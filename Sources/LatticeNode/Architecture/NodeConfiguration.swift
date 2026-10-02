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
        case .invalidPorts: "overlay and RPC ports must be nonzero and distinct"
        case .invalidPublicReadURL:
            "the public read URL must be an absolute http(s) base URL with a host and no credentials, query, or fragment"
        }
    }
}

/// Immutable setup and process identity for exactly one absolute chain path.
public struct NodeConfiguration: Sendable {
    public let address: ChainAddress
    public let storagePath: URL
    private let signingKeyBytes: [UInt8]
    public let processPublicKey: String
    public let listenPort: UInt16
    public let rpcPort: UInt16
    public let bootstrapPeers: [PeerEndpoint]
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
    /// Operator-declared address at which this node is publicly reachable
    /// (host only; the overlay listen port applies). Behind NAT or an L4
    /// proxy the OBSERVED address differs from the reachable one, so
    /// provider announcements built from observation advertise a dead
    /// address; this is the node's self-description. Optional: direct-IP
    /// nodes need none.
    public let externalAddress: String?
    /// Operator-declared public read URL for THIS chain's browsable HTTP
    /// surface (e.g. "https://toy.example.com"): a TLS-fronted base a browser
    /// can dial. Distinct from `externalAddress` on purpose — the P2P plane
    /// traffics in IP literals (netgroup hardening), which a browser cannot
    /// use, so browsability is its own self-description. Advertised through
    /// the parent rendezvous; consumers verify the served genesis against the
    /// parent's on-chain anchor before trusting it. Optional: nodes without a
    /// public TLS surface declare nothing and stay non-browsable.
    public let publicReadURL: String?
    /// Seconds with no newly accepted block after which this node widens its
    /// peer search: re-dial the configured peers it holds no session with, and
    /// dial a few endpoints from one provider lookup. An eclipse only works
    /// while the victim keeps asking the same peers, and the node that has
    /// stopped making progress is the one that most needs others. Staleness is
    /// measured from this node's own verified tip, never from a peer's claimed
    /// height. Discovery only: nothing here disconnects, scores or prefers a
    /// peer, and it has no bearing on validation or fork choice. `0` disables.
    public let peerSearchInterval: TimeInterval
    public let resourcePolicy: NodeResourcePolicy
    /// The child chains this process hosts as levels under Nexus (operator
    /// choice), parent before child; every parent is Nexus or listed.
    public let hostedChildren: [[String]]

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
        bootstrapPeers: [PeerEndpoint] = [],
        minPeerKeyBits: Int = 0,
        overlayMaxConnectionsPerNetgroup: Int = IvyConfig.defaultMaxConnections,
        externalAddress: String? = nil,
        publicReadURL: String? = nil,
        peerSearchInterval: TimeInterval = 600,
        resourcePolicy: NodeResourcePolicy = .default,
        hostedChildren: [[String]] = []
    ) throws {
        for child in hostedChildren {
            guard child.count > 1, (try? ChainRuntimeContext(path: child)) != nil,
                  child.dropLast().count == 1 || hostedChildren.contains(Array(child.dropLast())),
                  child.first == chainPath.first else {
                throw NodeConfigurationError.invalidChainPath
            }
        }
        guard let address = ChainAddress(chainPath) else {
            throw NodeConfigurationError.invalidChainPath
        }
        guard (try? ChainHello(
            nexusGenesisCID: NexusGenesis.expectedBlockHash,
            chainPath: address.components
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
        // Operator input fails loudly (unlike wire ingest, which is tolerant):
        // a declared-but-invalid URL is a deployment mistake, not peer noise.
        let declaredReadURL: String?
        if let publicReadURL {
            guard let normalized = normalizedPublicReadURL(publicReadURL) else {
                throw NodeConfigurationError.invalidPublicReadURL
            }
            declaredReadURL = normalized
        } else {
            declaredReadURL = nil
        }

        self.address = address
        self.storagePath = storagePath
        self.signingKeyBytes = Array(bytes)
        self.processPublicKey = try! PeerKey(
            rawRepresentation: signingKey.publicKey.rawRepresentation
        ).hex
        self.listenPort = listenPort
        self.rpcPort = rpcPort
        self.bootstrapPeers = bootstrapPeers
        self.minPeerKeyBits = minPeerKeyBits
        self.overlayMaxConnectionsPerNetgroup = max(1, overlayMaxConnectionsPerNetgroup)
        self.externalAddress = externalAddress
        self.publicReadURL = declaredReadURL
        self.peerSearchInterval = max(0, peerSearchInterval)
        self.resourcePolicy = resourcePolicy
        self.hostedChildren = hostedChildren.sorted { $0.count != $1.count ? $0.count < $1.count : $0.joined(separator: "/") < $1.joined(separator: "/") }
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
