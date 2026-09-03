import AppKit

/// Glues the tab store, the sidebar and the pane container together for
/// one window and implements every user action on tabs. Window-local state
/// (which tab is selected) lives here, not in the shared store.
@MainActor
final class TabCoordinator {
    private static let selectedTabKey = "selectedTabID"

    let store: TabStore
    let host: TerminalHost
    let herdrExecutable: URL
    let herdr: HerdrCLI
    let sidebar = SidebarViewController()
    let spaces = WorkspaceColumnViewController()
    let panes = PaneContainerViewController()
    weak var window: NSWindow?

    private let defaults: UserDefaults

    /// One spaces store per tab, created the first time its tile is selected
    /// and kept running afterwards so switching back is instant. The store's
    /// supervising task retains it, so dropping one without `stop()` would
    /// leak a socket — `remove(_:)` is the only place that drops one.
    private var workspaceStores: [UUID: WorkspaceStore] = [:]

    /// What `herdr session list` last said, keyed by name. Only the socket
    /// path is read from it: a tab may name a session herdr has never created,
    /// and `HerdrPaths` covers that case.
    private var knownSessions: [SessionName: HerdrSession] = [:]

    /// The selected tab of this window. Read from defaults once at start
    /// and written back on change, so it is this instance's state rather
    /// than a live view of a shared key.
    private(set) var selectedTabID: UUID? {
        didSet { defaults.set(selectedTabID?.uuidString, forKey: Self.selectedTabKey) }
    }

    init(store: TabStore, host: TerminalHost, herdrExecutable: URL, defaults: UserDefaults = .standard) {
        self.store = store
        self.host = host
        self.herdrExecutable = herdrExecutable
        self.defaults = defaults
        herdr = HerdrCLI(executableURL: herdrExecutable)
        selectedTabID = defaults.string(forKey: Self.selectedTabKey).flatMap(UUID.init(uuidString:))
    }

    func start() {
        store.onChange = { [weak self] in self?.refreshPresentation() }
        store.onSaveFailure = { [weak self] error in
            Task { await AlertPresenter.present(error, in: self?.window) }
        }
        sidebar.onAction = { [weak self] action, id in self?.handle(action, tabID: id) }
        sidebar.onAdd = { [weak self] anchor in self?.showAddMenu(from: anchor) }
        spaces.onAction = { [weak self] action, id in self?.handle(action, workspaceID: id) }
        spaces.onCreate = { [weak self] _ in
            Task { await self?.createSpace() }
        }

        Task { [weak self] in await self?.refreshKnownSessions() }

        let initial = selectedTabID.flatMap(store.tab(withID:)) ?? store.tabs.first
        if let initial {
            select(initial)
        } else {
            refreshPresentation()
        }
    }

    // MARK: - Selection and presentation

    private func select(_ tab: SessionTab) {
        selectedTabID = tab.id
        // Before the pane, so the store exists when its surface attaches and
        // asks for an immediate retry.
        spaces.bind(workspaceStore(for: tab))
        panes.select(tab) { [self] in makePane(for: tab) }
        refreshPresentation()
    }

    private func makePane(for tab: SessionTab) -> TerminalPaneViewController {
        let pane = TerminalPaneViewController(tab: tab, host: host, herdrExecutable: herdrExecutable)
        pane.onEvent = { [weak self] event in self?.handle(event, from: tab.id) }
        return pane
    }

    /// The single path from state to screen: tiles, existing panes and the
    /// window title all derive from the store and this window's selection.
    private func refreshPresentation() {
        sidebar.render(tabs: store.tabs, selectedID: selectedTabID)
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
            workspaceStores[tabID]?.retryNow()
        case .surfaceClosed:
            // Nothing to do: herdr's daemon keeps serving a detached session,
            // and a session that really ended is noticed by the store's own
            // reconnect loop within a couple of seconds.
            break
        }
    }

    private func updateWindowTitle() {
        guard let id = selectedTabID, let tab = store.tab(withID: id) else {
            window?.title = "Paddock"
            return
        }
        let terminalTitle = panes.pane(for: id)?.lastTitle
        window?.title = [tab.displayName, terminalTitle].compactMap { $0 }.joined(separator: " — ")
    }

    // MARK: - Spaces stores

    /// The store for one tab, started on creation and kept until the tab goes.
    private func workspaceStore(for tab: SessionTab) -> WorkspaceStore {
        if let existing = workspaceStores[tab.id] { return existing }
        let workspaces = WorkspaceStore(
            sessionName: tab.sessionName,
            socketPath: socketPath(for: tab.sessionName)
        )
        workspaceStores[tab.id] = workspaces
        workspaces.start()
        return workspaces
    }

    /// herdr's own answer when it has one, the computed layout otherwise — a
    /// tab may name a session that has never been created, and the column
    /// still needs an address to keep trying.
    private func socketPath(for name: SessionName) -> String {
        knownSessions[name]?.socketPath ?? HerdrPaths.socketPath(for: name)
    }

    /// Asks herdr for its sessions once at start-up. A failure is deliberately
    /// silent: every socket path has a fallback, and the add menu is where
    /// listing sessions is the user's own request and worth an alert.
    private func refreshKnownSessions() async {
        guard let sessions = try? await herdr.listSessions() else { return }
        cache(sessions)
    }

    private func cache(_ sessions: [HerdrSession]) {
        knownSessions = Dictionary(sessions.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        replaceStoresWithStaleSockets()
    }

    /// A store created before herdr had been asked is pointed at the fallback
    /// path. If herdr later reports another one, that store would keep failing
    /// against an address nothing listens on, so it is replaced outright — and
    /// rebound when it is the store on screen.
    private func replaceStoresWithStaleSockets() {
        for (tabID, workspaces) in workspaceStores {
            guard let tab = store.tab(withID: tabID),
                  socketPath(for: tab.sessionName) != workspaces.socketPath
            else { continue }
            workspaces.stop()
            workspaceStores[tabID] = nil
            guard tabID == selectedTabID else { continue }
            spaces.bind(workspaceStore(for: tab))
        }
    }

    // MARK: - Actions

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
        // Without `stop()` the supervising task keeps the store — and its
        // socket — alive for the lifetime of the app.
        workspaceStores.removeValue(forKey: tab.id)?.stop()
        store.removeTab(id: tab.id)
        guard wasSelected else { return }
        if let next = store.tabs.first {
            select(next)
        } else {
            selectedTabID = nil
            spaces.bind(nil)
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

    // MARK: - Spaces actions
    //
    // Every one of these runs against the *selected* tab's store, because that
    // is the store the column is bound to and the only one whose rows the user
    // can click. A failed focus is a footnote in the column's footer — it is
    // one click among many — while a failed create, rename or close answers a
    // dialog the user just filled in and gets an alert of its own.

    private var selectedWorkspaceStore: WorkspaceStore? {
        selectedTabID.flatMap { workspaceStores[$0] }
    }

    private func handle(_ action: WorkspaceAction, workspaceID: WorkspaceID) {
        guard let workspaces = selectedWorkspaceStore else { return }
        switch action {
        case .focus:
            Task {
                do {
                    try await workspaces.focus(workspaceID)
                    // The click landed in the column; the keyboard belongs to
                    // the terminal that just changed space — unless the user
                    // has moved to another tab meanwhile, whose pane and
                    // column must not react to a stale completion.
                    guard selectedWorkspaceStore === workspaces else { return }
                    panes.focusSelectedPane()
                } catch {
                    guard selectedWorkspaceStore === workspaces else { return }
                    spaces.showTransientError(error.localizedDescription)
                }
            }
        case .rename:
            Task { await renameSpace(workspaceID, in: workspaces) }
        case .close:
            Task { await closeSpace(workspaceID, in: workspaces) }
        }
    }

    private func renameSpace(_ workspaceID: WorkspaceID, in workspaces: WorkspaceStore) async {
        guard let workspace = workspaces.state.workspace(workspaceID) else { return }
        guard let raw = await AlertPresenter.promptForText(
            title: "Rename Space",
            message: "Shown in the Spaces column and in herdr’s own tab bar.",
            placeholder: "Label",
            initialValue: workspace.label,
            confirmTitle: "Rename",
            in: window
        ) else { return }
        let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }
        do {
            try await workspaces.rename(workspaceID, to: label)
        } catch {
            await AlertPresenter.present(error, in: window)
        }
    }

    private func closeSpace(_ workspaceID: WorkspaceID, in workspaces: WorkspaceStore) async {
        guard let workspace = workspaces.state.workspace(workspaceID) else { return }
        let confirmed = await AlertPresenter.confirm(
            title: "Close space “\(Self.displayName(of: workspace))”?",
            message: "Every pane and agent in it will be terminated.",
            confirmTitle: "Close Space",
            destructive: true,
            in: window
        )
        guard confirmed else { return }
        do {
            try await workspaces.close(workspaceID)
        } catch {
            await AlertPresenter.present(error, in: window)
        }
    }

    /// A space herdr has no label for is known by its number, exactly as the
    /// row draws it.
    private static func displayName(of workspace: Workspace) -> String {
        workspace.label.isEmpty ? "\(workspace.number)" : workspace.label
    }

    private func createSpace() async {
        guard let workspaces = selectedWorkspaceStore else { return }
        guard let raw = await AlertPresenter.promptForText(
            title: "New Space",
            message: "herdr creates the space and moves to it.",
            placeholder: "Label (optional)",
            confirmTitle: "Create",
            in: window
        ) else { return }
        let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await workspaces.create(label: label.isEmpty ? nil : label)
        } catch {
            await AlertPresenter.present(error, in: window)
        }
    }

    // MARK: - Adding tabs

    private func showAddMenu(from anchor: NSView) {
        Task {
            let untabbed = await untabbedSessions()
            let menu = NSMenu()
            for name in untabbed {
                let item = NSMenuItem(title: name.rawValue, action: #selector(addExistingSession(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = name
                menu.addItem(item)
            }
            if !untabbed.isEmpty {
                menu.addItem(.separator())
            }
            let create = NSMenuItem(title: "New Session…", action: #selector(createSession), keyEquivalent: "")
            create.target = self
            menu.addItem(create)
            menu.popUp(positioning: nil, at: NSPoint(x: anchor.bounds.maxX + 4, y: anchor.bounds.midY), in: anchor)
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

    @objc private func addExistingSession(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? SessionName else { return }
        addTab(name)
    }

    @objc private func createSession() {
        Task {
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
