import Lattice

/// Per-peer header-sync state.
public struct PeerSync: Sendable, Equatable {
    /// The one `getHeaders` in flight to this peer, and when it expires.
    public internal(set) var inFlight: InFlightHeaders?
    /// The last block this peer announced.
    public internal(set) var announcedTip: String?
    /// Consecutive header pages whose first header did not connect.
    public internal(set) var unconnecting: Int = 0
    /// When to ask this peer again without a request in flight.
    public internal(set) var retryAt: Int64?
    /// The height the current exchange last continued from.
    public internal(set) var continuationHeight: UInt64?
    /// The continuation point of an exchange ended for making no progress,
    /// kept for the retry that resumes it.
    public internal(set) var stalledHeight: UInt64?
    /// A page served to this peer that the shell has not finished sending.
    public internal(set) var serving = false

    public init() {}
}

public struct InFlightHeaders: Sendable, Equatable {
    public let requestID: UInt64
    public let deadline: Int64
}

/// A header whose page omitted its `ChildIndex`, waiting for the bytes by CID.
public struct AwaitingChildIndex: Sendable {
    public let blockCID: String
    public let block: Block
    public let peer: PeerID
    public let deadline: Int64
}

/// Header sync for one level: which peers are asked for what. Every map is
/// keyed by a live `PeerID`, and dropping a peer clears all of it at once.
public struct Sync: Sendable {
    public internal(set) var peers: [PeerID: PeerSync] = [:]
    /// Keyed by the child index CID.
    public internal(set) var awaitingChildIndex: [String: AwaitingChildIndex] = [:]
    var nextRequestID: UInt64 = 1

    public init() {}

    /// Forget everything about `peer`.
    mutating func drop(_ peer: PeerID) {
        peers[peer] = nil
        awaitingChildIndex = awaitingChildIndex.filter { $0.value.peer != peer }
    }

    /// The earliest deadline the core must wake for.
    var nextDeadline: Int64? {
        let requests = peers.values.compactMap { $0.inFlight?.deadline }
            + peers.values.compactMap(\.retryAt)
        let fetches = awaitingChildIndex.values.map(\.deadline)
        return (requests + fetches).min()
    }
}

extension ChainTree {
    /// The best header chain as a locator: the tip and its nine predecessors,
    /// then doubling steps back, always ending at genesis, capped at
    /// `HeadersRequest.maximumLocatorEntries`.
    func headerLocator() -> [String] {
        guard let tipHeight = headerSnapshot(of: canonicalTip)?.tipHeight else {
            return [canonicalTip]
        }
        var heights: [UInt64] = []
        var height = tipHeight
        var step: UInt64 = 1
        while heights.count < HeadersRequest.maximumLocatorEntries - 1 {
            heights.append(height)
            if height == 0 { break }
            if heights.count >= 10 { step *= 2 }
            height = height > step ? height - step : 0
        }
        if heights.last != 0 { heights.append(0) }
        return heights.compactMap { canonicalBlockHash(atHeight: $0) }
    }

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
