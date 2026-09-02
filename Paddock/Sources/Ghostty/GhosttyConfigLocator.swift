import Foundation

/// Where Ghostty itself would look for the user's configuration, in the
/// order libghostty's default loader uses. Only existing files are returned;
/// `nil` means "run with libghostty's built-in defaults".
enum GhosttyConfigLocator {
    static func path(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> String? {
        let xdgConfigHome = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(home)/.config"
        let candidates = [
            "\(xdgConfigHome)/ghostty/config",
            "\(home)/Library/Application Support/com.mitchellh.ghostty/config",
        ]
        return candidates.first { FileManager.default.isReadableFile(atPath: $0) }
    }

    static var themesSymlinkHint: String {
        """
        libghostty ships without theme files. If your config names a theme, link Ghostty.app's themes once:

        ln -s /Applications/Ghostty.app/Contents/Resources/ghostty/themes ~/.config/ghostty/themes
        """
    }
}
