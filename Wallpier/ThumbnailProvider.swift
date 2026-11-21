import AppKit
import ImageIO
import os.log

final class ThumbnailProvider {
    private let cache = NSCache<NSString, NSImage>()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.parth.Wallpier.thumbnails"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private let logger = Logger(subsystem: "com.parth.Wallpier", category: "Thumbnails")
    private var generation = 0

    init() {
        cache.countLimit = 120
        cache.totalCostLimit = 40 * 1_024 * 1_024
    }

    func reset() {
        generation += 1
        queue.cancelAllOperations()
        cache.removeAllObjects()
    }

    @discardableResult
    func requestThumbnail(
        for url: URL,
        maximumPixelSize: Int = 360,
        completion: @escaping (NSImage?) -> Void
    ) -> Operation? {
        let key = "\(url.path)#\(maximumPixelSize)" as NSString
        if let cached = cache.object(forKey: key) {
            completion(cached)
            return nil
        }

        let requestGeneration = generation
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let self, let operation, !operation.isCancelled else { return }
            let image = autoreleasepool {
                Self.makeThumbnail(for: url, maximumPixelSize: maximumPixelSize)
            }
            guard !operation.isCancelled else { return }

            if image == nil {
                self.logger.error("Could not create thumbnail for \(url.lastPathComponent, privacy: .public)")
            }

            OperationQueue.main.addOperation { [weak self] in
                guard let self, !operation.isCancelled, self.generation == requestGeneration else { return }
                if let image {
                    let cost = Int(image.size.width * image.size.height * 4)
                    self.cache.setObject(image, forKey: key, cost: cost)
                }
                completion(image)
            }
        }
        queue.addOperation(operation)
        return operation
    }

    private static func makeThumbnail(for url: URL, maximumPixelSize: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: image, size: .zero)
    }
}
