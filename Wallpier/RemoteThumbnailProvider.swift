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
    // CMA's CDN stalls when many thumbnail tasks run at once, so only its tasks are queued
    // and at most a couple are ever resumed concurrently.
    private struct PendingCMATask {
        let key: String
        let generation: Int
        let priority: Int
    }
    private static let cmaConcurrentRequestLimit = 2
    private static let cmaPreviewPixelSize = 1000
    private var pendingCMATasks: [PendingCMATask] = []
    private var activeCMACount = 0

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
        pendingCMATasks.removeAll()
        activeCMACount = 0
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
        // Only CMA tasks go through the bounded queue; other providers keep their old behavior.
        let isCMACDN = url.host?.lowercased() == CMAURLPolicy.imageHost
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.lock.lock()
            let isCurrent = self.generation == requestGeneration
            var wasActive = false
            if isCurrent { wasActive = self.tasks.removeValue(forKey: key as String) != nil }
            if wasActive && isCMACDN { self.activeCMACount -= 1 }
            self.lock.unlock()
            guard isCurrent else { return }
            if wasActive && isCMACDN { self.startNextCMATasks() }
            guard error == nil,
                  let response = response as? HTTPURLResponse,
                  let data, Self.accepts(response, for: url, byteCount: data.count) else {
                self.finish(key: key, generation: requestGeneration, result: nil)
                return
            }

            self.decodeQueue.addOperation { [weak self] in
                guard let self else { return }
                let result = autoreleasepool {
                    Self.makeThumbnail(data: data, maximumPixelSize: maximumPixelSize, catalog: CatalogLibrary.isMediaHost(url))
                }
                if result == nil {
                    self.logger.error("Could not decode remote thumbnail at \(url.absoluteString, privacy: .public)")
                }
                self.finish(key: key, generation: requestGeneration, result: result)
            }
        }

        lock.lock()
        guard generation == requestGeneration else {
            // Reset already cleared the old completions. A new request may now own this key.
            lock.unlock()
            task.cancel()
            return
        }
        tasks[key as String] = task
        if isCMACDN {
            // Queued suspended; a slot must free up before it resumes.
            let priority = maximumPixelSize >= Self.cmaPreviewPixelSize ? 1 : 0
            pendingCMATasks.append(PendingCMATask(key: key as String, generation: requestGeneration, priority: priority))
        } else {
            task.resume()
        }
        lock.unlock()
        if isCMACDN { startNextCMATasks() }
    }

    /// Resumes queued CMA tasks, highest priority first, while a concurrency slot is free.
    private func startNextCMATasks() {
        lock.lock()
        defer { lock.unlock() }
        while activeCMACount < Self.cmaConcurrentRequestLimit, !pendingCMATasks.isEmpty {
            var next = 0
            for index in 1..<pendingCMATasks.count where pendingCMATasks[index].priority > pendingCMATasks[next].priority {
                next = index
            }
            let pending = pendingCMATasks.remove(at: next)
            guard let task = tasks[pending.key], generation == pending.generation else { continue }
            activeCMACount += 1
            task.resume()
        }
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
        // CMA's CDN can be slow to first byte; queued tasks stay suspended until a slot frees.
        if url.host?.lowercased() == CMAURLPolicy.imageHost { request.timeoutInterval = 30 }
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
            return !CatalogLibrary.isMediaHost(requested) || CatalogURL.sameResource(requested, target)
        }
    }

    static func accepts(_ response: HTTPURLResponse, for requested: URL, byteCount: Int) -> Bool {
        guard (200...299).contains(response.statusCode), (1...maximumThumbnailBytes).contains(byteCount) else { return false }
        if requested.host?.lowercased() == CMAURLPolicy.imageHost,
           !(response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().hasPrefix("image/") { return false }
        if CatalogLibrary.isMediaHost(requested),
           !["image/jpeg", "image/png", "application/octet-stream"].contains(response.mimeType?.lowercased() ?? "") { return false }
        return response.url.map { allowsThumbnailResponse(from: requested, to: $0) } ?? false
    }

    private static func makeThumbnail(data: Data, maximumPixelSize: Int, catalog: Bool) -> (image: NSImage, cost: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        if catalog {
            guard CGImageSourceGetCount(source) == 1,
                  let type = CGImageSourceGetType(source) as String?, ["public.jpeg", "public.png"].contains(type),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  (1...8192).contains(width), (1...8192).contains(height), width * height <= 20_000_000 else { return nil }
        }
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
