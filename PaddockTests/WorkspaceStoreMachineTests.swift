import Foundation
import Testing
@testable import Paddock

/// The connection machine, driven offline: a `ScriptedHerdr` answers the
/// store's requests and pushes events, a `ManualClock` stands in for every
/// wait. What used to take a live herdr and twenty-second polls is a
/// millisecond here; the live suites keep what only a real herdr can prove.
///
/// Two clocks are in play and they are orthogonal. `ManualClock` measures
/// durations the store waits out (backoff, retry pause, coalescing floor).
/// `waitUntil` polls the wall clock briefly so the test can let the store's
/// tasks *reach* a state before asserting on it or advancing time past it.
@MainActor
struct WorkspaceStoreMachineTests {
    private let clock = ManualClock()

    // MARK: - Connecting

    @Test func connectsSubscribesAndTakesASnapshot() async throws {
        let (herdr, store) = try await ScriptedHerdr.connectable(clock: clock)
        store.start()
        defer { store.stop() }
        try await waitUntil { store.connection == .live }

        #expect(store.state.workspaces.map(\.id) == ["w1"])
        #expect(store.state.focusedID == "w1")
        let requests = await herdr.requests
        #expect(requests == [.ping, .sessionSnapshot], "ping, then subscribe, then one snapshot")
        let subscriptions = await herdr.subscriptions
        #expect(subscriptions == [HerdrSubscription.workspaceKinds + HerdrSubscription.paneKinds])
    }

    @Test func anotherProtocolVersionIsConnectedWithAWarning() async throws {
        let (herdr, store) = try await ScriptedHerdr.connectable(clock: clock)
        await herdr.alwaysReply(to: .ping, with: ScriptedHerdr.pongOtherProtocol)
        store.start()
        defer { store.stop() }
        try await waitUntil { store.connection.isConnected }
        #expect(store.connection == .unsupportedProtocol(42))
        #expect(!store.state.workspaces.isEmpty, "rows still arrive")
    }

    @Test func aMissingSocketIsSessionNotRunningAndRetriesOnTheBackoff() async throws {
        let (herdr, store) = try await ScriptedHerdr.connectable(clock: clock)
        await herdr.fail(.ping, with: PaddockError.herdrSocketUnavailable(path: "/x"))
        store.start()
        defer { store.stop() }
        try await waitUntil { store.connection == .sessionNotRunning }

        // The supervisor is asleep on the first backoff step; nothing else is.
        try await waitUntil { clock.pendingSleepers == 1 }
        #expect(await herdr.requestCount(of: .ping) == 1)
        clock.advance(by: .seconds(0.5))
        // The connection floor (1 s since the first attempt) still has to pass.
        try await waitUntil { clock.pendingSleepers == 1 }
        clock.advance(by: .seconds(0.5))
        try await waitUntil { store.connection == .live }
        #expect(await herdr.requestCount(of: .ping) == 2)
    }

    // MARK: - Events

    /// A burst of events costs one snapshot now and exactly one more once the
    /// floor has passed — never one per event, and never zero for the events
    /// that landed while the first snapshot was in flight. The first snapshot
    /// is held open by the fake so the burst provably arrives *during* it.
    @Test func aBurstDuringAnInFlightSnapshotCostsExactlyOneTrailingRefetch() async throws {
        let (herdr, store) = try await ScriptedHerdr.connectable(clock: clock)
        store.start()
        defer { store.stop() }
        try await waitUntil { store.connection == .live }
        // Put the connection's own snapshot outside the coalescing window.
        clock.advance(by: .seconds(1))

        await herdr.gate(.sessionSnapshot)
        await herdr.emit("workspace_focused")
        try await waitUntil { await herdr.heldRequestCount == 1 }
        #expect(await herdr.requestCount(of: .sessionSnapshot) == 2, "the leading edge refetched at once")

        // Delivered straight to the store on the main actor — the same call the
        // event loop makes — so all twenty are provably handled *while* the
        // gated snapshot is in flight, not merely queued on the stream.
        for _ in 0 ..< 20 {
            store.handle(HerdrEventKind(wire: "workspace_renamed"))
        }
        await herdr.release(.sessionSnapshot)

        // The pump now owes one trailing refetch and is waiting out the floor.
        try await waitUntil { clock.pendingSleepers == 1 }
        #expect(await herdr.requestCount(of: .sessionSnapshot) == 2, "nothing more until the floor passes")
        clock.advance(by: WorkspaceStore.minimumSnapshotInterval)
        try await waitUntil { await herdr.requestCount(of: .sessionSnapshot) == 3 }

        // And that is all: twenty events, one trailing snapshot.
        clock.advance(by: .seconds(5))
        try await waitUntil { clock.pendingSleepers == 0 }
        #expect(await herdr.requestCount(of: .sessionSnapshot) == 3)
    }

    /// Events outside any window refetch straight away, one snapshot each.
    @Test func eventsSpacedBeyondTheFloorEachRefetchImmediately() async throws {
        let (herdr, store) = try await ScriptedHerdr.connectable(clock: clock)
        store.start()
        defer { store.stop() }
        try await waitUntil { store.connection == .live }

        for round in 1 ... 3 {
            clock.advance(by: .seconds(1))
            await herdr.emit("workspace_focused")
            try await waitUntil { await herdr.requestCount(of: .sessionSnapshot) == 1 + round }
        }
        #expect(clock.pendingSleepers == 0, "no trailing refetch owed")
    }

    @Test func unsubscribedKindsDoNotRefetch() async throws {
        let (herdr, store) = try await ScriptedHerdr.connectable(clock: clock)
        store.start()
        defer { store.stop() }
        try await waitUntil { store.connection == .live }
        clock.advance(by: .seconds(1))

        await herdr.emit("tab_created")
        await herdr.emit("session_renamed")
        try await Task.sleep(for: .milliseconds(50))
        #expect(await herdr.requestCount(of: .sessionSnapshot) == 1)
    }

    // MARK: - Failures

    /// The defect this suite was written for: snapshots failing while the
    /// stream is still up used to leave a stale state under a connection that
    /// said nothing. Now the third failure ends the connection, `connection`
    /// says reconnecting, and the reconnect's own snapshot puts things right.
    @Test func repeatedSnapshotFailuresReconnectInsteadOfGoingQuiet() async throws {
        let (herdr, store) = try await ScriptedHerdr.connectable(clock: clock)
        var seen: [WorkspaceStore.ConnectionState] = []
        let observation = store.observe { seen.append(store.connection) }
        defer { observation.cancel() }
        store.start()
        defer { store.stop() }
        try await waitUntil { store.connection == .live }
        clock.advance(by: .seconds(1))

        for _ in 0 ..< WorkspaceStore.maximumSnapshotFailures {
            await herdr.fail(.sessionSnapshot, with: PaddockError.herdrTimeout(method: .sessionSnapshot))
        }
        await herdr.emit("workspace_renamed")

        // Two pauses between three failures.
        for _ in 0 ..< (WorkspaceStore.maximumSnapshotFailures - 1) {
            try await waitUntil { clock.pendingSleepers == 1 }
            clock.advance(by: WorkspaceStore.snapshotFailurePause)
        }
        try await waitUntil { seen.contains { if case .reconnecting = $0 { true } else { false } } }
        try await waitUntil { store.connection == .live }

        #expect(await herdr.subscriptions.count == 2, "a fresh events connection was opened")
        #expect(store.state.workspaces.map(\.id) == ["w1"], "and its snapshot landed")
        let failures = await herdr.requestCount(of: .sessionSnapshot)
        #expect(failures == 1 + WorkspaceStore.maximumSnapshotFailures + 1)
    }

    @Test func aStreamThatEndsReconnectsOnTheBackoff() async throws {
        let (herdr, store) = try await ScriptedHerdr.connectable(clock: clock)
        store.start()
        defer { store.stop() }
        try await waitUntil { store.connection == .live }

        await herdr.endStreams()
        try await waitUntil { store.connection == .reconnecting(.streamEnded) }
        #expect(store.state.workspaces.map(\.id) == ["w1"], "rows survive, dimmed")

        // Backoff 0.5 s, then the 1 s connection floor from the first attempt.
        try await waitUntil { clock.pendingSleepers == 1 }
        clock.advance(by: .seconds(0.5))
        try await waitUntil { clock.pendingSleepers == 1 }
        clock.advance(by: .seconds(0.5))
        try await waitUntil { store.connection == .live }
        #expect(await herdr.subscriptions.count == 2)
    }

    // MARK: - Subscriptions

    @Test func aRejectedPaneIsRetriedOnceAgainstAFreshSnapshot() async throws {
        let (herdr, store) = try await ScriptedHerdr.connectable(clock: clock)
        await herdr.onSubscribe(.reject(code: WorkspaceStore.paneNotFoundCode))
        store.start()
        defer { store.stop() }
        try await waitUntil { store.connection == .live }

        let subscriptions = await herdr.subscriptions
        #expect(subscriptions.count == 2, "rejected once, then accepted")
        let requests = await herdr.requests
        #expect(requests == [.ping, .sessionSnapshot, .sessionSnapshot], "a snapshot between the two subscribes")
    }

    @Test func anyOtherSubscribeRejectionIsAFailure() async throws {
        let (herdr, store) = try await ScriptedHerdr.connectable(clock: clock)
        await herdr.onSubscribe(.reject(code: "invalid_request"))
        store.start()
        defer { store.stop() }
        try await waitUntil { if case .reconnecting = store.connection { true } else { false } }
        #expect(await herdr.subscriptions.count == 1, "no retry for a rejection that is not pane_not_found")
    }

    /// The snapshot showed a pane the subscription does not cover, so the
    /// connection is reopened with the full list — and that costs no backoff,
    /// only the connection floor.
    @Test func aPaneSetTheSubscriptionDoesNotCoverResubscribes() async throws {
        let (herdr, store) = try await ScriptedHerdr.connectable(clock: clock)
        await herdr.alwaysReply(
            to: .sessionSnapshot,
            with: ScriptedHerdr.snapshot(
                workspaces: [("w1", 1, "code", true)],
                panes: [("w1:p1", "w1", "working")]
            )
        )
        store.start()
        defer { store.stop() }

        // First attempt: subscribe without panes, snapshot shows p1 → resubscribe,
        // which waits out the floor, not the backoff.
        try await waitUntil { clock.pendingSleepers == 1 }
        #expect(store.connection == .connecting, "not reported as a failure")
        clock.advance(by: WorkspaceStore.minimumTimeBetweenConnections)
        try await waitUntil { store.connection == .live }

        let subscriptions = await herdr.subscriptions
        #expect(subscriptions.count == 2)
        #expect(subscriptions.last?.contains(.paneAgentStatusChanged(paneID: "w1:p1")) == true)
        #expect(store.state.status(of: "w1") == .working)
    }

    // MARK: - Lifecycle

    @Test func stopIsQuietAndAStoppedStoreKeepsItsRows() async throws {
        let (herdr, store) = try await ScriptedHerdr.connectable(clock: clock)
        var notifications = 0
        let observation = store.observe { notifications += 1 }
        defer { observation.cancel() }
        store.start()
        try await waitUntil { store.connection == .live }

        store.stop()
        #expect(store.connection == .idle)
        let afterStop = notifications
        await herdr.emit("workspace_focused")
        await herdr.endStreams()
        clock.advance(by: .seconds(10))
        try await Task.sleep(for: .milliseconds(50))
        #expect(notifications == afterStop, "no observer is called after stop()")
        #expect(store.state.workspaces.map(\.id) == ["w1"], "rows are kept for the next start")
    }

    @Test func observersAreCalledAtMostOncePerTurn() async throws {
        let (_, store) = try await ScriptedHerdr.connectable(clock: clock)
        var notifications = 0
        let observation = store.observe { notifications += 1 }
        defer { observation.cancel() }
        store.start()
        defer { store.stop() }
        try await waitUntil { store.connection == .live }
        // connecting → (snapshot applied) → live all happened within a couple
        // of turns; what matters is that it was not one call per mutation.
        #expect((1 ... 2).contains(notifications), "three mutations, one or two turns")
    }

    // MARK: - Observation

    /// Two views may watch one store, and letting go of a token is enough to
    /// stop being told — nobody clears anybody else's closure.
    @Test func anyNumberOfObserversAndEachTokenStandsAlone() async throws {
        let (herdr, store) = try await ScriptedHerdr.connectable(clock: clock)
        var first = 0
        var second = 0
        let firstToken = store.observe { first += 1 }
        var secondToken: ObservationToken? = store.observe { second += 1 }
        defer { firstToken.cancel() }
        #expect(store.observerCount == 2)

        store.start()
        defer { store.stop() }
        try await waitUntil { store.connection == .live }
        #expect(first >= 1)
        #expect(second == first, "both heard the same rounds")

        secondToken = nil
        try await waitUntil { store.observerCount == 1 }
        let secondBefore = second
        clock.advance(by: .seconds(1))
        await herdr.alwaysReply(to: .sessionSnapshot, with: ScriptedHerdr.snapshot(workspaces: [("w1", 1, "renamed", true)]))
        await herdr.emit("workspace_renamed")
        try await waitUntil { store.state.workspaces.first?.label == "renamed" }
        try await waitUntil { first > secondBefore }
        #expect(second == secondBefore, "a dropped token hears nothing more")
    }

    @Test func cancellingATokenTwiceIsHarmless() async throws {
        let (_, store) = try await ScriptedHerdr.connectable(clock: clock)
        let token = store.observe {}
        token.cancel()
        token.cancel()
        #expect(store.observerCount == 0)
    }

    // MARK: - Helpers

    private func waitUntil(
        timeout: Duration = .seconds(5),
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: @MainActor () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("condition not met within \(timeout)", sourceLocation: sourceLocation)
    }
}
