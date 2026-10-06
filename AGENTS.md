# WinMouse

A macOS menu-bar app that makes an external mouse behave the way it does on Windows: the
"Enhance pointer precision" curve with the pointer speed slider, and Chrome/Edge-style wheel
scrolling (fixed lines per notch, a short ease-in-out, no acceleration).

## Rules

- Apple frameworks only, the ones the app already imports; no third-party packages.
- Settings live in the app's own `UserDefaults` domain. Never write to the global defaults domain
  or to system preference files.
- HID properties are set per external-mouse service only. Their original values are kept and put
  back on quit, when the app is switched off, when the pointer feature is turned off, and when the
  user session resigns.
- Trackpads (built-in or Magic Trackpad) stay untouched.
- Idle is free: no timers or polling while nothing moves, apart from the 5 s tap health check and
  the 2 s Accessibility poll that runs only while permission is missing.
- The event tap's mask is scroll-wheel only. Never tap mouse-moved or dragged events.
- Every constant comes from `docs/research/*.md`. Change one only together with new evidence there.
- Hardware behaviour counts as verified only after the physical-mouse checks in `docs/testing.md`;
  until then, report it as unverified.
- Pushing a `v*` tag publishes a GitHub prerelease. Ask before tagging, and follow
  `docs/releasing.md`.

## Build and test

- `./build.sh` runs the self-test, then builds the universal `build/WinMouse.app`;
  `./build.sh selftest` runs only the self-test. Keep the build on plain `swiftc` in `build.sh`:
  SwiftPM cannot run inside a sandboxed shell.
- The self-test compiles only the files in `build.sh`'s `TESTED` array (`WindowsPointer.swift`,
  `ScrollAnimation.swift`) against the vectors in `docs/research`. A newly tested file joins that
  array and stays free of AppKit and event taps. Tests live in `Sources/SelfTest/*Tests.swift` and
  use `check(condition, message)`.
- `Sources/WinMouse/Settings.swift` is the settings type every module reads. `docs/architecture.md`
  maps the runtime flow and permissions.
