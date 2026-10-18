import AppKit

/// A display-shaped thumbnail. The image fills the cell (like *Fill Screen* on a Mac display);
/// selection draws an accent ring outside the image so the picture itself is never covered.
final class WallpaperCollectionViewItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("WallpaperCollectionViewItem")
    static let ringInset: CGFloat = 4

    private var cell: ThumbnailCellView { view as! ThumbnailCellView }

    override var isSelected: Bool {
        didSet { if isViewLoaded { cell.isSelected = isSelected } }
    }

    override func loadView() {
        view = ThumbnailCellView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
    }

    var thumbnailFrame: NSRect { cell.imageHost.frame }
    var hasThumbnail: Bool { cell.imageHost.layer?.contents != nil }
    var showsSelectionRing: Bool { cell.isSelected }

    func configure(identifier: String, title: String, toolTip: String) {
        representedObject = identifier
        setThumbnail(nil, failed: false)
        view.toolTip = toolTip
        view.setAccessibilityLabel(title)
        view.setAccessibilityHelp(toolTip)
        cell.isSelected = isSelected
    }

    func setThumbnail(_ image: NSImage?, failed: Bool = true) {
        let scale = view.window?.backingScaleFactor ?? 2
        cell.imageHost.layer?.contents = image?.layerContents(forContentsScale: scale)
        cell.placeholder.isHidden = image != nil || !failed
    }
}

final class ThumbnailCellView: NSView {
    let imageHost = NSView()
    let ring = CALayer()
    let placeholder = NSImageView(image: NSImage(systemSymbolName: "photo", accessibilityDescription: nil) ?? NSImage())
    var isSelected = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(ring)
        ring.cornerRadius = 8
        imageHost.wantsLayer = true
        imageHost.layer?.cornerRadius = 5
        imageHost.layer?.masksToBounds = true
        imageHost.layer?.contentsGravity = .resizeAspectFill
        placeholder.contentTintColor = .tertiaryLabelColor
        placeholder.symbolConfiguration = .init(pointSize: 20, weight: .light)
        placeholder.isHidden = true
        addSubview(imageHost)
        addSubview(placeholder)
    }

    required init?(coder: NSCoder) { fatalError("Use programmatic initialization") }

    override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        let inset = WallpaperCollectionViewItem.ringInset
        imageHost.frame = bounds.insetBy(dx: inset, dy: inset)
        placeholder.frame = imageHost.frame
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ring.frame = bounds
        CATransaction.commit()
    }

    // Colors are resolved here so they follow light/dark and accent-color changes.
    // Selection is immediate on the Mac, so the ring's implicit layer animation is disabled.
    override func updateLayer() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageHost.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        ring.borderColor = NSColor.controlAccentColor.cgColor
        ring.borderWidth = isSelected ? 3 : 0
        CATransaction.commit()
    }
}
