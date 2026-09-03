import AppKit

/// The "Spaces" column: one row per herdr workspace of the selected session.
///
/// Pure view, like `SidebarViewController`: it renders whatever the bound
/// `WorkspaceStore` holds and reports clicks through closures. It never calls
/// herdr itself, so a click and a change made inside the TUI both reach the
/// rows the same way — through the store's events.
///
/// An `NSOutlineView` rather than a stack of custom views because phase 2
/// hangs agent rows off the workspaces as children, and because scrolling,
/// row reuse, animated insert/remove and accessibility come with it.
@MainActor
final class WorkspaceColumnViewController: NSViewController {
    static let width: CGFloat = 220
    /// Clears the transparent title bar's drag region, like
    /// `SidebarViewController.topInset` does for the tile strip. Smaller,
    /// because there are no traffic lights over this column.
    private static let topInset: CGFloat = 38

    /// A row was clicked, or a context-menu entry chosen, for this workspace id.
    var onAction: ((WorkspaceAction, WorkspaceID) -> Void)?
    /// The header's "+" was clicked; the view is the popover/sheet anchor.
    var onCreate: ((NSView) -> Void)?

    private let outline = WorkspaceOutlineView()
    private let scrollView = NSScrollView()
    private let footer = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "No spaces yet")
    private let addButton = NSButton()

    private var footerHeight: NSLayoutConstraint?
    private var footerTop: NSLayoutConstraint?
    private var footerBottom: NSLayoutConstraint?

    /// Held strongly: the store does not reference the column back (its
    /// `onChange` captures `self` weakly), so there is no cycle, and the
    /// coordinator is free to drop a store the moment it stops it.
    private var store: WorkspaceStore?

    /// What the outline view has been told about. The data source answers from
    /// these, never from the store, so a store that changes between two
    /// renders can never make the outline's row count disagree with its model.
    /// A row snapshot carries everything a cell draws, so this is the only
    /// copy of the render.
    private var renderedRows: [WorkspaceRowSnapshot] = []
    private var isDimmed = false

    /// `NSOutlineView` identifies rows by object identity, so every id needs
    /// one stable instance for as long as it is on screen — `reloadItem` and
    /// `moveItem` look the row up by the object they were handed. A fresh box
    /// per call would make both silently no-ops.
    private var items: [WorkspaceID: WorkspaceItem] = [:]

    /// Handed to the outline when it asks for a row the model does not have —
    /// unreachable while `ListDiff` keeps the two in step, and a placeholder
    /// beats trapping in a view that is only ever decoration. Not a
    /// `WorkspaceItem`: there is no such thing as a workspace with no id.
    private let placeholderItem = NSObject()

    private var transientMessage: String?
    private var transientTask: Task<Void, Never>?

    // MARK: - Chrome

    override func loadView() {
        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState
        view = background

        let header = makeHeaderLabel()
        configureAddButton()
        configureOutline()
        configureFooter()

        let separator = NSBox()
        separator.boxType = .separator

        for subview in [header, addButton, scrollView, emptyLabel, footer, separator] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        let footerHeight = footer.heightAnchor.constraint(equalToConstant: 0)
        let footerTop = footer.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 6)
        let footerBottom = footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10)
        self.footerHeight = footerHeight
        self.footerTop = footerTop
        self.footerBottom = footerBottom

        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: Self.width),

            header.topAnchor.constraint(equalTo: view.topAnchor, constant: Self.topInset),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            addButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            addButton.leadingAnchor.constraint(greaterThanOrEqualTo: header.trailingAnchor, constant: 6),
            addButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            footerTop,
            footerBottom,
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),

            separator.topAnchor.constraint(equalTo: view.topAnchor),
            separator.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
        ])

        render()
    }

    private func makeHeaderLabel() -> NSTextField {
        let header = NSTextField(labelWithString: "SPACES")
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        return header
    }

    private func configureAddButton() {
        addButton.bezelStyle = .inline
        addButton.isBordered = false
        addButton.imagePosition = .imageOnly
        addButton.contentTintColor = .secondaryLabelColor
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New space")
        addButton.target = self
        addButton.action = #selector(addButtonClicked)
        // The terminal keeps the keyboard: nothing in this column takes focus.
        addButton.refusesFirstResponder = true
        addButton.toolTip = "New space"
        addButton.setAccessibilityLabel("New space")
    }

    private func configureOutline() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("space"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.gridStyleMask = []
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        // Selection is not truth here: the pill follows herdr's `focused`
        // flag, and the table must never steal the keyboard from the terminal.
        outline.selectionHighlightStyle = .none
        outline.allowsEmptySelection = true
        outline.allowsMultipleSelection = false
        outline.refusesFirstResponder = true
        outline.rowSizeStyle = .custom
        outline.rowHeight = WorkspaceRowView.height
        outline.usesAutomaticRowHeights = false
        outline.floatsGroupRows = false
        // Phase 1 has no children; phase 2 sets a real indent for agent rows.
        outline.indentationPerLevel = 0
        outline.autoresizesOutlineColumn = false
        outline.dataSource = self
        outline.delegate = self
        outline.onRowClick = { [weak self] row in self?.rowClicked(row) }
        outline.contextMenuForRow = { [weak self] row in self?.contextMenu(forRow: row) }

        scrollView.documentView = outline
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
    }

    private func configureFooter() {
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        footer.lineBreakMode = .byTruncatingTail
        footer.maximumNumberOfLines = 2
        footer.usesSingleLineMode = false
        footer.cell?.wraps = true

        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true
    }

    // MARK: - Binding

    /// Points the column at one session's store, or at nothing.
    ///
    /// The previous store's `onChange` is cleared rather than left dangling:
    /// a store the coordinator keeps running for another tab must not go on
    /// driving this column.
    func bind(_ store: WorkspaceStore?) {
        if let current = self.store, current !== store {
            current.onChange = nil
        }
        self.store = store
        store?.onChange = { [weak self] in self?.render() }
        render()
    }

    /// Reads the bound store and brings the outline up to date.
    ///
    /// Rows are diffed rather than reloaded so that hover, scroll position and
    /// the row views themselves survive herdr's event chatter.
    func render() {
        guard isViewLoaded else { return }

        let state = store?.state ?? WorkspaceListState()
        let connection = store?.connection
        // Any state that is not keeping the rows current means what is on
        // screen is the last thing herdr said, not what is true now.
        isDimmed = connection.map { !$0.isConnected } ?? false

        let newRows = WorkspaceRowSnapshot.rows(for: state)
        let oldRows = renderedRows
        renderedRows = newRows
        syncItems(with: newRows)

        let changes = ListDiff.changes(from: oldRows.map(\.id), to: newRows.map(\.id))
        if !changes.isEmpty {
            outline.beginUpdates()
            if !changes.removals.isEmpty {
                outline.removeItems(at: IndexSet(changes.removals), inParent: nil, withAnimation: .effectFade)
            }
            if !changes.insertions.isEmpty {
                outline.insertItems(at: IndexSet(changes.insertions), inParent: nil, withAnimation: .effectFade)
            }
            for move in changes.moves {
                outline.moveItem(at: move.from, inParent: nil, to: move.to, inParent: nil)
            }
            outline.endUpdates()
        }

        // Rows that stayed but whose contents changed. A row that was just
        // inserted already draws from the new state.
        let previous = Dictionary(oldRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for row in newRows {
            guard let before = previous[row.id], before != row, let item = items[row.id] else { continue }
            outline.reloadItem(item)
        }

        applyRowAppearance()
        emptyLabel.isHidden = !(newRows.isEmpty && connection?.isConnected == true)
        updateFooter(for: connection)
    }

    /// The pill and the dimming live on views that `reloadItem` does not
    /// rebuild (the row view is reused as-is), so they are pushed onto the
    /// visible rows by hand. Rows scrolled into view later pick the same
    /// values up in `rowViewForItem` / `viewFor`.
    private func applyRowAppearance() {
        outline.enumerateAvailableRowViews { [renderedRows, isDimmed] rowView, row in
            guard renderedRows.indices.contains(row) else { return }
            (rowView as? WorkspaceRowView)?.isFocusedWorkspace = renderedRows[row].focused
            (rowView.view(atColumn: 0) as? WorkspaceCellView)?.setDimmed(isDimmed)
        }
    }

    private func syncItems(with rows: [WorkspaceRowSnapshot]) {
        for row in rows where items[row.id] == nil {
            items[row.id] = WorkspaceItem(id: row.id)
        }
        let live = Set(rows.map(\.id))
        for id in items.keys where !live.contains(id) {
            items.removeValue(forKey: id)
        }
    }

    // MARK: - Footer

    private func updateFooter(for connection: WorkspaceStore.ConnectionState?) {
        let text = transientMessage ?? ConnectionFooter.text(for: connection)
        footer.stringValue = text ?? ""
        footer.isHidden = text == nil
        // Collapse the whole footer strip, margins included, when it is empty.
        footerHeight?.isActive = text == nil
        footerTop?.constant = text == nil ? 0 : 6
        footerBottom?.constant = text == nil ? 0 : -10
    }

    /// Shows a one-off message (a failed focus, say) in the footer for a few
    /// seconds, then goes back to describing the connection.
    func showTransientError(_ message: String) {
        transientTask?.cancel()
        transientMessage = message
        updateFooter(for: store?.connection)
        transientTask = Task { @MainActor [weak self] in
            // Not `try?`: that swallows cancellation and would clear a message
            // a newer error has just replaced.
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.transientTask = nil
            self.transientMessage = nil
            self.updateFooter(for: self.store?.connection)
        }
    }

    // MARK: - Actions

    private func rowClicked(_ row: Int) {
        guard renderedRows.indices.contains(row) else { return }
        onAction?(.focus, renderedRows[row].id)
    }

    @objc private func addButtonClicked() {
        onCreate?(addButton)
    }

    private func contextMenu(forRow row: Int) -> NSMenu? {
        guard renderedRows.indices.contains(row) else { return nil }
        let id = renderedRows[row].id
        let menu = NSMenu()
        menu.addItem(menuItem("Rename…", action: .rename, id: id))
        menu.addItem(.separator())
        menu.addItem(menuItem("Close Space…", action: .close, id: id))
        return menu
    }

    private func menuItem(_ title: String, action: WorkspaceAction, id: WorkspaceID) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(contextMenuItemChosen(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ContextMenuPayload(action: action, workspaceID: id)
        return item
    }

    @objc private func contextMenuItemChosen(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? ContextMenuPayload else { return }
        onAction?(payload.action, payload.workspaceID)
    }
}

// MARK: - Outline data source and delegate

extension WorkspaceColumnViewController: NSOutlineViewDataSource {
    func outlineView(_: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        // Phase 1 is flat; agents become children of a workspace item later.
        item == nil ? renderedRows.count : 0
    }

    func outlineView(_: NSOutlineView, child index: Int, ofItem _: Any?) -> Any {
        guard renderedRows.indices.contains(index) else { return placeholderItem }
        let id = renderedRows[index].id
        if let item = items[id] { return item }
        // `syncItems` runs before every batch update, so this is belt and
        // braces: an id the outline asks about is one it should be able to
        // keep asking about.
        let item = WorkspaceItem(id: id)
        items[id] = item
        return item
    }

    func outlineView(_: NSOutlineView, isItemExpandable _: Any) -> Bool {
        false
    }
}

extension WorkspaceColumnViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor _: NSTableColumn?, item: Any) -> NSView? {
        guard let row = renderedRow(for: item) else { return nil }

        let cell = outlineView.makeView(withIdentifier: WorkspaceCellView.identifier, owner: self)
            as? WorkspaceCellView ?? {
                let new = WorkspaceCellView()
                new.identifier = WorkspaceCellView.identifier
                return new
            }()
        cell.apply(row, dimmed: isDimmed)
        return cell
    }

    func outlineView(_: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = WorkspaceRowView()
        row.isFocusedWorkspace = renderedRow(for: item)?.focused ?? false
        return row
    }

    private func renderedRow(for item: Any) -> WorkspaceRowSnapshot? {
        guard let id = (item as? WorkspaceItem)?.id else { return nil }
        return renderedRows.first { $0.id == id }
    }

    func outlineView(_: NSOutlineView, heightOfRowByItem _: Any) -> CGFloat {
        WorkspaceRowView.height
    }

    func outlineView(_: NSOutlineView, shouldSelectItem _: Any) -> Bool {
        false
    }
}

/// A reference-stable box for a workspace id.
///
/// `NSOutlineView` keeps its own map from item to row and compares items with
/// `isEqual:`, so the item has to be an object and the same object every time
/// the same id is asked for. An `NSObject` subclass gets identity comparison,
/// which is exactly the guarantee the cache in `items` provides.
private final class WorkspaceItem: NSObject {
    let id: WorkspaceID

    init(id: WorkspaceID) {
        self.id = id
    }
}

private struct ContextMenuPayload {
    let action: WorkspaceAction
    let workspaceID: WorkspaceID
}
