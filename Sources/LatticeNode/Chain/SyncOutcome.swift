import Foundation

/// The outcome of ONE sync attempt against a peer tip, plus its retry lifecycle.
///
/// This unifies the two divergent failure caches that are the top source of sync
/// fragility (analysis F1/F2): `refusedSyncTipPairs` (never cleared except a >512
/// flush) and `failedSyncTips` (cleared on every peer connect). They had no shared
/// lifecycle, and — worse — the dominant failure (content unavailable during
/// materialize) recorded into NEITHER, so a sync "completed" having done nothing
/// and silently waited forever. This model makes every attempt terminate in an
/// EXPLICIT outcome that dictates a defined retry rule — never a silent nothing.
enum SyncAttemptOutcome: Equatable, Sendable {
    /// Work-verified lighter (or an equal-work tie that holds the incumbent) — a
    /// DETERMINISTIC refusal. Sticky while both our tip and the peer's tip are
    /// unchanged; a change to either frees it (re-evaluating is not churn then).
    case refusedPermanent
    /// Content / state bytes were UNAVAILABLE (a transient availability miss, NOT
    /// fraud — the peer isn't lying, the data just isn't fetchable yet). Retry with
    /// backoff and try other peers; `attempt` drives the backoff. This is the case
    /// the old code dropped silently.
    case unavailableTransient(attempt: Int)
    /// The peer served bytes that failed PoW / proof / content-hash binding — bad
    /// data. Do not auto-retry the same tip; penalize the source at the call site.
    case invalid
    /// Adopted. Terminal.
    case admitted
}

/// Co-locates the two former sync failure caches behind one typed store (step
/// toward the unified `SyncAttemptOutcome` model). BEHAVIOR-PRESERVING: it keeps
/// the two distinct lifecycles the code relies on today — a `refused` set keyed
/// `peerTip|localTip` that is sticky (only a >512 flush, so it frees when a tip
/// changes and the key stops matching), and a `failed` set keyed by tip CID that
/// gates peer selection and is cleared on peer-connect / sync-completion. Unifying
/// their *lifecycles* into a single outcome state machine is the follow-on
/// behavior change (needs the fake-availability harness to test — see plan F1/F2).
struct SyncOutcomeStore: Sendable {
    private var refused: Set<String> = []
    private var failed: Set<String> = []

    // refused (deterministic, work-verified) — sticky until a tip changes.
    mutating func recordRefused(peerTip: String, localTip: String) {
        if refused.count > 512 { refused.removeAll() }
        refused.insert("\(peerTip)|\(localTip)")
    }
    func isRefused(peerTip: String, localTip: String) -> Bool {
        refused.contains("\(peerTip)|\(localTip)")
    }

    // failed (transient) — gates peer selection; cleared on connect / completion.
    mutating func recordFailed(tip: String) { failed.insert(tip) }
    func isFailed(tip: String) -> Bool { failed.contains(tip) }
    mutating func clearFailed() { failed.removeAll() }
}

extension SyncPolicy {

    /// Backoff (seconds) for a transient-unavailable retry — bounded exponential,
    /// matching the existing 1,2,4,8,16,30 ladder. Pure so the backoff schedule is
    /// table-testable without a wall clock (the real clock is injected at the call
    /// site per plan T4). `attempt` is 1-based (first retry = attempt 1).
    static func transientRetryDelaySeconds(attempt: Int, maxDelaySeconds: Int = 30) -> Int {
        guard attempt > 0 else { return 0 }
        let shift = min(attempt - 1, 20)                 // cap the shift so 1<<shift stays small
        let doubling = 1 << shift                          // 1,2,4,8,16,32,... (Int, well below overflow)
        return min(doubling, maxDelaySeconds)
    }

    /// Should a sync attempt be (re)tried, given its LAST recorded outcome and
    /// whether the relevant tips are unchanged since that outcome?
    ///
    /// - no prior outcome            → try (first attempt)
    /// - admitted                    → no (terminal; done)
    /// - refusedPermanent            → only if a tip changed (else pure churn)
    /// - invalid                     → no auto-retry (bad data; call site penalizes)
    /// - unavailableTransient(n)     → yes while n < maxRetries (this is the fix:
    ///                                 a content miss ALWAYS schedules a retry, it
    ///                                 never dead-ends silently)
    static func shouldRetrySync(lastOutcome: SyncAttemptOutcome?, tipsUnchanged: Bool, maxRetries: Int) -> Bool {
        switch lastOutcome {
        case .none:                          return true
        case .admitted:                      return false
        case .refusedPermanent:              return !tipsUnchanged
        case .invalid:                       return false
        case .unavailableTransient(let n):   return n < maxRetries
        }
    }
}
