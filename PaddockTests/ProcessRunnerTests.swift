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

// MARK: - Cancellation and timeout

extension ProcessRunnerTests {
    /// A child that never finishes must not hold the caller for ever: the
    /// timeout terminates it, the readers see EOF, and the caller gets a
    /// typed error instead of a result.
    @Test(.timeLimit(.minutes(1))) func timeoutTerminatesTheChild() async throws {
        let start = ContinuousClock.now
        let error = await #expect(throws: PaddockError.self) {
            _ = try await ProcessRunner.run(
                shell,
                arguments: ["-c", "exec sleep 30"],
                timeout: .milliseconds(200)
            )
        }
        guard case let .commandTimedOut(arguments, after) = try #require(error) else {
            Issue.record("expected .commandTimedOut, got \(String(describing: error))")
            return
        }
        #expect(arguments == ["-c", "exec sleep 30"])
        #expect(after == .milliseconds(200))
        #expect(ContinuousClock.now - start < .seconds(5), "the child was terminated, not waited for")
    }

    /// Cancelling the task that awaits the run terminates the child too, and
    /// surfaces as `CancellationError` rather than a `SIGTERM` exit status.
    @Test(.timeLimit(.minutes(1))) func cancellationTerminatesTheChild() async throws {
        let start = ContinuousClock.now
        let task = Task { [shell] in
            try await ProcessRunner.run(shell, arguments: ["-c", "exec sleep 30"])
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    /// The case a `terminate()` cannot settle on its own: the shell and the
    /// grandchild it forked both ignore SIGTERM, and the grandchild holds the
    /// pipe. (A grandchild that *honours* SIGTERM dies with the shell, because
    /// Foundation signals the child's whole process group — so it has to be
    /// made stubborn for the readers' own escape hatch to matter.) The run
    /// must still return promptly, and the grace-period SIGKILL must then take
    /// the whole group out.
    ///
    /// The shell touches a ready file once the grandchild exists, and the
    /// timeout is long enough that it always fires *after* that, so the test
    /// exercises inherited pipe ownership every time rather than by luck.
    @Test(.timeLimit(.minutes(1))) func timeoutIsABoundEvenWhenAStubbornGrandchildHoldsThePipe() async throws {
        let marker = "sleep 31338"
        defer { Task { try? await pkill(marker) } }
        let ready = readyFile()
        defer { try? FileManager.default.removeItem(at: ready) }

        let start = ContinuousClock.now
        await #expect(throws: PaddockError.self) {
            _ = try await ProcessRunner.run(
                shell,
                arguments: ["-c", "trap '' TERM; \(marker) & touch '\(ready.path)'; wait"],
                timeout: .seconds(1)
            )
        }
        #expect(FileManager.default.fileExists(atPath: ready.path), "the grandchild existed before the timeout")
        #expect(ContinuousClock.now - start < .seconds(5), "must not wait for the pipe's EOF")
        #expect(try await isRunning(marker), "the grandchild ignores SIGTERM and holds the pipe")

        let deadline = ContinuousClock.now + ProcessRunner.terminationGrace + .seconds(5)
        var after = try await matches(marker)
        while !after.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            after = try await matches(marker)
        }
        #expect(after.isEmpty, "the group SIGKILL ends the grandchild too; still running: \(after)")
    }

    /// The ordinary grandchild case needs no help from the readers: Foundation
    /// signals the child's process group, so a forked `sleep` dies with the
    /// shell and the pipe closes on its own.
    @Test(.timeLimit(.minutes(1))) func terminatingTheChildEndsAWellBehavedGrandchildToo() async throws {
        let marker = "sleep 31339"
        defer { Task { try? await pkill(marker) } }
        let ready = readyFile()
        defer { try? FileManager.default.removeItem(at: ready) }

        await #expect(throws: PaddockError.self) {
            _ = try await ProcessRunner.run(
                shell,
                arguments: ["-c", "\(marker) & touch '\(ready.path)'; wait"],
                timeout: .seconds(1)
            )
        }
        #expect(FileManager.default.fileExists(atPath: ready.path))
        #expect(try await !isRunning(marker), "SIGTERM to the group took the grandchild with the shell")
    }

    /// A child that ignores SIGTERM is killed after the grace period. The run
    /// itself returns as soon as the timeout fires; the kill happens behind it,
    /// so the check is that the child is gone once the grace period has passed.
    ///
    /// The ready file proves the trap was installed before the timeout fired;
    /// the odd sleep length is the marker `pgrep -fx` matches exactly — tests
    /// run in parallel and other cases use `sleep 30`.
    @Test(.timeLimit(.minutes(1))) func timeoutEscalatesToKillWhenTheChildIgnoresTerminate() async throws {
        let marker = "sleep 31337"
        defer { Task { try? await pkill(marker) } }
        let ready = readyFile()
        defer { try? FileManager.default.removeItem(at: ready) }

        let start = ContinuousClock.now
        await #expect(throws: PaddockError.self) {
            _ = try await ProcessRunner.run(
                shell,
                arguments: ["-c", "trap '' TERM; touch '\(ready.path)'; exec \(marker)"],
                timeout: .seconds(1)
            )
        }
        #expect(FileManager.default.fileExists(atPath: ready.path), "the trap was installed before the timeout")
        #expect(ContinuousClock.now - start < .seconds(5), "the run does not wait for the kill")

        // Alive right after the timeout: SIGTERM was ignored, as intended.
        #expect(try await isRunning(marker), "the child ignores SIGTERM and survives it")
        // Then gone once the grace period has passed. Polled rather than
        // checked at a fixed instant: under a full parallel test run the
        // detached kill and the reap can land a little late.
        let deadline = ContinuousClock.now + ProcessRunner.terminationGrace + .seconds(5)
        var after = try await matches(marker)
        while !after.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            after = try await matches(marker)
        }
        #expect(after.isEmpty, "SIGKILL after the grace period ends it; still running: \(after)")
    }

    private func readyFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("paddock-ready-\(UUID().uuidString)")
    }

    private func isRunning(_ commandLine: String) async throws -> Bool {
        try await !matches(commandLine).isEmpty
    }

    /// `pgrep -fxl` output for the processes whose *entire* command line is
    /// `commandLine`, so a failure says *what* is still alive. Exact match on
    /// purpose: a substring match once caught an unrelated shell whose
    /// arguments merely mentioned the marker.
    private func matches(_ commandLine: String) async throws -> String {
        let result = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/pgrep"),
            arguments: ["-fxl", commandLine]
        )
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Ends whatever a test left behind so a leaked marker cannot fail the
    /// next run.
    private func pkill(_ commandLine: String) async throws {
        _ = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/pkill"),
            arguments: ["-fx", commandLine]
        )
    }

    /// A generous timeout must not interfere with a run that finishes.
    @Test func aRunThatFinishesInTimeIsUnaffectedByTheTimeout() async throws {
        let result = try await ProcessRunner.run(
            shell,
            arguments: ["-c", "printf done"],
            timeout: .seconds(10)
        )
        #expect(result.status == 0)
        #expect(result.standardOutput == "done")
    }
}
