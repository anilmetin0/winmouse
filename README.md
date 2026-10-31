# WinMouse

WinMouse makes an external mouse on a Mac behave the way it does on Windows: the same pointer
curve and speed slider, the same wheel feel, Ctrl + wheel zoom, and side buttons that go back and
forward. Trackpads keep their macOS behavior.

**Status: experimental.** The curve, scroll and button mapping pass the included reference-vector
tests, and the app builds for Apple Silicon and Intel. Behavior with a physical mouse, permission
handling and restoration after a crash still need hardware testing.

## Features

### Pointer

WinMouse builds its curve from the Windows default curve and pointer speed setting (1 to 20,
default 10). It supplies the curve as an acceleration table for each external mouse. With
"Enhance pointer precision" off, it uses the linear speed settings from the Windows model.

### Wheel

Wheel scrolling is designed for a fixed distance per notch (3 lines, 100 points) with a short
ease-in-out. It does not add speed-based acceleration or momentum. Shift with the wheel scrolls
sideways. The wheel keeps the Windows direction when the trackpad uses natural scrolling.

Control with the wheel zooms, as Ctrl + wheel does on Windows: each notch away from you presses
Command-=, each notch toward you Command--. Chrome on the Mac ignores Ctrl + wheel, so keystrokes
work in Chrome as well as Safari. If macOS Zoom is set to zoom the screen with Control
and the wheel, WinMouse leaves it alone.

Trackpads, the Magic Mouse's touch scrolling, apps that declare themselves games, and wheel
gestures with Command or Option keep their macOS behaviour.

### Buttons

On Windows the side buttons go back and forward in every window. On a Mac, Chrome, Edge, Firefox,
VS Code and JetBrains IDEs already do that and get the buttons untouched. Finder, Safari, System
Settings, the App Store, Music, TV and Preview ignore them, so WinMouse presses their Back and
Forward shortcuts (Command-[ and Command-]; Control-Command-arrow in Xcode). It acts when you
release the button, as Windows does. Other apps keep the buttons, because Command-[ means indent
in many of them.

The middle button, right-click and double-click already behave like Windows in macOS browsers
and are left alone.

## Requirements

- macOS 14 Sonoma or later.
- Accessibility access, for the wheel and the side buttons. The pointer needs no permission.

## Install

Build from source with macOS 14 or later and Xcode or the Xcode Command Line Tools:

```sh
git clone https://github.com/anilmetin0/winmouse.git
cd winmouse
./build.sh
cp -R build/WinMouse.app /Applications/
open /Applications/WinMouse.app
```

A mouse icon appears in the menu bar and the settings window opens. The first time, macOS asks for
Accessibility access: allow WinMouse in System Settings > Privacy & Security > Accessibility.

After a rebuild, macOS may no longer recognise the permission, because it is tied to the app's
signature and a local build gets a new one every time. Remove WinMouse from the Accessibility list
and add it again, or sign with a certificate of your own:
`CODESIGN_IDENTITY="Your Certificate" ./build.sh`.
This signs only your local build; WinMouse releases do not use a project Developer ID certificate.

If you installed NewMouse before the rename, quit and remove the old app before opening WinMouse.
The new bundle identifier starts with fresh app settings and needs its own Accessibility grant.

## Settings

The settings use Windows names and defaults.

| Setting | On Windows | Default |
|---|---|---|
| Pointer speed | Mouse pointer speed | 10 of 20 |
| Enhance pointer precision | Enhance pointer precision | On |
| Lines to scroll at a time | Lines to scroll at a time | 3 |
| Characters to scroll horizontally | Horizontal scrolling | 3 |
| Smooth scrolling | Smooth scrolling in Chrome and Edge | On, off when Reduce Motion is on |
| Scrolling direction | Down motion scrolls down | Windows |
| Control + wheel zooms | Ctrl + wheel zoom | On |
| Side buttons go back and forward | Back and forward buttons | On |

The menu bar icon pauses and resumes WinMouse.

## What it does to your Mac

WinMouse does not write global system preferences. For each detected external mouse, it changes
per-device HID properties and saves their original values on the service. It attempts to restore
them on pause and quit, and recover after a crash on the next launch. Disconnecting the mouse or
restarting the Mac clears the service override. These behaviors have not yet been checked with a
physical mouse. Avoid running another mouse utility that changes the same HID properties or wheel
events.

## How it matches Windows

Each number comes from a source, collected in `docs/research`:

- [windows-pointer.md](docs/research/windows-pointer.md): the Windows pointer curve, the speed
  slider and the "Enhance pointer precision" math. The model fits INRIA's measurements of real
  Windows pointer output to within 0.02 %.
- [windows-scroll.md](docs/research/windows-scroll.md): the distance per notch and the animation,
  taken from Chromium's source.
- [macos-hid.md](docs/research/macos-hid.md): where macOS applies acceleration and how an app can
  replace a device's curve.
- [existing-apps.md](docs/research/existing-apps.md): what LinearMouse, Mac Mouse Fix, Mos and
  others do, and the problems their users reported.

Known differences from Windows:

- macOS measures the speed of a movement as its straight-line length. Windows adds the longer axis
  and half of the shorter one, so a diagonal movement counts as up to 12 % slower on the Mac and
  gets a little less acceleration.
- When the mouse speeds up into a steeper part of the curve, Windows blends the old and new
  segments for one report. A macOS table cannot do that.
- Side buttons only reach the apps listed above; unknown apps keep the raw buttons.
- The shortcuts are sent as key positions. On keyboard layouts where `[` or `=` sit on another key,
  an app that matches shortcuts by character may not react. Tell us which app.
- WinMouse uses private HID interfaces. A macOS update could change them. If pointer behavior is
  wrong, quit the app and reconnect the mouse or restart the Mac.

## Uninstall

Quit WinMouse from its menu, delete it from Applications and remove it from the Accessibility list
in System Settings.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for build and change guidelines. The app source is in
`Sources/WinMouse`, the self-tests are in `Sources/SelfTest`, and the research behind behavior and
constants is in `docs/research`. See the [architecture](docs/architecture.md) and
[hardware testing](docs/testing.md) notes for implementation details and verification steps.

## Project status

The [prereleases](https://github.com/anilmetin0/winmouse/releases) are
experimental and has no Developer ID signature or notarization.
See [CHANGELOG.md](CHANGELOG.md) for project history and [releasing.md](docs/releasing.md) for the
release process. Report security issues using GitHub's private reporting feature; do not publish
exploit details in a public issue. See [SECURITY.md](SECURITY.md).

## License

MIT. See [LICENSE](LICENSE).
