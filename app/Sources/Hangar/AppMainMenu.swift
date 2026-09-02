import AppKit

/// A real menu bar, present only while Hangar has a window open.
///
/// Hangar runs as an accessory app so the search panel can appear over whatever you
/// are doing without stealing the menu bar. But the setup and ssh-settings windows
/// are ordinary windows, and without a menu bar they have no Edit menu, so
/// Command-C and Command-V do nothing in their text fields. This installs the menu
/// when such a window opens and removes it when the last one closes, which keeps
/// the overlay clean and the windows behaving like Mac windows.
@MainActor
enum AppMainMenu {
    private static var openWindows = 0

    static func install() {
        openWindows += 1
        guard NSApp.mainMenu == nil else { return }
        NSApp.mainMenu = build()
    }

    static func release() {
        openWindows = max(0, openWindows - 1)
        if openWindows == 0 { NSApp.mainMenu = nil }
    }

    private static func build() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Hangar",
                        action: #selector(AppDelegate.menuShowAbout), keyEquivalent: "")
        appMenu.addItem(withTitle: "Check for Updates\u{2026}",
                        action: #selector(AppDelegate.menuCheckUpdates), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Hangar",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        // Closing a window leaves Hangar in the menu bar; this is the item that
        // actually ends it, and it is the only one that does.
        appMenu.addItem(withTitle: "Quit Hangar",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // The actions that matter, in the menu bar as well as the menubar item.
        // A nil target sends these down the responder chain to AppDelegate,
        // which is where the windows and the store already live.
        let fleetItem = NSMenuItem()
        let fleetMenu = NSMenu(title: "Fleet")
        let open = fleetMenu.addItem(withTitle: "Open Hangar",
                                     action: #selector(AppDelegate.menuOpenPanel),
                                     keyEquivalent: "h")
        open.keyEquivalentModifierMask = [.command, .shift]
        fleetMenu.addItem(withTitle: "Refresh Fleet",
                          action: #selector(AppDelegate.menuRefreshFleet),
                          keyEquivalent: "r")
        fleetMenu.addItem(.separator())
        fleetMenu.addItem(withTitle: "Fleet Dashboard",
                          action: #selector(AppDelegate.menuShowDashboard),
                          keyEquivalent: "d")
        fleetMenu.addItem(withTitle: "Setup Check",
                          action: #selector(AppDelegate.menuShowSetup),
                          keyEquivalent: "")
        fleetMenu.addItem(.separator())
        fleetMenu.addItem(withTitle: "Write SSH Aliases Now",
                          action: #selector(AppDelegate.menuWriteAliases),
                          keyEquivalent: "")
        fleetMenu.addItem(withTitle: "Reveal Log in Finder",
                          action: #selector(AppDelegate.menuRevealLog),
                          keyEquivalent: "")
        fleetItem.submenu = fleetMenu
        main.addItem(fleetItem)

        // Standard editing, so the text fields in these windows behave normally.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")),
                                    keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)),
                         keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)),
                         keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)),
                         keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)),
                         keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close",
                           action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "Hangar Help",
                         action: #selector(AppDelegate.menuShowSetup), keyEquivalent: "?")
        helpMenu.addItem(withTitle: "Source on GitHub",
                         action: #selector(AppDelegate.menuOpenSource), keyEquivalent: "")
        helpItem.submenu = helpMenu
        main.addItem(helpItem)
        NSApp.helpMenu = helpMenu

        return main
    }
}
