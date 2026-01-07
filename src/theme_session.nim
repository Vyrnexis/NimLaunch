## theme_session.nim — theme preview lifecycle helpers.

import ./[state, settings]

proc beginThemePreviewSession*() =
  if not themePreviewActive:
    themePreviewActive = true
    themePreviewBaseTheme = config.themeName
    themePreviewCurrent = config.themeName

proc endThemePreviewSession*(persist: bool) =
  if not themePreviewActive:
    return
  if persist:
    themePreviewBaseTheme = config.themeName
    themePreviewCurrent = config.themeName
  else:
    if themePreviewBaseTheme.len > 0 and themePreviewCurrent.len > 0 and
       themePreviewCurrent != themePreviewBaseTheme:
      applyThemeAndColors(config, themePreviewBaseTheme)
      themePreviewCurrent = themePreviewBaseTheme
  themePreviewActive = false

proc updateThemePreview*(isThemeCmd: bool; actions: seq[Action]; selectedIndex: int) =
  if not isThemeCmd:
    return
  if actions.len == 0:
    endThemePreviewSession(false)
    return
  beginThemePreviewSession()
  if selectedIndex < 0 or selectedIndex >= actions.len:
    return
  let act = actions[selectedIndex]
  if act.kind != akTheme:
    return
  let name = act.exec
  if themePreviewCurrent == name:
    return
  applyThemeAndColors(config, name)
  themePreviewCurrent = name
