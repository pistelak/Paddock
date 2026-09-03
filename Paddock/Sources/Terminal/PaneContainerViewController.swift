import AppKit

/// Hosts one `TerminalPaneViewController` per visited tab. All panes stay in
/// the view hierarchy with their bounds intact; only `isHidden` and surface
/// visibility change on selection, so libghostty never tears a surface down.
///
/// It does not remember which pane is selected: the coordinator owns the
/// selection and names the pane in every call that needs one.
@MainActor
final class PaneContainerViewController: NSViewController {
    private var panes: [UUID: TerminalPaneViewController] = [:]

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        view = container
    }

    func pane(for id: UUID) -> TerminalPaneViewController? {
        panes[id]
    }

    /// Shows the pane for `tab`, creating it on first visit, and gives it the
    /// keyboard.
    func select(_ tab: SessionTab, makePane: () -> TerminalPaneViewController) {
        let pane = panes[tab.id] ?? insertPane(makePane(), for: tab.id)
        pane.update(tab: tab)
        for (id, candidate) in panes {
            let visible = id == tab.id
            candidate.view.isHidden = !visible
            candidate.setVisible(visible)
        }
        pane.view.layoutSubtreeIfNeeded()
        pane.focusPreferredResponder()
    }

    /// Pushes current tab metadata into every existing pane.
    func reconcile(tabs: [SessionTab]) {
        for tab in tabs {
            panes[tab.id]?.update(tab: tab)
        }
    }

    func removePane(for id: UUID) {
        guard let pane = panes.removeValue(forKey: id) else { return }
        pane.view.removeFromSuperview()
        pane.removeFromParent()
    }

    /// Puts the keyboard into one pane; a hidden pane declines on its own.
    func focusPane(_ id: UUID) {
        panes[id]?.focusPreferredResponder()
    }

    private func insertPane(_ pane: TerminalPaneViewController, for id: UUID) -> TerminalPaneViewController {
        addChild(pane)
        pane.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pane.view)
        NSLayoutConstraint.activate([
            pane.view.topAnchor.constraint(equalTo: view.topAnchor),
            pane.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pane.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pane.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        panes[id] = pane
        return pane
    }
}
