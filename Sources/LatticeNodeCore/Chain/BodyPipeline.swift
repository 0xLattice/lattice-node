import Lattice

/// Body download and execution for one level. Block bodies are Volumes fetched by
/// CID through the content layer, which owns provider discovery, CID
/// verification and provider suppression, one attempt per ask. The core
/// names the next `ChainCoreConfig.bodyWindow` weighed-but-unexecuted blocks
/// on the best chain, asks again for a body not obtained after a backoff,
/// and connects them in parent order as their bodies arrive. It also
/// names, outside that count, the blocks the act-on tip would step into once
/// executed (`forkChildren`).
///
/// There is no per-peer state here and no fetch deadline: a missing body is
/// an availability wait, never blame and never a verdict.
public struct BodyPipeline: Sendable, Equatable {
    /// Bodies asked of the content layer that have not arrived.
    public internal(set) var requested: Set<String> = []
    /// Bodies that arrived and are not executed yet.
    public internal(set) var arrived: Set<String> = []
    /// The block whose connect job is running: one at a time, in parent
    /// order.
    public internal(set) var connecting: String?
    /// Blocks whose body could not be obtained, or whose connect found its
    /// content unresolvable, waiting before their bodies are asked for
    /// again. Each stays wanted: its wait ends early when the content may
    /// now be had (`wake`).
    public internal(set) var parked: [String: Parked] = [:]
    /// Child-level blocks whose connect lacked a parent fact (decision 21:
    /// a parent state this node has not executed), with the fact. Never
    /// invalid and never timed: each is connected again once its parent
    /// level holds that fact (`ChainEvent.parentFactsPresent`). Their bodies stay
    /// arrived.
    public internal(set) var awaitingParent: [String: CrossChainEvidenceRequirement] = [:]
    public struct Parked: Sendable, Equatable {
        public let notBefore: Int64
        public let attempts: Int
    }

    public init() {}

    /// The earliest parked retry after `now`.
    func nextRetry(after now: Int64) -> Int64? {
        parked.values.map(\.notBefore).filter { $0 > now }.min()
    }
}

extension ChainCore {
    /// The next blocks to execute: every fork child, then the best chain's
    /// blocks after its executed prefix in parent order. The operator's
    /// count bounds only that look-ahead. Each fork child is a
    /// proof-of-work header, so their number is paid for by work: a node
    /// asks for every alternative at a fork on the path it acts on.
    public var bodyWindow: [String] {
        bodyWindow(after: executedPrefix(actOn: actOnTip)).blocks
    }

    /// The body window after the executed prefix `prefix`, and the best
    /// chain's look-ahead it ends with.
    func bodyWindow(after prefix: (hash: String, height: UInt64)) -> (blocks: [String], best: [String]) {
        let forks = forkChildren(after: prefix.hash)
        let best = bestWindow(after: prefix)
        return (forks + best.filter { !forks.contains($0) }, best)
    }

    /// Whether this level has a backlog it could execute right now: the
    /// next two blocks after its executed prefix on its best chain have
    /// their bodies here, waiting on nothing but their connects. While they
    /// do (it is syncing), the level is not mined: work on its executed tip
    /// extends a chain it is about to leave. One block arriving at the tip
    /// leaves it mined. A body not held (withheld or missing), one whose
    /// content could not be read (it holds the level no more, arrived again
    /// or not, until its wait ends), or one waiting on its parent level
    /// leaves the level mined, and an invalid one is excluded when it
    /// executes and is no longer next.
    public var holdsBacklog: Bool {
        let prefix = executedPrefix(actOn: actOnTip)
        let first = prefix.hash.isEmpty ? 0 : prefix.height + 1
        return [first, first + 1].allSatisfy { height in
            guard let cid = tree.canonicalBlockHash(atHeight: height), bodies.parked[cid] == nil else { return false }
            return bodies.connecting == cid || (bodies.arrived.contains(cid) && bodies.awaitingParent[cid] == nil)
        }
    }

    /// The window's blocks whose parent is executed (`next`): the ones this
    /// level can connect next once their bodies arrive. And each window
    /// block's distance, in height, from the block on its own branch this
    /// level can connect next (a `next` block is at 0): the order in which
    /// their fetched bodies are needed. Per branch, so a fork or a root
    /// whose body is withheld does not push the blocks this level can use
    /// behind ones it cannot.
    public var connectOrder: (next: [String], distances: [String: Int]) {
        let prefix = executedPrefix(actOn: actOnTip)
        let (window, best) = bodyWindow(after: prefix)
        let inWindow = Set(window)
        // Each window block's parent, height and whether that parent is
        // executed. A best-chain block's parent and height are its place
        // after the executed prefix; only a fork child's are read.
        var links: [String: (parent: String?, height: UInt64, parentExecuted: Bool)] = [:]
        let first = prefix.hash.isEmpty ? 0 : prefix.height + 1
        for (offset, cid) in best.enumerated() {
            let parent = offset > 0 ? best[offset - 1] : (prefix.hash.isEmpty ? nil : prefix.hash)
            links[cid] = (parent, first + UInt64(offset), offset == 0 || tree.isExecuted(blockHash: best[offset - 1]))
        }
        for cid in window where links[cid] == nil {
            let parent = tree.parent(of: cid)
            links[cid] = (parent, tree.height(of: cid) ?? 0, parent.map(tree.isExecuted(blockHash:)) ?? true)
        }
        // The window block a block's run of unexecuted window ancestors starts at.
        var base: [String: String] = [:]
        func start(of cid: String) -> String {
            if let known = base[cid] { return known }
            let link = links[cid]
            let found = link.flatMap { link in
                link.parent.flatMap { inWindow.contains($0) && !link.parentExecuted ? start(of: $0) : nil }
            } ?? cid
            base[cid] = found
            return found
        }
        var distances: [String: Int] = [:]
        for cid in window {
            let height = links[cid]?.height ?? 0
            let from = links[start(of: cid)]?.height ?? height
            distances[cid] = height > from ? Int(height - from) : 0
        }
        return (window.filter { links[$0]?.parentExecuted ?? true }, distances)
    }

    /// The bytes a body of `cid` may count by its chain's spec, when the
    /// spec is held.
    public func maxBlockSize(of cid: String) -> Int? {
        tree.headerSnapshot(of: cid).flatMap { tree.specs[$0.specCID] }?.maxBlockSize
    }

    /// The best chain's blocks after its executed prefix `prefix`, up to the
    /// count.
    func bestWindow(after prefix: (hash: String, height: UInt64)) -> [String] {
        guard config.bodyWindow > 0, let tipHeight = tree.height(of: tree.canonicalTip) else { return [] }
        // A best chain whose genesis root is not executed yet starts there.
        let first = prefix.hash.isEmpty ? 0 : prefix.height + 1
        guard tipHeight >= first else { return [] }
        let last = min(tipHeight, first + UInt64(config.bodyWindow) - 1)
        return (first...last).compactMap { tree.canonicalBlockHash(atHeight: $0) }
    }

    /// The unexecuted blocks the act-on descent would step into once
    /// executed, heaviest first: every child of the act-on tip, and at each
    /// fork above it the children heavier than the executed one it took.
    /// The genesis roots are a fork like any other: while the best chain's
    /// root is not executed, the walk starts there.
    /// The cost: at a fork, each child that arrives heavier than those
    /// executed before it is executed too, so of three or more arriving
    /// lightest first more than one is stale. A stale sibling's descendants
    /// are never fetched unless it becomes the tip.
    func forkChildren(after prefix: String) -> [String] {
        var wanted: [String] = []
        var candidates = prefix.isEmpty ? tree.genesisRoots : tree.children(of: prefix)
        while true {
            let children = Self.byWeight(candidates.filter {
                tree.isExecuted(blockHash: $0) || !tree.isExcludedRoot($0)
            }, in: tree)
            wanted += children.prefix { !tree.isExecuted(blockHash: $0) }
            guard let fork = children.first(where: tree.isExecuted(blockHash:)) else { return wanted }
            candidates = tree.children(of: fork)
        }
    }

    /// The content layer has the body of `cid` locally. Only a body the
    /// window still wants is kept; any other arrival is simply unused.
    /// Its parent's body was held by whoever built on it: a parent waiting
    /// is asked for again at once.
    mutating func bodyFetched(_ cid: String) {
        guard bodies.requested.remove(cid) != nil else { return }
        bodies.arrived.insert(cid)
        wake(parentOf: cid)
    }

    /// A block's body may now be had: its parent's, when the block was
    /// weighed or its body arrived (its author executed the parent, so
    /// held that body), as Bitcoin asks for a block once a peer announces
    /// it. A hint, never a verdict: a wake costs one more attempt, and a
    /// block weighed again (or one whose parent is already executed) wakes
    /// nothing that waits. A wait that ends here is asked for in this step.
    mutating func wake(parentOf cid: String) {
        guard let parent = tree.parent(of: cid) else { return }
        end(parent)
    }

    /// A peer that may hold this level's content connected (`ChainEvent
    /// .providerJoined`): every waiting body is asked for again at once.
    mutating func providerJoined() {
        for cid in bodies.parked.keys { end(cid) }
    }

    /// `cid`'s wait is over: it is asked for in this step. It keeps its
    /// attempts, so a body that fails again waits as long as it would have,
    /// and a wake costs one attempt.
    private mutating func end(_ cid: String) {
        guard let parked = bodies.parked[cid] else { return }
        bodies.parked[cid] = BodyPipeline.Parked(notBefore: 0, attempts: parked.attempts)
    }

    /// The content layer could not obtain the body of `cid`: it waits out
    /// the backoff, and is asked for again then, or at once when it may
    /// now be had (`wake`, `providerJoined`). Nothing else ends the wait:
    /// an execution or a moved window says nothing of who holds a body.
    mutating func bodyUnavailable(_ cid: String, _ turn: inout Turn) {
        guard bodies.requested.remove(cid) != nil else { return }
        park(cid, now: turn.now)
    }

    /// `cid` waits before its body is asked for again, doubling per attempt
    /// up to `bodyRetryCap`.
    private mutating func park(_ cid: String, now: Int64) {
        let attempts = (bodies.parked[cid]?.attempts ?? 0) + 1
        let shift = min(attempts - 1, 20)
        let wait = min(config.bodyRetryCap, config.bodyRetryBase << Int64(shift))
        bodies.parked[cid] = BodyPipeline.Parked(notBefore: now + wait, attempts: attempts)
    }

    /// Apply a connect verdict. Execution depends only on content, so a
    /// verdict is never stale: a valid block joins the executed set, its
    /// post-state persisted with its validation; a block execution proved invalid is excluded while its
    /// work still weighs. A verdict lacking a parent fact waits for the
    /// parent level to execute more (`awaitingParent`). Any other verdict
    /// without a decision (content that was not resolvable after all) is an
    /// availability wait: the block parks, and its body is asked for again
    /// after a backoff.
    mutating func connected(_ verdict: ConnectVerdict, transactions: [String], _ turn: inout Turn) {
        let cid = verdict.blockHash
        if bodies.connecting == cid { bodies.connecting = nil }
        switch verdict.retryFailure {
        case .crossChainEvidenceRequired(let fact)?:
            switch fact {
            case .parentStateContinuity:
                bodies.awaitingParent[cid] = fact
                return
            case .childProof:
                break
            }
        default:
            break
        }
        bodies.arrived.remove(cid)
        switch tree.applyConnect(verdict) {
        case .applied(let update):
            if let state = update.materializedPostState { turn.states.append(state) }
            turn.facts += update.batches
            weighed += update.weighed
            if !update.excluded {
                executedTransactions[cid] = transactions
                if let meta = tree.getConsensusBlock(hash: cid) {
                    executedChildren.record(meta.childCommitments.keys)
                }
            }
            if let replyID = minedReplies.removeValue(forKey: cid) {
                turn.effects.append(.workSubmitted(
                    replyID: replyID,
                    update.excluded ? .invalid : .executed(tipCID: actOnTip.hash)
                ))
            }
        case .duplicate:
            break
        case .rejected:
            // No verdict: nothing was emitted and the tree is unchanged.
            guard verdict.retryFailure != nil else { break }
            park(cid, now: turn.now)
        }
    }

    /// The parent level now holds the facts these blocks awaited: they are
    /// connected again.
    mutating func parentFactsPresent(_ blocks: [String]) {
        for cid in blocks { bodies.awaitingParent[cid] = nil }
    }

    /// Ask the content layer for every body in the window not yet asked for
    /// (a parked one once its wait is over), cancel bodies the window
    /// left, and start the next connect: the first window block whose body
    /// is here and whose parent is executed.
    mutating func scheduleBodies(prefix: (hash: String, height: UInt64), _ turn: inout Turn) {
        let window = bodyWindow(after: prefix).blocks
        let wanted = Set(window)
        for cid in weighed { wake(parentOf: cid) }
        for cid in bodies.requested.subtracting(wanted).sorted() {
            turn.effects.append(.cancelBody(cid: cid))
        }
        bodies.requested.formIntersection(wanted)
        bodies.arrived.formIntersection(wanted)
        bodies.parked = bodies.parked.filter { wanted.contains($0.key) }
        bodies.awaitingParent = bodies.awaitingParent.filter { wanted.contains($0.key) }
        for cid in window where !bodies.requested.contains(cid) && !bodies.arrived.contains(cid) {
            if let parked = bodies.parked[cid], parked.notBefore > turn.now { continue }
            bodies.requested.insert(cid)
            turn.effects.append(.fetchBody(cid: cid))
        }
        guard bodies.connecting == nil, let next = window.first(where: {
            bodies.arrived.contains($0) && bodies.awaitingParent[$0] == nil
                && tree.parent(of: $0).map(tree.hasExecutedAncestry(blockHash:)) ?? true
        }), let job = tree.connectJob(for: next) else { return }
        bodies.connecting = next
        turn.effects.append(.connect(job))
    }
}
