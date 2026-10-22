#!/usr/bin/env bash
# NimLaunch example: clipboard history picker.
#
# Lists the clipboard history, newest first; choosing an entry puts it back on
# the clipboard. The last row clears the whole history after a confirmation.
# The backend is detected automatically:
#   cliphist  Wayland, fed by `wl-paste --watch cliphist store` from your
#             compositor's autostart
#   Klipper   KDE Plasma, read over D-Bus with qdbus
# Force one with NIMLAUNCH_CLIPBOARD_BACKEND=cliphist or =klipper.
#
# Dependencies: nimlaunch, plus either cliphist and wl-copy (wl-clipboard), or
#               qdbus / qdbus6 (Qt tools). Optional: notify-send.
# Klipper note: entries are fetched one by one and long histories are cut at
#               NIMLAUNCH_CLIPBOARD_LIMIT rows (default 50).
#
# Bind it in nimlaunch.toml:
#   [[shortcuts]]
#   group    = "scripts"
#   label    = "Clipboard History"
#   base     = "bash ~/.config/nimlaunch/scripts/nimlaunch_clipboard.sh"
#   mode     = "shell"
#   run_mode = "spawn"
set -euo pipefail

NIMLAUNCH_BIN="${NIMLAUNCH_BIN:-nimlaunch}"
CLIPHIST_BIN="${CLIPHIST_BIN:-cliphist}"
WL_COPY_BIN="${WL_COPY_BIN:-wl-copy}"
QDBUS_BIN="${QDBUS_BIN:-}"
LIMIT="${NIMLAUNCH_CLIPBOARD_LIMIT:-50}"
CLEAR_LABEL="Clear history…"

# Exits with an actionable message when a required command is unavailable.
require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'nimlaunch_clipboard: required command not found: %s\n' "$command_name" >&2
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

# Sends a desktop notification when notify-send is available.
notify() {
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "Clipboard" "$1" -i edit-paste || true
  fi
}

# Collapses clipboard text into a single-line row label of at most 100 chars.
preview_text() {
  local value="$1"

  value="${value//$'\r'/ }"
  value="${value//$'\n'/ }"
  value="${value//$'\t'/ }"
  value="${value#"${value%%[![:space:]]*}"}"
  printf '%.100s' "$value"
}

# Picks the first usable qdbus flavour unless QDBUS_BIN is set.
find_qdbus() {
  local candidate

  [[ -z "$QDBUS_BIN" ]] || return 0
  for candidate in qdbus6 qdbus-qt6 qdbus qdbus-qt5; do
    if command -v "$candidate" >/dev/null 2>&1; then
      QDBUS_BIN="$candidate"
      return 0
    fi
  done
  return 1
}

# Succeeds when Klipper answers on the session bus.
klipper_available() {
  find_qdbus && "$QDBUS_BIN" org.kde.klipper /klipper >/dev/null 2>&1
}

# Chooses cliphist or klipper for this session.
detect_backend() {
  case "${NIMLAUNCH_CLIPBOARD_BACKEND:-}" in
    cliphist | klipper)
      printf '%s' "$NIMLAUNCH_CLIPBOARD_BACKEND"
      return 0
      ;;
    "") ;;
    *)
      printf 'nimlaunch_clipboard: unknown backend: %s\n' "$NIMLAUNCH_CLIPBOARD_BACKEND" >&2
      exit 2
      ;;
  esac
  # Prefer cliphist whenever it works: it also stores images.
  if [[ -n "${WAYLAND_DISPLAY:-}" ]] && command -v "$CLIPHIST_BIN" >/dev/null 2>&1; then
    printf 'cliphist'
  elif klipper_available; then
    printf 'klipper'
  else
    printf 'nimlaunch_clipboard: no clipboard manager found; install cliphist (Wayland) or run Klipper (KDE)\n' >&2
    exit 127
  fi
}

# Loads the cliphist history into entries[], labels[] and icons[].
load_cliphist() {
  local line text
  require_command "$CLIPHIST_BIN"
  require_command "$WL_COPY_BIN"
  while IFS= read -r line; do
    text="${line#*$'\t'}"
    entries+=("$line")
    if [[ "$text" == "[[ binary data"* ]]; then
      icons+=(image-x-generic)
    else
      icons+=(edit-paste)
    fi
    labels+=("$(preview_text "$text")")
  done < <("$CLIPHIST_BIN" list | head -n "$LIMIT")
}

# Loads the Klipper history into entries[], labels[] and icons[].
load_klipper() {
  local index text
  find_qdbus || {
    printf 'nimlaunch_clipboard: required command not found: qdbus (or qdbus6)\n' >&2
    exit 127
  }
  for ((index = 0; index < LIMIT; index++)); do
    text="$("$QDBUS_BIN" org.kde.klipper /klipper getClipboardHistoryItem "$index")" || break
    [[ -n "$text" ]] || break
    entries+=("$text")
    icons+=(edit-paste)
    labels+=("$(preview_text "$text")")
  done
}

# Puts entries[$1] back on the clipboard.
restore_entry() {
  if [[ "$backend" == cliphist ]]; then
    printf '%s\n' "${entries[$1]}" | "$CLIPHIST_BIN" decode | "$WL_COPY_BIN"
  else
    "$QDBUS_BIN" org.kde.klipper /klipper setClipboardContents "${entries[$1]}" >/dev/null
  fi
}

# Deletes the whole history.
clear_history() {
  if [[ "$backend" == cliphist ]]; then
    "$CLIPHIST_BIN" wipe
  else
    "$QDBUS_BIN" org.kde.klipper /klipper clearClipboardHistory >/dev/null
  fi
}

require_command "$NIMLAUNCH_BIN"
backend="$(detect_backend)"

declare -a entries=() labels=() icons=()
declare -A seen_labels=()
"load_$backend"

((${#entries[@]} > 0)) || {
  notify "The clipboard history is empty"
  exit 0
}

# Identical previews (long texts that differ late) get a counter to stay unique.
for index in "${!labels[@]}"; do
  label="${labels[$index]}"
  [[ -n "$label" ]] || label="(blank)"
  if [[ -n "${seen_labels[$label]+set}" ]]; then
    seen_labels["$label"]=$((seen_labels[$label] + 1))
    label="$label (#${seen_labels[$label]})"
  else
    seen_labels["$label"]=1
  fi
  labels[index]="$label"
done

selection="$({
  for index in "${!labels[@]}"; do
    item "${labels[$index]}" "${icons[$index]}"
  done
  item "$CLEAR_LABEL" edit-clear-history
} | "$NIMLAUNCH_BIN" --dmenu -p "Clipboard:")" || cancelled $?
[[ -n "$selection" ]] || exit 0

# Real entries come first, so an entry that reads like the last row still wins.
if index="$(index_of "$selection" "${labels[@]}")"; then
  restore_entry "$index"
  notify "Restored: ${labels[$index]:0:60}"
elif [[ "$selection" == "$CLEAR_LABEL" ]]; then
  answer="$({
    item "No, keep it" dialog-cancel
    item "Yes, clear everything" dialog-ok
  } | "$NIMLAUNCH_BIN" --dmenu -p "Clear clipboard history?")" || cancelled $?
  if [[ "$answer" == "Yes, clear everything" ]]; then
    clear_history
    notify "History cleared"
  fi
else
  printf 'nimlaunch_clipboard: no such entry: %s\n' "$selection" >&2
  exit 1
fi
