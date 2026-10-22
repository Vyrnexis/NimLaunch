#!/usr/bin/env bash
# NimLaunch dmenu showcase: a guided tour of `nimlaunch --dmenu`.
#
# Read this file top to bottom: the helpers come first, copy any of them into
# your own scripts, then each demo shows one technique in a small function.
#
# Dependencies: nimlaunch, bash 4+, coreutils. Everything else is optional:
#   wl-copy or xclip   copy results to the clipboard (otherwise they are printed)
#   notify-send        desktop notifications (otherwise messages are printed)
#
# Bind it in nimlaunch.toml:
#   [[shortcuts]]
#   group    = "scripts"
#   label    = "dmenu Showcase"
#   base     = "bash ~/.config/nimlaunch/scripts/nimlaunch_showcase.sh"
#   mode     = "shell"
#   run_mode = "spawn"
#
# Try it with another binary: NIMLAUNCH_BIN=./bin/nimlaunch bash nimlaunch_showcase.sh
set -euo pipefail

NIMLAUNCH_BIN="${NIMLAUNCH_BIN:-nimlaunch}"
NOTES_FILE="${NIMLAUNCH_NOTES_FILE:-${XDG_DATA_HOME:-$HOME/.local/share}/nimlaunch/notes.txt}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Reusable helpers ───────────────────────────────────────────────────────

# True when a command is installed.
have_command() {
  command -v "$1" >/dev/null 2>&1
}

# Prints one dmenu row: a label, plus an optional icon (theme name or path).
# The "\0icon\x1f" suffix is rofi's row-option syntax. NimLaunch shows the icon
# and prints only the label when the row is chosen.
item() {
  printf '%s\0icon\x1f%s\n' "$1" "${2:-}"
}

# Shows the rows read from stdin and prints the choice.
#   exit 0  something was chosen (or typed, see below)
#   exit 1  cancelled with Esc or by losing focus
# NimLaunch also prints text that matches no row when you press Shift+Enter, or
# Enter while the list shows "No matches". Callers must therefore treat the
# result as a string, not as "one of my rows", whenever free text is possible.
menu() {
  "$NIMLAUNCH_BIN" --dmenu -p "$1"
}

# Asks a yes/no question; succeeds only for "Yes". Esc counts as "No".
# "No" is listed first, so a stray Enter is the safe answer.
confirm() {
  local answer
  answer="$({
    item "No" dialog-cancel
    item "Yes" dialog-ok
  } | menu "$1")" || return 1
  [[ "$answer" == "Yes" ]]
}

# Asks for a line of free text. The single row is only an instruction: type your
# text and press Shift+Enter, which returns exactly what you typed. Prints the
# trimmed text; fails when cancelled, left empty or when the instruction row
# itself was picked.
prompt_text() {
  local prompt="$1" hint="$2" text
  text="$(item "$hint" dialog-information | menu "$prompt")" || return 1
  text="${text#"${text%%[![:space:]]*}"}"
  text="${text%"${text##*[![:space:]]}"}"
  [[ -n "$text" && "$text" != "$hint" ]] || return 1
  printf '%s' "$text"
}

# Copies text to the clipboard with wl-copy (Wayland) or xclip (X11).
copy_text() {
  if [[ -n "${WAYLAND_DISPLAY:-}" ]] && have_command wl-copy; then
    printf '%s' "$1" | wl-copy
  elif have_command xclip; then
    printf '%s' "$1" | xclip -selection clipboard
  else
    return 1
  fi
}

# Shows a desktop notification, or prints the message without notify-send.
notify() {
  if have_command notify-send; then
    notify-send "NimLaunch showcase" "$1" -i "${2:-dialog-information}" || true
  else
    printf '%s\n' "$1"
  fi
}

# ─── Demo 1: nested menus with a Back entry ─────────────────────────────────

# Shows "Back" plus the given labels; prints the pick, fails on Back or Esc.
# A submenu is just another menu call: when it returns, you are in the parent.
leaf_menu() {
  local prompt="$1" choice entry
  shift
  choice="$({
    for entry in "$@"; do
      item "$entry" emblem-favorite
    done
    item "← Back" go-previous
  } | menu "$prompt")" || return 1
  [[ "$choice" != "← Back" ]] || return 1
  printf '%s' "$choice"
}

demo_nested() {
  local choice pick
  while true; do
    choice="$({
      item "Colours" applications-graphics
      item "Animals" face-smile
      item "← Back" go-previous
    } | menu "Nested menus:")" || return 0

    case "$choice" in
      Colours)
        pick="$(leaf_menu "Colours:" Red Green Blue Yellow)" || continue
        notify "You picked the colour $pick."
        ;;
      Animals)
        pick="$(leaf_menu "Animals:" Fox Otter Heron Lynx)" || continue
        notify "You picked the animal $pick."
        ;;
      "← Back") return 0 ;;
      *) ;; # free text that matched nothing: just show the menu again
    esac
  done
}

# ─── Demo 2: free-text input ────────────────────────────────────────────────

demo_quick_note() {
  local note
  note="$(prompt_text "Note:" "Type your note, then press Shift+Enter")" || return 0
  mkdir -p "$(dirname "$NOTES_FILE")"
  printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M')" "$note" >>"$NOTES_FILE"
  notify "Note saved to $NOTES_FILE" document-save
}

demo_show_notes() {
  local -a lines=()
  local line choice

  if [[ ! -s "$NOTES_FILE" ]]; then
    notify "No notes yet. Use \"Quick note\" first." dialog-warning
    return 0
  fi

  # Newest first, at most 50 rows.
  mapfile -t lines < <(tail -n 50 "$NOTES_FILE" | tac)
  choice="$(
    for line in "${lines[@]}"; do
      item "$line" text-x-generic
    done | menu "Notes (Enter copies):"
  )" || return 0

  # Strip the "YYYY-MM-DD HH:MM  " timestamp and copy what is left.
  choice="${choice#*  }"
  if copy_text "$choice"; then
    notify "Copied: $choice" edit-copy
  else
    printf '%s\n' "$choice"
  fi
}

# ─── Demo 3: confirmation dialog ────────────────────────────────────────────

demo_confirm() {
  if confirm "Really do the dangerous thing?"; then
    notify "You said yes."
  else
    notify "You said no (or pressed Esc)."
  fi
}

# ─── Demo 4: emoji and symbol picker ────────────────────────────────────────

demo_emoji() {
  # "glyph name": type part of the name to search, the glyph is what we copy.
  local -a symbols=(
    "😀 grinning face" "😂 face with tears of joy" "😍 heart eyes" "😎 sunglasses"
    "🤔 thinking face" "😴 sleeping face" "😭 loudly crying face" "🙃 upside-down face"
    "👍 thumbs up" "👎 thumbs down" "👏 clapping hands" "🙏 folded hands"
    "💪 flexed biceps" "👀 eyes" "🔥 fire" "✨ sparkles"
    "🎉 party popper" "❤️ red heart" "💔 broken heart" "💡 light bulb"
    "✅ check mark button" "❌ cross mark" "⚠️ warning" "🚀 rocket"
    "🐧 penguin" "🦊 fox" "🐱 cat" "🐶 dog"
    "☕ hot beverage" "🍕 pizza" "🍺 beer mug" "🌍 globe europe-africa"
    "→ right arrow" "← left arrow" "↑ up arrow" "↓ down arrow"
    "⇒ double right arrow" "… ellipsis" "• bullet" "— em dash"
    "© copyright" "™ trademark" "° degree sign" "± plus-minus"
    "× multiplication sign" "÷ division sign" "≈ almost equal" "≠ not equal"
    "≤ less than or equal" "≥ greater than or equal" "∞ infinity" "√ square root"
    "€ euro sign" "£ pound sign" "¥ yen sign" "₿ bitcoin sign"
    "λ lambda" "π pi" "Ω omega" "µ micro sign"
  )
  local choice symbol entry found=0

  choice="$(
    for entry in "${symbols[@]}"; do
      item "$entry"
    done | menu "Emoji:"
  )" || return 0

  # The pick could be free text, so confirm it is one of our rows.
  for entry in "${symbols[@]}"; do
    [[ "$entry" == "$choice" ]] && found=1
  done
  ((found)) || return 0

  symbol="${choice%% *}"
  if copy_text "$symbol"; then
    notify "Copied $symbol to the clipboard." edit-copy
  else
    printf '%s\n' "$symbol"
  fi
}

# ─── Demo 5: fuzzy matching tips ────────────────────────────────────────────

demo_fuzzy() {
  # NimLaunch matches dmenu rows four ways, so you rarely need the full text:
  #   substring       "studio"  → Visual Studio Code, OBS Studio
  #   initials        "vsc"     → Visual Studio Code
  #   letters in order "tdsk"   → Telegram Desktop
  #   one typo        "firfox"  → Mozilla Firefox
  local -a apps=(
    "Visual Studio Code" "GNU Image Manipulation Program" "LibreOffice Writer"
    "Mozilla Firefox" "Telegram Desktop" "Mozilla Thunderbird" "OBS Studio"
    "Kdenlive Video Editor"
  )
  local choice app

  while true; do
    choice="$({
      item "Tip: try vsc, gimp, low, tdsk or firfox" dialog-information
      for app in "${apps[@]}"; do
        item "$app" application-x-executable
      done
    } | menu "Fuzzy:")" || return 0

    for app in "${apps[@]}"; do
      if [[ "$app" == "$choice" ]]; then
        notify "You picked $app." application-x-executable
        return 0
      fi
    done
  done
}

# ─── Demo 6: launching the other example scripts ────────────────────────────

# Prints the paths of the sibling nimlaunch_*.sh scripts (not this one).
installed_scripts() {
  local path
  for path in "$SCRIPT_DIR"/nimlaunch_*.sh; do
    [[ -f "$path" && "$path" != */nimlaunch_showcase.sh ]] && printf '%s\n' "$path"
  done
  return 0
}

demo_scripts() {
  local -a paths=() labels=()
  local path name choice index status

  mapfile -t paths < <(installed_scripts)
  if ((${#paths[@]} == 0)); then
    notify "No other nimlaunch_*.sh scripts found next to this one." dialog-warning
    return 0
  fi

  for path in "${paths[@]}"; do
    name="$(basename "$path" .sh)"
    name="${name#nimlaunch_}"
    labels+=("${name^}")
  done

  choice="$(
    for index in "${!labels[@]}"; do
      item "${labels[$index]}" system-run
    done | menu "Scripts:"
  )" || return 0

  for index in "${!labels[@]}"; do
    [[ "${labels[$index]}" == "$choice" ]] || continue
    # Each script opens its own dmenu; ours resumes when it finishes.
    status=0
    bash "${paths[$index]}" || status=$?
    ((status == 0)) || notify "${labels[$index]} exited with status $status." dialog-warning
    return 0
  done
}

# ─── Main menu ──────────────────────────────────────────────────────────────

main() {
  local choice

  # Redraw the menu after every demo; Esc or "Quit" leaves the loop.
  while true; do
    choice="$({
      item "Nested menus" folder
      item "Quick note" accessories-text-editor
      item "Show notes" text-x-generic
      item "Confirm dialog" dialog-question
      item "Emoji and symbols" face-smile
      item "Fuzzy matching tips" edit-find
      if [[ -n "$(installed_scripts)" ]]; then
        item "Example scripts" system-run
      fi
      item "Quit" application-exit
    } | menu "Showcase:")" || break # Esc: leave quietly

    case "$choice" in
      "Nested menus") demo_nested ;;
      "Quick note") demo_quick_note ;;
      "Show notes") demo_show_notes ;;
      "Confirm dialog") demo_confirm ;;
      "Emoji and symbols") demo_emoji ;;
      "Fuzzy matching tips") demo_fuzzy ;;
      "Example scripts") demo_scripts ;;
      "Quit") break ;;
      *) ;; # free text that matched nothing: ignore and redraw
    esac
  done
}

if ! have_command "$NIMLAUNCH_BIN"; then
  printf 'nimlaunch_showcase: required command not found: %s\n' "$NIMLAUNCH_BIN" >&2
  exit 127
fi

main
