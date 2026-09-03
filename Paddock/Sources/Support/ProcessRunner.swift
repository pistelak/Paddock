import Foundation
import os

struct ProcessResult: Sendable {
    let status: Int32
    let standardOutput: String
    let standardError: String
}

/// Runs a subprocess to completion without blocking a cooperative thread:
/// both pipes are drained concurrently, each on a reader thread of its own (a
/// child that fills one pipe while we wait on the other would otherwise
/// deadlock, and `FileHandle.bytes` cannot give two readers that independence
/// — see `DescriptorReader`), and termination arrives through an `AsyncStream`
/// fed by `terminationHandler`.
///
/// **Cancellation and timeout are bounds, not requests.** Either one:
/// 1. sends `SIGTERM` to the child's process group — Foundation launches the
///    child as the leader of a fresh group and `Process.terminate()` signals
///    the whole group, so a grandchild that inherited the pipe (a login
///    shell's version manager, a backgrounded helper) normally dies with it;
/// 2. interrupts both pipe readers anyway, so a grandchild that survived —
///    one that ignores `SIGTERM`, or moved to a group of its own — cannot
///    keep them waiting for an EOF that never comes;
/// 3. gives the group `terminationGrace` to exit and sends it `SIGKILL` if the
///    child has not — a child that ignores `SIGTERM` still ends.
/// A cancelled run throws `CancellationError`; one that ran out of time throws
/// `PaddockError.commandTimedOut`. Anything that survives all this is
/// orphaned with its pipe's read end closed, so its next write fails.
///
/// Step 3 runs on a detached task on purpose. By the time it is needed the
/// structured context is being torn down — the timeout has thrown, the task
/// group is cancelling its children — and inside a cancelled task an
/// `AsyncStream` stops iterating at once, so nothing structured could still
/// be waiting for the exit. The detached task holds only the lock-guarded
/// process box, sleeps once, kills if needed, and ends.
enum ProcessRunner {
    /// How long a terminated child gets to exit on its own before `SIGKILL`.
    static let terminationGrace: Duration = .seconds(1)

    static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: Duration? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError

        let (termination, terminationContinuation) = AsyncStream<Int32>.makeStream()
        let running = RunningProcess(process)
        // Weak: the `Process` retains its handler, and the box retains the
        // `Process`, so a strong capture here would be a cycle that outlives
        // every run. The box is kept alive by `stop` for as long as the run is
        // in flight and by the escalation task for the grace period after a
        // terminate — which is exactly as long as anyone needs it.
        process.terminationHandler = { [weak running] finished in
            running?.markExited()
            terminationContinuation.yield(finished.terminationStatus)
            terminationContinuation.finish()
        }

        try process.run()

        let outputHandle = standardOutput.fileHandleForReading
        let errorHandle = standardError.fileHandleForReading
        let interrupt = DescriptorReader.Interrupt()

        let collect: @Sendable () async throws -> ProcessResult = {
            async let output = DescriptorReader.readToEnd(outputHandle, interrupt: interrupt)
            async let errors = DescriptorReader.readToEnd(errorHandle, interrupt: interrupt)
            let (standardOutputData, standardErrorData) = try await (output, errors)
            // Both readers are done — at EOF, or interrupted — so nothing is
            // using the descriptors any more. Closing here rather than leaving
            // it to the pipes' deallocation keeps a run from holding two
            // descriptors longer than it needs them, and hands a surviving
            // grandchild an `EPIPE` on its next write.
            try? outputHandle.close()
            try? errorHandle.close()

            var status: Int32 = -1
            for await value in termination {
                status = value
            }

            return ProcessResult(
                status: status,
                // A command that writes something other than UTF-8 is a broken
                // command, not a broken run: report what decoded and let the
                // caller's own parsing fail with a message about the content.
                standardOutput: String(decoding: standardOutputData, as: UTF8.self),
                standardError: String(decoding: standardErrorData, as: UTF8.self)
            )
        }
        let stop: @Sendable () -> Void = {
            running.terminate()
            interrupt.trigger()
        }

        let result: ProcessResult
        if let timeout {
            do {
                result = try await Timeout.race(timeout, interrupt: stop, operation: collect)
            } catch is Timeout.Expired {
                throw PaddockError.commandTimedOut(arguments: arguments, after: timeout)
            }
        } else {
            result = try await withTaskCancellationHandler(operation: collect, onCancel: stop)
        }
        // The child was terminated on the caller's behalf; its exit status is
        // not an answer, so say so instead of returning `SIGTERM`.
        try Task.checkCancellation()
        return result
    }

    /// The `Process`, reachable from a synchronous cancellation handler.
    ///
    /// `Process` is not `Sendable`; this box is, because the only things it
    /// lets anyone do from another thread are send a signal and record that
    /// the process exited, both under one lock. Signals stop once the process
    /// has exited: `terminate()` on a finished `Process` is harmless today but
    /// not documented to stay so, and `kill(2)` on a reaped pid could reach an
    /// unrelated process.
    private final class RunningProcess: @unchecked Sendable {
        private struct State {
            var hasExited = false
            var wasTerminated = false
        }

        private let process: Process
        private let state = OSAllocatedUnfairLock(initialState: State())

        init(_ process: Process) {
            self.process = process
        }

        func markExited() {
            state.withLock { $0.hasExited = true }
        }

        /// Sends `SIGTERM` once and arranges for `SIGKILL` after
        /// `terminationGrace` if the process is still around by then. Safe to
        /// call from any thread and after exit; a second call does nothing.
        func terminate() {
            let shouldEscalate = state.withLock { state -> Bool in
                guard !state.hasExited, !state.wasTerminated else { return false }
                state.wasTerminated = true
                process.terminate()
                return true
            }
            guard shouldEscalate else { return }
            // Detached: see the type's doc comment. Nothing structured can
            // still be waiting when this fires.
            Task.detached { [self] in
                try? await Task.sleep(for: ProcessRunner.terminationGrace)
                self.kill()
            }
        }

        /// Sends `SIGKILL` to the process group if the process is still
        /// running — the group, to match what `terminate()` signalled, so a
        /// grandchild that shrugged off `SIGTERM` goes too. Only ever a group
        /// the child leads: signalling any other group could reach this app.
        ///
        /// Three liveness checks, because `hasExited` is set by the
        /// termination handler and Foundation reaps the child a moment
        /// *before* it calls that handler: `isRunning`, then `hasExited`, then
        /// `getpgid` — which fails with `ESRCH` once the pid is gone, and is
        /// then taken as "nothing left to kill" rather than as a reason to
        /// fall back to a raw pid. What remains is the gap between that call
        /// and `kill(2)` itself, the same gap every pid-based signal has,
        /// `Process.terminate()` included; closing it would mean owning the
        /// spawn and reap ourselves instead of using `Process`.
        private func kill() {
            guard process.isRunning else { return }
            state.withLock { state in
                guard !state.hasExited else { return }
                let pid = process.processIdentifier
                guard getpgid(pid) == pid else { return }
                Darwin.kill(-pid, SIGKILL)
            }
        }
    }
}
