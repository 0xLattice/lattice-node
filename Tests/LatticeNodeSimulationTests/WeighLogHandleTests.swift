import Foundation
import Lattice
import UInt256
import XCTest
import cashew
@testable import LatticeBlockTree
@testable import LatticeNodeCore

/// A logged object is known by a bit at its tree handle, or by value while
/// the tree has no handle for it: either way an object is logged once, as
/// a set of entries would have it.
final class WeighLogHandleTests: XCTestCase {
    private static let context = try! ChainRuntimeContext(path: ["Nexus", "Handles"])
    private static let genesis = cid("genesis")
    private static let grind = cid("grind")

    private static func cid(_ seed: String) -> String {
        try! HeaderImpl<PublicKey>(node: PublicKey(key: "weigh-log-handles:\(seed)")).rawCID
    }

    private struct Work: Encodable {
        let id: String
        let work: UInt256
    }

    private static func work(_ work: UInt256, at hash: String) throws -> ChainFact {
        .work(ChainWorkFact(blockHash: hash, contribution: try JSONDecoder().decode(
            VerifiedWorkContribution.self, from: JSONEncoder().encode(Work(id: grind, work: work))
        )))
    }

    /// A tree holding the genesis, credited with `grind` at each of `works`
    /// in turn (each stronger one re-states the grind's work fact).
    private static func tree(works: [UInt256]) throws -> ChainTree {
        let max = String(repeating: "f", count: 64)
        let state = cid("state")
        let block = ChainFact.block(ChainBlockFact(
            blockHash: genesis, parentBlockHash: nil, blockHeight: 0,
            postStateCID: state, prevStateCID: state, specCID: cid("spec"),
            target: max, nextTarget: max, timestamp: 0, stateDiff: .empty
        ))
        let batches = try works.enumerated().map { index, work in
            BlockImportBatch(facts: (index == 0 ? [block] : []) + [try Self.work(work, at: genesis)])
        }
        return try ChainTree.restore(replaying: batches, context: context)
    }

    /// Logged by value before the tree took it, then re-stated once the
    /// tree holds it (and so has a handle): still logged once.
    func testAnEntryLoggedWithoutAHandleStaysLoggedOnceTheTreeTakesIt() throws {
        let empty = ChainTree.empty(context: Self.context)
        let held = try Self.tree(works: [1])
        let header = LogEntry.header(Self.genesis)
        let proof = LogEntry.proof(Self.grind, of: Self.genesis)
        XCTAssertNotNil(held.handle(of: Self.genesis))
        XCTAssertNotNil(held.grindHandle(of: Self.grind, at: Self.genesis))

        var log = WeighLog(id: "log")
        XCTAssertTrue(log.append(header, in: empty))
        XCTAssertTrue(log.append(proof, in: empty))
        XCTAssertFalse(log.append(header, in: held))
        XCTAssertFalse(log.append(proof, in: held))
        XCTAssertEqual(log.entries, [header, proof])
        XCTAssertTrue(log.contains(header, in: held))
        XCTAssertTrue(log.contains(proof, in: held))
    }

    /// A grind credited again with stronger work at the same block re-emits
    /// its work fact; the proof is logged once.
    func testAStrongerReCreditOfTheSameGrindIsNotLoggedAgain() throws {
        let tree = try Self.tree(works: [1, 5])
        XCTAssertEqual(tree.workContribution(id: Self.grind, at: Self.genesis)?.work, 5)
        let proof = LogEntry.proof(Self.grind, of: Self.genesis)

        var log = WeighLog(id: "log")
        XCTAssertTrue(log.append(.header(Self.genesis), in: tree))
        XCTAssertTrue(log.append(proof, in: tree))
        XCTAssertFalse(log.append(proof, in: tree))
        XCTAssertEqual(log.entries, [.header(Self.genesis), proof])
    }

    /// A hand-built header entry naming another block is not the header of
    /// that block.
    func testAHeaderNamingAnotherBlockIsNotThatBlocksHeader() throws {
        let held = try Self.tree(works: [1])
        var log = WeighLog(id: "log")
        XCTAssertTrue(log.append(.header(Self.genesis), in: held))
        XCTAssertFalse(log.contains(LogEntry(kind: .header, cid: Self.cid("other"), block: Self.genesis), in: held))
    }
}
