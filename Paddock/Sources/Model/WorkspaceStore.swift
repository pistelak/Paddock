import Foundation

/// The live spaces list of one herdr session — what the session tile's
/// indicator is derived from — plus the connection that keeps it current.
///
/// Everything the UI needs is two `private(set)` properties and `observe`:
/// read `state` and `connection`, re-render when told. Notifications are
/// *coalesced* — at most one round per main-actor turn — because herdr's
/// stream is chatty (17 workspace events in 4 s on an idle session during the
/// spike) and every event would otherwise be a render.
///
/// The store owns a supervising `Task` that reconnects for ever: ping, open
/// the events connection, take a `session.snapshot`, then let the stream drive
/// further snapshots until it ends. A dead session is not an error state to
/// recover from by hand — it is just a longer wait between attempts — so
/// `state` is never cleared on failure, so whatever draws it keeps the last
/// known state (the tile dims it: PR B).
///
/// **`session.snapshot` is the only source of state.** No event is ever applied
/// to `state`; events only say *something may have moved* and the store
/// refetches. The reason is herdr's replay: every `events.subscribe` ack is
/// followed by an unmarked historical backlog, paced at one event per 100 ms
/// (measured 2026-09-02 on the `default` session: 89 `workspace_focused` events
/// over 9.1 s), with nothing in the protocol — no cursor, no `seq`, no
/// timestamp, no opt-out — to tell a replayed event from a live one. Replayed
/// content is *stale*, so applying it drags the state back through the session's
/// history; that is what walked the focused pill across the (since removed)
/// spaces column for ten seconds after every connect. Refetching instead is bounded work
/// (`minimumSnapshotInterval`) and always lands on the present.
///
/// **Everything that waits, waits on `clock`.** The reconnect backoff, the
/// pause between snapshot retries, the floor between connection attempts and
/// the coalescing of events into snapshots all take their time from the
/// injected clock, and herdr itself is reached only through `transport`. That
/// is what lets the whole machine be driven through every transition in
/// milliseconds by a scripted peer and a manual clock — the live suites keep
/// the parts only a real herdr can prove.
///
/// **The supervising task retains the store while it runs**, so a store that
/// is started and then dropped without `stop()` stays alive with its socket
/// open. `WorkspaceStoreRegistry` is the only owner and the only caller of
/// `stop()`, so that cannot happen by accident.
@MainActor
final class WorkspaceStore {
    /// What the tile's tooltip says (PR B), and whether the state is stale.
    ///
    /// `unsupportedProtocol` is deliberately a *connected* state: the shapes
    /// Paddock reads are a small, stable subset, so a herdr speaking another
    /// protocol keeps working and only earns a warning. It becomes an error
    /// only if decoding actually fails, which surfaces as `reconnecting`.
    enum ConnectionState: Equatable, Sendable {
        case idle
        case connecting
        case live
        /// Keep the last state (the tile draws it dimmed: PR B), retry on the backoff.
        case reconnecting(ReconnectReason)
        /// No socket at the path: the session has not been started yet.
        case sessionNotRunning
        /// Connected and usable, but `ping` reported another protocol version.
        case unsupportedProtocol(Int)

        /// Whether the state is being kept current right now.
        var isConnected: Bool {
            switch self {
            case .live, .unsupportedProtocol: true
            case .idle, .connecting, .reconnecting, .sessionNotRunning: false
            }
        }
    }

    /// Why a connection is being retried. A model value, not a sentence: the
    /// tile's tooltip (PR B) turns it into words, tests compare cases, and a
    /// later UI can tell a timeout from a rejected request.
    enum ReconnectReason: Equatable, Sendable {
        /// herdr closed the socket — the session stopped or the daemon
        /// restarted. Not a fault.
        case streamEnded
        /// A request failed with one of Paddock's own errors.
        case failed(PaddockError)
        /// Something outside Paddock's vocabulary (a decoding error, a POSIX
        /// error the socket layer did not map); its description is all there is.
        case unexpected(String)
    }

    /// How many snapshot failures in a row the event loop tolerates while the
    /// stream is still up, and the pause between them. The last failure ends
    /// the connection: the supervisor reports `.reconnecting` and tries again
    /// on the backoff, so a herdr that answers events but not snapshots can
    /// never leave a stale state behind a connection that claims to be live.
    static let maximumSnapshotFailures = 3
    static let snapshotFailurePause: Duration = .seconds(1)

    /// The floor between the *starts* of two `session.snapshot` requests, which
    /// is also the window a burst of events coalesces in.
    ///
    /// Leading-edge: the first event after a quiet spell refetches straight
    /// away, so the indicator follows a change in herdr within
    /// about ten milliseconds. Everything that arrives while that snapshot is
    /// in flight, or inside the floor behind it, folds into one trailing
    /// refetch — *guaranteed*, even if no further event ever comes, which is
    /// why this is hand-rolled rather than swift-async-algorithms' `throttle`
    /// (that one only releases a held element when the next element arrives).
    /// herdr's 100 ms backlog replay therefore costs at most four snapshots a
    /// second instead of one per event, and a nine second replay costs ~36
    /// requests that each cost nothing to apply (`WorkspaceListState` is
    /// `Equatable`; an unchanged state is not a render).
    static let minimumSnapshotInterval: Duration = .milliseconds(250)

    let sessionName: SessionName
    let socketPath: String

    private(set) var state = WorkspaceListState()
    private(set) var connection: ConnectionState = .idle

    /// Everyone watching. Called after any change to `state` or `connection`,
    /// coalesced to once per main-actor turn; never after `stop()`.
    private var observers: [UUID: @MainActor () -> Void] = [:]

    let transport: any HerdrTransport
    let clock: any Clock<Duration>

    private var supervisor: Task<Void, Never>?
    private var resync: Task<Void, Never>?
    private var notification: Task<Void, Never>?

    /// Gates every mutation. A cancelled supervisor is not stopped the instant
    /// `stop()` returns — it is still unwinding somewhere between two awaits —
    /// and without this flag its last write would put the store back into
    /// `.reconnecting` and notify observers after the registry let go of it.
    private var isRunning = false

    // Supervisor state. Private: the connection loop lives in this file, and
    // nothing else may reset a backoff or move a floor mid-flight.
    private var backoff = Backoff()
    /// Guards against a pane set that keeps changing between the subscribe and
    /// the snapshot: reconnecting without a pause is only free a few times.
    private var consecutiveResubscribes = 0
    /// When the last connection attempt began, on `clock`, so `supervise()`
    /// can enforce a floor between two of them. Kept on the store rather than
    /// in the loop because `restart()` replaces the loop and the floor has to
    /// survive it. Erased, because the store is not generic over its clock;
    /// the supervisor reads it back through the clock's own instant type.
    private var lastConnectionStart: (any InstantProtocol<Duration>)?

    /// `transport` and `clock` are injectable so a test can drive the store
    /// with a scripted herdr and a manual clock; the app passes neither and
    /// gets the real socket client and `ContinuousClock`.
    init(
        sessionName: SessionName,
        socketPath: String,
        transport: (any HerdrTransport)? = nil,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.sessionName = sessionName
        self.socketPath = socketPath
        self.transport = transport ?? HerdrSocketClient(socketPath: socketPath)
        self.clock = clock
    }

    // MARK: - Lifecycle

    /// Starts connecting, or does nothing if the store is already running.
    func start() {
        guard !isRunning else { return }
        restart()
    }

    /// Cancels every task the store owns and goes back to `.idle`.
    ///
    /// `state` survives, so a stopped store that is started again still has
    /// state to show while it reconnects. No observer is called after this
    /// returns: the coalescing task is cancelled with the rest. Observers
    /// themselves survive, so a store that is started again is still watched.
    func stop() {
        isRunning = false
        // The task itself is kept, cancelled, so that a `start()` right after
        // this waits for it to unwind before opening a second connection.
        supervisor?.cancel()
        resync?.cancel()
        resync = nil
        needsSnapshot = false
        notification?.cancel()
        notification = nil
        isDirty = false
        connection = .idle
    }

    /// Reconnects now instead of waiting out the backoff — what the coordinator
    /// calls when a terminal surface attaches, because that is the moment herdr
    /// itself is starting up.
    ///
    /// A healthy connection is left alone; only the backoff is reset, so the
    /// *next* failure retries quickly.
    func retryNow() {
        backoff.reset()
        guard isRunning, !connection.isConnected else { return }
        restart()
    }

    /// Replaces the supervising task, waiting for the previous one to finish
    /// first so two event connections are never open at once.
    private func restart() {
        isRunning = true
        let previous = supervisor
        previous?.cancel()
        supervisor = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            await self.supervise()
        }
    }

    // MARK: - State

    /// Replaces the state wholesale from an authoritative snapshot.
    ///
    /// `session.snapshot` rather than `workspace.list` because it carries the
    /// panes too, and the panes are the only source of live agent status —
    /// one request instead of two, and no window in which the two disagree.
    @discardableResult
    func refreshFromSnapshot() async throws -> WorkspaceListState {
        // Recorded here rather than in the pump so that *every* snapshot — the
        // connection's first one, the `pane_not_found` retry, a resync — feeds
        // the same rate floor.
        // A local copy: the compiler opens an existential passed as an argument
        // only when it is not a stored-property access.
        let clock = self.clock
        lastSnapshotStart = Self.now(of: clock)
        let result: SessionSnapshotResult = try await transport.request(.sessionSnapshot)
        // The mapper checks the snapshot as well as translating it; a snapshot
        // that contradicts itself is a failed request, never a drawn one.
        apply(try WorkspaceListState(snapshot: result.snapshot))
        return state
    }

    /// The one writer of `state`, and private so it stays that way: every
    /// value it is handed came out of a `session.snapshot`.
    private func apply(_ newState: WorkspaceListState) {
        guard isRunning, newState != state else { return }
        state = newState
        markDirty()
    }

    /// Handles one stream event: at most a request for a fresh snapshot.
    ///
    /// Only the event's kind ever arrives here — see `WorkspaceEventPolicy`
    /// for why a replayed backlog makes ignoring the payload the only safe rule.
    func handle(_ kind: HerdrEventKind) {
        guard WorkspaceEventPolicy.effect(of: kind) == .resync else { return }
        scheduleResync()
    }

    func setConnection(_ newValue: ConnectionState) {
        guard isRunning, newValue != connection else { return }
        connection = newValue
        markDirty()
    }

    // MARK: - Resync

    /// Set by an event, cleared by the snapshot that answers it. The flag —
    /// not a task per event — is what carries the request, so a hundred
    /// replayed events cost one pending snapshot rather than a hundred
    /// cancelled tasks.
    private var needsSnapshot = false

    /// When the most recent `session.snapshot` request went out, on `clock`,
    /// for the rate floor. Set inside `refreshFromSnapshot()`, so every caller
    /// feeds it. Erased like `lastConnectionStart`, and for the same reason.
    private var lastSnapshotStart: (any InstantProtocol<Duration>)?

    /// Records that the world may have moved and makes sure a snapshot
    /// follows: immediately if none has gone out for `minimumSnapshotInterval`,
    /// otherwise as one trailing refetch shared with every other event in the
    /// window.
    ///
    /// If a snapshot turns up panes the current subscription list does not
    /// cover, the events connection is reopened — nothing else would notice,
    /// because the connection loop is parked inside `for try await`.
    func scheduleResync() {
        guard isRunning else { return }
        needsSnapshot = true
        guard resync == nil else { return }
        resync = Task { @MainActor [weak self] in
            await self?.pumpSnapshots()
        }
    }

    /// Snapshots until nothing is pending, one at a time, never faster than
    /// `minimumSnapshotInterval`.
    ///
    /// Clearing `resync` on the way out happens in the same synchronous stretch
    /// as the last `needsSnapshot` check, so an event that arrives after that
    /// check always finds `resync == nil` and starts a fresh pump: no request
    /// can be swallowed by the hand-over.
    ///
    /// **A snapshot that keeps failing ends the connection.** After
    /// `maximumSnapshotFailures` in a row the store reports `.reconnecting`
    /// and restarts, instead of going quiet while `connection` still reads live:
    /// the stream may well be healthy, but a state nobody can refresh is stale,
    /// and a reconnect is the one thing that always ends in a snapshot.
    private func pumpSnapshots() async {
        defer { resync = nil }
        var failures = 0
        while needsSnapshot {
            guard isRunning, !Task.isCancelled else { return }
            guard await waitForSnapshotSlot() else { return }
            // Cleared *before* the request: an event that fires while it is in
            // flight describes a world the answer may predate, so it has to
            // leave another snapshot pending.
            needsSnapshot = false
            let before = WorkspaceStore.subscriptions(for: state)
            do {
                try await refreshFromSnapshot()
            } catch {
                needsSnapshot = true
                failures += 1
                guard failures < Self.maximumSnapshotFailures else {
                    guard isRunning, !Task.isCancelled else { return }
                    setConnection(Self.connectionState(for: error))
                    return restart()
                }
                do { try await clock.sleep(for: Self.snapshotFailurePause) } catch { return }
                continue
            }
            failures = 0
            guard isRunning, !Task.isCancelled else { return }
            guard WorkspaceStore.subscriptions(for: state) == before else { return restart() }
        }
    }

    /// Sleeps out whatever is left of `minimumSnapshotInterval` since the last
    /// snapshot went out. Returns `false` if the store was stopped or the task
    /// cancelled while waiting.
    private func waitForSnapshotSlot() async -> Bool {
        let clock = self.clock
        let remaining = remainingSnapshotFloor(on: clock)
        guard remaining > .zero else { return true }
        // Not `try?`: swallowing cancellation here would snapshot after stop().
        do { try await clock.sleep(for: remaining) } catch { return false }
        return isRunning && !Task.isCancelled
    }

    private func remainingSnapshotFloor<C: Clock<Duration>>(on clock: C) -> Duration {
        guard let last = lastSnapshotStart as? C.Instant else { return .zero }
        return Self.minimumSnapshotInterval - last.duration(to: clock.now)
    }

    /// The existential `clock` opened into a concrete type so its instant can
    /// be stored (erased) and later compared with the same clock's `now`.
    static func now<C: Clock<Duration>>(of clock: C) -> any InstantProtocol<Duration> {
        clock.now
    }

    // MARK: - Observation

    /// Starts telling `body` about changes; stops when the returned token is
    /// cancelled or dropped. As many observers as ask, none of them owning the
    /// store — see `ObservationToken`.
    func observe(_ body: @escaping @MainActor () -> Void) -> ObservationToken {
        let id = UUID()
        observers[id] = body
        return ObservationToken { [weak self] in
            self?.observers[id] = nil
        }
    }

    var observerCount: Int {
        observers.count
    }

    // MARK: - Coalescing

    private var isDirty = false

    /// Requests one round of observer calls on the next main-actor turn. A
    /// burst of 200 events therefore renders once.
    private func markDirty() {
        guard isRunning else { return }
        isDirty = true
        guard notification == nil else { return }
        notification = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.notification = nil
            guard self.isDirty else { return }
            self.isDirty = false
            for observer in self.observers.values {
                observer()
            }
        }
    }
}

// MARK: - Connection loop

/// The supervising loop: one attempt at a time, for ever, with a backoff
/// between failures. Split from the store's public surface because none of it
/// is anybody else's business — the UI only ever reads `state` and
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
                    setConnection(.reconnecting(.streamEnded))
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
    /// state, because no event is ever applied. That is the whole reason herdr's
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
    /// the state were both settled by the snapshot before the loop started, and
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
    /// the spaces right, the global pane kinds that say the pane set moved, and
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

    /// What a failed attempt means.
    ///
    /// A missing socket is the ordinary case, not a fault: the session simply
    /// has not been started, and it gets its own state so the UI can say so
    /// instead of showing a POSIX message. Everything else is a reconnect that
    /// remembers *why*, as a value tests compare and the tile tooltip (PR B) renders.
    nonisolated static func connectionState(for error: Error) -> ConnectionState {
        guard let paddock = error as? PaddockError else {
            return .reconnecting(.unexpected(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            ))
        }
        if case .herdrSocketUnavailable = paddock {
            return .sessionNotRunning
        }
        return .reconnecting(.failed(paddock))
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
