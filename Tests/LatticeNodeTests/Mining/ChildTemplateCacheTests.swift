import Foundation
import Ivy
import Lattice
import LatticeNodeCore
import UInt256
import XCTest
import cashew
@testable import LatticeNode
import LatticeNodeAPI

/// A template rebuilds only the hosted levels that changed and their
/// ancestors: every other level's block is reused, and a reused block,
/// timestamp and all, is mined like any other.
final class ChildTemplateCacheTests: XCTestCase {
    private static func key(tip: String = "tip", transactions: [String] = []) -> ChildTemplateCache.Key {
        ChildTemplateCache.Key(
            tipCID: tip, actOnTipCID: tip, enteringCID: "entering", transactions: transactions,
            anchor: nil, request: TemplateRequest(rewardRecipient: nil), hosted: [], children: []
        )
    }

    private static func entry(_ key: ChildTemplateCache.Key, at instant: ContinuousClock.Instant) -> ChildTemplateCache.Entry {
        // The cache never reads the block: any will do.
        let state = LatticeStateHeader(rawCID: "state")
        let block = Block(
            version: Block.currentVersion, parent: nil,
            transactions: HeaderImpl(rawCID: state.rawCID), target: .max, nextTarget: .max,
            spec: VolumeImpl(rawCID: state.rawCID), parentState: state, prevState: state,
            postState: state, children: HeaderImpl(rawCID: state.rawCID), height: 0,
            timestamp: 0, rewardRecipient: nil, nonce: 0
        )
        return ChildTemplateCache.Entry(
            key: key, builtAt: instant, block: block, searchWitness: nil, subtreeThresholds: nil
        )
    }

    func testABlockIsReusedOnlyForItsOwnKeyAndWithinItsAge() {
        let cache = ChildTemplateCache(maxAge: .seconds(30))
        let path = ["Nexus", "Alpha"]
        let built = ContinuousClock.now
        cache.keep(Self.entry(Self.key(), at: built), at: path)

        XCTAssertNotNil(cache.block(at: path, for: Self.key(), now: built + .seconds(29)))
        XCTAssertNil(cache.block(at: path, for: Self.key(), now: built + .seconds(31)), "too old to reuse")
        XCTAssertNil(cache.block(at: path, for: Self.key(tip: "moved"), now: built), "another tip")
        XCTAssertNil(cache.block(at: path, for: Self.key(transactions: ["tx"]), now: built), "another pool")
        XCTAssertNil(cache.block(at: ["Nexus", "Beta"], for: Self.key(), now: built), "another level")

        // One block per level: a newer build replaces the older.
        cache.keep(Self.entry(Self.key(tip: "moved"), at: built), at: path)
        XCTAssertNil(cache.block(at: path, for: Self.key(), now: built))
        XCTAssertNotNil(cache.block(at: path, for: Self.key(tip: "moved"), now: built))
    }

    func testOnlyTheLevelThatChangedIsRebuiltAndAReusedBlockIsMined() async throws {
        let alpha = ["Nexus", "Alpha"]
        let beta = alpha + ["Beta"], gamma = alpha + ["Gamma"]
        let spec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000, premine: 0,
            targetBlockTime: 1_000, initialReward: 10, halvingInterval: 10_000, halfLife: 10
        )
        let storageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-template-cache-\(UUID().uuidString)", isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storageDirectory) }
        let port = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"], storagePath: storageDirectory, privateKeyHex: String(repeating: "5b", count: 32),
            listenPort: port, rpcPort: NetworkTransportTestPorts.allocate(),
            hostedChildren: [alpha, beta, gamma], childSpecs: [alpha: spec, beta: spec, gamma: spec]
        )
        let overlay = IvyConfig(
            signingKey: configuration.signingKey, listenPort: port, bootstrapPeers: [],
            requestTimeout: .seconds(5), stunServers: [], healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        )
        let storage = try await NodeStorage.open(configuration: configuration)
        let runtime = try await NodeRuntime.start(storage: storage, configuration: configuration, overlay: overlay)
        let betaReads = try XCTUnwrap(runtime.levelReads[beta])
        let gammaReads = try XCTUnwrap(runtime.levelReads[gamma])
        let recipient = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
        let request = MiningTemplateRequest(recipients: [MiningRecipient(chainPath: alpha, address: recipient)])

        func leaves(_ template: MiningTemplateResponse) throws -> (beta: String, gamma: String, gammaBlock: Block) {
            let alphaBlock = try XCTUnwrap(template.block.children.node?.entries["Alpha"]?.node)
            let entries = try XCTUnwrap(alphaBlock.children.node?.entries)
            let betaHeader = try XCTUnwrap(entries["Beta"]), gammaHeader = try XCTUnwrap(entries["Gamma"])
            return (betaHeader.rawCID, gammaHeader.rawCID, try XCTUnwrap(gammaHeader.node))
        }

        // Both leaves past genesis, then a template once nothing moves.
        try await eventually("Beta and Gamma are mined past genesis") {
            _ = try await runtime.mineBlock(request)
            let betaHeight = await betaReads.readSnapshot().height ?? 0
            let gammaHeight = await gammaReads.readSnapshot().height ?? 0
            return betaHeight >= 2 && gammaHeight >= 2
        }
        var first = try await runtime.miningTemplate(request)
        try await eventually("the template settles") {
            let next = try await runtime.miningTemplate(request)
            defer { first = next }
            return next.templateDigest == first.templateDigest
        }

        // Nothing changed: both leaves' blocks are reused. Built again, each
        // would take the root's newer timestamp and a new CID.
        try await Task.sleep(for: .milliseconds(20))
        let again = try await runtime.miningTemplate(request)
        let firstLeaves = try leaves(first), againLeaves = try leaves(again)
        XCTAssertEqual(againLeaves.beta, firstLeaves.beta, "Beta's block is reused")
        XCTAssertEqual(againLeaves.gamma, firstLeaves.gamma, "Gamma's block is reused")
        XCTAssertGreaterThan(again.block.timestamp, againLeaves.gammaBlock.timestamp, "the root's timestamp moved on")

        // A transaction to Beta rebuilds Beta's block, not Gamma's.
        let key = CryptoUtils.generateKeyPair()
        let body = try HeaderImpl(node: TransactionBody(
            accountActions: [], actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: key.publicKey)], nonce: 0, chainPath: beta
        ))
        let transaction = Transaction(
            signatures: [key.publicKey: try XCTUnwrap(TransactionSigning.sign(bodyHeader: body, privateKeyHex: key.privateKey))],
            body: body
        )
        _ = try await runtime.submitTransaction(SubmitTransactionRequest(transaction: transaction))
        var withTransaction = again
        try await eventually("a template carries Beta's transaction") {
            withTransaction = try await runtime.miningTemplate(request)
            return try leaves(withTransaction).beta != firstLeaves.beta
        }
        let rebuilt = try leaves(withTransaction)
        XCTAssertEqual(rebuilt.gamma, firstLeaves.gamma, "Gamma's block is still reused")

        // Mined, the reused Gamma block, with its older timestamp, becomes
        // Gamma's tip like any other.
        let gammaBefore = await gammaReads.readSnapshot().height ?? 0
        var nonce: UInt64 = 0
        while withTransaction.block.replacingNonce(nonce).proofOfWorkHash() > withTransaction.block.target { nonce += 1 }
        _ = try await runtime.submitWork(SubmitWorkRequest(workID: withTransaction.workID, nonce: nonce))
        try await eventually("Gamma advances with the reused block") {
            (await gammaReads.readSnapshot().height ?? 0) > gammaBefore
        }
        let gammaTip = await gammaReads.explorerCanonicalBlockCID(atHeight: gammaBefore + 1)
        XCTAssertEqual(gammaTip, rebuilt.gamma, "the reused block is Gamma's new tip")
        await runtime.stop()
    }
}
