# NimLaunch (SDL2)

NimLaunch is a lightweight, keyboard-first launcher with fuzzy search, themes,
shortcuts, power actions, and optional Vim mode. This build uses SDL2 for native
Wayland/X11 support (no Xlib/Xft) with GPU-backed compositing.

![NimLaunch screenshot](screenshots/NimLaunch-SDL2.gif)

## Features
- Fuzzy app search with typo tolerance; MRU bias for empty query.
- Prefix commands: `:t` themes, `:c` config files, `:s` file search, `:r` shell run,
  `!` shorthand, and custom shortcut groups (default power alias `:p`).
- Vim mode (optional): hjkl navigation, `/ : !` command bar, `gg/G`, `:q`, etc.
- Themes with live preview; clock overlay; status/toast messages.
- Icons from `.desktop` files (PNG/SVG) with a fallback alias map; icons can be
  toggled off in config.
- Window opacity setting (0.1–1.0) via SDL2 when supported.

## Install
Grab a compiled binary from the releases:
https://github.com/DrunkenAlcoholic/NimLaunch-SDL2/releases

## Build
> [!NOTE]
> Deps: `nim >= 2.0`, `sdl2`, `sdl2_ttf`, `sdl2_image`, `librsvg`, plus a font
> (default `ttf-dejavu`).

> [!TIP]
> Install a nerd font and change prompt/cursor characters for a nicer effect.
> ```toml
> [font]
> fontname = "MesloLGL Nerd Font Propo:size=16"
>
> [input]
> prompt = " "
> cursor = " "
> ```

### Archlinux
```bash
sudo pacman -S sdl2 sdl2_ttf sdl2_image librsvg ttf-dejavu --needed
```

### Ubuntu
```bash
sudo apt install libsdl2-dev libsdl2-ttf-dev libsdl2-image-dev librsvg2-bin fonts-dejavu
```

### OpenSUSE
```bash
sudo zypper install SDL2 SDL2_ttf SDL2_image-devel rsvg-convert dejavu-fonts
```

### Build
```bash
git clone https://github.com/Vyrnexis/NimLaunch-SDL2.git
cd NimLaunch-SDL2
```

```bash
nimble release   # or: nimble debug
```

For a more portable build (e.g., to run on other distros), use:

```bash
nimble zigit
```

or

```bash
nim c -d:release --opt:speed -o:./bin/nimlaunch src/main.nim
```

```bash
./bin/nimlaunch
```

Place the binary (`nimlaunch`) somewhere on your `PATH` (e.g., `~/.local/bin`) and
bind a hotkey to launch it. The TOML config is auto-generated on first run.

## Wayland/X11
Runs natively on both via SDL2 (no XWayland required on Wayland). Borderless
window like the original. GPU compositing handles fills/icons/text blits; SDL_ttf
still rasterizes glyphs in software.

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
| `:<group>` | `:p lock` | Run grouped shortcuts (e.g., `:p` for power) |

## Configuration
The config lives at `~/.config/nimlaunch/nimlaunch.toml`. It is auto-generated on
first run, shipping with sensible defaults and a long list of themes.

```toml
[window]
width = 500
opacity = 1.0          # 0.1–1.0; may be ignored on some Wayland setups
max_visible_items = 10
center = true
position_x = 20
position_y = 500
vertical_align = "one-third"
display = 0

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

[[groups]]
name = "power"
query_mode = "filter"

[[shortcuts]]
prefix = ":g"            # write "g", ":g", or "g:" — all map to :g in the UI
label  = "Search Google: "
base   = "https://www.google.com/search?q={query}"
mode   = "url"            # other options: "shell", "file"

[power]
prefix = ":p"            # default alias for the power group

[[shortcuts]]
group     = "power"
label     = "Shutdown"
base      = "systemctl poweroff"
mode      = "shell"
run_mode  = "spawn"
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

`vertical_align` only affects the Y position when `center = true`: `top` pins the
window toward the top, `center` centers it vertically, and `one-third` places it
about 1/3 down the display.

`display` selects which monitor to use when `center = true` (0 = primary, 1 = second, etc.).

## Shortcuts (how they work)
A shortcut is a template you trigger with `:`. The text you type after the
prefix becomes `{query}`.

Example: typing `:g cats` uses the shortcut below and opens Google with "cats".

```toml
[[shortcuts]]
prefix = "g"
label  = "Search Google: "
base   = "https://www.google.com/search?q={query}"
mode   = "url"
```

Shortcut fields:
- `prefix`: what you type after `:` (e.g., `g`, `note`, `rg`).
- `label`: text shown in the results list.
- `base`: template command/URL/path. Use `{query}` where the input should go.
- `mode`:
  - `url`: opens the URL in a browser (query is URL-encoded).
  - `shell`: runs a shell command (query is safely quoted).
  - `file`: opens a file or folder (expands `~`).

If `group` is set, the entry does not need a `prefix` because the group name
becomes the prefix (e.g., `:dev`, `:sys`, `:p`).

## Groups (powerful shortcuts)
Groups let you collect shortcuts under a shared prefix like `:dev` or `:p`.
Each group has a `query_mode`:
- `filter`: your input filters the list by label (safe for power/system).
- `pass`: your input is passed to each shortcut as `{query}` (great for search/dev).

Filter example (menu-style):
```toml
[[groups]]
name = "sys"
query_mode = "filter"

[[shortcuts]]
group    = "sys"
label    = "Lock"
base     = "loginctl lock-session"
mode     = "shell"
run_mode = "spawn"

[[shortcuts]]
group    = "sys"
label    = "Suspend"
base     = "systemctl suspend"
mode     = "shell"
run_mode = "spawn"
```

Usage: `:sys` shows the list, `:sys su` narrows to Suspend.

Pass-through example (multi-tool search):
```toml
[[groups]]
name = "dev"
query_mode = "pass"

[[shortcuts]]
group = "dev"
label = "Issues: "
base  = "gh issue list --search {query}"
mode  = "shell"

[[shortcuts]]
group = "dev"
label = "Docs: "
base  = "https://docs.example.com/search?q={query}"
mode  = "url"
```

Usage: `:dev crash` shows both results using \"crash\" as the query.

### Power group
The power menu is just a group named `power`. The `:p` prefix is an alias
controlled by `[power].prefix`.

## Vim mode
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
- `:t` shows the theme list; move with Up/Down to preview instantly and press
  Enter to keep the selection. Leaving `:t` without pressing Enter restores the
  theme you started with.
- Add or edit `[[themes]]` blocks in the TOML to create your own colour schemes.

Popular presets include Nord, Catppuccin (all flavours), Ayu, Dracula, Gruvbox,
Solarized, Tokyo Night, Monokai, Palenight, and more.
