import Foundation
import Ivy
import Lattice
import UInt256
import VolumeBroker
import cashew

struct StagedAdmission: Sendable, Equatable {
    let sequence: Int64
    let batch: BlockImportBatch
    let volumeRoots: [String]
}

/// `admission_batches`: one immutable admission batch; `payload` and
/// `volumeRoots` are the JSON bytes, decoded by the caller so a decode
/// failure stays `corrupt`.
struct AdmissionBatchRow: NodeStoreRecord {
    static let table = "admission_batches"
    private let row: Row

    init(_ row: Row) { self.row = row }

    var sequence: Int64 { get throws { try row.int("seq") } }
    var payload: Data { get throws { try row.blob("payload") } }
    var volumeRoots: Data { get throws { try row.blob("volume_roots") } }
}

/// `admission_facts`: one normalized fact of an admission batch.
struct AdmissionFactRow: NodeStoreRecord {
    static let table = "admission_facts"
    private let row: Row

    init(_ row: Row) { self.row = row }

    var factID: Data { get throws { try row.blob("fact_id") } }
    var payload: Data { get throws { try row.blob("payload") } }
}

/// `consensus_revision`: the durable revision floor, stored as decimal text.
struct ConsensusRevisionRow: NodeStoreRecord {
    static let table = "consensus_revision"
    private let row: Row

    init(_ row: Row) { self.row = row }

    var revision: UInt64 {
        get throws {
            guard let value = UInt64(try row.text("revision")) else {
                throw NodeStoreError.malformedRow(table: Self.table, column: "revision")
            }
            return value
        }
    }
}

extension NodeStore {
    func stage(
        _ batch: BlockImportBatch,
        volumeRoots: [String],
        persistence: ImportPersistence = .factsOnly
    ) async throws {
        let payload = try Self.encode(batch)
        let factsInBatch = try Self.normalizedFacts(in: batch)
        let facts = factsInBatch.sorted { $0.key.lexicographicallyPrecedes($1.key) }
        let acceptedBlocks = try Self.acceptedBlocks(in: batch)
        let pendingRoutes = Array(Set(persistence.pendingChildProofRoutes)).sorted {
            ($0.carrierCID, $0.directory) < ($1.carrierCID, $1.directory)
        }
        let carrierCIDs = Set(batch.facts.map { fact -> String in
            switch fact {
            case .block(let block): block.blockHash
            case .work(let work): work.blockHash
            // An exclusion is a standalone verdict on an already-durable block
            // (no routes, artifacts, or carrier evidence ride with it), so its
            // subject hash is inert for route gating here; carry it for
            // consistency. The fact itself is still persisted via normalizedFacts
            // so recovery replays it and rebuilds the excluded set.
            case .exclusion(let fact): fact.blockHash
            // A validation, like an exclusion, is a standalone judgment on an
            // already-durable block: it rides with no routes, artifacts or
            // carrier evidence, so its subject hash is inert for route gating.
            // Carried for consistency; the fact is persisted via
            // normalizedFacts so recovery replays it.
            case .validation(let fact): fact.blockHash
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
            persistence.hierarchyArtifacts,
            carrierCIDs: carrierCIDs
        )
        let preparedIncomingCarrierEvidence: PreparedAdmissionCarrierEvidence?
        if let incomingCarrierEvidence = persistence.incomingCarrierEvidence {
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
                    let existing = try database.row(
                        AdmissionFactRow.self,
                        "SELECT payload FROM admission_facts WHERE fact_id = ?1",
                        params: [.blob(fact.key)]
                    )
                    if let existing {
                        guard try existing.payload == fact.value else {
                            throw NodeStoreError.conflictingAdmissionFact
                        }
                    }
                }

                let replay = try database.row(
                    AdmissionBatchRow.self,
                    "SELECT seq, volume_roots FROM admission_batches WHERE payload = ?1",
                    params: [.blob(payload)]
                )
                if let existing = replay {
                    let existingSequence = try existing.sequence
                    guard try existing.volumeRoots == rootsPayload else {
                        throw NodeStoreError.conflictingAdmissionBatch
                    }
                    for fact in facts {
                        let existing = try database.row(
                            AdmissionFactRow.self,
                            "SELECT payload FROM admission_facts WHERE fact_id = ?1",
                            params: [.blob(fact.key)]
                        )
                        guard try existing?.payload == fact.value else {
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
                    guard let admissionSequence = try database.row(
                        AdmissionBatchRow.self,
                        "SELECT seq FROM admission_batches WHERE payload = ?1",
                        params: [.blob(payload)]
                    )?.sequence else {
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
                        admissionSequence: admissionSequence,
                        status: persistence.status
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
                    try deleteParentEvidenceInbox(attachmentCID: attachmentCID)
                }
                try persistPendingChildProofRouteRows(
                    try pendingRoutesIncludingPreparedProofs(
                        pendingRoutes,
                        carrierCIDs: Set(acceptedBlocks.map(\.blockCID))
                    ),
                    capacity: persistence.pendingChildProofCapacity
                )
                if let consensusRevisionFloor = persistence.consensusRevisionFloor {
                    try persistConsensusRevisionFloor(consensusRevisionFloor)
                }
        }
        if preparedHierarchyArtifacts?.carrierEvidence != nil
            || preparedIncomingCarrierEvidence != nil
        {
            await reconcileParentEvidenceInboxRetention()
        }
    }

    func stagedAdmissions() async throws -> [StagedAdmission] {
        try loadStagedAdmissions()
    }

    func consensusRevisionFloor() throws -> UInt64 {
        let rows = try database.rows(
            ConsensusRevisionRow.self,
            "SELECT revision FROM consensus_revision WHERE singleton = 1"
        )
        guard rows.count == 1 else {
            throw NodeStoreError.corrupt("malformed consensus revision floor")
        }
        return try rows[0].revision
    }

    private func persistConsensusRevisionFloor(_ floor: UInt64) throws {
        let current = try consensusRevisionFloor()
        guard floor > current else { return }
        try database.execute(
            "UPDATE consensus_revision SET revision = ?1 WHERE singleton = 1",
            params: [.text(String(floor))]
        )
    }

    func loadStagedAdmissions() throws -> [StagedAdmission] {
        try database.rows(
            AdmissionBatchRow.self,
            "SELECT seq, payload, volume_roots FROM admission_batches ORDER BY seq ASC"
        ).map { row in
            StagedAdmission(
                sequence: try row.sequence,
                batch: try Self.decode(BlockImportBatch.self, from: try row.payload),
                volumeRoots: try Self.decode([String].self, from: try row.volumeRoots)
            )
        }
    }

    private static func normalizedFacts(
        in batch: BlockImportBatch
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

    func auditAdmissionFacts(staged: [StagedAdmission]) throws {
        var expectedFacts: [Data: Data] = [:]
        for admission in staged {
            for (id, payload) in try Self.normalizedFacts(in: admission.batch) {
                if let existing = expectedFacts[id], existing != payload {
                    throw NodeStoreError.corrupt(
                        "admission batches disagree about an immutable fact"
                    )
                }
                expectedFacts[id] = payload
            }
        }

        var actualFacts: [Data: Data] = [:]
        for row in try database.rows(
            AdmissionFactRow.self, "SELECT fact_id, payload FROM admission_facts"
        ) {
            actualFacts[try row.factID] = try row.payload
        }
        guard actualFacts == expectedFacts else {
            throw NodeStoreError.corrupt(
                "normalized admission facts do not match immutable batches"
            )
        }
    }
}
