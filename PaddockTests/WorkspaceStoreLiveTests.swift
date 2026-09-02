import Foundation
import Testing
@testable import Paddock

/// Drives a real `WorkspaceStore` against a running herdr session. Disabled
/// unless `PADDOCK_LIVE_HERDR=1` is in the test runner's environment, so
/// `make test` and plain `xcodebuild test` never touch a socket.
///
/// To run it from the command line, inject the variable into the generated
/// `.xctestrun` (the scheme has no way to set it per-invocation):
///
///     xcodebuild build-for-testing -scheme Paddock -configuration Debug \
///         -derivedDataPath DerivedData -quiet
///     # the format-1 xctestrun keys the variables under the target's own node,
///     # not under TestConfigurations:
///     /usr/libexec/PlistBuddy -c \
///         'Add :PaddockTests:EnvironmentVariables:PADDOCK_LIVE_HERDR string 1' \
///         DerivedData/Build/Products/Paddock_macosx*.xctestrun
///     xcodebuild test-without-building -destination platform=macOS \
///         -xctestrun DerivedData/Build/Products/Paddock_macosx*.xctestrun \
///         -only-testing:PaddockTests/WorkspaceStoreLiveTests
///
/// `PADDOCK_LIVE_HERDR_SOCKET` picks the session; it defaults to `work`.
/// Everything here is read-only except `aThrowawaySpaceSurvivesEveryMutation`,
/// which creates a space of its own and only ever focuses, renames and closes
/// *that* one — no space the user made is touched.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PADDOCK_LIVE_HERDR"] == "1"))
struct WorkspaceStoreLiveTests {
    private let socketPath = ProcessInfo.processInfo.environment["PADDOCK_LIVE_HERDR_SOCKET"]
        ?? NSHomeDirectory() + "/.config/herdr/sessions/work/herdr.sock"

    /// The whole connect path in one test: ping, subscribe, snapshot, then the
    /// backlog replay reduced into rows — and a `stop()` that really stops.
    @MainActor
    @Test func theStoreGoesLiveAndFillsItsRows() async throws {
        let store = WorkspaceStore(sessionName: try SessionName("work"), socketPath: socketPath)
        var notifications = 0
        store.onChange = { notifications += 1 }

        store.start()
        try await waitUntil(timeout: .seconds(20)) {
            store.connection.isConnected && !store.state.workspaces.isEmpty
        }

        #expect(store.connection == .live, "protocol \(HerdrProtocol.supported) was expected")
        #expect(!store.state.workspaces.isEmpty)
        #expect(store.state.focusedID != nil, "herdr always has exactly one focused space")
        #expect(store.state.workspaces.filter(\.focused).count == 1)
        // Panes are what the per-pane status subscriptions are built from; a
        // live session always has at least one.
        #expect(!store.state.paneIDs.isEmpty)
        #expect(
            WorkspaceStore.subscriptions(for: store.state).count
                == HerdrSubscription.workspaceKinds.count
                + HerdrSubscription.paneKinds.count
                + store.state.paneIDs.count
        )

        // The backlog replay alone is dozens of events; coalescing means the
        // column repaints a handful of times, not once per event.
        #expect(notifications > 0)
        #expect(notifications < 40, "onChange is coalesced, \(notifications) is too many")

        store.stop()
        #expect(store.connection == .idle)
        let afterStop = notifications
        try await Task.sleep(for: .seconds(1))
        #expect(notifications == afterStop, "no onChange may fire after stop()")
        // The rows survive a stop so a reselected tab has something to draw.
        #expect(!store.state.workspaces.isEmpty)
    }

    /// Reconnecting has to work from a store that has already run once, and
    /// `retryNow()` must not disturb a healthy connection.
    @MainActor
    @Test func aStoppedStoreReconnects() async throws {
        let store = WorkspaceStore(sessionName: try SessionName("work"), socketPath: socketPath)
        store.start()
        try await waitUntil(timeout: .seconds(20)) { store.connection.isConnected }
        store.stop()

        store.start()
        try await waitUntil(timeout: .seconds(20)) { store.connection.isConnected }
        store.retryNow()
        #expect(store.connection.isConnected, "a live connection is left alone")
        store.stop()
    }

    /// The four mutations the coordinator wires to the column, against a real
    /// herdr, on a space this test creates for the purpose: create, focus,
    /// rename, close. Each one is verified the way the column sees it — by
    /// waiting for the `workspace_*` event to come back down the stream and
    /// change `state` — because that round trip *is* the contract: the store
    /// never applies a mutation to its own rows.
    @MainActor
    @Test func aThrowawaySpaceSurvivesEveryMutation() async throws {
        let store = WorkspaceStore(sessionName: try SessionName("work"), socketPath: socketPath)
        store.start()
        defer { store.stop() }
        try await waitUntil(timeout: .seconds(20)) {
            store.connection.isConnected && !store.state.workspaces.isEmpty
        }

        // Anything an interrupted earlier run left behind goes first, so a
        // live session never accumulates junk.
        await closeThrowawaySpaces(in: store)

        let label = Self.throwawayPrefix + String(UInt32.random(in: 0 ... .max))
        let existing = Set(store.state.workspaces.map(\.workspaceID))
        try await store.create(label: label)

        do {
            try await waitUntil(timeout: .seconds(10)) {
                store.state.workspaces.contains { !existing.contains($0.workspaceID) && $0.label == label }
            }
            let workspaceID = try #require(
                store.state.workspaces.first { !existing.contains($0.workspaceID) && $0.label == label }
            ).workspaceID

            // `create` asks for focus, so the pill has already moved; calling
            // `focus` again is exactly what a row click does and has to be
            // idempotent.
            try await store.focus(workspaceID)
            try await waitUntil(timeout: .seconds(10)) { store.state.focusedID == workspaceID }
            #expect(store.state.workspaces.filter(\.focused).count == 1)

            try await store.rename(workspaceID, to: label + "-renamed")
            try await waitUntil(timeout: .seconds(10)) {
                store.state.workspace(workspaceID)?.label == label + "-renamed"
            }

            try await store.close(workspaceID)
            try await waitUntil(timeout: .seconds(10)) { store.state.workspace(workspaceID) == nil }
            #expect(
                Set(store.state.workspaces.map(\.workspaceID)) == existing,
                "closing the throwaway space leaves the session exactly as it was found"
            )
        } catch {
            await closeThrowawaySpaces(in: store)
            throw error
        }
    }

    /// The label prefix that marks a space as this test's own. Nothing else is
    /// ever closed.
    private static let throwawayPrefix = "paddock-e2e-"

    /// Closes leftovers and waits for herdr to confirm each close, so a
    /// baseline taken right afterwards cannot still contain them.
    @MainActor
    private func closeThrowawaySpaces(in store: WorkspaceStore) async {
        _ = try? await store.refreshFromSnapshot()
        let leftovers = store.state.workspaces
            .filter { $0.label.hasPrefix(Self.throwawayPrefix) }
            .map(\.workspaceID)
        for workspaceID in leftovers {
            try? await store.close(workspaceID)
        }
        try? await waitUntil(timeout: .seconds(10)) {
            leftovers.allSatisfy { store.state.workspace($0) == nil }
        }
    }

    @MainActor
    private func waitUntil(
        timeout: Duration,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("condition not met within \(timeout)", sourceLocation: sourceLocation)
    }
}
