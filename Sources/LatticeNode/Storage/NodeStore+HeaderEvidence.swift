import Foundation
import Lattice
import LatticeNodeCore
import cashew

typealias SavedChildProofs = [ChainPath: [String: [String: ChildBlockProof]]]

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

    nonisolated func savedProofs() throws -> SavedChildProofs {
        var proofs: SavedChildProofs = [:]
        for row in try database.rows(from: "child_proofs", "SELECT chain, child, root, bytes FROM child_proofs") {
            guard let proof = ChildBlockProof.deserialize(try row.blob("bytes")) else {
                throw NodeStoreError.corrupt("a saved child proof does not deserialize")
            }
            let path = try row.text("chain").split(separator: "/").map(String.init)
            let child = try row.nonEmptyText("child")
            let root = try row.nonEmptyText("root")
            guard path.count > 1, ChainAddress(path) != nil,
                  CIDIdentity.isCanonical(child), CIDIdentity.isCanonical(root),
                  proof.directoryPath == Array(path.dropFirst()),
                  proof.rootCID == root else {
                throw NodeStoreError.corrupt("a saved child proof does not match its index")
            }
            proofs[path, default: [:]][child, default: [:]][root] = proof
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

    nonisolated func childIndexBytes(_ cid: String) -> Data? {
        try? database.row(
            ChildIndexEvidenceRow.self, "SELECT bytes FROM child_indexes WHERE cid = ?1", params: [.text(cid)]
        )?.bytes
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
