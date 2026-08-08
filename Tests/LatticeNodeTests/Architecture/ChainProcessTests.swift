import Crypto
import Ivy
@testable import Lattice
import UInt256
import VolumeBroker
import XCTest
import cashew
@testable import LatticeNode

final class ChainProcessTests: XCTestCase {
    func testLocalTransactionVolumeSurvivesRestartAndUnretainsOnRemoval()
        async throws
    {
        let directory = temporaryDirectory()
        let config = try configuration(path: ["Nexus"], storage: directory)
        let transaction = try signedGenesisAnchorTransaction(
            directory: "Local",
            childGenesisCID: try HeaderImpl<PublicKey>(
                node: PublicKey(key: "local-mempool-child")
            ).rawCID
        )
        let owner = [config.nexusGenesisCID, config.address.key]
            .joined(separator: ":") + ":durable-mempool"

        var process: ChainProcess? = try await ChainProcess.open(
            configuration: config
        )
        let transactionCID = try await process!.persistLocalTransaction(
            transaction,
            addedAt: 123
        )
        var loaded = try await process!.localTransactions()
        XCTAssertEqual(loaded.map(\.transactionCID), [transactionCID])
        XCTAssertEqual(loaded.map(\.addedAt), [123])

        process = nil
        process = try await ChainProcess.open(configuration: config)
        loaded = try await process!.localTransactions()
        XCTAssertEqual(loaded.map(\.transactionCID), [transactionCID])
        let broker = try DiskBroker(
            path: directory.appendingPathComponent("volumes.db").path
        )
        var owners = await broker.owners(root: transactionCID)
        XCTAssertTrue(owners.contains(owner))

        try await process!.removeLocalTransaction(transactionCID)
        var isEmpty = try await process!.localTransactions().isEmpty
        XCTAssertTrue(isEmpty)
        owners = await broker.owners(root: transactionCID)
        XCTAssertTrue(owners.isEmpty)
        process = nil
        process = try await ChainProcess.open(configuration: config)
        isEmpty = try await process!.localTransactions().isEmpty
        owners = await broker.owners(root: transactionCID)
        XCTAssertTrue(isEmpty)
        XCTAssertTrue(owners.isEmpty)
    }

    func testOpenFailsClosedWhenLocalTransactionVolumeIsMissing() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let config = try configuration(path: ["Nexus"], storage: directory)
        let transaction = try signedGenesisAnchorTransaction(
            directory: "Missing",
            childGenesisCID: try HeaderImpl<PublicKey>(
                node: PublicKey(key: "missing-mempool-child")
            ).rawCID
        )
        let transactionCID = try VolumeImpl<Transaction>(node: transaction).rawCID
        let store = try testNodeStore(
            databasePath: directory.appendingPathComponent("state.db"),
            nexusGenesisCID: config.nexusGenesisCID,
            chainPath: config.chainPath,
            issuingAuthorityKey: config.processPublicKey
        )
        try await store.persistLocalMempoolTransaction(
            transactionCID: transactionCID,
            addedAt: 1
        )

        do {
            _ = try await ChainProcess.open(configuration: config)
            XCTFail("expected missing local transaction Volume")
        } catch {
            XCTAssertEqual(
                error as? ChainProcessError,
                .missingMaterializedVolume(transactionCID)
            )
        }
    }

    func testOpenDropsContextualPinsWhoseStatePublicationNeverCommitted()
        async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let config = try configuration(path: ["Nexus"], storage: directory)
        let owner = [config.nexusGenesisCID, config.address.key]
            .joined(separator: ":") + ":contextual-candidates"
        let broker = try DiskBroker(
            path: directory.appendingPathComponent("volumes.db").path
        )
        let volumes = try ["kept", "orphan", "shared"].map {
            try VolumeImpl<PublicKey>(node: PublicKey(key: $0))
        }
        for volume in volumes {
            try await volume.store(storer: broker)
        }
        let kept = volumes[0].rawCID
        let orphan = volumes[1].rawCID
        let shared = volumes[2].rawCID

        var store: NodeStore? = try testNodeStore(
            databasePath: directory.appendingPathComponent("state.db"),
            nexusGenesisCID: config.nexusGenesisCID,
            chainPath: config.chainPath,
            issuingAuthorityKey: config.processPublicKey,
            contextualCandidateOwner: owner
        )
        try await store!.persistContextualCandidateRoots(
            candidateCID: kept,
            roots: [kept, shared],
            capacity: 2
        )
        // Crash after the VolumeBroker transaction but before state.db.
        try await broker.pinBatch(roots: [orphan, shared], owner: owner)
        let stateRoots = try await store!.contextualCandidateVolumeRoots()
        XCTAssertEqual(Set(stateRoots), Set([kept, shared]))
        store = nil

        let process = try await ChainProcess.open(configuration: config)
        let recoveredPins = await broker.pinnedRoots(owners: [owner])
        XCTAssertEqual(Set(recoveredPins), Set([kept, shared]))
        _ = try await broker.evictUnpinned(graceSeconds: 0)
        let evictedOrphan = await broker.fetchVolumeLocal(root: orphan)
        let retainedKept = await broker.fetchVolumeLocal(root: kept)
        let retainedShared = await broker.fetchVolumeLocal(root: shared)
        XCTAssertNil(evictedOrphan)
        XCTAssertNotNil(retainedKept)
        XCTAssertNotNil(retainedShared)
        try await broker.unpin(root: shared, owner: owner, count: 1)
        _ = try await broker.evictUnpinned(graceSeconds: 0)
        let releasedShared = await broker.fetchVolumeLocal(root: shared)
        XCTAssertNil(releasedShared)
        _ = process
    }

    func testOpenDropsContextualPinsLeftAfterStateEvictionCommitted()
        async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let config = try configuration(path: ["Nexus"], storage: directory)
        let owner = [config.nexusGenesisCID, config.address.key]
            .joined(separator: ":") + ":contextual-candidates"
        let broker = try DiskBroker(
            path: directory.appendingPathComponent("volumes.db").path
        )
        let volumes = try ["old", "kept", "newest", "shared"].map {
            try VolumeImpl<PublicKey>(node: PublicKey(key: $0))
        }
        for volume in volumes {
            try await volume.store(storer: broker)
        }
        let old = volumes[0].rawCID
        let kept = volumes[1].rawCID
        let newest = volumes[2].rawCID
        let shared = volumes[3].rawCID

        var store: NodeStore? = try testNodeStore(
            databasePath: directory.appendingPathComponent("state.db"),
            nexusGenesisCID: config.nexusGenesisCID,
            chainPath: config.chainPath,
            issuingAuthorityKey: config.processPublicKey,
            contextualCandidateOwner: owner
        )
        try await store!.persistContextualCandidateRoots(
            candidateCID: old,
            roots: [old, shared],
            capacity: 2
        )
        try await store!.persistContextualCandidateRoots(
            candidateCID: kept,
            roots: [kept, shared],
            capacity: 2
        )
        try await store!.persistContextualCandidateRoots(
            candidateCID: newest,
            roots: [newest, shared],
            capacity: 2
        )
        // Crash after state.db eviction but before the old pin delta.
        try await broker.pinBatch(roots: [old, shared], owner: owner)
        store = nil

        let process = try await ChainProcess.open(configuration: config)
        let recoveredPins = await broker.pinnedRoots(owners: [owner])
        XCTAssertEqual(Set(recoveredPins), Set([kept, newest, shared]))
        _ = try await broker.evictUnpinned(graceSeconds: 0)
        let evictedOld = await broker.fetchVolumeLocal(root: old)
        let retainedKept = await broker.fetchVolumeLocal(root: kept)
        let retainedNewest = await broker.fetchVolumeLocal(root: newest)
        let retainedShared = await broker.fetchVolumeLocal(root: shared)
        XCTAssertNil(evictedOld)
        XCTAssertNotNil(retainedKept)
        XCTAssertNotNil(retainedNewest)
        XCTAssertNotNil(retainedShared)
        try await broker.unpin(root: shared, owner: owner, count: 1)
        _ = try await broker.evictUnpinned(graceSeconds: 0)
        let sharedAfterOneRelease = await broker.fetchVolumeLocal(root: shared)
        XCTAssertNotNil(sharedAfterOneRelease)
        try await broker.unpin(root: shared, owner: owner, count: 1)
        _ = try await broker.evictUnpinned(graceSeconds: 0)
        let sharedAfterTwoReleases = await broker.fetchVolumeLocal(root: shared)
        XCTAssertNil(sharedAfterTwoReleases)
        _ = process
    }

    func testLiveMempoolPinsTrackCurrentRootsAndClearOnRestart() async throws {
        let directory = temporaryDirectory()
        let config = try configuration(path: ["Nexus"], storage: directory)
        let first = try signedGenesisAnchorTransaction(
            directory: "First",
            childGenesisCID: NexusGenesis.expectedBlockHash
        )
        let second = try signedGenesisAnchorTransaction(
            directory: "Second",
            childGenesisCID: NexusGenesis.expectedBlockHash
        )
        var process: ChainProcess? = try await ChainProcess.open(
            configuration: config
        )
        let firstRoot = try await process!.persistPeerTransaction(first)
        let secondRoot = try await process!.persistPeerTransaction(second)
        try await process!.updateLiveMempoolRoots(
            adding: [firstRoot, secondRoot],
            removing: []
        )
        let broker = try DiskBroker(
            path: directory.appendingPathComponent("volumes.db").path
        )
        let owner = [config.nexusGenesisCID, config.address.key]
            .joined(separator: ":") + ":live-mempool"
        var firstOwners = await broker.owners(root: firstRoot)
        var secondOwners = await broker.owners(root: secondRoot)
        XCTAssertEqual(firstOwners, Set([owner]))
        XCTAssertEqual(secondOwners, Set([owner]))

        try await process!.updateLiveMempoolRoots(
            adding: [],
            removing: [firstRoot]
        )
        firstOwners = await broker.owners(root: firstRoot)
        secondOwners = await broker.owners(root: secondRoot)
        XCTAssertTrue(firstOwners.isEmpty)
        XCTAssertEqual(secondOwners, Set([owner]))

        process = nil
        process = try await ChainProcess.open(configuration: config)
        secondOwners = await broker.owners(root: secondRoot)
        XCTAssertTrue(secondOwners.isEmpty)
        process = nil
    }

    func testTransientHierarchyContentIsAvailableOnlyAsACompleteVolume()
        async throws
    {
        let directory = temporaryDirectory()
        let process = try await ChainProcess.open(configuration: try configuration(
            path: ["Nexus"],
            storage: directory
        ))
        let durableHeader = try HeaderImpl<PublicKey>(
            node: PublicKey(key: "durable")
        )
        let provisionalHeader = try HeaderImpl<PublicKey>(
            node: PublicKey(key: "provisional")
        )
        let missingHeader = try HeaderImpl<PublicKey>(node: PublicKey(key: "missing"))
        let durable = try durableHeader.mapToData()
        let provisional = try provisionalHeader.mapToData()
        let nestedHeader = try HeaderImpl<PublicKey>(
            node: PublicKey(key: "provisional-member")
        )
        let nested = try nestedHeader.mapToData()
        let broker = try DiskBroker(
            path: directory.appendingPathComponent("volumes.db").path
        )
        try await broker.store(volume: SerializedVolume(
            root: durableHeader.rawCID,
            entries: [durableHeader.rawCID: durable]
        ))
        let source = ChainProcessIvyContentSource(
            process: process,
            transientRootVolume: { rootCID in
                rootCID == provisionalHeader.rawCID
                    ? SerializedVolume(
                        root: provisionalHeader.rawCID,
                        entries: [
                            provisionalHeader.rawCID: provisional,
                            nestedHeader.rawCID: nested,
                        ]
                    )
                    : nil
            }
        )

        let provisionalVolume = await source.volume(
            rootCID: provisionalHeader.rawCID,
            maxDataBytes: 1_024
        )
        XCTAssertEqual(provisionalVolume, [
            ContentEntry(cid: provisionalHeader.rawCID, data: provisional),
            ContentEntry(cid: nestedHeader.rawCID, data: nested),
        ].sorted { $0.cid < $1.cid })

        let durableVolume = await source.volume(
            rootCID: durableHeader.rawCID,
            maxDataBytes: 1_024
        )
        XCTAssertEqual(durableVolume, [
            ContentEntry(cid: durableHeader.rawCID, data: durable),
        ])

        let missingVolume = await source.volume(
            rootCID: missingHeader.rawCID,
            maxDataBytes: 1_024
        )
        XCTAssertTrue(missingVolume.isEmpty)

        let selectedEntries = await source.content(
            rootCID: provisionalHeader.rawCID,
            cids: [provisionalHeader.rawCID],
            maxDataBytes: 1_024
        )
        XCTAssertTrue(selectedEntries.isEmpty)
    }

    func testNexusOpenBootstrapsExactGenesisAndRecoversIt() async throws {
        let directory = temporaryDirectory()
        var process: ChainProcess? = try await ChainProcess.open(
            configuration: try configuration(path: ["Nexus"], storage: directory)
        )

        var status = await process!.status()
        XCTAssertEqual(status.phase, .active)
        XCTAssertEqual(status.tipCID, NexusGenesis.expectedBlockHash)
        XCTAssertEqual(status.height, 0)

        process = nil
        process = try await ChainProcess.open(
            configuration: try configuration(path: ["Nexus"], storage: directory)
        )
        status = await process!.status()
        XCTAssertEqual(status.phase, .active)
        XCTAssertEqual(status.tipCID, NexusGenesis.expectedBlockHash)
    }

    func testAuthenticatedPackageUsesOneBatchedFallbackWave() async throws {
        let fixture = try await childBootstrapFixture()
        let proofEntry = try XCTUnwrap(
            fixture.package.package.proof.entries.first
        )
        let fallback = BatchRecordingContentSource(entries: [
            "first": Data([0x01]),
            "second": Data([0x02]),
        ])
        let source = try ChainProcess.attemptContentSource(
            package: fixture.package.package,
            fallback: fallback
        )

        let entries = await source.fetch([
            proofEntry.cid,
            "first",
            "second",
        ])
        let requests = await fallback.requests()
        XCTAssertEqual(entries[proofEntry.cid], proofEntry.data)
        XCTAssertEqual(entries["first"], Data([0x01]))
        XCTAssertEqual(entries["second"], Data([0x02]))
        XCTAssertEqual(requests, [Set(["first", "second"])])
    }

    func testAttemptFetchersNeverShareAnAcquisitionScope() throws {
        let fallback = BatchRecordingContentSource(entries: [:])
        let first = try ChainProcess.attemptFetcher(
            package: nil,
            fallback: fallback
        )
        let second = try ChainProcess.attemptFetcher(
            package: nil,
            fallback: fallback
        )

        XCTAssertFalse(first === second)
    }

    func testRemoteAdmissionRequiresExplicitPermission() async throws {
        let producer = try await ChainProcess.open(
            configuration: try configuration(
                path: ["Nexus"],
                storage: temporaryDirectory()
            )
        )
        let genesis = try await producer.canonicalTipBlock()
        let candidate = try await BlockBuilder.buildBlock(
            previous: genesis,
            timestamp: 1,
            nonce: 0,
            fetcher: producer
        )
        let header = try BlockHeader(node: candidate)
        let remote = BatchRecordingContentSource(entries:
            try await blockContentEntries(header, fetcher: producer)
        )
        let consumer = try await ChainProcess.open(
            configuration: try configuration(
                path: ["Nexus"],
                storage: temporaryDirectory()
            )
        )
        let unresolved = BlockHeader(
            rawCID: header.rawCID,
            node: nil,
            encryptionInfo: nil
        )

        _ = try? await consumer.admit(unresolved)
        let localRequests = await remote.requests()
        XCTAssertTrue(localRequests.isEmpty)

        let outcome = try await consumer.admit(
            unresolved,
            remoteSource: remote
        )
        XCTAssertTrue(outcome.decision.isAccepted)
        let remoteRequests = await remote.requests()
        XCTAssertFalse(remoteRequests.isEmpty)
    }

    func testAdmissionStagesHierarchyArtifactsAcrossReopen() async throws {
        let directory = temporaryDirectory()
        let config = try configuration(path: ["Nexus"], storage: directory)
        var process: ChainProcess? = try await ChainProcess.open(configuration: config)
        let genesis = try await process!.canonicalTipBlock()
        // A self-contained child genesis (empty parentState) the parent only
        // RECORDS via a plain GenesisAction; it is never carried on the carrier.
        let child = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec,
            parentState: LatticeState.emptyHeader,
            timestamp: 1,
            target: UInt256.max,
            fetcher: process!
        )
        let childCID = try BlockHeader(node: child).rawCID
        let authorization = try signedGenesisAnchorTransaction(
            directory: "Payments",
            childGenesisCID: childCID
        )
        try await VolumeImpl<Transaction>(node: authorization).storeRecursively(
            storer: process!
        )
        let carrier = try await BlockBuilder.buildBlock(
            previous: genesis,
            transactions: [authorization],
            timestamp: 1,
            nonce: 0,
            fetcher: process!
        )
        let carrierHeader = try BlockHeader(node: carrier)

        let outcome = try await process!.admit(carrierHeader)
        XCTAssertTrue(outcome.decision.isAccepted)
        let carrierLink = try XCTUnwrap(outcome.parentCarrierLink)
        process = nil

        process = try await ChainProcess.open(configuration: config)
        let persistedCarrier = try await process!.issuedParentCarrierLink(
            carrierCID: carrierHeader.rawCID,
            rootCID: carrierLink.rootCID
        )
        let persistedGenesis = try await process!.issuedParentGenesisLink(
            directory: "Payments",
            childGenesisCID: childCID,
            // A self-contained genesis's recorded link binds to the empty parent
            // state, not the recording carrier's prevState.
            parentStateCID: LatticeState.emptyHeader.rawCID
        )
        XCTAssertEqual(persistedCarrier, carrierLink)
        XCTAssertEqual(persistedGenesis?.parentPath, ["Nexus"])
        XCTAssertEqual(persistedGenesis?.directory, "Payments")
        XCTAssertEqual(persistedGenesis?.childGenesisCID, childCID)
    }

    func testDisconnectedCarrierRelaysBeforeGenesisFactPromotion() async throws {
        let directory = temporaryDirectory()
        let config = try configuration(path: ["Nexus"], storage: directory)
        var process: ChainProcess? = try await ChainProcess.open(
            configuration: config
        )
        let genesis = try await process!.canonicalTipBlock()
        let missingParent = try await BlockBuilder.buildBlock(
            previous: genesis,
            timestamp: 1,
            nonce: 1,
            fetcher: process!
        )
        let missingParentHeader = try BlockHeader(node: missingParent)
        try await missingParentHeader.storeBlock(
            fetcher: process!,
            storer: process!
        )
        // A self-contained child genesis (empty parentState) the orphan carrier
        // only RECORDS via a plain GenesisAction; it is never carried.
        let child = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec,
            parentState: LatticeState.emptyHeader,
            timestamp: 2,
            target: UInt256.max,
            fetcher: process!
        )
        let childCID = try BlockHeader(node: child).rawCID
        let authorization = try signedGenesisAnchorTransaction(
            directory: "Payments",
            childGenesisCID: childCID
        )
        try await VolumeImpl<Transaction>(node: authorization).storeRecursively(
            storer: process!
        )
        let orphanTemplate = try await BlockBuilder.buildBlock(
            previous: missingParent,
            transactions: [authorization],
            timestamp: 2,
            nonce: 2,
            fetcher: process!
        )
        let orphan = try XCTUnwrap(BlockBuilder.mine(
            block: orphanTemplate,
            target: orphanTemplate.target,
            maxAttempts: 1_000_000
        ))
        let orphanHeader = try BlockHeader(node: orphan)

        let first = try await process!.admit(
            orphanHeader,
            preparingChildDirectories: ["Payments"]
        )
        XCTAssertTrue(
            first.decision.isAccepted,
            "orphan admission failed: \(first.decision)"
        )
        XCTAssertEqual(
            first.sameChainPredecessor,
            SameChainPredecessorRequirement(
                descendantCID: orphanHeader.rawCID,
                predecessorCID: missingParentHeader.rawCID
            )
        )
        let relay = try XCTUnwrap(first.parentCarrierLink)
        let earlyGenesis = try await process!.issuedParentGenesisLink(
            directory: "Payments",
            childGenesisCID: childCID,
            parentStateCID: LatticeState.emptyHeader.rawCID
        )
        XCTAssertNil(earlyGenesis)
        process = nil

        process = try await ChainProcess.open(configuration: config)
        let recoveredRelay = try await process!.issuedParentCarrierLink(
            carrierCID: orphanHeader.rawCID,
            rootCID: relay.rootCID
        )
        XCTAssertEqual(
            recoveredRelay,
            relay
        )
        let recoveredGenesis = try await process!.issuedParentGenesisLink(
            directory: "Payments",
            childGenesisCID: childCID,
            parentStateCID: LatticeState.emptyHeader.rawCID
        )
        XCTAssertNil(recoveredGenesis)

        let parentResult = try await process!.admit(missingParentHeader)
        XCTAssertTrue(parentResult.decision.isAccepted)
        let promoted = try await process!.admit(
            orphanHeader,
            preparingChildDirectories: ["Payments"]
        )
        XCTAssertTrue(promoted.decision.isAccepted)
        XCTAssertNil(promoted.sameChainPredecessor)
        let promotedGenesis = try await process!.issuedParentGenesisLink(
            directory: "Payments",
            childGenesisCID: childCID,
            parentStateCID: LatticeState.emptyHeader.rawCID
        )
        XCTAssertNotNil(promotedGenesis)
    }

    func testAcceptedLeafPageStartsWithDurableGenesis() async throws {
        let process = try await ChainProcess.open(
            configuration: try configuration(
                path: ["Nexus"],
                storage: temporaryDirectory()
            )
        )

        let page = try await process.acceptedLeafPage(
            afterCID: nil,
            snapshotSequence: nil,
            limit: 1
        )
        XCTAssertEqual(page.blockCIDs, [NexusGenesis.expectedBlockHash])
        let continuation = try await process.acceptedLeafPage(
            afterCID: NexusGenesis.expectedBlockHash,
            snapshotSequence: page.snapshotSequence,
            limit: 1
        )
        XCTAssertTrue(continuation.blockCIDs.isEmpty)
    }

    func testEmptyChildOpensReadyToRelayWithoutInventingGenesis() async throws {
        let directory = temporaryDirectory()
        let process = try await ChainProcess.open(
            configuration: try configuration(
                path: ["Nexus", "Payments"],
                storage: directory
            )
        )

        let status = await process.status()
        XCTAssertEqual(status.phase, .awaitingGenesis)
        XCTAssertNil(status.tipCID)
        XCTAssertNil(status.height)
    }

    func testMissingParentFactDoesNotOverrideContextualCandidateRetention()
        async throws {
        let fixture = try await childBootstrapFixture()
        let process = try await ChainProcess.open(
            configuration: fixture.configuration
        )
        try await process.storeContextualCandidate(
            fixture.childHeader,
            fetcher: fixture.source,
            capacity: 1
        )
        let owner = [
            fixture.configuration.nexusGenesisCID,
            fixture.configuration.address.key,
        ].joined(separator: ":") + ":contextual-candidates"
        let store = try testNodeStore(
            databasePath: fixture.configuration.storagePath
                .appendingPathComponent("state.db"),
            nexusGenesisCID: fixture.configuration.nexusGenesisCID,
            chainPath: fixture.configuration.chainPath,
            issuingAuthorityKey: fixture.configuration.processPublicKey,
            contextualCandidateOwner: owner
        )
        let retainedBefore = try await store.contextualCandidateVolumeRoots()
        XCTAssertTrue(retainedBefore.contains(fixture.childHeader.rawCID))
        XCTAssertGreaterThan(retainedBefore.count, 1)

        let missingFactPackage = AuthenticatedChildPackage(
            package: ChildValidationPackage(proof: fixture.proof)
        )
        let outcome = try await process.admit(
            fixture.childHeader,
            authenticatedChildPackage: missingFactPackage,
            remoteSource: fixture.source
        )
        guard case .unavailable(.parentGenesis(
            parentPath: _,
            directory: "Payments",
            childGenesisCID: fixture.childHeader.rawCID,
            parentStateCID: _
        )) = outcome.decision else {
            return XCTFail("expected missing parent genesis fact")
        }

        let retainedAfter = try await store.contextualCandidateVolumeRoots()
        XCTAssertEqual(retainedAfter, retainedBefore)
    }

    func testSuccessorAttachmentWaitsForChildGenesis() async throws {
        let fixture = try await childBootstrapFixture()
        let parentSource = fixture.source
        let sameChainSource = ChainProcessTestContentStore()
        let genesis = try XCTUnwrap(fixture.childHeader.node)
        let successor = try await BlockBuilder.buildBlock(
            previous: genesis,
            timestamp: 2,
            nonce: 1,
            fetcher: parentSource
        )
        let successorHeader = try BlockHeader(node: successor)
        try await successorHeader.storeBlock(
            fetcher: parentSource,
            storer: parentSource
        )
        try await successorHeader.storeBlock(
            fetcher: parentSource,
            storer: sameChainSource
        )
        let parentCarrier = try await BlockBuilder.buildGenesis(
            spec: NexusGenesis.spec,
            children: ["Payments": successor],
            timestamp: 3,
            target: UInt256.max,
            fetcher: parentSource
        )
        let parentCarrierHeader = try BlockHeader(node: parentCarrier)
        let proof = try await ChildBlockProof.generate(
            rootHeader: parentCarrierHeader,
            childDirectory: "Payments",
            fetcher: parentSource
        )
        let successorPackage = AuthenticatedChildPackage(
            package: ChildValidationPackage(
                proof: proof,
                parentGenesisLink: nil
            )
        )
        let process = try await ChainProcess.open(
            configuration: fixture.configuration
        )

        let early = try await process.admit(
            successorHeader,
            authenticatedChildPackage: successorPackage,
            remoteSource: sameChainSource
        )
        XCTAssertEqual(early.decision, .unavailable(nil))
        XCTAssertEqual(
            early.sameChainPredecessor,
            SameChainPredecessorRequirement(
                descendantCID: successorHeader.rawCID,
                predecessorCID: fixture.childHeader.rawCID
            )
        )
        XCTAssertEqual(early.parentCarrierLink?.carrierCID, successorHeader.rawCID)
        XCTAssertEqual(early.parentCarrierLink?.rootCID, proof.rootCID)
        let retainedRelay = try await process.recoveredAuthenticatedChildPackage(
            for: successorHeader.rawCID,
            rootCID: proof.rootCID
        )
        XCTAssertEqual(retainedRelay?.package.proof.rootCID, proof.rootCID)

        let bootstrapped = try await process.activateSeededChildGenesis(
            seed: fixture.seed
        )
        XCTAssertTrue(bootstrapped)
        let retry = try await process.admit(
            successorHeader,
            authenticatedChildPackage: successorPackage,
            remoteSource: sameChainSource
        )
        XCTAssertTrue(retry.decision.isAccepted)
        XCTAssertNil(retry.sameChainPredecessor)
    }

    func testSecondProcessCannotOpenTheSameStorageDirectory() async throws {
        let directory = temporaryDirectory()
        let config = try configuration(path: ["Nexus"], storage: directory)
        let process = try await ChainProcess.open(configuration: config)
        defer { _ = process }

        do {
            _ = try await ChainProcess.open(configuration: config)
            XCTFail("second writer unexpectedly opened the same storage")
        } catch let error as ChainProcessError {
            XCTAssertEqual(error, .storageInUse)
        }
    }

    func testReopenFailsWhenAStagedMaterializedVolumeIsMissing() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let config = try configuration(path: ["Nexus"], storage: directory)
        let store = try testNodeStore(
            databasePath: directory.appendingPathComponent("state.db"),
            nexusGenesisCID: config.nexusGenesisCID,
            chainPath: config.chainPath,
            issuingAuthorityKey: config.processPublicKey
        )
        try await store.stage(
            ChainAdmissionBatch(facts: [.block(ChainBlockFact(
                blockHash: NexusGenesis.expectedBlockHash,
                parentBlockHash: nil,
                blockHeight: 0,
                postStateCID: "state",
                prevStateCID: "previous-state",
                specCID: "spec",
                target: "target",
                nextTarget: "next-target",
                timestamp: 0,
                stateDiff: .empty
            ))]),
            volumeRoots: ["missing-volume"]
        )

        do {
            _ = try await ChainProcess.open(configuration: config)
            XCTFail("reopen unexpectedly accepted a missing materialized volume")
        } catch let error as ChainProcessError {
            XCTAssertEqual(error, .missingMaterializedVolume("missing-volume"))
        }
    }

    func testReopenRejectsASecondNexusGenesisRoot() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let config = try configuration(path: ["Nexus"], storage: directory)
        let store = try testNodeStore(
            databasePath: directory.appendingPathComponent("state.db"),
            nexusGenesisCID: config.nexusGenesisCID,
            chainPath: config.chainPath,
            issuingAuthorityKey: config.processPublicKey
        )
        let broker = try DiskBroker(
            path: directory.appendingPathComponent("volumes.db").path
        )
        let volume = try VolumeImpl<Transaction>(node: signedGenesisAnchorTransaction(
            directory: "Payments",
            childGenesisCID: NexusGenesis.expectedBlockHash
        ))
        try await volume.store(storer: broker)
        let root = volume.rawCID
        func genesis(_ hash: String) -> ChainAdmissionFact {
            .block(ChainBlockFact(
                blockHash: hash,
                parentBlockHash: nil,
                blockHeight: 0,
                postStateCID: root,
                prevStateCID: "previous-state",
                specCID: "spec",
                target: "target",
                nextTarget: "next-target",
                timestamp: 0,
                stateDiff: .empty
            ))
        }
        try await store.stage(
            ChainAdmissionBatch(facts: [
                genesis(NexusGenesis.expectedBlockHash),
                genesis("forged-nexus-genesis"),
            ]),
            volumeRoots: [root]
        )

        do {
            _ = try await ChainProcess.open(configuration: config)
            XCTFail("reopen unexpectedly accepted a second Nexus genesis")
        } catch let error as ChainProcessError {
            XCTAssertEqual(error, .invalidNexusGenesis)
        }
    }

#if DEBUG
    func testBlockedChildProofAcquisitionDoesNotBlockAdmission() async throws {
        let directory = temporaryDirectory()
        let config = try configuration(path: ["Nexus"], storage: directory)
        let blockedCID = "blocked-carrier"
        let source = BlockingContentSource(blockedCID: blockedCID)
        let candidateCID: String

        do {
            let process = try await ChainProcess.open(
                configuration: config
            )
            let genesis = try await process.canonicalTipBlock()
            let candidate = try await BlockBuilder.buildBlock(
                previous: genesis,
                timestamp: 1,
                nonce: 0,
                fetcher: process
            )
            let candidateHeader = try BlockHeader(node: candidate)
            candidateCID = candidateHeader.rawCID
            await source.setEntries(try await blockContentEntries(
                candidateHeader,
                fetcher: process
            ))

            let holder = Task {
                try await process.prepareChildProofs(
                    for: BlockHeader(
                        rawCID: blockedCID,
                        node: nil,
                        encryptionInfo: nil
                    ),
                    directories: ["Payments"],
                    remoteSource: source
                )
            }
            await source.waitForBlockedFetch()

            let admission = Task {
                return try await process.admit(candidateHeader)
            }
            let admissionFinished = expectation(
                description: "admission bypasses blocked proof acquisition"
            )
            Task {
                _ = try? await admission.value
                admissionFinished.fulfill()
            }
            await fulfillment(of: [admissionFinished], timeout: 1)
            let admitted = try await admission.value
            XCTAssertTrue(admitted.decision.isAccepted)
            let statusWhileBlocked = await process.status()
            XCTAssertEqual(statusWhileBlocked.tipCID, candidateCID)

            await source.releaseBlockedFetch()
            try await holder.value
            let status = await process.status()
            XCTAssertEqual(status.tipCID, candidateCID)
            XCTAssertEqual(status.height, 1)
        }

        let store = try testNodeStore(
            databasePath: directory.appendingPathComponent("state.db"),
            nexusGenesisCID: config.nexusGenesisCID,
            chainPath: config.chainPath,
            issuingAuthorityKey: config.processPublicKey
        )
        let staged = try await store.stagedAdmissions()
        XCTAssertEqual(staged.count, 2)
        XCTAssertTrue(staged.contains { admission in
            admission.batch.facts.contains { fact in
                guard case .block(let block) = fact else { return false }
                return block.blockHash == candidateCID
            }
        })
    }
#endif

    func testCancellationAfterRetentionCompletesDurableStage() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let config = try configuration(path: ["Nexus"], storage: directory)
        let store = try testNodeStore(
            databasePath: directory.appendingPathComponent("state.db"),
            nexusGenesisCID: config.nexusGenesisCID,
            chainPath: config.chainPath,
            issuingAuthorityKey: config.processPublicKey
        )
        let broker = try DiskBroker(
            path: directory.appendingPathComponent("volumes.db").path,
            evictUnpinnedGraceSeconds: 0
        )
        let admissionStorage = NodeAdmissionStorage(
            storage: broker
        )
        let transaction = try signedGenesisAnchorTransaction(
            directory: "Payments",
            childGenesisCID: NexusGenesis.expectedBlockHash
        )
        let volume = try VolumeImpl<Transaction>(node: transaction)
        try await volume.store(storer: admissionStorage)
        let root = volume.rawCID
        let batch = ChainAdmissionBatch(facts: [
            .block(ChainBlockFact(
                blockHash: root,
                parentBlockHash: nil,
                blockHeight: 0,
                postStateCID: root,
                prevStateCID: "previous-state",
                specCID: "spec",
                target: "target",
                nextTarget: "next-target",
                timestamp: 0,
                stateDiff: .empty
            )),
        ])
        let retained = TestLatch()
        let continueStage = TestLatch()
        let task = Task {
            try await ChainProcess.persist(
                batch,
                admissionStorage: admissionStorage,
                store: store,
                broker: broker,
                retentionScope: "cancellation-test",
                pendingChildProofRoutes: [],
                pendingChildProofCapacity: 1,
                afterRetainingRoots: {
                    await retained.signal()
                    await continueStage.wait()
                }
            )
        }

        await retained.wait()
        task.cancel()
        await continueStage.signal()
        try await task.value

        let staged = try await store.stagedAdmissions()
        XCTAssertEqual(staged.count, 1)
        XCTAssertEqual(staged.first?.volumeRoots, [root])
        let retainedRoots = try await broker.retainedRoots(
            scope: "cancellation-test"
        )
        XCTAssertEqual(retainedRoots, [root])
        let evicted = try await broker.evictUnpinned()
        XCTAssertEqual(evicted, 0)
        let stored = await broker.fetchVolumeLocal(root: root)
        XCTAssertNotNil(stored)
    }

    func testFailedStageLeavesSafeRetainedOrphanUntilStartupReconciliation()
        async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let config = try configuration(path: ["Nexus"], storage: directory)
        let store = try testNodeStore(
            databasePath: directory.appendingPathComponent("state.db"),
            nexusGenesisCID: config.nexusGenesisCID,
            chainPath: config.chainPath,
            issuingAuthorityKey: config.processPublicKey
        )
        let broker = try DiskBroker(
            path: directory.appendingPathComponent("volumes.db").path,
            evictUnpinnedGraceSeconds: 0
        )
        let admissionStorage = NodeAdmissionStorage(
            storage: broker
        )
        func batch(for root: String) -> ChainAdmissionBatch {
            ChainAdmissionBatch(facts: [
                .block(ChainBlockFact(
                    blockHash: root,
                    parentBlockHash: nil,
                    blockHeight: 0,
                    postStateCID: root,
                    prevStateCID: "previous-state",
                    specCID: "spec",
                    target: "target",
                    nextTarget: "next-target",
                    timestamp: 0,
                    stateDiff: .empty
                )),
            ])
        }
        let durableTransaction = try signedGenesisAnchorTransaction(
            directory: "Durable",
            childGenesisCID: NexusGenesis.expectedBlockHash
        )
        let durableVolume = try VolumeImpl<Transaction>(node: durableTransaction)
        try await durableVolume.store(storer: admissionStorage)
        let durableRoot = durableVolume.rawCID
        try await ChainProcess.persist(
            batch(for: durableRoot),
            admissionStorage: admissionStorage,
            store: store,
            broker: broker,
            retentionScope: "failed-stage-test",
            pendingChildProofRoutes: [],
            pendingChildProofCapacity: 1
        )

        let transaction = try signedGenesisAnchorTransaction(
            directory: "Failed",
            childGenesisCID: NexusGenesis.expectedBlockHash
        )
        let volume = try VolumeImpl<Transaction>(node: transaction)
        try await volume.store(storer: admissionStorage)
        let root = volume.rawCID

        do {
            try await ChainProcess.persist(
                batch(for: root),
                admissionStorage: admissionStorage,
                store: store,
                broker: broker,
                retentionScope: "failed-stage-test",
                pendingChildProofRoutes: [PendingChildProofRoute(
                    carrierCID: "not-in-batch",
                    directory: "Payments"
                )],
                pendingChildProofCapacity: 1
            )
            XCTFail("invalid staging route unexpectedly succeeded")
        } catch let error as NodeStoreError {
            guard case .invalidConfiguration = error else {
                return XCTFail("expected invalid staging route, got \(error)")
            }
        } catch {
            XCTFail("expected invalid staging route, got \(error)")
        }

        let staged = try await store.stagedAdmissions()
        XCTAssertEqual(staged.count, 1)
        XCTAssertEqual(staged.first?.volumeRoots, [durableRoot])
        let retainedRoots = try await broker.retainedRoots(scope: "failed-stage-test")
        XCTAssertEqual(retainedRoots, [durableRoot, root].sorted())
        let evicted = try await broker.evictUnpinned()
        XCTAssertEqual(evicted, 0)
        let stored = await broker.fetchVolumeLocal(root: root)
        XCTAssertNotNil(stored)
        let durableStored = await broker.fetchVolumeLocal(root: durableRoot)
        XCTAssertNotNil(durableStored)
    }

    func testReopenDropsRetainedRootWithoutStagedAdmission() async throws {
        let directory = temporaryDirectory()
        let config = try configuration(path: ["Nexus"], storage: directory)
        var process: ChainProcess? = try await ChainProcess.open(
            configuration: config
        )
        process = nil

        let broker = try DiskBroker(
            path: directory.appendingPathComponent("volumes.db").path,
            evictUnpinnedGraceSeconds: 0
        )
        let scope = [config.nexusGenesisCID, config.address.key].joined(separator: ":")
        let durableRoots = try await broker.retainedRoots(scope: scope)
        let orphan = try VolumeImpl<Transaction>(node: signedGenesisAnchorTransaction(
            directory: "Orphan",
            childGenesisCID: NexusGenesis.expectedBlockHash
        ))
        try await orphan.store(storer: broker)
        let orphanRoot = orphan.rawCID
        try await broker.mergeRetainedRoots(scope: scope, roots: [orphanRoot])
        let retainedBeforeReopen = try await broker.retainedRoots(scope: scope)
        XCTAssertEqual(
            retainedBeforeReopen,
            Array(Set(durableRoots + [orphanRoot])).sorted()
        )

        process = try await ChainProcess.open(configuration: config)
        let status = await process!.status()
        let retainedAfterReopen = try await broker.retainedRoots(scope: scope)
        let evicted = try await broker.evictUnpinned()
        let orphanStored = await broker.fetchVolumeLocal(root: orphanRoot)
        XCTAssertEqual(status.tipCID, NexusGenesis.expectedBlockHash)
        XCTAssertEqual(retainedAfterReopen, durableRoots)
        XCTAssertGreaterThanOrEqual(evicted, 1)
        XCTAssertNil(orphanStored)
    }


    func testPreparedProofRetryDoesNotRefetchOrEvictPendingCarriers() async throws {
        let directory = temporaryDirectory()
        let config = try configuration(path: ["Nexus"], storage: directory)
        var process: ChainProcess? = try await ChainProcess.open(configuration: config)
        let genesis = try await process!.canonicalTipBlock()
        let child = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec,
            parentState: genesis.postState,
            timestamp: 1,
            target: UInt256.max,
            fetcher: process!
        )
        let childCID = try BlockHeader(node: child).rawCID
        let authorization = try signedGenesisAnchorTransaction(
            directory: "Payments",
            childGenesisCID: childCID
        )
        try await VolumeImpl<Transaction>(node: authorization).storeRecursively(
            storer: process!
        )
        let carrier = try await BlockBuilder.buildBlock(
            previous: genesis,
            transactions: [authorization],
            children: ["Payments": child],
            timestamp: 2,
            fetcher: process!
        )
        let carrierHeader = try BlockHeader(node: carrier)
        let hop = try await ChildBlockProof.generate(
            rootHeader: carrierHeader,
            childDirectory: "Payments",
            fetcher: process!
        )
        let admitted = try await process!.admit(carrierHeader)
        XCTAssertTrue(admitted.decision.isAccepted)
        process = nil

        var store: NodeStore? = try testNodeStore(
            databasePath: directory.appendingPathComponent("state.db"),
            nexusGenesisCID: config.nexusGenesisCID,
            chainPath: config.chainPath,
            issuingAuthorityKey: config.processPublicKey
        )
        try await store!.persistPendingChildProofRoutes(
            carrierCID: carrierHeader.rawCID,
            directories: ["Payments"],
            capacity: 16
        )
        try await store!.persistPreparedChildProofs(
            carrierCID: carrierHeader.rawCID,
            proofs: [try PreparedChildProof(
                directory: "Payments",
                childCID: childCID,
                isChildGenesis: true,
                proof: hop
            )],
            capacity: 16
        )
        store = nil

        let remote = BatchRecordingContentSource(entries: [:])
        process = try await ChainProcess.open(
            configuration: config
        )
        let retriedDirectories = try await process!.retryPendingChildProofs(
            carrierCID: carrierHeader.rawCID
        )
        XCTAssertEqual(retriedDirectories, ["Payments"])
        let requestsAfterRecovery = await remote.requests()
        let pendingAfterRecovery = try await process!
            .pendingChildProofCarrierCIDs()
        XCTAssertTrue(requestsAfterRecovery.isEmpty)
        XCTAssertTrue(pendingAfterRecovery.isEmpty)

        for index in 0..<16 {
            try await process!.prepareChildProofs(
                for: BlockHeader(
                    rawCID: "missing-\(index)",
                    node: nil,
                    encryptionInfo: nil
                ),
                directories: ["Missing"]
            )
        }
        let requestsBeforePreparedRetry = await remote.requests()
        let pendingBeforePreparedRetry = try await process!
            .pendingChildProofCarrierCIDs()
        try await process!.prepareChildProofs(
            for: BlockHeader(
                rawCID: carrierHeader.rawCID,
                node: nil,
                encryptionInfo: nil
            ),
            directories: ["Payments"]
        )
        let requestsAfterPreparedRetry = await remote.requests()
        let pendingAfterPreparedRetry = try await process!
            .pendingChildProofCarrierCIDs()
        XCTAssertEqual(requestsAfterPreparedRetry, requestsBeforePreparedRetry)
        XCTAssertEqual(pendingAfterPreparedRetry, pendingBeforePreparedRetry)
        XCTAssertEqual(pendingAfterPreparedRetry.count, 16)
        let recovered = try await process!.durableDirectChildProofs(
            carrierCID: carrierHeader.rawCID,
            rootCID: carrierHeader.rawCID
        )
        XCTAssertEqual(recovered.map(\.directory), ["Payments"])
        XCTAssertEqual(
            recovered.map(\.childCID),
            [try BlockHeader(node: child).rawCID]
        )
        XCTAssertEqual(recovered.first?.proof.rootCID, carrierHeader.rawCID)
    }

    func testPreparedProofSurvivesCachePressureDuringBlockedRetry() async throws {
        let directory = temporaryDirectory()
        let config = try configuration(path: ["Nexus"], storage: directory)
        _ = try await ChainProcess.open(configuration: config)

        let source = ChainProcessTestContentStore()
        try await LatticeState.emptyHeader.storeRecursively(storer: source)
        let child = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec,
            parentState: LatticeState.emptyHeader,
            timestamp: 1,
            target: UInt256.max,
            fetcher: source
        )
        let carrier = try await BlockBuilder.buildGenesis(
            spec: NexusGenesis.spec,
            children: ["Prepared": child],
            timestamp: 2,
            target: UInt256.max,
            fetcher: source
        )
        let carrierHeader = try BlockHeader(node: carrier)
        try await carrierHeader.storeRecursively(storer: source as any Storer)
        let hop = try await ChildBlockProof.generate(
            rootHeader: carrierHeader,
            childDirectory: "Prepared",
            fetcher: source
        )

        var store: NodeStore? = try testNodeStore(
            databasePath: directory.appendingPathComponent("state.db"),
            nexusGenesisCID: config.nexusGenesisCID,
            chainPath: config.chainPath,
            issuingAuthorityKey: config.processPublicKey
        )
        try await store!.persistPendingChildProofRoutes(
            carrierCID: carrierHeader.rawCID,
            directories: ["Prepared", "Waiting"],
            capacity: 16
        )
        try await store!.persistPreparedChildProofs(
            carrierCID: carrierHeader.rawCID,
            proofs: [try PreparedChildProof(
                directory: "Prepared",
                childCID: try BlockHeader(node: child).rawCID,
                isChildGenesis: true,
                proof: hop
            )],
            capacity: 16
        )
        store = nil

        let remote = BlockingContentSource(blockedCID: carrierHeader.rawCID)
        await remote.setEntries(await source.allEntries())
        let liveProcess = try await ChainProcess.open(
            configuration: config
        )

        var evictionCarriers: [Block] = []
        for index in 0..<16 {
            let evictionCarrier = try await BlockBuilder.buildGenesis(
                spec: NexusGenesis.spec,
                children: ["Evict": child],
                timestamp: Int64(index + 10),
                target: UInt256.max,
                fetcher: source
            )
            try await BlockHeader(node: evictionCarrier).storeRecursively(
                storer: source as any Storer
            )
            evictionCarriers.append(evictionCarrier)
            try await BlockHeader(node: evictionCarrier).storeBlock(
                fetcher: source,
                storer: liveProcess
            )
        }

        let retry = Task {
            try await liveProcess.retryPendingChildProofs(
                carrierCID: carrierHeader.rawCID,
                remoteSource: remote
            )
        }
        await remote.waitForBlockedFetch()
        for evictionCarrier in evictionCarriers {
            _ = try await liveProcess.prepareChildProofs(
                for: evictionCarrier,
                capacity: 16
            )
        }
        await remote.releaseBlockedFetch()

        let completed = try await retry.value
        let pending = try await liveProcess.pendingChildProofCarrierCIDs()
        let issued = try await liveProcess.issuedChildEvidenceSummaries(
            directory: "Prepared",
            afterOrdinal: 0,
            throughOrdinal: UInt64(Int64.max),
            limit: 1
        )
        let inspection = try testNodeStore(
            databasePath: directory.appendingPathComponent("state.db"),
            nexusGenesisCID: config.nexusGenesisCID,
            chainPath: config.chainPath,
            issuingAuthorityKey: config.processPublicKey
        )
        let prepared = try await inspection.preparedChildProofs(
            carrierCID: carrierHeader.rawCID
        )
        XCTAssertEqual(completed, ["Waiting"])
        XCTAssertEqual(pending, [carrierHeader.rawCID])
        XCTAssertTrue(issued.isEmpty)
        XCTAssertEqual(prepared.map(\.directory), ["Prepared"])
    }

    func testRestartRetriesPendingProofForNonTipCarrier() async throws {
        let source = ChainProcessTestContentStore()
        let remote = ChainProcessTestContentStore()
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let config = try configuration(path: ["Nexus"], storage: directory)
        var live: ChainProcess? = try await ChainProcess.open(
            configuration: config
        )
        let genesis = try await live!.canonicalTipBlock()
        let child = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec,
            parentState: genesis.postState,
            timestamp: 1,
            target: UInt256.max,
            fetcher: live!
        )
        let childHeader = try BlockHeader(node: child)
        let authorization = try signedGenesisAnchorTransaction(
            directory: "Leaf",
            childGenesisCID: childHeader.rawCID
        )
        try await VolumeImpl<Transaction>(node: authorization).storeRecursively(
            storer: live!
        )
        let carrier = try await BlockBuilder.buildBlock(
            previous: genesis,
            transactions: [authorization],
            children: ["Leaf": child],
            timestamp: 2,
            fetcher: live!
        )
        let carrierHeader = try BlockHeader(node: carrier)
        let carrierOutcome = try await live!.admit(carrierHeader)
        XCTAssertTrue(carrierOutcome.decision.isAccepted)
        let unminedExtension = try await BlockBuilder.buildBlock(
            previous: carrier,
            timestamp: 3,
            fetcher: live!
        )
        let extensionBlock = try XCTUnwrap(BlockBuilder.mine(
            block: unminedExtension,
            target: unminedExtension.target
        ))
        let extensionOutcome = try await live!.admit(
            try BlockHeader(node: extensionBlock)
        )
        XCTAssertTrue(extensionOutcome.decision.isAccepted)
        try await carrierHeader.storeBlock(
            fetcher: live!,
            storer: source
        )
        try await childHeader.storeBlock(
            fetcher: live!,
            storer: source
        )
        live = nil

        var store: NodeStore? = try testNodeStore(
            databasePath: directory.appendingPathComponent("state.db"),
            nexusGenesisCID: config.nexusGenesisCID,
            chainPath: config.chainPath,
            issuingAuthorityKey: config.processPublicKey
        )
        try await store!.persistPendingChildProofRoutes(
            carrierCID: carrierHeader.rawCID,
            directories: ["Leaf"],
            capacity: 16
        )
        store = nil

        let process = try await ChainProcess.open(
            configuration: config
        )
        let status = await process.status()
        XCTAssertNotEqual(status.tipCID, carrierHeader.rawCID)
        let pendingBefore = try await process.pendingChildProofCarrierCIDs()
        XCTAssertEqual(pendingBefore, [carrierHeader.rawCID])

        await remote.store(entries: await source.allEntries())
        let retriedDirectories = try await process.retryPendingChildProofs(
            carrierCID: carrierHeader.rawCID,
            remoteSource: remote
        )
        XCTAssertEqual(retriedDirectories, ["Leaf"])
        let pendingAfter = try await process.pendingChildProofCarrierCIDs()
        XCTAssertTrue(pendingAfter.isEmpty)
        let durableProofs = try await process.durableDirectChildProofs(
            carrierCID: carrierHeader.rawCID,
            rootCID: carrierHeader.rawCID
        )
        let durable = try XCTUnwrap(durableProofs.first)
        XCTAssertEqual(durable.directory, "Leaf")
        XCTAssertEqual(durable.childCID, childHeader.rawCID)
    }

    private func configuration(path: [String], storage: URL) throws -> NodeConfiguration {
        let parentKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 2, count: 32)
        )
        let parentEndpoint = path.count == 1 ? nil : ParentEndpoint(
            publicKey: try PeerKey(
                rawRepresentation: parentKey.publicKey.rawRepresentation
            ).hex,
            host: "127.0.0.1",
            port: 4001
        )
        return try NodeConfiguration(
            chainPath: path,
            storagePath: storage,
            privateKeyHex: String(repeating: "01", count: 32),
            parentEndpoint: parentEndpoint
        )
    }

    private struct ChildBootstrapFixture {
        let configuration: NodeConfiguration
        let seed: ChildGenesisSeed
        let childHeader: BlockHeader
        let rootCID: String
        let proof: ChildBlockProof
        let package: AuthenticatedChildPackage
        let source: ChainProcessTestContentStore
    }

    private func childBootstrapFixture() async throws -> ChildBootstrapFixture {
        let configuration = try configuration(
            path: ["Nexus", "Payments"],
            storage: temporaryDirectory()
        )
        let source = ChainProcessTestContentStore()
        try await LatticeState.emptyHeader.storeRecursively(storer: source)
        // A self-contained child genesis the process rebuilds from `seed` and
        // self-admits (activateSeededChildGenesis). The genesis is never carried;
        // `package`/`proof` below only exercise the block-1 carrier-proof plumbing.
        let seed = ChildGenesisSeed(
            spec: NexusGenesis.spec, premineTo: nil, timestamp: 1
        )
        let child = try await ChildGenesisBuilder.build(
            seed: seed,
            chainPath: ["Nexus", "Payments"],
            fetcher: source
        )
        let childHeader = try BlockHeader(node: child)
        let unminedRoot = try await BlockBuilder.buildGenesis(
            spec: NexusGenesis.spec,
            children: ["Payments": child],
            timestamp: 2,
            target: UInt256.max,
            fetcher: source
        )
        let root = try XCTUnwrap(BlockBuilder.mine(
            block: unminedRoot,
            target: min(unminedRoot.target, child.target)
        ))
        let rootHeader = try BlockHeader(node: root)
        try await rootHeader.storeRecursively(storer: source as any Storer)
        let proof = try await ChildBlockProof.generate(
            rootHeader: rootHeader,
            childDirectory: "Payments",
            fetcher: source
        )
        let package = AuthenticatedChildPackage(
            package: ChildValidationPackage(
                proof: proof,
                parentGenesisLink: try decode(ParentGenesisLink.self, json: """
                    {"parentPath":["Nexus"],"directory":"Payments","childGenesisCID":"\(childHeader.rawCID)","parentStateCID":"\(child.parentState.rawCID)"}
                    """)
            )
        )
        return ChildBootstrapFixture(
            configuration: configuration,
            seed: seed,
            childHeader: childHeader,
            rootCID: rootHeader.rawCID,
            proof: proof,
            package: package,
            source: source
        )
    }

    private func contribution(id: String, work: UInt64) -> VerifiedWorkContribution {
        let json = Data(
            "{\"id\":\"\(id)\",\"work\":\"0x\(String(work, radix: 16))\"}"
                .utf8
        )
        return try! JSONDecoder().decode(VerifiedWorkContribution.self, from: json)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-chain-process-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func decode<T: Decodable>(_ type: T.Type, json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func blockContentEntries(
        _ header: BlockHeader,
        fetcher: any Fetcher
    ) async throws -> [String: Data] {
        let collector = ChainProcessTestContentStore()
        try await header.storeBlock(fetcher: fetcher, storer: collector)
        return await collector.allEntries()
    }
}

private func signedGenesisAnchorTransaction(
    directory: String,
    childGenesisCID: String,
    chainPath: [String] = ["Nexus"]
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
        chainPath: chainPath
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

private actor ChainProcessTestContentStore: ContentSource, Fetcher, Storer, VolumeStorer {
    private var entries: [String: Data] = [:]

    func fetch(rawCid: String) throws -> Data {
        guard let data = entries[rawCid] else { throw FetcherError.notFound(rawCid) }
        return data
    }

    func store(entries: [String: Data]) {
        self.entries.merge(entries) { existing, _ in existing }
    }

    func store(volume: SerializedVolume) {
        entries.merge(volume.entries) { existing, _ in existing }
    }

    func fetch(_ cids: Set<String>) -> [String: Data] {
        entries.filter { cids.contains($0.key) }
    }

    func allEntries() -> [String: Data] {
        entries
    }
}

private actor BatchRecordingContentSource: ContentSource {
    private let entries: [String: Data]
    private var recordedRequests: [Set<String>] = []

    init(entries: [String: Data]) {
        self.entries = entries
    }

    func fetch(_ cids: Set<String>) -> [String: Data] {
        recordedRequests.append(cids)
        return entries.filter { cids.contains($0.key) }
    }

    func requests() -> [Set<String>] {
        recordedRequests
    }
}

private actor TestLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        guard !isOpen else { return }
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
    private var blockedFetchStarted = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockedFetchWaiters: [Waiter] = []

    init(blockedCID: String) {
        self.blockedCID = blockedCID
    }

    func setEntries(_ entries: [String: Data]) {
        self.entries = entries
    }

    func fetch(_ cids: Set<String>) async -> [String: Data] {
        let found = entries.filter { cids.contains($0.key) }
        guard cids.contains(blockedCID) else { return found }

        blockedFetchStarted = true
        let pendingStarts = startWaiters
        startWaiters.removeAll()
        for waiter in pendingStarts { waiter.resume() }
        guard !released else { return found }

        return await withCheckedContinuation { continuation in
            blockedFetchWaiters.append(Waiter(
                entries: found,
                continuation: continuation
            ))
        }
    }

    func waitForBlockedFetch() async {
        guard !blockedFetchStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseBlockedFetch() {
        released = true
        let pending = blockedFetchWaiters
        blockedFetchWaiters.removeAll()
        for waiter in pending {
            waiter.continuation.resume(returning: waiter.entries)
        }
    }
}
