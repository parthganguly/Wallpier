import AppKit

struct WallpaperSetResult {
    let elapsedTime: TimeInterval
}

class WallpaperService {
    func setWallpaper(
        imageURL: URL,
        on screen: NSScreen,
        scaling: ScalingMode
    ) throws -> WallpaperSetResult {
        let start = ProcessInfo.processInfo.systemUptime
        try NSWorkspace.shared.setDesktopImageURL(
            imageURL,
            for: screen,
            options: Self.desktopImageOptions(for: scaling)
        )
        return WallpaperSetResult(
            elapsedTime: ProcessInfo.processInfo.systemUptime - start
        )
    }

    func currentWallpaper(on screen: NSScreen) -> (imageURL: URL, scaling: ScalingMode)? {
        guard let imageURL = NSWorkspace.shared.desktopImageURL(for: screen) else {
            return nil
        }
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        return (imageURL, Self.scalingMode(from: options))
    }

    /// What NSWorkspace is asked for. Fit and Fill both scale proportionally up or down; only Fill may clip.
    static func desktopImageOptions(for scaling: ScalingMode) -> [NSWorkspace.DesktopImageOptionKey: Any] {
        switch scaling {
        case .fill:
            return [
                .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                .allowClipping: true
            ]
        case .fit:
            return [
                .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                .allowClipping: false
            ]
        case .center:
            return [
                .imageScaling: NSImageScaling.scaleNone.rawValue,
                .allowClipping: false
            ]
        }
    }

    static func scalingMode(
        from options: [NSWorkspace.DesktopImageOptionKey: Any]
    ) -> ScalingMode {
        let scalingValue = (options[.imageScaling] as? NSNumber)?.uintValue
        if scalingValue == NSImageScaling.scaleNone.rawValue {
            return .center
        }
        let allowsClipping = (options[.allowClipping] as? NSNumber)?.boolValue ?? false
        return allowsClipping ? .fill : .fit
    }
}
