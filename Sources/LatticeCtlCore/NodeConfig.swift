// lattice.json as the node's own configuration: the node started with
// `--root` reads it at start and is its only writer while it runs. This file
// holds what both sides need of it: the node flags it stands for, changes to
// it (RFC 7396 merge patches), which keys apply live, and the operator API's
// shapes for reading and changing it.

import Foundation
import Lattice
import LatticeNode

extension Topology {
    /// The node flags this configuration stands for under `layout`: what
    /// `lattice-node --root` runs with. Hosted child chains carry the spec,
    /// premine recipient, genesis transactions and policy modules kept for
    /// them under `specs/`.
    public func nodeArguments(layout: HostLayout) -> [String] {
        var arguments = [
            "--data-directory", layout.chainDirectory(for: ChainAddress.nexus).path,
            "--identity-key", layout.identityKey(for: ChainAddress.nexus).path,
            "--listen-port", String(listen),
            "--rpc-port", String(rpc),
        ]
        arguments += peerArguments
        if let port = webSocket { arguments += ["--websocket-port", String(port)] }
        if let port = publicRead { arguments += ["--public-read-port", String(port)] }
        if let host = externalAddress { arguments += ["--external-address", host] }
        if let rate = publicReadRate { arguments += ["--public-read-rate", String(rate)] }
        if let rate = publicReadExpensiveRate { arguments += ["--public-read-expensive-rate", String(rate)] }
        if let rate = publicReadMaxRate { arguments += ["--public-read-max-rate", String(rate)] }
        if let fetches = publicReadFetches { arguments += ["--public-read-fetches", String(fetches)] }
        if let url = publicReadURL { arguments += ["--public-read-url", url] }
        arguments += publicSubmissionArguments
        arguments += contentServingArguments
        for origin in rpcAllowedOrigins ?? [] { arguments += ["--rpc-allowed-origin", origin] }
        if let operatorListen, let tokens = operatorTokensFile(root: layout.root) {
            arguments += ["--operator-listen", operatorListen, "--operator-tokens", tokens.path]
        }
        for origin in operatorAllowedOrigins ?? [] { arguments += ["--operator-allowed-origin", origin] }
        arguments += HostedChainFiles(layout, self).arguments
        return arguments
    }

    /// `operatorTokens`, resolved against `root` when relative.
    public func operatorTokensFile(root: URL) -> URL? {
        operatorTokens.map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : root.appendingPathComponent($0) }
    }

    /// `host:port`, a bracketed IPv6 host unbracketed; nil when it is not one.
    public static func hostPort(_ value: String) -> (host: String, port: UInt16)? {
        guard let colon = value.lastIndex(of: ":"), let port = UInt16(value[value.index(after: colon)...]),
              port != 0 else { return nil }
        var host = String(value[..<colon])
        if host.first == "[", host.last == "]" { host = String(host.dropFirst().dropLast()) }
        return host.isEmpty ? nil : (host, port)
    }

    /// An IPv4 or IPv6 address literal, or `localhost`: a host a listener
    /// binds as named, with no name lookup between check and start.
    public static func isAddressLiteral(_ host: String) -> Bool {
        if host == "localhost" { return true }
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }

    /// A peer as `public-key@host:port`, as the node reads `--peer`.
    public static func peerEndpoint(_ value: String) -> (key: String, host: String, port: UInt16)? {
        guard let at = value.firstIndex(of: "@"), at != value.startIndex,
              let (host, port) = hostPort(String(value[value.index(after: at)...])) else { return nil }
        return (String(value[..<at]), host, port)
    }

    /// This configuration with `patch` (an RFC 7396 JSON merge patch: an
    /// object's members replace, `null` removes, anything else replaces the
    /// whole value) applied. Not validated.
    public func applying(mergePatch patch: Data) throws -> Topology {
        guard let changes = try? JSONSerialization.jsonObject(with: patch) as? [String: Any] else {
            throw CtlError("a configuration change is one JSON object (a merge patch of \(Self.fileName))")
        }
        let merged = Self.merge(try jsonObject(), changes)
        return try Self.load(data: JSONSerialization.data(withJSONObject: merged))
    }

    /// This configuration as a JSON object.
    public func jsonObject() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as? [String: Any] ?? [:]
    }

    private static func merge(_ target: Any, _ patch: Any) -> Any {
        guard let patch = patch as? [String: Any] else { return patch }
        var result = target as? [String: Any] ?? [:]
        for (key, value) in patch {
            if value is NSNull {
                result[key] = nil
            } else {
                result[key] = merge(result[key] as Any, value)
            }
        }
        return result
    }

    /// This configuration without `paths` and every entry keyed by one of
    /// them that requires it hosted: its peers.
    public func removingChains(_ paths: Set<String>) -> Topology {
        var next = self
        next.hostedChains = hostedChains.map { $0.filter { !paths.contains($0) } }
        if var peers = next.peers {
            for path in paths { peers.byChain[path] = nil }
            next.peers = peers
        }
        return next
    }

    /// The keys a running node applies as they change: its hosted chains
    /// and the hosted children's peers. Every other key takes a restart.
    public static let liveKeys: Set<String> = ["hostedChains", "peers"]

    /// The keys whose value here differs from `running` (what a node started
    /// with) and that apply only at a start. Peers apply live except Nexus's,
    /// which a start dials.
    public func restartRequired(comparedTo running: Topology) throws -> [String] {
        let (saved, started) = (try jsonObject(), try running.jsonObject())
        var keys: [String] = []
        for key in Set(saved.keys).union(started.keys).sorted() {
            if key == "peers" {
                if peers?.byChain[ChainAddress.nexus] != running.peers?.byChain[ChainAddress.nexus] { keys.append(key) }
            } else if !Self.liveKeys.contains(key), !Self.equalJSON(saved[key], started[key]) {
                keys.append(key)
            }
        }
        return keys
    }

    /// The top-level keys whose values differ between the two.
    public func changedKeys(from other: Topology) throws -> [String] {
        let (mine, theirs) = (try jsonObject(), try other.jsonObject())
        return Set(mine.keys).union(theirs.keys).sorted().filter { !Self.equalJSON(mine[$0], theirs[$0]) }
    }

    static func equalJSON(_ lhs: Any?, _ rhs: Any?) -> Bool {
        func bytes(_ value: Any?) -> Data? {
            guard let value else { return nil }
            return try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys])
        }
        return bytes(lhs) == bytes(rhs)
    }
}

/// The files kept under `specs/` for the hosted child chains a
/// configuration lists, as the node's flags name them: a chain created here
/// has its spec, and with it its premine recipient, genesis transactions and
/// policy modules; a chain hosted from its peers has its path alone.
public struct HostedChainFiles: Sendable {
    public var hostChain: [String] = []
    public var premineTo: [String] = []
    public var genesisTransactions: [String] = []
    public var chainPeer: [String] = []
    public var policyModule: [String] = []

    public init(_ layout: HostLayout, _ topology: Topology) {
        let manager = FileManager.default
        for child in topology.hostedChains ?? [] {
            let spec = layout.childSpec(for: child)
            let hasSpec = manager.fileExists(atPath: spec.path)
            hostChain.append(hasSpec ? "\(child)=\(spec.path)" : child)
            // The recipient goes with the spec its genesis is built from.
            if hasSpec,
               let recipient = (try? String(contentsOf: layout.premineRecipient(for: child), encoding: .utf8))?
                   .trimmingCharacters(in: .whitespacesAndNewlines), !recipient.isEmpty {
                premineTo.append("\(child)=\(recipient)")
            }
            let genesis = layout.genesisTransactions(for: child)
            if hasSpec, manager.fileExists(atPath: genesis.path) {
                genesisTransactions.append("\(child)=\(genesis.path)")
            }
            let modules = (try? manager.contentsOfDirectory(
                at: layout.policyModules(for: child), includingPropertiesForKeys: nil
            )) ?? []
            policyModule += modules.sorted(by: { $0.path < $1.path }).map(\.path)
            for peer in topology.peers?.byChain[child] ?? [] { chainPeer.append("\(child)=\(peer)") }
        }
    }

    /// The flags for the chains and their files; their peers are among
    /// `peerArguments`.
    public var arguments: [String] {
        hostChain.flatMap { ["--host-chain", $0] }
            + premineTo.flatMap { ["--premine-to", $0] }
            + genesisTransactions.flatMap { ["--genesis-transactions", $0] }
            + policyModule.flatMap { ["--policy-module", $0] }
    }
}

/// `lattice config set` arguments as a merge patch: `a.b.c=value` sets that
/// member, the value read as JSON when it is JSON (a number, true, an array,
/// a quoted string...) and as a string otherwise; `unset` removes it.
public enum ConfigAssignment {
    public static func patch(setting assignments: [String]) throws -> Data {
        var patch: [String: Any] = [:]
        for assignment in assignments {
            guard let equals = assignment.firstIndex(of: "="), equals != assignment.startIndex else {
                throw CtlError("\(assignment): use key=value, e.g. stateWindow=128")
            }
            let text = String(assignment[assignment.index(after: equals)...])
            let value = (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) ?? text
            try set(&patch, path: String(assignment[..<equals]), to: value)
        }
        return try JSONSerialization.data(withJSONObject: patch, options: [.sortedKeys])
    }

    public static func patch(unsetting keys: [String]) throws -> Data {
        var patch: [String: Any] = [:]
        for key in keys { try set(&patch, path: key, to: NSNull()) }
        return try JSONSerialization.data(withJSONObject: patch, options: [.sortedKeys])
    }

    private static func set(_ object: inout [String: Any], path: String, to value: Any) throws {
        let keys = path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !keys.contains(where: \.isEmpty) else { throw CtlError("\(path) is not a key path") }
        func assign(_ object: inout [String: Any], _ keys: ArraySlice<String>) {
            guard let first = keys.first else { return }
            if keys.count == 1 {
                object[first] = value
            } else {
                var inner = object[first] as? [String: Any] ?? [:]
                assign(&inner, keys.dropFirst())
                object[first] = inner
            }
        }
        assign(&object, keys[...])
    }
}

// MARK: - The operator API's configuration shapes

/// `GET /config`: the node's configuration as it keeps it, and the keys
/// changed since its start that take a restart to apply.
public struct ConfigResponse: Codable, Sendable {
    public let config: Topology
    public let restartRequired: [String]

    public init(config: Topology, restartRequired: [String]) {
        self.config = config
        self.restartRequired = restartRequired
    }
}

/// One part of a change the node could not apply: the key and, for a
/// hosted chain, its path.
public struct ConfigFailure: Codable, Sendable {
    public let key: String
    public let chain: String?
    public let error: String

    public init(key: String, chain: String? = nil, error: String) {
        self.key = key
        self.chain = chain
        self.error = error
    }
}

/// The answer to a configuration change (`PATCH /config`, `POST` and
/// `DELETE /hosted-chains`): the configuration as now kept, which is what
/// took effect; the changed keys applied now; what failed (left out of the
/// kept configuration); and the keys waiting for a restart.
public struct ConfigChangeResponse: Codable, Sendable {
    public let config: Topology
    public let applied: [String]
    public let failed: [ConfigFailure]
    public let restartRequired: [String]

    public init(config: Topology, applied: [String], failed: [ConfigFailure], restartRequired: [String]) {
        self.config = config
        self.applied = applied
        self.failed = failed
        self.restartRequired = restartRequired
    }
}

/// `GET /hosted-chains`: the child chains running now, parent first, and
/// the ones the configuration lists (absent for a node started with flags).
public struct HostedChainsResponse: Codable, Sendable {
    public let chains: [String]
    public let configured: [String]?

    public init(chains: [String], configured: [String]?) {
        self.chains = chains
        self.configured = configured
    }
}

/// `GET /disk`: bytes on disk of each entry in the node's storage
/// directory (the state database, the Volume store, ...), and the free space
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

/// Writes `data` to a new file at `path`, created mode 0600 (never readable
/// by others, not even for a moment); refuses a file already there.
public func writePrivateFile(_ data: Data, to path: String) throws {
    let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard descriptor >= 0 else {
        throw CtlError("could not create \(path): \(String(cString: strerror(errno)))")
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    try handle.write(contentsOf: data)
    try handle.close()
}
