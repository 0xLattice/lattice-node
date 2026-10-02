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

private struct PersistedAcceptedBlock: Hashable {
    let blockCID: String
    let parentCID: String?
    let admissionSequence: Int64

    init(blockCID: String, parentCID: String?, admissionSequence: Int64) {
        self.blockCID = blockCID
        self.parentCID = parentCID
        self.admissionSequence = admissionSequence
    }

    init(_ row: AcceptedBlockRow) throws {
        self.init(
            blockCID: try row.blockCID,
            parentCID: try row.parentCID,
            admissionSequence: try row.admissionSequence
        )
    }
}

/// `accepted_blocks`: one accepted block's index row. `block_cid` is any
/// non-empty text (tests stage blocks whose hashes are plain labels), so
/// only the readers that need a canonical CID ask for `canonicalBlockCID`.
/// `parent_cid` is NULL for a root and otherwise non-empty text; an empty
/// string is malformed.
struct AcceptedBlockRow: NodeStoreRecord {
    static let table = "accepted_blocks"
    private let row: Row

    init(_ row: Row) { self.row = row }

    var blockCID: String { get throws { try row.nonEmptyText("block_cid") } }
    var canonicalBlockCID: String { get throws { try row.cid("block_cid") } }
    var parentCID: String? {
        get throws {
            guard let parent = try row.optionalText("parent_cid") else { return nil }
            guard !parent.isEmpty else {
                throw NodeStoreError.malformedRow(table: Self.table, column: "parent_cid")
            }
            return parent
        }
    }
    var admissionSequence: Int64 { get throws { try row.positiveInt("admission_seq") } }
    /// The execution tier; an integer outside `BlockStatus` is malformed.
    var status: BlockStatus {
        get throws {
            guard let status = BlockStatus(rawValue: try row.int("validated")) else {
                throw NodeStoreError.malformedRow(table: Self.table, column: "validated")
            }
            return status
        }
    }
    /// A derived index repaired from the parent links at boot, so any stored
    /// integer is read (only 1 means leaf) rather than refused.
    var leaf: Bool { get throws { try row.int("leaf") == 1 } }
}

extension NodeStore {
    /// The cursor-less (frontier) leaf page: ?1 = snapshot admission sequence,
    /// ?2 = limit. Served by the partial index `accepted_blocks_frontier`.
    /// Leaf-ness is the maintained `leaf` flag; under a snapshot a block whose
    /// only children were admitted after the snapshot reads as a non-leaf,
    /// which only ever hides a leaf from an older page walk.
    static let frontierLeafPageSQL =
        "SELECT block_cid FROM accepted_blocks AS block WHERE block.leaf = 1 AND block.admission_seq <= ?1 ORDER BY block.admission_seq DESC, block.block_cid DESC LIMIT ?2"

    func hasAcceptedBlock(_ blockCID: String) throws -> Bool {
        guard CIDIdentity.isCanonical(blockCID) else {
            throw NodeStoreError.corrupt("invalid accepted block lookup")
        }
        return try !database.query(
            "SELECT 1 FROM accepted_blocks WHERE block_cid = ?1 LIMIT 1",
            params: [.text(blockCID)]
        ).isEmpty
    }

    static func acceptedBlocks(
        in batch: BlockImportBatch
    ) throws -> [AcceptedBlockRecord] {
        var blocks: [String: AcceptedBlockRecord] = [:]
        for fact in batch.facts {
            guard case .block(let block) = fact else { continue }
            let record = AcceptedBlockRecord(
                blockCID: block.blockHash,
                parentCID: block.parentBlockHash
            )
            if let existing = blocks[record.blockCID], existing != record {
                throw NodeStoreError.conflictingImportFact
            }
            blocks[record.blockCID] = record
        }
        return blocks.values.sorted { $0.blockCID < $1.blockCID }
    }

    /// Owner: ImportJournal.stage — caller holds the transaction.
    func persistAcceptedBlockRows(
        _ blocks: [AcceptedBlockRecord],
        admissionSequence: Int64,
        status: BlockStatus
    ) throws {
        for block in blocks {
            let row = try database.row(
                AcceptedBlockRow.self,
                "SELECT block_cid, parent_cid, admission_seq FROM accepted_blocks WHERE block_cid = ?1",
                params: [.text(block.blockCID)]
            )
            if let row {
                let persisted = try PersistedAcceptedBlock(row)
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
                    status.sqlValue,
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

    func auditAcceptedBlocks(staged: [StagedImport]) throws {
        var expectedAcceptedBlocks: [String: PersistedAcceptedBlock] = [:]
        for admission in staged {
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

        var actualAcceptedBlocks: [String: PersistedAcceptedBlock] = [:]
        var leafFlags: [String: Bool] = [:]
        for row in try database.rows(
            AcceptedBlockRow.self,
            "SELECT block_cid, parent_cid, admission_seq, validated, leaf FROM accepted_blocks"
        ) {
            let block = try PersistedAcceptedBlock(row)
            _ = try row.status
            actualAcceptedBlocks[block.blockCID] = block
            leafFlags[block.blockCID] = try row.leaf
        }
        guard actualAcceptedBlocks == expectedAcceptedBlocks else {
            throw NodeStoreError.corrupt(
                "accepted-block index does not match immutable batches"
            )
        }
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
            syncTrace("boot audit: repairing leaf flag block=\(cid.prefix(12))")
            try database.execute(
                "UPDATE accepted_blocks SET leaf = ?1 WHERE block_cid = ?2",
                params: [.int(childrenByParent[cid] == nil ? 1 : 0), .text(cid)]
            )
        }
    }
}
