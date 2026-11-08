# Releasing

Releases are made from version tags. For a `vX.Y.Z` tag, the `Build and release` workflow runs the
self-tests, builds the universal app, packs it into `WinMouse-X.Y.Z.dmg` with a SHA-256 file, and
publishes a GitHub release whose notes are the `X.Y.Z` section of `CHANGELOG.md`. Versions with a
suffix such as `-beta.1` are marked as prereleases and do not become the latest release.

Stable releases also include `update.json`, generated from the exact disk image. Native checks
use `/releases/latest/download/update.json`. It is uploaded after the cask has been pinned, so
the native Homebrew route sees the corresponding cask version.

After a stable release is published, the workflow updates `Casks/winmouse.rb` on `main` with
the released version and the disk image's SHA-256. The cask stays pinned to the previous stable
release until that point; never use `sha256 :no_check` for it. No separate tap repository is needed:
`brew tap anilmetin0/winmouse https://github.com/anilmetin0/winmouse` uses this repository.
Homebrew 7 and later also require `brew trust anilmetin0/winmouse`.
The contents API write uses the checked-out blob SHA, so a concurrent cask edit is rejected.

## Before tagging

1. Set `CFBundleShortVersionString` in `Resources/Info.plist` to `X.Y.Z` and raise
   `CFBundleVersion` by one. The workflow stops if the tag and the app version differ.
2. In `CHANGELOG.md`, rename `Unreleased` to `[X.Y.Z] - YYYY-MM-DD`, add a new empty
   `Unreleased` above it, and update the comparison links at the bottom.
3. Run `./build.sh dmg`, open the disk image and try the app.
4. Complete the physical-mouse checks in [`testing.md`](testing.md), or say in the changelog which
   ones were not run.
5. Commit as `Release X.Y.Z` and make sure CI on `main` is green.

Also run `python3 scripts/test-update-cask.py`, `brew style Casks/winmouse.rb`, and
`actionlint .github/workflows/release.yml`. The workflow runs the first two on macOS.
Update both languages on the `landing` branch when installation instructions change. Its
download links and version labels follow `/releases/latest`, matching the stable Homebrew cask.

## Publish

```sh
git tag -a vX.Y.Z -m "WinMouse X.Y.Z"
git push origin vX.Y.Z
```

The app is signed ad hoc, not with a Developer ID certificate, and is not notarized. macOS asks
the user to approve the first launch in System Settings > Privacy & Security. Do not describe a
build as notarized.

## Check after publishing

- Verify the DMG, checksum and update manifest on the GitHub release and their SHA-256, and confirm the cask's version
  and checksum match the released disk image.
- Confirm the cask update commit reached `main`, and test its download without installing
  over a developer's working copy.
- Check the English and Turkish landing pages at desktop and phone widths, including the
  install/update copy buttons and the release-notes link.
- If requesting confirmation of an issue fix, link the specific release and leave the issue
  open until the reporter confirms the result. Distinguish synthetic tests from hardware checks.
