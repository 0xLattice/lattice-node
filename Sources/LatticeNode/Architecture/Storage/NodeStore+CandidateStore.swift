import Foundation
import Ivy
import Lattice
import UInt256
import VolumeBroker
import cashew

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

/// `child_genesis_volume_roots`: one bootstrap Volume root of a child
/// genesis; `child_cid` is whatever the proof named, so it stays text.
struct ChildGenesisVolumeRootRow: NodeStoreRecord {
    static let table = "child_genesis_volume_roots"
    private let row: Row

    init(_ row: Row) { self.row = row }

    var childCID: String { get throws { try row.text("child_cid") } }
    var rootCID: String { get throws { try row.cid("root_cid") } }
}

/// `prepared_child_proofs`: one bounded direct-hop proof prepared before
/// its carrier is admitted. `carrier_cid` and `child_cid` are the proof's
/// own root and hop, compared at use rather than validated here.
struct PreparedChildProofRow: NodeStoreRecord {
    static let table = "prepared_child_proofs"
    private let row: Row

    init(_ row: Row) { self.row = row }

    var carrierCID: String { get throws { try row.text("carrier_cid") } }
    var batchSequence: Int64 { get throws { try row.int("batch_seq") } }
    var directory: String { get throws { try row.text("directory") } }
    var childCID: String { get throws { try row.text("child_cid") } }
    var isChildGenesis: Bool { get throws { try row.bool("is_child_genesis") } }
    var attachmentCID: String { get throws { try row.cid("attachment_cid") } }
}

/// `pending_child_proof_routes`: one (carrier, directory) still owed a
/// child proof.
struct PendingChildProofRouteRow: NodeStoreRecord {
    static let table = "pending_child_proof_routes"
    private let row: Row

    init(_ row: Row) { self.row = row }

    var carrierCID: String { get throws { try row.nonEmptyText("carrier_cid") } }
    var batchSequence: Int64 { get throws { try row.int("batch_seq") } }
    var directory: String { get throws { try row.nonEmptyText("directory") } }
}

/// `contextual_candidates`: one locally built candidate and its
/// offer / issued / handoff state (the table's CHECKs keep them exclusive).
struct ContextualCandidateRow: NodeStoreRecord {
    static let table = "contextual_candidates"
    private let row: Row

    init(_ row: Row) { self.row = row }

    var candidateCID: String { get throws { try row.text("candidate_cid") } }
    var offerSequence: Int64? { get throws { try row.optionalInt("offer_seq") } }
    var issued: Bool { get throws { try row.bool("issued") } }
    var handoff: Bool { get throws { try row.bool("handoff") } }
    var handoffSequence: Int64? { get throws { try row.optionalInt("handoff_seq") } }
}

/// `contextual_candidate_roots`: one pinned Volume root of a candidate.
struct ContextualCandidateRootRow: NodeStoreRecord {
    static let table = "contextual_candidate_roots"
    private let row: Row

    init(_ row: Row) { self.row = row }

    var candidateCID: String { get throws { try row.text("candidate_cid") } }
    var rootCID: String { get throws { try row.cid("root_cid") } }
}

/// `contextual_candidate_children`: unused rows kept until the next schema
/// epoch; the audit parses `child_peer_key` as a `PeerKey` itself.
struct ContextualCandidateChildRow: NodeStoreRecord {
    static let table = "contextual_candidate_children"
    private let row: Row

    init(_ row: Row) { self.row = row }

    var childPeerKey: String { get throws { try row.text("child_peer_key") } }
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
            "SELECT issued, handoff FROM contextual_candidates WHERE candidate_cid = ?1",
            params: [.text(candidateCID)]
        )
        if let candidate {
            _ = try candidate.issued
            _ = try candidate.handoff
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
            try await evictExcessHandoffCandidates()
            return
        }
        try await recoveryVolumeBroker.pinBatch(
            roots: canonicalRoots,
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
                    "SELECT candidate_cid FROM contextual_candidates WHERE issued = 0 AND handoff = 0 ORDER BY offer_seq, candidate_cid"
                )
                for candidate in candidates.prefix(
                    max(0, candidates.count - capacity + 1)
                ) {
                    evictedRoots += try deleteContextualCandidateRows(
                        candidateCID: try candidate.candidateCID
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
            }
        } catch {
            await releaseContextualCandidatePins(canonicalRoots)
            throw error
        }
        await releaseContextualCandidatePins(evictedRoots)
        // Handoffs are exempt from the offer budget above, so their own
        // budget runs on the same cadence: every offer this chain stores.
        try await evictExcessHandoffCandidates()
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
                "SELECT issued, handoff FROM contextual_candidates WHERE candidate_cid = ?1",
                params: [.text(candidateCID)]
            ) else {
                throw NodeStoreError.corrupt(
                    "contextual candidate state is missing"
                )
            }
            guard try !row.issued, try !row.handoff else { return }
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

    /// Removes one candidate's row, descendants, and root references in the
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
            "DELETE FROM contextual_candidate_children WHERE candidate_cid = ?1",
            params: [.text(candidateCID)]
        )
        try database.execute(
            "DELETE FROM contextual_candidates WHERE candidate_cid = ?1",
            params: [.text(candidateCID)]
        )
        return roots
    }

    /// Owner: EvidenceIndex.storeParentEvidenceInbox — caller holds the transaction.
    func markContextualCandidateHandoff(
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
            "SELECT issued, handoff FROM contextual_candidates WHERE candidate_cid = ?1",
            params: [.text(candidateCID)]
        ) else { return false }
        let candidateRoots = try database.rows(
                ContextualCandidateRootRow.self,
                "SELECT root_cid FROM contextual_candidate_roots WHERE candidate_cid = ?1 ORDER BY root_cid",
                params: [.text(candidateCID)]
            ).map { try $0.rootCID }
        guard !candidateRoots.isEmpty else { return false }
        guard let rootsPayload = try database.row(
                AdmissionBatchRow.self,
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
                    "DELETE FROM contextual_candidate_children WHERE candidate_cid = ?1",
                    params: [.text(candidateCID)]
                )
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

    /// The candidates this chain built that the parent's evidence names as
    /// carried and still holds in the inbox: no admission has decided them.
    /// Read ungated: a view torn between the handoff mark and the inbox
    /// row costs at most one sibling offer or one extra deferral, and the
    /// next admission or push corrects either.
    func pendingHandoffChildCIDs() throws -> [String] {
        try database.rows(
            ContextualCandidateRow.self,
            "SELECT DISTINCT c.candidate_cid FROM contextual_candidates AS c INNER JOIN parent_evidence_inbox AS i ON i.child_cid = c.candidate_cid WHERE c.handoff = 1"
        ).map { try $0.candidateCID }
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
        let stranded = try database.rows(
            ContextualCandidateRow.self,
            "SELECT candidate_cid FROM contextual_candidates WHERE handoff = 1 ORDER BY handoff_seq"
        ).map { try $0.candidateCID }
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
        await releaseContextualCandidatePins(releasedRoots)
    }

    /// Owner: EvidenceIndex.persistIssuedChildProof / CandidateStore.persistPreparedChildProofs — caller holds the transaction.
    func persistChildGenesisVolumeRoots(
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

    func childGenesisVolumeRoots(
        childCID: String
    ) throws -> [String] {
        try database.rows(
            ChildGenesisVolumeRootRow.self,
            "SELECT root_cid FROM child_genesis_volume_roots WHERE child_cid = ?1 ORDER BY root_cid",
            params: [.text(childCID)]
        ).map { try $0.rootCID }
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
                let existing = try database.rows(
                    PreparedChildProofRow.self,
                    "SELECT batch_seq, directory, child_cid, is_child_genesis, attachment_cid FROM prepared_child_proofs WHERE carrier_cid = ?1 ORDER BY directory",
                    params: [.text(carrierCID)]
                )
                let existingByDirectory = Dictionary(
                    uniqueKeysWithValues: try existing.map { row in
                        (try row.directory, row)
                    }
                )
                for expected in canonical {
                    if let row = existingByDirectory[expected.directory] {
                        guard try row.childCID == expected.childCID,
                              try row.isChildGenesis == expected.isChildGenesis,
                              try row.attachmentCID == expected.attachment.rawCID else {
                            throw NodeStoreError.conflictingIssuedChildProof
                        }
                    }
                }

                let batchSequence: Int64
                if let first = existing.first {
                    let sequence = try first.batchSequence
                    guard try existing.allSatisfy({
                        try $0.batchSequence == sequence
                    }) else {
                        throw NodeStoreError.corrupt(
                            "malformed prepared child-proof sequence"
                        )
                    }
                    batchSequence = sequence
                } else {
                    let sequence = try database.row(
                        from: PreparedChildProofRow.table,
                        "SELECT COALESCE(MAX(batch_seq), 0) AS max_seq FROM prepared_child_proofs"
                    )?.int("max_seq") ?? 0
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
                let pinnedCount = try database.row(
                    from: PreparedChildProofRow.table,
                    "SELECT COUNT(DISTINCT p.carrier_cid) AS carrier_count FROM prepared_child_proofs AS p INNER JOIN contextual_candidate_roots AS c ON c.candidate_cid = p.carrier_cid"
                )?.int("carrier_count") ?? 0
                let speculativeCapacity = max(0, sqlCapacity - pinnedCount)
                let stale = try database.rows(
                    PreparedChildProofRow.self,
                    "SELECT p.carrier_cid FROM prepared_child_proofs AS p WHERE NOT EXISTS (SELECT 1 FROM contextual_candidate_roots AS c WHERE c.candidate_cid = p.carrier_cid) AND NOT EXISTS (SELECT 1 FROM pending_child_proof_routes AS route WHERE route.carrier_cid = p.carrier_cid) AND NOT EXISTS (SELECT 1 FROM accepted_blocks AS block WHERE block.block_cid = p.carrier_cid) GROUP BY p.carrier_cid ORDER BY MIN(p.batch_seq) DESC, p.carrier_cid DESC LIMIT -1 OFFSET ?1",
                    params: [.int(speculativeCapacity)]
                )
                for row in stale {
                    try database.execute(
                        "DELETE FROM prepared_child_proofs WHERE carrier_cid = ?1",
                        params: [.text(try row.carrierCID)]
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

    /// Owner: ImportJournal.stage / EvidenceIndex.persistIssuedHierarchyArtifacts / CandidateStore.persistPendingChildProofRoutes — caller holds the transaction.
    func persistPendingChildProofRouteRows(
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
            let existing = try database.row(
                PendingChildProofRouteRow.self,
                "SELECT batch_seq FROM pending_child_proof_routes WHERE carrier_cid = ?1 LIMIT 1",
                params: [.text(carrierCID)]
            )?.batchSequence
            let batchSequence: Int64
            if let existing {
                batchSequence = existing
            } else {
                let maximum = try database.row(
                    from: PendingChildProofRouteRow.table,
                    "SELECT COALESCE(MAX(batch_seq), 0) AS max_seq FROM pending_child_proof_routes"
                )?.int("max_seq") ?? 0
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
        let stale = try database.rows(
            PendingChildProofRouteRow.self,
            "SELECT route.carrier_cid FROM pending_child_proof_routes AS route WHERE NOT EXISTS (SELECT 1 FROM accepted_blocks AS block WHERE block.block_cid = route.carrier_cid) AND NOT EXISTS (SELECT 1 FROM issued_parent_facts AS fact WHERE fact.kind = 'carrier' AND fact.key_a = route.carrier_cid) GROUP BY route.carrier_cid ORDER BY MIN(route.batch_seq) DESC, route.carrier_cid DESC LIMIT -1 OFFSET ?1",
            params: [.int(sqlCapacity)]
        )
        for row in stale {
            try database.execute(
                "DELETE FROM pending_child_proof_routes WHERE carrier_cid = ?1",
                params: [.text(try row.carrierCID)]
            )
        }
    }

    /// Owner: ImportJournal.stage / EvidenceIndex.persistIssuedHierarchyArtifacts — caller holds the transaction.
    func pendingRoutesIncludingPreparedProofs(
        _ routes: [PendingChildProofRoute],
        carrierCIDs: Set<String>
    ) throws -> [PendingChildProofRoute] {
        var result = Set(routes)
        for carrierCID in carrierCIDs {
            for row in try database.rows(
                PreparedChildProofRow.self,
                "SELECT directory FROM prepared_child_proofs WHERE carrier_cid = ?1",
                params: [.text(carrierCID)]
            ) {
                result.insert(PendingChildProofRoute(
                    carrierCID: carrierCID,
                    directory: try row.directory
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
        try database.rows(
            PendingChildProofRouteRow.self,
            "SELECT carrier_cid, directory FROM pending_child_proof_routes ORDER BY batch_seq, carrier_cid, directory"
        ).map { row in
            PendingChildProofRoute(
                carrierCID: try row.carrierCID,
                directory: try row.directory
            )
        }
    }

    func preparedChildProofs(carrierCID: String) async throws -> [PreparedChildProof] {
        let rows = try database.rows(
            PreparedChildProofRow.self,
            "SELECT directory, child_cid, is_child_genesis, attachment_cid FROM prepared_child_proofs WHERE carrier_cid = ?1 ORDER BY directory",
            params: [.text(carrierCID)]
        )
        var proofs: [PreparedChildProof] = []
        proofs.reserveCapacity(rows.count)
        for row in rows {
            let directory = try row.directory
            let childCID = try row.childCID
            let isChildGenesis = try row.isChildGenesis
            let attachmentCID = try row.attachmentCID
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
                isChildGenesis: isChildGenesis,
                bootstrapRoots: try childGenesisVolumeRoots(
                    childCID: childCID
                ),
                proof: proof
            ))
        }
        return proofs
    }

    func preparedChildProofCarrierCIDs() async throws -> [String] {
        try database.rows(
            PreparedChildProofRow.self,
            "SELECT carrier_cid FROM prepared_child_proofs GROUP BY carrier_cid ORDER BY MIN(batch_seq), carrier_cid"
        ).map { try $0.carrierCID }
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

    func auditPreparedChildProofs() async throws {
        for carrierCID in try await preparedChildProofCarrierCIDs() {
            _ = try await preparedChildProofs(carrierCID: carrierCID)
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
        for row in try database.rows(
            ContextualCandidateChildRow.self,
            "SELECT DISTINCT child_peer_key FROM contextual_candidate_children"
        ) {
            let rawPeerKey = try row.childPeerKey
            guard (try? PeerKey(rawPeerKey)) != nil else {
                throw NodeStoreError.corrupt(
                    "contextual candidate child peer key is malformed"
                )
            }
        }
    }
}
