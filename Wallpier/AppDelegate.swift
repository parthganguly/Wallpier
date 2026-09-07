import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted unit tests exercise injected providers without launching live discovery.
        guard NSClassFromString("XCTestCase") == nil,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        NSApp.setActivationPolicy(.regular)

        let windowController = MainWindowController()
        mainWindowController = windowController
        configureMainMenu(for: windowController)
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func configureMainMenu(for controller: MainWindowController) {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        appMenu.addItem(
            withTitle: "About Wallpier",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        let servicesMenu = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Wallpier", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Wallpier", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileMenu = NSMenu(title: "File")
        let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)
        let chooseFolder = fileMenu.addItem(
            withTitle: "Choose Folder…",
            action: #selector(MainWindowController.chooseFolder(_:)),
            keyEquivalent: "o"
        )
        chooseFolder.target = controller
        let newCollection = fileMenu.addItem(
            withTitle: "New Collection…",
            action: #selector(MainWindowController.createCollection(_:)),
            keyEquivalent: "n"
        )
        newCollection.keyEquivalentModifierMask = [.command, .shift]
        newCollection.target = controller
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let editMenu = NSMenu(title: "Edit")
        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        let undo = editMenu.addItem(
            withTitle: "Undo Wallpaper Change",
            action: #selector(MainWindowController.undoWallpaperChange(_:)),
            keyEquivalent: "z"
        )
        undo.target = controller
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let viewMenu = NSMenu(title: "View")
        let viewMenuItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)
        let search = viewMenu.addItem(
            withTitle: "Search Wallhaven",
            action: #selector(MainWindowController.focusSearch(_:)),
            keyEquivalent: "f"
        )
        search.target = controller
        viewMenu.addItem(.separator())
        let sources: [(String, Selector, String)] = [
            ("Discover", #selector(MainWindowController.showDiscover(_:)), "1"),
            ("Local", #selector(MainWindowController.showLocal(_:)), "2"),
            ("Favorites", #selector(MainWindowController.showFavorites(_:)), "3"),
            ("Collections", #selector(MainWindowController.showCollections(_:)), "4")
        ]
        for (title, action, key) in sources {
            let item = viewMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = controller
        }
        viewMenu.addItem(.separator())
        let inspector = viewMenu.addItem(
            withTitle: "Hide Inspector",
            action: #selector(MainWindowController.toggleInspector(_:)),
            keyEquivalent: "0"
        )
        inspector.keyEquivalentModifierMask = [.command, .option]
        inspector.target = controller

        let wallpaperMenu = NSMenu(title: "Wallpaper")
        let wallpaperMenuItem = NSMenuItem(title: "Wallpaper", action: nil, keyEquivalent: "")
        wallpaperMenuItem.submenu = wallpaperMenu
        mainMenu.addItem(wallpaperMenuItem)
        let previous = wallpaperMenu.addItem(
            withTitle: "Previous Wallpaper",
            action: #selector(MainWindowController.previousWallpaper(_:)),
            keyEquivalent: "["
        )
        previous.target = controller
        let next = wallpaperMenu.addItem(
            withTitle: "Next Wallpaper",
            action: #selector(MainWindowController.nextWallpaper(_:)),
            keyEquivalent: "]"
        )
        next.target = controller
        wallpaperMenu.addItem(.separator())
        let setWallpaper = wallpaperMenu.addItem(
            withTitle: "Set Wallpaper",
            action: #selector(MainWindowController.setWallpaper(_:)),
            keyEquivalent: "\r"
        )
        setWallpaper.keyEquivalentModifierMask = [.command]
        setWallpaper.target = controller
        wallpaperMenu.addItem(.separator())
        let favorite = wallpaperMenu.addItem(
            withTitle: "Add or Remove Favorite",
            action: #selector(MainWindowController.toggleFavorite(_:)),
            keyEquivalent: "d"
        )
        favorite.target = controller
        let openSource = wallpaperMenu.addItem(
            withTitle: "Open on Wallhaven",
            action: #selector(MainWindowController.openSourcePage(_:)),
            keyEquivalent: "o"
        )
        openSource.keyEquivalentModifierMask = [.command, .shift]
        openSource.target = controller

        let windowMenu = NSMenu(title: "Window")
        let windowMenuItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        let helpMenu = NSMenu(title: "Help")
        let helpMenuItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)
        let help = helpMenu.addItem(
            withTitle: "Wallpier Help",
            action: #selector(MainWindowController.showHelp(_:)),
            keyEquivalent: "?"
        )
        help.keyEquivalentModifierMask = [.command, .shift]
        help.target = controller

        NSApp.mainMenu = mainMenu
    }
}

@main
enum WallpierApplication {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
