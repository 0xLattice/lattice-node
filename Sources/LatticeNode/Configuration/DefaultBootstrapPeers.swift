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
/// The node owns the dialing, and asks a seed only on need. With no peers
/// configured, a node tries the peers it remembers first; these by name while
/// it still has fewer than two peers; and `nexusFixed`, the same seeds at
/// fixed addresses, if names cannot be resolved. A node that already knows
/// the network does not touch them, and a node left short of peers looks
/// again within seconds, so losing a seed is temporary.
public enum DefaultBootstrapPeers {
    /// The public Nexus overlay's seeds: the project's own names, each pinned
    /// to the identity of the host behind it.
    ///
    /// Names under `lattice.build`, not a hosting provider's: `seedN` is a
    /// DNS alias for whichever host serves that identity, so a host can move
    /// provider or region with a DNS change and no release. A name alone
    /// grants nothing: a seed is dialled by name and accepted by key, so
    /// whoever answers at the name without the pinned key is refused.
    ///
    /// `deploy/read-replica/entrypoint.sh` carries this COMPLETE set and is
    /// the drift anchor the tests check against.
    ///
    /// Today `seed1`-`seed3` are the mainnet backbone, in one 137.66.0.0/16
    /// netgroup; `seed4` is the public follower in a different /16, so the set
    /// is neither a single host nor a single netgroup. Wider address
    /// diversity is a deployment question, not a code one.
    public static let nexus: [PeerEndpoint] = [
        PeerEndpoint(
            publicKey: "139b8f3639e7c515417c63bd3a652a5c6fd4a1a2d0baed8e33ea63047995fe64",
            host: "seed1.lattice.build",
            port: 4001
        ),
        PeerEndpoint(
            publicKey: "35edf67bfe3d612aeb1f0e25da9d3f0ced44dbf79d34f00c548cf9005be6eb7d",
            host: "seed2.lattice.build",
            port: 4001
        ),
        PeerEndpoint(
            publicKey: "9cace839489acb30385a9f20025cb9d6365283c81dce14cadab26507065acd4e",
            host: "seed3.lattice.build",
            port: 4001
        ),
        PeerEndpoint(
            publicKey: "57f80deb3b00da1b14b630638a4d0307be98126ec1d550476e4889087bb22d0f",
            host: "seed4.lattice.build",
            port: 4001
        ),
    ]

    /// The same seeds at fixed addresses, for when their names cannot be
    /// resolved: the last resort, as Bitcoin Core's fixed seeds are behind
    /// its DNS seeds. A node dials these only while it still has too few
    /// peers after the ones it remembers and the named seeds, so a DNS
    /// outage, or a zone that is taken away, does not cut new nodes off.
    ///
    /// These are each host's dedicated address today. Unlike a name they
    /// cannot follow a host that moves, so they are refreshed with a release;
    /// a stale one costs a failed dial and nothing else. The identities are
    /// the named seeds' own: a fixed address is accepted by the same key.
    public static let nexusFixed: [PeerEndpoint] = [
        PeerEndpoint(
            publicKey: "139b8f3639e7c515417c63bd3a652a5c6fd4a1a2d0baed8e33ea63047995fe64",
            host: "137.66.36.149",
            port: 4001
        ),
        PeerEndpoint(
            publicKey: "35edf67bfe3d612aeb1f0e25da9d3f0ced44dbf79d34f00c548cf9005be6eb7d",
            host: "137.66.14.188",
            port: 4001
        ),
        PeerEndpoint(
            publicKey: "9cace839489acb30385a9f20025cb9d6365283c81dce14cadab26507065acd4e",
            host: "137.66.16.78",
            port: 4001
        ),
        PeerEndpoint(
            publicKey: "57f80deb3b00da1b14b630638a4d0307be98126ec1d550476e4889087bb22d0f",
            host: "169.155.61.57",
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

    /// Environment variable that test and CI runs set to `1` so a node that
    /// would fall back to the built-in peers refuses to start instead of
    /// joining the public network. Unset, nothing changes.
    public static let forbidEnvironmentKey = "LATTICE_FORBID_DEFAULT_PEERS"

    /// True when `configured` (as passed to `resolved`) would select the
    /// built-in peers while `environment` forbids them.
    public static func forbidden(
        configured: [PeerEndpoint]?,
        environment: [String: String]
    ) -> Bool {
        configured == nil && environment[forbidEnvironmentKey] == "1"
    }
}
