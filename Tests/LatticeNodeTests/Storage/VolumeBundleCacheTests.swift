import Foundation
import XCTest
@testable import LatticeNode

/// The bundle cache records one connect job's bundles in one transaction, and
/// reads each back as it would a bundle recorded alone.
final class VolumeBundleCacheTests: XCTestCase {
    func testABatchReadsBackAsItsBlocksRecordedOneByOne() throws {
        let cache = VolumeBundleCache(directory: temporaryDirectory(create: true))
        cache.record([
            (root: "a", roots: ["a1", "a2"]),
            // A block's own root among its roots is served once, first.
            (root: "b", roots: ["b1", "b", "b2"]),
            (root: "c", roots: []),
        ])
        XCTAssertEqual(cache.bundle(root: "a"), ["a", "a1", "a2"])
        XCTAssertEqual(cache.bundle(root: "b"), ["b", "b1", "b2"])
        XCTAssertEqual(cache.bundle(root: "c"), ["c"])
        XCTAssertNil(cache.bundle(root: "d"))
    }

    func testALaterRecordReplacesAnEarlierOne() throws {
        let cache = VolumeBundleCache(directory: temporaryDirectory(create: true))
        cache.record(root: "a", roots: ["old"])
        cache.record([(root: "a", roots: ["new"]), (root: "b", roots: ["b1"])])
        XCTAssertEqual(cache.bundle(root: "a"), ["a", "new"])
        XCTAssertEqual(cache.bundle(root: "b"), ["b", "b1"])
    }

    func testAnEmptyBatchWritesNothing() throws {
        let cache = VolumeBundleCache(directory: temporaryDirectory(create: true))
        cache.record([])
        XCTAssertNil(cache.bundle(root: "a"))
    }

    /// Batches from several jobs at once each land whole: a batch is a
    /// transaction on the cache's one connection.
    func testConcurrentBatchesAllLand() async throws {
        let cache = VolumeBundleCache(directory: temporaryDirectory(create: true))
        await withTaskGroup(of: Void.self) { group in
            for job in 0..<8 {
                group.addTask {
                    cache.record((0..<50).map { (root: "r\(job)-\($0)", roots: ["x\(job)-\($0)"]) })
                }
            }
        }
        for job in 0..<8 {
            for block in 0..<50 {
                XCTAssertEqual(cache.bundle(root: "r\(job)-\(block)"), ["r\(job)-\(block)", "x\(job)-\(block)"])
            }
        }
    }
}
