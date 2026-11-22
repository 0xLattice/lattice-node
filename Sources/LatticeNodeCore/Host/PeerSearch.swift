/// When to look for more peers, per hosted level: a level that has not
/// progressed since boot, or not for a whole interval, is due a search of its
/// own rendezvous, at most once per interval. Peers that host another level
/// cannot sync this one, so each level finds its own.
public struct PeerSearch: Sendable {
    public init() {}

    private var highWater: [ChainPath: UInt64] = [:]
    private var lastProgressAt: [ChainPath: Int64] = [:]
    private var lastSearchAt: [ChainPath: Int64] = [:]
    private var lastTopUpAt: [ChainPath: Int64] = [:]

    /// The levels due a search now, given each level's act-on height. A
    /// level seen for the first time has not progressed yet: it is due at once.
    /// Without a connected peer no lookup can reach the DHT, so nothing is due
    /// and no search is spent.
    public mutating func due(
        heights: [(path: ChainPath, height: UInt64)], now: Int64, interval: Int64, connected: Bool
    ) -> [ChainPath] {
        var due: [ChainPath] = []
        for (path, height) in heights {
            if let previous = highWater[path], height > previous {
                lastProgressAt[path] = now
            }
            highWater[path] = max(highWater[path] ?? height, height)
            guard interval > 0, connected else { continue }
            let stalled = lastProgressAt[path].map { now - $0 >= interval } ?? true
            let rested = now - (lastSearchAt[path] ?? .min / 2) >= interval
            if stalled && rested {
                lastSearchAt[path] = now
                due.append(path)
            }
        }
        return due
    }

    /// The levels that may look up their rendezvous for more peers now, when
    /// short of the target: each at most once per interval, however often
    /// new sessions start a pass, so a level whose whole network is smaller
    /// than the target does not search on every pass. A level's peers grow
    /// from the lookups' fresh samples, not only from the first few found.
    public mutating func topUps(paths: [ChainPath], now: Int64, interval: Int64, connected: Bool) -> Set<ChainPath> {
        guard interval > 0, connected else { return [] }
        var allowed = Set<ChainPath>()
        for path in paths where now - (lastTopUpAt[path] ?? .min / 2) >= interval {
            lastTopUpAt[path] = now
            allowed.insert(path)
        }
        return allowed
    }
}

/// The keys of the peers connected now hosting each chain. A key entering
/// (a host connecting, or reconnecting) is when a chain's waiting bodies
/// are asked for again (`ChainEvent.providerJoined`).
public struct ConnectedHosts: Sendable {
    public var keys: [ChainPath: Set<String>] = [:]

    /// `path`'s hosts are now `current`: true when one of them was not
    /// connected before.
    public init() {}

    public mutating func update(_ path: ChainPath, _ current: Set<String>) -> Bool {
        defer { keys[path] = current }
        return !current.isSubset(of: keys[path] ?? [])
    }
}
