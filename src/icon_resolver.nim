## icon_resolver.nim — XDG icon discovery and resolution logic
##
## Follows the freedesktop Icon Theme Specification: themes are described by their
## `index.theme`, searched in preference order (including `Inherits=`), and each theme
## is searched for an exact size match before falling back to the closest size.

import std/[os, strutils, osproc, algorithm, streams, tables, sequtils]

const
  FallbackIconThemes = ["papirus", "papirus-dark", "adwaita", "adwaita-dark",
                        "breeze", "breeze-dark"]
  HicolorTheme = "hicolor"
  IconExts = [".png", ".svg", ".xpm"]
  DefaultIconSize = 16
  IconScale = 1

type
  DirKind = enum
    dkFixed, dkScalable, dkThreshold

  ThemeDir = object
    size, scale, minSize, maxSize, threshold: int
    kind: DirKind
    symbolic: bool
    paths: seq[string]  ## Existing on-disk directories, one per base dir.

  IconTheme = object
    name: string
    inherits: seq[string]
    dirs: seq[ThemeDir]

  SymbolicMode = enum
    smPlain, smSymbolicOnly, smAny

var
  resolverReady {.threadvar.}: bool
  preferredThemes {.threadvar.}: seq[string]
  themeLocations {.threadvar.}: Table[string, seq[string]]
  pixmapDirs {.threadvar.}: seq[string]
  themeChain {.threadvar.}: seq[IconTheme]
  iconCache {.threadvar.}: Table[string, string]
  otherThemes {.threadvar.}: seq[IconTheme]
  otherThemesReady {.threadvar.}: bool

# -------------------
# Theme preference
# -------------------
proc appendUniquePath(dst: var seq[string]; path: string) =
  if path.len == 0:
    return
  let cleaned = path.strip(chars = {DirSep, AltSep}, leading = false, trailing = true)
  if cleaned.len == 0:
    return
  if cleaned notin dst:
    dst.add(cleaned)

proc appendUniqueTheme(dst: var seq[string]; themeName: string) =
  let cleaned = themeName.strip(chars = {' ', '\t', '\'', '"'}).toLowerAscii
  if cleaned.len == 0:
    return
  if cleaned notin dst:
    dst.add(cleaned)

proc detectThemeFromGSettings(): string =
  let gsettingsExe = findExe("gsettings")
  if gsettingsExe.len == 0:
    return ""
  try:
    let p = startProcess(
      gsettingsExe,
      args = @["get", "org.gnome.desktop.interface", "icon-theme"],
      options = {poUsePath, poStdErrToStdOut}
    )
    defer: close(p)
    let output = p.outputStream.readAll().strip()
    let code = p.waitForExit()
    if code != 0 or output.len == 0:
      return ""
    result = output
    if result.len >= 2 and ((result[0] == '\'' and result[^1] == '\'') or
        (result[0] == '"' and result[^1] == '"')):
      result = result[1 .. ^2]
    result = result.strip(chars = {' ', '\t', '\'', '"'})
  except CatchableError:
    return ""

proc detectThemeFromGtkSettings(): string =
  let cfgHome = getEnv("XDG_CONFIG_HOME", getHomeDir() / ".config")
  let candidates = @[
    cfgHome / "gtk-4.0/settings.ini",
    cfgHome / "gtk-3.0/settings.ini"
  ]
  for iniPath in candidates:
    if not fileExists(iniPath):
      continue
    try:
      for rawLine in lines(iniPath):
        let line = rawLine.strip()
        if line.len == 0 or line.startsWith("#") or line.startsWith(";"):
          continue
        let lower = line.toLowerAscii
        if not lower.startsWith("gtk-icon-theme-name"):
          continue
        let eq = line.find('=')
        if eq < 0:
          continue
        return line[eq + 1 .. ^1].strip(chars = {' ', '\t', '\'', '"'})
    except CatchableError:
      discard
  ""

proc initPreferredIconThemes() =
  for theme in [getEnv("ICON_THEME"), detectThemeFromGSettings(),
      detectThemeFromGtkSettings()]:
    if theme.len == 0:
      continue
    appendUniqueTheme(preferredThemes, theme)
    let lower = theme.toLowerAscii
    if lower.endsWith("-dark"):
      appendUniqueTheme(preferredThemes, theme[0 ..< theme.len - 5])
    else:
      appendUniqueTheme(preferredThemes, theme & "-dark")

# -------------------
# Base directories
# -------------------
proc xdgDataRoots(): seq[string] =
  let xdgDataHome = getEnv("XDG_DATA_HOME")
  if xdgDataHome.len > 0:
    appendUniquePath(result, xdgDataHome)
  else:
    appendUniquePath(result, getHomeDir() / ".local/share")

  for entry in getEnv("XDG_DATA_DIRS", "/usr/local/share:/usr/share").split(':'):
    if entry.len == 0:
      continue
    appendUniquePath(result, entry)

  appendUniquePath(result, getHomeDir() / ".local/share/flatpak/exports/share")
  appendUniquePath(result, "/var/lib/flatpak/exports/share")

proc indexThemeLocations(baseDirs: seq[string]) =
  ## Map lowercase theme name -> theme directories (in base dir order).
  for base in baseDirs:
    try:
      for kind, path in walkDir(base, relative = false):
        if kind in {pcDir, pcLinkToDir}:
          let key = splitPath(path).tail.toLowerAscii
          if path notin themeLocations.mgetOrPut(key, @[]):
            themeLocations[key].add(path)
    except CatchableError:
      discard

# -------------------
# index.theme parsing
# -------------------
proc parseIniFile(path: string): Table[string, Table[string, string]] =
  var section = ""
  try:
    for rawLine in lines(path):
      let line = rawLine.strip()
      if line.len == 0 or line[0] in {'#', ';'}:
        continue
      if line[0] == '[' and line[^1] == ']':
        section = line[1 ..< line.len - 1]
        discard result.mgetOrPut(section, initTable[string, string]())
        continue
      let eq = line.find('=')
      if eq <= 0 or section.len == 0:
        continue
      result[section][line[0 ..< eq].strip()] = line[eq + 1 .. ^1].strip()
  except CatchableError:
    discard

proc splitList(value: string): seq[string] =
  for part in value.split(','):
    let item = part.strip()
    if item.len > 0 and item notin result:
      result.add(item)

proc intValue(section: Table[string, string]; key: string; default: int): int =
  try:
    if key in section:
      return parseInt(section[key])
  except ValueError:
    discard
  default

proc parseThemeDir(section: Table[string, string]; name: string;
                   locations: seq[string]): ThemeDir =
  ## Returns a dir with no paths when the section is unusable.
  if "Size" notin section:
    return
  let size = intValue(section, "Size", 0)
  result = ThemeDir(
    size: size,
    scale: max(1, intValue(section, "Scale", 1)),
    minSize: intValue(section, "MinSize", size),
    maxSize: intValue(section, "MaxSize", size),
    threshold: intValue(section, "Threshold", 2),
    kind: dkThreshold,
    symbolic: name.toLowerAscii.contains("symbolic")
  )
  case section.getOrDefault("Type").toLowerAscii
  of "fixed":
    result.kind = dkFixed
  of "scalable":
    result.kind = dkScalable
  else:
    discard
  for location in locations:
    let path = location / name
    if dirExists(path):
      result.paths.add(path)

proc loadTheme(name: string): IconTheme =
  ## Returns a theme with an empty name when no base dir provides an index.theme.
  let locations = themeLocations.getOrDefault(name)
  var indexPath = ""
  for location in locations:
    let candidate = location / "index.theme"
    if fileExists(candidate):
      indexPath = candidate
      break
  if indexPath.len == 0:
    return
  let ini = parseIniFile(indexPath)
  let header = ini.getOrDefault("Icon Theme")
  result = IconTheme(name: name)
  for parent in splitList(header.getOrDefault("Inherits")):
    result.inherits.add(parent.toLowerAscii)
  var dirNames = splitList(header.getOrDefault("Directories"))
  for scaled in splitList(header.getOrDefault("ScaledDirectories")):
    if scaled notin dirNames:
      dirNames.add(scaled)
  for dirName in dirNames:
    if dirName notin ini:
      continue
    let dir = parseThemeDir(ini[dirName], dirName, locations)
    if dir.paths.len > 0:
      result.dirs.add(dir)

proc addToChain(chain: var seq[IconTheme]; themeName: string) =
  let key = themeName.strip().toLowerAscii
  if key.len == 0 or key == HicolorTheme:
    return
  for theme in chain:
    if theme.name == key:
      return
  let theme = loadTheme(key)
  if theme.name.len == 0:
    return
  chain.add(theme)
  for parent in theme.inherits:
    addToChain(chain, parent)

proc initIconResolver() =
  if resolverReady:
    return
  initPreferredIconThemes()

  var baseDirs: seq[string] = @[]
  appendUniquePath(baseDirs, getHomeDir() / ".icons")
  for root in xdgDataRoots():
    appendUniquePath(baseDirs, root / "icons")
    let pixmaps = root / "pixmaps"
    if dirExists(pixmaps):
      appendUniquePath(pixmapDirs, pixmaps)
  if dirExists("/usr/share/pixmaps"):
    appendUniquePath(pixmapDirs, "/usr/share/pixmaps")
  indexThemeLocations(baseDirs)

  for theme in preferredThemes:
    addToChain(themeChain, theme)
  for theme in FallbackIconThemes:
    addToChain(themeChain, theme)
  let hicolor = loadTheme(HicolorTheme)
  if hicolor.name.len > 0:
    themeChain.add(hicolor)

  resolverReady = true

proc resetIconResolverForTests*() =
  ## Drop all cached state so the next lookup re-reads the environment and themes.
  resolverReady = false
  preferredThemes = @[]
  themeLocations = initTable[string, seq[string]]()
  pixmapDirs = @[]
  themeChain = @[]
  iconCache = initTable[string, string]()
  otherThemes = @[]
  otherThemesReady = false

# -------------------
# Lookup
# -------------------
proc hasImageExt(name: string): bool =
  let lower = name.toLowerAscii
  lower.endsWith(".png") or lower.endsWith(".svg") or lower.endsWith(".xpm")

proc matchesSize(dir: ThemeDir; size: int): bool =
  if dir.scale != IconScale:
    return false
  case dir.kind
  of dkFixed:
    dir.size == size
  of dkScalable:
    size in dir.minSize .. dir.maxSize
  of dkThreshold:
    size in dir.size - dir.threshold .. dir.size + dir.threshold

proc sizeDistance(dir: ThemeDir; size: int): int =
  let want = size * IconScale
  case dir.kind
  of dkFixed:
    abs(dir.size * dir.scale - want)
  of dkScalable:
    if want < dir.minSize * dir.scale:
      dir.minSize * dir.scale - want
    elif want > dir.maxSize * dir.scale:
      want - dir.maxSize * dir.scale
    else:
      0
  of dkThreshold:
    if want < (dir.size - dir.threshold) * dir.scale:
      (dir.size - dir.threshold) * dir.scale - want
    elif want > (dir.size + dir.threshold) * dir.scale:
      want - (dir.size + dir.threshold) * dir.scale
    else:
      0

proc dirAllowed(dir: ThemeDir; mode: SymbolicMode): bool =
  case mode
  of smPlain: not dir.symbolic
  of smSymbolicOnly: dir.symbolic
  of smAny: true

proc findInTheme(theme: IconTheme; files: seq[string]; size: int;
                 mode: SymbolicMode): string =
  ## Exact size matches come first (in Directories order), then the closest sizes,
  ## preferring the larger icon on ties. Each directory is visited at most once.
  var order: seq[tuple[group, dist, negPixels, idx: int]] = @[]
  for i, dir in theme.dirs:
    if not dirAllowed(dir, mode):
      continue
    if matchesSize(dir, size):
      order.add((0, 0, 0, i))
    else:
      order.add((1, sizeDistance(dir, size), -dir.size * dir.scale, i))
  order.sort()
  for entry in order:
    for path in theme.dirs[entry.idx].paths:
      for file in files:
        let candidate = path / file
        if fileExists(candidate):
          return candidate
  ""

proc findInChain(files: seq[string]; size: int; mode: SymbolicMode): string =
  for theme in themeChain:
    let hit = findInTheme(theme, files, size, mode)
    if hit.len > 0:
      return hit
  ""

proc findInOtherThemes(files: seq[string]; size: int): string =
  ## Last resort: installed themes outside the chain, loaded on first use.
  if not otherThemesReady:
    otherThemesReady = true
    var names: seq[string] = @[]
    for key in themeLocations.keys:
      names.add(key)
    names.sort()
    for key in names:
      if key == HicolorTheme or themeChain.anyIt(it.name == key):
        continue
      let theme = loadTheme(key)
      if theme.dirs.len > 0:
        otherThemes.add(theme)
  for theme in otherThemes:
    let hit = findInTheme(theme, files, size, smPlain)
    if hit.len > 0:
      return hit
  ""

proc fileNames(names: seq[string]): seq[string] =
  ## Expand icon names into file names; names that already carry an extension stay as is.
  for name in names:
    if hasImageExt(name):
      result.add(name)
    else:
      for ext in IconExts:
        result.add(name & ext)

proc findInPixmaps(files: seq[string]): string =
  for dir in pixmapDirs:
    for file in files:
      let candidate = dir / file
      if fileExists(candidate):
        return candidate
  ""

proc lookupIcon(iconName: string; size: int): string =
  var candidates: seq[string] = @[]
  proc addCandidate(name: string) =
    if name.len > 0 and name notin candidates:
      candidates.add(name)
  addCandidate(iconName)
  addCandidate(iconName.toLowerAscii)
  if hasImageExt(iconName):
    let dot = iconName.rfind('.')
    if dot > 0:
      let stem = iconName[0 ..< dot]
      addCandidate(stem)
      addCandidate(stem.toLowerAscii)

  let files = fileNames(candidates)
  let wantsSymbolic = iconName.toLowerAscii.contains("symbolic")

  # Prefer non-symbolic icons unless the requested name itself is symbolic.
  result = findInChain(files, size, if wantsSymbolic: smAny else: smPlain)
  if result.len == 0 and not wantsSymbolic:
    # Last resort inside the themes: symbolic directories, then "<name>-symbolic".
    result = findInChain(files, size, smSymbolicOnly)
    if result.len == 0:
      var symbolicNames: seq[string] = @[]
      for name in candidates:
        if not hasImageExt(name):
          symbolicNames.add(name & "-symbolic")
      result = findInChain(fileNames(symbolicNames), size, smAny)
  if result.len == 0:
    result = findInPixmaps(files)
  if result.len == 0:
    result = findInOtherThemes(files, size)

proc resolveIconPath*(iconName: string; requestedSize: int): string =
  ## Resolve an icon name to an on-disk image path usable by SDL3_image.
  if iconName.len == 0:
    return ""

  # If iconName is an absolute path, support direct image files and omitted extension.
  if '/' in iconName:
    if hasImageExt(iconName) and fileExists(iconName):
      return iconName
    for ext in IconExts:
      let p = iconName & ext
      if fileExists(p):
        return p
    return ""

  initIconResolver()

  let size = if requestedSize > 0: requestedSize else: DefaultIconSize
  let key = iconName & '\0' & $size
  if key in iconCache:
    return iconCache[key]
  result = lookupIcon(iconName, size)
  iconCache[key] = result
