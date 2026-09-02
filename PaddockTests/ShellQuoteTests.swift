import Testing
@testable import Paddock

struct ShellQuoteTests {
    @Test func safeValuesPassThroughForPrompt() {
        #expect(ShellQuote.forPrompt("/Users/me/Projects/app-1.0_final") == "/Users/me/Projects/app-1.0_final")
    }

    @Test(arguments: [
        ("/tmp/My File (2).txt", "'/tmp/My File (2).txt'"),
        ("it's", "'it'\\''s'"),
        ("line\nbreak\n", "'line\nbreak\n'"),
        ("", "''"),
    ])
    func unsafeValuesAreSingleQuoted(value: String, quoted: String) {
        #expect(ShellQuote.forPrompt(value) == quoted)
    }

    @Test(arguments: [
        ("plain", "'plain'"),
        ("a'b", "'a'\\''b'"),
    ])
    func singleQuotedAlwaysQuotes(value: String, quoted: String) {
        #expect(ShellQuote.singleQuoted(value) == quoted)
    }
}
