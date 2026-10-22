## paths.nim — shared helpers for config/cache and application search paths.

import std/[os, strutils, sets]

const
  AppName = "nimlaunch"
  DefaultXdgDataDirs = "/usr/local/share:/usr/share"
  DefaultXdgDataHome = ".local/share"
  DefaultXdgConfigHome = ".config"
  DefaultXdgCacheHome = ".cache"

proc getXdgHome(envVar, defaultSuffix: string): string =
  let fromEnv = getEnv(envVar)
  if fromEnv.len > 0 and fromEnv.isAbsolute:
    return normalizedPath(fromEnv)
  getHomeDir() / defaultSuffix

proc homeDirNoSlash*(): string =
  ## Return $HOME without the trailing slash that `getHomeDir()` appends.
  getHomeDir().strip(leading = false, chars = {'/'})

proc userConfigHome*(): string =
  ## Return XDG config home (respects $XDG_CONFIG_HOME).
  getXdgHome("XDG_CONFIG_HOME", DefaultXdgConfigHome)

proc userCacheHome*(): string =
  ## Return XDG cache home (respects $XDG_CACHE_HOME).
  getXdgHome("XDG_CACHE_HOME", DefaultXdgCacheHome)

proc configDir*(): string =
  ## Return the base config directory for NimLaunch (~/.config/nimlaunch).
  userConfigHome() / AppName

proc cacheDir*(): string =
  ## Return the base cache directory for NimLaunch (~/.cache/nimlaunch).
  userCacheHome() / AppName

proc applicationDirs*(): seq[string] =
  ## Return the list of application directories to scan.
  ## Order: user data, user Flatpak, system XDG, system Flatpak.
  let userDataHome = getXdgHome("XDG_DATA_HOME", DefaultXdgDataHome)
  var dirs: seq[string] = @[
    userDataHome / "applications",
    userDataHome / "flatpak/exports/share/applications"
  ]

  var xdgDataDirs = getEnv("XDG_DATA_DIRS")
  if xdgDataDirs.len == 0:
    xdgDataDirs = DefaultXdgDataDirs
  for dir in xdgDataDirs.split(':'):
    if dir.len > 0 and dir.isAbsolute:
      dirs.add(normalizedPath(dir) / "applications")

  dirs.add("/var/lib/flatpak/exports/share/applications")

  # Deduplicate while preserving order.
  var seen = initHashSet[string]()
  for d in dirs:
    if d.len == 0 or d in seen: continue
    seen.incl(d)
    result.add(d)

iterator walkDirDepth*(dir: string; maxDepth: int; yieldFilter: set[PathComponent] = {pcFile, pcDir}): string =
  ## Recursively walk a directory up to maxDepth.
  ## maxDepth = 0 means only the files in `dir` itself.
  if dirExists(dir):
    var stack = @[(dir, 0)]
    var seen = initHashSet[string]()
    try:
      seen.incl(expandFilename(dir))
    except CatchableError:
      discard

    while stack.len > 0:
      let (currentDir, depth) = stack.pop()
      for kind, path in walkDir(currentDir, relative = false):
        # We also want to yield symlinks to files if the user wants files
        let isFileLink = kind == pcLinkToFile and pcFile in yieldFilter
        if kind in yieldFilter or isFileLink:
          yield path
        
        if depth < maxDepth and (kind == pcDir or kind == pcLinkToDir):
          var realPath = path
          try:
            realPath = expandFilename(path)
          except CatchableError:
            continue
            
          if not seen.contains(realPath):
            seen.incl(realPath)
            stack.add((path, depth + 1))
