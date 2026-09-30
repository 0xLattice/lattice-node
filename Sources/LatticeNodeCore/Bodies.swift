import Lattice

/// Body download and execution for one level. Bodies are Volumes fetched by
/// CID through the content layer, which owns provider discovery, CID
/// verification, retries and provider suppression. The core only names the
/// next `CoreConfig.bodyWindow` weighed-but-unexecuted blocks on the best
/// chain and connects them in parent order as their bodies arrive.
///
/// There is no per-peer state here and no deadline: a missing body is an
/// availability wait, never blame.
public struct Bodies: Sendable, Equatable {
    /// Bodies asked of the content layer that have not arrived.
    public internal(set) var requested: Set<String> = []
    /// Bodies that arrived and are not executed yet.
    public internal(set) var arrived: Set<String> = []
    /// The block whose connect job is running: one at a time, in parent
    /// order.
    public internal(set) var connecting: String?

    public init() {}
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
    /// verdict is never stale: a valid block joins the executed set, and a
    /// block execution proved invalid is excluded while its work still
    /// weighs. A verdict without a decision (the body is not resolvable
    /// after all) is an availability wait: the body is asked for again.
    mutating func connected(_ verdict: ConnectVerdict, _ turn: inout Turn) {
        let cid = verdict.blockHash
        if bodies.connecting == cid { bodies.connecting = nil }
        bodies.arrived.remove(cid)
        switch tree.applyConnect(verdict) {
        case .applied(let update):
            turn.facts += update.batches
        case .duplicate:
            break
        case .rejected:
            // No verdict: nothing was emitted and the tree is unchanged.
            // The window asks for the body again on this step.
            break
        }
    }

    /// Ask the content layer for every body in the window not yet asked for,
    /// forget bodies the best chain left, and start the next connect when
    /// the block after the act-on tip has its body.
    mutating func scheduleBodies(_ turn: inout Turn) {
        let window = bodyWindow
        let wanted = Set(window)
        bodies.requested.formIntersection(wanted)
        bodies.arrived.formIntersection(wanted)
        for cid in window where !bodies.requested.contains(cid) && !bodies.arrived.contains(cid) {
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
