import Foundation

/// The app-owned, persisted list of side tabs: identity, session, display
/// name, colour and order. Nothing window-specific lives here. Every
/// mutation notifies `onChange` and queues a save; saves run strictly in
/// order and `flush()` waits for the last one.
///
/// A store whose file could not be read is never allowed to write over it by
/// accident: `load()` reports *why* it failed, and the caller either moves
/// the file aside first (`quarantineFile()`) or turns saving off for the rest
/// of the process (`disableSaving()`). Nothing here saves on its own after a
/// failed load — `replaceAll`, `addTab` and the rest go through the same
/// `scheduleSave()` gate.
@MainActor
final class TabStore {
    /// Why `load()` could not produce a tab list. The three cases call for
    /// three different recoveries, so they are kept apart rather than folded
    /// into one error.
    enum LoadFailure: Error {
        /// The file was written by a Paddock with a newer format. Its bytes
        /// are probably a perfectly good tab list for *that* Paddock, so this
        /// one must leave them alone.
        case newerVersion(Int)
        /// The bytes are not a tab list at all: malformed JSON, an invalid
        /// session name, a duplicate id or session. Safe to move aside.
        case invalidContents(Error)
        /// The file could not be read. Says nothing about the bytes, and a
        /// move might fail the same way, so the file is left where it is.
        case io(Error)
    }

    /// Whether mutations are written to disk. `disabled` is one-way and lasts
    /// for the life of the store: it exists for a launch whose file could not
    /// be read and must not be overwritten.
    enum Persistence: Equatable, Sendable {
        case persistent
        case disabled
    }

    private(set) var tabs: [SessionTab] = []
    private(set) var persistence: Persistence = .persistent
    var onChange: (() -> Void)?
    var onSaveFailure: ((Error) -> Void)?

    private let file: TabStoreFile
    private var generation = 0
    private var lastSave: Task<Void, Never>?

    init(fileURL: URL) {
        file = TabStoreFile(url: fileURL)
    }

    var fileURL: URL {
        file.url
    }

    static func defaultFileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Paddock", isDirectory: true)
            .appendingPathComponent("tabs.json")
    }

    // MARK: - Loading

    /// Returns `false` when there is no file yet (first launch).
    ///
    /// Reading, decoding and validating are kept as three steps so that an
    /// I/O error is reported as one and never mistaken for a corrupt file.
    @discardableResult
    func load() async throws(LoadFailure) -> Bool {
        let data: Data?
        do {
            data = try await file.read()
        } catch {
            throw .io(error)
        }
        guard let data else { return false }

        let decoded: TabsDocument.Decoded
        do {
            decoded = try TabsDocument.decode(data)
            try Self.validate(decoded.tabs)
        } catch PaddockError.unsupportedTabsFile(let version) where version > TabsDocument.currentVersion {
            throw .newerVersion(version)
        } catch {
            throw .invalidContents(error)
        }

        tabs = decoded.tabs
        onChange?()
        if decoded.needsUpgrade {
            scheduleSave()
        }
        return true
    }

    /// Moves an unreadable file aside so a fresh one can be written. Only
    /// meaningful after `load()` threw `.invalidContents`; see `TabStoreFile`.
    func quarantineFile() async throws -> URL {
        try await file.quarantineUnreadableFile()
    }

    /// Stops every future save, including the flush at quit. For a launch
    /// whose file must be left exactly as it was found.
    func disableSaving() {
        persistence = .disabled
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

    /// The single gate every write passes through: nothing reaches the disk
    /// while persistence is disabled — not a migration, not an edit, not the
    /// flush at quit.
    private func scheduleSave() {
        guard persistence == .persistent else { return }
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
