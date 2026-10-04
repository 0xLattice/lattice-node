import Crypto
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

    func testMaintenanceAnnouncesNexusAndEveryMaterializedChildGenesis() async throws {
        let routerKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 0x46, count: 32)
        )
        let routerPort = NetworkTransportTestPorts.allocate()
        let router = Ivy(config: IvyConfig(
            signingKey: routerKey,
            listenPort: routerPort,
            requestTimeout: .seconds(5),
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            externalAddress: ("127.0.0.1", routerPort),
            mode: .overlay
        ))
        let hello = try ChainHandshake(
            nexusGenesisCID: NexusGenesis.expectedBlockHash,
            chainPath: ["Nexus"]
        ).encode()
        let routerDelegate = BootstrapHelloDelegate(hello: hello)
        await router.installTestDelegate(routerDelegate)
        try await router.start()
        addTeardownBlock { await router.stop() }

        let routerEndpoint = PeerEndpoint(
            publicKey: try PeerKey(
                rawRepresentation: routerKey.publicKey.rawRepresentation
            ).hex,
            host: "127.0.0.1",
            port: routerPort
        )
        let storageDirectory = temporaryDirectory()
        let nodePort = NetworkTransportTestPorts.allocate()
        let alpha = ["Nexus", "Alpha"]
        let childSpec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 10,
            halvingInterval: 10_000,
            halfLife: 10
        )
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storageDirectory,
            privateKeyHex: String(repeating: "47", count: 32),
            listenPort: nodePort,
            rpcPort: NetworkTransportTestPorts.allocate(),
            bootstrapPeers: [routerEndpoint],
            externalAddress: "127.0.0.1",
            hostedChildren: [alpha],
            childSpecs: [alpha: childSpec]
        )
        let overlay = IvyConfig(
            signingKey: configuration.signingKey,
            listenPort: nodePort,
            bootstrapPeers: [routerEndpoint],
            requestTimeout: .seconds(5),
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            externalAddress: ("127.0.0.1", nodePort),
            mode: .overlay
        )
        let storage = try await NodeStorage.open(configuration: configuration)
        let runtime = try await NodeRuntime.start(
            storage: storage,
            configuration: configuration,
            overlay: overlay
        )
        addTeardownBlock { await runtime.stop() }
        try await eventually("the bootstrap session becomes ready") {
            runtime.peerCount == 1
        }

        try await eventually("Nexus is announced to the overlay") {
            runtime.inputs.yield(.maintenance)
            return await router.providers(for: configuration.nexusGenesisCID)
                .contains { $0.publicKey == configuration.processPublicKey }
        }

        let alphaReads = try XCTUnwrap(runtime.levelReads[alpha])
        _ = try await runtime.mineBlock()
        try await eventually("Alpha's genesis executes") {
            await alphaReads.explorerCanonicalBlockCID(atHeight: 0) != nil
        }
        let materializedAlphaGenesis = await alphaReads.explorerCanonicalBlockCID(atHeight: 0)
        let alphaGenesis = try XCTUnwrap(materializedAlphaGenesis)
        try await eventually("Alpha's genesis is announced to the overlay") {
            runtime.inputs.yield(.maintenance)
            return await router.providers(for: alphaGenesis)
                .contains { $0.publicKey == configuration.processPublicKey }
        }

        await runtime.stop()
        await router.stop()
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

    /// The explorer block reads name the coinbase recipient and what
    /// consensus credited it: reward + fees, or 0 when the recipient is nil.
    func testExplorerBlockReadsReportTheRewardRecipientAndCredit() async throws {
        let node = try host(keyByte: 0x36)
        let storage = try await NodeStorage.open(configuration: node.configuration)
        let runtime = try await NodeRuntime.start(
            storage: storage, configuration: node.configuration, overlay: node.overlay
        )
        let payer = CryptoUtils.generateKeyPair()
        let payerAddress = CryptoUtils.createAddress(from: payer.publicKey)
        let miner = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
        let payee = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)

        func mine(_ recipient: String?) async throws -> String {
            let request = MiningTemplateRequest(recipients: recipient.map {
                [MiningRecipient(chainPath: ["Nexus"], address: $0)]
            } ?? [])
            let template = try await runtime.miningTemplate(request)
            var nonce: UInt64 = 0
            while Self.block(template.block, nonce: nonce).proofOfWorkHash() > template.searchTarget { nonce += 1 }
            let mined = try await runtime.submitWork(SubmitWorkRequest(workID: template.workID, nonce: nonce))
            XCTAssertEqual(mined.disposition, .canonicalized)
            return try BlockHeader(node: Self.block(template.block, nonce: nonce)).rawCID
        }
        func reward(_ cid: String) async throws -> UInt64 {
            let blockRead = await runtime.reads.block(cid: cid)
            let block = try XCTUnwrap(blockRead)
            let specRead = try await block.spec.resolve(fetcher: storage).node
            let spec = try XCTUnwrap(specRead)
            return spec.rewardAtBlock(block.height)
        }

        // Block 1 pays the payer: reward only, no transactions.
        let first = try await mine(payerAddress)
        let firstDetailRead = await runtime.reads.explorerBlock(cid: first)
        let firstDetail = try XCTUnwrap(firstDetailRead)
        XCTAssertEqual(firstDetail.rewardRecipient, payerAddress)
        let firstReward = try await reward(first)
        XCTAssertEqual(firstDetail.rewardCredited, firstReward)
        let funded = try XCTUnwrap(firstDetail.rewardCredited)
        XCTAssertGreaterThan(funded, 10)

        // Block 2 carries a transfer leaving a fee of 7 (balance excess).
        let fee: Int64 = 7
        let bodyHeader = try HeaderImpl(node: TransactionBody(
            accountActions: [
                AccountAction(owner: payerAddress, delta: -10),
                AccountAction(owner: payee, delta: 10 - fee),
            ],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [payerAddress], nonce: 0, chainPath: ["Nexus"]
        ))
        _ = try await runtime.submitTransaction(SubmitTransactionRequest(transaction: Transaction(
            signatures: [payer.publicKey: try XCTUnwrap(TransactionSigning.sign(
                bodyHeader: bodyHeader, privateKeyHex: payer.privateKey
            ))],
            body: bodyHeader
        )))
        let second = try await mine(miner)
        let secondDetailRead = await runtime.reads.explorerBlock(cid: second)
        let secondDetail = try XCTUnwrap(secondDetailRead)
        XCTAssertEqual(secondDetail.transactionCount, 1)
        XCTAssertEqual(secondDetail.rewardRecipient, miner)
        let secondReward = try await reward(second)
        XCTAssertEqual(secondDetail.rewardCredited, secondReward + UInt64(fee))
        let latestRead = await runtime.reads.explorerLatestBlock()
        let latest = try XCTUnwrap(latestRead)
        XCTAssertEqual(latest.hash, second)
        XCTAssertEqual(latest.rewardRecipient, miner)
        XCTAssertEqual(latest.rewardCredited, secondDetail.rewardCredited)

        // Block 3 has no recipient: the reward burns, nothing is credited.
        let third = try await mine(nil)
        let thirdDetailRead = await runtime.reads.explorerBlock(cid: third)
        let thirdDetail = try XCTUnwrap(thirdDetailRead)
        XCTAssertNil(thirdDetail.rewardRecipient)
        XCTAssertEqual(thirdDetail.rewardCredited, 0)
        let thirdLatestRead = await runtime.reads.explorerLatestBlock()
        let thirdLatest = try XCTUnwrap(thirdLatestRead)
        XCTAssertNil(thirdLatest.rewardRecipient)
        XCTAssertEqual(thirdLatest.rewardCredited, 0)
        // The burned block still reports an explicit 0 credit on the wire.
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(thirdDetail), encoding: .utf8))
        XCTAssertTrue(json.contains("\"rewardCredited\":0"), json)
        await runtime.stop()
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

private final class BootstrapHelloDelegate: IvyDelegate {
    private let hello: Data

    init(hello: Data) {
        self.hello = hello
    }

    func ivy(_ ivy: Ivy, didConnect peer: AuthenticatedPeer) async {
        _ = await ivy.sendMessage(
            to: peer,
            topic: OverlayTopic.overlayHello,
            payload: hello
        )
    }
}

private extension Ivy {
    func installTestDelegate(_ delegate: IvyDelegate) {
        self.delegate = delegate
    }
}
