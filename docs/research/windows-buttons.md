# Windows mouse buttons and Ctrl + wheel, and what macOS does with them

Research note, 2026-10-31. Scope: what the extra mouse buttons, the middle and right buttons, double-click and Ctrl + wheel do on Windows, what macOS apps do with the same input, and how to reproduce the Windows behaviour from a macOS menu-bar app. Wheel scrolling is covered in [windows-scroll.md](windows-scroll.md) (middle-click autoscroll is in its §5, Shift + wheel in its §1).

How to read the evidence:

- `path:line` refers to source files I read at the commits listed under [Sources](#sources). Chromium paths are relative to `chromium/src` at `a0e963ee` (main, 2026-10-31). Firefox paths are relative to `mozilla-firefox/firefox` at `a5df22d9` (main, 2026-10-31). Line numbers come from `grep -n` on the downloaded files.
- *(secondary)* marks third-party statements I could not check against code or an Apple/Microsoft page. **unverified** means I found no primary source, or only a search-engine summary.
- Button numbers are 0-based as in `NSEvent.buttonNumber` and DOM `MouseEvent.button`: 0 left, 1 right, 2 middle, 3 back, 4 forward.

## Summary

- Windows turns the side buttons into one browser-navigation command in the OS itself: `DefWindowProc` processes `WM_XBUTTONUP` (button-up, not down) and generates `WM_APPCOMMAND` with `APPCOMMAND_BROWSER_BACKWARD` or `_FORWARD`. Apps that do not handle it get it passed up the parent chain (§1.1).
- The context menu on Windows appears on button-up (`WM_RBUTTONUP` makes `DefWindowProc` generate `WM_CONTEXTMENU`); Chromium has a setting for exactly this platform difference (§1.3). macOS opens it on press. Reproducing release-timing would mean re-posting right-button events, so §8 leaves it alone.
- Windows defaults: double-click time 500 ms, double-click rectangle 4 x 4 px. macOS: `NSEvent.doubleClickInterval` / `com.apple.mouse.doubleClickThreshold` (0.5 s on the machine I tested) (§1.4).
- Ctrl + wheel is the zoom convention on Windows. In Chromium on Windows it zooms one preset step per whole wheel tick (§2). Chromium compiles that code out on macOS, so a synthesised Ctrl + wheel will not zoom Chrome on a Mac (§2.2).
- macOS delivers side buttons as `otherMouseDown/Up` with `buttonNumber` 3 and 4. Chrome/Chromium, Firefox (since 92) and VS Code handle them natively. Safari, Finder, System Settings, App Store and Music do not; they need Cmd-[ / Cmd-] or a simulated navigation swipe (§3, §4, §6).
- Open-source utilities split two ways: SensibleSideButtons and Mac Mouse Fix post a private "navigation swipe" gesture event; LinearMouse posts a swipe only for an allowlist of apps and passes the button through everywhere else (§6).
- Recommendation: pass buttons 3/4 through for apps that handle them, post Cmd-[ / Cmd-] (or the app's own shortcut) for a short per-app list, post nothing for unknown apps. Turn Ctrl + wheel into Cmd-= / Cmd-- once per notch (§8). Both need event-tap events other than scroll wheel, which conflicts with a rule in `AGENTS.md` (§8).

## 1. Windows behaviour

### 1.1 XBUTTON1 and XBUTTON2

| Fact | Evidence |
|---|---|
| Windows supports left, middle, right plus XBUTTON1 and XBUTTON2 ("often located on the sides of the mouse"); they are "often mapped to ... forward and backward navigation in a Web browser". | [WM_XBUTTONDOWN] Remarks, [About Mouse Input] "XBUTTONs" |
| The message pair is `WM_XBUTTONDOWN` (0x020B) and `WM_XBUTTONUP` (0x020C). The high word of `wParam` is `XBUTTON1` (1) or `XBUTTON2` (2). | [WM_XBUTTONDOWN], [WM_XBUTTONUP] |
| **Button-up triggers the command.** "DefWindowProc generates the WM_APPCOMMAND message when it processes the WM_XBUTTONUP or WM_NCXBUTTONUP message". `WM_XBUTTONDOWN` has no such sentence. | [WM_APPCOMMAND] Remarks |
| `APPCOMMAND_BROWSER_BACKWARD` = 1 ("Navigate backward"), `APPCOMMAND_BROWSER_FORWARD` = 2 ("Navigate forward"). `lParam` carries `FAPPCOMMAND_MOUSE` (0x8000) when a mouse caused it. | [WM_APPCOMMAND] |
| Routing: "If a child window does not process this message and instead calls DefWindowProc, DefWindowProc will send the message to its parent window. If a top level window does not process this message ... DefWindowProc will call a shell hook with ... HSHELL_APPCOMMAND." Microsoft compares it to `WM_CONTEXTMENU`. | [WM_APPCOMMAND] Remarks, [About Mouse Input] |
| XBUTTON1 is the lower/rear "back" button on a typical mouse and XBUTTON2 is "forward" | **unverified**: the Microsoft pages only say which constant is which, not which physical button. Mozilla's bug 1615213 comment 6 reports Logitech software labelling them "Button 4" (back) and "Button 5" (forward) (secondary). |

Which apps act on it:

- Chromium (Chrome, Edge): `HWNDMessageHandler::OnAppCommand` passes the command to the delegate and returns `TRUE` when handled, with the comment "or in some cases the system will execute the default handler which can cause bugs like going forward or back two pages instead of one" (`ui/views/win/hwnd_message_handler.cc:2045-2055`). Separately, `WebContentsImpl::HandleMouseEvent` navigates on `kMouseUp` with `Button::kBack` / `kForward` for events that reach it from the renderer (`content/browser/web_contents/web_contents_impl.cc:4884-4900`).
- Firefox: handles `WM_APPCOMMAND` as a chrome event: `HandleAppCommandEvent` maps `"Back"` / `"Forward"` to `BrowserCommands.back()` / `forward()` (`browser/base/content/browser.js:1311-1319`). Mozilla's bug 1615213 reporter confirms "fourth and fifth mouse buttons trigger back and forward" in Firefox on Windows (secondary).
- Explorer and Settings: I found no Microsoft page that names the XBUTTON behaviour of Explorer or Settings. Microsoft documents Alt+Left / Alt+Right as Go back / Go forward and "Navigate to the previous folder" for Explorer [Keyboard shortcuts in Windows] (via search summary, **unverified** as an exact quote). That Explorer and Settings answer `APPCOMMAND_BROWSER_BACKWARD` follows from the `DefWindowProc` contract above plus Explorer's keyboard history, and is **unverified** by source.
- Electron documents the same event as `app-command` on Windows and Linux only; macOS has no equivalent (§3.3).

### 1.2 Middle button

- Pressing the wheel sends standard `WM_MBUTTONDOWN` / `WM_MBUTTONUP` ("Pressing and releasing the mouse wheel sends standard WM_MBUTTONUP and WM_MBUTTONDOWN messages"); a double-click sends `WM_MBUTTONDBLCLK` [About Mouse Input] "The Mouse Wheel". The system adds no action of its own.
- Autoscroll: see windows-scroll.md §5.
- Browsers: middle-click on a link opens it in a new background tab, middle-click on a tab closes it. Google's current shortcut page lists Ctrl + click for a background tab and does not mention the middle button [Chrome shortcuts]; the middle-button wording appears only in an old copy of the page and in third-party tables (secondary, **unverified** against current Google text). Firefox gives `MouseButton::eMiddle` its own click-count tracking (`dom/events/EventStateManager.cpp:1148-1151`); its behaviour for links is **unverified** here.
- macOS delivers the middle button as `otherMouseDown` with `buttonNumber` 2 (§3.1), and browsers on macOS already treat it the same way, so no mapping is needed (**unverified** per app).

### 1.3 Right button: menu on release (Windows) versus on press (macOS)

- Windows: "DefWindowProc generates the WM_CONTEXTMENU message when it processes the WM_RBUTTONUP or WM_NCRBUTTONUP message or when the user types SHIFT+F10" [WM_CONTEXTMENU]. So the menu opens on button-up.
- Chromium keeps this as a platform setting: `showContextMenuOnMouseUp`, "Typically enabled on Windows to match platform convention", default false (`third_party/blink/renderer/core/frame/settings.json5:830-834`). When set, the `contextmenu` event is generated from a `kMouseUp`, otherwise from `kMouseDown` (`third_party/blink/renderer/core/input/event_handler.cc:2338-2345`). Where Chromium sets the preference to true I did not find (**unverified**; the pref field is `context_menu_on_mouse_up`, read at `third_party/blink/renderer/core/exported/web_view_impl.cc:1908`).
- Firefox has the same split: on Windows `contextmenu` fires on mouse-up, elsewhere on mouse-down; pref `ui.context_menus.after_mouseup` (Mozilla bug 1360278, via search summary, **unverified**).
- macOS: AppKit shows the menu from the `rightMouseDown:` path. Apple's archived guide says Control-click on a view shows its menu and `menuForEvent:` customises it [How Menus Work]; GNUstep's NSView reference (a Cocoa reimplementation, secondary) says `menuForEvent:` "is used by NSView's rightMouseDown:". I found no Apple page that states "on mouse down" in those words (**unverified**).
- Consequence for WinMouse: delaying the right-button press until release would mean swallowing and re-posting right-button events for every app. Not recommended (§8).

### 1.4 Double-click: Windows and macOS defaults

| Item | Windows | macOS |
|---|---|---|
| Time | Default 500 ms: `SetDoubleClickTime(0)` "uses the default double-click time of 500 milliseconds". Range up to 5000 ms. Read with `GetDoubleClickTime`. [SetDoubleClickTime], [GetDoubleClickTime] | `NSEvent.doubleClickInterval` (seconds, class property); defaults key `com.apple.mouse.doubleClickThreshold` in the global domain, float seconds. `defaults read -g com.apple.mouse.doubleClickThreshold` returned `0.5` on this Mac, but I did not check that it is the factory default. Apple's reference page text did not load (**unverified** wording). |
| Rectangle | `SM_CXDOUBLECLK` / `SM_CYDOUBLECLK`: "The second click must occur within the rectangle ... The two clicks must also occur within a specified time" [GetSystemMetrics]. Default 4 x 4 px: registry values `DoubleClickWidth` / `DoubleClickHeight` under `HKCU\Control Panel\Mouse`, default 4 [Win2000 registry reference] (legacy page; the current docs give no default). The rectangle is centred on the first click (4 px = 2 either side, secondary). | None known: macOS click count uses its own tolerance (**unverified**). |
| Who generates it | Only windows whose class has `CS_DBLCLKS` get `WM_*BUTTONDBLCLK`; the sequence is DOWN, UP, DBLCLK, UP [About Mouse Input] | AppKit sets `clickCount` on the event |
| Unit | pixels, not scaled with DPI (secondary: Microsoft Q&A) | points |

WinMouse does not need to touch double-click: macOS already has its own interval and click count, and the two time defaults are the same (500 ms, if the 0.5 s above is the macOS factory default: **unverified**).

## 2. Ctrl + wheel zoom

### 2.1 Windows convention

- Microsoft's guidance: "Ctrl + wheel away from the user zooms in, toward the user zooms out" ([Best practices 2004], quoted in windows-scroll.md §1).
- A Win32 edit control passes wheel messages with `MK_SHIFT` or `MK_CONTROL` to `DefWindowProc` and calls the modifier cases "zoom and datazoom" ([About Mouse Input], sample under "Detecting a Mouse with a Wheel").
- Chrome: "Ctrl + Scroll your mousewheel up" makes everything bigger, "down" smaller. Chrome's Mac column lists no scroll zoom [Chrome shortcuts].
- Explorer: Ctrl + wheel changes the view / icon size. Microsoft Q&A answers say so (secondary: [MS Q&A Explorer zoom]); there is no support article, **unverified** as official behaviour.
- Office: Word, Excel and PowerPoint zoom on Ctrl + wheel; Excel has an option "Zoom on roll with IntelliMouse" (secondary: [Office Watch]; the option name is from a Microsoft Q&A answer, **unverified**).

### 2.2 Chromium: one preset step per whole wheel tick, not on macOS

- `WebContentsImpl::HandleWheelEvent` zooms when `event_action == kPageZoom` and `wheel_ticks_y` is non-zero. It accumulates `wheel_ticks_y` in `zoom_scroll_remainder_`, rounds with `std::lround`, subtracts what it used, and calls `delegate_->ContentsZoomChange(whole_remainder > 0)` if the whole part is non-zero. Comment: "Count only integer cumulative scrolls as zoom events; this handles smooth scroll and regular scroll device behavior." (`content/browser/web_contents/web_contents_impl.cc:4916-4938`). So one 120-unit notch is one zoom step; a 30-unit hi-res event adds a quarter notch and zooms every fourth event (rounding at half: `lround(0.5)` = 1, so the second event of four already steps; derived).
- The event gets `kPageZoom` only on Aura and Android, only for non-precise-pixel deltas with Ctrl held (`third_party/blink/common/input/web_mouse_wheel_event.cc:119-125`).
- A "step" is the next entry in `{0.25, 1/3, 0.5, 2/3, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0, 5.0}`, clamped to 25 %..500 % on desktop (`third_party/blink/common/page/page_zoom.cc:13-15, 25-26`). I did not open the `PageZoom::Zoom` code that picks the next entry, nor `Browser::ContentsZoomChange` (**unverified**).
- **Mac is excluded.** The whole block is `#if !BUILDFLAG(IS_MAC)`: "On Mac, this isn't done for two reasons: the OS already has a gesture to do this through pinch-zoom; if a user starts an inertial scroll ... and presses control ... the OS's buffered scroll events will come in with control key set which isn't what the user wants" (`web_contents_impl.cc:4919-4925`). Chrome's help page has no Mac scroll-zoom row either [Chrome shortcuts]. Posting Ctrl + wheel events on a Mac therefore does nothing in Chrome and Edge.
- Firefox: `mousewheel.with_control.action` exists but I did not read its default for macOS (**unverified**).

### 2.3 macOS zoom shortcuts

- Safari: "Press Command-Plus Sign (+) or Command-Minus Sign (-)" [Safari shortcuts]. Reset is not listed on that page (**unverified**).
- Chrome Mac: Cmd + `+` / Cmd + `-` / Cmd + `0` [Chrome shortcuts].
- Firefox Mac: Cmd + `+`, Cmd + `-`, Cmd + `0` (secondary: [iDownloadBlog]); a source-derived list (secondary) says Cmd + `=` also works.
- System-wide text editing: Apple's list has Shift-Command-Plus "Increase the size of the selected item. Command–Equal sign (=) performs the same function." and Shift-Command-Minus "Decrease the size of the selected item." [Mac keyboard shortcuts]. That is about selected items, not page zoom; Preview and Pages use their own menu items (**unverified** per app).
- Cmd-= is the unshifted key on a US layout; on other layouts the physical key carrying `=` or `+` moves (**unverified**, test before relying on key codes).

## 3. macOS side buttons

### 3.1 Event shape

- Buttons 0 and 1 are `leftMouse*` and `rightMouse*`. Every other button arrives as `otherMouseDown / Up / Dragged`; Apple documents `kCGEventOtherMouseDown` as "a mouse down event with one of buttons 2-31", 0-based, so 2 is the centre button [CGEventType.otherMouseDown]. `NSEvent.buttonNumber` uses the same numbering (via Chromium/OpenJDK usage, secondary).
- 3 = back, 4 = forward is a convention, not an Apple constant. It is what Chromium (below), Firefox (`widget/cocoa/nsCocoaUtils.mm:1142-1146`: `case 3: return MouseButton::eX1; case 4: return MouseButton::eX2;`), VS Code (`historyService.ts:176-190`) and SensibleSideButtons (`AppDelegate.m:76, 83`) all use.
- CoreGraphics field: `kCGMouseEventButtonNumber` read with `CGEventGetIntegerValueField` (`AppDelegate.m:70`).

### 3.2 Who handles 3/4 natively

| App | Native? | Evidence |
|---|---|---|
| Chrome, Chromium, Edge | Yes. Button number 3 becomes `Button::kBack`, 4 `kForward` (`components/input/web_input_event_builders_mac.mm:237-248`, used for other-mouse events at `:371, :386`). `WebContentsImpl::HandleMouseEvent` goes back/forward on **mouse-up** when history allows (`web_contents_impl.cc:4884-4900`). Edge shares the code (inferred, as in windows-scroll.md §2.5). Mac Mouse Fix's author reports Edge and Slack respond to buttons 4/5 (Aug 2025). | |
| Firefox | Yes, since Firefox 92. Bug 1615213 "Support special back/forward mouse buttons" (fixed in 92) replaced the old behaviour where both buttons arrived as middle. Mapping at `nsCocoaUtils.mm:1129-1153`. Side effect: web pages get no `mousedown` for these buttons, as on Windows (comment 31). | [Mozilla 1615213] |
| VS Code, VS Code forks, Cursor | Yes, in the renderer, not through Electron. `workbench.editor.mouseBackForwardToNavigate` (default `true`, `workbench.contribution.ts:396-397`) installs DOM `mousedown`/`mouseup` listeners and goes back on button 3, forward on button 4, **on mouse-down**, and stops the event so the browser default does not run (`src/vs/workbench/services/history/browser/historyService.ts:146-190`). Mac Mouse Fix's notes: VSCodium, Windsurf, Trae "MB 4/5 works" while navigation swipes do not. | |
| Electron apps in general | The `app-command` event is Windows and Linux only; the renderer sees `button` 3/4 and Chromium walks history for plain buttons (secondary: Rocket.Chat PR 3550, Min issue 410). Per-app, **unverified**. | [Electron BrowserWindow] |
| JetBrains IDEs | Buttons 4/5 work, per Mac Mouse Fix's notes (Aug 2025). | [MMF back-forward notes] |
| Safari | **No.** SensibleSideButtons' README: "macOS mostly ignores the M4/M5 mouse buttons"; an OpenLogi user reports Safari and Finder do not react (secondary). No Apple page states it. | [SSB README] |
| Finder | **No** by the same sources. Navigation swipes work (Mac Mouse Fix: "Always worked for me"). | |
| System Settings, App Store | No; need Cmd-[ / Cmd-] (App Store has back only). | [MMF back-forward notes], `Actions.m:96-97` |
| Music, TV, Preview | No; Cmd-[ goes back (Music, TV: no forward); Preview Cmd-[ / Cmd-] go back and forward. | [MMF back-forward notes], `Actions.m:105, 110-112` |

### 3.3 VS Code history

Issue 8641 (2016) asked for buttons 4 and 5 on macOS and blamed an Electron limitation (electron/electron #6996); the fix landed after Electron 7. Issue 116507 notes Electron's `swipe` event for drivers that emit swipes. Issues 88029, 184645, 201794 and 225524 are bug reports where the buttons stop working, mostly with Logitech or Mac Mouse Fix remapping (issue titles only, not all opened).

## 4. macOS Back and Forward shortcuts

| App | Back | Forward | Evidence |
|---|---|---|---|
| Finder | Cmd-[ | Cmd-] | [Mac keyboard shortcuts]: "Go to the previous folder" / "Go to the next folder" |
| Safari | Cmd-[ | Cmd-] | [Safari shortcuts] |
| Chrome | Cmd-[ or Cmd-Left | Cmd-] or Cmd-Right | [Chrome shortcuts] |
| Firefox | Cmd-[ or Cmd-Left | Cmd-] or Cmd-Right | secondary: [Mozilla Connect], [iDownloadBlog]; Mozilla's own help page did not load (**unverified** at source) |
| Xcode | Ctrl-Cmd-Left | Ctrl-Cmd-Right | [Xcode menu shortcuts] (archive, Xcode 4 era; unchanged in later write-ups, secondary). Cmd-[ is "Shift Left" in Xcode: **unverified** here. |
| VS Code | Ctrl-- | Ctrl-Shift-- | `editorActions.ts:1501-1520`: `mac: { primary: KeyMod.WinCtrl \| KeyCode.Minus, secondary: [KeyCode.BrowserBack] }`. Forward is the same file; Shift variant per the issue-tracker workaround, I did not read the forward block. |
| JetBrains IDEs | Cmd-[ | Cmd-] | [JetBrains Guide navigation] |
| System Settings, App Store, Music, TV | Cmd-[ | Cmd-] (Music/TV/App Store: back only) | `Actions.m:96-97, 105, 110`, [MMF back-forward notes] |
| Preview, Zotero | Cmd-[ | Cmd-] | `Actions.m:95, 112`, [MMF back-forward notes] |
| Acrobat | Cmd-Left | Cmd-Right | `Actions.m:98` |

Cmd-[ / Cmd-] are **not** back/forward in every app: Mac Mouse Fix's survey lists indent in Notes, Reminders, CotEditor and Freeform, previous/next occurrence in Calendar, and flipping contacts in Contacts. A blanket Cmd-[ mapping is therefore wrong; it must be per app. Apple's own list gives no general rule beyond Finder.

## 5. macOS accessibility zoom on scroll

- UI: System Settings > Accessibility > Zoom has "Use scroll gesture with modifier keys to zoom" ("To zoom in or out, press and hold the selected modifier key while scrolling with your trackpad or mouse") and "Modifier key for scroll gesture" ("Control, Option, or Command") [Apple Zoom settings]. The page does not say what is on by default or which key is preselected. Apple's "Zoom in on your Mac screen" page (search summary, secondary) names the same options.
- Defaults domain: dotfiles write `com.apple.universalaccess closeViewScrollWheelToggle -bool true` and `closeViewScrollWheelModifiersInt -int 262144` (262144 = `1<<18`, the Control flag mask; older dotfiles use `HIDScrollZoomModifierMask`). All secondary (public dotfiles, [dotfiles gist]); no Apple page names these keys, and Apple can change them. **unverified**.
- On the machine I used, `defaults read com.apple.universalaccess closeViewScrollWheelToggle` and `...ModifiersInt` both returned "key not found", so the feature has never been switched on there; this suggests, but does not prove, that it is off and unconfigured by default.
- Default modifier Control: only the dotfiles value suggests it; Apple's page lists three modifiers with no default (**unverified**).
- Interaction: if a user has this on with Control, Ctrl + wheel zooms the whole screen at the OS level before or alongside any app handling. How it orders against an event tap is **unverified**.

## 6. How other utilities do it

| Tool | License | Back/Forward action | Source |
|---|---|---|---|
| SensibleSideButtons | GPL-2.0-or-later (`LICENSE`, header of `main.m`) | Taps `otherMouseDown/Up` at `kCGHIDEventTap` and swallows buttons 3 and 4 (returns `NULL`). Button 3 posts a navigation swipe left, 4 swipe right. Default fires on mouse-down (`SBFMouseDown = YES`), option `SBFSwapButtons` swaps the buttons. The swipe is built with the private gesture fields from `External/TouchEvents.c` and posted as two events (began, ended) at `kCGHIDEventTap`. | `SensibleSideButtons/AppDelegate.m:30-62, 69-93, 160-163, 350-366` |
| Mac Mouse Fix | Custom "MMF License" (source available, GitHub reports "NOASSERTION"); not a standard open-source license, check before copying anything | "Back" / "Forward" actions choose a method per app by bundle id: default for `com.apple.*` is the navigation swipe, default for everything else is a simulated button 4/5 click; exceptions use Cmd-[ / Cmd-] (System Settings, App Store, Music, TV, Books, Preview, Zotero, Warp) or Cmd-Left/Right (Acrobat). Opera and ForkLift get swipes. Notes: swipes fail in VS Code and Cursor; Chrome sometimes ignores swipes shortly after load. | `Helper/Core/Actions/Actions.m:49-123`, `Helper/Core/Actions/Universal Back and Forward.md` |
| LinearMouse | MIT | `UniversalBackForwardTransformer`: a navigation swipe is posted only if the target app's bundle id is in `["com.apple.*", "com.binarynights.ForkLift*", "org.mozilla.firefox", "com.operasoftware.Opera"]`; any other app gets the plain back/forward mouse button. Swipe: two `CGEvent`s of NSEvent type `.gesture`, with `IOHIDEventType.navigationSwipe`, phases began and ended and the swipe mask left (back) or right (forward), posted at `.cgSessionEventTap`. The "Back"/"Forward" button actions use the same path. | `LinearMouse/EventTransformer/UniversalBackForwardTransformer.swift:15-20, 62-88, 95-112`, `ButtonActionExecutor.swift:598-603, 628-640`, `Modules/GestureKit/Sources/GestureKit/GestureEvent+NavigationSwipe.swift:1-24` |

Notes:

- The navigation swipe depends on undocumented CGEvent gesture fields. Apple does not document them; the code lives in private-API wrappers (`TouchEvents.c`, `GestureKit`). That conflicts with a "no private API" preference and may break on any macOS release (**unverified** whether it has broken; Mac Mouse Fix's Aug 2025 notes show app-specific failures).
- Mac Mouse Fix's author notes that LinearMouse sends swipes to Firefox but Firefox accepts buttons 4/5 since 92 (`Actions.m:90`).
- I did not compile or run any of the three tools.

## 7. Confidence and open questions

| Claim | Confidence | Basis |
|---|---|---|
| WM_XBUTTONUP -> WM_APPCOMMAND, back = 1, forward = 2 | high | Microsoft Learn |
| Context menu on WM_RBUTTONUP on Windows | high | Microsoft Learn |
| Windows 500 ms, 4 px defaults | high for 500 ms, medium-high for 4 px | SetDoubleClickTime doc; legacy registry reference |
| Chromium zooms one step per whole tick on Windows, nothing on Mac | high | source at `a0e963ee` |
| Buttons 3/4 handled natively by Chromium, Firefox 92+, VS Code | high | source |
| Safari, Finder do not handle 3/4 | medium | project README, issue reports; no Apple statement |
| `closeViewScrollWheel*` key names, Control default | low | dotfiles only |
| Per-app Cmd-[ / Cmd-] list | medium | Mac Mouse Fix's author's tests, Aug 2025 |

Open questions:

1. Event tap scope. Button handling needs `otherMouseDown/Up`; Ctrl + wheel needs the existing scroll tap. `AGENTS.md` says "Event taps see scroll-wheel events only". Changing that rule is the owner's decision.
2. Which app is "frontmost"? The right target is the app under the pointer for scroll (mac-hid in windows-scroll.md §8), but for navigation keystrokes it is the key window of the frontmost app. Posting a keystroke goes to the key window; `NSWorkspace.frontmostApplication` is the natural source (**unverified** for apps with palettes).
3. Hold behaviour: Chromium acts on mouse-up, VS Code on mouse-down. Acting on release matches Windows (§1.1).
4. Layout-dependent key codes for Cmd-= (§2.3).
5. Nobody has tried any of this on hardware yet.

## 8. Target spec for macOS

Buttons 3 and 4, decided per frontmost application at the moment of the button event. The app swallows the button only when it posts a replacement.

| Frontmost app (bundle id) | Action | Reason |
|---|---|---|
| Chrome, Edge, Brave, Chromium forks (`com.google.Chrome*`, `com.microsoft.edgemac*`, `com.brave.Browser*`) | pass through | Native (`web_input_event_builders_mac.mm:237-248`); swipes are flaky in Chrome. |
| Firefox (`org.mozilla.firefox`) | pass through | Native since 92. |
| VS Code, VSCodium, Cursor, Windsurf, Trae, other Electron editors | pass through | App handles DOM button 3/4 itself (`historyService.ts:170-190`); swipes do not work. |
| JetBrains IDEs | pass through | Buttons work per Mac Mouse Fix's notes. |
| Safari, Finder | Cmd-[ / Cmd-] | Documented by Apple [Mac keyboard shortcuts], [Safari shortcuts]; public API, no private gesture fields. |
| System Settings, App Store, Music, TV, Preview | Cmd-[ / Cmd-] | Swipes do nothing here; shortcut works (Mac Mouse Fix). Forward does nothing where the app has none. |
| Xcode | Ctrl-Cmd-Left / Ctrl-Cmd-Right | [Xcode menu shortcuts]. |
| Everything else | pass through | Cmd-[ means indent, previous occurrence or flip contacts in many apps (§4); guessing is worse than doing nothing. Users add apps in settings. |

Act on the button-up event like Windows (§1.1). Swallow the matching button-down too, or the app sees a down without an up.

Ctrl + wheel (system Ctrl, not Cmd): consume the event and post Cmd-= for a notch away from the user, Cmd-- for a notch toward the user, one per 120 units, accumulating `n = delta / 120` and stepping when the accumulator rounds to a whole number, like `HandleWheelEvent` (`web_contents_impl.cc:4930-4935`). Reasons:

- Windows convention is Ctrl + wheel zoom (§2.1), and Chromium on Mac refuses it (§2.2), so only keystrokes work in Chrome, Edge and Safari.
- Cmd-= / Cmd-- is the macOS zoom key pair in Safari, Chrome and Firefox (§2.3); Cmd-= avoids needing Shift on a US layout.
- One step per notch matches Chromium on Windows (§2.2).
- The synthetic key event must carry Command only: remove Control from the flags.
- Skip it when the frontmost app is on a "Ctrl + wheel does something else" list (e.g. apps with their own scroll zoom) or when macOS Zoom's own scroll-wheel option is on with Control (§5).

Right button, double-click: leave as macOS has them (§1.3, §1.4).

Not covered: middle-click actions beyond what browsers already do (§1.2), tilt wheel, any gesture or modifier remapping, swipe-based Back/Forward (private API, §6).

## 9. Constants used by the app

| Constant | Value | Evidence |
|---|---|---|
| Side button numbers | 3 back, 4 forward | §3.1 |
| `kVK_ANSI_LeftBracket`, `kVK_ANSI_RightBracket` | 0x21, 0x1E | SDK 27 `HIToolbox.framework/Headers/Events.h:229, 226` |
| `kVK_ANSI_Equal`, `kVK_ANSI_Minus` | 0x18, 0x1B | `Events.h:220, 223` |
| `kVK_LeftArrow`, `kVK_RightArrow` | 0x7B, 0x7C | `Events.h:311-312` |
| Control in `closeViewScrollWheelModifiersInt` | `1 << 18` | `NSEventModifierFlagControl = 1 << 18`, SDK 27 `AppKit.framework/Headers/NSEvent.h:170`; key name per §5 (**unverified**) |

Virtual key codes name a key position (the US ANSI layout), not a character. On a layout where `[` sits elsewhere (Turkish Q puts `ğ` on that key), what the app sees as the shortcut depends on whether it localizes its key equivalents to positions (macOS 12+ `NSMenuItem.allowsAutomaticKeyEquivalentLocalization`) or matches characters. **Unverified** on hardware with a non-US layout; one of the first things to test.

The app counts one zoom step per wheel event, the same one-notch-per-event rule the scrolling uses (`WheelEvents.swift`, `notches`), instead of accumulating `delta / 120`: macOS hands the tap accelerated line deltas, not 120-unit detents (macos-hid.md §1.1).

## Sources

Source code, read first-hand (`raw.githubusercontent.com`, fetched 2026-10-31):

- Chromium main `a0e963eebbcac6a60522c1aab8f72d519c7477aa`: https://github.com/chromium/chromium/tree/a0e963eebbcac6a60522c1aab8f72d519c7477aa . Files: `components/input/web_input_event_builders_mac.mm`, `content/browser/web_contents/web_contents_impl.cc`, `third_party/blink/common/input/web_mouse_wheel_event.cc`, `third_party/blink/common/page/page_zoom.cc`, `third_party/blink/renderer/core/input/event_handler.cc`, `third_party/blink/renderer/core/frame/settings.json5`, `third_party/blink/renderer/core/exported/web_view_impl.cc`, `ui/views/win/hwnd_message_handler.cc`, `ui/events/cocoa/events_mac.mm` (maps every other button to middle; unused for web input).
- Firefox main `a5df22d986d4b626f771b4f8885241941601c35c`: https://github.com/mozilla-firefox/firefox/tree/a5df22d986d4b626f771b4f8885241941601c35c . Files: `widget/cocoa/nsCocoaUtils.mm`, `dom/events/EventStateManager.cpp`, `browser/base/content/browser.js`.
- VS Code main `97d01924531421f671b69342f629ba0f9f0f1e2e`: https://github.com/microsoft/vscode/tree/97d01924531421f671b69342f629ba0f9f0f1e2e . Files: `src/vs/workbench/services/history/browser/historyService.ts`, `src/vs/workbench/browser/parts/editor/editorActions.ts`, `src/vs/workbench/browser/workbench.contribution.ts`.
- SensibleSideButtons `f24c0ced598325182fa4c4a38f57223530a47adc` (GPL-2.0-or-later): https://github.com/archagon/sensible-side-buttons/tree/f24c0ced598325182fa4c4a38f57223530a47adc [SSB README]
- LinearMouse `338f4809d29b9c14a5ec7cc0329cadc3e959cb18` (MIT): https://github.com/linearmouse/linearmouse/tree/338f4809d29b9c14a5ec7cc0329cadc3e959cb18
- Mac Mouse Fix `0b2c6fd746ed9fdeb24eb0190ce07b6aed82bfd2` (MMF License): https://github.com/noah-nuebling/mac-mouse-fix/tree/0b2c6fd746ed9fdeb24eb0190ce07b6aed82bfd2 ; [MMF back-forward notes]: `Helper/Core/Actions/Universal Back and Forward.md` in the same tree.

Microsoft documentation:

- [WM_XBUTTONDOWN]: https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-xbuttondown
- [WM_XBUTTONUP]: https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-xbuttonup
- [WM_APPCOMMAND]: https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-appcommand
- [WM_CONTEXTMENU]: https://learn.microsoft.com/en-us/windows/win32/menurc/wm-contextmenu
- [About Mouse Input]: https://learn.microsoft.com/en-us/windows/win32/inputdev/about-mouse-input
- [GetDoubleClickTime]: https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getdoubleclicktime
- [SetDoubleClickTime]: https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setdoubleclicktime
- [GetSystemMetrics]: https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getsystemmetrics
- [Best practices 2004]: https://learn.microsoft.com/en-us/previous-versions/ms997498(v=msdn.10)
- [Win2000 registry reference] (DoubleClickWidth/Height default 4, found through search, legacy): https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-2000-server/cc978661(v=technet.10) , https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-2000-server/cc978663(v=technet.10)
- [Keyboard shortcuts in Windows] (search summary): https://support.microsoft.com/en-us/accessibility/windows/keyboard-shortcuts-in-windows

Apple documentation:

- [Mac keyboard shortcuts]: https://support.apple.com/en-us/102650
- [Safari shortcuts]: https://support.apple.com/guide/safari/keyboard-and-other-shortcuts-cpsh003/mac
- [Apple Zoom settings]: https://support.apple.com/guide/mac-help/change-zoom-settings-for-accessibility-mh40579/mac ; "Zoom in on your Mac screen": https://support.apple.com/guide/mac-help/zoom-in-on-your-mac-screen-mchl779716b8/mac
- [CGEventType.otherMouseDown]: https://developer.apple.com/documentation/coregraphics/cgeventtype/othermousedown
- [Xcode menu shortcuts] (archive): https://developer.apple.com/library/archive/documentation/IDEs/Conceptual/xcode_help-command_shortcuts/MenuCommands/MenuCommands014.html
- [How Menus Work] (archive): https://developer.apple.com/library/content/documentation/Cocoa/Conceptual/MenuList/Articles/HowMenusWork.html
- `NSEvent.doubleClickInterval`: https://developer.apple.com/documentation/appkit/nsevent/doubleclickinterval (page text did not load; facts above are from the declaration only)

Other vendors and trackers:

- [Chrome shortcuts]: https://support.google.com/chrome/answer/157179
- [JetBrains Guide navigation]: https://www.jetbrains.com/guide/java/tips/code-nav-fwd-back/
- [Electron BrowserWindow]: https://www.electronjs.org/docs/latest/api/browser-window
- [Mozilla 1615213]: https://bugzilla.mozilla.org/show_bug.cgi?id=1615213 ; Mozilla bug 1360278 (search summary): https://bugzilla.mozilla.org/show_bug.cgi?id=1360278
- VS Code issues: https://github.com/microsoft/vscode/issues/8641 , /116507 , /140714 , /88029 , /225524 (titles and search summaries)

Secondary, or unverified where marked:

- [Mozilla Connect]: https://connect.mozilla.org/t5/ideas/macos-add-back-forward-to-the-application-menu/idi-p/14785 ; [iDownloadBlog]: https://www.idownloadblog.com/2020/04/13/keyboard-shortcuts-for-firefox-mac/
- [MS Q&A Explorer zoom]: https://learn.microsoft.com/en-us/answers/questions/5811332/zoom-on-file-explorer ; [Office Watch]: https://office-watch.com/2024/quicker-ways-to-zoom-in-microsoft-office/
- [dotfiles gist] (`closeViewScrollWheel*` keys): https://gist.github.com/CvX/6069760 and mathiasbynens/dotfiles issue 371: https://github.com/mathiasbynens/dotfiles/issues/371
- OpenLogi issue 23 (Safari, Finder ignore buttons): https://github.com/AprilNEA/OpenLogi/issues/23 ; Rocket.Chat PR 3550: https://github.com/RocketChat/Rocket.Chat.Electron/pull/3550 ; Min issue 410: https://github.com/minbrowser/min/issues/410

[WM_XBUTTONDOWN]: https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-xbuttondown
[WM_XBUTTONUP]: https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-xbuttonup
[WM_APPCOMMAND]: https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-appcommand
[WM_CONTEXTMENU]: https://learn.microsoft.com/en-us/windows/win32/menurc/wm-contextmenu
[About Mouse Input]: https://learn.microsoft.com/en-us/windows/win32/inputdev/about-mouse-input
[GetDoubleClickTime]: https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getdoubleclicktime
[SetDoubleClickTime]: https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setdoubleclicktime
[GetSystemMetrics]: https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getsystemmetrics
[Best practices 2004]: https://learn.microsoft.com/en-us/previous-versions/ms997498(v=msdn.10)
[Win2000 registry reference]: https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-2000-server/cc978661(v=technet.10)
[Keyboard shortcuts in Windows]: https://support.microsoft.com/en-us/accessibility/windows/keyboard-shortcuts-in-windows
[Mac keyboard shortcuts]: https://support.apple.com/en-us/102650
[Safari shortcuts]: https://support.apple.com/guide/safari/keyboard-and-other-shortcuts-cpsh003/mac
[Apple Zoom settings]: https://support.apple.com/guide/mac-help/change-zoom-settings-for-accessibility-mh40579/mac
[CGEventType.otherMouseDown]: https://developer.apple.com/documentation/coregraphics/cgeventtype/othermousedown
[Xcode menu shortcuts]: https://developer.apple.com/library/archive/documentation/IDEs/Conceptual/xcode_help-command_shortcuts/MenuCommands/MenuCommands014.html
[How Menus Work]: https://developer.apple.com/library/content/documentation/Cocoa/Conceptual/MenuList/Articles/HowMenusWork.html
[Chrome shortcuts]: https://support.google.com/chrome/answer/157179
[JetBrains Guide navigation]: https://www.jetbrains.com/guide/java/tips/code-nav-fwd-back/
[Electron BrowserWindow]: https://www.electronjs.org/docs/latest/api/browser-window
[Mozilla 1615213]: https://bugzilla.mozilla.org/show_bug.cgi?id=1615213
[Mozilla Connect]: https://connect.mozilla.org/t5/ideas/macos-add-back-forward-to-the-application-menu/idi-p/14785
[iDownloadBlog]: https://www.idownloadblog.com/2020/04/13/keyboard-shortcuts-for-firefox-mac/
[MS Q&A Explorer zoom]: https://learn.microsoft.com/en-us/answers/questions/5811332/zoom-on-file-explorer
[Office Watch]: https://office-watch.com/2024/quicker-ways-to-zoom-in-microsoft-office/
[dotfiles gist]: https://gist.github.com/CvX/6069760
[SSB README]: https://github.com/archagon/sensible-side-buttons/blob/f24c0ced598325182fa4c4a38f57223530a47adc/README.md
[MMF back-forward notes]: https://github.com/noah-nuebling/mac-mouse-fix/blob/0b2c6fd746ed9fdeb24eb0190ce07b6aed82bfd2/Helper/Core/Actions/Universal%20Back%20and%20Forward.md
