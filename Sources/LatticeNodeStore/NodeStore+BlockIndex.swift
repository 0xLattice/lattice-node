import Foundation
import Lattice
import UInt256
import VolumeBroker
import cashew

package struct AcceptedBlockRecord: Hashable {
    package let blockCID: String
    package let parentCID: String?

    package init(blockCID: String, parentCID: String?) {
        self.blockCID = blockCID
        self.parentCID = parentCID
    }
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
/// non-empty text (tests stage blocks whose hashes are plain labels).
/// `parent_cid` is NULL for a root and otherwise non-empty text; an empty
/// string is malformed.
package struct AcceptedBlockRow: NodeStoreRecord {
    package static let table = "accepted_blocks"
    private let row: Row

    package init(_ row: Row) { self.row = row }

    package var chainPath: String { get throws { try row.nonEmptyText("chain_path") } }
    package var blockCID: String { get throws { try row.nonEmptyText("block_cid") } }
    package var parentCID: String? {
        get throws {
            guard let parent = try row.optionalText("parent_cid") else { return nil }
            guard !parent.isEmpty else {
                throw NodeStoreError.malformedRow(table: Self.table, column: "parent_cid")
            }
            return parent
        }
    }
    package var admissionSequence: Int64 { get throws { try row.positiveInt("admission_seq") } }
}

extension NodeStore {
    /// The store's database in a node's storage directory.
    package static func databasePath(storage: URL) -> URL {
        storage.appendingPathComponent("state.db")
    }

    /// Whether the store in `storage` holds blocks of `chainPath`, by a
    /// query only, never creating a store: false when there is none yet, an
    /// error when there is one that cannot be read. Opened read-write: a WAL
    /// database stopped cleanly has no -wal/-shm files, and SQLite opens it
    /// read-only only with them. Its callers are the node itself, or a CLI
    /// holding the storage lock.
    package static func holdsBlocks(of chainPath: String, storage: URL) throws -> Bool {
        let path = databasePath(storage: storage)
        guard FileManager.default.fileExists(atPath: path.path) else { return false }
        let database = try NodeSQLite(path: path.path, create: false)
        return !(try database.query(
            "SELECT 1 FROM accepted_blocks WHERE chain_path = ?1 LIMIT 1", params: [.text(chainPath)]
        )).isEmpty
    }

    package func hasAcceptedBlock(
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
    package func isGenesis(_ blockCID: String, at chainPath: [String]) throws -> Bool {
        try !database.query(
            "SELECT 1 FROM accepted_blocks WHERE chain_path = ?1 AND block_cid = ?2 AND parent_cid IS NULL LIMIT 1",
            params: [.text(chainPath.joined(separator: "/")), .text(blockCID)]
        ).isEmpty
    }

    /// Whether this chain executed `blockCID`: its post-state is the state
    /// of a block this node validated, not one it has only weighed.
    package func hasExecutedBlock(_ blockCID: String, at chainPath: [String]) throws -> Bool {
        guard CIDIdentity.isCanonical(blockCID) else {
            throw NodeStoreError.corrupt("invalid executed block lookup")
        }
        return try !database.query(
            "SELECT 1 FROM accepted_blocks WHERE chain_path = ?1 AND block_cid = ?2 AND validated != ?3 LIMIT 1",
            params: [.text(chainPath.joined(separator: "/")), .text(blockCID), BlockStatus.header.sqlValue]
        ).isEmpty
    }

    package static func acceptedBlocks(
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
    package func persistAcceptedBlockRows(
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
            try database.execute(
                "INSERT INTO accepted_blocks (chain_path, block_cid, parent_cid, admission_seq, validated) VALUES (?1, ?2, ?3, ?4, ?5)",
                params: [
                    .text(chainPath),
                    .text(block.blockCID),
                    block.parentCID.map(NodeSQLiteValue.text) ?? .null,
                    .int(admissionSequence),
                    status.sqlValue,
                ]
            )
        }
    }
}
