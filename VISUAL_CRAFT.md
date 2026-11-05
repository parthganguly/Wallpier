# Wallpier visual craft (design/visual-craft)

## Direction

Wallpier is a quiet gallery wall: the wallpapers are the only saturated thing in the window, every
other element is native, neutral and still, and the chrome is precise enough that nothing draws the
eye away from a picture. Restraint, not decoration, is the identity; the one place the app is
deliberately expressive is the desktop preview, which is drawn as an actual display.

## Diagnosis (Phase 1) and changes (Phase 3)

Captured from one offline fixture (`testCaptureVisualCraftScenarios`), same data, sizes and appearance
before and after: `visual-evidence/visual-craft/{before,after}/vc-NN-*-{light,dark}.png`.

| Before | After | Why |
| --- | --- | --- |
| In dark mode the stage's desktop fill sits within 1.09:1 of the backdrop and its 10% separator outline within 1.34:1, so with *Fit* the display's edge disappears (vc-04, vc-05) | A hairline rim drawn just outside the stage: white 42% in dark (4.02:1 against the backdrop, 3.68:1 against the desktop fill; see Corrections), black 16% in light | The preview exists to show how much of the screen a picture covers; that needs the screen's edge |
| Selection ring is accent blue whether or not keys reach the gallery (inactive window, search field or sidebar focused) | Accent while the gallery is first responder in the key window; `secondaryLabelColor` (3.95:1 light, 5.89:1 dark) otherwise; never hidden | The ring now also says where arrow keys and Space go, as Finder and Photos selections do |
| 12 pt gutters against 16 pt margins; ring radius 8 around a 5 pt image (not concentric); pale skies and night scenes bleed into the backdrop | One 16 pt rhythm (gutters = margins); image radius 6, ring 10 (= 6 + 4 inset); a 1 px `separatorColor` hairline on each picture's edge | Each wallpaper reads as its own picture; edges hold on both backdrops; still three columns at the minimum (and a tiled) window width |
| Heart and ⋯ sat after the name and moved with its length (x ≈ 678 for “cr02”, ⋯ at x ≈ 355 for a folder image) | Heart and ⋯ have one fixed place beside Display / Scaling / Set, separated by a 14 pt gap | Item actions never shift while browsing; the apply controls stay one group |
| Captions: tags and sidebar counts at `tertiaryLabelColor` (1.88:1 light, 2.26:1 dark); empty-state titles at secondary; the folder preview repeated a tail-truncated folder path (vc-15) that hid the folder name; portrait/square/ultrawide shapes, cropped by display-shaped thumbnails, were never named | Preview caption text at `captionSecondary` (6.20:1 light, 5.89:1 dark; see Corrections); sidebar counts at secondary (3.95:1 / 5.89:1); empty-state titles at label color; local caption is “540 × 960 · Portrait” + “PNG”; captions and apply bar name Portrait, Square and Ultrawide (never ordinary landscape); truncating labels show expansion tooltips | Legible secondary information; hierarchy in states; the caption describes the picture, and says when the gallery's crop hides its real shape |

Also: the existing 0.18 s gallery ↔ preview crossfade now uses a strong ease-out (0.23, 1, 0.32, 1), so the
new view is mostly present at once. No animation was added.

Rejected after measurement: `underPageBackgroundColor` as a preview matte (`#969696` in light; secondary text on it 2.94:1).
Rejected for this user's environment: 24 pt margins (cost a column at the 820 pt minimum width that a tiling window manager produces).

## Corrections after review (Sol 6.1)

Matched captures: `visual-evidence/visual-craft/corrections/{before,after}/cc-{landscape,portrait,square,ultrawide}-{fill,fit,center}-{light,dark}.png`
(landscape is a 16:9 cached original; the others are low-resolution previews). Pixel diffs between each pair touch only the
rim perimeter (dark) or the caption text rows (light): image composition and fidelity notices are unchanged.

| Measure | Before | After |
| --- | --- | --- |
| Light caption text (metadata, tags, notice), nominal sRGB on `#FFFFFF` | `#808080` 3.95:1 | `#616161` 6.20:1 |
| Light caption, darkest rendered stroke at 1× (antialiased 11–13 pt) | `#929292` 3.11:1 | `#747474` 4.67:1 |
| Dark caption text, nominal on `#1E1E1E` | `#9A9A9A` 5.89:1 | unchanged (system secondary label) |
| Title, nominal light / dark | 14.94:1 / 12.23:1 | unchanged |
| Dark rim, nominal vs backdrop `#1E1E1E` / desktop `#252525` | `#545454` 2.20:1 / 2.01:1 | `#7D7D7D` 4.02:1 / 3.68:1 |
| Dark rim, rendered vs backdrop `#282828` / desktop `#313131` (all Fit and Center letterboxes) | `#676767` 2.61:1 / 2.30:1 | `#8F8F8F` 4.56:1 / 4.02:1 |
| Light rim | `#DEDEDE`; the desktop fill against white (9.67:1 rendered) carries the edge | unchanged |

`captionSecondary` (now `NSColor.secondaryText`, same values) is a named dynamic color: the system secondary label in dark appearances, black at 62% in light
ones (including Increase Contrast, where the system secondary label stays 3.95:1). The caption has no selected state,
and its colors do not change when the window is inactive.

Navigation test: `testBlankGalleryClickKeepsTheVisibleSetTarget` now derives its expectations from the laid-out columns
(two, three and four or more, via window width and thumbnail size) in Favorites and Discover: blank-gutter clicks keep
the Set target, Right stops at a row's end, Down moves one complete row, the apply bar follows, and the ring is accent
only while keys reach the gallery. The old expectation (Right from item 1 selects item 2) is false in a two-column grid.

## Small secondary text in light mode (second review)

One shared dynamic color, `NSColor.secondaryText` (`GalleryViews.swift`): the system secondary label in dark appearances
(renders byte-identically to it), black at 62% in light ones. It replaces the preview-only `captionSecondary` (same values)
and now also covers the apply-bar detail, informational status (initial and runtime styling; errors keep `systemRed`),
the folder path and empty-state explanations. Captures: `visual-evidence/visual-craft/secondary-text/{before,after}/st-*.png`.

| Text (nominal sRGB) | Background | Light before | Light after | Dark (unchanged) |
| --- | --- | --- | --- | --- |
| Apply-bar detail, informational status, folder path | window `#ECECEC` / `#323232` | `#767676` 3.82:1 | `#5A5A5A` 5.87:1 | `#A3A3A3` 5.06:1 |
| Empty-state explanation | content `#FFFFFF` / `#1E1E1E` | `#808080` 3.95:1 | `#616161` 6.20:1 | `#9A9A9A` 5.89:1 |
| Error status (`systemRed`, preserved) | window | 3.00:1 | 3.00:1 | 3.76:1 |

## Visual specification

- **Imagery.** Pictures are the only saturated color. No captions, badges or hover effects in the grid; one hairline edge, radius 6.
- **Surfaces.** Native only: source-list sidebar, unified toolbar, `controlBackgroundColor` behind the gallery and preview, window background in the bars. No gradients, blur, or custom shadows.
- **Type.** System font throughout. Preview title 15 semibold; caption metadata 13 and detail 11, apply-bar detail, status, folder path and empty-state explanations in `secondaryText` (≥ 5:1 in both appearances); counts 11 monospaced digits secondary. Tertiary color is for symbols and placeholders, never for text a person needs.
- **Density.** Sidebar uses the source-list default row size; toolbar is icon-only; filter bar uses small controls, only in Discover.
- **Gallery geometry.** Display-shaped (16:10) cells that divide the width exactly; 4 pt ring inset; 16 pt between pictures and to the edges; three zoom steps (170 / 240 / 330 pt targets).
- **Selection vs focus.** 3 pt ring outside the picture, concentric (radius 10). Accent when the gallery has keyboard focus in the key window, secondary label color otherwise. Immediate, no animation.
- **Apply bar.** Left: selection name (13 medium) and detail (11, digits monospaced), status line beneath. Right, fixed: heart, ⋯, 14 pt gap, Display, Scaling, Set Wallpaper (the window's default button and only accent-filled control).
- **Captions.** Name; “W × H · Shape · by uploader”; tags or file type; fidelity notice when the preview isn't the original. Shape names only for Portrait (< 0.95), Square (0.95–1.05) and Ultrawide (≥ 2:1).
- **Icons.** SF Symbols only; 15 pt in the apply bar, 34 pt light in empty states, 10 pt semibold for the rotation badge; tinted by semantic colors.
- **Motion.** Only state changes move: the gallery ↔ preview crossfade (0.18 s, strong ease-out, skipped with Reduce Motion). Keyboard navigation, selection, zoom and preview browsing are instant.

## Measured vs subjective

Measured: contrast ratios above (WCAG relative luminance, sRGB, macOS 13 semantic colors); gutters,
margins and radii from the layout code; column counts at 820 / 1120 / 1400 pt; fixed position of the
item actions; capture sizes (30 at 1120×720, 4 at 1400×800, 4 at the 820×564 minimum).
Subjective: that 16 pt reads calmer than 12 pt; the rim weights (16% / 24%); the shape-name thresholds;
the ease-out curve.

## break-ui pass

| Case | Result |
| --- | --- |
| Collection named “Long Exposure Studies from Patagonia and Tierra del Fuego” | Sidebar and title truncate at the end; sidebar now shows the full name in an expansion tooltip |
| `IMG_20250914_183022_HDR_portrait_edited_edited.png` | Fits the caption and apply bar at 1120; truncates with an expansion tooltip at the minimum width |
| Uploader `aleksandra.wisniewska-kowalczyk`, six tags | One line each at 1120 (vc-05) |
| Portrait, square, 21:9, 32:9 | Named in captions; preview geometry unchanged |
| Empty favorites, no folder, offline, loading | Titles now lead at label contrast; copy unchanged |
| 820×564 minimum | Three columns, apply bar unclipped (existing test) |
| Discover subtitle at the minimum width | Still truncates “14 of 2,…” (unchanged; wording belongs to Batch 2) |
