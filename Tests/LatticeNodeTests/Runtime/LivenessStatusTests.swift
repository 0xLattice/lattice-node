import Foundation
import Ivy
import Lattice
import LatticeNodeAPI
import LatticeNodeCore
import XCTest
@testable import LatticeNode

/// An operator can tell from `/status` whether each chain keeps up: its
/// acted-on height against the best header chain it knows, and how long its
/// acted-on tip has not moved. Behind and not moving is a stall.
final class LivenessStatusTests: XCTestCase {
    private struct Host {
        let configuration: NodeConfiguration
        let overlay: IvyConfig
        let endpoint: PeerEndpoint
    }

    private func host(keyByte: UInt8, peers: [PeerEndpoint] = [], blockBodies: BlockBodies = .all) throws -> Host {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-node-liveness-\(UUID().uuidString)", isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let port = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"], storagePath: directory,
            privateKeyHex: String(repeating: String(format: "%02x", keyByte), count: 32),
            listenPort: port, rpcPort: NetworkTransportTestPorts.allocate(), webSocket: .off,
            peerSearchInterval: 600, blockBodies: blockBodies
        )
        return Host(
            configuration: configuration,
            overlay: IvyConfig(
                signingKey: configuration.signingKey, listenPort: port, bootstrapPeers: peers,
                requestTimeout: .seconds(5), stunServers: [],
                healthConfig: PeerHealthConfig(enabled: false), mode: .overlay
            ),
            endpoint: PeerEndpoint(publicKey: configuration.processPublicKey, host: "127.0.0.1", port: port)
        )
    }

    private func start(_ host: Host) async throws -> NodeRuntime {
        try await startWithStorage(host).runtime
    }

    private func startWithStorage(_ host: Host) async throws -> (runtime: NodeRuntime, storage: NodeStorage) {
        let storage = try await NodeStorage.openWhenFree(configuration: host.configuration)
        let runtime = try await NodeRuntime.start(storage: storage, configuration: host.configuration, overlay: host.overlay)
        return (runtime, storage)
    }

    /// A node at its best tip is at its best header, and each block it acts
    /// on moves the time its tip last advanced.
    func testANodeAtItsTipIsNotBehindAndItsTipMoves() async throws {
        let runtime = try await start(try host(keyByte: 0x71))
        _ = try await runtime.mineBlock()
        var first: NodeStatusResponse?
        try await eventually("the mined block is acted on") {
            first = await runtime.status(chainPath: ["Nexus"])
            return (first?.height ?? 0) >= 1
        }
        XCTAssertEqual(first?.height, first?.bestHeaderHeight)
        let advanced = try XCTUnwrap(first?.sync?.tipAdvancedAt)
        XCTAssertLessThan(try XCTUnwrap(first?.sync?.secondsSinceTipAdvanced), 60)
        try await Task.sleep(for: .milliseconds(20))
        _ = try await runtime.mineBlock()
        try await eventually("the next block moves the tip") {
            (await runtime.status(chainPath: ["Nexus"])?.sync?.tipAdvancedAt ?? 0) > advanced
        }
        let after = await runtime.status(chainPath: ["Nexus"])
        XCTAssertEqual(after?.height, after?.bestHeaderHeight)
        XCTAssertEqual(after?.sync?.blockedOn, "atTip", "it waits for the network's next block")
        await runtime.stop()
    }

    /// A follower whose only peer has let go of the bodies it needs weighs
    /// the peer's headers but cannot execute them: it reports itself
    /// behind, with a tip that does not move.
    func testAFollowerThatCannotExecuteReportsItselfBehindAndNotMoving() async throws {
        let producer = try host(keyByte: 0x72, blockBodies: .none)
        let (producerRuntime, producerStorage) = try await startWithStorage(producer)
        var mined: [String] = []
        for _ in 0..<5 { mined.append(try BlockHeader(node: try await producerRuntime.mineBlock()).rawCID) }
        let height = try XCTUnwrap(producerRuntime.published.value?.actOnHeight)
        // The producer has let go of the bodies below its tip: the follower
        // can weigh their headers and never execute them.
        try await eventually("the producer lets go of its older bodies") {
            for cid in mined.dropLast() where await producerStorage.volume(cid) != nil { return false }
            return true
        }

        let follower = try await start(try host(keyByte: 0x73, peers: [producer.endpoint]))
        var seen: NodeStatusResponse?
        try await eventually("the follower weighs the producer's headers", within: .seconds(60)) {
            seen = await follower.status(chainPath: ["Nexus"])
            return (seen?.bestHeaderHeight ?? 0) >= height
        }
        XCTAssertLessThan(seen?.height ?? 0, height, "behind the headers it cannot execute")
        let before = try XCTUnwrap(seen?.sync?.secondsSinceTipAdvanced)
        try await alwaysDuring("its tip has not moved", .seconds(1), poll: .milliseconds(50)) {
            let now = await follower.status(chainPath: ["Nexus"])
            return (now?.height ?? 0) < height && now?.sync?.tipAdvancedAt == seen?.sync?.tipAdvancedAt
        }
        let later = await follower.status(chainPath: ["Nexus"])
        XCTAssertGreaterThan(try XCTUnwrap(later?.sync?.secondsSinceTipAdvanced), before, "and has been still for longer")
        // Why: the next block's body can be had from no one.
        try await eventually("the follower says what its tip waits on") {
            await follower.status(chainPath: ["Nexus"])?.sync?.blockedOn == "bodiesUnavailable"
        }
        XCTAssertEqual(later?.sync?.headersSynced, true, "it has weighed its peer's whole log")
        let metrics = await follower.metricsExposition(peers: 1, processStartTime: Date())
        let advancedAt = try XCTUnwrap(later?.sync?.tipAdvancedAt)
        XCTAssertTrue(
            metrics.contains("lattice_chain_tip_advanced_timestamp_seconds{chain=\"Nexus\"} \(advancedAt)"), metrics
        )
        XCTAssertTrue(metrics.contains("lattice_chain_tip_height{chain=\"Nexus\",tier=\"weighed\"} \(height)"), metrics)
        // What an alert reads: why the chain waits, and its latches.
        XCTAssertTrue(metrics.contains("lattice_chain_blocked_on{chain=\"Nexus\",on=\"bodiesUnavailable\"} 1"), metrics)
        // Every other reason reads 0, so one that ends does not vanish.
        XCTAssertTrue(metrics.contains("lattice_chain_blocked_on{chain=\"Nexus\",on=\"atTip\"} 0"), metrics)
        XCTAssertTrue(metrics.contains("lattice_chain_headers_synced{chain=\"Nexus\"} 1"), metrics)
        XCTAssertTrue(metrics.contains("lattice_chain_synced{chain=\"Nexus\"} "), metrics)
        XCTAssertTrue(metrics.contains("lattice_chain_jobs_queued{chain=\"Nexus\"} "), metrics)
        await follower.stop()
        await producerRuntime.stop()
    }
}
