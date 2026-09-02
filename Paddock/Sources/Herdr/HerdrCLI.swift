import Foundation

/// Thin async wrapper over the `herdr` command line for the few calls the
/// app needs. Attaching to a session is not here: that is done by the
/// terminal surface running `herdr --session <name>` directly.
struct HerdrCLI: Sendable {
    let executableURL: URL

    /// The sessions herdr knows about, with the socket path it reports for
    /// each. `--json` is asked for rather than the human table because the
    /// table has no stable column widths and drops the socket on narrow
    /// terminals.
    func listSessions() async throws -> [HerdrSession] {
        let output = try await run(["session", "list", "--json"])
        return try JSONDecoder().decode(HerdrSessionList.self, from: Data(output.utf8)).sessions
    }

    func stopSession(_ name: SessionName) async throws {
        _ = try await run(["session", "stop", name.rawValue])
    }

    /// Removes a stopped session's directory. herdr refuses while it runs.
    func deleteSession(_ name: SessionName) async throws {
        _ = try await run(["session", "delete", name.rawValue])
    }

    private func run(_ arguments: [String]) async throws -> String {
        let result = try await ProcessRunner.run(executableURL, arguments: arguments)
        guard result.status == 0 else {
            throw PaddockError.herdrCommandFailed(
                arguments: arguments,
                status: result.status,
                stderr: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result.standardOutput
    }
}
