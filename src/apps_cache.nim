## apps_cache.nim — application discovery and cache management.

import std/[os, json, times, options, strutils, algorithm, hashes, sets, syncio]
import ./[state, parser, paths]

const CacheFormatVersion = 13

## Derive the desktop-file ID relative to its applications directory.
proc desktopFileId(baseDir, path: string): string =
  let relative = relativePath(path, baseDir)
  relative.replace(DirSep, '-').replace(AltSep, '-')

## Capture locale and executable search inputs used by desktop parsing.
proc parsingEnvironmentSignature(): string =
  [getEnv("LC_ALL"), getEnv("LC_MESSAGES"), getEnv("LANG"), getEnv("PATH")].join("\x1f")

## Describe how one TryExec value resolves on PATH, including the mtime.
proc tryExecResolution(value: string): string =
  let resolved = findExe(value)
  if resolved.len == 0:
    return value & ":missing"
  var modified = 0'i64
  try:
    modified = getLastModificationTime(resolved).toUnix()
  except OSError:
    discard
  value & ":" & resolved & ":" & $modified

## Summarize how every cached TryExec value resolves, without reading any
## .desktop file. Installing or removing a program changes the result.
proc tryExecSignature(tryExecs: seq[string]): string =
  var resolutions: seq[string] = @[]
  for value in tryExecs:
    resolutions.add tryExecResolution(value)
  $hash(resolutions)

proc desktopDirFingerprint(dir: string): string =
  ## Build a lightweight fingerprint for *.desktop files under *dir*.
  ## Includes newest mtime, file count, summed mtimes, summed file sizes, and
  ## a path hash. Only directory walking and stat calls are used.
  if not dirExists(dir):
    return "0:0:0:0"
  var newest = 0'i64
  var count = 0'i64
  var sumMtime = 0'i64
  var sumSize = 0'i64
  var paths: seq[string] = @[]
  for entry in walkDirDepth(dir, maxDepth = 3, yieldFilter = {pcFile}):
    if entry.endsWith(".desktop"):
      paths.add(entry)
      try:
        let info = getFileInfo(entry)
        let m = times.toUnix(info.lastWriteTime)
        if m > newest: newest = m
        inc count
        sumMtime += m
        sumSize += info.size.int64
      except CatchableError:
        discard
  paths.sort()
  $count & ":" & $newest & ":" & $sumMtime & ":" & $sumSize &
      ":" & $hash(paths)

proc loadApplications*() =
  ## Scan .desktop files with caching to ~/.cache/nimlaunch/apps.json.
  let appDirs = applicationDirs()
  let environmentSignature = parsingEnvironmentSignature()
  var dirSignatures: seq[string] = @[]
  for dir in appDirs:
    dirSignatures.add desktopDirFingerprint(dir)

  let cacheBase = cacheDir()
  let cacheFile = cacheBase / "apps.json"

  if fileExists(cacheFile):
    try:
      let node = parseJson(readFile(cacheFile))
      if node.kind == JObject and node.hasKey("formatVersion"):
        ## Check the version before decoding: older caches lack newer fields.
        if node["formatVersion"].getInt() == CacheFormatVersion:
          let c = to(node, CacheData)
          if c.environmentSignature == environmentSignature and
             c.appDirs == appDirs and c.dirSignatures == dirSignatures and
             c.tryExecSignature == tryExecSignature(c.tryExecs):
            ctx.allApps = c.apps
            return
      else:
        if ctx.verboseMode:
          stderr.writeLine "Cache invalid — rescanning …"
    except IOError, ValueError, OSError:
        let e = getCurrentException()
        if ctx.verboseMode:
          stderr.writeLine "Cache miss — rescanning (" & $e.name & ": " & e.msg & ")"

  var claimedIds = initHashSet[string]()
  var apps: seq[DesktopApp] = @[]
  var tryExecSet = initHashSet[string]()
  for dir in appDirs:
    if not dirExists(dir): continue
    for path in walkDirDepth(dir, maxDepth = 3, yieldFilter = {pcFile}):
      if not path.endsWith(".desktop"): continue
      let desktopId = desktopFileId(dir, path)
      if desktopId in claimedIds:
        continue
      claimedIds.incl(desktopId)
      var tryExec = ""
      let opt = parseDesktopFile(path, tryExec)
      if tryExec.len > 0:
        tryExecSet.incl(tryExec)
      if isSome(opt):
        var app = get(opt)
        app.desktopId = desktopId
        apps.add app

  ctx.allApps = apps
  ctx.allApps.sort(proc(a, b: DesktopApp): int = cmpIgnoreCase(a.name, b.name))
  var tryExecs: seq[string] = @[]
  for value in tryExecSet:
    tryExecs.add value
  tryExecs.sort()
  try:
    createDir(cacheBase)
    writeFile(cacheFile, $ %CacheData(formatVersion: CacheFormatVersion,
                                      environmentSignature: environmentSignature,
                                      appDirs: appDirs,
                                      dirSignatures: dirSignatures,
                                      tryExecs: tryExecs,
                                      tryExecSignature: tryExecSignature(tryExecs),
                                      apps: ctx.allApps))
  except IOError, OSError:
    let e = getCurrentException()
    if ctx.verboseMode:
      stderr.writeLine "Warning: cache not saved (" & $e.name & ": " & e.msg & ")"
