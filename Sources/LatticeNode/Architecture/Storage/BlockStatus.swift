/// `accepted_blocks.validated`: how far the node has executed an accepted
/// block. The only place a tier value is spelled; every SQL site binds
/// `sqlValue` instead of writing the integer.
///
/// - `weighed`: boundary only (in the batch scope); enters fork choice on
///   verified work, not executed.
/// - `eager`: executed at admission; body + state inside
///   `admission_batches.volume_roots`.
/// - `walkValidated`: executed by the validate-on-candidacy walk; body +
///   state under the block's owner pin.
enum BlockStatus: Int64, Sendable, CaseIterable {
    case weighed = 0
    case eager = 1
    case walkValidated = 2

    /// Executed at either tier.
    var isExecuted: Bool { self != .weighed }

    var sqlValue: NodeSQLiteValue { .int(rawValue) }
}
