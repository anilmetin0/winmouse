# Changelog

All notable changes to WinMouse are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

New entries go under `Unreleased`. When a version is tagged, that section gets the version number
and the date, and it becomes the release notes on GitHub.

## [Unreleased]

## [0.3.0] - 2026-11-08

### Added

- Check for Updates in the menu bar and Settings. Install and Relaunch handles downloading,
  verification, installation and restarting. Homebrew-managed copies use Homebrew from the same
  window, preserving the cask receipt.
- Native update manifests are published with every stable release. Checks are manual; no
  background polling or update preference is added.
- Update tests cover manifest validation, SHA-256, actual bundle replacement/rollback and an
  end-to-end upgrade with a separate test identity and mouse controllers that do not write HID.

### Fixed

- Removed manual Quit and reopen instructions from Homebrew updates. Homebrew manages a running
  app's lifecycle; the native updater restores mouse state before restarting itself.
- Update errors and cancellation keep the installed copy. A failed relaunch restores the previous
  bundle; if restoration itself fails, the helper keeps the backup and reports its location.
- Missing Accessibility access opens Settings after an update or relaunch.

### Changed

- Regenerated the macOS iconset from the existing WinMouse vector, with clearer 16/32-point
  variants, a template menu-bar symbol and the WinMouse icon in the update window.
- Applied the same brand assets to the README, favicons and landing pages; macOS download buttons
  now use the Apple mark.
- Updated the English and Turkish installation and update instructions.

### Validation

- The native upgrade test downloads a fixture, verifies it, calls the normal shutdown path,
  replaces the bundle, relaunches the new version and verifies its signature. It uses mock mouse
  controllers, so this is not physical-mouse acceptance.
- The Homebrew lifecycle test upgraded a running, isolated app in the project's build directory,
  called its normal shutdown path and reopened the new version. No custom executable hooks
  were added to the cask.

## [0.2.0] - 2026-11-08

### Added

- Install with Homebrew using the tap in this repository. Run `brew update` and
  `brew upgrade --cask winmouse` to update. The release workflow pins each stable release's
  cask version and SHA-256 after publishing the disk image.
- Regression checks for browser scroll phases, both scroll directions at 60/120/144 Hz,
  horizontal cancellation and the Homebrew cask updater.

### Fixed

- Smooth wheel frames in supported browsers now share one Begin/Changed/End sequence. This
  addresses the repeated video jumps reported on YouTube Shorts and Facebook Reels in
  [#3](https://github.com/anilmetin0/winmouse/issues/3). The Windows curve, distance and timing
  are unchanged; confirmation with the reporter's mouse is still needed.
- An animation keeps its original pointer location and target process when available, and
  stops on app switches, setting changes, native trackpad input and modifier gestures.
- Releasing a side button after switching apps no longer sends navigation to the new app.
- A failed HID restoration keeps the mouse's recovery backup instead of discarding it.
- Granting Accessibility is detected when returning to WinMouse or opening its menu, without
  a background permission-polling timer.

### Changed

- Updated and pinned the build and artifact actions to their current release commits.
- The English and Turkish installation instructions cover Homebrew updates and refreshing
  Accessibility access after an update.

### Validation

- Reference and event-construction tests cover the calculations and CGEvent-to-AppKit phase
  mapping. Physical mouse acceptance on Shorts/Reels, HID write failures, and mixed-refresh
  displays has not been completed. Please report the mouse model, browser and macOS version
  if video skipping continues.

## [0.1.0] - 2026-10-31

First public release.

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

[Unreleased]: https://github.com/anilmetin0/winmouse/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/anilmetin0/winmouse/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/anilmetin0/winmouse/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/anilmetin0/winmouse/releases/tag/v0.1.0
