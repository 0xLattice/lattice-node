import Foundation
import Ivy
import Lattice
import LatticeNodeCore
import XCTest
@testable import LatticeBlockTree
@testable import LatticeNode

/// The checks boot runs on state.db: a store from another schema, network or
/// network is refused before any DDL, and the normalized indexes must be
/// exactly what the journaled batches imply.
final class NodeStoreBootTests: XCTestCase {
    private func store(_ path: URL, genesis: String = NexusGenesis.expectedBlockHash) throws -> NodeStore {
        try NodeStore(databasePath: path, nexusGenesisCID: genesis)
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

    func testAStorageDirectoryCannotBeOpenedByTwoLiveNodes() async throws {
        let directory = temporaryDirectory()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: directory,
            privateKeyHex: String(repeating: "42", count: 32)
        )
        let first = try await NodeStorage.open(configuration: configuration)

        do {
            _ = try await NodeStorage.open(configuration: configuration)
            XCTFail("a second writer opened the live node's storage")
        } catch let error as NodeStorageError {
            XCTAssertEqual(error, .storageInUse)
        } catch {
            XCTFail("expected storageInUse, got \(error)")
        }

        // Keep the first storage alive through the conflicting open. Without
        // this use, ARC is free to release its process-lifetime lock early.
        XCTAssertEqual(first.configuration.storagePath, directory)
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

    func testMetadataRejectsWrongEpochAndRoot() throws {
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
        XCTAssertThrowsError(try store(path, genesis: "different-root")) { error in
            guard case NodeStoreError.wipeRequired = error else {
                return XCTFail("got \(error)")
            }
        }
    }

    func testNormalizedIndexAuditRequiresExactBatchDerivedRows() async throws {
        let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
        let store = try store(path)
        try await store.stageChainFacts([blockBatch("child")], volumeRoots: [], logID: "log")
        try await store.auditNormalizedIndexes()
        _ = try NodeSQLite(path: path.path).execute(
            "INSERT INTO admission_facts (chain_path, fact_id, payload) VALUES (?1, ?2, ?3)",
            params: [
                .text("Nexus"), .blob(Data("extra-id".utf8)),
                .blob(Data("extra".utf8)),
            ]
        )
        await expectCorrupt(store)
    }

    func testNormalizedIndexAuditRejectsMissingAcceptedBlockRow() async throws {
        let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
        let store = try store(path)
        try await store.stageChainFacts([blockBatch("accepted")], volumeRoots: [], logID: "log")
        try await store.auditNormalizedIndexes()
        _ = try NodeSQLite(path: path.path).execute(
            "DELETE FROM accepted_blocks WHERE block_cid = ?1", params: [.text("accepted")]
        )
        await expectCorrupt(store)
    }

    func testStreamCursorsCommitWithFactsAndSurviveReopen() async throws {
        let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
        let initial = try store(path)
        let cursors = [
            "peer-a": StreamCursor(logID: "remote-log", position: 17),
            "peer-b": StreamCursor(logID: "other-log", position: 4),
        ]
        try await initial.stageChainFacts(
            [blockBatch("accepted")], volumeRoots: [], logID: "local-log",
            cursors: cursors
        )

        let reopened = try store(path)
        let restored = try await reopened.chainCursors()
        XCTAssertEqual(restored, cursors)

        let advanced = StreamCursor(logID: "remote-log", position: 23)
        try await reopened.stageChainFacts(
            [], volumeRoots: [], logID: "local-log",
            cursors: ["peer-a": advanced]
        )
        let updated = try await reopened.chainCursors()
        XCTAssertEqual(updated["peer-a"], advanced)
    }

    /// A peer that does not run a level answers with no log; the core ends
    /// that cursor (empty log id). Persisting it must not fail the step:
    /// it crashed a node hosting a child that had no genesis yet.
    func testAnEndedCursorForAnUnhostedLevelPersistsAndSurvivesReopen() async throws {
        let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
        let child: ChainPath = ["Nexus", "testnet"]
        let ended = ["peer": StreamCursor(logID: "", position: 0)]
        try await store(path).stageNodeFacts([
            NodeFactBatch(path: child, facts: [], volumeRoots: [], cursors: ended),
        ], logID: "local-log")
        let restored = try await store(path).chainCursors(at: child)
        XCTAssertEqual(restored, ended)
    }

    func testWholeTreeStepRollsBackAtomically() async throws {
        let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
        let store = try store(path)
        do {
            try await store.stageNodeFacts([
                NodeFactBatch(
                    path: ["Nexus"], facts: [blockBatch("root")],
                    volumeRoots: [], cursors: [:]
                ),
                NodeFactBatch(
                    path: ["Nexus", "Alpha"], facts: [blockBatch("child")],
                    volumeRoots: [],
                    cursors: ["": StreamCursor(logID: "remote-log", position: 1)]
                ),
            ], logID: "local-log")
            XCTFail("expected malformed child cursor to abort the transaction")
        } catch NodeStoreError.invalidConfiguration {
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let staged = try await store.stagedImports()
        XCTAssertTrue(staged.isEmpty)
        let logID = try await store.chainLogID()
        XCTAssertNil(logID)
    }

    func testAuditIncludesHostedChildNormalizedIndexes() async throws {
        let directory = temporaryDirectory(create: true)
        let path = directory.appendingPathComponent("state.db")
        let store = try store(path)
        let alpha = ["Nexus", "Alpha"]
        try await store.stageChainFacts(
            [blockBatch("accepted")], volumeRoots: [], logID: "log", at: alpha
        )
        let database = try NodeSQLite(path: path.path)
        _ = try database.execute(
            "DELETE FROM accepted_blocks WHERE chain_path = ?1 AND block_cid = ?2",
            params: [.text("Nexus/Alpha"), .text("accepted")]
        )
        await expectCorrupt(store)
    }

    func testCorruptSavedChildProofFailsToLoad() throws {
        let directory = temporaryDirectory(create: true)
        let headers = try HeaderEvidenceStore(directory: directory)
        let database = try NodeSQLite(path: directory.appendingPathComponent(HeaderEvidenceStore.fileName).path)
        _ = try database.execute(
            "INSERT INTO child_proofs (chain, child, root, bytes) VALUES (?1, ?2, ?3, ?4)",
            params: [
                .text("Nexus/Alpha"), .text("child"), .text("root"),
                .blob(Data("not a proof".utf8)),
            ]
        )

        XCTAssertThrowsError(try headers.proofs()) { error in
            guard case NodeStoreError.corrupt = error else { return XCTFail("got \(error)") }
        }
    }

    func testSavedChildProofMustMatchItsIndex() throws {
        let directory = temporaryDirectory(create: true)
        let headers = try HeaderEvidenceStore(directory: directory)
        let database = try NodeSQLite(
            path: directory.appendingPathComponent(HeaderEvidenceStore.fileName).path
        )
        let proof = ChildBlockProof(
            rootCID: NexusGenesis.expectedBlockHash,
            directoryPath: ["Alpha"],
            entries: []
        )
        _ = try database.execute(
            "INSERT INTO child_proofs (chain, child, root, bytes) VALUES (?1, ?2, ?3, ?4)",
            params: [
                .text("Nexus/Alpha"), .text("child"), .text("wrong-root"),
                .blob(try proof.serialize()),
            ]
        )

        XCTAssertThrowsError(try headers.proofs()) { error in
            guard case NodeStoreError.corrupt = error else { return XCTFail("got \(error)") }
        }
    }

    func testHeaderEvidenceRejectsUnknownSchemaAndWrongNetwork() throws {
        let unknownDirectory = temporaryDirectory(create: true)
        let unknown = try NodeSQLite(
            path: unknownDirectory.appendingPathComponent(HeaderEvidenceStore.fileName).path
        )
        _ = try unknown.execute("CREATE TABLE old_headers (cid TEXT PRIMARY KEY)")
        XCTAssertThrowsError(try HeaderEvidenceStore(directory: unknownDirectory)) { error in
            guard case NodeStoreError.wipeRequired = error else { return XCTFail("got \(error)") }
        }

        let networkDirectory = temporaryDirectory(create: true)
        _ = try HeaderEvidenceStore(directory: networkDirectory)
        XCTAssertThrowsError(try HeaderEvidenceStore(
            directory: networkDirectory,
            nexusGenesisCID: "wrong-network"
        )) { error in
            guard case NodeStoreError.wipeRequired = error else { return XCTFail("got \(error)") }
        }
    }
}
