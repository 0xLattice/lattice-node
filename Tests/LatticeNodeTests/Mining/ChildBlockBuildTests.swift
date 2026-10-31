import Foundation
import Ivy
import Lattice
import XCTest
import cashew
@testable import LatticeNode
import LatticeNodeAPI

/// `child/X` = `C@P` merged mining by a parent miner that does not host X:
/// the node hosting X builds C (`buildChildBlock`), its author commits it on
/// the parent, and pushes it until a parent block carrying it weighs it.
final class ChildBlockBuildTests: XCTestCase {
    private static let alpha = ["Nexus", "Alpha"]
    private static let alphaSpec = ChainSpec(
        maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000, premine: 10,
        targetBlockTime: 1_000, initialReward: 10, halvingInterval: 10_000, halfLife: 10
    )

    private func host(
        _ keyByte: String, hostsAlpha: Bool, alphaPremineTo: String? = nil, peers: [PeerEndpoint] = []
    ) throws -> (NodeConfiguration, IvyConfig, PeerEndpoint) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-child-build-\(UUID().uuidString)", isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let port = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"], storagePath: directory, privateKeyHex: String(repeating: keyByte, count: 32),
            listenPort: port, rpcPort: NetworkTransportTestPorts.allocate(),
            hostedChildren: hostsAlpha ? [Self.alpha] : [],
            childSpecs: hostsAlpha ? [Self.alpha: Self.alphaSpec] : [:],
            childPremineRecipients: alphaPremineTo.map { [Self.alpha: $0] } ?? [:]
        )
        let overlay = IvyConfig(
            signingKey: configuration.signingKey, listenPort: port, bootstrapPeers: peers,
            requestTimeout: .seconds(5), stunServers: [], healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        )
        return (configuration, overlay, PeerEndpoint(publicKey: configuration.processPublicKey, host: "127.0.0.1", port: port))
    }

    private func start(_ configuration: NodeConfiguration, _ overlay: IvyConfig) async throws -> (NodeRuntime, NodeStorage) {
        let storage = try await NodeStorage.open(configuration: configuration)
        let runtime = try await NodeRuntime.start(storage: storage, configuration: configuration, overlay: overlay)
        addTeardownBlock { await runtime.stop() }
        return (runtime, storage)
    }

    private static func signed(_ key: (privateKey: String, publicKey: String), _ body: TransactionBody) throws -> Transaction {
        let header = try HeaderImpl(node: body)
        return Transaction(
            signatures: [key.publicKey: try XCTUnwrap(TransactionSigning.sign(bodyHeader: header, privateKeyHex: key.privateKey))],
            body: header
        )
    }

    /// The commit-child transaction `lattice child commit` sends: `built`'s C
    /// at its P, replacing `previous`, paying a fee of 1.
    private static func commit(
        _ built: BuildChildBlockResponse, key: (privateKey: String, publicKey: String), nonce: UInt64
    ) throws -> Transaction {
        let address = CryptoUtils.createAddress(from: key.publicKey)
        return try signed(key, TransactionBody(
            accountActions: [AccountAction(owner: address, delta: -1)],
            actions: [Action(
                key: CHILD_COMMITMENT_KEY_PREFIX + alpha[1], oldValue: built.previous,
                newValue: built.blockCID + String(UnicodeScalar(CHILD_COMMITMENT_PARENT_STATE_SEPARATOR)) + built.parentState
            )],
            depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [address], nonce: nonce, chainPath: ["Nexus"]
        ))
    }

    /// The executed tip's post-state: the P a block built now enters.
    private static func tipState(_ reads: ChainReads) async throws -> String {
        let tip = await reads.readSnapshot().tipCID
        let block = await reads.blockNode(cid: try XCTUnwrap(tip))
        return try XCTUnwrap(block).postState.rawCID
    }

    /// A genesis built for its author: the spec rides with the push, P is
    /// the parent's tip state, nothing is committed there yet, and the block
    /// is stored and retained before any parent commits it.
    func testBuildingAGenesisStoresAndRetainsItForItsAuthor() async throws {
        let (configuration, overlay, _) = try host("7a", hostsAlpha: true)
        let (node, storage) = try await start(configuration, overlay)
        let recipient = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
        let built = try await node.buildChildBlock(BuildChildBlockRequest(chainPath: Self.alpha, recipient: recipient))
        let block = try XCTUnwrap(Block(data: built.submit.block))
        XCTAssertNil(block.parent, "a genesis")
        XCTAssertNotNil(built.submit.spec, "a genesis's push carries its spec")
        XCTAssertEqual(built.submit.chainPath, Self.alpha)
        XCTAssertEqual(try BlockHeader(node: block).rawCID, built.blockCID)
        let entering = try await Self.tipState(node.reads)
        XCTAssertEqual(built.parentState, entering)
        XCTAssertNil(built.previous)
        let held = await storage.broker.fetchDataLocal(cid: built.blockCID)
        XCTAssertNotNil(held, "the block's body is stored")
        let retained = try await storage.broker.retainedRoots(scope: storage.scopes.body(built.blockCID, at: Self.alpha))
        XCTAssertTrue(retained.contains(built.blockCID), "and retained")
        await XCTAssertThrowsErrorAsync(
            try await node.buildChildBlock(BuildChildBlockRequest(chainPath: ["Nexus", "Beta"]))
        )
        await XCTAssertThrowsErrorAsync(
            try await node.buildChildBlock(BuildChildBlockRequest(chainPath: ["Nexus"]))
        )
    }

    /// Genesis, then an existing chain, then a pending child transaction,
    /// each built on the node hosting Alpha, committed by a transaction
    /// submitted there (which it pools and relays, but never mines into its
    /// own template), mined into Nexus by a miner that does not host Alpha,
    /// and pushed until weighed.
    func testAParentMinerCarriesCommittedChildBlocksFromGenesisOn() async throws {
        let payer = CryptoUtils.generateKeyPair()
        let payerAddress = CryptoUtils.createAddress(from: payer.publicKey)
        let alice = CryptoUtils.generateKeyPair()
        let aliceAddress = CryptoUtils.createAddress(from: alice.publicKey)
        let (builderConfiguration, builderOverlay, builderEndpoint) = try host("7b", hostsAlpha: true, alphaPremineTo: aliceAddress)
        let (builder, _) = try await start(builderConfiguration, builderOverlay)
        let (minerConfiguration, minerOverlay, _) = try host("7c", hostsAlpha: false, peers: [builderEndpoint])
        let (miner, _) = try await start(minerConfiguration, minerOverlay)
        let alphaReads = try XCTUnwrap(builder.levelReads[Self.alpha])
        XCTAssertNil(miner.levelReads[Self.alpha], "the miner does not host Alpha")
        let mining = MiningTemplateRequest(recipients: [MiningRecipient(chainPath: ["Nexus"], address: payerAddress)])

        try await eventually("the miner and builder are connected") { miner.peerCount >= 1 && builder.peerCount >= 1 }
        try await eventually("the payer is funded") {
            _ = try await miner.mineBlock(mining)
            guard let tip = await miner.reads.readSnapshot().tipCID else { return false }
            return (await miner.reads.account(owner: payerAddress, blockCID: tip)?.balance ?? 0) >= 10
        }
        try await eventually("the builder follows the miner") {
            let tip = await miner.reads.readSnapshot().tipCID
            let followed = await builder.reads.readSnapshot().tipCID
            return tip != nil && followed == tip
        }

        /// One round: build on the builder, commit there, mine on the miner
        /// until the push answers `tree`.
        func round(_ label: String, nonce: UInt64) async throws -> BuildChildBlockResponse {
            let built = try await builder.buildChildBlock(BuildChildBlockRequest(chainPath: Self.alpha, recipient: aliceAddress))
            let entering = try await Self.tipState(miner.reads)
            XCTAssertEqual(built.parentState, entering, "\(label): built on the parent's tip state")
            _ = try await builder.submitTransaction(SubmitTransactionRequest(transaction: Self.commit(built, key: payer, nonce: nonce)))
            try await eventually("\(label): the miner pools the relayed commit") {
                await miner.reads.readSnapshot().mempoolCount == 1
            }
            _ = try await miner.mineBlock(mining)
            try await eventually("\(label): the pushed block is weighed") {
                try await builder.submitChildBlock(built.submit).status == .tree
            }
            try await eventually("\(label): Alpha executes it") {
                await alphaReads.readSnapshot().tipCID == built.blockCID
            }
            return built
        }

        let genesis = try await round("genesis", nonce: 0)
        XCTAssertNil(try XCTUnwrap(Block(data: genesis.submit.block)).parent)
        XCTAssertNil(genesis.previous)
        let premined = await alphaReads.account(owner: aliceAddress, blockCID: genesis.blockCID)?.balance
        XCTAssertEqual(premined, Self.alphaSpec.premineAmount())

        let next = try await round("existing chain", nonce: 1)
        XCTAssertEqual(try XCTUnwrap(Block(data: next.submit.block)).parent?.rawCID, genesis.blockCID, "extends Alpha's executed tip")
        XCTAssertNil(next.submit.spec)
        XCTAssertEqual(next.previous, genesis.blockCID + "@" + genesis.parentState, "the earlier commitment")

        let bob = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
        let transfer = try Self.signed(alice, TransactionBody(
            accountActions: [AccountAction(owner: aliceAddress, delta: -3), AccountAction(owner: bob, delta: 2)],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [aliceAddress], nonce: 0, chainPath: Self.alpha
        ))
        let transferCID = try await builder.submitTransaction(SubmitTransactionRequest(transaction: transfer)).transactionCID
        try await eventually("Alpha pools the transfer") { await alphaReads.readSnapshot().mempoolCount == 1 }
        let carrying = try await round("pending child transaction", nonce: 2)
        XCTAssertEqual(carrying.previous, next.blockCID + "@" + next.parentState)
        let landed = await alphaReads.explorerTransaction(cid: transferCID)?.blockHash
        XCTAssertEqual(landed, carrying.blockCID, "the pending transfer lands in the weighed C")
        let paid = await alphaReads.account(owner: bob, blockCID: carrying.blockCID)?.balance
        XCTAssertEqual(paid, 2)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("no error thrown", file: file, line: line)
    } catch {}
}
