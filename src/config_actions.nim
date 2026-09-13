## config_actions.nim — ~/.config discovery helpers.

import std/[os]
import ./[state, paths]

proc loadConfigFiles*() =
  ## Build the cached ~/.config file list once per run.
  ctx.configFilesCache.setLen(0)
  let base = userConfigHome()
  try:
    for path in walkDirDepth(base, maxDepth = 2, yieldFilter = {pcFile}):
      let fn = path.extractFilename
      if fn.len == 0: continue
      ctx.configFilesCache.add DesktopApp(
        name: fn,
        exec: path
      )
    ctx.configFilesLoaded = true
  except CatchableError as e:
    ctx.configFilesLoaded = false
    echo "loadConfigFiles warning: ", e.name, " ", e.msg

proc ensureConfigFilesLoaded*() =
  if not ctx.configFilesLoaded:
    loadConfigFiles()
