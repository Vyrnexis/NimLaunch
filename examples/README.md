# Examples

A ready-to-use configuration and a set of `nimlaunch --dmenu` scripts. Copy what
you like and edit it; everything here is meant to be read.

| Path | What it is |
|------|------------|
| [`nimlaunch.toml`](nimlaunch.toml) | A commented showcase config: URL, shell, file and terminal shortcuts, filter and pass groups, `stay_open`, a custom-theme template, and an entry for every script below |
| [`scripts/`](scripts) | Ten self-contained dmenu scripts (table below) |

## Install

```bash
# Config (back up your own first, this replaces it)
mkdir -p ~/.config/nimlaunch
cp examples/nimlaunch.toml ~/.config/nimlaunch/nimlaunch.toml

# Scripts
mkdir -p ~/.config/nimlaunch/scripts
cp examples/scripts/*.sh ~/.config/nimlaunch/scripts/
chmod +x ~/.config/nimlaunch/scripts/*.sh
```

Then type `:scripts` in NimLaunch for the list, or `:sys`, `:media`, `:svc`.
`nimlaunch --config examples/nimlaunch.toml --list-themes` checks that the file
parses without starting the launcher.

The scripts do not depend on the config: run one from a terminal, or bind it
to a key in your compositor, for example `bash ~/.config/nimlaunch/scripts/nimlaunch_windows.sh`.

## The scripts

Start with the showcase: it needs nothing but `nimlaunch`, bash and coreutils,
and is written to be read top to bottom.

| Script | What it does | Needs | Shows |
|--------|--------------|-------|-------|
| [`nimlaunch_showcase.sh`](scripts/nimlaunch_showcase.sh) | A tour of dmenu mode: nested menus, notes, confirmation, emoji picker, fuzzy tips, launcher for the other scripts | nothing extra | Reusable helpers (`menu`, `confirm`, `prompt_text`, `have_command`), Back entries, free text |
| [`nimlaunch_audio.sh`](scripts/nimlaunch_audio.sh) | Choose the default audio output; the current one is marked | `wpctl` (preferred) or `pactl` | Parsing tool output into rows, mapping labels back to ids |
| [`nimlaunch_bluetooth.sh`](scripts/nimlaunch_bluetooth.sh) | Power toggle, paired devices with connection state, connect / disconnect | `bluetoothctl` | Dynamic first row, state in labels |
| [`nimlaunch_clipboard.sh`](scripts/nimlaunch_clipboard.sh) | Clipboard history picker with a confirmed "Clear history" row | `cliphist` + `wl-copy` (Wayland) or Klipper + `qdbus` (KDE) | Backend auto-detection, a destructive entry behind a confirmation |
| [`nimlaunch_power.sh`](scripts/nimlaunch_power.sh) | Lock, suspend, log out, reboot, shut down | `systemctl`, `loginctl` | Confirmation submenu for destructive actions |
| [`nimlaunch_steam.sh`](scripts/nimlaunch_steam.sh) | Launch installed Steam games with their icons | `steam`, `awk` | Reading `libraryfolders.vdf` and `appmanifest_*.acf`, icon paths |
| [`nimlaunch_wifi.sh`](scripts/nimlaunch_wifi.sh) | Networks with signal and security; connect, rescan, toggle Wi-Fi | `nmcli` | **Free-text input**: type the password and press Shift+Enter |
| [`nimlaunch_windows.sh`](scripts/nimlaunch_windows.sh) | Window switcher with app icons | niri, Hyprland or sway (each with `jq`), or `wmctrl` on X11 | Compositor detection, JSON to rows |
| [`nimlaunch_calculator.sh`](scripts/nimlaunch_calculator.sh) | Interactive calculator with history; picking a result copies it | `bc`; `wl-copy` or `xclip` | A menu loop, input validation, Enter-on-no-match |
| [`nimlaunch_screenshot.sh`](scripts/nimlaunch_screenshot.sh) | Area, full screen or window, to the clipboard or a file | niri, or `grim` + `slurp` (Wayland), or `maim` (X11) | Choosing a toolchain at runtime; also scriptable: `area clipboard` |

All scripts need `bash` 4.4 or newer. `notify-send` is optional everywhere.

## Conventions

The scripts follow one pattern, so you can lift pieces into your own:

- `#!/usr/bin/env bash` and `set -euo pipefail`.
- Binaries are overridable (`NIMLAUNCH_BIN=./bin/nimlaunch bash nimlaunch_audio.sh`)
  and a missing dependency exits with status 127 and a message saying what to install.
- Esc (NimLaunch exits with status 1) ends the script quietly with status 0.
- Rows carry an icon through `label\0icon\x1fname`; the chosen row is mapped back
  to an id by index, never by parsing the label.
- Free-text prompts use a single instruction row and Shift+Enter.

See [docs/dmenu.md](../docs/dmenu.md) for the input and output format.
