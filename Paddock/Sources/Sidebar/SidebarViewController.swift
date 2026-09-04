import AppKit

/// The vertical strip of session tiles plus the "+" tile. Pure view: it
/// renders whatever it is given and reports clicks through closures.
@MainActor
final class SidebarViewController: NSViewController {
    /// Read by the split view item that hosts the strip; the view itself
    /// has no width constraint, the item owns it.
    static let width: CGFloat = 64
    /// The title bar sits outside this view.
    private static let topGap: CGFloat = 12

    var onAction: ((SidebarAction, UUID) -> Void)?
    var onAdd: ((NSView) -> Void)?

    private let stack = NSStackView()
    private let addButton = AddTabButton()
    private var items: [UUID: SessionTabItemView] = [:]

    override func loadView() {
        // A plain view on the window background; the split item owns the width.
        view = NSView()

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        addButton.onClick = { [weak self] anchor in self?.onAdd?(anchor) }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: Self.topGap),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -12),
        ])
    }

    /// `indicators` carries what each tile shows in its corner and says in its
    /// tooltip; a tab missing from it shows nothing.
    func render(tabs: [SessionTab], selectedID: UUID?, indicators: [UUID: TileIndicator] = [:]) {
        for tab in tabs where items[tab.id] == nil {
            items[tab.id] = makeItem(for: tab)
        }
        let liveIDs = Set(tabs.map(\.id))
        for (id, item) in items where !liveIDs.contains(id) {
            item.removeFromSuperview()
            items.removeValue(forKey: id)
        }

        let ordered = tabs.compactMap { items[$0.id] }
        stack.arrangedSubviews.forEach(stack.removeArrangedSubview)
        for item in ordered {
            stack.addArrangedSubview(item)
        }
        stack.addArrangedSubview(addButton)

        for tab in tabs {
            items[tab.id]?.apply(
                tab: tab,
                selected: tab.id == selectedID,
                indicator: indicators[tab.id] ?? .none(displayName: tab.displayName, sessionName: tab.sessionName.rawValue)
            )
        }
    }

    private func makeItem(for tab: SessionTab) -> SessionTabItemView {
        let item = SessionTabItemView(tab: tab)
        item.onSelect = { [weak self] id in self?.onAction?(.select, id) }
        item.onContextMenu = { [weak self] id, event in self?.showContextMenu(for: id, event: event) }
        return item
    }

    // MARK: - Context menu

    private func showContextMenu(for id: UUID, event: NSEvent) {
        guard let item = items[id] else { return }
        let menu = NSMenu()
        menu.addItem(menuItem("Rename…", action: .rename, id: id))
        menu.addItem(colourMenuItem(for: item.tab))
        menu.addItem(.separator())
        menu.addItem(menuItem("Remove Tab", action: .remove, id: id))
        menu.addItem(menuItem("Stop Session…", action: .stopSession, id: id))
        NSMenu.popUpContextMenu(menu, with: event, for: item)
    }

    private func colourMenuItem(for tab: SessionTab) -> NSMenuItem {
        let submenu = NSMenu()
        for color in TabColorID.allCases {
            let entry = menuItem(color.displayName, action: .recolor(color), id: tab.id)
            entry.image = Self.swatch(for: color.color)
            entry.state = color == tab.color ? .on : .off
            submenu.addItem(entry)
        }
        let item = NSMenuItem(title: "Colour", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func menuItem(_ title: String, action: SidebarAction, id: UUID) -> NSMenuItem {
        ClosureMenuItem(title: title) { [weak self] in self?.onAction?(action, id) }
    }

    private static func swatch(for color: TabColor) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            color.nsColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            return true
        }
    }
}
