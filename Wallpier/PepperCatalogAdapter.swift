import Foundation

struct PepperCatalogAdapter: CatalogAdapter {
    let id: RemoteProviderID = .pepper
    let endpoint = URL(string: "https://www.peppercarrot.com/en/wallpapers/index.html")!
    let hosts: Set<String> = ["www.peppercarrot.com"]

    private static let site = "https://www.peppercarrot.com"
    private static let directory = "/0_sources/0ther/wallpapers"
    private static let artist = "David Revoy"
    private static let licenseURL = URL(string: "https://creativecommons.org/licenses/by/4.0/")!
    private static let cache = CatalogueCache()

    // Each of these publisher-listed works has its own CC BY 4.0 notice and credits Revoy for the art.
    private static let reviewedFiles = [
        "2023-03-30_Concept-art-for-a-fictive-video-game-Save-Point",
        "2023-01-09_The-after-rain-smell",
        "2022-12-18_Point-of-View",
        "2022-12-06_Rain-City",
        "2022-06-30_Asleep",
        "2022-02-21_The-market",
        "2021-08-28_The-Treasure",
        "2021-05-19_Spooky-Cute-House",
        "2020-12-21_The-fairy-fir-tree",
        "2020-09-06_Autumn-Run",
        "2019-12-09_Unity-tree",
        "2018-06-03_Komona-sunset",
        "2018-06-03_Komona-sunset-dark",
        "2018-03-30_The-rendezvous",
        "2017-12-13_The-micro-dimension",
        "2017-04-07_Young-Pepper",
        "2016-12-04_Running-on-Snow",
        "2016-12-04_Snow-Angels"
    ].map { "\($0)_by-David-Revoy" }
    private static let reviewedIDs = Set(reviewedFiles)

    func search(_ options: CatalogSearchOptions, page: Int, transport: CatalogTransport) async throws -> RemoteSearchPage {
        let catalogue = try await Self.cache.catalogue(using: transport)
        let query = options.trimmedQuery
        let matches = catalogue.wallpapers.filter { item in
            query.isEmpty || ([item.displayTitle, Self.artist] + item.tags).contains { $0.localizedStandardContains(query) }
        }
        let currentPage = max(1, page)
        return RemoteSearchPage(wallpapers: currentPage == 1 ? matches : [], currentPage: currentPage, lastPage: 1,
                                total: matches.count, rateLimit: ProviderRateLimit(limit: nil, remaining: nil, resetDate: nil),
                                hiddenCount: query.isEmpty && currentPage == 1 ? catalogue.hidden : 0)
    }

    func refresh(_ reference: WallpaperReference, transport: CatalogTransport) async throws -> WallpaperReference {
        let itemID = reference.wallpaperID
        guard reference.providerIdentifier == id.rawValue, Self.reviewedIDs.contains(itemID),
              try await Self.liveIDs(using: transport, revalidate: true).contains(itemID),
              let current = try await Self.reference(for: itemID, using: transport, revalidate: true) else {
            throw RemoteProviderError.notOpenAccess
        }
        return current
    }

    func allowsMedia(_ url: URL, id: String, original: Bool) -> Bool {
        Self.reviewedIDs.contains(id) && url.absoluteString == Self.mediaURL(for: id, original: original).absoluteString
    }

    func allowsPage(_ url: URL, id: String) -> Bool {
        Self.reviewedIDs.contains(id) && url.absoluteString == Self.sourcePage(for: id).absoluteString
    }

    private static func sourcePage(for id: String) -> URL {
        URL(string: "\(site)/en/viewer/wallpapers-src__\(id).html")!
    }

    private static func mediaURL(for id: String, original: Bool) -> URL {
        URL(string: "\(site)\(directory)/\(original ? "hi-res" : "low-res")/\(id).jpg")!
    }

    private static func html(from url: URL, using transport: CatalogTransport, revalidate: Bool) async throws -> String {
        let data = try await transport.bytes(from: url, maximumBytes: 128_000, accept: "text/html", revalidate: revalidate)
        guard let html = String(data: data, encoding: .utf8) else { throw RemoteProviderError.invalidData }
        return html
    }

    private static func listedIDs(in folder: String, using transport: CatalogTransport, revalidate: Bool) async throws -> Set<String> {
        let path = "\(directory)/\(folder)"
        let listing = try await html(from: URL(string: "\(site)\(path)/")!, using: transport, revalidate: revalidate)
        guard listing.contains("Index of \(path)") else { throw RemoteProviderError.invalidData }
        return Set(reviewedFiles.filter { listing.contains("href=\"\($0).jpg\"") })
    }

    private static func liveIDs(using transport: CatalogTransport, revalidate: Bool) async throws -> Set<String> {
        async let low = listedIDs(in: "low-res", using: transport, revalidate: revalidate)
        async let high = listedIDs(in: "hi-res", using: transport, revalidate: revalidate)
        let (lowIDs, highIDs) = try await (low, high)
        return lowIDs.intersection(highIDs)
    }

    private static func reference(for id: String, using transport: CatalogTransport, revalidate: Bool) async throws -> WallpaperReference? {
        let page = sourcePage(for: id)
        let html: String
        do {
            html = try await Self.html(from: page, using: transport, revalidate: revalidate)
        } catch RemoteProviderError.httpStatus(404) {
            return nil
        }

        let original = mediaURL(for: id, original: true)
        let preview = mediaURL(for: id, original: false)
        guard html.contains("href=\"\(original.absoluteString)\""),
              html.contains("src=\"\(preview.absoluteString)\""),
              html.contains("Attribution to <strong>\(artist)</strong>"),
              let footer = html.range(of: "<div class=\"ViewFooterInfo\">"),
              let footerEnd = html.range(of: "</div>", range: footer.upperBound..<html.endIndex) else { return nil }
        let notice = html[footer.upperBound..<footerEnd.lowerBound]
        let titleLink = "href=\"\(site)/en/viewer/wallpapers__\(id).html\">"
        guard let titleStart = notice.range(of: titleLink),
              let titleEnd = notice.range(of: "</a>", range: titleStart.upperBound..<notice.endIndex),
              let licenseStart = notice.range(of: "<a href=\"\(licenseURL.absoluteString)deed.en\">CC-BY 4.0</a>"),
              titleEnd.upperBound <= licenseStart.lowerBound else { return nil }
        let attribution = DisplayText.clean(String(notice[titleEnd.upperBound..<licenseStart.lowerBound]))
        guard attribution == "by \(artist) −" else { return nil }

        let title = DisplayText.clean(String(notice[titleStart.upperBound..<titleEnd.lowerBound]))
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard !title.isEmpty,
              let size = html.range(of: #"Original size: [0-9]{3,4}x[0-9]{3,4}px"#, options: .regularExpression) else { return nil }
        let dimensions = html[size].dropFirst("Original size: ".count).dropLast(2).split(separator: "x")
        guard let width = Int(dimensions[0]), let height = Int(dimensions[1]),
              width >= 1280, height >= 720, width >= height, width <= 8192, width * height <= 40_000_000 else { return nil }

        let credit = notice.contains("AI derivation prohibited") ? "\(artist) · AI derivation prohibited" : artist
        let tags = id.contains("Save-Point") ? ["fantasy", "game concept art"] : ["fantasy", "illustration"]
        return WallpaperReference(
            providerIdentifier: RemoteProviderID.pepper.rawValue, wallpaperID: id,
            sourcePageURL: page, originalURL: original, previewURL: preview, thumbnailURL: preview,
            width: width, height: height, uploader: artist, tags: tags, cachedLocalPath: nil, title: title,
            license: "CC BY", licenseVersion: "4.0", licenseURL: licenseURL,
            catalog: CatalogRecord(credit: credit)
        )
    }

    private struct Catalogue {
        let wallpapers: [WallpaperReference]
        let hidden: Int

        static func load(using transport: CatalogTransport) async throws -> Catalogue {
            let live = try await liveIDs(using: transport, revalidate: false)
            let ids = reviewedFiles.filter(live.contains)
            var wallpapers: [WallpaperReference] = []
            for index in stride(from: 0, to: ids.count, by: 4) {
                let batch = try await withThrowingTaskGroup(of: WallpaperReference?.self) { group in
                    for item in ids[index..<min(index + 4, ids.count)] {
                        group.addTask { try await PepperCatalogAdapter.reference(for: item, using: transport, revalidate: false) }
                    }
                    return try await group.reduce(into: [WallpaperReference]()) { items, item in
                        if let item { items.append(item) }
                    }
                }
                wallpapers.append(contentsOf: batch)
            }
            wallpapers.sort { $0.wallpaperID > $1.wallpaperID }
            return Catalogue(wallpapers: wallpapers, hidden: reviewedFiles.count - wallpapers.count)
        }
    }

    private actor CatalogueCache {
        private var lastCatalogue: Catalogue?
        private var checkedAt = Date.distantPast
        private var loading: Task<Catalogue, Error>?

        func catalogue(using transport: CatalogTransport) async throws -> Catalogue {
            if let lastCatalogue, Date().timeIntervalSince(checkedAt) < 300 { return lastCatalogue }
            if let loading { return try await loading.value }
            let task = Task { try await Catalogue.load(using: transport) }
            loading = task
            defer { loading = nil }
            let catalogue = try await task.value
            lastCatalogue = catalogue
            checkedAt = Date()
            return catalogue
        }
    }
}
