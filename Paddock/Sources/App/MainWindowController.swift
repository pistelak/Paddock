import AppKit

@MainActor
final class MainWindowController: NSWindowController, NSMenuItemValidation {
    private static let defaultContentSize = NSSize(width: 1100, height: 720)
    /// Wide enough to keep a usable terminal next to both columns: 64 pt of
    /// tile strip plus 220 pt of spaces column leaves 356 pt, about 44 columns
    /// at the default font. (It was 560 while the tile strip was alone.)
    private static let minimumContentSize = NSSize(width: 640, height: 360)
    private static let sidebarHiddenKey = "sidebarHidden"
    private static let spacesHiddenKey = "spacesHidden"
    private static let frameAutosaveName = "Main"

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
        window.setFrameAutosaveName(Self.frameAutosaveName)
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Installs the app's content and restores both persisted column states.
    func install(_ content: MainContentViewController) {
        contentViewController = content
        // Installing a content view controller resizes the window to the
        // content's fitting size — the two fixed-width columns, since the
        // panes have no intrinsic size — clamped to `contentMinSize`. That
        // would open every window at the minimum, so the frame is put back:
        // the autosaved one, or the default on first launch.
        if let window, !window.setFrameUsingName(Self.frameAutosaveName) {
            window.setContentSize(Self.defaultContentSize)
            window.center()
        }
        content.isSpacesHidden = defaults.bool(forKey: Self.spacesHiddenKey)
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

    // MARK: - Spaces column

    var isSpacesHidden: Bool {
        content?.isSpacesHidden ?? false
    }

    @objc func toggleSpacesColumn(_: Any?) {
        setSpacesHidden(!isSpacesHidden)
    }

    /// Only the column moves: the spaces column never reaches the traffic
    /// lights, so the title bar keeps following the tile strip alone.
    func setSpacesHidden(_ hidden: Bool) {
        defaults.set(hidden, forKey: Self.spacesHiddenKey)
        content?.isSpacesHidden = hidden
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(togglePaddockSidebar(_:)):
            item.title = isSidebarHidden ? "Show Sidebar" : "Hide Sidebar"
            return content != nil
        case #selector(toggleSpacesColumn(_:)):
            item.title = isSpacesHidden ? "Show Spaces" : "Hide Spaces"
            // Hiding the tile strip hides the spaces column with it, so the
            // item has nothing to toggle until the strip is back.
            return content != nil && !isSidebarHidden
        default:
            return true
        }
    }
}
