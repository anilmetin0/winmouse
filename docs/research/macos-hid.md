# macOS HID pointer and scroll internals (macOS 27)

Research note, 2026-09-26. Scope: where macOS applies pointer and wheel acceleration in user space, what a normal signed (unentitled, non-sandboxed) app can change there, how long those changes live, and what an event tap can and cannot do. Goal of the product: an external mouse that feels like Windows ("Enhance pointer precision" curve, Windows wheel), without touching the built-in trackpad and without a kernel or DriverKit extension. The Windows side is in [windows-pointer.md](windows-pointer.md) and [windows-scroll.md](windows-scroll.md); prior art is in [existing-apps.md](existing-apps.md).

How to read the evidence:

- `IOHIDFamily:path:line` is the open-source tag **IOHIDFamily-2238.120.5** (newest tag on 2026-09-26, commit `e31e90a2`). The plugin installed on this Mac is newer: `IOHIDPointerScrollFilter.plugin/Contents/version.plist` reports `SourceVersion 2360001002000000` (IOHIDFamily 2360.1.2). Where it matters I checked the installed binary (marked **binary**).
- `IOKit@0x…` is disassembly of `/System/Library/Frameworks/IOKit.framework` from the dyld shared cache of this Mac (`dyld_info -disassemble`). Apple ships `IOHIDService.c`, `IOHIDEventSystemConnection.c` etc. as empty files in every IOKitUser tag, so the server side is only visible this way.
- **probe** is a program I wrote and ran on this Mac (macOS 27.0, build 26A428, Xcode SDK 27.0, Apple Silicon T6050). Scratch copies live in the session scratchpad (`mac-hid/`), not in the repo.
- **(secondary)** is third-party code or text I read but did not run. **unverified** means no first-hand check.
- Numbers in the filter are 16.16 fixed point ("fixed") unless stated otherwise.

---

## Summary

**(a) Pointer curve.** The whole mouse acceleration runs in user space in `hidd`, inside the service filter `IOHIDPointerScrollFilter`, per HID service (per device). Its inputs are per-service properties. A client of the HID event system can replace the curve of one mouse with an **Apple-format acceleration table** (`HIDPointerAccelerationTable`) and force its use with `HIDPointerAccelerationAlgorithm = 0`. The table is a piecewise-linear gain on per-report speed, which is the same shape as Windows' SmoothMouse curve. The shape can be reproduced exactly; the speed metric cannot (macOS uses `floor(√(dx²+dy²))`, Windows `max + min/2`), so diagonal motion looks up a speed up to 11.8 % lower (6.1 % at 45°, windows-pointer.md §1.2). Cost at runtime: zero for our app, no TCC permission. Catch: the keys that matter are only reachable through a **private** client type (`IOHIDEventSystemClientCreate` / `…CreateWithType`); the public `IOHIDEventSystemClientCreateSimpleClient` is restricted to a 30-key whitelist that contains the acceleration *index* keys but no curve keys.

**(b) Scrolling.** Wheel acceleration runs in the same filter (`IOHIDScrollAccelerator`), per device, and can be flattened per device with the same private client: `HIDSupportsScrollAcceleration = false`, or a linear `UserScrollAccelCurvesKey` for exactly N lines per detent. The public simple client cannot do it: its only scroll key, `HIDMouseScrollAcceleration`, set to −1 on a live device leaves the previously built accelerators running (§1.7). Anything beyond "N lines per notch" (Chrome-style 100 px per notch with animation, per-device direction while the trackpad keeps natural scrolling) needs an active event tap that swallows wheel events and posts pixel scroll events. That needs the Accessibility privilege. The tap can identify the sending device through undocumented CGEvent field 87 (registry ID of the HID service) and tell natural-scrolling inversion from field 137.

**Restore semantics.** Nothing we set per service is written to preferences. Every value we set is merged into the kernel dictionary `HIDEventServiceProperties` of that device's `IOHIDEventService` and is read back by the filter from there. It survives a `hidd` restart and a logout, and disappears when the device is unplugged/reconnected or the Mac reboots. Keys cannot be deleted from that dictionary, only overwritten, so "restore" means writing back the original values.

---

## 1. Where acceleration happens and the exact math

### 1.1 Pipeline

1. Kernel HID driver (`IOHIDEventDriver`, or the DriverKit-backed `AppleUserHIDEventService`, which subclasses it: `IOHIDFamily:IOHIDFamily/AppleUserHIDEventService.h:36`) turns reports into `IOHIDEvent`s. Wheel: one detent = `1.0` (`value << 16`) on the scroll axis (`IOHIDFamily:IOHIDFamily/IOHIDEventDriver.cpp:4297-4325`). No code in the open driver uses `kHIDUsage_GD_ResolutionMultiplier` (0x48), so high-resolution wheel mode is not enabled there (repo-wide `rg`, only the enum definition matches; the closed DriverKit driver is **unverified**).
2. In `hidd`, the service filter `IOHIDPointerScrollFilter` matches services conforming to GD/Mouse, GD/Pointer, AppleVendor/Pointer or Digitizer/TouchPad (`IOHIDFamily:IOHIDEventSystemPlugIns/IOHIDPointerScrollFilter.cpp:429-439`). For every relative pointer or scroll event it computes an accelerated copy, flags it `kIOHIDAccelerated` (0x10000) and appends it as a child of the original (`…PointerScrollFilter.cpp:537-627`).
3. The session filter `IOHIDNXEventTranslatorSessionFilter` builds the legacy NX events for WindowServer. **binary**: `_IOHIDPointerEventTranslatorCreateEventCollection` walks the children and picks the one with bit 16 (`kIOHIDAccelerated`) set, for pointer (type 0x11) and scroll (type 6) events (`tbnz w0, #0x10` at 0x6604/0x664C/0x6688/0x66D8 of the installed plugin). So every CGEvent delta you see, at any tap location, is already accelerated.
4. WindowServer turns NX events into CGEvents and runs event taps.

The installed binary matches the source in the parts that matter: the 19-key cached-property list decodes to the same keys in the same order (**binary**, `_cachedPropertyList` fixups at `__DATA,__data 0x18000…0x18090`), `IOHIDPointerAccelerator::accelerate` does `sqrt → frintm (floor) → ×multiplier → max(…, 2^-16) → algorithm->multiplier(v)/v` (**binary** 0x102C-0x1130), the parametric multiplier ends with `× 1.4328358208955223` (= 96/67, **binary** constant at 0x97D0), and the scroll constants are 500, 150, 67, −0.014572…, 1.500992…, 0.100006… (**binary** 0x96B8-0x96E0).

### 1.2 Which properties feed the filter

`setPropertyForClient` accepts exactly these keys, caches them and re-runs `setupAcceleration()` (`…PointerScrollFilter.cpp:354-374, 384-419`):

| Key (string value) | Meaning in the filter |
|---|---|
| `HIDPointerAccelerationType` | Name of the key that holds the pointer acceleration index. Mice get `HIDMouseAcceleration` from the driver (`IOHIDEventDriver.cpp:1595-1596`), pure pointers `HIDPointerAcceleration` (`:1613-1614`). |
| `HIDMouseAcceleration`, `HIDPointerAcceleration`, `HIDTrackpadAcceleration` | Acceleration index `a` (fixed). `a < 0` disables pointer acceleration entirely (`:860-862`). |
| `HIDScrollAccelerationType`, `HIDMouseScrollAcceleration`, `HIDScrollAcceleration`, `HIDTrackpadScrollAcceleration` | Same for scroll (`:931-959`); a negative value does not disable scroll acceleration on a live device (§1.7). |
| `HIDUseLinearScalingMouseAcceleration` | Linear mode, only when the type is `HIDMouseAcceleration` (`:866-886`). |
| `UserPointerAccelCurvesKey`, `UserScrollAccelCurvesKey` | User parametric curves (array of curve dicts). The string values are private; I decoded them from the installed binary's cached-key list (**binary**). |
| `HIDPointerAccelerationAlgorithm`, `HIDScrollAccelerationAlgorithm` | 0 = table, 1 = parametric, 2 = default selection (`IOHIDFamily/IOHIDKeys.h:455-485`; used at `…PointerScrollFilter.cpp:670-695, 749-774`). Present in tag 2008.80.3.0.1 and every later tag I checked; older tags have a different file layout and were not checked. |
| `HIDPointerAccelerationMultiplier` | Multiplies the *speed fed to the curve* (fixed, default 1.0) (`:1011-1019`, `IOHIDAcceleration.cpp:158`). |
| `HIDSupportsPointerAcceleration`, `HIDSupportsScrollAcceleration` | Booleans; `false` bypasses acceleration (`:797-802, 917-922`). |
| `HIDPointerReportRate` | **Plain integer Hz, not fixed** (passed as `(SInt32)defaultRate`, `:891`). If non-zero and the multiplier is 1.0, speed is scaled by `min(1, (1000/rate)/Δt_ms)` (`IOHIDAcceleration.cpp:143-158`). Default 0 = off. |
| `HIDScrollReportRate` | Fixed (default `67 << 16`) (`:963-970`). |
| `HIDPointerAccelerationMinimum` | Floor used in linear mode when `a == 0` (default 0.1) (`:871-883`). |

These are **not** in the cached list and are read straight from the service with `IOHIDServiceCopyProperty` each time `setupAcceleration()` runs: `HIDPointerResolution` (`:804`), `HIDScrollResolution[X|Y|Z]` (`:984-987`), `HIDPointerAccelerationTable` (`:630`), `HIDScrollAccelerationTable[X|Y|Z]` (`:705-709`), `HIDAccelCurves` and `HIDScrollAccelCurves` (driver curves, `:657, :736`). Setting them alone changes nothing until one cached key is set afterwards. LinearMouse hits exactly this: "HACK: Reapply an available acceleration value to make `pointerResolution` take effect." (`linearmouse/Modules/PointerKit/Sources/PointerKit/PointerDevice.swift:406-416`, secondary).

Defaults: pointer resolution 400 dpi when the driver publishes none (`…PointerScrollFilter.h:24`, `.cpp:806-812`; driver side `IOHIDEventService.cpp:77, 696-697` and the HID physical-units formula at `:1000-1045`); scroll resolution 9.0 (`IOHIDEventService.cpp:78, 701-702`). If the service has `HIDCompatibilityInterface` (legacy kernel shim) the filter only multiplies pointer by 1 and scroll by 0.1 (`…PointerScrollFilter.cpp:54-55, 782-787, 908-915`).

### 1.3 Pointer: velocity

`IOHIDPointerAccelerator::accelerate` (`IOHIDFamily:IOHIDEventSystemPlugIns/IOHIDAcceleration.cpp:136-171`), once per pointer event (= once per HID report):

```
v = floor(sqrt(dx² + dy²))                       // counts per report, floored
v *= (multiplier == 1.0) ? rateMul : multiplier  // rateMul = 1 unless HIDPointerReportRate is set
v  = max(v, 1/65536)
k  = algorithm.multiplier(v) / v
(dx, dy) *= k                                    // same gain on both axes, doubles, no rounding here
```

No averaging, no time normalisation by default: like Windows, speed is counts per packet, so the polling rate changes the feel. The timestamp is only used when `HIDPointerReportRate` is set.

### 1.4 Pointer: table algorithm (`HIDPointerAccelerationTable`)

Binary format, all fields big-endian (`IOHIDFamily:IOHIDEventSystemPlugIns/IOHIDAccelerationTable.hpp:27-89`, `IOHIDAccelerationTable.cpp`):

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | scale, fixed. Ignored by the current algorithm (only the unused `CreateOriginalWithTable` reads it). |
| 4 | 4 | signature bytes `@200` (0x40 0x32 0x30 0x30) or `USB*`; anything else is rejected (`IOHIDAccelerationAlgorithm.cpp:334-339`). |
| 8 | 2 | N = number of curves |
| 10… | | N × { 4 bytes acceleration index (fixed), 2 bytes M = point count, M × (4 bytes x fixed, 4 bytes y fixed) } |

`IOHIDTableAcceleration::CreateWithTable(table, a, res, rate=67)` (`IOHIDAccelerationAlgorithm.cpp:327-401`):

1. Walk the curves in order; `hi` = first curve with `a ≤ index`, `lo` = the one before. If `a` equals an index, or lies outside the table, one curve is used and every y is multiplied by `(a + 1) / (index + 1)`. Otherwise the two curves are blended point-wise with `ratio = (a − lo) / (hi − lo)` (`:279-325`).
2. Each point becomes `(x · res / 67, y · 96 / 67)` and a line segment from the previous point, starting at `(0, 0)`.
3. `multiplier(v)` evaluates the first segment whose end x ≥ v; above the last point the last segment is extrapolated (`:539-551`).

So the device-speed → cursor-speed map is **piecewise linear through the origin**, with output `out(v) = PL(v)` in points per report. For a single-curve custom table with index `a0` and the live index equal to `a0`:

```
x_i = v_i · 67 / res          // v_i: knot in counts per report
y_i = g(v_i) · 67 / 96        // g: desired output, points per report
```

This reproduces any piecewise-linear g exactly up to 16.16 rounding. Points are counted as `uint16`, so curves are not size-limited in practice. Avoid a point at x = 0 (division by zero in the slope). The built-in fallback table (used when a service has no table and no curves) decodes to two curves: index 0 → `[(1,1)]`, index 1 → nine points from `(0.4423, 0.375)` to `(40, 150)` (`…PointerScrollFilter.cpp:63-78`, decoded by `accel_sim.py`). With this table at 400 dpi and index 0.875 (this Mac's `com.apple.mouse.scaling`), my re-implementation gives 0.235, 0.471, 1.824, 5.405, 12.654, 35.11 points for 1, 2, 4, 8, 16, 32 counts per report (**probe** `accel_sim.py`, which also asserts that a custom single-curve table returns `y·96/67` at every knot).

**Gap to Windows** ([windows-pointer.md §1.2](windows-pointer.md)): Windows looks up `max(|dx|,|dy|) + min/2`, macOS `floor(√(dx²+dy²))`. Identical for axis-aligned motion. At 45° Windows sees 1.5·d where macOS sees ⌊1.414·d⌋ (6.1 % lower); the largest gap is 11.8 % at 26.6° (dy/dx = 0.5), plus the floor at small d (windows-pointer.md §1.2). The per-axis sub-pixel remainder of Windows has no counterpart in the filter (it outputs doubles); what WindowServer does with fractions is **unverified**. I assume the filter output is in points, the unit of the cursor position (the constants say 96 units per inch at 67 Hz: `IOHIDAcceleration.hpp:30-31`, `IOHIDAccelerationAlgorithm.hpp:23`); **unverified** on hardware.

### 1.5 Pointer: parametric algorithm (`HIDAccelCurves`, `UserPointerAccelCurvesKey`)

Each curve is a dictionary of fixed-point numbers: `HIDAccelIndex`, `HIDAccelGainLinear` (G1), `HIDAccelGainParabolic` (G2), `HIDAccelGainCubic` (G3), `HIDAccelGainQuartic` (G4), `HIDAccelTangentSpeedLinear` (T1), `HIDAccelTangentSpeedParabolicRoot` (T2) (`IOHIDAccelerationAlgorithm.cpp:89-109`; key strings in `IOHIDSystem/IOKit/hidsystem/IOHIDParameter.h:162-170`). `HIDAccelTangentSpeedCubicRoot` / `QuarticRoot` exist in the header but are not read. Curve choice: the last valid curve with `Index ≤ a`, all seven parameters linearly interpolated toward the next curve (`:111-165`). Invalid curves (all gains 0) are skipped but the index bookkeeping still uses the array position, so keep every curve valid.

With `s = v · 67 / res` (`:211-214`), the code actually computes (the header comment at `:18-86` differs: the gain sits inside the power):

```
f1(s) = G1·s + (G2·s)² + (G3·s)³ + (G4·s)⁴                         for s ≤ T1   (or all s if T1 = 0 and T2 = 0)
f2(s) = m0·s + b0,  m0 = G1 + 2·T1·G2² + 3·T1²·G3³ + 4·T1³·G4⁴,  b0 = f1(T1) − m0·T1     for T1 < s ≤ T2
f3(s) = sqrt(m1·s + b1),  m1 = 2·f2(T2)·m0,  b1 = f2(T2)² − m1·T2                        for s > T2
multiplier(v) = f(s) · 96 / 67                                       (:172-205, :216-255)
```

When T1 = 0 but T2 ≠ 0 the code uses `m1 = f1'(T2)` without the `2·y` factor (`:193-205`), so that branch is not slope-continuous. A parametric curve can only approximate a 5-point piecewise-linear Windows curve.

**Selection** (`…PointerScrollFilter.cpp:670-695`): if `HIDPointerAccelerationAlgorithm` is 0 → table, 1 → parametric, 2 or absent → parametric if `UserPointerAccelCurvesKey` (non-empty) or the service's `HIDAccelCurves` exist, else table. Mac Mouse Fix could not get tables to work on Ventura because `HIDAccelCurves` was always present and wins the default selection (`mac-mouse-fix/Helper/Core/PointerSpeed/PointerSpeed.m:312-317`, secondary); the algorithm key is the way around that.

### 1.6 Pointer: linear mode and "off"

- Linear: if the type is `HIDMouseAcceleration` and `HIDUseLinearScalingMouseAcceleration ≠ 0`, the accelerator is `IOHIDSimpleAccelerator(a)`: `(dx, dy) *= a`, where `a` is the `HIDMouseAcceleration` value, replaced by `HIDPointerAccelerationMinimum` (or the same key in the HID preference domain, which is probably `com.apple.iohid`: the constant is private and that is the only domain string in the binary, or 0.1) when `a == 0` (`…PointerScrollFilter.cpp:866-886`, `IOHIDAcceleration.cpp:23-31`). No resolution normalisation: a 1600 dpi mouse moves 4× farther than a 400 dpi mouse at the same slider. This is the Sonoma+ "Pointer acceleration" switch; System Settings' Mouse pane references this key (`strings` of `/System/Library/ExtensionKit/Extensions/MouseExtension.appex/Contents/MacOS/MouseExtension`).
- Off: `a < 0` (for example −1.0 = `0xFFFF0000`) creates no accelerator at all; raw counts pass through (`:860-862`). LinearMouse uses −1 on pre-Sonoma systems (secondary, `PointerDevice.swift:451-468`).

### 1.7 Scroll acceleration

Per axis, `IOHIDScrollAccelerator::accelerate` (`IOHIDFamily:IOHIDEventSystemPlugIns/IOHIDAcceleration.cpp:35-118`, constants `IOHIDAcceleration.hpp:21-31`):

```
Δt  = ms since previous scroll event on this accelerator
ring buffer of the last 9 events {Δt, |scroll|}; cleared on direction change or Δt > 500 ms
walk back from the newest: sum |scroll| and Δt; an event with Δt > 150 adds 150 and stops; stop at ΣΔt ≥ 500
rateMul = HIDScrollReportRate / 67                                  (1.0 by default)
t̄   = clamp((ΣΔt / n) · rateMul, 1, 150)
s̄   = Σ|scroll| / n
vel = (A·t̄² − B·t̄ + C) · s̄ · rateMul,  A = 2/65536, B = 0x3BB/65536 ≈ 0.014572, C = 0x18041/65536 ≈ 1.500992
vel = max(vel, 1/65536)
table:      if n > 2: vel *= sqrt(n);   mult = table(vel) / |scroll|
parametric:                             mult = f(vel) / vel
scroll_out = scroll · mult · 0.100006   (SCROLL_PIXEL_TO_WHEEL_SCALE = 0x199A/65536)
```

Momentum events are pre-scaled by `ScrollMomentumDispatchRate / 60` (`…PointerScrollFilter.cpp:575-609`). Table and parametric curves use `res = HIDScrollResolution` (9.0 default) and `rate = 67`. Selection and keys mirror the pointer side (`:704-774`); the index comes from `HIDMouseScrollAcceleration` for mice (`com.apple.scrollwheel.scaling`, 0.5 here).

A purely linear parametric scroll curve (`G1 = g`, everything else 0) gives a constant factor per notch: `f(v)/v = g · 67/9 · 96/67 = 10.667·g`, so `scroll_out = 1.0667·g` per detent (derived from the code above). The session translator then writes it into the NX event as, per axis (**binary**, `___IOHIDPointerEventTranslatorCreateScrollEvent` 0x6F24-0x7248): integer lines = `trunc(d)` but at least ±1, fixed = `d · 65536` rounded away from zero, points = `ceil(|d| · 10)` with sign. That matches what CoreGraphics does for line events (10 points per line, §5.2), so the filter output is in lines. This mapping comes from reading disassembly; which of the two event arguments is the accelerated one is my reading, **not verified on hardware**. A negative scroll index does **not** switch acceleration off on a live device: `setupScrollAcceleration` returns at `_scrollAcceleration < 0` (`:957-959`) before the loop that deletes and rebuilds the per-axis accelerators (`:972-998`), so the accelerators built with the previous index keep running (same order in the installed binary: the `fcmp d0, #0.0; b.mi` at 0x7FDC precedes the destructor call at 0x80C0). The pointer side deletes its accelerator first (`:789-794`), so −1 works there. Index 0 does not linearise scroll either when the table algorithm is active, because the table path divides by `|scroll|`, not by the time-dependent `vel`. What does work: `HIDSupportsScrollAcceleration = false` (checked per event, `:567-569`) or a linear parametric curve.

### 1.8 ScrollCount

`kCGScrollWheelEventScrollCount` (field 100) is computed in the closed translator, `___IOHIDPointerEventTranslatorProcessScrollCount` (symbol and the string `SCROLLCOUNT: Unknown phase 0x%x` in the installed `IOHIDNXEventTranslatorSessionFilter` plugin). Its parameters are the kernel `IOHIDSystem` properties with boot defaults `AccelerationFactor 163840` (2.5), `IgnoreMomentumScrolls true`, `Max 2000`, `MaxTimeDeltaBetween 600`, `MaxTimeDeltaToSustain 250`, `MinDeltaToStart 30`, `MinDeltaToSustain 20`, `MouseCanReset true` (`IOHIDFamily/Info-IOHIDFamily.plist:120-137`, copied to properties in `IOHIDSystem/IOHIDSystem.cpp:3986-4046`). The counting logic itself is **unverified**.

### 1.9 Other inputs

- A device can push its own settings: a vendor-defined event (AppleVendor page, `kHIDUsage_AppleVendor_Properties`) carrying `{"IOHIDSetAcceleration": {…}}` is applied with `IOHIDServiceSetProperty` and dropped unless `DropAccelPropertyEvents` is false (`…PointerScrollFilter.cpp:391-394, 471-520`). Only relevant for drivers.
- `ServiceFilterDebug`: reading this property on a service returns the filter's live state, including the built segments (`{m, b, x}`) of the active table or the parametric parameters (`:338-352, 1129-1178`). This is the cheapest way to verify on a real mouse what curve is active.

---

## 2. Setting properties from a normal app

### 2.1 The path, traced in the macOS 27 binaries

1. `IOHIDServiceClientSetProperty(service, key, value)` → client-side `__IOHIDEventSystemClientSetPropertyForService` (`IOKit@0x184E20978` tail-calls it). It serialises `{key: value}` and sends MIG `io_hideventsystem_set_properties_for_service`. The only client-side check: for restricted `UserKeyMapping` remaps it calls `IOHIDCheckAccess(1)` / `IOHIDRequestAccess(1)` (1 = `kIOHIDRequestTypeListenEvent`, Input Monitoring; `IOKit@0x184DC6854-0x184DC6884`, enum in SDK `IOKit.framework/Headers/hidsystem/IOHIDLib.h:162-165`).
2. Server (in `hidd`): `__io_hideventsystem_set_properties_for_service` (`IOKit@0x184DF7634`) looks up the connection and the service, then for each key (`…_block_invoke`, `IOKit@0x184DF7820`):
   - if the connection type is 4 (**Simple**) and the key is not in `__whiteList`, the key fails with `0xE00002C2` (`kIOReturnBadArgument`);
   - otherwise `_IOHIDEventSystemConnectionSetProperty` gets the key first (it only handles `ClientEventFilter`, `ClientSuspend`, `IdleNotificationTime`);
   - then `_IOHIDServiceSetPropertyForClient(service, key, value, connection)`.
3. `_IOHIDServiceSetPropertyForClient` (`IOKit@0x184DCC26C`) calls `IOHIDServiceCheckEntitlements` (`IOKit@0x184DCC9FC`): if the service has `ProtectedAccess = true` the connection needs entitlement bit 0x11 (`com.apple.private.hid.client.admin` or `…service-protected`); if the service has `HIDServiceAccessEntitlement`, that entitlement is required; otherwise it passes. `ProtectedAccess` is only set for Apple-vendor devices with AppleVendor usages 0x4B/0x4D or a few Apple personalities (`IOHIDFamily/IOHIDDevice.cpp:1705-1770`, `Info-IOHIDFamily.plist:170-182`), not for third-party mice.
4. Each service filter may rewrite or veto the value (`IOHIDServiceFilterFilterSetPropertyForClient`), then gets `setPropertyForClient` (IOHIDPointerScrollFilter ignores the client argument: `…PointerScrollFilter.cpp:384`, it only logs it at `:412`).
5. The value then goes to the service plugin. For kernel services, `-[IOHIDEventServicePlugin setProperty:forKey:client:]` is just `IOConnectSetCFProperty` (**binary**, `/System/Library/HIDPlugins/ServicePlugins/IOHIDEventServicePlugin.plugin`, 0x117C-0x11A0) → `IOHIDEventServiceUserClient::setProperties` → owner `setProperties` (`IOHIDFamily/IOHIDEventServiceUserClient.cpp:624-627`) → `IOHIDEventDriver::setProperties` → `super` (`IOHIDEventDriver.cpp:1736`) → `IOHIDEventService::setSystemProperties`, which **merges the dictionary into the registry property `HIDEventServiceProperties`** (`IOHIDEventService.cpp:582-603, 627-636`). The DriverKit path ends in the same place ("Publish remaining properties under HIDEventServiceProperties", `AppleUserHIDEventService.cpp:806-810`), except `HIDPointerAccelerationType` and `HIDScrollAccelerationType`, which become top-level properties (`:766-780`).
6. Reading back: `-[IOHIDEventServicePlugin propertyForKey:client:]` first looks in `HIDEventServiceProperties`, then reads the top-level property (without parent search for the eight table/type keys), then searches parents (**binary**, 0xF94-0x1178). So a client-set `HIDPointerAccelerationTable`, `HIDPointerResolution` or `HIDAccelCurves` **is** what `IOHIDServiceCopyProperty` returns to the filter. Mac Mouse Fix observed the same from the outside (`PointerSpeed.m:408`: "the props also end up inside HIDEventServiceProperties"; `Helper/Core/Config/PointerConfig.swift:394`: setting `HIDAccelCurves` on a mouse "the driver will use them", secondary).

### 2.2 Client types and what an unentitled app gets

| Creator | Type (value) | Needs | Service keys it may set |
|---|---|---|---|
| `IOHIDEventSystemClientCreateSimpleClient` (public) | Simple (4) | nothing | only the 30-key whitelist below |
| `IOHIDEventSystemClientCreate` (private) | Rate Controlled (3) | nothing | any key, subject to step 3 |
| `IOHIDEventSystemClientCreateWithType(…, 1/2/3, …)` (private) | Monitor / Passive / Rate Controlled | nothing to connect | any key, subject to step 3 |
| same with type 0 | Administrative | `com.apple.private.hid.client.admin`, else connection creation fails | any |

Evidence: type values from `_IOHIDEventSystemClientCreate` (`mov w1, #0x3`, `IOKit@0x184D7F0A8`) and `…CreateSimpleClient` (`mov w1, #0x4`, `IOKit@0x184E1B980`); names from `_IOHIDEventSystemConnectionGetTypeString` (array at `0x1E06CF720`: Administrative, Monitor, Passive, Rate Controlled, Simple); admin check in `__IOHIDEventSystemConnectionCreate` (`IOKit@0x184DF4150-0x184DF4174`).

The **Simple whitelist** (`__whiteList`, 30 CFStrings at `0x1E06CF748`, resolved from the shared cache): `VendorID, ProductID, LocationID, PrimaryUsagePage, PrimaryUsage, IORegistryEntryID, Transport, IOClass, Product, IOUserClass, Built-In, ServiceRecords, ClientRecords, SessionFilterDebug, HIDPointerAcceleration, HIDPointerAccelerationType, HIDMouseScrollAcceleration, HIDMouseAcceleration, HIDScrollAcceleration, HIDScrollAccelerationType, HIDPointerButtonMode, UserKeyMapping, CapsLockDelayOverride, EjectDelay, HIDInitialKeyRepeat, HIDKeyRepeat, HIDIdleTimeMicroseconds, HIDCapsLockState, KeyboardLanguage, CASecureLayerOnScreen`.

So with **public API only**, an app can set per device: the acceleration index (`HIDMouseAcceleration`), the scroll index (`HIDMouseScrollAcceleration`; −1 does not switch scroll acceleration off on a live device, §1.7), the pointer index −1 (acceleration off, raw counts), and the type keys. It cannot set `HIDUseLinearScalingMouseAcceleration`, `UserPointerAccelCurvesKey`, `HIDPointerAccelerationTable`, `HIDPointerAccelerationAlgorithm`, `HIDPointerResolution` or the multiplier. Those need the private client. Who uses the private client without HID entitlements:

- Apple's own System Settings Mouse pane: `MouseExtension` has only `com.apple.bluetooth.system`, `app-sandbox = false`, one mach-lookup exception and an SBPL for prefs and `iokit-set-properties` (`codesign -d --entitlements -`), and imports `IOHIDEventSystemClientCreateWithType`, `IOHIDServiceClientCopyProperty`, `IOHIDSetAccelerationWithKey`, `IOHIDSetParameter` (`dyld_info -imports`).
- The deprecated public `IOHIDSetParameter` / `IOHIDSetCFTypeParameter` themselves create a Passive client (`mov w1, #0x2` before `IOHIDEventSystemClientCreateWithType`, `IOKit@0x184D98E90`) and set the key system-wide when the handle is `IOHIDSystem` (`IOHIDSetHIDParameterToEventSystem`, `IOKit@0x184D98E54`). System-wide is the wrong scope for us (it reaches every pointer service; the filter reads `UserPointerAccelCurvesKey` regardless of type).
- LinearMouse: `IOHIDEventSystemClientCreate` (`Modules/PointerKit/Sources/PointerKit/PointerDeviceManager.swift:113`) and per-device `HIDPointerResolution` (clamped 10…1995), `HIDMouseAcceleration`, `HIDUseLinearScalingMouseAcceleration` (`PointerDevice.swift:406-468`) (secondary).
- Mac Mouse Fix: `IOHIDEventSystemClientCreateWithType(…, Passive, …)` and per-device `HIDPointerAccelerationTable` / `HIDAccelCurves` (`PointerSpeed.m:320-324, 395`) (secondary).
- `hidutil` is not a fair comparison: it carries `com.apple.private.hid.client.service-protected` (`codesign -d --entitlements - /usr/bin/hidutil`).

Mac Mouse Fix reports that setting user curves "doesn't do anything" (`PointerConfig.swift:397`, secondary). The key string on macOS 27 is `UserPointerAccelCurvesKey` (**binary**); whether MMF used that string is **unverified**.

### 2.3 Recipe for an exact per-device table (not yet run on hardware)

For each external mouse service (conforms to GD/Mouse, `Built-In` false, transport USB/Bluetooth/BLE), with a private client:

1. Read and keep the originals: `HIDPointerAccelerationType`, the index under that key, `HIDPointerAccelerationAlgorithm`, `HIDPointerAccelerationTable` (absent means "built-in default table", whose bytes are at `…PointerScrollFilter.cpp:63-78`), `HIDPointerResolution`.
2. Set `HIDPointerAccelerationTable` = single-curve table (index `a0`, knots from §1.4).
3. Optional, to decouple from the System Settings slider: set `HIDPointerAccelerationType` to a private key name (for example `NewmouseAcceleration`) and that key to `a0`. The filter reads the index from whatever key the type names (`…PointerScrollFilter.cpp:833-839`); a non-`HIDMouseAcceleration` type also makes the system "Pointer acceleration" switch ignore this device (`:868`). Values must be the right CF types: Mac Mouse Fix notes that a number in `HIDAccelCurves` crashed WindowServer on 12.4 (`PointerSpeed.m:325-326`, secondary).
4. Set `HIDPointerAccelerationAlgorithm = 0` last. It is a cached key, so this triggers `setupAcceleration()`.
5. Verify with `ServiceFilterDebug` (§1.9).

---

## 3. Lifetime and restore

| Event | Our per-service keys | System values |
|---|---|---|
| Our app quits or crashes | stay (kernel `HIDEventServiceProperties` + filter state in `hidd`) | untouched |
| `hidd` restarts | stay: the new filter finds nothing in its cache and falls back to `IOHIDServiceCopyProperty`, which reads `HIDEventServiceProperties` (`…PointerScrollFilter.cpp:1034-1052`) | reloaded from the kernel `IOHIDSystem` `HIDParameters` (`hidd/hidd.mm:53-68, 99`) |
| Logout / other user logs in | stay if the device stays connected (**inferred** from the above) | the new user's values are applied (by whom: **unverified**) |
| Unplug / Bluetooth reconnect | gone: new service object | system-wide values are pushed to the new service |
| Sleep / wake | USB: likely stay; Bluetooth: usually a reconnect (**unverified**) | – |
| Reboot | gone | from preferences |
| User moves a System Settings slider | our table/curves stay; the per-device index is overwritten by the system-wide one unless decoupled (§2.3 step 3) | changed |

Who writes the system values: the Mouse pane (`MouseExtension`) calls `IOHIDSetAccelerationWithKey` / `IOHIDSetParameter`, which does both `IOHIDEventSystemClientSetProperty` (live, all services) and `IOConnectSetCFProperty` on `IOHIDSystem` (kernel `HIDParameters`, reloaded by a restarted `hidd`) (`IOKit@0x184D98E54-0x184D99030`; imports of `MouseExtension`). It also imports `CFPreferencesSetValue` and has an SBPL exception to write `kCFPreferencesAnyApplication`, which is where `com.apple.mouse.scaling`, `com.apple.mouse.linear` and `com.apple.scrollwheel.scaling` live (**inferred**). `MachineSettings.framework` holds these pref keys next to `IOServiceOpen(IOHIDSystem)` and `IOHIDSetParameter` (strings in the shared cache, `InputDeviceUtilities.m`); which process applies them at login I could not pin down (**unverified**).

Restore procedure: keys cannot be removed from `HIDEventServiceProperties`, only overwritten. Write back the saved originals (or the default table bytes), `HIDPointerAccelerationAlgorithm = 2`, the original type, `UserPointerAccelCurvesKey = []` (an empty array falls through, `…PointerScrollFilter.cpp:649`), `HIDUseLinearScalingMouseAcceleration` back to the system value, then re-set the index to trigger a rebuild. Do this on quit, on logout (`NSWorkspace.sessionDidResignActiveNotification` / will-power-off), and unconditionally at launch to clean up after a crash. Re-apply on device arrival and on wake. Because nothing is persisted to disk, a crash can never outlive a replug or reboot.

---

## 4. Probes on this Mac (read-only)

`defaults read -g` (sandboxed shell):

```
com.apple.mouse.scaling = 0.875
com.apple.mouse.linear = 0
com.apple.scrollwheel.scaling = 0.5
com.apple.swipescrolldirection = 1
com.apple.trackpad.scaling = 1.5
com.apple.trackpad.scrolling = 0.4412
com.apple.mouse.doubleClickThreshold = 0.5
```

So on this machine, with a mouse connected, the mouse index would be 0.875 (table index 0.875 → about 57344 fixed), linear mode off, wheel index 0.5, natural scrolling on.

`hidutil list`: inside the tool sandbox it returns only the IORegistry "Devices" part (the event-system connection is blocked); run outside the sandbox it lists services. Relevant rows (filtered, SMC sensor services omitted, columns trimmed):

```
Services:
VendorID ProductID LocationID UsagePage Usage RegistryID  Transport Class                  Product                            Built-In
0x0      0x0       0xa7       13        12    0x100001014 FIFO      AppleMultitouchDevice  Apple Internal Keyboard / Trackpad 1
0x0      0x0       0xa7       1         6     0x100000fda FIFO      AppleHIDKeyboardEventDriverV2 Apple Internal Keyboard / Trackpad 1
0x5ac    0x0       0x0        65280     23    0x100000a3f (null)    IOHIDSystem            (null)                             0
Devices:
0x0      0x0       0xa7       1         2     0x10000100e FIFO      AppleHIDTransportHIDDevice Apple Internal Keyboard / Trackpad 1
```

No external mouse was connected. Note that the built-in trackpad also exposes a GD/Mouse (1/2) HID device, so "conforms to GD/Mouse" alone is not enough to exclude it; filter on `Built-In`.

Not obtained: `hidutil property --get …`. The in-sandbox run returns nothing and the unsandboxed run was blocked by the permission classifier, so I have no property values. To collect them, run in the prompt:

```
! hidutil property --get HIDMouseAcceleration
! hidutil property --get HIDUseLinearScalingMouseAcceleration
! hidutil property --matching '{"PrimaryUsagePage":13,"PrimaryUsage":12}' --get HIDPointerAccelerationType
! hidutil property --matching '{"PrimaryUsagePage":13,"PrimaryUsage":12}' --get ServiceFilterDebug
```

With a mouse connected, the same with `--matching '{"PrimaryUsagePage":1,"PrimaryUsage":2}'` for `HIDPointerResolution`, `HIDScrollResolution`, `HIDPointerAccelerationType`, `HIDEventServiceProperties` (via `ioreg -r -c IOHIDEventService -l`) and `ServiceFilterDebug` shows the live curve.

Side note: `~/Library/Preferences` contains `com.lujjjh.LinearMouse.plist` and `com.nuebling.mac-mouse-fix.plist`. If either app runs, it writes the same per-device keys; WinMouse should detect that and warn.

---

## 5. Scroll events in CoreGraphics and AppKit

### 5.1 Fields (SDK 27, `CoreGraphics.framework/Headers/CGEventTypes.h`)

| Field | No. | Meaning |
|---|---|---|
| `kCGScrollWheelEventDeltaAxis1/2` | 11/12 | integer lines (axis 1 vertical) (`:188-197`) |
| `kCGScrollWheelEventFixedPtDeltaAxis1/2` | 93/94 | 16.16 lines or line-equivalent (`:202-217`) |
| `kCGScrollWheelEventPointDeltaAxis1/2` | 96/97 | integer points (`:222-231`) |
| `kCGScrollWheelEventInstantMouser` | 14 | ignore for Inkwell (`:244-247`) |
| `kCGScrollWheelEventIsContinuous` | 88 | 1 = pixel-based, 0 = line-based (`:370-374`) |
| `kCGScrollWheelEventScrollPhase` | 99 | Began 1, Changed 2, Ended 4, Cancelled 8, MayBegin 128 (`:59-66, 237`) |
| `kCGScrollWheelEventScrollCount` | 100 | see §1.8 (`:240`) |
| `kCGScrollWheelEventMomentumPhase` | 123 | None 0, Begin 1, Continue 2, End 3 (`:51-57, 242`) |
| `kCGScrollWheelEventMomentumOptionPhase` | 173 | new, undocumented (`:384-385`) |
| `kCGScrollWheelEventAcceleratedDeltaAxis1/2` | 176/175 | new: accelerated deltas (`:387-389`) |
| `kCGScrollWheelEventRawDeltaAxis1/2` | 178/177 | new: raw (pre-acceleration) deltas (`:390-391`) |
| `kCGEventUnacceleratedPointerMovementX/Y` | 170/171 | new: unaccelerated pointer movement (`:380-382`) |
| field 87 (undocumented) | 87 | registry ID of the sending HID service; 0 for synthetic events. Mac Mouse Fix uses it as "senderID" to find the device (`mac-mouse-fix/Shared/Constants.h:309`, `Helper/Utility/EventUtility.m:109-141`, secondary). The translator does read `IOHIDEventGetSenderID` (**binary**, `_IOHIDPointerEventTranslatorCreateEventCollection`). |
| field 137 (undocumented) | 137 | drives `NSEvent.isDirectionInvertedFromDevice` (**probe**) |
| `kCGEventSourceUnixProcessID` | 41 | PID of the poster for synthetic events (**probe**: our own PID) |

The Apple documentation pages for fields 170-178 exist with no abstract and no availability version, so when they appeared is **unverified**. On synthetic events they are 0 (**probe**); whether hardware wheel events fill 177/178 needs a test with a mouse.

### 5.2 What `CGEventCreateScrollWheelEvent2` writes (**probe** `scrollprobe.swift`, `scrollprobe2.swift`; events created, never posted)

| Call | Delta | FixedPt | PointDelta | IsContinuous |
|---|---|---|---|---|
| `.line`, n = 1, 2, 3, 5, 10, −1, −7 | n | n.0 | 10·n | 0 |
| `.pixel`, p = 1, 3, 9 | 1 | p/10 (0.0999…, 0.2999…, 0.8999…) | p | 1 |
| `.pixel`, p = 10, 11, 25, −4 | 1, 1, 2, −1 | 1.0, 1.0999…, 2.5, −0.3999… | p | 1 |

Line delta for pixel events is `p/10` rounded away from zero with a minimum of 1. Writing fields afterwards:

- Setting the **integer** `DeltaAxis1` recomputes `FixedPt = n` and `PointDelta = 8·n` (1 → 8, 3 → 24, −5 → −40). Write order therefore matters: Delta first, then FixedPt, then PointDelta (writing in that order yields 3 / 3.0 / 30).
- Setting `FixedPtDeltaAxis1` or `PointDeltaAxis1` has no side effects.
- `PointDeltaAxis1` is integer: `setDoubleValueField(…, 12.75)` stores 12.

### 5.3 AppKit mapping (**probe**, `NSEvent(cgEvent:)`)

- Line event (`IsContinuous = 0`): `hasPreciseScrollingDeltas = false`; `scrollingDeltaY = deltaY = FixedPtDeltaAxis1` (overwriting FixedPt to −5.5 gives −5.5 in both; overwriting PointDelta changes nothing).
- Pixel event (`IsContinuous = 1`): `hasPreciseScrollingDeltas = true`; `scrollingDeltaY = PointDeltaAxis1` (points), `deltaY = FixedPtDeltaAxis1`. Flipping `IsContinuous` to 1 on a line event is enough to make AppKit read PointDelta.
- `ScrollPhase = 2` (Changed) shows up as `NSEvent.phase = 4` (`NSEventPhaseChanged`).
- Field 137 = 1 makes `isDirectionInvertedFromDevice` true; brute force over fields 0-255 found no other field that does.

Apple's contract: for non-precise deltas, apps multiply `scrollingDeltaY` by their line height; for precise deltas they scroll by the value ([scrollingDeltaY]). With natural scrolling on, deltaX/deltaY/scrollingDelta are already inverted and `isDirectionInvertedFromDevice` says so ([isDirectionInvertedFromDevice]). Synthetic events carry 137 = 0; whether WindowServer inverts posted events is **unverified** (inversion appears to happen when HID events are converted, so posted events likely pass as-is).

### 5.4 Telling a mouse wheel from a trackpad or Magic Mouse

- `IsContinuous = 0` and no phases → a classic line wheel. Trackpads and Magic Mouse send `IsContinuous = 1` with `ScrollPhase` / `MomentumPhase`. Not reliable alone: free-spin or high-resolution wheels, and vendor drivers that post smooth pixel events, also produce continuous events (**unverified**).
- Reliable: field 87 → registry ID → `IOHIDServiceClient` (or `IORegistryEntryIDMatching`) → check `Built-In`, `Transport`, VendorID/ProductID. This is what Mac Mouse Fix does (secondary, see §5.1). Events posted by us have field 87 = 0 and field 41 = our PID, which is how the tap should skip its own output.

---

## 6. Event taps

- **Locations** (Apple docs): `kCGHIDEventTap` "where HID system events enter the window server", `kCGSessionEventTap` "where HID system and remote control events enter a login session", `kCGAnnotatedSessionEventTap` "where session events have been annotated to flow to an application" ([CGEventTapLocation]).
- **Already accelerated:** yes, at every location. Acceleration happens in `hidd` before WindowServer (§1.1 step 3). Unaccelerated values are exposed separately in fields 170/171 (pointer) and 177/178 (scroll) (§5.1).
- **Changing motion in a tap:** editing `kCGMouseEventDeltaX/Y` changes what apps read, not where the cursor is. Prior art that tried to steer the cursor from a tap ended up warping it with `CGWarpMouseCursorPosition` and fighting the event-suppression interval (stutter, 0.05-0.07 s minimum; `mac-mouse-fix/Helper/Utility/PointerFreeze.m:115-120, 190-200, 286-310`), and notes that dropping mouse-moved events makes the cursor jump in screen recordings (`Helper/Core/Drag/ModifiedDrag.m:282-289`) (secondary). Conclusion: do the pointer curve in the HID filter, not in a tap. Whether rewriting the location at `kCGHIDEventTap` moves the cursor cleanly is **unverified**.
- **Root-only claim:** Apple's `CGEventTapCreate` docs and the SDK header still say HID-level taps need root ([tapCreate], SDK `CGEvent.h:269-270`). In practice LinearMouse creates an active `.cghidEventTap` as a normal user after `AXIsProcessTrustedWithOptions` (`LinearMouse/EventTap/EventTap.swift:85-92`, `LinearMouse/AccessibilityPermission.swift:12-19`), as does Mac Mouse Fix (`Helper/Core/Scroll/Scroll.m:84`) (secondary). Session-level taps avoid the question.
- **TCC:** two services exist, `kTCCServiceListenEvent` (Input Monitoring) and `kTCCServicePostEvent` (`hidd/hidd-Entitlements.plist:39-43`; `CGPreflight/RequestListenEventAccess` and `…PostEventAccess` since 10.15, SDK `CGEvent.h:398-408`). Apple DTS: a listen-only CGEventTap requires Input Monitoring, while an NSEvent global monitor requires Accessibility (developer.apple.com/forums/thread/707680, seen only as a search excerpt: (secondary)). Active (modifying) taps and `CGEventPost` are gated by the Accessibility list (PostEvent) (secondary: both prior-art apps request Accessibility for their active taps; I did not test it). Setting HID properties (§2) needs no TCC grant (nothing in the traced path checks one, except the `UserKeyMapping` remap case).
- **Disabling:** a tap gets `kCGEventTapDisabledByTimeout` (0xFFFFFFFE) when its callback is too slow, and `kCGEventTapDisabledByUserInput` (0xFFFFFFFF) when the user or system disables it (SDK `CGEventTypes.h:130-131`, `CGEvent.h:320-327`). The timeout is commonly given as about 1 s (secondary). Recovery used in practice: on the timeout event call `CGEventTapEnable(tap, true)`, pass the event through, and poll `CGEventTapIsEnabled` every few seconds because taps can also be disabled silently (LinearMouse `EventTap.swift:36-46, 108-123`, secondary). Keep the callback allocation-free and never block in it.
- **macOS 15/26/27 changes:** the SDK 27 header has the new fields 170, 171, 173 and 175-178. I found no documented change to tap creation or TCC for 15/26/27 in sources I could open (**unverified**; Apple's forums were behind a bot check).

---

## 7. Recommendation

**Pointer.** Per external mouse, set an Apple-format table plus `HIDPointerAccelerationAlgorithm = 0` through a private `IOHIDEventSystemClient` (Rate Controlled or Passive), following §2.3. Confidence that it works: **medium-high** (every link read in source or binary, the storage behaviour confirmed by two other apps; not yet run with a mouse). Confidence that the curve shape is exact: **high**. Remaining differences from Windows: speed metric (diagonals, up to 11.8 %), per-axis remainder, points vs DIPs on scaled displays. Fallback if tables misbehave on some driver: `UserPointerAccelCurvesKey` parametric fit (**medium**, approximate).

**Scroll.** Two layers:

1. Always, no permission: per external mouse, flatten macOS wheel acceleration with the private client: `HIDSupportsScrollAcceleration = false` (1.0 line per detent), or a linear `UserScrollAccelCurvesKey` (`G1 = N / 1.0667`) with `HIDScrollAccelerationAlgorithm = 1` for exactly N lines per detent. Not `HIDMouseScrollAcceleration = −1` (§1.7). Confidence: **medium** (math from source; the line/point mapping from disassembly, not measured).
2. For Windows-browser feel and per-device direction (opt-in, needs Accessibility): a session-level active tap on `kCGEventScrollWheel` only, filtered to external-mouse senders (field 87), that swallows line events and posts pixel events (`IsContinuous = 1`, integer `PointDelta`, phases as needed), flipping sign and clearing 137 when natural scrolling is on. Cost is limited to wheel events. Confidence: **medium** (fields and AppKit mapping measured on created events; hardware events not observed).

**Risks.** Private SPI and private key strings can change with any macOS update; keep a kill switch that restores defaults and a version check. Malformed values can crash `hidd` or WindowServer: validate CF types before every set. Our values outlive a crash of our app until replug or reboot, and follow the device across logouts; restore at launch, quit and logout. Another mouse app (LinearMouse, Mac Mouse Fix, both installed here) can overwrite the same keys. Not usable in the Mac App Store.

---

## Sources

Source trees (shallow clones in the session scratchpad):

- apple-oss-distributions/IOHIDFamily, tag `IOHIDFamily-2238.120.5`, commit `e31e90a24c27ad6cbe981650d12a1a4124065b03` (2026-06-05). Newest by version sort of `git ls-remote --tags`. Later-than-2008 tags spot-checked via raw.githubusercontent.com: 2008.80.3.0.1, 2031.100.16, 2102.0.6, 2104.80.4, 2115.100.21, 2115.140.4, 2222.0.24 (1778.100.19 and 1856.100.12 return 404 for these paths).
- apple-oss-distributions/IOKitUser, tag `IOKitUser-100231.120.3`, commit `23a611d9d194b63465f6df2abfdda63d71c87e97`. `hid.subproj/IOHIDService.c`, `IOHIDEventSystemConnection.c`, `IOHIDServiceClient.c` and 34 other HID files are 0 bytes in this and every older tag checked.
- linearmouse/linearmouse `fc7d920a8f76` (2026-09-25); noah-nuebling/mac-mouse-fix `cf708c59f499` (2026-09-26).

Binaries on this Mac (macOS 27.0 26A428):

- `/System/Library/HIDPlugins/IOHIDPointerScrollFilter.plugin` (SourceVersion 2360001002000000): `strings`, `nm`, `otool -tV`, `dyld_info -fixups`.
- `/System/Library/HIDPlugins/ServicePlugins/IOHIDEventServicePlugin.plugin`, `/System/Library/HIDPlugins/IOHIDNXEventTranslatorSessionFilter.plugin`: `dyld_info -disassemble`, `-objc`.
- IOKit and MachineSettings from `/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e*`: `dyld_info -disassemble/-exports/-section`, CFString arrays resolved with a small read-only cache reader (`dsc.py`).
- `/usr/bin/hidutil`, `/usr/libexec/hidd`, `/System/Library/ExtensionKit/Extensions/MouseExtension.appex`: `codesign -d --entitlements -`, `dyld_info -imports`, `strings`.
- SDK: `Xcode.app/…/MacOSX.sdk` 27.0, `CoreGraphics.framework/Headers/CGEventTypes.h`, `CGEvent.h`, `IOKit.framework/Headers/hidsystem/IOHIDEventSystemClient.h`, `IOHIDServiceClient.h`, `IOHIDLib.h`, `IOKit.framework/Headers/hid/IOHIDProperties.h`.

Probes (session scratchpad `mac-hid/`): `scrollprobe.swift`, `scrollprobe2.swift` (create CGEvents, read fields, convert to NSEvent; nothing posted), `accel_sim.py` (table decoder and re-implementation with a self-check), `dsc.py`.

Apple documentation (JSON endpoints under developer.apple.com/tutorials/data/documentation/…):

- [CGEventTapLocation]: https://developer.apple.com/documentation/coregraphics/cgeventtaplocation/cghideventtap
- [tapCreate]: https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:)
- https://developer.apple.com/documentation/coregraphics/cgeventtype/tapdisabledbytimeout, …/tapdisabledbyuserinput
- https://developer.apple.com/documentation/coregraphics/cgrequestposteventaccess(), …/cgpreflightlisteneventaccess() (macOS 10.15+)
- https://developer.apple.com/documentation/coregraphics/cgeventfield/eventunacceleratedpointermovementx, …/scrollwheeleventrawdeltaaxis1
- [isDirectionInvertedFromDevice]: https://developer.apple.com/documentation/appkit/nsevent/isdirectioninvertedfromdevice
- [scrollingDeltaY]: https://developer.apple.com/documentation/appkit/nsevent/scrollingdeltay ; https://developer.apple.com/documentation/appkit/nsevent/hasprecisescrollingdeltas
- Apple Support, "Control access to input monitoring on Mac" (macOS 27 edition): https://support.apple.com/guide/mac-help/control-access-to-input-monitoring-on-mac-mchl4cedafb6/mac

Secondary:

- Apple Developer Forums thread 707680 (Quinn on Input Monitoring vs Accessibility), seen only as a DuckDuckGo excerpt: https://developer.apple.com/forums/thread/707680
- Tap timeout "typically 1 second": https://deepwiki.com/pqrs-org/osx-event-observer-examples/2.2-cgeventtap-example (search excerpt)
- LinearMouse discussion on the Sonoma pointer-acceleration switch: https://github.com/linearmouse/linearmouse/discussions/493
