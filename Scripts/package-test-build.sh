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
# CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO keeps Xcode from adding com.apple.security.get-task-allow
# to the shipped signature; ENABLE_CODE_COVERAGE=NO keeps LLVM profiling out of both slices.
# Debug and test coverage behavior (ENABLE_TESTABILITY, the scheme's TestAction and the CI core
# job) are untouched. See .github/workflows/ci.yml for the independent hosted audit of this package.
xcodebuild -project Wallpier.xcodeproj -scheme Wallpier -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$dd" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO ENABLE_CODE_COVERAGE=NO \
  build > "$out/release-build.log" 2>&1
app="$dd/Build/Products/Release/Wallpier.app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$app/Contents/Info.plist")
codesign --verify --strict --deep "$app"
# Audit the app that will be zipped, then the app extracted back out of the finished ZIP, so the
# guard covers the actual shipped artifact, not just Xcode build settings.
audit-release-artifact() { python3 Scripts/audit-release-artifact.py "$1"; }
rm -rf "$out/Wallpier.app" "$out/Wallpier.app.dSYM"
ditto "$app" "$out/Wallpier.app"
ditto "$app.dSYM" "$out/Wallpier.app.dSYM"
audit-release-artifact "$out/Wallpier.app"
zip="$out/Wallpier-$version-$build-universal-adhoc.zip"
rm -f "$zip"
ditto -c -k --sequesterRsrc --keepParent "$out/Wallpier.app" "$zip"
shasum -a 256 "$zip" | tee "$zip.sha256"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/wallpier-zip-audit.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
ditto -x -k "$zip" "$scratch"
audit-release-artifact "$scratch/Wallpier.app"
