import Foundation

/// What a pane reports upward. One enum instead of one closure per
/// concern, so bell and notification events can join without new plumbing.
enum TerminalPaneEvent: Sendable {
    /// The terminal title changed; `nil` after a reattach cleared it.
    case titleChanged(String?)
    /// libghostty created the surface, so `herdr --session <name>` is starting
    /// in it right now: whoever is waiting on that session's socket should try
    /// again instead of sitting out its backoff.
    case surfaceAttached
    /// The surface ended. `processAlive` tells a detach (herdr is still there,
    /// its API socket keeps answering) from an exit (the session may be gone).
    case surfaceClosed(processAlive: Bool)
}
