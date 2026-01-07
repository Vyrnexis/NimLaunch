## fuzzy.nim — fuzzy matching, typo tolerance, and highlight helpers.

import std/strutils
import ./state

proc recentBoost*(name: string): int =
  ## Small score bonus for recently used apps (first is strongest).
  let idx = recentApps.find(name)
  if idx >= 0: return max(0, 200 - idx * 40)
  0

proc subseqPositions*(q, t: string): seq[int] =
  ## Case-insensitive subsequence positions of q within t (for highlight).
  if q.len == 0: return @[]
  let lq = q.toLowerAscii
  let lt = t.toLowerAscii
  var qi = 0
  for i in 0 ..< lt.len:
    if qi < lq.len and lt[i] == lq[qi]:
      result.add i
      inc qi
      if qi == lq.len: return
  result.setLen(0)

proc subseqSpans*(q, t: string): seq[(int, int)] =
  ## Convert positions to 1-char spans for highlighting.
  for p in subseqPositions(q, t): result.add (p, 1)

proc isWordBoundary*(lt: string; idx: int): bool =
  ## Basic token boundary check for nicer scoring.
  if idx <= 0: return true
  let c = lt[idx-1]
  c == ' ' or c == '-' or c == '_' or c == '.' or c == '/'

proc scoreMatch*(q, t, fullPath, home: string): int =
  ## Heuristic score for matching q against t (higher is better).
  ## Typo-friendly: 1 edit (ins/del/sub) or one adjacent transposition.
  if q.len == 0: return -1_000_000
  let lq = q.toLowerAscii
  let lt = t.toLowerAscii
  let pos = lt.find(lq)

  ## fast helpers (no alloc)
  proc withinOneEdit(a, b: string): bool =
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

  proc withinOneTransposition(a, b: string): bool =
    if a.len != b.len or a.len < 2: return false
    var k = 0
    while k < a.len and a[k] == b[k]: inc k
    if k >= a.len - 1: return false
    if not (a[k] == b[k+1] and a[k+1] == b[k]): return false
    let tailStart = k + 2
    result = if tailStart < a.len:
      a[tailStart .. ^1] == b[tailStart .. ^1]
    else:
      true

  var s = -1_000_000
  if pos >= 0:
    s = 1000
    if pos == 0: s += 200
    if isWordBoundary(lt, pos): s += 80
    s += max(0, 60 - (t.len - q.len))

  if t == q: s += 9000
  elif lt == lq: s += 8600
  elif lt.startsWith(lq): s += 8200
  elif pos >= 0: s += 7800
  else:
    var typoHit = false

    ## Whole-string typo tolerance (1 edit or adjacent swap).
    if lq.len > 0 and (withinOneEdit(lq, lt) or withinOneTransposition(lq, lt)):
      typoHit = true
      s = max(s, 7600)

    ## Substring typo tolerance to catch near-start matches.
    if not typoHit and lq.len > 0:
      let sizes = [max(1, lq.len - 1), lq.len, lq.len + 1]
      for L in sizes:
        if L > lt.len: continue
        var start = 0
        let maxStart = lt.len - L
        while start <= maxStart:
          let seg = lt[start ..< start + L]
          if withinOneEdit(lq, seg) or withinOneTransposition(lq, seg):
            typoHit = true
            var base = 7700
            if start == 0: base = 7950
            s = max(s, base - min(120, start))
            break
          inc start
        if typoHit: break

  if fullPath.startsWith(home & "/"):
    if lt == lq: s += 600
    elif lt.startsWith(lq): s += 400
  s
