#!/bin/bash
# Builds WinMouse.app with plain swiftc. A handful of files needs no Xcode project, and SwiftPM
# cannot run inside a sandboxed shell (it nests its own sandbox for the manifest).
#   ./build.sh            self-test, then build/WinMouse.app (arm64 + x86_64)
#   ./build.sh selftest   self-test only
#   ./build.sh dmg        all of the above, then build/WinMouse-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")"

# xcrun caches under /var/folders, which sandboxed shells may not write; its warnings are harmless.
# -disable-sandbox: SwiftUI's macros (@State since SDK 27) run in a plugin server that the compiler
# would otherwise wrap in its own sandbox, which fails when the shell is already sandboxed.
SDK="$(xcrun --show-sdk-path 2>/dev/null)"
MIN=14.0
# The module cache goes under build/ for the same reason: the default lives in /var/folders.
SWIFTC=(xcrun swiftc -O -swift-version 6 -disable-sandbox -sdk "$SDK" -module-cache-path build/ModuleCache)
mkdir -p build

# Reference math, event mapping and update file checks; no event tap or HID writes.
TESTED=(Sources/WinMouse/WindowsPointer.swift Sources/WinMouse/ScrollAnimation.swift
        Sources/WinMouse/WheelEvents.swift Sources/WinMouse/Buttons.swift Sources/Shared/UpdateSupport.swift)
"${SWIFTC[@]}" -target "arm64-apple-macos$MIN" "${TESTED[@]}" Sources/SelfTest/*.swift -o build/selftest
build/selftest
[[ "${1:-}" == "selftest" ]] && exit 0

APP="build/WinMouse.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for arch in arm64 x86_64; do
    "${SWIFTC[@]}" -parse-as-library -target "$arch-apple-macos$MIN" Sources/WinMouse/*.swift Sources/Shared/*.swift -o "build/WinMouse-$arch"
    "${SWIFTC[@]}" -parse-as-library -target "$arch-apple-macos$MIN" Sources/UpdateHelper/main.swift Sources/Shared/*.swift -o "build/WinMouseUpdater-$arch"
done
lipo -create build/WinMouse-arm64 build/WinMouse-x86_64 -output "$APP/Contents/MacOS/WinMouse"
lipo -create build/WinMouseUpdater-arm64 build/WinMouseUpdater-x86_64 -output "$APP/Contents/MacOS/WinMouseUpdater"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj Resources/AppIcon.icns "$APP/Contents/Resources/"

# Accessibility permission is tied to the signature. An ad-hoc signature changes with every build,
# so macOS forgets the permission after a rebuild; CODESIGN_IDENTITY="Your Certificate" avoids that.
codesign --force --sign "${CODESIGN_IDENTITY:--}" --timestamp=none "$APP/Contents/MacOS/WinMouseUpdater"
codesign --force --sign "${CODESIGN_IDENTITY:--}" --timestamp=none "$APP"
echo "Ready: $APP"
[[ "${1:-}" == "dmg" ]] || exit 0

# A disk image with the app and a link to /Applications, so installing is one drag.
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="build/WinMouse-$VERSION.dmg"
STAGE="build/dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "WinMouse $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGE"
if [[ "$VERSION" != *-* ]]; then
    python3 scripts/update-manifest.py "$VERSION" "$DMG" > build/update.json
fi
echo "Ready: $DMG"
