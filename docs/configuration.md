# Configuration

NimLaunch reads `${XDG_CONFIG_HOME:-~/.config}/nimlaunch/nimlaunch.toml`, or the
file given with `--config PATH`. If that file does not exist, NimLaunch creates
it from the embedded template ([`src/default_config.nim`](../src/default_config.nim)).
Restart NimLaunch after editing.

## Files

| Path | Purpose |
| ---- | ------- |
| `${XDG_CONFIG_HOME:-~/.config}/nimlaunch/nimlaunch.toml` | Your configuration |
| `${XDG_CACHE_HOME:-~/.cache}/nimlaunch/apps.json` | Parsed `.desktop` entries |
| `${XDG_CACHE_HOME:-~/.cache}/nimlaunch/recent.json` | Recently launched apps (up to 10) |
| `${XDG_CACHE_HOME:-~/.cache}/nimlaunch/usage.json` | Per-app launch counts |
| `${XDG_CACHE_HOME:-~/.cache}/nimlaunch/theme` | Last selected theme name |
| `${XDG_CACHE_HOME:-~/.cache}/nimlaunch/nimlaunch.lock` | Single-instance lock (holds the PID) |

The app cache is reused until the `.desktop` directories, the locale/`PATH`
environment, or a `TryExec` program change; it is then rebuilt automatically.
Deleting the cache files is always safe. Desktop entries come from
`XDG_DATA_HOME` and `XDG_DATA_DIRS` (with their standard defaults) plus the
Flatpak export directories.

## Error handling

- **Invalid TOML:** NimLaunch prints the parse error to stderr and runs with
  built-in defaults for that session. Your file is left untouched.
- **Malformed section or entry:** a `[section]` with the wrong shape is ignored
  with a warning. Invalid `[[shortcuts]]`, `[[groups]]` or `[[themes]]` entries
  are skipped and counted in a warning.
- **Wrong value type or missing key:** the default is used.
- **Unknown keys and sections are ignored.** Old configs keep loading; for
  example `pollIntervalMs` was removed (the event loop now sleeps until
  needed) and is simply skipped.

## Keys

Out-of-range numbers are clamped silently.

### `[window]`

| Key | Type | Default | Range / values | Notes |
| --- | ---- | ------- | -------------- | ----- |
| `width` | int | `500` | 200–4000 | Window width in pixels |
| `opacity` | float | `1.0` | 0.1–1.0 | Some compositors ignore it |
| `max_visible_items` | int | `10` | 1–100 | Rows shown before scrolling; reduced on small displays |
| `center` | bool | `true` | | `false` uses `position_x` / `position_y` |
| `position_x` | int | `20` | | Only when `center = false` |
| `position_y` | int | `500` | | Only when `center = false` |
| `vertical_align` | string | `"one-third"` | `"top"`, `"center"`, `"one-third"` | Only when `center = true` |
| `display` | int | `0` | ≥ 0 | Monitor index (0 = primary); negative becomes 0 |

Row and window height follow the font and icon size automatically. Wayland
compositors may ignore `position_x` / `position_y`; see
[Start Menu Mode](#advanced-start-menu-mode).

### `[font]`

| Key | Type | Default | Notes |
| --- | ---- | ------- | ----- |
| `fontname` | string | `"Dejavu:size=16"` | Fontconfig-style `"Family:size=N"`, e.g. `"JetBrains Mono:size=15"` |

### `[input]`

| Key | Type | Default | Notes |
| --- | ---- | ------- | ----- |
| `prompt` | string | `"> "` | Shown before the query |
| `cursor` | string | `"_"` | Shown after the query |
| `vim_mode` | bool | `false` | Vim-style navigation and command bar |

The input line scrolls horizontally to keep the cursor visible, and long result
labels are truncated with `…`.

### `[terminal]`

| Key | Type | Default | Notes |
| --- | ---- | ------- | ----- |
| `program` | string | `"gnome-terminal"` | Terminal for `:r`, `!`, `Terminal=true` apps and `run_mode = "terminal"` shortcuts. May include arguments |

If `program` is not installed, NimLaunch tries `$TERMINAL`, then `kitty`,
`alacritty`, `wezterm`, `foot`, `gnome-terminal`, `konsole`, `xfce4-terminal`,
`xterm`.

### `[border]`

| Key | Type | Default | Range | Notes |
| --- | ---- | ------- | ----- | ----- |
| `width` | int | `2` | 0–64 | Pixels; `0` disables the border. Reduced further if it would not fit |

### `[icons]`

| Key | Type | Default | Notes |
| --- | ---- | ------- | ----- |
| `enabled` | bool | `true` | `false` hides icons |

Icons follow your icon theme (`ICON_THEME` environment variable, then
gsettings, then GTK `settings.ini`) and its `Inherits` chain, then `hicolor`,
pixmaps, and other installed themes. PNG and SVG load through `SDL3_image`.

### `[theme]`

| Key | Type | Default | Notes |
| --- | ---- | ------- | ----- |
| `last_chosen` | string | `"Default"` | Initial theme, matched case-insensitively. The `theme` cache file takes priority once you pick a theme with `:t`. An unknown name falls back to the first theme (`Default`) |

### `[[themes]]`

Optional, repeatable. Adds a theme or overrides a built-in one of the same
name. Fields (`name`, `bgColorHex`, `fgColorHex`, `highlightBgColorHex`,
`highlightFgColorHex`, `borderColorHex`, `matchFgColorHex`) are described in
[Themes](themes.md).

### `[[groups]]`

| Key | Type | Default | Values |
| --- | ---- | ------- | ------ |
| `name` | string | required | Group name (lowercased) |
| `query_mode` | string | `"filter"` | `"filter"`, or `"pass"` (also `"passthrough"`, `"pass-through"`) |

Only needed for `query_mode = "pass"`; groups used by shortcuts are created
automatically. See [Groups and Shortcuts](groups-and-shortcuts.md).

### `[[shortcuts]]`

| Key | Type | Default | Values |
| --- | ---- | ------- | ------ |
| `prefix` | string | | Trigger name; leading/trailing `:` optional, case-insensitive. Ignored when `group` is set |
| `group` | string | | Attach to a group instead of a prefix (lowercased) |
| `label` | string | | Text shown in the results list |
| `base` | string | required | URL, command or path; optional `{query}` placeholder |
| `mode` | string | `"url"` | `"url"`, `"shell"`, `"file"` (anything else means `url`) |
| `run_mode` | string | `"terminal"` | `"terminal"`, `"spawn"` (shell mode only) |
| `stay_open` | bool | `false` | Keep NimLaunch open after the action |

An entry without `base`, or with neither `prefix` nor `group`, is skipped.
Details in [Groups and Shortcuts](groups-and-shortcuts.md).

## Themes

There are 84 built-in themes (`:t`, `nimlaunch --list-themes`). The generated
config contains no theme blocks. See [Themes](themes.md).

## Related documentation

- [Groups and Shortcuts](groups-and-shortcuts.md)
- [Themes](themes.md)
- [Dmenu Mode](dmenu.md)
- [Example config](../examples/nimlaunch.toml) and [examples/README.md](../examples/README.md)

## Advanced: Start Menu Mode

NimLaunch can be repurposed as a corner-pinned Start Menu for your panel (e.g., Waybar, Polybar, or KDE Panel).

Create a dedicated configuration file (e.g., `~/.config/nimlaunch/startmenu.toml`) and disable centering:

```toml
[window]
center = false
position_x = 15
position_y = 45  # Adjust based on your panel height and screen resolution
```

**Wayland Users:** By design, Wayland compositors forbid standard applications from dictating their absolute window positions. If your compositor ignores the coordinates and continues to center the window, you can force NimLaunch to run through XWayland (which allows absolute positioning) by prefixing the launch command:

```bash
SDL_VIDEODRIVER=x11 nimlaunch --config ~/.config/nimlaunch/startmenu.toml
```
