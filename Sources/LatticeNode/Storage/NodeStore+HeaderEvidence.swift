import Foundation
import Synchronization
import Lattice
import LatticeNodeCore
import cashew

/// Weighed header material and credited child proofs. A header can arrive
/// before its complete boundary Volume, so its node, child index, and proofs
/// cannot be represented as a complete content Volume yet. They are written in
/// the transaction of the facts that reference them.
extension NodeStore {
    struct PreparedEvidence {
        var headers: [(cid: String, block: Data, childrenCID: String, children: Data)] = []
        var proofs: [(child: String, root: String, bytes: Data)] = []
    }

    static func prepareEvidence(
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
                  proof.directoryPath == Array(path.dropFirst()) else {
                throw NodeStoreError.corrupt("a child proof does not match its chain path")
            }
            prepared.proofs.append((stored.childCID, proof.rootCID, try proof.serialize()))
        }
        return prepared
    }

    /// Owner: `stageNodeFacts` — runs inside its transaction.
    static func writeEvidence(_ evidence: PreparedEvidence, at path: String, in database: NodeSQLite) throws {
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
            try database.execute(
                // A verified proof is fixed by its block, root and path, so
                // a good copy only ever replaces a bad row's bytes.
                """
                INSERT INTO child_proofs (chain, child, root, bytes) VALUES (?1, ?2, ?3, ?4)
                ON CONFLICT (chain, child, root) DO UPDATE SET bytes = excluded.bytes
                """,
                params: [.text(path), .text(row.child), .text(row.root), .blob(row.bytes)]
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
    nonisolated func savedProofs(at path: ChainPath, for children: [String]) throws -> [String: [ChildBlockProof]] {
        var proofs: [String: [ChildBlockProof]] = [:]
        guard path.count > 1, ChainAddress(path) != nil else { return proofs }
        var bad: [Int64] = []
        var start = children.startIndex
        while start < children.endIndex {
            let chunk = children[start..<min(start + 500, children.endIndex)]
            start = chunk.endIndex
            let marks = (2...(chunk.count + 1)).map { "?\($0)" }.joined(separator: ", ")
            for row in try database.rows(
                from: "child_proofs",
                "SELECT rowid, child, root, bytes FROM child_proofs WHERE chain = ?1 AND child IN (\(marks)) ORDER BY child, root",
                params: [.text(path.joined(separator: "/"))] + chunk.map { .text($0) }
            ) {
                if let saved = Self.savedProof(row, at: path) {
                    proofs[saved.child, default: []].append(saved.proof)
                } else if let rowid = try? row.int("rowid") {
                    bad.append(rowid)
                    reportBadProof(at: path, (try? row.text("child")) ?? "?", (try? row.text("root")) ?? "?")
                }
            }
        }
        if !bad.isEmpty { Task { await self.dropBadProofs(bad, at: path) } }
        return proofs
    }

    /// A `child_proofs` row as the proof it names, or nil if it is not one.
    private static func savedProof(_ row: Row, at path: ChainPath) -> (child: String, proof: ChildBlockProof)? {
        guard let child = try? row.nonEmptyText("child"), let root = try? row.nonEmptyText("root"),
              let proof = (try? row.blob("bytes")).flatMap(ChildBlockProof.deserialize),
              CIDIdentity.isCanonical(child), CIDIdentity.isCanonical(root),
              proof.directoryPath == Array(path.dropFirst()),
              proof.rootCID == root else { return nil }
        return (child, proof)
    }

    /// Best effort: delete each row that still does not read back as its
    /// proof (a good copy may have replaced its bytes since).
    private func dropBadProofs(_ rowids: [Int64], at path: ChainPath) {
        for rowid in rowids {
            guard let row = try? database.row(
                from: "child_proofs",
                "SELECT rowid, child, root, bytes FROM child_proofs WHERE rowid = ?1",
                params: [.int(rowid)]
            ), Self.savedProof(row, at: path) == nil else { continue }
            _ = try? database.execute("DELETE FROM child_proofs WHERE rowid = ?1", params: [.int(rowid)])
        }
    }

    /// Each bad row is logged once, per store, for as many rows as
    /// `badProofsReported` remembers; past that, every 1,024th further row
    /// logs how many more there were.
    private static let badProofsReported = Mutex<(rows: Set<String>, more: Int)>(([], 0))

    private nonisolated func reportBadProof(at path: ChainPath, _ child: String, _ root: String) {
        let key = "\(ObjectIdentifier(self))\u{0}\(path)\u{0}\(child)\u{0}\(root)"
        let line: String? = Self.badProofsReported.withLock { reported in
            if reported.rows.contains(key) { return nil }
            if reported.rows.count < 1_024 {
                reported.rows.insert(key)
                return "saved proof unreadable, left out and deleted: block=\(child) root=\(root)"
            }
            reported.more += 1
            return reported.more % 1_024 == 0 ? "\(reported.more) more bad saved proof rows" : nil
        }
        if let line { SyncTrace.log(chain: path, line) }
    }

    nonisolated func header(_ cid: String) -> (block: Block, children: FlatDictionary<BlockHeader>)? {
        guard let row = try? database.row(
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
    nonisolated func headerBlockBytes(_ cid: String) -> Data? {
        try? database.row(
            HeaderBlockRow.self, "SELECT block FROM headers WHERE cid = ?1", params: [.text(cid)]
        )?.block
    }

    nonisolated func childIndexBytes(_ cid: String) -> Data? {
        try? database.row(
            ChildIndexEvidenceRow.self, "SELECT bytes FROM child_indexes WHERE cid = ?1", params: [.text(cid)]
        )?.bytes
    }
}

struct HeaderBlockRow: NodeStoreRecord {
    static let table = "headers"
    private let row: Row

    init(_ row: Row) { self.row = row }

    var block: Data { get throws { try row.blob("block") } }
}

/// Every weighed block's node and child index, by CID: what execution and
/// mining read of a block whose body this store does not hold.
struct HeaderRecords: ContentSource {
    let store: NodeStore

    func fetch(_ cids: Set<String>) async -> [String: Data] {
        var found: [String: Data] = [:]
        for cid in cids {
            if let bytes = store.headerBlockBytes(cid) ?? store.childIndexBytes(cid) { found[cid] = bytes }
        }
        return found
    }
}

struct HeaderEvidenceRow: NodeStoreRecord {
    static let table = "headers"
    private let row: Row

    init(_ row: Row) { self.row = row }

    var block: Data { get throws { try row.blob("block") } }
    var children: Data { get throws { try row.blob("children") } }
}

struct ChildIndexEvidenceRow: NodeStoreRecord {
    static let table = "child_indexes"
    private let row: Row

    init(_ row: Row) { self.row = row }

    var bytes: Data { get throws { try row.blob("bytes") } }
}

/// A served page's saved proofs, read just ahead of the page in chunks that
/// grow from 16 to 256 blocks, so a page cut short by its budget reads little
/// past its cut. A root chain's blocks carry none and read nothing.
struct SavedProofPage {
    let store: NodeStore
    let path: ChainPath
    let cids: [String]
    private var (readTo, chunk) = (0, 16)
    private var proofs: [String: [ChildBlockProof]] = [:]

    init(store: NodeStore, path: ChainPath, cids: [String]) {
        (self.store, self.path, self.cids) = (store, path, cids)
    }

    /// The saved proofs of the block at `offset`, asked in page order.
    mutating func proofs(at offset: Int) throws -> [ChildBlockProof] {
        guard path.count > 1 else { return [] }
        if offset >= readTo {
            readTo = min(offset + chunk, cids.count)
            chunk = min(chunk * 2, 256)
            proofs = try store.savedProofs(at: path, for: Array(cids[offset..<readTo]))
        }
        return proofs[cids[offset]] ?? []
    }
}
