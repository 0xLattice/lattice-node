import Lattice
import cashew
import LatticeNodeCore
import UInt256

/// A node's durable store: header content and the fact log, appended in the
/// order the core's `persist` effects name them.
public struct SimStore: Sendable {
    public private(set) var headers: [String: StoredHeader] = [:]
    public private(set) var childIndexes: [String: FlatDictionary<BlockHeader>] = [:]
    /// Each stored header's own proof-of-work, verified once from its bytes.
    public private(set) var ownWork: [String: VerifiedWorkContribution] = [:]
    public private(set) var facts: [BlockImportBatch] = []
    public private(set) var blockFacts: Set<String> = []
    public private(set) var validations: Set<String> = []
    public private(set) var exclusions: Set<String> = []
    /// The stream cursors, durable with the facts.
    public private(set) var cursors: [String: StreamCursor] = [:]
    /// Header content a torn write kept without its facts: held, not weighed.
    public private(set) var torn: Set<String> = []

    /// An empty store, for a level that starts from a bootstrap batch.
    init() {}

    public init(genesis: SimBlock, facts seed: BlockImportBatch) {
        append(PersistBatch(
            headers: [StoredHeader(blockCID: genesis.cid, block: genesis.block, children: genesis.children)],
            facts: [seed]
        ))
    }

    public mutating func append(_ batch: PersistBatch) {
        for header in batch.headers {
            torn.remove(header.blockCID)
            headers[header.blockCID] = header
            ownWork[header.blockCID] = ChainTree.rootWork(of: header.block)
            childIndexes[header.block.children.rawCID] = header.children
        }
        facts += batch.facts
        cursors.merge(batch.cursors) { $1 }
        for fact in batch.facts.flatMap(\.facts) {
            switch fact {
            case .block(let block): blockFacts.insert(block.blockHash)
            case .validation(let validation): validations.insert(validation.blockHash)
            case .exclusion(let exclusion): exclusions.insert(exclusion.blockHash)
            case .work: break
            }
        }
    }

    /// A crash in the middle of writing `batch`: its header content lands
    /// in the volumes, its facts never reach the fact log.
    public mutating func appendTorn(_ batch: PersistBatch) {
        for header in batch.headers where headers[header.blockCID] == nil {
            append(PersistBatch(headers: [header], facts: []))
            torn.insert(header.blockCID)
        }
    }
}

/// Everything a tree says about its blocks, read through its public API: the
/// form two trees are compared in.
public struct TreeDigest: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let parent: String?
        public let height: UInt64
        public let grinds: [String: UInt256]
        public let prevState: String
        public let postState: String
        public let subtreeWork: UInt256?
    }

    public let genesis: String
    public let canonicalTip: String
    public let canonicalPath: [String]
    public let blocks: [String: Entry]
    public let executed: Set<String>
    public let excluded: Set<String>

    public init(_ tree: ChainTree) {
        var tree = tree
        let genesis = tree.canonicalBlockHash(atHeight: 0) ?? tree.canonicalTip
        var blocks: [String: Entry] = [:]
        var executed = Set<String>()
        var excluded = Set<String>()
        var pending = [genesis]
        while let hash = pending.popLast() {
            guard let meta = tree.getConsensusBlock(hash: hash) else { continue }
            blocks[hash] = Entry(
                parent: meta.parentBlockHash,
                height: meta.blockHeight,
                grinds: meta.workContributions.mapValues(\.work),
                prevState: tree.headerSnapshot(of: hash)?.prevStateCID ?? "",
                postState: tree.headerSnapshot(of: hash)?.postStateCID ?? "",
                subtreeWork: tree.subtreeWeight(forHash: hash)?.uint256Value
            )
            if tree.hasExecutedAncestry(blockHash: hash) { executed.insert(hash) }
            if tree.isExcludedRoot(hash) { excluded.insert(hash) }
            pending += meta.childHashes
        }
        let tipHeight = blocks[tree.canonicalTip]?.height ?? 0
        self.genesis = genesis
        self.canonicalTip = tree.canonicalTip
        self.canonicalPath = (0...tipHeight).compactMap { tree.canonicalBlockHash(atHeight: $0) }
        self.blocks = blocks
        self.executed = executed
        self.excluded = excluded
    }

    /// The deepest executed block on the best chain, walked from genesis;
    /// empty while the genesis root is not executed.
    public var actOnTip: String {
        canonicalPath.prefix { executed.contains($0) }.last ?? ""
    }
}

/// The checks the simulator runs after every step of every honest node.
public enum Invariants {
    static func fail(_ node: String, _ detail: String) -> SimulationError {
        .invariant("\(node): \(detail)")
    }

    /// DST 1, DST 2 and the "Lattice architecture preserved" checklist over
    /// one node's tree, against its previous digest and its durable store.
    public static func check(
        node: String,
        core: Core,
        digest: TreeDigest,
        previous: TreeDigest?,
        store: SimStore,
        world: World,
        flipTieBreak: Bool = false,
        treeChanged: Bool = true,
        weightsChanged: Bool = true
    ) throws {
        if treeChanged {
            try checkTree(
                node: node, core: core, digest: digest, previous: previous,
                store: store, world: world, flipTieBreak: flipTieBreak, weightsChanged: weightsChanged
            )
        }

        // The act-on tip is the deepest executed block on the best chain.
        if core.snapshot.actOnTip != digest.actOnTip {
            throw fail(node, "act-on tip \(core.snapshot.actOnTip) is not \(digest.actOnTip)")
        }
        if let published = core.published, published != core.snapshot {
            throw fail(node, "published snapshot is stale after the step")
        }

        // DST 6: bounded sync state (one request of each kind per peer by
        // construction). The pending queue stays within the
        // operator's budget whatever peers send.
        if core.sync.pending.bytes > core.config.pendingBudget {
            throw fail(node, "the pending queue holds \(core.sync.pending.bytes) bytes, over its budget")
        }
        if core.sync.pending.entries.keys.contains(where: digest.blocks.keys.contains) {
            throw fail(node, "a weighed header is still pending")
        }
    }

    /// The checks over the tree itself: run whenever it changed.
    static func checkTree(
        node: String,
        core: Core,
        digest: TreeDigest,
        previous: TreeDigest?,
        store: SimStore,
        world: World,
        flipTieBreak: Bool,
        weightsChanged: Bool = true
    ) throws {
        // The weighed graph is exactly the headers this node made durable, and
        // each of them has a durable block fact.
        guard Set(digest.blocks.keys) == Set(store.headers.keys).subtracting(store.torn) else {
            throw fail(node, "the weighed graph is not the set of durable headers")
        }
        if let missing = digest.blocks.keys.first(where: { !store.blockFacts.contains($0) }) {
            throw fail(node, "weighed block \(missing) has no durable block fact")
        }
        // DST 4 / work weighs, validity selects: every held block that
        // breaks a header validity rule (wrong spec or prevState) is
        // excluded, and beyond those only a block whose body the generator
        // knows is invalid, once executed.
        let headerExcluded = world.excluded.intersection(digest.blocks.keys)
        let allowed = headerExcluded.union(world.invalidBodies)
        guard headerExcluded.isSubset(of: digest.excluded), digest.excluded.isSubset(of: allowed) else {
            throw fail(node, "excludes \(digest.excluded.sorted()), ground truth \(headerExcluded.sorted()) plus invalid bodies")
        }
        let excluded = digest.excluded

        // DST 1 / validity selects / hierarchical GHOST: the head is an
        // independent reference's, built from the generator's ground truth
        // (each held block's true parent and the work its target implies),
        // never from what the tree reports. An execution that changed no
        // weight, head or exclusion leaves this as the last check found it.
        if weightsChanged {
        var reference = GhostReference(genesis: world.genesis.cid)
        reference.flipTieBreak = flipTieBreak
        reference.excluded = excluded
        reference.add(world.genesis.cid, parent: nil, work: workForTarget(world.genesis.block.target))
        for hash in digest.blocks.keys.sorted() where hash != world.genesis.cid {
            guard let truth = world.blocks[hash] else {
                throw fail(node, "weighed block \(hash) was never generated")
            }
            reference.add(hash, parent: truth.parent, work: workForTarget(truth.block.target))
        }
        let descent = reference.descent()
        guard descent.head == digest.canonicalTip, descent.path == digest.canonicalPath else {
            throw fail(node, "head \(digest.canonicalTip) is not the GHOST reference's \(descent.head)")
        }
        let work = reference.subtreeWork()
        for (hash, entry) in digest.blocks where entry.subtreeWork != work[hash] {
            throw fail(node, "subtree work of \(hash) is \(String(describing: entry.subtreeWork)), reference \(String(describing: work[hash]))")
        }
        }
        if let excludedOnPath = digest.canonicalPath.first(where: digest.excluded.contains) {
            throw fail(node, "the best chain enters excluded root \(excludedOnPath)")
        }

        // DST 2 / weighed graph: each grind has one location, and every held
        // block weighs exactly its verified proof-of-work.
        var located: [String: String] = [:]
        for (hash, entry) in digest.blocks {
            for grind in entry.grinds.keys {
                if let other = located.updateValue(hash, forKey: grind) {
                    throw fail(node, "grind \(grind) is credited at \(other) and \(hash)")
                }
            }
            guard store.headers[hash] != nil else {
                throw fail(node, "weighed block \(hash) has no durable content")
            }
            guard let own = store.ownWork[hash], entry.grinds == [own.id: own.work] else {
                throw fail(node, "block \(hash) weighs \(entry.grinds), not its own proof-of-work")
            }
        }

        // Work is never revoked: the weighed graph only grows.
        if let previous {
            for (hash, before) in previous.blocks {
                guard let now = digest.blocks[hash] else {
                    throw fail(node, "weighed block \(hash) left the graph")
                }
                for (grind, work) in before.grinds where (now.grinds[grind] ?? .zero) < work {
                    throw fail(node, "grind \(grind) at \(hash) lost work")
                }
            }
            if !previous.executed.isSubset(of: digest.executed) {
                throw fail(node, "the executed set shrank")
            }
        }

        // The executed set is a subset of the weighed graph, closed under
        // ancestry, and outside every excluded subtree.
        for hash in digest.executed {
            guard let entry = digest.blocks[hash] else {
                throw fail(node, "executed block \(hash) is not weighed")
            }
            if let parent = entry.parent, !digest.executed.contains(parent) {
                throw fail(node, "executed block \(hash) has an unexecuted parent")
            }
            if digest.excluded.contains(hash) {
                throw fail(node, "executed block \(hash) is excluded")
            }
        }

        // Parent-chain continuity reads the executed set on any branch: as a
        // parent level, this tree attests exactly the states its executed
        // blocks produced (a block whose post-state is its pre-state
        // produces nothing).
        let facts = ParentLevelFacts(tree: core.tree)
        let produced = Set(digest.executed.compactMap { hash in
            digest.blocks[hash].flatMap { $0.prevState == $0.postState ? nil : $0.postState }
        })
        for (hash, entry) in digest.blocks {
            let link = ParentStateContinuityLink(
                parentPath: core.tree.context?.path ?? [],
                fromStateCID: LatticeState.emptyHeader.rawCID,
                toStateCID: entry.postState
            )
            if facts.hasContinuity(link) != produced.contains(entry.postState) {
                throw fail(node, "continuity for the post-state of \(hash) disagrees with the executed set")
            }
        }

        // Weighed-only blocks issue no facts: a validation fact exists only
        // for an executed block, an exclusion only for an excluded root.
        for hash in store.validations where !digest.executed.contains(hash) {
            throw fail(node, "unexecuted block \(hash) has a durable validation")
        }
        for hash in store.exclusions where !digest.excluded.contains(hash) {
            throw fail(node, "durable exclusion of \(hash) is not in the tree")
        }

        // The root-exclusion rule: a root is excluded only while another
        // executed root stands.
        for hash in digest.excluded where digest.blocks[hash]?.parent == nil {
            if !digest.executed.contains(where: { $0 != hash && digest.blocks[$0]?.parent == nil }) {
                throw fail(node, "root \(hash) is excluded with no other executed root")
            }
        }

    }
}
