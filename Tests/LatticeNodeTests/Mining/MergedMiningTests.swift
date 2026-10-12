import Foundation
import Ivy
import Lattice
import LatticeLightClient
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
    func testExportedWalletProofVectorsVerify() async throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/cross-chain-state-proofs.json")
        let proofs = try JSONDecoder().decode(
            [String: StateDictionaryProof].self,
            from: Data(contentsOf: fixtureURL)
        )
        XCTAssertEqual(Set(proofs.keys), [
            "deposit", "receiptExists", "receiptCompressedAbsence",
            "receiptMissingRouteAbsence",
        ])
        for (name, proof) in proofs {
            let verified = await LightClientProtocol.verify(proof)
            XCTAssertTrue(verified, name)
        }
    }

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
        let reopened = try await NodeStorage.open(configuration: configuration)
        let storedProofs = try await reopened.store.savedProofs()
        XCTAssertFalse((storedProofs[Self.alpha] ?? [:]).isEmpty, "Alpha's credited proofs survive the restart")
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

    /// A transaction for a hosted child chain reaches a peer that hosts the
    /// same child, just as a Nexus transaction reaches it: the peer learns of
    /// it by announcement and pools it on the level the transaction names.
    func testAPeerPoolsAnAnnouncedTransactionOnTheChainItNames() async throws {
        func host(_ keyByte: String, peers: [PeerEndpoint] = []) throws -> (NodeConfiguration, IvyConfig, PeerEndpoint) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "lattice-relay-\(UUID().uuidString)", isDirectory: true
            )
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
            let port = NetworkTransportTestPorts.allocate()
            let configuration = try NodeConfiguration(
                chainPath: ["Nexus"], storagePath: directory, privateKeyHex: String(repeating: keyByte, count: 32),
                listenPort: port, rpcPort: NetworkTransportTestPorts.allocate(),
                hostedChildren: [Self.alpha], childSpecs: [Self.alpha: Self.alphaSpec]
            )
            let overlay = IvyConfig(
                signingKey: configuration.signingKey, listenPort: port, bootstrapPeers: peers,
                requestTimeout: .seconds(5), stunServers: [], healthConfig: PeerHealthConfig(enabled: false),
                mode: .overlay
            )
            return (configuration, overlay, PeerEndpoint(publicKey: configuration.processPublicKey, host: "127.0.0.1", port: port))
        }
        let (minerConfiguration, minerOverlay, minerEndpoint) = try host("5a")
        let miner = try await NodeRuntime.start(
            storage: try await NodeStorage.open(configuration: minerConfiguration),
            configuration: minerConfiguration, overlay: minerOverlay
        )
        addTeardownBlock { await miner.stop() }
        let minerAlpha = try XCTUnwrap(miner.levelReads[Self.alpha])
        let payer = CryptoUtils.generateKeyPair()
        let payerAddress = CryptoUtils.createAddress(from: payer.publicKey)
        let payee = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
        let recipients = MiningTemplateRequest(recipients: [
            MiningRecipient(chainPath: ["Nexus"], address: payerAddress),
            MiningRecipient(chainPath: Self.alpha, address: payerAddress),
        ])
        func balance(_ reads: ChainReads) async -> UInt64 {
            guard let tip = await reads.readSnapshot().tipCID else { return 0 }
            return await reads.account(owner: payerAddress, blockCID: tip)?.balance ?? 0
        }
        try await eventually("the payer is funded on both chains") {
            _ = try await miner.mineBlock(recipients)
            let onAlpha = await balance(minerAlpha), onNexus = await balance(miner.reads)
            return onAlpha >= 5 && onNexus >= 5
        }

        // A second node that hosts both chains joins and catches up. It is the
        // one a transaction is submitted to, as a public submit node would be.
        let (entryConfiguration, entryOverlay, _) = try host("5b", peers: [minerEndpoint])
        let entry = try await NodeRuntime.start(
            storage: try await NodeStorage.open(configuration: entryConfiguration),
            configuration: entryConfiguration, overlay: entryOverlay
        )
        addTeardownBlock { await entry.stop() }
        let entryAlpha = try XCTUnwrap(entry.levelReads[Self.alpha])
        try await eventually("the entry node catches up on both chains") {
            let alphaTip = await minerAlpha.readSnapshot().tipCID, nexusTip = await miner.reads.readSnapshot().tipCID
            let entryAlphaTip = await entryAlpha.readSnapshot().tipCID, entryNexusTip = await entry.reads.readSnapshot().tipCID
            return alphaTip != nil && alphaTip == entryAlphaTip && nexusTip == entryNexusTip
        }

        func pay(on chainPath: [String]) throws -> Transaction {
            let body = TransactionBody(
                accountActions: [AccountAction(owner: payerAddress, delta: -2), AccountAction(owner: payee, delta: 1)],
                actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
                signers: [payerAddress], nonce: 0, chainPath: chainPath
            )
            let header = try HeaderImpl(node: body)
            return Transaction(
                signatures: [payer.publicKey: try XCTUnwrap(TransactionSigning.sign(
                    bodyHeader: header, privateKeyHex: payer.privateKey
                ))],
                body: header
            )
        }
        // The control: a Nexus transaction submitted to the entry node reaches the miner's pool.
        _ = try await entry.submitTransaction(SubmitTransactionRequest(transaction: try pay(on: ["Nexus"])))
        try await eventually("the miner pools the announced Nexus transaction") {
            await miner.reads.readSnapshot().mempoolCount == 1
        }
        // The same for the hosted child: it must land in the child's pool, and nowhere else.
        let alphaCID = try await entry.submitTransaction(SubmitTransactionRequest(transaction: try pay(on: Self.alpha))).transactionCID
        try await eventually("the miner pools the announced Alpha transaction", within: .seconds(10)) {
            await minerAlpha.readSnapshot().mempoolCount == 1
        }
        let nexusPooled = await miner.reads.readSnapshot().mempoolCount
        XCTAssertEqual(nexusPooled, 1, "a child transaction never enters the root pool")
        // And the miner then mines it on Alpha.
        try await eventually("the miner includes the Alpha transaction") {
            _ = try await miner.mineBlock(recipients)
            let included = await minerAlpha.explorerTransaction(cid: alphaCID)?.blockHeight
            return included != nil
        }
    }

    /// A WASM policy module that gives `verdict` for every transaction: the
    /// memory, allocator and transaction entrypoint the policy ABI requires.
    private static func policyModule(verdict: UInt8) -> Data {
        func section(_ id: UInt8, _ body: [UInt8]) -> [UInt8] { [id, UInt8(body.count)] + body }
        func export(_ name: String, kind: UInt8, index: UInt8) -> [UInt8] {
            [UInt8(name.utf8.count)] + Array(name.utf8) + [kind, index]
        }
        var exports: [UInt8] = [0x03]
        exports += export("memory", kind: 2, index: 0)
        exports += export("lattice_alloc", kind: 0, index: 0)
        exports += export("lattice_validate_transaction", kind: 0, index: 1)
        var module: [UInt8] = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]
        // (i32) -> i32 and (i32, i32) -> i32
        module += section(1, [0x02, 0x60, 0x01, 0x7f, 0x01, 0x7f, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f])
        module += section(3, [0x02, 0x00, 0x01])
        module += section(5, [0x01, 0x00, 0x01])
        module += section(7, exports)
        // lattice_alloc returns 1024; the entrypoint returns the verdict.
        module += section(10, [0x02, 0x05, 0x00, 0x41, 0x80, 0x08, 0x0b, 0x04, 0x00, 0x41, verdict, 0x0b])
        return Data(module)
    }

    /// A node hosting Nexus and Alpha. With `module`, Alpha's spec names it
    /// as its transaction policy and the node is given its bytes; without,
    /// the node only follows the Alpha others mine.
    private func policyHost(
        _ keyByte: String, module: Data?, peers: [PeerEndpoint] = []
    ) throws -> (NodeConfiguration, IvyConfig, PeerEndpoint) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-policy-\(UUID().uuidString)", isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let port = NetworkTransportTestPorts.allocate()
        let spec = try module.map { module in
            ChainSpec(
                maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000, premine: 0,
                targetBlockTime: 1_000, initialReward: 10, halvingInterval: 10_000, halfLife: 10,
                wasmPolicies: [WasmPolicyRef(
                    moduleCID: try WasmPolicyModuleHeader(node: WasmPolicyModule(bytes: module)).rawCID,
                    scope: .transaction
                )]
            )
        }
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"], storagePath: directory, privateKeyHex: String(repeating: keyByte, count: 32),
            listenPort: port, rpcPort: NetworkTransportTestPorts.allocate(),
            hostedChildren: [Self.alpha], childSpecs: spec.map { [Self.alpha: $0] } ?? [:],
            policyModules: module.map { [$0] } ?? []
        )
        let overlay = IvyConfig(
            signingKey: configuration.signingKey, listenPort: port, bootstrapPeers: peers,
            requestTimeout: .seconds(5), stunServers: [], healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        )
        return (configuration, overlay, PeerEndpoint(publicKey: configuration.processPublicKey, host: "127.0.0.1", port: port))
    }

    /// A payer the node's mining has funded on Alpha, and a transfer of theirs on it.
    private func fundedAlphaTransfer(
        _ miner: NodeRuntime
    ) async throws -> (recipients: MiningTemplateRequest, transfer: Transaction) {
        let alpha = try XCTUnwrap(miner.levelReads[Self.alpha])
        let payer = CryptoUtils.generateKeyPair()
        let payerAddress = CryptoUtils.createAddress(from: payer.publicKey)
        let payee = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
        let recipients = MiningTemplateRequest(recipients: [
            MiningRecipient(chainPath: ["Nexus"], address: payerAddress),
            MiningRecipient(chainPath: Self.alpha, address: payerAddress),
        ])
        try await eventually("the payer is funded on Alpha") {
            _ = try await miner.mineBlock(recipients)
            guard let tip = await alpha.readSnapshot().tipCID else { return false }
            return (await alpha.account(owner: payerAddress, blockCID: tip)?.balance ?? 0) >= 5
        }
        let body = TransactionBody(
            accountActions: [AccountAction(owner: payerAddress, delta: -2), AccountAction(owner: payee, delta: 1)],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [payerAddress], nonce: 0, chainPath: Self.alpha
        )
        let header = try HeaderImpl(node: body)
        return (recipients, Transaction(
            signatures: [payer.publicKey: try XCTUnwrap(TransactionSigning.sign(
                bodyHeader: header, privateKeyHex: payer.privateKey
            ))],
            body: header
        ))
    }

    /// A child chain whose spec names a policy module reaches a second node
    /// whole: a node given neither the spec nor the module follows the chain
    /// from the node that mined it, executes a block whose transaction the
    /// policy had to accept, and holds the module afterwards.
    func testAPeerSyncsAPolicyChildAndItsModuleFromTheNodeThatMinedIt() async throws {
        let module = Self.policyModule(verdict: 1)
        let moduleCID = try WasmPolicyModuleHeader(node: WasmPolicyModule(bytes: module)).rawCID
        let (minerConfiguration, minerOverlay, minerEndpoint) = try policyHost("6a", module: module)
        let miner = try await NodeRuntime.start(
            storage: try await NodeStorage.open(configuration: minerConfiguration),
            configuration: minerConfiguration, overlay: minerOverlay
        )
        addTeardownBlock { await miner.stop() }
        let minerAlpha = try XCTUnwrap(miner.levelReads[Self.alpha])
        let (recipients, transfer) = try await fundedAlphaTransfer(miner)
        let transferCID = try await miner.submitTransaction(SubmitTransactionRequest(transaction: transfer)).transactionCID
        try await eventually("the miner includes the transfer its policy accepts") {
            _ = try await miner.mineBlock(recipients)
            let included = await minerAlpha.explorerTransaction(cid: transferCID)?.blockHeight
            return included != nil
        }

        let (followerConfiguration, followerOverlay, _) = try policyHost("6b", module: nil, peers: [minerEndpoint])
        let followerStorage = try await NodeStorage.open(configuration: followerConfiguration)
        let before = await followerStorage.broker.fetchVolumeLocal(root: moduleCID)
        XCTAssertNil(before, "the follower starts without the module")
        let follower = try await NodeRuntime.start(
            storage: followerStorage, configuration: followerConfiguration, overlay: followerOverlay
        )
        addTeardownBlock { await follower.stop() }
        let followerAlpha = try XCTUnwrap(follower.levelReads[Self.alpha])
        try await eventually("the follower executes Alpha to the miner's tip") {
            let minerTip = await minerAlpha.readSnapshot().tipCID, followerTip = await followerAlpha.readSnapshot().tipCID
            return minerTip != nil && minerTip == followerTip
        }
        let followed = await followerAlpha.explorerTransaction(cid: transferCID)?.blockHeight
        XCTAssertNotNil(followed, "the follower executed the block carrying the transfer")
        let after = await followerStorage.broker.fetchVolumeLocal(root: moduleCID)
        XCTAssertNotNil(after, "the follower holds the module it fetched with the chain")
    }

    /// A policy that rejects every transaction keeps them off its chain: the
    /// same transfer the accepting policy's chain mines is refused at
    /// submission here, while the chain itself still advances.
    func testARejectingPolicyRefusesTheTransferAnAcceptingOneMines() async throws {
        let (configuration, overlay, _) = try policyHost("6c", module: Self.policyModule(verdict: 0))
        let node = try await NodeRuntime.start(
            storage: try await NodeStorage.open(configuration: configuration),
            configuration: configuration, overlay: overlay
        )
        addTeardownBlock { await node.stop() }
        let alpha = try XCTUnwrap(node.levelReads[Self.alpha])
        let (recipients, transfer) = try await fundedAlphaTransfer(node)
        do {
            _ = try await node.submitTransaction(SubmitTransactionRequest(transaction: transfer))
            XCTFail("the policy rejects the transfer")
        } catch {
            XCTAssertEqual(error as? MempoolError, .invalidState, "refused as invalid: \(error)")
        }
        let height = await alpha.readSnapshot().height ?? 0
        try await eventually("Alpha advances without the transfer") {
            _ = try await node.mineBlock(recipients)
            return (await alpha.readSnapshot().height ?? 0) > height
        }
        let pooled = await alpha.readSnapshot().mempoolCount
        XCTAssertEqual(pooled, 0)
    }

    /// The cross-chain swap end to end on one node that hosts Nexus and
    /// Alpha: A deposits on Alpha, B pays the receipt on Nexus, and B's
    /// withdrawal on Alpha is mined by merged mining. Preflight has no
    /// carrier, so the pool holds the withdrawal as unavailable; the child
    /// template must still offer it, to be checked against the carrier's
    /// entering state.
    func testAChildWithdrawalIsMinedOnceItsParentReceiptLands() async throws {
        let storageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-swap-\(UUID().uuidString)", isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storageDirectory) }
        let port = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"], storagePath: storageDirectory, privateKeyHex: String(repeating: "4f", count: 32),
            listenPort: port, rpcPort: NetworkTransportTestPorts.allocate(),
            hostedChildren: [Self.alpha], childSpecs: [Self.alpha: Self.alphaSpec]
        )
        let overlay = IvyConfig(
            signingKey: configuration.signingKey, listenPort: port, bootstrapPeers: [],
            requestTimeout: .seconds(5), stunServers: [], healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        )
        let storage = try await NodeStorage.open(configuration: configuration)
        let runtime = try await NodeRuntime.start(storage: storage, configuration: configuration, overlay: overlay)
        let nexusReads = runtime.reads
        let alphaReads = try XCTUnwrap(runtime.levelReads[Self.alpha])
        let demander = CryptoUtils.generateKeyPair()
        let demanderAddress = CryptoUtils.createAddress(from: demander.publicKey)
        let withdrawer = CryptoUtils.generateKeyPair()
        let withdrawerAddress = CryptoUtils.createAddress(from: withdrawer.publicKey)
        // B earns on Nexus, A on Alpha: B pays the receipt, A locks the deposit.
        let recipients = MiningTemplateRequest(recipients: [
            MiningRecipient(chainPath: ["Nexus"], address: withdrawerAddress),
            MiningRecipient(chainPath: Self.alpha, address: demanderAddress),
        ])
        func balance(_ reads: ChainReads, _ owner: String) async -> UInt64 {
            guard let tip = await reads.readSnapshot().tipCID else { return 0 }
            return await reads.account(owner: owner, blockCID: tip)?.balance ?? 0
        }
        func signed(_ key: (privateKey: String, publicKey: String), _ body: TransactionBody) throws -> Transaction {
            let header = try HeaderImpl(node: body)
            return Transaction(
                signatures: [key.publicKey: try XCTUnwrap(TransactionSigning.sign(
                    bodyHeader: header, privateKeyHex: key.privateKey
                ))],
                body: header
            )
        }
        @discardableResult
        func confirm(_ transaction: Transaction, on reads: ChainReads, _ label: String) async throws -> String {
            let cid = try await runtime.submitTransaction(SubmitTransactionRequest(transaction: transaction)).transactionCID
            try await eventually(label) {
                _ = try await runtime.mineBlock(recipients)
                let pooled = await reads.readSnapshot().mempoolCount
                let stored = await reads.transaction(cid: cid)
                return pooled == 0 && stored != nil
            }
            return cid
        }
        try await eventually("A and B are funded") {
            _ = try await runtime.mineBlock(recipients)
            let locked = await balance(alphaReads, demanderAddress)
            let paid = await balance(nexusReads, withdrawerAddress)
            return locked >= 10 && paid >= 3
        }

        try await confirm(signed(demander, TransactionBody(
            accountActions: [AccountAction(owner: demanderAddress, delta: -5)], actions: [],
            depositActions: [DepositAction(nonce: 1, demander: demanderAddress, amountDemanded: 3, amountDeposited: 5)],
            receiptActions: [], withdrawalActions: [],
            signers: [demanderAddress], nonce: 0, chainPath: Self.alpha
        )), on: alphaReads, "Alpha confirms the deposit")
        let secondDepositCID = try await confirm(signed(demander, TransactionBody(
            accountActions: [AccountAction(owner: demanderAddress, delta: -5)], actions: [],
            depositActions: [DepositAction(nonce: 2, demander: demanderAddress, amountDemanded: 4, amountDeposited: 5)],
            receiptActions: [], withdrawalActions: [],
            signers: [demanderAddress], nonce: 1, chainPath: Self.alpha
        )), on: alphaReads, "Alpha confirms the second active deposit")
        try await confirm(signed(withdrawer, TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [ReceiptAction(
                withdrawer: withdrawerAddress, nonce: 1, demander: demanderAddress,
                amountDemanded: 3, directory: "Alpha"
            )],
            withdrawalActions: [],
            signers: [withdrawerAddress], nonce: 0, chainPath: ["Nexus"]
        )), on: nexusReads, "Nexus confirms the receipt")
        // Zero fee, and B holds nothing on Alpha: the withdrawal funds itself.
        let withdrawal = try signed(withdrawer, TransactionBody(
            accountActions: [AccountAction(owner: withdrawerAddress, delta: 5)], actions: [], depositActions: [],
            receiptActions: [],
            withdrawalActions: [WithdrawalAction(
                withdrawer: withdrawerAddress, nonce: 1, demander: demanderAddress,
                amountDemanded: 3, amountWithdrawn: 5
            )],
            signers: [withdrawerAddress], nonce: 0, chainPath: Self.alpha
        ))
        // While it is pooled, a template and status agree on the digest, so
        // an external miner never sees its work as stale.
        let cid = try await runtime.submitTransaction(SubmitTransactionRequest(transaction: withdrawal)).transactionCID
        try await eventually("Alpha pools the withdrawal") { await alphaReads.readSnapshot().mempoolCount == 1 }
        let template = try await runtime.miningTemplate(recipients)
        let status = await runtime.status().templateDigest
        XCTAssertEqual(template.templateDigest, status)
        try await eventually("Alpha confirms the withdrawal") {
            _ = try await runtime.mineBlock(recipients)
            let pooled = await alphaReads.readSnapshot().mempoolCount
            let stored = await alphaReads.transaction(cid: cid)
            return pooled == 0 && stored != nil
        }
        let credited = await balance(alphaReads, withdrawerAddress)
        XCTAssertEqual(credited, 5)

        // The first raw key is now spent (value 0), but it still advances the
        // cursor; the next page lists and proves the still-active deposit.
        let spentResult = try await alphaReads.explorerDeposits(limit: 1, after: nil)
        let spentPage = try XCTUnwrap(spentResult)
        XCTAssertTrue(spentPage.deposits.isEmpty)
        let afterSpent = try XCTUnwrap(spentPage.next)
        let spentVerified = await LightClientProtocol.verify(spentPage.proof)
        XCTAssertTrue(spentVerified)
        XCTAssertEqual(spentPage.proof.claims.first?.value, "0")
        // `mineBlock` returns once Nexus has the block; the Alpha block it
        // carries is imported after. A loop that mines again before then
        // builds a sibling on Alpha's old tip, and Alpha's fork choice may
        // swap its tip for that sibling just after the loop ends. A page read
        // across the swap names no creating blocks (the chain moved under its
        // search), so the page is read until it is placed. Nothing more is
        // mined meanwhile, so the swap is the last change and this ends.
        func placedDeposits(limit: Int, after: String?) async throws -> ExplorerDepositsPage {
            var placed: ExplorerDepositsPage?
            try await eventually("Alpha places every listed deposit") {
                guard let page = try await alphaReads.explorerDeposits(limit: limit, after: after),
                      page.deposits.allSatisfy({ $0.blockHeight != nil && $0.blockHash != nil }) else { return false }
                placed = page
                return true
            }
            return try XCTUnwrap(placed)
        }
        let activePage = try await placedDeposits(limit: 1, after: afterSpent)
        XCTAssertEqual(activePage.deposits.count, 1)
        XCTAssertEqual(activePage.deposits.first?.nonce, "2")
        XCTAssertEqual(activePage.deposits.first?.amountDemanded, 4)
        // Each listed deposit names the canonical block that created it: the
        // block that executed its transaction, several blocks below the tip
        // by now, and unchanged by the later withdrawal of its neighbour.
        let depositTransaction = await alphaReads.explorerTransaction(cid: secondDepositCID)
        let createdAt = try XCTUnwrap(depositTransaction?.blockHeight)
        XCTAssertEqual(activePage.deposits.first?.blockHeight, createdAt)
        XCTAssertEqual(activePage.deposits.first?.blockHash, depositTransaction?.blockHash)
        XCTAssertLessThan(createdAt, activePage.proof.blockHeight)
        let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(activePage)) as? [String: Any]
        let wireDeposit = (wire?["deposits"] as? [[String: Any]])?.first
        XCTAssertEqual(wireDeposit?["blockHeight"] as? String, String(createdAt))
        XCTAssertEqual(wireDeposit?["blockHash"] as? String, depositTransaction?.blockHash)

        // One page places every deposit it lists with a single shared search:
        // a later deposit lands in a later block, and the older one keeps its.
        let thirdDepositCID = try await confirm(signed(demander, TransactionBody(
            accountActions: [AccountAction(owner: demanderAddress, delta: -1)], actions: [],
            depositActions: [DepositAction(nonce: 3, demander: demanderAddress, amountDemanded: 6, amountDeposited: 1)],
            receiptActions: [], withdrawalActions: [],
            signers: [demanderAddress], nonce: 2, chainPath: Self.alpha
        )), on: alphaReads, "Alpha confirms a third deposit")
        // The third deposit is in Alpha's tip block, the one a sibling can
        // replace: either sibling carries it (both were built while it was
        // pooled) at the same height, under a different hash. The page and
        // the transaction are two reads, so they are taken until they name
        // the same block, which they do for good once the tip is still.
        var bothRead: (page: ExplorerDepositsPage, third: ExplorerTransaction)?
        try await eventually("the page and the transaction name the third deposit's block alike") {
            let page = try await placedDeposits(limit: 10, after: nil)
            guard let third = await alphaReads.explorerTransaction(cid: thirdDepositCID), third.blockHash != nil,
                  page.deposits.last?.blockHash == third.blockHash else { return false }
            bothRead = (page, third)
            return true
        }
        let (bothPage, thirdTransaction) = try XCTUnwrap(bothRead)
        XCTAssertEqual(bothPage.deposits.map(\.nonce), ["2", "3"])
        let thirdCreatedAt = try XCTUnwrap(thirdTransaction.blockHeight)
        XCTAssertEqual(bothPage.deposits.map(\.blockHeight), [createdAt, thirdCreatedAt])
        XCTAssertEqual(bothPage.deposits.map(\.blockHash), [depositTransaction?.blockHash, thirdTransaction.blockHash])
        XCTAssertGreaterThan(thirdCreatedAt, createdAt)
        let bothVerified = await LightClientProtocol.verify(bothPage.proof)
        XCTAssertTrue(bothVerified)
        let activeVerified = await LightClientProtocol.verify(activePage.proof)
        XCTAssertTrue(activeVerified)

        func replacing(
            _ proof: StateDictionaryProof,
            blockHash: String? = nil,
            claims: [StateDictionaryProof.Claim]? = nil,
            witness: [LightClientProof.WitnessNode]? = nil
        ) -> StateDictionaryProof {
            StateDictionaryProof(
                blockHash: blockHash ?? proof.blockHash,
                blockHeight: proof.blockHeight, block: proof.block,
                stateRoot: proof.stateRoot, dictionary: proof.dictionary,
                dictionaryRoot: proof.dictionaryRoot,
                claims: claims ?? proof.claims,
                witness: witness ?? proof.witness
            )
        }
        let changedDepositClaim = replacing(
            activePage.proof,
            claims: activePage.proof.claims.map { .init(key: $0.key, value: "6") }
        )
        let changedClaimAccepted = await LightClientProtocol.verify(changedDepositClaim)
        XCTAssertFalse(changedClaimAccepted)
        let incompleteWitnessAccepted = await LightClientProtocol.verify(replacing(
            activePage.proof, witness: Array(activePage.proof.witness.dropLast())
        ))
        XCTAssertFalse(incompleteWitnessAccepted)
        let mismatchedBlockAccepted = await LightClientProtocol.verify(replacing(
            activePage.proof, blockHash: "bafyreiaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        ))
        XCTAssertFalse(mismatchedBlockAccepted)

        // One key is read and proven without the listing: the withdrawn
        // deposit as its zero marker, the active one as its amount, and a key
        // never deposited as absent. A wallet settles a purchase on the first.
        let spentKey = try XCTUnwrap(spentPage.proof.claims.first?.key)
        let spentStateResult = try await alphaReads.explorerDepositState(key: spentKey)
        let spentState = try XCTUnwrap(spentStateResult)
        XCTAssertTrue(spentState.exists)
        XCTAssertEqual(spentState.value, "0")
        XCTAssertEqual(spentState.proof.claims, [.init(key: spentKey, value: "0")])
        let spentStateVerified = await LightClientProtocol.verify(spentState.proof)
        XCTAssertTrue(spentStateVerified)
        let activeKey = try XCTUnwrap(activePage.deposits.first?.key)
        let activeStateResult = try await alphaReads.explorerDepositState(key: activeKey)
        let activeState = try XCTUnwrap(activeStateResult)
        XCTAssertEqual(activeState.value, "5")
        let activeStateVerified = await LightClientProtocol.verify(activeState.proof)
        XCTAssertTrue(activeStateVerified)
        let neverKey = "\(demanderAddress)/9/99"
        let neverStateResult = try await alphaReads.explorerDepositState(key: neverKey)
        let neverState = try XCTUnwrap(neverStateResult)
        XCTAssertFalse(neverState.exists)
        XCTAssertNil(neverState.value)
        let neverStateVerified = await LightClientProtocol.verify(neverState.proof)
        XCTAssertTrue(neverStateVerified)
        // A still-locked deposit cannot be passed off as withdrawn, nor as never made.
        for forged in ["0", nil] as [String?] {
            let accepted = await LightClientProtocol.verify(replacing(
                activeState.proof, claims: [.init(key: activeKey, value: forged)]
            ))
            XCTAssertFalse(accepted)
        }

        let receiptResult = try await nexusReads.explorerReceiptState(
            demander: demanderAddress, amountDemanded: 3, nonce: 1,
            destinationPath: Self.alpha
        )
        let receipt = try XCTUnwrap(receiptResult)
        XCTAssertTrue(receipt.exists)
        XCTAssertEqual(receipt.withdrawer, withdrawerAddress)
        let receiptVerified = await LightClientProtocol.verify(receipt.proof)
        XCTAssertTrue(receiptVerified)
        let forgedReceiptAbsence = replacing(
            receipt.proof,
            claims: receipt.proof.claims.map { .init(key: $0.key, value: nil) }
        )
        let forgedAbsenceAccepted = await LightClientProtocol.verify(forgedReceiptAbsence)
        XCTAssertFalse(forgedAbsenceAccepted)
        await runtime.stop()
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
        let betaHeight = try await mineNestedFirstRun(configuration, overlay, beta: beta)

        // A nested proof crosses two child indexes. Restoring only Alpha is
        // not enough: Beta must have its exact evidence immediately after a
        // process restart, and the next merged grind must keep advancing it.
        let reopened = try await NodeStorage.open(configuration: configuration)
        let storedProofs = try await reopened.store.savedProofs()
        XCTAssertFalse((storedProofs[beta] ?? [:]).isEmpty, "Beta's credited proofs survive the restart")
        let restarted = try await NodeRuntime.start(
            storage: reopened, configuration: configuration, overlay: overlay
        )
        let betaReads = try XCTUnwrap(restarted.levelReads[beta])
        let restoredHeight = await betaReads.readSnapshot().height ?? 0
        XCTAssertGreaterThanOrEqual(restoredHeight, betaHeight)
        _ = try await restarted.mineBlock()
        try await eventually("Beta advances after the restart") {
            (await betaReads.readSnapshot().height ?? 0) > restoredHeight
        }
        await restarted.stop()
    }

    private func mineNestedFirstRun(
        _ configuration: NodeConfiguration,
        _ overlay: IvyConfig,
        beta: [String]
    ) async throws -> UInt64 {
        let storage = try await NodeStorage.open(configuration: configuration)
        let runtime = try await NodeRuntime.start(
            storage: storage, configuration: configuration, overlay: overlay
        )
        let betaReads = try XCTUnwrap(runtime.levelReads[beta])
        let recipient = CryptoUtils.createAddress(
            from: CryptoUtils.generateKeyPair().publicKey
        )
        try await eventually("Beta's genesis is mined after Alpha executes") {
            // Alpha pays a recipient, so its state changes: Beta's genesis
            // must commit a non-empty parent state.
            _ = try await runtime.mineBlock(MiningTemplateRequest(recipients: [
                MiningRecipient(chainPath: Self.alpha, address: recipient),
            ]))
            return (await betaReads.readSnapshot().height ?? 0) >= 1
        }
        let height = await betaReads.readSnapshot().height ?? 0
        await runtime.stop()
        return height
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
        // Alpha; one that meets Nexus's advances both. Nexus executes a block
        // before Alpha executes the block it carried, so a template read in
        // between carries an Alpha block on the tip Alpha is about to leave:
        // its share is weighed as a sibling and Alpha's height stays. The
        // share is therefore taken from a fresh template until one advances
        // Alpha. Nothing else is mining, so Alpha settles and one does.
        let nexusBefore = runtime.published.value?.actOnHeight ?? 0
        var advanced = false
        for _ in 0..<8 where !advanced {
            let alphaBefore = await alphaReads.readSnapshot().height ?? 0
            template = try await runtime.miningTemplate(MiningTemplateRequest())
            let carried = try XCTUnwrap(template.block.children.node?.entries["Alpha"]?.node)
            var nonce: UInt64 = 0
            while true {
                let hash = template.block.replacingNonce(nonce).proofOfWorkHash()
                if hash > template.block.target, hash <= carried.target { break }
                nonce += 1
            }
            let share = try await runtime.submitWork(SubmitWorkRequest(workID: template.workID, nonce: nonce))
            XCTAssertEqual(share.disposition, .childOnly)
            advanced = (try? await eventually("the share advances Alpha alone", within: .seconds(3)) {
                (await alphaReads.readSnapshot().height ?? 0) > alphaBefore
            }) != nil
        }
        XCTAssertTrue(advanced, "a share advances Alpha alone")
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
        // Status and a template agree on the digest for the same state. The
        // digest covers Alpha's tip, which may still be moving to the block
        // the last Nexus block carried, so the two are read until they agree.
        try await eventually("status serves the digest of the template a miner fetches") {
            let served = await runtime.status().templateDigest
            let fetched = try await runtime.miningTemplate(MiningTemplateRequest()).templateDigest
            return served == fetched && served != digestBeforeChildTransaction
        }
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
