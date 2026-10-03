import Lattice

// The only core file that reads canonicity (the best chain). HeaderSync — what is
// served, what is asked, what is weighed — never does; `ChainCoreSyncTests`
// checks that the sync files name no canonicity API. Only what acts on the
// best chain lives here: the published snapshot, the act-on tip, and the
// mempool's tip.

/// What readers see: the best header tip and the tip a node acts on — the
/// deepest executed block on the best chain — with the mining tip epoch (a
/// worker skips a job whose epoch is not this one) and the pool's size.
public struct ChainSnapshot: Sendable, Equatable {
    public let bestHeaderTip: String
    public let bestHeaderHeight: UInt64
    public let actOnTip: String
    public let actOnHeight: UInt64
    public let miningEpoch: UInt64
    public let mempoolCount: Int
    public let mempoolBytes: Int
}

extension ChainCore {
    /// The best chain's genesis root, if any.
    static func bestRoot(of tree: ChainTree) -> [String] {
        tree.canonicalBlockHash(atHeight: 0).map { [$0] } ?? []
    }

    /// The mempool's starting tip: the act-on tip.
    static func miningTip(of tree: ChainTree) -> String {
        tree.actOnTip().hash
    }

    /// The spec of the act-on tip's genesis root: what the mempool measures
    /// transactions by. Nil while no root is executed.
    static func actOnSpec(of tree: ChainTree) -> ChainSpec? {
        tree.canonicalBlockHash(atHeight: 0)
            .flatMap { tree.isExecuted(blockHash: $0) ? tree.headerSnapshot(of: $0)?.specCID : nil }
            .flatMap { tree.specs[$0] }
    }

    public var snapshot: ChainSnapshot {
        let actOn = tree.actOnTip()
        return ChainSnapshot(
            bestHeaderTip: tree.canonicalTip,
            bestHeaderHeight: tree.headerSnapshot(of: tree.canonicalTip)?.tipHeight ?? 0,
            actOnTip: actOn.hash,
            actOnHeight: actOn.height,
            miningEpoch: mining.tipEpoch,
            mempoolCount: mining.mempool.count,
            mempoolBytes: mining.mempool.byteCount
        )
    }
}

extension ChainCore {
    // MARK: - Mining tip

    /// When the act-on tip moved, tell the mempool in the same step: the
    /// transactions of the blocks the act-on chain entered are confirmed
    /// (Bitcoin Core's `removeForBlock`), before any verdict on the new tip,
    /// and those of the blocks it left are read from content and returned
    /// (bounded by `maxPendingReturned`). An entered block whose IDs are not
    /// held is read first (`readTransactions`): the mempool stays on the
    /// old tip until the read answers, since a verdict on the new tip could
    /// not tell a used nonce from a confirmation.
    mutating func moveMiningTip(_ turn: inout Turn) {
        let tip = tree.actOnTip()
        guard tip.hash != mining.tipCID else { return }
        var entered: [String] = []
        var left: [String] = []
        var (old, new) = (mining.tipCID, tip.hash)
        while old != new, let oldHeight = index.height[old], let newHeight = index.height[new] {
            if oldHeight >= newHeight {
                left.append(old)
                guard let parent = index.parent[old] else { break }
                old = parent
            } else {
                entered.append(new)
                guard let parent = index.parent[new] else { break }
                new = parent
            }
        }
        let unread = entered.filter { executedTransactions[$0] == nil }
        guard unread.isEmpty else {
            let ask = unread.filter { !readingTransactions.contains($0) }.sorted()
            if !ask.isEmpty {
                readingTransactions.formUnion(ask)
                turn.effects.append(.readTransactions(ask))
            }
            return
        }
        let confirmed = Set(entered.flatMap { executedTransactions[$0] ?? [] })
        mining.spec = Self.actOnSpec(of: tree)
        turn.mining += mining.step(
            .tipMoved(TipMove(tipCID: tip.hash, confirmed: confirmed, left: left.reversed())),
            now: turn.now
        )
        let window = UInt64(max(config.bodyWindow, 0))
        executedTransactions = executedTransactions.filter {
            (index.height[$0.key] ?? 0) + window >= tip.height
        }
    }

    /// Answer each mined block awaiting execution that is not on the best
    /// chain: the body window will not execute it.
    mutating func answerSideMined(_ turn: inout Turn) {
        for (cid, replyID) in minedReplies.sorted(by: { $0.key < $1.key })
        where index.contains(cid) && !tree.isCanonical(hash: cid) {
            minedReplies[cid] = nil
            turn.effects.append(.workSubmitted(replyID: replyID, .side))
        }
    }

}

extension ChainTree {
    /// The deepest block on the best header chain whose ancestry is executed
    /// from genesis: the tip a node acts on. The executed blocks on one path
    /// are a prefix of it, so this is a binary search over heights. None
    /// (an empty hash) while the best chain's genesis root is not executed.
    func actOnTip() -> (hash: String, height: UInt64) {
        guard let genesis = canonicalBlockHash(atHeight: 0), isExecuted(blockHash: genesis) else { return ("", 0) }
        let tipHeight = headerSnapshot(of: canonicalTip)?.tipHeight ?? 0
        var low: UInt64 = 0
        var high = tipHeight
        while low < high {
            let middle = low + (high - low + 1) / 2
            if let hash = canonicalBlockHash(atHeight: middle),
               hasExecutedAncestry(blockHash: hash) {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return (canonicalBlockHash(atHeight: low) ?? canonicalTip, low)
    }
}
