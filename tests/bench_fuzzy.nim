## Micro-benchmark: old scoreMatch vs the new matcher on synthetic app names.
## Not part of `nimble test`. Run:
##   nim c -d:release -r --nimcache:./bin/nimcache-bench -o:./bin/bench_fuzzy tests/bench_fuzzy.nim
import std/[monotimes, times, strutils, unicode]
import ../src/fuzzy

# ── Previous implementation (copied verbatim, renamed) ─────────────────

proc oldIsWordBoundary(lt: string; idx: int): bool =
  if idx <= 0: return true
  var previous = idx - 1
  while previous > 0 and (ord(lt[previous]) and 0xC0) == 0x80:
    dec previous
  let rune = runeAt(lt, previous)
  rune in [Rune(' '), Rune('-'), Rune('_'), Rune('.'), Rune('/')]

proc oldWithinOneEdit(a, b: openArray[Rune]): bool =
  let m = a.len; let n = b.len
  if abs(m - n) > 1: return false
  var i = 0; var j = 0; var edits = 0
  while i < m and j < n:
    if a[i] == b[j]: inc i; inc j
    else:
      inc edits; if edits > 1: return false
      if m == n: inc i; inc j
      elif m < n: inc j
      else: inc i
  edits += (m - i) + (n - j)
  edits <= 1

proc oldWithinOneTransposition(a, b: openArray[Rune]): bool =
  if a.len != b.len or a.len < 2: return false
  var k = 0
  while k < a.len and a[k] == b[k]: inc k
  if k >= a.len - 1: return false
  if not (a[k] == b[k+1] and a[k+1] == b[k]): return false
  let tailStart = k + 2
  if tailStart < a.len:
    for i in tailStart ..< a.len:
      if a[i] != b[i]: return false
  return true

proc oldScoreMatch(q, lq, t, lt, fullPath, home: string): int =
  if q.len == 0: return -1_000_000
  let normalizedQuery = unicode.toLower(q)
  let normalizedText = unicode.toLower(t)
  let queryRunes = normalizedQuery.toRunes()
  let textRunes = normalizedText.toRunes()
  let pos = normalizedText.find(normalizedQuery)

  var s = -1_000_000
  if pos >= 0:
    s = 1000
    if pos == 0: s += 200
    if oldIsWordBoundary(normalizedText, pos): s += 80
    s += max(0, 60 - (t.len - q.len))

  if t == q: s += 9000
  elif normalizedText == normalizedQuery: s += 8600
  elif normalizedText.startsWith(normalizedQuery): s += 8200
  elif pos >= 0: s += 7800
  else:
    var typoHit = false
    if queryRunes.len > 0 and
        (oldWithinOneEdit(queryRunes, textRunes) or
         oldWithinOneTransposition(queryRunes, textRunes)):
      typoHit = true
      s = max(s, 7600)
    if not typoHit and queryRunes.len > 0:
      let sizes = [max(1, queryRunes.len - 1), queryRunes.len,
          queryRunes.len + 1]
      for L in sizes:
        if L > textRunes.len: continue
        var start = 0
        let maxStart = textRunes.len - L
        while start <= maxStart:
          let candidate = textRunes[start..<start + L]
          if oldWithinOneEdit(queryRunes, candidate) or
              oldWithinOneTransposition(queryRunes, candidate):
            typoHit = true
            var base = 7700
            if start == 0: base = 7950
            s = max(s, base - min(120, start))
            break
          inc start
        if typoHit: break

  if home.len > 0 and fullPath.startsWith(home & "/"):
    if normalizedText == normalizedQuery: s += 600
    elif normalizedText.startsWith(normalizedQuery): s += 400
  s

# ── Synthetic data ─────────────────────────────────────────────────────

const Words = [
  "Firefox", "Visual", "Studio", "Code", "Terminal", "Files", "Text", "Editor",
  "Calculator", "Image", "Viewer", "Music", "Player", "Video", "Settings",
  "System", "Monitor", "Browser", "Web", "Chrome", "Google", "GIMP", "Manager",
  "Network", "Disk", "Utility", "Archive", "Document", "PDF", "Reader", "Mail",
  "Client", "Calendar", "Photo", "Shop", "Draw", "Paint", "Konsole", "Dolphin",
  "Nautilus", "Thunar", "Notes", "Todo", "Clock", "Weather", "Maps", "Camera",
  "Café", "Éditeur", "東京", "Steam", "Discord", "Slack", "Zoom", "Docker",
  "Postgres", "Admin", "Tool", "Launcher", "Security", "Update", "Backup"]

const Queries = [
  "fire", "vsc", "term", "ffx", "code", "brow", "gimp", "calc", "zzz",
  "fierfox", "studio", "ed", "konsole", "files", "music", "set", "x", "pdf",
  "ima", "text", "café", "tokyo"]

var seed = 12345'u32
proc nextRand(n: int): int =
  seed = seed * 1664525'u32 + 1013904223'u32
  int((seed shr 8) mod uint32(n))

proc makeNames(count: int): seq[string] =
  for _ in 0 ..< count:
    var name = Words[nextRand(Words.len)]
    for _ in 0 ..< nextRand(4):
      name.add (if nextRand(8) == 0: "-" else: " ")
      name.add Words[nextRand(Words.len)]
    result.add name

proc bench(label: string; names, lowers: seq[string]; useNew: bool): float =
  ## Returns nanoseconds per (query, candidate) pair.
  var checksum = 0
  var best = high(int64)
  for _ in 0 ..< 5:
    let start = getMonoTime()
    for q in Queries:
      let ql = unicode.toLower(q)
      for i in 0 ..< names.len:
        checksum += (if useNew: fuzzyScore(ql, names[i], lowers[i])
                     else: oldScoreMatch(q, ql, names[i], lowers[i], names[i], ""))
    best = min(best, (getMonoTime() - start).inNanoseconds)
  let pairs = Queries.len * names.len
  result = best.float / pairs.float
  echo label, ": ", result.formatFloat(ffDecimal, 1), " ns/candidate (checksum ",
      checksum, ")"

let names = makeNames(5000)
var lowers: seq[string] = @[]
for n in names: lowers.add unicode.toLower(n)
var asciiNames: seq[string] = @[]
var asciiLowers: seq[string] = @[]
for i, n in names:
  if n.len == n.runeLen:
    asciiNames.add n
    asciiLowers.add lowers[i]
echo names.len, " names (", asciiNames.len, " ASCII), ", Queries.len, " queries"
let oldAll = bench("old  all  ", names, lowers, false)
let newAll = bench("new  all  ", names, lowers, true)
let oldAscii = bench("old  ascii", asciiNames, asciiLowers, false)
let newAscii = bench("new  ascii", asciiNames, asciiLowers, true)
echo "speed-up all: ", (oldAll / newAll).formatFloat(ffDecimal, 1), "x, ascii: ",
    (oldAscii / newAscii).formatFloat(ffDecimal, 1), "x"
