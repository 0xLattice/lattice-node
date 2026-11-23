/// The timestamp this node stamps the next block above one stamped
/// `previous` with: the earliest consensus allows (strictly after its
/// predecessor), raised to `notBefore`. Where the floor comes from is node
/// policy: the wall clock for a block of its own, or the carrier's timestamp
/// for a block a parent-chain carrier will carry. Nil when `previous` is the
/// last representable timestamp.
public func nextBlockTimestamp(after previous: Int64, notBefore floor: Int64) -> Int64? {
    let (minimum, overflow) = previous.addingReportingOverflow(1)
    guard !overflow else { return nil }
    return max(minimum, floor)
}
