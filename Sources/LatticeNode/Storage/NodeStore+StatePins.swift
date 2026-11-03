import Foundation
import Lattice

/// The state a chain's tip is made of, when the operator keeps no other:
/// how many nodes of that state name each node. A node is named by its own
/// content, so one can sit in several places, and it leaves the state when
/// the last of them does. The counts are rows of `core_meta`, keyed by
/// chain and node.
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

    static func stateCountKey(_ cid: String, at chainPath: [String]) -> String {
        "state_pin:" + chainPath.joined(separator: "/") + ":" + cid
    }

    func stateCount(_ cid: String, at chainPath: [String]) throws -> Int {
        try database.row(
            ChainFactMetadataRow.self, "SELECT value FROM core_meta WHERE key = ?1",
            params: [.text(Self.stateCountKey(cid, at: chainPath))]
        ).flatMap { Int(try $0.value) } ?? 0
    }

    /// The block whose state the counts describe; nil before the first.
    func stateTip(at chainPath: [String]) throws -> String? {
        try database.row(
            ChainFactMetadataRow.self, "SELECT value FROM core_meta WHERE key = ?1",
            params: [.text("state_tip:" + chainPath.joined(separator: "/"))]
        )?.value
    }

    /// Drops every chain's counts and the tips they describe.
    func forgetStateCounts() throws {
        _ = try database.execute(
            "DELETE FROM core_meta WHERE substr(key, 1, 10) IN ('state_pin:', 'state_tip:')"
        )
    }

    /// Drops the counts of the chain at `chainPath` and the tip they
    /// describe, so the next move counts its state afresh.
    func forgetStateCounts(at chainPath: [String]) throws {
        let path: String = chainPath.joined(separator: "/")
        let pins: String = "state_pin:" + path + ":"
        let tip: String = "state_tip:" + path
        let length = Int64(pins.utf8.count)
        _ = try database.execute(
            "DELETE FROM core_meta WHERE substr(key, 1, ?2) = ?1 OR key = ?3",
            params: [.text(pins), .int(length), .text(tip)]
        )
    }

    /// Whether the last count of the chain at `chainPath` found nodes of
    /// its state this store lacks: a start counts that state afresh, so the
    /// gaps are found and filled again.
    func stateHasGaps(at chainPath: [String]) throws -> Bool {
        try database.row(
            ChainFactMetadataRow.self, "SELECT value FROM core_meta WHERE key = ?1",
            params: [.text("state_gaps:" + chainPath.joined(separator: "/"))]
        ) != nil
    }

    func setStateHasGaps(_ gaps: Bool, at chainPath: [String]) throws {
        let key: String = "state_gaps:" + chainPath.joined(separator: "/")
        if gaps {
            _ = try database.execute(
                "INSERT OR REPLACE INTO core_meta (key, value) VALUES (?1, ?2)", params: [.text(key), .text("1")]
            )
        } else {
            _ = try database.execute("DELETE FROM core_meta WHERE key = ?1", params: [.text(key)])
        }
    }

    /// Whether this store's kept state was counted afresh since gaps were
    /// first found and filled: runs before that may have lost nodes of it
    /// without noting them.
    func stateGapsChecked() throws -> Bool {
        try database.row(
            ChainFactMetadataRow.self, "SELECT value FROM core_meta WHERE key = ?1",
            params: [.text("state_gaps_checked")]
        ) != nil
    }

    /// As a store from before gaps were noted: its next start on `tip`
    /// counts every level afresh.
    func forgetStateGapsChecked() throws {
        _ = try database.execute("DELETE FROM core_meta WHERE key = 'state_gaps_checked'", params: [])
    }

    func setStateGapsChecked() throws {
        _ = try database.execute(
            "INSERT OR REPLACE INTO core_meta (key, value) VALUES ('state_gaps_checked', '1')", params: []
        )
    }

    /// Moves the counts by `changes` and to `tip`, in one transaction.
    /// Returns the nodes that entered the state and the ones that left it.
    func moveStateCounts(
        at chainPath: [String], to tip: String, changes: [String: Int]
    ) throws -> (entered: [String], left: [String]) {
        let path = chainPath.joined(separator: "/")
        return try database.transaction {
            var (entered, left): ([String], [String]) = ([], [])
            for (cid, change) in changes where change != 0 {
                let key = Self.stateCountKey(cid, at: chainPath)
                let held = try database.row(
                    ChainFactMetadataRow.self, "SELECT value FROM core_meta WHERE key = ?1", params: [.text(key)]
                ).flatMap { Int(try $0.value) } ?? 0
                let count = max(0, held + change)
                if count > 0 {
                    _ = try database.execute(
                        "INSERT OR REPLACE INTO core_meta (key, value) VALUES (?1, ?2)",
                        params: [.text(key), .text(String(count))]
                    )
                    if held == 0 { entered.append(cid) }
                } else {
                    _ = try database.execute("DELETE FROM core_meta WHERE key = ?1", params: [.text(key)])
                    left.append(cid)
                }
            }
            _ = try database.execute(
                "INSERT OR REPLACE INTO core_meta (key, value) VALUES (?1, ?2)",
                params: [.text("state_tip:" + path), .text(tip)]
            )
            return (entered, left)
        }
    }
}
