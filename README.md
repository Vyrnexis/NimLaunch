# NimLaunch (SDL2)

NimLaunch is a lightweight, keyboard-first launcher with fuzzy search, themes, shortcuts, power actions, and Vim mode. This build uses SDL2 for native Wayland/X11 support (no Xlib/Xft), with GPU-backed compositing for rendering.

## Features
- Fuzzy app search with typo tolerance; MRU bias for empty query.
- Prefix commands: `:t` themes, `:c` config files, `:s` file search, `:p` power actions, `:r` shell run, `!` shorthand, custom shortcuts.
- Vim mode (optional): hjkl navigation, `/ : !` command bar, `gg/G`, `:q`, etc.
- Themes with live preview; clock overlay; status/toast messages.
- Icons from `.desktop` files (PNG/SVG) with a fallback alias map; icons can be toggled off in config.

## Install
Download the compiled binary in the release page
https://github.com/DrunkenAlcoholic/NimLaunch-SDL2/releases

## Build (Arch examples)
Deps: `nim >= 2.0`, `sdl2`, `sdl2_ttf`, `sdl2_image`, `librsvg` (`rsvg-convert`), plus a font (default `ttf-dejavu`).
```bash
sudo pacman -S sdl2 sdl2_ttf sdl2_image ttf-dejavu librsvg --needed
```
```bash
git clone https://github.com/DrunkenAlcoholic/NimLaunch-SDL2.git
cd NimLaunch-SDL2
```
```bash
nimble release
```
or
```bash
nim c -d:release --opt:speed -o:./bin/nimlaunch src/main.nim
```

```bash
cd bin
./bin/nimlaunch
```
it is Suggest to place the binary(nimlaunch) in one of your enviroment PATHS e.g ~/.local/bin and set a keybind to nimlauch, the toml config will be automatically genrated on first run.

## Wayland/X11
Runs natively on both via SDL2 (no XWayland required on Wayland). Borderless window like the original. GPU compositing handles fills/icons/text blits; SDL_ttf still rasterizes glyphs in software.

## Quick Reference

Every query updates the result list in real time. These shortcuts cover the
core workflow:

| Trigger | Context | Effect |
| ------- | ------- | ------ |
| Type text | Normal | Fuzzy-search applications; top hit updates instantly |
| Enter | Normal or command bar | Launch the highlighted entry immediately |
| Esc | Command bar | Close the bar, keep the narrowed results selected |
| Esc | Normal | Exit NimLaunch |
| ↑ / ↓ / PgUp / PgDn / Home / End | Any | Navigate the results list |
| `/` | Normal | Toggle the command bar (restores previous `/` search) |
| `:` / `!` | Normal | Open the bar primed for a prefix or `!` command |
| Ctrl+U | Command bar | Clear the current query |
| Ctrl+H / Backspace | Command bar | Delete one character (closes the bar when empty) |

### Built-in prefixes

| Prefix | Example | Description |
| ------ | ------- | ----------- |
| *none* | `fire` | Regular app search; rankings favour prefixes and recent launches |
| `:t` | `:t nord` | Browse themes; Up/Down preview, Enter to keep selection |
| `:s` | `:s notes` | Search files (`fd` → `locate` → bounded `$HOME` walk) |
| `:c` | `:c sway` | Match files inside `~/.config` and open with the default handler |
| `:r` | `:r htop` | Run a shell command inside your preferred terminal |
| `!` | `!htop` | Shorthand for `:r` without the colon |
| `:p` | `:p lock` | Show configured power/system actions (label filter) |

`:s` results render as `filename — /path/to/dir` and open with the system
handler. Power actions can either spawn in the background or run inside your
configured terminal depending on their `mode`.

### Vim mode

Enable by setting `[input].vim_mode = true` in `~/.config/nimlaunch/nimlaunch.toml`.
Vim mode adds:

| Trigger | Effect |
| ------- | ------ |
| `h` / `j` / `k` / `l` | Move cursor left/down/up/right (acts on the result list) |
| `gg` / `Shift+G` | Jump to top / bottom of the list |
| `/` | Toggle the command bar; reopening restores the last slash search |
| `:` / `!` | Open the command bar primed for colon or bang commands |
| `Enter` | Launch the highlighted entry immediately |
| `Esc` | Leave command mode but keep the current filtered results |
| `:q` (then Enter) | Quit NimLaunch from the command bar |
| `Ctrl+H` | Delete one character (when empty, closes the bar) |
| `Ctrl+U` | Clear the entire command |


## Configuration

The config lives at `~/.config/nimlaunch/nimlaunch.toml`. It is auto-generated
on first run, shipping with sensible defaults and a long list of themes.

```toml
[window]
width = 500
max_visible_items = 10
center = true
vertical_align = "one-third"

[font]
fontname = "Noto Sans:size=12"

[input]
prompt   = "> "
cursor   = "_"
vim_mode = false

[terminal]
program = "kitty"

[border]
width = 2

[icons]
enabled = true                    # Set to false to hide icons in the list

[[shortcuts]]
prefix = ":g"            # write "g", ":g", or "g:" — all map to :g in the UI
label  = "Search Google: "
base   = "https://www.google.com/search?q={query}"
mode   = "url"            # other options: "shell", "file"

[power]
prefix = ":p"            # write with or without ':'; the UI trigger remains :p

[[power_actions]]
label   = "Shutdown"
command = "systemctl poweroff"
mode    = "spawn"         # or "terminal"
stay_open = false

[[themes]]
name                = "Nord"
bgColorHex          = "#2E3440"
fgColorHex          = "#D8DEE9"
highlightBgColorHex = "#88C0D0"
highlightFgColorHex = "#2E3440"
borderColorHex      = "#4C566A"
matchFgColorHex     = "#f8c291"

[theme]
last_chosen = "Nord"
```

Shortcut and power prefixes are stored case-insensitively without leading/trailing
colons, so feel free to write `g:`, `:g`, or just `g`. At runtime you still press
`:` followed by the keyword (for example `:g search terms`).

### Custom shortcuts

Add more `[[shortcuts]]` blocks:

```toml
[[shortcuts]]
prefix = "yt:"
label  = "Search YouTube: "
base   = "https://www.youtube.com/results?search_query={query}"

[[shortcuts]]
prefix = "rg"
label  = "grep repo: "
base   = "cd ~/code && rg {query}"
mode   = "shell"

[[shortcuts]]
prefix = ":note"
label  = "Open note: "
base   = "~/notes/{query}.md"
mode   = "file"
```

`mode = "shell"` quotes the query for a shell command, while `mode = "file"`
expands `~` and launches the path with your default handler. If the file is
missing, NimLaunch stays open so you can adjust the query.


### Power actions

`[[power_actions]]` entries expose shutdown/reboot/lock/etc. commands behind a
keyword (default `:p`). Each action supports:

- `label` – text shown in the list.
- `command` – shell command executed via `/bin/sh -c`.
- `mode` – `spawn` (background) or `terminal` (run inside the configured terminal).
- `stay_open` – keep NimLaunch open after execution.

Set `[power].prefix = "x"` (or clear it) to change or disable the trigger.


## File discovery & caching

NimLaunch indexes `.desktop` files from:

1. `~/.local/share/applications`
2. `~/.local/share/flatpak/exports/share/applications`
3. `/usr/share/applications`
4. `/var/lib/flatpak/exports/share/applications`

Metadata is cached at `~/.cache/nimlaunch/apps.json`. The cache is invalidated
automatically when source directories change. Entries flagged as `NoDisplay=true`,
`Terminal=true`, or belonging solely to the `Settings` / `System` categories are
skipped so the list remains focused on launchable apps.

Recent launches are tracked in `~/.cache/nimlaunch/recent.json`, ensuring the
empty-query view always surfaces the last applications you opened.


## Themes

- `:t` shows the theme list; move with Up/Down to preview instantly and press Enter to keep the selection.
  Leaving `:t` without pressing Enter restores the theme you started with.
- Add or edit `[[themes]]` blocks in the TOML to create your own colour schemes.

Popular presets include Nord, Catppuccin (all flavours), Ayu, Dracula, Gruvbox,
Solarized, Tokyo Night, Monokai, Palenight, and more.

---
