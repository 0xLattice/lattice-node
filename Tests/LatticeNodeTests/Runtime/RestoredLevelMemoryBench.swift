#if canImport(Darwin)
import Darwin
import Foundation
import Lattice
import LatticeNodeCore
import UInt256
import XCTest
import cashew
@testable import LatticeBlockTree

/// What a restored child level holds per block, beside its tree: a chain
/// with a fork sibling every few blocks and two proofs on every block, its
/// main chain executed. Run with `RESTORED_LEVEL_BENCH=1` (blocks:
/// `RESTORED_LEVEL_BENCH_BLOCKS`, default 50,000); it prints heap in use.
final class RestoredLevelMemoryBench: XCTestCase {
    private static let forkEvery = 4

    private static func cid(_ kind: String, _ index: Int) -> String {
        try! HeaderImpl<PublicKey>(node: PublicKey(key: "\(kind)\(index)")).rawCID
    }

    private struct Work: Encodable {
        let id: String
        let work: UInt256
    }

    private static func work(_ id: String, at hash: String) throws -> ChainFact {
        .work(ChainWorkFact(blockHash: hash, contribution: try JSONDecoder().decode(
            VerifiedWorkContribution.self, from: JSONEncoder().encode(Work(id: id, work: 1))
        )))
    }

    private static func header(_ hash: String, parent: String?, height: Int, state: Int) -> ChainFact {
        let max = String(repeating: "f", count: 64)
        return .block(ChainBlockFact(
            blockHash: hash, parentBlockHash: parent, blockHeight: UInt64(height),
            postStateCID: cid("s", state), prevStateCID: cid("s", state - 1), specCID: cid("spec", 0),
            target: max, nextTarget: max, timestamp: Int64(height), stateDiff: .empty
        ))
    }

    /// Main block `index` with two grinds, executed; every `forkEvery`th
    /// also a weighed sibling with two grinds of its own.
    private static func batches(_ index: Int) throws -> [BlockImportBatch] {
        let hash = cid("b", index)
        let parent = index == 0 ? nil : cid("b", index - 1)
        var batches = [BlockImportBatch(facts: [
            header(hash, parent: parent, height: index, state: index),
            try work(cid("g", 2 * index), at: hash),
            .validation(ChainValidationFact(blockHash: hash)),
        ]), BlockImportBatch(facts: [try work(cid("g", 2 * index + 1), at: hash)])]
        if index > 0, index % forkEvery == 0 {
            let side = cid("x", index)
            batches.append(BlockImportBatch(facts: [
                header(side, parent: parent, height: index, state: -index),
                try work(cid("h", 2 * index), at: side),
            ]))
            batches.append(BlockImportBatch(facts: [try work(cid("h", 2 * index + 1), at: side)]))
        }
        return batches
    }

    private static func heapInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.size_in_use)
    }

    func testHeapPerBlockOfARestoredLevel() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["RESTORED_LEVEL_BENCH"] == "1", "set RESTORED_LEVEL_BENCH=1 to measure")
        let blocks = environment["RESTORED_LEVEL_BENCH_BLOCKS"].flatMap(Int.init) ?? 50_000
        let context = try ChainRuntimeContext(path: ["Nexus", "Bench"])
        let facts = try (0..<blocks).flatMap(Self.batches)
        let held = blocks + (blocks - 1) / Self.forkEvery

        var start = Self.heapInUse()
        let tree = try ChainTree.restore(replaying: facts, context: context)
        let treeBytes = Self.heapInUse() - start
        withExtendedLifetime(tree) {}

        start = Self.heapInUse()
        let core = try ChainCore.restore(replaying: facts, context: context, specs: [])
        let coreBytes = Self.heapInUse() - start
        XCTAssertEqual(core.sync.log.count, UInt64(3 * held))
        withExtendedLifetime((core, facts)) {}

        let perBlock = { (bytes: Int) in String(format: "%.0f B/block", Double(bytes) / Double(held)) }
        print("""
            restored-level bench: \(held) blocks (\(blocks) main, a fork every \(Self.forkEvery)), 2 proofs each
              tree alone:            \(perBlock(treeBytes))
              level (tree and core): \(perBlock(coreBytes))
              core beside the tree:  \(perBlock(coreBytes - treeBytes))
            """)
    }
}
#endif
