import Foundation
import Testing
@testable import Paddock

/// Serialized: the scrub test mutates the process environment, which every
/// other test in this suite reads. `.serialized` orders this suite only —
/// nothing else in the target reads a `HERDR_*` variable, and the test puts
/// back whatever the runner inherited, so the window is harmless.
@Suite(.serialized)
struct HerdrEnvironmentTests {
    @Test func findsOnlyHerdrMarkers() {
        let environment = [
            "HERDR_ENV": "1",
            "HERDR_PANE_ID": "w1:p1",
            "TERM_PROGRAM": "ghostty",
            "HOME": "/Users/me",
        ]
        #expect(HerdrEnvironment.inheritedMarkers(in: environment) == ["HERDR_ENV", "HERDR_PANE_ID"])
    }

    @Test func scrubRemovesMarkersFromProcessEnvironment() {
        // The scrub touches every HERDR_* variable, so remember and restore
        // whatever the test runner inherited.
        let inherited = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix(HerdrEnvironment.markerPrefix) }
        defer {
            for (key, value) in inherited {
                setenv(key, value, 1)
            }
        }
        setenv("HERDR_TEST_MARKER", "1", 1)
        let removed = HerdrEnvironment.scrubInheritedMarkers()
        #expect(removed.contains("HERDR_TEST_MARKER"))
        #expect(getenv("HERDR_TEST_MARKER") == nil)
    }
}
