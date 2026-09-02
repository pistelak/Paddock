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
    let panes = PaneContainerViewController()
    weak var window: NSWindow?

    private let defaults: UserDefaults

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
            AlertPresenter.present(error, in: self?.window)
        }
        sidebar.onAction = { [weak self] action, id in self?.handle(action, tabID: id) }
        sidebar.onAdd = { [weak self] anchor in self?.showAddMenu(from: anchor) }

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
        store.removeTab(id: tab.id)
        guard wasSelected else { return }
        if let next = store.tabs.first {
            select(next)
        } else {
            selectedTabID = nil
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
            AlertPresenter.present(error, in: window)
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
    private func untabbedSessions() async -> [SessionName] {
        do {
            return try await herdr.listSessions()
                .map(\.name)
                .filter { store.tab(forSession: $0) == nil }
        } catch {
            AlertPresenter.present(error, in: window)
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
                AlertPresenter.present(error, in: window)
            }
        }
    }

    private func addTab(_ name: SessionName) {
        do {
            let tab = try store.addTab(sessionName: name)
            select(tab)
        } catch {
            AlertPresenter.present(error, in: window)
        }
    }
}
