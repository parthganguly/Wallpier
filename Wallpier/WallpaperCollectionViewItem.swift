import AppKit

/// One contact-sheet cell: a fixed picture well, the artwork drawn uncropped inside it on a shared baseline,
/// then a title line and a maker line. Selection draws a ring outside the well, with a gap, so the picture is never
/// covered. The ring is accent-colored while the gallery has keyboard focus and neutral otherwise, as Mac selections are.
final class WallpaperCollectionViewItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("WallpaperCollectionViewItem")
    /// 3 pt gap plus the 2 pt ring.
    static let ringInset: CGFloat = 5

    private var cell: ThumbnailCellView { view as! ThumbnailCellView }

    override var isSelected: Bool {
        didSet { if isViewLoaded { cell.isSelected = isSelected } }
    }

    /// Whether arrow keys and Space act on this gallery: it is first responder in the key window.
    var isEmphasized = true {
        didSet { if isViewLoaded { cell.isEmphasized = isEmphasized } }
    }

    override func loadView() {
        view = ThumbnailCellView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
    }

    /// The picture itself: the artwork's own proportions, fitted inside the well.
    var thumbnailFrame: NSRect { cell.imageHost.frame }
    /// The fixed well every picture sits in, the same for every cell.
    var wellFrame: NSRect { cell.wellFrame }
    var hasThumbnail: Bool { cell.imageHost.layer?.contents != nil }
    var showsSelectionRing: Bool { cell.isSelected }
    var titleText: String { cell.titleLabel.stringValue }
    var subtitleText: String { cell.subtitleLabel.stringValue }

    func configure(identifier: String, title: String, toolTip: String, subtitle: String = "") {
        representedObject = identifier
        setThumbnail(nil, failed: false)
        setCaption(nil, style: .none)
        cell.titleLabel.stringValue = title
        cell.subtitleLabel.stringValue = subtitle
        view.toolTip = toolTip
        view.setAccessibilityLabel(title)
        view.setAccessibilityHelp(toolTip)
        cell.isSelected = isSelected
        cell.isEmphasized = isEmphasized
    }

    /// Browse-only works say so on the cell: a badge on the well, or the whole record as a catalog card.
    func setCaption(_ text: String?, style: ThumbnailCellView.CaptionStyle) {
        cell.setCaption(text, style: style)
    }

    var captionText: String { cell.captionLabel.isHidden ? "" : cell.captionLabel.stringValue }

    func setThumbnail(_ image: NSImage?, failed: Bool = true) {
        let scale = view.window?.backingScaleFactor ?? 2
        cell.imageHost.layer?.contents = image?.layerContents(forContentsScale: scale)
        cell.imageSize = image?.size
        cell.placeholder.isHidden = image != nil || !failed
    }
}

final class ThumbnailCellView: NSView {
    let imageHost = NSView()
    let ring = CALayer()
    let placeholder = NSImageView(image: NSImage(systemSymbolName: "photo", accessibilityDescription: nil) ?? NSImage())
    let titleLabel = NSTextField(labelWithString: "")
    let subtitleLabel = NSTextField(labelWithString: "")
    var isSelected = false { didSet { needsDisplay = true } }
    var isEmphasized = true { didSet { if isEmphasized != oldValue { needsDisplay = true } } }
    /// The picture's own size; only its proportions are used. nil while there is no picture.
    var imageSize: NSSize? { didSet { needsLayout = true; needsDisplay = true } }
    static let imageRadius: CGFloat = 2

    enum CaptionStyle { case none, badge, text }
    let captionLabel = NSTextField(wrappingLabelWithString: "")
    private var captionStyle = CaptionStyle.none

    override var isFlipped: Bool { true }

    /// Identical for every cell of the same width, whatever is (or isn't) in it.
    var wellFrame: NSRect {
        let inset = WallpaperCollectionViewItem.ringInset
        let width = max(0, bounds.width - 2 * inset)
        return NSRect(x: inset, y: inset, width: width, height: floor(width * GalleryLayout.wellAspect))
    }

    func setCaption(_ text: String?, style: CaptionStyle) {
        captionStyle = text == nil ? .none : style
        captionLabel.stringValue = text ?? ""
        captionLabel.isHidden = captionStyle == .none
        // A catalog card carries the title and maker itself; the lines beneath would only repeat them.
        titleLabel.isHidden = captionStyle == .text
        subtitleLabel.isHidden = captionStyle == .text
        switch captionStyle {
        case .none: break
        case .badge:
            captionLabel.font = .systemFont(ofSize: 11, weight: .medium)
            captionLabel.alignment = .center
            captionLabel.maximumNumberOfLines = 1
            captionLabel.lineBreakMode = .byTruncatingTail
        case .text:
            captionLabel.font = Theme.serif(12, weight: .regular)
            captionLabel.alignment = .center
            captionLabel.maximumNumberOfLines = 0
            captionLabel.lineBreakMode = .byWordWrapping
        }
        needsLayout = true
        needsDisplay = true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        captionLabel.isHidden = true
        captionLabel.isSelectable = false
        captionLabel.drawsBackground = false
        captionLabel.setAccessibilityElement(false)
        captionLabel.wantsLayer = true
        captionLabel.layer?.cornerRadius = 4
        layer?.addSublayer(ring)
        // Concentric with the well: the ring's radius is the well's plus the gap between them.
        ring.cornerRadius = Self.imageRadius + WallpaperCollectionViewItem.ringInset
        imageHost.wantsLayer = true
        imageHost.layer?.cornerRadius = Self.imageRadius
        imageHost.layer?.masksToBounds = true
        imageHost.layer?.contentsGravity = .resize
        placeholder.contentTintColor = Theme.inkTertiary
        placeholder.symbolConfiguration = .init(pointSize: 20, weight: .light)
        placeholder.isHidden = true
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = Theme.inkPrimary
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = Theme.inkSecondary
        for label in [titleLabel, subtitleLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.allowsExpansionToolTips = true
            label.setAccessibilityElement(false)
        }
        addSubview(imageHost)
        addSubview(placeholder)
        addSubview(captionLabel)
        addSubview(titleLabel)
        addSubview(subtitleLabel)
    }

    required init?(coder: NSCoder) { fatalError("Use programmatic initialization") }

    override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        let well = wellFrame
        // The artwork keeps its own proportions, scaled to fit the well and sitting on its bottom edge.
        if let size = imageSize, size.width > 0, size.height > 0, well.width > 0, well.height > 0 {
            let scale = min(well.width / size.width, well.height / size.height)
            let fitted = NSSize(width: floor(size.width * scale), height: floor(size.height * scale))
            imageHost.frame = NSRect(x: (well.midX - fitted.width / 2).rounded(), y: well.maxY - fitted.height, width: fitted.width, height: fitted.height)
        } else {
            imageHost.frame = well
        }
        placeholder.frame = well
        switch captionStyle {
        case .none: break
        case .badge:
            let wanted = captionLabel.sizeThatFits(NSSize(width: well.width, height: 20)).width + 16
            captionLabel.frame = NSRect(x: well.minX + 6, y: well.minY + 6, width: min(max(0, well.width - 12), wanted), height: 20)
        case .text:
            let area = well.insetBy(dx: 12, dy: 10)
            captionLabel.preferredMaxLayoutWidth = area.width
            let fitted = captionLabel.sizeThatFits(NSSize(width: area.width, height: .greatestFiniteMagnitude))
            let height = min(area.height, fitted.height)
            captionLabel.frame = NSRect(x: area.minX, y: area.midY - height / 2, width: area.width, height: height)
        }
        let inset = WallpaperCollectionViewItem.ringInset
        let lineWidth = max(0, bounds.width - 2 * inset)
        titleLabel.frame = NSRect(x: inset, y: well.maxY + 8, width: lineWidth, height: 16)
        subtitleLabel.frame = NSRect(x: inset, y: well.maxY + 24, width: lineWidth, height: 15)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ring.frame = NSRect(x: 0, y: 0, width: bounds.width, height: well.maxY + inset)
        CATransaction.commit()
    }

    // Colors are resolved here so they follow light/dark, Increase Contrast and accent changes.
    // Selection is immediate on the Mac, so the ring's implicit layer animation is disabled.
    // A hairline on the picture's own edge keeps pale skies on paper and night scenes on charcoal from
    // dissolving into the canvas; it sits on the edge, not over the content.
    override func updateLayer() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let hasPicture = imageSize != nil
        let card = captionStyle == .text
        imageHost.layer?.backgroundColor = (hasPicture ? NSColor.clear : card ? Theme.surface : Theme.surfaceHover).cgColor
        imageHost.layer?.borderColor = Theme.hairlineColor.cgColor
        imageHost.layer?.borderWidth = hasPicture || card ? 1 / (window?.backingScaleFactor ?? 2) : 0
        ring.borderColor = (isEmphasized ? Theme.accentText : NSColor.secondaryLabelColor).cgColor
        ring.borderWidth = isSelected ? 2 : 0
        // The badge sits on the picture, which can be any color: a fixed dark fill keeps it legible in both appearances.
        let badge = captionStyle == .badge
        captionLabel.layer?.backgroundColor = badge ? NSColor(white: 0, alpha: 0.72).cgColor : nil
        captionLabel.textColor = badge ? .white : Theme.inkPrimary
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }
}
