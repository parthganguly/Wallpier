# M2 CLOSURE RESULT

PASS for the requested Undo/history closure. No M3 work, redesign, new product features, or commit. This report supersedes the Undo limitation and test/build counts in the earlier M2 product report; the prior physical macOS unknowns remain separate.

# Undo failure root cause

The final failed history entry used the persisted `DisplayAssignment.imagePath` `/private/tmp/wallpier_test_a.jpg`. Before this closure, `applyWallpaper` preferred persisted state over a fresh system assignment, appended that path without validating or preserving it, and enabled Undo solely because history was nonempty. The Undo handler discovered the missing file only when invoked. No rollback bytes existed.

Evidence and attribution:

- **Previously set by Wallpier: yes.** The August 30 M0 QA record contains the command copying a user Pictures JPEG to `/tmp/wallpier_test_a.jpg`, selecting it in Wallpier, and the application's successful Set response (3.8 ms). The same log reports that path as the desktop image.
- **Captured from NSWorkspace?** The path was observed as the OS desktop assignment during M0 QA. The final September 5 failing entry, however, was created from an already-populated persisted assignment, not a fresh NSWorkspace capture. The retained records do not establish the exact first transition into persisted M1/M2 state; it would be inaccurate to invent that provenance.
- **Deleted by Wallpier?** No evidence supports that. Its deletion code was confined to downloaded temporary files and app-owned cache eviction; local Set did not delete external sources.
- **Deleted by QA?** Not established. Reviewed QA records show creation of this fixture, successful earlier restoration, and later absence. The recorded cleanup removed a different remote cached original and an empty coverage artifact, not this JPEG. There is no retained deletion event identifying the actor. Temporary-directory cleanup is plausible, not proven.
- **Inside Wallpier's cache?** No. `/tmp` aliases `/private/tmp` here; this was an external QA fixture, not a remote original under `Library/Caches/Wallpier/Originals`.
- **Ordinary-user analogue?** Yes: a wallpaper in Downloads, a temporary directory, a moved/deleted folder, a disconnected volume, or an unavailable cloud file can disappear after Set. The QA origin explains this incident without making it a macOS wallpaper-API defect.

Forensic records inspected: the Wallpier-specific Verdent session `df470417-e797-486d-9ff0-6ff07590ffa3` and this Codex task's retained execution log. The original copy recipe points to `/Users/parth/Pictures/illustrative walls/d6gexce-cc08696e-1abb-4429-ac86-69804c87e23e.jpg`, which still exists. That provenance is not proof that the vanished fixture's final bytes remained identical. Neither that user file nor the old `/tmp` path was modified or reapplied.

# Policy chosen

Before a genuine replacement, read the current wallpaper through WallpaperService, falling back to persisted assignment only when the public system read yields none.

For a readable, valid external previous image, WallpaperHistoryStore makes a byte-preserving rollback snapshot under `/Users/parth/Library/Application Support/Wallpier/Rollback`. This is application-support storage rather than purgeable remote-cache storage. File work runs on its actor, off the UI actor. SHA-256 content-addressed filenames reuse identical snapshots; changed content uses a new path, and damaged existing snapshots recover at a UUID-suffixed path. Copy verification detects a source changing during the copy. Symlinks to external files are copied as target bytes, not fragile links.

Already-owned remote originals and rollback files are referenced directly, without another copy. Undo stores an optional restore-path override while retaining the original `previous` assignment for historical provenance. Remote-cache protection includes history paths and actual current desktop paths, not only potentially stale persisted assignments.

History stays at **20 entries**, including on decoding older state. Rollback storage has a separate internal **250 MiB logical-byte limit**. If a new snapshot cannot fit, the requested wallpaper change proceeds with Undo explicitly unavailable; no protected snapshot is evicted to make a false promise. Snapshot counts follow retained history, with additional files retained only while current assignments, other history entries, favorites, collections, or current desktop protection still reference them. Content deduplication avoids copying identical prior bytes on every operation.

Cleanup removes only unreferenced `rollback-*` regular files in the dedicated rollback directory. It runs after successful state persistence following Set/Undo, including cleanup of a prepared snapshot after a failed/cancelled Set. A failed state write skips cleanup so older persisted references are not invalidated. Files released by other reference changes become eligible at the next cleanup; no generic reference-counting framework or background sweeper was added.

Missing/corrupt prior files and copy/space failures produce an explicit optional `undoUnavailableReason`. A degraded newest entry blocks Undo rather than silently jumping over that change into older history. If no previous assignment is known at all, older Undo history is cleared rather than misrepresented as undoing the new change. Concise Set status says “Undo unavailable for this change.” Technical details go to Logger.

Undo availability is validated on startup, window activation, and history changes; the command also checks file readability and revalidates image data before any desktop mutation. Missing/corrupt restore data cannot crash or invoke a knowingly invalid Set. Both button and menu use the same availability condition. External deletion after a validation can still occur; the action-time check handles that race safely.

No full-resolution decoding, re-encoding, database, generalized asset manager, or changes to scaling behavior were added. This is the smallest durable file-based extension to the existing bounded history. The project Mac-app skill guided honest command availability and keeping file work off the UI actor, not a redesign.

# Files changed

Closure-only changes, in addition to the preserved M2 working tree:

- `Wallpier/WallpaperHistoryStore.swift` — new bounded rollback actor, validation, deduplication and cleanup.
- `Wallpier/MainWindowController.swift` — preparation before shared local/remote/rotation Set; current-system preference; validated Undo; cleanup and task serialization.
- `Wallpier/WallpaperModels.swift` — optional rollback/unavailability fields, protected paths, decoded history bound.
- `Wallpier/WallpaperStateStore.swift` — success result from atomic save, allowing safe cleanup gating.
- `Wallpier.xcodeproj/project.pbxproj` — source membership for WallpaperHistoryStore.
- `WallpierTests/WallpierTests.swift` — 11 new closure tests and configurable tiny-image fixture dimensions.
- `M2_CLOSURE_REPORT.md` — this report.
- `M2_REPORT.md` — points to this superseding closure report.

WallpaperService, provider networking, remote-cache implementation, search filters, thumbnails, collection behavior and layout are otherwise unchanged by this closure. Existing untracked skill/development files were preserved.

# Tests

**31/31 focused tests passed**: the existing 20 M2 tests plus 11 closure tests:

1. External prior image survives original deletion and persisted-state reload.
2. Owned remote original is not copied and remains protected from remote eviction.
3. Identical rollback bytes deduplicate; changed bytes do not overwrite; owned rollback reuse does not copy again.
4. Cleanup follows 20-entry history plus current assignment/favorite/collection references.
5. Missing previous image persists a safe unavailable-Undo barrier.
6. Corrupt/missing rollback is rejected; corrupt snapshot recovery uses a different path.
7. Rollback capacity failure returns degraded history without preventing recording the requested change.
8. Legacy history without new fields decodes and round-trips.
9. State-save failure is reported for cleanup gating.
10. External symlink is snapshotted as durable bytes.
11. Decoded oversized history is bounded to 20.

The first expanded test run exposed duplicate bytes in color-only tiny fixtures, so their dimensions were made distinct. The final full suite passed. All tests use generated files in unique temporary directories and injected networking; no live NSWorkspace mutation or live Wallhaven dependency was added. Temporary test directories are removed by test teardown.

Command:

```sh
xcodebuild -project Wallpier.xcodeproj -scheme Wallpier -configuration Debug \
  -destination 'platform=macOS,arch=x86_64' -only-testing:WallpierTests test
```

Log: `/tmp/wallpier-m2-closure-tests.log`.

# Build

Final build results are recorded after the focused suite using:

```sh
xcodebuild -project Wallpier.xcodeproj -scheme Wallpier -configuration Debug clean build
xcodebuild -project Wallpier.xcodeproj -scheme Wallpier -configuration Debug \
  -destination 'generic/platform=macOS' ONLY_ACTIVE_ARCH=NO ARCHS='x86_64 arm64' build
```

Debug: PASS — clean build succeeded.
Universal: PASS — build succeeded; `lipo -archs` confirmed `x86_64 arm64`.
Warnings: zero compiler warnings in final focused tests, clean Debug build, and universal build.
Deployment target: macOS 12.0; sandbox remains disabled; native Apple frameworks only.

Logs: `/tmp/wallpier-m2-closure-debug-build.log`, `/tmp/wallpier-m2-closure-universal-build.log`.

# Regression audit

Search → preview → selected-original download → shared Set remains architecturally intact. The only insertion is prior-image preparation immediately before the existing WallpaperService call. Local, remote and collection rotation all use that same path; Set/Undo/rotation operations remain serialized while preservation runs. No eager original downloads were added. Only WallpaperService calls NSWorkspace desktop-image APIs. Public system reads for current/protected assignments also go through that service.

The existing 20 M2 tests still pass. No discovery redesign, new provider, M3 feature, third-party runtime dependency, or speculative macOS workaround appeared. No new live wallpaper mutation was performed in this closure pass.

# Remaining M0 unknowns

- Fill/Fit/Center visible OS behavior.
- Same-path/new-content refresh.
- Spaces.
- Sleep/wake.
- Physical multi-display behavior.

The current verification wallpaper remains applied. The old `/private/tmp/wallpier_test_a.jpg` cannot be restored through its vanished path; no guessed reconstruction was made. Its currently applied remote replacement and cached original were not removed. Relaunch the rebuilt app to use the new Undo policy; an already-running older process does not gain the fix automatically.

# M2 final gate

READY TO COMMIT for the accepted M2 milestone plus this correctness closure. No commit has been made. This is not a claim that the separate physical M0 behavior or distribution-readiness checks have been completed.
