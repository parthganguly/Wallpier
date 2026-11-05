# Wallpier

Wallpier is a native macOS wallpaper browser built with Swift and AppKit. Browse a local image folder or discover wallpapers through Wallhaven, organize favorites and collections, preview images on a desktop-shaped canvas, and set or rotate wallpapers with Undo history.

## Development status

This is an open-source development project, not a production-ready release. `main` contains the accepted Batch 3 source baseline and public project documentation. The draft `codex/opus/rc1-import` branch adds visual polish, improved previews and Fit defaults, remote-wallpaper retention groundwork, the app icon, packaging metadata, and repository CI.

The RC1 import has two known release blockers tracked in [GitHub Issues](https://github.com/parthganguly/Wallpier/issues):

- **P1:** failed durable retention can still allow manual Set or rotation to use a purgeable cache file.
- **P2:** the existing ad-hoc Release package contains a debugging entitlement and LLVM coverage instrumentation.

The import requires independent review at an exact commit SHA before acceptance. No downloadable public release, Developer ID signing, or notarization is provided.

## Features

- Local wallpaper browsing and Wallhaven discovery with provider-native search filters.
- Favorites and named collections without downloading every remote original.
- Gallery selection, an inspector, and desktop composition previews.
- Per-display wallpaper application, timed rotation, and Undo history.
- Native macOS menus, keyboard interaction, and window behavior.

The RC1 branch improves preview navigation and full-image composition, makes Fit the default for new state, and starts retaining active remote originals outside purgeable caches. The P1 failure path remains unresolved. Preview rendering is an approximation; physical desktop behavior needs its own acceptance checks.

## Requirements and compatibility

The project targets **macOS 12.0 or later** and Swift 5 language mode. The existing local validation baseline is an **Intel Mac running macOS Ventura 13.7.8 with Xcode 15.2**. That evidence does not establish every feature as accepted.

Runtime support on **macOS 12** and **Apple Silicon** remains unverified. Building an arm64 executable, or running deterministic hosted tests, does not establish physical Apple Silicon desktop acceptance. Multi-display behavior, Spaces, sleep/wake, accessibility, and actual Fit/Fill/Center rendering require suitable physical Macs.

## Build from source

1. Clone this repository and open `Wallpier.xcodeproj` in Xcode 15.2 or a compatible newer Xcode.
2. Select the **Wallpier** scheme and **My Mac** destination.
3. For a local development build, select an appropriate signing configuration if Xcode requests it, then build and run.

To compile without a signing identity:

```sh
xcodebuild -project Wallpier.xcodeproj -scheme Wallpier \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
```

To inspect the pending RC1 work, check out `codex/opus/rc1-import`. That branch includes a shared Xcode scheme, `Scripts/ci-core-tests.txt`, and a CI workflow for a reviewed deterministic subset. See [CONTRIBUTING.md](https://github.com/parthganguly/Wallpier/blob/codex/opus/rc1-import/CONTRIBUTING.md) for test scope and the SHA-bound review process. The complete interactive suite is broader than hosted CI and may require an active desktop session.

`Scripts/package-test-build.sh` on the RC1 branch produces an ad-hoc test package. Its current P2 defect blocks distribution; do not treat that package as a finished public release.

## Artwork and license

Repository source and original project artwork are available under the [MIT License](LICENSE), copyright 2026 Parth Ganguly.

Wallhaven artwork belongs to its respective creators and is not relicensed by this repository. Respect each creator's rights and the service's terms when downloading or using wallpapers. Personal wallpaper files, runtime state, credentials, and local recovery evidence are excluded from the published source.
