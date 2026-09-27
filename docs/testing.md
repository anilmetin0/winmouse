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

Finally verify restoration:

1. Pause WinMouse, then quit it; compare the mouse behavior with the baseline.
2. Reconnect the mouse and confirm it uses the baseline behavior.
3. Restart WinMouse after forcing a quit, then quit normally and check recovery.
4. Confirm the built-in trackpad's behavior never changed.

Do not describe hardware behavior as verified until these checks have been run on the target Mac and
mouse. Record the macOS version, mouse model/connection, observed result, and any failures with the
release checklist.
