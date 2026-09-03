import Foundation
import os

/// A `Clock` that only moves when a test says so.
///
/// Sleepers park until `advance(by:)` carries `now` past their deadline, so a
/// reconnect backoff, a snapshot-retry pause or a coalescing window costs a
/// test one method call instead of real seconds. `pendingSleepers` lets a test
/// wait (in real time, briefly) for the code under test to *reach* its sleep
/// before advancing past it — the two clocks are orthogonal: this one measures
/// durations, the wall clock only paces the test's own polling.
final class ManualClock: Clock, Sendable {
    struct Instant: InstantProtocol, Sendable {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Sleeper {
        let id: Int
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var nextID = 0
        var sleepers: [Sleeper] = []
        /// Cancellations that arrived before their sleeper registered.
        var cancelledBeforeRegistering: Set<Int> = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {}

    var now: Instant {
        state.withLock { $0.now }
    }

    var minimumResolution: Duration { .zero }

    /// How many tasks are currently parked in `sleep`.
    var pendingSleepers: Int {
        state.withLock { $0.sleepers.count }
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = state.withLock { state -> Int in
            state.nextID += 1
            return state.nextID
        }
        // A tombstone left by a cancellation that raced `advance(by:)` (the
        // sleeper was already removed, so the handler assumed it had not
        // registered yet) is cleared once this sleep is over either way.
        defer { state.withLock { _ = $0.cancelledBeforeRegistering.remove(id) } }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Disposition { case resume, park, cancelled }
                let disposition: Disposition = state.withLock { state in
                    if state.cancelledBeforeRegistering.remove(id) != nil { return .cancelled }
                    if deadline <= state.now { return .resume }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return .park
                }
                switch disposition {
                case .resume: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .park: break
                }
            }
        } onCancel: {
            let parked = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else {
                    state.cancelledBeforeRegistering.insert(id)
                    return nil
                }
                return state.sleepers.remove(at: index).continuation
            }
            parked?.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleeper whose deadline has passed,
    /// earliest first.
    func advance(by duration: Duration) {
        let due = state.withLock { state -> [Sleeper] in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.deadline <= now }.sorted { $0.deadline < $1.deadline }
            state.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }
}
