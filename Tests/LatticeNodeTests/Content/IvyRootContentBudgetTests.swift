import Foundation
import Ivy
import Lattice
import XCTest
import cashew
@testable import LatticeNode

/// What a content session may hold is bounded in bytes and in nothing else.
final class IvyRootContentBudgetTests: XCTestCase {
    /// A real content-addressed node: its CID and its canonical bytes.
    private func content(_ nonce: UInt64) throws -> (cid: String, data: Data) {
        let node = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: ["signer"], nonce: nonce, chainPath: ["Nexus"]
        )
        return (try HeaderImpl(node: node).rawCID, try XCTUnwrap(node.toData()))
    }

    /// Each CID served as its own one-member Volume.
    private func source(serving entries: [String: Data], maximumStorageBytes: Int) -> IvyRootContentSource {
        IvyRootContentSource(maximumStorageBytes: maximumStorageBytes) { requested in
            guard let data = entries[requested] else { return .empty }
            return AttributedVolumeResponse(
                rootCID: requested, entries: [requested: data], servedBy: nil, failure: nil
            )
        }
    }

    /// One Volume more than the 20,548 a session used to stop at, in a few
    /// megabytes.
    func testASessionHoldsAnyNumberOfVolumesWithinItsBytes() async throws {
        var entries: [String: Data] = [:]
        for nonce in 0..<UInt64(20_549) {
            let item = try content(nonce)
            entries[item.cid] = item.data
        }
        let wanted = Set(entries.keys)
        let source = source(serving: entries, maximumStorageBytes: 64 * 1_024 * 1_024)
        let fetched = await source.withRoot(try XCTUnwrap(wanted.first)) { session in
            await session.fetch(wanted)
        }
        XCTAssertEqual(fetched.count, wanted.count)
    }

    /// Content past the byte budget is declined, and the session says the
    /// budget declined it rather than that nobody served it.
    func testContentPastTheByteBudgetIsDeclinedAndSaidSo() async throws {
        let item = try content(1)
        let framed = item.cid.utf8.count + item.data.count + 6

        let tight = source(serving: [item.cid: item.data], maximumStorageBytes: framed - 1)
        let declined = await tight.withRootTracing(item.cid) { session in await session.fetch([item.cid]) }
        XCTAssertTrue(declined.value.isEmpty)
        XCTAssertTrue(declined.attribution.byteBudgetExceeded)

        let exact = source(serving: [item.cid: item.data], maximumStorageBytes: framed)
        let held = await exact.withRootTracing(item.cid) { session in await session.fetch([item.cid]) }
        XCTAssertEqual(held.value[item.cid], item.data)
        XCTAssertFalse(held.attribution.byteBudgetExceeded)
    }
}
