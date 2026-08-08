import Foundation
import Ivy
import Lattice
import UInt256
import VolumeBroker
import cashew

enum NodeStoreError: Error, Equatable, LocalizedError {
    case invalidConfiguration(String)
    case wipeRequired(String)
    case conflictingAdmissionFact
    case conflictingAdmissionBatch
    case conflictingIssuedParentFact
    case conflictingIssuedChildProof
    case invalidIssuedChildProof(String)
    case parentEvidenceInboxFull
    case corrupt(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let reason):
            "Invalid node store configuration: \(reason)"
        case .wipeRequired(let reason):
            "The node store is incompatible (\(reason)); stop the process, delete its entire configured storage directory (state.db and volumes.db), and restart."
        case .conflictingAdmissionFact:
            "Conflicting bytes for an immutable chain fact."
        case .conflictingAdmissionBatch:
            "An admission batch was replayed with different Volume roots."
        case .conflictingIssuedParentFact:
            "A locally issued parent fact was replayed with different bytes."
        case .conflictingIssuedChildProof:
            "A locally issued child proof was replayed with different bytes."
        case .invalidIssuedChildProof(let childCID):
            "The proof cached for child \(childCID) does not prove that child from this chain path."
        case .parentEvidenceInboxFull:
            "The pending parent-evidence inbox is full."
        case .corrupt(let reason):
            "The node store is corrupt: \(reason)"
        }
    }
}

struct StagedAdmission: Sendable, Equatable {
    let sequence: Int64
    let batch: ChainAdmissionBatch
    let volumeRoots: [String]
}

public struct ChildCandidateReservationReference: Hashable, Sendable {
    public let peerKey: PeerKey
    public let candidateCID: String

    public init(peerKey: PeerKey, candidateCID: String) {
        self.peerKey = peerKey
        self.candidateCID = candidateCID
    }
}

public struct ChildCandidateReservationUpdate: Sendable {
    public let reservations: [ChildCandidateReservationReference]
    public let handoffs: [ChildCandidateReservationReference]

    public init(
        reservations: [ChildCandidateReservationReference],
        handoffs: [ChildCandidateReservationReference] = []
    ) {
        self.reservations = reservations
        self.handoffs = handoffs
    }
}

struct LocalMempoolTransactionRecord: Sendable, Equatable {
    let transactionCID: String
    let addedAt: Int64
}

struct AcceptedLeafPage: Sendable, Equatable {
    let snapshotSequence: Int64
    let blockCIDs: [String]
}

struct IssuedChildEvidence: Sendable {
    let edgeCID: String
    let attachmentCID: String
    let edge: DirectChildEdge
    let proof: ChildBlockProof
}

/// Evidence verified by Lattice that the node must commit with the admission
/// batch that made it issuable. The proof package is optional for Nexus, where
/// the carrier is its own root.
struct AdmissionCarrierEvidence: Sendable {
    let proof: ChildBlockProof
    let childCID: String

    init(
        proof: ChildBlockProof,
        childCID: String
    ) {
        self.proof = proof
        self.childCID = childCID
    }
}

/// Hierarchy facts produced by Lattice at the same boundary as an accepted
/// admission. They remain separate from chain facts because replay does not
/// need them, but NodeStore commits both in one SQLite transaction.
struct AdmissionHierarchyArtifacts: Sendable {
    let carrierLink: ParentCarrierLink
    let carrierEvidence: AdmissionCarrierEvidence?
    let parentGenesisLinks: [ParentGenesisLink]
}

struct IssuedChildEvidenceSummary: Codable, Equatable, Hashable, Sendable {
    let ordinal: UInt64
    let childCID: String
    let rootCID: String
    let attachmentCID: String
}

struct ParentEvidenceScanCursor: Equatable, Sendable {
    let sourceID: String?
    let ordinal: UInt64
}

struct ParentEvidenceInboxItem: Sendable {
    let sourceID: String
    let ordinal: UInt64
    let attachment: ChildEvidenceVolume
    let package: AuthenticatedChildPackage
}

struct ChildRootAttachmentSummary: Equatable, Hashable, Sendable {
    let edgeCID: String
    let rootCID: String
    let attachmentCID: String
}

struct PreparedChildProof: Sendable {
    let directory: String
    let childCID: String
    let isChildGenesis: Bool
    let bootstrapRoots: [String]
    let proof: ChildBlockProof

    init(
        directory: String,
        childCID: String,
        isChildGenesis: Bool,
        bootstrapRoots: [String] = [],
        proof: ChildBlockProof
    ) throws {
        self.directory = directory
        self.childCID = childCID
        self.isChildGenesis = isChildGenesis
        self.bootstrapRoots = bootstrapRoots
        self.proof = proof
    }
}

struct PendingChildProofRoute: Sendable, Hashable {
    let carrierCID: String
    let directory: String
}

private struct PreparedAdmissionCarrierEvidence {
    let edge: DirectChildEdge
    let rootCID: String
    let proofAttachment: ChildEvidenceVolume
}

private struct PreparedAdmissionHierarchyArtifacts {
    let carrierLink: ParentCarrierLink
    let carrierLinkPayload: Data
    let carrierEvidence: PreparedAdmissionCarrierEvidence?
    let parentGenesisLinks: [(link: ParentGenesisLink, payload: Data)]
}

private struct PersistedParentFactSource: Codable {
    let carrierLink: ParentCarrierLink
    let parentGenesisLinks: [ParentGenesisLink]
}

private struct IssuedParentFactKey: Hashable {
    let kind: String
    let keyA: String
    let keyB: String
}

private struct AcceptedBlockRecord: Hashable {
    let blockCID: String
    let parentCID: String?
}

private struct PersistedAcceptedBlock: Hashable {
    let blockCID: String
    let parentCID: String?
    let admissionSequence: Int64
}

enum IssuedChildProofScope: String, Sendable {
    case incomingCarrier = "incoming_carrier"
    case outgoingDirectChild = "outgoing_direct_child"
}

/// Node-owned immutable facts and availability indexes for one absolute path.
actor NodeStore {
    /// Epoch 38 makes issued and handed-off contextual candidates mutually
    /// exclusive and gives each handoff an age for budgeted eviction.
    /// Older stores must be
    /// wiped; Nexus deterministically recreates the configured exact genesis.
    static let currentSchemaEpoch: Int64 = 38

    private static func parentGenesisFactKey(
        _ link: ParentGenesisLink
    ) -> String {
        parentGenesisFactKey(
            childGenesisCID: link.childGenesisCID,
            parentStateCID: link.parentStateCID
        )
    }

    private static func parentGenesisFactKey(
        childGenesisCID: String,
        parentStateCID: String
    ) -> String {
        "\(parentStateCID.utf8.count):\(parentStateCID)\(childGenesisCID)"
    }

    private let database: NodeSQLite
    private let nexusGenesisCID: String
    private let chainPath: [String]
    private let recoveryVolumeBroker: any RetainedRootMergeBroker
    private let issuedRecoveryRetentionScope: String
    private let preparedRecoveryRetentionScope: String
    private let parentEvidenceInboxRetentionScope: String
    private let parentEvidenceInboxCapacity: Int
    private let handoffCandidateCapacity: Int
    private let contextualCandidateOwner: String
    private var preparedMutationInFlight = false
    private var preparedMutationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        databasePath: URL,
        nexusGenesisCID: String,
        chainPath: [String],
        recoveryVolumeBroker: any RetainedRootMergeBroker,
        issuedRecoveryRetentionScope: String,
        preparedRecoveryRetentionScope: String,
        parentEvidenceInboxRetentionScope: String = "parent-evidence-inbox",
        parentEvidenceInboxCapacity: Int = 64,
        contextualCandidateOwner: String,
        handoffCandidateCapacity: Int = 1_024
    ) throws {
        guard !nexusGenesisCID.isEmpty else {
            throw NodeStoreError.invalidConfiguration("Nexus genesis CID is empty")
        }
        guard chainPath.first == "Nexus", chainPath.allSatisfy({ !$0.isEmpty }) else {
            throw NodeStoreError.invalidConfiguration("chainPath must be absolute and begin with Nexus")
        }
        guard !issuedRecoveryRetentionScope.isEmpty,
              !preparedRecoveryRetentionScope.isEmpty,
              !parentEvidenceInboxRetentionScope.isEmpty,
              parentEvidenceInboxCapacity > 0,
              handoffCandidateCapacity > 0,
              issuedRecoveryRetentionScope != preparedRecoveryRetentionScope,
              issuedRecoveryRetentionScope != parentEvidenceInboxRetentionScope,
              preparedRecoveryRetentionScope != parentEvidenceInboxRetentionScope,
              !contextualCandidateOwner.isEmpty else {
            throw NodeStoreError.invalidConfiguration(
                "hierarchy retention scopes must be nonempty and distinct"
            )
        }
        let database = try NodeSQLite(path: databasePath.path)
        let pathData = try Self.encode(chainPath)
        let tables = try database.query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
        )
        let tableNames = Set(tables.compactMap { $0["name"]?.textValue })

        if tableNames.isEmpty {
            try Self.createSchema(
                in: database,
                schemaEpoch: Self.currentSchemaEpoch,
                nexusGenesisCID: nexusGenesisCID,
                chainPath: pathData
            )
        } else {
            try Self.validateMetadata(
                in: database,
                tableNames: tableNames,
                schemaEpoch: Self.currentSchemaEpoch,
                nexusGenesisCID: nexusGenesisCID,
                chainPath: pathData
            )
            guard tableNames == Self.expectedTables else {
                throw NodeStoreError.wipeRequired("schema tables are missing or unexpected")
            }
        }
        try database.configureDurability()

        self.database = database
        self.nexusGenesisCID = nexusGenesisCID
        self.chainPath = chainPath
        self.recoveryVolumeBroker = recoveryVolumeBroker
        self.issuedRecoveryRetentionScope = issuedRecoveryRetentionScope
        self.preparedRecoveryRetentionScope = preparedRecoveryRetentionScope
        self.parentEvidenceInboxRetentionScope =
            parentEvidenceInboxRetentionScope
        self.parentEvidenceInboxCapacity = parentEvidenceInboxCapacity
        self.contextualCandidateOwner = contextualCandidateOwner
        self.handoffCandidateCapacity = handoffCandidateCapacity
    }

    private func acquirePreparedMutation() async {
        guard preparedMutationInFlight else {
            preparedMutationInFlight = true
            return
        }
        await withCheckedContinuation { continuation in
            preparedMutationWaiters.append(continuation)
        }
    }

    private func releasePreparedMutation() {
        guard !preparedMutationWaiters.isEmpty else {
            preparedMutationInFlight = false
            return
        }
        preparedMutationWaiters.removeFirst().resume()
    }

    private func mergeRecoveryRetention(
        scope: String,
        roots: [String]
    ) async throws {
        guard !roots.isEmpty else { return }
        try await recoveryVolumeBroker.mergeRetainedRoots(
            scope: scope,
            roots: roots
        )
    }

    private func reconcilePreparedRecoveryRetention() async throws {
        try await recoveryVolumeBroker.advanceRetainedRoots(
            scope: preparedRecoveryRetentionScope,
            roots: preparedRecoveryVolumeRoots()
        )
    }

    func stage(
        _ batch: ChainAdmissionBatch,
        volumeRoots: [String],
        pendingChildProofRoutes: [PendingChildProofRoute] = [],
        pendingChildProofCapacity: Int = 16,
        hierarchyArtifacts: AdmissionHierarchyArtifacts? = nil,
        incomingCarrierEvidence: AdmissionCarrierEvidence? = nil,
        consensusRevisionFloor: UInt64? = nil
    ) async throws {
        let payload = try Self.encode(batch)
        let factsInBatch = try Self.normalizedFacts(in: batch)
        let facts = factsInBatch.sorted { $0.key.lexicographicallyPrecedes($1.key) }
        let acceptedBlocks = try Self.acceptedBlocks(in: batch)
        let pendingRoutes = Array(Set(pendingChildProofRoutes)).sorted {
            ($0.carrierCID, $0.directory) < ($1.carrierCID, $1.directory)
        }
        let carrierCIDs = Set(batch.facts.map { fact -> String in
            switch fact {
            case .block(let block): block.blockHash
            case .work(let work): work.blockHash
            }
        })
        guard pendingRoutes.allSatisfy({
            carrierCIDs.contains($0.carrierCID) && !$0.directory.isEmpty
        }) else {
            throw NodeStoreError.invalidConfiguration(
                "pending child-proof route is outside its admission batch"
            )
        }
        let preparedHierarchyArtifacts = try await prepareHierarchyArtifacts(
            hierarchyArtifacts,
            carrierCIDs: carrierCIDs
        )
        let preparedIncomingCarrierEvidence: PreparedAdmissionCarrierEvidence?
        if let incomingCarrierEvidence {
            preparedIncomingCarrierEvidence = try await prepareCarrierEvidence(
                incomingCarrierEvidence,
                expectedChildCIDs: carrierCIDs,
                expectedRootCID: nil
            )
        } else {
            preparedIncomingCarrierEvidence = nil
        }
        let recoveryRoots = try await storeRecoveryEvidence(
            [preparedHierarchyArtifacts?.carrierEvidence,
             preparedIncomingCarrierEvidence].compactMap { $0 }
        )
        let rootsPayload = try Self.encode(Array(Set(volumeRoots)).sorted())

        try await mergeRecoveryRetention(
            scope: issuedRecoveryRetentionScope,
            roots: recoveryRoots
        )
        try database.transaction {
                for fact in facts {
                    let rows = try database.query(
                        "SELECT payload FROM admission_facts WHERE fact_id = ?1",
                        params: [.blob(fact.key)]
                    )
                    if let existing = rows.first?["payload"]?.blobValue {
                        guard existing == fact.value else {
                            throw NodeStoreError.conflictingAdmissionFact
                        }
                    }
                }

                let replay = try database.query(
                    "SELECT seq, volume_roots FROM admission_batches WHERE payload = ?1",
                    params: [.blob(payload)]
                )
                if let existing = replay.first,
                   let existingSequence = existing["seq"]?.intValue,
                   let existingRoots = existing["volume_roots"]?.blobValue {
                    guard existingRoots == rootsPayload else {
                        throw NodeStoreError.conflictingAdmissionBatch
                    }
                    for fact in facts {
                        let rows = try database.query(
                            "SELECT payload FROM admission_facts WHERE fact_id = ?1",
                            params: [.blob(fact.key)]
                        )
                        guard rows.first?["payload"]?.blobValue == fact.value else {
                            throw NodeStoreError.corrupt(
                                "an admission batch is missing its normalized fact"
                            )
                        }
                    }
                    try validateAcceptedBlockRows(
                        acceptedBlocks,
                        admissionSequence: existingSequence
                    )
                } else {
                    try database.execute(
                        "INSERT INTO admission_batches (payload, volume_roots) VALUES (?1, ?2)",
                        params: [.blob(payload), .blob(rootsPayload)]
                    )
                    guard let admissionSequence = try database.query(
                        "SELECT seq FROM admission_batches WHERE payload = ?1",
                        params: [.blob(payload)]
                    ).first?["seq"]?.intValue else {
                        throw NodeStoreError.corrupt("missing newly staged admission batch")
                    }
                    for fact in facts {
                        try database.execute(
                            "INSERT OR IGNORE INTO admission_facts (fact_id, payload) VALUES (?1, ?2)",
                            params: [.blob(fact.key), .blob(fact.value)]
                        )
                    }
                    try persistAcceptedBlockRows(
                        acceptedBlocks,
                        admissionSequence: admissionSequence
                    )
                }
                if let preparedHierarchyArtifacts {
                    try persistHierarchyArtifacts(preparedHierarchyArtifacts)
                }
                if let preparedIncomingCarrierEvidence {
                    try persistCarrierEvidence(preparedIncomingCarrierEvidence)
                }
                let admittedParentAttachments = [
                    preparedHierarchyArtifacts?.carrierEvidence?
                        .proofAttachment.rawCID,
                    preparedIncomingCarrierEvidence?.proofAttachment.rawCID,
                ].compactMap { $0 }
                for attachmentCID in Set(admittedParentAttachments) {
                    try database.execute(
                        "DELETE FROM parent_evidence_inbox WHERE attachment_cid = ?1",
                        params: [.text(attachmentCID)]
                    )
                }
                try persistPendingChildProofRouteRows(
                    try pendingRoutesIncludingPreparedProofs(
                        pendingRoutes,
                        carrierCIDs: Set(acceptedBlocks.map(\.blockCID))
                    ),
                    capacity: pendingChildProofCapacity
                )
                if let consensusRevisionFloor {
                    try persistConsensusRevisionFloor(consensusRevisionFloor)
                }
        }
        if preparedHierarchyArtifacts?.carrierEvidence != nil
            || preparedIncomingCarrierEvidence != nil
        {
            try? await recoveryVolumeBroker.advanceRetainedRoots(
                scope: parentEvidenceInboxRetentionScope,
                roots: parentEvidenceInboxRoots()
            )
        }
    }

    func stagedAdmissions() async throws -> [StagedAdmission] {
        try loadStagedAdmissions()
    }

    func consensusRevisionFloor() throws -> UInt64 {
        let rows = try database.query(
            "SELECT revision FROM consensus_revision WHERE singleton = 1"
        )
        guard rows.count == 1,
              let revision = rows[0]["revision"]?.textValue,
              let value = UInt64(revision) else {
            throw NodeStoreError.corrupt("malformed consensus revision floor")
        }
        return value
    }

    func advanceConsensusRevisionFloor(_ floor: UInt64) throws {
        try database.transaction {
            try persistConsensusRevisionFloor(floor)
        }
    }

    private func persistConsensusRevisionFloor(_ floor: UInt64) throws {
        let current = try consensusRevisionFloor()
        guard floor > current else { return }
        try database.execute(
            "UPDATE consensus_revision SET revision = ?1 WHERE singleton = 1",
            params: [.text(String(floor))]
        )
    }

    func persistLocalMempoolTransaction(
        transactionCID: String,
        addedAt: Int64
    ) throws {
        guard CIDIdentity.isCanonical(transactionCID), addedAt >= 0 else {
            throw NodeStoreError.invalidConfiguration(
                "local mempool transaction reference is malformed"
            )
        }
        try database.execute(
            "INSERT OR IGNORE INTO local_mempool_transactions (transaction_cid, added_at) VALUES (?1, ?2)",
            params: [.text(transactionCID), .int(addedAt)]
        )
    }

    func removeLocalMempoolTransaction(transactionCID: String) throws {
        guard CIDIdentity.isCanonical(transactionCID) else {
            throw NodeStoreError.invalidConfiguration(
                "local mempool transaction CID is malformed"
            )
        }
        try database.execute(
            "DELETE FROM local_mempool_transactions WHERE transaction_cid = ?1",
            params: [.text(transactionCID)]
        )
    }

    func localMempoolTransactions() throws -> [LocalMempoolTransactionRecord] {
        try database.query(
            "SELECT transaction_cid, added_at FROM local_mempool_transactions ORDER BY added_at, transaction_cid"
        ).map { row in
            guard let transactionCID = row["transaction_cid"]?.textValue,
                  let addedAt = row["added_at"]?.intValue,
                  CIDIdentity.isCanonical(transactionCID),
                  addedAt >= 0 else {
                throw NodeStoreError.corrupt(
                    "malformed local mempool transaction reference"
                )
            }
            return LocalMempoolTransactionRecord(
                transactionCID: transactionCID,
                addedAt: addedAt
            )
        }
    }

    /// Stable pagination over the accepted forest's leaves. The first call
    /// captures the current admission sequence; later calls reuse it so newly
    /// admitted descendants cannot reshuffle an in-progress page walk.
    func acceptedLeafPage(
        afterCID: String?,
        snapshotSequence: Int64?,
        limit: Int
    ) throws -> AcceptedLeafPage {
        guard limit > 0, let sqlLimit = Int64(exactly: limit) else {
            throw NodeStoreError.invalidConfiguration(
                "accepted-leaf page limit must be positive"
            )
        }
        let currentSequence = try database.query(
            "SELECT COALESCE(MAX(seq), 0) AS sequence FROM admission_batches"
        ).first?["sequence"]?.intValue ?? 0
        let snapshot = snapshotSequence ?? currentSequence
        guard snapshot >= 0, snapshot <= currentSequence else {
            throw NodeStoreError.invalidConfiguration(
                "accepted-leaf snapshot is outside durable admission history"
            )
        }

        let rows: [[String: NodeSQLiteValue]]
        if let afterCID {
            rows = try database.query(
                "SELECT block_cid FROM accepted_blocks AS block WHERE block.admission_seq <= ?1 AND block.block_cid > ?2 AND NOT EXISTS (SELECT 1 FROM accepted_blocks AS child WHERE child.parent_cid = block.block_cid AND child.admission_seq <= ?1) ORDER BY block.block_cid LIMIT ?3",
                params: [.int(snapshot), .text(afterCID), .int(sqlLimit)]
            )
        } else {
            rows = try database.query(
                "SELECT block_cid FROM accepted_blocks AS block WHERE block.admission_seq <= ?1 AND NOT EXISTS (SELECT 1 FROM accepted_blocks AS child WHERE child.parent_cid = block.block_cid AND child.admission_seq <= ?1) ORDER BY block.block_cid LIMIT ?2",
                params: [.int(snapshot), .int(sqlLimit)]
            )
        }
        let blockCIDs = try rows.map { row -> String in
            guard let cid = row["block_cid"]?.textValue, !cid.isEmpty else {
                throw NodeStoreError.corrupt("malformed accepted-block leaf index")
            }
            return cid
        }
        return AcceptedLeafPage(
            snapshotSequence: snapshot,
            blockCIDs: blockCIDs
        )
    }

    func auditNormalizedIndexes() async throws {
        let staged = try loadStagedAdmissions()
        var expectedFacts: [Data: Data] = [:]
        var expectedAcceptedBlocks: [String: PersistedAcceptedBlock] = [:]

        for admission in staged {
            for (id, payload) in try Self.normalizedFacts(in: admission.batch) {
                if let existing = expectedFacts[id], existing != payload {
                    throw NodeStoreError.corrupt(
                        "admission batches disagree about an immutable fact"
                    )
                }
                expectedFacts[id] = payload
            }
            for block in try Self.acceptedBlocks(in: admission.batch) {
                if let existing = expectedAcceptedBlocks[block.blockCID] {
                    guard existing.parentCID == block.parentCID else {
                        throw NodeStoreError.corrupt(
                            "admission batches disagree about an accepted block parent"
                        )
                    }
                } else {
                    expectedAcceptedBlocks[block.blockCID] = PersistedAcceptedBlock(
                        blockCID: block.blockCID,
                        parentCID: block.parentCID,
                        admissionSequence: admission.sequence
                    )
                }
            }
        }

        var actualFacts: [Data: Data] = [:]
        for row in try database.query("SELECT fact_id, payload FROM admission_facts") {
            guard let id = row["fact_id"]?.blobValue,
                  let payload = row["payload"]?.blobValue else {
                throw NodeStoreError.corrupt("malformed normalized admission fact")
            }
            actualFacts[id] = payload
        }
        guard actualFacts == expectedFacts else {
            throw NodeStoreError.corrupt(
                "normalized admission facts do not match immutable batches"
            )
        }

        var actualAcceptedBlocks: [String: PersistedAcceptedBlock] = [:]
        for row in try database.query(
            "SELECT block_cid, parent_cid, admission_seq FROM accepted_blocks"
        ) {
            let block = try persistedAcceptedBlock(from: row)
            actualAcceptedBlocks[block.blockCID] = block
        }
        guard actualAcceptedBlocks == expectedAcceptedBlocks else {
            throw NodeStoreError.corrupt(
                "accepted-block index does not match immutable batches"
            )
        }
        var connectedAcceptedBlocks = Set(
            actualAcceptedBlocks.values.compactMap {
                $0.parentCID == nil ? $0.blockCID : nil
            }
        )
        var childrenByParent: [String: [String]] = [:]
        for block in actualAcceptedBlocks.values {
            if let parentCID = block.parentCID {
                childrenByParent[parentCID, default: []].append(block.blockCID)
            }
        }
        var connectedQueue = Array(connectedAcceptedBlocks)
        while let parentCID = connectedQueue.popLast() {
            for childCID in childrenByParent[parentCID] ?? []
            where connectedAcceptedBlocks.insert(childCID).inserted {
                connectedQueue.append(childCID)
            }
        }

        var expectedParentFacts: [IssuedParentFactKey: Data] = [:]
        for row in try database.query(
            "SELECT payload FROM issued_parent_fact_sources ORDER BY payload"
        ) {
            guard let payload = row["payload"]?.blobValue else {
                throw NodeStoreError.corrupt("malformed parent-fact source")
            }
            let source = try Self.decode(
                PersistedParentFactSource.self,
                from: payload
            )
            guard try Self.encode(source) == payload,
                  source.carrierLink.parentPath == chainPath,
                  !source.carrierLink.carrierCID.isEmpty,
                  !source.carrierLink.rootCID.isEmpty,
                  chainPath.count > 1
                    || source.carrierLink.carrierCID
                        == source.carrierLink.rootCID else {
                throw NodeStoreError.corrupt("invalid parent-fact source")
            }
            let sortedGenesis = Array(Set(source.parentGenesisLinks)).sorted {
                ($0.directory, $0.childGenesisCID, $0.parentStateCID)
                    < ($1.directory, $1.childGenesisCID, $1.parentStateCID)
            }
            guard source.parentGenesisLinks == sortedGenesis,
                  source.parentGenesisLinks.allSatisfy({
                      $0.parentPath == chainPath
                          && !$0.directory.isEmpty
                          && !$0.childGenesisCID.isEmpty
                          && !$0.parentStateCID.isEmpty
                  }),
                  source.parentGenesisLinks.isEmpty
                    || connectedAcceptedBlocks.contains(
                        source.carrierLink.carrierCID
                    ) else {
                throw NodeStoreError.corrupt("invalid genesis-fact source")
            }
            try Self.addExpectedParentFact(
                key: IssuedParentFactKey(
                    kind: "carrier",
                    keyA: source.carrierLink.carrierCID,
                    keyB: source.carrierLink.rootCID
                ),
                payload: try Self.encode(source.carrierLink),
                to: &expectedParentFacts
            )
            for link in source.parentGenesisLinks {
                try Self.addExpectedParentFact(
                    key: IssuedParentFactKey(
                        kind: "genesis",
                        keyA: link.directory,
                        keyB: Self.parentGenesisFactKey(link)
                    ),
                    payload: try Self.encode(link),
                    to: &expectedParentFacts
                )
            }
        }
        var actualParentFacts: [IssuedParentFactKey: Data] = [:]
        for row in try database.query(
            "SELECT kind, key_a, key_b, payload FROM issued_parent_facts"
        ) {
            guard let kind = row["kind"]?.textValue,
                  let keyA = row["key_a"]?.textValue,
                  let keyB = row["key_b"]?.textValue,
                  let payload = row["payload"]?.blobValue else {
                throw NodeStoreError.corrupt("malformed issued parent fact")
            }
            actualParentFacts[IssuedParentFactKey(
                kind: kind,
                keyA: keyA,
                keyB: keyB
            )] = payload
        }
        guard actualParentFacts == expectedParentFacts else {
            throw NodeStoreError.corrupt(
                "issued parent facts do not match immutable sources"
            )
        }

        let attachments = try database.query(
            "SELECT scope, edge_cid, root_cid FROM issued_child_proofs ORDER BY scope, edge_cid, root_cid"
        )
        for row in attachments {
            guard let rawScope = row["scope"]?.textValue,
                  let scope = IssuedChildProofScope(rawValue: rawScope),
                  let edgeCID = row["edge_cid"]?.textValue,
                  let rootCID = row["root_cid"]?.textValue,
                  try await issuedChildEvidence(
                    scope: scope,
                    edgeCID: edgeCID,
                    rootCID: rootCID
                  ) != nil else {
                throw NodeStoreError.corrupt(
                    "malformed direct-child attachment index"
                )
            }
        }
        let outgoingOrdinals = try database.query(
            "SELECT ordinal FROM issued_child_proofs WHERE scope = ?1 ORDER BY ordinal",
            params: [.text(IssuedChildProofScope.outgoingDirectChild.rawValue)]
        )
        for (offset, row) in outgoingOrdinals.enumerated() {
            guard row["ordinal"]?.intValue == Int64(offset + 1) else {
                throw NodeStoreError.corrupt(
                    "child-evidence ordinals are not contiguous"
                )
            }
        }
        let invalidIncomingOrdinal = try database.query(
            "SELECT 1 FROM issued_child_proofs WHERE scope != ?1 AND ordinal IS NOT NULL LIMIT 1",
            params: [.text(IssuedChildProofScope.outgoingDirectChild.rawValue)]
        )
        guard invalidIncomingOrdinal.isEmpty else {
            throw NodeStoreError.corrupt(
                "incoming evidence has an outgoing ordinal"
            )
        }
        _ = try parentEvidenceScanCursor()
        _ = try await parentEvidenceInbox()
        for carrierCID in try await preparedChildProofCarrierCIDs() {
            _ = try await preparedChildProofs(carrierCID: carrierCID)
        }
        let malformedContextualCandidates = try database.query("""
            SELECT 1 FROM contextual_candidate_roots AS roots
            WHERE NOT EXISTS (
                SELECT 1 FROM contextual_candidates AS candidate
                WHERE candidate.candidate_cid = roots.candidate_cid
            )
            UNION ALL
            SELECT 1 FROM contextual_candidates AS candidate
            WHERE NOT EXISTS (
                SELECT 1 FROM contextual_candidate_roots AS roots
                WHERE roots.candidate_cid = candidate.candidate_cid
                    AND roots.root_cid = candidate.candidate_cid
            )
            AND NOT EXISTS (
                SELECT 1 FROM accepted_blocks AS block
                WHERE block.block_cid = candidate.candidate_cid
            )
            UNION ALL
            SELECT 1 FROM contextual_candidate_children AS child
            WHERE NOT EXISTS (
                SELECT 1 FROM contextual_candidates AS candidate
                WHERE candidate.candidate_cid = child.candidate_cid
            )
            LIMIT 1
            """)
        guard malformedContextualCandidates.isEmpty else {
            throw NodeStoreError.corrupt(
                "contextual candidate index is inconsistent"
            )
        }
        let conflictedContextualCandidates = try database.query(
            "SELECT 1 FROM contextual_candidates WHERE (issued = 1 AND handoff = 1) OR ((handoff = 1) != (handoff_seq IS NOT NULL)) LIMIT 1"
        )
        guard conflictedContextualCandidates.isEmpty else {
            throw NodeStoreError.corrupt(
                "contextual candidate handoff state is inconsistent"
            )
        }
        for row in try database.query(
            "SELECT DISTINCT child_peer_key FROM contextual_candidate_children"
        ) {
            guard let rawPeerKey = row["child_peer_key"]?.textValue,
                  (try? PeerKey(rawPeerKey)) != nil else {
                throw NodeStoreError.corrupt(
                    "contextual candidate child peer key is malformed"
                )
            }
        }
        let edgeCount = try database.query(
            "SELECT COUNT(*) AS count FROM issued_child_edges"
        ).first?["count"]?.intValue
        let attachedEdgeCount = try database.query(
            "SELECT COUNT(DISTINCT edge_cid) AS count FROM issued_child_proofs"
        ).first?["count"]?.intValue
        guard edgeCount == attachedEdgeCount else {
            throw NodeStoreError.corrupt("orphaned direct-child content")
        }
    }

    /// Durable child-to-parent carrier links used only by this child when it
    /// projects its configured parent's generic securing-work graph.
    func incomingParentCarrierBlocksByChildBlock()
        throws -> [String: Set<String>]
    {
        let rows = try database.query(
            "SELECT DISTINCT edge.child_cid, edge.parent_carrier_cid FROM issued_child_proofs AS proof INNER JOIN issued_child_edges AS edge ON edge.edge_cid = proof.edge_cid WHERE proof.scope = ?1 ORDER BY edge.child_cid, edge.parent_carrier_cid",
            params: [.text(IssuedChildProofScope.incomingCarrier.rawValue)]
        )
        var result: [String: Set<String>] = [:]
        for row in rows {
            guard let childCID = row["child_cid"]?.textValue,
                  let parentCarrierCID = row["parent_carrier_cid"]?.textValue,
                  CIDIdentity.isCanonical(childCID),
                  CIDIdentity.isCanonical(parentCarrierCID) else {
                throw NodeStoreError.corrupt("malformed incoming parent binding")
            }
            result[childCID, default: []].insert(parentCarrierCID)
        }
        return result
    }

    /// Resolve only bindings touched by a live parent-work delta. Full graph
    /// materialization remains a restart/reconnect operation.
    func incomingParentCarrierBlocksByChildBlock(
        matching parentBlockCIDs: Set<String>
    ) throws -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for parentBlockCID in parentBlockCIDs.sorted() {
            let rows = try database.query(
                "SELECT DISTINCT edge.child_cid FROM issued_child_proofs AS proof INNER JOIN issued_child_edges AS edge ON edge.edge_cid = proof.edge_cid WHERE proof.scope = ?1 AND edge.parent_carrier_cid = ?2 ORDER BY edge.child_cid",
                params: [
                    .text(IssuedChildProofScope.incomingCarrier.rawValue),
                    .text(parentBlockCID),
                ]
            )
            for row in rows {
                guard let childCID = row["child_cid"]?.textValue,
                      CIDIdentity.isCanonical(childCID) else {
                    throw NodeStoreError.corrupt(
                        "malformed incoming parent binding"
                    )
                }
                result[childCID, default: []].insert(parentBlockCID)
            }
        }
        return result
    }

    func incomingParentCarrierBlockCIDs(
        forChildBlockCID childBlockCID: String
    ) throws -> Set<String> {
        guard CIDIdentity.isCanonical(childBlockCID) else {
            throw NodeStoreError.corrupt("invalid incoming child block")
        }
        let rows = try database.query(
            "SELECT edge.parent_carrier_cid FROM issued_child_edges AS edge WHERE edge.child_cid = ?1 AND EXISTS (SELECT 1 FROM issued_child_proofs AS proof WHERE proof.scope = ?2 AND proof.edge_cid = edge.edge_cid) ORDER BY edge.parent_carrier_cid",
            params: [
                .text(childBlockCID),
                .text(IssuedChildProofScope.incomingCarrier.rawValue),
            ]
        )
        return try Set(rows.map { row in
            guard let parentCarrierCID = row["parent_carrier_cid"]?.textValue,
                  CIDIdentity.isCanonical(parentCarrierCID) else {
                throw NodeStoreError.corrupt("malformed incoming parent binding")
            }
            return parentCarrierCID
        })
    }

    func hasAcceptedBlock(_ blockCID: String) throws -> Bool {
        guard CIDIdentity.isCanonical(blockCID) else {
            throw NodeStoreError.corrupt("invalid accepted block lookup")
        }
        return try !database.query(
            "SELECT 1 FROM accepted_blocks WHERE block_cid = ?1 LIMIT 1",
            params: [.text(blockCID)]
        ).isEmpty
    }

    private func hasConnectedAcceptedBlock(_ blockCID: String) throws -> Bool {
        guard CIDIdentity.isCanonical(blockCID) else {
            throw NodeStoreError.corrupt("invalid connected block lookup")
        }
        return try !database.query(
            """
            WITH RECURSIVE connected(block_cid) AS (
                SELECT block_cid
                FROM accepted_blocks
                WHERE parent_cid IS NULL
                UNION
                SELECT child.block_cid
                FROM accepted_blocks AS child
                JOIN connected AS parent
                  ON child.parent_cid = parent.block_cid
            )
            SELECT 1
            FROM connected
            WHERE block_cid = ?1
            LIMIT 1
            """,
            params: [.text(blockCID)]
        ).isEmpty
    }

    func hasIncomingCarrierEdge(_ edgeCID: String) throws -> Bool {
        guard CIDIdentity.isCanonical(edgeCID) else {
            throw NodeStoreError.corrupt("invalid incoming edge lookup")
        }
        return try !database.query(
            "SELECT 1 FROM issued_child_proofs WHERE scope = ?1 AND edge_cid = ?2 LIMIT 1",
            params: [
                .text(IssuedChildProofScope.incomingCarrier.rawValue),
                .text(edgeCID),
            ]
        ).isEmpty
    }

    func syncSourceID() throws -> String {
        guard let sourceID = try database.query(
            "SELECT sync_source_id FROM node_metadata WHERE singleton = 1"
        ).first?["sync_source_id"]?.textValue,
              UUID(uuidString: sourceID) != nil else {
            throw NodeStoreError.corrupt("malformed sync source identifier")
        }
        return sourceID
    }

    private static func acceptedBlocks(
        in batch: ChainAdmissionBatch
    ) throws -> [AcceptedBlockRecord] {
        var blocks: [String: AcceptedBlockRecord] = [:]
        for fact in batch.facts {
            guard case .block(let block) = fact else { continue }
            let record = AcceptedBlockRecord(
                blockCID: block.blockHash,
                parentCID: block.parentBlockHash
            )
            if let existing = blocks[record.blockCID], existing != record {
                throw NodeStoreError.conflictingAdmissionFact
            }
            blocks[record.blockCID] = record
        }
        return blocks.values.sorted { $0.blockCID < $1.blockCID }
    }

    private func persistedAcceptedBlock(
        from row: [String: NodeSQLiteValue]
    ) throws -> PersistedAcceptedBlock {
        guard let blockCID = row["block_cid"]?.textValue,
              !blockCID.isEmpty,
              let admissionSequence = row["admission_seq"]?.intValue,
              admissionSequence > 0,
              let rawParent = row["parent_cid"] else {
            throw NodeStoreError.corrupt("malformed accepted-block index")
        }
        let parentCID: String?
        switch rawParent {
        case .null:
            parentCID = nil
        case .text(let value) where !value.isEmpty:
            parentCID = value
        default:
            throw NodeStoreError.corrupt("malformed accepted-block parent")
        }
        return PersistedAcceptedBlock(
            blockCID: blockCID,
            parentCID: parentCID,
            admissionSequence: admissionSequence
        )
    }

    private func validateAcceptedBlockRows(
        _ blocks: [AcceptedBlockRecord],
        admissionSequence: Int64
    ) throws {
        for block in blocks {
            let rows = try database.query(
                "SELECT block_cid, parent_cid, admission_seq FROM accepted_blocks WHERE block_cid = ?1",
                params: [.text(block.blockCID)]
            )
            guard let row = rows.first else {
                throw NodeStoreError.corrupt(
                    "an admission batch is missing its accepted-block index"
                )
            }
            let persisted = try persistedAcceptedBlock(from: row)
            guard persisted.parentCID == block.parentCID,
                  persisted.admissionSequence <= admissionSequence else {
                throw NodeStoreError.corrupt("malformed accepted-block index")
            }
        }
    }

    private func persistAcceptedBlockRows(
        _ blocks: [AcceptedBlockRecord],
        admissionSequence: Int64
    ) throws {
        for block in blocks {
            let rows = try database.query(
                "SELECT block_cid, parent_cid, admission_seq FROM accepted_blocks WHERE block_cid = ?1",
                params: [.text(block.blockCID)]
            )
            if let row = rows.first {
                let persisted = try persistedAcceptedBlock(from: row)
                guard persisted.parentCID == block.parentCID,
                      persisted.admissionSequence <= admissionSequence else {
                    throw NodeStoreError.corrupt("conflicting accepted-block index")
                }
                continue
            }
            try database.execute(
                "INSERT INTO accepted_blocks (block_cid, parent_cid, admission_seq) VALUES (?1, ?2, ?3)",
                params: [
                    .text(block.blockCID),
                    block.parentCID.map(NodeSQLiteValue.text) ?? .null,
                    .int(admissionSequence),
                ]
            )
        }
    }

    private func prepareHierarchyArtifacts(
        _ artifacts: AdmissionHierarchyArtifacts?,
        carrierCIDs: Set<String>
    ) async throws -> PreparedAdmissionHierarchyArtifacts? {
        guard let artifacts else { return nil }
        let link = artifacts.carrierLink
        guard !link.carrierCID.isEmpty,
              !link.rootCID.isEmpty,
              link.parentPath == chainPath,
              carrierCIDs.contains(link.carrierCID) else {
            throw NodeStoreError.invalidConfiguration(
                "issued hierarchy artifacts are outside their admission batch"
            )
        }
        if link.rootCID == link.carrierCID {
            // A self-rooted carrier is a self-contained genesis (the Nexus root
            // OR a self-mined child genesis): it satisfies its own PoW and is
            // authorized by the parent's recorded GenesisAction, never by a
            // carrier proof. It must therefore carry no evidence.
            if artifacts.carrierEvidence != nil {
                throw NodeStoreError.invalidConfiguration(
                    "a self-rooted carrier must not carry parent evidence"
                )
            }
        } else if chainPath.count == 1 {
            throw NodeStoreError.invalidConfiguration(
                "Nexus carrier evidence must be rooted at its carrier"
            )
        } else if artifacts.carrierEvidence == nil {
            throw NodeStoreError.invalidConfiguration(
                "child carrier evidence requires its authenticated parent proof"
            )
        }

        let parentGenesisLinks = try prepareParentGenesisLinks(
            artifacts.parentGenesisLinks
        )

        let carrierEvidence: PreparedAdmissionCarrierEvidence?
        if let evidence = artifacts.carrierEvidence {
            carrierEvidence = try await prepareCarrierEvidence(
                evidence,
                expectedChildCIDs: Set([link.carrierCID]),
                expectedRootCID: link.rootCID
            )
        } else {
            carrierEvidence = nil
        }

        return PreparedAdmissionHierarchyArtifacts(
            carrierLink: link,
            carrierLinkPayload: try Self.encode(link),
            carrierEvidence: carrierEvidence,
            parentGenesisLinks: parentGenesisLinks
        )
    }

    private func prepareCarrierEvidence(
        _ evidence: AdmissionCarrierEvidence,
        expectedChildCIDs: Set<String>,
        expectedRootCID: String?
    ) async throws -> PreparedAdmissionCarrierEvidence {
        let childCID = evidence.childCID
        guard expectedChildCIDs.contains(childCID),
              expectedRootCID.map({ $0 == evidence.proof.rootCID }) ?? true,
              let edge = await DirectChildEdge.derive(from: evidence.proof),
              edge.childCID == childCID,
              let directory = evidence.proof.directoryPath.last,
              edge.directory == directory else {
            throw NodeStoreError.invalidIssuedChildProof(childCID)
        }
        guard edge.edgeCID != nil else {
            throw NodeStoreError.invalidIssuedChildProof(childCID)
        }
        let portableEnvelopePayload = try ChildValidationPackageEnvelope(
            proof: evidence.proof
        ).encode()
        let proofAttachment = try ChildEvidenceVolume(
            envelopeBytes: portableEnvelopePayload,
            childCID: childCID
        )
        return PreparedAdmissionCarrierEvidence(
            edge: edge,
            rootCID: evidence.proof.rootCID,
            proofAttachment: proofAttachment
        )
    }

    private func prepareParentGenesisLinks(
        _ links: [ParentGenesisLink]
    ) throws -> [(link: ParentGenesisLink, payload: Data)] {
        let links = Array(Set(links)).sorted {
            ($0.directory, $0.childGenesisCID, $0.parentStateCID)
                < ($1.directory, $1.childGenesisCID, $1.parentStateCID)
        }
        guard links.allSatisfy({ link in
            link.parentPath == chainPath
                && !link.directory.isEmpty
                && !link.childGenesisCID.isEmpty
                && !link.parentStateCID.isEmpty
        }) else {
            throw NodeStoreError.invalidConfiguration(
                "issued genesis link belongs to a different chain path"
            )
        }
        return try links.map { (link: $0, payload: try Self.encode($0)) }
    }

    private func persistHierarchyArtifacts(
        _ artifacts: PreparedAdmissionHierarchyArtifacts
    ) throws {
        if let evidence = artifacts.carrierEvidence {
            try persistCarrierEvidence(evidence)
        }
        try persistParentFacts(
            link: artifacts.carrierLink,
            payload: artifacts.carrierLinkPayload,
            parentGenesisLinks: artifacts.parentGenesisLinks
        )
    }

    private func persistCarrierEvidence(
        _ evidence: PreparedAdmissionCarrierEvidence
    ) throws {
        guard let edgeCID = evidence.edge.edgeCID else {
            throw NodeStoreError.invalidIssuedChildProof(evidence.edge.childCID)
        }
        try persistIssuedChildEdgeRow(evidence.edge)
        try persistIssuedChildProofRow(
            scope: .incomingCarrier,
            edgeCID: edgeCID,
            rootCID: evidence.rootCID,
            attachmentCID: evidence.proofAttachment.rawCID
        )
    }

    private func storeRecoveryEvidence(
        _ evidence: [PreparedAdmissionCarrierEvidence]
    ) async throws -> [String] {
        for item in evidence {
            try await item.proofAttachment.store(storer: recoveryVolumeBroker)
        }
        return evidence.map(\.proofAttachment.rawCID)
    }

    private func persistParentFacts(
        link: ParentCarrierLink,
        payload: Data,
        parentGenesisLinks: [(link: ParentGenesisLink, payload: Data)]
    ) throws {
        let source = PersistedParentFactSource(
            carrierLink: link,
            parentGenesisLinks: parentGenesisLinks.map(\.link)
        )
        try database.execute(
            "INSERT OR IGNORE INTO issued_parent_fact_sources (payload) VALUES (?1)",
            params: [.blob(try Self.encode(source))]
        )
        try persistIssuedParentFact(
            kind: "carrier",
            keyA: link.carrierCID,
            keyB: link.rootCID,
            payload: payload
        )
        for genesis in parentGenesisLinks {
            try persistIssuedParentFact(
                kind: "genesis",
                keyA: genesis.link.directory,
                keyB: Self.parentGenesisFactKey(genesis.link),
                payload: genesis.payload
            )
        }
    }

    func persistIssuedHierarchyArtifacts(
        _ artifacts: AdmissionHierarchyArtifacts,
        pendingChildProofRoutes: [PendingChildProofRoute] = [],
        pendingChildProofCapacity: Int = 16
    ) async throws {
        let link = artifacts.carrierLink
        if !artifacts.parentGenesisLinks.isEmpty,
           try !hasConnectedAcceptedBlock(link.carrierCID) {
            throw NodeStoreError.invalidConfiguration(
                "genesis authority requires a connected parent block"
            )
        }
        guard pendingChildProofRoutes.allSatisfy({
            $0.carrierCID == link.carrierCID && !$0.directory.isEmpty
        }) else {
            throw NodeStoreError.invalidConfiguration(
                "pending child-proof route belongs to another carrier"
            )
        }
        guard let prepared = try await prepareHierarchyArtifacts(
            artifacts,
            carrierCIDs: [link.carrierCID]
        ) else {
            throw NodeStoreError.corrupt("missing issued hierarchy artifacts")
        }
        let recoveryRoots = try await storeRecoveryEvidence(
            [prepared.carrierEvidence].compactMap { $0 }
        )
        try await mergeRecoveryRetention(
            scope: issuedRecoveryRetentionScope,
            roots: recoveryRoots
        )
        try database.transaction {
            try persistHierarchyArtifacts(prepared)
            if let attachmentCID = prepared.carrierEvidence?
                .proofAttachment.rawCID
            {
                try database.execute(
                    "DELETE FROM parent_evidence_inbox WHERE attachment_cid = ?1",
                    params: [.text(attachmentCID)]
                )
            }
            try persistPendingChildProofRouteRows(
                try pendingRoutesIncludingPreparedProofs(
                    pendingChildProofRoutes,
                    carrierCIDs: [link.carrierCID]
                ),
                capacity: pendingChildProofCapacity
            )
        }
        if prepared.carrierEvidence != nil {
            try? await recoveryVolumeBroker.advanceRetainedRoots(
                scope: parentEvidenceInboxRetentionScope,
                roots: parentEvidenceInboxRoots()
            )
        }
    }

    func issuedParentCarrierLink(
        carrierCID: String,
        rootCID: String
    ) async throws -> ParentCarrierLink? {
        guard let payload = try issuedParentFact(
            kind: "carrier",
            keyA: carrierCID,
            keyB: rootCID
        ) else { return nil }
        let link = try Self.decode(ParentCarrierLink.self, from: payload)
        guard link.parentPath == chainPath,
              link.carrierCID == carrierCID,
              link.rootCID == rootCID else {
            throw NodeStoreError.corrupt("malformed locally issued carrier link")
        }
        return link
    }

    func issuedParentGenesisLink(
        directory: String,
        childGenesisCID: String,
        parentStateCID: String
    ) async throws -> ParentGenesisLink? {
        guard let payload = try issuedParentFact(
            kind: "genesis",
            keyA: directory,
            keyB: Self.parentGenesisFactKey(
                childGenesisCID: childGenesisCID,
                parentStateCID: parentStateCID
            )
        ) else { return nil }
        let link = try Self.decode(ParentGenesisLink.self, from: payload)
        guard link.parentPath == chainPath,
              link.directory == directory,
              link.childGenesisCID == childGenesisCID,
              link.parentStateCID == parentStateCID else {
            throw NodeStoreError.corrupt("malformed locally issued genesis link")
        }
        return link
    }

    /// Persists content-authenticated proof material used to serve a direct
    /// child. Different Nexus roots and directories for the same child are
    /// distinct valid evidence, so the cache is set-valued by
    /// `(childCID, directory, rootCID)`.
    func persistIssuedChildProof(
        _ proof: ChildBlockProof,
        childCID: String,
        isChildGenesis: Bool,
        bootstrapRoots: [String],
        parentCarrierCID: String? = nil,
        rootEnvelope: ChildValidationPackageEnvelope
    ) async throws {
        guard let directory = proof.directoryPath.last,
              isChildGenesis || bootstrapRoots.isEmpty,
              bootstrapRoots.isEmpty || bootstrapRoots.contains(childCID) else {
            throw NodeStoreError.invalidIssuedChildProof(childCID)
        }
        guard let edge = await DirectChildEdge.derive(from: proof),
              edge.childCID == childCID,
              edge.directory == directory,
              proof.directoryPath
                == Array(chainPath.dropFirst()) + [directory],
              parentCarrierCID.map({ $0 == edge.parentCarrierCID }) ?? true else {
            throw NodeStoreError.invalidIssuedChildProof(childCID)
        }
        _ = try await validatedProofPayload(
            proof,
            childCID: childCID
        )
        guard let edgeCID = edge.edgeCID else {
            throw NodeStoreError.invalidIssuedChildProof(childCID)
        }
        guard rootEnvelope.proofBytes == (try? proof.serialize()) else {
            throw NodeStoreError.invalidIssuedChildProof(childCID)
        }
        let proofAttachment = try ChildEvidenceVolume(
            envelopeBytes: try rootEnvelope.encode(),
            childCID: childCID
        )
        try await retainChildGenesisVolumes(
            bootstrapRoots,
            storer: recoveryVolumeBroker
        )
        try await proofAttachment.store(storer: recoveryVolumeBroker)
        let recoveryRoots = bootstrapRoots
            + [proofAttachment.rawCID]
        try await mergeRecoveryRetention(
            scope: issuedRecoveryRetentionScope,
            roots: recoveryRoots
        )
        try database.transaction {
            try persistChildGenesisVolumeRoots(
                childCID: childCID,
                roots: bootstrapRoots
            )
            try persistIssuedChildEdgeRow(edge)
            try persistIssuedChildProofRow(
                scope: .outgoingDirectChild,
                edgeCID: edgeCID,
                rootCID: proof.rootCID,
                attachmentCID: proofAttachment.rawCID
            )
        }
    }

    private func validatedProofPayload(
        _ proof: ChildBlockProof,
        childCID: String,
        exactDirectoryPath: [String]? = nil
    ) async throws -> Data {
        guard !childCID.isEmpty,
              exactDirectoryPath.map({ proof.directoryPath == $0 }) ?? true,
              try await Self.proves(
                proof,
                childCID: childCID,
                from: chainPath
              ) else {
            throw NodeStoreError.invalidIssuedChildProof(childCID)
        }
        let payload = try proof.serialize()
        guard ChildBlockProof.deserialize(payload) != nil else {
            throw NodeStoreError.invalidIssuedChildProof(childCID)
        }
        return payload
    }

    private func persistIssuedChildEdgeRow(_ edge: DirectChildEdge) throws {
        guard let edgeCID = edge.edgeCID else {
            throw NodeStoreError.invalidIssuedChildProof(edge.childCID)
        }
        let byIdentity = try database.query(
            "SELECT parent_carrier_cid, directory, child_cid FROM issued_child_edges WHERE edge_cid = ?1",
            params: [.text(edgeCID)]
        )
        let byTuple = try database.query(
            "SELECT edge_cid FROM issued_child_edges WHERE parent_carrier_cid = ?1 AND directory = ?2 AND child_cid = ?3",
            params: [
                .text(edge.parentCarrierCID), .text(edge.directory),
                .text(edge.childCID),
            ]
        )
        if let row = byIdentity.first {
            guard row["parent_carrier_cid"]?.textValue == edge.parentCarrierCID,
                  row["directory"]?.textValue == edge.directory,
                  row["child_cid"]?.textValue == edge.childCID,
                  byTuple.first?["edge_cid"]?.textValue == edgeCID else {
                throw NodeStoreError.conflictingIssuedChildProof
            }
            return
        }
        guard byTuple.isEmpty else {
            throw NodeStoreError.conflictingIssuedChildProof
        }
        try database.execute(
            "INSERT INTO issued_child_edges (edge_cid, parent_carrier_cid, directory, child_cid) VALUES (?1, ?2, ?3, ?4)",
            params: [
                .text(edgeCID), .text(edge.parentCarrierCID),
                .text(edge.directory), .text(edge.childCID),
            ]
        )
    }

    private func recoveryVolume(
        attachmentCID: String,
        childCID: String
    ) async throws -> ChildEvidenceVolume {
        guard CIDIdentity.isCanonical(attachmentCID) else {
            throw NodeStoreError.corrupt("malformed recovery attachment CID")
        }
        do {
            guard let serialized = await recoveryVolumeBroker.fetchVolumeLocal(
                root: attachmentCID
            ) else {
                throw NodeStoreError.corrupt("incomplete recovery attachment")
            }
            return try ChildEvidenceVolume(
                serialized: serialized,
                childCID: childCID
            )
        } catch let error as NodeStoreError {
            throw error
        } catch {
            throw NodeStoreError.corrupt("missing recovery attachment \(attachmentCID)")
        }
    }

    private func persistIssuedChildProofRow(
        scope: IssuedChildProofScope,
        edgeCID: String,
        rootCID: String,
        attachmentCID: String
    ) throws {
        let rows = try database.query(
            "SELECT attachment_cid, ordinal FROM issued_child_proofs WHERE scope = ?1 AND edge_cid = ?2 AND root_cid = ?3",
            params: [
                .text(scope.rawValue), .text(edgeCID), .text(rootCID),
            ]
        )
        if let row = rows.first {
            guard row["attachment_cid"]?.textValue == attachmentCID,
                  scope == .outgoingDirectChild
                    ? row["ordinal"]?.intValue != nil
                    : row["ordinal"]?.intValue == nil else {
                throw NodeStoreError.conflictingIssuedChildProof
            }
            return
        }
        let ordinal: NodeSQLiteValue
        if scope == .outgoingDirectChild {
            let maximum = try database.query(
                "SELECT COALESCE(MAX(ordinal), 0) AS ordinal FROM issued_child_proofs"
            ).first?["ordinal"]?.intValue ?? 0
            guard maximum < Int64.max else {
                throw NodeStoreError.corrupt(
                    "child-evidence ordinal exhausted"
                )
            }
            ordinal = .int(maximum + 1)
        } else {
            ordinal = .null
        }
        try database.execute(
            "INSERT INTO issued_child_proofs (scope, edge_cid, root_cid, attachment_cid, ordinal) VALUES (?1, ?2, ?3, ?4, ?5)",
            params: [
                .text(scope.rawValue), .text(edgeCID), .text(rootCID),
                .text(attachmentCID),
                ordinal,
            ]
        )
    }

    func issuedChildEvidence(
        childCID: String,
        directory: String,
        rootCID: String? = nil
    ) async throws -> IssuedChildEvidence? {
        try await issuedChildEvidence(
            scope: .outgoingDirectChild,
            childCID: childCID,
            directory: directory,
            rootCID: rootCID
        )
    }

    func incomingCarrierEvidence(
        childCID: String,
        directory: String,
        rootCID: String? = nil
    ) async throws -> IssuedChildEvidence? {
        try await issuedChildEvidence(
            scope: .incomingCarrier,
            childCID: childCID,
            directory: directory,
            rootCID: rootCID
        )
    }

    func issuedChildEvidence(
        scope: IssuedChildProofScope,
        edgeCID: String,
        rootCID: String
    ) async throws -> IssuedChildEvidence? {
        let rows = try database.query(
            "SELECT e.child_cid, e.directory FROM issued_child_proofs AS p INNER JOIN issued_child_edges AS e ON e.edge_cid = p.edge_cid WHERE p.scope = ?1 AND p.edge_cid = ?2 AND p.root_cid = ?3 LIMIT 1",
            params: [.text(scope.rawValue), .text(edgeCID), .text(rootCID)]
        )
        guard let row = rows.first,
              let childCID = row["child_cid"]?.textValue,
              let directory = row["directory"]?.textValue else {
            return nil
        }
        let evidence = try await issuedChildEvidence(
            scope: scope,
            childCID: childCID,
            directory: directory,
            rootCID: rootCID,
            exactEdgeCID: edgeCID
        )
        guard evidence?.edgeCID == edgeCID else {
            throw NodeStoreError.corrupt("malformed child root attachment")
        }
        return evidence
    }

    func issuedChildEvidence(
        scope: IssuedChildProofScope,
        edgeCID: String
    ) async throws -> IssuedChildEvidence? {
        guard let rootCID = try database.query(
            "SELECT root_cid FROM issued_child_proofs WHERE scope = ?1 AND edge_cid = ?2 ORDER BY root_cid LIMIT 1",
            params: [.text(scope.rawValue), .text(edgeCID)]
        ).first?["root_cid"]?.textValue else {
            return nil
        }
        return try await issuedChildEvidence(
            scope: scope,
            edgeCID: edgeCID,
            rootCID: rootCID
        )
    }

    private func issuedChildEvidence(
        scope: IssuedChildProofScope,
        childCID: String,
        directory: String,
        rootCID: String? = nil,
        exactEdgeCID: String? = nil
    ) async throws -> IssuedChildEvidence? {
        guard !directory.isEmpty else {
            throw NodeStoreError.invalidConfiguration(
                "child-proof directory must be nonempty"
            )
        }
        let rows: [[String: NodeSQLiteValue]]
        if let rootCID, let exactEdgeCID {
            rows = try database.query(
                "SELECT p.edge_cid, p.root_cid, p.attachment_cid, e.parent_carrier_cid, e.directory, e.child_cid FROM issued_child_proofs AS p INNER JOIN issued_child_edges AS e ON e.edge_cid = p.edge_cid WHERE p.scope = ?1 AND p.edge_cid = ?2 AND e.child_cid = ?3 AND e.directory = ?4 AND p.root_cid = ?5 LIMIT 1",
                params: [
                    .text(scope.rawValue), .text(exactEdgeCID),
                    .text(childCID), .text(directory), .text(rootCID),
                ]
            )
        } else if let rootCID {
            rows = try database.query(
                "SELECT p.edge_cid, p.root_cid, p.attachment_cid, e.parent_carrier_cid, e.directory, e.child_cid FROM issued_child_proofs AS p INNER JOIN issued_child_edges AS e ON e.edge_cid = p.edge_cid WHERE p.scope = ?1 AND e.child_cid = ?2 AND e.directory = ?3 AND p.root_cid = ?4 LIMIT 1",
                params: [
                    .text(scope.rawValue), .text(childCID), .text(directory),
                    .text(rootCID),
                ]
            )
        } else {
            rows = try database.query(
                "SELECT p.edge_cid, p.root_cid, p.attachment_cid, e.parent_carrier_cid, e.directory, e.child_cid FROM issued_child_proofs AS p INNER JOIN issued_child_edges AS e ON e.edge_cid = p.edge_cid WHERE p.scope = ?1 AND e.child_cid = ?2 AND e.directory = ?3 ORDER BY p.root_cid, p.edge_cid LIMIT 1",
                params: [
                    .text(scope.rawValue), .text(childCID), .text(directory),
                ]
            )
        }
        guard let row = rows.first else { return nil }
        guard let edgeCID = row["edge_cid"]?.textValue,
              let directory = row["directory"]?.textValue,
              let storedRoot = row["root_cid"]?.textValue,
              let attachmentCID = row["attachment_cid"]?.textValue,
              let parentCarrierCID = row["parent_carrier_cid"]?.textValue else {
            throw NodeStoreError.corrupt("malformed locally issued child proof")
        }
        let attachment = try await recoveryVolume(
            attachmentCID: attachmentCID,
            childCID: childCID
        )
        let envelope: ChildValidationPackageEnvelope
        do {
            envelope = try ChildValidationPackageEnvelope.decode(
                attachment.envelopeBytes
            )
        } catch {
            throw NodeStoreError.corrupt("malformed child evidence attachment")
        }
        guard let proof = ChildBlockProof.deserialize(envelope.proofBytes),
              (try? proof.serialize()) == envelope.proofBytes,
              proof.directoryPath.last == directory,
              proof.rootCID == storedRoot,
              try await Self.proves(
                  proof,
                  childCID: childCID,
                  from: chainPath
              ),
              let edge = await DirectChildEdge.derive(from: proof),
              edge.edgeCID == edgeCID,
              edge.parentCarrierCID == parentCarrierCID,
              edge.childCID == childCID,
              edge.directory == directory else {
            throw NodeStoreError.corrupt("malformed locally issued child proof")
        }
        return IssuedChildEvidence(
            edgeCID: edgeCID,
            attachmentCID: attachmentCID,
            edge: edge,
            proof: proof
        )
    }

    func issuedChildProofRoots(
        childCID: String,
        directory: String,
        afterRootCID: String?,
        limit: Int
    ) async throws -> [String] {
        try await issuedChildProofRoots(
            scope: .outgoingDirectChild,
            childCID: childCID,
            directory: directory,
            afterRootCID: afterRootCID,
            limit: limit
        )
    }

    func incomingCarrierProofRoots(
        childCID: String,
        directory: String,
        afterRootCID: String?,
        limit: Int
    ) async throws -> [String] {
        try await issuedChildProofRoots(
            scope: .incomingCarrier,
            childCID: childCID,
            directory: directory,
            afterRootCID: afterRootCID,
            limit: limit
        )
    }

    private func issuedChildProofRoots(
        scope: IssuedChildProofScope,
        childCID: String,
        directory: String,
        afterRootCID: String?,
        limit: Int
    ) async throws -> [String] {
        guard !directory.isEmpty, limit > 0,
              let sqlLimit = Int64(exactly: limit) else {
            throw NodeStoreError.invalidConfiguration(
                "child-proof page limit must be positive"
            )
        }
        let rows: [[String: NodeSQLiteValue]]
        if let afterRootCID {
            rows = try database.query(
                "SELECT DISTINCT p.root_cid FROM issued_child_proofs AS p INNER JOIN issued_child_edges AS e ON e.edge_cid = p.edge_cid WHERE p.scope = ?1 AND e.child_cid = ?2 AND e.directory = ?3 AND p.root_cid > ?4 ORDER BY p.root_cid LIMIT ?5",
                params: [
                    .text(scope.rawValue), .text(childCID), .text(directory),
                    .text(afterRootCID), .int(sqlLimit),
                ]
            )
        } else {
            rows = try database.query(
                "SELECT DISTINCT p.root_cid FROM issued_child_proofs AS p INNER JOIN issued_child_edges AS e ON e.edge_cid = p.edge_cid WHERE p.scope = ?1 AND e.child_cid = ?2 AND e.directory = ?3 ORDER BY p.root_cid LIMIT ?4",
                params: [
                    .text(scope.rawValue), .text(childCID), .text(directory),
                    .int(sqlLimit),
                ]
            )
        }
        var roots: [String] = []
        roots.reserveCapacity(rows.count)
        for row in rows {
            guard let root = row["root_cid"]?.textValue,
                  CIDIdentity.isCanonical(root) else {
                throw NodeStoreError.corrupt("malformed locally issued child-proof index")
            }
            roots.append(root)
        }
        return roots
    }

    func issuedChildEvidenceSummaries(
        directory: String,
        afterOrdinal: UInt64,
        throughOrdinal: UInt64,
        limit: Int
    ) async throws -> [IssuedChildEvidenceSummary] {
        guard !directory.isEmpty, limit > 0,
              let sqlLimit = Int64(exactly: limit),
              let after = Int64(exactly: afterOrdinal),
              let through = Int64(exactly: throughOrdinal),
              after <= through else {
            throw NodeStoreError.invalidConfiguration(
                "child-evidence page must be bounded"
            )
        }
        let rows = try database.query(
            "SELECT p.ordinal, e.child_cid, p.root_cid, p.attachment_cid FROM issued_child_proofs AS p INNER JOIN issued_child_edges AS e ON e.edge_cid = p.edge_cid WHERE p.scope = ?1 AND e.directory = ?2 AND p.ordinal > ?3 AND p.ordinal <= ?4 ORDER BY p.ordinal LIMIT ?5",
            params: [
                .text(IssuedChildProofScope.outgoingDirectChild.rawValue),
                .text(directory), .int(after), .int(through), .int(sqlLimit),
            ]
        )
        var summaries: [IssuedChildEvidenceSummary] = []
        summaries.reserveCapacity(rows.count)
        for row in rows {
            guard let rawOrdinal = row["ordinal"]?.intValue,
                  rawOrdinal > 0,
                  let ordinal = UInt64(exactly: rawOrdinal),
                  let childCID = row["child_cid"]?.textValue,
                  let rootCID = row["root_cid"]?.textValue,
                  let attachmentCID = row["attachment_cid"]?.textValue,
                  CIDIdentity.isCanonical(childCID),
                  CIDIdentity.isCanonical(rootCID),
                  CIDIdentity.isCanonical(attachmentCID) else {
                throw NodeStoreError.corrupt(
                    "malformed locally issued child-evidence index"
                )
            }
            summaries.append(IssuedChildEvidenceSummary(
                ordinal: ordinal,
                childCID: childCID,
                rootCID: rootCID,
                attachmentCID: attachmentCID
            ))
        }
        return summaries
    }

    func issuedChildEvidenceScanHead(directory: String) throws
        -> (sourceID: String, throughOrdinal: UInt64)
    {
        guard !directory.isEmpty else {
            throw NodeStoreError.invalidConfiguration(
                "child-evidence directory must be nonempty"
            )
        }
        let sourceID = try syncSourceID()
        guard let rawThrough = try database.query(
                "SELECT COALESCE(MAX(p.ordinal), 0) AS ordinal FROM issued_child_proofs AS p INNER JOIN issued_child_edges AS e ON e.edge_cid = p.edge_cid WHERE p.scope = ?1 AND e.directory = ?2",
                params: [
                    .text(IssuedChildProofScope.outgoingDirectChild.rawValue),
                    .text(directory),
                ]
              ).first?["ordinal"]?.intValue,
              let through = UInt64(exactly: rawThrough) else {
            throw NodeStoreError.corrupt(
                "malformed child-evidence scan head"
            )
        }
        return (sourceID, through)
    }

    func issuedChildEvidenceSummary(
        childCID: String,
        directory: String,
        rootCID: String
    ) throws -> (sourceID: String, summary: IssuedChildEvidenceSummary)? {
        guard let row = try database.query(
            "SELECT p.ordinal, p.attachment_cid FROM issued_child_proofs AS p INNER JOIN issued_child_edges AS e ON e.edge_cid = p.edge_cid WHERE p.scope = ?1 AND e.child_cid = ?2 AND e.directory = ?3 AND p.root_cid = ?4 LIMIT 1",
            params: [
                .text(IssuedChildProofScope.outgoingDirectChild.rawValue),
                .text(childCID), .text(directory), .text(rootCID),
            ]
        ).first,
              let rawOrdinal = row["ordinal"]?.intValue,
              let ordinal = UInt64(exactly: rawOrdinal),
              let attachmentCID = row["attachment_cid"]?.textValue else {
            return nil
        }
        return (
            try issuedChildEvidenceScanHead(directory: directory).sourceID,
            IssuedChildEvidenceSummary(
                ordinal: ordinal,
                childCID: childCID,
                rootCID: rootCID,
                attachmentCID: attachmentCID
            )
        )
    }

    func childRootAttachmentSummaries(
        scope: IssuedChildProofScope,
        directory: String,
        after: ChildRootAttachmentSummary?,
        limit: Int
    ) async throws -> [ChildRootAttachmentSummary] {
        guard !directory.isEmpty, limit > 0,
              let sqlLimit = Int64(exactly: limit) else {
            throw NodeStoreError.invalidConfiguration(
                "child root-attachment page must be bounded"
            )
        }
        let rows: [[String: NodeSQLiteValue]]
        if let after {
            rows = try database.query(
                "SELECT p.edge_cid, e.child_cid, p.root_cid, p.attachment_cid FROM issued_child_proofs AS p INNER JOIN issued_child_edges AS e ON e.edge_cid = p.edge_cid WHERE p.scope = ?1 AND e.directory = ?2 AND (p.edge_cid > ?3 OR (p.edge_cid = ?3 AND p.root_cid > ?4)) ORDER BY p.edge_cid, p.root_cid LIMIT ?5",
                params: [
                    .text(scope.rawValue), .text(directory), .text(after.edgeCID),
                    .text(after.rootCID), .int(sqlLimit),
                ]
            )
        } else {
            rows = try database.query(
                "SELECT p.edge_cid, e.child_cid, p.root_cid, p.attachment_cid FROM issued_child_proofs AS p INNER JOIN issued_child_edges AS e ON e.edge_cid = p.edge_cid WHERE p.scope = ?1 AND e.directory = ?2 ORDER BY p.edge_cid, p.root_cid LIMIT ?3",
                params: [
                    .text(scope.rawValue), .text(directory), .int(sqlLimit),
                ]
            )
        }
        var summaries: [ChildRootAttachmentSummary] = []
        summaries.reserveCapacity(rows.count)
        for row in rows {
            guard let edgeCID = row["edge_cid"]?.textValue,
                  let childCID = row["child_cid"]?.textValue,
                  let rootCID = row["root_cid"]?.textValue,
                  let attachmentCID = row["attachment_cid"]?.textValue,
                  CIDIdentity.isCanonical(edgeCID),
                  CIDIdentity.isCanonical(childCID),
                  CIDIdentity.isCanonical(rootCID),
                  CIDIdentity.isCanonical(attachmentCID) else {
                throw NodeStoreError.corrupt(
                    "malformed child root-attachment index"
                )
            }
            summaries.append(ChildRootAttachmentSummary(
                edgeCID: edgeCID,
                rootCID: rootCID,
                attachmentCID: attachmentCID
            ))
        }
        return summaries
    }

    func recoveryVolumeRoots() async throws -> [String] {
        Array(Set(
            try issuedRecoveryVolumeRoots()
                + preparedRecoveryVolumeRoots()
        )).sorted()
    }

    func issuedRecoveryVolumeRoots() throws -> [String] {
        try canonicalRecoveryRoots(sql: """
            SELECT attachment_cid AS cid FROM issued_child_proofs
            UNION
            SELECT roots.root_cid AS cid
            FROM child_genesis_volume_roots AS roots
            WHERE EXISTS (
                SELECT 1 FROM issued_child_edges AS edge
                WHERE edge.child_cid = roots.child_cid
            )
            ORDER BY cid
            """)
    }

    func parentEvidenceScanCursor() throws -> ParentEvidenceScanCursor {
        let rows = try database.query(
            "SELECT source_id, ordinal FROM parent_evidence_scan WHERE singleton = 1"
        )
        guard rows.count == 1,
              let rawOrdinal = rows[0]["ordinal"]?.intValue,
              let ordinal = UInt64(exactly: rawOrdinal) else {
            throw NodeStoreError.corrupt(
                "malformed parent-evidence scan cursor"
            )
        }
        let sourceID = rows[0]["source_id"]?.textValue
        guard sourceID.map({ UUID(uuidString: $0) != nil }) ?? true else {
            throw NodeStoreError.corrupt(
                "malformed parent-evidence scan source"
            )
        }
        return ParentEvidenceScanCursor(
            sourceID: sourceID,
            ordinal: ordinal
        )
    }

    func storeParentEvidenceInbox(
        sourceID: String,
        ordinal: UInt64,
        attachment: ChildEvidenceVolume,
        package: AuthenticatedChildPackage,
        advanceScan: Bool
    ) async throws {
        guard UUID(uuidString: sourceID) != nil,
              ordinal > 0,
              let sqlOrdinal = Int64(exactly: ordinal),
              package.package.proof.rootCID.isEmpty == false,
              let directHop = await package.package.proof.directHop() else {
            throw NodeStoreError.invalidConfiguration(
                "parent-evidence inbox reference is malformed"
            )
        }
        let envelope = try ChildValidationPackageEnvelope(
            package.package
        ).encode()
        guard envelope == attachment.envelopeBytes else {
            throw NodeStoreError.invalidIssuedChildProof(directHop.childCID)
        }
        _ = try await prepareCarrierEvidence(
            AdmissionCarrierEvidence(
                proof: package.package.proof,
                childCID: directHop.childCID
            ),
            expectedChildCIDs: [directHop.childCID],
            expectedRootCID: package.package.proof.rootCID
        )
        let existing = try database.query(
            "SELECT child_cid, root_cid, attachment_cid FROM parent_evidence_inbox WHERE source_id = ?1 AND ordinal = ?2",
            params: [.text(sourceID), .int(sqlOrdinal)]
        )
        if let row = existing.first {
            guard row["child_cid"]?.textValue == directHop.childCID,
                  row["root_cid"]?.textValue
                    == package.package.proof.rootCID,
                  row["attachment_cid"]?.textValue
                    == attachment.rawCID else {
                throw NodeStoreError.corrupt(
                    "parent-evidence ordinal changed"
                )
            }
        }
        let alreadyAdmitted = try admittedCarrierEvidenceExists(
            attachmentCID: attachment.rawCID,
            childCID: directHop.childCID,
            rootCID: package.package.proof.rootCID
        )
        if !alreadyAdmitted, existing.isEmpty {
            let count = try database.query(
                "SELECT COUNT(*) AS count FROM parent_evidence_inbox"
            ).first?["count"]?.intValue
            guard count.map({
                $0 < Int64(parentEvidenceInboxCapacity)
            }) == true else {
                throw NodeStoreError.parentEvidenceInboxFull
            }
        }
        try await attachment.store(storer: recoveryVolumeBroker)
        if !alreadyAdmitted {
            try await mergeRecoveryRetention(
                scope: parentEvidenceInboxRetentionScope,
                roots: [attachment.rawCID]
            )
        }
        let admittedDuringStore: Bool
        do {
            admittedDuringStore = try database.transaction {
                let transactionalExisting = try database.query(
                    "SELECT child_cid, root_cid, attachment_cid FROM parent_evidence_inbox WHERE source_id = ?1 AND ordinal = ?2",
                    params: [.text(sourceID), .int(sqlOrdinal)]
                )
                if let row = transactionalExisting.first {
                    guard row["child_cid"]?.textValue == directHop.childCID,
                          row["root_cid"]?.textValue
                            == package.package.proof.rootCID,
                          row["attachment_cid"]?.textValue
                            == attachment.rawCID else {
                        throw NodeStoreError.corrupt(
                            "parent-evidence ordinal changed"
                        )
                    }
                }
                let admitted = try admittedCarrierEvidenceExists(
                    attachmentCID: attachment.rawCID,
                    childCID: directHop.childCID,
                    rootCID: package.package.proof.rootCID
                )
                if admitted {
                    try database.execute(
                        "DELETE FROM parent_evidence_inbox WHERE attachment_cid = ?1",
                        params: [.text(attachment.rawCID)]
                    )
                } else if transactionalExisting.isEmpty {
                    let count = try database.query(
                        "SELECT COUNT(*) AS count FROM parent_evidence_inbox"
                    ).first?["count"]?.intValue
                    guard count.map({
                        $0 < Int64(parentEvidenceInboxCapacity)
                    }) == true else {
                        throw NodeStoreError.parentEvidenceInboxFull
                    }
                    try database.execute(
                        "INSERT INTO parent_evidence_inbox (source_id, ordinal, child_cid, root_cid, attachment_cid) VALUES (?1, ?2, ?3, ?4, ?5)",
                        params: [
                            .text(sourceID), .int(sqlOrdinal),
                            .text(directHop.childCID),
                            .text(package.package.proof.rootCID),
                            .text(attachment.rawCID),
                        ]
                    )
                }
                _ = try markContextualCandidateHandoff(
                    candidateCID: directHop.childCID
                )
                if advanceScan {
                    try persistParentEvidenceScan(
                        sourceID: sourceID,
                        ordinal: ordinal
                    )
                }
                return admitted
            }
        } catch {
            if !alreadyAdmitted {
                try? await recoveryVolumeBroker.advanceRetainedRoots(
                    scope: parentEvidenceInboxRetentionScope,
                    roots: parentEvidenceInboxRoots()
                )
            }
            throw error
        }
        if admittedDuringStore {
            try? await recoveryVolumeBroker.advanceRetainedRoots(
                scope: parentEvidenceInboxRetentionScope,
                roots: parentEvidenceInboxRoots()
            )
        }
    }

    private func admittedCarrierEvidenceExists(
        attachmentCID: String,
        childCID: String,
        rootCID: String
    ) throws -> Bool {
        try database.query(
            """
            SELECT 1
            FROM issued_child_proofs AS proof
            INNER JOIN issued_child_edges AS edge
                ON edge.edge_cid = proof.edge_cid
            WHERE proof.scope = ?1
                AND proof.attachment_cid = ?2
                AND edge.child_cid = ?3
                AND proof.root_cid = ?4
            LIMIT 1
            """,
            params: [
                .text(IssuedChildProofScope.incomingCarrier.rawValue),
                .text(attachmentCID),
                .text(childCID),
                .text(rootCID),
            ]
        ).isEmpty == false
    }

    private func persistParentEvidenceScan(
        sourceID: String,
        ordinal: UInt64
    ) throws {
        let current = try parentEvidenceScanCursor()
        let nextOrdinal = current.sourceID == sourceID
            ? max(current.ordinal, ordinal)
            : ordinal
        guard let sqlOrdinal = Int64(exactly: nextOrdinal) else {
            throw NodeStoreError.invalidConfiguration(
                "parent-evidence scan cursor is too large"
            )
        }
        try database.execute(
            "UPDATE parent_evidence_scan SET source_id = ?1, ordinal = ?2 WHERE singleton = 1",
            params: [.text(sourceID), .int(sqlOrdinal)]
        )
    }

    func parentEvidenceInboxRoots() throws -> [String] {
        try canonicalRecoveryRoots(sql: """
            SELECT DISTINCT attachment_cid AS cid
            FROM parent_evidence_inbox
            ORDER BY cid
        """)
    }

    func parentEvidenceInboxHasCapacity() throws -> Bool {
        let count = try database.query(
            "SELECT COUNT(*) AS count FROM parent_evidence_inbox"
        ).first?["count"]?.intValue
        guard let count else {
            throw NodeStoreError.corrupt(
                "parent-evidence inbox count is malformed"
            )
        }
        return count < Int64(parentEvidenceInboxCapacity)
    }

    func parentEvidenceInbox() async throws -> [ParentEvidenceInboxItem] {
        let rows = try database.query(
            "SELECT source_id, ordinal, child_cid, root_cid, attachment_cid FROM parent_evidence_inbox ORDER BY source_id, ordinal"
        )
        var items: [ParentEvidenceInboxItem] = []
        items.reserveCapacity(rows.count)
        for row in rows {
            guard let sourceID = row["source_id"]?.textValue,
                  UUID(uuidString: sourceID) != nil,
                  let rawOrdinal = row["ordinal"]?.intValue,
                  let ordinal = UInt64(exactly: rawOrdinal),
                  ordinal > 0,
                  let childCID = row["child_cid"]?.textValue,
                  let rootCID = row["root_cid"]?.textValue,
                  let attachmentCID = row["attachment_cid"]?.textValue else {
                throw NodeStoreError.corrupt(
                    "malformed parent-evidence inbox"
                )
            }
            let attachment = try await recoveryVolume(
                attachmentCID: attachmentCID,
                childCID: childCID
            )
            guard let envelope = try? ChildValidationPackageEnvelope.decode(
                attachment.envelopeBytes
            ), let proof = ChildBlockProof.deserialize(envelope.proofBytes),
               proof.rootCID == rootCID else {
                throw NodeStoreError.corrupt(
                    "malformed parent-evidence inbox attachment"
                )
            }
            let package = AuthenticatedChildPackage(
                package: ChildValidationPackage(proof: proof)
            )
            _ = try await prepareCarrierEvidence(
                AdmissionCarrierEvidence(
                    proof: proof,
                    childCID: childCID
                ),
                expectedChildCIDs: [childCID],
                expectedRootCID: rootCID
            )
            items.append(ParentEvidenceInboxItem(
                sourceID: sourceID,
                ordinal: ordinal,
                attachment: attachment,
                package: package
            ))
        }
        return items
    }

    func preparedRecoveryVolumeRoots() throws -> [String] {
        try canonicalRecoveryRoots(sql: """
            SELECT attachment_cid AS cid FROM prepared_child_proofs
            UNION
            SELECT roots.root_cid AS cid
            FROM child_genesis_volume_roots AS roots
            WHERE EXISTS (
                SELECT 1 FROM prepared_child_proofs AS prepared
                WHERE prepared.child_cid = roots.child_cid
            )
            ORDER BY cid
            """)
    }

    /// Preserves one entry per candidate/root pair so shared roots rebuild the
    /// exact owner count after a crash.
    func contextualCandidateVolumeRoots() throws -> [String] {
        try database.query("""
            SELECT root_cid
            FROM contextual_candidate_roots
            ORDER BY candidate_cid, root_cid
            """).map { row in
            guard let root = row["root_cid"]?.textValue,
                  CIDIdentity.isCanonical(root) else {
                throw NodeStoreError.corrupt(
                    "contextual candidate root index is malformed"
                )
            }
            return root
        }
    }

    func persistContextualCandidateRoots(
        candidateCID: String,
        roots: [String],
        children: [ChildCandidateReservationReference] = [],
        capacity: Int
    ) async throws {
        let canonicalRoots = Array(Set(roots)).sorted()
        let canonicalChildren = Array(Set(children)).sorted {
            ($0.peerKey.description, $0.candidateCID)
                < ($1.peerKey.description, $1.candidateCID)
        }
        guard CIDIdentity.isCanonical(candidateCID),
              canonicalRoots.contains(candidateCID),
              canonicalRoots.allSatisfy(CIDIdentity.isCanonical),
              canonicalChildren.allSatisfy({
                  CIDIdentity.isCanonical($0.candidateCID)
              }),
              capacity > 0 else {
            throw NodeStoreError.invalidConfiguration(
                "contextual candidate retention is malformed"
            )
        }
        await acquirePreparedMutation()
        defer { releasePreparedMutation() }
        let candidateRows = try database.query(
            "SELECT issued, handoff FROM contextual_candidates WHERE candidate_cid = ?1",
            params: [.text(candidateCID)]
        )
        if let candidate = candidateRows.first {
            guard candidate["issued"]?.intValue != nil,
                  candidate["handoff"]?.intValue != nil else {
                throw NodeStoreError.corrupt(
                    "contextual candidate state is malformed"
                )
            }
            let existing = try database.query(
            "SELECT root_cid FROM contextual_candidate_roots WHERE candidate_cid = ?1 ORDER BY root_cid",
            params: [.text(candidateCID)]
            ).compactMap { $0["root_cid"]?.textValue }
            guard existing.isEmpty || existing == canonicalRoots else {
                throw NodeStoreError.corrupt(
                    "contextual candidate roots changed"
                )
            }
            let existingChildren = try contextualCandidateChildrenLocked(
                candidateCID
            )
            guard existingChildren == canonicalChildren else {
                throw NodeStoreError.corrupt(
                    "contextual candidate children changed"
                )
            }
            try touchContextualCandidateOfferLocked(candidateCID)
            return
        }
        try await recoveryVolumeBroker.pinBatch(
            roots: canonicalRoots,
            owner: contextualCandidateOwner
        )
        var evictedRoots: [String] = []
        do {
            try database.transaction {
                let latestSequence = try database.query(
                    "SELECT MAX(offer_seq) AS offer_seq FROM contextual_candidates"
                ).first?["offer_seq"]?.intValue ?? 0
                let (sequence, overflow) = latestSequence.addingReportingOverflow(1)
                guard !overflow else {
                    throw NodeStoreError.corrupt(
                        "contextual candidate retention sequence overflow"
                    )
                }
                let candidates = try database.query(
                    "SELECT candidate_cid FROM contextual_candidates WHERE issued = 0 AND handoff = 0 ORDER BY offer_seq, candidate_cid"
                )
                for candidate in candidates.prefix(
                    max(0, candidates.count - capacity + 1)
                ) {
                    guard let oldest = candidate["candidate_cid"]?.textValue else {
                        throw NodeStoreError.corrupt(
                            "contextual candidate retention index is malformed"
                        )
                    }
                    evictedRoots += try database.query(
                        "SELECT root_cid FROM contextual_candidate_roots WHERE candidate_cid = ?1",
                        params: [.text(oldest)]
                    ).compactMap { $0["root_cid"]?.textValue }
                    try database.execute(
                        "DELETE FROM contextual_candidate_roots WHERE candidate_cid = ?1",
                        params: [.text(oldest)]
                    )
                    try database.execute(
                        "DELETE FROM contextual_candidate_children WHERE candidate_cid = ?1",
                        params: [.text(oldest)]
                    )
                    try database.execute(
                        "DELETE FROM contextual_candidates WHERE candidate_cid = ?1",
                        params: [.text(oldest)]
                    )
                }
                try database.execute(
                    "INSERT INTO contextual_candidates (candidate_cid, offer_seq, issued, handoff) VALUES (?1, ?2, 0, 0)",
                    params: [.text(candidateCID), .int(sequence)]
                )
                for root in canonicalRoots {
                    try database.execute(
                        "INSERT INTO contextual_candidate_roots (candidate_cid, root_cid) VALUES (?1, ?2)",
                        params: [.text(candidateCID), .text(root)]
                    )
                }
                for child in canonicalChildren {
                    try database.execute(
                        "INSERT INTO contextual_candidate_children (candidate_cid, child_peer_key, child_cid) VALUES (?1, ?2, ?3)",
                        params: [
                            .text(candidateCID), .text(child.peerKey.description),
                            .text(child.candidateCID),
                        ]
                    )
                }
            }
        } catch {
            try? await recoveryVolumeBroker.unpinBatch(
                items: canonicalRoots.map {
                    (root: $0, owner: contextualCandidateOwner, count: 1)
                }
            )
            throw error
        }
        try? await recoveryVolumeBroker.unpinBatch(
            items: evictedRoots.map {
                (root: $0, owner: contextualCandidateOwner, count: 1)
            }
        )
    }

    /// Refreshes availability without walking or rewriting an immutable
    /// candidate Volume that this node already owns.
    func touchContextualCandidate(
        candidateCID: String,
        children: [ChildCandidateReservationReference] = []
    ) async throws -> Bool {
        guard CIDIdentity.isCanonical(candidateCID) else {
            throw NodeStoreError.invalidConfiguration(
                "contextual candidate CID is malformed"
            )
        }
        await acquirePreparedMutation()
        defer { releasePreparedMutation() }
        let exists = try !database.query(
            "SELECT 1 FROM contextual_candidates WHERE candidate_cid = ?1 LIMIT 1",
            params: [.text(candidateCID)]
        ).isEmpty
        guard exists else { return false }
        let canonicalChildren = Array(Set(children)).sorted {
            ($0.peerKey.description, $0.candidateCID)
                < ($1.peerKey.description, $1.candidateCID)
        }
        guard try contextualCandidateChildrenLocked(candidateCID)
            == canonicalChildren else {
            throw NodeStoreError.corrupt(
                "contextual candidate children changed"
            )
        }
        try touchContextualCandidateOfferLocked(candidateCID)
        return true
    }

    private func touchContextualCandidateOfferLocked(
        _ candidateCID: String
    ) throws {
        try database.transaction {
            let row = try database.query(
                "SELECT issued, handoff FROM contextual_candidates WHERE candidate_cid = ?1",
                params: [.text(candidateCID)]
            ).first
            guard let issued = row?["issued"]?.intValue,
                  let handoff = row?["handoff"]?.intValue else {
                throw NodeStoreError.corrupt(
                    "contextual candidate state is missing"
                )
            }
            guard issued == 0, handoff == 0 else { return }
            let latestSequence = try database.query(
                "SELECT MAX(offer_seq) AS offer_seq FROM contextual_candidates"
            ).first?["offer_seq"]?.intValue ?? 0
            let (sequence, overflow) = latestSequence.addingReportingOverflow(1)
            guard !overflow else {
                throw NodeStoreError.corrupt(
                    "contextual candidate retention sequence overflow"
                )
            }
            try database.execute(
                "UPDATE contextual_candidates SET offer_seq = ?2 WHERE candidate_cid = ?1",
                params: [.text(candidateCID), .int(sequence)]
            )
        }
    }

    func contextualCandidateChildren(
        candidateCIDs: Set<String>
    ) throws -> [ChildCandidateReservationReference]? {
        guard candidateCIDs.allSatisfy(CIDIdentity.isCanonical) else {
            throw NodeStoreError.invalidConfiguration(
                "contextual candidate reservation is malformed"
            )
        }
        var effectiveCandidateCIDs = candidateCIDs
        for candidateCID in candidateCIDs.sorted() {
            guard try !database.query(
                "SELECT 1 FROM contextual_candidates WHERE candidate_cid = ?1",
                params: [.text(candidateCID)]
            ).isEmpty else { return nil }
        }
        effectiveCandidateCIDs.formUnion(try database.query(
            "SELECT candidate_cid FROM contextual_candidates WHERE handoff = 1"
        ).compactMap { $0["candidate_cid"]?.textValue })
        var children: [ChildCandidateReservationReference] = []
        for candidateCID in effectiveCandidateCIDs.sorted() {
            children += try contextualCandidateChildrenLocked(candidateCID)
        }
        return children
    }

    func currentContextualCandidateChildren()
        throws -> [ChildCandidateReservationReference]
    {
        let candidateCIDs = Set(try database.query(
            "SELECT candidate_cid FROM contextual_candidates WHERE issued = 1 OR handoff = 1"
        ).compactMap { $0["candidate_cid"]?.textValue })
        return try contextualCandidateChildren(candidateCIDs: candidateCIDs)
            ?? []
    }

    private func contextualCandidateChildrenLocked(
        _ candidateCID: String
    ) throws -> [ChildCandidateReservationReference] {
        try database.query(
            "SELECT child_peer_key, child_cid FROM contextual_candidate_children WHERE candidate_cid = ?1 ORDER BY child_peer_key, child_cid",
            params: [.text(candidateCID)]
        ).map { row in
            guard let rawPeerKey = row["child_peer_key"]?.textValue,
                  let peerKey = try? PeerKey(rawPeerKey),
                  let childCID = row["child_cid"]?.textValue,
                  CIDIdentity.isCanonical(childCID) else {
                throw NodeStoreError.corrupt(
                    "contextual candidate child index is malformed"
                )
            }
            return ChildCandidateReservationReference(
                peerKey: peerKey,
                candidateCID: childCID
            )
        }
    }

    /// Transfers a candidate from parent-work reservation into the durable
    /// child-side admission handoff before the parent may release it.
    func beginContextualCandidateHandoff(
        candidateCID: String
    ) async throws -> Bool {
        guard CIDIdentity.isCanonical(candidateCID) else {
            throw NodeStoreError.invalidConfiguration(
                "contextual candidate CID is malformed"
            )
        }
        await acquirePreparedMutation()
        defer { releasePreparedMutation() }
        let began = try markContextualCandidateHandoff(
            candidateCID: candidateCID
        )
        if began {
            try await evictExcessHandoffCandidates()
        }
        return began
    }

    /// Removes one candidate's row, descendants, and root references in the
    /// caller's transaction and returns the roots to unpin afterwards. The
    /// row, its index entries, and its pins always leave together: an index
    /// that promises evicted content is a liveness wedge, not a saving.
    private func deleteContextualCandidateRows(
        candidateCID: String
    ) throws -> [String] {
        let roots = try database.query(
            "SELECT root_cid FROM contextual_candidate_roots WHERE candidate_cid = ?1",
            params: [.text(candidateCID)]
        ).compactMap { $0["root_cid"]?.textValue }
        try database.execute(
            "DELETE FROM contextual_candidate_roots WHERE candidate_cid = ?1",
            params: [.text(candidateCID)]
        )
        try database.execute(
            "DELETE FROM contextual_candidate_children WHERE candidate_cid = ?1",
            params: [.text(candidateCID)]
        )
        try database.execute(
            "DELETE FROM contextual_candidates WHERE candidate_cid = ?1",
            params: [.text(candidateCID)]
        )
        return roots
    }

    private func markContextualCandidateHandoff(
        candidateCID: String
    ) throws -> Bool {
        guard try !database.query(
            "SELECT 1 FROM contextual_candidates AS candidate WHERE candidate.candidate_cid = ?1 AND EXISTS (SELECT 1 FROM contextual_candidate_roots AS roots WHERE roots.candidate_cid = candidate.candidate_cid)",
            params: [.text(candidateCID)]
        ).isEmpty else { return false }
        try database.execute(
            "UPDATE contextual_candidates SET handoff = 1, issued = 0, offer_seq = NULL, handoff_seq = COALESCE(handoff_seq, (SELECT COALESCE(MAX(handoff_seq), 0) + 1 FROM contextual_candidates)) WHERE candidate_cid = ?1",
            params: [.text(candidateCID)]
        )
        return true
    }

    func replaceIssuedContextualCandidates(
        _ desired: Set<String>,
        handoffs: Set<String> = [],
        capacity: Int
    ) async throws -> Bool {
        guard capacity > 0,
              desired.count + handoffs.count <= capacity,
              desired.isDisjoint(with: handoffs),
              desired.union(handoffs).allSatisfy(CIDIdentity.isCanonical) else {
            throw NodeStoreError.invalidConfiguration(
                "issued contextual candidate set is malformed"
            )
        }
        await acquirePreparedMutation()
        defer { releasePreparedMutation() }
        for candidateCID in desired {
            guard try !database.query(
                "SELECT 1 FROM contextual_candidates WHERE candidate_cid = ?1",
                params: [.text(candidateCID)]
            ).isEmpty else { return false }
        }
        for candidateCID in handoffs {
            guard try !database.query(
                "SELECT 1 FROM contextual_candidates AS candidate WHERE candidate.candidate_cid = ?1 AND EXISTS (SELECT 1 FROM contextual_candidate_roots AS roots WHERE roots.candidate_cid = candidate.candidate_cid)",
                params: [.text(candidateCID)]
            ).isEmpty else { return false }
        }
        var releasedRoots: [String] = []
        try database.transaction {
            for candidateCID in handoffs {
                _ = try markContextualCandidateHandoff(
                    candidateCID: candidateCID
                )
            }
            let candidates = try database.query(
                "SELECT candidate_cid, handoff FROM contextual_candidates ORDER BY candidate_cid"
            )
            for candidate in candidates {
                guard let candidateCID = candidate["candidate_cid"]?.textValue,
                      let handoff = candidate["handoff"]?.intValue else {
                    throw NodeStoreError.corrupt(
                        "contextual candidate state is malformed"
                    )
                }
                guard !desired.contains(candidateCID) else { continue }
                if handoff == 1 {
                    try database.execute(
                        "UPDATE contextual_candidates SET issued = 0, offer_seq = NULL WHERE candidate_cid = ?1",
                        params: [.text(candidateCID)]
                    )
                    continue
                }
                releasedRoots += try deleteContextualCandidateRows(
                    candidateCID: candidateCID
                )
            }
            // Durable handoff ownership outlives any later snapshot: a
            // handed-off candidate is never demoted back to a reservation,
            // so issued and handoff stay mutually exclusive.
            for candidateCID in desired {
                try database.execute(
                    "UPDATE contextual_candidates SET issued = 1, offer_seq = NULL WHERE candidate_cid = ?1 AND handoff = 0",
                    params: [.text(candidateCID)]
                )
            }
        }
        try? await recoveryVolumeBroker.unpinBatch(
            items: releasedRoots.map {
                (root: $0, owner: contextualCandidateOwner, count: 1)
            }
        )
        try await evictExcessHandoffCandidates()
        return true
    }

    func issuedContextualCandidateCIDs() throws -> Set<String> {
        Set(try database.query(
            "SELECT candidate_cid FROM contextual_candidates WHERE issued = 1 ORDER BY candidate_cid"
        ).compactMap { $0["candidate_cid"]?.textValue })
    }

    /// Removes a candidate reference only when its immutable admission batch
    /// already owns every root. Cache age and parent RPC state are deliberately
    /// irrelevant: exported work can return later as a valid side branch.
    func removeContextualCandidateIfAdmitted(
        candidateCID: String
    ) async throws -> Bool {
        guard CIDIdentity.isCanonical(candidateCID) else {
            throw NodeStoreError.invalidConfiguration(
                "contextual candidate CID is malformed"
            )
        }
        await acquirePreparedMutation()
        defer { releasePreparedMutation() }
        let candidateRows = try database.query(
            "SELECT issued, handoff FROM contextual_candidates WHERE candidate_cid = ?1",
            params: [.text(candidateCID)]
        )
        guard !candidateRows.isEmpty else { return false }
        let candidateRoots = try database.query(
                "SELECT root_cid FROM contextual_candidate_roots WHERE candidate_cid = ?1 ORDER BY root_cid",
                params: [.text(candidateCID)]
            ).compactMap { $0["root_cid"]?.textValue }
        guard !candidateRoots.isEmpty else { return false }
        guard let rootsPayload = try database.query(
                "SELECT batch.volume_roots FROM accepted_blocks AS block INNER JOIN admission_batches AS batch ON batch.seq = block.admission_seq WHERE block.block_cid = ?1",
                params: [.text(candidateCID)]
            ).first?["volume_roots"]?.blobValue else { return false }
        let admissionRoots = Set(
            try Self.decode([String].self, from: rootsPayload)
        )
        guard Set(candidateRoots).isSubset(of: admissionRoots) else {
            return false
        }
        try database.transaction {
            try database.execute(
                "DELETE FROM contextual_candidate_roots WHERE candidate_cid = ?1",
                params: [.text(candidateCID)]
            )
            if candidateRows.first?["issued"]?.intValue == 0 {
                try database.execute(
                    "DELETE FROM contextual_candidate_children WHERE candidate_cid = ?1",
                    params: [.text(candidateCID)]
                )
                try database.execute(
                    "DELETE FROM contextual_candidates WHERE candidate_cid = ?1",
                    params: [.text(candidateCID)]
                )
            }
        }
        try? await recoveryVolumeBroker.unpinBatch(
            items: candidateRoots.map {
                (root: $0, owner: contextualCandidateOwner, count: 1)
            }
        )
        return true
    }

    func pruneAdmittedContextualCandidates() async throws {
        let candidates = try database.query(
            "SELECT candidate_cid FROM contextual_candidates ORDER BY candidate_cid"
        ).compactMap { $0["candidate_cid"]?.textValue }
        for candidate in candidates {
            _ = try await removeContextualCandidateIfAdmitted(
                candidateCID: candidate
            )
        }
    }

    /// Enforces the local storage budget on handed-off candidates. Losing a
    /// fork is a cache-eviction event, not a consensus event: a handoff is
    /// re-derivable ownership, so the oldest handoffs beyond the budget are
    /// dropped whole — row, descendants, and pins together — and a branch
    /// that returns re-enters through ordinary verified acquisition. Newest
    /// handoffs survive, so a live reservation-to-admission window keeps its
    /// pinned roots.
    func enforceHandoffCandidateBudget() async throws {
        await acquirePreparedMutation()
        defer { releasePreparedMutation() }
        try await evictExcessHandoffCandidates()
    }

    private func evictExcessHandoffCandidates() async throws {
        let stranded = try database.query(
            "SELECT candidate_cid FROM contextual_candidates WHERE handoff = 1 ORDER BY handoff_seq"
        ).compactMap { $0["candidate_cid"]?.textValue }
        let excess = stranded.count - handoffCandidateCapacity
        guard excess > 0 else { return }
        var releasedRoots: [String] = []
        try database.transaction {
            for candidateCID in stranded.prefix(excess) {
                releasedRoots += try deleteContextualCandidateRows(
                    candidateCID: candidateCID
                )
            }
        }
        try? await recoveryVolumeBroker.unpinBatch(
            items: releasedRoots.map {
                (root: $0, owner: contextualCandidateOwner, count: 1)
            }
        )
    }

    private func canonicalRecoveryRoots(sql: String) throws -> [String] {
        try database.query(sql).map { row in
            guard let cid = row["cid"]?.textValue,
                  CIDIdentity.isCanonical(cid) else {
                throw NodeStoreError.corrupt("malformed recovery attachment index")
            }
            return cid
        }
    }

    private func persistChildGenesisVolumeRoots(
        childCID: String,
        roots: [String]
    ) throws {
        guard roots.allSatisfy(CIDIdentity.isCanonical),
              Set(roots).count == roots.count else {
            throw NodeStoreError.invalidIssuedChildProof(childCID)
        }
        for root in roots {
            try database.execute(
                "INSERT OR IGNORE INTO child_genesis_volume_roots (child_cid, root_cid) VALUES (?1, ?2)",
                params: [.text(childCID), .text(root)]
            )
        }
    }

    private func retainChildGenesisVolumes(
        _ roots: [String],
        storer: any VolumeStorer
    ) async throws {
        for root in Set(roots) {
            guard let volume = await recoveryVolumeBroker.fetchVolumeLocal(
                root: root
            ) else {
                throw NodeStoreError.invalidIssuedChildProof(root)
            }
            try await storer.store(volume: volume)
        }
    }

    private func childGenesisVolumeRoots(
        childCID: String
    ) throws -> [String] {
        try database.query(
            "SELECT root_cid FROM child_genesis_volume_roots WHERE child_cid = ?1 ORDER BY root_cid",
            params: [.text(childCID)]
        ).map { row in
            guard let root = row["root_cid"]?.textValue,
                  CIDIdentity.isCanonical(root) else {
                throw NodeStoreError.corrupt(
                    "malformed child genesis Volume root"
                )
            }
            return root
        }
    }

    func portableEvidenceVolumeCID(
        scope: IssuedChildProofScope,
        edgeCID: String,
        rootCID: String
    ) throws -> String? {
        let rows = try database.query(
            "SELECT attachment_cid FROM issued_child_proofs WHERE scope = ?1 AND edge_cid = ?2 AND root_cid = ?3",
            params: [
                .text(scope.rawValue), .text(edgeCID), .text(rootCID),
            ]
        )
        guard let row = rows.first else { return nil }
        guard rows.count == 1,
              let cid = row["attachment_cid"]?.textValue,
              CIDIdentity.isCanonical(cid) else {
            throw NodeStoreError.corrupt("malformed portable recovery attachment index")
        }
        return cid
    }

    /// Permanent root-independent hops already published by this parent.
    /// They outlive the bounded pre-publication recovery buffer and can be
    /// recomposed whenever this carrier gains another authenticated root.
    func retainedDirectChildProofs(
        carrierCID: String
    ) async throws -> [PreparedChildProof] {
        let rows = try database.query(
            "SELECT DISTINCT p.edge_cid FROM issued_child_proofs AS p INNER JOIN issued_child_edges AS e ON e.edge_cid = p.edge_cid WHERE p.scope = ?1 AND e.parent_carrier_cid = ?2 ORDER BY p.edge_cid",
            params: [
                .text(IssuedChildProofScope.outgoingDirectChild.rawValue),
                .text(carrierCID),
            ]
        )
        var proofs: [PreparedChildProof] = []
        proofs.reserveCapacity(rows.count)
        for row in rows {
            guard let edgeCID = row["edge_cid"]?.textValue,
                  let evidence = try await issuedChildEvidence(
                    scope: .outgoingDirectChild,
                    edgeCID: edgeCID
                  ), let proof = evidence.edge.proof else {
                throw NodeStoreError.corrupt("malformed retained direct-child edge")
            }
            let bootstrapRoots = try childGenesisVolumeRoots(
                childCID: evidence.edge.childCID
            )
            proofs.append(try PreparedChildProof(
                directory: evidence.edge.directory,
                childCID: evidence.edge.childCID,
                isChildGenesis: !bootstrapRoots.isEmpty,
                bootstrapRoots: bootstrapRoots,
                proof: proof
            ))
        }
        return proofs
    }

    /// A contextual candidate's child-link trie exists before that candidate is
    /// admitted. Keep a bounded durable direct-hop batch so a restart cannot
    /// prevent the admitted carrier from relaying work to its descendants.
    func persistPreparedChildProofs(
        carrierCID: String,
        proofs: [PreparedChildProof],
        capacity: Int
    ) async throws {
        guard capacity > 0, let sqlCapacity = Int64(exactly: capacity) else {
            throw NodeStoreError.invalidConfiguration(
                "prepared child-proof capacity must be positive"
            )
        }
        var canonical: [(
            directory: String,
            childCID: String,
            isChildGenesis: Bool,
            bootstrapRoots: [String],
            attachment: ChildEvidenceVolume
        )] = []
        var directories = Set<String>()
        for entry in proofs.sorted(by: { $0.directory < $1.directory }) {
            guard !entry.directory.isEmpty,
                  directories.insert(entry.directory).inserted,
                  entry.isChildGenesis || entry.bootstrapRoots.isEmpty,
                  entry.bootstrapRoots.isEmpty
                    || entry.bootstrapRoots.contains(entry.childCID),
                  entry.proof.rootCID == carrierCID,
                  entry.proof.directoryPath == [entry.directory],
                  await entry.proof.directHop()?.childCID == entry.childCID else {
                throw NodeStoreError.invalidIssuedChildProof(entry.childCID)
            }
            let payload = try entry.proof.serialize()
            guard ChildBlockProof.deserialize(payload) != nil else {
                throw NodeStoreError.invalidIssuedChildProof(entry.childCID)
            }
            canonical.append((
                entry.directory,
                entry.childCID,
                entry.isChildGenesis,
                entry.bootstrapRoots,
                try ChildEvidenceVolume(
                    envelopeBytes: try ChildValidationPackageEnvelope(
                        ChildValidationPackage(proof: entry.proof)
                    ).encode(),
                    childCID: entry.childCID
                )
            ))
        }
        guard !canonical.isEmpty else { return }
        await acquirePreparedMutation()
        defer { releasePreparedMutation() }
        do {
            try await retainChildGenesisVolumes(
                canonical.flatMap(\.bootstrapRoots),
                storer: recoveryVolumeBroker
            )
            for entry in canonical {
                try await entry.attachment.store(
                    storer: recoveryVolumeBroker
                )
            }
            try await mergeRecoveryRetention(
                scope: preparedRecoveryRetentionScope,
                roots: canonical.flatMap(\.bootstrapRoots)
                    + canonical.map(\.attachment.rawCID)
            )

            try database.transaction {
                for entry in canonical {
                    try persistChildGenesisVolumeRoots(
                        childCID: entry.childCID,
                        roots: entry.bootstrapRoots
                    )
                }
                let existing = try database.query(
                    "SELECT batch_seq, directory, child_cid, is_child_genesis, attachment_cid FROM prepared_child_proofs WHERE carrier_cid = ?1 ORDER BY directory",
                    params: [.text(carrierCID)]
                )
                let existingByDirectory = Dictionary(
                    uniqueKeysWithValues: try existing.map { row in
                        guard let directory = row["directory"]?.textValue else {
                            throw NodeStoreError.corrupt(
                                "malformed prepared child-proof directory"
                            )
                        }
                        return (directory, row)
                    }
                )
                for expected in canonical {
                    if let row = existingByDirectory[expected.directory] {
                        guard row["child_cid"]?.textValue == expected.childCID,
                              row["is_child_genesis"]?.intValue
                                == (expected.isChildGenesis ? 1 : 0),
                              row["attachment_cid"]?.textValue
                                == expected.attachment.rawCID else {
                            throw NodeStoreError.conflictingIssuedChildProof
                        }
                    }
                }

                let batchSequence: Int64
                if let first = existing.first {
                    guard let sequence = first["batch_seq"]?.intValue,
                          existing.allSatisfy({
                              $0["batch_seq"]?.intValue == sequence
                          }) else {
                        throw NodeStoreError.corrupt(
                            "malformed prepared child-proof sequence"
                        )
                    }
                    batchSequence = sequence
                } else {
                    let sequence = try database.query(
                        "SELECT COALESCE(MAX(batch_seq), 0) AS max_seq FROM prepared_child_proofs"
                    ).first?["max_seq"]?.intValue ?? 0
                    guard sequence < Int64.max else {
                        throw NodeStoreError.corrupt(
                            "prepared child-proof sequence overflow"
                        )
                    }
                    batchSequence = sequence + 1
                }

                for entry in canonical where existingByDirectory[entry.directory] == nil {
                    do {
                        try database.execute(
                            "INSERT INTO prepared_child_proofs (carrier_cid, batch_seq, directory, child_cid, is_child_genesis, attachment_cid) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                            params: [
                                .text(carrierCID),
                                .int(batchSequence),
                                .text(entry.directory),
                                .text(entry.childCID),
                                .int(entry.isChildGenesis ? 1 : 0),
                                .text(entry.attachment.rawCID),
                            ]
                        )
                    } catch {
                        throw NodeStoreError.conflictingIssuedChildProof
                    }
                }
                let pinnedCount = try database.query(
                    "SELECT COUNT(DISTINCT p.carrier_cid) AS carrier_count FROM prepared_child_proofs AS p INNER JOIN contextual_candidate_roots AS c ON c.candidate_cid = p.carrier_cid"
                ).first?["carrier_count"]?.intValue ?? 0
                let speculativeCapacity = max(0, sqlCapacity - pinnedCount)
                let stale = try database.query(
                    "SELECT p.carrier_cid FROM prepared_child_proofs AS p WHERE NOT EXISTS (SELECT 1 FROM contextual_candidate_roots AS c WHERE c.candidate_cid = p.carrier_cid) AND NOT EXISTS (SELECT 1 FROM pending_child_proof_routes AS route WHERE route.carrier_cid = p.carrier_cid) AND NOT EXISTS (SELECT 1 FROM accepted_blocks AS block WHERE block.block_cid = p.carrier_cid) GROUP BY p.carrier_cid ORDER BY MIN(p.batch_seq) DESC, p.carrier_cid DESC LIMIT -1 OFFSET ?1",
                    params: [.int(speculativeCapacity)]
                )
                for row in stale {
                    guard let staleCID = row["carrier_cid"]?.textValue else {
                        throw NodeStoreError.corrupt("malformed prepared child-proof index")
                    }
                    try database.execute(
                        "DELETE FROM prepared_child_proofs WHERE carrier_cid = ?1",
                        params: [.text(staleCID)]
                    )
                }
                try pruneUnreferencedChildGenesisVolumeRoots()
            }
            try await reconcilePreparedRecoveryRetention()
        } catch {
            try? await reconcilePreparedRecoveryRetention()
            throw error
        }
    }

    /// Records bounded proof work before consensus admission can make a carrier
    /// externally visible. A missing route stays retryable across a crash.
    func persistPendingChildProofRoutes(
        carrierCID: String,
        directories: [String],
        capacity: Int
    ) throws {
        let canonical = Array(Set(directories)).sorted()
        guard !carrierCID.isEmpty,
              !canonical.isEmpty,
              canonical.allSatisfy({ !$0.isEmpty }) else { return }
        try database.transaction {
            try persistPendingChildProofRouteRows(
                canonical.map {
                    PendingChildProofRoute(
                        carrierCID: carrierCID,
                        directory: $0
                    )
                },
                capacity: capacity
            )
        }
    }

    private func persistPendingChildProofRouteRows(
        _ routes: [PendingChildProofRoute],
        capacity: Int
    ) throws {
        guard capacity > 0, let sqlCapacity = Int64(exactly: capacity) else {
            throw NodeStoreError.invalidConfiguration(
                "pending child-proof capacity must be positive"
            )
        }
        guard !routes.isEmpty else { return }
        for (carrierCID, carrierRoutes) in Dictionary(
            grouping: routes,
            by: \.carrierCID
        ) {
            let existing = try database.query(
                "SELECT batch_seq FROM pending_child_proof_routes WHERE carrier_cid = ?1 LIMIT 1",
                params: [.text(carrierCID)]
            ).first?["batch_seq"]?.intValue
            let batchSequence: Int64
            if let existing {
                batchSequence = existing
            } else {
                let maximum = try database.query(
                    "SELECT COALESCE(MAX(batch_seq), 0) AS max_seq FROM pending_child_proof_routes"
                ).first?["max_seq"]?.intValue ?? 0
                guard maximum < Int64.max else {
                    throw NodeStoreError.corrupt(
                        "pending child-proof sequence overflow"
                    )
                }
                batchSequence = maximum + 1
            }
            for route in carrierRoutes {
                try database.execute(
                    "INSERT OR IGNORE INTO pending_child_proof_routes (carrier_cid, batch_seq, directory) VALUES (?1, ?2, ?3)",
                    params: [
                        .text(carrierCID),
                        .int(batchSequence),
                        .text(route.directory),
                    ]
                )
            }
        }
        let stale = try database.query(
            "SELECT route.carrier_cid FROM pending_child_proof_routes AS route WHERE NOT EXISTS (SELECT 1 FROM accepted_blocks AS block WHERE block.block_cid = route.carrier_cid) AND NOT EXISTS (SELECT 1 FROM issued_parent_facts AS fact WHERE fact.kind = 'carrier' AND fact.key_a = route.carrier_cid) GROUP BY route.carrier_cid ORDER BY MIN(route.batch_seq) DESC, route.carrier_cid DESC LIMIT -1 OFFSET ?1",
            params: [.int(sqlCapacity)]
        )
        for row in stale {
            guard let staleCID = row["carrier_cid"]?.textValue else {
                throw NodeStoreError.corrupt(
                    "malformed pending child-proof index"
                )
            }
            try database.execute(
                "DELETE FROM pending_child_proof_routes WHERE carrier_cid = ?1",
                params: [.text(staleCID)]
            )
        }
    }

    private func pendingRoutesIncludingPreparedProofs(
        _ routes: [PendingChildProofRoute],
        carrierCIDs: Set<String>
    ) throws -> [PendingChildProofRoute] {
        var result = Set(routes)
        for carrierCID in carrierCIDs {
            for row in try database.query(
                "SELECT directory FROM prepared_child_proofs WHERE carrier_cid = ?1",
                params: [.text(carrierCID)]
            ) {
                guard let directory = row["directory"]?.textValue else {
                    throw NodeStoreError.corrupt(
                        "malformed prepared child-proof directory"
                    )
                }
                result.insert(PendingChildProofRoute(
                    carrierCID: carrierCID,
                    directory: directory
                ))
            }
        }
        return result.sorted {
            ($0.carrierCID, $0.directory) < ($1.carrierCID, $1.directory)
        }
    }

    func removePendingChildProofRoutes(
        carrierCID: String,
        directories: [String]
    ) throws {
        for directory in Set(directories) {
            try database.execute(
                "DELETE FROM pending_child_proof_routes WHERE carrier_cid = ?1 AND directory = ?2",
                params: [.text(carrierCID), .text(directory)]
            )
        }
    }

    func pendingChildProofRoutes() throws -> [PendingChildProofRoute] {
        try database.query(
            "SELECT carrier_cid, directory FROM pending_child_proof_routes ORDER BY batch_seq, carrier_cid, directory"
        ).map { row in
            guard let carrierCID = row["carrier_cid"]?.textValue,
                  let directory = row["directory"]?.textValue,
                  !carrierCID.isEmpty,
                  !directory.isEmpty else {
                throw NodeStoreError.corrupt(
                    "malformed pending child-proof route"
                )
            }
            return PendingChildProofRoute(
                carrierCID: carrierCID,
                directory: directory
            )
        }
    }

    func preparedChildProofs(carrierCID: String) async throws -> [PreparedChildProof] {
        let rows = try database.query(
            "SELECT directory, child_cid, is_child_genesis, attachment_cid FROM prepared_child_proofs WHERE carrier_cid = ?1 ORDER BY directory",
            params: [.text(carrierCID)]
        )
        var proofs: [PreparedChildProof] = []
        proofs.reserveCapacity(rows.count)
        for row in rows {
            guard let directory = row["directory"]?.textValue,
                  let childCID = row["child_cid"]?.textValue,
                  let isChildGenesis = row["is_child_genesis"]?.intValue,
                  isChildGenesis == 0 || isChildGenesis == 1,
                  let attachmentCID = row["attachment_cid"]?.textValue else {
                throw NodeStoreError.corrupt("malformed prepared child proof")
            }
            let attachment = try await recoveryVolume(
                attachmentCID: attachmentCID,
                childCID: childCID
            )
            guard let envelope = try? ChildValidationPackageEnvelope.decode(
                      attachment.envelopeBytes
                  ),
                  let proof = ChildBlockProof.deserialize(envelope.proofBytes),
                  (try? proof.serialize()) == envelope.proofBytes,
                  proof.rootCID == carrierCID,
                  proof.directoryPath == [directory],
                  await proof.directHop()?.childCID == childCID else {
                throw NodeStoreError.corrupt("malformed prepared child proof")
            }
            proofs.append(try PreparedChildProof(
                directory: directory,
                childCID: childCID,
                isChildGenesis: isChildGenesis == 1,
                bootstrapRoots: try childGenesisVolumeRoots(
                    childCID: childCID
                ),
                proof: proof
            ))
        }
        return proofs
    }

    func preparedChildProofCarrierCIDs() async throws -> [String] {
        try database.query(
            "SELECT carrier_cid FROM prepared_child_proofs GROUP BY carrier_cid ORDER BY MIN(batch_seq), carrier_cid"
        ).map { row in
            guard let carrierCID = row["carrier_cid"]?.textValue else {
                throw NodeStoreError.corrupt("malformed prepared child-proof carrier index")
            }
            return carrierCID
        }
    }

    func removePreparedChildProof(
        carrierCID: String,
        directory: String
    ) async throws {
        await acquirePreparedMutation()
        defer { releasePreparedMutation() }
        do {
            try database.transaction {
                try database.execute(
                    "DELETE FROM prepared_child_proofs WHERE carrier_cid = ?1 AND directory = ?2",
                    params: [.text(carrierCID), .text(directory)]
                )
                try pruneUnreferencedChildGenesisVolumeRoots()
            }
            try await reconcilePreparedRecoveryRetention()
        } catch {
            try? await reconcilePreparedRecoveryRetention()
            throw error
        }
    }

    private func pruneUnreferencedChildGenesisVolumeRoots() throws {
        try database.execute("""
            DELETE FROM child_genesis_volume_roots
            WHERE child_cid NOT IN (
                SELECT child_cid FROM prepared_child_proofs
                UNION
                SELECT child_cid FROM issued_child_edges
            )
            """)
    }

    /// Durable direct edges can outlive their bounded preparation row. Return
    /// only carriers whose retained edge has a newly learned upstream root
    /// that has not been composed into an outgoing attachment yet.
    func uncomposedDirectChildProofCarrierCIDs(
        parentDirectory: String
    ) async throws -> [String] {
        guard !parentDirectory.isEmpty else { return [] }
        return try database.query(
            """
            SELECT DISTINCT outgoing_edge.parent_carrier_cid AS carrier_cid
            FROM issued_child_edges AS outgoing_edge
            INNER JOIN issued_child_proofs AS retained
                ON retained.edge_cid = outgoing_edge.edge_cid
                AND retained.scope = ?1
            INNER JOIN issued_child_edges AS incoming_edge
                ON incoming_edge.child_cid = outgoing_edge.parent_carrier_cid
                AND incoming_edge.directory = ?2
            INNER JOIN issued_child_proofs AS incoming
                ON incoming.edge_cid = incoming_edge.edge_cid
                AND incoming.scope = ?3
            WHERE NOT EXISTS (
                SELECT 1
                FROM issued_child_proofs AS composed
                WHERE composed.scope = ?1
                    AND composed.edge_cid = outgoing_edge.edge_cid
                    AND composed.root_cid = incoming.root_cid
            )
            ORDER BY carrier_cid
            """,
            params: [
                .text(IssuedChildProofScope.outgoingDirectChild.rawValue),
                .text(parentDirectory),
                .text(IssuedChildProofScope.incomingCarrier.rawValue),
            ]
        ).map { row in
            guard let carrierCID = row["carrier_cid"]?.textValue else {
                throw NodeStoreError.corrupt(
                    "malformed uncomposed direct-child carrier index"
                )
            }
            return carrierCID
        }
    }

    private func loadStagedAdmissions() throws -> [StagedAdmission] {
        try database.query(
            "SELECT seq, payload, volume_roots FROM admission_batches ORDER BY seq ASC"
        ).map { row in
            guard let sequence = row["seq"]?.intValue,
                  let payload = row["payload"]?.blobValue,
                  let rootsPayload = row["volume_roots"]?.blobValue else {
                throw NodeStoreError.corrupt("malformed admission batch row")
            }
            return StagedAdmission(
                sequence: sequence,
                batch: try Self.decode(ChainAdmissionBatch.self, from: payload),
                volumeRoots: try Self.decode([String].self, from: rootsPayload)
            )
        }
    }

    private func persistIssuedParentFact(
        kind: String,
        keyA: String,
        keyB: String,
        payload: Data
    ) throws {
        guard !keyA.isEmpty, !keyB.isEmpty else {
            throw NodeStoreError.invalidConfiguration(
                "issued parent fact keys must be nonempty"
            )
        }
        let rows = try database.query(
            "SELECT payload FROM issued_parent_facts WHERE kind = ?1 AND key_a = ?2 AND key_b = ?3",
            params: [.text(kind), .text(keyA), .text(keyB)]
        )
        if let existing = rows.first?["payload"]?.blobValue {
            guard existing == payload else {
                throw NodeStoreError.conflictingIssuedParentFact
            }
            return
        }
        try database.execute(
            "INSERT INTO issued_parent_facts (kind, key_a, key_b, payload) VALUES (?1, ?2, ?3, ?4)",
            params: [
                .text(kind), .text(keyA), .text(keyB), .blob(payload),
            ]
        )
    }

    private func issuedParentFact(
        kind: String,
        keyA: String,
        keyB: String
    ) throws -> Data? {
        return try database.query(
            "SELECT payload FROM issued_parent_facts WHERE kind = ?1 AND key_a = ?2 AND key_b = ?3",
            params: [.text(kind), .text(keyA), .text(keyB)]
        ).first?["payload"]?.blobValue
    }

    private static func addExpectedParentFact(
        key: IssuedParentFactKey,
        payload: Data,
        to facts: inout [IssuedParentFactKey: Data]
    ) throws {
        if let existing = facts[key], existing != payload {
            throw NodeStoreError.corrupt(
                "parent-fact sources disagree about an immutable fact"
            )
        }
        facts[key] = payload
    }

    private static func validateMetadata(
        in database: NodeSQLite,
        tableNames: Set<String>,
        schemaEpoch: Int64,
        nexusGenesisCID: String,
        chainPath: Data
    ) throws {
        guard tableNames.contains("node_metadata") else {
            throw NodeStoreError.wipeRequired("missing schema metadata")
        }
        let rows: [[String: NodeSQLiteValue]]
        do {
            rows = try database.query(
                "SELECT schema_epoch, nexus_genesis_cid, chain_path, sync_source_id FROM node_metadata WHERE singleton = 1"
            )
        } catch {
            throw NodeStoreError.wipeRequired("unreadable schema metadata")
        }
        guard rows.count == 1,
              rows[0]["schema_epoch"]?.intValue == schemaEpoch,
              rows[0]["nexus_genesis_cid"]?.textValue == nexusGenesisCID,
              rows[0]["chain_path"]?.blobValue == chainPath,
              let syncSourceID = rows[0]["sync_source_id"]?.textValue,
              UUID(uuidString: syncSourceID) != nil else {
            throw NodeStoreError.wipeRequired(
                "schema epoch, Nexus genesis, or chain path changed"
            )
        }
    }

    private static let expectedTables: Set<String> = [
        "node_metadata",
        "consensus_revision",
        "admission_batches",
        "admission_facts",
        "accepted_blocks",
        "issued_parent_fact_sources",
        "issued_parent_facts",
        "issued_child_edges",
        "issued_child_proofs",
        "parent_evidence_scan",
        "parent_evidence_inbox",
        "local_mempool_transactions",
        "child_genesis_volume_roots",
        "prepared_child_proofs",
        "pending_child_proof_routes",
        "contextual_candidates",
        "contextual_candidate_roots",
        "contextual_candidate_children",
    ]

    private static func createSchema(
        in database: NodeSQLite,
        schemaEpoch: Int64,
        nexusGenesisCID: String,
        chainPath: Data
    ) throws {
        try database.transaction {
            try database.execute("""
                CREATE TABLE node_metadata (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    schema_epoch INTEGER NOT NULL,
                    nexus_genesis_cid TEXT NOT NULL,
                    chain_path BLOB NOT NULL,
                    sync_source_id TEXT NOT NULL
                )
                """)
            try database.execute(
                "INSERT INTO node_metadata (singleton, schema_epoch, nexus_genesis_cid, chain_path, sync_source_id) VALUES (1, ?1, ?2, ?3, ?4)",
                params: [
                    .int(schemaEpoch),
                    .text(nexusGenesisCID),
                    .blob(chainPath),
                    .text(UUID().uuidString.lowercased()),
                ]
            )
            try createDataTables(in: database)
        }
    }

    private static func createDataTables(in database: NodeSQLite) throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS consensus_revision (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                revision TEXT NOT NULL
            ) WITHOUT ROWID
            """)
        try database.execute(
            "INSERT OR IGNORE INTO consensus_revision (singleton, revision) VALUES (1, '0')"
        )
        try database.execute("""
            CREATE TABLE IF NOT EXISTS admission_batches (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                payload BLOB NOT NULL UNIQUE,
                volume_roots BLOB NOT NULL
            )
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS admission_facts (
                fact_id BLOB PRIMARY KEY,
                payload BLOB NOT NULL
            ) WITHOUT ROWID
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS accepted_blocks (
                block_cid TEXT PRIMARY KEY,
                parent_cid TEXT,
                admission_seq INTEGER NOT NULL
            ) WITHOUT ROWID
            """)
        try database.execute(
            "CREATE INDEX IF NOT EXISTS accepted_blocks_by_parent ON accepted_blocks (parent_cid, admission_seq, block_cid)"
        )
        try database.execute("""
            CREATE TABLE IF NOT EXISTS issued_parent_fact_sources (
                payload BLOB PRIMARY KEY
            ) WITHOUT ROWID
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS issued_parent_facts (
                kind TEXT NOT NULL,
                key_a TEXT NOT NULL,
                key_b TEXT NOT NULL,
                payload BLOB NOT NULL,
                PRIMARY KEY (kind, key_a, key_b)
            ) WITHOUT ROWID
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS issued_child_edges (
                edge_cid TEXT PRIMARY KEY,
                parent_carrier_cid TEXT NOT NULL,
                directory TEXT NOT NULL,
                child_cid TEXT NOT NULL,
                UNIQUE (parent_carrier_cid, directory, child_cid)
            ) WITHOUT ROWID
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS issued_child_proofs (
                scope TEXT NOT NULL,
                edge_cid TEXT NOT NULL,
                root_cid TEXT NOT NULL,
                attachment_cid TEXT NOT NULL,
                ordinal INTEGER UNIQUE CHECK (ordinal IS NULL OR ordinal > 0),
                CHECK (
                    (scope = 'outgoing_direct_child' AND ordinal IS NOT NULL)
                    OR (scope != 'outgoing_direct_child' AND ordinal IS NULL)
                ),
                PRIMARY KEY (scope, edge_cid, root_cid)
            )
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS parent_evidence_scan (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                source_id TEXT,
                ordinal INTEGER NOT NULL CHECK (ordinal >= 0)
            ) WITHOUT ROWID
            """)
        try database.execute(
            "INSERT OR IGNORE INTO parent_evidence_scan (singleton, source_id, ordinal) VALUES (1, NULL, 0)"
        )
        try database.execute("""
            CREATE TABLE IF NOT EXISTS parent_evidence_inbox (
                source_id TEXT NOT NULL,
                ordinal INTEGER NOT NULL CHECK (ordinal > 0),
                child_cid TEXT NOT NULL,
                root_cid TEXT NOT NULL,
                attachment_cid TEXT NOT NULL,
                PRIMARY KEY (source_id, ordinal),
                UNIQUE (source_id, attachment_cid)
            ) WITHOUT ROWID
            """)
        try database.execute(
            "CREATE INDEX IF NOT EXISTS issued_child_edges_by_directory ON issued_child_edges (directory, child_cid, edge_cid)"
        )
        try database.execute(
            "CREATE INDEX IF NOT EXISTS issued_child_edges_by_child ON issued_child_edges (child_cid, parent_carrier_cid, edge_cid)"
        )
        try database.execute("""
            CREATE TABLE IF NOT EXISTS local_mempool_transactions (
                transaction_cid TEXT PRIMARY KEY,
                added_at INTEGER NOT NULL CHECK (added_at >= 0)
            ) WITHOUT ROWID
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS child_genesis_volume_roots (
                child_cid TEXT NOT NULL,
                root_cid TEXT NOT NULL,
                PRIMARY KEY (child_cid, root_cid)
            ) WITHOUT ROWID
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS prepared_child_proofs (
                carrier_cid TEXT NOT NULL,
                batch_seq INTEGER NOT NULL,
                directory TEXT NOT NULL,
                child_cid TEXT NOT NULL,
                is_child_genesis INTEGER NOT NULL
                    CHECK (is_child_genesis IN (0, 1)),
                attachment_cid TEXT NOT NULL,
                PRIMARY KEY (carrier_cid, directory)
            ) WITHOUT ROWID
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS pending_child_proof_routes (
                carrier_cid TEXT NOT NULL,
                batch_seq INTEGER NOT NULL,
                directory TEXT NOT NULL,
                PRIMARY KEY (carrier_cid, directory)
            ) WITHOUT ROWID
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS contextual_candidates (
                candidate_cid TEXT PRIMARY KEY,
                offer_seq INTEGER UNIQUE,
                issued INTEGER NOT NULL CHECK (issued IN (0, 1)),
                handoff INTEGER NOT NULL CHECK (handoff IN (0, 1)),
                handoff_seq INTEGER UNIQUE,
                CHECK (offer_seq IS NULL OR offer_seq > 0),
                CHECK (issued = 1 OR handoff = 1 OR offer_seq IS NOT NULL),
                CHECK (NOT (issued = 1 AND handoff = 1)),
                CHECK ((handoff = 1) = (handoff_seq IS NOT NULL))
            ) WITHOUT ROWID
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS contextual_candidate_roots (
                candidate_cid TEXT NOT NULL,
                root_cid TEXT NOT NULL,
                PRIMARY KEY (candidate_cid, root_cid)
            ) WITHOUT ROWID
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS contextual_candidate_children (
                candidate_cid TEXT NOT NULL,
                child_peer_key TEXT NOT NULL,
                child_cid TEXT NOT NULL,
                PRIMARY KEY (candidate_cid, child_peer_key, child_cid)
            ) WITHOUT ROWID
            """)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw NodeStoreError.corrupt(String(describing: error))
        }
    }

    private static func normalizedFacts(
        in batch: ChainAdmissionBatch
    ) throws -> [Data: Data] {
        var normalized: [Data: Data] = [:]
        for fact in batch.facts {
            let id = try encode(fact.id)
            let payload = try encode(fact)
            if let existing = normalized[id], existing != payload {
                throw NodeStoreError.conflictingAdmissionFact
            }
            normalized[id] = payload
        }
        return normalized
    }

    /// Checks only the content-addressed root-to-leaf association and path
    /// scope. Consensus work and transition validity remain Lattice's job.
    private static func proves(
        _ proof: ChildBlockProof,
        childCID: String,
        from chainPath: [String]
    ) async throws -> Bool {
        let localPath = Array(chainPath.dropFirst())
        let provesSelf = !localPath.isEmpty && proof.directoryPath == localPath
        let provesDirectChild = proof.directoryPath.count == localPath.count + 1
            && proof.directoryPath.starts(with: localPath)
        guard !proof.rootCID.isEmpty,
              provesSelf || provesDirectChild,
              proof.directoryPath.allSatisfy({ !$0.isEmpty }) else {
            return false
        }
        return await proof.directHop()?.childCID == childCID
    }

}

/// Records the canonical Volume boundaries materialized during one admission.
actor NodeAdmissionStorage: VolumeStorer {
    private let storage: any VolumeStorer
    private var roots = Set<String>()

    init(storage: any VolumeStorer) {
        self.storage = storage
    }

    func store(volume: SerializedVolume) async throws {
        try await storage.store(volume: volume)
        roots.insert(volume.root)
    }

    func takeStoredVolumeRoots() -> [String] {
        defer { roots.removeAll(keepingCapacity: true) }
        return roots.sorted()
    }
}
