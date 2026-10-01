import Lattice

/// Body download and execution for one level. Bodies are Volumes fetched by
/// CID through the content layer, which owns provider discovery, CID
/// verification, retries and provider suppression. The core only names the
/// next `CoreConfig.bodyWindow` weighed-but-unexecuted blocks on the best
/// chain and connects them in parent order as their bodies arrive.
///
/// There is no per-peer state here and no fetch deadline: a missing body is
/// an availability wait, never blame.
public struct Bodies: Sendable, Equatable {
    /// Bodies asked of the content layer that have not arrived.
    public internal(set) var requested: Set<String> = []
    /// Bodies that arrived and are not executed yet.
    public internal(set) var arrived: Set<String> = []
    /// The block whose connect job is running: one at a time, in parent
    /// order.
    public internal(set) var connecting: String?
    /// Blocks whose connect found its content unresolvable, waiting before
    /// their bodies are asked for again.
    public internal(set) var parked: [String: Parked] = [:]
    /// The act-on tip and window when `parked` was last kept: a change to
    /// either (an execution, or a best chain that moved) starts every
    /// backoff over. A header weighed off the best chain changes neither.
    var seen: TreeMark?

    public struct Parked: Sendable, Equatable {
        public let notBefore: Int64
        public let attempts: Int
    }

    struct TreeMark: Sendable, Equatable {
        let actOn: String
        let window: [String]
    }

    public init() {}

    /// The earliest parked retry after `now`.
    func nextRetry(after now: Int64) -> Int64? {
        parked.values.map(\.notBefore).filter { $0 > now }.min()
    }
}

extension Core {
    /// The best chain's blocks after the act-on tip, up to the window: the
    /// next blocks to execute, in parent order.
    public var bodyWindow: [String] {
        let actOn = tree.actOnTip()
        let tipHeight = tree.headerSnapshot(of: tree.canonicalTip)?.tipHeight ?? 0
        guard tipHeight > actOn.height, config.bodyWindow > 0 else { return [] }
        let last = min(tipHeight, actOn.height + UInt64(config.bodyWindow))
        return ((actOn.height + 1)...last).compactMap { tree.canonicalBlockHash(atHeight: $0) }
    }

    /// The content layer has the body of `cid` locally. Only a body the
    /// window still wants is kept; any other arrival is simply unused.
    mutating func bodyFetched(_ cid: String) {
        guard bodies.requested.remove(cid) != nil else { return }
        bodies.arrived.insert(cid)
    }

    /// Apply a connect verdict. Execution depends only on content, so a
    /// verdict is never stale: a valid block joins the executed set, its
    /// post-state and the genesis links it issued persisted with its
    /// validation; a block execution proved invalid is excluded while its
    /// work still weighs. A verdict without a decision (content that was not
    /// resolvable after all) is an availability wait: the block parks, and
    /// its body is asked for again after a backoff.
    mutating func connected(_ verdict: ConnectVerdict, _ turn: inout Turn) {
        let cid = verdict.blockHash
        if bodies.connecting == cid { bodies.connecting = nil }
        bodies.arrived.remove(cid)
        switch tree.applyConnect(verdict) {
        case .applied(let update):
            if let state = update.materializedPostState { turn.states.append(state) }
            turn.facts += update.batches
            turn.genesisLinks += update.parentGenesisLinks.map {
                IssuedGenesisLink(link: $0, issuer: update.blockHash)
            }
            if let replyID = minedReplies.removeValue(forKey: cid) {
                turn.effects.append(.workSubmitted(
                    replyID: replyID,
                    update.excluded ? .invalid : .executed(tipCID: tree.actOnTip().hash)
                ))
            }
        case .duplicate:
            break
        case .rejected:
            // No verdict: nothing was emitted and the tree is unchanged.
            guard verdict.retryFailure != nil else { break }
            let attempts = (bodies.parked[cid]?.attempts ?? 0) + 1
            let shift = min(attempts - 1, 20)
            let wait = min(config.bodyRetryCap, config.bodyRetryBase << Int64(shift))
            bodies.parked[cid] = Bodies.Parked(notBefore: turn.now + wait, attempts: attempts)
        }
    }

    /// Ask the content layer for every body in the window not yet asked for
    /// (a parked one once its wait is over), cancel bodies the best chain
    /// left, and start the next connect when the block after the act-on tip
    /// has its body.
    mutating func scheduleBodies(_ turn: inout Turn) {
        let window = bodyWindow
        let wanted = Set(window)
        let mark = Bodies.TreeMark(actOn: tree.actOnTip().hash, window: window)
        if bodies.seen != mark {
            bodies.seen = mark
            bodies.parked.removeAll()
        }
        for cid in bodies.requested.subtracting(wanted).sorted() {
            turn.effects.append(.cancelBody(cid: cid))
        }
        bodies.requested.formIntersection(wanted)
        bodies.arrived.formIntersection(wanted)
        bodies.parked = bodies.parked.filter { wanted.contains($0.key) }
        for cid in window where !bodies.requested.contains(cid) && !bodies.arrived.contains(cid) {
            if let parked = bodies.parked[cid], parked.notBefore > turn.now { continue }
            bodies.requested.insert(cid)
            turn.effects.append(.fetchBody(cid: cid))
        }
        guard bodies.connecting == nil, let next = window.first,
              bodies.arrived.contains(next),
              let job = tree.connectJob(for: next) else { return }
        bodies.connecting = next
        turn.effects.append(.connect(job))
    }
}
