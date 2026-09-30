import Crypto
import Foundation
import Ivy
import Lattice
import LatticeMinerCore
import UInt256
import VolumeBroker
import XCTest
import cashew
@testable import LatticeNode

final class ChainServiceTests: XCTestCase {
    func testTransactionRequestsCarryConcreteBodiesThroughJSON() throws {
        let key = CryptoUtils.generateKeyPair()
        let transaction = try signedTransaction(
            key: key,
            chainPath: ["Nexus"],
            accountActions: [AccountAction(
                owner: CryptoUtils.createAddress(from: key.publicKey),
                delta: 1
            )]
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let submitted = try decoder.decode(
            SubmitTransactionRequest.self,
            from: encoder.encode(SubmitTransactionRequest(
                transaction: transaction
            ))
        )
        XCTAssertNotNil(submitted.transaction.body.node)
        XCTAssertEqual(submitted.transaction.body.rawCID, transaction.body.rawCID)
    }

    func testRequestPayloadCeilingIsInclusive() async throws {
        let key = CryptoUtils.generateKeyPair()
        let body = try signedTransaction(
            key: key,
            chainPath: ["Nexus"]
        ).body
        func request(signatureBytes: Int) -> SubmitTransactionRequest {
            SubmitTransactionRequest(transaction: Transaction(
                signatures: ["k": String(repeating: "x", count: signatureBytes)],
                body: body
            ))
        }
        let encoder = JSONEncoder()
        let emptySize = try encoder.encode(request(signatureBytes: 0)).count
        let padding = ChainServiceLimits.maximumPayloadBytes - emptySize
        let exact = request(signatureBytes: padding)
        let oversized = request(signatureBytes: padding + 1)
        XCTAssertEqual(
            try encoder.encode(exact).count,
            ChainServiceLimits.maximumPayloadBytes
        )
        XCTAssertEqual(
            try encoder.encode(oversized).count,
            ChainServiceLimits.maximumPayloadBytes + 1
        )

        let service = makeService(process: try await nexusProcess())
        await XCTAssertThrowsErrorAsync(
            try await service.submitTransaction(exact)
        ) { error in
            XCTAssertEqual(error as? TransactionPoolError, .tooLarge)
        }
        await XCTAssertThrowsErrorAsync(
            try await service.submitTransaction(oversized)
        ) { error in
            XCTAssertEqual(error as? ChainServiceError, .requestTooLarge)
        }
    }

    func testPublicationFailureDoesNotRewriteAcceptedWork() async throws {
        let service = makeService(
            process: try await nexusProcess(),
            acceptedBlockPublisher: { _ in throw TestPublicationError.failed }
        )
        let template = try await service.miningTemplate(MiningTemplateRequest())

        let submitted = try await service.submitWork(SubmitWorkRequest(
            workID: template.workID,
            nonce: 0
        ))
        XCTAssertTrue(submitted.accepted)
        XCTAssertEqual(submitted.disposition, .canonicalized)
        let status = await service.status()
        XCTAssertEqual(status.height, 1)
    }

    func testNetworkAdmissionPublishesBeforeOptionalChildMaterialization()
        async throws {
        let process = try await nexusProcess()
        let publishedBlocks = PublishedBlocks()
        let service = makeService(
            process: process,
            acceptedBlockPublisher: { blockCID in
                await publishedBlocks.record(blockCID)
            }
        )
        let parent = try await process.canonicalTipBlock()
        let childGenesis = try await BlockBuilder.buildChildGenesis(
            spec: ChainSpec(
                maxNumberOfTransactionsPerBlock: 100,
                maxStateGrowth: 100_000,
                premine: 0,
                targetBlockTime: 1_000,
                initialReward: 10,
                halvingInterval: 100,
                halfLife: 10
            ),
            parentState: parent.postState,
            transactions: [],
            timestamp: 1,
            target: UInt256.max,
            fetcher: process
        )
        let genesisCID = try BlockHeader(node: childGenesis).rawCID
        _ = try await service.submitTransaction(SubmitTransactionRequest(
            transaction: try signedTransaction(
                key: CryptoUtils.generateKeyPair(),
                chainPath: ["Nexus"],
                genesisActions: [GenesisAction(
                    directory: "Sandbox",
                    blockCID: genesisCID
                )]
            )
        ))
        let template = try await service.miningTemplate(MiningTemplateRequest())
        let header = try BlockHeader(node: template.block)

        // `Block.storeBlock` deliberately leaves child links independent. This
        // network path has no authenticated direct-child route to materialize,
        // so hierarchy extraction is optional, but canonical visibility is not.
        let result = try await service.importNetworkCandidate(
            header,
            authenticatedChildPackage: nil,
            contentSource: FetcherContentSource(process)
        )

        guard case .canonicalized = result.decision else {
            return XCTFail("expected canonical network admission")
        }
        let publications = await publishedBlocks.all()
        XCTAssertEqual(publications, [header.rawCID])
    }

    func testBlockedNetworkPreflightDoesNotDelayTemplateCreation() async throws {
        let producer = try await nexusProcess()
        let genesis = try await producer.canonicalTipBlock()
        let candidate = try await BlockBuilder.buildBlock(
            previous: genesis,
            timestamp: 1,
            nonce: 0,
            fetcher: producer
        )
        let header = try BlockHeader(node: candidate)
        let remote = BlockingContentSource(blockedCID: header.rawCID)
        await remote.setEntries([
            header.rawCID: try XCTUnwrap(candidate.toData()),
        ])
        let process = try await nexusProcess()
        let service = makeService(process: process)
        let unresolved = BlockHeader(
            rawCID: header.rawCID,
            node: nil,
            encryptionInfo: nil
        )
        let admission = Task {
            try await service.importNetworkCandidate(
                unresolved,
                authenticatedChildPackage: nil,
                contentSource: remote
            )
        }
        await remote.waitForBlockedFetch()

        let templateFinished = expectation(
            description: "local template finishes while remote admission is blocked"
        )
        let template = Task {
            defer { templateFinished.fulfill() }
            do {
                return try await service.miningTemplate(MiningTemplateRequest())
            } catch {
                throw error
            }
        }
        await fulfillment(of: [templateFinished], timeout: 1)

        await remote.releaseBlockedFetch()
        _ = try await admission.value
        _ = try await template.value
    }

    /// The network runtime's stop cancels its ingress tasks without joining
    /// them, so an import already inside the service when shutdown starts is
    /// waited for: its commit is enqueued and reconciled before shutdown
    /// returns, nothing starts afterwards, and new ingress is refused.
    func testShutdownWaitsForAnImportInFlightAndRefusesNewIngress()
        async throws
    {
        let producer = try await nexusProcess()
        let genesis = try await producer.canonicalTipBlock()
        let candidate = try await BlockBuilder.buildBlock(
            previous: genesis,
            timestamp: 1,
            nonce: 0,
            fetcher: producer
        )
        let header = try BlockHeader(node: candidate)
        let remote = BlockingContentSource(blockedCID: header.rawCID)
        await remote.setEntries([
            header.rawCID: try XCTUnwrap(candidate.toData()),
        ])
        let process = try await nexusProcess()
        let service = makeService(process: process)
        let unresolved = BlockHeader(
            rawCID: header.rawCID,
            node: nil,
            encryptionInfo: nil
        )
        let admission = Task {
            try await service.importNetworkCandidate(
                unresolved,
                authenticatedChildPackage: nil,
                contentSource: remote
            )
        }
        await remote.waitForBlockedFetch()

        let returned = ShutdownReturned()
        let shutdown = Task {
            await service.shutdown()
            await returned.mark()
        }
        try await Task.sleep(for: .milliseconds(300))
        let early = await returned.value
        XCTAssertFalse(early, "shutdown returned with an import inside")

        await remote.releaseBlockedFetch()
        await shutdown.value
        let outcome = try await admission.value
        XCTAssertTrue(outcome.decision.isAccepted, "\(outcome.decision)")
        let quiescent = await service.isQuiescent()
        XCTAssertTrue(quiescent, "background work outlived shutdown")
        let height = await process.canonicalTipHeight()
        XCTAssertEqual(height, 1)

        do {
            _ = try await service.importNetworkCandidate(
                unresolved,
                authenticatedChildPackage: nil,
                contentSource: remote
            )
            XCTFail("ingress admitted after shutdown")
        } catch is CancellationError {}
        let roots = await service.transactionInventoryRoots()
        XCTAssertEqual(roots, [])
    }

    func testDuplicateWorkIsReportedWithoutClaimingNewAcceptance() async throws {
        let process = try await nexusProcess()
        let service = makeService(process: process)
        let template = try await service.miningTemplate(MiningTemplateRequest())
        let first = try await process.importBlock(BlockHeader(node: template.block))
        guard case .canonicalized = first.decision else {
            return XCTFail("expected initial canonical admission")
        }

        let duplicate = try await service.submitWork(SubmitWorkRequest(
            workID: template.workID,
            nonce: template.block.nonce
        ))
        XCTAssertFalse(duplicate.accepted)
        XCTAssertEqual(duplicate.disposition, .duplicate)
    }

    func testAdmittedTemplateIsConsumedWithoutInvalidatingCompetingWork()
        async throws
    {
        let service = makeService(process: try await nexusProcess())
        func recipient() -> MiningRecipient {
            MiningRecipient(
                chainPath: ["Nexus"],
                address: CryptoUtils.createAddress(
                    from: CryptoUtils.generateKeyPair().publicKey
                )
            )
        }
        let first = try await service.miningTemplate(
            MiningTemplateRequest(recipients: [recipient()])
        )
        let second = try await service.miningTemplate(
            MiningTemplateRequest(recipients: [recipient()])
        )
        XCTAssertNotEqual(first.workID, second.workID)

        let firstSubmission = try await service.submitWork(SubmitWorkRequest(
            workID: first.workID,
            nonce: 0
        ))
        let secondSubmission = try await service.submitWork(SubmitWorkRequest(
            workID: second.workID,
            nonce: 0
        ))
        XCTAssertTrue(firstSubmission.accepted)
        XCTAssertTrue(secondSubmission.accepted)
        await XCTAssertThrowsErrorAsync(
            try await service.submitWork(SubmitWorkRequest(
                workID: second.workID,
                nonce: 0
            ))
        ) { error in
            XCTAssertEqual(error as? MiningTemplateError, .unknownWork)
        }
    }

    func testRecipientTemplateCreditsTheBlockRewardAndSubmitsWork() async throws {
        let process = try await nexusProcess()
        let publishedBlocks = PublishedBlocks()
        let service = makeService(
            process: process,
            acceptedBlockPublisher: { blockCID in
                await publishedBlocks.record(blockCID)
            }
        )
        let recipient = CryptoUtils.createAddress(
            from: CryptoUtils.generateKeyPair().publicKey
        )

        let template = try await service.miningTemplate(
            MiningTemplateRequest(recipients: [MiningRecipient(
                chainPath: ["Nexus"],
                address: recipient
            )])
        )
        XCTAssertEqual(template.block.nonce, 0)
        XCTAssertEqual(template.chainPath, ["Nexus"])
        XCTAssertEqual(template.block.rewardRecipient, recipient)
        // The reward is a header field, not a transaction: it takes no slot.
        XCTAssertEqual(
            try template.block.transactions.node?.allKeysAndValues().count,
            0
        )

        let submitted = try await service.submitWork(SubmitWorkRequest(
            workID: template.workID,
            nonce: 0
        ))
        XCTAssertTrue(submitted.accepted)
        XCTAssertEqual(submitted.disposition, .canonicalized)
        let blockCIDs = await publishedBlocks.all()
        XCTAssertEqual(blockCIDs, [try XCTUnwrap(submitted.tipCID)])
        let status = await service.status()
        XCTAssertEqual(status.height, 1)
        let reward = NexusGenesis.spec.rewardAtBlock(1)
        let account = await service.explorerAccount(owner: recipient)
        XCTAssertEqual(account?.balance, reward)
        let block = await service.explorerBlock(cid: try XCTUnwrap(submitted.tipCID))
        XCTAssertEqual(block?.rewardRecipient, recipient)
        XCTAssertEqual(block?.rewardAmount, reward)
    }

    /// The recipient is credited the reward PLUS the fees its block carries,
    /// and a template without one burns both.
    func testRecipientIsPaidRewardPlusFeesAndNoRecipientBurns() async throws {
        let service = makeService(process: try await nexusProcess())
        let payer = CryptoUtils.generateKeyPair()
        let payerAddress = CryptoUtils.createAddress(from: payer.publicKey)
        let recipient = CryptoUtils.createAddress(
            from: CryptoUtils.generateKeyPair().publicKey
        )
        // Block 1 funds the payer.
        let funding = try await service.miningTemplate(MiningTemplateRequest(
            recipients: [MiningRecipient(chainPath: ["Nexus"], address: payerAddress)]
        ))
        let funded = try await service.submitWork(SubmitWorkRequest(
            workID: funding.workID, nonce: 0
        ))
        XCTAssertTrue(funded.accepted)
        // Block 2 carries a transfer of 10 that pays a fee of 7.
        let sink = CryptoUtils.createAddress(
            from: CryptoUtils.generateKeyPair().publicKey
        )
        _ = try await service.submitTransaction(SubmitTransactionRequest(
            transaction: try signedTransaction(
                key: payer,
                accountActions: [
                    AccountAction(owner: payerAddress, delta: -17),
                    AccountAction(owner: sink, delta: 10),
                ]
            )
        ))
        let paying = try await service.miningTemplate(MiningTemplateRequest(
            recipients: [MiningRecipient(chainPath: ["Nexus"], address: recipient)]
        ))
        XCTAssertEqual(
            try paying.block.transactions.node?.allKeysAndValues().count, 1
        )
        let paid = try await service.submitWork(SubmitWorkRequest(
            workID: paying.workID, nonce: 0
        ))
        XCTAssertTrue(paid.accepted)
        let reward = NexusGenesis.spec.rewardAtBlock(2)
        let account = await service.explorerAccount(owner: recipient)
        XCTAssertEqual(account?.balance, reward + 7)
        let paidBlock = await service.explorerBlock(cid: try XCTUnwrap(paid.tipCID))
        XCTAssertEqual(paidBlock?.rewardAmount, reward + 7)

        // Block 3 names no recipient: nothing is credited to anyone.
        let burning = try await service.miningTemplate(MiningTemplateRequest())
        XCTAssertNil(burning.block.rewardRecipient)
        let burned = try await service.submitWork(SubmitWorkRequest(
            workID: burning.workID, nonce: 0
        ))
        XCTAssertTrue(burned.accepted)
        let burnedBlock = await service.explorerBlock(
            cid: try XCTUnwrap(burned.tipCID)
        )
        XCTAssertNil(burnedBlock?.rewardRecipient)
        XCTAssertNil(burnedBlock?.rewardAmount)
        let unchanged = await service.explorerAccount(owner: recipient)
        XCTAssertEqual(unchanged?.balance, reward + 7)
    }

    /// The recipient is in the proof-of-work preimage: a different recipient
    /// is a different template, block and preimage.
    func testRecipientChangesTheTemplateAndPreimage() async throws {
        let service = makeService(process: try await nexusProcess())
        func template(_ address: String) async throws -> MiningTemplateResponse {
            try await service.miningTemplate(MiningTemplateRequest(
                recipients: [MiningRecipient(chainPath: ["Nexus"], address: address)]
            ))
        }
        let a = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
        let b = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
        let first = try await template(a)
        let second = try await template(b)
        XCTAssertNotEqual(first.workID, second.workID)
        XCTAssertNotEqual(
            try BlockHeader(node: first.block).rawCID,
            try BlockHeader(node: second.block).rawCID
        )
        XCTAssertNotEqual(
            Block.makeProofOfWorkPreimagePrefix(block: first.block),
            Block.makeProofOfWorkPreimagePrefix(block: second.block)
        )
    }

    func testMalformedRecipientPlansAreRefused() async throws {
        let service = makeService(process: try await nexusProcess())
        let address = CryptoUtils.createAddress(
            from: CryptoUtils.generateKeyPair().publicKey
        )
        let refused: [[MiningRecipient]] = [
            // Not a canonical address.
            [MiningRecipient(chainPath: ["Nexus"], address: "not-an-address")],
            [MiningRecipient(chainPath: ["Nexus"], address: "")],
            // Twice for one chain.
            [
                MiningRecipient(chainPath: ["Nexus"], address: address),
                MiningRecipient(chainPath: ["Nexus"], address: address),
            ],
            // Not at or below this chain.
            [MiningRecipient(chainPath: ["Other"], address: address)],
            [MiningRecipient(chainPath: [], address: address)],
        ]
        for recipients in refused {
            await XCTAssertThrowsErrorAsync(
                try await service.miningTemplate(
                    MiningTemplateRequest(recipients: recipients)
                )
            ) { error in
                XCTAssertEqual(error as? ChainServiceError, .invalidRecipientPlan)
            }
        }
    }

    /// The signed-reward request this replaced is refused, never read as a
    /// request that mines to no one.
    func testRewardsRequestIsRefused() throws {
        XCTAssertThrowsError(try JSONDecoder().decode(
            MiningTemplateRequest.self,
            from: Data(#"{"rewards":[]}"#.utf8)
        ))
        let decoded = try JSONDecoder().decode(
            MiningTemplateRequest.self,
            from: Data(#"{"recipients":[{"chainPath":["Nexus"],"address":"a"}]}"#.utf8)
        )
        XCTAssertEqual(decoded.recipients, [
            MiningRecipient(chainPath: ["Nexus"], address: "a"),
        ])
    }

    /// A transaction that creates value breaks the fee rule in any block, so
    /// the mempool never admits it.
    func testMempoolRefusesAValueCreatingTransaction() async throws {
        let service = makeService(process: try await nexusProcess())
        let key = CryptoUtils.generateKeyPair()
        await XCTAssertThrowsErrorAsync(
            try await service.submitTransaction(SubmitTransactionRequest(
                transaction: try signedTransaction(
                    key: key,
                    accountActions: [AccountAction(
                        owner: CryptoUtils.createAddress(from: key.publicKey),
                        delta: 1
                    )]
                )
            ))
        )
        let status = await service.status()
        XCTAssertEqual(status.mempoolCount, 0)
    }

    func testServiceOwnsABoundedMempool() async throws {
        let service = makeService(
            process: try await nexusProcess(),
            mempoolMaxCount: 1
        )
        let key = CryptoUtils.generateKeyPair()
        _ = try await service.submitTransaction(SubmitTransactionRequest(
            transaction: try signedTransaction(
                key: key,
                chainPath: ["Nexus"],
                nonce: 0
            )
        ))

        await XCTAssertThrowsErrorAsync(
            try await service.submitTransaction(SubmitTransactionRequest(
                transaction: try signedTransaction(
                    key: key,
                    chainPath: ["Nexus"],
                    nonce: 1
                )
            ))
        ) { error in
            XCTAssertEqual(error as? TransactionPoolError, .full)
        }
        let status = await service.status()
        XCTAssertEqual(status.mempoolCount, 1)
    }

    func testReadyTransactionDisplacesUnfundedFutureFeeClaim() async throws {
        let service = makeService(
            process: try await nexusProcess(),
            mempoolMaxCount: 1
        )
        _ = try await service.submitNetworkTransaction(
            try signedTransaction(
                key: CryptoUtils.generateKeyPair(),
                chainPath: ["Nexus"],
                nonce: 1
            )
        )
        let ready = try signedTransaction(
            key: CryptoUtils.generateKeyPair(),
            chainPath: ["Nexus"]
        )

        let submitted = try await service.submitTransaction(
            SubmitTransactionRequest(transaction: ready)
        )
        let inventory = await service.transactionInventoryRoots()

        XCTAssertEqual(inventory, [
            submitted.transactionCID,
        ])
    }

    func testLocalMempoolTransactionIsDurableContent() async throws {
        let process = try await nexusProcess()
        let service = makeService(process: process)
        let key = CryptoUtils.generateKeyPair()
        let submitted = try await service.submitTransaction(
            SubmitTransactionRequest(transaction: try signedTransaction(
                key: key,
                chainPath: ["Nexus"]
            ))
        )

        let stored = await process.content([submitted.transactionCID])
        XCTAssertNotNil(stored[submitted.transactionCID])
    }

    func testCanonicalCommitFencePrecedesLaterTemplateRequest()
        async throws {
        let publication = CanonicalCommitLatch()
        let process = try await nexusProcess()
        let service = makeService(
            process: process,
            acceptedBlockPublisher: { _ in await publication.wait() }
        )
        _ = try await service.submitTransaction(SubmitTransactionRequest(
            transaction: try signedTransaction(
                key: CryptoUtils.generateKeyPair(),
                chainPath: ["Nexus"]
            )
        ))
        let submittedTemplate = try await service.miningTemplate(
            MiningTemplateRequest()
        )
        let submission = Task {
            try await service.submitWork(SubmitWorkRequest(
                workID: submittedTemplate.workID,
                nonce: 0
            ))
        }
        await publication.waitUntilEntered()

        // The process has already enqueued its canonical commit, while the
        // service operation is deliberately paused in publication.
        let laterRequestStarted = Latch()
        let laterTemplate = Task {
            await laterRequestStarted.open()
            return try await service.miningTemplate(MiningTemplateRequest())
        }
        await laterRequestStarted.wait()
        await Task.yield()
        await Task.yield()
        await publication.release()

        let submitted = try await submission.value
        XCTAssertTrue(submitted.accepted)
        let template = try await laterTemplate.value
        XCTAssertEqual(
            try template.block.transactions.node?.allKeysAndValues().count,
            0
        )
    }

    func testIdleCanonicalCommitFencePrecedesLaterTemplateRequest()
        async throws {
        let process = try await nexusProcess()
        let service = makeService(process: process)
        _ = try await service.submitTransaction(SubmitTransactionRequest(
            transaction: try signedTransaction(
                key: CryptoUtils.generateKeyPair(),
                chainPath: ["Nexus"]
            )
        ))
        let mined = try await service.miningTemplate(MiningTemplateRequest())
        let admission = try await process.importBlock(BlockHeader(node: mined.block))
        guard case .canonicalized(let commit) = admission.decision else {
            return XCTFail("expected canonical direct admission")
        }

        let receipt = await service.enqueueCanonicalCommit(commit)
        let laterRequestStarted = Latch()
        let laterTemplate = Task {
            await laterRequestStarted.open()
            return try await service.miningTemplate(MiningTemplateRequest())
        }
        await laterRequestStarted.wait()
        await Task.yield()
        await Task.yield()
        await receipt.wait()

        let template = try await laterTemplate.value
        XCTAssertEqual(
            try template.block.transactions.node?.allKeysAndValues().count,
            0
        )
    }

    func testCanonicalCommitFenceCoalescesQueuedCommitsInSourceOrder()
        async throws {
        let process = try await nexusProcess()
        let service = makeService(process: process)
        _ = try await service.submitTransaction(SubmitTransactionRequest(
            transaction: try signedTransaction(
                key: CryptoUtils.generateKeyPair(),
                chainPath: ["Nexus"]
            )
        ))
        let template = try await service.miningTemplate(MiningTemplateRequest())
        let submitted = try await service.submitWork(SubmitWorkRequest(
            workID: template.workID,
            nonce: 0
        ))
        XCTAssertTrue(submitted.accepted)
        let blockCID = try XCTUnwrap(submitted.tipCID)
        let block = try await process.canonicalTipBlock()

        let removed = await service.enqueueCanonicalCommit(ChainCommit(
            revision: 2,
            tipHash: blockCID,
            canonicalBlocksRemoved: [blockCID]
        ))
        let added = await service.enqueueCanonicalCommit(ChainCommit(
            revision: 3,
            tipHash: blockCID,
            canonicalBlocksAdded: [blockCID: block.height]
        ))
        await removed.wait()
        await added.wait()

        // Removing the block re-admits its ordinary transaction; adding it
        // again must then remove it. A reversed queue would leave it pooled.
        let status = await service.status()
        XCTAssertEqual(status.mempoolCount, 0)
    }

    func testQueuedCommitFailureRestoresDurableMempoolAndReleasesWaiter()
        async throws {
        let service = makeService(process: try await nexusProcess())
        _ = try await service.submitTransaction(SubmitTransactionRequest(
            transaction: try signedTransaction(
                key: CryptoUtils.generateKeyPair(),
                chainPath: ["Nexus"]
            )
        ))
        let stale = try await service.miningTemplate(MiningTemplateRequest())

        let receipt = await service.enqueueCanonicalCommit(ChainCommit(
            tipHash: "missing-block",
            canonicalBlocksAdded: ["missing-block": 0]
        ))
        let laterRequestStarted = Latch()
        let laterTemplate = Task {
            await laterRequestStarted.open()
            return try await service.miningTemplate(MiningTemplateRequest())
        }
        await laterRequestStarted.wait()
        await Task.yield()
        await Task.yield()
        await receipt.wait()

        let status = await service.status()
        XCTAssertEqual(status.mempoolCount, 1)
        let template = try await laterTemplate.value
        XCTAssertEqual(
            try template.block.transactions.node?.allKeysAndValues().count,
            1
        )
        await XCTAssertThrowsErrorAsync(
            try await service.submitWork(SubmitWorkRequest(
                workID: stale.workID,
                nonce: 0
            ))
        ) { error in
            XCTAssertEqual(error as? MiningTemplateError, .unknownWork)
        }
    }

    func testServiceKeepsCompetingWorkAfterRuntimeStopAndRestart()
        async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-service-runtime-stop-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storage,
            privateKeyHex: String(repeating: "5c", count: 32)
        )
        let planes = try NodeNetworkPlaneConfigurations(
            overlay: IvyConfig(
                signingKey: configuration.signingKey,
                listenPort: 0,
                stunServers: [],
                mode: .overlay
            )
)
        let runtime = try NodeNetworkRuntime(
            configuration: configuration,
            planeConfigurations: planes
        )
        let process = try await ChainProcess.open(
            configuration: configuration
        )
        let service = makeService(process: process)

        // This is the daemon's runtime-to-service injection. Local work must
        // still reconcile while that runtime is stopped.
        let handlers = ClosureChainInterface(admission: { admission in
            try await service.importNetworkCandidate(
                admission.header,
                authenticatedChildPackage: admission.authenticatedChildPackage,
                contentSource: admission.contentSource
            )
        })
        do {
            try await runtime.start(process: process, chain: handlers)
            await runtime.stop()

            _ = try await service.submitTransaction(SubmitTransactionRequest(
                transaction: try signedTransaction(
                    key: CryptoUtils.generateKeyPair(),
                    chainPath: ["Nexus"]
                )
            ))
            let competing = try await service.miningTemplate(
                MiningTemplateRequest()
            )
            let submittedTemplate = try await service.miningTemplate(
                MiningTemplateRequest()
            )
            let submitted = try await service.submitWork(SubmitWorkRequest(
                workID: submittedTemplate.workID,
                nonce: 0
            ))

            XCTAssertTrue(submitted.accepted)
            let status = await service.status()
            XCTAssertEqual(status.mempoolCount, 0)
            let competingSubmission = try await service.submitWork(
                SubmitWorkRequest(workID: competing.workID, nonce: 0)
            )
            XCTAssertTrue(competingSubmission.accepted)

            try await runtime.start(process: process, chain: handlers)
            await runtime.stop()
        } catch {
            await runtime.stop()
            throw error
        }
    }

    /// Establishes: NODE-MEMPOOL-001.i
    func testRestartRestoresLocalTransactionsButNotPeerTransactions() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-service-mempool-restart-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storage,
            privateKeyHex: String(repeating: "5e", count: 32)
        )
        let local = try signedTransaction(
            key: CryptoUtils.generateKeyPair(),
            chainPath: ["Nexus"]
        )
        let peer = try signedTransaction(
            key: CryptoUtils.generateKeyPair(),
            chainPath: ["Nexus"]
        )

        var process: ChainProcess? = try await ChainProcess.open(
            configuration: configuration
        )
        var service: ChainService? = makeService(process: process!)
        let submitted = try await service!.submitTransaction(
            SubmitTransactionRequest(transaction: local)
        )
        _ = try await service!.submitNetworkTransaction(peer)
        let beforeRestart = await service!.transactionInventoryRoots()
        XCTAssertEqual(beforeRestart.count, 2)

        service = nil
        process = nil
        process = try await ChainProcess.open(configuration: configuration)
        service = makeService(process: process!)
        try await service!.restoreLocalTransactions()

        let restored = await service!.transactionInventoryRoots()
        XCTAssertEqual(restored, [submitted.transactionCID])
    }

    func testCanonicalCommitReconcilesEveryAddedAndRemovedTransaction() async throws {
        let process = try await nexusProcess()
        let service = makeService(process: process)
        let key = CryptoUtils.generateKeyPair()
        let removed = try signedTransaction(
            key: key,
            chainPath: ["Nexus"],
            nonce: 0
        )
        let rewardKey = CryptoUtils.generateKeyPair()
        _ = try await service.submitTransaction(
            SubmitTransactionRequest(transaction: removed)
        )
        let firstTemplate = try await service.miningTemplate(
            MiningTemplateRequest(recipients: [MiningRecipient(
                chainPath: ["Nexus"],
                address: CryptoUtils.createAddress(from: rewardKey.publicKey)
            )])
        )
        let first = try await service.submitWork(SubmitWorkRequest(
            workID: firstTemplate.workID,
            nonce: 0
        ))
        let removedBlockCID = try XCTUnwrap(first.tipCID)

        let addedFirst = try signedTransaction(
            key: CryptoUtils.generateKeyPair(),
            chainPath: ["Nexus"]
        )
        _ = try await service.submitTransaction(
            SubmitTransactionRequest(transaction: addedFirst)
        )
        let addedTemplate = try await service.miningTemplate(
            MiningTemplateRequest()
        )
        _ = try await service.submitWork(SubmitWorkRequest(
            workID: addedTemplate.workID,
            nonce: 0
        ))
        let addedBlock = try await process.canonicalTipBlock()
        let addedBlockCID = try BlockHeader(node: addedBlock).rawCID
        let addedSecond = try signedTransaction(
            key: CryptoUtils.generateKeyPair(),
            chainPath: ["Nexus"]
        )
        _ = try await service.submitTransaction(
            SubmitTransactionRequest(transaction: addedSecond)
        )
        let descendantTemplate = try await service.miningTemplate(
            MiningTemplateRequest()
        )
        _ = try await service.submitWork(SubmitWorkRequest(
            workID: descendantTemplate.workID,
            nonce: solvedNonce(for: descendantTemplate)
        ))
        let addedDescendant = try await process.canonicalTipBlock()
        let addedDescendantCID = try BlockHeader(node: addedDescendant).rawCID

        let outstanding = try await service.miningTemplate(
            MiningTemplateRequest()
        )
        let receipt = await service.enqueueCanonicalCommit(ChainCommit(
            tipHash: addedDescendantCID,
            canonicalBlocksAdded: [
                addedBlockCID: addedBlock.height,
                addedDescendantCID: addedDescendant.height,
            ],
            canonicalBlocksRemoved: [removedBlockCID]
        ))
        await receipt.wait()

        let outstandingSubmission = try await service.submitWork(
            SubmitWorkRequest(
                workID: outstanding.workID,
                nonce: solvedNonce(for: outstanding)
            )
        )
        XCTAssertTrue(outstandingSubmission.accepted)

        let status = await service.status()
        // This synthetic projection says a spent transaction was removed
        // without changing the real canonical state. Authoritative Lattice
        // preflight therefore rejects it instead of resurrecting it.
        XCTAssertEqual(status.mempoolCount, 0)
    }

    func testTemplateOmitsTransactionItsPolicyRejectsAtTheBlockTimestamp() async throws {
        // Transaction policy: accept iff the block timestamp (context offset
        // 19) is at least 1_000_000 ms. Preflight projects `now`, so the
        // transaction is pooled as ready; the child template is stamped from
        // its carrier (~2 ms here), where the policy rejects it. The template
        // must omit it rather than build an invalid block, and keep it pooled.
        let module = try WasmPolicyModuleHeader(node: WasmPolicyModule(bytes: XCTUnwrap(Data(hex:
            "0061736d01000000010c0260017f017f60027f7f017f03030200010503010001073903066d656d6f727902000d6c6174746963655f616c6c6f6300001c6c6174746963655f76616c69646174655f7472616e73616374696f6e00010a370205004180080b2f02017f017e03402003420886200041136a20026a310000842103200241016a22024108490d000b200342c0843d590b"
        ))))
        let spec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1,
            halvingInterval: 100,
            halfLife: 10,
            wasmPolicies: [WasmPolicyRef(moduleCID: module.rawCID, scope: .transaction)]
        )
        let fixture = try await activeChildService(spec: spec, policyModules: [module])
        let key = CryptoUtils.generateKeyPair()
        let body = TransactionBody(
            accountActions: [],
            actions: [Action(key: "release", oldValue: nil, newValue: "escrow")],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: key.publicKey)],
            nonce: 0,
            chainPath: ["Nexus", "Payments"]
        )
        let bodyHeader = try HeaderImpl(node: body)
        let transaction = Transaction(
            signatures: [key.publicKey: try XCTUnwrap(TransactionSigning.sign(
                bodyHeader: bodyHeader,
                privateKeyHex: key.privateKey
            ))],
            body: bodyHeader
        )
        let submission = try await fixture.service.submitTransaction(
            SubmitTransactionRequest(transaction: transaction)
        )
        XCTAssertEqual(submission.mempoolCount, 1)

        let candidate = try await fixture.service.miningCandidate(
            for: ChildCandidateRequestContext(
                parentCarrier: fixture.parentCarrier,
                recipients: []
            ),
            parentContentSource: FetcherContentSource(fixture.parent)
        )
        XCTAssertLessThan(candidate.block.timestamp, 1_000_000)
        XCTAssertEqual(candidate.block.transactions.node?.count, 0)
        let status = await fixture.service.status()
        XCTAssertEqual(status.mempoolCount, 1)
    }

    func testTemplateUsesLogicalBlockVolumeSizeAtExactBoundary() async throws {
        let key = CryptoUtils.generateKeyPair()
        let body = TransactionBody(
            accountActions: [],
            actions: [Action(
                key: "payload",
                oldValue: nil,
                newValue: String(repeating: "x", count: 8_192)
            )],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: key.publicKey)],
            nonce: 0,
            chainPath: ["Nexus", "Payments"]
        )
        let bodyHeader = try HeaderImpl(node: body)
        let transaction = Transaction(
            signatures: [key.publicKey: try XCTUnwrap(TransactionSigning.sign(
                bodyHeader: bodyHeader,
                privateKeyHex: key.privateKey
            ))],
            body: bodyHeader
        )
        func spec(maxBlockSize: Int) -> ChainSpec {
            ChainSpec(
                maxNumberOfTransactionsPerBlock: 100,
                maxStateGrowth: 100_000,
                maxBlockSize: maxBlockSize,
                premine: 0,
                targetBlockTime: 1_000,
                initialReward: 1,
                halvingInterval: 100,
                halfLife: 10
            )
        }
        func candidate(
            maxBlockSize: Int
        ) async throws -> (DirectChildCandidate, ChainServiceStatusResponse) {
            let fixture = try await activeChildService(
                spec: spec(maxBlockSize: maxBlockSize)
            )
            _ = try await fixture.service.submitTransaction(
                SubmitTransactionRequest(transaction: transaction)
            )
            let candidate = try await fixture.service.miningCandidate(
                for: ChildCandidateRequestContext(
                    parentCarrier: fixture.parentCarrier,
                    recipients: []
                ),
                parentContentSource: FetcherContentSource(fixture.parent)
            )
            return (candidate, await fixture.service.status())
        }

        let sizing = try await activeChildService(spec: spec(maxBlockSize: 1_000_000))
        _ = try await sizing.service.submitTransaction(
            SubmitTransactionRequest(transaction: transaction)
        )
        let sizedCandidate = try await sizing.service.miningCandidate(
            for: ChildCandidateRequestContext(
                parentCarrier: sizing.parentCarrier,
                recipients: []
            ),
            parentContentSource: FetcherContentSource(sizing.parent)
        )
        let logicalSize = try await sizedCandidate.block.logicalContentByteSize(
            fetcher: sizing.process
        )
        XCTAssertGreaterThan(logicalSize, try XCTUnwrap(sizedCandidate.block.toData()).count)

        let exact = try await candidate(maxBlockSize: logicalSize)
        XCTAssertEqual(exact.0.block.transactions.node?.count, 1)
        XCTAssertEqual(exact.1.mempoolCount, 1)

        let oneOver = try await candidate(maxBlockSize: logicalSize - 1)
        XCTAssertEqual(oneOver.0.block.transactions.node?.count, 0)
        XCTAssertEqual(oneOver.1.mempoolCount, 1)
    }

    func testTemplateSelectsLargestFittingTransactionPrefix() async throws {
        let key = CryptoUtils.generateKeyPair()
        let signer = CryptoUtils.createAddress(from: key.publicKey)
        let transactions = try (0..<7).map { index in
            let body = TransactionBody(
                accountActions: [],
                actions: [Action(
                    key: "payload-\(index)",
                    oldValue: nil,
                    newValue: String(repeating: "x", count: 2_048)
                )],
                depositActions: [],
                genesisActions: [],
                receiptActions: [],
                withdrawalActions: [],
                signers: [signer],
                nonce: UInt64(index),
                chainPath: ["Nexus", "Payments"]
            )
            let header = try HeaderImpl(node: body)
            return Transaction(
                signatures: [key.publicKey: try XCTUnwrap(
                    TransactionSigning.sign(
                        bodyHeader: header,
                        privateKeyHex: key.privateKey
                    )
                )],
                body: header
            )
        }
        func spec(_ maxBlockSize: Int) -> ChainSpec {
            ChainSpec(
                maxNumberOfTransactionsPerBlock: 100,
                maxStateGrowth: 100_000,
                maxBlockSize: maxBlockSize,
                premine: 0,
                targetBlockTime: 1_000,
                initialReward: 1,
                halvingInterval: 100,
                halfLife: 10
            )
        }
        func candidate(
            transactions: ArraySlice<Transaction>,
            maxBlockSize: Int
        ) async throws -> DirectChildCandidate {
            let fixture = try await activeChildService(spec: spec(maxBlockSize))
            for transaction in transactions {
                _ = try await fixture.service.submitTransaction(
                    SubmitTransactionRequest(transaction: transaction)
                )
            }
            return try await fixture.service.miningCandidate(
                for: ChildCandidateRequestContext(
                    parentCarrier: fixture.parentCarrier,
                    recipients: []
                ),
                parentContentSource: FetcherContentSource(fixture.parent)
            )
        }

        let sizing = try await activeChildService(spec: spec(1_000_000))
        for transaction in transactions.prefix(6) {
            _ = try await sizing.service.submitTransaction(
                SubmitTransactionRequest(transaction: transaction)
            )
        }
        let six = try await sizing.service.miningCandidate(
            for: ChildCandidateRequestContext(
                parentCarrier: sizing.parentCarrier,
                recipients: []
            ),
            parentContentSource: FetcherContentSource(sizing.parent)
        )
        let sixSize = try await six.block.logicalContentByteSize(
            fetcher: sizing.process
        )

        let fullSizing = try await activeChildService(spec: spec(1_000_000))
        for transaction in transactions {
            _ = try await fullSizing.service.submitTransaction(
                SubmitTransactionRequest(transaction: transaction)
            )
        }
        let seven = try await fullSizing.service.miningCandidate(
            for: ChildCandidateRequestContext(
                parentCarrier: fullSizing.parentCarrier,
                recipients: []
            ),
            parentContentSource: FetcherContentSource(fullSizing.parent)
        )
        let sevenSize = try await seven.block.logicalContentByteSize(
            fetcher: fullSizing.process
        )
        XCTAssertGreaterThan(sevenSize, sixSize)

        let maximal = try await candidate(
            transactions: transactions[...],
            maxBlockSize: sixSize + (sevenSize - sixSize) / 2
        )
        XCTAssertEqual(maximal.block.transactions.node?.count, 6)
    }

    func testTemplateOmitsOversizedOptionalChildren() async throws {
        func spec(_ maxBlockSize: Int) -> ChainSpec {
            ChainSpec(
                maxNumberOfTransactionsPerBlock: 100,
                maxStateGrowth: 100_000,
                maxBlockSize: maxBlockSize,
                premine: 0,
                targetBlockTime: 1_000,
                initialReward: 1,
                halvingInterval: 100,
                halfLife: 10
            )
        }

        func childService(
            _ fixture: ActiveChildServiceFixture,
            directories: [String]
        ) async throws -> ChainService {
            let service = makeService(process: fixture.process)
            try await service.attachStubChildren(
                directories, on: fixture.process
            ) { context in
                let genesis = try await BlockBuilder.buildChildGenesis(
                    spec: NexusGenesis.spec,
                    parentState: context.parentCarrier.prevState,
                    timestamp: context.parentCarrier.timestamp,
                    target: .max,
                    fetcher: fixture.process
                )
                let child = try await BlockBuilder.buildBlock(
                    previous: genesis,
                    transactions: [],
                    parentChainBlock: context.parentCarrier,
                    timestamp: context.parentCarrier.timestamp + 1,
                    fetcher: fixture.process
                )
                return directories.map {
                    DirectChildCandidate(directory: $0, block: child)
                }
            }
            return service
        }

        func candidate(
            maxBlockSize: Int,
            childDirectories: [String],
            transaction: Transaction? = nil
        ) async throws -> (DirectChildCandidate, ChainProcess) {
            let fixture = try await activeChildService(spec: spec(maxBlockSize))
            let service = try await childService(fixture, directories: childDirectories)
            if let transaction {
                _ = try await service.submitTransaction(
                    SubmitTransactionRequest(transaction: transaction)
                )
            }
            return (
                try await service.miningCandidate(
                    for: ChildCandidateRequestContext(
                        parentCarrier: fixture.parentCarrier,
                        recipients: []
                    ),
                    parentContentSource: FetcherContentSource(fixture.parent)
                ),
                fixture.process
            )
        }

        let empty = try await candidate(
            maxBlockSize: 1_000_000,
            childDirectories: []
        )
        let withChild = try await candidate(
            maxBlockSize: 1_000_000,
            childDirectories: ["Grandchild"]
        )
        let emptySize = try await empty.0.block.logicalContentByteSize(
            fetcher: empty.1
        )
        let childSize = try await withChild.0.block.logicalContentByteSize(
            fetcher: withChild.1
        )
        XCTAssertLessThan(emptySize, childSize)

        let omitted = try await candidate(
            maxBlockSize: emptySize,
            childDirectories: ["Grandchild"]
        )
        XCTAssertEqual(omitted.0.block.children.node?.count, 0)

        let key = CryptoUtils.generateKeyPair()
        let transaction = try signedTransaction(
            key: key,
            chainPath: ["Nexus", "Payments"],
            actions: [Action(
                key: "payload",
                oldValue: nil,
                newValue: String(repeating: "x", count: 8_192)
            )]
        )
        let transactionOnly = try await candidate(
            maxBlockSize: 1_000_000,
            childDirectories: [],
            transaction: transaction
        )
        let transactionSize = try await transactionOnly.0.block
            .logicalContentByteSize(fetcher: transactionOnly.1)
        let saturatedLimit = max(transactionSize, childSize)
        let childFirst = try await candidate(
            maxBlockSize: saturatedLimit,
            childDirectories: ["Grandchild"],
            transaction: transaction
        )
        XCTAssertEqual(childFirst.0.block.children.node?.count, 1)
        XCTAssertEqual(childFirst.0.block.transactions.node?.count, 0)

        let oneRotating = try await candidate(
            maxBlockSize: 1_000_000,
            childDirectories: ["A"]
        )
        let twoRotating = try await candidate(
            maxBlockSize: 1_000_000,
            childDirectories: ["A", "B"]
        )
        let oneRotatingSize = try await oneRotating.0.block
            .logicalContentByteSize(fetcher: oneRotating.1)
        let twoRotatingSize = try await twoRotating.0.block
            .logicalContentByteSize(fetcher: twoRotating.1)
        XCTAssertLessThan(oneRotatingSize, twoRotatingSize)

        let stableFixture = try await activeChildService(
            spec: spec(oneRotatingSize)
        )
        let stableService = try await childService(
            stableFixture,
            directories: ["A", "B"]
        )
        func scheduledDirectory() async throws -> String {
            let candidate = try await stableService.miningCandidate(
                for: ChildCandidateRequestContext(
                    parentCarrier: stableFixture.parentCarrier,
                    recipients: []
                ),
                parentContentSource: FetcherContentSource(stableFixture.parent)
            )
            return try XCTUnwrap(
                candidate.block.children.node?.entries.keys.first
            )
        }
        let firstDirectory = try await scheduledDirectory()
        let secondDirectory = try await scheduledDirectory()
        XCTAssertEqual(firstDirectory, secondDirectory)
    }

    /// A grind this host mined that misses Nexus's target but clears the
    /// hosted child's is handed to the child in memory: the child admits its
    /// carried block before `submitWork` answers, and the answer names it.
    func testMinedTargetMissIsAdmittedAtTheHostedChildBeforeSubmitWorkReturns()
        async throws
    {
        let fixture = try await activeChildService(
            spec: NexusGenesis.spec,
            carrierTarget: UInt256.max >> 4
        )
        let merged = await mergedMiningService(fixture)
        let template = try await settledTemplate(merged, MiningTemplateRequest())
        let childBlock = try XCTUnwrap(template.block.children.node?["Payments"]?.node)
        let childCID = try BlockHeader(node: childBlock).rawCID
        let nonce = firstNonce(of: template.block) {
            $0 > template.block.target && $0 <= childBlock.target
        }

        let submitted = try await merged.service.submitWork(SubmitWorkRequest(
            workID: template.workID,
            nonce: nonce
        ))
        XCTAssertEqual(submitted.disposition, .carrier)
        XCTAssertEqual(submitted.durableChildProofs, [
            DirectChildProofSummary(directory: "Payments", childCID: childCID),
        ])
        // Admitted weighed: the child's canonical tip is the carried block.
        let childTip = await fixture.process.canonicalTip()?.cid
        XCTAssertEqual(childTip, childCID)
    }

    /// The fold hands a hosted grandchild its composed proof whatever the
    /// child decided: here the child refuses its block (the proof names
    /// another block), and the grandchild still receives
    /// `proof.composing(hop:)` from the child's in-memory block.
    func testMinedHandoffComposesForTheGrandchildWhateverTheChildDecided()
        async throws
    {
        let fixture = try await activeChildService(spec: NexusGenesis.spec)
        let payments = makeService(
            process: fixture.process,
            parentLevel: LocalParentLevel(fixture.parent)
        )
        let received = ReceivedProofs()
        let grandchildCID = GrandchildCID()
        try await payments.attachStubChildren(
            ["Grandchild"],
            on: fixture.process,
            admit: { block, proof in
                await received.record(block, proof)
                return true
            }
        ) { context in
            let genesis = try await BlockBuilder.buildChildGenesis(
                spec: NexusGenesis.spec,
                parentState: context.parentCarrier.prevState,
                timestamp: context.parentCarrier.timestamp,
                target: .max,
                fetcher: fixture.process
            )
            let grandchild = try await BlockBuilder.buildBlock(
                previous: genesis,
                transactions: [],
                parentChainBlock: context.parentCarrier,
                timestamp: context.parentCarrier.timestamp + 1,
                fetcher: fixture.process
            )
            await grandchildCID.set(try BlockHeader(node: grandchild).rawCID)
            return [DirectChildCandidate(directory: "Grandchild", block: grandchild)]
        }
        let merged = await mergedMiningService(fixture, child: payments)
        let template = try await settledTemplate(merged, MiningTemplateRequest())
        let childBlock = try XCTUnwrap(template.block.children.node?["Payments"]?.node)
        XCTAssertNotNil(childBlock.children.node?["Grandchild"])
        let hop = try await ChildBlockProof.generate(
            rootHeader: BlockHeader(node: childBlock),
            childDirectory: "Grandchild",
            fetcher: fixture.process
        )
        // A proof of the grandchild, not of `childBlock`: the child refuses.
        let wrong = hop

        let admitted = await payments.admitMinedCarriage(block: childBlock, proof: wrong)
        XCTAssertFalse(admitted)
        let handed = await received.all()
        XCTAssertEqual(handed.count, 1)
        let expected = wrong.composing(hop: hop)
        let expectedCID = await grandchildCID.value
        XCTAssertEqual(handed.first?.cid, expectedCID)
        XCTAssertEqual(handed.first?.proof.rootCID, expected.rootCID)
        XCTAssertEqual(handed.first?.proof.directoryPath, expected.directoryPath)
        XCTAssertEqual(
            handed.first?.proof.entries.map(\.cid), expected.entries.map(\.cid)
        )
    }

    /// A nonce that clears only the child's easier target must not close the
    /// work: the miner keeps searching the same assignment toward the parent's
    /// harder target, and a later parent-clearing nonce for the same workID
    /// has to produce the parent block. Consuming the template on the carrier
    /// throws that nonce away as `unknownWork`.
    func testCarrierSubmissionKeepsWorkOpenForTheParentTarget() async throws {
        let process = try await nexusProcess()
        let genesis = try await process.canonicalTipBlock()
        let activeChild = try await anchoredChildGenesis(
            parent: process,
            parentGenesis: genesis,
            childTimestamp: 1,
            carrierNonce: 0,
            carrierTarget: UInt256.max >> 12
        )
        let publishedBlocks = PublishedBlocks()
        let service = makeService(
            process: process,
            acceptedBlockPublisher: { blockCID in
                await publishedBlocks.record(blockCID)
            }
        )
        try await service.attachStubChildren(["Payments"], on: process) { context in
            let child = try await BlockBuilder.buildBlock(
                previous: activeChild.block,
                transactions: [],
                parentChainBlock: context.parentCarrier,
                timestamp: context.parentCarrier.timestamp,
                fetcher: process
            )
            return [DirectChildCandidate(
                directory: "Payments",
                block: child
            )]
        }
        let template = try await service.miningTemplate(MiningTemplateRequest())
        XCTAssertLessThan(
            template.block.target,
            template.searchTarget,
            "the parent target must be harder than the scheduled child target"
        )
        XCTAssertEqual(template.targets, [template.searchTarget, template.block.target])

        // The parent target is hard: scan with a midstate, then let the node's
        // own hash decide every submission below.
        let carrierNonce = firstNonce(of: template.block, from: 0) {
            $0 > template.block.target
        }
        XCTAssertGreaterThan(
            template.block.replacingNonce(carrierNonce).proofOfWorkHash(),
            template.block.target
        )
        let carried = try await service.submitWork(SubmitWorkRequest(
            workID: template.workID,
            nonce: carrierNonce
        ))
        XCTAssertEqual(carried.disposition, .carrier)
        XCTAssertFalse(carried.accepted)
        let tipAfterCarrier = await process.status().tipCID
        XCTAssertEqual(tipAfterCarrier, template.block.parent?.rawCID)

        let parentNonce = firstNonce(of: template.block, from: carrierNonce + 1) {
            $0 <= template.block.target
        }
        XCTAssertLessThanOrEqual(
            template.block.replacingNonce(parentNonce).proofOfWorkHash(),
            template.block.target
        )
        let parent = try await service.submitWork(SubmitWorkRequest(
            workID: template.workID,
            nonce: parentNonce
        ))
        XCTAssertTrue(parent.accepted)
        XCTAssertEqual(parent.disposition, .canonicalized)
        let minedCID = try BlockHeader(
            node: template.block.replacingNonce(parentNonce)
        ).rawCID
        XCTAssertEqual(parent.tipCID, minedCID)
        let published = await publishedBlocks.all()
        XCTAssertEqual(published, [minedCID])

        // The parent block consumes the work.
        await XCTAssertThrowsErrorAsync(
            try await service.submitWork(SubmitWorkRequest(
                workID: template.workID,
                nonce: parentNonce
            ))
        ) { error in
            XCTAssertEqual(error as? MiningTemplateError, .unknownWork)
        }
    }

    /// The full node path on a fresh Nexus whose genesis is at the maximum
    /// target, by default: every block commits the scheduled target, the
    /// search is the miner's filter, a hash that meets the filter is a valid
    /// block the node canonicalizes, and a hash that clears the committed
    /// target but misses the filter is refused before admission.
    func testMinimumWorkByDefaultMinesScheduledBlocksAtTheFilter() async throws {
        let work = UInt256(1) << 10
        let filterTarget = minimumWorkTarget(work)
        let process = try await nexusProcess()
        let service = makeService(process: process)
        let request = MiningTemplateRequest(minimumWork: [MiningMinimumWork(
            chainPath: ["Nexus"],
            work: work
        )])
        // The committed target is the schedule. Block 1 commits the genesis
        // maximum, and from there the schedule hardens a little each block
        // because the harness mines far faster than `targetBlockTime` -- it is
        // ahead of schedule, so the absolute schedule answers by hardening.
        // It never eases, and stays far easier than the miner's filter.
        var scheduledSoFar = UInt256.max
        for _ in 0..<4 {
            let previous = try await process.canonicalTipBlock()
            let template = try await service.miningTemplate(request)
            XCTAssertEqual(template.block.target, previous.nextTarget)
            XCTAssertLessThanOrEqual(template.block.target, scheduledSoFar)
            XCTAssertGreaterThan(template.block.target, filterTarget)
            scheduledSoFar = template.block.target
            XCTAssertEqual(template.searchTarget, filterTarget)
            XCTAssertEqual(template.targets, [filterTarget])

            // Clears the committed target (every hash does) but not the
            // filter: the miner declined this block, so the node refuses it.
            let declined = firstNonce(of: template.block, from: 0) {
                $0 > filterTarget
            }
            await XCTAssertThrowsErrorAsync(
                try await service.submitWork(SubmitWorkRequest(
                    workID: template.workID,
                    nonce: declined
                ))
            ) { error in
                XCTAssertEqual(
                    error as? MiningTemplateError,
                    .missesSearchTarget
                )
            }
            let tipAfterRefusal = await process.status().tipCID
            XCTAssertEqual(tipAfterRefusal, try BlockHeader(node: previous).rawCID)

            // Meeting the filter necessarily meets the committed target, and
            // the node's own admission agrees.
            let nonce = firstNonce(of: template.block, from: 0) {
                $0 <= template.searchTarget
            }
            let response = try await service.submitWork(SubmitWorkRequest(
                workID: template.workID,
                nonce: nonce
            ))
            XCTAssertEqual(response.disposition, .canonicalized)
            let tip = try await process.canonicalTipBlock()
            XCTAssertEqual(tip.target, template.block.target)
            XCTAssertGreaterThan(tip.target, filterTarget)
            XCTAssertLessThanOrEqual(tip.proofOfWorkHash(), filterTarget)
        }
    }

    /// The minimum work is the miner's choice, not a rule the node enforces:
    /// after blocks committed at the minimum-work target it still accepts
    /// another producer's block at the scheduled (easier) target.
    /// The invariant this wiring rests on: the anchor carried in consensus
    /// state and the anchor recovered by walking the ancestry are the SAME
    /// anchor, so a node that has the parent in its graph and a node that does
    /// not compute the identical `nextTarget`.
    ///
    /// Nothing else asserts this directly. It is otherwise caught only second
    /// hand — a wrong anchor yields a target the node's own validator rejects,
    /// which surfaces as some unrelated block failing to be accepted, several
    /// steps from the cause.
    func testCarriedAnchorAndWalkedAnchorScheduleTheSameTarget() async throws {
        let process = try await nexusProcess()

        for _ in 0..<4 {
            let previous = try await process.canonicalTipBlock()
            let previousHash = try BlockHeader(node: previous).rawCID
            let carried = await process.difficultyAnchor(
                forBlockHash: previousHash
            )
            if previous.height == 0 {
                XCTAssertNil(
                    carried,
                    "genesis precedes the schedule and carries no anchor"
                )
            } else {
                XCTAssertEqual(
                    carried?.blockHeight, 1,
                    "every block's anchor is its height-1 ancestor"
                )
            }

            // Same parent, same timestamp: the only difference is where the
            // anchor came from.
            //
            // Space the blocks by half a target block time rather than 1ms.
            // The schedule reads `elapsed` since the ANCHOR, and elapsed
            // clamps at zero, so with 1ms spacing every candidate sits at
            // essentially zero elapsed and two different anchor timestamps
            // round to the same fixed-point exponent -- the comparison then
            // cannot see an anchor being wrong at all.
            let timestamp = previous.timestamp + 1_800_000
            let threaded = try await BlockBuilder.buildBlock(
                previous: previous,
                timestamp: timestamp,
                difficultyAnchor: carried,
                fetcher: process
            )
            let walked = try await BlockBuilder.buildBlock(
                previous: previous,
                timestamp: timestamp,
                difficultyAnchor: nil,
                fetcher: process
            )
            XCTAssertEqual(
                threaded.nextTarget, walked.nextTarget,
                "carried and walked anchors must schedule the same target at height \(threaded.height)"
            )
            XCTAssertEqual(threaded.target, walked.target)

            let mined = threaded.replacingNonce(
                firstNonce(of: threaded, from: 0) { $0 <= threaded.target }
            )
            let outcome = try await process.importBlock(BlockHeader(node: mined))
            XCTAssertTrue(
                outcome.decision.isAccepted,
                "a block scheduled from the carried anchor must satisfy the validator"
            )
        }
    }

    func testNodeAcceptsAnUnfilteredBlockAtTheScheduledTarget() async throws {
        let work = UInt256(1) << 10
        let process = try await nexusProcess()
        let service = makeService(process: process)
        let template = try await service.miningTemplate(MiningTemplateRequest(
            minimumWork: [MiningMinimumWork(chainPath: ["Nexus"], work: work)]
        ))
        // The block commits the SCHEDULE; the filter only narrows the search,
        // so the nonce has to clear the search target, not the block's.
        XCTAssertLessThan(
            template.searchTarget, template.block.target,
            "precondition: the filter is harder than the schedule here"
        )
        let nonce = firstNonce(of: template.block, from: 0) {
            $0 <= template.searchTarget
        }
        let filtered = try await service.submitWork(SubmitWorkRequest(
            workID: template.workID,
            nonce: nonce
        ))
        XCTAssertEqual(filtered.disposition, .canonicalized)

        let tip = try await process.canonicalTipBlock()
        // Block 1 commits the scheduled target -- the genesis maximum -- not
        // the filter. The filter shaped only what this miner searched for.
        XCTAssertEqual(tip.target, UInt256.max)
        XCTAssertLessThanOrEqual(tip.proofOfWorkHash(), minimumWorkTarget(work))

        // Now hand the node a HARDER filter, and do not commit it. The point of
        // this test is an asymmetry, so the filter has to be one the node was
        // actually GIVEN: a filter this test merely computes proves nothing,
        // because the node would refuse nothing either way.
        let harderWork = work << 4
        let harderFilter = minimumWorkTarget(harderWork)
        let harderTemplate = try await service.miningTemplate(
            MiningTemplateRequest(
                minimumWork: [MiningMinimumWork(
                    chainPath: ["Nexus"], work: harderWork
                )]
            )
        )
        XCTAssertEqual(harderTemplate.searchTarget, harderFilter)
        XCTAssertGreaterThan(
            harderTemplate.block.target, harderFilter,
            "precondition: the committed schedule is easier than the filter"
        )

        // A hash that clears the committed target but misses the filter. The
        // miner's own search refuses it...
        let missesFilter = firstNonce(of: harderTemplate.block, from: 0) {
            $0 <= harderTemplate.block.target && $0 > harderFilter
        }
        await XCTAssertThrowsErrorAsync(
            try await service.submitWork(SubmitWorkRequest(
                workID: harderTemplate.workID,
                nonce: missesFilter
            ))
        ) { error in
            XCTAssertEqual(error as? MiningTemplateError, .missesSearchTarget)
        }

        // ...and yet the node admits that very block. The filter bounds what
        // this miner searches for; it is not a rule the node enforces on work
        // that reaches it.
        let unfiltered = harderTemplate.block.replacingNonce(missesFilter)
        XCTAssertGreaterThan(
            unfiltered.proofOfWorkHash(), harderFilter,
            "the block must genuinely miss the filter, or this proves nothing"
        )
        XCTAssertLessThanOrEqual(
            unfiltered.proofOfWorkHash(), unfiltered.target,
            "and must still carry the work its committed target demands"
        )
        let outcome = try await process.importBlock(try BlockHeader(node: unfiltered))
        XCTAssertTrue(
            outcome.decision.isAccepted,
            "minimum work is the miner's choice, not a rule the node enforces"
        )
    }

    /// Merged mining, by default: every block in the template commits its
    /// scheduled target, and each chain's minimum work shapes only the
    /// thresholds the miner searches for. The node classifies a submitted
    /// nonce against those thresholds — a hash that clears a chain's
    /// committed target but misses its minimum work advances nothing.
    func testMergedTemplateAppliesEachChainsOwnMinimumWork() async throws {
        // The parent already retargeted to a harder schedule (about 2^-12 of
        // the maximum, so every nonce search below takes a few thousand
        // hashes at most on average); its child is a fresh chain still at the
        // maximum genesis target.
        let fixture = try await activeChildService(
            spec: NexusGenesis.spec,
            carrierTarget: UInt256.max >> 12
        )
        let parentTip = try await fixture.parent.canonicalTipBlock()
        let parentTarget = parentTip.nextTarget
        XCTAssertLessThan(parentTarget, UInt256.max >> 11)
        let childWork = UInt256(1) << 4
        let childTarget = minimumWorkTarget(childWork)
        // Asking for less work than the parent's own schedule changes nothing
        // there: the filter never makes a search easier.
        let parentWork = UInt256(1) << 8
        XCTAssertGreaterThan(minimumWorkTarget(parentWork), parentTarget)
        let merged = await mergedMiningService(fixture)
        let template = try await settledTemplate(merged,
            MiningTemplateRequest(minimumWork: [
                MiningMinimumWork(chainPath: ["Nexus"], work: parentWork),
                MiningMinimumWork(
                    chainPath: ["Nexus", "Payments"],
                    work: childWork
                ),
            ])
        )
        let lastChildCandidate = merged.child.readyCandidate()?.candidate.block
        let childBlock = try XCTUnwrap(lastChildCandidate)
        let childTip = try await fixture.process.canonicalTipBlock()
        XCTAssertEqual(template.block.target, parentTarget)
        XCTAssertEqual(childBlock.target, childTip.nextTarget)
        XCTAssertEqual(childBlock.target, .max)
        XCTAssertEqual(template.searchTarget, childTarget)
        XCTAssertEqual(template.targets, [childTarget, parentTarget])
        XCTAssertFalse(template.targets.contains(childBlock.target))

        // This hash clears the child's committed (maximum) target and misses
        // its minimum work: no child block.
        let tooEasy = firstNonce(of: template.block, from: 0) {
            $0 > childTarget
        }
        await XCTAssertThrowsErrorAsync(
            try await merged.service.submitWork(SubmitWorkRequest(
                workID: template.workID,
                nonce: tooEasy
            ))
        ) { error in
            XCTAssertEqual(error as? MiningTemplateError, .missesSearchTarget)
        }
        let tipAfterRefusal = await fixture.parent.status().tipCID
        XCTAssertEqual(tipAfterRefusal, template.block.parent?.rawCID)

        // Between the two thresholds: the child advances, the parent does not.
        let carrierNonce = firstNonce(of: template.block, from: 0) {
            $0 <= childTarget && $0 > parentTarget
        }
        let carried = try await merged.service.submitWork(SubmitWorkRequest(
            workID: template.workID,
            nonce: carrierNonce
        ))
        XCTAssertEqual(carried.disposition, .carrier)

        let parentNonce = firstNonce(
            of: template.block,
            from: carrierNonce + 1
        ) { $0 <= parentTarget }
        let accepted = try await merged.service.submitWork(SubmitWorkRequest(
            workID: template.workID,
            nonce: parentNonce
        ))
        XCTAssertEqual(accepted.disposition, .canonicalized)
        XCTAssertEqual(
            accepted.durableChildProofs.map(\.directory),
            ["Payments"]
        )
    }

    /// One nonce commits every chain at once. With the parent's minimum work
    /// harder than its schedule, a hash that clears only the child's threshold
    /// can still clear the parent's committed target — a valid parent block
    /// the miner declined. The search therefore stops at the parent's
    /// threshold, and such a hash is refused rather than admitted.
    func testMergedSearchStopsAtABindingParentMinimumWork() async throws {
        // Parent schedule about 2^-4 of the maximum, filter 2^8: each nonce
        // search below takes a few hundred hashes on average.
        let fixture = try await activeChildService(
            spec: NexusGenesis.spec,
            carrierTarget: UInt256.max >> 4
        )
        let parentTip = try await fixture.parent.canonicalTipBlock()
        let parentTarget = parentTip.nextTarget
        let parentWork = UInt256(1) << 8
        let parentThreshold = minimumWorkTarget(parentWork)
        XCTAssertLessThan(parentThreshold, parentTarget)
        XCTAssertGreaterThan(parentTarget, UInt256.max >> 5)
        let merged = await mergedMiningService(fixture)
        // No minimum work for the child: its threshold is its schedule.
        let template = try await settledTemplate(merged,
            MiningTemplateRequest(minimumWork: [
                MiningMinimumWork(chainPath: ["Nexus"], work: parentWork),
            ])
        )
        let lastChildCandidate = merged.child.readyCandidate()?.candidate.block
        let childBlock = try XCTUnwrap(lastChildCandidate)
        XCTAssertEqual(template.block.target, parentTarget)
        XCTAssertEqual(childBlock.target, .max)
        XCTAssertEqual(template.searchTarget, parentThreshold)
        XCTAssertEqual(template.targets, [parentThreshold])

        let declined = firstNonce(of: template.block, from: 0) {
            $0 <= parentTarget && $0 > parentThreshold
        }
        await XCTAssertThrowsErrorAsync(
            try await merged.service.submitWork(SubmitWorkRequest(
                workID: template.workID,
                nonce: declined
            ))
        ) { error in
            XCTAssertEqual(error as? MiningTemplateError, .missesSearchTarget)
        }
        let tipAfterRefusal = await fixture.parent.status().tipCID
        XCTAssertEqual(tipAfterRefusal, template.block.parent?.rawCID)

        let nonce = firstNonce(of: template.block, from: 0) {
            $0 <= parentThreshold
        }
        let accepted = try await merged.service.submitWork(SubmitWorkRequest(
            workID: template.workID,
            nonce: nonce
        ))
        XCTAssertEqual(accepted.disposition, .canonicalized)
        XCTAssertEqual(
            accepted.durableChildProofs.map(\.directory),
            ["Payments"]
        )
    }

    /// The same bound from the other side: a child minimum work harder than
    /// the parent's schedule. A hash that clears the parent's target but not
    /// the child's threshold would publish a parent block committing a child
    /// block at its maximum target — one the miner declined — so the search
    /// stops at the child's threshold.
    func testMergedSearchStopsAtABindingChildMinimumWork() async throws {
        // Parent schedule about 2^-4 of the maximum, filter 2^8: each nonce
        // search below takes a few hundred hashes on average.
        let fixture = try await activeChildService(
            spec: NexusGenesis.spec,
            carrierTarget: UInt256.max >> 4
        )
        let parentTip = try await fixture.parent.canonicalTipBlock()
        let parentTarget = parentTip.nextTarget
        let childWork = UInt256(1) << 8
        let childThreshold = minimumWorkTarget(childWork)
        XCTAssertLessThan(childThreshold, parentTarget)
        XCTAssertGreaterThan(parentTarget, UInt256.max >> 5)
        let merged = await mergedMiningService(fixture)
        let template = try await settledTemplate(merged,
            MiningTemplateRequest(minimumWork: [
                MiningMinimumWork(
                    chainPath: ["Nexus", "Payments"],
                    work: childWork
                ),
            ])
        )
        let lastChildCandidate = merged.child.readyCandidate()?.candidate.block
        let childBlock = try XCTUnwrap(lastChildCandidate)
        XCTAssertEqual(template.block.target, parentTarget)
        XCTAssertEqual(childBlock.target, .max)
        XCTAssertEqual(template.searchTarget, childThreshold)
        XCTAssertEqual(template.targets, [childThreshold])

        let declined = firstNonce(of: template.block, from: 0) {
            $0 <= parentTarget && $0 > childThreshold
        }
        await XCTAssertThrowsErrorAsync(
            try await merged.service.submitWork(SubmitWorkRequest(
                workID: template.workID,
                nonce: declined
            ))
        ) { error in
            XCTAssertEqual(error as? MiningTemplateError, .missesSearchTarget)
        }
        let tipAfterRefusal = await fixture.parent.status().tipCID
        XCTAssertEqual(tipAfterRefusal, template.block.parent?.rawCID)

        let nonce = firstNonce(of: template.block, from: 0) {
            $0 <= childThreshold
        }
        let accepted = try await merged.service.submitWork(SubmitWorkRequest(
            workID: template.workID,
            nonce: nonce
        ))
        XCTAssertEqual(accepted.disposition, .canonicalized)
        XCTAssertEqual(
            accepted.durableChildProofs.map(\.directory),
            ["Payments"]
        )
    }

    /// A level carries a child's snapshot only when it pays the miner's
    /// recipient for that chain: one paying anyone else is dropped, even
    /// when it was published as built on the plan.
    func testChildCandidatePayingTheWrongRecipientIsDropped() async throws {
        let planned = CryptoUtils.createAddress(
            from: CryptoUtils.generateKeyPair().publicKey
        )
        let other = CryptoUtils.createAddress(
            from: CryptoUtils.generateKeyPair().publicKey
        )
        for (paid, carried) in [(other, false), (planned, true)] {
            let fixture = try await activeChildService(spec: NexusGenesis.spec)
            let payments = makeService(
                process: fixture.process,
                parentLevel: LocalParentLevel(fixture.parent)
            )
            let recipients = [MiningRecipient(
                chainPath: ["Nexus", "Payments", "Grandchild"], address: planned
            )]
            try await payments.attachStubChildren(
                ["Grandchild"],
                on: fixture.process,
                plan: DescendantPlan(recipients: recipients)
            ) { context in
                let genesis = try await BlockBuilder.buildChildGenesis(
                    spec: NexusGenesis.spec,
                    parentState: context.parentCarrier.prevState,
                    timestamp: context.parentCarrier.timestamp,
                    target: .max,
                    fetcher: fixture.process
                )
                let grandchild = try await BlockBuilder.buildBlock(
                    previous: genesis,
                    transactions: [],
                    parentChainBlock: context.parentCarrier,
                    timestamp: context.parentCarrier.timestamp + 1,
                    rewardRecipient: paid,
                    fetcher: fixture.process
                )
                return [DirectChildCandidate(
                    directory: "Grandchild",
                    block: grandchild
                )]
            }
            let merged = await mergedMiningService(fixture, child: payments)
            _ = try await settledTemplate(
                merged, MiningTemplateRequest(recipients: recipients)
            )
            let childBlock = try XCTUnwrap(
                merged.child.readyCandidate()?.candidate.block
            )
            XCTAssertEqual(
                childBlock.children.node?["Grandchild"] != nil,
                carried,
                "grandchild paying \(paid == planned ? "the planned" : "another") recipient"
            )
        }
    }

    /// Submission through a three-level hierarchy: a filter on the grandchild
    /// is visible to the Nexus only through the child's witness, and a hash
    /// that clears every committed target but misses that filter is refused
    /// at the Nexus rather than published inside an accepted block.
    func testNestedMinimumWorkBoundsSubmissionThroughTheHierarchy()
        async throws
    {
        // Parent schedule about 2^-4 of the maximum, filter 2^8: each nonce
        // search below takes a few hundred hashes on average.
        let fixture = try await activeChildService(
            spec: NexusGenesis.spec,
            carrierTarget: UInt256.max >> 4
        )
        let parentTarget = try await fixture.parent.canonicalTipBlock()
            .nextTarget
        let work = UInt256(1) << 8
        let threshold = minimumWorkTarget(work)
        XCTAssertLessThan(threshold, parentTarget)
        let payments = makeService(
            process: fixture.process,
            parentLevel: LocalParentLevel(fixture.parent)
        )
        // The grandchild's snapshot is built on its part of the miner's plan.
        try await payments.attachStubChildren(
            ["Grandchild"],
            on: fixture.process,
            plan: DescendantPlan(minimumWork: [MiningMinimumWork(
                chainPath: ["Nexus", "Payments", "Grandchild"], work: work
            )])
        ) { context in
            let genesis = try await BlockBuilder.buildChildGenesis(
                spec: NexusGenesis.spec,
                parentState: context.parentCarrier.prevState,
                timestamp: context.parentCarrier.timestamp,
                target: .max,
                fetcher: fixture.process
            )
            let grandchild = try await BlockBuilder.buildBlock(
                previous: genesis,
                transactions: [],
                parentChainBlock: context.parentCarrier,
                timestamp: context.parentCarrier.timestamp + 1,
                fetcher: fixture.process
            )
            return [DirectChildCandidate(
                directory: "Grandchild",
                block: grandchild
            )]
        }
        let merged = await mergedMiningService(fixture, child: payments)
        let template = try await settledTemplate(merged,
            MiningTemplateRequest(minimumWork: [MiningMinimumWork(
                chainPath: ["Nexus", "Payments", "Grandchild"],
                work: work
            )])
        )
        let lastChildCandidate = merged.child.readyCandidate()?.candidate.block
        let childBlock = try XCTUnwrap(lastChildCandidate)
        let grandchildHeader: BlockHeader? = childBlock.children.node?["Grandchild"]
        XCTAssertEqual(template.block.target, parentTarget)
        XCTAssertEqual(childBlock.target, .max)
        XCTAssertEqual(grandchildHeader?.node?.target, .max)
        XCTAssertEqual(template.searchTarget, threshold)
        XCTAssertEqual(template.targets, [threshold])

        let declined = firstNonce(of: template.block, from: 0) {
            $0 <= parentTarget && $0 > threshold
        }
        await XCTAssertThrowsErrorAsync(
            try await merged.service.submitWork(SubmitWorkRequest(
                workID: template.workID,
                nonce: declined
            ))
        ) { error in
            XCTAssertEqual(error as? MiningTemplateError, .missesSearchTarget)
        }
        let tipAfterRefusal = await fixture.parent.status().tipCID
        XCTAssertEqual(tipAfterRefusal, template.block.parent?.rawCID)

        let nonce = firstNonce(of: template.block, from: 0) { $0 <= threshold }
        let accepted = try await merged.service.submitWork(SubmitWorkRequest(
            workID: template.workID,
            nonce: nonce
        ))
        XCTAssertEqual(accepted.disposition, .canonicalized)
        XCTAssertEqual(
            accepted.durableChildProofs.map(\.directory),
            ["Payments"]
        )
    }

    /// A parent service on the fixture's parent process hosting a child
    /// level on the fixture's child process (or `child`), wired as the host
    /// wires one.
    private func mergedMiningService(
        _ fixture: ActiveChildServiceFixture,
        child: ChainService? = nil,
        wrap: (any ChildLevel) -> any ChildLevel = { $0 }
    ) async -> (service: ChainService, child: ChainService) {
        let childService = child ?? makeService(
            process: fixture.process,
            parentLevel: LocalParentLevel(fixture.parent)
        )
        let service = makeService(process: fixture.parent)
        await host(childService, in: "Payments", under: service, wrap: wrap)
        return (service, childService)
    }

    /// Wires `child` as `parent`'s hosted child level in `directory`, as
    /// `ChainHost` does: the child's rebuilds pass `gate`, and a new
    /// snapshot marks the parent's own rebuild. `wrap` stands in for the
    /// level the parent sees.
    private func host(
        _ child: ChainService,
        in directory: String,
        under parent: ChainService,
        wrap: (any ChildLevel) -> any ChildLevel = { $0 }
    ) async {
        let mailbox = await child.openParentMailbox(
            tipChanged: {},
            serveParentRuns: {},
            candidateChanged: { [weak parent] in
                await parent?.childCandidateChanged()
            }
        )
        await parent.attachChildLevel(wrap(LocalChildLevel(
            directory: directory, mailbox: mailbox, service: child
        )))
    }

    /// Waits until `level`'s snapshot rebuilds from what stands now.
    private func settle(_ level: ChainService) async throws {
        await level.childCandidateChanged()
        try await eventually("the snapshot rebuilds") {
            await level.candidateRebuildIdle()
        }
    }

    /// A template carrying the hosted child's snapshot rebuilt for
    /// `request`'s plan: the first template sends the plan, the child
    /// rebuilds on it, and the second carries what it built.
    private func settledTemplate(
        _ merged: (service: ChainService, child: ChainService),
        _ request: MiningTemplateRequest
    ) async throws -> MiningTemplateResponse {
        _ = try await merged.service.miningTemplate(request)
        try await settle(merged.child)
        return try await merged.service.miningTemplate(request)
    }

    /// Target 0 is met by no hash and Lattice rejects it, so no target can
    /// represent more than `workForTarget(1)` work. Asking for more must be
    /// refused by name, never silently delivered as target 1 — that would
    /// freeze the chain this option exists to keep mining.
    func testUnachievableOrOversizedMinimumWorkIsRefused() async throws {
        let process = try await nexusProcess()
        let service = makeService(process: process)
        let ceiling = workForTarget(UInt256(1))

        await XCTAssertThrowsErrorAsync(
            try await service.miningTemplate(MiningTemplateRequest(
                minimumWork: [MiningMinimumWork(
                    chainPath: ["Nexus"],
                    work: ceiling + UInt256(1)
                )]
            ))
        ) { error in
            XCTAssertEqual(error as? ChainServiceError, .invalidMinimumWork)
        }

        // The ceiling itself is achievable: the hardest valid target.
        let template = try await service.miningTemplate(MiningTemplateRequest(
            minimumWork: [MiningMinimumWork(
                chainPath: ["Nexus"],
                work: ceiling
            )]
        ))
        XCTAssertEqual(template.searchTarget, UInt256(1))

        // A plan past the payload cap `recipients` also honours is a named
        // refusal here, not a child candidate that silently goes missing for
        // a whole round when the wire frame bites instead.
        await XCTAssertThrowsErrorAsync(
            try await service.miningTemplate(MiningTemplateRequest(
                minimumWork: (0..<40_000).map {
                    MiningMinimumWork(
                        chainPath: ["Nexus", "d\($0)"],
                        work: UInt256(1) << 16
                    )
                }
            ))
        ) { error in
            XCTAssertEqual(
                error as? ChainServiceError,
                .minimumWorkPlanTooLarge
            )
        }
    }

    /// A request without minimum work builds the scheduled block, unchanged.
    func testTemplateWithoutMinimumWorkIsTheScheduledBlock() async throws {
        let process = try await nexusProcess()
        let service = makeService(process: process)
        let legacy = try JSONDecoder().decode(
            MiningTemplateRequest.self,
            from: Data(#"{"recipients":[]}"#.utf8)
        )
        XCTAssertTrue(legacy.minimumWork.isEmpty)
        let template = try await service.miningTemplate(legacy)
        let genesis = try await process.canonicalTipBlock()
        let scheduled = try await BlockBuilder.buildBlock(
            previous: genesis,
            timestamp: template.block.timestamp,
            fetcher: process
        )
        XCTAssertEqual(template.block.target, genesis.nextTarget)
        XCTAssertEqual(template.block.toData(), scheduled.toData())
        XCTAssertEqual(
            try JSONEncoder().encode(MiningTemplateRequest()),
            Data(#"{"recipients":[]}"#.utf8)
        )
        // A request from an older miner that still asks for its filter to be
        // committed decodes fine and is simply not honoured: the key is gone,
        // so the block commits the schedule like any other.
        let legacyOptIn = try JSONDecoder().decode(
            MiningTemplateRequest.self,
            from: Data(#"{"recipients":[],"commitMinimumWorkTarget":true}"#.utf8)
        )
        XCTAssertTrue(legacyOptIn.minimumWork.isEmpty)
    }

    /// The template digest names every input of a template: the validated
    /// tip, the mempool, and the child candidates held. Status serves the
    /// same digest a template carries, so a miner comparing the two learns
    /// its work is stale for a change at any level — a child's fresh
    /// candidate as much as this chain's own tip.
    func testTemplateDigestTracksTipMempoolAndChildCandidates() async throws {
        let process = try await nexusProcess()
        let service = makeService(process: process)
        let payments = StubChildLevel(directory: "Payments")
        await service.attachChildLevel(payments)
        let first = try await service.miningTemplate(MiningTemplateRequest())
        let firstStatus = await service.status().templateDigest
        XCTAssertEqual(first.templateDigest, firstStatus, "status serves what the template carries")

        // A child candidate arriving changes the digest without any tip move.
        payments.publish(DirectChildCandidate(
            directory: "Payments", block: try await ongoingChild(on: process)
        ))
        let withChild = try await service.miningTemplate(MiningTemplateRequest())
        XCTAssertNotEqual(withChild.templateDigest, first.templateDigest)
        let withChildStatus = await service.status().templateDigest
        XCTAssertEqual(withChild.templateDigest, withChildStatus)

        // The tip moving changes it too.
        let submitted = try await service.submitWork(SubmitWorkRequest(
            workID: withChild.workID,
            nonce: 0
        ))
        XCTAssertEqual(submitted.disposition, .canonicalized)
        let afterBlock = await service.status().templateDigest
        XCTAssertNotNil(afterBlock)
        XCTAssertNotEqual(afterBlock, withChild.templateDigest)
    }

    func testAuthenticatedProviderSuppliesOrdinaryChildCandidate() async throws {
        let process = try await nexusProcess()
        let parent = try await process.canonicalTipBlock()
        let childGenesis = try await BlockBuilder.buildChildGenesis(
            spec: ChainSpec(
                maxNumberOfTransactionsPerBlock: 100,
                maxStateGrowth: 100_000,
                premine: 0,
                targetBlockTime: 1_000,
                initialReward: 10,
                halvingInterval: 100,
                halfLife: 10
            ),
            parentState: parent.postState,
            transactions: [],
            timestamp: 1,
            target: UInt256.max,
            fetcher: process
        )
        let child = try await BlockBuilder.buildBlock(
            previous: childGenesis,
            timestamp: 2,
            nonce: 0,
            fetcher: process
        )
        let provisionalParents = ProvisionalParents()
        let service = makeService(process: process)
        try await service.attachStubChildren(["Existing"], on: process) { context in
            await provisionalParents.record(context.parentCarrier)
            return [DirectChildCandidate(
                directory: "Existing",
                block: child
            )]
        }

        let template = try await service.miningTemplate(MiningTemplateRequest())
        let recordedProvisional = await provisionalParents.first()
        let provisional = try XCTUnwrap(recordedProvisional)
        // The child built on the tip the template builds on: the provisional
        // carrier shares the template's parent, schedule and `prevState`.
        XCTAssertEqual(provisional.parent?.rawCID, template.block.parent?.rawCID)
        XCTAssertEqual(provisional.target, template.block.target)
        XCTAssertEqual(provisional.nextTarget, template.block.nextTarget)
        XCTAssertEqual(provisional.prevState.rawCID, template.block.prevState.rawCID)
        XCTAssertEqual(
            template.block.children.node?["Existing"]?.rawCID,
            try BlockHeader(node: child).rawCID
        )
        let provisionalWorkID = try BlockHeader(node: provisional).rawCID
        XCTAssertNotEqual(provisionalWorkID, template.workID)
        let provisionalContent = await process.content([provisionalWorkID])
        XCTAssertNil(provisionalContent[provisionalWorkID])
        await XCTAssertThrowsErrorAsync(
            try await service.submitWork(SubmitWorkRequest(
                workID: provisionalWorkID,
                nonce: 0
            ))
        ) { error in
            XCTAssertEqual(error as? MiningTemplateError, .unknownWork)
        }

        let submitted = try await service.submitWork(SubmitWorkRequest(
            workID: template.workID,
            nonce: 0
        ))
        XCTAssertTrue(submitted.accepted)
        XCTAssertEqual(submitted.durableChildProofs, [
            DirectChildProofSummary(
                directory: "Existing",
                childCID: try BlockHeader(node: child).rawCID
            )
        ])
        // Handed off in memory.
    }

    func testIncompleteChildIsFilteredBeforeWorkWithoutNetworkFetch() async throws {
        let producer = try await nexusProcess()
        let parent = try await producer.canonicalTipBlock()
        let childGenesis = try await BlockBuilder.buildChildGenesis(
            spec: ChainSpec(
                maxNumberOfTransactionsPerBlock: 100,
                maxStateGrowth: 100_000,
                premine: 0,
                targetBlockTime: 1_000,
                initialReward: 10,
                halvingInterval: 100,
                halfLife: 10
            ),
            parentState: parent.postState,
            transactions: [],
            timestamp: 1,
            target: UInt256.max,
            fetcher: producer
        )
        let child = try await BlockBuilder.buildBlock(
            previous: childGenesis,
            timestamp: 2,
            nonce: 0,
            fetcher: producer
        )
        let childData = try XCTUnwrap(child.toData())
        let consumer = try await nexusProcess()
        let rawChild = try XCTUnwrap(Block(data: childData))
        let service = makeService(
            process: consumer
        )
        try await service.attachStubChildren(
            ["Incomplete", "Healthy"], on: consumer
        ) { _ in
            [
                DirectChildCandidate(
                    directory: "Incomplete",
                    block: rawChild
                ),
                DirectChildCandidate(
                    directory: "Healthy",
                    block: rawChild
                ),
            ]
        }

        let template = try await service.miningTemplate(MiningTemplateRequest())
        XCTAssertEqual(
            Set(try XCTUnwrap(template.block.children.node).entries.keys),
            ["Healthy", "Incomplete"]
        )
        let submitted = try await service.submitWork(SubmitWorkRequest(
            workID: template.workID,
            nonce: 0
        ))
        XCTAssertTrue(submitted.accepted)
    }

    func testChildCandidateProviderIsBoundedByService() async throws {
        let process = try await nexusProcess()
        let parent = try await process.canonicalTipBlock()
        let child = try await BlockBuilder.buildChildGenesis(
            spec: ChainSpec(
                maxNumberOfTransactionsPerBlock: 100,
                maxStateGrowth: 100_000,
                premine: 0,
                targetBlockTime: 1_000,
                initialReward: 10,
                halvingInterval: 100,
                halfLife: 10
            ),
            parentState: parent.postState,
            transactions: [],
            timestamp: 1,
            target: UInt256.max,
            fetcher: process
        )
        let service = ChainService(
            process: process,
            network: ClosureNetworkInterface(
                acceptedBlockPublisher: { _ in }
            ),
            maximumChildCandidates: 1
        )
        try await service.attachStubChildren(["A", "B"], on: process) { _ in
            ["A", "B"].map {
                DirectChildCandidate(
                    directory: $0,
                    block: child
                )
            }
        }

        let template = try await service.miningTemplate(
            MiningTemplateRequest()
        )
        let children = try XCTUnwrap(template.block.children.node)
        XCTAssertEqual(Set(children.entries.keys), ["A"])
    }

    /// A block ongoing under Nexus's genesis state: what a hosted child in
    /// any directory may offer a template on that genesis.
    private func ongoingChild(
        on process: ChainProcess, timestamp: Int64 = 2
    ) async throws -> Block {
        let parent = try await process.canonicalTipBlock()
        let childGenesis = try await BlockBuilder.buildChildGenesis(
            spec: ChainSpec(
                maxNumberOfTransactionsPerBlock: 100,
                maxStateGrowth: 100_000,
                premine: 0,
                targetBlockTime: 1_000,
                initialReward: 10,
                halvingInterval: 100,
                halfLife: 10
            ),
            parentState: parent.postState,
            transactions: [],
            timestamp: 1,
            target: UInt256.max,
            fetcher: process
        )
        return try await BlockBuilder.buildBlock(
            previous: childGenesis,
            timestamp: timestamp,
            nonce: 0,
            fetcher: process
        )
    }

    /// A snapshot binding another parent state than the template's tip
    /// post-state (built on an older tip) is neither carried nor a digest
    /// input; one binding it is both.
    func testAStaleSnapshotBindingIsSkipped() async throws {
        let process = try await nexusProcess()
        let service = makeService(process: process)
        let fresh = try await ongoingChild(on: process)
        let otherState = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec,
            parentState: LatticeState.emptyHeader,
            timestamp: 1,
            target: .max,
            fetcher: process
        )
        let stale = try await BlockBuilder.buildBlock(
            previous: otherState, timestamp: 2, nonce: 0, fetcher: process
        )
        XCTAssertNotEqual(stale.parentState.rawCID, fresh.parentState.rawCID)
        let staleLevel = StubChildLevel(
            directory: "Stale",
            candidate: DirectChildCandidate(directory: "Stale", block: stale)
        )
        await service.attachChildLevel(staleLevel)
        await service.attachChildLevel(StubChildLevel(
            directory: "Fresh",
            candidate: DirectChildCandidate(directory: "Fresh", block: fresh)
        ))
        let template = try await service.miningTemplate(MiningTemplateRequest())
        XCTAssertEqual(
            Set(template.block.children.node?.entries.keys.map { $0 } ?? []), ["Fresh"]
        )

        // The stale snapshot moving leaves the digest where it was.
        staleLevel.publish(DirectChildCandidate(
            directory: "Stale",
            block: try await BlockBuilder.buildBlock(
                previous: otherState, timestamp: 3, nonce: 0, fetcher: process
            )
        ))
        let digest = await service.status().templateDigest
        XCTAssertEqual(digest, template.templateDigest)
    }

    /// The parent's template never waits on a child's build (M3): with the
    /// hosted child's rebuild held, a template returns at once without it,
    /// and once the build finishes the snapshot changes the digest and the
    /// next template carries it.
    func testASlowChildBuildNeverDelaysTheParentTemplate() async throws {
        let fixture = try await activeChildService(spec: NexusGenesis.spec)
        let parent = makeService(process: fixture.parent)
        let building = Latch()
        let release = Latch()
        addTeardownBlock { await release.open() }
        let child = makeService(
            process: fixture.process,
            parentLevel: GatedTipParentLevel(LocalParentLevel(fixture.parent)) {
                await building.open()
                await release.wait()
            }
        )
        await host(child, in: "Payments", under: parent)
        await building.wait()

        let started = ContinuousClock.now
        let held = try await parent.miningTemplate(MiningTemplateRequest())
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
        XCTAssertNil(held.block.children.node?["Payments"])

        await release.open()
        try await eventually("the child publishes its snapshot") {
            child.readyCandidate() != nil
        }
        let status = await parent.status().templateDigest
        XCTAssertNotEqual(status, held.templateDigest)
        let carrying = try await parent.miningTemplate(MiningTemplateRequest())
        XCTAssertEqual(
            carrying.block.children.node?["Payments"]?.rawCID,
            child.readyCandidate()?.cid
        )
    }

    /// A transaction entering a hosted child's pool rebuilds no snapshot:
    /// peer gossip never churns the snapshot or the parent's digest. The
    /// next rebuild (here, a hosted child's change) picks it up.
    func testAMempoolInsertAloneRebuildsNoSnapshot() async throws {
        let fixture = try await activeChildService(spec: NexusGenesis.spec)
        let merged = await mergedMiningService(fixture)
        try await settle(merged.child)
        let before = try await merged.service.miningTemplate(MiningTemplateRequest())
        let first = try XCTUnwrap(merged.child.readyCandidate())

        _ = try await merged.child.submitTransaction(SubmitTransactionRequest(
            transaction: try signedTransaction(
                key: CryptoUtils.generateKeyPair(),
                chainPath: ["Nexus", "Payments"]
            )
        ))
        let idle = await merged.child.candidateRebuildIdle()
        XCTAssertTrue(idle, "a mempool insert scheduled a rebuild")
        XCTAssertEqual(merged.child.readyCandidate()?.cid, first.cid)
        let digest = await merged.service.status().templateDigest
        XCTAssertEqual(digest, before.templateDigest)

        try await settle(merged.child)
        let rebuilt = try XCTUnwrap(merged.child.readyCandidate())
        XCTAssertEqual(rebuilt.candidate.block.transactions.node?.count, 1)
    }

    /// A node serves one miner's plan at a time: a template request with a
    /// new plan adopts it, and until the child rebuilds on it no template
    /// carries the child's snapshot built for the previous plan.
    func testATemplateNeverCarriesASnapshotBuiltForAnotherPlan() async throws {
        let fixture = try await activeChildService(spec: NexusGenesis.spec)
        let building = Latch()
        let release = Latch()
        addTeardownBlock { await release.open() }
        let held = HeldGate()
        let payments = makeService(
            process: fixture.process,
            parentLevel: GatedTipParentLevel(LocalParentLevel(fixture.parent)) {
                guard await held.isHeld else { return }
                await building.open()
                await release.wait()
            }
        )
        let parent = makeService(process: fixture.parent)
        await host(payments, in: "Payments", under: parent)
        func plan(_ bits: Int) -> MiningTemplateRequest {
            MiningTemplateRequest(minimumWork: [MiningMinimumWork(
                chainPath: ["Nexus", "Payments"], work: UInt256(1) << bits
            )])
        }
        let first = try await settledTemplate((parent, payments), plan(2))
        let firstSnapshot = try XCTUnwrap(payments.readyCandidate())
        XCTAssertEqual(first.block.children.node?["Payments"]?.rawCID, firstSnapshot.cid)

        // The second plan's rebuild is held: the first plan's snapshot
        // stands, and is not carried.
        await held.hold()
        let second = try await parent.miningTemplate(plan(3))
        await building.wait()
        XCTAssertNil(second.block.children.node?["Payments"])
        XCTAssertEqual(payments.readyCandidate()?.cid, firstSnapshot.cid)

        await held.release()
        await release.open()
        try await eventually("the child rebuilds on the second plan") {
            await payments.candidateRebuildIdle()
                && payments.readyCandidate()?.plan.minimumWork.first?.work
                    == UInt256(1) << 3
        }
        let carrying = try await parent.miningTemplate(plan(3))
        XCTAssertEqual(
            carrying.block.children.node?["Payments"]?.rawCID,
            payments.readyCandidate()?.cid
        )
    }

    /// A grandchild's snapshot reaches the top (M2): a grandchild becoming
    /// ready rebuilds the child's snapshot, which then carries it, and so
    /// changes Nexus's digest.
    func testAGrandchildBecomingReadyRebuildsTheChildAndMovesTheParentDigest() async throws {
        let fixture = try await activeChildService(spec: NexusGenesis.spec)
        let payments = makeService(
            process: fixture.process,
            parentLevel: LocalParentLevel(fixture.parent)
        )
        let grandchild = StubChildLevel(directory: "Grandchild")
        await payments.attachChildLevel(grandchild)
        let merged = await mergedMiningService(fixture, child: payments)
        try await settle(payments)
        let before = try await merged.service.miningTemplate(MiningTemplateRequest())
        let without = try XCTUnwrap(payments.readyCandidate())
        XCTAssertNil(without.candidate.block.children.node?["Grandchild"])

        // The grandchild builds on Payments' tip, as its rebuild would.
        let tip = try await fixture.process.validatedTipBlock()
        let carrier = try XCTUnwrap(ChainService.provisionalCarrier(
            on: tip,
            tipCID: try BlockHeader(node: tip).rawCID,
            timestamp: tip.timestamp + 1
        ))
        let genesis = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec,
            parentState: carrier.prevState,
            timestamp: carrier.timestamp,
            target: .max,
            fetcher: fixture.process
        )
        grandchild.publish(DirectChildCandidate(
            directory: "Grandchild",
            block: try await BlockBuilder.buildBlock(
                previous: genesis,
                transactions: [],
                parentChainBlock: carrier,
                timestamp: carrier.timestamp + 1,
                fetcher: fixture.process
            )
        ))
        // What the host's `candidateChanged` hook does for the grandchild.
        try await settle(payments)

        let with = try XCTUnwrap(payments.readyCandidate())
        XCTAssertNotEqual(with.cid, without.cid)
        XCTAssertEqual(
            with.candidate.block.children.node?["Grandchild"]?.rawCID,
            grandchild.readyCandidate?.cid
        )
        let digest = await merged.service.status().templateDigest
        XCTAssertNotEqual(digest, before.templateDigest)
        let after = try await merged.service.miningTemplate(MiningTemplateRequest())
        XCTAssertEqual(after.block.children.node?["Payments"]?.rawCID, with.cid)
    }

    /// A child block the template's own tip already carries is not carried
    /// again: a children-only carrier leaves the post-state, so the child
    /// rebuilds the same block on the same carrier `prevState`, which still
    /// binds the next template, and carrying it twice would only credit the
    /// same block once more.
    func testTheTipsCarriedChildBlockIsNotCarriedAgain() async throws {
        let fixture = try await activeChildService(spec: NexusGenesis.spec)
        // A child that has not admitted its carried block (the mined
        // handoff would admit it, and the child would build its next one).
        let merged = await mergedMiningService(fixture) {
            DecliningChildLevel($0)
        }
        // The host has the parent serve a hosted child's runs, which also
        // names the child block the branch last carried.
        await merged.service.serveRuns(for: "Payments")
        try await settle(merged.child)

        let carrying = try await merged.service.miningTemplate(MiningTemplateRequest())
        let carried = try XCTUnwrap(carrying.block.children.node?["Payments"]?.rawCID)
        let mined = try await merged.service.submitWork(SubmitWorkRequest(
            workID: carrying.workID, nonce: solvedNonce(for: carrying)
        ))
        XCTAssertTrue(mined.accepted)

        // The parent's tip moved: the child rebuilds on it.
        try await settle(merged.child)
        let again = try await merged.service.miningTemplate(MiningTemplateRequest())
        let offered = try XCTUnwrap(merged.child.readyCandidate())
        XCTAssertEqual(offered.parentStateCID, again.block.prevState.rawCID)
        XCTAssertEqual(offered.cid, carried, "the child offers the carried block again")
        XCTAssertNil(again.block.children.node?["Payments"], "carried once, not twice")
    }

    /// One grind, one subtree insert, content first: `submitWork` hands the
    /// carried child block down and the child admits it while the parent
    /// has not yet committed its own block; the parent commits after.
    func testSubmitWorkAdmitsTheCarriedChildBeforeTheParentCommits() async throws {
        let fixture = try await activeChildService(spec: NexusGenesis.spec)
        let parentTipAtHandoff = GrandchildCID()
        let parentProcess = fixture.parent
        let merged = await mergedMiningService(fixture) { level in
            HandoffObservingChildLevel(level) {
                await parentTipAtHandoff.set(await parentProcess.canonicalTip()?.cid ?? "")
            }
        }
        await merged.service.serveRuns(for: "Payments")
        try await settle(merged.child)
        let before = await parentProcess.canonicalTip()?.cid

        let carrying = try await merged.service.miningTemplate(MiningTemplateRequest())
        let carried = try XCTUnwrap(carrying.block.children.node?["Payments"]?.rawCID)
        let mined = try await merged.service.submitWork(SubmitWorkRequest(
            workID: carrying.workID, nonce: solvedNonce(for: carrying)
        ))
        XCTAssertTrue(mined.accepted)
        XCTAssertEqual(mined.durableChildProofs, [
            DirectChildProofSummary(directory: "Payments", childCID: carried),
        ])
        let atHandoff = await parentTipAtHandoff.value
        XCTAssertEqual(atHandoff, before, "the parent committed before its child admitted")
        let after = await parentProcess.canonicalTip()?.cid
        XCTAssertNotEqual(after, before, "the parent committed its block after")
        XCTAssertEqual(after, mined.tipCID)
    }

    /// Closing mining ingress refuses new template and work requests at once
    /// and returns only after the requests already inside have finished,
    /// a mined handoff to a hosted child included.
    func testClosingMiningIngressRefusesNewWorkAndDrainsTheHandoffInFlight() async throws {
        let fixture = try await activeChildService(spec: NexusGenesis.spec)
        let inHandoff = Latch()
        let release = Latch()
        addTeardownBlock { await release.open() }
        let merged = await mergedMiningService(fixture) { level in
            HandoffObservingChildLevel(level) {
                await inHandoff.open()
                await release.wait()
            }
        }
        await merged.service.serveRuns(for: "Payments")
        try await settle(merged.child)
        let carrying = try await merged.service.miningTemplate(MiningTemplateRequest())
        let nonce = solvedNonce(for: carrying)
        let mining = Task {
            try await merged.service.submitWork(SubmitWorkRequest(
                workID: carrying.workID, nonce: nonce
            ))
        }
        await inHandoff.wait()

        let closed = ShutdownReturned()
        let closing = Task {
            await merged.service.closeMiningIngress()
            await closed.mark()
        }
        try await eventually("new mining requests are refused") {
            do {
                _ = try await merged.service.miningTemplate(MiningTemplateRequest())
                return false
            } catch ChainServiceError.shuttingDown {
                return true
            }
        }
        await XCTAssertThrowsErrorAsync(
            try await merged.service.submitWork(SubmitWorkRequest(
                workID: carrying.workID, nonce: nonce
            ))
        ) { error in
            XCTAssertEqual(error as? ChainServiceError, .shuttingDown)
        }
        let returnedEarly = await closed.value
        XCTAssertFalse(returnedEarly, "closed before the handoff in flight finished")

        await release.open()
        let mined = try await mining.value
        XCTAssertTrue(mined.accepted)
        await closing.value
        let returned = await closed.value
        XCTAssertTrue(returned)
    }

    /// A children-only parent block leaves the post-state and the child's
    /// tip, so the child rebuilds the block the parent carried as is — even
    /// once the carrier is older than a template's lifetime — and the
    /// carried-CID skip leaves it out; re-stamping it would build a sibling.
    func testAChildrenOnlyParentBlockAfterTheCarrierAgesKeepsTheCarriedCID() async throws {
        let fixture = try await activeChildService(spec: NexusGenesis.spec)
        let merged = await mergedMiningService(fixture)
        await merged.service.serveRuns(for: "Payments")
        try await settle(merged.child)
        let first = try XCTUnwrap(merged.child.readyCandidate())

        // On the parent tip it was stamped on, an aged carrier is re-stamped.
        await merged.child.advanceCarrierClockForTesting(milliseconds: 31_000)
        try await settle(merged.child)
        let restamped = try XCTUnwrap(merged.child.readyCandidate())
        XCTAssertNotEqual(restamped.cid, first.cid, "an aged carrier kept its timestamp")

        let carrying = try await merged.service.miningTemplate(MiningTemplateRequest())
        let carried = try XCTUnwrap(carrying.block.children.node?["Payments"]?.rawCID)
        XCTAssertEqual(carried, restamped.cid)
        let mined = try await merged.service.submitWork(SubmitWorkRequest(
            workID: carrying.workID, nonce: solvedNonce(for: carrying)
        ))
        XCTAssertTrue(mined.accepted)

        await merged.child.advanceCarrierClockForTesting(milliseconds: 31_000)
        try await settle(merged.child)
        let offered = try XCTUnwrap(merged.child.readyCandidate())
        XCTAssertEqual(offered.cid, carried, "the aged carrier was re-stamped: a sibling")
        let again = try await merged.service.miningTemplate(MiningTemplateRequest())
        XCTAssertNil(again.block.children.node?["Payments"], "carried once, not twice")
    }

    func testContextualChildCandidateBindsNewParentCarrierState() async throws {
        let parentProcess = try await nexusProcess()
        let parentGenesis = try await parentProcess.canonicalTipBlock()
        let childSpec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 1,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 10,
            halvingInterval: 100,
            halfLife: 10
        )
        // A self-contained child genesis (empty parentState): the parent only
        // RECORDS its CID via a plain GenesisAction; the child rebuilds it from
        // the seed and self-admits it. It is never carried on the carrier's
        // children.
        let seed = ChildGenesisSeed(
            spec: childSpec, premineTo: nil, timestamp: 1
        )
        let childGenesis = try await ChildGenesisBuilder.build(
            seed: seed,
            chainPath: ["Nexus", "Payments"],
            fetcher: parentProcess
        )
        let childHeader = try BlockHeader(node: childGenesis)
        let anchor = try signedTransaction(
            key: CryptoUtils.generateKeyPair(),
            chainPath: ["Nexus"],
            genesisActions: [GenesisAction(
                directory: "Payments",
                blockCID: childHeader.rawCID
            )]
        )
        try await VolumeImpl<Transaction>(node: anchor).storeRecursively(
            storer: parentProcess
        )
        let firstCarrier = try await BlockBuilder.buildBlock(
            previous: parentGenesis,
            transactions: [anchor],
            timestamp: parentGenesis.timestamp + 1,
            nonce: 0,
            fetcher: parentProcess
        )
        let firstCarrierHeader = try BlockHeader(node: firstCarrier)
        let parentOutcome = try await parentProcess.importBlock(firstCarrierHeader)
        XCTAssertNotNil(parentOutcome.parentCarrierLink)

        let childDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-child-service-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: childDirectory) }
        let childProcess = try await ChainProcess.open(configuration: NodeConfiguration(
            chainPath: ["Nexus", "Payments"],
            storagePath: childDirectory,
            privateKeyHex: String(repeating: "02", count: 32)
        ))
        let activated = try await childProcess.activateChildGenesis(
            seed: seed,
            confirmParentRecordedGenesis: { _ in true }
        )
        XCTAssertTrue(
            activated,
            "the seeded child genesis must self-admit"
        )

        let nextParentCarrier = try await BlockBuilder.buildBlock(
            previous: firstCarrier,
            timestamp: firstCarrier.timestamp + 1,
            nonce: 0,
            fetcher: parentProcess
        )
        XCTAssertNotEqual(
            nextParentCarrier.prevState.rawCID,
            childGenesis.parentState.rawCID
        )
        let childService = makeService(process: childProcess)
        await XCTAssertThrowsErrorAsync(
            try await childService.miningTemplate(MiningTemplateRequest())
        ) { error in
            XCTAssertEqual(
                error as? ChainServiceError,
                .parentCarrierRequired
            )
        }
        let unmatchedKey = CryptoUtils.generateKeyPair()
        let unmatchedDeployment = try signedTransaction(
            key: unmatchedKey,
            chainPath: ["Nexus", "Payments"],
            accountActions: [AccountAction(
                owner: CryptoUtils.createAddress(from: unmatchedKey.publicKey),
                delta: -1
            )],
            genesisActions: [GenesisAction(
                directory: "Orphan",
                blockCID: childHeader.rawCID
            )]
        )
        let ordinary = try signedTransaction(
            key: CryptoUtils.generateKeyPair(),
            chainPath: ["Nexus", "Payments"]
        )
        await XCTAssertThrowsErrorAsync(
            try await childService.submitTransaction(
                SubmitTransactionRequest(transaction: unmatchedDeployment)
            )
        ) { error in
            XCTAssertEqual(error as? TransactionPoolError, .invalidState)
        }
        _ = try await childService.submitTransaction(
            SubmitTransactionRequest(transaction: ordinary)
        )
        let livenessCandidate = try await childService.miningCandidate(
            for: ChildCandidateRequestContext(
                parentCarrier: nextParentCarrier,
                recipients: []
            ),
            parentContentSource: FetcherContentSource(parentProcess)
        )
        let selectedTransactions = try await livenessCandidate.block.transactions
            .resolve(fetcher: childProcess)
        XCTAssertEqual(selectedTransactions.node?.count, 1)
        XCTAssertEqual(
            try selectedTransactions.node?.allKeysAndValues()["0"]?.rawCID,
            try VolumeImpl<Transaction>(node: ordinary).rawCID
        )

        let childMiner = CryptoUtils.generateKeyPair()
        let childRecipient = CryptoUtils.createAddress(from: childMiner.publicKey)
        let candidate: DirectChildCandidate
        do {
            candidate = try await childService.miningCandidate(
                for: ChildCandidateRequestContext(
                    parentCarrier: nextParentCarrier,
                    recipients: [MiningRecipient(
                        chainPath: ["Nexus", "Payments"],
                        address: childRecipient
                    )]
                ),
                parentContentSource: FetcherContentSource(parentProcess)
            )
        } catch {
            XCTFail("contextual child candidate failed: \(error)")
            throw error
        }

        XCTAssertEqual(candidate.directory, "Payments")
        XCTAssertEqual(
            candidate.block.parentState.rawCID,
            nextParentCarrier.prevState.rawCID
        )
        XCTAssertNotEqual(
            candidate.block.parentState.rawCID,
            childGenesis.parentState.rawCID
        )
        XCTAssertEqual(candidate.block.rewardRecipient, childRecipient)
        await XCTAssertThrowsErrorAsync(
            try await childService.submitWork(SubmitWorkRequest(
                workID: try BlockHeader(node: candidate.block).rawCID,
                nonce: candidate.block.nonce
            ))
        ) { error in
            XCTAssertEqual(
                error as? ChainServiceError,
                .parentCarrierRequired
            )
        }
    }

    func testContextualCandidateIsStableAcrossParentCarrierIdentity() async throws {
        let fixture = try await activeChildService(spec: NexusGenesis.spec)
        let carrierTimestamp = fixture.parentCarrier.timestamp + 1
        let firstCarrier = try await BlockBuilder.buildBlock(
            previous: fixture.parentCarrier,
            timestamp: carrierTimestamp,
            nonce: 1,
            fetcher: fixture.parent
        )
        let secondCarrier = try await BlockBuilder.buildBlock(
            previous: fixture.parentCarrier,
            timestamp: carrierTimestamp,
            nonce: 2,
            fetcher: fixture.parent
        )
        XCTAssertNotEqual(
            try BlockHeader(node: firstCarrier).rawCID,
            try BlockHeader(node: secondCarrier).rawCID
        )

        let first = try await fixture.service.miningCandidate(
            for: ChildCandidateRequestContext(
                parentCarrier: firstCarrier,
                recipients: []
            ),
            parentContentSource: FetcherContentSource(fixture.parent)
        )
        try await Task.sleep(for: .milliseconds(20))
        let second = try await fixture.service.miningCandidate(
            for: ChildCandidateRequestContext(
                parentCarrier: secondCarrier,
                recipients: []
            ),
            parentContentSource: FetcherContentSource(fixture.parent)
        )

        XCTAssertEqual(
            try BlockHeader(node: first.block).rawCID,
            try BlockHeader(node: second.block).rawCID
        )
        let previous = try await fixture.process.canonicalTipBlock()
        XCTAssertEqual(
            first.block.timestamp,
            max(previous.timestamp + 1, carrierTimestamp)
        )
    }

    // MARK: - Bulk-sync common-ancestor negotiation (Stage 1)

    /// THE marooned-follower case: a receiver whose frontier is an off-chain
    /// losing sibling must resolve to the deepest common main-chain ancestor and
    /// receive the main-chain blocks forward from it — NOT get an empty page that
    /// forward-range conflates with "caught up".
    func testCommonAncestorResolvesDeepAncestorWhenFrontierIsOffChainSibling() async throws {
        let process = try await nexusProcess()
        let service = makeService(process: process)
        var mainCIDs: [String] = []
        for _ in 0..<3 {
            let template = try await service.miningTemplate(MiningTemplateRequest())
            let submitted = try await service.submitWork(
                SubmitWorkRequest(
                    workID: template.workID,
                    nonce: solvedNonce(for: template)
                )
            )
            XCTAssertTrue(submitted.accepted)
            mainCIDs.append(try XCTUnwrap(submitted.tipCID))
        }
        // Fork at height 3: two competing height-4 blocks; one is canonical, the
        // other is the off-chain sibling a marooned receiver would sit on.
        let templateA = try await service.miningTemplate(MiningTemplateRequest())
        let templateB = try await service.miningTemplate(MiningTemplateRequest())
        let nonceA = solvedNonce(for: templateA)
        let nonceB = solvedNonce(for: templateB)
        let cidA = try BlockHeader(node: templateA.block.replacingNonce(nonceA)).rawCID
        let cidB = try BlockHeader(node: templateB.block.replacingNonce(nonceB)).rawCID
        let submittedA = try await service.submitWork(
            SubmitWorkRequest(workID: templateA.workID, nonce: nonceA)
        )
        XCTAssertTrue(submittedA.accepted)
        let submittedB = try await service.submitWork(
            SubmitWorkRequest(workID: templateB.workID, nonce: nonceB)
        )
        XCTAssertTrue(submittedB.accepted)
        let canonical4Opt = await process.canonicalBlockCID(atHeight: 4)
        let canonical4 = try XCTUnwrap(canonical4Opt)
        let sibling4 = canonical4 == cidA ? cidB : cidA
        let deepAncestor = mainCIDs[2] // canonical height-3 block

        // Locator front is the off-chain sibling; the resolver must skip it and
        // find the deep on-chain ancestor, returning the main-chain block forward.
        let resolved = await process.commonAncestorRange(
            locator: [sibling4, deepAncestor, mainCIDs[1], mainCIDs[0]],
            limit: ForwardRangeResponseMessage.maximumBlocks
        )
        XCTAssertEqual(resolved.commonAncestor, deepAncestor)
        XCTAssertEqual(resolved.blockCIDs, [canonical4])

        // All-off-chain locator → no common ancestor (distinct from caught-up).
        let disjoint = await process.commonAncestorRange(
            locator: [sibling4, testOffChainCID],
            limit: ForwardRangeResponseMessage.maximumBlocks
        )
        XCTAssertNil(disjoint.commonAncestor)
        XCTAssertTrue(disjoint.blockCIDs.isEmpty)

        // Highest on-chain entry == tip → caught up (ancestor present, empty).
        let caughtUp = await process.commonAncestorRange(
            locator: [canonical4],
            limit: ForwardRangeResponseMessage.maximumBlocks
        )
        XCTAssertEqual(caughtUp.commonAncestor, canonical4)
        XCTAssertTrue(caughtUp.blockCIDs.isEmpty)
    }

    func testAncestorRangeMessagesRoundTripAndBound() throws {
        let genesis = "bafyreick4k7a6bxz4huqx4wiu3z5yph4tnpl4zvq2pi6xv3ouribtvzs24"
        let request = AncestorRangeRequestMessage(requestID: 7, locator: [genesis])
        XCTAssertEqual(
            try AncestorRangeRequestMessage.decoded(request.encoded()), request
        )
        // commonAncestor present + blocks.
        let withAncestor = AncestorRangeResponseMessage(
            requestID: 7, commonAncestor: genesis, blockCIDs: [genesis], hasMore: false
        )
        XCTAssertEqual(
            try AncestorRangeResponseMessage.decoded(withAncestor.encoded()), withAncestor
        )
        // commonAncestor nil + empty (no overlap) round-trips.
        let noOverlap = AncestorRangeResponseMessage(
            requestID: 7, commonAncestor: nil, blockCIDs: [], hasMore: false
        )
        XCTAssertEqual(
            try AncestorRangeResponseMessage.decoded(noOverlap.encoded()), noOverlap
        )
        // Bounds: empty locator, oversized locator, and nil-ancestor-with-blocks
        // are all rejected.
        XCTAssertThrowsError(
            try AncestorRangeRequestMessage(requestID: 1, locator: []).encoded()
        )
        let tooMany = (0...AncestorRangeRequestMessage.maximumLocatorEntries)
            .map { _ in genesis }
        XCTAssertThrowsError(
            try AncestorRangeRequestMessage(requestID: 1, locator: tooMany).encoded()
        )
        XCTAssertThrowsError(
            try AncestorRangeResponseMessage(
                requestID: 1, commonAncestor: nil, blockCIDs: [genesis], hasMore: false
            ).encoded()
        )
    }

    private let testOffChainCID =
        "bafyreib4ovbxjaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    /// Thread-safe recorder for the walk's per-height instrumentation.
    private final class ValidateStepRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _heights: [UInt64] = []
        func record(_ height: UInt64) {
            lock.lock(); defer { lock.unlock() }
            _heights.append(height)
        }
        var heights: [UInt64] {
            lock.lock(); defer { lock.unlock() }
            return _heights
        }
    }

    /// Mine `depth` blocks on `producer` and return them in ascending-height
    /// order. Only block 1 inherits the genesis maximum; from there the
    /// absolute schedule hardens slightly each block, so the nonce has to be
    /// solved rather than taken from the template.
    private func mineNexusChain(
        on producer: ChainProcess,
        depth: Int
    ) async throws -> [Block] {
        let producerService = makeService(process: producer)
        var blocks: [Block] = []
        for _ in 0..<depth {
            let template = try await producerService
                .miningTemplate(MiningTemplateRequest())
            let block = template.block.replacingNonce(
                firstNonce(of: template.block, from: 0) {
                    $0 <= template.block.target
                }
            )
            let outcome = try await producer.importBlock(BlockHeader(node: block))
            XCTAssertTrue(
                outcome.decision.isAccepted,
                "producer block must be accepted"
            )
            blocks.append(block)
        }
        return blocks
    }

    /// Acceptance: the deferred-execution linchpin end to end. Weighed
    /// admission ranks a block on verified work alone, so an attacker can put
    /// a block that will NEVER execute at the head of fork choice for free —
    /// the work is real, only the declared post-state is a lie. The chain must
    /// then do four things, and the fourth is what makes the other three safe:
    ///
    ///  1. rank it: an unexecuted block really does take the tip;
    ///  2. only convict on a COMPLETED check: while the body is out of reach
    ///     the block keeps its weight, because a node that excluded on a
    ///     missing body would let anyone delete a competitor's branch by
    ///     withholding bytes;
    ///  3. reproject: its weight leaves, and the tip falls back to the
    ///     heaviest block that actually validates;
    ///  4. keep serving it: exclusion is a chain-local weighting decision, not
    ///     pruning, so the bytes stay available to peers — a node must never
    ///     conclude that other nodes are wrong to hold it;
    ///
    /// Its recovery half — that a restart re-derives the same exclusion from
    /// the durable facts instead of re-admitting the forgery as the tip — is
    /// `testExclusionIsReDerivedFromDurableFactsAcrossRestart` below.
    ///
    /// These two are the only tests in this repo covering exclusion at all.
    func testInvalidWeighedTipIsExcludedReprojectedAndStillServed() async throws {
        let fixture = try await forgedWeighedTipFixture()
        let honest = fixture.honest
        let attack = fixture.attack
        let attackProducer = fixture.attackProducer
        let honestTip = try BlockHeader(node: honest[3]).rawCID
        let lastValid = attack[4]
        let lastValidCID = try BlockHeader(node: lastValid).rawCID
        let truth = attack[5]
        let forgedCID = try BlockHeader(node: fixture.forged).rawCID

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-chain-service-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        var node: ChainProcess? = try await ChainProcess.open(
            configuration: try NodeConfiguration(
                chainPath: ["Nexus"],
                storagePath: directory,
                privateKeyHex: String(repeating: "01", count: 32)
            )
        )
        defer { node = nil }

        // 1. Ranked. Work is a physical fact and the header links up, so the
        // forgery is accepted and takes the tip on weight alone.
        try await weighedAdmitForgedBranch(fixture, into: node!)
        let weighedTip = try BlockHeader(
            node: await node!.canonicalTipBlock()
        ).rawCID
        XCTAssertEqual(
            weighedTip, forgedCID,
            "an unexecuted block must be able to reach the tip, or there is nothing to defend against"
        )

        // 2a. Availability is never invalidity. Run the walk first with the
        // body out of reach: it cannot complete the check, so it must not
        // convict. A node that excluded here would let anyone delete a
        // competitor's branch by withholding bytes.
        // Withhold ONLY the forgery's body, so the walk provably runs the
        // whole branch and stalls on exactly that block — starving everything
        // would stop it at the first block and prove nothing about this one.
        struct BodyUnavailable: Error {}
        var starved: ChainService? = makeService(
            process: node!,
            executionBodySource: { cid, admit in
                guard cid != forgedCID else { throw BodyUnavailable() }
                return try await admit(FetcherContentSource(attackProducer))
            }
        )
        await starved!.runExecutionWalkPass()
        starved = nil
        let starvedValidated = await node!.deepestValidatedCanonicalTip()
        XCTAssertEqual(
            starvedValidated?.cid, lastValidCID,
            "the walk really did execute the branch and stop at the withheld block"
        )
        let starvedTip = try BlockHeader(
            node: await node!.canonicalTipBlock()
        ).rawCID
        XCTAssertEqual(
            starvedTip, forgedCID,
            "an unreachable body is a gap to retry, not a verdict: the block keeps its weight"
        )
        let heldWhileStarved = await node!.hasAcceptedBlock(forgedCID)
        XCTAssertTrue(heldWhileStarved, "and is certainly not dropped")

        // 2b and 3. Now the body is reachable. The walk executes forward,
        // completes the deterministic check, and fork choice reprojects.
        var service: ChainService? = makeService(
            process: node!,
            executionBodySource: { _, admit in
                try await admit(FetcherContentSource(attackProducer))
            }
        )
        await service!.runExecutionWalkPass()

        let afterTip = try BlockHeader(
            node: await node!.canonicalTipBlock()
        ).rawCID
        XCTAssertNotEqual(
            afterTip, forgedCID, "the invalid block must lose its weight"
        )
        XCTAssertEqual(
            afterTip, lastValidCID,
            "the tip falls back to the heaviest block that actually validates"
        )
        // Only the forgery is excluded. The competing honest branch is still
        // held and servable: a reprojection that quietly dropped it would
        // satisfy every tip assertion above.
        let honestSurvives = await node!.hasAcceptedBlock(honestTip)
        XCTAssertTrue(
            honestSurvives, "the honest branch must survive the exclusion"
        )
        let honestServed = await node!.content([honestTip])
        XCTAssertNotNil(
            honestServed[honestTip], "and still be servable"
        )
        let validated = await node!.deepestValidatedCanonicalTip()
        XCTAssertEqual(validated?.cid, lastValidCID)
        XCTAssertEqual(validated?.height, lastValid.height)

        // 4. Excluded, not pruned. The block and its bytes stay available:
        // this node stopped counting it, and says nothing about anyone else.
        // Control: the honest twin of the forgery was never admitted here, so
        // this predicate discriminates rather than answering true for anything.
        let neverAdmitted = await node!.hasAcceptedBlock(
            try BlockHeader(node: truth).rawCID
        )
        XCTAssertFalse(
            neverAdmitted, "a block this node never admitted is not accepted"
        )
        let stillAccepted = await node!.hasAcceptedBlock(forgedCID)
        XCTAssertTrue(
            stillAccepted,
            "exclusion is a weighting decision, not a deletion"
        )
        let served = await node!.content([forgedCID])
        XCTAssertNotNil(
            served[forgedCID],
            "an excluded block must still be servable to peers that ask for it"
        )

        service = nil
        node = nil
    }

    /// Acceptance, recovery half of §9.9: the exclusion above must be RE-DERIVED
    /// at boot. Nothing records "this node excluded a block" as a projection —
    /// the verdict is staged as its own durable `.exclusion` admission fact, and
    /// boot replays every staged fact through the same reducer as live
    /// admission, so the excluded subtree is rebuilt before the first canonical
    /// projection. A recovery path that dropped that fact would re-admit the
    /// heavier forged branch as the tip on every reboot — a node put back on a
    /// branch it has already proven invalid — and the live test above would
    /// still pass.
    ///
    /// Scope: this is a CLEAN restart — the service is joined and the process
    /// released before the directory is reopened — not a crash partway through
    /// a commit. Recovery from an interrupted write is a separate question and
    /// is not covered here.
    func testExclusionIsReDerivedFromDurableFactsAcrossRestart() async throws {
        let fixture = try await forgedWeighedTipFixture()
        let lastValid = fixture.attack[4]
        let lastValidCID = try BlockHeader(node: lastValid).rawCID
        let honestTip = try BlockHeader(node: fixture.honest[3]).rawCID
        let forgedCID = try BlockHeader(node: fixture.forged).rawCID

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-chain-service-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: directory,
            privateKeyHex: String(repeating: "01", count: 32)
        )
        var node: ChainProcess? = try await ChainProcess.open(
            configuration: configuration
        )
        try await weighedAdmitForgedBranch(fixture, into: node!)

        // Convict, exactly as the live test does: the body is reachable, the
        // walk completes the deterministic check, and fork choice reprojects.
        var service: ChainService? = makeService(
            process: node!,
            executionBodySource: { [attackProducer = fixture.attackProducer] _, admit in
                try await admit(FetcherContentSource(attackProducer))
            }
        )
        // Precondition the restart assertions are VACUOUS without: the forgery
        // must actually hold the tip. The attack branch's valid prefix alone
        // already outweighs the honest branch, so a forgery that never
        // canonicalized would leave the tip at `lastValidCID` with nothing
        // excluded — and every assertion after the restart would still pass.
        let rankedTip = try BlockHeader(
            node: await node!.canonicalTipBlock()
        ).rawCID
        XCTAssertEqual(
            rankedTip, forgedCID,
            "precondition: the forgery must hold the tip, or there is no exclusion to re-derive"
        )
        await service!.runExecutionWalkPass()
        let excludedTip = try BlockHeader(
            node: await node!.canonicalTipBlock()
        ).rawCID
        XCTAssertEqual(
            excludedTip, lastValidCID,
            "precondition: the exclusion reprojected before the restart"
        )

        // Restart. The service joins its workers so nothing is left holding the
        // process, both references go, and the storage-directory lock is
        // released — then the same directory is reopened from its durable facts
        // alone, with no in-memory state carried across.
        await service!.shutdown()
        service = nil
        node = nil
        let restarted = try await ChainProcess.open(configuration: configuration)

        let recoveredTip = try BlockHeader(
            node: await restarted.canonicalTipBlock()
        ).rawCID
        XCTAssertNotEqual(
            recoveredTip, forgedCID,
            "a restart must never put the node back on a branch it proved invalid"
        )
        XCTAssertEqual(
            recoveredTip, lastValidCID,
            "recovery must re-derive the same reprojection, not a different one"
        )
        // The forgery's work is still durably recorded and is still the
        // heaviest thing in the store; the height proves it is not counted.
        let recoveredHeight = await restarted.canonicalTipHeight()
        XCTAssertEqual(
            recoveredHeight, lastValid.height,
            "the excluded subtree's work must not count toward fork choice after a restart"
        )
        let forgedValidated = await restarted.blockValidated(forgedCID)
        XCTAssertFalse(
            forgedValidated,
            "an excluded block must never recover as validated"
        )
        // Control, as above: the competing honest branch is untouched by the
        // exclusion, so a recovery that simply dropped everything unexecutable
        // would not satisfy this.
        let honestSurvives = await restarted.hasAcceptedBlock(honestTip)
        XCTAssertTrue(
            honestSurvives, "the honest branch must survive the restart"
        )
        // Excluded, not pruned — across the restart too.
        let stillAccepted = await restarted.hasAcceptedBlock(forgedCID)
        XCTAssertTrue(
            stillAccepted,
            "exclusion is a weighting decision, not a deletion"
        )
        let served = await restarted.content([forgedCID])
        XCTAssertNotNil(
            served[forgedCID],
            "an excluded block must still be servable after a restart"
        )
    }

    /// The forged-weighed-tip fixture both exclusion tests run on: an honest
    /// branch, a heavier attack branch, and a forgery of the attack TIP.
    /// Tampering the tip is the only shape an attacker can actually get
    /// admitted: a lie deeper in the branch breaks `prevState ==
    /// parent.postState` for its own successor, so weighed admission rejects
    /// the rest.
    private struct ForgedWeighedTipFixture {
        let honestProducer: ChainProcess
        let honest: [Block]
        let attackProducer: ChainProcess
        /// Mined honestly; only `prefix(5)` is ever admitted, with `forged`
        /// standing in for the sixth block.
        let attack: [Block]
        /// The lie: this block pays a reward, so its post-state cannot equal
        /// its pre-state. Every header-linkage field stays honest, which is
        /// precisely why weighed admission has no grounds to refuse it.
        let forged: Block
    }

    private func forgedWeighedTipFixture() async throws
        -> ForgedWeighedTipFixture
    {
        let honestProducer = try await nexusProcess()
        let honest = try await mineNexusRewardChain(
            on: honestProducer, depth: 4, miner: CryptoUtils.generateKeyPair()
        )
        let attackProducer = try await nexusProcess()
        let attack = try await mineNexusRewardChain(
            on: attackProducer, depth: 6, miner: CryptoUtils.generateKeyPair()
        )
        let truth = attack[5]
        let unsolvedForgery = Block(
            version: truth.version,
            parent: truth.parent,
            transactions: truth.transactions,
            target: truth.target,
            nextTarget: truth.nextTarget,
            spec: truth.spec,
            parentState: truth.parentState,
            prevState: truth.prevState,
            postState: truth.prevState,
            children: truth.children,
            height: truth.height,
            timestamp: truth.timestamp,
            rewardRecipient: truth.rewardRecipient,
            nonce: truth.nonce
        )
        // Changing `postState` changes the proof-of-work preimage, so the
        // honest block's nonce no longer solves the forgery. Under the old
        // windowed retarget this harness sat at exactly the maximum target,
        // where every hash qualifies and the stale nonce went unnoticed; the
        // absolute schedule hardens slightly each block, so it must be
        // re-solved. Leaving it stale would get the forgery refused for want
        // of work and silently uncover the whole exclusion path -- this repo
        // has already been bitten by a max-target genesis masking a
        // securing-work bug.
        let forged = unsolvedForgery.replacingNonce(
            firstNonce(of: unsolvedForgery, from: 0) {
                $0 <= unsolvedForgery.target
            }
        )
        XCTAssertLessThanOrEqual(
            forged.proofOfWorkHash(), forged.target,
            "the forgery must carry real work, or exclusion is never exercised"
        )
        XCTAssertEqual(
            forged.target, truth.target,
            "the forgery claims exactly the work bound the honest block did"
        )
        XCTAssertNotEqual(
            try BlockHeader(node: forged).rawCID,
            try BlockHeader(node: truth).rawCID,
            "the forgery must be its own block, not the honest one"
        )
        return ForgedWeighedTipFixture(
            honestProducer: honestProducer,
            honest: honest,
            attackProducer: attackProducer,
            attack: attack,
            forged: forged
        )
    }

    /// Weighed-admit the fixture into `node`: the honest branch, the attack
    /// branch's valid prefix, then the forgery. Weighed admission judges work,
    /// not execution, so every one of these is accepted.
    private func weighedAdmitForgedBranch(
        _ fixture: ForgedWeighedTipFixture,
        into node: ChainProcess
    ) async throws {
        for block in fixture.honest {
            let outcome = try await node.importBlock(
                BlockHeader(node: block),
                remoteSource: FetcherContentSource(fixture.honestProducer),
                mode: .header
            )
            XCTAssertTrue(outcome.decision.isAccepted)
        }
        for block in fixture.attack.prefix(5) {
            let outcome = try await node.importBlock(
                BlockHeader(node: block),
                remoteSource: FetcherContentSource(fixture.attackProducer),
                mode: .header
            )
            XCTAssertTrue(outcome.decision.isAccepted)
        }
        let forged = try await node.importBlock(
            BlockHeader(node: fixture.forged),
            remoteSource: FetcherContentSource(fixture.attackProducer),
            mode: .header
        )
        XCTAssertTrue(
            forged.decision.isAccepted,
            "weighed admission judges work, not execution: it cannot refuse this"
        )
    }

    /// Deferred execution turning ON: a node that weighed-syncs a chain below its
    /// tip is NON-operable (weighed tip, validated tier at genesis) until the
    /// validate-on-candidacy walk executes the branch FORWARD and makes it
    /// operable. Folds in the forward-order assertion (strictly increasing from
    /// lastValidated+1, never tip-first).
    func testWeighedColdSyncBecomesOperableViaForwardExecutionWalk() async throws {
        let depth = 6
        let producer = try await nexusProcess()
        let chain = try await mineNexusChain(on: producer, depth: depth)

        let consumerProcess = try await nexusProcess()
        let consumer = makeService(process: consumerProcess)
        let genesisCID = try BlockHeader(
            node: await consumerProcess.canonicalTipBlock()
        ).rawCID

        // Weighed cold-sync: enter every below-tip block into fork choice on
        // verified work WITHOUT executing it. Driven straight at the process (no
        // canonical-commit publisher), so the walk does not auto-fire and the
        // intermediate non-operable state is observable.
        for block in chain {
            let outcome = try await consumerProcess.importBlock(
                BlockHeader(node: block),
                remoteSource: FetcherContentSource(producer),
                mode: .header
            )
            XCTAssertTrue(
                outcome.decision.isAccepted,
                "weighed admit must enter fork choice"
            )
        }

        // INTERMEDIATE: the header chain reached the tip, but nothing above
        // genesis is validated, so every act-on read still projects genesis.
        let weighedTipHeight = await consumerProcess.canonicalTipHeight()
        XCTAssertEqual(weighedTipHeight, UInt64(depth))
        let intermediateValidated = await consumerProcess
            .deepestValidatedCanonicalTip()
        XCTAssertEqual(intermediateValidated?.height, 0)
        XCTAssertEqual(intermediateValidated?.cid, genesisCID)
        let intermediateStatus = await consumer.status()
        XCTAssertEqual(intermediateStatus.tipCID, genesisCID)
        let intermediateTemplate = try await consumer
            .miningTemplate(MiningTemplateRequest())
        XCTAssertEqual(
            intermediateTemplate.block.parent?.rawCID, genesisCID,
            "a merely-weighed tip must not be a mining parent"
        )

        // Run the walk, recording each validated height to prove forward order.
        let recorder = ValidateStepRecorder()
        await consumer.setExecutionWalkObserver { recorder.record($0) }
        await consumer.runExecutionWalkPass()
        await consumer.setExecutionWalkObserver(nil)

        XCTAssertEqual(
            recorder.heights, (1...UInt64(depth)).map { $0 },
            "validate heights must be strictly increasing from genesis+1, "
                + "never tip-first"
        )

        // OPERABILITY: the validated tier now meets the canonical tier.
        let operableValidated = await consumerProcess
            .deepestValidatedCanonicalTip()
        let canonicalTipCID = try BlockHeader(
            node: await consumerProcess.canonicalTipBlock()
        ).rawCID
        XCTAssertEqual(operableValidated?.height, UInt64(depth))
        let validatedTipCID = try BlockHeader(
            node: await consumerProcess.validatedTipBlock()
        ).rawCID
        XCTAssertEqual(validatedTipCID, canonicalTipCID)
        let operableTemplate = try await consumer
            .miningTemplate(MiningTemplateRequest())
        XCTAssertEqual(
            operableTemplate.block.parent?.rawCID, canonicalTipCID,
            "once validated, the mining template must build on the canonical tip"
        )
    }

    /// `deepestValidatedCanonicalTip` is read on every walk iteration and every
    /// gated `status()`. Validated main-chain blocks form a prefix, so each
    /// read after the first must cost O(delta) store reads (the blocks
    /// validated since), never O(gap) — draining a backlog was O(gap²).
    func testValidatedTipProbeReadsScaleWithTheDeltaNotTheGap() async throws {
        let depth = 12
        let producer = try await nexusProcess()
        let chain = try await mineNexusChain(on: producer, depth: depth)
        let consumerProcess = try await nexusProcess()
        for block in chain {
            let outcome = try await consumerProcess.importBlock(
                BlockHeader(node: block),
                remoteSource: FetcherContentSource(producer),
                mode: .header
            )
            XCTAssertTrue(outcome.decision.isAccepted)
        }
        // Prime once (the full downward walk), then count only the reads the
        // per-block probes make while the tier advances one block at a time.
        _ = await consumerProcess.deepestValidatedCanonicalTip()
        await consumerProcess.resetValidatedTipStoreReadsForTesting()
        for (index, block) in chain.enumerated() {
            let outcome = try await consumerProcess.importBlock(
                BlockHeader(node: block),
                remoteSource: FetcherContentSource(producer),
                mode: .execution
            )
            XCTAssertTrue(outcome.decision.isAccepted)
            let validated = await consumerProcess.deepestValidatedCanonicalTip()
            XCTAssertEqual(validated?.height, UInt64(index + 1))
        }
        let reads = await consumerProcess.validatedTipStoreReadsForTesting()
        XCTAssertLessThanOrEqual(
            reads, 4 * depth,
            "\(reads) store reads for \(depth) probes: O(gap) per probe"
        )
    }

    /// The fast path re-reads the cached block's marker: an ungated probe can
    /// race an eviction that demoted the cached block and cleared the cache
    /// under the gate, then write the stale floor back. A demoted floor must
    /// fall back to the full walk, never be resurrected as validated.
    func testValidatedTipProbeDoesNotResurrectADemotedFloor() async throws {
        let depth = 4
        let producer = try await nexusProcess()
        let chain = try await mineNexusChain(on: producer, depth: depth)
        let consumerProcess = try await nexusProcess()
        for mode in [ImportMode.header, .execution] {
            for block in chain {
                let outcome = try await consumerProcess.importBlock(
                    BlockHeader(node: block),
                    remoteSource: FetcherContentSource(producer),
                    mode: mode
                )
                XCTAssertTrue(outcome.decision.isAccepted)
            }
        }
        let cached = await consumerProcess.deepestValidatedCanonicalTip()
        XCTAssertEqual(cached?.height, UInt64(depth))
        // Demote the cached tip behind the probe's back (the race).
        let tipCID = try BlockHeader(node: try XCTUnwrap(chain.last)).rawCID
        try await consumerProcess.demoteValidatedForTesting(tipCID)
        let probed = await consumerProcess.deepestValidatedCanonicalTip()
        XCTAssertEqual(probed?.height, UInt64(depth - 1))
        XCTAssertNotEqual(probed?.cid, tipCID, "a demoted floor is never validated")
    }

    /// Eviction demotes OFF-main-chain validated blocks; if that fork later
    /// wins, the main chain carries weighed holes BELOW still-validated
    /// blocks. A cached floor that sits below such a hole (parked at genesis
    /// by an intervening third fork) must not walk up into the hole and
    /// under-report: the probe must equal the full downward walk — the
    /// validated block above the hole.
    func testValidatedTipMatchesTheDownwardWalkAfterReorgBackOverAHole()
        async throws
    {
        // Fork A: validated to 4. Fork B: heavier, validated to 8, and A's
        // blocks are then off-chain deep enough to be demoted.
        let producerA = try await nexusProcess()
        let forkA = try await mineNexusChain(on: producerA, depth: 4)
        let producerB = try await nexusProcess()
        let forkB = try await mineNexusRewardChain(
            on: producerB, depth: 8, miner: CryptoUtils.generateKeyPair()
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-chain-service-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let policy = NodeResourcePolicy(
            maximumRetainedOffChainValidatedBlocks: 1,
            offChainValidatedRetentionDepth: 1
        )
        let consumerProcess = try await ChainProcess.open(
            configuration: NodeConfiguration(
                chainPath: ["Nexus"],
                storagePath: directory,
                privateKeyHex: String(repeating: "01", count: 32),
                resourcePolicy: policy
            )
        )
        for mode in [ImportMode.header, .execution] {
            for block in forkA {
                let outcome = try await consumerProcess.importBlock(
                    BlockHeader(node: block),
                    remoteSource: FetcherContentSource(producerA),
                    mode: mode
                )
                XCTAssertTrue(outcome.decision.isAccepted)
            }
        }
        for block in forkB {
            let outcome = try await consumerProcess.importBlock(
                BlockHeader(node: block),
                remoteSource: FetcherContentSource(producerB),
                mode: .header
            )
            XCTAssertTrue(outcome.decision.isAccepted)
        }
        let consumer = makeService(
            process: consumerProcess,
            executionBodySource: { cid, admit in
                try await admit(FetcherContentSource(producerB))
            }
        )
        await consumer.runExecutionWalkPass()
        let onB = await consumerProcess.deepestValidatedCanonicalTip()
        XCTAssertEqual(onB?.height, 8, "B validated to its tip")
        // Eviction: A's validated blocks are off-chain and deeper than the
        // retention depth below the validated head — all but one demoted.
        _ = try await consumerProcess.pruneUnpinnedVolumes()

        // A third fork C from genesis, heavier than B and weighed only: the
        // probe falls back (B's floor left the main chain) and parks the
        // cached floor at genesis — BELOW A's demoted holes.
        let producerC = try await nexusProcess()
        let forkC = try await mineNexusRewardChain(
            on: producerC, depth: 12, miner: CryptoUtils.generateKeyPair()
        )
        for block in forkC {
            let outcome = try await consumerProcess.importBlock(
                BlockHeader(node: block),
                remoteSource: FetcherContentSource(producerC),
                mode: .header
            )
            XCTAssertTrue(outcome.decision.isAccepted)
        }
        let onC = await consumerProcess.deepestValidatedCanonicalTip()
        XCTAssertEqual(onC?.height, 0, "nothing on C above genesis is validated")

        // Reorg back to A: extend it past C. The main chain is A with
        // demoted holes (A1-A3) below the A block that survived eviction.
        let moreA = try await mineNexusChain(on: producerA, depth: 10)
        for block in moreA {
            let outcome = try await consumerProcess.importBlock(
                BlockHeader(node: block),
                remoteSource: FetcherContentSource(producerA),
                mode: .header
            )
            XCTAssertTrue(outcome.decision.isAccepted)
        }
        let canonical = await consumerProcess.canonicalTipHeight()
        XCTAssertEqual(canonical, 14, "A must win again")
        let probed = await consumerProcess.deepestValidatedCanonicalTip()
        // The full downward walk from the tip, computed independently.
        var expected: (cid: String, height: UInt64)?
        var height: UInt64 = 14
        while true {
            if let cid = await consumerProcess.canonicalBlockCID(atHeight: height),
               await consumerProcess.blockValidated(cid) {
                expected = (cid, height)
                break
            }
            if height == 0 { break }
            height -= 1
        }
        XCTAssertEqual(expected?.height, 4, "A4 survived eviction above the holes")
        XCTAssertEqual(probed?.height, expected?.height)
        XCTAssertEqual(probed?.cid, expected?.cid)
        // And it keeps agreeing on a second probe (the fast path).
        let again = await consumerProcess.deepestValidatedCanonicalTip()
        XCTAssertEqual(again?.height, expected?.height)
    }

    /// Two forks demote at different heights (A5-A8 evicted first, D9-D10
    /// later), and a third fork parks the cached floor on the shared prefix
    /// BETWEEN them (T6). When D returns as the main chain — T1-T8 validated,
    /// D9-D10 holes, D11-D14 validated — a floor at or above the LOWEST
    /// demotion would walk up from T6 and stop at D9, reporting T8 while the
    /// downward walk reports D14. The gate must be the HIGHEST demotion.
    func testValidatedTipDoesNotWalkUpBetweenHolesOfDifferentForks()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-chain-service-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let policy = NodeResourcePolicy(
            maximumRetainedOffChainValidatedBlocks: 0,
            offChainValidatedRetentionDepth: 1
        )
        let consumerProcess = try await ChainProcess.open(
            configuration: NodeConfiguration(
                chainPath: ["Nexus"],
                storagePath: directory,
                privateKeyHex: String(repeating: "01", count: 32),
                resourcePolicy: policy
            )
        )
        func admitAll(
            _ blocks: [Block], from source: ChainProcess, mode: ImportMode
        ) async throws {
            for block in blocks {
                let outcome = try await consumerProcess.importBlock(
                    BlockHeader(node: block),
                    remoteSource: FetcherContentSource(source),
                    mode: mode
                )
                XCTAssertTrue(outcome.decision.isAccepted, "\(mode) admit")
            }
        }
        /// A producer that holds `prefix` (eager) so it can fork from its tip.
        func producer(holding prefix: [Block], from source: ChainProcess)
            async throws -> ChainProcess
        {
            let process = try await nexusProcess()
            for block in prefix {
                let outcome = try await process.importBlock(
                    BlockHeader(node: block),
                    remoteSource: FetcherContentSource(source)
                )
                XCTAssertTrue(outcome.decision.isAccepted)
            }
            return process
        }
        func downwardWalk(from height: UInt64) async -> (cid: String, height: UInt64)? {
            var height = height
            while true {
                if let cid = await consumerProcess.canonicalBlockCID(atHeight: height),
                   await consumerProcess.blockValidated(cid) {
                    return (cid, height)
                }
                if height == 0 { return nil }
                height -= 1
            }
        }

        // Trunk T1-T4, validated.
        let producerT = try await nexusProcess()
        let trunk = try await mineNexusChain(on: producerT, depth: 4)
        try await admitAll(trunk, from: producerT, mode: .header)
        try await admitAll(trunk, from: producerT, mode: .execution)
        // Fork A from T4 (A5-A8), validated while main.
        let producerA = try await producer(holding: trunk, from: producerT)
        let forkA = try await mineNexusRewardChain(
            on: producerA, depth: 4, miner: CryptoUtils.generateKeyPair()
        )
        try await admitAll(forkA, from: producerA, mode: .header)
        try await admitAll(forkA, from: producerA, mode: .execution)
        // Trunk continues T5-T12 (heavier): A is off-chain.
        let trunkMore = try await mineNexusChain(on: producerT, depth: 8)
        try await admitAll(trunkMore, from: producerT, mode: .header)
        // Fork D from T8 (D9-D14) will need bodies from producerD on the walk.
        let producerD = try await producer(
            holding: trunk + Array(trunkMore.prefix(4)), from: producerT
        )
        let consumer = makeService(
            process: consumerProcess,
            executionBodySource: { _, admit in
                try await admit(FetcherContentSource(producerD))
            }
        )
        await consumer.runExecutionWalkPass()
        let onTrunk = await consumerProcess.deepestValidatedCanonicalTip()
        XCTAssertEqual(onTrunk?.height, 12)
        // Eviction 1: A5-A8 demoted (holes 5-8 on fork A).
        _ = try await consumerProcess.pruneUnpinnedVolumes()

        let forkD = try await mineNexusRewardChain(
            on: producerD, depth: 6, miner: CryptoUtils.generateKeyPair()
        )
        try await admitAll(forkD, from: producerD, mode: .header)
        await consumer.runExecutionWalkPass()
        let onD = await consumerProcess.deepestValidatedCanonicalTip()
        XCTAssertEqual(onD?.height, 14, "D9-D14 validated while main")
        // Trunk T13-T16: D is off-chain; eviction 2 demotes D9-D10 (below
        // the retention ceiling 12 - 1), leaving D11-D14 validated ABOVE.
        let trunkEven = try await mineNexusChain(on: producerT, depth: 4)
        try await admitAll(trunkEven, from: producerT, mode: .header)
        let backOnTrunk = await consumerProcess.deepestValidatedCanonicalTip()
        XCTAssertEqual(backOnTrunk?.height, 12)
        _ = try await consumerProcess.pruneUnpinnedVolumes()
        let d9 = try BlockHeader(node: forkD[0]).rawCID
        let d11 = try BlockHeader(node: forkD[2]).rawCID
        let d9Validated = await consumerProcess.blockValidated(d9)
        let d11Validated = await consumerProcess.blockValidated(d11)
        XCTAssertFalse(d9Validated, "D9 demoted")
        XCTAssertTrue(d11Validated, "D11 retained above the hole")

        // Fork E from T6 (weighed only) parks the floor on the shared prefix
        // at T6 — above A's holes, below D's. Fork choice weighs SUBTREES at
        // the fork point: the trunk side of T6 is T7-T16 plus D9-D14 (16), so
        // E needs more than that to win here and still lose to D's return.
        let producerE = try await producer(
            holding: trunk + Array(trunkMore.prefix(2)), from: producerT
        )
        let forkE = try await mineNexusChain(on: producerE, depth: 18)
        try await admitAll(forkE, from: producerE, mode: .header)
        let onE = await consumerProcess.deepestValidatedCanonicalTip()
        XCTAssertEqual(onE?.height, 6, "floor parked at T6")

        // D returns, heavier than E: T1-T8 validated, D9-D10 holes, D11-D14
        // validated, D15-D22 weighed.
        let forkDMore = try await mineNexusRewardChain(
            on: producerD, depth: 8, miner: CryptoUtils.generateKeyPair()
        )
        try await admitAll(forkDMore, from: producerD, mode: .header)
        let canonical = await consumerProcess.canonicalTipHeight()
        XCTAssertEqual(canonical, 22)
        let probed = await consumerProcess.deepestValidatedCanonicalTip()
        let expected = await downwardWalk(from: 22)
        XCTAssertEqual(expected?.height, 14, "D14 is the true validated top")
        XCTAssertEqual(probed?.height, expected?.height)
        XCTAssertEqual(probed?.cid, expected?.cid)
    }

    /// Boot reconciliation demotes a walk-validated block whose owner pin is
    /// gone. That block can later sit on the main chain beneath validated
    /// blocks, so the reopened process must seed its hole ceiling from the
    /// boot demotions: a floor parked below the hole by an intervening fork
    /// must take the downward walk, not walk up into the hole.
    func testBootDemotedHoleIsRespectedAfterReorgBack() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-chain-service-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: directory,
            privateKeyHex: String(repeating: "01", count: 32)
        )
        var consumerProcess: ChainProcess? = try await ChainProcess.open(
            configuration: configuration
        )
        let producerA = try await nexusProcess()
        let forkA = try await mineNexusChain(on: producerA, depth: 6)
        for mode in [ImportMode.header, .execution] {
            for block in forkA {
                let outcome = try await consumerProcess!.importBlock(
                    BlockHeader(node: block),
                    remoteSource: FetcherContentSource(producerA),
                    mode: mode
                )
                XCTAssertTrue(outcome.decision.isAccepted)
            }
        }
        // A2 loses its owner pin; the next open demotes it.
        let a2 = try BlockHeader(node: forkA[1]).rawCID
        try await consumerProcess!.unpinValidatedOwnerForTesting(a2)
        consumerProcess = nil
        consumerProcess = try await ChainProcess.open(configuration: configuration)
        let a2Validated = await consumerProcess!.blockValidated(a2)
        XCTAssertFalse(a2Validated, "boot reconciliation demoted A2")

        // A heavier fork F from genesis parks the floor at genesis.
        let producerF = try await nexusProcess()
        let forkF = try await mineNexusRewardChain(
            on: producerF, depth: 8, miner: CryptoUtils.generateKeyPair()
        )
        for block in forkF {
            let outcome = try await consumerProcess!.importBlock(
                BlockHeader(node: block),
                remoteSource: FetcherContentSource(producerF),
                mode: .header
            )
            XCTAssertTrue(outcome.decision.isAccepted)
        }
        let onF = await consumerProcess!.deepestValidatedCanonicalTip()
        XCTAssertEqual(onF?.height, 0)

        // A returns: A1 validated, A2 a hole, A3-A6 validated above it.
        let forkAMore = try await mineNexusChain(on: producerA, depth: 4)
        for block in forkAMore {
            let outcome = try await consumerProcess!.importBlock(
                BlockHeader(node: block),
                remoteSource: FetcherContentSource(producerA),
                mode: .header
            )
            XCTAssertTrue(outcome.decision.isAccepted)
        }
        let canonical = await consumerProcess!.canonicalTipHeight()
        XCTAssertEqual(canonical, 10, "A must win again")
        let probed = await consumerProcess!.deepestValidatedCanonicalTip()
        XCTAssertEqual(probed?.height, 6, "the downward walk's A6, not A1")
        let a6 = try BlockHeader(node: forkA[5]).rawCID
        XCTAssertEqual(probed?.cid, a6)
    }

    /// The probe's cached floor is only a floor while that block is still the
    /// main-chain block at its height: a heavier fork below it must fall back
    /// to the full walk and report the validated prefix of the NEW main chain.
    func testValidatedTipFallsBackBelowAReorgedCachePoint() async throws {
        let producer = try await nexusProcess()
        let chain = try await mineNexusChain(on: producer, depth: 4)
        let consumerProcess = try await nexusProcess()
        let genesisCID = try BlockHeader(
            node: await consumerProcess.canonicalTipBlock()
        ).rawCID
        for mode in [ImportMode.header, .execution] {
            for block in chain {
                let outcome = try await consumerProcess.importBlock(
                    BlockHeader(node: block),
                    remoteSource: FetcherContentSource(producer),
                    mode: mode
                )
                XCTAssertTrue(outcome.decision.isAccepted)
            }
        }
        let cached = await consumerProcess.deepestValidatedCanonicalTip()
        XCTAssertEqual(cached?.height, 4)

        // A heavier competing fork from genesis (reward blocks, so its CIDs
        // differ), weighed only: the main chain moves and nothing on it above
        // genesis is validated.
        let rival = try await nexusProcess()
        let fork = try await mineNexusRewardChain(
            on: rival, depth: 6, miner: CryptoUtils.generateKeyPair()
        )
        for block in fork {
            let outcome = try await consumerProcess.importBlock(
                BlockHeader(node: block),
                remoteSource: FetcherContentSource(rival),
                mode: .header
            )
            XCTAssertTrue(outcome.decision.isAccepted)
        }
        let canonical = await consumerProcess.canonicalTipHeight()
        XCTAssertEqual(canonical, 6, "the fork must win")
        let reorged = await consumerProcess.deepestValidatedCanonicalTip()
        XCTAssertEqual(reorged?.height, 0)
        XCTAssertEqual(reorged?.cid, genesisCID)
    }

    /// A restart under deferred execution commonly leaves validated < canonical,
    /// and the walk is otherwise armed only by a canonical commit: with no
    /// network traffic nothing would ever run it and templates would build on
    /// the stale validated tip. Service start (`restoreLocalTransactions`, the
    /// daemon's pre-networking hook) must arm it itself.
    func testServiceStartDrivesTheExecutionWalkWhenValidatedLagsCanonical()
        async throws
    {
        let depth = 4
        let producer = try await nexusProcess()
        let chain = try await mineNexusChain(on: producer, depth: depth)
        let consumerProcess = try await nexusProcess()
        for block in chain {
            let outcome = try await consumerProcess.importBlock(
                BlockHeader(node: block),
                remoteSource: FetcherContentSource(producer),
                mode: .header
            )
            XCTAssertTrue(outcome.decision.isAccepted)
        }
        let consumer = makeService(process: consumerProcess)
        let before = await consumerProcess.deepestValidatedCanonicalTip()
        XCTAssertEqual(before?.height, 0, "restart state: validated lags")

        try await consumer.restoreLocalTransactions()

        var validated: UInt64?
        for _ in 0..<500 {
            validated = await consumerProcess.deepestValidatedCanonicalTip()?.height
            if validated == UInt64(depth) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(
            validated, UInt64(depth),
            "service start must converge validated to canonical unprompted"
        )
    }

    /// A gap in the below-tip range parks the walk at gap-1: the node keeps
    /// acting on the last validated tip (no wedge) and resumes to the tip once
    /// the missing block becomes admissible.
    func testExecutionWalkParksAtGapAndResumesOnRelease() async throws {
        let depth = 6
        let gapAt = 3 // heights 1,2 available; 3 withheld; 4,5,6 blocked behind it
        let producer = try await nexusProcess()
        let chain = try await mineNexusChain(on: producer, depth: depth)

        let consumerProcess = try await nexusProcess()
        let consumer = makeService(process: consumerProcess)

        // Weighed-admit only the blocks below the gap (heights 1..gapAt-1).
        for block in chain.prefix(gapAt - 1) {
            let outcome = try await consumerProcess.importBlock(
                BlockHeader(node: block),
                remoteSource: FetcherContentSource(producer),
                mode: .header
            )
            XCTAssertTrue(outcome.decision.isAccepted)
        }

        // The walk validates up to the last contiguous weighed block and parks.
        await consumer.runExecutionWalkPass()
        let parked = await consumerProcess.deepestValidatedCanonicalTip()
        XCTAssertEqual(
            parked?.height, UInt64(gapAt - 1),
            "the walk must park one block below the gap"
        )
        // Still operable on the parked tip: a template builds on it, no wedge.
        let parkedTipCID = try BlockHeader(
            node: await consumerProcess.validatedTipBlock()
        ).rawCID
        let parkedTemplate = try await consumer
            .miningTemplate(MiningTemplateRequest())
        XCTAssertEqual(parkedTemplate.block.parent?.rawCID, parkedTipCID)

        // Release the withheld block and the rest of the range.
        for block in chain.suffix(from: gapAt - 1) {
            let outcome = try await consumerProcess.importBlock(
                BlockHeader(node: block),
                remoteSource: FetcherContentSource(producer),
                mode: .header
            )
            XCTAssertTrue(outcome.decision.isAccepted)
        }

        // The walk resumes and reaches the tip.
        await consumer.runExecutionWalkPass()
        let resumed = await consumerProcess.deepestValidatedCanonicalTip()
        XCTAssertEqual(resumed?.height, UInt64(depth))
        let resumedTipCID = try BlockHeader(
            node: await consumerProcess.validatedTipBlock()
        ).rawCID
        let resumedCanonicalCID = try BlockHeader(
            node: await consumerProcess.canonicalTipBlock()
        ).rawCID
        XCTAssertEqual(resumedTipCID, resumedCanonicalCID)
    }

    /// Deferred execution + boundary-only weighed store (Lattice 30.3.0): a
    /// weighed admit no longer stores the block BODY, so the validate walk must
    /// FETCH each canonical block's body over the network. Proven with a
    /// fetch-granularity counter — body (tier-3) fetches equal the CANONICAL
    /// length, never the total weighed block count (canonical + losing siblings):
    /// the below-tip saving. The joiner still reaches its validated tip and builds
    /// a template on the canonical tip. Also folds in the forward-order assertion.
    func testExecutionWalkFetchesBodyForCanonicalOnlyNotSiblings() async throws {
        let depth = 6
        let siblingDepth = 4
        let miner = CryptoUtils.generateKeyPair()
        let sibMiner = CryptoUtils.generateKeyPair()
        let producer = try await nexusProcess()
        let canonical = try await mineNexusRewardChain(
            on: producer, depth: depth, miner: miner
        )
        // A strictly shorter competing fork from genesis: less work, so it stays a
        // below-tip loser the walk never validates.
        let siblingProducer = try await nexusProcess()
        let siblings = try await mineNexusRewardChain(
            on: siblingProducer, depth: siblingDepth, miner: sibMiner
        )

        let consumerProcess = try await nexusProcess()
        let bodySource = CountingValidateBodySource(producer: producer)
        let consumer = makeService(
            process: consumerProcess,
            executionBodySource: bodySource.admission()
        )

        // Weighed cold-sync the canonical chain FIRST (incumbent), then the losing
        // fork — every admit stores only the boundary (a boundary fetch), no body.
        var boundaryFetches = 0
        for block in canonical {
            let outcome = try await consumerProcess.importBlock(
                BlockHeader(node: block),
                remoteSource: FetcherContentSource(producer),
                mode: .header
            )
            XCTAssertTrue(outcome.decision.isAccepted, "canonical weighed admit")
            boundaryFetches += 1
        }
        for block in siblings {
            let outcome = try await consumerProcess.importBlock(
                BlockHeader(node: block),
                remoteSource: FetcherContentSource(siblingProducer),
                mode: .header
            )
            XCTAssertTrue(
                outcome.decision.isAccepted, "sibling weighed admit (side block)"
            )
            boundaryFetches += 1
        }

        // Not operable yet: canonical tip at depth, validated tier still genesis.
        let preWalkCanonical = await consumerProcess.canonicalTipHeight()
        XCTAssertEqual(preWalkCanonical, UInt64(depth))
        let preWalkValidated = await consumerProcess
            .deepestValidatedCanonicalTip()?.height
        XCTAssertEqual(preWalkValidated, 0)

        // Run the walk. It fetches ONLY canonical bodies, strictly forward.
        let recorder = ValidateStepRecorder()
        await consumer.setExecutionWalkObserver { recorder.record($0) }
        await consumer.runExecutionWalkPass()
        await consumer.setExecutionWalkObserver(nil)

        XCTAssertEqual(
            recorder.heights, (1...UInt64(depth)).map { $0 },
            "validate heights strictly forward from genesis+1, never tip-first"
        )

        // Fetch granularity: body fetches == canonical length, NOT total blocks.
        let canonicalCIDs = try canonical.map { try BlockHeader(node: $0).rawCID }
        XCTAssertEqual(
            bodySource.fetchedBlockCIDs.count, depth,
            "exactly one body fetch per canonical block"
        )
        XCTAssertEqual(
            Set(bodySource.fetchedBlockCIDs), Set(canonicalCIDs),
            "only canonical bodies fetched; no losing-sibling body fetched"
        )
        XCTAssertEqual(boundaryFetches, depth + siblingDepth)
        XCTAssertLessThan(
            bodySource.fetchedBlockCIDs.count, boundaryFetches,
            "body fetches must be far fewer than total (boundary) fetches"
        )

        // Operable: the validated tier meets the canonical tier.
        let canonicalTipCID = try BlockHeader(
            node: await consumerProcess.canonicalTipBlock()
        ).rawCID
        let operableValidated = await consumerProcess
            .deepestValidatedCanonicalTip()?.height
        XCTAssertEqual(operableValidated, UInt64(depth))
        let template = try await consumer
            .miningTemplate(MiningTemplateRequest())
        XCTAssertEqual(
            template.block.parent?.rawCID, canonicalTipCID,
            "once validated, the mining template builds on the canonical tip"
        )
    }

    /// Liveness for the network-fetch case: a validate whose body is WITHHELD
    /// parks the validated tip at gap-1 (node stays operable on that tip, no
    /// wedge), and releasing the body lets the walk's OWN retry timer re-drive it
    /// to the tip with no new canonical commit. Extends the 3a.2 park-and-resume
    /// test for bodies pulled over the network.
    func testExecutionWalkParksOnWithheldBodyAndAutoResumesOnRelease()
        async throws {
        let depth = 6
        let gapAt: UInt64 = 3
        let miner = CryptoUtils.generateKeyPair()
        let producer = try await nexusProcess()
        let canonical = try await mineNexusRewardChain(
            on: producer, depth: depth, miner: miner
        )
        let gapCID = try BlockHeader(node: canonical[Int(gapAt) - 1]).rawCID

        let consumerProcess = try await nexusProcess()
        let bodySource = CountingValidateBodySource(producer: producer)
        bodySource.withhold(gapCID)
        let consumer = makeService(
            process: consumerProcess,
            executionBodySource: bodySource.admission(),
            executionWalkRetryInterval: .milliseconds(20)
        )

        for block in canonical {
            let outcome = try await consumerProcess.importBlock(
                BlockHeader(node: block),
                remoteSource: FetcherContentSource(producer),
                mode: .header
            )
            XCTAssertTrue(outcome.decision.isAccepted)
        }

        // Walk parks one block below the withheld body; still operable there.
        await consumer.runExecutionWalkPass()
        let parkedHeight = await consumerProcess
            .deepestValidatedCanonicalTip()?.height
        XCTAssertEqual(
            parkedHeight, gapAt - 1,
            "the walk parks one block below the withheld body"
        )
        let parkedTipCID = try BlockHeader(
            node: await consumerProcess.validatedTipBlock()
        ).rawCID
        let parkedTemplate = try await consumer
            .miningTemplate(MiningTemplateRequest())
        XCTAssertEqual(
            parkedTemplate.block.parent?.rawCID, parkedTipCID,
            "operable on the parked tip, no wedge"
        )

        // Release the body: the park armed a retry, so the walk re-drives itself
        // to the tip without any new canonical commit.
        bodySource.release(gapCID)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var resumed = await consumerProcess
            .deepestValidatedCanonicalTip()?.height
        while resumed != UInt64(depth), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
            resumed = await consumerProcess
                .deepestValidatedCanonicalTip()?.height
        }
        XCTAssertEqual(
            resumed, UInt64(depth),
            "the walk auto-resumes to the tip once the body is released"
        )
        let resumedTipCID = try BlockHeader(
            node: await consumerProcess.validatedTipBlock()
        ).rawCID
        let canonicalTipCID = try BlockHeader(
            node: await consumerProcess.canonicalTipBlock()
        ).rawCID
        XCTAssertEqual(resumedTipCID, canonicalTipCID)
    }

    /// Injectable validate-body source that records every block whose body it is
    /// asked to fetch and can withhold a specific block's body (serving an empty
    /// source so the deferred body stays missing → `.unavailable`).
    private final class CountingValidateBodySource: @unchecked Sendable {
        private let producer: ChainProcess
        private let lock = NSLock()
        private var _fetched: [String] = []
        private var _withheld: Set<String> = []

        init(producer: ChainProcess) { self.producer = producer }

        var fetchedBlockCIDs: [String] {
            lock.withLock { _fetched }
        }

        func withhold(_ blockCID: String) {
            lock.withLock { _ = _withheld.insert(blockCID) }
        }

        func release(_ blockCID: String) {
            lock.withLock { _ = _withheld.remove(blockCID) }
        }

        func admission() -> ClosureNetworkInterface.ExecutionBodyImport {
            { [self] blockCID, admit in
                lock.withLock { _fetched.append(blockCID) }
                let withheld = lock.withLock { _withheld.contains(blockCID) }
                let source: any ContentSource = withheld
                    ? InMemoryContentStore()
                    : FetcherContentSource(producer)
                return try await admit(source)
            }
        }
    }

    /// Mine `depth` blocks on `producer`, each paying `miner` and carrying one
    /// of its transactions (so each block has a real, boundary-excluded BODY
    /// the validate walk must fetch), returned in ascending-height order.
    private func mineNexusRewardChain(
        on producer: ChainProcess,
        depth: Int,
        miner: (privateKey: String, publicKey: String)
    ) async throws -> [Block] {
        let service = makeService(process: producer)
        var blocks: [Block] = []
        for index in 0..<depth {
            let marker = try signedTransaction(
                key: miner,
                chainPath: ["Nexus"],
                nonce: UInt64(index)
            )
            _ = try await service.submitTransaction(
                SubmitTransactionRequest(transaction: marker)
            )
            let template = try await service.miningTemplate(
                MiningTemplateRequest(recipients: [MiningRecipient(
                    chainPath: ["Nexus"],
                    address: CryptoUtils.createAddress(from: miner.publicKey)
                )])
            )
            XCTAssertEqual(
                try template.block.transactions.node?.allKeysAndValues().count,
                1,
                "block \(index) must carry the miner's transaction"
            )
            // Solve the block rather than admitting the template's nonce as
            // mined. Under the old windowed retarget this chain sat at exactly
            // the maximum target, where nonce 0 always qualified; the absolute
            // schedule hardens slightly each block, so an unsolved block is
            // refused for want of work -- and because that stalls the tip, the
            // NEXT transaction's nonce is then wrong, several blocks away
            // from the cause.
            let block = template.block.replacingNonce(
                firstNonce(of: template.block, from: 0) {
                    $0 <= template.block.target
                }
            )
            let outcome = try await producer.importBlock(BlockHeader(node: block))
            XCTAssertTrue(
                outcome.decision.isAccepted,
                "reward block \(index) must be accepted"
            )
            blocks.append(block)
        }
        return blocks
    }

    private func nexusProcess() async throws -> ChainProcess {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-chain-service-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try await ChainProcess.open(
            configuration: NodeConfiguration(
                chainPath: ["Nexus"],
                storagePath: directory,
                privateKeyHex: String(repeating: "01", count: 32)
            )
        )
    }

    private func makeService(
        process: ChainProcess,
        acceptedBlockPublisher: @escaping ClosureNetworkInterface.AcceptedBlockPublisher = { _ in },
        acceptedTransactionPublisher:
            @escaping ClosureNetworkInterface.AcceptedTransactionPublisher = { _ in },
        executionBodySource: ClosureNetworkInterface.ExecutionBodyImport? = nil,
        executionWalkRetryInterval: Duration = .seconds(4),
        mempoolMaxCount: Int = 10_000,
        parentLevel: (any ParentLevel)? = nil
    ) -> ChainService {
        ChainService(
            process: process,
            network: ClosureNetworkInterface(
                acceptedBlockPublisher: acceptedBlockPublisher,
                acceptedTransactionPublisher: acceptedTransactionPublisher,
                executionBodySource: executionBodySource
            ),
            parentLevel: parentLevel,
            executionWalkRetryInterval: executionWalkRetryInterval,
            mempoolMaxCount: mempoolMaxCount
        )
    }

    private struct AnchoredChildGenesis {
        let block: Block
        let header: BlockHeader
        let carrierCID: String
        let seed: ChildGenesisSeed
    }

    private struct ActiveChildServiceFixture {
        let parent: ChainProcess
        let process: ChainProcess
        let service: ChainService
        let parentCarrier: Block
    }

    /// `carrierInterval` is the milliseconds between the Nexus genesis and the
    /// carrier recording the child. The parent schedule that follows is the
    /// maximum target scaled by `carrierInterval / targetBlockTime`, so a test
    /// that searches nonces can pick a parent target it solves in a handful
    /// of hashes.
    private func activeChildService(
        spec: ChainSpec,
        carrierInterval: Int64 = 1,
        carrierTarget: UInt256? = nil,
        policyModules: [WasmPolicyModuleHeader] = []
    ) async throws -> ActiveChildServiceFixture {
        let parent = try await nexusProcess()
        for module in policyModules {
            try await module.storeRecursively(storer: parent)
        }
        let parentGenesis = try await parent.canonicalTipBlock()
        let child = try await anchoredChildGenesis(
            parent: parent,
            parentGenesis: parentGenesis,
            childTimestamp: 1,
            carrierNonce: 0,
            carrierInterval: carrierInterval,
            carrierTarget: carrierTarget,
            spec: spec
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-child-service-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let process = try await ChainProcess.open(configuration: NodeConfiguration(
            chainPath: ["Nexus", "Payments"],
            storagePath: directory,
            privateKeyHex: String(repeating: "02", count: 32)
        ))
        for module in policyModules {
            try await module.storeRecursively(storer: process)
        }
        let activated = try await process.activateChildGenesis(
            seed: child.seed,
            confirmParentRecordedGenesis: { _ in true }
        )
        XCTAssertTrue(
            activated,
            "the seeded child genesis must self-admit for maxBlockSize \(spec.maxBlockSize)"
        )
        let resolvedParentCarrier = try await BlockHeader(
            rawCID: child.carrierCID,
            node: nil,
            encryptionInfo: nil
        ).resolve(fetcher: parent)
        let parentCarrier = try XCTUnwrap(
            resolvedParentCarrier.node
        )
        return ActiveChildServiceFixture(
            parent: parent,
            process: process,
            service: makeService(process: process),
            parentCarrier: parentCarrier
        )
    }

    private func anchoredChildGenesis(
        parent: ChainProcess,
        parentGenesis: Block,
        childTimestamp: Int64,
        carrierNonce: UInt64,
        carrierInterval: Int64 = 1,
        carrierTarget: UInt256? = nil,
        spec: ChainSpec = NexusGenesis.spec
    ) async throws -> AnchoredChildGenesis {
        // A self-contained child genesis (empty parentState) recorded on the
        // parent by a plain GenesisAction — never carried on the carrier's
        // children. The child rebuilds this identical genesis from `seed` and
        // self-admits it (activateChildGenesis).
        let seed = ChildGenesisSeed(
            spec: spec, premineTo: nil, timestamp: childTimestamp
        )
        let block = try await ChildGenesisBuilder.build(
            seed: seed,
            chainPath: ["Nexus", "Payments"],
            fetcher: parent
        )
        let header = try BlockHeader(node: block)
        let authorization = try signedTransaction(
            key: CryptoUtils.generateKeyPair(),
            chainPath: ["Nexus"],
            genesisActions: [GenesisAction(
                directory: "Payments",
                blockCID: header.rawCID
            )]
        )
        try await VolumeImpl<Transaction>(node: authorization).storeRecursively(
            storer: parent
        )
        // The carrier is the parent's block 1, which IS its difficulty anchor:
        // the target it commits is where the chain's schedule begins. A test
        // that needs a hard parent has to commit one here and mine it, the way
        // a launch does. It cannot mine its way down instead -- the absolute
        // schedule moves one doubling per `halfLife` blocks, so reaching
        // a hard target by retargeting would take thousands of blocks.
        let built = try await BlockBuilder.buildBlock(
            previous: parentGenesis,
            transactions: [authorization],
            timestamp: parentGenesis.timestamp + carrierInterval,
            target: carrierTarget,
            nonce: carrierNonce,
            fetcher: parent
        )
        let carrier = carrierTarget == nil
            ? built
            : built.replacingNonce(
                firstNonce(of: built, from: carrierNonce) { $0 <= built.target }
            )
        let carrierHeader = try BlockHeader(node: carrier)
        let parentAdmission = try await parent.importBlock(carrierHeader)
        XCTAssertNotNil(parentAdmission.parentCarrierLink)
        return AnchoredChildGenesis(
            block: block,
            header: header,
            carrierCID: carrierHeader.rawCID,
            seed: seed
        )
    }

}



private actor AttemptCounter {
    private var value = 0

    func next() -> Int {
        value += 1
        return value
    }

    func count() -> Int { value }
}

private enum TestPublicationError: Error {
    case failed
}

private actor CanonicalCommitLatch {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        let entryWaiters = self.entryWaiters
        self.entryWaiters.removeAll()
        for waiter in entryWaiters { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        let releaseWaiters = self.releaseWaiters
        self.releaseWaiters.removeAll()
        for waiter in releaseWaiters { waiter.resume() }
    }
}

private actor PublishedBlocks {
    private var values: [String] = []

    func record(_ blockCID: String) {
        values.append(blockCID)
    }

    func all() -> [String] {
        values
    }

    func count() -> Int {
        values.count
    }
}

private actor ProvisionalParents {
    private var values: [Block] = []

    func record(_ block: Block) {
        values.append(block)
    }

    func first() -> Block? {
        values.first
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {
        handler(error)
    }
}



private actor HeldGate {
    private(set) var isHeld = false
    func hold() { isHeld = true }
    func release() { isHeld = false }
}

/// A parent level whose validated-tip read, the start of a hosted child's
/// candidate build, first runs `hold`: a test parks the build there.
private final class GatedTipParentLevel: ParentLevel, Sendable {
    let base: any ParentLevel
    let hold: @Sendable () async -> Void

    init(_ base: any ParentLevel, hold: @escaping @Sendable () async -> Void) {
        self.base = base
        self.hold = hold
    }

    func hasProducedState(_ stateCID: String) async -> Bool {
        await base.hasProducedState(stateCID)
    }

    func recordedGenesisLink(
        directory: String, childGenesisCID: String
    ) async -> ParentGenesisLink? {
        await base.recordedGenesisLink(
            directory: directory, childGenesisCID: childGenesisCID
        )
    }

    func anchoredGenesisCID(directory: String) async -> String? {
        await base.anchoredGenesisCID(directory: directory)
    }

    func runReport(carrier: String, directory: String) async -> ParentRunReport? {
        await base.runReport(carrier: carrier, directory: directory)
    }

    func validatedTip() async -> (cid: String, block: Block)? {
        await hold()
        return await base.validatedTip()
    }

    var contentSource: any ContentSource { base.contentSource }
}

private actor ShutdownReturned {
    private(set) var value = false
    func mark() { value = true }
}

/// A hosted child level that admits no mined handoff.
private final class DecliningChildLevel: ChildLevel, Sendable {
    private let level: any ChildLevel

    init(_ level: any ChildLevel) {
        self.level = level
    }

    var directory: String { level.directory }

    func parentChanged(_ change: ParentChange) {
        level.parentChanged(change)
    }

    var readyCandidate: ReadyCandidate? { level.readyCandidate }

    func admitMined(block: Block, proof: ChildBlockProof) async -> Bool { false }
}

/// A hosted child level that runs `observe` when a mined handoff reaches
/// it, before admitting.
private final class HandoffObservingChildLevel: ChildLevel, Sendable {
    private let level: any ChildLevel
    private let observe: @Sendable () async -> Void

    init(_ level: any ChildLevel, observe: @escaping @Sendable () async -> Void) {
        self.level = level
        self.observe = observe
    }

    var directory: String { level.directory }

    func parentChanged(_ change: ParentChange) {
        level.parentChanged(change)
    }

    var readyCandidate: ReadyCandidate? { level.readyCandidate }

    func admitMined(block: Block, proof: ChildBlockProof) async -> Bool {
        await observe()
        return await level.admitMined(block: block, proof: proof)
    }
}

private actor ReceivedProofs {
    private var received: [(cid: String, proof: ChildBlockProof)] = []

    func record(_ block: Block, _ proof: ChildBlockProof) {
        received.append(((try? BlockHeader(node: block).rawCID) ?? "", proof))
    }

    func all() -> [(cid: String, proof: ChildBlockProof)] { received }
}

private actor GrandchildCID {
    private(set) var value: String?

    func set(_ cid: String) { value = cid }
}
