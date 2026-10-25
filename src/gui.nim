## gui.nim — SDL3/TTF renderer for NimLaunch
## Provides a thin API mirroring the original GUI (updateGuiColors, redrawWindow, etc.).

import std/[strutils, times, tables, streams, osproc, math, monotimes, os]
import sdl3
import sdl3_ttf
import ./[state, sdl3_image, icon_resolver, layout, paths]

const
  TTF_STYLE_BOLD = 0x01'u32

when not declared(setFontStyle):
  proc setFontStyle(font: Font; style: uint32) {.cdecl,
      importc: "TTF_SetFontStyle", dynlib: TtfLibName.}

type
  IconTextureObj = object
    tex: Texture
    w, h: int
  IconTexture = ref IconTextureObj

proc `=destroy`(x: var IconTextureObj) =
  if x.tex != nil:
    destroyTexture(x.tex)
    x.tex = nil

type
  UiMetrics = object
    scale: float32
    displayID: DisplayID
    displayScale: float32
    pixelDensity: float32
    contentScale: float32
    logicalWinW, logicalWinH: int
    drawW, drawH: int
    lineHeightPx: int
    fontLineHeightPx: int
    overlayLineHeightPx: int
    contentTopPx: int
    contentBottomPx: int
    visibleRows: int
    borderWidthPx: int
    outerMarginPx: int
    rowGapPx: int
    rowTextInsetPx: int
    iconInsetPx: int
    iconTextGapPx: int
    iconSlotPx: int
    overlayMarginPx: int
    commandBarExtraHeightPx: int
    commandBarBottomGapPx: int
    overlayStackGapPx: int

  BackendStateObj = object
    window: Window
    renderer: Renderer
    font: Font
    fontBold: Font
    fontOverlay: Font
    fontPath: string
    baseFontSize: int
    metrics: UiMetrics
    iconCache: Table[string, IconTexture]
    textCache: Table[string, tuple[tex: Texture, w, h: int]]
    textCacheQueue: seq[string]
    windowShown: bool
    windowRaised: bool
  BackendState = ref BackendStateObj

proc `=destroy`(x: var BackendStateObj) =
  for _, entry in x.textCache:
    if entry.tex != nil: destroyTexture(entry.tex)
  x.textCache.clear()
  x.iconCache.clear() # Triggers IconTextureObj destructors automatically
  if x.font != nil: closeFont(x.font)
  if x.fontBold != nil: closeFont(x.fontBold)
  if x.fontOverlay != nil: closeFont(x.fontOverlay)
  if x.renderer != nil: destroyRenderer(x.renderer)
  if x.window != nil: destroyWindow(x.window)
  x.window = nil
  x.renderer = nil

var st: BackendState

type
  IconRequest = object
    cacheKey: string
    iconName: string
    size: int

  IconResponse = object
    cacheKey: string
    surface: ptr Surface

var
  iconReqChan: Channel[IconRequest]
  iconResChan: Channel[IconResponse]
  iconThread: Thread[void]
  iconThreadStarted: bool
  iconPendingSet: Table[string, bool]
  widthCache: Table[string, int] ## text & font -> width; cleared with fonts

proc iconWorker() {.thread.} =
  while true:
    let req = iconReqChan.recv()
    if req.cacheKey == "SHUTDOWN":
      break
    let path = resolveIconPath(req.iconName, req.size)
    var surf: ptr Surface = nil
    if path.len > 0:
      surf = loadIconSurface(path, req.size)
    iconResChan.send(IconResponse(cacheKey: req.cacheKey, surface: surf))
    var evt = Event(`type`: EVENT_USER)
    discard pushEvent(evt)

proc getIconCacheSize*(): int =
  if st != nil: st.iconCache.len else: 0

const
  WindowDebug* = defined(nimlaunchWindowDebug)

# Colours cached from Config
var
  colBg: Color
  colFg: Color
  colHighlightBg: Color
  colHighlightFg: Color
  colMatch: Color
  colBorder: Color

const
  DefaultFontPath = "/usr/share/fonts/TTF/DejaVuSans.ttf"
  DefaultFallbackIcon = "application-x-executable"
  BaseOuterMargin = 10
  BasePromptInset = 12
  BaseRowGap = 6
  BaseRowTextInset = 2
  BaseIconInset = 4
  BaseIconTextGap = 8
  BaseOverlayMargin = 8
  BaseCommandBarExtraHeight = 6
  BaseCommandBarBottomGap = 4
  BaseOverlayStackGap = 4
  BaseClockRightMargin = 10
  BaseIconMinSize = 16
  BaseIconMaxSize = 32
  BaseIconSizeInset = 2
  ThemeFadeMs = 500 ## duration of the theme-name overlay fade
  FadeFrameMs = 16  ## redraw interval while the fade is animating
  ClockOffWaitMs = 3_600_000 ## idle wait when the clock is hidden

var
  lastThemeSwitchMs*: int64 = 0
  currentThemeName: string = ""
  statusText*: string = ""
  statusUntilMs*: int64 = 0
  lastClockMinute = -1 ## hour * 60 + minute of the last drawn clock


# -------------------
# Helpers
# -------------------
proc rgbToColor(c: Rgb; a: uint8 = 255'u8): Color =
  result.r = c.r
  result.g = c.g
  result.b = c.b
  result.a = a

proc roundScaled(base: int; scale: float32; minValue = 0): int =
  result = int(round(base.float * scale.float))
  if result < minValue:
    result = minValue

proc deriveFontSizeFromConfig(): int

proc layoutInputFor(scale: float32; canvasHeight, fontLineHeight,
    overlayLineHeight: int): LayoutInput =
  ## Build the layout request for `scale` (1.0 for unscaled base units).
  LayoutInput(
    canvasHeight: canvasHeight,
    requestedRows: ctx.config.maxVisibleItems,
    configuredLineHeight: roundScaled(ctx.config.lineHeight, scale, minValue = 1),
    fontLineHeight: fontLineHeight,
    overlayLineHeight: overlayLineHeight,
    iconMinimum: roundScaled(BaseIconMinSize, scale, minValue = 1) +
        roundScaled(BaseIconSizeInset, scale),
    textPadding: roundScaled(4, scale),
    outerMargin: roundScaled(BaseOuterMargin, scale),
    rowGap: roundScaled(BaseRowGap, scale),
    commandExtraHeight: roundScaled(BaseCommandBarExtraHeight, scale),
    commandBottomGap: roundScaled(BaseCommandBarBottomGap, scale),
    vimMode: ctx.config.vimMode,
    showIcons: ctx.config.showIcons)

proc logicalWindowHeight(): int =
  ## Estimate the initial native height before SDL can report display metrics.
  let fontSize = deriveFontSizeFromConfig()
  let input = layoutInputFor(1.0'f32, 1, fontSize + 4, max(6, fontSize - 2) + 4)
  min(4096, computeLayout(input).desiredHeight)

proc currentVideoDriverName(): string =
  let raw = getCurrentVideoDriver()
  if raw == nil:
    return ""
  $raw

proc isX11Backend(): bool =
  cmpIgnoreCase(currentVideoDriverName(), "x11") == 0

proc ownsWindowID*(windowID: WindowID): bool =
  not st.isNil and not st.window.isNil and windowID == getWindowID(st.window)

proc deriveFontSizeFromConfig(): int =
  ## Parse ctx.config.fontName looking for ":size=N" or "size=N".
  const key = "size="
  let lower = ctx.config.fontName.toLowerAscii
  let idx = lower.find(key)
  if idx >= 0:
    var j = idx + key.len
    var n = 0
    while j < lower.len and lower[j].isDigit:
      if n <= 256:
        n = n * 10 + (ord(lower[j]) - ord('0'))
      inc j
    if n > 0:
      return clamp(n, 6, 256)
  12

proc loadFont(path: string; size: int; makeBold = false): Font =
  let f = openFont(path.cstring, size.cfloat)
  if f.isNil:
    quit "[ERROR] Failed to load font: " & path & " (" & $getError() & ")"
  if makeBold:
    setFontStyle(f, TTF_STYLE_BOLD)
  f

proc resolveFontPath(name: string): string =
  ## Resolve a fontconfig name to a file path via fc-match; fall back to defaults.
  ## The result is cached (name and path) so later launches skip fc-match.
  if name.len == 0:
    return DefaultFontPath
  if name.contains('/'):
    return name
  let cacheFile = cacheDir() / "font"
  try:
    let lines = readFile(cacheFile).splitLines()
    if lines.len >= 2 and lines[0] == name and lines[1].len > 0 and
        fileExists(lines[1]):
      return lines[1]
  except CatchableError:
    discard
  try:
    let p = startProcess(
      "fc-match",
      args = @["-f", "%{file}\n", name],
      options = {poUsePath, poStdErrToStdOut}
    )
    defer: close(p)
    let output = p.outputStream.readAll().strip()
    if output.len > 0:
      try:
        createDir(cacheDir())
        writeFile(cacheFile, name & "\n" & output & "\n")
      except CatchableError:
        discard
      return output
  except CatchableError:
    discard
  DefaultFontPath

proc displayBounds(displayIndex: int; bounds: var Rect): bool =
  ## Fetch the bounds of the display at `displayIndex` (clamped to the available range).
  var count: cint
  let displays = getDisplays(count)
  defer:
    if displays != nil:
      sdlFree(displays)
  if displays == nil or count <= 0:
    return false
  getDisplayBounds(displays[clamp(displayIndex, 0, count.int - 1)], bounds)

proc computeAlignedWindowX(winWidth: int; displayIndex: int): cint =
  ## Compute window X for centerWindow using display bounds.
  var bounds: Rect
  if not displayBounds(displayIndex, bounds) or bounds.w <= 0:
    return WINDOWPOS_CENTERED.cint

  let displayLeft = bounds.x.int
  let displayW = bounds.w.int
  var x = displayLeft + (displayW - winWidth) div 2
  let maxX = displayLeft + displayW - winWidth
  if maxX >= displayLeft:
    x = max(displayLeft, min(x, maxX))
  x.cint

proc computeAlignedWindowY(winHeight: int; displayIndex: int): cint =
  ## Compute window Y for centerWindow + verticalAlign using display bounds.
  var bounds: Rect
  if not displayBounds(displayIndex, bounds) or bounds.h <= 0:
    return WINDOWPOS_CENTERED.cint

  let displayTop = bounds.y.int
  let displayH = bounds.h.int
  let align = ctx.config.verticalAlign.toLowerAscii
  var centerY: int
  case align
  of "top":
    centerY = displayTop + winHeight div 2
  of "center":
    centerY = displayTop + displayH div 2
  else:
    centerY = displayTop + displayH div 3

  var y = centerY - winHeight div 2
  let maxY = displayTop + displayH - winHeight
  if maxY >= displayTop:
    y = max(displayTop, min(y, maxY))
  y.cint

proc ensureSdl() =
  if sdl3.wasInit(INIT_VIDEO) == InitFlags(0):
    if not sdl3.init(INIT_VIDEO):
      quit "[ERROR] SDL init failed: " & $getError()
  if not sdl3_ttf.init():
    quit "[ERROR] TTF init failed: " & $getError()

proc configureTextInput() =
  if st.isNil or st.window.isNil:
    return
  let props = createProperties()
  defer:
    if props != 0:
      destroyProperties(props)
  discard setNumberProperty(props, PROP_TEXTINPUT_TYPE_NUMBER,
      ord(TEXTINPUT_TYPE_TEXT).int64)
  discard setNumberProperty(props, PROP_TEXTINPUT_CAPITALIZATION_NUMBER,
      ord(CAPITALIZE_NONE).int64)
  discard setBooleanProperty(props, PROP_TEXTINPUT_AUTOCORRECT_BOOLEAN, false)
  discard setBooleanProperty(props, PROP_TEXTINPUT_MULTILINE_BOOLEAN, false)
  if not startTextInputWithProperties(st.window, props):
    discard startTextInput(st.window)

proc destroyState() =
  if st.isNil: return
  discard stopTextInput(st.window)
  st = nil
  sdl3_ttf.quit()
  sdl3.quit()

proc nowMs*(): int64 =
  ## Monotonic milliseconds; only meaningful for intervals.
  getMonoTime().ticks div 1_000_000

proc scaledBaseMetrics(scale: float32): UiMetrics =
  ## Metrics holding only the scale and the scaled base-unit sizes.
  result.scale = scale
  result.borderWidthPx = roundScaled(ctx.config.borderWidth, scale)
  result.outerMarginPx = roundScaled(BaseOuterMargin, scale)
  result.rowGapPx = roundScaled(BaseRowGap, scale)
  result.rowTextInsetPx = roundScaled(BaseRowTextInset, scale)
  result.iconInsetPx = roundScaled(BaseIconInset, scale)
  result.iconTextGapPx = roundScaled(BaseIconTextGap, scale)
  result.overlayMarginPx = roundScaled(BaseOverlayMargin, scale)
  result.commandBarExtraHeightPx = roundScaled(BaseCommandBarExtraHeight, scale)
  result.commandBarBottomGapPx = roundScaled(BaseCommandBarBottomGap, scale)
  result.overlayStackGapPx = roundScaled(BaseOverlayStackGap, scale)

proc applyLayout(m: var UiMetrics) =
  ## Fill the row/content/icon metrics from the scale, draw size and font heights.
  let computed = computeLayout(layoutInputFor(m.scale, m.drawH,
      m.fontLineHeightPx, m.overlayLineHeightPx))
  m.lineHeightPx = computed.rowHeight
  m.contentTopPx = computed.contentTop
  m.contentBottomPx = computed.contentBottom
  m.visibleRows = computed.visibleRows
  let iconInset = roundScaled(BaseIconSizeInset, m.scale)
  let iconMin = roundScaled(BaseIconMinSize, m.scale, minValue = 1)
  let iconMax = roundScaled(BaseIconMaxSize, m.scale, minValue = 1)
  m.iconSlotPx = max(iconMin, min(m.lineHeightPx - iconInset, iconMax))

proc computeUiMetrics(window: Window; renderer: Renderer): UiMetrics =
  var drawW, drawH: cint
  var winW, winH: cint
  discard getWindowSize(window, winW, winH)
  if renderer.isNil or not getWindowSizeInPixels(window, drawW, drawH):
    drawW = winW
    drawH = winH

  let logicalW = max(1, winW.int)
  let logicalH = max(1, winH.int)
  let drawWi = max(1, drawW.int)
  let drawHi = max(1, drawH.int)

  let displayID = getDisplayForWindow(window)
  let displayScale = getWindowDisplayScale(window)
  let pixelDensity = getWindowPixelDensity(window)
  var contentScale = 0.0'f32
  if displayID != 0'u32:
    contentScale = getDisplayContentScale(displayID)

  var scale = displayScale
  if scale <= 0:
    scale = contentScale
  if scale <= 0:
    scale = pixelDensity
  if scale <= 0:
    scale = max(drawWi.float32 / logicalW.float32, drawHi.float32 / logicalH.float32)
  if scale < 1.0'f32:
    scale = 1.0'f32

  result = scaledBaseMetrics(scale)
  result.displayID = displayID
  result.displayScale = displayScale
  result.pixelDensity = pixelDensity
  result.contentScale = contentScale
  result.logicalWinW = logicalW
  result.logicalWinH = logicalH
  result.drawW = drawWi
  result.drawH = drawHi
  result.fontLineHeightPx =
    if not st.isNil and not st.font.isNil: max(1, getFontLineSkip(st.font).int)
    else: roundScaled(max(1, deriveFontSizeFromConfig() + 4), scale, minValue = 1)
  result.overlayLineHeightPx =
    if not st.isNil and not st.fontOverlay.isNil:
      max(1, getFontLineSkip(st.fontOverlay).int)
    else:
      roundScaled(max(1, deriveFontSizeFromConfig() + 2), scale, minValue = 1)
  applyLayout(result)

## Resize the native window so its drawable fits the requested rows and font.
proc fitWindowToContent(metrics: UiMetrics): bool =
  if st.isNil or st.window.isNil:
    return false
  let input = layoutInputFor(metrics.scale, metrics.drawH,
      metrics.fontLineHeightPx, metrics.overlayLineHeightPx)
  let desiredCanvasH = computeLayout(input).desiredHeight
  let density =
    if metrics.pixelDensity > 0: metrics.pixelDensity
    elif metrics.logicalWinW > 0:
      metrics.drawW.float32 / metrics.logicalWinW.float32
    else: 1.0'f32
  var desiredW = int(ceil((ctx.config.winWidth.float32 * metrics.scale / density).float))
  var desiredH = int(ceil((desiredCanvasH.float32 / density).float))
  var usable: Rect
  if metrics.displayID != 0'u32 and getDisplayUsableBounds(metrics.displayID, usable):
    desiredW = min(desiredW, max(1, usable.w.int))
    desiredH = min(desiredH, max(1, usable.h.int))
  desiredW = max(1, desiredW)
  desiredH = max(1, desiredH)
  if desiredW == metrics.logicalWinW and desiredH == metrics.logicalWinH:
    return false
  if not setWindowSize(st.window, desiredW.cint, desiredH.cint):
    return false
  if ctx.config.centerWindow:
    discard setWindowPosition(st.window,
        computeAlignedWindowX(desiredW, ctx.config.displayIndex),
        computeAlignedWindowY(desiredH, ctx.config.displayIndex))
  true

proc destroyIconTextures() =
  if st.isNil: return
  st.iconCache.clear()

proc rebuildFonts() =
  if st.isNil:
    return
  if not st.font.isNil: closeFont(st.font)
  if not st.fontBold.isNil: closeFont(st.fontBold)
  if not st.fontOverlay.isNil: closeFont(st.fontOverlay)
  let fontSize = max(6, roundScaled(st.baseFontSize, st.metrics.scale, minValue = 6))
  let overlaySize = max(fontSize - roundScaled(2, st.metrics.scale), 6)
  st.font = loadFont(st.fontPath, fontSize)
  st.fontBold = loadFont(st.fontPath, fontSize, makeBold = true)
  st.fontOverlay = loadFont(st.fontPath, overlaySize)

proc updateTextInputArea*() =
  if st.isNil or st.window.isNil:
    return
  let m = st.metrics
  var renderX, renderY, renderW, renderH: int
  let leftInset = roundScaled(BasePromptInset, m.scale)
  if ctx.config.vimMode and ctx.vim.active:
    let barHeight = m.lineHeightPx + m.commandBarExtraHeightPx
    renderY = max(0, m.drawH - barHeight - m.commandBarBottomGapPx)
    renderX = leftInset
    renderW = max(1, m.drawW - leftInset * 2)
    renderH = max(1, barHeight)
  else:
    renderX = leftInset
    renderY = m.outerMarginPx
    renderW = max(1, m.drawW - leftInset * 2)
    renderH = max(1, m.lineHeightPx + m.rowGapPx)
  var x1, y1, x2, y2: cfloat
  if not renderCoordinatesToWindow(st.renderer, renderX.cfloat, renderY.cfloat,
      x1, y1) or not renderCoordinatesToWindow(st.renderer,
      (renderX + renderW).cfloat, (renderY + renderH).cfloat, x2, y2):
    let density = max(0.1'f32, m.pixelDensity)
    x1 = renderX.cfloat / density
    y1 = renderY.cfloat / density
    x2 = (renderX + renderW).cfloat / density
    y2 = (renderY + renderH).cfloat / density
  var rect = Rect(
    x: int(round(x1.float)).cint,
    y: int(round(y1.float)).cint,
    w: max(1, int(round((x2 - x1).float))).cint,
    h: max(1, int(round((y2 - y1).float))).cint)
  discard setTextInputArea(st.window, rect.addr, rect.x + rect.w)

proc clearTextComposition*() =
  if st.isNil or st.window.isNil:
    return
  if textInputActive(st.window):
    discard clearComposition(st.window)

proc refreshMetrics*(force = false): bool =
  if st.isNil or st.window.isNil:
    return false
  let prev = st.metrics
  var next = computeUiMetrics(st.window, st.renderer)
  let fontScaleChanged = force or abs(next.scale - prev.scale) > 0.01'f32
  let displayChanged = force or next.displayID != prev.displayID
  st.metrics = next
  # Rebuild scale-sensitive resources only when their effective pixel size changes.
  if fontScaleChanged:
    rebuildFonts()
    next = computeUiMetrics(st.window, st.renderer)
  if force or fontScaleChanged or displayChanged:
    if fitWindowToContent(next):
      next = computeUiMetrics(st.window, st.renderer)
  st.metrics = next
  let iconSizeChanged = force or next.iconSlotPx != prev.iconSlotPx
  let metricsChanged = force or next.logicalWinW != prev.logicalWinW or
      next.logicalWinH != prev.logicalWinH or next.drawW != prev.drawW or
      next.drawH != prev.drawH or next.lineHeightPx != prev.lineHeightPx or
      next.borderWidthPx != prev.borderWidthPx or
      next.visibleRows != prev.visibleRows
  if iconSizeChanged:
    destroyIconTextures()
  if fontScaleChanged or metricsChanged or displayChanged:
    widthCache.clear()
    for _, entry in st.textCache:
      if entry.tex != nil: destroyTexture(entry.tex)
    st.textCache.clear()
    st.textCacheQueue.setLen(0)
  updateTextInputArea()

  when WindowDebug:
    if force or displayChanged or fontScaleChanged or metricsChanged or iconSizeChanged:
      echo "[window-debug] metrics display=", prev.displayID, "->", next.displayID,
          " displayScale=", prev.displayScale, "->", next.displayScale,
          " pixelDensity=", prev.pixelDensity, "->", next.pixelDensity,
          " contentScale=", prev.contentScale, "->", next.contentScale,
          " logical=", prev.logicalWinW, "x", prev.logicalWinH, "->",
          next.logicalWinW, "x", next.logicalWinH,
          " drawable=", prev.drawW, "x", prev.drawH, "->",
          next.drawW, "x", next.drawH,
          " uiScale=", prev.scale, "->", next.scale,
          " line=", prev.lineHeightPx, "->", next.lineHeightPx,
          " icon=", prev.iconSlotPx, "->", next.iconSlotPx

  metricsChanged or fontScaleChanged or iconSizeChanged or displayChanged

proc currentMetrics(): UiMetrics =
  if st.isNil:
    result = scaledBaseMetrics(1.0'f32)
    result.logicalWinW = ctx.config.winWidth
    result.logicalWinH = logicalWindowHeight()
    result.drawW = result.logicalWinW
    result.drawH = result.logicalWinH
    result.fontLineHeightPx = deriveFontSizeFromConfig() + 4
    result.overlayLineHeightPx = max(6, deriveFontSizeFromConfig() - 2) + 4
    applyLayout(result)
  else:
    result = st.metrics

## Map window coordinates (from mouse events) to an action index, or -1.
proc rowAt*(x, y: float): int =
  let m = currentMetrics()
  let px = x * m.drawW.float / max(1, m.logicalWinW).float
  let py = y * m.drawH.float / max(1, m.logicalWinH).float
  if px < 0 or px >= m.drawW.float or py < m.contentTopPx.float:
    return -1
  let slot = int((py - m.contentTopPx.float) / m.lineHeightPx.float)
  let idx = ctx.viewOffset + slot
  if slot >= m.visibleRows or idx >= ctx.actions.len: -1 else: idx

## Return the number of fully visible rows in the current layout.
proc visibleRowCount*(): int =
  max(1, currentMetrics().visibleRows)

proc notifyThemeChanged*(name: string) =
  currentThemeName = name
  lastThemeSwitchMs = nowMs()
  if not st.isNil:
    for _, entry in st.textCache:
      if entry.tex != nil: destroyTexture(entry.tex)
    st.textCache.clear()
    st.textCacheQueue.setLen(0)

proc notifyStatus*(text: string; durationMs = 800) =
  statusText = text
  statusUntilMs = nowMs() + durationMs

## Return the clock minute of day used to detect overlay changes.
proc minuteOfDay(t: times.DateTime): int =
  t.hour * 60 + t.minute

## Advance visual deadlines for fades, status expiry, and minute changes.
proc needsTimedRedraw*(): bool =
  let currentMs = nowMs()
  if currentThemeName.len > 0:
    if currentMs - lastThemeSwitchMs <= ThemeFadeMs:
      return true
    currentThemeName.setLen(0)
    return true
  if statusText.len > 0 and currentMs > statusUntilMs:
    statusText.setLen(0)
    return true
  ctx.config.showClock and minuteOfDay(now()) != lastClockMinute

## Return the nowMs() time of the next fade frame, status expiry, or clock
## minute change. A time at or before now() means a redraw is already due.
proc nextRedrawDeadlineMs*(): int64 =
  let currentMs = nowMs()
  if currentThemeName.len > 0:
    return currentMs + FadeFrameMs
  if statusText.len > 0:
    return statusUntilMs + 1
  if not ctx.config.showClock:
    return currentMs + ClockOffWaitMs
  let t = now()
  if minuteOfDay(t) != lastClockMinute:
    return currentMs
  currentMs + (60 - t.second) * 1000 - t.nanosecond div 1_000_000

# -------------------
# Init / Shutdown
# -------------------
proc initGui*() =
  ensureSdl()

  let fontPath = resolveFontPath(ctx.config.fontName)

  ## Keep the X11-specific taskbar hint scoped to X11 so Wayland compositors
  ## only see the SDL3 window-role properties below.
  if isX11Backend():
    discard setHint("SDL_VIDEO_X11_NET_WM_WINDOW_TYPE",
        "_NET_WM_WINDOW_TYPE_DOCK,_NET_WM_WINDOW_TYPE_UTILITY")

  let props = createProperties()
  defer:
    if props != 0:
      destroyProperties(props)
  discard setStringProperty(props, PROP_WINDOW_CREATE_TITLE_STRING, "NimLaunch")
  discard setNumberProperty(props, PROP_WINDOW_CREATE_X_NUMBER,
      if ctx.config.centerWindow: computeAlignedWindowX(ctx.config.winWidth, ctx.config.displayIndex).int64
      else: ctx.config.positionX.int64)
  discard setNumberProperty(props, PROP_WINDOW_CREATE_Y_NUMBER,
      if ctx.config.centerWindow: computeAlignedWindowY(logicalWindowHeight(),
          ctx.config.displayIndex).int64 else: ctx.config.positionY.int64)
  discard setNumberProperty(props, PROP_WINDOW_CREATE_WIDTH_NUMBER, ctx.config.winWidth.int64)
  discard setNumberProperty(props, PROP_WINDOW_CREATE_HEIGHT_NUMBER, logicalWindowHeight().int64)
  discard setBooleanProperty(props, PROP_WINDOW_CREATE_HIDDEN_BOOLEAN, true)
  discard setBooleanProperty(props, PROP_WINDOW_CREATE_BORDERLESS_BOOLEAN, true)
  discard setBooleanProperty(props, PROP_WINDOW_CREATE_FOCUSABLE_BOOLEAN, true)
  discard setBooleanProperty(props, PROP_WINDOW_CREATE_UTILITY_BOOLEAN, true)
  discard setBooleanProperty(props, PROP_WINDOW_CREATE_HIGH_PIXEL_DENSITY_BOOLEAN, true)

  st = BackendState(
    fontPath: fontPath,
    baseFontSize: deriveFontSizeFromConfig(),
    window: createWindowWithProperties(props)
  )
  if st.window.isNil:
    quit "[ERROR] createWindow: " & $getError()

  let rendererProps = createProperties()
  defer:
    if rendererProps != 0:
      destroyProperties(rendererProps)
  discard setPointerProperty(rendererProps, PROP_RENDERER_CREATE_WINDOW_POINTER,
      cast[pointer](st.window))
  discard setNumberProperty(rendererProps, PROP_RENDERER_CREATE_PRESENT_VSYNC_NUMBER, 1)
  st.renderer = createRendererWithProperties(rendererProps)
  if st.renderer.isNil:
    quit "[ERROR] createRenderer: " & $getError()

  st.iconCache = initTable[string, IconTexture]()
  discard refreshMetrics(force = true)

  when declared(setWindowOpacity):
    let opac = if ctx.config.opacity < 0.1: 0.1 elif ctx.config.opacity >
        1.0: 1.0 else: ctx.config.opacity
    discard setWindowOpacity(st.window, opac.cfloat)

  configureTextInput()

  iconReqChan.open()
  iconResChan.open()
  iconThreadStarted = true
  iconPendingSet = initTable[string, bool]()
  createThread(iconThread, iconWorker)

proc shutdownGui*() =
  if iconThreadStarted:
    ## Drop queued requests so the worker only finishes the one in flight.
    while iconReqChan.tryRecv().dataAvailable:
      discard
    iconReqChan.send(IconRequest(cacheKey: "SHUTDOWN"))
    joinThread(iconThread)
    iconThreadStarted = false
    while true:
      let (avail, res) = iconResChan.tryRecv()
      if not avail: break
      if res.surface != nil: destroySurface(res.surface)
    iconReqChan.close()
    iconResChan.close()
  destroyState()

proc updateGuiColors*() =
  colBg = rgbToColor(ctx.config.bgColor)
  colFg = rgbToColor(ctx.config.fgColor)
  colHighlightBg = rgbToColor(ctx.config.highlightBgColor)
  colHighlightFg = rgbToColor(ctx.config.highlightFgColor)
  colMatch = rgbToColor(ctx.config.matchFgColor)
  colBorder = rgbToColor(ctx.config.borderColor)

# -------------------
# Text rendering helpers
# -------------------
proc toFRect(x, y, w, h: int): FRect =
  result.x = x.cfloat
  result.y = y.cfloat
  result.w = w.cfloat
  result.h = h.cfloat

proc renderText(font: Font; text: string; color: Color): Texture =
  if text.len == 0 or font.isNil: return nil
  let key = text & "|" & $cast[uint](font) & "|" & $color.r & "," & $color.g & "," & $color.b & "," & $color.a
  if st.textCache.hasKey(key):
    return st.textCache[key].tex

  let surf = renderTextBlended(font, text.cstring, text.len.csize_t, color)
  if surf.isNil: return nil
  let tex = createTextureFromSurface(st.renderer, surf)
  if tex.isNil:
    destroySurface(surf)
    return nil
  let w = int(surf.w)
  let h = int(surf.h)
  destroySurface(surf)

  if st.textCacheQueue.len >= 256:
    let oldKey = st.textCacheQueue[0]
    st.textCacheQueue.delete(0)
    if st.textCache.hasKey(oldKey):
      destroyTexture(st.textCache[oldKey].tex)
      st.textCache.del(oldKey)

  st.textCache[key] = (tex, w, h)
  st.textCacheQueue.add(key)
  tex

proc measureText(font: Font; text: string): (int, int) =
  var w, h: cint
  discard getStringSize(font, text.cstring, text.len.csize_t, w, h)
  (w.int, h.int)

proc cachedWidth(font: Font; text: string): int =
  ## Width of `text`, measured once per font until the cache is reset.
  let key = text & "|" & $cast[uint](font)
  if widthCache.hasKey(key):
    return widthCache[key]
  if widthCache.len >= 4096:
    widthCache.clear()
  result = measureText(font, text)[0]
  widthCache[key] = result



proc pumpIconResults*() =
  if st.isNil: return
  while true:
    let (dataAvail, res) = iconResChan.tryRecv()
    if not dataAvail: break
    
    iconPendingSet.del(res.cacheKey)
    if res.surface.isNil:
      st.iconCache[res.cacheKey] = nil
      continue
      
    let tex = createTextureFromSurface(st.renderer, res.surface)
    destroySurface(res.surface)
    
    if tex.isNil:
      st.iconCache[res.cacheKey] = nil
      continue
      
    discard setTextureScaleMode(tex, SCALEMODE_LINEAR)
    var wf, hf: cfloat
    discard getTextureSize(tex, wf, hf)
    
    st.iconCache[res.cacheKey] = IconTexture(
      tex: tex,
      w: int(round(wf.float)),
      h: int(round(hf.float))
    )

proc getIconTexture(iconName: string; size: int): IconTexture =
  ## Get (or lazily load) an icon texture for a given iconName.
  if iconName.len == 0 or st.isNil:
    return nil

  let cacheKey = iconName & ":" & $size
  if st.iconCache.hasKey(cacheKey):
    return st.iconCache[cacheKey]

  if not iconPendingSet.hasKey(cacheKey):
    iconPendingSet[cacheKey] = true
    iconReqChan.send(IconRequest(cacheKey: cacheKey, iconName: iconName, size: size))

  return nil

proc drawIconAt(slotX, y: int; slotSize: int; iconName: string): int =
  ## Draw icon/fallback inside slot and return next text X position.
  let m = currentMetrics()
  result = slotX - m.rowTextInsetPx
  if iconName.len == 0:
    return

  var icon = getIconTexture(iconName, slotSize)
  if icon.isNil:
    icon = getIconTexture(DefaultFallbackIcon, slotSize)

  if icon != nil and not icon.tex.isNil:
    let maxDim = slotSize
    let scale = min(maxDim.float / icon.w.float, maxDim.float / icon.h.float)
    let dstW = int(round(icon.w.float * scale))
    let dstH = int(round(icon.h.float * scale))
    let dst = toFRect(slotX + (slotSize - dstW) div 2,
        y + (m.lineHeightPx - dstH) div 2, dstW, dstH)
    discard renderTexture(st.renderer, icon.tex, nil, dst.addr)
  else:
    let box = toFRect(slotX, y + (m.lineHeightPx - slotSize) div 2, slotSize, slotSize)
    discard setRenderDrawColor(st.renderer, colBg.r, colBg.g, colBg.b, 255'u8)
    discard renderFillRect(st.renderer, box.addr)
    discard setRenderDrawColor(st.renderer, colFg.r, colFg.g, colFg.b, 255'u8)
    discard renderRect(st.renderer, box.addr)

  result = slotX + slotSize + m.iconTextGapPx

# -------------------
# Drawing
# -------------------
const Ellipsis = "…"

type
  ## A byte range of a label drawn in one font and colour.
  TextRun = object
    a, b: int
    matched: bool

proc blitText(font: Font; text: string; color: Color; x, top, height: int): int =
  ## Draw `text` vertically centred in [top, top + height); return its width.
  let tex = renderText(font, text, color)
  if tex.isNil: return 0
  var tw, th: cfloat
  discard getTextureSize(tex, tw, th)
  let textHeight = int(round(th.float))
  let width = int(round(tw.float))
  let dst = toFRect(x, top + (height - textHeight) div 2, width, textHeight)
  discard renderTexture(st.renderer, tex, nil, dst.addr)
  width

proc buildRuns(limit: int; spans: seq[(int, int)]): seq[TextRun] =
  ## Split [0, limit) into alternating plain and matched runs. Adjacent spans
  ## become one run, so each run is a single texture.
  var pos = 0
  for (start, length) in spans:
    let first = max(start, pos)
    let last = min(start + length, limit)
    if length > 0 and first < last:
      if first > pos:
        result.add TextRun(a: pos, b: first)
      if result.len > 0 and result[^1].matched and result[^1].b == first:
        result[^1].b = last
      else:
        result.add TextRun(a: first, b: last, matched: true)
      pos = last
  if pos < limit:
    result.add TextRun(a: pos, b: limit)

proc runsWidth(text: string; runs: seq[TextRun]): int =
  for run in runs:
    let font = if run.matched: st.fontBold else: st.font
    result += cachedWidth(font, text[run.a ..< run.b])

proc rowTextAvail(rowX, textX: int): int =
  ## Width available for text that starts at `textX` in a row at `rowX`.
  let m = currentMetrics()
  max(1, m.drawW - rowX - m.rowTextInsetPx - textX)

proc fitRuns(text: string; spans: seq[(int, int)]; avail: int;
    runs: var seq[TextRun]): bool =
  ## Build the runs for `text`; when it is wider than `avail`, cut it at the
  ## longest UTF-8-safe prefix that leaves room for an ellipsis and return true.
  runs = buildRuns(text.len, spans)
  if runsWidth(text, runs) <= avail:
    return false
  let budget = avail - measureText(st.font, Ellipsis)[0]
  var cuts: seq[int] = @[0]
  for i in 1 .. text.len:
    if i == text.len or (ord(text[i]) and 0xC0) != 0x80:
      cuts.add i
  var lo = 0
  var hi = cuts.high
  while lo < hi:
    let mid = (lo + hi + 1) div 2
    if runsWidth(text, buildRuns(cuts[mid], spans)) <= budget:
      lo = mid
    else:
      hi = mid - 1
  runs = buildRuns(cuts[lo], spans)
  true

proc runeCuts(text: string): seq[int] =
  ## Byte offsets of every rune boundary in `text`, including its end.
  for i in 0 .. text.len:
    if i == text.len or (ord(text[i]) and 0xC0) != 0x80:
      result.add i

proc fitCaret(prompt, body: string; pos: int; cursor: string; avail: int): string =
  ## `prompt & body & cursor` with the cursor inserted at byte `pos` of `body`.
  ## When too wide, keep the prompt and caret, eliding the start of the text
  ## before the caret first and then the end of the text after it.
  let pos = clamp(pos, 0, body.len)
  let before = body[0 ..< pos]
  let after = body[pos .. ^1]
  result = prompt & before & cursor & after
  if measureText(st.font, result)[0] <= avail:
    return
  ## Larger cut index = shorter tail = narrower line.
  let cuts = runeCuts(before)
  if measureText(st.font, prompt & Ellipsis & cursor & after)[0] <= avail:
    var lo = 0
    var hi = cuts.high
    while lo < hi:
      let mid = (lo + hi) div 2
      if measureText(st.font, prompt & Ellipsis & before[cuts[mid] .. ^1] &
          cursor & after)[0] <= avail:
        hi = mid
      else:
        lo = mid + 1
    return prompt & Ellipsis & before[cuts[lo] .. ^1] & cursor & after
  ## Even a bare caret overflows: keep as much of the text after it as fits.
  let afterCuts = runeCuts(after)
  var lo = 0
  var hi = afterCuts.high
  while lo < hi:
    let mid = (lo + hi + 1) div 2
    if measureText(st.font, prompt & Ellipsis & cursor & after[0 ..< afterCuts[mid]] &
        Ellipsis)[0] <= avail:
      lo = mid
    else:
      hi = mid - 1
  result = prompt & Ellipsis & cursor & after[0 ..< afterCuts[lo]]
  if afterCuts[lo] < after.len:
    result.add Ellipsis

proc drawText(x, y: int; text: string; spans: seq[(int, int)] = @[];
    selected = false; iconName = "") =
  if st.isNil or st.renderer.isNil: return
  let m = currentMetrics()
  let baseColor = if selected: colHighlightFg else: colFg
  let bg = if selected: colHighlightBg else: colBg

  ## Fill row background
  let rect = toFRect(x, y, max(1, m.drawW - 2 * x), m.lineHeightPx)
  discard setRenderDrawColor(st.renderer, bg.r, bg.g, bg.b, 255'u8)
  discard renderFillRect(st.renderer, rect.addr)

  var textX = x + m.rowTextInsetPx

  ## Icon slot (adaptive size)
  let iconSlot = m.iconSlotPx
  let slotX = x + m.iconInsetPx
  if ctx.config.showIcons and iconName.len > 0:
    textX = drawIconAt(slotX, y, iconSlot, iconName)

  ## Plain and matched runs drawn left to right, truncated with an ellipsis.
  var runs: seq[TextRun]
  let truncated = fitRuns(text, spans, rowTextAvail(x, textX), runs)
  for run in runs:
    textX += blitText(if run.matched: st.fontBold else: st.font,
        text[run.a ..< run.b], if run.matched: colMatch else: baseColor,
        textX, y, m.lineHeightPx)
  if truncated:
    discard blitText(st.font, Ellipsis, baseColor, textX, y, m.lineHeightPx)

## Draw right-aligned overlay text above the result area.
proc drawOverlay(text: string; color: Color) =
  let m = currentMetrics()
  let (w, _) = measureText(st.fontOverlay, text)
  let margin = m.overlayMarginPx
  let tx = m.drawW - w - margin
  let ty = if ctx.config.vimMode:
      margin + m.overlayLineHeightPx + m.overlayStackGapPx
    else: margin
  let tex = renderText(st.fontOverlay, text, color)
  if tex.isNil: return
  var tw, th: cfloat
  discard getTextureSize(tex, tw, th)
  let dst = toFRect(tx, ty, int(round(tw.float)), int(round(th.float)))
  discard renderTexture(st.renderer, tex, nil, dst.addr)

## Draw the fading theme-name overlay while a preview is active.
proc drawThemeOverlay() =
  if currentThemeName.len == 0: return
  let elapsed = nowMs() - lastThemeSwitchMs
  if elapsed > ThemeFadeMs: return
  var color = colFg
  color.a = uint8(255.0 * (1.0 - elapsed.float / ThemeFadeMs.float))
  drawOverlay(currentThemeName, color)

## Draw the current status message until its deadline.
proc drawStatusOverlay() =
  if statusText.len == 0: return
  if nowMs() > statusUntilMs: return
  drawOverlay(statusText, colFg)

proc drawClock(topRight = false) =
  let m = currentMetrics()
  let t = now()
  let nowStr = t.format("HH:mm")
  lastClockMinute = minuteOfDay(t)
  let (w, h) = measureText(st.fontOverlay, nowStr)
  let cx = m.drawW - w - roundScaled(BaseClockRightMargin, m.scale)
  let cy = if topRight: m.outerMarginPx else:
      m.drawH - h - m.overlayMarginPx
  let tex = renderText(st.fontOverlay, nowStr, colFg)
  if tex.isNil: return
  var tw, th: cfloat
  discard getTextureSize(tex, tw, th)
  let dst = toFRect(cx, cy, int(round(tw.float)), int(round(th.float)))
  discard renderTexture(st.renderer, tex, nil, dst.addr)

proc drawPromptAndInput(y: var int) =
  let m = currentMetrics()
  # Prompt + input line (hidden in Vim mode to mirror original)
  if not ctx.config.vimMode:
    let rowX = roundScaled(BasePromptInset, m.scale)
    let promptLine = fitCaret(ctx.config.prompt, ctx.inputText, ctx.inputCursor, ctx.config.cursor,
        rowTextAvail(rowX, rowX + m.rowTextInsetPx))
    drawText(rowX, y, promptLine)
    y += m.lineHeightPx + m.rowGapPx
  else:
    y = m.contentTopPx

proc drawVisibleRows(startY: int): int =
  let m = currentMetrics()
  var y = startY
  let total = ctx.actions.len
  let maxRows = m.visibleRows
  let start = ctx.viewOffset
  let finish = min(ctx.viewOffset + maxRows, total)
  for idx in start ..< finish:
    let action = ctx.actions[idx]
    let selected = (idx == ctx.selectedIndex)
    drawText(roundScaled(BasePromptInset, m.scale), y, action.label,
        action.spans, selected, action.iconName)
    y += m.lineHeightPx
  y

proc drawOverlays() =
  if ctx.themePreviewActive:
    drawThemeOverlay()
  else:
    drawStatusOverlay()
  if ctx.config.showClock:
    drawClock(topRight = ctx.config.vimMode)

proc drawCommandBar() =
  if not (ctx.config.vimMode and ctx.vim.active):
    return
  let m = currentMetrics()
  let barHeight = m.lineHeightPx + m.commandBarExtraHeightPx
  var barTop = m.drawH - barHeight - m.commandBarBottomGapPx
  if barTop < 0: barTop = 0
  let barRect = toFRect(0, barTop, m.drawW, barHeight)
  discard setRenderDrawColor(st.renderer, colHighlightBg.r, colHighlightBg.g,
      colHighlightBg.b, 255'u8)
  discard renderFillRect(st.renderer, barRect.addr)
  let padX = roundScaled(BasePromptInset, m.scale)
  var textX = padX
  if ctx.vim.prefix.len > 0:
    textX += blitText(st.font, ctx.vim.prefix, colHighlightFg, textX, barTop,
        barHeight) + m.overlayStackGapPx
  if ctx.vim.buffer.len > 0:
    let barText = fitCaret("", ctx.vim.buffer, ctx.vim.buffer.len, "", max(1, m.drawW - padX - textX))
    discard blitText(st.font, barText, colHighlightFg, textX, barTop, barHeight)

proc drawBorder() =
  let m = currentMetrics()
  let maxUsableBorder = max(0, (min(m.drawW, m.drawH) - 1) div 2)
  let borderWidth = min(m.borderWidthPx, maxUsableBorder)
  if borderWidth <= 0:
    return
  discard setRenderDrawColor(st.renderer, colBorder.r, colBorder.g, colBorder.b, 255'u8)
  
  let w = m.drawW.cfloat
  let h = m.drawH.cfloat
  let bw = borderWidth.cfloat
  
  # Top border
  var topRect = toFRect(0, 0, w.int, bw.int)
  discard renderFillRect(st.renderer, topRect.addr)
  
  # Bottom border
  var botRect = toFRect(0, (h - bw).int, w.int, bw.int)
  discard renderFillRect(st.renderer, botRect.addr)
  
  # Left border
  var leftRect = toFRect(0, bw.int, bw.int, (h - 2*bw).int)
  discard renderFillRect(st.renderer, leftRect.addr)
  
  # Right border
  var rightRect = toFRect((w - bw).int, bw.int, bw.int, (h - 2*bw).int)
  discard renderFillRect(st.renderer, rightRect.addr)

proc presentFrame() =
  if not st.windowShown:
    discard showWindow(st.window)
    discard syncWindow(st.window)
    st.windowShown = true
  if not st.windowRaised:
    ## Hint most WMs to focus/raise us even when marked as utility/skip-taskbar.
    discard raiseWindow(st.window)
    when declared(setWindowAlwaysOnTop):
      if isX11Backend():
        discard setWindowAlwaysOnTop(st.window, true)
        discard setWindowAlwaysOnTop(st.window, false)
    discard syncWindow(st.window)
    st.windowRaised = true
  discard renderPresent(st.renderer)

when WindowDebug:
  proc layoutMetrics*(): tuple[logicalW, logicalH, drawW, drawH, lineH, iconSlot,
      borderW: int; scale, displayScale, pixelDensity, contentScale: float32;
      displayID: DisplayID] =
    let m = currentMetrics()
    (m.logicalWinW, m.logicalWinH, m.drawW, m.drawH, m.lineHeightPx,
     m.iconSlotPx, m.borderWidthPx, m.scale, m.displayScale, m.pixelDensity,
     m.contentScale, m.displayID)

  proc windowMetrics*(): tuple[winW, winH, drawW, drawH: int] =
    ## Return logical window size + renderer drawable size (pixels).
    let m = currentMetrics()
    if m.logicalWinW <= 0 or m.logicalWinH <= 0:
      return (0, 0, 0, 0)
    (m.logicalWinW, m.logicalWinH, m.drawW, m.drawH)

proc redrawWindow*() =
  if st.isNil: return
  pumpIconResults()

  when WindowDebug:
    let wm = windowMetrics()
    let lm = layoutMetrics()
    echo "[window-debug] redrawWindow win=", wm.winW, "x", wm.winH,
        " drawable=", wm.drawW, "x", wm.drawH,
        " layout=", lm.logicalW, "x", lm.logicalH,
        " display=", lm.displayID,
        " displayScale=", lm.displayScale,
        " pixelDensity=", lm.pixelDensity,
        " contentScale=", lm.contentScale,
        " line=", lm.lineH,
        " icon=", lm.iconSlot,
        " scale=", lm.scale

  discard setRenderDrawColor(st.renderer, colBg.r, colBg.g, colBg.b, colBg.a)
  discard renderClear(st.renderer)

  let metrics = currentMetrics()
  var y = if ctx.config.vimMode: metrics.contentTopPx else: metrics.outerMarginPx
  drawPromptAndInput(y)
  discard drawVisibleRows(y)
  drawOverlays()
  drawCommandBar()
  drawBorder()
  updateTextInputArea()
  presentFrame()
