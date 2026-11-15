// The declarative unit `lattice` operates on: one host's chain tree.
//
// One lattice-node process hosts every chain in the tree; a child
// reads its parent facts in-process.
// This file makes that host a value: process settings live once, and hosted
// child paths are levels of that process rather than process-shaped entries.

import Foundation
import Lattice

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
            byChain = [ChainAddress.nexus: nexus]
        } else {
            byChain = try container.decode([String: [String]].self)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if byChain.count == 1, let nexus = byChain[ChainAddress.nexus] {
            try container.encode(nexus)
        } else {
            try container.encode(byChain)
        }
    }
}

public struct Topology: Codable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case listen, rpc, webSocket, peers, publicRead, externalAddress
        case publicReadRate, publicReadExpensiveRate, publicReadMaxRate, publicReadFetches
        case publicReadURL, publicSubmit, publicSubmitRate, minRelayFee
        case servingMaxConcurrent, servingMaxInFlightVolumeBytes, maxAcquisitionBytes, blockBodies, state, stateWindow, stateWindows, finalityWindow, finalityWindows, announceLifetime
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
    /// Accept `POST /transactions` on the public read port too (the node's
    /// `--public-submit`). Absent or false = off; requires `publicRead`.
    public var publicSubmit: Bool?
    /// Listener-wide transaction submission ceiling (`--public-submit-rate`),
    /// in requests per second. Absent = the node's default; `0` disables it.
    public var publicSubmitRate: Double?
    /// The smallest fee the node admits to its pool (`--min-relay-fee`; node
    /// policy, never consensus). Absent = the node's default, 0.
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

    public init(
        listen: UInt16, rpc: UInt16, peers: [String]? = nil,
        publicRead: UInt16? = nil, externalAddress: String? = nil,
        publicReadRate: Double? = nil,
        publicReadExpensiveRate: Double? = nil,
        publicReadMaxRate: Double? = nil, hostedChains: [String]? = nil,
        publicReadURL: String? = nil,
        publicSubmit: Bool? = nil,
        publicSubmitRate: Double? = nil,
        minRelayFee: UInt64? = nil
    ) {
        self.listen = listen
        self.rpc = rpc
        self.peers = peers.map { ChainPeers(byChain: [ChainAddress.nexus: $0]) }
        self.publicRead = publicRead
        self.externalAddress = externalAddress
        self.publicReadRate = publicReadRate
        self.publicReadExpensiveRate = publicReadExpensiveRate
        self.publicReadMaxRate = publicReadMaxRate
        self.publicReadURL = publicReadURL
        self.publicSubmit = publicSubmit
        self.publicSubmitRate = publicSubmitRate
        self.minRelayFee = minRelayFee
        self.hostedChains = hostedChains
    }

    public static let fileName = "lattice.json"

    /// The configuration lattice.json and the fragments of config.d make
    /// together (`MergedConfig`), checked.
    public static func load(root: URL) throws -> Topology {
        try MergedConfig.load(root: root).topology
    }

    /// The `mine` object a lattice.json written before mining was a process
    /// of its own may hold. The node ignores it and never writes it back;
    /// the miner reads it while there is no miner.json.
    public static let retiredMiningKey = "mine"

    /// The warning for a lattice.json that still holds `mine`.
    public static let retiredMiningWarning =
        "mine in \(fileName) is no longer used by the node; the miner reads miner.json"

    /// Whether the lattice.json under `root` still holds `mine`.
    public static func holdsRetiredMining(root: URL) -> Bool {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(fileName)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object[retiredMiningKey] != nil
    }

    /// A `lattice.json`'s content, refusing a key this release does not know
    /// (`mine` is ignored: see `retiredMiningKey`).
    public static func load(data: Data) throws -> Topology {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CtlError("\(fileName) must contain one JSON object")
        }
        let known = Set(CodingKeys.allCases.map(\.rawValue))
        let unknown = Set(object.keys).subtracting(known).subtracting([retiredMiningKey]).sorted()
        guard unknown.isEmpty else {
            throw CtlError("unknown \(fileName) key(s): \(unknown.joined(separator: ", "))")
        }
        return try JSONDecoder().decode(Topology.self, from: data)
    }

    public func save(root: URL) throws {
        try writeDurably(canonicalData(), to: root.appendingPathComponent(Self.fileName))
    }

    /// This configuration as `save` writes it: sorted keys, so two equal
    /// configurations are equal bytes.
    public func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(self)
    }

    /// Nexus's list replaces the built-in peers (empty: none at all); a
    /// child's list is extra seeds for that chain, and an empty one is the
    /// same as none.
    public var peerArguments: [String] {
        var arguments: [String] = []
        if let nexus = peers?.byChain[ChainAddress.nexus] {
            arguments += nexus.isEmpty ? ["--no-default-peers"] : ["--peer"] + nexus
        }
        for (chain, list) in (peers?.byChain ?? [:]).sorted(by: { $0.key < $1.key })
        where chain != ChainAddress.nexus {
            for peer in list { arguments += ["--chain-peer", "\(chain)=\(peer)"] }
        }
        return arguments
    }

    public func validated() throws -> Topology {
        var listed: Set<String> = [ChainAddress.nexus]
        for child in hostedChains ?? [] {
            guard let childAddress = ChainAddress(string: child), childAddress.key == child,
                  !childAddress.isNexus, let parent = childAddress.parent, listed.contains(parent.key),
                  listed.insert(child).inserted else {
                throw CtlError("hosted chain \(child) is not a new Nexus-rooted path listed after its parent")
            }
        }
        for chain in (peers?.byChain ?? [:]).keys where !listed.contains(chain) {
            throw CtlError("peers are listed for \(chain), which is not a hosted chain")
        }
        for (chain, list) in peers?.byChain ?? [:] {
            for peer in list where Self.peerEndpoint(peer) == nil {
                throw CtlError("peer \(peer) for \(chain) is not public-key@host:port")
            }
        }
        if let blockBodies, blockBodies != "all", blockBodies != "none" {
            throw CtlError("blockBodies is all or none, not \(blockBodies)")
        }
        if let state, StateRetention(named: state) == nil {
            throw CtlError("state is all, recent or none, not \(state)")
        }
        if stateWindow != nil || !(stateWindows ?? [:]).isEmpty, StateRetention(named: state ?? "all") != .recent {
            throw CtlError("a state window applies to state recent only")
        }
        if stateWindow == 0 || (stateWindows ?? [:]).values.contains(0) {
            throw CtlError("a state window is at least 1 block")
        }
        for path in (stateWindows ?? [:]).keys
        where ChainAddress(path.split(separator: "/").map(String.init)) == nil {
            throw CtlError("stateWindows names \(path), which is not a chain path")
        }
        for path in (finalityWindows ?? [:]).keys
        where ChainAddress(path.split(separator: "/").map(String.init)) == nil {
            throw CtlError("finalityWindows names \(path), which is not a chain path")
        }
        if let announceLifetime, !(1...NodeConfiguration.maximumAnnounceLifetime).contains(announceLifetime) {
            throw CtlError(NodeConfigurationError.invalidAnnounceLifetime.description)
        }
        var ports: Set<UInt16> = []
        for port in [listen, rpc] + (publicRead.map { [$0] } ?? []) {
            guard port != 0, ports.insert(port).inserted else {
                throw CtlError("port \(port) is zero or used twice")
            }
        }
        if let webSocket, webSocket != 0, !ports.insert(webSocket).inserted {
            throw CtlError("port \(webSocket) is used twice")
        }
        for (name, rate) in [
            ("publicReadRate", publicReadRate),
            ("publicReadExpensiveRate", publicReadExpensiveRate),
            ("publicReadMaxRate", publicReadMaxRate),
            ("publicSubmitRate", publicSubmitRate),
        ] {
            if let rate, !rate.isFinite || rate < 0 {
                throw CtlError("\(name) must be finite and nonnegative")
            }
        }
        guard (operatorListen == nil) == (operatorTokens == nil) else {
            throw CtlError("operatorListen and operatorTokens go together")
        }
        if let operatorListen {
            guard let (host, port) = Self.hostPort(operatorListen), Self.isAddressLiteral(host) else {
                throw CtlError("operatorListen must be address:port, the address an IPv4 or IPv6 literal ([::1]:8090) or localhost")
            }
            guard !ports.contains(port), port != webSocket else {
                throw CtlError("operatorListen must use a port of its own, not one of listen, rpc, publicRead or webSocket")
            }
        }
        if operatorAllowedOrigins != nil, operatorListen == nil {
            throw CtlError("operatorAllowedOrigins requires operatorListen")
        }
        if let publicReadURL, !NodeConfiguration.isValidPublicReadURL(publicReadURL) {
            throw CtlError("publicReadURL must be an absolute http(s) URL with a host and no credentials, query or fragment")
        }
        let sessionBytes = NodeResourcePolicy.default.maximumAcquisitionStorageBytes
        if let maxAcquisitionBytes, maxAcquisitionBytes < sessionBytes {
            throw CtlError("maxAcquisitionBytes must be at least \(sessionBytes), the bytes one block's fetch may hold")
        }
        if let publicReadFetches, publicReadFetches < 0 {
            throw CtlError("publicReadFetches must be nonnegative")
        }
        if publicSubmit == true, publicRead == nil {
            throw CtlError("publicSubmit requires publicRead")
        }
        return self
    }

    /// Node flags for the content-serving limits, what the node keeps and
    /// how long its announcements last, in `lattice.json`.
    public var contentServingArguments: [String] {
        var arguments: [String] = []
        if let value = servingMaxConcurrent { arguments += ["--serving-max-concurrent", String(value)] }
        if let value = servingMaxInFlightVolumeBytes {
            arguments += ["--serving-max-in-flight-volume-bytes", String(value)]
        }
        if let value = maxAcquisitionBytes { arguments += ["--max-acquisition-bytes", String(value)] }
        if let value = blockBodies { arguments += ["--block-bodies", value] }
        if let value = state { arguments += ["--state", value] }
        if let value = stateWindow { arguments += ["--state-window", String(value)] }
        for (path, value) in (stateWindows ?? [:]).sorted(by: { $0.key < $1.key }) {
            arguments += ["--state-window", "\(path)=\(value)"]
        }
        if let value = finalityWindow { arguments += ["--finality-window", String(value)] }
        for (path, value) in (finalityWindows ?? [:]).sorted(by: { $0.key < $1.key }) {
            arguments += ["--finality-window", "\(path)=\(value)"]
        }
        if let value = announceLifetime { arguments += ["--announce-lifetime", String(value)] }
        return arguments
    }

    /// Node flags represented by the public submission policy in
    /// `lattice.json`. Keeping this translation in the config model makes it
    /// directly testable instead of relying on daemon-flag tests alone.
    public var publicSubmissionArguments: [String] {
        var arguments: [String] = []
        if publicSubmit == true { arguments.append("--public-submit") }
        if let publicSubmitRate {
            arguments += ["--public-submit-rate", String(publicSubmitRate)]
        }
        if let minRelayFee { arguments += ["--min-relay-fee", String(minRelayFee)] }
        return arguments
    }
}

public struct CtlError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Filesystem layout under the data root. Identity keys live OUTSIDE the
/// wipeable chain directories so a flag-day wipe never destroys identity.
public struct HostLayout: Sendable {
    public let root: URL

    public init(root: String?) {
        self.root = URL(fileURLWithPath: root
            ?? FileManager.default.currentDirectoryPath)
    }

    /// A hosted child chain's spec, the one its genesis is mined from.
    public func childSpec(for path: String) -> URL {
        root.appendingPathComponent("specs").appendingPathComponent(Self.encoded(path) + ".json")
    }

    /// The account a hosted child's genesis pays its premine to, kept beside
    /// the spec.
    public func premineRecipient(for path: String) -> URL {
        root.appendingPathComponent("specs").appendingPathComponent(Self.encoded(path) + ".premine-to")
    }

    /// The signed transactions a hosted child's genesis carries after its
    /// premine, kept beside the spec.
    public func genesisTransactions(for path: String) -> URL {
        root.appendingPathComponent("specs").appendingPathComponent(Self.encoded(path) + ".genesis.json")
    }

    /// The WASM policy modules a hosted child's spec names, one file per
    /// module, kept beside the spec.
    public func policyModules(for path: String) -> URL {
        root.appendingPathComponent("specs").appendingPathComponent(Self.encoded(path) + ".policies")
    }

    /// The one process identity. Callers pass `Nexus`; the parameter keeps
    /// filesystem helpers explicit about what the file belongs to.
    public func identityKey(for path: String) -> URL {
        root.appendingPathComponent("identity")
            .appendingPathComponent(Self.encoded(path) + ".key")
    }

    public func chainDirectory(for path: String) -> URL {
        root.appendingPathComponent("chains").appendingPathComponent(path)
    }

    /// The loopback RPC cookie the node writes at every start: the default
    /// `.cookie` in the data directory `lattice up` gives it.
    public var rpcCookie: URL {
        chainDirectory(for: "Nexus").appendingPathComponent(".cookie")
    }

    private static func encoded(_ path: String) -> String {
        path.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.alphanumerics.union(
                CharacterSet(charactersIn: "._-")
            )
        ) ?? path
    }

    /// Where a node asked to wipe its storage (`POST /wipe`) records it,
    /// outside the storage it wipes: its next start removes the storage
    /// directory before opening it, then this file.
    public var wipeRequest: URL {
        root.appendingPathComponent("run").appendingPathComponent("wipe-requested")
    }

    public func pidFile(for path: String) -> URL {
        root.appendingPathComponent("run").appendingPathComponent(
            path.replacingOccurrences(of: "/", with: "-") + ".pid"
        )
    }

    /// Removes `path`'s pidfile only while it still names `pid`: a stop
    /// must never delete the pidfile of a process started after it.
    public func removePidFile(for path: String, ifNaming pid: Int32) {
        let url = pidFile(for: path)
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              text.split(separator: " ").first.flatMap({ Int32($0) }) == pid
        else { return }
        try? FileManager.default.removeItem(at: url)
    }

    public func logFile(for path: String) -> URL {
        root.appendingPathComponent("log").appendingPathComponent(
            path.replacingOccurrences(of: "/", with: "-") + ".log"
        )
    }
}
