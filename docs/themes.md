# Themes

NimLaunch ships with 84 built-in themes, so a fresh install works without any theme configuration. Themes control the launcher colors and the persisted active theme.

- Browse and preview built-in themes with `:t` in the launcher.
- Print every theme name with `nimlaunch --list-themes`.
- Add your own themes, or override a built-in one, with `[[themes]]` blocks in `~/.config/nimlaunch/nimlaunch.toml`.
- Select the initial theme with the `[theme]` section.

Built-in themes are updated with NimLaunch releases. Because they are not copied into your configuration file, new and improved themes reach existing installs automatically.

## Theme Block

A `[[themes]]` block defines one theme. Example:

```toml
[[themes]]
name                = "My Theme"
bgColorHex          = "#111111"
fgColorHex          = "#f0f0f0"
highlightBgColorHex = "#2a2a2a"
highlightFgColorHex = "#ffffff"
borderColorHex      = "#555555"
matchFgColorHex     = "#ff8c42"
```

Fields:

- **`name`**: Label shown in the `:t` selector. Names are matched case-insensitively and must not be empty; blocks without a name are skipped with a warning.
- **`bgColorHex`**: Launcher background color.
- **`fgColorHex`**: Normal text color.
- **`highlightBgColorHex`**: Selected row background color.
- **`highlightFgColorHex`**: Selected row text color.
- **`borderColorHex`**: Border color.
- **`matchFgColorHex`**: Color used for matching characters. An empty value inherits the default match color (`#f8c291`).

Non-empty colors use `#RRGGBB` format. Invalid values fall back to built-in
rendering colors. A block without a name is skipped with a warning.

## Selecting a Theme

Use the built-in theme selector by typing:

`:t`

Then:
- Type to filter theme names.
- Use Up/Down to preview themes.
- Press `Enter` to keep the selected theme. NimLaunch stays open and saves it.
- Press `Esc` to discard the preview and close NimLaunch; the previous theme stays active.

## Persisted Theme

The configuration provides the initial theme:

```toml
[theme]
last_chosen = "Nord"
```

Accepted selections are stored in `${XDG_CACHE_HOME:-~/.cache}/nimlaunch/theme`
without rewriting your configuration. When that file exists, it takes priority
over `last_chosen`; delete it to fall back to the configured value. Names are
matched case-insensitively.

## Troubleshooting Theme Persistence

Common causes if a theme change does not persist:

- The cache directory is not writable (NimLaunch prints a warning on stderr).
- The saved theme no longer exists in the theme list. NimLaunch then falls back to `Default`.

If the TOML is invalid, NimLaunch prints a parse error on stderr and uses built-in defaults, including no custom `[[themes]]`, for that session.

## Custom and Overridden Themes

User `[[themes]]` blocks are applied on top of the built-in list:

- A block whose `name` matches a built-in theme (case-insensitive) **replaces** that theme in place.
- A block with any other name is **added** after the built-in themes.

The example above adds a new "My Theme". To change a built-in theme instead, reuse its name:

```toml
[[themes]]
name                = "Nord"
bgColorHex          = "#1b2028"
fgColorHex          = "#D8DEE9"
highlightBgColorHex = "#88C0D0"
highlightFgColorHex = "#1b2028"
borderColorHex      = "#4C566A"
matchFgColorHex     = ""
```

Older generated configuration files contain copies of 13 theme blocks. They keep working: each block overrides the built-in theme of the same name, so no duplicates appear. You can delete those blocks to receive future updates to those themes.

## Built-in Themes

These themes are available out of the box. Use the name shown in each heading with `[theme] last_chosen`, `:t`, or an overriding `[[themes]]` block. The listed colors are background, text, and highlight.

### Default

![Default](../screenshots/themes/Default.png)

`#2E3440` background · `#D8DEE9` text · `#88C0D0` highlight

### Arstotzka

![Arstotzka](../screenshots/themes/Arstotzka.png)

`#211f1e` background · `#edebe6` text · `#292725` highlight

### Ayu Dark

![Ayu Dark](../screenshots/themes/Ayu%20Dark.png)

`#0F1419` background · `#BFBDB6` text · `#59C2FF` highlight

### Ayu Light

![Ayu Light](../screenshots/themes/Ayu%20Light.png)

`#FAFAFA` background · `#5C6773` text · `#399EE6` highlight

### Azure

![Azure](../screenshots/themes/Azure.png)

`#181d26` background · `#ffffff` text · `#33333c` highlight

### Bold

![Bold](../screenshots/themes/Bold.png)

`#2a2626` background · `#ffffff` text · `#393434` highlight

### Box UK

![Box UK](../screenshots/themes/Box%20UK.png)

`#ffffff` background · `#414f5c` text · `#eeeeee` highlight

### Carbonight

![Carbonight](../screenshots/themes/Carbonight.png)

`#2e2c2b` background · `#b0b0b0` text · `#3b3633` highlight

### Catppuccin Frappe

![Catppuccin Frappe](../screenshots/themes/Catppuccin%20Frappe.png)

`#303446` background · `#C6D0F5` text · `#8CAAEE` highlight

### Catppuccin Latte

![Catppuccin Latte](../screenshots/themes/Catppuccin%20Latte.png)

`#EFF1F5` background · `#4C4F69` text · `#1E66F5` highlight

### Catppuccin Macchiato

![Catppuccin Macchiato](../screenshots/themes/Catppuccin%20Macchiato.png)

`#24273A` background · `#CAD3F5` text · `#8AADF4` highlight

### Catppuccin Mocha

![Catppuccin Mocha](../screenshots/themes/Catppuccin%20Mocha.png)

`#1E1E2E` background · `#CDD6F4` text · `#89B4FA` highlight

### Charcoal Dark

![Charcoal Dark](../screenshots/themes/Charcoal%20Dark.png)

`#120F09` background · `#C0A179` text · `#35291D` highlight

### Charcoal Light

![Charcoal Light](../screenshots/themes/Charcoal%20Light.png)

`#d6b891` background · `#35291d` text · `#a28662` highlight

### Chocolate

![Chocolate](../screenshots/themes/Chocolate.png)

`#150f08` background · `#ffffff` text · `#362715` highlight

### Cobalt

![Cobalt](../screenshots/themes/Cobalt.png)

`#002240` background · `#FFFFFF` text · `#007ACC` highlight

### Crisp

![Crisp](../screenshots/themes/Crisp.png)

`#221a22` background · `#ffffff` text · `#1c151c` highlight

### Darkside

![Darkside](../screenshots/themes/Darkside.png)

`#222324` background · `#bababa` text · `#303333` highlight

### Dracula

![Dracula](../screenshots/themes/Dracula.png)

`#282A36` background · `#F8F8F2` text · `#BD93F9` highlight

### Earthsong

![Earthsong](../screenshots/themes/Earthsong.png)

`#36312c` background · `#ebd1b7` text · `#45403b` highlight

### Earthsong Light

![Earthsong Light](../screenshots/themes/Earthsong%20Light.png)

`#ffffff` background · `#4d463e` text · `#eeeeee` highlight

### FreshCut

![FreshCut](../screenshots/themes/FreshCut.png)

`#2f3030` background · `#f8f8f2` text · `#383939` highlight

### Frontier

![Frontier](../screenshots/themes/Frontier.png)

`#36312c` background · `#f8f8f2` text · `#45403b` highlight

### GitHub

![GitHub](../screenshots/themes/GitHub.png)

`#ffffff` background · `#555555` text · `#eeeeee` highlight

### GitHub Dark

![GitHub Dark](../screenshots/themes/GitHub%20Dark.png)

`#0D1117` background · `#E6EDF3` text · `#388BFD` highlight

### GitHub Light

![GitHub Light](../screenshots/themes/GitHub%20Light.png)

`#FFFFFF` background · `#1F2328` text · `#0969DA` highlight

### Gloom

![Gloom](../screenshots/themes/Gloom.png)

`#2a332b` background · `#d8ebe5` text · `#3c4d3e` highlight

### Glowfish

![Glowfish](../screenshots/themes/Glowfish.png)

`#191f13` background · `#6ea240` text · `#222a1a` highlight

### Goldfish

![Goldfish](../screenshots/themes/Goldfish.png)

`#2e3336` background · `#f8f8f2` text · `#465459` highlight

### Grunge

![Grunge](../screenshots/themes/Grunge.png)

`#31332c` background · `#f8f8f2` text · `#41453a` highlight

### Gruvbox Dark

![Gruvbox Dark](../screenshots/themes/Gruvbox%20Dark.png)

`#282828` background · `#EBDBB2` text · `#83A598` highlight

### Gruvbox Light

![Gruvbox Light](../screenshots/themes/Gruvbox%20Light.png)

`#FBF1C7` background · `#3C3836` text · `#83A598` highlight

### Halflife

![Halflife](../screenshots/themes/Halflife.png)

`#222222` background · `#cccccc` text · `#282828` highlight

### Hyrule

![Hyrule](../screenshots/themes/Hyrule.png)

`#2d2c2b` background · `#c0d5c1` text · `#3d3934` highlight

### Iceberg

![Iceberg](../screenshots/themes/Iceberg.png)

`#323b3d` background · `#bdd6db` text · `#3e4c4f` highlight

### Juicy

![Juicy](../screenshots/themes/Juicy.png)

`#222222` background · `#e3e2e0` text · `#282828` highlight

### Keen

![Keen](../screenshots/themes/Keen.png)

`#111111` background · `#cccccc` text · `#222222` highlight

### Kiwi

![Kiwi](../screenshots/themes/Kiwi.png)

`#161a19` background · `#edebe6` text · `#282f2d` highlight

### Laravel

![Laravel](../screenshots/themes/Laravel.png)

`#2e2c2b` background · `#dedede` text · `#3b3633` highlight

### Lavender

![Lavender](../screenshots/themes/Lavender.png)

`#29222e` background · `#e0ceed` text · `#3a2f42` highlight

### Legacy

![Legacy](../screenshots/themes/Legacy.png)

`#14191f` background · `#aec2e0` text · `#1b232c` highlight

### Material Dark

![Material Dark](../screenshots/themes/Material%20Dark.png)

`#263238` background · `#ECEFF1` text · `#FFAB40` highlight

### Material Light

![Material Light](../screenshots/themes/Material%20Light.png)

`#FAFAFA` background · `#212121` text · `#FFAB40` highlight

### Mellow

![Mellow](../screenshots/themes/Mellow.png)

`#36312c` background · `#f8f8f2` text · `#45403b` highlight

### Mintchoc

![Mintchoc](../screenshots/themes/Mintchoc.png)

`#2b221c` background · `#bababa` text · `#3f322a` highlight

### Monokai

![Monokai](../screenshots/themes/Monokai.png)

`#272822` background · `#F8F8F2` text · `#66D9EF` highlight

### Monokai Pro

![Monokai Pro](../screenshots/themes/Monokai%20Pro.png)

`#2D2A2E` background · `#FCFCFA` text · `#78DCE8` highlight

### Mud

![Mud](../screenshots/themes/Mud.png)

`#403635` background · `#ffffff` text · `#322a29` highlight

### Nord

![Nord](../screenshots/themes/Nord.png)

`#2E3440` background · `#D8DEE9` text · `#88C0D0` highlight

### One Dark

![One Dark](../screenshots/themes/One%20Dark.png)

`#282C34` background · `#ABB2BF` text · `#61AFEF` highlight

### One Light

![One Light](../screenshots/themes/One%20Light.png)

`#FAFAFA` background · `#383A42` text · `#4078F2` highlight

### Otakon

![Otakon](../screenshots/themes/Otakon.png)

`#171417` background · `#f9f3f9` text · `#332d33` highlight

### Palenight

![Palenight](../screenshots/themes/Palenight.png)

`#292D3E` background · `#EEFFFF` text · `#82AAFF` highlight

### Pastel

![Pastel](../screenshots/themes/Pastel.png)

`#222222` background · `#eeeeee` text · `#333333` highlight

### Patriot

![Patriot](../screenshots/themes/Patriot.png)

`#2d3133` background · `#cad9e3` text · `#40484d` highlight

### Peacock

![Peacock](../screenshots/themes/Peacock.png)

`#2b2a27` background · `#ede0ce` text · `#403c37` highlight

### Peacocks In Space

![Peacocks In Space](../screenshots/themes/Peacocks%20In%20Space.png)

`#2b303b` background · `#dee3ec` text · `#272b34` highlight

### Peel

![Peel](../screenshots/themes/Peel.png)

`#23201c` background · `#edebe6` text · `#403c37` highlight

### Piggy

![Piggy](../screenshots/themes/Piggy.png)

`#1c1618` background · `#edebe6` text · `#34282c` highlight

### Potpourri

![Potpourri](../screenshots/themes/Potpourri.png)

`#2e2b2c` background · `#f8f8f2` text · `#403c37` highlight

### Rainbow

![Rainbow](../screenshots/themes/Rainbow.png)

`#16181a` background · `#c7d0d9` text · `#403c37` highlight

### Revelation

![Revelation](../screenshots/themes/Revelation.png)

`#2e2c2b` background · `#dedede` text · `#3b3633` highlight

### Shrek

![Shrek](../screenshots/themes/Shrek.png)

`#222222` background · `#ffffff` text · `#333333` highlight

### Slate

![Slate](../screenshots/themes/Slate.png)

`#19191f` background · `#ebebf4` text · `#2a2a33` highlight

### Slime

![Slime](../screenshots/themes/Slime.png)

`#292d30` background · `#ffffff` text · `#384147` highlight

### Snappy

![Snappy](../screenshots/themes/Snappy.png)

`#393939` background · `#e3e2e0` text · `#282828` highlight

### Snappy Light

![Snappy Light](../screenshots/themes/Snappy%20Light.png)

`#ffffff` background · `#555555` text · `#eeeeee` highlight

### Solarflare

![Solarflare](../screenshots/themes/Solarflare.png)

`#222222` background · `#e3e2e0` text · `#282828` highlight

### Solarized Dark

![Solarized Dark](../screenshots/themes/Solarized%20Dark.png)

`#002B36` background · `#839496` text · `#268BD2` highlight

### Solarized Light

![Solarized Light](../screenshots/themes/Solarized%20Light.png)

`#FDF6E3` background · `#657B83` text · `#268BD2` highlight

### Sourlick

![Sourlick](../screenshots/themes/Sourlick.png)

`#2e2c2b` background · `#dedede` text · `#3b3633` highlight

### Spearmint

![Spearmint](../screenshots/themes/Spearmint.png)

`#e1f0ee` background · `#719692` text · `#ceebe7` highlight

### Stark

![Stark](../screenshots/themes/Stark.png)

`#2e2c2b` background · `#dedede` text · `#3b3633` highlight

### Super

![Super](../screenshots/themes/Super.png)

`#15191d` background · `#ffffff` text · `#242b32` highlight

### Synthwave 84

![Synthwave 84](../screenshots/themes/Synthwave%2084.png)

`#2A2139` background · `#FFFFFF` text · `#F92AAD` highlight

### Tokyo Night

![Tokyo Night](../screenshots/themes/Tokyo%20Night.png)

`#1A1B26` background · `#A9B1D6` text · `#7AA2F7` highlight

### Tokyo Night Light

![Tokyo Night Light](../screenshots/themes/Tokyo%20Night%20Light.png)

`#D5D6DB` background · `#343B58` text · `#34548A` highlight

### Tonic

![Tonic](../screenshots/themes/Tonic.png)

`#2a2f31` background · `#eeeeee` text · `#353b3e` highlight

### Tribal

![Tribal](../screenshots/themes/Tribal.png)

`#19191d` background · `#ffffff` text · `#33333c` highlight

### Tron

![Tron](../screenshots/themes/Tron.png)

`#14191f` background · `#aec2e0` text · `#1b232c` highlight

### Turnip

![Turnip](../screenshots/themes/Turnip.png)

`#1a1b1d` background · `#ede0ce` text · `#222222` highlight

### Userscape

![Userscape](../screenshots/themes/Userscape.png)

`#f5f8fc` background · `#879bb0` text · `#eeeeee` highlight

### Yule

![Yule](../screenshots/themes/Yule.png)

`#2b2a27` background · `#ede0ce` text · `#52504b` highlight

### Zacks

![Zacks](../screenshots/themes/Zacks.png)

`#222222` background · `#f0f0f0` text · `#333333` highlight

## Reference Files

The built-in theme set is defined in:

- [`src/themes.nim`](../src/themes.nim)

The generated default configuration is embedded in:

- [`src/default_config.nim`](../src/default_config.nim)

The checked-in sample config lives at:

- [examples/nimlaunch.toml](../examples/nimlaunch.toml)

## Related Docs

- [Configuration](configuration.md)
- [Groups and Shortcuts](groups-and-shortcuts.md)
- [Dmenu Mode](dmenu.md)
