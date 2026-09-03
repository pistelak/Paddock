import Foundation
import os

/// The right to keep being told about a store's changes. Drop it — or call
/// `cancel()` — and the observation ends.
///
/// Observation is not ownership: any number of views may watch one store,
/// none of them decides when it runs, and letting go of a token is all a
/// view has to do when it looks elsewhere. That replaces the single settable
/// closure a store used to have, which forced whoever bound it to clear the
/// previous owner's closure by hand and left no slot for a second observer
/// (the tile badge, say).
///
/// `deinit` is `nonisolated`, so the actual removal is hopped onto the main
/// actor; the lock only makes "cancelled once" true whichever way it happens.
final class ObservationToken: Sendable {
    private let removal: @Sendable @MainActor () -> Void
    private let isCancelled = OSAllocatedUnfairLock(initialState: false)

    init(_ removal: @escaping @Sendable @MainActor () -> Void) {
        self.removal = removal
    }

    @MainActor
    func cancel() {
        guard claim() else { return }
        removal()
    }

    deinit {
        guard claim() else { return }
        let removal = removal
        Task { @MainActor in removal() }
    }

    private func claim() -> Bool {
        isCancelled.withLock { cancelled in
            defer { cancelled = true }
            return !cancelled
        }
    }
}
