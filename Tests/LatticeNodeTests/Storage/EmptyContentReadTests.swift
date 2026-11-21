import Foundation
import Lattice
import XCTest
import cashew
@testable import LatticeNode

/// What every block without child blocks or transactions names, the empty
/// child index and the empty transaction index, reads whole and checked
/// against its CID from stores that hold nothing: a walk of such a block
/// needs no store for them, and a peer asking for them is answered.
final class EmptyContentReadTests: XCTestCase {
    func testEmptyIndexesReadFromStoresHoldingNothing() async throws {
        let reads = StoreReads(stores: [])
        let childIndex = try HeaderImpl(node: FlatDictionary<BlockHeader>())
        let transactions = try HeaderImpl(node: MerkleDictionaryImpl<VolumeImpl<Transaction>>(children: [:], count: 0))

        let fetcher = CoalescingFetcher(reads)
        let resolvedChildren = try await HeaderImpl<FlatDictionary<BlockHeader>>(rawCID: childIndex.rawCID).resolve(fetcher: fetcher)
        XCTAssertEqual(resolvedChildren.node?.count, 0)
        let resolvedTransactions = try await HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Transaction>>>(rawCID: transactions.rawCID)
            .resolve(fetcher: fetcher)
        XCTAssertEqual(resolvedTransactions.node?.count, 0)

        let served = await reads.fetchDataLocal(cid: childIndex.rawCID)
        XCTAssertEqual(served, FlatDictionary<BlockHeader>().toData())
        let missing = try HeaderImpl(node: FlatDictionary<BlockHeader>(["x": BlockHeader(rawCID: childIndex.rawCID)])).rawCID
        let asked = await reads.fetch([missing])
        XCTAssertTrue(asked.isEmpty, "content not held is not answered")
    }
}
