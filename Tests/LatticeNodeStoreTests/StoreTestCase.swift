import Foundation
import Lattice
import LatticeNodeCore
import LatticeNodeSim
import XCTest
import cashew
@testable import LatticeNodeStore

/// Shared fixtures and helpers.
class StoreTestCase: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
    }

    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        return url
    }

    func dbPath(_ directory: URL) -> String { directory.appendingPathComponent("node.db").path }

    // MARK: - Fixtures

    /// A small two-level simulated run and one core's durable store as a
    /// single store batch, with the digests that core reached.
    struct Fixture: Sendable {
        let paths: [ChainPath]
        let hosted: Set<ChainPath>
        let coreConfig: ChainCoreConfig
        let host: HostStore
        let batch: StoreBatch
        let digests: [ChainPath: TreeDigest]
        let rootGenesis: String
    }

    static let fixture: Task<Fixture, Error> = Task {
        var config = LevelSimConfig(seed: 0x5_70_4E)
        config.levels = 2
        config.grinds = 14
        config.cores = 2
        config.settle = 30_000
        var simulator = try await LevelSimulator.make(config)
        let report = try await simulator.run()
        let core = try XCTUnwrap(report.digests.keys.sorted().first)
        let host = try XCTUnwrap(simulator.durable(core))
        var batch = StoreBatch()
        for path in host.records.keys.sorted(by: { $0.count < $1.count }) {
            try batch.add(try XCTUnwrap(host.records[path]))
        }
        for (path, level) in host.levels.sorted(by: { $0.key.count < $1.key.count }) {
            try batch.add(ChainBatch(headers: Array(level.headers.values), facts: level.facts), at: path)
        }
        return Fixture(
            paths: simulator.world.paths,
            hosted: simulator.world.hosted,
            coreConfig: simulator.coreConfig,
            host: host,
            batch: batch,
            digests: try XCTUnwrap(report.digests[core]),
            rootGenesis: try XCTUnwrap(host.records[LevelWorld.nexus]).genesis.blockCID
        )
    }

    /// A Lattice batch from facts, through Lattice's own decoding.
    func batch(_ facts: [ChainFact]) throws -> BlockImportBatch {
        try Store.decode(Store.encode(facts))
    }

    func logCount(_ store: Store) throws -> Int {
        try store.locked { db in try db.first("SELECT COUNT(*) FROM log") { Int($0.int(0)) } ?? 0 }
    }

    func contentCIDs(_ store: Store) throws -> Set<String> {
        try store.locked { db in
            var cids = Set<String>()
            try db.each("SELECT cid FROM content") { cids.insert($0.text(0)) }
            return cids
        }
    }

}
