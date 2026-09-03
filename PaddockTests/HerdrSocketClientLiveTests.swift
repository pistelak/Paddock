import Foundation
import Testing
@testable import Paddock

/// Talks to a real herdr. Disabled unless `PADDOCK_LIVE_HERDR=1` is in the test
/// runner's environment, because it needs a running session; `make test` and
/// plain `xcodebuild test` therefore skip it. To actually run it, add the
/// variable to the Paddock scheme's Test action in Xcode (Product ▸ Scheme ▸
/// Edit Scheme ▸ Test ▸ Arguments), or from the command line inject it into
/// the generated `.xctestrun`:
///
///     xcodebuild build-for-testing -scheme Paddock -derivedDataPath DerivedData
///     # add PADDOCK_LIVE_HERDR=1 to EnvironmentVariables in
///     # DerivedData/Build/Products/Paddock_*.xctestrun, then
///     xcodebuild test-without-building -xctestrun DerivedData/Build/Products/Paddock_*.xctestrun \
///         -only-testing:PaddockTests/HerdrSocketClientLiveTests -destination platform=macOS
///
/// `PADDOCK_LIVE_HERDR_SOCKET` picks the session; it defaults to `work`.
/// Every call here is read-only: no herdr state is ever mutated.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PADDOCK_LIVE_HERDR"] == "1"))
struct HerdrSocketClientLiveTests {
    private let socketPath = ProcessInfo.processInfo.environment["PADDOCK_LIVE_HERDR_SOCKET"]
        ?? NSHomeDirectory() + "/.config/herdr/sessions/work/herdr.sock"

    @Test func pingReportsAProtocolVersion() async throws {
        let client = HerdrSocketClient(socketPath: socketPath)
        let ping: PingResult = try await client.request("ping")
        #expect(!ping.version.isEmpty)
        #expect(ping.protocolVersion > 0)
    }

    /// Also proves the one-request-per-connection rule is respected: a second
    /// request on the same client has to open its own connection.
    @Test func snapshotAndListDecodeAndTheClientIsReusable() async throws {
        let client = HerdrSocketClient(socketPath: socketPath)
        let snapshot: SessionSnapshotResult = try await client.request("session.snapshot")
        #expect(!snapshot.snapshot.workspaces.isEmpty)

        let list: WorkspaceListResult = try await client.request("workspace.list")
        #expect(
            Set(list.workspaces.map(\.workspaceID))
                == Set(snapshot.snapshot.workspaces.map(\.workspaceID))
        )
    }

    /// The ack is validated inside `events(_:)`, the backlog replay arrives
    /// right after it, and cancelling the consumer ends the loop cleanly
    /// rather than throwing.
    @Test func eventsReplayABacklogAndEndCleanlyOnCancellation() async throws {
        let client = HerdrSocketClient(socketPath: socketPath)
        let stream = try await client.events(HerdrSubscription.workspaceKinds)

        let consumer = Task {
            var events: [HerdrEventKind] = []
            for try await event in stream { events.append(event) }
            return events
        }
        try await Task.sleep(for: .seconds(3))
        consumer.cancel()
        let replayed = try await consumer.value
        #expect(!replayed.isEmpty, "an idle session still replays its historical workspace events")

        // The connection is gone, but the client is not: requests still work.
        let ping: PingResult = try await client.request("ping")
        #expect(ping.protocolVersion > 0)
    }

    /// The regression that made the spaces column unusable: an events stream
    /// stays parked in `read(2)` for as long as its tab exists, and while
    /// `FileHandle.bytes` did that reading, Foundation's shared machinery let
    /// it starve every other reader in the process — so the very next herdr
    /// request (a row click, a second session's snapshot) never returned.
    @Test func aRequestWorksWhileAnEventsStreamIsParked() async throws {
        let streaming = HerdrSocketClient(socketPath: socketPath)
        let stream = try await streaming.events(HerdrSubscription.workspaceKinds)

        let start = ContinuousClock.now
        let ping: PingResult = try await HerdrSocketClient(socketPath: socketPath).request("ping")
        #expect(ping.protocolVersion > 0)
        #expect(
            ContinuousClock.now - start < .seconds(5),
            "a parked stream must not hold up an unrelated request"
        )
        // Nothing iterates the stream: it has to stay alive (and parked) for
        // the whole request, which is exactly the situation that used to hang.
        withExtendedLifetime(stream) {}
    }

    @Test func anUnknownMethodSurfacesAsAnRPCError() async throws {
        let client = HerdrSocketClient(socketPath: socketPath)
        let error = try #require(
            await #expect(throws: PaddockError.self) {
                let _: PingResult = try await client.request("no.such.method")
            },
            "expected herdr to reject the method"
        )
        guard case let .herdrRPC(method, code, _) = error else {
            Issue.record("unexpected \(error)")
            return
        }
        #expect(method == "no.such.method")
        #expect(code == "invalid_request")
    }

    /// A rejected subscription throws from `events(_:)` itself, so the caller
    /// never gets a stream that is doomed to fail on first iteration.
    @Test func aRejectedSubscriptionThrowsBeforeTheStreamIsReturned() async throws {
        let client = HerdrSocketClient(socketPath: socketPath)
        let error = try #require(
            await #expect(throws: PaddockError.self) {
                _ = try await client.events([.paneAgentStatusChanged(paneID: "not-a-pane")])
            },
            "expected herdr to reject the subscription"
        )
        guard case let .herdrRPC(method, _, _) = error else {
            Issue.record("unexpected \(error)")
            return
        }
        #expect(method == "events.subscribe")
    }

    @Test func aMissingSocketReportsTheSessionAsUnavailable() async throws {
        let path = NSTemporaryDirectory() + "paddock-missing-\(UUID().uuidString).sock"
        let client = HerdrSocketClient(socketPath: path)
        await #expect(
            throws: PaddockError.herdrSocketUnavailable(path: path),
            "expected a connection failure"
        ) {
            let _: PingResult = try await client.request("ping")
        }
    }
}
