import Foundation
import Testing
@testable import Paddock

/// `/bin/sh` is the subprocess under test everywhere here: it is always
/// present, and the failure these tests guard against — a pipe that fills
/// while nobody is draining it — needs nothing more exotic.
struct ProcessRunnerTests {
    private let shell = URL(fileURLWithPath: "/bin/sh")

    @Test func capturesBothStreamsAndTheExitStatus() async throws {
        let result = try await ProcessRunner.run(
            shell,
            arguments: ["-c", "printf out; printf err >&2; exit 3"]
        )
        #expect(result.status == 3)
        #expect(result.standardOutput == "out")
        #expect(result.standardError == "err")
    }

    /// The deadlock the two reader threads exist for.
    ///
    /// The child fills stderr past the 64 KiB pipe buffer *before* it writes a
    /// byte to stdout, so a runner that drained stdout to EOF first — or that
    /// let one reader starve the other — would block the child for ever and
    /// this test would time out rather than fail.
    @Test(.timeLimit(.minutes(1))) func drainsBothPipesConcurrently() async throws {
        let lines = 20_000
        let result = try await ProcessRunner.run(
            shell,
            arguments: ["-c", "yes stderr-line | head -n \(lines) >&2; yes stdout-line | head -n \(lines)"]
        )
        #expect(result.status == 0)
        #expect(result.standardOutput.count == lines * "stdout-line\n".count)
        #expect(result.standardError.count == lines * "stderr-line\n".count)
        #expect(result.standardOutput.hasSuffix("stdout-line\n"))
    }

    /// Several runs in flight at once: none of them may be held up by another
    /// one's reader, which is what `FileHandle.bytes` used to do here.
    @Test func concurrentRunsAllComplete() async throws {
        let outputs = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0 ..< 8 {
                group.addTask { [shell] in
                    try await ProcessRunner.run(
                        shell,
                        arguments: ["-c", "yes \(index) | head -n 5000"]
                    ).standardOutput
                }
            }
            return try await group.reduce(into: [String]()) { $0.append($1) }
        }
        #expect(outputs.count == 8)
        for output in outputs {
            #expect(output.split(separator: "\n").count == 5000)
        }
    }

    /// Output that is not valid UTF-8 must not lose the rest of the stream or
    /// throw; the replacement character is enough of a report.
    @Test func invalidUTF8IsReplacedRatherThanFatal() async throws {
        let result = try await ProcessRunner.run(
            shell,
            arguments: ["-c", "printf 'a\\377b'"]
        )
        #expect(result.status == 0)
        #expect(result.standardOutput == "a\u{FFFD}b")
    }
}
