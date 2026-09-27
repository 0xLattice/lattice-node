import Foundation
import Ivy
import Lattice
import UInt256
import VolumeBroker
import cashew

struct StagedAdmission: Sendable, Equatable {
    let sequence: Int64
    let batch: ChainAdmissionBatch
    let volumeRoots: [String]
}

extension NodeStore {
    func stage(
        _ batch: ChainAdmissionBatch,
        volumeRoots: [String],
        validated: Bool = true,
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
                        admissionSequence: admissionSequence,
                        validated: validated
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
                    capacity: pendingChildProofCapacity
                )
                if let consensusRevisionFloor {
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

    private func persistConsensusRevisionFloor(_ floor: UInt64) throws {
        let current = try consensusRevisionFloor()
        guard floor > current else { return }
        try database.execute(
            "UPDATE consensus_revision SET revision = ?1 WHERE singleton = 1",
            params: [.text(String(floor))]
        )
    }

    func loadStagedAdmissions() throws -> [StagedAdmission] {
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

    static func normalizedFacts(
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
    }
}
