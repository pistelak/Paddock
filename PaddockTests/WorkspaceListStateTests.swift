import Foundation
import Testing
@testable import Paddock

/// The one door into a `WorkspaceListState`: the snapshot mapper translates
/// herdr's wire shape and refuses what the column could not draw safely.
struct WorkspaceListStateTests {
    private func ws(_ id: WorkspaceID, focused: Bool = false) -> WorkspaceInfo {
        WorkspaceInfo(workspaceID: id, number: 1, label: id.rawValue, focused: focused, agentStatus: .idle)
    }

    // MARK: - Focus

    @Test func theTopLevelFocusedIdWins() throws {
        let state = try WorkspaceListState(snapshot: SessionSnapshot(
            workspaces: [ws("w1", focused: true), ws("w2")],
            focusedWorkspaceID: "w2"
        ))
        #expect(state.focusedID == "w2")
    }

    @Test func theRowFlagIsTheFallbackWhenTheTopLevelIdIsAbsent() throws {
        let state = try WorkspaceListState(snapshot: SessionSnapshot(workspaces: [ws("w1"), ws("w2", focused: true)]))
        #expect(state.focusedID == "w2")
    }

    /// Two flagged rows would have been two pills; the top-level id decides.
    @Test func twoFlaggedRowsDeferToTheTopLevelId() throws {
        let state = try WorkspaceListState(snapshot: SessionSnapshot(
            workspaces: [ws("w1", focused: true), ws("w2", focused: true)],
            focusedWorkspaceID: "w1"
        ))
        #expect(state.focusedID == "w1")
    }

    @Test func anEmptyListHasNoFocus() throws {
        let state = try WorkspaceListState(snapshot: SessionSnapshot(workspaces: [], focusedWorkspaceID: nil))
        #expect(state.focusedID == nil)
        #expect(state.workspaces.isEmpty)
    }

    /// Without the top-level id, the flags have to agree on exactly one row;
    /// a non-empty list that focuses nothing, or two things, is refused.
    @Test func aNonEmptyListWithNoFocusedRowAndNoTopLevelIdIsRefused() {
        #expect(throws: PaddockError.herdrSnapshotInvalid("expected exactly one focused workspace, found 0")) {
            try WorkspaceListState(snapshot: SessionSnapshot(workspaces: [ws("w1"), ws("w2")]))
        }
    }

    @Test func twoFlaggedRowsWithoutATopLevelIdAreRefused() {
        #expect(throws: PaddockError.herdrSnapshotInvalid("expected exactly one focused workspace, found 2")) {
            try WorkspaceListState(snapshot: SessionSnapshot(workspaces: [ws("w1", focused: true), ws("w2", focused: true)]))
        }
    }

    @Test func aFocusedIdNamingNoWorkspaceIsRefused() {
        #expect(throws: PaddockError.herdrSnapshotInvalid("focused workspace w9 is not listed")) {
            try WorkspaceListState(snapshot: SessionSnapshot(workspaces: [ws("w1", focused: true)], focusedWorkspaceID: "w9"))
        }
    }

    // MARK: - Integrity

    @Test func aDuplicateWorkspaceIsRefused() {
        #expect(throws: PaddockError.herdrSnapshotInvalid("workspace w1 is listed twice")) {
            try WorkspaceListState(snapshot: SessionSnapshot(workspaces: [ws("w1", focused: true), ws("w1")]))
        }
    }

    @Test func aPaneInAnUnlistedWorkspaceIsRefused() {
        #expect(throws: PaddockError.herdrSnapshotInvalid("pane w9:p1 belongs to unlisted workspace w9")) {
            try WorkspaceListState(snapshot: SessionSnapshot(
                workspaces: [ws("w1", focused: true)],
                panes: [PaneInfo(paneID: "w9:p1", workspaceID: "w9", agentStatus: .idle)]
            ))
        }
    }

    @Test func anEmptyIdDoesNotDecode() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WorkspaceID.self, from: Data("\"\"".utf8))
        }
        #expect(WorkspaceID(rawValue: "") == nil)
        #expect(PaneID(rawValue: "") == nil)
    }

    // MARK: - Derived status

    /// The per-workspace status is folded once at construction and must agree
    /// with the lookups next to it, including for the unchecked initialiser's
    /// one odd case: a duplicated id resolves to the first entry, as
    /// `workspace(_:)` does.
    @Test func statusByWorkspaceMatchesTheLookupsAndPrefersTheFirstDuplicate() {
        let state = WorkspaceListState(
            workspaces: [
                Workspace(id: "w1", number: 1, label: "a", agentStatus: .blocked),
                Workspace(id: "w1", number: 1, label: "a-again", agentStatus: .idle),
                Workspace(id: "w2", number: 2, label: "b", agentStatus: .idle),
            ],
            panes: ["w2:p1": PaneSummary(workspaceID: "w2", agentStatus: .working)]
        )
        #expect(state.status(of: "w1") == .blocked, "first entry wins, like workspace(_:)")
        #expect(state.workspace("w1")?.agentStatus == .blocked)
        #expect(state.status(of: "w2") == .working, "panes beat the workspace's own status")
        #expect(state.status(of: "w9") == .unknown)
        #expect(state.aggregateStatus == .blocked)
        #expect(WorkspaceListState().aggregateStatus == .unknown)
    }

    /// A pane whose workspace is not listed (impossible through the mapper,
    /// possible through the unchecked initialiser) belongs to nothing that is
    /// drawn: its workspace has no status, and it does not count toward the
    /// badge. Deliberate — the old per-call scan happened to answer for it.
    @Test func aPaneOfAnUnlistedWorkspaceCountsForNothing() {
        let state = WorkspaceListState(
            workspaces: [Workspace(id: "w1", number: 1, label: "a", agentStatus: .idle)],
            panes: ["w9:p1": PaneSummary(workspaceID: "w9", agentStatus: .working)]
        )
        #expect(state.status(of: "w9") == .unknown)
        #expect(state.status(of: "w1") == .idle)
        #expect(state.aggregateStatus == .idle)
    }

    @Test func countOfAStatusCountsSpaces() {
        let state = WorkspaceListState(
            workspaces: [
                Workspace(id: "w1", number: 1, label: "", agentStatus: .blocked),
                Workspace(id: "w2", number: 2, label: "", agentStatus: .blocked),
                Workspace(id: "w3", number: 3, label: "", agentStatus: .done),
            ],
            panes: ["w3:p1": PaneSummary(workspaceID: "w3", agentStatus: .working)],
            focusedID: "w1"
        )
        #expect(state.count(of: .blocked) == 2)
        #expect(state.count(of: .working) == 1, "a pane's status beats its space's own")
        #expect(state.count(of: .done) == 0)
        #expect(state.count(of: .idle) == 0)
        #expect(WorkspaceListState().count(of: .blocked) == 0)
    }

    // MARK: - Translation

    @Test func panesAreKeyedByIdAndWireOnlyFieldsAreDropped() throws {
        let state = try WorkspaceListState(snapshot: SessionSnapshot(
            workspaces: [ws("w1", focused: true)],
            panes: [
                PaneInfo(paneID: "w1:p1", workspaceID: "w1", tabID: "t", agent: "claude", agentStatus: .working, focused: true),
                PaneInfo(paneID: "w1:p2", workspaceID: "w1", agentStatus: .idle),
            ]
        ))
        #expect(state.paneIDs == ["w1:p1", "w1:p2"])
        #expect(state.panes["w1:p1"] == PaneSummary(workspaceID: "w1", agent: "claude", agentStatus: .working))
        #expect(state.status(of: "w1") == .working)
        #expect(state.aggregateStatus == .working)
    }
}
