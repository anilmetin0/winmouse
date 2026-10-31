# Changelog

User-visible changes are recorded here. Releases remain experimental until physical-mouse testing
is complete.

## [0.1.0] - 2026-10-31 (experimental prerelease)

- External mice get the Windows "Enhance pointer precision" curve and the 1-20 pointer speed
  slider, as a per-device acceleration table that is restored on pause, quit and after a crash.
- Wheel scrolling like Chrome and Edge on Windows: a fixed distance per notch, a short ease-in-out,
  no acceleration or momentum. Shift + wheel scrolls sideways.
- Side buttons go back and forward on release, as on Windows: passed through to apps that handle
  them (Chrome, Edge, Firefox, VS Code, JetBrains) and turned into each app's Back/Forward shortcut
  in Finder, Safari, System Settings, App Store, Music, TV, Preview and Xcode.
- Control + wheel zooms (Command-= / Command--), skipped when macOS Zoom uses Control + wheel.
- Settings in English and Turkish, a universal build for Apple Silicon and Intel, and CI that
  publishes a zip with its SHA-256 for each version tag.
