import Foundation
import UInt256

/// One canonical block to publish into the durable commitment.
public struct CanonicalSegmentBlock: Sendable {
    public let height: UInt64
    public let hash: String
    public let stateRoot: String?
    public init(height: UInt64, hash: String, stateRoot: String? = nil) {
        self.height = height
        self.hash = hash
        self.stateRoot = stateRoot
    }
}

/// A contiguous, ascending run of canonical blocks committed atomically as the single
/// durable publish of a canonical-chain change (F5-4). `connectsBelow` is whether
/// `blocks.first` continues the already-committed chain at the height just below it:
/// true for normal extends/reorgs that share a committed prefix; false for a
/// fail-closed recovery/import segment that cannot verify the rows below it, in
/// which case those rows are invalidated in the same transaction. No `parentHash`
/// is needed — `connectsBelow` is computed by the caller at build time; the commit
/// only writes (height,hash) rows + the tip marker.
public struct CanonicalSegment: Sendable {
    public let blocks: [CanonicalSegmentBlock]
    public let connectsBelow: Bool
    public init(blocks: [CanonicalSegmentBlock], connectsBelow: Bool) {
        self.blocks = blocks
        self.connectsBelow = connectsBelow
    }
}

/// Derived per-block indexes/effects that can be committed atomically with a
/// canonical segment once the block body and transaction actions are known.
public struct CanonicalBlockEffects: Sendable {
    public let changes: StateChangeset
    public let receiptGeneralEntries: [(key: String, value: Data, height: UInt64)]
    public let txHistory: [(address: String, txCID: String, blockHash: String, height: UInt64)]

    public init(
        changes: StateChangeset,
        receiptGeneralEntries: [(key: String, value: Data, height: UInt64)],
        txHistory: [(address: String, txCID: String, blockHash: String, height: UInt64)]
    ) {
        self.changes = changes
        self.receiptGeneralEntries = receiptGeneralEntries
        self.txHistory = txHistory
    }
}

/// AUDIT-ONLY (Module 3): one row of the canonical-transition log. Pure
/// observability — never consulted to drive recovery/reconcile/fork-choice.
public struct CanonicalTransitionRecord: Sendable {
    public struct PromotedBlock: Sendable, Codable {
        public let hash: String
        public let height: UInt64
    }
    public let seq: Int64
    public let oldTip: String
    public let newTip: String
    public let height: UInt64
    public let reason: String
    public let promoted: [PromotedBlock]
    public let orphaned: [String]
}

public actor StateStore {
    private static let receiptsAppliedThroughPath = "meta:receipts-applied-through-height"

    private let db: SQLiteDatabase
    /// Separate read-only connection. SQLite WAL allows concurrent readers
    /// without blocking the writer. Nonisolated read methods use this to
    /// bypass actor serialization — callers no longer queue behind writes.
    private nonisolated let readDb: SQLiteDatabase
    private let chain: String

    public init(storagePath: URL, chain: String) throws {
        let dir = storagePath.appendingPathComponent(chain)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = dir.appendingPathComponent("state.db").path
        self.db = try SQLiteDatabase(path: dbPath)
        self.readDb = try SQLiteDatabase(path: dbPath)
        self.chain = chain
        try createTables()
    }

    /// Test-only: arm/disarm the underlying write-fault seam so durable-write
    /// failure paths are exercisable without corrupting a real DB. No production
    /// caller. `internal` so only `@testable import` sees it.
    func _armWriteFault() { db._armWriteFault() }
    func _disarmWriteFault() { db._disarmWriteFault() }

    /// Test-only : arm a one-shot fault so the NEXT `commitReceiptsThrough`
    /// throws before it writes anything.
    private var failNextReceiptsCommit = false
    func armReceiptsCommitFailure() {
        failNextReceiptsCommit = true
    }

    private nonisolated func createTables() throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS state (
                path TEXT PRIMARY KEY,
                value BLOB NOT NULL,
                height INTEGER NOT NULL
            )
        """)

        try db.execute("""
            CREATE TABLE IF NOT EXISTS tx_history (
                address TEXT NOT NULL,
                txCID TEXT NOT NULL,
                blockHash TEXT NOT NULL,
                height INTEGER NOT NULL,
                PRIMARY KEY (address, txCID)
            )
        """)
        try db.execute("CREATE INDEX IF NOT EXISTS idx_tx_history_addr ON tx_history(address, height DESC)")

        try db.execute("""
            CREATE TABLE IF NOT EXISTS block_index (
                height INTEGER PRIMARY KEY,
                blockHash TEXT NOT NULL
            )
        """)

        try db.execute("""
            CREATE TABLE IF NOT EXISTS block_stored_roots (
                height INTEGER NOT NULL,
                root TEXT NOT NULL,
                count INTEGER NOT NULL DEFAULT 1,
                PRIMARY KEY (height, root)
            )
        """)

        try createBlockProofTable()
        try db.execute("CREATE INDEX IF NOT EXISTS idx_block_proofs_hash ON block_proofs(blockHash)")
        try db.execute("""
            CREATE TABLE IF NOT EXISTS inherited_work_contributions (
                height INTEGER NOT NULL,
                blockHash TEXT NOT NULL,
                contributorID TEXT NOT NULL,
                workHex TEXT NOT NULL,
                PRIMARY KEY (blockHash, contributorID)
            )
        """)
        try db.execute("CREATE INDEX IF NOT EXISTS idx_inherited_work_height ON inherited_work_contributions(height)")

        // Child-local verified parent state transitions. Rows are inserted only
        // after the corresponding parent transition proof has been verified.
        // This is not a parent fork-choice view; child consensus uses it only to
        // prove parent state root continuity across child blocks.
        try db.execute("""
            CREATE TABLE IF NOT EXISTS parent_state_edges (
                from_root TEXT NOT NULL,
                to_root TEXT NOT NULL,
                UNIQUE(from_root, to_root)
            )
        """)
        try db.execute("""
            DELETE FROM parent_state_edges
            WHERE rowid NOT IN (
                SELECT MIN(rowid)
                FROM parent_state_edges
                GROUP BY from_root, to_root
            )
        """)
        try db.execute("CREATE INDEX IF NOT EXISTS idx_parent_state_edges_from ON parent_state_edges(from_root)")
        try db.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_parent_state_edges_unique ON parent_state_edges(from_root, to_root)")

        try db.execute("""
            CREATE TABLE IF NOT EXISTS parent_headers (
                parent_hash TEXT PRIMARY KEY,
                previous_hash TEXT NULL,
                height INTEGER NOT NULL
            )
        """)
        try db.execute("CREATE INDEX IF NOT EXISTS idx_parent_headers_height ON parent_headers(height)")

        try db.execute("""
            CREATE TABLE IF NOT EXISTS child_parent_anchors (
                child_hash TEXT PRIMARY KEY,
                parent_hash TEXT NOT NULL,
                height INTEGER NOT NULL
            )
        """)
        try db.execute("CREATE INDEX IF NOT EXISTS idx_child_parent_anchors_height ON child_parent_anchors(height)")

        // One-hop merged-mining validator record: every child block (at any
        // depth) pins the topmost nexus block that admitted it. Stored here
        // (not on the broker alone) so prune at retention can release the
        // broker pin in O(rows-at-height) without walking the chain.
        try db.execute("""
            CREATE TABLE IF NOT EXISTS validator_pins (
                child_cid TEXT PRIMARY KEY,
                parent_cid TEXT NOT NULL,
                height INTEGER NOT NULL
            )
        """)
        try db.execute("CREATE INDEX IF NOT EXISTS idx_validator_pins_height ON validator_pins(height)")

        try createStateDeathIndexTables()

        // AUDIT-ONLY (Module 3): a bounded, observability-only log of canonical
        // transitions published through publishCanonicalTransition. It is NOT a
        // replay queue and NOTHING in recovery/reconcile/startup reads it — only
        // the get* accessors below (inspection/tests/RPC) ever query it.
        try db.execute("""
            CREATE TABLE IF NOT EXISTS canonical_transitions (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                old_tip TEXT NOT NULL,
                new_tip TEXT NOT NULL,
                height INTEGER NOT NULL,
                reason TEXT NOT NULL,
                promoted TEXT NOT NULL,
                orphaned TEXT NOT NULL
            )
        """)

        // Drop legacy tables/indexes from the old duplicated-state design.
        try db.execute("DROP TABLE IF EXISTS state_diffs")
        try db.execute("DROP INDEX IF EXISTS idx_diffs_height")
        try db.execute("DROP INDEX IF EXISTS idx_diffs_height_path")
        // (DECISION LOCKED Round 10): the per-boot
        // `DELETE FROM state WHERE path LIKE 'account:%'` is REMOVED. It cleaned
        // up the legacy duplicated-state design that no longer ships post
        // flag-day; keeping it would run a full-table scan on every startup AND
        // a schema-version gate would conflict with the no-migration-versioning
        // lock. Dropped outright (no schema_version row). Covered by
        // AccountMigrationDropTests.test_boot_doesNotDeleteAccountRows.
    }

    private nonisolated func createBlockProofTable() throws {
        // F5-4 (Hierarchical GHOST): each accepted child block may have multiple
        // sparse PoW paths from parent/root blocks down to that block. The block's
        // continuity anchor is still singular; this table stores all verified work
        // evidence paths so inherited weight can count every contributing parent/root
        // block once. Height-stamped rows prune with their child block.
        try db.execute("""
            CREATE TABLE IF NOT EXISTS block_proofs (
                height INTEGER NOT NULL,
                blockHash TEXT NOT NULL,
                proofID TEXT NOT NULL,
                proof BLOB NOT NULL,
                PRIMARY KEY (height, blockHash, proofID)
            )
        """)

        // Stage 2b-ii: the replaced-roots GC ledger was removed (object-grain
        // retention reclaims superseded state via window-slide + transitive eviction).
        // Drop the legacy tables on existing DBs; fresh DBs never create them.
        try db.execute("DROP TABLE IF EXISTS block_replaced_roots")
        try db.execute("DROP TABLE IF EXISTS block_prune_progress")
    }

    // MARK: - State Refcount Index (SHADOW; reference-counting retention design)

    /// Durable EDGE-REFERENCE-COUNT bookkeeping for the reference-counting state-
    /// retention redesign (the K-block retention-window model), maintained in SHADOW
    /// mode alongside the live object-grain pin/prune mechanism. These tables are
    /// additive: nothing reads them for retention decisions yet, so a failure to
    /// write them never affects accept/prune/reorg.
    ///
    /// MODEL — `refcount[X]` = number of parent trie-edges pointing to state node X
    /// across the RETAINED state versions. X is reclaimable when `refcount[X] == 0`
    /// (no retained parent) AND X is not itself a retained block's post-state root
    /// (a root is held by the block pin, not by a parent edge).
    ///
    /// Tables:
    ///   - `state_node_refcount(cid, refcount)` — the LIVE edge count maintained by
    ///     accept increments (and reorg-revert undo). Prune decrements are simulated
    ///     in `reclaimableStateNodes(atFloor:)` rather than mutating this live count,
    ///     so the SHADOW verdict is a pure query (drives no unpin).
    ///   - `state_node_edges(parent, child, count)` — the outgoing child-edge
    ///     MULTISET of every retained node (its adjacency list). The prune cascade
    ///     and reorg revert both walk this; `count` handles a node referencing the
    ///     same child more than once.
    ///   - `state_node_created(cid, height)` / `state_node_replaced(cid, height)` —
    ///     the membership-faithful per-height created/replaced node sets (append-only
    ///     logs). `created` heights drive reorg revert (inverse-apply a height's
    ///     increments); `replaced` heights are the leaving set the prune boundary
    ///     decrements from. (NOT Lattice's path-wise `diffCIDs` — see the accept hook.)
    ///   - `state_node_root(height, cid)` — the post-state root CID per height, so the
    ///     reclaim simulation never reports a still-retained root as reclaimable.
    private nonisolated func createStateDeathIndexTables() throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS state_node_refcount (
                cid TEXT PRIMARY KEY,
                refcount INTEGER NOT NULL
            )
        """)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS state_node_edges (
                parent TEXT NOT NULL,
                child TEXT NOT NULL,
                count INTEGER NOT NULL,
                PRIMARY KEY (parent, child)
            )
        """)
        try db.execute("CREATE INDEX IF NOT EXISTS idx_state_node_edges_parent ON state_node_edges(parent)")
        try db.execute("""
            CREATE TABLE IF NOT EXISTS state_node_created (
                cid TEXT NOT NULL,
                height INTEGER NOT NULL,
                PRIMARY KEY (cid, height)
            )
        """)
        try db.execute("CREATE INDEX IF NOT EXISTS idx_state_node_created_height ON state_node_created(height)")
        try db.execute("""
            CREATE TABLE IF NOT EXISTS state_node_replaced (
                cid TEXT NOT NULL,
                height INTEGER NOT NULL,
                PRIMARY KEY (cid, height)
            )
        """)
        try db.execute("CREATE INDEX IF NOT EXISTS idx_state_node_replaced_height ON state_node_replaced(height)")
        try db.execute("""
            CREATE TABLE IF NOT EXISTS state_node_root (
                height INTEGER PRIMARY KEY,
                cid TEXT NOT NULL
            )
        """)
    }

    /// One node's outgoing child-edge multiset (the adjacency captured at accept).
    struct StateNodeEdges: Sendable {
        let parent: String
        /// child cid -> number of edges from `parent` to it.
        let children: [String: Int]
    }

    /// ACCEPT (increment): record block `height`'s membership-faithful `created` /
    /// `replaced` node sets, the outgoing edges of every `created` node, the post-
    /// state `root`, and increment `refcount[child]` for every created→child edge.
    /// Atomic. SHADOW: callers wrap this so a failure cannot affect accept/prune.
    ///
    /// `createdEdges` is the adjacency of exactly the `created` nodes (the changed
    /// root→leaf path); incrementing a SHARED child is correct — post_N now also
    /// references it. Re-introduction self-heals: a CID re-appearing in a later
    /// `created` re-increments it.
    func recordStateRefcountDiff(
        height: UInt64,
        root: String,
        created: [String],
        replaced: [String],
        createdEdges: [StateNodeEdges]
    ) throws {
        let h = Int64(height)
        let createdSet = Set(created.filter { !$0.isEmpty })
        let replacedSet = Set(replaced.filter { !$0.isEmpty })
        _ = try db.transaction {
            // Idempotency guard: a re-accept of the SAME (height, root) — e.g. the same
            // block flowing through both durable-commit paths, or the genesis seed
            // firing again — must NOT double-increment refcounts. If this exact root is
            // already recorded for the height, the increments were already applied.
            if !root.isEmpty {
                let already = try db.query(
                    "SELECT cid FROM state_node_root WHERE height = ?1", params: [.int(h)]
                ).first?["cid"]?.textValue
                if already == root { return }
                try db.execute(
                    "INSERT OR REPLACE INTO state_node_root (height, cid) VALUES (?1, ?2)",
                    params: [.int(h), .text(root)]
                )
            }
            for cid in createdSet {
                try db.execute(
                    "INSERT OR IGNORE INTO state_node_created (cid, height) VALUES (?1, ?2)",
                    params: [.text(cid), .int(h)]
                )
            }
            for cid in replacedSet {
                try db.execute(
                    "INSERT OR IGNORE INTO state_node_replaced (cid, height) VALUES (?1, ?2)",
                    params: [.text(cid), .int(h)]
                )
            }
            for edges in createdEdges where !edges.parent.isEmpty {
                // Persist this node's adjacency (idempotent — content-addressed, so a
                // re-created cid has identical edges). Then increment each child edge.
                for (child, count) in edges.children where !child.isEmpty && count > 0 {
                    try db.execute(
                        "INSERT OR REPLACE INTO state_node_edges (parent, child, count) VALUES (?1, ?2, ?3)",
                        params: [.text(edges.parent), .text(child), .int(Int64(count))]
                    )
                    try incrementRefcountLocked(cid: child, by: count)
                }
            }
        }
    }

    /// REORG REVERT: undo a single abandoned fork `height`'s accept increments, as
    /// if the height had never been applied. The append-only per-height logs make
    /// this a clean inverse-apply: for every node `created` at `height`, decrement
    /// each of its child edges (the same edges the accept incremented), then delete
    /// the height's created/replaced/root rows. A created node that is now referenced
    /// by NO other retained created-node and is itself no longer a created node is
    /// orphaned — its refcount/edges rows are swept when they reach zero / are unused.
    ///
    /// SHADOW accept only ever INCREMENTS (prune decrements are simulated, not
    /// applied to the live count), so revert only has to undo increments — no cascade
    /// is needed here.
    func forgetStateRefcountHeight(_ height: UInt64) throws {
        let h = Int64(height)
        let createdHere = try db.query(
            "SELECT cid FROM state_node_created WHERE height = ?1", params: [.int(h)]
        ).compactMap { $0["cid"]?.textValue }
        let replacedHere = try db.query(
            "SELECT cid FROM state_node_replaced WHERE height = ?1", params: [.int(h)]
        ).compactMap { $0["cid"]?.textValue }
        guard !createdHere.isEmpty || !replacedHere.isEmpty else {
            // Still drop a stray root row for the height, if any.
            _ = try db.transaction {
                try db.execute("DELETE FROM state_node_root WHERE height = ?1", params: [.int(h)])
            }
            return
        }
        _ = try db.transaction {
            for cid in createdHere {
                // Was this cid created ONLY at this height? If it is still created at
                // another retained height, its edges/refcount must survive; we only
                // undo the increments this height contributed.
                let edges = try db.query(
                    "SELECT child, count FROM state_node_edges WHERE parent = ?1", params: [.text(cid)]
                )
                for row in edges {
                    guard let child = row["child"]?.textValue,
                          let count = row["count"]?.intValue else { continue }
                    try incrementRefcountLocked(cid: child, by: -Int(count))
                }
            }
            try db.execute("DELETE FROM state_node_created WHERE height = ?1", params: [.int(h)])
            try db.execute("DELETE FROM state_node_replaced WHERE height = ?1", params: [.int(h)])
            try db.execute("DELETE FROM state_node_root WHERE height = ?1", params: [.int(h)])
            // Sweep adjacency rows for nodes that are no longer created anywhere
            // (their increments are fully undone) so a re-accept rebuilds them cleanly.
            for cid in createdHere {
                let stillCreated = try db.query(
                    "SELECT 1 FROM state_node_created WHERE cid = ?1 LIMIT 1", params: [.text(cid)]
                ).first != nil
                if !stillCreated {
                    try db.execute("DELETE FROM state_node_edges WHERE parent = ?1", params: [.text(cid)])
                }
            }
            // Drop any refcount rows that fell to <= 0 (fully dereferenced).
            try db.execute("DELETE FROM state_node_refcount WHERE refcount <= 0")
        }
    }

    /// Apply a signed delta to `refcount[cid]` (must run inside `db.transaction`).
    /// Inserts the row on first reference; a non-positive result deletes the row so
    /// "no row" canonically means refcount 0.
    private nonisolated func incrementRefcountLocked(cid: String, by delta: Int) throws {
        let current = try db.query(
            "SELECT refcount FROM state_node_refcount WHERE cid = ?1", params: [.text(cid)]
        ).first?["refcount"]?.intValue ?? 0
        let next = current + Int64(delta)
        if next <= 0 {
            try db.execute("DELETE FROM state_node_refcount WHERE cid = ?1", params: [.text(cid)])
        } else {
            try db.execute(
                "INSERT OR REPLACE INTO state_node_refcount (cid, refcount) VALUES (?1, ?2)",
                params: [.text(cid), .int(next)]
            )
        }
    }

    /// SHADOW reclaim verdict at a retention `floor`: simulate pruning every height
    /// strictly below `floor` and return the nodes whose edge-refcount reaches 0.
    ///
    /// THE DECREMENT (edge-count, cascade-gated on refcount 0). Pruning height H
    /// releases post_H's block pin, i.e. the EDGE holding its post-state root. We
    /// decrement that root, and whenever a node's simulated refcount reaches 0 it has
    /// no retained parent left, so it is itself leaving: we recurse and decrement each
    /// of ITS child edges (the CASCADE). Driving the cascade off the actual refcount
    /// (rather than the membership `replaced(H)` set) is what makes the verdict equal
    /// reachability even under re-introduction / cross-height structural sharing — a
    /// node re-referenced by a still-retained version simply never reaches 0, so its
    /// subtree is never cascaded. (`replaced(H)` is retained as the per-height log for
    /// reorg-revert symmetry + audit; it is membership-faithful — NOT path-wise
    /// `diffCIDs` — and over the K-window with no re-introduction the cascade frontier
    /// reproduces it exactly.) A node held by a STILL-RETAINED root (height >= floor)
    /// is never reclaimable — it lives via the block pin, not a parent edge — matching
    /// `isPinReachable` (a pinned root is reachable). Pure query: mutates nothing.
    public nonisolated func reclaimableStateNodes(atFloor floor: UInt64) -> [String] {
        let floorI = Int64(floor)
        // Live refcounts (accept increments only).
        guard let rcRows = try? readDb.query("SELECT cid, refcount FROM state_node_refcount") else { return [] }
        var refcount: [String: Int] = [:]
        for row in rcRows {
            if let cid = row["cid"]?.textValue, let rc = row["refcount"]?.intValue { refcount[cid] = Int(rc) }
        }
        // Adjacency (outgoing child-edge multiset per retained node).
        guard let edgeRows = try? readDb.query("SELECT parent, child, count FROM state_node_edges") else { return [] }
        var edges: [String: [(child: String, count: Int)]] = [:]
        for row in edgeRows {
            guard let parent = row["parent"]?.textValue,
                  let child = row["child"]?.textValue,
                  let count = row["count"]?.intValue else { continue }
            edges[parent, default: []].append((child: child, count: Int(count)))
        }
        // Retained roots (height >= floor): held by the block pin, never reclaimable
        // and never cascaded through (their closure stays alive via the pin).
        var retainedRoots: Set<String> = []
        if let rootRows = try? readDb.query(
            "SELECT cid FROM state_node_root WHERE height >= ?1", params: [.int(floorI)]
        ) {
            for row in rootRows { if let cid = row["cid"]?.textValue { retainedRoots.insert(cid) } }
        }
        // Roots of pruned heights (height < floor): the block pins released by the floor.
        guard let prunedRootRows = try? readDb.query(
            "SELECT cid FROM state_node_root WHERE height < ?1", params: [.int(floorI)]
        ) else { return [] }

        var reclaimed: Set<String> = []
        // `leave(cid)`: cid has lost its last retained reference; reclaim it (unless a
        // retained root pins it) and decrement each of its child edges, cascading.
        func leave(_ cid: String) {
            guard !reclaimed.contains(cid) else { return }
            if retainedRoots.contains(cid) { return }
            reclaimed.insert(cid)
            for edge in edges[cid] ?? [] {
                let next = (refcount[edge.child] ?? 0) - edge.count
                refcount[edge.child] = next
                if next <= 0 { leave(edge.child) }
            }
        }
        // Release each pruned height's root pin. A root has no parent edge (refcount 0
        // already), so releasing its pin makes it leave immediately and seed the cascade.
        for row in prunedRootRows {
            guard let root = row["cid"]?.textValue else { continue }
            if retainedRoots.contains(root) { continue }   // re-pinned at a retained height
            leave(root)
        }
        return Array(reclaimed)
    }

    /// SHADOW: the full universe of state-node CIDs the index currently knows — the
    /// union of every refcounted node, every edge endpoint (parent + child), and every
    /// retained/pruned post-state root. This is the comparison universe for the
    /// production verification mode (`stateRefcountVerifyAgainstReachability`): the
    /// index's reclaim verdict is checked against live-broker reachability over exactly
    /// these nodes. Pure query.
    public nonisolated func allKnownStateNodes() -> Set<String> {
        var nodes: Set<String> = []
        if let rows = try? readDb.query("SELECT cid FROM state_node_refcount") {
            for row in rows { if let cid = row["cid"]?.textValue { nodes.insert(cid) } }
        }
        if let rows = try? readDb.query("SELECT parent, child FROM state_node_edges") {
            for row in rows {
                if let p = row["parent"]?.textValue { nodes.insert(p) }
                if let c = row["child"]?.textValue { nodes.insert(c) }
            }
        }
        if let rows = try? readDb.query("SELECT cid FROM state_node_root") {
            for row in rows { if let cid = row["cid"]?.textValue { nodes.insert(cid) } }
        }
        return nodes
    }

    /// FLIP FAIL-SAFE: the set of state nodes FORWARD-reachable from the RETAINED
    /// post-state roots (height >= `floor`) over `state_node_edges`. This is an
    /// INDEPENDENT algorithm from `reclaimableStateNodes`'s refcount cascade — a
    /// forward BFS over the structural adjacency rather than a refcount-0 backward
    /// cascade. The reclamation flip cross-checks the two: the reclaim set MUST be
    /// disjoint from this retained set, otherwise the index is internally inconsistent
    /// and the safe response is to LEAK (skip reclaim), never evict a node that is
    /// structurally inside a retained version. Pure query.
    public nonisolated func retainedStateNodes(atFloor floor: UInt64) -> Set<String> {
        let floorI = Int64(floor)
        guard let rootRows = try? readDb.query(
            "SELECT cid FROM state_node_root WHERE height >= ?1", params: [.int(floorI)]
        ) else { return [] }
        var edges: [String: [String]] = [:]
        if let edgeRows = try? readDb.query("SELECT parent, child FROM state_node_edges") {
            for row in edgeRows {
                guard let p = row["parent"]?.textValue, let c = row["child"]?.textValue else { continue }
                edges[p, default: []].append(c)
            }
        }
        var reachable: Set<String> = []
        var stack: [String] = rootRows.compactMap { $0["cid"]?.textValue }
        while let cid = stack.popLast() {
            guard reachable.insert(cid).inserted else { continue }
            for child in edges[cid] ?? [] where !reachable.contains(child) { stack.append(child) }
        }
        return reachable
    }

    /// SHADOW: full live edge-refcount view (testing / audit accessor).
    public nonisolated func stateNodeRefcounts() -> [(cid: String, refcount: Int)] {
        guard let rows = try? readDb.query("SELECT cid, refcount FROM state_node_refcount") else { return [] }
        return rows.compactMap { row in
            guard let cid = row["cid"]?.textValue, let rc = row["refcount"]?.intValue else { return nil }
            return (cid: cid, refcount: Int(rc))
        }
    }

    // MARK: - Transaction History

    /// peripheral (non-canonical) write. A failure is surfaced to the
    /// caller via `throws` and logged at `.error` so the caller does not treat
    /// the index as durably written; it re-derives on the next cycle/restart.
    public func indexTransaction(address: String, txCID: String, blockHash: String, height: UInt64) throws {
        do {
            _ = try db.transaction {
                try db.execute(
                    "INSERT OR REPLACE INTO tx_history (address, txCID, blockHash, height) VALUES (?1, ?2, ?3, ?4)",
                    params: [.text(address), .text(txCID), .text(blockHash), .int(Int64(height))]
                )
            }
        } catch {
            NodeLogger("statestore").error("indexTransaction failed for \(address)/\(txCID): \(error)")
            throw error
        }
    }

    /// Remove receipt index entries and tx history rows for orphaned transaction CIDs.
    /// Called from reorg recovery before re-admitting orphaned transactions to the mempool.
    /// When a transaction is re-confirmed on the new canonical chain, fresh entries are
    /// written by the next batchIndexReceipts call, reflecting the correct block hash.
    public func deleteReceiptsForOrphanedTxCIDs(_ cids: Set<String>) throws {
        guard !cids.isEmpty else { return }
        do {
            _ = try db.transaction {
                for cid in cids {
                    try db.execute(
                        "DELETE FROM state WHERE path = ?1 OR path = ?2",
                        params: [
                            .text("general:receipt:\(cid)"),
                            .text("general:receipt-idx:\(cid)")
                        ]
                    )
                    try db.execute(
                        "DELETE FROM tx_history WHERE txCID = ?1",
                        params: [.text(cid)]
                    )
                }
            }
        } catch {
            NodeLogger("statestore").error("deleteReceiptsForOrphanedTxCIDs failed for \(cids.count) cids: \(error)")
            throw error
        }
    }

    /// Batch-write receipt index entries and tx history in a single SQLite transaction.
    /// Replaces N individual writes with 1 transaction commit.
    public func batchIndexReceipts(
        generalEntries: [(key: String, value: Data, height: UInt64)],
        txHistory: [(address: String, txCID: String, blockHash: String, height: UInt64)],
        appliedThroughHeight: UInt64? = nil
    ) throws {
        guard !generalEntries.isEmpty || !txHistory.isEmpty || appliedThroughHeight != nil else { return }
        do {
            _ = try db.transaction {
                try writeReceipts(generalEntries: generalEntries, txHistory: txHistory)
                if let appliedThroughHeight {
                    try advanceReceiptsAppliedThroughHeight(appliedThroughHeight)
                }
            }
        } catch {
            NodeLogger("statestore").error("batchIndexReceipts failed (\(generalEntries.count) general, \(txHistory.count) tx): \(error)")
            throw error
        }
    }

    private func writeReceipts(
        generalEntries: [(key: String, value: Data, height: UInt64)],
        txHistory: [(address: String, txCID: String, blockHash: String, height: UInt64)]
    ) throws {
        for entry in generalEntries {
            let path = "general:\(entry.key)"
            try db.execute(
                "INSERT OR REPLACE INTO state (path, value, height) VALUES (?1, ?2, ?3)",
                params: [.text(path), .blob(entry.value), .int(Int64(entry.height))]
            )
        }
        for entry in txHistory {
            try db.execute(
                "INSERT OR REPLACE INTO tx_history (address, txCID, blockHash, height) VALUES (?1, ?2, ?3, ?4)",
                params: [.text(entry.address), .text(entry.txCID), .text(entry.blockHash), .int(Int64(entry.height))]
            )
        }
    }

    // MARK: - Receipts-Applied-Through Marker 

    /// durable "receipts/tx_history are indexed through height H" marker.
    /// Receipts and tx_history are written in a SEPARATE transaction from the
    /// canonical tip commit (`applyBlock`/`commitCanonicalSegment`), so a crash
    /// between the tip commit at H and receipt indexing leaves a durable tip at H
    /// with no receipts for H. This marker is advanced to H in the SAME
    /// transaction that durably writes H's receipts, so it is durable IFF those
    /// receipts are. Recovery (`recoverFromCAS`) reads it and replays the gap
    /// `[marker+1 … committedTip]`, reindexing receipts/tx_history — even when the
    /// committed tip itself already matches the in-memory tip.
    ///
    /// The marker is monotone: `INSERT OR REPLACE` only raises it via `MAX`, so a
    /// replay that reindexes an already-covered height never lowers it.
    public func commitReceiptsThrough(
        height: UInt64,
        generalEntries: [(key: String, value: Data, height: UInt64)],
        txHistory: [(address: String, txCID: String, blockHash: String, height: UInt64)]
    ) throws {
        if failNextReceiptsCommit {
            failNextReceiptsCommit = false
            throw SQLiteError.executeFailed("injected receipts commit failure")
        }
        do {
            _ = try db.transaction {
                try writeReceipts(generalEntries: generalEntries, txHistory: txHistory)
                try advanceReceiptsAppliedThroughHeight(height)
            }
        } catch {
            NodeLogger("statestore").error("commitReceiptsThrough failed at \(height): \(error)")
            throw error
        }
    }

    public nonisolated func getReceiptsAppliedThrough() -> UInt64? {
        getReceiptsAppliedThroughHeight()
    }

    private func receiptsAppliedThroughLocked() -> UInt64? {
        guard let rows = try? db.query(
            "SELECT value FROM state WHERE path = ?1",
            params: [.text(Self.receiptsAppliedThroughPath)]
        ), let row = rows.first, let data = row["value"]?.blobValue,
           let str = String(data: data, encoding: .utf8) else { return nil }
        return UInt64(str)
    }

    public nonisolated func getTransactionHistory(
        address: String,
        limit: Int = 50,
        afterHeight: UInt64? = nil,
        afterTxCID: String? = nil
    ) -> [(txCID: String, blockHash: String, height: UInt64)] {
        // Total order (height DESC, txCID DESC) so the `after` cursor seeks in the
        // STORE query — slicing a fixed first window can never return page 2 (M4).
        let safeLimit = max(1, min(limit, 1000))
        let rows: [[String: SQLiteValue]]?
        // Int64(exactly:) — never trap on a cursor height above Int64.max (the route
        // already rejects those, but the store must not crash regardless).
        if let afterHeight, let afterTxCID, let afterHeightI64 = Int64(exactly: afterHeight) {
            rows = try? readDb.query(
                """
                SELECT txCID, blockHash, height FROM tx_history
                WHERE address = ?1 AND (height < ?2 OR (height = ?2 AND txCID < ?3))
                ORDER BY height DESC, txCID DESC LIMIT ?4
                """,
                params: [.text(address), .int(afterHeightI64), .text(afterTxCID), .int(Int64(safeLimit))]
            )
        } else {
            rows = try? readDb.query(
                "SELECT txCID, blockHash, height FROM tx_history WHERE address = ?1 ORDER BY height DESC, txCID DESC LIMIT ?2",
                params: [.text(address), .int(Int64(safeLimit))]
            )
        }
        guard let rows else { return [] }
        return rows.compactMap { row in
            guard let cid = row["txCID"]?.textValue,
                  let hash = row["blockHash"]?.textValue,
                  let h = row["height"]?.intValue else { return nil }
            return (txCID: cid, blockHash: hash, height: UInt64(h))
        }
    }

    public nonisolated func getReceiptsAppliedThroughHeight() -> UInt64? {
        guard let rows = try? readDb.query(
            "SELECT value FROM state WHERE path = ?1",
            params: [.text(Self.receiptsAppliedThroughPath)]
        ), let row = rows.first, let data = row["value"]?.blobValue else { return nil }
        guard let str = String(data: data, encoding: .utf8) else { return nil }
        return UInt64(str)
    }

    // MARK: - Maintenance

    /// Checkpoint WAL + reclaim free pages. Scheduled on a slow cadence from
    /// `startStorageMaintenanceLoop`. Without periodic `wal_checkpoint(TRUNCATE)`
    /// the WAL file grows during heavy write bursts; without `incremental_vacuum`
    /// the space freed by `pruneTransactionHistory` stays in the
    /// freelist and the DB file never shrinks.
    public func maintain() throws {
        do {
            try db.walCheckpointTruncate()
            try db.incrementalVacuum()
        } catch {
            NodeLogger("statestore").error("maintain failed: \(error)")
            throw error
        }
    }

    // NOTE: block_index is the durable height→hash main-chain commitment (F5-4) and is
    // never pruned for SIZE — any chain can be a PoW-root anchor for children, and a
    // child must verify a proof's root canonically even after that root's body is pruned
    // ("keep the headers, prune the bodies"). It grows with the chain (height→hash only),
    // the accepted cost of trustless deep anchoring.

    /// THE durable publish point for a canonical-chain change (F5-4). StateStore is the
    /// authoritative source of the canonical height→hash commitment (block_index) and the
    /// chain-tip marker; ChainState is its in-memory projection. Every path that changes
    /// canonical history (extend, reorg, inherited-weight reorg, sync) builds one
    /// `CanonicalSegment` and commits it here, in ONE SQLite transaction — the block_index
    /// rewrite, the below-segment invalidation, and the tip marker move together or not at
    /// all. This replaces the previously-scattered backfill / invalidate / reconcile /
    /// setChainTip writes that could split across a crash and leave the commitment stale.
    public func commitCanonicalSegment(_ segment: CanonicalSegment) throws {
        try commitCanonicalSegment(segment, blockEffects: [])
    }

    /// Commit a canonical-chain segment and the deterministic per-block indexes
    /// derived from executing that segment's transaction actions in ONE SQLite
    /// transaction. Used by sync when it has materialized bodies/actions before
    /// publishing the fork-choice result, closing the historical gap where
    /// `commitCanonicalSegment` moved the tip and receipt/tx indexes caught up
    /// later.
    public func commitCanonicalSegment(
        _ segment: CanonicalSegment,
        blockEffects: [CanonicalBlockEffects]
    ) throws {
        guard let last = segment.blocks.last, let first = segment.blocks.first else { return }
        let segmentByHeight = Dictionary(uniqueKeysWithValues: segment.blocks.map { ($0.height, $0) })
        for effect in blockEffects {
            guard let block = segmentByHeight[effect.changes.height],
                  block.hash == effect.changes.blockHash else {
                throw SQLiteError.executeFailed("canonical block effects do not match committed segment at height \(effect.changes.height)")
            }
            if let stateRoot = block.stateRoot, stateRoot != effect.changes.stateRoot {
                throw SQLiteError.executeFailed("canonical block effects state root does not match segment at height \(effect.changes.height)")
            }
        }
        _ = try db.transaction {
            try writeCanonicalSegmentCommit(segment, first: first, last: last)
            for effect in blockEffects.sorted(by: { $0.changes.height < $1.changes.height }) {
                try writeReceipts(generalEntries: effect.receiptGeneralEntries, txHistory: effect.txHistory)
                try advanceReceiptsAppliedThroughHeight(effect.changes.height)
            }
        }
    }

    private func writeCanonicalSegmentCommit(
        _ segment: CanonicalSegment,
        first: CanonicalSegmentBlock,
        last: CanonicalSegmentBlock
    ) throws {
        for b in segment.blocks {
            try db.execute(
                "INSERT OR REPLACE INTO block_index (height, blockHash) VALUES (?1, ?2)",
                params: [.int(Int64(b.height)), .text(b.hash)])
        }
        if !segment.connectsBelow && first.height > 0 {
            // A non-connecting segment abandons the history below it — drop the
            // now-unverifiable rows so isCanonicalRoot fails closed there instead
            // of binding a stale pre-recovery root.
            try db.execute("DELETE FROM block_index WHERE height < ?1",
                           params: [.int(Int64(first.height))])
        }
        try db.execute(
            "INSERT OR REPLACE INTO state (path, value, height) VALUES ('meta:chain-tip', ?1, ?2)",
            params: [.blob(Data(last.hash.utf8)), .int(Int64(last.height))])
        try db.execute(
            "INSERT OR REPLACE INTO state (path, value, height) VALUES ('meta:height', ?1, ?2)",
            params: [.blob(Data(String(last.height).utf8)), .int(Int64(last.height))])
        if let stateRoot = last.stateRoot {
            try db.execute(
                "INSERT OR REPLACE INTO state (path, value, height) VALUES ('meta:state-root', ?1, ?2)",
                params: [.blob(Data(stateRoot.utf8)), .int(Int64(last.height))])
        }
        // If no block effects were supplied, this path is being used by
        // sync/reorg code that may only know the canonical segment. Do not
        // advance receiptsAppliedThrough; recovery replays missing receipt
        // indexes from the durable block_index floor through the committed tip.
    }

    /// Drop tx_history rows below `belowHeight` for every address except
    /// `keepAddress` (the node's own address — needed for startup pin rebuild).
    /// Without this, the table grows forever on disk since every block appends
    /// one row per tx-owner and nothing ever deletes. Returns the number of rows
    /// removed so callers can log progress.
    @discardableResult
    public func pruneTransactionHistory(belowHeight: UInt64, keepAddress: String) throws -> Int {
        guard belowHeight > 0 else { return 0 }
        do {
            // P-1302: execute() returns sqlite3_changes() — no separate COUNT needed.
            return try db.transaction {
                try db.execute(
                    "DELETE FROM tx_history WHERE height < ?1 AND address != ?2",
                    params: [.int(Int64(belowHeight)), .text(keepAddress)]
                )
            }
        } catch {
            NodeLogger("statestore").error("pruneTransactionHistory failed below \(belowHeight): \(error)")
            throw error
        }
    }

    /// Return all (txCID, blockHash, height) tuples for the given address.
    /// Used at startup to rebuild account pin sets from persisted history;
    /// the height keys the windowed `account:<ns>:txwindow:<h>` pin owners.
    public nonisolated func getAllTransactionCIDs(address: String) -> [(txCID: String, blockHash: String, height: UInt64)] {
        guard let rows = try? readDb.query(
            "SELECT txCID, blockHash, height FROM tx_history WHERE address = ?1",
            params: [.text(address)]
        ) else { return [] }
        return rows.compactMap { row in
            guard let cid = row["txCID"]?.textValue,
                  let hash = row["blockHash"]?.textValue,
                  let height = row["height"]?.intValue else { return nil }
            return (txCID: cid, blockHash: hash, height: UInt64(height))
        }
    }

    // MARK: - General State

    public nonisolated func getGeneral(key: String) -> Data? {
        let path = "general:\(key)"
        guard let rows = try? readDb.query(
            "SELECT value FROM state WHERE path = ?1",
            params: [.text(path)]
        ), let row = rows.first else { return nil }
        return row["value"]?.blobValue
    }

    public func setGeneral(key: String, value: Data, atHeight: UInt64) throws {
        let path = "general:\(key)"
        do {
            _ = try db.transaction {
                try db.execute(
                    "INSERT OR REPLACE INTO state (path, value, height) VALUES (?1, ?2, ?3)",
                    params: [.text(path), .blob(value), .int(Int64(atHeight))]
                )
            }
        } catch {
            NodeLogger("statestore").error("setGeneral failed for \(key): \(error)")
            throw error
        }
    }

    public nonisolated func queryGeneralKeys(prefix: String) throws -> [(key: String, data: Data)] {
        let escaped = prefix
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let fullPrefix = "general:\(escaped)"
        let rows = try readDb.query(
            "SELECT path, value FROM state WHERE path LIKE ?1 ESCAPE '\\'",
            params: [.text(fullPrefix + "%")]
        )
        return rows.compactMap { row in
            guard let path = row["path"]?.textValue,
                  let data = row["value"]?.blobValue else { return nil }
            let key = String(path.dropFirst("general:".count))
            return (key: key, data: data)
        }
    }

    // MARK: - Chain Metadata

    public nonisolated func getChainTip() -> String? {
        guard let rows = try? readDb.query(
            "SELECT value FROM state WHERE path = 'meta:chain-tip'"
        ), let row = rows.first else { return nil }
        return row["value"]?.blobValue.flatMap { String(data: $0, encoding: .utf8) }
    }

    public nonisolated func getHeight() -> UInt64? {
        guard let rows = try? readDb.query(
            "SELECT value FROM state WHERE path = 'meta:height'"
        ), let row = rows.first, let data = row["value"]?.blobValue else { return nil }
        guard let str = String(data: data, encoding: .utf8) else { return nil }
        return UInt64(str)
    }

    // The tip marker (meta:chain-tip / meta:height / meta:state-root) is moved ONLY by
    // commitCanonicalSegment / applyBlock, together with the block_index rows in one
    // transaction — there is no standalone tip-set, so the marker and the canonical
    // commitment can never split (F5-4).

    // MARK: - Block Index

    public nonisolated func getBlockHash(atHeight height: UInt64) -> String? {
        guard let rows = try? readDb.query(
            "SELECT blockHash FROM block_index WHERE height = ?1",
            params: [.int(Int64(height))]
        ), let row = rows.first else { return nil }
        return row["blockHash"]?.textValue
    }

    public nonisolated func getBlockIndexCount() -> Int {
        guard let rows = try? readDb.query("SELECT COUNT(*) AS c FROM block_index"),
              let row = rows.first,
              let c = row["c"]?.intValue else { return 0 }
        return Int(c)
    }

    /// True IFF block_index is gap-free over [0, throughHeight].
    public nonisolated func isBlockIndexContiguous(throughHeight: UInt64) -> Bool {
        guard let rows = try? readDb.query(
            "SELECT COUNT(*) AS c, MAX(height) AS m FROM block_index"
        ), let row = rows.first,
           let count = row["c"]?.intValue,
           let maxHeight = row["m"]?.intValue else { return false }
        return UInt64(maxHeight) == throughHeight && count == Int64(throughHeight) + 1
    }

    public nonisolated func getLowestBlockIndexHeight() -> UInt64? {
        guard let rows = try? readDb.query("SELECT MIN(height) AS h FROM block_index"),
              let row = rows.first,
              let h = row["h"]?.intValue else { return nil }
        return UInt64(h)
    }

    /// Write canonical height→hash rows. INSERT OR REPLACE (not IGNORE): callers pass
    /// the in-memory canonical main chain, so a row must overwrite any stale value left
    /// by a since-abandoned fork — block_index is the durable canonical commitment and
    /// a stale row at a finalized height would bind a wrong root (F5-4).
    public func backfillBlockIndex(_ entries: [(height: UInt64, blockHash: String)]) {
        guard !entries.isEmpty else { return }
        do {
            _ = try db.transaction {
                for entry in entries {
                    try db.execute(
                        "INSERT OR REPLACE INTO block_index (height, blockHash) VALUES (?1, ?2)",
                        params: [.int(Int64(entry.height)), .text(entry.blockHash)]
                    )
                }
            }
        } catch {
            NodeLogger("statestore").error("backfillBlockIndex failed for \(entries.count) entries: \(error)")
        }
    }

    // MARK: - Block Stored Roots (Pin Lifecycle)

    public func persistStoredRoots(height: UInt64, roots: [String]) throws {
        guard !roots.isEmpty else { return }
        var counts: [String: Int] = [:]
        for root in roots { counts[root, default: 0] += 1 }
        do {
            _ = try db.transaction {
                for (root, count) in counts {
                    try db.execute(
                        "INSERT OR REPLACE INTO block_stored_roots (height, root, count) VALUES (?1, ?2, ?3)",
                        params: [.int(Int64(height)), .text(root), .int(Int64(count))]
                    )
                }
            }
        } catch {
            NodeLogger("statestore").error("persistStoredRoots failed at \(height): \(error)")
            throw error
        }
    }

    public nonisolated func getStoredRoots(height: UInt64) -> [(root: String, count: Int)] {
        guard let rows = try? readDb.query(
            "SELECT root, count FROM block_stored_roots WHERE height = ?1",
            params: [.int(Int64(height))]
        ) else { return [] }
        return rows.compactMap { row in
            guard let root = row["root"]?.textValue,
                  let count = row["count"]?.intValue else { return nil }
            return (root: root, count: Int(count))
        }
    }

    public func deleteStoredRoots(height: UInt64) throws {
        do {
            _ = try db.transaction {
                try db.execute(
                    "DELETE FROM block_stored_roots WHERE height = ?1",
                    params: [.int(Int64(height))]
                )
            }
        } catch {
            NodeLogger("statestore").error("deleteStoredRoots failed at \(height): \(error)")
            throw error
        }
    }

    // MARK: - Block Proofs (F5-4 sparse work proofs)

    /// Persist one sparse work proof path for a block. A block can have multiple
    /// verified parent/root paths; `proofID` dedupes delivery of the same path while
    /// allowing distinct paths for the same block hash.
    public func persistBlockProof(height: UInt64, blockHash: String, proofID: String, proof: Data) throws {
        do {
            _ = try db.transaction {
                try db.execute(
                    "INSERT OR IGNORE INTO block_proofs (height, blockHash, proofID, proof) VALUES (?1, ?2, ?3, ?4)",
                    params: [.int(Int64(height)), .text(blockHash), .text(proofID), .blob(proof)]
                )
            }
        } catch {
            NodeLogger("statestore").error("persistBlockProof failed for \(blockHash) at \(height): \(error)")
            throw error
        }
    }

    /// Fetch all stored sparse work proof paths by block hash (for push/serve/sync).
    public nonisolated func getBlockProofs(blockHash: String) -> [Data] {
        guard let rows = try? readDb.query(
            "SELECT proof FROM block_proofs WHERE blockHash = ?1 ORDER BY proofID ASC",
            params: [.text(blockHash)]
        ) else { return [] }
        return rows.compactMap { $0["proof"]?.blobValue }
    }

    /// True when a specific proof (identified by `proofID`, i.e. a specific committing
    /// grind) is already stored for `blockHash`. Lets the self-heal persist a proof PER
    /// committer (matching a freshly-synced node) without re-deriving already-stored ones.
    public nonisolated func blockProofIDExists(blockHash: String, proofID: String) -> Bool {
        guard let rows = try? readDb.query(
            "SELECT 1 FROM block_proofs WHERE blockHash = ?1 AND proofID = ?2 LIMIT 1",
            params: [.text(blockHash), .text(proofID)]
        ) else { return false }
        return !rows.isEmpty
    }

    public nonisolated func getAllBlockProofs() -> [(height: UInt64, blockHash: String, proofID: String, proof: Data)] {
        guard let rows = try? readDb.query(
            "SELECT height, blockHash, proofID, proof FROM block_proofs ORDER BY height ASC, blockHash ASC, proofID ASC"
        ) else { return [] }
        return rows.compactMap { row in
            guard let height = row["height"]?.intValue,
                  let blockHash = row["blockHash"]?.textValue,
                  let proofID = row["proofID"]?.textValue,
                  let proof = row["proof"]?.blobValue else { return nil }
            return (height: UInt64(height), blockHash: blockHash, proofID: proofID, proof: proof)
        }
    }

    /// Height-scoped deletion: drops every proof at `height`. Correct for tip/
    /// retention pruning, which drop a whole height once it falls below the window.
    public func deleteBlockProofs(height: UInt64) throws {
        do {
            _ = try db.transaction {
                try db.execute(
                    "DELETE FROM block_proofs WHERE height = ?1",
                    params: [.int(Int64(height))]
                )
                try db.execute(
                    "DELETE FROM inherited_work_contributions WHERE height = ?1",
                    params: [.int(Int64(height))]
                )
            }
        } catch {
            NodeLogger("statestore").error("deleteBlockProofs failed at \(height): \(error)")
            throw error
        }
    }

    /// Hash-scoped deletion: drops one block's proof. Used by historical-mode
    /// pruning to evict an orphaned fork's proof while leaving the canonical
    /// block's proof at the same height intact (the "keep every main-chain proof"
    /// invariant). `height` is carried for key locality; `blockHash` alone is
    /// unique (a block hash fixes its height via the content-addressed block).
    public func deleteBlockProof(height: UInt64, blockHash: String) throws {
        do {
            _ = try db.transaction {
                try db.execute(
                    "DELETE FROM block_proofs WHERE height = ?1 AND blockHash = ?2",
                    params: [.int(Int64(height)), .text(blockHash)]
                )
                try db.execute(
                    "DELETE FROM inherited_work_contributions WHERE height = ?1 AND blockHash = ?2",
                    params: [.int(Int64(height)), .text(blockHash)]
                )
            }
        } catch {
            NodeLogger("statestore").error("deleteBlockProof failed for \(blockHash) at \(height): \(error)")
            throw error
        }
    }

    // MARK: - Inherited Work Contributions

    /// Persist the exact verified parent/root work contributors credited to a
    /// child block. These rows are local consensus metadata: callers write them
    /// only after proof/header validation, and restore rehydrates fork choice from
    /// them so restart does not depend on replay order of duplicate parent blocks.
    public func persistInheritedWorkContributions(
        height: UInt64,
        blockHash: String,
        contributions: [(id: String, work: UInt256)]
    ) throws {
        guard !contributions.isEmpty else { return }
        do {
            _ = try db.transaction {
                for contribution in contributions where contribution.work > .zero {
                    try db.execute(
                        """
                        INSERT OR IGNORE INTO inherited_work_contributions
                        (height, blockHash, contributorID, workHex)
                        VALUES (?1, ?2, ?3, ?4)
                        """,
                        params: [
                            .int(Int64(height)),
                            .text(blockHash),
                            .text(contribution.id),
                            .text(String(contribution.work, radix: 16)),
                        ]
                    )
                }
            }
        } catch {
            NodeLogger("statestore").error("persistInheritedWorkContributions failed for \(blockHash) at \(height): \(error)")
            throw error
        }
    }

    public nonisolated func getAllInheritedWorkContributions() -> [(height: UInt64, blockHash: String, contributorID: String, work: UInt256)] {
        guard let rows = try? readDb.query(
            """
            SELECT height, blockHash, contributorID, workHex
            FROM inherited_work_contributions
            ORDER BY height ASC, blockHash ASC, contributorID ASC
            """
        ) else { return [] }
        return rows.compactMap { row in
            guard let height = row["height"]?.intValue,
                  let blockHash = row["blockHash"]?.textValue,
                  let contributorID = row["contributorID"]?.textValue,
                  let workHex = row["workHex"]?.textValue,
                  let work = UInt256(workHex, radix: 16) else { return nil }
            return (height: UInt64(height), blockHash: blockHash, contributorID: contributorID, work: work)
        }
    }

    public func deleteInheritedWorkContributions(height: UInt64) throws {
        do {
            _ = try db.transaction {
                try db.execute(
                    "DELETE FROM inherited_work_contributions WHERE height = ?1",
                    params: [.int(Int64(height))]
                )
            }
        } catch {
            NodeLogger("statestore").error("deleteInheritedWorkContributions failed at \(height): \(error)")
            throw error
        }
    }

    public func deleteInheritedWorkContributions(height: UInt64, blockHash: String) throws {
        do {
            _ = try db.transaction {
                try db.execute(
                    "DELETE FROM inherited_work_contributions WHERE height = ?1 AND blockHash = ?2",
                    params: [.int(Int64(height)), .text(blockHash)]
                )
            }
        } catch {
            NodeLogger("statestore").error("deleteInheritedWorkContributions failed for \(blockHash) at \(height): \(error)")
            throw error
        }
    }

    // MARK: - Parent State Edges + Child Anchors

    public func persistParentStateEdge(fromRoot: String, toRoot: String) throws {
        do {
            _ = try db.transaction {
                try db.execute(
                    "INSERT OR IGNORE INTO parent_state_edges (from_root, to_root) VALUES (?1, ?2)",
                    params: [.text(fromRoot), .text(toRoot)]
                )
            }
        } catch {
            NodeLogger("statestore").error("persistParentStateEdge failed \(fromRoot) -> \(toRoot): \(error)")
            throw error
        }
    }

    public nonisolated func hasParentStatePath(from startRoot: String, to targetRoot: String, maxDepth: Int = 2048) -> Bool {
        if startRoot == targetRoot { return true }
        var frontier = [startRoot]
        var seen: Set<String> = [startRoot]
        var depth = 0

        while !frontier.isEmpty && depth < maxDepth {
            depth += 1
            var next: [String] = []
            for root in frontier {
                guard let rows = try? readDb.query(
                    "SELECT to_root FROM parent_state_edges WHERE from_root = ?1",
                    params: [.text(root)]
                ) else { continue }
                for row in rows {
                    guard let toRoot = row["to_root"]?.textValue else { continue }
                    if toRoot == targetRoot { return true }
                    if seen.insert(toRoot).inserted {
                        next.append(toRoot)
                    }
                }
            }
            frontier = next
        }
        return false
    }

    public func persistParentHeader(parentHash: String, previousHash: String?, height: UInt64) throws {
        do {
            _ = try db.transaction {
                try db.execute(
                    "INSERT OR REPLACE INTO parent_headers (parent_hash, previous_hash, height) VALUES (?1, ?2, ?3)",
                    params: [.text(parentHash), previousHash.map(SQLiteValue.text) ?? .null, .int(Int64(height))]
                )
            }
        } catch {
            NodeLogger("statestore").error("persistParentHeader failed for \(parentHash) at \(height): \(error)")
            throw error
        }
    }

    public nonisolated func getParentHeader(parentHash: String) -> (previousHash: String?, height: UInt64)? {
        guard let rows = try? readDb.query(
            "SELECT previous_hash, height FROM parent_headers WHERE parent_hash = ?1",
            params: [.text(parentHash)]
        ), let row = rows.first, let height = row["height"]?.intValue else { return nil }
        return (previousHash: row["previous_hash"]?.textValue, height: UInt64(height))
    }


    /// Every PoW-verified parent block hash this node has persisted, highest height
    /// first. The proof self-heal fetches each by CID (source-agnostic) and heals the
    /// child it commits when the bytes are available — divergence is irrelevant, only
    /// data availability is.
    public nonisolated func allParentHeaderHashes(limit: Int) -> [String] {
        (try? readDb.query(
            "SELECT parent_hash FROM parent_headers ORDER BY height DESC LIMIT ?1",
            params: [.int(Int64(limit))]
        ))?.compactMap { $0["parent_hash"]?.textValue } ?? []
    }

    public func persistChildParentAnchor(childHash: String, parentHash: String, height: UInt64) throws {
        do {
            _ = try db.transaction {
                try db.execute(
                    "INSERT OR IGNORE INTO child_parent_anchors (child_hash, parent_hash, height) VALUES (?1, ?2, ?3)",
                    params: [.text(childHash), .text(parentHash), .int(Int64(height))]
                )
            }
        } catch {
            NodeLogger("statestore").error("persistChildParentAnchor failed for \(childHash) at \(height): \(error)")
            throw error
        }
    }

    public func replaceChildParentAnchor(childHash: String, parentHash: String, height: UInt64) throws {
        do {
            _ = try db.transaction {
                try db.execute(
                    "INSERT OR REPLACE INTO child_parent_anchors (child_hash, parent_hash, height) VALUES (?1, ?2, ?3)",
                    params: [.text(childHash), .text(parentHash), .int(Int64(height))]
                )
            }
        } catch {
            NodeLogger("statestore").error("replaceChildParentAnchor failed for \(childHash) at \(height): \(error)")
            throw error
        }
    }

    public nonisolated func getChildParentAnchor(childHash: String) -> String? {
        guard let rows = try? readDb.query(
            "SELECT parent_hash FROM child_parent_anchors WHERE child_hash = ?1",
            params: [.text(childHash)]
        ), let row = rows.first else { return nil }
        return row["parent_hash"]?.textValue
    }

    public nonisolated func getAllChildParentAnchors() -> [(childHash: String, parentHash: String, height: UInt64)] {
        guard let rows = try? readDb.query(
            "SELECT child_hash, parent_hash, height FROM child_parent_anchors ORDER BY height ASC, child_hash ASC"
        ) else { return [] }
        return rows.compactMap { row in
            guard let childHash = row["child_hash"]?.textValue,
                  let parentHash = row["parent_hash"]?.textValue,
                  let height = row["height"]?.intValue else { return nil }
            return (childHash: childHash, parentHash: parentHash, height: UInt64(height))
        }
    }

    // MARK: - Validator Pins (Cross-Chain Merged Mining)

    public func persistValidatorPin(height: UInt64, childCID: String, parentCID: String) throws {
        do {
            _ = try db.transaction {
                try db.execute(
                    "INSERT OR REPLACE INTO validator_pins (child_cid, parent_cid, height) VALUES (?1, ?2, ?3)",
                    params: [.text(childCID), .text(parentCID), .int(Int64(height))]
                )
            }
        } catch {
            NodeLogger("statestore").error("persistValidatorPin failed for \(childCID) at \(height): \(error)")
            throw error
        }
    }

    public nonisolated func getValidatorParent(childCID: String) -> String? {
        guard let rows = try? readDb.query(
            "SELECT parent_cid FROM validator_pins WHERE child_cid = ?1",
            params: [.text(childCID)]
        ), let row = rows.first else { return nil }
        return row["parent_cid"]?.textValue
    }

    /// Every persisted validator pin across all heights. Used by the
    /// reconciliation pass to re-derive the authoritative live set
    /// and reclaim orphaned pins left behind by a swallowed delete failure.
    public nonisolated func getAllValidatorPins() -> [(childCID: String, parentCID: String, height: UInt64)] {
        guard let rows = try? readDb.query(
            "SELECT child_cid, parent_cid, height FROM validator_pins"
        ) else { return [] }
        return rows.compactMap { row in
            guard let c = row["child_cid"]?.textValue,
                  let p = row["parent_cid"]?.textValue,
                  let h = row["height"]?.intValue else { return nil }
            return (childCID: c, parentCID: p, height: UInt64(h))
        }
    }

    public nonisolated func getValidatorPins(height: UInt64) -> [(childCID: String, parentCID: String)] {
        guard let rows = try? readDb.query(
            "SELECT child_cid, parent_cid FROM validator_pins WHERE height = ?1",
            params: [.int(Int64(height))]
        ) else { return [] }
        return rows.compactMap { row in
            guard let c = row["child_cid"]?.textValue,
                  let p = row["parent_cid"]?.textValue else { return nil }
            return (childCID: c, parentCID: p)
        }
    }

    public nonisolated func getValidatorPinHeights(throughHeight: UInt64) -> [UInt64] {
        guard let rows = try? readDb.query(
            "SELECT DISTINCT height FROM validator_pins WHERE height <= ?1 ORDER BY height ASC",
            params: [.int(Int64(throughHeight))]
        ) else { return [] }
        return rows.compactMap { row in
            guard let height = row["height"]?.intValue else { return nil }
            return UInt64(height)
        }
    }

    public func deleteValidatorPins(height: UInt64) throws {
        do {
            _ = try db.transaction {
                try db.execute(
                    "DELETE FROM validator_pins WHERE height = ?1",
                    params: [.int(Int64(height))]
                )
            }
        } catch {
            NodeLogger("statestore").error("deleteValidatorPins failed at \(height): \(error)")
            throw error
        }
    }

    // MARK: - Batch Apply (Atomic)

    @discardableResult
    public func applyBlock(_ changes: StateChangeset) -> Bool {
        applyBlock(changes, receiptGeneralEntries: [], txHistory: [])
    }

    @discardableResult
    public func applyBlock(
        _ changes: StateChangeset,
        receiptGeneralEntries: [(key: String, value: Data, height: UInt64)],
        txHistory: [(address: String, txCID: String, blockHash: String, height: UInt64)]
    ) -> Bool {
        let log = NodeLogger("statestore")
        do {
            try db.beginTransaction()
            try writeBlockCommit(changes)
            try writeReceipts(generalEntries: receiptGeneralEntries, txHistory: txHistory)
            try advanceReceiptsAppliedThroughHeight(changes.height)
            try db.commit()
            return true
        } catch {
            log.error("applyBlock failed at height \(changes.height): \(error)")
            try? db.rollbackTransaction()
            return false
        }
    }

    private func writeBlockCommit(_ changes: StateChangeset) throws {
        try db.execute(
            "INSERT OR REPLACE INTO state (path, value, height) VALUES ('meta:chain-tip', ?1, ?2)",
            params: [.blob(Data(changes.blockHash.utf8)), .int(Int64(changes.height))]
        )
        try db.execute(
            "INSERT OR REPLACE INTO state (path, value, height) VALUES ('meta:height', ?1, ?2)",
            params: [.blob(Data(String(changes.height).utf8)), .int(Int64(changes.height))]
        )
        try db.execute(
            "INSERT OR REPLACE INTO state (path, value, height) VALUES ('meta:state-root', ?1, ?2)",
            params: [.blob(Data(changes.stateRoot.utf8)), .int(Int64(changes.height))]
        )
        try db.execute(
            "INSERT OR REPLACE INTO block_index (height, blockHash) VALUES (?1, ?2)",
            params: [.int(Int64(changes.height)), .text(changes.blockHash)]
        )
    }

    /// Single monotone write path for the receipts-applied-through marker
    /// (doc above `commitReceiptsThrough` declares it monotone): the
    /// marker only ever rises. A replay/reindex at a lower height — e.g.
    /// `applyBlock` re-applying an already-covered height during recovery —
    /// must not regress it, or recovery would re-open an already-closed gap.
    /// Must run inside the caller's open transaction.
    private func advanceReceiptsAppliedThroughHeight(_ height: UInt64) throws {
        let current = receiptsAppliedThroughLocked() ?? 0
        guard height > current else { return }
        try db.execute(
            "INSERT OR REPLACE INTO state (path, value, height) VALUES (?1, ?2, ?3)",
            params: [
                .text(Self.receiptsAppliedThroughPath),
                .blob(Data(String(height).utf8)),
                .int(Int64(height))
            ]
        )
    }

    // MARK: - Canonical Transition Audit Record (Module 3, AUDIT-ONLY)

    /// Append one canonical-transition row, then prune to the most recent
    /// `keepLast` rows. AUDIT-ONLY: this log is never read to drive behavior; a
    /// caller wraps this so an append failure cannot affect the commit it audits.
    public func appendCanonicalTransition(
        oldTip: String,
        newTip: String,
        height: UInt64,
        reason: String,
        promoted: [(hash: String, height: UInt64)],
        orphaned: [String],
        keepLast: Int = 512
    ) throws {
        let encoder = JSONEncoder()
        let promotedRecords = promoted.map {
            CanonicalTransitionRecord.PromotedBlock(hash: $0.hash, height: $0.height)
        }
        let promotedJSON = String(decoding: try encoder.encode(promotedRecords), as: UTF8.self)
        let orphanedJSON = String(decoding: try encoder.encode(orphaned), as: UTF8.self)
        _ = try db.transaction {
            try db.execute(
                """
                INSERT INTO canonical_transitions
                (old_tip, new_tip, height, reason, promoted, orphaned)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                """,
                params: [
                    .text(oldTip), .text(newTip), .int(Int64(height)),
                    .text(reason), .text(promotedJSON), .text(orphanedJSON),
                ]
            )
            if keepLast > 0 {
                try db.execute(
                    """
                    DELETE FROM canonical_transitions
                    WHERE seq <= (SELECT MAX(seq) FROM canonical_transitions) - ?1
                    """,
                    params: [.int(Int64(keepLast))]
                )
            }
        }
    }

    /// AUDIT-ONLY accessor: most-recent canonical transitions, newest first.
    public nonisolated func getRecentCanonicalTransitions(limit: Int) -> [CanonicalTransitionRecord] {
        let safeLimit = max(1, min(limit, 4096))
        guard let rows = try? readDb.query(
            """
            SELECT seq, old_tip, new_tip, height, reason, promoted, orphaned
            FROM canonical_transitions ORDER BY seq DESC LIMIT ?1
            """,
            params: [.int(Int64(safeLimit))]
        ) else { return [] }
        let decoder = JSONDecoder()
        return rows.compactMap { row in
            guard let seq = row["seq"]?.intValue,
                  let oldTip = row["old_tip"]?.textValue,
                  let newTip = row["new_tip"]?.textValue,
                  let height = row["height"]?.intValue,
                  let reason = row["reason"]?.textValue,
                  let promotedText = row["promoted"]?.textValue,
                  let orphanedText = row["orphaned"]?.textValue else { return nil }
            let promoted = (try? decoder.decode(
                [CanonicalTransitionRecord.PromotedBlock].self,
                from: Data(promotedText.utf8))) ?? []
            let orphaned = (try? decoder.decode([String].self, from: Data(orphanedText.utf8))) ?? []
            return CanonicalTransitionRecord(
                seq: seq,
                oldTip: oldTip,
                newTip: newTip,
                height: UInt64(height),
                reason: reason,
                promoted: promoted,
                orphaned: orphaned
            )
        }
    }

    /// AUDIT-ONLY accessor: the single most-recent canonical transition, if any.
    public nonisolated func getLatestCanonicalTransition() -> CanonicalTransitionRecord? {
        getRecentCanonicalTransitions(limit: 1).first
    }
}
