import std/[unittest, unicode, strutils]
import ../src/fuzzy

proc match(query, text: string): (int, seq[(int, int)]) =
  ## Score `text` for the query using the same lowercasing as the callers.
  var spans: seq[(int, int)]
  let score = fuzzyMatch(unicode.toLower(query), text, unicode.toLower(text), spans)
  (score, spans)

proc score(query, text: string): int = match(query, text)[0]

proc tier(query, text: string): MatchTier = matchTier(score(query, text))

proc highlighted(text: string; spans: seq[(int, int)]): string =
  ## Concatenate the matched slices of `text`, validating each boundary.
  for (start, length) in spans:
    let piece = text[start ..< start + length]
    check validateUtf8(piece) == -1
    result.add piece

suite "Fuzzy tests":
  test "each tier is recognised":
    check tier("firefox", "Firefox") == mtExact
    check tier("fire", "Firefox") == mtPrefix
    check tier("studio", "Visual Studio Code") == mtBoundary
    check tier("code", "Barcode") == mtSubstring
    check tier("vsc", "Visual Studio Code") == mtAcronym
    check tier("ffx", "Firefox") == mtSubsequence
    check tier("fierfox", "Firefox") == mtTypo

  test "tiers order exact > prefix > boundary > substring > acronym > subsequence > typo":
    let scores = [
      score("abc", "abc"),
      score("abc", "abcdef"),
      score("abc", "xx abcdef"),
      score("abc", "xxabcdef"),
      score("abc", "Alpha Beta Charlie"),
      score("abc", "a_big_cat".replace("_", "")),
      score("abc", "abd")]
    for i in 0 ..< scores.high:
      check scores[i] > scores[i + 1]

  test "tier score ranges do not overlap":
    for t in mtSubsequence .. mtExact:
      check TierBase[t] - TierBase[pred(t)] > 2 * TierSpread

  test "no match":
    check score("zzz", "Firefox") == NoMatch
    check match("zzz", "Firefox")[1].len == 0
    check score("", "Firefox") == NoMatch
    check score("fire", "") == NoMatch

  test "vsc finds Visual Studio Code with initials highlighted":
    let (s, spans) = match("vsc", "Visual Studio Code")
    check matchTier(s) == mtAcronym
    check highlighted("Visual Studio Code", spans) == "VSC"

  test "ffx finds Firefox as a subsequence":
    let (s, spans) = match("ffx", "Firefox")
    check matchTier(s) == mtSubsequence
    check highlighted("Firefox", spans) == "Ffx"

  test "acronym over multiple words":
    check tier("gc", "Google Chrome") == mtAcronym
    check score("gc", "Google Chrome") > score("gc", "Gnome Calculator Extra Long Name")
    check highlighted("Google Chrome", match("gc", "Google Chrome")[1]) == "GC"

  test "camelCase and separators count as word starts":
    check tier("gc", "GoogleChrome") == mtAcronym
    check tier("ps", "photo-shop") == mtAcronym
    check tier("ps", "photo_shop") == mtAcronym
    check tier("tm", "task.manager") == mtAcronym
    check highlighted("MyCoolApp", match("mca", "MyCoolApp")[1]) == "MCA"

  test "acronym that skips words ranks below a compact one":
    check score("vc", "Visual Code") > score("vc", "Visual Studio Code")

  test "subsequence prefers consecutive runs and early starts":
    check score("frfx", "Firefox") > score("frfx", "Free Form Fax Xylophone")
    check score("abc", "zzabczz") > score("abc", "zazbzcz")

  test "typo tolerance":
    let (s, spans) = match("fierfox", "Firefox")
    check matchTier(s) == mtTypo
    check spans.len == 1
    check tier("termnal", "Terminal") != mtNone
    check tier("terimnal", "Terminal") == mtTypo
    check tier("firefax", "Firefox") == mtTypo
    check score("termnal", "Terminal") < score("terminal", "Terminal")

  test "short queries do not typo-match":
    check score("fx", "fy") == NoMatch
    check score("ab", "ac") == NoMatch

  test "shorter text wins inside a tier":
    check score("fire", "Fire") > score("fire", "Firefox")
    check score("fire", "Firefox") > score("fire", "Firefox Developer Edition")

  test "minTier skips weaker tiers":
    var spans: seq[(int, int)]
    check fuzzyMatch("vsc", "Visual Studio Code", "", spans, mtSubstring) == NoMatch
    check spans.len == 0
    check fuzzyScore("vsc", "Visual Studio Code", "", mtAcronym) != NoMatch
    check fuzzyScore("fierfox", "Firefox", "", mtSubsequence) == NoMatch

  test "textLower is optional and does not change the result":
    var spans: seq[(int, int)]
    let withLower = fuzzyMatch("vsc", "Visual Studio Code", "visual studio code", spans)
    let without = fuzzyMatch("vsc", "Visual Studio Code", "", spans)
    check withLower == without

  test "substring spans cover the match":
    let (_, spans) = match("studio", "Visual Studio Code")
    check spans == @[(7, 6)]
    check match("fire", "Firefox")[1] == @[(0, 4)]

  test "unicode text keeps valid UTF-8 spans":
    let text = "Café 東京"
    let (s, spans) = match("é東", text)
    check s != NoMatch
    check highlighted(text, spans) == "é東"
    let (sa, accent) = match("caf", text)
    check matchTier(sa) == mtPrefix
    check highlighted(text, accent) == "Caf"
    check highlighted(text, match("東京", text)[1]) == "東京"
    check highlighted(text, match("c東", text)[1]) == "C東"

  test "unicode case folding":
    check score("É", "é") != NoMatch
    check tier("é", "É") == mtExact
    check tier("éa", "Éa Test") == mtPrefix
    check tier("ÉCOLE", "école") == mtExact
    check tier("naïve", "Naïve Bayes") == mtPrefix

  test "ascii query against non-ascii text":
    check tier("cafe", "Café") == mtTypo
    check tier("tokyo", "Café 東京") == mtNone

  test "very long input is bounded":
    let long = "ab".repeat(400)
    check score("ba", long) != NoMatch
    check score("é", "é".repeat(400)) != NoMatch
    check score("é".repeat(70), "é".repeat(80)) == NoMatch
