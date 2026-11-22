import Foundation
import Lattice
import LatticeNodeCore

/// One level's durable part of a node step. `NodeStore` commits every item in
/// the enclosing array in one SQLite transaction.
struct NodeFactBatch: Sendable {
    let path: ChainPath
    let facts: [BlockImportBatch]
    /// The state diff of each block these facts executed, by block hash
    /// (`ChainTreeUpdate.stateDiff`): a block fact never carries one.
    var stateDiffs: [String: StateDiff] = [:]
    var headers: [StoredHeader] = []
    var proofs: [StoredProof] = []
    let cursors: [String: StreamCursor]
    /// Keep `stateDiffs`, for the state window (`state: recent`).
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
                    // An executed block's diff is kept with the batch that
                    // validates it.
                    if level.keepsStateDiffs, validated.contains(block.blockHash),
                       let diff = level.stateDiffs[block.blockHash] {
                        diffs.append((block.blockHash, block.blockHeight, try Self.encode(diff)))
                    }
                    return (try Self.encode(fact.id), try Self.encode(fact))
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

    /// The blocks of the chain at `path` no other chain holds too: those
    /// whose header records `forget` drops.
    func ownBlocks(_ path: ChainPath) throws -> [String] {
        let (own, params) = try ownBlocksQuery(path)
        return try database.rows(from: "accepted_blocks", own, params: params).map { try $0.text("block_cid") }
    }

    private func ownBlocksQuery(_ path: ChainPath) throws -> (String, [NodeSQLiteValue]) {
        let chain = path.joined(separator: "/")
        let others = try chainPaths().map { $0.joined(separator: "/") }.filter { $0 != chain }.sorted()
        let own = """
            SELECT block_cid FROM accepted_blocks a WHERE a.chain_path = ?1 AND NOT EXISTS (
                SELECT 1 FROM accepted_blocks o
                WHERE o.chain_path IN (\(others.indices.map { "?\($0 + 2)" }.joined(separator: ", ")))
                  AND o.block_cid = a.block_cid
            )
            """
        return (own, [.text(chain)] + others.map { .text($0) })
    }

    /// Drops what this store keeps for the chain at `path`, in one
    /// transaction: its facts, block index, cursors,
    /// state diffs and child proofs, and the header records (`ownBlocks`)
    /// and proof entries no other chain's rows name. Child indexes stay: a
    /// leaf chain's blocks carry no child, and all such blocks, on any
    /// chain, share one child index; telling which of a parent chain's
    /// another header still names takes a pass over every header. Returns
    /// how many blocks' header records went.
    func forget(_ path: ChainPath) throws -> Int {
        let chain = path.joined(separator: "/")
        let (own, params) = try ownBlocksQuery(path)
        return try database.transaction {
            let blocks = try database.execute("DELETE FROM headers WHERE cid IN (\(own))", params: params)
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
