# In-flight Set audit

## Verdict

**Defect fixed.** Image/display/scaling capture and mutation exclusion were already coherent. The missing application-time display-availability check was reproduced before repair. No broader M2 correctness claim or commit.

## Baseline

- Actual HEAD: `48b6714f54c76829a75486db6a90cf916bd85967` — the accepted checkpoint, with no later commits.
- Initial tracked diff: empty (`git diff --stat`). Pre-existing untracked `.agents/`, `.verdent/`, and `skills-lock.json` were preserved.
- Read M2_REPORT.md and M2_CLOSURE_REPORT.md; no applicable AGENTS.md was found in the project/target directories or ancestor chain. Reports were checked against source.

## Current operation policy and execution trace

1. `setWallpaper` checks both mutation task slots before accepting work. It synchronously captures the selected local URL or remote reference, `NSScreen`, and scaling. Remote Set captures scaling inside `downloadAndSet`, before its task starts. Local and collection rotation also capture their inputs before starting tasks.
2. Remote `localOriginal` awaits cache lookup, original download on a miss, and cache installation. It updates matching references by identity; it does not reread the selected image or target. Cache protection includes history and the current desktop reported by WallpaperService.
3. Shared `applyWallpaper` reads the current system assignment after original resolution, falling back to persisted assignment only when the system read is unavailable. It then awaits rollback preparation. This preserves the closure policy; it does not promise to capture an external desktop change occurring during that later file-copy interval.
4. Immediately before the synchronous WallpaperService mutation, cancellation is checked. **The repair additionally resolves the captured display using the existing display identifier and the current display list, or throws a recoverable reconnect/retry error.** Undo uses the same check after its asynchronous restore-file validation. No selected-display fallback is used for mutation.
5. Only a successful wallpaper call appends/pops committed history and updates the assignment. Existing selection/scaling persistence behavior is retained. The Set status uses the applied filename and captured display, and includes the existing Undo-unavailable note where appropriate. Unavailable rollback data remains an honest barrier to Undo.
6. State is saved before rollback cleanup; failed saves skip cleanup. Failed/cancelled Set can clean an unused prepared snapshot only after saving unchanged committed history. The task slot remains occupied through cleanup. A cancellation delivered after the wallpaper side effect does not suppress recording or success reporting. Filesystem persistence and the macOS wallpaper change are **not atomic together**.

Navigation cancels search/detail/thumbnail work, with search generation and selection checks preventing obsolete publication. It leaves accepted user Set running. Selecting another image, source, collection, display, or scaling does not retarget that Set. There is no new cancellation UI; pre-application task cancellation follows existing silent handling and does not report success.

Repeated Set is rejected with “Wait for the current download to finish.” Undo and rotation return while either mutation task slot is occupied; Set/Undo controls and menu validation use the same busy condition. Rotation-source/interval changes may cancel a pending rotation, but retain its task slot until completion. There is no accepted supersession queue: an older Set cannot race a newer accepted mutation because the newer request is rejected until the older task finishes.

## Evidence

All names below are methods in `WallpierTests` and execute the production controller, provider, cache and history code with isolated dependencies.

| Scenario | Test | Observed result |
| --- | --- | --- |
| A/B: A on X/Fill, then B and Y/Fit | `testInFlightSetCapturesImageDisplayAndScaling` | Applies A on X/Fill; B remains selected; persisted history, rollback bytes and success status describe A/X/Fill. Passed before repair. |
| C: source/search/collection navigation, obsolete callbacks | `testInFlightNavigationDiscardsObsoleteSearchDetailAndPreview` | Old search/detail/preview completions leave the current collection, B preview, edited query and completed Set status intact. |
| D: competing Set, valid Undo, rotation | `testInFlightSetRejectsCompetingMutationsThenAcceptsNextSet` | All three are rejected during preparation; exact recorded order is A, B, A after later acceptance, with cached A reused. |
| E: failed/cancelled download | `testInFlightPreparationFailureAndCancellationAllowRecovery` | Neither case applies or advances history/assignment; no false success; a subsequent Set succeeds. Cancelled dependency deliberately returns bytes anyway. |
| F: captured display disappears | `testInFlightSetRejectsUnavailableCapturedDisplay` | **Pre-fix failed:** boundary invoked, history committed, no recoverable availability message. **Post-fix passed:** zero wallpaper calls, no history advance, reconnect/retry status. Synthetic-display logic verification only. |
| G: prior captured after download; durable Undo | `testInFlightSetCapturesPriorAtApplicationAndUndoRestoresIt` | Uses changed current assignment rather than download-start assignment; Undo succeeds from preserved bytes after prior source deletion, with correct display/scaling/history/status. |
| G: missing prior image | `testInFlightSetReportsUndoUnavailable` | Set succeeds; history records unavailable rollback; status and disabled Undo agree. |
| Application boundary failure | `testInFlightWallpaperFailureDoesNotCommitAndCleansPreparedRollback` | Records attempted call/failure; current assignment and committed history remain unchanged; unused snapshot is cleaned. |
| Cancellation after mutation | `testInFlightCancellationAfterMutationStillCommitsSuccess` | Recording boundary cancels the task after applying; assignment/history and success status still commit. |
| Same availability gap in Undo | `testInFlightUndoRechecksCapturedDisplayBeforeMutation` | Undo captures X before its async work; removal of X prevents a second wallpaper call and preserves history. |

The first full run found a test setup omission (no selected collection in the injected initial state). Correcting that fixture made the navigation check pass; no navigation production fix was required.

Pre-fix artifacts: [test log](/tmp/wallpier-inflight-prefix.log), [failure details](/tmp/wallpier-inflight-prefix-result.json). The targeted pre-fix run executed two tests: one passed, one failed with three assertions.

## Changes

- [MainWindowController.swift](/Users/parth/Projects/Wallpier/Wallpier/MainWindowController.swift): one shared availability helper used immediately before Set and Undo; dependency initialization before startup; limited internal control/action access and read-only task/state access for actual-controller tests.
- [WallpaperService.swift](/Users/parth/Projects/Wallpier/Wallpier/WallpaperService.swift): remove `final` so the test boundary can override both desktop reads and writes. Live API implementation unchanged.
- [RemoteThumbnailProvider.swift](/Users/parth/Projects/Wallpier/Wallpier/RemoteThumbnailProvider.swift): remove `final` to inject captured preview callbacks without networking. Live thumbnail implementation unchanged.
- [WallpierTests.swift](/Users/parth/Projects/Wallpier/WallpierTests/WallpierTests.swift): ten focused tests, generated fixtures, synthetic screens, recording wallpaper boundary and explicitly released async dependencies. No parallel Set implementation or added dependency.
- This report: baseline, execution trace, reproducer and verification evidence.

## Verification

**41/41 focused tests passed** (31 existing + 10 new), zero failures and zero compiler warnings. [Log](/tmp/wallpier-inflight-tests.log), [result metrics](/tmp/wallpier-inflight-final-result.json), [xcresult](/tmp/wallpier-inflight-audit-dd/Logs/Test/Test-Wallpier-2026.09.05_19-20-00-+0530.xcresult).

Clean Debug build: **PASS**. [Log](/tmp/wallpier-inflight-debug-build.log).

Universal build: **PASS**, `lipo -archs` confirms `x86_64 arm64`. [Log](/tmp/wallpier-inflight-universal-build.log). Both builds have zero compiler warnings. Xcode 15.2 (15C500b); deployment target remains macOS 12.0. `git diff --check` passed; final changes are confined to the four files above and this report.

Exact final commands:

```sh
xcodebuild -project Wallpier.xcodeproj -scheme Wallpier -configuration Debug \
  -derivedDataPath /tmp/wallpier-inflight-audit-dd \
  -destination 'platform=macOS,arch=x86_64' -only-testing:WallpierTests test
xcodebuild -project Wallpier.xcodeproj -scheme Wallpier -configuration Debug \
  -derivedDataPath /tmp/wallpier-inflight-audit-dd clean build
xcodebuild -project Wallpier.xcodeproj -scheme Wallpier -configuration Debug \
  -derivedDataPath /tmp/wallpier-inflight-audit-dd \
  -destination 'generic/platform=macOS' ONLY_ACTIVE_ARCH=NO ARCHS='x86_64 arm64' build
lipo -archs /tmp/wallpier-inflight-audit-dd/Build/Products/Debug/Wallpier.app/Contents/MacOS/Wallpier
```

Isolation: AppDelegate's existing XCTest guard was inspected before hosted tests ran; it returns before controller construction, state restoration, timers, or discovery. New tests use a nil-window controller with all dependencies supplied before any actions. Both WallpaperService methods are overridden; no real desktop reads or writes occur in these tests. Download/search/detail use the injected NetworkClient; thumbnail requests are intercepted. State, originals, rollback and generated prior images use unique temporary directories, removed after cancelling/draining owned tasks. Continuations determine completion order, with bounded XCTest expectations and five-second dependency failure deadlines; no race-creating sleeps. No app launched for manual use, live Wallhaven requests, physical display changes, Space switching, device sleep, permission changes, or access to user Wallpier storage. No harness configuration was changed.

## Limitations and next action

This verifies controller logic on Intel, not physical unplug behavior or actual macOS wallpaper rendering. It does not establish visual scaling, Spaces, sleep/wake, macOS 12 runtime behavior, or Apple Silicon runtime behavior. Availability uses the existing identity scheme; a physical removal after the synchronous check is still handled by the existing wallpaper-call error path, not an atomic display reservation. The tests do not separately suspend local-file rollback copying or run a real elapsed rotation timer; the shared application path and rotation rejection are covered. Preview callback tests verify controller selection guards, not the thumbnail decoder's internal scheduling. No broader UI/accessibility review was performed.

No unresolved product-policy decision. **Ready for focused review.**
