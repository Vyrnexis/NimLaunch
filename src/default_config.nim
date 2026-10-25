# ── Defaults as TOML text (same as NimLaunch) ───────────────────────────
const defaultToml* = """
# ==========================
# NimLaunch Configuration
# ==========================
# This file controls how NimLaunch looks and behaves.
# All settings are optional — if removed, defaults will be used.
# Edit values, save, and restart NimLaunch to apply changes.
# Colors must be in HEX format (e.g., "#RRGGBB").

[window]
width = 500                       # Width of the launcher window in pixels
line_height = 22                  # Minimum row height in pixels (12 - 200); never smaller than the font needs
show_clock = true                 # false hides the clock in the corner
opacity = 1.0                     # Window opacity (0.1 - 1.0); requires SDL support
max_visible_items = 10            # Number of items visible at once (affects height)
center = true                     # true: center window horizontally; false: use position_x/position_y
position_x = 20                   # X position in pixels when center=false
position_y = 500                  # Y position in pixels when center=false
vertical_align = "one-third"      # Only used when center=true; "top", "center", or "one-third"
display = 0                       # Display index when center=true (0 = primary)

[font]
fontname = "Dejavu:size=16"       # Font name & size (e.g., "Font Family:size=N")

[input]
prompt = "> "                     # Prompt prefix shown before your query
cursor = "_"                      # Cursor character displayed after query text
vim_mode = false                  # true enables Vim-style modes/hjkl navigation

[terminal]
program = ""                      # Terminal emulator for :r, ! and Terminal=true apps
                                  # Empty or not found: $TERMINAL is tried, then kitty,
                                  # alacritty, wezterm, foot, gnome-terminal, konsole,
                                  # xfce4-terminal and xterm

[border]
width = 2                         # Border thickness in pixels (0 = no border)

[icons]
enabled = true                    # Set to false to hide icons in the list

# ==========================
# Groups
# ==========================
# Define group names used by [[shortcuts]]. Avoid the built-in command names
# (s, c, t, r, q, quit) and shortcut prefixes: those always win, and NimLaunch
# warns on stderr when a group can never be reached.
# query_mode = "filter" (default) or "pass".

[[groups]]
name = "sys"
query_mode = "filter"

# ==========================
# Shortcuts
# ==========================
# Define custom prefix triggers. Each shortcut supports:
#   prefix  = letters you trigger with ':' (e.g., ":g"); leading/trailing ':' is optional
#   label   = text shown before your query in the results list
#   base    = template containing optional {query} placeholder
#   mode    = "url" (default), "shell", or "file"
#   group   = optional group name (e.g. "sys")
#   run_mode = "terminal" (default) or "spawn" for shell commands
#   stay_open = true keeps NimLaunch open after running the action

[[shortcuts]]
prefix = ":g"
label  = "Search Google: "
base   = "https://www.google.com/search?q={query}"
mode   = "url"

[[shortcuts]]
prefix = ":w"
label  = "Search Wiki: "
base   = "https://en.wikipedia.org/wiki/Special:Search?search={query}"
mode   = "url"

[[shortcuts]]
prefix = ":y"
label  = "Search YouTube: "
base   = "https://www.youtube.com/results?search_query={query}"
mode   = "url"

# ==========================
# Run commands
# ==========================
# Use `:r` (or `!`) to execute shell commands directly without a custom shortcut.

[[shortcuts]]
group     = "sys"
label     = "Lock"
base      = "loginctl lock-session"
mode      = "shell"
run_mode  = "spawn"
stay_open = false

[[shortcuts]]
group     = "sys"
label     = "Suspend"
base      = "systemctl suspend"
mode      = "shell"
run_mode  = "spawn"
stay_open = false

[[shortcuts]]
group     = "sys"
label     = "Shutdown"
base      = "systemctl poweroff"
mode      = "shell"
run_mode  = "spawn"
stay_open = false

[[shortcuts]]
group     = "sys"
label     = "Reboot"
base      = "systemctl reboot"
mode      = "shell"
run_mode  = "spawn"
stay_open = false

[[shortcuts]]
group     = "sys"
label     = "Logout"
base      = "loginctl terminate-user $USER"
mode      = "shell"
run_mode  = "spawn"
stay_open = false

# ==========================
# Themes
# ==========================
# About 84 themes are built into NimLaunch; you do not need to define any.
# Browse them with `:t` in the launcher, or run `nimlaunch --list-themes`.
#
# To add your own theme, or to override a built-in one, add a [[themes]]
# block. A block whose name matches a built-in theme (case-insensitive)
# replaces it; any other name adds a new theme to the `:t` selector.
# Colors:
#   bgColorHex          = Window background
#   fgColorHex          = Normal text color
#   highlightBgColorHex = Background of selected/highlighted item
#   highlightFgColorHex = Text color of selected/highlighted item
#   borderColorHex      = Window border color
#   matchFgColorHex     = Color for matching characters in search results
#                         (empty = inherit the default match color)
#
# [[themes]]
# name                = "My Theme"
# bgColorHex          = "#111111"
# fgColorHex          = "#f0f0f0"
# highlightBgColorHex = "#2a2a2a"
# highlightFgColorHex = "#ffffff"
# borderColorHex      = "#555555"
# matchFgColorHex     = "#ff8c42"

"""
