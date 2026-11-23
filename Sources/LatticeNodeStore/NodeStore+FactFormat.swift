import Foundation
import Lattice

/// The encoding of the facts `admission_facts` holds, recorded in `core_meta`
/// as `fact_format`.
///
/// Format 2: a block fact carries no state diff (Lattice dropped
/// `ChainBlockFact.stateDiff`; the diff is an execution output, kept in
/// `state_diffs`). A store from before records no format, and each of its
/// block facts encodes an empty `"stateDiff"`. It still decodes (the key is
/// ignored), but staging dedups a fact by its stored bytes, so a block fact
/// staged again would no longer match its own row and be refused as a
/// conflict. Such a store is migrated once, when it opens.
extension NodeStore {
    package static let currentFactFormat = "2"

    /// Owner: `createSchema` — a fresh store is in the current format.
    package static func recordFactFormat(in database: NodeSQLite) throws {
        try database.execute(
            "INSERT OR REPLACE INTO core_meta (key, value) VALUES ('fact_format', ?1)",
            params: [.text(currentFactFormat)]
        )
    }

    /// Owner: NodeStore.init, on an existing store. Re-encodes every stored
    /// block fact with the current type, in one transaction with the format
    /// it records: a crash leaves the store as it was, and the next open
    /// runs it again. A format this node does not know is refused.
    package static func migrateFactFormat(in database: NodeSQLite) throws {
        let recorded = try database.row(
            ChainFactMetadataRow.self,
            "SELECT value FROM core_meta WHERE key = 'fact_format'"
        )?.value
        if recorded == currentFactFormat { return }
        guard recorded == nil else {
            throw NodeStoreError.wipeRequired("unknown fact format \(recorded ?? "")")
        }
        let page = 512
        let blockPrefix = Data(#"{"block":"#.utf8)
        try database.transaction {
            // By primary key, a page at a time: no more than a page of rows
            // is held, and a page is read whole before any of it is written.
            var after: (path: String, seq: Int64, ord: Int64)?
            while true {
                let rows: [Row]
                if let after {
                    rows = try database.rows(
                        from: ImportFactRow.table,
                        "SELECT chain_path, seq, ord, payload FROM admission_facts WHERE (chain_path, seq, ord) > (?1, ?2, ?3) ORDER BY chain_path, seq, ord LIMIT ?4",
                        params: [.text(after.path), .int(after.seq), .int(after.ord), .int(Int64(page))]
                    )
                } else {
                    rows = try database.rows(
                        from: ImportFactRow.table,
                        "SELECT chain_path, seq, ord, payload FROM admission_facts ORDER BY chain_path, seq, ord LIMIT ?1",
                        params: [.int(Int64(page))]
                    )
                }
                for row in rows {
                    let path = try row.text("chain_path")
                    let seq = try row.int("seq")
                    let ord = try row.int("ord")
                    let payload = try row.blob("payload")
                    after = (path, seq, ord)
                    guard payload.starts(with: blockPrefix) else { continue }
                    let fact = try decode(ChainFact.self, from: payload)
                    guard case .block = fact else { continue }
                    let current = try encode(fact)
                    guard current != payload else { continue }
                    try database.execute(
                        "UPDATE admission_facts SET payload = ?1 WHERE chain_path = ?2 AND seq = ?3 AND ord = ?4",
                        params: [.blob(current), .text(path), .int(seq), .int(ord)]
                    )
                }
                if rows.count < page { break }
            }
            try recordFactFormat(in: database)
        }
    }
}
