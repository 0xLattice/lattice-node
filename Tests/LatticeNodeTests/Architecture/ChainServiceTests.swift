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

        let intent = ChildDeployIntentRequest(
            directory: "Sandbox",
            spec: ChainSpec(
                maxNumberOfTransactionsPerBlock: 100,
                maxStateGrowth: 100_000,
                premine: 1,
                targetBlockTime: 1_000,
                initialReward: 10,
                halvingInterval: 100
            ),
            genesisTransactions: [transaction],
            target: UInt256.max,
            timestamp: 1
        )
        let decodedIntent = try decoder.decode(
            ChildDeployIntentRequest.self,
            from: encoder.encode(intent)
        )
        XCTAssertNotNil(decodedIntent.genesisTransactions.first?.body.node)
        XCTAssertEqual(
            decodedIntent.genesisTransactions.first?.body.rawCID,
            transaction.body.rawCID
        )
    }

    func testChildIntentPolicyModuleRemainsContentBoundThroughJSON() throws {
        let module = try wasmPolicyModule(accepts: true)
        let request = ChildDeployIntentRequest(
            directory: "Sandbox",
            spec: childSpec(policyModule: module),
            genesisTransactions: [],
            policyModules: [module],
            target: .max,
            timestamp: 1
        )
        let encoded = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(
            ChildDeployIntentRequest.self,
            from: encoded
        )
        XCTAssertEqual(decoded.policyModules.first?.rootCID, module.rootCID)
        XCTAssertEqual(decoded.policyModules.first?.bytes, module.bytes)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var modules = try XCTUnwrap(
            object["policyModules"] as? [[String: Any]]
        )
        modules[0]["rootCID"] = NexusGenesis.expectedBlockHash
        object["policyModules"] = modules
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ChildDeployIntentRequest.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        )
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
        let intent = try await simpleChildIntent(
            service: service,
            directory: "Sandbox",
            timestamp: 1
        )
        _ = try await service.submitTransaction(SubmitTransactionRequest(
            transaction: try signedTransaction(
                key: CryptoUtils.generateKeyPair(),
                chainPath: ["Nexus"],
                genesisActions: [GenesisAction(
                    directory: intent.directory,
                    blockCID: intent.genesisCID
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
        _ = try await simpleChildIntent(
            service: service,
            directory: "Sandbox",
            timestamp: 1
        )

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
        XCTAssertEqual(status.pendingChildIntents, 0)
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

    func testChildIntentRequiresUnsignedGenesisAndParentAnchor() async throws {
        let process = try await nexusProcess()
        let publishedProofs = PublishedProofs()
        let service = makeService(
            process: process,
            childProofPublisher: { await publishedProofs.record($0) }
        )
        let childKey = CryptoUtils.generateKeyPair()
        let childOwner = CryptoUtils.createAddress(from: childKey.publicKey)
        let spec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 1,
            targetBlockTime: 1_000,
            initialReward: 10,
            halvingInterval: 100
        )
        let premineActions = [AccountAction(
            owner: childOwner,
            delta: Int64(spec.premineAmount())
        )]
        let signedPremine = try signedTransaction(
            key: childKey,
            chainPath: ["Nexus", "Sandbox"],
            accountActions: premineActions
        )
        let signedRequest = ChildDeployIntentRequest(
            directory: "Sandbox",
            spec: spec,
            genesisTransactions: [signedPremine],
            target: UInt256.max,
            timestamp: 1
        )
        await XCTAssertThrowsErrorAsync(
            try await service.createChildDeployIntent(signedRequest)
        ) { error in
            XCTAssertEqual(error as? ChainServiceError, .invalidChildGenesis)
        }

        let premine = Transaction(
            signatures: [:],
            body: try HeaderImpl(node: TransactionBody(
                accountActions: premineActions,
                actions: [],
                depositActions: [],
                genesisActions: [],
                receiptActions: [],
                withdrawalActions: [],
                signers: [],
                fee: 0,
                nonce: 0,
                chainPath: ["Nexus", "Sandbox"]
            ))
        )
        let intent = try await service.createChildDeployIntent(
            ChildDeployIntentRequest(
                directory: "Sandbox",
                spec: spec,
                genesisTransactions: [premine],
                target: UInt256.max,
                timestamp: 1
            )
        )
        XCTAssertEqual(intent.chainPath, ["Nexus", "Sandbox"])
        XCTAssertEqual(intent.genesisBlock.parentState.rawCID, intent.parentStateCID)

        let beforeAnchor = try await service.miningTemplate(
            MiningTemplateRequest()
        )
        XCTAssertEqual(beforeAnchor.block.children.node?.count, 0)

        let anchorKey = CryptoUtils.generateKeyPair()
        let anchor = try signedTransaction(
            key: anchorKey,
            chainPath: ["Nexus"],
            genesisActions: [GenesisAction(
                directory: intent.directory,
                blockCID: intent.genesisCID
            )]
        )
        _ = try await service.submitTransaction(
            SubmitTransactionRequest(transaction: anchor)
        )

        let normal = try await service.miningTemplate(MiningTemplateRequest())
        XCTAssertEqual(normal.block.children.node?.count, 0)
        let template = try await service.miningTemplate(
            MiningTemplateRequest(mode: .deployment)
        )
        let children = try XCTUnwrap(template.block.children.node)
        XCTAssertEqual(children.count, 1)
        XCTAssertEqual(
            try children.allKeysAndValues()["Sandbox"]?.rawCID,
            intent.genesisCID
        )

        let submitted = try await service.submitWork(SubmitWorkRequest(
            workID: template.workID,
            nonce: 0
        ))
        XCTAssertTrue(submitted.accepted)
        XCTAssertEqual(submitted.parentGenesisLinks.count, 1)
        XCTAssertEqual(submitted.parentGenesisLinks[0].parentPath, ["Nexus"])
        XCTAssertEqual(submitted.parentGenesisLinks[0].directory, "Sandbox")
        XCTAssertEqual(
            submitted.parentGenesisLinks[0].childGenesisCID,
            intent.genesisCID
        )
        let proofSummary = try XCTUnwrap(submitted.durableChildProofs.first)
        for _ in 0..<500 {
            if await publishedProofs.first() != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let recordedPublication = await publishedProofs.first()
        let publication = try XCTUnwrap(recordedPublication)
        XCTAssertEqual(proofSummary.directory, "Sandbox")
        XCTAssertEqual(proofSummary.childCID, intent.genesisCID)
        XCTAssertEqual(publication.directory, "Sandbox")
        XCTAssertEqual(publication.childCID, intent.genesisCID)
        let proof = publication.proof
        XCTAssertEqual(proof.directoryPath, ["Sandbox"])
        let responseJSON = try JSONEncoder().encode(submitted)
        XCTAssertFalse(String(decoding: responseJSON, as: UTF8.self).contains(
            "serializedProof"
        ))
        let status = await service.status()
        XCTAssertEqual(status.pendingChildIntents, 0)
    }

    func testChildIntentRejectsMissingAndMismatchedPolicyModules() async throws {
        let service = makeService(process: try await nexusProcess())
        let required = try wasmPolicyModule(accepts: true)
        let other = try wasmPolicyModule(accepts: false)
        let spec = childSpec(policyModule: required)

        for modules in [[], [other]] {
            await XCTAssertThrowsErrorAsync(
                try await service.createChildDeployIntent(
                    ChildDeployIntentRequest(
                        directory: "Sandbox",
                        spec: spec,
                        genesisTransactions: [],
                        policyModules: modules,
                        target: .max,
                        timestamp: 1
                    )
                )
            ) { error in
                XCTAssertEqual(
                    error as? ChainServiceError,
                    .invalidChildPolicyModules
                )
            }
        }
    }

    func testChildIntentRetainsNovelPolicyModuleUntilReplacementAndStaleness()
        async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-child-intent-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let process = try await ChainProcess.open(configuration: NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: directory,
            privateKeyHex: String(repeating: "01", count: 32)
        ))
        let service = makeService(process: process)
        let eviction = try DiskBroker(
            path: directory.appendingPathComponent("volumes.db").path,
            evictUnpinnedGraceSeconds: 0
        )
        let original = try wasmPolicyModule(accepts: true)
        let replacement = try wasmPolicyModule(accepts: false)
        let absentOriginal = await process.volume(original.rootCID)
        XCTAssertNil(absentOriginal)

        let originalIntent = try await service.createChildDeployIntent(
            ChildDeployIntentRequest(
                directory: "Sandbox",
                spec: childSpec(policyModule: original),
                genesisTransactions: [],
                policyModules: [original],
                target: .max,
                timestamp: 1
            )
        )
        _ = try await eviction.evictUnpinned()
        let retainedOriginal = await eviction.fetchVolumeLocal(
            root: original.rootCID
        )
        let retainedOriginalGenesis = await eviction.fetchVolumeLocal(
            root: originalIntent.genesisCID
        )
        XCTAssertNotNil(retainedOriginal)
        XCTAssertNotNil(retainedOriginalGenesis)

        let replacementIntent = try await service.createChildDeployIntent(
            ChildDeployIntentRequest(
                directory: "Sandbox",
                spec: childSpec(policyModule: replacement),
                genesisTransactions: [],
                policyModules: [replacement],
                target: .max,
                timestamp: 2
            )
        )
        _ = try await eviction.evictUnpinned()
        let releasedOriginal = await eviction.fetchVolumeLocal(
            root: original.rootCID
        )
        let retainedReplacement = await eviction.fetchVolumeLocal(
            root: replacement.rootCID
        )
        let releasedOriginalGenesis = await eviction.fetchVolumeLocal(
            root: originalIntent.genesisCID
        )
        let retainedReplacementGenesis = await eviction.fetchVolumeLocal(
            root: replacementIntent.genesisCID
        )
        XCTAssertNil(releasedOriginal)
        XCTAssertNotNil(retainedReplacement)
        XCTAssertNil(releasedOriginalGenesis)
        XCTAssertNotNil(retainedReplacementGenesis)

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
        _ = try await service.submitWork(SubmitWorkRequest(
            workID: template.workID,
            nonce: 0
        ))
        let status = await service.status()
        XCTAssertEqual(status.pendingChildIntents, 0)
        _ = try await eviction.evictUnpinned()
        let releasedReplacement = await eviction.fetchVolumeLocal(
            root: replacement.rootCID
        )
        let releasedReplacementGenesis = await eviction.fetchVolumeLocal(
            root: replacementIntent.genesisCID
        )
        XCTAssertNil(releasedReplacement)
        XCTAssertNil(releasedReplacementGenesis)
    }

    func testReplacingIntentDoesNotDeleteUserOwnedAnchor() async throws {
        let service = makeService(process: try await nexusProcess())
        let original = try await simpleChildIntent(
            service: service,
            directory: "Sandbox",
            timestamp: 1
        )
        let key = CryptoUtils.generateKeyPair()
        _ = try await service.submitTransaction(SubmitTransactionRequest(
            transaction: try signedTransaction(
                key: key,
                chainPath: ["Nexus"],
                genesisActions: [GenesisAction(
                    directory: original.directory,
                    blockCID: original.genesisCID
                )]
            )
        ))

        let replacement = try await simpleChildIntent(
            service: service,
            directory: "Sandbox",
            timestamp: 2
        )
        XCTAssertNotEqual(replacement.genesisCID, original.genesisCID)
        let status = await service.status()
        XCTAssertEqual(status.mempoolCount, 1)
        XCTAssertEqual(status.pendingChildIntents, 1)

        let normal = try await service.miningTemplate(MiningTemplateRequest())
        await XCTAssertThrowsErrorAsync(
            try await service.miningTemplate(
                MiningTemplateRequest(mode: .deployment)
            )
        ) { error in
            XCTAssertEqual(error as? ChainServiceError, .noDeploymentAvailable)
        }
        XCTAssertEqual(normal.block.transactions.node?.count, 0)
        XCTAssertEqual(normal.block.children.node?.count, 0)
    }

    func testDeploymentAnchorMustMatchPreparedGenesisCID() async throws {
        let service = makeService(process: try await nexusProcess())
        let intent = try await simpleChildIntent(
            service: service,
            directory: "Sandbox",
            timestamp: 1
        )
        let signer = CryptoUtils.generateKeyPair()
        _ = try await service.submitTransaction(SubmitTransactionRequest(
            transaction: try signedTransaction(
                key: signer,
                chainPath: ["Nexus"],
                genesisActions: [GenesisAction(
                    directory: intent.directory,
                    blockCID: NexusGenesis.expectedBlockHash
                )]
            )
        ))

        await XCTAssertThrowsErrorAsync(
            try await service.miningTemplate(
                MiningTemplateRequest(mode: .deployment)
            )
        ) { error in
            XCTAssertEqual(error as? ChainServiceError, .noDeploymentAvailable)
        }
        let unmatchedStatus = await service.status()
        XCTAssertEqual(unmatchedStatus.pendingChildIntents, 1)

        _ = try await service.submitTransaction(SubmitTransactionRequest(
            transaction: try signedTransaction(
                key: CryptoUtils.generateKeyPair(),
                chainPath: ["Nexus"],
                genesisActions: [GenesisAction(
                    directory: intent.directory,
                    blockCID: intent.genesisCID
                )]
            )
        ))
        let matched = try await service.miningTemplate(
            MiningTemplateRequest(mode: .deployment)
        )
        XCTAssertEqual(matched.block.transactions.node?.count, 1)
        XCTAssertEqual(
            try matched.block.children.node?.allKeysAndValues()["Sandbox"]?
                .rawCID,
            intent.genesisCID
        )
    }

    func testRewardCannotSilentlyDisplacePendingDeploymentAtTransactionLimit()
        async throws
    {
        let fixture = try await activeChildService(spec: ChainSpec(
            maxNumberOfTransactionsPerBlock: 1,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 10,
            halvingInterval: 100
        ))
        let intent = try await simpleChildIntent(
            service: fixture.service,
            directory: "Grandchild",
            timestamp: 2
        )
        _ = try await fixture.service.submitTransaction(
            SubmitTransactionRequest(transaction: try signedTransaction(
                key: CryptoUtils.generateKeyPair(),
                chainPath: ["Nexus", "Payments"],
                genesisActions: [GenesisAction(
                    directory: intent.directory,
                    blockCID: intent.genesisCID
                )]
            ))
        )
        let miner = CryptoUtils.generateKeyPair()
        let reward = try signedTransaction(
            key: miner,
            chainPath: ["Nexus", "Payments"],
            accountActions: [AccountAction(
                owner: CryptoUtils.createAddress(from: miner.publicKey),
                delta: 1
            )]
        )

        await XCTAssertThrowsErrorAsync(
            try await fixture.service.miningCandidate(
                parentCarrier: fixture.parentCarrier,
                parentContentSource: FetcherContentSource(fixture.parent),
                rewards: [MiningReward(
                    chainPath: ["Nexus", "Payments"],
                    transaction: reward
                )],
                mode: .deployment
            )
        ) { error in
            XCTAssertEqual(error as? ChainServiceError, .templateTooLarge)
        }
        let status = await fixture.service.status()
        XCTAssertEqual(status.pendingChildIntents, 1)
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

    func testChildDeploymentRejectsParentOnlyHitBeforeAnchorCanStrand()
        async throws
    {
        let process = try await nexusProcess()
        let service = makeService(process: process)
        let childTarget = UInt256.max / UInt256(256)
        let intent = try await simpleChildIntent(
            service: service,
            directory: "Sandbox",
            timestamp: 1,
            target: childTarget
        )
        let key = CryptoUtils.generateKeyPair()
        _ = try await service.submitTransaction(SubmitTransactionRequest(
            transaction: try signedTransaction(
                key: key,
                chainPath: ["Nexus"],
                genesisActions: [GenesisAction(
                    directory: intent.directory,
                    blockCID: intent.genesisCID
                )]
            )
        ))
        let tipBefore = try BlockHeader(
            node: try await process.canonicalTipBlock()
        ).rawCID
        let template = try await service.miningTemplate(
            MiningTemplateRequest(mode: .deployment)
        )
        XCTAssertEqual(template.searchTarget, childTarget)

        var missNonce: UInt64 = 0
        while template.block.replacingNonce(missNonce).proofOfWorkHash()
            <= childTarget {
            missNonce += 1
        }
        await XCTAssertThrowsErrorAsync(
            try await service.submitWork(SubmitWorkRequest(
                workID: template.workID,
                nonce: missNonce
            ))
        ) { error in
            XCTAssertEqual(error as? MiningTemplateError, .missesSearchTarget)
        }
        let tipAfterMiss = try BlockHeader(
            node: try await process.canonicalTipBlock()
        ).rawCID
        XCTAssertEqual(tipAfterMiss, tipBefore)
        var status = await service.status()
        XCTAssertEqual(status.mempoolCount, 1)
        XCTAssertEqual(status.pendingChildIntents, 1)

        var hitNonce: UInt64 = 0
        while template.block.replacingNonce(hitNonce).proofOfWorkHash()
            > childTarget {
            hitNonce += 1
        }
        let submitted = try await service.submitWork(SubmitWorkRequest(
            workID: template.workID,
            nonce: hitNonce
        ))
        XCTAssertTrue(submitted.accepted)
        XCTAssertEqual(submitted.parentGenesisLinks.map(\.childGenesisCID), [
            intent.genesisCID
        ])
        status = await service.status()
        XCTAssertEqual(status.mempoolCount, 0)
        XCTAssertEqual(status.pendingChildIntents, 0)
    }

    func testCanonicalStateChangeExpiresStaleChildIntent() async throws {
        let service = makeService(process: try await nexusProcess())
        _ = try await simpleChildIntent(
            service: service,
            directory: "Sandbox",
            timestamp: 1
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
        _ = try await service.submitWork(SubmitWorkRequest(
            workID: template.workID,
            nonce: 0
        ))

        let status = await service.status()
        XCTAssertEqual(status.pendingChildIntents, 0)
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
            transactions: [],
            childTimestamp: 1,
            carrierNonce: 0
        )
        let anchoredParent = try await process.canonicalTipBlock()
        XCTAssertEqual(anchoredParent.nextTarget, UInt256.max / UInt256(2))
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
            MiningTemplateRequest(mode: .deployment)
        )
        let children = try XCTUnwrap(template.block.children.node)
        XCTAssertEqual(Set(try children.allKeysAndValues().keys), ["A"])
    }

    func testSchedulingComesFromCommittedCandidateContent()
        async throws
    {
        let process = try await nexusProcess()
        let service = makeService(
            process: process,
            childCandidateProvider: { context in
                let child = try await BlockBuilder.buildChildGenesis(
                    spec: NexusGenesis.spec,
                    parentState: context.parentCarrier.prevState,
                    timestamp: context.parentCarrier.timestamp,
                    target: .max,
                    fetcher: process
                )
                return [
                    DirectChildCandidate(
                        directory: "Healthy",
                        block: child
                    ),
                    DirectChildCandidate(
                        directory: "Poisoned",
                        block: child
                    ),
                    DirectChildCandidate(
                        directory: "Viable",
                        block: child
                    ),
                ]
            }
        )

        let normal = try await service.miningTemplate(MiningTemplateRequest())
        XCTAssertEqual(
            Set(try XCTUnwrap(normal.block.children.node).allKeysAndValues().keys),
            []
        )
        XCTAssertEqual(normal.searchTarget, .max)

        let first = try await service.miningTemplate(
            MiningTemplateRequest(mode: .deployment)
        )
        let second = try await service.miningTemplate(
            MiningTemplateRequest(mode: .deployment)
        )
        XCTAssertEqual(first.searchTarget, .max)
        XCTAssertEqual(second.searchTarget, .max)
        let firstDirectories = Set(
            try XCTUnwrap(first.block.children.node).allKeysAndValues().keys
        )
        let secondDirectories = Set(
            try XCTUnwrap(second.block.children.node).allKeysAndValues().keys
        )
        XCTAssertNotEqual(firstDirectories, secondDirectories)
        for template in [first, second] {
            let directories = Set(
                try XCTUnwrap(template.block.children.node)
                    .allKeysAndValues().keys
            )
            XCTAssertEqual(directories.count, 1)
        }
    }

    func testDeploymentRoundsAlternateLocalAndDescendantSources() async throws {
        let process = try await nexusProcess()
        let service = makeService(
            process: process,
            childCandidateProvider: { context in
                let child = try await BlockBuilder.buildChildGenesis(
                    spec: NexusGenesis.spec,
                    parentState: context.parentCarrier.prevState,
                    timestamp: context.parentCarrier.timestamp,
                    target: UInt256.max / UInt256(2),
                    fetcher: process
                )
                return [DirectChildCandidate(
                    directory: "Existing",
                    block: child
                )]
            }
        )
        let intent = try await simpleChildIntent(
            service: service,
            directory: "Local",
            timestamp: 1
        )
        _ = try await service.submitTransaction(SubmitTransactionRequest(
            transaction: try signedTransaction(
                key: CryptoUtils.generateKeyPair(),
                chainPath: ["Nexus"],
                genesisActions: [GenesisAction(
                    directory: intent.directory,
                    blockCID: intent.genesisCID
                )]
            )
        ))

        let local = try await service.miningTemplate(
            MiningTemplateRequest(mode: .deployment)
        )
        let descendant = try await service.miningTemplate(
            MiningTemplateRequest(mode: .deployment)
        )
        let localAgain = try await service.miningTemplate(
            MiningTemplateRequest(mode: .deployment)
        )

        XCTAssertEqual(
            Set(try XCTUnwrap(local.block.children.node).allKeysAndValues().keys),
            ["Local"]
        )
        XCTAssertEqual(local.block.transactions.node?.count, 1)
        XCTAssertEqual(
            Set(try XCTUnwrap(descendant.block.children.node).allKeysAndValues().keys),
            ["Existing"]
        )
        XCTAssertEqual(descendant.block.transactions.node?.count, 0)
        XCTAssertEqual(
            Set(try XCTUnwrap(localAgain.block.children.node).allKeysAndValues().keys),
            ["Local"]
        )
        XCTAssertEqual(localAgain.block.transactions.node?.count, 1)
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
        let childGenesis = try await BlockBuilder.buildChildGenesis(
            spec: childSpec,
            parentState: parentGenesis.postState,
            transactions: [],
            timestamp: 1,
            target: UInt256.max,
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
            children: ["Payments": childGenesis],
            timestamp: parentGenesis.timestamp + 1,
            nonce: 0,
            fetcher: parentProcess
        )
        let firstCarrierHeader = try BlockHeader(node: firstCarrier)
        let parentOutcome = try await parentProcess.admit(firstCarrierHeader)
        XCTAssertNotNil(parentOutcome.parentCarrierLink)
        let issuedGenesisLink = try await parentProcess.issuedParentGenesisLink(
            directory: "Payments",
            childGenesisCID: childHeader.rawCID,
            parentStateCID: firstCarrier.prevState.rawCID
        )
        let genesisLink = try XCTUnwrap(issuedGenesisLink)
        let proof = try await ChildBlockProof.generate(
            rootHeader: firstCarrierHeader,
            childDirectory: "Payments",
            fetcher: parentProcess
        )

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
        try await childHeader.storeBlock(
            fetcher: childProcess,
            storer: childProcess
        )
        try await childGenesis.postState.storeRecursively(storer: childProcess)
        let bootstrap = try await childProcess.admit(
            childHeader,
            authenticatedChildPackage: AuthenticatedChildPackage(
                package: ChildValidationPackage(
                    proof: proof,
                    parentGenesisLink: genesisLink
                )
            )
        )
        XCTAssertTrue(
            bootstrap.decision.isAccepted,
            "unexpected bootstrap decision: \(bootstrap.decision)"
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
                    parentCreatedGenesis: false,
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
                        parentCreatedGenesis: false,
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
            parentCreatedGenesis: false,
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
            mempoolMaxCount: mempoolMaxCount
        )
    }

    private func simpleChildIntent(
        service: ChainService,
        directory: String,
        timestamp: Int64,
        target: UInt256 = .max
    ) async throws -> ChildDeployIntentResponse {
        try await service.createChildDeployIntent(ChildDeployIntentRequest(
            directory: directory,
            spec: ChainSpec(
                maxNumberOfTransactionsPerBlock: 100,
                maxStateGrowth: 100_000,
                premine: 0,
                targetBlockTime: 1_000,
                initialReward: 10,
                halvingInterval: 100
            ),
            genesisTransactions: [],
            target: target,
            timestamp: timestamp
        ))
    }

    private func childSpec(
        policyModule: ContentBoundWasmPolicyModule
    ) -> ChainSpec {
        ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 10,
            halvingInterval: 100,
            wasmPolicies: [WasmPolicyRef(
                moduleCID: policyModule.rootCID,
                scope: .transaction
            )]
        )
    }

    private func wasmPolicyModule(
        accepts: Bool
    ) throws -> ContentBoundWasmPolicyModule {
        // Minimal module: one memory, allocator, and transaction validator.
        try ContentBoundWasmPolicyModule(bytes: Data([
            0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
            0x01, 0x0c, 0x02,
            0x60, 0x01, 0x7f, 0x01, 0x7f,
            0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f,
            0x03, 0x03, 0x02, 0x00, 0x01,
            0x05, 0x03, 0x01, 0x00, 0x01,
            0x07, 0x39, 0x03,
            0x06, 0x6d, 0x65, 0x6d, 0x6f, 0x72, 0x79, 0x02, 0x00,
            0x0d, 0x6c, 0x61, 0x74, 0x74, 0x69, 0x63, 0x65, 0x5f,
            0x61, 0x6c, 0x6c, 0x6f, 0x63, 0x00, 0x00,
            0x1c, 0x6c, 0x61, 0x74, 0x74, 0x69, 0x63, 0x65, 0x5f,
            0x76, 0x61, 0x6c, 0x69, 0x64, 0x61, 0x74, 0x65, 0x5f,
            0x74, 0x72, 0x61, 0x6e, 0x73, 0x61, 0x63, 0x74, 0x69,
            0x6f, 0x6e, 0x00, 0x01,
            0x0a, 0x0b, 0x02,
            0x04, 0x00, 0x41, 0x00, 0x0b,
            0x04, 0x00, 0x41, accepts ? 0x01 : 0x00, 0x0b,
        ]))
    }

    private struct AnchoredChildGenesis {
        let block: Block
        let header: BlockHeader
        let carrierCID: String
        let package: AuthenticatedChildPackage
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
            transactions: [],
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
        try await storeChildGenesis(child, in: process)
        let bootstrap = try await process.admit(
            child.header,
            authenticatedChildPackage: child.package
        )
        XCTAssertTrue(
            bootstrap.decision.isAccepted,
            "unexpected bootstrap decision for maxBlockSize \(spec.maxBlockSize): \(bootstrap.decision)"
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
        transactions: [Transaction],
        childTimestamp: Int64,
        carrierNonce: UInt64,
        spec: ChainSpec = NexusGenesis.spec
    ) async throws -> AnchoredChildGenesis {
        for transaction in transactions {
            try await VolumeImpl<Transaction>(node: transaction).storeRecursively(
                storer: parent
            )
        }
        let block = try await BlockBuilder.buildChildGenesis(
            spec: spec,
            parentState: parentGenesis.postState,
            transactions: transactions,
            timestamp: childTimestamp,
            target: UInt256.max,
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
            children: ["Payments": block],
            timestamp: parentGenesis.timestamp + 1,
            nonce: carrierNonce,
            fetcher: parent
        )
        let carrierHeader = try BlockHeader(node: carrier)
        let parentAdmission = try await parent.admit(carrierHeader)
        XCTAssertNotNil(parentAdmission.parentCarrierLink)
        let issuedGenesisLink = try await parent.issuedParentGenesisLink(
            directory: "Payments",
            childGenesisCID: header.rawCID,
            parentStateCID: carrier.prevState.rawCID
        )
        let genesisLink = try XCTUnwrap(issuedGenesisLink)
        let proof = try await ChildBlockProof.generate(
            rootHeader: carrierHeader,
            childDirectory: "Payments",
            fetcher: parent
        )
        return AnchoredChildGenesis(
            block: block,
            header: header,
            carrierCID: carrierHeader.rawCID,
            package: AuthenticatedChildPackage(
                package: ChildValidationPackage(
                    proof: proof,
                    parentGenesisLink: genesisLink
                )
            )
        )
    }

    private func storeChildGenesis(
        _ child: AnchoredChildGenesis,
        in process: ChainProcess
    ) async throws {
        try await child.header.storeBlock(fetcher: process, storer: process)
        try await child.block.postState.storeRecursively(storer: process)
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
