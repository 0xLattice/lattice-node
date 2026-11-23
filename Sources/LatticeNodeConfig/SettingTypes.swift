import Foundation
import Ivy
import Lattice

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
    case invalidWebSocketURL
    case webSocketURLWithoutListener
    case invalidAnnounceLifetime
    case invalidConnectBatch

    public var description: String {
        switch self {
        case .invalidChainPath:
            "chain path must be Nexus-rooted, consensus-valid, and fit the setup wire frame"
        case .invalidPrivateKey: "process private key must be a 32-byte Ed25519 key"
        case .invalidPorts: "overlay, RPC and WebSocket ports must be nonzero and distinct"
        case .invalidPublicReadURL:
            "public read URL must be an absolute http(s) URL with a host and no credentials, query or fragment"
        case .invalidWebSocketURL:
            "WebSocket URL must be a ws:// or wss:// URL of at most \(WebAddress.maxURLBytes) printable ASCII bytes"
        case .webSocketURLWithoutListener:
            "a WebSocket URL needs the WebSocket listener: it names where browsers reach it"
        case .invalidAnnounceLifetime:
            "announce lifetime must be 1 to \(SettingLimits.maximumAnnounceLifetime) seconds: peers drop announcements that last longer"
        case .invalidConnectBatch:
            "connect batch must be at least 1 block"
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

/// Which block bodies a node keeps beyond the ones it needs to operate (the
/// bodies waiting to execute, and each chain's tip). A body is a block's
/// own Volume and its transactions'.
public enum BlockBodies: String, Sendable, CaseIterable {
    /// Every body it executed.
    case all
    /// No others.
    case none
}

/// Which state a node keeps. State is what executions read and create; it
/// is not a block body. Kept state is a cache: whatever reads state this
/// node does not hold (execution, preflight, reads) reads it from peers.
public enum StateRetention: String, Sendable, CaseIterable {
    /// The state of every block it executed.
    case all
    /// The whole current state of each chain, and what its most recent
    /// blocks replaced, for its state window
    /// (`NodeConfiguration.stateWindow(for:)`).
    case recent
    /// What the last execution read and created, until the next.
    case none

    /// An operator's name for it. `tip`, which kept exactly the tip's state,
    /// is now `recent`.
    public init?(named name: String) {
        self.init(rawValue: name == "tip" ? "recent" : name)
    }
}

/// The bounds an operator's settings are checked against: by `lattice`
/// before it writes a file, and by the node when it starts.
public enum SettingLimits {
    /// The longest announcement the overlay accepts: an expiry further out
    /// is dropped, by this node's overlay and by every peer's.
    public static let maximumAnnounceLifetime = IvyConfig.defaultMaxProviderTTLSeconds
    /// The longest public read URL the read-endpoint wire message carries.
    public static let maximumPublicReadURLBytes = 512

    /// An absolute http(s) URL naming a host, without credentials, query or
    /// fragment, that fits the read-endpoint wire message.
    public static func isValidPublicReadURL(_ value: String) -> Bool {
        guard value.utf8.count <= maximumPublicReadURLBytes,
              value.utf8.allSatisfy({ (0x21...0x7E).contains($0) }),
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return false }
        return true
    }

    /// A `ws://` or `wss://` URL a peer may advertise (`WebAddress`).
    public static func isValidWebSocketURL(_ value: String) -> Bool {
        WebAddress(url: value).isValid
    }
}
