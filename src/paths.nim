## paths.nim — shared helpers for config/cache and application search paths.

import std/[os, strutils, sets]

const
  AppName = "nimlaunch"
  DefaultXdgDataDirs = "/usr/local/share:/usr/share"
  DefaultXdgConfigHome = ".config"
  DefaultXdgCacheHome = ".cache"

proc userConfigHome*(): string =
  ## Return XDG config home (respects $XDG_CONFIG_HOME).
  let fromEnv = getEnv("XDG_CONFIG_HOME")
  if fromEnv.len > 0:
    return fromEnv.strip(chars = {DirSep, AltSep}, leading = false,
        trailing = true)
  getHomeDir() / DefaultXdgConfigHome

proc userCacheHome*(): string =
  ## Return XDG cache home (respects $XDG_CACHE_HOME).
  let fromEnv = getEnv("XDG_CACHE_HOME")
  if fromEnv.len > 0:
    return fromEnv.strip(chars = {DirSep, AltSep}, leading = false,
        trailing = true)
  getHomeDir() / DefaultXdgCacheHome

proc configDir*(): string =
  ## Return the base config directory for NimLaunch (~/.config/nimlaunch).
  userConfigHome() / AppName

proc cacheDir*(): string =
  ## Return the base cache directory for NimLaunch (~/.cache/nimlaunch).
  userCacheHome() / AppName

proc iconCacheDir*(size: int): string =
  ## Return the cache dir for rasterized icons at a given size.
  cacheDir() / "icons" / $size

proc applicationDirs*(): seq[string] =
  ## Return the list of application directories to scan.
  ## Order: user-local, user flatpak, system (XDG), system flatpak.
  var dirs: seq[string] = @[
    getHomeDir() / ".local/share/applications",
    getHomeDir() / ".local/share/flatpak/exports/share/applications"
  ]

  let xdgDataDirs = getEnv("XDG_DATA_DIRS", DefaultXdgDataDirs)
  for dir in xdgDataDirs.split(':'):
    if dir.len == 0: continue
    let cleaned = dir.strip(chars = {DirSep, AltSep}, leading = false,
        trailing = true)
    dirs.add(cleaned / "applications")

  dirs.add("/var/lib/flatpak/exports/share/applications")

  # Deduplicate while preserving order.
  var seen = initHashSet[string]()
  for d in dirs:
    if d.len == 0 or d in seen: continue
    seen.incl(d)
    result.add(d)
