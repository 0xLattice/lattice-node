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
                var validated: [String] = []
                let facts = try batch.facts.map { fact -> (id: Data, payload: Data) in
                    if case .validation(let validation) = fact {
                        validated.append(validation.blockHash)
                    }
                    return (try Self.encode(fact.id), try Self.encode(fact))
                }
                rows.append(PreparedRow(
                    facts: facts,
                    blocks: try Self.acceptedBlocks(in: batch),
                    validated: validated
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
                        guard try existing.payload != fact.payload else { continue }
                        guard try Self.restatesWeighedBlock(existing.payload, as: fact.payload) else {
                            throw NodeStoreError.conflictingImportFact
                        }
                        // The executed block's fact, in its place: the
                        // seq it was first staged in stays.
                        try database.execute(
                            "UPDATE admission_facts SET payload = ?3 WHERE chain_path = ?1 AND fact_id = ?2",
                            params: [.text(level.path), .blob(fact.id), .blob(fact.payload)]
                        )
                    }
                    if added { seq += 1 }
                    try persistAcceptedBlockRows(
                        row.blocks,
                        at: level.path,
                        admissionSequence: max(seq, 1),
                        status: .header
                    )
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

    /// A block's execution re-states its block fact with the state diff it
    /// produced. Only that change is a re-statement.
    static func restatesWeighedBlock(_ existing: Data, as new: Data) throws -> Bool {
        guard case .block(let weighed) = try decode(ChainFact.self, from: existing),
              case .block(let executed) = try decode(ChainFact.self, from: new),
              weighed.stateDiff.isEmpty else { return false }
        return weighed == ChainBlockFact(
            blockHash: executed.blockHash,
            parentBlockHash: executed.parentBlockHash,
            blockHeight: executed.blockHeight,
            postStateCID: executed.postStateCID,
            prevStateCID: executed.prevStateCID,
            parentStateCID: executed.parentStateCID,
            specCID: executed.specCID,
            target: executed.target,
            nextTarget: executed.nextTarget,
            timestamp: executed.timestamp,
            stateDiff: .empty,
            childCommitments: executed.childCommitments
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
