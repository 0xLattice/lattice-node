import Foundation
import Ivy
import Lattice
import UInt256
import VolumeBroker
import cashew

extension NodeStore {
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

    func reconcilePreparedRecoveryRetention() async throws {
        try await recoveryVolumeBroker.advanceRetainedRoots(
            scope: preparedRecoveryRetentionScope,
            roots: preparedRecoveryVolumeRoots()
        )
    }

    func storeRecoveryEvidence(
        _ evidence: [PreparedAdmissionCarrierEvidence]
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

    func parentEvidenceInboxRoots() throws -> [String] {
        try canonicalRecoveryRoots(sql: """
            SELECT DISTINCT attachment_cid AS cid
            FROM parent_evidence_inbox
            ORDER BY cid
        """)
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

    private func canonicalRecoveryRoots(sql: String) throws -> [String] {
        try database.query(sql).map { row in
            guard let cid = row["cid"]?.textValue,
                  CIDIdentity.isCanonical(cid) else {
                throw NodeStoreError.corrupt("malformed recovery attachment index")
            }
            return cid
        }
    }

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

    func reconcileParentEvidenceInboxRetention() async {
        try? await recoveryVolumeBroker.advanceRetainedRoots(
            scope: parentEvidenceInboxRetentionScope,
            roots: parentEvidenceInboxRoots()
        )
    }

    func releaseContextualCandidatePins(_ roots: [String]) async {
        try? await recoveryVolumeBroker.unpinBatch(
            items: roots.map {
                (root: $0, owner: contextualCandidateOwner, count: 1)
            }
        )
    }
}
