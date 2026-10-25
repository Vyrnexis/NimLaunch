import std/[assertions, json, os, osproc, unicode, strutils, tables, sequtils]
import sdl3
import ../src/themes
import ../src/[state, layout, parser, fuzzy, app_core, input, proc_utils, utils,
    settings, apps_cache, search, gui, paths]

block font_drives_layout:
  for fontHeight in [12, 16, 24, 32, 48, 64]:
    let input = LayoutInput(
      canvasHeight: 2000,
      requestedRows: 10,
      configuredLineHeight: 22,
      fontLineHeight: fontHeight,
      overlayLineHeight: max(10, fontHeight - 2),
      iconMinimum: 18,
      textPadding: 4,
      outerMargin: 10,
      rowGap: 6,
      commandExtraHeight: 6,
      commandBottomGap: 4,
      vimMode: false,
      showIcons: true)
    let computed = computeLayout(input)
    doAssert computed.rowHeight >= fontHeight + 4
    doAssert computed.visibleRows == 10
    doAssert computed.desiredHeight >= computed.contentTop + 10 * computed.rowHeight

block small_canvas_reduces_visible_rows:
  let computed = computeLayout(LayoutInput(
    canvasHeight: 180,
    requestedRows: 20,
    configuredLineHeight: 22,
    fontLineHeight: 32,
    overlayLineHeight: 30,
    iconMinimum: 18,
    textPadding: 4,
    outerMargin: 10,
    rowGap: 6,
    commandExtraHeight: 6,
    commandBottomGap: 4,
    vimMode: false,
    showIcons: true))
  doAssert computed.visibleRows < 20
  doAssert computed.contentTop + computed.visibleRows * computed.rowHeight <=
      computed.contentBottom

block empty_quoted_argument_is_preserved:
  doAssert tokenize("program \"\" tail") == @["program", "", "tail"]
  doAssert expandExecArgs("program \"\" tail").args == @["program", "", "tail"]
  doAssert expandExecArgs("program %f tail").args == @["program", "tail"]

block unicode_highlights_are_valid:
  let text = "Café 東京"
  var spans: seq[(int, int)]
  doAssert fuzzyMatch("é東", text, "", spans) != NoMatch
  doAssert spans.len == 2
  for (start, length) in spans:
    doAssert validateUtf8(text[start..<start + length]) == -1
  doAssert fuzzyScore("é", "É", "") != NoMatch

proc resetSearchState() =
  ctx.config = Config(maxVisibleItems: 10, lineHeight: 22)
  ctx.dmenuMode = false
  ctx.shortcuts = @[]
  ctx.groupQueryModes.clear()
  ctx.recentApps = @[]
  ctx.appUsage.clear()
  ctx.themePreviewActive = false

proc testApp(name: string; genericName = ""; keywords: seq[string] = @[]): DesktopApp =
  DesktopApp(name: name, nameLower: unicode.toLower(name), exec: name.toLowerAscii,
      desktopId: name & ".desktop", genericName: genericName,
      genericLower: unicode.toLower(genericName), keywords: keywords,
      keywordsLower: keywords.mapIt(unicode.toLower(it)))

proc rowNames(): seq[string] =
  for act in ctx.actions:
    result.add act.label

block generic_name_and_keywords_rank_below_name_matches:
  resetSearchState()
  ctx.allApps = @[
    testApp("Calculator"),
    testApp("Falkon", genericName = "Web Browser"),
    testApp("Konqueror", keywords = @["Internet", "browser"]),
    testApp("Browser Settings"),
    testApp("Superbrowser")]
  ctx.inputText = "browser"
  buildActions()
  doAssert rowNames() == @["Browser Settings", "Superbrowser", "Konqueror", "Falkon"]
  doAssert ctx.actions[0].spans == @[(0, 7)]
  doAssert ctx.actions[1].spans == @[(5, 7)]
  doAssert ctx.actions[2].spans.len == 0
  doAssert ctx.actions[3].spans.len == 0
  ctx.inputText = "web brow"
  buildActions()
  doAssert rowNames() == @["Falkon"]
  ctx.allApps = @[]
  ctx.inputText = ""

block acronym_and_subsequence_find_apps_with_exact_highlights:
  resetSearchState()
  ctx.allApps = @[
    testApp("Visual Studio Code"),
    testApp("Firefox"),
    testApp("Calculator")]
  ctx.inputText = "vsc"
  buildActions()
  doAssert rowNames() == @["Visual Studio Code"]
  doAssert ctx.actions[0].spans == @[(0, 1), (7, 1), (14, 1)]
  ctx.inputText = "ffx"
  buildActions()
  doAssert rowNames() == @["Firefox"]
  doAssert ctx.actions[0].spans == @[(0, 1), (4, 1), (6, 1)]
  ctx.inputText = "fierfox"
  buildActions()
  doAssert rowNames() == @["Firefox"]
  doAssert ctx.actions[0].spans.len == 1
  ctx.inputText = "zzz"
  buildActions()
  doAssert ctx.actions[0].kind == akPlaceholder
  doAssert ctx.actions[0].spans.len == 0
  ctx.allApps = @[]
  ctx.inputText = ""

block desktop_action_rows_share_the_app_spans:
  resetSearchState()
  var app = testApp("Terminal")
  app.desktopActions = @[DesktopEntryAction(name: "New Window", exec: "term -n")]
  ctx.allApps = @[app]
  ctx.inputText = "term"
  buildActions()
  doAssert ctx.actions.len == 2
  doAssert ctx.actions[1].kind == akAppAction
  doAssert ctx.actions[0].spans == @[(0, 4)]
  doAssert ctx.actions[1].spans == @[(0, 4)]
  ctx.allApps = @[]
  ctx.inputText = ""

block config_and_group_filters_use_the_matcher:
  resetSearchState()
  ctx.configFilesLoaded = true
  ctx.configFilesCache = @[
    DesktopApp(name: "init.lua", exec: "/c/init.lua"),
    DesktopApp(name: "my-kitty.conf", exec: "/c/my-kitty.conf"),
    DesktopApp(name: "kitty.conf", exec: "/c/kitty.conf")]
  ctx.inputText = ":c kit"
  buildActions()
  doAssert rowNames() == @["kitty.conf", "my-kitty.conf"]
  doAssert ctx.actions[0].spans == @[(0, 3)]
  doAssert ctx.actions[1].spans == @[(3, 3)]
  ctx.configFilesCache = @[]
  ctx.shortcuts = @[
    Shortcut(label: "Wikipedia", base: "u", mode: smUrl, group: "web"),
    Shortcut(label: "Search Web", base: "u", mode: smUrl, group: "web")]
  ctx.groupQueryModes["web"] = gqmFilter
  ctx.inputText = ":web web"
  buildActions()
  doAssert rowNames() == @["Search Web"]
  doAssert ctx.actions[0].spans == @[(7, 3)]
  ctx.shortcuts = @[]
  ctx.groupQueryModes.clear()
  ctx.inputText = ""

block run_and_shortcut_rows_highlight_the_typed_text:
  resetSearchState()
  ctx.inputText = "!ls -l"
  buildActions()
  doAssert ctx.actions[0].kind == akRun
  doAssert ctx.actions[0].spans == @[(5, 5)]
  ctx.shortcuts = @[Shortcut(prefix: "g", label: "Google", base: "u{query}", mode: smUrl)]
  ctx.inputText = ":g cats"
  buildActions()
  doAssert ctx.actions[0].label == "Google cats"
  doAssert ctx.actions[0].spans == @[(7, 4)]
  ctx.shortcuts = @[]
  ctx.inputText = ""

block dmenu_matches_use_unicode_lowercase_and_spans:
  resetSearchState()
  ctx.dmenuMode = true
  ctx.dmenuItems = @[
    DmenuItem(label: "alpha", labelLower: "alpha"),
    DmenuItem(label: "Éclair", labelLower: unicode.toLower("Éclair"))]
  ctx.inputText = "ÉCL"
  buildActions()
  doAssert rowNames() == @["Éclair"]
  doAssert ctx.actions[0].spans == @[(0, 4)]
  ctx.dmenuMode = false
  ctx.dmenuItems = @[]
  ctx.inputText = ""

block unicode_path_shortening_is_valid:
  let shortened = shortenPath("/tmp/東京/📄-résumé.txt", 12)
  doAssert shortened.runeLen <= 12
  doAssert validateUtf8(shortened) == -1

block vim_backspace_does_not_drop_later_text:
  ctx.config.vimMode = true
  ctx.vim.active = true
  ctx.vim.buffer = "ab"
  doAssert handleVimCommandKey(SDLK_BACKSPACE, false)
  var event: Event
  event.text.text = "c"
  var focus: FocusState
  doAssert handleTextInput(event, focus)
  doAssert ctx.vim.buffer == "ac"

block same_name_apps_keep_distinct_identity:
  ctx.config = Config(maxVisibleItems: 10, lineHeight: 22)
  ctx.inputText = ""
  ctx.allApps = @[
    DesktopApp(name: "Editor", nameLower: "editor", exec: "one",
        desktopId: "one.desktop"),
    DesktopApp(name: "Editor", nameLower: "editor", exec: "two",
        desktopId: "two.desktop")]
  ctx.recentApps = @["one.desktop"]
  buildActions()
  doAssert ctx.actions.len == 2
  doAssert appIdentity(ctx.allApps[ctx.actions[0].appIndex]) == "one.desktop"
  doAssert appIdentity(ctx.allApps[ctx.actions[1].appIndex]) == "two.desktop"

block shell_wrapper_accepts_trailing_syntax:
  for command in ["true;", "true &", "printf ok | cat", "true # final comment"]:
    let generated = buildShellCommand(command, "/bin/sh", hold = true).fullCmd
    let process = startProcess("/bin/sh", args = @["-n", "-c", generated])
    doAssert process.waitForExit() == 0
    process.close()

block theme_choice_uses_cache_file:
  let root = getTempDir() / "nimlaunch-theme-state"
  let oldCacheHome = getEnv("XDG_CACHE_HOME")
  defer:
    putEnv("XDG_CACHE_HOME", oldCacheHome)
    if dirExists(root):
      removeDir(root)
  putEnv("XDG_CACHE_HOME", root)
  ctx.config.themeName = "New"
  doAssert saveLastTheme()
  doAssert readFile(root / "nimlaunch/theme") == "New\n"

block expired_status_requests_clear_redraw:
  gui.statusText = "done"
  gui.statusUntilMs = 0
  doAssert gui.needsTimedRedraw()
  doAssert gui.statusText.len == 0

block dmenu_dry_run_records_success:
  ctx.dryRunMode = true
  ctx.dmenuMode = true
  ctx.dmenuAccepted = false
  ctx.dmenuDryRunAccepted = false
  ctx.shouldExit = false
  performAction(Action(kind: akDmenu, exec: "selected"))
  doAssert ctx.shouldExit
  doAssert ctx.dmenuAccepted
  doAssert ctx.dmenuDryRunAccepted
  ctx.dryRunMode = false
  ctx.dmenuMode = false

block desktop_id_precedence_honours_hidden_override:
  let root = getTempDir() / "nimlaunch-desktop-precedence"
  let userData = root / "user"
  let systemData = root / "system"
  let cacheData = root / "cache"
  createDir(userData / "applications")
  createDir(systemData / "applications")
  defer:
    if dirExists(root):
      removeDir(root)
  let oldDataHome = getEnv("XDG_DATA_HOME")
  let oldDataDirs = getEnv("XDG_DATA_DIRS")
  let oldCacheHome = getEnv("XDG_CACHE_HOME")
  let oldLocale = getEnv("LC_ALL")
  defer:
    putEnv("XDG_DATA_HOME", oldDataHome)
    putEnv("XDG_DATA_DIRS", oldDataDirs)
    putEnv("XDG_CACHE_HOME", oldCacheHome)
    putEnv("LC_ALL", oldLocale)
  putEnv("XDG_DATA_HOME", userData)
  putEnv("XDG_DATA_DIRS", systemData)
  putEnv("XDG_CACHE_HOME", cacheData)
  putEnv("LC_ALL", "C")
  writeFile(systemData / "applications/example.desktop",
      "[Desktop Entry]\nName=System\nExec=system-app\n")
  writeFile(userData / "applications/example.desktop",
      "[Desktop Entry]\nName=Hidden\nExec=user-app\nHidden=true\n")
  loadApplications()
  doAssert ctx.allApps.len == 0
  writeFile(userData / "applications/example.desktop",
      "[Desktop Entry]\nName=User\nName[fr]=Utilisateur\n" &
      "Exec=user-app\nPath=/tmp\n")
  loadApplications()
  doAssert ctx.allApps.len == 1
  doAssert ctx.allApps[0].desktopId == "example.desktop"
  doAssert ctx.allApps[0].exec == "user-app"
  doAssert ctx.allApps[0].workingDir == "/tmp"
  putEnv("LC_ALL", "fr_FR.UTF-8")
  loadApplications()
  doAssert ctx.allApps[0].name == "Utilisateur"

block try_exec_changes_invalidate_application_cache:
  let root = getTempDir() / "nimlaunch-tryexec-cache"
  let userData = root / "user"
  let systemData = root / "system"
  let cacheData = root / "cache"
  let executable = root / "available-command"
  createDir(userData / "applications")
  createDir(systemData / "applications")
  defer:
    if dirExists(root):
      removeDir(root)
  let oldDataHome = getEnv("XDG_DATA_HOME")
  let oldDataDirs = getEnv("XDG_DATA_DIRS")
  let oldCacheHome = getEnv("XDG_CACHE_HOME")
  defer:
    putEnv("XDG_DATA_HOME", oldDataHome)
    putEnv("XDG_DATA_DIRS", oldDataDirs)
    putEnv("XDG_CACHE_HOME", oldCacheHome)
  putEnv("XDG_DATA_HOME", userData)
  putEnv("XDG_DATA_DIRS", systemData)
  putEnv("XDG_CACHE_HOME", cacheData)
  writeFile(executable, "#!/bin/sh\nexit 0\n")
  setFilePermissions(executable, {fpUserRead, fpUserWrite, fpUserExec})
  writeFile(userData / "applications/tryexec.desktop",
      "[Desktop Entry]\nName=Conditional\nExec=conditional\nTryExec=" &
      executable & "\n")
  loadApplications()
  doAssert ctx.allApps.len == 1
  removeFile(executable)
  loadApplications()
  doAssert ctx.allApps.len == 0

block cache_hit_skips_scan_until_try_exec_program_appears:
  let root = getTempDir() / "nimlaunch-tryexec-install"
  let userData = root / "user"
  let systemData = root / "system"
  let cacheData = root / "cache"
  let binDir = root / "bin"
  createDir(userData / "applications")
  createDir(systemData / "applications")
  createDir(binDir)
  defer:
    if dirExists(root):
      removeDir(root)
  let oldDataHome = getEnv("XDG_DATA_HOME")
  let oldDataDirs = getEnv("XDG_DATA_DIRS")
  let oldCacheHome = getEnv("XDG_CACHE_HOME")
  let oldPath = getEnv("PATH")
  defer:
    putEnv("XDG_DATA_HOME", oldDataHome)
    putEnv("XDG_DATA_DIRS", oldDataDirs)
    putEnv("XDG_CACHE_HOME", oldCacheHome)
    putEnv("PATH", oldPath)
  putEnv("XDG_DATA_HOME", userData)
  putEnv("XDG_DATA_DIRS", systemData)
  putEnv("XDG_CACHE_HOME", cacheData)
  ## PATH is part of the cache key, so it must stay fixed during the test.
  putEnv("PATH", binDir & ":" & oldPath)
  writeFile(userData / "applications/plain.desktop",
      "[Desktop Entry]\nName=Plain\nExec=plain\n")
  writeFile(userData / "applications/later.desktop",
      "[Desktop Entry]\nName=Later\nExec=later\nTryExec=nimlaunch-later-cmd\n")
  loadApplications()
  doAssert ctx.allApps.len == 1
  doAssert ctx.allApps[0].name == "Plain"

  ## An edited cache is returned verbatim only when the next load is a hit.
  let cacheFile = cacheDir() / "apps.json"
  let cached = parseJson(readFile(cacheFile))
  doAssert cached["tryExecs"].len == 1
  cached["apps"][0]["name"] = newJString("FromCache")
  writeFile(cacheFile, $cached)
  loadApplications()
  doAssert ctx.allApps.len == 1
  doAssert ctx.allApps[0].name == "FromCache"

  ## Installing the TryExec program invalidates the cache and adds the entry.
  let program = binDir / "nimlaunch-later-cmd"
  writeFile(program, "#!/bin/sh\nexit 0\n")
  setFilePermissions(program, {fpUserRead, fpUserWrite, fpUserExec})
  loadApplications()
  doAssert ctx.allApps.len == 2
  doAssert ctx.allApps[0].name == "Later"
  doAssert ctx.allApps[1].name == "Plain"

block desktop_working_directory_reaches_spawn:
  let root = getTempDir() / "nimlaunch-working-directory"
  let output = root / "pwd.txt"
  createDir(root)
  defer:
    if dirExists(root):
      removeDir(root)
  doAssert spawnProcess("/bin/sh", ["-c", "pwd > \"$1\"", "sh", output], root)
  for _ in 0..<200:
    if fileExists(output):
      break
    sleep(10)
  doAssert fileExists(output)
  doAssert readFile(output).strip() == root

block background_search_returns_without_blocking_request:
  let root = getTempDir() / "nimlaunch-search-worker"
  createDir(root)
  defer:
    stopSearchWorker()
    if dirExists(root):
      removeDir(root)
  let oldHome = getEnv("HOME")
  defer: putEnv("HOME", oldHome)
  putEnv("HOME", root)
  startSearchWorker()
  let generation = requestFileSearch("nothing-matches-this-query")
  doAssert generation > 0
  var response: SearchResponse
  var received = false
  for _ in 0..<500:
    if pollFileSearch(response):
      received = true
      break
    sleep(10)
  doAssert received
  doAssert response.generation == generation
  doAssert response.query == "nothing-matches-this-query"

block quit_command_requires_activation:
  ctx.config = Config(maxVisibleItems: 10, lineHeight: 22)
  ctx.dmenuMode = false
  ctx.shouldExit = false
  ctx.shortcuts = @[Shortcut(prefix: "qr", label: "QR", base: "qrencode",
      mode: smShell, group: "qr")]
  ctx.groupQueryModes["qr"] = gqmFilter
  ctx.inputText = ":q"
  buildActions()
  doAssert not ctx.shouldExit
  doAssert ctx.actions.len == 1
  doAssert ctx.actions[0].kind == akQuit
  ctx.inputText = ":qr"
  buildActions()
  doAssert not ctx.shouldExit
  doAssert ctx.actions.len == 1
  doAssert ctx.actions[0].kind == akShortcut
  ctx.inputText = ":q"
  buildActions()
  activateCurrentSelection()
  doAssert ctx.shouldExit
  ctx.shouldExit = false
  ctx.shortcuts = @[]
  ctx.groupQueryModes.clear()
  ctx.inputText = ""

block vim_mode_keeps_navigation_keys:
  ctx.config = Config(maxVisibleItems: 10, lineHeight: 22, vimMode: true)
  ctx.vim = VimCommandState()
  ctx.actions = @[Action(kind: akRun, label: "one"), Action(kind: akRun, label: "two")]
  ctx.selectedIndex = 0
  ctx.viewOffset = 0
  var event: Event
  event.key.key = SDLK_DOWN
  var focus: FocusState
  doAssert handleKeyDown(event, focus)
  doAssert ctx.selectedIndex == 1
  event.key.key = SDLK_UP
  doAssert handleKeyDown(event, focus)
  doAssert ctx.selectedIndex == 0
  ctx.config.vimMode = false
  ctx.actions = @[]

block home_paths_use_tilde_and_score_higher:
  let home = getHomeDir()
  doAssert shortenPath(home & "Documents/notes.txt") == "~/Documents/notes.txt"
  let homeNoSlash = homeDirNoSlash()
  doAssert not homeNoSlash.endsWith("/")
  let depth = homeNoSlash.count('/')
  let inHome = scoreSearchCandidate("notes", "notes", "notes.txt",
      homeNoSlash & "/notes.txt", homeNoSlash, depth)
  let inDocs = scoreSearchCandidate("notes", "notes", "notes.txt",
      homeNoSlash & "/a/b/notes.txt", homeNoSlash, depth)
  let outside = scoreSearchCandidate("notes", "notes", "notes.txt",
      "/usr/share/notes.txt", homeNoSlash, depth)
  doAssert inHome > inDocs
  doAssert inDocs > outside

block terminal_desktop_apps_use_terminal_argv:
  let cmd = @["htop", "--tree"]
  doAssert terminalCommandArgs("kitty", @[], cmd) == @["-e", "htop", "--tree"]
  doAssert terminalCommandArgs("alacritty", @["--class", "x"], cmd) ==
      @["--class", "x", "-e", "htop", "--tree"]
  doAssert terminalCommandArgs("gnome-terminal", @[], cmd) == @["--", "htop", "--tree"]
  doAssert terminalCommandArgs("xfce4-terminal", @[], cmd) == @["-x", "htop", "--tree"]
  doAssert terminalCommandArgs("kgx", @[], cmd) == @["--", "htop", "--tree"]
  doAssert terminalCommandArgs("wezterm", @[], cmd, wezSeparator = true) ==
      @["start", "--", "htop", "--tree"]
  doAssert terminalCommandArgs("wezterm", @[], cmd) == @["start", "htop", "--tree"]
  doAssert buildTerminalArgs("kitty", @[], "/bin/sh", @["-c", "x"]) ==
      @["-e", "/bin/sh", "-c", "x"]

block dmenu_returns_typed_text_without_match:
  ctx.config = Config(maxVisibleItems: 10, lineHeight: 22)
  ctx.dryRunMode = false
  ctx.dmenuMode = true
  ctx.dmenuItems = @[DmenuItem(label: "alpha", labelLower: "alpha")]
  ctx.dmenuAccepted = false
  ctx.dmenuOutput = ""
  ctx.shouldExit = false
  ctx.inputText = "zzz-new-name"
  buildActions()
  doAssert ctx.actions.len == 1
  doAssert ctx.actions[0].kind == akPlaceholder
  activateCurrentSelection()
  doAssert ctx.dmenuAccepted
  doAssert ctx.dmenuOutput == "zzz-new-name"
  doAssert ctx.shouldExit
  # Shift+Enter returns the typed text even when a row matches.
  ctx.dmenuAccepted = false
  ctx.dmenuOutput = ""
  ctx.shouldExit = false
  ctx.inputText = "alp"
  buildActions()
  doAssert ctx.actions[0].kind == akDmenu
  var event: Event
  event.key.key = SDLK_RETURN
  event.key.`mod` = Keymod(KMOD_SHIFT)
  var focus: FocusState
  doAssert handleKeyDown(event, focus)
  doAssert ctx.dmenuOutput == "alp"
  doAssert ctx.shouldExit
  # Plain Enter with an empty query and no match does nothing.
  ctx.dmenuAccepted = false
  ctx.shouldExit = false
  ctx.dmenuItems = @[]
  ctx.inputText = ""
  buildActions()
  activateCurrentSelection()
  doAssert not ctx.dmenuAccepted
  doAssert not ctx.shouldExit
  ctx.dmenuMode = false
  ctx.dmenuItems = @[]
  ctx.inputText = ""

block theme_filter_selects_best_match_not_stale_row:
  resetSearchState()
  ctx.themeList = BuiltinThemes
  ctx.config.themeName = "Nord"
  ctx.inputText = ":t"
  buildActions()
  doAssert ctx.actions[ctx.selectedIndex].label == "Nord"
  ctx.inputText = ":t l"
  buildActions()
  doAssert ctx.selectedIndex == 0
  doAssert ctx.actions[0].kind == akTheme
  doAssert ctx.themePreviewCurrent == ctx.actions[0].exec
  endThemePreviewSession(false)
  ctx.inputText = ""
  ctx.actions = @[]

block narrowing_search_drops_non_matching_paths:
  let paths = @["/home/u/Notes.txt", "/home/u/notes/readme.md", "/home/u/other.txt"]
  doAssert narrowSearchPaths(paths, "notes") ==
      @["/home/u/Notes.txt", "/home/u/notes/readme.md"]
  doAssert narrowSearchPaths(paths, "notes.t") == @["/home/u/Notes.txt"]
  doAssert narrowSearchPaths(paths, "zzz").len == 0

block dmenu_line_parses_row_options:
  let plain = parseDmenuLine("Plain")
  doAssert plain.label == "Plain" and plain.iconName == "" and plain.meta == ""
  let full = parseDmenuLine("Fire\0icon\x1ffirefox\x1fmeta\x1fWeb Browser\x1fnonselectable\x1ftrue\x1fbogus\x1fx")
  doAssert full.label == "Fire"
  doAssert full.iconName == "firefox"
  doAssert full.meta == "Web Browser" and full.metaLower == "web browser"
  doAssert full.nonselectable
  doAssert not parseDmenuLine("A\0nonselectable\x1ffalse").nonselectable
  doAssert parseDmenuLine("A\0icon").iconName == ""

block dmenu_meta_matches_rank_below_label:
  resetSearchState()
  ctx.config = Config(maxVisibleItems: 10, lineHeight: 22)
  ctx.dmenuMode = true
  ctx.dmenuItems = @[parseDmenuLine("Zeta\0meta\x1fbrowser"),
      parseDmenuLine("Browser tool")]
  ctx.inputText = "browser"
  buildActions()
  doAssert rowNames() == @["Browser tool", "Zeta"]
  doAssert ctx.actions[1].dmenuIndex == 0
  doAssert ctx.actions[1].spans.len == 0
  ctx.dmenuMode = false
  ctx.dmenuItems = @[]
  ctx.inputText = ""

block dmenu_nonselectable_and_index_output:
  resetSearchState()
  ctx.config = Config(maxVisibleItems: 10, lineHeight: 22)
  ctx.dryRunMode = false
  ctx.dmenuMode = true
  ctx.dmenuItems = @[parseDmenuLine("Header\0nonselectable\x1ftrue"),
      parseDmenuLine("Row")]
  ctx.inputText = ""
  buildActions()
  doAssert ctx.actions.len == 2 and ctx.actions[1].dmenuIndex == 1
  doAssert ctx.actions[1].exec == ""
  ctx.shouldExit = false
  ctx.dmenuAccepted = false
  performAction(ctx.actions[0])
  doAssert not ctx.dmenuAccepted and not ctx.shouldExit
  performAction(ctx.actions[1])
  doAssert ctx.dmenuAccepted and ctx.dmenuOutput == "Row" and ctx.shouldExit
  ctx.dmenuIndexMode = true
  ctx.dmenuAccepted = false
  performAction(ctx.actions[1])
  doAssert ctx.dmenuOutput == "1"
  # Typed text has no input line.
  ctx.dmenuAccepted = false
  performAction(Action(kind: akDmenu, exec: "typed"))
  doAssert not ctx.dmenuAccepted
  ctx.dmenuIndexMode = false
  ctx.dmenuMode = false
  ctx.dmenuItems = @[]
  ctx.shouldExit = false

block dmenu_empty_query_lists_current_items:
  resetSearchState()
  ctx.config = Config(maxVisibleItems: 10, lineHeight: 22)
  ctx.dmenuMode = true
  ctx.dmenuItems = @[parseDmenuLine("one")]
  ctx.inputText = ""
  buildActions()
  doAssert rowNames() == @["one"]
  ctx.dmenuItems = @[parseDmenuLine("two"), parseDmenuLine("three")]
  buildActions()
  doAssert rowNames() == @["two", "three"]
  ctx.dmenuMode = false
  ctx.dmenuItems = @[]
