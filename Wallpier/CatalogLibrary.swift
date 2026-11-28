import Foundation
import ImageIO

struct CatalogCreator: Codable, Equatable, Hashable {
    let id: String
    let name: String
}

struct CatalogRecord: Codable, Equatable, Hashable {
    let creator: CatalogCreator?
    let credit: String?
    let browseOnly: Bool

    init(creator: CatalogCreator? = nil, credit: String? = nil, browseOnly: Bool = false) {
        self.creator = creator
        self.credit = credit
        self.browseOnly = browseOnly
    }
}

struct CatalogSearchOptions: Equatable {
    let query: String
    let creator: CatalogCreator?

    init(query: String, creator: CatalogCreator? = nil) {
        self.query = query
        self.creator = creator
    }

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
}

protocol CatalogAdapter {
    var id: RemoteProviderID { get }
    var endpoint: URL { get }
    var hosts: Set<String> { get }
    func search(_ options: CatalogSearchOptions, page: Int, transport: CatalogTransport) async throws -> RemoteSearchPage
    func refresh(_ reference: WallpaperReference, transport: CatalogTransport) async throws -> WallpaperReference
    func allowsMedia(_ url: URL, id: String, original: Bool) -> Bool
    func allowsPage(_ url: URL, id: String) -> Bool
}

enum CatalogURL {
    static func isHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil
            && url.port == nil && url.fragment == nil
    }

    static func make(_ base: String, _ query: [URLQueryItem]) -> URL {
        var components = URLComponents(string: base)!
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    static func sameResource(_ first: URL, _ second: URL) -> Bool {
        isHTTPS(second) && first.absoluteString == second.absoluteString
    }
}

actor CatalogTransport {
    static let userAgent = "Wallpier/0.2"
    private let hosts: Set<String>
    private let client: NetworkClient
    private var retryAfter: Date?

    init(hosts: Set<String>, client: NetworkClient? = nil) {
        self.hosts = hosts
        self.client = client ?? URLSessionNetworkClient.isolated(allowsRedirect: CatalogURL.sameResource)
    }

    func json<T: Decodable>(_ type: T.Type, from url: URL, maximumBytes: Int64 = 1_500_000,
                            revalidate: Bool = false) async throws -> T {
        let data = try await bytes(from: url, maximumBytes: maximumBytes, revalidate: revalidate)
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw RemoteProviderError.invalidData }
    }

    func bytes(from url: URL, maximumBytes: Int64 = 1_500_000, accept: String = "application/json",
               revalidate: Bool = false) async throws -> Data {
        let (file, _) = try await download(from: url, maximumBytes: maximumBytes, accept: accept, revalidate: revalidate)
        defer { try? FileManager.default.removeItem(at: file) }
        return try Data(contentsOf: file)
    }

    func conditionalBytes(from url: URL, etag: String?, maximumBytes: Int64 = 1_500_000)
        async throws -> (data: Data?, etag: String?) {
        let (file, response) = try await download(from: url, maximumBytes: maximumBytes,
                                                  accept: "application/json", revalidate: true, etag: etag)
        defer { try? FileManager.default.removeItem(at: file) }
        let receivedTag = response.value(forHTTPHeaderField: "ETag") ?? etag
        return (response.statusCode == 304 ? nil : try Data(contentsOf: file), receivedTag)
    }

    func download(from url: URL, maximumBytes: Int64, accept: String,
                  revalidate: Bool, etag: String? = nil) async throws -> (URL, HTTPURLResponse) {
        try Task.checkCancellation()
        guard CatalogURL.isHTTPS(url), let host = url.host?.lowercased(), hosts.contains(host) else {
            throw RemoteProviderError.untrustedURL
        }
        if let retryAfter, retryAfter > Date() {
            throw RemoteProviderError.rateLimited(retryAfter: retryAfter.timeIntervalSinceNow)
        }
        var request = URLRequest(url: url, cachePolicy: revalidate ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if revalidate { request.setValue("no-cache", forHTTPHeaderField: "Cache-Control") }
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (file, response) = try await client.boundedDownload(for: request, maximumBytes: maximumBytes, maximumRedirects: 0)
        do {
            try Task.checkCancellation()
            guard let finalURL = response.url, CatalogURL.sameResource(url, finalURL) else { throw RemoteProviderError.untrustedURL }
            let githubRateLimit = host == "api.github.com" && response.statusCode == 403
                && (response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
                    || response.value(forHTTPHeaderField: "Retry-After") != nil)
            if response.statusCode == 429 || githubRateLimit {
                let wait = max(1, ProviderThrottle.retryAfter(from: response) ?? 60)
                retryAfter = Date().addingTimeInterval(wait)
                throw RemoteProviderError.rateLimited(retryAfter: wait)
            }
            guard (200...299).contains(response.statusCode) || (response.statusCode == 304 && etag != nil) else {
                throw RemoteProviderError.httpStatus(response.statusCode)
            }
            return (file, response)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }
}

/// Provider-specific search and validation, with one transport per source so throttling stays local to it.
final class CatalogLibrary {
    private static let adapters: [RemoteProviderID: any CatalogAdapter] = {
        let sources: [any CatalogAdapter] = [
            MetCatalogAdapter(), WellcomeCatalogAdapter(), NASACatalogAdapter(),
            PlasmaCatalogAdapter(), PepperCatalogAdapter(), INaturalistCatalogAdapter()
        ]
        return Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
    }()

    private let transports: [RemoteProviderID: CatalogTransport]
    static let maximumOriginalBytes: Int64 = 40 * 1_024 * 1_024
    static let maximumImagePixels = 54_000_000

    init(client: NetworkClient? = nil) {
        transports = Self.adapters.mapValues { CatalogTransport(hosts: $0.hosts, client: client) }
    }

    static func endpoint(for provider: RemoteProviderID) -> URL? { adapters[provider]?.endpoint }

    func search(_ provider: RemoteProviderID, query: CatalogSearchOptions, page: Int) async throws -> RemoteSearchPage {
        guard page >= 1, let adapter = Self.adapters[provider], let transport = transports[provider] else {
            throw RemoteProviderError.unsupportedProvider
        }
        return try await adapter.search(query, page: page, transport: transport)
    }

    func checkedReference(for reference: WallpaperReference) async throws -> WallpaperReference {
        if let restriction = reference.useRestriction { throw restriction }
        guard let provider = reference.provider, let adapter = Self.adapters[provider], let transport = transports[provider] else {
            throw RemoteProviderError.unsupportedProvider
        }
        do {
            var current = try await adapter.refresh(reference, transport: transport)
            guard current.identityKey == reference.identityKey, current.useRestriction == nil else {
                throw RemoteProviderError.catalogOriginalIneligible
            }
            current.cachedLocalPath = current.originalURL == reference.originalURL ? reference.cachedLocalPath : nil
            return current
        } catch RemoteProviderError.notOpenAccess {
            throw RemoteProviderError.catalogOriginalIneligible
        }
    }

    func downloadOriginal(for currentReference: WallpaperReference) async throws -> (file: URL, reference: WallpaperReference) {
        var current = currentReference
        guard let provider = current.provider, let transport = transports[provider], Self.canUse(current) else {
            throw RemoteProviderError.catalogOriginalIneligible
        }
        let (file, response) = try await transport.download(from: current.originalURL, maximumBytes: Self.maximumOriginalBytes,
                                                            accept: "image/jpeg, image/png", revalidate: false)
        do {
            try Task.checkCancellation()
            let mime = response.mimeType?.lowercased()
            guard let image = Self.inspect(file), mime == image.mime || mime == "application/octet-stream",
                  Self.matches(image.width, image.height, reference: current) else { throw RemoteProviderError.mediaRejected }
            current.width = image.width
            current.height = image.height
            return (file, current)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    static func originalSize(_ url: URL) -> (width: Int, height: Int)? {
        inspect(url).map { ($0.width, $0.height) }
    }

    static func isFaithfulOriginal(_ url: URL, reference: WallpaperReference) -> Bool {
        guard let image = inspect(url) else { return false }
        return matches(image.width, image.height, reference: reference)
    }

    static func thumbnail(for reference: WallpaperReference, large: Bool) -> URL? {
        guard let provider = reference.provider, let adapter = adapters[provider], reference.catalog != nil else { return nil }
        let url = large ? reference.previewURL : reference.thumbnailURL
        return adapter.allowsMedia(url, id: reference.wallpaperID, original: false) ? url : nil
    }

    static func sourcePage(for reference: WallpaperReference) -> URL? {
        guard let provider = reference.provider,
              adapters[provider]?.allowsPage(reference.sourcePageURL, id: reference.wallpaperID) == true else { return nil }
        return reference.sourcePageURL
    }

    static func licensePage(for reference: WallpaperReference) -> URL? {
        guard let url = reference.licenseURL, CatalogURL.isHTTPS(url), url.query == nil else { return nil }
        switch url.host?.lowercased() {
        case "creativecommons.org":
            return url.path.hasPrefix("/licenses/") || url.path.hasPrefix("/publicdomain/") ? url : nil
        case "www.gnu.org": return url.path.hasPrefix("/licenses/") ? url : nil
        case "www.nasa.gov": return url.path == "/nasa-brand-center/images-and-media" ? url : nil
        default: return nil
        }
    }

    static func canUse(_ reference: WallpaperReference) -> Bool {
        guard let provider = reference.provider, let adapter = adapters[provider], reference.catalog?.browseOnly == false,
              reference.license != nil else { return false }
        return adapter.allowsMedia(reference.originalURL, id: reference.wallpaperID, original: true)
    }

    static func isMediaHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return adapters.values.contains { $0.hosts.contains(host) }
    }

    private static func matches(_ width: Int, _ height: Int, reference: WallpaperReference) -> Bool {
        (reference.width == 0 || reference.width == width) && (reference.height == 0 || reference.height == height)
    }

    private static func inspect(_ url: URL) -> (width: Int, height: Int, mime: String)? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= maximumOriginalBytes,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete, CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source) as String?,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...16_384).contains(width), (1...16_384).contains(height),
              width * height <= maximumImagePixels else { return nil }
        switch type {
        case "public.jpeg": return (width, height, "image/jpeg")
        case "public.png": return (width, height, "image/png")
        default: return nil
        }
    }
}
