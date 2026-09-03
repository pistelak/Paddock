import Foundation

/// What the spaces column's footer says about a connection, or nothing when
/// the rows are live and speak for themselves.
///
/// A pure function so the copy for every state can be checked without a
/// window, and so the store's `ConnectionState` can stay a model type: it
/// carries *what* went wrong (`ReconnectReason`), and this is the one place
/// that turns it into words.
enum ConnectionFooter {
    static func text(for connection: WorkspaceStore.ConnectionState?) -> String? {
        guard let connection else { return "No session selected" }
        switch connection {
        case .live:
            return nil
        case .idle, .connecting:
            return "Connecting…"
        case .sessionNotRunning:
            return "Session not running"
        case let .reconnecting(reason):
            return "Reconnecting… \(text(for: reason))"
        case let .unsupportedProtocol(version):
            return "herdr protocol \(version); expected \(HerdrProtocol.supported)"
        }
    }

    static func text(for reason: WorkspaceStore.ReconnectReason) -> String {
        switch reason {
        case .streamEnded:
            "herdr closed the connection."
        case let .failed(error):
            error.errorDescription ?? String(describing: error)
        case let .unexpected(description):
            description
        }
    }
}
