import Foundation

enum PaddockError: Error, LocalizedError, Equatable {
    case herdrNotFound
    case herdrCommandFailed(arguments: [String], status: Int32, stderr: String)
    case invalidSessionName(String)
    case duplicateSession(String)
    case unsupportedTabsFile(version: Int)
    case corruptTabsFile(String)
    case herdrSocketUnavailable(path: String)
    case herdrRPC(method: String, code: String, message: String)
    case herdrProtocolMismatch(found: Int)

    var errorDescription: String? {
        switch self {
        case .herdrNotFound:
            "herdr was not found. Install it with `brew install herdr` or put it on your login shell's PATH."
        case let .herdrCommandFailed(arguments, status, stderr):
            "`herdr \(arguments.joined(separator: " "))` exited with status \(status).\n\(stderr)"
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
        case let .herdrRPC(method, code, message):
            "herdr rejected `\(method)`: \(message) (\(code))."
        case let .herdrProtocolMismatch(found):
            "This herdr speaks API protocol \(found); Paddock was built for \(HerdrProtocol.supported)."
        }
    }
}
