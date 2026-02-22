import std/[os, strutils]
import sdl2
import ./[state, app_core, gui, utils]

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

proc handleVimCommandKey(sym: cint; ctrlHeld: bool;
    suppressText: var bool): bool =
  ## Handle Vim command-line keys. Return true if the key was consumed.
  case sym
  of K_RETURN:
    executeVimCommand()
    suppressText = true
    true
  of K_BACKSPACE, K_DELETE:
    if vimCommandBuffer.len > 0:
      vimCommandBuffer.setLen(vimCommandBuffer.len - 1)
      inputText = vimCommandBuffer
      buildActions()
    else:
      closeVimCommand(restoreInput = true, preserveBuffer = false)
    suppressText = true
    true
  else:
    if ctrlHeld and sym == K_h:
      if vimCommandBuffer.len > 0:
        vimCommandBuffer.setLen(vimCommandBuffer.len - 1)
        inputText = vimCommandBuffer
        buildActions()
      else:
        closeVimCommand(restoreInput = true, preserveBuffer = false)
      suppressText = true
      return true
    if ctrlHeld and sym == K_u:
      vimCommandBuffer.setLen(0)
      inputText = vimCommandBuffer
      buildActions()
      suppressText = true
      return true
    if sym == K_ESCAPE:
      closeVimCommand(restoreInput = true, preserveBuffer = true)
      suppressText = true
      return true
    ## Printable characters are handled by TextInput; do not block.
    false

proc handleVimNormalKey(sym: cint; text: string; modState: int16;
    suppressText: var bool): bool =
  ## Handle Vim-mode nav/open keys when not in command-line. Return true if consumed.
  let shiftHeld = (modState and ShiftMask) != 0
  case sym
  of K_SLASH:
    openVimCommand("")
    suppressText = true
    true
  of K_COLON:
    openVimCommand(":")
    suppressText = true
    true
  of K_EXCLAIM:
    openVimCommand("!")
    suppressText = true
    true
  of K_g:
    if shiftHeld:
      vimPendingG = false
      jumpToBottom()
    elif vimPendingG:
      vimPendingG = false
      jumpToTop()
    else:
      vimPendingG = true
    suppressText = true
    true
  of K_j:
    vimPendingG = false
    moveSelectionBy(1)
    suppressText = true
    true
  of K_k:
    vimPendingG = false
    moveSelectionBy(-1)
    suppressText = true
    true
  of K_h:
    vimPendingG = false
    deleteLastInputChar()
    suppressText = true
    true
  of K_l:
    vimPendingG = false
    activateCurrentSelection()
    suppressText = true
    true
  of K_ESCAPE:
    shouldExit = true
    suppressText = true
    true
  else:
    if text == ":":
      openVimCommand(":")
      suppressText = true
      return true
    elif text == "!":
      openVimCommand("!")
      suppressText = true
      return true
    elif text == "/":
      openVimCommand("")
      suppressText = true
      return true
    elif text.len > 0:
      vimPendingG = false
      suppressText = true
      return true
    vimPendingG = false
    false

proc handleVimKey(sym: cint; text: string; modState: int16;
    suppressText: var bool) =
  if vimCommandActive:
    discard handleVimCommandKey(sym, (modState and CtrlMask) != 0, suppressText)
  else:
    discard handleVimNormalKey(sym, text, modState, suppressText)

proc appendTextInput(txt: string) =
  if txt.len == 0: return
  if config.vimMode and vimCommandActive:
    vimCommandBuffer.add(txt)
    inputText = vimCommandBuffer
  else:
    inputText.add(txt)
  lastInputChangeMs = gui.nowMs()
  buildActions()

proc main() =
  if not ensureSingleInstance():
    echo "NimLaunch is already running."
    quit 0
  benchMode = "--bench" in commandLineParams()

  timeIt "Init Config:": initLauncherConfig()
  timeIt "Load Applications:": loadApplications()
  timeIt "Load Recent Apps:": loadRecent()
  timeIt "Build Actions:": buildActions()

  vimPendingG = false
  vimCommandBuffer.setLen(0)
  vimCommandActive = false

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
        case ev.window.event
        of WindowEvent_FocusGained:
          focus.hadFocus = true
          focus.lastGainMs = gui.nowMs()
        of WindowEvent_FocusLost, WindowEvent_Hidden, WindowEvent_Minimized:
          if shouldExitOnFocusLoss(focus):
            shouldExit = true
        else:
          discard
      of KeyDown:
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

        if handled:
          gui.redrawWindow()

      of TextInput:
        if suppressNextTextInput:
          suppressNextTextInput = false
          continue
        let s = $cast[cstring](addr ev.text.text[0])
        focus.hadFocus = true
        appendTextInput(s)
        gui.redrawWindow()
      else:
        discard

    if shouldExit: break

    ## Debounce wake-up: if we're in s: search, rebuild after idle
    let (cmd, rest, _) = parseCommand(inputText)
    if cmd == ckSearch:
      let sinceEdit = gui.nowMs() - lastInputChangeMs
      if rest.len >= 2 and sinceEdit >= SearchDebounceMs and
         lastSearchBuildMs < lastInputChangeMs:
        lastSearchBuildMs = gui.nowMs()
        buildActions()
        gui.redrawWindow()
        continue

    delay(10)

  if themePreviewActive:
    endThemePreviewSession(false)

  gui.shutdownGui()

when isMainModule:
  main()
