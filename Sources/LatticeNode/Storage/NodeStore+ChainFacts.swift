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
    /// The state these facts' executions produced is in the state buffer,
    /// not the store: the level's flush marker stays where it is until a
    /// flush moves it (`markFlushed`). False, the states were stored before
    /// this transaction, and the marker moves with the facts.
    var buffersState = false
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
            let buffersState: Bool
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
                cursors: level.cursors,
                buffersState: level.buffersState
            )
        }

        // Each level's seq as this transaction leaves it: added to the
        // log's newest seqs once it committed.
        var newest = try lastSeqs()
        var reached: [String: Int64] = [:]
        try database.transaction {
            if !prepared.isEmpty {
                try database.execute(
                    "INSERT OR IGNORE INTO core_meta (key, value) VALUES ('log_id', ?1)",
                    params: [.text(logID)]
                )
                // A log recorded whole in this transaction has lost nothing:
                // a store seeded before its first run starts clean.
                try database.execute(
                    "INSERT OR IGNORE INTO core_meta (key, value) VALUES ('clean_stop', '1')"
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
                reached[level.path] = seq
                // The step's states were stored before this transaction:
                // the level's marker moves with its facts.
                if !level.buffersState { try Self.markFlushed(seq, at: level.path, in: database) }
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
        newest.merge(reached) { max($0, $1) }
        newestSeqs = newest
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

    // MARK: - The executions whose state is stored

    /// The key of a level's flush marker: the seq up to which every
    /// execution's state is in the content store.
    static func flushedKey(_ path: String) -> String { "flushed:" + path }

    static func flushed(at path: String, in database: NodeSQLite) throws -> Int64? {
        guard case .text(let value)? = try database.query(
            "SELECT value FROM core_meta WHERE key = ?1", params: [.text(flushedKey(path))]
        ).first?["value"] else { return nil }
        return Int64(value)
    }

    /// Raises a level's marker to `seq`, never lowers it.
    static func markFlushed(_ seq: Int64, at path: String, in database: NodeSQLite) throws {
        guard seq > (try flushed(at: path, in: database) ?? -1) else { return }
        try database.execute(
            "INSERT OR REPLACE INTO core_meta (key, value) VALUES (?1, ?2)",
            params: [.text(flushedKey(path)), .text(String(seq))]
        )
    }

    /// Every level's newest seq. Held in memory once read: the one scan of
    /// the facts log is the first call's, and each transaction that adds
    /// facts keeps it current (`stageNodeFacts`), so a flush reads no log.
    func lastSeqs() throws -> [String: Int64] {
        if let newestSeqs { return newestSeqs }
        var seqs: [String: Int64] = [:]
        for row in try database.query("SELECT chain_path, MAX(seq) AS seq FROM admission_facts GROUP BY chain_path") {
            guard case .text(let path)? = row["chain_path"], case .int(let seq)? = row["seq"] else {
                throw NodeStoreError.corrupt("a level's newest seq does not read")
            }
            seqs[path] = seq
        }
        newestSeqs = seqs
        return seqs
    }

    /// The content store holds the state of every block executed in a batch
    /// up to these seqs: each level's marker moves there. Written after the
    /// states are, so a crash between the two leaves a marker behind the
    /// state, never ahead of it.
    func markFlushed(_ seqs: [String: Int64]) throws {
        guard !seqs.isEmpty else { return }
        try database.transaction {
            for (path, seq) in seqs { try Self.markFlushed(seq, at: path, in: database) }
        }
    }

    /// At a start: a block executed above its level's marker is one whose
    /// state the content store may not hold, so it counts as not executed.
    /// Its validation goes, its block is a header again, and the node
    /// executes it as it executes any block, from the state below it; a
    /// block whose state was stored after all produces the same state.
    /// Returns how many executions were forgotten: none after a clean stop,
    /// which flushes.
    ///
    /// A store no start has marked (one an older version wrote) stored
    /// every state before the facts that name it: its markers start at its
    /// newest seqs.
    func forgetUnflushedExecutions() throws -> Int {
        // What goes may have been a level's newest: read again when asked.
        defer { newestSeqs = nil }
        return try database.transaction {
            let seqs = try lastSeqs()
            guard try !database.query("SELECT 1 AS one FROM core_meta WHERE key = 'flush_markers'").isEmpty else {
                for (path, seq) in seqs { try Self.markFlushed(seq, at: path, in: database) }
                try database.execute("INSERT INTO core_meta (key, value) VALUES ('flush_markers', '1')")
                return 0
            }
            var forgotten = 0
            for (path, last) in seqs.sorted(by: { $0.key < $1.key }) {
                let marker = try Self.flushed(at: path, in: database) ?? 0
                guard last > marker else { continue }
                for row in try database.query(
                    "SELECT fact_id, payload FROM admission_facts WHERE chain_path = ?1 AND seq > ?2 ORDER BY seq, ord",
                    params: [.text(path), .int(marker)]
                ) {
                    guard case .blob(let id)? = row["fact_id"], case .blob(let payload)? = row["payload"] else {
                        throw NodeStoreError.corrupt("an admission fact above the flush marker does not read")
                    }
                    guard case .validation(let validation) = try Self.decode(ChainFact.self, from: payload) else { continue }
                    try database.execute(
                        "DELETE FROM admission_facts WHERE chain_path = ?1 AND fact_id = ?2",
                        params: [.text(path), .blob(id)]
                    )
                    try database.execute(
                        "UPDATE accepted_blocks SET validated = ?1 WHERE chain_path = ?2 AND block_cid = ?3 AND validated = ?4",
                        params: [
                            BlockStatus.header.sqlValue, .text(path),
                            .text(validation.blockHash), BlockStatus.executed.sqlValue,
                        ]
                    )
                    try database.execute(
                        "DELETE FROM state_diffs WHERE chain_path = ?1 AND block_cid = ?2",
                        params: [.text(path), .text(validation.blockHash)]
                    )
                    forgotten += 1
                }
            }
            return forgotten
        }
    }

    /// The host weigh-log id recorded with the first fact, if any.
    func chainLogID() throws -> String? {
        try database.row(
            ChainFactMetadataRow.self,
            "SELECT value FROM core_meta WHERE key = 'log_id'"
        )?.value
    }

    /// The weigh log id of the run that is starting, and whether it replaces
    /// the stored one. Called once, at boot, before anything is journaled.
    ///
    /// A peer keeps a cursor into this node's log as (id, position). A run
    /// that did not stop cleanly may have lost the log's tail, and entries
    /// appended since would sit at positions a peer has already passed: it
    /// would skip them, or ask past the log's end for good. So unless the
    /// last run marked a clean stop, the log continues under a new id, which
    /// every peer answers by reading it again from its start (a duplicate
    /// costs one id). A store that has journaled nothing has no id to
    /// replace: `fresh` is recorded with its first fact. A store written
    /// before this mark existed counts as not stopped cleanly, once.
    ///
    /// Clearing the mark is durable before this returns, whatever the store's
    /// sync level: if it were lost with a tail the run journaled after it, the
    /// next start would keep the id over a shortened log.
    func openWeighLog(fresh: String) throws -> (id: String, replaced: Bool) {
        // FULL fsyncs this commit's WAL frames whether or not a reader holds
        // the WAL, unlike a checkpoint, which a reader can leave undone.
        let level = try database.query("PRAGMA synchronous").first?["synchronous"]
        try database.execute("PRAGMA synchronous=FULL")
        defer {
            if case .int(let previous)? = level { _ = try? database.execute("PRAGMA synchronous=\(previous)") }
        }
        return try database.transaction {
            let stored = try chainLogID()
            let clean = try markedClean()
            try database.execute("INSERT OR REPLACE INTO core_meta (key, value) VALUES ('clean_stop', '0')")
            guard stored != nil, !clean else { return (stored ?? fresh, false) }
            try database.execute("UPDATE core_meta SET value = ?1 WHERE key = 'log_id'", params: [.text(fresh)])
            return (fresh, true)
        }
    }

    /// Whether the last run marked a clean stop.
    func markedClean() throws -> Bool {
        try database.row(
            ChainFactMetadataRow.self,
            "SELECT value FROM core_meta WHERE key = 'clean_stop'"
        )?.value == "1"
    }

    /// The run stopped with everything it journaled written: the next start
    /// keeps the log's id (`openWeighLog`). Called after the last write is
    /// durable, and written directly, never through a buffer.
    func markCleanStop() throws {
        try database.execute("INSERT OR REPLACE INTO core_meta (key, value) VALUES ('clean_stop', '1')")
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
