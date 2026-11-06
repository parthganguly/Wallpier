#!/usr/bin/env python3
"""Release artifact guard for Wallpier's private ad-hoc test package.

Exit 0 only if the given Wallpier.app is strictly and validly ad-hoc signed with the hardened
runtime, has neither arm64 nor x86_64 slice missing, and carries no debugging entitlement and no
LLVM coverage instrumentation in either slice. Mirrors the hosted audit in
.github/workflows/ci.yml (release-audit job) so the failure appears before any upload.

usage: python3 Scripts/audit-release-artifact.py <path to Wallpier.app>
"""
import pathlib
import plistlib
import re
import subprocess
import sys


def run(*argv: str) -> str:
    return subprocess.check_output(argv, text=True)


app = pathlib.Path(sys.argv[1])
binary = app / "Contents/MacOS/Wallpier"

run("codesign", "--verify", "--strict", "--deep", str(app))

raw = run("codesign", "-d", "--entitlements", ":-", str(app)).strip()
entitlements: dict = plistlib.loads(raw) if raw else {}  # type: ignore[assignment]
if entitlements.get("com.apple.security.get-task-allow", False):
    raise SystemExit("Forbidden debugging entitlement is enabled: com.apple.security.get-task-allow")
print("  entitlements: no com.apple.security.get-task-allow")

signature = subprocess.run(
    ["codesign", "-dvvv", str(app)], capture_output=True, text=True, check=True
).stderr
if not re.search(r"flags=.*runtime", signature):
    raise SystemExit("Hardened runtime is missing")
if "adhoc" not in signature:
    raise SystemExit("Ad-hoc signature is missing")
print("  signature: valid, strict, ad-hoc with hardened runtime")

arches = set(run("xcrun", "lipo", "-archs", str(binary)).split())
if arches != {"arm64", "x86_64"}:
    raise SystemExit(f"Unexpected architecture slices: {arches}")
print(f"  architecture slices: {', '.join(sorted(arches))} ok")

for arch in sorted(arches):
    symbols = run("xcrun", "nm", "-arch", arch, str(binary))
    sections = run("xcrun", "otool", "-arch", arch, "-l", str(binary))
    if re.search(r"__llvm_(profile|prf|cov)", symbols + sections):
        raise SystemExit(f"Coverage instrumentation in {arch}")
    print(f"  {arch}: no LLVM coverage symbols or sections")

print("  artifact audit: PASS")
