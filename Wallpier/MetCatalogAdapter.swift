import Foundation

// The Metropolitan Museum of Art Open Access, as a catalog adapter.
//
// Search is `v1.1/search` (IDs only, offset+limit <= 20); every ID is then resolved through `v1/objects/{id}`, two at a
// time, and kept only when the object's own record says `isPublicDomain == true` and carries a real `primaryImage`
// (so the blank-image public-domain case is dropped). "More by" is a name query whose rows are post-filtered on the
// exact constituent ID with the exact role "Artist".

struct MetCatalogAdapter: CatalogAdapter {
    static let apiHost = "collectionapi.metmuseum.org"
    static let imageHost = "images.metmuseum.org"
    static let pageHost = "www.metmuseum.org"
    static let pageSize = 20
    static let maximumPages = 100
    /// What a blank search shows: a recognizable, public-domain-rich landscape set.
    static let defaultQuery = "Van Gogh landscape"
    static let artistRole = "Artist"
    static let licenseURL = URL(string: "https://creativecommons.org/publicdomain/zero/1.0/")!

    var id: RemoteProviderID { .met }
    var endpoint: URL { URL(string: "https://www.metmuseum.org/art/collection/search")! }
    var hosts: Set<String> { [Self.apiHost, Self.imageHost] }

    // MARK: Typed records

    struct SearchResponse: Decodable {
        let total: Int?
        let objectIDs: [Int]?
    }

    struct Constituent: Decodable {
        let constituentID: Int?
        let role: String?
        let name: String?
    }

    struct MetObject: Decodable {
        let objectID: Int
        let isPublicDomain: Bool?
        let primaryImage: String?
        let primaryImageSmall: String?
        let title: String?
        let objectURL: String?
        let objectDate: String?
        let creditLine: String?
        let artistDisplayName: String?
        let repository: String?
        let constituents: [Constituent]?
    }

    // MARK: Search

    func search(_ options: CatalogSearchOptions, page: Int, transport: CatalogTransport) async throws -> RemoteSearchPage {
        let requested = max(1, min(page, Self.maximumPages))
        let creator = options.creator
        let text = creator?.name ?? (options.trimmedQuery.isEmpty ? Self.defaultQuery : options.trimmedQuery)
        var query = [URLQueryItem(name: "hasImages", value: "true"), URLQueryItem(name: "q", value: text)]
        if creator != nil { query.insert(URLQueryItem(name: "artistOrCulture", value: "true"), at: 0) }
        query += [URLQueryItem(name: "offset", value: String((requested - 1) * Self.pageSize)),
                  URLQueryItem(name: "limit", value: String(Self.pageSize))]
        let response = try await transport.json(SearchResponse.self, from: CatalogURL.make("https://\(Self.apiHost)/public/collection/v1.1/search", query))

        // Never trust a server to honor `limit`: at most one page of IDs, unique, positive.
        var seenIDs = Set<Int>()
        let ids = (response.objectIDs ?? []).filter { $0 > 0 && seenIDs.insert($0).inserted }.prefix(Self.pageSize)
        let objects = try await Self.objects(Array(ids), transport: transport, revalidate: false)

        var wallpapers: [WallpaperReference] = []
        var hidden = 0
        for object in objects {
            guard let object, let reference = Self.reference(from: object) else { hidden += 1; continue }
            if let creator, reference.catalog?.creator?.id != creator.id { hidden += 1; continue }
            wallpapers.append(reference)
        }
        let total = max(response.total ?? wallpapers.count, 0)
        let computedLast = total == 0 ? 0 : min((total - 1) / Self.pageSize + 1, Self.maximumPages)
        let last = ids.isEmpty ? min(requested, computedLast) : computedLast
        return RemoteSearchPage(wallpapers: wallpapers, currentPage: requested, lastPage: last, total: total,
                                rateLimit: ProviderRateLimit(limit: nil, remaining: nil, resetDate: nil), hiddenCount: hidden)
    }

    // MARK: Refresh

    func refresh(_ reference: WallpaperReference, transport: CatalogTransport) async throws -> WallpaperReference {
        guard reference.providerIdentifier == RemoteProviderID.met.rawValue, let objectID = Int(reference.wallpaperID), objectID > 0 else {
            throw RemoteProviderError.unsupportedProvider
        }
        let object = try await transport.json(MetObject.self, from: Self.objectURL(objectID), revalidate: true)
        guard object.objectID == objectID, let fresh = Self.reference(from: object) else { throw RemoteProviderError.notOpenAccess }
        return fresh
    }

    // MARK: URL policy

    func allowsMedia(_ url: URL, id: String, original: Bool) -> Bool {
        guard CatalogURL.isHTTPS(url), url.host?.lowercased() == Self.imageHost, url.query == nil, url.fragment == nil else { return false }
        // /CRDImages/<department>/<original|web-large>/<file>
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5, parts[0].isEmpty, parts[1] == "CRDImages", parts[3] == (original ? "original" : "web-large") else { return false }
        return Self.isSafeComponent(parts[2]) && Self.isSafeComponent(parts[4])
            && ["jpg", "jpeg", "png"].contains(url.pathExtension.lowercased())
    }

    func allowsPage(_ url: URL, id: String) -> Bool {
        CatalogURL.isHTTPS(url) && url.host?.lowercased() == Self.pageHost && url.query == nil
            && url.path == "/art/collection/search/\(id)" && Int(id) != nil
    }

    private static func isSafeComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else { return false }
        return value.unicodeScalars.allSatisfy { ($0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains(Character($0)))) || "._-".unicodeScalars.contains($0) }
    }

    // MARK: Mapping

    static func objectURL(_ id: Int) -> URL {
        CatalogURL.make("https://\(apiHost)/public/collection/v1/objects/\(id)", [])
    }

    /// Compound and qualified credits remain visible without opening an ambiguous creator view.
    static func creator(of object: MetObject) -> CatalogCreator? {
        let names = (object.constituents ?? []).filter { $0.role == artistRole }
        guard names.count == 1, let constituent = names.first, let id = constituent.constituentID, id > 0,
              let name = constituent.name, !DisplayText.clean(name).isEmpty,
              DisplayText.clean(name) == DisplayText.clean(object.artistDisplayName) else { return nil }
        return CatalogCreator(id: String(id), name: name)
    }

    /// nil unless the record is public domain with an eligible original and thumbnail on the exact media paths.
    static func reference(from object: MetObject) -> WallpaperReference? {
        let adapter = MetCatalogAdapter()
        let identifier = String(object.objectID)
        guard object.objectID > 0, object.isPublicDomain == true,
              let originalText = object.primaryImage, let original = URL(string: originalText), adapter.allowsMedia(original, id: identifier, original: true),
              let smallText = object.primaryImageSmall, let small = URL(string: smallText), adapter.allowsMedia(small, id: identifier, original: false),
              let pageText = object.objectURL, let page = URL(string: pageText), adapter.allowsPage(page, id: identifier) else { return nil }
        let creator = creator(of: object)
        let artist = object.artistDisplayName.flatMap { DisplayText.clean($0).isEmpty ? nil : $0 }
        let title = object.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        if let artist { parts.append(artist) }
        parts.append("The Metropolitan Museum of Art")
        if let line = object.creditLine?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty { parts.append(line) }
        return WallpaperReference(
            providerIdentifier: RemoteProviderID.met.rawValue, wallpaperID: identifier, sourcePageURL: page,
            originalURL: original, previewURL: small, thumbnailURL: small, width: 0, height: 0,
            uploader: artist, tags: [], cachedLocalPath: nil,
            title: (title?.isEmpty ?? true) ? nil : title, sourceName: "The Metropolitan Museum of Art", license: "cc0",
            licenseVersion: "1.0", licenseURL: licenseURL,
            catalog: CatalogRecord(creator: creator, credit: parts.joined(separator: " · "), browseOnly: false))
    }

    // MARK: Detail fetching (two-wide, small cache)

    private static func objects(_ ids: [Int], transport: CatalogTransport, revalidate: Bool) async throws -> [MetObject?] {
        var results: [MetObject?] = []
        var index = 0
        while index < ids.count {
            if index + 1 < ids.count {
                let firstID = ids[index]
                let secondID = ids[index + 1]
                async let first = detail(firstID, transport: transport, revalidate: revalidate)
                async let second = detail(secondID, transport: transport, revalidate: revalidate)
                let pair = try await (first, second)
                results += [pair.0, pair.1]
                index += 2
            } else {
                results.append(try await detail(ids[index], transport: transport, revalidate: revalidate))
                index += 1
            }
        }
        return results
    }

    /// nil for an object the museum can't serve (gone or malformed); throttling and cancellation still propagate.
    private static func detail(_ id: Int, transport: CatalogTransport, revalidate: Bool) async throws -> MetObject? {
        if !revalidate, let cached = MetObjectCache.shared.object(id) { return cached }
        do {
            let object = try await transport.json(MetObject.self, from: objectURL(id), revalidate: revalidate)
            guard object.objectID == id else { return nil }
            MetObjectCache.shared.store(object)
            return object
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as RemoteProviderError {
            if case .rateLimited = error { throw error }
            return nil
        } catch is DecodingError {
            return nil
        }
    }
}

/// A small, bounded cache of object details so paging back or filtering the same artist doesn't refetch them.
private final class MetObjectCache {
    static let shared = MetObjectCache()
    private let lock = NSLock()
    private var storage: [Int: MetCatalogAdapter.MetObject] = [:]
    private var order: [Int] = []
    private let capacity = 200

    func object(_ id: Int) -> MetCatalogAdapter.MetObject? {
        lock.lock(); defer { lock.unlock() }
        return storage[id]
    }

    func store(_ object: MetCatalogAdapter.MetObject) {
        lock.lock(); defer { lock.unlock() }
        if storage.updateValue(object, forKey: object.objectID) == nil { order.append(object.objectID) }
        while order.count > capacity { storage[order.removeFirst()] = nil }
    }
}
