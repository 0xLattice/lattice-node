import Foundation
import UInt256
import XCTest
import cashew
@testable import Lattice
@testable import LatticeNode

final class MultichainInvariantTests: XCTestCase {
    func testDirectParentPackageReplaysOnlyToItsDeclaredChildAcrossRestarts()
        async throws {
        let parentStorage = temporaryDirectory()
        let paymentsStorage = temporaryDirectory()
        let receiptsStorage = temporaryDirectory()
        let parentConfiguration = try configuration(
            path: ["Nexus"],
            storage: parentStorage,
            privateKeyHex: String(repeating: "41", count: 32)
        )
        let paymentsConfiguration = try configuration(
            path: ["Nexus", "Payments"],
            storage: paymentsStorage,
            privateKeyHex: String(repeating: "42", count: 32),
            parentPublicKey: parentConfiguration.processPublicKey
        )
        let receiptsConfiguration = try configuration(
            path: ["Nexus", "Payments", "Receipts"],
            storage: receiptsStorage,
            privateKeyHex: String(repeating: "43", count: 32),
            parentPublicKey: paymentsConfiguration.processPublicKey
        )

        var parent: ChainProcess? = try await ChainProcess.open(
            configuration: parentConfiguration
        )
        let parentGenesis = try await parent!.canonicalTipBlock()
        // A self-contained child genesis (empty parentState) the parent RECORDS
        // via a GenesisAction. The Payments node rebuilds it from `seed` and
        // self-admits it.
        let seed = ChildGenesisSeed(
            spec: NexusGenesis.spec, premineTo: nil, timestamp: 1
        )
        let childGenesis = try await ChildGenesisBuilder.build(
            seed: seed,
            chainPath: ["Nexus", "Payments"],
            fetcher: parent!
        )
        let childGenesisCID = try BlockHeader(node: childGenesis).rawCID
        let authorization = try signedGenesisAnchorTransaction(
            directory: "Payments",
            childGenesisCID: childGenesisCID
        )
        try await VolumeImpl<Transaction>(node: authorization).storeRecursively(
            storer: parent!
        )
        // The genesis is recorded in this carrier; the child's height-1 block is
        // co-mined in the NEXT carrier, whose pre-state (this carrier's post-state)
        // already records the genesis — that is block-1's parentState.
        let unminedRecordingCarrier = try await BlockBuilder.buildBlock(
            previous: parentGenesis,
            transactions: [authorization],
            timestamp: 1,
            nonce: 0,
            fetcher: parent!
        )
        let recordingCarrier = try XCTUnwrap(BlockBuilder.mine(
            block: unminedRecordingCarrier,
            target: unminedRecordingCarrier.target
        ))
        let recordingOutcome = try await parent!.admit(
            try BlockHeader(node: recordingCarrier)
        )
        XCTAssertTrue(recordingOutcome.decision.isAccepted)
        let provisional = try await BlockBuilder.buildBlock(
            previous: recordingCarrier,
            timestamp: 2,
            nonce: 0,
            fetcher: parent!
        )
        let childBlock = try await BlockBuilder.buildBlock(
            previous: childGenesis,
            parentChainBlock: provisional,
            timestamp: 2,
            fetcher: parent!
        )
        let childHeader = try BlockHeader(node: childBlock)
        let unminedCarrier = try await BlockBuilder.buildBlock(
            previous: recordingCarrier,
            children: ["Payments": childBlock],
            timestamp: 2,
            nonce: 0,
            fetcher: parent!
        )
        let carrier = try XCTUnwrap(BlockBuilder.mine(
            block: unminedCarrier,
            target: min(unminedCarrier.target, childBlock.target)
        ))
        _ = try await parent!.prepareChildProofs(
            for: carrier,
            capacity: 16
        )
        let carrierHeader = try BlockHeader(node: carrier)
        let carrierOutcome = try await parent!.admit(
            carrierHeader,
            preparingChildDirectories: ["Payments"]
        )
        XCTAssertTrue(carrierOutcome.decision.isAccepted)
        _ = try await parent!.retryPendingChildProofs(
            carrierCID: carrierHeader.rawCID
        )

        XCTAssertEqual(
            carrierOutcome.parentCarrierLink?.carrierCID,
            carrierHeader.rawCID
        )
        let persistedEvidence = try await parent!.issuedChildEvidence(
            childCID: childHeader.rawCID,
            directory: "Payments",
            rootCID: carrierHeader.rawCID
        )
        let beforeRestart = try XCTUnwrap(persistedEvidence)

        parent = nil
        parent = try await ChainProcess.open(configuration: parentConfiguration)
        let reopenedEvidence = try await parent!.issuedChildEvidence(
            childCID: childHeader.rawCID,
            directory: "Payments",
            rootCID: carrierHeader.rawCID
        )
        let evidence = try XCTUnwrap(reopenedEvidence)
        let reopenedCarrierLink = try await parent!.issuedParentCarrierLink(
            carrierCID: carrierHeader.rawCID,
            rootCID: carrierHeader.rawCID
        )
        let carrierLink = try XCTUnwrap(reopenedCarrierLink)
        let reopenedGenesisLink = try await parent!.issuedParentGenesisLink(
            directory: "Payments",
            childGenesisCID: childGenesisCID,
            // A self-contained genesis's recorded link binds to the empty parent
            // state, not the recording carrier's prevState.
            parentStateCID: LatticeState.emptyHeader.rawCID
        )
        let genesisLink = try XCTUnwrap(reopenedGenesisLink)
        XCTAssertEqual(carrierLink.parentPath, ["Nexus"])
        XCTAssertEqual(carrierLink.carrierCID, carrierHeader.rawCID)
        XCTAssertEqual(carrierLink.rootCID, carrierHeader.rawCID)
        XCTAssertEqual(genesisLink.parentPath, ["Nexus"])
        XCTAssertEqual(genesisLink.directory, "Payments")
        XCTAssertEqual(genesisLink.childGenesisCID, childGenesisCID)
        XCTAssertEqual(
            try evidence.proof.serialize(),
            try beforeRestart.proof.serialize()
        )
        XCTAssertEqual(evidence.proof.rootCID, carrierHeader.rawCID)
        XCTAssertEqual(evidence.proof.directoryPath, ["Payments"])

        // A co-mined height-1 block is authenticated by its carrier proof alone;
        // the genesis link is only for genesis admission (the child already
        // self-admitted its genesis). validateParentFacts requires a nil link here.
        let package = AuthenticatedChildPackage(
            package: ChildValidationPackage(
                proof: evidence.proof,
                parentGenesisLink: nil
            )
        )
        let childBlockHeader = BlockHeader(
            rawCID: childHeader.rawCID,
            node: nil,
            encryptionInfo: nil
        )
        let childContent = MultichainContentStore()
        try await childHeader.storeBlock(
            fetcher: parent!,
            storer: childContent
        )

        // A descendant (Receipts) must not be bootstrapped by an ancestor's
        // (Payments') child package, even after self-admitting nothing yet.
        var receipts: ChainProcess? = try await ChainProcess.open(
            configuration: receiptsConfiguration
        )
        let receiptsOutcome = try await receipts!.admit(
            childBlockHeader,
            authenticatedChildPackage: package,
            remoteSource: childContent
        )
        XCTAssertFalse(
            receiptsOutcome.decision.isAccepted,
            "an ancestor package must not bootstrap a descendant: \(receiptsOutcome.decision)"
        )
        let receiptsStatus = await receipts!.status()
        XCTAssertEqual(receiptsStatus.phase, .awaitingGenesis)
        XCTAssertEqual(receiptsStatus.chainPath, ["Nexus", "Payments", "Receipts"])
        XCTAssertNil(receiptsStatus.tipCID)

        receipts = nil
        receipts = try await ChainProcess.open(configuration: receiptsConfiguration)
        let reopenedReceiptsStatus = await receipts!.status()
        XCTAssertEqual(reopenedReceiptsStatus.phase, .awaitingGenesis)
        XCTAssertNil(reopenedReceiptsStatus.tipCID)

        // Payments self-admits its self-contained genesis from the seed, then the
        // parent package co-mines its height-1 block onto that genesis.
        var payments: ChainProcess? = try await ChainProcess.open(
            configuration: paymentsConfiguration
        )
        let paymentsBootstrapped = try await payments!
            .activateSeededChildGenesis(seed: seed)
        XCTAssertTrue(paymentsBootstrapped)
        let accepted = try await payments!.admit(
            childBlockHeader,
            authenticatedChildPackage: package,
            remoteSource: childContent
        )
        XCTAssertTrue(accepted.decision.isAccepted)
        let paymentsStatus = await payments!.status()
        XCTAssertEqual(paymentsStatus.tipCID, childHeader.rawCID)

        payments = nil
        payments = try await ChainProcess.open(configuration: paymentsConfiguration)
        let reopenedPaymentsStatus = await payments!.status()
        XCTAssertEqual(reopenedPaymentsStatus.tipCID, childHeader.rawCID)
    }

    private func configuration(
        path: [String],
        storage: URL,
        privateKeyHex: String,
        parentPublicKey: String? = nil
    ) throws -> NodeConfiguration {
        try NodeConfiguration(
            chainPath: path,
            storagePath: storage,
            privateKeyHex: privateKeyHex,
            parentEndpoint: parentPublicKey.map {
                ParentEndpoint(publicKey: $0, host: "127.0.0.1", port: 4002)
            }
        )
    }

    private func signedGenesisAnchorTransaction(
        directory: String,
        childGenesisCID: String
    ) throws -> Transaction {
        let key = CryptoUtils.generateKeyPair()
        let body = TransactionBody(
            accountActions: [],
            actions: [],
            depositActions: [],
            genesisActions: [GenesisAction(
                directory: directory,
                blockCID: childGenesisCID
            )],
            receiptActions: [],
            withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: key.publicKey)],
            fee: 0,
            nonce: 0,
            chainPath: ["Nexus"]
        )
        let bodyHeader = try HeaderImpl<TransactionBody>(node: body)
        let signature = try XCTUnwrap(TransactionSigning.sign(
            bodyHeader: bodyHeader,
            privateKeyHex: key.privateKey
        ))
        return Transaction(
            signatures: [key.publicKey: signature],
            body: bodyHeader
        )
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-multichain-invariant-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}

private actor MultichainContentStore: ContentSource, VolumeStorer {
    private var entries: [String: Data] = [:]

    func fetch(_ cids: Set<String>) -> [String: Data] {
        entries.filter { cids.contains($0.key) }
    }

    func store(volume: SerializedVolume) {
        entries.merge(volume.entries) { existing, _ in existing }
    }
}
