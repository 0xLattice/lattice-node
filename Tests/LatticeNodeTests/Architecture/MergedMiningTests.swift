import Foundation
import Ivy
import Lattice
import LatticeNodeCore
import UInt256
import XCTest
import cashew
@testable import LatticeNode

/// Merged mining on the core driver: a node hosting Nexus and one child
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
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-merged-\(UUID().uuidString)", isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let port = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"], storagePath: storage,
            privateKeyHex: String(repeating: "4d", count: 32),
            listenPort: port, rpcPort: NetworkTransportTestPorts.allocate(),
            hostedChildren: [Self.alpha], childSpecs: [Self.alpha: Self.alphaSpec]
        )
        let overlay = IvyConfig(
            signingKey: configuration.signingKey, listenPort: port, bootstrapPeers: [],
            requestTimeout: .seconds(5), stunServers: [], healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        )
        let process = try await ChainProcess.open(configuration: configuration)
        let driver = try await CoreDriver.start(process: process, configuration: configuration, overlay: overlay)
        let alphaReads = try XCTUnwrap(driver.levelReads[Self.alpha])

        let first = try await driver.miningTemplate(MiningTemplateRequest())
        XCTAssertNotNil(first.block.children.node?.entries["Alpha"], "the template carries Alpha's genesis")

        // Fast blocks harden Nexus's scheduled target below the maximum.
        var template = first
        var mined = 0
        while template.block.target == UInt256.max, mined < 64 {
            _ = try await driver.mineBlock()
            mined += 1
            try await eventually("block \(mined) executes") { driver.published.value?.actOnHeight == UInt64(mined) }
            template = try await driver.miningTemplate(MiningTemplateRequest())
        }
        XCTAssertLessThan(template.block.target, UInt256.max, "Nexus mines at a hard scheduled target")
        try await eventually("Alpha advanced with the Nexus blocks that carried it") {
            (await alphaReads.readSnapshot().height ?? 0) >= 1
        }

        // A grind that meets Alpha's target but misses Nexus's weighs only
        // Alpha; one that meets Nexus's advances both.
        let alphaBefore = await alphaReads.readSnapshot().height ?? 0
        let nexusBefore = driver.published.value?.actOnHeight ?? 0
        let carried = try XCTUnwrap(template.block.children.node?.entries["Alpha"]?.node)
        var nonce: UInt64 = 0
        while true {
            let hash = template.block.replacingNonce(nonce).proofOfWorkHash()
            if hash > template.block.target, hash <= carried.target { break }
            nonce += 1
        }
        let share = try await driver.submitWork(SubmitWorkRequest(workID: template.workID, nonce: nonce))
        XCTAssertEqual(share.disposition, .childOnly)
        try await eventually("the share advances Alpha alone") {
            (await alphaReads.readSnapshot().height ?? 0) > alphaBefore
        }
        XCTAssertEqual(driver.published.value?.actOnHeight, nexusBefore, "a share never enters Nexus")
        _ = try await driver.mineBlock()
        try await eventually("a Nexus hit advances both") {
            (driver.published.value?.actOnHeight ?? 0) > nexusBefore
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
        let admitted = try await driver.submitTransaction(SubmitTransactionRequest(transaction: transaction))
        let pooled = await alphaReads.readSnapshot().mempoolCount
        XCTAssertEqual(pooled, 1)
        XCTAssertEqual(driver.published.value?.mempoolCount, 0, "Nexus's pool never holds it")
        try await eventually("Alpha confirms the transaction") {
            _ = try await driver.mineBlock()
            return await alphaReads.readSnapshot().mempoolCount == 0
        }
        let stored = await alphaReads.transaction(cid: admitted.transactionCID)
        XCTAssertNotNil(stored)
        await driver.stop()
    }
}
