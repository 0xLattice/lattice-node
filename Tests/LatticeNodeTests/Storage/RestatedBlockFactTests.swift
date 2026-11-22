import Foundation
import Lattice
import LatticeNodeCore
import XCTest
@testable import LatticeBlockTree
@testable import LatticeNode

/// Execution re-states a weighed block fact, and only that: the executed
/// copy is the weighed one. Its state diff is an execution output, staged
/// beside the facts and kept apart for the state window. Every header
/// field, the child block's `parentState` included, must be carried over
/// unchanged.
final class RestatedBlockFactTests: XCTestCase {
    private let alpha: ChainPath = ["Nexus", "Alpha"]

    private func fact(parentState: String?) -> ChainFact {
        .block(ChainBlockFact(
            blockHash: "block", parentBlockHash: "parent", blockHeight: 1,
            postStateCID: "post", prevStateCID: "prev", parentStateCID: parentState,
            specCID: "spec", target: "target", nextTarget: "next-target",
            timestamp: 0
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
        _ facts: [ChainFact], diffs: [String: StateDiff] = [:], in store: NodeStore, keepsStateDiffs: Bool = true
    ) async throws {
        try await store.stageNodeFacts([
            NodeFactBatch(
                path: alpha, facts: [BlockImportBatch(facts: facts)], stateDiffs: diffs, cursors: [:],
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
        try await stage([fact(parentState: "anchor")], in: store)
        try await stage(
            [fact(parentState: "anchor"), .validation(ChainValidationFact(blockHash: "block"))],
            diffs: ["block": try executedDiff], in: store
        )
        let stored = try await store.storedFacts(at: alpha).facts
        XCTAssertEqual(stored.first, fact(parentState: "anchor"))
        XCTAssertEqual(stored.count, 2)
        let kept = try await store.stateDiff("block", at: alpha)
        XCTAssertEqual(kept, try executedDiff)
    }

    func testRestatementCannotChangeParentState() async throws {
        let store = try store()
        try await stage([fact(parentState: "anchor")], in: store)
        do {
            try await stage([fact(parentState: "elsewhere")], diffs: ["block": try executedDiff], in: store)
            XCTFail("a re-statement changed the block's parent state")
        } catch NodeStoreError.conflictingImportFact {}
    }

    /// The diff is kept only for an executed block, and only when asked:
    /// a store whose node keeps all state, or none, reads no diff.
    func testADiffIsKeptOnlyForAnExecutionAndOnlyWhenAsked() async throws {
        let unexecuted = try store()
        try await stage([fact(parentState: nil)], diffs: ["block": try executedDiff], in: unexecuted)
        let none = try await unexecuted.stateDiff("block", at: alpha)
        XCTAssertNil(none)

        let notAsked = try store()
        try await stage(
            [fact(parentState: nil), .validation(ChainValidationFact(blockHash: "block"))],
            diffs: ["block": try executedDiff], in: notAsked, keepsStateDiffs: false
        )
        let unkept = try await notAsked.stateDiff("block", at: alpha)
        XCTAssertNil(unkept)
    }
}
