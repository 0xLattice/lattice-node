import Crypto
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Ivy
import Lattice
import Tally
import UInt256
import VolumeBroker
import XCTest
import cashew
@testable import LatticeNode

private func awaitedUnwrap<T>(
    _ value: T?,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}

private actor ContentRequestRecorder {
    private var values: [String] = []
    func append(root: String) { values.append(root) }
    func snapshot() -> [String] { values }
}

/// An overlay peer serving its child-evidence index, and the proofs it
/// names, as ordinary Volumes.
private actor EvidenceIndexPeer: IvyContentSource {
    private let broker: MemoryBroker
    private var served: [String] = []

    init(broker: MemoryBroker) { self.broker = broker }

    func content(
        rootCID: String,
        cids: [String],
        maxDataBytes: Int
    ) async -> [ContentEntry] {
        []
    }

    func volume(rootCID: String, maxDataBytes: Int) async -> [ContentEntry] {
        guard let volume = await broker.fetchVolumeLocal(root: rootCID) else {
            return []
        }
        served.append(rootCID)
        var remaining = maxDataBytes
        var entries: [ContentEntry] = []
        for (cid, data) in volume.entries.sorted(by: { $0.key < $1.key }) {
            guard data.count <= remaining else { return [] }
            remaining -= data.count
            entries.append(ContentEntry(cid: cid, data: data))
        }
        return entries
    }

    func servedRoots() -> [String] { served }
}

extension NodeNetworkRuntime {
    fileprivate func childEvidenceRootPeers() -> Set<PeerKey> {
        Set(overlayState.overlayRecords.records.filter {
            $0.value.evidenceRoot != nil
        }.keys)
    }
}

final class NetworkTrustEvidenceTests: NetworkTrustTestCase {
    func testChildValidationPackageEnvelopeRoundTripsAndRejectsTrailingBytes() throws {
        let package = ChildValidationPackage(
            proof: proof()
        )
        let encoded = try ChildValidationPackageEnvelope(package).encode()
        let decoded = try ChildValidationPackageEnvelope.decode(encoded)
            .makeValidationPackage()

        XCTAssertEqual(try decoded.proof.serialize(), try package.proof.serialize())
        XCTAssertNil(decoded.parentGenesisLink)
        XCTAssertNil(decoded.parentStateContinuityLink)

        var trailing = encoded
        trailing.append(0)
        XCTAssertThrowsError(try ChildValidationPackageEnvelope.decode(trailing))
        XCTAssertThrowsError(try ChildValidationPackageEnvelope.decode(
            encoded,
            maximumEncodedSize: encoded.count - 1
        )) { error in
            XCTAssertEqual(
                error as? ChildValidationPackageEnvelopeError,
                .oversized
            )
        }

        XCTAssertThrowsError(try ChildValidationPackageEnvelope.decode(
            Data(repeating: 0, count: ChildValidationPackageEnvelope.maximumEncodedSize + 1)
        )) { error in
            XCTAssertEqual(error as? ChildValidationPackageEnvelopeError, .oversized)
        }
    }

    /// Establishes: NODE-STORAGE-001.a
    func testAnObjectOutsideTheSessionRootIsRequestedAsItsOwnRootOnce() async throws {
        let recorder = ContentRequestRecorder()
        let servingKey = peerKey(signingKey(46)).hex
        let rootHeader = try HeaderImpl<PublicKey>(node: PublicKey(key: "session-root"))
        let nestedHeader = try HeaderImpl<PublicKey>(node: PublicKey(key: "own-root"))
        let rootCID = rootHeader.rawCID
        let nestedCID = nestedHeader.rawCID
        let volumes = [
            rootCID: [rootCID: try rootHeader.mapToData()],
            nestedCID: [nestedCID: try nestedHeader.mapToData()],
        ]
        let source = IvyRootContentSource { root in
            await recorder.append(root: root)
            return AttributedVolumeResponse(
                rootCID: root,
                entries: volumes[root] ?? [:],
                servedBy: PeerID(publicKey: servingKey)
            )
        }

        let result = await source.withRootTracing(rootCID) { session in
            _ = await session.fetch([rootCID])
            let first = await session.fetch([nestedCID])
            let again = await session.fetch([nestedCID])
            return (first, again)
        }

        XCTAssertEqual(result.value.0, [nestedCID: volumes[nestedCID]![nestedCID]!])
        XCTAssertEqual(result.value.1, result.value.0)
        let requests = await recorder.snapshot()
        XCTAssertEqual(requests, [rootCID, nestedCID])
    }

    /// Establishes: NODE-STORAGE-001.a
    func testRootScopedContentFetchesCompleteVolumesAndKeepsAttribution() async {
        let recorder = ContentRequestRecorder()
        let servingKey = peerKey(signingKey(45)).hex
        let rootHeader = try! HeaderImpl<PublicKey>(
            node: PublicKey(key: "root-volume")
        )
        let leftHeader = try! HeaderImpl<PublicKey>(
            node: PublicKey(key: "left-volume")
        )
        let rightHeader = try! HeaderImpl<PublicKey>(
            node: PublicKey(key: "right-volume")
        )
        let rootCID = rootHeader.rawCID
        let leftCID = leftHeader.rawCID
        let rightCID = rightHeader.rawCID
        let entries = [
            rootCID: try! rootHeader.mapToData(),
            leftCID: try! leftHeader.mapToData(),
            rightCID: try! rightHeader.mapToData(),
        ]
        let source = IvyRootContentSource { root in
            await recorder.append(root: root)
            return AttributedVolumeResponse(
                rootCID: root,
                entries: entries,
                servedBy: PeerID(publicKey: servingKey)
            )
        }

        let result = await source.withRootTracing(rootCID) { session in
            let root = await session.fetch([rootCID])
            let descendants = await session.fetch([leftCID, rightCID])
            return (root, descendants)
        }

        XCTAssertEqual(result.value.0, [rootCID: entries[rootCID]!])
        XCTAssertEqual(result.value.1, [
            leftCID: entries[leftCID]!,
            rightCID: entries[rightCID]!,
        ])
        XCTAssertEqual(result.attribution.servedByPublicKeys, [servingKey])
        XCTAssertTrue(result.attribution.allResponsesComplete)
        let requests = await recorder.snapshot()
        XCTAssertEqual(requests, [rootCID])
    }

    func testRootScopedContentBoundsAllRetainedMembers() async {
        let root = try! HeaderImpl<PublicKey>(node: PublicKey(key: "root"))
        let padding = try! HeaderImpl<PublicKey>(node: PublicKey(key: "padding"))
        let nested = try! HeaderImpl<PublicKey>(node: PublicKey(key: "nested"))
        let rootEntries = [
            root.rawCID: try! root.mapToData(),
            padding.rawCID: try! padding.mapToData(),
        ]
        let nestedEntries = [nested.rawCID: try! nested.mapToData()]
        let source = IvyRootContentSource(
            maximumMembers: rootEntries.count,
            maximumStorageBytes: .max
        ) { requested in
            AttributedVolumeResponse(
                rootCID: requested,
                entries: requested == root.rawCID ? rootEntries : nestedEntries,
                servedBy: nil
            )
        }

        let result = await source.withRootTracing(root.rawCID) { session in
            let rootData = await session.fetch([root.rawCID])
            let nestedData = await session.fetch([nested.rawCID])
            return (rootData, nestedData)
        }

        XCTAssertEqual(result.value.0, [root.rawCID: rootEntries[root.rawCID]!])
        XCTAssertTrue(result.value.1.isEmpty)
        XCTAssertFalse(result.attribution.allResponsesComplete)
    }

    func testRootScopedContentBoundsAllRetainedStorage() async {
        let root = try! HeaderImpl<PublicKey>(node: PublicKey(key: "root"))
        let nested = try! HeaderImpl<PublicKey>(node: PublicKey(key: "nested"))
        let rootData = try! root.mapToData()
        let nestedData = try! nested.mapToData()
        let rootStorageBytes = root.rawCID.utf8.count + rootData.count + 6
        let source = IvyRootContentSource(
            maximumMembers: .max,
            maximumStorageBytes: rootStorageBytes
        ) { requested in
            AttributedVolumeResponse(
                rootCID: requested,
                entries: requested == root.rawCID
                    ? [root.rawCID: rootData]
                    : [nested.rawCID: nestedData],
                servedBy: nil
            )
        }

        let result = await source.withRootTracing(root.rawCID) { session in
            let rootResult = await session.fetch([root.rawCID])
            let nestedResult = await session.fetch([nested.rawCID])
            return (rootResult, nestedResult)
        }

        XCTAssertEqual(result.value.0, [root.rawCID: rootData])
        XCTAssertTrue(result.value.1.isEmpty)
        XCTAssertFalse(result.attribution.allResponsesComplete)
    }

    func testRootScopedContentAttributesLocalCapacityWithoutBlamingPeer() async {
        let root = try! HeaderImpl<PublicKey>(node: PublicKey(key: "root"))
        let source = IvyRootContentSource { _ in .localCapacityUnavailable }

        let result = await source.withRootTracing(root.rawCID) { session in
            await session.fetch([root.rawCID])
        }

        XCTAssertTrue(result.value.isEmpty)
        XCTAssertFalse(result.attribution.allResponsesComplete)
        XCTAssertTrue(result.attribution.localCapacityUnavailable)
        XCTAssertFalse(result.attribution.contentUnavailable)
        XCTAssertTrue(result.attribution.servedByPublicKeys.isEmpty)
        XCTAssertNil(result.attribution.soleRemoteSupplierPublicKey)
    }

    func testRootScopedContentRecordsTransientUnavailableVolume() async {
        let root = try! HeaderImpl<PublicKey>(node: PublicKey(key: "root"))
        let missing = try! HeaderImpl<PublicKey>(node: PublicKey(key: "missing"))
        let rootData = try! root.mapToData()
        let source = IvyRootContentSource { requested in
            requested == root.rawCID
                ? AttributedVolumeResponse(
                    rootCID: root.rawCID,
                    entries: [root.rawCID: rootData],
                    servedBy: nil
                )
                : .empty
        }

        let result = await source.withRootTracing(root.rawCID) { session in
            _ = await session.fetch([root.rawCID])
            return await session.fetch([missing.rawCID])
        }

        XCTAssertTrue(result.value.isEmpty)
        XCTAssertFalse(result.attribution.allResponsesComplete)
        XCTAssertFalse(result.attribution.localCapacityUnavailable)
        XCTAssertTrue(result.attribution.contentUnavailable)
    }

    /// Establishes: NODE-STORAGE-001.c
    func testRootScopedContentRefusesAVolumeWithOneBadMemberEntry() async throws {
        let root = try HeaderImpl<PublicKey>(node: PublicKey(key: "root"))
        let member = try HeaderImpl<PublicKey>(node: PublicKey(key: "member"))
        let rootBytes = try root.mapToData()
        let supplier = peerKey(signingKey(0x45)).hex
        let source = IvyRootContentSource { requested in
            AttributedVolumeResponse(
                rootCID: requested,
                entries: [requested: rootBytes, member.rawCID: Data([0])],
                servedBy: PeerID(publicKey: supplier)
            )
        }

        let result = await source.withRootTracing(root.rawCID) { session in
            await session.fetch([root.rawCID])
        }

        XCTAssertTrue(result.value.isEmpty, "a valid root entry does not vouch for its members")
        XCTAssertEqual(
            result.attribution.deficientVolumeSuppliers,
            [root.rawCID: [supplier]]
        )
    }

    /// Establishes: NODE-STORAGE-001.c
    func testRootScopedContentAttributesMalformedVolumeToItsSupplier() async {
        let root = try! HeaderImpl<PublicKey>(node: PublicKey(key: "root"))
        let supplier = peerKey(signingKey(0x44)).hex
        let source = IvyRootContentSource { requested in
            AttributedVolumeResponse(
                rootCID: requested,
                entries: [requested: Data([0])],
                servedBy: PeerID(publicKey: supplier)
            )
        }

        let result = await source.withRootTracing(root.rawCID) { session in
            await session.fetch([root.rawCID])
        }

        XCTAssertTrue(result.value.isEmpty)
        XCTAssertEqual(
            result.attribution.deficientVolumeSuppliers,
            [root.rawCID: [supplier]]
        )
    }

    /// Establishes: NODE-STORAGE-001.f
    func testExactPeerSourcePreservesLocalFailuresBeforeAttribution() {
        let expected = PeerID(publicKey: "expected")
        let other = PeerID(publicKey: "other")
        XCTAssertEqual(
            IvyRootContentSource.response(.localCapacityUnavailable, from: expected),
            .localCapacityUnavailable
        )
        let callerBound = AttributedVolumeResponse(
            rootCID: "",
            entries: [:],
            servedBy: nil,
            failure: .callerBoundaryExceeded
        )
        XCTAssertEqual(
            IvyRootContentSource.response(callerBound, from: expected),
            callerBound
        )
        let wrongPeer = AttributedVolumeResponse(
            rootCID: "root",
            entries: ["root": Data([1])],
            servedBy: other
        )
        XCTAssertEqual(
            IvyRootContentSource.response(wrongPeer, from: expected),
            .empty
        )
        let rightPeer = AttributedVolumeResponse(
            rootCID: "root",
            entries: ["root": Data([1])],
            servedBy: expected
        )
        XCTAssertEqual(IvyRootContentSource.response(rightPeer, from: expected), rightPeer)
    }

    func testEvidenceMergeAddsLocallyValidatedGenesisFact() throws {
        let proof = proof()
        let genesis = try genesisLink(
            parentPath: ["Nexus"], directory: "Payments", cid: "child-genesis"
        )
        let proofOnly = AuthenticatedChildPackage(package: ChildValidationPackage(
            proof: proof
        ))
        let genesisOnly = AuthenticatedChildPackage(package: ChildValidationPackage(
            proof: proof,
            parentGenesisLink: genesis
        ))

        let complete = BlockFetcher.mergePackages(proofOnly, genesisOnly)
        XCTAssertEqual(complete?.package.parentGenesisLink, genesis)
    }

    // A parent verdict (genesis/continuity link) is attached only through the
    // gated merge, and the merge is content-bound to the exact proof it was
    // confirmed against. This locks the "authenticated => authorized" boundary:
    // a link may never be grafted onto a different proof, and a conflicting
    // second link never silently overwrites the first. If a future path tries
    // to smuggle a wire-supplied verdict onto a candidate, it fails here.
    func testEvidenceMergeRejectsCrossProofAndConflictingLinks() throws {
        let proofA = proof()
        let proofB = ChildBlockProof(
            rootCID: "different-proof-root",
            directoryPath: ["Payments"],
            entries: []
        )
        let genesis = try genesisLink(
            parentPath: ["Nexus"], directory: "Payments", cid: "child-genesis"
        )
        let otherGenesis = try genesisLink(
            parentPath: ["Nexus"], directory: "Payments", cid: "other-child-genesis"
        )

        // A link confirmed against proofB cannot attach to proofA's candidate.
        let proofOnlyA = AuthenticatedChildPackage(
            package: ChildValidationPackage(proof: proofA)
        )
        let genesisOnB = AuthenticatedChildPackage(
            package: ChildValidationPackage(proof: proofB, parentGenesisLink: genesis)
        )
        XCTAssertNil(BlockFetcher.mergePackages(proofOnlyA, genesisOnB))

        // Conflicting genesis facts for the same proof are rejected outright,
        // never overwritten — a second (attacker) verdict cannot replace the first.
        let genesisA = AuthenticatedChildPackage(
            package: ChildValidationPackage(proof: proofA, parentGenesisLink: genesis)
        )
        let conflictingA = AuthenticatedChildPackage(
            package: ChildValidationPackage(
                proof: proofA, parentGenesisLink: otherGenesis
            )
        )
        XCTAssertNil(BlockFetcher.mergePackages(genesisA, conflictingA))

        // The same verdict on the same proof still merges (idempotent).
        XCTAssertEqual(
            BlockFetcher.mergePackages(genesisA, genesisA)?
                .package.parentGenesisLink,
            genesis
        )
    }

    func testParentEvidenceDoesNotContainChildValidationContent() async throws {
        let child = try await canonicalNetworkBlock()
        let childCID = try BlockHeader(node: child).rawCID
        let envelope = try ChildValidationPackageEnvelope(
            ChildValidationPackage(proof: proof())
        )
        let attachment = try ChildEvidenceVolume(
            envelopeBytes: envelope.encode(),
            childCID: childCID
        )

        XCTAssertEqual(attachment.serialized.entries.count, 1)
        XCTAssertNil(attachment.serialized.entries[childCID])
    }

    /// A cold-synced child block whose proof this node cannot recover
    /// locally resolves `.childProof` through overlay peers' child-evidence
    /// indexes: a peer serving an entry that does not bind its key is blamed
    /// and its root dropped, and an honest peer's proofs (two grinds for the
    /// one block) are then admitted as weighed package seeds.
    func testColdSyncResolvesAChildProofThroughPeerIndexesAndBlamesJunk()
        async throws
    {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-evidence-index-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let overlayPort = NetworkTransportTestPorts.allocate()
        let targetConfiguration = try NodeConfiguration(
            chainPath: ["Nexus", "Middle", "Leaf"],
            storagePath: storage.appendingPathComponent("target"),
            privateKeyHex: String(repeating: "75", count: 32),
            listenPort: overlayPort,
            rpcPort: NetworkTransportTestPorts.allocate()
        )

        let content = InMemoryContentStore()
        try await LatticeState.emptyHeader.storeRecursively(
            storer: content as any Storer
        )
        let leaf = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec,
            parentState: LatticeState.emptyHeader,
            timestamp: 1,
            target: UInt256.max,
            fetcher: content
        )
        let leafHeader = try BlockHeader(node: leaf)
        let leafVolume = try VolumeImpl<Block>(node: leaf)
        try await leafVolume.store(storer: content)
        let storedLeafVolume = await content.volume(root: leafHeader.rawCID)
        let leafSerializedVolume = try XCTUnwrap(storedLeafVolume)
        let middle = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec,
            parentState: LatticeState.emptyHeader,
            children: ["Leaf": leaf],
            timestamp: 2,
            target: UInt256.max,
            fetcher: content
        )
        let middleHeader = try BlockHeader(node: middle)
        let leafHop = try await ChildBlockProof.generate(
            rootHeader: middleHeader,
            childDirectory: "Leaf",
            fetcher: content
        )
        var proofs: [ChildBlockProof] = []
        for timestamp in [Int64(3), Int64(4)] {
            let root = try await BlockBuilder.buildGenesis(
                spec: NexusGenesis.spec,
                children: ["Middle": middle],
                timestamp: timestamp,
                target: UInt256.max,
                fetcher: content
            )
            let rootHeader = try BlockHeader(node: root)
            try await rootHeader.storeRecursively(storer: content as any Storer)
            proofs.append(try await ChildBlockProof.generate(
                rootHeader: rootHeader,
                childDirectory: "Middle",
                fetcher: content
            ).composing(hop: leafHop))
        }
        var edges: [DirectChildEdge] = []
        for proof in proofs {
            let edge = await DirectChildEdge.derive(from: proof)
            edges.append(try XCTUnwrap(edge))
        }
        XCTAssertEqual(Set(edges.compactMap(\.edgeCID)).count, 1)
        XCTAssertEqual(Set(proofs.map(\.rootCID)).count, 2)

        // The honest index holds both grinds; the junk index files one
        // grind's proof under a grind it does not prove.
        let honestBroker = MemoryBroker()
        let junkBroker = MemoryBroker()
        var honestEntries: [ChildEvidenceIndex.Entry] = []
        var attachments: [ChildEvidenceVolume] = []
        for proof in proofs {
            let attachment = try ChildEvidenceVolume(
                envelopeBytes: try ChildValidationPackageEnvelope(
                    ChildValidationPackage(proof: proof)
                ).encode(),
                childCID: leafHeader.rawCID
            )
            try await attachment.store(storer: honestBroker)
            try await attachment.store(storer: junkBroker)
            attachments.append(attachment)
            honestEntries.append(ChildEvidenceIndex.Entry(
                childCID: leafHeader.rawCID,
                rootCID: proof.rootCID,
                attachmentCID: attachment.rawCID
            ))
        }
        let honestRoot = try awaitedUnwrap(try await ChildEvidenceIndex.inserting(
            honestEntries, into: nil, fetcher: honestBroker, storer: honestBroker
        )).root
        let junkRoot = try awaitedUnwrap(try await ChildEvidenceIndex.inserting(
            [ChildEvidenceIndex.Entry(
                childCID: leafHeader.rawCID,
                rootCID: proofs[1].rootCID,
                attachmentCID: attachments[0].rawCID
            )],
            into: nil, fetcher: junkBroker, storer: junkBroker
        )).root

        let runtime = try NodeNetworkRuntime(
            configuration: targetConfiguration,
            planeConfigurations: try NodeNetworkPlaneConfigurations(
                overlay: IvyConfig(
                    signingKey: targetConfiguration.signingKey,
                    listenPort: overlayPort,
                    requestTimeout: .seconds(1),
                    stunServers: [],
                    healthConfig: PeerHealthConfig(enabled: false),
                    mode: .overlay
                )
            )
        )
        let process = try await ChainProcess.open(
            configuration: targetConfiguration
        )
        let roots = NetworkEventRecorder()
        let unavailable = NetworkEventRecorder()
        let eager = NetworkEventRecorder()
        let handlers = ClosureChainInterface(
            admission: { admission in
                if !admission.weighed {
                    await eager.append(admission.header.rawCID)
                }
                guard let rootCID = admission.authenticatedChildPackage?
                    .package.proof.rootCID else {
                    await unavailable.append(admission.header.rawCID)
                    return NodeImportOutcome(
                        decision: .unavailable(.childProof(
                            chainPath: targetConfiguration.chainPath,
                            childCID: admission.header.rawCID
                        )),
                        sameChainPredecessor: nil
                    )
                }
                guard (await admission.contentSource.fetch(
                    Set([admission.header.rawCID])
                ))[admission.header.rawCID] != nil else {
                    throw NetworkTestError.failedPhase("child Volume unavailable")
                }
                await roots.append(rootCID)
                return NodeImportOutcome(
                    decision: .acceptedSide(ChainCommit(
                        tipHash: admission.header.rawCID
                    )),
                    sameChainPredecessor: nil
                )
            }
        )

        func overlayPeer(_ byte: UInt8) -> Ivy {
            Ivy(config: IvyConfig(
                signingKey: signingKey(byte),
                listenPort: 0,
                stunServers: [],
                healthConfig: PeerHealthConfig(enabled: false),
                mode: .overlay
            ))
        }
        let honestPeer = overlayPeer(0x76)
        let honestSource = EvidenceIndexPeer(broker: honestBroker)
        await honestPeer.setContentSource(honestSource)
        let junkPeer = overlayPeer(0x79)
        let junkSource = EvidenceIndexPeer(broker: junkBroker)
        await junkPeer.setContentSource(junkSource)
        let blockAdvertiser = overlayPeer(0x77)
        await blockAdvertiser.setContentSource(
            VolumeSource(one: leafSerializedVolume)
        )
        let target = PeerID(publicKey: targetConfiguration.processPublicKey)
        let targetEndpoint = PeerEndpoint(
            publicKey: targetConfiguration.processPublicKey,
            host: "127.0.0.1",
            port: overlayPort
        )
        let overlayHello = try ChainHello(
            nexusGenesisCID: targetConfiguration.nexusGenesisCID,
            chainPath: targetConfiguration.chainPath
        ).encode()
        /// Pushes `root` until the runtime holds it for `peer`: a push that
        /// lands before the hello is processed is dropped.
        func push(_ root: String, from peer: Ivy, key: PeerKey) async throws {
            for _ in 0..<200 {
                if await runtime.childEvidenceRootPeers().contains(key) { return }
                _ = await peer.sendMessage(
                    to: target,
                    topic: NodeNetworkTopic.childEvidenceRoot,
                    payload: try ChildEvidenceRootMessage(rootCID: root).encoded()
                )
                try await Task.sleep(for: .milliseconds(50))
            }
            throw NetworkTestError.failedPhase("peer root registered")
        }
        do {
            try await runtime.start(process: process, chain: handlers)
            let junkKey = peerKey(signingKey(0x79))
            try await connectAndHello(
                junkPeer, peerID: target, endpoint: targetEndpoint, hello: overlayHello
            )
            try await push(junkRoot, from: junkPeer, key: junkKey)
            try await connectAndHello(
                blockAdvertiser, peerID: target, endpoint: targetEndpoint, hello: overlayHello
            )
            guard case .enqueued = await blockAdvertiser.sendMessage(
                to: target,
                topic: NodeNetworkTopic.blockAnnouncement,
                payload: try BlockAnnouncementMessage(
                    blockCID: leafHeader.rawCID
                ).encoded()
            ) else {
                throw NetworkTestError.failedSend
            }
            try await waitForEventCount(
                1,
                in: unavailable,
                phase: "overlay block before any proof"
            )
            // The junk entry is fetched, fails to bind its grind, and its
            // complete supplier is blamed: its root is dropped.
            for _ in 0..<200 {
                if !(await runtime.childEvidenceRootPeers().contains(junkKey)) { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let junkServed = await junkSource.servedRoots()
            XCTAssertTrue(junkServed.contains(attachments[0].rawCID))
            let junkDropped = await !runtime.childEvidenceRootPeers().contains(junkKey)
            XCTAssertTrue(junkDropped, "the junk peer's root was not dropped")
            let beforeHonest = await roots.snapshot()
            XCTAssertTrue(beforeHonest.isEmpty, "junk was admitted: \(beforeHonest)")

            try await connectAndHello(
                honestPeer, peerID: target, endpoint: targetEndpoint, hello: overlayHello
            )
            try await push(honestRoot, from: honestPeer, key: peerKey(signingKey(0x76)))
            // A block not yet held admits one proof per pass; the other grind
            // arrives by the walk once the block is held and indexed.
            try await waitForEventCount(
                1,
                in: roots,
                phase: "a grind from the honest index"
            )
            let admittedRoots = await roots.snapshot()
            XCTAssertTrue(Set(admittedRoots).isSubset(of: Set(proofs.map(\.rootCID))))
            let honestServed = Set(await honestSource.servedRoots())
            XCTAssertFalse(honestServed.isDisjoint(with: attachments.map(\.rawCID)))
            let eagerAdmissions = await eager.snapshot()
            XCTAssertTrue(
                eagerAdmissions.isEmpty,
                "a proof from a peer index is a network block: weighed, \(eagerAdmissions)"
            )
        } catch {
            await honestPeer.stop()
            await junkPeer.stop()
            await blockAdvertiser.stop()
            await runtime.stop()
            throw error
        }
        await honestPeer.stop()
        await junkPeer.stop()
        await blockAdvertiser.stop()
        await runtime.stop()
    }

    func testExactSourceFanOutIsCappedIndependentOfProviderCount() {
        // An announcement flood cannot force O(N) sequential fetch timeouts before
        // the recovery source: the direct-advertiser fan-out is capped to a small
        // constant regardless of how many advertisers are injected. The genuine
        // supplier stays reachable via the uncapped recovery source.
        func peers(_ n: Int) -> [AuthenticatedPeer] {
            (0..<n).map { authenticatedPeer(signingKey(UInt8($0)), role: .endpoint) }
        }
        let blockCID = "block-under-advertiser-flood"
        let few = NodeNetworkRuntime.boundedOrderedExactPeers(peers(2), blockCID: blockCID)
        let flood = NodeNetworkRuntime.boundedOrderedExactPeers(peers(64), blockCID: blockCID)
        XCTAssertEqual(few.count, 2, "a small provider set is probed in full")
        XCTAssertEqual(flood.count, 8, "a flood is capped, not scaled with N")
        let all = peers(64)
        XCTAssertTrue(flood.allSatisfy { all.contains($0) })
    }

    private func genesisLink(
        parentPath: [String],
        directory: String,
        cid: String,
        parentStateCID: String = testCID("genesis-parent-state")
    ) throws -> ParentGenesisLink {
        struct Wire: Encodable {
            let parentPath: [String]
            let directory: String
            let childGenesisCID: String
            let parentStateCID: String
        }
        return try JSONDecoder().decode(
            ParentGenesisLink.self,
            from: JSONEncoder().encode(Wire(
                parentPath: parentPath,
                directory: directory,
                childGenesisCID: cid,
                parentStateCID: parentStateCID
            ))
        )
    }
}
