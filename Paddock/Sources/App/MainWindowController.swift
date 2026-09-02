import AppKit

@MainActor
final class MainWindowController: NSWindowController, NSMenuItemValidation {
    private static let defaultContentSize = NSSize(width: 1100, height: 720)
    private static let minimumContentSize = NSSize(width: 560, height: 360)
    private static let sidebarHiddenKey = "sidebarHidden"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Paddock"
        // No window tabs: AppKit would otherwise inject Show/Hide Tab Bar
        // items into the View menu.
        window.tabbingMode = .disallowed
        window.contentMinSize = Self.minimumContentSize
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("Main")
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Installs the app's content and restores the persisted sidebar state.
    func install(_ content: MainContentViewController) {
        contentViewController = content
        applySidebarHidden(defaults.bool(forKey: Self.sidebarHiddenKey))
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

    func setSidebarHidden(_ hidden: Bool) {
        defaults.set(hidden, forKey: Self.sidebarHiddenKey)
        applySidebarHidden(hidden)
    }

    /// With the sidebar visible the traffic lights sit inside the sidebar
    /// column and the title bar is invisible. Without it the terminal would
    /// run under the traffic lights, so the window gets a regular title bar
    /// back and the title (the active session) becomes the only context.
    private func applySidebarHidden(_ hidden: Bool) {
        guard let window, let content else { return }
        content.isSidebarHidden = hidden
        window.titlebarAppearsTransparent = !hidden
        window.titleVisibility = hidden ? .visible : .hidden
        if hidden {
            window.styleMask.remove(.fullSizeContentView)
        } else {
            window.styleMask.insert(.fullSizeContentView)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(togglePaddockSidebar(_:)) else { return true }
        item.title = isSidebarHidden ? "Show Sidebar" : "Hide Sidebar"
        return content != nil
    }
}
