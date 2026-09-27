# Releasing

Releases are created from version tags. The GitHub Actions workflow runs the self-tests, builds the
universal app, zips `WinMouse.app`, calculates a SHA-256 checksum, and creates a prerelease with both
files attached.

## Before tagging

1. Confirm the version in `Resources/Info.plist` matches the intended `vX.Y.Z` tag.
2. Move the corresponding `CHANGELOG.md` entries from `Unreleased` to a dated version heading.
3. Run `./build.sh` on macOS and review the resulting app.
4. Complete the physical-mouse checks in [`testing.md`](testing.md), or keep the release marked
   experimental and state which hardware checks remain unverified.
5. Make sure the `main` branch CI run is green.

## Publish

Push a version tag such as `v0.1.0`. The `Build and release` workflow creates a prerelease. It does
not sign the app with a Developer ID certificate or notarize it. macOS may require the user to
approve opening the downloaded app. Do not describe the build as notarized or ready for general
installation.

The ZIP contains the app bundle. Verify it after downloading:

```sh
shasum -a 256 -c WinMouse-v0.1.0-macos-universal.zip.sha256
```

Replace `v0.1.0` in the filename with the version being checked.
