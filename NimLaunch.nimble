# Package

version       = "0.1.0"
author        = "DrunkenAlcoholic"
description   = "NimLaunch rewrite in SDL2 for native X11 and Wayland"
license       = "MIT"
srcDir        = "src"
bin           = @["nimlaunch"]


# Dependencies

requires "nim >= 2.0"
requires "sdl2"
requires "parsetoml"


# Build tasks

# Native Nim builds
task nimRelease, "Release build with native compiler":
  mkDir("bin")
  exec "nim c -d:release -d:danger --passC:'-ffunction-sections -fdata-sections' --passL:'-Wl,--gc-sections -s' --opt:size -o:./bin/nimlaunch src/main.nim"

task nimDebug, "Debug build with native compiler":
  mkDir("bin")
  exec "nim c -o:./bin/nimlaunch src/main.nim"

# Zig-based builds (portable)
task zigRelease, "Release build with Zig compiler (portable)":
  mkDir("bin")
  exec "nim c -d:release --cc:clang --clang.exe='./zigcc' --clang.linkerexe='./zigcc' --passC:'-target x86_64-linux-gnu -mcpu=x86_64 -ffunction-sections -fdata-sections' --passL:'-target x86_64-linux-gnu -mcpu=x86_64 -Wl,--gc-sections -s' -o:./bin/nimlaunch ./src/main.nim"

task zigDebug, "Debug build with Zig compiler":
  mkDir("bin")
  exec "nim c --cc:clang --clang.exe='./zigcc' --clang.linkerexe='./zigcc' -o:./bin/nimlaunch ./src/main.nim"
