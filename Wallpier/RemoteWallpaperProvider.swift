import Foundation

struct ProviderRateLimit: Equatable {
    let limit: Int?
    let remaining: Int?
    let resetDate: Date?
}

struct RemoteSearchPage: Equatable {
    let wallpapers: [WallpaperReference]
    let currentPage: Int
    let lastPage: Int
    let total: Int
    let rateLimit: ProviderRateLimit

    var hasMorePages: Bool { currentPage < lastPage }
}

enum RemoteProviderError: Error, Equatable, LocalizedError {
    case invalidResponse
    case invalidData
    case httpStatus(Int)
    case rateLimited(retryAfter: TimeInterval?)
    case originalUnavailable

    /// The longest wait a throttle header may ask for; longer, non-finite or negative values are malformed.
    static let maximumRetryDelay: TimeInterval = 3600

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The wallpaper source returned an invalid response."
        case .invalidData:
            return "The wallpaper source returned data Wallpier could not read."
        case .httpStatus(let status):
            return "The wallpaper source returned HTTP \(status)."
        case .rateLimited(let retryAfter):
            if let retryAfter, retryAfter.isFinite {
                let seconds = Int(min(max(1, retryAfter), Self.maximumRetryDelay).rounded())
                return "Wallhaven is temporarily rate-limiting requests. Try again in about \(seconds) seconds."
            }
            return "Wallhaven is temporarily rate-limiting requests. Try again shortly."
        case .originalUnavailable:
            return "The original wallpaper is no longer available."
        }
    }
}

protocol NetworkClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse)
}

struct URLSessionNetworkClient: NetworkClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw RemoteProviderError.invalidResponse
        }
        return (data, response)
    }

    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        let (url, response) = try await session.download(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw RemoteProviderError.invalidResponse
        }
        return (url, response)
    }
}

protocol RemoteWallpaperProvider {
    associatedtype SearchOptions: Equatable

    var identifier: String { get }
    func search(options: SearchOptions, page: Int) async throws -> RemoteSearchPage
    func fetchDetails(for reference: WallpaperReference) async throws -> WallpaperReference
    func downloadOriginal(for reference: WallpaperReference) async throws -> URL
}
