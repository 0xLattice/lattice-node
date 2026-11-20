import Lattice

// The only core file that reads canonicity (the best chain). HeaderSync — what is
// served, what is asked, what is weighed — never does; `ChainCoreSyncTests`
// checks that the sync files name no canonicity API. Only what acts on the
// best chain lives here: the published snapshot, the act-on tip, the
// mempool's tip, and the operator's finality window, the one place sync
// consults the best chain, and only when a window is set.

/// What readers see: the best header tip and the tip a node acts on — the
/// heaviest executed tip — and the pool's size.
public struct ChainSnapshot: Sendable, Equatable {
    public let bestHeaderTip: String
    public let bestHeaderHeight: UInt64
    public let actOnTip: String
    public let actOnHeight: UInt64
    public let mempoolCount: Int
    public let mempoolBytes: Int
}

extension ChainCore {
    /// The mempool's starting tip: the act-on tip.
    static func miningTip(of tree: ChainTree) -> String {
        tree.heaviestExecutedTip()
    }

    /// The tip a node acts on: the heaviest executed tip
    /// (`ChainTree.heaviestExecutedTip`). A block with no verdict — its body
    /// not held, or not yet run — is never stepped into: it weighs, and is
    /// taken once it executes.
    var actOnTip: (hash: String, height: UInt64) {
        let tip = tree.heaviestExecutedTip()
        return (tip, tree.height(of: tip) ?? 0)
    }

    /// The act-on descent with `avoided` blocks, and all they lead to, left
    /// out (`ChainTree.heaviestExecutedTip(avoiding:)`).
    public func actOnTip(avoiding avoided: Set<String>) -> String {
        tree.heaviestExecutedTip(avoiding: avoided)
    }

    /// `tipCID` when `accepts` holds for it; otherwise the act-on descent
    /// avoiding each tip it fails for (`actOnTip(avoiding:)`), checked again.
    /// Nil when it holds for none, or answers nil (the tip cannot be read).
    /// It runs at once, so the walk sees one state of the level.
    public func actOnTip(from tipCID: String, accepting accepts: (String) -> Bool?) -> String? {
        var avoided: Set<String> = []
        var tip = tipCID
        while true {
            guard let ok = accepts(tip) else { return nil }
            if ok { return tip }
            // Each pass avoids one more block of a finite tree.
            guard avoided.insert(tip).inserted else { return nil }
            tip = actOnTip(avoiding: avoided)
        }
    }

    /// The parent of a weighed block: how a reader walks the act-on chain,
    /// which need not be the best header chain.
    public func parent(of cid: String) -> String? {
        tree.parent(of: cid)
    }

    /// Sibling blocks heaviest first by fork choice's subtree work, ties by
    /// its rule. Each is weighed once, and only at a fork.
    static func byWeight(_ siblings: [String], in tree: ChainTree) -> [String] {
        guard siblings.count > 1 else { return siblings }
        return siblings
            .map { (hash: $0, work: tree.forkChoiceWeight(of: $0) ?? .zero) }
            .sorted { $0.work != $1.work ? $0.work > $1.work : forkChoicePrefersBlock($0.hash, over: $1.hash) }
            .map(\.hash)
    }

    /// The spec of the act-on tip's genesis root: what the mempool measures
    /// transactions by. Every block carries its parent's spec (spec §5.1),
    /// so it is the act-on tip's own. Nil while no root is executed.
    static func actOnSpec(of tree: ChainTree) -> ChainSpec? {
        tree.headerSnapshot(of: tree.heaviestExecutedTip()).flatMap { tree.specs[$0.specCID] }
    }

    /// Set `synced` once a peer's log has been read to its end and applied,
    /// and the act-on tip is the heaviest tip whose bodies may be had
    /// (`heaviestObtainableTip`). Only a log of a peer running this level
    /// counts: one that does not answers with an empty log of no id
    /// (`NodeCore.answerUnhosted`), which says nothing about the chain. As
    /// Bitcoin Core's `IsInitialBlockDownload` reads only the active chain,
    /// never the best header, whose data may never come
    /// (`setBlockIndexCandidates` holds only tips with data), a body no
    /// provider had, its backoff at the cap, does not hold the latch: it
    /// stays one-way, and a body that arrives later moves only fork choice.
    ///
    /// The first half alone sets `headersSynced`, once this level holds a
    /// weighed block: a level with none (a child whose genesis it has not
    /// weighed) opens no child, whatever log it read. It says what this
    /// level read, not how much there is: the log is one peer's, and a peer
    /// that is itself behind has a short one. A child opened on a parent
    /// that has weighed little weighs what proofs let it, and the rest as
    /// its parent weighs on (`ChildProofs`).
    mutating func latchSynced() {
        guard !synced, sync.peers.contains(where: { peer, state in
            state.readToEnd && !state.more && state.holes.isEmpty && sync.cursors[peer.key]?.logID.isEmpty == false
        }) else { return }
        let snapshot = snapshot
        guard !snapshot.bestHeaderTip.isEmpty else { return }
        headersSynced = true
        guard !snapshot.actOnTip.isEmpty else { return }
        if snapshot.actOnTip == snapshot.bestHeaderTip || snapshot.actOnTip == heaviestObtainableTip() { synced = true }
    }

    /// Whether `cid` cannot be executed here for now. Either its body could
    /// not be obtained: it failed often enough that its backoff reached
    /// `bodyRetryCap`, and it waits that out (`bodies.parked`), not asked
    /// again, arrived or executed since; a body in flight, a first ask or
    /// one asked again is not, nor is one whose backoff is still below the
    /// cap: a transient failure holds the latch as a body in flight does.
    /// Or its connect waits on a parent fact its parent level lacks once
    /// that level has caught up (`parentCaughtUp`): "not proven here"
    /// (spec §9.5), retriable and owed by no one, so not on its way. While
    /// the parent is still syncing the fact likely is, and holds the latch
    /// as a body in flight does.
    func unobtainable(_ cid: String) -> Bool {
        if bodies.awaitingParent[cid] != nil, parentCaughtUp, !tree.isExecuted(blockHash: cid) { return true }
        guard let parked = bodies.parked[cid] else { return false }
        return config.bodyRetryWait(afterAttempts: parked.attempts) >= config.bodyRetryCap
            && !bodies.requested.contains(cid) && !bodies.arrived.contains(cid) && !tree.isExecuted(blockHash: cid)
    }

    /// Fork choice's tip with every block that cannot be executed here for
    /// now (`unobtainable`),
    /// and all it leads to, left out, as are blocks proven invalid (fork
    /// choice's own exclusion). Up to the first such block on the
    /// best chain it is the best chain itself, so only the heaviest
    /// branches below that block are walked.
    func heaviestObtainableTip() -> String {
        let best = tree.canonicalTip
        let lowest = Set(bodies.parked.keys).union(bodies.awaitingParent.keys).filter(unobtainable)
            .compactMap { cid in tree.height(of: cid).flatMap { tree.canonicalBlockHash(atHeight: $0) == cid ? $0 : nil } }
            .min()
        guard let lowest else { return best }
        func preferred(_ blocks: [String]) -> String? {
            Self.byWeight(blocks.filter {
                !unobtainable($0) && (tree.isExecuted(blockHash: $0) || !tree.isExcludedRoot($0))
            }, in: tree).first
        }
        let start = lowest == 0 ? nil : tree.canonicalBlockHash(atHeight: lowest - 1)
        guard var tip = start ?? preferred(tree.genesisRoots) else { return "" }
        while let next = preferred(tree.getConsensusBlock(hash: tip)?.childHashes ?? []) { tip = next }
        return tip
    }

    public var snapshot: ChainSnapshot { snapshot(actOn: actOnTip) }

    func snapshot(actOn: (hash: String, height: UInt64)) -> ChainSnapshot {
        let bestHeaderTip = tree.canonicalTip
        return ChainSnapshot(
            bestHeaderTip: bestHeaderTip,
            bestHeaderHeight: tree.height(of: bestHeaderTip) ?? 0,
            actOnTip: actOn.hash,
            actOnHeight: actOn.height,
            mempoolCount: mining.mempool.count,
            mempoolBytes: mining.mempool.byteCount
        )
    }
}

extension ChainCore {
    // MARK: - Mining tip

    /// What every step ends with: the body window scheduled, the mempool
    /// moved to the act-on tip, and mined blocks the window will not
    /// execute answered. Returns the act-on tip, read once: none of it
    /// changes the tree.
    mutating func followActOnChain(_ turn: inout Turn) -> (hash: String, height: UInt64) {
        let tip = actOnTip
        let prefix = executedPrefix(actOn: tip)
        scheduleBodies(prefix: prefix, &turn)
        moveMiningTip(to: tip, &turn)
        answerSideMined(prefix: prefix.hash, &turn)
        return tip
    }

    /// When the act-on tip moved, tell the mempool in the same step: the
    /// transactions of the blocks the act-on chain entered are confirmed
    /// (Bitcoin Core's `removeForBlock`), before any verdict on the new tip,
    /// and those of the blocks it left are read from content and returned
    /// (bounded by `maxPendingReturned`). An entered block whose IDs are not
    /// held is read first (`readTransactions`): the mempool stays on the
    /// old tip until the read answers, since a verdict on the new tip could
    /// not tell a used nonce from a confirmation.
    mutating func moveMiningTip(to tip: (hash: String, height: UInt64), _ turn: inout Turn) {
        guard tip.hash != mining.tipCID else { return }
        var entered: [String] = []
        var left: [String] = []
        var (old, new) = (mining.tipCID, tip.hash)
        while old != new, let oldHeight = tree.height(of: old), let newHeight = tree.height(of: new) {
            if oldHeight >= newHeight {
                left.append(old)
                guard let parent = tree.parent(of: old) else { break }
                old = parent
            } else {
                entered.append(new)
                guard let parent = tree.parent(of: new) else { break }
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
            (tree.height(of: $0.key) ?? 0) + window >= tip.height
        }
    }

    /// Answer each mined block awaiting execution that the body window will
    /// not execute: one off the best chain that is not a fork child.
    mutating func answerSideMined(prefix: String, _ turn: inout Turn) {
        guard !minedReplies.isEmpty else { return }
        let stepped = forkChildren(after: prefix)
        for (cid, replyID) in minedReplies.sorted(by: { $0.key < $1.key })
        where tree.contains(blockHash: cid) && !tree.isCanonical(hash: cid) && !stepped.contains(cid) {
            minedReplies[cid] = nil
            turn.effects.append(.workSubmitted(replyID: replyID, .side))
        }
    }

}

extension ChainCore {
    /// The deepest block on the best header chain whose ancestry is executed
    /// from genesis, read from the act-on tip `actOn`: up to that block the
    /// act-on descent is fork choice's own, so an act-on tip on the best
    /// chain is it. Only an act-on tip off the best chain (one that stepped
    /// into an executed fork child, or descends from another genesis root)
    /// searches for it. None (an empty hash) while the best chain's genesis
    /// root is not executed.
    func executedPrefix(actOn: (hash: String, height: UInt64)) -> (hash: String, height: UInt64) {
        if !actOn.hash.isEmpty, tree.isCanonical(hash: actOn.hash) { return actOn }
        return tree.executedPrefix()
    }
}

extension ChainTree {
    /// The deepest block on the best header chain whose ancestry is executed
    /// from genesis. The executed blocks on one path
    /// are a prefix of it, so this is a binary search over heights. None
    /// (an empty hash) while the best chain's genesis root is not executed.
    func executedPrefix() -> (hash: String, height: UInt64) {
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

// MARK: - Finality window

extension ChainCore {
    /// Whether a block at `height` is more than this chain's finality window
    /// below its best weighed tip. The tip's next height never
    /// is, so a stalled chain can always be extended.
    func pastFinality(height: UInt64) -> Bool {
        guard let window = config.finality.window(for: chainPath), !tree.canonicalTip.isEmpty else { return false }
        let tip = tree.getHighestBlockHeight()
        return tip > height && tip - height > window
    }

    /// Whether weighed block `cid` is past the finality window.
    func pastFinality(_ cid: String) -> Bool {
        tree.height(of: cid).map(pastFinality(height:)) ?? false
    }
}
