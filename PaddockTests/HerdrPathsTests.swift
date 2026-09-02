import Foundation
import Testing
@testable import Paddock

struct HerdrPathsTests {
    private let config = URL(fileURLWithPath: "/Users/me/.config/herdr", isDirectory: true)

    @Test func defaultSessionUsesTheConfigDirectoryItself() throws {
        #expect(
            HerdrPaths.socketPath(for: try SessionName("default"), configDirectory: config)
                == "/Users/me/.config/herdr/herdr.sock"
        )
    }

    @Test func namedSessionUsesASessionsSubdirectory() throws {
        #expect(
            HerdrPaths.socketPath(for: try SessionName("personal"), configDirectory: config)
                == "/Users/me/.config/herdr/sessions/personal/herdr.sock"
        )
    }

    @Test func configDirectoryDefaultsToHomeDotConfig() {
        #expect(HerdrPaths.configDirectory(environment: [:], home: "/Users/me").path == "/Users/me/.config/herdr")
    }

    @Test func configDirectoryHonoursXDGConfigHome() {
        #expect(
            HerdrPaths.configDirectory(environment: ["XDG_CONFIG_HOME": "/xdg"], home: "/Users/me").path
                == "/xdg/herdr"
        )
    }

    /// An exported but empty `XDG_CONFIG_HOME` means "unset", the same reading
    /// `GhosttyConfigLocator` uses.
    @Test func emptyXDGConfigHomeFallsBackToHome() {
        #expect(
            HerdrPaths.configDirectory(environment: ["XDG_CONFIG_HOME": ""], home: "/Users/me").path
                == "/Users/me/.config/herdr"
        )
    }
}
