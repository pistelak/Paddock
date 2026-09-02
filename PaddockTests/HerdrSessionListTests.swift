import Foundation
import Testing
@testable import Paddock

struct HerdrSessionListTests {
    private func decode(_ json: String) throws -> [HerdrSession] {
        try JSONDecoder().decode(HerdrSessionList.self, from: Data(json.utf8)).sessions
    }

    @Test func decodesSessionListFromHerdr() throws {
        let sessions = try decode(#"""
        {"sessions":[
          {"default":true,"name":"default","running":true,
           "session_dir":"/Users/me/.config/herdr",
           "socket_path":"/Users/me/.config/herdr/herdr.sock"},
          {"default":false,"name":"personal","running":true,
           "session_dir":"/Users/me/.config/herdr/sessions/personal",
           "socket_path":"/Users/me/.config/herdr/sessions/personal/herdr.sock"}
        ]}
        """#)
        #expect(sessions == [
            HerdrSession(
                name: try SessionName("default"),
                socketPath: "/Users/me/.config/herdr/herdr.sock",
                sessionDirectory: "/Users/me/.config/herdr",
                isDefault: true,
                isRunning: true
            ),
            HerdrSession(
                name: try SessionName("personal"),
                socketPath: "/Users/me/.config/herdr/sessions/personal/herdr.sock",
                sessionDirectory: "/Users/me/.config/herdr/sessions/personal",
                isDefault: false,
                isRunning: true
            ),
        ])
    }

    @Test func dropsRowsWithNamesPaddockCannotUse() throws {
        let sessions = try decode(#"""
        {"sessions":[
          {"default":false,"name":"bad name!","running":true,
           "session_dir":"/tmp/bad","socket_path":"/tmp/bad/herdr.sock"},
          {"default":false,"name":"work","running":true,
           "session_dir":"/tmp/work","socket_path":"/tmp/work/herdr.sock"}
        ]}
        """#)
        #expect(sessions.map(\.name.rawValue) == ["work"])
    }

    @Test func decodesEmptySessionList() throws {
        #expect(try decode(#"{"sessions":[]}"#).isEmpty)
    }

    @Test func stoppedSessionIsNotRunning() throws {
        let sessions = try decode(#"""
        {"sessions":[{"default":false,"name":"work","running":false,
                      "session_dir":"/tmp/work","socket_path":"/tmp/work/herdr.sock"}]}
        """#)
        #expect(sessions.count == 1)
        #expect(sessions.first?.isRunning == false)
    }

    /// A row missing the fields Paddock does not control keeps the session:
    /// the socket path falls back to herdr's layout instead of being lost.
    @Test func fillsInMissingFieldsFromTheDefaultLayout() throws {
        let sessions = try decode(#"{"sessions":[{"name":"work"}]}"#)
        let expected = HerdrPaths.socketPath(for: try SessionName("work"))
        #expect(sessions.count == 1)
        let session = try #require(sessions.first)
        #expect(session.socketPath == expected)
        #expect(session.sessionDirectory == (expected as NSString).deletingLastPathComponent)
        #expect(session.isDefault == false)
        #expect(session.isRunning == false)
    }
}
