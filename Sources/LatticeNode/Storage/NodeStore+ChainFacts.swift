import Foundation
import Lattice
import LatticeNodeCore

/// One level's durable part of a node step. `NodeStore` commits every item in
/// the enclosing array in one SQLite transaction.
struct NodeFactBatch: Sendable {
    let path: ChainPath
    let facts: [BlockImportBatch]
    var headers: [StoredHeader] = []
    var proofs: [StoredProof] = []
    let cursors: [String: StreamCursor]
    /// Keep the state diffs of the blocks these facts executed, for the
    /// state window (`state: recent`). A block fact never carries one.
    var keepsStateDiffs = false
}

extension NodeStore {
    /// Commit one whole node step across all affected levels. Content is
    /// durable before this runs; every header, proof, fact, normalized index
    /// row, and cursor for the step becomes visible atomically.
    func stageNodeFacts(_ levels: [NodeFactBatch], logID: String) throws {
        struct PreparedRow {
            let facts: [(id: Data, payload: Data)]
            let blocks: [AcceptedBlockRecord]
            let validated: [String]
            let diffs: [(block: String, height: UInt64, diff: Data)]
        }
        struct PreparedLevel {
            let path: String
            let evidence: PreparedEvidence
            let rows: [PreparedRow]
            let cursors: [String: StreamCursor]
        }

        guard Set(levels.map(\.path)).count == levels.count else {
            throw NodeStoreError.invalidConfiguration(
                "a node fact transaction contains a duplicate chain path"
            )
        }
        let prepared = try levels.map { level -> PreparedLevel in
            guard ChainAddress(level.path) != nil else {
                throw NodeStoreError.invalidConfiguration(
                    "chain path must be Nexus-rooted and consensus-valid"
                )
            }
            var rows: [PreparedRow] = []
            for batch in level.facts {
                let validated = batch.facts.compactMap { fact -> String? in
                    guard case .validation(let validation) = fact else { return nil }
                    return validation.blockHash
                }
                var diffs: [(block: String, height: UInt64, diff: Data)] = []
                let facts = try batch.facts.map { fact -> (id: Data, payload: Data) in
                    guard case .block(let block) = fact else {
                        return (try Self.encode(fact.id), try Self.encode(fact))
                    }
                    // An executed block's diff is in the batch that
                    // validates it.
                    if level.keepsStateDiffs, validated.contains(block.blockHash) {
                        diffs.append((block.blockHash, block.blockHeight, try Self.encode(block.stateDiff)))
                    }
                    return (try Self.encode(fact.id), try Self.encode(ChainFact.block(Self.withoutStateDiff(block))))
                }
                rows.append(PreparedRow(
                    facts: facts,
                    blocks: try Self.acceptedBlocks(in: batch),
                    validated: validated,
                    diffs: diffs
                ))
            }
            return PreparedLevel(
                path: level.path.joined(separator: "/"),
                evidence: try Self.prepareEvidence(
                    headers: level.headers, proofs: level.proofs, at: level.path
                ),
                rows: rows,
                cursors: level.cursors
            )
        }

        try database.transaction {
            if !prepared.isEmpty {
                try database.execute(
                    "INSERT OR IGNORE INTO core_meta (key, value) VALUES ('log_id', ?1)",
                    params: [.text(logID)]
                )
            }
            for level in prepared {
                try Self.writeEvidence(level.evidence, at: level.path, in: database)
                // Each batch that adds a fact takes the level's next seq; a
                // fact already held keeps the seq it was first staged in.
                var seq = try Self.lastSeq(at: level.path, in: database)
                for row in level.rows {
                    var added = false
                    for (ord, fact) in row.facts.enumerated() {
                        if try database.execute(
                            "INSERT INTO admission_facts (chain_path, seq, ord, fact_id, payload) VALUES (?1, ?2, ?3, ?4, ?5) ON CONFLICT (chain_path, fact_id) DO NOTHING",
                            params: [
                                .text(level.path), .int(seq + 1), .int(Int64(ord)),
                                .blob(fact.id), .blob(fact.payload),
                            ]
                        ) == 1 {
                            added = true
                            continue
                        }
                        guard let existing = try database.row(
                            ImportFactRow.self,
                            "SELECT payload FROM admission_facts WHERE chain_path = ?1 AND fact_id = ?2",
                            params: [.text(level.path), .blob(fact.id)]
                        ) else {
                            throw NodeStoreError.corrupt("an admission fact was neither stored nor held")
                        }
                        guard try existing.payload == fact.payload else {
                            throw NodeStoreError.conflictingImportFact
                        }
                    }
                    if added { seq += 1 }
                    try persistAcceptedBlockRows(
                        row.blocks,
                        at: level.path,
                        admissionSequence: max(seq, 1),
                        status: .header
                    )
                    for diff in row.diffs {
                        try database.execute(
                            "INSERT OR REPLACE INTO state_diffs (chain_path, block_cid, height, diff) VALUES (?1, ?2, ?3, ?4)",
                            params: [
                                .text(level.path), .text(diff.block),
                                .int(Int64(clamping: diff.height)), .blob(diff.diff),
                            ]
                        )
                    }
                    for cid in row.validated {
                        try database.execute(
                            "UPDATE accepted_blocks SET validated = ?1 WHERE chain_path = ?2 AND block_cid = ?3 AND validated = ?4",
                            params: [
                                BlockStatus.executed.sqlValue, .text(level.path),
                                .text(cid), BlockStatus.header.sqlValue,
                            ]
                        )
                    }
                }
                // An empty log id is an ended cursor: the peer does not run
                // this level (`StreamPage` with no log). It is a valid state.
                for (peerKey, cursor) in level.cursors.sorted(by: { $0.key < $1.key }) {
                    guard !peerKey.isEmpty,
                          let position = Int64(exactly: cursor.position) else {
                        throw NodeStoreError.invalidConfiguration(
                            "stream cursor is malformed"
                        )
                    }
                    try database.execute(
                        "INSERT INTO stream_cursors (chain_path, peer_key, log_id, position) VALUES (?1, ?2, ?3, ?4) ON CONFLICT(chain_path, peer_key) DO UPDATE SET log_id = excluded.log_id, position = excluded.position",
                        params: [
                            .text(level.path), .text(peerKey),
                            .text(cursor.logID), .int(position),
                        ]
                    )
                }
            }
        }
    }

    /// Convenience for seeding and focused store tests.
    func stageChainFacts(
        _ batches: [BlockImportBatch],
        logID: String,
        cursors: [String: StreamCursor] = [:],
        at path: ChainPath = ["Nexus"]
    ) throws {
        try stageNodeFacts([
            NodeFactBatch(
                path: path,
                facts: batches,
                cursors: cursors
            ),
        ], logID: logID)
    }

    /// The level's newest seq, 0 when it holds no fact.
    static func lastSeq(at path: String, in database: NodeSQLite) throws -> Int64 {
        try database.row(
            from: "admission_facts",
            "SELECT COALESCE(MAX(seq), 0) AS seq FROM admission_facts WHERE chain_path = ?1",
            params: [.text(path)]
        )?.int("seq") ?? 0
    }

    /// The host weigh-log id recorded with the first fact, if any.
    func chainLogID() throws -> String? {
        try database.row(
            ChainFactMetadataRow.self,
            "SELECT value FROM core_meta WHERE key = 'log_id'"
        )?.value
    }

    func chainCursors(at path: ChainPath = ["Nexus"]) throws -> [String: StreamCursor] {
        Dictionary(uniqueKeysWithValues: try database.rows(
            StreamCursorRow.self,
            "SELECT chain_path, peer_key, log_id, position FROM stream_cursors WHERE chain_path = ?1 ORDER BY peer_key",
            params: [.text(path.joined(separator: "/"))]
        ).map { row in
            (try row.peerKey, StreamCursor(
                logID: try row.logID,
                position: try row.position
            ))
        })
    }

    /// The block fact as stored: its execution's state diff is undo data,
    /// kept apart for the state window, so the fact a block's execution
    /// re-states is the one its weighing staged.
    static func withoutStateDiff(_ fact: ChainBlockFact) -> ChainBlockFact {
        guard !fact.stateDiff.isEmpty else { return fact }
        return ChainBlockFact(
            blockHash: fact.blockHash,
            parentBlockHash: fact.parentBlockHash,
            blockHeight: fact.blockHeight,
            postStateCID: fact.postStateCID,
            prevStateCID: fact.prevStateCID,
            parentStateCID: fact.parentStateCID,
            specCID: fact.specCID,
            target: fact.target,
            nextTarget: fact.nextTarget,
            timestamp: fact.timestamp,
            stateDiff: .empty,
            childCommitments: fact.childCommitments
        )
    }

    /// Every chain this store holds a fact, a cursor or a child proof of:
    /// one index seek per chain, not a pass over the rows.
    func chainPaths() throws -> Set<ChainPath> {
        var paths: Set<ChainPath> = []
        for (table, column) in [("admission_facts", "chain_path"), ("stream_cursors", "chain_path"), ("child_proofs", "chain")] {
            var last = ""
            while let chain = try database.row(
                from: table,
                "SELECT \(column) AS chain FROM \(table) WHERE \(column) > ?1 ORDER BY \(column) LIMIT 1",
                params: [.text(last)]
            )?.text("chain") {
                paths.insert(chain.split(separator: "/").map(String.init))
                last = chain
            }
        }
        return paths
    }

    /// The `core_meta` key that records the operator unhosted the chain at
    /// `path` and its release has not finished.
    static func releaseKey(_ path: String) -> String { "released:" + path }

    /// Records, in one transaction, that the operator unhosted these chains:
    /// written before anything of theirs is let go of, and deleted with
    /// each one's facts, so a release a stop or a failure cut short is
    /// finished at the next start.
    func recordReleases(_ paths: [ChainPath]) throws {
        try database.transaction {
            for path in paths {
                try database.execute(
                    "INSERT OR IGNORE INTO core_meta (key, value) VALUES (?1, '')",
                    params: [.text(Self.releaseKey(path.joined(separator: "/")))]
                )
            }
        }
    }

    /// `recordReleases` on a stopped node's store, by a CLI holding its
    /// storage lock: nothing when there is no store yet.
    static func recordRelease(of chainPath: String, storage: URL) throws {
        let path = databasePath(storage: storage)
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        let database = try NodeSQLite(path: path.path, create: false)
        try database.execute(
            "INSERT OR IGNORE INTO core_meta (key, value) VALUES (?1, '')", params: [.text(releaseKey(chainPath))]
        )
    }

    /// The chains whose release is recorded and not finished.
    func pendingReleases() throws -> [ChainPath] {
        let prefix = Self.releaseKey("")
        return try database.rows(
            from: "core_meta", "SELECT key FROM core_meta WHERE substr(key, 1, ?2) = ?1",
            params: [.text(prefix), .int(Int64(prefix.utf8.count))]
        ).map { try $0.text("key").dropFirst(prefix.count).split(separator: "/").map(String.init) }
    }

    /// The record of an unfinished release goes, and the release with it:
    /// the chain is hosted again.
    func cancelRelease(_ path: ChainPath) throws {
        try database.execute(
            "DELETE FROM core_meta WHERE key = ?1", params: [.text(Self.releaseKey(path.joined(separator: "/")))]
        )
    }

    /// Drops what this store keeps for the chain at `path`, with the record
    /// of its release, in one transaction: its facts, block index, cursors,
    /// state diffs and child proofs, and the header records and proof
    /// entries no other chain's rows name. Child indexes stay: one is
    /// shared by every block that carries no child, on any chain, and
    /// telling which one another header still names takes a pass over
    /// every header. Returns the blocks whose header records went.
    func forget(_ path: ChainPath) throws -> [String] {
        let chain = path.joined(separator: "/")
        let others = try chainPaths().map { $0.joined(separator: "/") }.filter { $0 != chain }.sorted()
        let params: [NodeSQLiteValue] = [.text(chain)] + others.map { .text($0) }
        // The chain's own blocks: those no other chain holds too.
        let own = """
            SELECT block_cid FROM accepted_blocks a WHERE a.chain_path = ?1 AND NOT EXISTS (
                SELECT 1 FROM accepted_blocks o
                WHERE o.chain_path IN (\(others.indices.map { "?\($0 + 2)" }.joined(separator: ", ")))
                  AND o.block_cid = a.block_cid
            )
            """
        return try database.transaction {
            let blocks = try database.rows(from: "accepted_blocks", own, params: params).map { try $0.text("block_cid") }
            try database.execute("DELETE FROM headers WHERE cid IN (\(own))", params: params)
            var named: Set<String> = []
            for row in try database.rows(
                from: "child_proofs", "SELECT entries FROM child_proofs WHERE chain = ?1", params: [.text(chain)]
            ) {
                named.formUnion(try row.text("entries").split(separator: " ").map(String.init))
            }
            try database.execute("DELETE FROM child_proofs WHERE chain = ?1", params: [.text(chain)])
            // A proof entry goes once no proof left names it.
            let entries = try named.filter {
                try !database.query("SELECT 1 FROM proof_entries WHERE cid = ?1", params: [.text($0)]).isEmpty
            }
            if !entries.isEmpty {
                var kept: Set<String> = []
                for row in try database.rows(from: "child_proofs", "SELECT entries FROM child_proofs") {
                    kept.formUnion(try row.text("entries").split(separator: " ").map(String.init))
                }
                for cid in entries.subtracting(kept) {
                    try database.execute("DELETE FROM proof_entries WHERE cid = ?1", params: [.text(cid)])
                }
            }
            for table in ["admission_facts", "accepted_blocks", "stream_cursors", "state_diffs"] {
                try database.execute("DELETE FROM \(table) WHERE chain_path = ?1", params: [.text(chain)])
            }
            try database.execute("DELETE FROM core_meta WHERE key = ?1", params: [.text(Self.releaseKey(chain))])
            return blocks
        }
    }
}

struct ChainFactMetadataRow: NodeStoreRecord {
    static let table = "core_meta"
    private let row: Row

    init(_ row: Row) { self.row = row }
    var value: String { get throws { try row.text("value") } }
}

struct StreamCursorRow: NodeStoreRecord {
    static let table = "stream_cursors"
    private let row: Row

    init(_ row: Row) { self.row = row }
    var peerKey: String { get throws { try row.nonEmptyText("peer_key") } }
    var logID: String { get throws { try row.text("log_id") } }
    var position: UInt64 { get throws { try row.uint64("position") } }
}
