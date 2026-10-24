import Foundation
import Ivy
import Lattice
import LatticeNodeCore
import XCTest
import cashew
@testable import LatticeBlockTree
@testable import LatticeNode

/// The checks boot runs on state.db: a store from another schema, network or
/// network is refused before any DDL.
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

    private var alphaProof: StoredProof {
        StoredProof(
            childCID: NexusGenesis.expectedBlockHash,
            proof: ChildBlockProof(rootCID: NexusGenesis.expectedBlockHash, directoryPath: ["Alpha"], entries: [])
        )
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

    /// Boot and a hot-hosted start read one level's journal in seq order,
    /// in pages through `admission_batches_by_level`: whatever the SQLite
    /// version's plan, a sort never holds more than one page of payloads.
    func testALevelsJournalIsReadInPagesInSeqOrder() async throws {
        let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
        let store = try store(path)
        let alphaRows = Int(NodeStore.levelBatchesPage) + 3
        var expected: [BlockImportBatch] = []
        for index in 0..<(2 * alphaRows) {
            let level = index.isMultiple(of: 2) ? ["Nexus"] : ["Nexus", "Alpha"]
            try await store.stageChainFacts(
                [blockBatch("block-\(index)")], volumeRoots: [], logID: "log", at: level
            )
            if level.count == 2 { expected.append(blockBatch("block-\(index)")) }
        }
        let database = try NodeSQLite(path: path.path)
        _ = try database.execute("ANALYZE")
        let plan = try database.query(
            "EXPLAIN QUERY PLAN " + NodeStore.levelBatchesSQL,
            params: [.text("Nexus/Alpha"), .int(0), .int(NodeStore.levelBatchesPage)]
        ).compactMap { $0["detail"]?.textValue }.joined(separator: "\n")
        XCTAssertTrue(plan.contains("admission_batches_by_level"), plan)
        XCTAssertTrue(plan.contains("seq>?"), plan)
        let batches = try await store.importBatches(at: ["Nexus", "Alpha"])
        XCTAssertEqual(batches, expected)
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
                    proofs: [alphaProof],
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
        XCTAssertTrue(try store.savedProofs(at: ["Nexus", "Alpha"], for: [alphaProof.childCID]).isEmpty)
    }

    func testAChildProofCommitsWithItsStepAndSurvivesReopen() async throws {
        let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
        let alpha: ChainPath = ["Nexus", "Alpha"]
        try await store(path).stageNodeFacts([
            NodeFactBatch(
                path: alpha, facts: [blockBatch("child")], proofs: [alphaProof],
                volumeRoots: [], cursors: [:]
            ),
        ], logID: "local-log")
        let saved = try store(path).savedProofs(at: alpha, for: [alphaProof.childCID])
        XCTAssertEqual(saved[alphaProof.childCID]?.map(\.rootCID), [alphaProof.proof.rootCID])
    }

    /// Saved proofs are read from the store, never held: a proof is served
    /// by the store that committed it at once, and by the reopened store
    /// after a restart, each block's ordered by root, across query chunks.
    func testSavedChildProofsAreReadFromTheStoreAtOnceAndAfterReopen() async throws {
        let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
        let alpha: ChainPath = ["Nexus", "Alpha"]
        func cid(_ seed: String) throws -> String { try HeaderImpl<PublicKey>(node: PublicKey(key: seed)).rawCID }
        let other = try cid("other block")
        let roots = try [cid("root a"), cid("root b")].sorted()
        let (lowRoot, highRoot) = (roots[0], roots[1])
        let proofs = [highRoot, lowRoot].map {
            StoredProof(childCID: other, proof: ChildBlockProof(rootCID: $0, directoryPath: ["Alpha"], entries: []))
        } + [alphaProof]
        let store = try store(path)
        try await store.stageNodeFacts([
            NodeFactBatch(path: alpha, facts: [blockBatch("child")], proofs: proofs, volumeRoots: [], cursors: [:]),
        ], logID: "local-log")
        // Past one query chunk, with blocks that have no proofs.
        let asked = (0..<600).map { "absent-\($0)" } + [other, alphaProof.childCID]
        let expected = [other: [lowRoot, highRoot], alphaProof.childCID: [alphaProof.proof.rootCID]]
        XCTAssertEqual(try store.savedProofs(at: alpha, for: asked).mapValues { $0.map(\.rootCID) }, expected)
        let reopened = try self.store(path)
        XCTAssertEqual(try reopened.savedProofs(at: alpha, for: asked).mapValues { $0.map(\.rootCID) }, expected)
        XCTAssertTrue(try reopened.savedProofs(at: ["Nexus", "Beta"], for: asked).isEmpty)
    }

    func testCorruptSavedChildProofFailsToLoad() throws {
        let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
        let store = try store(path)
        let database = try NodeSQLite(path: path.path)
        _ = try database.execute(
            "INSERT INTO child_proofs (chain, child, root, bytes) VALUES (?1, ?2, ?3, ?4)",
            params: [
                .text("Nexus/Alpha"), .text("child"), .text("root"),
                .blob(Data("not a proof".utf8)),
            ]
        )

        XCTAssertThrowsError(try store.savedProofs(at: ["Nexus", "Alpha"], for: ["child"])) { error in
            guard case NodeStoreError.corrupt = error else { return XCTFail("got \(error)") }
        }
    }

    func testSavedChildProofMustMatchItsIndex() throws {
        let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
        let store = try store(path)
        let database = try NodeSQLite(path: path.path)
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

        XCTAssertThrowsError(try store.savedProofs(at: ["Nexus", "Alpha"], for: ["child"])) { error in
            guard case NodeStoreError.corrupt = error else { return XCTFail("got \(error)") }
        }
    }
}
