import Lattice
import UInt256

/// Per-peer sync state: at most one request of each kind in flight, each
/// with a deadline. A deadline that passes disconnects the peer.
public struct PeerSync: Sendable, Equatable {
    /// The catch-up page in flight.
    public internal(set) var catchUp: InFlightPage?
    /// The header asked for by CID (a parent this peer's header named).
    public internal(set) var parentRequest: InFlightHeader?
    /// The catch-up page served to this peer that the shell has not finished
    /// sending: one at a time.
    public internal(set) var serving: UInt64?
    /// The peer's next catch-up request, served once `serving` is sent.
    public internal(set) var queued: HeadersRequest?

    public init() {}
}

public struct InFlightPage: Sendable, Equatable {
    public let requestID: UInt64
    public let after: HeaderKey?
    public let deadline: Int64
}

public struct InFlightHeader: Sendable, Equatable {
    public let requestID: UInt64
    public let cid: String
    public let deadline: Int64
}

/// A child index fetch by CID, from one peer.
public struct AwaitingChildIndex: Sendable, Equatable {
    public let peer: PeerID
    public let deadline: Int64
}

/// A header whose proof-of-work verified but that is not weighed yet: its
/// parent is not weighed, its child index is not in hand, or its timestamp is
/// in this node's future.
public struct PendingHeader: Sendable {
    public let blockCID: String
    public let block: Block
    public internal(set) var children: ChildIndex?
    /// Its achieved proof-of-work hash: small means real work.
    public let hash: UInt256
    public internal(set) var bytes: Int
    /// The peer asked for its parent and its child index.
    public internal(set) var source: PeerID
    /// Whether its parent was already asked of `source`.
    public internal(set) var askedParent = false
    /// Not before this time: a header from this node's future.
    public internal(set) var notBefore: Int64?

    var parent: String? { block.parent?.rawCID }
}

/// The headers not yet weighed, under an operator byte budget. Weighed
/// headers never live here, so nothing weighed is ever evicted.
public struct PendingQueue: Sendable {
    public internal(set) var entries: [String: PendingHeader] = [:]
    public internal(set) var bytes = 0

    mutating func insert(_ header: PendingHeader) {
        entries[header.blockCID] = header
        bytes += header.bytes
    }

    mutating func remove(_ cid: String) {
        guard let removed = entries.removeValue(forKey: cid) else { return }
        bytes -= removed.bytes
    }

    mutating func setChildren(_ children: ChildIndex, of cid: String, bytes size: Int) {
        guard entries[cid]?.children == nil else { return }
        entries[cid]?.children = children
        entries[cid]?.bytes += size
        bytes += size
    }

    /// Evict while over `budget`: the pending leaf (no pending child) with
    /// the largest hash first. A header's priority is the smallest hash in
    /// its pending subtree, so a leaf holds the largest priority on its path
    /// and a parent is never evicted from under a child that lifts it.
    mutating func evict(to budget: Int) {
        while bytes > budget {
            let parents = Set(entries.values.compactMap(\.parent))
            guard let victim = entries.values
                .filter({ !parents.contains($0.blockCID) })
                .max(by: { $0.hash != $1.hash ? $0.hash < $1.hash : $0.blockCID < $1.blockCID })
            else { return }
            remove(victim.blockCID)
        }
    }

    /// Each header's priority: the smallest hash among it and its pending
    /// descendants, so a queued child lifts its parent.
    public func priorities() -> [String: UInt256] {
        var priority = entries.mapValues(\.hash)
        var pendingChildren: [String: Int] = [:]
        for header in entries.values {
            if let parent = header.parent, entries[parent] != nil {
                pendingChildren[parent, default: 0] += 1
            }
        }
        var ready = entries.keys.filter { pendingChildren[$0] == nil }
        while let cid = ready.popLast() {
            guard let parent = entries[cid]?.parent, entries[parent] != nil else { continue }
            priority[parent] = min(priority[parent]!, priority[cid]!)
            pendingChildren[parent]! -= 1
            if pendingChildren[parent] == 0 { ready.append(parent) }
        }
        return priority
    }
}

/// Header sync for one level: which peers are asked for what, and the
/// headers not yet weighed. Every per-peer map is keyed by a live `PeerID`,
/// and dropping a peer clears it at once.
public struct Sync: Sendable {
    public internal(set) var peers: [PeerID: PeerSync] = [:]
    /// Keyed by the child index CID.
    public internal(set) var awaitingChildIndex: [String: AwaitingChildIndex] = [:]
    public internal(set) var pending = PendingQueue()
    var nextRequestID: UInt64 = 1

    public init() {}

    /// Forget everything about `peer`.
    mutating func drop(_ peer: PeerID) {
        peers[peer] = nil
        awaitingChildIndex = awaitingChildIndex.filter { $0.value.peer != peer }
    }

    /// The earliest time after `now` the core must wake for.
    func nextDeadline(after now: Int64) -> Int64? {
        let requests = peers.values.flatMap {
            [$0.catchUp?.deadline, $0.parentRequest?.deadline].compactMap { $0 }
        }
        let fetches = awaitingChildIndex.values.map(\.deadline)
        let held = pending.entries.values.compactMap(\.notBefore).filter { $0 > now }
        return (requests + fetches + held).min()
    }
}

extension ChainTree {
    /// The deepest block on the best header chain whose ancestry is executed
    /// from genesis: the tip a node acts on. The executed blocks on one path
    /// are a prefix of it, so this is a binary search over heights.
    func actOnTip() -> (hash: String, height: UInt64) {
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
