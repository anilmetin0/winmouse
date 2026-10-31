# Releasing

Releases are made from version tags. For a `vX.Y.Z` tag, the `Build and release` workflow runs the
self-tests, builds the universal app, packs it into `WinMouse-X.Y.Z.dmg` with a SHA-256 file, and
publishes a GitHub release whose notes are the `X.Y.Z` section of `CHANGELOG.md`. Versions below
1.0.0 and versions with a suffix such as `-beta.1` are marked as prereleases.

## Before tagging

1. Set `CFBundleShortVersionString` in `Resources/Info.plist` to `X.Y.Z` and raise
   `CFBundleVersion` by one. The workflow stops if the tag and the app version differ.
2. In `CHANGELOG.md`, rename `Unreleased` to `[X.Y.Z] - YYYY-MM-DD`, add a new empty
   `Unreleased` above it, and update the comparison links at the bottom.
3. Run `./build.sh dmg`, open the disk image and try the app.
4. Complete the physical-mouse checks in [`testing.md`](testing.md), or say in the changelog which
   ones were not run.
5. Commit as `Release X.Y.Z` and make sure CI on `main` is green.

## Publish

```sh
git tag -a vX.Y.Z -m "WinMouse X.Y.Z"
git push origin vX.Y.Z
```

The app is signed ad hoc, not with a Developer ID certificate, and is not notarized. macOS asks
the user to approve the first launch in System Settings > Privacy & Security. Do not describe a
build as notarized.
