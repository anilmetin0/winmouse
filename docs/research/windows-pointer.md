# Windows pointer ballistics: Enhance Pointer Precision and the pointer speed slider

Research note, 2026-09-26. Scope: how Windows turns mouse counts into pointer pixels (Enhance Pointer Precision on and off, pointer speed slider). Scrolling is out of scope. Primary target is Windows 10/11; Windows 7, 8.x, XP and Vista differences are listed where they differ.

How to read the evidence:

- `file:line` refers to repositories cloned on 2026-09-26 at the commits listed under [Sources](#sources).
- "MarkC" means Mark Cranness's reverse engineering (blog, registry fixes, Fix Builder script). I read his material first-hand, but I did not check his claims against Windows binaries. Treat his claims as strong secondary evidence.
- "INRIA data" is the libpointing EchoMouse capture of real Windows output (see [§4.3](#43-comparison-with-measured-windows-output)). I fitted the model against it myself.
- **derived** marks my own arithmetic from the cited numbers. **(secondary)** marks third-party claims. **unverified** means no source was found or nothing was checked.

---

## Summary

Windows runs this once per mouse report (per USB poll that carries motion). `(dx, dy)` are raw counts ("mickeys").

```
m  = max(|dx|,|dy|) + min(|dx|,|dy|) / 2        // speed in counts PER PACKET (no time involved)
x  = m / 3.5                                    // SmoothMouseXCurve units
k  = (DPI / 120) * (MouseSensitivity / 10)      // Windows 8, 8.1, 10 (11: unverified, assumed same)
     (DPI / 150) * (MouseSensitivity / 10)      // Windows 7
     (max(60,Hz) / max(96,DPI)) * (Sens / 10)   // XP, Vista (Hz = monitor refresh rate)
f  = k * Y(x)                                   // pixels per packet; Y = piecewise-linear SmoothMouseYCurve
g  = f / m                                      // one gain, applied to both axes
   // if this packet's curve segment > previous packet's segment: g = (g + g_prevSegmentLine(m)) / 2
out_x = trunc(dx*g + rem_x);  rem_x = dx*g + rem_x - out_x   // same for y; truncation toward zero
```

`DPI = 96 × display scale` (100 % → 96, 125 % → 120, 150 % → 144), clamped to at least 96. At 100 % on Windows 10, `k = 0.8` at slider 10.

With the default Windows 10 curve at 100 % and slider 10, the transfer function in counts per packet → pixels per packet is the polyline through **(0, 0), (1.505, 0.856), (4.375, 3.3125), (13.51, 15.1875), (140, 355.0)**, extended linearly past 140. The gain is 0.57 up to 1.5 counts/packet, about 1.0 at 8, 2.0 at 32 and 2.54 at 140. It approaches 2.69 at higher counts.

**EPP off:** `out = counts × slider factor` (1/32 … 3.5, with 1.0 at the default 10), with the same remainder handling. Since Windows 10 1709 the result is also multiplied by the per-monitor display scale.

**Polling rate:** Windows does not normalise by time. The same hand speed produces 8× larger packets at 125 Hz than at 1000 Hz, so a 1000 Hz mouse gets much less acceleration ([§4](#4-test-vectors)).

---

## 1. The EPP algorithm step by step

### 1.1 Pipeline (Windows 7 and later)

1. Take one relative report `(dx, dy)` from the device.
2. Compute the speed `m = max(|dx|,|dy|) + min(|dx|,|dy|)/2` in counts per packet ([§1.2](#12-speed-the-max--min2-magnitude)).
3. Pick the curve segment for `x = m/3.5` ([§1.5](#15-interpolation-and-segment-choice)).
4. Compute `g = slope_i + intercept_i / m` on the table in counts → pixels. If the segment index went up since the last packet, average with the previous segment's line ([§1.6](#16-cross-packet-state-segment-transition-averaging)).
5. For each axis: `v = d·g + remainder`, output `trunc(v)`, and store `v − trunc(v)` ([§1.7](#17-sub-pixel-remainder)).
6. Move the pointer by the integer result.

Evidence: the Microsoft XP paper lists the same stages: table rebuilt when settings change, input converted to 16.16, magnitude looked up in the table, value interpolated, remainder added and stored ("Summary of the Ballistic Algorithm for Windows XP", steps 1–6). MarkC's Windows 7 reconstruction as code: `capitalfuse/SmoothMouse:SmoothMouseDaemon/libpointing/WindowsFunction.cpp:135-241`.

### 1.2 Speed: the "max + min/2" magnitude

- Microsoft: "The number used to look up the mouse X and Y translated values is the vector magnitude of incoming X and Y magnitudes … is then applied to translate the X and Y data" (XP paper, "Calculating Acceleration"). One gain comes from the vector and is applied to both axes. Before XP, each axis was accelerated separately.
- The exact formula comes from MarkC's reconstruction: `mouseMag = max(abs(mouseRawX), abs(mouseRawY)) + min(abs(mouseRawX), abs(mouseRawY)) / 2.0` (`WindowsFunction.cpp:178-179`).
- MarkC's threshold ReadMe gives the rule as "(Very approximately) If X_Movement + Y_Movement/2 >= threshold+1 then use higher speed-factor" (`!Threshold_Acceleration_ReadMe.txt:117-118`, inside the Fix Builder zip). Its example table has (6,4) → ×2, (7,2) → ×2, (7,1) → ×1 and (6,3) → ×1 for a threshold of 7. That matches max+min/2 (8, 8, 7.5, 7.5). A Euclidean magnitude (7.21, 7.28) would not cross.
- **derived:** max+min/2 equals the Euclidean length on the axes. It is 6.1 % larger at 45° and at most 11.8 % larger, at 26.6° (dy/dx = 0.5).
- Units are counts per packet. No time or polling interval appears anywhere in the formula ([§1.8](#18-polling-rate-dependence)).

Confidence: medium-high. Two MarkC-derived sources agree, and the INRIA data are one-axis only, so they cannot test this part.

### 1.3 The registry curve: format and decoded defaults

`HKCU\Control Panel\Mouse\SmoothMouseXCurve` and `SmoothMouseYCurve` are REG_BINARY values of 40 bytes: 5 points × 8 bytes, little-endian. The value is the integer divided by 65536 (16.16 fixed point). Microsoft: "Five X and Y pairs are stored in 16.16 fixed point format" (XP paper). Microsoft also says the internal lookup table "consists of six points (the first is [0,0])" (paper, step 4), so Windows adds an implicit origin in front of the 5 registry points. The default curves start at (0,0) anyway, so this only matters for custom curves. MarkC's Fix Builder uses a non-zero first point in one of its hacks (`Builder.vbs:697-699`).

Decoded defaults. I decoded them with `int.from_bytes(le)/65536`. The bytes come from MarkC's `Windows_10+8.x_Default.reg` and `Windows_7+Vista+XP_Default.reg`, and the Windows 7 values also appear in `WindowsFunction.cpp:87-106`.

| Point | X bytes | X | Y bytes, Win 8/8.1/10/11 | Y (Win 8+) | Y bytes, XP/Vista/7 | Y (XP–7) |
|---|---|---|---|---|---|---|
| 0 | `00,00,00,00` | 0 | `00,00,00,00` | 0 | `00,00,00,00` | 0 |
| 1 | `15,6e,00,00` | 0.430008 | `fd,11,01,00` | 1.070267 | `b8,5e,01,00` | 1.369995 |
| 2 | `00,40,01,00` | 1.25 | `00,24,04,00` | 4.140625 | `cd,4c,05,00` | 5.300003 |
| 3 | `29,dc,03,00` | 3.860001 | `00,fc,12,00` | 18.984375 | `cd,4c,18,00` | 24.300003 |
| 4 | `00,00,28,00` | 40.0 | `00,c0,bb,01` | 443.75 | `00,00,38,02` | 568.0 |

(The last 4 bytes of each 8-byte point are `00,00,00,00` in all defaults.)

- Windows 11 has the same defaults as Windows 10 (secondary: sugarsweetapps.com 2024 article "Default Windows 10/11 registry values"; a Windows 11 tutorial on php.cn in a Brave search excerpt). A fresh Windows 10 dump posted on Reddit in 2017 also shows `MouseSensitivity=10, MouseSpeed=1, MouseThreshold1=6, MouseThreshold2=10` (secondary).
- **derived:** Y(Win 8+) = 0.78125 × Y(Win 7), exactly 25/32 up to 16.16 rounding. Together with the constant change from DPI/150 to DPI/120 ([§1.4](#14-units-and-scaling-constants)), Windows 8+ at 100 % gives `k·Y = 0.625·Y7`. That is exactly XP/Vista at 60 Hz and 96 DPI (60/96 = 0.625), and 2.3 % slower than Windows 7 at 100 % (0.64). So Microsoft appears to have restored the XP-at-60-Hz feel in Windows 8.

### 1.4 Units and scaling constants

**X axis: `x = counts per packet / 3.5`.**
- MarkC Fix Builder: `SmoothXMickeys = BMult(SmoothX + ExtraX, B(3.5))` (`Builder.vbs:874`, also `:858`).
- libpointing/SmoothMouse: `SmoothMouseGain(mouseMag / 3.5, …)` (`WindowsFunction.cpp:184`).
- MarkC, XP/Vista formula: "Pointer = Mouse / 3.5 * MonitorRefreshRate / DPI * SmoothMouseY / SmoothMouseX" (fix page comment, 1 Feb 2012).
- My fit: I fitted the INRIA Windows 7 capture (400 CPI, 125 Hz, notch 6, n = 1…127) with a free X divisor and a free output scale. A divisor of 3.5 gives 0.016 % mean error. 3.4 and 3.6 give 0.40 %. 3.2, which the XP paper's 125 Hz / 400 dpi numbers would imply, gives 1.24 % with a 8.9 % worst case.

**Y axis: pixels per packet = `Y × k`.**

| Windows | k | Evidence |
|---|---|---|
| 8, 8.1, 10 | `max(96, DPI)/120 × Sens/10` | `Builder.vbs:629-631` (`DPIFactor = B(Max(96,DPI)/120)`), `:651` (`SmoothYPixels = BMult(BMult(SmoothY, DPIFactor), B(MouseSensitivity/10))`) |
| 11 | assumed as Windows 10 | unverified: no source describes Windows 11 internals; same registry defaults (secondary) |
| 7 | `max(96, DPI)/150 × Sens/10` | `Builder.vbs:632-634`; MarkC, 19 Aug 2011: "Windows 7 has a scaling factor that includes: Desktop DPI / 150"; the INRIA fit matches 96/150 to 0.02 % |
| XP, Vista | `max(60, refresh Hz)/max(96, DPI) × Sens/10` | `Builder.vbs:636`; MarkC part zero: XP/Vista "include a factor '* RefreshRate'" and "a divisor '/ DPI'" |

Cross-check (**derived**): MarkC's shipped "exactly 1-to-1 @ 6/11" fixes, which users checked with MouseMovementRecorder, give g = 1.000 under these constants:

| Fix file | X per step | Y per step | g = k·(Y/X)/3.5 |
|---|---|---|---|
| `Windows_10+8.x_MouseFix_ItemsSize=100%` | 12.8 | 56 | 0.8 × 4.375 / 3.5 = 1 |
| `…ItemsSize=125%` | 16 | 56 | 1.0 × 3.5 / 3.5 = 1 |
| `…ItemsSize=150%` | 19.2 | 56 | 1.2 × 2.917 / 3.5 = 1 |
| `Windows_7_MouseFix_TextSize(DPI)=100%` | 10.24 | 56 | 0.64 × 5.469 / 3.5 = 1 |
| `XP+Vista_MouseFix_@60Hz_DPI=96` | 10 | 56 | 0.625 × 5.6 / 3.5 = 1 |

**What the XP paper intended versus what Windows ships.** The paper defines mouse speed as counts × 125 Hz ÷ 400 counts/inch, and pointer speed as pixels × refresh Hz ÷ screen DPI. The equations are images in the archive; I reconstructed them from the paper's worked examples: 3 counts/packet → 0.9375 in/s, and 3 px at 75 Hz on an 80 dpi screen → 2.8 in/s. The shipping code divides by 3.5 instead of 3.2. XP and Vista also multiply by refresh/DPI where the paper's units need DPI/refresh, which is MarkC's "upside down" DPI finding (part zero). The "inches per second" labels on the curve are therefore nominal only. Treat X as counts/3.5 and Y as pixels/k. The origin of 3.5 is unexplained.

### 1.5 Interpolation and segment choice

Windows interpolates the **output speed** linearly, not the gain. For segment `i` in counts/pixels space:

```
slope     = (Yp[i+1] - Yp[i]) / (Xm[i+1] - Xm[i])      // Xm = 3.5·X, Yp = k·Y
intercept = Yp[i] - slope * Xm[i]
gain      = slope + intercept / m                       // so pixels/packet = slope·m + intercept
```

Sources: `WindowsFunction.cpp:119-121`. The Fix Builder computes the same slope and intercept in 16.16 (`Builder.vbs:873-876`). Segment choice: `x < X1` → 0, `X1 ≤ x < X2` → 1, `X2 ≤ x < X3` → 2, otherwise 3. Past X4 the last segment is extended (`WindowsFunction.cpp:109-114`). The XP paper says velocities beyond the last inflection "are linearly extrapolated".

Windows 10, 100 %, slider 10, in counts/packet → pixels/packet (**derived**):

| Segment | Counts/packet | Slope (px/count) | Intercept (px) |
|---|---|---|---|
| 0 | 0 – 1.505 | 0.56890 | 0 |
| 1 | 1.505 – 4.375 | 0.85586 | −0.43188 |
| 2 | 4.375 – 13.51 | 1.29994 | −2.37476 |
| 3 | ≥ 13.51 | 2.68648 | −21.10681 |

For other settings, multiply slope and intercept by `Sens/10 × (DPI/96)`. The segment boundaries stay put.

Steady state (same segment on consecutive packets):

| Counts/packet | 1 | 2 | 3 | 4 | 5 | 6 | 8 | 10 | 12 | 14 | 16 | 20 | 24 | 32 | 48 | 64 | 100 | 140 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| px/packet | 0.569 | 1.280 | 2.136 | 2.992 | 4.125 | 5.425 | 8.025 | 10.625 | 13.225 | 16.504 | 21.877 | 32.623 | 43.369 | 64.860 | 107.844 | 150.828 | 247.541 | 355.000 |
| gain | 0.569 | 0.640 | 0.712 | 0.748 | 0.825 | 0.904 | 1.003 | 1.063 | 1.102 | 1.179 | 1.367 | 1.631 | 1.807 | 2.027 | 2.247 | 2.357 | 2.475 | 2.536 |

### 1.6 Cross-packet state: segment-transition averaging

Windows keeps only two pieces of state between packets: the per-axis remainder and the previous packet's segment index.

- Code: `if (currentSegmentIndex > previousSegmentIndex) { … pixelGain = (pixelGain + pixelGainUsingPreviousSegment) / 2.0; }` (`WindowsFunction.cpp:187-196`). The previous segment's line is evaluated at the current speed.
- MarkC describes the effect: mouse counts "+5 +6 +7 +8 +9 +10" become "+5 +6 +7 +12 +18 +20" with a threshold curve. "The speed-factor used is an average of the previous zone (×1) and the current zone (×2), or ×1.5" (`!Threshold_Acceleration_ReadMe.txt:164-167`).
- The averaging applies only when speeding up into a higher segment. Slowing down switches segments immediately.
- There is no other smoothing and no averaging of velocity over time in either source. The INRIA steady-state data match a memoryless curve to 0.02 %. The "Smooth" in `SmoothMouse*Curve` refers to the continuous curve, as opposed to the pre-XP step thresholds (MarkC threshold ReadMe, "Unlike Windows 10/8.x/7/Vista/XP acceleration (which is continuously, smoothly variable)").
- What resets the stored segment is **unverified**: idle time, a zero-motion report, or nothing. libpointing sets it to 0 on a zero-speed packet (`WindowsFunction.cpp:100-103`).

Confidence: medium. Two consistent MarkC-derived sources, but not measurable in the INRIA data, which used constant counts per packet.

### 1.7 Sub-pixel remainder

- **Windows 7:** "adds in the previous remainder, then truncates the fractional result towards zero, and stores the new remainder" (MarkC part zero). Code: `WindowsFunction.cpp:205-212`, a floor on |v| with the sign restored. Remainders are never cleared, not even on a direction change. MarkC's fix ReadMe notes that a leftover remainder causes a "1 mouse count error when the mouse changes direction left/right or up/down" (`!MarkC_Windows_10+8.x+7_MouseFix_ReadMe.txt:245`, see also `!Threshold_Acceleration_ReadMe.txt:185`).
- **Windows 8, 8.1, 10, 11:** assumed to behave like Windows 7 (MarkC's exact 1:1 fixes for 8.x/10 depend on this). Not directly verified.
- **XP and Vista:** truncation toward −∞. XP resets an axis's remainder when that axis changes sign or reads 0; Vista resets it on a sign change and ignores zeros. The result is a slow up-left drift (MarkC part zero; reply of 15 Feb 2013: `if (Sign(mouseRawX) != Sign(previousMouseRawX) || mouseRawX == 0) previousMouseXRemainder = 0`; code `WindowsFunction.cpp:139-160, 219-221`).
- **EPP off:** the slider multiplier uses the same carry-a-remainder, truncate-toward-zero scheme, "at least since Windows 98" (MarkC part zero).
- Internally all of this is 16.16 fixed point (XP paper).

### 1.8 Polling-rate dependence

**Verdict: Windows EPP works on counts per packet. It is not time-normalised, so it depends strongly on the polling rate.**

- MarkC (19 Aug 2011): "2000 mouse counts in 1 second @ 125Hz is 2000/125 = 16 per poll, and the accel curve for speed 16 is applied. 2000 mouse counts in 1 second @ 1000Hz is 2 per poll … which is a lot less accel than at 16. (Windows is not smart enough to adjust for mouse polling rate.)"
- The XP paper says the table uses "default values of the mouse refresh rate (USB 125 Hz), and default mouse resolution (400 dpi). (This may change in the future to actually reflect the pointer parameters.)"
- The 2018 Fix Builder ReadMe still tells users to rescale thresholds by `new_mouse_update_rate / old_mouse_update_rate` (`!Threshold_Acceleration_ReadMe.txt:57-80`).
- I found no source claiming that Windows 10 or 11 changed this. For Windows 11 this is **unverified**.

Consequence: the curve was tuned for about 125 Hz. At 1000 Hz, normal desktop movement stays in segments 0–2, with gains of 0.57–1.1 ([§4](#4-test-vectors)).

Windows 8.1 "delays and coalesces (merges) mouse input for programs, causing the effective mouse polling rate to be as low as 62 Hz in some cases" (MarkC ReadMe, KB2908279). This is about messages delivered to applications. Whether coalescing ever happens before the ballistics step is **unverified**.

### 1.9 Display scaling and per-monitor DPI

- **EPP on, Windows 8.x/10:** `k` is proportional to DPI: 100 % → 0.8, 125 % → 1.0, 150 % → 1.2, 200 % → 1.6 (at slider 10). On 8.1 and 10 the Fix Builder reads DPI from `HKCU\Control Panel\Desktop\WindowMetrics\AppliedDPI`, the system DPI (`Builder.vbs:87-94`). **Unverified:** which DPI Windows uses when monitors have different scale factors. MarkC only advises finding "the percentage needed so that your main (gaming) monitor looks the same" (fix ReadMe, 8.1 section).
- **EPP off, Windows 10 1709+ (build 16299) and presumably Windows 11:** "Mouse pointer movements when Enhance pointer precision is OFF, are now scaled according to the per-monitor scaling of items setting" (fix ReadMe:186, Builder ReadMe:181). The Fix Builder sets the EPP-off gain to `scale × slider factor` from that build on (`Builder.vbs:95, 376-377, 386`). Before 1709, and on 7/8.x, EPP off ignores scaling. Supporting reports: a Ten Forums thread from January 2018, right after the 1709 update ("increased x3 only on that display" at 300 %), and a Microsoft Q&A question about Windows 11 at 150 % (both secondary).
- **Windows 7:** DPI/150. **XP/Vista:** refresh/DPI, which is inverted: a higher DPI gives a *slower* pointer.
- **derived:** on Windows 10 1709+, both paths scale linearly with the display scale. Measured in logical pixels (DIPs), pointer motion is therefore independent of the scale setting: EPP off at slider 10 is 1 count → 1 DIP, and EPP on is `0.8 · Y(m/3.5)` DIPs per packet. This maps directly to macOS points ([§6](#6-implications-for-the-macos-app)).

### 1.10 Fixed-point quirks

Windows computes in 16.16 (XP paper; the Fix Builder mirrors it with truncating `B`, `BMult` and `BDiv`, `Builder.vbs:838-851`). I rebuilt the Windows 10 table in 16.16 with those helpers and compared it with double precision. The largest gain difference over 1–399 counts/packet is 0.0042 %, which is not perceptible. **Use Double.** The only fixed-point behaviour that affects feel is the remainder carry and truncation in [§1.7](#17-sub-pixel-remainder), which the model keeps. One overflow note from the paper: "While an overflow is possible, it is very unlikely." That is irrelevant at realistic counts.

---

## 2. Pointer speed slider

| Control Panel notch | MouseSensitivity | Factor, EPP off | Factor, EPP on (scales Y, the output) |
|---|---|---|---|
| 1 | 1 | 1/32 = 0.03125 | 0.1 |
| 2 | 2 | 1/16 = 0.0625 | 0.2 |
| – | 3 | 0.125 | 0.3 |
| 3 | 4 | 0.25 | 0.4 |
| – | 5 | 0.375 | 0.5 |
| 4 | 6 | 0.5 | 0.6 |
| – | 7 | 0.625 | 0.7 |
| 5 | 8 | 0.75 | 0.8 |
| – | 9 | 0.875 | 0.9 |
| **6 (default)** | **10** | **1.0** | **1.0** |
| – | 11 | 1.25 | 1.1 |
| 7 | 12 | 1.5 | 1.2 |
| – | 13 | 1.75 | 1.3 |
| 8 | 14 | 2.0 | 1.4 |
| – | 15 | 2.25 | 1.5 |
| 9 | 16 | 2.5 | 1.6 |
| – | 17 | 2.75 | 1.7 |
| 10 | 18 | 3.0 | 1.8 |
| – | 19 | 3.25 | 1.9 |
| 11 | 20 | 3.5 | 2.0 |

Formulas and evidence:

- **EPP off:** `s ≤ 2: s/32; s ≤ 10: (s−2)/8; else (s−6)/4` (`Builder.vbs:260-267`). SmoothMouse uses the same notch table `{0.03125, 0.0625, 0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5}` (`WindowsFunction.cpp:248`). The INRIA EPP-off capture confirms it: 127 counts → 3.97 px at notch 1, 31.75 at notch 3, 444.5 at notch 11 (`pointing-echomouse/windows/no-epp/f1.dat, f3.dat, f11.dat`).
- **EPP on:** `s/10`, multiplied into the Y (pixel) side, so the curve's knees stay at the same counts per packet. Sources: `Builder.vbs:651`; `WindowsFunction.cpp:183`; MarkC's table (fix page comments of 29 Nov 2012 and 22 Dec 2013: "EPP on sens factor is additional to the varying curve sens"). My fit of the INRIA EPP capture across all 11 notches (1,397 points) gives 0.042 % mean error. The only outliers are at 1 count/packet on the two slowest notches (measured 0.05 px against 0.058 predicted, cause unknown).
- **Notch ↔ MouseSensitivity:** `n ≤ 2 → n`, otherwise `2n − 2` (`Builder.vbs:233, 260`). `SPI_GETMOUSESPEED`/`SPI_SETMOUSESPEED` accept 1 (slowest) to 20 (fastest), "A value of 10 is the default" (Microsoft docs). The Windows 10/11 Settings slider writes 1–20 directly (secondary).

**MouseSpeed, MouseThreshold1, MouseThreshold2:**

- These are the three integers read and written by `SPI_GETMOUSE`/`SPI_SETMOUSE` ("the two mouse threshold values and the mouse acceleration", Microsoft docs). The `MOUSEINPUT` docs still describe the pre-XP algorithm: if the distance on either axis is greater than threshold 1 and speed ≠ 0, the distance is doubled; if it is greater than threshold 2 and speed = 2, it is doubled again, before the slider scaling.
- Since XP: `MouseSpeed = 0` means EPP off and `MouseSpeed ≥ 1` means EPP on. **The thresholds are ignored.** MarkC, 7 Aug 2014: "In Windows XP+, the MouseThreshold1 & 2 settings ARE IGNORED … (Any value higher than 1 will still count as ON)". MarkC, Nov 2012: "Control Panel sets the two thresholds to 6,10 when EPP is on, and to 0,0 when EPP is off. BUT those thresholds are IGNORED by Windows". The INRIA EPP data agree: with thresholds 6/10 in the registry there is no doubling between 6 and 7 counts (5.56 → 6.88 px).
- Defaults are `MouseSpeed 1, Threshold1 6, Threshold2 10, MouseSensitivity 10`. ReactOS uses the same defaults (`sysparams.c:244-247`); a Windows 10 registry dump shows them too (secondary).
- For our purposes: EPP on ⇔ `MouseSpeed ≥ 1`. Never use the thresholds.

---

## 3. Pseudo-code for a faithful reimplementation

Swift-flavoured pseudo-code. Output is in "Windows pixels at 100 % scale". See [§6](#6-implications-for-the-macos-app) for how that maps to macOS points.

```swift
// SmoothMouseXCurve / SmoothMouseYCurve defaults, decoded 16.16 (Windows 8/8.1/10/11)
let curveX: [Double] = [0, 0.430008, 1.25, 3.860001, 40.0]
let curveY: [Double] = [0, 1.070267, 4.140625, 18.984375, 443.75]

func eppOffFactor(_ s: Int) -> Double {            // MouseSensitivity 1...20
    s <= 2 ? Double(s) / 32 : s <= 10 ? Double(s - 2) / 8 : Double(s - 6) / 4
}

struct WindowsBallistics {
    var epp = true
    var sensitivity = 10                           // MouseSensitivity
    var scale = 1.0                                // Windows display scale; keep 1.0 when emitting macOS points
    private(set) var prevSeg = 0
    private(set) var rem = (x: 0.0, y: 0.0)

    // Table in counts/packet -> pixels/packet. Rebuild when settings change (Windows does the same).
    var tx: [Double] { curveX.map { $0 * 3.5 } }
    var ty: [Double] {
        let k = max(96, 96 * scale) / 120 * Double(sensitivity) / 10      // Win 8+; Win 7: /150
        return curveY.map { $0 * k }
    }

    private func segmentGain(_ i: Int, _ m: Double) -> Double {
        let slope = (ty[i + 1] - ty[i]) / (tx[i + 1] - tx[i])
        return slope + (ty[i] - slope * tx[i]) / m
    }

    mutating func eppGain(dx: Int, dy: Int) -> Double {
        let ax = Double(abs(dx)), ay = Double(abs(dy))
        let m = max(ax, ay) + min(ax, ay) / 2       // NOT sqrt(dx²+dy²)
        guard m > 0 else { prevSeg = 0; return 0 }  // reset rule: libpointing's guess (unverified)
        var i = 0
        while i < 3 && m >= tx[i + 1] { i += 1 }    // last segment extrapolates
        var g = segmentGain(i, m)
        if i > prevSeg { g = (g + segmentGain(prevSeg, m)) / 2 }   // speeding up across a knee
        prevSeg = i
        return g
    }

    /// Call once per HID report, with that report's raw counts.
    mutating func move(dx: Int, dy: Int) -> (dx: Int, dy: Int) {
        let g = epp ? eppGain(dx: dx, dy: dy)
                    : eppOffFactor(sensitivity) * scale          // `* scale` only on Win10 1709+
        let vx = Double(dx) * g + rem.x, vy = Double(dy) * g + rem.y
        let ox = vx.rounded(.towardZero), oy = vy.rounded(.towardZero)
        rem = (vx - ox, vy - oy)                    // never reset (Win7+), not even on direction change
        return (Int(ox), Int(oy))
    }
}
```

Notes:

- Apply it **per report**. Merging reports before this step changes `m` and the result.
- For Windows 7, use the XP/Vista/7 curve and `/150`. For XP/Vista, use `max(60, Hz)/max(96, DPI)`, round toward −∞, and apply the remainder resets from [§1.7](#17-sub-pixel-remainder).
- Doubles instead of 16.16 change the gain by at most 0.0042 %.
- A runnable reference with self-checks is in the [appendix](#appendix-reference-model-python). The test vectors below come from it.

---

## 4. Test vectors

Assumptions: constant horizontal motion for 20 s. The mouse reports integer counts per poll and carries the fraction internally; polls with 0 counts send no report. Windows 10 constants, 100 % scale, slider 10, EPP on, default curve, remainder carried. Cells show pointer px/s and, in brackets, the effective px per count. `counts/packet = DPI × speed / Hz`.

### 4.1 EPP on, Windows 10/11 (primary target)

| Mouse | 0.5 in/s | 1 in/s | 2 in/s | 5 in/s | 10 in/s | 20 in/s | 40 in/s |
|---|---|---|---|---|---|---|---|
| 400 DPI @ 125 Hz | 121 (×0.60) | 288 (×0.72) | 743 (×0.93) | 2,734 (×1.37) | 8,106 (×2.03) | 18,851 (×2.36) | 40,339 (×2.52) |
| 400 DPI @ 1000 Hz | 114 (×0.57) | 228 (×0.57) | 455 (×0.57) | 1,280 (×0.64) | 2,992 (×0.75) | 8,025 (×1.00) | 21,876 (×1.37) |
| 800 DPI @ 125 Hz | 288 (×0.72) | 743 (×0.93) | 1,783 (×1.11) | 8,106 (×2.03) | 18,851 (×2.36) | 40,339 (×2.52) | 83,316 (×2.60) |
| 800 DPI @ 1000 Hz | 228 (×0.57) | 455 (×0.57) | 967 (×0.60) | 2,992 (×0.75) | 8,025 (×1.00) | 21,876 (×1.37) | 64,859 (×2.03) |
| 1600 DPI @ 125 Hz | 743 (×0.93) | 1,783 (×1.11) | 5,958 (×1.86) | 18,851 (×2.36) | 40,339 (×2.52) | 83,316 (×2.60) | 169,270 (×2.64) |
| 1600 DPI @ 1000 Hz | 455 (×0.57) | 967 (×0.60) | 2,307 (×0.72) | 8,025 (×1.00) | 21,876 (×1.37) | 64,859 (×2.03) | 150,825 (×2.36) |

Because the curve only sees counts per packet, the cells repeat along the diagonals: 400 DPI @ 125 Hz at 1 in/s equals 800 DPI @ 125 Hz at 0.5 in/s. The 1000 Hz rows equal the 125 Hz rows at one-eighth of the counts per packet. The 1600 DPI @ 125 Hz, 40 in/s case is 512 counts/packet and needs 16-bit HID reports.

### 4.2 EPP off (any Windows version, slider 10, 100 %): exactly DPI × speed

| Mouse (any polling rate) | 0.5 | 1 | 2 | 5 | 10 | 20 | 40 in/s |
|---|---|---|---|---|---|---|---|
| 400 DPI | 200 | 400 | 800 | 2,000 | 4,000 | 8,000 | 16,000 |
| 800 DPI | 400 | 800 | 1,600 | 4,000 | 8,000 | 16,000 | 32,000 |
| 1600 DPI | 800 | 1,600 | 3,200 | 8,000 | 16,000 | 32,000 | 64,000 |

On Windows 10 1709+ with a display scale above 100 %, multiply by the scale to get physical pixels.

### 4.3 Comparison with measured Windows output

INRIA's libpointing ships EchoMouse captures of real Windows pointer output: `pointing-echomouse/windows/epp/f1…f11.dat`, labelled "system: Windows_7_8_10", input "hz=125&cpi=400", output 1440×900 at 60 Hz, one file per slider notch, px/packet for n = 1…127 counts (`config.dict:1-9`). The data match the **Windows 7** constants (96/150 with the XP–7 curve). They do not match the Windows 8+ constants, which come out 2.3 % lower. So the capture was most likely made on Windows 7.

Per-packet output, notch 6:

| Counts/packet | 1 | 2 | 4 | 8 | 14 | 20 | 50 | 80 | 127 |
|---|---|---|---|---|---|---|---|---|---|
| Measured (INRIA) | 0.58 | 1.31 | 3.07 | 8.22 | 16.90 | 33.41 | 115.93 | 198.46 | 327.76 |
| Model, Windows 7 constants | 0.583 | 1.311 | 3.063 | 8.217 | 16.900 | 33.406 | 115.934 | 198.463 | 327.758 |
| Model, Windows 10 constants | 0.569 | 1.280 | 2.992 | 8.025 | 16.504 | 32.623 | 113.217 | 193.811 | 320.076 |

px/s for 400 DPI @ 125 Hz, computed by summing the measured per-count outputs over the same packet sequence, against the Windows 7 model:

| Speed | 0.5 in/s | 1 | 2 | 5 | 10 | 20 |
|---|---|---|---|---|---|---|
| From INRIA data | 127.2 | 294.8 | 761.0 | 2,800.0 | 8,302.5 | 19,305.0 |
| Windows 7 model | 123.8 | 295.3 | 760.9 | 2,799.9 | 8,300.9 | 19,303.0 |

The 0.5 in/s difference comes from the segment averaging in [§1.6](#16-cross-packet-state-segment-transition-averaging): packets alternate between 1 and 2 counts across the first knee. The constant-count EchoMouse protocol cannot show that effect; the model without averaging gives 127.4.

Raw Accel documents an "Enhanced Pointer Precision" lookup table (`doc/Guide.md:177`): `1.505035,0.85549892; 4.375,3.30972978; 13.51,15.17478447; 140,354.7026875`. The x values are 3.5 × X. The y values equal the Windows 10 table above × 0.99916, a constant 0.084 % gap whose source is unknown and which does not matter. How Raw Accel obtained these numbers is not stated (secondary).

---

## 5. How other implementations do it

| Project | What it does | Faithfulness | Evidence |
|---|---|---|---|
| Microsoft "Pointer Ballistics for Windows XP" (2002) | Design paper: physical units, vector magnitude, 5-point 16.16 curve, interpolation, remainder carry, 125 Hz / 400 dpi assumption. Equations are images; no code. | Describes intent. The shipped constants differ (3.5, inverted XP DPI ratio). | Wayback copy (see Sources) |
| MarkC fixes and Fix Builder 2.6 (2010–2018) | Reverse-engineered formulas for XP/Vista, 7, 8.x and 10, encoded as registry curves that give exact 1:1. VBS script mirrors the Windows 16.16 math. | The best available description; fixes widely validated with MouseMovementRecorder. | `Builder.vbs:629-651, 838-887`; blog |
| libpointing `WindowsFunction` (INRIA), vendored by SmoothMouse | C++ Windows 7 model: max+min/2, /3.5, DPI/150 (fixed at 96 DPI, 60 Hz), segment averaging, XP/Vista/7 remainder rules, EPP-off notch table. SmoothMouse (macOS, 2012–2016) called it once per kext mouse event and used Windows pixels directly as CG points (`mouse.mm:178-197`; slider = `velocity*4 − 6`). | Windows 7 constants and curve, not Windows 10. libpointing now replays measured tables instead (`TransferFunction.cpp:212-236`). | `capitalfuse/SmoothMouse:SmoothMouseDaemon/libpointing/WindowsFunction.cpp`. The official SmoothMouse GitHub org only hosts helper repos (Mouse-Movement-Recorder, Uninstaller, …). |
| Raw Accel (Windows driver) | "Look Up Table" style with the EPP velocity points above. | Time-normalised: input is counts/**ms**, so it matches Windows EPP only at 1000 Hz. It uses the Euclidean magnitude (`Guide.md:36-38, 57-60`) and has no segment averaging. | `a1xd/rawaccel:doc/Guide.md:177` |
| YeetMouse (Linux) | Converts Raw Accel's EPP velocity LUT to a sensitivity LUT (f(x)/x) via a script; ready-made config in issue #67. | Same limits as Raw Accel, plus resampling. | `README.org:231-234`; issue comment 2025-12-06 |
| leetmouse (Linux) | Sample config: "Emulate Windows' Enhanced Pointer Precision for my mouse (1000 Hz) by approximating it with a linear accel" (sens 0.85, accel 0.26, cap 4.0, post-scale 0.4). | Rough approximation. | `driver/config.sample.h:14-20` |
| maccel (Linux) | Aims to reproduce Raw Accel's linear/natural/synchronous curves; no EPP mode. | n/a | `site/src/WHY.md:6-15, 45-48` |
| libinput custom profile | User-defined f(x) with "x axis … the device speed in device units per millisecond". | Time-normalised like Raw Accel, so a per-packet Windows curve can only be approximated for one polling rate. No maintained EPP port found (GitHub repo search, 2026-09-26). | libinput docs, "The custom acceleration profile" |
| ReactOS | **No ballistics.** `UserSendMouseInput` adds dx/dy to the cursor (`mouse.c:185-190`). It only stores the settings with Windows defaults (`sysparams.c:244-247`). | n/a | `reactos/reactos` master |

Licensing note: libpointing is LGPL/GPL, and MarkC's script is copyrighted with no license. Reimplement from this description; do not copy code.

---

## 6. Implications for the macOS app

- **Units (derived):** on Windows 10 1709+, EPP on and EPP off both scale linearly with the display scale, so the motion is scale-independent in DIPs. Emit Windows-100 % pixels as **macOS points** (`scale = 1.0` in [§3](#3-pseudo-code-for-a-faithful-reimplementation)). SmoothMouse did the same. Physical cursor travel still depends on each display's points per inch, just as on Windows.
- **Per-report processing:** the curve's input is counts per HID report. The Mac side must run the function on each raw report at the mouse's real polling rate (mac-hid's area). If reports get merged, or deltas get time-normalised, a 1000 Hz mouse will behave like a 125 Hz one, with about 2× more acceleration at normal speeds.
- **Integer output with remainder:** Windows moves whole pixels and carries the fraction. Emitting fractional points on Retina would be smoother but not identical; that is a product decision.
- **Constants to ship:** the Windows 10/11 curve (Y8), `k = 0.8 × Sens/10` (in points), max+min/2, /3.5, segment averaging, truncation toward zero.

---

## 7. Confidence per item and open questions

| Item | Confidence | Basis |
|---|---|---|
| Registry format and default curves (7, 8+, 10) | High | Several sources plus my own decoding |
| Windows 11 default curve equals Windows 10 | Medium | Secondary only |
| X divisor 3.5 | High | MarkC code and fixes, plus best fit to measured data |
| Windows 7 `DPI/150` | High | MarkC plus INRIA fit (0.02 %) |
| Windows 8/8.1/10 `DPI/120` | Medium-high | MarkC builder plus the fix files; no independent measurement found; agrees with Raw Accel's LUT to 0.08 % |
| Windows 11 same algorithm as Windows 10 | Low (unverified) | No source either way |
| Magnitude = max + min/2 | Medium-high | libpointing code plus MarkC's worked threshold table |
| Output interpolation (slope + intercept/m) | High | Code, builder, fits the measurements |
| Segment-transition averaging | Medium | Two MarkC-derived sources; not measurable in the data |
| Remainder: truncate toward zero, never reset (7+) | Medium-high for 7; medium for 8/10/11 | MarkC recordings plus code |
| Polling-rate dependence (per packet) | High for XP–10; unverified for 11 | MarkC, XP paper, builder ReadMe |
| EPP-on slider `Sens/10` | High | Builder plus INRIA fit across 11 notches |
| EPP-off slider table | High | Builder, SmoothMouse, INRIA no-EPP data |
| Thresholds ignored since XP; MouseSpeed ≥ 1 means EPP on | High | MarkC plus INRIA data |
| EPP-off × per-monitor scale since Win10 1709 | Medium | MarkC ReadMe/builder, forum reports (secondary) |
| Which DPI EPP-on uses on mixed-DPI setups (8.1+) | Unknown | — |

Open questions, roughly in priority order:

1. **Windows 11 check.** Record HID counts against pointer pixels on a real Windows 11 machine, for example with MarkC's MouseMovementRecorder and a HID replay device, at 125 and 1000 Hz, 100 % and 150 %, EPP on and off. Compare with [§4.1](#41-epp-on-windows-1011-primary-target). This one measurement would move most "medium" rows to "high".
2. Which DPI EPP-on uses when monitors have different scale factors: system `AppliedDPI` or the monitor under the cursor.
3. What resets the previous-segment state: idle time, zero reports, or nothing.
4. Whether any Windows 8.1+/11 input coalescing (including the Windows 11 raw-input rate limits for background apps) ever merges reports before ballistics (probably not; unverified).
5. A 2024 Microsoft Q&A report describes a sharp isolated packet (`0,0,0,40,0,0,0`) followed later by a reverse movement of roughly the same size, only with EPP on. Unexplained and unverified; nothing in the known algorithm produces it.
6. Where Raw Accel's 0.084 % lower LUT values come from, and why the INRIA notch-1/notch-2 values at 1 count/packet run low. Both are negligible.
7. Where the 3.5 constant comes from. It is not the paper's 125/400 = 1/3.2.

---

## Appendix: reference model (Python)

This model produced every number in [§4](#4-test-vectors) and in the Windows 10 tables. `demo()` is the self-check: EPP off is 1:1, the slider table, the INRIA 14-count point, the Raw Accel 140-count point, the averaging damping, and max+min/2.

```python
import math
from fractions import Fraction

def fx(b): return int.from_bytes(bytes(b), 'little') / 65536.0      # registry 16.16

CURVE_X  = [0.0, fx([0x15,0x6e,0,0]), fx([0,0x40,1,0]), fx([0x29,0xdc,3,0]), fx([0,0,0x28,0])]
CURVE_Y8 = [0.0, fx([0xfd,0x11,1,0]), fx([0,0x24,4,0]), fx([0,0xfc,0x12,0]), fx([0,0xc0,0xbb,1])]  # Win 8/8.1/10
CURVE_Y7 = [0.0, fx([0xb8,0x5e,1,0]), fx([0xcd,0x4c,5,0]), fx([0xcd,0x4c,0x18,0]), fx([0,0,0x38,2])] # XP/Vista/7

def slider_factor_epp_off(s):
    return s / 32 if s <= 2 else (s - 2) / 8 if s <= 10 else (s - 6) / 4

class Windows:
    def __init__(self, epp=True, sens=10, scale=1.0, os='win10'):
        dpi = max(96, round(96 * scale))
        k, cy = (dpi / 150, CURVE_Y7) if os == 'win7' else (dpi / 120, CURVE_Y8)
        self.epp = epp
        self.px = [3.5 * x for x in CURVE_X]                 # counts/packet
        self.py = [k * sens / 10 * y for y in cy]            # pixels/packet
        self.prev_seg, self.rem = 0, [0.0, 0.0]
        self.off_gain = slider_factor_epp_off(sens) * (scale if os == 'win10' else 1.0)

    def _seg_gain(self, i, m):
        slope = (self.py[i+1] - self.py[i]) / (self.px[i+1] - self.px[i])
        return slope + (self.py[i] - slope * self.px[i]) / m

    def gain(self, dx, dy):
        m = max(abs(dx), abs(dy)) + min(abs(dx), abs(dy)) / 2
        if m == 0:
            self.prev_seg = 0
            return 0.0
        i = 0
        while i < 3 and m >= self.px[i+1]:
            i += 1
        g = self._seg_gain(i, m)
        if i > self.prev_seg:
            g = (g + self._seg_gain(self.prev_seg, m)) / 2
        self.prev_seg = i
        return g

    def move(self, dx, dy):
        g = self.gain(dx, dy) if self.epp else self.off_gain
        out = []
        for a, d in enumerate((dx, dy)):
            v = d * g + self.rem[a]
            o = math.trunc(v)
            self.rem[a] = v - o
            out.append(o)
        return tuple(out)

def packets(dpi, hz, ips, seconds):
    acc, step = Fraction(0), Fraction(dpi) * Fraction(str(ips)) / hz
    for _ in range(int(hz * seconds)):
        acc += step
        n = math.floor(acc)
        acc -= n
        if n:
            yield n

def px_per_s(dpi, hz, ips, seconds=20, **kw):
    w = Windows(**kw)
    return sum(w.move(n, 0)[0] for n in packets(dpi, hz, ips, seconds)) / seconds

def demo():
    assert px_per_s(800, 1000, 3, epp=False) == 2400
    assert [slider_factor_epp_off(s) for s in (1, 2, 4, 6, 8, 10, 12, 20)] == [1/32, 1/16, .25, .5, .75, 1, 1.5, 3.5]
    w = Windows(os='win7'); w.gain(14, 0); assert abs(14 * w.gain(14, 0) - 16.90) < 0.01      # INRIA f6.dat:20
    w = Windows(); w.gain(140, 0); assert abs(140 * w.gain(140, 0) / 354.7026875 - 1) < 0.001  # Raw Accel LUT
    w = Windows(); first = w.gain(35, 0); assert first < w.gain(35, 0)                          # averaging damps 1st packet
    w = Windows(); a = w.gain(6, 4); w = Windows(); assert abs(a - w.gain(8, 0)) < 1e-12       # max + min/2
    print('demo ok')

if __name__ == '__main__':
    demo()
```

---

## Sources

Primary (Microsoft):
- Microsoft, "Pointer Ballistics for Windows XP", 31 Oct 2002. Wayback: https://web.archive.org/web/20101222190833/http://www.microsoft.com/whdc/archive/pointer-bal.mspx. Linked from Microsoft Learn, "Taking Advantage of High-Definition Mouse Movement": https://learn.microsoft.com/en-us/windows/win32/dxtecharts/taking-advantage-of-high-dpi-mouse-movement (link target https://web.archive.org/web/20110623221617/http://msdn.microsoft.com/en-us/windows/hardware/gg463319.aspx).
- MOUSEINPUT remarks (legacy threshold algorithm): https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-mouseinput
- SystemParametersInfoW (`SPI_GETMOUSE`, `SPI_SETMOUSE`, `SPI_GETMOUSESPEED`, `SPI_SETMOUSESPEED`): https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-systemparametersinfow

MarkC (Mark Cranness), reverse engineering:
- "Windows mouse pointer acceleration (Enhance pointer precision) is partially broken – Part zero" (remainders, DPI and refresh scaling; comments of 15 Feb 2013 and 26 Aug 2013): http://donewmouseaccel.blogspot.com/2010/02/windows-mouse-pointer-acceleration_28.html
- "The MarkC Windows 10 + 8.1 + 8 + 7 Mouse Acceleration Fix" and its comments (19 Aug 2011 polling rate and DPI/150; 1 Feb 2012 XP formula with 3.5): http://donewmouseaccel.blogspot.com/2010/03/markc-windows-7-mouse-acceleration-fix.html. Comment pages 2 and 3 (slider table of 29 Nov 2012 and 22 Dec 2013; thresholds ignored, 7 Aug 2014): same URL with `?commentPage=2&m=0` and `?commentPage=3&m=0`.
- Fix Builder page: http://donewmouseaccel.blogspot.com/2010/04/markc-mouse-acceleration-fix-builder.html
- Fix and Fix Builder 2.6 files, third-party mirror of MarkC's OneDrive ZIPs: https://github.com/GXGalaxy/input_lag at `a24982b8ad8e32561cf49ab0e353644827dcecb3`. Used: `Windows_10+8.x_Default.reg`, `Windows_7+Vista+XP_Default.reg`, `Windows 10 Fixes/*.reg`, `Windows 7 Fixes/*.reg`, `XP+Vista Fixes/*.reg`, `!MarkC_Windows_10+8.x+7_MouseFix_ReadMe.txt`, and `MarkC_Windows_10+8.x+7+Vista+XP_MouseFix_Builder_2.6x.zip`. The zip contains `MarkC_Windows_10+8.x+7+Vista+XP_MouseFix_Builder.vbs` (header: "Copyright 2010-2018 Mark Cranness"), `!Threshold_Acceleration_ReadMe.txt` and `!MarkC_MouseFix_Builder_ReadMe.txt`.

Implementations and measurements:
- INRIA libpointing: https://github.com/INRIA/libpointing at `ecb67da58145343c9fa64211d629730134fe74ae`. Files: `pointing-echomouse/windows/{epp,no-epp}/{config.dict,f1..f11.dat}` (added 2016-03-25, commit 39db5e8c) and `pointing/transferfunctions/TransferFunction.cpp:198-236`. Method paper: G. Casiez and N. Roussel, "No more bricolage!", UIST 2011.
- SmoothMouse with source (fork): https://github.com/capitalfuse/SmoothMouse at `f91a4b20221621bf03d568600c3c5e9a5c5a49b6`. Files: `SmoothMouseDaemon/libpointing/WindowsFunction.cpp`, `SmoothMouseDaemon/mouse.mm:178-197`. Project status: https://smoothmouse.com/
- Raw Accel: https://github.com/a1xd/rawaccel at `53a721345617a1e29f3a16750cbdf807040cf44e`, `doc/Guide.md:36-38, 57-60, 177`.
- YeetMouse: https://github.com/AndyFilter/YeetMouse at `78dcd0d573bedd5dd7b9e29e9162b28c9eb2fd7b`, `README.org:231-234`. EPP LUT comment: https://github.com/AndyFilter/YeetMouse/issues/67#issuecomment-3620653542
- leetmouse: https://github.com/systemofapwne/leetmouse at `eb36c3a6ac03e9696741cc9e47d9a25569176298`, `driver/config.sample.h:14-20`.
- maccel: https://github.com/Gnarus-G/maccel at `e398002eb6df8c7dcf0fe3fad66d0d05d6dcf1e2`, `site/src/WHY.md`.
- libinput pointer acceleration docs (custom profile): https://wayland.freedesktop.org/libinput/doc/latest/pointer-acceleration.html
- ReactOS, master at fetch time (HEAD `980afdfb1d3afe0877b2660da0f270030879b85e`): `win32ss/user/ntuser/mouse.c:168-190`, `win32ss/user/ntuser/sysparams.c:244-247`, https://github.com/reactos/reactos

Secondary:
- Windows 10/11 default curve bytes: https://sugarsweetapps.com/blog/how-to-customize-mouse-acceleration-in-windows-11-smoothmousexcurve-and-smoothmouseycurve/ ; Reddit r/windows "how can get the default windows 10 mouse registry?" (2017, seen via a Brave search excerpt).
- Display scaling speeding up the pointer after 1709: https://www.tenforums.com/general-support/101652-display-scaling-also-increasing-pointer-speed-can-i-disable.html ; Windows 11 at 150 %: https://learn.microsoft.com/en-us/answers/questions/3898363/windows-11-pro-dpi-scaling-affects-cursor-speed-at
- EPP reverse-jump report (unverified): https://learn.microsoft.com/en-us/answers/questions/2122292/documentation-help-understadning-enhance-pointer-p
- Pointer to the archived XP paper: https://stackoverflow.com/questions/36862013/raw-input-and-cursor-acceleration
