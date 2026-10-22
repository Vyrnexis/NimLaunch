#!/usr/bin/env bash
# NimLaunch example: session and power menu.
#
# Lock, suspend, log out, reboot and shut down. Actions that end your session
# or turn the machine off ask for confirmation first; Esc backs out at any time.
#
# Dependencies: nimlaunch, systemctl and loginctl (systemd). Optional: a
#               compositor CLI for a clean log out (niri, hyprctl, swaymsg).
# Overrides:    NIMLAUNCH_LOCK_CMD="swaylock -f" replaces `loginctl lock-session`.
#
# Bind it in nimlaunch.toml:
#   [[shortcuts]]
#   group    = "sys"
#   label    = "Power Menu"
#   base     = "bash ~/.config/nimlaunch/scripts/nimlaunch_power.sh"
#   mode     = "shell"
#   run_mode = "spawn"
set -euo pipefail

NIMLAUNCH_BIN="${NIMLAUNCH_BIN:-nimlaunch}"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
LOGINCTL_BIN="${LOGINCTL_BIN:-loginctl}"

# Exits with an actionable message when a required command is unavailable.
require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'nimlaunch_power: required command not found: %s\n' "$command_name" >&2
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

# Asks for confirmation; succeeds only on "Yes". "No" is listed first so a
# stray Enter is harmless, and Esc counts as "No".
confirm() {
  local answer
  answer="$({
    item "No, cancel" dialog-cancel
    item "Yes, $1" dialog-ok
  } | "$NIMLAUNCH_BIN" --dmenu -p "Really $1?")" || return 1
  [[ "$answer" == "Yes, $1" ]]
}

# Ends the graphical session using the running compositor's own command, and
# falls back to logind for everything else.
log_out() {
  if [[ -n "${NIRI_SOCKET:-}" ]] && command -v niri >/dev/null 2>&1; then
    niri msg action quit --skip-confirmation
  elif [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] && command -v hyprctl >/dev/null 2>&1; then
    hyprctl dispatch exit
  elif [[ -n "${SWAYSOCK:-}" ]] && command -v swaymsg >/dev/null 2>&1; then
    swaymsg exit
  elif [[ -n "${XDG_SESSION_ID:-}" ]]; then
    "$LOGINCTL_BIN" terminate-session "$XDG_SESSION_ID"
  else
    "$LOGINCTL_BIN" terminate-user "$USER"
  fi
}

# Locks the screen with NIMLAUNCH_LOCK_CMD or logind's lock request.
lock_screen() {
  if [[ -n "${NIMLAUNCH_LOCK_CMD:-}" ]]; then
    bash -c "$NIMLAUNCH_LOCK_CMD"
  else
    "$LOGINCTL_BIN" lock-session
  fi
}

require_command "$NIMLAUNCH_BIN"
require_command "$SYSTEMCTL_BIN"
require_command "$LOGINCTL_BIN"

choice="$({
  item "Lock" system-lock-screen
  item "Suspend" system-suspend
  item "Log out" system-log-out
  item "Reboot" system-reboot
  item "Shut down" system-shutdown
} | "$NIMLAUNCH_BIN" --dmenu -p "Power:")" || cancelled $?

case "$choice" in
  "Lock") lock_screen ;;
  "Suspend") "$SYSTEMCTL_BIN" suspend ;;
  "Log out") if confirm "log out"; then log_out; fi ;;
  "Reboot") if confirm "reboot"; then "$SYSTEMCTL_BIN" reboot; fi ;;
  "Shut down") if confirm "shut down"; then "$SYSTEMCTL_BIN" poweroff; fi ;;
  "") ;;
  *)
    printf 'nimlaunch_power: no such action: %s\n' "$choice" >&2
    exit 1
    ;;
esac
