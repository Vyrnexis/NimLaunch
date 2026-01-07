## apps_cache.nim — application discovery and cache management.

import std/[os, json, tables, sequtils, times, options, strutils, algorithm]
import ./[state, parser, paths]

const CacheFormatVersion = 4

proc newestDesktopMtime(dir: string): int64 =
  ## Return newest mtime among *.desktop files under *dir* (recursive).
  if not dirExists(dir): return 0
  var newest = 0'i64
  for entry in walkDirRec(dir, yieldFilter = {pcFile}):
    if entry.endsWith(".desktop"):
      let m = times.toUnix(getLastModificationTime(entry))
      if m > newest: newest = m
  newest

proc loadApplications*() =
  ## Scan .desktop files with caching to ~/.cache/nimlaunch/apps.json.
  let appDirs = applicationDirs()
  let dirMtimes = appDirs.map(newestDesktopMtime)

  let cacheBase = cacheDir()
  let cacheFile = cacheBase / "apps.json"

  if fileExists(cacheFile):
    try:
      let node = parseJson(readFile(cacheFile))
      if node.kind == JObject and node.hasKey("formatVersion"):
        let c = to(node, CacheData)
        if c.formatVersion == CacheFormatVersion and
           c.appDirs == appDirs and c.dirMtimes == dirMtimes:
          allApps = c.apps
          filteredApps = @[]
          matchSpans = @[]
          return
      else:
        echo "Cache invalid — rescanning …"
    except:
      echo "Cache miss — rescanning …"

  var dedup = initTable[string, DesktopApp]()
  for dir in appDirs:
    if not dirExists(dir): continue
    for path in walkDirRec(dir, yieldFilter = {pcFile}):
      if not path.endsWith(".desktop"): continue
      let opt = parseDesktopFile(path)
      if isSome(opt):
        let app = get(opt)
        let sanitizedExec = parser.stripFieldCodes(app.exec).strip()
        var key = sanitizedExec.toLowerAscii
        if key.len == 0:
          key = getBaseExec(app.exec).toLowerAscii
        if key.len == 0:
          key = app.name.toLowerAscii
        if not dedup.hasKey(key) or (app.hasIcon and not dedup[key].hasIcon):
          dedup[key] = app

  allApps = dedup.values.toSeq
  allApps.sort(proc(a, b: DesktopApp): int = cmpIgnoreCase(a.name, b.name))
  filteredApps = @[]
  matchSpans = @[]
  try:
    createDir(cacheBase)
    writeFile(cacheFile, pretty(%CacheData(formatVersion: CacheFormatVersion,
                                           appDirs: appDirs,
                                           dirMtimes: dirMtimes,
                                           apps: allApps)))
  except CatchableError:
    echo "Warning: cache not saved."
