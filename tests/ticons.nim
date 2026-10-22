import std/[unittest, os, strutils]
import ../src/icon_resolver

const
  FakeIndex = """
[Icon Theme]
Name=Fake
Inherits=Parent
Directories=16x16/apps,32x32/apps,scalable/apps

[16x16/apps]
Size=16
Type=Fixed

[32x32/apps]
Size=32
Type=Fixed

[scalable/apps]
Size=64
MinSize=8
MaxSize=512
Type=Scalable
"""
  ParentIndex = """
[Icon Theme]
Name=Parent
Inherits=hicolor
Directories=48x48/apps,symbolic/apps

[48x48/apps]
Size=48
Type=Fixed

[symbolic/apps]
Size=16
MinSize=8
MaxSize=512
Type=Scalable
"""
  HicolorIndex = """
[Icon Theme]
Name=Hicolor
Directories=32x32/apps,128x128/apps

[32x32/apps]
Size=32
Type=Fixed

[128x128/apps]
Size=128
Type=Fixed
"""

var
  root: string
  savedEnv: seq[(string, string, bool)]

proc touch(path: string) =
  createDir(parentDir(path))
  writeFile(path, "x")

proc writeThemeIndex(base, theme, content: string) =
  createDir(base / "icons" / theme)
  writeFile(base / "icons" / theme / "index.theme", content)

proc setEnv(key, value: string) =
  savedEnv.add((key, getEnv(key), existsEnv(key)))
  putEnv(key, value)

proc setUp() =
  root = getTempDir() / ("nimlaunch-icons-" & $getCurrentProcessId())
  removeDir(root)
  createDir(root / "home")
  createDir(root / "cfg")
  createDir(root / "data")
  createDir(root / "sys")
  setEnv("HOME", root / "home")
  setEnv("XDG_CONFIG_HOME", root / "cfg")
  setEnv("XDG_DATA_HOME", root / "data")
  setEnv("XDG_DATA_DIRS", root / "sys")
  setEnv("ICON_THEME", "fake")
  let sys = root / "sys"
  writeThemeIndex(sys, "fake", FakeIndex)
  writeThemeIndex(sys, "parent", ParentIndex)
  writeThemeIndex(sys, "hicolor", HicolorIndex)

proc tearDown() =
  for i in countdown(savedEnv.high, 0):
    let (key, value, existed) = savedEnv[i]
    if existed:
      putEnv(key, value)
    else:
      delEnv(key)
  removeDir(root)

setUp()

let sys = root / "sys" / "icons"

suite "Icon resolver":
  setup:
    resetIconResolverForTests()

  test "exact fixed size match":
    touch(sys / "fake/16x16/apps/exact.png")
    touch(sys / "fake/32x32/apps/exact.png")
    check resolveIconPath("exact", 32) == sys / "fake/32x32/apps/exact.png"
    check resolveIconPath("exact", 16) == sys / "fake/16x16/apps/exact.png"

  test "closest size when no exact match":
    touch(sys / "fake/16x16/apps/near.png")
    touch(sys / "fake/32x32/apps/near.png")
    check resolveIconPath("near", 30) == sys / "fake/32x32/apps/near.png"
    check resolveIconPath("near", 17) == sys / "fake/16x16/apps/near.png"

  test "scalable svg when no fixed size fits":
    touch(sys / "fake/scalable/apps/vector.svg")
    check resolveIconPath("vector", 24) == sys / "fake/scalable/apps/vector.svg"

  test "png preferred over svg in the same directory":
    touch(sys / "fake/32x32/apps/both.svg")
    touch(sys / "fake/32x32/apps/both.png")
    check resolveIconPath("both", 32) == sys / "fake/32x32/apps/both.png"

  test "preferred theme beats larger exact icon in hicolor":
    touch(sys / "fake/16x16/apps/consistent.png")
    touch(sys / "hicolor/32x32/apps/consistent.png")
    check resolveIconPath("consistent", 32) == sys / "fake/16x16/apps/consistent.png"

  test "hicolor is used when the preferred chain lacks the icon":
    touch(sys / "hicolor/128x128/apps/onlyhicolor.png")
    check resolveIconPath("onlyhicolor", 32) == sys / "hicolor/128x128/apps/onlyhicolor.png"

  test "inherited theme lookup":
    touch(sys / "parent/48x48/apps/inherited.png")
    touch(sys / "hicolor/32x32/apps/inherited.png")
    check resolveIconPath("inherited", 32) == sys / "parent/48x48/apps/inherited.png"

  test "theme directory spread over several base dirs":
    touch(root / "data/icons/fake/32x32/apps/split.png")
    check resolveIconPath("split", 32) == root / "data/icons/fake/32x32/apps/split.png"

  test "symbolic-only icon is found as last resort":
    touch(sys / "parent/symbolic/apps/onlysym.svg")
    check resolveIconPath("onlysym", 32) == sys / "parent/symbolic/apps/onlysym.svg"

  test "name-symbolic file is found as last resort":
    touch(sys / "fake/scalable/apps/dashy-symbolic.svg")
    check resolveIconPath("dashy", 32) == sys / "fake/scalable/apps/dashy-symbolic.svg"

  test "non-symbolic icon beats symbolic one from an earlier theme":
    touch(sys / "parent/symbolic/apps/mixed.svg")
    touch(sys / "hicolor/32x32/apps/mixed.png")
    check resolveIconPath("mixed", 32) == sys / "hicolor/32x32/apps/mixed.png"

  test "symbolic name request accepts symbolic directories":
    touch(sys / "parent/symbolic/apps/wanted-symbolic.svg")
    check resolveIconPath("wanted-symbolic", 16) == sys / "parent/symbolic/apps/wanted-symbolic.svg"

  test "pixmap fallback":
    touch(root / "sys/pixmaps/pixonly.png")
    check resolveIconPath("pixonly", 32) == root / "sys/pixmaps/pixonly.png"
    touch(root / "sys/pixmaps/pixext.xpm")
    check resolveIconPath("pixext.xpm", 32) == root / "sys/pixmaps/pixext.xpm"

  test "themed icon beats pixmap":
    touch(root / "sys/pixmaps/both2.png")
    touch(sys / "hicolor/128x128/apps/both2.png")
    check resolveIconPath("both2", 32) == sys / "hicolor/128x128/apps/both2.png"

  test "names with extension and mixed case":
    touch(sys / "fake/32x32/apps/ext.png")
    touch(sys / "fake/32x32/apps/casey.png")
    check resolveIconPath("ext.png", 32) == sys / "fake/32x32/apps/ext.png"
    check resolveIconPath("ext.svg", 32) == sys / "fake/32x32/apps/ext.png"
    check resolveIconPath("Casey", 32) == sys / "fake/32x32/apps/casey.png"

  test "absolute path passthrough":
    let abs = root / "loose.png"
    touch(abs)
    touch(root / "bare.svg")
    check resolveIconPath(abs, 32) == abs
    check resolveIconPath(root / "bare", 32) == root / "bare.svg"
    check resolveIconPath(root / "nothere", 32) == ""

  test "missing icon returns empty and is cached":
    check resolveIconPath("ghost", 32) == ""
    touch(sys / "fake/32x32/apps/ghost.png")
    check resolveIconPath("ghost", 32) == ""
    check resolveIconPath("ghost", 16) == sys / "fake/32x32/apps/ghost.png"
    resetIconResolverForTests()
    check resolveIconPath("ghost", 32) == sys / "fake/32x32/apps/ghost.png"

  test "unrelated installed theme is the last resort":
    writeThemeIndex(root / "sys", "other",
      "[Icon Theme]\nDirectories=32x32/apps\n[32x32/apps]\nSize=32\nType=Fixed\n")
    touch(sys / "other/32x32/apps/stray.png")
    check resolveIconPath("stray", 32) == sys / "other/32x32/apps/stray.png"
    touch(root / "sys" / "pixmaps" / "straypix.png")
    touch(sys / "other/32x32/apps/straypix.png")
    resetIconResolverForTests()
    check resolveIconPath("straypix", 32) == root / "sys" / "pixmaps" / "straypix.png"

  test "empty name":
    check resolveIconPath("", 32) == ""

  test "reset picks up a different theme":
    touch(sys / "fake/32x32/apps/swap.png")
    touch(sys / "hicolor/32x32/apps/swap.png")
    check resolveIconPath("swap", 32) == sys / "fake/32x32/apps/swap.png"
    putEnv("ICON_THEME", "nonexistent-theme")
    resetIconResolverForTests()
    check resolveIconPath("swap", 32) == sys / "hicolor/32x32/apps/swap.png"
    putEnv("ICON_THEME", "fake")

  test "inherit cycles terminate":
    writeThemeIndex(root / "sys", "loopa",
      "[Icon Theme]\nInherits=loopb\nDirectories=16x16/apps\n" &
      "[16x16/apps]\nSize=16\nType=Fixed\n")
    writeThemeIndex(root / "sys", "loopb",
      "[Icon Theme]\nInherits=loopa,fake\nDirectories=\n")
    putEnv("ICON_THEME", "loopa")
    resetIconResolverForTests()
    touch(sys / "loopa/16x16/apps/cyc.png")
    check resolveIconPath("cyc", 16) == sys / "loopa/16x16/apps/cyc.png"
    check resolveIconPath("cycmissing", 16) == ""
    putEnv("ICON_THEME", "fake")

tearDown()
