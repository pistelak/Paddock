import Testing
@testable import Paddock

struct HerdrSessionListParserTests {
    @Test func parsesHerdrTable() throws {
        let output = """
        name                 status   directory                                        socket
        default              running  /Users/me/.config/herdr                          /Users/me/.config/herdr/herdr.sock
        personal             stopped  /Users/me/.config/herdr/sessions/personal        /Users/me/.config/herdr/sessions/personal/herdr.sock
        work                 stopped  /Users/me/.config/herdr/sessions/work            /Users/me/.config/herdr/sessions/work/herdr.sock
        """
        let sessions = HerdrSessionListParser.parse(output)
        #expect(sessions == [
            HerdrSession(name: try SessionName("default"), status: .running),
            HerdrSession(name: try SessionName("personal"), status: .stopped),
            HerdrSession(name: try SessionName("work"), status: .stopped),
        ])
    }

    @Test func ignoresBlankMalformedAndUnusableLines() throws {
        let sessions = HerdrSessionListParser.parse("\n\nonlyname\nalpha weird\nbad;name running\n")
        #expect(sessions == [HerdrSession(name: try SessionName("alpha"), status: .unknown)])
    }
}
