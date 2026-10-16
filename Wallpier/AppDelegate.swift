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

    // Hosted tests open their own windows; only closing the real main window quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        mainWindowController != nil
    }

    // Internal so activated-app tests dispatch keys through the production menu bar.
    func configureMainMenu(for controller: MainWindowController) {
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

        func submenu(_ title: String) -> NSMenu {
            let menu = NSMenu(title: title)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            mainMenu.addItem(item)
            return menu
        }
        @discardableResult
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "",
                 _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = controller
            item.tag = tag
            return item
        }

        let fileMenu = submenu("File")
        add(fileMenu, "Choose Folder…", #selector(MainWindowController.chooseFolder(_:)), "o")
        add(fileMenu, "New Collection…", #selector(MainWindowController.createCollection(_:)), "n", [.command, .shift])
        add(fileMenu, "Rename Collection…", #selector(MainWindowController.renameCollection(_:)))
        add(fileMenu, "Delete Collection…", #selector(MainWindowController.deleteCollection(_:)))
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let editMenu = submenu("Edit")
        // Nil-targeted, so the focused text field or the window's library Undo answers first.
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z").keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let viewMenu = submenu("View")
        add(viewMenu, "Hide Sidebar", #selector(MainWindowController.toggleSidebar(_:)), "s", [.command, .control])
        viewMenu.addItem(.separator())
        add(viewMenu, "Discover", #selector(MainWindowController.showDiscover(_:)), "1")
        add(viewMenu, "Folder", #selector(MainWindowController.showLocal(_:)), "2")
        add(viewMenu, "Favorites", #selector(MainWindowController.showFavorites(_:)), "3")
        add(viewMenu, "Collections", #selector(MainWindowController.showCollections(_:)), "4")
        viewMenu.addItem(.separator())
        add(viewMenu, "Preview on Desktop", #selector(MainWindowController.toggleViewer(_:)), "y")
        add(viewMenu, "Larger Thumbnails", #selector(MainWindowController.makeThumbnailsLarger(_:)), "+")
        add(viewMenu, "Smaller Thumbnails", #selector(MainWindowController.makeThumbnailsSmaller(_:)), "-")
        viewMenu.addItem(.separator())
        add(viewMenu, "Search Wallhaven", #selector(MainWindowController.focusSearch(_:)), "f")

        let wallpaperMenu = submenu("Wallpaper")
        add(wallpaperMenu, "Set Wallpaper", #selector(MainWindowController.setWallpaper(_:)), "\r")
        add(wallpaperMenu, "Undo Wallpaper Change", #selector(MainWindowController.undoWallpaperChange(_:)))
        wallpaperMenu.addItem(.separator())
        add(wallpaperMenu, "Previous Wallpaper", #selector(MainWindowController.previousWallpaper(_:)), "[")
        add(wallpaperMenu, "Next Wallpaper", #selector(MainWindowController.nextWallpaper(_:)), "]")
        wallpaperMenu.addItem(.separator())
        add(wallpaperMenu, "Add to Favorites", #selector(MainWindowController.toggleFavorite(_:)), "d")
        let collections = wallpaperMenu.addItem(withTitle: "Add to Collection", action: nil, keyEquivalent: "")
        collections.submenu = NSMenu(title: "Add to Collection")
        collections.submenu?.delegate = controller
        add(wallpaperMenu, "Remove from Collection", #selector(MainWindowController.removeSelected(_:)), "\u{8}")
        add(wallpaperMenu, "Open on Wallhaven", #selector(MainWindowController.openSourcePage(_:)), "o", [.command, .shift])
        wallpaperMenu.addItem(.separator())
        let rotation = wallpaperMenu.addItem(withTitle: "Automatic Rotation", action: nil, keyEquivalent: "")
        let rotationMenu = NSMenu(title: "Automatic Rotation")
        rotation.submenu = rotationMenu
        for (index, title) in ["Never", "Every 15 Minutes", "Every Hour", "Every Day"].enumerated() {
            add(rotationMenu, title, #selector(MainWindowController.setRotationInterval(_:)), tag: index)
        }
        rotationMenu.addItem(.separator())
        add(rotationMenu, "Shuffle", #selector(MainWindowController.toggleShuffle(_:)))
        rotationMenu.addItem(.separator())
        add(rotationMenu, "Rotation Settings…", #selector(MainWindowController.showRotationSettings(_:)), "r", [.command, .option])

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
