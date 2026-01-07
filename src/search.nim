## search.nim — file search helpers and shared constants.

import std/[os, strutils, osproc, streams]

const
  SearchDebounceMs* = 240   # debounce for s: while typing (unified)
  SearchFdCap*      = 800   # cap external search results from fd/locate
  SearchShowCap*    = 250   # cap items we score per rebuild

var
  lastSearchBuildMs* = 0'i64   ## idle-loop guard to rebuild after debounce
  lastSearchQuery* = ""        ## cache key for s: queries
  lastSearchResults*: seq[string] = @[] ## cached paths for narrowing queries

proc shortenPath*(p: string; maxLen = 80): string =
  ## Replace $HOME with ~, and ellipsize the middle if too long.
  var s = p
  let home = getHomeDir()
  if s.startsWith(home & "/"): s = "~" & s[home.len .. ^1]
  if s.len <= maxLen: return s
  let keep = maxLen div 2 - 2
  if keep <= 0: return s
  result = s[0 ..< keep] & "…" & s[s.len - keep .. ^1]

proc scanFilesFast*(query: string): seq[string] =
  ## Fast file search in order:
  ##  1) `fd` (fast, respects .gitignore)
  ##  2) `locate -i` (DB backed, may be stale)
  ##  3) bounded walk under $HOME (slowest)
  let home  = getHomeDir()
  let ql    = query.toLowerAscii
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
        query, home
      ]
      let p = startProcess(fdExe, args = args, options = {poUsePath, poStdErrToStdOut})
      defer: close(p)
      let output = p.outputStream.readAll()
      for line in output.splitLines():
        if line.len > 0: result.add(line)
      return

    ## --- Fallback: `locate -i` -----------------------------------------
    let locExe = findExe("locate")
    if locExe.len > 0:
      let p = startProcess(locExe, args = @["-i", "-l", $limit, query],
                           options = {poUsePath, poStdErrToStdOut})
      defer: close(p)
      let output = p.outputStream.readAll()
      for line in output.splitLines():
        if line.len > 0: result.add(line)
      return

    ## --- Final fallback: bounded walk under $HOME -----------------------
    var count = 0
    for path in walkDirRec(home, yieldFilter = {pcFile}):
      if path.toLowerAscii.contains(ql):
        result.add(path)
        inc count
        if count >= limit: break

  except CatchableError as e:
    echo "scanFilesFast warning: ", e.name, ": ", e.msg
