import CryptoKit
import Foundation
import ImageIO
import os.log

/// Only owns rollback copies. Remote originals keep their existing cache ownership.
actor WallpaperHistoryStore {
    static let maximumSizeBytes: Int64 = 250 * 1_024 * 1_024
    private let root: URL
    private let originalsRoot: URL
    private let limit: Int64
    private let files = FileManager()
    private let logger = Logger(subsystem: "com.parth.Wallpier", category: "History")

    init(root: URL? = nil, originalsRoot: URL? = nil, maximumSizeBytes: Int64 = WallpaperHistoryStore.maximumSizeBytes) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wallpier/Rollback", isDirectory: true)
        self.originalsRoot = originalsRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wallpier/Originals", isDirectory: true)
        limit = maximumSizeBytes
    }

    func prepare(previous: DisplayAssignment, replacement: DisplayAssignment) -> HistoryEntry {
        var entry = HistoryEntry(previous: previous, replacement: replacement, timestamp: Date())
        let source = URL(fileURLWithPath: previous.imagePath)
        guard Self.validImage(source) else {
            entry.undoUnavailableReason = .previousFileUnavailable
            logger.notice("Previous wallpaper is unavailable: \(source.path, privacy: .public)")
            return entry
        }
        // Resolve symlinks before deciding ownership: an external symlink isn't owned storage.
        let resolved = source.resolvingSymlinksInPath()
        if isDirectChild(source, of: originalsRoot) || isDirectChild(source, of: root) {
            if resolved.path != source.standardizedFileURL.path { entry.rollbackPath = resolved.path }
            return entry
        }
        do {
            entry.rollbackPath = try preserve(resolved).path
        } catch {
            logger.error("Could not preserve previous wallpaper: \(error.localizedDescription, privacy: .public)")
            entry.undoUnavailableReason = .preservationFailed
        }
        return entry
    }

    func undoAssignment(for entry: HistoryEntry) -> DisplayAssignment? {
        guard entry.undoUnavailableReason == nil else { return nil }
        let path = entry.rollbackPath ?? entry.previous.imagePath
        guard Self.validImage(URL(fileURLWithPath: path)) else { return nil }
        return DisplayAssignment(displayID: entry.previous.displayID, displayName: entry.previous.displayName,
                                 imagePath: path, scaling: entry.previous.scaling)
    }

    /// Called only after a successful state save, never against an uncommitted history snapshot.
    func cleanup(protectedPaths: Set<String>) {
        let protected = Set(protectedPaths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        do {
            guard files.fileExists(atPath: root.path) else { return }
            for url in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey]) {
                guard url.lastPathComponent.hasPrefix("rollback-"), isDirectChild(url, of: root),
                      !protected.contains(url.resolvingSymlinksInPath().path),
                      try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                try files.removeItem(at: url)
            }
        } catch { logger.error("Rollback cleanup failed: \(error.localizedDescription, privacy: .public)") }
    }

    private func preserve(_ source: URL) throws -> URL {
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, Int64(size) <= limit else { throw CocoaError(.fileWriteOutOfSpace) }
        let hash = try contentHash(source)
        let ext = source.pathExtension.lowercased()
        let suffix = ext.isEmpty ? "img" : ext
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        var destination = root.appendingPathComponent("rollback-\(hash).\(suffix)")
        if files.fileExists(atPath: destination.path) {
            if Self.validImage(destination), try contentHash(destination) == hash { return destination }
            destination = root.appendingPathComponent("rollback-\(hash)-\(UUID()).\(suffix)")
        }
        let existing = try files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
        let bytes = try existing.reduce(Int64(0)) { sum, url in
            sum + Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        guard bytes + Int64(size) <= limit else { throw CocoaError(.fileWriteOutOfSpace) }
        try Task.checkCancellation()
        do {
            try files.copyItem(at: source, to: destination)
            // A source modified while copying must not produce a mislabeled snapshot.
            let copiedSize = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard bytes + Int64(copiedSize) <= limit else { throw CocoaError(.fileWriteOutOfSpace) }
            guard Self.validImage(destination), try contentHash(destination) == hash else { throw CocoaError(.fileReadCorruptFile) }
            return destination
        } catch {
            // This fresh, unique destination has never been referenced by a desktop/history.
            try? files.removeItem(at: destination)
            throw error
        }
    }

    private func contentHash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
            try Task.checkCancellation()
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func isDirectChild(_ url: URL, of directory: URL) -> Bool {
        url.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath()
    }

    private static func validImage(_ url: URL) -> Bool {
        guard FileManager.default.isReadableFile(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetStatus(source) == .statusComplete else { return false }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceThumbnailMaxPixelSize: 32,
                                      kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil
    }
}
