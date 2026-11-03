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

    /// Drops every chain's counts, the tips they describe, and the marks
    /// that they were counted whole: a later run on `tip` heals each chain.
    func forgetStateCounts() throws {
        _ = try database.execute(
            "DELETE FROM core_meta WHERE substr(key, 1, 10) IN ('state_pin:', 'state_tip:', 'state_chk:')"
        )
    }

    /// Whether the counts of the chain at `chainPath` describe a state this
    /// store holds whole: set when a count afresh found nothing missing,
    /// cleared when a move finds a node missing. A start heals a chain
    /// without it.
    func stateWhole(at chainPath: [String]) throws -> Bool {
        try database.row(
            ChainFactMetadataRow.self, "SELECT value FROM core_meta WHERE key = ?1",
            params: [.text("state_chk:" + chainPath.joined(separator: "/"))]
        ) != nil
    }

    func setStateWhole(_ whole: Bool, at chainPath: [String]) throws {
        let key = "state_chk:" + chainPath.joined(separator: "/")
        if whole {
            _ = try database.execute(
                "INSERT OR REPLACE INTO core_meta (key, value) VALUES (?1, '1')", params: [.text(key)]
            )
        } else {
            _ = try database.execute("DELETE FROM core_meta WHERE key = ?1", params: [.text(key)])
        }
    }

    /// Moves the counts by `changes` and to `tip`, in one transaction; a
    /// count `afresh` replaces the chain's counts with `changes` in it.
    /// Returns the nodes that entered the state and the ones that left it.
    func moveStateCounts(
        at chainPath: [String], to tip: String, changes: [String: Int], afresh: Bool = false
    ) throws -> (entered: [String], left: [String]) {
        let path = chainPath.joined(separator: "/")
        return try database.transaction {
            if afresh {
                let pins = "state_pin:" + path + ":"
                _ = try database.execute(
                    "DELETE FROM core_meta WHERE substr(key, 1, ?2) = ?1",
                    params: [.text(pins), .int(Int64(pins.utf8.count))]
                )
            }
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
