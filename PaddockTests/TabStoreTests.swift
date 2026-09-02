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

    @Test func rejectsNewerFileFormatBeforeDecodingTabs() async throws {
        try write("{\"version\": 3, \"tabs\": [{\"unknown\": true}]}")
        let store = makeStore()
        await #expect(throws: PaddockError.unsupportedTabsFile(version: 3)) {
            _ = try await store.load()
        }
    }

    @Test func rejectsDuplicateSessionsInFile() async throws {
        try write("""
        {"version": 2, "tabs": [
          {"id": "60E1F8ED-364B-442A-AB67-90DB70F6B822", "sessionName": "work", "displayName": "a", "color": "blue"},
          {"id": "0382F4A0-7A89-48C7-8EDE-726D90ABE978", "sessionName": "work", "displayName": "b", "color": "red"}
        ]}
        """)
        let store = makeStore()
        let error = await #expect(throws: PaddockError.self) {
            _ = try await store.load()
        }
        guard case .corruptTabsFile = try #require(error) else {
            Issue.record("unexpected \(String(describing: error))")
            return
        }
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
