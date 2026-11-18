import Foundation
import Ivy
import Lattice
import LatticeNodeCore
import XCTest
@testable import LatticeBlockTree
@testable import LatticeNode

/// A peer's cursor into this node's weigh log is (id, position). A run that
/// did not stop cleanly may have lost the log's tail, so its log continues
/// under a new id and every peer reads it again from its start; a run that
/// stopped cleanly keeps the id, and its peers their positions.
final class WeighLogIDTests: XCTestCase {
    private func store(_ path: URL) throws -> NodeStore {
        try NodeStore(databasePath: path, nexusGenesisCID: NexusGenesis.expectedBlockHash)
    }

    private func blockBatch(_ hash: String) -> BlockImportBatch {
        BlockImportBatch(facts: [
            .block(ChainBlockFact(
                blockHash: hash, parentBlockHash: nil, blockHeight: 0, postStateCID: "state",
                prevStateCID: "previous-state", specCID: "spec", target: "target", nextTarget: "next-target",
                timestamp: 0, stateDiff: .empty
            )),
        ])
    }

    func testAStoreThatJournaledNothingTakesTheFreshIDWithItsFirstFact() async throws {
        let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
        let store = try store(path)
        let opened = try await store.openWeighLog(fresh: "first")
        XCTAssertEqual(opened.id, "first")
        XCTAssertFalse(opened.replaced, "there was no log to replace")
        let before = try await store.chainLogID()
        XCTAssertNil(before, "the id is recorded with the first fact, not before")
        try await store.stageChainFacts([blockBatch("a")], logID: opened.id)
        let after = try await store.chainLogID()
        XCTAssertEqual(after, "first")
    }

    func testACleanStopKeepsTheLogID() async throws {
        let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
        do {
            let store = try store(path)
            let opened = try await store.openWeighLog(fresh: "first")
            try await store.stageChainFacts([blockBatch("a")], logID: opened.id)
            try await store.markCleanStop()
        }
        let reopened = try store(path)
        let opened = try await reopened.openWeighLog(fresh: "second")
        XCTAssertEqual(opened.id, "first")
        XCTAssertFalse(opened.replaced)
    }

    func testAnUncleanStopGivesTheLogANewID() async throws {
        let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
        do {
            let store = try store(path)
            let opened = try await store.openWeighLog(fresh: "first")
            try await store.stageChainFacts([blockBatch("a")], logID: opened.id)
            // No clean stop: the process died.
        }
        let reopened = try store(path)
        let opened = try await reopened.openWeighLog(fresh: "second")
        XCTAssertEqual(opened.id, "second")
        XCTAssertTrue(opened.replaced)
        let stored = try await reopened.chainLogID()
        XCTAssertEqual(stored, "second", "the new id is the stored one")
        // Facts journaled by the run that follows do not bring the old id back.
        try await reopened.stageChainFacts([blockBatch("b")], logID: opened.id)
        let kept = try await reopened.chainLogID()
        XCTAssertEqual(kept, "second")
    }

    /// The mark is cleared when a run opens the log, so a second unclean stop
    /// replaces the id again, and a clean one after it keeps the newest.
    func testEveryUncleanStopReplacesTheIDAndACleanOneKeepsIt() async throws {
        let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
        do {
            let store = try store(path)
            let opened = try await store.openWeighLog(fresh: "first")
            try await store.stageChainFacts([blockBatch("a")], logID: opened.id)
            try await store.markCleanStop()
        }
        do {
            let store = try store(path)
            let opened = try await store.openWeighLog(fresh: "second")
            XCTAssertEqual(opened.id, "first")
        }
        do {
            let store = try store(path)
            let opened = try await store.openWeighLog(fresh: "third")
            XCTAssertEqual(opened.id, "third")
            XCTAssertTrue(opened.replaced)
            try await store.markCleanStop()
        }
        let last = try await store(path).openWeighLog(fresh: "fourth")
        XCTAssertEqual(last.id, "third")
        XCTAssertFalse(last.replaced)
    }

    /// A store seeded before its first run (boot recovery seeds the Nexus
    /// genesis) recorded its whole log in one transaction: it starts clean.
    func testAStoreSeededBeforeItsFirstRunKeepsItsID() async throws {
        let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
        let store = try store(path)
        try await store.stageChainFacts([blockBatch("genesis")], logID: "seeded")
        let opened = try await store.openWeighLog(fresh: "other")
        XCTAssertEqual(opened.id, "seeded")
        XCTAssertFalse(opened.replaced)
    }

    /// A store written before the mark existed has a log id and no mark. It
    /// cannot say how its last run stopped, so its log gets a new id, once.
    func testAStoreFromBeforeTheMarkGetsANewIDOnce() async throws {
        let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
        do {
            let store = try store(path)
            try await store.stageChainFacts([blockBatch("a")], logID: "old")
        }
        do {
            let database = try NodeSQLite(path: path.path)
            try database.execute("DELETE FROM core_meta WHERE key = 'clean_stop'")
        }
        do {
            let store = try store(path)
            let opened = try await store.openWeighLog(fresh: "new")
            XCTAssertEqual(opened.id, "new")
            XCTAssertTrue(opened.replaced)
            try await store.markCleanStop()
        }
        let again = try await store(path).openWeighLog(fresh: "newer")
        XCTAssertEqual(again.id, "new")
        XCTAssertFalse(again.replaced)
    }

    /// The runtime end to end: a node that is stopped and started again keeps
    /// its log id, and while it runs its store is not marked clean.
    func testANodeStoppedAndStartedAgainKeepsItsLogID() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-weigh-log-id-\(UUID().uuidString)", isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let port = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"], storagePath: directory,
            privateKeyHex: String(repeating: "7c", count: 32),
            listenPort: port, rpcPort: NetworkTransportTestPorts.allocate(), externalAddress: "127.0.0.1"
        )
        let overlay = IvyConfig(
            signingKey: configuration.signingKey, listenPort: port, bootstrapPeers: [],
            requestTimeout: .seconds(5), stunServers: [], healthConfig: PeerHealthConfig(enabled: false),
            externalAddress: ("127.0.0.1", port), mode: .overlay
        )
        var first: String?
        do {
            let storage = try await NodeStorage.open(configuration: configuration)
            let runtime = try await NodeRuntime.start(storage: storage, configuration: configuration, overlay: overlay)
            first = try await storage.chainLogID()
            XCTAssertNotNil(first)
            await runtime.stop()
        }
        do {
            let storage = try await NodeStorage.open(configuration: configuration)
            let runtime = try await NodeRuntime.start(storage: storage, configuration: configuration, overlay: overlay)
            let second = try await storage.chainLogID()
            XCTAssertEqual(second, first, "a clean stop keeps the id")
            // Running, so not marked clean: a start now would replace the id.
            let whileRunning = try await storage.store.openWeighLog(fresh: "probe")
            XCTAssertTrue(whileRunning.replaced)
            await runtime.stop()
        }
    }
}
