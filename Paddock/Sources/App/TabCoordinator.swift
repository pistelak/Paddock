import AppKit

/// Glues the tab store, the sidebar and the pane container together for
/// the window: which tab is selected, what each view is bound to, and where a
/// user action on a tab goes. Window-local state (the selection) lives here,
/// not in the shared store.
///
/// Everything that is a dialog or a menu of its own has moved out:
/// `AddSessionMenu` and `WindowTitle`. Every running `WorkspaceStore` — one per
/// session, the source of the tiles' indicators — belongs to `registry`.
@MainActor
final class TabCoordinator {
    private static let selectedTabKey = "selectedTabID"

    let store: TabStore
    let host: TerminalHost
    let herdrExecutable: URL
    let herdr: HerdrCLI
    let sidebar = SidebarViewController()
    let panes = PaneContainerViewController()
    weak var window: NSWindow?

    private let defaults: UserDefaults

    /// Every running spaces store, and what herdr said about sessions. The
    /// registry is the only thing that starts or stops a store.
    let registry: WorkspaceStoreRegistry

    /// The selected tab. Read from defaults once at start and written back by
    /// `select(_:)`, so it is this instance's state rather than a live view of
    /// the key. Paddock has one window, so the key is app-wide on purpose.
    private(set) var selectedTabID: UUID?

    init(
        store: TabStore,
        host: TerminalHost,
        herdrExecutable: URL,
        defaults: UserDefaults = .standard,
        registry: WorkspaceStoreRegistry = WorkspaceStoreRegistry()
    ) {
        self.store = store
        self.host = host
        self.herdrExecutable = herdrExecutable
        self.defaults = defaults
        self.registry = registry
        herdr = HerdrCLI(executableURL: herdrExecutable)
        selectedTabID = defaults.string(forKey: Self.selectedTabKey).flatMap(UUID.init(uuidString:))
    }

    func start() {
        store.onChange = { [weak self] in self?.refreshPresentation() }
        // Any store's state moved: the tile indicators may have too.
        registry.onChange = { [weak self] _ in self?.refreshPresentation() }
        store.onSaveFailure = { [weak self] error in
            Task { await AlertPresenter.present(error, in: self?.window) }
        }
        sidebar.onAction = { [weak self] action, id in self?.handle(action, tabID: id) }
        sidebar.onAdd = { [weak self] anchor in
            Task { await self?.showAddMenu(from: anchor) }
        }

        Task { [weak self] in await self?.refreshKnownSessions() }

        let initial = selectedTabID.flatMap(store.tab(withID:)) ?? store.tabs.first
        if let initial {
            select(initial)
        } else {
            refreshPresentation()
        }
    }

    /// Stops every store. The app calls this once at quit; nothing is usable
    /// afterwards.
    func stop() {
        registry.stopAll()
    }

    // MARK: - Selection and presentation

    private func select(_ tab: SessionTab) {
        setSelectedTab(tab.id)
        // Before the pane, so the store exists when its surface attaches and
        // asks for an immediate retry.
        _ = registry.store(for: tab)
        panes.select(tab) { [self] in makePane(for: tab) }
        refreshPresentation()
    }

    private func setSelectedTab(_ id: UUID?) {
        selectedTabID = id
        defaults.set(id?.uuidString, forKey: Self.selectedTabKey)
    }

    /// Puts the keyboard into the selected tab's pane once the strip has
    /// finished showing or hiding.
    func focusSelectedPane() {
        guard let selectedTabID else { return }
        panes.focusPane(selectedTabID)
    }

    private func makePane(for tab: SessionTab) -> TerminalPaneViewController {
        let pane = TerminalPaneViewController(tab: tab, host: host, herdrExecutable: herdrExecutable)
        pane.onEvent = { [weak self] event in self?.handle(event, from: tab.id) }
        return pane
    }

    /// The single path from state to screen: tiles, existing panes and the
    /// window title all derive from the store and this window's selection.
    private func refreshPresentation() {
        let indicators = Dictionary(uniqueKeysWithValues: store.tabs.compactMap { tab in
            registry.indicatorInputs(of: tab.id).map { inputs in
                (tab.id, TileIndicator(
                    displayName: tab.displayName,
                    sessionName: tab.sessionName.rawValue,
                    state: inputs.state,
                    connection: inputs.connection
                ))
            }
        })
        sidebar.render(tabs: store.tabs, selectedID: selectedTabID, indicators: indicators)
        panes.reconcile(tabs: store.tabs)
        updateWindowTitle()
    }

    private func handle(_ event: TerminalPaneEvent, from tabID: UUID) {
        switch event {
        case .titleChanged:
            guard tabID == selectedTabID else { return }
            updateWindowTitle()
        case .surfaceAttached:
            // herdr is coming up in that surface: whatever the store was
            // waiting for, now is the moment to try again.
            registry.existingStore(for: tabID)?.retryNow()
        case .surfaceClosed:
            // Nothing to do: herdr's daemon keeps serving a detached session,
            // and a session that really ended is noticed by the store's own
            // reconnect loop within a couple of seconds.
            break
        }
    }

    private func updateWindowTitle() {
        let tab = selectedTabID.flatMap(store.tab(withID:))
        let terminalTitle = selectedTabID.flatMap(panes.pane(for:))?.lastTitle
        window?.title = WindowTitle.text(tab: tab, terminalTitle: terminalTitle)
    }

    // MARK: - Sessions

    /// Asks herdr for its sessions once at start-up, then opens a store for
    /// every tab so each tile has an indicator from the start. A listing
    /// failure is deliberately silent — every socket path has a fallback, and
    /// the add menu is where listing sessions is the user's own request and
    /// worth an alert — and does not stop the stores from starting.
    private func refreshKnownSessions() async {
        if let sessions = try? await herdr.listSessions() {
            cache(sessions)
        }
        // `cache` only restarts when something was replaced; the tabs that had
        // no store yet get one here either way, listing failure included.
        registry.startAll(for: store.tabs)
        refreshPresentation()
    }

    /// Hands the list to the registry. Every store the list contradicted was
    /// dropped, so every tab is given a store again at once — at the path herdr
    /// just named — and the tiles are redrawn. Every tab, not only the selected
    /// one: with indicators on all tiles, an unselected tab whose store was
    /// dropped would otherwise show nothing until it was next selected.
    private func cache(_ sessions: [HerdrSession]) {
        let replaced = registry.update(knownSessions: sessions)
        guard !replaced.isEmpty else { return }
        registry.startAll(for: store.tabs)
        refreshPresentation()
    }

    // MARK: - Tab actions

    private func handle(_ action: SidebarAction, tabID: UUID) {
        guard let tab = store.tab(withID: tabID) else { return }
        switch action {
        case .select:
            select(tab)
        case .rename:
            Task { await rename(tab) }
        case let .recolor(color):
            store.recolorTab(id: tab.id, to: color)
        case .remove:
            remove(tab)
        case .stopSession:
            Task { await stopSession(of: tab) }
        }
    }

    private func rename(_ tab: SessionTab) async {
        guard let name = await AlertPresenter.promptForText(
            title: "Rename Tab",
            message: "Shown on the tile; the herdr session stays “\(tab.sessionName.rawValue)”.",
            placeholder: "Display name",
            initialValue: tab.displayName,
            confirmTitle: "Rename",
            in: window
        ) else { return }
        store.renameTab(id: tab.id, to: name)
    }

    private func remove(_ tab: SessionTab) {
        let wasSelected = selectedTabID == tab.id
        panes.removePane(for: tab.id)
        registry.drop(tab.id)
        store.removeTab(id: tab.id)
        guard wasSelected else { return }
        if let next = store.tabs.first {
            select(next)
        } else {
            setSelectedTab(nil)
            refreshPresentation()
        }
    }

    private func stopSession(of tab: SessionTab) async {
        let confirmed = await AlertPresenter.confirm(
            title: "Stop herdr session “\(tab.sessionName.rawValue)”?",
            message: "Every pane and agent running in it will be terminated. The tab stays.",
            confirmTitle: "Stop Session",
            destructive: true,
            in: window
        )
        guard confirmed else { return }
        do {
            try await herdr.stopSession(tab.sessionName)
        } catch {
            await AlertPresenter.present(error, in: window)
        }
    }

    // MARK: - Adding tabs

    private func showAddMenu(from anchor: NSView) async {
        let untabbed = await untabbedSessions()
        switch AddSessionMenu.present(from: anchor, sessions: untabbed) {
        case nil:
            return
        case let .existing(name)?:
            addTab(name)
        case .create?:
            await createSession()
        }
    }

    /// herdr sessions with a valid name that have no tab yet. A failure to
    /// list them is reported, not mistaken for "none".
    ///
    /// The full list is cached on the way past: this is the one call that
    /// happens often enough to keep the socket paths current.
    private func untabbedSessions() async -> [SessionName] {
        do {
            let sessions = try await herdr.listSessions()
            cache(sessions)
            return sessions
                .map(\.name)
                .filter { store.tab(forSession: $0) == nil }
        } catch {
            await AlertPresenter.present(error, in: window)
            return []
        }
    }

    private func createSession() async {
        guard let raw = await AlertPresenter.promptForText(
            title: "New herdr Session",
            message: "herdr creates the session the first time the tab is opened.",
            placeholder: "e.g. work, personal, client-x",
            confirmTitle: "Add",
            in: window
        ) else { return }
        do {
            addTab(try SessionName(raw))
        } catch {
            await AlertPresenter.present(error, in: window)
        }
    }

    private func addTab(_ name: SessionName) {
        do {
            let tab = try store.addTab(sessionName: name)
            select(tab)
        } catch {
            Task { await AlertPresenter.present(error, in: window) }
        }
    }
}
