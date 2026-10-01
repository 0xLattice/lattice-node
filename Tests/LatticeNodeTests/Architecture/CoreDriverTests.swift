import Foundation
import Ivy
import Lattice
import XCTest
@testable import LatticeNode

/// The core driver end to end: two Nexus nodes on loopback Ivy, each a
/// `CoreDriver` over its own `ChainProcess`. The producer's history is
/// boot-replayed into its core; the joiner syncs the headers, fetches the
/// bodies by CID, executes them, and boot-replays its own journal.
final class CoreDriverTests: NetworkTrustTestCase {
    private struct Host {
        let configuration: NodeConfiguration
        let overlay: IvyConfig
        let endpoint: PeerEndpoint
    }

    private func host(keyByte: UInt8, peers: [PeerEndpoint] = []) throws -> Host {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-core-driver-\(UUID().uuidString)", isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let port = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storage,
            privateKeyHex: String(repeating: String(format: "%02x", keyByte), count: 32),
            listenPort: port,
            rpcPort: NetworkTransportTestPorts.allocate()
        )
        return Host(
            configuration: configuration,
            overlay: IvyConfig(
                signingKey: configuration.signingKey,
                listenPort: port,
                bootstrapPeers: peers,
                requestTimeout: .seconds(5),
                stunServers: [],
                healthConfig: PeerHealthConfig(enabled: false),
                mode: .overlay
            ),
            endpoint: PeerEndpoint(publicKey: configuration.processPublicKey, host: "127.0.0.1", port: port)
        )
    }

    func testJoinerSyncsHeadersAndExecutesBodiesOverLoopbackIvy() async throws {
        let producer = try host(keyByte: 0x31)
        let producerProcess = try await ChainProcess.open(configuration: producer.configuration)
        let clock = TestBlockClock()
        var tip = try await producerProcess.canonicalTipBlock()
        for _ in 0..<4 {
            tip = try await acceptNexusBlock(on: tip, process: producerProcess, timestamp: clock.next())
        }
        let tipCID = try BlockHeader(node: tip).rawCID
        let producerDriver = try await CoreDriver.start(
            process: producerProcess, configuration: producer.configuration, overlay: producer.overlay
        )
        XCTAssertEqual(producerDriver.published.value?.actOnTip, tipCID)

        let joiner = try host(keyByte: 0x32, peers: [producer.endpoint])
        do {
            let joinerProcess = try await ChainProcess.open(configuration: joiner.configuration)
            let joinerDriver = try await CoreDriver.start(
                process: joinerProcess, configuration: joiner.configuration, overlay: joiner.overlay
            )
            try await eventually("the joiner executes the producer's tip") {
                joinerDriver.published.value?.actOnTip == tipCID
            }
            XCTAssertEqual(joinerDriver.published.value?.actOnHeight, 4)
            await joinerDriver.stop()
        }
        await producerDriver.stop()

        // Restart: the joiner's own journal replays to the same tip.
        let reopened = try await ChainProcess.open(configuration: joiner.configuration)
        let host = try await CoreDriver.boot(
            process: reopened, configuration: joiner.configuration, coreConfig: .init()
        )
        let snapshot = try XCTUnwrap(host.levels[host.rootPath]?.snapshot)
        XCTAssertEqual(snapshot.actOnTip, tipCID)
        XCTAssertEqual(snapshot.bestHeaderTip, tipCID)
    }
}
