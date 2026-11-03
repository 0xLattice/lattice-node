import Foundation
import Lattice

/// Block facts by block, and the counts earlier versions kept of a tip's
/// state (rows of `core_meta`), which a start forgets.
extension NodeStore {
    /// The executed block's fact, which names the state it produced.
    func blockFact(_ blockCID: String, at chainPath: [String]) throws -> ChainBlockFact? {
        guard let row = try database.row(
            ImportFactRow.self,
            "SELECT chain_path, fact_id, payload FROM admission_facts WHERE chain_path = ?1 AND fact_id = ?2",
            params: [.text(chainPath.joined(separator: "/")), .blob(try Self.encode(ChainFactID.block(blockCID)))]
        ), case .block(let fact) = try Self.decode(ChainFact.self, from: try row.payload) else { return nil }
        return fact
    }

    /// Drops the counts of a tip's state earlier versions kept, and the
    /// tips they described.
    func forgetStateCounts() throws {
        _ = try database.execute(
            "DELETE FROM core_meta WHERE substr(key, 1, 10) IN ('state_pin:', 'state_tip:')"
        )
    }
}
