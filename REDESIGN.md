# Wallpier interface redesign (design/opus55-overhaul)

## Thesis

Wallpier is a place to look at wallpapers, so the window belongs to the images.
A source-list sidebar replaces the segmented source picker and per-source control rows;
the gallery fills the window edge to edge with display-shaped thumbnails; Space (or a
double-click) swaps the gallery for a single-wallpaper *desktop preview* that renders the
estimate of how the selected display and scaling will show it. Applying never
moves: one quiet bar along the bottom always holds Display, Scaling and the single
accent-colored **Set Wallpaper** button, whatever you are looking at.

## Decisions

| Area | Before | After | Why |
| --- | --- | --- | --- |
| Navigation | Segmented control + a different control row per source | Sidebar: Library (Discover, Folder, Favorites) and each collection as its own row, with counts and a rotation badge | Collections become places, not a popup; switching source never reshuffles controls |
| Browsing | Fixed 184×144 cells with captions, ragged right edge | Adaptive grid of 16:10 aspect-fill thumbnails that always fills the width; ⌘+/⌘− zoom | Imagery dominates; thumbnails approximate *Fill* on a Mac display |
| Inspecting | 210 pt preview in a permanent inspector | Full-window desktop preview (Space / ⌘Y / double-click, ←/→ to browse, Esc to return) | Inspect at a useful size, and *see* Fill / Fit / Center on the chosen display's shape |
| Applying | Display / Scaling / Set at the bottom of the inspector | Bottom apply bar, identical in gallery and preview | The primary action has one permanent home |
| Search | Field + 4 popups + Search button; filters needed a second click | Toolbar search field; Discover-only filter bar; filters apply immediately | Native toolbar search; fewer steps |
| Item actions | Stack of buttons in the inspector | Heart + ⋯ menu in the apply bar, the same menu on right-click, Wallpaper menu | One action model in three discoverable places |
| Rotation | Footer row of controls always on screen | Toolbar button (tinted while active) opening a popover; Wallpaper ▸ Automatic Rotation menu; sidebar badge | Present and visible without dominating browsing |
| Undo | Footer button | Toolbar button + Wallpaper ▸ Undo Wallpaper Change; ⌘Z is text and removal Undo | Standard place; text editing keeps its own commands |
| Status | Footer label | Second line of the apply bar; counts in the window subtitle | Status sits next to the action it reports on |

Retained deliberately: the engine (WallpaperService, Wallhaven provider, caches, history,
rollback, in-flight Set serialization, rotation semantics), every menu command and
shortcut except the obsolete inspector toggle, the default-button Return behaviour, and
sheet alerts for user-initiated failures.

Also fixed, because the live app exposed it: Wallhaven returns an empty page for
`sorting=relevance` without a query (the default state), so first launch showed "No Results".
Empty-query Relevance now asks for this month's toplist (`WallhavenEndpoint.searchURL`).

## Progress record (2026-10-12)

Status: implemented; uncommitted on `design/opus55-overhaul` (worktree `../Wallpier-opus55`).

- Done: sidebar, adaptive gallery, desktop preview, apply bar, toolbar (view mode, rotation
  popover, undo, search), Discover filter bar, folder bar, empty/loading/error states, context
  and ⋯ menus, menu bar command model, drag-to-collect, Delete/⌘⌫ removal, ⌘C copy link,
  thumbnail zoom, transient status line, live-API relevance fix.
- Verified: 49/49 unit tests (`-only-testing:WallpierTests`), Debug build, universal Release
  build (x86_64 + arm64, minos 12.0), fixture captures (light/dark) in
  `visual-evidence/opus55-redesign/{before,after}`, live-app captures in `.../live`.
- Not run: `WallpierUITests` (template tests that launch the real app against real state).
- Main-tree uncommitted rotation tests (on `main`) were not ported; the names they use
  (`scalingPopUp`, `rotationPopUp`, `restoreState()`, `rotationSelectionChanged()`,
  status strings) still exist, but `rotationTimerFactoryForTesting` must be re-added.

Captures: `TEST_RUNNER_WALLPIER_CAPTURE_DIR=<dir> xcodebuild test ... -only-testing:WallpierTests/WallpierTests/testCaptureScenarios`

## Review fixes (2026-10-13, Sol's two P2 findings)

- Return/Enter in the gallery: `GalleryCollectionView` swallowed them, so the default button
  never fired. They are now passed up the responder chain to the window's default-button
  handling (Set Wallpaper, still gated by its enabled state). The search field and preview
  were already correct. Test: `testReturnSetsFromGalleryAndPreviewButSearchesFromSearchField`
  (window `sendEvent` dispatch; fails without the fix).
- (Superseded by Batch 2 below: `thumbs.large` is a 432×243 16:9 crop, not 3:2.) Uncached Wallhaven previews draw the cropped `thumbs.large`; the preview caption now
  says "Approximate preview from a cropped thumbnail…" only in that case. Local files and
  downloaded originals don't show it; nothing is downloaded early. Test:
  `testOnlyCroppedRemotePreviewsAreMarkedApproximateAndNothingIsDownloaded`.

## Batch 2: truthful preview and Discover (2026-10-16)

- Preview source, best first: a validated cached original (ImageIO-downsampled to 1800 px);
  `thumbs.large` for 16:9 originals (it is a 432×243 centre crop, whole only for 16:9); Wallhaven's
  aspect-preserving `thumbs.original` for every other shape; else `thumbs.large`, labelled
  “Cropped thumbnail; framing is approximate…”. Thumbnails are labelled “Low-resolution preview;
  detail may differ.” Older saved references lack `thumbs.original`; the selected one gains it from
  its details. A newer, better image is never replaced by an older or worse one; a Set that caches
  the original refreshes the preview only if that wallpaper is still selected. No original is
  downloaded for previewing. The stage is an estimate, not macOS's own rendering.
- Network: the API and original downloads keep separate backoffs, so a metadata 429 (or an
  exhausted quota) no longer stops Set from downloading an original, while an original 429 is
  still honoured. Details load only for the visible preview, after a 300 ms dwell, once per wallpaper.
- Discover: the subtitle names the request the results came from (“forest” or Top This Month,
  on Wallhaven); edited text or a changed display-derived size shows “Showing …” and Update Results
  (Return does the same); further pages repeat the results' own request. Filters still apply at once.
