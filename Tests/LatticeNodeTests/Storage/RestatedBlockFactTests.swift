import Foundation
import Lattice
import XCTest
@testable import LatticeNode

/// Execution re-states a weighed block fact with its state diff, and only
/// that: every header field, the child block's `parentState` included, must
/// be carried over unchanged.
final class RestatedBlockFactTests: XCTestCase {
    private func fact(parentState: String?, diff: StateDiff) -> ChainBlockFact {
        ChainBlockFact(
            blockHash: "block", parentBlockHash: "parent", blockHeight: 1,
            postStateCID: "post", prevStateCID: "prev", parentStateCID: parentState,
            specCID: "spec", target: "target", nextTarget: "next-target",
            timestamp: 0, stateDiff: diff
        )
    }

    private func payload(_ fact: ChainBlockFact) throws -> Data {
        try NodeStore.encode(ChainFact.block(fact))
    }

    /// A non-empty diff; `StateDiff` has no public memberwise init.
    private var executedDiff: StateDiff {
        get throws {
            try JSONDecoder().decode(
                StateDiff.self, from: Data(#"{"replaced":{"old":1},"created":{"new":1}}"#.utf8)
            )
        }
    }

    func testChildBlockExecutionRestatesItsWeighedFact() throws {
        XCTAssertTrue(try NodeStore.restatesWeighedBlock(
            payload(fact(parentState: "anchor", diff: .empty)),
            as: payload(fact(parentState: "anchor", diff: try executedDiff))
        ))
    }

    func testRestatementCannotChangeParentState() throws {
        XCTAssertFalse(try NodeStore.restatesWeighedBlock(
            payload(fact(parentState: "anchor", diff: .empty)),
            as: payload(fact(parentState: "elsewhere", diff: try executedDiff))
        ))
    }
}
