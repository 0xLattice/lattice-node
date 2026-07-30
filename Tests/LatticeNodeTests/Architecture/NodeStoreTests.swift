import Foundation
import Ivy
import XCTest
import UInt256
import VolumeBroker
import cashew
@testable import Lattice
@testable import LatticeNode

private func testCID(_ seed: String) -> String {
    try! HeaderImpl<PublicKey>(node: PublicKey(key: seed)).rawCID
}

final class NodeStoreTests: XCTestCase {
    private let genesisCID = NexusGenesis.expectedBlockHash
    private let parentProcessKey = String(repeating: "a", count: 64)

    func testLegacyDatabaseFailsBeforeNewDDL() throws {
        let directory = temporaryDirectory()
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
        let directory = temporaryDirectory()
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
        let directory = temporaryDirectory()
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
        let directory = temporaryDirectory()
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

    func testOutgoingChildEvidenceRequiresItsAcceptedLocalCarrier()
        async throws {
        let content = TestContentStore()
        try await LatticeState.emptyHeader.storeRecursively(storer: content)
        let leaf = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec,
            parentState: LatticeState.emptyHeader,
            timestamp: 1,
            target: UInt256.max,
            fetcher: content
        )
        let carrier = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec,
            parentState: LatticeState.emptyHeader,
            children: ["Leaf": leaf],
            timestamp: 2,
            target: UInt256.max,
            fetcher: content
        )
        let root = try await BlockBuilder.buildGenesis(
            spec: NexusGenesis.spec,
            children: ["Middle": carrier],
            timestamp: 3,
            target: UInt256.max,
            fetcher: content
        )
        let rootHeader = try BlockHeader(node: root)
        let carrierHeader = try BlockHeader(node: carrier)
        let leafHeader = try BlockHeader(node: leaf)
        try await rootHeader.storeRecursively(storer: content as any Storer)
        let upstream = try await ChildBlockProof.generate(
            rootHeader: rootHeader,
            childDirectory: "Middle",
            fetcher: content
        )
        let direct = try await ChildBlockProof.generate(
            rootHeader: carrierHeader,
            childDirectory: "Leaf",
            fetcher: content
        )
        let proof = upstream.composing(hop: direct)
        let store = try makeStore(chainPath: ["Nexus", "Middle"])
        try await store.stage(
            blockBatch(
                postStateCID: "carrier-state",
                blockHash: carrierHeader.rawCID,
                parentBlockHash: rootHeader.rawCID,
                blockHeight: 1
            ),
            volumeRoots: []
        )
        try await persistIssuedChildProof(
            in: store,
            proof,
            childCID: leafHeader.rawCID,
            parentCarrierCID: carrierHeader.rawCID
        )
        await XCTAssertThrowsErrorAsync(
            try await persistIssuedChildProof(
                in: store,
                proof,
                childCID: leafHeader.rawCID,
                parentCarrierCID: rootHeader.rawCID
            )
        ) { error in
            XCTAssertEqual(
                error as? NodeStoreError,
                .invalidIssuedChildProof(leafHeader.rawCID)
            )
        }

        let unacceptedStore = try makeStore(chainPath: ["Nexus", "Middle"])
        try await persistIssuedChildProof(
            in: unacceptedStore,
            proof,
            childCID: leafHeader.rawCID,
            parentCarrierCID: carrierHeader.rawCID
        )
        let unacceptedEvidence = try await unacceptedStore.issuedChildEvidence(
            childCID: leafHeader.rawCID,
            directory: "Leaf",
            rootCID: rootHeader.rawCID
        )
        XCTAssertNotNil(unacceptedEvidence)
    }

    func testAdmissionBatchReplayIsIdempotentAndFactConflictFailsClosed() async throws {
        let store = try makeStore()
        let original = blockBatch(postStateCID: "state-a")

        try await store.stage(original, volumeRoots: ["volume-z", "volume-a"])
        try await store.stage(original, volumeRoots: ["volume-a", "volume-z"])

        var staged = try await store.stagedAdmissions()
        XCTAssertEqual(staged.count, 1)
        XCTAssertEqual(staged[0].batch, original)
        XCTAssertEqual(staged[0].volumeRoots, ["volume-a", "volume-z"])

        await XCTAssertThrowsErrorAsync(
            try await store.stage(
                blockBatch(postStateCID: "state-b"),
                volumeRoots: ["other-volume"]
            )
        ) { error in
            XCTAssertEqual(error as? NodeStoreError, .conflictingAdmissionFact)
        }

        staged = try await store.stagedAdmissions()
        XCTAssertEqual(staged.count, 1)
    }

    func testAdmissionBatchRejectsDifferentRootList() async throws {
        let store = try makeStore()
        let batch = blockBatch(postStateCID: "state")
        try await store.stage(batch, volumeRoots: ["volume-a"])

        await XCTAssertThrowsErrorAsync(
            try await store.stage(batch, volumeRoots: ["volume-b"])
        ) { error in
            XCTAssertEqual(error as? NodeStoreError, .conflictingAdmissionBatch)
        }
        let staged = try await store.stagedAdmissions()
        XCTAssertEqual(staged.count, 1)
    }

    func testAdmissionReplayFailsWhenNormalizedFactRowsAreMissing() async throws {
        let factsPath = temporaryDirectory().appendingPathComponent("state.db")
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
        let artifacts = AdmissionHierarchyArtifacts(
            carrierLink: carrier,
            carrierEvidence: nil,
            parentGenesisLinks: [genesis]
        )

        try await store.stage(
            blockBatch(postStateCID: "state", blockHash: "carrier"),
            volumeRoots: [],
            hierarchyArtifacts: artifacts
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
        let staged = try await store.stagedAdmissions()
        XCTAssertEqual(storedCarrier, carrier)
        XCTAssertEqual(storedGenesis, genesis)
        XCTAssertEqual(staged.count, 1)
    }

    func testNormalizedIndexAuditRejectsParentFactWithoutSource() async throws {
        let path = temporaryDirectory().appendingPathComponent("state.db")
        let store = try makeStore(path: path)
        let carrier = try decode(ParentCarrierLink.self, json: """
            {"parentPath":["Nexus"],"carrierCID":"carrier","rootCID":"carrier"}
            """)
        try await store.stage(
            blockBatch(postStateCID: "state", blockHash: "carrier"),
            volumeRoots: [],
            hierarchyArtifacts: AdmissionHierarchyArtifacts(
                carrierLink: carrier,
                carrierEvidence: nil,
                parentGenesisLinks: []
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
            ChainAdmissionBatch(facts: [
                .work(ChainWorkFact(
                    blockHash: "carrier",
                    contribution: contribution(id: "grind", work: 7)
                )),
            ]),
            volumeRoots: [],
            hierarchyArtifacts: AdmissionHierarchyArtifacts(
                carrierLink: carrier,
                carrierEvidence: nil,
                parentGenesisLinks: []
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
                hierarchyArtifacts: AdmissionHierarchyArtifacts(
                    carrierLink: outsideBatch,
                    carrierEvidence: nil,
                    parentGenesisLinks: []
                )
            )
        ) { error in
            guard case NodeStoreError.invalidConfiguration = error else {
                return XCTFail("expected invalid hierarchy artifact, got \(error)")
            }
        }
        let staged = try await store.stagedAdmissions()
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
                hierarchyArtifacts: AdmissionHierarchyArtifacts(
                    carrierLink: carrier,
                    carrierEvidence: nil,
                    parentGenesisLinks: []
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
        XCTAssertEqual(first.blockCIDs, ["root-a"])

        try await store.stage(
            blockBatch(postStateCID: "root-c-state", blockHash: "root-c"),
            volumeRoots: []
        )
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
        XCTAssertEqual(refreshed.blockCIDs, ["root-a", "root-b", "root-c"])
    }

    func testNormalizedIndexAuditRequiresExactBatchDerivedRows() async throws {
        let path = temporaryDirectory().appendingPathComponent("state.db")
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
        let path = temporaryDirectory().appendingPathComponent("state.db")
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
        let path = temporaryDirectory().appendingPathComponent("state.db")
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
            hierarchyArtifacts: AdmissionHierarchyArtifacts(
                carrierLink: carrier,
                carrierEvidence: nil,
                parentGenesisLinks: [genesis]
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
                hierarchyArtifacts: AdmissionHierarchyArtifacts(
                    carrierLink: carrier,
                    carrierEvidence: nil,
                    parentGenesisLinks: [genesis]
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
                AdmissionHierarchyArtifacts(
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
                AdmissionHierarchyArtifacts(
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
            AdmissionHierarchyArtifacts(
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

    func testIssuedChildProofsAreSetValuedContentBoundAndDurable() async throws {
        let path = temporaryDirectory().appendingPathComponent("state.db")
        var store: NodeStore? = try makeStore(path: path)
        let fixture = try await childProofFixture()

        try await persistIssuedChildProof(
            in: store!,
            fixture.first,
            childCID: fixture.childCID
        )
        try await persistIssuedChildProof(
            in: store!,
            fixture.second,
            childCID: fixture.childCID
        )

        let selectedValue = try await store!.issuedChildEvidence(
            childCID: fixture.childCID,
            directory: "Child"
        )
        let selected = try XCTUnwrap(selectedValue).proof
        XCTAssertEqual(
            selected.rootCID,
            min(fixture.first.rootCID, fixture.second.rootCID)
        )
        let firstPage = try await store!.issuedChildProofRoots(
            childCID: fixture.childCID,
            directory: "Child",
            afterRootCID: nil,
            limit: 1
        )
        let secondPage = try await store!.issuedChildProofRoots(
            childCID: fixture.childCID,
            directory: "Child",
            afterRootCID: try XCTUnwrap(firstPage.last),
            limit: 1
        )
        let exhaustedPage = try await store!.issuedChildProofRoots(
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
        let exactValue = try await store!.issuedChildEvidence(
            childCID: fixture.childCID,
            directory: "Child",
            rootCID: fixture.second.rootCID
        )
        let exact = try XCTUnwrap(exactValue).proof
        XCTAssertEqual(try exact.serialize(), try fixture.second.serialize())

        store = nil
        store = try makeStore(path: path)
        let recoveredValue = try await store!.issuedChildEvidence(
            childCID: fixture.childCID,
            directory: "Child",
            rootCID: fixture.first.rootCID
        )
        let recovered = try XCTUnwrap(recoveredValue).proof
        XCTAssertEqual(try recovered.serialize(), try fixture.first.serialize())
        let otherChildCID = testCID("other-child")
        await XCTAssertThrowsErrorAsync(
            try await persistIssuedChildProof(
                in: store!,
                fixture.first,
                childCID: otherChildCID
            )
        ) { error in
            XCTAssertEqual(
                error as? NodeStoreError,
                .invalidIssuedChildProof(otherChildCID)
            )
        }
    }

    func testBootstrapRootsStayLocalAndRetainedOutsideEvidenceVolume()
        async throws {
        let directory = temporaryDirectory()
        let path = directory.appendingPathComponent("state.db")
        let broker = try DiskBroker(
            path: directory.appendingPathComponent("volumes.db").path,
            evictUnpinnedGraceSeconds: 0
        )
        let fixture = try await childProofFixture()
        var bootstrapVolumes = [fixture.childVolume]
        for index in 0..<48 {
            let header = try HeaderImpl<PublicKey>(
                node: PublicKey(key: "bootstrap-root-\(index)")
            )
            bootstrapVolumes.append(SerializedVolume(
                root: header.rawCID,
                entries: [header.rawCID: try header.mapToData()]
            ))
        }
        let bootstrapRoots = bootstrapVolumes.map(\.root)
        XCTAssertGreaterThan(
            try JSONEncoder().encode(bootstrapRoots).count,
            1_024
        )
        for volume in bootstrapVolumes {
            try await broker.store(volume: volume)
        }

        var store: NodeStore? = try makeStore(
            path: path,
            broker: broker
        )
        try await persistIssuedChildProof(
            in: store!,
            fixture.first,
            childCID: fixture.childCID,
            bootstrapRoots: bootstrapRoots
        )
        try await store!.persistPreparedChildProofs(
            carrierCID: fixture.first.rootCID,
            proofs: [try PreparedChildProof(
                directory: "Child",
                childCID: fixture.childCID,
                isChildGenesis: true,
                bootstrapRoots: bootstrapRoots,
                proof: fixture.first
            )],
            capacity: 1
        )

        let storedEvidence = try await store!.issuedChildEvidence(
            childCID: fixture.childCID,
            directory: "Child",
            rootCID: fixture.first.rootCID
        )
        let evidence = try XCTUnwrap(storedEvidence)
        let expectedEnvelope = try ChildValidationPackageEnvelope(
            ChildValidationPackage(proof: evidence.proof)
        )
        let expectedVolume = try ChildEvidenceVolume(
            envelopeBytes: try expectedEnvelope.encode(),
            childCID: fixture.childCID
        )
        XCTAssertEqual(evidence.attachmentCID, expectedVolume.rawCID)

        let storedEvidenceVolume = await broker.fetchVolumeLocal(
            root: evidence.attachmentCID
        )
        let evidenceVolume = try XCTUnwrap(storedEvidenceVolume)
        XCTAssertEqual(evidenceVolume.entries.count, 1)
        let evidenceFramedBytes = evidenceVolume.entries.reduce(0) {
            $0 + 6 + $1.key.utf8.count + $1.value.count
        }
        XCTAssertLessThanOrEqual(
            evidenceFramedBytes,
            ChildValidationPackageEnvelope.maximumEncodedSize + 1_024
        )

        _ = try await broker.evictUnpinned()
        for root in bootstrapRoots {
            let retained = await broker.fetchVolumeLocal(root: root)
            XCTAssertNotNil(retained)
        }

        store = nil
        store = try makeStore(
            path: path,
            broker: broker
        )
        let recoveredPrepared = try await store!.preparedChildProofs(
            carrierCID: fixture.first.rootCID
        )
        XCTAssertEqual(
            recoveredPrepared.first?.bootstrapRoots,
            bootstrapRoots.sorted()
        )
        let recoveredRoots = try await store!.recoveryVolumeRoots()
        XCTAssertTrue(Set(bootstrapRoots).isSubset(of: Set(recoveredRoots)))
    }

    func testIssuedChildProofsKeepSameChildDistinctAcrossDirectories() async throws {
        let content = TestContentStore()
        try await LatticeState.emptyHeader.storeRecursively(storer: content)
        let child = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec,
            parentState: LatticeState.emptyHeader,
            timestamp: 1,
            target: UInt256.max,
            fetcher: content
        )
        let childCID = try BlockHeader(node: child).rawCID
        let carrier = try await BlockBuilder.buildGenesis(
            spec: NexusGenesis.spec,
            children: ["Alpha": child, "Beta": child],
            timestamp: 2,
            target: UInt256.max,
            fetcher: content
        )
        let carrierHeader = try BlockHeader(node: carrier)
        try await carrierHeader.storeRecursively(storer: content as any Storer)
        let alpha = try await ChildBlockProof.generate(
            rootHeader: carrierHeader,
            childDirectory: "Alpha",
            fetcher: content
        )
        let beta = try await ChildBlockProof.generate(
            rootHeader: carrierHeader,
            childDirectory: "Beta",
            fetcher: content
        )
        let store = try makeStore()

        try await persistIssuedChildProof(
            in: store,
            alpha,
            childCID: childCID
        )
        try await persistIssuedChildProof(
            in: store,
            beta,
            childCID: childCID
        )

        let alphaValue = try await store.issuedChildEvidence(
            childCID: childCID,
            directory: "Alpha",
            rootCID: carrierHeader.rawCID
        )
        let betaValue = try await store.issuedChildEvidence(
            childCID: childCID,
            directory: "Beta",
            rootCID: carrierHeader.rawCID
        )
        let alphaProof = try XCTUnwrap(alphaValue).proof
        let betaProof = try XCTUnwrap(betaValue).proof
        XCTAssertEqual(try alphaProof.serialize(), try alpha.serialize())
        XCTAssertEqual(try betaProof.serialize(), try beta.serialize())
        let alphaRoots = try await store.issuedChildProofRoots(
            childCID: childCID,
            directory: "Alpha",
            afterRootCID: nil,
            limit: 2
        )
        XCTAssertEqual(
            alphaRoots,
            [carrierHeader.rawCID]
        )

        try await store.stage(
            blockBatch(
                postStateCID: "state",
                blockHash: carrierHeader.rawCID
            ),
            volumeRoots: [],
            hierarchyArtifacts: AdmissionHierarchyArtifacts(
                carrierLink: try decode(ParentCarrierLink.self, json: """
                    {"parentPath":["Nexus"],"carrierCID":"\(carrierHeader.rawCID)","rootCID":"\(carrierHeader.rawCID)"}
                """),
                carrierEvidence: nil,
                parentGenesisLinks: [try decode(
                    ParentGenesisLink.self,
                    json: """
                    {"parentPath":["Nexus"],"directory":"Alpha","childGenesisCID":"historical-alpha-genesis","parentStateCID":"historical-parent-state"}
                    """
                )]
            )
        )
        let alphaSummaries = try await store.issuedChildEvidenceSummaries(
            directory: "Alpha",
            afterOrdinal: 0,
            throughOrdinal: UInt64(Int64.max),
            limit: 2
        )
        XCTAssertEqual(alphaSummaries.count, 1)
        XCTAssertEqual(alphaSummaries.first?.childCID, childCID)
        XCTAssertEqual(alphaSummaries.first?.rootCID, carrierHeader.rawCID)
        XCTAssertTrue(alphaSummaries.first.map {
            CIDIdentity.isCanonical($0.attachmentCID)
        } ?? false)
        let betaSummaries = try await store.issuedChildEvidenceSummaries(
            directory: "Beta",
            afterOrdinal: 0,
            throughOrdinal: UInt64(Int64.max),
            limit: 2
        )
        XCTAssertEqual(betaSummaries.count, 1)
        XCTAssertEqual(betaSummaries.first?.childCID, childCID)
        XCTAssertEqual(betaSummaries.first?.rootCID, carrierHeader.rawCID)
    }

    func testIssuedCarrierEvidencePersistsProofAndLinkTogether() async throws {
        let path = temporaryDirectory().appendingPathComponent("state.db")
        let store = try makeStore(path: path, chainPath: ["Nexus", "Child"])
        let fixture = try await childProofFixture()
        let link = try decode(ParentCarrierLink.self, json: """
            {"parentPath":["Nexus","Child"],"carrierCID":"\(fixture.childCID)","rootCID":"\(fixture.first.rootCID)"}
            """)

        try await store.persistIssuedHierarchyArtifacts(
            AdmissionHierarchyArtifacts(
                carrierLink: link,
                carrierEvidence: AdmissionCarrierEvidence(
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

    func testIncomingCarrierProofRootsPageAcrossContexts() async throws {
        let store = try makeStore(chainPath: ["Nexus", "Child"])
        let fixture = try await childProofFixture()
        for proof in [fixture.first, fixture.second] {
            try await store.persistIssuedHierarchyArtifacts(
                AdmissionHierarchyArtifacts(
                    carrierLink: try decode(ParentCarrierLink.self, json: """
                        {"parentPath":["Nexus","Child"],"carrierCID":"\(fixture.childCID)","rootCID":"\(proof.rootCID)"}
                        """),
                    carrierEvidence: AdmissionCarrierEvidence(
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

    func testIncomingAndOutgoingAttachmentsShareOneDirectEdgeAcrossRoots()
        async throws {
        let content = TestContentStore()
        try await LatticeState.emptyHeader.storeRecursively(storer: content)
        let leaf = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec,
            parentState: LatticeState.emptyHeader,
            timestamp: 1,
            target: UInt256.max,
            fetcher: content
        )
        let carrier = try await BlockBuilder.buildGenesis(
            spec: NexusGenesis.spec,
            children: ["A": leaf],
            timestamp: 2,
            target: UInt256.max,
            fetcher: content
        )
        let carrierHeader = try BlockHeader(node: carrier)
        let leafCID = try BlockHeader(node: leaf).rawCID
        let direct = try await ChildBlockProof.generate(
            rootHeader: carrierHeader,
            childDirectory: "A",
            fetcher: content
        )
        var absoluteProofs: [ChildBlockProof] = []
        for timestamp in [Int64(3), Int64(4)] {
            let root = try await BlockBuilder.buildGenesis(
                spec: NexusGenesis.spec,
                children: ["A": carrier],
                timestamp: timestamp,
                target: UInt256.max,
                fetcher: content
            )
            let rootHeader = try BlockHeader(node: root)
            try await rootHeader.storeRecursively(storer: content as any Storer)
            absoluteProofs.append(try await ChildBlockProof.generate(
                rootHeader: rootHeader,
                childDirectory: "A",
                fetcher: content
            ).composing(hop: direct))
        }

        let parentPath = temporaryDirectory().appendingPathComponent("state.db")
        let parentBroker = try DiskBroker(
            path: parentPath.deletingLastPathComponent()
                .appendingPathComponent("volumes.db").path
        )
        let parent = try makeStore(
            path: parentPath,
            chainPath: ["Nexus", "A"],
            broker: parentBroker
        )
        let child = try makeStore(chainPath: ["Nexus", "A", "A"])
        try await parent.stage(
            blockBatch(
                postStateCID: "carrier-state",
                blockHash: carrierHeader.rawCID
            ),
            volumeRoots: []
        )
        for proof in absoluteProofs {
            try await persistIssuedChildProof(
                in: parent,
                proof,
                childCID: leafCID,
                parentCarrierCID: carrierHeader.rawCID
            )
            try await child.persistIssuedHierarchyArtifacts(
                AdmissionHierarchyArtifacts(
                    carrierLink: try decode(ParentCarrierLink.self, json: """
                        {"parentPath":["Nexus","A","A"],"carrierCID":"\(leafCID)","rootCID":"\(proof.rootCID)"}
                        """),
                    carrierEvidence: AdmissionCarrierEvidence(
                        proof: proof,
                        childCID: leafCID
                    ),
                    parentGenesisLinks: []
                )
            )
        }

        let parentAttachments = try await parent.childRootAttachmentSummaries(
            scope: .outgoingDirectChild,
            directory: "A",
            after: nil,
            limit: 3
        )
        let childAttachments = try await child.childRootAttachmentSummaries(
            scope: .incomingCarrier,
            directory: "A",
            after: nil,
            limit: 3
        )
        XCTAssertEqual(
            parentAttachments.map { [$0.edgeCID, $0.rootCID] },
            childAttachments.map { [$0.edgeCID, $0.rootCID] }
        )
        XCTAssertEqual(parentAttachments.count, 2)
        XCTAssertEqual(Set(parentAttachments.map(\.edgeCID)).count, 1)
        XCTAssertEqual(
            Set(parentAttachments.map(\.rootCID)),
            Set(absoluteProofs.map(\.rootCID))
        )
        let database = try NodeSQLite(path: parentPath.path)
        XCTAssertEqual(
            try database.query(
                "SELECT COUNT(*) AS count FROM issued_child_edges"
            ).first?["count"]?.intValue,
            1
        )
        XCTAssertEqual(
            try database.query(
                "SELECT COUNT(*) AS count FROM issued_child_proofs"
            ).first?["count"]?.intValue,
            2
        )

        let derivedEdge = await DirectChildEdge.derive(from: absoluteProofs[0])
        let edge = try XCTUnwrap(derivedEdge)
        XCTAssertEqual(edge.parentCarrierCID, carrierHeader.rawCID)
        XCTAssertEqual(edge.childCID, leafCID)
        XCTAssertEqual(edge.directory, "A")
        XCTAssertEqual(edge.proofBytes, try direct.serialize())
        let edgeCID = try XCTUnwrap(edge.edgeCID)
        let fetchedEdgeVolume = await parentBroker.fetchVolumeLocal(root: edgeCID)
        XCTAssertNil(fetchedEdgeVolume)
        let attachment = try await child.issuedChildEvidence(
            scope: .incomingCarrier,
            edgeCID: edgeCID,
            rootCID: absoluteProofs[1].rootCID
        )
        XCTAssertEqual(attachment?.edgeCID, edge.edgeCID)
        XCTAssertEqual(
            try attachment?.proof.serialize(),
            try absoluteProofs[1].serialize()
        )
        let tables = try database.query(
            "SELECT name FROM sqlite_master WHERE type = 'table'"
        ).compactMap { $0["name"]?.textValue }
        XCTAssertFalse(tables.contains("issued_child_blocks"))
        XCTAssertEqual(
            Set(try database.query("PRAGMA table_info(issued_child_edges)")
                .compactMap { $0["name"]?.textValue }),
            Set([
                "edge_cid", "parent_carrier_cid", "directory", "child_cid",
            ])
        )
        XCTAssertEqual(
            Set(try database.query("PRAGMA table_info(issued_child_proofs)")
                .compactMap { $0["name"]?.textValue }),
            Set([
                "scope", "edge_cid", "root_cid", "attachment_cid", "ordinal",
            ])
        )

        let proofRow = try XCTUnwrap(try database.query(
            "SELECT scope, edge_cid, root_cid, attachment_cid FROM issued_child_proofs LIMIT 1"
        ).first)
        let storedAttachmentCID = try XCTUnwrap(
            proofRow["attachment_cid"]?.textValue
        )
        let missingAttachmentCID = try HeaderImpl<PublicKey>(
            node: PublicKey(key: "missing-evidence-volume")
        ).rawCID
        try database.execute(
            "UPDATE issued_child_proofs SET attachment_cid = ?1 WHERE scope = ?2 AND edge_cid = ?3 AND root_cid = ?4",
            params: [
                .text(missingAttachmentCID),
                .text(try XCTUnwrap(proofRow["scope"]?.textValue)),
                .text(try XCTUnwrap(proofRow["edge_cid"]?.textValue)),
                .text(try XCTUnwrap(proofRow["root_cid"]?.textValue)),
            ]
        )
        let missingRootCID = try XCTUnwrap(proofRow["root_cid"]?.textValue)
        let indexedAttachments = try await parent.childRootAttachmentSummaries(
            scope: .outgoingDirectChild,
            directory: "A",
            after: nil,
            limit: 3
        )
        XCTAssertEqual(
            indexedAttachments.first { $0.rootCID == missingRootCID }?
                .attachmentCID,
            missingAttachmentCID
        )
        let indexedRoots = try await parent.issuedChildProofRoots(
            childCID: leafCID,
            directory: "A",
            afterRootCID: nil,
            limit: 3
        )
        XCTAssertTrue(indexedRoots.contains(missingRootCID))
        await XCTAssertThrowsErrorAsync(
            try await parent.issuedChildEvidence(
                scope: .outgoingDirectChild,
                edgeCID: edgeCID,
                rootCID: missingRootCID
            )
        )
        await XCTAssertThrowsErrorAsync(
            try await parent.auditNormalizedIndexes()
        ) { error in
            guard case NodeStoreError.corrupt = error else {
                return XCTFail("expected missing attachment corruption, got \(error)")
            }
        }
        try database.execute(
            "UPDATE issued_child_proofs SET attachment_cid = ?1 WHERE attachment_cid = ?2",
            params: [.text(storedAttachmentCID), .text(missingAttachmentCID)]
        )

        try NodeSQLite(path: parentPath.path).execute(
            "UPDATE issued_child_edges SET child_cid = ?1",
            params: [.text(try BlockHeader(node: carrier).rawCID)]
        )
        await XCTAssertThrowsErrorAsync(
            try await parent.auditNormalizedIndexes()
        ) { error in
            guard case NodeStoreError.corrupt = error else {
                return XCTFail("expected corrupt edge index, got \(error)")
            }
        }
    }

    func testIncomingCarrierProofIsNeverAdvertisedAsOutgoingChildProof() async throws {
        let content = TestContentStore()
        try await LatticeState.emptyHeader.storeRecursively(storer: content)
        let leaf = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec,
            parentState: LatticeState.emptyHeader,
            timestamp: 1,
            target: UInt256.max,
            fetcher: content
        )
        let carrier = try await BlockBuilder.buildGenesis(
            spec: NexusGenesis.spec,
            children: ["A": leaf],
            timestamp: 2,
            target: UInt256.max,
            fetcher: content
        )
        let carrierHeader = try BlockHeader(node: carrier)
        let root = try await BlockBuilder.buildGenesis(
            spec: NexusGenesis.spec,
            children: ["A": carrier],
            timestamp: 3,
            target: UInt256.max,
            fetcher: content
        )
        let rootHeader = try BlockHeader(node: root)
        let leafCID = try BlockHeader(node: leaf).rawCID
        try await rootHeader.storeRecursively(storer: content as any Storer)
        let incoming = try await ChildBlockProof.generate(
            rootHeader: rootHeader,
            childDirectory: "A",
            fetcher: content
        )
        let direct = try await ChildBlockProof.generate(
            rootHeader: carrierHeader,
            childDirectory: "A",
            fetcher: content
        )
        let outgoing = incoming.composing(hop: direct)
        let store = try makeStore(chainPath: ["Nexus", "A"])

        try await store.stage(
            blockBatch(
                postStateCID: "state",
                blockHash: carrierHeader.rawCID
            ),
            volumeRoots: [],
            hierarchyArtifacts: AdmissionHierarchyArtifacts(
                carrierLink: try decode(ParentCarrierLink.self, json: """
                    {"parentPath":["Nexus","A"],"carrierCID":"\(carrierHeader.rawCID)","rootCID":"\(rootHeader.rawCID)"}
                    """),
                carrierEvidence: AdmissionCarrierEvidence(
                    proof: incoming,
                    childCID: carrierHeader.rawCID
                ),
                parentGenesisLinks: [try decode(
                    ParentGenesisLink.self,
                    json: """
                    {"parentPath":["Nexus","A"],"directory":"A","childGenesisCID":"\(leafCID)","parentStateCID":"parent-state"}
                    """
                )]
            )
        )
        try await persistIssuedChildProof(
            in: store,
            outgoing,
            childCID: leafCID
        )
        let carrierRoots = try await store.incomingCarrierProofRoots(
            childCID: carrierHeader.rawCID,
            directory: "A",
            afterRootCID: nil,
            limit: 1
        )
        XCTAssertEqual(carrierRoots, [rootHeader.rawCID])
        XCTAssertNotEqual(carrierRoots, [carrierHeader.rawCID])
        let outgoingCarrierEvidence = try await store.issuedChildEvidence(
            childCID: carrierHeader.rawCID,
            directory: "A",
            rootCID: rootHeader.rawCID
        )
        XCTAssertNil(outgoingCarrierEvidence)
        let incomingCarrierEvidence = try await store.incomingCarrierEvidence(
            childCID: carrierHeader.rawCID,
            directory: "A",
            rootCID: rootHeader.rawCID
        )
        XCTAssertNotNil(incomingCarrierEvidence)
        let summaries = try await store.issuedChildEvidenceSummaries(
            directory: "A",
            afterOrdinal: 0,
            throughOrdinal: UInt64(Int64.max),
            limit: 2
        )
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.childCID, leafCID)
        XCTAssertEqual(summaries.first?.rootCID, rootHeader.rawCID)
        XCTAssertTrue(summaries.first.map {
            CIDIdentity.isCanonical($0.attachmentCID)
        } ?? false)
    }

    func testPreparedChildProofsAreDurableAndBoundedByCarrier() async throws {
        let path = temporaryDirectory().appendingPathComponent("state.db")
        var store: NodeStore? = try makeStore(path: path)
        let fixture = try await childProofFixture()
        let first = try PreparedChildProof(
            directory: "Child",
            childCID: fixture.childCID,
            isChildGenesis: true,
            proof: fixture.first
        )
        let second = try PreparedChildProof(
            directory: "Child",
            childCID: fixture.childCID,
            isChildGenesis: true,
            proof: fixture.second
        )

        try await store!.persistPreparedChildProofs(
            carrierCID: fixture.first.rootCID,
            proofs: [first],
            capacity: 1
        )
        try await store!.persistPreparedChildProofs(
            carrierCID: fixture.first.rootCID,
            proofs: [first],
            capacity: 1
        )
        store = nil
        store = try makeStore(path: path)

        let recovered = try await store!.preparedChildProofs(
            carrierCID: fixture.first.rootCID
        )
        XCTAssertEqual(recovered.map(\.directory), ["Child"])
        XCTAssertEqual(recovered.map(\.childCID), [fixture.childCID])
        XCTAssertEqual(
            try recovered.first?.proof.serialize(),
            try fixture.first.serialize()
        )
        XCTAssertEqual(recovered.first?.bootstrapRoots, [])

        try await store!.persistPreparedChildProofs(
            carrierCID: fixture.second.rootCID,
            proofs: [second],
            capacity: 1
        )
        let evicted = try await store!.preparedChildProofs(
            carrierCID: fixture.first.rootCID
        )
        let carriers = try await store!.preparedChildProofCarrierCIDs()
        XCTAssertTrue(evicted.isEmpty)
        XCTAssertEqual(carriers, [fixture.second.rootCID])
    }

    func testEvictedPreparedGenesisDropsUnownedBootstrapRoots() async throws {
        let directory = temporaryDirectory()
        let broker = try DiskBroker(
            path: directory.appendingPathComponent("volumes.db").path
        )
        let store = try makeStore(
            path: directory.appendingPathComponent("state.db"),
            broker: broker
        )
        let first = try await childProofFixture(childTimestamp: 1)
        let second = try await childProofFixture(childTimestamp: 10)
        let firstAttachment = try ChildEvidenceVolume(
            envelopeBytes: try ChildValidationPackageEnvelope(
                ChildValidationPackage(proof: first.first)
            ).encode(),
            childCID: first.childCID
        )
        let secondAttachment = try ChildEvidenceVolume(
            envelopeBytes: try ChildValidationPackageEnvelope(
                ChildValidationPackage(proof: second.first)
            ).encode(),
            childCID: second.childCID
        )
        for volume in [first.childVolume, second.childVolume] {
            try await broker.store(volume: volume)
        }

        try await store.persistPreparedChildProofs(
            carrierCID: first.first.rootCID,
            proofs: [try PreparedChildProof(
                directory: "Child",
                childCID: first.childCID,
                isChildGenesis: true,
                bootstrapRoots: [first.childCID],
                proof: first.first
            )],
            capacity: 1
        )
        try await store.persistPreparedChildProofs(
            carrierCID: second.first.rootCID,
            proofs: [try PreparedChildProof(
                directory: "Child",
                childCID: second.childCID,
                isChildGenesis: true,
                bootstrapRoots: [second.childCID],
                proof: second.first
            )],
            capacity: 1
        )

        let roots = try await store.recoveryVolumeRoots()
        XCTAssertFalse(roots.contains(first.childCID))
        XCTAssertTrue(roots.contains(second.childCID))
        _ = try await broker.evictUnpinned(graceSeconds: 0)
        let evictedChild = await broker.fetchVolumeLocal(root: first.childCID)
        let evictedAttachment = await broker.fetchVolumeLocal(
            root: firstAttachment.rawCID
        )
        let retainedChild = await broker.fetchVolumeLocal(root: second.childCID)
        let retainedAttachment = await broker.fetchVolumeLocal(
            root: secondAttachment.rawCID
        )
        XCTAssertNil(evictedChild)
        XCTAssertNil(evictedAttachment)
        XCTAssertNotNil(retainedChild)
        XCTAssertNotNil(retainedAttachment)
    }

    func testPreparedRetentionMutationIsSerializedThroughExactReconciliation()
        async throws {
        let directory = temporaryDirectory()
        let broker = try DiskBroker(
            path: directory.appendingPathComponent("volumes.db").path
        )
        let blockingBroker = BlockingVolumeBroker(broker: broker)
        let store = try makeStore(
            path: directory.appendingPathComponent("state.db"),
            broker: blockingBroker
        )
        let first = try await childProofFixture(childTimestamp: 1)
        let second = try await childProofFixture(childTimestamp: 10)
        let firstPrepared = try PreparedChildProof(
            directory: "Child",
            childCID: first.childCID,
            isChildGenesis: false,
            proof: first.first
        )
        let secondPrepared = try PreparedChildProof(
            directory: "Child",
            childCID: second.childCID,
            isChildGenesis: false,
            proof: second.first
        )
        let firstAttachment = try ChildEvidenceVolume(
            envelopeBytes: try ChildValidationPackageEnvelope(
                ChildValidationPackage(proof: first.first)
            ).encode(),
            childCID: first.childCID
        )
        let secondAttachment = try ChildEvidenceVolume(
            envelopeBytes: try ChildValidationPackageEnvelope(
                ChildValidationPackage(proof: second.first)
            ).encode(),
            childCID: second.childCID
        )

        let firstTask = Task {
            try await store.persistPreparedChildProofs(
                carrierCID: first.first.rootCID,
                proofs: [firstPrepared],
                capacity: 1
            )
        }
        await blockingBroker.waitUntilFirstStore()
        let secondTask = Task {
            try await store.persistPreparedChildProofs(
                carrierCID: second.first.rootCID,
                proofs: [secondPrepared],
                capacity: 1
            )
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        let storesWhileBlocked = await blockingBroker.storeCount()
        XCTAssertEqual(storesWhileBlocked, 1)

        await blockingBroker.releaseFirstStore()
        try await firstTask.value
        try await secondTask.value
        let retainedCarriers = try await store.preparedChildProofCarrierCIDs()
        XCTAssertEqual(retainedCarriers, [second.first.rootCID])

        _ = try await broker.evictUnpinned(graceSeconds: 0)
        let evicted = await broker.fetchVolumeLocal(root: firstAttachment.rawCID)
        let retained = await broker.fetchVolumeLocal(root: secondAttachment.rawCID)
        XCTAssertNil(evicted)
        XCTAssertNotNil(retained)
    }

    func testIssuedGenesisKeepsBootstrapRootsAfterPreparationRemoval()
        async throws {
        let directory = temporaryDirectory()
        let broker = try DiskBroker(
            path: directory.appendingPathComponent("volumes.db").path
        )
        let store = try makeStore(
            path: directory.appendingPathComponent("state.db"),
            broker: broker
        )
        let fixture = try await childProofFixture()
        try await broker.store(
            volume: fixture.childVolume
        )
        let prepared = try PreparedChildProof(
            directory: "Child",
            childCID: fixture.childCID,
            isChildGenesis: true,
            bootstrapRoots: [fixture.childCID],
            proof: fixture.first
        )
        try await store.persistPreparedChildProofs(
            carrierCID: fixture.first.rootCID,
            proofs: [prepared],
            capacity: 1
        )
        try await persistIssuedChildProof(
            in: store,
            fixture.first,
            childCID: fixture.childCID,
            bootstrapRoots: [fixture.childCID]
        )
        try await store.removePreparedChildProof(
            carrierCID: fixture.first.rootCID,
            directory: "Child"
        )

        let roots = try await store.recoveryVolumeRoots()
        XCTAssertTrue(roots.contains(fixture.childCID))
        let storedEvidence = try await store.issuedChildEvidence(
            childCID: fixture.childCID,
            directory: "Child",
            rootCID: fixture.first.rootCID
        )
        let evidence = try XCTUnwrap(storedEvidence)
        _ = try await broker.evictUnpinned(graceSeconds: 0)
        let retainedChild = await broker.fetchVolumeLocal(root: fixture.childCID)
        let retainedEvidence = await broker.fetchVolumeLocal(
            root: evidence.attachmentCID
        )
        XCTAssertNotNil(retainedChild)
        XCTAssertNotNil(retainedEvidence)
    }

    func testPendingChildProofRoutesUnionRecoverAndEvictByCarrier() async throws {
        let path = temporaryDirectory().appendingPathComponent("state.db")
        var store: NodeStore? = try makeStore(path: path)
        try await store!.persistPendingChildProofRoutes(
            carrierCID: "carrier-a",
            directories: ["Beta", "Alpha"],
            capacity: 1
        )
        try await store!.persistPendingChildProofRoutes(
            carrierCID: "carrier-a",
            directories: ["Gamma", "Alpha"],
            capacity: 1
        )
        store = nil
        store = try makeStore(path: path)

        let recoveredRoutes = try await store!.pendingChildProofRoutes()
        XCTAssertEqual(
            recoveredRoutes,
            [
                PendingChildProofRoute(carrierCID: "carrier-a", directory: "Alpha"),
                PendingChildProofRoute(carrierCID: "carrier-a", directory: "Beta"),
                PendingChildProofRoute(carrierCID: "carrier-a", directory: "Gamma"),
            ]
        )
        try await store!.removePendingChildProofRoutes(
            carrierCID: "carrier-a",
            directories: ["Beta"]
        )
        try await store!.persistPendingChildProofRoutes(
            carrierCID: "carrier-b",
            directories: ["Delta"],
            capacity: 1
        )
        let remainingRoutes = try await store!.pendingChildProofRoutes()
        XCTAssertEqual(
            remainingRoutes,
            [PendingChildProofRoute(carrierCID: "carrier-b", directory: "Delta")]
        )
    }

    func testPendingRouteCapacityOnlyEvictsSpeculativeCarriers() async throws {
        let store = try makeStore()
        try await store.stage(
            blockBatch(postStateCID: "state", blockHash: "accepted"),
            volumeRoots: [],
            pendingChildProofRoutes: [PendingChildProofRoute(
                carrierCID: "accepted",
                directory: "AcceptedChild"
            )],
            pendingChildProofCapacity: 1
        )
        try await store.persistIssuedHierarchyArtifacts(
            AdmissionHierarchyArtifacts(
                carrierLink: try decode(ParentCarrierLink.self, json: """
                    {"parentPath":["Nexus"],"carrierCID":"issued","rootCID":"issued"}
                    """),
                carrierEvidence: nil,
                parentGenesisLinks: []
            ),
            pendingChildProofRoutes: [PendingChildProofRoute(
                carrierCID: "issued",
                directory: "IssuedChild"
            )],
            pendingChildProofCapacity: 1
        )
        try await store.persistPendingChildProofRoutes(
            carrierCID: "speculative-a",
            directories: ["A"],
            capacity: 1
        )
        try await store.persistPendingChildProofRoutes(
            carrierCID: "speculative-b",
            directories: ["B"],
            capacity: 1
        )

        let routes = try await store.pendingChildProofRoutes()
        XCTAssertEqual(Set(routes), [
            PendingChildProofRoute(
                carrierCID: "accepted",
                directory: "AcceptedChild"
            ),
            PendingChildProofRoute(
                carrierCID: "issued",
                directory: "IssuedChild"
            ),
            PendingChildProofRoute(
                carrierCID: "speculative-b",
                directory: "B"
            ),
        ])
    }

    func testPreparedProofDoesNotSuppressPendingPublicationRoute() async throws {
        let store = try makeStore()
        let fixture = try await childProofFixture()
        try await store.persistPreparedChildProofs(
            carrierCID: fixture.first.rootCID,
            proofs: [try PreparedChildProof(
                directory: "Child",
                childCID: fixture.childCID,
                isChildGenesis: true,
                proof: fixture.first
            )],
            capacity: 1
        )

        try await store.stage(
            blockBatch(
                postStateCID: "state",
                blockHash: fixture.first.rootCID
            ),
            volumeRoots: [],
            pendingChildProofRoutes: [],
            pendingChildProofCapacity: 1
        )

        let routes = try await store.pendingChildProofRoutes()
        XCTAssertEqual(routes, [PendingChildProofRoute(
            carrierCID: fixture.first.rootCID,
            directory: "Child"
        )])
    }

    func testPreparedChildProofRoutesGrowByImmutableDirectory() async throws {
        let content = TestContentStore()
        try await LatticeState.emptyHeader.storeRecursively(storer: content)
        let alpha = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec,
            parentState: LatticeState.emptyHeader,
            timestamp: 1,
            target: UInt256.max,
            fetcher: content
        )
        let beta = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec,
            parentState: LatticeState.emptyHeader,
            timestamp: 2,
            target: UInt256.max,
            fetcher: content
        )
        let carrier = try await BlockBuilder.buildGenesis(
            spec: NexusGenesis.spec,
            children: ["Alpha": alpha, "Beta": beta],
            timestamp: 3,
            target: UInt256.max,
            fetcher: content
        )
        let carrierHeader = try BlockHeader(node: carrier)
        try await carrierHeader.storeRecursively(storer: content as any Storer)
        let alphaProof = try await ChildBlockProof.generate(
            rootHeader: carrierHeader,
            childDirectory: "Alpha",
            fetcher: content
        )
        let betaProof = try await ChildBlockProof.generate(
            rootHeader: carrierHeader,
            childDirectory: "Beta",
            fetcher: content
        )
        let alphaCID = try BlockHeader(node: alpha).rawCID
        let betaCID = try BlockHeader(node: beta).rawCID
        let store = try makeStore()
        try await store.persistPreparedChildProofs(
            carrierCID: carrierHeader.rawCID,
            proofs: [try PreparedChildProof(
                directory: "Alpha",
                childCID: alphaCID,
                isChildGenesis: true,
                proof: alphaProof
            )],
            capacity: 2
        )
        try await store.persistPreparedChildProofs(
            carrierCID: carrierHeader.rawCID,
            proofs: [try PreparedChildProof(
                directory: "Beta",
                childCID: betaCID,
                isChildGenesis: true,
                proof: betaProof
            )],
            capacity: 2
        )

        let recovered = try await store.preparedChildProofs(
            carrierCID: carrierHeader.rawCID
        )
        XCTAssertEqual(recovered.map(\.directory), ["Alpha", "Beta"])
    }

    func testAdmissionStorageRecordsOnlyActualVolumeRoots() async throws {
        let broker = MemoryBroker()
        let admission = NodeAdmissionStorage(storage: broker)
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

    func testContextualCandidateRootsUseDurableLRUReplacement()
        async throws
    {
        let directory = temporaryDirectory()
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

    func testContextualOffersCannotEvictIssuedReservations() async throws {
        let directory = temporaryDirectory()
        let broker = try DiskBroker(
            path: directory.appendingPathComponent("volumes.db").path
        )
        let store = try makeStore(
            path: directory.appendingPathComponent("state.db"),
            broker: broker
        )
        let volumes = try ["issued", "old-offer", "new-offer"].map {
            try VolumeImpl<PublicKey>(node: PublicKey(key: $0))
        }
        for volume in volumes {
            try await volume.store(storer: broker)
        }
        let issued = volumes[0].rawCID
        let oldOffer = volumes[1].rawCID
        let newOffer = volumes[2].rawCID
        let child = ChildCandidateReservationReference(
            peerKey: try PeerKey(
                rawRepresentation: Data(repeating: 0xaa, count: PeerKey.byteCount)
            ),
            candidateCID: oldOffer
        )
        try await store.persistContextualCandidateRoots(
            candidateCID: issued,
            roots: [issued],
            children: [child],
            capacity: 1
        )
        let firstReplacement = try await store.replaceIssuedContextualCandidates(
            [issued],
            capacity: 1
        )
        XCTAssertTrue(firstReplacement)
        try await store.persistContextualCandidateRoots(
            candidateCID: oldOffer,
            roots: [oldOffer],
            capacity: 1
        )
        try await store.persistContextualCandidateRoots(
            candidateCID: newOffer,
            roots: [newOffer],
            capacity: 1
        )
        let retainedRoots = try await store.contextualCandidateVolumeRoots()
        XCTAssertEqual(Set(retainedRoots), Set([issued, newOffer]))
        let retainedChildren = try await store.contextualCandidateChildren(
            candidateCIDs: [issued]
        )
        XCTAssertEqual(retainedChildren, [child])
        _ = try await broker.evictUnpinned(graceSeconds: 0)
        let retainedIssued = await broker.fetchVolumeLocal(root: issued)
        let evictedOldOffer = await broker.fetchVolumeLocal(root: oldOffer)
        let retainedNewOffer = await broker.fetchVolumeLocal(root: newOffer)
        XCTAssertNotNil(retainedIssued)
        XCTAssertNil(evictedOldOffer)
        XCTAssertNotNil(retainedNewOffer)

        let secondReplacement = try await store.replaceIssuedContextualCandidates(
            [newOffer],
            capacity: 1
        )
        XCTAssertTrue(secondReplacement)
        _ = try await broker.evictUnpinned(graceSeconds: 0)
        let releasedIssued = await broker.fetchVolumeLocal(root: issued)
        let promotedOffer = await broker.fetchVolumeLocal(root: newOffer)
        XCTAssertNil(releasedIssued)
        XCTAssertNotNil(promotedOffer)
    }

    func testParentEvidenceHandoffSurvivesReleaseUntilAdmissionOwnsRoots()
        async throws
    {
        let directory = temporaryDirectory()
        let broker = try DiskBroker(
            path: directory.appendingPathComponent("volumes.db").path
        )
        let store = try makeStore(
            path: directory.appendingPathComponent("state.db"),
            broker: broker
        )
        let candidate = try VolumeImpl<PublicKey>(
            node: PublicKey(key: "handoff-candidate")
        )
        let shared = try VolumeImpl<PublicKey>(
            node: PublicKey(key: "handoff-shared")
        )
        let storer = broker
        try await candidate.store(storer: storer)
        try await shared.store(storer: storer)
        let descendant = ChildCandidateReservationReference(
            peerKey: try PeerKey(
                rawRepresentation: Data(
                    repeating: 0xbb,
                    count: PeerKey.byteCount
                )
            ),
            candidateCID: shared.rawCID
        )
        try await store.persistContextualCandidateRoots(
            candidateCID: candidate.rawCID,
            roots: [candidate.rawCID, shared.rawCID],
            children: [descendant],
            capacity: 16
        )
        let issuedReplacement = try await store.replaceIssuedContextualCandidates(
            [candidate.rawCID],
            capacity: 16
        )
        XCTAssertTrue(issuedReplacement)
        let beganHandoff = try await store.beginContextualCandidateHandoff(
            candidateCID: candidate.rawCID
        )
        XCTAssertTrue(beganHandoff)

        let releasedReservation = try await store
            .replaceIssuedContextualCandidates(
            [],
            capacity: 16
        )
        XCTAssertTrue(releasedReservation)
        let issued = try await store.issuedContextualCandidateCIDs()
        XCTAssertTrue(issued.isEmpty)
        let retainedDescendants = try await store
            .contextualCandidateChildren(candidateCIDs: [])
        XCTAssertEqual(retainedDescendants, [descendant])
        _ = try await broker.evictUnpinned(graceSeconds: 0)
        let retainedCandidate = await broker.fetchVolumeLocal(
            root: candidate.rawCID
        )
        let retainedShared = await broker.fetchVolumeLocal(root: shared.rawCID)
        XCTAssertNotNil(retainedCandidate)
        XCTAssertNotNil(retainedShared)

        try await store.stage(
            blockBatch(
                postStateCID: "handoff-state",
                blockHash: candidate.rawCID
            ),
            volumeRoots: [candidate.rawCID, shared.rawCID]
        )
        let removedAfterAdmission = try await store
            .removeContextualCandidateIfAdmitted(
            candidateCID: candidate.rawCID
        )
        XCTAssertTrue(removedAfterAdmission)
        let releasedDescendants = try await store
            .currentContextualCandidateChildren()
        XCTAssertTrue(releasedDescendants.isEmpty)
        _ = try await broker.evictUnpinned(graceSeconds: 0)
        let releasedCandidate = await broker.fetchVolumeLocal(
            root: candidate.rawCID
        )
        let releasedShared = await broker.fetchVolumeLocal(root: shared.rawCID)
        XCTAssertNil(releasedCandidate)
        XCTAssertNil(releasedShared)
    }

    func testHandoffClearsIssuedAndSnapshotCannotDemoteHandoff()
        async throws
    {
        let directory = temporaryDirectory()
        let broker = try DiskBroker(
            path: directory.appendingPathComponent("volumes.db").path
        )
        let store = try makeStore(
            path: directory.appendingPathComponent("state.db"),
            broker: broker
        )
        let candidate = try VolumeImpl<PublicKey>(
            node: PublicKey(key: "exclusive-candidate")
        )
        try await candidate.store(storer: broker)
        try await store.persistContextualCandidateRoots(
            candidateCID: candidate.rawCID,
            roots: [candidate.rawCID],
            capacity: 16
        )
        let issuedReplacement = try await store
            .replaceIssuedContextualCandidates(
            [candidate.rawCID],
            capacity: 16
        )
        XCTAssertTrue(issuedReplacement)
        let issuedBeforeHandoff = try await store
            .issuedContextualCandidateCIDs()
        XCTAssertEqual(issuedBeforeHandoff, [candidate.rawCID])

        // Handoff ownership replaces the reservation rather than stacking on
        // top of it: issued and handoff are mutually exclusive.
        let beganHandoff = try await store.beginContextualCandidateHandoff(
            candidateCID: candidate.rawCID
        )
        XCTAssertTrue(beganHandoff)
        let issuedAfterHandoff = try await store
            .issuedContextualCandidateCIDs()
        XCTAssertTrue(issuedAfterHandoff.isEmpty)

        // A later parent snapshot cannot demote durable handoff ownership
        // back to a plain reservation.
        let reissueAttempt = try await store
            .replaceIssuedContextualCandidates(
            [candidate.rawCID],
            capacity: 16
        )
        XCTAssertTrue(reissueAttempt)
        let issuedAfterReissue = try await store
            .issuedContextualCandidateCIDs()
        XCTAssertTrue(issuedAfterReissue.isEmpty)
        try await store.auditNormalizedIndexes()
    }

    func testHandoffBudgetEvictsOldestAndEvictedCandidateCanReturn()
        async throws
    {
        let directory = temporaryDirectory()
        let broker = try DiskBroker(
            path: directory.appendingPathComponent("volumes.db").path
        )
        let store = try makeStore(
            path: directory.appendingPathComponent("state.db"),
            broker: broker,
            handoffCandidateCapacity: 2
        )
        var candidates: [VolumeImpl<PublicKey>] = []
        for index in 0..<3 {
            let candidate = try VolumeImpl<PublicKey>(
                node: PublicKey(key: "budget-candidate-\(index)")
            )
            try await candidate.store(storer: broker)
            try await store.persistContextualCandidateRoots(
                candidateCID: candidate.rawCID,
                roots: [candidate.rawCID],
                capacity: 16
            )
            candidates.append(candidate)
        }
        for candidate in candidates {
            let began = try await store.beginContextualCandidateHandoff(
                candidateCID: candidate.rawCID
            )
            XCTAssertTrue(began)
        }

        // The budget keeps the two newest handoffs and drops the oldest
        // whole: row and pinned roots together.
        let retained = try await store.contextualCandidateVolumeRoots()
        XCTAssertEqual(
            Set(retained),
            Set([candidates[1].rawCID, candidates[2].rawCID])
        )
        _ = try await broker.evictUnpinned(graceSeconds: 0)
        let evictedVolume = await broker.fetchVolumeLocal(
            root: candidates[0].rawCID
        )
        XCTAssertNil(evictedVolume)
        try await store.auditNormalizedIndexes()

        // Eviction is willingness, not validity: the same candidate returns
        // through the ordinary offer path and hands off again as the newest
        // entry, and the budget then sheds the next-oldest.
        let returning = candidates[0]
        try await returning.store(storer: broker)
        try await store.persistContextualCandidateRoots(
            candidateCID: returning.rawCID,
            roots: [returning.rawCID],
            capacity: 16
        )
        let readmitted = try await store.beginContextualCandidateHandoff(
            candidateCID: returning.rawCID
        )
        XCTAssertTrue(readmitted)
        let afterReturn = try await store.contextualCandidateVolumeRoots()
        XCTAssertEqual(
            Set(afterReturn),
            Set([candidates[2].rawCID, returning.rawCID])
        )
        try await store.auditNormalizedIndexes()
    }

    func testParentEvidenceScanAndInboxSurviveCrashUntilAdmissionOwnsVolume()
        async throws
    {
        let directory = temporaryDirectory()
        let parentBroker = try DiskBroker(
            path: directory.appendingPathComponent("parent-volumes.db").path
        )
        let childBroker = try DiskBroker(
            path: directory.appendingPathComponent("child-volumes.db").path
        )
        let parent = try makeStore(
            path: directory.appendingPathComponent("parent.db"),
            broker: parentBroker
        )
        let fixture = try await childProofFixture()
        try await persistIssuedChildProof(
            in: parent,
            fixture.first,
            childCID: fixture.childCID
        )
        try await parent.stage(
            blockBatch(
                postStateCID: "state",
                blockHash: fixture.first.rootCID
            ),
            volumeRoots: [],
            hierarchyArtifacts: AdmissionHierarchyArtifacts(
                carrierLink: try decode(ParentCarrierLink.self, json: """
                    {"parentPath":["Nexus"],"carrierCID":"\(fixture.first.rootCID)","rootCID":"\(fixture.first.rootCID)"}
                """),
                carrierEvidence: nil,
                parentGenesisLinks: [try decode(
                    ParentGenesisLink.self,
                    json: """
                    {"parentPath":["Nexus"],"directory":"Child","childGenesisCID":"\(fixture.childCID)","parentStateCID":"parent-state"}
                    """
                )]
            )
        )
        let scan = try await parent.issuedChildEvidenceScanHead(
            directory: "Child"
        )
        try await persistIssuedChildProof(
            in: parent,
            fixture.second,
            childCID: fixture.childCID
        )
        let page = try await parent.issuedChildEvidenceSummaries(
            directory: "Child",
            afterOrdinal: 0,
            throughOrdinal: scan.throughOrdinal,
            limit: 2
        )
        let summary = try XCTUnwrap(page.first)
        XCTAssertEqual(summary.ordinal, scan.throughOrdinal)
        XCTAssertEqual(page.count, 1)
        let advancedScan = try await parent.issuedChildEvidenceScanHead(
            directory: "Child"
        )
        XCTAssertGreaterThan(advancedScan.throughOrdinal, scan.throughOrdinal)

        let storedIssued = try await parent.issuedChildEvidence(
            childCID: fixture.childCID,
            directory: "Child",
            rootCID: fixture.first.rootCID
        )
        let issued = try XCTUnwrap(storedIssued)
        let package = AuthenticatedChildPackage(
            package: ChildValidationPackage(proof: issued.proof)
        )
        let attachment = try ChildEvidenceVolume(
            envelopeBytes: try ChildValidationPackageEnvelope(
                package.package
            ).encode(),
            childCID: fixture.childCID
        )
        let storedSecondIssued = try await parent.issuedChildEvidence(
            childCID: fixture.childCID,
            directory: "Child",
            rootCID: fixture.second.rootCID
        )
        let secondIssued = try XCTUnwrap(storedSecondIssued)
        let secondPackage = AuthenticatedChildPackage(
            package: ChildValidationPackage(proof: secondIssued.proof)
        )
        let secondAttachment = try ChildEvidenceVolume(
            envelopeBytes: try ChildValidationPackageEnvelope(
                secondPackage.package
            ).encode(),
            childCID: fixture.childCID
        )
        let childPath = directory.appendingPathComponent("child.db")
        var child: NodeStore? = try makeStore(
            path: childPath,
            chainPath: ["Nexus", "Child"],
            broker: childBroker,
            parentEvidenceInboxCapacity: 1
        )
        try await child!.storeParentEvidenceInbox(
            sourceID: scan.sourceID,
            ordinal: summary.ordinal,
            attachment: attachment,
            package: package,
            advanceScan: false
        )
        let liveCursor = try await child!.parentEvidenceScanCursor()
        XCTAssertEqual(
            liveCursor,
            ParentEvidenceScanCursor(sourceID: nil, ordinal: 0)
        )
        try await child!.storeParentEvidenceInbox(
            sourceID: scan.sourceID,
            ordinal: summary.ordinal,
            attachment: attachment,
            package: package,
            advanceScan: true
        )
        let scannedCursor = try await child!.parentEvidenceScanCursor()
        XCTAssertEqual(
            scannedCursor,
            ParentEvidenceScanCursor(
                sourceID: scan.sourceID,
                ordinal: summary.ordinal
            )
        )

        child = nil
        child = try makeStore(
            path: childPath,
            chainPath: ["Nexus", "Child"],
            broker: childBroker,
            parentEvidenceInboxCapacity: 1
        )
        let recoveredInbox = try await child!.parentEvidenceInbox()
        XCTAssertEqual(recoveredInbox.count, 1)
        let retainedBeforeAdmission = try await childBroker.retainedRoots(
            scope: "parent-evidence-inbox"
        )
        XCTAssertEqual(
            retainedBeforeAdmission,
            [attachment.rawCID]
        )
        do {
            try await child!.storeParentEvidenceInbox(
                sourceID: scan.sourceID,
                ordinal: advancedScan.throughOrdinal,
                attachment: secondAttachment,
                package: secondPackage,
                advanceScan: true
            )
            XCTFail("a full inbox advanced past unstored parent evidence")
        } catch {
            XCTAssertEqual(
                error as? NodeStoreError,
                .parentEvidenceInboxFull
            )
        }
        let backpressuredCursor = try await child!
            .parentEvidenceScanCursor()
        XCTAssertEqual(backpressuredCursor, scannedCursor)
        let rejectedVolume = await childBroker.fetchVolumeLocal(
            root: secondAttachment.rawCID
        )
        XCTAssertNil(rejectedVolume)

        try await child!.stage(
            blockBatch(
                postStateCID: testCID("child-post-state"),
                blockHash: fixture.childCID
            ),
            volumeRoots: [],
            incomingCarrierEvidence: AdmissionCarrierEvidence(
                proof: package.package.proof,
                childCID: fixture.childCID
            )
        )
        let admittedInbox = try await child!.parentEvidenceInbox()
        XCTAssertTrue(admittedInbox.isEmpty)
        let retainedAfterAdmission = try await childBroker.retainedRoots(
            scope: "parent-evidence-inbox"
        )
        XCTAssertTrue(retainedAfterAdmission.isEmpty)
        let admittedVolume = await childBroker.fetchVolumeLocal(
            root: attachment.rawCID
        )
        XCTAssertNotNil(admittedVolume)

        let rebuiltParentSourceID =
            "00000000-0000-4000-8000-000000000002"
        try await child!.storeParentEvidenceInbox(
            sourceID: rebuiltParentSourceID,
            ordinal: summary.ordinal,
            attachment: attachment,
            package: package,
            advanceScan: true
        )
        let rebuiltParentCursor =
            try await child!.parentEvidenceScanCursor()
        XCTAssertEqual(
            rebuiltParentCursor,
            ParentEvidenceScanCursor(
                sourceID: rebuiltParentSourceID,
                ordinal: summary.ordinal
            )
        )
        let replayedInbox = try await child!.parentEvidenceInbox()
        XCTAssertTrue(replayedInbox.isEmpty)
        let replayedInboxRoots = try await childBroker.retainedRoots(
            scope: "parent-evidence-inbox"
        )
        XCTAssertTrue(replayedInboxRoots.isEmpty)

        try await child!.storeParentEvidenceInbox(
            sourceID: rebuiltParentSourceID,
            ordinal: advancedScan.throughOrdinal,
            attachment: secondAttachment,
            package: secondPackage,
            advanceScan: true
        )
        let pendingSecondInbox = try await child!.parentEvidenceInbox()
        let retainedSecondInbox = try await childBroker.retainedRoots(
            scope: "parent-evidence-inbox"
        )
        XCTAssertEqual(pendingSecondInbox.count, 1)
        XCTAssertEqual(
            retainedSecondInbox,
            [secondAttachment.rawCID]
        )

        let childCarrierLink = try decode(ParentCarrierLink.self, json: """
            {"parentPath":["Nexus","Child"],"carrierCID":"\(fixture.childCID)","rootCID":"\(fixture.second.rootCID)"}
            """)
        try await child!.persistIssuedHierarchyArtifacts(
            AdmissionHierarchyArtifacts(
                carrierLink: childCarrierLink,
                carrierEvidence: AdmissionCarrierEvidence(
                    proof: secondPackage.package.proof,
                    childCID: fixture.childCID
                ),
                parentGenesisLinks: []
            )
        )

        let issuedSecondInbox = try await child!.parentEvidenceInbox()
        let retainedIssuedSecondInbox = try await childBroker.retainedRoots(
            scope: "parent-evidence-inbox"
        )
        let incomingSecondEvidence =
            try await child!.incomingCarrierEvidence(
                childCID: fixture.childCID,
                directory: "Child",
                rootCID: fixture.second.rootCID
            )
        let retainedSecondVolume = await childBroker.fetchVolumeLocal(
            root: secondAttachment.rawCID
        )
        XCTAssertTrue(issuedSecondInbox.isEmpty)
        XCTAssertTrue(retainedIssuedSecondInbox.isEmpty)
        XCTAssertEqual(
            incomingSecondEvidence?.attachmentCID,
            secondAttachment.rawCID
        )
        XCTAssertNotNil(retainedSecondVolume)
    }

    func testContextualCandidateProtectsPreparedDescendantProofAtCapacity()
        async throws
    {
        let directory = temporaryDirectory()
        let broker = try DiskBroker(
            path: directory.appendingPathComponent("volumes.db").path
        )
        var store: NodeStore? = try makeStore(
            path: directory.appendingPathComponent("state.db"),
            broker: broker
        )
        let fixture = try await childProofFixture()
        let first = try PreparedChildProof(
            directory: "Child",
            childCID: fixture.childCID,
            isChildGenesis: true,
            proof: fixture.first
        )
        let second = try PreparedChildProof(
            directory: "Child",
            childCID: fixture.childCID,
            isChildGenesis: true,
            proof: fixture.second
        )
        for volume in fixture.rootVolumes {
            try await broker.store(volume: volume)
        }

        try await store!.persistContextualCandidateRoots(
            candidateCID: fixture.first.rootCID,
            roots: [fixture.first.rootCID],
            capacity: 1
        )
        try await store!.persistPreparedChildProofs(
            carrierCID: fixture.first.rootCID,
            proofs: [first],
            capacity: 1
        )
        try await store!.persistContextualCandidateRoots(
            candidateCID: fixture.second.rootCID,
            roots: [fixture.second.rootCID],
            capacity: 1
        )
        try await store!.persistPreparedChildProofs(
            carrierCID: fixture.second.rootCID,
            proofs: [second],
            capacity: 1
        )
        store = nil
        store = try makeStore(
            path: directory.appendingPathComponent("state.db"),
            broker: broker
        )
        let evicted = try await store!.preparedChildProofs(
            carrierCID: fixture.first.rootCID
        )
        XCTAssertTrue(evicted.isEmpty)
        let retained = try await store!.preparedChildProofs(
            carrierCID: fixture.second.rootCID
        )
        XCTAssertEqual(retained.map(\.directory), ["Child"])
    }

    func testAcceptedPendingCarrierProtectsPreparedProofAtCapacity()
        async throws
    {
        let directory = temporaryDirectory()
        let broker = try DiskBroker(
            path: directory.appendingPathComponent("volumes.db").path
        )
        let path = directory.appendingPathComponent("state.db")
        var store: NodeStore? = try makeStore(path: path, broker: broker)
        let candidate = try await childProofFixture(childTimestamp: 1)
        let admitted = try await childProofFixture(childTimestamp: 10)
        for volume in candidate.rootVolumes + admitted.rootVolumes
            + [candidate.childVolume, admitted.childVolume] {
            try await broker.store(volume: volume)
        }

        try await store!.persistPreparedChildProofs(
            carrierCID: candidate.first.rootCID,
            proofs: [try PreparedChildProof(
                directory: "Child",
                childCID: candidate.childCID,
                isChildGenesis: true,
                bootstrapRoots: [candidate.childCID],
                proof: candidate.first
            )],
            capacity: 1
        )
        try await store!.persistContextualCandidateRoots(
            candidateCID: candidate.first.rootCID,
            roots: [candidate.first.rootCID],
            capacity: 1
        )

        try await store!.stage(
            blockBatch(
                postStateCID: "admitted-state",
                blockHash: admitted.first.rootCID
            ),
            volumeRoots: [admitted.first.rootCID],
            pendingChildProofRoutes: [PendingChildProofRoute(
                carrierCID: admitted.first.rootCID,
                directory: "Child"
            )]
        )
        try await store!.persistPreparedChildProofs(
            carrierCID: admitted.first.rootCID,
            proofs: [try PreparedChildProof(
                directory: "Child",
                childCID: admitted.childCID,
                isChildGenesis: true,
                bootstrapRoots: [admitted.childCID],
                proof: admitted.first
            )],
            capacity: 1
        )

        store = nil
        store = try makeStore(path: path, broker: broker)
        let candidateProofs = try await store!.preparedChildProofs(
            carrierCID: candidate.first.rootCID
        )
        let admittedProofs = try await store!.preparedChildProofs(
            carrierCID: admitted.first.rootCID
        )
        XCTAssertEqual(candidateProofs.map(\.directory), ["Child"])
        XCTAssertEqual(admittedProofs.map(\.directory), ["Child"])
        XCTAssertEqual(admittedProofs.first?.bootstrapRoots, [admitted.childCID])

        _ = try await broker.evictUnpinned(graceSeconds: 0)
        let admittedChild = await broker.fetchVolumeLocal(
            root: admitted.childCID
        )
        XCTAssertNotNil(admittedChild)
    }

    private func makeStore(
        path: URL? = nil,
        genesisCID: String? = nil,
        chainPath: [String] = ["Nexus"],
        broker suppliedBroker: (any RetainedRootMergeBroker)? = nil,
        parentEvidenceInboxCapacity: Int = 64,
        handoffCandidateCapacity: Int = 1_024
    ) throws -> NodeStore {
        let path = path ?? temporaryDirectory().appendingPathComponent("state.db")
        let broker: any RetainedRootMergeBroker
        if let suppliedBroker {
            broker = suppliedBroker
        } else {
            broker = try DiskBroker(
                path: path.deletingLastPathComponent()
                    .appendingPathComponent("volumes.db").path
            )
        }
        return try NodeStore(
            databasePath: path,
            nexusGenesisCID: genesisCID ?? self.genesisCID,
            chainPath: chainPath,
            recoveryVolumeBroker: broker,
            issuedRecoveryRetentionScope: "test:issued-hierarchy",
            preparedRecoveryRetentionScope: "test:prepared-hierarchy",
            parentEvidenceInboxCapacity: parentEvidenceInboxCapacity,
            contextualCandidateOwner: "test:contextual-candidates",
            handoffCandidateCapacity: handoffCandidateCapacity
        )
    }

    private func persistIssuedChildProof(
        in store: NodeStore,
        _ proof: ChildBlockProof,
        childCID: String,
        isChildGenesis: Bool = true,
        bootstrapRoots: [String]? = nil,
        parentCarrierCID: String? = nil
    ) async throws {
        let envelope = try ChildValidationPackageEnvelope(
            ChildValidationPackage(proof: proof)
        )
        try await store.persistIssuedChildProof(
            proof,
            childCID: childCID,
            isChildGenesis: isChildGenesis,
            bootstrapRoots: bootstrapRoots ?? [],
            parentCarrierCID: parentCarrierCID,
            rootEnvelope: envelope
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-node-store-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func blockBatch(
        postStateCID: String,
        blockHash: String = "same-block",
        parentBlockHash: String? = nil,
        blockHeight: UInt64 = 0
    ) -> ChainAdmissionBatch {
        ChainAdmissionBatch(facts: [
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
        let content = TestContentStore()
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

private actor RecordingVolumeStorer: VolumeStorer {
    private var roots: [String] = []

    func store(volume: SerializedVolume) async throws {
        roots.append(volume.root)
    }

    func storedRoots() -> [String] {
        roots
    }
}

private actor TestContentStore: Fetcher, Storer, VolumeStorer {
    private var entries: [String: Data] = [:]
    private var volumes: [String: SerializedVolume] = [:]

    func fetch(rawCid: String) throws -> Data {
        guard let data = entries[rawCid] else { throw FetcherError.notFound(rawCid) }
        return data
    }

    func store(entries: [String: Data]) {
        self.entries.merge(entries) { existing, _ in existing }
    }

    func store(volume: SerializedVolume) {
        entries.merge(volume.entries) { existing, _ in existing }
        volumes[volume.root] = volume
    }

    func allEntries() -> [String: Data] { entries }
    func volume(root: String) -> SerializedVolume? { volumes[root] }
}

private actor BlockingVolumeBroker: RetainedRootMergeBroker {
    nonisolated let near: (any VolumeBroker)? = nil
    nonisolated let far: (any VolumeBroker)? = nil

    private let broker: DiskBroker
    private var stores = 0
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(broker: DiskBroker) {
        self.broker = broker
    }

    func hasVolume(root: String) async -> Bool {
        await broker.hasVolume(root: root)
    }

    func fetchVolumeLocal(root: String) async -> SerializedVolume? {
        await broker.fetchVolumeLocal(root: root)
    }

    func storeVolumesLocal(_ volumes: [SerializedVolume]) async throws {
        let shouldBlock = stores == 0 && !volumes.isEmpty
        stores += volumes.count
        if shouldBlock {
            enteredWaiters.forEach { $0.resume() }
            enteredWaiters.removeAll()
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        try await broker.storeVolumesLocal(volumes)
    }

    func pin(
        root: String,
        owner: String,
        count: Int,
        ttl: Duration?
    ) async throws {
        try await broker.pin(root: root, owner: owner, count: count, ttl: ttl)
    }

    func unpin(root: String, owner: String, count: Int) async throws {
        try await broker.unpin(root: root, owner: owner, count: count)
    }

    func unpinAll(owner: String) async throws {
        try await broker.unpinAll(owner: owner)
    }

    func owners(root: String) async -> Set<String> {
        await broker.owners(root: root)
    }

    func evictUnpinned() async throws -> Int {
        try await broker.evictUnpinned()
    }

    func advanceRetainedRoots(scope: String, roots: [String]) async throws {
        try await broker.advanceRetainedRoots(scope: scope, roots: roots)
    }

    func retainedRoots(scope: String) async throws -> [String] {
        try await broker.retainedRoots(scope: scope)
    }

    func mergeRetainedRoots(scope: String, roots: [String]) async throws {
        try await broker.mergeRetainedRoots(scope: scope, roots: roots)
    }

    func waitUntilFirstStore() async {
        guard stores == 0 else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func releaseFirstStore() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func storeCount() -> Int {
        stores
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
