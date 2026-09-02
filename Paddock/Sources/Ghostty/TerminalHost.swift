import GhosttyTerminal

/// Owns the single `TerminalController` (one `ghostty_app_t`) every surface
/// in the app shares, and remembers whether the user's config loaded.
@MainActor
final class TerminalHost {
    let controller: TerminalController
    let configPath: String?
    let configurationIssue: String?

    init(configPath: String?) {
        self.configPath = configPath
        controller = TerminalController(configFilePath: configPath)
        configurationIssue = controller.lastConfigurationIssue
    }
}
