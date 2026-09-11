import Foundation

/// Prometheus text exposition format 0.0.4.
public let nodeMetricsContentType = "text/plain; version=0.0.4"

extension ChainService {
    /// The operator `/metrics` exposition. Reads the same ungated snapshot as
    /// `/health` plus the O(1) canonical tip: no operation gate, no history walk.
    public func metricsExposition(peers: Int, processStartTime: Date) async -> String {
        let snapshot = await readSnapshot()
        return renderNodeMetrics(NodeMetricsSample(
            chainPath: snapshot.chainPath,
            validatedTipHeight: snapshot.height,
            weighedTipHeight: await canonicalTipHeight(),
            peers: peers,
            mempoolTransactions: snapshot.mempoolCount,
            processStartTime: processStartTime
        ))
    }
}

struct NodeMetricsSample: Sendable, Equatable {
    let chainPath: [String]
    /// Deepest validated main-chain tip; nil while awaiting genesis.
    let validatedTipHeight: UInt64?
    /// Canonical (weighed-inclusive) main-chain tip; nil while awaiting genesis.
    let weighedTipHeight: UInt64?
    let peers: Int
    let mempoolTransactions: Int
    let processStartTime: Date
}

func renderNodeMetrics(_ sample: NodeMetricsSample) -> String {
    let chain = "chain=\"\(escapeMetricLabelValue(sample.chainPath.joined(separator: "/")))\""
    var output = ""
    func family(_ name: String, _ help: String, _ samples: [(String, String)]) {
        output += "# HELP \(name) \(help)\n# TYPE \(name) gauge\n"
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
        "lattice_peers",
        "Authenticated same-chain overlay peers.",
        [(chain, String(sample.peers))]
    )
    family(
        "lattice_mempool_transactions",
        "Transactions in the mempool.",
        [(chain, String(sample.mempoolTransactions))]
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
