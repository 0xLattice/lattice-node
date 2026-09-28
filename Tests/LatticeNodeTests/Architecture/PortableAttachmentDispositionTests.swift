import XCTest
@testable import LatticeNode

/// The decision `recoverPortableAttachment` acts on once an overlay peer's
/// attachment has been fetched and checked. Every row of the table is
/// pinned. Blame follows the bytes alone: good bytes are never blamed, even
/// when the runtime or the session changed during the fetch or the check
/// (#215), and bad bytes are blamed on their sole supplier either way.
final class PortableAttachmentDispositionTests: XCTestCase {

    private typealias Disposition = NodeNetworkRuntime.PortableAttachmentDisposition<Int>

    private func decide(
        verified: Int?,
        current: Bool,
        complete: Bool = true,
        soleSupplier: String? = "supplier"
    ) -> String {
        let disposition: Disposition = NodeNetworkRuntime.portableAttachmentDisposition(
            verified,
            current: current,
            complete: complete,
            soleSupplier: soleSupplier
        )
        switch disposition {
        case .enqueue(let value): return "enqueue \(value)"
        case .stale: return "stale"
        case .reject(let blame): return "reject blame=\(blame ?? "nil")"
        }
    }

    /// Establishes: NODE-SEMANTICS-004.c
    func testVerifiedBytesAreNeverBlamedWhenTheRuntimeOrSessionChanged() {
        XCTAssertEqual(decide(verified: 7, current: false), "stale")
        XCTAssertEqual(decide(verified: 7, current: false, complete: false), "stale")
    }

    func testVerifiedOnTheCurrentSessionIsEnqueued() {
        XCTAssertEqual(decide(verified: 7, current: true), "enqueue 7")
    }

    func testFailedBytesBlameOnlyTheSoleSupplierOfACompleteFetch() {
        XCTAssertEqual(decide(verified: nil, current: true), "reject blame=supplier")
        XCTAssertEqual(decide(verified: nil, current: false), "reject blame=supplier")
        XCTAssertEqual(decide(verified: nil, current: true, complete: false), "reject blame=nil")
        XCTAssertEqual(decide(verified: nil, current: true, soleSupplier: nil), "reject blame=nil")
    }
}
