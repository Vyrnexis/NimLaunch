## input.nim — key handling, Vim mode, and window event helpers.

import std/strutils
import sdl3
import ./[state, app_core, gui, utils]

proc executeVimCommand*()
proc syncVimCommand*()
proc openVimCommand*(initial: string = "")
proc closeVimCommand*(restoreInput = false; preserveBuffer = false)
proc appendTextInput*(txt: string)

type FocusState* = object
  hadFocus*: bool
  startMs*: int64
  lastGainMs*: int64

proc sanitizePastedText(text: string): string =
  ## Normalize pasted text into a single-line launcher query/command.
  result = newStringOfCap(text.len)
  var lastWasSpace = false
  for ch in text:
    case ch
    of '\0':
      discard
    of '\r', '\n', '\t':
      if not lastWasSpace:
        result.add ' '
        lastWasSpace = true
    else:
      result.add ch
      lastWasSpace = ch == ' '
  result = result.strip()

proc readClipboardText(primaryFallback = true): string =
  proc consume(raw: cstring): string =
    if raw == nil:
      return ""
    result = sanitizePastedText($raw)
    sdlFree(cast[pointer](raw))

  if hasClipboardText():
    result = consume(getClipboardText())
    if result.len > 0:
      return result

  if primaryFallback and hasPrimarySelectionText():
    result = consume(getPrimarySelectionText())

proc pasteInputText*(): bool =
  let pasted = readClipboardText(primaryFallback = true)
  if pasted.len == 0:
    return false
  appendTextInput(pasted)
  true

when gui.WindowDebug:
  proc handleTextEditing*(ev: Event) =
    if not gui.ownsWindowID(ev.edit.windowID):
      return
    let preview = if ev.edit.text == nil: "" else: $ev.edit.text
    echo "[window-debug] text-editing text=\"", preview,
        "\" start=", ev.edit.start,
        " length=", ev.edit.length,
        " vimActive=", ctx.vim.active

  proc handleTextEditingCandidates*(ev: Event) =
    if not gui.ownsWindowID(ev.edit_candidates.windowID):
      return
    var sample: seq[string] = @[]
    let total = max(0, ev.edit_candidates.num_candidates)
    let limit = min(total, 3)
    for i in 0 ..< limit:
      let cand = ev.edit_candidates.candidates[i]
      sample.add(if cand == nil: "" else: $cand)
    echo "[window-debug] text-editing-candidates count=",
        ev.edit_candidates.num_candidates,
        " selected=", ev.edit_candidates.selected_candidate,
        " horizontal=", ev.edit_candidates.horizontal,
        " sample=", sample.join(" | ")

proc shouldExitOnFocusLoss*(fs: FocusState): bool =
  ## Exit only after initial grace period and a small delay after last focus gain.
  let now = gui.nowMs()
  let armed = (now - fs.startMs) > 300
  let postGain = (now - fs.lastGainMs) > 150
  fs.hadFocus and armed and postGain

proc vimCursor(): int =
  ## Command-bar cursor clamped to the buffer.
  ctx.vim.cursor = clamp(ctx.vim.cursor, 0, ctx.vim.buffer.len)
  ctx.vim.cursor

proc vimMoveCursor(pos: int) =
  ## Move the command-bar cursor without re-running the search.
  ctx.vim.cursor = pos
  ctx.inputCursor = ctx.vim.prefix.len + vimCursor()

proc vimBackspace() =
  ## Delete the rune before the cursor; an empty bar closes instead.
  if ctx.vim.buffer.len == 0:
    closeVimCommand(restoreInput = true, preserveBuffer = false)
  elif vimCursor() > 0:
    ctx.vim.cursor = deleteBefore(ctx.vim.buffer, ctx.vim.cursor)
    syncVimCommand()

proc handleVimCommandKey*(sym: Keycode; ctrlHeld: bool): bool =
  ## Handle Vim command-line keys. Return true if the key was consumed.
  if ctrlHeld:
    case sym
    of uint32(ord('h')):
      vimBackspace()
      return true
    of uint32(ord('u')):
      if vimCursor() > 0:
        ctx.vim.buffer.delete(0 ..< ctx.vim.cursor)
        ctx.vim.cursor = 0
        syncVimCommand()
      return true
    of uint32(ord('w')):
      if vimCursor() > 0:
        ctx.vim.cursor = deleteWordBefore(ctx.vim.buffer, ctx.vim.cursor)
        syncVimCommand()
      return true
    of uint32(ord('a')):
      vimMoveCursor(0)
      return true
    of uint32(ord('e')):
      vimMoveCursor(ctx.vim.buffer.len)
      return true
    else:
      discard
  case sym
  of SDLK_RETURN:
    executeVimCommand()
    true
  of SDLK_BACKSPACE:
    vimBackspace()
    true
  of SDLK_DELETE:
    if vimCursor() < ctx.vim.buffer.len:
      deleteAfter(ctx.vim.buffer, ctx.vim.cursor)
      syncVimCommand()
    true
  of SDLK_LEFT:
    vimMoveCursor(prevRunePos(ctx.vim.buffer, vimCursor()))
    true
  of SDLK_RIGHT:
    vimMoveCursor(nextRunePos(ctx.vim.buffer, vimCursor()))
    true
  of SDLK_ESCAPE:
    let restore = ctx.vim.buffer.len == 0
    closeVimCommand(restoreInput = restore, preserveBuffer = true)
    true
  else:
    ## Printable characters are handled by TextInput; do not block.
    false

proc handleVimNormalKey*(sym: Keycode; modState: Keymod): bool =
  ## Handle Vim-mode nav keys when not in command-line. Return true if consumed.
  let shiftHeld = (modState and KMOD_SHIFT) != 0

  case sym
  of uint32(ord('g')):
    if shiftHeld:
      ctx.vim.pendingG = false
      jumpToBottom()
    elif ctx.vim.pendingG:
      ctx.vim.pendingG = false
      jumpToTop()
    else:
      ctx.vim.pendingG = true
    true
  of uint32(ord('j')):
    ctx.vim.pendingG = false
    moveSelectionBy(1)
    true
  of uint32(ord('k')):
    ctx.vim.pendingG = false
    moveSelectionBy(-1)
    true
  of uint32(ord('h')):
    ctx.vim.pendingG = false
    deleteLastInputChar()
    true
  of uint32(ord('l')):
    ctx.vim.pendingG = false
    activateCurrentSelection()
    true
  of SDLK_ESCAPE:
    ctx.shouldExit = true
    true
  else:
    ctx.vim.pendingG = false
    false

proc handleVimKey*(sym: Keycode; modState: Keymod): bool =
  if ctx.vim.active:
    handleVimCommandKey(sym, (modState and KMOD_CTRL) != 0)
  else:
    handleVimNormalKey(sym, modState)

proc resetVimState*() =
  ctx.vim = VimCommandState()

proc syncVimCommand*() =
  ctx.inputText = ctx.vim.prefix & ctx.vim.buffer
  ctx.inputCursor = ctx.vim.prefix.len + vimCursor()
  ctx.lastInputChangeMs = gui.nowMs()
  buildActions()

proc openVimCommand*(initial: string = "") =
  gui.clearTextComposition()
  if not ctx.vim.active:
    ctx.vim.savedInput = ctx.inputText
    ctx.vim.savedSelectedIndex = ctx.selectedIndex
    ctx.vim.savedViewOffset = ctx.viewOffset
    ctx.vim.restorePending = true
  if initial.len > 0 and (initial[0] == ':' or initial[0] == '!'):
    ctx.vim.prefix = initial[0 .. 0]
    if initial.len > 1:
      ctx.vim.buffer = initial[1 .. ^1]
    else:
      ctx.vim.buffer.setLen(0)
  else:
    ctx.vim.prefix = ""
    if initial.len == 0 and ctx.vim.lastSearch.len > 0:
      ctx.vim.buffer = ctx.vim.lastSearch
    else:
      ctx.vim.buffer = initial
  ctx.vim.cursor = ctx.vim.buffer.len
  ctx.vim.active = true
  ctx.vim.pendingG = false
  syncVimCommand()

proc closeVimCommand*(restoreInput = false; preserveBuffer = false) =
  gui.clearTextComposition()
  let savedInput = ctx.vim.savedInput
  let savedSelected = ctx.vim.savedSelectedIndex
  let savedOffset = ctx.vim.savedViewOffset
  let savedBuffer = ctx.vim.prefix & ctx.vim.buffer
  if savedBuffer.len == 0:
    ctx.vim.lastSearch = ""
  elif preserveBuffer and (savedBuffer[0] != ':' and savedBuffer[0] != '!'):
    ctx.vim.lastSearch = savedBuffer
  ctx.vim.buffer.setLen(0)
  ctx.vim.cursor = 0
  ctx.vim.prefix = ""
  ctx.vim.active = false
  ctx.vim.pendingG = false

  if restoreInput and ctx.vim.restorePending:
    ctx.inputText = savedInput
    ctx.inputCursor = savedInput.len
    ctx.lastInputChangeMs = gui.nowMs()
    buildActions()

    if ctx.actions.len > 0:
      let clampedSel = max(0, min(savedSelected, ctx.actions.len - 1))
      let visibleRows = gui.visibleRowCount()
      let maxOffset = max(0, ctx.actions.len - visibleRows)
      var newOffset = max(0, min(savedOffset, maxOffset))
      if clampedSel < newOffset:
        newOffset = clampedSel
      elif clampedSel >= newOffset + visibleRows:
        newOffset = max(0, clampedSel - visibleRows + 1)
      ctx.selectedIndex = clampedSel
      ctx.viewOffset = newOffset
    else:
      ctx.selectedIndex = 0
      ctx.viewOffset = 0

  ctx.vim.savedInput = ""
  ctx.vim.savedSelectedIndex = 0
  ctx.vim.savedViewOffset = 0
  ctx.vim.restorePending = false

proc executeVimCommand*() =
  gui.clearTextComposition()
  let trimmed = (ctx.vim.prefix & ctx.vim.buffer).strip()
  closeVimCommand(preserveBuffer = false)
  if trimmed.len == 0:
    return
  ctx.inputText = trimmed
  ctx.inputCursor = trimmed.len
  ctx.lastInputChangeMs = gui.nowMs()
  buildActions()
  if trimmed.len == 0 or (trimmed[0] != ':' and trimmed[0] != '!'):
    ctx.vim.lastSearch = trimmed
  if ctx.actions.len > 0:
    activateCurrentSelection()

proc appendTextInput*(txt: string) =
  if txt.len == 0: return
  if ctx.config.vimMode and ctx.vim.active:
    ctx.vim.cursor = insertAt(ctx.vim.buffer, vimCursor(), txt)
    syncVimCommand()
  else:
    insertInputText(txt)

proc handleWindowEvent*(ev: Event; focus: var FocusState): bool =
  ## Handle window lifecycle/resize events and report whether a redraw is needed.
  var needsRedraw = false
  case ev.window.`type`
  of EVENT_WINDOW_FOCUS_GAINED:
    focus.hadFocus = true
    focus.lastGainMs = gui.nowMs()
    needsRedraw = true
  of EVENT_WINDOW_SHOWN, EVENT_WINDOW_EXPOSED:
    discard gui.refreshMetrics()
    needsRedraw = true
  of EVENT_WINDOW_RESIZED, EVENT_WINDOW_PIXEL_SIZE_CHANGED,
      EVENT_WINDOW_DISPLAY_CHANGED, EVENT_WINDOW_DISPLAY_SCALE_CHANGED:
    needsRedraw = gui.refreshMetrics() or needsRedraw
  of EVENT_WINDOW_FOCUS_LOST, EVENT_WINDOW_HIDDEN, EVENT_WINDOW_MINIMIZED:
    gui.clearTextComposition()
    if shouldExitOnFocusLoss(focus):
      ctx.shouldExit = true
  else:
    discard

  when gui.WindowDebug:
    let m = gui.windowMetrics()
    let l = gui.layoutMetrics()
    echo "[window-debug] event=", $ev.window.`type`,
        " data=", ev.window.data1, "x", ev.window.data2,
        " win=", m.winW, "x", m.winH,
        " drawable=", m.drawW, "x", m.drawH,
        " layout=", l.logicalW, "x", l.logicalH,
        " display=", l.displayID,
        " displayScale=", l.displayScale,
        " pixelDensity=", l.pixelDensity,
        " contentScale=", l.contentScale,
        " line=", l.lineH,
        " icon=", l.iconSlot,
        " scale=", l.scale,
        " redraw=", needsRedraw

  needsRedraw

proc handleNavigationKey(sym: Keycode; modState: Keymod): bool =
  ## Handle list navigation and activation keys shared by all input modes.
  let shiftHeld = (modState and KMOD_SHIFT) != 0
  let ctrlHeld = (modState and KMOD_CTRL) != 0
  if ctrlHeld and (sym == uint32(ord('n')) or sym == uint32(ord('p'))):
    moveSelectionBy(if sym == uint32(ord('n')): 1 else: -1)
    return true
  case sym
  of SDLK_TAB:
    moveSelectionBy(if shiftHeld: -1 else: 1)
    true
  of SDLK_RETURN:
    activateCurrentSelection()
    true
  of SDLK_UP:
    moveSelectionBy(-1)
    true
  of SDLK_DOWN:
    moveSelectionBy(1)
    true
  of SDLK_PAGEUP:
    if ctx.actions.len > 0:
      moveSelectionBy(-gui.visibleRowCount())
    true
  of SDLK_PAGEDOWN:
    if ctx.actions.len > 0:
      moveSelectionBy(gui.visibleRowCount())
    true
  of SDLK_HOME:
    jumpToTop()
    true
  of SDLK_END:
    jumpToBottom()
    true
  else:
    false

proc handleKeyDown*(ev: Event; focus: var FocusState): bool =
  let sym = ev.key.key
  let modState = ev.key.`mod`
  let ctrlHeld = (modState and KMOD_CTRL) != 0
  let shiftHeld = (modState and KMOD_SHIFT) != 0
  var handled = false
  focus.hadFocus = true
  if ctrlHeld and sym == uint32(ord('v')):
    handled = pasteInputText()
  elif shiftHeld and sym == SDLK_INSERT:
    handled = pasteInputText()
  elif shiftHeld and sym == SDLK_RETURN and
      (openContainingFolder() or acceptTypedText()):
    handled = true
  elif ctx.config.vimMode:
    handled = handleVimKey(sym, modState)
    if not handled:
      handled = handleNavigationKey(sym, modState)
  elif ctrlHeld and sym in [uint32(ord('u')), uint32(ord('h')), uint32(ord('w')),
      uint32(ord('a')), uint32(ord('e'))]:
    case char(sym)
    of 'u': deleteInputToStart()
    of 'h': deleteLastInputChar()
    of 'w': deleteInputWord()
    of 'a': setInputCursor(atEnd = false)
    else: setInputCursor(atEnd = true)
    handled = true
  else:
    case sym
    of SDLK_ESCAPE:
      ctx.shouldExit = true
      handled = true
    of SDLK_BACKSPACE:
      deleteLastInputChar()
      handled = true
    of SDLK_DELETE:
      deleteInputCharAfter()
      handled = true
    of SDLK_LEFT:
      moveInputCursor(-1)
      handled = true
    of SDLK_RIGHT:
      moveInputCursor(1)
      handled = true
    else:
      handled = handleNavigationKey(sym, modState)

  handled

proc handleTextInput*(ev: Event; focus: var FocusState): bool =
  let s = $ev.text.text
  focus.hadFocus = true
  if ctx.config.vimMode and not ctx.vim.active and s.len > 0:
    case s[0]
    of '/':
      ctx.vim.pendingG = false
      openVimCommand("")
      return true
    of ':':
      ctx.vim.pendingG = false
      openVimCommand(":")
      return true
    of '!':
      ctx.vim.pendingG = false
      openVimCommand("!")
      return true
    else:
      ctx.vim.pendingG = false
      return true
  appendTextInput(s)
  true

var wheelRemainder = 0.0 ## fractional scroll left over from smooth wheels

proc handleMouseWheel*(ev: Event): bool =
  ## Scroll the selection one row per wheel notch; touchpad fractions add up.
  if not gui.ownsWindowID(ev.wheel.windowID):
    return false
  var dy = ev.wheel.y.float
  if ev.wheel.direction == MOUSEWHEEL_FLIPPED:
    dy = -dy
  wheelRemainder += dy
  let rows = int(wheelRemainder) # truncates toward zero
  if rows == 0:
    return false
  wheelRemainder -= rows.float
  moveSelectionBy(-rows)
  true

proc handleMouseButton*(ev: Event): bool =
  ## Left click selects a row; clicking the selected row or double-clicking runs it.
  if not gui.ownsWindowID(ev.button.windowID) or ev.button.button != 1:
    return false
  let row = gui.rowAt(ev.button.x, ev.button.y)
  if row < 0:
    return false
  if row == ctx.selectedIndex or ev.button.clicks >= 2:
    selectIndex(row)
    activateCurrentSelection()
  else:
    selectIndex(row)
  true
