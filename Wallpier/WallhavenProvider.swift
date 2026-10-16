import Foundation

enum WallhavenEndpoint {
    private static let baseURL = URL(string: "https://wallhaven.cc/api/v1")!

    static func searchURL(options: WallhavenSearchOptions, page: Int) -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("search"),
            resolvingAgainstBaseURL: false
        )!
        var items: [URLQueryItem] = []
        let query = options.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            items.append(URLQueryItem(name: "q", value: query))
        }
        items.append(URLQueryItem(name: "categories", value: options.category.rawValue))
        items.append(URLQueryItem(name: "purity", value: "100"))
        // Wallhaven returns an empty page for relevance without a query; show this month's top wallpapers.
        let sorting = query.isEmpty && options.sorting == .relevance ? WallhavenSorting.toplist : options.sorting
        items.append(URLQueryItem(name: "sorting", value: sorting.rawValue))
        items.append(URLQueryItem(name: "order", value: "desc"))
        if sorting == .toplist {
            items.append(URLQueryItem(name: "topRange", value: "1M"))
        }
        if let minimumResolution = options.minimumResolution {
            items.append(URLQueryItem(name: "atleast", value: minimumResolution))
        }
        if options.aspectRatio != .any {
            items.append(URLQueryItem(name: "ratios", value: options.aspectRatio.rawValue))
        }
        items.append(URLQueryItem(name: "page", value: String(max(1, page))))
        components.queryItems = items
        return components.url!
    }

    static func detailsURL(id: String) -> URL {
        baseURL.appendingPathComponent("w").appendingPathComponent(id)
    }
}

actor WallhavenProvider: RemoteWallpaperProvider {
    nonisolated let identifier = "wallhaven"

    private struct SearchCacheEntry {
        let insertedAt: Date
        let page: RemoteSearchPage
    }

    private let client: NetworkClient
    private let decoder = JSONDecoder()
    private let cacheLifetime: TimeInterval
    private var searchCache: [URL: SearchCacheEntry] = [:]
    private var detailCache: [String: WallpaperReference] = [:]
    private var retryNotBefore: Date?

    init(client: NetworkClient = URLSessionNetworkClient(), cacheLifetime: TimeInterval = 300) {
        self.client = client
        self.cacheLifetime = cacheLifetime
    }

    func search(options: WallhavenSearchOptions, page: Int) async throws -> RemoteSearchPage {
        let url = WallhavenEndpoint.searchURL(options: options, page: page)
        if let cached = searchCache[url], Date().timeIntervalSince(cached.insertedAt) < cacheLifetime {
            return cached.page
        }

        let (data, response) = try await dataWithTransientRetry(for: request(url: url))
        try validate(response)
        let payload: WallhavenSearchResponse
        do {
            payload = try decoder.decode(WallhavenSearchResponse.self, from: data)
        } catch {
            throw RemoteProviderError.invalidData
        }

        let wallpapers = try payload.data.map { try $0.reference(providerIdentifier: identifier) }
        let result = RemoteSearchPage(
            wallpapers: wallpapers,
            currentPage: payload.meta.currentPage,
            lastPage: payload.meta.lastPage,
            total: payload.meta.total,
            rateLimit: Self.rateLimit(from: response)
        )
        searchCache[url] = SearchCacheEntry(insertedAt: Date(), page: result)
        if searchCache.count > 12,
           let oldest = searchCache.min(by: { $0.value.insertedAt < $1.value.insertedAt })?.key {
            searchCache.removeValue(forKey: oldest)
        }
        return result
    }

    func fetchDetails(for reference: WallpaperReference) async throws -> WallpaperReference {
        if var cached = detailCache[reference.identityKey] {
            cached.cachedLocalPath = reference.cachedLocalPath
            return cached
        }

        let (data, response) = try await dataWithTransientRetry(
            for: request(url: WallhavenEndpoint.detailsURL(id: reference.wallpaperID))
        )
        try validate(response)
        let payload: WallhavenDetailResponse
        do {
            payload = try decoder.decode(WallhavenDetailResponse.self, from: data)
        } catch {
            throw RemoteProviderError.invalidData
        }
        var detailed = try payload.data.reference(providerIdentifier: identifier)
        detailed.cachedLocalPath = reference.cachedLocalPath
        detailCache[reference.identityKey] = detailed
        if detailCache.count > 100,
           let key = detailCache.keys.first(where: { $0 != reference.identityKey }) {
            detailCache.removeValue(forKey: key)
        }
        return detailed
    }

    func downloadOriginal(for reference: WallpaperReference) async throws -> URL {
        try checkBackoff()
        var downloadRequest = request(url: reference.originalURL)
        downloadRequest.setValue("image/*", forHTTPHeaderField: "Accept")
        let (temporaryURL, response) = try await client.download(for: downloadRequest)
        do {
            try validate(response)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
        guard response.expectedContentLength != 0 else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw RemoteProviderError.originalUnavailable
        }
        return temporaryURL
    }

    private func request(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Wallpier/0.2", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func dataWithTransientRetry(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var lastResult: (Data, HTTPURLResponse)?
        for attempt in 0..<2 {
            try Task.checkCancellation()
            try checkBackoff()
            let result = try await client.data(for: request)
            lastResult = result
            if attempt == 0, [502, 503, 504].contains(result.1.statusCode) {
                try await Task.sleep(nanoseconds: 750_000_000)
                continue
            }
            return result
        }
        return lastResult!
    }

    private func validate(_ response: HTTPURLResponse) throws {
        if response.statusCode == 429 {
            let delay = max(1, Self.retryAfter(from: response) ?? 60)
            retryNotBefore = Date().addingTimeInterval(delay)
            throw RemoteProviderError.rateLimited(retryAfter: delay)
        }
        let limits = Self.rateLimit(from: response)
        if limits.remaining == 0, let reset = limits.resetDate, reset > Date() {
            retryNotBefore = reset
        }
        guard (200...299).contains(response.statusCode) else {
            if response.statusCode == 404 {
                throw RemoteProviderError.originalUnavailable
            }
            throw RemoteProviderError.httpStatus(response.statusCode)
        }
    }

    private func checkBackoff() throws {
        if let retryNotBefore, retryNotBefore > Date() {
            throw RemoteProviderError.rateLimited(retryAfter: retryNotBefore.timeIntervalSinceNow)
        }
    }

    private static func rateLimit(from response: HTTPURLResponse) -> ProviderRateLimit {
        ProviderRateLimit(
            limit: integerHeader("x-ratelimit-limit", response: response),
            remaining: integerHeader("x-ratelimit-remaining", response: response),
            resetDate: resetDate(from: response)
        )
    }

    private static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else {
            if let reset = resetDate(from: response) {
                return max(0, reset.timeIntervalSinceNow)
            }
            return nil
        }
        if let seconds = TimeInterval(value) {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
    }

    private static func resetDate(from response: HTTPURLResponse) -> Date? {
        let names = ["x-ratelimit-reset", "ratelimit-reset"]
        for name in names {
            if let value = response.value(forHTTPHeaderField: name),
               let timestamp = TimeInterval(value) {
                return Date(timeIntervalSince1970: timestamp)
            }
        }
        return nil
    }

    private static func integerHeader(_ name: String, response: HTTPURLResponse) -> Int? {
        response.value(forHTTPHeaderField: name).flatMap(Int.init)
    }
}

private struct WallhavenSearchResponse: Decodable {
    let data: [WallhavenListing]
    let meta: Meta

    struct Meta: Decodable {
        let currentPage: Int
        let lastPage: Int
        let perPage: Int
        let total: Int
        let seed: String?

        private enum CodingKeys: String, CodingKey {
            case currentPage = "current_page"
            case lastPage = "last_page"
            case perPage = "per_page"
            case total, seed
        }
    }
}

private struct WallhavenDetailResponse: Decodable {
    let data: WallhavenListing
}

private struct WallhavenListing: Decodable {
    let id: String
    let url: URL
    let path: URL
    let dimensionX: Int
    let dimensionY: Int
    let thumbs: Thumbnails
    let uploader: Uploader?
    let tags: [Tag]?

    struct Thumbnails: Decodable {
        let large: URL
        let small: URL
    }

    struct Uploader: Decodable {
        let username: String
    }

    struct Tag: Decodable {
        let name: String
    }

    private enum CodingKeys: String, CodingKey {
        case id, url, path, thumbs, uploader, tags
        case dimensionX = "dimension_x"
        case dimensionY = "dimension_y"
    }

    func reference(providerIdentifier: String) throws -> WallpaperReference {
        WallpaperReference(
            providerIdentifier: providerIdentifier,
            wallpaperID: id,
            sourcePageURL: url,
            originalURL: path,
            previewURL: thumbs.large,
            thumbnailURL: thumbs.small,
            width: dimensionX,
            height: dimensionY,
            uploader: uploader?.username,
            tags: tags?.prefix(8).map(\.name) ?? [],
            cachedLocalPath: nil
        )
    }
}
