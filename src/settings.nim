## settings.nim — config/theme loading for NimLaunch SDL2.

import std/[os, strutils, math, options, tables]
import parsetoml as toml
import ./[state as st, gui, utils, paths]

var
  baseMatchFgColorHex = ""     ## default fallback for match highlight colour

proc applyTheme*(cfg: var Config; name: string) =
  ## Set theme fields from `themeList` by name; respect explicit match color.
  let fallbackMatch = if baseMatchFgColorHex.len > 0:
    baseMatchFgColorHex
  else:
    cfg.matchFgColorHex
  for i, th in st.themeList:
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

proc updateParsedColors*(cfg: var Config) =
  ## Resolve hex → RGB colours for SDL rendering.
  let bg = parseHexRgb8(cfg.bgColorHex)
  let fg = parseHexRgb8(cfg.fgColorHex)
  let hbg = parseHexRgb8(cfg.highlightBgColorHex)
  let hfg = parseHexRgb8(cfg.highlightFgColorHex)
  let border = parseHexRgb8(cfg.borderColorHex)
  let match = parseHexRgb8(cfg.matchFgColorHex)
  if isNone(bg) or isNone(fg) or isNone(hbg) or isNone(hfg) or isNone(border) or isNone(match):
    quit "Invalid colour in theme configuration"
  cfg.bgColor = get(bg)
  cfg.fgColor = get(fg)
  cfg.highlightBgColor = get(hbg)
  cfg.highlightFgColor = get(hfg)
  cfg.borderColor = get(border)
  cfg.matchFgColor = get(match)

proc applyThemeAndColors*(cfg: var Config; name: string; doNotify = true) =
  ## Apply theme, resolve colors, push to GUI, and optionally redraw.
  applyTheme(cfg, name)
  updateParsedColors(cfg)
  gui.updateGuiColors()
  if doNotify:
    gui.notifyThemeChanged(name)
    gui.redrawWindow()

proc saveLastTheme*(cfgPath: string) =
  ## Update or insert [theme].last_chosen = "<name>" in the TOML file.
  var lines: seq[string]
  try:
    lines = readFile(cfgPath).splitLines()
  except CatchableError as e:
    echo "saveLastTheme warning: unable to read ", cfgPath, " (", e.name, "): ", e.msg
    return
  var inTheme = false
  var updated = false
  var themeSectionFound = false
  for i in 0..<lines.len:
    let l = lines[i].strip()
    if l == "[theme]":
      inTheme = true
      themeSectionFound = true
      continue
    if inTheme:
      if l.startsWith("[") and l.endsWith("]"):
        lines.insert("last_chosen = \"" & st.config.themeName & "\"", i)
        updated = true
        inTheme = false
        break
      if l.startsWith("last_chosen"):
        lines[i] = "last_chosen = \"" & st.config.themeName & "\""
        updated = true
        inTheme = false
        break
  if inTheme and not updated:
    lines.add("last_chosen = \"" & st.config.themeName & "\"")
    updated = true
  if not themeSectionFound:
    lines.add("")
    lines.add("[theme]")
    lines.add("last_chosen = \"" & st.config.themeName & "\"")
    updated = true
  if updated:
    try:
      writeFile(cfgPath, lines.join("\n"))
    except CatchableError as e:
      echo "saveLastTheme warning: unable to write ", cfgPath, " (", e.name, "): ", e.msg

proc loadShortcutsSection(tbl: toml.TomlValueRef; cfgPath: string) =
  ## Populate `state.shortcuts` from `[[shortcuts]]` entries in *tbl*.
  st.shortcuts = @[]
  if not tbl.hasKey("shortcuts"): return

  try:
    for scVal in tbl["shortcuts"].getElems():
      let scTbl = scVal.getTable()
      let prefixRaw = scTbl.getOrDefault("prefix").getStr("")
      var prefix = normalizePrefix(prefixRaw)
      let base = scTbl.getOrDefault("base").getStr("").strip()
      let label = scTbl.getOrDefault("label").getStr("").strip(chars = {'\t', '\r', '\n'})
      let modeStr = scTbl.getOrDefault("mode").getStr("url").toLowerAscii
      let group = scTbl.getOrDefault("group").getStr("").strip().toLowerAscii
      let runModeStr = scTbl.getOrDefault("run_mode").getStr("").strip().toLowerAscii
      let stayOpen = scTbl.getOrDefault("stay_open").getBool(false)

      if base.len == 0:
        continue
      if group.len > 0:
        prefix.setLen(0) # groups use their own prefix; ignore per-entry prefixes
      if prefix.len == 0 and group.len == 0:
        continue

      var mode = smUrl
      case modeStr
      of "shell": mode = smShell
      of "file": mode = smFile
      else: discard
      if group == "power" and mode != smShell:
        mode = smShell

      var runMode = pamTerminal
      case runModeStr
      of "spawn": runMode = pamSpawn
      of "terminal": runMode = pamTerminal
      else: discard

      st.shortcuts.add Shortcut(prefix: prefix,
                                label: label,
                                base: base,
                                mode: mode,
                                group: group,
                                runMode: runMode,
                                stayOpen: stayOpen)
  except CatchableError:
    echo "NimLaunch warning: ignoring invalid [[shortcuts]] entries in ", cfgPath

proc parseGroupQueryMode(modeStr: string): GroupQueryMode =
  case modeStr
  of "pass", "passthrough", "pass-through": gqmPass
  else: gqmFilter

proc loadGroupsSection(tbl: toml.TomlValueRef; cfgPath: string) =
  ## Populate `state.groupQueryModes` from `[[groups]]` entries in *tbl*.
  st.groupQueryModes = initTable[string, GroupQueryMode]()
  if not tbl.hasKey("groups"): return

  try:
    for grpVal in tbl["groups"].getElems():
      let grpTbl = grpVal.getTable()
      let name = grpTbl.getOrDefault("name").getStr("").strip().toLowerAscii
      if name.len == 0:
        continue
      let modeStr = grpTbl.getOrDefault("query_mode").getStr("filter").strip().toLowerAscii
      st.groupQueryModes[name] = parseGroupQueryMode(modeStr)
  except CatchableError:
    echo "NimLaunch warning: ignoring invalid [[groups]] entries in ", cfgPath

proc ensureGroupDefaults() =
  ## Ensure every shortcut group exists with a default query mode.
  for sc in st.shortcuts:
    if sc.group.len == 0: continue
    if not st.groupQueryModes.hasKey(sc.group):
      st.groupQueryModes[sc.group] = gqmFilter

proc loadPowerSection(tbl: toml.TomlValueRef; cfgPath: string) =
  ## Populate the power prefix from [power].
  if not tbl.hasKey("power"):
    return
  try:
    let p = tbl["power"].getTable()
    let rawPrefix = p.getOrDefault("prefix").getStr(st.config.powerPrefix)
    st.config.powerPrefix = normalizePrefix(rawPrefix)
  except CatchableError:
    echo "NimLaunch warning: ignoring invalid [power] section in ", cfgPath

proc initLauncherConfig*() =
  ## Initialize defaults, read TOML, apply last theme, compute geometry.
  st.config = Config() # zero-init
  st.groupQueryModes = initTable[string, GroupQueryMode]()

  ## In-code defaults
  st.config.winWidth = 500
  st.config.lineHeight = 22
  st.config.maxVisibleItems = 10
  st.config.centerWindow = true
  st.config.positionX = 20
  st.config.positionY = 500
  st.config.verticalAlign = "one-third"
  st.config.fontName = "Dejavu:size=16"
  st.config.prompt = "> "
  st.config.cursor = "_"
  st.config.opacity = 1.0
  st.config.terminalExe = "gnome-terminal"
  st.config.borderWidth = 2
  st.config.matchFgColorHex = "#f8c291"
  st.config.powerPrefix = normalizePrefix("p:")
  st.config.vimMode = false
  st.config.showIcons = true

  ## Ensure TOML exists
  let cfgDir = configDir()
  let cfgPath = cfgDir / "nimlaunch.toml"
  if not fileExists(cfgPath):
    createDir(cfgDir)
    writeFile(cfgPath, defaultToml)
    echo "Created default config at ", cfgPath

  ## Parse TOML
  var tbl: toml.TomlValueRef
  try:
    tbl = toml.parseFile(cfgPath)
  except CatchableError as e:
    echo "NimLaunch warning: invalid TOML in ", cfgPath, " (", e.name, "): ", e.msg
    tbl = toml.parseString(defaultToml)

  ## window
  if tbl.hasKey("window"):
    try:
      let w = tbl["window"].getTable()
      st.config.winWidth = w.getOrDefault("width").getInt(st.config.winWidth)
      st.config.maxVisibleItems = w.getOrDefault("max_visible_items").getInt(st.config.maxVisibleItems)
      st.config.centerWindow = w.getOrDefault("center").getBool(st.config.centerWindow)
      st.config.positionX = w.getOrDefault("position_x").getInt(st.config.positionX)
      st.config.positionY = w.getOrDefault("position_y").getInt(st.config.positionY)
      st.config.verticalAlign = w.getOrDefault("vertical_align").getStr(st.config.verticalAlign)
      st.config.opacity = w.getOrDefault("opacity").getFloat(st.config.opacity)
    except CatchableError:
      echo "NimLaunch warning: ignoring invalid [window] section in ", cfgPath

  ## font
  if tbl.hasKey("font"):
    try:
      let f = tbl["font"].getTable()
      st.config.fontName = f.getOrDefault("fontname").getStr(st.config.fontName)
    except CatchableError:
      echo "NimLaunch warning: ignoring invalid [font] section in ", cfgPath

  ## input
  if tbl.hasKey("input"):
    try:
      let inp = tbl["input"].getTable()
      st.config.prompt = inp.getOrDefault("prompt").getStr(st.config.prompt)
      st.config.cursor = inp.getOrDefault("cursor").getStr(st.config.cursor)
      st.config.vimMode = inp.getOrDefault("vim_mode").getBool(st.config.vimMode)
    except CatchableError:
      echo "NimLaunch warning: ignoring invalid [input] section in ", cfgPath

  ## terminal
  if tbl.hasKey("terminal"):
    try:
      let term = tbl["terminal"].getTable()
      st.config.terminalExe = term.getOrDefault("program").getStr(st.config.terminalExe)
    except CatchableError:
      echo "NimLaunch warning: ignoring invalid [terminal] section in ", cfgPath

  ## border
  if tbl.hasKey("border"):
    try:
      let b = tbl["border"].getTable()
      st.config.borderWidth = b.getOrDefault("width").getInt(st.config.borderWidth)
    except CatchableError:
      echo "NimLaunch warning: ignoring invalid [border] section in ", cfgPath

  ## icons
  if tbl.hasKey("icons"):
    try:
      let ic = tbl["icons"].getTable()
      st.config.showIcons = ic.getOrDefault("enabled").getBool(st.config.showIcons)
    except CatchableError:
      echo "NimLaunch warning: ignoring invalid [icons] section in ", cfgPath

  ## themes
  st.themeList = @[]
  if tbl.hasKey("themes"):
    try:
      for thVal in tbl["themes"].getElems():
        let th = thVal.getTable()
        st.themeList.add Theme(
          name: th.getOrDefault("name").getStr(""),
          bgColorHex: th.getOrDefault("bgColorHex").getStr(""),
          fgColorHex: th.getOrDefault("fgColorHex").getStr(""),
          highlightBgColorHex: th.getOrDefault("highlightBgColorHex").getStr(""),
          highlightFgColorHex: th.getOrDefault("highlightFgColorHex").getStr(""),
          borderColorHex: th.getOrDefault("borderColorHex").getStr(""),
          matchFgColorHex: th.getOrDefault("matchFgColorHex").getStr("")
        )
    except CatchableError:
      echo "NimLaunch warning: ignoring invalid [[themes]] entries in ", cfgPath

  loadGroupsSection(tbl, cfgPath)
  loadShortcutsSection(tbl, cfgPath)
  ensureGroupDefaults()
  loadPowerSection(tbl, cfgPath)

  ## last_chosen (case-insensitive match; fallback to first theme)
  var lastName = ""
  if tbl.hasKey("theme"):
    try:
      let themeTbl = tbl["theme"].getTable()
      lastName = themeTbl.getOrDefault("last_chosen").getStr("")
    except CatchableError:
      echo "NimLaunch warning: ignoring invalid [theme] section in ", cfgPath
  var pickedIndex = -1
  if lastName.len > 0:
    for i, th in st.themeList:
      if th.name.toLowerAscii == lastName.toLowerAscii:
        pickedIndex = i
        break
  if pickedIndex < 0:
    if st.themeList.len > 0: pickedIndex = 0
    else: quit("NimLaunch error: no themes defined in nimlaunch.toml")

  let chosen = st.themeList[pickedIndex].name
  st.config.themeName = chosen
  if baseMatchFgColorHex.len == 0:
    baseMatchFgColorHex = st.config.matchFgColorHex
  applyTheme(st.config, chosen)
  if chosen != lastName:
    saveLastTheme(cfgPath)

  ## guard rails for config values that affect layout/search limits
  if st.config.maxVisibleItems < 1:
    st.config.maxVisibleItems = 1
  if st.config.borderWidth < 0:
    st.config.borderWidth = 0
  st.config.opacity = clamp(st.config.opacity, 0.1, 1.0)

  ## derived geometry
  st.config.winMaxHeight = 40 + st.config.maxVisibleItems * st.config.lineHeight
