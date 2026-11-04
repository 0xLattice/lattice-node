import Foundation
import Lattice

/// What the counts of a chain's current state, on `recent`, are moved by:
/// the facts of its executed blocks, each naming its parent, its height
/// and how its execution changed the places of the state's nodes. Also
/// the counts earlier versions kept (rows of `core_meta`), which a start
/// forgets.
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

    /// The change that moves a chain's counts from `marker` to `tip`, an
    /// act-on block, with the cursor raised to a window below the tip when
    /// that is higher: what the blocks entering the act-on chain created,
    /// less what the blocks leaving it created, less what the blocks the
    /// cursor passes replaced. Nil when the counts cannot follow: a fact is
    /// missing, or the cursor's block is not on the tip's chain (the tip is
    /// below it, or forked from below it). Every block above the cursor on
    /// the tip's chain is read: a window of them once the cursor moves with
    /// the tip.
    func countedChange(
        at chainPath: [String], from marker: CountedMarker, to tip: String, window: UInt64
    ) throws -> (deltas: [String: Int], marker: CountedMarker)? {
        // The tip's chain above the cursor, by height.
        var chain: [UInt64: ChainBlockFact] = [:]
        guard var fact = try blockFact(tip, at: chainPath) else { return nil }
        let top = CountedMarker.Block(height: fact.blockHeight, cid: tip)
        while fact.blockHeight > marker.cursor.height {
            chain[fact.blockHeight] = fact
            guard let parent = fact.parentBlockHash, let next = try blockFact(parent, at: chainPath) else { return nil }
            fact = next
        }
        guard fact.blockHash == marker.cursor.cid else { return nil }
        // The blocks the counts' tip had above where the two chains meet.
        var left: [ChainBlockFact] = []
        var old = marker.tip
        while old.height > marker.cursor.height, chain[old.height]?.blockHash != old.cid {
            guard let fact = try blockFact(old.cid, at: chainPath), let parent = fact.parentBlockHash else { return nil }
            left.append(fact)
            old = CountedMarker.Block(height: fact.blockHeight - 1, cid: parent)
        }
        guard old.height > marker.cursor.height || old.cid == marker.cursor.cid else { return nil }
        let height = max(marker.cursor.height, top.height >= window ? top.height - window : 0)
        var cursor = marker.cursor
        if height > cursor.height {
            guard let fact = chain[height] else { return nil }
            cursor = CountedMarker.Block(height: height, cid: fact.blockHash)
        }
        var deltas: [String: Int] = [:]
        for fact in left {
            for (cid, count) in Self.net(fact.stateDiff).created { deltas[cid, default: 0] -= count }
        }
        for (height, fact) in chain {
            let net = Self.net(fact.stateDiff)
            if height > old.height {
                for (cid, count) in net.created { deltas[cid, default: 0] += count }
            }
            if height <= cursor.height {
                for (cid, count) in net.replaced { deltas[cid, default: 0] -= count }
            }
        }
        return (deltas.filter { $0.value != 0 }, CountedMarker(cursor: cursor, tip: top))
    }

    /// A block's diff netted per node: a block's diff sums its
    /// transitions', so a node one transition created and a later one
    /// replaced is on both sides, and is no change.
    static func net(_ diff: StateDiff) -> (created: [String: Int], replaced: [String: Int]) {
        var net = diff.created
        for (cid, count) in diff.replaced { net[cid, default: 0] -= count }
        return (net.filter { $0.value > 0 }, net.filter { $0.value < 0 }.mapValues { -$0 })
    }

    /// The block `depth` blocks below `tip` on its chain, or the lowest one
    /// reached when a fact is missing first.
    func ancestor(of tip: String, depth: UInt64, at chainPath: [String]) throws -> CountedMarker.Block? {
        guard var fact = try blockFact(tip, at: chainPath) else { return nil }
        for _ in 0..<depth {
            guard let parent = fact.parentBlockHash, let next = try blockFact(parent, at: chainPath) else { break }
            fact = next
        }
        return CountedMarker.Block(height: fact.blockHeight, cid: fact.blockHash)
    }

    /// Drops the counts of a tip's state earlier versions kept, the tips
    /// they described, and the counts and cursors of a version that kept
    /// them in state.db.
    func forgetStateCounts() throws {
        _ = try database.execute(
            """
            DELETE FROM core_meta WHERE substr(key, 1, 10) IN ('state_pin:', 'state_tip:')
                OR substr(key, 1, 12) = 'state_count:' OR substr(key, 1, 13) = 'state_cursor:'
            """
        )
    }
}

/// Where a chain's counts stand, written with them as their marker: the
/// block whose state they count with what each block after it replaced
/// (the cursor), and the act-on tip they were last moved to.
struct CountedMarker: Equatable, Sendable {
    struct Block: Equatable, Sendable {
        let height: UInt64
        let cid: String
    }

    let cursor: Block
    let tip: Block

    init(cursor: Block, tip: Block) {
        self.cursor = cursor
        self.tip = tip
    }

    init?(_ text: String) {
        let parts = text.split(separator: " ").map(String.init)
        guard parts.count == 4, let cursor = UInt64(parts[0]), let tip = UInt64(parts[2]), cursor <= tip else { return nil }
        self.init(cursor: Block(height: cursor, cid: parts[1]), tip: Block(height: tip, cid: parts[3]))
    }

    var text: String { "\(cursor.height) \(cursor.cid) \(tip.height) \(tip.cid)" }
}
