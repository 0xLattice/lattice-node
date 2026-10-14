import Crypto
import Foundation
import Ivy
import Lattice
import LatticeNodeCore
import VolumeBroker
import Tally
import XCTest
import cashew
@testable import LatticeNode

/// Content stays because a scope names it: a block's body under the
/// block's name, what executions read and create under the chain's.
final class RetentionRulesTests: XCTestCase {
    private struct Host {
        let configuration: NodeConfiguration
        let overlay: IvyConfig
        let endpoint: PeerEndpoint
    }

    private func host(keyByte: UInt8, peers: [PeerEndpoint] = [], storageDirectory reused: URL? = nil) throws -> Host {
        let storageDirectory = reused ?? FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-node-rules-\(UUID().uuidString)", isDirectory: true
        )
        if reused == nil { addTeardownBlock { try? FileManager.default.removeItem(at: storageDirectory) } }
        let port = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storageDirectory,
            privateKeyHex: String(repeating: String(format: "%02x", keyByte), count: 32),
            listenPort: port,
            rpcPort: NetworkTransportTestPorts.allocate(),
            webSocket: .off
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

    private func mine(_ runtime: NodeRuntime) async throws -> String {
        try BlockHeader(node: try await runtime.mineBlock()).rawCID
    }

    /// A mined block's body is pinned under the block's name once the block
    /// is recorded, with its transaction; the chain's scope names neither.
    /// Both survive a restart, which leaves pins as it finds them.
    func testABodyIsPinnedUnderItsBlocksNameAndStaysAcrossARestart() async throws {
        let node = try host(keyByte: 0x81)
        var mined = ""
        var carried = ""
        do {
            let storage = try await NodeStorage.open(configuration: node.configuration)
            let runtime = try await NodeRuntime.start(
                storage: storage, configuration: node.configuration, overlay: node.overlay
            )
            carried = try await runtime.submitTransaction(
                SubmitTransactionRequest(transaction: try transaction())
            ).transactionCID
            mined = try await mine(runtime)
            let held = await NodeRuntime.transactionIDs(ofBlock: mined, fetcher: storage)
            XCTAssertEqual(held, [carried])
            try await eventually("the body is pinned under the block's own name") {
                try await Set(storage.broker.retainedRoots(scope: storage.scopes.body(mined))) == [mined, carried]
            }
            let chain = try await Set(storage.broker.retainedRoots(scope: storage.scopes.chain))
            XCTAssertTrue(chain.isDisjoint(with: [mined, carried]), "a body is not the chain's to name")
            XCTAssertFalse(chain.isEmpty, "what its execution read and created is")
            await runtime.stop()
        }

        let reopened = try await NodeStorage.open(configuration: node.configuration)
        let pinned = try await Set(reopened.broker.retainedRoots(scope: reopened.scopes.body(mined)))
        XCTAssertEqual(pinned, [mined, carried])
        let body = await reopened.volume(mined)
        XCTAssertNotNil(body)
        let transaction = await reopened.volume(carried)
        XCTAssertNotNil(transaction)
        let booted = try await NodeRuntime.boot(
            storage: reopened, configuration: node.configuration, coreConfig: .init()
        )
        XCTAssertEqual(booted.levels[booted.rootPath]?.snapshot.actOnTip, mined)
    }

    /// A block's body is every entry of its transaction index, as storing
    /// the block finds them: consensus puts no rule on the index's keys.
    func testABodyIsEveryEntryOfTheTransactionIndexWhateverItsKey() async throws {
        for key in ["0", "a", "1"] {
            let producer = try await NodeStorage.open(configuration: try host(keyByte: 0x86).configuration)
            let joiner = try await NodeStorage.open(configuration: try host(keyByte: 0x87).configuration)
            let genesisCID = NexusGenesis.expectedBlockHash
            let genesisData = await producer.content([genesisCID])[genesisCID]
            let genesis = try XCTUnwrap(Block(data: try XCTUnwrap(genesisData)))
            let carried = try transaction()
            var nonce: UInt64 = 0
            var block: Block
            repeat {
                let built = try await BlockBuilder.buildBlockWithTransition(
                    previous: genesis, transactions: [carried],
                    timestamp: TestBlockClock().next(), nonce: nonce, fetcher: producer
                ).block
                let index = try HeaderImpl(node: MerkleDictionaryImpl<VolumeImpl<Transaction>>()
                    .inserting(key: key, value: try VolumeImpl<Transaction>(node: carried)))
                block = Block(
                    version: built.version, parent: built.parent, transactions: index,
                    target: built.target, nextTarget: built.nextTarget, spec: built.spec,
                    parentState: built.parentState, prevState: built.prevState, postState: built.postState,
                    children: built.children, height: built.height, timestamp: built.timestamp,
                    rewardRecipient: built.rewardRecipient, nonce: nonce
                )
                nonce += 1
            } while block.proofOfWorkHash() > block.target
            let header = try BlockHeader(node: block)
            let producerBroker = await producer.broker
            let storer = NodeImportStorage(storage: producerBroker)
            try await header.storeBlock(fetcher: producer, storer: storer)
            try await storer.commit()
            try await producer.retainHeld(await storer.takeStoredVolumeRoots())
            let valid = try await block.validateNexus(fetcher: producer.localFetcher).0
            XCTAssertTrue(valid, "key \(key)")

            let source = NodeStorageIvyContentSource(storage: producer)
            let server = PeerID(publicKey: String(repeating: "ab", count: 32))
            let remote = IvyRootContentSource(fetch: { root in
                let entries = await source.volume(rootCID: root, maxDataBytes: .max)
                guard !entries.isEmpty else { return .empty }
                return AttributedVolumeResponse(
                    rootCID: root,
                    entries: Dictionary(uniqueKeysWithValues: entries.map { ($0.cid, $0.data) }),
                    servedBy: server
                )
            }, fetchBundle: { _ in [] })
            _ = try await joiner.fetchChainBody(header.rawCID, remote: remote)
            let pinned = try await Set(joiner.broker.retainedRoots(scope: joiner.scopes.body(header.rawCID)))
            XCTAssertEqual(pinned, [header.rawCID, try Mempool.cid(of: carried)], "key \(key)")
        }
    }

    /// What executions created stays with the chain: after a restart, which
    /// drops what no scope names, the state of every block is read from
    /// this store and the node builds on its tip.
    func testExecutedStateStaysAcrossARestart() async throws {
        let node = try host(keyByte: 0x85)
        let miner = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
        let paid = MiningTemplateRequest(recipients: [MiningRecipient(chainPath: ["Nexus"], address: miner)])
        var blocks: [String] = []
        do {
            let storage = try await NodeStorage.open(configuration: node.configuration)
            let runtime = try await NodeRuntime.start(
                storage: storage, configuration: node.configuration, overlay: node.overlay
            )
            for _ in 0..<4 { blocks.append(try BlockHeader(node: try await runtime.mineBlock(paid)).rawCID) }
            await runtime.stop()
        }

        let storage = try await NodeStorage.open(configuration: node.configuration)
        let runtime = try await NodeRuntime.start(
            storage: storage, configuration: node.configuration, overlay: node.overlay
        )
        var balances: [UInt64] = []
        for cid in blocks { balances.append(await runtime.reads.account(owner: miner, blockCID: cid)?.balance ?? 0) }
        XCTAssertEqual(balances, balances.sorted(), "each block's own state is read")
        XCTAssertGreaterThan(try XCTUnwrap(balances.first), 0)
        XCTAssertEqual(Set(balances).count, blocks.count)
        _ = try await runtime.mineBlock(paid)
        XCTAssertEqual(runtime.published.value?.actOnHeight, UInt64(blocks.count + 1))
        await runtime.stop()
    }

    /// Letting go of a body removes the block's own Volume and its
    /// transactions, and nothing the chain's scope names: the node goes on
    /// reading state and building on that block.
    func testLettingGoOfABodyKeepsWhatTheChainNames() async throws {
        let node = try host(keyByte: 0x82)
        let storage = try await NodeStorage.open(configuration: node.configuration)
        let runtime = try await NodeRuntime.start(
            storage: storage, configuration: node.configuration, overlay: node.overlay
        )
        let carried = try await runtime.submitTransaction(
            SubmitTransactionRequest(transaction: try transaction())
        ).transactionCID
        let mined = try await mine(runtime)
        try await eventually("the body is pinned under the block's own name") {
            try await storage.broker.retainedRoots(scope: storage.scopes.body(mined)).count == 2
        }
        let chainBefore = try await storage.broker.retainedRoots(scope: storage.scopes.chain)

        await storage.releaseBody(mined)

        let body = await storage.volume(mined)
        XCTAssertNil(body)
        let transaction = await storage.volume(carried)
        XCTAssertNil(transaction)
        let chainAfter = try await storage.broker.retainedRoots(scope: storage.scopes.chain)
        XCTAssertEqual(chainAfter, chainBefore)
        for root in chainAfter {
            let held = await storage.volume(root)
            XCTAssertNotNil(held, root)
        }
        let account = await runtime.reads.account(owner: "nobody", blockCID: mined)
        XCTAssertNotNil(account)
        let next = try await mine(runtime)
        XCTAssertEqual(runtime.published.value?.actOnTip, next)
        await runtime.stop()
    }

    /// A transaction two bodies carry is let go of with the second.
    func testATransactionTwoBodiesCarryGoesWithTheSecond() async throws {
        let node = try host(keyByte: 0x83)
        let storage = try await NodeStorage.open(configuration: node.configuration)
        let shared = try VolumeImpl<Transaction>(node: try transaction())
        let storer = NodeImportStorage(storage: await storage.broker)
        try await shared.store(storer: storer)
        try await storer.commit()
        let (first, second) = (storage.scopes.body("first"), storage.scopes.body("second"))
        try await storage.broker.mergeRetainedRoots(scope: first, roots: [shared.rawCID])
        try await storage.broker.mergeRetainedRoots(scope: second, roots: [shared.rawCID])

        await storage.releaseBody("first")
        let stillHeld = await storage.volume(shared.rawCID)
        XCTAssertNotNil(stillHeld)
        await storage.releaseBody("second")
        let gone = await storage.volume(shared.rawCID)
        XCTAssertNil(gone)
    }
}
