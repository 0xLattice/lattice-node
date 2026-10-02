import Foundation
import Lattice

extension NodeStore {
    /// The facts of one core step, in ONE transaction: every batch's
    /// admission row and normalized facts, its accepted-block rows, and the
    /// executed tier of each validated block. The content those facts
    /// reference (`volumeRoots`) is stored and retained before this runs. A
    /// batch already journaled is a replay and adds nothing.
    /// The weigh log id is recorded in the same transaction as the first
    /// fact, so a store with facts always names the log they imply.
    func stageCoreFacts(_ batches: [BlockImportBatch], volumeRoots: [String], logID: String) throws {
        let rootsPayload = try Self.encode(Array(Set(volumeRoots)).sorted())
        var rows: [(payload: Data, facts: [(id: Data, payload: Data)], blocks: [AcceptedBlockRecord], validated: [String])] = []
        for batch in batches {
            var validated: [String] = []
            let facts = try batch.facts.map { fact -> (id: Data, payload: Data) in
                if case .validation(let validation) = fact { validated.append(validation.blockHash) }
                return (try Self.encode(fact.id), try Self.encode(fact))
            }
            rows.append((try Self.encode(batch), facts, try Self.acceptedBlocks(in: batch), validated))
        }
        try database.transaction {
            if !rows.isEmpty {
                try database.execute(
                    "INSERT OR IGNORE INTO core_meta (key, value) VALUES ('log_id', ?1)", params: [.text(logID)]
                )
            }
            for row in rows {
                if try database.row(
                    ImportBatchRow.self,
                    "SELECT seq FROM admission_batches WHERE payload = ?1",
                    params: [.blob(row.payload)]
                ) != nil { continue }
                for fact in row.facts {
                    if let existing = try database.row(
                        ImportFactRow.self,
                        "SELECT payload FROM admission_facts WHERE fact_id = ?1",
                        params: [.blob(fact.id)]
                    ), try existing.payload != fact.payload {
                        throw NodeStoreError.conflictingImportFact
                    }
                }
                try database.execute(
                    "INSERT INTO admission_batches (payload, volume_roots) VALUES (?1, ?2)",
                    params: [.blob(row.payload), .blob(rootsPayload)]
                )
                guard let sequence = try database.row(
                    ImportBatchRow.self,
                    "SELECT seq FROM admission_batches WHERE payload = ?1",
                    params: [.blob(row.payload)]
                )?.sequence else {
                    throw NodeStoreError.corrupt("missing newly staged admission batch")
                }
                for fact in row.facts {
                    try database.execute(
                        "INSERT OR IGNORE INTO admission_facts (fact_id, payload) VALUES (?1, ?2)",
                        params: [.blob(fact.id), .blob(fact.payload)]
                    )
                }
                try persistAcceptedBlockRows(row.blocks, admissionSequence: sequence, status: .header)
                for cid in row.validated {
                    try database.execute(
                        "UPDATE accepted_blocks SET validated = ?1 WHERE block_cid = ?2 AND validated = ?3",
                        params: [BlockStatus.executed.sqlValue, .text(cid), BlockStatus.header.sqlValue]
                    )
                }
            }
        }
    }

    /// The weigh log id recorded with the first core fact, if any.
    func coreLogID() throws -> String? {
        return try database.row(CoreMetaRow.self, "SELECT value FROM core_meta WHERE key = 'log_id'")?.value
    }
}

/// `core_meta`: one value by key (the weigh log id).
struct CoreMetaRow: NodeStoreRecord {
    static let table = "core_meta"
    private let row: Row

    init(_ row: Row) { self.row = row }

    var value: String { get throws { try row.text("value") } }
}
