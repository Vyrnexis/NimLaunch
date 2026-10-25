import std/[unittest, options, os, tables]
import ../src/parser

suite "Parser tests":
  test "tokenize basic args":
    let toks = tokenize("hello world")
    check toks == @["hello", "world"]

  test "tokenize quotes":
    let toks = tokenize("cmd -arg \"hello world\" 'foo bar'")
    check toks == @["cmd", "-arg", "hello world", "foo bar"]

  test "tokenize preserves an explicitly empty argument":
    check tokenize("cmd \"\" tail") == @["cmd", "", "tail"]

  test "tokenize escapes":
    let toks = tokenize("cmd \"hello \\\"world\\\"\"")
    check toks == @["cmd", "hello \"world\""]
    check tokenize("cmd \"C:\\dir\\a\\\\b\"") == @["cmd", "C:\\dir\\a\\b"]

  test "expand Desktop Entry field codes":
    let expanded = expandExecArgs("viewer %F %i --name=%c %k %%",
        "My App", "my-icon", "/tmp/my-app.desktop")
    check expanded.valid
    check expanded.args == @[
      "viewer", "--icon", "my-icon", "--name=My App",
      "/tmp/my-app.desktop", "%"
    ]
    check not expandExecArgs("viewer %x").valid

  test "prefer localized values before the default":
    let hadLcAll = existsEnv("LC_ALL")
    let oldLcAll = getEnv("LC_ALL")
    defer:
      if hadLcAll: putEnv("LC_ALL", oldLcAll)
      else: delEnv("LC_ALL")
    putEnv("LC_ALL", "fr_FR.UTF-8")
    let entries = {
      "Name": "English",
      "Name[fr]": "Français",
      "Name[fr_FR]": "Français (France)"
    }.toTable
    check getBestValue(entries, "Name") == "Français (France)"

  test "getBaseExec":
    check getBaseExec("/usr/bin/kitty --single-instance") == "kitty"
    check getBaseExec("code %F") == "code"
    check getBaseExec("env FOO=1 VAR=2 /opt/app/bin/foo %U") == "foo"
    check getBaseExec("flatpak run com.app.Name") == "com.app.Name"
    check getBaseExec("snap run app") == "app"
    check getBaseExec("sh -c 'prog --opt'") == "prog"
    check getBaseExec("sudo nano") == "nano"
    check getBaseExec("pkexec gparted") == "gparted"

  test "parseDesktopFile valid entry with actions":
    let tmp = getTempDir() / "nimlaunch_test_valid.desktop"
    writeFile(tmp, """[Desktop Entry]
Name=SuperApp
Exec=superapp %U
Path=/tmp
Icon=superapp-icon
Categories=Network;WebBrowser;
Actions=NewTab;

[Desktop Action NewTab]
Name=New Tab
Exec=superapp --new-tab
Icon=tab-new
""")
    defer:
      if fileExists(tmp): removeFile(tmp)

    let parsed = parseDesktopFile(tmp)
    check isSome(parsed)
    let app = get(parsed)
    check app.name == "SuperApp"
    check app.exec == "superapp %U"
    check app.desktopFile == tmp
    check app.workingDir == "/tmp"
    check app.icon == "superapp-icon"
    check app.desktopActions.len == 1
    check app.desktopActions[0].name == "New Tab"
    check app.desktopActions[0].exec == "superapp --new-tab"

  test "parseDesktopFile exclusions":
    let tmp = getTempDir() / "nimlaunch_test_excluded.desktop"
    defer:
      if fileExists(tmp): removeFile(tmp)

    # NoDisplay=true
    writeFile(tmp, "[Desktop Entry]\nName=HiddenApp\nExec=hiddenapp\nNoDisplay=true\n")
    check isNone(parseDesktopFile(tmp))

    # Unknown field codes invalidate the entry.
    writeFile(tmp, "[Desktop Entry]\nName=InvalidApp\nExec=invalid %x\n")
    check isNone(parseDesktopFile(tmp))

  test "Terminal=true applications are kept and flagged":
    let tmp = getTempDir() / "nimlaunch_test_terminal.desktop"
    defer:
      if fileExists(tmp): removeFile(tmp)

    writeFile(tmp, "[Desktop Entry]\nName=TerminalApp\nExec=htop\nTerminal=true\n")
    let parsed = parseDesktopFile(tmp)
    check isSome(parsed)
    check get(parsed).terminal

    writeFile(tmp, "[Desktop Entry]\nName=PlainApp\nExec=plain\nTerminal=false\n")
    check not get(parseDesktopFile(tmp)).terminal

  test "categories do not control application visibility":
    let tmp = getTempDir() / "nimlaunch_test_categories.desktop"
    defer:
      if fileExists(tmp): removeFile(tmp)

    writeFile(tmp,
        "[Desktop Entry]\nName=SettingsApp\nExec=gnome-control-center\n" &
        "Categories=GNOME;GTK;Settings;\n")
    check isSome(parseDesktopFile(tmp))

    writeFile(tmp,
        "[Desktop Entry]\nName=SystemApp\nExec=system-monitor\nCategories=System;\n")
    check isSome(parseDesktopFile(tmp))

  test "GenericName and Keywords are parsed with lowercase forms":
    let tmp = getTempDir() / "nimlaunch_test_keywords.desktop"
    defer:
      if fileExists(tmp): removeFile(tmp)

    writeFile(tmp, "[Desktop Entry]\nName=Éditeur\nGenericName=Web Browser\n" &
        "Keywords=Internet; WWW ;Navigateur;;\nExec=editor\n")
    let app = get(parseDesktopFile(tmp))
    check app.nameLower == "éditeur"
    check app.genericName == "Web Browser"
    check app.genericLower == "web browser"
    check app.keywords == @["Internet", "WWW", "Navigateur"]
    check app.keywordsLower == @["internet", "www", "navigateur"]

  test "missing GenericName and Keywords stay empty":
    let tmp = getTempDir() / "nimlaunch_test_no_keywords.desktop"
    defer:
      if fileExists(tmp): removeFile(tmp)

    writeFile(tmp, "[Desktop Entry]\nName=Plain\nExec=plain\n")
    let app = get(parseDesktopFile(tmp))
    check app.genericName.len == 0
    check app.keywords.len == 0
    check app.keywordsLower.len == 0

  test "localized GenericName and Keywords are preferred":
    let hadLcAll = existsEnv("LC_ALL")
    let oldLcAll = getEnv("LC_ALL")
    let tmp = getTempDir() / "nimlaunch_test_localized_keywords.desktop"
    defer:
      if hadLcAll: putEnv("LC_ALL", oldLcAll)
      else: delEnv("LC_ALL")
      if fileExists(tmp): removeFile(tmp)

    writeFile(tmp, "[Desktop Entry]\nName=Browser\nGenericName=Web Browser\n" &
        "GenericName[fr]=Navigateur Web\nKeywords=Internet;\n" &
        "Keywords[fr]=Internet;Navigateur;Web;\nExec=browser\n")
    putEnv("LC_ALL", "fr_FR.UTF-8")
    let french = get(parseDesktopFile(tmp))
    check french.genericName == "Navigateur Web"
    check french.keywords == @["Internet", "Navigateur", "Web"]
    putEnv("LC_ALL", "C")
    let fallback = get(parseDesktopFile(tmp))
    check fallback.genericName == "Web Browser"
    check fallback.keywords == @["Internet"]

  test "desktop entry value unescaping with \\s in Name":
    let tmp = getTempDir() / "nimlaunch_test_unescape_name.desktop"
    defer:
      if fileExists(tmp): removeFile(tmp)

    writeFile(tmp, """[Desktop Entry]
Name=\sMy\sApp\s
GenericName=Web\sBrowser
Icon=my\sapp\sicon
Path=/home/user/my\sapp
Exec=myapp
Type=Application
""")
    let parsed = parseDesktopFile(tmp)
    check isSome(parsed)
    let app = get(parsed)
    check app.name == " My App "
    check app.nameLower == " my app "
    check app.genericName == "Web Browser"
    check app.genericLower == "web browser"
    check app.icon == "my app icon"
    check app.workingDir == "/home/user/my app"

  test "splitDesktopList with \\; in Keywords":
    let tmp = getTempDir() / "nimlaunch_test_keywords_semicolon.desktop"
    defer:
      if fileExists(tmp): removeFile(tmp)

    writeFile(tmp, """[Desktop Entry]
Name=Editor
Exec=editor
Keywords=Science\;Math;Programming\;Development;Plain;
""")
    let parsed = parseDesktopFile(tmp)
    check isSome(parsed)
    let app = get(parsed)
    check app.keywords == @["Science;Math", "Programming;Development", "Plain"]
    check app.keywordsLower == @["science;math", "programming;development", "plain"]

  test "Exec double-escape unescaping":
    let tmp = getTempDir() / "nimlaunch_test_exec_double_escape.desktop"
    defer:
      if fileExists(tmp): removeFile(tmp)

    writeFile(tmp, """[Desktop Entry]
Name=EchoApp
Exec=sh -c "echo \\"hi\\""
Type=Application
Actions=Custom;

[Desktop Action Custom]
Name=EchoAction
Exec=sh -c "echo \\"action\\""
""")
    let parsed = parseDesktopFile(tmp)
    check isSome(parsed)
    let app = get(parsed)
    check app.exec == "sh -c \"echo \\\"hi\\\"\""
    let expanded = expandExecArgs(app.exec)
    check expanded.valid
    check expanded.args == @["sh", "-c", "echo \"hi\""]
    check getBaseExec(app.exec) == "echo"
    check app.desktopActions.len == 1
    let actionExpanded = expandExecArgs(app.desktopActions[0].exec)
    check actionExpanded.valid
    check actionExpanded.args == @["sh", "-c", "echo \"action\""]

  test "getBestValue with precomputed prefs and overload":
    let hadLcAll = existsEnv("LC_ALL")
    let oldLcAll = getEnv("LC_ALL")
    defer:
      if hadLcAll: putEnv("LC_ALL", oldLcAll)
      else: delEnv("LC_ALL")
    putEnv("LC_ALL", "de_DE.UTF-8")
    let entries = {
      "Name": "English",
      "Name[de]": "Deutsch",
      "Name[de_DE]": "Deutsch (Deutschland)"
    }.toTable
    # Overload using localeChain()
    check getBestValue(entries, "Name") == "Deutsch (Deutschland)"
    # Parameterized overload with explicit prefs
    check getBestValue(entries, "Name", @["de_DE", "de"]) == "Deutsch (Deutschland)"
    check getBestValue(entries, "Name", @["de"]) == "Deutsch"
    check getBestValue(entries, "Name", @["fr"]) == "English"
    check getBestValue(entries, "Name", @[]) == "English"
