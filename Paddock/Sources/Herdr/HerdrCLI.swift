import Foundation

/// Thin async wrapper over the `herdr` command line for the few calls the
/// app needs. Attaching to a session is not here: that is done by the
/// terminal surface running `herdr --session <name>` directly.
struct HerdrCLI: Sendable {
    let executableURL: URL

    func listSessions() async throws -> [HerdrSession] {
        let output = try await run(["session", "list"])
        return HerdrSessionListParser.parse(output)
    }

    func stopSession(_ name: SessionName) async throws {
        _ = try await run(["session", "stop", name.rawValue])
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
