import Foundation
import ImageIO

// Cleveland Museum of Art Open Access, as a Wallpier source.
//
// Only documented operations are used: artwork search (including the artist-name search), artwork detail and
// creator detail. The creator's own artwork list is a stub that can credit derivative works, so it never fills the
// grid; it is only read for diagnostics. Nothing here is a connector for any other provider.

/// Which URLs Wallpier will request for CMA: API calls only to the Open Access API host, media only over HTTPS from
/// the Open Access CDN, and canonical links only to the museum's own site.
enum CMAURLPolicy {
    static let apiHost = "openaccess-api.clevelandart.org"
    static let imageHost = "openaccess-cdn.clevelandart.org"
    static let pageHosts: Set<String> = ["clevelandart.org", "www.clevelandart.org"]
    static let maximumRedirects = 3
    /// The hard cap on a print download, enforced while the bytes stream in.
    static let maximumDownloadBytes: Int64 = 40 * 1_024 * 1_024
    static let maximumPixels = 80_000_000
    static let minimumLongEdge = 1_920
    static let dimensionTolerance = 2
    /// The reported file size is only a sanity ceiling, never an equality check.
    static let fileSizeAllowance = 1.25
    static let maximumResponseBytes = 6 * 1_024 * 1_024

    enum Rendition: String {
        case web, print
        var suffix: String { "_\(rawValue).jpg" }
    }

    static func isSafeHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443) && !(url.host ?? "").isEmpty
    }

    static func isAPIURL(_ url: URL) -> Bool { isSafeHTTPS(url) && url.host?.lowercased() == apiHost }

    /// HTTPS on the CDN host: what every media request and every redirect hop must be.
    static func isImageHostURL(_ url: URL) -> Bool { isSafeHTTPS(url) && url.host?.lowercased() == imageHost }

    static func isCMAHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "clevelandart.org" || host.hasSuffix(".clevelandart.org")
    }

    /// The record's canonical page: HTTPS on the museum's own host. Never constructed or guessed.
    static func isAllowedPageURL(_ url: URL) -> Bool {
        isSafeHTTPS(url) && pageHosts.contains(url.host?.lowercased() ?? "")
    }

    /// An item-specific rendition path such as `/1930.189/1930.189_web.jpg` on the CDN.
    static func isAllowedMediaURL(_ url: URL, rendition: Rendition) -> Bool {
        guard isImageHostURL(url), url.query == nil, url.fragment == nil else { return false }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty else { return false }
        let directory = String(parts[1]), file = String(parts[2])
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !directory.isEmpty, directory != ".", directory != "..",
              directory.unicodeScalars.allSatisfy(allowed.contains), file.unicodeScalars.allSatisfy(allowed.contains),
              file.hasPrefix(directory + "_"), file.lowercased().hasSuffix(rendition.suffix) else { return false }
        return true
    }

    /// API requests stay on the API host; media redirects stay on the CDN host. HTTP is never followed.
    static func allowsRedirect(from original: URL, to target: URL) -> Bool {
        switch original.host?.lowercased() {
        case apiHost: return isAPIURL(target)
        // Media redirects stay on the same approved item and rendition path: same host, same path, no query.
        case imageHost: return isImageHostURL(target) && target.path == original.path && target.query == nil && target.fragment == nil
        default: return false
        }
    }
}

enum CMAEndpoint {
    static let pageSize = 20
    /// One search page, no pagination: the creator view's whole fanout is this and one creator detail.
    static let creatorWorksLimit = 100
    static let fields = "id,title,creation_date,accession_number,url,creators,share_license_status,images"
    private static let base = URL(string: "https://openaccess-api.clevelandart.org/api/")!

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? ""
    }

    private static func artworksURL(_ items: [(String, String)]) -> URL {
        var components = URLComponents(url: base.appendingPathComponent("artworks", isDirectory: true), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = items.map { "\($0.0)=\(encode($0.1))" }.joined(separator: "&")
        return components.url!
    }

    /// A blank search browses open-access (CC0) works that have images. Typed text searches all of the museum's public
    /// records, so a record that can only be linked (not copyright-cleared, or without images) is reachable too.
    static func searchURL(options: CMASearchOptions, page: Int) -> URL {
        var items: [(String, String)] = []
        if options.trimmedQuery.isEmpty { items += [("cc0", "1"), ("has_image", "1")] } else { items.append(("q", options.trimmedQuery)) }
        items += [("limit", String(pageSize)), ("skip", String((max(1, min(page, 100_000)) - 1) * pageSize)), ("fields", fields)]
        return artworksURL(items)
    }

    /// The documented artist-name search. Names are never identity: every row is checked against the creator ID.
    static func artistWorksURL(name: String) -> URL {
        artworksURL([("artists", name), ("limit", String(creatorWorksLimit)), ("fields", fields)])
    }

    static func creatorURL(id: Int) -> URL { base.appendingPathComponent("creators", isDirectory: true).appendingPathComponent(String(id)) }
    static func artworkURL(id: Int) -> URL { base.appendingPathComponent("artworks", isDirectory: true).appendingPathComponent(String(id)) }
}

struct CMASearchOptions: Codable, Equatable {
    var query = ""

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var resultsDescription: String { trimmedQuery.isEmpty ? "Open-access works" : "“\(trimmedQuery)”" }

    private enum CodingKeys: String, CodingKey { case query }

    init(query: String = "") { self.query = query }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        query = (try? container.decodeIfPresent(String.self, forKey: .query)) ?? ""
    }
}

// MARK: - The record a CMA reference keeps

/// What Wallpier shows for one CMA row, decided once from the row's own record.
enum CMAKind: Equatable {
    /// Explicit CC0 with well-formed web and print renditions: preview, Set and Favorite are allowed.
    case settable
    /// CC0 with a web rendition but no valid print: a thumbnail and a link only.
    case thumbnailOnly
    /// Not CC0, or no usable images: a text row and a link only. No image request of any kind.
    case metadataOnly
}

/// The museum's record, kept as reported. Display text is cleaned when shown, never here.
struct CMARecord: Codable, Equatable, Hashable {
    struct Creator: Codable, Equatable, Hashable {
        var id: Int?
        var description: String?
        var role: String?
        var qualifier: String?
    }

    var creators: [Creator]
    var creationDate: String?
    var accessionNumber: String?
    var shareLicenseStatus: String?
    /// Validated at classification: the renditions' URLs, dimensions and sizes were well formed.
    var hasWeb: Bool
    var hasPrint: Bool
    var webWidth: Int?
    var webHeight: Int?
    var printFileSize: Int?

    /// Roles that credit a creator as the maker. Only the verified one: anything else fails closed.
    static let plainRoles: Set<String> = ["artist"]

    var isCC0: Bool { shareLicenseStatus?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "CC0" }

    var kind: CMAKind {
        guard isCC0, hasWeb else { return .metadataOnly }
        return hasPrint ? .settable : .thumbnailOnly
    }

    static func isPlain(_ creator: Creator) -> Bool {
        guard creator.id != nil, let role = creator.role?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              plainRoles.contains(role) else { return false }
        return (creator.qualifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The creator this record credits plainly, first listed.
    var primaryPlainCreator: Creator? { creators.first(where: Self.isPlain) }

    func creditsPlainly(id: Int) -> Bool { creators.contains { $0.id == id && Self.isPlain($0) } }
    func mentions(id: Int) -> Bool { creators.contains { $0.id == id } }
}

enum CMADisplay {
    /// The decoded text before the first " (" (a nationality or date clause), else the whole decoded description.
    static func name(fromDescription description: String?) -> String {
        let cleaned = DisplayText.clean(description)
        if let range = cleaned.range(of: " (") {
            let prefix = cleaned[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            if !prefix.isEmpty { return prefix }
        }
        return cleaned
    }
}

extension WallpaperReference {
    var cmaKind: CMAKind? { provider == .cma ? (cma?.kind ?? .metadataOnly) : nil }
    /// A CMA row that may be browsed and linked but never previewed, set, favorited or collected.
    var isCMABrowseOnly: Bool { cmaKind.map { $0 != .settable } ?? false }
    var cmaPageURL: URL? { provider == .cma && CMAURLPolicy.isAllowedPageURL(sourcePageURL) ? sourcePageURL : nil }

    /// Credit for display: the plainly credited creator only, with "and others" when more are listed.
    /// A qualified credit keeps its qualifier; co-contributors are never named as authors.
    var cmaCreditName: String { cmaCredit(preferring: nil) }

    /// Inside a creator view the credit is that creator's, when the record still credits them plainly; a record that no
    /// longer does is credited as it now reads (qualified or unattributed), never as an unqualified “by”.
    func cmaCredit(preferring creatorID: Int?) -> String {
        guard let record = cma else { return "Unattributed" }
        let others = record.creators.count > 1 ? " and others" : ""
        let plain = creatorID.flatMap { id in record.creators.first { $0.id == id && CMARecord.isPlain($0) } } ?? record.primaryPlainCreator
        if let primary = plain {
            let name = CMADisplay.name(fromDescription: primary.description)
            return name.isEmpty ? "Unattributed" : name + others
        }
        if let first = record.creators.first, let qualifier = first.qualifier.map({ DisplayText.clean($0) }), !qualifier.isEmpty {
            let name = CMADisplay.name(fromDescription: first.description)
            if !name.isEmpty { return "\(qualifier) \(name)" + others }
        }
        return "Unattributed"
    }

    var cmaDateText: String? {
        let date = DisplayText.clean(cma?.creationDate)
        return date.isEmpty ? nil : date
    }

    /// "Katsushika Hokusai · Cleveland Museum of Art · CC0"
    var cmaProvenance: String { cmaProvenance(preferring: nil) }

    func cmaProvenance(preferring creatorID: Int?) -> String {
        [cmaCredit(preferring: creatorID), "Cleveland Museum of Art", cma?.isCC0 == true ? "CC0" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    /// The creator an anchor credits plainly, if it does.
    var cmaPivot: (id: Int, name: String)? {
        guard provider == .cma, let creator = cma?.primaryPlainCreator, let id = creator.id else { return nil }
        let name = CMADisplay.name(fromDescription: creator.description)
        return name.isEmpty ? nil : (id, name)
    }

    var cmaToolTip: String {
        var parts = [displayTitle, cmaProvenance]
        if let date = cmaDateText { parts.insert(date, at: 1) }
        switch cmaKind {
        case .thumbnailOnly?: parts.append("No high-resolution JPEG")
        case .metadataOnly?: parts.append("View on Cleveland Museum of Art")
        default: break
        }
        return parts.joined(separator: " · ")
    }

    /// Why a CMA work can't be previewed, set, favorited or collected; nil when it can.
    var cmaUseRestriction: RemoteProviderError? {
        guard provider == .cma else { return .unsupportedProvider }
        guard cmaKind == .settable else { return .browseOnly }
        guard CMAURLPolicy.isAllowedMediaURL(originalURL, rendition: .print),
              CMAURLPolicy.isAllowedMediaURL(thumbnailURL, rendition: .web),
              CMAURLPolicy.isAllowedPageURL(sourcePageURL), Int(wallpaperID) != nil else { return .untrustedURL }
        return nil
    }
}

// MARK: - Parsing

enum CMAParsing {
    struct Rendition {
        let url: URL
        let width: Int
        let height: Int
        let fileSize: Int?
    }

    static func positiveInt(_ value: Any?, maximum: Int) -> Int? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.count <= 12, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(trimmed), (1...maximum).contains(number) else { return nil }
            return number
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let double = number.doubleValue
            guard double.isFinite, double == double.rounded(), double >= 1, double <= Double(maximum) else { return nil }
            return Int(double)
        default:
            return nil
        }
    }

    static func nonNegativeInt(_ value: Any?) -> Int? {
        let limit = 100_000_000   // far beyond any real catalog; larger claims are malformed, not trusted
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue >= 0,
           number.doubleValue <= Double(limit), number.doubleValue == number.doubleValue.rounded() { return number.intValue }
        if let string = value as? String, string.count <= 9, let number = Int(string.trimmingCharacters(in: .whitespaces)), (0...limit).contains(number) { return number }
        return nil
    }

    static func rendition(_ object: Any?, kind: CMAURLPolicy.Rendition) -> Rendition? {
        guard let dictionary = object as? [String: Any], let text = dictionary["url"] as? String, let url = URL(string: text),
              CMAURLPolicy.isAllowedMediaURL(url, rendition: kind),
              let width = positiveInt(dictionary["width"], maximum: 100_000),
              let height = positiveInt(dictionary["height"], maximum: 100_000) else { return nil }
        return Rendition(url: url, width: width, height: height, fileSize: positiveInt(dictionary["filesize"], maximum: 2_000_000_000))
    }

    static func creators(_ value: Any?) -> [CMARecord.Creator] {
        guard let array = value as? [Any] else { return [] }
        return array.prefix(50).compactMap { entry in
            guard let dictionary = entry as? [String: Any] else { return nil }
            // A qualifier that is present but isn't text is malformed: it must never read as "no qualifier".
            let rawQualifier = dictionary["qualifier"]
            let qualifier: String? = rawQualifier == nil || rawQualifier is NSNull ? nil : ((rawQualifier as? String) ?? "unknown")
            return CMARecord.Creator(id: positiveInt(dictionary["id"], maximum: 1_000_000_000),
                                     description: dictionary["description"] as? String,
                                     role: dictionary["role"] as? String,
                                     qualifier: qualifier)
        }
    }

    /// nil when the row has no usable identity or canonical link; such a row is hidden and counted.
    /// Otherwise the row is kept whatever its kind: classification happens here, once.
    static func reference(from object: [String: Any]) -> WallpaperReference? {
        guard let id = positiveInt(object["id"], maximum: 1_000_000_000),
              let pageText = object["url"] as? String, let page = URL(string: pageText), CMAURLPolicy.isAllowedPageURL(page) else { return nil }
        let web = rendition((object["images"] as? [String: Any])?["web"], kind: .web)
        // A print that metadata already shows can't be a faithful high-resolution JPEG (small, huge, over the byte cap, or
        // the size of the web thumbnail) is not a print: the row is thumbnail-only instead of offering a Set that must fail.
        let print = rendition((object["images"] as? [String: Any])?["print"], kind: .print).flatMap { candidate -> Rendition? in
            let webSize = web.map { ($0.width, $0.height) }
            guard CMAProvider.acceptsDimensions(decoded: (candidate.width, candidate.height), reported: (candidate.width, candidate.height), web: webSize),
                  Int64(candidate.fileSize ?? 0) <= CMAURLPolicy.maximumDownloadBytes else { return nil }
            return candidate
        }
        let record = CMARecord(
            creators: creators(object["creators"]),
            creationDate: object["creation_date"] as? String,
            accessionNumber: object["accession_number"] as? String,
            shareLicenseStatus: object["share_license_status"] as? String,
            hasWeb: web != nil, hasPrint: print != nil,
            webWidth: web?.width, webHeight: web?.height, printFileSize: print?.fileSize)
        // A row carries only the media addresses its kind earns: a thumbnail-only row has its web rendition, a
        // text-only row has none. Everything else is the record's own page, an inert placeholder that gated accessors
        // never turn into a media request.
        let kind = record.kind
        let thumbnail = kind == .metadataOnly ? nil : web
        let original = kind == .settable ? print : nil
        let size = original.map { ($0.width, $0.height) } ?? thumbnail.map { ($0.width, $0.height) } ?? (0, 0)
        return WallpaperReference(
            providerIdentifier: RemoteProviderID.cma.rawValue,
            wallpaperID: String(id),
            sourcePageURL: page,
            originalURL: original?.url ?? page,
            previewURL: thumbnail?.url ?? page,
            thumbnailURL: thumbnail?.url ?? page,
            width: size.0, height: size.1,
            uploader: nil, tags: [], cachedLocalPath: nil,
            title: object["title"] as? String,
            sourceName: nil,
            license: record.isCC0 ? "cc0" : (record.shareLicenseStatus.map { DisplayText.clean($0, limit: 40).lowercased() }),
            cma: record)
    }
}

// MARK: - Provider

struct CMACreatorPage: Equatable {
    let creatorID: Int
    /// The decoded creator-detail name.
    let name: String
    /// Rows whose record credits `creatorID` plainly, in the museum's order.
    let works: [WallpaperReference]
    /// The name search's own total: matches of the text, not a count of qualifying works.
    let matchTotal: Int?
    /// Rows the one bounded search page returned.
    let returnedCount: Int
    let hiddenCount: Int
    /// Rows that matched the name but not the creator ID plainly, by artwork ID; counted in diagnostics, never shown.
    let excluded: [Int: CMAExclusion]
    /// Artwork IDs on the creator's own stub list, for diagnostics only.
    let stubIDs: [Int]

    /// The search had more matches than the one page returned.
    var isTruncated: Bool { (matchTotal ?? 0) > returnedCount }
    /// Every shown row is explicit CC0, so "Open-access works" is true of the whole view.
    var allOpenAccess: Bool { works.allSatisfy { $0.cma?.isCC0 == true } }
}

enum CMAExclusion: String, Equatable {
    case otherCreator
    case qualifiedOrNonPlainRole
}

actor CMAProvider: RemoteWallpaperProvider {
    nonisolated let identifier = RemoteProviderID.cma.rawValue

    private let client: NetworkClient
    private var retryNotBefore: Date?

    init(client: NetworkClient = URLSessionNetworkClient(allowsRedirect: CMAURLPolicy.allowsRedirect)) {
        self.client = client
    }

    // MARK: Discover

    func search(options: CMASearchOptions, page: Int) async throws -> RemoteSearchPage {
        let requestedPage = max(1, page)
        let (data, _) = try await fetchJSON(CMAEndpoint.searchURL(options: options, page: requestedPage))
        let envelope = try Self.envelope(data)
        var kept: [WallpaperReference] = []
        var hidden = 0
        var seen = Set<String>()
        for row in envelope.rows {
            if let object = row as? [String: Any], let reference = CMAParsing.reference(from: object), seen.insert(reference.identityKey).inserted {
                kept.append(reference)
            } else {
                hidden += 1
            }
        }
        let total = envelope.total ?? kept.count
        let computedLast = total == 0 ? 0 : (total + CMAEndpoint.pageSize - 1) / CMAEndpoint.pageSize
        // A page with no rows ends pagination, whatever the total claims.
        let lastPage = envelope.rows.isEmpty ? min(requestedPage, computedLast) : computedLast
        return RemoteSearchPage(wallpapers: kept, currentPage: requestedPage, lastPage: lastPage, total: total,
                                rateLimit: ProviderRateLimit(limit: nil, remaining: nil, resetDate: nil), hiddenCount: hidden)
    }

    // MARK: Creator

    /// At most two requests: the creator's detail, then one bounded artist-name search. Rows are included only when
    /// their own record credits this exact creator ID with a plain role and no qualifier.
    func creatorWorks(id: Int) async throws -> CMACreatorPage {
        guard id > 0 else { throw RemoteProviderError.invalidData }
        let (detailData, _) = try await fetchJSON(CMAEndpoint.creatorURL(id: id))
        guard let root = try? JSONSerialization.jsonObject(with: detailData) as? [String: Any],
              let detail = root["data"] as? [String: Any],
              CMAParsing.positiveInt(detail["id"], maximum: 1_000_000_000) == id else { throw RemoteProviderError.invalidData }
        var name = DisplayText.clean(detail["name"] as? String)
        if name.isEmpty { name = CMADisplay.name(fromDescription: detail["description"] as? String) }
        guard !name.isEmpty else { throw RemoteProviderError.invalidData }
        let stubIDs = ((detail["artworks"] as? [Any]) ?? []).prefix(500).compactMap { entry -> Int? in
            guard let dictionary = entry as? [String: Any] else { return nil }
            return CMAParsing.positiveInt(dictionary["id"], maximum: 1_000_000_000)
        }

        let (searchData, _) = try await fetchJSON(CMAEndpoint.artistWorksURL(name: name))
        let envelope = try Self.envelope(searchData)
        var works: [WallpaperReference] = []
        var excluded: [Int: CMAExclusion] = [:]
        var hidden = 0
        var seen = Set<String>()
        for row in envelope.rows.prefix(CMAEndpoint.creatorWorksLimit) {
            guard let object = row as? [String: Any], let reference = CMAParsing.reference(from: object) else { hidden += 1; continue }
            guard let record = reference.cma, let artworkID = Int(reference.wallpaperID) else { hidden += 1; continue }
            if record.creditsPlainly(id: id) {
                if seen.insert(reference.identityKey).inserted { works.append(reference) }
            } else {
                excluded[artworkID] = record.mentions(id: id) ? .qualifiedOrNonPlainRole : .otherCreator
            }
        }
        return CMACreatorPage(creatorID: id, name: name, works: works, matchTotal: envelope.total,
                              returnedCount: min(envelope.rows.count, CMAEndpoint.creatorWorksLimit), hiddenCount: hidden,
                              excluded: excluded, stubIDs: Array(stubIDs))
    }

    // MARK: Detail

    /// One artwork's current record, by ID.
    func artwork(id: Int) async throws -> WallpaperReference {
        let (data, _) = try await fetchJSON(CMAEndpoint.artworkURL(id: id))
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let object = root["data"] as? [String: Any],
              let reference = CMAParsing.reference(from: object), Int(reference.wallpaperID) == id else { throw RemoteProviderError.invalidData }
        return reference
    }

    func fetchDetails(for reference: WallpaperReference) async throws -> WallpaperReference {
        guard reference.provider == .cma, let id = Int(reference.wallpaperID) else { throw RemoteProviderError.invalidData }
        var refreshed = try await artwork(id: id)
        refreshed.cachedLocalPath = reference.cachedLocalPath
        return refreshed
    }

    // MARK: Original (print JPEG)

    func downloadOriginal(for reference: WallpaperReference) async throws -> URL {
        try await downloadPrint(for: reference).file
    }

    /// Checks eligibility first (no request for a browse-only or untrusted reference), refreshes the artwork detail,
    /// re-checks CC0 and the print rendition, then streams the print JPEG under a hard cap and validates the bytes
    /// and pixels. Returns the refreshed record alongside the temporary file.
    func downloadPrint(for reference: WallpaperReference) async throws -> (file: URL, reference: WallpaperReference) {
        guard reference.provider == .cma, let id = Int(reference.wallpaperID) else { throw RemoteProviderError.untrustedURL }
        if let restriction = reference.cmaUseRestriction { throw restriction }
        let refreshed = try await fetchDetails(for: reference)
        guard refreshed.identityKey == reference.identityKey, refreshed.cmaUseRestriction == nil, refreshed.cma?.hasPrint == true else {
            throw RemoteProviderError.notOpenAccess
        }
        _ = id
        try Task.checkCancellation()
        try checkBackoff()
        var request = URLRequest(url: refreshed.originalURL)
        request.timeoutInterval = 30
        request.setValue("image/jpeg", forHTTPHeaderField: "Accept")
        request.setValue("Wallpier/0.2", forHTTPHeaderField: "User-Agent")
        let (temporaryURL, response) = try await client.boundedDownload(
            for: request, maximumBytes: CMAURLPolicy.maximumDownloadBytes, maximumRedirects: CMAURLPolicy.maximumRedirects)
        do {
            try validate(response)
            // The final response must be the very approved item and rendition path that was requested.
            guard let finalURL = response.url, CMAURLPolicy.isImageHostURL(finalURL), finalURL.path == refreshed.originalURL.path,
                  finalURL.query == nil else { throw RemoteProviderError.untrustedURL }
            let type = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            guard type == "image/jpeg" || type.hasPrefix("image/jpeg;") else { throw RemoteProviderError.mediaRejected }
            guard Self.isFaithfulPrint(at: temporaryURL, for: refreshed) else { throw RemoteProviderError.mediaRejected }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
        return (temporaryURL, refreshed)
    }

    // MARK: Local media checks

    /// Local-only checks, also run on cached bytes before a new Set: size within the cap and the reported size's
    /// allowance, a JPEG start marker, a decodable JPEG of the reported print dimensions (±2 px), a long edge of at
    /// least 1920 px, at most 80 MP, and not the web thumbnail standing in for the print.
    static func isFaithfulPrint(at url: URL, for reference: WallpaperReference) -> Bool {
        guard reference.provider == .cma, let record = reference.cma, record.hasPrint, record.hasWeb,
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value,
              size > 0, size <= CMAURLPolicy.maximumDownloadBytes else { return false }
        if let reported = record.printFileSize, Double(size) > Double(reported) * CMAURLPolicy.fileSizeAllowance { return false }
        guard startsWithJPEGMarker(url),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetStatus(source) == .statusComplete,
              (CGImageSourceGetType(source) as String?) == "public.jpeg", CGImageSourceGetCount(source) >= 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = properties[kCGImagePropertyPixelWidth] as? Int, var height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) { swap(&width, &height) }
        let web = record.webWidth.flatMap { w in record.webHeight.map { (w, $0) } }
        guard acceptsDimensions(decoded: (width, height), reported: (reference.width, reference.height), web: web) else { return false }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 32]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil
    }

    static func acceptsDimensions(decoded: (Int, Int), reported: (Int, Int), web: (Int, Int)?) -> Bool {
        let tolerance = CMAURLPolicy.dimensionTolerance
        guard decoded.0 > 0, decoded.1 > 0, reported.0 > 0, reported.1 > 0,
              abs(decoded.0 - reported.0) <= tolerance, abs(decoded.1 - reported.1) <= tolerance,
              max(decoded.0, decoded.1) >= CMAURLPolicy.minimumLongEdge,
              decoded.0 <= CMAURLPolicy.maximumPixels / decoded.1 else { return false }
        if let web, abs(decoded.0 - web.0) <= tolerance, abs(decoded.1 - web.1) <= tolerance { return false }
        return true
    }

    static func startsWithJPEGMarker(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 2), head.count == 2 else { return false }
        return head[head.startIndex] == 0xFF && head[head.startIndex + 1] == 0xD8
    }

    // MARK: Requests

    private static func envelope(_ data: Data) throws -> (rows: [Any], total: Int?) {
        guard data.count <= CMAURLPolicy.maximumResponseBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["data"] as? [Any] else { throw RemoteProviderError.invalidData }
        // A total that is present but malformed or overflow-prone fails the page rather than steering pagination.
        let rawTotal = (root["info"] as? [String: Any])?["total"]
        let total = CMAParsing.nonNegativeInt(rawTotal)
        if let rawTotal, !(rawTotal is NSNull), total == nil { throw RemoteProviderError.invalidData }
        return (rows, total)
    }

    private func fetchJSON(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        guard CMAURLPolicy.isAPIURL(url) else { throw RemoteProviderError.untrustedURL }
        try checkBackoff()
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Wallpier/0.2", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await client.data(for: request)
        try validate(response)
        guard let finalURL = response.url, CMAURLPolicy.isAPIURL(finalURL) else { throw RemoteProviderError.untrustedURL }
        return (data, response)
    }

    private func validate(_ response: HTTPURLResponse) throws {
        if response.statusCode == 429 {
            let delay = max(1, ProviderThrottle.retryAfter(from: response, maximum: RemoteProviderError.maximumOpenverseRetryDelay) ?? 60)
            retryNotBefore = Date().addingTimeInterval(delay)
            throw RemoteProviderError.rateLimited(retryAfter: delay)
        }
        switch response.statusCode {
        case 200...299: return
        case 300...399: throw RemoteProviderError.untrustedURL   // A redirect the policy refused.
        case 404, 410: throw RemoteProviderError.originalUnavailable
        default: throw RemoteProviderError.httpStatus(response.statusCode)
        }
    }

    private func checkBackoff() throws {
        if let retryNotBefore, retryNotBefore > Date() {
            throw RemoteProviderError.rateLimited(retryAfter: retryNotBefore.timeIntervalSinceNow)
        }
    }
}
