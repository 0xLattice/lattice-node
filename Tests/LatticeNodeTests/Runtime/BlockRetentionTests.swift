import Crypto
import Foundation
import Ivy
import Lattice
import LatticeNodeCore
import VolumeBroker
import XCTest
import cashew
@testable import LatticeNode

/// `retainBlockBytes`: a node releases the bodies of executed blocks its
/// budget does not cover, and goes on mining, syncing and restarting.
final class BlockRetentionTests: XCTestCase {
    private struct Host {
        let configuration: NodeConfiguration
        let overlay: IvyConfig
        let endpoint: PeerEndpoint
    }

    private func host(
        keyByte: UInt8,
        peers: [PeerEndpoint] = [],
        storageDirectory reused: URL? = nil,
        retainBlockBytes: Int? = nil
    ) throws -> Host {
        let storageDirectory = reused ?? FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-node-retention-\(UUID().uuidString)", isDirectory: true
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
            retainBlockBytes: retainBlockBytes
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

    private func mine(_ runtime: NodeRuntime) async throws -> String {
        try BlockHeader(node: try await runtime.mineBlock()).rawCID
    }

    /// With no budget for bodies, a miner releases each block's body once it
    /// has built past it, keeps mining, and restarts on what is left.
    func testAMinerWithNoBudgetReleasesBodiesItBuiltPastAndRestarts() async throws {
        let miner = try host(keyByte: 0x51, retainBlockBytes: 0)
        let genesis = miner.configuration.nexusGenesisCID
        var blocks: [String] = []
        do {
            let storage = try await NodeStorage.open(configuration: miner.configuration)
            let runtime = try await NodeRuntime.start(
                storage: storage, configuration: miner.configuration, overlay: miner.overlay
            )
            for _ in 0..<4 { blocks.append(try await mine(runtime)) }
            let tip = try XCTUnwrap(blocks.last)
            XCTAssertEqual(runtime.published.value?.actOnTip, tip)
            try await eventually("every body below the tip is released") {
                for cid in blocks.dropLast() where await storage.volume(cid) != nil { return false }
                return true
            }
            let tipVolume = await storage.volume(tip)
            XCTAssertNotNil(tipVolume, "the tip's body stays whatever the budget")
            let genesisVolume = await storage.volume(genesis)
            XCTAssertNotNil(genesisVolume, "the genesis block is never released")
            await runtime.stop()
        }

        // The journal still names the released bodies; boot retains what is left.
        let reopened = try await NodeStorage.open(configuration: miner.configuration)
        let runtime = try await NodeRuntime.start(
            storage: reopened, configuration: miner.configuration, overlay: miner.overlay
        )
        XCTAssertEqual(runtime.published.value?.actOnTip, blocks.last)
        let next = try await mine(runtime)
        XCTAssertEqual(runtime.published.value?.actOnTip, next)
        XCTAssertEqual(runtime.published.value?.actOnHeight, UInt64(blocks.count + 1))
        await runtime.stop()
    }

    /// A node with no budget for bodies syncs a chain from a peer that kept
    /// them, releasing as it goes, and replays to the same tip.
    func testAJoinerWithNoBudgetSyncsFromAPeerThatKeptEveryBody() async throws {
        let producer = try host(keyByte: 0x52)
        let producerStorage = try await NodeStorage.open(configuration: producer.configuration)
        let producerRuntime = try await NodeRuntime.start(
            storage: producerStorage, configuration: producer.configuration, overlay: producer.overlay
        )
        var blocks: [String] = []
        for _ in 0..<8 { blocks.append(try await mine(producerRuntime)) }
        let tip = try XCTUnwrap(blocks.last)

        let joiner = try host(keyByte: 0x53, peers: [producer.endpoint], retainBlockBytes: 0)
        do {
            let storage = try await NodeStorage.open(configuration: joiner.configuration)
            let runtime = try await NodeRuntime.start(
                storage: storage, configuration: joiner.configuration, overlay: joiner.overlay
            )
            try await eventually("the joiner executes the producer's tip") {
                runtime.published.value?.actOnTip == tip
            }
            try await eventually("the joiner released every body below the tip") {
                for cid in blocks.dropLast() where await storage.volume(cid) != nil { return false }
                return true
            }
            await runtime.stop()
        }
        for cid in blocks {
            let kept = await producerStorage.volume(cid)
            XCTAssertNotNil(kept, "a node with no budget set keeps every body")
        }
        await producerRuntime.stop()

        let reopened = try await NodeStorage.open(configuration: joiner.configuration)
        let booted = try await NodeRuntime.boot(
            storage: reopened, configuration: joiner.configuration, coreConfig: .init()
        )
        XCTAssertEqual(booted.levels[booted.rootPath]?.snapshot.actOnTip, tip)
    }

    /// Execution and mining read a block's own node from the header records
    /// when its body was released: a node executes a block on such a parent
    /// and builds on such a tip, with nothing fetched for it.
    func testANodeBuildsOnABlockWhoseBodyWasReleased() async throws {
        let producer = try host(keyByte: 0x55)
        let producerStorage = try await NodeStorage.open(configuration: producer.configuration)
        let producerRuntime = try await NodeRuntime.start(
            storage: producerStorage, configuration: producer.configuration, overlay: producer.overlay
        )
        var blocks: [String] = []
        for _ in 0..<3 { blocks.append(try await mine(producerRuntime)) }
        let tip = blocks[2]

        let joiner = try host(keyByte: 0x56, peers: [producer.endpoint], retainBlockBytes: 0)
        let genesis = joiner.configuration.nexusGenesisCID
        do {
            let storage = try await NodeStorage.open(configuration: joiner.configuration)
            let runtime = try await NodeRuntime.start(
                storage: storage, configuration: joiner.configuration, overlay: joiner.overlay
            )
            try await eventually("the joiner executes the producer's tip") {
                runtime.published.value?.actOnTip == tip
            }
            await runtime.stop()
        }
        do {
            // As though the node built on the first block: the tip's body goes.
            let storage = try await NodeStorage.open(configuration: joiner.configuration)
            await storage.loadBodies(hosting: [["Nexus"]])
            var chain = HeightIndex()
            for cid in [genesis, blocks[0]] { chain.append(cid) }
            await storage.collect([ChainRetentionView(path: ["Nexus"], chain: chain, held: [])], executed: [])
            let released = await storage.volume(tip)
            XCTAssertNil(released)
        }

        // Alone, its tip is the released block: it answers a state read
        // there and builds a template on it.
        do {
            let alone = try host(
                keyByte: 0x56, storageDirectory: joiner.configuration.storagePath, retainBlockBytes: 0
            )
            let storage = try await NodeStorage.open(configuration: alone.configuration)
            let runtime = try await NodeRuntime.start(
                storage: storage, configuration: alone.configuration, overlay: alone.overlay
            )
            XCTAssertEqual(runtime.published.value?.actOnTip, tip)
            let account = await runtime.reads.account(owner: "nobody", blockCID: tip)
            XCTAssertNotNil(account, "state is not released with a body")
            _ = try await runtime.miningTemplate(MiningTemplateRequest())
            await runtime.stop()
        }

        // With its peer again, it executes the producer's next block on it.
        let next = try await mine(producerRuntime)
        let storage = try await NodeStorage.open(configuration: joiner.configuration)
        let runtime = try await NodeRuntime.start(
            storage: storage, configuration: joiner.configuration, overlay: joiner.overlay
        )
        try await eventually("the joiner executes the block after the released one") {
            runtime.published.value?.actOnTip == next
        }
        await runtime.stop()
        await producerRuntime.stop()
    }

    /// The budget is spent from the tip down: the newest bodies that fit
    /// stay and every older one goes, but never the genesis block's.
    func testABudgetKeepsTheNewestBodiesThatFit() async throws {
        let full = try host(keyByte: 0x54)
        var blocks: [String] = []
        do {
            let storage = try await NodeStorage.open(configuration: full.configuration)
            let runtime = try await NodeRuntime.start(
                storage: storage, configuration: full.configuration, overlay: full.overlay
            )
            for _ in 0..<6 { blocks.append(try await mine(runtime)) }
            await runtime.stop()
        }
        let genesis = full.configuration.nexusGenesisCID

        var sizes: [Int] = []
        do {
            let sizing = try await NodeStorage.open(configuration: full.configuration)
            for cid in blocks {
                let bytes = try await sizing.fetch(rawCid: cid)
                let block = try XCTUnwrap(Block(data: bytes))
                sizes.append(try await block.logicalContentByteSize(fetcher: sizing))
            }
        }
        var chain = HeightIndex()
        for cid in [genesis] + blocks { chain.append(cid) }
        let view = ChainRetentionView(path: ["Nexus"], chain: chain, held: [])

        // Room for exactly the two newest bodies, then for one byte less.
        for (budget, firstKept) in [(sizes[5] + sizes[4], 4), (sizes[5] + sizes[4] - 1, 5)] {
            let budgeted = try host(
                keyByte: 0x54, storageDirectory: full.configuration.storagePath, retainBlockBytes: budget
            )
            let storage = try await NodeStorage.open(configuration: budgeted.configuration)
            await storage.loadBodies(hosting: [["Nexus"]])
            await storage.collect([view], executed: [])
            for (index, cid) in blocks.enumerated() {
                let held = await storage.volume(cid) != nil
                XCTAssertEqual(held, index >= firstKept, "block \(index + 1) with a budget of \(budget)")
            }
            let genesisVolume = await storage.volume(genesis)
            XCTAssertNotNil(genesisVolume)
        }

        // Unset again: the store stays as it is and still opens.
        let unset = try await NodeStorage.open(configuration: full.configuration)
        let released = await unset.volume(blocks[0])
        XCTAssertNil(released)
    }

    /// A transaction in a block the chain left is returned to the pool and
    /// mined again. The left block's body is released; the transaction is
    /// not, because the block that carries it now is held.
    func testATransactionOfAReleasedLosingBlockSurvivesInTheBlockThatCarriesItNow() async throws {
        let node = try host(keyByte: 0x57, retainBlockBytes: 0)
        let storage = try await NodeStorage.open(configuration: node.configuration)
        var runtime = try await NodeRuntime.start(
            storage: storage, configuration: node.configuration, overlay: node.overlay
        )
        let transaction = try transaction()
        let admitted = try await runtime.submitTransaction(SubmitTransactionRequest(transaction: transaction))
        let losing = try await mine(runtime)
        let carried = await NodeRuntime.transactionIDs(ofBlock: losing, fetcher: storage)
        XCTAssertEqual(carried, [admitted.transactionCID])
        await runtime.stop()

        // A producer with a heavier two-block branch from genesis.
        let producer = try host(keyByte: 0x58)
        let producerStorage = try await NodeStorage.open(configuration: producer.configuration)
        let producerRuntime = try await NodeRuntime.start(
            storage: producerStorage, configuration: producer.configuration, overlay: producer.overlay
        )
        _ = try await mine(producerRuntime)
        let producerTip = try await mine(producerRuntime)

        let restarted = try host(
            keyByte: 0x57, peers: [producer.endpoint],
            storageDirectory: node.configuration.storagePath, retainBlockBytes: 0
        )
        runtime = try await NodeRuntime.start(
            storage: storage, configuration: restarted.configuration, overlay: restarted.overlay
        )
        try await eventually("the node reorgs onto the heavier branch") {
            runtime.published.value?.actOnTip == producerTip
        }
        // The left block's body was read before it was released.
        try await eventually("the left block's transaction is returned to the pool") {
            runtime.published.value?.mempoolCount == 1
        }
        try await eventually("the left block's body is released") {
            await storage.volume(losing) == nil
        }

        let tip = try await mine(runtime)
        XCTAssertEqual(runtime.published.value?.actOnTip, tip)
        let now = await NodeRuntime.transactionIDs(ofBlock: tip, fetcher: storage)
        XCTAssertEqual(now, [admitted.transactionCID], "the tip carries the transaction, and holds it")
        // Building past it releases it with its block.
        _ = try await mine(runtime)
        try await eventually("the transaction goes with the body that carried it") {
            await storage.volume(admitted.transactionCID) == nil
        }
        await runtime.stop()
        await producerRuntime.stop()
    }

    /// Two sibling blocks carry one transaction. The losing one's body is
    /// released while the other is held: the transaction stays, because a
    /// held body still names it.
    func testATransactionTwoBlocksCarryStaysWhileOneOfThemIsHeld() async throws {
        let shared = try transaction()
        let budget = 1_000_000_000
        let node = try host(keyByte: 0x59, retainBlockBytes: budget)
        let storage = try await NodeStorage.open(configuration: node.configuration)
        var runtime = try await NodeRuntime.start(
            storage: storage, configuration: node.configuration, overlay: node.overlay
        )
        let admitted = try await runtime.submitTransaction(SubmitTransactionRequest(transaction: shared))
        let losing = try await mine(runtime)
        await runtime.stop()

        let producer = try host(keyByte: 0x5A)
        let producerStorage = try await NodeStorage.open(configuration: producer.configuration)
        let producerRuntime = try await NodeRuntime.start(
            storage: producerStorage, configuration: producer.configuration, overlay: producer.overlay
        )
        _ = try await producerRuntime.submitTransaction(SubmitTransactionRequest(transaction: shared))
        let winning = try await mine(producerRuntime)
        let producerTip = try await mine(producerRuntime)
        let carried = await NodeRuntime.transactionIDs(ofBlock: winning, fetcher: producerStorage)
        XCTAssertEqual(carried, [admitted.transactionCID])

        let again = try host(
            keyByte: 0x59, peers: [producer.endpoint],
            storageDirectory: node.configuration.storagePath, retainBlockBytes: budget
        )
        runtime = try await NodeRuntime.start(
            storage: storage, configuration: again.configuration, overlay: again.overlay
        )
        try await eventually("the node reorgs onto the producer's branch") {
            runtime.published.value?.actOnTip == producerTip
        }
        try await eventually("the losing block's body is released") {
            await storage.volume(losing) == nil
        }
        let winningHeld = await storage.volume(winning)
        XCTAssertNotNil(winningHeld)
        let sharedHeld = await storage.volume(admitted.transactionCID)
        XCTAssertNotNil(sharedHeld, "a transaction a held block carries went with the losing block")
        await runtime.stop()
        await producerRuntime.stop()
    }
}
