import Foundation

/// The app-owned, persisted list of side tabs: identity, session, display
/// name, colour and order. Nothing window-specific lives here. Every
/// mutation notifies `onChange` and queues a save; saves run strictly in
/// order and `flush()` waits for the last one.
@MainActor
final class TabStore {
    private(set) var tabs: [SessionTab] = []
    var onChange: (() -> Void)?
    var onSaveFailure: ((Error) -> Void)?

    private let file: TabStoreFile
    private var generation = 0
    private var lastSave: Task<Void, Never>?

    init(fileURL: URL) {
        file = TabStoreFile(url: fileURL)
    }

    static func defaultFileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Paddock", isDirectory: true)
            .appendingPathComponent("tabs.json")
    }

    // MARK: - Loading

    /// Returns `false` when there is no file yet (first launch).
    @discardableResult
    func load() async throws -> Bool {
        guard let data = try await file.read() else { return false }
        let decoded = try TabsDocument.decode(data)
        try Self.validate(decoded.tabs)
        tabs = decoded.tabs
        onChange?()
        if decoded.needsUpgrade {
            scheduleSave()
        }
        return true
    }

    static func seedTabs(from sessions: [HerdrSession]) -> [SessionTab] {
        var tabs: [SessionTab] = []
        for session in sessions where !tabs.contains(where: { $0.sessionName == session.name }) {
            tabs.append(SessionTab(
                sessionName: session.name,
                color: TabColorID.leastUsed(among: tabs.map(\.color))
            ))
        }
        return tabs
    }

    /// A tab list is well-formed when ids and session names are unique.
    static func validate(_ tabs: [SessionTab]) throws {
        var ids = Set<UUID>()
        var names = Set<SessionName>()
        for tab in tabs {
            guard ids.insert(tab.id).inserted else {
                throw PaddockError.corruptTabsFile("duplicate tab id \(tab.id)")
            }
            guard names.insert(tab.sessionName).inserted else {
                throw PaddockError.corruptTabsFile("duplicate session “\(tab.sessionName)”")
            }
        }
    }

    // MARK: - Queries

    func tab(withID id: UUID) -> SessionTab? {
        tabs.first { $0.id == id }
    }

    func tab(forSession name: SessionName) -> SessionTab? {
        tabs.first { $0.sessionName == name }
    }

    // MARK: - Mutation

    func replaceAll(_ newTabs: [SessionTab]) throws {
        try Self.validate(newTabs)
        guard newTabs != tabs else { return }
        tabs = newTabs
        didMutate()
    }

    @discardableResult
    func addTab(sessionName: SessionName) throws -> SessionTab {
        guard tab(forSession: sessionName) == nil else {
            throw PaddockError.duplicateSession(sessionName.rawValue)
        }
        let tab = SessionTab(
            sessionName: sessionName,
            color: TabColorID.leastUsed(among: tabs.map(\.color))
        )
        tabs.append(tab)
        didMutate()
        return tab
    }

    func renameTab(id: UUID, to name: String) {
        mutateTab(id: id) { $0.rename(name) }
    }

    func recolorTab(id: UUID, to color: TabColorID) {
        mutateTab(id: id) { $0.recolor(color) }
    }

    /// Moves a tab to `index` in the final order; out-of-range indices clamp.
    func moveTab(id: UUID, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: from)
        let target = min(max(index, 0), tabs.count)
        tabs.insert(tab, at: target)
        guard target != from else { return }
        didMutate()
    }

    func removeTab(id: UUID) {
        let before = tabs.count
        tabs.removeAll { $0.id == id }
        guard tabs.count != before else { return }
        didMutate()
    }

    private func mutateTab(id: UUID, _ change: (inout SessionTab) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let original = tabs[index]
        change(&tabs[index])
        guard tabs[index] != original else { return }
        didMutate()
    }

    private func didMutate() {
        onChange?()
        scheduleSave()
    }

    // MARK: - Saving

    private func scheduleSave() {
        generation += 1
        let data: Data
        do {
            data = try TabsDocument.encode(tabs)
        } catch {
            onSaveFailure?(error)
            return
        }

        let thisGeneration = generation
        let previous = lastSave
        lastSave = Task { [file, weak self] in
            await previous?.value
            do {
                try await file.write(data, generation: thisGeneration)
            } catch {
                self?.onSaveFailure?(error)
            }
        }
    }

    /// Waits until every queued save has hit the disk.
    func flush() async {
        await lastSave?.value
    }
}
