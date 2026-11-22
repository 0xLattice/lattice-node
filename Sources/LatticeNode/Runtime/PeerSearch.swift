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

/// How a hosted child level's peers are recognised: by the claim in their
/// hello, and by the level's rendezvous. Nexus has none.
public struct ChainHosts: Hashable, Sendable {
    let path: ChainPath
    let key: String

    public init(nexusGenesisCID: String, chainPath: ChainPath) {
        path = chainPath
        key = ChainPeersKey.key(nexusGenesisCID: nexusGenesisCID, chainPath: chainPath)
    }

    /// The hosts a read of the chain at `path` asks first: a child chain's
    /// own; none for Nexus, whose peers all host it.
    static func of(_ path: ChainPath, nexusGenesisCID: String) -> ChainHosts? {
        path.count > 1 ? ChainHosts(nexusGenesisCID: nexusGenesisCID, chainPath: path) : nil
    }
}
