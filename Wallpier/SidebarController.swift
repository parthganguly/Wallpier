import AppKit

enum SidebarItem: Equatable {
    case discover, local, favorites
    case collection(UUID)
}

extension NSPasteboard.PasteboardType {
    /// A Wallhaven reference's identity key, for drags within Wallpier.
    static let wallpierReference = NSPasteboard.PasteboardType("com.parth.Wallpier.reference")
}

final class SidebarNode: NSObject {
    let item: SidebarItem?
    let title: String
    let symbolName: String?
    let count: Int?
    let isRotating: Bool
    let children: [SidebarNode]

    /// A selectable row.
    init(_ item: SidebarItem, title: String, symbolName: String, count: Int? = nil, isRotating: Bool = false) {
        self.item = item; self.title = title; self.symbolName = symbolName
        self.count = count; self.isRotating = isRotating; children = []
    }

    /// A group header.
    init(group title: String, children: [SidebarNode]) {
        item = nil; self.title = title; symbolName = nil; count = nil; isRotating = false; self.children = children
    }
}

final class SidebarOutlineView: NSOutlineView {
    var menuProvider: ((SidebarItem) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, let item = (item(atRow: row) as? SidebarNode)?.item else { return nil }
        return menuProvider?(item)
    }
}

/// Source list: Library (Discover, Folder, Favorites) and one row per collection.
final class SidebarController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outlineView = SidebarOutlineView()
    let scrollView = NSScrollView()
    var onSelect: ((SidebarItem) -> Void)?
    /// Called when wallpapers are dropped on Favorites or a collection; returns whether they were accepted.
    var onDrop: ((SidebarItem, [String]) -> Bool)?
    private var groups: [SidebarNode] = []
    private var isReloading = false

    override init() {
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Sidebar"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.floatsGroupRows = false
        outlineView.rowSizeStyle = .default
        outlineView.allowsEmptySelection = true
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.registerForDraggedTypes([.wallpierReference])
        outlineView.setAccessibilityLabel("Sources")
        scrollView.documentView = outlineView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
    }

    var selectedItem: SidebarItem? { (outlineView.item(atRow: outlineView.selectedRow) as? SidebarNode)?.item }
    var rows: [SidebarNode] { groups.flatMap { [$0] + $0.children } }

    func reload(groups: [SidebarNode], selection: SidebarItem?) {
        isReloading = true
        defer { isReloading = false }
        self.groups = groups
        outlineView.reloadData()
        groups.forEach { outlineView.expandItem($0) }
        select(selection)
    }

    func select(_ item: SidebarItem?) {
        let wasReloading = isReloading
        isReloading = true
        defer { isReloading = wasReloading }
        let row = rows.first { $0.item != nil && $0.item == item }.map { outlineView.row(forItem: $0) } ?? -1
        outlineView.selectRowIndexes(row >= 0 ? [row] : [], byExtendingSelection: false)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarNode)?.children.count ?? groups.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarNode)?.children[index] ?? groups[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SidebarNode)?.item == nil
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarNode)?.item == nil
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? SidebarNode)?.item != nil
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { false }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        if node.item == nil {
            let id = NSUserInterfaceItemIdentifier("SidebarHeader")
            let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
                let cell = NSTableCellView()
                cell.identifier = id
                let label = NSTextField(labelWithString: "")
                label.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(label)
                cell.textField = label
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
                return cell
            }()
            cell.textField?.stringValue = node.title
            return cell
        }
        let id = NSUserInterfaceItemIdentifier("SidebarRow")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? SidebarCell ?? SidebarCell(identifier: id)
        cell.configure(node)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isReloading, let item = selectedItem else { return }
        onSelect?(item)
    }

    // MARK: Drop wallpapers on Favorites or a collection

    private func dropTarget(_ item: Any?) -> SidebarItem? {
        switch (item as? SidebarNode)?.item {
        case .favorites?: return .favorites
        case .collection(let id)?: return .collection(id)
        default: return nil
        }
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard dropTarget(item) != nil else { return [] }
        outlineView.setDropItem(item, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let target = dropTarget(item) else { return false }
        let identities = info.draggingPasteboard.pasteboardItems?.compactMap { $0.string(forType: .wallpierReference) } ?? []
        return !identities.isEmpty && (onDrop?(target, identities) ?? false)
    }
}

final class SidebarCell: NSTableCellView {
    private let icon = NSImageView()
    private let countLabel = NSTextField(labelWithString: "")
    private let rotationBadge = NSImageView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        rotationBadge.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Rotating")
        rotationBadge.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        icon.contentTintColor = .controlAccentColor
        rotationBadge.contentTintColor = .controlAccentColor
        rotationBadge.toolTip = "Automatic rotation uses this source"
        let stack = NSStackView(views: [icon, label, rotationBadge, countLabel])
        stack.spacing = 6
        stack.setCustomSpacing(4, after: rotationBadge)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // The icon is deliberately not the `imageView` outlet: source-list styling would
        // re-tint it and render it near-black in inactive dark windows.
        textField = label
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18)
        ])
    }

    required init?(coder: NSCoder) { fatalError("Use programmatic initialization") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let tint: NSColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .controlAccentColor
            icon.contentTintColor = tint
            rotationBadge.contentTintColor = tint
        }
    }

    func configure(_ node: SidebarNode) {
        icon.image = node.symbolName.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        textField?.stringValue = node.title
        countLabel.stringValue = node.count.map(String.init) ?? ""
        countLabel.isHidden = node.count == nil
        rotationBadge.isHidden = !node.isRotating
        let count = node.count.map { ", \($0) wallpaper\($0 == 1 ? "" : "s")" } ?? ""
        setAccessibilityLabel(node.title + count + (node.isRotating ? ", used for automatic rotation" : ""))
    }
}
