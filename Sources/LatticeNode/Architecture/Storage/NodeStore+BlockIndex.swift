import Foundation
import Ivy
import Lattice
import UInt256
import VolumeBroker
import cashew

struct AcceptedLeafPage: Sendable, Equatable {
    let snapshotSequence: Int64
    let blockCIDs: [String]
}

struct AcceptedBlockRecord: Hashable {
    let blockCID: String
    let parentCID: String?
}

struct PersistedAcceptedBlock: Hashable {
    let blockCID: String
    let parentCID: String?
    let admissionSequence: Int64
}

extension NodeStore {
    /// The cursor-less (frontier) leaf page: ?1 = snapshot admission sequence,
    /// ?2 = limit. Served by the partial index `accepted_blocks_frontier`.
    /// Leaf-ness is the maintained `leaf` flag; under a snapshot a block whose
    /// only children were admitted after the snapshot reads as a non-leaf,
    /// which only ever hides a leaf from an older page walk.
    static let frontierLeafPageSQL =
        "SELECT block_cid FROM accepted_blocks AS block WHERE block.leaf = 1 AND block.admission_seq <= ?1 ORDER BY block.admission_seq DESC, block.block_cid DESC LIMIT ?2"

    /// Pagination over the accepted forest's leaves. The cursor-less page is
    /// the MOST RECENTLY ADMITTED leaves (newest first): the leaf set only
    /// ever grows (accepted rows are never deleted) and only recent forks can
    /// still contend in fork choice, so a bounded frontier page must be the
    /// recent end, never a lexicographic sample. A cursored page keeps the
    /// legacy contract — leaves lexicographically after `afterCID`, in CID
    /// order — which is what the wire's cursor rule and older peers' descent
    /// expect; the frontier pull never cursors. The first call captures the
    /// current admission sequence; later calls reuse it so newly admitted
    /// descendants cannot reshuffle an in-progress page walk.
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
            // Legacy cursored descent (older peers only; dead after the
            // flag-day roll — delete with the cursored request handling).
            rows = try database.query(
                "SELECT block_cid FROM accepted_blocks AS block WHERE block.admission_seq <= ?1 AND block.block_cid > ?2 AND NOT EXISTS (SELECT 1 FROM accepted_blocks AS child WHERE child.parent_cid = block.block_cid AND child.admission_seq <= ?1) ORDER BY block.block_cid LIMIT ?3",
                params: [.int(snapshot), .text(afterCID), .int(sqlLimit)]
            )
        } else {
            rows = try database.query(
                Self.frontierLeafPageSQL,
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

    func hasAcceptedBlock(_ blockCID: String) throws -> Bool {
        guard CIDIdentity.isCanonical(blockCID) else {
            throw NodeStoreError.corrupt("invalid accepted block lookup")
        }
        return try !database.query(
            "SELECT 1 FROM accepted_blocks WHERE block_cid = ?1 LIMIT 1",
            params: [.text(blockCID)]
        ).isEmpty
    }

    /// The durable parent edge of an accepted block, or nil when the block is
    /// unknown or a root. Serves the predecessor descent: locating the deepest
    /// missing ancestor of an accepted-but-disconnected segment with point
    /// lookups instead of block materialization.
    func acceptedBlockParent(_ blockCID: String) throws -> String? {
        guard CIDIdentity.isCanonical(blockCID) else {
            throw NodeStoreError.corrupt("invalid accepted block lookup")
        }
        return try database.query(
            "SELECT parent_cid FROM accepted_blocks WHERE block_cid = ?1 LIMIT 1",
            params: [.text(blockCID)]
        ).first?["parent_cid"]?.textValue
    }

    /// The most recently admitted accepted-block CIDs, newest first, capped at
    /// `limit`. Bounds the late-child evidence backfill to a recent window;
    /// carriers older than the window rely on the verified any-peer proof
    /// fallback rather than parent self-issuance.
    func recentAcceptedBlockCIDs(limit: Int) throws -> [String] {
        guard limit > 0 else { return [] }
        let rows = try database.query(
            "SELECT block_cid FROM accepted_blocks ORDER BY admission_seq DESC LIMIT ?1",
            params: [.int(Int64(limit))]
        )
        return try rows.map { row in
            guard let cid = row["block_cid"]?.textValue,
                  CIDIdentity.isCanonical(cid) else {
                throw NodeStoreError.corrupt("malformed recent accepted block")
            }
            return cid
        }
    }

    func hasConnectedAcceptedBlock(_ blockCID: String) throws -> Bool {
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

    static func acceptedBlocks(
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

    func persistedAcceptedBlock(
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

    /// Owner: ImportJournal.stage — caller holds the transaction.
    func validateAcceptedBlockRows(
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

    /// Owner: ImportJournal.stage — caller holds the transaction.
    func persistAcceptedBlockRows(
        _ blocks: [AcceptedBlockRecord],
        admissionSequence: Int64,
        validated: Bool
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
            // Leaf-ness is incremental: a new row is a leaf unless a child
            // row already exists (accepted rows arrive out of order for
            // disconnected segments), and inserting a child retires its
            // parent's leaf flag.
            try database.execute(
                "INSERT INTO accepted_blocks (block_cid, parent_cid, admission_seq, validated, leaf) VALUES (?1, ?2, ?3, ?4, CASE WHEN EXISTS (SELECT 1 FROM accepted_blocks WHERE parent_cid = ?1) THEN 0 ELSE 1 END)",
                params: [
                    .text(block.blockCID),
                    block.parentCID.map(NodeSQLiteValue.text) ?? .null,
                    .int(admissionSequence),
                    .int(validated ? 1 : 0),
                ]
            )
            if let parentCID = block.parentCID {
                try database.execute(
                    "UPDATE accepted_blocks SET leaf = 0 WHERE block_cid = ?1 AND leaf = 1",
                    params: [.text(parentCID)]
                )
            }
        }
    }

    /// Whether `blockCID` was admitted at the durable *validated* tier (its
    /// state transition executed and post-state materialized), as opposed to
    /// merely *weighed*. `false` for an unknown block or one recorded weighed.
    /// The tier is a node-side recovery fact, not derivable from the consensus
    /// batch, so it is read straight from the durable accepted-block index.
    ///
    /// Tier values: `0` weighed (boundary only, in the batch scope), `1` eager
    /// (body + state inside `admission_batches.volume_roots`), `2` walk-
    /// validated (body + state under the block's owner pin). A downgrade that
    /// only knows `1` reads `2` as "not validated" — the safe direction.
    func blockValidated(_ blockCID: String) throws -> Bool {
        (try database.query(
            "SELECT validated FROM accepted_blocks WHERE block_cid = ?1 LIMIT 1",
            params: [.text(blockCID)]
        ).first?["validated"]?.intValue ?? 0) >= 1
    }

    /// Flip an already-weighed accepted block's durable marker to the walk-
    /// validated tier. Marker ONLY: the caller pins the materialized body and
    /// post-state roots under the block's owner FIRST, so a crash between the
    /// two leaves an orphan pin (reclaimed at boot), never a marker without
    /// its state.
    ///
    /// The weighed block fact (empty `stateDiff`) is immutable and keyed by
    /// blockHash ONLY, so re-staging the validated fact (its real `stateDiff`)
    /// would collide (`conflictingAdmissionFact`). Deferred execution therefore
    /// never rewrites `admission_facts` on validation: the weighed fact REMAINS
    /// the state-blind consensus-replay record, and the materialized state is a
    /// node-side availability artifact keyed by this marker plus the owner pin.
    /// Idempotent, so a re-validation (reorg re-projection, crash-retry) is a
    /// no-op.
    func promoteValidated(blockCID: String) throws {
        try database.transaction {
            _ = try database.execute(
                "UPDATE accepted_blocks SET validated = 2 WHERE block_cid = ?1",
                params: [.text(blockCID)]
            )
        }
    }

    /// Every block marked walk-validated (tier `2`): the set whose body and
    /// post-state must be held by a per-block owner pin.
    func walkValidatedBlockCIDs() throws -> Set<String> {
        Set(try database.query(
            "SELECT block_cid FROM accepted_blocks WHERE validated = 2"
        ).compactMap { $0["block_cid"]?.textValue })
    }

    /// Every block this store has executed, at either tier (`1` eager, `2`
    /// walk-validated). Used once per boot to carry pre-existing history across
    /// the introduction of durable validation facts: rows written before that
    /// fact existed carry no fact, and without them a chain would come back
    /// having forgotten every execution and would attest nothing.
    ///
    /// `>= 1` and not `== 1` so the walk-validated tier (`2`) counts too. The
    /// column's DEFAULT of `1` is not what makes legacy rows qualify — every
    /// row is inserted with an explicit `validated ? 1 : 0`, and the schema
    /// epoch wipes any store old enough to predate the column, so the default
    /// never fires. What makes them qualify is that they were written `1` or
    /// `2` by an image that really did execute them.
    func executedBlockCIDs() throws -> Set<String> {
        Set(try database.query(
            "SELECT block_cid FROM accepted_blocks WHERE validated >= 1"
        ).compactMap { $0["block_cid"]?.textValue })
    }

    /// Return a walk-validated block to the weighed tier (its owner pin is
    /// gone, so its state may be evicted); the walk re-validates it on
    /// candidacy.
    ///
    /// Retention bookkeeping ONLY. It does not retract the durable validation
    /// fact, and must not: execution is a judgment about immutable bytes, so
    /// evicting a cached post-state does not unmake it. Being unable to SERVE a
    /// state is availability, never a verdict (spec §9.9), whereas retracting
    /// the fact would make a restarted node disagree with a live one about what
    /// its own chain produced.
    func demoteValidated(blockCID: String) throws {
        try database.transaction {
            _ = try database.execute(
                "UPDATE accepted_blocks SET validated = 0 WHERE block_cid = ?1",
                params: [.text(blockCID)]
            )
        }
    }
}
