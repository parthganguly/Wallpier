import AppKit

final class WallpaperCollectionViewItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("WallpaperCollectionViewItem")
    private(set) var thumbnailWell = NSView()

    override var isSelected: Bool {
        didSet { updateSelectionAppearance() }
    }

    override func loadView() {
        let container = NSView()

        let thumbnailWell = NSView()
        thumbnailWell.translatesAutoresizingMaskIntoConstraints = false
        thumbnailWell.wantsLayer = true
        thumbnailWell.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.18).cgColor
        thumbnailWell.layer?.cornerRadius = 4
        thumbnailWell.layer?.masksToBounds = true

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter

        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        thumbnailWell.addSubview(imageView)
        container.addSubview(thumbnailWell)
        container.addSubview(label)
        NSLayoutConstraint.activate([
            thumbnailWell.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            thumbnailWell.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            thumbnailWell.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            thumbnailWell.heightAnchor.constraint(equalTo: container.heightAnchor, constant: -30),
            imageView.leadingAnchor.constraint(equalTo: thumbnailWell.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: thumbnailWell.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: thumbnailWell.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: thumbnailWell.bottomAnchor),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: thumbnailWell.bottomAnchor, constant: 4),
            label.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -5)
        ])

        view = container
        self.thumbnailWell = thumbnailWell
        self.imageView = imageView
        textField = label
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        updateSelectionAppearance()
    }

    func configure(identifier: String, title: String, toolTip: String, placeholder: NSImage?) {
        representedObject = identifier
        textField?.stringValue = title
        imageView?.image = placeholder
        view.toolTip = toolTip
        view.setAccessibilityLabel("Wallpaper \(title)")
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
            thumbnailWell.layer?.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor
            thumbnailWell.layer?.borderWidth = 2
        } else {
            thumbnailWell.layer?.borderWidth = 0
        }
    }
}
