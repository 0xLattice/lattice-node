import Foundation
import Ivy
import Lattice
import LatticeNodeCore
import UInt256
import XCTest
import cashew
@testable import LatticeNode

/// Merged mining on the node runtime: a node hosting Nexus and one child
/// chain mines templates that carry the child's block, and one grind
/// advances every chain whose target it meets. Nexus's target is its real,
/// scheduled one, never the maximum.
final class MergedMiningTests: XCTestCase {
    static let alpha = ["Nexus", "Alpha"]
    static let alphaSpec = ChainSpec(
        maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000, premine: 0,
        targetBlockTime: 1_000, initialReward: 10, halvingInterval: 10_000, halfLife: 10
    )

    func testOneGrindAdvancesNexusAndItsHostedChild() async throws {
        let storageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-merged-\(UUID().uuidString)", isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storageDirectory) }
        let port = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"], storagePath: storageDirectory,
            privateKeyHex: String(repeating: "4d", count: 32),
            listenPort: port, rpcPort: NetworkTransportTestPorts.allocate(),
            hostedChildren: [Self.alpha], childSpecs: [Self.alpha: Self.alphaSpec]
        )
        let overlay = IvyConfig(
            signingKey: configuration.signingKey, listenPort: port, bootstrapPeers: [],
            requestTimeout: .seconds(5), stunServers: [], healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        )
        let alphaHeight = try await mineFirstRun(configuration, overlay)

        // A restart serves Alpha's headers with their proofs at once, and
        // resumes both chains where they were.
        let storedProofs = try HeaderContentStore(directory: storageDirectory).proofs()
        XCTAssertFalse((storedProofs[Self.alpha] ?? [:]).isEmpty, "Alpha's credited proofs survive the restart")
        let reopened = try await NodeStorage.open(configuration: configuration)
        let restarted = try await NodeRuntime.start(storage: reopened, configuration: configuration, overlay: overlay)
        // A block weighed before the stop may execute only now: never lower.
        let resumed = await restarted.levelReads[Self.alpha]?.readSnapshot().height ?? 0
        XCTAssertGreaterThanOrEqual(resumed, alphaHeight)
        _ = try await restarted.mineBlock()
        try await eventually("Alpha advances after the restart") {
            (await restarted.levelReads[Self.alpha]?.readSnapshot().height ?? 0) > resumed
        }
        await restarted.stop()
    }

    /// A nested child (Nexus/Alpha/Beta) created with its parent: its
    /// genesis waits until Alpha executes a block, then both advance by
    /// merged mining.
    func testANestedChildGenesisIsMinedOnceItsParentExecutes() async throws {
        let beta = Self.alpha + ["Beta"]
        let storageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-nested-\(UUID().uuidString)", isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storageDirectory) }
        let port = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"], storagePath: storageDirectory, privateKeyHex: String(repeating: "4e", count: 32),
            listenPort: port, rpcPort: NetworkTransportTestPorts.allocate(),
            hostedChildren: [Self.alpha, beta], childSpecs: [Self.alpha: Self.alphaSpec, beta: Self.alphaSpec]
        )
        let overlay = IvyConfig(
            signingKey: configuration.signingKey, listenPort: port, bootstrapPeers: [],
            requestTimeout: .seconds(5), stunServers: [], healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        )
        let storage = try await NodeStorage.open(configuration: configuration)
        let runtime = try await NodeRuntime.start(storage: storage, configuration: configuration, overlay: overlay)
        let betaReads = try XCTUnwrap(runtime.levelReads[beta])
        try await eventually("Beta's genesis is mined after Alpha executes") {
            // Alpha pays a recipient, so its states change: Beta's genesis
            // must commit a non-empty parent state.
            _ = try await runtime.mineBlock(MiningTemplateRequest(recipients: [
                MiningRecipient(chainPath: Self.alpha, address: CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)),
            ]))
            return (await betaReads.readSnapshot().height ?? 0) >= 1
        }
        await runtime.stop()
    }

    /// The first run: Nexus hardens, Alpha advances by merged grinds and by
    /// a share, and a transaction to Alpha is mined. Returns Alpha's height;
    /// the storage closes on return.
    private func mineFirstRun(_ configuration: NodeConfiguration, _ overlay: IvyConfig) async throws -> UInt64 {
        let storage = try await NodeStorage.open(configuration: configuration)
        let runtime = try await NodeRuntime.start(storage: storage, configuration: configuration, overlay: overlay)
        let alphaReads = try XCTUnwrap(runtime.levelReads[Self.alpha])

        let first = try await runtime.miningTemplate(MiningTemplateRequest())
        XCTAssertNotNil(first.block.children.node?.entries["Alpha"], "the template carries Alpha's genesis")
        let initialStatusDigest = await runtime.status().templateDigest
        XCTAssertEqual(first.templateDigest, initialStatusDigest)

        // Fast blocks harden Nexus's scheduled target below the maximum.
        var template = first
        var mined = 0
        while template.block.target == UInt256.max, mined < 64 {
            _ = try await runtime.mineBlock()
            mined += 1
            try await eventually("block \(mined) executes") { runtime.published.value?.actOnHeight == UInt64(mined) }
            template = try await runtime.miningTemplate(MiningTemplateRequest())
        }
        XCTAssertLessThan(template.block.target, UInt256.max, "Nexus mines at a hard scheduled target")
        try await eventually("Alpha advanced with the Nexus blocks that carried it") {
            (await alphaReads.readSnapshot().height ?? 0) >= 1
        }

        // A grind that meets Alpha's target but misses Nexus's weighs only
        // Alpha; one that meets Nexus's advances both.
        let alphaBefore = await alphaReads.readSnapshot().height ?? 0
        let nexusBefore = runtime.published.value?.actOnHeight ?? 0
        let carried = try XCTUnwrap(template.block.children.node?.entries["Alpha"]?.node)
        var nonce: UInt64 = 0
        while true {
            let hash = template.block.replacingNonce(nonce).proofOfWorkHash()
            if hash > template.block.target, hash <= carried.target { break }
            nonce += 1
        }
        let share = try await runtime.submitWork(SubmitWorkRequest(workID: template.workID, nonce: nonce))
        XCTAssertEqual(share.disposition, .childOnly)
        try await eventually("the share advances Alpha alone") {
            (await alphaReads.readSnapshot().height ?? 0) > alphaBefore
        }
        XCTAssertEqual(runtime.published.value?.actOnHeight, nexusBefore, "a share never enters Nexus")
        _ = try await runtime.mineBlock()
        try await eventually("a Nexus hit advances both") {
            (runtime.published.value?.actOnHeight ?? 0) > nexusBefore
        }

        // A transaction naming Alpha goes to Alpha's pool and is mined into
        // an Alpha block a merged grind carries.
        let key = CryptoUtils.generateKeyPair()
        let body = try HeaderImpl(node: TransactionBody(
            accountActions: [], actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: key.publicKey)], nonce: 0, chainPath: Self.alpha
        ))
        let transaction = Transaction(
            signatures: [key.publicKey: try XCTUnwrap(TransactionSigning.sign(bodyHeader: body, privateKeyHex: key.privateKey))],
            body: body
        )
        let digestBeforeChildTransaction = await runtime.status().templateDigest
        let admitted = try await runtime.submitTransaction(SubmitTransactionRequest(transaction: transaction))
        let pooled = await alphaReads.readSnapshot().mempoolCount
        XCTAssertEqual(pooled, 1)
        XCTAssertEqual(runtime.published.value?.mempoolCount, 0, "Nexus's pool never holds it")
        let digestWithChildTransaction = await runtime.status().templateDigest
        XCTAssertNotEqual(digestWithChildTransaction, digestBeforeChildTransaction)
        let refreshedTemplate = try await runtime.miningTemplate(MiningTemplateRequest())
        XCTAssertEqual(refreshedTemplate.templateDigest, digestWithChildTransaction)
        try await eventually("Alpha confirms the transaction") {
            _ = try await runtime.mineBlock()
            return await alphaReads.readSnapshot().mempoolCount == 0
        }
        let stored = await alphaReads.transaction(cid: admitted.transactionCID)
        XCTAssertNotNil(stored)
        // A withdrawal on Alpha names a receipt its parent state does not
        // hold: execution refuses it, so no Alpha block ever carries it. (The
        // pool may keep it as not ready: the receipt can still appear on a
        // later parent state.)
        let withdrawer = CryptoUtils.generateKeyPair()
        let withdrawerAddress = CryptoUtils.createAddress(from: withdrawer.publicKey)
        let withdrawalBody = try HeaderImpl(node: TransactionBody(
            accountActions: [AccountAction(owner: withdrawerAddress, delta: 5)], actions: [], depositActions: [],
            receiptActions: [],
            withdrawalActions: [WithdrawalAction(
                withdrawer: withdrawerAddress, nonce: 7, demander: withdrawerAddress,
                amountDemanded: 5, amountWithdrawn: 5
            )],
            signers: [withdrawerAddress], nonce: 0, chainPath: Self.alpha
        ))
        let withdrawal = Transaction(
            signatures: [withdrawer.publicKey: try XCTUnwrap(TransactionSigning.sign(
                bodyHeader: withdrawalBody, privateKeyHex: withdrawer.privateKey
            ))],
            body: withdrawalBody
        )
        let withdrawalCID = try? await runtime.submitTransaction(SubmitTransactionRequest(transaction: withdrawal)).transactionCID
        let heightBefore = await alphaReads.readSnapshot().height ?? 0
        try await eventually("Alpha advances past the withdrawal") {
            _ = try await runtime.mineBlock()
            return (await alphaReads.readSnapshot().height ?? 0) >= heightBefore + 2
        }
        for height in 0...((await alphaReads.readSnapshot().height) ?? 0) {
            guard let cid = await alphaReads.explorerCanonicalBlockCID(atHeight: height),
                  let page = await alphaReads.explorerBlockTransactions(cid: cid, offset: 0, limit: 100) else { continue }
            XCTAssertFalse(page.transactions.contains { $0.txCID == withdrawalCID }, "block \(height) carries the withdrawal")
        }

        let alphaHeight = await alphaReads.readSnapshot().height ?? 0
        await runtime.stop()
        return alphaHeight

    }
}
