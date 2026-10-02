import Lattice
import UInt256

/// Per-peer sync state: at most one request of each kind in flight, each
/// with a deadline. A deadline that passes disconnects the peer.
public struct PeerSync: Sendable, Equatable {
    /// The `getStream` page in flight.
    public internal(set) var stream: InFlightStream?
    /// The last page said more follows.
    public internal(set) var more = false
    /// The last position of the peer's log taken, and the entries taken that
    /// are not yet applied (at most a page): the cursor stays before the
    /// first of them.
    public internal(set) var taken: UInt64 = 0
    public internal(set) var holes: [StreamEntry] = []
    /// The last position whose object was asked for.
    public internal(set) var requested: UInt64 = 0
    /// The objects asked of this peer (`getData`).
    public internal(set) var data: InFlightData?
    /// This peer read our log to its end: we push what we append.
    public internal(set) var subscribed = false
    /// The ancestors asked for by CID (a parent this peer's header named).
    public internal(set) var parentRequest: InFlightHeader?
    /// The child index asked for by CID (one wait per peer).
    public internal(set) var childIndex: InFlightFetch?
    /// The token of the answer the shell is still sending to this peer: one
    /// at a time.
    public internal(set) var serving: UInt64?
    /// Requests that arrived while `serving` was being sent, in order (at
    /// most one of each kind: an honest peer has no more in flight).
    public internal(set) var queued: [SyncMessage] = []

    public init() {}

    public static func == (lhs: PeerSync, rhs: PeerSync) -> Bool {
        lhs.stream == rhs.stream && lhs.more == rhs.more && lhs.taken == rhs.taken
            && lhs.holes == rhs.holes && lhs.requested == rhs.requested
            && lhs.data == rhs.data && lhs.subscribed == rhs.subscribed
            && lhs.parentRequest == rhs.parentRequest
            && lhs.childIndex == rhs.childIndex && lhs.serving == rhs.serving
            && lhs.queued.count == rhs.queued.count
    }

    var deadlines: [Int64] {
        [stream?.deadline, data?.deadline, parentRequest?.deadline, childIndex?.deadline].compactMap { $0 }
    }
}

public struct InFlightStream: Sendable, Equatable {
    public let requestID: UInt64
    public let deadline: Int64
}

public struct InFlightData: Sendable, Equatable {
    public let requestID: UInt64
    public let cids: [String]
    public let deadline: Int64
}

public struct InFlightHeader: Sendable, Equatable {
    public let requestID: UInt64
    public let cid: String
    public let deadline: Int64
}

public struct InFlightFetch: Sendable, Equatable {
    public let cid: String
    public let deadline: Int64
}

/// A binary heap under `precedes`, with lazy deletion left to the caller
/// (a popped element is checked against the live state).
struct Heap<Element: Sendable>: Sendable {
    private var items: [Element] = []
    let precedes: @Sendable (Element, Element) -> Bool

    init(_ precedes: @escaping @Sendable (Element, Element) -> Bool) {
        self.precedes = precedes
    }

    var count: Int { items.count }
    var first: Element? { items.first }

    /// Rebuild the heap from the elements `keep` accepts (drops stale ones).
    mutating func compact(_ keep: (Element) -> Bool) {
        let live = items.filter(keep)
        items = []
        for item in live { push(item) }
    }

    mutating func push(_ item: Element) {
        items.append(item)
        var child = items.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard precedes(items[child], items[parent]) else { break }
            items.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> Element? {
        guard !items.isEmpty else { return nil }
        items.swapAt(0, items.count - 1)
        let top = items.removeLast()
        var parent = 0
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var first = parent
            if left < items.count, precedes(items[left], items[first]) { first = left }
            if right < items.count, precedes(items[right], items[first]) { first = right }
            guard first != parent else { break }
            items.swapAt(parent, first)
            parent = first
        }
        return top
    }
}

/// A header whose proof-of-work verified but that is not connected yet: its
/// parent is not weighed, its child index is not in hand, or its timestamp
/// is in this node's (bounded) future.
public struct PendingHeader: Sendable {
    public let blockCID: String
    public let block: Block
    public internal(set) var children: ChildIndex?
    /// Its achieved proof-of-work hash: small means real work.
    public let hash: UInt256
    public internal(set) var bytes: Int
    /// Every live peer that sent it, first first: the first is asked for its
    /// parent and its child index.
    public internal(set) var announcers: [PeerID]
    /// Whether its parent was already asked of the first announcer.
    public internal(set) var askedParent = false
    /// Not before this time: a header from this node's future.
    public internal(set) var notBefore: Int64?
    /// A child header's verified grinds and their proofs, by root (it enters
    /// the queue with one).
    public internal(set) var evidence: [String: VerifiedChildEvidence] = [:]
    public internal(set) var proofs: [String: ChildBlockProof] = [:]

    var parent: String? { block.parent?.rawCID }
    var source: PeerID? { announcers.first }
}

/// The headers not yet weighed, under an operator byte budget. Weighed
/// headers never live here, so nothing weighed is ever evicted. Every
/// structure is incremental: pending children per parent, each header's
/// priority (the smallest hash in its pending subtree, so a queued child
/// lifts its parent), and a heap of evictable leaves.
public struct PendingQueue: Sendable {
    public internal(set) var entries: [String: PendingHeader] = [:]
    public internal(set) var bytes = 0
    /// Pending children, keyed by the parent CID (held or not).
    var childrenOf: [String: Set<String>] = [:]
    /// Pending headers by the child index CID they commit.
    var byChildIndex: [String: Set<String>] = [:]
    var priority: [String: UInt256] = [:]
    /// Evictable leaves by hash, largest first (decision 12). Stale entries
    /// are skipped.
    var leaves = Heap<(hash: UInt256, cid: String)> {
        $0.hash != $1.hash ? $0.hash > $1.hash : $0.cid > $1.cid
    }

    /// Each header's priority: the smallest hash among it and its pending
    /// descendants.
    public func priorities() -> [String: UInt256] { priority }

    /// The pending headers committing child index `cid`.
    func committing(_ cid: String) -> [PendingHeader] {
        (byChildIndex[cid] ?? []).sorted().compactMap { entries[$0] }
    }

    func isLeaf(_ cid: String) -> Bool { childrenOf[cid]?.isEmpty ?? true }

    mutating func insert(_ header: PendingHeader) {
        let cid = header.blockCID
        entries[cid] = header
        bytes += header.bytes
        byChildIndex[header.block.children.rawCID, default: []].insert(cid)
        priority[cid] = min(header.hash, childrenOf[cid].map(lowestPriority) ?? .max)
        if isLeaf(cid) { leaves.push((header.hash, cid)) }
        if let parent = header.parent {
            childrenOf[parent, default: []].insert(cid)
            lift(from: parent)
        }
    }

    mutating func remove(_ cid: String) {
        guard let removed = entries.removeValue(forKey: cid) else { return }
        bytes -= removed.bytes
        priority[cid] = nil
        let children = removed.block.children.rawCID
        byChildIndex[children]?.remove(cid)
        if byChildIndex[children]?.isEmpty == true { byChildIndex[children] = nil }
        if let parent = removed.parent {
            childrenOf[parent]?.remove(cid)
            if childrenOf[parent]?.isEmpty == true { childrenOf[parent] = nil }
            if let held = entries[parent] {
                if isLeaf(parent) { leaves.push((held.hash, parent)) }
                lift(from: parent)
            }
        }
    }

    mutating func setChildren(_ children: ChildIndex, of cid: String, bytes size: Int) {
        guard entries[cid] != nil, entries[cid]?.children == nil else { return }
        entries[cid]?.children = children
        entries[cid]?.bytes += size
        bytes += size
    }

    private func lowestPriority(_ children: Set<String>) -> UInt256 {
        children.compactMap { priority[$0] }.min() ?? .max
    }

    /// Recompute priorities from `cid` up its pending ancestors while they
    /// change.
    private mutating func lift(from cid: String) {
        var current: String? = cid
        while let hash = current, let header = entries[hash] {
            let updated = min(header.hash, childrenOf[hash].map(lowestPriority) ?? .max)
            guard updated != priority[hash] else { return }
            priority[hash] = updated
            current = header.parent
        }
    }

    /// Evict while over `budget`: the pending leaf with the largest hash, so a parent is never evicted from under a child that
    /// lifts it. Returns the evicted headers.
    mutating func evict(to budget: Int) -> [PendingHeader] {
        var evicted: [PendingHeader] = []
        while bytes > budget, let top = leaves.pop() {
            guard let header = entries[top.cid], isLeaf(top.cid), header.hash == top.hash else { continue }
            remove(top.cid)
            evicted.append(header)
        }
        return evicted
    }

    /// Drop stale heap entries once they outnumber the live ones.
    mutating func compact() {
        guard leaves.count > 2 * entries.count + 8 else { return }
        var seen = Set<String>()
        let entries = self.entries
        let childrenOf = self.childrenOf
        leaves.compact { item in
            guard let header = entries[item.cid], childrenOf[item.cid]?.isEmpty ?? true,
                  header.hash == item.hash else { return false }
            return seen.insert(item.cid).inserted
        }
    }
}

/// The weighed graph as sync reads it, maintained as headers are weighed:
/// every header and its parent.
public struct WeighedIndex: Sendable {
    var parent: [String: String] = [:]
    var members: Set<String> = []
    /// Leaves: headers with no weighed child.
    public internal(set) var leaves: Set<String> = []

    mutating func add(_ cid: String, parent: String?) {
        guard members.insert(cid).inserted else { return }
        if let parent {
            self.parent[cid] = parent
            leaves.remove(parent)
        }
        leaves.insert(cid)
    }

    func contains(_ cid: String) -> Bool { members.contains(cid) }
}

/// Header sync for one level: which peers are asked for what, and the
/// headers not yet weighed. Every per-peer map is keyed by a live `PeerID`,
/// and dropping a peer clears it at once.
public struct Sync: Sendable {
    public internal(set) var peers: [PeerID: PeerSync] = [:]
    public internal(set) var pending = PendingQueue()
    /// A child level's proof work: headers awaiting a proof, and checks in
    /// flight.
    public internal(set) var proofs = ProofSync()
    /// The pending headers each peer announced.
    var announced: [PeerID: Set<String>] = [:]
    /// Headers waiting for a free request slot of their first announcer,
    /// each queued once per slot.
    var wants: [WantSlot: Heap<(priority: UInt256, cid: String)>] = [:]
    var wanting: [WantSlot: Set<String>] = [:]
    /// Held headers from this node's future, by time.
    var held = Heap<(time: Int64, cid: String)> { $0.time != $1.time ? $0.time < $1.time : $0.cid < $1.cid }
    var nextRequestID: UInt64 = 1
    var nextToken: UInt64 = 1
    /// This node's weigh log, which peers stream.
    public internal(set) var log = WeighLog()
    /// Per peer key: the last position of its log received and applied.
    /// Written with the facts (`PersistBatch.cursors`) and handed back to
    /// `Core.init`; kept only for connected peers and those handed back.
    public internal(set) var cursors: [String: StreamCursor] = [:]
    var knownCursors: Set<String> = []

    public init() {}

    /// Remove a pending header and every reference to it.
    mutating func removePending(_ cid: String) {
        guard let header = pending.entries[cid] else { return }
        for peer in header.announcers { announced[peer]?.remove(cid) }
        pending.remove(cid)
    }

    mutating func evict(to budget: Int) {
        for header in pending.evict(to: budget) {
            for peer in header.announcers { announced[peer]?.remove(header.blockCID) }
        }
    }

    /// Drop stale entries of every lazy heap once they outnumber the live
    /// ones, so bookkeeping stays O(pending).
    mutating func compact() {
        pending.compact()
        let live = pending.entries.count
        let entries = pending.entries
        if held.count > 2 * live + 8 {
            held.compact { entries[$0.cid]?.notBefore == $0.time }
        }
        for (slot, heap) in wants where heap.count > 2 * live + 8 {
            var heap = heap
            heap.compact { entries[$0.cid]?.source == slot.peer }
            wants[slot] = heap.count == 0 ? nil : heap
            wanting[slot] = wanting[slot]?.filter { entries[$0]?.source == slot.peer }
        }
    }

    /// Entries in the lazy heaps and announcement sets: O(pending).
    public var bookkeeping: Int {
        pending.leaves.count + held.count + wants.values.reduce(0) { $0 + $1.count }
            + announced.values.reduce(0) { $0 + $1.count }
    }

    /// The earliest time after `now` the core must wake for.
    func nextDeadline(after now: Int64) -> Int64? {
        let requests = peers.values.flatMap(\.deadlines)
        let times = requests + [held.first?.time].compactMap { $0 }
        return times.filter { $0 > now && $0 != .max }.min()
    }
}

/// One request slot of one peer: its ancestors request or its child-index
/// wait.
struct WantSlot: Hashable, Sendable {
    let peer: PeerID
    let parent: Bool
}
