import Foundation

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
    /// Parent run reports credited at a child block (§9.10).
    let parentReportsApplied: UInt64
    /// Parent run reports refused, by Lattice's typed reason; `locationConflict`
    /// is the permanent one.
    let parentReportRefusals: [String: UInt64]
    /// Validate-walk passes parked on a non-verdict (§9.9): a stall the
    /// operator must be able to see, since nothing re-arms it on its own.
    let validateWalkParked: UInt64

    init(
        chainPath: [String],
        validatedTipHeight: UInt64?,
        weighedTipHeight: UInt64?,
        overlayPeers: Int,
        mempoolTransactions: Int,
        processStartTime: Date,
        parentReportsApplied: UInt64 = 0,
        parentReportRefusals: [String: UInt64] = [:],
        validateWalkParked: UInt64 = 0
    ) {
        self.chainPath = chainPath
        self.validatedTipHeight = validatedTipHeight
        self.weighedTipHeight = weighedTipHeight
        self.overlayPeers = overlayPeers
        self.mempoolTransactions = mempoolTransactions
        self.processStartTime = processStartTime
        self.parentReportsApplied = parentReportsApplied
        self.parentReportRefusals = parentReportRefusals
        self.validateWalkParked = validateWalkParked
    }
}

func renderNodeMetrics(_ sample: NodeMetricsSample) -> String {
    let chain = "chain=\"\(escapeMetricLabelValue(sample.chainPath.joined(separator: "/")))\""
    var output = ""
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
    )
    family(
        "lattice_overlay_peers",
        "Authenticated same-chain overlay peers; the parent/child fact-plane link is not counted.",
        [(chain, String(sample.overlayPeers))]
    )
    family(
        "lattice_mempool_transactions",
        "Transactions in the mempool.",
        [(chain, String(sample.mempoolTransactions))]
    )
    family(
        "lattice_parent_run_reports_applied_total",
        "Parent run reports credited at a child block (Lattice spec 9.10).",
        [(chain, String(sample.parentReportsApplied))],
        type: "counter"
    )
    family(
        "lattice_parent_run_reports_refused_total",
        "Parent run reports refused, by reason; locationConflict is permanent.",
        sample.parentReportRefusals.sorted { $0.key < $1.key }.map { reason, count in
            ("\(chain),reason=\"\(escapeMetricLabelValue(reason))\"", String(count))
        },
        type: "counter"
    )
    family(
        "lattice_validate_walk_parked_total",
        "Validate-walk passes parked on a non-verdict (a stall nothing re-arms on its own).",
        [(chain, String(sample.validateWalkParked))],
        type: "counter"
    )
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
