import std/[unittest, os, strutils, tables, sets, sequtils]
import ../src/[state, settings, app_core, paths, themes]

const LegacyThemeBlocks = """
[[themes]]
name                = "Default"
bgColorHex          = "#2E3440"
fgColorHex          = "#D8DEE9"
highlightBgColorHex = "#88C0D0"
highlightFgColorHex = "#2E3440"
borderColorHex      = "#8BE9FD"
matchFgColorHex     = "#f8c291"

[[themes]]
name                = "Ayu Dark"
bgColorHex          = "#0F1419"
fgColorHex          = "#BFBDB6"
highlightBgColorHex = "#59C2FF"
highlightFgColorHex = "#0F1419"
borderColorHex      = "#1F2328"
matchFgColorHex     = ""

[[themes]]
name                = "Ayu Light"
bgColorHex          = "#FAFAFA"
fgColorHex          = "#5C6773"
highlightBgColorHex = "#399EE6"
highlightFgColorHex = "#FAFAFA"
borderColorHex      = "#F0F0F0"
matchFgColorHex     = ""

[[themes]]
name                = "Catppuccin Frappe"
bgColorHex          = "#303446"
fgColorHex          = "#C6D0F5"
highlightBgColorHex = "#8CAAEE"
highlightFgColorHex = "#303446"
borderColorHex      = "#414559"
matchFgColorHex     = ""

[[themes]]
name                = "Catppuccin Latte"
bgColorHex          = "#EFF1F5"
fgColorHex          = "#4C4F69"
highlightBgColorHex = "#1E66F5"
highlightFgColorHex = "#EFF1F5"
borderColorHex      = "#BCC0CC"
matchFgColorHex     = ""

[[themes]]
name                = "Catppuccin Macchiato"
bgColorHex          = "#24273A"
fgColorHex          = "#CAD3F5"
highlightBgColorHex = "#8AADF4"
highlightFgColorHex = "#24273A"
borderColorHex      = "#363A4F"
matchFgColorHex     = ""

[[themes]]
name                = "Catppuccin Mocha"
bgColorHex          = "#1E1E2E"
fgColorHex          = "#CDD6F4"
highlightBgColorHex = "#89B4FA"
highlightFgColorHex = "#1E1E2E"
borderColorHex      = "#313244"
matchFgColorHex     = ""

[[themes]]
name                = "Dracula"
bgColorHex          = "#282A36"
fgColorHex          = "#F8F8F2"
highlightBgColorHex = "#BD93F9"
highlightFgColorHex = "#282A36"
borderColorHex      = "#44475A"
matchFgColorHex     = ""

[[themes]]
name                = "GitHub Dark"
bgColorHex          = "#0D1117"
fgColorHex          = "#E6EDF3"
highlightBgColorHex = "#388BFD"
highlightFgColorHex = "#0D1117"
borderColorHex      = "#30363D"
matchFgColorHex     = ""

[[themes]]
name                = "GitHub Light"
bgColorHex          = "#FFFFFF"
fgColorHex          = "#1F2328"
highlightBgColorHex = "#0969DA"
highlightFgColorHex = "#FFFFFF"
borderColorHex      = "#D1D9E0"
matchFgColorHex     = ""

[[themes]]
name                = "Gruvbox Dark"
bgColorHex          = "#282828"
fgColorHex          = "#EBDBB2"
highlightBgColorHex = "#83A598"
highlightFgColorHex = "#282828"
borderColorHex      = "#3C3836"
matchFgColorHex     = ""

[[themes]]
name                = "Gruvbox Light"
bgColorHex          = "#FBF1C7"
fgColorHex          = "#3C3836"
highlightBgColorHex = "#83A598"
highlightFgColorHex = "#FBF1C7"
borderColorHex      = "#EBDBB2"
matchFgColorHex     = ""

[[themes]]
name                = "Nord"
bgColorHex          = "#2E3440"
fgColorHex          = "#D8DEE9"
highlightBgColorHex = "#88C0D0"
highlightFgColorHex = "#2E3440"
borderColorHex      = "#4C566A"
matchFgColorHex     = ""
"""
  ## The 13 [[themes]] blocks that older generated configs contained.

proc themeIndex(name: string): int =
  result = -1
  for i, th in ctx.themeList:
    if th.name.toLowerAscii == name.toLowerAscii:
      return i

proc loadConfigText(toml: string; savedTheme = "") =
  ## Load *toml* with the saved-theme cache isolated from the real one;
  ## *savedTheme* simulates a theme previously picked with `:t`.
  let cfgPath = getTempDir() / "nimlaunch_test_themes.toml"
  let cacheHome = getTempDir() / "nimlaunch-test-theme-cache"
  let hadCacheHome = existsEnv("XDG_CACHE_HOME")
  let oldCacheHome = getEnv("XDG_CACHE_HOME")
  putEnv("XDG_CACHE_HOME", cacheHome)
  defer:
    if hadCacheHome: putEnv("XDG_CACHE_HOME", oldCacheHome)
    else: delEnv("XDG_CACHE_HOME")
    if fileExists(cfgPath): removeFile(cfgPath)
    if dirExists(cacheHome): removeDir(cacheHome)
  writeFile(cfgPath, toml)
  if savedTheme.len > 0:
    createDir(cacheHome / "nimlaunch")
    writeFile(cacheHome / "nimlaunch" / "theme", savedTheme & "\n")
  ctx.configOverridePath = cfgPath
  initLauncherConfig()

suite "Configuration and Shortcuts tests":
  test "load shortcuts from TOML table":
    let examplePath = currentSourcePath().parentDir.parentDir / "examples" / "nimlaunch.toml"
    check fileExists(examplePath)

    ctx.configOverridePath = examplePath
    initLauncherConfig()
    check ctx.shortcuts.len > 0

    var foundGoogle = false
    var foundSvcStatus = false
    for sc in ctx.shortcuts:
      if sc.prefix == "g":
        foundGoogle = true
        check sc.mode == smUrl
        check sc.base.contains("google.com")
      elif sc.group == "svc" and sc.label.contains("systemctl status"):
        foundSvcStatus = true
        check sc.mode == smShell
    check foundGoogle
    check foundSvcStatus

  test "parseCommand routing":
    let (cmdG, restG, idxG, _) = parseCommand(":g nim language")
    check cmdG == ckShortcut
    check restG == "nim language"
    check idxG >= 0
    check ctx.shortcuts[idxG].prefix == "g"

    let (cmdSvc, restSvc, _, groupSvc) = parseCommand(":svc ssh")
    check cmdSvc == ckGroup
    check groupSvc == "svc"
    check restSvc == "ssh"

    let (cmdSearch, restSearch, _, _) = parseCommand(":s myfile.nim")
    check cmdSearch == ckSearch
    check restSearch == "myfile.nim"

    let (cmdRun, restRun, _, _) = parseCommand("!ls -la")
    check cmdRun == ckRun
    check restRun == "ls -la"

    let (cmdNone, restNone, _, _) = parseCommand("firefox")
    check cmdNone == ckNone
    check restNone == "firefox"

  test "group query modes":
    check ctx.groupQueryModes.hasKey("sys")
    check ctx.groupQueryModes["sys"] == gqmFilter

    check ctx.groupQueryModes.hasKey("svc")
    check ctx.groupQueryModes["svc"] == gqmPass

  test "built-in themes are complete and unique":
    check BuiltinThemes.len == 84
    check BuiltinThemes[0].name == "Default"
    var seen = initHashSet[string]()
    for th in BuiltinThemes:
      check th.name.len > 0
      check not seen.containsOrIncl(th.name.toLowerAscii)
    for want in ["Default", "Nord", "Arstotzka"]:
      check want.toLowerAscii in seen

  test "config without themes loads built-ins and picks Default":
    loadConfigText("[window]\nwidth = 500\n")
    check ctx.themeList.len == BuiltinThemes.len
    check ctx.config.themeName == "Default"
    check ctx.config.bgColorHex == BuiltinThemes[0].bgColorHex

  test "default config contains no active theme blocks":
    check not defaultToml.contains("\n[[themes]]")
    loadConfigText(defaultToml)
    check ctx.themeList.len == BuiltinThemes.len
    check ctx.config.themeName == "Default"

  test "user theme overrides a built-in without duplicating it":
    loadConfigText("""
[[themes]]
name = "nord"
bgColorHex = "#010203"
fgColorHex = "#040506"
highlightBgColorHex = "#070809"
highlightFgColorHex = "#0a0b0c"
borderColorHex = "#0d0e0f"
matchFgColorHex = ""
""", savedTheme = "Nord")
    check ctx.themeList.len == BuiltinThemes.len
    let idx = themeIndex("Nord")
    check idx == themeIndex("nord")
    check ctx.themeList[idx].name == "nord"
    check ctx.themeList[idx].bgColorHex == "#010203"
    check ctx.config.bgColorHex == "#010203"
    var count = 0
    for th in ctx.themeList:
      if th.name.toLowerAscii == "nord": inc count
    check count == 1

  test "new user theme is appended and can be chosen":
    loadConfigText("""
[[themes]]
name = "My Theme"
bgColorHex = "#111111"
fgColorHex = "#f0f0f0"
highlightBgColorHex = "#2a2a2a"
highlightFgColorHex = "#ffffff"
borderColorHex = "#555555"
matchFgColorHex = "#ff8c42"
""", savedTheme = "My Theme")
    check ctx.themeList.len == BuiltinThemes.len + 1
    check ctx.themeList[^1].name == "My Theme"
    check ctx.config.themeName == "My Theme"
    check ctx.config.matchFgColorHex == "#ff8c42"

  test "user theme without a name is skipped":
    loadConfigText("""
[[themes]]
bgColorHex = "#111111"

[[themes]]
name = "  "
bgColorHex = "#222222"
""")
    check ctx.themeList.len == BuiltinThemes.len

  test "legacy default config with 13 theme blocks has no duplicates":
    loadConfigText("[window]\nwidth = 500\n\n" & LegacyThemeBlocks &
        "\n[theme]\nlast_chosen = \"Gruvbox Dark\"\n", savedTheme = "Gruvbox Dark")
    check ctx.themeList.len == BuiltinThemes.len
    check ctx.config.themeName == "Gruvbox Dark"
    var seen = initHashSet[string]()
    for th in ctx.themeList:
      check not seen.containsOrIncl(th.name.toLowerAscii)

  test "unknown saved theme falls back to the first theme":
    loadConfigText("", savedTheme = "No Such Theme")
    check ctx.config.themeName == ctx.themeList[0].name

  test "obsolete [theme] last_chosen is ignored":
    loadConfigText("[theme]\nlast_chosen = \"Nord\"\n")
    check ctx.config.themeName == "Default"

  test "window line_height and show_clock load, clamp and default":
    loadConfigText("")
    check ctx.config.lineHeight == 22
    check ctx.config.showClock
    check ctx.config.terminalExe == ""
    loadConfigText("[window]\nline_height = 40\nshow_clock = false\n")
    check ctx.config.lineHeight == 40
    check not ctx.config.showClock
    loadConfigText("[window]\nline_height = 1\n")
    check ctx.config.lineHeight == 12
    loadConfigText("[window]\nline_height = 9999\n")
    check ctx.config.lineHeight == 200

  test "nameConflicts reports shadowed groups and prefixes":
    loadConfigText("""
[[groups]]
name = "s"
[[groups]]
name = "web"
[[shortcuts]]
prefix = ":q"
base = "x"
[[shortcuts]]
prefix = ":web"
base = "y"
[[shortcuts]]
prefix = ":ok"
base = "z"
""")
    let found = nameConflicts()
    check found.len == 3
    check found.anyIt("group \"s\"" in it)
    check found.anyIt("prefix \"q\"" in it)
    check found.anyIt("prefix \"web\"" in it)

  test "ignore the removed pollIntervalMs setting":
    let cfgPath = getTempDir() / "nimlaunch_test_legacy_poll.toml"
    defer:
      if fileExists(cfgPath): removeFile(cfgPath)
    writeFile(cfgPath, defaultToml.replace("width = 500",
        "pollIntervalMs = 50\nwidth = 777"))
    ctx.configOverridePath = cfgPath
    initLauncherConfig()
    check ctx.config.winWidth == 777

  test "respect XDG data and root config paths":
    let hadDataHome = existsEnv("XDG_DATA_HOME")
    let oldDataHome = getEnv("XDG_DATA_HOME")
    let hadConfigHome = existsEnv("XDG_CONFIG_HOME")
    let oldConfigHome = getEnv("XDG_CONFIG_HOME")
    defer:
      if hadDataHome: putEnv("XDG_DATA_HOME", oldDataHome)
      else: delEnv("XDG_DATA_HOME")
      if hadConfigHome: putEnv("XDG_CONFIG_HOME", oldConfigHome)
      else: delEnv("XDG_CONFIG_HOME")
    let customData = getTempDir() / "nimlaunch-xdg-data"
    putEnv("XDG_DATA_HOME", customData & DirSep)
    putEnv("XDG_CONFIG_HOME", $DirSep)
    let dirs = applicationDirs()
    check dirs[0] == customData / "applications"
    check userConfigHome() == $DirSep
    check configDir() == $DirSep / "nimlaunch"
