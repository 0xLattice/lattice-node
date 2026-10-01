import Foundation
import Lattice
import LatticeNodeCore
import LatticeNodeSim
import XCTest
import cashew
@testable import LatticeNodeStore

final class StoreTests: StoreTestCase {
    // MARK: - Schema

    func testOpenMigratesOnceAndReopens() throws {
        let path = dbPath(try directory())
        do {
            let store = try Store(path: path, rootGenesis: "genesis")
            XCTAssertEqual(try store.locked { try Schema.version($0) }, Schema.current)
        }
        let store = try Store(path: path, rootGenesis: "genesis")
        let tables = try store.locked { db in
            var tables: [String] = []
            try db.each("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name") { tables.append($0.text(0)) }
            return tables
        }
        XCTAssertEqual(tables, ["content", "log", "mempool", "meta"])
    }

    func testNewerSchemaIsRefused() throws {
        let path = dbPath(try directory())
        do {
            let store = try Store(path: path, rootGenesis: "genesis")
            try store.locked { try Meta.set(Meta.schemaVersion, String(Schema.current + 1), $0) }
        }
        XCTAssertThrowsError(try Store(path: path, rootGenesis: "genesis")) {
            XCTAssertEqual($0 as? StoreError, .newerSchema(found: Schema.current + 1, supported: Schema.current))
        }
    }

    func testAnotherNetworksStoreIsRefused() throws {
        let path = dbPath(try directory())
        _ = try Store(path: path, rootGenesis: "genesis")
        XCTAssertThrowsError(try Store(path: path, rootGenesis: "other")) {
            XCTAssertEqual($0 as? StoreError, .wrongNetwork(stored: "genesis", opened: "other"))
        }
    }

    // MARK: - Log

    /// A Lattice batch is one weight row (block and work together) plus one
    /// row per verdict; attributed runs are their own kind.
    func testRowsKeepWeightTogetherAndSplitVerdicts() async throws {
        let fixture = try await Self.fixture.value
        let rootFacts = try XCTUnwrap(fixture.batch.levels.first { $0.path == LevelWorld.nexus }).facts
        let genesis = try XCTUnwrap(rootFacts.first { $0.facts.contains { if case .block = $0 { true } else { false } } })
        let weight = genesis.facts.filter {
            switch $0 {
            case .block, .work: true
            case .validation, .exclusion: false
            }
        }
        var combined = weight
        guard case .block(let block) = combined[0] else { return XCTFail("genesis batch starts with its block") }
        combined.append(.validation(ChainValidationFact(blockHash: block.blockHash)))
        combined.append(.exclusion(ChainExclusionFact(blockHash: block.blockHash)))
        var batch = StoreBatch()
        batch.levels = [(LevelWorld.nexus, [try self.batch(combined)])]
        let rows = try Store.rows(batch)
        XCTAssertEqual(rows.map(\.kind), [.block, .validation, .exclusion])
        XCTAssertEqual(Set(rows.map(\.cid)), [block.blockHash])
        XCTAssertEqual(try Store.decode(rows[0].fact).facts, weight)
    }

    /// The store alone rebuilds the trees a simulated host reached, at
    /// every level, from one scan of the log.
    func testRestoreRebuildsTheSimulatedHost() async throws {
        let fixture = try await Self.fixture.value
        let path = dbPath(try directory())
        try Store(path: path, rootGenesis: fixture.rootGenesis).apply(fixture.batch)
        let restored = try Store(path: path, rootGenesis: fixture.rootGenesis).restore()
        XCTAssertEqual(restored.records.map(\.path), fixture.paths)
        let host = try restored.host(hosted: fixture.hosted, config: fixture.coreConfig)
        XCTAssertEqual(Set(host.levels.keys), Set(fixture.digests.keys))
        for (chain, digest) in fixture.digests {
            XCTAssertEqual(TreeDigest(try XCTUnwrap(host.levels[chain]).tree), digest, "\(chain)")
        }
    }

    /// A level added again replays from its new record; a dropped level is
    /// not restored.
    func testLevelRecordsReplaceAndDrop() async throws {
        let fixture = try await Self.fixture.value
        let store = try Store(path: dbPath(try directory()), rootGenesis: fixture.rootGenesis)
        try store.apply(fixture.batch)
        let child = LevelWorld.alpha
        var drop = StoreBatch()
        drop.removed = [child]
        try store.apply(drop)
        XCTAssertEqual(try store.restore().records.map(\.path), [LevelWorld.nexus])
        XCTAssertNil(try store.restore().facts[child])

        var again = StoreBatch()
        try again.add(try XCTUnwrap(fixture.batch.added.first { $0.path == child }))
        try store.apply(again)
        let restored = try store.restore()
        XCTAssertEqual(restored.records.map(\.path), [LevelWorld.nexus, child])
        XCTAssertEqual(restored.facts[child]?.count, 0)
    }

    /// The weight-fact stream: header and proof entries only, in log order,
    /// resumable from any position.
    func testWeightFactStreamResumesByPosition() async throws {
        let fixture = try await Self.fixture.value
        let store = try Store(path: dbPath(try directory()), rootGenesis: fixture.rootGenesis)
        try store.apply(fixture.batch)
        for chain in fixture.paths {
            let all = try store.weightFacts(chain, after: 0, limit: .max)
            XCTAssertFalse(all.isEmpty)
            XCTAssertTrue(all.allSatisfy { $0.kind == .block || $0.kind == .work })
            XCTAssertTrue(all.allSatisfy { !$0.grind.isEmpty })
            XCTAssertEqual(all.map(\.seq), all.map(\.seq).sorted())
            var resumed: [WeightEntry] = []
            var position: Int64 = 0
            while case let page = try store.weightFacts(chain, after: position, limit: 3), let last = page.last {
                resumed += page
                position = last.seq
            }
            XCTAssertEqual(resumed, all)
            let weighed = Set(try XCTUnwrap(fixture.digests[chain]).blocks.keys)
            XCTAssertEqual(Set(all.filter { $0.kind == .block }.map(\.block)), weighed)
        }
    }

    func testMempoolJournal() throws {
        let store = try Store(path: dbPath(try directory()), rootGenesis: "genesis")
        try store.addToMempool("b", content: ["b": Data([0xA0])], at: ["Nexus"], addedAt: 2)
        try store.addToMempool("a", content: ["a": Data([0xA0])], at: ["Nexus"], addedAt: 1)
        try store.addToMempool("c", content: ["c": Data([0xA0])], at: ["Nexus", "Alpha"], addedAt: 1)
        try store.removeFromMempool(["b"], at: ["Nexus"])
        XCTAssertEqual(try store.restore().mempool, [["Nexus"]: ["a"], ["Nexus", "Alpha"]: ["c"]])
        XCTAssertEqual(try store.content("b"), Data([0xA0]))
    }

    func testVolumeRoundTrip() async throws {
        let store = try Store(path: dbPath(try directory()), rootGenesis: "genesis")
        let volume = SerializedVolume(root: "r", entries: ["r": Data([1]), "m1": Data([2]), "m2": Data([3])])
        try await store.store(volume: volume)
        let read = try XCTUnwrap(try store.volume("r"))
        XCTAssertEqual(read.root, "r")
        XCTAssertEqual(read.entries, volume.entries)
        XCTAssertNil(try store.volume("m1"))
    }
}
