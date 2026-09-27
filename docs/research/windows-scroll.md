# Windows mouse-wheel scrolling in numbers

Research note, 2026-09-26. Scope: what a notched mouse wheel does on Windows 10/11 (the OS contract, Chrome and Edge, Firefox, native apps), reduced to numbers the macOS app can reproduce by posting pixel scroll events. Pointer speed is covered in [windows-pointer.md](windows-pointer.md).

How to read the evidence:

- `path:line` refers to source files I read at the commits listed under [Sources](#sources). Chromium paths are relative to `chromium/src` at `08da355f` (main, 2026-09-26) unless marked *pre-removal*: that is `176f7658`, the parent of the change that switched off Windows Scrolling Personality in November 2024. Firefox paths are relative to `mozilla-firefox/firefox` at `c32abda0` (main, 2026-09-26).
- *derived* marks my own arithmetic or output of the reference model in the [appendix](#appendix-reference-model-python). *(secondary)* marks third-party statements I read but could not check against code. *unverified* means I found no primary source, or only saw a search-engine summary.
- 1 DIP (one Windows pixel at 100 % display scaling) is treated as 1 macOS point.

## Summary

- Windows defines only the unit: one detent is `WHEEL_DELTA = 120`, and an app should scroll `(delta / 120) × lines` lines, where lines defaults to 3. Windows has no mouse-wheel acceleration (§1).
- Chrome and Edge turn one notch into 100 DIP (100/3 DIP per line × 3 lines) and animate it with `cubic-bezier(0.42, 0, 0.58, 1)` over 200 ms. A notch that arrives mid-animation adds 100 DIP to the target. The curve is rebuilt from the current position so the speed stays continuous, and the new segment lasts between 200 and 100 ms depending on the distance left (§2).
- Firefox ends up at nearly the same distance (3 lines × about 17 px × 2 ≈ 102 px) with a different curve: `cubic-bezier(0.25, 0, 0.6, 1)` for a lone notch, lasting `clamp(2 × recent notch interval, 50, 200)` ms (§3).
- Native apps don't agree with each other. Classic Win32 views step 3 lines per notch without animation, XAML views scroll about 48 px per notch with an OS-driven animation whose parameters are not public, and WPF jumps 48 px (§4).
- Windows Scrolling Personality (percent-based scrolling plus the "impulse" curve, shipped in Edge in 2020) is gone. Microsoft disabled it in Edge and removed it from Chromium in November 2024; M133 was the first release without it (§2.5).
- Recommendation: copy Chrome/Edge exactly. All of its numbers are in public source code, it is what Edge (the browser Windows ships with) does, and Firefox's distance is within 2 % of it. The target spec is in [§8](#8-target-spec-for-macos).

## 1. The Win32 contract

| Item | Value | Evidence |
|---|---|---|
| Detent size | `WHEEL_DELTA = 120`. Smaller values come from "finer-resolution wheels"; apps either add deltas up to 120 or scroll partial lines. | [WM_MOUSEWHEEL] |
| Lines per notch | `SPI_GETWHEELSCROLLLINES`, default 3 | [SPI], [About Mouse Input] |
| "One screen at a time" | lines = `WHEEL_PAGESCROLL` (`UINT_MAX`): treat the notch as one click in the page-up/page-down area of the scroll bar. The same applies when lines exceeds the number of visible lines. | [SPI] (`SPI_SETWHEELSCROLLLINES`), [About Mouse Input] |
| Tilt / horizontal wheel | `WM_MOUSEHWHEEL`, positive = right. Characters per tilt: `SPI_GETWHEELSCROLLCHARS`, default 3 | [WM_MOUSEHWHEEL], [SPI] |
| Where wheel input goes | `SPI_GETMOUSEWHEELROUTING`: focused window, hybrid (the API's default) or window under the pointer. Settings shows it as "Scroll inactive windows when hovering over them". | [SPI], [Settings] |
| Direction | Windows 11 Settings: "Down motion scrolls down" or "Down motion scrolls up" | [Settings] |
| Animation switch | `SPI_GETCLIENTAREAANIMATION` (animations on/off). Chrome reads it (§2.4). | [SPI] |

Settings > Bluetooth & devices > Mouse > Scrolling has four controls: *Roll the mouse wheel to scroll* (Multiple lines at a time / One screen at a time), *Lines to scroll at a time*, *Scroll inactive windows when hovering over them* and *Scrolling direction*. Characters per tilt is in the old Mouse Properties dialog, Wheel tab [Settings].

Microsoft's guidance for applications [Best practices 2004]:

- `(scroll value / WHEEL_DELTA) × lines-to-scroll = lines to scroll`. Scroll fractional lines if possible; otherwise keep the remainder and reset it when the direction changes or focus moves.
- Page mode: `scroll value / 120 = pages`.
- Tilt: `(tilt value / 120) × characters-to-scroll = characters to scroll`.
- Ctrl + wheel away from the user zooms in, toward the user zooms out.
- The first wheel mouse had 18 detents per revolution. 120 was chosen because it divides evenly for future high-resolution wheels.

High-resolution wheels: Windows Vista added support for the HID Resolution Multiplier. Windows sets the multiplier to its logical maximum and then delivers deltas below 120 ((secondary): Peter Hutterer's Linux kernel patch notes, which cite Microsoft's "Enhanced Wheel Support in Windows" paper; I did not open that paper). Microsoft's Win32 tutorial: "If the mouse wheel has a high resolution, the absolute value of the delta might be less than 120" [Other mouse operations].

Windows applies no wheel acceleration. The evidence:

1. The `SystemParametersInfo` reference has no wheel-acceleration parameter. The only acceleration it mentions belongs to the pointer (`SPI_GETMOUSE`). I searched the whole page text.
2. Microsoft's formula above is linear in the delta.
3. None of the four Settings controls is an acceleration.
4. The "Accelerated scrolling" added in Insider Beta build 26220.8925 (20 July 2026) is filed under "[Touchpad]" and applies to precision touchpads only [Insider 26220.8925].
5. Chrome's Windows conversion is linear (§2.1), and Firefox ships its wheel acceleration switched off (§3.1).

Vendor software (Logitech Options+, Razer Synapse and others) can add its own scroll acceleration. I did not check any of them (unverified).

Windows does not convert Shift + wheel into horizontal scrolling. The app receives `WM_MOUSEWHEEL` with `MK_SHIFT` set and decides what to do. Chromium reads `MK_SHIFT` from the message and swaps the axes itself (`ui/events/blink/web_input_event_builders_win.cc:279-291`, `components/input/mouse_wheel_event_queue.cc:154-164`). Microsoft's own sample passes Shift and Ctrl wheel messages on to `DefWindowProc` [About Mouse Input].

## 2. Chrome and Edge (Chromium)

### 2.1 Distance per notch

On Windows, Chromium builds wheel events directly from `WM_MOUSEWHEEL`/`WM_MOUSEHWHEEL` (`ui/events/blink/web_input_event.cc:48-69, 267-275`):

```cpp
// ui/events/blink/web_input_event_builders_win.cc:297-335 (abridged)
float num_ticks = wheel_delta / WHEEL_DELTA;          // fractional for hi-res wheels
float scroll_delta = num_ticks;
if (horizontal_scroll) {
  SystemParametersInfo(SPI_GETWHEELSCROLLCHARS, 0, &scroll_chars, 0);
  scroll_delta *= scroll_chars;
} else {
  SystemParametersInfo(SPI_GETWHEELSCROLLLINES, 0, &scroll_lines, 0);
  if (scroll_lines == WHEEL_PAGESCROLL) result.delta_units = kScrollByPage;
  else scroll_delta *= scroll_lines;
}
if (result.delta_units != kScrollByPage) {
  // "... IE 8 is ~60 px/line ... Here we use 100 px per three lines
  //  (the default scroll amount is three lines per wheel tick)."
  static const float kScrollbarPixelsPerLine = 100.0f / 3.0f;
  scroll_delta *= kScrollbarPixelsPerLine;
}
```

So `distance = (delta / 120) × lines × 100/3` DIP: 100 DIP per notch at the default 3 lines, 33.3 DIP per line. Mozilla measured the same in Chrome: 33.33 × n px at n lines per notch (bug 1418822 comment 40 (secondary)).

- Units: Chromium multiplies wheel deltas by the device scale factor before the renderer sees them (`components/input/input_router_impl.cc:675`, `ui/events/blink/blink_event_util.cc:525-535`). 100 DIP is 150 physical pixels at 150 % scaling. On macOS it is 100 points.
- Page zoom: the distance stays constant on screen when the page is zoomed (Mozilla's measurement, same comment (secondary)).
- High-resolution wheels: `num_ticks` is a float, so a 30-unit event scrolls 25 DIP.
- "One screen at a time": the notch becomes a page scroll of `0.875 × min(scroller height, viewport height)` (`cc/input/input_handler.cc:1791-1806`, `cc/input/scroll_utils.h:20-27`).
- Small scrollers: each wheel delta is capped at the size of the scroller (`kLimitScrollDeltaToScrollerSize`, enabled by default: `ui/base/ui_base_features.cc:217-219`, `cc/input/input_handler.cc:1753-1780`).
- Acceleration: nothing in the conversion depends on event timing or rate.
- Ctrl + wheel zooms the page instead of scrolling (`third_party/blink/common/input/web_mouse_wheel_event.cc:119-125`).

### 2.2 Animation curve and duration

Every Windows wheel event is animated. Chromium leaves `hasPreciseScrollingDeltas` false for `WM_MOUSEWHEEL` (`web_input_event_builders_win.cc:268-271`), and both the compositor and Blink animate anything that isn't a precise-pixel scroll (`cc/input/input_handler.cc:2459-2467`, `third_party/blink/renderer/core/scroll/scroll_animator.cc:98-105`). Both paths build the curve with `ScrollType::kMouseWheel` (`cc/animation/scroll_offset_animations_impl.cc:60-74`, `scroll_animator.cc:292-304`), which maps to `DurationBehavior::kInverseDelta` (`cc/animation/scroll_offset_animation_curve_factory.cc:12-24`). One exception: on Blink's main-thread path a page-mode notch gets the keyboard curve, a constant 150 ms (`scroll_animator.cc:296-299`, `scroll_offset_animation_curve.cc:17, 155-157`).

- Curve: `cubic-bezier(0.42, 0, 0.58, 1)`, the CSS `ease-in-out` (`cc/animation/scroll_offset_animation_curve.cc:28-33, 327-339`). The only other curve type left is linear, used for autoscroll (`scroll_offset_animation_curve.h:114`).
- Duration (`scroll_offset_animation_curve.cc:17-18, 44-54, 166-173`), with Δ the distance still to travel:

  ```
  T(Δ) = clamp(14 − |Δ| / 60, 6, 12) / 60 seconds
       = 200 ms for |Δ| ≤ 120, 100 ms for |Δ| ≥ 480, linear in between (300 px → 150 ms)
  ```

  The header describes it as "Duration inversely proportional to scroll delta within certain bounds. Used for mouse wheels, makes fast wheel flings feel 'snappy' while preserving smoothness of slow wheel movements" (`scroll_offset_animation_curve.h:51-54`).
- Shape (derived): a lone notch covers 12.9 % of its distance after a quarter of the time, 50 % at half time and 87.1 % at three quarters. Speed starts and ends at zero and peaks at 1.72 × the mean, which is 862 DIP/s for one 100 DIP notch.
- Start offset: the compositor starts a new animation one frame in, so the first frame after the event already moves (`cc/trees/layer_tree_host_impl.cc:4559-4566`).

### 2.3 Merging notches during a running animation

`ScrollOffsetAnimationCurve::UpdateTarget` (`scroll_offset_animation_curve.cc:341-410`) receives `target + delta` from both threads (`scroll_offset_animations_impl.cc:124-141`, `scroll_animator.cc:114-116, 165-193`):

1. The target accumulates: new target = old target + this notch's delta, clamped to the scroll range. Nothing is dropped, not even on a direction change.
2. Distance left: Δ = new target − current position. The current speed v comes from the curve's slope (`:315-325`).
3. New duration: `T' = min(T(Δ), 2.5 × Δ / v)`. The second term only counts while v points toward the new target (`:81-101, 185-198`).
4. Speed continuity: the new curve keeps the ease-in-out shape with a scaled first control point, `cubic-bezier(0.42, 0.42·s, 0.58, 1)` with `s = clamp(v × T' / Δ, −1000, 1000)` (`:70-79, 399-409`). Its initial slope is s, so the speed at the join equals v.
5. If T' < 10 ms, the animation jumps to the target (`:392-397`).
6. Reversal has no special case. A notch against the motion makes s negative: the content keeps going for a moment and then swings back (derived; vector D in §6). The removed impulse curve set the speed to zero on reversal instead (pre-removal `scroll_offset_animation_curve.cc:437-448`).

Spinning faster shortens the segments (more distance left, so T(Δ) moves toward 100 ms) and keeps the speed from dropping between notches. The distance per notch stays the same.

### 2.4 When Chrome does not animate

Smooth scrolling is on when `--enable-smooth-scrolling` is set, or when `--disable-smooth-scrolling` is absent and `gfx::Animation::ScrollAnimationsEnabledBySystem()` returns true (`content/browser/web_contents/web_contents_impl.cc:4049-4052`). On Windows that function returns the `SPI_GETCLIENTAREAANIMATION` value. If the query fails, it returns true except in a remote session (`ui/gfx/animation/animation_win.cc:19-49`). With animations off, each notch jumps 100 DIP at once.

### 2.5 Windows Scrolling Personality (history)

- 2020: Microsoft brought Edge Legacy's scrolling to Chromium: "Add percent-based scrolling for Windows" (CL 1776898, 2020-01-28) and impulse-style animations. The Edge blog (2020-04-02) said these were "enabled by default in all channels of the new Microsoft Edge", and that "Chromium browsers use a fixed scroll delta value (100px per mousewheel tick, 40px per scrollbar button click or keyboard arrow press)" [Edge blog].
- Parameters (pre-removal): 5 % of the scroller per line, so 15 % per notch, measured against `min(scroller, viewport)` (`ui/events/blink/blink_event_util.h:32-34`, `web_input_event_builders_win.cc:319-325`, `cc/input/scroll_utils.cc:15-33`). Impulse curve: `cubic-bezier(0.25, 0, 0, 1)` from rest, duration `clamp(1.5 ms × |Δ| in px, 200, 500)` ms, speed reset to zero on reversal (`cc/animation/scroll_offset_animation_curve.cc:43-49, 68-82, 258-272, 437-448`).
- Default in Chromium, off: `kWindowsScrollingPersonality` was `FEATURE_DISABLED_BY_DEFAULT`, with a `static_assert` that forbade enabling it on Mac (pre-removal `ui/base/ui_base_features.cc:159-176`). The impulse curve alone was on by default in Chromium for a short time until "Disable ImpulseScrollAnimations by default" (CL 2760506, 2021-03-15; merged to M90 as CL 2778734).
- Removal: Chromium issue 359747082, "Unship Windows Scrolling Personality": "WSP (Windows Scrolling Personality) was identified as a source of battery regressions, and we are planning to remove the code. We already disabled the feature in Edge." Microsoft engineers then removed the flag and the code: CL 6002351 (2024-11-13, main #1382457), CL 6020590 (2024-11-21), CL 6040435 (2024-11-27). M132 branched at #1381561 [chromiumdash], so M133 was the first release without the flag. User reports agree ((secondary): Brave and Vivaldi forums, Reddit).
- Today: Chrome and Edge both behave as described in §2.1 to §2.4. Edge is closed source and I found no Edge-specific wheel code or setting, so "Edge = Chromium" is an inference, backed by Microsoft's own statement and by Microsoft having written the removal.

## 3. Firefox on Windows

### 3.1 Distance

- Lines per notch come from `SPI_GETWHEELSCROLLLINES` (`widget/windows/WinMouseScrollHandler.cpp:876-912`). A value above 120 is treated as page mode. The event carries `(delta / 120) × lines` lines (`:808-827`).
- One line is the font's maximum height in the scrolled element (horizontally: the average character width), at least 5 device pixels (`layout/generic/ScrollContainerFrame.cpp:5189-5210`, `modules/libpref/init/StaticPrefList.yaml:14595-14600`).
- `mousewheel.system_scroll_override.enabled` is true on Windows (and GTK) and both factors are 200, so line scrolls are doubled (`StaticPrefList.yaml:14549-14574`, `widget/WidgetEventImpl.cpp:1199-1233`; APZ path: `gfx/layers/apz/src/AsyncPanZoomController.cpp:2122-2133`). Only page mode is exempt (`WinMouseScrollHandler.cpp:829-833`). Up to Firefox 115 the doubling applied only while lines and characters were both at the default 3 (`WinMouseScrollHandler.cpp:802-812, 1005-1009` at tag `FIREFOX_115_0_RELEASE`). Bugs 1659790 (Firefox 116) and 1845580 (Firefox 117) removed that condition.
- Result: about 3 × 17 × 2 ≈ 102 px per notch. Mozilla measured 17 px per line, and 102 px per notch at 3 lines against Chrome's 100 (bug 1418822 comment 40 (secondary)).
- One event never scrolls more than a page (`dom/events/EventStateManager.cpp:3773-3792`, `AsyncPanZoomController.cpp:2151-2160`).
- Acceleration is off: `mousewheel.acceleration.start = -1` (`StaticPrefList.yaml:14503-14516`; used in `dom/events/WheelHandlingHelper.cpp:431-439` and `AsyncPanZoomController.cpp:2135-2149`).

### 3.2 Animation

- Line-based wheel events scroll smoothly (`EventStateManager.cpp:3797-3817`). APZ creates a wheel animation with origin `MouseWheel` (`gfx/layers/apz/src/SmoothScrollAnimation.cpp:42-69`) and uses the Bezier physics unless `general.smoothScroll.msdPhysics.enabled` is set, which is the case only in Nightly builds (`SmoothScrollAnimation.cpp:82-104`, `StaticPrefList.yaml:7214-7218`).
- Duration = `clamp(2 × average of the last three notch intervals, 50, 200)` ms (`layout/generic/ScrollAnimationBezierPhysics.cpp:56-76`; prefs `general.smoothScroll.mouseWheel.durationMinMS = 50`, `durationMaxMS = 200` and `general.smoothScroll.durationToIntervalRatio = 200` at `StaticPrefList.yaml:7106-7145`; origin mapping in `gfx/layers/apz/src/APZPublicUtils.cpp:32-87`). The first notch of a series gets 200 ms because the interval history starts at 100 ms (`ScrollAnimationBezierPhysics.cpp:78-89`).
- Curve (per axis): `cubic-bezier(dt, dxy, 0.6, 1)` with `s = v × T / Δ`, `dt = 0.25 / √(1 + s²)` and `dxy = 0.25 × s / √(1 + s²)` (`ScrollAnimationBezierPhysics.cpp:91-113`; weights 0.25 and 0.4 at `StaticPrefList.yaml:7099-7104, 7207-7212`). A lone notch (v = 0) gets `cubic-bezier(0.25, 0, 0.6, 1)`.
- Merging: each notch adds its delta to the destination (`SmoothScrollAnimation.cpp:156-161`) and restarts the curve from the current position and speed. If the destination did not change and the new segment would end later, the old segment is kept (`ScrollAnimationBezierPhysics.cpp:26-33`).
- Shape (derived): a lone notch covers 21.5 % after a quarter of the time, 58.2 % at half time and 88.2 % at three quarters. Speed peaks at 1.5 × the mean, 38 % into the segment. It gets going sooner than Chrome's curve (12.9 % at a quarter) and settles more gently.

### 3.3 Modifiers and autoscroll

- Shift + wheel scrolls horizontally on Windows (`browser/app/profile/firefox.js:1446-1455`; action 4 is described at `modules/libpref/init/all.js:1802-1819`).
- Middle-click autoscroll: `general.autoScroll` is true everywhere except Linux (`firefox.js:252-256`).

## 4. Native Windows apps

| App or framework | Per notch | Animated | Evidence |
|---|---|---|---|
| Win32 edit and list box controls | lines setting × line height | no | [About Mouse Input] lists them as following the lines setting; pixel line heights unverified |
| File Explorer folder views | line steps | no | Microsoft's Tali Roth, as reported by Windows Latest, 2026-04-26 (secondary) |
| File Explorer Home and Gallery (WinUI 3) | not found | yes | same article (secondary) |
| XAML `ScrollViewer` (UWP, WinUI 2, WinUI 3), e.g. Settings | DirectManipulation decides. Fallback path: `min(viewport, round(delta × max(48, round(0.15 × viewport)) / 120))` | yes (DirectManipulation) | `dxaml/xcp/dxaml/lib/ScrollViewer_Partial.cpp:2795-2836`, `ScrollViewer_Partial.h:26-37`, `ScrollContentPresenter_Partial.cpp:645-801`. A user reports that Settings keeps scrolling smoothly with Windows animations turned off (secondary). |
| WinUI 3 `ScrollView` (InteractionTracker) | follows the wheel settings since Windows 10 1809; pixels per line not public | yes (compositor) | `controls/dev/ScrollPresenter/ScrollPresenter.cpp:2791-2804`; microsoft-ui-xaml issue #593. Uno Platform's clone uses 16 px × 3 = 48 px (`InteractionTracker.cs:137-145` (secondary)). |
| WPF `ScrollViewer` | 48 px per wheel event, whatever the delta or lines setting | no | `ScrollViewer.cs:2866-2867, 1101-1113`, `Primitives/ScrollContentPresenter.cs:119-129` |
| Excel (Microsoft 365) | smooth; can stop partway through a row | yes | [Excel blog] 2021-10-07 |
| Word | animated since Office 2013 when Windows animations are on | yes | Super User thread (secondary) |

Other switches: "Smooth-scroll list boxes" (`SPI_GETLISTBOXSMOOTHSCROLLING`) covers list boxes only, and `ScrollWindowEx(SW_SMOOTHSCROLL)` lets each app pick its own duration [SPI], [ScrollWindowEx]. I found no public numbers for the wheel animations of DirectManipulation or InteractionTracker (unverified), and I did not look at Notepad.

XAML and WPF apps move about half as far as a browser, and classic Win32 apps depend on each app's line height, so native apps offer no single distance to copy.

## 5. Horizontal scrolling and extras

- Tilt wheel (`WM_MOUSEHWHEEL`) in Chrome/Edge: `(delta / 120) × characters × 100/3` DIP, so 100 DIP per tilt event at the default 3 characters (`web_input_event_builders_win.cc:273-276, 301-306, 331-335`). If the system query fails, Chromium assumes 1 character (`:22-23`). Firefox uses characters × average character width × 2 (not measured).
- Tilt repeat: tilt has no press or release on Windows; the mouse or its driver repeats the event while the wheel is held, at a rate no Windows setting controls. The X-Mouse Button Control author reports about 50 ms (unverified: search summary of a forums.highrez.co.uk thread).
- Shift + wheel in Chrome/Edge: when the event has no horizontal part, x and y are swapped, so the page moves sideways by the vertical distance, 100 DIP. The code is Aura-only, which covers Windows and Linux but not Mac (`web_mouse_wheel_event.cc:119-129`, `mouse_wheel_event_queue.cc:154-164`). Firefox also scrolls sideways (§3.3). For File Explorer the reports disagree: it works on Windows 11 22H2 in one test and did not work in Details view on Windows 7 and 10 (unverified: forum posts).
- Ctrl + wheel zooms in Chrome/Edge, following Microsoft's convention (§1).
- Middle-click autoscroll is on by default in Chrome and Edge on Windows: "This is enabled by default on Windows only" (`third_party/blink/renderer/platform/runtime_enabled_features.json5:4260-4265`; I did not trace where Windows switches it on). Dead zone 15 DIP; speed per axis `8e-6 × distance^2.2` (`third_party/blink/renderer/core/page/autoscroll_controller.cc:55, 301-316`; units not traced). Firefox has it on as well (§3.3).

## 6. Test vectors (Chromium model, 100 px per notch)

Output of the reference model in the appendix, which follows `UpdateTarget` step by step (derived). Positions in px, times in ms after the first notch.

| Case | Notches at | Position at time | Animation ends |
|---|---|---|---|
| A: one notch | 0 | 25→3.1, 50→12.9, 75→29.3, 100→50.0, 125→70.7, 150→87.1, 175→96.9, 200→100.0 | 200.0 |
| B: three notches | 0, 50, 100 | 50→12.9, 100→59.5, 150→145.1, 200→245.9, 250→297.1 | 266.5 |
| C: ten notches | every 30 | 90→65.2, 180→358.5, 270→706.2, 300→808.4, 350→944.4, 400→996.6 | 421.7 |
| D: down, then up | +1 at 0, −1 at 60 | 30→4.5, 60→18.7, 90→33.5, 120→38.3, 150→32.9, 200→12.4 | 260.0 (back at 0) |

Firefox for comparison (my port of `ScrollAnimationBezierPhysics`, 102 px per notch, derived): one notch 25→6.8, 50→21.9, 100→59.4, 150→89.9, 200→102.0; three notches 50 ms apart end at 232 ms.

These numbers come from my models; none were measured on Windows. Before release, someone with Windows should log `scrollY` on every animation frame after single notches and after quick bursts in Edge, and compare (unverified).

## 7. Confidence and open questions

| Claim | Confidence | Basis |
|---|---|---|
| Windows has no wheel acceleration | high | docs, Settings, Insider notes (§1) |
| Chrome: 100 DIP per notch, 33.3 per line, linear | high | source, Microsoft's Edge blog, Mozilla's measurement |
| Chrome: curve, duration, merge rule | high | source at `08da355f` |
| Edge behaves like Chrome | medium-high | inferred from Microsoft's statement and the removal CLs; Edge source not available |
| Firefox distance, curve, durations | high for the code, medium for the 17 px line | source; Mozilla's measurement |
| Native app numbers | medium to low | partly open source; the rest closed or secondary |
| Tilt repeat rate | low | unverified |

Open questions:

1. Scroll limits: Chromium clamps the target to the scroller's range, so extra notches at the end of a page don't pile up. The macOS app cannot see that range. A reverse notch that arrives within about 200 ms of notches pushed past the end can be partly swallowed. Test whether anyone notices before adding a workaround.
2. "One screen at a time": Chrome uses 87.5 % of the scroller's height. The app can only see the window under the pointer, or with the Accessibility API the scroll area. Someone has to pick one.
3. Event delivery on macOS (mac-hid's area): continuous pixel events without momentum phases, and how macOS "Natural scrolling" and its own Shift-to-horizontal conversion treat events we post.
4. Ctrl + wheel zoom and middle-click autoscroll are product decisions, separate from the scrolling curve.
5. Nobody has checked the numbers on a Windows machine yet (see §6).

## 8. Target spec for macOS

Distances are in points (pt); 1 pt = 1 Windows DIP.

Input: one notch is 120 units. High-resolution devices deliver fractions `n = delta / 120` (mac-hid provides these).

Vertical distance: `d = n × L × 100/3 pt`, where L is lines per notch (default 3). That is 100 pt per notch, linear in n, with no dependence on speed and no acceleration.

"One screen at a time": `d = n × 0.875 × H`, where H is the height of the scroll area under the pointer (open question 2).

Fresh notch (no animation running, or the last one has finished), at time t:

```
p0 = current position;  P = p0 + d;  t0 = t        // t = the notch's timestamp, so the
T  = Tinv(|d|);  f = cubic-bezier(0.42, 0, 0.58, 1)  // first frame after it already moves
position(τ) = p0 + (P − p0) · f((τ − t0) / T)
Tinv(x) = clamp(14 − x / 60, 6, 12) / 60 s          // 200 ms up to 120 pt, 100 ms from 480 pt
```

Notch during an animation, at time t:

```
P'  = P + d                                    // the target accumulates; no distance is dropped
p   = position(t);  v = f'((t − t0) / T) · (P − p0) / T
Δ   = P' − p
if |Δ| < 0.01 pt:  stop at P'
Tb  = (|v| ≥ 0.01 and Δ / v > 0) ? 2.5 · Δ / v : ∞
T'  = min(Tinv(|Δ|), Tb);  if T' < 10 ms: jump to P'
s   = clamp(v · T' / Δ, −1000, 1000)
f   = cubic-bezier(0.42, 0.42 · s, 0.58, 1);  p0 = p;  P = P';  t0 = t;  T = T'
```

Output: on every display refresh, post the difference between `position(now)` and what has been posted so far as a pixel scroll event, carrying the sub-point remainder. Post nothing after the target is reached: no momentum or inertia.

Smooth scrolling off: post `d` at once for each notch. This is what Chrome does with Windows animations off, and what classic Win32 apps always do.

Horizontal:

- Tilt or horizontal wheel: `d = n × C × 100/3 pt`, where C is characters per tilt (default 3), so 100 pt, with the same animation and merge rules on the x axis. Keep separate state per axis. (Chromium runs one 2-D curve per scroller; that only differs when both axes move at once.)
- Shift + vertical wheel: move along x by the vertical distance (100 pt), only when the event has no x component.
- Direction: wheel away from the user scrolls toward the top of the document, tilt right scrolls right (Windows' default "Down motion scrolls down").
- Routing: macOS already sends wheel events to the view under the pointer, which matches Windows with "Scroll inactive windows" on (mac-hid to confirm).

User settings, with the same names and defaults as Windows:

| Setting | Values | Windows equivalent |
|---|---|---|
| Roll the wheel to scroll | Multiple lines (default) / One screen at a time | Settings > Mouse > Roll the mouse wheel to scroll |
| Lines to scroll at a time | integer, default 3 | Settings > Mouse > Lines to scroll at a time |
| Characters to scroll per tilt | integer, default 3 | Mouse Properties > Wheel > Horizontal Scrolling |
| Scrolling direction | Down motion scrolls down (default) / up | Settings > Mouse > Scrolling direction |
| Smooth scrolling | on by default, off while macOS Reduce Motion is on | Chrome follows `SPI_GETCLIENTAREAANIMATION` |

Not exposed: curve, duration, acceleration. Windows offers none of these.

Out of scope: percent-based scrolling and the impulse curve (removed from Chrome and Edge), Firefox's curve (could become a second profile if users ask), the 48 px of native XAML and WPF.

## Appendix: reference model (Python)

Port of the Chromium curve above, one axis. `python3 model.py` prints `ok` when it reproduces the §6 table.

```python
"""Chromium (Chrome/Edge) mouse-wheel scroll animation, 1 axis, px (= macOS pt).
Port of cc/animation/scroll_offset_animation_curve.cc @ 08da355f (EaseInOut + kInverseDelta)."""
EPS = 0.01

class Bezier:
    def __init__(s, x1, y1, x2, y2):
        s.cx = 3*x1; s.bx = 3*(x2 - x1) - s.cx; s.ax = 1 - s.cx - s.bx
        s.cy = 3*y1; s.by = 3*(y2 - y1) - s.cy; s.ay = 1 - s.cy - s.by
    def _x(s, t): return ((s.ax*t + s.bx)*t + s.cx)*t
    def _y(s, t): return ((s.ay*t + s.by)*t + s.cy)*t
    def _dx(s, t): return (3*s.ax*t + 2*s.bx)*t + s.cx
    def _dy(s, t): return (3*s.ay*t + 2*s.by)*t + s.cy
    def _solve(s, x):                      # x is monotonic in t because x1, x2 are in [0, 1]
        lo, hi = 0.0, 1.0
        for _ in range(100):
            t = (lo + hi)/2
            if s._x(t) < x: lo = t
            else: hi = t
        return (lo + hi)/2
    def value(s, x): return 0.0 if x <= 0 else 1.0 if x >= 1 else s._y(s._solve(x))
    def slope(s, x):
        t = s._solve(min(max(x, 0.0), 1.0)); dx, dy = s._dx(t), s._dy(t)
        return 0.0 if dx == 0 and dy == 0 else dy/dx

def ease(slope=0.0):                        # cubic-bezier(0.42, 0.42*slope, 0.58, 1)
    return Bezier(0.42, 0.42*max(-1000.0, min(1000.0, slope)), 0.58, 1)

def t_inv(d):                               # seconds; 200 ms up to 120 px, 100 ms from 480 px
    return min(max(14.0 - abs(d)/60.0, 6.0), 12.0)/60.0

class WheelAnimation:
    def __init__(s, pos=0.0): s.p0 = s.target = pos; s.t0 = s.T = 0.0; s.f = ease()
    def position(s, t):
        x = (t - s.t0)/s.T if s.T > 0 else 1.0
        return s.target if x >= 1 else s.p0 if x <= 0 else s.p0 + (s.target - s.p0)*s.f.value(x)
    def velocity(s, t):
        x = (t - s.t0)/s.T if s.T > 0 else 1.0
        return 0.0 if x >= 1 else s.f.slope(x)*(s.target - s.p0)/s.T
    def notch(s, t, d):                     # d = signed distance of this notch
        if t >= s.t0 + s.T:                 # idle: fresh ease-in-out segment
            s.p0 = s.target; s.target += d; s.t0 = t; s.T = t_inv(d); s.f = ease(); return
        new_target = s.target + d
        p, v = s.position(t), s.velocity(t)
        delta = new_target - p
        if abs(delta) < EPS: s.target, s.T = new_target, t - s.t0; return
        bound = (delta/v)*2.5 if abs(v) >= EPS else float("inf")
        T = min(t_inv(delta), bound if bound >= 0 else float("inf"))
        if T < EPS: s.target, s.T = new_target, t - s.t0; return      # jump
        s.f = ease(v*T/delta); s.p0, s.target, s.t0, s.T = p, new_target, t, T

def trajectory(notches, marks_ms, px=100.0):
    a = WheelAnimation(); events = sorted([(t, 0, sgn) for t, sgn in notches] + [(m/1000, 1, m) for m in marks_ms])
    out = []
    for t, kind, v in events:
        if kind == 0: a.notch(t, v*px)
        else: out.append(round(a.position(t), 1))
    return out, round((a.t0 + a.T)*1000, 1)

if __name__ == "__main__":
    assert t_inv(100) == 0.2 and abs(t_inv(480) - 0.1) < 1e-12
    assert trajectory([(0, 1)], [25, 50, 75, 100, 125, 150, 175, 200]) == \
        ([3.1, 12.9, 29.3, 50.0, 70.7, 87.1, 96.9, 100.0], 200.0)
    assert trajectory([(0, 1), (.05, 1), (.10, 1)], [50, 100, 150, 200, 250]) == \
        ([12.9, 59.5, 145.1, 245.9, 297.1], 266.5)
    assert trajectory([(i*.03, 1) for i in range(10)], [90, 180, 270, 300, 350, 400]) == \
        ([65.2, 358.5, 706.2, 808.4, 944.4, 996.6], 421.7)
    assert trajectory([(0, 1), (.06, -1)], [30, 60, 90, 120, 150, 200]) == \
        ([4.5, 18.7, 33.5, 38.3, 32.9, 12.4], 260.0)
    print("ok")
```

## Sources

Source code, read first-hand:

- Chromium main `08da355f5163273673e9203114c3fbea92f87a1f` (GitHub mirror, fetched 2026-09-26): https://github.com/chromium/chromium/tree/08da355f5163273673e9203114c3fbea92f87a1f
- Chromium pre-removal `176f765873d48abe1e327aad04baf3a8718261bc`: https://github.com/chromium/chromium/tree/176f765873d48abe1e327aad04baf3a8718261bc
- Chromium changes: [CL 1776898](https://chromium-review.googlesource.com/c/chromium/src/+/1776898) (percent-based scrolling, 2020), [CL 2760506](https://chromium-review.googlesource.com/c/chromium/src/+/2760506) and [CL 2778734](https://chromium-review.googlesource.com/c/chromium/src/+/2778734) (impulse off by default, 2021), [CL 6002351](https://chromium-review.googlesource.com/c/chromium/src/+/6002351), [CL 6020590](https://chromium-review.googlesource.com/c/chromium/src/+/6020590), [CL 6040435](https://chromium-review.googlesource.com/c/chromium/src/+/6040435) (removal, 2024)
- Chromium issue 359747082, "Unship Windows Scrolling Personality": https://issues.chromium.org/issues/359747082 (text read through the tracker's JSON endpoint `https://issues.chromium.org/action/issues/359747082`)
- [chromiumdash] milestone branch points: https://chromiumdash.appspot.com/fetch_milestones?only_branched=true
- Firefox main `c32abda0190531351e22da36334f18f9e994d474`: https://github.com/mozilla-firefox/firefox/tree/c32abda0190531351e22da36334f18f9e994d474 ; old behaviour at tag `FIREFOX_115_0_RELEASE`: https://github.com/mozilla-firefox/firefox/blob/FIREFOX_115_0_RELEASE/widget/windows/WinMouseScrollHandler.cpp
- microsoft-ui-xaml `25e7dbb156afb1a7605d7b21d68305efab0738a3`: https://github.com/microsoft/microsoft-ui-xaml/tree/25e7dbb156afb1a7605d7b21d68305efab0738a3 ; issue #593: https://github.com/microsoft/microsoft-ui-xaml/issues/593
- dotnet/wpf `7fc2bd9ddc3e6575c1d64dab64f5e19e905a7fd6` (`src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/`): https://github.com/dotnet/wpf/tree/7fc2bd9ddc3e6575c1d64dab64f5e19e905a7fd6
- Uno Platform `bd315218448acbf2c27b554696a7a858378ecdd4` (third-party WinUI clone, (secondary)): https://github.com/unoplatform/uno/blob/bd315218448acbf2c27b554696a7a858378ecdd4/src/Uno.UI.Composition/Composition/InteractionTracker/InteractionTracker.cs

Microsoft documentation:

- [WM_MOUSEWHEEL]: https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-mousewheel
- [WM_MOUSEHWHEEL]: https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-mousehwheel
- [SPI] SystemParametersInfoW: https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-systemparametersinfow
- [About Mouse Input]: https://learn.microsoft.com/en-us/windows/win32/inputdev/about-mouse-input
- [ScrollWindowEx]: https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-scrollwindowex
- [Other mouse operations]: https://learn.microsoft.com/en-us/windows/win32/learnwin32/other-mouse-operations
- [Best practices 2004] "Best Practices for Supporting Microsoft Mouse and Keyboard Devices" (Kevin Smith, April 2004): https://learn.microsoft.com/en-us/previous-versions/ms997498(v=msdn.10)
- [Settings] "Change mouse settings": https://support.microsoft.com/en-US/Windows/Hardware/Input-Devices/change-mouse-settings
- [Insider 26220.8925] release notes, 20 July 2026: https://learn.microsoft.com/en-us/windows-insider/release-notes/beta/preview-build-26220-8925
- [Edge blog] "Scrolling personality improvements in Microsoft Edge", 2020-04-02: https://blogs.windows.com/msedgedev/2020/04/02/scrolling-personality-improvements
- [Excel blog] "Smooth Scrolling comes to Excel for Windows", 2021-10-07: https://techcommunity.microsoft.com/blog/excelblog/smooth-scrolling-comes-to-excel-for-windows/2823555

Bug trackers:

- Mozilla bug 1418822, comment 40 (Chrome vs Firefox px per notch): https://bugzilla.mozilla.org/show_bug.cgi?id=1418822#c40
- Mozilla bug 1659790 (Firefox 116) and 1845580 (Firefox 117): https://bugzilla.mozilla.org/show_bug.cgi?id=1659790 , https://bugzilla.mozilla.org/show_bug.cgi?id=1845580

Secondary, or unverified where marked:

- Windows Latest, "Microsoft explains why Windows 11 File Explorer scrolls smoothly in some places, but not everywhere", 2026-04-26: https://www.windowslatest.com/2026/04/26/microsoft-explains-why-windows-11-file-explorer-scrolls-smoothly-in-some-places-but-not-everywhere
- Microsoft Q&A, "Disable smooth scrolling in Windows 11" (Settings keeps smooth scrolling): https://learn.microsoft.com/en-us/answers/questions/3833882/disable-smooth-scrolling-in-windows-11
- Super User 544523 (Office 2013 smooth scrolling): https://superuser.com/questions/544523
- Windows Report, 2024-11-14; Brave Community; Vivaldi forum; Reddit (flag gone in M133): https://windowsreport.com/chrome-is-ditching-microsofts-scrolling-improvements-due-to-battery-performance-issues , https://community.brave.app/t/please-keep-the-windows-scrolling-personality-flag/593654 , https://forum.vivaldi.net/topic/106460
- Peter Hutterer, Linux HID patch notes on the Resolution Multiplier (search summary, unverified): https://lkml.iu.edu/hypermail/linux/kernel/1811.2/06027.html
- X-Mouse Button Control forum on tilt repeat (search summary, unverified): https://forums.highrez.co.uk/viewtopic.php?t=4902
- Shift + wheel in File Explorer (search summaries, unverified): https://www.autohotkey.com/boards/viewtopic.php?t=76415 , https://www.elevenforum.com/t/change-mouse-horizontal-scrolling-setting-in-windows-11.12444/

[WM_MOUSEWHEEL]: https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-mousewheel
[WM_MOUSEHWHEEL]: https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-mousehwheel
[SPI]: https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-systemparametersinfow
[About Mouse Input]: https://learn.microsoft.com/en-us/windows/win32/inputdev/about-mouse-input
[ScrollWindowEx]: https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-scrollwindowex
[Other mouse operations]: https://learn.microsoft.com/en-us/windows/win32/learnwin32/other-mouse-operations
[Best practices 2004]: https://learn.microsoft.com/en-us/previous-versions/ms997498(v=msdn.10)
[Settings]: https://support.microsoft.com/en-US/Windows/Hardware/Input-Devices/change-mouse-settings
[Insider 26220.8925]: https://learn.microsoft.com/en-us/windows-insider/release-notes/beta/preview-build-26220-8925
[Edge blog]: https://blogs.windows.com/msedgedev/2020/04/02/scrolling-personality-improvements
[Excel blog]: https://techcommunity.microsoft.com/blog/excelblog/smooth-scrolling-comes-to-excel-for-windows/2823555
[chromiumdash]: https://chromiumdash.appspot.com/fetch_milestones?only_branched=true
