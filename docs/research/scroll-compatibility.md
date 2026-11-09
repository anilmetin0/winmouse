# Browser scroll sequences

2026-11-08, follow-up to [issue #3](https://github.com/anilmetin0/winmouse/issues/3).

The report describes skipping roughly ten YouTube Shorts or Facebook Reels when scrolling.
It does not identify the mouse, browser, display refresh rate or macOS version. The reporter's
hardware behavior remains unverified.

## Evidence

Running the real `WheelAxis` at the default three lines per notch produces 12 nonzero pixel
events at 60 Hz, 22 at 120 Hz and 27 at 144 Hz, over the same 200 ms / 100 pt trajectory.
The old event construction gave every frame a zero scroll phase. The distance was correct;
the independent-frame representation is the compatibility problem being addressed.

The live YouTube Shorts page inspected on 2026-11-08 used `scroll-snap-type: y mandatory` on
`#shorts-container`. This establishes the use of snapping, not an end-to-end reproduction of
the report. Reels was not inspected behind an authenticated account.

Chromium's `MouseWheelPhaseHandler::AddPhaseIfNeededAndScheduleEndEvent` distinguishes explicit
scroll phases from its synthesized, timer-based wheel sequences. Without phases it may break
latching when the position, modifiers or direction change. Explicit Begin/Changed/End is the
browser's scroll-sequence contract:

- [Chromium source at 8f8a5de4](https://github.com/chromium/chromium/blob/8f8a5de4fa8280aa457ccebd06c99ba9c2d8ff5e/content/browser/renderer_host/input/mouse_wheel_phase_handler.cc)
- [Apple NSEvent.phase](https://developer.apple.com/documentation/appkit/nsevent/phase)
- Local CG-to-AppKit phase mapping and SDK values: [macos-hid.md §5.2](macos-hid.md)

## Delivery contract

Smooth output to Safari, Chrome/Chromium, Edge, Firefox, Brave, Vivaldi, Opera and Arc uses
one Begin, zero or more Changed events, and one zero-delta End per animation. The bundle-ID
allowlist is the browsers' standard macOS application identifiers, including the development
variants listed by `groupsWheelFrames`. Native apps retain phase-free output to avoid turning
on their trackpad elasticity. Unsmoothed output remains one phase-free event per notch.

CG phase values are Begin = 1, Changed = 2, End = 4, Cancelled = 8; these are **not** the
NSEventPhase bit values. The mapping is checked against real NSEvents in the self-test.
No momentum phases, type-29 gesture events, acceleration or extra distance are added.

The first notch's location and receiving process stay fixed through an animation. Settings
changes, app activation, tap interruption, modifier gestures and native continuous input cancel
the old sequence and discard its remaining distance. This prevents wheel tails reaching another
app or mixing with a trackpad. Synthetic output has no HID sender and is never transformed again.

## Verification boundary

`Sources/SelfTest/ScrollTests.swift` checks the actual event builder, AppKit's phase decoding,
100 pt totals in both directions at 60/120/144 Hz, horizontal cancellation, a fresh gesture after
cancellation, phase-free native output and duplicate-End suppression. The reference curve and
its constants are unchanged. Physical mouse acceptance on Shorts/Reels, Safari boundary behavior
and mixed-refresh displays remain release follow-up checks; do not claim those passed.

## Lost scrolling after restart

2026-11-09: the reporter confirmed the feed-skipping change works with a TUF Gaming M3 connected
through a hub, Firefox, a 120 Hz display and macOS Sequoia 15.8.2. They then reported no wheel
scrolling after restarting their Mac, with pointer movement and the middle button still working
([follow-up](https://github.com/anilmetin0/winmouse/issues/3#issuecomment-6731821037)).

`python3 scripts/test-scroll-routing.py` reproduces a delivery failure with the production
`MouseTap.wheel` → `post` → `deliver` path on macOS 27.2 (26B123). The fixture creates a fresh
AppKit scroll view, supplies a discrete notch and a valid target PID, and measures the view's
actual scroll offset. It creates no HID tap and writes no device properties. Smooth scrolling
is off to isolate event delivery from display callbacks.

| Delivery | View displacement for one downward notch |
| --- | --- |
| 0.3.0, new pixel event sent with `postToPid` | 0 pt |
| Control, same pixel distance sent at `cgSessionEventTap` | 100 pt |
| Fixed `MouseTap`, sent at `cgSessionEventTap` | 100 pt |
| Fixed `MouseTap`, original target window is no longer key | 100 pt |

The pre-fix failure repeated in two fresh launches with `CGPreflightPostEventAccess() == true`.
The control rules out a missing posting permission; disabling smoothing rules out the frame clock
for this reproduction. This establishes a real lost-scroll path, without establishing that a
reboot itself causes it or that this is the only failure on the reporter's Sequoia installation.

Apple's SDK `CGEvent.h` documents that `CGEventPostToPid` inserts events immediately before the
target process's taps; session posting enters the normal session event stream. The generated
pixel event has not been annotated with a receiving window. Passing it through the session lets
WindowServer route it before AppKit delivery. See also
[CGEventTapLocation](https://developer.apple.com/documentation/coregraphics/cgeventtaplocation),
which distinguishes the session and annotated-session stages.

All output, including End/Cancelled, now uses session posting at the first notch's saved location.
The saved PID still identifies the browser and detects target changes; it is not a posting route.
Browser phases, distance, timing, cancellation and the event-tap mask are unchanged. This adds no
timer or polling. Hardware restart acceptance on Sequoia 15.8.2 remains pending.
