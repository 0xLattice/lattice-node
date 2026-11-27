/// What a level's acted-on tip waits on, derived from the level's state
/// where it is asked; nothing here is stored. Behind its best header tip, it
/// names the state of the next block to execute; at it, whether headers are
/// still being weighed. `stalled` is the one that should never last: the
/// level is behind and no work for its next block is under way.
public enum ChainProgress: String, Sendable, Equatable, CaseIterable {
    /// The acted-on tip is the best header tip, and no header is waiting to
    /// be weighed: the level waits for the network's next block.
    case atTip
    /// Headers are read or waiting for their parent header.
    case headers
    /// Child-chain headers wait for a proof that weighs them.
    case proofs
    /// A child level waits for its parent level: to weigh a peer's whole
    /// log before it reads its own peers, or to execute the fact its next
    /// block needs.
    case parent
    /// The next block's body is asked for and has not arrived.
    case bodies
    /// The next block's body could not be had, from any peer or this
    /// node's store, and is asked for again after a wait.
    case bodiesUnavailable
    /// The next block is being executed, or its body has arrived and waits
    /// for its connect.
    case execution
    /// Behind the best header tip, with nothing under way for the next
    /// block: no ask, no body, no connect.
    case stalled
}

extension ChainCore {
    /// What the acted-on tip waits on (`ChainProgress`). `parentWeighed` is
    /// whether the parent level has weighed a peer's whole log (true for a
    /// root level); `next` is `connectOrder.next`, when the caller holds it.
    public func progress(parentWeighed: Bool, next: [String]? = nil) -> ChainProgress {
        if !parentWeighed { return .parent }
        let snapshot = snapshot
        guard snapshot.actOnTip == snapshot.bestHeaderTip else {
            let next = next ?? connectOrder.next
            // The block that would move the tip: a child of the tip, as
            // status's `waiting` names it, else the first block whose parent
            // is executed.
            guard let cid = next.first(where: { parent(of: $0) == snapshot.actOnTip }) ?? next.first else {
                return .stalled
            }
            if bodies.connecting.contains(cid) || bodies.arrived.contains(cid) {
                return bodies.awaitingParent[cid] != nil ? .parent : .execution
            }
            if bodies.awaitingParent[cid] != nil { return .parent }
            if bodies.parked[cid] != nil { return .bodiesUnavailable }
            if bodies.requested.contains(cid) { return .bodies }
            return .stalled
        }
        if !sync.proofs.awaiting.isEmpty { return .proofs }
        if !sync.pending.entries.isEmpty { return .headers }
        return .atTip
    }
}
