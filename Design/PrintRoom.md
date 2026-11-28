# Wallpier — Final Native Design Specification (Authority Spec)

Opus 5.5 selected the Print Room direction. Gemini 4 Neon leads visual design, copy, and editorial review.

Wallpier uses native Swift and AppKit on macOS 12 and later. The build targets Xcode 15.2 and Swift 5.9 for Intel and Apple Silicon.

The contrast, layout, and performance figures below specify targets for verification on the running app.

---

## 1. Architecture & Surface Map

| Surface | Governing Pattern | AppKit Seam |
| --- | --- | --- |
| **Sidebar** | Neon *Print Room* (Library top, 3 source groups) | Existing `NSSplitViewController` + `SidebarController` (`NSOutlineView`) |
| **Gallery (Discover, Favorites, Collections, Folder, Artist grid)** | Fixed-cell `NSCollectionViewFlowLayout`, uncropped `aspectFit` prints on shared baseline + 2-line placard | `GalleryViews.swift` + `WallpaperCollectionViewItem.swift` |
| **Artist Header** | Astra's truthful wording inside Neon's content header; toolbar shows provider only | Header container in `MainWindowController` |
| **Desktop Preview** | Astra's single stacked layout (no right-hand info column) with Neon's colors & type | `PreviewViews.swift` (`DesktopPreviewView`, `ViewerView`) |
| **Gallery Dock** | Neon's direct-Set dock (`Display`, `Scaling`, `Set Wallpaper` always visible) | Apply dock view in `MainWindowController` |
| **Secondary Surfaces & Icon** | Neon's archival surfaces, New York + SF Pro type, original *Framed Horizon* icon | Popovers, Help sheet, About panel, `AppIcon.appiconset` |

**Hard Preservation Boundaries:** No new persisted keys or `WallpaperState` schema changes; no new media fetches on selection; keep existing thumbnail/preview cancellation and 300 ms detail dwell; preserve all 9 provider policies, browse-only restrictions, exact keyboard shortcuts, menus, drag/drop, rotation, and durable Set/Undo.

---

## 2. Semantic Color Tokens (Light, Dark & High Contrast)

**Primary Button Contrast Correction:** `#D45B3B` (measured 3.92:1 with white) is retired. Both appearances use **`#C24B2C`** (independently measured **4.84:1** with `#FFFFFF`) for the primary `Set Wallpaper` button fill.

| Token (`NSColor` Asset / Dynamic) | Light (*Archival Paper*) | Dark (*Darkroom Obsidian*) | Increased Contrast Override | Role |
| --- | --- | --- | --- | --- |
| `canvasBackground` | `#F6F4EF` | `#161615` | `#FAF9F5` / `#0F0F0E` | Gallery & content ground |
| `stageBackdrop` | `#ECE9E2` | `#111110` | `#E4E0D6` / `#0B0B0A` | Desktop Preview surround |
| `sidebarOpaqueFallback` | `#EFECE5` | `#1D1D1B` | `#E8E4DA` / `#181816` | Sidebar under Reduce Transparency |
| `surfaceElevated` | `#FFFFFF` | `#242422` | `#FFFFFF` / `#2A2A27` | Controls, popovers, search field |
| `surfaceHover` | `#E7E3DA` | `#2E2D2A` | `#DDD8CC` / `#383632` | Row & control hover fill |
| `dockBackground` | `#F2EFE9` | `#1B1B19` | `#ECE8DF` / `#161614` | Gallery dock & Preview control bar |
| `inkPrimary` | `#1C1917` | `#F2EFE9` | `#000000` / `#FFFFFF` | Titles, active labels |
| `inkSecondary` | `#57534E` | `#A8A29E` | `#3B3834` / `#D4D0CA` | Captions, metadata, credits |
| `inkTertiary` | `#756E68` | `#8E8882` | `#524D48` / `#B5B0A8` | Group headers, inactive icons |
| `hairline` | `rgba(28,25,23,0.11)` | `rgba(255,252,245,0.11)` | `rgba(28,25,23,0.32)` / `rgba(255,252,245,0.32)` | Dividers, control borders |
| `printHairline` | `rgba(28,25,23,0.10)` | `rgba(255,252,245,0.12)` | `rgba(28,25,23,0.28)` / `rgba(255,252,245,0.28)` | `1px` hairline on actual artwork rect |
| `accentPrimaryFill` | `#C24B2C` | `#C24B2C` | `#A63A1E` / `#B84224` | `Set Wallpaper` button normal fill (`#FFFFFF` text) |
| `accentPrimaryHover` | `#AE4124` | `#AE4124` | `#913118` / `#A3381D` | Primary button hover |
| `accentPrimaryPressed` | `#97361C` | `#97361C` | `#7D2812` / `#8C2E16` | Primary button pressed |
| `accentForeground` | `#B03F22` | `#EB7A5C` | `#993318` / `#FF9478` | Links, active selection ring, active icons |
| `accentSoftFill` | `rgba(194,75,44,0.11)` | `rgba(235,122,92,0.16)` | `rgba(176,63,34,0.16)` / `rgba(255,148,120,0.22)` | Active sidebar row tint |
| `statusError` | `#B91C1C` | `#F87171` | `#991B1B` / `#FCA5A5` | Error status & notices |
| `desktopMat` | `#1A1A19` | `#1A1A19` | `#141413` | Display screen backing inside Preview frame |
| `stageRim` | `rgba(28,25,23,0.22)` | `rgba(255,252,245,0.36)` | `rgba(28,25,23,0.50)` / `rgba(255,252,245,0.60)` | `1px` display bezel edge |

*Fallback:* If custom button tinting misbehaves on macOS 12 `NSButton`, fall back to standard native `.controlAccentColor` primary button while retaining the archival surface and typography tokens.

---

## 3. Typography & International Text

Use **New York** via `NSFontDescriptor.preferredFontDescriptor(forTextStyle:).withDesign(.serif)` (falling back to system serif if unavailable; SF Pro automatically handles CJK/unsupported scripts via CoreText). Never hardcode pixel heights that clip tall diacritics.

| Role | Font | Size | Weight | Tracking / Features | Usage |
| --- | --- | --- | --- | --- | --- |
| **Artist / Empty Title** | New York (serif) | `22 pt` | Semibold | `-0.02 em` | Artist header name, About wordmark |
| **Preview Title** | New York (serif) | `18 pt` (`16 pt` narrow) | Medium | `-0.015 em`, wraps (0 lines max) | Desktop Preview artwork title (selectable) |
| **Toolbar / Popover** | SF Pro Text | `13 pt` | Semibold | `-0.005 em` | Window title, Popover heading, Dialog title |
| **Control / Sidebar** | SF Pro Text | `12.5–13 pt` | Regular / Medium | `0` | Sidebar rows (`12.5 pt`), buttons (`13 pt`), popups |
| **Placard Line 1** | SF Pro Text | `12 pt` | Medium | `0`, 1 line tail-truncate | Gallery cell title (`allowsExpansionToolTips = true`) |
| **Placard Line 2 / Meta** | SF Pro Text | `11 pt` | Regular | `monospacedDigitSystemFont` | Maker · date / source, counts, pager, dimensions |

---

## 4. Exact Layout & Component Specifications

### 4.1 Window & Constraint Hygiene (Zero Warnings)
- **Window sizes:** Default `1320 × 820`, minimum `820 × 540`. `window.styleMask.insert(.fullSizeContentView)`, `window.toolbarStyle = .unified`.
- **Zero Auto Layout Warnings Rule:** Never collapse `scopeBar`, `discoverBar`, `localBar`, or `creatorBar` with a `heightAnchor == 0` constraint while inner stack views hold required top/bottom `edgeInsets`. Use an `NSStackView` with `detachesHiddenViews = true` (or remove/add the active header subview cleanly) so hidden bars contribute zero competing constraints.

### 4.2 Sidebar (`SidebarController`)
- **Width:** Default **`232 pt`** (min `196 pt`, max `280 pt`, collapsible via `⌃⌘S`; never auto-collapses).
- **Row metrics:** `26 pt` row height, `10 pt` horizontal inset, `15 pt` SF Symbol (`inkTertiary` at rest; `accentForeground` when selected; `alternateSelectedControlTextColor` if system emphasized), `7 pt` icon-to-label gap, `6 pt` corner radius on selection pill (`accentSoftFill`).
- **Exact Group Order (all groups start expanded; no new persisted disclosure key):**
  1. **Library:** `Favorites` (`heart`, tabular count), `Folder` (`folder`, path tooltip, rotation glyph if rotating)
  2. **Collections:** Header includes trailing `+` (`plus`, `18 × 18 pt`, tooltip `New Collection (⇧⌘N)`); rows use `rectangle.stack`, name, rotation glyph if active, tabular count. Drop target for `.wallpierReference` preserved.
  3. **Museums & Archives:** `Cleveland Museum of Art` (`building.columns`), `The Met` (`building.columns`), `Wellcome Collection` (`book.closed`)
  4. **Photography & Space:** `Openverse` (`camera.aperture`), `iNaturalist` (`leaf`), `NASA Images` (`sparkles`)
  5. **Wallpapers & Digital:** `Wallhaven` (`photo.on.rectangle.angled`), `KDE Plasma` (`macwindow`), `Pepper&Carrot` (`paintbrush.pointed`)
- **Narrow width:** At `196 pt`, `allowsExpansionToolTips = true` reveals full names; `View ▸ Discover Sources` lists all 9 in full under the same 3 groups.

### 4.3 Contact Sheet Grid (`GalleryLayout` & `WallpaperCollectionViewItem`)
- **Fixed-Cell Geometry (No aspect-dependent relayout, preserves exact provider order):**
  - `colGap = 16 pt`, `rowGap = 20 pt`, `minOuterMargin = 20 pt`, `topInset = 16 pt`, `bottomInset = 24 pt`.
  - `GalleryThumbnailSize` targets (image well uses **4:3** aspect `height = floor(width * 0.75)`):
    - Index `0` (Compact): `targetWellWidth = 176 pt`
    - Index `1` (Standard, default): `targetWellWidth = 232 pt`
    - Index `2` (Large): `targetWellWidth = 304 pt`
  - **Column & Cell Formula:**
    - `usable = max(1, contentWidth - 2 * minOuterMargin)`
    - `columns = max(1, Int(floor((usable + colGap) / (targetWellWidth + colGap))))` (minimum 2 columns at `820 pt` when `targetWellWidth ≤ 232 pt`)
    - `cellWidth = floor((usable - CGFloat(columns - 1) * colGap) / CGFloat(columns))`
    - `extra = max(0, usable - (cellWidth * CGFloat(columns) + CGFloat(columns - 1) * colGap))`
    - `sectionInset.left = minOuterMargin + floor(extra / 2)`, `sectionInset.right = minOuterMargin + ceil(extra / 2)`
    - `wellWidth = cellWidth - 2 * ringInset` (`ringInset = 5 pt`)
    - `wellHeight = floor(wellWidth * 0.75)`
    - `placardHeight = 38 pt` (`6 pt` gap + `16 pt` line 1 + `2 pt` gap + `14 pt` line 2)
    - `cellHeight = wellHeight + 2 * ringInset + placardHeight`
- **Original Print Framing inside Well:**
  - Image drawn **uncropped (`aspectFit`)**, **aligned to the bottom baseline of the well** (`y = well.minY` in non-flipped coordinates; horizontally centered). **No mat box, no drop shadow.**
  - Crisp `2 pt` corner radius and `1px` (`1 / backingScaleFactor`) `printHairline` stroke drawn on the **fitted image rect** itself.
  - **Selection Ring:** `2 pt` stroke around the cell's well outer rect (`ringInset = 5 pt`, `cornerRadius = 5 pt`, `3 pt` breathing gap from well edge). `accentForeground` when gallery is first responder in key window; `secondaryLabelColor` when unfocused. Updates immediately (`CATransaction.setDisableActions(true)`).
- **2-Line Placard (below well, `paddingHorizontal = 5 pt`):**
  - Line 1: `item.title` (`12 pt` Medium, `inkPrimary`, 1 line, tail-truncate, expansion tooltip).
  - Line 2 (`11 pt` Regular, `inkSecondary`, 1 line, tail-truncate):
    - Single-provider Discover / Artist: `[Maker] · [Date]` (omitting missing fields; never orphaned `·`).
    - Favorites / Mixed Collections: `[Maker] · [Source]`.
    - Local Folder: `[EXT] · [Dimensions if known]`.
    - Browse-only works: append `· Browse only` (never triggers a fetch; double-click opens source page). Missing-image cells show a quiet `20 pt` `photo` SF Symbol (`inkTertiary`) centered in the well with title and creator preserved below.

### 4.4 Artist View Header
- **Toolbar:** Displays active provider name (e.g., `Cleveland Museum of Art`), never duplicates artist name.
- **Content Header (`padding: 12 pt 20 pt`, bottom `1px` `hairline`):**
  - Row 1: `‹ Back to “Hokusai”` (or `‹ Back to Favorites` / `‹ Back to “[Collection]”`, small native button, `Esc`) on left; clickable link to starting work by its real title (`View “[Starting Work Title]” on [Provider] ↗`, tail-truncated with full tooltip) on right.
  - Row 2: Creator name in New York Semibold `22 pt` (`Katsushika Hokusai`) + truthful count (`8 works shown` when 8 related works are displayed with anchor omitted, or `Showing X works from the first Y of Z matches` when provider reports a larger total). Never invent bios, portraits, or catalogue totals.

### 4.5 Desktop Preview (Astra's Single Stacked Layout)
One layout at all window sizes (no right-hand info column):
1. **Stage Area (`flex: 1`, background `stageBackdrop`, `padding: 16 pt 24 pt 10 pt`):**
   - Centered `DesktopPreviewView` sized to the selected `NSScreen` real aspect ratio, `6 pt` corner radius, `desktopMat` fill, `1px` `stageRim` stroke. Preserves existing Fit/Fill/Center geometry (Fit default for new profiles).
2. **Caption Band (`padding: 10 pt 24 pt 12 pt`, background `canvasBackground`, top `1px` `hairline`):**
   - **Row 1 (Title + Pager):** New York Medium `18 pt` title (`16 pt` at `height ≤ 580 pt`, wraps cleanly, selectable) on left; Pager (`‹` `[1 of 6 loaded]` `›`, tabular `11.5 pt`, `←`/`→`, `⌘[`/`⌘]`) on right.
   - **Row 2 (Attribution):** Selectable `12 pt` line: `[Role-accurate Credit] · [Date] · [Source Name ↗] · [Exact License]`. Openverse adds its mandatory acknowledgement line (`11 pt`, `inkSecondary`).
   - **Row 3 (Optional Details + Fidelity Notice, max height `44 pt`, vertically scrollable if long):** Dimensions/orientation + credit line (`900 × 617 · Landscape · Bequest of Edward L. Whittemore`) and, when `stageFidelity < .original`, `[photo icon] Low-resolution preview; detail may differ. Set Wallpaper downloads the full original.`
3. **Control Row (`52 pt` height, background `dockBackground`, top `1px` `hairline`, `padding: 0 16 pt`):**
   - Left: `Favorite` (`♡` / `♥`, `⌘D`), `Collection` / `⋯` menu, `Focus` toggle (`View ▸ Hide Preview Controls`; hides Caption Band + Control Row, `Esc` restores controls).
   - Right: Explicit text label **`Display`** + `[Studio Display ▾]`, explicit text label **`Scaling`** + `[Fit to Screen ▾]`, primary **`Set Wallpaper`** (`Return`).

### 4.6 Gallery Dock (Direct-Set Bar)
- **Height:** `52 pt`, `dockBackground`, top `1px` `hairline`, `padding: 0 16 pt`.
- **Left (`min-width: 100 pt`, flexible):** Optional small spinning indicator + Selected Title (`13 pt` Medium, `inkPrimary`, tail-truncate + tooltip) over subtle status/meta line (`11 pt` `inkSecondary`: shows transient status + inline `Undo` link after Set, or dimensions · source · license when idle).
- **Right (`flex-shrink: 0`):** `More by [Creator]` (only when provider resolver supports it), `♡` Favorite, `⋯` Actions, `1px` vertical hairline, `Display ▾`, `Scaling ▾`, `Set Wallpaper`.
- **Minimum Window (`820 × 540`) No-Clipping Rules:**
  1. `More by [Creator]` detaches first (`NSStackView.VisibilityPriority.detachOnlyIfNecessary`; stays in `⋯` and `Wallpaper ▸ More by Creator`).
  2. Title truncates with expansion tooltip (never below `100 pt`).
  3. `Display ▾` (`116–180 pt`), `Scaling ▾` (`96–130 pt`), and `Set Wallpaper` (`min 112 pt`) are **never hidden or clipped**.

---

## 5. Control States, Motion & Accessibility

- **8 Control States:**
  - *Normal:* Semantic surface + `1px` `hairline` (`accentPrimaryFill` on primary CTA).
  - *Hover:* `surfaceHover` (`accentPrimaryHover` on primary).
  - *Pressed:* `surfaceActive` (`accentPrimaryPressed` on primary), immediate on pointer-down.
  - *Focused:* Native macOS keyboard focus ring (`focusRingType = .default`), never suppressed.
  - *Selected:* `accentSoftFill` + `accentForeground` icon/ring (neutral gray ring when gallery loses focus).
  - *Disabled:* `0.45` alpha + explanatory tooltip for consequential restrictions (e.g., browse-only or unconfirmed license).
  - *Busy:* Inline `NSProgressIndicator` (small) in dock or centered in empty state; mutating buttons disabled until complete.
  - *Error:* `statusError` text + icon + recovery action (`Try Again` or `Review Original Source`).
- **Motion:** Zero animation on arrow keys, selection rings, `⌘D`, or gallery scroll. Only Gallery ↔ Preview cross-fade (`160 ms` opacity, `cubic-bezier(0.23, 1, 0.32, 1)`) and native popover presentation. Under `accessibilityDisplayShouldReduceMotion`, all transitions become instant.
- **Accessibility:** Full keyboard traversal (`Tab`, arrows, `Space`, `Return`, `Esc`, `⌘1`–`⌘4`, `⌘Y`, `⌘D`, `⌘F`, `⌃⌘S`). No state carried by color alone (paired with filled/outline icons or text). VoiceOver labels on every cell (`Title, Maker, Source, License`), verb-first icon buttons (`Add to Favorites`), and stage (`Desktop preview of [Title], [Scaling] on [Display]`).

---

## 6. Copy Truthfulness, Secondary Surfaces & Failure States

- **Attribution & Role Rules (Astra's Contract):** Show only provider-reported roles and credits (`by Name` except qualified attributions like `after …` or `workshop of …` shown verbatim). Never promote an uploader or institution into an "artist". Never fabricate counts, bios, portraits, or unverified licenses.
- **Favorites & Mixed Collections:** Same Contact Sheet with Line 2 as `Maker · Source`. Empty Favorites: `No Favorites Yet` / `Click the heart or press ⌘D on any work to keep it here.` + `[Browse Discover]`. Empty Collection: `“[Name]” Is Empty` / `Drag works onto this collection in the sidebar, or choose Add to Collection.` Delete Collection alert names the collection and item count (`Delete “Evening Light”?`, `This removes the collection of 5 works. Your saved originals are not deleted.`, `[Delete Collection]` / `[Cancel]`).
- **Local Folder:** Scope strip shows tilde-abbreviated selectable path (middle-truncated, full-path tooltip) + `Change Folder…` (`⌘O`).
- **Automatic Rotation Popover (`⌥⌘R`):** Native `NSPopover` anchored to toolbar rotation button; aligned 2-column form (`Change wallpaper`, `Choose from`, `Shuffle`), live plain-language summary, and active vermilion dot + tooltip on toolbar button when running.
- **Help (`⇧⌘?`):** Clean native Help sheet/window with 4 scannable sections (Discover & Sources, Artist Exploration, Desktop Preview & Fit, Library & Rotation) and a compact shortcut table.
- **About Wallpier:** Native About panel with *Framed Horizon* icon, New York wordmark, real bundle version, and truthful source acknowledgements (including Openverse non-endorsement).
- **Failure States (Calm, Specific, Recoverable):**
  - *Offline:* `wifi.exclamationmark` · `You’re Offline` · `Check your connection and try again.` · `[Try Again]`
  - *API / Timeout:* `exclamationmark.triangle` · `Couldn’t Reach [Provider]` · Specific error · `[Try Again]`
  - *Rate Limit:* Non-blocking dock status (keeps loaded works usable) + retry timing only when provider supplies it.
  - *Zero Results:* `magnifyingglass` · `No Results for “[Query]”` · Truthful provider scope note (+ `[Load More]` for Openverse/catalogs when unloaded pages remain).
  - *Openverse Unconfirmed License:* `Set Wallpaper` disabled; `[Review Original Source]` shown.

---

## 7. App Icon & Asset Provenance

- **Original Icon (*The Framed Horizon*):** Programmatically generated vector artwork (100% original, zero third-party or AI-generated assets), delivered as `AppIcon.appiconset` covering `16, 32, 128, 256, 512 pt` at `@1x` and `@2x` (`16×16` through `1024×1024 px`).
  - **Geometry:** Standard macOS Big Sur/Monterey squircle in anodized darkroom obsidian (`#1D1C1A`) with subtle top rim highlight, framing an archival warm-paper mat (`#F4F0E6`), an inner slate-indigo stepped mountain horizon (`#2F3E4E`), and a **Hanko Vermilion** circular seal (`#C24B2C`). At `16×16 px`, simplifies to the obsidian frame, cream aperture, single horizon peak, and vermilion dot for crisp Dock/Finder legibility.
- **Monochrome Brand Mark:** Single-color template PDF/SVG vector of the framed-horizon glyph for About and empty states.
- **UI Icons:** Native Monterey-compatible SF Symbols only (`14–15 pt`), with labeled fallbacks where needed.
