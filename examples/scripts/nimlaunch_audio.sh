#!/usr/bin/env bash
# NimLaunch example: choose the default audio output.
#
# Lists the available output devices (sinks) and makes the selected one the
# default. The current default is marked "(current)".
#
# Dependencies: nimlaunch, and either wpctl (PipeWire + WirePlumber, preferred)
#               or pactl (PulseAudio / pipewire-pulse). Optional: notify-send.
#
# Bind it in nimlaunch.toml:
#   [[shortcuts]]
#   group    = "scripts"
#   label    = "Audio Output"
#   base     = "bash ~/.config/nimlaunch/scripts/nimlaunch_audio.sh"
#   mode     = "shell"
#   run_mode = "spawn"
set -euo pipefail

NIMLAUNCH_BIN="${NIMLAUNCH_BIN:-nimlaunch}"
WPCTL_BIN="${WPCTL_BIN:-wpctl}"
PACTL_BIN="${PACTL_BIN:-pactl}"

# Exits with an actionable message when a required command is unavailable.
require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'nimlaunch_audio: required command not found: %s\n' "$command_name" >&2
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

# Emits "id<TAB>current<TAB>name" for every sink known to WirePlumber.
wpctl_sinks() {
  "$WPCTL_BIN" status | LC_ALL=C awk '
    /^Audio$/ { in_audio = 1; next }
    /^Video$/ { in_audio = 0 }
    in_audio && /Sinks:$/ { in_sinks = 1; next }
    in_sinks && /(├|└)─/ { in_sinks = 0 }
    in_sinks && match($0, / \*?[ ]+[0-9]+\. /) {
      marker = substr($0, RSTART, RLENGTH)
      name = substr($0, RSTART + RLENGTH)
      sub(/ \[vol:.*$/, "", name)
      id = marker
      gsub(/[^0-9]/, "", id)
      printf "%s\t%d\t%s\n", id, (marker ~ /\*/), name
    }
  '
}

# Emits "name<TAB>current<TAB>description" for every PulseAudio sink.
pactl_sinks() {
  local default_sink
  default_sink="$("$PACTL_BIN" get-default-sink 2>/dev/null || true)"
  "$PACTL_BIN" list sinks | awk -v default_sink="$default_sink" '
    /^[[:space:]]+Name: / { sub(/^[[:space:]]+Name: /, ""); name = $0 }
    /^[[:space:]]+Description: / {
      sub(/^[[:space:]]+Description: /, "")
      printf "%s\t%d\t%s\n", name, (name == default_sink), $0
    }
  '
}

# Makes the sink with the given id (wpctl) or name (pactl) the default.
set_default() {
  local sink="$1" stream

  if [[ "$backend" == wpctl ]]; then
    "$WPCTL_BIN" set-default "$sink"
  else
    "$PACTL_BIN" set-default-sink "$sink"
    # Move streams that are already playing so the switch is audible at once.
    while read -r stream _; do
      "$PACTL_BIN" move-sink-input "$stream" "$sink" || true
    done < <("$PACTL_BIN" list short sink-inputs)
  fi
}

require_command "$NIMLAUNCH_BIN"
if command -v "$WPCTL_BIN" >/dev/null 2>&1; then
  backend=wpctl
elif command -v "$PACTL_BIN" >/dev/null 2>&1; then
  backend=pactl
else
  printf 'nimlaunch_audio: install wpctl (WirePlumber) or pactl (PulseAudio)\n' >&2
  exit 127
fi

declare -a sink_ids=() sink_labels=()
declare -A seen_labels=()

while IFS=$'\t' read -r id current name; do
  [[ -n "$id" && -n "$name" ]] || continue
  label="$name"
  # Two devices can share a description; keep the rows distinguishable.
  [[ -z "${seen_labels[$label]+set}" ]] || label="$name ($id)"
  seen_labels["$label"]=1
  ((current)) && label="$label (current)"
  sink_ids+=("$id")
  sink_labels+=("$label")
done < <("${backend}_sinks")

((${#sink_ids[@]} > 0)) || {
  printf 'nimlaunch_audio: no audio outputs found\n' >&2
  exit 1
}

selection="$(
  for label in "${sink_labels[@]}"; do
    item "$label" audio-speakers
  done | "$NIMLAUNCH_BIN" --dmenu -p "Audio output:"
)" || cancelled $?
[[ -n "$selection" ]] || exit 0

index="$(index_of "$selection" "${sink_labels[@]}")" || {
  printf 'nimlaunch_audio: no such output: %s\n' "$selection" >&2
  exit 1
}

set_default "${sink_ids[$index]}"
if command -v notify-send >/dev/null 2>&1; then
  notify-send "Audio output" "${sink_labels[$index]%" (current)"}" -i audio-speakers || true
fi
