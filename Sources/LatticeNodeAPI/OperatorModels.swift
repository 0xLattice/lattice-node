import Foundation
import Lattice

// The operator API's configuration shapes: `lattice.json` as a value, and the
// answers of the operator listener. Loading, merging and checking a
// configuration is `LatticeNodeConfig`'s; these are what crosses the wire.

/// `peers` in `lattice.json`: an object keyed by chain path. An array is
/// Nexus's list, as every file written before chains had lists of their own.
public struct ChainPeers: Codable, Sendable, Equatable {
    public var byChain: [String: [String]]

    public init(byChain: [String: [String]]) {
        self.byChain = byChain
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let nexus = try? container.decode([String].self) {
            byChain = [DEFAULT_ROOT_DIRECTORY: nexus]
        } else {
            byChain = try container.decode([String: [String]].self)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if byChain.count == 1, let nexus = byChain[DEFAULT_ROOT_DIRECTORY] {
            try container.encode(nexus)
        } else {
            try container.encode(byChain)
        }
    }
}

public struct Topology: Codable, Sendable {
    package enum CodingKeys: String, CodingKey, CaseIterable {
        case listen, rpc, webSocket, peers, publicRead, externalAddress
        case publicReadRate, publicReadExpensiveRate, publicReadMaxRate, publicReadFetches
        case publicReadURL, webSocketURL, publicSubmit, publicSubmitRate, minRelayFee
        case servingMaxConcurrent, servingMaxInFlightVolumeBytes, maxAcquisitionBytes, blockBodies, state, stateWindow, stateWindows, finalityWindow, finalityWindows, announceLifetime, connectBatch
        case hostedChains, rpcAllowedOrigins, operatorListen, operatorTokens, operatorAllowedOrigins
    }
    public var listen: UInt16
    public var rpc: UInt16
    /// Port for browsers (the node's `--websocket-port`): overlay sessions
    /// over WebSocket on TCP and STUN on UDP. Absent = the node's default,
    /// which it does without if the port is taken; 0 = off.
    public var webSocket: UInt16?
    /// Each chain's peers as `publicKey@host:port`, by chain path. Nexus's
    /// list is its bootstrap peers (absent: the built-in ones; empty: none);
    /// a hosted child's is extra seeds for that chain, beside what it finds
    /// through its parent.
    public var peers: ChainPeers?
    /// Public read-only HTTP port (the node's `--public-read-port`): binds
    /// all interfaces and serves only the bounded GET read routes. Absent =
    /// no public read listener for this hosted tree.
    public var publicRead: UInt16?
    /// Self-described publicly reachable host (the node's
    /// `--external-address`) for overlay announcements from NAT/proxy-fronted
    /// processes. Host only; the chain's listen port applies.
    public var externalAddress: String?
    /// Ignored by the node (`--public-read-rate` /
    /// `--public-read-expensive-rate`, per-client limits that were removed).
    /// Still accepted so an existing `lattice.json` keeps loading.
    public var publicReadRate: Double?
    public var publicReadExpensiveRate: Double?
    /// Listener-wide arrival-rate ceiling (`--public-read-max-rate`), in
    /// requests per second. Absent = the node's default; `0` disables it.
    public var publicReadMaxRate: Double?
    /// Volumes the public read listener reads from peers at once for
    /// readers when the node does not hold them (`--public-read-fetches`).
    /// Absent = the node's default; `0` = only what the node holds.
    public var publicReadFetches: Int?
    /// This host's public read URL (the node's `--public-read-url`), declared
    /// for every level it hosts. Absent = none declared.
    public var publicReadURL: String?
    /// The URL browsers dial for this node's WebSocket listener (the node's
    /// `--websocket-url`), e.g. `wss://node.example.org/ivy` through a proxy
    /// that ends TLS; requires `webSocket`. Absent = the node advertises
    /// relays among its peers.
    public var webSocketURL: String?
    /// Accept `POST /transactions` on the public read port too (the node's
    /// `--public-submit`). Absent or false = off; requires `publicRead`.
    public var publicSubmit: Bool?
    /// Listener-wide transaction submission ceiling (`--public-submit-rate`),
    /// in requests per second. Absent = the node's default; `0` disables it.
    public var publicSubmitRate: Double?
    /// The smallest fee the node admits to its pool (`--min-relay-fee`; node
    /// policy, never consensus). Absent = the node's default, 1.
    public var minRelayFee: UInt64?
    /// Content-serving limits (`--serving-max-*`). Absent = the node's defaults.
    public var servingMaxConcurrent: Int?
    public var servingMaxInFlightVolumeBytes: Int?
    /// Bytes of fetched content the node's fetches hold in memory at once,
    /// every hosted chain together (`--max-acquisition-bytes`). Absent =
    /// the node's default.
    public var maxAcquisitionBytes: Int?
    /// The block bodies kept beyond what the node needs to operate
    /// (`--block-bodies`): `all` or `none`. Absent = `all`.
    public var blockBodies: String?
    /// The state kept (`--state`): `all`, `recent` or `none` (`tip` is the
    /// earlier name of `recent`). Absent = `all`.
    public var state: String?
    /// With `recent`, the blocks of each chain, counting its tip, whose
    /// replaced state is kept beside the current state (`--state-window`).
    /// Absent = 64.
    public var stateWindow: UInt64?
    /// Per-chain state windows in blocks, by chain path, over `stateWindow`.
    public var stateWindows: [String: UInt64]?
    /// Node-local finality in blocks (`--finality-window`): headers and work
    /// more than this many blocks below a chain's best tip are declined, and
    /// the node does not follow a reorganization deeper than this. Absent or
    /// 0 = keep everything.
    public var finalityWindow: UInt64?
    /// Per-chain finality windows in blocks, by chain path, over
    /// `finalityWindow`; 0 turns it off for that chain.
    public var finalityWindows: [String: UInt64]?
    /// Seconds each provider announcement lasts (`--announce-lifetime`).
    /// Absent = the node's default.
    public var announceLifetime: UInt64?
    /// Ready blocks of one chain executed per connect job, with one commit
    /// for them all (`--connect-batch`). Absent = 32; at least 1.
    public var connectBatch: Int?
    /// Child chains this process hosts as levels, parent before child.
    public var hostedChains: [String]?
    /// Browser origins allowed on the loopback RPC port (the node's
    /// `--rpc-allowed-origin`), e.g. `chrome-extension://<id>`. Each still
    /// needs the node's cookie. Absent = browsers are refused.
    public var rpcAllowedOrigins: [String]? = nil
    /// The remote operator listener's `host:port` (the node's
    /// `--operator-listen`), for clients on other machines. Requires
    /// `operatorTokens`. Absent = off.
    public var operatorListen: String? = nil
    /// The remote operator listener's token file (`--operator-tokens`); a
    /// relative path is under the root. The node creates it with the first
    /// token made through its API.
    public var operatorTokens: String? = nil
    /// Browser origins allowed on the remote operator listener
    /// (`--operator-allowed-origin`), e.g. `https://dashboard.example`. Each
    /// still needs a token. Absent = browsers are refused.
    public var operatorAllowedOrigins: [String]? = nil

    public init(listen: UInt16, rpc: UInt16) {
        self.listen = listen
        self.rpc = rpc
    }
}


// MARK: - The operator listener's answers

/// `GET /config`: the node's configuration as it keeps it, and the keys
/// changed since its start that take a restart to apply.
/// `GET /config`, and the answer to a change of a fragment: the merged
/// configuration (`spec`), the layers it was merged from, in order, and how
/// the running node compares with it.
public struct ConfigResponse: Codable, Sendable {
    public let spec: Topology
    public let fragments: [String]
    public let status: ConfigStatus

    public init(spec: Topology, fragments: [String], status: ConfigStatus) {
        self.spec = spec
        self.fragments = fragments
        self.status = status
    }
}

public struct ConfigStatus: Codable, Sendable {
    /// One chain the configuration hosts (`HostedTree`), or that the node
    /// hosts though the configuration does not.
    public struct Chain: Codable, Sendable {
        public let path: String
        /// The layers that list it; empty when it is implied.
        public let from: [String]
        /// When no layer lists it: the listed chains under it, which keep it
        /// hosted. Absent for a listed chain.
        public let impliedBy: [String]?
        /// `hosted` or `notHosted`.
        public let actual: String
        /// Why it is not hosted as configured.
        public let error: String?

        public init(path: String, from: [String], impliedBy: [String]? = nil, actual: String, error: String? = nil) {
            self.path = path
            self.from = from
            self.impliedBy = impliedBy
            self.actual = actual
            self.error = error
        }
    }

    public let chains: [Chain]
    /// The keys whose value differs from what the node started with and
    /// applies only at its next start.
    public let pendingRestart: [String]
    /// What else does not match: a re-read the node could not use, a
    /// listener it could not open.
    public let errors: [String]
    /// What the layers set that does not apply (a setting for a chain not
    /// hosted, a state window without `state: recent`, a file of config.d
    /// that is not read): reported, not an error.
    public let inert: [String]

    public init(chains: [Chain], pendingRestart: [String], errors: [String], inert: [String] = []) {
        self.chains = chains
        self.pendingRestart = pendingRestart
        self.errors = errors
        self.inert = inert
    }
}

/// `POST /chains`: the chain, and whether this request created it (false:
/// it was created with exactly this already).
public struct CreatedChainResponse: Codable, Sendable {
    public let path: String
    public let created: Bool

    public init(path: String, created: Bool) {
        self.path = path
        self.created = created
    }
}

public struct HostedChainsResponse: Codable, Sendable {
    public let chains: [String]
    public let configured: [String]?

    public init(chains: [String], configured: [String]?) {
        self.chains = chains
        self.configured = configured
    }
}

/// `GET /disk`: bytes on disk of each entry in the node's storage
/// directory (the state database, the Volume stores, ...), and the free space
/// of its file system.
public struct DiskResponse: Codable, Sendable {
    public struct Store: Codable, Sendable {
        public let name: String
        public let bytes: UInt64

        public init(name: String, bytes: UInt64) {
            self.name = name
            self.bytes = bytes
        }
    }

    public let storage: String
    public let stores: [Store]
    public let totalBytes: UInt64
    public let freeBytes: UInt64?

    public init(storage: String, stores: [Store], totalBytes: UInt64, freeBytes: UInt64?) {
        self.storage = storage
        self.stores = stores
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
    }
}

/// `POST /tokens`: a new token for the remote operator listener, with a
/// role (`admin`: every route; `read`: every GET) or a list of routes.
public struct CreateTokenRequest: Codable, Sendable {
    public let name: String
    public let role: String?
    public let routes: [String]?

    public init(name: String, role: String? = nil, routes: [String]? = nil) {
        self.name = name
        self.role = role
        self.routes = routes
    }
}

/// The token itself, shown this once: the node keeps only its SHA-256.
public struct CreateTokenResponse: Codable, Sendable {
    public let name: String
    public let token: String

    public init(name: String, token: String) {
        self.name = name
        self.token = token
    }
}

/// `GET /tokens`: each token's name and what it may use.
public struct TokensResponse: Codable, Sendable {
    public struct Token: Codable, Sendable {
        public let name: String
        public let role: String?
        public let routes: [String]?

        public init(name: String, role: String?, routes: [String]?) {
            self.name = name
            self.role = role
            self.routes = routes
        }
    }

    public let tokens: [Token]

    public init(tokens: [Token]) {
        self.tokens = tokens
    }
}

