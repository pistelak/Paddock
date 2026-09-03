import Testing
@testable import Paddock

/// Every connection state has its footer line here, so the copy is checked
/// without a window and a new state cannot slip through unworded.
struct ConnectionFooterTests {
    @Test func noStoreMeansNoSession() {
        #expect(ConnectionFooter.text(for: nil) == "No session selected")
    }

    @Test func liveRowsSpeakForThemselves() {
        #expect(ConnectionFooter.text(for: .live) == nil)
    }

    @Test(arguments: [WorkspaceStore.ConnectionState.idle, .connecting])
    func connectingStatesSayConnecting(state: WorkspaceStore.ConnectionState) {
        #expect(ConnectionFooter.text(for: state) == "Connecting…")
    }

    @Test func sessionNotRunning() {
        #expect(ConnectionFooter.text(for: .sessionNotRunning) == "Session not running")
    }

    @Test func unsupportedProtocolNamesBothVersions() {
        #expect(ConnectionFooter.text(for: .unsupportedProtocol(42)) == "herdr protocol 42; expected \(HerdrProtocol.supported)")
    }

    @Test func streamEnded() {
        #expect(ConnectionFooter.text(for: .reconnecting(.streamEnded)) == "Reconnecting… herdr closed the connection.")
    }

    @Test func aFailedRequestUsesItsOwnDescription() {
        let error = PaddockError.herdrTimeout(method: .sessionSnapshot)
        #expect(ConnectionFooter.text(for: .reconnecting(.failed(error))) == "Reconnecting… \(error.errorDescription!)")
    }

    @Test func anUnexpectedErrorUsesItsDescription() {
        #expect(ConnectionFooter.text(for: .reconnecting(.unexpected("boom"))) == "Reconnecting… boom")
    }
}
