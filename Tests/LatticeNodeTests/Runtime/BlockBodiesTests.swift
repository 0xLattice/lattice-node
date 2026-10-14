import Crypto
import Foundation
import Ivy
import Lattice
import LatticeNodeCore
import VolumeBroker
import XCTest
import cashew
@testable import LatticeNode

/// `blockBodies: none`: a node keeps only the bodies it needs to operate
/// (the ones waiting to execute, each chain's tip, each genesis) and goes
/// on mining, syncing and restarting.
final class BlockBodiesTests: XCTestCase {
    private struct Host {
        let configuration: NodeConfiguration
        let overlay: IvyConfig
        let endpoint: PeerEndpoint
    }

    private static let alpha = ["Nexus", "Alpha"]
    private static let alphaSpec = ChainSpec(
        maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000, premine: 0,
        targetBlockTime: 1_000, initialReward: 10, halvingInterval: 10_000, halfLife: 10
    )

    private func host(
        keyByte: UInt8,
        peers: [PeerEndpoint] = [],
        storageDirectory reused: URL? = nil,
        blockBodies: BlockBodies = .all,
        hosted: Bool = false
    ) throws -> Host {
        let storageDirectory = reused ?? FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-node-bodies-\(UUID().uuidString)", isDirectory: true
        )
        if reused == nil { addTeardownBlock { try? FileManager.default.removeItem(at: storageDirectory) } }
        let port = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storageDirectory,
            privateKeyHex: String(repeating: String(format: "%02x", keyByte), count: 32),
            listenPort: port,
            rpcPort: NetworkTransportTestPorts.allocate(),
            webSocket: .off,
            blockBodies: blockBodies,
            hostedChildren: hosted ? [Self.alpha] : [],
            childSpecs: hosted ? [Self.alpha: Self.alphaSpec] : [:]
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

    private func transaction() throws -> Transaction {
        let key = CryptoUtils.generateKeyPair()
        let bodyHeader = try HeaderImpl(node: TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: key.publicKey)],
            nonce: 0, chainPath: ["Nexus"]
        ))
        return Transaction(
            signatures: [key.publicKey: try XCTUnwrap(TransactionSigning.sign(
                bodyHeader: bodyHeader, privateKeyHex: key.privateKey
            ))],
            body: bodyHeader
        )
    }

    private func mine(
        _ runtime: NodeRuntime, _ request: MiningTemplateRequest = MiningTemplateRequest()
    ) async throws -> String {
        try BlockHeader(node: try await runtime.mineBlock(request)).rawCID
    }

    private func start(_ host: Host) async throws -> (NodeRuntime, NodeStorage) {
        let storage = try await NodeStorage.open(configuration: host.configuration)
        return (try await NodeRuntime.start(
            storage: storage, configuration: host.configuration, overlay: host.overlay
        ), storage)
    }

    private func bodiesHeld(_ storage: NodeStorage, of blocks: [String]) async -> [String] {
        var held: [String] = []
        for cid in blocks where await storage.volume(cid) != nil { held.append(cid) }
        return held
    }

    /// A miner on `none` holds its tip's body and its genesis block, lets
    /// go of each body it built past, keeps mining, and restarts.
    func testAMinerOnNoneHoldsOnlyItsTipsBody() async throws {
        let miner = try host(keyByte: 0x91, blockBodies: .none)
        let genesis = miner.configuration.nexusGenesisCID
        var blocks: [String] = []
        do {
            let (runtime, storage) = try await start(miner)
            for _ in 0..<4 { blocks.append(try await mine(runtime)) }
            let tip = try XCTUnwrap(blocks.last)
            try await eventually("every body below the tip is let go of") {
                await self.bodiesHeld(storage, of: blocks) == [tip]
            }
            let genesisVolume = await storage.volume(genesis)
            XCTAssertNotNil(genesisVolume, "every node holds its genesis block")
            let state = await runtime.reads.account(owner: "nobody", blockCID: blocks[0])
            XCTAssertNotNil(state, "state is not a body")
            await runtime.stop()
        }

        let (runtime, storage) = try await start(miner)
        XCTAssertEqual(runtime.published.value?.actOnTip, blocks.last)
        let next = try await mine(runtime)
        XCTAssertEqual(runtime.published.value?.actOnHeight, UInt64(blocks.count + 1))
        try await eventually("the old tip's body goes once another block is the tip") {
            await self.bodiesHeld(storage, of: blocks + [next]) == [next]
        }
        await runtime.stop()
    }

    /// A node on `none` syncs a chain from a peer that keeps every body,
    /// letting go as it goes, and replays to the same tip. Its peer, on the
    /// default, lets go of nothing.
    func testAJoinerOnNoneSyncsFromAPeerThatKeepsEveryBody() async throws {
        let producer = try host(keyByte: 0x92)
        let (producerRuntime, producerStorage) = try await start(producer)
        var blocks: [String] = []
        for _ in 0..<8 { blocks.append(try await mine(producerRuntime)) }
        let tip = try XCTUnwrap(blocks.last)

        let joiner = try host(keyByte: 0x93, peers: [producer.endpoint], blockBodies: .none)
        do {
            let (runtime, storage) = try await start(joiner)
            try await eventually("the joiner executes the producer's tip") {
                runtime.published.value?.actOnTip == tip
            }
            try await eventually("the joiner holds only its tip's body") {
                await self.bodiesHeld(storage, of: blocks) == [tip]
            }
            await runtime.stop()
        }
        let kept = await bodiesHeld(producerStorage, of: blocks)
        XCTAssertEqual(kept, blocks, "a node keeping all lets go of no body")
        await producerRuntime.stop()

        let reopened = try await NodeStorage.open(configuration: joiner.configuration)
        let booted = try await NodeRuntime.boot(
            storage: reopened, configuration: joiner.configuration, coreConfig: .init()
        )
        XCTAssertEqual(booted.levels[booted.rootPath]?.snapshot.actOnTip, tip)
    }

    /// A node that kept every body is switched to `none`: at its next start
    /// it lets go of all but its tip's.
    func testSwitchingToNoneLetsGoOfTheBodiesARunThatKeptAllLeft() async throws {
        let all = try host(keyByte: 0x96)
        var blocks: [String] = []
        do {
            let (runtime, storage) = try await start(all)
            for _ in 0..<4 { blocks.append(try await mine(runtime)) }
            await runtime.stop()
            let held = await bodiesHeld(storage, of: blocks)
            XCTAssertEqual(held, blocks)
        }

        let none = try host(keyByte: 0x96, storageDirectory: all.configuration.storagePath, blockBodies: .none)
        let (runtime, storage) = try await start(none)
        let tip = try XCTUnwrap(blocks.last)
        try await eventually("only the tip's body is left") {
            await self.bodiesHeld(storage, of: blocks) == [tip]
        }
        let genesis = await storage.volume(none.configuration.nexusGenesisCID)
        XCTAssertNotNil(genesis)
        let next = try await mine(runtime)
        XCTAssertEqual(runtime.published.value?.actOnTip, next)
        await runtime.stop()
    }

    /// When the chain moves to another branch, the bodies of the blocks it
    /// left are let go of, and their transactions are read from a peer and
    /// returned to the pool. The tip that then carries one holds it, and it
    /// goes with that tip's body.
    func testTransactionsOfTheBlocksTheChainLeftAreReadFromAPeer() async throws {
        let left = try host(keyByte: 0xa4)
        let (leftRuntime, _) = try await start(left)
        let carried = try await leftRuntime.submitTransaction(
            SubmitTransactionRequest(transaction: try transaction())
        ).transactionCID
        _ = try await mine(leftRuntime)
        let a2 = try await mine(leftRuntime)

        let heavier = try host(keyByte: 0xa5)
        let (heavierRuntime, _) = try await start(heavier)
        for _ in 0..<2 { _ = try await mine(heavierRuntime) }
        let b3 = try await mine(heavierRuntime)

        var node = try host(keyByte: 0xa6, peers: [left.endpoint], blockBodies: .none)
        let (runtime, storage) = try await start(node)
        try await eventually("the node executes the first branch") { runtime.published.value?.actOnTip == a2 }
        await runtime.stop()
        node = try host(
            keyByte: 0xa6, peers: [left.endpoint, heavier.endpoint],
            storageDirectory: node.configuration.storagePath, blockBodies: .none
        )
        let again = try await NodeRuntime.start(
            storage: storage, configuration: node.configuration, overlay: node.overlay
        )
        try await eventually("the node moves onto the heavier branch") { again.published.value?.actOnTip == b3 }
        try await eventually("the left block's transaction is returned") {
            again.published.value?.mempoolCount == 1
        }
        try await eventually("the left tip's body is let go of") { await storage.volume(a2) == nil }

        let tip = try await mine(again)
        let now = await NodeRuntime.transactionIDs(ofBlock: tip, fetcher: storage)
        XCTAssertEqual(now, [carried], "the tip carries the transaction, and holds it")
        _ = try await mine(again)
        try await eventually("the transaction goes with the body that carried it") {
            await storage.volume(carried) == nil
        }
        await again.stop()
        await leftRuntime.stop()
        await heavierRuntime.stop()
    }

    /// A node on `none` that hosts a child chain holds each level's tip
    /// and the child's genesis block, and both levels go on advancing
    /// across a restart.
    func testAHostedChildOnNoneAdvancesAndRestarts() async throws {
        let paid = MiningTemplateRequest(recipients: [
            MiningRecipient(
                chainPath: ["Nexus"], address: CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
            ),
            MiningRecipient(
                chainPath: Self.alpha, address: CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
            ),
        ])
        let miner = try host(keyByte: 0xa8, blockBodies: .none, hosted: true)
        var roots: [String] = []
        var children: [String] = []
        var childGenesis = ""
        do {
            let (runtime, storage) = try await start(miner)
            let alpha = try XCTUnwrap(runtime.levelReads[Self.alpha])
            for round in 0..<4 {
                roots.append(try await mine(runtime, paid))
                try await eventually("the child advances (round \(round))") {
                    guard let tip = await alpha.readSnapshot().tipCID, !tip.isEmpty, children.last != tip else {
                        return false
                    }
                    children.append(tip)
                    return true
                }
            }
            childGenesis = try XCTUnwrap(children.first)
            let (rootTip, childTip) = (try XCTUnwrap(roots.last), try XCTUnwrap(children.last))
            try await eventually("each level holds its tip's body, and the child its genesis block") {
                let heldRoots = await self.bodiesHeld(storage, of: roots)
                let heldChildren = await self.bodiesHeld(storage, of: children)
                return heldRoots == [rootTip] && heldChildren == [childGenesis, childTip]
            }
            let named = try await storage.broker.retainedRoots(scope: storage.scopes.body(childTip, at: Self.alpha))
            XCTAssertTrue(named.contains(childTip), "a body is named by its block on its chain")
            await runtime.stop()
        }

        let (runtime, storage) = try await start(miner)
        let alpha = try XCTUnwrap(runtime.levelReads[Self.alpha])
        let before = await alpha.readSnapshot().height ?? 0
        _ = try await mine(runtime, paid)
        try await eventually("the child advances after the restart") {
            (await alpha.readSnapshot().height ?? 0) > before
        }
        let genesis = await storage.volume(childGenesis)
        XCTAssertNotNil(genesis, "every node holds each chain's genesis block")
        await runtime.stop()
    }
}
