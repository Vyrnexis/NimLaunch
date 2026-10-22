#!/usr/bin/env bash
# NimLaunch example: screenshots of an area, the whole screen or one window.
#
# Pick what to capture and where to put it: the clipboard or a PNG file in
# $XDG_PICTURES_DIR/Screenshots (default ~/Pictures/Screenshots). The tools
# follow your session:
#   niri      `niri msg action screenshot*`; niri decides where the image goes
#   Wayland   grim + slurp, with wl-copy for the clipboard
#   X11       maim, with xclip for the clipboard
# Window capture needs a way to list window geometry: Hyprland (hyprctl + jq),
# sway (swaymsg + jq), niri or X11 with xdotool; elsewhere that row is hidden.
#
# Skip the menu in a key binding: nimlaunch_screenshot.sh area clipboard
#   (first argument area|full|window, second clipboard|file)
#
# Dependencies: nimlaunch plus the tools above. Optional: notify-send.
#
# Bind it in nimlaunch.toml:
#   [[shortcuts]]
#   group    = "scripts"
#   label    = "Screenshot"
#   base     = "bash ~/.config/nimlaunch/scripts/nimlaunch_screenshot.sh"
#   mode     = "shell"
#   run_mode = "spawn"
set -euo pipefail

NIMLAUNCH_BIN="${NIMLAUNCH_BIN:-nimlaunch}"
NIRI_BIN="${NIRI_BIN:-niri}"
GRIM_BIN="${GRIM_BIN:-grim}"
SLURP_BIN="${SLURP_BIN:-slurp}"
WL_COPY_BIN="${WL_COPY_BIN:-wl-copy}"
MAIM_BIN="${MAIM_BIN:-maim}"
XCLIP_BIN="${XCLIP_BIN:-xclip}"
XDOTOOL_BIN="${XDOTOOL_BIN:-xdotool}"
HYPRCTL_BIN="${HYPRCTL_BIN:-hyprctl}"
SWAYMSG_BIN="${SWAYMSG_BIN:-swaymsg}"
JQ_BIN="${JQ_BIN:-jq}"

# Exits with an actionable message when a required command is unavailable.
require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'nimlaunch_screenshot: required command not found: %s\n' "$command_name" >&2
    exit 127
  fi
}

# Prints one dmenu row: a label plus an icon name or path.
item() {
  printf '%s\0icon\x1f%s\n' "$1" "${2:-}"
}

# Exits quietly when the menu was cancelled (status 1), otherwise propagates.
cancelled() {
  (($1 == 1)) && exit 0
  exit "$1"
}

# Sends a desktop notification when notify-send is available.
notify() {
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "Screenshot" "$1" -i camera-photo || true
  fi
}

# Prints the capture backend: niri, wayland or x11.
detect_backend() {
  if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
    if [[ -n "${NIRI_SOCKET:-}" ]] && command -v "$NIRI_BIN" >/dev/null 2>&1; then
      printf 'niri'
    else
      printf 'wayland'
    fi
  elif [[ -n "${DISPLAY:-}" ]]; then
    printf 'x11'
  else
    printf 'nimlaunch_screenshot: no Wayland or X11 session detected\n' >&2
    exit 1
  fi
}

# Succeeds when the current session can capture a single window.
window_capture_supported() {
  case "$backend" in
    niri) return 0 ;;
    x11) command -v "$XDOTOOL_BIN" >/dev/null 2>&1 ;;
    wayland)
      command -v "$JQ_BIN" >/dev/null 2>&1 &&
        { [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] || [[ -n "${SWAYSOCK:-}" ]]; }
      ;;
  esac
}

# Prints the directory for saved screenshots.
screenshot_directory() {
  local pictures=""

  if command -v xdg-user-dir >/dev/null 2>&1; then
    pictures="$(xdg-user-dir PICTURES 2>/dev/null || true)"
  fi
  [[ -n "$pictures" ]] || pictures="${XDG_PICTURES_DIR:-$HOME/Pictures}"
  printf '%s/Screenshots' "$pictures"
}

# Prints one "x,y WxH" region per visible window, for slurp -r.
window_regions() {
  if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
    "$HYPRCTL_BIN" -j clients | "$JQ_BIN" -r \
      '.[] | select(.mapped == true) | "\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"'
  else
    "$SWAYMSG_BIN" -t get_tree | "$JQ_BIN" -r '
      recurse(.nodes[]?, .floating_nodes[]?)
      | select(.pid != null and .visible == true)
      | "\(.rect.x),\(.rect.y) \(.rect.width)x\(.rect.height)"'
  fi
}

# niri owns the whole flow: its screenshot UI copies and saves as configured.
capture_niri() {
  case "$1" in
    area) "$NIRI_BIN" msg action screenshot ;;
    full) "$NIRI_BIN" msg action screenshot-screen ;;
    window) "$NIRI_BIN" msg action screenshot-window ;;
  esac
}

# Captures mode $1 (area|full|window) to destination $2 (clipboard|file) with
# grim and slurp.
capture_wayland() {
  local geometry="" file
  local -a grim_args=()

  require_command "$GRIM_BIN"
  case "$1" in
    area)
      require_command "$SLURP_BIN"
      geometry="$("$SLURP_BIN")" || return 0 # Esc in slurp: nothing to do
      ;;
    window)
      require_command "$SLURP_BIN"
      require_command "$JQ_BIN"
      geometry="$(window_regions | "$SLURP_BIN" -r)" || return 0
      ;;
  esac
  [[ "$1" == full || -n "$geometry" ]] || return 0
  [[ -z "$geometry" ]] || grim_args=(-g "$geometry")

  if [[ "$2" == clipboard ]]; then
    require_command "$WL_COPY_BIN"
    "$GRIM_BIN" "${grim_args[@]}" - | "$WL_COPY_BIN" --type image/png
    notify "Screenshot copied to the clipboard"
  else
    file="$(screenshot_directory)/$(date '+%Y-%m-%d_%H-%M-%S').png"
    mkdir -p "$(dirname "$file")"
    "$GRIM_BIN" "${grim_args[@]}" "$file"
    notify "Screenshot saved to $file"
  fi
}

# Captures mode $1 (area|full|window) to destination $2 (clipboard|file) with maim.
capture_x11() {
  local file
  local -a maim_args=()

  require_command "$MAIM_BIN"
  case "$1" in
    area) maim_args=(--select) ;;
    window)
      require_command "$XDOTOOL_BIN"
      maim_args=(--window "$("$XDOTOOL_BIN" selectwindow)") || return 0
      ;;
  esac

  if [[ "$2" == clipboard ]]; then
    require_command "$XCLIP_BIN"
    "$MAIM_BIN" "${maim_args[@]}" | "$XCLIP_BIN" -selection clipboard -t image/png
    notify "Screenshot copied to the clipboard"
  else
    file="$(screenshot_directory)/$(date '+%Y-%m-%d_%H-%M-%S').png"
    mkdir -p "$(dirname "$file")"
    "$MAIM_BIN" "${maim_args[@]}" "$file"
    notify "Screenshot saved to $file"
  fi
}

require_command "$NIMLAUNCH_BIN"
backend="$(detect_backend)"

mode="${1:-}"
destination="${2:-}"

if [[ -z "$mode" ]]; then
  declare -a labels=()
  declare -a modes=() destinations=()
  if [[ "$backend" == niri ]]; then
    labels=("Area" "Screen" "Window")
    modes=(area full window)
    destinations=(file file file)
  else
    labels=("Area → clipboard" "Area → file" "Full screen → clipboard" "Full screen → file")
    modes=(area area full full)
    destinations=(clipboard file clipboard file)
    if window_capture_supported; then
      labels+=("Window → clipboard" "Window → file")
      modes+=(window window)
      destinations+=(clipboard file)
    fi
  fi

  selection="$(
    for label in "${labels[@]}"; do
      item "$label" camera-photo
    done | "$NIMLAUNCH_BIN" --dmenu -p "Screenshot:"
  )" || cancelled $?
  [[ -n "$selection" ]] || exit 0

  for index in "${!labels[@]}"; do
    if [[ "${labels[$index]}" == "$selection" ]]; then
      mode="${modes[$index]}"
      destination="${destinations[$index]}"
      break
    fi
  done
  [[ -n "$mode" ]] || {
    printf 'nimlaunch_screenshot: no such entry: %s\n' "$selection" >&2
    exit 1
  }
  # Let NimLaunch's window disappear before the compositor captures the screen.
  sleep 0.3
fi

case "$mode" in
  area | full | window) ;;
  *)
    printf 'usage: nimlaunch_screenshot.sh [area|full|window] [clipboard|file]\n' >&2
    exit 2
    ;;
esac
case "$destination" in
  clipboard | file) ;;
  *)
    printf 'usage: nimlaunch_screenshot.sh [area|full|window] [clipboard|file]\n' >&2
    exit 2
    ;;
esac

"capture_$backend" "$mode" "$destination"
