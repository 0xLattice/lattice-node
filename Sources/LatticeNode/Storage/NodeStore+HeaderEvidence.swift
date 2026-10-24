import Foundation
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
                "INSERT OR IGNORE INTO child_proofs (chain, child, root, bytes) VALUES (?1, ?2, ?3, ?4)",
                params: [.text(path), .text(row.child), .text(row.root), .blob(row.bytes)]
            )
        }
    }

    /// The saved proofs of `children` at `path`, each block's ordered by
    /// root; a block with none is absent. Read on demand, never held: one
    /// primary-key range read per chunk of blocks.
    nonisolated func savedProofs(at path: ChainPath, for children: [String]) throws -> [String: [ChildBlockProof]] {
        var proofs: [String: [ChildBlockProof]] = [:]
        let chain = path.joined(separator: "/")
        var start = children.startIndex
        while start < children.endIndex {
            let chunk = children[start..<min(start + 500, children.endIndex)]
            start = chunk.endIndex
            let marks = (2...(chunk.count + 1)).map { "?\($0)" }.joined(separator: ", ")
            for row in try database.rows(
                from: "child_proofs",
                "SELECT child, root, bytes FROM child_proofs WHERE chain = ?1 AND child IN (\(marks)) ORDER BY child, root",
                params: [.text(chain)] + chunk.map { .text($0) }
            ) {
                guard let proof = ChildBlockProof.deserialize(try row.blob("bytes")) else {
                    throw NodeStoreError.corrupt("a saved child proof does not deserialize")
                }
                let child = try row.nonEmptyText("child")
                let root = try row.nonEmptyText("root")
                guard path.count > 1, ChainAddress(path) != nil,
                      CIDIdentity.isCanonical(child), CIDIdentity.isCanonical(root),
                      proof.directoryPath == Array(path.dropFirst()),
                      proof.rootCID == root else {
                    throw NodeStoreError.corrupt("a saved child proof does not match its index")
                }
                proofs[child, default: []].append(proof)
            }
        }
        return proofs
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
