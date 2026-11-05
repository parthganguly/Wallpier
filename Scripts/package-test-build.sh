#!/bin/bash
# Builds a Universal Release Wallpier.app and zips it for private testing.
# usage: Scripts/package-test-build.sh <output dir>
#
# Ad-hoc signed with the hardened runtime: runs on the building Mac and, after the tester removes
# quarantine or uses right-click > Open, on others. Not Developer ID signed or notarized.
set -euo pipefail
out=$(cd "${1:?usage: $0 <output dir>}" && pwd)
cd "$(dirname "$0")/.."
# Outside the source tree: a DerivedData path sharing its prefix confuses dsymutil.
dd="${TMPDIR:-/tmp}/wallpier-package-dd"
rm -rf "$dd"
xcodebuild -project Wallpier.xcodeproj -scheme Wallpier -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$dd" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build > "$out/release-build.log" 2>&1
app="$dd/Build/Products/Release/Wallpier.app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$app/Contents/Info.plist")
codesign --verify --strict --deep "$app"
rm -rf "$out/Wallpier.app" "$out/Wallpier.app.dSYM"
ditto "$app" "$out/Wallpier.app"
ditto "$app.dSYM" "$out/Wallpier.app.dSYM"
zip="$out/Wallpier-$version-$build-universal-adhoc.zip"
rm -f "$zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
shasum -a 256 "$zip" | tee "$zip.sha256"
