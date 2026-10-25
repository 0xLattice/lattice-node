#if canImport(Darwin)
import Darwin
import Foundation
import Lattice
import UInt256
import XCTest
import cashew
@testable import LatticeBlockTree
@testable import LatticeNode

/// What in-flight mining jobs cost while the live tree moves on: a job that
/// held a copy of its level's tree (`ChainLevel(tree:)`, as the per-epoch
/// copy did) makes the live tree's next insert duplicate its storage, so N
/// jobs on N tips hold up to N more trees. A job holding a `MiningBasis`
/// holds a few hundred bytes. Run with `MINING_BASIS_BENCH=1` (blocks:
/// `MINING_BASIS_BENCH_BLOCKS`, default 50,000); it prints heap in use.
final class MiningBasisMemoryBench: XCTestCase {
    private static let jobs = 8

    private static func cid(_ kind: String, _ index: Int) -> String {
        try! HeaderImpl<PublicKey>(node: PublicKey(key: "\(kind)\(index)")).rawCID
    }

    private struct Work: Encodable {
        let id: String
        let work: UInt256
    }

    /// Block `index` of one chain, weighed by a grind of its own and executed.
    private static func block(_ index: Int) throws -> BlockImportBatch {
        let hash = cid("b", index)
        let contribution = try JSONDecoder().decode(
            VerifiedWorkContribution.self, from: JSONEncoder().encode(Work(id: cid("g", index), work: 1))
        )
        let max = String(repeating: "f", count: 64)
        return BlockImportBatch(facts: [
            .block(ChainBlockFact(
                blockHash: hash, parentBlockHash: index == 0 ? nil : cid("b", index - 1),
                blockHeight: UInt64(index), postStateCID: cid("s", index), prevStateCID: cid("s", index - 1),
                specCID: cid("spec", 0), target: max, nextTarget: max, timestamp: Int64(index), stateDiff: .empty
            )),
            .work(ChainWorkFact(blockHash: hash, contribution: contribution)),
            .validation(ChainValidationFact(blockHash: hash)),
        ])
    }

    private static func heapInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.size_in_use)
    }

    /// Heap held after each of `jobs` in-flight jobs, each spawned on a tip
    /// the live tree then moves past, over a tree of `blocks` blocks.
    private func held(blocks: Int, copying: Bool) throws -> (tree: Int, jobs: [Int]) {
        let context = try ChainRuntimeContext(path: ["Nexus", "Bench"])
        let batches = try (0..<blocks + Self.jobs).map(Self.block)
        let start = Self.heapInUse()
        var live = try ChainTree.restore(replaying: Array(batches.prefix(blocks)), context: context)
        let tree = Self.heapInUse() - start
        var held: [Any] = []
        var jobs: [Int] = []
        let baseline = Self.heapInUse()
        for job in 0..<Self.jobs {
            let tip = Self.cid("b", blocks - 1 + job)
            if copying {
                held.append(try XCTUnwrap(ChainLevel(tree: live)))
            } else {
                held.append(MiningBasis(
                    snapshot: live.transactionPreflightTip(at: tip).snapshot, anchor: NodeRuntime.anchor(live, tip)
                ))
            }
            _ = try live.replay(batches[blocks + job])
            jobs.append(Self.heapInUse() - baseline)
        }
        withExtendedLifetime((live, held, batches)) {}
        return (tree, jobs)
    }

    func testJobsHoldingABasisKeepNoCopyOfTheTree() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["MINING_BASIS_BENCH"] == "1", "set MINING_BASIS_BENCH=1 to measure")
        let blocks = environment["MINING_BASIS_BENCH_BLOCKS"].flatMap(Int.init) ?? 50_000
        let copies = try held(blocks: blocks, copying: true)
        let basis = try held(blocks: blocks, copying: false)
        let mb = { (bytes: Int) in String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        print("""
            mining-basis bench: \(blocks) blocks, \(Self.jobs) jobs in flight
              tree: \(mb(copies.tree))
              jobs holding a tree copy, after each job: \(copies.jobs.map(mb))
              jobs holding a basis, after each job:     \(basis.jobs.map(mb))
            """)
        XCTAssertLessThan(basis.jobs.last ?? 0, copies.jobs.last ?? 0)
    }
}
#endif
