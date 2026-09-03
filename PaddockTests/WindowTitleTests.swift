import Testing
@testable import Paddock

struct WindowTitleTests {
    private func tab(_ display: String) throws -> SessionTab {
        SessionTab(sessionName: try SessionName("work"), displayName: display, color: .blue)
    }

    @Test func noTabIsJustTheAppName() {
        #expect(WindowTitle.text(tab: nil, terminalTitle: "ignored") == "Paddock")
    }

    /// `""` is deliberately the same as `nil`: no dangling "Work — ".
    @Test func aTabWithoutATerminalTitleIsItsDisplayName() throws {
        #expect(WindowTitle.text(tab: try tab("Work"), terminalTitle: nil) == "Work")
        #expect(WindowTitle.text(tab: try tab("Work"), terminalTitle: "") == "Work")
    }

    @Test func aTerminalTitleIsAppended() throws {
        #expect(WindowTitle.text(tab: try tab("Work"), terminalTitle: "vim") == "Work — vim")
    }
}

struct SurfaceEndTests {
    @Test func aLiveProcessMeansDetached() {
        #expect(SurfaceEnd(processAlive: true) == .detached)
        #expect(SurfaceEnd(processAlive: false) == .exited)
    }
}
