import Ivy

/// Overlay bootstrap peers the binary ships for the root chain, so a fresh
/// node joins the network with no flags and always has a peer source an
/// attacker cannot choose.
///
/// These are a DISCOVERY convenience and nothing more. A default peer gets no
/// trust, no validation shortcut, and no fork-choice influence: it enters
/// `IvyConfig.bootstrapPeers`, the very same field an operator-supplied
/// `--peer` enters, so one serving a bad chain is dropped exactly like any
/// other stranger. Nothing here is consensus.
///
/// Ivy owns the dialing. A configured peer is re-dialled for the life of the
/// process under Ivy's exponential backoff, so losing a default peer is
/// temporary rather than permanent, and defaults need no reconnect machinery
/// of their own.
public enum DefaultBootstrapPeers {
    /// The public Nexus overlay, as deployed. `deploy/read-replica/entrypoint.sh`
    /// carries this COMPLETE set and is the drift anchor the tests check
    /// against; `deploy/testnet-follower/fly.toml` corroborates the three
    /// backbones, and correctly omits the follower itself — a host must not
    /// dial its own identity.
    ///
    /// Hostnames rather than IP literals, so a host that moves stays
    /// reachable. The first three are the mainnet backbone and today resolve
    /// into one 137.66.0.0/16 netgroup; the fourth is the public follower in a
    /// different /16, so the set is neither a single host nor a single
    /// netgroup. Wider address diversity is a deployment question — hosts off
    /// this provider — not a code one.
    public static let nexus: [PeerEndpoint] = [
        PeerEndpoint(
            publicKey: "139b8f3639e7c515417c63bd3a652a5c6fd4a1a2d0baed8e33ea63047995fe64",
            host: "lattice-mainnet-iad.fly.dev",
            port: 4001
        ),
        PeerEndpoint(
            publicKey: "35edf67bfe3d612aeb1f0e25da9d3f0ced44dbf79d34f00c548cf9005be6eb7d",
            host: "lattice-mainnet-ams.fly.dev",
            port: 4001
        ),
        PeerEndpoint(
            publicKey: "9cace839489acb30385a9f20025cb9d6365283c81dce14cadab26507065acd4e",
            host: "lattice-mainnet-sjc.fly.dev",
            port: 4001
        ),
        PeerEndpoint(
            publicKey: "57f80deb3b00da1b14b630638a4d0307be98126ec1d550476e4889087bb22d0f",
            host: "lattice-mainnet-testnet.fly.dev",
            port: 4001
        ),
    ]

    /// The overlay bootstrap peers a process starts with.
    ///
    /// `configured` is the operator's peer source and is authoritative
    /// whenever it exists: a supplied list REPLACES the defaults (the two are
    /// never merged) and an explicitly empty list means "no bootstrap peers".
    /// Only `nil` — no peer source configured at all — falls back to the
    /// built-ins.
    ///
    /// The defaults are the ROOT chain's. A child chain that configures
    /// nothing gets nothing: seeding a child's overlay with Nexus backbone
    /// addresses would populate its peer set with processes that do not carry
    /// the child's chain at all, masking the same-chain peers it needs.
    public static func resolved(
        chainPath: [String],
        configured: [PeerEndpoint]?
    ) -> [PeerEndpoint] {
        if let configured { return configured }
        guard ChainAddress(chainPath)?.isNexus == true else { return [] }
        return nexus
    }
}
