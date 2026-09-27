import Foundation
import Ivy
import Lattice
import UInt256
import VolumeBroker
import cashew

extension NodeStore {
    /// Owner: ImportJournal.stage / EvidenceIndex.persistIssuedHierarchyArtifacts / EvidenceIndex.persistIssuedChildProof / EvidenceIndex.storeParentEvidenceInbox / CandidateStore.persistPreparedChildProofs — recovery-broker retention write, outside any database transaction.
    func mergeRecoveryRetention(
        scope: String,
        roots: [String]
    ) async throws {
        guard !roots.isEmpty else { return }
        try await recoveryVolumeBroker.mergeRetainedRoots(
            scope: scope,
            roots: roots
        )
    }

    /// Owner: CandidateStore.persistPreparedChildProofs / CandidateStore.removePreparedChildProof — recovery-broker retention write, outside any database transaction.
    func reconcilePreparedRecoveryRetention() async throws {
        try await recoveryVolumeBroker.advanceRetainedRoots(
            scope: preparedRecoveryRetentionScope,
            roots: preparedRecoveryVolumeRoots()
        )
    }

    /// Owner: ImportJournal.stage / EvidenceIndex.persistIssuedHierarchyArtifacts — recovery-broker volume write, outside any database transaction.
    func storeRecoveryEvidence(
        _ evidence: [PreparedImportCarrierEvidence]
    ) async throws -> [String] {
        for item in evidence {
            try await item.proofAttachment.store(storer: recoveryVolumeBroker)
        }
        return evidence.map(\.proofAttachment.rawCID)
    }

    func recoveryVolume(
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

    func recoveryVolumeRoots() async throws -> [String] {
        Array(Set(
            try issuedRecoveryVolumeRoots()
                + preparedRecoveryVolumeRoots()
        )).sorted()
    }

    func issuedRecoveryVolumeRoots() throws -> [String] {
        try canonicalRecoveryRoots(
            from: "\(IssuedChildProofRow.table)∪\(ChildGenesisVolumeRootRow.table)",
            sql: """
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

    func parentEvidenceInboxRoots() throws -> [String] {
        try canonicalRecoveryRoots(from: ParentEvidenceInboxRow.table, sql: """
            SELECT DISTINCT attachment_cid AS cid
            FROM parent_evidence_inbox
            ORDER BY cid
        """)
    }

    func preparedRecoveryVolumeRoots() throws -> [String] {
        try canonicalRecoveryRoots(
            from: "\(PreparedChildProofRow.table)∪\(ChildGenesisVolumeRootRow.table)",
            sql: """
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
        try database.rows(ContextualCandidateRootRow.self, """
            SELECT root_cid
            FROM contextual_candidate_roots
            ORDER BY candidate_cid, root_cid
            """).map { try $0.rootCID }
    }

    /// `sql` projects one canonical-CID column named `cid`; `table` labels
    /// the tables it unions for the error.
    private func canonicalRecoveryRoots(
        from table: String,
        sql: String
    ) throws -> [String] {
        try database.rows(from: table, sql).map { try $0.cid("cid") }
    }

    /// Owner: EvidenceIndex.persistIssuedChildProof / CandidateStore.persistPreparedChildProofs — volume write to the caller's storer, outside any database transaction.
    func retainChildGenesisVolumes(
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

    /// Owner: ImportJournal.stage / EvidenceIndex.persistIssuedHierarchyArtifacts / EvidenceIndex.storeParentEvidenceInbox / EvidenceIndex.consumeParentEvidence — recovery-broker retention write, outside any database transaction.
    func reconcileParentEvidenceInboxRetention() async {
        try? await recoveryVolumeBroker.advanceRetainedRoots(
            scope: parentEvidenceInboxRetentionScope,
            roots: parentEvidenceInboxRoots()
        )
    }

    /// Owner: CandidateStore.persistContextualCandidateRoots / CandidateStore.removeContextualCandidateIfAdmitted / CandidateStore.evictExcessHandoffCandidates — recovery-broker retention write, outside any database transaction.
    func releaseContextualCandidatePins(_ roots: [String]) async {
        try? await recoveryVolumeBroker.unpinBatch(
            items: roots.map {
                (root: $0, owner: contextualCandidateOwner, count: 1)
            }
        )
    }
}
