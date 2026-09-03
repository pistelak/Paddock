import Foundation

/// The live spaces list of one herdr session: what the column draws, plus the
/// connection that keeps it current.
///
/// Everything the UI needs is two `private(set)` properties and one closure,
/// the same shape as `TabStore`: read `state` and `connection`, re-render in
/// `onChange`. `onChange` is *coalesced* — at most one call per main-actor
/// turn — because herdr's stream is chatty (17 workspace events in 4 s on an
/// idle session during the spike) and every event would otherwise be a render.
///
/// The store owns a supervising `Task` that reconnects for ever: ping, open
/// the events connection, take a `session.snapshot`, then let the stream drive
/// further snapshots until it ends. A dead session is not an error state to
/// recover from by hand — it is just a longer wait between attempts — so
/// `state` is never cleared on failure and the column keeps drawing the last
/// known rows dimmed.
///
/// **`session.snapshot` is the only source of state.** No event is ever applied
/// to `state`; events only say *something may have moved* and the store
/// refetches. The reason is herdr's replay: every `events.subscribe` ack is
/// followed by an unmarked historical backlog, paced at one event per 100 ms
/// (measured 2026-09-02 on the `default` session: 89 `workspace_focused` events
/// over 9.1 s), with nothing in the protocol — no cursor, no `seq`, no
/// timestamp, no opt-out — to tell a replayed event from a live one. Replayed
/// content is *stale*, so applying it drags the rows back through the session's
/// history; that is what walked the focused pill across the column for ten
/// seconds after every connect. Refetching instead is bounded work
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
/// open. Whoever owns the store (the tab coordinator) must call `stop()` when
/// it drops one.
@MainActor
final class WorkspaceStore {
    /// What the footer says, and whether the rows are stale.
    ///
    /// `unsupportedProtocol` is deliberately a *connected* state: the shapes
    /// Paddock reads are a small, stable subset, so a herdr speaking another
    /// protocol keeps working and only earns a warning. It becomes an error
    /// only if decoding actually fails, which surfaces as `reconnecting`.
    enum ConnectionState: Equatable, Sendable {
        case idle
        case connecting
        case live
        /// Keep the last rows, draw them dimmed, retry on the backoff.
        case reconnecting(lastError: String)
        /// No socket at the path: the session has not been started yet.
        case sessionNotRunning
        /// Connected and usable, but `ping` reported another protocol version.
        case unsupportedProtocol(Int)

        /// Whether rows are being kept current right now.
        var isConnected: Bool {
            switch self {
            case .live, .unsupportedProtocol: true
            case .idle, .connecting, .reconnecting, .sessionNotRunning: false
            }
        }
    }

    /// How many snapshot failures in a row the event loop tolerates while the
    /// stream is still up, and the pause between them. The last failure ends
    /// the connection: the supervisor reports `.reconnecting` and tries again
    /// on the backoff, so a herdr that answers events but not snapshots can
    /// never leave stale rows on screen under a footer that says nothing.
    static let maximumSnapshotFailures = 3
    static let snapshotFailurePause: Duration = .seconds(1)

    /// The floor between the *starts* of two `session.snapshot` requests, which
    /// is also the window a burst of events coalesces in.
    ///
    /// Leading-edge: the first event after a quiet spell refetches straight
    /// away, so the pill follows a click or a `herdr workspace focus` within
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

    /// Called after any change to `state` or `connection`, coalesced to once
    /// per main-actor turn. Never called after `stop()`.
    var onChange: (() -> Void)?

    let transport: any HerdrTransport
    let clock: any Clock<Duration>

    private var supervisor: Task<Void, Never>?
    private var resync: Task<Void, Never>?
    private var notification: Task<Void, Never>?

    /// Gates every mutation. A cancelled supervisor is not stopped the instant
    /// `stop()` returns — it is still unwinding somewhere between two awaits —
    /// and without this flag its last write would put the store back into
    /// `.reconnecting` and fire an `onChange` after the column let go of it.
    private var isRunning = false

    var backoff = Backoff()
    /// Guards against a pane set that keeps changing between the subscribe and
    /// the snapshot: reconnecting without a pause is only free a few times.
    var consecutiveResubscribes = 0
    /// When the last connection attempt began, on `clock`, so `supervise()`
    /// can enforce a floor between two of them. Kept on the store rather than
    /// in the loop because `restart()` replaces the loop and the floor has to
    /// survive it. Erased, because the store is not generic over its clock;
    /// the supervisor reads it back through the clock's own instant type.
    var lastConnectionStart: (any InstantProtocol<Duration>)?

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
    /// rows to draw while it reconnects. No `onChange` fires after this
    /// returns: the coalescing task is cancelled with the rest.
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

    // MARK: - Mutations
    //
    // Every mutation is a request on a connection of its own and its result is
    // discarded: the column updates when the `workspace_*` event it causes
    // comes back down the stream, so a click and a change made in the TUI take
    // exactly the same path. Errors are rethrown for the caller to show.

    func focus(_ workspaceID: String) async throws {
        try await transport.send(.workspaceFocus, params: WorkspaceTargetParams(workspaceID))
    }

    /// Creates a space and moves herdr to it, so the TUI and the column agree
    /// about where the user is.
    func create(label: String?) async throws {
        try await transport.send(.workspaceCreate, params: WorkspaceCreateParams(label: label, focus: true))
    }

    func rename(_ workspaceID: String, to label: String) async throws {
        try await transport.send(.workspaceRename, params: WorkspaceRenameParams(workspaceID: workspaceID, label: label))
    }

    func close(_ workspaceID: String) async throws {
        try await transport.send(.workspaceClose, params: WorkspaceTargetParams(workspaceID))
    }

    // MARK: - State

    /// Replaces the rows wholesale from an authoritative snapshot.
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
        apply(WorkspaceListState(snapshot: result.snapshot))
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
    /// and restarts, instead of going quiet while the footer still says live:
    /// the stream may well be healthy, but rows nobody can refresh are stale,
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

    // MARK: - Coalescing

    private var isDirty = false

    /// Requests one `onChange` on the next main-actor turn. A burst of 200
    /// events therefore renders once.
    private func markDirty() {
        guard isRunning else { return }
        isDirty = true
        guard notification == nil else { return }
        notification = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.notification = nil
            guard self.isDirty else { return }
            self.isDirty = false
            self.onChange?()
        }
    }
}
