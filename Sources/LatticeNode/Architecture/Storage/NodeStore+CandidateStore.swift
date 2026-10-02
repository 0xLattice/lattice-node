import Foundation
import Ivy
import Lattice
import UInt256
import VolumeBroker
import cashew

/// `contextual_candidates`: one locally built candidate and its
/// offer / issued state.
struct ContextualCandidateRow: NodeStoreRecord {
    static let table = "contextual_candidates"
    private let row: Row

    init(_ row: Row) { self.row = row }

    var candidateCID: String { get throws { try row.text("candidate_cid") } }
    var offerSequence: Int64? { get throws { try row.optionalInt("offer_seq") } }
    var issued: Bool { get throws { try row.bool("issued") } }
}

/// `contextual_candidate_roots`: one pinned Volume root of a candidate.
struct ContextualCandidateRootRow: NodeStoreRecord {
    static let table = "contextual_candidate_roots"
    private let row: Row

    init(_ row: Row) { self.row = row }

    var candidateCID: String { get throws { try row.text("candidate_cid") } }
    var rootCID: String { get throws { try row.cid("root_cid") } }
}

extension NodeStore {
    func persistContextualCandidateRoots(
        candidateCID: String,
        roots: [String],
        capacity: Int
    ) async throws {
        let canonicalRoots = Array(Set(roots)).sorted()
        guard CIDIdentity.isCanonical(candidateCID),
              canonicalRoots.contains(candidateCID),
              canonicalRoots.allSatisfy(CIDIdentity.isCanonical),
              capacity > 0 else {
            throw NodeStoreError.invalidConfiguration(
                "contextual candidate retention is malformed"
            )
        }
        await acquirePreparedMutation()
        defer { releasePreparedMutation() }
        let candidate = try database.row(
            ContextualCandidateRow.self,
            "SELECT issued FROM contextual_candidates WHERE candidate_cid = ?1",
            params: [.text(candidateCID)]
        )
        if let candidate {
            _ = try candidate.issued
            let existing = try database.rows(
                ContextualCandidateRootRow.self,
                "SELECT root_cid FROM contextual_candidate_roots WHERE candidate_cid = ?1 ORDER BY root_cid",
                params: [.text(candidateCID)]
            ).map { try $0.rootCID }
            guard existing.isEmpty || existing == canonicalRoots else {
                throw NodeStoreError.corrupt(
                    "contextual candidate roots changed"
                )
            }
            try touchContextualCandidateOfferLocked(candidateCID)
            return
        }
        try await recoveryVolumeBroker.retain(canonicalRoots,
            owner: contextualCandidateOwner
        )
        var evictedRoots: [String] = []
        do {
            try database.transaction {
                let latestSequence = try database.row(
                    ContextualCandidateRow.self,
                    "SELECT MAX(offer_seq) AS offer_seq FROM contextual_candidates"
                )?.offerSequence ?? 0
                let (sequence, overflow) = latestSequence.addingReportingOverflow(1)
                guard !overflow else {
                    throw NodeStoreError.corrupt(
                        "contextual candidate retention sequence overflow"
                    )
                }
                let candidates = try database.rows(
                    ContextualCandidateRow.self,
                    "SELECT candidate_cid FROM contextual_candidates WHERE issued = 0 ORDER BY offer_seq, candidate_cid"
                )
                for candidate in candidates.prefix(
                    max(0, candidates.count - capacity + 1)
                ) {
                    evictedRoots += try deleteContextualCandidateRows(
                        candidateCID: try candidate.candidateCID
                    )
                }
                try database.execute(
                    "INSERT INTO contextual_candidates (candidate_cid, offer_seq, issued) VALUES (?1, ?2, 0)",
                    params: [.text(candidateCID), .int(sequence)]
                )
                for root in canonicalRoots {
                    try database.execute(
                        "INSERT INTO contextual_candidate_roots (candidate_cid, root_cid) VALUES (?1, ?2)",
                        params: [.text(candidateCID), .text(root)]
                    )
                }
            }
        } catch {
            await releaseContextualCandidatePins(canonicalRoots)
            throw error
        }
        await releaseContextualCandidatePins(evictedRoots)
    }

    /// Refreshes availability without walking or rewriting an immutable
    /// candidate Volume that this node already owns.
    func touchContextualCandidate(
        candidateCID: String
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
        try touchContextualCandidateOfferLocked(candidateCID)
        return true
    }

    private func touchContextualCandidateOfferLocked(
        _ candidateCID: String
    ) throws {
        try database.transaction {
            guard let row = try database.row(
                ContextualCandidateRow.self,
                "SELECT issued FROM contextual_candidates WHERE candidate_cid = ?1",
                params: [.text(candidateCID)]
            ) else {
                throw NodeStoreError.corrupt(
                    "contextual candidate state is missing"
                )
            }
            guard try !row.issued else { return }
            let latestSequence = try database.row(
                ContextualCandidateRow.self,
                "SELECT MAX(offer_seq) AS offer_seq FROM contextual_candidates"
            )?.offerSequence ?? 0
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

    /// Removes one candidate's row and root references in the
    /// caller's transaction and returns the roots to unpin afterwards. The
    /// row, its index entries, and its pins always leave together: an index
    /// that promises evicted content is a liveness wedge, not a saving.
    private func deleteContextualCandidateRows(
        candidateCID: String
    ) throws -> [String] {
        let roots = try database.rows(
            ContextualCandidateRootRow.self,
            "SELECT root_cid FROM contextual_candidate_roots WHERE candidate_cid = ?1",
            params: [.text(candidateCID)]
        ).map { try $0.rootCID }
        try database.execute(
            "DELETE FROM contextual_candidate_roots WHERE candidate_cid = ?1",
            params: [.text(candidateCID)]
        )
        try database.execute(
            "DELETE FROM contextual_candidates WHERE candidate_cid = ?1",
            params: [.text(candidateCID)]
        )
        return roots
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
        guard let candidate = try database.row(
            ContextualCandidateRow.self,
            "SELECT issued FROM contextual_candidates WHERE candidate_cid = ?1",
            params: [.text(candidateCID)]
        ) else { return false }
        let candidateRoots = try database.rows(
                ContextualCandidateRootRow.self,
                "SELECT root_cid FROM contextual_candidate_roots WHERE candidate_cid = ?1 ORDER BY root_cid",
                params: [.text(candidateCID)]
            ).map { try $0.rootCID }
        guard !candidateRoots.isEmpty else { return false }
        guard let rootsPayload = try database.row(
                ImportBatchRow.self,
                "SELECT batch.volume_roots FROM accepted_blocks AS block INNER JOIN admission_batches AS batch ON batch.seq = block.admission_seq WHERE block.block_cid = ?1",
                params: [.text(candidateCID)]
            )?.volumeRoots else { return false }
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
            if try !candidate.issued {
                try database.execute(
                    "DELETE FROM contextual_candidates WHERE candidate_cid = ?1",
                    params: [.text(candidateCID)]
                )
            }
        }
        await releaseContextualCandidatePins(candidateRoots)
        return true
    }

    func pruneAdmittedContextualCandidates() async throws {
        let candidates = try database.rows(
            ContextualCandidateRow.self,
            "SELECT candidate_cid FROM contextual_candidates ORDER BY candidate_cid"
        ).map { try $0.candidateCID }
        for candidate in candidates {
            _ = try await removeContextualCandidateIfAdmitted(
                candidateCID: candidate
            )
        }
    }

    func auditContextualCandidates() throws {
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
            LIMIT 1
            """)
        guard malformedContextualCandidates.isEmpty else {
            throw NodeStoreError.corrupt(
                "contextual candidate index is inconsistent"
            )
        }
    }
}
