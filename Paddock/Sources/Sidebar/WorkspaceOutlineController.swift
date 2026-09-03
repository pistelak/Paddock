import AppKit

/// Keeps an `NSOutlineView` showing a list of `WorkspaceRowSnapshot`s.
///
/// This is the AppKit-shaped half of the spaces column: the data source and
/// delegate, the stable item objects the outline identifies rows by, the
/// diff-and-animate application of a new list, and the pill/dimming that
/// live on row views `reloadItem` does not rebuild. It knows nothing about
/// stores or connections; it is handed rows and reports row indices.
@MainActor
final class WorkspaceOutlineController: NSObject {
    let outline = WorkspaceOutlineView()

    /// A row was clicked, or a context-menu entry chosen, for this workspace.
    var onAction: ((WorkspaceAction, WorkspaceID) -> Void)?

    /// What the outline view has been told about. The data source answers
    /// from these, never from a store, so a store that changes between two
    /// renders can never make the outline's row count disagree with its model.
    private(set) var rows: [WorkspaceRowSnapshot] = []
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

    override init() {
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("space"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.gridStyleMask = []
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        // Selection is not truth here: the pill follows herdr's focused id,
        // and the table must never steal the keyboard from the terminal.
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
    }

    // MARK: - Applying rows

    /// Brings the outline up to date with `newRows`. Rows are diffed rather
    /// than reloaded so that hover, scroll position and the row views
    /// themselves survive herdr's event chatter.
    func apply(_ newRows: [WorkspaceRowSnapshot], dimmed: Bool) {
        let oldRows = rows
        rows = newRows
        isDimmed = dimmed
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
    }

    /// The pill and the dimming live on views that `reloadItem` does not
    /// rebuild (the row view is reused as-is), so they are pushed onto the
    /// visible rows by hand. Rows scrolled into view later pick the same
    /// values up in `rowViewForItem` / `viewFor`.
    private func applyRowAppearance() {
        outline.enumerateAvailableRowViews { [rows, isDimmed] rowView, row in
            guard rows.indices.contains(row) else { return }
            (rowView as? WorkspaceRowView)?.isFocusedWorkspace = rows[row].focused
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

    // MARK: - Actions

    private func rowClicked(_ row: Int) {
        guard rows.indices.contains(row) else { return }
        onAction?(.focus, rows[row].id)
    }

    private func contextMenu(forRow row: Int) -> NSMenu? {
        guard rows.indices.contains(row) else { return nil }
        let id = rows[row].id
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Rename…") { [weak self] in self?.onAction?(.rename, id) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Close Space…") { [weak self] in self?.onAction?(.close, id) })
        return menu
    }

    private func row(for item: Any) -> WorkspaceRowSnapshot? {
        guard let id = (item as? WorkspaceItem)?.id else { return nil }
        return rows.first { $0.id == id }
    }
}

// MARK: - Data source and delegate

extension WorkspaceOutlineController: NSOutlineViewDataSource {
    func outlineView(_: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        // Phase 1 is flat; agents become children of a workspace item later.
        item == nil ? rows.count : 0
    }

    func outlineView(_: NSOutlineView, child index: Int, ofItem _: Any?) -> Any {
        guard rows.indices.contains(index) else { return placeholderItem }
        let id = rows[index].id
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

extension WorkspaceOutlineController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor _: NSTableColumn?, item: Any) -> NSView? {
        guard let row = row(for: item) else { return nil }

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
        let rowView = WorkspaceRowView()
        rowView.isFocusedWorkspace = row(for: item)?.focused ?? false
        return rowView
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
