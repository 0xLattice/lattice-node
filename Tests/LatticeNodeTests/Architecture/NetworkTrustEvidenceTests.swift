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

private actor ContentRequestRecorder {
    private var values: [String] = []
    func append(root: String) { values.append(root) }
    func snapshot() -> [String] { values }
}

private struct PortableAttachmentTestPayload: Sendable {
    let summary: PortableAttachmentSummary
    let content: [String: Data]
}

private actor PortableAttachmentQueuePeer: IvyDelegate, IvyContentSource {
    private let attachments: [PortableAttachmentTestPayload]
    private let firstAdmissionGate: CandidateBuildGate
    private var servedAttachments = Set<String>()

    init(
        attachments: [PortableAttachmentTestPayload],
        firstAdmissionGate: CandidateBuildGate
    ) {
        self.attachments = attachments.sorted {
            ($0.summary.edgeCID, $0.summary.rootCID)
                < ($1.summary.edgeCID, $1.summary.rootCID)
        }
        self.firstAdmissionGate = firstAdmissionGate
    }

    func content(
        rootCID: String,
        cids: [String],
        maxDataBytes: Int
    ) async -> [ContentEntry] {
        []
    }

    func volume(rootCID: String, maxDataBytes: Int) async -> [ContentEntry] {
        guard let attachment = attachments.first(where: {
            $0.summary.attachmentCID == rootCID
        }) else { return [] }
        if !servedAttachments.contains(rootCID) {
            if servedAttachments.count == 1 {
                while await firstAdmissionGate.enteredCount() == 0 {
                    try? await Task.sleep(for: .milliseconds(1))
                }
            }
            servedAttachments.insert(rootCID)
        }
        var remaining = maxDataBytes
        var entries: [ContentEntry] = []
        for (cid, data) in attachment.content.sorted(by: { $0.key < $1.key }) {
            guard data.count <= remaining else { return [] }
            remaining -= data.count
            entries.append(ContentEntry(cid: cid, data: data))
        }
        return entries
    }

    func servedRoots() -> Set<String> { servedAttachments }
}

private actor ParentRunReportSink {
    private var reports: [ParentRunReport] = []
    func record(_ report: ParentRunReport) { reports.append(report) }
    func received() -> [ParentRunReport] { reports }
}

private actor ChildEvidenceRecorder {
    struct Snapshot: Sendable {
        let helloSessions: [Data]
        let indexEntries: [[IssuedChildEvidenceSummary]]
        let available: [ChildEvidenceAvailableMessage]
    }

    private var nextRequestID: UInt64 = 1
    private var helloSessions: [Data] = []
    private var indexEntries: [[IssuedChildEvidenceSummary]] = []
    private var available: [ChildEvidenceAvailableMessage] = []
    private var runReports: [ParentRunReportMessage] = []

    func record(_ report: ParentRunReportMessage) { runReports.append(report) }
    func runReportsSeen() -> [ParentRunReportMessage] { runReports }
    func nextRunReportRequestID() -> UInt64 { defer { nextRequestID &+= 1 }; return nextRequestID }

    func beginSession(_ sessionID: Data) -> UInt64? {
        guard !helloSessions.contains(sessionID) else { return nil }
        helloSessions.append(sessionID)
        defer { nextRequestID &+= 1 }
        return nextRequestID
    }

    func record(_ response: ChildEvidenceIndexResponseMessage) {
        indexEntries.append(response.entries)
    }

    func record(_ message: ChildEvidenceAvailableMessage) {
        available.append(message)
    }

    func snapshot() -> Snapshot {
        Snapshot(
            helloSessions: helloSessions,
            indexEntries: indexEntries,
            available: available
        )
    }
}

private final class ChildEvidencePeer: IvyDelegate, Sendable {
    private let recorder: ChildEvidenceRecorder
    private let hello: Data
    private let childPath: [String]
    /// Committers to ask the parent to re-serve once the evidence index has
    /// answered (i.e. once this child is evidence-ready on the parent).
    private let runReportCarriers: [String]

    init(
        recorder: ChildEvidenceRecorder,
        hello: Data,
        childPath: [String],
        runReportCarriers: [String] = []
    ) {
        self.recorder = recorder
        self.hello = hello
        self.childPath = childPath
        self.runReportCarriers = runReportCarriers
    }

    func ivy(
        _ ivy: Ivy,
        didReceiveMessage message: PeerMessage,
        from peer: AuthenticatedPeer
    ) async {
        switch message.topic {
        case NodeNetworkTopic.hierarchyHello:
            guard let requestID = await recorder.beginSession(peer.sessionID),
                  case .enqueued = await ivy.sendMessage(
                    to: peer,
                    topic: NodeNetworkTopic.hierarchyHello,
                    payload: hello
                  ),
                  let payload = try? ChildEvidenceIndexRequestMessage(
                    requestID: requestID,
                    childPath: childPath,
                    sourceID: nil,
                    cursor: 0,
                    through: nil
                  ).encoded()
            else { return }
            _ = await ivy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.childEvidenceIndexRequest,
                payload: payload
            )
        case NodeNetworkTopic.childEvidenceIndexResponse:
            guard let response = try? ChildEvidenceIndexResponseMessage.decoded(
                message.payload
            ) else { return }
            await recorder.record(response)
            guard !runReportCarriers.isEmpty,
                  let payload = try? ParentRunReportRequestMessage(
                    requestID: await recorder.nextRunReportRequestID(),
                    carrierCIDs: runReportCarriers
                  ).encoded() else { return }
            _ = await ivy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.parentRunReportRequest,
                payload: payload
            )
        case NodeNetworkTopic.parentRunReport:
            guard let report = try? ParentRunReportMessage.decoded(message.payload)
            else { return }
            await recorder.record(report)
        case NodeNetworkTopic.childEvidenceAvailable:
            guard let available = try? ChildEvidenceAvailableMessage.decoded(
                message.payload
            ) else { return }
            await recorder.record(available)
        default:
            break
        }
    }
}

private struct RunReportServeFixture {
    let storage: URL
    let configuration: NodeConfiguration
    let runtime: NodeNetworkRuntime
    let process: ChainProcess
    let child: Ivy
    /// Ivy holds its delegate weakly; the fixture keeps the fake child alive.
    let childDelegate: ChildEvidencePeer
    /// A second child naming a directory this node never anchored.
    let stranger: Ivy
    let strangerDelegate: ChildEvidencePeer
    let strangerRecorder: ChildEvidenceRecorder
    let recorder: ChildEvidenceRecorder
    let carrierCID: String
    let childCID: String
    let strangerCID: String
}

private struct PendingSideCarrierFixture {
    let storage: URL
    let configuration: NodeConfiguration
    let runtime: NodeNetworkRuntime
    let process: ChainProcess
    let child: Ivy
    let childDelegate: ChildEvidencePeer
    let recorder: ChildEvidenceRecorder
    let remoteContent: InMemoryContentStore
    let canonicalTipCID: String
    let carrierCID: String
    let childCID: String
    let childPath: [String]
}

/// A raw immediate child on its parent's hierarchy plane. It answers the
/// parent's hello with its own, then asks for its evidence index (answered
/// for any wired child) and for the genesis CID the parent anchored for its
/// directory. Records every payload the parent sends.
private final class AnchorRequestingChildPeer: IvyDelegate, Sendable {
    private let recorder: PayloadRecorder
    private let hello: Data
    private let childPath: [String]

    init(recorder: PayloadRecorder, hello: Data, childPath: [String]) {
        self.recorder = recorder
        self.hello = hello
        self.childPath = childPath
    }

    func ivy(
        _ ivy: Ivy,
        didReceiveMessage message: PeerMessage,
        from peer: AuthenticatedPeer
    ) async {
        await recorder.append(topic: message.topic, payload: message.payload)
        guard message.topic == NodeNetworkTopic.hierarchyHello,
              let index = try? ChildEvidenceIndexRequestMessage(
                requestID: 1,
                childPath: childPath,
                sourceID: nil,
                cursor: 0,
                through: nil
              ).encoded(),
              let anchor = try? ChildGenesisAnchorRequestMessage(
                requestID: 2
              ).encoded()
        else { return }
        _ = await ivy.sendMessage(
            to: peer,
            topic: NodeNetworkTopic.hierarchyHello,
            payload: hello
        )
        _ = await ivy.sendMessage(
            to: peer,
            topic: NodeNetworkTopic.childEvidenceIndexRequest,
            payload: index
        )
        _ = await ivy.sendMessage(
            to: peer,
            topic: NodeNetworkTopic.childGenesisAnchorRequest,
            payload: anchor
        )
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

        let complete = NodeNetworkRuntime.merging(proofOnly, with: genesisOnly)
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
        XCTAssertNil(NodeNetworkRuntime.merging(proofOnlyA, with: genesisOnB))

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
        XCTAssertNil(NodeNetworkRuntime.merging(genesisA, with: conflictingA))

        // The same verdict on the same proof still merges (idempotent).
        XCTAssertEqual(
            NodeNetworkRuntime.merging(genesisA, with: genesisA)?
                .package.parentGenesisLink,
            genesis
        )
    }

    func testEvidenceIndexPagesAreCanonicalAndCursorBound() throws {
        let summaries = [
            IssuedChildEvidenceSummary(
                ordinal: 1,
                childCID: testCID("child-a"),
                rootCID: testCID("root-a"),
                attachmentCID: testCID("attachment-a")
            ),
            IssuedChildEvidenceSummary(
                ordinal: 2,
                childCID: testCID("child-b"),
                rootCID: testCID("root-a"),
                attachmentCID: testCID("attachment-b")
            ),
            IssuedChildEvidenceSummary(
                ordinal: 3,
                childCID: testCID("child-b"),
                rootCID: testCID("root-b"),
                attachmentCID: testCID("attachment-c")
            ),
        ]
        let cursor = summaries[0]
        let request = ChildEvidenceIndexRequestMessage(
            requestID: 9,
            childPath: ["Nexus", "Payments"],
            sourceID: testEvidenceSourceID,
            cursor: cursor.ordinal,
            through: 3
        )
        XCTAssertEqual(
            try ChildEvidenceIndexRequestMessage.decoded(request.encoded()),
            request
        )
        let entries = Array(summaries.dropFirst())
        let response = ChildEvidenceIndexResponseMessage(
            requestID: 9,
            childPath: ["Nexus", "Payments"],
            sourceID: testEvidenceSourceID,
            cursor: cursor.ordinal,
            through: 3,
            entries: entries,
            next: 3
        )
        XCTAssertEqual(
            try ChildEvidenceIndexResponseMessage.decoded(response.encoded()),
            response
        )
        XCTAssertThrowsError(try ChildEvidenceIndexResponseMessage(
            requestID: 9,
            childPath: ["Nexus", "Payments"],
            sourceID: testEvidenceSourceID,
            cursor: cursor.ordinal,
            through: 3,
            entries: Array(response.entries.reversed()),
            next: 3
        ).encoded())
        XCTAssertThrowsError(try ChildEvidenceIndexResponseMessage(
            requestID: 9,
            childPath: ["Nexus", "Payments"],
            sourceID: testEvidenceSourceID,
            cursor: cursor.ordinal,
            through: 3,
            entries: [],
            next: 2
        ).encoded())
    }

    func testEvidenceAvailabilityCarriesOneCompleteVolumeRoot() async throws {
        let process = try await canonicalNetworkProcess()
        let block = try await process.canonicalTipBlock()
        let childCID = try BlockHeader(node: block).rawCID
        let envelope = try ChildValidationPackageEnvelope(
            ChildValidationPackage(proof: proof())
        )
        let attachment = try ChildEvidenceVolume(
            envelopeBytes: envelope.encode(),
            childCID: childCID
        )
        let response = ChildEvidenceAvailableMessage(
            childPath: ["Nexus", "Payments"],
            sourceID: testEvidenceSourceID,
            ordinal: 1,
            childCID: childCID,
            rootCID: childCID,
            attachmentCID: attachment.rawCID
        )
        let decoded = try ChildEvidenceAvailableMessage.decoded(response.encoded())
        XCTAssertEqual(decoded.attachmentCID, attachment.rawCID)
        XCTAssertEqual(attachment.serialized.entries.count, 1)
        XCTAssertNil(attachment.serialized.entries[childCID])
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

    func testPortableAttachmentsKeepDistinctRootsForTheSameChildWhileAdmissionIsBlocked()
        async throws
    {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-portable-root-queue-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let rootKey = signingKey(0x73)
        let rootPeerKey = peerKey(rootKey).hex
        let middleConfiguration = try NodeConfiguration(
            chainPath: ["Nexus", "Middle"],
            storagePath: storage.appendingPathComponent("middle"),
            privateKeyHex: String(repeating: "74", count: 32),
            listenPort: NetworkTransportTestPorts.allocate(),
            factListenPort: NetworkTransportTestPorts.allocate(),
            rpcPort: NetworkTransportTestPorts.allocate(),
            parentEndpoint: ParentEndpoint(
                publicKey: rootPeerKey,
                host: "127.0.0.1",
                port: NetworkTransportTestPorts.allocate()
            )
        )
        let middlePeerKey = middleConfiguration.processPublicKey
        let overlayPort = NetworkTransportTestPorts.allocate()
        let hierarchyPort = NetworkTransportTestPorts.allocate()
        let parentPort = NetworkTransportTestPorts.allocate()
        let targetConfiguration = try NodeConfiguration(
            chainPath: ["Nexus", "Middle", "Leaf"],
            storagePath: storage.appendingPathComponent("target"),
            privateKeyHex: String(repeating: "75", count: 32),
            listenPort: overlayPort,
            factListenPort: hierarchyPort,
            rpcPort: NetworkTransportTestPorts.allocate(),
            parentEndpoint: ParentEndpoint(
                publicKey: middlePeerKey,
                host: "127.0.0.1",
                port: parentPort
            )
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

        var attachments: [PortableAttachmentTestPayload] = []
        for (proof, edge) in zip(proofs, edges) {
            let package = ChildValidationPackage(
                proof: proof
            )
            let envelope = try ChildValidationPackageEnvelope(package)
            let attachment = try ChildEvidenceVolume(
                envelopeBytes: try envelope.encode(),
                childCID: leafHeader.rawCID
            )
            let attachmentBroker = MemoryBroker()
            try await attachment.store(
                storer: attachmentBroker
            )
            let fetchedAttachment = await attachmentBroker.fetchVolumeLocal(
                root: attachment.rawCID
            )
            let attachmentVolume = try XCTUnwrap(fetchedAttachment)
            XCTAssertEqual(attachmentVolume.root, attachment.serialized.root)
            XCTAssertEqual(attachmentVolume.entries, attachment.serialized.entries)
            attachments.append(PortableAttachmentTestPayload(
                summary: PortableAttachmentSummary(
                    edgeCID: try XCTUnwrap(edge.edgeCID),
                    rootCID: proof.rootCID,
                    attachmentCID: attachment.rawCID
                ),
                content: attachment.serialized.entries
            ))
        }
        let parentPeerKey = try PeerKey(middlePeerKey)
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
                ),
                hierarchy: IvyConfig(
                    signingKey: targetConfiguration.signingKey,
                    listenPort: hierarchyPort,
                    bootstrapPeers: [PeerEndpoint(
                        publicKey: middlePeerKey,
                        host: "127.0.0.1",
                        port: targetConfiguration.parentEndpoint!.port
                    )],
                    inboundAdmissionBypassPeerKeys: [parentPeerKey],
                    stunServers: [],
                    healthConfig: PeerHealthConfig(enabled: false),
                    maxConnections: IvyConfig.defaultMaxConnections,
                    reservedOutboundConnectionSlots: 1,
                    maxConnectionsPerNetgroup: IvyConfig.defaultMaxConnections,
                    relayEnabled: false,
                    privateContentExchangeEnabled: true,
                    carriers: [],
                    mode: .privateNetwork
                )
            )
        )
        let process = try await ChainProcess.open(
            configuration: targetConfiguration
        )
        let roots = NetworkEventRecorder()
        let unavailable = NetworkEventRecorder()
        let eager = NetworkEventRecorder()
        let firstAdmissionGate = CandidateBuildGate()
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
                        parentCarrierLink: nil,
                        sameChainPredecessor: nil
                    )
                }
                guard (await admission.contentSource.fetch(
                    Set([admission.header.rawCID])
                ))[admission.header.rawCID] != nil else {
                    throw NetworkTestError.failedPhase("child Volume unavailable")
                }
                if (await roots.snapshot()).isEmpty {
                    _ = await firstAdmissionGate.enter()
                }
                await roots.append(rootCID)
                return NodeImportOutcome(
                    decision: .acceptedSide(ChainCommit(
                        tipHash: admission.header.rawCID
                    )),
                    parentCarrierLink: nil,
                    sameChainPredecessor: nil
                )
            }
        )

        let evidencePeer = Ivy(config: IvyConfig(
            signingKey: signingKey(0x76),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        let delegate = PortableAttachmentQueuePeer(
            attachments: attachments,
            firstAdmissionGate: firstAdmissionGate
        )
        await evidencePeer.installTestDelegate(delegate)
        await evidencePeer.setContentSource(delegate)
        let blockKey = signingKey(0x77)
        let blockAdvertiser = Ivy(config: IvyConfig(
            signingKey: blockKey,
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        let replacement = Ivy(config: IvyConfig(
            signingKey: signingKey(0x78),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        await blockAdvertiser.setContentSource(
            VolumeSource(one: leafSerializedVolume)
        )
        await replacement.setContentSource(
            VolumeSource(one: leafSerializedVolume)
        )
        let parent = Ivy(config: IvyConfig(
            signingKey: middleConfiguration.signingKey,
            listenPort: parentPort,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            privateContentExchangeEnabled: true,
            mode: .privateNetwork
        ))
        // Parent authentication authorizes the attachment; availability is
        // independent. The exact overlay advertiser serves the complete child
        // genesis Volume.
        do {
            try await parent.start()
            try await runtime.start(process: process, chain: handlers)
            let childPeer = PeerID(publicKey: targetConfiguration.processPublicKey)
            for _ in 0..<100 {
                if (await parent.connectedPeers).contains(childPeer) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let hierarchyHello = try ChainHello(
                nexusGenesisCID: targetConfiguration.nexusGenesisCID,
                chainPath: middleConfiguration.chainPath
            ).encode()
            guard (await parent.connectedPeers).contains(childPeer),
                  case .enqueued = await parent.sendMessage(
                    to: childPeer,
                    topic: NodeNetworkTopic.hierarchyHello,
                    payload: hierarchyHello
                  ) else {
                throw NetworkTestError.failedStart
            }
            try await connectAndHello(
                evidencePeer,
                peerID: PeerID(publicKey: targetConfiguration.processPublicKey),
                endpoint: PeerEndpoint(
                    publicKey: targetConfiguration.processPublicKey,
                    host: "127.0.0.1",
                    port: overlayPort
                ),
                hello: try ChainHello(
                    nexusGenesisCID: targetConfiguration.nexusGenesisCID,
                    chainPath: targetConfiguration.chainPath
                ).encode()
            )
            try await connectAndHello(
                blockAdvertiser,
                peerID: PeerID(publicKey: targetConfiguration.processPublicKey),
                endpoint: PeerEndpoint(
                    publicKey: targetConfiguration.processPublicKey,
                    host: "127.0.0.1",
                    port: overlayPort
                ),
                hello: try ChainHello(
                    nexusGenesisCID: targetConfiguration.nexusGenesisCID,
                    chainPath: targetConfiguration.chainPath
                ).encode()
            )
            guard case .enqueued = await blockAdvertiser.sendMessage(
                to: PeerID(publicKey: targetConfiguration.processPublicKey),
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
                phase: "overlay block before portable parent proof"
            )
            // Availability hints are dropped until the evidence peer's hello has
            // been processed on its own session; re-send until both are served.
            for _ in 0..<200 {
                if (await delegate.servedRoots()).count == 2 { break }
                for attachment in attachments {
                    _ = await evidencePeer.sendMessage(
                        to: PeerID(publicKey: targetConfiguration.processPublicKey),
                        topic: NodeNetworkTopic.portableAttachmentAvailable,
                        payload: try PortableAttachmentAvailableMessage(
                            edgeCID: attachment.summary.edgeCID,
                            rootCID: attachment.summary.rootCID,
                            attachmentCID: attachment.summary.attachmentCID
                        ).encoded()
                    )
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            let initiallyServedRoots = await delegate.servedRoots()
            guard initiallyServedRoots.count == 2 else {
                throw NetworkTestError.failedPhase(
                    "distinct portable attachment roots"
                )
            }
            XCTAssertEqual(
                initiallyServedRoots,
                Set(attachments.map(\.summary.attachmentCID))
            )

            await blockAdvertiser.stop()
            await firstAdmissionGate.release(1)
            try await waitForEventCount(
                1,
                in: roots,
                phase: "first root before advertiser replacement"
            )
            try await connectAndHello(
                replacement,
                peerID: PeerID(publicKey: targetConfiguration.processPublicKey),
                endpoint: PeerEndpoint(
                    publicKey: targetConfiguration.processPublicKey,
                    host: "127.0.0.1",
                    port: overlayPort
                ),
                hello: try ChainHello(
                    nexusGenesisCID: targetConfiguration.nexusGenesisCID,
                    chainPath: targetConfiguration.chainPath
                ).encode()
            )
            guard case .enqueued = await replacement.sendMessage(
                to: PeerID(publicKey: targetConfiguration.processPublicKey),
                topic: NodeNetworkTopic.blockAnnouncement,
                payload: try BlockAnnouncementMessage(
                    blockCID: leafHeader.rawCID
                ).encoded()
            ) else {
                throw NetworkTestError.failedSend
            }
            try await waitForEventCount(
                2,
                in: roots,
                phase: "replacement advertiser retry"
            )
            let admittedRoots = await roots.snapshot()
            let servedRoots = await delegate.servedRoots()
            XCTAssertEqual(
                servedRoots,
                Set(attachments.map(\.summary.attachmentCID))
            )
            XCTAssertEqual(admittedRoots.count, 2)
            XCTAssertEqual(Set(admittedRoots), Set(proofs.map(\.rootCID)))
            let eagerAdmissions = await eager.snapshot()
            XCTAssertTrue(
                eagerAdmissions.isEmpty,
                "a portable attachment is a network block: weighed, \(eagerAdmissions)"
            )
        } catch {
            await firstAdmissionGate.releaseAll()
            await replacement.stop()
            await blockAdvertiser.stop()
            await evidencePeer.stop()
            await parent.stop()
            await runtime.stop()
            throw error
        }
        await firstAdmissionGate.releaseAll()
        await replacement.stop()
        await blockAdvertiser.stop()
        await evidencePeer.stop()
        await parent.stop()
        await runtime.stop()
    }

    /// The validate walk's evidence request suspends on the parent's answer.
    /// §9.10 over a real hierarchy session, PARENT side: a child that wired in
    /// (and became evidence-ready) asks for the runs of two committers, one
    /// real and one that commits nothing here. The runtime serves the real
    /// one — with the successor's work in it — and is silent about the other,
    /// exactly once each; and the directory was served only because this
    /// chain anchored the child's genesis, not because a peer named it.
    func testParentServesRunReportsForTheCarriersAChildNamesAndOnlyThose()
        async throws
    {
        let fixture = try await runReportServeFixture(keyByte: 0x68)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fixture.storage)
        }
        do {
            let process = fixture.process
            try await fixture.runtime.start(
                process: process,
                chain: ClosureChainInterface(
                    admission: { _ in
                        NodeImportOutcome(
                            decision: .duplicate,
                            parentCarrierLink: nil,
                            sameChainPredecessor: nil
                        )
                    },
                    runReportServing: { directory in
                        await process.serveRuns(for: directory)
                    }
                )
            )
            try await fixture.child.start()
            try await fixture.stranger.start()
            try await eventually("the parent served the real committer's run") {
                !(await fixture.recorder.runReportsSeen()).isEmpty
            }
            try await eventually("the stranger's index request was answered") {
                !(await fixture.strangerRecorder.snapshot()).indexEntries.isEmpty
            }
            // Let a second (wrong) answer arrive if one were ever going to.
            try await alwaysDuring("the stranger stays unserved, one report only", .milliseconds(300)) {
                let strangerSaw = await fixture.strangerRecorder.runReportsSeen()
                let served = await fixture.recorder.runReportsSeen()
                return strangerSaw.isEmpty && served.count == 1
            }
            let served = await fixture.recorder.runReportsSeen()
            let strangerSaw = await fixture.strangerRecorder.runReportsSeen()
            XCTAssertTrue(strangerSaw.isEmpty, "a directory this node never anchored is served nothing")
            XCTAssertEqual(served.count, 1, "one report for the one committer; silence for the stranger")
            let report = try XCTUnwrap(served.first)
            XCTAssertEqual(report.carrierCID, fixture.carrierCID)
            XCTAssertEqual(report.childBlockCID, fixture.childCID)
            XCTAssertEqual(report.directory, "Payments")
            XCTAssertGreaterThan(report.runWork, report.ownWork,
                                 "the successor mined on the carrier is in its run")
            let servedDirectories = await process.servedRunDirectoryList()
            XCTAssertEqual(servedDirectories, ["Payments"], "served because anchored, not because a peer named it")
            await fixture.stranger.stop()
            await fixture.child.stop()
            await fixture.runtime.stop()
        } catch {
            await fixture.stranger.stop()
            await fixture.child.stop()
            await fixture.runtime.stop()
            throw error
        }
    }

    /// §9.10 over a real hierarchy session, child side: once the parent role
    /// is granted the child asks for the runs of the committers it names, the
    /// parent's reply arrives on the push topic, and the report reaches the
    /// service handler with its fields intact. A child with nothing to ask
    /// sends nothing (pinned by the request list being exactly its committers).
    func testChildAsksItsParentForRunReportsOnHelloAndReceivesTheReply()
        async throws
    {
        let fixture = try await hierarchyRetryFixture(keyByte: 0x6A, summary: nil)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fixture.storage)
        }
        let carrier = testCID("run-report-committer")
        let sink = ParentRunReportSink()
        do {
            try await fixture.parent.start()
            try await fixture.runtime.start(
                process: fixture.process,
                chain: ClosureChainInterface(
                    admission: { _ in
                        NodeImportOutcome(
                            decision: .duplicate,
                            parentCarrierLink: nil,
                            sameChainPredecessor: nil
                        )
                    },
                    parentRunReport: { report in await sink.record(report) },
                    recentCarriers: { [carrier] }
                )
            )
            try await eventually("parent role granted") {
                !(await fixture.recorder.sessionTrace()).hellos.isEmpty
            }
            try await eventually("run-report request sent to the parent") {
                !(await fixture.recorder.runReportRequestsSeen()).isEmpty
            }
            let requests = await fixture.recorder.runReportRequestsSeen()
            XCTAssertEqual(requests.map(\.carrierCIDs), [[carrier]],
                           "exactly the committers this chain knows, once per session")
            try await eventually("the parent's report reached the handler") {
                !(await sink.received()).isEmpty
            }
            let received = await sink.received()
            let report = try XCTUnwrap(received.first)
            XCTAssertEqual(report.blockHash, carrier)
            XCTAssertEqual(report.directory, "Retry")
            XCTAssertEqual(report.childBlock, testCID("run-report-child-block"))
            XCTAssertEqual(report.grinds, [carrier])
            XCTAssertEqual(report.runWork, WorkSum(UInt256(9)))
            XCTAssertEqual(report.ownWork, WorkSum(UInt256(4)))
            XCTAssertEqual(report.revision, 7)
            await fixture.parent.stop()
            await fixture.runtime.stop()
        } catch {
            await fixture.parent.stop()
            await fixture.runtime.stop()
            throw error
        }
    }

    /// When the parent session drops while it is in flight, the request must
    /// resolve nil (the walk parks and retries) — never stay suspended: an
    /// unresumed continuation would leave the walk worker alive and every
    /// later reserve a no-op for the process lifetime.
    func testExecutionEvidenceRequestResolvesNilWhenTheParentSessionDrops()
        async throws
    {
        let fixture = try await hierarchyRetryFixture(
            keyByte: 0x68,
            summary: nil
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fixture.storage)
        }
        let package = AuthenticatedChildPackage(
            package: ChildValidationPackage(proof: ChildBlockProof(
                rootCID: "proof-root",
                directoryPath: ["Retry"],
                entries: []
            ))
        )
        do {
            try await fixture.parent.start()
            try await fixture.runtime.start(
                process: fixture.process,
                chain: duplicateNetworkHandlers()
            )
            try await eventually("parent role granted") {
                !(await fixture.recorder.sessionTrace()).hellos.isEmpty
            }
            // In flight: the parent never answers.
            let resolved = Task { [runtime = fixture.runtime] in
                await runtime.resolveExecutionEvidenceForTesting(
                    for: testCID("child-block"),
                    requirement: .parentStateContinuity(
                        parentPath: ["Nexus"],
                        // The protocol's only continuity shape: anchored at
                        // the parent chain's genesis. A synthetic `from` is
                        // refused as malformed and never reaches the wire.
                        fromStateCID: LatticeState.emptyHeader.rawCID,
                        toStateCID: testCID("to-state")
                    ),
                    package: package
                )
            }
            try await eventually("request sent to the parent") {
                await fixture.recorder.parentFactRequestCount() >= 1
            }
            await fixture.parent.stop()

            // Bounded: a leaked continuation never returns.
            let outcome = await withTaskGroup(
                of: Bool.self, returning: Bool.self
            ) { group in
                group.addTask { await resolved.value == nil }
                group.addTask {
                    try? await Task.sleep(nanoseconds: scaledNanoseconds(.seconds(10)))
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            XCTAssertTrue(
                outcome,
                "an in-flight evidence request must resolve nil on parent drop"
            )
        } catch {
            await fixture.parent.stop()
            await fixture.runtime.stop()
            throw error
        }
        await fixture.parent.stop()
        await fixture.runtime.stop()
    }

    func testRecoveredNoncanonicalCarrierAnnouncesEvidenceAfterEmptyIndex()
        async throws {
        let fixture = try await pendingSideCarrierFixture(
            keyByte: 0x68,
            rejectAvailability: false
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fixture.storage)
        }
        var provider: Ivy?

        do {
            try await fixture.runtime.start(
                process: fixture.process,
                chain: duplicateNetworkHandlers()
            )
            try await fixture.child.start()
            try await waitForEvidenceIndexes(fixture, count: 1)
            let initial = await fixture.recorder.snapshot()
            XCTAssertEqual(
                initial.indexEntries,
                [[]]
            )

            provider = try await exposePendingCarrierContent(
                fixture,
                keyByte: 0x6a
            )
            for _ in 0..<300 {
                if !(await fixture.recorder.snapshot()).available.isEmpty {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }

            let recorded = await fixture.recorder.snapshot()
            XCTAssertEqual(recorded.indexEntries, [[]])
            XCTAssertEqual(recorded.available.count, 1)
            XCTAssertEqual(recorded.available.first?.childPath, fixture.childPath)
            XCTAssertEqual(recorded.available.first?.childCID, fixture.childCID)
            XCTAssertEqual(recorded.available.first?.rootCID, fixture.carrierCID)
            XCTAssertTrue(recorded.available.first.map {
                CIDIdentity.isCanonical($0.attachmentCID)
            } ?? false)
            let pending = try await fixture.process.pendingChildProofCarrierCIDs()
            let status = await fixture.process.status()
            // A concurrent current-tip retry may retain its own route. This
            // recovery is responsible only for the side carrier it completed.
            XCTAssertFalse(pending.contains(fixture.carrierCID))
            XCTAssertEqual(status.tipCID, fixture.canonicalTipCID)
        } catch {
            await provider?.stop()
            await fixture.child.stop()
            await fixture.runtime.stop()
            throw error
        }
        await provider?.stop()
        await fixture.child.stop()
        await fixture.runtime.stop()
    }

    /// A parent whose own send budget refuses an evidence hint keeps the
    /// session and re-sends the hint on its next push run: a child scans the
    /// index only on a hello or an admission, so a refused hint left alone
    /// would strand the entry until the next delivered one.
    func testRejectedEvidenceHintKeepsTheSessionAndIsResentWhenTheBudgetAllows()
        async throws {
        let fixture = try await pendingSideCarrierFixture(
            keyByte: 0x6b,
            rejectAvailability: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fixture.storage)
        }
        var provider: Ivy?
        let parentID = PeerID(publicKey: fixture.configuration.processPublicKey)

        do {
            try await fixture.runtime.start(
                process: fixture.process,
                chain: duplicateNetworkHandlers()
            )
            try await fixture.child.start()
            try await waitForEvidenceIndexes(fixture, count: 1)
            let hierarchyTally = await fixture.runtime.hierarchy.tally
            let childID = await fixture.child.localID
            var exhausted = false
            for _ in 0..<16 where !exhausted {
                exhausted = !hierarchyTally.shouldAllow(
                    peer: childID
                )
            }
            XCTAssertTrue(exhausted)

            provider = try await exposePendingCarrierContent(
                fixture,
                keyByte: 0x6d
            )
            // The side carrier completes and its evidence lands in the
            // durable index; the hint that follows is the one the budget
            // refuses. Wait for the index, not the clock: sanitizer builds
            // take several times longer to get here.
            var indexed = false
            for _ in 0..<1_000 where !indexed {
                indexed = try await fixture.process.store.issuedChildEvidenceScanHead(
                    directory: "Payments"
                ).throughOrdinal > 0
                if !indexed { try await Task.sleep(for: .milliseconds(10)) }
            }
            XCTAssertTrue(indexed, "the carrier's evidence is indexed")
            // The hint that follows the index is the one the budget refuses;
            // wait for that refusal to be on record, not for the clock.
            var refused = 0
            for _ in 0..<1_000 where refused == 0 {
                refused = await fixture.runtime.debugSnapshot().refusedChildEvidenceHintCount
                if refused == 0 { try await Task.sleep(for: .milliseconds(10)) }
            }
            XCTAssertEqual(refused, 1, "the hint was refused and remembered")
            let connectedAfterRejection = await fixture.child.connectedPeers
            XCTAssertTrue(
                connectedAfterRejection.contains(parentID),
                "a refused hint is not the session's fault"
            )
            let rejected = await fixture.recorder.snapshot()
            XCTAssertEqual(rejected.helloSessions.count, 1)
            XCTAssertEqual(rejected.indexEntries, [[]])
            XCTAssertTrue(rejected.available.isEmpty)

            // Budget back, the next push run (any state change) re-sends the
            // hint on the same session; no reconnect, no index pull.
            hierarchyTally.resetPeer(childID)
            await fixture.runtime.chainStateChanged()
            var resent: [ChildEvidenceAvailableMessage] = []
            for _ in 0..<2_000 {
                resent = await fixture.recorder.snapshot().available
                if !resent.isEmpty { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let repaired = await fixture.recorder.snapshot()
            XCTAssertEqual(repaired.helloSessions.count, 1, "the session is the same one")
            XCTAssertEqual(repaired.indexEntries, [[]], "no second index pull was needed")
            XCTAssertEqual(resent.count, 1)
            XCTAssertEqual(resent.first?.childCID, fixture.childCID)
            XCTAssertEqual(resent.first?.rootCID, fixture.carrierCID)
            XCTAssertTrue(
                resent.first.map { CIDIdentity.isCanonical($0.attachmentCID) } ?? false,
                "attachment \(resent.first?.attachmentCID ?? "none")"
            )
            // The recovered side carrier's route is released by the same
            // publication the hint rode on; that finishes on its own clock.
            // A concurrent current-tip retry may retain its own route; this
            // recovery answers only for the side carrier it completed.
            var pending = try await fixture.process.pendingChildProofCarrierCIDs()
            for _ in 0..<1_000 where pending.contains(fixture.carrierCID) {
                try await Task.sleep(for: .milliseconds(10))
                pending = try await fixture.process.pendingChildProofCarrierCIDs()
            }
            let status = await fixture.process.status()
            XCTAssertFalse(pending.contains(fixture.carrierCID), "\(pending)")
            XCTAssertEqual(status.tipCID, fixture.canonicalTipCID)
        } catch {
            await provider?.stop()
            await fixture.child.stop()
            await fixture.runtime.stop()
            throw error
        }
        await provider?.stop()
        await fixture.child.stop()
        await fixture.runtime.stop()
    }

    // A node that SYNCED a carrier committing a child — with no child peer
    // connected at admission and no GenesisAction to auto-seed a route — never
    // issues that child's securing evidence, though a node that MINED the same
    // carrier would have issued it eagerly. That is the mining⊥admission gap a
    // late-connecting (or post-restart-recovered) child hits. The backfill must
    // self-issue it from the accepted carrier, independent of peer timing.
    func testBackfillSeedsRoutesForAnUnroutedCommittedChildCarrier() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-late-child-backfill-\(UUID().uuidString)", isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storage,
            privateKeyHex: String(repeating: "6b", count: 32),
            listenPort: NetworkTransportTestPorts.allocate(),
            factListenPort: NetworkTransportTestPorts.allocate(),
            rpcPort: NetworkTransportTestPorts.allocate()
        )
        let process = try await ChainProcess.open(configuration: configuration)
        let genesis = try await process.canonicalTipBlock()

        // A carrier that COMMITS a child but carries no GenesisAction — so
        // admission with no connected child peer seeds no route for it. A node
        // that MINED this carrier would have issued the child's evidence
        // eagerly; a node that SYNCED it leaves the child unrouted (the
        // late-connect / post-restart-recovery gap).
        try await LatticeState.emptyHeader.storeRecursively(storer: process)
        let childBlock = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec,
            parentState: LatticeState.emptyHeader,
            timestamp: 3_600_000,
            target: .max,
            fetcher: process
        )
        let carrier = try await BlockBuilder.buildBlock(
            previous: genesis,
            children: ["Payments": childBlock],
            timestamp: 3_600_000,
            nonce: 1,
            fetcher: process
        )
        let carrierHeader = try BlockHeader(node: carrier)
        try await carrierHeader.storeBlock(fetcher: process, storer: process)

        let outcome = try await process.importBlock(
            BlockHeader(
                rawCID: carrierHeader.rawCID,
                node: nil,
                encryptionInfo: nil
            ),
            preparingChildDirectories: []
        )
        guard outcome.decision.isAccepted else {
            throw NetworkTestError.failedPhase("committed-child carrier admission")
        }

        // Gap: the accepted carrier committed a child, but admission seeded no
        // proof route for it.
        let routedBefore = try await process.pendingChildProofCarrierCIDs()
        XCTAssertTrue(routedBefore.isEmpty, "carrier unrouted before backfill")

        // The backfill closes the gap: it seeds the pending proof route from the
        // accepted carrier, independent of mining and of peer timing. The
        // existing acquire/promote pipeline then issues the evidence once the
        // child content resolves (locally-retained or fetched from any peer).
        await process.backfillChildProofRoutes(directory: "Payments")

        let routedAfter = try await process.pendingChildProofCarrierCIDs()
        XCTAssertEqual(
            routedAfter, [carrierHeader.rawCID],
            "backfill seeds a proof route for the accepted carrier's committed child"
        )
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

    /// A parent with more anchored children than one listing page. Anchors
    /// live in the genesisState trie in key order, so `c200` sorts past the
    /// first 200 entries while `c000` sits inside them. For both wired
    /// children, every runtime path that resolves a child's anchor must find
    /// it: the answer to the child's own anchor request, the read URL served
    /// for the child's genesis, and the provider record announced for it.
    /// Each path's observation is recorded while the network runs and asserted
    /// only once it is torn down.
    func testWiredChildAnchorsResolveBeyondTheFirstListingPage()
        async throws {
        let target = try await overlayRuntime(
            keyByte: 0xd1,
            requestTimeout: .seconds(2)
        )
        let directories = (0...200).map { String(format: "c%03d", $0) }
        let anchors = directories.map {
            GenesisAction(directory: $0, blockCID: testCID("anchor-\($0)"))
        }
        let genesisCIDs = Dictionary(
            uniqueKeysWithValues: anchors.map { ($0.directory, $0.blockCID) }
        )
        let children = ["c000", "c200"]
        XCTAssertEqual(directories.sorted().firstIndex(of: "c200"), 200)

        let key = CryptoUtils.generateKeyPair()
        let body = TransactionBody(
            accountActions: [],
            actions: [],
            depositActions: [],
            genesisActions: anchors,
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
        let authorization = Transaction(
            signatures: [key.publicKey: signature],
            body: bodyHeader
        )
        try await VolumeImpl<Transaction>(node: authorization)
            .storeRecursively(storer: target.process)
        let genesis = try await target.process.canonicalTipBlock()
        let carrier = try await BlockBuilder.buildBlock(
            previous: genesis,
            transactions: [authorization],
            timestamp: genesis.timestamp + 3_600_000,
            nonce: 1,
            fetcher: target.process
        )
        let admission = try await target.process.importBlock(
            BlockHeader(node: carrier)
        )
        XCTAssertTrue(admission.decision.isAccepted)

        /// The first payload on `topic` matching `accept`, or nil once the
        /// wait lapses.
        func firstPayload<Value>(
            _ topic: String,
            in recorder: PayloadRecorder,
            accept: (Data) -> Value?
        ) async throws -> Value? {
            // Generous: this file also runs under ASan + UBSan, where the
            // handshake and its hello follow-up are far slower. A lapse here
            // would read as an unresolved anchor — the very failure under
            // test — so it must only ever mean "never arrived".
            for _ in 0..<3_000 {
                for payload in await recorder.payloads(topic: topic) {
                    if let value = accept(payload) { return value }
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            return nil
        }

        let configuration = target.process.configuration
        var instances: [Ivy] = []
        var delegates: [any IvyDelegate] = []
        var wired: [String: Bool] = [:]
        var anchorAnswers: [String: String] = [:]
        var readURLs: [String: [String]] = [:]
        var announced: [String: Bool] = [:]
        func stopAll() async {
            for ivy in instances { await ivy.stop() }
            await target.runtime.stop()
        }
        do {
            try await target.runtime.start(
                process: target.process,
                chain: duplicateNetworkHandlers()
            )
            var recorders: [String: PayloadRecorder] = [:]
            for (index, directory) in children.enumerated() {
                let recorder = PayloadRecorder()
                let delegate = AnchorRequestingChildPeer(
                    recorder: recorder,
                    hello: try ChainHello(
                        nexusGenesisCID: configuration.nexusGenesisCID,
                        chainPath: ["Nexus", directory],
                        publicReadURL: "https://\(directory).example"
                    ).encode(),
                    childPath: ["Nexus", directory]
                )
                let child = Ivy(config: IvyConfig(
                    signingKey: signingKey(0xd2 + UInt8(index)),
                    listenPort: 0,
                    bootstrapPeers: [PeerEndpoint(
                        publicKey: configuration.processPublicKey,
                        host: "127.0.0.1",
                        port: configuration.factListenPort
                    )],
                    requestTimeout: .seconds(2),
                    stunServers: [],
                    mode: .privateNetwork
                ))
                await child.installTestDelegate(delegate)
                instances.append(child)
                delegates.append(delegate)
                recorders[directory] = recorder
                try await child.start()
            }

            // (1) The child's own anchor request, answered on the hierarchy
            // plane. The evidence-index answer (served to any wired child)
            // proves the role was granted, so a silent anchor answer is the
            // lookup's miss, not a missing session.
            for directory in children {
                let recorder = try XCTUnwrap(recorders[directory])
                wired[directory] = try await firstPayload(
                    NodeNetworkTopic.childEvidenceIndexResponse,
                    in: recorder,
                    accept: { _ in true }
                ) ?? false
                anchorAnswers[directory] = try await firstPayload(
                    NodeNetworkTopic.childGenesisAnchorResponse,
                    in: recorder,
                    accept: {
                        try? ChildGenesisAnchorResponseMessage.decoded($0)
                            .genesisCID
                    }
                )
            }

            // (2) The read URL a wired child declared, served for its genesis.
            let observerRecorder = PayloadRecorder()
            let observerDelegate = PayloadRecordingPeer(
                recorder: observerRecorder
            )
            // A real listen port: the parent routes (and so announces to) only
            // peers that advertise a dialable address.
            let observer = Ivy(config: IvyConfig(
                signingKey: signingKey(0xd4),
                listenPort: NetworkTransportTestPorts.allocate(),
                stunServers: [],
                mode: .overlay
            ))
            await observer.installTestDelegate(observerDelegate)
            instances.append(observer)
            delegates.append(observerDelegate)
            try await connectAndHello(
                observer,
                peerID: target.peerID,
                endpoint: target.endpoint,
                hello: target.hello
            )
            // Overlay topics are gated on a completed hello; the tip
            // announcement back proves it landed.
            _ = try await firstPayload(
                NodeNetworkTopic.blockAnnouncement,
                in: observerRecorder,
                accept: { $0 }
            )
            for (index, directory) in children.enumerated() {
                let requestID = UInt64(10 + index)
                _ = await observer.sendMessage(
                    to: target.peerID,
                    topic: NodeNetworkTopic.readEndpointRequest,
                    payload: try ReadEndpointRequestMessage(
                        requestID: requestID,
                        genesisCID: try XCTUnwrap(genesisCIDs[directory])
                    ).encoded()
                )
                readURLs[directory] = try await firstPayload(
                    NodeNetworkTopic.readEndpointResponse,
                    in: observerRecorder,
                    accept: { payload -> [String]? in
                        guard let response = try?
                                ReadEndpointResponseMessage.decoded(payload),
                              response.requestID == requestID
                        else { return nil }
                        return response.readURLs
                    }
                )
            }

            // (3) The provider record announced for each wired child genesis.
            await target.runtime.announceGenesisProvidersForTesting(
                process: target.process
            )
            for directory in children {
                let genesisCID = try XCTUnwrap(genesisCIDs[directory])
                let deadline = ContinuousClock.now + .seconds(15)
                var found = false
                while !found, ContinuousClock.now < deadline {
                    found = await observer.discoverProviders(
                        rootCID: genesisCID
                    ).contains {
                        $0.publicKey == configuration.processPublicKey
                    }
                    if !found {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                }
                announced[directory] = found
            }
        } catch {
            await stopAll()
            throw error
        }
        await stopAll()
        withExtendedLifetime(delegates) {}

        for directory in children {
            XCTAssertEqual(wired[directory], true, "\(directory) hierarchy role")
            XCTAssertEqual(
                anchorAnswers[directory],
                genesisCIDs[directory],
                "anchor request from \(directory)"
            )
            XCTAssertEqual(
                readURLs[directory],
                ["https://\(directory).example"],
                "read URL for \(directory)"
            )
            XCTAssertEqual(
                announced[directory],
                true,
                "provider record for \(directory)"
            )
        }
    }

    /// A Nexus runtime hosting one anchored child directory with a carrier
    /// that commits child block 1 and a successor mined on top of it, plus a
    /// fake child peer that, once evidence-ready, asks for the runs of the
    /// carrier and of a block that commits nothing.
    private func runReportServeFixture(keyByte: UInt8) async throws -> RunReportServeFixture {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-run-report-serve-\(UUID().uuidString)",
            isDirectory: true
        )
        let overlayPort = NetworkTransportTestPorts.allocate()
        let hierarchyPort = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storage,
            privateKeyHex: String(repeating: String(format: "%02x", keyByte), count: 32),
            listenPort: overlayPort,
            factListenPort: hierarchyPort,
            rpcPort: NetworkTransportTestPorts.allocate()
        )
        let childKey = signingKey(keyByte &+ 1)
        let runtime = try NodeNetworkRuntime(
            configuration: configuration,
            planeConfigurations: try NodeNetworkPlaneConfigurations(
                overlay: IvyConfig(
                    signingKey: configuration.signingKey,
                    listenPort: overlayPort,
                    stunServers: [],
                    mode: .overlay
                ),
                hierarchy: IvyConfig(
                    signingKey: configuration.signingKey,
                    listenPort: hierarchyPort,
                    requestTimeout: .milliseconds(200),
                    stunServers: [],
                    maxConnections: IvyConfig.defaultMaxConnections,
                    maxConnectionsPerNetgroup: IvyConfig.defaultMaxConnections,
                    privateContentExchangeEnabled: true,
                    mode: .privateNetwork
                )
            )
        )
        let process = try await ChainProcess.open(configuration: configuration)
        let genesis = try await process.canonicalTipBlock()
        // Anchor the child's genesis on the canonical chain.
        let childGenesis = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec,
            parentState: LatticeState.emptyHeader,
            timestamp: 3_600_000,
            target: UInt256.max,
            fetcher: process
        )
        let authorization = try signedGenesisAnchorTransaction(
            directory: "Payments",
            childGenesisCID: try BlockHeader(node: childGenesis).rawCID,
            chainPath: configuration.chainPath
        )
        try await VolumeImpl<Transaction>(node: authorization).storeRecursively(storer: process)
        let recording = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [authorization],
            timestamp: 3_600_000, nonce: 1, fetcher: process
        )
        guard try await process.importBlock(BlockHeader(node: recording)).decision.isAccepted else {
            throw NetworkTestError.failedPhase("recording carrier")
        }
        // The carrier commits child block 1.
        let provisional = try await BlockBuilder.buildBlock(
            previous: recording, timestamp: 7_200_000, nonce: 2, fetcher: process
        )
        let childBlock = try await BlockBuilder.buildBlock(
            previous: childGenesis, parentChainBlock: provisional,
            timestamp: 7_200_000, target: UInt256.max, fetcher: process
        )
        let carrier = try await BlockBuilder.buildBlock(
            previous: recording, children: ["Payments": childBlock],
            timestamp: 7_200_000, nonce: 2, fetcher: process
        )
        let carrierHeader = try BlockHeader(node: carrier)
        _ = try await process.prepareChildProofs(for: carrier, capacity: 16)
        guard try await process.importBlock(
            carrierHeader, preparingChildDirectories: ["Payments"]
        ).decision.isAccepted else {
            throw NetworkTestError.failedPhase("carrier")
        }
        _ = try await process.retryPendingChildProofs(carrierCID: carrierHeader.rawCID)
        // A successor on the carrier: its work belongs to the carrier's run.
        let successor = try await BlockBuilder.buildBlock(
            previous: carrier, timestamp: 10_800_000, nonce: 3, fetcher: process
        )
        let successorHeader = try BlockHeader(node: successor)
        guard try await process.importBlock(successorHeader).decision.isAccepted else {
            throw NetworkTestError.failedPhase("successor")
        }

        let childPath = ["Nexus", "Payments"]
        let recorder = ChildEvidenceRecorder()
        let childDelegate = ChildEvidencePeer(
            recorder: recorder,
            hello: try ChainHello(
                nexusGenesisCID: configuration.nexusGenesisCID,
                chainPath: childPath
            ).encode(),
            childPath: childPath,
            runReportCarriers: [carrierHeader.rawCID, successorHeader.rawCID]
        )
        let child = Ivy(config: IvyConfig(
            signingKey: childKey,
            listenPort: 0,
            bootstrapPeers: [PeerEndpoint(
                publicKey: configuration.processPublicKey,
                host: "127.0.0.1",
                port: hierarchyPort
            )],
            requestTimeout: .milliseconds(200),
            stunServers: [],
            mode: .privateNetwork
        ))
        await child.installTestDelegate(childDelegate)
        // A child of a directory this node never anchored asks for the same
        // committer: the name alone must serve nothing.
        let strangerPath = ["Nexus", "Markets"]
        let strangerRecorder = ChildEvidenceRecorder()
        let strangerDelegate = ChildEvidencePeer(
            recorder: strangerRecorder,
            hello: try ChainHello(
                nexusGenesisCID: configuration.nexusGenesisCID,
                chainPath: strangerPath
            ).encode(),
            childPath: strangerPath,
            runReportCarriers: [carrierHeader.rawCID]
        )
        let stranger = Ivy(config: IvyConfig(
            signingKey: signingKey(keyByte &+ 2),
            listenPort: 0,
            bootstrapPeers: [PeerEndpoint(
                publicKey: configuration.processPublicKey,
                host: "127.0.0.1",
                port: hierarchyPort
            )],
            requestTimeout: .milliseconds(200),
            stunServers: [],
            mode: .privateNetwork
        ))
        await stranger.installTestDelegate(strangerDelegate)
        return RunReportServeFixture(
            storage: storage,
            configuration: configuration,
            runtime: runtime,
            process: process,
            child: child,
            childDelegate: childDelegate,
            stranger: stranger,
            strangerDelegate: strangerDelegate,
            strangerRecorder: strangerRecorder,
            recorder: recorder,
            carrierCID: carrierHeader.rawCID,
            childCID: try BlockHeader(node: childBlock).rawCID,
            strangerCID: successorHeader.rawCID
        )
    }

    private func pendingSideCarrierFixture(
        keyByte: UInt8,
        rejectAvailability: Bool
    ) async throws -> PendingSideCarrierFixture {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-pending-side-proof-\(UUID().uuidString)",
            isDirectory: true
        )
        let overlayPort = NetworkTransportTestPorts.allocate()
        let hierarchyPort = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storage,
            privateKeyHex: String(
                repeating: String(format: "%02x", keyByte),
                count: 32
            ),
            listenPort: overlayPort,
            factListenPort: hierarchyPort,
            rpcPort: NetworkTransportTestPorts.allocate()
        )
        let childKey = signingKey(keyByte &+ 1)
        let hierarchyTally = rejectAvailability
            ? TallyConfig(
                perPeerRequestCapacity: 8,
                perPeerRequestRefillPerSecond: 0
            )
            : .default
        let runtime = try NodeNetworkRuntime(
            configuration: configuration,
            planeConfigurations: try NodeNetworkPlaneConfigurations(
                overlay: IvyConfig(
                    signingKey: configuration.signingKey,
                    listenPort: overlayPort,
                    stunServers: [],
                    mode: .overlay
                ),
                hierarchy: IvyConfig(
                    signingKey: configuration.signingKey,
                    listenPort: hierarchyPort,
                    tallyConfig: hierarchyTally,
                    requestTimeout: .milliseconds(200),
                    stunServers: [],
                    maxConnections: IvyConfig.defaultMaxConnections,
                    maxConnectionsPerNetgroup: IvyConfig.defaultMaxConnections,
                    privateContentExchangeEnabled: true,
                    mode: .privateNetwork
                )
            )
        )
        let process = try await ChainProcess.open(
            configuration: configuration
        )
        let genesis = try await process.canonicalTipBlock()
        var canonical = genesis
        for step in 1...3 {
            canonical = try await BlockBuilder.buildBlock(
                previous: canonical,
                timestamp: Int64(step * 3_600_000),
                nonce: UInt64(step),
                fetcher: process
            )
            let outcome = try await process.importBlock(BlockHeader(node: canonical))
            guard outcome.decision.isAccepted else {
                throw NetworkTestError.failedPhase("canonical fixture branch")
            }
        }
        let canonicalTipCID = try BlockHeader(node: canonical).rawCID

        let sidePredecessor = try await BlockBuilder.buildBlock(
            previous: genesis,
            timestamp: 3_600_000,
            nonce: 100,
            fetcher: process
        )
        let sidePredecessorHeader = try BlockHeader(node: sidePredecessor)
        let sidePredecessorOutcome = try await process.importBlock(sidePredecessorHeader)
        guard case .acceptedSide = sidePredecessorOutcome.decision else {
            throw NetworkTestError.failedPhase("side fixture predecessor")
        }

        // A self-contained child genesis (empty parentState) the side carrier
        // RECORDS via a GenesisAction while co-mining the child's height-1 block.
        let childGenesis = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec,
            parentState: LatticeState.emptyHeader,
            timestamp: 7_200_000,
            target: UInt256.max,
            fetcher: process
        )
        let authorization = try signedGenesisAnchorTransaction(
            directory: "Payments",
            childGenesisCID: try BlockHeader(node: childGenesis).rawCID,
            chainPath: configuration.chainPath
        )
        try await VolumeImpl<Transaction>(node: authorization).storeRecursively(
            storer: process
        )
        let provisional = try await BlockBuilder.buildBlock(
            previous: sidePredecessor,
            timestamp: 7_200_000,
            nonce: 101,
            fetcher: process
        )
        let childBlock = try await BlockBuilder.buildBlock(
            previous: childGenesis,
            parentChainBlock: provisional,
            timestamp: 7_200_000,
            target: UInt256.max,
            fetcher: process
        )
        let childHeader = try BlockHeader(node: childBlock)
        let carrier = try await BlockBuilder.buildBlock(
            previous: sidePredecessor,
            transactions: [authorization],
            children: ["Payments": childBlock],
            timestamp: 7_200_000,
            nonce: 101,
            fetcher: process
        )
        let carrierHeader = try BlockHeader(node: carrier)
        let remoteContent = InMemoryContentStore()
        let proof = try await ChildBlockProof.generate(
            rootHeader: carrierHeader,
            childDirectory: "Payments",
            fetcher: process
        )
        let remoteEntries = Dictionary(
            proof.entries.map { ($0.cid, $0.data) },
            uniquingKeysWith: { first, _ in first }
        )
        await remoteContent.store(entries: remoteEntries)
        try await childHeader.storeBlock(
            fetcher: process,
            storer: remoteContent
        )
        try await carrierHeader.storeBlock(
            fetcher: process,
            storer: remoteContent
        )
        try await carrierHeader.storeBlock(
            fetcher: process,
            storer: process
        )
        let carrierOutcome = try await process.importBlock(
            BlockHeader(
                rawCID: carrierHeader.rawCID,
                node: nil,
                encryptionInfo: nil
            ),
            // The child cannot authenticate until this carrier authorizes it;
            // the admission boundary must retain that new route itself.
            preparingChildDirectories: []
        )
        guard case .acceptedSide = carrierOutcome.decision,
              carrierOutcome.parentCarrierLink?.carrierCID == carrierHeader.rawCID
        else {
            throw NetworkTestError.failedPhase("pending side carrier")
        }
        guard try await process.pendingChildProofCarrierCIDs()
            == [carrierHeader.rawCID],
              try await process.store.issuedChildEvidenceSummaries(
                directory: "Payments",
                afterOrdinal: 0,
                throughOrdinal: UInt64(Int64.max),
                limit: 1
              ).isEmpty,
              await process.status().tipCID == canonicalTipCID
        else {
            throw NetworkTestError.failedPhase("pending side carrier state")
        }

        let childPath = ["Nexus", "Payments"]
        let recorder = ChildEvidenceRecorder()
        let childDelegate = ChildEvidencePeer(
            recorder: recorder,
            hello: try ChainHello(
                nexusGenesisCID: configuration.nexusGenesisCID,
                chainPath: childPath
            ).encode(),
            childPath: childPath
        )
        let child = Ivy(config: IvyConfig(
            signingKey: childKey,
            listenPort: 0,
            bootstrapPeers: [PeerEndpoint(
                publicKey: configuration.processPublicKey,
                host: "127.0.0.1",
                port: hierarchyPort
            )],
            requestTimeout: .milliseconds(200),
            stunServers: [],
            mode: .privateNetwork
        ))
        await child.installTestDelegate(childDelegate)
        return PendingSideCarrierFixture(
            storage: storage,
            configuration: configuration,
            runtime: runtime,
            process: process,
            child: child,
            childDelegate: childDelegate,
            recorder: recorder,
            remoteContent: remoteContent,
            canonicalTipCID: canonicalTipCID,
            carrierCID: carrierHeader.rawCID,
            childCID: childHeader.rawCID,
            childPath: childPath
        )
    }

    private func waitForEvidenceIndexes(
        _ fixture: PendingSideCarrierFixture,
        count: Int
    ) async throws {
        try await eventually("child evidence index") {
            (await fixture.recorder.snapshot()).indexEntries.count >= count
        }
    }

    private func exposePendingCarrierContent(
        _ fixture: PendingSideCarrierFixture,
        keyByte: UInt8
    ) async throws -> Ivy {
        let provider = Ivy(config: IvyConfig(
            signingKey: signingKey(keyByte),
            listenPort: 0,
            stunServers: [],
            mode: .overlay
        ))
        await provider.setContentSource(fixture.remoteContent)
        do {
            try await provider.start()
            let parentID = PeerID(
                publicKey: fixture.configuration.processPublicKey
            )
            try await provider.connect(to: PeerEndpoint(
                publicKey: fixture.configuration.processPublicKey,
                host: "127.0.0.1",
                port: fixture.configuration.listenPort
            ))
            for _ in 0..<200 {
                if (await provider.connectedPeers).contains(parentID) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard (await provider.connectedPeers).contains(parentID),
                  case .enqueued = await provider.sendMessage(
                    to: parentID,
                    topic: NodeNetworkTopic.overlayHello,
                    payload: try ChainHello(
                        nexusGenesisCID: fixture.configuration.nexusGenesisCID,
                        chainPath: fixture.configuration.chainPath
                    ).encode()
                  )
            else {
                throw NetworkTestError.failedStart
            }
            return provider
        } catch {
            await provider.stop()
            throw error
        }
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
