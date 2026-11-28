import Foundation

enum ScalingMode: String, Codable, CaseIterable {
    case fill
    case fit
    case center

    var displayName: String {
        switch self {
        case .fill: return "Fill"
        case .fit: return "Fit"
        case .center: return "Center"
        }
    }
}

enum RotationInterval: String, Codable, CaseIterable {
    case off
    case fifteenMinutes
    case oneHour
    case oneDay

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .fifteenMinutes: return "15 minutes"
        case .oneHour: return "1 hour"
        case .oneDay: return "1 day"
        }
    }

    var seconds: TimeInterval? {
        switch self {
        case .off: return nil
        case .fifteenMinutes: return 15 * 60
        case .oneHour: return 60 * 60
        case .oneDay: return 24 * 60 * 60
        }
    }
}

enum LibrarySource: String, Codable, CaseIterable {
    case discover
    case local
    case favorites
    case collections

    var displayName: String {
        switch self {
        case .discover: return "Discover"
        case .local: return "Local"
        case .favorites: return "Favorites"
        case .collections: return "Collections"
        }
    }
}

enum WallhavenCategory: String, Codable, CaseIterable {
    case all = "111"
    case general = "100"
    case anime = "010"
    case people = "001"

    var displayName: String {
        switch self {
        case .all: return "All Categories"
        case .general: return "General"
        case .anime: return "Anime"
        case .people: return "People"
        }
    }
}

enum WallhavenAspectRatio: String, Codable, CaseIterable {
    case any = ""
    case standard = "16x10"
    case widescreen = "16x9"
    case ultrawide = "21x9"

    var displayName: String {
        switch self {
        case .any: return "Any Ratio"
        case .standard: return "16:10"
        case .widescreen: return "16:9"
        case .ultrawide: return "21:9"
        }
    }
}

enum WallhavenSorting: String, Codable, CaseIterable {
    case relevance
    case dateAdded = "date_added"
    case toplist
    case views
    case favorites

    var displayName: String {
        switch self {
        case .relevance: return "Relevance"
        case .dateAdded: return "Newest"
        case .toplist: return "Top This Month"
        case .views: return "Most Viewed"
        case .favorites: return "Most Favorited"
        }
    }
}

struct WallhavenSearchOptions: Codable, Equatable {
    var query = ""
    var category: WallhavenCategory = .all
    var minimumWidth: Int?
    var minimumHeight: Int?
    var usesDisplayMinimum = true
    var aspectRatio: WallhavenAspectRatio = .any
    var sorting: WallhavenSorting = .relevance

    var minimumResolution: String? {
        guard let minimumWidth, let minimumHeight else { return nil }
        return "\(minimumWidth)x\(minimumHeight)"
    }

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Wallhaven returns nothing for relevance without search text, so that request asks for this month's top list.
    var effectiveSorting: WallhavenSorting { trimmedQuery.isEmpty && sorting == .relevance ? .toplist : sorting }

    /// What results for these options are, in a few words: “forest”, or Top This Month.
    var resultsDescription: String { trimmedQuery.isEmpty ? effectiveSorting.displayName : "“\(trimmedQuery)”" }

    private enum CodingKeys: String, CodingKey {
        case query, category, minimumWidth, minimumHeight, usesDisplayMinimum
        case aspectRatio, sorting
    }

    init(
        query: String = "",
        category: WallhavenCategory = .all,
        minimumWidth: Int? = nil,
        minimumHeight: Int? = nil,
        usesDisplayMinimum: Bool = true,
        aspectRatio: WallhavenAspectRatio = .any,
        sorting: WallhavenSorting = .relevance
    ) {
        self.query = query
        self.category = category
        self.minimumWidth = minimumWidth
        self.minimumHeight = minimumHeight
        self.usesDisplayMinimum = usesDisplayMinimum
        self.aspectRatio = aspectRatio
        self.sorting = sorting
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        query = try container.decodeIfPresent(String.self, forKey: .query) ?? ""
        category = try container.decodeIfPresent(WallhavenCategory.self, forKey: .category) ?? .all
        minimumWidth = try container.decodeIfPresent(Int.self, forKey: .minimumWidth)
        minimumHeight = try container.decodeIfPresent(Int.self, forKey: .minimumHeight)
        usesDisplayMinimum = try container.decodeIfPresent(Bool.self, forKey: .usesDisplayMinimum) ?? true
        aspectRatio = try container.decodeIfPresent(WallhavenAspectRatio.self, forKey: .aspectRatio) ?? .any
        sorting = try container.decodeIfPresent(WallhavenSorting.self, forKey: .sorting) ?? .relevance
    }
}

/// The remote sources Discover can search. Raw values are the persisted `providerIdentifier`s.
enum RemoteProviderID: String, Codable, CaseIterable {
    case wallhaven
    case openverse
    case cma
    case plasma, pepper, met, wellcome, inaturalist, nasa

    var isCatalog: Bool {
        switch self {
        case .wallhaven, .openverse, .cma: return false
        default: return true
        }
    }

    var filtersPublishedCatalog: Bool { self == .plasma || self == .pepper }

    var displayName: String {
        switch self {
        case .wallhaven: return "Wallhaven"
        case .openverse: return "Openverse"
        case .cma: return "Cleveland Museum of Art"
        case .plasma: return "KDE Plasma"
        case .pepper: return "Pepper&Carrot"
        case .met: return "The Met"
        case .wellcome: return "Wellcome Collection"
        case .inaturalist: return "iNaturalist"
        case .nasa: return "NASA Images"
        }
    }
}

/// Openverse's own, deliberately narrow filters: wide, large, non-mature Commons JPEGs are fixed;
/// only the public-domain license choice is offered. Nothing here broadens licensing.
enum OpenverseLicenseFilter: String, Codable, CaseIterable {
    case cc0AndPublicDomain = "cc0,pdm"
    case cc0 = "cc0"
    case publicDomainMark = "pdm"

    var displayName: String {
        switch self {
        case .cc0AndPublicDomain: return "CC0 & Public Domain"
        case .cc0: return "CC0 Only"
        case .publicDomainMark: return "Public Domain Mark Only"
        }
    }
}

struct OpenverseSearchOptions: Codable, Equatable {
    var query = ""
    var license: OpenverseLicenseFilter = .cc0AndPublicDomain

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var resultsDescription: String { trimmedQuery.isEmpty ? "Commons Images" : "“\(trimmedQuery)”" }

    private enum CodingKeys: String, CodingKey { case query, license }

    init(query: String = "", license: OpenverseLicenseFilter = .cc0AndPublicDomain) {
        self.query = query
        self.license = license
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        query = (try? container.decodeIfPresent(String.self, forKey: .query)) ?? ""
        license = (try? container.decodeIfPresent(OpenverseLicenseFilter.self, forKey: .license)) ?? .cc0AndPublicDomain
    }
}

struct WallpaperReference: Codable, Equatable, Hashable, Identifiable {
    let providerIdentifier: String
    let wallpaperID: String
    let sourcePageURL: URL
    let originalURL: URL
    let previewURL: URL
    let thumbnailURL: URL
    var width: Int
    var height: Int
    var uploader: String?
    var tags: [String]
    var cachedLocalPath: String?
    /// Wallhaven's `thumbs.original`: small, but in the original's proportions. Absent from older saved references.
    var uncroppedPreviewURL: URL? = nil
    // Openverse attribution, exactly as the index reported it. Absent for Wallhaven and older saved references.
    var title: String? = nil
    /// The underlying source Openverse indexed the work from, e.g. `wikimedia`.
    var sourceName: String? = nil
    /// Reported license code (`cc0` or `pdm`); never substituted when missing.
    var license: String? = nil
    var licenseVersion: String? = nil
    var licenseURL: URL? = nil
    /// The Cleveland Museum of Art's record, as reported. Absent for every other provider and older saved references.
    var cma: CMARecord? = nil
    var catalog: CatalogRecord? = nil

    var id: String { identityKey }
    var identityKey: String { "\(providerIdentifier):\(wallpaperID)" }
    var resolution: String { "\(width)×\(height)" }

    var orientation: String { width == height ? "square" : width > height ? "landscape" : "portrait" }

    /// nil for a provider this build doesn't support: such references are never routed to another provider.
    var provider: RemoteProviderID? { RemoteProviderID(rawValue: providerIdentifier) }
    var providerName: String { provider?.displayName ?? providerIdentifier }
    /// Display-only: Openverse and CMA text is decoded and cleaned each time it is shown, so references saved by
    /// older builds read correctly. The stored `title` stays as the source reported it.
    var displayTitle: String {
        switch provider {
        case .openverse?: return title.map(DisplayText.title) ?? wallpaperID
        case .cma?: return DisplayText.title(title)
        case .wallhaven?, nil: return title ?? wallpaperID
        default: return DisplayText.title(title)
        }
    }
    /// Who made the work, as shown: nil when none was reported. Wallhaven's uploader is shown as reported.
    var displayCreator: String? {
        switch provider {
        case .openverse?: return uploader.map(DisplayText.creator)
        case .cma?: return cmaCreditName
        case .wallhaven?, nil: return uploader
        default: return uploader.map(DisplayText.creator)
        }
    }
    /// Credit phrase for captions: “by Name”, except a credit that already carries its own qualifier
    /// (“after Charles Le Brun”) is shown as reported, never as “by after …”.
    var displayCredit: String? {
        guard let creator = displayCreator else { return nil }
        if provider == .cma { return creator }
        let lowered = creator.lowercased()
        let qualifiers = ["after ", "attributed to ", "circle of ", "follower of ", "workshop of ", "school of ", "manner of ",
                          "studio of ", "style of ", "copy after ", "imitator of ", "probably "]
        if provider != .wallhaven, qualifiers.contains(where: { lowered.hasPrefix($0) }) { return creator }
        return "by \(creator)"
    }
    /// Where the work comes from: Wallhaven itself, or the source Openverse indexed it from.
    var sourceDisplayName: String {
        guard provider == .openverse else { return providerName }
        return sourceName.map { OpenverseURLPolicy.sourceNames[$0] ?? $0 } ?? "the original source"
    }
    /// For Openverse: the reported license code, version and URL agree with a known canonical public-domain deed.
    /// Anything else is browse-only until the original source is reviewed; nothing is filled in.
    var licenseIsConsistent: Bool {
        provider == .openverse && OpenverseURLPolicy.isCanonicalLicenseURL(licenseURL, license: license, version: licenseVersion)
    }
    var useRestriction: RemoteProviderError? {
        switch provider {
        case .openverse?:
            if OpenverseURLPolicy.isThumbnailOnly(originalURL, source: sourceName) { return .originalUnavailable }
            return licenseIsConsistent ? nil : .licenseNeedsReview
        case .wallhaven?: return nil
        case .cma?: return cmaUseRestriction
        case nil: return .unsupportedProvider
        default: return CatalogLibrary.canUse(self) ? nil : .catalogBrowseOnly
        }
    }

    var isBrowseOnly: Bool { isCMABrowseOnly || (provider?.isCatalog == true && blocksUse) }

    var blocksUse: Bool { useRestriction != nil }

    /// Reconstruct Openverse thumbnail addresses from validated data, including for previously saved references.
    /// A CMA thumbnail is only the record's web rendition, and only while it still passes the CMA media policy.
    func galleryThumbnailURL(large: Bool) -> URL? {
        switch provider {
        case .wallhaven?: return large ? previewURL : thumbnailURL
        case .openverse?:
            guard let id = UUID(uuidString: wallpaperID) else { return nil }
            if sourceName == OpenverseURLPolicy.discoverySource,
               let thumbnail = OpenverseURLPolicy.commonsThumbnail(for: originalURL) { return thumbnail }
            return OpenverseEndpoint.thumbnailURL(id: id)
        case .cma?:
            guard let kind = cmaKind, kind != .metadataOnly, cma?.isCC0 == true,
                  CMAURLPolicy.isAllowedMediaURL(thumbnailURL, rendition: .web) else { return nil }
            return thumbnailURL
        case nil: return nil
        default: return CatalogLibrary.thumbnail(for: self, large: large)
        }
    }
    /// “CC0 1.0” or “Public Domain Mark 1.0”, as reported; nil when no license was reported.
    var licenseDescription: String? {
        guard let license else { return nil }
        let names = ["cc0": "CC0", "pdm": "Public Domain Mark", "cc-by": "CC BY",
                     "cc-by-sa": "CC BY-SA", "nasa": "NASA media guidelines"]
        let name = names[license.lowercased()] ?? license.uppercased()
        return [name, licenseVersion].compactMap { $0 }.joined(separator: " ")
    }

    /// The remote image the desktop preview draws until an original is cached, and how faithful it is.
    /// `previewURL` (Wallhaven's `thumbs.large`) is a 432×243 centre crop, so it holds the whole picture
    /// only for 16:9 originals (within a pixel of rounding); other shapes need the uncropped thumbnail.
    var remotePreview: (url: URL, fidelity: PreviewFidelity)? {
        // Openverse thumbnails are resized, not cropped: the whole picture, at low resolution.
        // A CMA work that can't be set has no live desktop preview at all.
        if provider == .cma, cmaKind != .settable { return nil }
        if provider != .wallhaven { return galleryThumbnailURL(large: true).map { ($0, .lowResolution) } }
        guard width > 0, height > 0 else { return (previewURL, .croppedThumbnail) }
        if abs(Double(height) * 432 / Double(width) - 243) <= 1 { return (previewURL, .lowResolution) }
        if let uncroppedPreviewURL { return (uncroppedPreviewURL, .lowResolution) }
        return (previewURL, .croppedThumbnail)
    }
}

/// How faithfully the desktop preview's image represents the original; a better one may replace a
/// worse one for the same wallpaper, never the reverse.
enum PreviewFidelity: Int, Comparable {
    case none, croppedThumbnail, lowResolution, original

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The caption under the preview; nil when the picture is drawn from the original's own pixels.
    var notice: (symbol: String, text: String, help: String)? {
        switch self {
        case .none, .original: return nil
        case .lowResolution:
            return ("photo", "Low-resolution preview; detail may differ.",
                    "The framing follows the original's proportions, but this is a small thumbnail, so sharpness and fine detail can differ. Set Wallpaper downloads and uses the full original.")
        case .croppedThumbnail:
            return ("crop", "Cropped thumbnail; framing is approximate and detail may differ.",
                    "Wallhaven's larger thumbnail is cut to 16:9, so parts of this wallpaper are missing here. Set Wallpaper downloads and uses the full original.")
        }
    }
}

struct WallpaperCollection: Codable, Equatable, Identifiable {
    let id: UUID
    private(set) var name: String
    private(set) var wallpapers: [WallpaperReference]

    init(id: UUID = UUID(), name: String, wallpapers: [WallpaperReference] = []) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.wallpapers = wallpapers
    }

    mutating func rename(to newName: String) {
        name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func add(_ reference: WallpaperReference) {
        guard !wallpapers.contains(where: { $0.identityKey == reference.identityKey }) else { return }
        wallpapers.append(reference)
    }

    mutating func remove(identityKey: String) {
        wallpapers.removeAll { $0.identityKey == identityKey }
    }

    mutating func updateCachedPath(identityKey: String, path: String) {
        for index in wallpapers.indices where wallpapers[index].identityKey == identityKey {
            wallpapers[index].cachedLocalPath = path
        }
    }
}

struct DisplayAssignment: Codable, Equatable {
    let displayID: String
    let displayName: String
    let imagePath: String
    let scaling: ScalingMode
}

struct HistoryEntry: Codable, Equatable {
    let previous: DisplayAssignment
    let replacement: DisplayAssignment
    let timestamp: Date
    // Optional fields keep existing M1/M2 JSON readable without rewriting its assignments.
    var rollbackPath: String? = nil
    var undoUnavailableReason: UndoUnavailableReason? = nil
}

enum UndoUnavailableReason: String, Codable {
    case previousFileUnavailable
    case preservationFailed
    case restoreFileUnavailable
}

struct WallpaperState: Codable, Equatable {
    static let currentVersion = 2
    static let historyLimit = 20

    var version = Self.currentVersion
    /// A local rotation place belongs to this folder: another folder, or this one revisited later,
    /// starts from its first image. A collection's place is unaffected by the browsing folder.
    var folderPath: String? { didSet { if folderPath != oldValue, activeRotationCollectionID == nil { rotationCursor = nil } } }
    var selectedImagePath: String?
    var selectedDisplayID: String?
    /// Fit shows the whole wallpaper, leaving the desktop color around it rather than cropping. Older state files
    /// always saved this value, so a saved Fill can't be told from the old default and is kept as a choice.
    var scalingMode: ScalingMode = .fit
    var rotationInterval: RotationInterval = .off
    var shuffleEnabled = false
    var displayAssignments: [DisplayAssignment] = []
    var history: [HistoryEntry] = []

    var currentSource: LibrarySource = .discover
    var selectedRemoteIdentity: String?
    var wallhavenSearch = WallhavenSearchOptions()
    /// Which remote source Discover shows; each keeps its own search.
    var discoverProvider: RemoteProviderID = .wallhaven
    var openverseSearch = OpenverseSearchOptions()
    var cmaSearch = CMASearchOptions()
    var catalogQueries: [String: String] = [:]
    var favorites: [WallpaperReference] = []
    var collections: [WallpaperCollection] = []
    var selectedCollectionID: UUID?
    /// Rotating from a different source starts that source from the beginning.
    var activeRotationCollectionID: UUID? { didSet { if activeRotationCollectionID != oldValue { rotationCursor = nil } } }
    /// Rotation's own place, independent of browsing: the member it last attempted, as a
    /// collection member's identity or a local file path. Unknown or nil starts from the first member.
    var rotationCursor: String?

    init() {}

    func assignment(for displayID: String) -> DisplayAssignment? {
        displayAssignments.first { $0.displayID == displayID }
    }

    mutating func setAssignment(_ assignment: DisplayAssignment) {
        displayAssignments.removeAll { $0.displayID == assignment.displayID }
        displayAssignments.append(assignment)
    }

    mutating func appendHistory(_ entry: HistoryEntry) {
        history.append(entry)
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
    }

    mutating func popHistory() -> HistoryEntry? {
        history.popLast()
    }

    func isFavorite(_ reference: WallpaperReference) -> Bool {
        favorites.contains { $0.identityKey == reference.identityKey }
    }

    mutating func toggleFavorite(_ reference: WallpaperReference) {
        if isFavorite(reference) {
            favorites.removeAll { $0.identityKey == reference.identityKey }
        } else {
            favorites.append(reference)
        }
    }

    mutating func updateCachedPath(for reference: WallpaperReference, path: String) {
        for index in favorites.indices where favorites[index].identityKey == reference.identityKey {
            favorites[index].cachedLocalPath = path
        }
        for index in collections.indices {
            collections[index].updateCachedPath(identityKey: reference.identityKey, path: path)
        }
    }

    var protectedCachePaths: Set<String> {
        var paths = Set(displayAssignments.map(\.imagePath))
        for entry in history {
            paths.insert(entry.previous.imagePath)
            paths.insert(entry.replacement.imagePath)
            if let rollbackPath = entry.rollbackPath { paths.insert(rollbackPath) }
        }
        paths.formUnion(favorites.compactMap(\.cachedLocalPath))
        for collection in collections {
            paths.formUnion(collection.wallpapers.compactMap(\.cachedLocalPath))
        }
        return paths
    }

    private enum CodingKeys: String, CodingKey {
        case version, folderPath, selectedImagePath, selectedDisplayID
        case scalingMode, rotationInterval, shuffleEnabled, displayAssignments, history
        case currentSource, selectedRemoteIdentity, wallhavenSearch, favorites, collections
        case discoverProvider, openverseSearch, cmaSearch, catalogQueries
        case selectedCollectionID, activeRotationCollectionID, rotationCursor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedFolderPath = try container.decodeIfPresent(String.self, forKey: .folderPath)

        version = Self.currentVersion
        folderPath = decodedFolderPath
        selectedImagePath = try container.decodeIfPresent(String.self, forKey: .selectedImagePath)
        selectedDisplayID = try container.decodeIfPresent(String.self, forKey: .selectedDisplayID)
        scalingMode = try container.decodeIfPresent(ScalingMode.self, forKey: .scalingMode) ?? .fit
        rotationInterval = try container.decodeIfPresent(RotationInterval.self, forKey: .rotationInterval) ?? .off
        shuffleEnabled = try container.decodeIfPresent(Bool.self, forKey: .shuffleEnabled) ?? false
        displayAssignments = try container.decodeIfPresent([DisplayAssignment].self, forKey: .displayAssignments) ?? []
        history = Array((try container.decodeIfPresent([HistoryEntry].self, forKey: .history) ?? []).suffix(Self.historyLimit))
        currentSource = try container.decodeIfPresent(LibrarySource.self, forKey: .currentSource)
            ?? (decodedFolderPath == nil ? .discover : .local)
        selectedRemoteIdentity = try container.decodeIfPresent(String.self, forKey: .selectedRemoteIdentity)
        wallhavenSearch = try container.decodeIfPresent(WallhavenSearchOptions.self, forKey: .wallhavenSearch)
            ?? WallhavenSearchOptions()
        // Absent in state saved before Openverse; an unknown value must never discard the rest of the state.
        discoverProvider = (try? container.decodeIfPresent(RemoteProviderID.self, forKey: .discoverProvider)) ?? .wallhaven
        openverseSearch = (try? container.decodeIfPresent(OpenverseSearchOptions.self, forKey: .openverseSearch)) ?? OpenverseSearchOptions()
        cmaSearch = (try? container.decodeIfPresent(CMASearchOptions.self, forKey: .cmaSearch)) ?? CMASearchOptions()
        catalogQueries = (try? container.decodeIfPresent([String: String].self, forKey: .catalogQueries)) ?? [:]
        favorites = try container.decodeIfPresent([WallpaperReference].self, forKey: .favorites) ?? []
        collections = try container.decodeIfPresent([WallpaperCollection].self, forKey: .collections) ?? []
        selectedCollectionID = try container.decodeIfPresent(UUID.self, forKey: .selectedCollectionID)
        activeRotationCollectionID = try container.decodeIfPresent(UUID.self, forKey: .activeRotationCollectionID)
        rotationCursor = try container.decodeIfPresent(String.self, forKey: .rotationCursor)
    }
}

/// Gallery thumbnails crop every wallpaper to the display's shape, so captions name the shapes that
/// crop noticeably. Ordinary landscape (3:2 to 16:9 and a little wider) needs no word.
enum WallpaperShape {
    static func name(width: Int, height: Int) -> String? {
        guard width > 0, height > 0 else { return nil }
        let ratio = Double(width) / Double(height)
        if ratio < 0.95 { return "Portrait" }
        if ratio <= 1.05 { return "Square" }
        return ratio >= 2 ? "Ultrawide" : nil
    }

    /// "3840 × 2160", with the shape's name when it has one.
    static func summary(width: Int, height: Int) -> String {
        ["\(width) × \(height)", name(width: width, height: height)].compactMap { $0 }.joined(separator: " · ")
    }
}

enum WallpaperNavigation {
    static func index(after currentIndex: Int?, direction: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let currentIndex, (0..<count).contains(currentIndex) else {
            return direction < 0 ? count - 1 : 0
        }

        let offset = direction < 0 ? -1 : 1
        return (currentIndex + offset + count) % count
    }
}

enum SupportedWallpaperFiles {
    static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif"]

    static func isSupported(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    static func images(in folderURL: URL, fileManager: FileManager = .default) throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        return try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            guard isSupported(url) else { return false }
            return (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) == true
        }
        .sorted {
            $0.lastPathComponent.compare(
                $1.lastPathComponent,
                options: [.caseInsensitive, .numeric, .diacriticInsensitive],
                locale: Locale.current
            ) == .orderedAscending
        }
    }
}
