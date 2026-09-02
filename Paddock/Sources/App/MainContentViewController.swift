import AppKit

/// Fixed-width sidebar on the left, terminal panes filling the rest. The
/// sidebar can be collapsed; the panes then take the full width.
@MainActor
final class MainContentViewController: NSViewController {
    let sidebar: SidebarViewController
    let panes: PaneContainerViewController

    var isSidebarHidden = false {
        didSet {
            guard isSidebarHidden != oldValue, isViewLoaded else { return }
            applySidebarVisibility()
        }
    }

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
        applySidebarVisibility()
    }

    private func applySidebarVisibility() {
        sidebar.view.isHidden = isSidebarHidden
        panesLeadingToSidebar?.isActive = !isSidebarHidden
        panesLeadingToEdge?.isActive = isSidebarHidden
        view.layoutSubtreeIfNeeded()
        panes.focusSelectedPane()
    }
}
