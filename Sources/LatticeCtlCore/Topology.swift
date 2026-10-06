// The declarative unit `lattice` operates on: one host's chain tree.
//
// One lattice-node process hosts every chain in the tree; a child
// reads its parent facts in-process.
// This file makes that host a value: process settings live once, and hosted
// child paths are levels of that process rather than process-shaped entries.

import Foundation
import Lattice
import LatticeNode

public struct Topology: Codable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case listen, rpc, peers, publicRead, externalAddress
        case publicReadRate, publicReadExpensiveRate, publicReadMaxRate
        case publicReadURL, publicSubmit, publicSubmitRate, minRelayFee
        case hostedChains, mine, rpcAllowedOrigins
    }
    public var listen: UInt16
    public var rpc: UInt16
    /// Overlay bootstrap peers as `publicKey@host:port`.
    public var peers: [String]?
    /// Public read-only HTTP port (the node's `--public-read-port`): binds
    /// all interfaces and serves only the bounded GET read routes. Absent =
    /// no public read listener for this hosted tree.
    public var publicRead: UInt16?
    /// Self-described publicly reachable host (the node's
    /// `--external-address`) for overlay announcements from NAT/proxy-fronted
    /// processes. Host only; the chain's listen port applies.
    public var externalAddress: String?
    /// Per-client arrival-rate ceilings for the public read listener (the
    /// node's `--public-read-rate` / `--public-read-expensive-rate`), in
    /// requests per second. The client is the peer socket address, so a host
    /// behind a proxy that presents ONE address for every client must set
    /// these to `0` — otherwise the whole internet is throttled as one user.
    /// Absent = the node's defaults.
    public var publicReadRate: Double?
    public var publicReadExpensiveRate: Double?
    /// Listener-wide arrival-rate ceiling (`--public-read-max-rate`), in
    /// requests per second. Address-agnostic, so it stays correct behind such
    /// a proxy. Absent = the node's default; `0` disables it.
    public var publicReadMaxRate: Double?
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
    /// Child chains this process hosts as levels, parent before child.
    public var hostedChains: [String]?
    public var mine: TopologyMine?
    /// Browser origins allowed on the loopback RPC port (the node's
    /// `--rpc-allowed-origin`), e.g. `chrome-extension://<id>`. Each still
    /// needs the node's cookie. Absent = browsers are refused.
    public var rpcAllowedOrigins: [String]? = nil

    public init(
        listen: UInt16, rpc: UInt16, peers: [String]? = nil,
        publicRead: UInt16? = nil, externalAddress: String? = nil,
        publicReadRate: Double? = nil,
        publicReadExpensiveRate: Double? = nil,
        publicReadMaxRate: Double? = nil, hostedChains: [String]? = nil,
        mine: TopologyMine? = nil, publicReadURL: String? = nil,
        publicSubmit: Bool? = nil,
        publicSubmitRate: Double? = nil,
        minRelayFee: UInt64? = nil
    ) {
        self.listen = listen
        self.rpc = rpc
        self.peers = peers
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
        self.mine = mine
    }

    public static let fileName = "lattice.json"

    public static func load(root: URL) throws -> Topology {
        let url = root.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else {
            throw CtlError("no \(fileName) in \(root.path); run `lattice init` first")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CtlError("\(fileName) must contain one JSON object")
        }
        let known = Set(CodingKeys.allCases.map(\.rawValue))
        let unknown = Set(object.keys).subtracting(known).sorted()
        guard unknown.isEmpty else {
            throw CtlError("unknown \(fileName) key(s): \(unknown.joined(separator: ", "))")
        }
        return try JSONDecoder().decode(Topology.self, from: data)
    }

    public func save(root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try writeDurably(
            encoder.encode(self), to: root.appendingPathComponent(Self.fileName)
        )
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
        var ports: Set<UInt16> = []
        for port in [listen, rpc] + (publicRead.map { [$0] } ?? []) {
            guard port != 0, ports.insert(port).inserted else {
                throw CtlError("port \(port) is zero or used twice")
            }
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
        if let publicReadURL, !NodeConfiguration.isValidPublicReadURL(publicReadURL) {
            throw CtlError("publicReadURL must be an absolute http(s) URL with a host and no credentials, query or fragment")
        }
        if publicSubmit == true, publicRead == nil {
            throw CtlError("publicSubmit requires publicRead")
        }
        if let workers = mine?.workers, workers < 1 {
            throw CtlError("mine.workers must be at least 1")
        }
        if let batchSize = mine?.batchSize, batchSize < 1 {
            throw CtlError("mine.batchSize must be at least 1")
        }
        for path in Set((mine?.recipients ?? [:]).keys)
            .union((mine?.minWork ?? [:]).keys) where !listed.contains(path) {
            throw CtlError("mining configuration names unhosted chain \(path)")
        }
        if let timeout = mine?.templateTimeoutSeconds, timeout < 1 {
            throw CtlError("mine.templateTimeoutSeconds must be at least 1; a zero timeout can never observe a template expiry, so no round deadline could be derived and the miner would never mine")
        }
        if let timeout = mine?.templateTimeoutSeconds,
           timeout > TopologyMine.maximumTemplateTimeoutSeconds {
            throw CtlError("mine.templateTimeoutSeconds must be at most \(TopologyMine.maximumTemplateTimeoutSeconds); the coordinator's own template fetch is fixed at that, so a longer probe would observe expiries for rounds that then die fetching the same template")
        }
        if let multiplier = mine?.roundDeadlineMultiplier, multiplier < 1 {
            throw CtlError("mine.roundDeadlineMultiplier must be at least 1; a round deadline shorter than the round's own bound would kill every healthy round")
        }
        return self
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

public struct TopologyMine: Codable, Sendable {
    /// "cpu" or a path to any contract-conforming worker executable.
    public var worker: String?
    public var workers: Int?
    public var batchSize: UInt64?
    /// Where each chain's block reward and fees go, by chain path (e.g.
    /// `{"Nexus": "bafy..."}`), passed to the coordinator as `--recipient`.
    /// A chain left out mines to no one: its reward and fees burn.
    public var recipients: [String: String]?
    /// Minimum work per block by chain path (e.g. `{"Nexus": "2^32"}`),
    /// passed to the coordinator as `--min-work`. The miner only searches for
    /// and submits hashes that meet it; blocks still commit their scheduled
    /// target. A chain left out mines at its scheduled target.
    public var minWork: [String: String]?
    /// Shortest gap, in seconds, between the template builds of two
    /// consecutive parent blocks this miner produces. A floor, never a
    /// ceiling: a round that already ran longer waits not at all, so the
    /// cadence stops binding by itself once the schedule alone is slower than
    /// it. Unlike `minWork`, which fixes the work per block and so leaves the
    /// retarget with no feedback, this fixes the spacing the retarget reads
    /// and leaves the work to the schedule. Absent = produce blocks as fast as
    /// they solve.
    public var minBlockIntervalSeconds: UInt64?
    /// How long to wait for the node to ANSWER a template request, in seconds.
    /// This bounds how long the node takes to BUILD a template, which is a
    /// different quantity from the template lifetime the answer reports and is
    /// not bounded by it. Set it above what `POST /mining/templates` costs
    /// on this host: if it is lower, no round deadline can be derived and the
    /// miner will not mine at all (#153, where a 15s compiled-in value sat
    /// under a 16.6s build). Keep it at or below the coordinator's own request
    /// timeout, since a probe that tolerates more than the mining path does
    /// will observe an expiry for rounds that cannot then run. Absent = 60s.
    public var templateTimeoutSeconds: UInt64?
    /// Headroom multiplier on the mining round deadline. The loop measures a
    /// round's own bound — the node's advertised template expiry plus the
    /// longest round that has actually completed — and refuses to wait longer
    /// than that times this. It exists because a supervisor that trusts a
    /// child's exit signal can wait forever (#62). Raise it on a host whose
    /// rounds legitimately run long; lower it to notice a wedge sooner.
    /// Absent = the default headroom.
    public var roundDeadlineMultiplier: Int?

    public init(
        worker: String? = nil, workers: Int? = nil,
        batchSize: UInt64? = nil, recipients: [String: String]? = nil,
        minWork: [String: String]? = nil,
        minBlockIntervalSeconds: UInt64? = nil,
        templateTimeoutSeconds: UInt64? = nil,
        roundDeadlineMultiplier: Int? = nil
    ) {
        self.worker = worker
        self.workers = workers
        self.batchSize = batchSize
        self.recipients = recipients
        self.minWork = minWork
        self.minBlockIntervalSeconds = minBlockIntervalSeconds
        self.templateTimeoutSeconds = templateTimeoutSeconds
        self.roundDeadlineMultiplier = roundDeadlineMultiplier
    }

    private enum CodingKeys: String, CodingKey {
        case worker, workers, batchSize, recipients, minWork
        case minBlockIntervalSeconds, templateTimeoutSeconds
        case roundDeadlineMultiplier
    }

    private enum RetiredKeys: String, CodingKey {
        case chain, rewards
    }

    public init(from decoder: any Decoder) throws {
        let retired = try decoder.container(keyedBy: RetiredKeys.self)
        for key in [RetiredKeys.chain, .rewards] where retired.contains(key) {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: retired,
                debugDescription: "Retired mining configuration key \(key.stringValue); this release accepts only the current topology format"
            )
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            worker: try container.decodeIfPresent(String.self, forKey: .worker),
            workers: try container.decodeIfPresent(Int.self, forKey: .workers),
            batchSize: try container.decodeIfPresent(UInt64.self, forKey: .batchSize),
            recipients: try container.decodeIfPresent([String: String].self, forKey: .recipients),
            minWork: try container.decodeIfPresent([String: String].self, forKey: .minWork),
            minBlockIntervalSeconds: try container.decodeIfPresent(
                UInt64.self, forKey: .minBlockIntervalSeconds
            ),
            templateTimeoutSeconds: try container.decodeIfPresent(
                UInt64.self, forKey: .templateTimeoutSeconds
            ),
            roundDeadlineMultiplier: try container.decodeIfPresent(
                Int.self, forKey: .roundDeadlineMultiplier
            )
        )
    }


    /// The default behind `templateTimeoutSeconds`: the `URLRequest` default
    /// that the coordinator's own template fetch runs under, having set no
    /// timeout of its own. An operator may raise this for a host whose
    /// templates cost more to build, but raising it past what the coordinator
    /// tolerates buys nothing -- the probe would observe an expiry for rounds
    /// that then fail fetching the same template.
    public static let defaultTemplateTimeoutSeconds: UInt64 = 60

    /// The ceiling, and it is the SAME constant for the same reason: above the
    /// coordinator's own fetch timeout there is no legal value at all. The
    /// probe would observe an expiry and every round would then die fetching
    /// the same template. So this setting is usefully adjustable DOWNWARD
    /// only -- a host that needs longer than this to build a template cannot
    /// be fixed here, because the coordinator's side is not settable at all.
    ///
    /// Bound rather than repeated: `validated()` can only check a value the
    /// operator WROTE, so a tree omitting the field resolves to the default
    /// unchecked. Were these two numbers able to drift, lowering the ceiling
    /// alone would leave every default-valued tree probing above it, silently
    /// and with nothing to refuse.
    public static let maximumTemplateTimeoutSeconds: UInt64 =
        defaultTemplateTimeoutSeconds

    /// `templateTimeoutSeconds` or the default, in seconds.
    public var resolvedTemplateTimeoutSeconds: UInt64 {
        templateTimeoutSeconds ?? Self.defaultTemplateTimeoutSeconds
    }

    /// `minWork` as coordinator `--min-work` values, in path order.
    public var minimumWorkEntries: [String] {
        (minWork ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }

    /// How long to hold the next round so consecutive parent blocks are at
    /// least `minBlockIntervalSeconds` apart, given how long the round that
    /// just produced a block already took. Measured from the round's START,
    /// because a block's timestamp is fixed when its template is built:
    /// spacing template builds is what spaces the timestamps the retarget
    /// reads. Pure, so the release — a round slower than the cadence waits not
    /// at all — is an executable invariant rather than a timing test.
    public func pacingHold(afterRoundOf elapsed: Duration) -> Duration {
        guard let seconds = minBlockIntervalSeconds else { return .zero }
        return max(.zero, .seconds(seconds) - elapsed)
    }

    /// `recipients` as coordinator `--recipient` values, in path order.
    public var recipientEntries: [String] {
        (recipients ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }

    /// The coordinator arguments for `recipients`.
    public var coordinatorRecipientArguments: [String] {
        recipientEntries.flatMap { ["--recipient", $0] }
    }

    /// The coordinator arguments for `minWork`.
    public var coordinatorMinimumWorkArguments: [String] {
        minimumWorkEntries.flatMap { ["--min-work", $0] }

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
