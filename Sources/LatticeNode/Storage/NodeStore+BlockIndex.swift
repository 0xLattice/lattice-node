import Foundation
import Ivy
import Lattice
import UInt256
import VolumeBroker
import cashew

struct AcceptedBlockRecord: Hashable {
    let blockCID: String
    let parentCID: String?
    let height: UInt64
    let postStateCID: String
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
    var height: UInt64 { get throws { try row.uint64("height") } }
    var postStateCID: String { get throws { try row.nonEmptyText("post_state") } }
    /// The execution tier; an integer outside `BlockStatus` is malformed.
    var status: BlockStatus {
        get throws {
            guard let status = BlockStatus(rawValue: try row.int("validated")) else {
                throw NodeStoreError.malformedRow(table: Self.table, column: "validated")
            }
            return status
        }
    }
}

extension NodeStore {
    /// The store's database in a node's storage directory.
    static func databasePath(storage: URL) -> URL {
        storage.appendingPathComponent("state.db")
    }

    /// Whether the store in `storage` holds blocks of `chainPath`, by a
    /// query only, never creating a store: false when there is none yet, an
    /// error when there is one that cannot be read. Opened read-write: a WAL
    /// database stopped cleanly has no -wal/-shm files, and SQLite opens it
    /// read-only only with them. Its callers are the node itself, or a CLI
    /// holding the storage lock.
    static func holdsBlocks(of chainPath: String, storage: URL) throws -> Bool {
        let path = databasePath(storage: storage)
        guard FileManager.default.fileExists(atPath: path.path) else { return false }
        let database = try NodeSQLite(path: path.path, create: false)
        return !(try database.query(
            "SELECT 1 FROM accepted_blocks WHERE chain_path = ?1 LIMIT 1", params: [.text(chainPath)]
        )).isEmpty
    }

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

    /// A block as the index holds it: its parent, height and post-state.
    func indexedBlock(_ blockCID: String, at chainPath: [String]) throws -> AcceptedBlockRecord? {
        guard let row = try database.row(
            AcceptedBlockRow.self,
            "SELECT block_cid, parent_cid, height, post_state FROM accepted_blocks WHERE chain_path = ?1 AND block_cid = ?2",
            params: [.text(chainPath.joined(separator: "/")), .text(blockCID)]
        ) else { return nil }
        return AcceptedBlockRecord(
            blockCID: try row.blockCID, parentCID: try row.parentCID,
            height: try row.height, postStateCID: try row.postStateCID
        )
    }

    static func acceptedBlocks(
        in batch: BlockImportBatch
    ) throws -> [AcceptedBlockRecord] {
        var blocks: [String: AcceptedBlockRecord] = [:]
        for fact in batch.facts {
            guard case .block(let block) = fact else { continue }
            let record = AcceptedBlockRecord(
                blockCID: block.blockHash,
                parentCID: block.parentBlockHash,
                height: block.blockHeight,
                postStateCID: block.postStateCID
            )
            if let existing = blocks[record.blockCID], existing != record {
                throw NodeStoreError.conflictingImportFact
            }
            blocks[record.blockCID] = record
        }
        return blocks.values.sorted { $0.blockCID < $1.blockCID }
    }

    /// Owner: `stageNodeFacts` — caller holds the transaction. A block's
    /// CID fixes its parent, height and post-state, so a row held is the
    /// same row.
    func persistAcceptedBlockRows(
        _ blocks: [AcceptedBlockRecord],
        at chainPath: String,
        status: BlockStatus
    ) throws {
        for block in blocks {
            try database.execute(
                "INSERT OR IGNORE INTO accepted_blocks (chain_path, block_cid, parent_cid, height, post_state, validated) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params: [
                    .text(chainPath),
                    .text(block.blockCID),
                    block.parentCID.map(NodeSQLiteValue.text) ?? .null,
                    .int(Int64(clamping: block.height)),
                    .text(block.postStateCID),
                    status.sqlValue,
                ]
            )
        }
    }
}
