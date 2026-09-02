import Foundation
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
        controller = Self.makeController(configPath: configPath)
        configurationIssue = controller.lastConfigurationIssue
    }

    /// A config that resolves a `theme = dark:…,light:…` line is handed to
    /// libghostty with that line lifted into `TerminalTheme`; see
    /// ``GhosttyConditionalTheme`` for why a conditional config costs every
    /// pane its `command`. Anything else is loaded from the file as-is.
    private static func makeController(configPath: String?) -> TerminalController {
        guard
            let configPath,
            let contents = try? String(contentsOfFile: configPath, encoding: .utf8),
            let resolved = GhosttyConditionalTheme.resolve(
                contents,
                directory: URL(fileURLWithPath: configPath).deletingLastPathComponent()
            )
        else {
            return TerminalController(configFilePath: configPath)
        }

        return TerminalController(
            configSource: .generated(resolved.base),
            theme: resolved.theme
        )
    }
}
