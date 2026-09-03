import AppKit

/// The vertical strip of session tiles plus the "+" tile. Pure view: it
/// renders whatever it is given and reports clicks through closures.
@MainActor
final class SidebarViewController: NSViewController {
    static let width: CGFloat = 64
    /// Clears the traffic lights, which sit inside the sidebar column.
    private static let topInset: CGFloat = 48

    var onAction: ((SidebarAction, UUID) -> Void)?
    var onAdd: ((NSView) -> Void)?

    private let stack = NSStackView()
    private let addButton = AddTabButton()
    private var items: [UUID: SessionTabItemView] = [:]

    override func loadView() {
        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState
        view = background

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Sessions are the outer level and spaces the inner one, but both
        // columns use the same `.sidebar` material, so side by side they read
        // as a single surface. Two things separate them: a wash that sinks the
        // tile strip a step behind the spaces column, and a hairline on the
        // trailing edge that mirrors the one the spaces column draws against
        // the terminal.
        //
        // A wash rather than a different material (`.underPageBackground` was
        // the alternative): with `blendingMode = .behindWindow` that material
        // is a good deal darker than `.sidebar`, which fights the traffic
        // lights sitting on top of this column, and it would no longer track
        // the window's active state the way the neighbouring column does.
        // The overlay keeps one material for both columns and makes the depth
        // an explicit few per cent.
        let tint = SidebarTintView()
        let separator = NSBox()
        separator.boxType = .separator

        for subview in [tint, separator, stack] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        addButton.onClick = { [weak self] anchor in self?.onAdd?(anchor) }

        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: Self.width),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: Self.topInset),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -12),

            tint.topAnchor.constraint(equalTo: view.topAnchor),
            tint.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tint.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            separator.topAnchor.constraint(equalTo: view.topAnchor),
            separator.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
        ])
    }

    /// `statuses` carries a badge per tab for the sessions that have one;
    /// tabs missing from it draw no dot.
    func render(tabs: [SessionTab], selectedID: UUID?, statuses: [UUID: AgentStatus] = [:]) {
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
            items[tab.id]?.apply(tab: tab, selected: tab.id == selectedID, status: statuses[tab.id])
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

/// The wash that sinks the tile strip one step behind the spaces column.
///
/// Drawn rather than layer-backed so a light/dark switch simply redraws it,
/// the way `StatusDotView` and `SessionTabItemView` already work. Vibrancy is
/// switched off: inside an `NSVisualEffectView` a vibrant fill is blended
/// against the material and a flat black wash would come out as anything but
/// the few per cent asked for.
@MainActor
private final class SidebarTintView: NSView {
    /// Dark mode has more room between two neighbouring greys than light mode,
    /// where the same value reads as a smudge.
    private static let darkAlpha: CGFloat = 0.06
    private static let lightAlpha: CGFloat = 0.03

    override var allowsVibrancy: Bool { false }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSColor.black.withAlphaComponent(isDark ? Self.darkAlpha : Self.lightAlpha).setFill()
        dirtyRect.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
