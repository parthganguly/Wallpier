import Foundation

struct INaturalistCatalogAdapter: CatalogAdapter {
    let id: RemoteProviderID = .inaturalist
    let endpoint = URL(string: "https://www.inaturalist.org/observations")!
    let hosts: Set<String> = ["api.inaturalist.org", "inaturalist-open-data.s3.amazonaws.com", "www.inaturalist.org"]

    private static let api = "https://api.inaturalist.org/v2/observations"
    private static let bucket = "https://inaturalist-open-data.s3.amazonaws.com/photos"
    // A field projection also keeps location, observer profiles and identification histories off the wire.
    private static let fields = "id,taxon.name,taxon.preferred_common_name,photos.id,photos.url,photos.license_code,photos.hidden,photos.attribution,photos.original_dimensions.width,photos.original_dimensions.height"
    private static let throttle = INaturalistThrottle()

    func search(_ options: CatalogSearchOptions, page: Int, transport: CatalogTransport) async throws -> RemoteSearchPage {
        let pageSize = 20
        guard options.creator == nil, (1...(10_000 / pageSize)).contains(page) else {
            throw RemoteProviderError.invalidData
        }
        var query = [
            URLQueryItem(name: "fields", value: Self.fields),
            URLQueryItem(name: "photo_license", value: "cc0"),
            URLQueryItem(name: "photos", value: "true"),
            URLQueryItem(name: "quality_grade", value: "research"),
            URLQueryItem(name: "order_by", value: "votes"),
            URLQueryItem(name: "per_page", value: String(pageSize)),
            URLQueryItem(name: "page", value: String(page))
        ]
        if options.trimmedQuery.isEmpty {
            query.append(URLQueryItem(name: "taxon_id", value: "3")) // Birds
        } else {
            query.append(URLQueryItem(name: "q", value: options.trimmedQuery))
            query.append(URLQueryItem(name: "search_on", value: "names"))
        }
        try await Self.throttle.waitForTurn()
        let response = try await transport.json(ObservationPage.self, from: CatalogURL.make(Self.api, query))
        guard response.page == page, response.total_results >= 0 else { throw RemoteProviderError.invalidData }
        // One eligible photo per observation keeps browsing and pagination in the same units.
        let references = response.results.compactMap { observation in
            observation.photos?.lazy.compactMap { self.reference(observation, photo: $0) }.first
        }
        let lastPage = max(1, (min(response.total_results, 10_000) + pageSize - 1) / pageSize)
        return RemoteSearchPage(wallpapers: references, currentPage: page, lastPage: lastPage,
                                total: response.total_results, rateLimit: ProviderRateLimit(limit: nil, remaining: nil, resetDate: nil),
                                hiddenCount: response.results.count - references.count)
    }

    func refresh(_ reference: WallpaperReference, transport: CatalogTransport) async throws -> WallpaperReference {
        guard reference.providerIdentifier == id.rawValue, let key = PhotoKey(reference.wallpaperID) else {
            throw RemoteProviderError.notOpenAccess
        }
        let query = [URLQueryItem(name: "id", value: String(key.observation)),
                     URLQueryItem(name: "fields", value: Self.fields), URLQueryItem(name: "per_page", value: "1")]
        try await Self.throttle.waitForTurn()
        let result = try await transport.json(ObservationPage.self, from: CatalogURL.make(Self.api, query), revalidate: true)
        guard let observation = result.results.first(where: { $0.id == key.observation }),
              let photo = observation.photos?.first(where: { $0.id == key.photo }),
              let refreshed = self.reference(observation, photo: photo) else { throw RemoteProviderError.notOpenAccess }
        return refreshed
    }

    func allowsMedia(_ url: URL, id: String, original: Bool) -> Bool {
        guard let key = PhotoKey(id), let ext = Self.imageExtension(url) else { return false }
        let renditions = original ? ["original"] : ["medium", "large"]
        return renditions.contains { url.absoluteString == "\(Self.bucket)/\(key.photo)/\($0).\(ext)" }
    }

    func allowsPage(_ url: URL, id: String) -> Bool {
        guard let key = PhotoKey(id) else { return false }
        return url.absoluteString == "\(endpoint.absoluteString)/\(key.observation)"
    }

    private static func imageExtension(_ url: URL) -> String? {
        let ext = url.pathExtension
        return ["jpg", "jpeg", "png"].contains(ext) ? ext : nil
    }

    private func reference(_ observation: Observation, photo: Photo) -> WallpaperReference? {
        guard observation.id > 0, photo.id > 0, photo.hidden == false, photo.license_code == "cc0",
              let credit = photo.attribution?.trimmingCharacters(in: .whitespacesAndNewlines), !credit.isEmpty,
              let raw = photo.url, let square = URL(string: raw), let ext = Self.imageExtension(square),
              raw == "\(Self.bucket)/\(photo.id)/square.\(ext)" else { return nil }
        let directory = square.deletingLastPathComponent()
        let preview = directory.appendingPathComponent("large.\(ext)")
        let dimensions = photo.original_dimensions
        let hasDimensions = (dimensions?.width ?? 0) > 0 && (dimensions?.height ?? 0) > 0
        return WallpaperReference(
            providerIdentifier: id.rawValue, wallpaperID: "\(observation.id)-\(photo.id)",
            sourcePageURL: endpoint.appendingPathComponent(String(observation.id)),
            originalURL: directory.appendingPathComponent("original.\(ext)"), previewURL: preview,
            thumbnailURL: directory.appendingPathComponent("medium.\(ext)"),
            width: hasDimensions ? dimensions?.width ?? 0 : 0, height: hasDimensions ? dimensions?.height ?? 0 : 0,
            uploader: nil, tags: [], cachedLocalPath: nil, uncroppedPreviewURL: preview,
            title: observation.taxon?.preferred_common_name ?? observation.taxon?.name ?? "Nature observation",
            sourceName: "iNaturalist", license: "cc0", licenseVersion: "1.0",
            licenseURL: URL(string: "https://creativecommons.org/publicdomain/zero/1.0/"),
            catalog: CatalogRecord(credit: credit)
        )
    }

    private struct PhotoKey {
        let observation: Int
        let photo: Int

        init?(_ key: String) {
            let parts = key.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 2, let observation = Int(parts[0]), let photo = Int(parts[1]),
                  observation > 0, photo > 0, key == "\(observation)-\(photo)" else { return nil }
            self.observation = observation
            self.photo = photo
        }
    }

    private struct ObservationPage: Decodable {
        let total_results: Int
        let page: Int
        let results: [Observation]
    }

    private struct Observation: Decodable {
        let id: Int
        let taxon: Taxon?
        let photos: [Photo]?
    }

    private struct Taxon: Decodable {
        let name: String?
        let preferred_common_name: String?
    }

    private struct Photo: Decodable {
        let id: Int
        let url: String?
        let license_code: String?
        let attribution: String?
        let hidden: Bool?
        let original_dimensions: Dimensions?
    }

    private struct Dimensions: Decodable {
        let width: Int?
        let height: Int?
    }
}

private actor INaturalistThrottle {
    private var nextStart: UInt64 = 0

    func waitForTurn() async throws {
        while true {
            try Task.checkCancellation()
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= nextStart {
                nextStart = now + 1_000_000_000
                return
            }
            // Multiple suspended callers may wake together. Recheck under actor isolation.
            try await Task.sleep(nanoseconds: nextStart - now)
        }
    }
}
