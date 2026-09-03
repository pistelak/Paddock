import Foundation

/// How a terminal surface came to an end.
///
/// libghostty reports one bit, "is the process still alive"; the two states
/// it distinguishes mean different things to the user (the overlay's message)
/// and to the store (a detached herdr keeps answering its socket, an exited
/// one may be gone), so they get names rather than a `Bool` at three hops.
enum SurfaceEnd: Equatable, Sendable {
    /// The herdr client detached; the session keeps running server-side.
    case detached
    /// The herdr process exited; the session may be gone.
    case exited

    init(processAlive: Bool) {
        self = processAlive ? .detached : .exited
    }
}

/// What a pane reports upward. One enum instead of one closure per
/// concern, so bell and notification events can join without new plumbing.
enum TerminalPaneEvent: Equatable, Sendable {
    /// The terminal title changed; `nil` after a reattach cleared it.
    case titleChanged(String?)
    /// libghostty created the surface, so `herdr --session <name>` is starting
    /// in it right now: whoever is waiting on that session's socket should try
    /// again instead of sitting out its backoff.
    case surfaceAttached
    /// The surface ended, one way or the other.
    case surfaceClosed(SurfaceEnd)
}
