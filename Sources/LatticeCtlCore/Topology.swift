// The declarative unit `lattice` operates on: one host's chain-process tree.
//
// Lattice runs one process per chain; a child authenticates against its
// immediate parent's fact plane. This file makes that tree a value: each
// entry is one process, parents are derived from chain paths, and every
// verb reconciles against it rather than accumulating flag invocations.

import Foundation
import Lattice
import LatticeNode

public struct TopologyChain: Codable {
    public var listen: UInt16
    public var fact: UInt16
    public var rpc: UInt16
    /// Overlay bootstrap peers as `publicKey@host:port`. Only meaningful
    /// entries for this chain's own path; children of a local parent are
    /// wired to it automatically.
    public var peers: [String]?
    /// Public read-only HTTP port (the node's `--public-read-port`): binds
    /// all interfaces and serves only the bounded GET read routes. Absent =
    /// no public read listener for this chain's process.
    public var publicRead: UInt16?
    /// Self-described publicly reachable host (the node's
    /// `--external-address`) for overlay announcements from NAT/proxy-fronted
    /// processes. Host only; the chain's listen port applies.
    public var externalAddress: String?
    /// Operator-declared browsable base URL (the node's `--public-read-url`)
    /// for this chain's public read surface: a TLS-fronted hostname a browser
    /// can dial, advertised through the parent rendezvous. Distinct from
    /// `externalAddress`, which the P2P plane constrains to IP literals.
    public var publicReadUrl: String?
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

    public init(
        listen: UInt16, fact: UInt16, rpc: UInt16, peers: [String]? = nil,
        publicRead: UInt16? = nil, externalAddress: String? = nil,
        publicReadUrl: String? = nil, publicReadRate: Double? = nil,
        publicReadExpensiveRate: Double? = nil,
        publicReadMaxRate: Double? = nil
    ) {
        self.listen = listen
        self.fact = fact
        self.rpc = rpc
        self.peers = peers
        self.publicRead = publicRead
        self.externalAddress = externalAddress
        self.publicReadUrl = publicReadUrl
        self.publicReadRate = publicReadRate
        self.publicReadExpensiveRate = publicReadExpensiveRate
        self.publicReadMaxRate = publicReadMaxRate
    }
}

public struct TopologyMine: Codable {
    public var chain: String
    /// "cpu" or a path to any contract-conforming worker executable.
    public var worker: String?
    public var workers: Int?
    public var batchSize: UInt64?
    /// A `lattice-rewards emit-batch` file; the cursor lives beside it.
    public var rewards: String?
    /// Minimum work per block by chain path (e.g. `{"Nexus": "2^32"}`),
    /// passed to the coordinator as `--min-work`. The miner only searches for
    /// and submits hashes that meet it; blocks still commit their scheduled
    /// target. A chain left out mines at its scheduled target.
    public var minWork: [String: String]?
    /// `true` commits each `minWork` target into that chain's blocks instead
    /// of the scheduled target (coordinator `--commit-min-work-target`).
    /// Absent or `false` — the default — blocks commit the schedule.
    public var commitMinWorkTarget: Bool?
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
    /// not bounded by it. Set it above what `POST /v1/mining/templates` costs
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
        chain: String, worker: String? = nil, workers: Int? = nil,
        batchSize: UInt64? = nil, rewards: String? = nil,
        minWork: [String: String]? = nil,
        commitMinWorkTarget: Bool? = nil,
        minBlockIntervalSeconds: UInt64? = nil,
        templateTimeoutSeconds: UInt64? = nil,
        roundDeadlineMultiplier: Int? = nil
    ) {
        self.chain = chain
        self.worker = worker
        self.workers = workers
        self.batchSize = batchSize
        self.rewards = rewards
        self.minWork = minWork
        self.commitMinWorkTarget = commitMinWorkTarget
        self.minBlockIntervalSeconds = minBlockIntervalSeconds
        self.templateTimeoutSeconds = templateTimeoutSeconds
        self.roundDeadlineMultiplier = roundDeadlineMultiplier
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

    /// The coordinator arguments for `minWork` and `commitMinWorkTarget`.
    public var coordinatorMinimumWorkArguments: [String] {
        minimumWorkEntries.flatMap { ["--min-work", $0] }
            + (commitMinWorkTarget == true ? ["--commit-min-work-target"] : [])
    }
}

public struct Topology: Codable {
    /// Chain path key (e.g. "Nexus", "Nexus/Payments") to process settings.
    public var chains: [String: TopologyChain]
    public var mine: TopologyMine?

    public init(
        chains: [String: TopologyChain], mine: TopologyMine? = nil
    ) {
        self.chains = chains
        self.mine = mine
    }

    public static let fileName = "lattice.json"

    public static func load(root: URL) throws -> Topology {
        let url = root.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else {
            throw CtlError("no \(fileName) in \(root.path); run `lattice init` first")
        }
        return try JSONDecoder().decode(Topology.self, from: data)
    }

    public func save(root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(self).write(
            to: root.appendingPathComponent(Self.fileName),
            options: .atomic
        )
    }

    /// Parent-before-child order, so `up` can wire children to a parent
    /// that is already running.
    public func orderedPaths() -> [String] {
        chains.keys.sorted { $0.components(separatedBy: "/").count
            < $1.components(separatedBy: "/").count || $0 < $1 }
    }

    public func validated() throws -> Topology {
        var ports: Set<UInt16> = []
        for (path, chain) in chains {
            guard let address = ChainAddress(string: path),
                  address.key == path,
                  address.components.allSatisfy({
                      $0 != "." && $0 != ".." && !$0.contains("/")
                  }) else {
                throw CtlError("chain path is not absolute and Nexus-rooted: \(path)")
            }
            if address.components.count > 1 {
                let parent = address.components.dropLast().joined(separator: "/")
                guard chains[parent] != nil else {
                    throw CtlError("\(path) has no local parent \(parent); every child needs its immediate parent in the tree")
                }
            }
            for port in [chain.listen, chain.fact, chain.rpc]
                + (chain.publicRead.map { [$0] } ?? []) {
                guard ports.insert(port).inserted else {
                    throw CtlError("port \(port) is used twice")
                }
            }
        }
        if let mine, chains[mine.chain] == nil {
            throw CtlError("mine.chain \(mine.chain) is not in the tree")
        }
        if let mine, mine.commitMinWorkTarget == true, mine.minimumWorkEntries.isEmpty {
            throw CtlError("mine.commitMinWorkTarget commits the mine.minWork targets and needs at least one mine.minWork entry")
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

    public func identityKey(for path: String) -> URL {
        root.appendingPathComponent("identity")
            .appendingPathComponent(
                path.replacingOccurrences(of: "/", with: "-") + ".key"
            )
    }

    public func chainDirectory(for path: String) -> URL {
        root.appendingPathComponent("chains").appendingPathComponent(path)
    }

    /// An in-flight `child deploy` (genesis seed + signed anchor). Outside the
    /// wipeable chain directories: the anchor may land on the parent at any
    /// time, and without this file its genesis could never be rebuilt.
    public func pendingDeploy(for path: String) -> URL {
        // Percent-encoded, not `/`-flattened: `-` is a legal directory atom,
        // so flattening would give `Nexus/A/B` and `Nexus/A-B` one file, and
        // one child's genesis seed would overwrite the other's.
        let encoded = path.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.alphanumerics.union(
                CharacterSet(charactersIn: "._-")
            )
        ) ?? path
        return root.appendingPathComponent("pending-deploy")
            .appendingPathComponent(encoded + ".json")
    }

    public func pidFile(for path: String) -> URL {
        root.appendingPathComponent("run").appendingPathComponent(
            path.replacingOccurrences(of: "/", with: "-") + ".pid"
        )
    }

    public func logFile(for path: String) -> URL {
        root.appendingPathComponent("log").appendingPathComponent(
            path.replacingOccurrences(of: "/", with: "-") + ".log"
        )
    }
}
