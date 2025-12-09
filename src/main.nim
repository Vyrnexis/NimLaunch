import std/[os, strutils]
import sdl2
import ./[state, app_core, gui, utils, settings]

const
  CtrlMask = 0x00C0'i16
  ShiftMask = 0x0003'i16

type FocusState = object
  hadFocus: bool
  startMs: int64
  lastGainMs: int64

proc shouldExitOnFocusLoss(fs: FocusState): bool =
  ## Exit only after initial grace period and a small delay after last focus gain.
  let now = gui.nowMs()
  let armed = (now - fs.startMs) > 300
  let postGain = (now - fs.lastGainMs) > 150
  fs.hadFocus and armed and postGain

proc handleVimCommandKey(sym: cint; ctrlHeld: bool; suppressText: var bool): bool =
  ## Handle Vim command-line keys. Return true if the key was consumed.
  case sym
  of K_RETURN:
    executeVimCommand()
    suppressText = true
    true
  of K_BACKSPACE, K_DELETE:
    if vim.buffer.len > 0:
      vim.buffer.setLen(vim.buffer.len - 1)
      syncVimCommand()
    else:
      closeVimCommand(restoreInput = true, preserveBuffer = false)
    suppressText = true
    true
  else:
    if ctrlHeld and sym == K_h:
      if vim.buffer.len > 0:
        vim.buffer.setLen(vim.buffer.len - 1)
        syncVimCommand()
      else:
        closeVimCommand(restoreInput = true, preserveBuffer = false)
      suppressText = true
      return true
    if ctrlHeld and sym == K_u:
      vim.buffer.setLen(0)
      syncVimCommand()
      suppressText = true
      return true
    if sym == K_ESCAPE:
      let restore = vim.buffer.len == 0
      closeVimCommand(restoreInput = restore, preserveBuffer = true)
      suppressText = true
      return true
    ## Printable characters are handled by TextInput; do not block.
    false

proc openVimCommandForTrigger(text: string; shiftHeld: bool; suppressText: var bool): bool =
  ## Open the Vim command bar for '/', ':' or '!'. Return true if consumed.
  if text.len == 0:
    return false
  let trigger = if text[0] == ';' and shiftHeld: ':' else: text[0]
  case trigger
  of '/':
    openVimCommand("")
  of ':':
    openVimCommand(":")
  of '!':
    openVimCommand("!")
  else:
    return false
  suppressText = true
  true

proc handleVimNormalKey(sym: cint; text: string; modState: int16; suppressText: var bool): bool =
  ## Handle Vim-mode nav/open keys when not in command-line. Return true if consumed.
  let shiftHeld = (modState and ShiftMask) != 0
  ## Directly detect slash/colon/bang on keycodes so non-US layouts and numpad divide work.
  case sym
  of K_SLASH, K_KP_DIVIDE:
    vim.pendingG = false
    openVimCommand("")
    suppressText = true
    return true
  of K_SEMICOLON:
    if shiftHeld:
      vim.pendingG = false
      openVimCommand(":")
      suppressText = true
      return true
  of K_EXCLAIM:
    vim.pendingG = false
    openVimCommand("!")
    suppressText = true
    return true
  else:
    discard

  case sym
  of K_g:
    if shiftHeld:
      vim.pendingG = false
      jumpToBottom()
    elif vim.pendingG:
      vim.pendingG = false
      jumpToTop()
    else:
      vim.pendingG = true
    suppressText = true
    true
  of K_j:
    vim.pendingG = false
    moveSelectionBy(1)
    suppressText = true
    true
  of K_k:
    vim.pendingG = false
    moveSelectionBy(-1)
    suppressText = true
    true
  of K_h:
    vim.pendingG = false
    deleteLastInputChar()
    suppressText = true
    true
  of K_l:
    vim.pendingG = false
    activateCurrentSelection()
    suppressText = true
    true
  of K_ESCAPE:
    shouldExit = true
    suppressText = true
    true
  else:
    if openVimCommandForTrigger(text, shiftHeld, suppressText):
      return true
    elif text.len > 0:
      vim.pendingG = false
      suppressText = true
      return true
    vim.pendingG = false
    false

proc handleVimKey(sym: cint; text: string; modState: int16; suppressText: var bool) =
  if vim.active:
    discard handleVimCommandKey(sym, (modState and CtrlMask) != 0, suppressText)
  else:
    discard handleVimNormalKey(sym, text, modState, suppressText)

proc appendTextInput(txt: string) =
  if txt.len == 0: return
  if config.vimMode and vim.active:
    vim.buffer.add(txt)
    syncVimCommand()
  else:
    inputText.add(txt)
  lastInputChangeMs = gui.nowMs()
  buildActions()

proc handleWindowEvent(ev: Event; focus: var FocusState) =
  case ev.window.event
  of WindowEvent_FocusGained:
    focus.hadFocus = true
    focus.lastGainMs = gui.nowMs()
  of WindowEvent_FocusLost, WindowEvent_Hidden, WindowEvent_Minimized:
    if shouldExitOnFocusLoss(focus):
      shouldExit = true
  else:
    discard

proc handleKeyDown(ev: Event; focus: var FocusState; suppressNextTextInput: var bool): bool =
  let sym = ev.key.keysym.sym
  let modState = ev.key.keysym.modstate
  var handled = false
  var text = ""
  let code = sym.int
  if code >= 32 and code <= 126:
    text = $(chr(code))
  focus.hadFocus = true

  if config.vimMode:
    handleVimKey(sym, text, modState, suppressNextTextInput)
    handled = suppressNextTextInput
  elif sym == K_u and ((modState and CtrlMask) != 0):
    clearInput()
    handled = true
  elif sym == K_h and ((modState and CtrlMask) != 0):
    deleteLastInputChar()
    handled = true
  else:
    case sym
    of K_ESCAPE:
      shouldExit = true
      handled = true
    of K_RETURN:
      activateCurrentSelection()
      handled = true
    of K_BACKSPACE:
      deleteLastInputChar()
      handled = true
    of K_LEFT:
      deleteLastInputChar()
      handled = true
    of K_RIGHT:
      discard
    of K_UP:
      moveSelectionBy(-1)
      handled = true
    of K_DOWN:
      moveSelectionBy(1)
      handled = true
    of K_PAGEUP:
      if filteredApps.len > 0:
        moveSelectionBy(-max(1, config.maxVisibleItems))
      handled = true
    of K_PAGEDOWN:
      if filteredApps.len > 0:
        moveSelectionBy(max(1, config.maxVisibleItems))
      handled = true
    of K_HOME:
      jumpToTop()
      handled = true
    of K_END:
      jumpToBottom()
      handled = true
    else:
      discard

  handled

proc handleTextInput(ev: Event; focus: var FocusState; suppressNextTextInput: var bool): bool =
  if suppressNextTextInput:
    suppressNextTextInput = false
    return false
  let s = $cast[cstring](addr ev.text.text[0])
  focus.hadFocus = true
  appendTextInput(s)
  true

proc processSearchDebounce(): bool =
  ## Debounce wake-up: if we're in s: search, rebuild after idle.
  let (cmd, rest, _) = parseCommand(inputText)
  if cmd != ckSearch:
    return false
  let sinceEdit = gui.nowMs() - lastInputChangeMs
  if rest.len >= 2 and sinceEdit >= SearchDebounceMs and
     lastSearchBuildMs < lastInputChangeMs:
    lastSearchBuildMs = gui.nowMs()
    buildActions()
    return true
  false

proc main() =
  if not ensureSingleInstance():
    echo "NimLaunch is already running."
    quit 0
  benchMode = "--bench" in commandLineParams()

  timeIt "Init Config:": initLauncherConfig()
  timeIt "Load Applications:": loadApplications()
  timeIt "Load Recent Apps:": loadRecent()
  timeIt "Build Actions:": buildActions()

  resetVimState()

  gui.initGui()
  timeIt "updateParsedColors:": updateParsedColors(config)
  timeIt "updateGuiColors:": gui.updateGuiColors()
  timeIt "Benchmark(Redraw Frame):": gui.redrawWindow()

  if benchMode: quit 0

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
