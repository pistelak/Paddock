import Foundation

/// Finds the `herdr` executable. GUI apps launched from Finder or Xcode do
/// not inherit the login shell's PATH, so well-known Homebrew locations are
/// tried first and the login shell is consulted only as a fallback.
enum HerdrLocator {
    static let candidatePaths = [
        "/opt/homebrew/bin/herdr",
        "/usr/local/bin/herdr",
    ]

    /// How long the login shell gets. A `.zshrc` that blocks (a version
    /// manager phoning home, an `nvm` init, a prompt waiting on input) must
    /// not hold the launch: past this the answer is "not found" and the user
    /// gets the install hint instead of a window that never opens.
    static let loginShellTimeout: Duration = .seconds(3)

    static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> URL? {
        if let found = candidatePaths.first(where: FileManager.default.isExecutableFile(atPath:)) {
            return URL(fileURLWithPath: found)
        }
        return await locateViaLoginShell(environment: environment)
    }

    private static func locateViaLoginShell(environment: [String: String]) async -> URL? {
        let shell = environment["SHELL"] ?? "/bin/zsh"
        guard let result = try? await ProcessRunner.run(
            URL(fileURLWithPath: shell),
            arguments: ["-lc", "command -v herdr"],
            environment: environment,
            timeout: loginShellTimeout
        ), result.status == 0 else {
            return nil
        }
        let path = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}
