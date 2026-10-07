import Foundation
import Ivy
import LatticeNodeCore
import XCTest
@testable import LatticeNode

/// The operator's connection cap and memory budgets reach what they bound,
/// and unset they are the values the node always ran with.
final class MemoryBudgetsTests: XCTestCase {
    private func configuration(
        overlayMaxConnectionsPerNetgroup: Int? = nil,
        overlayMaxConnections: Int = IvyConfig.defaultMaxConnections,
        memoryBudgets: MemoryBudgets = .default
    ) throws -> NodeConfiguration {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-budgets-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: directory,
            privateKeyHex: String(repeating: "5a", count: 32),
            overlayMaxConnectionsPerNetgroup: overlayMaxConnectionsPerNetgroup,
            overlayMaxConnections: overlayMaxConnections,
            memoryBudgets: memoryBudgets
        )
    }

    func testDefaultsAreThePreviousConstants() throws {
        let configuration = try configuration()
        let core = NodeRuntime.coreConfig(ChainCoreConfig(), applying: configuration)
        XCTAssertEqual(core.proofs.maxSourceBytes, 1_048_576)
        XCTAssertEqual(core.pendingBudget, 16_777_216)
        XCTAssertEqual(core.mining.mempool.maxBytes, 67_108_864)
        XCTAssertEqual(core.mining.mempool, MempoolLimits())
        XCTAssertEqual(configuration.memoryBudgets.syncMaxQueuedBytesPerSession, 8_388_608)
        let outbox = SessionOutbox(send: { _, _, _ in .notConnected }, waitUntilWritable: { _ in true })
        XCTAssertEqual(outbox.maximumQueuedBytesPerSession, 8_388_608)
        let overlay = try OverlayConfiguration(configuration).overlay
        XCTAssertEqual(overlay.maxConnections, 256)
        XCTAssertEqual(overlay.maxConnectionsPerNetgroup, 256)
        XCTAssertEqual(overlay.reservedOutboundConnectionSlots, 16)
    }

    func testOperatorBudgetsReachTheCore() throws {
        let core = NodeRuntime.coreConfig(ChainCoreConfig(), applying: try configuration(
            memoryBudgets: MemoryBudgets(
                syncMaxUnverifiedBytesPerPeer: 111,
                syncMaxPendingBytes: 222,
                mempoolMaxBytes: 333,
                syncMaxQueuedBytesPerSession: 444
            )
        ))
        XCTAssertEqual(core.proofs.maxSourceBytes, 111)
        XCTAssertEqual(core.pendingBudget, 222)
        XCTAssertEqual(core.mining.mempool.maxBytes, 333)
    }

    func testTheConnectionCapReachesTheOverlayAndItsDependents() throws {
        let overlay = try OverlayConfiguration(configuration(overlayMaxConnections: 512)).overlay
        XCTAssertEqual(overlay.maxConnections, 512)
        XCTAssertEqual(overlay.maxConnectionsPerNetgroup, 512, "the per-netgroup default is the total")
        XCTAssertEqual(overlay.reservedOutboundConnectionSlots, 16)

        let small = try OverlayConfiguration(configuration(overlayMaxConnections: 8)).overlay
        XCTAssertEqual(small.maxConnections, 8)
        XCTAssertEqual(small.maxConnectionsPerNetgroup, 8)
        XCTAssertEqual(small.reservedOutboundConnectionSlots, 7, "one slot stays open to inbound")

        let explicit = try OverlayConfiguration(configuration(
            overlayMaxConnectionsPerNetgroup: 4, overlayMaxConnections: 512
        )).overlay
        XCTAssertEqual(explicit.maxConnectionsPerNetgroup, 4)

        XCTAssertNoThrow(try OverlayConfiguration(configuration(overlayMaxConnections: 1)))
        XCTAssertThrowsError(try OverlayConfiguration(configuration(overlayMaxConnections: 0)))
    }
}
