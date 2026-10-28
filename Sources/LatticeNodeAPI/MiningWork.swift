import Lattice
import UInt256

// What `MiningMinimumWork` asks of a template, in targets: the node and its
// miners and sponsors compute it the same way.

/// The most work any valid target can represent. Target 0 is met by no hash
/// and Lattice rejects it (`validateProofOfWork`), so target 1 is the hardest
/// and `workForTarget(1)` — 2^255 — is the ceiling. Work above it is refused
/// where it enters, never clamped: a clamped target would ask for less work
/// than the miner requested, and near the ceiling it would freeze the chain.
public let maximumRepresentableWork = workForTarget(UInt256(1))

/// The easiest target whose work (`workForTarget`, spec §9.1:
/// `floor(2^256 / (target + 1))`) is at least `work`, i.e.
/// `floor(2^256 / work) - 1`. Callers bound `work` by
/// `maximumRepresentableWork` first.
public func minimumWorkTarget(_ work: UInt256) -> UInt256 {
    precondition(work > .zero && work <= maximumRepresentableWork)
    let quotient = UInt256.max / work
    // floor(2^256 / work) exceeds floor((2^256 - 1) / work) by one exactly
    // when work divides 2^256. Within the ceiling a non-exact quotient is at
    // least 2, so the target below it is always a valid (positive) target.
    let exact = UInt256.max % work == work - UInt256(1)
    return exact ? quotient : quotient - UInt256(1)
}
