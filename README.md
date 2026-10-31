<div align="center">

<!-- icon -->

# WinMouse

**Your mouse, the way it feels on Windows.**

A free, open-source menu bar app that gives an external mouse on macOS the Windows pointer
acceleration, wheel scrolling, Ctrl + wheel zoom and back/forward side buttons.

[![Latest release](https://img.shields.io/github/v/release/anilmetin0/winmouse?include_prereleases&label=release)](https://github.com/anilmetin0/winmouse/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](#requirements)
[![Apple Silicon and Intel](https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-universal-555)](#requirements)
[![License: MIT](https://img.shields.io/github/license/anilmetin0/winmouse)](LICENSE)
[![Build](https://img.shields.io/github/actions/workflow/status/anilmetin0/winmouse/release.yml?branch=main&label=build)](https://github.com/anilmetin0/winmouse/actions/workflows/release.yml)

[**Download**](https://github.com/anilmetin0/winmouse/releases/latest) ·
[Features](#features) · [Install](#install) · [FAQ](#faq) · [Türkçe](#türkçe)

</div>

## Why

If your hands learned the mouse on Windows, a Mac feels wrong. The pointer starts slow and then
shoots off, and one wheel notch scrolls a different distance every time. That comes from macOS's
own acceleration curve and its trackpad-style scrolling, and the Mouse settings cannot turn either
into what Windows does.

Most Mac mouse utilities turn acceleration off or make the wheel glide like a trackpad. WinMouse
copies Windows instead. The curve comes from the Windows registry defaults, the scrolling from
Chromium's source, and every number is documented in [`docs/research`](docs/research).

## Features

**Windows pointer acceleration.** The "Enhance pointer precision" curve and the Windows pointer
speed slider (1 to 20, default 10), applied by macOS itself to each external mouse. It costs
nothing while the mouse moves and needs no permission. Turn precision off and you get Windows'
linear speeds.

**Windows wheel scrolling.** Every notch moves the same distance: 3 lines, with the short
ease-in-out of Chrome and Edge on Windows. There is no acceleration, no momentum and no bounce.
Shift + wheel scrolls sideways, and the tilt wheel scrolls by characters.

**Ctrl + wheel zoom.** Control with the wheel zooms in browsers and other apps, one step per
notch, as on Windows.

**Back and forward buttons.** The side buttons go back and forward when you release them, as on
Windows. Chrome, Edge, Firefox, VS Code and JetBrains IDEs get the buttons directly, while Finder,
Safari, System Settings, App Store, Music, TV, Preview and Xcode get their own Back and Forward
shortcuts.

**Only the mouse changes.** Trackpads, the Magic Mouse's touch scrolling and games keep their
macOS behaviour. The scroll direction stays Windows-style even with Natural scrolling on for the
trackpad.

**Settings with Windows names.** Each setting has the name and default of its Windows
counterpart. The app is in English and Turkish.

| Setting | Windows counterpart | Default |
|---|---|---|
| Pointer speed | Mouse pointer speed | 10 of 20 |
| Enhance pointer precision | Enhance pointer precision | On |
| Lines to scroll at a time | Lines to scroll at a time | 3 |
| Characters to scroll horizontally | Horizontal scrolling | 3 |
| Smooth scrolling | Smooth scrolling in Chrome and Edge | On (off with Reduce Motion) |
| Scrolling direction | Down motion scrolls down | Windows |
| Control + wheel zooms | Ctrl + wheel zoom | On |
| Side buttons go back and forward | Back and forward buttons | On |

## Install

1. Download `WinMouse-<version>.dmg` from the
   [latest release](https://github.com/anilmetin0/winmouse/releases/latest).
2. Open it and drag **WinMouse** to **Applications**.
3. Open WinMouse. It is not notarized by Apple, so the first launch is blocked: open
   **System Settings > Privacy & Security**, find the message about WinMouse and click
   **Open Anyway**.
4. Allow WinMouse in **System Settings > Privacy & Security > Accessibility** when asked. The
   wheel and the side buttons need it.

A mouse icon appears in the menu bar. Click it to pause WinMouse or open its settings.

### Requirements

- macOS 14 Sonoma or later, on Apple Silicon or Intel.
- A mouse with a wheel. Side buttons and a tilt wheel are optional.

### Build from source

```sh
git clone https://github.com/anilmetin0/winmouse.git
cd winmouse
./build.sh        # runs the self-tests, then builds build/WinMouse.app
./build.sh dmg    # also builds the disk image
```

This needs Xcode or the Command Line Tools. See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## FAQ

**Does it change my system settings?**
No. WinMouse writes nothing to system preferences. It sets the pointer curve on each external
mouse's own device entry and keeps the previous values. Those values go back when you pause or
quit WinMouse, and at the next launch if it crashed. Unplugging the mouse or restarting the Mac
also clears them.

**Why does it need Accessibility access?**
To read wheel and side-button events and post the scrolling and shortcuts that replace them. The
pointer curve works without it. WinMouse has no network code and collects nothing.

**Can I run it next to LinearMouse, Mac Mouse Fix or Mos?**
Quit them first. They change the same mouse settings and wheel events, and the two apps undo each
other. WinMouse warns you in its settings when one of them is running.

**A side button does nothing in my app.**
WinMouse only sends shortcuts to the apps listed above, because Command-[ means indent in many
others. Shortcuts are sent by key position, so with a keyboard layout where `[` sits elsewhere
an app may not react. [Open an issue](https://github.com/anilmetin0/winmouse/issues) with the
app's name and your layout.

**Can a macOS update break it?**
The pointer curve uses a private macOS interface, so a future macOS could change it. If the
pointer ever feels wrong, quit WinMouse and reconnect the mouse; that restores macOS's own curve.

**How close is it to Windows?**
The curve and the scrolling use Windows' and Chromium's own numbers. Two small differences
remain: macOS measures diagonal movement a little slower (up to 12 %), and it cannot blend two
curve segments the way Windows does for one report. The [research notes](docs/research) have the
details.

**How do I uninstall it?**
Quit WinMouse from its menu, move it from Applications to the Trash and remove it from the
Accessibility list in System Settings.

## Türkçe

WinMouse, Mac'e takılan harici farenin Windows'taki gibi davranmasını sağlayan ücretsiz ve açık
kaynaklı bir menü çubuğu uygulamasıdır. Windows'un imleç ivmesini ("İşaretçi hassasiyetini
artır" ve imleç hızı), tekerlek kaydırmasını, Ctrl + tekerlek yakınlaştırmayı ve geri/ileri yan
tuşlarını getirir. İzleme dörtgenine dokunmaz. Uygulama Türkçedir;
[son sürümü](https://github.com/anilmetin0/winmouse/releases/latest) indirip yukarıdaki kurulum
adımlarını izleyin.

## Contributing

Bug reports, mice or apps that behave differently from Windows, and pull requests are welcome.
Read [CONTRIBUTING.md](CONTRIBUTING.md) first. The [architecture](docs/architecture.md) and
[testing](docs/testing.md) notes explain how the app works and how to check a change. Report
security issues privately, as described in [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
