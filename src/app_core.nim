## app_core.nim — NimLaunch application logic for search, actions, and launch flow.

import std/[os, strutils, tables, sets, uri,
            algorithm, heapqueue, exitprocs, syncio, times]
when defined(posix):
  import posix
from std/unicode import toLower
import ./[state, parser, gui, utils, settings, paths, fuzzy, proc_utils, search]

when defined(posix):
  when not declared(flock):
    proc flock(fd: cint; operation: cint): cint {.importc,
        header: "<sys/file.h>".}

# ── Module-local globals ────────────────────────────────────────────────
const
  DefaultAppSearchCap = 200
  ## Generic-name and keyword hits score in a band between Name acronym matches
  ## (at most 4250) and Name substring matches (at least 5250): they rank below
  ## any Name match at substring tier or better but above fuzzy Name matches.
  SecondaryBase = 4400
  SecondaryTierStep = 200
  iconAliases = {
    "code": "visual-studio-code",
    "codium": "vscodium",
    "neovide": "nvim",
    "wezterm": "com.github.wez.wezterm",
    "alacritty": "Alacritty",
    "gnome-terminal": "utilities-terminal",
    "foot": "terminal",
    "edge": "microsoft-edge",
    "nautilus": "org.gnome.Nautilus",
    "thunar": "Thunar",
    "pcmanfm": "system-file-manager"
  }.toTable

var
  lockFilePath = ""
  pendingSearchQuery = ""
  pendingSearchGeneration = 0
when defined(posix):
  var lockFd: cint = -1

proc buildActions*()

# ── Theme preview session ──
proc beginThemePreviewSession*() =
  if not ctx.themePreviewActive:
    ctx.themePreviewActive = true
    ctx.themePreviewBaseTheme = ctx.config.themeName
    ctx.themePreviewCurrent = ctx.config.themeName

proc endThemePreviewSession*(persist: bool) =
  if not ctx.themePreviewActive:
    return
  if persist:
    ctx.themePreviewBaseTheme = ctx.config.themeName
    ctx.themePreviewCurrent = ctx.config.themeName
  else:
    if ctx.themePreviewBaseTheme.len > 0 and ctx.themePreviewCurrent.len > 0 and
       ctx.themePreviewCurrent != ctx.themePreviewBaseTheme:
      applyThemeAndColors(ctx.config, ctx.themePreviewBaseTheme, doRedraw = false)
      ctx.themePreviewCurrent = ctx.themePreviewBaseTheme
  ctx.themePreviewActive = false

proc updateThemePreview*(isThemeCmd: bool; selectedIndex: int) =
  if not isThemeCmd:
    return
  if ctx.actions.len == 0:
    endThemePreviewSession(false)
    return
  beginThemePreviewSession()
  if selectedIndex < 0 or selectedIndex >= ctx.actions.len:
    return
  let act = ctx.actions[selectedIndex]
  if act.kind != akTheme:
    return
  let name = act.exec
  if ctx.themePreviewCurrent == name:
    return
  applyThemeAndColors(ctx.config, name, doRedraw = false)
  ctx.themePreviewCurrent = name

proc pickIcon(app: DesktopApp): string =
  ## Choose an icon name for a DesktopApp, using explicit icon, alias, or base exec.
  if app.icon.len > 0:
    return app.icon
  let base = parser.getBaseExec(app.exec).toLowerAscii
  if iconAliases.hasKey(base):
    return iconAliases[base]
  base

proc pickDesktopActionIcon(app: DesktopApp; action: DesktopEntryAction): string =
  ## Select the icon for a desktop secondary action or fallback to the app icon.
  if action.icon.len > 0:
    return action.icon
  pickIcon(app)

proc addDesktopActionRows(rows: var seq[Action]; appIndex: int;
    spans: seq[(int, int)]) =
  ## Append desktop action rows for ctx.allApps[appIndex] to the action list.
  ## The labels start with the app name, so its match spans stay valid.
  for desktopAction in ctx.allApps[appIndex].desktopActions:
    let iconName =
      if ctx.config.showIcons:
        pickDesktopActionIcon(ctx.allApps[appIndex], desktopAction)
      else: ""
    rows.add Action(
      kind: akAppAction,
      label: ctx.allApps[appIndex].name & " · " & desktopAction.name,
      exec: desktopAction.exec,
      appIndex: appIndex,
      iconName: iconName,
      desktopName: desktopAction.name,
      desktopIcon: desktopAction.icon,
      spans: spans
    )

# ── Single-instance helpers ────────────────────────────────────────────
when defined(posix):
  const
    LOCK_EX = 2.cint
    LOCK_NB = 4.cint
    LOCK_UN = 8.cint

  proc releaseSingleInstanceLock() =
    ## Release advisory file lock and cleanup lock file descriptor.
    if lockFd >= 0:
      discard flock(lockFd, LOCK_UN)
      discard close(lockFd)
      lockFd = -1

  proc ensureSingleInstance*(): bool =
    ## Obtain an exclusive advisory lock; return false if another instance owns it.
    let cacheDirPath = cacheDir()
    try:
      createDir(cacheDirPath)
    except CatchableError:
      discard
    lockFilePath = cacheDirPath / "nimlaunch.lock"

    var openFlags = O_RDWR or O_CREAT
    when declared(O_CLOEXEC):
      openFlags = openFlags or O_CLOEXEC
    let fd = open(lockFilePath.cstring, openFlags, 0o600)
    if fd < 0:
      stderr.writeLine "NimLaunch warning: unable to open lock file at " & lockFilePath
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

  proc closeRunningInstance*(): bool =
    ## Ask the instance that holds the lock to quit (hotkey toggle behaviour).
    ## SDL turns SIGTERM into EVENT_QUIT, so the other instance shuts down cleanly.
    var pid = 0
    try:
      pid = parseInt(readFile(lockFilePath).strip())
    except CatchableError:
      return false
    if pid <= 0 or pid == getCurrentProcessId():
      return false
    try:
      if readFile("/proc/" & $pid & "/comm").strip() != "nimlaunch":
        return false
    except CatchableError:
      discard # no procfs: trust the lock holder's PID
    kill(Pid(pid), SIGTERM) == 0
else:
  proc releaseSingleInstanceLock() =
    ## Clean up lock file sentinel.
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

  proc closeRunningInstance*(): bool =
    ## Signalling another instance is only supported on POSIX.
    false

# ── Command parsing / action helpers ───────────────────────────────────
type CmdKind* = enum
  ## Recognised input prefixes.
  ckNone,     # no special prefix
  ckTheme,    # `t:`
  ckConfig,   # `c:`
  ckSearch,   # `s:` fast file search
  ckGroup,    # user-defined group prefix
  ckShortcut, # custom shortcuts (e.g. :g, :wiki)
  ckRun,      # raw `r:` command
  ckQuit      # `:q` or `:quit` to exit

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
    of "q", "quit": return (ckQuit, rest, -1, "")
    else:
      for i, sc in ctx.shortcuts:
        if sc.prefix.len == 0:
          continue
        if norm == sc.prefix:
          return (ckShortcut, rest, i, "")
      if ctx.groupQueryModes.hasKey(norm):
        return (ckGroup, rest, -1, norm)
      return (ckNone, inputText, -1, "")

  var rest: string
  if takePrefix(inputText, "!", rest):
    return (ckRun, rest.strip(), -1, "")
  (ckNone, inputText, -1, "")

# ── Shortcut helpers ────────────────────────────────────────────────────
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
    result = substituteQuery(sc.base, quoteShell(query))
  of smFile:
    result = substituteQuery(sc.base, query)

proc shortcutAction(sc: Shortcut; label, exec: string;
    spans: seq[(int, int)] = @[]): Action =
  ## Build a shortcut result row carrying the shortcut's launch settings.
  Action(kind: akShortcut,
         label: label,
         exec: exec,
         iconName: "",
         shortcutMode: sc.mode,
         powerMode: sc.runMode,
         stayOpen: sc.stayOpen,
         spans: spans)

proc labelSpans(queryLower, label: string): seq[(int, int)] =
  ## Highlight ranges of a label for the lowercased query.
  discard fuzzyMatch(queryLower, label, "", result)

proc querySpans(label, query: string): seq[(int, int)] =
  ## Highlight the typed query when it is the tail of a pass-through label.
  if query.len > 0 and label.len >= query.len and label.endsWith(query):
    result.add (label.len - query.len, query.len)

proc byScoreThenIndex(a, b: (int, int)): int =
  result = cmp(b[0], a[0])
  if result == 0:
    result = cmp(a[1], b[1])

template rankByLabel(count: int; queryLower: string; minTier: MatchTier;
    labelExpr: untyped): seq[int] =
  ## Indices 0 ..< count whose label (an expression using `idx`) matches the
  ## query at `minTier` or better, best match first and ties in list order.
  block:
    var scored: seq[(int, int)] = @[]
    for idx {.inject.} in 0 ..< count:
      let score = fuzzyScore(queryLower, labelExpr, "", minTier)
      if score != NoMatch:
        scored.add (score, idx)
    scored.sort(byScoreThenIndex)
    var order: seq[int] = @[]
    for item in scored:
      order.add item[1]
    order

proc buildThemeActions(rest: string; defaultIndex: var int): seq[Action] =
  ## Build theme selection rows; with an empty query remember the active row.
  defaultIndex = 0
  let ql = toLower(rest)
  let currentThemeLower = ctx.config.themeName.toLowerAscii
  var order: seq[int] = @[]
  if ql.len == 0:
    for i in 0 ..< ctx.themeList.len:
      order.add i
  else:
    order = rankByLabel(ctx.themeList.len, ql, mtSubsequence,
        ctx.themeList[idx].name)
  for row, i in order:
    let name = ctx.themeList[i].name
    result.add Action(kind: akTheme, label: name, exec: name, iconName: "",
        spans: labelSpans(ql, name))
    if ql.len == 0 and name.toLowerAscii == currentThemeLower:
      defaultIndex = row
  if result.len == 0:
    result.add Action(kind: akPlaceholder, label: "No matching themes", exec: "")

# ── ~/.config discovery ──
proc loadConfigFiles() =
  ## Build the cached ~/.config file list once per run.
  ctx.configFilesCache.setLen(0)
  let base = userConfigHome()
  try:
    for path in walkDirDepth(base, maxDepth = 2, yieldFilter = {pcFile}):
      let fn = path.extractFilename
      if fn.len == 0: continue
      ctx.configFilesCache.add DesktopApp(
        name: fn,
        exec: path
      )
    ctx.configFilesLoaded = true
  except CatchableError as e:
    ctx.configFilesLoaded = false
    echo "loadConfigFiles warning: ", e.name, " ", e.msg

proc ensureConfigFilesLoaded() =
  if not ctx.configFilesLoaded:
    loadConfigFiles()

proc buildConfigActions(rest: string): seq[Action] =
  ## Build configuration file results under ~/.config.
  ensureConfigFilesLoaded()
  let ql = toLower(rest)
  var order: seq[int] = @[]
  if ql.len == 0:
    for i in 0 ..< ctx.configFilesCache.len:
      order.add i
  else:
    ## Large list: skip the loosest tiers (subsequence, typo) to limit noise.
    order = rankByLabel(ctx.configFilesCache.len, ql, mtAcronym,
        ctx.configFilesCache[idx].name)
  for i in order:
    let entry = ctx.configFilesCache[i]
    result.add Action(kind: akConfig, label: entry.name, exec: entry.exec,
        iconName: "", spans: labelSpans(ql, entry.name))
  if result.len == 0:
    result.add Action(kind: akPlaceholder, label: "No matches", exec: "")

proc buildShortcutActions(rest: string; shortcutIdx: int): seq[Action] =
  ## Resolve a configured shortcut against the current query.
  if shortcutIdx < 0 or shortcutIdx >= ctx.shortcuts.len:
    return @[Action(kind: akPlaceholder, label: "Shortcut not found", exec: "")]
  let sc = ctx.shortcuts[shortcutIdx]
  let label = shortcutLabel(sc, rest)
  @[shortcutAction(sc, label, shortcutExec(sc, rest), querySpans(label, rest))]

proc groupQueryMode(name: string): GroupQueryMode =
  if ctx.groupQueryModes.hasKey(name): ctx.groupQueryModes[name] else: gqmFilter

proc buildGroupActions(groupName, rest: string): seq[Action] =
  ## Build grouped actions. Query mode controls pass-through vs filter.
  var entries: seq[Shortcut] = @[]
  for sc in ctx.shortcuts:
    if sc.group == groupName:
      entries.add sc
  if entries.len == 0:
    return @[Action(kind: akPlaceholder,
                    label: "No actions in group",
                    exec: "")]

  if groupQueryMode(groupName) == gqmPass:
    if rest.len == 0:
      return @[Action(kind: akPlaceholder, label: "Enter a query", exec: "")]
    for sc in entries:
      let label = shortcutLabel(sc, rest)
      let exec = shortcutExec(sc, rest)
      let safeLabel = if label.len > 0: label else: sc.base
      result.add shortcutAction(sc, safeLabel, exec, querySpans(safeLabel, rest))
    if result.len == 0:
      result.add Action(kind: akPlaceholder, label: "No matches", exec: "")
    return

  let ql = toLower(rest.strip())
  var labels: seq[string] = @[]
  for sc in entries:
    labels.add(if sc.label.len > 0: sc.label else: sc.base)
  var order: seq[int] = @[]
  if ql.len == 0:
    for i in 0 ..< entries.len:
      order.add i
  else:
    order = rankByLabel(labels.len, ql, mtSubsequence, labels[idx])
  for i in order:
    result.add shortcutAction(entries[i], labels[i], shortcutExec(entries[i], ""),
        labelSpans(ql, labels[i]))
  if result.len == 0:
    result.add Action(kind: akPlaceholder, label: "No matches", exec: "")

proc buildRunActions(rest: string): seq[Action] =
  ## Return metadata for :r or ! commands.
  if rest.len == 0:
    return @[Action(kind: akPlaceholder, label: "Run: enter a command", exec: "")]
  const prefix = "Run: "
  @[Action(kind: akRun, label: prefix & rest, exec: rest, iconName: "",
      spans: @[(prefix.len, rest.len)])]

proc pathDepth(path: string): int =
  ## Count directory separators in path.
  path.count('/')

proc scoreSearchCandidate*(query: string; queryLower: string; fileName: string;
                           path: string; homeDir: string; homeDepth: int): int =
  ## Score a file-search hit; `homeDir` must not end with a slash.
  let inHome = homeDir.len > 0 and path.startsWith(homeDir & "/")
  var score = fuzzyScore(queryLower, fileName, "")
  case matchTier(score)
  of mtExact:
    score += 12_000
    if inHome: score += 600
  of mtPrefix:
    score += 4_000
    if inHome: score += 400
  else:
    discard

  if inHome:
    score += 800
    let directory = path[0 ..< max(0, path.len - fileName.len)].strip(
        leading = false, chars = {'/'})
    let relativeDepth = max(0, pathDepth(directory) - homeDepth)
    score -= min(relativeDepth, 10) * 200
    if directory == homeDir:
      score += 5_000
      if fileName.len > 0 and fileName[0] == '.':
        score += 4_000
  else:
    score -= 2_000

  score

proc narrowSearchPaths*(paths: seq[string]; queryLower: string): seq[string] =
  ## Keep paths whose full lowercased path contains the query: a superset
  ## filter for a query that extends the one `paths` was found for.
  for path in paths:
    if queryLower in toLower(path):
      result.add path

proc buildSearchActions(rest: string): seq[Action] =
  ## File search via :s — respects debounce and reuses cached results.
  let sinceEdit = gui.nowMs() - ctx.lastInputChangeMs
  if rest.len < 2 or sinceEdit < SearchDebounceMs:
    return @[Action(kind: akPlaceholder, label: "Searching…", exec: "")]

  gui.notifyStatus("Searching…", 1200)
  let restLower = toLower(rest)

  var paths: seq[string]
  if lastSearchQuery.len > 0 and rest.len >= lastSearchQuery.len and
     rest.startsWith(lastSearchQuery) and lastSearchResults.len > 0 and
     lastSearchResults.len < SearchFdCap:
    paths = narrowSearchPaths(lastSearchResults, restLower)
  elif getCachedSearchResults(rest, paths):
    discard
  else:
    if pendingSearchQuery != rest:
      let generation = requestFileSearch(rest)
      if generation > 0:
        pendingSearchQuery = rest
        pendingSearchGeneration = generation
    return @[Action(kind: akPlaceholder, label: "Searching…", exec: "")]

  lastSearchQuery = rest
  lastSearchResults = paths

  let homeDir = homeDirNoSlash()
  let homeDepth = pathDepth(homeDir)
  var topScores = initHeapQueue[(int, string)]()
  let showCap = max(ctx.config.maxVisibleItems, 40)
  let queryLower = restLower

  for idx in 0 ..< paths.len:
    let path = paths[idx]
    let fileName = path.extractFilename
    let score = scoreSearchCandidate(rest, queryLower, fileName, path, homeDir, homeDepth)
    push(topScores, (score, path))
    if topScores.len > showCap: discard pop(topScores)

  var ranked: seq[(int, string)] = @[]
  while topScores.len > 0: ranked.add pop(topScores)
  ranked.reverse()

  for it in ranked:
    let path = it[1]
    let fileName = path.extractFilename
    let directory = os.parentDir(path)
    let pretty = fileName & " — " & shortenPath(directory)
    result.add Action(kind: akFile, label: pretty, exec: path, iconName: "",
        spans: labelSpans(queryLower, fileName))

  if result.len == 0:
    result.add Action(kind: akPlaceholder, label: "No matches", exec: "")

## Apply the latest completed file search and rebuild matching actions.
proc pollSearchUpdates*(): bool =
  var response: SearchResponse
  while pollFileSearch(response):
    if response.generation == pendingSearchGeneration:
      pendingSearchQuery.setLen(0)
      pendingSearchGeneration = 0
      if response.complete:
        cacheSearchResults(response.query, response.paths)
      let (cmd, rest, _, _) = parseCommand(ctx.inputText)
      if cmd == ckSearch:
        if response.complete and rest == response.query:
          lastSearchQuery = response.query
          lastSearchResults = response.paths
        buildActions()
        result = true

proc parseDmenuLine*(line: string): DmenuItem =
  ## Parse `label\0key\x1fvalue\x1fkey\x1fvalue...` (rofi row options).
  ## Unknown keys are ignored.
  let nullPos = line.find('\0')
  result.label = if nullPos == -1: line else: line[0 ..< nullPos]
  if nullPos != -1:
    let parts = line[nullPos + 1 .. ^1].split('\x1f')
    var i = 0
    while i + 1 < parts.len:
      case parts[i]
      of "icon": result.iconName = parts[i + 1]
      of "meta": result.meta = parts[i + 1]
      of "nonselectable": result.nonselectable = parts[i + 1] == "true"
      else: discard
      i += 2
  result.labelLower = toLower(result.label)
  result.metaLower = toLower(result.meta)

proc secondaryScore(best: int): int =
  ## Rank a substring-or-better hit on secondary text below label matches.
  if best == NoMatch: return NoMatch
  let tier = matchTier(best)
  SecondaryBase + (ord(tier) - ord(mtSubstring)) * SecondaryTierStep +
    (best - TierBase[tier]) div 2

proc buildDmenuActions(rest: string): seq[Action] =
  ## Dmenu mode — filter stdin-provided lines; rows resolve their text via
  ## `dmenuIndex` when accepted.
  let query = rest
  if query.len == 0:
    result = newSeqOfCap[Action](ctx.dmenuItems.len)
    for i, item in ctx.dmenuItems:
      result.add Action(kind: akDmenu, label: item.label, dmenuIndex: i,
          iconName: item.iconName)
  else:
    var top = initHeapQueue[(int, int)]()
    let limit = max(250, ctx.config.maxVisibleItems * 8)
    let queryLower = toLower(query)
    for i, item in ctx.dmenuItems:
      var s = fuzzyScore(queryLower, item.label, item.labelLower)
      if s == NoMatch and item.meta.len > 0:
        s = secondaryScore(fuzzyScore(queryLower, item.meta, item.metaLower,
            mtSubstring))
      if s != NoMatch:
        push(top, (s, i))
        if top.len > limit:
          discard pop(top)
    var ranked: seq[(int, int)] = @[]
    while top.len > 0:
      ranked.add pop(top)
    # Using sort here instead of reverse because of the secondary key (item index)
    ranked.sort(byScoreThenIndex)
    for item in ranked:
      let dItem = ctx.dmenuItems[item[1]]
      result.add Action(kind: akDmenu, label: dItem.label, dmenuIndex: item[1],
          iconName: dItem.iconName, spans: labelSpans(queryLower, dItem.label))

  if result.len == 0:
    result.add Action(kind: akPlaceholder, label: "No matches", exec: "")

proc scoreApp(app: DesktopApp; queryLower: string;
    spans: var seq[(int, int)]): int =
  ## Name matches carry highlight spans. Generic-name and keyword hits (no
  ## spans) only count at substring tier or better and rank in the secondary
  ## band, ordered by their own tier.
  result = fuzzyMatch(queryLower, app.name, app.nameLower, spans)
  if result == NoMatch:
    var best = fuzzyScore(queryLower, app.genericName, app.genericLower,
        mtSubstring)
    for i, keyword in app.keywords:
      let lower = if i < app.keywordsLower.len: app.keywordsLower[i] else: ""
      best = max(best, fuzzyScore(queryLower, keyword, lower, mtSubstring))
    result = secondaryScore(best)

proc buildDefaultActions(rest: string; defaultIndex: var int): seq[Action] =
  ## Default launcher view — MRU when empty, fuzzy search otherwise.
  defaultIndex = 0
  if rest.len == 0:
    ## The table maps identity -> index and is rebuilt per call: this branch
    ## only runs for an empty query, and ctx.allApps may be reassigned.
    var index = initTable[string, int](ctx.allApps.len * 2)
    var nameCounts = initCountTable[string]()
    for i, app in ctx.allApps:
      index[appIdentity(app)] = i
      nameCounts.inc(app.name)

    var seen = initHashSet[int]()
    for recentKey in ctx.recentApps:
      var key = recentKey
      if not index.hasKey(key) and nameCounts[recentKey] == 1:
        for app in ctx.allApps:
          if app.name == recentKey:
            key = appIdentity(app)
            break
      if index.hasKey(key):
        let i = index[key]
        if i notin seen:
          let iconName = if ctx.config.showIcons: pickIcon(ctx.allApps[i]) else: ""
          result.add Action(kind: akApp, label: ctx.allApps[i].name,
              exec: ctx.allApps[i].exec, appIndex: i, iconName: iconName)
          seen.incl i

    ## Compute usage boosts once instead of inside the sort comparator.
    let nowSec = epochTime().int64
    var remaining: seq[(int, int)] = @[]
    for i, app in ctx.allApps:
      if i notin seen:
        remaining.add (usageBoost(appIdentity(app), nowSec), i)
    remaining.sort(proc(a, b: (int, int)): int =
      result = cmp(b[0], a[0])
      if result == 0:
        result = cmpIgnoreCase(ctx.allApps[a[1]].name, ctx.allApps[b[1]].name)
    )
    for (_, i) in remaining:
      let iconName = if ctx.config.showIcons: pickIcon(ctx.allApps[i]) else: ""
      result.add Action(kind: akApp, label: ctx.allApps[i].name,
          exec: ctx.allApps[i].exec, appIndex: i, iconName: iconName)
  else:
    var top = initHeapQueue[(int, int)]()
    let limit = max(DefaultAppSearchCap, ctx.config.maxVisibleItems * 8)
    let queryLower = toLower(rest)
    let nowSec = epochTime().int64
    var spans: seq[(int, int)] = @[]
    for i, app in ctx.allApps:
      let s = scoreApp(app, queryLower, spans)
      if s != NoMatch:
        let key = appIdentity(app)
        push(top, (s + recentBoost(key) + usageBoost(key, nowSec), i))
        if top.len > limit: discard pop(top)
    var ranked: seq[(int, int)] = @[]
    while top.len > 0: ranked.add pop(top)
    ranked.sort(proc(a, b: (int, int)): int =
      result = cmp(b[0], a[0])
      if result == 0: result = cmpIgnoreCase(ctx.allApps[a[1]].name, ctx.allApps[b[1]].name)
    )
    for item in ranked:
      let i = item[1]
      let iconName = if ctx.config.showIcons: pickIcon(ctx.allApps[i]) else: ""
      var rowSpans: seq[(int, int)] = @[]
      discard scoreApp(ctx.allApps[i], queryLower, rowSpans)
      result.add Action(kind: akApp, label: ctx.allApps[i].name,
          exec: ctx.allApps[i].exec, appIndex: i, iconName: iconName,
          spans: rowSpans)
      let appLower = ctx.allApps[i].nameLower
      if ctx.allApps[i].desktopActions.len > 0 and (appLower == queryLower or
          appLower.startsWith(queryLower)):
        addDesktopActionRows(result, i, rowSpans)

  if result.len == 0:
    result.add Action(kind: akPlaceholder, label: "No applications found", exec: "")

proc updateDisplayState(cmd: CmdKind; defaultIndex: int) =
  ## Maintain selection and preview state after the actions changed.
  if ctx.actions.len == 0:
    if cmd == ckTheme:
      endThemePreviewSession(false)
    else:
      ctx.selectedIndex = 0
      ctx.viewOffset = 0
  else:
    let maxIndex = ctx.actions.len - 1
    let clamped = min(defaultIndex, maxIndex)
    ctx.selectedIndex = clamped
    let visible = gui.visibleRowCount()
    if clamped >= visible:
      ctx.viewOffset = clamped - visible + 1
    else:
      ctx.viewOffset = 0

    if cmd == ckTheme:
      if ctx.actions.len > 0 and ctx.actions[ctx.selectedIndex].kind == akTheme:
        updateThemePreview(cmd == ckTheme, ctx.selectedIndex)
      else:
        endThemePreviewSession(false)
    else:
      endThemePreviewSession(false)

# ── Build ctx.actions and display state ────────────────────────────────────────
proc buildActions*() =
  ## Populate actions (with their highlight spans) from the current input.
  if ctx.dmenuMode:
    ctx.actions = buildDmenuActions(ctx.inputText)
    updateDisplayState(ckNone, 0)
    return

  let (cmd, rest, shortcutIdx, groupName) = parseCommand(ctx.inputText)
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
  of ckQuit:
    nextActions = @[Action(kind: akQuit, label: "Quit NimLaunch", exec: "")]
  else:
    discard

  if cmd == ckNone:
    nextActions = buildDefaultActions(rest, defaultIndex)
  elif nextActions.len == 0:
    nextActions.add Action(kind: akPlaceholder, label: "No matches", exec: "")

  ctx.actions = nextActions
  updateDisplayState(cmd, defaultIndex)

# ── Perform selected action ─────────────────────────────────────────────
proc clearInput*() =
  ctx.inputText.setLen(0)
  ctx.lastInputChangeMs = gui.nowMs()
  buildActions()

proc resolveDmenuOutput(a: Action): bool =
  ## Record what dmenu mode prints for `a`. Typed text has no input line, so
  ## it cannot be reported in --index mode and counts as not accepted.
  if a.dmenuIndex in 0..<ctx.dmenuItems.len:
    ctx.dmenuOutput =
      if ctx.dmenuIndexMode: $a.dmenuIndex else: ctx.dmenuItems[a.dmenuIndex].label
  elif ctx.dmenuIndexMode:
    return false
  else:
    ctx.dmenuOutput = a.exec
  ctx.dmenuAccepted = true
  true

proc performAction*(a: Action) =
  if a.kind == akDmenu and a.dmenuIndex in 0..<ctx.dmenuItems.len and
      ctx.dmenuItems[a.dmenuIndex].nonselectable:
    return
  if ctx.dryRunMode:
    if a.kind == akDmenu:
      if resolveDmenuOutput(a):
        ctx.dmenuDryRunAccepted = true
        stdout.write(ctx.dmenuOutput & "\n")
    elif a.kind != akQuit:
      stdout.write(a.exec & "\n")
    ctx.shouldExit = true
    return

  var exitAfter = true ## default: exit after action
  template fail(msg: string) =
    gui.notifyStatus(msg, 1600)
    exitAfter = false
  case a.kind
  of akRun:
    if not runCommand(a.exec):
      fail("Failed: " & a.label)
  of akConfig:
    if not openPathWithFallback(a.exec):
      fail("Failed: " & a.label)
  of akFile:
    if not openPathWithFallback(a.exec):
      fail("Failed to open: " & a.label)
  of akApp, akAppAction:
    var success = false
    if a.appIndex in 0..<ctx.allApps.len:
      let app = ctx.allApps[a.appIndex]
      let name = if a.kind == akApp: app.name else: a.desktopName
      let icon = if a.kind == akApp: app.icon else: a.desktopIcon
      let expansion = parser.expandExecArgs(a.exec, name, icon, app.desktopFile)
      let args = expansion.args
      if expansion.valid and args.len > 0:
        if app.terminal:
          success = spawnInTerminal(args, app.workingDir)
        else:
          success = spawnProcess(args[0], args[1..^1], app.workingDir)
      if success:
        recordAppLaunch(app)
    if not success:
      fail("Failed: " & a.label)
  of akDmenu:
    discard resolveDmenuOutput(a)
  of akShortcut:
    case a.shortcutMode
    of smUrl:
      if not openUrl(a.exec):
        fail("Failed: " & a.label)
    of smShell:
      var success = true
      case a.powerMode
      of pamSpawn:
        success = spawnShellCommand(a.exec)
      of pamTerminal:
        success = runCommand(a.exec)
      if not success:
        fail("Failed: " & a.label)
    of smFile:
      let expanded = a.exec.expandTilde()
      if not fileExists(expanded) and not dirExists(expanded):
        fail("Not found: " & shortenPath(expanded, 50))
      elif not openPathWithFallback(expanded):
        fail("Failed to open: " & shortenPath(expanded, 50))
    if exitAfter and a.stayOpen:
      exitAfter = false
  of akTheme:
    ## Apply and persist, but DO NOT reset selection or exit.
    applyThemeAndColors(ctx.config, a.exec, doNotify = false, doRedraw = false)
    discard saveLastTheme()
    endThemePreviewSession(true)
    clearInput()
    gui.redrawWindow()
    exitAfter = false
  of akQuit:
    discard
  of akPlaceholder:
    exitAfter = false
  if a.kind == akDmenu:
    ctx.shouldExit = true
  elif exitAfter:
    ctx.shouldExit = true

# ── Input/navigation helpers ───────────────────────────────────────────
proc deleteLastInputChar*() =
  if ctx.inputText.len > 0:
    deleteLastUtf8Rune(ctx.inputText)
    ctx.lastInputChangeMs = gui.nowMs()
    buildActions()

proc acceptTypedText*(): bool =
  ## Dmenu mode: return the raw typed input as the selection, like dmenu/rofi.
  if not ctx.dmenuMode or ctx.inputText.len == 0:
    return false
  performAction(Action(kind: akDmenu, label: ctx.inputText, exec: ctx.inputText))
  true

proc activateCurrentSelection*() =
  if ctx.selectedIndex in 0..<ctx.actions.len:
    let current = ctx.actions[ctx.selectedIndex]
    if current.kind == akPlaceholder and acceptTypedText():
      return
    performAction(current)

proc refreshThemePreview() =
  ## Re-apply the preview for the selected row when the input is a theme command.
  updateThemePreview(parseCommand(ctx.inputText)[0] == ckTheme, ctx.selectedIndex)

proc moveSelectionBy*(step: int) =
  if ctx.actions.len == 0: return
  var newIndex = ctx.selectedIndex + step
  if newIndex < 0: newIndex = 0
  if newIndex > ctx.actions.len - 1: newIndex = ctx.actions.len - 1
  if newIndex == ctx.selectedIndex: return
  ctx.selectedIndex = newIndex
  let visibleRows = gui.visibleRowCount()
  if ctx.selectedIndex < ctx.viewOffset:
    ctx.viewOffset = ctx.selectedIndex
  elif ctx.selectedIndex >= ctx.viewOffset + visibleRows:
    ctx.viewOffset = ctx.selectedIndex - visibleRows + 1
    if ctx.viewOffset < 0: ctx.viewOffset = 0
  refreshThemePreview()

proc jumpToTop*() =
  if ctx.actions.len == 0: return
  ctx.selectedIndex = 0
  ctx.viewOffset = 0
  refreshThemePreview()

proc jumpToBottom*() =
  if ctx.actions.len == 0: return
  ctx.selectedIndex = ctx.actions.len - 1
  let start = ctx.actions.len - gui.visibleRowCount()
  ctx.viewOffset = if start > 0: start else: 0
  refreshThemePreview()
