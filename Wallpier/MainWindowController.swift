import AppKit
import os.log

/// Neutral backdrop the wallpapers sit on, following appearance changes.
private final class BackdropView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

private extension NSToolbarItem.Identifier {
    static let viewMode = Self("com.parth.Wallpier.viewMode")
    static let rotation = Self("com.parth.Wallpier.rotation")
    static let undoWallpaper = Self("com.parth.Wallpier.undo")
    static let search = Self("com.parth.Wallpier.search")
    static let sidebarSeparator = Self("com.parth.Wallpier.sidebarSeparator")
}

/// Keeps its own text Undo history, so ⌘Z and ⇧⌘Z while typing never reach library removals.
private final class SearchField: NSSearchField {
    private let textUndoManager = UndoManager()
    override var undoManager: UndoManager? { textUndoManager }
}

@MainActor
final class MainWindowController: NSWindowController, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout,
    NSMenuItemValidation, NSSearchFieldDelegate, NSToolbarDelegate, NSMenuDelegate {

    private enum SetSource { case user, rotation }
    /// Favorites, or one collection: the lists whose removals can be undone.
    private enum MemberList: Equatable { case favorites, collection(UUID) }
    private enum BrowserItem {
        case local(URL)
        case remote(WallpaperReference)

        var identifier: String {
            switch self {
            case .local(let url): return "local:\(url.path)"
            case .remote(let ref): return ref.identityKey
            }
        }
        var title: String {
            switch self {
            case .local(let url): return url.deletingPathExtension().lastPathComponent
            case .remote(let ref): return ref.wallpaperID
            }
        }
        /// Also the gallery cell's accessibility help, so VoiceOver hears more than an opaque ID.
        var toolTip: String {
            switch self {
            case .local(let url): return url.path
            case .remote(let ref): return "Wallhaven \(ref.wallpaperID) — \(ref.width) × \(ref.height), \(ref.orientation)"
            }
        }
    }

    private let wallpaperService: WallpaperService
    private let stateStore: WallpaperStateStore
    private let thumbnailProvider = ThumbnailProvider()
    private let remoteThumbnailProvider: RemoteThumbnailProvider
    private let provider: WallhavenProvider
    private let originalCache: RemoteWallpaperCache
    private let historyStore: WallpaperHistoryStore
    private let availableScreens: () -> [NSScreen]
    private var validatedUndoEntry: HistoryEntry?
    private(set) var undoValidationTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.parth.Wallpier", category: "MainWindow")
    private(set) lazy var state = stateStore.load()

    private var localURLs: [URL] = []
    private(set) var remoteResults: [WallpaperReference] = []
    private var currentPage = 0
    private var lastPage = 0
    private var totalResults = 0
    private var screens: [NSScreen] = []
    private var folderLoadID = UUID()
    private var isLoadingFolder = false
    private var rotationTimer: Timer?
    private(set) var searchTask: Task<Void, Never>?
    private(set) var detailTask: Task<Void, Never>?
    private(set) var downloadTask: Task<Void, Never>?
    private(set) var rotationTask: Task<Void, Never>?
    private var isSearching = false
    private var searchGeneration = UUID()
    private var resultOptions: WallhavenSearchOptions?
    private var searchErrorText: String?
    private var lastAppendFailure: Date?
    /// After a failed page, further pages wait this long; Next is re-enabled when it ends.
    private let appendRetryCooldown: TimeInterval = 5
    private var appendRetryTask: Task<Void, Never>?
    /// Next at the last loaded result asked for a page; it completes when that page arrives, if nothing changed meanwhile.
    private struct PendingAdvance { let generation: UUID; let identity: String; let revision: Int; let query: WallhavenSearchOptions? }
    private var pendingAdvance: PendingAdvance?
    /// Bumped by every selection change, so a pending move can tell the user went elsewhere and came back.
    private var selectionRevision = 0
    private static let loadingMoreStatus = "Loading more results from Wallhaven…"
    /// Closing the preview, by any path, cancels its pending detail request so reopening can ask again.
    private(set) var isViewerVisible = false { didSet { if oldValue && !isViewerVisible { endPreviewSession() } } }
    /// How faithful the stage's image is. Completions may only replace it with an equal or better one.
    private var stageFidelity = PreviewFidelity.none
    /// The wallpaper whose preview details were requested; reselecting it doesn't request them again.
    private var detailIdentity: String?
    /// Details wait for the selection to settle, so arrowing through the preview doesn't fetch every item.
    static let detailDwellNanoseconds: UInt64 = 300_000_000

    // Window structure
    private var splitViewController: NSSplitViewController?
    private let sidebar = SidebarController()
    private let newCollectionButton = NSButton(title: "New Collection", target: nil, action: nil)

    // Search and filters
    let searchField: NSSearchField = SearchField()
    private var searchToolbarItem: NSSearchToolbarItem?
    let categoryPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let resolutionPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let aspectPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sortingPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let scopeBar = NSStackView()
    private lazy var scopeBarCollapsed = scopeBar.heightAnchor.constraint(equalToConstant: 0)
    private var statusClearTask: Task<Void, Never>?
    private let discoverBar = NSStackView()
    private let localBar = NSStackView()
    private let folderPathLabel = NSTextField(labelWithString: "")
    /// Shown when the visible results no longer match the search text, filters or display size.
    let pendingSearchLabel = NSTextField(labelWithString: "")
    let updateResultsButton = NSButton(title: "Update Results", target: nil, action: nil)

    // Gallery and preview
    private let galleryLayout = GalleryLayout()
    private let galleryScroll = NSScrollView()
    let emptyStateView = EmptyStateView()
    let viewerView = ViewerView()
    let stageView = DesktopPreviewView()
    let previewTitleLabel = NSTextField(labelWithString: "No Wallpaper Selected")
    /// Pointer navigation for the preview, beside the position in the browsable items. Same commands as ←/→ and ⌘[ ⌘].
    let previewPreviousButton = NSButton()
    let previewNextButton = NSButton()
    let previewPositionLabel = NSTextField(labelWithString: "")
    let previewMetadataLabel = NSTextField(labelWithString: "")
    private let previewTagsLabel = NSTextField(labelWithString: "")
    /// Says what the stage is drawn from when it isn't the original: a low-resolution or a cropped thumbnail.
    let approximatePreviewNotice = NSStackView()
    private let previewNoticeIcon = NSImageView()
    private let previewNoticeLabel = NSTextField(labelWithString: "")

    // Apply bar
    let applyBar = NSStackView()
    private let busyIndicator = NSProgressIndicator()
    let selectionLabel = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")
    let favoriteButton = NSButton()
    private let moreButton = NSButton()
    let displayPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let scalingPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let setWallpaperButton = NSButton(title: "Set Wallpaper", target: nil, action: nil)

    // Toolbar, rotation and undo
    let viewModeControl = NSSegmentedControl()
    let rotationButton = NSButton()
    let undoButton = NSButton()
    private let rotationSourcePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let rotationPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let shuffleButton = NSButton(checkboxWithTitle: "Shuffle", target: nil, action: nil)
    let rotationSummaryLabel = NSTextField(wrappingLabelWithString: "")
    private(set) lazy var rotationPopover = makeRotationPopover()

    private(set) lazy var collectionView: GalleryCollectionView = {
        let view = GalleryCollectionView()
        view.collectionViewLayout = galleryLayout
        view.dataSource = self
        view.delegate = self
        view.isSelectable = true
        view.allowsMultipleSelection = false
        // A nonempty gallery always shows its Set target: clicking blank space keeps the selection.
        view.allowsEmptySelection = false
        view.backgroundColors = [.clear]
        view.register(WallpaperCollectionViewItem.self, forItemWithIdentifier: WallpaperCollectionViewItem.reuseIdentifier)
        view.setDraggingSourceOperationMask(.copy, forLocal: true)
        view.setDraggingSourceOperationMask(.copy, forLocal: false)
        view.setAccessibilityLabel("Wallpapers")
        view.onActivate = { [weak self] in self?.setViewerVisible(true) }
        view.onDelete = { [weak self] in self?.removeSelected(nil) }
        view.contextMenu = { [weak self] in self?.itemMenu() }
        return view
    }()

    // Inject before any state restoration, search, or rotation can start.
    init(window: NSWindow?, wallpaperService: WallpaperService, stateStore: WallpaperStateStore,
         provider: WallhavenProvider, originalCache: RemoteWallpaperCache,
         historyStore: WallpaperHistoryStore, remoteThumbnailProvider: RemoteThumbnailProvider,
         availableScreens: @escaping () -> [NSScreen]) {
        self.wallpaperService = wallpaperService
        self.stateStore = stateStore
        self.provider = provider
        self.originalCache = originalCache
        self.historyStore = historyStore
        self.remoteThumbnailProvider = remoteThumbnailProvider
        self.availableScreens = availableScreens
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("Use programmatic initialization") }

#if DEBUG
    // Development captures use the injected initializer before restoring isolated state.
    func prepareForVisualCapture(discoverPage: RemoteSearchPage) {
        precondition(window?.contentView?.subviews.isEmpty == true)
        precondition(state.currentSource != .discover && state.rotationInterval == .off)
        remoteResults = discoverPage.wallpapers
        currentPage = discoverPage.currentPage
        lastPage = discoverPage.lastPage
        totalResults = discoverPage.total
        resultOptions = state.wallhavenSearch
        configureUI()
        restoreState()
    }

    var sidebarForTesting: SidebarController { sidebar }
    var galleryScrollForTesting: NSScrollView { galleryScroll }
    var galleryLayoutForTesting: GalleryLayout { galleryLayout }

    // Test-only rotation seam: when set, this creates the repeating rotation Timer instead of the
    // native target/selector Timer below. Development and release leave it nil, so the production
    // scheduling path, retention, tolerance and run-loop behavior are unchanged.
    var rotationTimerFactoryForTesting: ((TimeInterval, @escaping () -> Void) -> Timer)?
#endif

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Wallpier"
        self.init(window: window, wallpaperService: WallpaperService(), stateStore: WallpaperStateStore(),
                  provider: WallhavenProvider(), originalCache: RemoteWallpaperCache(),
                  historyStore: WallpaperHistoryStore(), remoteThumbnailProvider: RemoteThumbnailProvider(),
                  availableScreens: { NSScreen.screens })
        configureUI()
        // Only the real window remembers its frame and sidebar width; test windows never write defaults.
        if !window.setFrameUsingName("WallpierMainWindow") { window.center() }
        window.setFrameAutosaveName("WallpierMainWindow")
        splitViewController?.splitView.autosaveName = "WallpierSidebar"
        restoreState()
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshUndoAvailability), name: NSWindow.didBecomeKeyNotification, object: window)
        refreshUndoAvailability()
    }

    deinit {
        rotationTimer?.invalidate()
        searchTask?.cancel()
        detailTask?.cancel()
        downloadTask?.cancel()
        rotationTask?.cancel()
        undoValidationTask?.cancel()
        statusClearTask?.cancel()
        appendRetryTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Building the window

    private func configureUI() {
        guard let window else { return }
        configureControls()
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 820, height: 540)

        let sidebarController = NSViewController()
        sidebarController.view = makeSidebarView()
        let contentController = NSViewController()
        contentController.view = makeContentView()
        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 280
        sidebarItem.canCollapse = true
        let contentItem = NSSplitViewItem(viewController: contentController)
        contentItem.minimumThickness = 620
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(contentItem)
        split.view.frame = NSRect(origin: .zero, size: window.contentRect(forFrameRect: window.frame).size)
        splitViewController = split
        let frame = window.frame
        window.contentViewController = split
        window.setFrame(frame, display: false)

        let toolbar = NSToolbar(identifier: "WallpierMainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.initialFirstResponder = collectionView
        galleryScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(galleryDidScroll), name: NSView.boundsDidChangeNotification, object: galleryScroll.contentView)
    }

    private func configureControls() {
        searchField.placeholderString = "Search Wallhaven"
        searchField.target = self; searchField.action = #selector(search(_:))
        searchField.delegate = self
        searchField.sendsWholeSearchString = true
        searchField.setAccessibilityHelp("Searches safe-for-work wallpapers on Wallhaven")
        searchField.toolTip = "Search Wallhaven (⌘F). Results appear in Discover."
        categoryPopUp.addItems(withTitles: WallhavenCategory.allCases.map(\.displayName))
        resolutionPopUp.addItems(withTitles: ["At Least Display Size", "Any Resolution", "1080p or Larger", "1440p or Larger", "4K or Larger"])
        aspectPopUp.addItems(withTitles: WallhavenAspectRatio.allCases.map(\.displayName))
        sortingPopUp.addItems(withTitles: WallhavenSorting.allCases.map(\.displayName))
        let filterNames = ["Category", "Minimum resolution", "Aspect ratio", "Sort order"]
        for (popup, name) in zip([categoryPopUp, resolutionPopUp, aspectPopUp, sortingPopUp], filterNames) {
            popup.target = self; popup.action = #selector(searchOptionChanged(_:))
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            popup.setAccessibilityLabel(name)
        }

        displayPopUp.target = self; displayPopUp.action = #selector(displaySelectionChanged); displayPopUp.setAccessibilityLabel("Display")
        displayPopUp.toolTip = "The display the wallpaper is set on"
        scalingPopUp.addItems(withTitles: ScalingMode.allCases.map(scalingTitle))
        scalingPopUp.target = self; scalingPopUp.action = #selector(scalingSelectionChanged); scalingPopUp.setAccessibilityLabel("Scaling")
        scalingPopUp.toolTip = "How the wallpaper is sized to the display"
        setWallpaperButton.target = self; setWallpaperButton.action = #selector(setWallpaper(_:)); setWallpaperButton.keyEquivalent = "\r"
        setWallpaperButton.setAccessibilityHelp("Downloads the original if needed and sets it on the selected display")
        configureSymbolButton(favoriteButton, symbol: "heart", label: "Favorite", action: #selector(toggleFavorite(_:)))
        configureSymbolButton(moreButton, symbol: "ellipsis.circle", label: "More Actions", action: #selector(showMoreMenu(_:)))

        rotationPopUp.addItems(withTitles: RotationInterval.allCases.map(rotationTitle))
        rotationPopUp.target = self; rotationPopUp.action = #selector(rotationSelectionChanged)
        rotationPopUp.setAccessibilityLabel("Rotation interval")
        rotationSourcePopUp.target = self; rotationSourcePopUp.action = #selector(rotationSourceChanged)
        rotationSourcePopUp.setAccessibilityLabel("Rotation source")
        shuffleButton.target = self; shuffleButton.action = #selector(shuffleChanged)

        viewModeControl.segmentCount = 2
        viewModeControl.trackingMode = .selectOne
        for (index, (symbol, label)) in [("square.grid.2x2", "Gallery"), ("display", "Desktop Preview")].enumerated() {
            viewModeControl.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: label), forSegment: index)
            viewModeControl.setToolTip(label, forSegment: index)
        }
        viewModeControl.selectedSegment = 0
        viewModeControl.target = self; viewModeControl.action = #selector(viewModeChanged(_:))
        configureToolbarButton(rotationButton, symbol: "arrow.triangle.2.circlepath", label: "Automatic Rotation", action: #selector(showRotationSettings(_:)))
        configureToolbarButton(undoButton, symbol: "arrow.uturn.backward", label: "Undo Wallpaper Change", action: #selector(undoWallpaperChange(_:)))
        undoButton.isEnabled = false

        let width = UserDefaults.standard.object(forKey: "GalleryThumbnailSize") as? Int ?? 1
        galleryLayout.targetWidth = GalleryLayout.thumbnailWidths[GalleryLayout.thumbnailWidths.indices.contains(width) ? width : 1]
    }

    private func configureSymbolButton(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        button.contentTintColor = .secondaryLabelColor
        button.target = self; button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    private func configureToolbarButton(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.target = self; button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    private func makeSidebarView() -> NSView {
        sidebar.onSelect = { [weak self] item in self?.activate(item) }
        sidebar.onDrop = { [weak self] target, identities in self?.collect(identities, into: target) ?? false }
        sidebar.outlineView.menuProvider = { [weak self] item in self?.sidebarMenu(for: item) }
        newCollectionButton.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: nil)
        newCollectionButton.imagePosition = .imageLeading
        newCollectionButton.isBordered = false
        newCollectionButton.contentTintColor = .secondaryLabelColor
        newCollectionButton.font = .systemFont(ofSize: NSFont.systemFontSize)
        newCollectionButton.target = self; newCollectionButton.action = #selector(createCollection(_:))
        let view = NSView()
        for subview in [sidebar.scrollView, newCollectionButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            sidebar.scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            sidebar.scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebar.scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sidebar.scrollView.bottomAnchor.constraint(equalTo: newCollectionButton.topAnchor, constant: -8),
            newCollectionButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            newCollectionButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14)
        ])
        return view
    }

    private func makeContentView() -> NSView {
        // Scope bar: Discover filters or the current folder, only where relevant.
        discoverBar.setViews([categoryPopUp, resolutionPopUp, aspectPopUp, sortingPopUp], in: .leading)
        pendingSearchLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pendingSearchLabel.textColor = .secondaryLabelColor
        pendingSearchLabel.lineBreakMode = .byTruncatingTail
        // Shown whole or not at all: a truncated “Showing “…” says nothing. The button and its tooltip remain.
        pendingSearchLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        updateResultsButton.controlSize = .small
        updateResultsButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        updateResultsButton.target = self; updateResultsButton.action = #selector(search(_:))
        discoverBar.setViews([pendingSearchLabel, updateResultsButton], in: .trailing)
        discoverBar.setVisibilityPriority(.detachOnlyIfNecessary, for: pendingSearchLabel)
        discoverBar.spacing = 8
        let folderIcon = NSImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil) ?? NSImage())
        folderIcon.contentTintColor = .secondaryLabelColor
        folderPathLabel.lineBreakMode = .byTruncatingMiddle
        folderPathLabel.allowsExpansionToolTips = true
        folderPathLabel.textColor = .secondaryText
        folderPathLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        folderPathLabel.isSelectable = true
        folderPathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let changeFolder = NSButton(title: "Change Folder…", target: self, action: #selector(chooseFolder(_:)))
        changeFolder.controlSize = .small
        changeFolder.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        localBar.setViews([folderIcon, folderPathLabel], in: .leading)
        localBar.setViews([changeFolder], in: .trailing)
        localBar.spacing = 6
        let scopeSeparator = NSBox(); scopeSeparator.boxType = .separator
        let scopeRows = NSStackView(views: [discoverBar, localBar])
        scopeRows.orientation = .vertical
        scopeRows.edgeInsets = NSEdgeInsets(top: 7, left: 14, bottom: 7, right: 14)
        scopeBar.setViews([scopeRows, scopeSeparator], in: .top)
        scopeBar.orientation = .vertical
        scopeBar.spacing = 0
        [discoverBar, localBar].forEach { $0.widthAnchor.constraint(equalTo: scopeRows.widthAnchor, constant: -28).isActive = true }
        [scopeRows, scopeSeparator].forEach { $0.widthAnchor.constraint(equalTo: scopeBar.widthAnchor).isActive = true }

        // Gallery, desktop preview and empty state share one area; only one is visible.
        galleryScroll.documentView = collectionView
        galleryScroll.hasVerticalScroller = true
        galleryScroll.autohidesScrollers = true
        galleryScroll.drawsBackground = false
        galleryScroll.automaticallyAdjustsContentInsets = false
        let galleryArea = BackdropView()
        configureViewer()
        for subview in [galleryScroll, viewerView, emptyStateView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            galleryArea.addSubview(subview)
            NSLayoutConstraint.activate([
                subview.leadingAnchor.constraint(equalTo: galleryArea.leadingAnchor), subview.trailingAnchor.constraint(equalTo: galleryArea.trailingAnchor),
                subview.topAnchor.constraint(equalTo: galleryArea.topAnchor), subview.bottomAnchor.constraint(equalTo: galleryArea.bottomAnchor)
            ])
        }
        viewerView.isHidden = true
        emptyStateView.isHidden = true

        configureApplyBar()
        let barSeparator = NSBox(); barSeparator.boxType = .separator
        let view = NSView()
        for subview in [scopeBar, galleryArea, barSeparator, applyBar] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
            subview.leadingAnchor.constraint(equalTo: view.leadingAnchor).isActive = true
            subview.trailingAnchor.constraint(equalTo: view.trailingAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            scopeBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            galleryArea.topAnchor.constraint(equalTo: scopeBar.bottomAnchor),
            galleryArea.bottomAnchor.constraint(equalTo: barSeparator.topAnchor),
            barSeparator.bottomAnchor.constraint(equalTo: applyBar.topAnchor),
            applyBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            applyBar.heightAnchor.constraint(equalToConstant: 52),
            galleryArea.heightAnchor.constraint(greaterThanOrEqualToConstant: 240)
        ])
        return view
    }

    private func configureViewer() {
        previewTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        previewMetadataLabel.textColor = .secondaryText
        previewTagsLabel.textColor = .secondaryText
        previewTagsLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        for label in [previewTitleLabel, previewMetadataLabel, previewTagsLabel] {
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.allowsExpansionToolTips = true
            label.isSelectable = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        previewNoticeIcon.symbolConfiguration = .init(pointSize: NSFont.smallSystemFontSize, weight: .regular)
        previewNoticeIcon.contentTintColor = .secondaryText
        previewNoticeLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        previewNoticeLabel.textColor = .secondaryText
        previewNoticeLabel.lineBreakMode = .byTruncatingTail
        previewNoticeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        approximatePreviewNotice.setViews([previewNoticeIcon, previewNoticeLabel], in: .leading)
        approximatePreviewNotice.spacing = 4
        approximatePreviewNotice.setAccessibilityElement(true)
        approximatePreviewNotice.setAccessibilityRole(.staticText)
        approximatePreviewNotice.isHidden = true
        // Even the original's pixels only estimate the desktop: macOS's own rendering isn't reproduced.
        stageView.toolTip = "An estimate of how the selected display and scaling show this wallpaper."
        for (button, symbol, label, key) in [(previewPreviousButton, "chevron.left", "Previous Wallpaper", "←"),
                                             (previewNextButton, "chevron.right", "Next Wallpaper", "→")] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
            button.contentTintColor = .secondaryText
            // Clicking keeps keyboard focus in the preview, so ←/→ go on working after a click.
            button.refusesFirstResponder = true
            button.target = self; button.action = #selector(previewPagerClicked(_:))
            button.toolTip = "\(label) (\(key))"
            button.setAccessibilityLabel(label)
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        }
        previewPositionLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        previewPositionLabel.textColor = .secondaryText
        previewPositionLabel.alignment = .center
        let pager = NSStackView(views: [previewPreviousButton, previewPositionLabel, previewNextButton])
        pager.spacing = 4
        let caption = NSStackView(views: [pager, previewTitleLabel, previewMetadataLabel, previewTagsLabel, approximatePreviewNotice])
        caption.orientation = .vertical
        caption.spacing = 3
        caption.setHuggingPriority(.required, for: .vertical)
        caption.setCustomSpacing(4, after: pager)
        caption.setCustomSpacing(5, after: previewTitleLabel)
        for subview in [stageView, caption] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            viewerView.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            stageView.topAnchor.constraint(equalTo: viewerView.topAnchor, constant: 20),
            stageView.leadingAnchor.constraint(equalTo: viewerView.leadingAnchor, constant: 28),
            stageView.trailingAnchor.constraint(equalTo: viewerView.trailingAnchor, constant: -28),
            caption.topAnchor.constraint(equalTo: stageView.bottomAnchor, constant: 8),
            caption.centerXAnchor.constraint(equalTo: viewerView.centerXAnchor),
            caption.leadingAnchor.constraint(greaterThanOrEqualTo: viewerView.leadingAnchor, constant: 28),
            caption.bottomAnchor.constraint(equalTo: viewerView.bottomAnchor, constant: -16)
        ])
        viewerView.setAccessibilityElement(true)
        viewerView.setAccessibilityRole(.group)
        viewerView.setAccessibilityLabel("Desktop preview")
        viewerView.onNavigate = { [weak self] direction in self?.moveSelection(direction: direction) }
        viewerView.onClose = { [weak self] in self?.setViewerVisible(false) }
    }

    private func configureApplyBar() {
        busyIndicator.style = .spinning
        busyIndicator.controlSize = .small
        busyIndicator.isDisplayedWhenStopped = false
        selectionLabel.lineBreakMode = .byTruncatingTail
        selectionLabel.allowsExpansionToolTips = true
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.allowsExpansionToolTips = true
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryText
        statusLabel.isHidden = true
        let text = NSStackView(views: [selectionLabel, statusLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        for view in [text, selectionLabel, statusLabel] {
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        displayPopUp.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        displayPopUp.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        displayPopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        setWallpaperButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 118).isActive = true
        // The heart and ⋯ keep one place whatever the selection's name or status line, so they never
        // shift while browsing; a wider gap separates them from the three controls that apply.
        applyBar.setViews([busyIndicator, text], in: .leading)
        applyBar.setViews([favoriteButton, moreButton, displayPopUp, scalingPopUp, setWallpaperButton], in: .trailing)
        applyBar.setCustomSpacing(4, after: favoriteButton)
        applyBar.setCustomSpacing(14, after: moreButton)
        applyBar.spacing = 8
        applyBar.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        applyBar.setAccessibilityLabel("Selected wallpaper")
    }

    private func makeRotationPopover() -> NSPopover {
        let title = NSTextField(labelWithString: "Automatic Rotation")
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Change wallpaper:"), rotationPopUp],
            [NSTextField(labelWithString: "Choose from:"), rotationSourcePopUp],
            [NSGridCell.emptyContentView, shuffleButton]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        rotationPopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true
        rotationSourcePopUp.widthAnchor.constraint(equalTo: rotationPopUp.widthAnchor).isActive = true
        rotationSummaryLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        rotationSummaryLabel.textColor = .secondaryLabelColor
        rotationSummaryLabel.preferredMaxLayoutWidth = 290
        let stack = NSStackView(views: [title, grid, rotationSummaryLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        rotationSummaryLabel.widthAnchor.constraint(equalToConstant: 290).isActive = true
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16)
        ])
        let controller = NSViewController()
        controller.view = container
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        return popover
    }

    // MARK: - State restoration

    // Internal for development tests: real startup path with injected, isolated dependencies.
    func restoreState() {
        searchField.stringValue = state.wallhavenSearch.query
        categoryPopUp.selectItem(at: WallhavenCategory.allCases.firstIndex(of: state.wallhavenSearch.category) ?? 0)
        aspectPopUp.selectItem(at: WallhavenAspectRatio.allCases.firstIndex(of: state.wallhavenSearch.aspectRatio) ?? 0)
        sortingPopUp.selectItem(at: WallhavenSorting.allCases.firstIndex(of: state.wallhavenSearch.sorting) ?? 0)
        selectResolutionControl()
        scalingPopUp.selectItem(at: ScalingMode.allCases.firstIndex(of: state.scalingMode) ?? 0)
        stageView.scaling = state.scalingMode
        rotationPopUp.selectItem(at: RotationInterval.allCases.firstIndex(of: state.rotationInterval) ?? 0)
        shuffleButton.state = state.shuffleEnabled ? .on : .off
        refreshDisplays(); refreshCollectionControls(); updateSourceUI(); configureRotationTimer()
        if let path = state.folderPath { loadFolder(URL(fileURLWithPath: path), persistSelection: false) }
        if state.currentSource == .discover { performSearch(page: 1, appending: false) } else { reloadCurrentSource() }
    }

    private var currentItems: [BrowserItem] {
        switch state.currentSource {
        case .discover: return remoteResults.map(BrowserItem.remote)
        case .local: return localURLs.map(BrowserItem.local)
        case .favorites: return state.favorites.map(BrowserItem.remote)
        case .collections: return selectedCollection?.wallpapers.map(BrowserItem.remote) ?? []
        }
    }
    private var selectedCollection: WallpaperCollection? {
        guard let id = state.selectedCollectionID else { return nil }
        return state.collections.first { $0.id == id }
    }
    /// The gallery's visible selection is the only Set target; remembered state just restores it.
    private var selectedIndex: Int? {
        guard let item = collectionView.selectionIndexPaths.first?.item, currentItems.indices.contains(item) else { return nil }
        return item
    }
    private var selectedItem: BrowserItem? {
        guard let index = selectedIndex, currentItems.indices.contains(index) else { return nil }
        return currentItems[index]
    }
    private var selectedReference: WallpaperReference? {
        guard case .remote(let ref) = selectedItem else { return nil }
        return ref
    }
    private var selectedScreen: NSScreen? {
        guard screens.indices.contains(displayPopUp.indexOfSelectedItem) else { return nil }
        return screens[displayPopUp.indexOfSelectedItem]
    }
    private var selectedScalingMode: ScalingMode {
        let index = scalingPopUp.indexOfSelectedItem
        return ScalingMode.allCases.indices.contains(index) ? ScalingMode.allCases[index] : state.scalingMode
    }
    private var selectedRotationInterval: RotationInterval {
        let index = rotationPopUp.indexOfSelectedItem
        return RotationInterval.allCases.indices.contains(index) ? RotationInterval.allCases[index] : .off
    }

    // MARK: - Sources

    @objc func showDiscover(_ sender: Any?) { selectSource(.discover) }
    @objc func showLocal(_ sender: Any?) { selectSource(.local) }
    @objc func showFavorites(_ sender: Any?) { selectSource(.favorites) }
    @objc func showCollections(_ sender: Any?) { selectSource(.collections) }

    private func activate(_ item: SidebarItem) {
        switch item {
        case .discover: selectSource(.discover)
        case .local: selectSource(.local)
        case .favorites: selectSource(.favorites)
        case .collection(let id): state.selectedCollectionID = id; selectSource(.collections)
        }
    }

    private func selectSource(_ source: LibrarySource) {
        searchTask?.cancel()
        searchGeneration = UUID()
        searchTask = nil
        isSearching = false
        state.currentSource = source
        stateStore.save(state)
        pendingAdvance = nil
        remoteThumbnailProvider.reset(); cancelDetails()
        isViewerVisible = false
        updateSourceUI()
        if state.currentSource == .discover && remoteResults.isEmpty { performSearch(page: 1, appending: false) }
        else { reloadCurrentSource() }
    }

    private var currentSidebarItem: SidebarItem? {
        switch state.currentSource {
        case .discover: return .discover
        case .local: return .local
        case .favorites: return .favorites
        case .collections: return selectedCollection.map { .collection($0.id) }
        }
    }

    @objc func toggleSidebar(_ sender: Any?) { splitViewController?.toggleSidebar(sender) }
    private var isSidebarVisible: Bool { splitViewController?.splitViewItems.first?.isCollapsed == false }

    // MARK: - Search

    @objc func focusSearch(_ sender: Any?) {
        if state.currentSource != .discover { selectSource(.discover) }
        if let searchToolbarItem, window?.toolbar?.isVisible == true { searchToolbarItem.beginSearchInteraction() }
        else { window?.makeFirstResponder(searchField) }
    }

    // A new search or filter replaces the results being browsed, so it returns to the gallery that shows them,
    // rather than leaving the preview to vanish and its wallpaper to change when the request completes.
    @objc func search(_ sender: Any?) {
        isViewerVisible = false
        if state.currentSource != .discover {
            state.currentSource = .discover; updateSourceUI()
        }
        persistSearchOptions(); performSearch(page: 1, appending: false)
    }

    @objc private func searchOptionChanged(_ sender: Any?) {
        persistSearchOptions()
        if state.currentSource == .discover { isViewerVisible = false; performSearch(page: 1, appending: false) } else { invalidateSearch() }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === searchField else { return }
        persistSearchOptions()
        invalidateSearch()
        // Typing elsewhere doesn't filter the folder or library: say where the search goes.
        let scope = "Press Return to search Wallhaven in Discover."
        if state.currentSource != .discover, statusLabel.stringValue != scope { showStatus(scope, isError: false) }
    }

    private func invalidateSearch() {
        pendingAdvance = nil
        searchTask?.cancel()
        searchGeneration = UUID()
        isSearching = false
        updateEmptyAndPagination()
        updateControlAvailability()
    }

    private func persistSearchOptions() {
        state.wallhavenSearch.query = searchField.stringValue
        if WallhavenCategory.allCases.indices.contains(categoryPopUp.indexOfSelectedItem) { state.wallhavenSearch.category = WallhavenCategory.allCases[categoryPopUp.indexOfSelectedItem] }
        if WallhavenAspectRatio.allCases.indices.contains(aspectPopUp.indexOfSelectedItem) { state.wallhavenSearch.aspectRatio = WallhavenAspectRatio.allCases[aspectPopUp.indexOfSelectedItem] }
        if WallhavenSorting.allCases.indices.contains(sortingPopUp.indexOfSelectedItem) { state.wallhavenSearch.sorting = WallhavenSorting.allCases[sortingPopUp.indexOfSelectedItem] }
        applyResolutionSelection(); stateStore.save(state)
    }

    private func selectResolutionControl() {
        if state.wallhavenSearch.usesDisplayMinimum { resolutionPopUp.selectItem(at: 0); return }
        switch (state.wallhavenSearch.minimumWidth, state.wallhavenSearch.minimumHeight) {
        case (nil, nil): resolutionPopUp.selectItem(at: 1)
        case (1920, 1080): resolutionPopUp.selectItem(at: 2)
        case (2560, 1440): resolutionPopUp.selectItem(at: 3)
        case (3840, 2160): resolutionPopUp.selectItem(at: 4)
        default: resolutionPopUp.selectItem(at: 1)
        }
    }

    private func applyResolutionSelection() {
        switch resolutionPopUp.indexOfSelectedItem {
        case 0: state.wallhavenSearch.usesDisplayMinimum = true; updateDisplayMinimum()
        case 2: state.wallhavenSearch.usesDisplayMinimum = false; state.wallhavenSearch.minimumWidth = 1920; state.wallhavenSearch.minimumHeight = 1080
        case 3: state.wallhavenSearch.usesDisplayMinimum = false; state.wallhavenSearch.minimumWidth = 2560; state.wallhavenSearch.minimumHeight = 1440
        case 4: state.wallhavenSearch.usesDisplayMinimum = false; state.wallhavenSearch.minimumWidth = 3840; state.wallhavenSearch.minimumHeight = 2160
        default: state.wallhavenSearch.usesDisplayMinimum = false; state.wallhavenSearch.minimumWidth = nil; state.wallhavenSearch.minimumHeight = nil
        }
    }

    private func updateDisplayMinimum() {
        guard state.wallhavenSearch.usesDisplayMinimum, let screen = selectedScreen else { return }
        state.wallhavenSearch.minimumWidth = Int(screen.frame.width * screen.backingScaleFactor)
        state.wallhavenSearch.minimumHeight = Int(screen.frame.height * screen.backingScaleFactor)
    }

    private func performSearch(page: Int, appending: Bool) {
        searchTask?.cancel()
        let generation = UUID()
        searchGeneration = generation
        searchErrorText = nil
        if !appending {
            pendingAdvance = nil
            remoteThumbnailProvider.reset()
            remoteResults = []
            currentPage = 0; lastPage = 0; totalResults = 0
            lastAppendFailure = nil
            collectionView.reloadData()
            restoreSelection()
        }
        isSearching = true
        updateEmptyAndPagination(); updateControlAvailability()
        // A further page extends the visible results, so it repeats their request, not the edited controls.
        let options = appending ? resultOptions ?? state.wallhavenSearch : state.wallhavenSearch
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await provider.search(options: options, page: page)
                try Task.checkCancellation()
                guard searchGeneration == generation, state.currentSource == .discover else { return }
                resultOptions = options
                if appending {
                    let known = Set(remoteResults.map(\.identityKey))
                    let added = result.wallpapers.filter { !known.contains($0.identityKey) }
                    let start = remoteResults.count
                    remoteResults.append(contentsOf: added)
                    collectionView.insertItems(at: Set((start..<remoteResults.count).map { IndexPath(item: $0, section: 0) }))
                } else {
                    remoteResults = result.wallpapers
                    state.selectedRemoteIdentity = remoteResults.first?.identityKey
                    collectionView.reloadData(); restoreSelection()
                }
                currentPage = result.currentPage; lastPage = result.lastPage; totalResults = result.total
                isSearching = false
                updateEmptyAndPagination(); updateControlAvailability(); stateStore.save(state)
                if appending, statusLabel.stringValue == Self.loadingMoreStatus { showStatus("", isError: false) }
                if let remaining = result.rateLimit.remaining, remaining < 10 {
                    showStatus("Wallhaven allows \(remaining) more requests this minute.", isError: false)
                }
                if appending { finishPendingAdvance(generation) }
                DispatchQueue.main.async { [weak self] in self?.loadMoreIfNeeded() }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, searchGeneration == generation else { return }
                isSearching = false
                if appending {
                    pendingAdvance = nil
                    let failure = Date()
                    lastAppendFailure = failure
                    appendRetryTask?.cancel()
                    appendRetryTask = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(((self?.appendRetryCooldown ?? 5) + 0.1) * 1_000_000_000))
                        guard let self, !Task.isCancelled, lastAppendFailure == failure else { return }
                        updateControlAvailability()
                    }
                    showStatus("Couldn’t load more results. \(friendlyMessage(for: error))", isError: true)
                } else {
                    searchErrorText = friendlyMessage(for: error)
                    showStatus("", isError: false)
                }
                updateEmptyAndPagination(); updateControlAvailability()
            }
        }
    }

    @objc private func galleryDidScroll(_ notification: Notification) { loadMoreIfNeeded() }

    /// Loads the next Discover page when the user nears the end of the grid. A failed page waits
    /// a few seconds before scrolling can retry it, so an outage never turns into a request loop.
    /// Discover has result pages that aren't loaded yet: the loaded results aren't the whole set.
    private var hasUnloadedResults: Bool { state.currentSource == .discover && currentPage < lastPage }
    private var canLoadMoreResults: Bool {
        hasUnloadedResults && !isSearching && Date().timeIntervalSince(lastAppendFailure ?? .distantPast) > appendRetryCooldown
    }

    private func loadMoreIfNeeded() {
        guard canLoadMoreResults, !galleryScroll.isHidden else { return }
        let visible = galleryScroll.documentVisibleRect
        guard visible.maxY >= collectionView.frame.height - max(visible.height * 0.5, 200) else { return }
        performSearch(page: currentPage + 1, appending: true)
    }

    // MARK: - Local folder

    @objc func chooseFolder(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a Wallpaper Folder"; panel.prompt = "Choose Folder"
        panel.message = "Wallpier shows the JPEG, PNG and HEIC images in the folder you choose."
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if let path = state.folderPath { panel.directoryURL = URL(fileURLWithPath: path) }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let folderURL = panel.url, let self else { return }
            openFolder(folderURL)
        }
    }

    func openFolder(_ folderURL: URL) { selectSource(.local); loadFolder(folderURL, persistSelection: true) }

    private func loadFolder(_ folderURL: URL, persistSelection: Bool) {
        let standardizedURL = folderURL.standardizedFileURL
        let requestID = UUID(); folderLoadID = requestID; thumbnailProvider.reset()
        if state.currentSource == .local { localURLs = []; collectionView.reloadData(); restoreSelection() }
        folderPathLabel.stringValue = (standardizedURL.path as NSString).abbreviatingWithTildeInPath; folderPathLabel.toolTip = standardizedURL.path
        isLoadingFolder = true
        updateSourceUI(); updateEmptyAndPagination()
        Task.detached(priority: .userInitiated) {
            let result = Result { try SupportedWallpaperFiles.images(in: standardizedURL) }
            await MainActor.run { [weak self] in
                guard let self, self.folderLoadID == requestID else { return }
                self.isLoadingFolder = false
                switch result {
                case .success(let urls):
                    self.localURLs = urls
                    self.state.folderPath = standardizedURL.path
                    if persistSelection || !urls.contains(where: { $0.path == self.state.selectedImagePath }) { self.state.selectedImagePath = urls.first?.path }
                    self.stateStore.save(self.state)
                    self.refreshSidebar()
                    if self.state.currentSource == .local {
                        self.updateSourceUI()
                        self.reloadCurrentSource()
                        self.showStatus(urls.isEmpty ? "No supported images found in this folder." : "Loaded \(urls.count) local wallpapers.", isError: false)
                    }
                case .failure(let error):
                    self.updateEmptyAndPagination()
                    self.presentError(title: "Could Not Open Folder", message: error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Setting wallpapers

    @objc func setWallpaper(_ sender: Any?) {
        guard rotationTask == nil, downloadTask == nil else { showStatus("Wait for the current download to finish.", isError: false); return }
        guard let item = selectedItem else { showStatus("Select a wallpaper first.", isError: true); NSSound.beep(); return }
        guard let screen = selectedScreen else { showStatus("No display is available.", isError: true); NSSound.beep(); return }
        switch item {
        case .local(let url):
            let scaling = selectedScalingMode
            downloadTask = Task { [weak self] in
                guard let self else { return }
                defer { downloadTask = nil; updateControlAvailability() }
                await applyWallpaper(url, to: screen, scaling: scaling, source: .user)
            }
            updateControlAvailability()
        case .remote(let ref): downloadAndSet(ref, screen: screen, source: .user)
        }
    }

    private func downloadAndSet(_ reference: WallpaperReference, screen: NSScreen, source: SetSource) {
        guard downloadTask == nil else { return }
        let scaling = selectedScalingMode
        setWallpaperButton.isEnabled = false
        showStatus("Preparing the full-resolution original…", isError: false)
        downloadTask = Task { [weak self] in
            guard let self else { return }
            defer { downloadTask = nil; updateControlAvailability() }
            do {
                let url = try await localOriginal(for: reference)
                try Task.checkCancellation()
                await applyWallpaper(url, to: screen, scaling: scaling, source: source)
            } catch is CancellationError {
                return
            } catch {
                let message = friendlyMessage(for: error)
                if source == .user { presentError(title: "Could Not Set Wallpaper", message: message) }
                else { showStatus("Automatic rotation failed: \(message)", isError: true) }
            }
        }
        updateControlAvailability()
    }

    private func localOriginal(for reference: WallpaperReference) async throws -> URL {
        if let cached = try await originalCache.cachedURL(for: reference) {
            updateReference(reference, cachedPath: cached.path); showOriginalIfSelected(reference, at: cached); return cached
        }
        showStatus("Downloading the \(reference.resolution) original from Wallhaven…", isError: false)
        let temporary = try await provider.downloadOriginal(for: reference)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        let installed = try await originalCache.installDownloadedFile(temporary, for: reference, protectedPaths: currentProtectedPaths())
        updateReference(reference, cachedPath: installed.path)
        showOriginalIfSelected(reference, at: installed)
        return installed
    }

    private func updateReference(_ reference: WallpaperReference, cachedPath: String? = nil) {
        var updated = reference
        let existing = remoteResults.first { $0.identityKey == reference.identityKey }
            ?? state.favorites.first { $0.identityKey == reference.identityKey }
            ?? state.collections.lazy.flatMap(\.wallpapers).first { $0.identityKey == reference.identityKey }
        updated.cachedLocalPath = cachedPath ?? existing?.cachedLocalPath ?? reference.cachedLocalPath
        if let cachedPath { updated.cachedLocalPath = cachedPath }
        if let index = remoteResults.firstIndex(where: { $0.identityKey == updated.identityKey }) { remoteResults[index] = updated }
        state.favorites = state.favorites.map { $0.identityKey == updated.identityKey ? updated : $0 }
        state.collections = state.collections.map { collection in
            let mapped = collection.wallpapers.map { $0.identityKey == updated.identityKey ? updated : $0 }
            return WallpaperCollection(id: collection.id, name: collection.name, wallpapers: mapped)
        }
        stateStore.save(state)
    }

    private func applyWallpaper(_ imageURL: URL, to screen: NSScreen, scaling: ScalingMode, source: SetSource) async {
        let displayID = identifier(for: screen); let displayName = description(for: screen)
        // Prefer the current public OS assignment over possibly stale persisted state.
        let prior = systemAssignment(for: screen, displayID: displayID, displayName: displayName) ?? state.assignment(for: displayID)
        let replacement = DisplayAssignment(displayID: displayID, displayName: displayName, imagePath: imageURL.path, scaling: scaling)
        let entry: HistoryEntry?
        if let prior, prior != replacement { entry = await historyStore.prepare(previous: prior, replacement: replacement) }
        else { entry = nil }
        do {
            try Task.checkCancellation()
            let result = try wallpaperService.setWallpaper(imageURL: imageURL, on: try availableScreen(matching: screen), scaling: scaling)
            if let entry { state.appendHistory(entry) }
            // With no known prior assignment, older entries cannot undo this new change.
            else if prior == nil { state.history.removeAll() }
            // The assignment and history record what this change captured; the display and scaling
            // choices stay whatever the user has selected since, so state keeps agreeing with the controls.
            state.setAssignment(replacement)
            let saved = stateStore.save(state)
            let undoNote = prior == nil || entry?.undoUnavailableReason != nil ? " Undo unavailable for this change." : ""
            showStatus(String(format: "Set %@ on %@ in %.1f ms.", imageURL.lastPathComponent, screen.localizedName, result.elapsedTime * 1_000) + undoNote, isError: false)
            logger.info("Set \(imageURL.lastPathComponent, privacy: .public) on \(displayName, privacy: .public)")
            refreshUndoAvailability()
            if saved { await cleanupRollbackFiles() }
            updateControlAvailability()
        } catch {
            if !Task.isCancelled {
                logger.error("Wallpaper set failed: \(error.localizedDescription, privacy: .public)")
                if source == .user { presentError(title: "Could Not Set Wallpaper", message: error.localizedDescription) }
                else { showStatus("Automatic rotation failed: \(error.localizedDescription)", isError: true) }
            }
            if stateStore.save(state) { await cleanupRollbackFiles() }
        }
    }

    private func availableScreen(matching captured: NSScreen) throws -> NSScreen {
        guard let screen = availableScreens().first(where: { identifier(for: $0) == identifier(for: captured) }) else {
            throw NSError(domain: "Wallpier", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "The display selected for this wallpaper change is not currently available. Reconnect it and try again."])
        }
        return screen
    }

    private func systemAssignment(for screen: NSScreen, displayID: String, displayName: String) -> DisplayAssignment? {
        guard let current = wallpaperService.currentWallpaper(on: screen) else { return nil }
        return DisplayAssignment(displayID: displayID, displayName: displayName, imagePath: current.imageURL.path, scaling: current.scaling)
    }

    // MARK: - Selection and preview

    @objc func previousWallpaper(_ sender: Any?) { moveSelection(direction: -1) }
    @objc func nextWallpaper(_ sender: Any?) { moveSelection(direction: 1) }

    /// Where Previous (−1) or Next (+1) leads. Complete sources wrap around; Discover doesn't while more results
    /// remain on Wallhaven, since wrapping would present the loaded pages as the whole result set.
    private func navigationIndex(_ direction: Int) -> Int? {
        guard let next = WallpaperNavigation.index(after: selectedIndex, direction: direction, count: currentItems.count),
              next != selectedIndex else { return nil }
        if hasUnloadedResults, let current = selectedIndex, direction > 0 ? next < current : next > current { return nil }
        return next
    }

    private func canNavigate(_ direction: Int) -> Bool {
        navigationIndex(direction) != nil || (direction > 0 && selectedIndex != nil && canLoadMoreResults)
    }

    /// The one navigation path for arrow keys, ⌘[ ⌘] and the preview's buttons. Next past the last loaded result
    /// loads the next page, as scrolling the gallery would, and stays put: arriving results never move the selection.
    private func moveSelection(direction: Int) {
        if let next = navigationIndex(direction) { selectItem(at: next); return }
        if direction > 0, let identity = selectedItem?.identifier, canLoadMoreResults {
            showStatus(Self.loadingMoreStatus, isError: false)
            performSearch(page: currentPage + 1, appending: true)
            pendingAdvance = PendingAdvance(generation: searchGeneration, identity: identity, revision: selectionRevision, query: resultOptions)
            return
        }
        NSSound.beep()
    }

    /// The page a boundary Next asked for has arrived: finish that move only if it still means the same thing —
    /// same request, preview still open, same wallpaper selected with no selection change since, same applied query.
    private func finishPendingAdvance(_ generation: UUID) {
        guard let pending = pendingAdvance, pending.generation == generation else { return }
        pendingAdvance = nil
        guard isViewerVisible, pending.revision == selectionRevision, selectedItem?.identifier == pending.identity,
              resultOptions == pending.query, let index = selectedIndex, currentItems.indices.contains(index + 1) else { return }
        selectItem(at: index + 1)
    }

    /// Clicking the pager gives the keyboard back to the preview, ending any search-field editing (its draft is kept).
    @objc private func previewPagerClicked(_ sender: NSButton) {
        window?.makeFirstResponder(viewerView)
        moveSelection(direction: sender === previewPreviousButton ? -1 : 1)
    }

    /// Closing the preview ends everything it was waiting for: details, a pending boundary move, the loading state.
    private func endPreviewSession() {
        cancelDetails()
        pendingAdvance = nil
        stageView.placeholder = .none
    }

    private func updatePreviewNavigation() {
        let count = currentItems.count
        if let index = selectedIndex {
            previewPositionLabel.stringValue = "\((index + 1).formatted()) of \(count.formatted())" + (hasUnloadedResults ? " loaded" : "")
        } else {
            previewPositionLabel.stringValue = ""
        }
        previewPositionLabel.toolTip = hasUnloadedResults
            ? "\(count.formatted()) of \(totalResults.formatted()) Wallhaven results are loaded. Next at the last one loads more." : nil
        previewPositionLabel.setAccessibilityLabel(previewPositionLabel.stringValue.isEmpty ? nil : "Wallpaper \(previewPositionLabel.stringValue)")
        previewPreviousButton.isEnabled = canNavigate(-1)
        previewNextButton.isEnabled = canNavigate(1)
    }

    private func selectItem(at index: Int) {
        guard currentItems.indices.contains(index) else { return }
        let item = currentItems[index]; let indexPath = IndexPath(item: index, section: 0)
        collectionView.selectionIndexPaths = [indexPath]
        collectionView.scrollToItems(at: [indexPath], scrollPosition: .nearestVerticalEdge)
        rememberSelection(item); updatePreview(for: item)
        updateControlAvailability()
    }

    private func rememberSelection(_ item: BrowserItem) {
        selectionRevision += 1
        switch item {
        case .local(let url): state.selectedImagePath = url.path
        case .remote(let ref): state.selectedRemoteIdentity = ref.identityKey
        }
        stateStore.save(state)
    }

    private func restoreSelection() {
        guard !currentItems.isEmpty else { collectionView.selectionIndexPaths = []; updatePreview(for: nil); return }
        let index: Int
        switch state.currentSource {
        case .local:
            index = currentItems.firstIndex { if case .local(let url) = $0 { return url.path == state.selectedImagePath }; return false } ?? 0
        default: index = currentItems.firstIndex { $0.identifier == state.selectedRemoteIdentity } ?? 0
        }
        selectItem(at: index)
    }

    private func updatePreview(for item: BrowserItem?) {
        if item?.identifier != detailIdentity { cancelDetails() }
        stageView.image = nil
        stageView.placeholder = .none
        stageFidelity = .none
        updatePreviewNotice()
        guard let item else {
            previewTitleLabel.stringValue = "No Wallpaper Selected"
            previewMetadataLabel.stringValue = ""
            previewTagsLabel.stringValue = ""
            stageView.setAccessibilityLabel("No wallpaper selected")
            updateSelectionSummary()
            return
        }
        previewTitleLabel.stringValue = item.title
        switch item {
        case .local(let url):
            stageView.imagePixelSize = .zero
            // The folder is already named by the window title and folder bar; the caption describes the picture.
            previewMetadataLabel.stringValue = ""
            previewTagsLabel.stringValue = url.pathExtension.uppercased()
            Task.detached(priority: .utility) {
                let size = DesktopPreviewView.pixelSize(of: url)
                await MainActor.run { [weak self] in
                    guard let self, case .local(let selectedURL) = self.selectedItem, selectedURL == url, let size else { return }
                    self.stageView.imagePixelSize = size
                    self.previewMetadataLabel.stringValue = WallpaperShape.summary(width: Int(size.width), height: Int(size.height))
                }
            }
        case .remote(let ref):
            configureRemoteMetadata(ref)
            stageView.imagePixelSize = CGSize(width: ref.width, height: ref.height)
        }
        stageView.setAccessibilityLabel("Desktop preview of \(item.title)")
        updateSelectionSummary()
        if isViewerVisible { loadPreviewContent(for: item) }
    }

    /// Draws the selected wallpaper on the stage and fetches the details the preview shows. Only while
    /// the preview is visible: the gallery shows neither, so browsing it costs no requests.
    private func loadPreviewContent(for item: BrowserItem) {
        if stageView.image == nil { stageView.placeholder = .loading }
        switch item {
        case .local(let url): loadLocalPreview(url, identity: item.identifier)
        case .remote(let ref):
            // A validated cached original is best, but checking takes a moment: show the most faithful
            // thumbnail meanwhile unless an original is expected. Nothing here downloads an original.
            if ref.cachedLocalPath == nil { loadRemotePreview(ref) }
            Task { [weak self] in
                let cached = try? await self?.originalCache.cachedURL(for: ref)
                guard let self, selectedItem?.identifier == ref.identityKey else { return }
                if let cached { loadLocalPreview(cached, identity: ref.identityKey) { [weak self] in self?.loadRemotePreview(ref) } }
                else if ref.cachedLocalPath != nil { loadRemotePreview(ref) }
            }
            fetchDetailsIfNeeded(for: ref)
        }
    }

    private func loadLocalPreview(_ url: URL, identity: String, onFailure: (() -> Void)? = nil) {
        thumbnailProvider.requestThumbnail(for: url, maximumPixelSize: 1800) { [weak self] image in
            guard let self, selectedItem?.identifier == identity else { return }
            guard let image else {
                if let onFailure { onFailure() } else if isViewerVisible, stageFidelity == .none { stageView.placeholder = .unavailable }
                return
            }
            showOnStage(image, fidelity: .original, identity: identity)
        }
    }

    private func loadRemotePreview(_ ref: WallpaperReference) {
        let (url, fidelity) = ref.remotePreview
        remoteThumbnailProvider.requestThumbnail(for: url, maximumPixelSize: 1000) { [weak self] image in
            guard let self else { return }
            guard let image else {
                if isViewerVisible, selectedItem?.identifier == ref.identityKey, stageFidelity == .none { stageView.placeholder = .unavailable }
                return
            }
            showOnStage(image, fidelity: fidelity, identity: ref.identityKey)
        }
    }

    /// The only way an image reaches the stage: it must belong to the current selection and be at least
    /// as faithful as what's shown, so late or obsolete completions never downgrade the preview.
    private func showOnStage(_ image: NSImage, fidelity: PreviewFidelity, identity: String) {
        guard selectedItem?.identifier == identity, fidelity >= stageFidelity else { return }
        stageView.image = image
        stageFidelity = fidelity
        updatePreviewNotice()
    }

    private func updatePreviewNotice() {
        guard let notice = stageFidelity.notice else { approximatePreviewNotice.isHidden = true; return }
        previewNoticeIcon.image = NSImage(systemSymbolName: notice.symbol, accessibilityDescription: nil)
        previewNoticeLabel.stringValue = notice.text
        approximatePreviewNotice.toolTip = notice.help
        approximatePreviewNotice.setAccessibilityLabel(notice.text)
        approximatePreviewNotice.setAccessibilityHelp(notice.help)
        approximatePreviewNotice.isHidden = false
    }

    /// A Set or rotation made this original available: upgrade the preview only if it still shows that wallpaper.
    private func showOriginalIfSelected(_ reference: WallpaperReference, at url: URL) {
        guard let selected = selectedReference, selected.identityKey == reference.identityKey else { return }
        configureRemoteMetadata(selected)
        if isViewerVisible { loadLocalPreview(url, identity: selected.identityKey) }
    }

    private func configureRemoteMetadata(_ reference: WallpaperReference) {
        let parts = [WallpaperShape.summary(width: reference.width, height: reference.height), reference.uploader.map { "by \($0)" },
                     reference.cachedLocalPath == nil ? nil : "Original downloaded"]
        previewMetadataLabel.stringValue = parts.compactMap { $0 }.joined(separator: " · ")
        previewTagsLabel.stringValue = reference.tags.isEmpty ? "Wallhaven · SFW" : reference.tags.joined(separator: " · ")
        updateSelectionSummary()
    }

    /// Uploader and tags, and the uncropped thumbnail older references lack, come from the API. Requested
    /// once per selected wallpaper, after a short dwell, and a throttled API only leaves them missing.
    private func fetchDetailsIfNeeded(for reference: WallpaperReference) {
        guard reference.uploader == nil || reference.tags.isEmpty || reference.remotePreview.fidelity == .croppedThumbnail,
              detailIdentity != reference.identityKey else { return }
        detailTask?.cancel()
        detailIdentity = reference.identityKey
        detailTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.detailDwellNanoseconds)
                guard let self, isViewerVisible, selectedReference?.identityKey == reference.identityKey else { return }
                let detailed = try await provider.fetchDetails(for: reference)
                try Task.checkCancellation(); updateReference(detailed)
                guard let current = selectedReference, current.identityKey == detailed.identityKey else { return }
                configureRemoteMetadata(current)
                if current.remotePreview.fidelity > stageFidelity { loadRemotePreview(current) }
            } catch is CancellationError { return }
            catch { self?.logger.error("Wallhaven detail failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private func cancelDetails() {
        detailTask?.cancel()
        detailIdentity = nil
    }

    /// First line of the apply bar: what Set Wallpaper will apply.
    private func updateSelectionSummary() {
        let title: String, detail: String
        switch selectedItem {
        case nil: title = "No Wallpaper Selected"; detail = ""
        case .local(let url)?: title = url.deletingPathExtension().lastPathComponent; detail = url.pathExtension.uppercased()
        case .remote(let ref)?: title = ref.wallpaperID; detail = WallpaperShape.summary(width: ref.width, height: ref.height)
        }
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium),
            .foregroundColor: selectedItem == nil ? NSColor.secondaryLabelColor : NSColor.labelColor])
        if !detail.isEmpty {
            text.append(NSAttributedString(string: "  " + detail, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
                .foregroundColor: NSColor.secondaryText]))
        }
        selectionLabel.attributedStringValue = text
        let isFavorite = selectedReference.map(state.isFavorite) ?? false
        favoriteButton.image = NSImage(systemSymbolName: isFavorite ? "heart.fill" : "heart",
                                       accessibilityDescription: isFavorite ? "Remove from Favorites" : "Add to Favorites")
        favoriteButton.contentTintColor = isFavorite ? .systemPink : .secondaryLabelColor
        favoriteButton.toolTip = isFavorite ? "Remove from Favorites (⌘D)" : "Add to Favorites (⌘D)"
        favoriteButton.setAccessibilityLabel(isFavorite ? "Remove from Favorites" : "Add to Favorites")
    }

    // MARK: - Gallery / desktop preview mode

    @objc func toggleViewer(_ sender: Any?) { setViewerVisible(!isViewerVisible) }

    @objc private func viewModeChanged(_ sender: NSSegmentedControl) { setViewerVisible(sender.selectedSegment == 1) }

    private func setViewerVisible(_ visible: Bool) {
        guard !visible || selectedItem != nil else { viewModeControl.selectedSegment = 0; NSSound.beep(); return }
        guard visible != isViewerVisible else { return }
        isViewerVisible = visible
        updateContentVisibility(animated: true)
        if visible, let item = selectedItem { loadPreviewContent(for: item) }
        window?.makeFirstResponder(visible ? viewerView : collectionView)
        if !visible, let index = selectedIndex {
            collectionView.scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: .nearestVerticalEdge)
        }
    }

    private func updateContentVisibility(animated: Bool = false) {
        let hasItems = !currentItems.isEmpty
        let showViewer = isViewerVisible && hasItems && selectedItem != nil
        if !showViewer && isViewerVisible { isViewerVisible = false }
        let target: NSView = showViewer ? viewerView : galleryScroll
        let changed = target.isHidden
        viewerView.isHidden = !showViewer
        galleryScroll.isHidden = showViewer || !hasItems
        updateScopeBar()
        viewModeControl.selectedSegment = showViewer ? 1 : 0
        viewModeControl.setEnabled(hasItems, forSegment: 1)
        if !showViewer, window?.firstResponder === viewerView { window?.makeFirstResponder(collectionView) }
        if animated, changed, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            target.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
                target.animator().alphaValue = 1
            }
        } else {
            target.alphaValue = 1
        }
    }

    @objc func makeThumbnailsLarger(_ sender: Any?) { changeThumbnailSize(by: 1) }
    @objc func makeThumbnailsSmaller(_ sender: Any?) { changeThumbnailSize(by: -1) }

    private var thumbnailSizeIndex: Int { GalleryLayout.thumbnailWidths.firstIndex(of: galleryLayout.targetWidth) ?? 1 }

    private func changeThumbnailSize(by step: Int) {
        let index = thumbnailSizeIndex + step
        guard GalleryLayout.thumbnailWidths.indices.contains(index) else { NSSound.beep(); return }
        galleryLayout.targetWidth = GalleryLayout.thumbnailWidths[index]
        UserDefaults.standard.set(index, forKey: "GalleryThumbnailSize")
        collectionView.reloadData()
        if let index = selectedIndex {
            collectionView.selectionIndexPaths = [IndexPath(item: index, section: 0)]
            collectionView.scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: .nearestVerticalEdge)
        }
    }

    // MARK: - Favorites and collections

    @objc func toggleFavorite(_ sender: Any?) {
        guard let ref = selectedReference else { return }
        if let index = state.favorites.firstIndex(where: { $0.identityKey == ref.identityKey }) {
            return setMembership(ref, in: .favorites, at: index, member: false)
        }
        setMembership(ref, in: .favorites, at: state.favorites.count, member: true, addition: true)
    }

    @objc func addToCollection(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let ref = selectedReference,
              let collection = state.collections.first(where: { $0.id == id }) else { return }
        setMembership(ref, in: .collection(id), at: collection.wallpapers.count, member: true, addition: true)
    }

    @objc func removeFromCollection(_ sender: Any?) {
        guard let id = state.selectedCollectionID, let ref = selectedReference,
              let index = selectedCollection?.wallpapers.firstIndex(where: { $0.identityKey == ref.identityKey }) else { return }
        setMembership(ref, in: .collection(id), at: index, member: false)
    }

    /// Delete key and ⌘⌫: removes the selection from the favorites or collection being viewed.
    @objc func removeSelected(_ sender: Any?) {
        switch state.currentSource {
        case .favorites where selectedReference != nil: toggleFavorite(sender)
        case .collections where selectedReference != nil: removeFromCollection(sender)
        default: NSSound.beep()
        }
    }

    private var currentList: MemberList? {
        switch state.currentSource {
        case .favorites: return .favorites
        case .collections: return state.selectedCollectionID.map(MemberList.collection)
        default: return nil
        }
    }

    /// Adds a wallpaper to, or removes it from, Favorites or a collection at a position. Each real
    /// change registers its opposite with the window's Undo (⌘Z, ⇧⌘Z) for this session only, which
    /// also retires any obsolete Redo; a change that changes nothing registers nothing. Restoring
    /// the desktop is the separate, persistent Undo Wallpaper Change.
    private func setMembership(_ ref: WallpaperReference, in list: MemberList, at index: Int, member: Bool, addition: Bool = false) {
        var members: [WallpaperReference], name: String
        switch list {
        case .favorites: members = state.favorites; name = "Favorites"
        case .collection(let id):
            guard let collection = state.collections.first(where: { $0.id == id }) else { return }
            members = collection.wallpapers; name = "“\(collection.name)”"
        }
        guard members.contains(where: { $0.identityKey == ref.identityKey }) != member else { return }
        // Removing the member rotation last used keeps rotation's place: it continues with the one that followed.
        if !member, case .collection(let id) = list, id == state.activeRotationCollectionID, state.rotationCursor == ref.identityKey,
           let position = members.firstIndex(where: { $0.identityKey == ref.identityKey }) {
            state.rotationCursor = position > 0 ? members[position - 1].identityKey : nil
        }
        if member { members.insert(ref, at: min(index, members.count)) } else { members.removeAll { $0.identityKey == ref.identityKey } }
        switch list {
        case .favorites: state.favorites = members
        case .collection(let id):
            guard let position = state.collections.firstIndex(where: { $0.id == id }) else { return }
            state.collections[position] = WallpaperCollection(id: id, name: state.collections[position].name, wallpapers: members)
        }
        // In the list being viewed, select the restored wallpaper, or keep the grid position after a removal.
        let viewing = currentList == list
        if viewing, !members.isEmpty { state.selectedRemoteIdentity = member ? ref.identityKey : members[min(index, members.count - 1)].identityKey }
        stateStore.save(state); refreshCollectionControls()
        if viewing { reloadCurrentSource() } else { updateSelectionSummary() }
        if let undoManager = window?.undoManager {
            undoManager.registerUndo(withTarget: self) { $0.setMembership(ref, in: list, at: index, member: !member, addition: addition) }
            undoManager.setActionName(addition ? "Add to \(name)" : "Remove from \(name)")
        }
        showStatus(member ? "\(addition ? "Added" : "Restored") \(ref.wallpaperID) to \(name)." : "Removed \(ref.wallpaperID) from \(name).", isError: false)
    }

    /// Adds dropped wallpapers (by identity) to Favorites or a collection.
    private func collect(_ identities: [String], into target: SidebarItem) -> Bool {
        let known = remoteResults + state.favorites + state.collections.flatMap(\.wallpapers)
        let references = identities.compactMap { identity in known.first { $0.identityKey == identity } }
        guard !references.isEmpty else { return false }
        let list: MemberList, name: String, members: [WallpaperReference]
        switch target {
        case .favorites: list = .favorites; name = "Favorites"; members = state.favorites
        case .collection(let id):
            guard let collection = state.collections.first(where: { $0.id == id }) else { return false }
            list = .collection(id); name = collection.name; members = collection.wallpapers
        default: return false
        }
        var present = Set(members.map(\.identityKey))
        let adding = references.filter { present.insert($0.identityKey).inserted }
        // One drop is one Undo step; a drop that adds nothing leaves Undo and Redo untouched.
        guard !adding.isEmpty else { return true }
        window?.undoManager?.beginUndoGrouping()
        for (offset, ref) in adding.enumerated() {
            setMembership(ref, in: list, at: members.count + offset, member: true, addition: true)
        }
        window?.undoManager?.endUndoGrouping()
        showStatus("Added \(adding.count == 1 ? adding[0].wallpaperID : "\(adding.count) wallpapers") to \(name).", isError: false)
        return true
    }

    @objc func openSourcePage(_ sender: Any?) {
        switch selectedItem {
        case .remote(let ref)?: NSWorkspace.shared.open(ref.sourcePageURL)
        case .local(let url)?: NSWorkspace.shared.activateFileViewerSelecting([url])
        case nil: NSSound.beep()
        }
    }

    @objc func copy(_ sender: Any?) {
        guard let item = selectedItem else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch item {
        case .remote(let ref): pasteboard.writeObjects([ref.sourcePageURL as NSURL])
        case .local(let url): pasteboard.writeObjects([url as NSURL])
        }
    }

    @objc func createCollection(_ sender: Any?) {
        // From an item's menu, the new collection starts with that wallpaper.
        let adding = (sender as? NSMenuItem)?.representedObject as? String == "withSelection" ? selectedReference : nil
        promptForCollectionName(title: "New Collection", initialValue: "") { [weak self] name in
            guard let self, !name.isEmpty else { return }
            let collection = WallpaperCollection(name: name)
            state.collections.append(collection); stateStore.save(state)
            if let adding { setMembership(adding, in: .collection(collection.id), at: 0, member: true, addition: true) }
            else { state.selectedCollectionID = collection.id; refreshCollectionControls(); selectSource(.collections) }
        }
    }

    @objc func renameCollection(_ sender: Any?) {
        guard let id = targetCollectionID(sender), let index = state.collections.firstIndex(where: { $0.id == id }) else { return }
        promptForCollectionName(title: "Rename Collection", initialValue: state.collections[index].name) { [weak self] name in
            guard let self, !name.isEmpty, let current = state.collections.firstIndex(where: { $0.id == id }) else { return }
            state.collections[current].rename(to: name); stateStore.save(state); refreshCollectionControls(); updateWindowTitle()
        }
    }

    @objc func deleteCollection(_ sender: Any?) {
        guard let id = targetCollectionID(sender), let collection = state.collections.first(where: { $0.id == id }), let window else { return }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "Delete “\(collection.name)”?"
        alert.informativeText = "The collection will be removed. Cached originals and favorites are not deleted."
        alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            state.collections.removeAll { $0.id == id }
            // Removal Undo cannot restore into a deleted collection; don't offer it.
            window.undoManager?.removeAllActions(withTarget: self)
            if state.activeRotationCollectionID == id {
                rotationTask?.cancel()
                state.activeRotationCollectionID = nil
                state.rotationInterval = .off
                rotationPopUp.selectItem(at: RotationInterval.allCases.firstIndex(of: .off) ?? 0)
                configureRotationTimer()
            }
            if state.selectedCollectionID == id { state.selectedCollectionID = state.collections.first?.id }
            stateStore.save(state)
            refreshCollectionControls(); updateSourceUI(); reloadCurrentSource()
        }
    }

    /// Sidebar context menus name their collection; menu-bar commands act on the one being viewed.
    private func targetCollectionID(_ sender: Any?) -> UUID? {
        (sender as? NSMenuItem)?.representedObject as? UUID ?? (state.currentSource == .collections ? state.selectedCollectionID : nil)
    }

    private func promptForCollectionName(title: String, initialValue: String, completion: @escaping (String) -> Void) {
        guard let window else { return }
        let input = NSTextField(string: initialValue); input.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = "Enter a short, descriptive name."; alert.accessoryView = input
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            completion(input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func refreshCollectionControls() {
        if state.selectedCollectionID == nil || !state.collections.contains(where: { $0.id == state.selectedCollectionID }) { state.selectedCollectionID = state.collections.first?.id }
        refreshRotationSources(); refreshSidebar(); stateStore.save(state); updateControlAvailability()
    }

    private func refreshSidebar() {
        let rotating = state.rotationInterval != .off
        let folderName = state.folderPath.map { URL(fileURLWithPath: $0).lastPathComponent }
        let library = [
            SidebarNode(.discover, title: "Discover", symbolName: "globe"),
            SidebarNode(.local, title: folderName ?? "Folder", symbolName: "folder",
                        count: state.folderPath == nil || isLoadingFolder ? nil : localURLs.count,
                        isRotating: rotating && state.activeRotationCollectionID == nil),
            SidebarNode(.favorites, title: "Favorites", symbolName: "heart", count: state.favorites.count)
        ]
        let collections = state.collections.map {
            SidebarNode(.collection($0.id), title: $0.name, symbolName: "rectangle.stack", count: $0.wallpapers.count,
                        isRotating: rotating && state.activeRotationCollectionID == $0.id)
        }
        var groups = [SidebarNode(group: "Library", children: library)]
        if !collections.isEmpty { groups.append(SidebarNode(group: "Collections", children: collections)) }
        sidebar.reload(groups: groups, selection: currentSidebarItem)
    }

    // MARK: - Rotation

    private func refreshRotationSources() {
        let folderName = state.folderPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Local Folder"
        rotationSourcePopUp.removeAllItems(); rotationSourcePopUp.addItem(withTitle: folderName); rotationSourcePopUp.addItems(withTitles: state.collections.map(\.name))
        rotationSourcePopUp.item(at: 0)?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        for index in state.collections.indices { rotationSourcePopUp.item(at: index + 1)?.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: nil) }
        if let id = state.activeRotationCollectionID, let index = state.collections.firstIndex(where: { $0.id == id }) { rotationSourcePopUp.selectItem(at: index + 1) }
        else { rotationSourcePopUp.selectItem(at: 0) }
    }

    @objc private func rotationSourceChanged() {
        rotationTask?.cancel()
        let index = rotationSourcePopUp.indexOfSelectedItem - 1
        state.activeRotationCollectionID = state.collections.indices.contains(index) ? state.collections[index].id : nil
        stateStore.save(state); refreshSidebar(); updateControlAvailability()
    }

    @objc func rotationSelectionChanged() {
        rotationTask?.cancel()
        state.rotationInterval = selectedRotationInterval; stateStore.save(state); configureRotationTimer()
        showStatus(selectedRotationInterval == .off ? "Automatic rotation is off." : "Automatic rotation: \(selectedRotationInterval.displayName).", isError: false)
        refreshSidebar(); updateControlAvailability()
    }

    @objc private func shuffleChanged() { state.shuffleEnabled = shuffleButton.state == .on; stateStore.save(state); updateControlAvailability() }

    @objc func setRotationInterval(_ sender: NSMenuItem) {
        guard RotationInterval.allCases.indices.contains(sender.tag) else { return }
        rotationPopUp.selectItem(at: sender.tag); rotationSelectionChanged()
    }

    @objc func toggleShuffle(_ sender: Any?) {
        shuffleButton.state = shuffleButton.state == .on ? .off : .on; shuffleChanged()
    }

    /// From a sidebar row: rotate through that folder or collection, then show the settings so
    /// an interval can be chosen if rotation is off.
    @objc func useForRotation(_ sender: NSMenuItem) {
        let id = sender.representedObject as? UUID
        rotationSourcePopUp.selectItem(at: id.flatMap { id in state.collections.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0)
        rotationSourceChanged()
        if state.rotationInterval == .off { showRotationSettings(nil) }
    }

    @objc func showRotationSettings(_ sender: Any?) {
        guard window != nil else { return }
        if rotationPopover.isShown { rotationPopover.performClose(sender); return }
        updateControlAvailability()
        let anchor: NSView = rotationButton.window != nil ? rotationButton : (window?.contentView ?? rotationButton)
        if let content = rotationPopover.contentViewController?.view { rotationPopover.contentSize = content.fittingSize }
        rotationPopover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    private func configureRotationTimer() {
        rotationTimer?.invalidate(); rotationTimer = nil
        guard let seconds = state.rotationInterval.seconds else { return }
        #if DEBUG
        if let rotationTimerFactoryForTesting {
            rotationTimer = rotationTimerFactoryForTesting(seconds) { [weak self] in self?.rotateWallpaper() }
            rotationTimer?.tolerance = min(seconds * 0.05, 60)
            return
        }
        #endif
        let timer = Timer(
            timeInterval: seconds,
            target: self,
            selector: #selector(rotationTimerFired(_:)),
            userInfo: nil,
            repeats: true
        )
        timer.tolerance = min(seconds * 0.05, 60); RunLoop.main.add(timer, forMode: .common); rotationTimer = timer
    }

    @objc private func rotationTimerFired(_ timer: Timer) { rotateWallpaper() }

    func rotateWallpaper() {
        guard rotationTask == nil, downloadTask == nil, let screen = selectedScreen else { return }
        if let id = state.activeRotationCollectionID {
            guard let collection = state.collections.first(where: { $0.id == id }), !collection.wallpapers.isEmpty else { return }
            let refs = collection.wallpapers
            // Rotation follows its own cursor, never the browsing selection. An attempt moves the
            // cursor even if it fails, so one unavailable wallpaper isn't retried on every tick.
            let index = rotationIndex(current: refs.firstIndex { $0.identityKey == state.rotationCursor }, count: refs.count)
            let ref = refs[index]; state.rotationCursor = ref.identityKey; stateStore.save(state)
            setWallpaperButton.isEnabled = false
            let scaling = selectedScalingMode
            rotationTask = Task { [weak self] in
                guard let self else { return }
                defer { rotationTask = nil; updateControlAvailability() }
                do {
                    let url = try await localOriginal(for: ref)
                    try Task.checkCancellation()
                    guard state.activeRotationCollectionID == id, state.rotationInterval != .off else { return }
                    await applyWallpaper(url, to: screen, scaling: scaling, source: .rotation)
                } catch {
                    if !Task.isCancelled { showStatus("Automatic rotation failed: \(friendlyMessage(for: error))", isError: true) }
                }
            }
            updateControlAvailability()
        } else {
            guard !localURLs.isEmpty else { return }
            let index = rotationIndex(current: localURLs.firstIndex { $0.path == state.rotationCursor }, count: localURLs.count)
            state.rotationCursor = localURLs[index].path; stateStore.save(state)
            let url = localURLs[index]; let scaling = selectedScalingMode
            rotationTask = Task { [weak self] in
                guard let self else { return }
                defer { rotationTask = nil; updateControlAvailability() }
                await applyWallpaper(url, to: screen, scaling: scaling, source: .rotation)
            }
            updateControlAvailability()
        }
    }

    private func rotationIndex(current: Int?, count: Int) -> Int {
        if state.shuffleEnabled, count > 1 {
            var candidate = Int.random(in: 0..<count)
            if candidate == current { candidate = (candidate + 1) % count }
            return candidate
        }
        return WallpaperNavigation.index(after: current, direction: 1, count: count) ?? 0
    }

    private var rotationSourceName: String {
        if let id = state.activeRotationCollectionID, let collection = state.collections.first(where: { $0.id == id }) { return "“\(collection.name)”" }
        return state.folderPath.map { "“\(URL(fileURLWithPath: $0).lastPathComponent)”" } ?? "your local folder"
    }

    private var rotationSummary: String {
        let display = selectedScreen?.localizedName ?? "the selected display"
        let count: Int
        if let id = state.activeRotationCollectionID { count = state.collections.first(where: { $0.id == id })?.wallpapers.count ?? 0 }
        else { count = localURLs.count }
        if count == 0 {
            return state.activeRotationCollectionID == nil && state.folderPath == nil
                ? "Choose a folder or a collection to rotate through."
                : "\(rotationSourceName.prefix(1).uppercased() + rotationSourceName.dropFirst()) has no wallpapers to rotate through yet."
        }
        guard state.rotationInterval != .off else {
            return "Wallpier can change the wallpaper on \(display) on a schedule while it’s open."
        }
        let order = state.shuffleEnabled ? "a random wallpaper" : "the next wallpaper"
        let every = rotationTitle(state.rotationInterval)
        return "\(every.prefix(1) + every.dropFirst().lowercased()), Wallpier sets \(order) from \(rotationSourceName) on \(display) using \(scalingTitle(selectedScalingMode)). Rotation runs while Wallpier is open."
    }

    // MARK: - Undo

    @objc func undoWallpaperChange(_ sender: Any?) {
        guard downloadTask == nil, rotationTask == nil else { return }
        guard let entry = state.history.last else { showStatus("There is no Wallpier wallpaper change to undo.", isError: false); NSSound.beep(); return }
        guard let screen = screens.first(where: { identifier(for: $0) == entry.previous.displayID }) else {
            presentError(title: "Cannot Undo Wallpaper Change", message: "The display used by the previous assignment is not currently available."); return
        }
        downloadTask = Task { [weak self] in
            guard let self else { return }
            defer { downloadTask = nil; updateControlAvailability() }
            guard let assignment = await historyStore.undoAssignment(for: entry) else {
                markUndoUnavailable(entry)
                showStatus("Undo unavailable: the previous wallpaper could not be preserved or is no longer readable.", isError: false)
                return
            }
            let url = URL(fileURLWithPath: assignment.imagePath)
            do {
                try Task.checkCancellation()
                let result = try wallpaperService.setWallpaper(imageURL: url, on: try availableScreen(matching: screen), scaling: assignment.scaling)
                _ = state.popHistory(); state.setAssignment(assignment); state.selectedDisplayID = assignment.displayID; state.scalingMode = assignment.scaling
                let saved = stateStore.save(state)
                refreshDisplays(); scalingPopUp.selectItem(at: ScalingMode.allCases.firstIndex(of: assignment.scaling) ?? 0)
                stageView.scaling = assignment.scaling
                showStatus(String(format: "Restored %@ in %.1f ms.", url.lastPathComponent, result.elapsedTime * 1_000), isError: false)
                refreshUndoAvailability()
                if saved { await cleanupRollbackFiles() }
            } catch { presentError(title: "Could Not Restore Wallpaper", message: error.localizedDescription) }
        }
        updateControlAvailability()
    }

    private var canUndoWallpaper: Bool {
        guard let entry = state.history.last, entry == validatedUndoEntry,
              screens.contains(where: { identifier(for: $0) == entry.previous.displayID }) else { return false }
        return FileManager.default.isReadableFile(atPath: entry.rollbackPath ?? entry.previous.imagePath)
    }

    @objc private func refreshUndoAvailability() {
        undoValidationTask?.cancel(); validatedUndoEntry = nil
        updateControlAvailability()
        guard let entry = state.history.last, entry.undoUnavailableReason == nil else { return }
        undoValidationTask = Task { [weak self] in
            guard let self else { return }
            let assignment = await historyStore.undoAssignment(for: entry)
            guard !Task.isCancelled, state.history.last == entry else { return }
            if assignment != nil { validatedUndoEntry = entry }
            else { markUndoUnavailable(entry) }
            updateControlAvailability()
        }
    }

    private func markUndoUnavailable(_ entry: HistoryEntry) {
        guard state.history.last == entry else { return }
        validatedUndoEntry = nil
        state.history[state.history.count - 1].undoUnavailableReason = entry.undoUnavailableReason ?? .restoreFileUnavailable
        stateStore.save(state)
        logger.notice("Undo unavailable for \(entry.rollbackPath ?? entry.previous.imagePath, privacy: .public)")
        updateControlAvailability()
    }

    private func cleanupRollbackFiles() async {
        await historyStore.cleanup(protectedPaths: currentProtectedPaths())
    }

    private func currentProtectedPaths() -> Set<String> {
        var protected = state.protectedCachePaths
        // Also retain actual current desktops if persisted assignments were externally changed.
        protected.formUnion(screens.compactMap { wallpaperService.currentWallpaper(on: $0)?.imageURL.path })
        return protected
    }

    // MARK: - Displays and scaling

    @objc func displaySelectionChanged() {
        guard let screen = selectedScreen else { return }
        state.selectedDisplayID = identifier(for: screen); updateDisplayMinimum(); stateStore.save(state)
        invalidateSearch()
        updateStageDisplay(screen)
    }
    @objc func scalingSelectionChanged() {
        state.scalingMode = selectedScalingMode; stateStore.save(state)
        stageView.scaling = selectedScalingMode
        updateControlAvailability()
    }
    @objc private func screenParametersChanged(_ notification: Notification) { refreshDisplays() }

    func refreshDisplays() {
        let desired = state.selectedDisplayID; screens = availableScreens()
        displayPopUp.removeAllItems()
        let names = screens.map(\.localizedName)
        for screen in screens {
            // Repeat the resolution only when two displays share a name.
            let title = names.filter { $0 == screen.localizedName }.count > 1 ? description(for: screen) : screen.localizedName
            displayPopUp.addItem(withTitle: title)
            displayPopUp.lastItem?.image = NSImage(systemSymbolName: "display", accessibilityDescription: nil)
            displayPopUp.lastItem?.toolTip = description(for: screen)
        }
        if let desired, let index = screens.firstIndex(where: { identifier(for: $0) == desired }) { displayPopUp.selectItem(at: index) }
        else { displayPopUp.selectItem(at: screens.isEmpty ? -1 : 0) }
        displayPopUp.isEnabled = !screens.isEmpty
        if let screen = selectedScreen { state.selectedDisplayID = identifier(for: screen); updateDisplayMinimum(); updateStageDisplay(screen) }
        stateStore.save(state); updateControlAvailability(); updatePendingSearch()
    }

    private func updateStageDisplay(_ screen: NSScreen) {
        displayPopUp.toolTip = description(for: screen)
        let size = CGSize(width: screen.frame.width * screen.backingScaleFactor, height: screen.frame.height * screen.backingScaleFactor)
        if size.width > 0, size.height > 0 { stageView.displayPixelSize = size }
    }

    private func identifier(for screen: NSScreen) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = screen.deviceDescription[key] as? NSNumber { return String(number.uint32Value) }
        return "\(screen.localizedName)-\(Int(screen.frame.origin.x))-\(Int(screen.frame.origin.y))"
    }
    private func description(for screen: NSScreen) -> String {
        let width = Int(screen.frame.width * screen.backingScaleFactor); let height = Int(screen.frame.height * screen.backingScaleFactor)
        return "\(screen.localizedName) — \(width)×\(height) px"
    }

    private func scalingTitle(_ mode: ScalingMode) -> String {
        switch mode {
        case .fill: return "Fill Screen"
        case .fit: return "Fit to Screen"
        case .center: return "Center"
        }
    }

    private func rotationTitle(_ interval: RotationInterval) -> String {
        switch interval {
        case .off: return "Never"
        case .fifteenMinutes: return "Every 15 Minutes"
        case .oneHour: return "Every Hour"
        case .oneDay: return "Every Day"
        }
    }

    // MARK: - Presentation updates

    /// Filters and the folder bar act on the gallery's results; the preview inspects one wallpaper, so they step aside.
    private func updateScopeBar() {
        discoverBar.isHidden = state.currentSource != .discover
        localBar.isHidden = state.currentSource != .local || state.folderPath == nil
        scopeBar.isHidden = (discoverBar.isHidden && localBar.isHidden) || !viewerView.isHidden
        scopeBarCollapsed.isActive = scopeBar.isHidden
    }

    private func updateSourceUI() {
        updateScopeBar()
        if let path = state.folderPath, folderPathLabel.stringValue.isEmpty {
            folderPathLabel.stringValue = (path as NSString).abbreviatingWithTildeInPath; folderPathLabel.toolTip = path
        }
        sidebar.select(currentSidebarItem)
        updateWindowTitle()
        updateControlAvailability()
    }

    private func reloadCurrentSource() {
        collectionView.reloadData(); restoreSelection(); updateEmptyAndPagination(); updateControlAvailability()
    }

    private func updateWindowTitle() {
        updatePendingSearch()
        guard let window else { return }
        let count = currentItems.count
        let wallpapers = count == 1 ? "1 wallpaper" : "\(count.formatted()) wallpapers"
        switch state.currentSource {
        case .discover:
            window.title = "Discover"
            // Names the request the results came from, which the edited controls may no longer describe.
            window.subtitle = totalResults > 0 ? "\(resultOptions?.resultsDescription ?? "Results") on Wallhaven · \(remoteResults.count.formatted()) of \(totalResults.formatted())" : ""
        case .local:
            window.title = state.folderPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Folder"
            window.subtitle = state.folderPath == nil || isLoadingFolder ? "" : wallpapers
        case .favorites:
            window.title = "Favorites"; window.subtitle = wallpapers
        case .collections:
            window.title = selectedCollection?.name ?? "Collections"; window.subtitle = selectedCollection == nil ? "" : wallpapers
        }
    }

    /// When the visible results no longer match the search text, filters or display-derived size, say
    /// which request they show and offer to apply the new one (as Return in the search field does).
    private func updatePendingSearch() {
        let draft = state.wallhavenSearch
        sortingPopUp.toolTip = draft.effectiveSorting == draft.sorting ? "Sort order"
            : "Without search text Wallhaven has no relevance order, so Discover shows this month’s top wallpapers."
        var note: String?
        if let applied = resultOptions, !remoteResults.isEmpty,
           WallhavenEndpoint.searchURL(options: applied, page: 1) != WallhavenEndpoint.searchURL(options: draft, page: 1) {
            if applied.trimmedQuery != draft.trimmedQuery { note = "Showing \(applied.resultsDescription)" }
            else if applied.minimumResolution != draft.minimumResolution, draft.usesDisplayMinimum { note = "Showing results for the previous display size" }
            else { note = "Showing results for earlier filters" }
        }
        pendingSearchLabel.stringValue = note ?? ""
        pendingSearchLabel.toolTip = note.map { "\($0). Press Return in the search field or click Update Results to search with the current settings." }
        pendingSearchLabel.isHidden = note == nil
        updateResultsButton.isHidden = note == nil
        updateResultsButton.toolTip = draft.trimmedQuery.isEmpty ? "Show \(draft.effectiveSorting.displayName) on Wallhaven"
            : "Search Wallhaven for “\(draft.trimmedQuery)”"
    }

    private func updateEmptyAndPagination() {
        updateWindowTitle()
        defer { updateContentVisibility() }
        guard currentItems.isEmpty else { emptyStateView.isHidden = true; return }
        switch state.currentSource {
        case .discover:
            if isSearching {
                emptyStateView.show(symbolName: nil, title: "Searching Wallhaven…", message: "")
            } else if let searchErrorText {
                let offline = searchErrorText.contains("offline") || searchErrorText.contains("reach Wallhaven")
                emptyStateView.show(symbolName: offline ? "wifi.exclamationmark" : "exclamationmark.triangle",
                                    title: "Couldn’t Load Wallpapers", message: searchErrorText,
                                    action: ("Try Again", #selector(search(_:)), self))
            } else if resultOptions == nil || resultOptions != state.wallhavenSearch {
                emptyStateView.show(symbolName: "magnifyingglass", title: "Search Wallhaven",
                                    message: "Press Return in the search field to see safe-for-work wallpapers.")
            } else {
                emptyStateView.show(symbolName: "magnifyingglass", title: "No Results",
                                    message: "No safe-for-work Wallhaven wallpapers matched these filters.")
            }
        case .local:
            if isLoadingFolder {
                emptyStateView.show(symbolName: nil, title: "Loading Folder…", message: "")
            } else if state.folderPath == nil {
                emptyStateView.show(symbolName: "folder", title: "No Folder Chosen",
                                    message: "Choose a folder of JPEG, PNG or HEIC images to browse them here.",
                                    action: ("Choose Folder…", #selector(chooseFolder(_:)), self))
            } else {
                emptyStateView.show(symbolName: "photo.on.rectangle", title: "No Images",
                                    message: "This folder has no JPEG, PNG or HEIC images.",
                                    action: ("Choose Another Folder…", #selector(chooseFolder(_:)), self))
            }
        case .favorites:
            emptyStateView.show(symbolName: "heart", title: "No Favorites Yet",
                                message: "Click the heart or press ⌘D on any Wallhaven wallpaper to keep it here.",
                                action: ("Browse Discover", #selector(showDiscover(_:)), self))
        case .collections:
            if let collection = selectedCollection {
                emptyStateView.show(symbolName: "rectangle.stack", title: "“\(collection.name)” Is Empty",
                                    message: "Drag wallpapers onto this collection in the sidebar, or choose Add to Collection.")
            } else {
                emptyStateView.show(symbolName: "rectangle.stack", title: "No Collections",
                                    message: "Collections keep Wallhaven wallpapers together, and can be used for automatic rotation.",
                                    action: ("New Collection…", #selector(createCollection(_:)), self))
            }
        }
    }

    private func updateControlAvailability() {
        let canMutate = downloadTask == nil && rotationTask == nil
        let hasSelection = selectedItem != nil
        setWallpaperButton.isEnabled = hasSelection && selectedScreen != nil && canMutate
        undoButton.isEnabled = canUndoWallpaper && canMutate
        undoButton.toolTip = canUndoWallpaper ? "Undo Wallpaper Change" : "No restorable wallpaper change"
        favoriteButton.isHidden = selectedReference == nil
        moreButton.isHidden = !hasSelection
        updatePreviewNavigation()
        // An empty gallery shows its own spinner; the bar's is for work behind visible content.
        let busy = !canMutate || ((isSearching || isLoadingFolder) && !currentItems.isEmpty)
        if busy { busyIndicator.startAnimation(nil) } else { busyIndicator.stopAnimation(nil) }
        busyIndicator.isHidden = !busy

        let rotationCount: Int
        if let id = state.activeRotationCollectionID { rotationCount = state.collections.first(where: { $0.id == id })?.wallpapers.count ?? 0 }
        else { rotationCount = localURLs.count }
        rotationPopUp.isEnabled = rotationCount > 0 || state.rotationInterval != .off
        shuffleButton.isEnabled = rotationCount > 0 && state.rotationInterval != .off
        let rotating = state.rotationInterval != .off
        rotationButton.contentTintColor = rotating ? .controlAccentColor : nil
        rotationButton.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                                       accessibilityDescription: rotating ? "Automatic Rotation On" : "Automatic Rotation")
        rotationButton.toolTip = rotating ? "Automatic rotation: \(rotationTitle(state.rotationInterval).lowercased()) from \(rotationSourceName)" : "Automatic Rotation"
        rotationSummaryLabel.stringValue = rotationSummary
    }

    private func friendlyMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost: return "You appear to be offline. Check your connection and try again."
            case .timedOut: return "Wallhaven took too long to respond. Try again."
            case .cancelled: return "The request was cancelled."
            default: return "Could not reach Wallhaven. \(urlError.localizedDescription)"
            }
        }
        return error.localizedDescription
    }

    /// Informational messages fade after a few seconds; errors and in-progress work stay.
    private func showStatus(_ text: String, isError: Bool) {
        statusClearTask?.cancel()
        if !isError, !text.isEmpty {
            statusClearTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard let self, !Task.isCancelled, statusLabel.stringValue == text, downloadTask == nil, rotationTask == nil else { return }
                showStatus("", isError: false)
            }
        }
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? .systemRed : .secondaryText
        statusLabel.toolTip = text
        statusLabel.isHidden = text.isEmpty
        statusLabel.setAccessibilityLabel(text)
        if !text.isEmpty { NSAccessibility.post(element: statusLabel, notification: .announcementRequested, userInfo: [.announcement: text]) }
    }
    private func presentError(title: String, message: String) {
        showStatus("\(title): \(message)", isError: true)
        guard let window else { return }
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = title; alert.informativeText = message; alert.addButton(withTitle: "OK"); alert.beginSheetModal(for: window)
    }

    // Saved scaling choices are never rewritten: an old saved Fill can't be told from a deliberate one.
    static let helpText = """
        Discover searches safe-for-work wallpapers on Wallhaven. Your folder, Favorites and collections are in the sidebar.

        Select a wallpaper and press Space to preview it on your display’s shape; ← and → browse, Esc returns. \
        Set Wallpaper (Return) downloads only that original and applies it with the display and scaling shown beside it. \
        Undo Wallpaper Change, in the toolbar and Wallpaper menu, restores the previous wallpaper; \
        ⌘Z undoes removing a wallpaper from Favorites or a collection.

        Fit to Screen is the default for new installations. Existing scaling choices are preserved. \
        If your wallpapers are cropped, select Fit to Screen once; Wallpier remembers your choice.

        Drag wallpapers onto Favorites or a collection to keep them. The rotation button in the toolbar changes the wallpaper on a schedule while Wallpier is open.
        """

    @objc func showHelp(_ sender: Any?) {
        let alert = NSAlert(); alert.messageText = "Wallpier Help"
        alert.informativeText = Self.helpText
        alert.addButton(withTitle: "OK")
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    // MARK: - Menus

    /// The selected wallpaper's actions: the ⋯ button, a right-click, and Wallpaper ▸ share it.
    func itemMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
        }
        add("Set Wallpaper", #selector(setWallpaper(_:)))
        add(isViewerVisible ? "Back to Gallery" : "Preview on Desktop", #selector(toggleViewer(_:)))
        menu.addItem(.separator())
        if let ref = selectedReference {
            add(state.isFavorite(ref) ? "Remove from Favorites" : "Add to Favorites", #selector(toggleFavorite(_:)))
            let collections = NSMenuItem(title: "Add to Collection", action: nil, keyEquivalent: "")
            collections.submenu = NSMenu(title: "Add to Collection")
            populateCollectionMenu(collections.submenu!)
            menu.addItem(collections)
            if state.currentSource == .collections, let collection = selectedCollection {
                add("Remove from “\(collection.name)”", #selector(removeFromCollection(_:)))
            }
            menu.addItem(.separator())
            add("Open on Wallhaven", #selector(openSourcePage(_:)))
            add("Copy Link", #selector(copy(_:)))
        } else if selectedItem != nil {
            add("Show in Finder", #selector(openSourcePage(_:)))
            add("Copy", #selector(copy(_:)))
        }
        return menu
    }

    func populateCollectionMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let ref = selectedReference
        for collection in state.collections {
            let item = menu.addItem(withTitle: collection.name, action: #selector(addToCollection(_:)), keyEquivalent: "")
            item.representedObject = collection.id
            item.target = self
            item.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: nil)
            item.state = ref.map { ref in collection.wallpapers.contains { $0.identityKey == ref.identityKey } } == true ? .on : .off
        }
        if !state.collections.isEmpty { menu.addItem(.separator()) }
        let new = menu.addItem(withTitle: "New Collection…", action: #selector(createCollection(_:)), keyEquivalent: "")
        new.representedObject = "withSelection"
        new.target = self
    }

    func menuNeedsUpdate(_ menu: NSMenu) { populateCollectionMenu(menu) }

    @objc private func showMoreMenu(_ sender: NSButton) {
        itemMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    private func sidebarMenu(for item: SidebarItem) -> NSMenu? {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, _ object: Any? = nil, checked: Bool = false) {
            let menuItem = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = object
            menuItem.state = checked ? .on : .off
        }
        let rotating = state.rotationInterval != .off
        switch item {
        case .discover: return nil
        case .favorites: return nil
        case .local:
            add(state.folderPath == nil ? "Choose Folder…" : "Change Folder…", #selector(chooseFolder(_:)))
            if state.folderPath != nil {
                menu.addItem(.separator())
                add("Use for Automatic Rotation", #selector(useForRotation(_:)), checked: rotating && state.activeRotationCollectionID == nil)
            }
        case .collection(let id):
            add("Use for Automatic Rotation", #selector(useForRotation(_:)), id, checked: rotating && state.activeRotationCollectionID == id)
            menu.addItem(.separator())
            add("Rename…", #selector(renameCollection(_:)), id)
            add("Delete…", #selector(deleteCollection(_:)), id)
        }
        return menu
    }

    /// ⌘⌫ removal applies only while the gallery or preview has focus in the key window, so in the
    /// search field or a sheet's text field it stays a text command.
    private var isBrowsingFocused: Bool {
        guard let window, window.isKeyWindow else { return false }
        return window.firstResponder === collectionView || window.firstResponder === viewerView
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let canMutate = downloadTask == nil && rotationTask == nil
        switch menuItem.action {
        case #selector(toggleSidebar(_:)):
            menuItem.title = isSidebarVisible ? "Hide Sidebar" : "Show Sidebar"
            return splitViewController != nil
        case #selector(toggleViewer(_:)):
            menuItem.title = isViewerVisible ? "Back to Gallery" : "Preview on Desktop"
            return isViewerVisible || selectedItem != nil
        case #selector(makeThumbnailsLarger(_:)): return thumbnailSizeIndex < GalleryLayout.thumbnailWidths.count - 1
        case #selector(makeThumbnailsSmaller(_:)): return thumbnailSizeIndex > 0
        case #selector(setWallpaper(_:)): return selectedItem != nil && selectedScreen != nil && canMutate
        case #selector(previousWallpaper(_:)): return canNavigate(-1)
        case #selector(nextWallpaper(_:)): return canNavigate(1)
        case #selector(undoWallpaperChange(_:)): return canUndoWallpaper && canMutate
        case #selector(toggleFavorite(_:)):
            menuItem.title = selectedReference.map(state.isFavorite) == true ? "Remove from Favorites" : "Add to Favorites"
            return selectedReference != nil
        case #selector(openSourcePage(_:)):
            if menuItem.keyEquivalent == "o" { menuItem.title = selectedReference == nil && selectedItem != nil ? "Show in Finder" : "Open on Wallhaven" }
            return selectedItem != nil
        case #selector(copy(_:)): return selectedItem != nil
        case #selector(addToCollection(_:)): return selectedReference != nil
        case #selector(createCollection(_:)):
            return menuItem.representedObject as? String != "withSelection" || selectedReference != nil
        case #selector(removeSelected(_:)):
            switch state.currentSource {
            case .favorites: menuItem.title = "Remove from Favorites"
            case .collections: menuItem.title = selectedCollection.map { "Remove from “\($0.name)”" } ?? "Remove from Collection"
            default: menuItem.title = "Remove from Collection"
            }
            return selectedReference != nil && currentList != nil && isBrowsingFocused
        case #selector(renameCollection(_:)), #selector(deleteCollection(_:)): return targetCollectionID(menuItem) != nil
        case #selector(setRotationInterval(_:)):
            menuItem.state = RotationInterval.allCases.firstIndex(of: state.rotationInterval) == menuItem.tag ? .on : .off
            return rotationPopUp.isEnabled
        case #selector(toggleShuffle(_:)):
            menuItem.state = state.shuffleEnabled ? .on : .off
            return shuffleButton.isEnabled
        case #selector(showRotationSettings(_:)): return window != nil
        case #selector(showDiscover(_:)): menuItem.state = state.currentSource == .discover ? .on : .off; return true
        case #selector(showLocal(_:)): menuItem.state = state.currentSource == .local ? .on : .off; return true
        case #selector(showFavorites(_:)): menuItem.state = state.currentSource == .favorites ? .on : .off; return true
        case #selector(showCollections(_:)): menuItem.state = state.currentSource == .collections ? .on : .off; return true
        default: return true
        }
    }

    // MARK: - Gallery data source and delegate

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { currentItems.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let reusable = collectionView.makeItem(withIdentifier: WallpaperCollectionViewItem.reuseIdentifier, for: indexPath)
        guard let item = reusable as? WallpaperCollectionViewItem, currentItems.indices.contains(indexPath.item) else { return reusable }
        let represented = currentItems[indexPath.item]
        item.isEmphasized = self.collectionView.isSelectionEmphasized
        item.configure(identifier: represented.identifier, title: represented.title, toolTip: represented.toolTip)
        // Decode at the cell's pixel size; switch to Wallhaven's larger thumbnail only when cells need it.
        let pixels = galleryLayout.fittedItemSize.width * (window?.backingScaleFactor ?? 2)
        let maximumPixelSize = Int(min(max(pixels, 360), 720))
        switch represented {
        case .local(let url):
            thumbnailProvider.requestThumbnail(for: url, maximumPixelSize: maximumPixelSize) { [weak item] image in
                guard (item?.representedObject as? String) == represented.identifier else { return }; item?.setThumbnail(image)
            }
        case .remote(let ref):
            remoteThumbnailProvider.requestThumbnail(for: pixels > 340 ? ref.previewURL : ref.thumbnailURL, maximumPixelSize: maximumPixelSize) { [weak item] image in
                guard (item?.representedObject as? String) == represented.identifier else { return }; item?.setThumbnail(image)
            }
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> NSSize { galleryLayout.fittedItemSize }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let index = indexPaths.first?.item, currentItems.indices.contains(index) else { return }
        let item = currentItems[index]; rememberSelection(item); updatePreview(for: item)
        updateControlAvailability()
    }

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool { true }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard currentItems.indices.contains(indexPath.item) else { return nil }
        switch currentItems[indexPath.item] {
        case .local(let url): return url as NSURL
        case .remote(let ref):
            let item = NSPasteboardItem()
            item.setString(ref.identityKey, forType: .wallpierReference)
            item.setString(ref.sourcePageURL.absoluteString, forType: .URL)
            item.setString(ref.sourcePageURL.absoluteString, forType: .string)
            return item
        }
    }

    // MARK: - Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarSeparator, .viewMode, .flexibleSpace, .rotation, .undoWallpaper, .search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func viewItem(_ view: NSView, label: String) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = view
            item.label = label
            item.paletteLabel = label
            item.toolTip = view.toolTip
            return item
        }
        switch itemIdentifier {
        case .sidebarSeparator:
            guard let splitView = splitViewController?.splitView else { return nil }
            return NSTrackingSeparatorToolbarItem(identifier: itemIdentifier, splitView: splitView, dividerIndex: 0)
        case .viewMode: return viewItem(viewModeControl, label: "View")
        case .rotation: return viewItem(rotationButton, label: "Rotation")
        case .undoWallpaper: return viewItem(undoButton, label: "Undo")
        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.searchField = searchField
            item.preferredWidthForSearchField = 220
            item.label = "Search"
            searchField.delegate = self
            searchToolbarItem = item
            return item
        default: return nil
        }
    }
}
