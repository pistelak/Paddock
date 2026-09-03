import Foundation

/// Races an operation against a deadline and against cancellation of the
/// calling task, running `interrupt` in either case.
///
/// The operations this guards — a blocked socket read, a subprocess waiting
/// on its pipes — ignore Swift cancellation on their own: nothing inside them
/// checks `Task.isCancelled`. So something has to reach in from outside and
/// make them finish (shut the descriptor down, terminate the child), which is
/// what `interrupt` is for. It is called at most once per cause, is expected
/// to be cheap and non-blocking, and must be safe to call after the operation
/// has already finished.
enum Timeout {
    /// Thrown when `duration` elapses first. Callers translate it into their
    /// own vocabulary (`PaddockError.herdrTimeout`, `.commandTimedOut`).
    struct Expired: Error, Equatable, Sendable {
        let duration: Duration
    }

    static func race<T: Sendable>(
        _ duration: Duration,
        interrupt: @escaping @Sendable () -> Void,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Outcome<T>.self) { group in
                group.addTask { .value(try await operation()) }
                group.addTask {
                    // `try?` around the sleep would swallow cancellation and
                    // interrupt a perfectly healthy operation.
                    do { try await Task.sleep(for: duration) } catch { return .cancelled }
                    guard !Task.isCancelled else { return .cancelled }
                    interrupt()
                    return .timedOut
                }
                defer { group.cancelAll() }

                while let outcome = try await group.next() {
                    switch outcome {
                    case let .value(value): return value
                    case .timedOut: throw Expired(duration: duration)
                    case .cancelled: continue
                    }
                }
                throw CancellationError()
            }
        } onCancel: {
            interrupt()
        }
    }

    /// Which arm of the race finished first.
    private enum Outcome<Value: Sendable>: Sendable {
        case value(Value)
        case timedOut
        case cancelled
    }
}
