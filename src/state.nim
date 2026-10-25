## state.nim — core data definitions and runtime state

import std/tables
# ── Data structures ─────────────────────────────────────────────────────
type
  DmenuItem* = object
    label*: string
    labelLower*: string
    iconName*: string
    meta*, metaLower*: string ## extra search text, never displayed
    nonselectable*: bool

  Rgb* = object
    r*, g*, b*: uint8

  ## A secondary action declared in a .desktop file.
  DesktopEntryAction* = object
    name*: string
    exec*: string
    icon*: string

  ## A single launchable application parsed from a `.desktop` file.
  DesktopApp* = object
    name*, nameLower*, exec*, desktopFile*: string
    desktopId*, workingDir*: string
    genericName*, genericLower*: string
    keywords*, keywordsLower*: seq[string]
    icon*: string
    terminal*: bool ## Terminal=true: run inside the user's terminal
    desktopActions*: seq[DesktopEntryAction]

  ## Payload cached to `~/.cache/nimlaunch/apps.json`.
  CacheData* = object
    formatVersion*: int
    environmentSignature*: string
    appDirs*: seq[string]
    dirSignatures*: seq[string]
    tryExecs*: seq[string]       ## sorted unique TryExec values seen in the scan
    tryExecSignature*: string    ## how those values resolved on PATH
    apps*: seq[DesktopApp]

  AppUsage* = object
    launchCount*: int
    lastLaunched*: int64

  ## Launcher configuration; field defaults are the built-in settings.
  Config* = object
    # Window geometry ----------------------------------------------------
    winWidth*: int = 500
    opacity*: float = 1.0    ## 0.1 - 1.0 window opacity (SDL window)
    lineHeight*: int = 22
    maxVisibleItems*: int = 10
    centerWindow*: bool = true
    positionX*: int = 20
    positionY*: int = 500
    verticalAlign*: string = "one-third" ## "top" | "center" | "one-third"
    displayIndex*: int = 0   ## display index for centered positioning

    # Colours as hex strings (resolved to SDL colours later) -------------
    bgColorHex*, fgColorHex*: string
    highlightBgColorHex*, highlightFgColorHex*: string
    borderColorHex*: string
    borderWidth*: int = 2
    matchFgColorHex*: string = "#f8c291" ## color for matched letters
    showIcons*: bool = true
    showClock*: bool = true

    # Prompt / font / theme / terminal ----------------------------------
    prompt*: string = "> "
    cursor*: string = "_"
    fontName*: string = "Dejavu:size=16"
    themeName*: string
    terminalExe*: string     ## preferred terminal program
    vimMode*: bool

    # Resolved colours (set after theme application) --------------------
    bgColor*, fgColor*, highlightBgColor*, highlightFgColor*,
      borderColor*, matchFgColor*: Rgb

  PowerActionMode* = enum
    pamSpawn,   # execute via background shell
    pamTerminal # run inside configured terminal

  GroupQueryMode* = enum
    gqmFilter, # group query filters entries by label
    gqmPass    # group query passes through as {query}

  ShortcutMode* = enum
    smUrl,   # open base with URL-encoded query
    smShell, # run base as a shell command
    smFile   # treat base as a filesystem path

  ## User-configurable prefix shortcut.
  Shortcut* = object
    prefix*, label*, base*: string
    mode*: ShortcutMode
    group*: string # optional group label (e.g., "sys")
    runMode*: PowerActionMode = pamTerminal
    stayOpen*: bool = false

  ## What kind of thing the user can pick.
  ActionKind* = enum
    akApp,      # a real .desktop application
    akAppAction,# a .desktop secondary action (e.g. New Window)
    akDmenu,    # a generic stdin-provided entry
    akRun,      # a `:r` shell command
    akConfig,   # `:c` file under ~/.config
    akFile,     # `:s` file search (open with default app)
    akShortcut, # configurable shortcut (URL/shell/file)
    akTheme,    # `:t` Theme selector
    akPlaceholder

  ## A single selectable entry in the launcher.
  Action* = object
    kind*: ActionKind
    label*: string       # what gets drawn (e.g. "Firefox" or "Run: ls")
    exec*: string        # what actually gets executed or opened
    appIndex*: int = -1  # index into ctx.allApps for akApp/akAppAction; -1 otherwise
    dmenuIndex*: int = -1 # index into ctx.dmenuItems for stdin rows; -1 for typed text
    iconName*: string
    desktopName*, desktopIcon*: string
    shortcutMode*: ShortcutMode = smUrl
    powerMode*: PowerActionMode = pamTerminal
    stayOpen*: bool = false
    spans*: seq[(int, int)] ## matched (byte offset, byte length) ranges of label

  VimCommandState* = object
    prefix*: string
    buffer*: string
    lastSearch*: string
    pendingG*: bool
    active*: bool
    savedInput*: string
    savedSelectedIndex*: int
    savedViewOffset*: int
    restorePending*: bool

  ## Theme definition (matchFgColorHex is explicit; no "auto" support).
  Theme* = object
    name*: string
    bgColorHex*: string
    fgColorHex*: string
    highlightBgColorHex*: string
    highlightFgColorHex*: string
    borderColorHex*: string
    matchFgColorHex*: string ## leave empty to inherit Config.matchFgColorHex

  AppContext* = object
    config*: Config
    allApps*: seq[DesktopApp]
    inputText*: string
    inputCursor*: int ## byte offset into inputText, on a UTF-8 boundary
    lastInputChangeMs*: int64
    selectedIndex*: int
    viewOffset*: int
    shouldExit*: bool
    recentApps*: seq[string]
    appUsage*: Table[string, AppUsage]
    themeList*: seq[Theme]
    shortcuts*: seq[Shortcut]
    groupQueryModes*: Table[string, GroupQueryMode]
    configFilesLoaded*: bool
    configFilesCache*: seq[DesktopApp]
    vim*: VimCommandState
    themePreviewActive*: bool
    themePreviewBaseTheme*: string
    themePreviewCurrent*: string
    dmenuMode*: bool
    dmenuItems*: seq[DmenuItem]
    dmenuIndexMode*: bool ## print the input line index instead of its text
    dmenuAccepted*: bool
    dmenuDryRunAccepted*: bool
    dmenuOutput*: string
    dmenuPrompt*: string
    listThemesMode*: bool
    dryRunMode*: bool
    verboseMode*: bool
    configOverridePath*: string
    actions*: seq[Action]

var ctx*: AppContext

# ── Constants ───────────────────────────────────────────────────────────
const
  ## Hard-coded terminal fallback search order.
  fallbackTerms* = [
    "kitty", "alacritty", "wezterm", "foot",
    "gnome-terminal", "konsole", "xfce4-terminal", "xterm"
  ]
  maxRecent* = 10

import ./default_config
export default_config
