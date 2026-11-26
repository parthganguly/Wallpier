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
    /// A museum work shown for browsing only: no open-access high-resolution JPEG to preview, set or keep.
    case browseOnly
    /// The museum's current record no longer lists this work as open access with a high-resolution JPEG.
    case notOpenAccess
    /// The downloaded image didn't match what the museum's record says it is.
    case mediaRejected
    /// The download exceeded Wallpier's hard size cap and was stopped.
    case originalTooLarge

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
        case .browseOnly:
            return "This work has no open-access high-resolution JPEG, so it can only be viewed on the museum’s site."
        case .notOpenAccess:
            return "The museum no longer lists this work as open access with a high-resolution JPEG, so it wasn’t downloaded."
        case .mediaRejected:
            return "The downloaded image didn’t match the museum’s record, so it wasn’t used."
        case .originalTooLarge:
            return "The download was larger than Wallpier allows, so it was stopped."
        }
    }
}

protocol NetworkClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse)
    /// Streams the body to a temporary file and stops as soon as more than `maximumBytes` have arrived, following at
    /// most `maximumRedirects` redirects the client's policy allows. The caller removes the file.
    func boundedDownload(for request: URLRequest, maximumBytes: Int64, maximumRedirects: Int) async throws -> (URL, HTTPURLResponse)
}

extension NetworkClient {
    /// Clients that can't stream (test doubles) download first and check the size afterwards.
    func boundedDownload(for request: URLRequest, maximumBytes: Int64, maximumRedirects: Int) async throws -> (URL, HTTPURLResponse) {
        let (url, response) = try await download(for: request)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        if size > maximumBytes || response.expectedContentLength > maximumBytes {
            try? FileManager.default.removeItem(at: url)
            throw RemoteProviderError.originalTooLarge
        }
        return (url, response)
    }
}

/// Streams one request to a temporary file under a cumulative byte cap, re-checking every redirect hop. Exceeding the
/// cap, or a hop the policy refuses beyond the hop limit, ends the transfer; a refused hop is delivered as the final
/// 3xx response for the caller to reject.
final class BoundedDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let maximumBytes: Int64
    private let maximumRedirects: Int
    private let allowsRedirect: ((URL, URL) -> Bool)?
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(URL, HTTPURLResponse), Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var fileURL: URL?
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var redirects = 0
    private var response: HTTPURLResponse?
    private var failure: Error?
    private var cancelledByCaller = false
    private var finished = false

    /// `configuration` lets a test supply a URLProtocol; production always uses a fresh ephemeral session.
    init(request: URLRequest, maximumBytes: Int64, maximumRedirects: Int, allowsRedirect: ((URL, URL) -> Bool)?,
         configuration: URLSessionConfiguration = .ephemeral) {
        self.request = request
        self.maximumBytes = maximumBytes
        self.maximumRedirects = maximumRedirects
        self.allowsRedirect = allowsRedirect
        self.configuration = configuration
    }

    func run() async throws -> (URL, HTTPURLResponse) {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(URL, HTTPURLResponse), Error>) in
                lock.lock()
                self.continuation = continuation
                let configuration = self.configuration
                configuration.timeoutIntervalForRequest = 30
                configuration.timeoutIntervalForResource = 300
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                let task = session.dataTask(with: request)
                self.session = session
                self.task = task
                let alreadyCancelled = cancelledByCaller
                lock.unlock()
                if alreadyCancelled { task.cancel() } else { task.resume() }
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func cancel() {
        lock.lock()
        cancelledByCaller = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    private func fail(_ error: Error) {
        lock.lock()
        if failure == nil { failure = error }
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            fail(RemoteProviderError.invalidResponse)
            return completionHandler(.cancel)
        }
        if http.expectedContentLength > maximumBytes {
            fail(RemoteProviderError.originalTooLarge)
            return completionHandler(.cancel)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wallpier-download-\(UUID().uuidString).part")
        guard FileManager.default.createFile(atPath: url.path, contents: nil), let handle = try? FileHandle(forWritingTo: url) else {
            fail(CocoaError(.fileWriteUnknown))
            return completionHandler(.cancel)
        }
        lock.lock()
        // A redirect may deliver a second response: keep only the latest body.
        try? self.handle?.close()
        if let previous = fileURL { try? FileManager.default.removeItem(at: previous) }
        self.response = http
        self.fileURL = url
        self.handle = handle
        received = 0
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        received += Int64(data.count)
        let exceeded = received > maximumBytes
        let handle = self.handle
        lock.unlock()
        if exceeded { return fail(RemoteProviderError.originalTooLarge) }
        do { try handle?.write(contentsOf: data) } catch { fail(error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        redirects += 1
        let hops = redirects
        lock.unlock()
        guard hops <= maximumRedirects, let from = task.currentRequest?.url ?? response.url, let to = request.url,
              allowsRedirect?(from, to) ?? true else { return completionHandler(nil) }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        try? handle?.close()
        handle = nil
        let url = fileURL
        let response = (task.response as? HTTPURLResponse) ?? self.response
        let failure = self.failure
        let cancelled = cancelledByCaller
        let session = self.session
        self.session = nil
        lock.unlock()
        session?.finishTasksAndInvalidate()

        func discard() { if let url { try? FileManager.default.removeItem(at: url) } }
        if cancelled { discard(); continuation?.resume(throwing: CancellationError()); return }
        if let failure { discard(); continuation?.resume(throwing: failure); return }
        if let error { discard(); continuation?.resume(throwing: error); return }
        guard let url, let response else { discard(); continuation?.resume(throwing: RemoteProviderError.invalidResponse); return }
        continuation?.resume(returning: (url, response))
    }
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
    private let allowsRedirect: ((URL, URL) -> Bool)?

    /// Without `allowsRedirect`, redirects follow URLSession's defaults, as Wallhaven always has.
    init(session: URLSession = .shared, allowsRedirect: ((URL, URL) -> Bool)? = nil) {
        self.session = session
        self.allowsRedirect = allowsRedirect
        redirectPolicy = allowsRedirect.map(RedirectPolicyDelegate.init)
    }

    /// A client with its own ephemeral session: no cookies, and an HTTP cache that lives in memory only, apart from the app's.
    static func isolated(allowsRedirect: ((URL, URL) -> Bool)? = nil) -> URLSessionNetworkClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = URLCache(memoryCapacity: 8 * 1_024 * 1_024, diskCapacity: 0)
        configuration.timeoutIntervalForRequest = 30
        return URLSessionNetworkClient(session: URLSession(configuration: configuration), allowsRedirect: allowsRedirect)
    }

    func boundedDownload(for request: URLRequest, maximumBytes: Int64, maximumRedirects: Int) async throws -> (URL, HTTPURLResponse) {
        try await BoundedDownloader(request: request, maximumBytes: maximumBytes, maximumRedirects: maximumRedirects,
                                    allowsRedirect: allowsRedirect).run()
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
