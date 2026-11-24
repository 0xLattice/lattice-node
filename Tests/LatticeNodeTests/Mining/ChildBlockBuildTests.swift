import Foundation
import Ivy
import Lattice
import XCTest
import cashew
@testable import LatticeNode
import LatticeNodeAPI
import LatticeCtlCore

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
        let node = try testNode(keyByte: UInt8(keyByte, radix: 16)!, peers: peers) {
            try NodeConfiguration(
                chainPath: ["Nexus"], storagePath: $0.storagePath, privateKeyHex: $0.privateKeyHex,
                listenPort: $0.listenPort, rpcPort: $0.rpcPort,
                hostedChildren: hostsAlpha ? [Self.alpha] : [],
                childSpecs: hostsAlpha ? [Self.alpha: Self.alphaSpec] : [:],
                childPremineRecipients: alphaPremineTo.map { [Self.alpha: $0] } ?? [:]
            )
        }
        return (node.configuration, node.overlay, node.endpoint)
    }

    private func start(_ configuration: NodeConfiguration, _ overlay: IvyConfig) async throws -> (NodeRuntime, NodeStorage) {
        let storage = try await NodeStorage.openWhenFree(configuration: configuration)
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
        let held = await storage.stores.anyChain.fetchDataLocal(cid: built.blockCID)
        XCTAssertNotNil(held, "the block's body is stored")
        let retained = try await storage.broker(at: Self.alpha).retainedRoots(scope: storage.scopes.body(built.blockCID, at: Self.alpha))
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

    /// The loop's step: any push answer but `dropped` means a weighed carrier
    /// commits the block (whatever was committed since, a reorg the
    /// committers index still spans), so it waits; dropped on the built P,
    /// it resends a commit the pool has not taken and never builds again;
    /// dropped on another P (a reorg past its carrier too), it builds.
    func testTheCommitStepDecidesFromThePushAndTheChain() throws {
        let submit = SubmitChildBlockRequest(chainPath: Self.alpha, block: Data(), children: Data())
        let built = BuildChildBlockResponse(blockCID: "c1", parentState: "p1", previous: "c0@p0", submit: submit)
        let onP1 = ChildCommitmentResponse(parentState: "p1", value: "c0@p0")
        let onP2 = ChildCommitmentResponse(parentState: "p2", value: "x@p1")
        XCTAssertEqual(ChildCommitStep(pushed: nil, read: nil, built: nil, accepted: false), .read)
        XCTAssertEqual(ChildCommitStep(pushed: nil, read: onP1, built: nil, accepted: false), .build)
        XCTAssertEqual(ChildCommitStep(pushed: .tree, read: nil, built: built, accepted: true), .done)
        for carried in [SubmitChildBlockStatus.pending, .awaiting] {
            XCTAssertEqual(ChildCommitStep(pushed: carried, read: nil, built: built, accepted: true), .wait, "carried")
            XCTAssertEqual(ChildCommitStep(pushed: carried, read: onP2, built: built, accepted: false), .wait, "overwritten since")
        }
        XCTAssertEqual(ChildCommitStep(pushed: .dropped, read: nil, built: built, accepted: true), .read)
        XCTAssertEqual(ChildCommitStep(pushed: .dropped, read: onP1, built: built, accepted: true), .wait, "commit pending")
        XCTAssertEqual(ChildCommitStep(pushed: .dropped, read: onP1, built: built, accepted: false), .commit, "not taken: resend")
        XCTAssertEqual(ChildCommitStep(pushed: .dropped, read: onP2, built: built, accepted: true), .build, "tip moved or reorged")
        let landedSincePush = ChildCommitmentResponse(parentState: "p2", value: "c1@p1")
        XCTAssertEqual(ChildCommitStep(pushed: .dropped, read: landedSincePush, built: built, accepted: true), .wait, "carried since the push")
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
        let fetcher = pair.builderStorage.workFetcher(.anyChain)
        let carried = try await template.block.orderedTransactions(fetcher: fetcher)
        XCTAssertTrue(carried.isEmpty, "the hosting node's template leaves the commit out")
        let own = template.block.children.node?[Self.alpha[1]]?.rawCID
        XCTAssertNotNil(own)
        XCTAssertNotEqual(own, built.blockCID)
        let mined = try await pair.builder.mine(template)
        let minedCarried = try await mined.orderedTransactions(fetcher: fetcher)
        XCTAssertTrue(minedCarried.isEmpty, "and so does the block it mines")
    }

    /// Genesis, then an existing chain, then a pending child transaction,
    /// each built on the node hosting Alpha, committed there (it pools and
    /// relays the commit), mined into Nexus by a miner that does not host
    /// Alpha, and pushed until weighed, by `lattice child commit`'s loop. In
    /// the third round Nexus's tip moves between the build and the commit
    /// being mined: the push is dropped, the build again enters another
    /// state, its commit is resent until taken, and it lands. In the last,
    /// another author's commit replaces ours once it is carried: the loop
    /// never commits again, and ours is weighed.
    func testAParentMinerCarriesCommittedChildBlocksFromGenesisOn() async throws {
        let pair = try await pair(("7b", "7c"))
        let (builder, miner) = (pair.builder, pair.miner)
        let alphaReads = try XCTUnwrap(builder.levelReads[Self.alpha])

        /// `lattice child commit`'s loop on the runtimes, each round decided
        /// by `ChildCommitStep`. A taken commit is mined once the miner pools
        /// it. `staleTip`: the first commit's tip is mined past by a template
        /// taken before it (and the next round runs without waiting for the
        /// stale commit's eviction). `overwritten`: after the carrier, another
        /// author's commit replaces `child/Alpha` before any round runs.
        /// Returns every block the loop built and the one weighed.
        enum Twist { case none, staleTip, overwritten }
        func commitUntilWeighed(_ label: String, _ twist: Twist = .none) async throws -> (builds: [BuildChildBlockResponse], weighed: BuildChildBlockResponse) {
            var builds: [BuildChildBlockResponse] = []
            var built: BuildChildBlockResponse?
            var accepted = false
            var taken: String?
            let past = twist == .staleTip ? try await miner.miningTemplate(pair.mining) : nil
            // As the CLI's loop does, a refused commit is left unaccepted and
            // sent again by a later round. The pool judges it on its own tip,
            // which can trail by a step the executed tip the block was built
            // on (it first reads the entered blocks' transactions), so a
            // commit sent right after a tip move can be refused once.
            func commit(_ block: BuildChildBlockResponse) async throws {
                let transaction = try await pair.commit(block)
                let request = SubmitTransactionRequest(transaction: transaction)
                guard let response = try? await builder.submitTransaction(request) else { return }
                let cid = response.transactionCID
                (taken, accepted) = (cid, true)
            }
            // The miner hosts only Nexus, so its template's targets leave
            // Alpha's out; Alpha's grows harder each round, and a carrier
            // that misses it adds no work to ours, which then waits for good.
            func carry() async throws {
                let ours = try XCTUnwrap(Block(data: try XCTUnwrap(built).submit.block))
                _ = try await miner.mine(try await miner.miningTemplate(pair.mining), meeting: ours.target)
            }
            func round() async throws -> ChildCommitStep {
                var pushed: SubmitChildBlockStatus?
                if let built { pushed = try await builder.submitChildBlock(built.submit).status }
                var step = ChildCommitStep(pushed: pushed, read: nil, built: built, accepted: accepted)
                if step == .read {
                    let read = try await builder.childCommitment(chainPath: Self.alpha)
                    step = ChildCommitStep(pushed: pushed, read: read, built: built, accepted: accepted)
                }
                switch step {
                case .done, .wait, .read:
                    break
                case .commit:
                    if let built { try await commit(built) }
                case .build:
                    let next = try await builder.buildChildBlock(pair.build)
                    (built, accepted) = (next, false)
                    builds.append(next)
                    try await commit(next)
                }
                return step
            }
            func pooled(_ cid: String) async -> Bool {
                await miner.reads.explorerMempool().transactions.contains(cid)
            }
            func value(_ block: BuildChildBlockResponse) -> String { block.blockCID + "@" + block.parentState }

            // Each scenario starts from a builder in step with the miner: a
            // block of the last one still arriving would move P under the
            // first build, and the loop would rightly build again.
            try await eventually("\(label): the builder follows the miner") {
                let tip = await miner.reads.readSnapshot().tipCID
                let followed = await builder.reads.readSnapshot().tipCID
                return tip != nil && followed == tip
            }
            try await eventually("\(label): the first round's commit is taken") {
                _ = try await round()
                return taken != nil
            }
            XCTAssertEqual(builds.count, 1, "\(label): the first round builds")
            let first = try XCTUnwrap(taken)
            try await eventually("\(label): the miner pools the relayed commit") { await pooled(first) }
            for _ in 0..<3 { _ = try await round() }
            XCTAssertEqual(builds.count, 1, "\(label): rounds on one P build (and retain) one block")
            var mined: String? = first
            switch twist {
            case .staleTip:
                // The stale commit is mined past, never mined for: until the
                // miner evicts it, mining a block for it would move the tip
                // a second time (it can no longer be carried).
                _ = try await miner.mine(try XCTUnwrap(past))
            case .none:
                try await carry()
            case .overwritten:
                try await carry()
                let ours = try XCTUnwrap(built)
                try await eventually("\(label): ours is carried") {
                    try await builder.childCommitment(chainPath: Self.alpha).value == value(ours)
                }
                let theirs = try await builder.buildChildBlock(pair.build)
                var cid: String?
                try await eventually("\(label): their commit is taken") {
                    let transaction = try await pair.commit(theirs)
                    cid = try? await builder.submitTransaction(SubmitTransactionRequest(transaction: transaction)).transactionCID
                    return cid != nil
                }
                try await eventually("\(label): the miner pools their commit") { await pooled(try XCTUnwrap(cid)) }
                _ = try await miner.mineBlock(pair.mining)
                try await eventually("\(label): theirs replaces ours") {
                    try await builder.childCommitment(chainPath: Self.alpha).value == value(theirs)
                }
            }
            try await eventually("\(label): the pushed block is weighed") {
                let step = try? await round()
                if let taken, taken != mined, await pooled(taken) {
                    mined = taken
                    try await carry()
                }
                return step == .done
            }
            XCTAssertEqual(builds.count, twist == .staleTip ? 2 : 1, "\(label): one build per P the tip entered, none once carried")
            let weighed = try XCTUnwrap(built)
            if twist != .overwritten {
                try await eventually("\(label): Alpha executes it") {
                    await alphaReads.readSnapshot().tipCID == weighed.blockCID
                }
            }
            return (builds, weighed)
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
        let (builds, carrying) = try await commitUntilWeighed("pending child transaction, tip moved", .staleTip)
        let stale = builds[0]
        XCTAssertNotEqual(stale.parentState, carrying.parentState, "built again on the moved tip")
        XCTAssertNotEqual(stale.blockCID, carrying.blockCID)
        XCTAssertEqual(carrying.previous, next.blockCID + "@" + next.parentState)
        let landed = await alphaReads.explorerTransaction(cid: transferCID)?.blockHash
        XCTAssertEqual(landed, carrying.blockCID, "the pending transfer lands in the weighed C")
        let paid = await alphaReads.account(owner: bob, blockCID: carrying.blockCID)?.balance
        XCTAssertEqual(paid, 2)

        let carried = try await commitUntilWeighed("overwritten after carried", .overwritten).weighed
        XCTAssertEqual(carried.previous, carrying.blockCID + "@" + carrying.parentState)
    }
}

extension ChildBlockBuildTests {
    /// A child genesis mined elsewhere: built on the parent's state P,
    /// carried by a parent block entering P that no node ever weighs, the
    /// parent then moving past P. Pushed with the proof a synced header would
    /// carry, it is weighed, executed, synced by a peer with that proof, and
    /// extended by the node's own template; pushed without proofs it is
    /// dropped as before; a proof that does not verify is refused.
    func testAChildBlockPushedWithItsProofsIsTakenAsASyncedHeader() async throws {
        let alice = CryptoUtils.generateKeyPair()
        let aliceAddress = CryptoUtils.createAddress(from: alice.publicKey)
        let (configuration, overlay, endpoint) = try host("8a", hostsAlpha: true, alphaPremineTo: aliceAddress)
        let (node, storage) = try await start(configuration, overlay)
        let alphaReads = try XCTUnwrap(node.levelReads[Self.alpha])
        // Nexus blocks pay a miner, so each moves Nexus's state.
        let miner = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
        let leaveAlphaOut = MiningTemplateRequest(
            recipients: [MiningRecipient(chainPath: ["Nexus"], address: miner)], exclude: [Self.alpha]
        )
        _ = try await node.mineBlock(leaveAlphaOut)

        // G on P, by the node's own builder.
        let built = try await node.buildChildBlock(BuildChildBlockRequest(chainPath: Self.alpha, recipient: aliceAddress))
        let genesis = try XCTUnwrap(Block(data: built.submit.block))
        XCTAssertNil(genesis.parent)

        // A carrier: a parent block entering `state` whose only child is G,
        // ground to G's target and never submitted. Its proof is the one a
        // peer would send with G.
        let fetcher = storage.workFetcher(.anyChain)
        func carrier(enteredBy template: MiningTemplateResponse) throws -> Block {
            let block = template.block
            let children = try HeaderImpl<FlatDictionary<BlockHeader>>(
                node: FlatDictionary([Self.alpha[1]: try BlockHeader(node: genesis)])
            )
            var nonce: UInt64 = 0
            func carrying(_ nonce: UInt64) -> Block {
                Block(
                    version: block.version, parent: block.parent, transactions: block.transactions,
                    target: block.target, nextTarget: block.nextTarget, spec: block.spec,
                    parentState: block.parentState, prevState: block.prevState, postState: block.postState,
                    children: children, height: block.height, timestamp: block.timestamp,
                    rewardRecipient: block.rewardRecipient, nonce: nonce
                )
            }
            while carrying(nonce).proofOfWorkHash() > genesis.target { nonce += 1 }
            return carrying(nonce)
        }
        func proof(from carrier: Block) async throws -> Data {
            try await ChildBlockProof.generate(
                rootHeader: try BlockHeader(node: carrier), childDirectory: Self.alpha[1], fetcher: fetcher
            ).serialize()
        }
        let onP = try await node.miningTemplate(leaveAlphaOut)
        XCTAssertEqual(onP.block.prevState.rawCID, built.parentState, "the carrier enters P")
        let good = try carrier(enteredBy: onP)
        let goodProof = try await proof(from: good)

        // The parent moves past P without carrying G.
        _ = try await node.mineBlock(leaveAlphaOut)
        let moved = try await Self.tipState(node.reads)
        XCTAssertNotEqual(moved, built.parentState)

        func push(_ proofs: [Data]?) async throws -> SubmitChildBlockResponse {
            let submit = built.submit
            return try await node.submitChildBlock(SubmitChildBlockRequest(
                chainPath: submit.chainPath, block: submit.block, children: submit.children, spec: submit.spec, proofs: proofs
            ))
        }
        // (c) Refused: a carrier entering another state than G's P, and
        // bytes that are no proof.
        let offState = try await proof(from: try carrier(enteredBy: try await node.miningTemplate(leaveAlphaOut)))
        do {
            _ = try await push([offState])
            XCTFail("a proof from a carrier not entering P is refused")
        } catch NodeAPIError.invalidChildProof {}
        do {
            _ = try await push([Data([1, 2, 3])])
            XCTFail("bytes that are no proof are refused")
        } catch NodeAPIError.malformedBlock {}
        do {
            _ = try await push(Array(repeating: offState, count: 9))
            XCTFail("more proofs than a synced header's are taken is refused")
        } catch NodeAPIError.invalidChildProof {}
        do {
            _ = try await node.submitChildBlock(SubmitChildBlockRequest(
                chainPath: ["Nexus", "Unhosted"], block: built.submit.block, children: built.submit.children, spec: built.submit.spec, proofs: [offState]
            ))
            XCTFail("an unhosted chain is unknown, whatever its proofs")
        } catch NodeRuntimeError.unknownChain {}
        // (b) Without proofs, as before: no weighed parent block commits it.
        let bare = try await push(nil)
        XCTAssertEqual(bare.status, .dropped)
        XCTAssertEqual(bare.blockCID, built.blockCID)

        // (a) With its proof: checked, weighed, executed.
        let first = try await push([goodProof])
        XCTAssertNotEqual(first.status, .dropped, "taken to wait for its proof's check")
        try await eventually("G is weighed") { try await push([goodProof]).status == .tree }
        try await eventually("Alpha executes G") { await alphaReads.readSnapshot().tipCID == built.blockCID }
        let premined = await alphaReads.account(owner: aliceAddress, blockCID: built.blockCID)?.balance
        XCTAssertEqual(premined, Self.alphaSpec.premineAmount())

        // A peer syncs G with its saved proof.
        let (followerConfiguration, followerOverlay, _) = try host("8b", hostsAlpha: true, peers: [endpoint])
        let (follower, _) = try await start(followerConfiguration, followerOverlay)
        let followerAlpha = try XCTUnwrap(follower.levelReads[Self.alpha])
        try await eventually("the peer executes G") { await followerAlpha.readSnapshot().tipCID == built.blockCID }

        // Block 1 on G, from the node's own template.
        try await eventually("the node mines Alpha's block 1") {
            _ = try await node.mineBlock(MiningTemplateRequest(recipients: leaveAlphaOut.recipients))
            return await alphaReads.readSnapshot().tipCID != built.blockCID
        }
        var cid = await alphaReads.readSnapshot().tipCID
        var held = await alphaReads.blockNode(cid: try XCTUnwrap(cid))
        while let block = held, block.height > 1 {
            cid = block.parent?.rawCID
            held = await alphaReads.blockNode(cid: try XCTUnwrap(cid))
        }
        let block = try XCTUnwrap(held)
        XCTAssertEqual(block.height, 1)
        XCTAssertEqual(block.parent?.rawCID, built.blockCID, "block 1 extends G")

        if let out = ProcessInfo.processInfo.environment["LATTICE_PROOF_VECTOR"] {
            try Self.writeVector(
                to: out, built: built, genesis: genesis, carrier: good, proof: goodProof,
                premineTo: aliceAddress, request: SubmitChildBlockRequest(
                    chainPath: built.submit.chainPath, block: built.submit.block, children: built.submit.children,
                    spec: built.submit.spec, proofs: [goodProof]
                )
            )
        }
    }

    /// The inputs and bytes of a pushed genesis and its proof, for a builder
    /// outside this repository to check its own bytes against.
    private static func writeVector(
        to path: String, built: BuildChildBlockResponse, genesis: Block, carrier: Block, proof: Data,
        premineTo: String, request: SubmitChildBlockRequest
    ) throws {
        let decoded = try XCTUnwrap(ChildBlockProof.deserialize(proof))
        let json = JSONEncoder()
        json.outputFormatting = [.sortedKeys]
        func object<T: Encodable>(_ value: T) throws -> Any {
            try JSONSerialization.jsonObject(with: try json.encode(value), options: [.fragmentsAllowed])
        }
        func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
        let carrierBytes = try XCTUnwrap(carrier.toData())
        let carrierChildren = try XCTUnwrap(carrier.children.node?.toData())
        let vector: [String: Any] = [
            "about": "A child genesis built by lattice-node's buildChildBlock, a carrier (a parent block entering the genesis's parentState whose children index holds only the genesis, never weighed), and the ChildBlockProof the node generates for it (ChildBlockProof.generate(rootHeader: carrier, childDirectory:), serialize()). POST /child-blocks takes `request`; each `proofs` element is base64 of the proof's serialize() bytes, as one element of the sync wire's WireHeaderEntry.proofs.",
            "chainPath": built.submit.chainPath,
            "childDirectory": built.submit.chainPath.last ?? "",
            "spec": try object(alphaSpec),
            "specBytesBase64": built.submit.spec?.base64EncodedString() ?? "",
            "specCID": genesis.spec.rawCID,
            "premineTo": premineTo,
            "parentStateCID": built.parentState,
            "genesis": [
                "cid": built.blockCID,
                "fields": try object(genesis),
                "timestamp": genesis.timestamp,
                "nonce": genesis.nonce,
                "bytesBase64": built.submit.block.base64EncodedString(),
                "childrenBytesBase64": built.submit.children.base64EncodedString(),
            ] as [String: Any],
            "carrier": [
                "cid": try BlockHeader(node: carrier).rawCID,
                "fields": try object(carrier),
                "timestamp": carrier.timestamp,
                "nonce": carrier.nonce,
                "prevStateCID": carrier.prevState.rawCID,
                "bytesBase64": carrierBytes.base64EncodedString(),
                "bytesHex": hex(carrierBytes),
                "childrenBytesBase64": carrierChildren.base64EncodedString(),
                "childrenCID": carrier.children.rawCID,
            ] as [String: Any],
            "proof": [
                "base64": proof.base64EncodedString(),
                "hex": hex(proof),
                "rootCID": decoded.rootCID,
                "directoryPath": decoded.directoryPath,
                "entries": decoded.entries.map { ["cid": $0.cid, "dataBase64": $0.data.base64EncodedString()] },
            ] as [String: Any],
            "request": try object(request),
        ]
        let data = try JSONSerialization.data(withJSONObject: vector, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path))
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
