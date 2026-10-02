import Foundation
import Lattice
import LatticeNodeCore
import cashew

/// The header content the core's facts reference: each weighed block's node
/// bytes and its child index, as they arrived on the wire. A wire header is
/// the block node alone, not its whole boundary Volume, so it cannot go into
/// the Volume store (a root's membership is fixed once stored, and the body
/// fetch stores the full boundary later). It lives in its own SQLite file
/// beside state.db, committed (synchronous=FULL) before the facts.
// PENDING P4 (one store): this sidecar folds into the node store.
final class CoreHeaderStore: Sendable {
    static let fileName = "core-headers.db"

    private let database: NodeSQLite

    init(directory: URL) throws {
        database = try NodeSQLite(path: directory.appendingPathComponent(Self.fileName).path)
        try database.configureDurability()
        try database.execute(
            "CREATE TABLE IF NOT EXISTS headers (cid TEXT PRIMARY KEY, block BLOB NOT NULL, children_cid TEXT NOT NULL)"
        )
        try database.execute(
            "CREATE TABLE IF NOT EXISTS child_indexes (cid TEXT PRIMARY KEY, bytes BLOB NOT NULL)"
        )
    }

    /// One transaction: every header of a persist batch, or none.
    func store(_ headers: [StoredHeader]) throws {
        guard !headers.isEmpty else { return }
        var rows: [(cid: String, block: Data, childrenCID: String, children: Data)] = []
        for header in headers {
            guard let block = header.block.toData(), let children = header.children.toData() else {
                throw NodeStoreError.corrupt("a weighed header does not serialize")
            }
            rows.append((header.blockCID, block, header.block.children.rawCID, children))
        }
        try database.transaction {
            for row in rows {
                try database.execute(
                    "INSERT OR IGNORE INTO headers (cid, block, children_cid) VALUES (?1, ?2, ?3)",
                    params: [.text(row.cid), .blob(row.block), .text(row.childrenCID)]
                )
                try database.execute(
                    "INSERT OR IGNORE INTO child_indexes (cid, bytes) VALUES (?1, ?2)",
                    params: [.text(row.childrenCID), .blob(row.children)]
                )
            }
        }
    }

    /// A stored header's block node and child index.
    func header(_ cid: String) -> (block: Block, children: FlatDictionary<BlockHeader>)? {
        guard let row = try? database.row(
            CoreHeaderRow.self,
            "SELECT h.block AS block, c.bytes AS children FROM headers h JOIN child_indexes c ON c.cid = h.children_cid WHERE h.cid = ?1",
            params: [.text(cid)]
        ),
              let block = (try? row.block).flatMap(Block.init(data:)),
              let children = (try? row.children).flatMap(FlatDictionary<BlockHeader>.init(data:))
        else { return nil }
        return (block, children)
    }

    func childIndexBytes(_ cid: String) -> Data? {
        try? database.row(
            CoreChildIndexRow.self, "SELECT bytes FROM child_indexes WHERE cid = ?1", params: [.text(cid)]
        )?.bytes
    }
}

/// `headers` joined with its `child_indexes` row.
struct CoreHeaderRow: NodeStoreRecord {
    static let table = "headers"
    private let row: Row

    init(_ row: Row) { self.row = row }

    var block: Data { get throws { try row.blob("block") } }
    var children: Data { get throws { try row.blob("children") } }
}

/// `child_indexes`: one child index's bytes by CID.
struct CoreChildIndexRow: NodeStoreRecord {
    static let table = "child_indexes"
    private let row: Row

    init(_ row: Row) { self.row = row }

    var bytes: Data { get throws { try row.blob("bytes") } }
}

