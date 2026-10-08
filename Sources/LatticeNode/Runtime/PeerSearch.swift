import LatticeNodeCore

/// The rendezvous for a hosted child level: every node hosting it announces
/// itself as a provider of this key, and a node looking for the level's peers
/// looks it up. Keyed by path, not genesis: a joiner knows the path before it
/// holds any block, and competing geneses share one rendezvous for fork
/// choice to settle. Scoped to the Nexus it runs under, so two networks
/// sharing a DHT never mix. Nexus has none: every node hosts it, so every
/// peer is one of its peers.
enum ChainPeersKey {
    static func key(nexusGenesisCID: String, chainPath: [String]) -> String {
        "lattice.chain-peers.v1:\(nexusGenesisCID):\(chainPath.joined(separator: "/"))"
    }
}

/// When to look for more peers, per hosted level: a level that has not
/// progressed since boot, or not for a whole interval, is due a search of its
/// own rendezvous, at most once per interval. Peers that host another level
/// cannot sync this one, so each level finds its own.
struct PeerSearch {
    private var highWater: [ChainPath: UInt64] = [:]
    private var lastProgressAt: [ChainPath: Int64] = [:]
    private var lastSearchAt: [ChainPath: Int64] = [:]

    /// The levels due a search now, given each level's act-on height. A
    /// level seen for the first time has not progressed yet: it is due at once.
    /// Without a connected peer no lookup can reach the DHT, so nothing is due
    /// and no search is spent.
    mutating func due(
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
}
