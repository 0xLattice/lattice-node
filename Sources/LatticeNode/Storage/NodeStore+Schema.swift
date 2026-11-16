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
}

extension NodeStore {
    /// Epoch 48: each fact is kept once, by id, with the staged batch that
    /// first held it; the batch journal is gone and boot restores from the
    /// facts. A block fact no longer carries its state diff: `state_diffs`
    /// keeps it for the state window. A child proof names its entries by
    /// CID.
    /// Epoch 47: block facts record the block's `parentState`, which an
    /// attributed run checks before crediting a child block (§9.10). Older
    /// child-chain facts lack it and would read as the empty state.
    /// Epoch 46: weighed header material and credited child proofs live in
    /// this store, written with their facts. Older stores must be wiped; Nexus
    /// deterministically recreates the configured exact genesis.
    static let currentSchemaEpoch: Int64 = 48

    static func validateMetadata(
        in database: NodeSQLite,
        tableNames: Set<String>,
        schemaEpoch: Int64,
        nexusGenesisCID: String
    ) throws {
        guard tableNames.contains("node_metadata") else {
            throw NodeStoreError.wipeRequired("missing schema metadata")
        }
        let rows: [NodeMetadataRow]
        do {
            rows = try database.rows(
                NodeMetadataRow.self,
                "SELECT schema_epoch, nexus_genesis_cid FROM node_metadata WHERE singleton = 1"
            )
        } catch {
            throw NodeStoreError.wipeRequired("unreadable schema metadata")
        }
        // A malformed metadata column is a wipe, not a typed refusal: the
        // store is not this node's to repair.
        let changed = NodeStoreError.wipeRequired(
            "schema epoch or Nexus genesis changed"
        )
        guard rows.count == 1 else { throw changed }
        do {
            guard try rows[0].schemaEpoch == schemaEpoch,
                  try rows[0].nexusGenesisCID == nexusGenesisCID else {
                throw changed
            }
        } catch NodeStoreError.malformedRow {
            throw changed
        }
    }

    static let expectedTables: Set<String> = [
        "node_metadata",
        "admission_facts",
        "accepted_blocks",
        "local_mempool_transactions",
        "core_meta",
        "stream_cursors",
        "headers",
        "child_indexes",
        "child_proofs",
        "proof_entries",
        "state_diffs",
    ]

    /// Owner: NodeStore.init — runs before the store exists, on an empty database.
    static func createSchema(
        in database: NodeSQLite,
        schemaEpoch: Int64,
        nexusGenesisCID: String
    ) throws {
        try database.transaction {
            try database.execute("""
                CREATE TABLE node_metadata (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    schema_epoch INTEGER NOT NULL,
                    nexus_genesis_cid TEXT NOT NULL
                )
                """)
            try database.execute(
                "INSERT INTO node_metadata (singleton, schema_epoch, nexus_genesis_cid) VALUES (1, ?1, ?2)",
                params: [
                    .int(schemaEpoch),
                    .text(nexusGenesisCID),
                ]
            )
            try createDataTables(in: database)
        }
    }

    private static func createDataTables(in database: NodeSQLite) throws {
        // Every fact once, by id (`UNIQUE`), kept forever. `seq` is the
        // level's staged batch that first held it and `ord` its place in
        // that batch: a level reads back as one key range in its weigh
        // order, and appends at its end. A row is stored whole in its
        // b-tree page up to about 1,000 bytes: a block fact, without its
        // state diff, is about 750.
        try database.execute("""
            CREATE TABLE IF NOT EXISTS admission_facts (
                chain_path TEXT NOT NULL,
                seq INTEGER NOT NULL,
                ord INTEGER NOT NULL,
                fact_id BLOB NOT NULL,
                payload BLOB NOT NULL,
                PRIMARY KEY (chain_path, seq, ord),
                UNIQUE (chain_path, fact_id)
            ) WITHOUT ROWID
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS accepted_blocks (
                chain_path TEXT NOT NULL,
                block_cid TEXT NOT NULL,
                parent_cid TEXT,
                admission_seq INTEGER NOT NULL,
                validated INTEGER NOT NULL DEFAULT \(BlockStatus.executed.rawValue),
                PRIMARY KEY (chain_path, block_cid)
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
        try database.execute("""
            CREATE TABLE IF NOT EXISTS stream_cursors (
                chain_path TEXT NOT NULL,
                peer_key TEXT NOT NULL,
                log_id TEXT NOT NULL,
                position INTEGER NOT NULL CHECK (position >= 0),
                PRIMARY KEY (chain_path, peer_key)
            ) WITHOUT ROWID
            """)
        try database.execute(
            "CREATE TABLE IF NOT EXISTS headers (cid TEXT PRIMARY KEY, block BLOB NOT NULL, children_cid TEXT NOT NULL)"
        )
        try database.execute(
            "CREATE TABLE IF NOT EXISTS child_indexes (cid TEXT PRIMARY KEY, bytes BLOB NOT NULL)"
        )
        // A credited proof names its entries by CID: the block nodes and
        // child indexes `headers` and `child_indexes` hold are read from
        // there, and only the rest (a carrier's node and child index when
        // no level weighed it) is kept in `proof_entries`, once per CID.
        try database.execute(
            "CREATE TABLE IF NOT EXISTS child_proofs (chain TEXT NOT NULL, child TEXT NOT NULL, root TEXT NOT NULL, entries TEXT NOT NULL, PRIMARY KEY (chain, child, root))"
        )
        try database.execute(
            "CREATE TABLE IF NOT EXISTS proof_entries (cid TEXT PRIMARY KEY, bytes BLOB NOT NULL)"
        )
        // Undo data: each executed block's state diff, which moves the
        // counts of a chain's state on `recent`, kept for the state window
        // only (Bitcoin's `rev*.dat`). No fact carries it.
        try database.execute(
            "CREATE TABLE IF NOT EXISTS state_diffs (chain_path TEXT NOT NULL, block_cid TEXT NOT NULL, height INTEGER NOT NULL, diff BLOB NOT NULL, PRIMARY KEY (chain_path, block_cid))"
        )
    }
}
