## settings.nim — config and theme loading for NimLaunch.

import std/[os, strutils, math, options, tables, syncio]
import parsetoml as toml
import ./[state as st, gui, utils, paths]

var
  baseMatchFgColorHex = "" ## default fallback for match highlight colour

proc applyTheme*(cfg: var Config; name: string) =
  ## Set theme fields from `ctx.themeList` by name; respect explicit match color.
  let fallbackMatch = if baseMatchFgColorHex.len > 0:
    baseMatchFgColorHex
  else:
    cfg.matchFgColorHex
  for i, th in ctx.themeList:
    if th.name.toLowerAscii == name.toLowerAscii:
      cfg.bgColorHex = th.bgColorHex
      cfg.fgColorHex = th.fgColorHex
      cfg.highlightBgColorHex = th.highlightBgColorHex
      cfg.highlightFgColorHex = th.highlightFgColorHex
      cfg.borderColorHex = th.borderColorHex
      if th.matchFgColorHex.len > 0:
        cfg.matchFgColorHex = th.matchFgColorHex
      else:
        cfg.matchFgColorHex = fallbackMatch
      cfg.themeName = th.name
      break

proc getRgb(hex: string; defaultRgb: Rgb): Rgb =
  let opt = parseHexRgb8(hex)
  if isSome(opt): get(opt) else: defaultRgb

proc updateParsedColors*(cfg: var Config) =
  ## Resolve hex → RGB colours for SDL rendering. Fallback if invalid.
  cfg.bgColor = getRgb(cfg.bgColorHex, Rgb(r: 30, g: 30, b: 30))
  cfg.fgColor = getRgb(cfg.fgColorHex, Rgb(r: 200, g: 200, b: 200))
  cfg.highlightBgColor = getRgb(cfg.highlightBgColorHex, Rgb(r: 60, g: 60, b: 60))
  cfg.highlightFgColor = getRgb(cfg.highlightFgColorHex, Rgb(r: 255, g: 255, b: 255))
  cfg.borderColor = getRgb(cfg.borderColorHex, Rgb(r: 100, g: 100, b: 100))
  cfg.matchFgColor = getRgb(cfg.matchFgColorHex, Rgb(r: 255, g: 100, b: 100))

proc applyThemeAndColors*(cfg: var Config; name: string; doNotify = true;
    doRedraw = true) =
  ## Apply theme, resolve colors, push to GUI, and optionally redraw.
  applyTheme(cfg, name)
  updateParsedColors(cfg)
  gui.updateGuiColors()
  if doNotify:
    gui.notifyThemeChanged(name)
  if doRedraw:
    gui.redrawWindow()

## Persist the selected theme separately from user-authored configuration.
proc saveLastTheme*(): bool =
  let path = cacheDir() / "theme"
  try:
    createDir(path.parentDir)
    writeFile(path, ctx.config.themeName & "\n")
    true
  except IOError, OSError:
    let e = getCurrentException()
    stderr.writeLine "saveLastTheme warning: unable to write " & path &
        " (" & $e.name & "): " & e.msg
    false

proc loadShortcutsSection(tbl: toml.TomlValueRef; cfgPath: string) =
  ## Populate `ctx.shortcuts` from `[[shortcuts]]` entries in *tbl*.
  ctx.shortcuts = @[]
  if not tbl.hasKey("shortcuts"): return

  try:
    var invalidCount = 0
    for scVal in tbl["shortcuts"].getElems():
      try:
        let scTbl = scVal.getTable()
        let prefixRaw = scTbl.getOrDefault("prefix").getStr("")
        var prefix = normalizePrefix(prefixRaw)
        let base = scTbl.getOrDefault("base").getStr("").strip()
        let label = scTbl.getOrDefault("label").getStr("").strip(chars = {'\t',
            '\r', '\n'})
        let modeStr = scTbl.getOrDefault("mode").getStr("url").toLowerAscii
        let group = scTbl.getOrDefault("group").getStr("").strip().toLowerAscii
        let runModeStr = scTbl.getOrDefault("run_mode").getStr("").strip().toLowerAscii
        let stayOpen = scTbl.getOrDefault("stay_open").getBool(false)

        if base.len == 0:
          continue
        if group.len > 0:
          prefix.setLen(0)
        if prefix.len == 0 and group.len == 0:
          continue

        var mode = smUrl
        case modeStr
        of "shell": mode = smShell
        of "file": mode = smFile
        else: discard

        var runMode = pamTerminal
        case runModeStr
        of "spawn": runMode = pamSpawn
        of "terminal": runMode = pamTerminal
        else: discard

        ctx.shortcuts.add Shortcut(prefix: prefix,
                                  label: label,
                                  base: base,
                                  mode: mode,
                                  group: group,
                                  runMode: runMode,
                                  stayOpen: stayOpen)
      except CatchableError:
        inc invalidCount
    if invalidCount > 0:
      stderr.writeLine "NimLaunch warning: skipped " & $invalidCount &
          " invalid [[shortcuts]] entries in " & cfgPath
  except CatchableError:
    stderr.writeLine "NimLaunch warning: ignoring invalid [[shortcuts]] entries in " & cfgPath

proc parseGroupQueryMode(modeStr: string): GroupQueryMode =
  case modeStr
  of "pass", "passthrough", "pass-through": gqmPass
  else: gqmFilter

proc loadGroupsSection(tbl: toml.TomlValueRef; cfgPath: string) =
  ## Populate `ctx.groupQueryModes` from `[[groups]]` entries in *tbl*.
  ctx.groupQueryModes = initTable[string, GroupQueryMode]()
  if not tbl.hasKey("groups"): return

  try:
    var invalidCount = 0
    for grpVal in tbl["groups"].getElems():
      try:
        let grpTbl = grpVal.getTable()
        let name = grpTbl.getOrDefault("name").getStr("").strip().toLowerAscii
        if name.len == 0:
          continue
        let modeStr = grpTbl.getOrDefault("query_mode").getStr("filter").strip().toLowerAscii
        ctx.groupQueryModes[name] = parseGroupQueryMode(modeStr)
      except CatchableError:
        inc invalidCount
    if invalidCount > 0:
      stderr.writeLine "NimLaunch warning: skipped " & $invalidCount &
          " invalid [[groups]] entries in " & cfgPath
  except CatchableError:
    stderr.writeLine "NimLaunch warning: ignoring invalid [[groups]] entries in " & cfgPath

proc ensureGroupDefaults() =
  ## Ensure every shortcut group exists with a default query mode.
  for sc in ctx.shortcuts:
    if sc.group.len == 0: continue
    if not ctx.groupQueryModes.hasKey(sc.group):
      ctx.groupQueryModes[sc.group] = gqmFilter

proc initLauncherConfig*() =
  ## Initialize defaults, read TOML, apply last theme, compute geometry.
  ctx.config = Config() # zero-init
  ctx.groupQueryModes = initTable[string, GroupQueryMode]()

  ## In-code defaults
  ctx.config.winWidth = 500
  ctx.config.lineHeight = 22
  ctx.config.maxVisibleItems = 10
  ctx.config.centerWindow = true
  ctx.config.positionX = 20
  ctx.config.positionY = 500
  ctx.config.verticalAlign = "one-third"
  ctx.config.displayIndex = 0
  ctx.config.fontName = "Dejavu:size=16"
  ctx.config.prompt = "> "
  ctx.config.cursor = "_"
  ctx.config.opacity = 1.0
  ctx.config.terminalExe = "gnome-terminal"
  ctx.config.borderWidth = 2
  ctx.config.matchFgColorHex = "#f8c291"
  ctx.config.vimMode = false
  ctx.config.showIcons = true
  ctx.config.pollIntervalMs = 10

  ## Ensure TOML exists
  let cfgDir = configDir()
  let cfgPath = if ctx.configOverridePath.len > 0: ctx.configOverridePath else: cfgDir / "nimlaunch.toml"
  if not fileExists(cfgPath):
    try:
      createDir(parentDir(cfgPath))
      writeFile(cfgPath, defaultToml)
      stderr.writeLine "Created default config at " & cfgPath
    except CatchableError as e:
      stderr.writeLine "NimLaunch warning: unable to write default config at " &
          cfgPath & " (" & $e.name & "): " & e.msg

  ## Parse TOML
  var tbl: toml.TomlValueRef
  var configValid = true
  try:
    tbl = toml.parseFile(cfgPath)
  except CatchableError as e:
    configValid = false
    stderr.writeLine "NimLaunch config error: failed to parse " & cfgPath
    stderr.writeLine "  " & $e.name & ": " & e.msg
    stderr.writeLine "  NimLaunch is ignoring this file and using built-in defaults for this session."
    stderr.writeLine "  Fix the TOML file and restart NimLaunch to restore your saved settings."
    tbl = toml.parseString(defaultToml)

  ## window
  if tbl.hasKey("window"):
    try:
      let w = tbl["window"].getTable()
      ctx.config.winWidth = w.getOrDefault("width").getInt(ctx.config.winWidth)
      ctx.config.maxVisibleItems = w.getOrDefault("max_visible_items").getInt(
          ctx.config.maxVisibleItems)
      ctx.config.centerWindow = w.getOrDefault("center").getBool(
          ctx.config.centerWindow)
      ctx.config.positionX = w.getOrDefault("position_x").getInt(
          ctx.config.positionX)
      ctx.config.positionY = w.getOrDefault("position_y").getInt(
          ctx.config.positionY)
      ctx.config.verticalAlign = w.getOrDefault("vertical_align").getStr(
          ctx.config.verticalAlign)
      ctx.config.displayIndex = w.getOrDefault("display").getInt(
          ctx.config.displayIndex)
      ctx.config.pollIntervalMs = w.getOrDefault("pollIntervalMs").getInt(
          ctx.config.pollIntervalMs)
      ctx.config.opacity = w.getOrDefault("opacity").getFloat(ctx.config.opacity)
    except CatchableError:
      stderr.writeLine "NimLaunch warning: ignoring invalid [window] section in " & cfgPath

  ## font
  if tbl.hasKey("font"):
    try:
      let f = tbl["font"].getTable()
      ctx.config.fontName = f.getOrDefault("fontname").getStr(ctx.config.fontName)
    except CatchableError:
      stderr.writeLine "NimLaunch warning: ignoring invalid [font] section in " & cfgPath

  ## input
  if tbl.hasKey("input"):
    try:
      let inp = tbl["input"].getTable()
      ctx.config.prompt = inp.getOrDefault("prompt").getStr(ctx.config.prompt)
      ctx.config.cursor = inp.getOrDefault("cursor").getStr(ctx.config.cursor)
      ctx.config.vimMode = inp.getOrDefault("vim_mode").getBool(
          ctx.config.vimMode)
    except CatchableError:
      stderr.writeLine "NimLaunch warning: ignoring invalid [input] section in " & cfgPath

  ## terminal
  if tbl.hasKey("terminal"):
    try:
      let term = tbl["terminal"].getTable()
      ctx.config.terminalExe = term.getOrDefault("program").getStr(
          ctx.config.terminalExe)
    except CatchableError:
      stderr.writeLine "NimLaunch warning: ignoring invalid [terminal] section in " & cfgPath


  ## border
  if tbl.hasKey("border"):
    try:
      let b = tbl["border"].getTable()
      ctx.config.borderWidth = b.getOrDefault("width").getInt(
          ctx.config.borderWidth)
    except CatchableError:
      stderr.writeLine "NimLaunch warning: ignoring invalid [border] section in " & cfgPath

  ## icons
  if tbl.hasKey("icons"):
    try:
      let ic = tbl["icons"].getTable()
      ctx.config.showIcons = ic.getOrDefault("enabled").getBool(
          ctx.config.showIcons)
    except CatchableError:
      stderr.writeLine "NimLaunch warning: ignoring invalid [icons] section in " & cfgPath

  ## themes
  ctx.themeList = @[]
  if tbl.hasKey("themes"):
    try:
      var invalidCount = 0
      for thVal in tbl["themes"].getElems():
        try:
          let th = thVal.getTable()
          ctx.themeList.add Theme(
            name: th.getOrDefault("name").getStr(""),
            bgColorHex: th.getOrDefault("bgColorHex").getStr(""),
            fgColorHex: th.getOrDefault("fgColorHex").getStr(""),
            highlightBgColorHex: th.getOrDefault("highlightBgColorHex").getStr(
                ""),
            highlightFgColorHex: th.getOrDefault("highlightFgColorHex").getStr(
                ""),
            borderColorHex: th.getOrDefault("borderColorHex").getStr(""),
            matchFgColorHex: th.getOrDefault("matchFgColorHex").getStr("")
          )
        except CatchableError:
          inc invalidCount
      if invalidCount > 0:
        stderr.writeLine "NimLaunch warning: skipped " & $invalidCount &
            " invalid [[themes]] entries in " & cfgPath
    except CatchableError:
      stderr.writeLine "NimLaunch warning: ignoring invalid [[themes]] entries in " & cfgPath

  loadGroupsSection(tbl, cfgPath)
  loadShortcutsSection(tbl, cfgPath)
  ensureGroupDefaults()

  ## last_chosen (case-insensitive match; fallback to first theme)
  var lastName = ""
  if tbl.hasKey("theme"):
    try:
      let themeTbl = tbl["theme"].getTable()
      lastName = themeTbl.getOrDefault("last_chosen").getStr("")
    except CatchableError:
      stderr.writeLine "NimLaunch warning: ignoring invalid [theme] section in " & cfgPath
  let savedThemePath = cacheDir() / "theme"
  if fileExists(savedThemePath):
    try:
      let savedName = readFile(savedThemePath).strip()
      if savedName.len > 0:
        lastName = savedName
    except IOError, OSError:
      let e = getCurrentException()
      stderr.writeLine "NimLaunch warning: unable to read " & savedThemePath &
          " (" & $e.name & "): " & e.msg
  var pickedIndex = -1
  if lastName.len > 0:
    for i, th in ctx.themeList:
      if th.name.toLowerAscii == lastName.toLowerAscii:
        pickedIndex = i
        break
  if pickedIndex < 0:
    if ctx.themeList.len > 0: pickedIndex = 0
    else: quit("NimLaunch error: no themes defined in nimlaunch.toml")

  let chosen = ctx.themeList[pickedIndex].name
  ctx.config.themeName = chosen
  if baseMatchFgColorHex.len == 0:
    baseMatchFgColorHex = ctx.config.matchFgColorHex
  applyTheme(ctx.config, chosen)
  if configValid and chosen != lastName:
    discard saveLastTheme()

  ## guard rails for ctx.config values that affect layout/search limits
  ctx.config.winWidth = clamp(ctx.config.winWidth, 200, 4000)
  ctx.config.maxVisibleItems = clamp(ctx.config.maxVisibleItems, 1, 100)
  if ctx.config.borderWidth < 0:
    ctx.config.borderWidth = 0
  elif ctx.config.borderWidth > 64:
    ctx.config.borderWidth = 64
  if ctx.config.displayIndex < 0:
    ctx.config.displayIndex = 0
  ctx.config.pollIntervalMs = clamp(ctx.config.pollIntervalMs, 1, 1000)
  ctx.config.opacity = clamp(ctx.config.opacity, 0.1, 1.0)

  ## derived geometry
  ctx.config.winMaxHeight = gui.estimatedWindowHeight()
  let maxUsableBorder = max(0, (min(ctx.config.winWidth, ctx.config.winMaxHeight) - 1) div 2)
  if ctx.config.borderWidth > maxUsableBorder:
    ctx.config.borderWidth = maxUsableBorder
