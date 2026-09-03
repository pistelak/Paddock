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

    /// The floor between the *starts* of two connection attempts, whatever
    /// ended the previous one.
    ///
    /// A pure safety net. Nothing should be able to reconnect in a tight loop
    /// any more — only a snapshot can change the pane set, and no event is
    /// applied at all — but every subscribe replays a backlog and costs herdr a
    /// stream, so a bug that does slip through must degrade to one stream per
    /// second instead of the ~11k-per-run hot loop that was observed. It
    /// applies across `restart()` too.
    static let minimumTimeBetweenConnections: Duration = .seconds(1)

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
            guard await waitForConnectionSlot() else { return }
            let clock = self.clock
            lastConnectionStart = Self.now(of: clock)
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
            do { try await clock.sleep(for: .seconds(backoff.next())) } catch { return }
        }
    }

    private static let streamEndedMessage = "herdr closed the connection."

    /// Sleeps out whatever is left of `minimumTimeBetweenConnections` since the
    /// previous attempt started. Returns `false` if the task was cancelled
    /// while waiting, so the caller stops instead of connecting anyway.
    private func waitForConnectionSlot() async -> Bool {
        let clock = self.clock
        let remaining = remainingConnectionFloor(on: clock)
        guard remaining > .zero else { return true }
        // Not `try?`: swallowing cancellation here would keep a stopped store
        // reconnecting.
        do { try await clock.sleep(for: remaining) } catch { return false }
        return !Task.isCancelled
    }

    /// The existential `clock` is opened into a concrete `C` here so the stored
    /// instant can be compared with the clock's own `now`; an instant from
    /// another clock (there is none) would simply read as "no floor".
    private func remainingConnectionFloor<C: Clock<Duration>>(on clock: C) -> Duration {
        guard let last = lastConnectionStart as? C.Instant else { return .zero }
        return Self.minimumTimeBetweenConnections - last.duration(to: clock.now)
    }

    /// One full attempt: ping, subscribe, snapshot, then let the stream ask for
    /// further snapshots until it ends.
    ///
    /// **Ordering.** Subscribing has to come first, or a change made between
    /// the snapshot and the subscribe would go unnoticed until the next one.
    /// Events that arrive while the snapshot is in flight are not lost and not
    /// a problem either: the stream buffers them, and reading one afterwards
    /// only asks for another snapshot — one request, and it cannot regress the
    /// rows, because no event is ever applied. That is the whole reason herdr's
    /// unmarked, stale backlog replay is harmless here; see
    /// `WorkspaceEventPolicy`.
    private func runOneConnection() async throws -> SessionOutcome {
        setConnection(.connecting)

        // The socket has no handshake, so `ping` doubles as the reachability
        // check: a session that is not running fails here with
        // `herdrSocketUnavailable` before any state is touched.
        let ping: PingResult = try await transport.request(.ping)
        let connected: WorkspaceStore.ConnectionState = ping.protocolVersion == HerdrProtocol.supported
            ? .live
            : .unsupportedProtocol(ping.protocolVersion)

        let opened = try await openEvents(Self.subscriptions(for: state))
        // A stream that never gets an iterator keeps its socket open for
        // ever: the reader only stops through termination. Every exit before
        // the loop below has to end it by hand.
        var isConsumed = false
        defer { if !isConsumed { opened.discard() } }
        try await refreshFromSnapshot()

        // The stream was opened for the pane set of an older snapshot. Reopen
        // it for this one, or a pane it does not cover would never report its
        // agent status — herdr allows one request per connection, so a
        // subscription cannot be added to a live stream.
        guard Self.subscriptions(for: state) == opened.subscriptions else { return .resubscribe }
        // Getting this far means the previous immediate reconnects were
        // productive: the pane set held still long enough to connect on it.
        consecutiveResubscribes = 0
        backoff.reset()
        setConnection(connected)

        isConsumed = true
        return try await follow(opened)
    }

    /// The event loop of one connection. Nothing runs concurrently here: the
    /// snapshot was awaited, then the loop reads events and hands each to
    /// `handle(_:)`, which asks the resync pump for a snapshot. A quiet
    /// session parks in `next()` for ever, which is fine — `connection` and
    /// the rows were both settled by the snapshot before the loop started, and
    /// the subscription list is re-checked by every resync, not by this loop.
    private func follow(_ opened: OpenedEvents) async throws -> SessionOutcome {
        for try await kind in opened.stream {
            handle(kind)
        }
        return .streamEnded
    }

    /// A subscribed events connection: the stream, and the list herdr actually
    /// accepted — which is not always the list that was asked for.
    struct OpenedEvents: Sendable {
        let stream: AsyncThrowingStream<HerdrEventKind, Error>
        let subscriptions: [HerdrSubscription]

        /// Ends a stream nobody is going to iterate. Termination — which is
        /// what shuts the socket down — only happens through an iterator, so
        /// one is created and cancelled on the spot: `next()` on an already
        /// cancelled task terminates the stream before reading anything.
        func discard() {
            let stream = stream
            Task.detached { for try await _ in stream {} }.cancel()
        }
    }

    /// Subscribes, retrying once against a fresh snapshot if herdr rejects a
    /// pane id — the list was built from a snapshot that has since gone stale,
    /// and a second rejection is a real failure worth backing off from.
    private func openEvents(_ requested: [HerdrSubscription]) async throws -> OpenedEvents {
        do {
            return OpenedEvents(stream: try await transport.events(requested), subscriptions: requested)
        } catch let error as PaddockError {
            guard case let .herdrRPC(_, code, _) = error, code == Self.paneNotFoundCode else { throw error }
            try await refreshFromSnapshot()
            let retried = Self.subscriptions(for: state)
            return OpenedEvents(stream: try await transport.events(retried), subscriptions: retried)
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
