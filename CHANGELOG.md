# Changelog

User-visible changes are recorded here. Releases remain experimental until physical-mouse testing
is complete.

## [0.2.0] - 2026-10-31 (experimental prerelease)

- Side buttons go back and forward on release, as on Windows: passed through to apps that handle
  them (Chrome, Edge, Firefox, VS Code, JetBrains) and turned into each app's Back/Forward shortcut
  in Finder, Safari, System Settings, App Store, Music, TV, Preview and Xcode.
- Control + wheel zooms (Command-= / Command--), skipped when macOS Zoom uses Control + wheel.
- One event tap for the wheel and the side buttons; the Accessibility notice covers both.
- The raw wheel-delta field is spelled by number, so SDKs that don't name it still build; CI runs
  on macOS 26.

## [0.1.0] - 2026-09-28 (experimental prerelease)

- Initial implementation of the external-mouse pointer curve and fixed-distance wheel scrolling.
- Added public documentation, contribution guidelines, macOS CI, and a universal app release build.
