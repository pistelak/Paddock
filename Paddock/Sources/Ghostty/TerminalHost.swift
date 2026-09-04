import AppKit
import GhosttyKit
import GhosttyTerminal

/// Owns the single `TerminalController` (one `ghostty_app_t`) every surface
/// in the app shares, and remembers whether the user's config loaded.
@MainActor
final class TerminalHost {
    let controller: TerminalController
    let configurationIssue: String?

    init(configPath: String?) {
        controller = Self.makeController(configPath: configPath)
        configurationIssue = controller.lastConfigurationIssue
    }

    /// Resolves the same effective background Ghostty gives its surfaces.
    /// `setColorScheme` makes conditional themes follow this window before
    /// the finalized config is queried through libghostty.
    func backgroundColor(for appearance: NSAppearance) -> NSColor {
        let scheme: TerminalColorScheme = switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: .dark
        default: .light
        }
        controller.setColorScheme(scheme)
        return Self.backgroundColor(in: controller.renderedConfig) ?? .windowBackgroundColor
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

    private static func backgroundColor(in renderedConfig: String) -> NSColor? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("paddock-sidebar-\(UUID().uuidString).conf")
        guard let config = ghostty_config_new() else { return nil }
        defer {
            ghostty_config_free(config)
            try? FileManager.default.removeItem(at: url)
        }

        do {
            try renderedConfig.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        ghostty_config_load_file(config, url.path)
        ghostty_config_finalize(config)

        var color = ghostty_config_color_s()
        let key = "background"
        guard ghostty_config_get(config, &color, key, UInt(key.utf8.count)) else { return nil }
        let (red, green, blue) = (CGFloat(color.r) / 255, CGFloat(color.g) / 255, CGFloat(color.b) / 255)

        // The triple is only three bytes; `window-colorspace` says how the
        // renderer interprets them, and the sidebar must read them the same way.
        var colorspace: UnsafePointer<CChar>?
        let colorspaceKey = "window-colorspace"
        if ghostty_config_get(config, &colorspace, colorspaceKey, UInt(colorspaceKey.utf8.count)),
           let colorspace, String(cString: colorspace) == "display-p3" {
            return NSColor(displayP3Red: red, green: green, blue: blue, alpha: 1)
        }
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}
