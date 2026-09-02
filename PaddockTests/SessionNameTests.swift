import Foundation
import Testing
@testable import Paddock

struct SessionNameTests {
    @Test(arguments: [
        ("  work ", "work"),
        ("side-project_2.0", "side-project_2.0"),
    ])
    func acceptsSimpleNames(raw: String, trimmed: String) throws {
        #expect(try SessionName(raw).rawValue == trimmed)
    }

    @Test(arguments: ["", "   ", "my space", "a;b", "$(x)", "ünïcode", String(repeating: "a", count: 65)])
    func rejectsShellSensitiveNames(bad: String) {
        #expect(throws: PaddockError.invalidSessionName(bad)) {
            try SessionName(bad)
        }
    }

    @Test func decodingAcceptsAValidName() throws {
        let name = try JSONDecoder().decode(SessionName.self, from: Data("\"work\"".utf8))
        #expect(name.rawValue == "work")
    }

    @Test func decodingRejectsAShellSensitiveName() {
        #expect(throws: PaddockError.invalidSessionName("work; open -a Calculator")) {
            try JSONDecoder().decode(SessionName.self, from: Data("\"work; open -a Calculator\"".utf8))
        }
    }
}
