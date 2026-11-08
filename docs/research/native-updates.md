# Native and Homebrew updates

2026-11-08. Update behavior introduced in 0.3.0, after the 0.2.0 Homebrew release.

## Homebrew lifecycle evidence

The tested Homebrew source at `2ed87166a21c29527db16218bc79a8a534faa4e8` records running apps
successfully quit by `uninstall quit` and reopens them after an upgrade:

- [AbstractUninstall.uninstall_quit](https://github.com/Homebrew/brew/blob/2ed87166a21c29527db16218bc79a8a534faa4e8/Library/Homebrew/cask/artifact/abstract_uninstall.rb)
- [Upgrade.reopen_apps_after_upgrade](https://github.com/Homebrew/brew/blob/2ed87166a21c29527db16218bc79a8a534faa4e8/Library/Homebrew/cask/upgrade.rb)
- [Cask configuration precedence and persisted app directory](https://github.com/Homebrew/brew/blob/2ed87166a21c29527db16218bc79a8a534faa4e8/Library/Homebrew/cask/config.rb)

Therefore manual Quit and `open -a WinMouse` instructions do not belong in the upgrade commands.
`brew update` refreshes tap metadata; `brew upgrade --cask winmouse` replaces the app.

The cask uses the standard `uninstall quit` directive and Homebrew's own reopen behavior.
The initial /tmp fixture was not discoverable by Launch Services for `open -b`. Repeating the
test with a complete app fixture installed under the project's build directory passed: Homebrew
quit 0.6.0 normally, upgraded it and reopened 0.7.0. The app trace recorded stop/restore before
the new launch. The native Homebrew route quits itself normally before the external upgrade,
then its helper reopens the app by its explicit path. No custom cask executable hooks are used.

## Native delivery contract

Updates are enabled by default, with one Settings switch to disable them. Like AndroMac,
checks happen at launch and UI entry, plus wake/session activation, at most once per 24 hours.
There is no repeating update timer. The manual menu check remains available. The HTTPS endpoint is this repository's stable release asset:
`https://github.com/anilmetin0/winmouse/releases/latest/download/update.json`.
GitHub's [release asset download documentation](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases)
explains the stable `/releases/latest/download/asset-name` URL. It avoids the unauthenticated API
rate limit seen while testing the website.

The manifest contains a stable, numeric X.Y.Z version, the exact GitHub release DMG URL, byte
count, lowercase SHA-256, and the matching release-notes URL. Both URLs must exactly match this
repository's versioned paths. A malformed manifest, downgrade, failed download, byte-count/hash
mismatch, wrong bundle identifier/version/executable or invalid code signature stops installation.
The trust anchor is HTTPS delivery from the owner's GitHub release, including its hash; this is
not a separate signed update feed and does not protect against compromise of the release account.

Manual installs stream the DMG to disk, verify it, mount it read-only with `hdiutil`, and copy
with `ditto` to a private, same-volume staging directory. System `shasum` and `codesign` verify
integrity; no runtime package or framework dependency is added. Staging uses mode 0700.
After verification a separate helper waits for normal app termination, swaps the bundle with
Foundation's same-volume replacement API, keeps a backup until Launch Services opens the new
copy, and restores the backup if launch fails. It never removes quarantine or changes privacy
settings. A non-writable or mounted-image install reports an error without replacing the app.

Homebrew installs are detected by their persisted `Caskroom/winmouse/.metadata/config.json` and
exact `appdir`, at the standard Apple Silicon `/opt/homebrew` or Intel `/usr/local` prefixes.
Their native Install button refreshes/fetches while WinMouse is open, quits normally, then runs
only the named cask upgrade and reopens the app. Homebrew retains ownership of its receipt and
checksum checks. Dependent upgrades and automatic cleanup are disabled for this operation.

## Operational bounds

- Daily cadence: 24 × 60 × 60 seconds, following AndroMac's `UpdateCheck.interval` and its
  event-driven `checkIfDue` approach. A backwards clock change permits one fresh check.
- Automatic installs wait for the app's windows/menu to close and its own wheel animation and
  held-side-button work to finish. The engine reports idle transitions; no motion/drag/left/right
  event taps or polling are introduced. Failed automatic handoffs are not retried in a loop for
  the same release; the user can retry manually.
- Manifest limit: 64 KiB; the generated manifest is only a few hundred bytes. This is a parser
  bound, not an input-behavior constant. The download's expected size comes from the built image.
- Helper shutdown deadline: 30 seconds, checked every 100 ms only during an update. A process
  that refuses normal termination cancels the replacement. This bounded update-only wait does
  not add an idle timer to the app.
- Stable versions contain exactly three ASCII integer components without leading zeros; numeric
  ordering prevents 0.10.0 being mistaken for a downgrade from 0.9.0.
- App identity remains `io.github.anilmetin0.winmouse`; the executable remains `WinMouse`.
- The app remains ad-hoc signed and unnotarized. macOS may require Accessibility to be refreshed
  after either update route. The settings window opens when that permission is missing.

## Verification

`Sources/SelfTest/UpdateTests.swift` exercises version ordering, malformed/foreign/HTTP manifests,
known SHA-256 vectors, corrupt/wrong-size files, actual filesystem replacement and rollback, a
missing-candidate failure preserving the old copy, and Homebrew detection with a custom appdir.
Additional native UI and lifecycle checks use separate bundle identities, mouse controllers that
perform no HID writes, and temporary app/tap directories. Physical mouse behavior remains outside
these updater tests; see `docs/testing.md`.
