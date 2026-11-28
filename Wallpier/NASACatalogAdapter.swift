import Foundation

// NASA Image and Video Library, as a catalog adapter.
//
// Only positively attributable NASA imagery is shown. A record passes when either
//   1. its `photographer` is exactly NASA or a NASA center (e.g. "NASA", "NASA/JSC"), or
//   2. it is a coded Apollo archive record: center JSC, an Apollo frame ID (`as<mission>-<roll>-<frame>`), the
//      "APOLLO PROJECT" archive keyword, and no creator fields at all.
// In both cases any `secondary_creator` must itself be NASA or a NASA center, a named third party, a ©, a
// "courtesy of" or a non-NASA "Credit:" line anywhere in the description rejects the record, and the original must be
// the exact `~orig` image on the assets host. On refresh the record is fetched again by `nasa_id` and the exact
// original URL must appear in the item's asset manifest (old http manifest entries are normalized to https on the
// documented assets host only, before comparison).

struct NASACatalogAdapter: CatalogAdapter {
    static let apiHost = "images-api.nasa.gov"
    static let assetHost = "images-assets.nasa.gov"
    static let pageHost = "images.nasa.gov"
    static let pageSize = 20
    static let maximumPages = 100
    static let defaultQuery = "Earth horizon"
    static let defaultCenter = "JSC"
    static let rightsGuidance = URL(string: "https://www.nasa.gov/nasa-brand-center/images-and-media/")!

    static let centerNames: Set<String> = [
        "ARC", "AFRC", "GRC", "GSFC", "HQ", "JSC", "KSC", "LARC", "MSFC", "SSC",
        "AMES RESEARCH CENTER", "ARMSTRONG FLIGHT RESEARCH CENTER", "GLENN RESEARCH CENTER", "GODDARD SPACE FLIGHT CENTER",
        "JOHNSON SPACE CENTER", "KENNEDY SPACE CENTER", "LANGLEY RESEARCH CENTER",
        "MARSHALL SPACE FLIGHT CENTER", "STENNIS SPACE CENTER"
    ]

    var id: RemoteProviderID { .nasa }
    var endpoint: URL { URL(string: "https://images.nasa.gov")! }
    var hosts: Set<String> { [Self.apiHost, Self.assetHost] }

    // MARK: Typed records

    struct SearchResponse: Decodable {
        struct Collection: Decodable {
            struct Metadata: Decodable { let total_hits: Int? }
            let items: [Item]
            let metadata: Metadata?
        }
        let collection: Collection
    }

    struct Item: Decodable {
        let data: [DataRecord]
        let links: [Link]?
    }

    struct DataRecord: Decodable {
        let center: String?
        let nasa_id: String?
        let title: String?
        let media_type: String?
        let photographer: String?
        let secondary_creator: String?
        let description: String?
        let keywords: [String]?
    }

    struct Link: Decodable {
        let href: String?
        let rel: String?
        let render: String?
        let width: Int?
        let height: Int?
    }

    struct AssetManifest: Decodable {
        struct Collection: Decodable {
            struct Entry: Decodable { let href: String? }
            let items: [Entry]
        }
        let collection: Collection
    }

    // MARK: Search

    func search(_ options: CatalogSearchOptions, page: Int, transport: CatalogTransport) async throws -> RemoteSearchPage {
        let requested = max(1, min(page, Self.maximumPages))
        let blank = options.trimmedQuery.isEmpty
        var query = [URLQueryItem(name: "q", value: blank ? Self.defaultQuery : options.trimmedQuery),
                     URLQueryItem(name: "media_type", value: "image")]
        if blank { query.append(URLQueryItem(name: "center", value: Self.defaultCenter)) }
        query += [URLQueryItem(name: "page_size", value: String(Self.pageSize)), URLQueryItem(name: "page", value: String(requested))]
        let response = try await transport.json(SearchResponse.self, from: CatalogURL.make("https://\(Self.apiHost)/search", query))

        var wallpapers: [WallpaperReference] = []
        var hidden = 0
        var seen = Set<String>()
        for item in response.collection.items.prefix(Self.pageSize) {
            guard let reference = Self.reference(from: item), seen.insert(reference.wallpaperID).inserted else { hidden += 1; continue }
            wallpapers.append(reference)
        }
        let total = max(response.collection.metadata?.total_hits ?? wallpapers.count, 0)
        let computedLast = total == 0 ? 0 : min((total - 1) / Self.pageSize + 1, Self.maximumPages)
        let last = response.collection.items.isEmpty ? min(requested, computedLast) : computedLast
        return RemoteSearchPage(wallpapers: wallpapers, currentPage: requested, lastPage: last, total: total,
                                rateLimit: ProviderRateLimit(limit: nil, remaining: nil, resetDate: nil), hiddenCount: hidden)
    }

    // MARK: Refresh

    func refresh(_ reference: WallpaperReference, transport: CatalogTransport) async throws -> WallpaperReference {
        let nasaID = reference.wallpaperID
        guard reference.providerIdentifier == RemoteProviderID.nasa.rawValue, Self.isSafeID(nasaID) else {
            throw RemoteProviderError.unsupportedProvider
        }
        // Fresh rights: the record again, by exact ID.
        let lookup = CatalogURL.make("https://\(Self.apiHost)/search",
                                     [URLQueryItem(name: "nasa_id", value: nasaID), URLQueryItem(name: "media_type", value: "image")])
        let response = try await transport.json(SearchResponse.self, from: lookup, revalidate: true)
        guard let item = response.collection.items.first(where: { $0.data.first?.nasa_id == nasaID }),
              let fresh = Self.reference(from: item), fresh.wallpaperID == nasaID else { throw RemoteProviderError.notOpenAccess }
        // The exact original must be in the asset manifest.
        let manifestURL = CatalogURL.make("https://\(Self.apiHost)/asset/\(Self.encoded(nasaID))", [])
        let manifest = try await transport.json(AssetManifest.self, from: manifestURL, revalidate: true)
        let listed = Set(manifest.collection.items.compactMap { $0.href.flatMap(Self.normalizedAssetURL)?.absoluteString })
        guard listed.contains(fresh.originalURL.absoluteString) else { throw RemoteProviderError.notOpenAccess }
        return fresh
    }

    // MARK: URL policy

    func allowsMedia(_ url: URL, id: String, original: Bool) -> Bool {
        guard Self.isSafeID(id), CatalogURL.isHTTPS(url), url.host?.lowercased() == Self.assetHost, url.query == nil, url.fragment == nil else { return false }
        let prefix = "/image/\(id)/\(id)~"
        guard url.path.hasPrefix(prefix) else { return false }
        let suffix = String(url.path.dropFirst(prefix.count))
        if original { return ["orig.jpg", "orig.jpeg", "orig.png"].contains(suffix) }
        return ["thumb.jpg", "small.jpg", "medium.jpg", "large.jpg"].contains(suffix)
    }

    func allowsPage(_ url: URL, id: String) -> Bool {
        CatalogURL.isHTTPS(url) && url.host?.lowercased() == Self.pageHost && Self.isSafeID(id)
            && url.query == nil && url.path == "/details/\(id)"
    }

    static func isSafeID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 160 && value != "." && value != ".." && !value.contains("..")
            && value.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains(Character($0)) || "-_.".unicodeScalars.contains($0)) }
    }

    private static func encoded(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? id
    }

    /// Absolute HTTPS URL on the documented assets host; an `http` entry on that exact host is upgraded, nothing else.
    static func normalizedAssetURL(_ text: String) -> URL? {
        guard var components = URLComponents(string: text), components.host?.lowercased() == assetHost,
              components.user == nil, components.password == nil, components.port == nil else { return nil }
        guard components.scheme?.lowercased() == "https" || components.scheme?.lowercased() == "http" else { return nil }
        components.scheme = "https"
        return components.url
    }

    // MARK: Rights

    /// "NASA", or "NASA/<center>" / "NASA <center>" where every part is a NASA center code or name.
    static func isNASACredit(_ text: String) -> Bool {
        let upper = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if upper == "NASA" { return true }
        guard upper.hasPrefix("NASA/") || upper.hasPrefix("NASA ") else { return false }
        let parts = upper.dropFirst(5).split(separator: "/", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        return !parts.isEmpty && parts.allSatisfy { centerNames.contains($0) }
    }

    private static func clean(_ text: String?) -> String? {
        guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// Any ©, "courtesy" or "copyright" wording, or a "Credit:" line that isn't NASA, rejects the record.
    static func descriptionIsClean(_ description: String?) -> Bool {
        guard let description else { return true }
        let lower = description.lowercased()
        if lower.contains("©") || lower.contains("&copy;") || lower.contains("courtesy") || lower.contains("copyright") { return false }
        var searchRange = description.startIndex..<description.endIndex
        while let found = description.range(of: "credit:", options: .caseInsensitive, range: searchRange) {
            let tail = description[found.upperBound...]
            let end = tail.firstIndex(where: { $0 == "." || $0 == "\n" || $0 == "<" || $0 == ")" }) ?? tail.endIndex
            if !isNASACredit(String(tail[..<end])) { return false }
            searchRange = found.upperBound..<description.endIndex
        }
        return true
    }

    /// The credit line for a record that positively qualifies, else nil.
    static func credit(for data: DataRecord) -> String? {
        guard descriptionIsClean(data.description) else { return nil }
        let photographer = clean(data.photographer), secondary = clean(data.secondary_creator)
        if let secondary, !isNASACredit(secondary) { return nil }
        if let photographer { return isNASACredit(photographer) ? photographer : nil }
        // Coded Apollo archive record: no creator fields at all.
        guard secondary == nil, data.center?.uppercased() == "JSC", let nasaID = data.nasa_id,
              nasaID.range(of: "^as[0-9]{1,2}-[0-9]{1,3}-[0-9]+$", options: [.regularExpression, .caseInsensitive]) != nil,
              (data.keywords ?? []).contains(where: { $0.trimmingCharacters(in: .whitespaces).uppercased() == "APOLLO PROJECT" })
        else { return nil }
        return "NASA/JSC"
    }

    // MARK: Mapping

    static func reference(from item: Item) -> WallpaperReference? {
        guard let data = item.data.first, data.media_type == "image", let nasaID = data.nasa_id, isSafeID(nasaID),
              let creditLine = Self.credit(for: data) else { return nil }
        let adapter = NASACatalogAdapter()
        func find(_ matches: (Link) -> Bool, original: Bool) -> (url: URL, link: Link)? {
            for candidate in item.links ?? [] where matches(candidate) {
                if let text = candidate.href, let url = normalizedAssetURL(text), adapter.allowsMedia(url, id: nasaID, original: original) { return (url, candidate) }
            }
            return nil
        }
        guard let original = find({ $0.rel == "canonical" && $0.render == "image" }, original: true),
              let thumbnail = find({ $0.rel == "preview" }, original: false) else { return nil }
        let preview = find({ $0.href?.contains("~medium.") == true }, original: false)
            ?? find({ $0.href?.contains("~small.") == true }, original: false) ?? thumbnail
        var components = URLComponents()
        components.scheme = "https"; components.host = pageHost; components.path = "/details/\(nasaID)"
        guard let page = components.url, adapter.allowsPage(page, id: nasaID) else { return nil }
        // Unknown original dimensions stay 0×0; never a rendition's size.
        let width = original.link.width.flatMap { $0 > 0 ? $0 : nil } ?? 0
        let height = original.link.height.flatMap { $0 > 0 ? $0 : nil } ?? 0
        let known = width > 0 && height > 0
        let title = clean(data.title)
        return WallpaperReference(
            providerIdentifier: RemoteProviderID.nasa.rawValue, wallpaperID: nasaID, sourcePageURL: page,
            originalURL: original.url, previewURL: preview.url, thumbnailURL: thumbnail.url,
            width: known ? width : 0, height: known ? height : 0, uploader: nil, tags: [], cachedLocalPath: nil,
            title: title, sourceName: "NASA Image and Video Library", license: "nasa", licenseURL: rightsGuidance,
            catalog: CatalogRecord(creator: nil, credit: "\(creditLine) · NASA Image and Video Library", browseOnly: false))
    }
}
