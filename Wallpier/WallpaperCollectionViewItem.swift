import AppKit

/// A display-shaped thumbnail. The image fills the cell (like *Fill Screen* on a Mac display);
/// selection draws a ring outside the image so the picture itself is never covered. The ring is
/// accent-colored while the gallery has keyboard focus and gray otherwise, as Mac selections are.
final class WallpaperCollectionViewItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("WallpaperCollectionViewItem")
    static let ringInset: CGFloat = 4

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

    var thumbnailFrame: NSRect { cell.imageHost.frame }
    var hasThumbnail: Bool { cell.imageHost.layer?.contents != nil }
    var showsSelectionRing: Bool { cell.isSelected }

    func configure(identifier: String, title: String, toolTip: String) {
        representedObject = identifier
        setThumbnail(nil, failed: false)
        setCaption(nil, style: .none)
        view.toolTip = toolTip
        view.setAccessibilityLabel(title)
        view.setAccessibilityHelp(toolTip)
        cell.isSelected = isSelected
        cell.isEmphasized = isEmphasized
    }

    /// Browse-only works say so on the cell: a badge over a thumbnail, or the whole record as text.
    func setCaption(_ text: String?, style: ThumbnailCellView.CaptionStyle) {
        cell.setCaption(text, style: style)
    }

    var captionText: String { cell.captionLabel.isHidden ? "" : cell.captionLabel.stringValue }

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
    var isEmphasized = true { didSet { if isEmphasized != oldValue { needsDisplay = true } } }
    static let imageRadius: CGFloat = 6

    enum CaptionStyle { case none, badge, text }
    let captionLabel = NSTextField(wrappingLabelWithString: "")
    private var captionStyle = CaptionStyle.none

    func setCaption(_ text: String?, style: CaptionStyle) {
        captionStyle = text == nil ? .none : style
        captionLabel.stringValue = text ?? ""
        captionLabel.isHidden = captionStyle == .none
        switch captionStyle {
        case .none: break
        case .badge:
            captionLabel.font = .systemFont(ofSize: 11, weight: .medium)
            captionLabel.alignment = .center
            captionLabel.maximumNumberOfLines = 1
            captionLabel.lineBreakMode = .byTruncatingTail
        case .text:
            captionLabel.font = .systemFont(ofSize: 12)
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
        // Concentric with the image: the ring's radius is the image's plus the gap between them.
        ring.cornerRadius = Self.imageRadius + WallpaperCollectionViewItem.ringInset
        imageHost.wantsLayer = true
        imageHost.layer?.cornerRadius = Self.imageRadius
        imageHost.layer?.masksToBounds = true
        imageHost.layer?.contentsGravity = .resizeAspectFill
        placeholder.contentTintColor = .tertiaryLabelColor
        placeholder.symbolConfiguration = .init(pointSize: 20, weight: .light)
        placeholder.isHidden = true
        addSubview(imageHost)
        addSubview(placeholder)
        addSubview(captionLabel)
    }

    required init?(coder: NSCoder) { fatalError("Use programmatic initialization") }

    override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        let inset = WallpaperCollectionViewItem.ringInset
        imageHost.frame = bounds.insetBy(dx: inset, dy: inset)
        placeholder.frame = imageHost.frame
        switch captionStyle {
        case .none: break
        case .badge:
            captionLabel.frame = NSRect(x: imageHost.frame.minX + 6, y: imageHost.frame.minY + 6, width: max(0, imageHost.frame.width - 12), height: 20)
        case .text:
            let area = imageHost.frame.insetBy(dx: 10, dy: 8)
            captionLabel.preferredMaxLayoutWidth = area.width
            let fitted = captionLabel.sizeThatFits(NSSize(width: area.width, height: .greatestFiniteMagnitude))
            let height = min(area.height, fitted.height)
            captionLabel.frame = NSRect(x: area.minX, y: area.midY - height / 2, width: area.width, height: height)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ring.frame = bounds
        CATransaction.commit()
    }

    // Colors are resolved here so they follow light/dark and accent-color changes.
    // Selection is immediate on the Mac, so the ring's implicit layer animation is disabled.
    // A hairline inside the image keeps pale skies on white and night scenes on dark from
    // dissolving into the backdrop; it sits on the picture's edge, not over its content.
    override func updateLayer() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageHost.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        imageHost.layer?.borderColor = NSColor.separatorColor.cgColor
        imageHost.layer?.borderWidth = 1 / (window?.backingScaleFactor ?? 2)
        ring.borderColor = (isEmphasized ? NSColor.controlAccentColor : NSColor.secondaryLabelColor).cgColor
        ring.borderWidth = isSelected ? 3 : 0
        // The badge sits on the picture, which can be any color: a fixed dark fill keeps it legible in both appearances.
        let badge = captionStyle == .badge
        captionLabel.layer?.backgroundColor = badge ? NSColor(white: 0, alpha: 0.7).cgColor : nil
        captionLabel.textColor = badge ? .white : .labelColor
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }
}
