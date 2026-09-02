import Foundation
import GhosttyTerminal

/// Resolves ghostty's conditional `theme = dark:A,light:B` syntax out of a
/// user config, handing the light/dark split to the package instead.
///
/// A conditional value is the only thing a normal config puts in ghostty's
/// `_conditional_set`, and that set is what makes surface options vanish:
/// `Surface.init` re-derives the surface's config whenever the surface's
/// conditional state differs from the state the config was loaded with
/// (ghostty 1.3.1 `src/Surface.zig:468-484`), and that re-derivation replays
/// the config file from scratch (`src/config/Config.zig:4325-4338`). Only
/// `working-directory` is copied back across the rebuild, so every field the
/// embedded apprt set for *this* surface — `command`, `env`,
/// `wait-after-command` — is silently dropped, and the pane falls back to the
/// login shell. Paddock's panes are nothing but a `command`, so this is fatal.
///
/// Resolving the conditional here leaves the config unconditional, which keeps
/// the surface's `command` intact. Light/dark still switches, through
/// `TerminalTheme`: the package re-renders and pushes the new config to live
/// surfaces on an appearance change, which ghostty's own conditional does not
/// do for surfaces that already exist.
enum GhosttyConditionalTheme {
    struct Resolved: Equatable {
        /// The config text with the conditional `theme` lines removed.
        var base: String
        /// The light/dark themes those lines asked for.
        var theme: TerminalTheme
    }

    /// Returns `nil` when `contents` names no conditional theme, so a config
    /// that never needed rewriting is passed to libghostty untouched.
    ///
    /// `directory` is where `contents` was read from. The rewritten text is
    /// handed to libghostty as a generated file elsewhere, and ghostty
    /// resolves a relative `config-file` include against the file it appears
    /// in, so such includes are made absolute here to keep pointing at the
    /// user's config directory.
    static func resolve(_ contents: String, directory: URL? = nil) -> Resolved? {
        var keptLines: [String] = []
        var light: String?
        var dark: String?
        var foundConditional = false

        for line in contents.components(separatedBy: .newlines) {
            if let value = themeValue(in: line) {
                if let variants = conditionalVariants(in: value) {
                    // Ghostty is last-wins for repeated keys; match that.
                    foundConditional = true
                    light = variants.light ?? light
                    dark = variants.dark ?? dark
                } else {
                    // A later plain `theme = C` overrides both appearances in
                    // ghostty, so anything lifted before it must not win
                    // over it: the line stays, the variants are forgotten.
                    light = nil
                    dark = nil
                    keptLines.append(line)
                }
                continue
            }
            keptLines.append(absolutizedInclude(in: line, directory: directory))
        }

        guard foundConditional else { return nil }

        return Resolved(
            base: keptLines.joined(separator: "\n"),
            theme: TerminalTheme(
                light: themeConfiguration(named: light),
                dark: themeConfiguration(named: dark)
            )
        )
    }

    // MARK: - Parsing

    /// Rewrites a `config-file = path` line whose path is relative so it is
    /// absolute against `directory`; every other line is returned unchanged.
    /// Ghostty's optional-include marker (`?path`) is preserved.
    private static func absolutizedInclude(in line: String, directory: URL?) -> String {
        guard let directory else { return line }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: "=") else { return line }
        let key = trimmed[trimmed.startIndex ..< separator].trimmingCharacters(in: .whitespaces)
        guard key == "config-file" else { return line }
        var value = unquoted(trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespaces))
        let optionalMarker = value.hasPrefix("?") ? "?" : ""
        value = String(value.dropFirst(optionalMarker.count))
        guard !value.isEmpty, !value.hasPrefix("/"), !value.hasPrefix("~") else { return line }
        let absolute = directory.appendingPathComponent(value).path
        return "config-file = \(optionalMarker)\(absolute)"
    }

    /// The right-hand side of a `theme = …` line, unquoted; nil for anything
    /// else, including comments.
    private static func themeValue(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#") else { return nil }
        guard let separator = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[trimmed.startIndex ..< separator]
            .trimmingCharacters(in: .whitespaces)
        guard key == "theme" else { return nil }
        let value = trimmed[trimmed.index(after: separator)...]
            .trimmingCharacters(in: .whitespaces)
        return unquoted(value)
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }

    /// Splits `dark:A,light:B` into its variants. Nil when the value names no
    /// variant at all, i.e. it is an ordinary unconditional theme.
    private static func conditionalVariants(
        in value: String
    ) -> (light: String?, dark: String?)? {
        var light: String?
        var dark: String?

        for part in value.components(separatedBy: ",") {
            let entry = part.trimmingCharacters(in: .whitespaces)
            if let name = entry.dropPrefix("light:") {
                light = name
            } else if let name = entry.dropPrefix("dark:") {
                dark = name
            }
        }

        guard light != nil || dark != nil else { return nil }
        return (light, dark)
    }

    /// An empty configuration for a variant the user did not name, so that
    /// side keeps libghostty's own default rather than borrowing the other.
    private static func themeConfiguration(named name: String?) -> TerminalConfiguration {
        guard let name, !name.isEmpty else { return .init() }
        return TerminalConfiguration().custom("theme", name)
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }
}
