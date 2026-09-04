import AppKit

/// A traditional macOS terminal window: a compact system title bar above
/// custom content, no toolbar, and AppKit-owned full screen.
@MainActor
final class MainWindowController: NSWindowController, NSMenuItemValidation {
    private static let defaultContentSize = NSSize(width: 1100, height: 720)
    private static let sidebarHiddenKey = "sidebarHidden"
    private static let frameAutosaveName = "Main"

    private let defaults: UserDefaults

    /// Called when a toggle has finished, so whoever owns the selection can
    /// put the keyboard back where it belongs. May run twice when one toggle
    /// interrupts another, so it must be idempotent.
    var onSidebarToggled: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Paddock"
        // No window tabs: AppKit would otherwise inject Show/Hide Tab Bar
        // items into the View menu.
        window.tabbingMode = .disallowed
        // A fallback only: the content's constraints are what hold the size.
        window.contentMinSize = MainContentViewController.minimumSize
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName(Self.frameAutosaveName)
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Installs the app's content with the persisted strip state.
    func install(_ content: MainContentViewController) {
        // The state goes on before the view reaches the window, so a hidden
        // strip never shows for a frame and nothing animates on launch.
        content.setSidebarHidden(defaults.bool(forKey: Self.sidebarHiddenKey), animated: false) {}
        contentViewController = content
        // Installing a content view controller resizes the window to the
        // content's fitting size — the minimum, since the panes have no
        // intrinsic size. That would open every window at the minimum, so the
        // frame is put back: the autosaved one, or the default on first launch.
        if let window, !window.setFrameUsingName(Self.frameAutosaveName) {
            window.setContentSize(Self.defaultContentSize)
            window.center()
        }
    }

    // MARK: - Sidebar

    private var content: MainContentViewController? {
        contentViewController as? MainContentViewController
    }

    var isSidebarHidden: Bool {
        content?.isSidebarHidden ?? false
    }

    @objc func togglePaddockSidebar(_: Any?) {
        setSidebarHidden(!isSidebarHidden)
    }

    /// A toggle that interrupts another just re-focuses the terminal twice,
    /// which is harmless, so completions need no bookkeeping.
    func setSidebarHidden(_ hidden: Bool) {
        guard let content else { return }
        defaults.set(hidden, forKey: Self.sidebarHiddenKey)
        content.setSidebarHidden(hidden, animated: true) { [weak self] in
            self?.onSidebarToggled?()
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(togglePaddockSidebar(_:)):
            item.title = isSidebarHidden ? "Show Sidebar" : "Hide Sidebar"
            return content != nil
        default:
            return true
        }
    }
}
