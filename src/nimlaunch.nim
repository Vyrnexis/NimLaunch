## nimlaunch.nim — default nimble entrypoint.
## Keeps `src/main.nim` as the main implementation module.

import ./main

when isMainModule:
  main()
