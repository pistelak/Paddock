import Foundation

/// Every running `WorkspaceStore`, one per tab, and the one place their
/// lifetime is decided.
///
/// A store's supervising task retains it while it runs, so a store that is
/// dropped without `stop()` keeps its socket open for the life of the app.
/// Making the registry the only owner — the only caller of `stop()`, the only
/// thing that creates one — turns that documented duty into a property of the
/// shape: `drop(_:)` and `stopAll()` are the two ways a store goes away, and
/// both stop it first.
///
/// It also owns what `herdr session list` last said, because that is what
/// decides a store's socket path, and because a store created before herdr
/// had been asked may be pointed at the fallback path and need replacing once
/// the real one is known.
///
/// Stores are created the first time a tab is selected and kept running
/// afterwards so switching back is instant. A tab that has never been
/// selected has no store and therefore no badge yet; opening every store at
/// launch would cost one socket per tab before the user has looked at any.
@MainActor
final class WorkspaceStoreRegistry {
    /// Builds a store for a tab at a socket path — injectable so tests can
    /// hand every store a scripted herdr and a manual clock.
    typealias MakeStore = @MainActor (SessionTab, String) -> WorkspaceStore

    /// Fires after any store changed; the argument is that store's tab.
    var onChange: ((UUID) -> Void)?

    private let makeStore: MakeStore
    private var stores: [UUID: WorkspaceStore] = [:]
    private var observations: [UUID: ObservationToken] = [:]
    private var knownSessions: [SessionName: HerdrSession] = [:]

    init(makeStore: @escaping MakeStore = { tab, socketPath in
        WorkspaceStore(sessionName: tab.sessionName, socketPath: socketPath)
    }) {
        self.makeStore = makeStore
    }

    // MARK: - Lookup

    /// The store for one tab, started on creation and kept until the tab goes.
    func store(for tab: SessionTab) -> WorkspaceStore {
        if let existing = stores[tab.id] { return existing }
        let store = makeStore(tab, socketPath(for: tab.sessionName))
        stores[tab.id] = store
        observations[tab.id] = store.observe { [weak self] in self?.onChange?(tab.id) }
        store.start()
        return store
    }

    /// The store for a tab that has one — never creates.
    func existingStore(for tabID: UUID) -> WorkspaceStore? {
        stores[tabID]
    }

    /// What the tile badge shows: the whole session folded into one status,
    /// or nothing for a tab that has not been visited yet.
    func aggregateStatus(of tabID: UUID) -> AgentStatus? {
        stores[tabID]?.state.aggregateStatus
    }

    var runningTabIDs: Set<UUID> {
        Set(stores.keys)
    }

    // MARK: - Lifetime

    /// Stops the tab's store and forgets it.
    func drop(_ tabID: UUID) {
        observations.removeValue(forKey: tabID)?.cancel()
        stores.removeValue(forKey: tabID)?.stop()
    }

    /// Stops every store — what the coordinator does at quit.
    func stopAll() {
        for tabID in Array(stores.keys) {
            drop(tabID)
        }
    }

    // MARK: - Sessions

    /// herdr's own answer when it has one, the computed layout otherwise — a
    /// tab may name a session that has never been created, and the column
    /// still needs an address to keep trying.
    func socketPath(for name: SessionName) -> String {
        knownSessions[name]?.socketPath ?? HerdrPaths.socketPath(for: name)
    }

    /// Records what `herdr session list` said and replaces every store whose
    /// socket path it contradicts, returning the tabs that were replaced so the
    /// caller can rebind the one on screen.
    ///
    /// A store created before herdr had been asked is pointed at the fallback
    /// path. If herdr later reports another one, that store would keep failing
    /// against an address nothing listens on, so it is stopped and dropped
    /// outright; the next `store(for:)` creates one at the right path.
    @discardableResult
    func update(knownSessions sessions: [HerdrSession]) -> [UUID] {
        knownSessions = Dictionary(sessions.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var replaced: [UUID] = []
        for (tabID, store) in stores where socketPath(for: store.sessionName) != store.socketPath {
            drop(tabID)
            replaced.append(tabID)
        }
        return replaced
    }
}
