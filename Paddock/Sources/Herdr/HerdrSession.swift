import Foundation

/// One herdr session as `herdr session list --json` reports it.
///
/// `socketPath` is the reason this type exists in its current shape: it is the
/// authoritative address of the session's API socket, and Paddock only falls
/// back to `HerdrPaths.socketPath(for:)` for sessions herdr has never created.
struct HerdrSession: Hashable, Sendable {
    let name: SessionName
    let socketPath: String
    let sessionDirectory: String
    let isDefault: Bool
    let isRunning: Bool
}

/// The payload of `herdr session list --json`:
///
///     {"sessions":[{"default":true,"name":"default","running":true,
///                   "session_dir":"…","socket_path":"…/herdr.sock"}]}
///
/// Rows whose name Paddock could not use as a `SessionName` are dropped rather
/// than thrown, so a `HerdrSession` always carries a usable name and one odd
/// session cannot make the whole list unavailable. For the same reason every
/// field except the name is optional here: a future herdr that renames or
/// drops one of them costs a fallback value, not the session list.
struct HerdrSessionList: Decodable, Sendable {
    let sessions: [HerdrSession]

    private enum CodingKeys: String, CodingKey {
        case sessions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try container.decode([Row].self, forKey: .sessions).compactMap(\.session)
    }

    private struct Row: Decodable {
        let name: String
        let running: Bool?
        let isDefault: Bool?
        let sessionDirectory: String?
        let socketPath: String?

        enum CodingKeys: String, CodingKey {
            case name
            case running
            case isDefault = "default"
            case sessionDirectory = "session_dir"
            case socketPath = "socket_path"
        }

        /// `nil` for a name Paddock cannot use — it would be interpolated into
        /// a shell-parsed Ghostty `command`, so an unusable name means the
        /// session is not addressable at all.
        var session: HerdrSession? {
            guard let name = try? SessionName(name) else { return nil }
            let socketPath = socketPath ?? HerdrPaths.socketPath(for: name)
            return HerdrSession(
                name: name,
                socketPath: socketPath,
                sessionDirectory: sessionDirectory ?? (socketPath as NSString).deletingLastPathComponent,
                isDefault: isDefault ?? (name.rawValue == HerdrPaths.defaultSessionName),
                isRunning: running ?? false
            )
        }
    }
}
