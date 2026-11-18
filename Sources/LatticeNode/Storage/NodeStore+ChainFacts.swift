import Foundation
import Lattice
import LatticeNodeCore

/// One level's durable part of a flush. `NodeStore` commits every item in
/// the enclosing array in one SQLite transaction.
struct NodeFactBatch: Sendable {
    let path: ChainPath
    let facts: [BlockImportBatch]
    /// What executions decided (`ChainBatch.executed`): each batch re-states
    /// its block's weighed facts (`BlockImport.admissionFacts`), so only its
    /// verdict is written, and on `recent` its block's state diff.
    var executed: [BlockImportBatch] = []
    var headers: [StoredHeader] = []
    var proofs: [StoredProof] = []
    let cursors: [String: StreamCursor]
    /// Keep the state diffs of the blocks these facts executed, for the
    /// state window (`state: recent`). A block fact never carries one.
    var keepsStateDiffs = false
}

extension NodeStore {
    /// Commit a flush across all affected levels. Content is durable before
    /// this runs; every header, proof, fact, index row, and cursor of the
    /// flush becomes durable atomically. Each batch that writes a fact takes
    /// the level's next seq: the store holds the facts in the order the
    /// tree applied them.
    func stageNodeFacts(_ levels: [NodeFactBatch], logID: String) throws {
        struct PreparedRow {
            var facts: [Data] = []
            var blocks: [AcceptedBlockRecord] = []
            var validated: [String] = []
            var diffs: [(block: String, height: UInt64, diff: Data)] = []
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
                var row = PreparedRow(blocks: try Self.acceptedBlocks(in: batch))
                for fact in batch.facts {
                    if case .validation(let validation) = fact { row.validated.append(validation.blockHash) }
                    guard case .block(let block) = fact else {
                        row.facts.append(try Self.encode(fact))
                        continue
                    }
                    row.facts.append(try Self.encode(ChainFact.block(Self.withoutStateDiff(block))))
                }
                rows.append(row)
            }
            for batch in level.executed {
                var row = PreparedRow()
                for fact in batch.facts {
                    switch fact {
                    case .validation(let validation):
                        row.facts.append(try Self.encode(fact))
                        row.validated.append(validation.blockHash)
                    case .exclusion:
                        row.facts.append(try Self.encode(fact))
                    case .block, .work:
                        break
                    }
                }
                // An executed block's diff is in the batch that validates it.
                if level.keepsStateDiffs {
                    for case .block(let block) in batch.facts where row.validated.contains(block.blockHash) {
                        row.diffs.append((block.blockHash, block.blockHeight, try Self.encode(block.stateDiff)))
                    }
                }
                rows.append(row)
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
                var seq = try Self.lastSeq(at: level.path, in: database)
                for row in level.rows {
                    if !row.facts.isEmpty { seq += 1 }
                    for (ord, payload) in row.facts.enumerated() {
                        try database.execute(
                            "INSERT INTO admission_facts (chain_path, seq, ord, payload) VALUES (?1, ?2, ?3, ?4)",
                            params: [.text(level.path), .int(seq), .int(Int64(ord)), .blob(payload)]
                        )
                    }
                    try persistAcceptedBlockRows(row.blocks, at: level.path, status: .header)
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
