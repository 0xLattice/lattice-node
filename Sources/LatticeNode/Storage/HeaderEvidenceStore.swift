import Foundation
import Lattice
import LatticeNodeCore
import cashew

typealias SavedChildProofs = [ChainPath: [String: [String: ChildBlockProof]]]

/// Durable wire evidence referenced by chain facts. A header can arrive before
/// its complete boundary Volume, so its node, child index, and credited child
/// proofs cannot be represented as a complete content Volume yet. They live in
/// this evidence database, committed with FULL durability before their facts.
final class HeaderEvidenceStore: Sendable {
    static let fileName = "header-evidence.db"
    static let schemaEpoch: Int64 = 1
    private static let expectedTables: Set<String> = [
        "evidence_metadata", "headers", "child_indexes", "child_proofs",
    ]

    private let database: NodeSQLite

    init(
        directory: URL,
        nexusGenesisCID: String = NexusGenesis.expectedBlockHash
    ) throws {
        database = try NodeSQLite(path: directory.appendingPathComponent(Self.fileName).path)
        let tables = Set(try database.rows(
            from: "sqlite_master",
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
        ).map { try $0.text("name") })
        if tables.isEmpty {
            try database.transaction {
                try database.execute("""
                    CREATE TABLE evidence_metadata (
                        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                        schema_epoch INTEGER NOT NULL,
                        nexus_genesis_cid TEXT NOT NULL
                    )
                    """)
                try database.execute(
                    "INSERT INTO evidence_metadata (singleton, schema_epoch, nexus_genesis_cid) VALUES (1, ?1, ?2)",
                    params: [.int(Self.schemaEpoch), .text(nexusGenesisCID)]
                )
                try database.execute(
                    "CREATE TABLE headers (cid TEXT PRIMARY KEY, block BLOB NOT NULL, children_cid TEXT NOT NULL)"
                )
                try database.execute(
                    "CREATE TABLE child_indexes (cid TEXT PRIMARY KEY, bytes BLOB NOT NULL)"
                )
                try database.execute(
                    "CREATE TABLE child_proofs (chain TEXT NOT NULL, child TEXT NOT NULL, root TEXT NOT NULL, bytes BLOB NOT NULL, PRIMARY KEY (chain, child, root))"
                )
            }
        } else {
            guard tables == Self.expectedTables else {
                throw NodeStoreError.wipeRequired(
                    "header evidence schema tables are missing or unexpected"
                )
            }
            let metadata: EvidenceMetadataRow?
            do {
                metadata = try database.row(
                    EvidenceMetadataRow.self,
                    "SELECT schema_epoch, nexus_genesis_cid FROM evidence_metadata WHERE singleton = 1"
                )
            } catch {
                throw NodeStoreError.wipeRequired("unreadable header evidence metadata")
            }
            do {
                guard let metadata,
                      try metadata.schemaEpoch == Self.schemaEpoch,
                      try metadata.nexusGenesisCID == nexusGenesisCID else {
                    throw NodeStoreError.wipeRequired(
                        "header evidence schema epoch or Nexus genesis changed"
                    )
                }
            } catch NodeStoreError.malformedRow {
                throw NodeStoreError.wipeRequired("unreadable header evidence metadata")
            }
        }
        try database.configureDurability()
    }

    func storeProof(_ proof: ChildBlockProof, for child: String, at path: [String]) throws {
        guard path.count > 1, ChainAddress(path) != nil,
              CIDIdentity.isCanonical(child), CIDIdentity.isCanonical(proof.rootCID),
              proof.directoryPath == Array(path.dropFirst()) else {
            throw NodeStoreError.corrupt("a child proof does not match its chain path")
        }
        try database.execute(
            "INSERT OR IGNORE INTO child_proofs (chain, child, root, bytes) VALUES (?1, ?2, ?3, ?4)",
            params: [.text(path.joined(separator: "/")), .text(child), .text(proof.rootCID), .blob(try proof.serialize())]
        )
    }

    func proofs() throws -> SavedChildProofs {
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

    func header(_ cid: String) -> (block: Block, children: FlatDictionary<BlockHeader>)? {
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

    func childIndexBytes(_ cid: String) -> Data? {
        try? database.row(
            ChildIndexEvidenceRow.self, "SELECT bytes FROM child_indexes WHERE cid = ?1", params: [.text(cid)]
        )?.bytes
    }
}

struct EvidenceMetadataRow: NodeStoreRecord {
    static let table = "evidence_metadata"
    private let row: Row

    init(_ row: Row) { self.row = row }

    var schemaEpoch: Int64 { get throws { try row.int("schema_epoch") } }
    var nexusGenesisCID: String { get throws { try row.nonEmptyText("nexus_genesis_cid") } }
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
