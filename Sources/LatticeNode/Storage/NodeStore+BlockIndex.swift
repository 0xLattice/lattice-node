import Foundation
import Ivy
import Lattice
import UInt256
import VolumeBroker
import cashew

struct AcceptedBlockRecord: Hashable {
    let blockCID: String
    let parentCID: String?
}

private struct PersistedAcceptedBlock: Hashable {
    let chainPath: String
    let blockCID: String
    let parentCID: String?
    let admissionSequence: Int64

    init(chainPath: String, blockCID: String, parentCID: String?, admissionSequence: Int64) {
        self.chainPath = chainPath
        self.blockCID = blockCID
        self.parentCID = parentCID
        self.admissionSequence = admissionSequence
    }

    init(_ row: AcceptedBlockRow) throws {
        self.init(
            chainPath: try row.chainPath,
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

    var chainPath: String { get throws { try row.nonEmptyText("chain_path") } }
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
    func hasAcceptedBlock(
        _ blockCID: String,
        at chainPath: [String] = ["Nexus"]
    ) throws -> Bool {
        guard CIDIdentity.isCanonical(blockCID) else {
            throw NodeStoreError.corrupt("invalid accepted block lookup")
        }
        return try !database.query(
            "SELECT 1 FROM accepted_blocks WHERE chain_path = ?1 AND block_cid = ?2 LIMIT 1",
            params: [.text(chainPath.joined(separator: "/")), .text(blockCID)]
        ).isEmpty
    }

    /// Whether `blockCID` is the genesis block of the chain at `chainPath`.
    func isGenesis(_ blockCID: String, at chainPath: [String]) throws -> Bool {
        try !database.query(
            "SELECT 1 FROM accepted_blocks WHERE chain_path = ?1 AND block_cid = ?2 AND parent_cid IS NULL LIMIT 1",
            params: [.text(chainPath.joined(separator: "/")), .text(blockCID)]
        ).isEmpty
    }

    /// Whether this chain executed `blockCID`: its post-state is the state
    /// of a block this node validated, not one it has only weighed.
    func hasExecutedBlock(_ blockCID: String, at chainPath: [String]) throws -> Bool {
        guard CIDIdentity.isCanonical(blockCID) else {
            throw NodeStoreError.corrupt("invalid executed block lookup")
        }
        return try !database.query(
            "SELECT 1 FROM accepted_blocks WHERE chain_path = ?1 AND block_cid = ?2 AND validated != ?3 LIMIT 1",
            params: [.text(chainPath.joined(separator: "/")), .text(blockCID), BlockStatus.header.sqlValue]
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
        at chainPath: String,
        admissionSequence: Int64,
        status: BlockStatus
    ) throws {
        for block in blocks {
            let row = try database.row(
                AcceptedBlockRow.self,
                "SELECT chain_path, block_cid, parent_cid, admission_seq FROM accepted_blocks WHERE chain_path = ?1 AND block_cid = ?2",
                params: [.text(chainPath), .text(block.blockCID)]
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
                "INSERT INTO accepted_blocks (chain_path, block_cid, parent_cid, admission_seq, validated, leaf) VALUES (?1, ?2, ?3, ?4, ?5, CASE WHEN EXISTS (SELECT 1 FROM accepted_blocks WHERE chain_path = ?1 AND parent_cid = ?2) THEN 0 ELSE 1 END)",
                params: [
                    .text(chainPath),
                    .text(block.blockCID),
                    block.parentCID.map(NodeSQLiteValue.text) ?? .null,
                    .int(admissionSequence),
                    status.sqlValue,
                ]
            )
            if let parentCID = block.parentCID {
                try database.execute(
                    "UPDATE accepted_blocks SET leaf = 0 WHERE chain_path = ?1 AND block_cid = ?2 AND leaf = 1",
                    params: [.text(chainPath), .text(parentCID)]
                )
            }
        }
    }

    /// The leaf flag is a derived index over the parent links, written in
    /// the journal's transaction; boot repairs a row that disagrees (an
    /// edited or damaged store) in one statement, never a wipe.
    func repairLeafFlags() throws {
        let leaf = "NOT EXISTS (SELECT 1 FROM accepted_blocks AS child WHERE child.chain_path = accepted_blocks.chain_path AND child.parent_cid = accepted_blocks.block_cid)"
        try database.execute("UPDATE accepted_blocks SET leaf = \(leaf) WHERE leaf IS NOT \(leaf)")
    }
}
