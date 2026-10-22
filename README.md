# NimLaunch (SDL3)

The lightning fast original X11 only version is available here:

https://github.com/Vyrnexis/NimLaunch-X11

NimLaunch is a keyboard-first launcher for Wayland and X11 built on SDL3. It
covers three workflows:

- launching applications from `.desktop` entries
- configurable URL, shell and file shortcuts
- generic stdin-driven selection through `--dmenu`

SDL3 provides native Wayland and X11 support (no XWayland needed) with
GPU-backed compositing; icons load through `SDL3_image`.

![NimLaunch screenshot](screenshots/NimLaunch-SDL2.gif)

## Features
- **Fuzzy matching, ranked by tier:** exact > prefix > word-boundary substring > substring > initials (`vsc` → Visual Studio Code) > letters in order (`ffx` → Firefox) > one typo (queries of 3+ characters). Matched letters are highlighted.
- **Searches more than names:** an app's GenericName and Keywords are matched too (`browser` finds Firefox), ranked below name matches. Recent and frequently launched apps get a boost.
- **Terminal apps:** `.desktop` entries with `Terminal=true` are listed and open in your terminal (`[terminal] program`, then `$TERMINAL`, then a built-in fallback list).
- **Desktop actions:** apps that expose secondary launch actions list them.
- **Prefix commands:** `:t` themes, `:c` config files, `:s` file search, `:r` / `!` run a command, plus your own shortcuts and groups.
- **Toggle hotkey:** launching NimLaunch while it is already open closes the running instance.
- **Themes:** 84 built-in themes with live preview (`:t`); add or override themes with `[[themes]]`. The chosen theme persists in the cache directory.
- **Icons:** PNG/SVG icons follow your icon theme (`ICON_THEME`, gsettings, GTK `settings.ini`) and its `Inherits` chain, then hicolor, pixmaps and other installed themes. Decoding runs on a background worker.
- **Fast startup:** parsed `.desktop` entries are cached and reused until the application directories, locale/`PATH`, or `TryExec` programs change.
- **Vim mode (optional):** `j/k`, `gg/G`, `/ : !` command bar, `:q`.
- **`--dmenu` mode:** pick from stdin items, with `rofi`-style `\0icon\x1f` icon metadata and Shift+Enter to return typed text.
- Window opacity (0.1–1.0), long labels truncated with `…`, and an input line that scrolls to keep the cursor visible.

## Documentation
- [Configuration](docs/configuration.md): every config key, defaults, and file locations
- [Groups and Shortcuts](docs/groups-and-shortcuts.md)
- [Themes](docs/themes.md): built-in gallery, custom themes, persistence
- [Dmenu Mode](docs/dmenu.md)
- [Examples](examples/README.md): sample config and `--dmenu` scripts

## Install
Grab a compiled binary from the [releases page](https://github.com/Vyrnexis/NimLaunch/releases).

**Arch Linux (AUR)**
You can install NimLaunch from the Arch User Repository using `yay` or `paru`:
```bash
# For the pre-built binary
yay -S nimlaunch-bin
# OR
paru -S nimlaunch-bin
```

## Build
> [!NOTE]
> Runtime/build deps: `nim >= 2.0`, `sdl3`, `sdl3_ttf`, `sdl3_image`, plus a font
> (default `ttf-dejavu`).
>
> Nim package note: the Nim SDL3 and `parsetoml` sources are vendored in
> `packages/`, so Nimble does not need to download those wrappers separately.
>
> Optional helpers:
> - `fd` and/or `locate` for faster `:s` file search

### Arch Linux
```bash
sudo pacman -S sdl3 sdl3_ttf sdl3_image ttf-dejavu --needed
```

### Ubuntu releases with SDL3 development packages (including 25.10)
```bash
sudo apt install libsdl3-dev libsdl3-ttf-dev libsdl3-image-dev fonts-dejavu-core
```

### OpenSUSE
```bash
# Tumbleweed / Slowroll package names:
sudo zypper install SDL3-devel SDL3_ttf-devel SDL3_image-devel dejavu-fonts
```
If you are on Leap and a name differs, run `zypper search sdl3`
to find the matching package variant.

### Solus
```bash
sudo eopkg it sdl3-devel sdl3-ttf-devel sdl3-image-devel
```

### Build from source
```bash
git clone https://github.com/Vyrnexis/NimLaunch.git
cd NimLaunch
```

```bash
nimble build          # default release build -> ./bin/nimlaunch
nimble test           # run all automated test suites
nimble -y nimDebug    # debug build -> ./bin/nimlaunch
nimble -y nimRelease  # release build tuned for this CPU -> ./bin/nimlaunch
nimble -y nimGeneric  # portable + smaller release build (generic x86_64 baseline) -> ./bin/nimlaunch
```

Zig/clang variants:

```bash
nimble -y zigDebug    # debug build -> ./bin/nimlaunch
nimble -y zigRelease  # release build for current CPU via Zig/clang -> ./bin/nimlaunch
nimble -y zigGeneric  # portable + smaller Zig/clang release build (generic x86_64 baseline) -> ./bin/nimlaunch
```

The native tasks require a C compiler. The Zig tasks additionally require
`zig` on `PATH`; the included `zigcc` wrapper is selected automatically.

For custom compiler flags, run `nimble c` from the project root:

```bash
nimble c -d:release -d:lto --opt:speed --mm:orc --threads:on -o:./bin/nimlaunch src/nimlaunch.nim
```

Run the result with `./bin/nimlaunch`.

## Usage
Put `nimlaunch` on your `PATH` (for example `~/.local/bin`) and bind it to a
hotkey. Pressing the hotkey again while NimLaunch is open closes it. The
launcher also closes when it loses focus. A default config is written on first
run.

### Keys

| Key | Effect |
| --- | ------ |
| Type text | Fuzzy-search applications |
| Enter | Launch the highlighted entry |
| Shift+Enter | `--dmenu` only: return the typed text, even without a match |
| ↑ / ↓ / PgUp / PgDn / Home / End | Move through the results (all modes, including Vim mode) |
| Esc | Exit NimLaunch |
| Ctrl+U | Clear the query |
| Backspace / Ctrl+H / ← | Delete one character |
| Ctrl+V / Shift+Insert | Paste from the clipboard |

With `vim_mode = true`: `j`/`k` move, `gg`/`G` jump, `h` deletes a character,
`l` activates, and `/`, `:` or `!` open a command bar. In the bar, Enter runs
the text, Esc closes it (keeping the narrowed results if you typed something),
Ctrl+U clears it, and Backspace on an empty bar closes it.

### Prefixes

| Prefix | Example | Description |
| ------ | ------- | ----------- |
| *none* | `fire` | Application search |
| `:t` | `:t nord` | Browse themes; ↑/↓ previews, Enter keeps the theme |
| `:s` | `:s notes` | Search files (needs 2+ characters): `fd`, then `locate`, then a depth-3 walk of `$HOME` |
| `:c` | `:c sway` | Search files in the XDG config directory (two levels deep) and open the match |
| `:r`, `!` | `!htop` | Run a shell command in your terminal |
| `:q`, `:quit` | `:q` | Offers a "Quit NimLaunch" row; quits only when you press Enter |
| `:<prefix>` | `:g rust` | Your own `[[shortcuts]]` |
| `:<group>` | `:sys lock` | Your own `[[groups]]` / shortcut groups |

## Configuration
The config file is `${XDG_CONFIG_HOME:-~/.config}/nimlaunch/nimlaunch.toml`,
created on first run. See [Configuration](docs/configuration.md) for every key
and [Groups and Shortcuts](docs/groups-and-shortcuts.md) for custom prefixes.

[examples/README.md](examples/README.md) describes the sample config and the
`--dmenu` scripts. [docs/dmenu.md](docs/dmenu.md) covers `--dmenu` itself.

## Command line

| Flag | Description |
| ---- | ----------- |
| `-c`, `--config PATH` | Use an alternate config file (created from the defaults if missing) |
| `--dmenu` | Select an item read from standard input |
| `-p`, `--prompt TEXT` | Override the prompt (only valid with `--dmenu`) |
| `--dry-run` | Print the selected raw action instead of running it; desktop-entry field codes are not expanded |
| `--list-themes` | Print theme names and exit |
| `--verbose` | Print uptime, app count and icon-cache size on exit |
| `-v`, `--version` | Print the version and exit |
| `-h`, `--help` | Print usage and exit |

## Troubleshooting
- **Build fails with `cannot open file: sdl3` or `parsetoml`:** build from the
  project root so `config.nims` can add the vendored `packages/` paths.
- **`:s` is slow:** install `fd` and/or `locate`; without them NimLaunch walks
  `$HOME` three levels deep.
- **SVG icons are missing:** your `SDL3_image` build needs SVG support.
- **`--dmenu` looks empty:** pipe newline-separated input, for example
  `printf 'one\ntwo\n' | nimlaunch --dmenu`.
- **Terminal apps or `:r` do nothing:** set `[terminal] program` to an installed
  terminal. Otherwise NimLaunch tries `$TERMINAL`, then `kitty`, `alacritty`,
  `wezterm`, `foot`, `gnome-terminal`, `konsole`, `xfce4-terminal`, `xterm`.
- **Text is wrong or too small:** set `[font] fontname`, for example
  `"Dejavu:size=16"`. Row and window height adjust automatically.
- **Config changes are ignored:** a TOML syntax error makes NimLaunch use
  built-in defaults for that session and print the error on stderr. Run it from
  a terminal to see it.
- **Theme does not persist:** the cache directory
  (`${XDG_CACHE_HOME:-~/.cache}/nimlaunch`) must be writable.
- **Black padding or delayed repaint on Wayland (Niri):** build with
  `-d:nimlaunchWindowDebug` to log window events and redraw timing.
