import Crypto
import Foundation
import Ivy
import Lattice
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

        let reward = try decoder.decode(
            MiningReward.self,
            from: encoder.encode(MiningReward(
                chainPath: ["Nexus"],
                transaction: transaction
            ))
        )
        XCTAssertNotNil(reward.transaction.body.node)
        XCTAssertEqual(reward.transaction.body.rawCID, transaction.body.rawCID)
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
                halvingInterval: 100
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
        let result = try await service.admitNetworkCandidate(
            header,
            authenticatedChildPackage: nil,
            preparingChildDirectories: [],
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
            try await service.admitNetworkCandidate(
                unresolved,
                authenticatedChildPackage: nil,
                preparingChildDirectories: [],
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

    func testDuplicateWorkIsReportedWithoutClaimingNewAcceptance() async throws {
        let process = try await nexusProcess()
        let service = makeService(process: process)
        let template = try await service.miningTemplate(MiningTemplateRequest())
        let first = try await process.admit(BlockHeader(node: template.block))
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
        func reward() throws -> MiningReward {
            let key = CryptoUtils.generateKeyPair()
            return MiningReward(
                chainPath: ["Nexus"],
                transaction: try signedTransaction(
                    key: key,
                    chainPath: ["Nexus"],
                    accountActions: [AccountAction(
                        owner: CryptoUtils.createAddress(from: key.publicKey),
                        delta: 1
                    )]
                )
            )
        }
        let first = try await service.miningTemplate(
            MiningTemplateRequest(rewards: [try reward()])
        )
        let second = try await service.miningTemplate(
            MiningTemplateRequest(rewards: [try reward()])
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

    func testExternalRewardTransactionProducesAndSubmitsWork() async throws {
        let process = try await nexusProcess()
        let publishedBlocks = PublishedBlocks()
        let service = makeService(
            process: process,
            acceptedBlockPublisher: { blockCID in
                await publishedBlocks.record(blockCID)
            }
        )
        let miner = CryptoUtils.generateKeyPair()
        let reward = try signedTransaction(
            key: miner,
            chainPath: ["Nexus"],
            accountActions: [AccountAction(
                owner: CryptoUtils.createAddress(from: miner.publicKey),
                delta: 1
            )]
        )

        let template = try await service.miningTemplate(
            MiningTemplateRequest(rewards: [MiningReward(
                chainPath: ["Nexus"],
                transaction: reward
            )])
        )
        XCTAssertEqual(template.block.nonce, 0)
        XCTAssertEqual(template.chainPath, ["Nexus"])
        XCTAssertEqual(
            try template.block.transactions.node?.allKeysAndValues().count,
            1
        )
        XCTAssertEqual(
            try template.block.transactions.node?.allKeysAndValues()
                .values.first?.rawCID,
            try VolumeImpl<Transaction>(node: reward).rawCID
        )
        XCTAssertEqual(Set(reward.signatures.keys), [miner.publicKey])
        XCTAssertFalse(reward.signatures.keys.contains(
            process.configuration.processPublicKey
        ))

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
    }

    func testStateInvalidRewardIsRejectedInsteadOfSilentlyDropped() async throws {
        let service = makeService(process: try await nexusProcess())
        let issued = try await service.miningTemplate(MiningTemplateRequest())
        let miner = CryptoUtils.generateKeyPair()
        let rewardWithNonceGap = try signedTransaction(
            key: miner,
            chainPath: ["Nexus"],
            accountActions: [AccountAction(
                owner: CryptoUtils.createAddress(from: miner.publicKey),
                delta: 1
            )],
            nonce: 1
        )

        await XCTAssertThrowsErrorAsync(
            try await service.miningTemplate(MiningTemplateRequest(
                rewards: [MiningReward(
                    chainPath: ["Nexus"],
                    transaction: rewardWithNonceGap
                )]
            ))
        ) { error in
            XCTAssertEqual(error as? ChainServiceError, .invalidRewardTransaction)
        }

        let submitted = try await service.submitWork(SubmitWorkRequest(
            workID: issued.workID,
            nonce: 0
        ))
        XCTAssertTrue(submitted.accepted)
    }

    func testRewardPlanBindsDeclaredPathBeforeRouting() async throws {
        let service = makeService(process: try await nexusProcess())
        let miner = CryptoUtils.generateKeyPair()
        let reward = try signedTransaction(
            key: miner,
            chainPath: ["Nexus"],
            accountActions: [AccountAction(
                owner: CryptoUtils.createAddress(from: miner.publicKey),
                delta: 1
            )]
        )

        await XCTAssertThrowsErrorAsync(
            try await service.miningTemplate(MiningTemplateRequest(rewards: [
                MiningReward(
                    chainPath: ["Nexus", "Payments"],
                    transaction: reward
                )
            ]))
        ) { error in
            XCTAssertEqual(error as? ChainServiceError, .invalidRewardPlan)
        }
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
                fee: .max,
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
        let laterRequestStarted = TaskStartLatch()
        let laterTemplate = Task {
            await laterRequestStarted.signal()
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
        let admission = try await process.admit(BlockHeader(node: mined.block))
        guard case .canonicalized(let commit) = admission.decision else {
            return XCTFail("expected canonical direct admission")
        }

        let receipt = await service.enqueueCanonicalCommit(commit)
        let laterRequestStarted = TaskStartLatch()
        let laterTemplate = Task {
            await laterRequestStarted.signal()
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
            mainChainBlocksRemoved: [blockCID]
        ))
        let added = await service.enqueueCanonicalCommit(ChainCommit(
            revision: 3,
            tipHash: blockCID,
            mainChainBlocksAdded: [blockCID: block.height]
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
            mainChainBlocksAdded: ["missing-block": 0]
        ))
        let laterRequestStarted = TaskStartLatch()
        let laterTemplate = Task {
            await laterRequestStarted.signal()
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
            ),
            hierarchy: IvyConfig(
                signingKey: configuration.signingKey,
                listenPort: 0,
                stunServers: [],
                maxConnections: IvyConfig.defaultMaxConnections,
                maxConnectionsPerNetgroup: IvyConfig.defaultMaxConnections,
                relayEnabled: false,
                carriers: [],
                mode: .privateNetwork
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
        let handlers = NodeNetworkHandlers(admission: { admission in
            try await service.admitNetworkCandidate(
                admission.header,
                authenticatedChildPackage: admission.authenticatedChildPackage,
                preparingChildDirectories: admission.preparingChildDirectories,
                contentSource: admission.contentSource
            )
        })
        do {
            try await runtime.start(process: process, handlers: handlers)
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

            try await runtime.start(process: process, handlers: handlers)
            await runtime.stop()
        } catch {
            await runtime.stop()
            throw error
        }
    }

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
        let reward = try signedTransaction(
            key: rewardKey,
            chainPath: ["Nexus"],
            accountActions: [AccountAction(
                owner: CryptoUtils.createAddress(from: rewardKey.publicKey),
                delta: 1
            )]
        )
        _ = try await service.submitTransaction(
            SubmitTransactionRequest(transaction: removed)
        )
        let firstTemplate = try await service.miningTemplate(
            MiningTemplateRequest(rewards: [MiningReward(
                chainPath: ["Nexus"],
                transaction: reward
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
            nonce: 0
        ))
        let addedDescendant = try await process.canonicalTipBlock()
        let addedDescendantCID = try BlockHeader(node: addedDescendant).rawCID

        let outstanding = try await service.miningTemplate(
            MiningTemplateRequest()
        )
        let receipt = await service.enqueueCanonicalCommit(ChainCommit(
            tipHash: addedDescendantCID,
            mainChainBlocksAdded: [
                addedBlockCID: addedBlock.height,
                addedDescendantCID: addedDescendant.height,
            ],
            mainChainBlocksRemoved: [removedBlockCID]
        ))
        await receipt.wait()

        let outstandingSubmission = try await service.submitWork(
            SubmitWorkRequest(workID: outstanding.workID, nonce: 0)
        )
        XCTAssertTrue(outstandingSubmission.accepted)

        let status = await service.status()
        // This synthetic projection says a spent transaction was removed
        // without changing the real canonical state. Authoritative Lattice
        // preflight therefore rejects it instead of resurrecting it.
        XCTAssertEqual(status.mempoolCount, 0)
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
            fee: 0,
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
                halvingInterval: 100
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
                parentCarrier: fixture.parentCarrier,
                parentContentSource: FetcherContentSource(fixture.parent)
            )
            return (candidate, await fixture.service.status())
        }

        let sizing = try await activeChildService(spec: spec(maxBlockSize: 1_000_000))
        _ = try await sizing.service.submitTransaction(
            SubmitTransactionRequest(transaction: transaction)
        )
        let sizedCandidate = try await sizing.service.miningCandidate(
            parentCarrier: sizing.parentCarrier,
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
                fee: 0,
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
                halvingInterval: 100
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
                parentCarrier: fixture.parentCarrier,
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
            parentCarrier: sizing.parentCarrier,
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
            parentCarrier: fullSizing.parentCarrier,
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
                halvingInterval: 100
            )
        }

        func childService(
            _ fixture: ActiveChildServiceFixture,
            directories: [String]
        ) -> ChainService {
            makeService(
                process: fixture.process,
                childCandidateProvider: { context in
                    guard !directories.isEmpty else { return [] }
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
            )
        }

        func candidate(
            maxBlockSize: Int,
            childDirectories: [String],
            transaction: Transaction? = nil
        ) async throws -> (DirectChildCandidate, ChainProcess) {
            let fixture = try await activeChildService(spec: spec(maxBlockSize))
            let service = childService(fixture, directories: childDirectories)
            if let transaction {
                _ = try await service.submitTransaction(
                    SubmitTransactionRequest(transaction: transaction)
                )
            }
            return (
                try await service.miningCandidate(
                    parentCarrier: fixture.parentCarrier,
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
        let stableService = childService(
            stableFixture,
            directories: ["A", "B"]
        )
        func scheduledDirectory() async throws -> String {
            let candidate = try await stableService.miningCandidate(
                parentCarrier: stableFixture.parentCarrier,
                parentContentSource: FetcherContentSource(stableFixture.parent)
            )
            return try XCTUnwrap(
                candidate.block.children.node?.allKeysAndValues().keys.first
            )
        }
        let firstDirectory = try await scheduledDirectory()
        let secondDirectory = try await scheduledDirectory()
        XCTAssertEqual(firstDirectory, secondDirectory)
    }

    func testParentTargetMissKeepsDurableProofWhenPublicationFails() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-target-miss-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: directory,
            privateKeyHex: String(repeating: "01", count: 32)
        )
        let process = try await ChainProcess.open(configuration: configuration)
        let genesis = try await process.canonicalTipBlock()
        let activeChild = try await anchoredChildGenesis(
            parent: process,
            parentGenesis: genesis,
            childTimestamp: 1,
            carrierNonce: 0
        )
        let anchoredParent = try await process.canonicalTipBlock()
        // The anchored carrier's next target is the unclamped proportional
        // retarget for its solve interval (Nexus commits no maxTargetChange).
        XCTAssertEqual(
            anchoredParent.nextTarget,
            NexusGenesis.spec.calculateWindowedTarget(
                previousTarget: anchoredParent.target,
                ancestorTimestamps: [anchoredParent.timestamp, genesis.timestamp]
            )
        )
        let store = try testNodeStore(
            databasePath: directory.appendingPathComponent("state.db"),
            nexusGenesisCID: configuration.nexusGenesisCID,
            chainPath: configuration.chainPath,
            issuingAuthorityKey: configuration.processPublicKey
        )
        let admissionsBefore = try await store.stagedAdmissions()
        let leavesBefore = try await process.acceptedLeafPage(
            afterCID: nil,
            snapshotSequence: nil,
            limit: 16
        )

        let publishedProofs = PublishedProofs()
        let publishedBlocks = PublishedBlocks()
        let service = makeService(
            process: process,
            childCandidateProvider: { context in
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
            },
            childProofPublisher: {
                await publishedProofs.record($0)
                throw TestPublicationError.failed
            },
            acceptedBlockPublisher: { blockCID in
                await publishedBlocks.record(blockCID)
            }
        )
        let template = try await service.miningTemplate(MiningTemplateRequest())
        var nonce: UInt64 = 0
        while template.block.replacingNonce(nonce).proofOfWorkHash()
                <= template.block.target {
            nonce += 1
        }

        let submitted = try await service.submitWork(SubmitWorkRequest(
            workID: template.workID,
            nonce: nonce
        ))
        XCTAssertFalse(submitted.accepted)
        XCTAssertEqual(submitted.disposition, .carrier)
        XCTAssertNotNil(submitted.parentCarrierLink)
        XCTAssertTrue(submitted.durableChildProofs.isEmpty)
        for _ in 0..<500 {
            if await publishedProofs.count() > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let publicationCount = await publishedProofs.count()
        XCTAssertEqual(publicationCount, 1)
        let publishedBlockCount = await publishedBlocks.count()
        XCTAssertEqual(publishedBlockCount, 0)
        let admissionsAfter = try await store.stagedAdmissions()
        let leavesAfter = try await process.acceptedLeafPage(
            afterCID: nil,
            snapshotSequence: nil,
            limit: 16
        )
        XCTAssertEqual(admissionsAfter, admissionsBefore)
        XCTAssertEqual(leavesAfter, leavesBefore)
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
                halvingInterval: 100
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
        let publication = PublishedProofs()
        let provisionalParents = ProvisionalParents()
        let service = makeService(
            process: process,
            childCandidateProvider: { context in
                await provisionalParents.record(context.parentCarrier)
                return [DirectChildCandidate(
                    directory: "Existing",
                    block: child
                )]
            },
            childProofPublisher: { await publication.record($0) }
        )

        let template = try await service.miningTemplate(MiningTemplateRequest())
        let recordedProvisional = await provisionalParents.first()
        let provisional = try XCTUnwrap(recordedProvisional)
        XCTAssertEqual(
            provisional.transactions.rawCID,
            template.block.transactions.rawCID
        )
        XCTAssertEqual(provisional.timestamp, template.block.timestamp)
        XCTAssertEqual(provisional.target, template.block.target)
        XCTAssertEqual(provisional.nextTarget, template.block.nextTarget)
        XCTAssertEqual(provisional.prevState.rawCID, template.block.prevState.rawCID)
        XCTAssertEqual(
            try template.block.children.node?.allKeysAndValues()["Existing"]?
                .rawCID,
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
        for _ in 0..<500 {
            if await publication.count() > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let publicationCount = await publication.count()
        XCTAssertEqual(publicationCount, 1)
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
                halvingInterval: 100
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
            process: consumer,
            childCandidateProvider: { _ in
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
        )

        let template = try await service.miningTemplate(MiningTemplateRequest())
        XCTAssertEqual(
            Set(try XCTUnwrap(template.block.children.node).allKeysAndValues().keys),
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
                halvingInterval: 100
            ),
            parentState: parent.postState,
            transactions: [],
            timestamp: 1,
            target: UInt256.max,
            fetcher: process
        )
        let service = ChainService(
            process: process,
            childCandidateProvider: { _ in
                ["A", "B"].map {
                    DirectChildCandidate(
                        directory: $0,
                        block: child
                    )
                }
            },
            childProofPublisher: { _ in },
            acceptedBlockPublisher: { _ in },
            maximumChildCandidates: 1
        )

        let template = try await service.miningTemplate(
            MiningTemplateRequest()
        )
        let children = try XCTUnwrap(template.block.children.node)
        XCTAssertEqual(Set(try children.allKeysAndValues().keys), ["A"])
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
            halvingInterval: 100
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
        let parentOutcome = try await parentProcess.admit(firstCarrierHeader)
        XCTAssertNotNil(parentOutcome.parentCarrierLink)

        let childDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-child-service-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: childDirectory) }
        let childProcess = try await ChainProcess.open(configuration: NodeConfiguration(
            chainPath: ["Nexus", "Payments"],
            storagePath: childDirectory,
            privateKeyHex: String(repeating: "02", count: 32),
            parentEndpoint: ParentEndpoint(
                publicKey: parentProcess.configuration.processPublicKey,
                host: "127.0.0.1",
                port: 4002
            )
        ))
        let activated = try await childProcess.activateSeededChildGenesis(
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
            )],
            fee: 1
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
            parentCarrier: nextParentCarrier,
            parentContentSource: FetcherContentSource(parentProcess),
            rewards: []
        )
        let selectedTransactions = try await livenessCandidate.block.transactions
            .resolve(fetcher: childProcess)
        XCTAssertEqual(selectedTransactions.node?.count, 1)
        XCTAssertEqual(
            try selectedTransactions.node?.allKeysAndValues()["0"]?.rawCID,
            try VolumeImpl<Transaction>(node: ordinary).rawCID
        )

        let childMiner = CryptoUtils.generateKeyPair()
        let childReward = try signedTransaction(
            key: childMiner,
            chainPath: ["Nexus", "Payments"],
            accountActions: [AccountAction(
                owner: CryptoUtils.createAddress(from: childMiner.publicKey),
                delta: 1
            )]
        )
        let candidate: DirectChildCandidate
        do {
            candidate = try await childService.miningCandidate(
                parentCarrier: nextParentCarrier,
                parentContentSource: FetcherContentSource(parentProcess),
                rewards: [MiningReward(
                    chainPath: ["Nexus", "Payments"],
                    transaction: childReward
                )]
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
        XCTAssertEqual(
            try candidate.block.transactions.node?.allKeysAndValues()
                .values.first?.rawCID,
            try VolumeImpl<Transaction>(node: childReward).rawCID
        )
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
            parentCarrier: firstCarrier,
            parentContentSource: FetcherContentSource(fixture.parent)
        )
        try await Task.sleep(for: .milliseconds(20))
        let second = try await fixture.service.miningCandidate(
            parentCarrier: secondCarrier,
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

    func testAbandonedParentCarriersDoNotExhaustChildCandidates() async throws {
        let fixture = try await activeChildService(spec: NexusGenesis.spec)
        var candidateCIDs: Set<String> = []

        for offset in 1...20 {
            let carrier = try await BlockBuilder.buildBlock(
                previous: fixture.parentCarrier,
                timestamp: fixture.parentCarrier.timestamp + Int64(offset),
                nonce: UInt64(offset),
                fetcher: fixture.parent
            )
            let candidate = try await fixture.service.miningCandidate(
                parentCarrier: carrier,
                parentContentSource: FetcherContentSource(fixture.parent)
            )
            candidateCIDs.insert(try BlockHeader(node: candidate.block).rawCID)
        }

        XCTAssertEqual(candidateCIDs.count, 20)
    }

    func testTemplateIsNotExposedAndLostReservationAckRollsBack() async throws {
        let process = try await nexusProcess()
        let peer = try PeerKey(
            rawRepresentation: Data(repeating: 7, count: PeerKey.byteCount)
        )
        let recorder = ReservationRecorder(accept: false)
        let service = makeService(
            process: process,
            childCandidateProvider: { context in
                let genesis = try await BlockBuilder.buildChildGenesis(
                    spec: NexusGenesis.spec,
                    parentState: context.parentCarrier.prevState,
                    timestamp: context.parentCarrier.timestamp - 1,
                    target: .max,
                    fetcher: process
                )
                let child = try await BlockBuilder.buildBlock(
                    previous: genesis,
                    parentChainBlock: context.parentCarrier,
                    timestamp: context.parentCarrier.timestamp,
                    target: .max,
                    fetcher: process
                )
                return [DirectChildCandidate(
                    directory: "Child",
                    block: child,
                    advertiserPeerKey: peer
                )]
            },
            childCandidateReservationReconciler: { update in
                await recorder.reconcile(update)
            }
        )

        await XCTAssertThrowsErrorAsync(
            try await service.miningTemplate(MiningTemplateRequest())
        ) { error in
            XCTAssertEqual(
                error as? ChainServiceError,
                .childCandidateReservationFailed
            )
        }
        let snapshots = await recorder.snapshots()
        XCTAssertEqual(snapshots.count, 4)
        XCTAssertEqual(snapshots.first?.count, 1)
        XCTAssertEqual(snapshots[1], [])
        XCTAssertEqual(snapshots[2].count, 1)
        XCTAssertEqual(snapshots[3], [])
        let childStateAfterLostAck = await recorder.current()
        XCTAssertTrue(childStateAfterLostAck.isEmpty)
    }

    func testTemplateRebuildOmitsReservationFailureButKeepsHealthySibling()
        async throws
    {
        let process = try await nexusProcess()
        let failedPeer = try PeerKey(
            rawRepresentation: Data(repeating: 0x61, count: PeerKey.byteCount)
        )
        let healthyPeer = try PeerKey(
            rawRepresentation: Data(repeating: 0x62, count: PeerKey.byteCount)
        )
        let attempts = AttemptCounter()
        let service = makeService(
            process: process,
            childCandidateProvider: { context in
                let attempt = await attempts.next()
                let directories = attempt == 1
                    ? [("Failed", failedPeer), ("Healthy", healthyPeer)]
                    : [("Healthy", healthyPeer)]
                var candidates: [DirectChildCandidate] = []
                for (directory, peer) in directories {
                    let genesis = try await BlockBuilder.buildChildGenesis(
                        spec: NexusGenesis.spec,
                        parentState: context.parentCarrier.prevState,
                        timestamp: context.parentCarrier.timestamp - 1,
                        target: .max,
                        fetcher: process
                    )
                    let child = try await BlockBuilder.buildBlock(
                        previous: genesis,
                        parentChainBlock: context.parentCarrier,
                        timestamp: context.parentCarrier.timestamp,
                        target: .max,
                        fetcher: process
                    )
                    candidates.append(DirectChildCandidate(
                        directory: directory,
                        block: child,
                        advertiserPeerKey: peer
                    ))
                }
                return candidates
            },
            childCandidateReservationReconciler: { update in
                !update.reservations.contains { $0.peerKey == failedPeer }
            }
        )

        let template = try await service.miningTemplate(
            MiningTemplateRequest()
        )
        let children = try XCTUnwrap(template.block.children.node)
        XCTAssertEqual(Set(try children.allKeysAndValues().keys), ["Healthy"])
        let attemptCount = await attempts.count()
        XCTAssertEqual(attemptCount, 2)
    }

    func testReservationSnapshotRecursesThroughThreeChainLevels()
        async throws
    {
        let middleProcess = try await nexusProcess()
        let leafProcess = try await nexusProcess()
        let leafPeer = try PeerKey(
            rawRepresentation: Data(repeating: 0x71, count: PeerKey.byteCount)
        )

        let leafPrevious = try await leafProcess.canonicalTipBlock()
        let leafBlock = try await BlockBuilder.buildBlock(
            previous: leafPrevious,
            timestamp: leafPrevious.timestamp + 1,
            target: .max,
            nonce: 1,
            fetcher: leafProcess
        )
        let leafHeader = try BlockHeader(node: leafBlock)
        try await leafProcess.storeContextualCandidate(
            leafHeader,
            fetcher: leafProcess,
            capacity: 16
        )

        let middlePrevious = try await middleProcess.canonicalTipBlock()
        let middleBlock = try await BlockBuilder.buildBlock(
            previous: middlePrevious,
            timestamp: middlePrevious.timestamp + 1,
            target: .max,
            nonce: 2,
            fetcher: middleProcess
        )
        let middleHeader = try BlockHeader(node: middleBlock)
        try await middleProcess.storeContextualCandidate(
            middleHeader,
            fetcher: middleProcess,
            children: [ChildCandidateReservationReference(
                peerKey: leafPeer,
                candidateCID: leafHeader.rawCID
            )],
            capacity: 16
        )

        let leafService = makeService(process: leafProcess)
        let middleService = makeService(
            process: middleProcess,
            childCandidateReservationReconciler: { update in
                guard update.reservations.allSatisfy({
                    $0.peerKey == leafPeer
                }) else {
                    return false
                }
                return await leafService.replaceIssuedCandidateReservations(
                    NetworkCandidateReservationUpdate(
                        candidateCIDs:
                            update.reservations.map(\.candidateCID),
                        handoffCIDs: update.handoffs.map(\.candidateCID)
                    )
                )
            }
        )
        let reserved = await middleService.replaceIssuedCandidateReservations(
            NetworkCandidateReservationUpdate(
                candidateCIDs: [middleHeader.rawCID],
                handoffCIDs: []
            )
        )
        XCTAssertTrue(reserved)

        let middleStore = try testNodeStore(
            databasePath: middleProcess.configuration.storagePath
                .appendingPathComponent("state.db"),
            nexusGenesisCID: middleProcess.configuration.nexusGenesisCID,
            chainPath: middleProcess.configuration.chainPath,
            issuingAuthorityKey: middleProcess.configuration.processPublicKey
        )
        let leafStore = try testNodeStore(
            databasePath: leafProcess.configuration.storagePath
                .appendingPathComponent("state.db"),
            nexusGenesisCID: leafProcess.configuration.nexusGenesisCID,
            chainPath: leafProcess.configuration.chainPath,
            issuingAuthorityKey: leafProcess.configuration.processPublicKey
        )
        let middleIssued = try await middleStore
            .issuedContextualCandidateCIDs()
        let leafIssued = try await leafStore.issuedContextualCandidateCIDs()
        XCTAssertEqual(middleIssued, [middleHeader.rawCID])
        XCTAssertEqual(leafIssued, [leafHeader.rawCID])

        let released = await middleService.replaceIssuedCandidateReservations(
            NetworkCandidateReservationUpdate(
                candidateCIDs: [],
                handoffCIDs: []
            )
        )
        XCTAssertTrue(released)
        for _ in 0..<100 {
            if try await middleStore.issuedContextualCandidateCIDs().isEmpty,
               try await leafStore.issuedContextualCandidateCIDs().isEmpty {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let middleReleased = try await middleStore
            .issuedContextualCandidateCIDs()
        let leafReleased = try await leafStore.issuedContextualCandidateCIDs()
        XCTAssertTrue(middleReleased.isEmpty)
        XCTAssertTrue(leafReleased.isEmpty)
    }

    func testCommittedHandoffIsExcludedFromEveryOutstandingReservation()
        async throws
    {
        let process = try await nexusProcess()
        let block = try await process.canonicalTipBlock()
        let peer = try PeerKey(
            rawRepresentation: Data(
                repeating: 0x72,
                count: PeerKey.byteCount
            )
        )
        let candidate = DirectChildCandidate(
            directory: "Child",
            block: block,
            advertiserPeerKey: peer
        )
        let handoff = ChildCandidateReservationReference(
            peerKey: peer,
            candidateCID: try BlockHeader(node: block).rawCID
        )

        let ownership = try ChildCandidateOwnership(
            candidates: [candidate, candidate],
            handoffs: [handoff]
        )

        XCTAssertTrue(ownership.reservations.isEmpty)
        XCTAssertEqual(ownership.handoffs, [handoff])
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
                SubmitWorkRequest(workID: template.workID, nonce: 0)
            )
            XCTAssertTrue(submitted.accepted)
            mainCIDs.append(try XCTUnwrap(submitted.tipCID))
        }
        // Fork at height 3: two competing height-4 blocks; one is canonical, the
        // other is the off-chain sibling a marooned receiver would sit on.
        let templateA = try await service.miningTemplate(MiningTemplateRequest())
        let templateB = try await service.miningTemplate(MiningTemplateRequest())
        let cidA = try BlockHeader(node: templateA.block).rawCID
        let cidB = try BlockHeader(node: templateB.block).rawCID
        let submittedA = try await service.submitWork(
            SubmitWorkRequest(workID: templateA.workID, nonce: 0)
        )
        XCTAssertTrue(submittedA.accepted)
        let submittedB = try await service.submitWork(
            SubmitWorkRequest(workID: templateB.workID, nonce: 0)
        )
        XCTAssertTrue(submittedB.accepted)
        let canonical4Opt = await process.mainChainBlockCID(atHeight: 4)
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
        let genesis = "bafyreiayw4z5qz4lt2sljf2enzn7uol3qa6bebadav7qwnqz7agxkiuwhq"
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

    /// Mine `depth` blocks on `producer` (Nexus genesis target is max, so PoW is
    /// trivial) and return them in ascending-height order.
    private func mineNexusChain(
        on producer: ChainProcess,
        depth: Int
    ) async throws -> [Block] {
        let producerService = makeService(process: producer)
        var blocks: [Block] = []
        for _ in 0..<depth {
            let template = try await producerService
                .miningTemplate(MiningTemplateRequest())
            let outcome = try await producer.admit(
                BlockHeader(node: template.block)
            )
            XCTAssertTrue(
                outcome.decision.isAccepted,
                "producer block must be accepted"
            )
            blocks.append(template.block)
        }
        return blocks
    }

    /// Deferred execution turning ON: a node that weighed-syncs a chain below its
    /// tip is NON-operable (weighed tip, validated tier at genesis) until the
    /// validate-on-candidacy walk executes the branch FORWARD and makes it
    /// operable. Folds in the forward-order assertion (strictly increasing from
    /// lastValidated+1, never tip-first).
    func testWeighedColdSyncBecomesOperableViaForwardValidateWalk() async throws {
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
            let outcome = try await consumerProcess.admit(
                BlockHeader(node: block),
                remoteSource: FetcherContentSource(producer),
                mode: .weighed
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
            .deepestValidatedMainChainTip()
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
        await consumer.setValidateWalkObserver { recorder.record($0) }
        await consumer.runValidateWalkPass()
        await consumer.setValidateWalkObserver(nil)

        XCTAssertEqual(
            recorder.heights, (1...UInt64(depth)).map { $0 },
            "validate heights must be strictly increasing from genesis+1, "
                + "never tip-first"
        )

        // OPERABILITY: the validated tier now meets the canonical tier.
        let operableValidated = await consumerProcess
            .deepestValidatedMainChainTip()
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

    /// `deepestValidatedMainChainTip` is read on every walk iteration and every
    /// gated `status()`. Validated main-chain blocks form a prefix, so each
    /// read after the first must cost O(delta) store reads (the blocks
    /// validated since), never O(gap) — draining a backlog was O(gap²).
    func testValidatedTipProbeReadsScaleWithTheDeltaNotTheGap() async throws {
        let depth = 12
        let producer = try await nexusProcess()
        let chain = try await mineNexusChain(on: producer, depth: depth)
        let consumerProcess = try await nexusProcess()
        for block in chain {
            let outcome = try await consumerProcess.admit(
                BlockHeader(node: block),
                remoteSource: FetcherContentSource(producer),
                mode: .weighed
            )
            XCTAssertTrue(outcome.decision.isAccepted)
        }
        // Prime once (the full downward walk), then count only the reads the
        // per-block probes make while the tier advances one block at a time.
        _ = await consumerProcess.deepestValidatedMainChainTip()
        await consumerProcess.resetValidatedTipStoreReadsForTesting()
        for (index, block) in chain.enumerated() {
            let outcome = try await consumerProcess.admit(
                BlockHeader(node: block),
                remoteSource: FetcherContentSource(producer),
                mode: .validate
            )
            XCTAssertTrue(outcome.decision.isAccepted)
            let validated = await consumerProcess.deepestValidatedMainChainTip()
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
        for mode in [AdmissionMode.weighed, .validate] {
            for block in chain {
                let outcome = try await consumerProcess.admit(
                    BlockHeader(node: block),
                    remoteSource: FetcherContentSource(producer),
                    mode: mode
                )
                XCTAssertTrue(outcome.decision.isAccepted)
            }
        }
        let cached = await consumerProcess.deepestValidatedMainChainTip()
        XCTAssertEqual(cached?.height, UInt64(depth))
        // Demote the cached tip behind the probe's back (the race).
        let tipCID = try BlockHeader(node: try XCTUnwrap(chain.last)).rawCID
        try await consumerProcess.demoteValidatedForTesting(tipCID)
        let probed = await consumerProcess.deepestValidatedMainChainTip()
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
        for mode in [AdmissionMode.weighed, .validate] {
            for block in forkA {
                let outcome = try await consumerProcess.admit(
                    BlockHeader(node: block),
                    remoteSource: FetcherContentSource(producerA),
                    mode: mode
                )
                XCTAssertTrue(outcome.decision.isAccepted)
            }
        }
        for block in forkB {
            let outcome = try await consumerProcess.admit(
                BlockHeader(node: block),
                remoteSource: FetcherContentSource(producerB),
                mode: .weighed
            )
            XCTAssertTrue(outcome.decision.isAccepted)
        }
        let consumer = makeService(
            process: consumerProcess,
            validateBodySource: { cid, admit in
                try await admit(FetcherContentSource(producerB))
            }
        )
        await consumer.runValidateWalkPass()
        let onB = await consumerProcess.deepestValidatedMainChainTip()
        XCTAssertEqual(onB?.height, 8, "B validated to its tip")
        // Eviction: A's validated blocks are off-chain and deeper than the
        // retention depth below the validated head — all but one demoted.
        _ = try await consumerProcess.evictUnretainedVolumes()

        // A third fork C from genesis, heavier than B and weighed only: the
        // probe falls back (B's floor left the main chain) and parks the
        // cached floor at genesis — BELOW A's demoted holes.
        let producerC = try await nexusProcess()
        let forkC = try await mineNexusRewardChain(
            on: producerC, depth: 12, miner: CryptoUtils.generateKeyPair()
        )
        for block in forkC {
            let outcome = try await consumerProcess.admit(
                BlockHeader(node: block),
                remoteSource: FetcherContentSource(producerC),
                mode: .weighed
            )
            XCTAssertTrue(outcome.decision.isAccepted)
        }
        let onC = await consumerProcess.deepestValidatedMainChainTip()
        XCTAssertEqual(onC?.height, 0, "nothing on C above genesis is validated")

        // Reorg back to A: extend it past C. The main chain is A with
        // demoted holes (A1-A3) below the A block that survived eviction.
        let moreA = try await mineNexusChain(on: producerA, depth: 10)
        for block in moreA {
            let outcome = try await consumerProcess.admit(
                BlockHeader(node: block),
                remoteSource: FetcherContentSource(producerA),
                mode: .weighed
            )
            XCTAssertTrue(outcome.decision.isAccepted)
        }
        let canonical = await consumerProcess.canonicalTipHeight()
        XCTAssertEqual(canonical, 14, "A must win again")
        let probed = await consumerProcess.deepestValidatedMainChainTip()
        // The full downward walk from the tip, computed independently.
        var expected: (cid: String, height: UInt64)?
        var height: UInt64 = 14
        while true {
            if let cid = await consumerProcess.mainChainBlockCID(atHeight: height),
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
        let again = await consumerProcess.deepestValidatedMainChainTip()
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
            _ blocks: [Block], from source: ChainProcess, mode: AdmissionMode
        ) async throws {
            for block in blocks {
                let outcome = try await consumerProcess.admit(
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
                let outcome = try await process.admit(
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
                if let cid = await consumerProcess.mainChainBlockCID(atHeight: height),
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
        try await admitAll(trunk, from: producerT, mode: .weighed)
        try await admitAll(trunk, from: producerT, mode: .validate)
        // Fork A from T4 (A5-A8), validated while main.
        let producerA = try await producer(holding: trunk, from: producerT)
        let forkA = try await mineNexusRewardChain(
            on: producerA, depth: 4, miner: CryptoUtils.generateKeyPair()
        )
        try await admitAll(forkA, from: producerA, mode: .weighed)
        try await admitAll(forkA, from: producerA, mode: .validate)
        // Trunk continues T5-T12 (heavier): A is off-chain.
        let trunkMore = try await mineNexusChain(on: producerT, depth: 8)
        try await admitAll(trunkMore, from: producerT, mode: .weighed)
        // Fork D from T8 (D9-D14) will need bodies from producerD on the walk.
        let producerD = try await producer(
            holding: trunk + Array(trunkMore.prefix(4)), from: producerT
        )
        let consumer = makeService(
            process: consumerProcess,
            validateBodySource: { _, admit in
                try await admit(FetcherContentSource(producerD))
            }
        )
        await consumer.runValidateWalkPass()
        let onTrunk = await consumerProcess.deepestValidatedMainChainTip()
        XCTAssertEqual(onTrunk?.height, 12)
        // Eviction 1: A5-A8 demoted (holes 5-8 on fork A).
        _ = try await consumerProcess.evictUnretainedVolumes()

        let forkD = try await mineNexusRewardChain(
            on: producerD, depth: 6, miner: CryptoUtils.generateKeyPair()
        )
        try await admitAll(forkD, from: producerD, mode: .weighed)
        await consumer.runValidateWalkPass()
        let onD = await consumerProcess.deepestValidatedMainChainTip()
        XCTAssertEqual(onD?.height, 14, "D9-D14 validated while main")
        // Trunk T13-T16: D is off-chain; eviction 2 demotes D9-D10 (below
        // the retention ceiling 12 - 1), leaving D11-D14 validated ABOVE.
        let trunkEven = try await mineNexusChain(on: producerT, depth: 4)
        try await admitAll(trunkEven, from: producerT, mode: .weighed)
        let backOnTrunk = await consumerProcess.deepestValidatedMainChainTip()
        XCTAssertEqual(backOnTrunk?.height, 12)
        _ = try await consumerProcess.evictUnretainedVolumes()
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
        try await admitAll(forkE, from: producerE, mode: .weighed)
        let onE = await consumerProcess.deepestValidatedMainChainTip()
        XCTAssertEqual(onE?.height, 6, "floor parked at T6")

        // D returns, heavier than E: T1-T8 validated, D9-D10 holes, D11-D14
        // validated, D15-D22 weighed.
        let forkDMore = try await mineNexusRewardChain(
            on: producerD, depth: 8, miner: CryptoUtils.generateKeyPair()
        )
        try await admitAll(forkDMore, from: producerD, mode: .weighed)
        let canonical = await consumerProcess.canonicalTipHeight()
        XCTAssertEqual(canonical, 22)
        let probed = await consumerProcess.deepestValidatedMainChainTip()
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
        for mode in [AdmissionMode.weighed, .validate] {
            for block in forkA {
                let outcome = try await consumerProcess!.admit(
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
            let outcome = try await consumerProcess!.admit(
                BlockHeader(node: block),
                remoteSource: FetcherContentSource(producerF),
                mode: .weighed
            )
            XCTAssertTrue(outcome.decision.isAccepted)
        }
        let onF = await consumerProcess!.deepestValidatedMainChainTip()
        XCTAssertEqual(onF?.height, 0)

        // A returns: A1 validated, A2 a hole, A3-A6 validated above it.
        let forkAMore = try await mineNexusChain(on: producerA, depth: 4)
        for block in forkAMore {
            let outcome = try await consumerProcess!.admit(
                BlockHeader(node: block),
                remoteSource: FetcherContentSource(producerA),
                mode: .weighed
            )
            XCTAssertTrue(outcome.decision.isAccepted)
        }
        let canonical = await consumerProcess!.canonicalTipHeight()
        XCTAssertEqual(canonical, 10, "A must win again")
        let probed = await consumerProcess!.deepestValidatedMainChainTip()
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
        for mode in [AdmissionMode.weighed, .validate] {
            for block in chain {
                let outcome = try await consumerProcess.admit(
                    BlockHeader(node: block),
                    remoteSource: FetcherContentSource(producer),
                    mode: mode
                )
                XCTAssertTrue(outcome.decision.isAccepted)
            }
        }
        let cached = await consumerProcess.deepestValidatedMainChainTip()
        XCTAssertEqual(cached?.height, 4)

        // A heavier competing fork from genesis (reward blocks, so its CIDs
        // differ), weighed only: the main chain moves and nothing on it above
        // genesis is validated.
        let rival = try await nexusProcess()
        let fork = try await mineNexusRewardChain(
            on: rival, depth: 6, miner: CryptoUtils.generateKeyPair()
        )
        for block in fork {
            let outcome = try await consumerProcess.admit(
                BlockHeader(node: block),
                remoteSource: FetcherContentSource(rival),
                mode: .weighed
            )
            XCTAssertTrue(outcome.decision.isAccepted)
        }
        let canonical = await consumerProcess.canonicalTipHeight()
        XCTAssertEqual(canonical, 6, "the fork must win")
        let reorged = await consumerProcess.deepestValidatedMainChainTip()
        XCTAssertEqual(reorged?.height, 0)
        XCTAssertEqual(reorged?.cid, genesisCID)
    }

    /// A restart under deferred execution commonly leaves validated < canonical,
    /// and the walk is otherwise armed only by a canonical commit: with no
    /// network traffic nothing would ever run it and templates would build on
    /// the stale validated tip. Service start (`restoreLocalTransactions`, the
    /// daemon's pre-networking hook) must arm it itself.
    func testServiceStartDrivesTheValidateWalkWhenValidatedLagsCanonical()
        async throws
    {
        let depth = 4
        let producer = try await nexusProcess()
        let chain = try await mineNexusChain(on: producer, depth: depth)
        let consumerProcess = try await nexusProcess()
        for block in chain {
            let outcome = try await consumerProcess.admit(
                BlockHeader(node: block),
                remoteSource: FetcherContentSource(producer),
                mode: .weighed
            )
            XCTAssertTrue(outcome.decision.isAccepted)
        }
        let consumer = makeService(process: consumerProcess)
        let before = await consumerProcess.deepestValidatedMainChainTip()
        XCTAssertEqual(before?.height, 0, "restart state: validated lags")

        try await consumer.restoreLocalTransactions()

        var validated: UInt64?
        for _ in 0..<500 {
            validated = await consumerProcess.deepestValidatedMainChainTip()?.height
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
    func testValidateWalkParksAtGapAndResumesOnRelease() async throws {
        let depth = 6
        let gapAt = 3 // heights 1,2 available; 3 withheld; 4,5,6 blocked behind it
        let producer = try await nexusProcess()
        let chain = try await mineNexusChain(on: producer, depth: depth)

        let consumerProcess = try await nexusProcess()
        let consumer = makeService(process: consumerProcess)

        // Weighed-admit only the blocks below the gap (heights 1..gapAt-1).
        for block in chain.prefix(gapAt - 1) {
            let outcome = try await consumerProcess.admit(
                BlockHeader(node: block),
                remoteSource: FetcherContentSource(producer),
                mode: .weighed
            )
            XCTAssertTrue(outcome.decision.isAccepted)
        }

        // The walk validates up to the last contiguous weighed block and parks.
        await consumer.runValidateWalkPass()
        let parked = await consumerProcess.deepestValidatedMainChainTip()
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
            let outcome = try await consumerProcess.admit(
                BlockHeader(node: block),
                remoteSource: FetcherContentSource(producer),
                mode: .weighed
            )
            XCTAssertTrue(outcome.decision.isAccepted)
        }

        // The walk resumes and reaches the tip.
        await consumer.runValidateWalkPass()
        let resumed = await consumerProcess.deepestValidatedMainChainTip()
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
    func testValidateWalkFetchesBodyForCanonicalOnlyNotSiblings() async throws {
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
            validateBodySource: bodySource.admission()
        )

        // Weighed cold-sync the canonical chain FIRST (incumbent), then the losing
        // fork — every admit stores only the boundary (a boundary fetch), no body.
        var boundaryFetches = 0
        for block in canonical {
            let outcome = try await consumerProcess.admit(
                BlockHeader(node: block),
                remoteSource: FetcherContentSource(producer),
                mode: .weighed
            )
            XCTAssertTrue(outcome.decision.isAccepted, "canonical weighed admit")
            boundaryFetches += 1
        }
        for block in siblings {
            let outcome = try await consumerProcess.admit(
                BlockHeader(node: block),
                remoteSource: FetcherContentSource(siblingProducer),
                mode: .weighed
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
            .deepestValidatedMainChainTip()?.height
        XCTAssertEqual(preWalkValidated, 0)

        // Run the walk. It fetches ONLY canonical bodies, strictly forward.
        let recorder = ValidateStepRecorder()
        await consumer.setValidateWalkObserver { recorder.record($0) }
        await consumer.runValidateWalkPass()
        await consumer.setValidateWalkObserver(nil)

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
            .deepestValidatedMainChainTip()?.height
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
    func testValidateWalkParksOnWithheldBodyAndAutoResumesOnRelease()
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
            validateBodySource: bodySource.admission(),
            validateWalkRetryInterval: .milliseconds(20)
        )

        for block in canonical {
            let outcome = try await consumerProcess.admit(
                BlockHeader(node: block),
                remoteSource: FetcherContentSource(producer),
                mode: .weighed
            )
            XCTAssertTrue(outcome.decision.isAccepted)
        }

        // Walk parks one block below the withheld body; still operable there.
        await consumer.runValidateWalkPass()
        let parkedHeight = await consumerProcess
            .deepestValidatedMainChainTip()?.height
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
            .deepestValidatedMainChainTip()?.height
        while resumed != UInt64(depth), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
            resumed = await consumerProcess
                .deepestValidatedMainChainTip()?.height
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

        func admission() -> ValidateBodyAdmission {
            { [self] blockCID, admit in
                lock.withLock { _fetched.append(blockCID) }
                let withheld = lock.withLock { _withheld.contains(blockCID) }
                let source: any ContentSource = withheld
                    ? EmptyContentSource()
                    : FetcherContentSource(producer)
                return try await admit(source)
            }
        }
    }

    private struct EmptyContentSource: ContentSource {
        func fetch(_ cids: Set<String>) async -> [String: Data] { [:] }
    }

    /// Mine `depth` blocks on `producer`, each carrying a reward transaction (so
    /// each block has a real, boundary-excluded BODY the validate walk must
    /// fetch), returned in ascending-height order.
    private func mineNexusRewardChain(
        on producer: ChainProcess,
        depth: Int,
        miner: (privateKey: String, publicKey: String)
    ) async throws -> [Block] {
        let service = makeService(process: producer)
        var blocks: [Block] = []
        for index in 0..<depth {
            let reward = try signedTransaction(
                key: miner,
                chainPath: ["Nexus"],
                accountActions: [AccountAction(
                    owner: CryptoUtils.createAddress(from: miner.publicKey),
                    delta: 1
                )],
                nonce: UInt64(index)
            )
            let template = try await service.miningTemplate(
                MiningTemplateRequest(rewards: [MiningReward(
                    chainPath: ["Nexus"],
                    transaction: reward
                )])
            )
            let outcome = try await producer.admit(
                BlockHeader(node: template.block)
            )
            XCTAssertTrue(
                outcome.decision.isAccepted,
                "reward block \(index) must be accepted"
            )
            blocks.append(template.block)
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
        childCandidateProvider: @escaping ChildCandidateProvider = { _ in [] },
        childCandidateReservationReconciler:
            @escaping ChildCandidateReservationReconciler = {
                $0.reservations.isEmpty && $0.handoffs.isEmpty
            },
        childProofPublisher: @escaping ChildProofPublisher = { _ in },
        acceptedBlockPublisher: @escaping AcceptedBlockPublisher = { _ in },
        acceptedTransactionPublisher:
            @escaping AcceptedTransactionPublisher = { _ in },
        validateBodySource: ValidateBodyAdmission? = nil,
        validateWalkRetryInterval: Duration = .seconds(4),
        mempoolMaxCount: Int = 10_000
    ) -> ChainService {
        ChainService(
            process: process,
            childCandidateProvider: childCandidateProvider,
            childCandidateReservationReconciler:
                childCandidateReservationReconciler,
            childProofPublisher: childProofPublisher,
            acceptedBlockPublisher: acceptedBlockPublisher,
            acceptedTransactionPublisher: acceptedTransactionPublisher,
            validateBodySource: validateBodySource,
            validateWalkRetryInterval: validateWalkRetryInterval,
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

    private func activeChildService(
        spec: ChainSpec
    ) async throws -> ActiveChildServiceFixture {
        let parent = try await nexusProcess()
        let parentGenesis = try await parent.canonicalTipBlock()
        let child = try await anchoredChildGenesis(
            parent: parent,
            parentGenesis: parentGenesis,
            childTimestamp: 1,
            carrierNonce: 0,
            spec: spec
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-child-service-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let process = try await ChainProcess.open(configuration: NodeConfiguration(
            chainPath: ["Nexus", "Payments"],
            storagePath: directory,
            privateKeyHex: String(repeating: "02", count: 32),
            parentEndpoint: ParentEndpoint(
                publicKey: parent.configuration.processPublicKey,
                host: "127.0.0.1",
                port: 4002
            )
        ))
        let activated = try await process.activateSeededChildGenesis(
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
        spec: ChainSpec = NexusGenesis.spec
    ) async throws -> AnchoredChildGenesis {
        // A self-contained child genesis (empty parentState) recorded on the
        // parent by a plain GenesisAction — never carried on the carrier's
        // children. The child rebuilds this identical genesis from `seed` and
        // self-admits it (activateSeededChildGenesis).
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
        let carrier = try await BlockBuilder.buildBlock(
            previous: parentGenesis,
            transactions: [authorization],
            timestamp: parentGenesis.timestamp + 1,
            nonce: carrierNonce,
            fetcher: parent
        )
        let carrierHeader = try BlockHeader(node: carrier)
        let parentAdmission = try await parent.admit(carrierHeader)
        XCTAssertNotNil(parentAdmission.parentCarrierLink)
        return AnchoredChildGenesis(
            block: block,
            header: header,
            carrierCID: carrierHeader.rawCID,
            seed: seed
        )
    }

}

private actor ReservationRecorder {
    private let accept: Bool
    private var values: [[ChildCandidateReservationReference]] = []
    private var currentValue: Set<ChildCandidateReservationReference> = []

    init(accept: Bool) {
        self.accept = accept
    }

    func reconcile(
        _ update: ChildCandidateReservationUpdate
    ) -> Bool {
        let references = update.reservations
        values.append(references)
        currentValue = Set(references)
        return (references.isEmpty && update.handoffs.isEmpty) || accept
    }

    func snapshots() -> [[ChildCandidateReservationReference]] { values }
    func current() -> Set<ChildCandidateReservationReference> { currentValue }
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

private actor TaskStartLatch {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        signaled = true
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        guard !signaled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor BlockingContentSource: ContentSource {
    private struct Waiter {
        let entries: [String: Data]
        let continuation: CheckedContinuation<[String: Data], Never>
    }

    private let blockedCID: String
    private var entries: [String: Data] = [:]
    private var blocked = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var fetchWaiters: [Waiter] = []

    init(blockedCID: String) {
        self.blockedCID = blockedCID
    }

    func setEntries(_ entries: [String: Data]) {
        self.entries = entries
    }

    func fetch(_ cids: Set<String>) async -> [String: Data] {
        let found = entries.filter { cids.contains($0.key) }
        guard cids.contains(blockedCID) else { return found }

        blocked = true
        let pendingStarts = startWaiters
        startWaiters.removeAll()
        for waiter in pendingStarts { waiter.resume() }
        guard !released else { return found }
        return await withCheckedContinuation { continuation in
            fetchWaiters.append(Waiter(
                entries: found,
                continuation: continuation
            ))
        }
    }

    func waitForBlockedFetch() async {
        guard !blocked else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseBlockedFetch() {
        released = true
        let pending = fetchWaiters
        fetchWaiters.removeAll()
        for waiter in pending {
            waiter.continuation.resume(returning: waiter.entries)
        }
    }
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

private actor PublishedProofs {
    private var values: [DirectChildProofPublication] = []

    func record(_ publication: DirectChildProofPublication) {
        values.append(publication)
    }

    func first() -> DirectChildProofPublication? {
        values.first
    }

    func count() -> Int {
        values.count
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

private actor CountingContentSource: ContentSource {
    private let entries: [String: Data]
    private var requests = 0

    init(entries: [String: Data]) {
        self.entries = entries
    }

    func fetch(_ cids: Set<String>) -> [String: Data] {
        requests += 1
        return entries.filter { cids.contains($0.key) }
    }

    func requestCount() -> Int {
        requests
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

private func signedTransaction(
    key: (privateKey: String, publicKey: String),
    chainPath: [String],
    accountActions: [AccountAction] = [],
    actions: [Action] = [],
    genesisActions: [GenesisAction] = [],
    fee: UInt64 = 0,
    nonce: UInt64 = 0
) throws -> Transaction {
    let body = transactionBody(
        key: key,
        chainPath: chainPath,
        accountActions: accountActions,
        actions: actions,
        genesisActions: genesisActions,
        fee: fee,
        nonce: nonce
    )
    let header = try HeaderImpl(node: body)
    let signature = try XCTUnwrap(TransactionSigning.sign(
        bodyHeader: header,
        privateKeyHex: key.privateKey
    ))
    return Transaction(signatures: [key.publicKey: signature], body: header)
}

private func transactionBody(
    key: (privateKey: String, publicKey: String),
    chainPath: [String],
    accountActions: [AccountAction] = [],
    actions: [Action] = [],
    genesisActions: [GenesisAction] = [],
    fee: UInt64 = 0,
    nonce: UInt64 = 0
) -> TransactionBody {
    TransactionBody(
        accountActions: accountActions,
        actions: actions,
        depositActions: [],
        genesisActions: genesisActions,
        receiptActions: [],
        withdrawalActions: [],
        signers: [CryptoUtils.createAddress(from: key.publicKey)],
        fee: fee,
        nonce: nonce,
        chainPath: chainPath
    )
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

private extension Block {
    func replacingNonce(_ nonce: UInt64) -> Block {
        Block(
            version: version,
            parent: parent,
            transactions: transactions,
            target: target,
            nextTarget: nextTarget,
            spec: spec,
            parentState: parentState,
            prevState: prevState,
            postState: postState,
            children: children,
            height: height,
            timestamp: timestamp,
            nonce: nonce
        )
    }
}
