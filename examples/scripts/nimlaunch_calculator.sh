#!/usr/bin/env bash
# NimLaunch example: interactive calculator.
#
# Type an expression and press Shift+Enter (or Enter while the list shows "No
# matches"): the answer appears as the first row, above your earlier
# calculations. Pick the answer, or any earlier row, to copy its result to the
# clipboard and quit. Esc quits without copying. Because plain Enter chooses
# the highlighted row, Shift+Enter is the safe way to evaluate.
#
# Supported: + - * / % ^ and parentheses, sqrt() sin() cos() atan() ln() exp(),
# and pi. Anything else is rejected before it reaches bc.
#
# Dependencies: nimlaunch, bc. Optional: wl-copy or xclip (clipboard; the
#               result is printed without them), notify-send.
# Start with an expression: nimlaunch_calculator.sh "2 * (3 + 4)"
#
# Bind it in nimlaunch.toml:
#   [[shortcuts]]
#   group    = "scripts"
#   label    = "Calculator"
#   base     = "bash ~/.config/nimlaunch/scripts/nimlaunch_calculator.sh"
#   mode     = "shell"
#   run_mode = "spawn"
set -euo pipefail

NIMLAUNCH_BIN="${NIMLAUNCH_BIN:-nimlaunch}"
BC_BIN="${BC_BIN:-bc}"
WL_COPY_BIN="${WL_COPY_BIN:-wl-copy}"
XCLIP_BIN="${XCLIP_BIN:-xclip}"
HINT="Type an expression, then press Shift+Enter"

# Exits with an actionable message when a required command is unavailable.
require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'nimlaunch_calculator: required command not found: %s\n' "$command_name" >&2
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
    notify-send "Calculator" "$1" -i accessories-calculator || true
  fi
}

# Evaluates expression $1. On success sets `result` and returns 0; otherwise
# sets `error` and returns 1.
evaluate() {
  local expression="${1,,}" output
  local allowed='^([-+*/%^(),.[:space:][:digit:]]|[scale]\(|sqrt\()+$'

  expression="${expression//×/*}"
  expression="${expression//÷//}"
  expression="${expression//"sin("/"s("}"
  expression="${expression//"cos("/"c("}"
  expression="${expression//"atan("/"a("}"
  expression="${expression//"ln("/"l("}"
  expression="${expression//"exp("/"e("}"
  expression="${expression//pi/(4*a(1))}"

  # Only digits, operators, brackets and the bc functions s c a l e sqrt remain.
  if [[ -z "${expression//[[:space:]]/}" ]]; then
    error="Empty expression"
    return 1
  fi
  if [[ ! "$expression" =~ $allowed ]]; then
    error="Unsupported characters in: $1"
    return 1
  fi

  # bc -l loads the math library; scale=12 keeps the output readable.
  output="$(printf 'scale=12\n%s\n' "$expression" | BC_LINE_LENGTH=0 "$BC_BIN" -l 2>&1)" || true
  output="${output//$'\\\n'/}"
  if [[ ! "$output" =~ ^-?[0-9]*\.?[0-9]+$ ]]; then
    error="Invalid expression: $1"
    return 1
  fi

  # Tidy: .5 -> 0.5, 2.500000000000 -> 2.5, 4.000000000000 -> 4.
  [[ "$output" == .* ]] && output="0$output"
  [[ "$output" == -.* ]] && output="-0${output#-}"
  if [[ "$output" == *.* ]]; then
    output="${output%"${output##*[!0]}"}"
    output="${output%.}"
  fi
  result="$output"
}

# Copies $1 with wl-copy (Wayland) or xclip (X11), else prints it.
copy_result() {
  if [[ -n "${WAYLAND_DISPLAY:-}" ]] && command -v "$WL_COPY_BIN" >/dev/null 2>&1; then
    printf '%s' "$1" | "$WL_COPY_BIN"
    notify "Copied $1 to the clipboard"
  elif command -v "$XCLIP_BIN" >/dev/null 2>&1; then
    printf '%s' "$1" | "$XCLIP_BIN" -selection clipboard
    notify "Copied $1 to the clipboard"
  else
    printf '%s\n' "$1"
    notify "Result: $1 (no clipboard tool found)"
  fi
}

require_command "$NIMLAUNCH_BIN"
require_command "$BC_BIN"

# History, newest first: expression and result are kept in parallel arrays.
declare -a history_expressions=() history_results=()
result="" error="" previous_error=""

# Records a successful calculation, replacing an identical older entry.
remember() {
  local -a expressions=("$1") results=("$2")
  local index

  for index in "${!history_expressions[@]}"; do
    [[ "${history_expressions[$index]}" == "$1" ]] && continue
    expressions+=("${history_expressions[$index]}")
    results+=("${history_results[$index]}")
  done
  history_expressions=("${expressions[@]}")
  history_results=("${results[@]}")
}

if [[ -n "$*" ]]; then
  if evaluate "$*"; then
    remember "$*" "$result"
  fi
fi

while true; do
  selection="$({
    [[ -z "$error" ]] || item "$error" dialog-error
    ((${#history_results[@]} == 0)) || item "= ${history_results[0]}" edit-copy
    for index in "${!history_expressions[@]}"; do
      item "${history_expressions[$index]} = ${history_results[$index]}" accessories-calculator
    done
    item "$HINT" dialog-information
  } | "$NIMLAUNCH_BIN" --dmenu -p "Calc:")" || cancelled $?

  previous_error="$error"
  error=""
  # A row from the list copies its result; anything else is a new expression.
  if ((${#history_results[@]} > 0)) && [[ "$selection" == "= ${history_results[0]}" ]]; then
    copy_result "${history_results[0]}"
    exit 0
  fi
  for index in "${!history_expressions[@]}"; do
    if [[ "$selection" == "${history_expressions[$index]} = ${history_results[$index]}" ]]; then
      copy_result "${history_results[$index]}"
      exit 0
    fi
  done
  [[ -n "$selection" && "$selection" != "$HINT" && "$selection" != "$previous_error" ]] || continue

  if evaluate "$selection"; then
    remember "$selection" "$result"
  fi
done
