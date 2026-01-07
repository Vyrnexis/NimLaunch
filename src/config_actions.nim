## config_actions.nim — ~/.config discovery helpers.

import std/[os]
import ./[state, utils, paths]

proc refreshConfigFiles*() =
  ## Build the cached ~/.config file list once per run.
  configFilesCache.setLen(0)
  let base = userConfigHome()
  try:
    for path in walkDirRec(base, yieldFilter = {pcFile}):
      let fn = path.extractFilename
      if fn.len == 0: continue
      configFilesCache.add DesktopApp(
        name: fn,
        exec: "xdg-open " & shellQuote(path),
        hasIcon: false
      )
  except CatchableError as e:
    echo "refreshConfigFiles warning: ", e.name, " ", e.msg
  configFilesLoaded = true

proc ensureConfigFiles*() =
  if not configFilesLoaded:
    refreshConfigFiles()
