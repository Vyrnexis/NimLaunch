## gui.nim — SDL2/TTF renderer for NimLaunch2
## Provides a thin API mirroring the original GUI (updateGuiColors, redrawWindow, etc.).

import std/[os, strutils, times, tables, streams, osproc]
import sdl2
import sdl2/ttf
import sdl2/image
import ./[state, paths]

when not declared(setWindowOpacity):
  proc setWindowOpacity(window: WindowPtr; opacity: cfloat): cint {.cdecl, importc: "SDL_SetWindowOpacity", dynlib: LibName.}

when not declared(SDL_WINDOW_SKIP_TASKBAR):
  const SDL_WINDOW_SKIP_TASKBAR* = 0x00010000'u32

when not declared(SDL_WINDOW_UTILITY):
  const SDL_WINDOW_UTILITY* = 0x00020000'u32

when not declared(setWindowAlwaysOnTop):
  proc setWindowAlwaysOnTop(window: WindowPtr; on: cint): cint {.cdecl, importc: "SDL_SetWindowAlwaysOnTop", dynlib: LibName.}

when not declared(raiseWindow):
  proc raiseWindow(window: WindowPtr) {.cdecl, importc: "SDL_RaiseWindow", dynlib: LibName.}

type
  IconTexture = ref object
    tex: TexturePtr
    w, h: int

  BackendState = ref object
    window: WindowPtr
    renderer: RendererPtr
    font: FontPtr
    fontBold: FontPtr
    fontOverlay: FontPtr
    iconCache: Table[string, IconTexture]
    windowShown: bool
    windowRaised: bool

var st: BackendState

# Colours cached from Config
var
  colBg: Color
  colFg: Color
  colHighlightBg: Color
  colHighlightFg: Color
  colMatch: Color
  colBorder: Color

const
  IconSearchSizes = [16, 20, 24, 32, 48]
  IconThemes = ["hicolor", "Papirus", "Papirus-Dark", "Adwaita", "Adwaita-dark",
                "gnome", "Breeze", "Numix", "Numix-Circle", "Elementary"]
  IconRoots = [getHomeDir() / ".local/share/icons", "/usr/share/icons"]
  IconSearchDirsBase = [
    "/usr/share/icons/hicolor",
    "/usr/share/pixmaps"
  ]
  DefaultFontPath = "/usr/share/fonts/TTF/DejaVuSans.ttf"
  DefaultFallbackIcon = "application-x-executable"

var
  lastThemeSwitchMs*: int64 = 0
  currentThemeName: string = ""
  statusText*: string = ""
  statusUntilMs*: int64 = 0

# -------------------
# Helpers
# -------------------
proc rgbToColor(c: Rgb; a: uint8 = 255'u8): Color =
  result.r = c.r
  result.g = c.g
  result.b = c.b
  result.a = a

proc deriveFontSizeFromConfig(): int =
  ## Parse config.fontName looking for ":size=N" or "size=N".
  const key = "size="
  let lower = config.fontName.toLowerAscii
  let idx = lower.find(key)
  if idx >= 0:
    var j = idx + key.len
    var n = 0
    while j < lower.len and lower[j].isDigit:
      n = n * 10 + (ord(lower[j]) - ord('0'))
      inc j
    if n > 0: return n
  12

proc loadFont(path: string; size: int; makeBold = false): FontPtr =
  let f = openFont(path.cstring, size.cint)
  if f.isNil:
    quit "[ERROR] Failed to load font: " & path & " (" & $getError() & ")"
  if makeBold:
    setFontStyle(f, TTF_STYLE_BOLD.cint)
  f

proc resolveFontPath(name: string): string =
  ## Resolve a fontconfig name to a file path via fc-match; fall back to defaults.
  if name.len == 0:
    return DefaultFontPath
  if name.contains('/'):
    return name
  try:
    let p = startProcess(
      "fc-match",
      args = @["-f", "%{file}\n", name],
      options = {poUsePath, poStdErrToStdOut}
    )
    defer: close(p)
    let output = p.outputStream.readAll().strip()
    if output.len > 0:
      return output
  except CatchableError:
    discard
  DefaultFontPath

proc computeAlignedWindowY(winHeight: int): cint =
  ## Compute window Y for centerWindow + verticalAlign using display bounds.
  var bounds: Rect
  if getDisplayBounds(0, bounds) != SdlSuccess:
    return SDL_WINDOWPOS_CENTERED

  let displayTop = bounds.y.int
  let displayH = bounds.h.int
  if displayH <= 0:
    return SDL_WINDOWPOS_CENTERED

  let align = config.verticalAlign.toLowerAscii
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
  if sdl2.wasInit(INIT_VIDEO) == 0'u32:
    if not sdl2.init(INIT_VIDEO):
      quit "[ERROR] SDL init failed: " & $getError()
  if ttfInit().int != 0:
    quit "[ERROR] TTF init failed: " & $getError()
  discard image.init(IMG_INIT_PNG)

proc destroyState() =
  if st.isNil: return
  stopTextInput()
  for _, tex in st.iconCache:
    if not tex.isNil and not tex.tex.isNil:
      tex.tex.destroy()
  st.iconCache.clear()
  if not st.font.isNil: st.font.close()
  if not st.fontBold.isNil: st.fontBold.close()
  if not st.fontOverlay.isNil: st.fontOverlay.close()
  if not st.renderer.isNil: st.renderer.destroy()
  if not st.window.isNil: st.window.destroy()
  st = nil
  ttfQuit()
  sdl2.quit()

proc nowMs*(): int64 =
  (epochTime() * 1_000).int64

proc notifyThemeChanged*(name: string) =
  currentThemeName = name
  lastThemeSwitchMs = nowMs()

proc notifyStatus*(text: string; durationMs = 800) =
  statusText = text
  statusUntilMs = nowMs() + durationMs

# -------------------
# Init / Shutdown
# -------------------
proc initGui*() =
  ensureSdl()

  let size = deriveFontSizeFromConfig()
  let fontPath = resolveFontPath(config.fontName)

  ## Request a dock/utility window type so most WMs hide us from the taskbar.
  discard setHint("SDL_VIDEO_X11_NET_WM_WINDOW_TYPE", "_NET_WM_WINDOW_TYPE_DOCK,_NET_WM_WINDOW_TYPE_UTILITY")

  st = BackendState(
    window: createWindow(
      "NimLaunch2 SDL2".cstring,
      if config.centerWindow: SDL_WINDOWPOS_CENTERED else: cint(config.positionX),
      if config.centerWindow: computeAlignedWindowY(config.winMaxHeight) else: cint(config.positionY),
      cint(config.winWidth),
      cint(config.winMaxHeight),
      SDL_WINDOW_HIDDEN or SDL_WINDOW_BORDERLESS or SDL_WINDOW_SKIP_TASKBAR or SDL_WINDOW_UTILITY
    )
  )
  if st.window.isNil:
    quit "[ERROR] createWindow: " & $getError()

  discard setHint(HINT_RENDER_SCALE_QUALITY, "0") # nearest for crisper icons

  st.renderer = createRenderer(
    st.window,
    -1,
    Renderer_Accelerated or Renderer_PresentVsync
  )
  if st.renderer.isNil:
    quit "[ERROR] createRenderer: " & $getError()

  st.font = loadFont(fontPath, size)
  st.fontBold = loadFont(fontPath, size, makeBold = true)
  st.fontOverlay = loadFont(fontPath, max(size - 2, 6))
  st.iconCache = initTable[string, IconTexture]()

  when declared(setWindowOpacity):
    let opac = if config.opacity < 0.1: 0.1 elif config.opacity > 1.0: 1.0 else: config.opacity
    discard setWindowOpacity(st.window, opac.cfloat)

  startTextInput()

proc shutdownGui*() =
  destroyState()

proc updateGuiColors*() =
  colBg = rgbToColor(config.bgColor)
  colFg = rgbToColor(config.fgColor)
  colHighlightBg = rgbToColor(config.highlightBgColor)
  colHighlightFg = rgbToColor(config.highlightFgColor)
  colMatch = rgbToColor(config.matchFgColor)
  colBorder = rgbToColor(config.borderColor)

# -------------------
# Text rendering helpers
# -------------------
proc renderText(font: FontPtr; text: string; color: Color): TexturePtr =
  if text.len == 0 or font.isNil: return nil
  let surf = renderUTF8Blended(font, text.cstring, color)
  if surf.isNil: return nil
  let tex = createTextureFromSurface(st.renderer, surf)
  if tex.isNil:
    freeSurface(surf)
    return nil
  freeSurface(surf)
  tex

proc measureText(font: FontPtr; text: string): (int, int) =
  var w, h: cint
  discard sizeUTF8(font, text.cstring, addr w, addr h)
  (w.int, h.int)

# -------------------
# Icon resolution (PNG-only)
# -------------------
proc rasterizeSvg(svgPath: string; size: int): string =
  ## Convert an SVG icon to a cached PNG using rsvg-convert; returns cache path or "".
  let exe = findExe("rsvg-convert")
  if exe.len == 0: return ""
  let cacheDir = iconCacheDir(size)
  try: createDir(cacheDir) except CatchableError: discard
  let base = svgPath.extractFilename
  let outPath = cacheDir / (base & ".png")
  if fileExists(outPath):
    return outPath
  try:
    let p = startProcess(
      exe,
      args = @["-w", $size, "-h", $size, svgPath],
      options = {poUsePath, poStdErrToStdOut}
    )
    defer: close(p)
    let pngData = p.outputStream.readAll()
    let code = p.waitForExit()
    if code == 0 and pngData.len > 0:
      writeFile(outPath, pngData)
      return outPath
  except CatchableError:
    discard
  ""

proc searchIconInDir(base: string; size: int; iconName: string): string =
  ## Search a specific base dir for size/scalable icons.
  for ext in [".png", ".svg"]:
    # size-specific
    let p = base / ($size & "x" & $size) / "apps" / (iconName & ext)
    if fileExists(p):
      if ext == ".svg": return rasterizeSvg(p, size)
      return p
    # scalable
    let scalable = base / "scalable" / "apps" / (iconName & ext)
    if fileExists(scalable):
      if ext == ".svg": return rasterizeSvg(scalable, size)
      return scalable
  ""

proc resolveIconPath(iconName: string; requestedSize: int): string =
  ## Resolve an icon name to a rasterizable file path; supports PNG directly and SVG via rsvg-convert.
  if iconName.len == 0:
    return ""
  var candidates: seq[string] = @[iconName]
  let lower = iconName.toLowerAscii
  if lower != iconName:
    candidates.add(lower)

  # If iconName is an absolute path, accept only .png files.
  if '/' in iconName:
    let lower = iconName.toLowerAscii()
    if fileExists(iconName) and (lower.endsWith(".png") or lower.endsWith(".svg")):
      if lower.endsWith(".svg"):
        return rasterizeSvg(iconName, requestedSize)
      return iconName
    return ""

  # Build list of icon sizes to try: requested first, then fallbacks.
  var sizes: seq[int] = @[]
  if requestedSize > 0:
    sizes.add(requestedSize)

  for s in IconSearchSizes:
    if s notin sizes:
      sizes.add(s)

  # Search in hicolor + pixmaps
  for icon in candidates:
    for size in sizes:
      for base in IconSearchDirsBase:
        if base == "/usr/share/pixmaps":
          # Pixmaps usually have no size subdir
          for ext in [".png", ".svg"]:
            let p = base / (icon & ext)
            if fileExists(p):
              if ext == ".svg": return rasterizeSvg(p, size)
              return p
        else:
          # hicolor/<size>x<size>/apps/<icon>.png or .svg (including scalable)
          let sizedDir = base / ($size & "x" & $size) / "apps"
          for ext in [".png", ".svg"]:
            let p = sizedDir / (icon & ext)
            if fileExists(p):
              if ext == ".svg": return rasterizeSvg(p, size)
              return p
          # scalable icons
          let scalable = base / "scalable" / "apps" / (icon & ".svg")
          if fileExists(scalable):
            let raster = rasterizeSvg(scalable, size)
            if raster.len > 0: return raster

  # Search common themes under icon roots
  for icon in candidates:
    for size in sizes:
      for root in IconRoots:
        if not dirExists(root): continue
        for theme in IconThemes:
          let base = root / theme
          if dirExists(base):
            let hit = searchIconInDir(base, size, icon)
            if hit.len > 0: return hit

  result = ""

proc loadPngTexture(path: string): IconTexture =
  ## Load a PNG from disk into an SDL_Texture using SDL2_image.
  if path.len == 0:
    return nil

  let tex = image.loadTexture(st.renderer, path.cstring)
  if tex.isNil:
    return nil

  var w, h: cint
  discard queryTexture(tex, nil, nil, addr w, addr h)

  new(result)
  result.tex = tex
  result.w = w
  result.h = h

proc getIconTexture(iconName: string; size: int): IconTexture =
  ## Get (or lazily load) an icon texture for a given iconName.
  if iconName.len == 0 or st.isNil:
    return nil

  let cacheKey = iconName & ":" & $size
  if st.iconCache.hasKey(cacheKey):
    return st.iconCache[cacheKey]

  let path = resolveIconPath(iconName, size)
  if path.len == 0:
    return nil

  let tex = loadPngTexture(path)
  if tex.isNil:
    return nil

  st.iconCache[cacheKey] = tex
  result = tex

proc drawIconAt(slotX, y: int; slotSize: int; iconName: string): int =
  ## Draw icon/fallback inside slot and return next text X position.
  result = slotX - 2
  if iconName.len == 0:
    return

  var icon = getIconTexture(iconName, slotSize)
  if icon.isNil:
    icon = getIconTexture(DefaultFallbackIcon, slotSize)

  if icon != nil and not icon.tex.isNil:
    let maxDim = slotSize
    let scale = min(maxDim.float / icon.w.float, maxDim.float / icon.h.float)
    let dstW = cint(icon.w.float * scale)
    let dstH = cint(icon.h.float * scale)
    var dst: Rect
    dst.w = dstW
    dst.h = dstH
    dst.x = cint(slotX + (slotSize - dstW.int) div 2)
    dst.y = cint(y + (config.lineHeight - dstH.int) div 2)
    discard st.renderer.copy(icon.tex, nil, addr dst)
  else:
    var box: Rect
    box.w = slotSize.cint
    box.h = slotSize.cint
    box.x = cint(slotX)
    box.y = cint(y + (config.lineHeight - slotSize) div 2)
    discard st.renderer.setDrawColor(colBg.r, colBg.g, colBg.b, 255'u8)
    discard st.renderer.fillRect(addr box)
    discard st.renderer.setDrawColor(colFg.r, colFg.g, colFg.b, 255'u8)
    discard st.renderer.drawRect(addr box)

  result = slotX + (slotSize + 8)

# -------------------
# Drawing
# -------------------
proc drawText(x, y: int; text: string; spans: seq[(int, int)] = @[]; selected = false; iconName = "") =
  if st.isNil or st.renderer.isNil: return
  let baseColor = if selected: colHighlightFg else: colFg
  let bg = if selected: colHighlightBg else: colBg

  ## Fill row background
  var rect: Rect
  rect.x = cint(x)
  rect.y = cint(y - 2)
  rect.w = cint(config.winWidth - 2 * x)
  rect.h = cint(config.lineHeight)
  discard st.renderer.setDrawColor(bg.r, bg.g, bg.b, 255'u8)
  discard st.renderer.fillRect(addr rect)

  var textX = x + 2

  ## Icon slot (adaptive size)
  let iconSlot = max(16, min(config.lineHeight - 2, 32))
  let slotX = x + 4
  if config.showIcons and iconName.len > 0:
    textX = drawIconAt(slotX, y, iconSlot, iconName)

  ## Base text
  if text.len > 0:
    let tex = renderText(st.font, text, baseColor)
    if not tex.isNil:
      var dst: Rect
      dst.x = cint(textX)
      dst.y = cint(y)
      discard queryTexture(tex, nil, nil, addr dst.w, addr dst.h)
      discard st.renderer.copy(tex, nil, addr dst)
      tex.destroy()

  ## Highlight spans
  if spans.len > 0:
    for (s, len) in spans:
      if len <= 0 or s < 0 or s >= text.len: continue
      let e = min(s + len, text.len)
      let pre = if s > 0: text[0 ..< s] else: ""
      let seg = text[s ..< e]
      let (preW, _) = measureText(st.font, pre)
      let tex = renderText(st.fontBold, seg, colMatch)
      if tex.isNil: continue
      var dst: Rect
      dst.x = cint(textX + preW)
      dst.y = cint(y)
      discard queryTexture(tex, nil, nil, addr dst.w, addr dst.h)
      discard st.renderer.copy(tex, nil, addr dst)
      tex.destroy()

proc drawThemeOverlay() =
  if currentThemeName.len == 0: return
  let elapsed = nowMs() - lastThemeSwitchMs
  if elapsed > 500: return
  let alpha = 1.0 - (elapsed.float / 500.0)
  var col = colFg
  col.a = uint8(255.0 * alpha)
  let (w, _) = measureText(st.fontOverlay, currentThemeName)
  let margin = 8
  let tx = config.winWidth - w - margin
  let ty = margin
  let tex = renderText(st.fontOverlay, currentThemeName, col)
  if tex.isNil: return
  var dst: Rect
  dst.x = tx.cint
  dst.y = ty.cint
  discard queryTexture(tex, nil, nil, addr dst.w, addr dst.h)
  discard st.renderer.copy(tex, nil, addr dst)
  tex.destroy()

proc drawStatusOverlay() =
  if statusText.len == 0: return
  if nowMs() > statusUntilMs: return
  let (w, h) = measureText(st.fontOverlay, statusText)
  let margin = 8
  let tx = config.winWidth - w - margin
  let ty = margin + h + 4
  let tex = renderText(st.fontOverlay, statusText, colFg)
  if tex.isNil: return
  var dst: Rect
  dst.x = tx.cint
  dst.y = ty.cint
  discard queryTexture(tex, nil, nil, addr dst.w, addr dst.h)
  discard st.renderer.copy(tex, nil, addr dst)
  tex.destroy()

proc drawClock(topRight = false) =
  let nowStr = now().format("HH:mm")
  let (w, h) = measureText(st.fontOverlay, nowStr)
  let cx = config.winWidth - w - 10
  let cy = if topRight: h + 6 else: config.winMaxHeight - h - 8
  let tex = renderText(st.fontOverlay, nowStr, colFg)
  if tex.isNil: return
  var dst: Rect
  dst.x = cx.cint
  dst.y = cy.cint
  discard queryTexture(tex, nil, nil, addr dst.w, addr dst.h)
  discard st.renderer.copy(tex, nil, addr dst)
  tex.destroy()

proc drawPromptAndInput(y: var int) =
  # Prompt + input line (hidden in Vim mode to mirror original)
  if not config.vimMode:
    let promptLine = config.prompt & inputText & config.cursor
    drawText(12, y, promptLine)
    y += config.lineHeight + 6
  else:
    y += 2

proc drawVisibleRows(startY: int): int =
  var y = startY
  let total = filteredApps.len
  let maxRows = config.maxVisibleItems
  let start = viewOffset
  let finish = min(viewOffset + maxRows, total)
  for idx in start ..< finish:
    let row = filteredApps[idx]
    let selected = (idx == selectedIndex)
    drawText(12, y, row.text, matchSpans[idx], selected, row.iconName)
    y += config.lineHeight
  y

proc drawOverlays() =
  if themePreviewActive:
    drawThemeOverlay()
  else:
    drawStatusOverlay()
  if config.vimMode:
    drawClock(topRight = true)
  else:
    drawClock()

proc drawCommandBar() =
  if not (config.vimMode and vim.active):
    return
  let barHeight = config.lineHeight + 6
  var barTop = config.winMaxHeight - barHeight - 4
  if barTop < 0: barTop = 0
  var barRect: Rect
  barRect.x = 0
  barRect.y = barTop.cint
  barRect.w = config.winWidth.cint
  barRect.h = barHeight.cint
  discard st.renderer.setDrawColor(colHighlightBg.r, colHighlightBg.g, colHighlightBg.b, 255'u8)
  discard st.renderer.fillRect(addr barRect)
  var textX = 12
  if vim.prefix.len > 0:
    let prefixTex = renderText(st.font, vim.prefix, colHighlightFg)
    if not prefixTex.isNil:
      var pDst: Rect
      pDst.x = textX.cint
      discard queryTexture(prefixTex, nil, nil, addr pDst.w, addr pDst.h)
      pDst.y = cint(barTop + (barHeight - pDst.h.int) div 2)
      textX = pDst.x + pDst.w + 4
      discard st.renderer.copy(prefixTex, nil, addr pDst)
      prefixTex.destroy()
  let barText = vim.buffer
  if barText.len > 0:
    let tex = renderText(st.font, barText, colHighlightFg)
    if not tex.isNil:
      var dst: Rect
      dst.x = textX.cint
      discard queryTexture(tex, nil, nil, addr dst.w, addr dst.h)
      dst.y = cint(barTop + (barHeight - dst.h.int) div 2)
      discard st.renderer.copy(tex, nil, addr dst)
      tex.destroy()

proc drawBorder() =
  if config.borderWidth <= 0:
    return
  discard st.renderer.setDrawColor(colBorder.r, colBorder.g, colBorder.b, 255'u8)
  for i in 0 ..< config.borderWidth:
    var rect: Rect
    rect.x = cint(i)
    rect.y = cint(i)
    rect.w = cint(config.winWidth - 1 - i * 2)
    rect.h = cint(config.winMaxHeight - 1 - i * 2)
    discard st.renderer.drawRect(addr rect)

proc presentFrame() =
  if not st.windowShown:
    showWindow(st.window)
    st.windowShown = true
  if not st.windowRaised:
    ## Hint most WMs to focus/raise us even when marked as utility/skip-taskbar.
    raiseWindow(st.window)
    when declared(setWindowAlwaysOnTop):
      discard setWindowAlwaysOnTop(st.window, 1)
      discard setWindowAlwaysOnTop(st.window, 0)
    st.windowRaised = true
  st.renderer.present()

proc redrawWindow*() =
  if st.isNil: return

  discard st.renderer.setDrawColor(colBg.r, colBg.g, colBg.b, colBg.a)
  discard st.renderer.clear()

  var y = 10
  drawPromptAndInput(y)
  discard drawVisibleRows(y)
  drawOverlays()
  drawCommandBar()
  drawBorder()
  presentFrame()
