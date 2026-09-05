import CryptoKit
import Foundation
import ImageIO

enum RemoteWallpaperCacheError: Error, LocalizedError {
    case invalidImage
    case capacityReached

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "The downloaded wallpaper was not a valid image."
        case .capacityReached:
            return "The wallpaper cache is full of saved assets, or this image exceeds its limit. Remove unused favorites or collection items and try again."
        }
    }
}

actor RemoteWallpaperCache {
    static let defaultMaximumSizeBytes: Int64 = 500 * 1_024 * 1_024

    private let fileManager: FileManager
    private let rootURL: URL
    private let maximumSizeBytes: Int64

    init(
        rootURL: URL? = nil,
        maximumSizeBytes: Int64 = RemoteWallpaperCache.defaultMaximumSizeBytes
    ) {
        let fileManager = FileManager()
        self.fileManager = fileManager
        self.maximumSizeBytes = maximumSizeBytes
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
            self.rootURL = cachesURL
                .appendingPathComponent("Wallpier", isDirectory: true)
                .appendingPathComponent("Originals", isDirectory: true)
        }
    }

    nonisolated static func filename(for reference: WallpaperReference) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        func sanitized(_ value: String) -> String {
            String(value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" })
        }

        let digest = SHA256.hash(data: Data(reference.originalURL.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let rawExtension = reference.originalURL.pathExtension.lowercased()
        let usefulExtension = rawExtension.isEmpty || rawExtension.count > 8 ? "img" : rawExtension
        return "\(sanitized(reference.providerIdentifier))-\(sanitized(reference.wallpaperID))-\(digest).\(usefulExtension)"
    }

    func cachedURL(for reference: WallpaperReference) throws -> URL? {
        if let path = reference.cachedLocalPath {
            let saved = URL(fileURLWithPath: path).standardizedFileURL
            if saved.deletingLastPathComponent() == rootURL.standardizedFileURL,
               Self.isValidImage(saved) {
                try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: saved.path)
                return saved
            }
        }
        let url = rootURL.appendingPathComponent(Self.filename(for: reference), isDirectory: false)
        guard Self.isValidImage(url) else { return nil }
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    func installDownloadedFile(
        _ temporaryURL: URL,
        for reference: WallpaperReference,
        protectedPaths: Set<String>
    ) throws -> URL {
        defer { try? fileManager.removeItem(at: temporaryURL) }
        guard Self.isValidImage(temporaryURL) else {
            try? fileManager.removeItem(at: temporaryURL)
            throw RemoteWallpaperCacheError.invalidImage
        }

        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var destination = rootURL.appendingPathComponent(Self.filename(for: reference), isDirectory: false)
        if fileManager.fileExists(atPath: destination.path) {
            if Self.isValidImage(destination) {
                try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
                return destination
            }
            // Never replace bytes at a path the desktop may still reference.
            destination = destination.deletingPathExtension()
                .appendingPathExtension("recovered-\(UUID().uuidString)")
                .appendingPathExtension(reference.originalURL.pathExtension)
        }

        do {
            try fileManager.moveItem(at: temporaryURL, to: destination)
        } catch {
            try fileManager.copyItem(at: temporaryURL, to: destination)
            try? fileManager.removeItem(at: temporaryURL)
        }
        try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)

        var protected = protectedPaths
        protected.insert(destination.path)
        _ = try evictIfNeeded(protectedPaths: protected)
        let remaining = try fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        let total = try remaining.reduce(Int64(0)) { sum, url in
            let values = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            return sum + Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        guard total <= maximumSizeBytes else {
            try fileManager.removeItem(at: destination)
            throw RemoteWallpaperCacheError.capacityReached
        }
        return destination
    }

    private static func isValidImage(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetStatus(source) == .statusComplete else { return false }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 32,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil
    }

    @discardableResult
    func evictIfNeeded(protectedPaths: Set<String>) throws -> [URL] {
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .totalFileAllocatedSizeKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        let urls = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        var entries: [(url: URL, size: Int64, date: Date)] = []
        var total: Int64 = 0
        for url in urls {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { continue }
            let size = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            total += size
            entries.append((url, size, values.contentModificationDate ?? .distantPast))
        }

        guard total > maximumSizeBytes else { return [] }
        let protected = Set(protectedPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        var removed: [URL] = []
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            guard total > maximumSizeBytes else { break }
            guard !protected.contains(entry.url.standardizedFileURL.path) else { continue }
            try fileManager.removeItem(at: entry.url)
            total -= entry.size
            removed.append(entry.url)
        }
        return removed
    }
}
