import std/[unittest, options]
import ../src/[utils, state]

suite "Utils tests":
  test "parseHexRgb8 valid colors":
    let c1 = parseHexRgb8("#000000")
    check isSome(c1)
    check get(c1) == Rgb(r: 0, g: 0, b: 0)

    let c2 = parseHexRgb8("#FFFFFF")
    check isSome(c2)
    check get(c2) == Rgb(r: 255, g: 255, b: 255)

    let c3 = parseHexRgb8("#1E1E2E")
    check isSome(c3)
    check get(c3) == Rgb(r: 0x1E, g: 0x1E, b: 0x2E)

  test "parseHexRgb8 invalid colors":
    check isNone(parseHexRgb8(""))
    check isNone(parseHexRgb8("FFFFFF")) # missing #
    check isNone(parseHexRgb8("#FFFFF"))  # too short
    check isNone(parseHexRgb8("#FFFFFFF")) # too long
    check isNone(parseHexRgb8("#GGGGGG")) # invalid hex characters

  test "normalizePrefix":
    check normalizePrefix(":g") == "g"
    check normalizePrefix("g:") == "g"
    check normalizePrefix(":G:") == "g"
    check normalizePrefix("  :svc:  ") == "svc"
    check normalizePrefix("sys") == "sys"

  test "cursor movement respects UTF-8 boundaries":
    let text = "aé€b"
    check prevRunePos(text, text.len) == text.len - 1
    check prevRunePos(text, 3) == 1
    check prevRunePos(text, 0) == 0
    check nextRunePos(text, 1) == 3
    check nextRunePos(text, 3) == 6
    check nextRunePos(text, text.len) == text.len

  test "insertAt inserts at the cursor":
    var text = "ac"
    check insertAt(text, 1, "é") == 3
    check text == "aéc"
    check insertAt(text, 99, "!") == text.len
    check text == "aéc!"

  test "deleteBefore and deleteAfter remove whole runes":
    var text = "aéb"
    check deleteBefore(text, 3) == 1
    check text == "ab"
    check deleteBefore(text, 0) == 0
    check text == "ab"
    text = "é€"
    deleteAfter(text, 0)
    check text == "€"
    deleteAfter(text, text.len)
    check text == "€"

  test "deleteWordBefore skips trailing spaces then one word":
    var text = "foo bar  baz"
    check deleteWordBefore(text, text.len) == 9
    check text == "foo bar  "
    check deleteWordBefore(text, text.len) == 4
    check text == "foo "
    var mid = "one two"
    check deleteWordBefore(mid, 4) == 0
    check mid == "two"
