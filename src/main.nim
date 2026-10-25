import std/[os, strutils, syncio]
import sdl3
import ./[state, app_core, gui, utils, settings, search, input, apps_cache]

proc nimbleVersion(): string {.compileTime.} =
  ## Read `version = "x.y.z"` from NimLaunch.nimble at compile time.
  for line in staticRead("../NimLaunch.nimble").splitLines():
    let trimmed = line.strip()
    if trimmed.startsWith("version"):
      return trimmed.split('"')[1]
  "unknown"

const
  Version = nimbleVersion()
  MaxWaitMs = 1000 ## upper bound on a single event wait

# Print the command-line synopsis and available options.
proc printUsage() =
  echo """Usage: nimlaunch [options]

Options:
  -c, --config PATH  Use an alternate configuration file
  -p, --prompt TEXT  Override the prompt in --dmenu mode
      --dmenu         Select an item read from standard input
      --index         With --dmenu, print the 0-based input line index
  -i                  Accepted for dmenu/rofi compatibility (no effect)
      --dry-run       Print the selected raw action without executing it
      --list-themes   Print configured theme names and exit
      --verbose       Print runtime metrics on shutdown
  -v, --version       Print the version and exit
  -h, --help          Show this help text and exit"""

# Parse command-line options into the shared startup context.
proc configureStartupMode() =
  var i = 1
  while i <= paramCount():
    let arg = paramStr(i)
    if arg == "--version" or arg == "-v":
      echo "NimLaunch v", Version
      quit 0
    elif arg == "--help" or arg == "-h":
      printUsage()
      quit 0
    elif arg == "--list-themes":
      ctx.listThemesMode = true
    elif arg == "--dry-run":
      ctx.dryRunMode = true
    elif arg == "--verbose":
      ctx.verboseMode = true
    elif arg == "--dmenu":
      ctx.dmenuMode = true
    elif arg == "--index":
      ctx.dmenuIndexMode = true
    elif arg == "-i":
      discard # matching is already case-insensitive
    elif arg == "--prompt" or arg == "-p":
      if i < paramCount():
        ctx.dmenuPrompt = paramStr(i + 1)
        inc i
      else:
        quit "Error: --prompt requires a text argument."
    elif arg == "--config" or arg == "-c":
      if i < paramCount():
        ctx.configOverridePath = paramStr(i + 1)
        inc i
      else:
        quit "Error: --config requires a path argument."
    else:
      quit "Error: unknown option '" & arg & "'. Use --help for usage."
    inc i

  if ctx.dmenuPrompt.len > 0 and not ctx.dmenuMode:
    quit "Error: --prompt can only be used with --dmenu."
  if ctx.dmenuIndexMode and not ctx.dmenuMode:
    quit "Error: --index can only be used with --dmenu."

# Read non-empty dmenu entries and their Rofi row options.
proc loadDmenuInput() =
  let raw = stdin.readAll()
  ctx.dmenuItems.setLen(0)
  for line in raw.splitLines():
    var item = line
    if item.len > 0 and item[^1] == '\r':
      item.setLen(item.len - 1)
    if item.len > 0:
      ctx.dmenuItems.add parseDmenuLine(item)

## True while an s: query is waiting for its debounce delay to elapse.
proc searchBuildPending(): bool =
  let (cmd, rest, _, _) = parseCommand(ctx.inputText)
  cmd == ckSearch and rest.len >= 2 and lastSearchBuildMs < ctx.lastInputChangeMs

proc processSearchDebounce(): bool =
  ## Debounce wake-up: if we're in s: search, rebuild after idle.
  let now = gui.nowMs()
  if searchBuildPending() and now - ctx.lastInputChangeMs >= SearchDebounceMs:
    lastSearchBuildMs = now
    buildActions()
    return true
  false

## Milliseconds the event loop may sleep before a timed update is due.
proc nextWaitTimeoutMs(): int32 =
  var deadline = gui.nextRedrawDeadlineMs()
  if searchBuildPending():
    deadline = min(deadline, ctx.lastInputChangeMs + SearchDebounceMs)
  int32(clamp(deadline - gui.nowMs(), 1'i64, MaxWaitMs))

proc main*() =
  let startupTimeMs = gui.nowMs()
  configureStartupMode()

  if not ctx.dmenuMode and not ctx.listThemesMode and not ensureSingleInstance():
    # A second launch toggles: close the visible launcher instead of opening another.
    if not closeRunningInstance():
      echo "NimLaunch is already running."
    quit 0
  initLauncherConfig()
  if ctx.dmenuPrompt.len > 0:
    ctx.config.prompt = ctx.dmenuPrompt

  if ctx.listThemesMode:
    for th in ctx.themeList:
      echo th.name
    quit 0
  if ctx.dmenuMode:
    loadDmenuInput()
  else:
    loadApplications()
    loadRecent()
    loadUsage()
  buildActions()

  resetVimState()

  gui.initGui()
  updateParsedColors(ctx.config)
  gui.updateGuiColors()
  gui.redrawWindow()

  var ev: Event
  var focus: FocusState
  focus.startMs = gui.nowMs()
  focus.lastGainMs = focus.startMs

  while not ctx.shouldExit:
    ## Sleep until an event, a worker wake-up, or the next timed deadline.
    var haveEvent = waitEventTimeout(ev, nextWaitTimeoutMs())
    var needsRedraw = false
    while haveEvent and not ctx.shouldExit:
      case ev.`type`
      of EVENT_QUIT:
        ctx.shouldExit = true
      of EVENT_WINDOW_SHOWN, EVENT_WINDOW_HIDDEN, EVENT_WINDOW_EXPOSED,
          EVENT_WINDOW_MOVED, EVENT_WINDOW_RESIZED, EVENT_WINDOW_PIXEL_SIZE_CHANGED,
          EVENT_WINDOW_MINIMIZED, EVENT_WINDOW_FOCUS_GAINED, EVENT_WINDOW_FOCUS_LOST,
          EVENT_WINDOW_DISPLAY_CHANGED, EVENT_WINDOW_DISPLAY_SCALE_CHANGED:
        if handleWindowEvent(ev, focus):
          needsRedraw = true
      of EVENT_KEY_DOWN:
        if handleKeyDown(ev, focus):
          needsRedraw = true
      of EVENT_TEXT_INPUT:
        if handleTextInput(ev, focus):
          needsRedraw = true
      of EVENT_TEXT_EDITING:
        if handleTextEditing(ev):
          needsRedraw = true
      of EVENT_TEXT_EDITING_CANDIDATES:
        if handleTextEditingCandidates(ev):
          needsRedraw = true
      of EVENT_USER:
        needsRedraw = true
      else:
        discard
      haveEvent = pollEvent(ev)

    if ctx.shouldExit: break

    ## Run every check each wake-up so a worker event is never left unpolled.
    if processSearchDebounce():
      needsRedraw = true
    if pollSearchUpdates():
      needsRedraw = true
    if gui.needsTimedRedraw():
      needsRedraw = true
    ## One present per wake-up: vsync makes each redraw block.
    if needsRedraw:
      gui.redrawWindow()

  if ctx.themePreviewActive:
    endThemePreviewSession(false)

  stopSearchWorker()

  if ctx.verboseMode:
    let uptimeMs = gui.nowMs() - startupTimeMs
    stderr.writeLine "NimLaunch shutting down."
    stderr.writeLine "  Uptime: " & $uptimeMs & " ms"
    stderr.writeLine "  Apps parsed: " & $ctx.allApps.len
    stderr.writeLine "  Icons cached: " & $getIconCacheSize()

  gui.shutdownGui()
  if ctx.dmenuMode:
    if ctx.dmenuAccepted:
      if not ctx.dmenuDryRunAccepted:
        stdout.write(ctx.dmenuOutput & "\n")
      quit 0
    quit 1
