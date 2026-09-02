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
/// the events connection, take a `session.snapshot`, then reduce events until
/// the stream ends. A dead session is not an error state to recover from by
/// hand — it is just a longer wait between attempts — so `state` is never
/// cleared on failure and the column keeps drawing the last known rows dimmed.
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

    /// How long a burst of `needsResync` events is allowed to accumulate
    /// before one `session.snapshot` settles all of them.
    static let resyncDebounce: Duration = .milliseconds(200)

    let sessionName: SessionName
    let socketPath: String

    private(set) var state = WorkspaceListState()
    private(set) var connection: ConnectionState = .idle

    /// Called after any change to `state` or `connection`, coalesced to once
    /// per main-actor turn. Never called after `stop()`.
    var onChange: (() -> Void)?

    let client: HerdrSocketClient

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

    /// `client` is injectable so a test can point the store at a socket of its
    /// own; there is deliberately no protocol seam, because everything worth
    /// testing without herdr (the subscription list, the backoff, the error
    /// mapping) is a pure function on this type.
    init(sessionName: SessionName, socketPath: String, client: HerdrSocketClient? = nil) {
        self.sessionName = sessionName
        self.socketPath = socketPath
        self.client = client ?? HerdrSocketClient(socketPath: socketPath)
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
        let _: HerdrResultTag = try await client.request(
            "workspace.focus",
            params: WorkspaceTargetParams(workspaceID)
        )
    }

    /// Creates a space and moves herdr to it, so the TUI and the column agree
    /// about where the user is.
    func create(label: String?) async throws {
        let _: HerdrResultTag = try await client.request(
            "workspace.create",
            params: WorkspaceCreateParams(label: label, focus: true)
        )
    }

    func rename(_ workspaceID: String, to label: String) async throws {
        let _: HerdrResultTag = try await client.request(
            "workspace.rename",
            params: WorkspaceRenameParams(workspaceID: workspaceID, label: label)
        )
    }

    func close(_ workspaceID: String) async throws {
        let _: HerdrResultTag = try await client.request(
            "workspace.close",
            params: WorkspaceTargetParams(workspaceID)
        )
    }

    // MARK: - State

    /// Replaces the rows wholesale from an authoritative snapshot.
    ///
    /// `session.snapshot` rather than `workspace.list` because it carries the
    /// panes too, and the panes are the only source of live agent status —
    /// one request instead of two, and no window in which the two disagree.
    @discardableResult
    func refreshFromSnapshot() async throws -> WorkspaceListState {
        let result: SessionSnapshotResult = try await client.request("session.snapshot")
        apply(WorkspaceListState(snapshot: result.snapshot))
        return state
    }

    func apply(_ newState: WorkspaceListState) {
        guard isRunning, newState != state else { return }
        state = newState
        markDirty()
    }

    func reduce(_ event: HerdrEvent) -> WorkspaceReducer.Outcome {
        let outcome = WorkspaceReducer.apply(event, to: &state)
        if outcome.contains(.changed) { markDirty() }
        if outcome.contains(.needsResync) { scheduleResync() }
        return outcome
    }

    func setConnection(_ newValue: ConnectionState) {
        guard isRunning, newValue != connection else { return }
        connection = newValue
        markDirty()
    }

    // MARK: - Resync

    /// Debounces the `needsResync` outcome: a backlog replay can produce
    /// dozens of them in a row, and one snapshot settles them all.
    ///
    /// If the snapshot turns up panes the current subscription list does not
    /// cover, the events connection is reopened — nothing else would notice,
    /// because the loop is parked inside `for try await`.
    private func scheduleResync() {
        resync?.cancel()
        resync = Task { @MainActor [weak self] in
            // Not `try?`: that would swallow cancellation and resync anyway.
            do { try await Task.sleep(for: WorkspaceStore.resyncDebounce) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.resync = nil
            let before = WorkspaceStore.subscriptions(for: self.state)
            // A failed resync is not reported: the same failure is about to
            // end the event stream, and the supervisor owns that story.
            guard (try? await self.refreshFromSnapshot()) != nil else { return }
            guard !Task.isCancelled else { return }
            if WorkspaceStore.subscriptions(for: self.state) != before {
                self.restart()
            }
        }
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
