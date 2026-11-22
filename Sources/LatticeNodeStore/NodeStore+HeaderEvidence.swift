import Foundation
import Lattice
import LatticeNodeCore
import cashew
import LatticeNodeConfig
import LatticeNodeSupport

/// Weighed header material and credited child proofs. A header can arrive
/// before its complete boundary Volume, so its node, child index, and proofs
/// cannot be represented as a complete content Volume yet. They are written in
/// the transaction of the facts that reference them.
extension NodeStore {
    package struct PreparedEvidence {
        package var headers: [(cid: String, block: Data, childrenCID: String, children: Data)] = []
        package var proofs: [(child: String, root: String, entries: [(cid: String, data: Data)])] = []
    }

    package static func prepareEvidence(
        headers: [StoredHeader], proofs: [StoredProof], at path: ChainPath
    ) throws -> PreparedEvidence {
        var prepared = PreparedEvidence()
        for header in headers {
            guard let block = header.block.toData(), let children = header.children.toData() else {
                throw NodeStoreError.corrupt("a weighed header does not serialize")
            }
            prepared.headers.append((header.blockCID, block, header.block.children.rawCID, children))
        }
        for stored in proofs {
            let proof = stored.proof
            guard path.count > 1,
                  CIDIdentity.isCanonical(stored.childCID), CIDIdentity.isCanonical(proof.rootCID),
                  // Byte for byte, as Lattice's check: `String ==` is
                  // Unicode canonical equivalence, which admits a respelled path.
                  proof.directoryPath.elementsEqual(path.dropFirst(), by: { $0.utf8.elementsEqual($1.utf8) }) else {
                throw NodeStoreError.corrupt("a child proof does not match its chain path")
            }
            // What `serialize` refuses is refused here too.
            _ = try proof.serialize()
            guard proof.entries.allSatisfy({ CIDIdentity.isCanonical($0.cid) }) else {
                throw NodeStoreError.corrupt("a child proof names an entry by a non-canonical CID")
            }
            prepared.proofs.append((stored.childCID, proof.rootCID, proof.entries))
        }
        return prepared
    }

    /// Owner: `stageNodeFacts` — runs inside its transaction.
    package static func writeEvidence(_ evidence: PreparedEvidence, at path: String, in database: NodeSQLite) throws {
        for row in evidence.headers {
            try database.execute(
                "INSERT OR IGNORE INTO headers (cid, block, children_cid) VALUES (?1, ?2, ?3)",
                params: [.text(row.cid), .blob(row.block), .text(row.childrenCID)]
            )
            try database.execute(
                "INSERT OR IGNORE INTO child_indexes (cid, bytes) VALUES (?1, ?2)",
                params: [.text(row.childrenCID), .blob(row.children)]
            )
        }
        for row in evidence.proofs {
            for entry in row.entries where try database.query(
                "SELECT 1 FROM headers WHERE cid = ?1 AND block = ?2 UNION ALL SELECT 1 FROM child_indexes WHERE cid = ?1 AND bytes = ?2 LIMIT 1",
                params: [.text(entry.cid), .blob(entry.data)]
            ).isEmpty {
                try database.execute(
                    "INSERT OR IGNORE INTO proof_entries (cid, bytes) VALUES (?1, ?2)",
                    params: [.text(entry.cid), .blob(entry.data)]
                )
            }
            try database.execute(
                // A verified proof is fixed by its block, root and path, so
                // a good copy only ever replaces a bad row's entries.
                """
                INSERT INTO child_proofs (chain, child, root, entries) VALUES (?1, ?2, ?3, ?4)
                ON CONFLICT (chain, child, root) DO UPDATE SET entries = excluded.entries
                """,
                params: [
                    .text(path), .text(row.child), .text(row.root),
                    .text(row.entries.map(\.cid).joined(separator: " ")),
                ]
            )
        }
    }

    /// The saved proofs of `children` at `path`, each block's ordered by
    /// root; a block with none is absent. Read on demand, never held: one
    /// primary-key range read per chunk of blocks. A query that fails is a
    /// store fault and throws. A row that does not read back as its proof is
    /// left out and deleted: this node serves the block without it, and
    /// takes a good copy again only if a peer re-sends it while the block
    /// still waits for proof (a block already credited is not re-written).
    package nonisolated func savedProofs(at path: ChainPath, for children: [String]) throws -> [String: [ChildBlockProof]] {
        var proofs: [String: [ChildBlockProof]] = [:]
        guard path.count > 1, ChainAddress(path) != nil else { return proofs }
        var bad: [Int64] = []
        var start = children.startIndex
        while start < children.endIndex {
            let chunk = children[start..<min(start + 500, children.endIndex)]
            start = chunk.endIndex
            let marks = (2...(chunk.count + 1)).map { "?\($0)" }.joined(separator: ", ")
            for row in try reads.rows(
                from: "child_proofs",
                "SELECT rowid, child, root, entries FROM child_proofs WHERE chain = ?1 AND child IN (\(marks)) ORDER BY child, root",
                params: [.text(path.joined(separator: "/"))] + chunk.map { .text($0) }
            ) {
                if let saved = try savedProof(row, at: path) {
                    proofs[saved.child, default: []].append(saved.proof)
                } else if let rowid = try? row.int("rowid") {
                    bad.append(rowid)
                    SyncTrace.log(
                        chain: path,
                        "saved proof unreadable, left out: block=\((try? row.text("child")) ?? "?") root=\((try? row.text("root")) ?? "?")"
                    )
                }
            }
        }
        if !bad.isEmpty { Task { await self.dropBadProofs(bad, at: path) } }
        return proofs
    }

    /// A `child_proofs` row as the proof it names, each entry read by its
    /// CID, or nil if it is not one: an entry not held, or not named by a
    /// CID. The proof is the one written, byte for byte.
    private nonisolated func savedProof(_ row: Row, at path: ChainPath) throws -> (child: String, proof: ChildBlockProof)? {
        guard let child = try? row.nonEmptyText("child"), let root = try? row.nonEmptyText("root"),
              let cids = (try? row.text("entries")).map({ $0.split(separator: " ").map(String.init) }),
              CIDIdentity.isCanonical(child), CIDIdentity.isCanonical(root),
              cids.allSatisfy(CIDIdentity.isCanonical) else { return nil }
        var entries: [(cid: String, data: Data)] = []
        for cid in cids {
            guard let bytes = try reads.row(
                from: "proof_entries",
                "SELECT bytes FROM proof_entries WHERE cid = ?1 UNION ALL SELECT block FROM headers WHERE cid = ?1 UNION ALL SELECT bytes FROM child_indexes WHERE cid = ?1 LIMIT 1",
                params: [.text(cid)]
            )?.blob("bytes") else { return nil }
            entries.append((cid, bytes))
        }
        return (child, ChildBlockProof(rootCID: root, directoryPath: Array(path.dropFirst()), entries: entries))
    }

    /// Best effort: delete each row of `path` that still does not read back
    /// as its proof (a good copy may have replaced its bytes since, and a
    /// deleted rowid can be reused by another chain's row).
    private func dropBadProofs(_ rowids: [Int64], at path: ChainPath) {
        let chain = path.joined(separator: "/")
        for rowid in rowids {
            guard let row = try? database.row(
                from: "child_proofs",
                "SELECT rowid, child, root, entries FROM child_proofs WHERE rowid = ?1 AND chain = ?2",
                params: [.int(rowid), .text(chain)]
            ), let unread = try? savedProof(row, at: path) == nil, unread else { continue }
            _ = try? database.execute(
                "DELETE FROM child_proofs WHERE rowid = ?1 AND chain = ?2",
                params: [.int(rowid), .text(chain)]
            )
        }
    }

    package nonisolated func header(_ cid: String) -> (block: Block, children: FlatDictionary<BlockHeader>)? {
        guard let row = try? reads.row(
            HeaderEvidenceRow.self,
            "SELECT h.block AS block, c.bytes AS children FROM headers h JOIN child_indexes c ON c.cid = h.children_cid WHERE h.cid = ?1",
            params: [.text(cid)]
        ),
              let block = (try? row.block).flatMap(Block.init(data:)),
              let children = (try? row.children).flatMap(FlatDictionary<BlockHeader>.init(data:))
        else { return nil }
        return (block, children)
    }

    /// A weighed block's own node, as it was weighed.
    package nonisolated func headerBlockBytes(_ cid: String) -> Data? {
        try? reads.row(
            HeaderBlockRow.self, "SELECT block FROM headers WHERE cid = ?1", params: [.text(cid)]
        )?.block
    }

    package nonisolated func childIndexBytes(_ cid: String) -> Data? {
        try? reads.row(
            ChildIndexEvidenceRow.self, "SELECT bytes FROM child_indexes WHERE cid = ?1", params: [.text(cid)]
        )?.bytes
    }
}

package struct HeaderBlockRow: NodeStoreRecord {
    package static let table = "headers"
    private let row: Row

    package init(_ row: Row) { self.row = row }

    package var block: Data { get throws { try row.blob("block") } }
}

/// Every weighed block's node and child index, by CID: what execution and
/// mining read of a block whose body this store does not hold.
package struct HeaderRecords: ContentSource {
    package let store: NodeStore

    package init(store: NodeStore) { self.store = store }

    package func fetch(_ cids: Set<String>) async -> [String: Data] {
        var found: [String: Data] = [:]
        for cid in cids {
            if let bytes = store.headerBlockBytes(cid) ?? store.childIndexBytes(cid) { found[cid] = bytes }
        }
        return found
    }
}

package struct HeaderEvidenceRow: NodeStoreRecord {
    package static let table = "headers"
    private let row: Row

    package init(_ row: Row) { self.row = row }

    package var block: Data { get throws { try row.blob("block") } }
    package var children: Data { get throws { try row.blob("children") } }
}

package struct ChildIndexEvidenceRow: NodeStoreRecord {
    package static let table = "child_indexes"
    private let row: Row

    package init(_ row: Row) { self.row = row }

    package var bytes: Data { get throws { try row.blob("bytes") } }
}

/// A served page's saved proofs, read just ahead of the page in chunks that
/// grow from 16 to 256 blocks, so a page cut short by its budget reads little
/// past its cut. A root chain's blocks carry none and read nothing.
package struct SavedProofPage {
    package let store: NodeStore
    package let path: ChainPath
    package let cids: [String]
    private var (readTo, chunk) = (0, 16)
    private var proofs: [String: [ChildBlockProof]] = [:]

    package init(store: NodeStore, path: ChainPath, cids: [String]) {
        (self.store, self.path, self.cids) = (store, path, cids)
    }

    /// The saved proofs of the block at `offset`, asked in page order.
    package mutating func proofs(at offset: Int) throws -> [ChildBlockProof] {
        guard path.count > 1 else { return [] }
        if offset >= readTo {
            readTo = min(offset + chunk, cids.count)
            chunk = min(chunk * 2, 256)
            proofs = try store.savedProofs(at: path, for: Array(cids[offset..<readTo]))
        }
        return proofs[cids[offset]] ?? []
    }
}
