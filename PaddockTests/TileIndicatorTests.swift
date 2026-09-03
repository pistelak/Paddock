import Testing
@testable import Paddock

/// Every decision a tile makes about its corner mark, tooltip and VoiceOver
/// label, checked without a window.
struct TileIndicatorTests {
    private func state(_ statuses: [AgentStatus]) -> WorkspaceListState {
        WorkspaceListState(
            workspaces: statuses.enumerated().map { index, status in
                Workspace(id: WorkspaceID(rawValue: "w\(index)")!, number: index + 1, label: "", agentStatus: status)
            },
            focusedID: statuses.isEmpty ? nil : "w0"
        )
    }

    private func indicator(_ statuses: [AgentStatus], connection: WorkspaceStore.ConnectionState = .live) -> TileIndicator {
        TileIndicator(displayName: "Work", sessionName: "work", state: state(statuses), connection: connection)
    }

    // MARK: - Mark

    @Test func blockedSpacesAreCountedAndBeatEverything() {
        let tile = indicator([.blocked, .done, .working, .blocked, .idle])
        #expect(tile.mark == .attention(count: 2))
        #expect(tile.accessibilityLabel == "Work, 2 spaces need your input, 1 space finished, 1 space working")
    }

    @Test func oneBlockedSpaceReadsInTheSingular() {
        #expect(indicator([.blocked]).accessibilityLabel == "Work, 1 space needs your input")
    }

    @Test func doneShowsOnlyWhenNothingIsBlocked() {
        #expect(indicator([.done, .working]).mark == .done)
        #expect(indicator([.done, .blocked]).mark == .attention(count: 1))
    }

    @Test func workingShowsOnlyWhenNothingIsBlockedOrDone() {
        #expect(indicator([.working, .idle]).mark == .working)
        #expect(indicator([.working, .done]).mark == .done)
    }

    @Test(arguments: [[AgentStatus.idle], [.unknown], [.idle, .unknown], []])
    func idleAndUnknownDrawNothing(statuses: [AgentStatus]) {
        let tile = indicator(statuses)
        #expect(tile.mark == nil)
        #expect(tile.accessibilityLabel == "Work")
    }

    @Test func aStatusIsCountedPerSpaceNotPerPane() {
        // Two panes in one space fold to one status before they get here.
        let state = WorkspaceListState(
            workspaces: [Workspace(id: "w1", number: 1, label: "", agentStatus: .idle)],
            panes: [
                "w1:p1": PaneSummary(workspaceID: "w1", agentStatus: .blocked),
                "w1:p2": PaneSummary(workspaceID: "w1", agentStatus: .blocked),
            ],
            focusedID: "w1"
        )
        let tile = TileIndicator(displayName: "Work", sessionName: "work", state: state, connection: .live)
        #expect(tile.mark == .attention(count: 1))
    }

    // MARK: - Connection

    @Test func aLiveTileIsNotDimmedAndNamesTheSession() {
        let tile = indicator([.working])
        #expect(!tile.isDimmed)
        #expect(tile.tooltip == "work")
    }

    @Test(arguments: [
        (WorkspaceStore.ConnectionState.idle, "Connecting…"),
        (.connecting, "Connecting…"),
        (.sessionNotRunning, "Session not running"),
        (.reconnecting(.streamEnded), "Reconnecting… herdr closed the connection."),
        (.reconnecting(.unexpected("boom")), "Reconnecting… boom"),
    ])
    func aTileThatIsNotLiveIsDimmedAndSaysWhy(connection: WorkspaceStore.ConnectionState, text: String) {
        let tile = indicator([.blocked], connection: connection)
        #expect(tile.isDimmed)
        #expect(tile.tooltip == text)
        #expect(tile.mark == .attention(count: 1), "the last known state is still shown, dimmed")
        #expect(tile.accessibilityLabel.hasSuffix(text.lowercased()))
    }

    @Test func aFailedRequestUsesItsOwnDescription() {
        let error = PaddockError.herdrTimeout(method: .sessionSnapshot)
        #expect(TileIndicator.text(for: .reconnecting(.failed(error))) == "Reconnecting… \(error.errorDescription!)")
    }

    @Test func anotherProtocolIsConnectedButSaysSo() {
        let tile = indicator([], connection: .unsupportedProtocol(42))
        #expect(!tile.isDimmed, "still connected and usable")
        #expect(tile.tooltip == "herdr protocol 42; expected \(HerdrProtocol.supported)")
    }

    @Test func aTabWithoutAStoreShowsNothing() {
        let tile = TileIndicator.none(displayName: "Work", sessionName: "work")
        #expect(tile.mark == nil)
        #expect(!tile.isDimmed)
        #expect(tile.tooltip == "work")
        #expect(tile.accessibilityLabel == "Work")
    }
}
