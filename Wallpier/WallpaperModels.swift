import Foundation

enum ScalingMode: String, Codable, CaseIterable {
    case fill
    case fit
    case center

    var displayName: String {
        switch self {
        case .fill: return "Fill"
        case .fit: return "Fit"
        case .center: return "Center"
        }
    }
}

enum RotationInterval: String, Codable, CaseIterable {
    case off
    case fifteenMinutes
    case oneHour
    case oneDay

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .fifteenMinutes: return "15 minutes"
        case .oneHour: return "1 hour"
        case .oneDay: return "1 day"
        }
    }

    var seconds: TimeInterval? {
        switch self {
        case .off: return nil
        case .fifteenMinutes: return 15 * 60
        case .oneHour: return 60 * 60
        case .oneDay: return 24 * 60 * 60
        }
    }
}

struct DisplayAssignment: Codable, Equatable {
    let displayID: String
    let displayName: String
    let imagePath: String
    let scaling: ScalingMode
}

struct HistoryEntry: Codable, Equatable {
    let previous: DisplayAssignment
    let replacement: DisplayAssignment
    let timestamp: Date
}

struct WallpaperState: Codable, Equatable {
    static let historyLimit = 20

    var version = 1
    var folderPath: String?
    var selectedImagePath: String?
    var selectedDisplayID: String?
    var scalingMode: ScalingMode = .fill
    var rotationInterval: RotationInterval = .off
    var shuffleEnabled = false
    var displayAssignments: [DisplayAssignment] = []
    var history: [HistoryEntry] = []

    func assignment(for displayID: String) -> DisplayAssignment? {
        displayAssignments.first { $0.displayID == displayID }
    }

    mutating func setAssignment(_ assignment: DisplayAssignment) {
        displayAssignments.removeAll { $0.displayID == assignment.displayID }
        displayAssignments.append(assignment)
    }

    mutating func appendHistory(_ entry: HistoryEntry) {
        history.append(entry)
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
    }

    mutating func popHistory() -> HistoryEntry? {
        history.popLast()
    }
}

enum WallpaperNavigation {
    static func index(after currentIndex: Int?, direction: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let currentIndex, (0..<count).contains(currentIndex) else {
            return direction < 0 ? count - 1 : 0
        }

        let offset = direction < 0 ? -1 : 1
        return (currentIndex + offset + count) % count
    }
}

enum SupportedWallpaperFiles {
    static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif"]

    static func isSupported(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    static func images(in folderURL: URL, fileManager: FileManager = .default) throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        return try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            guard isSupported(url) else { return false }
            return (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) == true
        }
        .sorted {
            $0.lastPathComponent.compare(
                $1.lastPathComponent,
                options: [.caseInsensitive, .numeric, .diacriticInsensitive],
                locale: Locale.current
            ) == .orderedAscending
        }
    }
}
