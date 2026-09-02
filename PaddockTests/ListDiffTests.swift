import Testing
@testable import Paddock

struct ListDiffTests {
    // MARK: - The plan itself

    @Test func identicalListsProduceNoChanges() {
        let changes = ListDiff.changes(from: ["a", "b", "c"], to: ["a", "b", "c"])
        #expect(changes.isEmpty)
        #expect(changes == ListDiff.Changes())
    }

    @Test func emptyToEmptyProducesNoChanges() {
        #expect(ListDiff.changes(from: [String](), to: []).isEmpty)
    }

    @Test func insertionsAreIndicesInTheNewListAscending() {
        let changes = ListDiff.changes(from: ["a", "c"], to: ["a", "b", "c", "d"])
        #expect(changes.removals == [])
        #expect(changes.insertions == [1, 3])
        #expect(changes.moves == [])
    }

    @Test func removalsAreIndicesInTheOldListDescending() {
        let changes = ListDiff.changes(from: ["a", "b", "c", "d"], to: ["b", "d"])
        #expect(changes.removals == [2, 0])
        #expect(changes.insertions == [])
        #expect(changes.moves == [])
    }

    @Test func reorderIsExpressedAsMoves() {
        let changes = ListDiff.changes(from: ["a", "b", "c"], to: ["c", "a", "b"])
        #expect(changes.removals == [])
        #expect(changes.insertions == [])
        #expect(changes.moves == [ListDiff.Move(from: 2, to: 0)])
    }

    @Test func swapOfTwoRowsIsOneMove() {
        let changes = ListDiff.changes(from: ["a", "b"], to: ["b", "a"])
        #expect(changes.moves == [ListDiff.Move(from: 1, to: 0)])
    }

    @Test func everythingChangedIsAllRemovalsAndInsertions() {
        let changes = ListDiff.changes(from: ["a", "b"], to: ["x", "y", "z"])
        #expect(changes.removals == [1, 0])
        #expect(changes.insertions == [0, 1, 2])
        #expect(changes.moves == [])
    }

    @Test func movesNeverPrecedeTheirTarget() {
        // Every move walks a row backwards, because the walk fixes indices
        // left to right; anything else would mean applying them in order is
        // not enough.
        let changes = ListDiff.changes(from: ["a", "b", "c", "d"], to: ["d", "c", "b", "a"])
        for move in changes.moves {
            #expect(move.from > move.to)
        }
    }

    // MARK: - Applying the plan the way AppKit does

    @Test(arguments: [
        (["a", "b", "c", "d"], ["d", "e", "b", "f"]),
        (["1", "2", "3"], ["3", "2", "1"]),
        ([], ["a", "b"]),
        (["a", "b"], []),
        (["a"], ["b", "a", "c"]),
        (["a", "b", "c", "d", "e"], ["e", "a", "x", "c"]),
    ])
    func planTransformsOldIntoNewForMixedChanges(old: [String], new: [String]) {
        expectPlanWorks(from: old, to: new)
    }

    @Test func planTransformsOldIntoNewForRandomLists() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0 ..< 200 {
            let pool = (0 ..< 12).map(String.init)
            let old = pool.filter { _ in Bool.random(using: &generator) }.shuffled()
            let new = pool.filter { _ in Bool.random(using: &generator) }.shuffled()
            expectPlanWorks(from: old, to: new)
        }
    }

    /// Replays the plan exactly as `NSOutlineView` does inside
    /// `beginUpdates()` / `endUpdates()`: removals first (indices in the old
    /// list), then insertions (indices in the new list), then each move in
    /// order, every step against the list as it stands.
    private func expectPlanWorks(
        from old: [String],
        to new: [String],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let changes = ListDiff.changes(from: old, to: new)
        var working = old
        for index in changes.removals {
            guard working.indices.contains(index) else {
                Issue.record("removal index \(index) out of range", sourceLocation: sourceLocation)
                return
            }
            working.remove(at: index)
        }
        for index in changes.insertions {
            guard index <= working.count else {
                Issue.record("insertion index \(index) out of range", sourceLocation: sourceLocation)
                return
            }
            working.insert(new[index], at: index)
        }
        for move in changes.moves {
            guard working.indices.contains(move.from), move.to <= working.count else {
                Issue.record("move \(move) out of range", sourceLocation: sourceLocation)
                return
            }
            let moved = working.remove(at: move.from)
            working.insert(moved, at: move.to)
        }
        #expect(working == new, sourceLocation: sourceLocation)
    }
}
