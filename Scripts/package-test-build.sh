#!/bin/bash
# Builds a Universal Release Wallpier.app and zips it for private testing.
# usage: Scripts/package-test-build.sh <output dir>
#
# Ad-hoc signed with the hardened runtime: runs on the building Mac and, after the tester removes
# quarantine or uses right-click > Open, on others. Not Developer ID signed or notarized.
# Fails, and leaves no ZIP, unless the app extracted from the ZIP passes Scripts/audit-release-app.sh.
set -euo pipefail
out=$(cd "${1:?usage: $0 <output dir>}" && pwd)
cd "$(dirname "$0")/.."
# Outside the source tree: a DerivedData path sharing its prefix confuses dsymutil.
dd="${TMPDIR:-/tmp}/wallpier-package-dd"
rm -rf "$dd"
# The Release target already sets these; repeating them here keeps a stray xcconfig or override from
# reintroducing the debugging entitlement (ad-hoc signing counts as development) or coverage instrumentation.
xcodebuild -project Wallpier.xcodeproj -scheme Wallpier -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$dd" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO \
  build > "$out/release-build.log" 2>&1
if grep -q -E -e '-profile-generate|-profile-coverage-mapping|-fprofile-instr-generate' "$out/release-build.log"; then
  echo "Release build injected coverage instrumentation; see $out/release-build.log" >&2
  exit 1
fi
app="$dd/Build/Products/Release/Wallpier.app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$app/Contents/Info.plist")
rm -rf "$out/Wallpier.app" "$out/Wallpier.app.dSYM"
ditto "$app" "$out/Wallpier.app"
ditto "$app.dSYM" "$out/Wallpier.app.dSYM"
zip="$out/Wallpier-$version-$build-universal-adhoc.zip"
rm -f "$zip" "$zip.sha256"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
# Audit what testers receive: the app extracted from the final ZIP. The checksum is written only after it passes.
shipped=$(mktemp -d "${TMPDIR:-/tmp}/wallpier-shipped.XXXXXX")
trap 'rm -rf "$shipped"' EXIT
ditto -x -k "$zip" "$shipped"
if ! bash Scripts/audit-release-app.sh "$shipped/Wallpier.app"; then
  rm -f "$zip"
  echo "Release artifact audit failed; removed $zip" >&2
  exit 1
fi
(cd "$out" && shasum -a 256 "$(basename "$zip")") | tee "$zip.sha256"
