import AppKit

/// The outline view behind the spaces column.
///
/// Two AppKit behaviours have to go, because in this column a click is a
/// *request to herdr*, not a selection:
///
/// - `mouseDown` does not reach `super`, so the table never starts its
///   selection tracking and never makes itself first responder — the terminal
///   keeps the keyboard even though the user clicked the column.
/// - `menu(for:)` is built here rather than through a static `menu`, so the
///   row under the cursor is known and no selection has to be made to find it.
///
/// Both are reported through closures; the view controller owns the meaning.
@MainActor
final class WorkspaceOutlineView: NSOutlineView {
    /// Row index under the pointer, or nothing when the click missed a row.
    var onRowClick: ((Int) -> Void)?
    /// Builds the context menu for a row index. Returning nil shows no menu.
    var contextMenuForRow: ((Int) -> NSMenu?)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clicked = row(at: point)
        guard clicked >= 0 else { return }
        onRowClick?(clicked)
    }

    override func rightMouseDown(with event: NSEvent) {
        // Deliberately not `super`: the default implementation selects the
        // clicked row before showing the menu.
        if let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clicked = row(at: point)
        guard clicked >= 0 else { return nil }
        return contextMenuForRow?(clicked)
    }

    /// Belt and braces with `refusesFirstResponder`: nothing in this column
    /// should ever take the keyboard away from the terminal.
    override var acceptsFirstResponder: Bool { false }
}
