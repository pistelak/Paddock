import Foundation
import Testing
@testable import Paddock

/// The failure modes a session's store has to survive, against a real herdr:
/// a session that stops under it, a stale socket file left behind, several
/// sessions live at once.
///
/// Disabled unless `PADDOCK_LIVE_HERDR=1`, like the other live suites; see
/// `WorkspaceStoreLiveTests` for the `.xctestrun` recipe.
///
/// Everything destructive happens to one throwaway session — `paddock-qa-`
/// plus a random suffix by default, `PADDOCK_LIVE_HERDR_QA_SESSION` to
/// override — which the suite starts headlessly (`herdr --session <name>
/// server`) and stops again, and then gives a space of its own — see
/// `ensureQASpace()`, a headless session has none. The suite refuses a
/// session that already exists, running or stopped, so an override can never
/// point it at a session with the user's data in it. No session the user is
/// working in is ever stopped; `work` and `default` are only read from.
///
/// Swift Testing has no async teardown (`deinit` cannot await), so the session
/// lifecycle is a scoped helper: every test runs inside `withQASession`, which
/// stops and deletes the session again on the way out, success or failure.
/// The suite is `.serialized` because that one session is shared state: run in
/// parallel, one test's teardown stops the session another test is watching.
@MainActor
@Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["PADDOCK_LIVE_HERDR"] == "1")
)
struct WorkspaceStoreHardeningLiveTests {
    /// A fresh name per suite instance: the session is then guaranteed to be
    /// this run's own, and the `herdr session delete` at the end cannot hit a
    /// stopped session somebody kept under a fixed name.
    private static var defaultQASessionName: String {
        "paddock-qa-" + UUID().uuidString.lowercased().prefix(8)
    }

    /// Whether the running test started the throwaway session, and so owns it.
    /// A box rather than a `var` on the suite: `withQASession` and a restart
    /// inside a test body both write to it, and only the owner tears it down.
    @MainActor
    private final class Ownership {
        var owned = false
    }

    private let herdrExecutable: URL
    private let qaSession: SessionName

    private var herdr: HerdrCLI { HerdrCLI(executableURL: herdrExecutable) }

    init() async throws {
        let environment = ProcessInfo.processInfo.environment
        herdrExecutable = try #require(await HerdrLocator.locate(), "herdr is not installed")
        qaSession = try SessionName(
            environment["PADDOCK_LIVE_HERDR_QA_SESSION"] ?? Self.defaultQASessionName
        )
    }

    // MARK: - A session that stops while watched

    /// `herdr session stop` while a store is watching that session: the
    /// connection has to read "session not running", the last state has to
    /// stay (so a tile can keep, and later dim, its indicator), and a session that
    /// comes back has to repopulate them without the store being recreated.
    ///
    /// This is also the stale-socket case: herdr leaves the socket *file*
    /// behind when a session stops, so the reconnect gets `ECONNREFUSED`
    /// rather than `ENOENT`, and both have to read as "not running".
    @Test func aSessionThatStopsKeepsItsRowsAndComesBack() async throws {
        try await withQASession { ownership in
            let store = WorkspaceStore(sessionName: qaSession, socketPath: qaSocketPath)
            store.start()
            defer { store.stop() }
            try await waitUntil(timeout: .seconds(20)) {
                store.connection.isConnected && !store.state.workspaces.isEmpty
            }
            let rowsWhileLive = store.state.workspaces

            try await herdr.stopSession(qaSession)
            try await waitUntil(timeout: .seconds(30)) { store.connection == .sessionNotRunning }
            // Whether herdr unlinked its socket file on the way out decides which
            // errno the reconnect saw — `ECONNREFUSED` for a stale file, `ENOENT`
            // for none. Both have to land on `.sessionNotRunning`; naming which
            // one it was makes a failure here readable.
            let socketFileSurvived = FileManager.default.fileExists(atPath: qaSocketPath)
            #expect(
                store.connection == .sessionNotRunning,
                "socket file left behind: \(socketFileSurvived)"
            )
            #expect(
                store.state.workspaces == rowsWhileLive,
                "a stopped session keeps its last state; the tile dims instead of clearing"
            )

            try await startQASession(ownership)
            // What the coordinator does when a pane's surface attaches.
            store.retryNow()
            try await waitUntil(timeout: .seconds(30)) {
                store.connection.isConnected && !store.state.workspaces.isEmpty
            }
            #expect(store.state.focusedID != nil)
        }
    }

    /// Quitting the herdr *client* leaves the daemon serving the session, so
    /// the store must not so much as blink. (A TUI quit detaches the same
    /// way; killing the attached client is the scriptable version of it.)
    @Test func killingTheAttachedClientLeavesTheStoreLive() async throws {
        try await withQASession { _ in
            let store = WorkspaceStore(sessionName: qaSession, socketPath: qaSocketPath)
            store.start()
            defer { store.stop() }
            try await waitUntil(timeout: .seconds(20)) { store.connection.isConnected }

            let client = try attachThrowawayClient()
            defer { if client.isRunning { client.terminate() } }
            try await Task.sleep(for: .seconds(2))
            client.terminate()
            try await Task.sleep(for: .seconds(2))

            #expect(
                store.connection.isConnected,
                "the daemon still serves the session, so the events connection is untouched"
            )
        }
    }

    // MARK: - Several sessions at once

    /// Three sessions' stores running side by side, which is what
    /// three visited tabs leave behind. Each one has to reach its own session.
    @Test func threeSessionsAreLiveAtTheSameTime() async throws {
        try await withQASession { _ in
            let sessions = try await liveSessionNames(atLeast: 3)
            let stores = sessions.map {
                WorkspaceStore(sessionName: $0, socketPath: HerdrPaths.socketPath(for: $0))
            }
            for store in stores { store.start() }
            defer { for store in stores { store.stop() } }

            try await waitUntil(timeout: .seconds(30)) {
                stores.allSatisfy { $0.connection.isConnected && !$0.state.workspaces.isEmpty }
            }
            // Different sessions never share workspace ids, so this also proves
            // the three stores are not all talking to the same socket.
            let identifiers = stores.map { Set($0.state.workspaces.map(\.id)) }
            for (index, ids) in identifiers.enumerated() {
                for (other, otherIDs) in identifiers.enumerated() where other != index {
                    #expect(ids.isDisjoint(with: otherIDs), "two stores share workspace ids")
                }
            }
        }
    }

    // MARK: - Helpers

    private var qaSocketPath: String {
        HerdrPaths.socketPath(for: qaSession)
    }

    /// Runs `body` with the throwaway session up, then stops and deletes it if
    /// this test was the one that started it — Swift Testing's stand-in for an
    /// async `tearDown`.
    private func withQASession(_ body: (Ownership) async throws -> Void) async throws {
        let ownership = Ownership()
        do {
            try await startQASession(ownership)
            try await body(ownership)
        } catch {
            await stopQASession(ownership)
            throw error
        }
        await stopQASession(ownership)
    }

    /// Starts the throwaway session headlessly and waits for its socket to
    /// answer. `herdr --session <name> server` is the one way to have a
    /// session without a terminal to attach it to. Ownership is recorded
    /// *before* the daemon is launched, so a failure while waiting for it
    /// still tears the session down.
    ///
    /// A session that is already up is left alone, but it still goes through
    /// `ensureQASpace()`: the restart in the middle of
    /// `aSessionThatStopsKeepsItsRowsAndComesBack` comes back through here and
    /// has to find its spaces again. A session this run does not own yet must
    /// not exist at all, not even stopped, because teardown deletes it.
    private func startQASession(_ ownership: Ownership) async throws {
        if try await isRunning(qaSession) {
            try await ensureQASpace()
            return
        }
        if !ownership.owned, try await exists(qaSession) {
            throw PaddockError.invalidSessionName(
                "\(qaSession): already exists; the live suite only works on a session it created"
            )
        }
        ownership.owned = true
        let command = "\(ShellQuote.singleQuoted(herdrExecutable.path))"
            + " --session \(ShellQuote.singleQuoted(qaSession.rawValue)) server"
        // Detached through `sh`, because the server never exits and
        // `ProcessRunner` waits for the processes it runs.
        _ = try await ProcessRunner.run(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "nohup \(command) >/dev/null 2>&1 &"]
        )
        try await waitUntil(timeout: .seconds(20)) {
            (try? await isRunning(qaSession)) == true
        }
        try await ensureQASpace()
    }

    /// Gives the throwaway session a space, because a headless one has none.
    ///
    /// `herdr … server` only opens its first workspace when it is started from
    /// inside a herdr pane — it takes the cwd for it from `HERDR_STARTUP_CWD`,
    /// which the Xcode test runner's environment does not carry (verified
    /// against herdr 0.8.0: the same `server` command started with that
    /// variable set snapshots `workspaces: [w1]`, and without it
    /// `workspaces: []`). So the session this suite starts comes up connected,
    /// live and *empty*, and every assertion about spaces or focus needs a space
    /// created by hand first.
    ///
    /// herdr persists the space, so the restart inside a test finds it again
    /// and this is a no-op the second time round.
    private func ensureQASpace() async throws {
        let client = HerdrSocketClient(socketPath: qaSocketPath)
        // `herdr session list` calls the session running a moment before its
        // socket answers, so the first request may still be refused.
        try await waitUntil(timeout: .seconds(20)) {
            (try? await client.request(.workspaceList) as WorkspaceListResult) != nil
        }
        let existing: WorkspaceListResult = try await client.request(.workspaceList)
        guard existing.workspaces.isEmpty else { return }
        try await client.send(
            .workspaceCreate,
            params: CreateWorkspaceParams(label: qaSession.rawValue, focus: true)
        )
        try await waitUntil(timeout: .seconds(10)) {
            let list = try? await client.request(.workspaceList) as WorkspaceListResult
            return list?.workspaces.isEmpty == false
        }
    }

    /// A session this test started must not outlive it: a leftover daemon
    /// would show up in the user's `herdr session list` and skew later runs.
    private func stopQASession(_ ownership: Ownership) async {
        guard ownership.owned else { return }
        ownership.owned = false
        try? await herdr.stopSession(qaSession)
        try? await waitUntil(timeout: .seconds(10)) {
            (try? await isRunning(qaSession)) == false
        }
        try? await herdr.deleteSession(qaSession)
    }

    private func attachThrowawayClient() throws -> Process {
        let process = Process()
        // `script` gives herdr the pty it insists on; the client's output is
        // of no interest and goes nowhere.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = [
            "-q", "/dev/null",
            herdrExecutable.path, "--session", qaSession.rawValue,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    private func isRunning(_ name: SessionName) async throws -> Bool {
        try await herdr.listSessions().contains { $0.name == name && $0.isRunning }
    }

    private func exists(_ name: SessionName) async throws -> Bool {
        try await herdr.listSessions().contains { $0.name == name }
    }

    /// The running sessions to test against, the throwaway one first so a
    /// machine with only it and `default` still has two. Too few running
    /// sessions used to skip the test; Swift Testing has no mid-test skip, so
    /// it is a failure of an opt-in suite instead.
    private func liveSessionNames(atLeast count: Int) async throws -> [SessionName] {
        let running = try await herdr.listSessions().filter(\.isRunning).map(\.name)
        let ordered = [qaSession] + running.filter { $0 != qaSession }
        try #require(ordered.count >= count, "needs \(count) running herdr sessions")
        return Array(ordered.prefix(count))
    }

    private func waitUntil(
        timeout: Duration,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("condition not met within \(timeout)", sourceLocation: sourceLocation)
    }
}

/// `workspace.create`'s params, kept by the test alone: Paddock no longer
/// creates workspaces itself, but the QA session needs one to have any state.
private struct CreateWorkspaceParams: Encodable {
    let label: String
    let focus: Bool
}
