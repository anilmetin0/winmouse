# WinMouse

A macOS menu-bar app that makes an external mouse behave the way it does on Windows: the
"Enhance pointer precision" curve with the pointer speed slider, Chrome/Edge-style wheel
scrolling (fixed lines per notch, a short ease-in-out, no acceleration), Ctrl + wheel zoom, and
side buttons that go back and forward in every app.

## Rules

- No dependencies: AppKit, SwiftUI, IOKit, CoreGraphics and QuartzCore only.
- Never write to the global defaults domain or to system preference files. HID properties are set
  per external-mouse service only; their original values are kept and put back on quit, when the
  app is switched off, and when a feature is turned off.
- Never touch trackpads (built-in or Magic Trackpad).
- Idle cost is zero: no timers or polling while nothing moves, apart from the 5 s tap health check.
- The event tap sees scroll-wheel events and other-button presses and releases only. Never tap
  mouse-moved, dragged, left- or right-button events.
- Every constant comes from `docs/research/*.md`. Change one only together with new evidence there.

## Build and test

`./build.sh` compiles and runs `build/selftest` (reference vectors from `docs/research`), then
builds `build/WinMouse.app` with plain `swiftc`. `./build.sh selftest` runs only the self-test.
