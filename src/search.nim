## search.nim — file search helpers and shared constants.

import std/[os, strutils, osproc, streams, tables, unicode, syncio, atomics]
import sdl3
import ./paths

const
  SearchDebounceMs* = 240 # debounce for s: while typing (unified)
  SearchFdCap* = 800      # cap external search results from fd/locate
  SearchCacheMax* = 6     # keep a small cache of recent queries

static:
  doAssert SearchCacheMax > 0

var
  lastSearchBuildMs* = 0'i64            ## idle-loop guard to rebuild after debounce
  lastSearchQuery* = ""                 ## cache key for s: queries
  lastSearchResults*: seq[string] = @[] ## cached paths for narrowing queries
  searchCache*: OrderedTable[string, seq[string]] = initOrderedTable[string,
      seq[string]]()

type
  SearchRequest = object
    generation: int
    query: string

  SearchResponse* = object
    generation*: int
    query*: string
    paths*: seq[string]

var
  searchRequestChannel: Channel[SearchRequest]
  searchResponseChannel: Channel[SearchResponse]
  searchThread: Thread[void]
  searchThreadStarted = false
  nextSearchGeneration = 0
  latestRequestedGeneration: Atomic[int]
  searchStopping: Atomic[bool]

proc cacheSearchResults*(query: string; results: seq[string]) =
  if query.len == 0:
    return
  if searchCache.hasKey(query):
    searchCache.del(query)
  searchCache[query] = results
  if searchCache.len > SearchCacheMax:
    var oldestKey = ""
    for key in searchCache.keys:
      oldestKey = key
      break
    if oldestKey.len > 0:
      searchCache.del(oldestKey)

proc getCachedSearchResults*(query: string; results: var seq[string]): bool =
  if searchCache.hasKey(query):
    results = searchCache[query]
    return true
  false

proc shortenPath*(p: string; maxLen = 80): string =
  ## Replace $HOME with ~, and ellipsize the middle if too long.
  var s = p
  let home = homeDirNoSlash()
  if home.len > 0 and s.startsWith(home & "/"): s = "~" & s[home.len .. ^1]
  if s.runeLen <= maxLen: return s
  let keep = maxLen div 2 - 2
  if keep <= 0: return s
  result = s.runeSubStr(0, keep) & "…" &
      s.runeSubStr(s.runeLen - keep, keep)

## Return true when a worker result is obsolete or shutdown has started.
proc searchCancelled(generation: int): bool =
  generation > 0 and (searchStopping.load() or
      latestRequestedGeneration.load() > generation)

## Run an external finder, appending existing files to `results` (capped at SearchFdCap).
## Returns true when the search is finished: the finder succeeded or was cancelled
## (`results` keeps whatever was collected). On failure it warns, clears `results`
## and returns false so the caller can try the next strategy.
proc runFinder(exe: string; args: seq[string]; label: string; generation: int;
    results: var seq[string]): bool =
  let p = startProcess(exe, args = args, options = {poUsePath, poStdErrToStdOut})
  defer: close(p)
  var line = ""
  var diagnostics: seq[string] = @[]
  while p.outputStream.readLine(line):
    if searchCancelled(generation):
      return true
    if line.len > 0 and results.len < SearchFdCap and fileExists(line):
      results.add(line)
    elif line.len > 0 and diagnostics.len < 8:
      diagnostics.add(line)
  if p.waitForExit() == 0:
    return true
  for message in diagnostics:
    stderr.writeLine label & " warning: " & message
  results.setLen(0)

## Search for files with cooperative cancellation for the fallback walk.
proc scanFilesFastInternal(query: string; generation: int): seq[string] =
  ## Fast file search in order:
  ##  1) `fd` (fast, respects .gitignore)
  ##  2) `locate -i` (DB backed, may be stale)
  ##  3) bounded walk under $HOME (slowest)
  let home = getHomeDir()
  let limit = SearchFdCap

  try:
    ## --- Prefer `fd` ----------------------------------------------------
    let fdExe = findExe("fd")
    if fdExe.len > 0:
      let args = @[
        "-i", "--type", "f", "--absolute-path",
        "--color", "never",
        "--max-results", $limit,
        "--fixed-strings",
        "--", query, home
      ]
      if runFinder(fdExe, args, "fd", generation, result):
        return

    ## --- Fallback: `locate -i` -----------------------------------------
    let locExe = findExe("locate")
    if locExe.len > 0:
      let args = @["-i", "-l", $limit, "--", query]
      if runFinder(locExe, args, "locate", generation, result):
        return

    ## --- Final fallback: bounded walk under $HOME -----------------------
    let ql = query.toLowerAscii
    var count = 0
    for path in walkDirDepth(home, maxDepth = 3, yieldFilter = {pcFile}):
      if searchCancelled(generation):
        return
      if "/." in path: continue
      if path.toLowerAscii.contains(ql):
        result.add(path)
        inc count
        if count >= limit: break

  except CatchableError as e:
    stderr.writeLine "scanFilesFast warning: " & $e.name & ": " & e.msg

## Process file searches away from the SDL event loop.
proc searchWorker() {.thread.} =
  while true:
    let request = searchRequestChannel.recv()
    if request.generation < 0:
      break
    searchResponseChannel.send(SearchResponse(
      generation: request.generation,
      query: request.query,
      paths: scanFilesFastInternal(request.query, request.generation)))
    ## Wake the SDL event loop so it polls the response promptly.
    var evt = Event(`type`: EVENT_USER)
    discard pushEvent(evt)

## Start the background file-search worker once.
proc startSearchWorker*() =
  if searchThreadStarted:
    return
  searchRequestChannel.open(1)
  searchResponseChannel.open()
  searchStopping.store(false)
  createThread(searchThread, searchWorker)
  searchThreadStarted = true

## Stop and join the background file-search worker.
proc stopSearchWorker*() =
  if not searchThreadStarted:
    return
  searchStopping.store(true)
  discard searchRequestChannel.tryRecv()
  searchRequestChannel.send(SearchRequest(generation: -1))
  joinThread(searchThread)
  searchRequestChannel.close()
  searchResponseChannel.close()
  searchThreadStarted = false
  searchStopping.store(false)

## Queue a search if the single pending slot is available.
proc requestFileSearch*(query: string): int =
  if not searchThreadStarted:
    startSearchWorker()
  inc nextSearchGeneration
  latestRequestedGeneration.store(nextSearchGeneration)
  let request = SearchRequest(generation: nextSearchGeneration, query: query)
  if searchRequestChannel.trySend(request):
    return request.generation
  0

## Receive one completed file search without blocking.
proc pollFileSearch*(response: var SearchResponse): bool =
  if not searchThreadStarted:
    return false
  let received = searchResponseChannel.tryRecv()
  if not received.dataAvailable:
    return false
  response = received.msg
  true
