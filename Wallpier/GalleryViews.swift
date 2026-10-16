import AppKit

/// Flow layout whose display-shaped (16:10) cells always divide the available width exactly,
/// so the grid never leaves a ragged gap on the right at any window size. The collection view's
/// delegate returns `fittedItemSize`; setting `itemSize` during `prepare()` leaves cells stale.
final class GalleryLayout: NSCollectionViewFlowLayout {
    static let thumbnailWidths: [CGFloat] = [170, 240, 330]
    static let aspect: CGFloat = 10.0 / 16.0

    var targetWidth: CGFloat = GalleryLayout.thumbnailWidths[1] { didSet { invalidateLayout() } }
    private var preparedWidth: CGFloat = 0
    private(set) var fittedItemSize = NSSize(width: 240, height: 150)

    override init() {
        super.init()
        sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 16, right: 12)
        minimumInteritemSpacing = 4
        minimumLineSpacing = 4
    }

    required init?(coder: NSCoder) { fatalError("Use programmatic initialization") }

    static func itemSize(availableWidth: CGFloat, targetWidth: CGFloat, spacing: CGFloat) -> NSSize {
        let columns = max(1, ((availableWidth + spacing) / (targetWidth + spacing)).rounded())
        let width = floor((availableWidth - (columns - 1) * spacing) / columns)
        return NSSize(width: width, height: floor(width * aspect))
    }

    override func prepare() {
        if let width = collectionView?.enclosingScrollView?.contentView.bounds.width, width > 0 {
            preparedWidth = width
            fittedItemSize = Self.itemSize(availableWidth: width - sectionInset.left - sectionInset.right,
                                           targetWidth: targetWidth, spacing: minimumInteritemSpacing)
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
    var onDelete: (() -> Void)?
    var contextMenu: (() -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        if plain, event.keyCode == 36 || event.keyCode == 76 { return nextResponder?.keyDown(with: event) ?? super.keyDown(with: event) }  // Return, Enter
        switch (event.charactersIgnoringModifiers ?? "", plain) {
        case (" ", true): onActivate?()
        case ("\u{7f}", true), ("\u{f728}", true): onDelete?()   // Delete, Forward Delete
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, indexPathForItem(at: convert(event.locationInWindow, from: nil)) != nil { onActivate?() }
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
        symbol.contentTintColor = .tertiaryLabelColor
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.textColor = .secondaryLabelColor
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
