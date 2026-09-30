import Foundation
import Ivy
import Lattice
import UInt256
import VolumeBroker
import cashew

extension NodeStore {
    /// Owner: ImportJournal.stage / EvidenceIndex.persistIssuedHierarchyArtifacts — recovery-broker retention write, outside any database transaction.
    func mergeRecoveryPruningProtection(
        scope: String,
        roots: [String]
    ) async throws {
        guard !roots.isEmpty else { return }
        try await recoveryVolumeBroker.mergeRetainedRoots(
            scope: scope,
            roots: roots
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
        try issuedRecoveryVolumeRoots()
    }

    func issuedRecoveryVolumeRoots() throws -> [String] {
        try canonicalRecoveryRoots(
            from: IssuedChildProofRow.table,
            sql: """
            SELECT DISTINCT attachment_cid AS cid FROM issued_child_proofs
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

    /// Owner: CandidateStore.persistContextualCandidateRoots / CandidateStore.removeContextualCandidateIfAdmitted — recovery-broker retention write, outside any database transaction.
    func releaseContextualCandidatePins(_ roots: [String]) async {
        try? await recoveryVolumeBroker.unpinBatch(
            items: roots.map {
                (root: $0, owner: contextualCandidateOwner, count: 1)
            }
        )
    }
}
