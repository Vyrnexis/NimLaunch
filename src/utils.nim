## utils.nim — shared helper routines (SDL2 port)
## Derived from NimLaunch, with X11-specific colour allocation removed.
##
## Side effects:
##   • recent-application JSON persistence

import std/[os, strutils, json, options]
import ./[state, paths]

# ── Shell helpers ───────────────────────────────────────────────────────
## Quote a string for safe use inside a POSIX shell single-quoted context.
proc shellQuote*(s: string): string =
  result = "'"
  for ch in s:
    if ch == '\'':
      result.add("'\\''") # close ' … escape ' … reopen '
    else:
      result.add(ch)
  result.add("'")

proc normalizePrefix*(prefix: string): string =
  ## Canonicalise user-configured prefixes by trimming colons/whitespace and
  ## lowercasing so parsing is resilient to variants like ":g", "g:" or ":G:".
  prefix.strip(chars = Whitespace + {':'}).toLowerAscii

# ── Colour helpers ──────────────────────────────────────────────────────
proc parseHexRgb8*(hex: string): Option[Rgb] =
  ## Parse "#RRGGBB" into Rgb; return none on bad input.
  if hex.len != 7 or hex[0] != '#':
    return none(Rgb)
  try:
    let r = parseHexInt(hex[1..2])
    let g = parseHexInt(hex[3..4])
    let b = parseHexInt(hex[5..6])
    some(Rgb(r: uint8(r), g: uint8(g), b: uint8(b)))
  except:
    none(Rgb)

# ── Recent/MRU (applications) persistence ───────────────────────────────
let recentFile* = cacheDir() / "recent.json"

proc loadRecent*() =
  ## Populate state.recentApps from disk; log on error.
  if fileExists(recentFile):
    try:
      let j = parseJson(readFile(recentFile))
      state.recentApps = j.to(seq[string])
    except CatchableError as e:
      echo "loadRecent warning: ", recentFile, " (", e.name, "): ", e.msg

proc saveRecent*() =
  ## Persist state.recentApps to disk; log on error.
  try:
    createDir(recentFile.parentDir)
    writeFile(recentFile, pretty(%state.recentApps))
  except CatchableError as e:
    echo "saveRecent warning: ", recentFile, " (", e.name, "): ", e.msg
