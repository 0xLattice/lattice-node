import Lattice
import Foundation
import Ivy

public let DEFAULT_RETENTION_DEPTH: UInt64 = 1000

public enum StorageMode: String, Sendable {
    case stateless
    case stateful
    case historical
}

public enum BlockRetention: String, Sendable {
    case tip
    case retention
    case historical
}

public struct LatticeNodeConfig: Sendable {
    public let publicKey: String

    /// Raw 32-byte hex public key for Ivy P2P identity (strips ed01 Multikey prefix).
    /// Ivy's identify protocol requires raw Ed25519 keys; Multikey peers are rejected
    /// by nodes running Ivy < 5.18.1.
    public var p2pPublicKey: String {
        if publicKey.hasPrefix("ed01") && publicKey.count == 68 {
            return String(publicKey.dropFirst(4))
        }
        return publicKey
    }
    public let privateKey: String
    public let listenPort: UInt16
    public let bootstrapPeers: [PeerEndpoint]
    public let storagePath: URL
    public let enableLocalDiscovery: Bool
    public let persistInterval: UInt64
    public let retentionDepth: UInt64
    public let resources: NodeResourceConfig
    /// Operational tunables (timeouts, caps, dedup windows, token-bucket rates,
    /// intervals). Node-local, never consensus-affecting — see `NodeTuning`.
    public let tuning: NodeTuning
    public let finality: FinalityConfig
    public let maxPeerConnections: Int
    public let discoveryOnly: Bool
    public let storageMode: StorageMode
    public let blockRetention: BlockRetention
    public let pinAnnounceExpiry: UInt64
    public let reannounceInterval: Duration
    public let evictionInterval: Duration
    public let pendingGossipBlockLimit: Int
    public let maxFrameSize: UInt32
    /// Node-local minimum fee RATE in units per serialized-body byte.
    /// Mempool admission / relay policy only — NOT a consensus rule.
    /// Defaults to 0 for programmatic nodes/tests; the CLI daemon default is 1.
    public let minFeeRate: UInt64
    public let isTestnet: Bool
    /// Full chain path from the PoW root, inclusive. E.g. ["Root","Mid","Stable"].
    /// Transactions submitted to this node use this as the expected validation path.
    /// Defaults to nil (uses specNode.directory only — correct for a root chain node).
    public let fullChainPath: [String]?

    /// Minimum proof-of-work bits a peer's identity key must carry to be admitted
    /// (/ Decision 15). Wired into every node-constructed `IvyConfig` so the
    /// Ivy handshake/endpoint-insert gate (Ivy.swift) rejects below-threshold
    /// Sybil identities, and used as the floor for the outbound `selectDiversePeers`
    /// candidate filter. The initializer default is the canonical non-zero
    /// `defaultMinPeerKeyBits` (Decision 15), so any node constructed without an
    /// explicit value still gets the secure gate; in-process test topologies of
    /// difficulty-0 keys opt out by passing `minPeerKeyBits: 0`. Configurable knob,
    /// not a hardcoded done-state.
    public let minPeerKeyBits: Int

    /// Canonical Decision-15 security default: the minimum peer key-PoW bits a
    /// production node requires for admission. Lives here (not only in the CLI) so
    /// the secure default is owned by the config layer; the CLI/daemon reference it.
    ///
    /// M3 (audit): 24 bits ≈ 2^24 key generations per identity (grinding
    /// is Curve25519-keygen bound, not hash bound — minutes of one-time work on
    /// commodity hardware), making bulk Sybil identity minting expensive while
    /// staying a one-time cost per persistent identity. The earlier raise attempt
    /// regressed startup because the parent-subscription Ivy key was reground on
    /// every subscription start; that key is now cached in the data dir
    /// (`parent-sub-identity.json`, BackgroundLoops.swift) so the grind is paid
    /// once per data dir, not per start. Dev/test topologies opt out explicitly:
    /// smoke (`--min-peer-key-bits 0`), devnet, and cluster/MultiNodeClient all
    /// pass 0.
    ///
    /// NETWORK-INTEROP INVARIANT: this default MUST equal the key-PoW level the
    /// network's nodes actually run, otherwise a default joiner rejects the
    /// network's peers (it requires ≥default bits; the peers present fewer) and
    /// can never connect — observed as peerCount 0 / no sync. All current
    /// mainnet+testnet deployments run `--min-peer-key-bits 16`, so the default
    /// is 16. (Treat this as a per-network constant; raising it requires raising
    /// every deployed node in lockstep.)
    public static let defaultMinPeerKeyBits: Int = 16

    /// Public payout address that the node credits in the block-template coinbase
    /// (Mechanism A). The node signs the coinbase with a
    /// node-local coinbase authority; the coinbase credit is authorization-free,
    /// so the node never holds the payout address's private key and the miner
    /// never sends one.
    /// Defaults to nil (no coinbase is built — the miner still searches the nonce
    /// over an empty-reward template).
    public let coinbaseAddress: String?

    /// Operator-declared public P2P endpoint (host, port) advertised to peers,
    /// overriding STUN/observed addresses. Required for cloud/NAT nodes (e.g. fly)
    /// whose observed address is private and not externally dialable.
    public let externalAddress: (host: String, port: UInt16)?
    /// Public, CORS-enabled HTTP RPC base URL for this node (e.g. https://node.example.com),
    /// advertised through the child-peer rendezvous so a browser can be pointed straight at
    /// this node's chain. nil = don't advertise an RPC URL (NAT/private node).
    public let rpcPublicUrl: String?
    /// Serve as a circuit relay for NAT'd peers (Phase 1 NAT traversal).
    public let relayEnabled: Bool
    /// Relay peers to route through when a direct dial fails.
    public let knownRelays: [PeerEndpoint]

    public init(
        publicKey: String,
        privateKey: String,
        listenPort: UInt16 = 4001,
        bootstrapPeers: [PeerEndpoint] = [],
        storagePath: URL,
        enableLocalDiscovery: Bool = false,
        persistInterval: UInt64 = 100,
        retentionDepth: UInt64 = DEFAULT_RETENTION_DEPTH,
        resources: NodeResourceConfig = .default,
        tuning: NodeTuning = .default,
        finality: FinalityConfig = FinalityConfig(),
        maxPeerConnections: Int = BootstrapPeers.maxPeerConnections,
        discoveryOnly: Bool = false,
        storageMode: StorageMode = .stateful,
        blockRetention: BlockRetention = .retention,
        pinAnnounceExpiry: UInt64 = 86400,
        reannounceInterval: Duration = .seconds(86400),
        evictionInterval: Duration = .seconds(21600),
        pendingGossipBlockLimit: Int = 512,
        maxFrameSize: UInt32 = IvyConfig.defaultMaxFrameSize,
        minFeeRate: UInt64 = 0,
        isTestnet: Bool = false,
        fullChainPath: [String]? = nil,
        minPeerKeyBits: Int = LatticeNodeConfig.defaultMinPeerKeyBits,
        coinbaseAddress: String? = nil,
        externalAddress: (host: String, port: UInt16)? = nil,
        rpcPublicUrl: String? = nil,
        relayEnabled: Bool = false,
        knownRelays: [PeerEndpoint] = []
    ) {
        self.publicKey = publicKey
        self.privateKey = privateKey
        self.listenPort = listenPort
        self.bootstrapPeers = bootstrapPeers
        self.storagePath = storagePath
        self.enableLocalDiscovery = enableLocalDiscovery
        self.persistInterval = persistInterval
        self.retentionDepth = retentionDepth
        self.resources = resources
        self.tuning = tuning
        self.finality = finality
        self.maxPeerConnections = maxPeerConnections
        self.discoveryOnly = discoveryOnly
        self.storageMode = storageMode
        self.blockRetention = blockRetention
        self.pinAnnounceExpiry = pinAnnounceExpiry
        self.reannounceInterval = reannounceInterval
        self.evictionInterval = evictionInterval
        self.pendingGossipBlockLimit = pendingGossipBlockLimit
        self.maxFrameSize = maxFrameSize
        self.minFeeRate = minFeeRate
        self.isTestnet = isTestnet
        self.fullChainPath = fullChainPath
        self.minPeerKeyBits = minPeerKeyBits
        self.coinbaseAddress = coinbaseAddress
        self.rpcPublicUrl = rpcPublicUrl
        self.externalAddress = externalAddress
        self.relayEnabled = relayEnabled
        self.knownRelays = knownRelays
    }
}
