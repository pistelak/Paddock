import Foundation

/// Where a session's API socket lives when `herdr session list` has not named
/// it. A tab may point at a session herdr has never created, and the spaces
/// store still needs an address to try — it starts answering the moment the
/// surface brings the session up.
///
/// Mirrors herdr's own layout: the `default` session owns the config directory
/// itself, every other session a `sessions/<name>` subdirectory.
enum HerdrPaths {
    static let defaultSessionName = "default"
    static let socketFileName = "herdr.sock"

    /// `~/.config/herdr`, resolving `XDG_CONFIG_HOME` exactly like
    /// `GhosttyConfigLocator` does — an empty value counts as unset.
    static func configDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> URL {
        let xdgConfigHome = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(home)/.config"
        return URL(fileURLWithPath: xdgConfigHome, isDirectory: true)
            .appendingPathComponent("herdr", isDirectory: true)
    }

    static func socketPath(
        for name: SessionName,
        configDirectory: URL = HerdrPaths.configDirectory()
    ) -> String {
        let directory = name.rawValue == defaultSessionName
            ? configDirectory
            : configDirectory
                .appendingPathComponent("sessions", isDirectory: true)
                .appendingPathComponent(name.rawValue, isDirectory: true)
        return directory.appendingPathComponent(socketFileName).path
    }
}
