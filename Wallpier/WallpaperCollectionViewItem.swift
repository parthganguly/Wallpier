import AppKit

final class WallpaperCollectionViewItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("WallpaperCollectionViewItem")

    override var isSelected: Bool {
        didSet { updateSelectionAppearance() }
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 6

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter

        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        container.addSubview(imageView)
        container.addSubview(label)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            imageView.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            imageView.heightAnchor.constraint(equalTo: container.heightAnchor, constant: -30),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 4),
            label.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -5)
        ])

        view = container
        self.imageView = imageView
        textField = label
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        updateSelectionAppearance()
    }

    func configure(url: URL, placeholder: NSImage?) {
        representedObject = url
        textField?.stringValue = url.deletingPathExtension().lastPathComponent
        imageView?.image = placeholder
        view.toolTip = url.path
        view.setAccessibilityLabel("Wallpaper \(url.lastPathComponent)")
    }

    func setThumbnail(_ image: NSImage?) {
        imageView?.image = image
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        updateSelectionAppearance()
    }

    private func updateSelectionAppearance() {
        guard isViewLoaded else { return }
        if isSelected {
            view.layer?.backgroundColor = NSColor.selectedContentBackgroundColor
                .withAlphaComponent(0.28).cgColor
            view.layer?.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor
            view.layer?.borderWidth = 2
        } else {
            view.layer?.backgroundColor = NSColor.clear.cgColor
            view.layer?.borderWidth = 0
        }
    }
}
