import XCTest
import UInt256
@testable import LatticeNode

/// Contract tests for the single `apply(candidate)` choke point — the operation
/// gossip, sync, and rescue all funnel into. Fakes for the four injected steps, so
/// the whole contract (four outcomes + the cheap-fork-choice-first ordering + the
/// authoritative re-check at adopt) is pinned with no actor and no network.
final class ChainApplyTests: XCTestCase {

    /// Records which steps ran, in order, so we can assert the pipeline short-circuits.
    private actor CallLog {
        private(set) var steps: [String] = []
        func add(_ s: String) { steps.append(s) }
    }

    private let candidate = CandidateExtension(
        tipCID: "bafycandidate", tipHeight: 589, claimedWork: UInt256(1_000), source: nil)

    /// Test gather kinds (the payload for `.complete` is the candidate itself).
    private enum GatherKind { case complete, incomplete, mismatch(String) }

    /// Build a `ChainApply` whose steps return the given results and log their calls.
    /// `Gathered = CandidateExtension` — gather passes the candidate through.
    private func makeApply(
        log: CallLog,
        heavier: Bool = true,
        gather: GatherKind = .complete,
        validate: ValidationResult = .valid,
        adopt: AdoptResult = .adopted
    ) -> ChainApply<CandidateExtension> {
        ChainApply(
            isStrictlyHeavier: { _ in await log.add("forkChoice"); return heavier },
            gather: { c in
                await log.add("gather")
                switch gather {
                case .complete:        return .complete(c)
                case .incomplete:      return .incomplete
                case .mismatch(let r): return .contentMismatch(r)
                }
            },
            validate: { _ in await log.add("validate"); return validate },
            adopt: { _ in await log.add("adopt"); return adopt }
        )
    }

    func testAdoptedWhenHeavierAvailableValid() async {
        let log = CallLog()
        let outcome = await makeApply(log: log).apply(candidate)
        XCTAssertEqual(outcome, .adopted(tipCID: "bafycandidate"))
        let steps = await log.steps
        XCTAssertEqual(steps, ["forkChoice", "gather", "validate", "adopt"], "full pipeline, in order")
    }

    func testIgnoredWhenLighterShortCircuitsBeforeAnyFetch() async {
        let log = CallLog()
        let outcome = await makeApply(log: log, heavier: false).apply(candidate)
        XCTAssertEqual(outcome, .ignoredLighter)
        let steps = await log.steps
        XCTAssertEqual(steps, ["forkChoice"], "a lighter candidate must NOT trigger a fetch (cheap-first)")
    }

    func testPendingWhenDataIncompleteIsNotInvalid() async {
        let log = CallLog()
        let outcome = await makeApply(log: log, gather: .incomplete).apply(candidate)
        XCTAssertEqual(outcome, .pendingUnavailable, "missing data → retry, NEVER invalid")
        let steps = await log.steps
        XCTAssertEqual(steps, ["forkChoice", "gather"], "no validate/adopt on a data miss")
    }

    func testInvalidWhenContentMismatch() async {
        let log = CallLog()
        let outcome = await makeApply(log: log, gather: .mismatch("cid≠hash")).apply(candidate)
        XCTAssertEqual(outcome, .invalid(reason: "cid≠hash"), "content-binding failure is attributable → invalid")
        let steps = await log.steps
        XCTAssertEqual(steps, ["forkChoice", "gather"])
    }

    func testInvalidWhenValidationFails() async {
        let log = CallLog()
        let outcome = await makeApply(log: log, validate: .invalid("bad PoW")).apply(candidate)
        XCTAssertEqual(outcome, .invalid(reason: "bad PoW"))
        let steps = await log.steps
        XCTAssertEqual(steps, ["forkChoice", "gather", "validate"], "no adopt on invalid")
    }

    func testIgnoredWhenSupersededAtAdopt() async {
        // Everything passed, but the local chain advanced during gather/validate —
        // the authoritative re-check under the lock holds the (now-heavier) incumbent.
        let log = CallLog()
        let outcome = await makeApply(log: log, adopt: .supersededByHeavierLocal).apply(candidate)
        XCTAssertEqual(outcome, .ignoredLighter, "mid-apply local advance → hold incumbent (twice-check)")
        let steps = await log.steps
        XCTAssertEqual(steps, ["forkChoice", "gather", "validate", "adopt"])
    }

    func testPendingWhenAdoptTransientFailure() async {
        let log = CallLog()
        let outcome = await makeApply(log: log, adopt: .transientFailure).apply(candidate)
        XCTAssertEqual(outcome, .pendingUnavailable, "a commit-time miss retries, never dead-ends silently")
    }

    /// Properties of every ChainOutcome — only `.adopted` is adopted; each has a
    /// distinct metric suffix (so degraded/pending are observably different signals).
    func testChainOutcomeProperties() {
        XCTAssertTrue(ChainOutcome.adopted(tipCID: "x").wasAdopted)
        for o: ChainOutcome in [.ignoredLighter, .pendingUnavailable, .invalid(reason: "r"), .degraded(reason: "r")] {
            XCTAssertFalse(o.wasAdopted, "\(o) must not count as adopted")
        }
        XCTAssertEqual(ChainOutcome.adopted(tipCID: "x").metricSuffix, "adopted")
        XCTAssertEqual(ChainOutcome.ignoredLighter.metricSuffix, "ignored_lighter")
        XCTAssertEqual(ChainOutcome.pendingUnavailable.metricSuffix, "pending_unavailable")
        XCTAssertEqual(ChainOutcome.invalid(reason: "r").metricSuffix, "invalid")
        XCTAssertEqual(ChainOutcome.degraded(reason: "r").metricSuffix, "degraded",
                       "degraded is a distinct signal from pending_unavailable (not 'retriable by waiting')")
    }

    /// Retry gating: ONLY a content-availability miss retries by waiting; every other
    /// outcome is terminal. (This is what makes startSync re-attempt a strictly-heavier
    /// chain at the same/lower height — the case a height-gated retry misses.)
    func testOnlyPendingUnavailableIsRetriableTransient() {
        XCTAssertTrue(ChainOutcome.pendingUnavailable.isRetriableTransient)
        XCTAssertFalse(ChainOutcome.adopted(tipCID: "x").isRetriableTransient, "adopted is done")
        XCTAssertFalse(ChainOutcome.ignoredLighter.isRetriableTransient, "work-refused → retry is churn")
        XCTAssertFalse(ChainOutcome.invalid(reason: "r").isRetriableTransient, "bad data → no retry")
        XCTAssertFalse(ChainOutcome.degraded(reason: "r").isRetriableTransient, "local failure → not fixable by waiting")
    }
}
