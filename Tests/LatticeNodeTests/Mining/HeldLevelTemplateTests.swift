import Foundation
import Ivy
import Lattice
@testable import LatticeNodeCore
import LatticeNodeAPI
import XCTest
import cashew
@testable import LatticeNode

/// The runtime's wiring of `ChainCore.holdsBacklog`, through the real worker
/// pool with a level's connects held (`NodeRuntime.start`'s `observeJob`): a
/// synced root executing one arriving block keeps answering templates, a
/// root holding a backlog refuses them (503 "executing"), and a child
/// holding one is left out of the root's template and of its own build
/// (and its directory still carries no foreign `child/X` commitment).
final class HeldLevelTemplateTests: XCTestCase {
    private static let nexus: ChainPath = ["Nexus"]
    private static let alpha: ChainPath = ["Nexus", "Alpha"]

    /// Connects at one level, held while `holding`: the n-th to reach the
    /// gate passes once `step` has been called n times, or on `release`.
    private actor Gate {
        private(set) var holding = false
        private(set) var held = 0
        private var steps = 0

        func hold() { holding = true }
        func release() { holding = false }
        /// Lets one more held connect through.
        func step() { steps += 1 }
        /// Awaited on the connect's worker: waits while held.
        func pass() async {
            guard holding else { return }
            held += 1
            let turn = held
            while holding && steps < turn { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
    }

    /// The observer that holds `path`'s connects at `gate`.
    private static func holding(_ path: ChainPath, at gate: Gate) -> NodeRuntime.JobObserver {
        { kind, at, _ in if kind == .connect, at == path { await gate.pass() } }
    }

    private func node(
        keyByte: UInt8,
        peers: [PeerEndpoint] = [],
        hosting alpha: Bool = false,
        creator: Bool = true,
        coreConfig: ChainCoreConfig = ChainCoreConfig(),
        connectBatch: Int = NodeConfiguration.defaultConnectBatch,
        observe: NodeRuntime.JobObserver? = nil
    ) async throws -> (runtime: NodeRuntime, endpoint: PeerEndpoint, storage: NodeStorage) {
        let port = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: Self.nexus, storagePath: temporaryDirectory(),
            privateKeyHex: String(repeating: String(format: "%02x", keyByte), count: 32),
            listenPort: port, rpcPort: NetworkTransportTestPorts.allocate(),
            hostedChildren: alpha ? [Self.alpha] : [],
            childSpecs: alpha && creator ? [Self.alpha: MergedMiningTests.alphaSpec] : [:],
            connectBatch: connectBatch
        )
        let storage = try await NodeStorage.open(configuration: configuration)
        let runtime = try await NodeRuntime.start(
            storage: storage,
            configuration: configuration,
            overlay: IvyConfig(
                signingKey: configuration.signingKey, listenPort: port, bootstrapPeers: peers,
                requestTimeout: .seconds(5), stunServers: [], healthConfig: PeerHealthConfig(enabled: false),
                mode: .overlay
            ),
            coreConfig: coreConfig,
            workers: 2,
            observeJob: observe
        )
        addTeardownBlock { await runtime.stop() }
        return (runtime, PeerEndpoint(publicKey: configuration.processPublicKey, host: "127.0.0.1", port: port), storage)
    }

    /// Whether `path` on `runtime` has the body of the best chain's block at
    /// `height` and has weighed headers up to `best`.
    private static func holds(
        _ runtime: NodeRuntime, _ path: ChainPath, height: UInt64, best: UInt64
    ) async -> Bool {
        await LiveLevels(inputs: runtime.inputs).read { levels -> Bool in
            guard let level = levels[path], level.snapshot.bestHeaderHeight == best,
                  let cid = level.tree.canonicalBlockHash(atHeight: height) else { return false }
            return level.bodies.arrived.contains(cid)
        } == true
    }

    /// A synced node receives one block and executes it: its root stays
    /// mined. A request made during the connect is answered on the tip it
    /// is leaving, as the status names it, and a miner following the node's
    /// pushes is never refused and is then given the new tip's template.
    func testASyncedRootExecutingOneArrivingBlockKeepsAnsweringTemplates() async throws {
        let miner = try await node(keyByte: 0x81)
        for _ in 0..<2 { _ = try await miner.runtime.mineBlock() }
        let gate = Gate()
        let follower = try await node(keyByte: 0x82, peers: [miner.endpoint], observe: Self.holding(Self.nexus, at: gate))
        try await eventually("the follower is synced") { follower.runtime.published.value?.actOnHeight == 2 }

        // A miner following pushes: each digest is fetched at once.
        actor Seen {
            var templates: [MiningTemplateResponse] = []
            var refusals: [String] = []
            func add(_ template: MiningTemplateResponse) { templates.append(template) }
            func refuse(_ error: any Error) { refusals.append("\(error)") }
        }
        let seen = Seen()
        let events = follower.runtime.miningEvents()
        let following = Task {
            for await _ in events {
                do { await seen.add(try await follower.runtime.miningTemplate(MiningTemplateRequest())) }
                catch { await seen.refuse(error) }
            }
        }
        defer { following.cancel() }

        await gate.hold()
        _ = try await miner.runtime.mineBlock()
        try await eventually("the follower executes block 3 (held)") { await gate.held == 1 }
        let during = try await follower.runtime.miningTemplate(MiningTemplateRequest())
        XCTAssertEqual(during.block.height, 3, "built on the tip it is leaving, as main does")
        let status = await follower.runtime.status().templateDigest
        XCTAssertEqual(during.templateDigest, status, "the answer is the status's template")
        await gate.release()

        try await eventually("the follower fetched the new tip's template") {
            await seen.templates.last?.block.height == 4
        }
        let refusals = await seen.refusals
        XCTAssertEqual(refusals, [], "a miner following pushes is never refused")
    }

    /// A syncing root holds a backlog (the next two blocks' bodies): it
    /// refuses templates (503 "executing") until it has executed it.
    func testASyncingRootHoldingABacklogRefusesTemplates() async throws {
        let miner = try await node(keyByte: 0x83)
        for _ in 0..<4 { _ = try await miner.runtime.mineBlock() }
        let gate = Gate()
        await gate.hold()
        let follower = try await node(keyByte: 0x84, peers: [miner.endpoint], observe: Self.holding(Self.nexus, at: gate))
        try await eventually("block 1's connect is held with block 2's body here") {
            guard await gate.held == 1 else { return false }
            return await Self.holds(follower.runtime, Self.nexus, height: 2, best: 4)
        }
        do {
            _ = try await follower.runtime.miningTemplate(MiningTemplateRequest())
            XCTFail("a root holding a backlog has no template")
        } catch {
            XCTAssertEqual(error as? TemplateError, .executing)
        }
        await gate.release()
        try await eventually("the follower is synced") { follower.runtime.published.value?.actOnHeight == 4 }
        let template = try await follower.runtime.miningTemplate(MiningTemplateRequest())
        XCTAssertEqual(template.block.height, 5)
    }

    /// A root's digest names no tip while it holds a backlog: it changes
    /// when the backlog arrives (the tip unmoved), stays the same while
    /// the root executes it, and changes again once the root is mined.
    func testARootHoldingABacklogKeepsOneDigestUntilItIsMinedAgain() async throws {
        let miner = try await node(keyByte: 0x87)
        for _ in 0..<2 { _ = try await miner.runtime.mineBlock() }
        let gate = Gate()
        // One block per connect job, so each step executes one block of the
        // backlog: batched, blocks 4-6 would connect in one step.
        let follower = try await node(
            keyByte: 0x88, peers: [miner.endpoint], connectBatch: 1, observe: Self.holding(Self.nexus, at: gate)
        )
        try await eventually("the follower is synced") { follower.runtime.published.value?.actOnHeight == 2 }
        let synced = await follower.runtime.status().templateDigest

        await gate.hold()
        for _ in 0..<4 { _ = try await miner.runtime.mineBlock() }
        try await eventually("block 3's connect is held with the bodies of blocks 3-6 here") {
            guard await gate.held == 1 else { return false }
            for height in UInt64(3)...6 where !(await Self.holds(follower.runtime, Self.nexus, height: height, best: 6)) {
                return false
            }
            return true
        }
        let held = await follower.runtime.status().templateDigest
        XCTAssertNotNil(held)
        XCTAssertNotEqual(held, synced, "a backlog arriving changes the digest, the tip unmoved")
        for height in UInt64(3)...4 {
            await gate.step()
            try await eventually("the follower executes block \(height)") {
                follower.runtime.published.value?.actOnHeight == height
            }
            let digest = await follower.runtime.status().templateDigest
            XCTAssertEqual(digest, held, "the digest names no tip while the root holds a backlog (tip \(height))")
        }
        await gate.release()
        try await eventually("the follower is synced") { follower.runtime.published.value?.actOnHeight == 6 }
        let mined = await follower.runtime.status().templateDigest
        XCTAssertNotEqual(mined, held, "mined again, the digest names its tip")
    }

    /// A child holding a backlog is left out of the root's template, which
    /// the status names, and its own build is refused, until it has
    /// executed it.
    func testAChildHoldingABacklogIsLeftOutOfTheRootTemplateAndItsBuild() async throws {
        let payer = CryptoUtils.generateKeyPair()
        let payerAddress = CryptoUtils.createAddress(from: payer.publicKey)
        let paying = MiningTemplateRequest(recipients: [MiningRecipient(chainPath: Self.nexus, address: payerAddress)])
        let miner = try await node(keyByte: 0x85, hosting: true)
        let minerAlpha = try XCTUnwrap(miner.runtime.levelReads[Self.alpha])
        // Nexus blocks 1-4 carry Alpha's genesis and blocks 1-3.
        for height in 0..<4 {
            _ = try await miner.runtime.mineBlock(paying)
            try await eventually("Alpha executes its block \(height)") {
                await minerAlpha.readSnapshot().height == UInt64(height)
            }
        }
        // Alpha's genesis connects; its block 1 is held. Alpha has executed,
        // so it would be carried were it not left out.
        let gate = Gate()
        await gate.hold()
        await gate.step()
        let follower = try await node(
            keyByte: 0x86, peers: [miner.endpoint], hosting: true, creator: false,
            observe: Self.holding(Self.alpha, at: gate)
        )
        let followerAlpha = try XCTUnwrap(follower.runtime.levelReads[Self.alpha])
        try await eventually("the follower's Nexus is synced, Alpha's block 1 held with block 2's body here") {
            guard follower.runtime.published.value?.actOnHeight == 4, await gate.held == 2 else { return false }
            guard await followerAlpha.readSnapshot().tipCID != nil else { return false }
            return await Self.holds(follower.runtime, Self.alpha, height: 2, best: 3)
        }
        let alphaHeight = await followerAlpha.readSnapshot().height
        XCTAssertEqual(alphaHeight, 0, "Alpha has executed its genesis")

        // A foreign `child/Alpha` commitment, pooled on the follower.
        let commitment = try await follower.runtime.childCommitment(chainPath: Self.alpha)
        let foreign = try await follower.runtime.submitTransaction(SubmitTransactionRequest(
            transaction: try Self.commit(
                key: payer, previous: commitment.value,
                to: try XCTUnwrap(follower.runtime.published.value?.actOnTip), at: commitment.parentState
            )
        ))
        XCTAssertEqual(foreign.mempoolCount, 1, "the follower pools the commitment")

        let template = try await follower.runtime.miningTemplate(MiningTemplateRequest())
        XCTAssertEqual(template.block.height, 5, "the root is mined")
        XCTAssertNil(template.block.children.node?.entries["Alpha"], "Alpha is left out while it holds a backlog")
        let carried = try await MiningTemplateAssembly.blockTransactions(in: template.block, fetcher: follower.storage.workFetcher)
        XCTAssertTrue(carried.isEmpty, "Alpha's directory, left out, is still hosted: no foreign commitment")
        let status = await follower.runtime.status().templateDigest
        XCTAssertEqual(template.templateDigest, status)
        do {
            _ = try await follower.runtime.buildChildBlock(BuildChildBlockRequest(chainPath: Self.alpha, recipient: nil))
            XCTFail("a child holding a backlog has no block to build")
        } catch {
            XCTAssertEqual(error as? TemplateError, .executing)
        }

        await gate.release()
        try await eventually("Alpha executes its backlog") { await followerAlpha.readSnapshot().height == 3 }
        let carrying = try await follower.runtime.miningTemplate(MiningTemplateRequest())
        XCTAssertNotNil(carrying.block.children.node?.entries["Alpha"], "Alpha is carried again")
        _ = try await follower.runtime.buildChildBlock(BuildChildBlockRequest(chainPath: Self.alpha, recipient: nil))
    }

    /// A child's best header moving past its act-on tip leaves the root's
    /// digest naming only what a template is built from: the act-on tips,
    /// next blocks, and that a block of the child is weighed. Alpha asks
    /// for one body at a time and its block 1's connect is held, so it holds
    /// no backlog and is mined, while Nexus executes the blocks carrying its
    /// headers 1-3.
    func testAChildsBestHeaderPastItsActOnTipIsNotInTheDigest() async throws {
        let miner = try await node(keyByte: 0x87, hosting: true)
        let minerAlpha = try XCTUnwrap(miner.runtime.levelReads[Self.alpha])
        // Nexus blocks 1-4 carry Alpha's genesis and blocks 1-3.
        for height in 0..<4 {
            _ = try await miner.runtime.mineBlock()
            try await eventually("Alpha executes its block \(height)") {
                await minerAlpha.readSnapshot().height == UInt64(height)
            }
        }
        let gate = Gate()
        await gate.hold()
        await gate.step()
        let follower = try await node(
            keyByte: 0x88, peers: [miner.endpoint], hosting: true, creator: false,
            coreConfig: ChainCoreConfig(bodyWindow: 1), observe: Self.holding(Self.alpha, at: gate)
        )
        let levels = LiveLevels(inputs: follower.runtime.inputs)
        try await eventually("Nexus is synced, Alpha's best header at 3 with its block 1 held") {
            guard follower.runtime.published.value?.actOnHeight == 4, await gate.held == 2 else { return false }
            return await levels.read { $0[Self.alpha]?.snapshot.bestHeaderHeight } == 3
        }
        let alpha = await levels.read { levels in
            levels[Self.alpha].map { ($0.snapshot.actOnHeight, $0.holdsBacklog) }
        } ?? nil
        XCTAssertEqual(alpha?.0, 0, "Alpha has executed only its genesis")
        XCTAssertEqual(alpha?.1, false, "Alpha holds no backlog: it is mined")
        let expected = await levels.read { levels -> String? in
            guard let nexus = levels[Self.nexus], let alpha = levels[Self.alpha] else { return nil }
            return NodeRuntime.templateDigest(
                tip: nexus.snapshot.actOnTip, carrying: nexus.mining.nextBlock,
                levels: [(Self.alpha, alpha.snapshot.actOnTip, true, alpha.mining.nextBlock)]
            )
        } ?? nil
        let status = await follower.runtime.status().templateDigest
        XCTAssertEqual(status, expected, "the digest names Alpha's act-on tip, not its best header")
        let template = try await follower.runtime.miningTemplate(MiningTemplateRequest())
        XCTAssertNotNil(template.block.children.node?.entries["Alpha"], "Alpha is carried")
        XCTAssertEqual(template.templateDigest, status, "the template is the status's")
        await gate.release()
    }

    /// A `child/Alpha` commit from `key` (nonce 0, a fee of 1): `previous`
    /// replaced by `block` at `state`.
    private static func commit(
        key: (privateKey: String, publicKey: String), previous: String?, to block: String, at state: String
    ) throws -> Transaction {
        let address = CryptoUtils.createAddress(from: key.publicKey)
        let body = try HeaderImpl(node: TransactionBody(
            accountActions: [AccountAction(owner: address, delta: -1)],
            actions: [Action(
                key: CHILD_COMMITMENT_KEY_PREFIX + alpha[1], oldValue: previous,
                newValue: block + String(UnicodeScalar(CHILD_COMMITMENT_PARENT_STATE_SEPARATOR)) + state
            )],
            depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [address], nonce: 0, chainPath: nexus
        ))
        return Transaction(
            signatures: [key.publicKey: try XCTUnwrap(TransactionSigning.sign(bodyHeader: body, privateKeyHex: key.privateKey))],
            body: body
        )
    }
}
