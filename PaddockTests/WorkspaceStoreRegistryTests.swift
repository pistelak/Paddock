import Foundation
import Testing
@testable import Paddock

/// The registry is the one owner of every `WorkspaceStore`: it creates them
/// at the right socket path, is the only thing that stops them, and replaces
/// the ones herdr's session list contradicts.
@MainActor
struct WorkspaceStoreRegistryTests {
    private let clock = ManualClock()

    /// Every store the registry makes gets its own scripted herdr, so the
    /// test can tell them apart; the path it was made for is recorded.
    private final class Factory {
        var made: [(tab: SessionTab, socketPath: String, herdr: ScriptedHerdr)] = []
    }

    /// Every store connects cleanly to a one-workspace, pane-less session
    /// whose workspace reports `blocked`, so a test can wait for `.live` on
    /// the first connection (a pane would force a resubscribe through the
    /// connection floor) and still see a badge.
    private func makeRegistry() -> (WorkspaceStoreRegistry, Factory) {
        let factory = Factory()
        let clock = clock
        let registry = WorkspaceStoreRegistry { tab, socketPath in
            let herdr = ScriptedHerdr(alwaysReplying: [
                .ping: ScriptedHerdr.pong,
                .sessionSnapshot: ScriptedHerdr.snapshot(
                    workspaces: [("w1", 1, "code", true)],
                    workspaceStatus: "blocked"
                ),
            ])
            factory.made.append((tab, socketPath, herdr))
            return WorkspaceStore(sessionName: tab.sessionName, socketPath: socketPath, transport: herdr, clock: clock)
        }
        return (registry, factory)
    }

    /// A store that has demonstrably started: connected, with a stream open.
    private func live(_ store: WorkspaceStore) async throws {
        try await waitUntil { store.connection == .live }
    }

    private func tab(_ name: String) throws -> SessionTab {
        SessionTab(sessionName: try SessionName(name), color: .blue)
    }

    private func session(_ name: String, socketPath: String) throws -> HerdrSession {
        HerdrSession(
            name: try SessionName(name),
            socketPath: socketPath,
            sessionDirectory: (socketPath as NSString).deletingLastPathComponent,
            isDefault: false,
            isRunning: true
        )
    }

    @Test func aStoreIsCreatedOnceStartedAndReused() async throws {
        let (registry, factory) = makeRegistry()
        let work = try tab("work")

        let first = registry.store(for: work)
        let second = registry.store(for: work)
        #expect(first === second)
        #expect(factory.made.count == 1)
        #expect(registry.existingStore(for: work.id) === first)
        #expect(registry.existingStore(for: UUID()) == nil, "never creates by id")

        // Started on creation.
        try await live(first)
        registry.stopAll()
    }

    @Test func theFallbackPathIsUsedUntilHerdrSaysOtherwise() throws {
        let (registry, factory) = makeRegistry()
        let work = try tab("work")
        _ = registry.store(for: work)
        #expect(factory.made.last?.socketPath == HerdrPaths.socketPath(for: work.sessionName))

        registry.update(knownSessions: [try session("work", socketPath: "/elsewhere/herdr.sock")])
        #expect(registry.socketPath(for: work.sessionName) == "/elsewhere/herdr.sock")
        registry.stopAll()
    }

    /// The reason the registry owns the session list: a store started against
    /// the fallback path must not keep failing once herdr has named the real one.
    @Test func updateReplacesOnlyStoresWhosePathChangedAndReportsThem() async throws {
        let (registry, factory) = makeRegistry()
        let work = try tab("work")
        let home = try tab("home")
        let workStore = registry.store(for: work)
        let homeStore = registry.store(for: home)
        try await live(workStore)
        try await live(homeStore)

        let replaced = registry.update(knownSessions: [
            try session("work", socketPath: "/elsewhere/work.sock"),
            try session("home", socketPath: HerdrPaths.socketPath(for: home.sessionName)),
        ])
        #expect(replaced == [work.id])
        #expect(workStore.connection == .idle, "the replaced store was stopped")
        #expect(registry.existingStore(for: work.id) == nil, "and dropped")
        #expect(registry.existingStore(for: home.id) === homeStore, "the other one is untouched")
        #expect(homeStore.connection == .live)

        let recreated = registry.store(for: work)
        #expect(recreated !== workStore)
        #expect(factory.made.last?.socketPath == "/elsewhere/work.sock")
        registry.stopAll()
    }

    /// Dropping a *running* store stops it: no more requests, the stream gone,
    /// and it stays that way however much time passes.
    @Test func dropStopsTheStore() async throws {
        let (registry, factory) = makeRegistry()
        let work = try tab("work")
        let store = registry.store(for: work)
        try await live(store)
        let herdr = try #require(factory.made.first?.herdr)

        registry.drop(work.id)
        #expect(store.connection == .idle)
        #expect(registry.existingStore(for: work.id) == nil)
        try await waitUntil { store.observerCount == 0 }
        try await waitUntil { await herdr.openStreamCount == 0 }

        let requests = await herdr.requests.count
        clock.advance(by: .seconds(30))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await herdr.requests.count == requests, "a stopped store asks for nothing more")
        registry.drop(work.id) // idempotent
    }

    @Test func stopAllLeavesNothingRunning() async throws {
        let (registry, factory) = makeRegistry()
        let stores = try ["a", "b", "c"].map { registry.store(for: try tab($0)) }
        for store in stores { try await live(store) }

        registry.stopAll()
        #expect(stores.allSatisfy { $0.connection == .idle })
        #expect(registry.runningTabIDs.isEmpty)
        for made in factory.made {
            try await waitUntil { await made.herdr.openStreamCount == 0 }
        }
    }

    /// The tile badge: a store's aggregate status, once it has one.
    @Test func aggregateStatusFollowsTheStoreAndChangeIsReported() async throws {
        let (registry, _) = makeRegistry()
        let work = try tab("work")
        var changed: [UUID] = []
        registry.onChange = { changed.append($0) }
        #expect(registry.aggregateStatus(of: work.id) == nil, "no store, no badge")

        let store = registry.store(for: work)
        defer { registry.stopAll() }
        try await live(store)

        #expect(registry.aggregateStatus(of: work.id) == .blocked)
        try await waitUntil { changed.contains(work.id) }
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: @MainActor () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("condition not met within \(timeout)", sourceLocation: sourceLocation)
    }
}
