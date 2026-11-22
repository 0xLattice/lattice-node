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
                timestamp: 0
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

    /// Boot and a hot-hosted start read one level's facts in the order it
    /// took them, as one primary-key range with no sort: each batch's new
    /// facts in place, a fact staged again keeping its first seq, and a
    /// block fact staged again with a new fact read at its first place.
    func testALevelsFactsAreReadInStagedOrderByTheKey() async throws {
        let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
        let store = try store(path)
        let alpha: ChainPath = ["Nexus", "Alpha"]
        var expected: [ChainFact] = []
        for index in 0..<6 {
            let level = index.isMultiple(of: 2) ? ["Nexus"] : alpha
            try await store.stageChainFacts([blockBatch("block-\(index)")], logID: "log", at: level)
            if level == alpha { expected += blockBatch("block-\(index)").facts }
        }
        // Staged again with a new fact: only the new fact takes a new seq.
        let validation = ChainFact.validation(ChainValidationFact(blockHash: "block-1"))
        try await store.stageChainFacts(
            [BlockImportBatch(facts: blockBatch("block-1").facts + [validation])], logID: "log", at: alpha
        )
        expected.append(validation)
        // Staged again whole: no new seq.
        try await store.stageChainFacts([blockBatch("block-3")], logID: "log", at: alpha)

        let database = try NodeSQLite(path: path.path)
        _ = try database.execute("ANALYZE")
        let plan = try database.query(
            "EXPLAIN QUERY PLAN " + NodeStore.levelFactsSQL, params: [.text("Nexus/Alpha")]
        ).compactMap { $0["detail"]?.textValue }.joined(separator: "\n")
        XCTAssertTrue(plan.contains("PRIMARY KEY"), plan)
        XCTAssertFalse(plan.contains("TEMP B-TREE"), plan)
        let stored = try await store.storedFacts(at: alpha)
        XCTAssertEqual(stored.facts, expected)
        XCTAssertEqual(stored.batches, 4)
    }

    func testStreamCursorsCommitWithFactsAndSurviveReopen() async throws {
        let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
        let initial = try store(path)
        let cursors = [
            "peer-a": StreamCursor(logID: "remote-log", position: 17),
            "peer-b": StreamCursor(logID: "other-log", position: 4),
        ]
        try await initial.stageChainFacts(
            [blockBatch("accepted")], logID: "local-log",
            cursors: cursors
        )

        let reopened = try store(path)
        let restored = try await reopened.chainCursors()
        XCTAssertEqual(restored, cursors)

        let advanced = StreamCursor(logID: "remote-log", position: 23)
        try await reopened.stageChainFacts(
            [], logID: "local-log",
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
            NodeFactBatch(path: child, facts: [], cursors: ended),
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
                    cursors: [:]
                ),
                NodeFactBatch(
                    path: ["Nexus", "Alpha"], facts: [blockBatch("child")],
                    proofs: [alphaProof],
                    cursors: ["": StreamCursor(logID: "remote-log", position: 1)]
                ),
            ], logID: "local-log")
            XCTFail("expected malformed child cursor to abort the transaction")
        } catch NodeStoreError.invalidConfiguration {
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let held = try await store.hasStagedImports()
        XCTAssertFalse(held)
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
                cursors: [:]
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
        let other = try cid("other block")
        let roots = try [cid("root a"), cid("root b")].sorted()
        let (lowRoot, highRoot) = (roots[0], roots[1])
        let proofs = [highRoot, lowRoot].map {
            StoredProof(childCID: other, proof: ChildBlockProof(rootCID: $0, directoryPath: ["Alpha"], entries: []))
        } + [alphaProof]
        let store = try store(path)
        try await store.stageNodeFacts([
            NodeFactBatch(path: alpha, facts: [blockBatch("child")], proofs: proofs, cursors: [:]),
        ], logID: "local-log")
        // Past one query chunk, with blocks that have no proofs.
        let asked = (0..<600).map { "absent-\($0)" } + [other, alphaProof.childCID]
        let expected = [other: [lowRoot, highRoot], alphaProof.childCID: [alphaProof.proof.rootCID]]
        XCTAssertEqual(try store.savedProofs(at: alpha, for: asked).mapValues { $0.map(\.rootCID) }, expected)
        let reopened = try self.store(path)
        XCTAssertEqual(try reopened.savedProofs(at: alpha, for: asked).mapValues { $0.map(\.rootCID) }, expected)
        XCTAssertTrue(try reopened.savedProofs(at: ["Nexus", "Beta"], for: asked).isEmpty)
    }

    /// A saved-proof row that does not read back as its proof is left out
    /// and deleted, never a failure: the block's good proofs are still
    /// served, and a good copy written later is read back.
    func testACorruptSavedChildProofIsDeletedAndCanBeWrittenAgain() async throws {
        try await expectBadRowReplaced(entries: "not a cid")
    }

    func testASavedChildProofWhoseEntryIsNotHeldIsDeletedAndCanBeWrittenAgain() async throws {
        try await expectBadRowReplaced(entries: try cid("an entry nothing holds"))
    }

    private func expectBadRowReplaced(entries badEntries: String) async throws {
        let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
        let store = try store(path)
        let database = try NodeSQLite(path: path.path)
        let alpha: ChainPath = ["Nexus", "Alpha"]
        let (child, goodRoot, badRoot) = (try cid("child"), NexusGenesis.expectedBlockHash, try cid("bad root"))
        for (root, entries) in [(goodRoot, ""), (badRoot, badEntries)] {
            _ = try database.execute(
                "INSERT INTO child_proofs (chain, child, root, entries) VALUES (?1, ?2, ?3, ?4)",
                params: [.text("Nexus/Alpha"), .text(child), .text(root), .text(entries)]
            )
        }
        let saved = try store.savedProofs(at: alpha, for: [child])
        XCTAssertEqual(saved.mapValues { $0.map(\.rootCID) }, [child: [goodRoot]])
        try await eventually("the bad row is deleted") {
            try database.rows(from: "child_proofs", "SELECT root FROM child_proofs").map { try $0.text("root") } == [goodRoot]
        }

        let fresh = StoredProof(childCID: child, proof: ChildBlockProof(rootCID: badRoot, directoryPath: ["Alpha"], entries: []))
        try await store.stageNodeFacts([
            NodeFactBatch(path: alpha, facts: [blockBatch("child")], proofs: [fresh], cursors: [:]),
        ], logID: "local-log")
        let rewritten = try store.savedProofs(at: alpha, for: [child])
        XCTAssertEqual(rewritten.mapValues { $0.map(\.rootCID) }, [child: [goodRoot, badRoot].sorted()])
    }

    /// A query that fails is a store fault: it throws, never reads as absent.
    func testASavedProofQueryThatFailsThrows() throws {
        let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
        let store = try store(path)
        _ = try NodeSQLite(path: path.path).execute("DROP TABLE child_proofs")
        XCTAssertThrowsError(try store.savedProofs(at: ["Nexus", "Alpha"], for: [try cid("child")]))
    }

    /// A served page reads its proofs in chunks of 16, 32, 64, …: a proof on
    /// either side of each chunk edge is served with its block, and a root
    /// chain's page reads none.
    func testAServedPageReadsEveryProofAcrossChunkEdges() async throws {
        let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
        let store = try store(path)
        let alpha: ChainPath = ["Nexus", "Alpha"]
        let cids = try (0..<60).map { try cid("block \($0)") }
        let withProofs = [15, 16, 47, 48]
        try await store.stageNodeFacts([
            NodeFactBatch(
                path: alpha, facts: [blockBatch("child")],
                proofs: withProofs.map {
                    StoredProof(childCID: cids[$0], proof: ChildBlockProof(
                        rootCID: NexusGenesis.expectedBlockHash, directoryPath: ["Alpha"], entries: []
                    ))
                },
                cursors: [:]
            ),
        ], logID: "local-log")
        var page = SavedProofPage(store: store, path: alpha, cids: cids)
        let served = try cids.indices.filter { try !page.proofs(at: $0).isEmpty }
        XCTAssertEqual(served, withProofs)
        var rootPage = SavedProofPage(store: store, path: ["Nexus"], cids: cids)
        XCTAssertTrue(try cids.indices.allSatisfy { try rootPage.proofs(at: $0).isEmpty })
    }

    private func cid(_ seed: String) throws -> String {
        try HeaderImpl<PublicKey>(node: PublicKey(key: seed)).rawCID
    }
}
