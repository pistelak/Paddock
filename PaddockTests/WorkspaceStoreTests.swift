import Foundation
import Testing
@testable import Paddock

/// Covers the parts of the store that are pure: the subscription list it
/// builds from a state, the reconnect schedule and the error-to-footer
/// mapping. `HerdrSocketClient` is an actor with no protocol seam on purpose,
/// so the socket itself is exercised by `WorkspaceStoreLiveTests` against a
/// real herdr instead of by a mock that would only assert its own fiction.
///
/// The one behavioural test here needs no herdr: a socket path that does not
/// exist fails immediately with `ENOENT`, which is exactly the "session not
/// running" path the column has to draw.
struct WorkspaceStoreTests {
    // MARK: - Fixtures

    private func ws(_ id: String, number: Int = 1) -> WorkspaceInfo {
        WorkspaceInfo(
            workspaceID: id,
            number: number,
            label: id.uppercased(),
            focused: false,
            paneCount: 1,
            tabCount: 1,
            activeTabID: "t-\(id)",
            agentStatus: .idle
        )
    }

    private func pane(_ id: String, in workspaceID: String) -> PaneInfo {
        PaneInfo(paneID: id, workspaceID: workspaceID, tabID: "t-\(workspaceID)", agentStatus: .idle, focused: false)
    }

    // MARK: - Subscriptions

    @Test func subscriptionsForAnEmptyStateAreTheGlobalKindsOnly() {
        let subscriptions = WorkspaceStore.subscriptions(for: WorkspaceListState())
        #expect(subscriptions == HerdrSubscription.workspaceKinds + HerdrSubscription.paneKinds)
    }

    @Test func subscriptionsAddOnePerPaneInSortedOrder() {
        let state = WorkspaceListState(
            workspaces: [ws("w1"), ws("w2", number: 2)],
            panes: [pane("p3", in: "w2"), pane("p1", in: "w1"), pane("p2", in: "w1")]
        )
        let subscriptions = WorkspaceStore.subscriptions(for: state)

        #expect(Array(subscriptions.suffix(3)) == [
            .paneAgentStatusChanged(paneID: "p1"),
            .paneAgentStatusChanged(paneID: "p2"),
            .paneAgentStatusChanged(paneID: "p3"),
        ])
        #expect(
            subscriptions.count
                == HerdrSubscription.workspaceKinds.count + HerdrSubscription.paneKinds.count + 3
        )
    }

    /// The loop compares two lists to decide whether to reconnect, so the same
    /// pane set must always produce the very same array — however the panes
    /// happened to be inserted.
    @Test func subscriptionsAreStableAcrossInsertionOrder() {
        let first = WorkspaceListState(
            workspaces: [ws("w1")],
            panes: [pane("b", in: "w1"), pane("a", in: "w1")]
        )
        let second = WorkspaceListState(
            workspaces: [ws("w1")],
            panes: [pane("a", in: "w1"), pane("b", in: "w1")]
        )
        #expect(WorkspaceStore.subscriptions(for: first) == WorkspaceStore.subscriptions(for: second))
    }

    /// A workspace with no panes still gets a row; it just has no per-pane
    /// subscription to add.
    @Test func workspacesWithoutPanesAddNoSubscriptions() {
        let state = WorkspaceListState(workspaces: [ws("w1")], panes: [])
        #expect(
            WorkspaceStore.subscriptions(for: state)
                == HerdrSubscription.workspaceKinds + HerdrSubscription.paneKinds
        )
    }

    // MARK: - Backoff

    @Test func backoffDoublesToAFiveSecondCap() {
        var backoff = WorkspaceStore.Backoff()
        let schedule = (0 ..< 7).map { _ in backoff.next() }
        #expect(schedule == [0.5, 1, 2, 4, 5, 5, 5])
    }

    @Test func resetReturnsToTheFirstDelay() {
        var backoff = WorkspaceStore.Backoff()
        _ = backoff.next()
        _ = backoff.next()
        _ = backoff.next()
        backoff.reset()
        #expect(backoff.next() == 0.5)
        #expect(backoff.next() == 1)
    }

    @Test func aFreshBackoffEqualsAResetOne() {
        var used = WorkspaceStore.Backoff()
        for _ in 0 ..< 10 { _ = used.next() }
        used.reset()
        #expect(used == WorkspaceStore.Backoff())
    }

    // MARK: - Connection state from errors

    @Test func aMissingSocketReadsAsSessionNotRunning() {
        let error = PaddockError.herdrSocketUnavailable(path: "/nope/herdr.sock")
        #expect(WorkspaceStore.connectionState(for: error) == .sessionNotRunning)
    }

    @Test func anRPCErrorReadsAsReconnectingWithItsMessage() {
        let error = PaddockError.herdrRPC(method: "ping", code: "invalid_request", message: "nope")
        guard case let .reconnecting(message) = WorkspaceStore.connectionState(for: error) else {
            Issue.record("expected .reconnecting")
            return
        }
        #expect(message.contains("nope"), Comment(rawValue: message))
    }

    @Test func aTimeoutReadsAsReconnecting() {
        let state = WorkspaceStore.connectionState(for: PaddockError.herdrTimeout(method: "session.snapshot"))
        guard case let .reconnecting(message) = state else {
            Issue.record("expected .reconnecting")
            return
        }
        #expect(!message.isEmpty)
    }

    /// A decoding failure is a real fault but still only a reconnect: the rows
    /// stay on screen and the next snapshot may well decode.
    @Test func aNonPaddockErrorStillReadsAsReconnecting() {
        struct Boom: Error {}
        guard case .reconnecting = WorkspaceStore.connectionState(for: Boom()) else {
            Issue.record("expected .reconnecting")
            return
        }
    }

    @Test func onlyConnectedStatesCountAsConnected() {
        #expect(WorkspaceStore.ConnectionState.live.isConnected)
        #expect(WorkspaceStore.ConnectionState.unsupportedProtocol(3).isConnected)
        #expect(!WorkspaceStore.ConnectionState.idle.isConnected)
        #expect(!WorkspaceStore.ConnectionState.connecting.isConnected)
        #expect(!WorkspaceStore.ConnectionState.sessionNotRunning.isConnected)
        #expect(!WorkspaceStore.ConnectionState.reconnecting(lastError: "x").isConnected)
    }

    // MARK: - Lifecycle

    @MainActor
    private func makeStore() throws -> WorkspaceStore {
        let name = try SessionName("nonexistent")
        return WorkspaceStore(
            sessionName: name,
            socketPath: NSTemporaryDirectory() + "paddock-absent-\(UUID().uuidString).sock"
        )
    }

    @MainActor
    @Test func aFreshStoreIsIdleAndEmpty() throws {
        let store = try makeStore()
        #expect(store.connection == .idle)
        #expect(store.state.workspaces.isEmpty)
        // Stopping something that never started is a no-op, so a coordinator
        // can stop unconditionally.
        store.stop()
        #expect(store.connection == .idle)
    }

    @MainActor
    @Test func aMissingSocketEndsUpInSessionNotRunningAndNotifiesOnce() async throws {
        let store = try makeStore()
        var notifications = 0
        store.onChange = { notifications += 1 }

        store.start()
        store.start() // idempotent: a second call must not open a second loop
        try await waitUntil { store.connection == .sessionNotRunning }

        #expect(notifications > 0, "the footer has to hear about the failure")
        #expect(store.state.workspaces.isEmpty)

        store.stop()
        #expect(store.connection == .idle)
        let afterStop = notifications
        try await Task.sleep(for: .milliseconds(300))
        #expect(notifications == afterStop, "no onChange may fire after stop()")
    }

    /// `retryNow()` on a store that was never started must not start one:
    /// the coordinator drives the lifecycle, the surface only nudges it.
    @MainActor
    @Test func retryNowDoesNothingWhileStopped() async throws {
        let store = try makeStore()
        store.retryNow()
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.connection == .idle)
    }

    @MainActor
    @Test func aStoppedStoreCanBeStartedAgain() async throws {
        let store = try makeStore()
        store.start()
        try await waitUntil { store.connection == .sessionNotRunning }
        store.stop()

        store.start()
        try await waitUntil { store.connection == .sessionNotRunning }
    }

    /// Polls on the main actor rather than using an expectation, because the
    /// store only ever mutates there.
    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(5),
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("condition not met within \(timeout)", sourceLocation: sourceLocation)
    }
}
