# Wallpier Release Candidate 1

Base: `ea27eed` plus the uncommitted `design/preview-experience` snapshot (byte-identical, verified with `diff -r`),
on branch `release/rc1` in `/Users/parth/Projects/Wallpier-rc1`. Uncommitted, by request.

## Wallpaper durability

**Before RC1.** Set Wallpaper and rotation pointed the desktop straight at `~/Library/Caches/Wallpier/Originals/…`,
and `WallpaperHistoryStore.prepare` made no rollback copy for a previous wallpaper in that folder. Wallpier's own
LRU eviction protected those files, but macOS may purge `Caches` under storage pressure. A purge leaves the desktop and
the saved assignment pointing at a missing file, and Undo becomes silently unavailable. The undo button still shows as
enabled because it was validated before the purge. `testActiveRemoteWallpaperAndUndoSurviveCachePurge` reproduced all
three against the unfixed code.

**RC1 ownership model.**

| Storage | Holds | Bound |
|---|---|---|
| `Caches/Wallpier/Originals` | Downloaded originals, fetched on demand | 500 MB LRU (unchanged) |
| `Application Support/Wallpier/Rollback` | Only files a saved display assignment or Undo entry references: the copies of set remote originals (same filename) and rollback copies of external wallpapers | 250 MB, history ≤ 20 entries, swept after every committed save |

- `WallpaperHistoryStore.retain(_:)` copies a cached original into owned storage just before it is set. On APFS the
  copy is a clone (measured: a 300 MB copy changed free space by 0), so it uses no extra disk until the cache copy is
  evicted.
- **Retention fails closed (#1).** `retain` returns only a verified owned file, or it throws. It never falls back to
  the purgeable cache file. Budget exhaustion, a directory or file-copy error, an invalid or incomplete copy, and
  cancellation all make Set and rotation fail before the wallpaper boundary is reached. So there is no desktop change,
  no new display assignment and no new history entry. An explicit Set shows "Could Not Set Wallpaper" with the reason
  and says the desktop was not changed. Rotation reports "Automatic rotation failed" and releases its busy guard, so
  a later Set or tick can succeed.
- The copy is written to a uniquely named `.partial-<UUID>` file, checked for size and decodability, and then renamed
  into place. Failure cleanup removes only that partial file. It never removes an existing owned file, a stale file or
  a folder at the destination name, or any other operation's file. A partial file left by a crash is unreferenced, so
  the next committed cleanup sweeps it.
- **Still the same on a retention failure (by design):** the downloaded original stays in the remote cache and the
  wallpaper reference keeps its cache path. A rotation attempt still advances the rotation cursor, so one wallpaper
  that can't be retained isn't retried on every tick.
- A previous wallpaper that is still in Caches (state saved before RC1) gets an owned rollback copy, like any external
  file.
- **Previous-wallpaper policy (unchanged, separate from #1).** If the *previous* wallpaper is missing, or can't be
  copied within the budget, the new change still proceeds. Its history entry is then marked Undo-unavailable
  (`previousFileUnavailable` / `preservationFailed`), and the status reports "Undo unavailable for this change." Only
  the *new* wallpaper must be durably owned.
- Cleanup removes every unreferenced file in the owned folder, not just `rollback-*` files, so set originals don't
  accumulate.
- Favorites, collections, browsing and previews are unchanged. Originals still download only when needed.

**Upgrade note.** Changes made before RC1 stay cache-dependent until the next Set. RC1 doesn't rewrite the desktop at
launch.

## App icon

`Wallpier/Assets.xcassets/AppIcon.appiconset` had slots but no images, so the app shipped with the generic icon.

The new icon is a warm gallery mat holding a 16:10, desktop-shaped aperture. Inside is a quiet dusk landscape whose
near ridge rises in a soft "W". The mat matches the app's native, photo-first gallery. The aperture says "your desktop
picture", and the W is a mark you only notice on a second look. Everything is drawn from vectors at each size by
`Design/make-app-icon.swift`, a design-time script that isn't in any target. At 16 and 32 px the far ridge and inner
shadow are dropped and the frame line is thicker, so the window stays legible. There's no runtime image generation.

## Distribution

`Scripts/package-test-build.sh <out>` builds Universal Release, ad-hoc signs it with the hardened runtime, verifies the
signature, and writes `Wallpier-<version>-<build>-universal-adhoc.zip` with its SHA-256.

Public distribution needs these, all currently missing:

1. Apple Developer Program membership and a **Developer ID Application** certificate in the keychain.
   `security find-identity -v -p codesigning` reports 0 identities on this Mac.
2. Sign with that identity: `CODE_SIGN_IDENTITY="Developer ID Application"`, `DEVELOPMENT_TEAM=<team>`, plus
   `--timestamp`. Release already enables the hardened runtime, and the entitlements file is empty (no exceptions
   needed).
3. Notarize with `xcrun notarytool submit Wallpier.zip --keychain-profile <profile> --wait`, then
   `xcrun stapler staple Wallpier.app` and re-zip the stapled app.
4. Optional: replace the `com.parth.Wallpier` identifier with a reverse-DNS domain you control. Do it before the first
   public build, because macOS keys preferences (window frame) and saved window state to it. Wallpier's own
   `state.json` path doesn't depend on it.
