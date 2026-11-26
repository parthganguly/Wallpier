import AppKit
import ImageIO
import os.log

class RemoteThumbnailProvider {
    private let cache = NSCache<NSString, NSImage>()
    private let session: URLSession
    private let decodeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.parth.Wallpier.remote-thumbnails"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.parth.Wallpier", category: "RemoteThumbnails")
    private var generation = 0
    private var tasks: [String: URLSessionDataTask] = [:]
    private var completions: [String: [(NSImage?) -> Void]] = [:]

    /// `memoryOnly` keeps every cached thumbnail in memory (no disk cache at all), for isolated runs.
    init(memoryOnly: Bool = false) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = URLCache(
            memoryCapacity: 12 * 1_024 * 1_024,
            diskCapacity: memoryOnly ? 0 : 80 * 1_024 * 1_024
        )
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.timeoutIntervalForRequest = 20
        // Openverse thumbnails must not be redirected off its API host; Wallhaven's keep URLSession's defaults.
        let redirects = RedirectPolicyDelegate { from, to in
            Self.allowsThumbnailResponse(from: from, to: to)
        }
        session = URLSession(configuration: configuration, delegate: redirects, delegateQueue: nil)
        cache.countLimit = 100
        cache.totalCostLimit = 32 * 1_024 * 1_024
    }

    deinit {
        session.invalidateAndCancel()
    }

    func reset() {
        lock.lock()
        generation += 1
        let currentTasks = Array(tasks.values)
        tasks.removeAll()
        completions.removeAll()
        lock.unlock()
        currentTasks.forEach { $0.cancel() }
        decodeQueue.cancelAllOperations()
        cache.removeAllObjects()
    }

    func requestThumbnail(
        for url: URL,
        maximumPixelSize: Int = 420,
        completion: @escaping (NSImage?) -> Void
    ) {
        // A CMA address that isn't a valid media URL (including a saved one) is never requested.
        if CMAURLPolicy.isCMAHost(url), !CMAURLPolicy.isImageHostURL(url) { completion(nil); return }
        let key = "\(url.absoluteString)#\(maximumPixelSize)" as NSString
        if let cached = cache.object(forKey: key) {
            completion(cached)
            return
        }

        lock.lock()
        let requestGeneration = generation
        if completions[key as String] != nil {
            completions[key as String]?.append(completion)
            lock.unlock()
            return
        }
        completions[key as String] = [completion]
        lock.unlock()

        let request = Self.thumbnailRequest(for: url)
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.lock.lock()
            let isCurrent = self.generation == requestGeneration
            if isCurrent { self.tasks.removeValue(forKey: key as String) }
            self.lock.unlock()
            guard isCurrent else { return }
            guard error == nil,
                  let response = response as? HTTPURLResponse,
                  let data, Self.accepts(response, for: url, byteCount: data.count) else {
                self.finish(key: key, generation: requestGeneration, result: nil)
                return
            }

            self.decodeQueue.addOperation { [weak self] in
                guard let self else { return }
                let result = autoreleasepool {
                    Self.makeThumbnail(data: data, maximumPixelSize: maximumPixelSize)
                }
                if result == nil {
                    self.logger.error("Could not decode remote thumbnail at \(url.absoluteString, privacy: .public)")
                }
                self.finish(key: key, generation: requestGeneration, result: result)
            }
        }

        lock.lock()
        tasks[key as String] = task
        lock.unlock()
        task.resume()
    }

    private func finish(key: NSString, generation: Int, result: (image: NSImage, cost: Int)?) {
        OperationQueue.main.addOperation { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self.generation == generation else { self.lock.unlock(); return }
            let callbacks = self.completions.removeValue(forKey: key as String) ?? []
            if let result { self.cache.setObject(result.image, forKey: key, cost: result.cost) }
            self.lock.unlock()
            callbacks.forEach { $0(result?.image) }
        }
    }

    static let maximumThumbnailBytes = 16 * 1_024 * 1_024

    static func thumbnailRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        // Openverse's thumbnail endpoint returns HTTP 406 for an image-only Accept header.
        let accept = url.host?.lowercased() == OpenverseURLPolicy.apiHost ? "*/*" : "image/*"
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if url.host?.lowercased() == OpenverseURLPolicy.commonsThumbnailHost {
            request.setValue("Wallpier/0.2 (https://github.com/parthganguly/Wallpier)", forHTTPHeaderField: "User-Agent")
        } else {
            request.setValue("Wallpier/0.2", forHTTPHeaderField: "User-Agent")
        }
        return request
    }

    private static func allowsThumbnailResponse(from requested: URL, to target: URL) -> Bool {
        switch requested.host?.lowercased() {
        case OpenverseURLPolicy.apiHost:
            return OpenverseURLPolicy.allowsRedirect(from: requested, to: target)
        case OpenverseURLPolicy.commonsThumbnailHost:
            return OpenverseURLPolicy.isSafeHTTPS(target) && target.host?.lowercased() == OpenverseURLPolicy.commonsThumbnailHost
                && requested.path == target.path
        case CMAURLPolicy.imageHost:
            // CMA thumbnails stay on the same approved path on the museum's CDN over HTTPS.
            return CMAURLPolicy.allowsRedirect(from: requested, to: target)
        default:
            return true
        }
    }

    static func accepts(_ response: HTTPURLResponse, for requested: URL, byteCount: Int) -> Bool {
        guard (200...299).contains(response.statusCode), (1...maximumThumbnailBytes).contains(byteCount) else { return false }
        if requested.host?.lowercased() == CMAURLPolicy.imageHost,
           !(response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().hasPrefix("image/") { return false }
        return response.url.map { allowsThumbnailResponse(from: requested, to: $0) } ?? false
    }

    private static func makeThumbnail(data: Data, maximumPixelSize: Int) -> (image: NSImage, cost: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return (
            NSImage(cgImage: cgImage, size: .zero),
            cgImage.width * cgImage.height * 4
        )
    }
}
