import Foundation

/// The supervising loop: one attempt at a time, for ever, with a backoff
/// between failures. Split from the store's public surface because none of it
/// is anybody else's business — the column only ever reads `state` and
/// `connection`.
extension WorkspaceStore {
    /// Above this many reconnects in a row without a single event in between,
    /// the store stops treating a subscription change as free and starts
    /// waiting out the backoff — a pane set that keeps changing between the
    /// subscribe and the snapshot must not become a hot loop.
    static let maximumImmediateResubscribes = 5

    /// The error code herdr answers `events.subscribe` with when one of the
    /// `pane_id`s is gone (verified against herdr 0.8.0).
    static let paneNotFoundCode = "pane_not_found"

    /// Why one connection attempt ended.
    enum SessionOutcome: Equatable, Sendable {
        /// herdr closed the socket — the session stopped, or the daemon
        /// restarted. Not an error: the stream ends cleanly.
        case streamEnded
        /// The pane set changed, so the events connection has to be reopened
        /// with a new subscription list. Costs no backoff.
        case resubscribe
    }

    /// Attempts, waits, attempts again, until the task is cancelled.
    func supervise() async {
        while !Task.isCancelled {
            do {
                switch try await runOneConnection() {
                case .resubscribe:
                    consecutiveResubscribes += 1
                    guard consecutiveResubscribes > Self.maximumImmediateResubscribes else { continue }
                    // The penalty is paid once; the next round is free again.
                    consecutiveResubscribes = 0
                case .streamEnded:
                    guard !Task.isCancelled else { return }
                    setConnection(.reconnecting(lastError: Self.streamEndedMessage))
                }
            } catch {
                guard !Task.isCancelled else { return }
                setConnection(Self.connectionState(for: error))
            }
            guard !Task.isCancelled else { return }
            // Not `try?`: swallowing cancellation here would keep a stopped
            // store reconnecting.
            do { try await Task.sleep(for: .seconds(backoff.next())) } catch { return }
        }
    }

    private static let streamEndedMessage = "herdr closed the connection."

    /// One full attempt: ping, subscribe, snapshot, then reduce events until
    /// the stream ends or the subscription list goes stale.
    private func runOneConnection() async throws -> SessionOutcome {
        setConnection(.connecting)

        // The socket has no handshake, so `ping` doubles as the reachability
        // check: a session that is not running fails here with
        // `herdrSocketUnavailable` before any state is touched.
        let ping: PingResult = try await client.request("ping")
        let connected: WorkspaceStore.ConnectionState = ping.protocolVersion == HerdrProtocol.supported
            ? .live
            : .unsupportedProtocol(ping.protocolVersion)

        // Subscribe *before* snapshotting: events that fire in between are
        // buffered by the stream and applied on top of the snapshot, so
        // nothing is missed. (herdr also replays a historical backlog right
        // after the ack; the reducer is built to distrust it.)
        let opened = try await openEvents(Self.subscriptions(for: state))
        try await refreshFromSnapshot()

        // The snapshot is authoritative and may know panes the subscribe did
        // not cover. Their status would never arrive, so reopen at once.
        guard Self.subscriptions(for: state) == opened.subscriptions else { return .resubscribe }

        backoff.reset()
        setConnection(connected)

        for try await event in opened.stream {
            // Reaching the stream at all means the previous immediate
            // reconnects were productive.
            consecutiveResubscribes = 0
            let outcome = reduce(event)
            guard outcome.contains(.resubscribe),
                  Self.subscriptions(for: state) != opened.subscriptions
            else { continue }
            // Breaking out drops the stream, which shuts the socket down.
            return .resubscribe
        }
        return .streamEnded
    }

    /// Subscribes, retrying once against a fresh snapshot if herdr rejects a
    /// pane id — the list was built from a snapshot that has since gone stale,
    /// and a second rejection is a real failure worth backing off from.
    ///
    /// Returns the list that was actually accepted, so the caller can compare
    /// it against the one the snapshot implies.
    private func openEvents(
        _ requested: [HerdrSubscription]
    ) async throws -> (stream: AsyncThrowingStream<HerdrEvent, Error>, subscriptions: [HerdrSubscription]) {
        do {
            return (try await client.events(requested), requested)
        } catch let error as PaddockError {
            guard case let .herdrRPC(_, code, _) = error, code == Self.paneNotFoundCode else { throw error }
            try await refreshFromSnapshot()
            let retried = Self.subscriptions(for: state)
            return (try await client.events(retried), retried)
        }
    }

    // MARK: - Pure helpers

    /// Everything one session has to listen to: the workspace kinds that keep
    /// the rows right, the global pane kinds that say the pane set moved, and
    /// one `pane.agent_status_changed` per pane — the only place agent status
    /// ever arrives.
    ///
    /// Deterministic (panes come from `state.paneIDs`, which is sorted) so the
    /// loop can compare two lists to decide whether reconnecting is worth it.
    nonisolated static func subscriptions(for state: WorkspaceListState) -> [HerdrSubscription] {
        HerdrSubscription.workspaceKinds
            + HerdrSubscription.paneKinds
            + state.paneIDs.map { .paneAgentStatusChanged(paneID: $0) }
    }

    /// How a failed attempt reads in the footer.
    ///
    /// A missing socket is the ordinary case, not a fault: the session simply
    /// has not been started, and it gets its own state so the column can say
    /// so instead of showing a POSIX message.
    nonisolated static func connectionState(for error: Error) -> ConnectionState {
        if let paddock = error as? PaddockError, case .herdrSocketUnavailable = paddock {
            return .sessionNotRunning
        }
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return .reconnecting(lastError: message)
    }

    /// The reconnect schedule, in seconds: 0.5, 1, 2, 4, then 5 for ever.
    ///
    /// A value type with no clock of its own so the sequence is testable
    /// without waiting for it. `reset()` runs after every successful snapshot,
    /// so a session that flaps recovers as fast as one that never failed.
    struct Backoff: Equatable, Sendable {
        static let first = 0.5
        static let cap = 5.0

        private var pending = Backoff.first

        init() {}

        mutating func next() -> Double {
            defer { pending = min(pending * 2, Self.cap) }
            return pending
        }

        mutating func reset() {
            pending = Self.first
        }
    }
}
