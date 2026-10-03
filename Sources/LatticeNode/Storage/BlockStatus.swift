/// `accepted_blocks.validated`: how far the node has executed an accepted
/// block. The only place a tier value is spelled; every SQL site binds
/// `sqlValue` instead of writing the integer.
///
/// - `header`: boundary only (in the batch scope); enters fork choice on
///   verified work, not executed.
/// - `executed`: executed at import; body + state inside
///   `admission_batches.volume_roots`.
/// - `executedAndPinned`: executed by the execution walk; body + state under
///   the block's owner pin.
enum BlockStatus: Int64, Sendable, CaseIterable {
    case header = 0
    case executed = 1
    case executedAndPinned = 2

    /// Executed at either tier.
    var isExecuted: Bool { self != .header }

    var sqlValue: NodeSQLiteValue { .int(rawValue) }
}
