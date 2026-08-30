import AppKit
import os.log

final class MainWindowController: NSWindowController,
    NSCollectionViewDataSource,
    NSCollectionViewDelegate,
    NSMenuItemValidation {

    private enum SetSource {
        case user
        case rotation
    }

    private let wallpaperService = WallpaperService()
    private let stateStore = WallpaperStateStore()
    private let thumbnailProvider = ThumbnailProvider()
    private let logger = Logger(subsystem: "com.parth.Wallpier", category: "MainWindow")
    private lazy var state = stateStore.load()

    private var imageURLs: [URL] = []
    private var screens: [NSScreen] = []
    private var folderLoadID = UUID()
    private var rotationTimer: Timer?

    private let folderPathLabel = NSTextField(labelWithString: "No folder selected")
    private let imageCountLabel = NSTextField(labelWithString: "")
    private let emptyStateLabel = NSTextField(wrappingLabelWithString: "Choose a folder to browse wallpapers.")
    private let displayPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let scalingPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let rotationPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let shuffleButton = NSButton(checkboxWithTitle: "Shuffle", target: nil, action: nil)
    private let setWallpaperButton = NSButton(title: "Set Wallpaper", target: nil, action: nil)
    private let previousButton = NSButton(title: "Previous", target: nil, action: nil)
    private let nextButton = NSButton(title: "Next", target: nil, action: nil)
    private let undoButton = NSButton(title: "Undo", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "Choose a wallpaper folder to begin.")

    private lazy var collectionView: NSCollectionView = {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 174, height: 138)
        layout.sectionInset = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 12

        let collectionView = NSCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.allowsEmptySelection = false
        collectionView.register(
            WallpaperCollectionViewItem.self,
            forItemWithIdentifier: WallpaperCollectionViewItem.reuseIdentifier
        )
        collectionView.setAccessibilityLabel("Wallpaper browser")
        return collectionView
    }()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Wallpier"
        window.minSize = NSSize(width: 720, height: 520)
        if !window.setFrameUsingName("WallpierMainWindow") {
            window.center()
        }
        window.setFrameAutosaveName("WallpierMainWindow")

        self.init(window: window)
        configureUI()
        restoreState()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        rotationTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    private func configureUI() {
        guard let contentView = window?.contentView else { return }

        let chooseFolderButton = NSButton(
            title: "Choose Folder…",
            target: self,
            action: #selector(chooseFolder(_:))
        )
        chooseFolderButton.bezelStyle = .rounded
        chooseFolderButton.setAccessibilityHelp("Choose a folder containing JPEG, PNG, or HEIC wallpapers")

        folderPathLabel.lineBreakMode = .byTruncatingMiddle
        folderPathLabel.isSelectable = true
        folderPathLabel.textColor = .secondaryLabelColor
        folderPathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        imageCountLabel.textColor = .secondaryLabelColor
        imageCountLabel.alignment = .right

        let folderRow = NSStackView(views: [chooseFolderButton, folderPathLabel, imageCountLabel])
        folderRow.orientation = .horizontal
        folderRow.alignment = .centerY
        folderRow.spacing = 10

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
        scrollView.documentView = collectionView

        let browserContainer = NSView()
        browserContainer.translatesAutoresizingMaskIntoConstraints = false
        browserContainer.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: browserContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: browserContainer.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: browserContainer.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: browserContainer.bottomAnchor)
        ])

        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.alignment = .center
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.font = .systemFont(ofSize: 15)
        browserContainer.addSubview(emptyStateLabel)
        NSLayoutConstraint.activate([
            emptyStateLabel.centerXAnchor.constraint(equalTo: browserContainer.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: browserContainer.centerYAnchor),
            emptyStateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: browserContainer.leadingAnchor, constant: 30),
            emptyStateLabel.trailingAnchor.constraint(lessThanOrEqualTo: browserContainer.trailingAnchor, constant: -30)
        ])

        displayPopUp.target = self
        displayPopUp.action = #selector(displaySelectionChanged)
        displayPopUp.setAccessibilityLabel("Display")

        scalingPopUp.addItems(withTitles: ScalingMode.allCases.map(\.displayName))
        scalingPopUp.target = self
        scalingPopUp.action = #selector(scalingSelectionChanged)
        scalingPopUp.setAccessibilityLabel("Scaling")

        rotationPopUp.addItems(withTitles: RotationInterval.allCases.map(\.displayName))
        rotationPopUp.target = self
        rotationPopUp.action = #selector(rotationSelectionChanged)
        rotationPopUp.setAccessibilityLabel("Rotation interval")

        shuffleButton.target = self
        shuffleButton.action = #selector(shuffleChanged)

        setWallpaperButton.target = self
        setWallpaperButton.action = #selector(setWallpaper(_:))
        setWallpaperButton.bezelStyle = .rounded
        setWallpaperButton.keyEquivalent = "\r"
        setWallpaperButton.setAccessibilityHelp("Set the selected image on the selected display")

        undoButton.target = self
        undoButton.action = #selector(undoWallpaperChange(_:))
        undoButton.bezelStyle = .rounded
        undoButton.setAccessibilityHelp("Restore the previous Wallpier wallpaper assignment")

        previousButton.target = self
        previousButton.action = #selector(previousWallpaper(_:))
        previousButton.bezelStyle = .rounded
        previousButton.setAccessibilityHelp("Select the previous wallpaper by filename")

        nextButton.target = self
        nextButton.action = #selector(nextWallpaper(_:))
        nextButton.bezelStyle = .rounded
        nextButton.setAccessibilityHelp("Select the next wallpaper by filename")

        let flexibleSpacer = NSView()
        flexibleSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let displayLabel = NSTextField(labelWithString: "Display:")
        let scalingLabel = NSTextField(labelWithString: "Scaling:")
        let primaryControls = NSStackView(views: [
            displayLabel,
            displayPopUp,
            scalingLabel,
            scalingPopUp,
            flexibleSpacer,
            setWallpaperButton
        ])
        primaryControls.orientation = .horizontal
        primaryControls.alignment = .centerY
        primaryControls.spacing = 8

        let rotationLabel = NSTextField(labelWithString: "Rotate:")
        let secondarySpacer = NSView()
        secondarySpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let secondaryControls = NSStackView(views: [
            previousButton,
            nextButton,
            rotationLabel,
            rotationPopUp,
            shuffleButton,
            secondarySpacer,
            undoButton
        ])
        secondaryControls.orientation = .horizontal
        secondaryControls.alignment = .centerY
        secondaryControls.spacing = 8

        statusLabel.isSelectable = true
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2

        let separator = NSBox()
        separator.boxType = .separator

        let rootStack = NSStackView(views: [
            folderRow,
            browserContainer,
            separator,
            primaryControls,
            secondaryControls,
            statusLabel
        ])
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 10
        contentView.addSubview(rootStack)

        [folderRow, browserContainer, separator, primaryControls, secondaryControls, statusLabel]
            .forEach { $0.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true }
        browserContainer.setContentHuggingPriority(.defaultLow, for: .vertical)
        browserContainer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            browserContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 290),
            displayPopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 210),
            scalingPopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
            rotationPopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 110)
        ])
    }

    private func restoreState() {
        scalingPopUp.selectItem(at: ScalingMode.allCases.firstIndex(of: state.scalingMode) ?? 0)
        rotationPopUp.selectItem(at: RotationInterval.allCases.firstIndex(of: state.rotationInterval) ?? 0)
        shuffleButton.state = state.shuffleEnabled ? .on : .off
        refreshDisplays()
        configureRotationTimer()

        if let folderPath = state.folderPath {
            loadFolder(URL(fileURLWithPath: folderPath), persistSelection: false)
        } else {
            updateEmptyState()
            updateControlAvailability()
        }
    }

    @objc func chooseFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Choose a Wallpaper Folder"
        panel.prompt = "Choose Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if let folderPath = state.folderPath {
            panel.directoryURL = URL(fileURLWithPath: folderPath)
        }

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }
        loadFolder(folderURL, persistSelection: true)
    }

    @objc func setWallpaper(_ sender: Any?) {
        guard let imageURL = selectedImageURL else {
            showStatus("Select a wallpaper first.", isError: true)
            NSSound.beep()
            return
        }
        guard let screen = selectedScreen else {
            showStatus("No display is available.", isError: true)
            NSSound.beep()
            return
        }
        applyWallpaper(imageURL, to: screen, scaling: selectedScalingMode, source: .user)
    }

    @objc func previousWallpaper(_ sender: Any?) {
        moveSelection(direction: -1)
    }

    @objc func nextWallpaper(_ sender: Any?) {
        moveSelection(direction: 1)
    }

    @objc func undoWallpaperChange(_ sender: Any?) {
        guard let entry = state.history.last else {
            showStatus("There is no Wallpier wallpaper change to undo.", isError: false)
            NSSound.beep()
            return
        }
        guard let screen = screens.first(where: { identifier(for: $0) == entry.previous.displayID }) else {
            presentError(
                title: "Cannot Undo Wallpaper Change",
                message: "The display used by the previous assignment is not currently available."
            )
            return
        }

        let previousURL = URL(fileURLWithPath: entry.previous.imagePath)
        guard FileManager.default.fileExists(atPath: previousURL.path) else {
            presentError(
                title: "Cannot Undo Wallpaper Change",
                message: "The previous wallpaper file no longer exists at \(previousURL.path)."
            )
            return
        }

        do {
            let result = try wallpaperService.setWallpaper(
                imageURL: previousURL,
                on: screen,
                scaling: entry.previous.scaling
            )
            _ = state.popHistory()
            state.setAssignment(entry.previous)
            state.selectedDisplayID = entry.previous.displayID
            state.scalingMode = entry.previous.scaling
            stateStore.save(state)
            restoreSelectionIfLoaded(path: entry.previous.imagePath)
            refreshDisplays()
            scalingPopUp.selectItem(at: ScalingMode.allCases.firstIndex(of: entry.previous.scaling) ?? 0)
            showStatus(
                String(format: "Restored %@ in %.1f ms.", previousURL.lastPathComponent, result.elapsedTime * 1_000),
                isError: false
            )
            logger.info("Undid wallpaper assignment on \(entry.previous.displayName, privacy: .public)")
            updateControlAvailability()
        } catch {
            presentError(title: "Could Not Restore Wallpaper", message: error.localizedDescription)
        }
    }

    @objc func showHelp(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Wallpier Help"
        alert.informativeText = "Choose a folder containing JPEG, PNG, HEIC, or HEIF files. Select a thumbnail, display, and scaling mode, then choose Set Wallpaper. Previous and Next move the selection; automatic rotation sets subsequent selections while Wallpier remains open."
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(setWallpaper(_:)):
            return selectedImageURL != nil && selectedScreen != nil
        case #selector(previousWallpaper(_:)), #selector(nextWallpaper(_:)):
            return !imageURLs.isEmpty
        case #selector(undoWallpaperChange(_:)):
            return !state.history.isEmpty
        default:
            return true
        }
    }

    private func loadFolder(_ folderURL: URL, persistSelection: Bool) {
        let standardizedURL = folderURL.standardizedFileURL
        let requestID = UUID()
        folderLoadID = requestID
        thumbnailProvider.reset()
        imageURLs = []
        collectionView.reloadData()
        folderPathLabel.stringValue = standardizedURL.path
        folderPathLabel.toolTip = standardizedURL.path
        imageCountLabel.stringValue = "Loading…"
        emptyStateLabel.stringValue = "Loading wallpapers…"
        emptyStateLabel.isHidden = false
        updateControlAvailability()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try SupportedWallpaperFiles.images(in: standardizedURL) }
            DispatchQueue.main.async {
                guard let self, self.folderLoadID == requestID else { return }
                switch result {
                case .success(let urls):
                    self.imageURLs = urls
                    self.collectionView.reloadData()
                    self.imageCountLabel.stringValue = urls.count == 1 ? "1 image" : "\(urls.count) images"
                    self.state.folderPath = standardizedURL.path

                    let selectedPath: String?
                    if !persistSelection,
                       let savedPath = self.state.selectedImagePath,
                       urls.contains(where: { $0.path == savedPath }) {
                        selectedPath = savedPath
                    } else {
                        selectedPath = urls.first?.path
                    }
                    self.state.selectedImagePath = selectedPath
                    self.stateStore.save(self.state)
                    self.restoreSelectionIfLoaded(path: selectedPath)
                    self.updateEmptyState()
                    self.updateControlAvailability()
                    self.showStatus(
                        urls.isEmpty ? "No supported images found in this folder." : "Loaded \(urls.count) wallpapers.",
                        isError: false
                    )
                case .failure(let error):
                    self.imageCountLabel.stringValue = ""
                    self.emptyStateLabel.stringValue = "This folder could not be read."
                    self.emptyStateLabel.isHidden = false
                    self.presentError(title: "Could Not Open Folder", message: error.localizedDescription)
                    self.updateControlAvailability()
                }
            }
        }
    }

    private func applyWallpaper(
        _ imageURL: URL,
        to screen: NSScreen,
        scaling: ScalingMode,
        source: SetSource
    ) {
        let displayID = identifier(for: screen)
        let displayName = description(for: screen)
        let priorAssignment = state.assignment(for: displayID) ?? systemAssignment(
            for: screen,
            displayID: displayID,
            displayName: displayName
        )
        let replacement = DisplayAssignment(
            displayID: displayID,
            displayName: displayName,
            imagePath: imageURL.path,
            scaling: scaling
        )

        do {
            let result = try wallpaperService.setWallpaper(
                imageURL: imageURL,
                on: screen,
                scaling: scaling
            )
            if let priorAssignment, priorAssignment != replacement {
                state.appendHistory(
                    HistoryEntry(
                        previous: priorAssignment,
                        replacement: replacement,
                        timestamp: Date()
                    )
                )
            }
            state.setAssignment(replacement)
            state.selectedImagePath = imageURL.path
            state.selectedDisplayID = displayID
            state.scalingMode = scaling
            stateStore.save(state)
            showStatus(
                String(format: "Set %@ on %@ in %.1f ms.", imageURL.lastPathComponent, screen.localizedName, result.elapsedTime * 1_000),
                isError: false
            )
            logger.info("Set \(imageURL.lastPathComponent, privacy: .public) on \(displayName, privacy: .public)")
            updateControlAvailability()
        } catch {
            logger.error("Wallpaper set failed: \(error.localizedDescription, privacy: .public)")
            if source == .user {
                presentError(title: "Could Not Set Wallpaper", message: error.localizedDescription)
            } else {
                showStatus("Automatic rotation failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    private func systemAssignment(
        for screen: NSScreen,
        displayID: String,
        displayName: String
    ) -> DisplayAssignment? {
        guard let current = wallpaperService.currentWallpaper(on: screen) else { return nil }
        return DisplayAssignment(
            displayID: displayID,
            displayName: displayName,
            imagePath: current.imageURL.path,
            scaling: current.scaling
        )
    }

    private func moveSelection(direction: Int) {
        guard let nextIndex = WallpaperNavigation.index(
            after: selectedImageIndex,
            direction: direction,
            count: imageURLs.count
        ) else {
            NSSound.beep()
            return
        }
        selectImage(at: nextIndex, announce: true)
    }

    private func selectImage(at index: Int, announce: Bool) {
        guard imageURLs.indices.contains(index) else { return }
        let indexPath = IndexPath(item: index, section: 0)
        collectionView.selectionIndexPaths = [indexPath]
        DispatchQueue.main.async { [weak self] in
            guard let self, self.collectionView.selectionIndexPaths.contains(indexPath) else { return }
            self.collectionView.layoutSubtreeIfNeeded()
            guard let attributes = self.collectionView.collectionViewLayout?
                .layoutAttributesForItem(at: indexPath) else { return }
            self.collectionView.scrollToVisible(attributes.frame)
        }
        state.selectedImagePath = imageURLs[index].path
        stateStore.save(state)
        if announce {
            showStatus("Selected \(imageURLs[index].lastPathComponent).", isError: false)
        }
        updateControlAvailability()
    }

    private func restoreSelectionIfLoaded(path: String?) {
        guard let path, let index = imageURLs.firstIndex(where: { $0.path == path }) else { return }
        selectImage(at: index, announce: false)
    }

    private var selectedImageIndex: Int? {
        if let indexPath = collectionView.selectionIndexPaths.first,
           imageURLs.indices.contains(indexPath.item) {
            return indexPath.item
        }
        if let selectedPath = state.selectedImagePath {
            return imageURLs.firstIndex(where: { $0.path == selectedPath })
        }
        return nil
    }

    private var selectedImageURL: URL? {
        guard let index = selectedImageIndex, imageURLs.indices.contains(index) else { return nil }
        return imageURLs[index]
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

    @objc private func displaySelectionChanged() {
        guard let screen = selectedScreen else { return }
        state.selectedDisplayID = identifier(for: screen)
        stateStore.save(state)
        displayPopUp.toolTip = description(for: screen)
        updateControlAvailability()
    }

    @objc private func scalingSelectionChanged() {
        state.scalingMode = selectedScalingMode
        stateStore.save(state)
    }

    @objc private func rotationSelectionChanged() {
        state.rotationInterval = selectedRotationInterval
        stateStore.save(state)
        configureRotationTimer()
        showStatus(
            selectedRotationInterval == .off
                ? "Automatic rotation is off."
                : "Automatic rotation: \(selectedRotationInterval.displayName).",
            isError: false
        )
        updateControlAvailability()
    }

    @objc private func shuffleChanged() {
        state.shuffleEnabled = shuffleButton.state == .on
        stateStore.save(state)
    }

    private func configureRotationTimer() {
        rotationTimer?.invalidate()
        rotationTimer = nil
        guard let seconds = state.rotationInterval.seconds else { return }

        let timer = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in
            self?.rotateWallpaper()
        }
        timer.tolerance = min(seconds * 0.05, 60)
        RunLoop.main.add(timer, forMode: .common)
        rotationTimer = timer
    }

    private func rotateWallpaper() {
        guard !imageURLs.isEmpty, let screen = selectedScreen else { return }

        let nextIndex: Int
        if state.shuffleEnabled, imageURLs.count > 1 {
            let current = selectedImageIndex ?? 0
            var candidate = Int.random(in: 0..<imageURLs.count)
            if candidate == current {
                candidate = (candidate + 1) % imageURLs.count
            }
            nextIndex = candidate
        } else {
            nextIndex = WallpaperNavigation.index(
                after: selectedImageIndex,
                direction: 1,
                count: imageURLs.count
            ) ?? 0
        }

        selectImage(at: nextIndex, announce: false)
        applyWallpaper(
            imageURLs[nextIndex],
            to: screen,
            scaling: selectedScalingMode,
            source: .rotation
        )
    }

    @objc private func screenParametersChanged(_ notification: Notification) {
        refreshDisplays()
    }

    private func refreshDisplays() {
        let desiredID = state.selectedDisplayID
        screens = NSScreen.screens
        displayPopUp.removeAllItems()
        displayPopUp.addItems(withTitles: screens.map(description(for:)))
        if let desiredID, let index = screens.firstIndex(where: { identifier(for: $0) == desiredID }) {
            displayPopUp.selectItem(at: index)
        } else {
            displayPopUp.selectItem(at: screens.isEmpty ? -1 : 0)
        }
        displayPopUp.isEnabled = !screens.isEmpty
        if let screen = selectedScreen {
            state.selectedDisplayID = identifier(for: screen)
            displayPopUp.toolTip = description(for: screen)
        }
        stateStore.save(state)
        updateControlAvailability()
    }

    private func identifier(for screen: NSScreen) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = screen.deviceDescription[key] as? NSNumber {
            return String(number.uint32Value)
        }
        return "\(screen.localizedName)-\(Int(screen.frame.origin.x))-\(Int(screen.frame.origin.y))"
    }

    private func description(for screen: NSScreen) -> String {
        let pixelWidth = Int(screen.frame.width * screen.backingScaleFactor)
        let pixelHeight = Int(screen.frame.height * screen.backingScaleFactor)
        return "\(screen.localizedName) — \(pixelWidth)×\(pixelHeight) px"
    }

    private func updateEmptyState() {
        if imageURLs.isEmpty {
            emptyStateLabel.stringValue = state.folderPath == nil
                ? "Choose a folder to browse wallpapers."
                : "No JPEG, PNG, HEIC, or HEIF images were found."
            emptyStateLabel.isHidden = false
        } else {
            emptyStateLabel.isHidden = true
        }
    }

    private func updateControlAvailability() {
        let hasImages = !imageURLs.isEmpty
        setWallpaperButton.isEnabled = selectedImageURL != nil && selectedScreen != nil
        previousButton.isEnabled = hasImages
        nextButton.isEnabled = hasImages
        undoButton.isEnabled = !state.history.isEmpty
        rotationPopUp.isEnabled = hasImages
        shuffleButton.isEnabled = hasImages && state.rotationInterval != .off
    }

    private func showStatus(_ text: String, isError: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        statusLabel.setAccessibilityLabel(text)
    }

    private func presentError(title: String, message: String) {
        showStatus("\(title): \(message)", isError: true)
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int {
        1
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        imageURLs.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(
            withIdentifier: WallpaperCollectionViewItem.reuseIdentifier,
            for: indexPath
        )
        guard let wallpaperItem = item as? WallpaperCollectionViewItem,
              imageURLs.indices.contains(indexPath.item) else {
            return item
        }

        let url = imageURLs[indexPath.item]
        let placeholder = NSImage(
            systemSymbolName: "photo",
            accessibilityDescription: "Loading thumbnail"
        )
        wallpaperItem.configure(url: url, placeholder: placeholder)
        thumbnailProvider.requestThumbnail(for: url) { [weak wallpaperItem] image in
            guard let wallpaperItem,
                  (wallpaperItem.representedObject as? URL) == url else { return }
            wallpaperItem.setThumbnail(image)
        }
        return wallpaperItem
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        didSelectItemsAt indexPaths: Set<IndexPath>
    ) {
        guard let index = indexPaths.first?.item, imageURLs.indices.contains(index) else { return }
        state.selectedImagePath = imageURLs[index].path
        stateStore.save(state)
        showStatus("Selected \(imageURLs[index].lastPathComponent).", isError: false)
        updateControlAvailability()
    }
}
