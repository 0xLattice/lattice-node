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
            path: components
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

public struct ParentEndpoint: Codable, Hashable, Sendable {
    public let publicKey: String
    public let host: String
    public let port: UInt16

    public init(publicKey: String, host: String, port: UInt16) {
        self.publicKey = publicKey
        self.host = host
        self.port = port
    }

    var ivy: PeerEndpoint {
        PeerEndpoint(publicKey: publicKey, host: host, port: port)
    }
}

public enum NodeConfigurationError: Error, Equatable, CustomStringConvertible {
    case invalidChainPath
    case invalidPrivateKey
    case invalidPorts
    case invalidParentEndpoint
    case missingParentEndpoint
    case unexpectedParentEndpoint

    public var description: String {
        switch self {
        case .invalidChainPath:
            "chain path must be Nexus-rooted, consensus-valid, and fit the setup wire frame"
        case .invalidPrivateKey: "process private key must be a 32-byte Ed25519 key"
        case .invalidPorts: "overlay, fact-plane, and RPC ports must be nonzero and distinct"
        case .invalidParentEndpoint: "the parent endpoint must have a valid peer key, host, and port"
        case .missingParentEndpoint: "a child process requires its authenticated immediate-parent endpoint"
        case .unexpectedParentEndpoint: "the Nexus process has no parent endpoint"
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
    public let factListenPort: UInt16
    public let rpcPort: UInt16
    public let bootstrapPeers: [PeerEndpoint]
    public let parentEndpoint: ParentEndpoint?
    public let minPeerKeyBits: Int
    /// Per-netgroup inbound/outbound overlay connection cap. Ivy buckets peers by
    /// the connection's observed remote host (/16), an anti-eclipse defense that
    /// assumes distinct source IPs. Nodes fronted by an L4 proxy (e.g. fly-proxy)
    /// see every inbound connection as the proxy's single address, collapsing all
    /// inbound onto one netgroup; such deployments must raise this. Default keeps
    /// Ivy's conservative value for direct-IP nodes.
    public let overlayMaxConnectionsPerNetgroup: Int
    /// Operator-declared address at which this node is publicly reachable
    /// (host only; the overlay listen port applies). Behind NAT or an L4
    /// proxy the OBSERVED address differs from the reachable one, so
    /// provider announcements built from observation advertise a dead
    /// address; this is the node's self-description. Optional: direct-IP
    /// nodes need none.
    public let externalAddress: String?
    public let resourcePolicy: NodeResourcePolicy

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
        factListenPort: UInt16 = 4002,
        rpcPort: UInt16 = 8080,
        bootstrapPeers: [PeerEndpoint] = [],
        parentEndpoint: ParentEndpoint? = nil,
        minPeerKeyBits: Int = 0,
        overlayMaxConnectionsPerNetgroup: Int = 2,
        externalAddress: String? = nil,
        resourcePolicy: NodeResourcePolicy = .default
    ) throws {
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
              factListenPort != 0,
              rpcPort != 0,
              Set([listenPort, factListenPort, rpcPort]).count == 3 else {
            throw NodeConfigurationError.invalidPorts
        }
        if address.isNexus, parentEndpoint != nil {
            throw NodeConfigurationError.unexpectedParentEndpoint
        }
        if !address.isNexus, parentEndpoint == nil {
            throw NodeConfigurationError.missingParentEndpoint
        }
        let normalizedParentEndpoint: ParentEndpoint?
        if let parentEndpoint {
            let host = parentEndpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let key = try? PeerKey(parentEndpoint.publicKey),
                  !host.isEmpty,
                  parentEndpoint.port != 0 else {
                throw NodeConfigurationError.invalidParentEndpoint
            }
            normalizedParentEndpoint = ParentEndpoint(
                publicKey: key.hex,
                host: host,
                port: parentEndpoint.port
            )
        } else {
            normalizedParentEndpoint = nil
        }

        self.address = address
        self.storagePath = storagePath
        self.signingKeyBytes = Array(bytes)
        self.processPublicKey = try! PeerKey(
            rawRepresentation: signingKey.publicKey.rawRepresentation
        ).hex
        self.listenPort = listenPort
        self.factListenPort = factListenPort
        self.rpcPort = rpcPort
        self.bootstrapPeers = bootstrapPeers
        self.parentEndpoint = normalizedParentEndpoint
        self.minPeerKeyBits = minPeerKeyBits
        self.overlayMaxConnectionsPerNetgroup = max(1, overlayMaxConnectionsPerNetgroup)
        self.externalAddress = externalAddress
        self.resourcePolicy = resourcePolicy
    }

    public var chainPath: [String] { address.components }
    public var nexusGenesisCID: String { NexusGenesis.expectedBlockHash }
    public var signingKey: Curve25519.Signing.PrivateKey {
        try! Curve25519.Signing.PrivateKey(rawRepresentation: signingKeyBytes)
    }
    public var runtimeContext: ChainRuntimeContext {
        get throws {
            try ChainRuntimeContext(path: chainPath)
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
