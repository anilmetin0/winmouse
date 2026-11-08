# Existing macOS mouse apps: techniques, failures, and why none feels like Windows

Research date: 2026-09-26. Scope: pointer speed/acceleration and wheel scrolling for an external mouse.

Source code was read first-hand from shallow clones at these commits:

| Repo | Commit | Date | License |
|---|---|---|---|
| linearmouse/linearmouse | `fc7d920a8f76` | 2026-09-25 | MIT |
| noah-nuebling/mac-mouse-fix (`master`, holds the current MMF 3 code; the `version-3` branch is older, last commit `1a87a5f` on 2023-12-23) | `cf708c59f499` | 2026-09-26 | "MMF License" (custom) |
| Caldis/Mos | `8a2fd112e2af` | 2026-08-21 | CC BY-NC 4.0 |
| ther0n/UnnaturalScrollWheels | `07a61a0ddc73` | 2026-08-03 | GPL-3.0 |
| pilotmoon/Scroll-Reverser | `187bf3945b61` | 2025-12-13 | Apache-2.0 |

References of the form `repo/path:line` point into those commits. Inside the per-app tables and bullets, short file names are used; their full paths are:

- Mac Mouse Fix: `Scroll.m`, `ScrollConfig.swift` → `mac-mouse-fix/Helper/Core/Scroll/Scroll.m`, `mac-mouse-fix/Helper/Core/Config/ScrollConfig.swift`; `PointerSpeed.m` → `mac-mouse-fix/Helper/Core/PointerSpeed/PointerSpeed.m`; `PointerConfig.swift` → `mac-mouse-fix/Helper/Core/Config/PointerConfig.swift`; `AccessibilityCheck.m` → `mac-mouse-fix/Helper/AccessibilityCheck.m`; `default_config.plist` → `mac-mouse-fix/Shared/Config/default_config.plist`; `SwitchMaster.swift` → `mac-mouse-fix/Helper/Core/Coordinate/SwitchMaster.swift`; `Readme.md` → `mac-mouse-fix/Markdown/Templates/Readme.md`.
- LinearMouse: `EventTap.swift`, `EventThread.swift`, `EventType.swift`, `GlobalEventTap.swift`, `GlobalEventTapWatchdog.swift` → `linearmouse/LinearMouse/EventTap/`; `*Transformer.swift`, `EventTransformerManager.swift` → `linearmouse/LinearMouse/EventTransformer/`; `ScrollWheelEventView.swift` → `linearmouse/LinearMouse/EventView/`; `Device.swift`, `DeviceManager.swift` → `linearmouse/LinearMouse/Device/`; `Smoothed.swift` → `linearmouse/LinearMouse/Model/Configuration/Scheme/Scrolling/`; `PointerDevice.swift`, `PointerDeviceManager.swift` → `linearmouse/Modules/PointerKit/Sources/PointerKit/`.
- Mos: `ScrollCore.swift`, `ScrollPoster.swift`, `ScrollEvent.swift`, `ScrollUtils.swift`, `ScrollDispatchContext.swift`, `ScrollFilter.swift`, `Interpolator.swift` → `Mos/Mos/ScrollCore/`; `Interceptor.swift`, `Constants.swift` → `Mos/Mos/Utils/`.
- UnnaturalScrollWheels: `ScrollInterceptor.swift`, `AppDelegate.swift`, `Options.swift` → `UnnaturalScrollWheels/UnnaturalScrollWheels/`.
- Scroll-Reverser: `MouseTap.m`, `AppDelegate.m`, `PrefsWindowController.m` → `Scroll-Reverser/` (repo root).

Sections marked **(from subagent)** were collected by helper agents (issue trackers, SmoothMouse, code search, closed-app docs). Items marked (checked) inside those sections I re-opened myself.

---

## 0. Short answer

- **Nobody among the five implements a Windows "Enhance pointer precision" (EPP) curve.** LinearMouse only drives Apple's own acceleration (index 0-40, pointer resolution, Sonoma's linear toggle). Mac Mouse Fix has unshipped code that writes custom Apple curves and gave up because the HID driver's curve keys cannot be removed/overridden reliably. Mos and Scroll-Reverser do not touch the pointer. UnnaturalScrollWheels can only switch acceleration off globally. The only Mac app that ever emulated the Windows curve was SmoothMouse, which replaced the system driver with a kext and stopped at macOS Sierra (section 1.5).
- **Scrolling:** MMF and Mos replace the wheel with a trackpad-like inertial animation (MMF on raw ticks with its own speed curve, Mos on top of macOS's already-accelerated pixel deltas). LinearMouse can do either. LinearMouse, UnnaturalScrollWheels and Scroll-Reverser can force "N lines per notch" but post it unsmoothed, so the page jumps a full step per notch. No app combines "fixed distance per notch, no acceleration" with a short, momentum-free animation.
- **Reliability** is the other complaint: settings lost after wake or reconnect, taps disabled or leaked, display-link stutter, and trackpad-style side effects such as rubber-banding and swipe navigation (sections 3 and 7).

---

## 1. Pointer speed and acceleration

### 1.1 Mac Mouse Fix (MMF 3, `master`)

Status: **not shipped.** Every entry point is guarded by `assert(false); /// Don't use this, yet, because feature not implemented` (`mac-mouse-fix/Helper/Core/PointerSpeed/PointerSpeed.m:59`, `:87`), and the per-device call is commented out with the reason "Seems that parametric curves are always set under Ventura, so we can't use tableBased curves :/ And in its current form this code will always crash" (`mac-mouse-fix/Shared/Devices/DeviceManager.m:243-246`). The public readme says MMF does not change pointer acceleration and points users to the Sonoma+ system toggle (`mac-mouse-fix/Markdown/Templates/Readme.md:397-404`).

What the unshipped code does (useful as a map of the private API surface):

- **Target:** a per-device `IOHIDServiceClient` for the `AppleUserHIDEventDriver` child of the device's `IOHIDInterface` (`PointerSpeed.m:493-506`), obtained through a *passive* event-system client `IOHIDEventSystemClientCreateWithType(..., HIDEventSystemClientTypePassive, NULL)` plus `IOHIDEventSystemClientCopyServiceForRegistryID` (both private, declared by hand at `PointerSpeed.m:25-36`, used at `:389-402`).
- **Sensitivity:** `kIOHIDPointerResolutionKey` = `400 / sensitivity` as IOFixed (16.16). "400 is the default (unchangeable) pointer resolution"; smaller = faster; "This only seems to do anything if we set the acceleration preset right afterwards" (`PointerSpeed.m:183-203`).
- **Preset curve:** `kIOHIDMouseAccelerationType` ("HIDMouseAcceleration") = IOFixed index; 0.0-3.0 matches the System Settings slider / `com.apple.mouse.scaling`; negative disables acceleration but also raises sensitivity (`PointerSpeed.m:205-227`). Default when unset is 0.6875 (`mac-mouse-fix/Helper/Core/Config/PointerConfig.swift:381-392`).
- **Custom parametric curve:** write an array of dicts to `kHIDAccelParametricCurvesKey` ("HIDAccelCurves") with `kHIDAccelIndexKey`, `kHIDAccelGainLinear/Parabolic/Cubic/QuarticKey`, `kHIDAccelTangentSpeedLinearKey`, `kHIDAccelTangentSpeedParabolicRootKey` (all IOFixed), then select it by setting the preset index to the same arbitrary index (123) (`PointerSpeed.m:229`, `:258-292`). Apple's curve family is `f(x) = ax + (bx)^2 + (cx)^3 + (dx)^4` with caps (`PointerConfig.swift:303`); MMF's parameter fitting is in `PointerConfig.swift:287-362` and `mac-mouse-fix/Helper/Core/Config/Gain Curve Math.tex`.
- **Custom table curve:** `kIOHIDPointerAccelerationTableKey` with a CFData table built by `IOHIDAccelerationTableBridge.mm` (`PointerSpeed.m:231-256`, `:312-321`).
- **Why it was abandoned (author's notes):**
  - "Once parametricCurves are set we don't know of a way to remove them again. And they override tableBasedCurves." (`PointerSpeed.m:296-298`) and "TODO: This is always true under Ventura!" (`:315`).
  - Removing properties from the registry entry does not work (StackOverflow question linked at `PointerSpeed.m:443`); to restore defaults MMF would have to re-write the curves that keyboards carry in `IOHIDEventDriver.kext/Contents/Info.plist` ("This is a really ugly solution", `PointerConfig.swift:393-418`).
  - `kIOHIDUserPointerAccelCurvesKey` "setting curves to that value doesn't do anything" (`PointerConfig.swift:397`).
  - "Setting a number crashes the window server under 12.4 Monterey" (`PointerSpeed.m:326`); "CRASH when u set kHIDAccelParametricCurvesKey to sth weird" (`:478`).
  - Reapplying after sleep/display changes was suspected but never built ("The CursorSense source code makes me think that happens after the computer wakes up from sleep or after a new display has been attached", `PointerSpeed.m:44-53`).
- **Polling-rate observation:** Apple's accelerator treats the raw per-report delta as "speed", so a 1000 Hz mouse sees 1/8 the deltas of a 125 Hz mouse at the same hand speed and the curve "won't kick in properly"; MMF planned to compensate by scaling sensitivity and curve coefficients (`PointerConfig.swift:12-34`, `:204-205`, `:346-350`). Relevant to us: a Windows-EPP clone must work from counts-per-time, not counts-per-report.

### 1.2 LinearMouse

Status: **shipped, per device, Apple curves only.**

- **Client:** `IOHIDEventSystemClientCreate` + matching GenericDesktop Mouse/Pointer, scheduled on the main queue (`linearmouse/Modules/PointerKit/Sources/PointerKit/PointerDeviceManager.swift:108-150`). Properties are written with `IOHIDServiceClientSetProperty` on each device's service client (`PointerDevice.swift:248-275`).
- **Keys and values** (`linearmouse/Modules/PointerKit/Sources/PointerKit/PointerDevice.swift:397-470`):
  - `kIOHIDPointerResolutionKey`, IOFixed, clamped 10...1995; after writing it, the acceleration value is re-written as a "HACK ... to make `pointerResolution` take effect" (`:406-417`). UI "speed" 0...1 maps to resolution through `1/1200 ... 1/40` (`linearmouse/LinearMouse/Device/Device.swift:681-711`).
  - Acceleration key = the device's `kIOHIDPointerAccelerationTypeKey` value, usually `HIDMouseAcceleration` (`PointerDevice.swift:419-437`), IOFixed, range `[0, 40] ∪ {-1}` (`:450-468`; config clamp `linearmouse/LinearMouse/Model/Configuration/Scheme/Pointer.swift:7-12`).
  - `HIDUseLinearScalingMouseAcceleration` (Sonoma+, nil on older systems) for "disable acceleration" (`PointerDevice.swift:439-448`, `Device.swift:649-663`). With it set to 1 the acceleration value is used as a plain tracking speed (`linearmouse/LinearMouse/Device/DeviceManager.swift:961-979`); on pre-Sonoma it writes `-1` instead (`:978`).
- **Re-apply triggers:** configuration change, active display change, frontmost app change (schemes can be per app/display) (`DeviceManager.swift:758-797`); device add (`:845`); resume after sleep (`:288`); and whenever the event system reports a change of `HIDMouseAcceleration`, `HIDTrackpadAcceleration`, `HIDPointerResolution` or `HIDUseLinearScalingMouseAcceleration`, i.e. it fights System Settings or other tools that rewrite them (`DeviceManager.swift:168-180`). Sleep/wake and session switches go through a lifecycle reconcile (`linearmouse/LinearMouse/AppDelegate.swift:163-193`).
- **Restore:** captures the device's initial resolution and linear-scaling flag at attach (`Device.swift:296-298`), reads the system-wide acceleration from `IOHIDSystem` via `IOHIDCopyCFTypeParameter` (`DeviceManager.swift:1060-1085`) and writes them back on teardown (`Device.swift:713-760`).
- Also: hardware DPI and hi-res wheel on Logitech devices over HID++ (`Device.swift:453-505`), outside our scope.

### 1.3 UnnaturalScrollWheels

- Global on/off only: `IOHIDEventSystemClientCreateSimpleClient` + `IOHIDEventSystemClientSetProperty(client, kIOHIDMouseAccelerationType, -1)` ("Based on https://github.com/apsun/NoMouseAccel") (`UnnaturalScrollWheels/UnnaturalScrollWheels/AppDelegate.swift:130-160`). Note it writes the raw Int32 `-1`, not IOFixed -1.0; any negative value turns Apple's curve off.
- Remembers the original value (default `45056` = 0.6875 in 16.16, `Options.swift:13`) and restores it in `applicationWillTerminate` only (`AppDelegate.swift:45-48`), so a crash or kill leaves acceleration off. A nil read after wake used to crash the app (`AppDelegate.swift:136-150`). No re-apply on wake or reconnect (the wake observer only re-enables the scroll tap, `ScrollInterceptor.swift:178-195`). `DisableMouseAccel.swift` is an empty file.

### 1.4 Mos, Scroll-Reverser

No pointer speed or acceleration code (searched for `HIDMouseAcceleration`, `PointerResolution`, `IOHIDServiceClientSetProperty`, `IOHIDEventSystemClientSetProperty`, `mouse.scaling`; no hits outside event-type enums).

### 1.5 SmoothMouse (2012-2016): the only app that emulated the Windows curve

The original repository is gone. A standalone copy of the daemon, preference pane and installer survives at https://github.com/capitalfuse/SmoothMouse (commit `f91a4b2`, 2014-01-10). The kext source is not in it, so how the kext hooked the system is `unverified`. Paths below are relative to that copy; items marked (checked) I read myself, the rest is **(from subagent)**.

- **Input:** a kext (`com.cyberic.smoothmouse`) handed raw `dx`, `dy`, buttons, timestamp and a sequence number to the daemon through an IODataQueue; the reader thread ran with a Mach real-time policy (`SmoothMouseDaemon/Daemon.mm:149-208`, `KextProtocol.h:9-22`, `Prio.mm:44-86`). The developer wrote that SmoothMouse "didn't tweak the default driver … it took its place" (https://dae.me/blog/2144/on-macos-sierra-support-and-the-future-of-smoothmouse/).
- **Curve** (checked, `SmoothMouseDaemon/libpointing/WindowsFunction.cpp`, ported from libpointing):
  - points X = {0, 0.43, 1.25, 3.86, 40}, Y = {0, 1.37, 5.30, 24.30, 568}, the Windows XP/7 `SmoothMouseXCurve`/`SmoothMouseYCurve` defaults (`:105-106`);
  - "speed" of one HID report = max(|dx|,|dy|) + min(|dx|,|dy|)/2, no timestamps (`:178-179`);
  - gain = slope + intercept/speed of the segment that contains speed/3.5 (`:121`); pixel gain = (96/150) × (sensitivity/10) × gain / 3.5 (`:164`, `:172`, `:178-185`); sensitivity = 10 + 2 × slider (`:67`);
  - when speed climbs into a higher segment, the gain is averaged with the previous segment's (`:187-196`);
  - sub-pixel remainders carry over to the next report ("Windows 7 does not clear remainders", `:162`); output is truncated toward zero (`:199-231`).
- **Windows 8 and later use other constants.** SDL3 (zlib license) reads the same registry keys and falls back to Windows 8+ defaults Y = 0x000111fd, 0x00042400, 0x0012fc00, 0x01bbc000 (≈ 1.07, 4.14, 18.98, 443.75) with a denominator of 120 instead of 150 (checked, `libsdl-org/SDL@a19bac6:src/video/windows/SDL_windowsmouse.c:858-889`, `:905`). That is a license-clean reference for our curve; the exact Windows 10/11 math belongs to the Windows-pointer research.
- **Output:** the default driver posted relative moves with `IOHIDPostEvent(..., kIOHIDSetRelativeCursorPosition)` (checked, `SmoothMouseDaemon/Driver.mm:342-349`); another mode posted `kCGEventMouseMoved` with `kCGMouseEventDeltaX/Y` at `kCGSessionEventTap` (checked, `Driver.mm:290-292`). Buttons and click counts were re-posted as well (`Driver.mm:453-561`, `mouse.mm:157-170`).
- **macOS acceleration** was set to 0.0 with `IOHIDSetAccelerationWithKey` and restored on quit (checked, `SmoothMouseDaemon/SystemMouseAcceleration.mm:49`, `:84`, `:119`); a supervisor loop wakes every 500 ms (checked, `Daemon.mm:25`, `:451`) and re-applies it (`Daemon.mm:425-453`).
- **Workarounds it needed:** its own cursor position clamped to display bounds (`mouse.mm:84-116`); resync on clicks, sequence gaps and mismatching deltas (`MouseSupervisor.mm:31-67`); a per-app exclusion list that disconnects the kext (`Daemon.mm:246-281`); a hard-coded list of games and pro apps (`Config.mm:193-217`); an installer that refuses to run next to SteerMouse, USB Overdrive, ControllerMate or Logitech kexts (`Installer/Distribution.xml:38-47`).
- **What broke:** the 1.0.5-1.0.10 changelogs list games unable to capture the pointer, hot corners firing inside games, Ableton knobs, Qt apps, Lightroom tools, WoW mouse-look, and "pressing and holding a mouse button may cause the mouse pointer to become extremely sensitive or stop moving at all" (https://web.archive.org/web/2015id_/http://smoothmouse.com/changelog/1.0.7, same path for 1.0.5 and 1.0.9). In 2016 the developer wrote that `CGEventPost` skipped movements under GPU load, `IOHIDPostEvent` had "a serious bug" with Steam games and Screen Zoom, and Sierra removed calls SmoothMouse needed (dae.me/blog/2144). His later revival bounty lists what was still missing: read raw x/y per device, stop the system driver from moving the pointer for that device, and inject relative motion without breaking games, shake-to-locate or zoom (https://dae.me/blog/2243/macos-kernel-programming-bounty-to-revive-smoothmouse/).
- In the macOS 27 SDK, `IOHIDPostEvent` is deprecated since 11.0 with "Use CGSEventTap for posting HID events, IOHIDUserDevice for simulating HID device…" and `IOHIDSetAccelerationWithKey` since 10.12 (checked, `IOKit.framework/Headers/hidsystem/IOHIDLib.h:60-68`, `:99`).

### 1.6 Other open-source code that touches the HID acceleration keys (from subagent unless marked)

No project was found that writes a Windows-shaped curve into `HIDAccelCurves`, `HIDPointerAccelerationTable` or `HIDUserPointerAccelCurves`. The search used Sourcegraph because grep.app was rate-limited.

- Keys that are public in the macOS 27 SDK (checked): `kIOHIDUseLinearScalingMouseAccelerationKey` = "HIDUseLinearScalingMouseAcceleration" (`IOKit.framework/Headers/hid/IOHIDEventServiceKeys.h:182`), `kHIDAccelParametricCurvesKey` (`IOHIDEventServiceKeys.h:165`), `kIOHIDPointerAccelerationTableKey` (`hidsystem/IOHIDParameter.h:92`).
- Apple's `IOHIDPointerScrollFilter.cpp` (apple-open-source/macos@529ea92) reads a user curve property (648-656), skips acceleration when the value is below 0 (860-862), and with `HIDUseLinearScalingMouseAcceleration` set uses a constant multiplier instead of a curve (866-885).
- **vorssaint/vorssaint-utils** (GPL-3.0, checked): per device, `IOHIDServiceClientSetProperty` with `HIDUseLinearScalingMouseAcceleration = 1` when the service has the key, otherwise acceleration −1, reading each value back (`MouseAccelerationSupport.swift:105-127`). After hot-plug it re-applies at 0, 0.25, 0.75, 1.5 and 2.5 s with a fresh client because the event-system service "and its initial settings can arrive later still" (checked, `Sources/Vorssaint/Services/MouseAcceleration/MouseAccelerationSupport.swift:82`, `MouseAccelerationService.swift:161-179`). It restores on sleep or session switch and re-applies on wake (checked, observers at `MouseAccelerationService.swift:222-240`). A journal plus a watchdog child process restore the original values even after SIGKILL (`MouseAccelerationRecovery.swift:136-186`, `MouseAccelerationGuard.swift:7-72`).
- **apsun/NoMouseAccel** (MIT, checked): one global `IOHIDEventSystemClientSetProperty(HIDMouseAcceleration, −1)` (`main.c:19-28`); its README says `com.apple.mouse.scaling -1` makes movement "insanely slow".
- Small tools: patrickjane/fixmouse (MIT; −65536 through `IOConnectSetCFProperties`, loop mode every 3 s), docwhat/killmouseaccel (`IOHIDSetParameter`), Rel1cx/sensi-mouse-cli (MIT; `IOHIDSetParameter` for acceleration and `HIDPointerResolution`), Hammerspoon (`IOHIDSetAccelerationWithKey`), DarkPlaces/Quakespasm (acceleration −1 while the game runs).
- **INRIA/libpointing** (upstream GPL-2.0+; the copy inside SmoothMouse says LGPL-2.0+, checked `WindowsFunction.cpp:1-10`) ships measured transfer functions: Windows 7/8/10 with EPP at slider −5…5, 125 Hz, 400 CPI (`pointing-echomouse/windows/epp/*.dat`) and macOS 15.3.2 (`pointing-echomouse/darwin-24`). Good test oracle; GPL data, so keep it outside our repo or re-measure.
- **ckb-next:** a user-space copy of Apple's old IOHIPointing curve code (APSL); `IOHIDPostEvent` only worked as the console user; the newer path posts through Karabiner's VirtualHIDPointing.
- **Drewbadour/HIDDriverKitAccelerationDisableSample** ("MIT NON-AI" license): a DriverKit dext for listed Logitech IDs that re-dispatches pointer events with the no-acceleration flag at a fixed ×0.5 (`DeliberateMouseDriver.cpp:356-428`); needs the DriverKit HID entitlements. It is the only code found that runs before the system accelerator, where a Windows curve could live without an event tap. It does not try one.
- **manishshanker/SmoothMouseLite** (2026, no license): rewrites only the delta fields in an event tap with a power curve; whether that moves the cursor at all is `unverified`. Its `dlsym("IOHIDSetAccelerationWithType")` names a symbol the macOS 27 `IOKit.tbd` does not export.

### 1.7 Closed apps: what their public pages say (from subagent, not checked)

- **SteerMouse** (https://plentycom.jp/en/steermouse/): speed = system Tracking Speed plus its own "Sensitivity"; no Magic Mouse or Magic Trackpad; 5.8 (2026-09-09) supports macOS 27; acceleration maximum raised from 20 to 99 in 5.6.2; the scroll option "Disable acceleration & sensitivity" is hidden since 10.12 as "not supported by OS"; it shipped a kext around 2013. No Windows curve.
- **CursorSense** (https://plentycom.jp/en/cursorsense/): per-device acceleration and sensitivity. Advice for Windows users: "Set acceleration to 0.01 and use sensitivity…", a near-linear setup, not a Windows curve. 1.3: "The algorithm for the cursor speed has been changed in macOS Sierra". Download page: "Magic Mouse does not support sensitivity changes in macOS 26 Tahoe or later". That its sensitivity is `HIDPointerResolution` is an `unverified` inference.
- **BetterMouse** (https://better-mouse.com): "Separated cursor acceleration & speed control, acceleration can be completely disabled"; "doesn't install any extensions, drivers, or agents", needs Accessibility only; per-app exceptions; Shift+scroll broke on Sonoma after 1.5.4166 (https://better-mouse.com/version-1-5-4166).
- **SmoothScroll** (https://smoothscroll.net/help): scrolling only; not in the App Store because it "doesn't allow us to modify low level input events that smooth scrolling needs"; recommends turning off `chrome://flags/#smooth-scrolling` to avoid a delayed scroll start.
- **ControllerMate:** SmoothMouse's developer recommended it because it lets you "draw the acceleration curve" (dae.me/blog/2144).

---

## 2. Scroll pipeline

### 2.1 Comparison

| | Mac Mouse Fix 3 | LinearMouse | Mos | UnnaturalScrollWheels | Scroll-Reverser |
|---|---|---|---|---|---|
| Tap location / placement / option | `kCGHIDEventTap`, head, active (`Scroll.m:83-84`) | `.cghidEventTap`, head, active (`EventTap.swift:85-92`) | `.cgAnnotatedSessionEventTap`, tail, active; separate listen-only taps for hotkeys and left click (`ScrollCore.swift:405-429`) | `.cghidEventTap`, tail, active (`ScrollInterceptor.swift:97-104`) | `kCGSessionEventTap`, tail, active scroll tap + passive gesture tap (`MouseTap.m:287-307`) |
| Mask | scrollWheel only (`Scroll.m:83`) | scroll, buttons, drags, key, flags; +mouseMoved only if needed (`EventType.swift:5-21`, `GlobalEventTap.swift:70-75`) | scrollWheel (`ScrollCore.swift:41`) | scrollWheel (`ScrollInterceptor.swift:102`) | scrollWheel + gesture (`MouseTap.m:295`, `:305`) |
| Thread | tap on main run loop (added in `+load`, `AccessibilityCheck.m:36`, `:193`; `Scroll.m:86-87`); work on a serial user-interactive queue (`Scroll.m:71-72`, `:245-247`); output on a CVDisplayLink queue (`mac-mouse-fix/Shared/Animation/DisplayLink.m:123-130`) | dedicated `Thread`, `.userInteractive`, own run loop (`EventThread.swift:46-62`) | main run loop (`Interceptor.swift:97-101`); output from CVDisplayLink thread via a post queue (`ScrollPoster.swift:197-200`, `ScrollDispatchContext.swift:108-131`) | a GCD global-queue worker kept inside `CFRunLoopRun()` (`ScrollInterceptor.swift:96-127`) | main run loop (`MouseTap.m:313-316`) |
| Mouse vs trackpad | pass through if `IsContinuous != 0`, `ScrollPhase != 0`, tablet ID != 0, diagonal, or Wacom (`Scroll.m:216-232`) | per device: IOHIDEvent sender ID → device (`DeviceManager.swift:920-933`); category trackpad if Digitizer/TouchPad usage, Magic Mouse forced to "mouse" (`Device.swift:610-622`) | trackpad if momentum/scroll phase != 0 or `ScrollCount != 0`, except events sourced by Logi Options (`ScrollEvent.swift:61-85`); comment: cannot tell Magic Mouse or Hackintosh trackpads apart (`ScrollCore.swift:79-84`) | `IsContinuous != 0` → not a wheel; alternate: phases/`ScrollCount` (`ScrollInterceptor.swift:49-63`) | non-continuous → mouse; continuous + ≥2 touches within 222 ms → trackpad; continuous, no phase, no touch for 333 ms → mouse; else previous (`MouseTap.m:132-155`) |
| What it emits | swallows the tick (`Scroll.m:249`) and posts new events at `kCGSessionEventTap`: line events (unsmoothed), continuous pixel events, or gesture+momentum events (`Scroll.m:836-846`, `:1030-1145`) | mutates the event in place (linear/reverse/speed) or swallows it and posts synthetic continuous events at `.cgSessionEventTap` (`SmoothedScrollingTransformer.swift:31`, `:92-104`) | swallows and posts copies of the original event with new point deltas, `IsContinuous=1`, via `CGEventPostToPid` (`ScrollPoster.swift:510-531`, `ScrollDispatchContext.swift:125-131`) | mutates in place | mutates in place |
| Smoothing | yes (default "High" + trackpad simulation, `mac-mouse-fix/Shared/Config/default_config.plist:18-27`) | optional, 120 Hz timer | yes, default on | no | no |
| `DisabledByTimeout` | re-enable; ignore `ByUserInput` (`Scroll.m:204-213`) | re-enable on timeout + 5 s health timer + 10 s permission watchdog that restarts the app (`EventTap.swift:35-47`, `:104-123`; `GlobalEventTapWatchdog.swift:19-42`) | stop animation, pass event; 5 s keeper re-enables with a 3-per-60 s cap (`ScrollCore.swift:56-59`; `Interceptor.swift:20-30`, `:103-123`) | re-enable, rebuild if it will not re-enable, again on wake (+1 s) (`ScrollInterceptor.swift:25-35`, `:139-159`, `:178-195`) | re-enable on any non-scroll callback (`MouseTap.m:236-239`) |
| Per-app rules | none in MMF 3 (menu-bar toggle only; MMF 2 had them) (`mac-mouse-fix/Markdown/Templates/Readme.md:312-326`) | schemes matched by app, process, display, device (`DeviceManager.swift:950-955`); bypass list for Shottr/Homerow; optional "ignore events from other apps" (`EventTransformerManager.swift:115-127`, `:206-228`) | allow/deny list with per-app smooth/reverse/step/speed/duration (`ScrollCore.swift:100-119`); Launchpad forced unsmoothed before macOS 26 (`ScrollUtils.swift:74-90`) | none | "ReverseOnlyRawInput": skip events with a source PID (remote desktop) (`MouseTap.m:159-166`, `:280`) |
| Modifiers | configurable; defaults Shift = horizontal, Option = precise, Control = quick, Command = zoom (`default_config.plist:7-17`) | per-modifier action (alter orientation, change speed, zoom, prevent); handled flag is removed from the event (`ModifierActionsTransformer.swift:71-86`, `:98-99`) | "toggle" (default Shift) swaps axes, "dash" (Option) ×5, "block" (Command) disables smoothing (`Constants.swift:143-151`; `ScrollPoster.swift:114-127`; `ScrollCore.swift:227-238`) | none | none |

### 2.2 Mac Mouse Fix 3 details

- **Input model:** uses integer `PointDeltaAxis1/2` of the tick (`Scroll.m:218-219`). The tap is enabled only while some setting differs from macOS defaults (`mac-mouse-fix/Helper/Core/Coordinate/SwitchMaster.swift:528-539`).
- **Own acceleration (not Apple's):** speed = `1 / timeBetweenTicks` (ticks/s); pixels per tick = `BezierCappedAccelerationCurve` from `(1/0.160 s, minSens)` to `(1/0.015 s, maxSens)` (`Scroll.m:428-469`; `mac-mouse-fix/Helper/Core/Config/ScrollConfig.swift:1024-1030`). Ticks more than 160 ms apart are "not consecutive" (`ScrollConfig.swift:314-325`). min/max px per tick by smoothness × speed: Off 20-40 / 40-80, Regular 30-120 / 90-180, High 60-150 / 120-240 (`ScrollConfig.swift:944-984`); max scaled by display height relative to 1080 with weight 0.1 (`:998-1009`).
- **Fast scroll:** after 2-6 consecutive "swipes", distance is multiplied exponentially (`ScrollSpeedupCurve(swipeThreshold:initialSpeedup:exponentialSpeedup:)`, capped at 100 000×) (`Scroll.m:475-491`; `ScrollConfig.swift:394-421`).
- **Animation:** "hybrid" curve = linear/Bezier base segment + drag-physics tail. Regular: base duration 180→110 ms depending on tick rate (exponential, curvature 4), `dragExponent 1.0, dragCoefficient 23, stopSpeed 30`; High: base 220 ms, `dragExponent 0.7, dragCoefficient 40, stopSpeed 30` (`ScrollConfig.swift:759-777`, `:806-821`). The "Low" (`VeryLowInertia`) branch is compiled out (`#if false`) and falls through to `fatalError()` (`ScrollConfig.swift:592-706`). A tick in the opposite direction cancels the animation (`Scroll.m:505-510`).
- **Frame driver:** CVDisplayLink; notes record stutter and a deadlock around its scheduling, with radars FB13682243 "Scheduling of CVDisplayLinkCallback causes stuttery scrolling throughout macOS" and FB19025288 "Random Super-Slow and Super-Fast Trackpad Scrolls on macOS Tahoe" (`mac-mouse-fix/Shared/Animation/Old MFDisplayLinkWorkType stuff.md:1-16`, `:62`). Author's own "scroll stopped working" incident on Tahoe beta, with CPU time in `SLEventCreateCopy` and `SLEventPost` (`mac-mouse-fix/Helper/Core/Scroll/Bug Log [Aug 2025] - Scroll Stopped Working.md`); header note links the public write-up (`Scroll.m:35-38`).
- **Event synthesis:**
  - Line events: `CGEventCreate` + field 55 = 22 (scroll type), `DeltaAxis` = px/10 truncated but at least ±1, `PointDeltaAxis` = px, `FixedPtDeltaAxis` set by hand because "under the Ventura Beta" it is no longer derived (`Scroll.m:1090-1145`).
  - Continuous events: same plus `IsContinuous = 1` and a sub-pixel accumulator for the line fields (`Scroll.m:1030-1088`).
  - Gesture events ("trackpad simulation"): type-22 event with fields 88 (continuous), 137 (`isDirectionInvertedFromDevice`), 99 (scroll phase), 123 (momentum phase), plus a type-29 subtype-6 gesture event (fields 110, 116, 119, 132) (`mac-mouse-fix/Helper/Core/Touch/GestureScrollSimulator.m:559-641`). To stop app-side momentum (Xcode, iPad apps) it sends a `MayBegin` + `Cancelled` pair, "simulating a quick tap with 2 fingers" (`Scroll.m:960-970`, `:1010-1016`).
- **Direction:** user setting "reverseDirection" simply multiplies by -1 (`ScrollConfig.swift:263-268`); it does not read the natural-scrolling pref (a field-137 read is commented out, `:285-298`). Default is reverse on (`default_config.plist:18-19`).
- **Known jank list:** iPad apps, Universal Control/iPhone Mirroring, Launchpad, Safari zoom reversal (`mac-mouse-fix/Helper/Core/Scroll/ScrollNotes.md:8-21`). Chromium needs extra zoom deltas (`Scroll.m:1152-1185`).

### 2.3 LinearMouse details

- **Transformer chain** built per scheme: Reverse → Logitech hi-res normalizer → ... → modifier actions → Smoothed → Linear (if not smoothed) → acceleration/speed scaling (`EventTransformerManager.swift:758-880`).
- **Edits all four delta representations at once** (`DeltaAxis`, `FixedPtDeltaAxis`, `PointDeltaAxis`, and the embedded IOHIDEvent `ScrollX/Y` via `CGEventCopyIOHIDEvent`), rounding integer line deltas to at least ±1 (`ScrollWheelEventView.swift:13-17`, `:119-152`).
- **Linear mode ("by lines"):** `IsContinuous = 0`, `DeltaAxis1 = sign × N` per notch; "by pixels": `IsContinuous = 1`, point/fixed = sign × N; momentum-phase events are dropped (`LinearScrollingVerticalTransformer.swift:42-72`). This is the closest to Windows' "N lines per notch", but unsmoothed.
- **Smoothed mode:** engine fed in pixels, a 1/120 s `Timer` on the event thread (not display-synced) emits `CGEvent(scrollWheelEvent2Source:units:.pixel ...)` with `IsContinuous = 1`, trackpad-style scroll/momentum phases, companion gesture events (MayBegin, series start/end), a synthetic marker in `eventSourceUserData`, and the last modifier flags (`SmoothedScrollingTransformer.swift:12`, `:116-127`, `:261-310`, `:359-417`). Presets (default `easeInOut`) with response/speed/acceleration/inertia; "bouncing" default on (`Smoothed.swift:85-87`, `:135-136`). Docs: turn `bouncing` off "to avoid rubber-band overscroll", which drops the phase markers "so apps are less likely to treat it like a trackpad gesture" (`linearmouse/Documentation/Configuration.md:89-91`).
- **Native continuous input** (trackpad-like, with phases) is handled separately (`SmoothedScrollingTransformer.swift:63-72`).
- **Direction:** reverse is an explicit per-scheme flag, no natural-scroll detection (`ReverseScrollingTransformer.swift:15-26`).

### 2.4 Mos details

- **Input:** takes `PointDeltaAxis` first (already accelerated by macOS), else fixed-point, else integer lines (`ScrollEvent.swift:88-115`); raises tiny deltas to `step` (default 33.6 px) (`ScrollCore.swift:147-158`) and multiplies by `speed` (default 2.70) and dash amplification (`ScrollPoster.swift:81-92`).
- **Animation:** CVDisplayLink callback; each frame moves `(target - current) × trans` where `trans = 1 - sqrt(duration / 5.2)` (default duration 4.35 → about 0.085) (`ScrollPoster.swift:399-412`; `Interpolator.swift:14-17`; `Constants.swift:158-186`). This is a per-frame exponential approach with no time step, so on a 120 Hz display the same setting finishes about twice as fast as on 60 Hz. A 5-sample "peak filter" smooths the start (`ScrollFilter.swift:38-42`).
- **Phases:** optional "simulate trackpad" adds scroll/momentum phases; without it, Chrome still gets a final `TrackingEnd` phase event (`ScrollPoster.swift:240-263`). Momentum thresholds 0.18 s / 0.45 s (`ScrollPoster.swift:35-40`).
- **Delivery:** `CGEventPostToPid` to the PID captured from the original event, "so momentum does not follow the cursor" to another app, and to avoid a proxy-lifetime crash (Mos PR #523, issue #868) (`ScrollPoster.swift:525-528`; `ScrollDispatchContext.swift:125-131`).
- **Robustness notes in code:** stale taps must be `CFMachPortInvalidate`d or WindowServer keeps them and "slow[s] down system-wide input (#970)" (`Interceptor.swift:56-63`); auto-restart throttling so a tap blocked behind a TCC dialog does not freeze input forever (`Interceptor.swift:20-30`); display link re-created when it binds to a transitional low refresh rate after wake (#958) (`ScrollPoster.swift:55-63`); zombie display-link detection (`ScrollPoster.swift:311-326`).
- **Direction:** reverse (vertical + horizontal) on by default (`Constants.swift:134-142`); no natural-scroll detection.

### 2.5 UnnaturalScrollWheels details

- Inverts `DeltaAxis1/2` only, and with "disable scroll acceleration" (default on, 3 lines) sets `DeltaAxis1 = sign × scrollLines` (`ScrollInterceptor.swift:65-79`; `Options.swift:16-19`). Point/fixed deltas are left for macOS to derive (see Scroll-Reverser's note below). Horizontal acceleration is not removed.

### 2.6 Scroll-Reverser details

- Reads `isDirectionInvertedFromDevice` for logging only (`MouseTap.m:81-85`); reversal is per source (mouse/trackpad) and axis (`:159-182`, `:206-208`).
- **Step size:** when a non-continuous tick has `|DeltaAxis1| == 1`, it writes `DeltaAxis1 = stepsize` (default 3) and lets macOS recompute the rest; accelerated ticks (`|Δ| > 1`) pass through (`MouseTap.m:200-216`; `AppDelegate.m:144-151`).
- Field-order note: "setting DeltaAxis causes macos to internally modify PointDeltaAxis (8x multiplier on DeltaAxis value) and FixedPtDeltaAxis (1x multiplier)", so point values must be written second (`MouseTap.m:210-212`). MMF instead uses 10 px per line (`Scroll.m:1110-1113`). Both are right, for different paths. Measured first-hand on this Mac (`sw_vers`: ProductVersion 27.0, BuildVersion 26A428) with a throwaway Swift program that only creates events in memory and never posts them:

  | Construction | DeltaAxis1 | PointDeltaAxis1 | FixedPtDeltaAxis1 | IsContinuous |
  |---|---|---|---|---|
  | `CGEvent(scrollWheelEvent2Source:units:.line, wheel1: 1)` | 1 | 10 | 1.0 | 0 |
  | same with `wheel1: 3` | 3 | 30 | 3.0 | 0 |
  | `units: .pixel, wheel1: 40` | 4 | 40 | 4.0 | 1 |
  | line event, then `setIntegerValueField(.scrollWheelEventDeltaAxis1, 3)` | 3 | **24** | 3.0 | 0 |

  `CGEventSource(stateID: .hidSystemState).pixelsPerLine` is 10. So creating a line event gives 10 px per line, but writing `DeltaAxis1` on an existing event makes macOS recompute `PointDeltaAxis1` at 8 px per line. Any consumer that reads the point field then gets 8 px per line instead of 10 unless the point field is written afterwards. Which apps read the point field versus the line field for non-continuous events was not tested (`unverified`).
- Bug: the horizontal IOHID value is multiplied by `vmul` instead of `hmul` (`MouseTap.m:228`).
- The gesture tap is listen-only on purpose: an active gesture tap caused extra permission dialogs, broke "shake to locate cursor" and the notification-center swipe (`MouseTap.m:287-291`).

---

## 3. Issue-tracker complaints that matter to us

Collected by the helper agent from issue pages it opened. I re-opened the pages marked (checked) and confirmed the quoted text; everything else is **(from subagent)**. MMF's `DiscussionsArchive/` folder contains only a README, so no MMF GitHub Discussions were read.

### 3.1 Pointer settings reset or have no effect

- LinearMouse #806 (checked), maintainer lujjjh: pointer speed "doesn’t work on built-in trackpads starting from M2 models and also doesn’t function on the Magic Trackpad, starting with macOS Sequoia. This issue also affects tools like CursorSense … macOS has removed higher-level support". #1004: on Tahoe, `HIDPointerResolution` writes are refused for Apple devices while third-party mice still work.
- LinearMouse PR #1365 (checked, open): `NSWorkspace.didWakeNotification` "fires before the HID stack has settled", and `IOHIDEventSystemClientRegisterPropertyChangedCallback` "catches what System Settings → Mouse writes, not the per-service HIDEventServiceProperties". The service is destroyed on sleep and a new one published on wake; the PR re-applies once a second for 30 s. Related: #1047; #764 (after wake or a KVM switch the device reappears under a new name and loses its settings).
- LinearMouse #106: the Universal Control cursor gets stuck; lujjjh: "disabling cursor acceleration actually updates cursor acceleration to -1". UnnaturalScrollWheels #41: Universal Control breaks when acceleration is disabled.

### 3.2 Stutter, lag, CPU, taps dying

- LinearMouse #1380 (checked, open): drags stutter with an 8 kHz mouse. `sample WindowServer` shows SkyLight `add_event_vector_to_tap` as the hottest frame, and LinearMouse's tap "is the only enabled synchronous tap on the system whose mask contains leftMouseDragged". #1166/#1168: 0.11.0 regressions (about 50 % CPU while dragging), fixed in 0.11.1. #915: the CPU cost comes from monitoring all input to find the active device.
- LinearMouse PR #1143: returning a copied `CGEvent` with `passUnretained` caused "Invalid event returned by callback" and silently disabled the tap. The current code returns copies with `passRetained` (checked, `EventTap.swift:56-61`) and re-checks the tap every 5 s (`:104-123`).
- MMF #875 (checked), maintainer: periodic scroll stutter in Firefox and Safari "also happens with the Trackpad"; reading vsync timestamps through `IOFrameBuffer` "is only available for Intel Macs".
- MMF #1279, #1121, #1109 (label "Scroll Stops Working After macOS Update"); the 3.0.7 notes mention a "deadlock in the scrolling system… cannot be solved fully without deeper changes". Mos #697 reports the same "smooth scrolling dies" pattern. The MMF author's public note lists wake, boot, reconnect and updates as triggers and says users report that Mos does not have the problem (checked, https://github.com/noah-nuebling/notes-public/blob/23361f16a315f48f1f6278161b8cefab50fc3665/mmf/bug-investigation/scrolling-stops-intermittently_apr-2025.md).
- Mos #958: choppy scrolling after wake because the display link is rebuilt at 60 Hz during a cooldown and misses the later 144 Hz mode (the fix is in `ScrollPoster.swift:55-63`, checked). Mos PR #999 / #970: five disabled taps leaked per sleep/wake cycle and made input lag system-wide (fix in `Interceptor.swift:56-63`, checked).

### 3.3 Rubber-banding, swipe navigation, overshoot, per-app quirks

- MMF #746 (checked), maintainer: MMF's events "don't look like anything that macOS apps normally see" (one tick scrolled 29 lines in dropdowns; Preview scrolls too fast), and trackpad simulation instead stutters in System Settings: "I think these are just limitations of macOS."
- MMF #378, #372, #438: the bounce and unwanted back/forward swipes come from trackpad simulation; #372 traces to a Chromium bug that also hits the Magic Mouse (the code links https://issues.chromium.org/issues/40322807, `GestureScrollSimulator.m:23`, checked); overshoot can only be avoided by dropping trackpad simulation, and AX-based overscroll detection is "extremely slow".
- MMF #1512 (checked), maintainer: "browsers like Safari make non-smooth scroll events cover more distance than smooth events", and "The next bigger thing I plan to address is adding pointer-speed settings … in the next year or so."
- MMF #2026 (checked; a third party's notice): on macOS 27 the gesture data has to be attached as an `IOHIDEvent` (master commit `f92d2d53a`; "no release contains it yet"), and high-rate mice sent "up to 19 gesture events per 8ms frame, where an Apple Trackpad sends exactly one" (PR #2025 coalesces them).
- MMF #1112, #1141: other taps (Logi Options, Mos) and the order taps are installed in break scrolling. #973: no per-app exclusion, so smoothing breaks games and Photoshop.
- LinearMouse #16 (checked), lujjjh: different per-app step sizes (Chrome about 6 lines vs Xcode about 1.5 per notch, numbers from subagent) are "a known issue … I've also tried SteerMouse, which behaves the same". #1290: smoothing fights Calendar's scroll snapping; reversing in both Logi Options+ and LinearMouse reverses twice.
- Mos #160, #213: Chrome over-scrolls; Caldis: Mos's events "have the same characteristics as the scroll events of the trackpad". #751: rubber-banding would get "stuck at the edge of the page in Chrome". #410/#438: Catalyst apps (Messages) lock up; a user zeroed `PhaseValueMapping`. #15/#607: Shift+wheel stops scrolling horizontally when smoothing is on. #332: in Office the wheel turns into zoom.
- Scroll-Reverser #143, #129, #130: direction flips mid-scroll; a user's log shows a switch to "mouse" after more than 333 ms, which is the heuristic at `MouseTap.m:146-150` (checked). #136: bouncing in Safari 15.3. #92: the Accessibility setting "Use trackpad gesture to zoom" suppresses the gesture events it relies on, "further up the food chain than I can do anything about". #65/#113: the step size does not apply to Shift+scroll.
- UnnaturalScrollWheels #4, #44: Logitech Options makes wheel events continuous, hence the alternate detection mode (`ScrollInterceptor.swift:49-63`, checked); a Magic Mouse cannot be inverted.

### 3.4 Permissions

- UnnaturalScrollWheels #107, #67, #118: the Accessibility grant goes stale after an update or an invalid 1.4.0 signature; the fix is to remove and re-add the app. #97: freezes on Tahoe and dies after sleep. #117: 1.4.0 locked up all input.
- Mos 4.2.0: "Fixed system input blocking when Accessibility permission is revoked while Mos is running" (checked, `Mos/CHANGELOG.md:34`). Mos #635: Mos gets killed at random, probably a null pointer when another app takes over a scroll event.
- Scroll-Reverser PR #206: tap-disabled events crashed inside `NSEvent eventWithCGEvent` before the re-enable code ran. The cloned code still builds the NSEvent before checking the event type (checked, `MouseTap.m:63`).

---

## 4. Did anyone implement a Windows EPP curve?

Only SmoothMouse, which needed its own kext and stopped at Sierra (section 1.5). None of the five studied apps has one, and no closed app advertises one.

- **LinearMouse** #261 "Matching Windows mouse acceleration curve" (checked; opened 2022-10-02 by user ViRb3; open and labelled "help wanted" per subagent). The opener writes: "macOS and Windows use fundamentally different acceleration curves. This means that it is completely impossible to match them 1:1." The maintainer's only reply: "When developing LinearMouse, I've noticed the `HIDPointerAccelerationTable` property, but I haven't dived into it" (author taken from the page data). Also (from subagent): #122, "if 'Enhance pointer precision' is enabled, pixel-perfect matching is difficult to achieve because the acceleration curves on Windows and macOS appear to be different"; #642, "due to the closed-source nature of both macOS and Windows, answering this question isn't straightforward"; #1001 (2026-08), "I don't plan to increase Pointer Speed further, as higher values can behave poorly due to how it is implemented."
- **Mac Mouse Fix** #14 (checked, 2019), maintainer: "it seems very hard to change the pointer speed programmatically … While I was able to change a devices `HIDPointerResolution` value, which is also altered when you change sensitivity in SteerMouse, that did not have an effect on actual sensitivity". Custom-curve code exists but is disabled (section 1.1); #1512 (checked) puts pointer-speed settings "in the next year or so". Requests #527, #1202 and #1286 have no maintainer answer (from subagent).
- **Mos** #124 "Do you plan to disabled mouse cursor acceleration?" (checked), Caldis: "Modifying the mouse pointer acceleration requires a lot of extra modifications to the underlying driver. If I using the CGEvent API used by Mos in current for this purpose, it will cause some performance problems." He points to CursorSense, ControllerMate and SteelSeries ExactMouse.
- **UnnaturalScrollWheels** only disables acceleration; #22 says it is based on NoMouseAccel, "which takes advantage of a possible bug" (from subagent). **Scroll-Reverser** has no pointer features.
- **Closed apps:** CursorSense recommends a near-linear setup for Windows users (section 1.7). A Reddit excerpt says SmoothMouse's developer claimed Windows acceleration "can't even be replicated" by SteerMouse or CursorSense (https://reddit.com/r/mac/comments/ilzvo2; secondary, `unverified`).

---

## 5. Licenses: what we may reuse

| Project | License | Practical meaning for an open-source Swift app |
|---|---|---|
| LinearMouse | MIT (`linearmouse/LICENSE`) | Code may be copied with the copyright notice. Safest source to borrow from. |
| Scroll-Reverser | Apache-2.0 (`Scroll-Reverser/LICENSE`, header `MouseTap.m:1-2`) | Code may be copied; keep notice, state changes, include NOTICE if any. |
| Mac Mouse Fix | Custom "MMF License" (`mac-mouse-fix/License`) | Derived works must say so; a derived *free* app is allowed, but the license text ties published binaries that contain MMF code to MMF's monetization rules unless the work is "substantial improvements"; the author calls it "Open Source in spirit". Not OSI-approved. Treat as reference only; re-implement from the documented behavior (field numbers, API names and constants are facts, not expression). Its `version-3` branch also contains GPL code used with permission (`License`, closing note). |
| Mos | CC BY-NC 4.0 (`Mos/LICENSE`) | Non-commercial only and not a software license in the usual sense; do not copy code into an open-source app that could be used commercially. Reference only. |
| UnnaturalScrollWheels | GPL-3.0 (`UnnaturalScrollWheels/LICENSE`) | Copying code makes our app GPL-3.0. Reference only unless we choose GPL. |

Other code referenced above:

| Project | License | Practical meaning |
|---|---|---|
| SmoothMouse (capitalfuse copy) | No license grant: `Installer/Resources/License.rtf` is only "Copyright © 2013 Cyberic" plus a warranty disclaimer (checked) | Do not copy. Its `WindowsFunction.cpp` header says LGPL-2.0+ (checked); upstream libpointing is GPL-2.0+ (from subagent). Use as a description of the algorithm only. |
| SDL3 | zlib (checked, `SDL_windowsmouse.c:1-20`) | Curve constants and fixed-point math may be reused; keep the notice in copied source files and mark changes. |
| vorssaint-utils | GPL-3.0 (checked) | Ideas only. |
| apsun/NoMouseAccel | MIT (checked) | One API call; nothing worth copying beyond the idea. |
| libpointing data tables | GPL-2.0+ (from subagent) | Use as an external test oracle, not shipped in our repo. |

---

## 6. Techniques worth reusing

1. **Neutralize macOS acceleration per device, not globally.** Match GenericDesktop Mouse/Pointer services with `IOHIDEventSystemClientCreate` and write properties with `IOHIDServiceClientSetProperty` (LinearMouse, MIT: `PointerDeviceManager.swift:108-150`, `PointerDevice.swift:248-275`). On Sonoma and later, `HIDUseLinearScalingMouseAcceleration = 1` switches Apple's filter to a constant multiplier (public key, `IOHIDEventServiceKeys.h:182`); older systems fall back to acceleration −1 (`DeviceManager.swift:961-979`). This gives a clean linear baseline for our own curve.
2. **Capture the baseline and restore it, including after a crash.** LinearMouse records the initial values at attach and writes them back on teardown (`Device.swift:296-298`, `:713-760`). vorssaint adds a journal and a watchdog child process that restores even after SIGKILL (idea only, GPL). UnnaturalScrollWheels shows the failure without this: it restores only in `applicationWillTerminate` (`AppDelegate.swift:45-48`).
3. **Re-apply whenever the service can be reset:** a property-changed callback (`DeviceManager.swift:168-180`), hot-plug with retries at 0-2.5 s (vorssaint `MouseAccelerationSupport.swift:82`), and a polling window after wake, because `didWake` arrives before the HID stack settles and property callbacks miss per-service resets (LinearMouse PR #1365).
4. **Tap plumbing:** a dedicated user-interactive thread with its own run loop (`EventThread.swift:46-62`); re-enable on `tapDisabledByTimeout` plus a 5 s health check (`EventTap.swift:35-47`, `:104-123`); `CFMachPortInvalidate` on teardown (Mos #970); stop the tap and throttle restarts when Accessibility is revoked, so input never freezes (Mos `Interceptor.swift:20-30`, `:86-111`; idea only, CC BY-NC).
5. **Identify the sending device for every event** with `CGEventCopyIOHIDEvent` → `IOHIDEventGetSenderID` → service registry ID (`DeviceManager.swift:920-933`). The heuristics fail in practice: Logitech Options makes wheel events continuous (UnnaturalScrollWheels #4), timing heuristics flip direction mid-scroll (Scroll-Reverser #143), and Mos cannot tell a Magic Mouse from a trackpad (`ScrollCore.swift:79-84`).
6. **Mark synthetic events** in `eventSourceUserData` and let them pass the tap untouched (Mos `ScrollUtils.swift:16-35`; LinearMouse `isLinearMouseSyntheticEvent`).
7. **Keep every delta representation consistent:** line, fixed-point, point and the embedded IOHIDEvent value (`ScrollWheelEventView.swift:119-152`), and write the point field after the line field. On this Mac, setting `DeltaAxis1` on an existing event made macOS recompute 8 px per line, while creating a line event gives 10 px per line (section 2.6).
8. **Fixed lines per notch, no macOS wheel acceleration:** set `DeltaAxis1 = sign × N` on non-continuous events (LinearMouse `LinearScrollingVerticalTransformer.swift:55-62`; UnnaturalScrollWheels `ScrollInterceptor.swift:75-78`; Scroll-Reverser `MouseTap.m:200-216`).
9. **Deliver animation frames to the original target** with `CGEventPostToPid`, so frames posted after the cursor moves still reach the window that was scrolled (Mos `ScrollDispatchContext.swift:125-131`).
10. **Windows curve reference:** SDL3's `ReadMouseCurve` (zlib) for the constants, SmoothMouse/libpointing for the segment averaging and remainder handling (reference only), and libpointing's measured EPP tables as an outside test oracle.

## 7. Pitfalls to avoid

1. **Writing `HIDAccelCurves`.** Once set it cannot be removed, it overrides table curves, and bad values have crashed WindowServer (`PointerSpeed.m:296-327`, `:478`). MMF never shipped it.
2. **Re-injecting all pointer motion from user space** (SmoothMouse): it broke pointer capture in games, hot corners, drags and pro apps; `CGEventPost` dropped moves under GPU load; `IOHIDPostEvent` is deprecated since macOS 11 (section 1.5).
3. **Active synchronous taps on high-rate events.** LinearMouse's default HID-level tap on drag events made WindowServer's `add_event_vector_to_tap` the hottest frame with an 8 kHz mouse (#1380). This weighs directly on any design that rewrites `mouseMoved` in a tap to apply a curve.
4. **Trackpad simulation for a wheel:** rubber-banding, back/forward swipes, overshoot, Calendar snapping, Catalyst lock-ups (MMF #378/#372/#438, Mos #410, LinearMouse #1290), and it broke on macOS 27 when the undocumented CGEvent gesture fields stopped being read (MMF #2026). A Windows-like wheel needs none of it.
5. **CVDisplayLink as the animation clock:** stutter and deadlocks (MMF radars FB13682243 and FB19025288, `Shared/Animation/Old MFDisplayLinkWorkType stuff.md:14-16`; MMF #875), a stale low refresh rate after wake (Mos #958), zombie links (`ScrollPoster.swift:311-326`). A per-frame fraction without a time step also makes the animation length depend on the refresh rate (Mos `ScrollPoster.swift:404-412`).
6. **Heavy or thread-unsafe work in the tap path:** `IOHIDDeviceGetProperty` from the scroll queue crashed MMF (`Scroll.m:276-287`); `NSEvent(cgEvent:)` on a tap-disabled event crashed Scroll-Reverser (PR #206); MMF does app lookup only on the first tick of a gesture because it is slow (`Scroll.m:328-330`).
7. **Lifecycle leaks:** restoring only on a clean quit (UnnaturalScrollWheels), leaking taps on every wake (Mos #970), keeping a tap alive after Accessibility is revoked (Mos 4.2.0).
8. **Trusting `didWake`** or property callbacks to signal that per-device settings are back (LinearMouse PR #1365).
9. **Asserts in release builds:** an `assert` in the scroll path crashed MMF 3.0.2 (#988, cited in `Scroll.m:651-670`).

## 8. Gap analysis: why none feels like Windows

**Pointer.**
- None of the five applies a Windows-shaped curve. LinearMouse, the most complete, moves Apple's curve index (0-40) and pointer resolution or switches to linear (section 1.2), so the shape stays Apple's. Apple's parametric curves are `ax + (bx)^2 + (cx)^3 + (dx)^4` with caps (`PointerConfig.swift:303`) and cannot express Windows' five-point piecewise-linear gain exactly. The table route (`HIDPointerAccelerationTable`) is unexplored in LinearMouse (#261) and was blocked by parametric curves in MMF's tests (`PointerSpeed.m:296-321`).
- The one Windows emulator replaced the system driver with a kext and then chased app breakage for years (section 1.5). The only modern pre-accelerator hook found is a DriverKit sample that needs entitlements (section 1.6).
- Nobody calibrates counts-to-pixels against Windows. SmoothMouse's port hard-codes 96 dpi and computes per HID report (`WindowsFunction.cpp:164`, `:178-179`); Apple's accelerator also works per report, which MMF notes makes it polling-rate dependent (`PointerConfig.swift:12-34`). libpointing's measured tables (section 1.6) are the only ground truth seen.
- Settings drift after sleep or reconnect (LinearMouse PR #1365, #764), so a setup that feels right can change after wake.

**Scroll.**
- On Windows the wheel moves a fixed number of lines per notch (3 by default) and smoothing, if any, happens in the app (secondary; details belong to the Windows-scroll research). On macOS the system accelerates wheel ticks: Scroll-Reverser rewrites only ticks with `|Δ| == 1` and passes the accelerated ones through (`MouseTap.m:200-203`). Apps also map lines to pixels differently (LinearMouse #16; Safari, per MMF #1512).
- The apps that remove wheel acceleration (LinearMouse "by lines", UnnaturalScrollWheels, Scroll-Reverser) post unsmoothed line events, so the page jumps a full step per notch.
- The apps that smooth go trackpad-style. MMF defaults to "High" with trackpad simulation (`default_config.plist:18-27`): a 220 ms base, a drag tail and an exponential "fast scroll" (`ScrollConfig.swift:394-421`, `:806-821`). Mos multiplies already-accelerated point deltas (`ScrollEvent.swift:101-104`; step 33.6, speed 2.7, `Constants.swift:152-156`) and eases per frame. LinearMouse's default preset is easeInOut with bouncing on (`Smoothed.swift:85-87`, `:135-136`). Each adds momentum, overscroll or speed-dependent distance.
- The smoothers carry recurring "scroll stops" and stutter bugs tied to display-link scheduling and taps (section 3.2), which users feel as lag.

**The unoccupied spot:** (a) a per-device Windows EPP curve (Windows 7 or 8+ constants, sensitivity 1-20, sub-pixel remainders) on top of a linear macOS baseline that is re-applied after every reset; (b) a wheel with a fixed distance per notch, no macOS wheel acceleration, and at most a short per-notch ease with no momentum, no scroll phases and no gesture events, so no rubber band or swipe navigation; (c) restore-on-crash and wake handling from day one.

2026-11-08 implementation update: browser snapping needs an explicit Begin/Changed/End sequence
for the animation's frames. Only recognized browsers receive those phases; native applications
retain phase-free pixel output. No momentum or companion gesture events are generated. See
[scroll-compatibility.md](scroll-compatibility.md) for the evidence, regression checks and
unverified hardware behavior. This supersedes the blanket "no scroll phases" recommendation.

---

## Sources

Repositories (cloned 2026-09-26, commits in the table at the top):
- https://github.com/linearmouse/linearmouse
- https://github.com/noah-nuebling/mac-mouse-fix
- https://github.com/Caldis/Mos
- https://github.com/ther0n/UnnaturalScrollWheels
- https://github.com/pilotmoon/Scroll-Reverser
- https://github.com/apsun/NoMouseAccel (referenced by UnnaturalScrollWheels, not read)

Issue and PR pages opened first-hand (quotes checked):
- https://github.com/linearmouse/linearmouse/issues/261
- https://github.com/linearmouse/linearmouse/issues/806
- https://github.com/linearmouse/linearmouse/pull/1365
- https://github.com/linearmouse/linearmouse/issues/1380
- https://github.com/linearmouse/linearmouse/issues/16
- https://github.com/noah-nuebling/mac-mouse-fix/issues/14
- https://github.com/noah-nuebling/mac-mouse-fix/issues/746
- https://github.com/noah-nuebling/mac-mouse-fix/issues/875
- https://github.com/noah-nuebling/mac-mouse-fix/issues/1512
- https://github.com/noah-nuebling/mac-mouse-fix/issues/2026
- https://github.com/Caldis/Mos/issues/124
- https://github.com/noah-nuebling/notes-public/blob/23361f16a315f48f1f6278161b8cefab50fc3665/mmf/bug-investigation/scrolling-stops-intermittently_apr-2025.md

Other issue numbers in sections 3 and 4 were opened by the helper agent (from subagent). Their URLs follow the pattern `https://github.com/<owner>/<repo>/issues/<n>` (pull requests: `/pull/<n>`) for linearmouse/linearmouse, noah-nuebling/mac-mouse-fix, Caldis/Mos, ther0n/UnnaturalScrollWheels and pilotmoon/Scroll-Reverser.

Other code (cloned into the scratchpad by the helper agent; lines marked checked were read by me):
- https://github.com/capitalfuse/SmoothMouse (commit `f91a4b2`)
- https://github.com/libsdl-org/SDL/blob/a19bac6/src/video/windows/SDL_windowsmouse.c
- https://github.com/vorssaint/vorssaint-utils (commit `4c6edc9`)
- https://github.com/apsun/NoMouseAccel
- https://github.com/INRIA/libpointing
- https://github.com/Drewbadour/HIDDriverKitAccelerationDisableSample
- https://github.com/manishshanker/SmoothMouseLite
- https://github.com/patrickjane/fixmouse, https://github.com/docwhat/killmouseaccel, https://github.com/Rel1cx/sensi-mouse-cli

Web pages (from subagent, not opened by me):
- https://dae.me/blog/2144/on-macos-sierra-support-and-the-future-of-smoothmouse/
- https://dae.me/blog/2243/macos-kernel-programming-bounty-to-revive-smoothmouse/
- https://web.archive.org/web/2015id_/http://smoothmouse.com/changelog/1.0.7
- https://plentycom.jp/en/steermouse/ and https://plentycom.jp/en/cursorsense/
- https://better-mouse.com and https://better-mouse.com/version-1-5-4166
- https://smoothscroll.net/help
- https://reddit.com/r/mac/comments/ilzvo2

Local SDK headers (checked): `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/IOKit.framework/Headers/` (`hidsystem/IOHIDLib.h`, `hid/IOHIDEventServiceKeys.h`, `hidsystem/IOHIDParameter.h`).
