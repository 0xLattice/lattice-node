import Foundation
import Tally
import UInt256

/// A candidate chain extension gathered from ANY source — a gossiped block, a sync
/// batch, or a rescue backfill. It is just a claimed tip plus enough to reach the
/// blocks/proofs on the path from our chain to it. Sources differ only in how they
/// GATHER (single-block fast path vs batched bulk path); they all produce this.
struct CandidateExtension: Sendable, Equatable {
    let tipCID: String
    let tipHeight: UInt64
    /// UNVERIFIED work hint from the gatherer (may be nil from an old peer). Used
    /// only as a cheap fork-choice pre-filter; the authoritative weight comparison
    /// is re-done at adopt, under the commit lock, against verified data.
    let claimedWork: UInt256?
    /// The peer that offered it — a fetch hint and the attributability handle for
    /// graduated penalties (invalid → ban; can't-serve → retry; withheld → light).
    let source: PeerID?
}

/// The four — and only four — fates of a candidate. This is the spine: there is no
/// "silent nothing." Availability failures are `pendingUnavailable` (retry, NOT a
/// verdict on validity); only provably-bad data is `invalid`.
enum ChainOutcome: Equatable, Sendable {
    case adopted(tipCID: String)   // heavier + available + valid → reorged to it
    case ignoredLighter            // fork choice: not strictly heavier → hold incumbent
    case pendingUnavailable        // data not fetchable yet → retry later (never a ban)
    case invalid(reason: String)   // bad PoW / proof / content-binding / state → reject
    case degraded(reason: String)  // LOCAL/post-commit failure (not the peer's fault, not
                                    // retriable-by-waiting): storage/config error, or a
                                    // post-commit step failing after the segment already
                                    // committed. TERMINAL — a sync retry is wrong/futile.
}

extension ChainOutcome {
    /// Did the candidate get adopted? (bridges the former `Bool` return of
    /// `finalizeSyncResult` while call sites migrate to the full outcome.)
    var wasAdopted: Bool { if case .adopted = self { return true } else { return false } }

    /// Should a bounded transient-failure retry be scheduled for this outcome? ONLY a
    /// content-availability miss retries by waiting — and it retries regardless of
    /// height (a strictly-heavier-at-same-or-lower-height chain is exactly the case a
    /// height-gated retry misses). `.adopted`/`.ignoredLighter`/`.invalid`/`.degraded`
    /// are terminal: retrying churns (lighter), is futile (invalid), or can't be fixed
    /// by waiting (degraded/local failure).
    var isRetriableTransient: Bool { if case .pendingUnavailable = self { return true } else { return false } }

    /// Metric suffix so each outcome is observable — the transient case (the seed-496
    /// class) must be a visible signal, not a silent stall.
    var metricSuffix: String {
        switch self {
        case .adopted:            return "adopted"
        case .ignoredLighter:     return "ignored_lighter"
        case .pendingUnavailable: return "pending_unavailable"
        case .invalid:            return "invalid"
        case .degraded:           return "degraded"
        }
    }
}

/// Result of gathering a candidate's reachable blocks/proofs by content hash. On
/// success it CARRIES the gathered payload (`Gathered`) that `validate` and `adopt`
/// then consume — e.g. the downloaded+persisted segment for sync, or the resolved
/// block for gossip. This data flow is what lets `apply()` wrap real node code.
enum GatherOutcome<Gathered: Sendable>: Sendable {
    case complete(Gathered)        // everything reachable is present + content-bound
    case incomplete                // some bytes not fetchable yet (transient, not fraud)
    case contentMismatch(String)   // bytes served don't hash to their CID (attributable)
}

enum ValidationResult: Equatable, Sendable {
    case valid
    case invalid(String)           // PoW / proof / state re-execution failed
}

/// Result of the authoritative adopt step, which re-checks fork choice UNDER the
/// commit lock (the chain may have advanced during gather/validate) and then commits.
enum AdoptResult: Equatable, Sendable {
    case adopted
    case supersededByHeavierLocal  // local chain advanced under us → hold incumbent
    case transientFailure          // a commit-time availability/IO miss → retry
}

/// The single apply operation — our `ActivateBestChain`, the choke point gossip,
/// sync, and rescue will funnel into. The four steps map 1:1 to the SOTA-validated
/// model: fork choice (cheap, first) → availability (missing = pending) → validate
/// (verify-not-trust) → adopt (authoritative re-check under lock, then commit).
///
/// STATUS: proposed choke point — NOT YET WIRED into the live sync/gossip paths.
/// It is fully contract-tested with fakes (ChainApplyTests), and its shape is what the
/// redirect step will use: real closures that call the node's fork-choice / fetcher /
/// validator / commit paths, replacing the duplicate flows. Until that redirect lands,
/// only `ChainOutcome` (finalizeSyncResult's return) is live; this struct is scaffolding.
struct ChainApply<Gathered: Sendable>: Sendable {
    /// Cheap pre-filter: is the candidate plausibly heavier (may use claimedWork)?
    /// Not authoritative — `adopt` re-checks against verified data under the lock.
    var isStrictlyHeavier: @Sendable (CandidateExtension) async -> Bool
    /// Fetch the reachable blocks/proofs by content hash from any peer/CAS, producing
    /// the `Gathered` payload that `validate`/`adopt` consume.
    var gather: @Sendable (CandidateExtension) async -> GatherOutcome<Gathered>
    /// PoW + proofs + state re-execution over the gathered data.
    var validate: @Sendable (Gathered) async -> ValidationResult
    /// Re-check fork choice under the commit lock, then commit/reorg the gathered data.
    var adopt: @Sendable (Gathered) async -> AdoptResult

    func apply(_ candidate: CandidateExtension) async -> ChainOutcome {
        // 1. Fork choice first — cheapest gate. A not-heavier candidate is dropped
        //    before any fetch/validation bandwidth is spent (Bitcoin: only fetch
        //    along the best-work chain).
        guard await isStrictlyHeavier(candidate) else { return .ignoredLighter }

        // 2. Availability — gather the reachable path. Missing bytes are NOT a
        //    validity verdict: they are transient and retried. Only bytes that fail
        //    content binding are attributable and rejected here.
        let gathered: Gathered
        switch await gather(candidate) {
        case .incomplete:              return .pendingUnavailable
        case .contentMismatch(let r):  return .invalid(reason: r)
        case .complete(let g):         gathered = g
        }

        // 3. Validate — verify-not-trust: PoW + proofs + re-execute state.
        if case .invalid(let r) = await validate(gathered) { return .invalid(reason: r) }

        // 4. Adopt — the authoritative fork-choice re-check happens HERE, under the
        //    commit lock, because the local chain may have advanced during 2–3. A
        //    transient commit-time miss retries rather than dead-ends.
        switch await adopt(gathered) {
        case .adopted:                 return .adopted(tipCID: candidate.tipCID)
        case .supersededByHeavierLocal: return .ignoredLighter
        case .transientFailure:        return .pendingUnavailable
        }
    }
}
