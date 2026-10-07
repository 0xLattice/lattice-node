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
        let framed = item.cid.utf8.count + item.data.count + IvyRootContentSource.retainedEntryOverhead

        let tight = source(serving: [item.cid: item.data], maximumStorageBytes: framed - 1)
        let declined = await tight.withRootTracing(item.cid) { session in await session.fetch([item.cid]) }
        XCTAssertTrue(declined.value.isEmpty)
        XCTAssertTrue(declined.attribution.byteBudgetExceeded)

        let exact = source(serving: [item.cid: item.data], maximumStorageBytes: framed)
        let held = await exact.withRootTracing(item.cid) { session in await session.fetch([item.cid]) }
        XCTAssertEqual(held.value[item.cid], item.data)
        XCTAssertFalse(held.attribution.byteBudgetExceeded)
    }

    /// A Volume a peer padded with entries nobody asked for is charged what
    /// the session retains for each of them, so padding cannot make a session
    /// hold more than its budget says.
    func testAPaddedVolumeIsChargedWhatTheSessionRetainsForEachEntry() async throws {
        let root = try content(0)
        var entries = [root.cid: root.data]
        for nonce in 1...500 {
            let junk = try content(UInt64(nonce))
            entries[junk.cid] = junk.data
        }
        let padded = entries
        func source(maximumStorageBytes: Int) -> IvyRootContentSource {
            IvyRootContentSource(maximumStorageBytes: maximumStorageBytes) { _ in
                AttributedVolumeResponse(rootCID: root.cid, entries: padded, servedBy: nil, failure: nil)
            }
        }
        // What holding the entries takes at the very least: their CIDs and
        // bytes, a slot in each of the four tables keyed by CID, the data's
        // header and the owner set's.
        let slots = 4 * MemoryLayout<String>.stride + MemoryLayout<Data>.stride
            + MemoryLayout<Set<String>>.stride
        let retainedAtLeast = padded.reduce(0) { $0 + $1.key.utf8.count + $1.value.count + slots }

        let charged = await source(maximumStorageBytes: .max).withRoot(root.cid) { session in
            _ = await session.fetch([root.cid])
            return session.accountedBytes
        }
        XCTAssertGreaterThanOrEqual(charged, retainedAtLeast)

        let declined = await source(maximumStorageBytes: charged - 1).withRootTracing(root.cid) { session in
            let fetched = await session.fetch([root.cid])
            return (fetched: fetched.count, accounted: session.accountedBytes)
        }
        XCTAssertEqual(declined.value.fetched, 0)
        XCTAssertEqual(declined.value.accounted, 0)
        XCTAssertTrue(declined.attribution.byteBudgetExceeded)
    }

    /// A size a peer declares is its claim, verified by nothing: an answer
    /// refused for it says nothing about this node's budget.
    func testASizeAPeerOnlyDeclaredIsNotThisNodesBudget() async throws {
        let item = try content(1)
        let source = IvyRootContentSource { _ in
            AttributedVolumeResponse(rootCID: "", entries: [:], servedBy: nil, failure: .callerBoundaryExceeded)
        }
        let refused = await source.withRootTracing(item.cid) { session in await session.fetch([item.cid]) }
        XCTAssertTrue(refused.value.isEmpty)
        XCTAssertFalse(refused.attribution.byteBudgetExceeded)
    }
}
