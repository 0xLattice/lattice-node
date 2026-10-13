import Crypto
import Foundation
import Ivy
import Lattice
import UInt256

public struct ChainAddress: Hashable, Sendable, CustomStringConvertible {
    public static let nexus = "Nexus"

    public let components: [String]

    public init?(_ components: [String]) {
        guard (try? ChainRuntimeContext(
            path: components,
            genesisCID: components.count == 1 ? NexusGenesis.expectedBlockHash : nil
        )) != nil else {
            return nil
        }
        self.components = components
    }

    public init?(string: String) {
        self.init(string.split(separator: "/", omittingEmptySubsequences: false).map(String.init))
    }

    public var key: String { components.joined(separator: "/") }
    public var parent: ChainAddress? { ChainAddress(Array(components.dropLast())) }
    public var directory: String { components.last! }
    public var isNexus: Bool { components.count == 1 }
    public var description: String { key }

}

public enum NodeConfigurationError: Error, Equatable, CustomStringConvertible {
    case invalidChainPath
    case invalidPrivateKey
    case invalidPorts
    case invalidPublicReadURL

    public var description: String {
        switch self {
        case .invalidChainPath:
            "chain path must be Nexus-rooted, consensus-valid, and fit the setup wire frame"
        case .invalidPrivateKey: "process private key must be a 32-byte Ed25519 key"
        case .invalidPorts: "overlay, RPC and WebSocket ports must be nonzero and distinct"
        case .invalidPublicReadURL:
            "public read URL must be an absolute http(s) URL with a host and no credentials, query or fragment"
        }
    }
}

/// Whether the node listens for peers that cannot open a TCP connection:
/// browsers. On that port it accepts overlay sessions over WebSocket (TCP)
/// and answers STUN (UDP), and while it listens it relays between its peers,
/// which is how two browsers meet before they connect to each other.
public enum WebSocketListener: Sendable, Equatable {
    case off
    /// Listen if the port can be bound and start without it if not, so a
    /// second node on one machine still starts. The default.
    case ifAvailable(UInt16)
    /// Listen, and fail to start if the port cannot be bound.
    case required(UInt16)

    public static let defaultPort: UInt16 = 4002

    public var port: UInt16? {
        switch self {
        case .off: nil
        case .ifAvailable(let port), .required(let port): port
        }
    }
}

/// Immutable setup and process identity for one Nexus-rooted hosted tree.
public struct NodeConfiguration: Sendable {
    public let address: ChainAddress
    public let storagePath: URL
    private let signingKeyBytes: [UInt8]
    public let processPublicKey: String
    public let listenPort: UInt16
    public let rpcPort: UInt16
    public let webSocket: WebSocketListener
    /// The operator's peers: dialled from the start and kept for the life of
    /// the process.
    public let bootstrapPeers: [PeerEndpoint]
    /// Introductions of last resort (the built-in seeds, when the operator
    /// configured no peers): dialled only while the node has too few peers
    /// after trying the ones it remembers. A node that already knows the
    /// network does not touch them, so they shape it as little as possible
    /// and carry only the nodes that need them.
    public let seedPeers: [PeerEndpoint]
    /// The seeds again at fixed addresses, behind them: dialled only while
    /// the node still has too few peers after the seeds by name, so that it
    /// can find the network when names cannot be resolved.
    public let fixedSeedPeers: [PeerEndpoint]
    /// A hosted child chain's own seeds (operator's list), beside what it
    /// finds through its parent: dialled only while that chain has too few
    /// peers after trying the ones it remembers and its rendezvous.
    public let childSeedPeers: [[String]: [PeerEndpoint]]
    /// With fewer current peers than this, a hosted chain dials peers it
    /// remembers (operator choice).
    public let peerTarget: Int
    /// With fewer current peers than this, a hosted chain dials its seeds
    /// (operator choice).
    public let peersBeforeSeeds: Int
    public let minPeerKeyBits: Int
    /// Per-netgroup inbound/outbound overlay connection cap. Ivy buckets peers by
    /// the connection's observed remote host (/16), an anti-eclipse defense that
    /// assumes distinct source IPs. Nodes fronted by an L4 proxy (e.g. fly-proxy)
    /// see every connection as the proxy's single address, collapsing the whole
    /// mesh onto one netgroup and strangling it. This cap governs per-netgroup
    /// connections in BOTH directions. A low value buys little here: bad data is
    /// rejected on CID/PoW verification, not on connection policy (no
    /// assumevalid); the reserved outbound slots that carry a node's own sync
    /// are protected by a separate inbound ceiling regardless of this value; so
    /// slot-flooding an unauthenticated peer can only withhold or delay, never
    /// feed a false chain. The default is therefore permissive. A public
    /// direct-IP node that wants a real per-source admission COST should set
    /// `minPeerKeyBits > 0` (a grinding price) rather than rely on this bucket.
    public let overlayMaxConnectionsPerNetgroup: Int
    /// Content-serving limits handed to the overlay (operator policy).
    public let contentServing: ContentServingLimits
    /// Operator-declared address at which this node is publicly reachable
    /// (host only; the overlay listen port applies). Behind NAT or an L4
    /// proxy the OBSERVED address differs from the reachable one, so
    /// provider announcements built from observation advertise a dead
    /// address; this is the node's self-description. Optional: direct-IP
    /// nodes need none.
    public let externalAddress: String?
    /// Seconds with no newly accepted block after which this node widens its
    /// peer search: re-dial the configured peers it holds no session with, and
    /// dial a few endpoints from one provider lookup. An eclipse only works
    /// while the victim keeps asking the same peers, and the node that has
    /// stopped making progress is the one that most needs others. Staleness is
    /// measured from this node's own verified tip, never from a peer's claimed
    /// height. Discovery only: nothing here disconnects, scores or prefers a
    /// peer, and it has no bearing on validation or fork choice. `0` disables
    /// stalled-peer search; provider announcements continue.
    public let peerSearchInterval: TimeInterval
    public let resourcePolicy: NodeResourcePolicy
    /// How many bytes of executed block bodies (each block's own Volume and
    /// its transactions') this node keeps for each chain it hosts, newest
    /// first (operator choice). Nil keeps every body; 0 keeps the tip's
    /// alone. Facts, headers and state are not bodies.
    public let retainBlockBytes: Int?
    /// The child chains this process hosts as levels under Nexus (operator
    /// choice), parent before child; every parent is Nexus or listed.
    public let hostedChildren: [[String]]
    /// The spec a hosted child's genesis is built from while it has no root
    /// (operator choice; a child with none only follows roots others mine).
    public let childSpecs: [[String]: ChainSpec]
    /// The WASM policy modules those specs name by CID (operator-supplied
    /// bytes): stored at start, so a genesis that names one can be stored.
    public let policyModules: [Data]
    /// The URL at which the public read routes of every level this process
    /// hosts are reachable (operator declaration; never derived). A peer's
    /// read-endpoint request for a hosted level is answered with it, and each
    /// hosted child level is announced under its read-endpoint key.
    public let publicReadURL: String?
    /// The public read listener also accepts `POST /transactions` (operator
    /// choice, default off). Declared beside `publicReadURL` to peers.
    public let publicSubmit: Bool
    /// The smallest fee (a transaction's balance excess, credited to the
    /// block's recipient) this node admits to its pool, at every level it
    /// hosts. Node relay policy, never consensus: a block carrying a
    /// cheaper transaction stays valid. 0 admits any fee.
    public let minRelayFee: UInt64

    /// Overlay slots kept in reserve for outbound dials so a burst of inbound
    /// connections (from one source, especially behind a proxy where the
    /// per-netgroup cap cannot discriminate) can never exhaust total capacity and
    /// starve the outbound dials a node needs to bootstrap and cold-sync.
    public static let overlayReservedOutboundSlots = 16

    public init(
        chainPath: [String],
        storagePath: URL,
        privateKeyHex: String,
        listenPort: UInt16 = 4001,
        rpcPort: UInt16 = 8080,
        webSocket: WebSocketListener = .ifAvailable(WebSocketListener.defaultPort),
        bootstrapPeers: [PeerEndpoint] = [],
        seedPeers: [PeerEndpoint] = [],
        fixedSeedPeers: [PeerEndpoint] = [],
        childSeedPeers: [[String]: [PeerEndpoint]] = [:],
        peerTarget: Int = 8,
        peersBeforeSeeds: Int = 2,
        minPeerKeyBits: Int = 0,
        overlayMaxConnectionsPerNetgroup: Int = IvyConfig.defaultMaxConnections,
        contentServing: ContentServingLimits = .default,
        externalAddress: String? = nil,
        peerSearchInterval: TimeInterval = 600,
        resourcePolicy: NodeResourcePolicy = .default,
        retainBlockBytes: Int? = nil,
        hostedChildren: [[String]] = [],
        childSpecs: [[String]: ChainSpec] = [:],
        policyModules: [Data] = [],
        publicReadURL: String? = nil,
        publicSubmit: Bool = false,
        minRelayFee: UInt64 = 0
    ) throws {
        guard let address = ChainAddress(chainPath), address.isNexus else {
            throw NodeConfigurationError.invalidChainPath
        }
        var listed: Set<[String]> = [chainPath]
        for child in hostedChildren {
            guard child.count > 1, (try? ChainRuntimeContext(path: child)) != nil,
                  listed.contains(Array(child.dropLast())),
                  listed.insert(child).inserted else {
                throw NodeConfigurationError.invalidChainPath
            }
        }
        guard childSeedPeers.keys.allSatisfy({ $0 != chainPath && listed.contains($0) }) else {
            throw NodeConfigurationError.invalidChainPath
        }
        guard (try? ChainHandshake(
            nexusGenesisCID: NexusGenesis.expectedBlockHash,
            chainPath: address.components,
            capabilities: Self.helloCapabilities(hostedChildren: hostedChildren, relays: true)
        ).encode()) != nil else {
            throw NodeConfigurationError.invalidChainPath
        }
        guard let bytes = Self.hexData(privateKeyHex),
              let signingKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: bytes) else {
            throw NodeConfigurationError.invalidPrivateKey
        }
        guard listenPort != 0,
              rpcPort != 0,
              listenPort != rpcPort else {
            throw NodeConfigurationError.invalidPorts
        }
        if let publicReadURL, !Self.isValidPublicReadURL(publicReadURL) {
            throw NodeConfigurationError.invalidPublicReadURL
        }

        self.address = address
        self.storagePath = storagePath
        self.signingKeyBytes = Array(bytes)
        self.processPublicKey = try! PeerKey(
            rawRepresentation: signingKey.publicKey.rawRepresentation
        ).hex
        self.listenPort = listenPort
        self.rpcPort = rpcPort
        switch webSocket {
        case .required(let port):
            guard port != 0, port != listenPort, port != rpcPort else {
                throw NodeConfigurationError.invalidPorts
            }
            self.webSocket = webSocket
        case .ifAvailable(let port):
            // A port given to something else is not available.
            self.webSocket = port == 0 || port == listenPort || port == rpcPort ? .off : webSocket
        case .off:
            self.webSocket = .off
        }
        self.bootstrapPeers = bootstrapPeers
        self.seedPeers = seedPeers
        self.fixedSeedPeers = fixedSeedPeers
        self.childSeedPeers = childSeedPeers
        self.peerTarget = max(0, peerTarget)
        self.peersBeforeSeeds = max(0, peersBeforeSeeds)
        self.minPeerKeyBits = minPeerKeyBits
        self.overlayMaxConnectionsPerNetgroup = max(1, overlayMaxConnectionsPerNetgroup)
        self.contentServing = contentServing
        self.externalAddress = externalAddress
        self.peerSearchInterval = peerSearchInterval.isFinite
            ? max(0, peerSearchInterval) : 0
        self.resourcePolicy = resourcePolicy
        self.retainBlockBytes = retainBlockBytes
        self.childSpecs = childSpecs.filter { hostedChildren.contains($0.key) }
        self.hostedChildren = hostedChildren
        self.policyModules = policyModules
        self.publicReadURL = publicReadURL
        self.publicSubmit = publicSubmit
        self.minRelayFee = minRelayFee
    }

    /// What this node's hello says it speaks and hosts: the one list the
    /// hello is built from and its size is checked against.
    /// `relays` is whether the overlay it is said over relays.
    func helloCapabilities(relays: Bool) -> Set<String> {
        Self.helloCapabilities(hostedChildren: hostedChildren, relays: relays)
    }

    private static func helloCapabilities(hostedChildren: [[String]], relays: Bool) -> Set<String> {
        Set([ChainHandshake.volumeBundle] + (relays ? [ChainHandshake.relay] : [])
            + hostedChildren.map(ChainHandshake.hosting))
    }

    /// An absolute http(s) URL naming a host, without credentials, query or
    /// fragment, that fits the read-endpoint wire message.
    public static func isValidPublicReadURL(_ value: String) -> Bool {
        guard value.utf8.count <= ReadEndpointResponseMessage.maximumURLBytes,
              value.utf8.allSatisfy({ (0x21...0x7E).contains($0) }),
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return false }
        return true
    }

    public var chainPath: [String] { address.components }
    public var nexusGenesisCID: String { NexusGenesis.expectedBlockHash }
    public var signingKey: Curve25519.Signing.PrivateKey {
        try! Curve25519.Signing.PrivateKey(rawRepresentation: signingKeyBytes)
    }
    public var runtimeContext: ChainRuntimeContext {
        get throws {
            // Only the root chain pins its genesis (Lattice §5.1).
            try ChainRuntimeContext(
                path: chainPath, genesisCID: address.isNexus ? nexusGenesisCID : nil
            )
        }
    }

    private static func hexData(_ value: String) -> Data? {
        guard value.count == 64 else { return nil }
        var result = Data(capacity: 32)
        var index = value.startIndex
        for _ in 0..<32 {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }
}
