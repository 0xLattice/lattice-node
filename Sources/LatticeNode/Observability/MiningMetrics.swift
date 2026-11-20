import LatticeNodeAPI
import LatticeNodeCore
import Synchronization

/// Outcome 10's measures (docs/design/node-design.md §1): how long the node
/// takes to answer a template request and a work submission, and how many
/// submissions were on a stale template. Recorded where each is answered —
/// the template and submission RPCs, and the loop for staleness — into
/// atomic counters: no lock, and nothing the loop waits on.
final class MiningMetrics: Sendable {
    /// Bucket upper bounds in seconds, around the targets: a template in
    /// 100 ms and a submission in 50 ms at the 99th percentile.
    static let bounds: [Double] = [0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]

    /// A submission's `outcome` label: the disposition the miner is
    /// answered with, the work refusal's case, or `error` for one refused
    /// before it reached a template (a malformed work ID) or one the node
    /// could not finish (it stopped, or storing the block failed).
    static let outcomes = [
        WorkDisposition.canonicalized, .acceptedSide, .childOnly, .duplicate, .invalid,
    ].map(\.rawValue) + [TemplateError.unknownWork, .missesSearchTarget].map { "\($0)" } + ["error"]

    /// The templates answered, by how long each took.
    let templates = Histogram()
    /// The submissions answered, by outcome, by how long each took.
    let submissions: [String: Histogram] = Dictionary(
        uniqueKeysWithValues: MiningMetrics.outcomes.map { ($0, Histogram()) }
    )
    /// Submissions whose template's digest was no longer the root's: the
    /// node had told miners (`GET /mining/events`, status) to fetch another.
    private let stale = Atomic<UInt64>(0)

    func submitted(_ outcome: String, after duration: Duration) {
        (submissions[outcome] ?? submissions["error"])?.observe(duration)
    }

    func submittedOnStaleTemplate() {
        stale.wrappingAdd(1, ordering: .relaxed)
    }

    static func outcome(of error: any Error) -> String {
        switch error as? TemplateError {
        case .unknownWork?: "\(TemplateError.unknownWork)"
        case .missesSearchTarget?: "\(TemplateError.missesSearchTarget)"
        default: "error"
        }
    }

    var snapshot: Snapshot {
        Snapshot(
            templates: templates.snapshot,
            submissions: Self.outcomes.compactMap { outcome in
                submissions[outcome].map { (outcome, $0.snapshot) }
            }.filter { $0.1.count > 0 },
            staleSubmissions: stale.load(ordering: .relaxed)
        )
    }

    struct Snapshot: Sendable {
        let templates: Histogram.Snapshot
        /// Only the outcomes seen, as a Prometheus client exposes a label
        /// set once it is first used.
        let submissions: [(outcome: String, Histogram.Snapshot)]
        let staleSubmissions: UInt64
    }

    /// A Prometheus histogram over `bounds`: a count per bucket and the sum
    /// of what was observed, each an atomic counter. A scrape reads them one
    /// by one, so it may land between one observation's bucket and its sum.
    final class Histogram: Sendable {
        private final class Counter: Sendable {
            let value = Atomic<UInt64>(0)
        }

        /// One per bound, then the one above every bound (`+Inf`); not
        /// cumulative until read.
        private let buckets = (0...MiningMetrics.bounds.count).map { _ in Counter() }
        private let nanoseconds = Counter()

        func observe(_ duration: Duration) {
            let (seconds, attoseconds) = duration.components
            let elapsed = Double(seconds) + Double(attoseconds) / 1e18
            let bucket = MiningMetrics.bounds.firstIndex { elapsed <= $0 } ?? MiningMetrics.bounds.count
            buckets[bucket].value.wrappingAdd(1, ordering: .relaxed)
            nanoseconds.value.wrappingAdd(UInt64(max(0, elapsed) * 1e9), ordering: .relaxed)
        }

        var snapshot: Snapshot {
            var total: UInt64 = 0
            let cumulative = buckets.map { bucket in
                total += bucket.value.load(ordering: .relaxed)
                return total
            }
            return Snapshot(
                cumulative: cumulative,
                seconds: Double(nanoseconds.value.load(ordering: .relaxed)) / 1e9
            )
        }

        struct Snapshot: Sendable {
            /// The count at or below each bound, then the count of all.
            let cumulative: [UInt64]
            let seconds: Double
            var count: UInt64 { cumulative.last ?? 0 }
        }
    }
}
