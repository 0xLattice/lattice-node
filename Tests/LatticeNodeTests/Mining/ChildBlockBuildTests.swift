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

    /// A builder hosting Alpha (which mines nothing) and a miner hosting
    /// Nexus only, the miner's blocks paying `payer`, funded and in step.
    private struct Pair {
        let builder: NodeRuntime
        let miner: NodeRuntime
        let builderStorage: NodeStorage
        let payer: (privateKey: String, publicKey: String)
        let alice: (privateKey: String, publicKey: String)
        let mining: MiningTemplateRequest
        var aliceAddress: String { CryptoUtils.createAddress(from: alice.publicKey) }
        var payerAddress: String { CryptoUtils.createAddress(from: payer.publicKey) }
        var build: BuildChildBlockRequest { BuildChildBlockRequest(chainPath: ChildBlockBuildTests.alpha, recipient: aliceAddress) }

        /// The commit-child transaction at the payer's next nonce on the builder's tip.
        func commit(_ built: BuildChildBlockResponse) async throws -> Transaction {
            let tip = await builder.reads.readSnapshot().tipCID
            let nonce = await builder.reads.account(owner: payerAddress, blockCID: try XCTUnwrap(tip))?.nonce ?? 0
            return try ChildBlockBuildTests.commit(built, key: payer, nonce: nonce)
        }
    }

    private func pair(_ bytes: (String, String)) async throws -> Pair {
        let payer = CryptoUtils.generateKeyPair()
        let alice = CryptoUtils.generateKeyPair()
        let (builderConfiguration, builderOverlay, builderEndpoint) = try host(
            bytes.0, hostsAlpha: true, alphaPremineTo: CryptoUtils.createAddress(from: alice.publicKey)
        )
        let (builder, builderStorage) = try await start(builderConfiguration, builderOverlay)
        let (minerConfiguration, minerOverlay, _) = try host(bytes.1, hostsAlpha: false, peers: [builderEndpoint])
        let (miner, _) = try await start(minerConfiguration, minerOverlay)
        XCTAssertNil(miner.levelReads[Self.alpha], "the miner does not host Alpha")
        let payerAddress = CryptoUtils.createAddress(from: payer.publicKey)
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
        return Pair(
            builder: builder, miner: miner, builderStorage: builderStorage,
            payer: payer, alice: alice, mining: mining
        )
    }

    /// The relay rule on the production template path: a node that hosts
    /// Alpha and mines Nexus pools a valid `child/Alpha` commit and relays
    /// it, and neither the template it builds nor the block it mines from it
    /// carries the commit; Alpha's slot holds its own candidate.
    func testAHostingMinerRelaysAChildCommitButNeverMinesIt() async throws {
        let pair = try await pair(("7d", "7e"))
        let built = try await pair.builder.buildChildBlock(pair.build)
        _ = try await pair.builder.submitTransaction(SubmitTransactionRequest(transaction: try await pair.commit(built)))
        try await eventually("the peer pools the relayed commit") {
            await pair.miner.reads.readSnapshot().mempoolCount == 1
        }
        let pooled = await pair.builder.reads.readSnapshot().mempoolCount
        XCTAssertEqual(pooled, 1, "the hosting node pools the commit")
        let template = try await pair.builder.miningTemplate(pair.mining)
        let fetcher = pair.builderStorage.workFetcher
        let carried = try await MiningTemplateAssembly.blockTransactions(in: template.block, fetcher: fetcher)
        XCTAssertTrue(carried.isEmpty, "the hosting node's template leaves the commit out")
        let own = template.block.children.node?[Self.alpha[1]]?.rawCID
        XCTAssertNotNil(own)
        XCTAssertNotEqual(own, built.blockCID)
        let mined = try await pair.builder.mine(template)
        let minedCarried = try await MiningTemplateAssembly.blockTransactions(in: mined, fetcher: fetcher)
        XCTAssertTrue(minedCarried.isEmpty, "and so does the block it mines")
    }

    /// Genesis, then an existing chain, then a pending child transaction,
    /// each built on the node hosting Alpha, committed there (it pools and
    /// relays the commit), mined into Nexus by a miner that does not host
    /// Alpha, and pushed until weighed, by `lattice child commit`'s loop. In
    /// the last round Nexus's tip moves between the build and the commit
    /// being mined: the push is dropped, the build again enters another
    /// state, and that one is committed and lands.
    func testAParentMinerCarriesCommittedChildBlocksFromGenesisOn() async throws {
        let pair = try await pair(("7b", "7c"))
        let (builder, miner) = (pair.builder, pair.miner)
        let alphaReads = try XCTUnwrap(builder.levelReads[Self.alpha])

        /// `lattice child commit`'s loop on the runtimes: build, commit when
        /// the build supersedes the committed block, push; on `dropped` or an
        /// error, build again. With `stale`, the first commit's tip is mined
        /// past by a template taken before the commit, which never carries it.
        func commitUntilWeighed(_ label: String, stale: Bool = false) async throws -> (first: BuildChildBlockResponse, weighed: BuildChildBlockResponse) {
            var built = try await builder.buildChildBlock(pair.build)
            let first = built
            var past = stale ? try await miner.miningTemplate(pair.mining) : nil
            var committed: BuildChildBlockResponse?
            var rebuild = false
            try await eventually("\(label): the pushed block is weighed") {
                do {
                    if rebuild { built = try await builder.buildChildBlock(pair.build) }
                    rebuild = false
                    if built.supersedes(committed) {
                        _ = try await builder.submitTransaction(SubmitTransactionRequest(transaction: try await pair.commit(built)))
                        committed = built
                        try await eventually("\(label): the miner pools the relayed commit") {
                            await miner.reads.readSnapshot().mempoolCount == 1
                        }
                        if let template = past {
                            past = nil
                            _ = try await miner.mine(template)
                        } else {
                            _ = try await miner.mineBlock(pair.mining)
                        }
                    }
                    guard let committed else { return false }
                    let pushed = try await builder.submitChildBlock(committed.submit)
                    if pushed.status == .tree { return true }
                    rebuild = pushed.status == .dropped
                } catch {
                    rebuild = true
                }
                return false
            }
            let weighed = try XCTUnwrap(committed)
            try await eventually("\(label): Alpha executes it") {
                await alphaReads.readSnapshot().tipCID == weighed.blockCID
            }
            return (first, weighed)
        }

        let genesis = try await commitUntilWeighed("genesis").weighed
        XCTAssertNil(try XCTUnwrap(Block(data: genesis.submit.block)).parent)
        XCTAssertNil(genesis.previous)
        let premined = await alphaReads.account(owner: pair.aliceAddress, blockCID: genesis.blockCID)?.balance
        XCTAssertEqual(premined, Self.alphaSpec.premineAmount())

        let next = try await commitUntilWeighed("existing chain").weighed
        XCTAssertEqual(try XCTUnwrap(Block(data: next.submit.block)).parent?.rawCID, genesis.blockCID, "extends Alpha's executed tip")
        XCTAssertNil(next.submit.spec)
        XCTAssertEqual(next.previous, genesis.blockCID + "@" + genesis.parentState, "the earlier commitment")

        let bob = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
        let transfer = try Self.signed(pair.alice, TransactionBody(
            accountActions: [AccountAction(owner: pair.aliceAddress, delta: -3), AccountAction(owner: bob, delta: 2)],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [pair.aliceAddress], nonce: 0, chainPath: Self.alpha
        ))
        let transferCID = try await builder.submitTransaction(SubmitTransactionRequest(transaction: transfer)).transactionCID
        try await eventually("Alpha pools the transfer") { await alphaReads.readSnapshot().mempoolCount == 1 }
        let (stale, carrying) = try await commitUntilWeighed("pending child transaction, tip moved", stale: true)
        XCTAssertNotEqual(stale.parentState, carrying.parentState, "built again on the moved tip")
        XCTAssertNotEqual(stale.blockCID, carrying.blockCID)
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
