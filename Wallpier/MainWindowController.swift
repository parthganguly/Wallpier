import AppKit
import os.log

/// Archival paper (light) or darkroom charcoal (dark) the wallpapers sit on, following appearance changes.
private final class BackdropView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.canvas.setFill()
        dirtyRect.fill()
    }
}

/// A small caption above a control, so Display and Scaling are named on screen and not only to VoiceOver.
private func labeled(_ caption: String, _ control: NSView) -> NSStackView {
    let label = NSTextField(labelWithString: caption)
    label.font = .systemFont(ofSize: 10, weight: .medium)
    label.textColor = Theme.inkSecondary
    label.setAccessibilityElement(false)
    let stack = NSStackView(views: [label, control])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 1
    return stack
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

/// The request Discover's results came from, in the terms of the source that answered it.
private enum DiscoverQuery: Equatable {
    case wallhaven(WallhavenSearchOptions)
    case openverse(OpenverseSearchOptions)
    case cma(CMASearchOptions)
    case catalog(RemoteProviderID, CatalogSearchOptions)

    var provider: RemoteProviderID {
        switch self { case .wallhaven: return .wallhaven; case .openverse: return .openverse; case .cma: return .cma; case .catalog(let id, _): return id }
    }
    /// The search field's text for this source, as typed.
    var queryText: String {
        switch self { case .wallhaven(let o): return o.query; case .openverse(let o): return o.query; case .cma(let o): return o.query; case .catalog(_, let o): return o.query }
    }
    var trimmedQuery: String { queryText.trimmingCharacters(in: .whitespacesAndNewlines) }
    var resultsDescription: String {
        switch self {
        case .wallhaven(let o): return o.resultsDescription
        case .openverse(let o): return o.resultsDescription
        case .cma(let o): return o.resultsDescription
        case .catalog: return trimmedQuery.isEmpty ? "Browse" : "“\(trimmedQuery)”"
        }
    }
    var minimumResolution: String? { if case .wallhaven(let o) = self { return o.minimumResolution }; return nil }
    var firstPageURL: URL? {
        switch self {
        case .wallhaven(let o): return WallhavenEndpoint.searchURL(options: o, page: 1)
        case .openverse(let o): return OpenverseEndpoint.searchURL(options: o, page: 1)
        case .cma(let o): return CMAEndpoint.searchURL(options: o, page: 1)
        case .catalog: return nil
        }
    }
}

/// A creator's works are shown in place of the gallery
/// that opened it. Back (or Esc) restores that gallery, its scroll position, selection and focus.
private struct CreatorLevel {
    enum Phase: Equatable { case loading, loaded, failed(String) }

    /// The source view that opened it (Discover's CMA, Favorites, a collection): parked with it when the source changes.
    let originKey: String
    let provider: RemoteProviderID
    let creatorID: String
    var name: String

    var cmaCreatorID: Int? { provider == .cma ? Int(creatorID) : nil }
    let anchorIdentity: String
    let anchorPageURL: URL?
    let parentScrollY: CGFloat
    /// The starting work's real title, and what the Back button returns to (a query, Favorites or a collection name).
    var anchorTitle = ""
    var originName = "Gallery"
    var results: [WallpaperReference] = []
    var selectedIdentity: String?
    var scrollY: CGFloat = 0
    var phase: Phase = .loading
    var matchTotal: Int?
    var returnedCount = 0

    /// Every shown work is explicit CC0, so "Open-access works" is true of the whole view.
    var allOpenAccess: Bool { provider != .cma || results.allSatisfy { $0.cma?.isCC0 == true } }
    var isTruncated: Bool { (matchTotal ?? 0) > returnedCount }
    var cacheKey: String { "\(provider.rawValue):\(creatorID)" }
    var subtitle: String {
        let source = provider.displayName
        guard phase == .loaded else { return source }
        return allOpenAccess ? "\(source) · Open-access works" : "Works at \(source)"
    }
}

private struct CreatorSearchResult {
    let name: String
    var works: [WallpaperReference]
    let matchTotal: Int?
    let returnedCount: Int
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
            case .remote(let ref): return ref.displayTitle
            }
        }
        /// A museum work shown for browsing only (no preview, Set, Favorite or collection).
        var isBrowseOnly: Bool {
            if case .remote(let ref) = self { return ref.isBrowseOnly }
            return false
        }
        /// Also the gallery cell's accessibility help, so VoiceOver hears more than an opaque ID.
        var toolTip: String {
            switch self {
            case .local(let url): return url.path
            case .remote(let ref):
                if ref.provider == .cma { return ref.cmaToolTip }
                if ref.provider?.isCatalog == true {
                    let size = ref.width > 0 && ref.height > 0 ? WallpaperShape.summary(width: ref.width, height: ref.height) : nil
                    return [ref.displayTitle, ref.displayCredit, size, ref.providerName, ref.licenseDescription]
                        .compactMap { $0 }.joined(separator: " · ")
                }
                let base = "\(ref.providerName) \(ref.displayTitle) — \(ref.width) × \(ref.height), \(ref.orientation)"
                guard ref.provider == .openverse else { return base }
                let credits = [ref.displayCredit, "\(ref.licenseDescription ?? "license not reported") via \(ref.sourceDisplayName)"]
                return ([base] + credits.compactMap { $0 }).joined(separator: " · ")
            }
        }
    }

    private let wallpaperService: WallpaperService
    private let stateStore: WallpaperStateStore
    private let thumbnailProvider = ThumbnailProvider()
    private let remoteThumbnailProvider: RemoteThumbnailProvider
    private let provider: WallhavenProvider
    private let openverseProvider: OpenverseProvider
    private let cmaProvider: CMAProvider
    private let catalogLibrary: CatalogLibrary
    /// Where the thumbnail-size preference lives; isolated runs pass their own suite.
    private let defaults: UserDefaults
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
    private var previewThumbnailOperation: Operation?
    private var previewThumbnailToken: UInt64 = 0
    private(set) var downloadTask: Task<Void, Never>?
    private(set) var rotationTask: Task<Void, Never>?
    private var isSearching = false
    private var searchGeneration = UUID()
    private var resultOptions: DiscoverQuery?
    private var searchErrorText: String?
    /// Results the source returned that couldn't be verified and so aren't shown.
    private var hiddenResults = 0
    /// Each Discover source keeps its own results, pages, request and failure while the other is shown.
    private struct DiscoverSession {
        var results: [WallpaperReference] = []
        var currentPage = 0, lastPage = 0, total = 0, hidden = 0
        var options: DiscoverQuery?
        var scrollY: CGFloat = 0
        var errorText: String?
        var selectedIdentity: String?
    }
    private var parkedSessions: [RemoteProviderID: DiscoverSession] = [:]
    /// The visible creator view, if any; it replaces the gallery's items without touching the results beneath it.
    private var creatorLevel: CreatorLevel?
    /// Creator views left behind by a source change, restored when their source returns.
    private var parkedCreators: [String: CreatorLevel] = [:]
    /// Loaded creator results for this session, by provider and creator ID; Retry clears an entry.
    private var creatorCache: [String: CreatorSearchResult] = [:]
    private var creatorTask: Task<Void, Never>?
    private var creatorGeneration = UUID()
    private var lastAppendFailure: Date?
    /// After a failed page, further pages wait this long; Next is re-enabled when it ends.
    private let appendRetryCooldown: TimeInterval = 5
    private var appendRetryTask: Task<Void, Never>?
    /// Next at the last loaded result asked for a page; it completes when that page arrives, if nothing changed meanwhile.
    private struct PendingAdvance { let generation: UUID; let identity: String; let revision: Int; let query: DiscoverQuery? }
    private var pendingAdvance: PendingAdvance?
    /// Bumped by every selection change, so a pending move can tell the user went elsewhere and came back.
    private var selectionRevision = 0
    private var loadingMoreStatus: String { "Loading more results from \(discoverName)…" }
    private var discoverName: String { state.discoverProvider.displayName }
    private var draftQuery: DiscoverQuery {
        switch state.discoverProvider {
        case .wallhaven: return .wallhaven(state.wallhavenSearch)
        case .openverse: return .openverse(state.openverseSearch)
        case .cma: return .cma(state.cmaSearch)
        default:
            let id = state.discoverProvider
            return .catalog(id, CatalogSearchOptions(query: state.catalogQueries[id.rawValue] ?? ""))
        }
    }
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

    // Search and filters
    let searchField: NSSearchField = SearchField()
    private var searchToolbarItem: NSSearchToolbarItem?
    let categoryPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let resolutionPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let aspectPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sortingPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let openverseLicensePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    /// Openverse's fixed filters and its acknowledgement, shown whenever its results are.
    let openverseNoticeLabel = NSTextField(labelWithString: "Powered by Openverse; not endorsed by Openverse.")
    /// Openverse pages are loaded on request, never by scrolling: filtered pages can be short or empty.
    let loadMoreButton = NSButton(title: "Load More", target: nil, action: nil)
    /// Shown for an Openverse work whose reported license can't be confirmed: Set is refused until the source is reviewed.
    let reviewSourceButton = NSButton(title: "Review Original Source", target: nil, action: nil)
    /// Cleveland Museum of Art: what the source is, shown whenever its results are.
    let cmaNoticeLabel = NSTextField(labelWithString: "Open-access (CC0) works from the Cleveland Museum of Art.")
    /// Opens the selected work's credited creator, one level deep, in place of the gallery.
    let moreByButton = NSButton(title: "More by", target: nil, action: nil)
    /// The museum's own page for a work that can only be browsed.
    let viewOnMuseumButton = NSButton(title: "View on Cleveland Museum of Art ↗", target: nil, action: nil)
    /// Beside the confirmation after a museum work is set.
    let statusUndoButton = NSButton(title: "Undo", target: nil, action: nil)
    // The creator view's header: Back, the creator's name, what the works are, and a truthful count with a link.
    let creatorBar = NSStackView()
    let creatorBackButton = NSButton(title: "← Gallery", target: nil, action: nil)
    let creatorTitleLabel = NSTextField(labelWithString: "")
    let creatorSubtitleLabel = NSTextField(labelWithString: "")
    let creatorStatusLabel = NSTextField(labelWithString: "")
    /// The "·" between the provenance line and the count line, shown only with a count.
    private let creatorSeparatorLabel = NSTextField(labelWithString: "·")
    /// Opens the artwork page the creator view started from; the museum's record, not a catalog of the creator.
    let creatorLinkButton = NSButton(title: "View starting work on Cleveland Museum of Art ↗", target: nil, action: nil)
    private let scopeBar = NSStackView()
    /// The gallery area sits under the scope bar when one is shown, else directly under the titlebar. Swapping two
    /// anchors removes the bar from layout; pinning a bar with internal insets to zero height fights those insets.
    private lazy var galleryBelowScopeBar = galleryArea.topAnchor.constraint(equalTo: scopeBar.bottomAnchor)
    private lazy var galleryAtTop = galleryArea.topAnchor.constraint(equalTo: contentRoot.safeAreaLayoutGuide.topAnchor)
    private let galleryArea = BackdropView()
    private let contentRoot = NSView()
    private let barSeparator = NSBox()
    private lazy var galleryAboveDock = galleryArea.bottomAnchor.constraint(equalTo: barSeparator.topAnchor)
    private lazy var galleryToBottom = galleryArea.bottomAnchor.constraint(equalTo: contentRoot.bottomAnchor)
    private lazy var stageAboveCaption = stageView.bottomAnchor.constraint(equalTo: previewCaptionBand.topAnchor, constant: -12)
    private lazy var stageToBottom = stageView.bottomAnchor.constraint(equalTo: viewerView.bottomAnchor, constant: -16)
    private var statusClearTask: Task<Void, Never>?
    private let discoverBar = SplitBar(spacing: 8)
    private let localBar = SplitBar(spacing: 6)
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
    /// A true wrapping cell (not a single-line label): two lines at its concrete width, the last truncating with an ellipsis.
    let previewTitleLabel = WrappingLabel(wrappingLabelWithString: "No Wallpaper Selected")
    /// The caption band and control row, which focus mode (F in the preview) hides until Esc.
    private let previewCaptionBand = NSStackView()
    private(set) var isFocusMode = false
    /// Pointer navigation for the preview, beside the position in the browsable items. Same commands as ←/→ and ⌘[ ⌘].
    let previewPreviousButton = NSButton()
    let previewNextButton = NSButton()
    let previewPositionLabel = NSTextField(labelWithString: "")
    let previewMetadataLabel = NSTextField(labelWithString: "")
    private let previewTagsLabel = NSTextField(labelWithString: "")
    /// An Openverse work's reported license, its source page and the Openverse acknowledgement, as links.
    let previewAttributionLabel = NSTextField(labelWithString: "")
    let previewAcknowledgementLabel = NSTextField(labelWithString: "Powered by Openverse; not endorsed by Openverse. Licenses are as reported, not verified.")
    /// Says what the stage is drawn from when it isn't the original: a low-resolution or a cropped thumbnail.
    let approximatePreviewNotice = NSStackView()
    private let previewNoticeIcon = NSImageView()
    private let previewNoticeLabel = NSTextField(labelWithString: "")

    // Apply bar
    /// A plain view holding three bounded groups (metadata, optional shortcuts, controls); see `configureApplyBar`.
    let applyBar = NSView()
    private static let dockShortcutHeight: CGFloat = 24
    private var dockShortcutWidth: NSLayoutConstraint?
    private let busyIndicator = NSProgressIndicator()
    let selectionLabel = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")
    let favoriteButton = NSButton()
    private let collectionButton = NSButton()
    private let moreButton = NSButton()
    let displayPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let scalingPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let setWallpaperButton = PrimaryButton(title: "Set Wallpaper", target: nil, action: nil)

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
        // Double-clicking a work that can only be browsed opens its museum page: its one action.
        view.onOpen = { [weak self] in
            guard let self else { return }
            if selectedItem?.isBrowseOnly == true { openSourcePage(nil) } else { setViewerVisible(true) }
        }
        view.onCancel = { [weak self] in self?.handleEscape() ?? false }
        view.onDelete = { [weak self] in self?.removeSelected(nil) }
        view.contextMenu = { [weak self] in self?.itemMenu() }
        return view
    }()

    // Inject before any state restoration, search, or rotation can start.
    init(window: NSWindow?, wallpaperService: WallpaperService, stateStore: WallpaperStateStore,
         provider: WallhavenProvider, openverseProvider: OpenverseProvider = OpenverseProvider(),
         cmaProvider: CMAProvider = CMAProvider(), catalogLibrary: CatalogLibrary = CatalogLibrary(),
         originalCache: RemoteWallpaperCache,
         historyStore: WallpaperHistoryStore, remoteThumbnailProvider: RemoteThumbnailProvider,
         availableScreens: @escaping () -> [NSScreen], defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.wallpaperService = wallpaperService
        self.stateStore = stateStore
        self.provider = provider
        self.openverseProvider = openverseProvider
        self.cmaProvider = cmaProvider
        self.catalogLibrary = catalogLibrary
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
        resultOptions = draftQuery
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
        collectionView.dataSource = nil
        configureUI()
        setInitialSidebarWidth()
        collectionView.dataSource = self
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
        previewThumbnailOperation?.cancel()
        downloadTask?.cancel()
        rotationTask?.cancel()
        undoValidationTask?.cancel()
        statusClearTask?.cancel()
        appendRetryTask?.cancel()
        creatorTask?.cancel()
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
        // 232 pt shows "Cleveland Museum of Art" and "Wellcome Collection" whole; at the 196 pt minimum a
        // truncated row shows its full name in a tooltip. A saved divider position still wins.
        sidebarItem.minimumThickness = 196
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
        window.defaultButtonCell = setWallpaperButton.cell as? NSButtonCell
        window.initialFirstResponder = collectionView
        galleryScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(galleryDidScroll), name: NSView.boundsDidChangeNotification, object: galleryScroll.contentView)
    }

    /// Give the first window enough room for provider names. Restoring an autosaved divider still takes precedence.
    @objc private func setInitialSidebarWidth() {
        guard let split = splitViewController else { return }
        let defaultWidth: CGFloat = 232
        guard split.view.bounds.width - defaultWidth >= split.splitViewItems[1].minimumThickness else { return }
        split.view.layoutSubtreeIfNeeded()
        split.splitView.setPosition(defaultWidth, ofDividerAt: 0)
    }

    private func configureControls() {
        searchField.target = self; searchField.action = #selector(search(_:))
        searchField.delegate = self
        searchField.sendsWholeSearchString = true
        configureSearchField()
        categoryPopUp.addItems(withTitles: WallhavenCategory.allCases.map(\.displayName))
        resolutionPopUp.addItems(withTitles: ["At Least Display Size", "Any Resolution", "1080p or Larger", "1440p or Larger", "4K or Larger"])
        aspectPopUp.addItems(withTitles: WallhavenAspectRatio.allCases.map(\.displayName))
        sortingPopUp.addItems(withTitles: WallhavenSorting.allCases.map(\.displayName))
        openverseLicensePopUp.addItems(withTitles: OpenverseLicenseFilter.allCases.map(\.displayName))
        let filterNames = ["Category", "Minimum resolution", "Aspect ratio", "Sort order", "License"]
        for (popup, name) in zip([categoryPopUp, resolutionPopUp, aspectPopUp, sortingPopUp, openverseLicensePopUp], filterNames) {
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
        configureSymbolButton(collectionButton, symbol: "rectangle.stack.badge.plus", label: "Add to Collection", action: #selector(showCollectionMenu(_:)))
        configureSymbolButton(moreButton, symbol: "ellipsis.circle", label: "More Actions", action: #selector(showMoreMenu(_:)))
        configureCreatorControls()

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
            viewModeControl.setToolTip(index == 0 ? "Gallery" : "Desktop Preview (Space)", forSegment: index)
            viewModeControl.setLabel("", forSegment: index)
        }
        viewModeControl.setAccessibilityLabel("View mode")
        viewModeControl.selectedSegment = 0
        viewModeControl.target = self; viewModeControl.action = #selector(viewModeChanged(_:))
        configureToolbarButton(rotationButton, symbol: "arrow.triangle.2.circlepath", label: "Automatic Rotation", action: #selector(showRotationSettings(_:)))
        configureToolbarButton(undoButton, symbol: "arrow.uturn.backward", label: "Undo Wallpaper Change", action: #selector(undoWallpaperChange(_:)))
        undoButton.isEnabled = false

        let width = defaults.object(forKey: "GalleryThumbnailSize") as? Int ?? 1
        galleryLayout.targetWidth = GalleryLayout.thumbnailWidths[GalleryLayout.thumbnailWidths.indices.contains(width) ? width : 1]
    }

    private func configureSymbolButton(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        button.contentTintColor = Theme.inkSecondary
        button.focusRingType = .exterior
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
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
        // New Collection is the `+` in the Collections group header.
        sidebar.onAddCollection = { [weak self] in self?.createCollection(nil) }
        let view = NSView()
        sidebar.scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sidebar.scrollView)
        NSLayoutConstraint.activate([
            sidebar.scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            sidebar.scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebar.scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sidebar.scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        return view
    }

    private func makeContentView() -> NSView {
        // Scope bar: Discover filters or the current folder, only where relevant.
        openverseNoticeLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        openverseNoticeLabel.textColor = .secondaryText
        openverseNoticeLabel.lineBreakMode = .byTruncatingTail
        openverseNoticeLabel.toolTip = "Wide, large, non-mature Wikimedia Commons JPEGs reported as CC0 or public domain. Openverse doesn’t verify licenses: review the source before reuse."
        // The acknowledgement stays whole at the minimum window width; the pending-search note gives way first.
        // It truncates (full text in its tooltip) only after every control around it has its room.
        openverseNoticeLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(400), for: .horizontal)
        cmaNoticeLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(400), for: .horizontal)
        loadMoreButton.controlSize = .small
        loadMoreButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        loadMoreButton.target = self; loadMoreButton.action = #selector(loadMoreResults(_:))
        loadMoreButton.toolTip = "Load the next page of Openverse results"
        reviewSourceButton.toolTip = selectedReference?.useRestriction?.errorDescription
        loadMoreButton.isHidden = true
        discoverBar.leadingGroup.setViews([categoryPopUp, resolutionPopUp, aspectPopUp, sortingPopUp, openverseLicensePopUp, openverseNoticeLabel, cmaNoticeLabel], in: .leading)
        pendingSearchLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pendingSearchLabel.textColor = .secondaryLabelColor
        pendingSearchLabel.lineBreakMode = .byTruncatingTail
        // Shown whole or not at all: a truncated “Showing “…” says nothing. The button and its tooltip remain.
        pendingSearchLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pendingSearchLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 148).isActive = true
        updateResultsButton.controlSize = .small
        updateResultsButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        updateResultsButton.target = self; updateResultsButton.action = #selector(search(_:))
        // Right-aligned, with the bar's own trailing padding: the note gives way first, Update Results and Load More stay.
        discoverBar.trailingGroup.setViews([pendingSearchLabel, updateResultsButton, loadMoreButton], in: .leading)
        discoverBar.trailingGroup.setVisibilityPriority(.detachOnlyIfNecessary, for: pendingSearchLabel)
        discoverBar.trailingGroup.setVisibilityPriority(.mustHold, for: updateResultsButton)
        discoverBar.trailingGroup.setVisibilityPriority(.mustHold, for: loadMoreButton)
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
        folderPathLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(200), for: .horizontal)
        localBar.leadingGroup.setViews([folderIcon, folderPathLabel], in: .leading)
        localBar.trailingGroup.setViews([changeFolder], in: .leading)
        let scopeSeparator = NSBox(); scopeSeparator.boxType = .separator
        let scopeRows = NSStackView(views: [discoverBar, localBar, creatorBar])
        scopeRows.orientation = .vertical
        scopeRows.edgeInsets = NSEdgeInsets(top: 7, left: 14, bottom: 7, right: 14)
        scopeBar.setViews([scopeRows, scopeSeparator], in: .top)
        scopeBar.orientation = .vertical
        scopeBar.spacing = 0
        [discoverBar, localBar, creatorBar].forEach { $0.widthAnchor.constraint(equalTo: scopeRows.widthAnchor, constant: -28).isActive = true }
        [scopeRows, scopeSeparator].forEach { $0.widthAnchor.constraint(equalTo: scopeBar.widthAnchor).isActive = true }

        // Gallery, desktop preview and empty state share one area; only one is visible.
        galleryScroll.documentView = collectionView
        galleryScroll.hasVerticalScroller = true
        galleryScroll.autohidesScrollers = true
        galleryScroll.drawsBackground = false
        galleryScroll.automaticallyAdjustsContentInsets = false
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
        barSeparator.boxType = .separator
        let view = contentRoot
        for subview in [scopeBar, galleryArea, barSeparator, applyBar] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
            subview.leadingAnchor.constraint(equalTo: view.leadingAnchor).isActive = true
            subview.trailingAnchor.constraint(equalTo: view.trailingAnchor).isActive = true
        }
        let galleryMinimum = galleryArea.heightAnchor.constraint(greaterThanOrEqualToConstant: 200)
        galleryMinimum.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scopeBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            galleryBelowScopeBar,
            galleryAboveDock,
            barSeparator.bottomAnchor.constraint(equalTo: applyBar.topAnchor),
            applyBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            applyBar.heightAnchor.constraint(equalToConstant: 56),
            galleryMinimum
        ])
        // The window's minimum width must come from the split (sidebar 196 + content 620), not from the widest row of
        // controls. Stacks default to a required clipping resistance, so their arranged views' widths summed into the
        // minimum content size (detachOnlyIfNecessary never got to act: the stack was never narrower than its contents).
        // With a low clipping resistance each stack takes the width its container gives it: optional views detach
        // (More by, View on…), labels truncate, and Display, Scaling, Set and the icon buttons keep their sizes.
        relaxHorizontalMinimums(in: view)
        return view
    }

    /// The dock and the scope bars bound their own groups explicitly (see `configureApplyBar` and `SplitBar`), so a
    /// blanket low clipping resistance would only let their fixed-size controls overflow; everything else relaxes.
    private func relaxHorizontalMinimums(in view: NSView) {
        if view === applyBar || view is SplitBar { return }
        if let stack = view as? NSStackView { stack.setClippingResistancePriority(.defaultLow, for: .horizontal) }
        view.subviews.forEach(relaxHorizontalMinimums(in:))
    }

    private func configureViewer() {
        // Use the full display title supplied by the provider, even when it needs several lines.
        previewTitleLabel.font = Theme.serif(18, weight: .medium)
        previewTitleLabel.textColor = Theme.inkPrimary
        previewTitleLabel.lineBreakMode = .byWordWrapping
        previewTitleLabel.maximumNumberOfLines = 0
        previewTitleLabel.cell?.truncatesLastVisibleLine = false
        previewTitleLabel.cell?.wraps = true
        previewTitleLabel.cell?.isScrollable = false
        previewMetadataLabel.textColor = .secondaryText
        previewTagsLabel.textColor = .secondaryText
        previewTagsLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        for label in [previewTitleLabel, previewMetadataLabel, previewTagsLabel] {
            label.alignment = .left
            if label !== previewTitleLabel { label.lineBreakMode = .byTruncatingTail }
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
        // A visible way into focus mode (also F); Esc brings the caption and controls back.
        let focusButton = NSButton()
        focusButton.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Focus Mode")
        focusButton.isBordered = false
        focusButton.imagePosition = .imageOnly
        focusButton.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        focusButton.contentTintColor = Theme.accentText
        focusButton.refusesFirstResponder = true
        focusButton.target = self; focusButton.action = #selector(focusButtonClicked(_:))
        focusButton.toolTip = "Focus Mode: hide the caption and controls (F). Esc brings them back."
        focusButton.setAccessibilityLabel("Focus Mode")
        focusButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        focusButton.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let pager = NSStackView(views: [previewPreviousButton, previewPositionLabel, previewNextButton, focusButton])
        pager.spacing = 4
        // Links must be clickable: selectable, with attributes.
        previewAttributionLabel.isSelectable = true
        previewAttributionLabel.allowsEditingTextAttributes = true
        previewAttributionLabel.lineBreakMode = .byTruncatingTail
        previewAttributionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previewAttributionLabel.isHidden = true
        previewAcknowledgementLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        previewAcknowledgementLabel.textColor = .secondaryText
        previewAcknowledgementLabel.alignment = .left
        previewAcknowledgementLabel.lineBreakMode = .byTruncatingTail
        previewAcknowledgementLabel.isHidden = true
        // Caption band under the stage: title and pager, then credit and date, source and license, notices.
        // Keep the pager at the trailing edge and give the title the rest of the caption width.
        let titleRow = NSView()
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        for view in [previewTitleLabel, pager] {
            view.translatesAutoresizingMaskIntoConstraints = false
            titleRow.addSubview(view)
        }
        pager.setContentHuggingPriority(.required, for: .horizontal)
        pager.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            previewTitleLabel.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
            previewTitleLabel.topAnchor.constraint(equalTo: titleRow.topAnchor),
            previewTitleLabel.bottomAnchor.constraint(equalTo: titleRow.bottomAnchor),
            previewTitleLabel.trailingAnchor.constraint(equalTo: pager.leadingAnchor, constant: -12),
            pager.trailingAnchor.constraint(equalTo: titleRow.trailingAnchor),
            pager.topAnchor.constraint(equalTo: titleRow.topAnchor, constant: 2)
        ])
        let caption = previewCaptionBand
        for view in [titleRow, previewMetadataLabel, previewTagsLabel, previewAttributionLabel, previewAcknowledgementLabel, approximatePreviewNotice] {
            caption.addArrangedSubview(view)
        }
        caption.orientation = .vertical
        caption.alignment = .leading
        caption.spacing = 3
        caption.setHuggingPriority(.required, for: .vertical)
        caption.setCustomSpacing(6, after: titleRow)
        for view in [titleRow, previewMetadataLabel, previewTagsLabel, previewAttributionLabel, previewAcknowledgementLabel] {
            view.widthAnchor.constraint(equalTo: caption.widthAnchor).isActive = true
        }
        for subview in [stageView, caption] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            viewerView.addSubview(subview)
        }
        let stageMinimum = stageView.heightAnchor.constraint(greaterThanOrEqualToConstant: 140)
        stageMinimum.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stageView.topAnchor.constraint(equalTo: viewerView.topAnchor, constant: 16),
            stageView.leadingAnchor.constraint(equalTo: viewerView.leadingAnchor, constant: 28),
            stageView.trailingAnchor.constraint(equalTo: viewerView.trailingAnchor, constant: -28),
            stageMinimum,
            caption.leadingAnchor.constraint(equalTo: viewerView.leadingAnchor, constant: 28),
            caption.trailingAnchor.constraint(equalTo: viewerView.trailingAnchor, constant: -28),
            caption.bottomAnchor.constraint(equalTo: viewerView.bottomAnchor, constant: -14),
            stageAboveCaption
        ])
        viewerView.setAccessibilityElement(true)
        viewerView.setAccessibilityRole(.group)
        viewerView.setAccessibilityLabel("Desktop preview")
        viewerView.onNavigate = { [weak self] direction in self?.moveSelection(direction: direction) }
        viewerView.onClose = { [weak self] in self?.setViewerVisible(false) }
        viewerView.onToggleFocus = { [weak self] in self?.setFocusMode(!(self?.isFocusMode ?? false)) }
        viewerView.onEscape = { [weak self] in
            guard let self, isFocusMode else { return false }
            setFocusMode(false)
            return true
        }
    }

    private func configureApplyBar() {
        busyIndicator.style = .spinning
        busyIndicator.controlSize = .small
        busyIndicator.isDisplayedWhenStopped = false
        // The dock is strictly two lines: this one (title and detail, never wrapping) and, under it, the status
        // when there is one. Status takes the place of the dock's second line; it never adds a third.
        selectionLabel.lineBreakMode = .byTruncatingTail
        selectionLabel.maximumNumberOfLines = 1
        selectionLabel.usesSingleLineMode = true
        selectionLabel.allowsExpansionToolTips = true
        statusLabel.maximumNumberOfLines = 1
        statusLabel.usesSingleLineMode = true
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.allowsExpansionToolTips = true
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryText
        statusLabel.isHidden = true
        let text = NSStackView(views: [selectionLabel, statusLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        for label in [selectionLabel, statusLabel] {
            label.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        }
        // Labels truncate before anything else gives: below the leading group's clipping resistance (500).
        for view in [text, selectionLabel, statusLabel] {
            view.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(200), for: .horizontal)
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        // The dock is three explicitly bounded parts, left to right: metadata (flexible), optional shortcuts (they
        // detach, lowest priority first, when there isn't room) and the controls group, pinned to the trailing edge
        // with required sizes. Display, Scaling and Set are therefore always present and never overlap anything.
        let leadingStack = NSStackView(views: [busyIndicator, text, statusUndoButton])
        leadingStack.spacing = 8
        leadingStack.distribution = .fill
        leadingStack.setClippingResistancePriority(NSLayoutConstraint.Priority(500), for: .horizontal)
        reviewSourceButton.target = self; reviewSourceButton.action = #selector(openSourcePage(_:))
        reviewSourceButton.controlSize = .small
        reviewSourceButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        reviewSourceButton.toolTip = "Openverse’s reported license for this image is missing or doesn’t match its license link. Review the original source; Wallpier won’t set it."
        reviewSourceButton.isHidden = true
        // Display and Scaling are named on screen, above their popups. They shrink before anything else is lost.
        for popup in [displayPopUp, scalingPopUp] {
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        // Keep these controls together at every width. Long display names are available in the menu and tooltip.
        displayPopUp.widthAnchor.constraint(equalToConstant: 120).isActive = true
        scalingPopUp.widthAnchor.constraint(equalToConstant: 100).isActive = true
        setWallpaperButton.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let displayGroup = labeled("Display", displayPopUp), scalingGroup = labeled("Scaling", scalingPopUp)
        displayGroup.widthAnchor.constraint(equalTo: displayPopUp.widthAnchor).isActive = true
        scalingGroup.widthAnchor.constraint(equalTo: scalingPopUp.widthAnchor).isActive = true
        // Favorite, Collection and ⋯ keep one place whatever the selection, then the three controls that apply.
        let controls = NSStackView(views: [favoriteButton, collectionButton, moreButton, displayGroup, scalingGroup, setWallpaperButton])
        controls.distribution = .fill
        controls.spacing = 8
        controls.setCustomSpacing(2, after: favoriteButton)
        controls.setCustomSpacing(2, after: collectionButton)
        controls.setCustomSpacing(12, after: moreButton)
        controls.setHuggingPriority(.required, for: .horizontal)
        controls.setContentCompressionResistancePriority(.required, for: .horizontal)
        controls.setClippingResistancePriority(.required, for: .horizontal)
        // These optional buttons are laid out together when their visibility or title changes.
        let optional = NSView()
        for button in [moreByButton, viewOnMuseumButton, reviewSourceButton] { optional.addSubview(button) }
        for view in [leadingStack, optional, controls] {
            view.translatesAutoresizingMaskIntoConstraints = false
            applyBar.addSubview(view)
        }
        // Optional controls occupy their measured widths, leaving the dock's surplus space to selection and status.
        let shortcutWidth = optional.widthAnchor.constraint(equalToConstant: 0)
        dockShortcutWidth = shortcutWidth
        NSLayoutConstraint.activate([
            leadingStack.leadingAnchor.constraint(equalTo: applyBar.leadingAnchor, constant: 16),
            leadingStack.centerYAnchor.constraint(equalTo: applyBar.centerYAnchor),
            controls.trailingAnchor.constraint(equalTo: applyBar.trailingAnchor, constant: -16),
            controls.centerYAnchor.constraint(equalTo: applyBar.centerYAnchor),
            optional.trailingAnchor.constraint(equalTo: controls.leadingAnchor, constant: -12),
            optional.centerYAnchor.constraint(equalTo: applyBar.centerYAnchor),
            optional.heightAnchor.constraint(equalToConstant: Self.dockShortcutHeight),
            leadingStack.trailingAnchor.constraint(equalTo: optional.leadingAnchor, constant: -10),
            shortcutWidth
        ])
        applyBar.setAccessibilityLabel("Selected wallpaper")
        applyBar.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(updateDockShortcutsForWidth),
                                               name: NSView.frameDidChangeNotification, object: applyBar)
    }

    @objc private func updateDockShortcutsForWidth() {
        let width = applyBar.bounds.width
        let compact = width > 0 && width < 720
        let hasSourceShortcut = !viewOnMuseumButton.isHidden || !reviewSourceButton.isHidden
        moreByButton.isHidden = (width > 0 && width < (hasSourceShortcut ? 960 : 820)) || pivotCreator == nil
        if let reference = selectedReference, reference.isBrowseOnly {
            let title = compact ? "View Source ↗" : "View on \(reference.providerName) ↗"
            if viewOnMuseumButton.title != title { viewOnMuseumButton.title = title }
        }
        let reviewTitle = compact ? "Review Source" : "Review Original Source"
        if reviewSourceButton.title != reviewTitle { reviewSourceButton.title = reviewTitle }
        let shortcuts: [(NSButton, CGFloat, CGFloat)] = [
            (moreByButton, 110, 230), (viewOnMuseumButton, 96, 160), (reviewSourceButton, 96, 160)
        ]
        var nextX: CGFloat = 0
        let spacing: CGFloat = 8
        for (button, minimum, maximum) in shortcuts where !button.isHidden {
            let size = button.intrinsicContentSize
            let buttonWidth = min(maximum, max(minimum, ceil(size.width)))
            button.frame = NSRect(x: nextX, y: (Self.dockShortcutHeight - size.height) / 2,
                                  width: buttonWidth, height: size.height)
            nextX += buttonWidth + spacing
        }
        dockShortcutWidth?.constant = max(0, nextX - spacing)
    }

    private func makeRotationPopover() -> NSPopover {
        let title = NSTextField(labelWithString: "Automatic Rotation")
        title.font = Theme.serif(17)
        title.textColor = Theme.inkPrimary
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
        rotationSummaryLabel.textColor = Theme.inkSecondary
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
        searchField.stringValue = draftQuery.queryText
        configureSearchField()
        openverseLicensePopUp.selectItem(at: OpenverseLicenseFilter.allCases.firstIndex(of: state.openverseSearch.license) ?? 0)
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
        // A creator view replaces whatever source opened it; every reload, selection and count reads this.
        if let creatorLevel { return creatorLevel.results.map(BrowserItem.remote) }
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

    /// Discover, showing whichever source was shown last.
    @objc func showDiscover(_ sender: Any?) { selectSource(.discover) }
    @objc func showWallhaven(_ sender: Any?) { showDiscover(provider: .wallhaven) }
    @objc func showOpenverse(_ sender: Any?) { showDiscover(provider: .openverse) }
    @objc func showCMA(_ sender: Any?) { showDiscover(provider: .cma) }
    @objc func showCatalog(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let source = RemoteProviderID(rawValue: raw), source.isCatalog else { return }
        showDiscover(provider: source)
    }

    /// Switches Discover's source. The other source's results, pages and failure are kept aside, untouched,
    /// and any request still running for it is cancelled by `selectSource`, so no result crosses sources.
    func showDiscover(provider: RemoteProviderID) {
        if provider != state.discoverProvider {
            parkedSessions[state.discoverProvider] = DiscoverSession(
                results: remoteResults, currentPage: currentPage, lastPage: lastPage, total: totalResults, hidden: hiddenResults,
                options: resultOptions, scrollY: state.currentSource == .discover && creatorLevel == nil
                    ? galleryScroll.contentView.bounds.origin.y : (creatorLevel?.parentScrollY ?? 0), errorText: searchErrorText,
                selectedIdentity: state.currentSource == .discover ? (creatorLevel?.anchorIdentity ?? selectedReference?.identityKey) : nil)
            let next = parkedSessions.removeValue(forKey: provider) ?? DiscoverSession()
            state.discoverProvider = provider
            remoteResults = next.results
            currentPage = next.currentPage; lastPage = next.lastPage; totalResults = next.total; hiddenResults = next.hidden
            resultOptions = next.options; searchErrorText = next.errorText; lastAppendFailure = nil
            if let identity = next.selectedIdentity { state.selectedRemoteIdentity = identity }
            searchField.stringValue = draftQuery.queryText
            configureSearchField()
            selectSource(.discover)
            if creatorLevel == nil, !remoteResults.isEmpty { restoreScroll(next.scrollY) }
            return
        }
        selectSource(.discover)
    }

    private func configureSearchField() {
        searchField.placeholderString = state.discoverProvider.filtersPublishedCatalog
            ? "Filter \(discoverName) wallpapers" : "Search \(discoverName)"
        switch state.discoverProvider {
        case .wallhaven: searchField.setAccessibilityHelp("Searches safe-for-work wallpapers on Wallhaven")
        case .openverse: searchField.setAccessibilityHelp("Searches openly licensed Wikimedia Commons images on Openverse")
        case .cma: searchField.setAccessibilityHelp("Searches open-access works at the Cleveland Museum of Art")
        default: searchField.setAccessibilityHelp(searchField.placeholderString)
        }
        searchField.toolTip = "Search \(discoverName) (⌘F). Results appear in Discover."
    }
    @objc func showLocal(_ sender: Any?) { selectSource(.local) }
    @objc func showFavorites(_ sender: Any?) { selectSource(.favorites) }
    @objc func showCollections(_ sender: Any?) { selectSource(.collections) }

    private func activate(_ item: SidebarItem) {
        switch item {
        case .discover: showDiscover(provider: .wallhaven)
        case .openverse: showDiscover(provider: .openverse)
        case .cma: showDiscover(provider: .cma)
        case .catalog(let provider): showDiscover(provider: provider)
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
        reconcileCreatorLevel()
        updateSourceUI()
        if state.currentSource == .discover && remoteResults.isEmpty && creatorLevel == nil { performSearch(page: 1, appending: false) }
        else { reloadCurrentSource() }
        if let scroll = pendingCreatorScroll { pendingCreatorScroll = nil; restoreScroll(scroll) }
    }

    private var currentSidebarItem: SidebarItem? {
        switch state.currentSource {
        case .discover:
            switch state.discoverProvider {
            case .wallhaven: return .discover
            case .openverse: return .openverse
            case .cma: return .cma
            default: return .catalog(state.discoverProvider)
            }
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
            state.currentSource = .discover; reconcileCreatorLevel()
        }
        // A new search replaces the results a creator view was opened from.
        dropCreatorLevel()
        updateSourceUI()
        persistSearchOptions(); performSearch(page: 1, appending: false)
    }

    @objc private func searchOptionChanged(_ sender: Any?) {
        persistSearchOptions()
        if state.currentSource == .discover { isViewerVisible = false; dropCreatorLevel(); updateSourceUI(); performSearch(page: 1, appending: false) } else { invalidateSearch() }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === searchField else { return }
        persistSearchOptions()
        invalidateSearch()
        // Typing elsewhere doesn't filter the folder or library: say where the search goes.
        let scope = "Press Return to search \(discoverName) in Discover."
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
        switch state.discoverProvider {
        case .wallhaven: state.wallhavenSearch.query = searchField.stringValue
        case .openverse: state.openverseSearch.query = searchField.stringValue
        case .cma: state.cmaSearch.query = searchField.stringValue
        default: state.catalogQueries[state.discoverProvider.rawValue] = searchField.stringValue
        }
        if OpenverseLicenseFilter.allCases.indices.contains(openverseLicensePopUp.indexOfSelectedItem) { state.openverseSearch.license = OpenverseLicenseFilter.allCases[openverseLicensePopUp.indexOfSelectedItem] }
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
        if !appending, statusLabel.textColor == Theme.statusError {
            showStatus("", isError: false)
        }
        if !appending { pendingAdvance = nil }
        if !appending && !state.discoverProvider.isCatalog {
            remoteThumbnailProvider.reset()
            remoteResults = []
            currentPage = 0; lastPage = 0; totalResults = 0; hiddenResults = 0
            lastAppendFailure = nil
            collectionView.reloadData()
            restoreSelection()
        }
        isSearching = true
        updateEmptyAndPagination(); updateControlAvailability()
        // A further page extends the visible results, so it repeats their request, not the edited controls.
        let query = appending ? resultOptions ?? draftQuery : draftQuery
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result: RemoteSearchPage
                switch query {
                case .wallhaven(let options): result = try await provider.search(options: options, page: page)
                case .openverse(let options): result = try await openverseProvider.search(options: options, page: page)
                case .cma(let options): result = try await cmaProvider.search(options: options, page: page)
                case .catalog(let source, let options):
                    result = try await catalogLibrary.search(source, query: options, page: page)
                }
                try Task.checkCancellation()
                guard searchGeneration == generation, state.currentSource == .discover, state.discoverProvider == query.provider else { return }
                resultOptions = query
                hiddenResults = (appending ? hiddenResults : 0) + result.hiddenCount
                if appending {
                    let known = Set(remoteResults.map(\.identityKey))
                    let added = result.wallpapers.filter { !known.contains($0.identityKey) }
                    let start = remoteResults.count
                    remoteResults.append(contentsOf: added)
                    // After an empty filtered page there is nothing to extend: show and select the first results.
                    if start == 0 { collectionView.reloadData(); restoreSelection() }
                    else { collectionView.insertItems(at: Set((start..<remoteResults.count).map { IndexPath(item: $0, section: 0) })) }
                } else {
                    if query.provider.isCatalog { remoteThumbnailProvider.reset() }
                    remoteResults = result.wallpapers
                    state.selectedRemoteIdentity = remoteResults.first?.identityKey
                    collectionView.reloadData(); restoreSelection()
                }
                currentPage = result.currentPage; lastPage = result.lastPage; totalResults = result.total
                isSearching = false
                updateEmptyAndPagination(); updateControlAvailability(); stateStore.save(state)
                if appending, statusLabel.stringValue == loadingMoreStatus { showStatus("", isError: false) }
                if let remaining = result.rateLimit.remaining, remaining < 10 {
                    showStatus("\(query.provider.displayName) allows \(remaining) more requests this minute.", isError: false)
                }
                if result.hiddenCount > 0 {
                    showStatus("\(hiddenResults) \(query.provider.displayName) result\(hiddenResults == 1 ? " was" : "s were") hidden: the image host, license or links couldn’t be verified.", isError: false)
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
                    showStatus("Couldn’t load more results. \(friendlyMessage(for: error, source: query.provider.displayName))", isError: true)
                } else {
                    let message = friendlyMessage(for: error, source: query.provider.displayName)
                    searchErrorText = message
                    showStatus(query.provider.isCatalog && !remoteResults.isEmpty ? message : "", isError: !remoteResults.isEmpty)
                }
                updateEmptyAndPagination(); updateControlAvailability()
            }
        }
    }

    @objc private func galleryDidScroll(_ notification: Notification) { loadMoreIfNeeded() }

    /// Loads the next Discover page when the user nears the end of the grid. A failed page waits
    /// a few seconds before scrolling can retry it, so an outage never turns into a request loop.
    /// Discover has result pages that aren't loaded yet: the loaded results aren't the whole set.
    private var hasUnloadedResults: Bool { state.currentSource == .discover && creatorLevel == nil && currentPage < lastPage }
    private var canLoadMoreResults: Bool {
        hasUnloadedResults && !isSearching && Date().timeIntervalSince(lastAppendFailure ?? .distantPast) > appendRetryCooldown
    }

    private func loadMoreIfNeeded() {
        guard state.discoverProvider == .wallhaven, canLoadMoreResults, !galleryScroll.isHidden else { return }
        let visible = galleryScroll.documentVisibleRect
        guard visible.maxY >= collectionView.frame.height - max(visible.height * 0.5, 200) else { return }
        performSearch(page: currentPage + 1, appending: true)
    }

    /// Openverse's explicit next page: from the bar, or an empty filtered page's empty state.
    @objc func loadMoreResults(_ sender: Any?) {
        guard canLoadMoreResults else { NSSound.beep(); return }
        performSearch(page: currentPage + 1, appending: true)
    }

    // MARK: - Creator view (Cleveland Museum of Art)

    private var pendingCreatorScroll: CGFloat?

    private func configureCreatorControls() {
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        cmaNoticeLabel.font = small
        cmaNoticeLabel.textColor = .secondaryText
        cmaNoticeLabel.lineBreakMode = .byTruncatingTail
        cmaNoticeLabel.toolTip = "Works the Cleveland Museum of Art has released as CC0 open access. Each work credits its maker and links to the museum’s own page."

        for button in [moreByButton, viewOnMuseumButton, creatorLinkButton] {
            button.controlSize = .small
            button.font = small
            button.lineBreakMode = .byTruncatingTail
            button.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        }
        moreByButton.target = self; moreByButton.action = #selector(showCreator(_:))
        moreByButton.isHidden = true
        viewOnMuseumButton.target = self; viewOnMuseumButton.action = #selector(openSourcePage(_:))
        viewOnMuseumButton.setAccessibilityLabel("View on Cleveland Museum of Art")
        viewOnMuseumButton.setAccessibilityRole(.link)
        viewOnMuseumButton.isHidden = true
        creatorLinkButton.target = self; creatorLinkButton.action = #selector(openCreatorLink(_:))
        creatorLinkButton.setAccessibilityLabel("View the starting work on the Cleveland Museum of Art website")
        creatorLinkButton.setAccessibilityRole(.link)
        creatorLinkButton.isHidden = true

        statusUndoButton.isBordered = false
        statusUndoButton.font = small
        statusUndoButton.contentTintColor = Theme.accentText
        statusUndoButton.target = self; statusUndoButton.action = #selector(undoWallpaperChange(_:))
        statusUndoButton.setAccessibilityLabel("Undo Wallpaper Change")
        statusUndoButton.isHidden = true

        // The artist header, in the content area: Back, the creator's name in the editorial serif, a truthful
        // count line, and a link to the starting work by its real title. The toolbar names the source instead.
        creatorBackButton.controlSize = .small
        creatorBackButton.font = small
        creatorBackButton.bezelStyle = .inline
        creatorBackButton.isBordered = false
        creatorBackButton.contentTintColor = Theme.accentText
        creatorBackButton.imagePosition = .imageLeading
        creatorBackButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
        creatorBackButton.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        creatorBackButton.lineBreakMode = .byTruncatingTail
        creatorBackButton.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        creatorBackButton.target = self; creatorBackButton.action = #selector(closeCreator(_:))
        creatorBackButton.toolTip = "Back (Esc)"
        creatorBackButton.setAccessibilityLabel("Back")
        creatorTitleLabel.font = Theme.serif(22)
        creatorTitleLabel.textColor = Theme.inkPrimary
        creatorTitleLabel.lineBreakMode = .byTruncatingTail
        creatorTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        creatorSubtitleLabel.font = small
        creatorSubtitleLabel.textColor = .secondaryText
        creatorSubtitleLabel.lineBreakMode = .byTruncatingTail
        creatorSubtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        creatorStatusLabel.font = small
        creatorStatusLabel.textColor = .secondaryText
        creatorStatusLabel.lineBreakMode = .byTruncatingTail
        creatorStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        creatorStatusLabel.isHidden = true
        creatorLinkButton.isBordered = false
        creatorLinkButton.contentTintColor = Theme.accentText
        // Back at the leading edge, the starting-work link at the trailing edge, with the row spanning the header.
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let backRow = NSStackView(views: [creatorBackButton, spacer, creatorLinkButton])
        backRow.spacing = 12
        backRow.distribution = .fill
        // The link fits whole when there is room and otherwise visibly truncates inside its own bounds (full title in
        // its tooltip and accessibility label); it yields (below the stack's 250 clipping) before Back does.
        creatorLinkButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        creatorLinkButton.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(200), for: .horizontal)
        creatorLinkButton.lineBreakMode = .byTruncatingTail
        creatorLinkButton.cell?.lineBreakMode = .byTruncatingTail
        creatorLinkButton.cell?.truncatesLastVisibleLine = true
        creatorBackButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        creatorSeparatorLabel.font = small
        creatorSeparatorLabel.textColor = .secondaryText
        creatorSeparatorLabel.isHidden = true
        creatorSeparatorLabel.setAccessibilityElement(false)
        let countRow = NSStackView(views: [creatorSubtitleLabel, creatorSeparatorLabel, creatorStatusLabel])
        countRow.spacing = 6
        creatorBar.setViews([backRow, creatorTitleLabel, countRow], in: .top)
        creatorBar.orientation = .vertical
        creatorBar.alignment = .leading
        creatorBar.spacing = 2
        backRow.widthAnchor.constraint(equalTo: creatorBar.widthAnchor).isActive = true
        creatorBar.setAccessibilityLabel("Creator")
        creatorBar.isHidden = true
    }

    /// What the page's "More by" opens: the creator the selected work credits plainly, from the work's own record.
    private var pivotCreator: CatalogCreator? {
        guard creatorLevel == nil, let reference = selectedReference, !reference.isBrowseOnly else { return nil }
        if let cma = reference.cmaPivot { return CatalogCreator(id: String(cma.id), name: cma.name) }
        guard reference.provider == .met || reference.provider == .wellcome,
              let creator = reference.catalog?.creator, !creator.id.isEmpty,
              !DisplayText.clean(creator.name).isEmpty else { return nil }
        return CatalogCreator(id: creator.id, name: DisplayText.creator(creator.name))
    }

    private var originKey: String {
        switch state.currentSource {
        case .discover: return "discover:\(state.discoverProvider.rawValue)"
        case .local: return "local"
        case .favorites: return "favorites"
        case .collections: return "collection:\(state.selectedCollectionID?.uuidString ?? "")"
        }
    }

    /// What Back returns to, in the user's terms: the search they ran, Favorites, a collection or the folder.
    private var currentOriginName: String {
        switch state.currentSource {
        case .discover:
            let query = draftQuery.trimmedQuery
            let applied = resultOptions?.trimmedQuery ?? query
            return applied.isEmpty ? discoverName : "“\(applied)”"
        case .local: return state.folderPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Folder"
        case .favorites: return "Favorites"
        case .collections: return selectedCollection.map { "“\($0.name)”" } ?? "Collection"
        }
    }

    @objc func showCreator(_ sender: Any?) {
        guard let reference = selectedReference, let creator = pivotCreator else { NSSound.beep(); return }
        openCreator(id: creator.id, name: creator.name, from: reference)
    }

    /// One level only: the view replaces the gallery's items, leaving the results beneath it untouched.
    /// A creator already loaded this session opens from memory; otherwise it costs one detail and one search request.
    private func openCreator(id: String, name: String, from anchor: WallpaperReference) {
        guard creatorLevel == nil, let provider = anchor.provider else { return }
        isViewerVisible = false
        // The results beneath must not change while the creator view covers them.
        searchTask?.cancel(); searchGeneration = UUID(); searchTask = nil; isSearching = false; pendingAdvance = nil
        var level = CreatorLevel(originKey: originKey, provider: provider, creatorID: id, name: name, anchorIdentity: anchor.identityKey,
                                 anchorPageURL: browsableSourceURL(anchor), parentScrollY: galleryScroll.contentView.bounds.origin.y)
        level.anchorTitle = anchor.displayTitle
        level.originName = currentOriginName
        if let cached = creatorCache[level.cacheKey] { apply(cached, to: &level) }
        creatorLevel = level
        state.selectedRemoteIdentity = level.results.first?.identityKey
        updateSourceUI()
        reloadCurrentSource()
        restoreScroll(0)
        if level.phase == .loading { loadCreator(level) }
        window?.makeFirstResponder(collectionView)
        showStatus("", isError: false)
    }

    private func apply(_ page: CreatorSearchResult, to level: inout CreatorLevel) {
        level.name = page.name
        level.results = page.works.filter { $0.identityKey != level.anchorIdentity }
        level.matchTotal = page.matchTotal
        level.returnedCount = page.returnedCount
        level.phase = .loaded
    }

    private func loadCreator(_ request: CreatorLevel) {
        creatorTask?.cancel()
        let generation = UUID()
        creatorGeneration = generation
        creatorTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page: CreatorSearchResult
                if let id = request.cmaCreatorID {
                    let result = try await cmaProvider.creatorWorks(id: id)
                    page = CreatorSearchResult(name: result.name, works: result.works,
                                               matchTotal: result.matchTotal, returnedCount: result.returnedCount)
                } else {
                    let creator = CatalogCreator(id: request.creatorID, name: request.name)
                    let result = try await catalogLibrary.search(request.provider,
                        query: CatalogSearchOptions(query: "", creator: creator), page: 1)
                    let works = result.wallpapers.filter { $0.catalog?.creator?.id == creator.id }
                    page = CreatorSearchResult(name: request.name, works: works, matchTotal: nil,
                                               returnedCount: works.count)
                }
                try Task.checkCancellation()
                guard creatorGeneration == generation, var level = creatorLevel, level.cacheKey == request.cacheKey else { return }
                creatorCache[level.cacheKey] = page
                apply(page, to: &level)
                creatorLevel = level
                state.selectedRemoteIdentity = level.results.first?.identityKey
                updateSourceUI(); reloadCurrentSource()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, creatorGeneration == generation, var level = creatorLevel, level.cacheKey == request.cacheKey else { return }
                level.phase = .failed(friendlyMessage(for: error, source: request.provider.displayName))
                creatorLevel = level
                updateSourceUI(); updateEmptyAndPagination(); updateControlAvailability()
            }
        }
    }

    /// Retry clears the cached entry and asks again.
    @objc func retryCreator(_ sender: Any?) {
        guard var level = creatorLevel else { return }
        creatorCache.removeValue(forKey: level.cacheKey)
        level.phase = .loading
        level.results = []
        creatorLevel = level
        updateSourceUI(); reloadCurrentSource()
        loadCreator(level)
    }

    /// Back to the gallery that opened the creator view: its scroll position, its selection (the work the user
    /// started from) and keyboard focus on the gallery.
    @objc func closeCreator(_ sender: Any?) {
        guard let level = creatorLevel else { return }
        creatorTask?.cancel(); creatorGeneration = UUID()
        isViewerVisible = false
        creatorLevel = nil
        state.selectedRemoteIdentity = level.anchorIdentity
        updateSourceUI()
        reloadCurrentSource()
        restoreScroll(level.parentScrollY)
        window?.makeFirstResponder(collectionView)
    }

    /// Esc, when nothing else owns it: leaves the creator view. The preview's own Esc is unchanged.
    private func handleEscape() -> Bool {
        guard creatorLevel != nil else { return false }
        closeCreator(nil)
        return true
    }

    private func dropCreatorLevel() {
        creatorTask?.cancel(); creatorGeneration = UUID()
        creatorLevel = nil
        parkedCreators.removeValue(forKey: originKey)
    }

    /// A source change parks the visible creator view with its source; coming back restores it, with its results,
    /// selection and scroll. A creator still loading when parked loads again on return.
    private func reconcileCreatorLevel() {
        let key = originKey
        if var level = creatorLevel, level.originKey != key {
            level.scrollY = galleryScroll.contentView.bounds.origin.y
            creatorTask?.cancel(); creatorGeneration = UUID()
            parkedCreators[level.originKey] = level
            creatorLevel = nil
        }
        guard creatorLevel == nil, var restored = parkedCreators.removeValue(forKey: key) else { return }
        if restored.phase == .loading, let cached = creatorCache[restored.cacheKey] { apply(cached, to: &restored) }
        creatorLevel = restored
        if let identity = restored.selectedIdentity { state.selectedRemoteIdentity = identity }
        pendingCreatorScroll = restored.scrollY
        if restored.phase == .loading { loadCreator(restored) }
    }

    private func restoreScroll(_ y: CGFloat) {
        collectionView.layoutSubtreeIfNeeded()
        let maximum = max(0, collectionView.frame.height - galleryScroll.contentView.bounds.height)
        galleryScroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, y), maximum)))
        galleryScroll.reflectScrolledClipView(galleryScroll.contentView)
    }

    @objc func openCreatorLink(_ sender: Any?) {
        guard let url = creatorLevel?.anchorPageURL else { NSSound.beep(); return }
        urlOpener(url)
    }

    /// Opens a link in the user's browser; tests replace it so activating a link never launches one.
    private var urlOpener: (URL) -> Void = { _ = NSWorkspace.shared.open($0) }

    private func updateCreatorBar() {
        guard let level = creatorLevel else { creatorBar.isHidden = true; return }
        creatorTitleLabel.stringValue = level.name
        creatorTitleLabel.toolTip = level.name
        creatorSubtitleLabel.stringValue = level.subtitle
        creatorBackButton.title = "Back to \(level.originName)"
        creatorBackButton.setAccessibilityLabel("Back to \(level.originName)")
        // The count describes what is on screen, and for a bounded search page says so; it never invents a total.
        let status: String
        if level.phase == .loaded, level.isTruncated, let total = level.matchTotal {
            status = "Showing \(level.results.count.formatted()) works from the first \(level.returnedCount.formatted()) of \(total.formatted()) matches"
        } else if level.phase == .loaded {
            status = level.results.count == 1 ? "1 work shown" : "\(level.results.count.formatted()) works shown"
        } else {
            status = ""
        }
        creatorStatusLabel.stringValue = status
        creatorStatusLabel.toolTip = status.isEmpty ? nil : status
        creatorStatusLabel.isHidden = status.isEmpty
        creatorSeparatorLabel.isHidden = status.isEmpty
        let starting = level.anchorTitle.isEmpty ? "the starting work" : "“\(level.anchorTitle)”"
        creatorLinkButton.title = "View \(starting) on \(level.provider.displayName) ↗"
        creatorLinkButton.toolTip = "Open \(starting) on \(level.provider.displayName)"
        creatorLinkButton.setAccessibilityLabel("View \(starting) on \(level.provider.displayName)")
        creatorLinkButton.isHidden = level.anchorPageURL == nil
    }

#if DEBUG
    var isShowingCreatorViewForTesting: Bool { creatorLevel != nil }
    var visibleItemIdentitiesForTesting: [String] { currentItems.map(\.identifier) }
    var parkedCreatorCountForTesting: Int { parkedCreators.count }
    var selectedIdentityForTesting: String? { selectedItem?.identifier }
    var creatorTaskForTesting: Task<Void, Never>? { creatorTask }
    var creatorCacheKeysForTesting: Set<String> { Set(creatorCache.keys) }
    var selectedReferenceForTesting: WallpaperReference? { selectedReference }
    var urlOpenerForTesting: (URL) -> Void { get { urlOpener } set { urlOpener = newValue } }
    func creatorWorkForTesting(_ identity: String) -> WallpaperReference? { creatorLevel?.results.first { $0.identityKey == identity } }
#endif

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
        case .remote(let ref):
            if ref.isBrowseOnly, let restriction = ref.useRestriction {
                showStatus(restriction.errorDescription ?? "This work can’t be set.", isError: true); NSSound.beep(); return
            }
            downloadAndSet(ref, screen: screen, source: .user)
        }
    }

    private func downloadAndSet(_ reference: WallpaperReference, screen: NSScreen, source: SetSource) {
        guard downloadTask == nil else { return }
        let scaling = selectedScalingMode
        setWallpaperButton.isEnabled = false
        showStatus(reference.provider == .cma ? "Downloading high-resolution museum JPEG…" : "Preparing the full-resolution original…", isError: false)
        let confirmation = reference.provider == .cma ? "Set on \(screen.localizedName) · High-resolution museum JPEG (CC0)" : nil
        downloadTask = Task { [weak self] in
            guard let self else { return }
            defer { downloadTask = nil; updateControlAvailability() }
            do {
                let url = try await historyStore.retain(try await localOriginal(for: reference))
                try Task.checkCancellation()
                await applyWallpaper(url, to: screen, scaling: scaling, source: source, confirmation: confirmation)
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
        // Checked before any cached copy is reused, so Set and rotation both fail closed.
        if let restriction = reference.useRestriction { throw restriction }
        let catalog = reference.provider?.isCatalog == true
        var current = catalog ? try await catalogLibrary.checkedReference(for: reference) : reference
        if let cached = try await originalCache.cachedURL(for: current, accepting: Self.originalCheck(for: current)) {
            if catalog, current.width == 0 || current.height == 0 {
                if let size = CatalogLibrary.originalSize(cached) { current.width = size.width; current.height = size.height }
            }
            updateReference(current, cachedPath: cached.path); showOriginalIfSelected(current, at: cached); return cached
        }
        showStatus(reference.provider == .cma ? "Downloading high-resolution museum JPEG…"
                   : "Downloading the original from \(reference.sourceDisplayName)…", isError: false)
        let temporary: URL
        // The museum's record is refreshed first; the refreshed record is what the download is checked against.
        switch reference.provider {
        case .openverse?: temporary = try await openverseProvider.downloadOriginal(for: reference)
        case .wallhaven?: temporary = try await provider.downloadOriginal(for: reference)
        case .cma?:
            let result = try await cmaProvider.downloadPrint(for: reference)
            temporary = result.file
            current = result.reference
            current.cachedLocalPath = reference.cachedLocalPath
        case nil: throw RemoteProviderError.unsupportedProvider
        default:
            let result = try await catalogLibrary.downloadOriginal(for: current)
            temporary = result.file
            current = result.reference
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        let installed = try await originalCache.installDownloadedFile(temporary, for: current, protectedPaths: currentProtectedPaths(),
                                                                      accepting: Self.originalCheck(for: current))
        updateReference(current, cachedPath: installed.path)
        showOriginalIfSelected(current, at: installed)
        return installed
    }

    /// Openverse cache files must still be the exact reported original, and CMA files the validated print JPEG;
    /// Wallhaven keeps the cache's own check.
    private static func originalCheck(for reference: WallpaperReference) -> ((URL) -> Bool)? {
        switch reference.provider {
        case .openverse?: return { OpenverseProvider.isFaithfulOriginal(at: $0, for: reference) }
        case .cma?: return { CMAProvider.isFaithfulPrint(at: $0, for: reference) }
        case .wallhaven?, nil: return nil
        default: return { CatalogLibrary.isFaithfulOriginal($0, reference: reference) }
        }
    }

    private func updateReference(_ reference: WallpaperReference, cachedPath: String? = nil) {
        var updated = reference
        let existing = remoteResults.first { $0.identityKey == reference.identityKey }
            ?? state.favorites.first { $0.identityKey == reference.identityKey }
            ?? state.collections.lazy.flatMap(\.wallpapers).first { $0.identityKey == reference.identityKey }
        updated.cachedLocalPath = cachedPath ?? existing?.cachedLocalPath ?? reference.cachedLocalPath
        if let cachedPath { updated.cachedLocalPath = cachedPath }
        if let index = remoteResults.firstIndex(where: { $0.identityKey == updated.identityKey }) { remoteResults[index] = updated }
        if let index = creatorLevel?.results.firstIndex(where: { $0.identityKey == updated.identityKey }) { creatorLevel?.results[index] = updated }
        for (key, level) in parkedCreators {
            guard let index = level.results.firstIndex(where: { $0.identityKey == updated.identityKey }) else { continue }
            parkedCreators[key]?.results[index] = updated
        }
        for key in Array(creatorCache.keys) {
            guard let index = creatorCache[key]?.works.firstIndex(where: { $0.identityKey == updated.identityKey }) else { continue }
            creatorCache[key]?.works[index] = updated
        }
        state.favorites = state.favorites.map { $0.identityKey == updated.identityKey ? updated : $0 }
        state.collections = state.collections.map { collection in
            let mapped = collection.wallpapers.map { $0.identityKey == updated.identityKey ? updated : $0 }
            return WallpaperCollection(id: collection.id, name: collection.name, wallpapers: mapped)
        }
        stateStore.save(state)
    }

    private func applyWallpaper(_ imageURL: URL, to screen: NSScreen, scaling: ScalingMode, source: SetSource, confirmation: String? = nil) async {
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
            if let confirmation {
                // A museum work says what was set, with Undo beside it while the change can be undone.
                showStatus(confirmation + undoNote, isError: false, offersUndo: undoNote.isEmpty)
            } else {
                showStatus(String(format: "Set %@ on %@ in %.1f ms.", imageURL.lastPathComponent, screen.localizedName, result.elapsedTime * 1_000) + undoNote, isError: false)
            }
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
        guard var next = WallpaperNavigation.index(after: selectedIndex, direction: direction, count: currentItems.count),
              next != selectedIndex else { return nil }
        // The preview skips works that can only be browsed: they have nothing to draw.
        if isViewerVisible {
            let items = currentItems
            var steps = 0
            while items[next].isBrowseOnly {
                guard steps < items.count, let following = WallpaperNavigation.index(after: next, direction: direction, count: items.count) else { return nil }
                next = following; steps += 1
            }
            if next == selectedIndex { return nil }
        }
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
            showStatus(loadingMoreStatus, isError: false)
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

    /// Closing the preview ends everything it was waiting for: details, local preview decode, a pending boundary move, the loading state.
    private func endPreviewSession() {
        cancelDetails()
        cancelLocalPreview()
        pendingAdvance = nil
        stageView.placeholder = .none
        if isFocusMode { setFocusMode(false) }
    }

    private func updatePreviewNavigation() {
        let count = currentItems.count
        if let index = selectedIndex {
            previewPositionLabel.stringValue = "\((index + 1).formatted()) of \(count.formatted())" + (hasUnloadedResults ? " loaded" : "")
        } else {
            previewPositionLabel.stringValue = ""
        }
        previewPositionLabel.toolTip = hasUnloadedResults
            ? "\(count.formatted()) of \(totalResults.formatted()) \(discoverName) results are loaded. Next at the last one loads more." : nil
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
        case .remote(let ref):
            state.selectedRemoteIdentity = ref.identityKey
            if creatorLevel != nil { creatorLevel?.selectedIdentity = ref.identityKey }
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
        cancelLocalPreview()
        stageView.image = nil
        stageView.placeholder = .none
        stageFidelity = .none
        updatePreviewNotice()
        // Attribution belongs to one Openverse selection; nothing else inherits it.
        previewAttributionLabel.attributedStringValue = NSAttributedString()
        previewAttributionLabel.isHidden = true
        previewAcknowledgementLabel.isHidden = true
        previewTagsLabel.isHidden = false
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
        // A museum work without a verified print has no preview: no thumbnail, cached copy or detail request.
        if case .remote(let ref) = item, ref.isBrowseOnly { stageView.placeholder = .unavailable; return }
        if stageView.image == nil { stageView.placeholder = .loading }
        switch item {
        case .local(let url): loadLocalPreview(url, identity: item.identifier, cancelsPrevious: true)
        case .remote(let ref):
            // A validated cached original is best, but checking takes a moment: show the most faithful
            // thumbnail meanwhile unless an original is expected. Nothing here downloads an original.
            if ref.cachedLocalPath == nil { loadRemotePreview(ref) }
            Task { [weak self] in
                let cached = try? await self?.originalCache.cachedURL(for: ref, accepting: Self.originalCheck(for: ref))
                guard let self, selectedItem?.identifier == ref.identityKey else { return }
                if let cached { loadLocalPreview(cached, identity: ref.identityKey) { [weak self] in self?.loadRemotePreview(ref) } }
                else if ref.cachedLocalPath != nil { loadRemotePreview(ref) }
            }
            fetchDetailsIfNeeded(for: ref)
        }
    }

    private func cancelLocalPreview() {
        previewThumbnailToken &+= 1
        previewThumbnailOperation?.cancel()
        previewThumbnailOperation = nil
    }

    private func loadLocalPreview(_ url: URL, identity: String, cancelsPrevious: Bool = false, onFailure: (() -> Void)? = nil) {
        let token: UInt64?
        if cancelsPrevious {
            cancelLocalPreview()
            token = previewThumbnailToken
        } else {
            token = nil
        }
        let operation = thumbnailProvider.requestThumbnail(for: url, maximumPixelSize: 1800) { [weak self] image in
            guard let self else { return }
            if let token, self.previewThumbnailToken == token {
                self.previewThumbnailOperation = nil
            }
            guard selectedItem?.identifier == identity else { return }
            guard let image else {
                if let onFailure { onFailure() } else if isViewerVisible, stageFidelity == .none { stageView.placeholder = .unavailable }
                return
            }
            showOnStage(image, fidelity: .original, identity: identity)
        }
        if let token, let operation, previewThumbnailToken == token {
            previewThumbnailOperation = operation
        }
    }

    private func loadRemotePreview(_ ref: WallpaperReference) {
        guard let (url, fidelity) = ref.remotePreview else {
            if isViewerVisible, selectedItem?.identifier == ref.identityKey, stageFidelity == .none { stageView.placeholder = .unavailable }
            return
        }
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
        if selected.width > 0 && selected.height > 0 {
            stageView.imagePixelSize = CGSize(width: selected.width, height: selected.height)
        }
        if isViewerVisible { loadLocalPreview(url, identity: selected.identityKey) }
    }

    private func configureRemoteMetadata(_ reference: WallpaperReference) {
        // A museum work's credit is in the attribution line; its caption gives the date instead.
        let credit = reference.provider == .cma ? reference.cmaDateText : reference.displayCredit
        let size = reference.width > 0 && reference.height > 0 ? WallpaperShape.summary(width: reference.width, height: reference.height) : nil
        let parts = [size, credit,
                     reference.cachedLocalPath == nil ? nil : "Original downloaded"]
        previewMetadataLabel.stringValue = parts.compactMap { $0 }.joined(separator: " · ")
        let openverse = reference.provider == .openverse
        let museum = reference.provider == .cma
        previewTagsLabel.stringValue = reference.tags.isEmpty && !openverse && !museum && reference.provider == .wallhaven
            ? "Wallhaven · SFW" : reference.tags.joined(separator: " · ")
        previewTagsLabel.isHidden = previewTagsLabel.stringValue.isEmpty
        let attribution = Self.attribution(for: reference, creatorID: creatorLevel?.cmaCreatorID)
        previewAttributionLabel.attributedStringValue = attribution ?? NSAttributedString()
        previewAttributionLabel.isHidden = attribution == nil
        previewAcknowledgementLabel.isHidden = !openverse
        updateSelectionSummary()
    }

    /// Reported license (linked when a license URL was reported), the source page, and Openverse's acknowledgement.
    /// Never fills in a license the source didn't report.
    static func attribution(for reference: WallpaperReference, creatorID: Int? = nil) -> NSAttributedString? {
        guard reference.provider == .openverse || reference.provider == .cma || reference.provider?.isCatalog == true else { return nil }
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .left; paragraph.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString()
        func add(_ string: String, link: URL? = nil) {
            var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                                                             .foregroundColor: NSColor.secondaryText, .paragraphStyle: paragraph]
            // Links use the accent foreground (vermilion), underlined so they don't rely on color alone, not system blue.
            if let link {
                attributes[.link] = link
                attributes[.foregroundColor] = Theme.accentText
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            text.append(NSAttributedString(string: string, attributes: attributes))
        }
        if reference.provider == .cma {
            // "Katsushika Hokusai · Cleveland Museum of Art · CC0": the museum is the link, to the record's own page.
            add("\(reference.cmaCredit(preferring: creatorID)) · ")
            add("Cleveland Museum of Art", link: reference.cmaPageURL)
            if reference.cma?.isCC0 == true { add(" · CC0") }
            return text
        }
        if reference.provider?.isCatalog == true {
            let credit = DisplayText.clean(reference.catalog?.credit)
            if !credit.isEmpty, credit != reference.providerName { add("\(credit) · ") }
            add(reference.providerName, link: CatalogLibrary.sourcePage(for: reference))
            if let license = reference.licenseDescription {
                add(" · ")
                add(license, link: CatalogLibrary.licensePage(for: reference))
            }
            return text
        }
        if reference.licenseIsConsistent {
            add("\(reference.licenseDescription ?? "") as reported", link: reference.licenseURL)
        } else {
            add("\(reference.licenseDescription ?? "No license reported") · unconfirmed, review source")
        }
        add(" · ")
        let landing = OpenverseURLPolicy.isAllowedLandingURL(reference.sourcePageURL, source: reference.sourceName) ? reference.sourcePageURL : nil
        add("Source: \(reference.sourceDisplayName)", link: landing)
        return text
    }

    /// Uploader and tags, and the uncropped thumbnail older references lack, come from the API. Requested
    /// once per selected wallpaper, after a short dwell, and a throttled API only leaves them missing.
    private func fetchDetailsIfNeeded(for reference: WallpaperReference) {
        // A museum work's record is complete as listed; its detail is only refreshed when a new download needs it.
        guard let providerID = reference.provider, providerID != .cma, !providerID.isCatalog,
              reference.uploader == nil || reference.tags.isEmpty || reference.remotePreview?.fidelity == .croppedThumbnail,
              detailIdentity != reference.identityKey else { return }
        detailTask?.cancel()
        detailIdentity = reference.identityKey
        detailTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.detailDwellNanoseconds)
                guard let self, isViewerVisible, selectedReference?.identityKey == reference.identityKey else { return }
                let detailed: WallpaperReference
                switch reference.provider {
                case .openverse?: detailed = try await openverseProvider.fetchDetails(for: reference)
                case .wallhaven?: detailed = try await provider.fetchDetails(for: reference)
                default: return
                }
                try Task.checkCancellation(); updateReference(detailed)
                guard let current = selectedReference, current.identityKey == detailed.identityKey else { return }
                configureRemoteMetadata(current)
                if (current.remotePreview?.fidelity ?? .none) > stageFidelity { loadRemotePreview(current) }
            } catch is CancellationError { return }
            catch { self?.logger.error("\(reference.providerName, privacy: .public) detail failed: \(error.localizedDescription, privacy: .public)") }
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
        case .remote(let ref)?:
            title = ref.displayTitle
            if ref.provider == .cma {
                let provenance = ref.cmaProvenance(preferring: creatorLevel?.cmaCreatorID)
                switch ref.cmaKind {
                case .thumbnailOnly?: detail = [provenance, "No high-resolution JPEG"].joined(separator: " · ")
                case .metadataOnly?, nil: detail = [provenance, "View on Cleveland Museum of Art"].joined(separator: " · ")
                case .settable?: detail = provenance
                }
            } else if ref.provider?.isCatalog == true {
                let size = ref.width > 0 && ref.height > 0 ? WallpaperShape.summary(width: ref.width, height: ref.height) : nil
                detail = [size, ref.licenseDescription, ref.isBrowseOnly ? "View at source" : nil].compactMap { $0 }.joined(separator: " · ")
            } else {
                detail = ([WallpaperShape.summary(width: ref.width, height: ref.height)] + (ref.provider == .openverse ? [ref.licenseIsConsistent ? ref.licenseDescription ?? "" : "License unconfirmed"] : []))
                    .joined(separator: " · ")
            }
        }
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium),
            .foregroundColor: selectedItem == nil ? Theme.inkSecondary : Theme.inkPrimary])
        if !detail.isEmpty {
            text.append(NSAttributedString(string: "  " + detail, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
                .foregroundColor: NSColor.secondaryText]))
        }
        // Attributed text carries its own paragraph style: without tail truncation it wraps and clips to its first word.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        selectionLabel.attributedStringValue = text
        selectionLabel.toolTip = title + (detail.isEmpty ? "" : " — " + detail)
        let isFavorite = selectedReference.map(state.isFavorite) ?? false
        favoriteButton.image = NSImage(systemSymbolName: isFavorite ? "heart.fill" : "heart",
                                       accessibilityDescription: isFavorite ? "Remove from Favorites" : "Add to Favorites")
        favoriteButton.contentTintColor = isFavorite ? Theme.accentText : Theme.inkSecondary
        favoriteButton.toolTip = isFavorite ? "Remove from Favorites (⌘D)" : "Add to Favorites (⌘D)"
        favoriteButton.setAccessibilityLabel(isFavorite ? "Remove from Favorites" : "Add to Favorites")
    }

    // MARK: - Gallery / desktop preview mode

    @objc func toggleViewer(_ sender: Any?) { setViewerVisible(!isViewerVisible) }

    @objc private func viewModeChanged(_ sender: NSSegmentedControl) { setViewerVisible(sender.selectedSegment == 1) }

    private func setViewerVisible(_ visible: Bool) {
        guard !visible || selectedItem != nil else { viewModeControl.selectedSegment = 0; NSSound.beep(); return }
        // A work that can only be browsed has no desktop preview; say why rather than showing an empty stage.
        if visible, let reference = selectedReference, reference.isBrowseOnly {
            if reference.provider?.isCatalog == true {
                viewModeControl.selectedSegment = 0
                showStatus(reference.useRestriction?.errorDescription ?? "", isError: false)
                return
            }
            viewModeControl.selectedSegment = 0; NSSound.beep()
            showStatus(reference.cmaKind == .thumbnailOnly ? "No high-resolution JPEG, so there’s no desktop preview. View it on the Cleveland Museum of Art instead."
                       : "No image to preview. View it on the Cleveland Museum of Art instead.", isError: false)
            return
        }
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
        // The preview's caption band names the work, so the control row doesn't repeat it.
        selectionLabel.isHidden = showViewer
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
        defaults.set(index, forKey: "GalleryThumbnailSize")
        collectionView.reloadData()
        if let index = selectedIndex {
            collectionView.selectionIndexPaths = [IndexPath(item: index, section: 0)]
            collectionView.scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: .nearestVerticalEdge)
        }
    }

    // MARK: - Favorites and collections

    @objc func toggleFavorite(_ sender: Any?) {
        guard let ref = selectedReference, !ref.isBrowseOnly else { return }
        if let index = state.favorites.firstIndex(where: { $0.identityKey == ref.identityKey }) {
            return setMembership(ref, in: .favorites, at: index, member: false)
        }
        setMembership(ref, in: .favorites, at: state.favorites.count, member: true, addition: true)
    }

    @objc func addToCollection(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let ref = selectedReference, !ref.isBrowseOnly,
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
        showStatus(member ? "\(addition ? "Added" : "Restored") \(ref.displayTitle) to \(name)." : "Removed \(ref.displayTitle) from \(name).", isError: false)
    }

    /// Adds dropped wallpapers (by identity) to Favorites or a collection.
    private func collect(_ identities: [String], into target: SidebarItem) -> Bool {
        let known = remoteResults + (creatorLevel?.results ?? []) + state.favorites + state.collections.flatMap(\.wallpapers)
        let references = identities.compactMap { identity in known.first { $0.identityKey == identity } }.filter { !$0.isBrowseOnly }
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
        showStatus("Added \(adding.count == 1 ? adding[0].displayTitle : "\(adding.count) wallpapers") to \(name).", isError: false)
        return true
    }

    @objc func openSourcePage(_ sender: Any?) {
        switch selectedItem {
        case .remote(let ref)?:
            guard let url = browsableSourceURL(ref) else { NSSound.beep(); showStatus("This wallpaper’s source page isn’t on a known host for its source.", isError: true); return }
            urlOpener(url)
        case .local(let url)?: NSWorkspace.shared.activateFileViewerSelecting([url])
        case nil:
            guard state.currentSource == .discover, let url = CatalogLibrary.endpoint(for: state.discoverProvider) else {
                NSSound.beep()
                return
            }
            urlOpener(url)
        }
    }

    /// Wallhaven pages as before; an Openverse source page only on its source's known landing host.
    private func browsableSourceURL(_ ref: WallpaperReference) -> URL? {
        switch ref.provider {
        case .wallhaven?: return ref.sourcePageURL
        case .openverse?: return OpenverseURLPolicy.isAllowedLandingURL(ref.sourcePageURL, source: ref.sourceName) ? ref.sourcePageURL : nil
        case .cma?: return ref.cmaPageURL
        case nil: return nil
        default: return CatalogLibrary.sourcePage(for: ref)
        }
    }

    /// Only a canonical deed that matches the reported license is opened.
    @objc func openLicense(_ sender: Any?) {
        guard let ref = selectedReference else { NSSound.beep(); return }
        let url = ref.provider?.isCatalog == true ? CatalogLibrary.licensePage(for: ref)
            : (ref.licenseIsConsistent ? ref.licenseURL : nil)
        guard let url else { NSSound.beep(); return }
        urlOpener(url)
    }

    @objc func copy(_ sender: Any?) {
        guard let item = selectedItem else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch item {
        case .remote(let ref): if let url = browsableSourceURL(ref) { pasteboard.writeObjects([url as NSURL]) }
        case .local(let url): pasteboard.writeObjects([url as NSURL])
        }
    }

    @objc func createCollection(_ sender: Any?) {
        // From an item's menu, the new collection starts with that wallpaper.
        let adding = (sender as? NSMenuItem)?.representedObject as? String == "withSelection" ? selectedReference.flatMap { ref -> WallpaperReference? in ref.isBrowseOnly ? nil : ref } : nil
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
        func catalog(_ id: RemoteProviderID, _ symbol: String) -> SidebarNode {
            SidebarNode(.catalog(id), title: id.displayName, symbolName: symbol)
        }
        // All nine sources, each in exactly one group.
        let wallpapers = [
            SidebarNode(.discover, title: RemoteProviderID.wallhaven.displayName, symbolName: "globe"),
            catalog(.plasma, "desktopcomputer"), catalog(.pepper, "paintbrush")
        ]
        let museums = [
            SidebarNode(.cma, title: RemoteProviderID.cma.displayName, symbolName: "building.columns"),
            catalog(.met, "building.columns"), catalog(.wellcome, "books.vertical")
        ]
        let photography = [
            SidebarNode(.openverse, title: RemoteProviderID.openverse.displayName, symbolName: "camera"),
            catalog(.inaturalist, "leaf"), catalog(.nasa, "sparkles")
        ]
        let library = [
            SidebarNode(.favorites, title: "Favorites", symbolName: "heart", count: state.favorites.count),
            SidebarNode(.local, title: folderName ?? "Folder", symbolName: "folder",
                        count: state.folderPath == nil || isLoadingFolder ? nil : localURLs.count,
                        isRotating: rotating && state.activeRotationCollectionID == nil)
        ]
        let collections = state.collections.map {
            SidebarNode(.collection($0.id), title: $0.name, symbolName: "rectangle.stack", count: $0.wallpapers.count,
                        isRotating: rotating && state.activeRotationCollectionID == $0.id)
        }
        // The user's own library first, with `+` in the Collections header; then the sources, grouped.
        let groups = [
            SidebarNode(group: "Library", children: library),
            SidebarNode(group: "Collections", children: collections, hasAddButton: true),
            SidebarNode(group: "Museums & Archives", children: museums),
            SidebarNode(group: "Photography & Space", children: photography),
            SidebarNode(group: "Wallpapers & Digital", children: wallpapers)
        ]
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
                    await applyWallpaper(try await historyStore.retain(url), to: screen, scaling: scaling, source: .rotation)
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
        let source = state.discoverProvider
        [categoryPopUp, resolutionPopUp, aspectPopUp, sortingPopUp].forEach { $0.isHidden = source != .wallhaven }
        [openverseLicensePopUp, openverseNoticeLabel].forEach { $0.isHidden = source != .openverse }
        cmaNoticeLabel.isHidden = source != .cma
        // Blank browsing lists open-access works with images; typed text searches all public records.
        cmaNoticeLabel.stringValue = state.cmaSearch.trimmedQuery.isEmpty
            ? "Open-access (CC0) works with images from the Cleveland Museum of Art."
            : "Public records from the Cleveland Museum of Art. Only open-access works with images can be previewed or set."
        // The notice may truncate in a narrow bar; its whole text is the tooltip (and the accessibility value).
        cmaNoticeLabel.toolTip = cmaNoticeLabel.stringValue
        // The creator view's header stands in for the bar of whatever it covers.
        updateCreatorBar()
        let creatorShown = creatorLevel != nil
        discoverBar.isHidden = state.currentSource != .discover || creatorShown
        localBar.isHidden = state.currentSource != .local || state.folderPath == nil || creatorShown
        creatorBar.isHidden = !creatorShown
        scopeBar.isHidden = (discoverBar.isHidden && localBar.isHidden && creatorBar.isHidden) || !viewerView.isHidden
        // Hidden bars leave layout by anchoring the gallery to the titlebar instead, never by pinning a zero height.
        guard galleryArea.superview === contentRoot else { return }
        if scopeBar.isHidden {
            galleryBelowScopeBar.isActive = false; galleryAtTop.isActive = true
        } else {
            galleryAtTop.isActive = false; galleryBelowScopeBar.isActive = true
        }
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
        if let level = creatorLevel {
            // The header in the content names the creator; the toolbar keeps naming the source.
            window.title = level.provider.displayName
            window.subtitle = level.phase == .loaded ? (level.allOpenAccess ? "Open-access works" : "Works on record") : ""
            return
        }
        let count = currentItems.count
        let wallpapers = count == 1 ? "1 wallpaper" : "\(count.formatted()) wallpapers"
        switch state.currentSource {
        case .discover:
            window.title = "Discover"
            // Names the request the results came from, which the edited controls may no longer describe.
            window.subtitle = totalResults > 0 ? "\(resultOptions?.resultsDescription ?? "Results") on \(discoverName) · \(remoteResults.count.formatted()) of \(totalResults.formatted())" : ""
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
        let wallhaven = state.wallhavenSearch, draft = draftQuery
        sortingPopUp.toolTip = wallhaven.effectiveSorting == wallhaven.sorting ? "Sort order"
            : "Without search text Wallhaven has no relevance order, so Discover shows this month’s top wallpapers."
        var note: String?
        if let applied = resultOptions, !remoteResults.isEmpty,
           draft.provider.isCatalog ? applied != draft : applied.firstPageURL != draft.firstPageURL {
            if applied.trimmedQuery != draft.trimmedQuery { note = "Showing \(applied.resultsDescription)" }
            else if applied.minimumResolution != draft.minimumResolution, draft.provider == .wallhaven, wallhaven.usesDisplayMinimum { note = "Showing results for the previous display size" }
            else { note = "Showing results for earlier filters" }
        }
        pendingSearchLabel.stringValue = note ?? ""
        pendingSearchLabel.toolTip = note.map { "\($0). Press Return in the search field or click Update Results to search with the current settings." }
        pendingSearchLabel.isHidden = note == nil
        updateResultsButton.isHidden = note == nil
        let emptyQueryTip: String
        switch draft.provider {
        case .wallhaven: emptyQueryTip = "Show \(wallhaven.effectiveSorting.displayName) on Wallhaven"
        case .openverse: emptyQueryTip = "Show Wikimedia Commons images on Openverse"
        case .cma: emptyQueryTip = "Show open-access works at the Cleveland Museum of Art"
        default: emptyQueryTip = "Browse \(discoverName)"
        }
        updateResultsButton.toolTip = draft.trimmedQuery.isEmpty ? emptyQueryTip : "Search \(discoverName) for “\(draft.trimmedQuery)”"
    }

    private func updateEmptyAndPagination() {
        updateWindowTitle()
        defer { updateContentVisibility() }
        guard currentItems.isEmpty else { emptyStateView.isHidden = true; return }
        if let level = creatorLevel {
            let museum = level.provider.displayName
            switch level.phase {
            case .loading:
                emptyStateView.show(symbolName: nil, title: "Loading open-access works from \(museum)…", message: "")
            case .failed(let message):
                emptyStateView.show(symbolName: "exclamationmark.triangle", title: "Couldn’t load works from \(museum).", message: message,
                                    action: ("Retry", #selector(retryCreator(_:)), self))
            case .loaded:
                emptyStateView.show(symbolName: "photo.on.rectangle", title: "No other open-access works available in \(museum).", message: "")
            }
            return
        }
        switch state.currentSource {
        case .discover:
            if isSearching {
                emptyStateView.show(symbolName: nil, title: "Searching \(discoverName)…", message: "")
            } else if let searchErrorText {
                let offline = searchErrorText.contains("offline") || searchErrorText.contains("reach \(discoverName)")
                emptyStateView.show(symbolName: offline ? "wifi.exclamationmark" : "exclamationmark.triangle",
                                    title: "Couldn’t Load Wallpapers", message: searchErrorText,
                                    action: ("Try Again", #selector(search(_:)), self))
            } else if resultOptions == nil || resultOptions != draftQuery {
                let prompt: String
                switch state.discoverProvider {
                case .wallhaven: prompt = "Press Return in the search field to see safe-for-work wallpapers."
                case .openverse: prompt = "Press Return in the search field to find openly licensed Wikimedia Commons images."
                case .cma: prompt = "Press Return in the search field to search the Cleveland Museum of Art’s public records."
                default: prompt = "Press Return in the search field to update results from \(discoverName)."
                }
                emptyStateView.show(symbolName: "magnifyingglass", title: "Search \(discoverName)", message: prompt)
            } else if state.discoverProvider == .cma {
                let hidden = hiddenResults == 0 ? "" : " \(hiddenResults) result\(hiddenResults == 1 ? " was" : "s were") hidden because the image host or links couldn’t be verified."
                emptyStateView.show(symbolName: "magnifyingglass", title: "No Results",
                                    message: (state.cmaSearch.trimmedQuery.isEmpty ? "No open-access works with images were listed by the Cleveland Museum of Art."
                                              : "No public records at the Cleveland Museum of Art matched.") + hidden)
            } else if state.discoverProvider == .openverse {
                // Truthful: Wallpier never broadens the license or content filters to fill the page.
                let hidden = hiddenResults == 0 ? "" : " \(hiddenResults) result\(hiddenResults == 1 ? " was" : "s were") hidden because the image host, license or links couldn’t be verified."
                if hasUnloadedResults {
                    emptyStateView.show(symbolName: "magnifyingglass", title: "No Verifiable Results Yet",
                                        message: "Nothing on the pages loaded so far could be shown." + hidden + " Openverse has more pages.",
                                        action: ("Load More", #selector(loadMoreResults(_:)), self))
                } else {
                    emptyStateView.show(symbolName: "magnifyingglass", title: "No Results",
                                        message: "No wide, large Wikimedia Commons JPEGs with this public-domain license matched on Openverse." + hidden)
                }
            } else if state.discoverProvider.isCatalog {
                if hasUnloadedResults {
                    emptyStateView.show(symbolName: "magnifyingglass", title: "No Verifiable Results Yet",
                                        message: "\(discoverName) has more pages.",
                                        action: ("Load More", #selector(loadMoreResults(_:)), self))
                } else {
                    emptyStateView.show(symbolName: "magnifyingglass", title: "No Results",
                                        message: "No eligible images from \(discoverName) matched.")
                }
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
                                message: "Click the heart or press ⌘D on any wallpaper in Discover to keep it here.",
                                action: ("Browse Discover", #selector(showDiscover(_:)), self))
        case .collections:
            if let collection = selectedCollection {
                emptyStateView.show(symbolName: "rectangle.stack", title: "“\(collection.name)” Is Empty",
                                    message: "Drag wallpapers onto this collection in the sidebar, or choose Add to Collection.")
            } else {
                emptyStateView.show(symbolName: "rectangle.stack", title: "No Collections",
                                    message: "Collections keep wallpapers from Wallhaven and Openverse together, and can be used for automatic rotation.",
                                    action: ("New Collection…", #selector(createCollection(_:)), self))
            }
        }
    }

    private func updateControlAvailability() {
        let canMutate = downloadTask == nil && rotationTask == nil
        let hasSelection = selectedItem != nil
        let blocked = selectedReference?.blocksUse == true
        setWallpaperButton.isEnabled = hasSelection && selectedScreen != nil && canMutate && !blocked
        setWallpaperButton.toolTip = selectedReference?.useRestriction?.errorDescription
        reviewSourceButton.isHidden = !(selectedReference.map { $0.provider == .openverse && $0.blocksUse } ?? false)
        reviewSourceButton.toolTip = selectedReference?.useRestriction?.errorDescription
        // Wallhaven pages load as the grid scrolls; Openverse and the museum load a page on request.
        loadMoreButton.isHidden = !(state.discoverProvider != .wallhaven && hasUnloadedResults && !currentItems.isEmpty)
        loadMoreButton.isEnabled = canLoadMoreResults
        loadMoreButton.toolTip = "Load the next page of \(discoverName) results"
        undoButton.isEnabled = canUndoWallpaper && canMutate
        undoButton.toolTip = canUndoWallpaper ? "Undo Wallpaper Change" : "No restorable wallpaper change"
        statusUndoButton.isEnabled = canUndoWallpaper && canMutate
        if let creator = pivotCreator {
            moreByButton.title = "More by \(creator.name)"
            moreByButton.setAccessibilityLabel("More by \(creator.name)")
            moreByButton.toolTip = "Show works from \(selectedReference?.providerName ?? discoverName) credited to \(creator.name)"
        }
        viewOnMuseumButton.isHidden = selectedReference?.isBrowseOnly != true
        if let reference = selectedReference, reference.isBrowseOnly {
            viewOnMuseumButton.setAccessibilityLabel("View on \(reference.providerName)")
            viewOnMuseumButton.toolTip = "View on \(reference.providerName)"   // The label truncates in a narrow dock.
        }
        updateDockShortcutsForWidth()
        favoriteButton.isHidden = selectedReference == nil || selectedReference?.isBrowseOnly == true
        collectionButton.isHidden = favoriteButton.isHidden   // Browse-only works can't be collected either.
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
        rotationButton.contentTintColor = rotating ? Theme.accentText : nil
        rotationButton.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                                       accessibilityDescription: rotating ? "Automatic Rotation On" : "Automatic Rotation")
        rotationButton.toolTip = rotating ? "Automatic rotation: \(rotationTitle(state.rotationInterval).lowercased()) from \(rotationSourceName)" : "Automatic Rotation"
        rotationSummaryLabel.stringValue = rotationSummary
    }

    private func friendlyMessage(for error: Error, source: String? = nil) -> String {
        let source = source ?? discoverName
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost: return "You appear to be offline. Check your connection and try again."
            case .timedOut: return "\(source) took too long to respond. Try again."
            case .cancelled: return "The request was cancelled."
            default: return "Could not reach \(source). \(urlError.localizedDescription)"
            }
        }
        return error.localizedDescription
    }

    /// Informational messages fade after a few seconds; errors and in-progress work stay.
    private func showStatus(_ text: String, isError: Bool, offersUndo: Bool = false) {
        statusClearTask?.cancel()
        if !isError, !text.isEmpty {
            statusClearTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard let self, !Task.isCancelled, statusLabel.stringValue == text, downloadTask == nil, rotationTask == nil else { return }
                showStatus("", isError: false)
            }
        }
        statusUndoButton.isHidden = !offersUndo || text.isEmpty
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? Theme.statusError : .secondaryText
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
        Choose a Discover source in the sidebar and use the search field to search it. KDE Plasma and Pepper&Carrot \
        filter smaller published wallpaper collections. Favorites and collections can keep wallpapers from different sources together.

        Openverse results are wide, large, non-mature Wikimedia Commons JPEGs reported as CC0 or public domain. Wallpier shows each \
        one's creator, source and reported license; Openverse doesn't verify licenses, so review the source page before reuse.

        “More by” opens a creator’s works when the source identifies that creator. Click “Back to” or press Esc to return. \
        Works labeled for browsing open on their source site. The preview shows available credit and rights information.

        Select a wallpaper and press Space to preview it on your display’s shape; ← and → browse, Esc returns. \
        Set Wallpaper (Return) downloads only that original and applies it with the display and scaling shown beside it. \
        Undo Wallpaper Change, in the toolbar and Wallpaper menu, restores the previous wallpaper; \
        ⌘Z undoes removing a wallpaper from Favorites or a collection.

        Fit to Screen is the default for new installations. Existing scaling choices are preserved. \
        If your wallpapers are cropped, select Fit to Screen once; Wallpier remembers your choice.

        Drag wallpapers onto Favorites or a collection to keep them. The rotation button in the toolbar changes the wallpaper on a schedule while Wallpier is open.
        """

    static let shortcutsText = """
        Space — Preview on Desktop, or back to the gallery
        ← → — previous or next wallpaper (also ⌘[ and ⌘])
        Return — Set Wallpaper
        ⌘D — Add to or Remove from Favorites
        F — focus mode in the preview; Esc brings the details back
        Esc — leave the preview or an artist's works
        ⌘F — search the current source
        ⌘+ and ⌘− — larger or smaller thumbnails
        ⌃⌘S — show or hide the sidebar
        ⌥⌘R — Automatic Rotation settings
        ⇧⌘N — New Collection
        """

    @objc private func closeHelp(_ sender: NSButton) {
        guard let sheet = sender.window else { return }
        if let parent = sheet.sheetParent { parent.endSheet(sheet) } else { sheet.close() }
    }

    /// A scrollable help sheet: the same guidance as before, in the editorial type, with the keyboard shortcuts after it.
    @objc func showHelp(_ sender: Any?) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Wallpier Help"
        let text = NSMutableAttributedString()
        func add(_ string: String, font: NSFont, color: NSColor = Theme.inkPrimary, spacing: CGFloat = 8, before: CGFloat = 0,
                 tab: CGFloat? = nil) {
            let paragraph = NSMutableParagraphStyle(); paragraph.paragraphSpacing = spacing; paragraph.paragraphSpacingBefore = before
            paragraph.lineSpacing = 2
            if let tab {   // A hanging indent: keys in the first column, wrapped actions aligned under their own column.
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: tab)]
                paragraph.headIndent = tab
            }
            text.append(NSAttributedString(string: string + "\n", attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]))
        }
        // The same guidance as helpText, under four clear headings, then a compact shortcut table.
        let paragraphs = Self.helpText.components(separatedBy: "\n\n").map { $0.replacingOccurrences(of: "\n", with: " ") }
        let sections: [(String, [Int])] = [("Discover & Sources", [0, 1]), ("Artist Exploration", [2]),
                                           ("Desktop Preview & Fit", [3, 4]), ("Library & Rotation", [5])]
        add("Wallpier Help", font: Theme.serif(24), spacing: 4)
        for (heading, indices) in sections {
            add(heading, font: Theme.serif(17), spacing: 4, before: 10)
            for index in indices where paragraphs.indices.contains(index) { add(paragraphs[index], font: .systemFont(ofSize: 13)) }
        }
        add("Keyboard Shortcuts", font: Theme.serif(17), spacing: 4, before: 10)
        for line in Self.shortcutsText.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: " — ")
            guard parts.count == 2 else { continue }
            add(parts[0] + "\t" + parts[1], font: .systemFont(ofSize: 13), spacing: 3, tab: 96)
        }
        let scroll = NSTextView.scrollableTextView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        if let textView = scroll.documentView as? NSTextView {
            textView.isEditable = false
            textView.textContainerInset = NSSize(width: 20, height: 18)
            textView.drawsBackground = true
            textView.backgroundColor = Theme.canvas
            textView.textStorage?.setAttributedString(text)
        }
        let done = NSButton(title: "Done", target: self, action: #selector(closeHelp(_:)))
        done.keyEquivalent = "\r"
        done.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(scroll); content.addSubview(done)
        // A fixed, fully visible sheet: the scroll area fills it above the Done button, so nothing is clipped.
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 540), content.heightAnchor.constraint(equalToConstant: 580),
            scroll.topAnchor.constraint(equalTo: content.topAnchor), scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: done.topAnchor, constant: -12),
            done.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), done.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
        ])
        panel.contentView = content
        if let window { window.beginSheet(panel) } else { panel.center(); panel.makeKeyAndOrderFront(nil) }
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
            if let creator = pivotCreator { add("More by \(creator.name)", #selector(showCreator(_:))); menu.addItem(.separator()) }
            if creatorLevel != nil { add("Back to Gallery", #selector(closeCreator(_:))); menu.addItem(.separator()) }
            add(state.isFavorite(ref) ? "Remove from Favorites" : "Add to Favorites", #selector(toggleFavorite(_:)))
            let collections = NSMenuItem(title: "Add to Collection", action: nil, keyEquivalent: "")
            collections.submenu = NSMenu(title: "Add to Collection")
            populateCollectionMenu(collections.submenu!)
            menu.addItem(collections)
            if state.currentSource == .collections, let collection = selectedCollection {
                add("Remove from “\(collection.name)”", #selector(removeFromCollection(_:)))
            }
            menu.addItem(.separator())
            if ref.provider == .openverse, !ref.licenseIsConsistent { add("Review Original Source", #selector(openSourcePage(_:))) }
            else { add("Open on \(ref.sourceDisplayName)", #selector(openSourcePage(_:))) }
            if ref.licenseIsConsistent || CatalogLibrary.licensePage(for: ref) != nil {
                add("View License (\(ref.licenseDescription ?? ""))", #selector(openLicense(_:)))
            }
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

    @objc private func focusButtonClicked(_ sender: Any?) {
        window?.makeFirstResponder(viewerView)   // So Esc, which leaves focus mode, reaches the preview.
        setFocusMode(true)
    }

    /// The same Add to Collection choices as the Wallpaper menu, from the control row.
    @objc private func showCollectionMenu(_ sender: NSButton) {
        let menu = NSMenu(title: "Add to Collection")
        populateCollectionMenu(menu)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    /// Focus mode (F in the preview) hides the caption band and the control row so the stage has the whole window; Esc restores them.
    /// Hidden areas leave layout by swapping anchors, never by pinning a zero height.
    private func setFocusMode(_ focused: Bool) {
        guard focused == false || isViewerVisible else { return }
        isFocusMode = focused
        previewCaptionBand.isHidden = focused
        applyBar.isHidden = focused
        barSeparator.isHidden = focused
        guard galleryArea.superview === contentRoot else { return }
        if focused {
            stageAboveCaption.isActive = false; stageToBottom.isActive = true
            galleryAboveDock.isActive = false; galleryToBottom.isActive = true
        } else {
            stageToBottom.isActive = false; stageAboveCaption.isActive = true
            galleryToBottom.isActive = false; galleryAboveDock.isActive = true
        }
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
        case .discover, .openverse, .cma, .catalog: return nil
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
            return isViewerVisible || (selectedItem != nil && selectedItem?.isBrowseOnly != true)
        case #selector(showCreator(_:)):
            menuItem.title = pivotCreator.map { "More by \($0.name)" } ?? "More by Creator"
            return pivotCreator != nil
        case #selector(closeCreator(_:)): return creatorLevel != nil
        case #selector(makeThumbnailsLarger(_:)): return thumbnailSizeIndex < GalleryLayout.thumbnailWidths.count - 1
        case #selector(makeThumbnailsSmaller(_:)): return thumbnailSizeIndex > 0
        case #selector(setWallpaper(_:)): return selectedItem != nil && selectedScreen != nil && canMutate && selectedReference?.blocksUse != true
        case #selector(previousWallpaper(_:)): return canNavigate(-1)
        case #selector(nextWallpaper(_:)): return canNavigate(1)
        case #selector(undoWallpaperChange(_:)): return canUndoWallpaper && canMutate
        case #selector(toggleFavorite(_:)):
            menuItem.title = selectedReference.map(state.isFavorite) == true ? "Remove from Favorites" : "Add to Favorites"
            return selectedReference != nil && selectedReference?.isBrowseOnly != true
        case #selector(openSourcePage(_:)):
            if menuItem.keyEquivalent == "o" {
                menuItem.title = selectedReference.map { "Open on \($0.sourceDisplayName)" } ?? (selectedItem != nil ? "Show in Finder" : "Open on \(discoverName)")
            }
            return selectedItem != nil || (state.currentSource == .discover && state.discoverProvider.isCatalog)
        case #selector(openLicense(_:)):
            guard let reference = selectedReference else { return false }
            return reference.provider?.isCatalog == true
                ? CatalogLibrary.licensePage(for: reference) != nil : reference.licenseIsConsistent
        case #selector(focusSearch(_:)): menuItem.title = "Search \(discoverName)"; return true
        case #selector(copy(_:)): return selectedItem != nil
        case #selector(addToCollection(_:)): return selectedReference != nil && selectedReference?.isBrowseOnly != true
        case #selector(createCollection(_:)):
            return menuItem.representedObject as? String != "withSelection" || (selectedReference != nil && selectedReference?.isBrowseOnly != true)
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
        case #selector(showWallhaven(_:)), #selector(showOpenverse(_:)), #selector(showCMA(_:)):
            let provider: RemoteProviderID = menuItem.action == #selector(showOpenverse(_:)) ? .openverse
                : menuItem.action == #selector(showCMA(_:)) ? .cma : .wallhaven
            menuItem.state = state.currentSource == .discover && state.discoverProvider == provider ? .on : .off; return true
        case #selector(showCatalog(_:)):
            menuItem.state = state.currentSource == .discover && state.discoverProvider.rawValue == (menuItem.representedObject as? String) ? .on : .off
            return true
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
        item.configure(identifier: represented.identifier, title: represented.title, toolTip: represented.toolTip,
                       subtitle: cellSubtitle(for: represented))
        // Decode at the cell's pixel size; switch to Wallhaven's larger thumbnail only when cells need it.
        let pixels = galleryLayout.fittedItemSize.width * (window?.backingScaleFactor ?? 2)
        let maximumPixelSize = Int(min(max(pixels, 360), 720))
        switch represented {
        case .local(let url):
            thumbnailProvider.requestThumbnail(for: url, maximumPixelSize: maximumPixelSize) { [weak item] image in
                guard (item?.representedObject as? String) == represented.identifier else { return }; item?.setThumbnail(image)
            }
        case .remote(let ref):
            // Browse-only museum works say so on their cell; a text-only record never asks for an image at all.
            switch ref.cmaKind {
            case .thumbnailOnly?: item.setCaption("No high-resolution JPEG", style: .badge)
            case .metadataOnly?:
                item.setCaption([ref.displayTitle, ref.cmaDateText, ref.cmaCredit(preferring: creatorLevel?.cmaCreatorID), "View on Cleveland Museum of Art ↗"]
                                    .compactMap { $0 }.joined(separator: "\n"), style: .text)
                return item
            case .settable?, nil: break
            }
            guard let url = ref.galleryThumbnailURL(large: pixels > 340) else { item.setThumbnail(nil); return item }
            remoteThumbnailProvider.requestThumbnail(for: url, maximumPixelSize: maximumPixelSize) { [weak item] image in
                guard (item?.representedObject as? String) == represented.identifier else { return }; item?.setThumbnail(image)
            }
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> NSSize { galleryLayout.fittedItemSize }

    /// Leftover pixels from the whole-number column count go into the outer margins.
    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
                        insetForSectionAt section: Int) -> NSEdgeInsets { galleryLayout.fittedSectionInset }

    /// The cell's second line: maker · date, or maker · source where a list mixes sources. Only what the record reports.
    private func cellSubtitle(for item: BrowserItem) -> String {
        switch item {
        case .local(let url): return url.pathExtension.uppercased()
        case .remote(let ref):
            let maker = ref.provider == .cma ? ref.cmaCredit(preferring: creatorLevel?.cmaCreatorID) : ref.displayCreator
            let mixed = (state.currentSource == .favorites || state.currentSource == .collections) && creatorLevel == nil
            let tail = mixed ? ref.providerName : ref.cmaDateText
            let parts = [maker, tail].compactMap { $0 }.filter { !$0.isEmpty }
            return parts.isEmpty ? ref.providerName : parts.joined(separator: " · ")
        }
    }

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
            // A work that can only be browsed can't be dragged into Favorites or a collection.
            if ref.isBrowseOnly { return nil }
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
