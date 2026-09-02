import Foundation

/// Turns "these ids used to be in this order, now they are in that order" into
/// the batch-update calls `NSTableView` / `NSOutlineView` expect.
///
/// The lists are diffed rather than reloaded because a reload throws away row
/// views (killing hover and any in-flight animation) on every one of herdr's
/// chatty updates, and because `insert`/`remove` are what make rows animate.
///
/// The plan is deliberately in the order AppKit applies it — removals, then
/// insertions, then moves — with each step's indices read against the list as
/// it stands *after* the previous step, which is exactly how the calls between
/// `beginUpdates()` and `endUpdates()` are interpreted:
///
/// 1. `removals`: indices into the old list, descending, of ids that are gone.
/// 2. `insertions`: indices into the new list, ascending, of ids that are new.
///    After these two steps the list holds the right ids, but survivors may
///    still be in their old relative order.
/// 3. `moves`: one `moveItem(at:to:)` each, applied in order, to finish.
///
/// Ids are assumed unique (herdr workspace ids are). A duplicate cannot crash
/// this — the plan just may not be minimal.
enum ListDiff {
    /// `remove the row at from, insert it at to` — `NSOutlineView.moveItem`
    /// and `NSTableView.moveRow` have exactly these semantics.
    struct Move: Equatable, Sendable {
        let from: Int
        let to: Int
    }

    struct Changes: Equatable, Sendable {
        /// Indices into the old list, descending.
        var removals: [Int] = []
        /// Indices into the new list, ascending.
        var insertions: [Int] = []
        /// Applied in order, after the removals and insertions.
        var moves: [Move] = []

        var isEmpty: Bool { removals.isEmpty && insertions.isEmpty && moves.isEmpty }
    }

    static func changes<ID: Hashable>(from old: [ID], to new: [ID]) -> Changes {
        let survivors = Set(new)
        let known = Set(old)

        // Step 1: drop what is gone, keeping the survivors in their old order.
        var working: [ID] = []
        working.reserveCapacity(new.count)
        var removals: [Int] = []
        for (index, id) in old.enumerated() {
            if survivors.contains(id) {
                working.append(id)
            } else {
                removals.append(index)
            }
        }
        removals.reverse()

        // Step 2: add what is new at its final index. Ascending order keeps
        // every index valid: an id at index `i` of the new list has `i`
        // predecessors there, and all of them are already in `working`.
        var insertions: [Int] = []
        for (index, id) in new.enumerated() where !known.contains(id) {
            insertions.append(index)
            working.insert(id, at: min(index, working.count))
        }

        // Step 3: sort the survivors into place. Walking left to right means
        // everything before `target` is already final, so each id needs at
        // most one move and `from` is always ahead of `to`.
        var moves: [Move] = []
        for (target, id) in new.enumerated() where target < working.count {
            guard working[target] != id else { continue }
            guard let current = working[target...].firstIndex(of: id) else { continue }
            working.remove(at: current)
            working.insert(id, at: target)
            moves.append(Move(from: current, to: target))
        }

        return Changes(removals: removals, insertions: insertions, moves: moves)
    }
}
