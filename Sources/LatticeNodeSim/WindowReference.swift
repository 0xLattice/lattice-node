import Lattice
import LatticeNodeCore

extension Invariants {
    /// The body window, its connect order and the backlog as the core
    /// derives them (from its act-on tip and the best chain's own shape)
    /// agree after every step with the walk they replaced: the executed
    /// prefix searched for on the best chain at every read, and every
    /// window block's parent, height and execution read from the tree.
    static func checkWindowReference(node: String, core: ChainCore) throws {
        let reference = WindowReference(core: core)
        if core.bodyWindow != reference.window {
            throw fail(node, "body window \(core.bodyWindow), the reference walk's \(reference.window)")
        }
        let order = core.connectOrder
        if order.next != reference.next {
            throw fail(node, "next to connect \(order.next), the reference walk's \(reference.next)")
        }
        if order.distances != reference.distances {
            throw fail(node, "connect distances \(order.distances), the reference walk's \(reference.distances)")
        }
        if core.holdsBacklog != reference.holdsBacklog {
            throw fail(node, "holds a backlog: \(core.holdsBacklog), the reference walk's \(reference.holdsBacklog)")
        }
        let height = core.tree.headerSnapshot(of: core.tree.canonicalTip)?.tipHeight ?? 0
        if core.snapshot.bestHeaderHeight != height {
            throw fail(node, "best header height \(core.snapshot.bestHeaderHeight), the tip's header's \(height)")
        }
    }
}

/// The walk the core's body window replaced, read from the tree alone.
struct WindowReference {
    let window: [String]
    let next: [String]
    let distances: [String: Int]
    let holdsBacklog: Bool

    init(core: ChainCore) {
        let tree = core.tree
        let prefix = Self.executedPrefix(tree)
        let first = prefix.hash.isEmpty ? 0 : prefix.height + 1
        var best: [String] = []
        if let tipHeight = tree.headerSnapshot(of: tree.canonicalTip)?.tipHeight, core.config.bodyWindow > 0,
           tipHeight >= first {
            let last = min(tipHeight, first + UInt64(core.config.bodyWindow) - 1)
            best = (first...last).compactMap { tree.canonicalBlockHash(atHeight: $0) }
        }
        var forks: [String] = []
        var candidates = prefix.hash.isEmpty ? tree.genesisRoots : tree.children(of: prefix.hash)
        while true {
            let children = Self.byWeight(candidates.filter {
                tree.isExecuted(blockHash: $0) || !tree.isExcludedRoot($0)
            }, in: tree)
            forks += children.prefix { !tree.isExecuted(blockHash: $0) }
            guard let fork = children.first(where: tree.isExecuted(blockHash:)) else { break }
            candidates = tree.children(of: fork)
        }
        let window = forks + best.filter { !forks.contains($0) }
        self.window = window
        next = window.filter { tree.parent(of: $0).map(tree.isExecuted(blockHash:)) ?? true }
        let inWindow = Set(window)
        var base: [String: String] = [:]
        func start(of cid: String) -> String {
            if let known = base[cid] { return known }
            let parent = tree.parent(of: cid)
            let found = parent.flatMap { inWindow.contains($0) && !tree.isExecuted(blockHash: $0) ? start(of: $0) : nil } ?? cid
            base[cid] = found
            return found
        }
        var distances: [String: Int] = [:]
        for cid in window {
            let height = tree.height(of: cid) ?? 0
            let from = tree.height(of: start(of: cid)) ?? height
            distances[cid] = height > from ? Int(height - from) : 0
        }
        self.distances = distances
        let bodies = core.bodies
        holdsBacklog = [first, first + 1].allSatisfy { height in
            guard let cid = tree.canonicalBlockHash(atHeight: height), bodies.parked[cid] == nil else { return false }
            return bodies.connecting == cid || (bodies.arrived.contains(cid) && bodies.awaitingParent[cid] == nil)
        }
    }

    /// The deepest best-chain block whose ancestry is executed, by binary
    /// search over heights; none while the best chain's root is not executed.
    static func executedPrefix(_ tree: ChainTree) -> (hash: String, height: UInt64) {
        guard let genesis = tree.canonicalBlockHash(atHeight: 0), tree.isExecuted(blockHash: genesis) else { return ("", 0) }
        var low: UInt64 = 0
        var high = tree.headerSnapshot(of: tree.canonicalTip)?.tipHeight ?? 0
        while low < high {
            let middle = low + (high - low + 1) / 2
            if let hash = tree.canonicalBlockHash(atHeight: middle), tree.hasExecutedAncestry(blockHash: hash) {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return (tree.canonicalBlockHash(atHeight: low) ?? tree.canonicalTip, low)
    }

    static func byWeight(_ siblings: [String], in tree: ChainTree) -> [String] {
        guard siblings.count > 1 else { return siblings }
        return siblings
            .map { (hash: $0, work: tree.forkChoiceWeight(of: $0) ?? .zero) }
            .sorted { $0.work != $1.work ? $0.work > $1.work : forkChoicePrefersBlock($0.hash, over: $1.hash) }
            .map(\.hash)
    }
}
