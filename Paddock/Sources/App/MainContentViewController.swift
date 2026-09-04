import AppKit

/// The session tile strip on the left with terminal panes filling the rest.
/// The strip is an ordinary fixed-width split item rather than AppKit's
/// special sidebar item, so it cannot alter the window's title-bar or
/// full-screen presentation. Its controller owns the sidebar material.
@MainActor
final class MainContentViewController: NSSplitViewController {
    /// Wide enough to keep a usable terminal next to the tile strip.
    /// Enforced with constraints: `NSWindow.contentMinSize` is ignored once
    /// Auto Layout sizes the window, which a split view does.
    static let minimumSize = NSSize(width: 560, height: 360)

    private let sidebarItem: NSSplitViewItem

    init(sidebar: SidebarViewController, panes: PaneContainerViewController) {
        sidebarItem = NSSplitViewItem(viewController: sidebar)
        let panesItem = NSSplitViewItem(viewController: panes)
        super.init(nibName: nil, bundle: nil)

        // A fixed strip: nothing to drag or auto-collapse when the window gets
        // narrow. `isCollapsed` still permits the app's explicit toggle.
        sidebarItem.minimumThickness = SidebarViewController.width
        sidebarItem.maximumThickness = SidebarViewController.width
        sidebarItem.canCollapse = false
        // The terminal is what resizes with the window.
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(panesItem.holdingPriority.rawValue + 1)
        addSplitViewItem(sidebarItem)
        addSplitViewItem(panesItem)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.dividerStyle = .thin
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumSize.width),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumSize.height),
        ])
    }

    var isSidebarHidden: Bool {
        sidebarItem.isCollapsed
    }

    /// Collapses or expands the strip. `completion` runs on the main actor
    /// once the animation has ended, or at once when not animated. AppKit
    /// also runs it for an animation a newer one cancelled, so it must be
    /// safe to run twice.
    func setSidebarHidden(_ hidden: Bool, animated: Bool, completion: @escaping @Sendable @MainActor () -> Void) {
        guard animated else {
            sidebarItem.isCollapsed = hidden
            completion()
            return
        }
        NSAnimationContext.runAnimationGroup({ _ in
            sidebarItem.animator().isCollapsed = hidden
        }, completionHandler: {
            // AppKit calls this on the main thread; the type just does not say so.
            MainActor.assumeIsolated { completion() }
        })
    }
}
