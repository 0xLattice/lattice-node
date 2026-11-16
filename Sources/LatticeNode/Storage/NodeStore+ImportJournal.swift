import Foundation
import Lattice
import LatticeNodeCore

/// `admission_facts`: one fact, kept once by id, with the staged batch that
/// first held it.
struct ImportFactRow: NodeStoreRecord {
    static let table = "admission_facts"
    private let row: Row

    init(_ row: Row) { self.row = row }

    var payload: Data { get throws { try row.blob("payload") } }
}

extension NodeStore {
    /// Whether any fact is stored: one row read, not the facts.
    func hasStagedImports() throws -> Bool {
        try !database.query("SELECT 1 FROM admission_facts LIMIT 1").isEmpty
    }

    /// One level's facts in the order it first took them: by seq, then by
    /// place in the batch, one primary-key range read with no sort. Each is
    /// decoded as its row is read: no other level's rows are read, and the
    /// rows are never held.
    static let levelFactsSQL =
        "SELECT seq, payload FROM admission_facts WHERE chain_path = ?1 ORDER BY seq, ord"

    func storedFacts(at chainPath: [String]) throws -> StoredFacts {
        var facts: [ChainFact] = []
        var (batches, last): (UInt64, Int64) = (0, 0)
        try database.forEach(
            Self.levelFactsSQL, params: [.text(chainPath.joined(separator: "/"))]
        ) { row in
            guard let seq = row.int(0) else {
                throw NodeStoreError.malformedRow(table: ImportFactRow.table, column: "seq")
            }
            guard let payload = row.blob(1) else {
                throw NodeStoreError.malformedRow(table: ImportFactRow.table, column: "payload")
            }
            if seq != last { (batches, last) = (batches + 1, seq) }
            facts.append(try Self.decode(ChainFact.self, from: payload))
        }
        return StoredFacts(facts: facts, batches: batches)
    }
}
