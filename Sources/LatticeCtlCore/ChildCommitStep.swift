import Lattice
import LatticeNodeAPI

/// One round of an author's commit loop (`lattice child commit`), decided
/// by the node: `pushed` is the answer to pushing the built block (nil when
/// none is built), `read` the commitment read once that answer is
/// `dropped` or there is no block, `accepted` whether the parent's pool took
/// the built block's commit.
///
/// Any answer but `dropped` means a weighed parent block commits the block
/// (the node's committers index, which spans forks): it waits for `tree`,
/// whatever was committed since. Dropped, a parent tip still entering the
/// built block's P waits for its commit, sending it again until the pool
/// takes it; a tip on another P is built on, unless it holds the built
/// block's own commitment (a carrier landed since the push).
public enum ChildCommitStep: Sendable, Equatable {
    /// Weighed in the child's tree: stop.
    case done
    /// Carried, or committed and pending: push again next round.
    case wait
    /// Dropped, or nothing built: read the commitment, then decide again.
    case read
    /// Send the built block's commit again.
    case commit
    /// Build on the read P and commit that.
    case build

    public init(
        pushed: SubmitChildBlockStatus?, read: ChildCommitmentResponse?,
        built: BuildChildBlockResponse?, accepted: Bool
    ) {
        switch pushed {
        case .tree: self = .done; return
        case .pending, .awaiting: self = .wait; return
        case .dropped, nil: break
        }
        guard let read else { self = .read; return }
        if let built, read.parentState == built.parentState {
            self = accepted ? .wait : .commit
        } else if let built, read.value == built.blockCID
            + String(UnicodeScalar(CHILD_COMMITMENT_PARENT_STATE_SEPARATOR)) + built.parentState {
            // A carrier landed after the push: the next push answers carried.
            self = .wait
        } else {
            self = .build
        }
    }
}
