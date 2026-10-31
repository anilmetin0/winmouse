# Changelog

All notable changes to WinMouse are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

New entries go under `Unreleased`. When a version is tagged, that section gets the version number
and the date, and it becomes the release notes on GitHub.

## [Unreleased]

## [0.1.0] - 2026-10-31

First public prerelease. It is experimental: the math passes its reference tests, but behaviour
with a physical mouse has not been verified yet.

### Added

- **Pointer.** External mice get the Windows "Enhance pointer precision" curve and the Windows
  pointer speed slider (1 to 20, default 10). WinMouse writes it as an acceleration table on each
  mouse's own HID service, keeps the mouse's previous values, and puts them back on pause, on quit,
  on a user switch and after a crash. No permission is needed for this part.
- **Wheel.** Scrolling works like Chrome and Edge on Windows: 3 lines (100 points) per notch, a
  short ease-in-out, no acceleration and no momentum. Lines per notch, characters per tilt, smooth
  scrolling and the scrolling direction are adjustable. Shift + wheel scrolls sideways.
- **Zoom.** Control + wheel zooms the way Ctrl + wheel does on Windows, one step per notch. It is
  skipped when macOS Zoom already uses Control with the wheel.
- **Side buttons.** Back and forward act when the button is released, as on Windows. Chrome, Edge,
  Firefox, VS Code and JetBrains IDEs receive the buttons directly. Finder, Safari, System
  Settings, App Store, Music, TV, Preview and Xcode receive their own Back and Forward shortcuts.
  Other apps keep the buttons unchanged.
- Trackpads, the Magic Mouse's touch scrolling and apps that declare themselves games keep their
  macOS behaviour.
- A menu bar switch to pause everything, an optional Open at login, and a settings window in
  English and Turkish.
- A universal build for Apple Silicon and Intel, distributed as a disk image with a SHA-256
  checksum.

[Unreleased]: https://github.com/anilmetin0/winmouse/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/anilmetin0/winmouse/releases/tag/v0.1.0
