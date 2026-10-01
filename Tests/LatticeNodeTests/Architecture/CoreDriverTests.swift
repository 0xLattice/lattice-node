import Foundation
import Ivy
import Lattice
import LatticeNodeCore
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

    /// RPC writes are core events answered from effects, and RPC reads come
    /// from the published snapshot: a template on the act-on tip, a grind
    /// submitted and weighed, its body connected, and every read following.
    func testRPCWritesAreCoreEventsAndReadsFollowThePublishedSnapshot() async throws {
        let node = try host(keyByte: 0x33)
        let process = try await ChainProcess.open(configuration: node.configuration)
        let driver = try await CoreDriver.start(
            process: process, configuration: node.configuration, overlay: node.overlay
        )
        let genesis = try XCTUnwrap(driver.published.value?.actOnTip)

        let template = try await driver.miningTemplate(MiningTemplateRequest())
        XCTAssertEqual(template.block.parent?.rawCID, genesis)
        var nonce: UInt64 = 0
        while Self.block(template.block, nonce: nonce).proofOfWorkHash() > template.searchTarget {
            nonce += 1
        }
        let cid = try BlockHeader(node: Self.block(template.block, nonce: nonce)).rawCID
        let submitted = try await driver.submitWork(SubmitWorkRequest(workID: template.workID, nonce: nonce))
        XCTAssertTrue(submitted.accepted)
        XCTAssertEqual(submitted.disposition, .canonicalized)

        try await eventually("the mined block executes") { driver.published.value?.actOnTip == cid }
        let read = await driver.reads.readSnapshot()
        XCTAssertEqual(read.tipCID, cid)
        XCTAssertEqual(read.height, 1)
        let canonical = await driver.reads.explorerCanonicalBlockCID(atHeight: 1)
        XCTAssertEqual(canonical, cid)
        let block = await driver.reads.block(cid: cid)
        XCTAssertEqual(block?.height, 1)
        let status = await driver.status()
        XCTAssertNotNil(status.templateDigest)

        // The root cleared its own target, so its work is closed.
        do {
            _ = try await driver.submitWork(SubmitWorkRequest(workID: template.workID, nonce: nonce))
            XCTFail("closed work was accepted again")
        } catch let error as TemplateError {
            XCTAssertEqual(error, .unknownWork)
        }
        await driver.stop()
        do {
            _ = try await driver.miningTemplate(MiningTemplateRequest())
            XCTFail("a stopped driver answered")
        } catch let error as CoreDriverError {
            XCTAssertEqual(error, .stopped)
        }
    }

    private static func block(_ block: Block, nonce: UInt64) -> Block {
        Block(
            version: block.version,
            parent: block.parent,
            transactions: block.transactions,
            target: block.target,
            nextTarget: block.nextTarget,
            spec: block.spec,
            parentState: block.parentState,
            prevState: block.prevState,
            postState: block.postState,
            children: block.children,
            height: block.height,
            timestamp: block.timestamp,
            rewardRecipient: block.rewardRecipient,
            nonce: nonce
        )
    }
}
