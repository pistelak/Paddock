import Foundation

/// Everything one row of the spaces column actually draws.
///
/// The column keeps the snapshot it last drew for each id so that a render can
/// ask the cheap question "did this row change?" instead of reloading all of
/// them: herdr sends bursts of events that leave the visible text identical
/// (pane geometry, token counts, tab ids), and reloading a row that did not
/// change destroys its cell view for nothing.
///
/// It is a plain value, outside the view types, so the diffing rules can be
/// tested without a window.
struct WorkspaceRowSnapshot: Equatable, Sendable {
    let id: WorkspaceID
    let number: Int
    let label: String
    /// From `WorkspaceListState.status(of:)`, not `Workspace.agentStatus`:
    /// only the pane-derived status stays live.
    let status: AgentStatus
    /// `state.focusedID == id`, decided once per render in `rows(for:)`.
    let focused: Bool

    init(id: WorkspaceID, number: Int, label: String, status: AgentStatus, focused: Bool) {
        self.id = id
        self.number = number
        self.label = label
        self.status = status
        self.focused = focused
    }

    init(_ workspace: Workspace, status: AgentStatus, focused: Bool) {
        self.init(
            id: workspace.id,
            number: workspace.number,
            label: workspace.label,
            status: status,
            focused: focused
        )
    }

    /// `1 · docs`, or just the number when herdr has no label for the space.
    var displayText: String {
        label.isEmpty ? "\(number)" : "\(number) · \(label)"
    }

    /// In herdr's order, always: `workspace.moved` / `workspace.reordered`
    /// ship the full ordered list and the column must not second-guess it.
    static func rows(for state: WorkspaceListState) -> [WorkspaceRowSnapshot] {
        state.workspaces.map {
            WorkspaceRowSnapshot($0, status: state.status(of: $0.id), focused: $0.id == state.focusedID)
        }
    }
}
