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
                PaneInfo(paneID: "p1", workspaceID: "w1", tabID: "t1", agentStatus: .working, focused: true),
                PaneInfo(paneID: "p2", workspaceID: "w1", tabID: "t1", agentStatus: .blocked, focused: false),
            ]
        )
        #expect(WorkspaceRowSnapshot.rows(for: state).first?.status == .blocked)
    }

    @Test func displayTextJoinsNumberAndLabel() {
        let row = WorkspaceRowSnapshot(workspace("w1", number: 2, label: "docs"), status: .idle)
        #expect(row.displayText == "2 · docs")
    }

    @Test func displayTextIsJustTheNumberWithoutALabel() {
        let row = WorkspaceRowSnapshot(workspace("w1", number: 2, label: ""), status: .idle)
        #expect(row.displayText == "2")
    }

    /// The column reloads a row only when its snapshot changes, so the fields
    /// the row draws — and only those — have to take part in equality.
    @Test func snapshotChangesWithEveryDrawnField() {
        let base = WorkspaceRowSnapshot(workspace("w1", number: 1, label: "code"), status: .idle)
        #expect(base == WorkspaceRowSnapshot(workspace("w1", number: 1, label: "code"), status: .idle))
        #expect(base != WorkspaceRowSnapshot(workspace("w1", number: 2, label: "code"), status: .idle))
        #expect(base != WorkspaceRowSnapshot(workspace("w1", number: 1, label: "docs"), status: .idle))
        #expect(base != WorkspaceRowSnapshot(workspace("w1", number: 1, label: "code"), status: .working))
        #expect(base != WorkspaceRowSnapshot(workspace("w1", number: 1, label: "code", focused: true), status: .idle))
    }

    /// Token counts and pane geometry churn constantly; a render that reloaded
    /// on those would fight herdr's event chatter for nothing.
    @Test func snapshotIgnoresFieldsTheRowDoesNotDraw() {
        let quiet = workspace("w1", number: 1, label: "code")
        let busy = WorkspaceInfo(
            workspaceID: "w1",
            number: 1,
            label: "code",
            focused: false,
            paneCount: 7,
            tabCount: 4,
            activeTabID: "t9",
            agentStatus: .working,
            tokens: ["input": "1200"]
        )
        #expect(WorkspaceRowSnapshot(quiet, status: .idle) == WorkspaceRowSnapshot(busy, status: .idle))
    }

    private func workspace(
        _ id: String,
        number: Int,
        label: String,
        focused: Bool = false,
        agentStatus: AgentStatus = .idle
    ) -> WorkspaceInfo {
        WorkspaceInfo(
            workspaceID: id,
            number: number,
            label: label,
            focused: focused,
            paneCount: 1,
            tabCount: 1,
            activeTabID: "t1",
            agentStatus: agentStatus
        )
    }
}
