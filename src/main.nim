import sdl2
import ./[state, app_core, gui, utils, settings, search, input, apps_cache, theme_session]

proc processSearchDebounce(): bool =
  ## Debounce wake-up: if we're in s: search, rebuild after idle.
  let (cmd, rest, _, _) = parseCommand(inputText)
  if cmd != ckSearch:
    return false
  let now = gui.nowMs()
  let sinceEdit = now - lastInputChangeMs
  if rest.len >= 2 and sinceEdit >= SearchDebounceMs and
     lastSearchBuildMs < lastInputChangeMs:
    lastSearchBuildMs = now
    buildActions()
    return true
  false

proc main() =
  if not ensureSingleInstance():
    echo "NimLaunch is already running."
    quit 0
  initLauncherConfig()
  loadApplications()
  loadRecent()
  buildActions()

  resetVimState()

  gui.initGui()
  updateParsedColors(config)
  gui.updateGuiColors()
  gui.redrawWindow()

  var suppressNextTextInput = false
  var ev = defaultEvent
  var focus: FocusState
  focus.startMs = gui.nowMs()
  focus.lastGainMs = focus.startMs

  while not shouldExit:
    while pollEvent(ev):
      case ev.kind
      of QuitEvent:
        shouldExit = true
      of WindowEvent:
        handleWindowEvent(ev, focus)
      of KeyDown:
        if handleKeyDown(ev, focus, suppressNextTextInput):
          gui.redrawWindow()

      of TextInput:
        if handleTextInput(ev, focus, suppressNextTextInput):
          gui.redrawWindow()
      else:
        discard

    if shouldExit: break

    if processSearchDebounce():
      gui.redrawWindow()
      continue

    delay(10)

  if themePreviewActive:
    endThemePreviewSession(false)

  gui.shutdownGui()

when isMainModule:
  main()
