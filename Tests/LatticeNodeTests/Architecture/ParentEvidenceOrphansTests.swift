import XCTest
@testable import LatticeNode

final class ParentEvidenceOrphansTests: XCTestCase {
    private func summary(_ child: String) -> IssuedChildEvidenceSummary {
        IssuedChildEvidenceSummary(
            ordinal: 1, childCID: child, rootCID: "r", attachmentCID: "a-\(child)"
        )
    }

    /// A plain bound with LimitOrphans' policy: at it a random orphan gives
    /// way and the newcomer is kept; re-inserting a held orphan evicts
    /// nothing.
    func testAtTheBoundARandomOrphanGivesWayToTheNewcomer() {
        var pool = ParentEvidenceOrphans(capacity: 2)
        pool.insert(sourceID: "s", summary: summary("a"), retry: .nextTrigger)
        pool.insert(sourceID: "s", summary: summary("b"), retry: .predecessor("p"))
        pool.insert(sourceID: "s", summary: summary("b"), retry: .nextTrigger)
        XCTAssertEqual(pool.entries.count, 2, "re-inserting held evicts nothing")
        var evicted: Set<String> = []
        for _ in 0..<64 {
            var trial = pool
            trial.insert(sourceID: "s", summary: summary("c"), retry: .notBefore(1))
            XCTAssertEqual(trial.entries.count, 2, "the bound holds")
            XCTAssertTrue(trial.contains(childCID: "c", rootCID: "r"), "the newcomer is kept")
            evicted.formUnion(["a", "b"].filter { !trial.contains(childCID: $0, rootCID: "r") })
        }
        XCTAssertEqual(evicted, ["a", "b"], "the victim is random, not always the oldest")
    }

    /// Release takes exactly the orphans whose retry is met, and only them.
    func testReleaseTakesExactlyTheReadyOrphans() {
        var pool = ParentEvidenceOrphans(capacity: 8)
        pool.insert(sourceID: "s", summary: summary("a"), retry: .predecessor("p"))
        pool.insert(sourceID: "s", summary: summary("b"), retry: .predecessor("q"))
        pool.insert(sourceID: "s", summary: summary("c"), retry: .notBefore(10))
        let released = pool.release { $0 == .predecessor("p") }
        XCTAssertEqual(released.map(\.summary.childCID), ["a"])
        XCTAssertEqual(pool.entries.count, 2)
        XCTAssertFalse(pool.contains(childCID: "a", rootCID: "r"))
    }
}
