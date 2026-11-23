/// `accepted_blocks.validated`: how far the node has executed an accepted
/// block. The only place a tier value is spelled; every SQL site binds
/// `sqlValue` instead of writing the integer.
///
/// - `header`: boundary only (in the batch scope); enters fork choice on
///   verified work, not executed.
/// - `executed`: executed at import.
/// - `executedAndPinned`: executed by the execution walk; body + state under
///   the block's owner pin. No longer written, but kept: stores written
///   before may hold the value 2.
enum BlockStatus: Int64, Sendable, CaseIterable {
    case header = 0
    case executed = 1
    case executedAndPinned = 2

    var sqlValue: NodeSQLiteValue { .int(rawValue) }
}
