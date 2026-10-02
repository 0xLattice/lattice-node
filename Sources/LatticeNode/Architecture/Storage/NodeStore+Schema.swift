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
    /// Epoch 38 makes issued and handed-off contextual candidates mutually
    /// exclusive and gives each handoff an age for budgeted eviction.
    /// Epoch 39 records the deferred-execution tier (weighed vs validated) on
    /// each accepted block so recovery reconstructs the validated set.
    /// Epoch 40 records leaf-ness on each accepted block so the frontier page
    /// is an index read, not a per-row scan of the accepted history.
    /// Epoch 41 records the root of the child-evidence index
    /// (`child_evidence_root`), built fresh from the first admission, and
    /// drops the parent-to-child proof pipeline: the issuance ordinals and
    /// the outgoing proofs, routes, prepared proofs, the parent-evidence scan
    /// cursor and inbox, candidate handoffs, and the source identifier.
    /// Epoch 42 adds `core_meta`, the core driver's weigh log id.
    /// Older stores must be
    /// wiped; Nexus deterministically recreates the configured exact genesis.
    static let currentSchemaEpoch: Int64 = 42

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
        "consensus_revision",
        "admission_batches",
        "admission_facts",
        "accepted_blocks",
        "issued_parent_fact_sources",
        "issued_parent_facts",
        "issued_child_edges",
        "issued_child_proofs",
        "child_evidence_root",
        "child_evidence_pins_dirty",
        "local_mempool_transactions",
        "contextual_candidates",
        "contextual_candidate_roots",
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
            CREATE TABLE IF NOT EXISTS consensus_revision (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                revision TEXT NOT NULL
            ) WITHOUT ROWID
            """)
        try database.execute(
            "INSERT OR IGNORE INTO consensus_revision (singleton, revision) VALUES (1, '0')"
        )
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
            CREATE TABLE IF NOT EXISTS issued_parent_fact_sources (
                payload BLOB PRIMARY KEY
            ) WITHOUT ROWID
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS issued_parent_facts (
                kind TEXT NOT NULL,
                key_a TEXT NOT NULL,
                key_b TEXT NOT NULL,
                payload BLOB NOT NULL,
                PRIMARY KEY (kind, key_a, key_b)
            ) WITHOUT ROWID
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS issued_child_edges (
                edge_cid TEXT PRIMARY KEY,
                parent_carrier_cid TEXT NOT NULL,
                directory TEXT NOT NULL,
                child_cid TEXT NOT NULL,
                UNIQUE (parent_carrier_cid, directory, child_cid)
            ) WITHOUT ROWID
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS issued_child_proofs (
                scope TEXT NOT NULL,
                edge_cid TEXT NOT NULL,
                root_cid TEXT NOT NULL,
                attachment_cid TEXT NOT NULL,
                CHECK (scope = 'incoming_carrier'),
                PRIMARY KEY (scope, edge_cid, root_cid)
            )
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS child_evidence_root (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                root_cid TEXT NOT NULL
            ) WITHOUT ROWID
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS child_evidence_pins_dirty (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1)
            ) WITHOUT ROWID
            """)
        try database.execute(
            "CREATE INDEX IF NOT EXISTS issued_child_edges_by_directory ON issued_child_edges (directory, child_cid, edge_cid)"
        )
        try database.execute(
            "CREATE INDEX IF NOT EXISTS issued_child_edges_by_child ON issued_child_edges (child_cid, parent_carrier_cid, edge_cid)"
        )
        try database.execute("""
            CREATE TABLE IF NOT EXISTS local_mempool_transactions (
                transaction_cid TEXT PRIMARY KEY,
                added_at INTEGER NOT NULL CHECK (added_at >= 0)
            ) WITHOUT ROWID
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS contextual_candidates (
                candidate_cid TEXT PRIMARY KEY,
                offer_seq INTEGER UNIQUE,
                issued INTEGER NOT NULL CHECK (issued IN (0, 1)),
                CHECK (offer_seq IS NULL OR offer_seq > 0),
                CHECK (issued = 1 OR offer_seq IS NOT NULL)
            ) WITHOUT ROWID
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS contextual_candidate_roots (
                candidate_cid TEXT NOT NULL,
                root_cid TEXT NOT NULL,
                PRIMARY KEY (candidate_cid, root_cid)
            ) WITHOUT ROWID
            """)
        // The core driver's weigh log id: written with the first core fact.
        try database.execute("""
            CREATE TABLE IF NOT EXISTS core_meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            ) WITHOUT ROWID
            """)
    }

    /// Boot-time audit of every normalized index against the immutable
    /// admission batches: one audit per table owner, in a fixed order.
    func auditNormalizedIndexes() async throws {
        let staged = try loadStagedImports()
        try auditAdmissionFacts(staged: staged)
        let connectedAcceptedBlocks = try auditAcceptedBlocks(staged: staged)
        try auditIssuedParentFacts(connected: connectedAcceptedBlocks)
        try await auditIssuedChildAttachments()
        try auditContextualCandidates()
    }
}
