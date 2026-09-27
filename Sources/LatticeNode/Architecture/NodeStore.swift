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

/// Node-owned immutable facts and availability indexes for one absolute path.
actor NodeStore {
    let database: NodeSQLite
    let nexusGenesisCID: String
    let chainPath: [String]
    let recoveryVolumeBroker: any RetainedRootMergeBroker
    let blockRetentionScope: String
    let issuedRecoveryRetentionScope: String
    let preparedRecoveryRetentionScope: String
    let parentEvidenceInboxRetentionScope: String
    let parentEvidenceInboxCapacity: Int
    let handoffCandidateCapacity: Int
    let contextualCandidateOwner: String
    var preparedMutationInFlight = false
    var preparedMutationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        databasePath: URL,
        nexusGenesisCID: String,
        chainPath: [String],
        recoveryVolumeBroker: any RetainedRootMergeBroker,
        blockRetentionScope: String,
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
        guard !blockRetentionScope.isEmpty,
              !issuedRecoveryRetentionScope.isEmpty,
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
        // Indexes are ensured on BOTH branches: an existing store runs no
        // other DDL, so an index added after its creation would never exist.
        try Self.ensureIndexes(in: database)
        try database.configureDurability()

        self.database = database
        self.nexusGenesisCID = nexusGenesisCID
        self.chainPath = chainPath
        self.recoveryVolumeBroker = recoveryVolumeBroker
        self.blockRetentionScope = blockRetentionScope
        self.issuedRecoveryRetentionScope = issuedRecoveryRetentionScope
        self.preparedRecoveryRetentionScope = preparedRecoveryRetentionScope
        self.parentEvidenceInboxRetentionScope =
            parentEvidenceInboxRetentionScope
        self.parentEvidenceInboxCapacity = parentEvidenceInboxCapacity
        self.contextualCandidateOwner = contextualCandidateOwner
        self.handoffCandidateCapacity = handoffCandidateCapacity
    }

    func acquirePreparedMutation() async {
        guard preparedMutationInFlight else {
            preparedMutationInFlight = true
            return
        }
        await withCheckedContinuation { continuation in
            preparedMutationWaiters.append(continuation)
        }
    }

    func releasePreparedMutation() {
        guard !preparedMutationWaiters.isEmpty else {
            preparedMutationInFlight = false
            return
        }
        preparedMutationWaiters.removeFirst().resume()
    }

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
        var leafFlags: [String: Bool] = [:]
        for row in try database.query(
            "SELECT block_cid, parent_cid, admission_seq, leaf FROM accepted_blocks"
        ) {
            let block = try persistedAcceptedBlock(from: row)
            actualAcceptedBlocks[block.blockCID] = block
            guard let leaf = row["leaf"]?.intValue else {
                throw NodeStoreError.corrupt("malformed accepted-block leaf flag")
            }
            leafFlags[block.blockCID] = leaf == 1
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
        // The maintained leaf flag is a derived index over the parent links
        // verified above, so a disagreeing row is repaired from that truth,
        // never a wipe: only the disagreeing rows are rewritten.
        for (cid, leaf) in leafFlags.sorted(by: { $0.key < $1.key })
        where leaf != (childrenByParent[cid] == nil) {
            SyncTrace.log("boot audit: repairing leaf flag block=\(cid.prefix(12))")
            try database.execute(
                "UPDATE accepted_blocks SET leaf = ?1 WHERE block_cid = ?2",
                params: [.int(childrenByParent[cid] == nil ? 1 : 0), .text(cid)]
            )
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

        // Startup-bounded attachment audit: shape, edge linkage, and LOCAL
        // COMPLETENESS of every attachment Volume (the broker's SQL
        // completeness predicate) — but never materialization. The issued
        // index grows with every proof issued over the chain's whole life, so
        // fetching and decoding each attachment here made process startup
        // O(history x volume-decode) and wedged long-lived nodes for hours;
        // the full decode-and-bind validation still runs fail-closed at every
        // actual use (`recoveryVolume`).
        let attachments = try database.query(
            """
            SELECT p.scope, p.root_cid, p.attachment_cid, e.edge_cid
            FROM issued_child_proofs AS p
            LEFT JOIN issued_child_edges AS e ON e.edge_cid = p.edge_cid
            ORDER BY p.scope, p.edge_cid, p.root_cid
            """
        )
        for row in attachments {
            guard let rawScope = row["scope"]?.textValue,
                  IssuedChildProofScope(rawValue: rawScope) != nil,
                  let rootCID = row["root_cid"]?.textValue,
                  CIDIdentity.isCanonical(rootCID),
                  let attachmentCID = row["attachment_cid"]?.textValue,
                  CIDIdentity.isCanonical(attachmentCID),
                  row["edge_cid"]?.textValue != nil,
                  await recoveryVolumeBroker.hasVolume(root: attachmentCID)
            else {
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

    /// The candidates this chain built that the parent's evidence names as
    /// carried and still holds in the inbox: no admission has decided them.
    /// Read ungated: a view torn between the handoff mark and the inbox
    /// row costs at most one sibling offer or one extra deferral, and the
    /// next admission or push corrects either.
    func pendingHandoffChildCIDs() throws -> [String] {
        try database.query(
            "SELECT DISTINCT c.candidate_cid FROM contextual_candidates AS c INNER JOIN parent_evidence_inbox AS i ON i.child_cid = c.candidate_cid WHERE c.handoff = 1"
        ).compactMap { $0["candidate_cid"]?.textValue }
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

    func childGenesisVolumeRoots(
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

    func pendingRoutesIncludingPreparedProofs(
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

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw NodeStoreError.corrupt(String(describing: error))
        }
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
