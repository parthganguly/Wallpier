import Foundation
import ImageIO

/// Which URLs Wallpier will request for Openverse results. The index aggregates many sites, so its image
/// URLs are not trusted as given: originals come only over HTTPS from a curated CDN list per source, and a
/// redirect must stay within the same policy. Everything else is still shown in the source's own page.
enum OpenverseURLPolicy {
    static let apiHost = "api.openverse.org"
    static let discoverySource = "wikimedia"
    static let commonsThumbnailHost = "thumb.wikimedia.org"

    /// Image hosts per Openverse source. A leading dot matches that domain's subdomains.
    static let imageHosts: [String: [String]] = [
        "wikimedia": ["upload.wikimedia.org"],
        "flickr": [".staticflickr.com"],
        "stocksnap": ["cdn.stocksnap.io"],
        "rawpixel": ["images.rawpixel.com"]
    ]

    /// Landing (source-page) hosts per source; opened in the browser only when they match.
    static let landingHosts: [String: [String]] = [
        "wikimedia": ["commons.wikimedia.org"],
        "flickr": ["www.flickr.com", "flickr.com"],
        "stocksnap": ["stocksnap.io"],
        "rawpixel": ["www.rawpixel.com", "rawpixel.com"]
    ]

    /// The only license deeds Wallpier treats as confirming the reported code.
    static let canonicalLicenseURLs = [
        "cc0": "https://creativecommons.org/publicdomain/zero/1.0/",
        "pdm": "https://creativecommons.org/publicdomain/mark/1.0/"
    ]

    static let sourceNames = [
        "wikimedia": "Wikimedia Commons", "flickr": "Flickr", "stocksnap": "StockSnap", "rawpixel": "rawpixel"
    ]

    static func isSafeHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443) && !(url.host ?? "").isEmpty
    }

    static func isAllowedImageURL(_ url: URL, source: String) -> Bool {
        guard isSafeHTTPS(url), let host = url.host?.lowercased(), let hosts = imageHosts[source] else { return false }
        return hosts.contains { $0.hasPrefix(".") ? host.hasSuffix($0) : host == $0 }
    }

    static func isThumbnailOnly(_ url: URL, source: String?) -> Bool {
        (source == "stocksnap" && url.path.hasPrefix("/img-thumbs/"))
            || (source == discoverySource && url.path.hasPrefix("/wikipedia/commons/thumb/"))
    }

    /// Wikimedia's documented standard-width JPEG thumbnail path, using the original's catalogued shard and filename.
    /// See https://wikitech.wikimedia.org/wiki/Image_scalers and https://www.mediawiki.org/wiki/Common_thumbnail_sizes.
    static func commonsThumbnail(for original: URL) -> URL? {
        guard isAllowedImageURL(original, source: discoverySource),
              var components = URLComponents(url: original, resolvingAgainstBaseURL: false) else { return nil }
        let parts = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 6, parts[0].isEmpty, parts[1] == "wikipedia", parts[2] == "commons",
              parts[3].range(of: "^[a-f0-9]$", options: .regularExpression) != nil,
              parts[4].range(of: "^[a-f0-9]{2}$", options: .regularExpression) != nil, parts[4].hasPrefix(parts[3]),
              let name = parts[5].removingPercentEncoding,
              !name.contains("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              ["jpg", "jpeg"].contains(original.pathExtension.lowercased()) else { return nil }
        components.host = commonsThumbnailHost
        components.percentEncodedPath = "/wikipedia/commons/thumb/\(parts[3])/\(parts[4])/\(parts[5])/500px-\(parts[5])"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func isAllowedLandingURL(_ url: URL, source: String?) -> Bool {
        guard isSafeHTTPS(url), let source, let host = url.host?.lowercased(), let hosts = landingHosts[source] else { return false }
        return hosts.contains(host)
    }

    /// The reported code, version (if any) and URL name the same known deed. A missing, different or decorated URL doesn't.
    static func isCanonicalLicenseURL(_ url: URL?, license: String?, version: String?) -> Bool {
        guard let url, let license, let canonical = canonicalLicenseURLs[license.lowercased()],
              version == nil || version == "1.0",
              url.query == nil, url.fragment == nil, isSafeHTTPS(url), url.host?.lowercased() == "creativecommons.org" else { return false }
        let path = url.path.hasSuffix("/") ? url.path : url.path + "/"
        let deed = "https://creativecommons.org" + path
        return deed == canonical || deed == canonical + "deed.en/"
    }

    /// API and thumbnail requests stay on the API host; an original's redirect stays on its source's CDN.
    static func allowsRedirect(from original: URL, to target: URL) -> Bool {
        if original.host?.lowercased() == apiHost { return isSafeHTTPS(target) && target.host?.lowercased() == apiHost }
        guard let source = imageHosts.keys.first(where: { isAllowedImageURL(original, source: $0) }) else { return false }
        return isAllowedImageURL(target, source: source)
    }
}

enum OpenverseEndpoint {
    static let pageSize = 20
    private static let baseURL = URL(string: "https://api.openverse.org/v1/images/")!

    /// Openly licensed Commons JPEGs suited to a desktop. `filter_dead` and relevance ordering are the API's defaults.
    static func searchURL(options: OpenverseSearchOptions, page: Int) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = []
        if !options.trimmedQuery.isEmpty { items.append(URLQueryItem(name: "q", value: options.trimmedQuery)) }
        items += [
            URLQueryItem(name: "page", value: String(max(1, page))),
            URLQueryItem(name: "page_size", value: String(pageSize)),
            URLQueryItem(name: "extension", value: "jpg,jpeg"),
            URLQueryItem(name: "aspect_ratio", value: "wide"),
            URLQueryItem(name: "size", value: "large"),
            URLQueryItem(name: "license", value: options.license.rawValue),
            URLQueryItem(name: "mature", value: "false"),
            URLQueryItem(name: "source", value: OpenverseURLPolicy.discoverySource)
        ]
        components.queryItems = items
        // URLComponents leaves a literal + alone, which the API's query parsing reads as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    static func detailsURL(id: UUID) -> URL {
        baseURL.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    /// Built from the validated identifier rather than trusting the response's `thumbnail` field.
    static func thumbnailURL(id: UUID) -> URL {
        detailsURL(id: id).appendingPathComponent("thumb", isDirectory: true)
    }
}

actor OpenverseProvider: RemoteWallpaperProvider {
    nonisolated let identifier = RemoteProviderID.openverse.rawValue
    /// An original larger than Wallpier's durable store could never be retained for the desktop.
    static let maximumOriginalBytes = WallpaperHistoryStore.maximumSizeBytes

    private let client: NetworkClient
    private let decoder = JSONDecoder()
    private var detailCache: [String: WallpaperReference] = [:]
    private enum Origin { case api, originals }
    private var retryNotBefore: [Origin: Date] = [:]

    init(client: NetworkClient = URLSessionNetworkClient(allowsRedirect: OpenverseURLPolicy.allowsRedirect)) {
        self.client = client
    }

    func search(options: OpenverseSearchOptions, page: Int) async throws -> RemoteSearchPage {
        let (data, response) = try await dataWithTransientRetry(for: request(url: OpenverseEndpoint.searchURL(options: options, page: page)))
        try validate(response)
        let requestedPage = max(1, page)
        // Only the page that was asked for advances pagination.
        guard let payload = try? decoder.decode(OpenverseSearchResponse.self, from: data),
              payload.page == nil || payload.page == requestedPage else { throw RemoteProviderError.invalidData }
        let licenses = Set(options.license.rawValue.split(separator: ",").map(String.init))
        let wallpapers = payload.results.compactMap { entry -> WallpaperReference? in
            guard let reference = entry.value?.reference(allowedLicenses: licenses),
                  reference.sourceName == OpenverseURLPolicy.discoverySource,
                  OpenverseURLPolicy.commonsThumbnail(for: reference.originalURL) != nil else { return nil }
            return reference
        }
        let currentPage = requestedPage
        return RemoteSearchPage(
            wallpapers: wallpapers,
            currentPage: currentPage,
            lastPage: max(0, payload.pageCount),
            total: max(0, payload.resultCount),
            rateLimit: ProviderRateLimit(limit: nil, remaining: nil, resetDate: nil),
            hiddenCount: payload.results.count - wallpapers.count
        )
    }

    func fetchDetails(for reference: WallpaperReference) async throws -> WallpaperReference {
        if var cached = detailCache[reference.identityKey] {
            cached.cachedLocalPath = reference.cachedLocalPath
            return cached
        }
        guard let id = UUID(uuidString: reference.wallpaperID) else { throw RemoteProviderError.invalidData }
        let (data, response) = try await dataWithTransientRetry(for: request(url: OpenverseEndpoint.detailsURL(id: id)))
        try validate(response)
        // A work whose metadata no longer verifies is reported, never patched with other values.
        guard var detailed = (try? decoder.decode(OpenverseImage.self, from: data))?.reference(allowedLicenses: ["cc0", "pdm"]),
              detailed.identityKey == reference.identityKey else { throw RemoteProviderError.invalidData }
        detailed.cachedLocalPath = reference.cachedLocalPath
        detailCache[reference.identityKey] = detailed
        if detailCache.count > 100, let key = detailCache.keys.first(where: { $0 != reference.identityKey }) {
            detailCache.removeValue(forKey: key)
        }
        return detailed
    }

    /// Downloads only this original, re-checking a saved reference's URL and license, the final URL after
    /// redirects, the size, and that the bytes are an image of the reported shape.
    func downloadOriginal(for reference: WallpaperReference) async throws -> URL {
        guard reference.providerIdentifier == identifier, let source = reference.sourceName,
              OpenverseURLPolicy.isAllowedImageURL(reference.originalURL, source: source) else {
            throw RemoteProviderError.untrustedURL
        }
        if let restriction = reference.useRestriction { throw restriction }
        try checkBackoff(.originals)
        var downloadRequest = request(url: reference.originalURL)
        downloadRequest.setValue("image/*", forHTTPHeaderField: "Accept")
        let (temporaryURL, response) = try await client.download(for: downloadRequest)
        do {
            try validate(response, origin: .originals)
            guard let finalURL = response.url, OpenverseURLPolicy.isAllowedImageURL(finalURL, source: source) else {
                throw RemoteProviderError.untrustedURL
            }
            guard !OpenverseURLPolicy.isThumbnailOnly(finalURL, source: source) else {
                throw RemoteProviderError.originalUnavailable
            }
            if let type = response.value(forHTTPHeaderField: "Content-Type"), !type.lowercased().hasPrefix("image/") {
                throw RemoteProviderError.invalidData
            }
            guard response.expectedContentLength != 0 else { throw RemoteProviderError.originalUnavailable }
            guard response.expectedContentLength <= Self.maximumOriginalBytes,
                  Self.isFaithfulOriginal(at: temporaryURL, for: reference) else { throw RemoteProviderError.invalidData }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
        return temporaryURL
    }

    /// The file is a decodable raster within the size bound whose orientation-corrected pixel size is exactly the
    /// reported width and height, so a stale, substituted or downsized file is never taken for the original.
    static func isFaithfulOriginal(at url: URL, for reference: WallpaperReference) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value,
              size > 0, size <= maximumOriginalBytes,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = properties[kCGImagePropertyPixelWidth] as? Int, var height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, reference.width > 0, reference.height > 0 else { return false }
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) { swap(&width, &height) }
        guard width == reference.width, height == reference.height else { return false }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 32]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil
    }

    private func request(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Wallpier/0.2 (https://github.com/parthganguly/Wallpier)", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// One bounded retry for a transient gateway failure; 429 is never retried, it holds requests back instead.
    private func dataWithTransientRetry(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        try checkBackoff(.api)
        let result = try await client.data(for: request)
        guard [502, 503, 504].contains(result.1.statusCode) else { return result }
        try await Task.sleep(nanoseconds: 750_000_000)
        try checkBackoff(.api)
        return try await client.data(for: request)
    }

    private func validate(_ response: HTTPURLResponse, origin: Origin = .api) throws {
        if response.statusCode == 429 {
            let delay = max(1, ProviderThrottle.retryAfter(from: response, maximum: RemoteProviderError.maximumOpenverseRetryDelay) ?? 60)
            retryNotBefore[origin] = Date().addingTimeInterval(delay)
            throw RemoteProviderError.rateLimited(retryAfter: delay)
        }
        switch response.statusCode {
        case 200...299: return
        case 300...399: throw RemoteProviderError.untrustedURL   // A redirect the policy refused.
        case 404, 410: throw RemoteProviderError.originalUnavailable
        default: throw RemoteProviderError.httpStatus(response.statusCode)
        }
    }

    private func checkBackoff(_ origin: Origin) throws {
        if let retryNotBefore = retryNotBefore[origin], retryNotBefore > Date() {
            throw RemoteProviderError.rateLimited(retryAfter: retryNotBefore.timeIntervalSinceNow)
        }
    }
}

private struct OpenverseSearchResponse: Decodable {
    let resultCount: Int
    let pageCount: Int
    let page: Int?
    let results: [Lenient]

    /// One malformed result hides that result, not the page.
    struct Lenient: Decodable {
        let value: OpenverseImage?
        init(from decoder: Decoder) throws { value = try? OpenverseImage(from: decoder) }
    }

    private enum CodingKeys: String, CodingKey {
        case resultCount = "result_count", pageCount = "page_count", page, results
    }
}

private struct OpenverseImage: Decodable {
    let id: String?
    let title: String?
    let url: String?
    let foreignLandingURL: String?
    let creator: String?
    let license: String?
    let licenseVersion: String?
    let licenseURL: String?
    let source: String?
    let width: Int?
    let height: Int?
    let mature: Bool?
    let tags: [Tag]?

    struct Tag: Decodable { let name: String? }

    private enum CodingKeys: String, CodingKey {
        case id, title, url, creator, license, source, width, height, mature, tags
        case foreignLandingURL = "foreign_landing_url"
        case licenseVersion = "license_version"
        case licenseURL = "license_url"
    }

    private static func text(_ value: String?, limit: Int = 200) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(limit))
    }

    /// Only results whose identity, original, landing page, requested license, known non-mature flag and wide,
    /// sane dimensions all verify locally; nil otherwise. The license URL may still need review (see `licenseIsConsistent`).
    func reference(allowedLicenses: Set<String>) -> WallpaperReference? {
        guard let id = id.flatMap(UUID.init(uuidString:)),
              let source = source?.lowercased(),
              let original = url.flatMap(URL.init(string:)), OpenverseURLPolicy.isAllowedImageURL(original, source: source),
              let landing = foreignLandingURL.flatMap(URL.init(string:)), OpenverseURLPolicy.isAllowedLandingURL(landing, source: source),
              let license = license?.lowercased(), allowedLicenses.contains(license),
              mature == false,
              let width, let height, (1_024...100_000).contains(width), (600...100_000).contains(height),
              // Wide: landscape. Openverse's own `wide` threshold isn't relied on, only confirmed loosely.
              width > height else { return nil }
        let licenseURL = self.licenseURL.flatMap(URL.init(string:)).flatMap { OpenverseURLPolicy.isSafeHTTPS($0) ? $0 : nil }
        let thumbnail = (source == OpenverseURLPolicy.discoverySource ? OpenverseURLPolicy.commonsThumbnail(for: original) : nil)
            ?? OpenverseEndpoint.thumbnailURL(id: id)
        return WallpaperReference(
            providerIdentifier: RemoteProviderID.openverse.rawValue,
            wallpaperID: id.uuidString.lowercased(),
            sourcePageURL: landing,
            originalURL: original,
            previewURL: thumbnail,
            thumbnailURL: thumbnail,
            width: width,
            height: height,
            uploader: Self.text(creator),
            tags: (tags ?? []).compactMap { Self.text($0.name, limit: 60) }.prefix(8).map { $0 },
            cachedLocalPath: nil,
            title: Self.text(title),
            sourceName: source,
            license: license,
            licenseVersion: Self.text(licenseVersion, limit: 20),
            licenseURL: licenseURL
        )
    }
}
