import Foundation
import Lattice
import VolumeBroker
import XCTest
import cashew
@testable import LatticeNode

/// One admission's content is one volumes.db transaction.
final class NodeImportStorageTests: XCTestCase {
    private func spec(_ premine: UInt64) throws -> VolumeImpl<ChainSpec> {
        try VolumeImpl<ChainSpec>(node: ChainSpec(
            maxNumberOfTransactionsPerBlock: 10, maxStateGrowth: 100_000, premine: premine,
            targetBlockTime: 1_000, initialReward: 1, halvingInterval: 10_000, halfLife: 10
        ))
    }

    func testAnAdmissionsVolumesCommitTogetherOrNotAtAll() async throws {
        let broker = try DiskBroker(
            path: temporaryDirectory(create: true).appendingPathComponent("volumes.db").path
        )
        let (first, second) = (try spec(0), try spec(1))

        // A failure part-way leaves none of the admission's Volumes.
        let failed = NodeImportStorage(storage: broker)
        try await first.store(storer: failed)
        await failed.store(volume: SerializedVolume(root: second.rawCID, entries: [second.rawCID: Data([0])]))
        do {
            try await failed.commit()
            XCTFail("a Volume whose bytes do not match its CID was stored")
        } catch {}
        let afterFailure = await broker.hasVolume(root: first.rawCID)
        XCTAssertFalse(afterFailure)

        // Nothing is in the broker before the commit; everything is after.
        let storage = NodeImportStorage(storage: broker)
        try await first.store(storer: storage)
        try await second.store(storer: storage)
        let beforeCommit = await broker.hasVolume(root: first.rawCID)
        XCTAssertFalse(beforeCommit)
        try await storage.commit()
        for root in await storage.takeStoredVolumeRoots() {
            let stored = await broker.hasVolume(root: root)
            XCTAssertTrue(stored)
        }
        try await broker.mergeRetainedRoots(scope: "scope", roots: [first.rawCID, second.rawCID])
    }
}
