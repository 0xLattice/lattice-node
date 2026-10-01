import Foundation
import Lattice
import LatticeNodeCore
import LatticeNodeSim
import XCTest
import cashew
@testable import LatticeNodeStore

/// Boot-replay cost: a synthetic root chain of `STORE_BENCH_BLOCKS` blocks,
/// four facts each (block, its grind, a second grind, a validation), written
/// to a store, then restored into the host core. Off unless the variable is
/// set: `STORE_BENCH_BLOCKS=100000 swift test --filter BootReplayBenchmark`.
final class BootReplayBenchmark: StoreTestCase {
    func testBootReplay() async throws {
        guard let count = ProcessInfo.processInfo.environment["STORE_BENCH_BLOCKS"].flatMap(Int.init) else {
            throw XCTSkip("set STORE_BENCH_BLOCKS to run")
        }
        let fixture = try await Self.fixture.value
        let record = try XCTUnwrap(fixture.batch.added.first { $0.path == LevelWorld.nexus })
        let rootFacts = try XCTUnwrap(fixture.batch.levels.first { $0.path == LevelWorld.nexus }).facts
        var genesisBlock: ChainBlockFact?
        var genesisWork: ChainWorkFact?
        for fact in rootFacts.flatMap(\.facts) {
            if case .block(let block) = fact, block.blockHeight == 0 { genesisBlock = block }
            if case .work(let work) = fact, work.blockHash == record.genesis.blockCID { genesisWork = work }
        }
        let genesis = try XCTUnwrap(genesisBlock)
        let work = try XCTUnwrap(genesisWork)

        let path = dbPath(try directory())
        let store = try Store(path: path, rootGenesis: record.genesis.blockCID)
        var setup = StoreBatch()
        try setup.add(record)
        setup.levels = [(LevelWorld.nexus, [try batch([.block(genesis), .work(work)])])]
        try store.apply(setup)

        let template = String(decoding: try JSONEncoder().encode(work.contribution), as: UTF8.self)
        func contribution(_ id: String) throws -> VerifiedWorkContribution {
            try JSONDecoder().decode(
                VerifiedWorkContribution.self,
                from: Data(template.replacingOccurrences(of: work.contribution.id, with: id).utf8)
            )
        }
        func cid(_ index: Int) throws -> String {
            try VolumeImpl<ChainSpec>(node: ChainSpec(
                maxNumberOfTransactionsPerBlock: 1, maxStateGrowth: 1, premine: UInt64(index),
                targetBlockTime: 1, initialReward: 1, halvingInterval: 1, halfLife: 1
            )).rawCID
        }

        let writeStart = Date()
        var parent = genesis.blockHash
        var chunk: [BlockImportBatch] = []
        func flush() throws {
            var batch = StoreBatch()
            batch.levels = [(LevelWorld.nexus, chunk)]
            try store.apply(batch)
            chunk = []
        }
        for height in 1...count {
            let block = try cid(2 * height)
            chunk.append(try batch([
                .block(ChainBlockFact(
                    blockHash: block, parentBlockHash: parent, blockHeight: UInt64(height),
                    postStateCID: genesis.postStateCID, prevStateCID: genesis.postStateCID,
                    specCID: genesis.specCID, target: genesis.target, nextTarget: genesis.nextTarget,
                    timestamp: genesis.timestamp + Int64(height) * 1_000, stateDiff: .empty, childCommitments: [:]
                )),
                .work(ChainWorkFact(blockHash: block, contribution: try contribution(block))),
            ]))
            chunk.append(try batch([.work(ChainWorkFact(blockHash: block, contribution: try contribution(try cid(2 * height + 1))))]))
            chunk.append(.validation(blockHash: block))
            parent = block
            if chunk.count >= 3_000 { try flush() }
        }
        try flush()
        let written = Date().timeIntervalSince(writeStart)

        let before = peakResidentBytes()
        let start = Date()
        let restored = try Store(path: path, rootGenesis: record.genesis.blockCID).restore()
        let scanned = Date()
        let host = try restored.host(hosted: [], config: fixture.coreConfig)
        let done = Date()
        let after = peakResidentBytes()

        XCTAssertEqual(host.levels[LevelWorld.nexus]?.tree.canonicalTip, parent)
        let size = fileSize(path) + fileSize(path + "-wal")
        let rows = restored.facts[LevelWorld.nexus]?.count ?? 0
        print("""
            BOOT-REPLAY blocks=\(count) rows=\(rows) facts=\(count * 4) \
            write=\(String(format: "%.2f", written))s \
            scan+decode=\(String(format: "%.2f", scanned.timeIntervalSince(start)))s \
            Core.restore=\(String(format: "%.2f", done.timeIntervalSince(scanned)))s \
            total=\(String(format: "%.2f", done.timeIntervalSince(start)))s \
            peakRSS=\(after / 1_048_576)MiB (before restore \(before / 1_048_576)MiB) \
            db=\(size / 1_048_576)MiB
            """)
    }

    private func fileSize(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
    }

    private func peakResidentBytes() -> Int {
        var usage = rusage()
        getrusage(0, &usage)  // RUSAGE_SELF on every platform
        #if os(Linux)
        return Int(usage.ru_maxrss) * 1_024
        #else
        return Int(usage.ru_maxrss)
        #endif
    }
}
