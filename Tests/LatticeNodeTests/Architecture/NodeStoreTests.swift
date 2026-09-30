import Foundation
import Ivy
import XCTest
import UInt256
import VolumeBroker
import cashew
@testable import Lattice
@testable import LatticeBlockTree
@testable import LatticeNode

final class NodeStoreTests: XCTestCase {
    private let genesisCID = NexusGenesis.expectedBlockHash
    private let parentProcessKey = String(repeating: "a", count: 64)

    func testLegacyDatabaseFailsBeforeNewDDL() throws {
        let directory = temporaryDirectory(create: true)
        let path = directory.appendingPathComponent("state.db")
        let legacy = try NodeSQLite(path: path.path)
        try legacy.execute("CREATE TABLE legacy_state (value TEXT NOT NULL)")

        XCTAssertThrowsError(try makeStore(path: path)) { error in
            guard case NodeStoreError.wipeRequired = error else {
                return XCTFail("expected wipe-required error, got \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("entire configured storage directory"))
        }

        let tables = try legacy.query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
        ).compactMap { $0["name"]?.textValue }
        XCTAssertEqual(tables, ["legacy_state"])
    }

    func testMetadataRejectsWrongEpochRootAndPath() throws {
        let directory = temporaryDirectory(create: true)
        let path = directory.appendingPathComponent("state.db")
        _ = try makeStore(path: path)

        let database = try NodeSQLite(path: path.path)
        for epoch in [
            NodeStore.currentSchemaEpoch - 1,
            NodeStore.currentSchemaEpoch + 1,
        ] {
            try database.execute(
                "UPDATE node_metadata SET schema_epoch = ?1 WHERE singleton = 1",
                params: [.int(epoch)]
            )
            XCTAssertThrowsError(try makeStore(path: path)) { error in
                guard case NodeStoreError.wipeRequired = error else {
                    return XCTFail("expected wipe-required error, got \(error)")
                }
            }
            XCTAssertEqual(
                try database.query(
                    "SELECT schema_epoch FROM node_metadata WHERE singleton = 1"
                ).first?["schema_epoch"]?.intValue,
                epoch
            )
        }
        try database.execute(
            "UPDATE node_metadata SET schema_epoch = ?1 WHERE singleton = 1",
            params: [.int(NodeStore.currentSchemaEpoch)]
        )

        for attempt in [
            { try self.makeStore(path: path, genesisCID: "different-root") },
            { try self.makeStore(path: path, chainPath: ["Nexus", "Payments"]) },
        ] {
            XCTAssertThrowsError(try attempt()) { error in
                guard case NodeStoreError.wipeRequired = error else {
                    return XCTFail("expected wipe-required error, got \(error)")
                }
            }
        }
    }

    func testMatchingMetadataDoesNotRepairMissingTables() throws {
        let directory = temporaryDirectory(create: true)
        let path = directory.appendingPathComponent("state.db")
        _ = try makeStore(path: path)
        let database = try NodeSQLite(path: path.path)
        try database.execute("DROP TABLE issued_child_edges")

        XCTAssertThrowsError(try makeStore(path: path)) { error in
            guard case NodeStoreError.wipeRequired = error else {
                return XCTFail("expected wipe-required error, got \(error)")
            }
        }
    }

    func testCurrentSchemaHasNoInheritedWorkProjection() throws {
        let directory = temporaryDirectory(create: true)
        let path = directory.appendingPathComponent("state.db")
        _ = try makeStore(path: path)

        let tables = try NodeSQLite(path: path.path).query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
        ).compactMap { $0["name"]?.textValue }

        XCTAssertFalse(tables.contains("parent_coverage"))
        XCTAssertFalse(tables.contains("inherited_work_snapshot"))
        XCTAssertFalse(tables.contains("parent_work_sources"))
        XCTAssertFalse(tables.contains("parent_work_strengths"))
        XCTAssertFalse(tables.contains("parent_work_coverage"))
        XCTAssertFalse(tables.contains("parent_work_source"))
        XCTAssertFalse(tables.contains("parent_work_facts"))
        XCTAssertEqual(
            Set(try NodeSQLite(path: path.path).query(
                "PRAGMA table_info(local_mempool_transactions)"
            ).compactMap { $0["name"]?.textValue }),
            Set(["transaction_cid", "added_at"])
        )
    }

    func testAdmissionBatchReplayIsIdempotentAndFactConflictFailsClosed() async throws {
        let store = try makeStore()
        let original = blockBatch(postStateCID: "state-a")

        try await store.stage(original, volumeRoots: ["volume-z", "volume-a"])
        try await store.stage(original, volumeRoots: ["volume-a", "volume-z"])

        var staged = try await store.stagedImports()
        XCTAssertEqual(staged.count, 1)
        XCTAssertEqual(staged[0].batch, original)
        XCTAssertEqual(staged[0].volumeRoots, ["volume-a", "volume-z"])

        await XCTAssertThrowsErrorAsync(
            try await store.stage(
                blockBatch(postStateCID: "state-b"),
                volumeRoots: ["other-volume"]
            )
        ) { error in
            XCTAssertEqual(error as? NodeStoreError, .conflictingImportFact)
        }

        staged = try await store.stagedImports()
        XCTAssertEqual(staged.count, 1)
    }

    func testAdmissionBatchRejectsDifferentRootList() async throws {
        let store = try makeStore()
        let batch = blockBatch(postStateCID: "state")
        try await store.stage(batch, volumeRoots: ["volume-a"])

        await XCTAssertThrowsErrorAsync(
            try await store.stage(batch, volumeRoots: ["volume-b"])
        ) { error in
            XCTAssertEqual(error as? NodeStoreError, .conflictingImportBatch)
        }
        let staged = try await store.stagedImports()
        XCTAssertEqual(staged.count, 1)
    }

    func testAdmissionReplayFailsWhenNormalizedFactRowsAreMissing() async throws {
        let factsPath = temporaryDirectory(create: true).appendingPathComponent("state.db")
        let factsStore = try makeStore(path: factsPath)
        let batch = blockBatch(postStateCID: "state", blockHash: "child")
        try await factsStore.stage(batch, volumeRoots: [])
        try NodeSQLite(path: factsPath.path).execute("DELETE FROM admission_facts")
        await XCTAssertThrowsErrorAsync(
            try await factsStore.stage(batch, volumeRoots: [])
        ) { error in
            guard case NodeStoreError.corrupt = error else {
                return XCTFail("expected corruption, got \(error)")
            }
        }
    }

    func testAdmissionStagesHierarchyFactsWithItsBatch() async throws {
        let store = try makeStore()
        let carrier = try decode(ParentCarrierLink.self, json: """
            {"parentPath":["Nexus"],"carrierCID":"carrier","rootCID":"carrier"}
            """)
        let genesis = try decode(ParentGenesisLink.self, json: """
            {"parentPath":["Nexus"],"directory":"Payments","childGenesisCID":"child-genesis","parentStateCID":"parent-state"}
            """)
        let artifacts = ImportHierarchyArtifacts(
            carrierLink: carrier,
            carrierEvidence: nil,
            parentGenesisLinks: [genesis]
        )

        try await store.stage(
            blockBatch(postStateCID: "state", blockHash: "carrier"),
            volumeRoots: [],
            persistence: ImportPersistence(
                hierarchyArtifacts: artifacts
            )
        )

        let storedCarrier = try await store.issuedParentCarrierLink(
            carrierCID: "carrier",
            rootCID: "carrier"
        )
        let storedGenesis = try await store.issuedParentGenesisLink(
            directory: "Payments",
            childGenesisCID: "child-genesis",
            parentStateCID: "parent-state"
        )
        let staged = try await store.stagedImports()
        XCTAssertEqual(storedCarrier, carrier)
        XCTAssertEqual(storedGenesis, genesis)
        XCTAssertEqual(staged.count, 1)
    }

    func testNormalizedIndexAuditRejectsParentFactWithoutSource() async throws {
        let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
        let store = try makeStore(path: path)
        let carrier = try decode(ParentCarrierLink.self, json: """
            {"parentPath":["Nexus"],"carrierCID":"carrier","rootCID":"carrier"}
            """)
        try await store.stage(
            blockBatch(postStateCID: "state", blockHash: "carrier"),
            volumeRoots: [],
            persistence: ImportPersistence(
                hierarchyArtifacts: ImportHierarchyArtifacts(
                    carrierLink: carrier,
                    carrierEvidence: nil,
                    parentGenesisLinks: []
                )
            )
        )
        try await store.auditNormalizedIndexes()

        let payload = try JSONEncoder().encode(carrier)
        try NodeSQLite(path: path.path).execute(
            "INSERT INTO issued_parent_facts (kind, key_a, key_b, payload) VALUES ('carrier', 'extra', 'extra', ?1)",
            params: [.blob(payload)]
        )
        await XCTAssertThrowsErrorAsync(
            try await store.auditNormalizedIndexes()
        ) { error in
            guard case NodeStoreError.corrupt = error else {
                return XCTFail("expected corrupt parent-fact index, got \(error)")
            }
        }
    }

    func testEvidenceOnlyAdmissionStagesItsVerifiedCarrierLink() async throws {
        let store = try makeStore()
        let carrier = try decode(ParentCarrierLink.self, json: """
            {"parentPath":["Nexus"],"carrierCID":"carrier","rootCID":"carrier"}
            """)

        try await store.stage(
            BlockImportBatch(facts: [
                .work(ChainWorkFact(
                    blockHash: "carrier",
                    contribution: contribution(id: "grind", work: 7)
                )),
            ]),
            volumeRoots: [],
            persistence: ImportPersistence(
                hierarchyArtifacts: ImportHierarchyArtifacts(
                    carrierLink: carrier,
                    carrierEvidence: nil,
                    parentGenesisLinks: []
                )
            )
        )

        let stored = try await store.issuedParentCarrierLink(
            carrierCID: "carrier",
            rootCID: "carrier"
        )
        XCTAssertEqual(stored, carrier)
    }

    func testInvalidHierarchyArtifactRollsBackItsAdmissionBatch() async throws {
        let store = try makeStore()
        let outsideBatch = try decode(ParentCarrierLink.self, json: """
            {"parentPath":["Nexus"],"carrierCID":"outside","rootCID":"root"}
            """)

        await XCTAssertThrowsErrorAsync(
            try await store.stage(
                blockBatch(postStateCID: "state", blockHash: "carrier"),
                volumeRoots: [],
                persistence: ImportPersistence(
                    hierarchyArtifacts: ImportHierarchyArtifacts(
                        carrierLink: outsideBatch,
                        carrierEvidence: nil,
                        parentGenesisLinks: []
                    )
                )
            )
        ) { error in
            guard case NodeStoreError.invalidConfiguration = error else {
                return XCTFail("expected invalid hierarchy artifact, got \(error)")
            }
        }
        let staged = try await store.stagedImports()
        let carrier = try await store.issuedParentCarrierLink(
            carrierCID: "outside",
            rootCID: "root"
        )
        XCTAssertTrue(staged.isEmpty)
        XCTAssertNil(carrier)
    }

    func testNexusHierarchyArtifactCannotClaimAnotherRoot() async throws {
        let store = try makeStore()
        let carrier = try decode(ParentCarrierLink.self, json: """
            {"parentPath":["Nexus"],"carrierCID":"carrier","rootCID":"other-root"}
            """)

        await XCTAssertThrowsErrorAsync(
            try await store.stage(
                blockBatch(postStateCID: "state", blockHash: "carrier"),
                volumeRoots: [],
                persistence: ImportPersistence(
                    hierarchyArtifacts: ImportHierarchyArtifacts(
                        carrierLink: carrier,
                        carrierEvidence: nil,
                        parentGenesisLinks: []
                    )
                )
            )
        ) { error in
            guard case NodeStoreError.invalidConfiguration = error else {
                return XCTFail("expected invalid Nexus hierarchy artifact, got \(error)")
            }
        }
    }

    func testAcceptedLeafPageUsesAnImmutableAdmissionSnapshot() async throws {
        let store = try makeStore()
        try await store.stage(
            blockBatch(postStateCID: "root-a-state", blockHash: "root-a"),
            volumeRoots: []
        )
        try await store.stage(
            blockBatch(postStateCID: "root-b-state", blockHash: "root-b"),
            volumeRoots: []
        )
        let first = try await store.acceptedLeafPage(
            afterCID: nil,
            snapshotSequence: nil,
            limit: 1
        )
        XCTAssertEqual(first.blockCIDs, ["root-b"], "most recent first")

        try await store.stage(
            blockBatch(postStateCID: "root-c-state", blockHash: "root-c"),
            volumeRoots: []
        )
        // A cursored (legacy descent) page under the captured snapshot: CID
        // order after the cursor, never seeing root-c.
        let continued = try await store.acceptedLeafPage(
            afterCID: "root-a",
            snapshotSequence: first.snapshotSequence,
            limit: 1
        )
        let refreshed = try await store.acceptedLeafPage(
            afterCID: nil,
            snapshotSequence: nil,
            limit: 16
        )
        XCTAssertEqual(continued.blockCIDs, ["root-b"])
        XCTAssertEqual(refreshed.blockCIDs, ["root-c", "root-b", "root-a"])
    }

    /// The frontier page is served per authenticated peer request on the store
    /// actor: it must read the partial frontier index — on a PRE-EXISTING
    /// store too, whose open path runs no other DDL — never scan and
    /// temp-sort the accepted set.
    func testFrontierLeafPageUsesTheFrontierIndexOnAnExistingStore() async throws {
        let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
        var store: NodeStore? = try makeStore(path: path)
        try await store!.stage(
            blockBatch(postStateCID: "root-a-state", blockHash: "root-a"),
            volumeRoots: []
        )
        store = nil
        // A store file created without the index (an older layout).
        do {
            let older = try NodeSQLite(path: path.path)
            _ = try older.execute("DROP INDEX IF EXISTS accepted_blocks_frontier")
        }
        store = try makeStore(path: path)
        // A fresh connection sees the reopened store's schema.
        let database = try NodeSQLite(path: path.path)
        let indexes = try database.query(
            "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'accepted_blocks'"
        ).compactMap { $0["name"]?.textValue }
        let plan = try database.query(
            "EXPLAIN QUERY PLAN " + NodeStore.frontierLeafPageSQL,
            params: [.int(1), .int(64)]
        )
        let details = plan.compactMap { $0["detail"]?.textValue }
        XCTAssertTrue(
            details.contains { $0.contains("accepted_blocks_frontier") },
            "plan: \(details) indexes: \(indexes)"
        )
        XCTAssertFalse(
            details.contains { $0.contains("TEMP B-TREE") },
            "plan: \(details)"
        )
        XCTAssertNotNil(store)
    }

    /// The leaf flag is a derived index over the verified parent links: a
    /// disagreeing row is REPAIRED by the boot audit from those links, never
    /// treated as corruption that wipes the store.
    func testBootAuditRepairsAWrongLeafFlag() async throws {
        let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
        let store = try makeStore(path: path)
        try await store.stage(
            blockBatch(postStateCID: "root-state", blockHash: "root"),
            volumeRoots: []
        )
        try await store.stage(
            blockBatch(
                postStateCID: "child-state",
                blockHash: "child",
                parentBlockHash: "root",
                blockHeight: 1
            ),
            volumeRoots: []
        )
        let database = try NodeSQLite(path: path.path)
        // Both flags deliberately wrong.
        _ = try database.execute(
            "UPDATE accepted_blocks SET leaf = CASE block_cid WHEN 'root' THEN 1 ELSE 0 END"
        )
        try await store.auditNormalizedIndexes()
        var leaves: [String: Int64] = [:]
        for row in try database.query("SELECT block_cid, leaf FROM accepted_blocks") {
            leaves[try XCTUnwrap(row["block_cid"]?.textValue)] =
                try XCTUnwrap(row["leaf"]?.intValue)
        }
        XCTAssertEqual(leaves, ["root": 0, "child": 1])
    }

    /// Leaf-ness is maintained on insert in either order: a parent inserted
    /// after its child (a disconnected segment arriving out of order) is not
    /// a leaf, and inserting a child retires its parent's flag.
    func testAcceptedBlockLeafFlagsTrackChildrenInEitherInsertionOrder()
        async throws
    {
        let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
        let store = try makeStore(path: path)
        // In order: root, then child.
        try await store.stage(
            blockBatch(postStateCID: "root-state", blockHash: "root"),
            volumeRoots: []
        )
        try await store.stage(
            blockBatch(
                postStateCID: "child-state",
                blockHash: "child",
                parentBlockHash: "root",
                blockHeight: 1
            ),
            volumeRoots: []
        )
        // Out of order: grandchild before its parent.
        try await store.stage(
            blockBatch(
                postStateCID: "gc-state",
                blockHash: "grandchild",
                parentBlockHash: "middle",
                blockHeight: 3
            ),
            volumeRoots: []
        )
        try await store.stage(
            blockBatch(
                postStateCID: "middle-state",
                blockHash: "middle",
                parentBlockHash: "child",
                blockHeight: 2
            ),
            volumeRoots: []
        )
        let database = try NodeSQLite(path: path.path)
        var leaves: [String: Int64] = [:]
        for row in try database.query("SELECT block_cid, leaf FROM accepted_blocks") {
            leaves[try XCTUnwrap(row["block_cid"]?.textValue)] =
                try XCTUnwrap(row["leaf"]?.intValue)
        }
        XCTAssertEqual(
            leaves,
            ["root": 0, "child": 0, "middle": 0, "grandchild": 1]
        )
        try await store.auditNormalizedIndexes()
    }

    /// The maintained-flag frontier page is the same set the correlated
    /// NOT EXISTS leaf filter produces on a forked fixture.
    func testFrontierPageMatchesTheLeafFilterOnAForkedFixture() async throws {
        let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
        let store = try makeStore(path: path)
        try await store.stage(
            blockBatch(postStateCID: "r-state", blockHash: "r"),
            volumeRoots: []
        )
        for (cid, parent, height) in [
            ("a", "r", UInt64(1)), ("b", "r", 1), ("aa", "a", 2), ("ab", "a", 2),
            ("aaa", "aa", 3),
        ] {
            try await store.stage(
                blockBatch(
                    postStateCID: "\(cid)-state",
                    blockHash: cid,
                    parentBlockHash: parent,
                    blockHeight: height
                ),
                volumeRoots: []
            )
        }
        let page = try await store.acceptedLeafPage(
            afterCID: nil,
            snapshotSequence: nil,
            limit: 64
        )
        let database = try NodeSQLite(path: path.path)
        let filtered = try database.query(
            "SELECT block_cid FROM accepted_blocks AS block WHERE NOT EXISTS (SELECT 1 FROM accepted_blocks AS child WHERE child.parent_cid = block.block_cid) ORDER BY block.admission_seq DESC, block.block_cid DESC"
        ).compactMap { $0["block_cid"]?.textValue }
        XCTAssertEqual(page.blockCIDs, filtered)
        XCTAssertEqual(Set(page.blockCIDs), ["aaa", "ab", "b"])
    }

    /// The leaf set only grows and only recent forks can still contend, so
    /// the bounded frontier (cursor-less) page must hold the most recently
    /// ADMITTED leaves — never a lexicographic sample. The cursored page
    /// keeps the legacy CID-order contract the wire's cursor rule expects.
    func testAcceptedLeafPageIsMostRecentFirstAndCursorKeepsCIDOrder()
        async throws
    {
        let store = try makeStore()
        // Admission order deliberately disagrees with lexicographic order.
        for name in ["root-e", "root-a", "root-d", "root-b", "root-c"] {
            try await store.stage(
                blockBatch(postStateCID: "\(name)-state", blockHash: name),
                volumeRoots: []
            )
        }
        let frontier = try await store.acceptedLeafPage(
            afterCID: nil,
            snapshotSequence: nil,
            limit: 2
        )
        XCTAssertEqual(frontier.blockCIDs, ["root-c", "root-b"])
        let cursored = try await store.acceptedLeafPage(
            afterCID: "root-b",
            snapshotSequence: frontier.snapshotSequence,
            limit: 2
        )
        XCTAssertEqual(cursored.blockCIDs, ["root-c", "root-d"])
    }

    func testValidatedTierMarkerSurvivesRecovery() async throws {
        let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
        let store = try makeStore(path: path)
        try await store.stage(
            blockBatch(postStateCID: "root-state", blockHash: "root"),
            volumeRoots: []
        )
        try await store.stage(
            blockBatch(
                postStateCID: "child-state",
                blockHash: "child",
                parentBlockHash: "root",
                blockHeight: 1
            ),
            volumeRoots: [],
            persistence: ImportPersistence(
                status: .header
            )
        )
        let rootValidated = try await store.blockValidated("root")
        let childValidated = try await store.blockValidated("child")
        let unknownValidated = try await store.blockValidated("unknown")
        XCTAssertTrue(rootValidated)
        XCTAssertFalse(childValidated)
        XCTAssertFalse(unknownValidated)

        // A fresh store over the same durable file (crash recovery) must
        // reconstruct the identical validated set, and the tier must not
        // perturb the batch-derived index audit.
        let recovered = try makeStore(path: path)
        let recoveredRoot = try await recovered.blockValidated("root")
        let recoveredChild = try await recovered.blockValidated("child")
        XCTAssertTrue(recoveredRoot)
        XCTAssertFalse(recoveredChild)
        try await recovered.auditNormalizedIndexes()
    }

    func testPromoteValidatedFlipsMarkerOnlyAndSurvivesRecovery() async throws {
        let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
        let store = try makeStore(path: path)
        // A weighed child: enters the accepted index below the validated tier,
        // carrying the empty-stateDiff block fact.
        try await store.stage(
            blockBatch(postStateCID: "root-state", blockHash: "root"),
            volumeRoots: []
        )
        try await store.stage(
            blockBatch(
                postStateCID: "child-state",
                blockHash: "child",
                parentBlockHash: "root",
                blockHeight: 1
            ),
            volumeRoots: [],
            persistence: ImportPersistence(
                status: .header
            )
        )
        let weighedChild = try await store.blockValidated("child")
        XCTAssertFalse(weighedChild)
        var walkValidated = try await store.executedAndPinnedBlockCIDs()
        XCTAssertTrue(walkValidated.isEmpty)

        // Validate-on-candidacy promotes it: the durable marker flips to the
        // walk-validated tier WITHOUT rewriting admission_facts. Retaining the
        // materialized state is the caller's owner pin, not this marker.
        try await store.promoteValidated(blockCID: "child")
        let validatedChild = try await store.blockValidated("child")
        XCTAssertTrue(validatedChild)
        walkValidated = try await store.executedAndPinnedBlockCIDs()
        XCTAssertEqual(
            walkValidated, ["child"],
            "the eager root is validated but not walk-validated"
        )

        // Idempotent: a re-validation (reorg re-projection / crash retry) is a
        // no-op and never throws a fact conflict.
        try await store.promoteValidated(blockCID: "child")
        let revalidatedChild = try await store.blockValidated("child")
        XCTAssertTrue(revalidatedChild)

        // Crash recovery: a fresh store over the same durable file keeps the
        // tier, and the tier does not perturb the batch-derived index audit.
        let recovered = try makeStore(path: path)
        let recoveredChildValidated = try await recovered.blockValidated("child")
        XCTAssertTrue(recoveredChildValidated)
        walkValidated = try await recovered.executedAndPinnedBlockCIDs()
        XCTAssertEqual(walkValidated, ["child"])
        try await recovered.auditNormalizedIndexes()

        // Boot reconciliation returns a marker whose pin is gone to weighed.
        try await recovered.demoteValidated(blockCID: "child")
        let demotedChild = try await recovered.blockValidated("child")
        XCTAssertFalse(demotedChild)
        walkValidated = try await recovered.executedAndPinnedBlockCIDs()
        XCTAssertTrue(walkValidated.isEmpty)
        let rootStillValidated = try await recovered.blockValidated("root")
        XCTAssertTrue(rootStillValidated)
    }

    func testNormalizedIndexAuditRequiresExactBatchDerivedRows() async throws {
        let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
        let store = try makeStore(path: path)
        try await store.stage(
            blockBatch(postStateCID: "state", blockHash: "child"),
            volumeRoots: []
        )
        try await store.auditNormalizedIndexes()

        try NodeSQLite(path: path.path).execute(
            "INSERT INTO admission_facts (fact_id, payload) VALUES (?1, ?2)",
            params: [.blob(Data("extra-id".utf8)), .blob(Data("extra".utf8))]
        )
        await XCTAssertThrowsErrorAsync(
            try await store.auditNormalizedIndexes()
        ) { error in
            guard case NodeStoreError.corrupt = error else {
                return XCTFail("expected corruption, got \(error)")
            }
        }
    }

    func testNormalizedIndexAuditRejectsMissingAcceptedBlockRow() async throws {
        let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
        let store = try makeStore(path: path)
        try await store.stage(
            blockBatch(postStateCID: "state", blockHash: "accepted"),
            volumeRoots: []
        )
        try await store.auditNormalizedIndexes()

        try NodeSQLite(path: path.path).execute(
            "DELETE FROM accepted_blocks WHERE block_cid = ?1",
            params: [.text("accepted")]
        )
        await XCTAssertThrowsErrorAsync(
            try await store.auditNormalizedIndexes()
        ) { error in
            guard case NodeStoreError.corrupt = error else {
                return XCTFail("expected corruption, got \(error)")
            }
        }
    }

    func testIssuedParentFactsAreDurable() async throws {
        let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
        var store: NodeStore? = try makeStore(path: path)
        let carrier = try decode(ParentCarrierLink.self, json: """
            {"parentPath":["Nexus"],"carrierCID":"carrier","rootCID":"carrier"}
            """)
        let genesis = try decode(ParentGenesisLink.self, json: """
            {"parentPath":["Nexus"],"directory":"Child","childGenesisCID":"genesis","parentStateCID":"parent-state"}
            """)

        try await store!.stage(
            blockBatch(postStateCID: "state", blockHash: "carrier"),
            volumeRoots: [],
            persistence: ImportPersistence(
                hierarchyArtifacts: ImportHierarchyArtifacts(
                    carrierLink: carrier,
                    carrierEvidence: nil,
                    parentGenesisLinks: [genesis]
                )
            )
        )
        store = nil
        store = try makeStore(path: path)

        let storedCarrier = try await store!.issuedParentCarrierLink(
            carrierCID: "carrier",
            rootCID: "carrier"
        )
        let storedGenesis = try await store!.issuedParentGenesisLink(
            directory: "Child",
            childGenesisCID: "genesis",
            parentStateCID: "parent-state"
        )
        XCTAssertEqual(storedCarrier, carrier)
        XCTAssertEqual(storedGenesis, genesis)
    }

    func testCompetingGenesisFactsShareDeploymentStateWithoutCollision()
        async throws
    {
        let store = try makeStore()
        let state = "shared-parent-state"
        for (carrierCID, childCID) in [
            ("carrier-a", "child-a"),
            ("carrier-b", "child-b"),
        ] {
            let carrier = try decode(ParentCarrierLink.self, json: """
                {"parentPath":["Nexus"],"carrierCID":"\(carrierCID)","rootCID":"\(carrierCID)"}
                """)
            let genesis = try decode(ParentGenesisLink.self, json: """
                {"parentPath":["Nexus"],"directory":"Child","childGenesisCID":"\(childCID)","parentStateCID":"\(state)"}
                """)
            try await store.stage(
                blockBatch(postStateCID: "state", blockHash: carrierCID),
                volumeRoots: [],
                persistence: ImportPersistence(
                    hierarchyArtifacts: ImportHierarchyArtifacts(
                        carrierLink: carrier,
                        carrierEvidence: nil,
                        parentGenesisLinks: [genesis]
                    )
                )
            )
        }

        for childCID in ["child-a", "child-b"] {
            let link = try await store.issuedParentGenesisLink(
                directory: "Child",
                childGenesisCID: childCID,
                parentStateCID: state
            )
            XCTAssertEqual(link?.childGenesisCID, childCID)
        }
    }

    func testUnacceptedCarrierCannotAuthorizeGenesis() async throws {
        let store = try makeStore()
        let carrierCID = testCID("unaccepted-genesis-carrier")
        let carrier = try decode(ParentCarrierLink.self, json: """
            {"parentPath":["Nexus"],"carrierCID":"\(carrierCID)","rootCID":"\(carrierCID)"}
            """)
        let genesis = try decode(ParentGenesisLink.self, json: """
            {"parentPath":["Nexus"],"directory":"Child","childGenesisCID":"child","parentStateCID":"state"}
            """)

        await XCTAssertThrowsErrorAsync(
            try await store.persistIssuedHierarchyArtifacts(
                ImportHierarchyArtifacts(
                    carrierLink: carrier,
                    carrierEvidence: nil,
                    parentGenesisLinks: [genesis]
                )
            )
        ) { error in
            guard case NodeStoreError.invalidConfiguration = error else {
                return XCTFail("expected accepted-parent guard, got \(error)")
            }
        }
    }

    func testDisconnectedAcceptedCarrierCannotAuthorizeGenesis()
        async throws
    {
        let store = try makeStore()
        let rootCID = testCID("connected-root")
        let missingCID = testCID("missing-parent")
        let carrierCID = testCID("disconnected-carrier")
        try await store.stage(
            blockBatch(postStateCID: "root-state", blockHash: rootCID),
            volumeRoots: []
        )
        try await store.stage(
            blockBatch(
                postStateCID: "orphan-state",
                blockHash: carrierCID,
                parentBlockHash: missingCID,
                blockHeight: 2
            ),
            volumeRoots: []
        )
        let carrier = try decode(ParentCarrierLink.self, json: """
            {"parentPath":["Nexus"],"carrierCID":"\(carrierCID)","rootCID":"\(carrierCID)"}
            """)
        let genesis = try decode(ParentGenesisLink.self, json: """
            {"parentPath":["Nexus"],"directory":"Child","childGenesisCID":"child","parentStateCID":"state"}
            """)

        await XCTAssertThrowsErrorAsync(
            try await store.persistIssuedHierarchyArtifacts(
                ImportHierarchyArtifacts(
                    carrierLink: carrier,
                    carrierEvidence: nil,
                    parentGenesisLinks: [genesis]
                )
            )
        ) { error in
            guard case NodeStoreError.invalidConfiguration = error else {
                return XCTFail("expected connected-parent guard, got \(error)")
            }
        }
        try await store.persistIssuedHierarchyArtifacts(
            ImportHierarchyArtifacts(
                carrierLink: carrier,
                carrierEvidence: nil,
                parentGenesisLinks: []
            )
        )
        let storedCarrier = try await store.issuedParentCarrierLink(
            carrierCID: carrierCID,
            rootCID: carrierCID
        )
        XCTAssertEqual(storedCarrier, carrier)
        let storedGenesis = try await store.issuedParentGenesisLink(
            directory: "Child",
            childGenesisCID: "child",
            parentStateCID: "state"
        )
        XCTAssertNil(storedGenesis)
        try await store.auditNormalizedIndexes()
    }


    func testIssuedCarrierEvidencePersistsProofAndLinkTogether() async throws {
        let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
        let store = try makeStore(path: path, chainPath: ["Nexus", "Child"])
        let fixture = try await childProofFixture()
        let link = try decode(ParentCarrierLink.self, json: """
            {"parentPath":["Nexus","Child"],"carrierCID":"\(fixture.childCID)","rootCID":"\(fixture.first.rootCID)"}
            """)

        try await store.persistIssuedHierarchyArtifacts(
            ImportHierarchyArtifacts(
                carrierLink: link,
                carrierEvidence: ImportCarrierEvidence(
                    proof: fixture.first,
                    childCID: fixture.childCID
                ),
                parentGenesisLinks: []
            )
        )

        let storedLink = try await store.issuedParentCarrierLink(
            carrierCID: fixture.childCID,
            rootCID: fixture.first.rootCID
        )
        XCTAssertEqual(storedLink, link)
        let proofValue = try await store.incomingCarrierEvidence(
            childCID: fixture.childCID,
            directory: "Child",
            rootCID: fixture.first.rootCID
        )?.proof
        let proof = try XCTUnwrap(proofValue)
        XCTAssertEqual(try proof.serialize(), try fixture.first.serialize())
        let incomingCoverage = try await store
            .incomingParentCarrierBlocksByChildBlock()
        XCTAssertEqual(Set(incomingCoverage.keys), [fixture.childCID])
    }

    /// The re-ask list and the local location binding (Lattice §9.10) are
    /// drawn from carrier edges of blocks this chain ACCEPTED: an edge recorded
    /// for a block that was never accepted — a merged-mining round whose root
    /// missed this chain's target — names no committer here, and one committer
    /// is listed once, newest first.
    func testIncomingCarriersCoverOnlyAcceptedBlocks() async throws {
        let store = try makeStore(chainPath: ["Nexus", "Child"])
        let fixture = try await childProofFixture()
        for proof in [fixture.first, fixture.second] {
            try await store.persistIssuedHierarchyArtifacts(
                ImportHierarchyArtifacts(
                    carrierLink: try decode(ParentCarrierLink.self, json: """
                        {"parentPath":["Nexus","Child"],"carrierCID":"\(fixture.childCID)","rootCID":"\(proof.rootCID)"}
                        """),
                    carrierEvidence: ImportCarrierEvidence(
                        proof: proof,
                        childCID: fixture.childCID
                    ),
                    parentGenesisLinks: []
                )
            )
        }
        let derivedFirst = await DirectChildEdge.derive(from: fixture.first)
        let derivedSecond = await DirectChildEdge.derive(from: fixture.second)
        let firstEdge = try XCTUnwrap(derivedFirst)
        let secondEdge = try XCTUnwrap(derivedSecond)

        // Evidence recorded, block not accepted: nothing to re-ask, no location.
        let before = try await store.incomingCarriers(limit: 256)
        XCTAssertEqual(before, [], "a carrier of a block this chain did not accept commits nothing here")
        let unbound = try await store.incomingCarrierChildBlock(carrier: firstEdge.parentCarrierCID)
        XCTAssertNil(unbound)

        // The block is accepted: both carriers are committers, newest edge first,
        // each once, and both bind to this chain's block.
        try await store.stage(
            blockBatch(postStateCID: "child-state", blockHash: fixture.childCID),
            volumeRoots: []
        )
        let after = try await store.incomingCarriers(limit: 256)
        XCTAssertEqual(after, [secondEdge.parentCarrierCID, firstEdge.parentCarrierCID])
        XCTAssertEqual(Set(after).count, after.count, "distinct")
        let bound = try await store.incomingCarrierChildBlock(carrier: firstEdge.parentCarrierCID)
        XCTAssertEqual(bound, fixture.childCID)
        let limited = try await store.incomingCarriers(limit: 1)
        XCTAssertEqual(limited, [secondEdge.parentCarrierCID], "the bound counts committers, newest first")
    }

    func testIncomingCarrierProofRootsPageAcrossContexts() async throws {
        let store = try makeStore(chainPath: ["Nexus", "Child"])
        let fixture = try await childProofFixture()
        for proof in [fixture.first, fixture.second] {
            try await store.persistIssuedHierarchyArtifacts(
                ImportHierarchyArtifacts(
                    carrierLink: try decode(ParentCarrierLink.self, json: """
                        {"parentPath":["Nexus","Child"],"carrierCID":"\(fixture.childCID)","rootCID":"\(proof.rootCID)"}
                        """),
                    carrierEvidence: ImportCarrierEvidence(
                        proof: proof,
                        childCID: fixture.childCID
                    ),
                    parentGenesisLinks: []
                )
            )
        }

        let firstPage = try await store.incomingCarrierProofRoots(
            childCID: fixture.childCID,
            directory: "Child",
            afterRootCID: nil,
            limit: 1
        )
        let secondPage = try await store.incomingCarrierProofRoots(
            childCID: fixture.childCID,
            directory: "Child",
            afterRootCID: try XCTUnwrap(firstPage.last),
            limit: 1
        )
        let exhaustedPage = try await store.incomingCarrierProofRoots(
            childCID: fixture.childCID,
            directory: "Child",
            afterRootCID: try XCTUnwrap(secondPage.last),
            limit: 1
        )
        XCTAssertEqual(
            firstPage + secondPage,
            [fixture.first.rootCID, fixture.second.rootCID].sorted()
        )
        XCTAssertTrue(exhaustedPage.isEmpty)
    }

    func testAdmissionStorageRecordsOnlyActualVolumeRoots() async throws {
        let broker = MemoryBroker()
        let admission = NodeImportStorage(storage: broker)
        let node = PublicKey(key: "actual-volume")
        let header = try HeaderImpl<PublicKey>(node: node)
        let root = header.rawCID
        try await admission.store(volume: SerializedVolume(
            root: root,
            entries: [root: try header.mapToData()]
        ))

        let recordedRoots = await admission.takeStoredVolumeRoots()
        let drainedRoots = await admission.takeStoredVolumeRoots()
        XCTAssertEqual(recordedRoots, [root])
        XCTAssertTrue(drainedRoots.isEmpty)
        let hasVolume = await broker.hasVolume(root: root)
        XCTAssertTrue(hasVolume)
    }

    /// Establishes: NODE-STORAGE-002.g
    func testTouchingAnOfferMakesItTheNewestAcrossReopen() async throws {
        let directory = temporaryDirectory(create: true)
        let path = directory.appendingPathComponent("state.db")
        let broker = try DiskBroker(
            path: directory.appendingPathComponent("volumes.db").path
        )
        let volumes = try ["touched-a", "touched-b", "touched-c"].map { seed in
            try VolumeImpl<PublicKey>(node: PublicKey(key: seed))
        }
        for volume in volumes { try await volume.store(storer: broker) }
        let (a, b, c) = (volumes[0].rawCID, volumes[1].rawCID, volumes[2].rawCID)

        var store: NodeStore? = try makeStore(path: path, broker: broker)
        try await store!.persistContextualCandidateRoots(candidateCID: a, roots: [a], capacity: 2)
        try await store!.persistContextualCandidateRoots(candidateCID: b, roots: [b], capacity: 2)
        // The path production takes when a template carries an offer again.
        let touched = try await store!.touchContextualCandidate(candidateCID: a)
        XCTAssertTrue(touched)

        store = nil
        store = try makeStore(path: path, broker: broker)
        try await store!.persistContextualCandidateRoots(candidateCID: c, roots: [c], capacity: 2)
        let retained = try await store!.contextualCandidateVolumeRoots()
        XCTAssertEqual(Set(retained), Set([a, c]), "the touched offer outlived the untouched one")
    }

    /// Establishes: NODE-STORAGE-002.g, NODE-STORAGE-002.i, NODE-STORAGE-002.p
    func testContextualCandidateRootsUseDurableLRUReplacement()
        async throws
    {
        let directory = temporaryDirectory(create: true)
        let path = directory.appendingPathComponent("state.db")
        let broker = try DiskBroker(
            path: directory.appendingPathComponent("volumes.db").path
        )
        let storer = broker
        let volumes = try ["a", "b", "c", "d", "shared"].map { seed in
            try VolumeImpl<PublicKey>(node: PublicKey(key: seed))
        }
        for volume in volumes { try await volume.store(storer: storer) }
        let a = volumes[0].rawCID
        let b = volumes[1].rawCID
        let c = volumes[2].rawCID
        let d = volumes[3].rawCID
        let shared = volumes[4].rawCID

        var store: NodeStore? = try makeStore(path: path, broker: broker)
        try await store!.persistContextualCandidateRoots(
            candidateCID: a,
            roots: [shared, a],
            capacity: 2
        )
        try await store!.persistContextualCandidateRoots(
            candidateCID: b,
            roots: [b, shared],
            capacity: 2
        )
        // A reused child CID remains as recent as the newest parent template
        // that references it without duplicating its retained roots.
        try await store!.persistContextualCandidateRoots(
            candidateCID: a,
            roots: [a, shared],
            capacity: 2
        )
        try await store!.persistContextualCandidateRoots(
            candidateCID: c,
            roots: [c, shared],
            capacity: 2
        )
        let retainedBeforeReopen = try await store!
            .contextualCandidateVolumeRoots()
        XCTAssertEqual(Set(retainedBeforeReopen), Set([a, c, shared]))
        // Live, before any reopen rebuilds the counts: b's eviction released
        // its own pin on the shared root, and a and c still hold theirs.
        _ = try await broker.evictUnpinned(graceSeconds: 0)
        let sharedWhileLive = await broker.fetchVolumeLocal(root: shared)
        XCTAssertNotNil(sharedWhileLive, "b's eviction left a and c's shared root owned")
        try await volumes[3].store(storer: storer)

        store = nil
        store = try makeStore(path: path, broker: broker)
        let recoveredRoots = try await store!.contextualCandidateVolumeRoots()
        try await broker.unpinAll(owner: "test:contextual-candidates")
        try await broker.pinBatch(
            roots: recoveredRoots,
            owner: "test:contextual-candidates"
        )
        try await store!.persistContextualCandidateRoots(
            candidateCID: d,
            roots: [d],
            capacity: 2
        )
        let retainedAfterReopen = try await store!
            .contextualCandidateVolumeRoots()
        XCTAssertEqual(Set(retainedAfterReopen), Set([c, d, shared]))
        _ = try await broker.evictUnpinned(graceSeconds: 0)
        let volumeA = await broker.fetchVolumeLocal(root: a)
        let volumeB = await broker.fetchVolumeLocal(root: b)
        let volumeC = await broker.fetchVolumeLocal(root: c)
        let volumeD = await broker.fetchVolumeLocal(root: d)
        let sharedVolume = await broker.fetchVolumeLocal(root: shared)
        XCTAssertNil(volumeA)
        XCTAssertNil(volumeB)
        XCTAssertNotNil(volumeC)
        XCTAssertNotNil(volumeD)
        XCTAssertNotNil(sharedVolume)

        let removedWithoutAdmission = try await store!
            .removeContextualCandidateIfAdmitted(candidateCID: c)
        XCTAssertFalse(removedWithoutAdmission)
        try await store!.stage(
            blockBatch(postStateCID: "state-c", blockHash: c),
            volumeRoots: [c, shared]
        )
        let removedAfterAdmission = try await store!
            .removeContextualCandidateIfAdmitted(candidateCID: c)
        XCTAssertTrue(removedAfterAdmission)
        let rootsAfterAdmission = try await store!
            .contextualCandidateVolumeRoots()
        XCTAssertEqual(Set(rootsAfterAdmission), Set([d]))
        _ = try await broker.evictUnpinned(graceSeconds: 0)
        let retainedD = await broker.fetchVolumeLocal(root: d)
        let retainedShared = await broker.fetchVolumeLocal(root: shared)
        XCTAssertNotNil(retainedD)
        XCTAssertNil(retainedShared)
    }


    /// Of three offers, the one whose admission batch owns only some of its
    /// roots keeps its row and pins; the one whose batch owns every root is
    /// released, and one with no admission is not.
    /// Establishes: NODE-STORAGE-002.k
    func testAdmissionReleasesAnOfferOnlyOnceItsBatchOwnsEveryRoot()
        async throws {
        let directory = temporaryDirectory(create: true)
        let broker = try DiskBroker(
            path: directory.appendingPathComponent("volumes.db").path
        )
        let store = try makeStore(
            path: directory.appendingPathComponent("state.db"),
            broker: broker
        )
        var offers: [[String]] = []
        for name in ["partly-owned", "fully-owned", "unadmitted"] {
            let volumes = try ["\(name)", "\(name)-body", "\(name)-state"].map {
                try VolumeImpl<PublicKey>(node: PublicKey(key: $0))
            }
            for volume in volumes { try await volume.store(storer: broker) }
            let roots = volumes.map(\.rawCID)
            try await store.persistContextualCandidateRoots(
                candidateCID: roots[0],
                roots: roots,
                capacity: 16
            )
            offers.append(roots)
        }
        let (partly, fully, unadmitted) = (offers[0], offers[1], offers[2])
        try await store.stage(
            blockBatch(postStateCID: "partly-state", blockHash: partly[0]),
            volumeRoots: Array(partly.prefix(2))
        )
        try await store.stage(
            blockBatch(postStateCID: "fully-state", blockHash: fully[0]),
            volumeRoots: fully
        )

        let releasedPartly = try await store.removeContextualCandidateIfAdmitted(
            candidateCID: partly[0]
        )
        let releasedFully = try await store.removeContextualCandidateIfAdmitted(
            candidateCID: fully[0]
        )
        let releasedUnadmitted = try await store
            .removeContextualCandidateIfAdmitted(candidateCID: unadmitted[0])
        XCTAssertFalse(releasedPartly, "released before the batch owned every root")
        XCTAssertTrue(releasedFully)
        XCTAssertFalse(releasedUnadmitted)

        let indexed = try await store.contextualCandidateVolumeRoots()
        XCTAssertEqual(Set(indexed), Set(partly + unadmitted))
        for root in partly + unadmitted {
            let owners = await broker.owners(root: root)
            XCTAssertEqual(owners, ["test:contextual-candidates"], root)
        }
        for root in fully {
            let owners = await broker.owners(root: root)
            XCTAssertTrue(owners.isEmpty, root)
        }
    }

    /// Offers are this chain's own retention: the budget keeps the newest
    /// and drops the oldest whole — row and pinned roots together — so a
    /// child that rebuilds often cannot pin without bound, and an offer the
    /// parent never carried costs nothing for long.
    /// Establishes: NODE-STORAGE-002.i
    func testOfferBudgetEvictsTheOldestOfferWhole() async throws {
        let directory = temporaryDirectory(create: true)
        let broker = try DiskBroker(
            path: directory.appendingPathComponent("volumes.db").path
        )
        let store = try makeStore(
            path: directory.appendingPathComponent("state.db"),
            broker: broker
        )
        // Offered in DESCENDING CID order, so the oldest offer has the
        // largest CID: evicting by CID instead of by age picks the wrong one.
        let offers = try (0..<3).map { index in
            try VolumeImpl<PublicKey>(node: PublicKey(key: "offer-\(index)"))
        }.sorted { $0.rawCID > $1.rawCID }
        for offer in offers {
            try await offer.store(storer: broker)
            try await store.persistContextualCandidateRoots(
                candidateCID: offer.rawCID,
                roots: [offer.rawCID],
                capacity: 2
            )
        }
        let retained = try await store.contextualCandidateVolumeRoots()
        XCTAssertEqual(Set(retained), Set([offers[1].rawCID, offers[2].rawCID]))
        _ = try await broker.evictUnpinned(graceSeconds: 0)
        let evicted = await broker.fetchVolumeLocal(root: offers[0].rawCID)
        XCTAssertNil(evicted, "the oldest offer's body is released with its row")
        try await store.auditNormalizedIndexes()
        // Re-offering the same candidate is a touch, not a second row.
        try await offers[2].store(storer: broker)
        try await store.persistContextualCandidateRoots(
            candidateCID: offers[2].rawCID,
            roots: [offers[2].rawCID],
            capacity: 2
        )
        let afterTouch = try await store.contextualCandidateVolumeRoots()
        XCTAssertEqual(Set(afterTouch), Set([offers[1].rawCID, offers[2].rawCID]))
    }



    // MARK: - Storage ordering and ownership (NODE-STORAGE-002)

    /// A store that throws records nothing: of two Volumes, only the one
    /// whose store returned is a root the admission may retain and stage.
    /// Establishes: NODE-STORAGE-002.v
    func testImportStorageRecordsARootOnlyAfterItsStoreReturns() async throws {
        let directory = temporaryDirectory(create: true)
        let broker = FaultInjectingBroker(broker: try DiskBroker(
            path: directory.appendingPathComponent("volumes.db").path
        ))
        let storage = NodeImportStorage(storage: broker)
        let volumes = try ["recorded-first", "refused-second"].map {
            try VolumeImpl<PublicKey>(node: PublicKey(key: $0))
        }
        await broker.failNext(.store(root: volumes[1].rawCID))

        try await volumes[0].store(storer: storage)
        do {
            try await volumes[1].store(storer: storage)
            XCTFail("the injected store fault did not surface")
        } catch {
            XCTAssertEqual(
                error as? InjectedBrokerFault,
                InjectedBrokerFault(step: .store(root: volumes[1].rawCID))
            )
        }

        let recorded = await storage.takeStoredVolumeRoots()
        XCTAssertEqual(recorded, [volumes[0].rawCID])
    }

    /// Issued carrier evidence (`persistIssuedHierarchyArtifacts`): a fault
    /// at its store or its issued retention writes no evidence row; while
    /// the retention merge is in flight, no row exists yet.
    /// Establishes: NODE-STORAGE-002.b
    func testIssuedCarrierEvidenceIsWrittenOnlyAfterItsVolumeIsStoredAndRetained()
        async throws {
        let fixture = try await childProofFixture()
        let child = try await childEvidenceStore(fixture)
        let link = try decode(ParentCarrierLink.self, json: """
            {"parentPath":["Nexus","Child"],"carrierCID":"\(fixture.childCID)","rootCID":"\(fixture.first.rootCID)"}
            """)
        let artifacts = ImportHierarchyArtifacts(
            carrierLink: link,
            carrierEvidence: ImportCarrierEvidence(
                proof: fixture.first,
                childCID: fixture.childCID
            ),
            parentGenesisLinks: []
        )

        for step in [
            BrokerStep.store(root: child.attachment.rawCID),
            .merge(scope: "test:issued-hierarchy"),
        ] {
            await child.broker.failNext(step)
            do {
                try await child.store.persistIssuedHierarchyArtifacts(artifacts)
                XCTFail("the fault at \(step) did not surface")
            } catch {
                XCTAssertEqual(
                    error as? InjectedBrokerFault,
                    InjectedBrokerFault(step: step)
                )
            }
            try await assertNoEvidenceRow(child, fixture: fixture, after: step)
            let issuedLink = try await child.store.issuedParentCarrierLink(
                carrierCID: fixture.childCID,
                rootCID: fixture.first.rootCID
            )
            XCTAssertNil(issuedLink, "a carrier link outran its evidence at \(step)")
        }

        let merge = BrokerStep.merge(scope: "test:issued-hierarchy")
        await child.broker.parkNext(merge)
        let issuing = Task {
            try await child.store.persistIssuedHierarchyArtifacts(artifacts)
        }
        try await child.broker.waitUntilParked(merge)
        try await assertNoEvidenceRow(child, fixture: fixture, after: merge)
        let linkWhileParked = try await child.store.issuedParentCarrierLink(
            carrierCID: fixture.childCID,
            rootCID: fixture.first.rootCID
        )
        XCTAssertNil(linkWhileParked, "a carrier link outran its retention")
        await child.broker.release(merge)
        try await issuing.value

        let evidence = try await child.store.incomingCarrierEvidence(
            childCID: fixture.childCID,
            directory: "Child",
            rootCID: fixture.first.rootCID
        )
        XCTAssertEqual(evidence?.attachmentCID, child.attachment.rawCID)
        let issued = try await child.disk.retainedRoots(
            scope: "test:issued-hierarchy"
        )
        XCTAssertEqual(issued, [child.attachment.rawCID])
    }

    /// The admission batch that stages a carried block's incoming evidence
    /// (`stage`): a fault at its store or its issued retention stages no
    /// batch; while the retention merge is in flight, no row exists yet.
    /// Establishes: NODE-STORAGE-002.b
    func testStagedCarrierEvidenceIsWrittenOnlyAfterItsVolumeIsStoredAndRetained()
        async throws {
        let fixture = try await childProofFixture()
        let persistence = ImportPersistence(
            incomingCarrierEvidence: ImportCarrierEvidence(
                proof: fixture.first,
                childCID: fixture.childCID
            )
        )
        try await assertStagedEvidenceIsWrittenOnlyAfterItsVolumeIsStoredAndRetained(
            persistence,
            fixture: fixture
        )
    }

    /// The same at the batch's issued hierarchy artifacts (`stage` with
    /// `hierarchyArtifacts.carrierEvidence`, a carried child block's own
    /// carrier link and evidence).
    /// Establishes: NODE-STORAGE-002.b
    func testStagedHierarchyCarrierEvidenceIsWrittenOnlyAfterItsVolumeIsStoredAndRetained()
        async throws {
        let fixture = try await childProofFixture()
        let link = try decode(ParentCarrierLink.self, json: """
            {"parentPath":["Nexus","Child"],"carrierCID":"\(fixture.childCID)","rootCID":"\(fixture.first.rootCID)"}
            """)
        let persistence = ImportPersistence(
            hierarchyArtifacts: ImportHierarchyArtifacts(
                carrierLink: link,
                carrierEvidence: ImportCarrierEvidence(
                    proof: fixture.first,
                    childCID: fixture.childCID
                ),
                parentGenesisLinks: []
            )
        )
        try await assertStagedEvidenceIsWrittenOnlyAfterItsVolumeIsStoredAndRetained(
            persistence,
            fixture: fixture
        )
    }

    private func assertStagedEvidenceIsWrittenOnlyAfterItsVolumeIsStoredAndRetained(
        _ persistence: ImportPersistence,
        fixture: (
            childCID: String,
            childVolume: SerializedVolume,
            first: ChildBlockProof,
            second: ChildBlockProof,
            rootVolumes: [SerializedVolume]
        ),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let child = try await childEvidenceStore(fixture)
        let batch = blockBatch(
            postStateCID: testCID("staged-evidence-state"),
            blockHash: fixture.childCID
        )

        for step in [
            BrokerStep.store(root: child.attachment.rawCID),
            .merge(scope: "test:issued-hierarchy"),
        ] {
            await child.broker.failNext(step)
            do {
                try await child.store.stage(
                    batch,
                    volumeRoots: [],
                    persistence: persistence
                )
                XCTFail("the fault at \(step) did not surface", file: file, line: line)
            } catch {
                XCTAssertEqual(
                    error as? InjectedBrokerFault,
                    InjectedBrokerFault(step: step),
                    file: file,
                    line: line
                )
            }
            let staged = try await child.store.stagedImports()
            XCTAssertTrue(
                staged.isEmpty,
                "a batch outran its evidence at \(step)",
                file: file,
                line: line
            )
            try await assertNoEvidenceRow(
                child,
                fixture: fixture,
                after: step,
                file: file,
                line: line
            )
        }

        let merge = BrokerStep.merge(scope: "test:issued-hierarchy")
        await child.broker.parkNext(merge)
        let staging = Task {
            try await child.store.stage(
                batch,
                volumeRoots: [],
                persistence: persistence
            )
        }
        try await child.broker.waitUntilParked(merge)
        let stagedWhileParked = try await child.store.stagedImports()
        XCTAssertTrue(
            stagedWhileParked.isEmpty,
            "a batch outran its retention",
            file: file,
            line: line
        )
        try await assertNoEvidenceRow(
            child,
            fixture: fixture,
            after: merge,
            file: file,
            line: line
        )
        await child.broker.release(merge)
        try await staging.value

        let staged = try await child.store.stagedImports()
        XCTAssertEqual(staged.count, 1, file: file, line: line)
        let evidence = try await child.store.incomingCarrierEvidence(
            childCID: fixture.childCID,
            directory: "Child",
            rootCID: fixture.first.rootCID
        )
        XCTAssertEqual(
            evidence?.attachmentCID,
            child.attachment.rawCID,
            file: file,
            line: line
        )
        let issued = try await child.disk.retainedRoots(
            scope: "test:issued-hierarchy"
        )
        XCTAssertEqual(issued, [child.attachment.rawCID], file: file, line: line)
    }

    /// Carrier evidence enters issued retention through two sites, issued
    /// artifacts and a staged admission, interleaved: each after the other
    /// has retained something, and a pruning pass keeps all three.
    /// Establishes: NODE-STORAGE-002.d
    func testIssuedCarrierEvidenceOnlyGrowsIssuedRetentionWhileLive()
        async throws {
        let directory = temporaryDirectory(create: true)
        let broker = try DiskBroker(
            path: directory.appendingPathComponent("volumes.db").path
        )
        let store = try makeStore(
            path: directory.appendingPathComponent("state.db"),
            chainPath: ["Nexus", "Child"],
            broker: broker
        )
        let early = try await childProofFixture(childTimestamp: 1)
        let late = try await childProofFixture(childTimestamp: 10)
        func artifacts(
            _ childCID: String,
            _ proof: ChildBlockProof
        ) throws -> ImportHierarchyArtifacts {
            ImportHierarchyArtifacts(
                carrierLink: try decode(ParentCarrierLink.self, json: """
                    {"parentPath":["Nexus","Child"],"carrierCID":"\(childCID)","rootCID":"\(proof.rootCID)"}
                    """),
                carrierEvidence: ImportCarrierEvidence(
                    proof: proof,
                    childCID: childCID
                ),
                parentGenesisLinks: []
            )
        }

        try await store.persistIssuedHierarchyArtifacts(
            try artifacts(early.childCID, early.first)
        )
        try await store.stage(
            blockBatch(
                postStateCID: testCID("late-carrier-state"),
                blockHash: late.childCID
            ),
            volumeRoots: [],
            persistence: ImportPersistence(
                incomingCarrierEvidence: ImportCarrierEvidence(
                    proof: late.first,
                    childCID: late.childCID
                )
            )
        )
        try await store.persistIssuedHierarchyArtifacts(
            try artifacts(early.childCID, early.second)
        )

        var attachments: [String] = []
        for (childCID, rootCID) in [
            (early.childCID, early.first.rootCID),
            (late.childCID, late.first.rootCID),
            (early.childCID, early.second.rootCID),
        ] {
            let evidence = try await store.incomingCarrierEvidence(
                childCID: childCID,
                directory: "Child",
                rootCID: rootCID
            )
            attachments.append(try XCTUnwrap(evidence).attachmentCID)
        }
        XCTAssertEqual(Set(attachments).count, 3)
        _ = try await broker.evictUnpinned(graceSeconds: 0)
        for attachment in attachments {
            let kept = await broker.fetchVolumeLocal(root: attachment)
            XCTAssertNotNil(kept, "a live issue shrank issued retention")
        }
    }

    /// A batch pin that throws writes no offer row: the offer is not there
    /// to touch and names no roots, and nothing is left pinned. While the
    /// pin is in flight, no row exists yet.
    /// Establishes: NODE-STORAGE-002.h
    func testOfferRowIsWrittenOnlyAfterItsRootsArePinned() async throws {
        let directory = temporaryDirectory(create: true)
        let disk = try DiskBroker(
            path: directory.appendingPathComponent("volumes.db").path
        )
        let broker = FaultInjectingBroker(broker: disk)
        let store = try makeStore(
            path: directory.appendingPathComponent("state.db"),
            broker: broker
        )
        let volumes = try ["pinned-offer", "pinned-offer-state"].map {
            try VolumeImpl<PublicKey>(node: PublicKey(key: $0))
        }
        for volume in volumes { try await volume.store(storer: disk) }
        let offer = volumes[0].rawCID
        let roots = volumes.map(\.rawCID)

        await broker.failNext(.pinBatch(owner: "test:contextual-candidates"))
        do {
            try await store.persistContextualCandidateRoots(
                candidateCID: offer,
                roots: roots,
                capacity: 2
            )
            XCTFail("the injected pin fault did not surface")
        } catch {
            XCTAssertEqual(
                error as? InjectedBrokerFault,
                InjectedBrokerFault(
                    step: .pinBatch(owner: "test:contextual-candidates")
                )
            )
        }
        let touched = try await store.touchContextualCandidate(candidateCID: offer)
        XCTAssertFalse(touched, "an offer row outran its pins")
        let indexed = try await store.contextualCandidateVolumeRoots()
        XCTAssertTrue(indexed.isEmpty)

        let pin = BrokerStep.pinBatch(owner: "test:contextual-candidates")
        await broker.parkNext(pin)
        let offering = Task {
            try await store.persistContextualCandidateRoots(
                candidateCID: offer,
                roots: roots,
                capacity: 2
            )
        }
        try await broker.waitUntilParked(pin)
        let indexedWhileParked = try await store.contextualCandidateVolumeRoots()
        XCTAssertTrue(indexedWhileParked.isEmpty, "an offer row outran its pins")
        await broker.release(pin)
        try await offering.value

        let indexedAfter = try await store.contextualCandidateVolumeRoots()
        XCTAssertEqual(Set(indexedAfter), Set(roots))
        for root in roots {
            let owners = await disk.owners(root: root)
            XCTAssertEqual(owners, ["test:contextual-candidates"])
        }
    }

    private struct ChildEvidenceStore {
        let disk: DiskBroker
        let broker: FaultInjectingBroker
        let store: NodeStore
        let attachment: ChildEvidenceVolume
    }

    /// A child-chain store behind a fault-injecting broker, and the
    /// attachment of `fixture.first`'s evidence.
    private func childEvidenceStore(
        _ fixture: (
            childCID: String,
            childVolume: SerializedVolume,
            first: ChildBlockProof,
            second: ChildBlockProof,
            rootVolumes: [SerializedVolume]
        )
    ) async throws -> ChildEvidenceStore {
        let directory = temporaryDirectory(create: true)
        let disk = try DiskBroker(
            path: directory.appendingPathComponent("volumes.db").path
        )
        let broker = FaultInjectingBroker(broker: disk)
        let store = try makeStore(
            path: directory.appendingPathComponent("state.db"),
            chainPath: ["Nexus", "Child"],
            broker: broker
        )
        let package = AuthenticatedChildPackage(
            package: ChildValidationPackage(proof: fixture.first)
        )
        let attachment = try ChildEvidenceVolume(
            envelopeBytes: try ChildValidationPackageEnvelope(
                package.package
            ).encode(),
            childCID: fixture.childCID
        )
        return ChildEvidenceStore(
            disk: disk,
            broker: broker,
            store: store,
            attachment: attachment
        )
    }

    /// No evidence row names the attachment.
    private func assertNoEvidenceRow(
        _ child: ChildEvidenceStore,
        fixture: (
            childCID: String,
            childVolume: SerializedVolume,
            first: ChildBlockProof,
            second: ChildBlockProof,
            rootVolumes: [SerializedVolume]
        ),
        after step: BrokerStep,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let evidence = try await child.store.incomingCarrierEvidence(
            childCID: fixture.childCID,
            directory: "Child",
            rootCID: fixture.first.rootCID
        )
        XCTAssertNil(
            evidence,
            "an evidence row outran its Volume at \(step)",
            file: file,
            line: line
        )
    }

    /// One carrier whose root commits two child chains, Alpha and Beta,
    /// and a direct-hop proof of each.
    private func twoDirectoryProofFixture() async throws -> (
        carrierCID: String,
        proofs: [(directory: String, childCID: String, proof: ChildBlockProof)]
    ) {
        let content = InMemoryContentStore()
        try await LatticeState.emptyHeader.storeRecursively(storer: content)
        var children: [String: Block] = [:]
        for (directory, timestamp) in [("Alpha", Int64(1)), ("Beta", Int64(2))] {
            children[directory] = try await BlockBuilder.buildChildGenesis(
                spec: NexusGenesis.spec,
                parentState: LatticeState.emptyHeader,
                timestamp: timestamp,
                target: UInt256.max,
                fetcher: content
            )
        }
        let root = try await BlockBuilder.buildGenesis(
            spec: NexusGenesis.spec,
            children: children,
            timestamp: 3,
            target: UInt256.max,
            nonce: 1,
            fetcher: content
        )
        let rootHeader = try BlockHeader(node: root)
        try await rootHeader.storeRecursively(storer: content as any Storer)
        try await VolumeImpl<Block>(node: root).store(storer: content)
        var proofs: [(directory: String, childCID: String, proof: ChildBlockProof)] = []
        for directory in ["Alpha", "Beta"] {
            proofs.append((
                directory,
                try BlockHeader(node: children[directory]!).rawCID,
                try await ChildBlockProof.generate(
                    rootHeader: rootHeader,
                    childDirectory: directory,
                    fetcher: content
                )
            ))
        }
        return (rootHeader.rawCID, proofs)
    }

    private func makeStore(
        path: URL? = nil,
        genesisCID: String? = nil,
        chainPath: [String] = ["Nexus"],
        broker: (any RetainedRootMergeBroker)? = nil
    ) throws -> NodeStore {
        try testNodeStore(
            databasePath: path
                ?? temporaryDirectory(create: true).appendingPathComponent("state.db"),
            nexusGenesisCID: genesisCID ?? self.genesisCID,
            chainPath: chainPath,
            broker: broker
        )
    }

    private func blockBatch(
        postStateCID: String,
        blockHash: String = "same-block",
        parentBlockHash: String? = nil,
        blockHeight: UInt64 = 0
    ) -> BlockImportBatch {
        BlockImportBatch(facts: [
            .block(ChainBlockFact(
                blockHash: blockHash,
                parentBlockHash: parentBlockHash,
                blockHeight: blockHeight,
                postStateCID: postStateCID,
                prevStateCID: "previous-state",
                specCID: "spec",
                target: "target",
                nextTarget: "next-target",
                timestamp: 0,
                stateDiff: .empty
            )),
        ])
    }

    private func contribution(id: String, work: UInt64) -> VerifiedWorkContribution {
        let json = Data("{\"id\":\"\(id)\",\"work\":\"0x\(String(work, radix: 16))\"}".utf8)
        return try! JSONDecoder().decode(VerifiedWorkContribution.self, from: json)
    }

    private func decode<T: Decodable>(_ type: T.Type, json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func childProofFixture(
        childTimestamp: Int64 = 1
    ) async throws -> (
        childCID: String,
        childVolume: SerializedVolume,
        first: ChildBlockProof,
        second: ChildBlockProof,
        rootVolumes: [SerializedVolume]
    ) {
        let content = InMemoryContentStore()
        try await LatticeState.emptyHeader.storeRecursively(storer: content)
        let child = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec,
            parentState: LatticeState.emptyHeader,
            timestamp: childTimestamp,
            target: UInt256.max,
            fetcher: content
        )
        let childHeader = try BlockHeader(node: child)
        let childCID = childHeader.rawCID
        try await childHeader.store(storer: content)
        let storedChildVolume = await content.volume(root: childCID)
        let childVolume = try XCTUnwrap(storedChildVolume)
        var proofs: [ChildBlockProof] = []
        var rootVolumes: [SerializedVolume] = []
        for (timestamp, nonce) in [
            (childTimestamp + 1, UInt64(1)),
            (childTimestamp + 2, UInt64(2)),
        ] {
            let root = try await BlockBuilder.buildGenesis(
                spec: NexusGenesis.spec,
                children: ["Child": child],
                timestamp: timestamp,
                target: UInt256.max,
                nonce: nonce,
                fetcher: content
            )
            let rootHeader = try BlockHeader(node: root)
            try await rootHeader.storeRecursively(storer: content as any Storer)
            try await VolumeImpl<Block>(node: root).store(storer: content)
            let rootVolume = await content.volume(root: rootHeader.rawCID)
            rootVolumes.append(try XCTUnwrap(rootVolume))
            proofs.append(try await ChildBlockProof.generate(
                rootHeader: rootHeader,
                childDirectory: "Child",
                fetcher: content
            ))
        }
        return (
            childCID,
            childVolume,
            proofs[0],
            proofs[1],
            rootVolumes
        )
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {
        handler(error)
    }
}
