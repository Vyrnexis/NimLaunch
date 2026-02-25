# NimLaunch (SDL2)

NimLaunch is a keyboard-first launcher with fuzzy app search, themes, shortcuts,
power actions, and optional Vim mode. It uses SDL2 for native Wayland/X11
support (no Xlib/Xft) with GPU-backed compositing.

![NimLaunch screenshot](screenshots/NimLaunch-SDL2.gif)

## Features
- Fuzzy app search with typo tolerance; MRU bias for empty query.
- Prefix commands: `:t`, `:c`, `:s`, `:r`, `!`, and custom groups (default alias `:p`).
- Vim mode (optional): `j/k` navigation, `/ : !` command bar, `gg/G`, `:q`, etc.
- Themes with live preview, status/toast messages, and clock overlay.
- Icons from `.desktop` files (PNG/SVG) with fallback alias mapping; can be disabled.
- Window opacity setting (0.1–1.0) via SDL2 when supported.

## Install
Grab a compiled binary from the releases:
https://github.com/Vyrnexis/NimLaunch/releases

## Build
> [!NOTE]
> Deps: `nim >= 2.0`, `sdl2`, `sdl2_ttf`, `sdl2_image`, `librsvg`, plus a font
> (default `ttf-dejavu`).
>
> Optional but recommended for faster `:s` file search: `fd` and/or `locate`.

### Archlinux
```bash
sudo pacman -S sdl2 sdl2_ttf sdl2_image librsvg ttf-dejavu --needed
```

### Ubuntu
```bash
sudo apt install libsdl2-dev libsdl2-ttf-dev libsdl2-image-dev librsvg2-bin fonts-dejavu-core
```

### OpenSUSE
```bash
# Tumbleweed / Slowroll package names:
sudo zypper install SDL2-devel SDL2_ttf-devel SDL2_image-devel librsvg-tools dejavu-fonts
```
If you are on Leap and a name differs, run `zypper search sdl2` and `zypper search rsvg`
to find the matching package variant.

### Build from source
```bash
git clone https://github.com/Vyrnexis/NimLaunch.git
cd NimLaunch
```

```bash
nimble -y nimDebug    # debug build -> ./bin/nimlaunch
nimble -y nimRelease  # release build(custom flags) -> ./bin/nimlaunch
```

For a more portable release build (via Zig/clang), use:

```bash
nimble -y zigDebug    # debug build -> ./bin/nimlaunch
nimble -y zigRelease  # release build(custom flags) -> ./bin/nimlaunch
```

Or compile directly with Nim:

```bash
nim c -d:release --opt:speed -o:./bin/nimlaunch src/main.nim
```

```bash
./bin/nimlaunch      # from task builds above
```

Place the binary (`nimlaunch`) somewhere on your `PATH` (e.g., `~/.local/bin`) and
bind a hotkey to launch it. The TOML config is auto-generated on first run.

## Wayland/X11
Runs natively on both via SDL2 (no XWayland required on Wayland). Borderless
window like the original. GPU compositing handles fills/icons/text blits; SDL_ttf
still rasterizes glyphs in software.

## Troubleshooting
- Build fails with `cannot open .../src/nimlaunch.nim`: build from project root,
  or run `nimble -y nimDebug` / `nimble -y nimRelease` tasks.
- `:s` search feels slow: install `fd` and/or `locate` so search avoids the
  slower `$HOME` fallback walk.
- Icons are missing for SVG apps: ensure `rsvg-convert` is installed
  (`librsvg2-bin` on Ubuntu, `librsvg-tools` on openSUSE).
- Text looks wrong or too small: set `[font].fontname` to an installed font and
  size (e.g., `"Dejavu:size=16"`).
- Theme changes do not persist: verify `~/.config/nimlaunch/nimlaunch.toml`
  is writable.

## Quick Reference
Core controls:

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
Config path: `~/.config/nimlaunch/nimlaunch.toml` (auto-generated on first run).

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

`vertical_align` only affects Y when `center = true` (`top`, `center`, `one-third`).
`display` selects the monitor index when centered (`0` = primary, `1` = second, ...).

## Shortcuts (how they work)
A shortcut is a `:`-triggered template. Text after the prefix is inserted as
`{query}`.

Fields:
- `prefix`: what you type after `:` (e.g., `g`, `note`, `rg`).
- `label`: text shown in the results list.
- `base`: template command/URL/path. Use `{query}` where the input should go.
- `mode = "url"`: opens URL (query is URL-encoded).
- `mode = "shell"`: runs shell command (query is safely quoted).
- `mode = "file"`: opens file/folder (`~` expands).

If `group` is set, `prefix` is optional because the group name becomes the
prefix (e.g., `:dev`, `:sys`, `:p`).

## Groups (powerful shortcuts)
Groups collect shortcuts under one prefix (`:dev`, `:sys`, `:p`).
- `query_mode = "filter"`: query filters by label.
- `query_mode = "pass"`: query is passed as `{query}` to each entry.

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

### Power group
The power menu is a normal group named `power`; `:p` is an alias from
`[power].prefix`.

## Vim mode
Enable with `[input].vim_mode = true` in `~/.config/nimlaunch/nimlaunch.toml`.
General controls in Quick Reference still apply; Vim mode adds:

| Trigger | Effect |
| ------- | ------ |
| `j` / `k` | Move selection down / up |
| `h` | Delete one character from the input |
| `l` | Launch the highlighted entry |
| `gg` / `Shift+G` | Jump to top / bottom of the list |
| `/` | Open the command bar for search |
| `:` | Open the command bar for prefix commands |
| `!` | Open the command bar for run commands (`:r` shorthand) |
| `Esc` | Close the command bar and keep current filtered results |
| `:q` (then Enter) | Quit NimLaunch from the command bar |

## File discovery & caching
NimLaunch indexes `.desktop` files from:

1. `~/.local/share/applications`
2. `~/.local/share/flatpak/exports/share/applications`
3. each `<dir>/applications` from `$XDG_DATA_DIRS` (defaults to `/usr/local/share:/usr/share`)
4. `/var/lib/flatpak/exports/share/applications`

App metadata is cached in `~/.cache/nimlaunch/apps.json` and invalidated when
source dirs change. Entries with `NoDisplay=true`, `Hidden=true`,
`Terminal=true`, or exact `Settings` / `System` categories are skipped.
Recent launches are tracked in `~/.cache/nimlaunch/recent.json`.

## Themes
- Use `:t` to browse themes, preview with Up/Down, and press Enter to keep.
- Leaving `:t` without Enter restores the previous theme.
- Add/edit `[[themes]]` in TOML to create custom palettes.
