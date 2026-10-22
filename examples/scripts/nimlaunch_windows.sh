#!/usr/bin/env bash
# NimLaunch example: window switcher.
#
# Lists the open windows as "title — app" with the application's icon, and
# focuses the one you pick. The compositor is detected from the environment:
#   niri      niri msg -j windows        (jq)
#   Hyprland  hyprctl -j clients         (jq)
#   sway      swaymsg -t get_tree        (jq)
#   X11       wmctrl -lx                 (any EWMH window manager)
# Force one with NIMLAUNCH_WINDOWS_BACKEND=niri|hyprland|sway|x11.
#
# Dependencies: nimlaunch, plus the tools in the list above. jq is required for
#               niri, Hyprland and sway only.
#
# Bind it in nimlaunch.toml:
#   [[shortcuts]]
#   group    = "scripts"
#   label    = "Window Switcher"
#   base     = "bash ~/.config/nimlaunch/scripts/nimlaunch_windows.sh"
#   mode     = "shell"
#   run_mode = "spawn"
set -euo pipefail

NIMLAUNCH_BIN="${NIMLAUNCH_BIN:-nimlaunch}"
NIRI_BIN="${NIRI_BIN:-niri}"
HYPRCTL_BIN="${HYPRCTL_BIN:-hyprctl}"
SWAYMSG_BIN="${SWAYMSG_BIN:-swaymsg}"
WMCTRL_BIN="${WMCTRL_BIN:-wmctrl}"
JQ_BIN="${JQ_BIN:-jq}"

# jq filter tail shared by the JSON backends: turns [id, app, title] into one
# tab-separated row with tabs and newlines in the values replaced by spaces.
ROW='map(tostring | gsub("[\\t\\r\\n]"; " ")) | join("\t")'

# Exits with an actionable message when a required command is unavailable.
require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'nimlaunch_windows: required command not found: %s\n' "$command_name" >&2
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

# Prints the index of the first argument within the remaining ones.
index_of() {
  local needle="$1" index=0 candidate
  shift
  for candidate in "$@"; do
    if [[ "$candidate" == "$needle" ]]; then
      printf '%s' "$index"
      return 0
    fi
    index=$((index + 1))
  done
  return 1
}

# Prints the window backend for this session.
detect_backend() {
  case "${NIMLAUNCH_WINDOWS_BACKEND:-}" in
    niri | hyprland | sway | x11)
      printf '%s' "$NIMLAUNCH_WINDOWS_BACKEND"
      return 0
      ;;
    "") ;;
    *)
      printf 'nimlaunch_windows: unknown backend: %s\n' "$NIMLAUNCH_WINDOWS_BACKEND" >&2
      exit 2
      ;;
  esac
  if [[ -n "${NIRI_SOCKET:-}" ]]; then
    printf 'niri'
  elif [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
    printf 'hyprland'
  elif [[ -n "${SWAYSOCK:-}" ]]; then
    printf 'sway'
  elif [[ -n "${DISPLAY:-}" ]]; then
    printf 'x11'
  else
    printf 'nimlaunch_windows: no supported compositor or X11 display detected\n' >&2
    exit 1
  fi
}

# Checks the commands the chosen backend needs, before any of them runs.
require_niri() {
  require_command "$NIRI_BIN"
  require_command "$JQ_BIN"
}

require_hyprland() {
  require_command "$HYPRCTL_BIN"
  require_command "$JQ_BIN"
}

require_sway() {
  require_command "$SWAYMSG_BIN"
  require_command "$JQ_BIN"
}

require_x11() {
  require_command "$WMCTRL_BIN"
}

# Each list_* function prints "id<TAB>app<TAB>title" rows; each focus_* takes
# the id of one of those rows.
list_niri() {
  "$NIRI_BIN" msg -j windows |
    "$JQ_BIN" -r ".[] | [.id, .app_id // \"\", .title // \"\"] | $ROW"
}

focus_niri() {
  "$NIRI_BIN" msg action focus-window --id "$1" >/dev/null
}

list_hyprland() {
  "$HYPRCTL_BIN" -j clients |
    "$JQ_BIN" -r ".[] | select(.mapped == true) | [.address, .class // \"\", .title // \"\"] | $ROW"
}

focus_hyprland() {
  "$HYPRCTL_BIN" dispatch focuswindow "address:$1" >/dev/null
}

list_sway() {
  "$SWAYMSG_BIN" -t get_tree | "$JQ_BIN" -r "
    recurse(.nodes[]?, .floating_nodes[]?)
    | select((.type == \"con\" or .type == \"floating_con\") and .pid != null)
    | [.id, .app_id // .window_properties.class // \"\", .name // \"\"]
    | $ROW"
}

focus_sway() {
  "$SWAYMSG_BIN" "[con_id=$1] focus" >/dev/null
}

# wmctrl -lx prints: id desktop instance.Class host title... (desktop -1 is a
# panel or dock). The lower-cased Class doubles as the icon name.
list_x11() {
  "$WMCTRL_BIN" -lx | awk '
    $2 == "-1" { next }
    {
      id = $1
      count = split($3, parts, ".")
      app = tolower(parts[count])
      title = $0
      sub(/^[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +/, "", title)
      printf "%s\t%s\t%s\n", id, app, title
    }
  '
}

focus_x11() {
  "$WMCTRL_BIN" -ia "$1"
}

require_command "$NIMLAUNCH_BIN"
backend="$(detect_backend)"
"require_$backend"

declare -a window_ids=() window_labels=() window_icons=()
declare -A seen_labels=()

while IFS=$'\t' read -r id app title; do
  [[ -n "$id" ]] || continue
  [[ -n "$title" ]] || title="Untitled window"
  label="${title:0:80}"
  [[ -z "$app" ]] || label="$label — $app"
  [[ -z "${seen_labels[$label]+set}" ]] || label="$label ($id)"
  seen_labels["$label"]=1
  window_ids+=("$id")
  window_labels+=("$label")
  window_icons+=("${app:-application-x-executable}")
done < <("list_$backend")

((${#window_ids[@]} > 0)) || {
  printf 'nimlaunch_windows: no windows found\n' >&2
  exit 1
}

selection="$(
  for index in "${!window_labels[@]}"; do
    item "${window_labels[$index]}" "${window_icons[$index]}"
  done | "$NIMLAUNCH_BIN" --dmenu -p "Windows:"
)" || cancelled $?
[[ -n "$selection" ]] || exit 0

index="$(index_of "$selection" "${window_labels[@]}")" || {
  printf 'nimlaunch_windows: no such window: %s\n' "$selection" >&2
  exit 1
}

"focus_$backend" "${window_ids[$index]}"
