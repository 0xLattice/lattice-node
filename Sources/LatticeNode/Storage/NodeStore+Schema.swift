import Foundation
import Ivy
import Lattice
import UInt256
import VolumeBroker
import cashew

/// `node_metadata`: the store's identity singleton.
struct NodeMetadataRow: NodeStoreRecord {
    static let table = "node_metadata"
    private let row: Row

    init(_ row: Row) { self.row = row }

    var schemaEpoch: Int64 { get throws { try row.int("schema_epoch") } }
    var nexusGenesisCID: String { get throws { try row.text("nexus_genesis_cid") } }
    var chainPath: Data { get throws { try row.blob("chain_path") } }
}

extension NodeStore {
    /// Epoch 43: the node runtime's journal alone (admission batches and
    /// facts, accepted blocks, the local mempool, the weigh log id). Older
    /// stores must be wiped; Nexus deterministically recreates the
    /// configured exact genesis.
    static let currentSchemaEpoch: Int64 = 43

    static func validateMetadata(
        in database: NodeSQLite,
        tableNames: Set<String>,
        schemaEpoch: Int64,
        nexusGenesisCID: String,
        chainPath: Data
    ) throws {
        guard tableNames.contains("node_metadata") else {
            throw NodeStoreError.wipeRequired("missing schema metadata")
        }
        let rows: [NodeMetadataRow]
        do {
            rows = try database.rows(
                NodeMetadataRow.self,
                "SELECT schema_epoch, nexus_genesis_cid, chain_path FROM node_metadata WHERE singleton = 1"
            )
        } catch {
            throw NodeStoreError.wipeRequired("unreadable schema metadata")
        }
        // A malformed metadata column is a wipe, not a typed refusal: the
        // store is not this node's to repair.
        let changed = NodeStoreError.wipeRequired(
            "schema epoch, Nexus genesis, or chain path changed"
        )
        guard rows.count == 1 else { throw changed }
        do {
            guard try rows[0].schemaEpoch == schemaEpoch,
                  try rows[0].nexusGenesisCID == nexusGenesisCID,
                  try rows[0].chainPath == chainPath else {
                throw changed
            }
        } catch NodeStoreError.malformedRow {
            throw changed
        }
    }

    static let expectedTables: Set<String> = [
        "node_metadata",
        "admission_batches",
        "admission_facts",
        "accepted_blocks",
        "local_mempool_transactions",
        "core_meta",
    ]

    /// Owner: NodeStore.init — runs before the store exists, on an empty database.
    static func createSchema(
        in database: NodeSQLite,
        schemaEpoch: Int64,
        nexusGenesisCID: String,
        chainPath: Data
    ) throws {
        try database.transaction {
            try database.execute("""
                CREATE TABLE node_metadata (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    schema_epoch INTEGER NOT NULL,
                    nexus_genesis_cid TEXT NOT NULL,
                    chain_path BLOB NOT NULL
                )
                """)
            try database.execute(
                "INSERT INTO node_metadata (singleton, schema_epoch, nexus_genesis_cid, chain_path) VALUES (1, ?1, ?2, ?3)",
                params: [
                    .int(schemaEpoch),
                    .text(nexusGenesisCID),
                    .blob(chainPath),
                ]
            )
            try createDataTables(in: database)
        }
    }

    /// Every index, `IF NOT EXISTS`, run at every open (new and existing
    /// stores alike) so an index introduced later still materializes.
    /// Owner: NodeStore.init — runs before the store exists, on every open.
    static func ensureIndexes(in database: NodeSQLite) throws {
        try database.execute(
            "CREATE INDEX IF NOT EXISTS accepted_blocks_by_parent ON accepted_blocks (parent_cid, admission_seq, block_cid)"
        )
        // The frontier (cursor-less) page: the leaves, newest first. Partial
        // on `leaf = 1` so on a fork-free chain the page is one index entry,
        // never a scan of the accepted history filtered per row.
        try database.execute(
            "CREATE INDEX IF NOT EXISTS accepted_blocks_frontier ON accepted_blocks (admission_seq DESC, block_cid DESC) WHERE leaf = 1"
        )
    }

    private static func createDataTables(in database: NodeSQLite) throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS admission_batches (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                payload BLOB NOT NULL UNIQUE,
                volume_roots BLOB NOT NULL
            )
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS admission_facts (
                fact_id BLOB PRIMARY KEY,
                payload BLOB NOT NULL
            ) WITHOUT ROWID
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS accepted_blocks (
                block_cid TEXT PRIMARY KEY,
                parent_cid TEXT,
                admission_seq INTEGER NOT NULL,
                validated INTEGER NOT NULL DEFAULT \(BlockStatus.executed.rawValue),
                leaf INTEGER NOT NULL DEFAULT 1
            ) WITHOUT ROWID
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS local_mempool_transactions (
                transaction_cid TEXT PRIMARY KEY,
                added_at INTEGER NOT NULL CHECK (added_at >= 0)
            ) WITHOUT ROWID
            """)
        // The node runtime's weigh log id: written with the first chain fact.
        try database.execute("""
            CREATE TABLE IF NOT EXISTS core_meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            ) WITHOUT ROWID
            """)
    }

    /// Boot-time audit of every normalized index against the immutable
    /// admission batches: one audit per table owner, in a fixed order.
    func auditNormalizedIndexes() throws {
        let staged = try loadStagedImports()
        try auditAdmissionFacts(staged: staged)
        try auditAcceptedBlocks(staged: staged)
    }
}
