// The bound a mining round derives from its OWN parameters.
//
// A coordinator round ends on a solution, an exhausted nonce batch, a stale
// tip, or the node refusing nonces for expired work — so a round's natural
// bound is the template expiry the node itself advertises
// (`expiresInMilliseconds` on `POST /v1/mining/templates`) plus the time a
// batch takes. Expiry is OBSERVED from the node rather than assumed; batch
// time is MEASURED as the longest round that has actually completed in this
// process. Neither is a constant here.
//
// The headroom multiplier on top is the operator's:
// `mine.roundDeadlineMultiplier` in lattice.json. It is the only number in
// this file, it has a sane default, and an operator changes it by editing a
// file rather than by recompiling.

import Foundation

public enum MiningRoundDeadline {
    /// Headroom when the operator names none. A round is expected to finish
    /// within one template expiry plus one batch; ten times that leaves slack
    /// for a slow or contended host while staying far short of "forever".
    public static let defaultMultiplier: UInt64 = 10

    /// The deadline for the next round.
    ///
    /// - Parameters:
    ///   - templateExpiry: what the node advertised for this chain's work.
    ///   - longestCompletedRound: the longest round observed to COMPLETE in
    ///     this process. A wedged round never completes, so it can never
    ///     inflate the bound that would have caught it.
    ///   - multiplier: operator headroom; below 1 is floored, since a
    ///     deadline shorter than the round's own bound kills healthy rounds.
    public static func deadline(
        templateExpiry: Duration,
        longestCompletedRound: Duration,
        multiplier: UInt64
    ) -> Duration {
        let base = templateExpiry + longestCompletedRound
        let headroom = Int64(clamping: max(multiplier, 1))
        let seconds = base.components.seconds
            .multipliedReportingOverflow(by: headroom)
        guard !seconds.overflow else { return .seconds(Int64.max / 2) }
        let nanoseconds = (base.components.attoseconds / 1_000_000_000)
            .multipliedReportingOverflow(by: headroom)
        guard !nanoseconds.overflow else {
            return .seconds(seconds.partialValue)
        }
        return .seconds(seconds.partialValue)
            + .nanoseconds(nanoseconds.partialValue)
    }
}
