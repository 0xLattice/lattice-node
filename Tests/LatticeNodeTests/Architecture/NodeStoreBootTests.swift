import Foundation
import Ivy
import Lattice
import XCTest
@testable import LatticeBlockTree
@testable import LatticeNode

/// The checks boot runs on state.db: a store from another schema, network or
/// chain is refused before any DDL, and the normalized indexes must be
/// exactly what the journaled batches imply.
final class NodeStoreBootTests: XCTestCase {
    private func store(_ path: URL, genesis: String = NexusGenesis.expectedBlockHash, chain: [String] = ["Nexus"]) throws -> NodeStore {
        try NodeStore(databasePath: path, nexusGenesisCID: genesis, chainPath: chain)
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

    private func expectCorrupt(_ store: NodeStore) async {
        do {
            try await store.auditNormalizedIndexes()
            XCTFail("expected the audit to refuse")
        } catch NodeStoreError.corrupt {
        } catch {
            XCTFail("expected corruption, got \(error)")
        }
    }

    func testLegacyDatabaseFailsBeforeNewDDL() throws {
        let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
        let legacy = try NodeSQLite(path: path.path)
        _ = try legacy.execute("CREATE TABLE legacy_state (value TEXT NOT NULL)")
        XCTAssertThrowsError(try store(path)) { error in
            guard case NodeStoreError.wipeRequired = error else { return XCTFail("got \(error)") }
        }
        let tables = try legacy.query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
        ).compactMap { $0["name"]?.textValue }
        XCTAssertEqual(tables, ["legacy_state"])
    }

    func testMetadataRejectsWrongEpochRootAndPath() throws {
        let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
        _ = try store(path)
        let database = try NodeSQLite(path: path.path)
        for epoch in [NodeStore.currentSchemaEpoch - 1, NodeStore.currentSchemaEpoch + 1] {
            _ = try database.execute(
                "UPDATE node_metadata SET schema_epoch = ?1 WHERE singleton = 1", params: [.int(epoch)]
            )
            XCTAssertThrowsError(try store(path)) { error in
                guard case NodeStoreError.wipeRequired = error else { return XCTFail("got \(error)") }
            }
        }
        _ = try database.execute(
            "UPDATE node_metadata SET schema_epoch = ?1 WHERE singleton = 1",
            params: [.int(NodeStore.currentSchemaEpoch)]
        )
        for attempt in [
            { try self.store(path, genesis: "different-root") },
            { try self.store(path, chain: ["Nexus", "Payments"]) },
        ] {
            XCTAssertThrowsError(try attempt()) { error in
                guard case NodeStoreError.wipeRequired = error else { return XCTFail("got \(error)") }
            }
        }
    }

    func testNormalizedIndexAuditRequiresExactBatchDerivedRows() async throws {
        let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
        let store = try store(path)
        try await store.stageCoreFacts([blockBatch("child")], volumeRoots: [], logID: "log")
        try await store.auditNormalizedIndexes()
        _ = try NodeSQLite(path: path.path).execute(
            "INSERT INTO admission_facts (fact_id, payload) VALUES (?1, ?2)",
            params: [.blob(Data("extra-id".utf8)), .blob(Data("extra".utf8))]
        )
        await expectCorrupt(store)
    }

    func testNormalizedIndexAuditRejectsMissingAcceptedBlockRow() async throws {
        let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
        let store = try store(path)
        try await store.stageCoreFacts([blockBatch("accepted")], volumeRoots: [], logID: "log")
        try await store.auditNormalizedIndexes()
        _ = try NodeSQLite(path: path.path).execute(
            "DELETE FROM accepted_blocks WHERE block_cid = ?1", params: [.text("accepted")]
        )
        await expectCorrupt(store)
    }
}
