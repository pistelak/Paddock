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
/// Everything here is read-only: nothing in this suite mutates the session.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PADDOCK_LIVE_HERDR"] == "1"))
struct WorkspaceStoreLiveTests {
    private let socketPath = ProcessInfo.processInfo.environment["PADDOCK_LIVE_HERDR_SOCKET"]
        ?? NSHomeDirectory() + "/.config/herdr/sessions/work/herdr.sock"

    /// The whole connect path in one test: ping, subscribe, snapshot, then the
    /// backlog replay reduced into one state — and a `stop()` that really stops.
    @MainActor
    @Test func theStoreGoesLiveAndFillsItsRows() async throws {
        let store = WorkspaceStore(sessionName: try SessionName("work"), socketPath: socketPath)
        var notifications = 0
        let observation = store.observe { notifications += 1 }
        defer { observation.cancel() }

        store.start()
        try await waitUntil(timeout: .seconds(20)) {
            store.connection.isConnected && !store.state.workspaces.isEmpty
        }

        #expect(store.connection == .live, "protocol \(HerdrProtocol.supported) was expected")
        #expect(!store.state.workspaces.isEmpty)
        #expect(store.state.focusedID != nil, "herdr always has exactly one focused space")
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
        // tile repaints a handful of times, not once per event.
        #expect(notifications > 0)
        #expect(notifications < 40, "notifications are coalesced, \(notifications) is too many")

        store.stop()
        #expect(store.connection == .idle)
        let afterStop = notifications
        try await Task.sleep(for: .seconds(1))
        #expect(notifications == afterStop, "no observer may be called after stop()")
        // The state survives a stop so a restarted store has something to show.
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
