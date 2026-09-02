import Foundation
import Testing
@testable import Paddock

/// Fixtures are built with the models' own initialisers rather than JSON: the
/// wire shapes are covered by `HerdrProtocolTests`, and what matters here is
/// the state machine.
struct WorkspaceReducerTests {
    // MARK: - Fixtures

    private func ws(
        _ id: String,
        number: Int = 1,
        label: String? = nil,
        focused: Bool = false,
        status: AgentStatus = .idle,
        paneCount: Int = 1
    ) -> WorkspaceInfo {
        WorkspaceInfo(
            workspaceID: id,
            number: number,
            label: label ?? id.uppercased(),
            focused: focused,
            paneCount: paneCount,
            tabCount: 1,
            activeTabID: "t-\(id)",
            agentStatus: status
        )
    }

    private func pane(
        _ id: String,
        in workspaceID: String,
        agent: String? = nil,
        status: AgentStatus = .idle
    ) -> PaneInfo {
        PaneInfo(
            paneID: id,
            workspaceID: workspaceID,
            tabID: "t-\(workspaceID)",
            agent: agent,
            agentStatus: status,
            focused: false
        )
    }

    private func state(
        _ workspaces: [WorkspaceInfo] = [],
        panes: [PaneInfo] = []
    ) -> WorkspaceListState {
        WorkspaceListState(workspaces: workspaces, panes: panes)
    }

    /// Applies an event twice and asserts the second application is a no-op:
    /// every payload herdr sends is a full value, so replaying it (the
    /// subscribe backlog does exactly that) must land on the same state.
    @discardableResult
    private func applyTwice(
        _ event: HerdrEvent,
        to state: inout WorkspaceListState,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> WorkspaceReducer.Outcome {
        let outcome = WorkspaceReducer.apply(event, to: &state)
        let afterFirst = state
        let second = WorkspaceReducer.apply(event, to: &state)
        #expect(state == afterFirst, "event is not idempotent", sourceLocation: sourceLocation)
        if !outcome.contains(.needsResync) {
            #expect(second == .unchanged, "replay reported work to do", sourceLocation: sourceLocation)
        }
        return outcome
    }

    // MARK: - Outcome

    @Test func panesChangedImpliesChangedAndResubscribe() {
        #expect(WorkspaceReducer.Outcome.panesChanged.contains(.changed))
        #expect(WorkspaceReducer.Outcome.panesChanged.contains(.resubscribe))
        #expect(WorkspaceReducer.Outcome.unchanged.isEmpty)
        #expect(WorkspaceReducer.Outcome.changed != .panesChanged)
    }

    // MARK: - State

    @Test func snapshotInitDerivesWorkspacesPanesAndFocus() {
        let snapshot = SessionSnapshot(
            version: "0.8.0",
            protocolVersion: 19,
            workspaces: [ws("w1"), ws("w2", number: 2, focused: true)],
            panes: [pane("p1", in: "w1", agent: "claude", status: .working), pane("p2", in: "w2")],
            focusedWorkspaceID: "w2"
        )

        let state = WorkspaceListState(snapshot: snapshot)

        #expect(state.workspaces.map(\.workspaceID) == ["w1", "w2"])
        #expect(state.focusedID == "w2")
        #expect(state.panes["p1"] == PaneSummary(workspaceID: "w1", agent: "claude", agentStatus: .working))
        #expect(state.panes["p2"] == PaneSummary(workspaceID: "w2", agentStatus: .idle))
    }

    @Test func paneIDsAreSorted() {
        let state = state([ws("w1")], panes: [pane("p3", in: "w1"), pane("p1", in: "w1"), pane("p2", in: "w1")])
        #expect(state.paneIDs == ["p1", "p2", "p3"])
    }

    @Test func statusFallsBackToWorkspaceValueWithoutPanes() {
        let state = state([ws("w1", status: .blocked)])
        #expect(state.status(of: "w1") == .blocked)
        #expect(state.status(of: "nope") == .unknown)
    }

    @Test func statusPrefersPaneDerivedValueOnceAPaneIsKnown() {
        var state = state([ws("w1", status: .working)], panes: [pane("p1", in: "w1", status: .idle)])
        #expect(state.status(of: "w1") == .idle)

        let outcome = applyTwice(
            .paneAgentStatusChanged(paneID: "p1", workspaceID: "w1", status: .blocked, agent: "claude"),
            to: &state
        )
        #expect(outcome == .changed)
        #expect(state.status(of: "w1") == .blocked)
        #expect(state.workspaces[0].agentStatus == .working, "the wire value stays untouched")
    }

    @Test func statusTakesTheHighestPriorityPaneOfThatWorkspaceOnly() {
        let state = state(
            [ws("w1"), ws("w2", number: 2)],
            panes: [
                pane("p1", in: "w1", status: .idle),
                pane("p2", in: "w1", status: .done),
                pane("p3", in: "w2", status: .blocked),
            ]
        )
        #expect(state.status(of: "w1") == .done)
        #expect(state.status(of: "w2") == .blocked)
    }

    @Test func aggregateStatusIsBlockedFirst() {
        #expect(state().aggregateStatus == .unknown)

        let state = state(
            [ws("w1", status: .done), ws("w2", number: 2, status: .working), ws("w3", number: 3, status: .blocked)]
        )
        #expect(state.aggregateStatus == .blocked)
    }

    @Test(arguments: [
        (AgentStatus.done, AgentStatus.working, AgentStatus.done),
        (.working, .idle, .working),
        (.idle, .unknown, .idle),
    ])
    func aggregateStatusOrdersDoneOverWorkingOverIdleOverUnknown(
        first: AgentStatus,
        second: AgentStatus,
        winner: AgentStatus
    ) {
        #expect(state([ws("a", status: first), ws("b", status: second)]).aggregateStatus == winner)
    }

    // MARK: - workspace_created / workspace_updated

    @Test func workspaceCreatedForAnUnknownIDAsksForAResync() {
        var state = state([ws("w1")])
        let outcome = applyTwice(.workspaceCreated(ws("w2", number: 2)), to: &state)

        #expect(outcome == .needsResync)
        #expect(state.workspaces.map(\.workspaceID) == ["w1"], "a backlog replay must not insert a ghost row")
    }

    @Test func workspaceCreatedForAKnownIDUpdatesInPlace() {
        var state = state([ws("w1", label: "old"), ws("w2", number: 2)])
        let outcome = applyTwice(.workspaceCreated(ws("w1", label: "new")), to: &state)

        #expect(outcome == .changed)
        #expect(state.workspaces.map(\.label) == ["new", "W2"])
    }

    @Test func workspaceUpdatedReplacesInPlaceAndKeepsOrder() {
        var state = state([ws("w1"), ws("w2", number: 2, label: "old", status: .idle)])
        let outcome = applyTwice(.workspaceUpdated(ws("w2", number: 2, label: "new", status: .working)), to: &state)

        #expect(outcome == .changed)
        #expect(state.workspaces.map(\.workspaceID) == ["w1", "w2"])
        #expect(state.workspaces[1].label == "new")
        #expect(state.workspaces[1].agentStatus == .working)
    }

    @Test func workspaceUpdatedDoesNotMoveTheFocusPill() {
        var state = state([ws("w1", focused: true), ws("w2", number: 2)])
        let outcome = applyTwice(.workspaceUpdated(ws("w2", number: 2, label: "new", focused: true)), to: &state)

        #expect(outcome == .changed)
        #expect(state.focusedID == "w1")
        #expect(state.workspaces[1].label == "new")
    }

    @Test func workspaceUpdatedWithNothingNewIsUnchanged() {
        var state = state([ws("w1")])
        #expect(WorkspaceReducer.apply(.workspaceUpdated(ws("w1")), to: &state) == .unchanged)
    }

    @Test func workspaceUpdatedForAnUnknownIDAsksForAResync() {
        var state = state([ws("w1")])
        #expect(WorkspaceReducer.apply(.workspaceUpdated(ws("w9")), to: &state) == .needsResync)
        #expect(state.workspaces.count == 1)
    }

    // MARK: - workspace_renamed

    @Test func workspaceRenamedSetsTheLabel() {
        var state = state([ws("w1", label: "old")])
        let outcome = applyTwice(.workspaceRenamed(id: "w1", label: "new"), to: &state)

        #expect(outcome == .changed)
        #expect(state.workspaces[0].label == "new")
    }

    @Test func workspaceRenamedForAnUnknownIDAsksForAResync() {
        var state = state([ws("w1")])
        #expect(WorkspaceReducer.apply(.workspaceRenamed(id: "w9", label: "x"), to: &state) == .needsResync)
    }

    // MARK: - workspace_focused

    @Test func workspaceFocusedClearsEveryOtherFlag() {
        var state = state([ws("w1", focused: true), ws("w2", number: 2), ws("w3", number: 3)])
        let outcome = applyTwice(.workspaceFocused(id: "w3"), to: &state)

        #expect(outcome == .changed)
        #expect(state.workspaces.map(\.focused) == [false, false, true])
        #expect(state.focusedID == "w3")
    }

    @Test func workspaceFocusedForAnUnknownIDAsksForAResync() {
        var state = state([ws("w1", focused: true)])
        #expect(WorkspaceReducer.apply(.workspaceFocused(id: "w9"), to: &state) == .needsResync)
        #expect(state.focusedID == "w1")
    }

    // MARK: - workspace_moved / workspace_reordered

    @Test func workspaceMovedReplacesTheOrder() {
        var state = state([ws("w1"), ws("w2", number: 2)], panes: [pane("p1", in: "w1")])
        let outcome = applyTwice(.workspaceMoved([ws("w2", number: 1), ws("w1", number: 2)]), to: &state)

        #expect(outcome == .changed)
        #expect(state.workspaces.map(\.workspaceID) == ["w2", "w1"])
        #expect(state.paneIDs == ["p1"], "panes of surviving workspaces are kept")
    }

    @Test func workspaceReorderedWithADifferentIDSetRequestsResyncAndKeepsState() {
        let before = state(
            [ws("w1"), ws("w2", number: 2)],
            panes: [pane("p1", in: "w1"), pane("p2", in: "w2")]
        )
        var state = before
        let outcome = applyTwice(.workspaceReordered([ws("w1")]), to: &state)

        #expect(outcome == .needsResync, "a stale backlog list must not overwrite the current one")
        #expect(state == before)
    }

    @Test func workspaceReorderedWithTheSameListIsUnchanged() {
        var state = state([ws("w1"), ws("w2", number: 2)])
        #expect(WorkspaceReducer.apply(.workspaceReordered([ws("w1"), ws("w2", number: 2)]), to: &state) == .unchanged)
    }

    // MARK: - workspace_closed

    @Test func workspaceClosedRemovesTheRowAndItsPanes() {
        var state = state(
            [ws("w1"), ws("w2", number: 2)],
            panes: [pane("p1", in: "w1"), pane("p2", in: "w2")]
        )
        let outcome = applyTwice(.workspaceClosed(id: "w2"), to: &state)

        #expect(outcome == .panesChanged)
        #expect(state.workspaces.map(\.workspaceID) == ["w1"])
        #expect(state.paneIDs == ["p1"])
    }

    @Test func workspaceClosedWithoutPanesOnlyRedraws() {
        var state = state([ws("w1"), ws("w2", number: 2)])
        #expect(WorkspaceReducer.apply(.workspaceClosed(id: "w2"), to: &state) == .changed)
    }

    @Test func workspaceClosedForAnUnknownIDIsUnchanged() {
        var state = state([ws("w1")])
        #expect(WorkspaceReducer.apply(.workspaceClosed(id: "w9"), to: &state) == .unchanged)
        #expect(state.workspaces.count == 1)
    }

    // MARK: - pane_created

    @Test func paneCreatedAddsASummaryAndAsksForAResubscribe() {
        var state = state([ws("w1")])
        let outcome = applyTwice(.paneCreated(pane("p1", in: "w1", agent: "claude", status: .working)), to: &state)

        #expect(outcome == .panesChanged)
        #expect(state.panes["p1"] == PaneSummary(workspaceID: "w1", agent: "claude", agentStatus: .working))
    }

    @Test func paneCreatedForAnUnknownWorkspaceAsksForAResync() {
        var state = state([ws("w1")])
        #expect(WorkspaceReducer.apply(.paneCreated(pane("p9", in: "w9")), to: &state) == .needsResync)
        #expect(state.panes.isEmpty)
    }

    // MARK: - pane_closed / pane_exited

    @Test func paneClosedRemovesThePane() {
        var state = state([ws("w1")], panes: [pane("p1", in: "w1"), pane("p2", in: "w1")])
        let outcome = applyTwice(.paneClosed(paneID: "p1", workspaceID: "w1"), to: &state)

        #expect(outcome == .panesChanged)
        #expect(state.paneIDs == ["p2"])
    }

    @Test func paneExitedRemovesThePane() {
        var state = state([ws("w1")], panes: [pane("p1", in: "w1")])
        let outcome = applyTwice(.paneExited(paneID: "p1", workspaceID: "w1"), to: &state)

        #expect(outcome == .panesChanged)
        #expect(state.panes.isEmpty)
    }

    @Test func paneClosedForAnUnknownPaneIsUnchanged() {
        var state = state([ws("w1")], panes: [pane("p1", in: "w1")])
        #expect(WorkspaceReducer.apply(.paneClosed(paneID: "p9", workspaceID: "w1"), to: &state) == .unchanged)
        #expect(state.paneIDs == ["p1"])
    }

    // MARK: - pane_agent_detected

    @Test func paneAgentDetectedSetsTheAgentWithoutTouchingSubscriptions() {
        var state = state([ws("w1")], panes: [pane("p1", in: "w1", status: .working)])
        let outcome = applyTwice(
            .paneAgentDetected(paneID: "p1", workspaceID: "w1", agent: "claude", released: false),
            to: &state
        )

        #expect(outcome == .changed, "every pane is subscribed, so an agent appearing is only a repaint")
        #expect(state.panes["p1"] == PaneSummary(workspaceID: "w1", agent: "claude", agentStatus: .working))
    }

    @Test func paneAgentReleasedKeepsThePaneAndClearsWhatIsKnown() {
        var state = state([ws("w1")], panes: [pane("p1", in: "w1", agent: "claude", status: .done)])
        let outcome = applyTwice(
            .paneAgentDetected(paneID: "p1", workspaceID: "w1", agent: "claude", released: true),
            to: &state
        )

        #expect(outcome == .changed)
        #expect(state.panes["p1"] == PaneSummary(workspaceID: "w1", agent: nil, agentStatus: .unknown))
        #expect(state.status(of: "w1") == .unknown)
    }

    @Test func paneAgentDetectedForAnUnknownPaneAddsItAndResubscribes() {
        var state = state([ws("w1")])
        let outcome = applyTwice(
            .paneAgentDetected(paneID: "p1", workspaceID: "w1", agent: "claude", released: false),
            to: &state
        )

        #expect(outcome == .panesChanged)
        #expect(state.panes["p1"] == PaneSummary(workspaceID: "w1", agent: "claude", agentStatus: .unknown))
    }

    @Test func paneAgentDetectedForAnUnknownWorkspaceAsksForAResync() {
        var state = state([ws("w1")])
        let outcome = WorkspaceReducer.apply(
            .paneAgentDetected(paneID: "p9", workspaceID: "w9", agent: "claude", released: false),
            to: &state
        )
        #expect(outcome == .needsResync)
        #expect(state.panes.isEmpty)
    }

    // MARK: - pane_agent_status_changed

    @Test func paneAgentStatusChangedForAnUnknownPaneCreatesIt() {
        var state = state([ws("w1", status: .idle)])
        let outcome = applyTwice(
            .paneAgentStatusChanged(paneID: "p1", workspaceID: "w1", status: .working, agent: "claude"),
            to: &state
        )

        #expect(outcome == .panesChanged, "a pane the state did not have has to be subscribed to")
        #expect(state.status(of: "w1") == .working)
    }

    @Test func paneAgentStatusChangedKeepsAKnownAgentWhenThePayloadOmitsIt() {
        var state = state([ws("w1")], panes: [pane("p1", in: "w1", agent: "claude", status: .working)])
        let outcome = applyTwice(
            .paneAgentStatusChanged(paneID: "p1", workspaceID: "w1", status: .done, agent: nil),
            to: &state
        )

        #expect(outcome == .changed)
        #expect(state.panes["p1"] == PaneSummary(workspaceID: "w1", agent: "claude", agentStatus: .done))
    }

    @Test func paneAgentStatusChangedForAnUnknownWorkspaceAsksForAResync() {
        var state = state([ws("w1")])
        let outcome = WorkspaceReducer.apply(
            .paneAgentStatusChanged(paneID: "p9", workspaceID: "w9", status: .blocked, agent: nil),
            to: &state
        )
        #expect(outcome == .needsResync)
        #expect(state.panes.isEmpty)
    }

    // MARK: - Unhandled kinds

    @Test func unhandledKindsAreIgnored() {
        var state = state([ws("w1")], panes: [pane("p1", in: "w1")])
        let before = state
        #expect(WorkspaceReducer.apply(.other(kind: "tab_created"), to: &state) == .unchanged)
        #expect(state == before)
    }

    // MARK: - Sequences

    @Test func replayingAWholeBacklogTwiceLandsOnTheSameState() {
        let events: [HerdrEvent] = [
            .workspaceCreated(ws("w9", number: 9)),
            .workspaceFocused(id: "w2"),
            .paneCreated(pane("p2", in: "w2", agent: "claude")),
            .paneAgentStatusChanged(paneID: "p2", workspaceID: "w2", status: .blocked, agent: "claude"),
            .workspaceRenamed(id: "w1", label: "renamed"),
            .workspaceClosed(id: "w3"),
        ]
        let initial = state([ws("w1", focused: true), ws("w2", number: 2)], panes: [pane("p1", in: "w1")])

        var once = initial
        for event in events {
            _ = WorkspaceReducer.apply(event, to: &once)
        }
        var twice = initial
        for event in events + events {
            _ = WorkspaceReducer.apply(event, to: &twice)
        }

        #expect(once == twice)
        #expect(once.focusedID == "w2")
        #expect(once.status(of: "w2") == .blocked)
        #expect(once.aggregateStatus == .blocked)
    }
}
