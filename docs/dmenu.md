# Dmenu Mode

`nimlaunch --dmenu` turns NimLaunch into a generic picker. It does not scan
applications: it reads rows from standard input, shows them in the usual window
and theme, and prints the chosen row on standard output. That makes it the
building block for audio, Wi-Fi, power, clipboard and window menus; the
[example scripts](../examples/README.md) are all built on it.

```bash
printf 'one\ntwo\nthree\n' | nimlaunch --dmenu
```

## Usage

```
nimlaunch --dmenu [-p PROMPT] [--dry-run] [-c CONFIG]
```

| Option | Meaning |
|--------|---------|
| `--dmenu` | Read rows from stdin and print the selection |
| `-p`, `--prompt TEXT` | Replace the configured `[input] prompt` for this run; only valid with `--dmenu` |
| `-c`, `--config PATH` | Use another config file (theme, font, width, icons) |
| `--dry-run` | Accepted for consistency; the selection is printed once, as usual |

Dmenu mode uses your normal configuration, so it follows your theme, font and
window settings. It skips the launcher's single-instance toggle: a dmenu run
neither closes nor is closed by the regular launcher.

## Input format

One row per line. Empty lines are ignored, a trailing carriage return is
stripped, and duplicate rows stay separate, in their original order.

### Icons

Add an icon with rofi's row option syntax: the label, a NUL byte, then
`icon` and the unit separator `\x1f` followed by an icon name or path.

```bash
printf 'Firefox\0icon\x1ffirefox\nNotes\0icon\x1f/home/me/notes.svg\n' | nimlaunch --dmenu
```

- A **name** is looked up in your icon theme, like desktop-entry icons.
- A **path** is anything containing a `/` (use an absolute one) that points to a
  PNG, SVG or XPM file; the extension may be left off. JPEG is not supported.
- A row with an unknown icon is shown without one. `[icons] enabled = false`
  hides all icons.
- Only `icon` is understood; the label is always the text before the NUL.

Use `printf`, not `echo -e`, and never put a NUL in the label itself. Keep
labels to a single line: a newline would start a new row.

## Output and exit codes

| Result | stdout | Exit status |
|--------|--------|-------------|
| Row chosen with `Enter` | The label, once, followed by a newline (icon data is not printed) | `0` |
| Free text accepted (see below) | The typed text and a newline | `0` |
| `Esc`, or the window loses focus | nothing | `1` |
| Bad command line | nothing; an error goes to stderr | `1` |

So `choice="$(… | nimlaunch --dmenu)" || exit 0` is the idiom for "do nothing
when cancelled". An empty row list is allowed: the window shows "No matches"
and still accepts free text.

## Free text

A script often needs a value that is not in the list: a note, a password, an
expression, a new name. Dmenu mode returns what you typed in two cases:

- **`Shift+Enter`** always returns the typed text, whatever the list shows.
- **`Enter` while the list says "No matches"** returns it too.

Nothing is returned for an empty query. Because a plain `Enter` picks the
highlighted row when something matches, scripts that want text show one
instruction row and tell the user to press `Shift+Enter`:

```bash
hint="Type your note, then press Shift+Enter"
note="$(printf '%s\0icon\x1f%s\n' "$hint" dialog-information |
  nimlaunch --dmenu -p "Note:")" || exit 0
[[ -n "$note" && "$note" != "$hint" ]] || exit 0
printf '%s\n' "$note" >> ~/notes.txt
```

The output of free text looks exactly like a chosen row, so compare it with
your known labels before acting on it, and treat anything else as input. The
[Wi-Fi script](../examples/scripts/nimlaunch_wifi.sh) uses this for passwords
and the [calculator](../examples/scripts/nimlaunch_calculator.sh) for
expressions.

## Matching

Matching is case-insensitive and tolerant, so users rarely type a full label.
From best to weakest, a query matches a row when it is:

1. the **whole label** or a **prefix** of it,
2. a **substring**, ranked higher at the start of a word,
3. the **initials** of its words: `vsc` finds "Visual Studio Code",
4. its **letters in order**: `tdsk` finds "Telegram Desktop",
5. a substring with **one typo** (a wrong, missing, extra or swapped letter, for
   queries of three or more characters): `firfox` finds "Firefox".

Matched characters are highlighted. Better matches come first and ties keep
the input order; with an empty query every row is shown in input order, so
sort the list the way you want it to appear.

## `--dry-run`

`--dry-run` is the launcher's "print instead of execute" switch. In dmenu mode
there is nothing to execute, so it makes no difference: the selection is
printed once and the exit status is the same. It is safe to leave in test
invocations.

## Writing your own script

The pattern is always the same: build rows, run `nimlaunch --dmenu`, map the
answer back to something to act on.

```bash
#!/usr/bin/env bash
set -euo pipefail

NIMLAUNCH_BIN="${NIMLAUNCH_BIN:-nimlaunch}"

ids=(work home)
labels=("Work profile" "Home profile")

choice="$(
  for label in "${labels[@]}"; do
    printf '%s\0icon\x1f%s\n' "$label" "user-identity"
  done | "$NIMLAUNCH_BIN" --dmenu -p "Profile:"
)" || exit 0   # Esc: nothing to do

for index in "${!labels[@]}"; do
  if [[ "${labels[$index]}" == "$choice" ]]; then
    switch-profile "${ids[$index]}"
    exit 0
  fi
done
echo "unknown choice: $choice" >&2
exit 1
```

Habits worth copying from the examples:

- Map the chosen label back to an **id by position**; do not parse ids out of
  the label. Make labels unique first (append the id when two rows collide).
- Treat exit status `1` as cancel, and exit `0`. Let other failures through.
- Make binaries overridable (`NIMLAUNCH_BIN`) so you can test with a fake.
- Check dependencies up front and exit `127` with a message saying what to install.
- For a submenu or a "← Back" row, just call `nimlaunch --dmenu` again from a
  function; when it returns you are back in the parent.

[`nimlaunch_showcase.sh`](../examples/scripts/nimlaunch_showcase.sh) is written
as a tutorial and starts with copy-ready helpers: `have_command`, `item` (one
row with an icon), `menu`, `confirm` (yes/no) and `prompt_text` (free text),
followed by demos of nested menus, notes, an emoji picker and fuzzy matching.

To test a script without a window, put a fake on `NIMLAUNCH_BIN` that reads
stdin and prints the answer you want, or exits `1` to simulate Esc.

## Hooking scripts into NimLaunch

Expose a script from the main launcher with a shortcut, then type its group:

```toml
[[shortcuts]]
group    = "scripts"
label    = "Audio Output"
base     = "bash ~/.config/nimlaunch/scripts/nimlaunch_audio.sh"
mode     = "shell"
run_mode = "spawn"
```

`:scripts audio` now opens the audio picker. Use `run_mode = "spawn"` so no
terminal window appears. See [Groups and Shortcuts](groups-and-shortcuts.md).
Scripts also work from a compositor key binding, with no config at all.

## Example scripts

All scripts live in [`examples/scripts/`](../examples/scripts); installation,
dependencies and conventions are in [examples/README.md](../examples/README.md).

| Script | Does | Demonstrates |
|--------|------|--------------|
| [`nimlaunch_showcase.sh`](../examples/scripts/nimlaunch_showcase.sh) | Guided tour with no dependencies | Helpers, nested menus, free text, confirmation |
| [`nimlaunch_audio.sh`](../examples/scripts/nimlaunch_audio.sh) | Default audio output (`wpctl` or `pactl`) | Parsing command output |
| [`nimlaunch_bluetooth.sh`](../examples/scripts/nimlaunch_bluetooth.sh) | Power, connect, disconnect (`bluetoothctl`) | State in labels |
| [`nimlaunch_clipboard.sh`](../examples/scripts/nimlaunch_clipboard.sh) | History for cliphist or Klipper, clear with confirmation | Backend detection |
| [`nimlaunch_power.sh`](../examples/scripts/nimlaunch_power.sh) | Lock, suspend, log out, reboot, shut down | Confirmation submenu |
| [`nimlaunch_steam.sh`](../examples/scripts/nimlaunch_steam.sh) | Installed Steam games with icons | Icon paths |
| [`nimlaunch_wifi.sh`](../examples/scripts/nimlaunch_wifi.sh) | Networks via `nmcli`, password prompt | Free text (Shift+Enter) |
| [`nimlaunch_windows.sh`](../examples/scripts/nimlaunch_windows.sh) | Window switcher for niri, Hyprland, sway, X11 | Compositor detection |
| [`nimlaunch_calculator.sh`](../examples/scripts/nimlaunch_calculator.sh) | Calculator with history, copies the result | Menu loop, validation |
| [`nimlaunch_screenshot.sh`](../examples/scripts/nimlaunch_screenshot.sh) | Area, screen or window capture | Toolchain selection |

## Related Documentation

- [Configuration](configuration.md)
- [Groups and Shortcuts](groups-and-shortcuts.md)
- [Themes](themes.md)
- [Examples](../examples/README.md)
