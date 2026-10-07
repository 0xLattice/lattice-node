import LatticeNodeCore
import XCTest
@testable import LatticeNode

/// A peer the core drops for stalling is not to blame and must be able to
/// come back: its session is recycled, so a configured peer is re-dialled.
/// Closing it for good left a syncing node with no peers once its few
/// configured peers had each missed one deadline.
final class SessionCloseTests: XCTestCase {
    func testAStalledPeerIsRecycledSoItCanReconnect() {
        XCTAssertEqual(SessionClose(.stalled), .recycle)
    }

    func testAPeerThatSentInvalidProofOfWorkIsClosedForGood() {
        XCTAssertEqual(SessionClose(.proofOfWorkInvalid), .close)
    }
}
