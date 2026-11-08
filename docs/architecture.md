# Architecture

WinMouse is a menu bar app built with AppKit, SwiftUI, IOKit, CoreGraphics, and QuartzCore. It has
no third-party dependencies. `build.sh` compiles the app directly with `swiftc` for Apple Silicon
and Intel Macs.

## Runtime flow

`App.swift` owns the app lifecycle. It loads `Settings`, creates the menu bar item and settings
window, and sends setting changes to `PointerController` and `MouseTap`.

`PointerController.swift` watches HID device notifications and finds each external Generic Desktop
Mouse service. It skips services marked built-in. For a selected service it saves the prior pointer
table and algorithm on that service, then installs the generated Apple-format table. It restores
those values when disabled, when the user session resigns, and on quit. On launch it checks for a
leftover WinMouse marker and attempts recovery. This path uses private macOS HID interfaces and has
not been validated with a physical mouse yet.

`MouseTap.swift` creates one CoreGraphics event tap for scroll-wheel events and other-button
presses and releases, on its own thread. For the wheel it leaves continuous events, events with
phases, synthetic events without a sender, game-category apps, and Command/Option gestures alone.
Control + wheel becomes Command-= or Command-- per notch unless macOS Zoom uses that gesture. The
remaining discrete notches become configured distances, animated with `ScrollAnimation.swift` and
posted as pixel scroll events. Supported browsers get Begin/Changed/End scroll phases for one
animation; native apps retain phase-free output. No momentum or companion gesture events are
generated. The original notch's position and available target PID are kept through the animation.
App switches, setting changes and native scrolling cancel a pending wheel tail.
`WheelEvents.swift` holds the event-field helpers and tested scroll-sequence builder.

For buttons 3 and 4, `Buttons.swift` decides per frontmost app: pass the button through (apps that
handle it, and every unknown app), or hold the press back and post the app's Back/Forward shortcut
on release. The tap requires Accessibility access. A five-second health check runs only while the
tap is active; the animation driver pauses while idle.
Missing Accessibility access is retried when the app becomes active or its menu opens, without
an additional permission-polling timer.

`WindowsPointer.swift` builds the pointer curve and Apple-format HID table. `ScrollAnimation.swift`
contains the wheel distance and easing model, and `Buttons.swift` the per-app button mapping. Their pure calculations are covered by the self-test
vectors in `Sources/SelfTest` and the evidence in `docs/research`.

## State and permissions

- User settings live in the app's own `UserDefaults` domain. WinMouse does not write global defaults.
- Pointer changes are stored per HID service. The original table and algorithm are held in the
  service marker to recover values after a crash.
- Scrolling and the side buttons need Accessibility permission because WinMouse intercepts wheel
  and button events and posts scroll and key events.
  Pointer-table writes do not use that permission path.
- Open-at-login uses `SMAppService.mainApp` and is opt-in in Settings.
- Update checks/downloads contact GitHub only when requested. There is no update timer or telemetry.
- `Updater.swift` owns the update window and request/cancellation state. `UpdateSupport.swift`
  validates stable release metadata, exact asset URLs, sizes, hashes, bundles and Homebrew receipts.
  The signed helper in `Contents/MacOS` waits for normal shutdown before replacing or upgrading
  the app and reopening it. Manual replacements keep a rollback copy until launch succeeds.

## Platform limits

The pointer controller uses private HID interfaces. macOS can change them between releases. macOS
also measures pointer speed differently from Windows for diagonal movement; see
[`windows-pointer.md`](research/windows-pointer.md) and [`macos-hid.md`](research/macos-hid.md).

The event tap distinguishes classic wheel events from continuous scrolling by event fields, then
requires a nonzero sender ID. Some high-resolution wheels and vendor drivers may report differently.
Hardware coverage is still needed; see [`testing.md`](testing.md).
