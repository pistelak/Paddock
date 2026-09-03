import AppKit

/// Fixed-width columns on the left — the session tile strip and the spaces
/// column — with terminal panes filling the rest.
///
/// Either column can be collapsed. The spaces column hides on its own, and
/// also whenever the tile strip goes: a spaces list with no visible session
/// selector would be context without its subject.
@MainActor
final class MainContentViewController: NSViewController {
    let sidebar: SidebarViewController
    let spaces: WorkspaceColumnViewController
    let panes: PaneContainerViewController

    var isSidebarHidden = false {
        didSet {
            guard isSidebarHidden != oldValue, isViewLoaded else { return }
            applyLayout()
        }
    }

    var isSpacesHidden = false {
        didSet {
            guard isSpacesHidden != oldValue, isViewLoaded else { return }
            applyLayout()
        }
    }

    /// Called after the columns were shown or hidden, so whoever owns the
    /// selection can put the keyboard back where it belongs.
    var onLayoutChange: (() -> Void)?

    /// The three possible left edges of the pane area. Exactly one is active
    /// at a time; `applyLayout()` owns the swap.
    private var panesLeadingToSpaces: NSLayoutConstraint?
    private var panesLeadingToSidebar: NSLayoutConstraint?
    private var panesLeadingToEdge: NSLayoutConstraint?

    init(
        sidebar: SidebarViewController,
        spaces: WorkspaceColumnViewController,
        panes: PaneContainerViewController
    ) {
        self.sidebar = sidebar
        self.spaces = spaces
        self.panes = panes
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true

        addChild(sidebar)
        addChild(spaces)
        addChild(panes)
        for child in [sidebar.view, spaces.view, panes.view] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }

        // Both columns constrain their own width (64 and 220); this only
        // stacks them left to right.
        let toSpaces = panes.view.leadingAnchor.constraint(equalTo: spaces.view.trailingAnchor)
        let toSidebar = panes.view.leadingAnchor.constraint(equalTo: sidebar.view.trailingAnchor)
        let toEdge = panes.view.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        panesLeadingToSpaces = toSpaces
        panesLeadingToSidebar = toSidebar
        panesLeadingToEdge = toEdge

        NSLayoutConstraint.activate([
            sidebar.view.topAnchor.constraint(equalTo: view.topAnchor),
            sidebar.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebar.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),

            spaces.view.topAnchor.constraint(equalTo: view.topAnchor),
            spaces.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            spaces.view.leadingAnchor.constraint(equalTo: sidebar.view.trailingAnchor),

            panes.view.topAnchor.constraint(equalTo: view.topAnchor),
            panes.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            panes.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        applyLayout()
    }

    /// Hides or shows the two columns and picks the one pane leading
    /// constraint that matches. The spaces column is only ever visible
    /// alongside the tile strip.
    private func applyLayout() {
        let spacesVisible = !isSidebarHidden && !isSpacesHidden
        sidebar.view.isHidden = isSidebarHidden
        spaces.view.isHidden = !spacesVisible

        // Deactivate first: two active leading constraints would conflict.
        panesLeadingToSpaces?.isActive = false
        panesLeadingToSidebar?.isActive = false
        panesLeadingToEdge?.isActive = false
        if isSidebarHidden {
            panesLeadingToEdge?.isActive = true
        } else if spacesVisible {
            panesLeadingToSpaces?.isActive = true
        } else {
            panesLeadingToSidebar?.isActive = true
        }

        view.layoutSubtreeIfNeeded()
        onLayoutChange?()
    }
}
