#!/bin/bash
# Fails unless a packaged Wallpier.app is a clean Release artifact: strict valid signature, hardened runtime,
# no enabled get-task-allow, exactly arm64 + x86_64, and no LLVM coverage instrumentation in either slice.
# usage: Scripts/audit-release-app.sh <Wallpier.app>
set -euo pipefail
app=$(cd "${1:?usage: $0 <Wallpier.app>}" && pwd)
codesign --verify --strict --deep "$app"
python3 -I - "$app" <<'PY'
import plistlib, re, subprocess, sys
app = sys.argv[1]
binary = f'{app}/Contents/MacOS/Wallpier'
def run(*args):
    result = subprocess.run(args, capture_output=True, text=False, check=True)
    return result.stdout, result.stderr.decode()
raw, _ = run('codesign', '-d', '--entitlements', ':-', app)
entitlements = plistlib.loads(raw.strip()) if raw.strip() else {}
assert entitlements.get('com.apple.security.get-task-allow') is not True, 'Debug entitlement get-task-allow is enabled'
_, signature = run('codesign', '-dvvv', app)
assert re.search(r'flags=\S*\(.*runtime.*\)', signature), 'Hardened runtime is missing'
arches = set(run('xcrun', 'lipo', '-archs', binary)[0].decode().split())
assert arches == {'arm64', 'x86_64'}, f'Unexpected architecture slices: {sorted(arches)}'
for arch in sorted(arches):
    symbols = run('xcrun', 'nm', '-arch', arch, binary)[0].decode()
    sections = run('xcrun', 'otool', '-arch', arch, '-l', binary)[0].decode()
    found = sorted(set(re.findall(r'__llvm_(?:profile|prf|cov)\w*', symbols + sections)))
    assert not found, f'Coverage instrumentation in {arch}: {found[:5]}'
print(f'Release audit passed: {sorted(arches)}, strict signature, hardened runtime, no get-task-allow, no coverage')
PY
