## proc_utils.nim — process spawning, terminal selection, and file-opening helpers.

import std/[os, osproc, strutils]
import ./[state, parser]

proc whichExists*(name: string): bool =
  ## True if an executable can be found in $PATH (or is a path that exists).
  if name.len == 0: return false
  if name.contains('/'): return fileExists(name)
  findExe(name).len > 0

proc tryStart(candidates: seq[(string, seq[string])]): bool =
  ## Attempt to start each (exe, args) pair; return true on first success.
  for (exe, args) in candidates:
    if exe.len == 0: continue
    try:
      discard startProcess(exe, args = args, options = {poDaemon, poParentStreams})
      return true
    except CatchableError:
      discard
  false

proc openPathWithDefault*(path: string): bool =
  ## Open a file with the system default handler; fall back to common editors.
  let abs = absolutePath(path)
  if not fileExists(abs): return false

  ## Preferred system openers
  if tryStart(@[(findExe("xdg-open"), @[abs]),
               (findExe("gio"), @["open", abs])]):
    return true

  ## Respect user editor preference
  var envCandidates: seq[(string, seq[string])] = @[]
  for envName in ["VISUAL", "EDITOR"]:
    let ed = getEnv(envName)
    if ed.len == 0:
      continue
    let tokens = tokenize(ed)
    if tokens.len == 0:
      continue
    let head = tokens[0]
    var exePath: string
    if head.contains('/'):
      exePath = expandFilename(head)
      if not fileExists(exePath):
        exePath = ""
    else:
      exePath = findExe(head)
    if exePath.len == 0:
      continue
    var args: seq[string] = @[]
    if tokens.len > 1:
      args = tokens[1 ..< tokens.len]
    args.add abs
    envCandidates.add((exePath, args))
  if tryStart(envCandidates):
    return true

  ## Fallback shortlist
  var fallbackCandidates: seq[(string, seq[string])] = @[]
  for ed in ["gedit", "kate", "mousepad", "code", "nano", "vi"]:
    let exe = findExe(ed)
    if exe.len > 0:
      fallbackCandidates.add((exe, @[abs]))
  if tryStart(fallbackCandidates):
    return true

  false

proc openPathWithFallback*(path: string): bool =
  ## Open files or directories, falling back to xdg-open when needed.
  let resolved = path.expandTilde()
  if openPathWithDefault(resolved): return true
  if dirExists(resolved) or fileExists(resolved):
    try:
      discard startProcess("/usr/bin/env", args = @["xdg-open", resolved], options = {poDaemon})
      return true
    except CatchableError:
      echo "openPathWithFallback failed: ", resolved
  false

proc chooseTerminal*(): string =
  ## Pick a terminal emulator: prefer config.terminalExe, then $TERMINAL, then fallbacks.
  if config.terminalExe.len > 0:
    let tokens = tokenize(config.terminalExe)
    if tokens.len > 0 and whichExists(tokens[0]):
      return config.terminalExe
  let envTerm = getEnv("TERMINAL")
  if envTerm.len > 0:
    let tokens = tokenize(envTerm)
    if tokens.len > 0 and whichExists(tokens[0]):
      return envTerm
  for t in fallbackTerms:
    if whichExists(t):
      return t
  ""  # headless

proc hasHoldFlagLocal*(args: seq[string]): bool =
  ## Detect common "keep window open" flags passed to terminals.
  for a in args:
    case a
    of "--hold", "-hold", "--keep-open", "--wait", "--noclose",
       "--stay-open", "--keep", "--keepalive":
      return true
    else:
      discard
  false

proc appendShellArgs*(argv: var seq[string]; shExe: string; shArgs: seq[string]) =
  ## Append shell executable and its arguments to `argv`.
  argv.add shExe
  for a in shArgs: argv.add a

proc buildTerminalArgs*(base: string; termArgs: seq[string]; shExe: string;
                       shArgs: seq[string]): seq[string] =
  ## Normalize command-line to launch a shell inside major terminals.
  var argv = termArgs
  case base
  of "gnome-terminal", "kgx":
    argv.add "--"
  of "wezterm":
    argv = @["start"] & argv
  else:
    argv.add "-e"
  appendShellArgs(argv, shExe, shArgs)
  argv

proc buildShellCommand*(cmd, shExe: string; hold = false):
    tuple[fullCmd: string, shArgs: seq[string]] =
  ## Run user's command in a group, and add a robust hold prompt when needed.
  ## Grouping prevents suffix binding to pipelines/conditionals.
  let suffix = (if hold: "" else: "; printf '\\n[Press Enter to close]\\n'; read -r _")
  let fullCmd = "{ " & cmd & " ; }" & suffix
  let shArgs = if shExe.endsWith("bash"): @["-lc", fullCmd] else: @["-c", fullCmd]
  (fullCmd, shArgs)

proc runCommand*(cmd: string) =
  ## Run `cmd` in the user's terminal; fall back to /bin/sh if none.
  let bash = findExe("bash")
  let shExe = if bash.len > 0: bash else: "/bin/sh"

  var parts = tokenize(chooseTerminal()) # parser.tokenize on config.terminalExe/$TERMINAL
  if parts.len == 0:
    let (_, shArgs) = buildShellCommand(cmd, shExe)
    try:
      discard startProcess(shExe, args = shArgs,
                           options = {poDaemon, poParentStreams})
    except CatchableError as e:
      echo "runCommand failed: ", cmd, " (", e.name, "): ", e.msg
    return

  let exe = parts[0]
  let exePath = findExe(exe)
  if exePath.len == 0:
    let (_, shArgs) = buildShellCommand(cmd, shExe)
    try:
      discard startProcess(shExe, args = shArgs,
                           options = {poDaemon, poParentStreams})
    except CatchableError as e:
      echo "runCommand failed: ", cmd, " (", e.name, "): ", e.msg
    return

  var termArgs = if parts.len > 1: parts[1..^1] else: @[]
  let base = exe.extractFilename()
  let hold = hasHoldFlagLocal(termArgs)
  let (_, shArgs) = buildShellCommand(cmd, shExe, hold)
  let argv = buildTerminalArgs(base, termArgs, shExe, shArgs)
  try:
    discard startProcess(exePath, args = argv,
                         options = {poDaemon, poParentStreams})
  except CatchableError as e:
    echo "runCommand failed: ", cmd, " (", e.name, "): ", e.msg

proc spawnShellCommand*(cmd: string): bool =
  ## Execute *cmd* via /bin/sh in the background; return success.
  try:
    discard startProcess("/bin/sh", args = ["-c", cmd],
                         options = {poDaemon, poParentStreams})
    true
  except CatchableError as e:
    echo "spawnShellCommand failed: ", cmd, " (", e.name, "): ", e.msg
    false

proc openUrl*(url: string) =
  ## Open *url* via xdg-open (no shell involved). Log failures for diagnosis.
  try:
    discard startProcess("/usr/bin/env", args = @["xdg-open", url],
                         options = {poDaemon, poParentStreams})
  except CatchableError as e:
    echo "openUrl failed: ", url, " (", e.name, "): ", e.msg
