#!/usr/bin/env bash
# NimLaunch example: launch installed Steam games.
#
# Reads libraryfolders.vdf to find every Steam library, lists the games from
# their appmanifest_*.acf files (without Proton, runtimes and Steamworks) and
# starts the chosen one with steam://rungameid/<appid>.
#
# Icons: Steam's own shortcut icons (hicolor "steam_icon_<appid>") are used
# when present, otherwise the generic "steam" icon. Steam's JPEG library cache
# is skipped because NimLaunch loads PNG, SVG and XPM icons only.
#
# Dependencies: nimlaunch, steam, awk, sort. Optional: notify-send.
# Overrides:    STEAM_ROOT=/path/to/Steam, STEAM_BIN=/path/to/launcher
#               (xdg-open is used when there is no steam binary).
#
# Bind it in nimlaunch.toml:
#   [[shortcuts]]
#   group    = "scripts"
#   label    = "Steam Games"
#   base     = "bash ~/.config/nimlaunch/scripts/nimlaunch_steam.sh"
#   mode     = "shell"
#   run_mode = "spawn"
set -euo pipefail

NIMLAUNCH_BIN="${NIMLAUNCH_BIN:-nimlaunch}"
STEAM_BIN="${STEAM_BIN:-steam}"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"

# Exits with an actionable message when a required command is unavailable.
require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'nimlaunch_steam: required command not found: %s\n' "$command_name" >&2
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

# Prints the Steam installation directory, if one can be found.
find_steam_root() {
  local candidate

  for candidate in \
    "${STEAM_ROOT:-}" \
    "$DATA_HOME/Steam" \
    "$HOME/.steam/steam" \
    "$HOME/.steam/root" \
    "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"; do
    if [[ -n "$candidate" && -d "$candidate/steamapps" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

# Adds the appmanifest files of one library directory to manifest_files[].
add_library_manifests() {
  local manifest

  for manifest in "$1"/steamapps/appmanifest_*.acf; do
    [[ -f "$manifest" ]] && manifest_files+=("$manifest")
  done
  return 0
}

# Prints the best available icon for a game: a Steam shortcut icon or "steam".
game_icon() {
  local icon

  for icon in "$DATA_HOME"/icons/hicolor/*/apps/"steam_icon_$1.png"; do
    if [[ -f "$icon" ]]; then
      printf '%s' "$icon"
      return 0
    fi
  done
  printf 'steam'
}

require_command "$NIMLAUNCH_BIN"
steam_root="$(find_steam_root)" || {
  printf 'nimlaunch_steam: Steam installation not found (set STEAM_ROOT)\n' >&2
  exit 1
}

# Every library listed in libraryfolders.vdf, plus the main installation.
declare -a manifest_files=()
declare -A seen_libraries=()
libraries_file="$steam_root/steamapps/libraryfolders.vdf"
declare -a libraries=("$steam_root")
if [[ -f "$libraries_file" ]]; then
  while IFS= read -r path; do
    [[ -n "$path" ]] && libraries+=("$path")
  done < <(awk -F'"' '$2 == "path" { print $4 }' "$libraries_file")
fi
for library in "${libraries[@]}"; do
  [[ -z "${seen_libraries[$library]+set}" && -d "$library/steamapps" ]] || continue
  seen_libraries["$library"]=1
  add_library_manifests "$library"
done

((${#manifest_files[@]} > 0)) || {
  printf 'nimlaunch_steam: no installed games found\n' >&2
  exit 1
}

declare -a game_ids=() game_names=() game_labels=()
declare -A seen_labels=()
while IFS=$'\t' read -r app_id name; do
  [[ -n "$app_id" && -n "$name" ]] || continue
  case "$name" in
    Proton* | "Steam Linux Runtime"* | Steamworks*) continue ;;
  esac
  label="$name"
  [[ -z "${seen_labels[$label]+set}" ]] || label="$name ($app_id)"
  seen_labels["$label"]=1
  game_ids+=("$app_id")
  game_names+=("$name")
  game_labels+=("$label")
done < <(
  # First "appid" and first "name" of each manifest (nested blocks repeat keys).
  awk -F'"' '
    FNR == 1 { appid = ""; name = "" }
    $2 == "appid" && appid == "" { appid = $4 }
    $2 == "name" && name == "" && appid != "" { name = $4; print appid "\t" name }
  ' "${manifest_files[@]}" | sort -f -t $'\t' -k2,2
)

((${#game_ids[@]} > 0)) || {
  printf 'nimlaunch_steam: no playable games found\n' >&2
  exit 1
}

selection="$(
  for index in "${!game_labels[@]}"; do
    item "${game_labels[$index]}" "$(game_icon "${game_ids[$index]}")"
  done | "$NIMLAUNCH_BIN" --dmenu -p "Steam:"
)" || cancelled $?
[[ -n "$selection" ]] || exit 0

index="$(index_of "$selection" "${game_labels[@]}")" || {
  printf 'nimlaunch_steam: no such game: %s\n' "$selection" >&2
  exit 1
}

if command -v notify-send >/dev/null 2>&1; then
  notify-send "Steam" "Launching ${game_names[$index]}" -i steam || true
fi
url="steam://rungameid/${game_ids[$index]}"
if command -v "$STEAM_BIN" >/dev/null 2>&1; then
  "$STEAM_BIN" "$url" >/dev/null 2>&1 &
else
  require_command xdg-open
  xdg-open "$url" >/dev/null 2>&1 &
fi
