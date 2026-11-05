// The bound a mining round derives from its OWN measured history.
//
// It only detects a hung coordinator: work never expires on a clock, so the
// bound says nothing about the chain. Before any round has completed it is
// a fixed first-round allowance; after, the longest round that actually
// completed in this process, times the operator's headroom. A wedged round
// never completes, so it never widens the bound that would catch it.
//
// The headroom multiplier is the operator's: `mine.roundDeadlineMultiplier`
// in lattice.json. It has a sane default, and an operator changes it by
// editing a file rather than by recompiling.

import Foundation

public enum MiningRoundDeadline {
    /// Headroom when the operator names none.
    public static let defaultMultiplier: Int = 10

    /// The bound before any round has completed, and the most one measured
    /// round can count for.
    public static let firstRoundAllowance: Duration = .seconds(600)

    /// The deadline for the next round.
    ///
    /// - Parameters:
    ///   - longestCompletedRound: the longest round observed to COMPLETE in
    ///     this process. Counted at most `firstRoundAllowance`: a completed
    ///     round is bounded only by the PREVIOUS deadline, so feeding it back
    ///     unclamped would ratchet the bound by the multiplier every time
    ///     and a few slow-but-completing rounds would recreate the very
    ///     freeze this bound exists to stop.
    ///   - multiplier: operator headroom; below 1 is floored.
    public static func deadline(
        longestCompletedRound: Duration,
        multiplier: Int
    ) -> Duration {
        let measured = min(longestCompletedRound, firstRoundAllowance)
        let headroom = Int64(clamping: max(multiplier, 1))
        // Whole seconds, saturating: `Duration * Int` traps on overflow, and
        // a huge multiplier means "effectively never", not a crash. The cap
        // sits well below Int64.max seconds because the timer adds the
        // deadline to the clock's own reading, which must not overflow.
        let (seconds, overflow) = measured.components.seconds
            .multipliedReportingOverflow(by: headroom)
        return max(firstRoundAllowance, .seconds(overflow ? maximumSeconds : min(seconds, maximumSeconds)))
    }

    /// The largest deadline, in seconds: effectively never, yet safe to add
    /// to any clock reading.
    public static let maximumSeconds = Int64.max / 2
}
