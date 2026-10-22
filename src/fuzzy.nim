## fuzzy.nim — tiered fuzzy matching with highlight spans, plus usage boosts.
##
## Scores are `NoMatch` or `TierBase[tier] + adjustment`. Tier bases are
## `TierGap` (1500) apart and in-tier adjustments are clamped to ±`TierSpread`
## (300), so tiers never overlap. `recentBoost` (≤ 200) plus `usageBoost`
## (≤ 920) can reorder results inside a tier and only occasionally lift a hit
## into the tier directly above it.
##
##   exact 10000 > prefix 8500 > word-boundary substring 7000 >
##   substring 5500 > acronym 4000 > subsequence 2500 > typo 1000
##
## Queries must already be lowercased (`unicode.toLower`). Matching never
## allocates: ASCII input is compared bytewise, other input is decoded into
## fixed stack buffers (texts beyond `MaxTextRunes` runes are matched on their
## first `MaxTextRunes` runes; queries beyond `MaxQueryRunes` never match).

import std/[times, tables, unicode]
import ./state

proc recentBoost*(key: string): int =
  ## Small score bonus for recently used apps (first is strongest).
  let idx = ctx.recentApps.find(key)
  if idx >= 0: return max(0, 200 - idx * 40)
  0

proc usageBoost*(key: string): int =
  ## Small persistent score layer based on launch frequency and recency.
  let stats = ctx.appUsage.getOrDefault(key)
  if stats.launchCount <= 0 and stats.lastLaunched <= 0:
    return 0
  let frequency = min(stats.launchCount, 20) * 30
  let ageSeconds = max(0'i64, epochTime().int64 - stats.lastLaunched)
  let recency =
    if ageSeconds < 3_600: 320
    elif ageSeconds < 86_400: 220
    elif ageSeconds < 604_800: 120
    elif ageSeconds < 2_592_000: 40
    else: 0
  frequency + recency


# ── Matcher ─────────────────────────────────────────────────────────────

type
  MatchTier* = enum
    ## Ordered from weakest to strongest.
    mtNone, mtTypo, mtSubsequence, mtAcronym, mtSubstring, mtBoundary,
      mtPrefix, mtExact

const
  NoMatch* = -1_000_000
  TierSpread* = 300 ## in-tier adjustments stay within ±TierSpread
  TierBase*: array[MatchTier, int] =
    [NoMatch, 1000, 2500, 4000, 5500, 7000, 8500, 10000]
  MaxTextRunes = 256
  MaxQueryRunes = 64
  MaxAdjust = TierSpread - 50

type
  AsciiQuery = object
    s: cstring
    n: int

  ## Byte view of an ASCII text; `low` is nil when no lowercase copy is usable.
  AsciiText = object
    orig, low: cstring
    n: int

  RuneQuery = object
    n: int
    ch: array[MaxQueryRunes, int32]

  ## Decoded text: lowercased runes, word-start flags and byte offsets.
  RuneText = object
    n: int
    ch: array[MaxTextRunes, int32]
    start: array[MaxTextRunes, bool]
    off: array[MaxTextRunes + 1, int32]

func matchTier*(score: int): MatchTier =
  ## Recover the tier a score from the matcher belongs to.
  result = mtNone
  for tier in countdown(mtExact, mtTypo):
    if score >= TierBase[tier] - TierSpread:
      return tier

func isAscii(s: string): bool =
  for c in s:
    if c >= '\x80':
      return false
  true

func isSeparator(c: int32): bool {.inline.} =
  c == int32(' ') or c == int32('-') or c == int32('_') or c == int32('.') or
    c == int32('/') or c == int32('(')

func lowerAscii(c: char): int32 {.inline.} =
  if c in 'A'..'Z': int32(ord(c) + 32) else: int32(ord(c))

# Query / text accessors shared by the ASCII and rune implementations.
func len(q: AsciiQuery): int {.inline.} = q.n
func at(q: AsciiQuery; i: int): int32 {.inline.} = int32(ord(q.s[i]))
func len(q: RuneQuery): int {.inline.} = q.n
func at(q: RuneQuery; i: int): int32 {.inline.} = q.ch[i]
func len(t: AsciiText): int {.inline.} = t.n
func len(t: RuneText): int {.inline.} = t.n

func at(t: AsciiText; i: int): int32 {.inline.} =
  if t.low != nil: int32(ord(t.low[i])) else: lowerAscii(t.orig[i])

func at(t: RuneText; i: int): int32 {.inline.} = t.ch[i]

func isStart(t: AsciiText; i: int): bool {.inline.} =
  ## Word start: text start, after a separator, or a lower→Upper transition.
  if i == 0:
    true
  else:
    let prev = t.orig[i - 1]
    let cur = t.orig[i]
    isSeparator(int32(ord(prev))) or
      ((prev in 'a'..'z' or prev in '0'..'9') and cur in 'A'..'Z')

func isStart(t: RuneText; i: int): bool {.inline.} = t.start[i]

## Byte offset of character `i` (`i == len` gives the end of the text).
func byteAt(t: AsciiText; i: int): int {.inline.} = i
func byteAt(t: RuneText; i: int): int {.inline.} = int(t.off[i])

func lowerRune(r: Rune): int32 {.inline.} =
  if int32(r) < 128: lowerAscii(char(int32(r))) else: int32(unicode.toLower(r))

proc decodeText(t: var RuneText; s: string) =
  var i = 0
  var n = 0
  var prevLowerOrDigit = false
  var prevSeparator = true
  while i < s.len and n < MaxTextRunes:
    var r: Rune
    t.off[n] = int32(i)
    fastRuneAt(s, i, r, true)
    let lowered = lowerRune(r)
    t.ch[n] = lowered
    t.start[n] = prevSeparator or (prevLowerOrDigit and unicode.isUpper(r))
    prevSeparator = isSeparator(lowered)
    prevLowerOrDigit = unicode.isLower(r) or
      (int32(r) >= int32('0') and int32(r) <= int32('9'))
    inc n
  t.n = n
  t.off[n] = int32(i)

proc decodeQuery(q: var RuneQuery; s: string): bool =
  var i = 0
  var n = 0
  while i < s.len:
    if n == MaxQueryRunes:
      return false
    var r: Rune
    fastRuneAt(s, i, r, true)
    q.ch[n] = lowerRune(r)
    inc n
  q.n = n
  true

func lenBonus(n, m: int): int {.inline.} = max(0, 60 - (m - n))

func tierScore(tier: MatchTier; adjust: int): int {.inline.} =
  TierBase[tier] + clamp(adjust, -MaxAdjust, MaxAdjust)

proc addSpan(spans: var seq[(int, int)]; a, b: int) =
  ## Append the byte range [a, b), merging it into an adjacent last span.
  if b > a:
    if spans.len > 0 and spans[^1][0] + spans[^1][1] == a:
      spans[^1][1] += b - a
    else:
      spans.add (a, b - a)

func equalsAt[Q, T](q: Q; t: T; s: int): bool {.inline.} =
  ## True when the whole query matches the text starting at character `s`.
  for k in 0 ..< q.len:
    if t.at(s + k) != q.at(k):
      return false
  true

func withinOneEdit[Q, T](q: Q; t: T; s, size: int): bool =
  ## One insertion, deletion or substitution between the query and t[s ..< s+size].
  let a = q.len
  if abs(a - size) > 1:
    return false
  var i = 0
  var j = 0
  var edits = 0
  while i < a and j < size:
    if q.at(i) == t.at(s + j):
      inc i
      inc j
    else:
      inc edits
      if edits > 1:
        return false
      if a == size:
        inc i
        inc j
      elif a < size:
        inc j
      else:
        inc i
  edits += (a - i) + (size - j)
  edits <= 1

func withinOneTransposition[Q, T](q: Q; t: T; s, size: int): bool =
  ## One adjacent swap between the query and t[s ..< s+size].
  let a = q.len
  if a != size or a < 2:
    return false
  var k = 0
  while k < a and q.at(k) == t.at(s + k):
    inc k
  if k >= a - 1 or q.at(k) != t.at(s + k + 1) or q.at(k + 1) != t.at(s + k):
    return false
  for i in k + 2 ..< a:
    if q.at(i) != t.at(s + i):
      return false
  true

proc matchCore[Q, T](q: Q; t: T; minTier: MatchTier; record: bool;
    spans: var seq[(int, int)]): int =
  let n = q.len
  let m = t.len
  if n == 0 or n > m + 1:
    return NoMatch

  ## Exact, prefix, boundary substring and plain substring.
  if n <= m:
    var first = -1
    var boundary = -1
    let lead = q.at(0)
    var s = 0
    while s <= m - n and boundary < 0:
      if t.at(s) == lead and equalsAt(q, t, s):
        if first < 0:
          first = s
        if t.isStart(s):
          boundary = s
      inc s
    if first >= 0:
      var tier = mtSubstring
      var pos = first
      if first == 0:
        tier = if n == m: mtExact else: mtPrefix
      elif boundary >= 0:
        tier = mtBoundary
        pos = boundary
      if tier < minTier:
        return NoMatch
      if record:
        spans.addSpan t.byteAt(pos), t.byteAt(pos + n)
      return tierScore(tier, lenBonus(n, m) - min(60, pos))

  ## Acronym: query characters land on word starts, in order.
  if n >= 2 and minTier <= mtAcronym:
    var qi = 0
    var starts = 0
    var i = 0
    while i < m and qi < n:
      if t.isStart(i):
        inc starts
        if t.at(i) == q.at(qi):
          if record:
            spans.addSpan t.byteAt(i), t.byteAt(i + 1)
          inc qi
      inc i
    if qi == n:
      return tierScore(mtAcronym, lenBonus(n, m) - (starts - n) * 40)
    spans.setLen(0)

  ## Subsequence: forward pass finds the end, a backward pass the tightest
  ## start, and a final forward pass from there scores and records the match.
  if n >= 2 and minTier <= mtSubsequence:
    var qi = 0
    var last = -1
    var i = 0
    while i < m and qi < n:
      if t.at(i) == q.at(qi):
        inc qi
        last = i
      inc i
    if qi == n:
      var first = last
      qi = n - 1
      i = last
      while i >= 0 and qi >= 0:
        if t.at(i) == q.at(qi):
          first = i
          dec qi
        dec i
      var consecutive = 0
      var boundaryHits = 0
      var gaps = 0
      var previous = -2
      qi = 0
      i = first
      while qi < n:
        if t.at(i) == q.at(qi):
          if i == previous + 1:
            inc consecutive
          elif previous >= 0:
            gaps += i - previous - 1
          if t.isStart(i):
            inc boundaryHits
          if record:
            spans.addSpan t.byteAt(i), t.byteAt(i + 1)
          previous = i
          inc qi
        inc i
      return tierScore(mtSubsequence, 15 * consecutive + 20 * boundaryHits -
        min(150, gaps * 4) - min(50, first) + lenBonus(n, m))

  ## Typo: one edit or adjacent swap against a text window of similar length.
  if n >= 3 and minTier <= mtTypo:
    for s in 0 ..< m:
      for size in [n, n - 1, n + 1]:
        if s + size <= m and (withinOneEdit(q, t, s, size) or
            withinOneTransposition(q, t, s, size)):
          if record:
            spans.addSpan t.byteAt(s), t.byteAt(s + size)
          return tierScore(mtTypo, lenBonus(n, m) +
            (if s == 0: 100 else: max(0, 80 - s * 8)))
  NoMatch

proc matchAny(queryLower, text, textLower: string; minTier: MatchTier;
    record: bool; spans: var seq[(int, int)]): int =
  if record:
    spans.setLen(0)
  if queryLower.len == 0 or text.len == 0:
    return NoMatch
  if isAscii(queryLower) and isAscii(text):
    let usable = textLower.len == text.len
    let t = AsciiText(orig: text.cstring,
        low: if usable: textLower.cstring else: nil, n: text.len)
    matchCore(AsciiQuery(s: queryLower.cstring, n: queryLower.len), t,
        minTier, record, spans)
  else:
    var q {.noinit.}: RuneQuery
    if not decodeQuery(q, queryLower):
      return NoMatch
    var t {.noinit.}: RuneText
    decodeText(t, text)
    matchCore(q, t, minTier, record, spans)

proc fuzzyMatch*(queryLower, text, textLower: string;
    spans: var seq[(int, int)]; minTier = mtTypo): int =
  ## Score `text` against the lowercased query and fill `spans` with the
  ## matched (byte offset, byte length) ranges of `text`, always on UTF-8
  ## boundaries. Returns `NoMatch` (spans empty) for no match or a match below
  ## `minTier`. `textLower` is an optional lowercase copy of `text` (pass "" if
  ## unavailable); it only speeds up ASCII texts.
  matchAny(queryLower, text, textLower, minTier, true, spans)

proc fuzzyScore*(queryLower, text, textLower: string;
    minTier = mtTypo): int =
  ## Like `fuzzyMatch` without recording spans.
  var none: seq[(int, int)]
  matchAny(queryLower, text, textLower, minTier, false, none)
