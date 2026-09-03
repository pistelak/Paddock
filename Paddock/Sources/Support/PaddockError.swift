import Foundation

enum PaddockError: Error, LocalizedError, Equatable {
    case herdrNotFound
    case herdrCommandFailed(arguments: [String], status: Int32, stderr: String)
    case commandTimedOut(arguments: [String], after: Duration)
    case invalidSessionName(String)
    case duplicateSession(String)
    case unsupportedTabsFile(version: Int)
    case corruptTabsFile(String)
    case herdrSocketUnavailable(path: String)
    /// A second reader was asked for on a socket connection that already has
    /// one; see `UnixSocketConnection.makeLines()`.
    case herdrSocketAlreadyReading(path: String)
    case herdrRPC(method: HerdrMethod, code: String, message: String)
    case herdrTimeout(method: HerdrMethod)
    case herdrConnectionClosed(method: HerdrMethod)
    /// A `session.snapshot` that contradicts itself (duplicate workspace ids,
    /// a pane in a workspace that is not listed, a focused id that names no
    /// workspace). Never applied; reported as a reconnect.
    case herdrSnapshotInvalid(String)

    var errorDescription: String? {
        switch self {
        case .herdrNotFound:
            "herdr was not found. Install it with `brew install herdr` or put it on your login shell's PATH."
        case let .herdrCommandFailed(arguments, status, stderr):
            "`herdr \(arguments.joined(separator: " "))` exited with status \(status).\n\(stderr)"
        case let .commandTimedOut(arguments, after):
            "`\(arguments.joined(separator: " "))` did not finish within \(after) and was terminated."
        case let .invalidSessionName(name):
            "“\(name)” is not a valid session name. Use up to \(SessionName.maximumLength) ASCII letters, digits, dots, dashes or underscores."
        case let .duplicateSession(name):
            "A tab for the session “\(name)” already exists."
        case let .unsupportedTabsFile(version):
            "The saved tab list has format version \(version), which this version of Paddock cannot read."
        case let .corruptTabsFile(reason):
            "The saved tab list is not usable: \(reason)."
        case let .herdrSocketUnavailable(path):
            "No herdr is listening on \(path). The session is probably not running yet."
        case let .herdrSocketAlreadyReading(path):
            "The connection to \(path) is already being read."
        case let .herdrRPC(method, code, message):
            "herdr rejected `\(method)`: \(message) (\(code))."
        case let .herdrTimeout(method):
            "herdr did not answer `\(method)` within \(HerdrSocketClient.requestTimeout)."
        case let .herdrConnectionClosed(method):
            "herdr closed the connection before answering `\(method)`."
        case let .herdrSnapshotInvalid(reason):
            "herdr sent an inconsistent snapshot: \(reason)."
        }
    }
}
