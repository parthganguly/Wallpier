# M2 RESULT

Closure update: [M2_CLOSURE_REPORT.md](/Users/parth/Projects/Wallpier/M2_CLOSURE_REPORT.md) supersedes this historical product-pass report's Undo policy and test/build counts. The physical macOS unknowns remain explicit.

CONDITIONAL PASS — implemented, clean-built, universal-built, and 20 focused tests passed. The live search → preview → download → set path works. Elapsed collection rotation, assistive-technology coverage, and physical macOS behavior still need acceptance testing. No commit was made.

Important test-session side effect: the desktop currently shows Wallhaven `1jlpq3`. The final Set worked, but Undo could not restore the prior persisted assignment because `/private/tmp/wallpier_test_a.jpg` no longer exists. Wallpier showed a native error and preserved the current wallpaper/history. No replacement bytes or guessed original wallpaper were installed. The downloaded ~2.2 MiB original remains cached. The temporary verification favorite and collection were removed through the UI; rotation is Off.

# Primary install flow

Discover → enter a query and native Wallhaven filters → Search → select a thumbnail → inspect preview, resolution, uploader and tags → retain/choose display and scaling → Set Wallpaper. Only the selected original downloads; a cache hit reuses it. WallpaperService applies the local URL, and shared assignment/history logic records the result. Open on Wallhaven is available for attribution and source context.

Live verification included `forest`, three pages / 72 results, preview metadata, and a successful 4032×2268 Set of `1jlpq3`. The desktop visibly changed to the selected image.

# Files changed

Modified:

- `Wallpier.xcodeproj/project.pbxproj` — app source and test-fixture membership.
- `Wallpier/AppDelegate.swift` — source/search/favorite/collection menu commands; suppress live app startup in hosted unit tests.
- `Wallpier/MainWindowController.swift` — discovery/library UI, async orchestration, collection operations, on-demand collection rotation, shared Set/history flow.
- `Wallpier/WallpaperModels.swift` — provider-native options, remote references, favorites, collections, version-2 migration, cache protection.
- `Wallpier/ThumbnailProvider.swift` — size-sensitive local thumbnail keys and stale-generation protection.
- `Wallpier/WallpaperCollectionViewItem.swift` — local/remote identity, captions and accessibility labels.
- `WallpierTests/WallpierTests.swift` — 14 additional deterministic tests, retaining the six M1 tests.

Added:

- `Wallpier/RemoteWallpaperProvider.swift`
- `Wallpier/WallhavenProvider.swift`
- `Wallpier/RemoteWallpaperCache.swift`
- `Wallpier/RemoteThumbnailProvider.swift`
- `WallpierTests/Fixtures/wallhaven-search.json`
- `WallpierTests/Fixtures/wallhaven-detail.json`
- `M2_REPORT.md`

`WallpaperService.swift` and `WallpaperStateStore.swift` were not changed. Existing untracked `.agents/`, `.verdent/`, and `skills-lock.json` were preserved. The empty generated `default.profraw` test artifact was removed; it contained no data and is regenerable.

# Architecture

One programmatic AppKit window. MainWindowController is main-actor isolated and coordinates UI, existing persistence/history, provider/cache actors and bounded thumbnail workers.

The small RemoteWallpaperProvider protocol exposes search, detail and original download, with an associated SearchOptions type. Wallhaven categories, ratios, sorting and resolution remain Wallhaven-specific; there is no universal filter DSL. The current controller uses the concrete first provider. NetworkClient is injectable for deterministic tests.

WallpaperService remains the sole caller of NSWorkspace desktop-image APIs. The UI's other NSWorkspace use only opens the canonical source webpage. WallhavenProvider imports Foundation, not AppKit; the controller contains no endpoint/request construction.

# Wallhaven implementation

Implemented against the [official Wallhaven API documentation](https://wallhaven.cc/help/api): `/api/v1/search`, `/api/v1/w/{id}`, and the original/thumbnail/preview URLs returned by the API. No scraping or HTML parsing.

- SFW `purity=100`, no API key or account UI.
- Query, category, minimum resolution, aspect ratio and sorting. Selected-display pixel dimensions provide the default minimum.
- Explicit Load More; duplicate request prevention and identity deduplication. Query/filter changes cancel pending work; generation checks prevent stale result/error publication. Old filters cannot append into a new query.
- Search metadata cached for five minutes, bounded to 12 pages; detail metadata bounded to 100 references.
- Reads rate-limit headers; HTTP 429 honors Retry-After/reset and gates subsequent calls. A conservative 60-second fallback is retry policy, not an assumed service quota. Transient 502/503/504 responses receive one bounded retry, not polling.
- Canonical source URL, dimensions, uploader and selected tags are retained. Imagery is third-party content; nothing is bundled or rehosted.

Live Wallhaven requests intermittently returned HTTP 502 during verification; successful requests and a recoverable error UI were both observed.

# Cache

Originals: `/Users/parth/Library/Caches/Wallpier/Originals`, default internal limit 500 MiB (524,288,000 bytes). This is the original-file budget, not a whole-process/thumbnail budget.

Filenames combine sanitized provider and ID, SHA-256 of the original URL, and extension. Existing valid originals are reused. Corrupt originals recover at a new UUID-suffixed path; bytes are never overwritten at the old path. ImageIO validates with a tiny decode, not a full-resolution NSImage.

Modification-time LRU-ish eviction protects current persisted assignments, both sides of history, favorites and collection cached paths. If protected assets prevent the new file fitting, the new installation is rejected with an error. Missing cached files can download again on explicit need. No database or manifest framework.

Remote decoded thumbnails have a 100-entry / 32 MiB NSCache cost budget; local thumbnails retain a 120-entry / 40 MiB budget. URLCache is configured for 12 MiB memory / 80 MiB disk; the ephemeral session means durable thumbnail retention is not promised. Decode concurrency is two; HTTP connections per thumbnail host are four. NSCache budgets are advisory eviction limits, not strict RSS ceilings. Source/reset generations prevent canceled decodes from repopulating old image caches.

# Favorites / collections

Favorites store references without fetching originals. Collections support create, rename, delete, add, remove and browsing. Live checks verified these operations and relaunch retention; fixture tests verify model persistence and deduplication.

M2 deliberately keeps remote-reference collections separate from the existing local-folder library. Mixed local/remote collections were not added.

The existing Timer supports choosing a collection and downloading its next item only when needed. Tasks prevent overlapping Set/rotation downloads; cancellation and failure leave the desktop intact. Deleting the active rotation collection stops rotation rather than silently falling back to the local folder. A real elapsed-interval collection-rotation cycle was not observed in this session.

# Persistence

Existing Codable JSON at `/Users/parth/Library/Application Support/Wallpier/state.json`; version 2 adds references, favorites, collections and source/filter choices. M1 JSON with missing new fields migrates while retaining local selection, rotation, display assignments and history. Existing corrupt-state fallback remains. No SQLite or package extraction.

# Build

Machine: 2017 Intel MacBook Air, 8 GB RAM, Ventura 13.7.8; Xcode 15.2 (15C500b), Swift 5.9 toolchain / Swift 5 language mode. Deployment target remains macOS 12.0; sandbox remains disabled; no third-party application dependencies.

All final commands succeeded:

```sh
xcodebuild -project Wallpier.xcodeproj -scheme Wallpier -configuration Debug clean build
xcodebuild -project Wallpier.xcodeproj -scheme Wallpier -configuration Debug -destination 'platform=macOS,arch=x86_64' -only-testing:WallpierTests test
xcodebuild -project Wallpier.xcodeproj -scheme Wallpier -configuration Debug -destination 'generic/platform=macOS' ONLY_ACTIVE_ARCH=NO ARCHS='x86_64 arm64' build
```

`lipo -archs` confirmed `x86_64 arm64`. No compiler warnings/errors in these final logs:

- `/tmp/wallpier-m2-final-clean-build.log`
- `/tmp/wallpier-m2-final-focused-tests.log`
- `/tmp/wallpier-m2-final-universal-build.log`

Apple Silicon was cross-built, not runtime-tested. macOS 12 was deployment-target checked, not physically tested. The separate development-only computer-use helper reported npm audit findings during setup; it is not linked or shipped with Wallpier.

# Tests

20/20 focused tests passed. Coverage includes M1 persistence/history/navigation/intervals/image filtering/corruption fallback; version-1 migration; reference Codable; favorites and collection operations; query URL construction; search/detail fixtures; Retry-After and subsequent-request backoff; bounded gateway retry; cached-path preservation; deterministic filenames; protected eviction; corrupt-original recovery at a new path; and rejecting additions when protected files exhaust capacity. Tests use injected network clients and generated tiny images, not live networking or desktop mutation.

Live UI checks: search/preview, 24 → 48 → 72 results, grid navigation/scroll positioning, native menus, favorite without an original, collection create/add/browse/rename/remove/delete, relaunch retention, normal and minimum-size window layouts, and remote Set. Earlier smoke verification successfully exercised Undo; the final run verified its missing-file refusal instead. These are separate observations, not a claim that the final desktop was restored.

Remaining manual acceptance procedure:

1. Search two distinct queries rapidly; change filters during a pending page request. Confirm only the submitted query's pages appear. Test no-results and offline/retry behavior.
2. Preview and Set an uncached image, then repeat Set. Confirm original reuse, selected display/scaling, concise success state, and no additional original for simple browsing/favoriting.
3. Set two distinct available images and Undo. Confirm the first remains available and is restored. Delete neither source during this check.
4. Create a two-item collection, relaunch, choose it as the rotation source, choose the shortest interval, and wait through two firings. Test an uncached item and a failed download; confirm no overlap and unchanged desktop on failure. Set rotation Off afterward.
5. Remove items/delete the active rotation collection; confirm safe empty states and stopped rotation. Verify cached originals needed by history are retained.
6. Check VoiceOver, keyboard-only search → selection → Set, light/dark/high-contrast appearances, minimum window size and preview scrolling.
7. Run the separate physical M0/M1 checks below; do not treat unit-test success as evidence for them.

# Performance

Approximate Debug-process samples from `ps` (RSS KiB / 1024), on the Intel machine:

| State | Approximate RSS | Idle CPU |
|---|---:|---:|
| Local, six test images, earlier M2 sample | 49.6 MiB | 0% |
| 24 visible Wallhaven results, before final minor UI/status fixes | 52.5 MiB | 0% |
| 72 results after browsing / thumbnail warmup | 67.5 MiB | 0% |
| Same process switched to empty Local mode, old decoded grid released | 58.2 MiB | 0% |

Earlier repeated 72-result idle samples also stabilized near 67.5 MiB after warmup. This is short-session evidence of release/stability, not a long-running leak proof. Result metadata and URLSession/allocator caches can remain after a source change; RSS need not return immediately to launch baseline.

Grid navigation and large scroll-position changes completed without an observed hang. No frame-time profiling or measured scrolling FPS was performed.

Final live wallpaper API latency: **6.4 ms** for `1jlpq3` (4032×2268, ~2.2 MiB original). Earlier smoke call: 3.1 ms for another original. These measure only the NSWorkspace operation, not network download time or visible desktop-render completion. End-to-end download latency was not instrumented.

# Design review

M1's local controls evolved into a compact source switch, contextual search/library controls, dominant native collection grid and a restrained preview/Set pane. System fonts, native menus, source shortcuts and simple sheets remain. The preview now scrolls independently at the 860×560 minimum window size; its Set controls were visually verified reachable. The normal 1120-wide layout shows the full action stack without clipping.

The project-local Mac-app skill guided command availability, native controls and state retention; the computer-use skill supported actual Mac screenshots. This materially led to the minimum-height preview correction and collection-control availability fixes. No decorative dashboard/card redesign was introduced.

Limitations: no full VoiceOver/high-contrast pass, advanced drag/copy interoperability, or instrumented scroll benchmark. The observed appearance was the current system's dark appearance, not a complete appearance matrix.

# Unverified macOS behavior

Still physically unverified: visible Fill/Fit/Center differences; same-path/new-content refresh; Spaces; sleep/wake; true multi-display operation. No speculative workarounds were added. The final missing old `/tmp` fixture is a concrete file-availability failure, not evidence of an NSWorkspace bug. Undo cannot recreate a vanished source file.

# Scope audit

Only WallpaperService calls desktop wallpaper APIs. No AppKit in WallhavenProvider; no Wallhaven HTTP construction in the controller. Originals download only for explicit Set or an enabled collection-rotation firing. No API keys, NSFW UI, accounts, scraping, mass download, additional providers, database, plugin framework, lock-screen/screensaver code, dynamic HEIC generation, SwiftUI rewrite, AI features, launch-at-login, updater or release packaging. Existing local HEIC recognition was retained from M1; no HEIC feature work was added. No commit.

# M3 candidates

Identify only: complete physical/display/accessibility validation; stronger end-to-end automation for collection rotation and cancellation; longer memory/scroll profiling; evaluate mixed local/remote collections and image/source copy/drag affordances if user demand justifies them. No candidate was implemented as a new milestone.

# Release blockers

- Complete real elapsed collection rotation and failure/cancellation acceptance checks.
- Complete macOS 12, Apple Silicon, physical multi-display/Spaces/sleep-wake and accessibility coverage before making corresponding compatibility claims.
- Resolve the user's desired desktop after the missing-fixture Undo failure; the final verification image is still applied. The old file was already absent, and no guessed replacement was created.
- Wallhaven availability is an external dependency; intermittent 502 responses remain possible despite bounded retry.
- Signing/notarization/distribution were expressly out of M2 scope; this is a development build, not a packaged release.

# Final assessment

Yes, the working primary flow is meaningfully shorter: search, select, Set inside one app, retaining display/scaling and history. It eliminates switching to a browser, managing a downloaded file in Finder, and opening System Settings. Favorites and collections keep useful discoveries without pre-downloading originals. Network speed is not improved by the workflow itself, and the conditional test gaps above prevent an unconditional release-readiness claim.
