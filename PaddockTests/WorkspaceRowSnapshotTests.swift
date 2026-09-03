import Testing
@testable import Paddock

struct WorkspaceRowSnapshotTests {
    @Test func rowsKeepHerdrsOrder() {
        let state = WorkspaceListState(workspaces: [
            workspace("w3", number: 3, label: "notes"),
            workspace("w1", number: 1, label: "code"),
            workspace("w2", number: 2, label: "docs"),
        ])
        #expect(WorkspaceRowSnapshot.rows(for: state).map(\.id) == ["w3", "w1", "w2"])
    }

    @Test func statusComesFromThePanesWhenAnyAreKnown() {
        let state = WorkspaceListState(
            workspaces: [workspace("w1", number: 1, label: "code", agentStatus: .idle)],
            panes: [
                "p1": PaneSummary(workspaceID: "w1", agentStatus: .working),
                "p2": PaneSummary(workspaceID: "w1", agentStatus: .blocked),
            ]
        )
        #expect(WorkspaceRowSnapshot.rows(for: state).first?.status == .blocked)
    }

    /// The pill follows the one focused id on the state, not a flag per row.
    @Test func exactlyTheFocusedRowIsFocused() {
        let state = WorkspaceListState(
            workspaces: [workspace("w1", number: 1, label: "a"), workspace("w2", number: 2, label: "b")],
            focusedID: "w2"
        )
        #expect(WorkspaceRowSnapshot.rows(for: state).map(\.focused) == [false, true])
    }

    @Test func displayTextJoinsNumberAndLabel() {
        let row = WorkspaceRowSnapshot(workspace("w1", number: 2, label: "docs"), status: .idle, focused: false)
        #expect(row.displayText == "2 · docs")
    }

    @Test func displayTextIsJustTheNumberWithoutALabel() {
        let row = WorkspaceRowSnapshot(workspace("w1", number: 2, label: ""), status: .idle, focused: false)
        #expect(row.displayText == "2")
    }

    /// The column reloads a row only when its snapshot changes, so the fields
    /// the row draws — and only those — have to take part in equality.
    @Test func snapshotChangesWithEveryDrawnField() {
        let base = WorkspaceRowSnapshot(workspace("w1", number: 1, label: "code"), status: .idle, focused: false)
        #expect(base == WorkspaceRowSnapshot(workspace("w1", number: 1, label: "code"), status: .idle, focused: false))
        #expect(base != WorkspaceRowSnapshot(workspace("w1", number: 2, label: "code"), status: .idle, focused: false))
        #expect(base != WorkspaceRowSnapshot(workspace("w1", number: 1, label: "docs"), status: .idle, focused: false))
        #expect(base != WorkspaceRowSnapshot(workspace("w1", number: 1, label: "code"), status: .working, focused: false))
        #expect(base != WorkspaceRowSnapshot(workspace("w1", number: 1, label: "code"), status: .idle, focused: true))
    }

    /// Token counts and pane geometry churn constantly; they never reach the
    /// domain `Workspace`, so a render cannot reload on them.
    @Test func wireOnlyFieldsNeverReachTheRow() {
        let quiet = WorkspaceInfo(workspaceID: "w1", number: 1, label: "code", focused: false, agentStatus: .working)
        let busy = WorkspaceInfo(
            workspaceID: "w1",
            number: 1,
            label: "code",
            focused: true,
            paneCount: 7,
            tabCount: 4,
            activeTabID: "t9",
            agentStatus: .working,
            tokens: ["input": "1200"]
        )
        #expect(Workspace(quiet) == Workspace(busy))
    }

    private func workspace(
        _ id: WorkspaceID,
        number: Int,
        label: String,
        agentStatus: AgentStatus = .idle
    ) -> Workspace {
        Workspace(id: id, number: number, label: label, agentStatus: agentStatus)
    }
}
