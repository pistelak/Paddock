import Foundation
import Testing
@testable import Paddock

/// A class suite so `deinit` can remove the temp directory: Swift Testing
/// builds one instance per `@Test`, so every test gets its own tabs file.
@MainActor
final class TabStoreTests {
    private let fileURL: URL

    init() {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaddockTests-\(UUID().uuidString)")
            .appendingPathComponent("tabs.json")
    }

    deinit {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func makeStore() -> TabStore {
        TabStore(fileURL: fileURL)
    }

    private func write(_ json: String) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(json.utf8).write(to: fileURL)
    }

    private func name(_ raw: String) throws -> SessionName {
        try SessionName(raw)
    }

    /// Seeding only reads the name; the rest is filled in from herdr's layout.
    private func session(
        _ raw: String,
        isDefault: Bool = false,
        isRunning: Bool = false
    ) throws -> HerdrSession {
        let sessionName = try name(raw)
        let socketPath = HerdrPaths.socketPath(for: sessionName)
        return HerdrSession(
            name: sessionName,
            socketPath: socketPath,
            sessionDirectory: (socketPath as NSString).deletingLastPathComponent,
            isDefault: isDefault,
            isRunning: isRunning
        )
    }

    @Test func loadReportsMissingFile() async throws {
        let store = makeStore()
        let loaded = try await store.load()
        #expect(!loaded)
        #expect(store.tabs.isEmpty)
    }

    @Test func seedAssignsDistinctColorsAndSkipsDuplicates() throws {
        let tabs = TabStore.seedTabs(from: [
            try session("default", isDefault: true, isRunning: true),
            try session("work"),
            try session("work"),
        ])
        #expect(tabs.map(\.sessionName.rawValue) == ["default", "work"])
        #expect(tabs[0].color != tabs[1].color)
    }

    @Test func roundTripKeepsLatestStateAfterRapidMutations() async throws {
        let store = makeStore()
        let work = try store.addTab(sessionName: name("work"))
        try store.addTab(sessionName: name("personal"))
        let scratch = try store.addTab(sessionName: name("scratch"))
        store.removeTab(id: scratch.id)
        store.renameTab(id: work.id, to: "  Work stuff ")
        store.recolorTab(id: work.id, to: .teal)
        await store.flush()

        let reloaded = makeStore()
        let loaded = try await reloaded.load()
        #expect(loaded)
        #expect(reloaded.tabs.map(\.sessionName.rawValue) == ["work", "personal"])
        #expect(reloaded.tabs.first?.id == work.id)
        #expect(reloaded.tabs.first?.displayName == "Work stuff")
        #expect(reloaded.tabs.first?.color == .teal)
    }

    @Test func moveTab() throws {
        let store = makeStore()
        let a = try store.addTab(sessionName: name("a"))
        let b = try store.addTab(sessionName: name("b"))
        let c = try store.addTab(sessionName: name("c"))
        var changes = 0
        store.onChange = { changes += 1 }

        store.moveTab(id: c.id, to: 0)
        #expect(store.tabs.map(\.id) == [c.id, a.id, b.id])
        store.moveTab(id: c.id, to: 99)
        #expect(store.tabs.map(\.id) == [a.id, b.id, c.id])
        store.moveTab(id: a.id, to: 0)
        store.moveTab(id: UUID(), to: 1)
        #expect(store.tabs.map(\.id) == [a.id, b.id, c.id])
        // didMutate is the only path to both onChange and a save, so the
        // notification count is the save count.
        #expect(changes == 2, "no-op moves must not notify (and therefore not save)")
    }

    @Test func replaceAllWithSameTabsIsNoOp() throws {
        let store = makeStore()
        try store.addTab(sessionName: name("work"))
        var changes = 0
        store.onChange = { changes += 1 }
        try store.replaceAll(store.tabs)
        #expect(changes == 0)
    }

    @Test func renameFallsBackToSessionNameWhenBlank() throws {
        let store = makeStore()
        let work = try store.addTab(sessionName: name("work"))
        store.renameTab(id: work.id, to: "Acme")
        store.renameTab(id: work.id, to: "   ")
        #expect(store.tab(withID: work.id)?.displayName == "work")
    }

    @Test func rejectsDuplicateSession() throws {
        let store = makeStore()
        try store.addTab(sessionName: name("work"))
        #expect(throws: PaddockError.duplicateSession("work")) {
            try store.addTab(sessionName: self.name("work"))
        }
    }

    @Test func migratesVersion1ColorIndex() async throws {
        try write("""
        {"version": 1, "tabs": [
          {"id": "60E1F8ED-364B-442A-AB67-90DB70F6B822", "sessionName": "work", "displayName": "", "colorIndex": 9}
        ]}
        """)
        let store = makeStore()
        _ = try await store.load()
        #expect(store.tabs.count == 1)
        #expect(store.tabs.first?.color == TabColorID.allCases[1])
        #expect(store.tabs.first?.displayName == "work", "blank display names normalise to the session name")

        await store.flush()
        let rewritten = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        #expect(
            rewritten?["version"] as? Int == TabsDocument.currentVersion,
            "a migrated file is rewritten in the current format"
        )
    }

    // MARK: - Load failures

    private static let duplicateSessionsJSON = """
    {"version": 2, "tabs": [
      {"id": "60E1F8ED-364B-442A-AB67-90DB70F6B822", "sessionName": "work", "displayName": "a", "color": "blue"},
      {"id": "0382F4A0-7A89-48C7-8EDE-726D90ABE978", "sessionName": "work", "displayName": "b", "color": "red"}
    ]}
    """

    private func loadFailure(of store: TabStore) async throws -> TabStore.LoadFailure {
        try #require(await #expect(throws: TabStore.LoadFailure.self) {
            _ = try await store.load()
        })
    }

    @Test func aNewerFileFormatIsReportedAsSuchBeforeDecodingTabs() async throws {
        try write("{\"version\": 3, \"tabs\": [{\"unknown\": true}]}")
        guard case let .newerVersion(version) = try await loadFailure(of: makeStore()) else {
            Issue.record("expected .newerVersion")
            return
        }
        #expect(version == 3)
    }

    /// A version Paddock has never written is not "newer": it is not a tab
    /// list this app can vouch for, and moving it aside is the right call.
    @Test func anUnknownOlderVersionIsInvalidContents() async throws {
        try write("{\"version\": 0, \"tabs\": []}")
        guard case .invalidContents = try await loadFailure(of: makeStore()) else {
            Issue.record("expected .invalidContents")
            return
        }
    }

    @Test func duplicateSessionsInTheFileAreInvalidContents() async throws {
        try write(Self.duplicateSessionsJSON)
        guard case let .invalidContents(reason) = try await loadFailure(of: makeStore()) else {
            Issue.record("expected .invalidContents")
            return
        }
        guard case .corruptTabsFile = reason as? PaddockError else {
            Issue.record("unexpected \(reason)")
            return
        }
    }

    @Test(arguments: [
        "{\"version\": 2, \"tabs\": [{\"id\": \"60E1F8ED-364B-442A-AB67-90DB70F6B822\"",
        "not json",
        "{\"version\": 2, \"tabs\": [{\"id\": \"60E1F8ED-364B-442A-AB67-90DB70F6B822\", \"sessionName\": \"bad name!\", \"displayName\": \"a\", \"color\": \"blue\"}]}",
    ])
    func unreadableJSONIsInvalidContents(json: String) async throws {
        try write(json)
        guard case .invalidContents = try await loadFailure(of: makeStore()) else {
            Issue.record("expected .invalidContents")
            return
        }
    }

    /// Something is at the path but it cannot be read as a file. These are
    /// deterministic (no reliance on permissions, which a privileged runner
    /// ignores) and each must be `.io`, never "missing": a missing file is
    /// what lets the caller write a fresh one.
    @Test func aSymlinkLoopAtThePathIsAnIOFailure() async throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: fileURL.path, withDestinationPath: fileURL.lastPathComponent)
        guard case .io = try await loadFailure(of: makeStore()) else {
            Issue.record("expected .io")
            return
        }
    }

    @Test func aDanglingSymlinkAtThePathIsAnIOFailure() async throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: fileURL.path, withDestinationPath: "does-not-exist.json")
        guard case .io = try await loadFailure(of: makeStore()) else {
            Issue.record("expected .io")
            return
        }
    }

    @Test func aDirectoryAtThePathIsAnIOFailure() async throws {
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: true)
        guard case .io = try await loadFailure(of: makeStore()) else {
            Issue.record("expected .io")
            return
        }
    }

    /// A symlink to a real file is fine — a user who keeps tabs.json in a
    /// dotfiles repo must not be told their file is unreadable.
    @Test func aSymlinkToARealFileLoads() async throws {
        let target = fileURL.deletingLastPathComponent().appendingPathComponent("real-tabs.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"version\": 2, \"tabs\": []}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(atPath: fileURL.path, withDestinationPath: target.lastPathComponent)
        #expect(try await makeStore().load())
    }

    // MARK: - Recovery

    /// The data-loss bug this guards: a file that failed to load must not be
    /// written over by the seeded replacement. Quarantine moves it aside with
    /// its bytes intact, and only then does a save go to the original path.
    @Test func quarantineMovesTheFileAsideWithItsBytesIntact() async throws {
        try write(Self.duplicateSessionsJSON)
        let original = try Data(contentsOf: fileURL)
        let store = makeStore()
        _ = try await loadFailure(of: store)

        let backup = try await store.quarantineFile()
        #expect(!FileManager.default.fileExists(atPath: fileURL.path), "the original path is free")
        #expect(backup.deletingLastPathComponent() == fileURL.deletingLastPathComponent(), "a sibling")
        #expect(backup.lastPathComponent.hasPrefix("tabs.json.unreadable-"))
        #expect(try Data(contentsOf: backup) == original)

        try store.replaceAll([SessionTab(sessionName: name("work"), color: .blue)])
        await store.flush()
        #expect(FileManager.default.fileExists(atPath: fileURL.path), "the fresh list was saved")
        #expect(try Data(contentsOf: backup) == original, "and the backup was not touched")
    }

    @Test func quarantineNeverOverwritesAnEarlierBackup() async throws {
        try write("first")
        let store = makeStore()
        let first = try await store.quarantineFile()
        try write("second")
        let second = try await store.quarantineFile()
        #expect(first != second)
        #expect(try String(decoding: Data(contentsOf: first), as: UTF8.self) == "first")
        #expect(try String(decoding: Data(contentsOf: second), as: UTF8.self) == "second")
    }

    /// The other half of the recovery: a file left in place (newer format, I/O
    /// error) must see zero writes for the rest of the run — not from seeding,
    /// not from an edit, not from the flush at quit.
    @Test func disablingSavingStopsEveryWrite() async throws {
        let newer = "{\"version\": 3, \"tabs\": []}"
        try write(newer)
        let store = makeStore()
        _ = try await loadFailure(of: store)
        store.disableSaving()
        #expect(store.persistence == .disabled)

        try store.replaceAll([SessionTab(sessionName: name("work"), color: .blue)])
        let work = try store.addTab(sessionName: name("personal"))
        store.renameTab(id: work.id, to: "Personal")
        store.removeTab(id: work.id)
        await store.flush()

        #expect(try String(decoding: Data(contentsOf: fileURL), as: UTF8.self) == newer, "original bytes untouched")
        #expect(store.tabs.count == 1, "the in-memory list still works")
    }

    // MARK: - Stored format

    /// The V2 file is decoded through a frozen stored type and `SessionTab`'s
    /// initialiser, so a blank name normalises exactly like a V1 one does.
    @Test(arguments: ["\"\"", "\"   \"", "null"])
    func version2BlankDisplayNamesNormaliseToTheSessionName(displayName: String) async throws {
        try write("""
        {"version": 2, "tabs": [
          {"id": "60E1F8ED-364B-442A-AB67-90DB70F6B822", "sessionName": "work", "displayName": \(displayName), "color": "teal"}
        ]}
        """)
        let store = makeStore()
        #expect(try await store.load())
        #expect(store.tabs.first?.displayName == "work")
        #expect(store.tabs.first?.color == .teal)
    }

    @Test func version2RoundTripsThroughTheStoredType() throws {
        let tabs = [
            SessionTab(sessionName: try name("work"), displayName: "Work", color: .teal),
            SessionTab(sessionName: try name("home"), color: .red),
        ]
        let decoded = try TabsDocument.decode(TabsDocument.encode(tabs))
        #expect(decoded.tabs == tabs)
        #expect(!decoded.needsUpgrade)
    }

    @Test func initials() throws {
        #expect(try SessionTab(sessionName: name("work"), color: .blue).initials == "WO")
        #expect(try SessionTab(sessionName: name("side-project"), color: .blue).initials == "SP")
        #expect(try SessionTab(sessionName: name("x"), displayName: "Acme Corp", color: .blue).initials == "AC")
    }

    @Test func leastUsedColor() {
        #expect(TabColorID.leastUsed(among: []) == .blue)
        #expect(TabColorID.leastUsed(among: [.blue]) == .green)
        #expect(TabColorID.leastUsed(among: TabColorID.allCases + [.blue]) == .green)
    }
}
