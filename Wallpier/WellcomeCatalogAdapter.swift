import Foundation

// Wellcome Collection images, as a catalog adapter.
//
// Search is `catalogue/v2/images` filtered to `locations.license=pdm,cc-0` with `include=source.contributors`. Each
// image's own IIIF location is re-checked row by row: an IIIF image location, licence exactly PDM or CC0, and only
// "open" access conditions. A contributor is the creator only when the record gives that contributor an actual role of
// Artist or Photographer (the live samples carry empty role lists, so most rows are credited to the collection only).
// True dimensions come from the IIIF v2 info.json, fetched on refresh only, never during search.

struct WellcomeCatalogAdapter: CatalogAdapter {
    static let apiHost = "api.wellcomecollection.org"
    static let iiifHost = "iiif.wellcomecollection.org"
    static let pageHost = "wellcomecollection.org"
    static let pageSize = 20
    static let maximumPages = 100
    static let allowedLicenses: [String: String] = ["pdm": "mark", "cc-0": "zero"]
    static let creatorRoles: Set<String> = ["artist", "photographer"]
    static let thumbnailSize = "!640,640"
    static let previewSize = "!1280,1280"

    var id: RemoteProviderID { .wellcome }
    var endpoint: URL { URL(string: "https://wellcomecollection.org/collections")! }
    var hosts: Set<String> { [Self.apiHost, Self.iiifHost] }

    // MARK: Typed records

    struct ImagesResponse: Decodable {
        let totalPages: Int?
        let totalResults: Int?
        let results: [ImageRecord]
    }

    struct ImageRecord: Decodable {
        let id: String
        let locations: [Location]?
        let source: Source?
    }

    struct Location: Decodable {
        struct License: Decodable { let id: String? }
        struct Condition: Decodable {
            struct Status: Decodable { let id: String? }
            let status: Status?
        }
        struct LocationType: Decodable { let id: String? }
        let url: String?
        let credit: String?
        let license: License?
        let accessConditions: [Condition]?
        let locationType: LocationType?
    }

    struct Source: Decodable {
        let id: String?
        let title: String?
        let contributors: [Contributor]?
    }

    struct Contributor: Decodable {
        struct Agent: Decodable { let id: String?; let label: String? }
        struct Role: Decodable { let label: String? }
        let agent: Agent?
        let roles: [Role]?
    }

    struct IIIFInfo: Decodable {
        let id: String?
        let width: Int?
        let height: Int?
        private enum CodingKeys: String, CodingKey { case id = "@id", width, height }
    }

    // MARK: Search

    func search(_ options: CatalogSearchOptions, page: Int, transport: CatalogTransport) async throws -> RemoteSearchPage {
        let requested = max(1, min(page, Self.maximumPages))
        var query = [URLQueryItem(name: "locations.license", value: "pdm,cc-0"),
                     URLQueryItem(name: "include", value: "source.contributors"),
                     URLQueryItem(name: "pageSize", value: String(Self.pageSize)),
                     URLQueryItem(name: "page", value: String(requested))]
        if let creator = options.creator {
            // Exact contributor ID; the role is still verified on every returned row below.
            query.append(URLQueryItem(name: "source.contributors.agent", value: creator.id))
        } else if !options.trimmedQuery.isEmpty {
            query.append(URLQueryItem(name: "query", value: options.trimmedQuery))
        }
        let response = try await transport.json(ImagesResponse.self, from: CatalogURL.make("https://\(Self.apiHost)/catalogue/v2/images", query))

        var wallpapers: [WallpaperReference] = []
        var hidden = 0
        var seen = Set<String>()
        for record in response.results.prefix(Self.pageSize) {
            guard let reference = Self.reference(from: record, width: 0, height: 0), seen.insert(reference.wallpaperID).inserted else { hidden += 1; continue }
            if let creator = options.creator, reference.catalog?.creator?.id != creator.id { hidden += 1; continue }
            wallpapers.append(reference)
        }
        let total = max(response.totalResults ?? wallpapers.count, 0)
        let computedLast = max(0, min(response.totalPages ?? 0, Self.maximumPages))
        let last = response.results.isEmpty ? min(requested, computedLast) : computedLast
        return RemoteSearchPage(wallpapers: wallpapers, currentPage: requested, lastPage: last, total: total,
                                rateLimit: ProviderRateLimit(limit: nil, remaining: nil, resetDate: nil), hiddenCount: hidden)
    }

    // MARK: Refresh

    func refresh(_ reference: WallpaperReference, transport: CatalogTransport) async throws -> WallpaperReference {
        guard reference.providerIdentifier == RemoteProviderID.wellcome.rawValue, Self.isSafeComponent(reference.wallpaperID) else {
            throw RemoteProviderError.unsupportedProvider
        }
        let url = CatalogURL.make("https://\(Self.apiHost)/catalogue/v2/images/\(reference.wallpaperID)",
                                  [URLQueryItem(name: "include", value: "source.contributors")])
        let record = try await transport.json(ImageRecord.self, from: url, revalidate: true)
        guard record.id == reference.wallpaperID, let location = Self.eligibleLocation(record), let iiifID = Self.iiifID(of: location) else {
            throw RemoteProviderError.notOpenAccess
        }
        // True dimensions, from the same IIIF image the record licenses.
        let infoURL = CatalogURL.make("https://\(Self.iiifHost)/image/\(iiifID)/info.json", [])
        let info = try await transport.json(IIIFInfo.self, from: infoURL, revalidate: true)
        guard let width = info.width, let height = info.height, width > 0, height > 0, width <= 100_000, height <= 100_000,
              info.id == nil || info.id == "https://\(Self.iiifHost)/image/\(iiifID)" else { throw RemoteProviderError.invalidData }
        guard let fresh = Self.reference(from: record, width: width, height: height) else { throw RemoteProviderError.notOpenAccess }
        return fresh
    }

    // MARK: URL policy

    func allowsMedia(_ url: URL, id: String, original: Bool) -> Bool {
        guard CatalogURL.isHTTPS(url), url.host?.lowercased() == Self.iiifHost, url.query == nil, url.fragment == nil else { return false }
        // /image/<iiif id>/full/<size>/0/default.jpg
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 7, parts[0].isEmpty, parts[1] == "image", Self.isSafeComponent(parts[2]), parts[3] == "full",
              parts[5] == "0", parts[6] == "default.jpg" else { return false }
        return original ? parts[4] == "full" : (parts[4] == Self.thumbnailSize || parts[4] == Self.previewSize)
    }

    func allowsPage(_ url: URL, id: String) -> Bool {
        guard CatalogURL.isHTTPS(url), url.host?.lowercased() == Self.pageHost, Self.isSafeComponent(id) else { return false }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0].isEmpty, parts[1] == "works", Self.isSafeComponent(parts[2]), parts[3] == "images" else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.count == 1 && items[0].name == "id" && items[0].value == id
    }

    static func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64 && value.unicodeScalars.allSatisfy {
            $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains(Character($0)) || $0 == "-" || $0 == "_")
        }
    }

    // MARK: Mapping

    /// The first IIIF image location that is PDM or CC0 and whose every access condition is "open".
    static func eligibleLocation(_ record: ImageRecord) -> Location? {
        (record.locations ?? []).first { location in
            guard location.locationType?.id == "iiif-image", let license = location.license?.id, allowedLicenses[license] != nil,
                  let conditions = location.accessConditions, !conditions.isEmpty else { return false }
            return conditions.allSatisfy { $0.status?.id == "open" } && iiifID(of: location) != nil
        }
    }

    /// `https://iiif.wellcomecollection.org/image/<ID>/info.json` -> `<ID>`; anything else is not a Wellcome image.
    static func iiifID(of location: Location) -> String? {
        guard let text = location.url, let url = URL(string: text), CatalogURL.isHTTPS(url), url.host?.lowercased() == iiifHost,
              url.query == nil else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0].isEmpty, parts[1] == "image", parts[3] == "info.json", isSafeComponent(parts[2]) else { return nil }
        return parts[2]
    }

    /// The first contributor with an agent ID and an actual Artist or Photographer role.
    static func creator(of source: Source?) -> CatalogCreator? {
        for contributor in source?.contributors ?? [] {
            guard let id = contributor.agent?.id, isSafeComponent(id),
                  let name = contributor.agent?.label?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  (contributor.roles ?? []).contains(where: { creatorRoles.contains(($0.label ?? "").trimmingCharacters(in: .whitespaces).lowercased()) })
            else { continue }
            return CatalogCreator(id: id, name: name)
        }
        return nil
    }

    static func reference(from record: ImageRecord, width: Int, height: Int) -> WallpaperReference? {
        guard isSafeComponent(record.id), let location = eligibleLocation(record), let iiif = iiifID(of: location),
              let licenseID = location.license?.id, let licenseDeed = allowedLicenses[licenseID],
              let workID = record.source?.id, isSafeComponent(workID),
              let original = URL(string: "https://\(iiifHost)/image/\(iiif)/full/full/0/default.jpg"),
              let preview = URL(string: "https://\(iiifHost)/image/\(iiif)/full/\(previewSize)/0/default.jpg"),
              let thumbnail = URL(string: "https://\(iiifHost)/image/\(iiif)/full/\(thumbnailSize)/0/default.jpg"),
              let page = URL(string: "https://\(pageHost)/works/\(workID)/images?id=\(record.id)") else { return nil }
        let creator = Self.creator(of: record.source)
        var credit = (location.credit?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "Wellcome Collection"
        if let creator { credit = "\(creator.name) · \(credit)" }
        let title = record.source?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return WallpaperReference(
            providerIdentifier: RemoteProviderID.wellcome.rawValue, wallpaperID: record.id, sourcePageURL: page,
            originalURL: original, previewURL: preview, thumbnailURL: thumbnail, width: width, height: height,
            uploader: creator?.name, tags: [], cachedLocalPath: nil,
            title: (title?.isEmpty ?? true) ? nil : title, sourceName: "Wellcome Collection", license: licenseID == "cc-0" ? "cc0" : "pdm",
            licenseVersion: "1.0", licenseURL: URL(string: "https://creativecommons.org/publicdomain/\(licenseDeed)/1.0/"),
            catalog: CatalogRecord(creator: creator, credit: credit, browseOnly: false))
    }
}
