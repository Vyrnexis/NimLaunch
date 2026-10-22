#!/usr/bin/env bash
# NimLaunch example: Wi-Fi networks via NetworkManager.
#
# Lists nearby networks with signal strength and security, strongest first, and
# connects to the one you pick. Saved networks connect straight away; the
# connected one disconnects. For a new secured network the script asks for the
# password in a second NimLaunch prompt: type it and press Shift+Enter, which
# returns exactly what you typed (see docs/dmenu.md, "Free text"). The password
# is visible while you type it, and nmcli receives it as an argument, so use
# this on a machine you trust. Rows also rescan and toggle the Wi-Fi radio.
#
# Dependencies: nimlaunch, nmcli (NetworkManager). Optional: notify-send.
# Note: a saved network is recognised by a connection named like its SSID,
#       which is what `nmcli device wifi connect` creates.
#
# Bind it in nimlaunch.toml:
#   [[shortcuts]]
#   group    = "scripts"
#   label    = "Wi-Fi"
#   base     = "bash ~/.config/nimlaunch/scripts/nimlaunch_wifi.sh"
#   mode     = "shell"
#   run_mode = "spawn"
set -euo pipefail

NIMLAUNCH_BIN="${NIMLAUNCH_BIN:-nimlaunch}"
NMCLI_BIN="${NMCLI_BIN:-nmcli}"
RESCAN_LABEL="Rescan networks"

# Exits with an actionable message when a required command is unavailable.
require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'nimlaunch_wifi: required command not found: %s\n' "$command_name" >&2
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
    notify-send "Wi-Fi" "$1" -i network-wireless || true
  fi
}

# Splits one escaped nmcli --terse record into the global nmcli_fields array.
parse_nmcli_record() {
  local record="$1"
  local character field="" escaped=0 index
  nmcli_fields=()

  for ((index = 0; index < ${#record}; index++)); do
    character="${record:index:1}"
    if ((escaped)); then
      field+="$character"
      escaped=0
    elif [[ "$character" == "\\" ]]; then
      escaped=1
    elif [[ "$character" == ":" ]]; then
      nmcli_fields+=("$field")
      field=""
    else
      field+="$character"
    fi
  done
  ((escaped)) && field+="\\"
  nmcli_fields+=("$field")
}

# Asks for a password with a free-text prompt; prints it, fails when cancelled.
# The single row only carries the instruction: Shift+Enter returns what you
# typed, a plain Enter would pick the row itself and is treated as cancel.
prompt_password() {
  local hint="Type the password, then press Shift+Enter" text
  text="$(item "$hint" dialog-password | "$NIMLAUNCH_BIN" --dmenu -p "Password for $1:")" || return 1
  [[ -n "$text" && "$text" != "$hint" ]] || return 1
  printf '%s' "$text"
}

# Fills known_profiles[] with the names of saved Wi-Fi connections.
load_known_profiles() {
  local record name
  known_profiles=()
  while IFS= read -r record; do
    [[ "${record%%:*}" == "802-11-wireless" ]] || continue
    name="${record#*:}"
    name="${name//\\:/:}"
    name="${name//\\\\/\\}"
    known_profiles["$name"]=1
  done < <("$NMCLI_BIN" --terse --escape yes --fields TYPE,NAME connection show)
}

# Fills the network arrays from the current scan, keeping the strongest
# access point per SSID.
load_networks() {
  local record active signal security ssid index

  ssids=()
  signal_of=()
  securities=()
  labels=()
  icons=()
  actives=()
  declare -A position=()
  while IFS= read -r record; do
    parse_nmcli_record "$record"
    ((${#nmcli_fields[@]} >= 4)) || continue
    active="${nmcli_fields[0]}"
    signal="${nmcli_fields[1]}"
    security="${nmcli_fields[2]}"
    ssid="${nmcli_fields[3]}"
    [[ -n "$ssid" ]] || continue
    [[ "$security" == "--" ]] && security=""

    if [[ -n "${position[$ssid]+set}" ]]; then
      index="${position[$ssid]}"
      # Same network seen again: keep the stronger signal, never lose "in use".
      [[ "$active" == "*" ]] && actives[index]=1
      ((signal > signal_of[index])) || continue
    else
      index="${#ssids[@]}"
      position["$ssid"]="$index"
      actives[index]=0
      [[ "$active" == "*" ]] && actives[index]=1
    fi
    ssids[index]="$ssid"
    securities[index]="$security"
    signal_of[index]="$signal"
  done < <("$NMCLI_BIN" --terse --escape yes --fields IN-USE,SIGNAL,SECURITY,SSID device wifi list)

  for index in "${!ssids[@]}"; do
    labels[index]="${ssids[$index]} — ${signal_of[$index]}% ${securities[$index]:-open}"
    icons[index]="network-wireless"
    [[ -z "${securities[$index]}" ]] || icons[index]="network-wireless-encrypted"
    if ((actives[index])); then
      labels[index]="${labels[$index]} (connected)"
    fi
  done
}

# Connects to, or disconnects from, the network at index $1.
activate_network() {
  local ssid="${ssids[$1]}" security="${securities[$1]}" password output

  if ((actives[$1])); then
    if output="$("$NMCLI_BIN" connection down id "$ssid" 2>&1)"; then
      notify "Disconnected from $ssid"
    else
      notify "Could not disconnect: $output"
      return 1
    fi
    return 0
  fi

  notify "Connecting to $ssid…"
  if [[ -n "${known_profiles[$ssid]+set}" ]]; then
    output="$("$NMCLI_BIN" connection up id "$ssid" 2>&1)" || {
      notify "Could not connect to $ssid: $output"
      return 1
    }
  elif [[ -z "$security" ]]; then
    output="$("$NMCLI_BIN" device wifi connect "$ssid" 2>&1)" || {
      notify "Could not connect to $ssid: $output"
      return 1
    }
  else
    password="$(prompt_password "$ssid")" || return 0
    output="$("$NMCLI_BIN" device wifi connect "$ssid" password "$password" 2>&1)" || {
      # nmcli keeps the profile of a failed attempt; drop it so a retry asks again.
      "$NMCLI_BIN" connection delete id "$ssid" >/dev/null 2>&1 || true
      notify "Could not connect to $ssid: $output"
      return 1
    }
  fi
  notify "Connected to $ssid"
}

require_command "$NIMLAUNCH_BIN"
require_command "$NMCLI_BIN"

declare -a ssids=() securities=() labels=() icons=() actives=() signal_of=()
declare -A known_profiles=()

while true; do
  radio="$("$NMCLI_BIN" radio wifi)"
  if [[ "$radio" != enabled ]]; then
    selection="$(item "Turn Wi-Fi on" network-wireless |
      "$NIMLAUNCH_BIN" --dmenu -p "Wi-Fi is off:")" || cancelled $?
    if [[ "$selection" == "Turn Wi-Fi on" ]]; then
      "$NMCLI_BIN" radio wifi on
      notify "Turned on"
    fi
    exit 0
  fi

  load_known_profiles
  load_networks

  selection="$({
    for index in "${!labels[@]}"; do
      item "${labels[$index]}" "${icons[$index]}"
    done
    item "$RESCAN_LABEL" view-refresh
    item "Turn Wi-Fi off" network-wireless-disabled
  } | "$NIMLAUNCH_BIN" --dmenu -p "Wi-Fi:")" || cancelled $?
  [[ -n "$selection" ]] || exit 0

  if index="$(index_of "$selection" "${labels[@]}")"; then
    activate_network "$index"
    exit 0
  fi
  case "$selection" in
    "$RESCAN_LABEL")
      "$NMCLI_BIN" device wifi rescan >/dev/null 2>&1 || true
      sleep 3 # give the scan a moment, then show the menu again
      ;;
    "Turn Wi-Fi off")
      "$NMCLI_BIN" radio wifi off
      notify "Turned off"
      exit 0
      ;;
    *)
      printf 'nimlaunch_wifi: no such entry: %s\n' "$selection" >&2
      exit 1
      ;;
  esac
done
