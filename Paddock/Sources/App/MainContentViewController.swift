import AppKit

/// The session tile strip on the left with terminal panes filling the rest.
/// The strip can be collapsed; the panes then take the whole window.
@MainActor
final class MainContentViewController: NSViewController {
    let sidebar: SidebarViewController
    let panes: PaneContainerViewController

    var isSidebarHidden = false {
        didSet {
            guard isSidebarHidden != oldValue, isViewLoaded else { return }
            applyLayout()
        }
    }

    /// Called after the strip was shown or hidden, so whoever owns the
    /// selection can put the keyboard back where it belongs.
    var onLayoutChange: (() -> Void)?

    /// The two possible left edges of the pane area. Exactly one is active
    /// at a time; `applyLayout()` owns the swap.
    private var panesLeadingToSidebar: NSLayoutConstraint?
    private var panesLeadingToEdge: NSLayoutConstraint?

    init(sidebar: SidebarViewController, panes: PaneContainerViewController) {
        self.sidebar = sidebar
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
        addChild(panes)
        for child in [sidebar.view, panes.view] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }

        // The strip constrains its own width (64); this only places it.
        let toSidebar = panes.view.leadingAnchor.constraint(equalTo: sidebar.view.trailingAnchor)
        let toEdge = panes.view.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        panesLeadingToSidebar = toSidebar
        panesLeadingToEdge = toEdge

        NSLayoutConstraint.activate([
            sidebar.view.topAnchor.constraint(equalTo: view.topAnchor),
            sidebar.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebar.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),

            panes.view.topAnchor.constraint(equalTo: view.topAnchor),
            panes.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            panes.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        applyLayout()
    }

    /// Hides or shows the strip and picks the one pane leading constraint
    /// that matches.
    private func applyLayout() {
        sidebar.view.isHidden = isSidebarHidden
        // Deactivate first: two active leading constraints would conflict.
        panesLeadingToSidebar?.isActive = false
        panesLeadingToEdge?.isActive = false
        (isSidebarHidden ? panesLeadingToEdge : panesLeadingToSidebar)?.isActive = true

        view.layoutSubtreeIfNeeded()
        onLayoutChange?()
    }
}
