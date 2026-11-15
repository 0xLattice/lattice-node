// The miner's own settings: `<root>/miner.json` (or `lattice mine run
// --config`). The miner is a separate process and a client of a node; the
// node knows nothing of this file and keeps none of it in its lattice.json.

import Foundation
import LatticeMinerCore

public struct MinerConfig: Codable, Sendable {
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
    /// How long to wait for the node to ANSWER a template request, in seconds,
    /// before mining starts. This bounds how long the node takes to BUILD a
    /// template. Set it above what `POST /mining/templates` costs on this
    /// host: if it is lower, the miner will not mine at all (#153, where a
    /// 15s compiled-in value sat under a 16.6s build). Keep it at or below
    /// the coordinator's own request timeout, since a probe that tolerates
    /// more than the mining path does starts rounds that cannot then run.
    /// Absent = 60s.
    public var templateTimeoutSeconds: UInt64?
    /// Headroom multiplier on the mining round deadline. The loop measures
    /// the longest round that has actually completed and refuses to wait
    /// longer than that times this (and never less than the first-round
    /// allowance). It exists because a supervisor that trusts a
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

    private enum CodingKeys: String, CodingKey, CaseIterable {
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
                debugDescription: "Retired mining configuration key \(key.stringValue); this release accepts only the current format"
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
    /// tolerates buys nothing -- the probe would start rounds that then fail
    /// fetching the same template.
    public static let defaultTemplateTimeoutSeconds: UInt64 = 60

    /// The ceiling, and it is the SAME constant for the same reason: above the
    /// coordinator's own fetch timeout there is no legal value at all. The
    /// probe would pass and every round would then die fetching the same
    /// template. So this setting is usefully adjustable DOWNWARD
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

extension MinerConfig {
    public static let fileName = "miner.json"

    /// The settings `file` holds, refusing a key this release does not know:
    /// a misspelt `recipients` would burn every reward.
    public static func load(file: URL) throws -> MinerConfig {
        guard let data = try? Data(contentsOf: file) else {
            throw CtlError("no miner settings at \(file.path); write its worker and recipients there (see `lattice mine --help`)")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CtlError("\(file.path) must contain one JSON object")
        }
        return try load(object, source: file.path)
    }

    /// The settings under `root`: its miner.json, or, while there is none,
    /// the `mine` object a lattice.json there still holds from before mining
    /// was a process of its own (its `enabled` ignored). That object is
    /// copied to miner.json the first time (never over one already there),
    /// so the node dropping it from lattice.json later strands nothing; the
    /// note says so. Nil note when read from miner.json.
    public static func load(root: URL) throws -> (config: MinerConfig, warning: String?) {
        let file = root.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: file.path) { return (try load(file: file), nil) }
        let topologyFile = root.appendingPathComponent(Topology.fileName)
        guard let data = try? Data(contentsOf: topologyFile),
              let topology = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var mine = topology[Topology.retiredMiningKey] as? [String: Any] else {
            return (try load(file: file), nil)
        }
        mine["enabled"] = nil
        let config = try load(mine, source: "\(topologyFile.path) (mine)")
        let copy = try JSONSerialization.data(withJSONObject: mine, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard try createDurably(copy, at: file) else {
            // Another miner copied it first: read what is there.
            return (try load(file: file), nil)
        }
        return (
            config,
            "copied the mine object in \(topologyFile.path) to \(file.path), which the miner reads from now on (the node no longer uses it)"
        )
    }

    private static func load(_ object: [String: Any], source: String) throws -> MinerConfig {
        let unknown = Set(object.keys).subtracting(CodingKeys.allCases.map(\.rawValue)).sorted()
        guard unknown.isEmpty else {
            throw CtlError("\(source): unknown miner setting(s): \(unknown.joined(separator: ", "))")
        }
        do {
            return try JSONDecoder().decode(
                MinerConfig.self, from: JSONSerialization.data(withJSONObject: object)
            ).validated()
        } catch {
            throw CtlError("\(source): \(error)")
        }
    }

    public func validated() throws -> MinerConfig {
        if let workers, workers < 1 {
            throw CtlError("workers must be at least 1")
        }
        if let batchSize, batchSize < 1 {
            throw CtlError("batchSize must be at least 1")
        }
        if MinerLoopLogic.recipientField(recipientEntries) == nil {
            throw CtlError("recipients maps chain paths to addresses")
        }
        if MinerLoopLogic.minimumWorkField(minimumWorkEntries) == nil {
            throw CtlError("minWork maps chain paths to work per block, as 2^N or a positive decimal integer")
        }
        if let templateTimeoutSeconds, templateTimeoutSeconds < 1 {
            throw CtlError("templateTimeoutSeconds must be at least 1; a zero timeout can never see the node answer a template request, so the miner would never mine")
        }
        if let templateTimeoutSeconds, templateTimeoutSeconds > Self.maximumTemplateTimeoutSeconds {
            throw CtlError("templateTimeoutSeconds must be at most \(Self.maximumTemplateTimeoutSeconds); the coordinator's own template fetch is fixed at that, so a longer probe would start rounds that then die fetching the same template")
        }
        if let roundDeadlineMultiplier, roundDeadlineMultiplier < 1 {
            throw CtlError("roundDeadlineMultiplier must be at least 1; a round deadline shorter than the round's own bound would kill every healthy round")
        }
        return self
    }
}
