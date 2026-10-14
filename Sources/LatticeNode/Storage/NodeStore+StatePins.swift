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
