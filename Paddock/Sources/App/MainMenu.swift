import AppKit
import Sparkle

/// A deliberately small main menu. There is no Edit menu on purpose: the
/// terminal handles Cmd+C / Cmd+V itself through Ghostty's keybindings, and
/// an Edit menu would intercept those key equivalents first.
///
/// "Check for Updates…" has no key equivalent, like everything here that is
/// not a standard application-menu item. Sparkle enables it only while its
/// updater is running, so in a development build it is present but greyed
/// out — the visible sign that this is not a release.
@MainActor
enum MainMenu {
    static func build(updater: SPUStandardUpdaterController) -> NSMenu {
        let main = NSMenu()
        main.addItem(appMenuItem(updater: updater))
        main.addItem(viewMenuItem())
        main.addItem(windowMenuItem())
        return main
    }

    private static func appMenuItem(updater: SPUStandardUpdaterController) -> NSMenuItem {
        let menu = NSMenu()
        menu.addItem(withTitle: "About Paddock", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let checkForUpdates = menu.addItem(
            withTitle: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdates.target = updater
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide Paddock", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Paddock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private static func viewMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "View")
        // Ctrl+Cmd+S: herdr sees Cmd keys through the kitty protocol, so the
        // one app-level shortcut uses a chord no terminal program binds.
        let sidebar = menu.addItem(
            withTitle: "Hide Sidebar",
            action: #selector(MainWindowController.togglePaddockSidebar(_:)),
            keyEquivalent: "s"
        )
        sidebar.keyEquivalentModifierMask = [.command, .control]

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private static func windowMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let fullScreen = menu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]

        let item = NSMenuItem()
        item.submenu = menu
        NSApp.windowsMenu = menu
        return item
    }
}
