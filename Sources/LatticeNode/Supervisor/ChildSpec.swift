import Foundation

/// The lattice-node-specific description of a child chain process to spawn.
/// Every field is derived by the parent at deploy time — deterministic ports,
/// the genesis it just built, its own P2P address — so a supervised child needs
/// no manual port/genesis/peer wiring. The argument vector mirrors what the
/// SmokeTests harness builds today (`lib/lattice.mjs spawnChild`), so a
/// supervised child is boot-identical to a manually-launched one.
public struct ChildSpec: Sendable, Equatable {
    public let directory: String
    public let chainPath: [String]
    public let genesisHex: String
    /// Parent chain P2P address for block extraction: `<pubkey>@host:port`.
    public let subscribeP2P: String
    /// Parent chain gossip endpoint to bootstrap the child's own gossip (`--peer`).
    public let bootstrapPeer: String?
    /// Child chain P2P port (deterministic from the parent base port + directory).
    public let port: UInt16
    /// Child RPC port (deterministic from the parent RPC base + directory).
    public let rpcPort: UInt16
    public let dataDir: String
    /// Public payout address to credit in the child's block-template coinbase, inherited from
    /// the parent node's `--coinbase-address`. nil → the child mines an empty-reward template
    /// (forfeiting its block reward), so this must be set for a child to earn its reward.
    public let coinbaseAddress: String?
    /// Config the child inherits from the parent (e.g. `--min-peer-key-bits`),
    /// already expressed as argv pairs.
    public let inheritedArguments: [String]

    public init(
        directory: String,
        chainPath: [String],
        genesisHex: String,
        subscribeP2P: String,
        bootstrapPeer: String?,
        port: UInt16,
        rpcPort: UInt16,
        dataDir: String,
        coinbaseAddress: String? = nil,
        inheritedArguments: [String] = []
    ) {
        self.directory = directory
        self.chainPath = chainPath
        self.genesisHex = genesisHex
        self.subscribeP2P = subscribeP2P
        self.bootstrapPeer = bootstrapPeer
        self.port = port
        self.rpcPort = rpcPort
        self.dataDir = dataDir
        self.coinbaseAddress = coinbaseAddress
        self.inheritedArguments = inheritedArguments
    }

    /// The argument vector (excluding argv[0]) for `lattice-node`. Leads with the
    /// explicit `node` subcommand to match the harness invocation exactly rather
    /// than relying on it being the default subcommand. `inheritedArguments`
    /// carries the parent's namespace-independent policy (`--no-dns-seeds`,
    /// `--min-fee-rate`, `--min-peer-key-bits`). `--coinbase-address` is passed so the child
    /// claims its block reward (without it the child mines empty-reward templates).
    public func arguments() -> [String] {
        var args: [String] = [
            "node",
            "--genesis-hex", genesisHex,
            "--chain-directory", directory,
            "--chain-path", chainPath.joined(separator: "/"),
            "--subscribe-p2p", subscribeP2P,
            "--port", String(port),
            "--rpc-port", String(rpcPort),
            "--data-dir", dataDir,
        ]
        if let bootstrapPeer { args += ["--peer", bootstrapPeer] }
        if let coinbaseAddress { args += ["--coinbase-address", coinbaseAddress] }
        args += inheritedArguments
        return args
    }

    /// Build the generic launch description for the supervisor.
    public func launch(nodeExecutable: URL) -> SupervisedLaunch {
        SupervisedLaunch(label: directory, executableURL: nodeExecutable, arguments: arguments())
    }
}
