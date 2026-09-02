import Foundation

/// herdr refuses to start inside a herdr-managed pane, detected through the
/// `HERDR_*` variables it exports to its children. Paddock launched from such
/// a pane (`make run`, `open Paddock.app`) inherits them and every surface's
/// child would too, so they are removed from the process environment before
/// the first surface spawns.
enum HerdrEnvironment {
    static let markerPrefix = "HERDR_"

    static func inheritedMarkers(in environment: [String: String]) -> [String] {
        environment.keys.filter { $0.hasPrefix(markerPrefix) }.sorted()
    }

    /// Returns the variables that were removed.
    @discardableResult
    static func scrubInheritedMarkers() -> [String] {
        let keys = inheritedMarkers(in: ProcessInfo.processInfo.environment)
        for key in keys {
            unsetenv(key)
        }
        return keys
    }
}
