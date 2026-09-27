# WinMouse

A macOS menu-bar app that makes an external mouse behave the way it does on Windows: the
"Enhance pointer precision" curve with the pointer speed slider, and Chrome/Edge-style wheel
scrolling (fixed lines per notch, a short ease-in-out, no acceleration).

## Rules

- No dependencies: AppKit, SwiftUI, IOKit, CoreGraphics and QuartzCore only.
- Never write to the global defaults domain or to system preference files. HID properties are set
  per external-mouse service only; their original values are kept and put back on quit, when the
  app is switched off, and when a feature is turned off.
- Never touch trackpads (built-in or Magic Trackpad).
- Idle cost is zero: no timers or polling while nothing moves, apart from the 5 s tap health check.
- Event taps see scroll-wheel events only. Never tap mouse-moved or dragged events.
- Every constant comes from `docs/research/*.md`. Change one only together with new evidence there.

## Build and test

- `./build.sh` compiles and runs `build/selftest` (reference vectors from `docs/research`), then
  builds `build/WinMouse.app` with plain `swiftc`. SwiftPM does not run inside the agent sandbox.
- `./build.sh selftest` runs only the self-test.

## Layout

- `Sources/WinMouse`: the app. `Settings.swift` is the settings type every module reads.
- `Sources/SelfTest`: `main.swift` plus one `*Tests.swift` per module, using `check(condition, message)`.
- `Resources`: `Info.plist` and the `*.lproj` string tables.
- `docs/research`: the evidence behind every number.
