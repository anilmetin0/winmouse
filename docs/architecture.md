# Architecture

WinMouse is a menu bar app built with AppKit, SwiftUI, IOKit, CoreGraphics, and QuartzCore. It has
no third-party dependencies. `build.sh` compiles the app directly with `swiftc` for Apple Silicon
and Intel Macs.

## Runtime flow

`App.swift` owns the app lifecycle. It loads `Settings`, creates the menu bar item and settings
window, and sends setting changes to `PointerController` and `ScrollEngine`.

`PointerController.swift` watches HID device notifications and finds each external Generic Desktop
Mouse service. It skips services marked built-in. For a selected service it saves the prior pointer
table and algorithm on that service, then installs the generated Apple-format table. It restores
those values when disabled, when the user session resigns, and on quit. On launch it checks for a
leftover WinMouse marker and attempts recovery. This path uses private macOS HID interfaces and has
not been validated with a physical mouse yet.

`ScrollEngine.swift` creates a CoreGraphics event tap for scroll-wheel events only. It leaves
continuous events, events with phases, synthetic events without a sender, game-category apps, and
Command/Option/Control gestures alone. For the remaining discrete wheel events it converts notches
to configured distances, animates them with `ScrollAnimation.swift`, and posts pixel scroll events.
The event tap requires Accessibility access. A five-second health check runs only while the tap is
active; the animation driver pauses while idle.

`WindowsPointer.swift` builds the pointer curve and Apple-format HID table. `ScrollAnimation.swift`
contains the wheel distance and easing model. Their pure calculations are covered by the self-test
vectors in `Sources/SelfTest` and the evidence in `docs/research`.

## State and permissions

- User settings live in the app's own `UserDefaults` domain. WinMouse does not write global defaults.
- Pointer changes are stored per HID service. The original table and algorithm are held in the
  service marker to recover values after a crash.
- Scrolling needs macOS Accessibility permission because WinMouse intercepts and posts wheel events.
  Pointer-table writes do not use that permission path.
- Open-at-login uses `SMAppService.mainApp` and is opt-in in Settings.
- The app does not include network code or telemetry.

## Platform limits

The pointer controller uses private HID interfaces. macOS can change them between releases. macOS
also measures pointer speed differently from Windows for diagonal movement; see
[`windows-pointer.md`](research/windows-pointer.md) and [`macos-hid.md`](research/macos-hid.md).

The event tap distinguishes classic wheel events from continuous scrolling by event fields, then
requires a nonzero sender ID. Some high-resolution wheels and vendor drivers may report differently.
Hardware coverage is still needed; see [`testing.md`](testing.md).
