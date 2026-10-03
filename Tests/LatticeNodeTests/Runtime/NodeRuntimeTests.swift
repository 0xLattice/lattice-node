import Foundation
import Ivy
import Lattice
import LatticeNodeCore
import XCTest
import cashew
@testable import LatticeNode

/// The node runtime end to end: two Nexus nodes on loopback Ivy, each a
/// `NodeRuntime` over its own `NodeStorage`. The producer's history is
/// boot-replayed into its core; the joiner syncs the headers, fetches the
/// bodies by CID, executes them, and boot-replays its own journal.
final class NodeRuntimeTests: XCTestCase {
    private struct Host {
        let configuration: NodeConfiguration
        let overlay: IvyConfig
        let endpoint: PeerEndpoint
    }

    private func host(
        keyByte: UInt8,
        peers: [PeerEndpoint] = [],
        storageDirectory reused: URL? = nil
    ) throws -> Host {
        let storageDirectory = reused ?? FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-node-runtime-\(UUID().uuidString)", isDirectory: true
        )
        if reused == nil { addTeardownBlock { try? FileManager.default.removeItem(at: storageDirectory) } }
        let port = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storageDirectory,
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
        let producerStorage = try await NodeStorage.open(configuration: producer.configuration)
        let producerRuntime = try await NodeRuntime.start(
            storage: producerStorage, configuration: producer.configuration, overlay: producer.overlay
        )
        var blockCIDs: [String] = []
        for _ in 0..<4 {
            blockCIDs.append(try BlockHeader(node: try await producerRuntime.mineBlock()).rawCID)
        }
        let tipCID = try XCTUnwrap(blockCIDs.last)
        XCTAssertEqual(producerRuntime.published.value?.actOnTip, tipCID)

        let joiner = try host(keyByte: 0x32, peers: [producer.endpoint])
        do {
            let joinerStorage = try await NodeStorage.open(configuration: joiner.configuration)
            let joinerRuntime = try await NodeRuntime.start(
                storage: joinerStorage, configuration: joiner.configuration, overlay: joiner.overlay
            )
            try await eventually("the joiner executes the producer's tip") {
                joinerRuntime.published.value?.actOnTip == tipCID
            }
            XCTAssertEqual(joinerRuntime.published.value?.actOnHeight, 4)
            await joinerRuntime.stop()
        }
        await producerRuntime.stop()

        // Restart: the joiner's own journal replays to the same tip.
        let reopened = try await NodeStorage.open(configuration: joiner.configuration)
        let host = try await NodeRuntime.boot(
            storage: reopened, configuration: joiner.configuration, coreConfig: .init(),
            headers: try HeaderEvidenceStore(directory: joiner.configuration.storagePath)
        )
        let snapshot = try XCTUnwrap(host.levels[host.rootPath]?.snapshot)
        XCTAssertEqual(snapshot.actOnTip, tipCID)
        XCTAssertEqual(snapshot.bestHeaderTip, tipCID)

        // The executed bodies stay retained across the restart: a sweep
        // keeps every one.
        _ = try await reopened.broker.sweep()
        for cid in blockCIDs {
            let volume = await reopened.volume(cid)
            XCTAssertNotNil(volume, "body \(cid) was evicted after restart")
        }
    }

    /// RPC writes are core events answered from effects, and RPC reads come
    /// from the published snapshot: a template on the act-on tip, a grind
    /// submitted and weighed, its body connected, and every read following.
    func testRPCWritesAreCoreEventsAndReadsFollowThePublishedSnapshot() async throws {
        let node = try host(keyByte: 0x33)
        let storage = try await NodeStorage.open(configuration: node.configuration)
        let runtime = try await NodeRuntime.start(
            storage: storage, configuration: node.configuration, overlay: node.overlay
        )
        let genesis = try XCTUnwrap(runtime.published.value?.actOnTip)

        let template = try await runtime.miningTemplate(MiningTemplateRequest())
        XCTAssertEqual(template.block.parent?.rawCID, genesis)
        var nonce: UInt64 = 0
        while Self.block(template.block, nonce: nonce).proofOfWorkHash() > template.searchTarget {
            nonce += 1
        }
        let cid = try BlockHeader(node: Self.block(template.block, nonce: nonce)).rawCID
        let submitted = try await runtime.submitWork(SubmitWorkRequest(workID: template.workID, nonce: nonce))
        XCTAssertTrue(submitted.accepted)
        XCTAssertEqual(submitted.disposition, .canonicalized)
        // Answered once executed: the act-on tip is the mined block, and the
        // next template builds on it.
        XCTAssertEqual(submitted.tipCID, cid)
        XCTAssertEqual(runtime.published.value?.actOnTip, cid)
        let next = try await runtime.miningTemplate(MiningTemplateRequest())
        XCTAssertEqual(next.block.parent?.rawCID, cid)
        let read = await runtime.reads.readSnapshot()
        XCTAssertEqual(read.tipCID, cid)
        XCTAssertEqual(read.height, 1)
        let canonical = await runtime.reads.explorerCanonicalBlockCID(atHeight: 1)
        XCTAssertEqual(canonical, cid)
        let block = await runtime.reads.block(cid: cid)
        XCTAssertEqual(block?.height, 1)
        let status = await runtime.status()
        XCTAssertNotNil(status.templateDigest)

        // The root cleared its own target, so its work is closed.
        do {
            _ = try await runtime.submitWork(SubmitWorkRequest(workID: template.workID, nonce: nonce))
            XCTFail("closed work was accepted again")
        } catch let error as TemplateError {
            XCTAssertEqual(error, .unknownWork)
        }
        await runtime.stop()
        do {
            _ = try await runtime.miningTemplate(MiningTemplateRequest())
            XCTFail("a stopped runtime answered")
        } catch let error as NodeRuntimeError {
            XCTAssertEqual(error, .stopped)
        }
    }

    /// Bitcoin's rule on a reorg: every transaction of a block the act-on
    /// chain left is returned, read from its body, even right after a
    /// restart (nothing about it is kept in memory).
    func testAReorgRightAfterARestartReturnsTheLeftBlocksTransactions() async throws {
        let node = try host(keyByte: 0x34)
        let storage = try await NodeStorage.open(configuration: node.configuration)
        var runtime = try await NodeRuntime.start(
            storage: storage, configuration: node.configuration, overlay: node.overlay
        )
        let key = CryptoUtils.generateKeyPair()
        let bodyHeader = try HeaderImpl(node: TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: key.publicKey)],
            nonce: 0, chainPath: ["Nexus"]
        ))
        let transaction = Transaction(
            signatures: [key.publicKey: try XCTUnwrap(TransactionSigning.sign(
                bodyHeader: bodyHeader, privateKeyHex: key.privateKey
            ))],
            body: bodyHeader
        )
        let admitted = try await runtime.submitTransaction(SubmitTransactionRequest(transaction: transaction))
        // Our one block carries it.
        let template = try await runtime.miningTemplate(MiningTemplateRequest())
        var nonce: UInt64 = 0
        while Self.block(template.block, nonce: nonce).proofOfWorkHash() > template.searchTarget { nonce += 1 }
        let mined = try await runtime.submitWork(SubmitWorkRequest(workID: template.workID, nonce: nonce))
        XCTAssertEqual(mined.disposition, .canonicalized)
        let carried = try await MiningTemplateAssembly.blockTransactions(
            in: Self.block(template.block, nonce: nonce), fetcher: storage
        )
        XCTAssertEqual(try carried.map { try Mempool.cid(of: $0) }, [admitted.transactionCID])
        await runtime.stop()

        // A producer with a heavier two-block branch from genesis.
        let producer = try host(keyByte: 0x35)
        let producerStorage = try await NodeStorage.open(configuration: producer.configuration)
        let producerRuntime = try await NodeRuntime.start(
            storage: producerStorage, configuration: producer.configuration, overlay: producer.overlay
        )
        _ = try await producerRuntime.mineBlock()
        let producerTip = try BlockHeader(node: try await producerRuntime.mineBlock()).rawCID

        // Restart, then reorg onto the producer's branch.
        let restarted = try host(
            keyByte: 0x34,
            peers: [producer.endpoint],
            storageDirectory: node.configuration.storagePath
        )
        runtime = try await NodeRuntime.start(
            storage: storage, configuration: restarted.configuration, overlay: restarted.overlay
        )
        try await eventually("the restarted node reorgs onto the heavier branch") {
            runtime.published.value?.actOnTip == producerTip
        }
        try await eventually("the left block's transaction is returned to the pool") {
            runtime.published.value?.mempoolCount == 1
        }
        let listing = await runtime.reads.explorerMempool()
        XCTAssertEqual(listing.transactions, [admitted.transactionCID])
        await runtime.stop()
        await producerRuntime.stop()
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
