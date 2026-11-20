import Foundation
import LatticeNodeCore

/// Prometheus text exposition format 0.0.4.
public let nodeMetricsContentType = "text/plain; version=0.0.4"

struct NodeMetricsSample: Sendable {
    let chainPath: [String]
    /// Deepest validated main-chain tip; nil while awaiting genesis.
    let validatedTipHeight: UInt64?
    /// Canonical (weighed-inclusive) main-chain tip; nil while awaiting genesis.
    let weighedTipHeight: UInt64?
    let overlayPeers: Int
    let mempoolTransactions: Int
    let processStartTime: Date
    /// Every hosted chain, the root first: its tip heights, and when its
    /// acted-on tip last moved (nil before it has a tip).
    let chains: [Chain]
    /// Template and submission answer times, and submissions on stale
    /// templates (`MiningMetrics`); nil renders none.
    let mining: MiningMetrics.Snapshot?

    struct Chain: Sendable {
        let path: [String]
        let validatedTipHeight: UInt64?
        let weighedTipHeight: UInt64?
        let tipAdvancedAt: Double?
        /// What its tip waits on (`ChainProgress`), its latches, and its jobs
        /// waiting for a worker, as `/status` reports them; nil before the
        /// chain's first step.
        var blockedOn: String? = nil
        var synced: Bool? = nil
        var headersSynced: Bool? = nil
        var jobsQueued: Int? = nil
    }

    init(
        chainPath: [String],
        validatedTipHeight: UInt64?,
        weighedTipHeight: UInt64?,
        overlayPeers: Int,
        mempoolTransactions: Int,
        processStartTime: Date,
        chains: [Chain] = [],
        mining: MiningMetrics.Snapshot? = nil
    ) {
        self.chainPath = chainPath
        self.validatedTipHeight = validatedTipHeight
        self.weighedTipHeight = weighedTipHeight
        self.overlayPeers = overlayPeers
        self.mempoolTransactions = mempoolTransactions
        self.processStartTime = processStartTime
        self.chains = chains
        self.mining = mining
    }
}

func renderNodeMetrics(_ sample: NodeMetricsSample) -> String {
    let chain = "chain=\"\(escapeMetricLabelValue(sample.chainPath.joined(separator: "/")))\""
    var output = ""
    func label(_ path: [String]) -> String { "chain=\"\(escapeMetricLabelValue(path.joined(separator: "/")))\"" }
    func family(_ name: String, _ help: String, _ samples: [(String, String)], type: String = "gauge") {
        output += "# HELP \(name) \(help)\n# TYPE \(name) \(type)\n"
        for (labels, value) in samples {
            output += "\(name){\(labels)} \(value)\n"
        }
    }
    family(
        "lattice_chain_tip_height",
        "Main-chain tip height by tier (validated, weighed); absent while awaiting genesis.",
        [("validated", sample.validatedTipHeight), ("weighed", sample.weighedTipHeight)]
            .compactMap { tier, height in
                height.map { ("\(chain),tier=\"\(tier)\"", String($0)) }
            }
            + sample.chains.filter { $0.path != sample.chainPath }.flatMap { child in
                [("validated", child.validatedTipHeight), ("weighed", child.weighedTipHeight)].compactMap { tier, height in
                    height.map { ("\(label(child.path)),tier=\"\(tier)\"", String($0)) }
                }
            }
    )
    family(
        "lattice_overlay_peers",
        "Authenticated hosted-tree overlay peers; in-process parent/child links are not counted.",
        [(chain, String(sample.overlayPeers))]
    )
    family(
        "lattice_mempool_transactions",
        "Transactions in the mempool.",
        [(chain, String(sample.mempoolTransactions))]
    )
    family(
        "lattice_chain_tip_advanced_timestamp_seconds",
        "When each hosted chain's acted-on tip last moved, in unix seconds; with tip heights below the weighed tip, an old one is a stall.",
        sample.chains.compactMap { chain in chain.tipAdvancedAt.map { (label(chain.path), String($0)) } }
    )
    family(
        "lattice_chain_blocked_on",
        "What each hosted chain's acted-on tip waits on: every reason (atTip, headers, proofs, parent, bodies, bodiesUnavailable, execution, stalled), 1 for the current one and 0 for the rest.",
        sample.chains.flatMap { chain in
            chain.blockedOn.map { current in
                ChainProgress.allCases.map { reason in
                    ("\(label(chain.path)),on=\"\(escapeMetricLabelValue(reason.rawValue))\"", reason.rawValue == current ? "1" : "0")
                }
            } ?? []
        }
    )
    family(
        "lattice_chain_synced",
        "Whether each hosted chain has caught up since the process started (1) and so takes peer transactions.",
        sample.chains.compactMap { chain in chain.synced.map { (label(chain.path), $0 ? "1" : "0") } }
    )
    family(
        "lattice_chain_headers_synced",
        "Whether each hosted chain has weighed a peer's whole log since the process started (1): its children read their peers, and it relays.",
        sample.chains.compactMap { chain in chain.headersSynced.map { (label(chain.path), $0 ? "1" : "0") } }
    )
    family(
        "lattice_chain_jobs_queued",
        "Each hosted chain's jobs waiting for a worker.",
        sample.chains.compactMap { chain in chain.jobsQueued.map { (label(chain.path), String($0)) } }
    )
    if let mining = sample.mining {
        func histogram(_ name: String, _ help: String, _ series: [(String, MiningMetrics.Histogram.Snapshot)]) {
            output += "# HELP \(name) \(help)\n# TYPE \(name) histogram\n"
            let bounds = MiningMetrics.bounds.map { "\($0)" } + ["+Inf"]
            for (labels, histogram) in series {
                for (bound, count) in zip(bounds, histogram.cumulative) {
                    output += "\(name)_bucket{\(labels),le=\"\(bound)\"} \(count)\n"
                }
                output += "\(name)_sum{\(labels)} \(histogram.seconds)\n"
                output += "\(name)_count{\(labels)} \(histogram.count)\n"
            }
        }
        histogram(
            "lattice_template_build_seconds",
            "Time to answer a mining template request, by outcome: ok (a template), or the refusal (busy, executing, buildFailed).",
            mining.templates.map { ("\(chain),outcome=\"\($0.outcome)\"", $0.1) }
        )
        histogram(
            "lattice_work_submission_seconds",
            "Time to answer a work submission, by outcome: the disposition answered (canonicalized, acceptedSide, childOnly, duplicate, invalid), unknownWork, missesSearchTarget, or error.",
            mining.submissions.map { ("\(chain),outcome=\"\($0.outcome)\"", $0.1) }
        )
        family(
            "lattice_work_submissions_stale_total",
            "Work submissions whose nonce cleared the search target on work whose tip was no longer the act-on tip.",
            [(chain, String(mining.staleSubmissions))],
            type: "counter"
        )
    }
    family(
        "process_start_time_seconds",
        "Start time of the process since unix epoch in seconds.",
        [(chain, String(sample.processStartTime.timeIntervalSince1970))]
    )
    return output
}

/// Label-value escaping per the exposition format: backslash, double quote and
/// line feed. Chain paths are operator-supplied. Scalars, not Characters, so a
/// CRLF grapheme cannot carry a raw line feed past the `\n` case.
func escapeMetricLabelValue(_ value: String) -> String {
    var escaped = ""
    for scalar in value.unicodeScalars {
        switch scalar {
        case "\\": escaped += "\\\\"
        case "\"": escaped += "\\\""
        case "\n": escaped += "\\n"
        default: escaped.unicodeScalars.append(scalar)
        }
    }
    return escaped
}
