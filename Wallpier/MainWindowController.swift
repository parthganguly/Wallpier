import AppKit
import os.log

private final class PreviewDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class MainWindowController: NSWindowController, NSCollectionViewDataSource,
    NSCollectionViewDelegate, NSMenuItemValidation, NSSearchFieldDelegate {

    private enum SetSource { case user, rotation }
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
        var toolTip: String {
            switch self {
            case .local(let url): return url.path
            case .remote(let ref): return "Wallhaven \(ref.wallpaperID) — \(ref.resolution)"
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
    private var rotationTimer: Timer?
    private(set) var searchTask: Task<Void, Never>?
    private(set) var detailTask: Task<Void, Never>?
    private(set) var downloadTask: Task<Void, Never>?
    private(set) var rotationTask: Task<Void, Never>?
    private var isSearching = false
    private var searchGeneration = UUID()
    private var resultOptions: WallhavenSearchOptions?

    private let sourcePicker = NSSegmentedControl(labels: LibrarySource.allCases.map(\.displayName), trackingMode: .selectOne, target: nil, action: nil)
    let searchField = NSSearchField()
    private let categoryPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let resolutionPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let aspectPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sortingPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let searchButton = NSButton(title: "Search", target: nil, action: nil)
    private let chooseFolderButton = NSButton(title: "Choose Folder…", target: nil, action: nil)
    private let folderPathLabel = NSTextField(labelWithString: "No folder selected")
    private let imageCountLabel = NSTextField(labelWithString: "")
    private let collectionPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let newCollectionButton = NSButton(title: "New…", target: nil, action: nil)
    private let renameCollectionButton = NSButton(title: "Rename…", target: nil, action: nil)
    private let deleteCollectionButton = NSButton(title: "Delete", target: nil, action: nil)
    private let sourceSummaryLabel = NSTextField(labelWithString: "")
    private let discoverControls = NSStackView()
    private let localControls = NSStackView()
    private let favoritesControls = NSStackView()
    private let collectionsControls = NSStackView()

    private let emptyStateLabel = NSTextField(wrappingLabelWithString: "Search Wallhaven to discover wallpapers.")
    private let progressIndicator = NSProgressIndicator()
    private let loadMoreButton = NSButton(title: "Load More", target: nil, action: nil)
    private let resultCountLabel = NSTextField(labelWithString: "")
    let previewImageView = NSImageView()
    let previewTitleLabel = NSTextField(labelWithString: "No wallpaper selected")
    let previewMetadataLabel = NSTextField(wrappingLabelWithString: "Select a wallpaper to preview it.")
    private let previewTagsLabel = NSTextField(wrappingLabelWithString: "")
    private let favoriteButton = NSButton(title: "Add to Favorites", target: nil, action: nil)
    private let addToCollectionPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let removeFromCollectionButton = NSButton(title: "Remove from Collection", target: nil, action: nil)
    private let openSourceButton = NSButton(title: "Open on Wallhaven", target: nil, action: nil)
    let displayPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let scalingPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let setWallpaperButton = NSButton(title: "Set Wallpaper", target: nil, action: nil)
    private let rotationSourcePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let rotationPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let shuffleButton = NSButton(checkboxWithTitle: "Shuffle", target: nil, action: nil)
    private let previousButton = NSButton(title: "Previous", target: nil, action: nil)
    private let nextButton = NSButton(title: "Next", target: nil, action: nil)
    let undoButton = NSButton(title: "Undo", target: nil, action: nil)
    let statusLabel = NSTextField(wrappingLabelWithString: "Ready.")

    private lazy var collectionView: NSCollectionView = {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 184, height: 144)
        layout.sectionInset = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 12
        let view = NSCollectionView()
        view.collectionViewLayout = layout
        view.dataSource = self
        view.delegate = self
        view.isSelectable = true
        view.allowsMultipleSelection = false
        view.allowsEmptySelection = true
        view.register(WallpaperCollectionViewItem.self, forItemWithIdentifier: WallpaperCollectionViewItem.reuseIdentifier)
        view.setAccessibilityLabel("Wallpaper browser")
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

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Wallpier"
        window.minSize = NSSize(width: 860, height: 560)
        if !window.setFrameUsingName("WallpierMainWindow") { window.center() }
        window.setFrameAutosaveName("WallpierMainWindow")
        self.init(window: window, wallpaperService: WallpaperService(), stateStore: WallpaperStateStore(),
                  provider: WallhavenProvider(), originalCache: RemoteWallpaperCache(),
                  historyStore: WallpaperHistoryStore(), remoteThumbnailProvider: RemoteThumbnailProvider(),
                  availableScreens: { NSScreen.screens })
        configureUI()
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
        NotificationCenter.default.removeObserver(self)
    }

    private func configureUI() {
        guard let contentView = window?.contentView else { return }
        sourcePicker.target = self
        sourcePicker.action = #selector(sourceChanged)
        sourcePicker.setAccessibilityLabel("Wallpaper source")
        configureSourceControls()

        let controlHost = NSStackView(views: [discoverControls, localControls, favoritesControls, collectionsControls])
        controlHost.orientation = .vertical
        controlHost.spacing = 0
        controlHost.detachesHiddenViews = true

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .controlBackgroundColor
        scroll.documentView = collectionView
        let browserContainer = NSView()
        browserContainer.addSubview(scroll)
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.alignment = .center
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.font = .systemFont(ofSize: 15)
        browserContainer.addSubview(emptyStateLabel)
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.style = .spinning
        progressIndicator.isDisplayedWhenStopped = false
        browserContainer.addSubview(progressIndicator)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: browserContainer.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: browserContainer.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: browserContainer.topAnchor), scroll.bottomAnchor.constraint(equalTo: browserContainer.bottomAnchor),
            emptyStateLabel.centerXAnchor.constraint(equalTo: browserContainer.centerXAnchor), emptyStateLabel.centerYAnchor.constraint(equalTo: browserContainer.centerYAnchor, constant: 12),
            emptyStateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: browserContainer.leadingAnchor, constant: 30), emptyStateLabel.trailingAnchor.constraint(lessThanOrEqualTo: browserContainer.trailingAnchor, constant: -30),
            progressIndicator.centerXAnchor.constraint(equalTo: browserContainer.centerXAnchor), progressIndicator.bottomAnchor.constraint(equalTo: emptyStateLabel.topAnchor, constant: -12)
        ])
        loadMoreButton.target = self
        loadMoreButton.action = #selector(loadMore(_:))
        resultCountLabel.textColor = .secondaryLabelColor
        let pageSpacer = NSView(); pageSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let pageRow = NSStackView(views: [resultCountLabel, pageSpacer, loadMoreButton])
        pageRow.orientation = .horizontal; pageRow.alignment = .centerY
        let browserColumn = NSStackView(views: [browserContainer, pageRow])
        browserColumn.orientation = .vertical; browserColumn.alignment = .leading; browserColumn.spacing = 8
        browserContainer.widthAnchor.constraint(equalTo: browserColumn.widthAnchor).isActive = true
        pageRow.widthAnchor.constraint(equalTo: browserColumn.widthAnchor).isActive = true
        browserContainer.setContentHuggingPriority(.defaultLow, for: .vertical)

        let previewPanel = makePreviewPanel()
        let split = NSSplitView()
        split.isVertical = true; split.dividerStyle = .thin
        split.addArrangedSubview(browserColumn); split.addArrangedSubview(previewPanel)
        previewPanel.widthAnchor.constraint(greaterThanOrEqualToConstant: 270).isActive = true
        previewPanel.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
        let footer = makeFooter()
        let separator = NSBox(); separator.boxType = .separator
        statusLabel.isSelectable = true; statusLabel.textColor = .secondaryLabelColor; statusLabel.maximumNumberOfLines = 2
        let root = NSStackView(views: [sourcePicker, controlHost, split, separator, footer, statusLabel])
        root.translatesAutoresizingMaskIntoConstraints = false
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 10
        contentView.addSubview(root)
        [sourcePicker, controlHost, split, separator, footer, statusLabel].forEach { $0.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        split.setContentHuggingPriority(.defaultLow, for: .vertical)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16), root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14), root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            split.heightAnchor.constraint(greaterThanOrEqualToConstant: 360)
        ])
    }

    private func configureSourceControls() {
        searchField.placeholderString = "Search Wallhaven"
        searchField.target = self; searchField.action = #selector(search(_:))
        searchField.delegate = self
        searchField.sendsWholeSearchString = true
        searchField.setAccessibilityHelp("Searches safe-for-work wallpapers on Wallhaven")
        categoryPopUp.addItems(withTitles: WallhavenCategory.allCases.map(\.displayName))
        aspectPopUp.addItems(withTitles: WallhavenAspectRatio.allCases.map(\.displayName))
        sortingPopUp.addItems(withTitles: WallhavenSorting.allCases.map(\.displayName))
        resolutionPopUp.addItems(withTitles: ["Selected Display", "Any Resolution", "1920×1080+", "2560×1440+", "3840×2160+"])
        for popup in [categoryPopUp, resolutionPopUp, aspectPopUp, sortingPopUp] {
            popup.target = self; popup.action = #selector(searchOptionChanged(_:))
        }
        searchButton.target = self; searchButton.action = #selector(search(_:))
        discoverControls.setViews([searchField, categoryPopUp, resolutionPopUp, aspectPopUp, sortingPopUp, searchButton], in: .leading)
        discoverControls.orientation = .horizontal; discoverControls.alignment = .centerY; discoverControls.spacing = 8
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        chooseFolderButton.target = self; chooseFolderButton.action = #selector(chooseFolder(_:))
        chooseFolderButton.setAccessibilityHelp("Choose a folder containing JPEG, PNG, or HEIC wallpapers")
        folderPathLabel.lineBreakMode = .byTruncatingMiddle; folderPathLabel.isSelectable = true; folderPathLabel.textColor = .secondaryLabelColor
        folderPathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageCountLabel.textColor = .secondaryLabelColor
        localControls.setViews([chooseFolderButton, folderPathLabel, imageCountLabel], in: .leading)
        localControls.orientation = .horizontal; localControls.alignment = .centerY; localControls.spacing = 10
        sourceSummaryLabel.textColor = .secondaryLabelColor
        favoritesControls.setViews([sourceSummaryLabel], in: .leading); favoritesControls.orientation = .horizontal

        collectionPopUp.target = self; collectionPopUp.action = #selector(collectionSelectionChanged)
        newCollectionButton.target = self; newCollectionButton.action = #selector(createCollection(_:))
        renameCollectionButton.target = self; renameCollectionButton.action = #selector(renameCollection(_:))
        deleteCollectionButton.target = self; deleteCollectionButton.action = #selector(deleteCollection(_:))
        collectionsControls.setViews([collectionPopUp, newCollectionButton, renameCollectionButton, deleteCollectionButton], in: .leading)
        collectionsControls.orientation = .horizontal; collectionsControls.alignment = .centerY; collectionsControls.spacing = 8
    }

    private func makePreviewPanel() -> NSView {
        let panel = PreviewDocumentView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = panel
        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.imageAlignment = .alignCenter
        previewImageView.imageFrameStyle = .grayBezel
        previewImageView.setAccessibilityLabel("Wallpaper preview")
        previewTitleLabel.font = .boldSystemFont(ofSize: 15); previewTitleLabel.lineBreakMode = .byTruncatingMiddle
        previewMetadataLabel.textColor = .secondaryLabelColor; previewMetadataLabel.maximumNumberOfLines = 3
        previewTagsLabel.textColor = .tertiaryLabelColor; previewTagsLabel.maximumNumberOfLines = 3
        favoriteButton.target = self; favoriteButton.action = #selector(toggleFavorite(_:))
        addToCollectionPopUp.target = self; addToCollectionPopUp.action = #selector(addToCollection(_:))
        removeFromCollectionButton.target = self; removeFromCollectionButton.action = #selector(removeFromCollection(_:))
        openSourceButton.target = self; openSourceButton.action = #selector(openSourcePage(_:))
        displayPopUp.target = self; displayPopUp.action = #selector(displaySelectionChanged); displayPopUp.setAccessibilityLabel("Display")
        scalingPopUp.addItems(withTitles: ScalingMode.allCases.map(\.displayName))
        scalingPopUp.target = self; scalingPopUp.action = #selector(scalingSelectionChanged); scalingPopUp.setAccessibilityLabel("Scaling")
        setWallpaperButton.target = self; setWallpaperButton.action = #selector(setWallpaper(_:)); setWallpaperButton.keyEquivalent = "\r"
        setWallpaperButton.setAccessibilityHelp("Downloads the original if needed and sets it on the selected display")
        let displayLabel = NSTextField(labelWithString: "Display")
        let scalingLabel = NSTextField(labelWithString: "Scaling")
        displayLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize); scalingLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let views: [NSView] = [previewImageView, previewTitleLabel, previewMetadataLabel, previewTagsLabel, favoriteButton, addToCollectionPopUp, removeFromCollectionButton, openSourceButton, displayLabel, displayPopUp, scalingLabel, scalingPopUp, setWallpaperButton]
        let stack = NSStackView(views: views)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 7
        panel.addSubview(stack)
        [previewImageView, previewTitleLabel, previewMetadataLabel, previewTagsLabel, favoriteButton, addToCollectionPopUp, removeFromCollectionButton, openSourceButton, displayPopUp, scalingPopUp, setWallpaperButton].forEach {
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14), stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 4), stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -8),
            panel.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            previewImageView.heightAnchor.constraint(equalToConstant: 210)
        ])
        return scroll
    }

    private func makeFooter() -> NSView {
        previousButton.target = self; previousButton.action = #selector(previousWallpaper(_:))
        nextButton.target = self; nextButton.action = #selector(nextWallpaper(_:))
        rotationSourcePopUp.target = self; rotationSourcePopUp.action = #selector(rotationSourceChanged)
        rotationPopUp.addItems(withTitles: RotationInterval.allCases.map(\.displayName))
        rotationPopUp.target = self; rotationPopUp.action = #selector(rotationSelectionChanged)
        shuffleButton.target = self; shuffleButton.action = #selector(shuffleChanged)
        undoButton.target = self; undoButton.action = #selector(undoWallpaperChange(_:))
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [previousButton, nextButton, NSTextField(labelWithString: "Rotate"), rotationSourcePopUp, rotationPopUp, shuffleButton, spacer, undoButton])
        stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = 8
        return stack
    }

    private func restoreState() {
        sourcePicker.selectedSegment = LibrarySource.allCases.firstIndex(of: state.currentSource) ?? 0
        searchField.stringValue = state.wallhavenSearch.query
        categoryPopUp.selectItem(at: WallhavenCategory.allCases.firstIndex(of: state.wallhavenSearch.category) ?? 0)
        aspectPopUp.selectItem(at: WallhavenAspectRatio.allCases.firstIndex(of: state.wallhavenSearch.aspectRatio) ?? 0)
        sortingPopUp.selectItem(at: WallhavenSorting.allCases.firstIndex(of: state.wallhavenSearch.sorting) ?? 0)
        selectResolutionControl()
        scalingPopUp.selectItem(at: ScalingMode.allCases.firstIndex(of: state.scalingMode) ?? 0)
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
    private var selectedIndex: Int? {
        if let item = collectionView.selectionIndexPaths.first?.item, currentItems.indices.contains(item) { return item }
        switch state.currentSource {
        case .local:
            guard let path = state.selectedImagePath else { return nil }
            return currentItems.firstIndex { if case .local(let url) = $0 { return url.path == path }; return false }
        default:
            guard let identity = state.selectedRemoteIdentity else { return nil }
            return currentItems.firstIndex { $0.identifier == identity }
        }
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
        return ScalingMode.allCases.indices.contains(index) ? ScalingMode.allCases[index] : .fill
    }
    private var selectedRotationInterval: RotationInterval {
        let index = rotationPopUp.indexOfSelectedItem
        return RotationInterval.allCases.indices.contains(index) ? RotationInterval.allCases[index] : .off
    }

    @objc private func sourceChanged() {
        guard LibrarySource.allCases.indices.contains(sourcePicker.selectedSegment) else { return }
        searchTask?.cancel()
        searchGeneration = UUID()
        searchTask = nil
        isSearching = false
        progressIndicator.stopAnimation(nil)
        searchButton.isEnabled = true
        state.currentSource = LibrarySource.allCases[sourcePicker.selectedSegment]
        stateStore.save(state)
        remoteThumbnailProvider.reset(); detailTask?.cancel()
        updateSourceUI()
        if state.currentSource == .discover && remoteResults.isEmpty { performSearch(page: 1, appending: false) }
        else {
            reloadCurrentSource()
            showStatus("\(currentItems.count) wallpapers in \(state.currentSource.displayName).", isError: false)
        }
    }

    @objc func showDiscover(_ sender: Any?) { selectSource(.discover) }
    @objc func showLocal(_ sender: Any?) { selectSource(.local) }
    @objc func showFavorites(_ sender: Any?) { selectSource(.favorites) }
    @objc func showCollections(_ sender: Any?) { selectSource(.collections) }

    private func selectSource(_ source: LibrarySource) {
        sourcePicker.selectedSegment = LibrarySource.allCases.firstIndex(of: source) ?? 0
        sourceChanged()
    }

    @objc func focusSearch(_ sender: Any?) {
        sourcePicker.selectedSegment = LibrarySource.allCases.firstIndex(of: .discover) ?? 0
        if state.currentSource != .discover { sourceChanged() }
        window?.makeFirstResponder(searchField)
    }

    @objc func search(_ sender: Any?) {
        if state.currentSource != .discover {
            sourcePicker.selectedSegment = LibrarySource.allCases.firstIndex(of: .discover) ?? 0
            state.currentSource = .discover; updateSourceUI()
        }
        persistSearchOptions(); performSearch(page: 1, appending: false)
    }

    @objc private func searchOptionChanged(_ sender: Any?) {
        persistSearchOptions()
        invalidateSearch()
        showStatus("Search filters updated. Choose Search to apply them.", isError: false)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === searchField else { return }
        persistSearchOptions()
        invalidateSearch()
    }

    private func invalidateSearch() {
        searchTask?.cancel()
        searchGeneration = UUID()
        isSearching = false
        progressIndicator.stopAnimation(nil)
        searchButton.isEnabled = true
        updateEmptyAndPagination()
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
        searchTask?.cancel(); detailTask?.cancel()
        let generation = UUID()
        searchGeneration = generation
        if !appending {
            remoteThumbnailProvider.reset()
            remoteResults = []
            currentPage = 0; lastPage = 0; totalResults = 0
            collectionView.reloadData()
            restoreSelection()
            updateControlAvailability()
        }
        isSearching = true; progressIndicator.startAnimation(nil)
        emptyStateLabel.stringValue = appending ? "Loading more wallpapers…" : "Searching Wallhaven…"
        emptyStateLabel.isHidden = appending && !remoteResults.isEmpty
        searchButton.isEnabled = false; loadMoreButton.isEnabled = false
        let options = state.wallhavenSearch
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await provider.search(options: options, page: page)
                try Task.checkCancellation()
                guard searchGeneration == generation, state.currentSource == .discover else { return }
                resultOptions = options
                if appending {
                    let known = Set(remoteResults.map(\.identityKey))
                    remoteResults.append(contentsOf: result.wallpapers.filter { !known.contains($0.identityKey) })
                } else {
                    remoteResults = result.wallpapers
                    state.selectedRemoteIdentity = remoteResults.first?.identityKey
                }
                currentPage = result.currentPage; lastPage = result.lastPage; totalResults = result.total
                isSearching = false; progressIndicator.stopAnimation(nil); searchButton.isEnabled = true
                collectionView.reloadData(); restoreSelection(); updateEmptyAndPagination(); updateControlAvailability(); stateStore.save(state)
                let rate = result.rateLimit.remaining.map { " · \($0) requests remaining" } ?? ""
                showStatus("Loaded \(remoteResults.count) of \(result.total) Wallhaven results\(rate).", isError: false)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, searchGeneration == generation else { return }
                isSearching = false; progressIndicator.stopAnimation(nil); searchButton.isEnabled = true
                updateEmptyAndPagination(errorText: friendlyMessage(for: error)); updateControlAvailability()
                showStatus(friendlyMessage(for: error), isError: true)
            }
        }
    }

    @objc private func loadMore(_ sender: Any?) {
        guard !isSearching, currentPage < lastPage, resultOptions == state.wallhavenSearch else { return }
        performSearch(page: currentPage + 1, appending: true)
    }

    @objc func chooseFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Choose a Wallpaper Folder"; panel.prompt = "Choose Folder"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if let path = state.folderPath { panel.directoryURL = URL(fileURLWithPath: path) }
        guard panel.runModal() == .OK, let folderURL = panel.url else { return }
        sourcePicker.selectedSegment = LibrarySource.allCases.firstIndex(of: .local) ?? 1
        sourceChanged(); loadFolder(folderURL, persistSelection: true)
    }

    private func loadFolder(_ folderURL: URL, persistSelection: Bool) {
        let standardizedURL = folderURL.standardizedFileURL
        let requestID = UUID(); folderLoadID = requestID; thumbnailProvider.reset()
        if state.currentSource == .local { localURLs = []; collectionView.reloadData() }
        folderPathLabel.stringValue = standardizedURL.path; folderPathLabel.toolTip = standardizedURL.path
        imageCountLabel.stringValue = "Loading…"; updateEmptyAndPagination(loadingText: "Loading local wallpapers…")
        Task.detached(priority: .userInitiated) {
            let result = Result { try SupportedWallpaperFiles.images(in: standardizedURL) }
            await MainActor.run { [weak self] in
                guard let self, self.folderLoadID == requestID else { return }
                switch result {
                case .success(let urls):
                    self.localURLs = urls; self.imageCountLabel.stringValue = urls.count == 1 ? "1 image" : "\(urls.count) images"
                    self.state.folderPath = standardizedURL.path
                    if persistSelection || !urls.contains(where: { $0.path == self.state.selectedImagePath }) { self.state.selectedImagePath = urls.first?.path }
                    self.stateStore.save(self.state)
                    if self.state.currentSource == .local {
                        self.reloadCurrentSource()
                        self.showStatus(urls.isEmpty ? "No supported images found in this folder." : "Loaded \(urls.count) local wallpapers.", isError: false)
                    }
                case .failure(let error):
                    self.imageCountLabel.stringValue = ""
                    self.presentError(title: "Could Not Open Folder", message: error.localizedDescription)
                }
            }
        }
    }

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
    }

    private func localOriginal(for reference: WallpaperReference) async throws -> URL {
        if let cached = try await originalCache.cachedURL(for: reference) {
            updateReference(reference, cachedPath: cached.path); return cached
        }
        showStatus("Downloading \(reference.resolution) original from Wallhaven…", isError: false)
        let temporary = try await provider.downloadOriginal(for: reference)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        let installed = try await originalCache.installDownloadedFile(temporary, for: reference, protectedPaths: currentProtectedPaths())
        updateReference(reference, cachedPath: installed.path)
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
            state.setAssignment(replacement); state.selectedDisplayID = displayID; state.scalingMode = scaling
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

    @objc func previousWallpaper(_ sender: Any?) { moveSelection(direction: -1) }
    @objc func nextWallpaper(_ sender: Any?) { moveSelection(direction: 1) }

    private func moveSelection(direction: Int) {
        guard let next = WallpaperNavigation.index(after: selectedIndex, direction: direction, count: currentItems.count) else { NSSound.beep(); return }
        selectItem(at: next, announce: true)
    }

    private func selectItem(at index: Int, announce: Bool) {
        guard currentItems.indices.contains(index) else { return }
        let item = currentItems[index]; let indexPath = IndexPath(item: index, section: 0)
        collectionView.selectionIndexPaths = [indexPath]
        collectionView.scrollToItems(at: [indexPath], scrollPosition: .nearestVerticalEdge)
        rememberSelection(item); updatePreview(for: item)
        if announce { showStatus("Selected \(item.title).", isError: false) }
        updateControlAvailability()
    }

    private func rememberSelection(_ item: BrowserItem) {
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
        selectItem(at: index, announce: false)
    }

    private func updatePreview(for item: BrowserItem?) {
        detailTask?.cancel()
        previewImageView.image = NSImage(systemSymbolName: "photo", accessibilityDescription: "No preview")
        guard let item else {
            previewTitleLabel.stringValue = "No wallpaper selected"
            previewMetadataLabel.stringValue = "Select a wallpaper to preview it."
            previewTagsLabel.stringValue = ""
            return
        }
        previewTitleLabel.stringValue = item.title
        switch item {
        case .local(let url):
            previewMetadataLabel.stringValue = url.path; previewTagsLabel.stringValue = "Local file"
            thumbnailProvider.requestThumbnail(for: url, maximumPixelSize: 900) { [weak self] image in
                guard case .local(let selectedURL) = self?.selectedItem, selectedURL == url else { return }
                self?.previewImageView.image = image
            }
        case .remote(let ref):
            configureRemoteMetadata(ref)
            remoteThumbnailProvider.requestThumbnail(for: ref.previewURL, maximumPixelSize: 1000) { [weak self] image in
                guard self?.selectedReference?.identityKey == ref.identityKey else { return }
                self?.previewImageView.image = image
            }
            if ref.uploader == nil || ref.tags.isEmpty { fetchDetails(for: ref) }
        }
    }

    private func configureRemoteMetadata(_ reference: WallpaperReference) {
        let uploader = reference.uploader.map { " · by \($0)" } ?? ""
        let cacheStatus = reference.cachedLocalPath == nil ? "" : " · original cached"
        previewMetadataLabel.stringValue = "\(reference.resolution)\(uploader)\(cacheStatus)"
        previewTagsLabel.stringValue = reference.tags.isEmpty ? "Wallhaven · SFW" : reference.tags.joined(separator: " · ")
        favoriteButton.title = state.isFavorite(reference) ? "Remove from Favorites" : "Add to Favorites"
    }

    private func fetchDetails(for reference: WallpaperReference) {
        detailTask = Task { [weak self] in
            guard let self else { return }
            do {
                let detailed = try await provider.fetchDetails(for: reference)
                try Task.checkCancellation(); updateReference(detailed)
                guard selectedReference?.identityKey == detailed.identityKey else { return }
                configureRemoteMetadata(detailed)
            } catch is CancellationError { return }
            catch { logger.error("Wallhaven detail failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    @objc func toggleFavorite(_ sender: Any?) {
        guard let ref = selectedReference else { return }
        state.toggleFavorite(ref); stateStore.save(state)
        updateSourceUI()
        if state.currentSource == .favorites { reloadCurrentSource() } else { updatePreview(for: .remote(ref)) }
    }

    @objc private func addToCollection(_ sender: NSPopUpButton) {
        defer { sender.selectItem(at: 0) }
        guard sender.indexOfSelectedItem > 0, let ref = selectedReference else { return }
        let index = sender.indexOfSelectedItem - 1
        guard state.collections.indices.contains(index) else { return }
        state.collections[index].add(ref); stateStore.save(state); refreshCollectionControls()
        showStatus("Added \(ref.wallpaperID) to \(state.collections[index].name).", isError: false)
    }

    @objc private func removeFromCollection(_ sender: Any?) {
        guard let id = state.selectedCollectionID, let index = state.collections.firstIndex(where: { $0.id == id }), let ref = selectedReference else { return }
        state.collections[index].remove(identityKey: ref.identityKey); stateStore.save(state); refreshCollectionControls(); reloadCurrentSource()
    }

    @objc func openSourcePage(_ sender: Any?) {
        guard let ref = selectedReference else { return }
        NSWorkspace.shared.open(ref.sourcePageURL)
    }

    @objc func createCollection(_ sender: Any?) {
        promptForCollectionName(title: "New Collection", initialValue: "") { [weak self] name in
            guard let self, !name.isEmpty else { return }
            let collection = WallpaperCollection(name: name)
            state.collections.append(collection); state.selectedCollectionID = collection.id; stateStore.save(state)
            refreshCollectionControls()
            if state.currentSource == .collections { reloadCurrentSource() }
        }
    }

    @objc func renameCollection(_ sender: Any?) {
        guard let id = state.selectedCollectionID, let index = state.collections.firstIndex(where: { $0.id == id }) else { return }
        promptForCollectionName(title: "Rename Collection", initialValue: state.collections[index].name) { [weak self] name in
            guard let self, !name.isEmpty, let current = state.collections.firstIndex(where: { $0.id == id }) else { return }
            state.collections[current].rename(to: name); stateStore.save(state); refreshCollectionControls()
        }
    }

    @objc func deleteCollection(_ sender: Any?) {
        guard let id = state.selectedCollectionID, let collection = state.collections.first(where: { $0.id == id }), let window else { return }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "Delete “\(collection.name)”?"
        alert.informativeText = "The collection will be removed. Cached originals and favorites are not deleted."
        alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            state.collections.removeAll { $0.id == id }
            if state.activeRotationCollectionID == id {
                rotationTask?.cancel()
                state.activeRotationCollectionID = nil
                state.rotationInterval = .off
                rotationPopUp.selectItem(at: RotationInterval.allCases.firstIndex(of: .off) ?? 0)
                configureRotationTimer()
            }
            state.selectedCollectionID = state.collections.first?.id; stateStore.save(state)
            refreshCollectionControls(); reloadCurrentSource()
        }
    }

    private func promptForCollectionName(title: String, initialValue: String, completion: @escaping (String) -> Void) {
        guard let window else { return }
        let input = NSTextField(string: initialValue); input.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = "Enter a short, descriptive name."; alert.accessoryView = input
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            completion(input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    @objc private func collectionSelectionChanged() {
        guard state.collections.indices.contains(collectionPopUp.indexOfSelectedItem) else { return }
        state.selectedCollectionID = state.collections[collectionPopUp.indexOfSelectedItem].id; stateStore.save(state); reloadCurrentSource()
    }

    private func refreshCollectionControls() {
        if state.selectedCollectionID == nil || !state.collections.contains(where: { $0.id == state.selectedCollectionID }) { state.selectedCollectionID = state.collections.first?.id }
        collectionPopUp.removeAllItems(); collectionPopUp.addItems(withTitles: state.collections.map(\.name))
        if let selected = state.selectedCollectionID, let index = state.collections.firstIndex(where: { $0.id == selected }) { collectionPopUp.selectItem(at: index) }
        addToCollectionPopUp.removeAllItems(); addToCollectionPopUp.addItem(withTitle: "Add to Collection…"); addToCollectionPopUp.addItems(withTitles: state.collections.map(\.name))
        refreshRotationSources(); stateStore.save(state); updateControlAvailability()
    }

    private func refreshRotationSources() {
        rotationSourcePopUp.removeAllItems(); rotationSourcePopUp.addItem(withTitle: "Local Folder"); rotationSourcePopUp.addItems(withTitles: state.collections.map(\.name))
        if let id = state.activeRotationCollectionID, let index = state.collections.firstIndex(where: { $0.id == id }) { rotationSourcePopUp.selectItem(at: index + 1) }
        else { rotationSourcePopUp.selectItem(at: 0) }
    }

    @objc private func rotationSourceChanged() {
        rotationTask?.cancel()
        let index = rotationSourcePopUp.indexOfSelectedItem - 1
        state.activeRotationCollectionID = state.collections.indices.contains(index) ? state.collections[index].id : nil
        stateStore.save(state); updateControlAvailability()
    }

    @objc private func rotationSelectionChanged() {
        rotationTask?.cancel()
        state.rotationInterval = selectedRotationInterval; stateStore.save(state); configureRotationTimer()
        showStatus(selectedRotationInterval == .off ? "Automatic rotation is off." : "Automatic rotation: \(selectedRotationInterval.displayName).", isError: false)
        updateControlAvailability()
    }

    @objc private func shuffleChanged() { state.shuffleEnabled = shuffleButton.state == .on; stateStore.save(state) }

    private func configureRotationTimer() {
        rotationTimer?.invalidate(); rotationTimer = nil
        guard let seconds = state.rotationInterval.seconds else { return }
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
            let index = rotationIndex(current: refs.firstIndex { $0.identityKey == state.selectedRemoteIdentity }, count: refs.count)
            let ref = refs[index]; state.selectedRemoteIdentity = ref.identityKey; stateStore.save(state)
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
        } else {
            guard !localURLs.isEmpty else { return }
            let index = rotationIndex(current: localURLs.firstIndex { $0.path == state.selectedImagePath }, count: localURLs.count)
            state.selectedImagePath = localURLs[index].path; stateStore.save(state)
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

    @objc func displaySelectionChanged() {
        guard let screen = selectedScreen else { return }
        state.selectedDisplayID = identifier(for: screen); updateDisplayMinimum(); stateStore.save(state)
        invalidateSearch()
        displayPopUp.toolTip = description(for: screen)
    }
    @objc func scalingSelectionChanged() { state.scalingMode = selectedScalingMode; stateStore.save(state) }
    @objc private func screenParametersChanged(_ notification: Notification) { refreshDisplays() }

    func refreshDisplays() {
        let desired = state.selectedDisplayID; screens = availableScreens()
        displayPopUp.removeAllItems(); displayPopUp.addItems(withTitles: screens.map(description(for:)))
        if let desired, let index = screens.firstIndex(where: { identifier(for: $0) == desired }) { displayPopUp.selectItem(at: index) }
        else { displayPopUp.selectItem(at: screens.isEmpty ? -1 : 0) }
        displayPopUp.isEnabled = !screens.isEmpty
        if let screen = selectedScreen { state.selectedDisplayID = identifier(for: screen); displayPopUp.toolTip = description(for: screen); updateDisplayMinimum() }
        stateStore.save(state); updateControlAvailability()
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

    private func updateSourceUI() {
        discoverControls.isHidden = state.currentSource != .discover
        localControls.isHidden = state.currentSource != .local
        favoritesControls.isHidden = state.currentSource != .favorites
        collectionsControls.isHidden = state.currentSource != .collections
        sourceSummaryLabel.stringValue = state.favorites.isEmpty ? "No favorites yet. Add wallpapers from Discover." : "\(state.favorites.count) favorite wallpaper\(state.favorites.count == 1 ? "" : "s")"
        updateControlAvailability()
    }

    private func reloadCurrentSource() {
        collectionView.reloadData(); restoreSelection(); updateEmptyAndPagination(); updateControlAvailability()
    }

    private func updateEmptyAndPagination(errorText: String? = nil, loadingText: String? = nil) {
        let items = currentItems
        if let loadingText { emptyStateLabel.stringValue = loadingText; emptyStateLabel.isHidden = false }
        else if let errorText, items.isEmpty { emptyStateLabel.stringValue = errorText; emptyStateLabel.isHidden = false }
        else if items.isEmpty {
            switch state.currentSource {
            case .discover: emptyStateLabel.stringValue = "No safe-for-work Wallhaven results matched these filters."
            case .local: emptyStateLabel.stringValue = state.folderPath == nil ? "Choose a folder to browse local wallpapers." : "No supported images were found."
            case .favorites: emptyStateLabel.stringValue = "No favorites yet. Add wallpapers from Discover."
            case .collections: emptyStateLabel.stringValue = state.collections.isEmpty ? "Create a collection to organize Wallhaven wallpapers." : "This collection is empty."
            }
            emptyStateLabel.isHidden = false
        } else { emptyStateLabel.isHidden = true }
        if state.currentSource == .discover {
            resultCountLabel.stringValue = totalResults > 0 ? "\(remoteResults.count) of \(totalResults) results" : ""
            loadMoreButton.isHidden = currentPage >= lastPage || lastPage == 0
            loadMoreButton.isEnabled = !isSearching && currentPage < lastPage && resultOptions == state.wallhavenSearch
        } else {
            resultCountLabel.stringValue = items.count == 1 ? "1 wallpaper" : "\(items.count) wallpapers"
            loadMoreButton.isHidden = true
        }
    }

    private func updateControlAvailability() {
        let hasItems = !currentItems.isEmpty; let hasRemote = selectedReference != nil
        setWallpaperButton.isEnabled = selectedItem != nil && selectedScreen != nil && downloadTask == nil && rotationTask == nil
        previousButton.isEnabled = hasItems; nextButton.isEnabled = hasItems
        undoButton.isEnabled = canUndoWallpaper && downloadTask == nil && rotationTask == nil
        undoButton.toolTip = canUndoWallpaper ? "Restore the previous wallpaper" : "No restorable wallpaper change"
        favoriteButton.isHidden = !hasRemote; addToCollectionPopUp.isHidden = !hasRemote
        addToCollectionPopUp.isEnabled = hasRemote && !state.collections.isEmpty; openSourceButton.isHidden = !hasRemote
        removeFromCollectionButton.isHidden = state.currentSource != .collections || !hasRemote
        renameCollectionButton.isEnabled = selectedCollection != nil; deleteCollectionButton.isEnabled = selectedCollection != nil
        let rotationCount: Int
        if let id = state.activeRotationCollectionID { rotationCount = state.collections.first(where: { $0.id == id })?.wallpapers.count ?? 0 }
        else { rotationCount = localURLs.count }
        rotationPopUp.isEnabled = rotationCount > 0 || state.rotationInterval != .off
        shuffleButton.isEnabled = rotationCount > 0 && state.rotationInterval != .off
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

    private func showStatus(_ text: String, isError: Bool) {
        statusLabel.stringValue = text; statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor; statusLabel.setAccessibilityLabel(text)
    }
    private func presentError(title: String, message: String) {
        showStatus("\(title): \(message)", isError: true)
        guard let window else { return }
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = title; alert.informativeText = message; alert.addButton(withTitle: "OK"); alert.beginSheetModal(for: window)
    }

    @objc func showHelp(_ sender: Any?) {
        let alert = NSAlert(); alert.messageText = "Wallpier Help"
        alert.informativeText = "Discover searches safe-for-work wallpapers through the official Wallhaven API. Selecting a result loads a preview; Set Wallpaper downloads only that full-resolution original. Favorites and collections keep references without downloading originals. Local continues to browse a folder on this Mac."
        alert.addButton(withTitle: "OK")
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(setWallpaper(_:)): return selectedItem != nil && selectedScreen != nil && downloadTask == nil && rotationTask == nil
        case #selector(previousWallpaper(_:)), #selector(nextWallpaper(_:)): return !currentItems.isEmpty
        case #selector(undoWallpaperChange(_:)): return canUndoWallpaper && downloadTask == nil && rotationTask == nil
        case #selector(toggleFavorite(_:)), #selector(openSourcePage(_:)): return selectedReference != nil
        case #selector(renameCollection(_:)), #selector(deleteCollection(_:)): return selectedCollection != nil
        default: return true
        }
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { currentItems.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let reusable = collectionView.makeItem(withIdentifier: WallpaperCollectionViewItem.reuseIdentifier, for: indexPath)
        guard let item = reusable as? WallpaperCollectionViewItem, currentItems.indices.contains(indexPath.item) else { return reusable }
        let represented = currentItems[indexPath.item]
        let placeholder = NSImage(systemSymbolName: "photo", accessibilityDescription: "Loading thumbnail")
        item.configure(identifier: represented.identifier, title: represented.title, toolTip: represented.toolTip, placeholder: placeholder)
        switch represented {
        case .local(let url):
            thumbnailProvider.requestThumbnail(for: url) { [weak item] image in
                guard (item?.representedObject as? String) == represented.identifier else { return }; item?.setThumbnail(image)
            }
        case .remote(let ref):
            remoteThumbnailProvider.requestThumbnail(for: ref.thumbnailURL) { [weak item] image in
                guard (item?.representedObject as? String) == represented.identifier else { return }; item?.setThumbnail(image)
            }
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let index = indexPaths.first?.item, currentItems.indices.contains(index) else { return }
        let item = currentItems[index]; rememberSelection(item); updatePreview(for: item)
        showStatus("Selected \(item.title).", isError: false); updateControlAvailability()
    }
}
