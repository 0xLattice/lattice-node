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
    /// cursor passes replaced. `known` is the counts' chain, the blocks
    /// from the cursor up to their tip, as the last change returned it;
    /// without it (or not matching the marker) it is walked again. Only the
    /// facts of the blocks entering, leaving and passed are read. Nil when
    /// the counts cannot follow: a fact is missing, or the cursor's block is
    /// not on the tip's chain (the tip is below it, or forked from below
    /// it).
    func countedChange(
        at chainPath: [String], from marker: CountedMarker, to tip: String, window: UInt64, known: [String]? = nil
    ) throws -> CountedChange? {
        let base = marker.cursor.height
        var chain: [String]
        if let known, known.first == marker.cursor.cid, known.last == marker.tip.cid,
           UInt64(known.count) == marker.tip.height - base + 1 {
            chain = known
        } else {
            guard let walked = try self.chain(from: marker.tip, down: marker.cursor, at: chainPath) else { return nil }
            chain = walked
        }
        // The tip's chain down to where it meets the counts' chain.
        var entering: [ChainBlockFact] = []
        guard var fact = try blockFact(tip, at: chainPath) else { return nil }
        while true {
            let height = fact.blockHeight
            if height >= base, height - base < UInt64(chain.count), chain[Int(height - base)] == fact.blockHash { break }
            guard height > base, let parent = fact.parentBlockHash, let next = try blockFact(parent, at: chainPath) else {
                return nil
            }
            entering.append(fact)
            fact = next
        }
        let meet = Int(fact.blockHeight - base)
        var deltas: [String: Int] = [:]
        for cid in chain[(meet + 1)...] {
            guard let left = try blockFact(cid, at: chainPath) else { return nil }
            for (cid, count) in Self.net(left.stateDiff).created { deltas[cid, default: 0] -= count }
        }
        var facts: [String: ChainBlockFact] = [:]
        for fact in entering {
            facts[fact.blockHash] = fact
            for (cid, count) in Self.net(fact.stateDiff).created { deltas[cid, default: 0] += count }
        }
        chain = Array(chain[...meet]) + entering.reversed().map(\.blockHash)
        let top = base + UInt64(chain.count - 1)
        let passed = Int(max(base, top >= window ? top - window : 0) - base)
        for cid in chain[1..<(passed + 1)] {
            guard let crossed = try facts[cid] ?? blockFact(cid, at: chainPath) else { return nil }
            for (cid, count) in Self.net(crossed.stateDiff).replaced { deltas[cid, default: 0] -= count }
        }
        return CountedChange(
            deltas: deltas.filter { $0.value != 0 },
            marker: CountedMarker(
                cursor: CountedMarker.Block(height: base + UInt64(passed), cid: chain[passed]),
                tip: CountedMarker.Block(height: top, cid: tip)
            ),
            known: Array(chain[passed...])
        )
    }

    /// The blocks from `bottom` up to `top` on `top`'s chain, lowest first:
    /// nil when a fact is missing or `bottom` is not below `top`.
    func chain(from top: CountedMarker.Block, down bottom: CountedMarker.Block, at chainPath: [String]) throws -> [String]? {
        guard top.height >= bottom.height else { return nil }
        var chain = [top.cid]
        while UInt64(chain.count) <= top.height - bottom.height {
            guard let fact = try blockFact(chain[chain.count - 1], at: chainPath), let parent = fact.parentBlockHash else {
                return nil
            }
            chain.append(parent)
        }
        guard chain.last == bottom.cid else { return nil }
        return chain.reversed()
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

    /// Drops the counts of a tip's state earlier versions kept, and the
    /// tips they described.
    func forgetStateCounts() throws {
        _ = try database.execute(
            "DELETE FROM core_meta WHERE substr(key, 1, 10) IN ('state_pin:', 'state_tip:')"
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

/// A move of a chain's counts: the deltas, the marker they are written
/// with, and the blocks from the new cursor up to the tip, which the next
/// move starts from.
struct CountedChange: Sendable {
    let deltas: [String: Int]
    let marker: CountedMarker
    let known: [String]
}
