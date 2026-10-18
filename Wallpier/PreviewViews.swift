import AppKit
import ImageIO

/// Estimates how the desktop will show a wallpaper: inside a frame with the target display's
/// proportions, scaled by the chosen mode. The image may be a downsampled preview, so
/// geometry always comes from the original's pixel size, never the preview bitmap's; the
/// preview must therefore hold the whole original (see `WallpaperReference.remotePreview`).
final class DesktopPreviewView: NSView {
    static let desktopColor = NSColor(calibratedWhite: 0.11, alpha: 1)

    var image: NSImage? { didSet { needsDisplay = true } }
    var imagePixelSize: CGSize = .zero { didSet { needsDisplay = true } }
    var displayPixelSize = CGSize(width: 2880, height: 1800) { didSet { needsDisplay = true } }
    var scaling: ScalingMode = .fill { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { fatalError("Use programmatic initialization") }

    /// The largest display-shaped rectangle that fits in `bounds`.
    static func stageRect(in bounds: CGRect, display: CGSize) -> CGRect {
        let aspect = display.width > 0 && display.height > 0 ? display.width / display.height : 1.6
        var size = CGSize(width: bounds.width, height: bounds.width / aspect)
        if size.height > bounds.height { size = CGSize(width: bounds.height * aspect, height: bounds.height) }
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height).integral
    }

    /// Where the full original lands inside `stage` for a scaling mode (may extend past it for Fill/Center).
    static func imageRect(in stage: CGRect, image: CGSize, display: CGSize, scaling: ScalingMode) -> CGRect {
        guard image.width > 0, image.height > 0, stage.width > 0 else { return stage }
        let size: CGSize
        switch scaling {
        case .fill, .fit:
            let ratios = (stage.width / image.width, stage.height / image.height)
            let scale = scaling == .fill ? max(ratios.0, ratios.1) : min(ratios.0, ratios.1)
            size = CGSize(width: image.width * scale, height: image.height * scale)
        case .center:
            let scale = display.width > 0 ? stage.width / display.width : 1
            size = CGSize(width: image.width * scale, height: image.height * scale)
        }
        return CGRect(x: stage.midX - size.width / 2, y: stage.midY - size.height / 2, width: size.width, height: size.height)
    }

    var stageRect: CGRect { Self.stageRect(in: bounds.insetBy(dx: 1, dy: 1), display: displayPixelSize) }

    override func draw(_ dirtyRect: NSRect) {
        let stage = stageRect
        let outline = NSBezierPath(roundedRect: stage, xRadius: 6, yRadius: 6)
        Self.desktopColor.setFill()
        outline.fill()
        if let image {
            NSGraphicsContext.saveGraphicsState()
            outline.addClip()
            NSGraphicsContext.current?.imageInterpolation = .high
            let original = imagePixelSize.width > 0 ? imagePixelSize : image.size
            let target = Self.imageRect(in: stage, image: original, display: displayPixelSize, scaling: scaling)
            image.draw(in: target, from: Self.cropRect(of: image.size, toAspectOf: target.size), operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        }
        NSColor.separatorColor.setStroke()
        outline.lineWidth = 1
        outline.stroke()
    }

    /// Trims a preview's rounding difference from the original's shape. A thumbnail that was cropped
    /// (Wallhaven's 16:9 `thumbs.large` of another shape) can't be restored this way; it is labelled instead.
    static func cropRect(of size: CGSize, toAspectOf target: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, target.width > 0, target.height > 0 else { return CGRect(origin: .zero, size: size) }
        let aspect = target.width / target.height
        if size.width / size.height > aspect {
            let width = size.height * aspect
            return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
        }
        let height = size.width / aspect
        return CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
    }

    /// Reads only the image header; call off the main thread.
    nonisolated static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }
}

/// Container for the single-wallpaper preview. Owns its keyboard: ←/→ browse, Space or Esc return.
final class ViewerView: NSView {
    var onNavigate: ((Int) -> Void)?
    var onClose: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return super.keyDown(with: event) }
        switch event.specialKey {
        case .leftArrow?, .upArrow?: onNavigate?(-1)
        case .rightArrow?, .downArrow?: onNavigate?(1)
        default:
            if event.charactersIgnoringModifiers == " " || event.keyCode == 53 { onClose?() } else { super.keyDown(with: event) }
        }
    }

    override func cancelOperation(_ sender: Any?) { onClose?() }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { onClose?() }
    }
}
