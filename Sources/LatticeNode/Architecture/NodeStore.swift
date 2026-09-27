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
