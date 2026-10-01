import Foundation
import Lattice
import LatticeNodeCore
import LatticeNodeSim
import XCTest
import cashew
@testable import LatticeNodeStore

/// Store-level crash images, torn write-ahead logs, and the content
/// collector.
final class CrashAndCollectorTests: StoreTestCase {
    /// The database files as a crash would leave them: the main file and the
    /// write-ahead log, without the rebuildable shared-memory index.
    func crashImage(of path: String, into directory: URL) throws -> String {
        let image = dbPath(directory)
        for suffix in ["", "-wal"] where FileManager.default.fileExists(atPath: path + suffix) {
            try FileManager.default.copyItem(atPath: path + suffix, toPath: image + suffix)
        }
        return image
    }

    /// The fixture's root level alone, and its child level alone.
    func split(_ batch: StoreBatch) -> (root: StoreBatch, child: StoreBatch) {
        var root = StoreBatch()
        var child = StoreBatch()
        root.added = batch.added.filter { $0.path == LevelWorld.nexus }
        child.added = batch.added.filter { $0.path != LevelWorld.nexus }
        root.levels = batch.levels.filter { $0.path == LevelWorld.nexus }
        child.levels = batch.levels.filter { $0.path != LevelWorld.nexus }
        root.content = batch.content
        return (root, child)
    }

    /// A crash before the commit keeps no part of the batch: neither its log
    /// rows nor its content.
    func testCrashBeforeCommitKeepsNoPartOfTheBatch() async throws {
        let fixture = try await Self.fixture.value
        let path = dbPath(try directory())
        let store = try Store(path: path, rootGenesis: fixture.rootGenesis)
        let parts = split(fixture.batch)
        let root = parts.root
        var child = parts.child
        child.content = ["unreferenced-before-commit": Data([0xA0])]
        try store.apply(root)
        let committed = try logCount(store)
        var image = ""
        let crashDirectory = try directory()
        try store.apply(child) { image = try crashImage(of: path, into: crashDirectory) }

        let recovered = try Store(path: image, rootGenesis: fixture.rootGenesis)
        XCTAssertEqual(try logCount(recovered), committed)
        XCTAssertEqual(try recovered.restore().records.map(\.path), [LevelWorld.nexus])
        XCTAssertNil(try recovered.content("unreferenced-before-commit"))
        XCTAssertEqual(try logCount(store), committed + (try Store.rows(child)).count)
    }

    /// A write-ahead log torn or corrupted at any byte recovers to a prefix
    /// of whole batches, and every recovered block row has its content.
    func testTornWriteAheadLogRecoversWholeBatches() async throws {
        let fixture = try await Self.fixture.value
        let root = split(fixture.batch).root
        let headers = try XCTUnwrap(fixture.host.levels[LevelWorld.nexus]?.headers)
        var batches: [StoreBatch] = []
        var first = StoreBatch()
        for record in root.added { try first.add(record) }
        batches.append(first)
        for facts in root.levels.flatMap(\.facts) {
            var batch = StoreBatch()
            for fact in facts.facts {
                if case .block(let block) = fact, let header = headers[block.blockHash] {
                    try batch.add(PersistBatch(headers: [header], facts: []), at: LevelWorld.nexus)
                }
            }
            batch.levels = [(LevelWorld.nexus, [facts])]
            batches.append(batch)
        }

        let path = dbPath(try directory())
        let store = try Store(path: path, rootGenesis: fixture.rootGenesis)
        try store.locked { db in try db.script("PRAGMA wal_autocheckpoint=0") }
        var prefixes: Set<Int> = [0]
        var rows = 0
        for batch in batches {
            try store.apply(batch)
            rows += try Store.rows(batch).count
            prefixes.insert(rows)
        }
        let image = try crashImage(of: path, into: try directory())
        let wal = try Data(contentsOf: URL(fileURLWithPath: image + "-wal"))
        XCTAssertGreaterThan(wal.count, 4_096)

        var recoveredCounts: Set<Int> = []
        for cut in stride(from: 0, to: wal.count, by: max(1, wal.count / 48)) {
            for torn in [wal.prefix(cut), corrupted(wal, at: cut)] {
                let directory = try directory()
                let copy = dbPath(directory)
                try FileManager.default.copyItem(atPath: image, toPath: copy)
                try Data(torn).write(to: URL(fileURLWithPath: copy + "-wal"))
                let recovered = try Store(path: copy, rootGenesis: fixture.rootGenesis)
                let count = try logCount(recovered)
                XCTAssertTrue(prefixes.contains(count), "cut \(cut): \(count) rows is no whole-batch prefix")
                let missing = try recovered.locked { db in
                    try db.first(
                        "SELECT COUNT(*) FROM log WHERE kind = 'block' AND cid NOT IN (SELECT cid FROM content)"
                    ) { $0.int(0) }
                }
                XCTAssertEqual(missing, 0, "cut \(cut): a recovered block row lacks its content")
                recoveredCounts.insert(count)
            }
        }
        XCTAssertGreaterThan(recoveredCounts.count, 2, "the cuts exercised several prefixes")
    }

    private func corrupted(_ data: Data, at offset: Int) -> Data {
        var data = data
        if offset < data.count { data[data.startIndex + offset] ^= 0xFF }
        return data
    }

    // MARK: - Collector

    func testCollectorSweepsOnlyUnreachableContent() async throws {
        let fixture = try await Self.fixture.value
        let store = try Store(path: dbPath(try directory()), rootGenesis: fixture.rootGenesis)
        try store.apply(fixture.batch)
        try store.put(["junk": Data([0xA0]), "in-flight": Data([0xA0])])
        try store.addToMempool("pending-tx", content: ["pending-tx": Data([0xA0])], at: LevelWorld.nexus, addedAt: 1)

        XCTAssertEqual(try store.collectGarbage(keeping: ["in-flight"]), 1)
        let held = try contentCIDs(store)
        XCTAssertFalse(held.contains("junk"))
        XCTAssertTrue(held.isSuperset(of: ["in-flight", "pending-tx"]))
        XCTAssertTrue(held.isSuperset(of: fixture.batch.content.keys), "a linked node was swept")
        XCTAssertEqual(try store.collectGarbage(), 1, "in-flight content is collected once no one keeps it")
    }

    /// Content a root reaches but the collector cannot read stops the sweep:
    /// it fails closed rather than lose what that content links.
    func testUntraceableReachableContentStopsTheSweep() throws {
        let store = try Store(path: dbPath(try directory()), rootGenesis: "genesis")
        try store.put(["junk": Data([0xA0])])
        try store.addToMempool("opaque", content: ["opaque": Data([0xFF, 0x00])], at: ["Nexus"], addedAt: 1)
        XCTAssertThrowsError(try store.collectGarbage()) {
            XCTAssertEqual($0 as? StoreError, .untraceable("opaque"))
        }
        XCTAssertNotNil(try store.content("junk"))
    }

    func testLinksAreEveryCashewLink() async throws {
        let fixture = try await Self.fixture.value
        let genesis = try XCTUnwrap(fixture.batch.added.first).genesis.block
        let links = try XCTUnwrap(Links.of(try XCTUnwrap(genesis.toData())))
        XCTAssertTrue(Set(links).isSuperset(of: [
            genesis.spec.rawCID, genesis.postState.rawCID, genesis.prevState.rawCID,
            genesis.children.rawCID, genesis.transactions.rawCID,
        ]))
        XCTAssertNil(Links.of(Data([0xFF])))
        XCTAssertNil(Links.of(Data([0xA1, 0x60])), "a truncated map is malformed")
    }
}
