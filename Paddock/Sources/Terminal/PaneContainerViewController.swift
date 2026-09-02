import AppKit

/// Hosts one `TerminalPaneViewController` per visited tab. All panes stay in
/// the view hierarchy with their bounds intact; only `isHidden` and surface
/// visibility change on selection, so libghostty never tears a surface down.
@MainActor
final class PaneContainerViewController: NSViewController {
    private var panes: [UUID: TerminalPaneViewController] = [:]
    private(set) var selectedID: UUID?

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        view = container
    }

    func pane(for id: UUID) -> TerminalPaneViewController? {
        panes[id]
    }

    /// Shows the pane for `tab`, creating it on first visit.
    func select(_ tab: SessionTab, makePane: () -> TerminalPaneViewController) {
        let pane = panes[tab.id] ?? insertPane(makePane(), for: tab.id)
        pane.update(tab: tab)
        selectedID = tab.id
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
        if selectedID == id { selectedID = nil }
    }

    func focusSelectedPane() {
        guard let selectedID else { return }
        panes[selectedID]?.focusPreferredResponder()
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
