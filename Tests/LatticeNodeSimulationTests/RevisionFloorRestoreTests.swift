import Foundation
import Lattice
import UInt256
import XCTest
import cashew
@testable import LatticeBlockTree
@testable import LatticeNodeCore

/// A restart never moves the revision back (§12.5.11).
final class RevisionFloorRestoreTests: XCTestCase {
    private static let context = try! ChainRuntimeContext(path: ["Nexus", "Revisions"])
    private static let genesis = cid("genesis")
    private static let grind = cid("grind")

    private static func cid(_ seed: String) -> String {
        try! HeaderImpl<PublicKey>(node: PublicKey(key: "revision-floor:\(seed)")).rawCID
    }

    private struct Work: Encodable {
        let id: String
        let work: UInt256
    }

    private static func work(_ work: UInt256) throws -> ChainFact {
        .work(ChainWorkFact(blockHash: genesis, contribution: try JSONDecoder().decode(
            VerifiedWorkContribution.self, from: JSONEncoder().encode(Work(id: grind, work: work))
        )))
    }

    private static var block: ChainFact {
        let max = String(repeating: "f", count: 64)
        let state = cid("state")
        return .block(ChainBlockFact(
            blockHash: genesis, parentBlockHash: nil, blockHeight: 0,
            postStateCID: state, prevStateCID: state, specCID: cid("spec"),
            target: max, nextTarget: max, timestamp: 0, stateDiff: .empty
        ))
    }

    /// The grind is strengthened twice, then the block's validation batch
    /// re-states its strongest grind (as `connectJob` builds it), which live
    /// import applies as a duplicate. Replay sorts block batches first, so
    /// that batch lands the final quantity in one mutation and both work
    /// batches replay as duplicates: one revision fewer than live.
    func testRestartAfterARestatedStrengthenedGrindDoesNotMoveTheRevisionBack() throws {
        let batches = [
            BlockImportBatch(facts: [Self.block, try Self.work(1)]),
            BlockImportBatch(facts: [try Self.work(2)]),
            BlockImportBatch(facts: [try Self.work(3)]),
            BlockImportBatch(facts: [
                Self.block, try Self.work(3), .validation(ChainValidationFact(blockHash: Self.genesis)),
            ]),
        ]
        var live = try ChainTree.restore(replaying: [batches[0]], context: Self.context)
        for batch in batches.dropFirst() { _ = try live.replay(batch) }
        XCTAssertEqual(live.workContribution(id: Self.grind, at: Self.genesis)?.work, 3)
        XCTAssertTrue(live.isExecuted(blockHash: Self.genesis))
        let exposed = live.currentRevision()
        XCTAssertEqual(exposed, 3)

        // The bare replay count is lower: the hazard the floor covers.
        let bare = try ChainTree.restore(replaying: batches, context: Self.context)
        XCTAssertLessThan(bare.currentRevision(), exposed)

        let restored = try ChainCore.restore(replaying: batches, context: Self.context, specs: [])
        XCTAssertGreaterThanOrEqual(restored.tree.currentRevision(), exposed)
        XCTAssertEqual(restored.tree.workContribution(id: Self.grind, at: Self.genesis)?.work, 3)

        // A second restart of the same facts exposes the same revision.
        let again = try ChainCore.restore(replaying: batches, context: Self.context, specs: [])
        XCTAssertEqual(again.tree.currentRevision(), restored.tree.currentRevision())
    }
}
