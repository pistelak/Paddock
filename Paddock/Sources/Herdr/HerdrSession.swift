import Foundation

struct HerdrSession: Hashable, Sendable {
    enum Status: String, Sendable {
        case running
        case stopped
        case unknown
    }

    let name: SessionName
    let status: Status
}

/// Parses the table printed by `herdr session list`:
///
///     name      status   directory                  socket
///     default   running  /Users/me/.config/herdr    /Users/me/.config/herdr/herdr.sock
///
/// Rows whose name Paddock could not use as a session name are dropped here,
/// so a `HerdrSession` always carries a usable `SessionName`.
enum HerdrSessionListParser {
    static func parse(_ output: String) -> [HerdrSession] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap(parseLine)
    }

    private static func parseLine(_ line: Substring) -> HerdrSession? {
        let columns = line.split(whereSeparator: \.isWhitespace)
        guard columns.count >= 2, columns[0] != "name" else { return nil }
        guard let name = try? SessionName(String(columns[0])) else { return nil }
        let status = HerdrSession.Status(rawValue: String(columns[1])) ?? .unknown
        return HerdrSession(name: name, status: status)
    }
}
