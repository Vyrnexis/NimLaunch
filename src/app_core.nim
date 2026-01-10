## app_core.nim — port of NimLaunch logic (search, actions) for SDL2 UI.

import std/[os, strutils, tables, sets, uri,
            algorithm, heapqueue, exitprocs]
when defined(posix):
  import posix
import ./[state, parser, gui, utils, settings, paths, fuzzy, proc_utils, search, theme_session, config_actions]

when defined(posix):
  when not declared(flock):
    proc flock(fd: cint; operation: cint): cint {.importc, header: "<sys/file.h>".}

# ── Module-local globals ────────────────────────────────────────────────
var
  actions*: seq[Action]        ## transient list for the UI

const
  iconAliases = {
    "code": "visual-studio-code",
    "codium": "vscodium",
    "nvim": "nvim",
    "neovide": "nvim",
    "kitty": "kitty",
    "wezterm": "com.github.wez.wezterm",
    "alacritty": "Alacritty",
    "gnome-terminal": "utilities-terminal",
    "foot": "terminal",
    "firefox": "firefox",
    "chromium": "chromium",
    "google-chrome": "google-chrome",
    "brave-browser": "brave-browser",
    "opera": "opera",
    "vivaldi": "vivaldi",
    "edge": "microsoft-edge",
    "discord": "discord",
    "steam": "steam",
    "lutris": "lutris",
    "spotify": "spotify",
    "vlc": "vlc",
    "mpv": "mpv",
    "nautilus": "org.gnome.Nautilus",
    "dolphin": "dolphin",
    "thunar": "Thunar",
    "pcmanfm": "system-file-manager",
    "gimp": "gimp",
    "inkscape": "inkscape"
  }.toTable

var
  lockFilePath = ""
when defined(posix):
  var lockFd: cint = -1

proc pickIcon(app: DesktopApp): string =
  ## Choose an icon name for a DesktopApp, using explicit icon, alias, or base exec.
  if app.icon.len > 0:
    return app.icon
  let base = parser.getBaseExec(app.exec).toLowerAscii
  if iconAliases.hasKey(base):
    return iconAliases[base]
  base

# ── Single-instance helpers ────────────────────────────────────────────
when defined(posix):
  const
    LOCK_EX = 2.cint
    LOCK_NB = 4.cint
    LOCK_UN = 8.cint

  proc releaseSingleInstanceLock() =
    if lockFd >= 0:
      discard flock(lockFd, LOCK_UN)
      discard close(lockFd)
      lockFd = -1
    if lockFilePath.len > 0 and fileExists(lockFilePath):
      try:
        removeFile(lockFilePath)
      except CatchableError:
        discard

  proc ensureSingleInstance*(): bool =
    ## Obtain an exclusive advisory lock; return false if another instance owns it.
    let cacheDirPath = cacheDir()
    try:
      createDir(cacheDirPath)
    except CatchableError:
      discard
    lockFilePath = cacheDirPath / "nimlaunch.lock"

    let fd = open(lockFilePath.cstring, O_RDWR or O_CREAT, 0o664)
    if fd < 0:
      echo "NimLaunch warning: unable to open lock file at ", lockFilePath
      return true

    if flock(fd, LOCK_EX or LOCK_NB) != 0:
      discard close(fd)
      return false

    discard ftruncate(fd, 0)
    discard lseek(fd, 0, 0)
    let pidStr = $getCurrentProcessId() & "\n"
    discard write(fd, pidStr.cstring, pidStr.len.cint)

    lockFd = fd
    addExitProc(releaseSingleInstanceLock)
    true
else:
  proc releaseSingleInstanceLock() =
    if lockFilePath.len > 0 and fileExists(lockFilePath):
      try:
        removeFile(lockFilePath)
      except CatchableError:
        discard

  proc ensureSingleInstance*(): bool =
    ## Basic file sentinel fallback for non-POSIX targets.
    let cacheDirPath = cacheDir()
    try:
      createDir(cacheDirPath)
    except CatchableError:
      discard
    lockFilePath = cacheDirPath / "nimlaunch.lock"

    if fileExists(lockFilePath):
      return false

    try:
      writeFile(lockFilePath, $getCurrentProcessId())
      addExitProc(releaseSingleInstanceLock)
    except CatchableError:
      discard
    true

# ── Command parsing / actions helpers ───────────────────────────────────
type CmdKind* = enum
  ## Recognised input prefixes.
  ckNone,        # no special prefix
  ckTheme,       # `t:`
  ckConfig,      # `c:`
  ckSearch,      # `s:` fast file search
  ckGroup,       # user-defined group prefix
  ckShortcut,    # custom shortcuts (e.g. :g, :wiki)
  ckRun          # raw `r:` command

proc takePrefix(input, pfx: string; rest: var string): bool =
  ## Consume a command prefix and return the remainder (trimmed).
  let n = pfx.len
  if input.len >= n and input[0..n-1] == pfx:
    if input.len == n:
      rest = ""; return true
    if input.len > n:
      if input[n] == ' ':
        rest = input[n+1 .. ^1].strip(); return true
      rest = input[n .. ^1].strip(); return true
  false

proc parseCommand*(inputText: string): (CmdKind, string, int, string) =
  ## Parse *inputText* and return the command kind, remainder, shortcut index, and group name.
  if inputText.len > 0 and inputText[0] == ':':
    var body = inputText[1 .. ^1]
    var rest = ""
    let sep = body.find({' ', '\t'})
    var keyword = body
    if sep >= 0:
      keyword = body[0 ..< sep]
      rest = body[sep + 1 .. ^1].strip()
    else:
      rest = ""
    let norm = normalizePrefix(keyword)
    case norm
    of "s": return (ckSearch, rest, -1, "")
    of "c": return (ckConfig, rest, -1, "")
    of "t": return (ckTheme, rest, -1, "")
    of "r": return (ckRun, rest, -1, "")
    else:
      if config.powerPrefix.len > 0 and norm == config.powerPrefix:
        return (ckGroup, rest, -1, "power")
      for i, sc in shortcuts:
        if sc.prefix.len == 0:
          continue
        if norm == sc.prefix:
          return (ckShortcut, rest, i, "")
      if groupQueryModes.hasKey(norm):
        return (ckGroup, rest, -1, norm)
      return (ckNone, inputText, -1, "")

  var rest: string
  if takePrefix(inputText, "!", rest):
    return (ckRun, rest.strip(), -1, "")
  (ckNone, inputText, -1, "")

# ── Applications discovery (.desktop) ───────────────────────────────────
proc substituteQuery(pattern, value: string): string =
  ## Replace `{query}` placeholder or append value if absent.
  if pattern.contains("{query}"):
    result = pattern.replace("{query}", value)
  else:
    result = pattern & value

proc shortcutLabel(sc: Shortcut; query: string): string =
  ## Compose UI label for a shortcut result. Preserve user-provided spacing
  ## but inject a single space when the label doesn't already end with one.
  if sc.label.len == 0:
    return query

  if query.len == 0:
    return sc.label

  result = sc.label
  let last = sc.label[^1]
  if not last.isSpaceAscii():
    result.add ' '
  result.add query

proc shortcutExec(sc: Shortcut; query: string): string =
  ## Build the execution string for a shortcut before mode-specific handling.
  case sc.mode
  of smUrl:
    result = substituteQuery(sc.base, encodeUrl(query))
  of smShell:
    result = substituteQuery(sc.base, shellQuote(query))
  of smFile:
    result = substituteQuery(sc.base, query)

proc buildThemeActions(rest: string; defaultIndex: var int): seq[Action] =
  ## Build theme selection rows and remember the currently active index.
  defaultIndex = 0
  let ql = rest.toLowerAscii
  let currentThemeLower = config.themeName.toLowerAscii
  var idx = 0
  for th in themeList:
    if ql.len == 0 or th.name.toLowerAscii.contains(ql):
      result.add Action(kind: akTheme, label: th.name, exec: th.name, iconName: "")
      if th.name.toLowerAscii == currentThemeLower:
        defaultIndex = idx
      inc idx
  if result.len == 0:
    result.add Action(kind: akPlaceholder, label: "No matching themes", exec: "")

proc buildConfigActions(rest: string): seq[Action] =
  ## Build configuration file results under ~/.config.
  ensureConfigFilesLoaded()
  let ql = rest.toLowerAscii
  for entry in configFilesCache:
    if ql.len == 0 or entry.name.toLowerAscii.contains(ql):
      result.add Action(kind: akConfig, label: entry.name, exec: entry.exec, iconName: "")
  if result.len == 0:
    result.add Action(kind: akPlaceholder, label: "No matches", exec: "")

proc buildShortcutActions(rest: string; shortcutIdx: int): seq[Action] =
  ## Resolve a configured shortcut against the current query.
  if shortcutIdx < 0 or shortcutIdx >= shortcuts.len:
    return @[Action(kind: akPlaceholder, label: "Shortcut not found", exec: "")]
  let sc = shortcuts[shortcutIdx]
  @[Action(kind: akShortcut,
           label: shortcutLabel(sc, rest),
           exec: shortcutExec(sc, rest),
           iconName: "",
           shortcutMode: sc.mode,
           powerMode: sc.runMode,
           stayOpen: sc.stayOpen)]

proc groupQueryMode(name: string): GroupQueryMode =
  if groupQueryModes.hasKey(name): groupQueryModes[name] else: gqmFilter

proc buildGroupActions(groupName, rest: string): seq[Action] =
  ## Build grouped actions. Query mode controls pass-through vs filter.
  var entries: seq[Shortcut] = @[]
  for sc in shortcuts:
    if sc.group == groupName:
      entries.add sc
  if entries.len == 0:
    return @[Action(kind: akPlaceholder,
                    label: "No actions in group",
                    exec: "")]

  if groupQueryMode(groupName) == gqmPass:
    for sc in entries:
      let label = shortcutLabel(sc, rest)
      let exec = shortcutExec(sc, rest)
      let safeLabel = if label.len > 0: label else: sc.base
      result.add Action(kind: akShortcut,
                        label: safeLabel,
                        exec: exec,
                        iconName: "",
                        shortcutMode: sc.mode,
                        powerMode: sc.runMode,
                        stayOpen: sc.stayOpen)
    if result.len == 0:
      result.add Action(kind: akPlaceholder, label: "No matches", exec: "")
    return

  let ql = rest.strip().toLowerAscii
  for sc in entries:
    let label = if sc.label.len > 0: sc.label else: sc.base
    if ql.len == 0 or label.toLowerAscii.contains(ql):
      result.add Action(kind: akShortcut,
                        label: label,
                        exec: shortcutExec(sc, ""),
                        iconName: "",
                        shortcutMode: sc.mode,
                        powerMode: sc.runMode,
                        stayOpen: sc.stayOpen)
  if result.len == 0:
    result.add Action(kind: akPlaceholder, label: "No matches", exec: "")

proc buildRunActions(rest: string): seq[Action] =
  ## Return metadata for :r or ! commands.
  if rest.len == 0:
    return @[Action(kind: akPlaceholder, label: "Run: enter a command", exec: "")]
  @[Action(kind: akRun, label: "Run: " & rest, exec: rest, iconName: "")]

proc buildSearchActions(rest: string): seq[Action] =
  ## File search via :s — respects debounce and reuses cached results.
  let sinceEdit = gui.nowMs() - lastInputChangeMs
  if rest.len < 2 or sinceEdit < SearchDebounceMs:
    return @[Action(kind: akPlaceholder, label: "Searching…", exec: "")]

  gui.notifyStatus("Searching…", 1200)
  let restLower = rest.toLowerAscii

  var paths: seq[string]
  if lastSearchQuery.len > 0 and rest.len >= lastSearchQuery.len and
     rest.startsWith(lastSearchQuery) and lastSearchResults.len > 0:
    paths = lastSearchResults
  else:
    paths = scanFilesFast(rest)

  lastSearchQuery = rest
  lastSearchResults = paths

  let maxScore = min(paths.len, SearchShowCap)

  proc pathDepth(s: string): int =
    var d = 0
    for ch in s:
      if ch == '/': inc d
    d

  let home = getHomeDir()
  let homeDepth = block:
    var d = 0
    for ch in home:
      if ch == '/': inc d
    d
  var top = initHeapQueue[(int, string)]()
  let limit = config.maxVisibleItems
  let ql = restLower

  for idx in 0 ..< maxScore:
    let p = paths[idx]
    let name = p.extractFilename
    var s = scoreMatch(rest, name, p, home)

    let nl = name.toLowerAscii
    if nl == ql: s += 12_000
    elif nl.startsWith(ql): s += 4_000

    if p.startsWith(home & "/"):
      s += 800
      let dir = p[0 ..< max(0, p.len - name.len)]
      let relDepth = max(0, pathDepth(dir) - homeDepth)
      s -= min(relDepth, 10) * 200
      if dir == home or dir == (home & "/"):
        s += 5_000
        if name.len > 0 and name[0] == '.': s += 4_000
    else:
      s -= 2_000

    if s > -1_000_000:
      push(top, (s, p))
      if top.len > max(limit, 200): discard pop(top)

  var ranked: seq[(int, string)] = @[]
  while top.len > 0: ranked.add pop(top)
  ranked.sort(proc(a, b: (int, string)): int = cmp(b[0], a[0]))

  let showCap = max(limit, min(40, SearchShowCap))
  for i, it in ranked:
    if i >= showCap: break
    let p = it[1]
    let name = p.extractFilename
    var dir = p[0 ..< max(0, p.len - name.len)]
    while dir.len > 0 and dir[^1] == '/': dir.setLen(dir.len - 1)
    let pretty = name & " — " & shortenPath(dir)
    result.add Action(kind: akFile, label: pretty, exec: p, iconName: "")

  if result.len == 0:
    result.add Action(kind: akPlaceholder, label: "No matches", exec: "")

proc buildDefaultActions(rest: string; defaultIndex: var int): seq[Action] =
  ## Default launcher view — MRU when empty, fuzzy search otherwise.
  defaultIndex = 0
  if rest.len == 0:
    var index = initTable[string, DesktopApp](allApps.len * 2)
    for app in allApps:
      index[app.name] = app

    var seen = initHashSet[string]()
    for name in recentApps:
      if index.hasKey(name):
        let app = index[name]
        let iconName = if config.showIcons: pickIcon(app) else: ""
        result.add Action(kind: akApp, label: app.name, exec: app.exec, appData: app, iconName: iconName)
        seen.incl name

    for app in allApps:
      if not seen.contains(app.name):
        let iconName = if config.showIcons: pickIcon(app) else: ""
        result.add Action(kind: akApp, label: app.name, exec: app.exec, appData: app, iconName: iconName)
  else:
    var top = initHeapQueue[(int, int)]()
    let limit = config.maxVisibleItems
    for i, app in allApps:
      let s = scoreMatch(rest, app.name, app.name, "")
      if s > -1_000_000:
        push(top, (s + recentBoost(app.name), i))
        if top.len > limit: discard pop(top)
    var ranked: seq[(int, int)] = @[]
    while top.len > 0: ranked.add pop(top)
    ranked.sort(proc(a, b: (int, int)): int =
      result = cmp(b[0], a[0])
      if result == 0: result = cmpIgnoreCase(allApps[a[1]].name, allApps[b[1]].name)
    )
    for item in ranked:
      let app = allApps[item[1]]
      let iconName = if config.showIcons: pickIcon(app) else: ""
      result.add Action(kind: akApp, label: app.name, exec: app.exec, appData: app, iconName: iconName)

  if result.len == 0:
    result.add Action(kind: akPlaceholder, label: "No applications found", exec: "")

proc updateDisplayRows(cmd: CmdKind; highlightQuery: string; defaultIndex: int) =
  ## Sync state.filteredApps/matchSpans and maintain selection/preview state.
  filteredApps.setLen(0)
  matchSpans.setLen(0)

  for act in actions:
    filteredApps.add DisplayRow(text: act.label, iconName: act.iconName)
    if highlightQuery.len == 0:
      matchSpans.add @[]
    else:
      case act.kind
      of akRun:
        const prefix = "Run: "
        let off = if act.label.len >= prefix.len: prefix.len else: 0
        let seg = if off < act.label.len: act.label[off .. ^1] else: ""
        var spansAbs: seq[(int, int)] = @[]
        for (s, l) in subseqSpans(highlightQuery, seg): spansAbs.add (off + s, l)
        matchSpans.add spansAbs
      of akPlaceholder:
        matchSpans.add @[]
      else:
        matchSpans.add subseqSpans(highlightQuery, act.label)

  if actions.len == 0:
    if cmd == ckTheme:
      endThemePreviewSession(false)
    else:
      selectedIndex = 0
      viewOffset = 0
  else:
    let maxIndex = actions.len - 1
    var clamped = min(defaultIndex, maxIndex)
    if cmd == ckTheme and defaultIndex == 0:
      clamped = min(selectedIndex, maxIndex)
    selectedIndex = clamped
    let visible = max(1, config.maxVisibleItems)
    if clamped >= visible:
      viewOffset = clamped - visible + 1
    else:
      viewOffset = 0

    if cmd == ckTheme:
      if actions.len > 0 and actions[selectedIndex].kind == akTheme:
        updateThemePreview(cmd == ckTheme, actions, selectedIndex)
      else:
        endThemePreviewSession(false)
    else:
      endThemePreviewSession(false)

# ── Build actions & mirror to filteredApps ─────────────────────────────
proc buildActions*() =
  ## Populate `actions` based on `inputText`; mirror to GUI lists/spans.
  let (cmd, rest, shortcutIdx, groupName) = parseCommand(inputText)
  var defaultIndex = 0
  var nextActions: seq[Action] = @[]

  case cmd
  of ckTheme:
    beginThemePreviewSession()
    nextActions = buildThemeActions(rest, defaultIndex)
  of ckConfig:
    nextActions = buildConfigActions(rest)
  of ckShortcut:
    nextActions = buildShortcutActions(rest, shortcutIdx)
  of ckGroup:
    nextActions = buildGroupActions(groupName, rest)
  of ckSearch:
    nextActions = buildSearchActions(rest)
  of ckRun:
    nextActions = buildRunActions(rest)
  else:
    discard

  if cmd == ckNone:
    nextActions = buildDefaultActions(rest, defaultIndex)
  elif nextActions.len == 0:
    nextActions.add Action(kind: akPlaceholder, label: "No matches", exec: "")

  actions = nextActions
  updateDisplayRows(cmd, rest, defaultIndex)

# ── Perform selected action ─────────────────────────────────────────────
proc clearInput*() =
  inputText.setLen(0)
  lastInputChangeMs = gui.nowMs()
  buildActions()

proc performAction*(a: Action) =
  var exitAfter = true ## default: exit after action
  case a.kind
  of akRun:
    runCommand(a.exec)
  of akConfig:
    if not spawnShellCommand(a.exec):
      gui.notifyStatus("Failed: " & a.label, 1600)
      exitAfter = false
  of akFile:
    if not openPathWithFallback(a.exec):
      gui.notifyStatus("Failed to open: " & a.label, 1600)
      exitAfter = false
  of akApp:
    ## safer: strip .desktop field codes before launching
    let sanitized = parser.stripFieldCodes(a.exec).strip()
    if spawnShellCommand(sanitized):
      let ri = recentApps.find(a.label)
      if ri >= 0: recentApps.delete(ri)
      recentApps.insert(a.label, 0)
      if recentApps.len > maxRecent: recentApps.setLen(maxRecent)
      saveRecent()
    else:
      gui.notifyStatus("Failed: " & a.label, 1600)
      exitAfter = false
  of akShortcut:
    case a.shortcutMode
    of smUrl:
      openUrl(a.exec)
    of smShell:
      var success = true
      case a.powerMode
      of pamSpawn:
        success = spawnShellCommand(a.exec)
      of pamTerminal:
        runCommand(a.exec)
      if not success:
        gui.notifyStatus("Failed: " & a.label, 1600)
        exitAfter = false
    of smFile:
      let expanded = a.exec.expandTilde()
      if not fileExists(expanded) and not dirExists(expanded):
        gui.notifyStatus("Not found: " & shortenPath(expanded, 50), 1600)
        exitAfter = false
      elif not openPathWithFallback(expanded):
        gui.notifyStatus("Failed to open: " & shortenPath(expanded, 50), 1600)
        exitAfter = false
    if exitAfter and a.stayOpen:
      exitAfter = false
  of akPower:
    var success = true
    case a.powerMode
    of pamSpawn:
      success = spawnShellCommand(a.exec)
    of pamTerminal:
      runCommand(a.exec)
    if not success:
      gui.notifyStatus("Failed: " & a.label, 1600)
      exitAfter = false
    elif a.stayOpen:
      exitAfter = false
  of akTheme:
    ## Apply and persist, but DO NOT reset selection or exit.
    applyThemeAndColors(config, a.exec, doNotify = false)
    saveLastTheme(configDir() / "nimlaunch.toml")
    endThemePreviewSession(true)
    clearInput()
    gui.redrawWindow()
    exitAfter = false
  of akPlaceholder:
    exitAfter = false
  if exitAfter: shouldExit = true

# ── Input/navigation helpers ───────────────────────────────────────────
proc deleteLastInputChar*() =
  if inputText.len > 0:
    inputText.setLen(inputText.len - 1)
    lastInputChangeMs = gui.nowMs()
    buildActions()

proc activateCurrentSelection*() =
  if selectedIndex in 0..<actions.len:
    performAction(actions[selectedIndex])

proc moveSelectionBy*(step: int) =
  if filteredApps.len == 0: return
  var newIndex = selectedIndex + step
  if newIndex < 0: newIndex = 0
  if newIndex > filteredApps.len - 1: newIndex = filteredApps.len - 1
  if newIndex == selectedIndex: return
  selectedIndex = newIndex
  if selectedIndex < viewOffset:
    viewOffset = selectedIndex
  elif selectedIndex >= viewOffset + config.maxVisibleItems:
    viewOffset = selectedIndex - config.maxVisibleItems + 1
    if viewOffset < 0: viewOffset = 0
  updateThemePreview(parseCommand(inputText)[0] == ckTheme, actions, selectedIndex)

proc jumpToTop*() =
  if filteredApps.len == 0: return
  selectedIndex = 0
  viewOffset = 0
  updateThemePreview(parseCommand(inputText)[0] == ckTheme, actions, selectedIndex)

proc jumpToBottom*() =
  if filteredApps.len == 0: return
  selectedIndex = filteredApps.len - 1
  let start = filteredApps.len - config.maxVisibleItems
  viewOffset = if start > 0: start else: 0
  updateThemePreview(parseCommand(inputText)[0] == ckTheme, actions, selectedIndex)
