#!/usr/bin/env bash
# NimLaunch example: Bluetooth power and paired devices.
#
# The first row switches the adapter on or off. While it is on, every paired
# device is listed with its connection state; choosing one connects it, or
# disconnects it when it is already connected.
#
# Dependencies: nimlaunch, bluetoothctl (BlueZ). Optional: notify-send.
#
# Bind it in nimlaunch.toml:
#   [[shortcuts]]
#   group    = "scripts"
#   label    = "Bluetooth"
#   base     = "bash ~/.config/nimlaunch/scripts/nimlaunch_bluetooth.sh"
#   mode     = "shell"
#   run_mode = "spawn"
set -euo pipefail

NIMLAUNCH_BIN="${NIMLAUNCH_BIN:-nimlaunch}"
BLUETOOTHCTL_BIN="${BLUETOOTHCTL_BIN:-bluetoothctl}"

# Exits with an actionable message when a required command is unavailable.
require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'nimlaunch_bluetooth: required command not found: %s\n' "$command_name" >&2
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
    notify-send "Bluetooth" "$1" -i bluetooth || true
  fi
}

# Succeeds when the adapter is powered on.
adapter_is_on() {
  "$BLUETOOTHCTL_BIN" show 2>/dev/null |
    awk '$1 == "Powered:" { on = ($2 == "yes") } END { exit !on }'
}

# Succeeds when the device with the given address is connected.
device_is_connected() {
  "$BLUETOOTHCTL_BIN" info "$1" 2>/dev/null |
    awk '$1 == "Connected:" { on = ($2 == "yes") } END { exit !on }'
}

require_command "$NIMLAUNCH_BIN"
require_command "$BLUETOOTHCTL_BIN"

power_label="Turn Bluetooth on"
adapter_is_on && power_label="Turn Bluetooth off"

declare -a device_macs=() device_names=() device_labels=()
declare -A seen_labels=()

if adapter_is_on; then
  # Older BlueZ releases do not understand "devices Paired"; fall back to all.
  while read -r record_type mac name; do
    [[ "$record_type" == "Device" && -n "$mac" ]] || continue
    [[ -n "$name" ]] || name="Unnamed device"
    label="$name"
    [[ -z "${seen_labels[$label]+set}" ]] || label="$name ($mac)"
    seen_labels["$label"]=1
    device_is_connected "$mac" && label="$label (connected)"
    device_macs+=("$mac")
    device_names+=("$name")
    device_labels+=("$label")
  done < <("$BLUETOOTHCTL_BIN" devices Paired 2>/dev/null || "$BLUETOOTHCTL_BIN" devices)
fi

selection="$({
  item "$power_label" preferences-system-bluetooth
  for label in "${device_labels[@]}"; do
    item "$label" bluetooth
  done
} | "$NIMLAUNCH_BIN" --dmenu -p "Bluetooth:")" || cancelled $?
[[ -n "$selection" ]] || exit 0

if [[ "$selection" == "$power_label" ]]; then
  if adapter_is_on; then
    "$BLUETOOTHCTL_BIN" power off >/dev/null
    notify "Turned off"
  else
    "$BLUETOOTHCTL_BIN" power on >/dev/null
    notify "Turned on"
  fi
  exit 0
fi

index="$(index_of "$selection" "${device_labels[@]}")" || {
  printf 'nimlaunch_bluetooth: no such device: %s\n' "$selection" >&2
  exit 1
}

mac="${device_macs[$index]}"
name="${device_names[$index]}"
if device_is_connected "$mac"; then
  if "$BLUETOOTHCTL_BIN" disconnect "$mac" >/dev/null; then
    notify "Disconnected from $name"
  else
    notify "Could not disconnect from $name"
    exit 1
  fi
elif "$BLUETOOTHCTL_BIN" connect "$mac" >/dev/null; then
  notify "Connected to $name"
else
  notify "Could not connect to $name"
  exit 1
fi
