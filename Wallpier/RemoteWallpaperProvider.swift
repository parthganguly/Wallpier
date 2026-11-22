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
    /// Results the source returned that Wallpier did not show because their image, license or links could not be verified.
    var hiddenCount = 0

    var hasMorePages: Bool { currentPage < lastPage }
}

enum RemoteProviderError: Error, Equatable, LocalizedError {
    case invalidResponse
    case invalidData
    case httpStatus(Int)
    case rateLimited(retryAfter: TimeInterval?)
    case originalUnavailable
    /// An image address outside the hosts Wallpier trusts for that source, or a redirect away from them.
    case untrustedURL
    /// Openverse's reported license code and URL don't agree with a known public-domain deed.
    case licenseNeedsReview
    /// A saved reference from a provider this build doesn't support.
    case unsupportedProvider

    /// The longest wait a Wallhaven throttle header may ask for; longer, non-finite or negative values are malformed.
    static let maximumRetryDelay: TimeInterval = 3600
    /// Openverse's anonymous sustained quota is per day, so its Retry-After may legitimately be up to a day.
    static let maximumOpenverseRetryDelay: TimeInterval = 86_400

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
                let seconds = min(max(1, retryAfter), Self.maximumOpenverseRetryDelay)
                if seconds >= 3600 {
                    let hours = Int((seconds / 3600).rounded())
                    return "The wallpaper source is temporarily rate-limiting requests. Try again in about \(hours) hour\(hours == 1 ? "" : "s")."
                }
                return "The wallpaper source is temporarily rate-limiting requests. Try again in about \(Int(seconds.rounded())) seconds."
            }
            return "The wallpaper source is temporarily rate-limiting requests. Try again shortly."
        case .originalUnavailable:
            return "The original wallpaper is no longer available."
        case .untrustedURL:
            return "This image is hosted somewhere Wallpier doesn’t download from, so it wasn’t downloaded. Open its source page to review it."
        case .licenseNeedsReview:
            return "Openverse’s reported license for this image is missing or doesn’t match its license link. Review the original source; Wallpier won’t set it."
        case .unsupportedProvider:
            return "This wallpaper comes from a source this version of Wallpier doesn’t support."
        }
    }
}

protocol NetworkClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse)
}

/// Follows a redirect only when `allows(original, target)` says so; otherwise the 3xx response is returned as final.
final class RedirectPolicyDelegate: NSObject, URLSessionTaskDelegate {
    private let allows: (URL, URL) -> Bool

    init(allows: @escaping (URL, URL) -> Bool) {
        self.allows = allows
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let from = task.originalRequest?.url, let to = request.url, allows(from, to) else { return completionHandler(nil) }
        completionHandler(request)
    }
}

struct URLSessionNetworkClient: NetworkClient {
    private let session: URLSession
    private let redirectPolicy: RedirectPolicyDelegate?

    /// Without `allowsRedirect`, redirects follow URLSession's defaults, as Wallhaven always has.
    init(session: URLSession = .shared, allowsRedirect: ((URL, URL) -> Bool)? = nil) {
        self.session = session
        redirectPolicy = allowsRedirect.map(RedirectPolicyDelegate.init)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request, delegate: redirectPolicy)
        guard let response = response as? HTTPURLResponse else {
            throw RemoteProviderError.invalidResponse
        }
        return (data, response)
    }

    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        let (url, response) = try await session.download(for: request, delegate: redirectPolicy)
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

/// Throttle header parsing shared by both providers.
enum ProviderThrottle {
    static func retryAfter(from response: HTTPURLResponse,
                           maximum: TimeInterval = RemoteProviderError.maximumRetryDelay) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else {
            if let reset = resetDate(from: response) {
                return max(0, reset.timeIntervalSinceNow)
            }
            return nil
        }
        if let seconds = TimeInterval(value) {
            return validDelay(seconds, maximum: maximum)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value).flatMap { validDelay(max(0, $0.timeIntervalSinceNow), maximum: maximum) }
    }

    /// nil for a malformed wait (NaN, infinite, negative or beyond the maximum), so callers use their default.
    private static func validDelay(_ seconds: TimeInterval, maximum: TimeInterval) -> TimeInterval? {
        seconds.isFinite && seconds >= 0 && seconds <= maximum ? seconds : nil
    }

    static func resetDate(from response: HTTPURLResponse) -> Date? {
        let names = ["x-ratelimit-reset", "ratelimit-reset"]
        for name in names {
            // A past reset is harmless; a non-finite or far-future one would suppress requests indefinitely.
            if let value = response.value(forHTTPHeaderField: name),
               let timestamp = TimeInterval(value), timestamp.isFinite,
               timestamp - Date().timeIntervalSince1970 <= RemoteProviderError.maximumRetryDelay {
                return Date(timeIntervalSince1970: timestamp)
            }
        }
        return nil
    }
}
