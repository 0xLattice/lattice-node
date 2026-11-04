import Foundation
import Lattice

/// The whole current state of each chain on `recent`: how many places in
/// it each node holds, and the block whose state that is. A node is named
/// by its content, so it can sit in several places, and it leaves the
/// state when the last of them does. The counts are rows of `core_meta`
/// (`state_count:<chain>:<cid>`), the block is `state_cursor:<chain>`, its
/// height and CID. Also the counts earlier versions kept of a tip's state,
/// which a start forgets.
extension NodeStore {
    /// The executed block's fact, which names the state it produced and
    /// how its execution changed the places of the state's nodes.
    func blockFact(_ blockCID: String, at chainPath: [String]) throws -> ChainBlockFact? {
        guard let row = try database.row(
            ImportFactRow.self,
            "SELECT chain_path, fact_id, payload FROM admission_facts WHERE chain_path = ?1 AND fact_id = ?2",
            params: [.text(chainPath.joined(separator: "/")), .blob(try Self.encode(ChainFactID.block(blockCID)))]
        ), case .block(let fact) = try Self.decode(ChainFact.self, from: try row.payload) else { return nil }
        return fact
    }

    private static let countPrefix = "state_count:"
    private static let cursorPrefix = "state_cursor:"

    private static func countKey(_ cid: String, at chainPath: [String]) -> String {
        countPrefix + chainPath.joined(separator: "/") + ":" + cid
    }

    private static func cursorKey(at chainPath: [String]) -> String {
        cursorPrefix + chainPath.joined(separator: "/")
    }

    /// The block whose state the chain's counts describe: nil before a
    /// state sync of it completed.
    func currentStateCursor(at chainPath: [String]) throws -> (height: UInt64, block: String)? {
        guard let value = try database.row(
            ChainFactMetadataRow.self, "SELECT value FROM core_meta WHERE key = ?1",
            params: [.text(Self.cursorKey(at: chainPath))]
        )?.value else { return nil }
        let parts = value.split(separator: " ")
        guard parts.count == 2, let height = UInt64(parts[0]) else { return nil }
        return (height, String(parts[1]))
    }

    /// How many places each of `cids` holds in the chain's current state.
    func currentStateCounts(_ cids: [String], at chainPath: [String]) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for cid in cids {
            counts[cid] = try database.row(
                ChainFactMetadataRow.self, "SELECT value FROM core_meta WHERE key = ?1",
                params: [.text(Self.countKey(cid, at: chainPath))]
            ).flatMap { Int(try $0.value) } ?? 0
        }
        return counts
    }

    /// Sets the counts `counts` names (a count of 0 drops its row) and the
    /// block they now describe, in one transaction. With `replacing`, every
    /// other count of the chain goes first.
    func writeCurrentState(
        at chainPath: [String], counts: [String: Int], cursor: (height: UInt64, block: String), replacing: Bool = false
    ) throws {
        try database.transaction {
            if replacing { try deleteRows(after: Self.countPrefix + chainPath.joined(separator: "/") + ":") }
            for (cid, count) in counts {
                let key = Self.countKey(cid, at: chainPath)
                if count > 0 {
                    _ = try database.execute(
                        "INSERT OR REPLACE INTO core_meta (key, value) VALUES (?1, ?2)",
                        params: [.text(key), .text(String(count))]
                    )
                } else {
                    _ = try database.execute("DELETE FROM core_meta WHERE key = ?1", params: [.text(key)])
                }
            }
            _ = try database.execute(
                "INSERT OR REPLACE INTO core_meta (key, value) VALUES (?1, ?2)",
                params: [.text(Self.cursorKey(at: chainPath)), .text("\(cursor.height) \(cursor.block)")]
            )
        }
    }

    /// Drops the counts and the block of the chain at `chainPath`, or of
    /// every chain when it is nil.
    func forgetCurrentState(at chainPath: [String]?) throws {
        try database.transaction {
            if let chainPath {
                try deleteRows(after: Self.countPrefix + chainPath.joined(separator: "/") + ":")
                _ = try database.execute(
                    "DELETE FROM core_meta WHERE key = ?1", params: [.text(Self.cursorKey(at: chainPath))]
                )
            } else {
                try deleteRows(after: Self.countPrefix)
                try deleteRows(after: Self.cursorPrefix)
            }
        }
    }

    /// Deletes every `core_meta` row whose key starts with `prefix`, which
    /// ends with a colon: the keys from it up to the next character.
    private func deleteRows(after prefix: String) throws {
        _ = try database.execute(
            "DELETE FROM core_meta WHERE key >= ?1 AND key < ?2",
            params: [.text(prefix), .text(String(prefix.dropLast()) + ";")]
        )
    }

    /// Drops the counts of a tip's state earlier versions kept, and the
    /// tips they described.
    func forgetStateCounts() throws {
        _ = try database.execute(
            "DELETE FROM core_meta WHERE substr(key, 1, 10) IN ('state_pin:', 'state_tip:')"
        )
    }
}
