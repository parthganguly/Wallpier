import Foundation
import os.log

final class WallpaperStateStore {
    private let fileManager: FileManager
    private let stateURL: URL
    private let logger = Logger(subsystem: "com.parth.Wallpier", category: "State")

    init(fileManager: FileManager = .default, stateURL: URL? = nil) {
        self.fileManager = fileManager
        if let stateURL {
            self.stateURL = stateURL
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.stateURL = applicationSupport
                .appendingPathComponent("Wallpier", isDirectory: true)
                .appendingPathComponent("state.json", isDirectory: false)
        }
    }

    func load() -> WallpaperState {
        guard fileManager.fileExists(atPath: stateURL.path) else {
            return WallpaperState()
        }

        do {
            let data = try Data(contentsOf: stateURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(WallpaperState.self, from: data)
        } catch {
            logger.error("State load failed; using defaults: \(error.localizedDescription, privacy: .public)")
            return WallpaperState()
        }
    }

    @discardableResult
    func save(_ state: WallpaperState) -> Bool {
        do {
            let directoryURL = stateURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(state).write(to: stateURL, options: .atomic)
            return true
        } catch {
            logger.error("State save failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
