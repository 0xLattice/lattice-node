import Lattice
import UInt256

/// Per-peer sync state: at most one request of each kind in flight, each
/// with a deadline. A deadline that passes disconnects the peer.
public struct PeerSync: Sendable, Equatable {
    /// The catch-up page in flight.
    public internal(set) var catchUp: InFlightPage?
    /// The header asked for by CID (a parent this peer's header named).
    public internal(set) var parentRequest: InFlightHeader?
    /// The child index asked for by CID (one wait per peer).
    public internal(set) var childIndex: InFlightFetch?
    /// The token of the answer the shell is still sending to this peer: one
    /// at a time.
    public internal(set) var serving: UInt64?
    /// Requests that arrived while `serving` was being sent, in order (at
    /// most one of each kind: an honest peer has no more in flight).
    public internal(set) var queued: [SyncMessage] = []
    /// When to ask this peer for a catch-up again (the repair path).
    public internal(set) var nextCatchUp: Int64 = .max

    public init() {}

    public static func == (lhs: PeerSync, rhs: PeerSync) -> Bool {
        lhs.catchUp == rhs.catchUp && lhs.parentRequest == rhs.parentRequest
            && lhs.childIndex == rhs.childIndex && lhs.serving == rhs.serving
            && lhs.queued.count == rhs.queued.count && lhs.nextCatchUp == rhs.nextCatchUp
    }

    var deadlines: [Int64] {
        [catchUp?.deadline, parentRequest?.deadline, childIndex?.deadline].compactMap { $0 }
    }
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

/// A header whose proof-of-work verified but that is not weighed yet: its
/// parent is not weighed, its branch is under the anti-DoS work threshold,
/// its child index is not in hand, or its timestamp is in this node's future.
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
    /// Its branch's cumulative work: the fork point's chain work plus its
    /// pending ancestors' and its own. Nil until it links to the weighed graph.
    public internal(set) var chainWork: WorkSum?
    /// On a branch a descendant carried over the threshold.
    public internal(set) var eligible = false

    var parent: String? { block.parent?.rawCID }
    var source: PeerID? { announcers.first }
    var work: UInt256 { workForTarget(block.target) }
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
    /// Leaves by hash, largest first (stale entries are skipped).
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

    /// Evict while over `budget`: the pending leaf with the largest hash
    /// first, so a parent is never evicted from under a child that lifts it.
    /// Returns the evicted headers.
    @discardableResult
    mutating func evict(to budget: Int) -> [PendingHeader] {
        var evicted: [PendingHeader] = []
        while bytes > budget, let top = leaves.pop() {
            guard let header = entries[top.cid], isLeaf(top.cid) else { continue }
            remove(top.cid)
            evicted.append(header)
        }
        return evicted
    }
}

/// The weighed graph as sync reads it, maintained as headers are weighed:
/// every header by (height, CID), its parent, and its chain work.
public struct WeighedIndex: Sendable {
    /// CIDs at each height, sorted. Heights are contiguous from genesis.
    var byHeight: [[String]] = []
    var parent: [String: String] = [:]
    var height: [String: UInt64] = [:]
    var chainWork: [String: WorkSum] = [:]
    /// Leaves: headers with no weighed child.
    public internal(set) var leaves: Set<String> = []

    mutating func add(_ cid: String, parent: String?, height: UInt64, work: UInt256) {
        guard self.height[cid] == nil else { return }
        while byHeight.count <= Int(height) { byHeight.append([]) }
        let row = byHeight[Int(height)]
        byHeight[Int(height)].insert(cid, at: row.firstIndex { $0 > cid } ?? row.count)
        self.height[cid] = height
        let base = parent.flatMap { chainWork[$0] } ?? .zero
        chainWork[cid] = base + work
        if let parent {
            self.parent[cid] = parent
            leaves.remove(parent)
        }
        leaves.insert(cid)
    }

    func contains(_ cid: String) -> Bool { height[cid] != nil }

    public func chainWork(of cid: String) -> WorkSum? { chainWork[cid] }

    func key(_ cid: String) -> HeaderKey? {
        height[cid].map { HeaderKey(height: $0, cid: cid) }
    }

    /// The ancestor of `cid` at `target` height, walking parents.
    func ancestor(of cid: String, atHeight target: UInt64) -> String? {
        var current = cid
        while let h = height[current], h > target {
            guard let up = parent[current] else { return nil }
            current = up
        }
        return height[current] == target ? current : nil
    }

    /// Headers in `HeaderKey` order from `start` (inclusive of its height,
    /// after its CID when `strictlyAfter`), as a lazy stream.
    func keys(from start: HeaderKey, strictlyAfter: Bool) -> AnySequence<HeaderKey> {
        let rows = byHeight
        return AnySequence { () -> AnyIterator<HeaderKey> in
            var height = Int(start.height)
            var column: Int = {
                guard height < rows.count else { return 0 }
                let row = rows[height]
                // Binary search the first CID at or after the start.
                var low = 0, high = row.count
                while low < high {
                    let middle = (low + high) / 2
                    if row[middle] < start.cid || (strictlyAfter && row[middle] == start.cid) {
                        low = middle + 1
                    } else {
                        high = middle
                    }
                }
                return low
            }()
            return AnyIterator {
                while height < rows.count {
                    if column < rows[height].count {
                        defer { column += 1 }
                        return HeaderKey(height: UInt64(height), cid: rows[height][column])
                    }
                    height += 1
                    column = 0
                }
                return nil
            }
        }
    }
}

/// Header sync for one level: which peers are asked for what, and the
/// headers not yet weighed. Every per-peer map is keyed by a live `PeerID`,
/// and dropping a peer clears it at once.
public struct Sync: Sendable {
    public internal(set) var peers: [PeerID: PeerSync] = [:]
    public internal(set) var pending = PendingQueue()
    /// The pending headers each peer announced.
    var announced: [PeerID: Set<String>] = [:]
    /// Headers waiting for a free request slot of their first announcer.
    var wants: [WantSlot: Heap<(priority: UInt256, cid: String)>] = [:]
    /// Held headers from this node's future, by time.
    var held = Heap<(time: Int64, cid: String)> { $0.time != $1.time ? $0.time < $1.time : $0.cid < $1.cid }
    var nextRequestID: UInt64 = 1
    var nextToken: UInt64 = 1
    /// How many index entries the last catch-up page examined: serving is
    /// O(page + locator × window), never O(graph).
    public internal(set) var lastServeScanned = 0

    public init() {}

    /// The earliest time after `now` the core must wake for.
    func nextDeadline(after now: Int64) -> Int64? {
        let requests = peers.values.flatMap { $0.deadlines + [$0.nextCatchUp] }
        let times = requests + [held.first?.time].compactMap { $0 }
        return times.filter { $0 > now && $0 != .max }.min()
    }
}

/// One request slot of one peer: its parent request or its child-index wait.
struct WantSlot: Hashable, Sendable {
    let peer: PeerID
    let parent: Bool
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
