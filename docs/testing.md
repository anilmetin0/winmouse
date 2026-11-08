# Testing

## Build and reference tests

On macOS 14 or later with Xcode or the Xcode Command Line Tools:

```sh
./build.sh selftest
./build.sh
```

The first command checks pointer and scroll math against the vectors in `docs/research`. The second
also builds a universal `build/WinMouse.app` for `arm64` and `x86_64`. These checks do not exercise
IOKit writes, Accessibility, event routing, or a real mouse.

The scroll tests also check the event builder's Begin/Changed/End and Cancelled phases through
AppKit at 60, 120 and 144 Hz, including distance conservation and phase-free output for native
apps. Release-tooling tests run separately with `python3 scripts/test-update-cask.py`.

## Hardware acceptance

Before testing, quit LinearMouse, Mac Mouse Fix, Mos, and any other utility that changes mouse HID
properties or wheel events. Connect an external mouse and record the trackpad behavior/settings for
comparison. Launch `build/WinMouse.app` and grant Accessibility access when macOS asks.

Check the active HID type:

```sh
hidutil property --matching '{"PrimaryUsagePage":1,"PrimaryUsage":2}' --get HIDPointerAccelerationType
```

The current implementation uses the legacy type name `NewMouseAcceleration` so a new install can
recover service backups left by the previous app name. Confirm it appears for the external mouse.

Capture scroll diagnostics while using the wheel:

```sh
log stream --style compact --level debug --predicate 'subsystem == "io.github.anilmetin0.winmouse"'
```

Check that the log reports the expected raw deltas and sender ID, that wheel motion follows the
selected direction and line count, and that continuous trackpad/Magic Mouse scrolling stays native.
Also check Shift-wheel, modifier gestures, a game-category app, and natural scrolling.

In YouTube Shorts and Facebook Reels, try one notch, a fast burst, a reverse notch and a pause
between notches, with smooth scrolling on and off. One notch must not skip multiple videos.
Move the pointer to another window during an animation, switch apps, disable scrolling while
side buttons remain enabled, and scroll the trackpad during a wheel tail. The old animation
must stop or remain at its original target. Check browser edges for rubber-banding as well.

Buttons and zoom:

- Side buttons in Chrome, Firefox and VS Code go back/forward once (not twice); in Finder, Safari,
  System Settings and Preview they go back/forward on release; in Notes nothing happens.
- Hold a side button, switch apps with Command-Tab, release: no stuck button, no stray shortcut.
- Control + wheel zooms Safari and Chrome one step per notch, away from you zooms in, with natural
  scrolling on and off. Test with a non-US keyboard layout (for example Turkish Q) as well.

Finally verify restoration:

1. Pause WinMouse, then quit it; compare the mouse behavior with the baseline.
2. Reconnect the mouse and confirm it uses the baseline behavior.
3. Restart WinMouse after forcing a quit, then quit normally and check recovery.
4. Confirm the built-in trackpad's behavior never changed.

Do not describe hardware behavior as verified until these checks have been run on the target Mac and
mouse. Record the macOS version, mouse model/connection, observed result, and any failures with the
release checklist.

## Native update acceptance

`./build.sh` also checks stable-version parsing, exact release URLs, SHA-256, bundle replacement,
rollback, failed-replacement preservation, and Homebrew receipt/config matching.

On a logged-in Mac with XcodeBuildMCP available, run `python3 scripts/test-native-update.py`
and `python3 scripts/test-native-update.py --automatic`.
It builds unique-identity app fixtures, substitutes mouse controllers that perform no HID writes,
serves fixture responses through URLProtocol, and exercises the production App/Updater/helper
path. The manual trace is launch 0.2.0 → available → stop → restore → launch 0.3.0. The automatic
variant makes no manual check/install calls and must reach the same new launch from startup. The new
fixture exits after recording its shutdown. Its apps, DMG and trace remain in the reported
temporary directory for inspection. This does not install into Applications or test real HID.

Manually check the update window's available, current, downloading, cancelled and error states,
including Try Again, in English and Turkish. Verify the app icon appears and text fits. The
0.3.0 pass verified the available/error/retry states visually and passed the native fixture upgrade.

For Homebrew, verify an installed, running copy closes and reopens with
`brew update && brew upgrade --cask winmouse`. A stopped copy should remain stopped. The isolated
/tmp fixture could not be reopened by bundle ID. A subsequent fixture installed under this
project's build directory passed the full Homebrew lifecycle: launch 0.6.0 → stop/restore 0.6.0
→ launch 0.7.0. Both used separate bundle IDs and mock mouse controllers; neither touched a
real WinMouse install or its HID settings.
