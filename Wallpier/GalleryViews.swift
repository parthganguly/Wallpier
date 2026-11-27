import AppKit

/// Wallpier's design tokens: archival warm paper in light, darkroom charcoal in dark, one vermilion accent.
/// Colors resolve per appearance, including Increase Contrast, so they follow the system without observers.
enum Theme {
    private static func traits(_ appearance: NSAppearance) -> (dark: Bool, highContrast: Bool) {
        let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
        let dark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
        let high = match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
        return (dark, high)
    }

    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    private static func token(_ name: String, light: UInt32, dark: UInt32, lightHigh: UInt32? = nil, darkHigh: UInt32? = nil) -> NSColor {
        NSColor(name: "Wallpier\(name)") { appearance in
            let t = traits(appearance)
            return rgb(t.dark ? (t.highContrast ? darkHigh ?? dark : dark) : (t.highContrast ? lightHigh ?? light : light))
        }
    }

    /// Ink on paper in light and paper on ink in dark, with a stronger alpha under Increase Contrast.
    private static func hairline(_ name: String, normal: CGFloat, high: CGFloat) -> NSColor {
        NSColor(name: "Wallpier\(name)") { appearance in
            let t = traits(appearance)
            let alpha = t.highContrast ? high : normal
            return t.dark ? rgb(0xFFFCF5, alpha) : rgb(0x1C1917, alpha)
        }
    }

    static let canvas = token("Canvas", light: 0xF6F4EF, dark: 0x161615)
    static let stageBackdrop = token("StageBackdrop", light: 0xECE9E2, dark: 0x111110)
    static let surface = token("Surface", light: 0xFFFFFF, dark: 0x232321)
    static let surfaceHover = token("SurfaceHover", light: 0xEAE6DE, dark: 0x2D2C29)
    static let inkPrimary = token("InkPrimary", light: 0x1C1917, dark: 0xF2EFE9)
    /// 6.8:1 on the light canvas and 7.1:1 on the dark one; Increase Contrast promotes it further.
    static let inkSecondary = token("InkSecondary", light: 0x57534E, dark: 0xA8A29E, lightHigh: 0x3F3B37, darkHigh: 0xD6D3CD)
    static let inkTertiary = token("InkTertiary", light: 0x6B645E, dark: 0x9A948C, lightHigh: 0x4A4540, darkHigh: 0xC9C5BE)
    static let hairlineColor = hairline("Hairline", normal: 0.11, high: 0.45)
    /// Fill of the primary command. White on #C24B2C is 4.84:1; the lighter #D45B3B measured 3.92:1 and fails,
    /// so both appearances share this fill and only foreground accents lighten in dark.
    static let accentFill = rgb(0xC24B2C)
    static let accentFillHover = rgb(0xAE4124)
    static let accentFillPressed = rgb(0x9A381D)
    /// Accent for text, links and selection frames: 5.7:1 on paper, 6.6:1 on darkroom charcoal.
    static let accentText = token("AccentText", light: 0xB03F22, dark: 0xEB7A5C, lightHigh: 0x962F16, darkHigh: 0xF59A80)
    static let statusError = token("StatusError", light: 0xB91C1C, dark: 0xF87171)
    /// The display's own screen in the desktop preview.
    static let desktopMat = rgb(0x1A1A19)
    static let cornerRadius: CGFloat = 6

    /// New York where available (the system serif), else the regular system face; CJK falls back through CoreText.
    static func serif(_ size: CGFloat, weight: NSFont.Weight = .semibold) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.serif), let font = NSFont(descriptor: descriptor, size: size) else { return base }
        return font
    }
}

extension NSColor {
    /// Small secondary text (11–13 pt): captions, details, status and explanations.
    static let secondaryText = Theme.inkSecondary
}

/// A label that wraps to the width its container gives it, so titles grow downward instead of truncating.
final class WrappingLabel: NSTextField {
    override func layout() {
        super.layout()
        if abs(preferredMaxLayoutWidth - bounds.width) > 0.5, bounds.width > 0 {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}

/// The one primary command (Set Wallpaper): vermilion fill with white text, a native keyboard focus ring,
/// and distinct hover, pressed and disabled looks.
final class PrimaryButton: NSButton {
    private var isHovered = false { didSet { needsDisplay = true } }

    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title; self.target = target; self.action = action
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        setButtonType(.momentaryPushIn)
        focusRingType = .exterior
        font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("Use programmatic initialization") }

    override var title: String {
        didSet {
            attributedTitle = NSAttributedString(string: title, attributes: [
                .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold), .foregroundColor: NSColor.white])
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: super.intrinsicContentSize.width + 28, height: 30)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func draw(_ dirtyRect: NSRect) {
        let fill = isHighlighted ? Theme.accentFillPressed : isHovered ? Theme.accentFillHover : Theme.accentFill
        (isEnabled ? fill : fill.withAlphaComponent(0.45)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Theme.cornerRadius, yRadius: Theme.cornerRadius).fill()
        cell?.drawInterior(withFrame: bounds, in: self)
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: Theme.cornerRadius, yRadius: Theme.cornerRadius).fill()
    }
    override var focusRingMaskBounds: NSRect { bounds }
}

/// Fixed-cell contact sheet. Every cell has the same size whatever its picture's proportions: a picture well
/// above a two-line caption. The column count is a whole number worked out from the width, and leftover pixels
/// go into the outer margins, so nothing is cut off at any window width and nothing re-flows when thumbnails
/// load. The collection view's delegate returns `fittedItemSize` and `fittedSectionInset`.
final class GalleryLayout: NSCollectionViewFlowLayout {
    static let thumbnailWidths: [CGFloat] = [170, 240, 330]
    /// Well height over width: a little taller than a display so portraits and squares stay legible.
    static let wellAspect: CGFloat = 0.75
    /// The gap, title line and maker line under each well.
    static let captionHeight: CGFloat = 40

    var targetWidth: CGFloat = GalleryLayout.thumbnailWidths[1] { didSet { invalidateLayout() } }
    private var preparedWidth: CGFloat = 0
    private(set) var fittedItemSize = NSSize(width: 240, height: 190)
    private(set) var fittedSectionInset = NSEdgeInsets(top: 12, left: 15, bottom: 20, right: 15)

    // With the cells' 5 pt ring inset, pictures sit 18 pt apart and 20 pt from the edges.
    override init() {
        super.init()
        sectionInset = NSEdgeInsets(top: 12, left: 15, bottom: 20, right: 15)
        minimumInteritemSpacing = 8
        minimumLineSpacing = 10
    }

    required init?(coder: NSCoder) { fatalError("Use programmatic initialization") }

    static func cellHeight(forWidth width: CGFloat) -> CGFloat {
        let ring = WallpaperCollectionViewItem.ringInset
        return ring + floor((width - 2 * ring) * wellAspect) + captionHeight
    }

    static func itemSize(availableWidth: CGFloat, targetWidth: CGFloat, spacing: CGFloat) -> NSSize {
        let columns = max(1, ((availableWidth + spacing) / (targetWidth + spacing)).rounded())
        let width = floor((availableWidth - (columns - 1) * spacing) / columns)
        return NSSize(width: width, height: cellHeight(forWidth: width))
    }

    override func prepare() {
        if let width = collectionView?.enclosingScrollView?.contentView.bounds.width, width > 0 {
            preparedWidth = width
            let available = width - sectionInset.left - sectionInset.right
            fittedItemSize = Self.itemSize(availableWidth: available, targetWidth: targetWidth, spacing: minimumInteritemSpacing)
            let columns = max(1, floor((available + minimumInteritemSpacing) / (fittedItemSize.width + minimumInteritemSpacing)))
            let leftover = max(0, available - (columns * fittedItemSize.width + (columns - 1) * minimumInteritemSpacing))
            fittedSectionInset = NSEdgeInsets(top: sectionInset.top, left: sectionInset.left + floor(leftover / 2),
                                              bottom: sectionInset.bottom, right: sectionInset.right + ceil(leftover / 2))
        }
        super.prepare()
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != preparedWidth || super.shouldInvalidateLayout(forBoundsChange: newBounds)
    }

    // A bounds-change context does not re-ask the delegate for sizes unless told to.
    override func invalidationContext(forBoundsChange newBounds: NSRect) -> NSCollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(forBoundsChange: newBounds)
        (context as? NSCollectionViewFlowLayoutInvalidationContext)?.invalidateFlowLayoutDelegateMetrics = newBounds.width != preparedWidth
        return context
    }
}

/// Adds the Mac gestures a grid of images is expected to support: Space and double-click
/// open the selected item, Delete removes it where removal makes sense, and a right-click
/// selects the clicked item before showing its context menu. Return and Enter are passed up
/// the responder chain, which NSCollectionView would otherwise swallow, so the window's
/// default button (Set Wallpaper, with its own enabled-state guard) receives them.
final class GalleryCollectionView: NSCollectionView {
    var onActivate: (() -> Void)?
    /// Double-click; falls back to `onActivate` when unset.
    var onOpen: (() -> Void)?
    /// Esc: returns whether it was handled (a creator view going back); unhandled Esc continues as before.
    var onCancel: (() -> Bool)?
    var onDelete: (() -> Void)?
    var contextMenu: (() -> NSMenu?)?
    /// True while arrow keys and Space act on the gallery (first responder in the key window);
    /// selection rings are accent-colored only then, so the ring also says where typing goes.
    private(set) var isSelectionEmphasized = false

    private func setSelectionEmphasized(_ emphasized: Bool) {
        isSelectionEmphasized = emphasized
        for case let item as WallpaperCollectionViewItem in visibleItems() { item.isEmphasized = emphasized }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { setSelectionEmphasized(window?.isKeyWindow ?? false) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { setSelectionEmphasized(false) }
        return resigned
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let newWindow else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(keyStateChanged), name: NSWindow.didBecomeKeyNotification, object: newWindow)
        NotificationCenter.default.addObserver(self, selector: #selector(keyStateChanged), name: NSWindow.didResignKeyNotification, object: newWindow)
    }

    @objc private func keyStateChanged() {
        setSelectionEmphasized(window?.isKeyWindow == true && window?.firstResponder === self)
    }

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        if plain, event.keyCode == 36 || event.keyCode == 76 { return nextResponder?.keyDown(with: event) ?? super.keyDown(with: event) }  // Return, Enter
        if plain, event.keyCode == 53, onCancel?() == true { return }   // Esc
        switch (event.charactersIgnoringModifiers ?? "", plain) {
        case (" ", true): onActivate?()
        case ("\u{7f}", true), ("\u{f728}", true): onDelete?()   // Delete, Forward Delete
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, indexPathForItem(at: convert(event.locationInWindow, from: nil)) != nil { (onOpen ?? onActivate)?() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let indexPath = indexPathForItem(at: convert(event.locationInWindow, from: nil)) else { return nil }
        if !selectionIndexPaths.contains(indexPath) {
            selectionIndexPaths = [indexPath]
            delegate?.collectionView?(self, didSelectItemsAt: [indexPath])
        }
        return contextMenu?()
    }
}

/// Centered message for loading, empty and failure states, with an optional single action.
final class EmptyStateView: NSView {
    private let symbol = NSImageView()
    private let spinner = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    let actionButton = NSButton(title: "", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        symbol.symbolConfiguration = .init(pointSize: 34, weight: .light)
        symbol.contentTintColor = Theme.inkTertiary
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        // The title leads in the editorial serif at full contrast; the symbol and message stay quiet beneath it.
        titleLabel.font = Theme.serif(20)
        titleLabel.textColor = Theme.inkPrimary
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.textColor = .secondaryText
        messageLabel.alignment = .center
        messageLabel.preferredMaxLayoutWidth = 340
        messageLabel.isSelectable = true
        actionButton.bezelStyle = .rounded
        let stack = NSStackView(views: [symbol, spinner, titleLabel, messageLabel, actionButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(14, after: symbol)
        stack.setCustomSpacing(14, after: spinner)
        stack.setCustomSpacing(16, after: messageLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -16),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 340)
        ])
    }

    required init?(coder: NSCoder) { fatalError("Use programmatic initialization") }

    var title: String { titleLabel.stringValue }
    var message: String { messageLabel.stringValue }

    /// `symbolName == nil` shows a spinner instead of a symbol.
    func show(symbolName: String?, title: String, message: String, action: (title: String, selector: Selector, target: AnyObject)? = nil) {
        if let symbolName {
            symbol.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            symbol.isHidden = false
            spinner.stopAnimation(nil)
        } else {
            symbol.isHidden = true
            spinner.startAnimation(nil)
        }
        titleLabel.stringValue = title
        messageLabel.stringValue = message
        messageLabel.isHidden = message.isEmpty
        actionButton.isHidden = action == nil
        if let action {
            actionButton.title = action.title
            actionButton.action = action.selector
            actionButton.target = action.target
        }
        setAccessibilityLabel([title, message].filter { !$0.isEmpty }.joined(separator: ". "))
        isHidden = false
    }
}
