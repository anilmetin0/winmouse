#!/bin/bash
# Builds WinMouse.app with plain swiftc. A handful of files needs no Xcode project, and SwiftPM
# cannot run inside a sandboxed shell (it nests its own sandbox for the manifest).
#   ./build.sh            self-test, then build/WinMouse.app (arm64 + x86_64)
#   ./build.sh selftest   self-test only
#   ./build.sh dmg        all of the above, then build/WinMouse-<version>.dmg and its SHA-256
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

# The pure math and event mapping (no AppKit, no event taps) against docs/research.
TESTED=(Sources/WinMouse/WindowsPointer.swift Sources/WinMouse/ScrollAnimation.swift
        Sources/WinMouse/WheelEvents.swift Sources/WinMouse/Buttons.swift)
"${SWIFTC[@]}" -target "arm64-apple-macos$MIN" "${TESTED[@]}" Sources/SelfTest/*.swift -o build/selftest
build/selftest
[[ "${1:-}" == "selftest" ]] && exit 0

APP="build/WinMouse.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for arch in arm64 x86_64; do
    "${SWIFTC[@]}" -parse-as-library -target "$arch-apple-macos$MIN" Sources/WinMouse/*.swift -o "build/WinMouse-$arch"
done
lipo -create build/WinMouse-arm64 build/WinMouse-x86_64 -output "$APP/Contents/MacOS/WinMouse"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/" 2>/dev/null || true

# Accessibility permission is tied to the signature. An ad-hoc signature changes with every build,
# so macOS forgets the permission after a rebuild; CODESIGN_IDENTITY="Your Certificate" avoids that.
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
(cd build && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "Ready: $DMG"
