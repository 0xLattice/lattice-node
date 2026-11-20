import Foundation
import Ivy
import Lattice
import LatticeNodeCore
import XCTest
import cashew
@testable import LatticeNode
import LatticeNodeAPI

/// A child withdrawal's parent-receipt witness travels with its block's
/// body: a node keeping bodies stores, pins and serves it, and a node that
/// fetches the body executes the withdrawal from it, with the parent state
/// the withdrawal names let go of everywhere.
final class ReceiptWitnessTests: XCTestCase {
    private struct Host {
        let configuration: NodeConfiguration
        let overlay: IvyConfig
        let endpoint: PeerEndpoint
    }

    private static let alpha = ["Nexus", "Alpha"]
    private static let alphaSpec = ChainSpec(
        maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000, premine: 0,
        targetBlockTime: 1_000, initialReward: 10, halvingInterval: 10_000, halfLife: 10
    )

    private func host(
        keyByte: UInt8, peers: [PeerEndpoint] = [], blockBodies: BlockBodies, hosted: Bool = true,
        storageDirectory reused: URL? = nil
    ) throws -> Host {
        let storageDirectory = reused ?? FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-node-witness-\(UUID().uuidString)", isDirectory: true
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
            blockBodies: blockBodies,
            state: .recent,
            hostedChildren: hosted ? [Self.alpha] : [],
            childSpecs: hosted ? [Self.alpha: Self.alphaSpec] : [:],
            stateWindows: FinalityWindows(all: 2)
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

    private func start(_ host: Host) async throws -> (NodeRuntime, NodeStorage) {
        let storage = try await NodeStorage.open(configuration: host.configuration)
        return (try await NodeRuntime.start(
            storage: storage, configuration: host.configuration, overlay: host.overlay
        ), storage)
    }

    private func signed(_ key: (privateKey: String, publicKey: String), _ body: TransactionBody) throws -> Transaction {
        let header = try HeaderImpl(node: body)
        return Transaction(
            signatures: [key.publicKey: try XCTUnwrap(TransactionSigning.sign(
                bodyHeader: header, privateKeyHex: key.privateKey
            ))],
            body: header
        )
    }

    /// The producer (bodies kept, `state: recent`) confirms a deposit on
    /// Alpha, its receipt on Nexus and the withdrawal on Alpha, then goes on
    /// until the Nexus state the withdrawal names is gone from it but for
    /// the witness. A follower on `blockBodies: none` and `state: recent`
    /// syncs from it alone and executes the withdrawal's block.
    func testAFollowerOnNoneExecutesAnOldChildWithdrawalFromTheWitnessItsBodyCarries() async throws {
        let producer = try host(keyByte: 0xd1, blockBodies: .all)
        let (runtime, storage) = try await start(producer)
        let nexusReads = runtime.reads
        let alphaReads = try XCTUnwrap(runtime.levelReads[Self.alpha])
        let demander = CryptoUtils.generateKeyPair()
        let demanderAddress = CryptoUtils.createAddress(from: demander.publicKey)
        let withdrawer = CryptoUtils.generateKeyPair()
        let withdrawerAddress = CryptoUtils.createAddress(from: withdrawer.publicKey)
        let recipients = MiningTemplateRequest(recipients: [
            MiningRecipient(chainPath: ["Nexus"], address: withdrawerAddress),
            MiningRecipient(chainPath: Self.alpha, address: demanderAddress),
        ])
        func balance(_ reads: ChainReads, _ owner: String) async -> UInt64 {
            guard let tip = await reads.readSnapshot().tipCID else { return 0 }
            return await reads.account(owner: owner, blockCID: tip)?.balance ?? 0
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
            return locked >= 10 && paid >= 6
        }
        try await confirm(try signed(demander, TransactionBody(
            accountActions: [AccountAction(owner: demanderAddress, delta: -5)], actions: [],
            depositActions: [DepositAction(nonce: 1, demander: demanderAddress, amountDemanded: 3, amountDeposited: 5)],
            receiptActions: [], withdrawalActions: [],
            signers: [demanderAddress], nonce: 0, chainPath: Self.alpha
        )), on: alphaReads, "Alpha confirms the deposit")
        func receipt(nonce: UInt128, signerNonce: UInt64) throws -> Transaction {
            try signed(withdrawer, TransactionBody(
                accountActions: [], actions: [], depositActions: [],
                receiptActions: [ReceiptAction(
                    withdrawer: withdrawerAddress, nonce: nonce, demander: demanderAddress,
                    amountDemanded: 3, directory: "Alpha"
                )],
                withdrawalActions: [],
                signers: [withdrawerAddress], nonce: signerNonce, chainPath: ["Nexus"]
            ))
        }
        try await confirm(try receipt(nonce: 1, signerNonce: 0), on: nexusReads, "Nexus confirms the receipt")
        let withdrawalCID = try await confirm(try signed(withdrawer, TransactionBody(
            accountActions: [AccountAction(owner: withdrawerAddress, delta: 5)], actions: [], depositActions: [],
            receiptActions: [],
            withdrawalActions: [WithdrawalAction(
                withdrawer: withdrawerAddress, nonce: 1, demander: demanderAddress,
                amountDemanded: 3, amountWithdrawn: 5
            )],
            signers: [withdrawerAddress], nonce: 0, chainPath: Self.alpha
        )), on: alphaReads, "Alpha confirms the withdrawal")
        // A later receipt replaces the receipt tree's root, and the blocks
        // after it move the anchored state out of the producer's window.
        try await confirm(try receipt(nonce: 2, signerNonce: 1), on: nexusReads, "Nexus confirms a later receipt")
        for _ in 0..<6 { _ = try await runtime.mineBlock(recipients) }
        // The Alpha block carrying it: down from the tip, read once the
        // chain has grown past it. A block mined before Alpha executed the
        // one before it is that one's sibling and carries the withdrawal
        // too, and the chain keeps only one of them.
        let local = await storage.localFetcher
        let alphaHead = await alphaReads.readSnapshot()
        var walk = alphaHead.tipCID
        var placed: String?
        while let cid = walk, placed == nil {
            let node = try await BlockHeader(rawCID: cid).resolve(fetcher: local).node
            let block = try XCTUnwrap(node)
            if try await NodeRuntime.carriedTransactionIDs(of: block, fetcher: local).contains(withdrawalCID) {
                placed = cid
            }
            walk = block.parent?.rawCID
        }
        let withdrawalBlock = try XCTUnwrap(placed)

        let resolved = try await BlockHeader(rawCID: withdrawalBlock).resolve(fetcher: local)
        let block = try XCTUnwrap(resolved.node)
        let anchored = try? await block.parentState.resolve(fetcher: local)
        XCTAssertNotNil(anchored?.node, "the producer holds the witness: the anchored state's root")
        // Let go of behind the loop, once the counts reach the tip.
        try await eventually("the producer lets go of the rest of the state the withdrawal names") {
            (try? await block.parentState.resolveRecursive(fetcher: local)) == nil
        }
        let pinned = try await storage.broker(at: Self.alpha).retainedRoots(scope: storage.scopes.body(withdrawalBlock, at: Self.alpha))
        let witness = await storage.receiptWitness(of: BlockHeader(rawCID: withdrawalBlock), fetcher: local).map(\.root)
        XCTAssertFalse(witness.isEmpty)
        XCTAssertTrue(Set(witness).isSubset(of: Set(pinned)), "the witness is pinned with the body")
        let bundle = await storage.volumeBundle(withdrawalBlock)
        XCTAssertTrue(Set(witness).isSubset(of: Set(bundle)), "and served with it")
        // A witness that cannot be read when the block is stored fails it,
        // as its content would: the block is not stored, so its connect
        // job does not connect it (`connectJob`).
        let content = NodeImportStorage(storage: nil, keepsVolumes: true)
        try await BlockHeader(rawCID: withdrawalBlock).storeBlockContent(fetcher: local, storer: content)
        let contentVolumes = await content.takeVolumes().map(\.volume)
        let unreadable = Set(witness).subtracting(contentVolumes.map(\.root))
        XCTAssertFalse(unreadable.isEmpty)
        // Stored by a node holding nothing of it, so storing reads it.
        let empty = try await NodeStorage.open(configuration: try host(keyByte: 0xd3, blockBodies: .all).configuration)
        let stored = try await empty.storeValidBlocks(
            [(withdrawalBlock, nil)], at: Self.alpha, from: Unreadable(local, cids: unreadable)
        )
        XCTAssertNil(stored[withdrawalBlock], "a block whose witness cannot be read is not stored")
        // A fetch that obtained the block's content and not its receipt
        // proofs says so, as a wait of its own; one that obtained nothing
        // reports the body as not obtained.
        let proofsMissing = await empty.incompleteBody(withdrawalBlock, read: contentVolumes, error: Unanswered())
        XCTAssertEqual(BodyWait(fetchFailure: proofsMissing), .receiptProofsUnavailable)
        XCTAssertEqual("\(BodyWait(fetchFailure: proofsMissing))", "its receipt proofs not obtained from any peer")
        let nothingRead = await empty.incompleteBody(withdrawalBlock, read: [], error: Unanswered())
        XCTAssertEqual(BodyWait(fetchFailure: nothingRead), .unavailable)
        let producerAlpha = await alphaReads.readSnapshot()
        // Its height, not its tip: the producer's last carried Alpha block
        // can connect after this read, and the follower then follows it.
        let alphaHeight = try XCTUnwrap(producerAlpha.height)

        // The follower first follows Nexus alone, past the anchored state,
        // which its window lets go of; then it hosts Alpha, whose sync
        // reaches the withdrawal with that state gone here and at its peer.
        let nexusOnly = try host(keyByte: 0xd2, peers: [producer.endpoint], blockBodies: .none, hosted: false)
        do {
            let (nexusRuntime, nexusStorage) = try await start(nexusOnly)
            let nexusTip = await nexusReads.readSnapshot().tipCID
            try await eventually("the follower executes Nexus to the producer's tip") {
                nexusRuntime.published.value?.actOnTip == nexusTip
            }
            // On `recent` a window is let go of once the chain's counts reach
            // the tip, which a maintenance pass may be what settles: it can
            // still be held when the tip is published.
            let followerLocal = await nexusStorage.localFetcher
            var polls = 0
            try await eventually("the follower let go of the state the withdrawal names") {
                if polls % 50 == 0 { nexusRuntime.inputs.yield(.maintenance) }
                polls += 1
                return (try? await block.parentState.resolveRecursive(fetcher: followerLocal)) == nil
            }
            await nexusRuntime.stop()
        }
        let follower = try host(
            keyByte: 0xd2, peers: [producer.endpoint], blockBodies: .none,
            storageDirectory: nexusOnly.configuration.storagePath
        )
        let (followerRuntime, followerStorage) = try await start(follower)
        let followerAlpha = try XCTUnwrap(followerRuntime.levelReads[Self.alpha])
        try await eventually("the follower executes Alpha past the withdrawal", within: .seconds(60)) {
            (await followerAlpha.readSnapshot().height ?? 0) >= alphaHeight
        }
        // It stored the witness as part of the body it fetched, and on
        // `none` let go of both once the block was no longer its tip.
        let row = followerStorage.bundles.bundle(root: withdrawalBlock)
        let missing = Set(witness).subtracting(row ?? [])
        var held: [String: Bool] = [:]
        for root in missing { held[root] = await followerStorage.stores.hasVolume(root: root) }
        XCTAssertTrue(
            missing.isEmpty,
            "the follower stored the witness with the body: bundle row \(row.map { "of \($0.count) roots" } ?? "absent"), "
                + "missing \(missing.count) of \(witness.count) witness roots, held here \(held)"
        )
        try await eventually("the follower lets go of the old body and its witness") {
            try await followerStorage.broker.retainedRoots(
                scope: followerStorage.scopes.body(withdrawalBlock, at: Self.alpha)
            ).isEmpty
        }
        await followerRuntime.stop()
        await runtime.stop()
    }

    /// A fetch that ended with nothing served.
    private struct Unanswered: Error {}

    /// Reads through `fetcher` except `cids`, which fail.
    private struct Unreadable: Fetcher {
        struct Failure: Error {}
        let fetcher: any Fetcher
        let cids: Set<String>

        init(_ fetcher: any Fetcher, cids: Set<String>) {
            self.fetcher = fetcher
            self.cids = cids
        }

        func fetch(rawCid: String) async throws -> Data {
            guard !cids.contains(rawCid) else { throw Failure() }
            return try await fetcher.fetch(rawCid: rawCid)
        }
    }
}
