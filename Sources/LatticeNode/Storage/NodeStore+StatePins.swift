import Foundation
import Lattice

/// The counts earlier versions kept of a tip's state (rows of
/// `core_meta`), which a start forgets.
extension NodeStore {
    /// Drops the counts of a tip's state earlier versions kept, and the
    /// tips they described.
    func forgetStateCounts() throws {
        _ = try database.execute(
            "DELETE FROM core_meta WHERE substr(key, 1, 10) IN ('state_pin:', 'state_tip:')"
        )
    }
}
