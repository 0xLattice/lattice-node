import Foundation
import Lattice
import LatticeNodeCore
import XCTest
@testable import LatticeBlockTree
@testable import LatticeNode

/// Execution re-states a weighed block fact with its state diff, and only
/// that. The store writes an execution's verdict, not the re-statement: the
/// fact held is the weighed one, and the diff is kept apart for the state
/// window. A re-statement that changes a header field is refused by the
/// tree before anything reaches the store (`Chain.applyStaged`).
final class RestatedBlockFactTests: XCTestCase {
    private let alpha: ChainPath = ["Nexus", "Alpha"]

    private func fact(parentState: String?, diff: StateDiff) -> ChainFact {
        .block(ChainBlockFact(
            blockHash: "block", parentBlockHash: "parent", blockHeight: 1,
            postStateCID: "post", prevStateCID: "prev", parentStateCID: parentState,
            specCID: "spec", target: "target", nextTarget: "next-target",
            timestamp: 0, stateDiff: diff
        ))
    }

    /// A non-empty diff; `StateDiff` has no public memberwise init.
    private var executedDiff: StateDiff {
        get throws {
            try JSONDecoder().decode(
                StateDiff.self, from: Data(#"{"replaced":{"old":1},"created":{"new":1}}"#.utf8)
            )
        }
    }

    private func stage(
        _ facts: [ChainFact], executed: Bool = false, in store: NodeStore, keepsStateDiffs: Bool = true
    ) async throws {
        let batch = BlockImportBatch(facts: facts)
        try await store.stageNodeFacts([
            NodeFactBatch(
                path: alpha, facts: executed ? [] : [batch], executed: executed ? [batch] : [], cursors: [:],
                keepsStateDiffs: keepsStateDiffs
            ),
        ], logID: "log")
    }

    private func store() throws -> NodeStore {
        try NodeStore(
            databasePath: temporaryDirectory(create: true).appendingPathComponent("state.db"), nexusGenesisCID: "genesis"
        )
    }

    func testChildBlockExecutionRestatesItsWeighedFact() async throws {
        let store = try store()
        try await stage([fact(parentState: "anchor", diff: .empty)], in: store)
        try await stage(
            [fact(parentState: "anchor", diff: try executedDiff), .validation(ChainValidationFact(blockHash: "block"))],
            executed: true, in: store
        )
        let stored = try await store.storedFacts(at: alpha).facts
        XCTAssertEqual(stored, [
            fact(parentState: "anchor", diff: .empty), .validation(ChainValidationFact(blockHash: "block")),
        ], "the weighed fact, then the verdict")
        let kept = try await store.stateDiff("block", at: alpha)
        XCTAssertEqual(kept, try executedDiff)
    }

    /// The diff is kept only for an executed block, and only when asked:
    /// a store whose node keeps all state, or none, reads no diff.
    func testADiffIsKeptOnlyForAnExecutionAndOnlyWhenAsked() async throws {
        let unexecuted = try store()
        try await stage([fact(parentState: nil, diff: try executedDiff)], in: unexecuted)
        let none = try await unexecuted.stateDiff("block", at: alpha)
        XCTAssertNil(none)

        let notAsked = try store()
        try await stage([fact(parentState: nil, diff: .empty)], in: notAsked)
        try await stage(
            [fact(parentState: nil, diff: try executedDiff), .validation(ChainValidationFact(blockHash: "block"))],
            executed: true, in: notAsked, keepsStateDiffs: false
        )
        let unkept = try await notAsked.stateDiff("block", at: alpha)
        XCTAssertNil(unkept)
    }
}
