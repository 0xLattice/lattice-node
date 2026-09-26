import Ivy
import Lattice
import UInt256
import VolumeBroker
import XCTest
import cashew
@testable import LatticeNode

private func protocolCID(_ seed: String) -> String {
    try! HeaderImpl<PublicKey>(node: PublicKey(key: seed)).rawCID
}

final class PortableEvidenceProtocolTests: XCTestCase {
    func testChildEvidenceIsOneCompleteContentAddressedVolume() async throws {
        let (envelope, childCID) = try await evidenceFixture()
        let attachment = try ChildEvidenceVolume(
            envelopeBytes: envelope,
            childCID: childCID
        )
        let broker = MemoryBroker()
        try await attachment.store(storer: broker)
        let fetched = await broker.fetchVolumeLocal(root: attachment.rawCID)
        let volume = try XCTUnwrap(fetched)
        try volume.validate()
        XCTAssertEqual(volume.root, attachment.rawCID)
        XCTAssertEqual(volume.entries.count, 1)
        XCTAssertNotNil(volume.entries[attachment.rawCID])
        let rootData = try XCTUnwrap(volume.entries[attachment.rawCID])
        let framedBytes = 6 + attachment.rawCID.utf8.count + rootData.count
        XCTAssertLessThanOrEqual(
            framedBytes,
            ChildEvidenceVolume.maximumFramedBytes
        )
        XCTAssertEqual(
            ChildEvidenceVolume.maximumArchiveBytes,
            ChildEvidenceVolume.maximumFramedBytes + 2
        )

        let resolved = try ChildEvidenceVolume(
            serialized: volume,
            childCID: childCID
        )
        XCTAssertEqual(resolved.envelopeBytes, envelope)

        let resolvedWithoutExternalHint = try ChildEvidenceVolume(
            serialized: volume
        )
        XCTAssertEqual(resolvedWithoutExternalHint.envelopeBytes, envelope)
        XCTAssertThrowsError(try ChildEvidenceVolume(
            serialized: volume,
            childCID: protocolCID("wrong-child")
        ))
    }

    func testChildEvidenceRootCommitsItsExactProofAndChild() async throws {
        let (envelope, childCID) = try await evidenceFixture()
        let left = try ChildEvidenceVolume(
            envelopeBytes: envelope,
            childCID: childCID
        )
        let right = try ChildEvidenceVolume(
            envelopeBytes: envelope,
            childCID: childCID
        )
        XCTAssertEqual(left.rawCID, right.rawCID)
        XCTAssertEqual(left.serialized.entries, right.serialized.entries)
        XCTAssertNotEqual(
            left.rawCID,
            try ChildEvidenceVolume(
                envelopeBytes: envelope + Data([0]),
                childCID: childCID
            ).rawCID
        )
        XCTAssertNotEqual(
            left.rawCID,
            try ChildEvidenceVolume(
                envelopeBytes: envelope,
                childCID: protocolCID("another-child")
            ).rawCID
        )
    }

    func testChildEvidenceRejectsMembershipDrift() async throws {
        let (envelope, childCID) = try await evidenceFixture()
        let attachment = try ChildEvidenceVolume(
            envelopeBytes: envelope,
            childCID: childCID
        )
        let extra = PublicKey(key: "uncommitted-evidence-member")
        let extraHeader = try HeaderImpl<PublicKey>(node: extra)
        var withExtra = attachment.serialized.entries
        withExtra[extraHeader.rawCID] = try extraHeader.mapToData()
        XCTAssertThrowsError(try ChildEvidenceVolume(
            serialized: SerializedVolume(
                root: attachment.rawCID,
                entries: withExtra
            ),
            childCID: childCID
        ))

        var missing = attachment.serialized.entries
        missing.removeValue(forKey: attachment.rawCID)
        XCTAssertThrowsError(try ChildEvidenceVolume(
            serialized: SerializedVolume(
                root: attachment.rawCID,
                entries: missing
            ),
            childCID: childCID
        ))

        var corrupt = attachment.serialized.entries
        corrupt[attachment.rawCID]?.append(0)
        XCTAssertThrowsError(try ChildEvidenceVolume(
            serialized: SerializedVolume(
                root: attachment.rawCID,
                entries: corrupt
            ),
            childCID: childCID
        ))
    }

    func testPortableAttachmentTopicsStayOnOverlay() {
        for topic in [
            NodeNetworkTopic.portableAttachmentAvailable,
            NodeNetworkTopic.portableAttachmentIndexRequest,
            NodeNetworkTopic.portableAttachmentIndexResponse,
        ] {
            XCTAssertEqual(NodeNetworkTopic.plane(for: topic), .overlay)
        }
    }

    func testParentRunReportsRoundTripAndRefuseWhatNoParentCouldSend() throws {
        let report = ParentRunReportMessage(
            directory: "Payments",
            committerCID: protocolCID("committer"),
            childBlockCID: protocolCID("child-block"),
            grinds: [protocolCID("grind-a"), protocolCID("grind-b")],
            runWork: WorkSum(UInt256(17)),
            ownWork: WorkSum(UInt256(5)),
            revision: 9
        )
        XCTAssertEqual(try ParentRunReportMessage.decoded(report.encoded()), report)
        XCTAssertEqual(NodeNetworkTopic.plane(for: NodeNetworkTopic.parentRunReport), .hierarchy)
        XCTAssertEqual(NodeNetworkTopic.plane(for: NodeNetworkTopic.parentRunReportRequest), .hierarchy)

        func malformed(_ message: ParentRunReportMessage, _ label: String) {
            XCTAssertThrowsError(try message.encoded(), label) { error in
                XCTAssertEqual(error as? NodeNetworkWireError, .malformed, label)
            }
        }
        malformed(ParentRunReportMessage(
            directory: "", committerCID: report.committerCID, childBlockCID: report.childBlockCID,
            grinds: report.grinds, runWork: report.runWork, ownWork: report.ownWork, revision: 9
        ), "empty directory")
        malformed(ParentRunReportMessage(
            directory: "Payments", committerCID: "not-a-cid", childBlockCID: report.childBlockCID,
            grinds: report.grinds, runWork: report.runWork, ownWork: report.ownWork, revision: 9
        ), "non-canonical committer")
        malformed(ParentRunReportMessage(
            directory: "Payments", committerCID: report.committerCID, childBlockCID: report.childBlockCID,
            grinds: [], runWork: report.runWork, ownWork: report.ownWork, revision: 9
        ), "no grinds")
        malformed(ParentRunReportMessage(
            directory: "Payments", committerCID: report.committerCID, childBlockCID: report.childBlockCID,
            grinds: [protocolCID("grind-a"), protocolCID("grind-a")], runWork: report.runWork,
            ownWork: report.ownWork, revision: 9
        ), "duplicate grind")
        malformed(ParentRunReportMessage(
            directory: "Payments", committerCID: report.committerCID, childBlockCID: report.childBlockCID,
            grinds: report.grinds, runWork: WorkSum(UInt256(4)), ownWork: WorkSum(UInt256(5)), revision: 9
        ), "own exceeds run: no honest run does that")

        let request = ParentRunReportRequestMessage(
            requestID: 3, committerCIDs: [protocolCID("committer"), protocolCID("committer-2")]
        )
        XCTAssertEqual(try ParentRunReportRequestMessage.decoded(request.encoded()), request)
        XCTAssertThrowsError(try ParentRunReportRequestMessage(requestID: 0, committerCIDs: [protocolCID("c")]).encoded())
        XCTAssertThrowsError(try ParentRunReportRequestMessage(requestID: 3, committerCIDs: []).encoded())
        XCTAssertThrowsError(try ParentRunReportRequestMessage(
            requestID: 3, committerCIDs: [protocolCID("c"), protocolCID("c")]
        ).encoded())
        // Bounded by what a correct child can ask: one more is malformed, not slow.
        let atBound = (0..<maximumParentRunReportRequestCommitters).map { protocolCID("bound-\($0)") }
        XCTAssertNoThrow(try ParentRunReportRequestMessage(requestID: 4, committerCIDs: atBound).encoded())
        XCTAssertThrowsError(try ParentRunReportRequestMessage(
            requestID: 5, committerCIDs: atBound + [protocolCID("one-too-many")]
        ).encoded())
    }

    func testParentChainFactsAreExactSessionBoundQueries() throws {
        let genesis = ParentChainFactMessage(
            requestID: 1,
            fact: .genesis(
                childGenesisCID: protocolCID("child-genesis"),
                parentStateCID: protocolCID("deployment-parent-state")
            )
        )
        XCTAssertEqual(
            try ParentChainFactMessage.decoded(genesis.encoded()),
            genesis
        )

        let continuity = ParentChainFactMessage(
            requestID: 2,
            fact: .continuity(
                fromStateCID: LatticeState.emptyHeader.rawCID,
                toStateCID: protocolCID("to-state")
            )
        )
        XCTAssertEqual(
            try ParentChainFactMessage.decoded(continuity.encoded()),
            continuity
        )
        XCTAssertEqual(
            NodeNetworkTopic.plane(for: NodeNetworkTopic.parentChainFactRequest),
            .hierarchy
        )
        XCTAssertEqual(
            NodeNetworkTopic.plane(for: NodeNetworkTopic.parentChainFactResponse),
            .hierarchy
        )

        XCTAssertThrowsError(try ParentChainFactMessage(
            requestID: 0,
            fact: genesis.fact
        ).encoded())
        XCTAssertThrowsError(try ParentChainFactMessage(
            requestID: 4,
            fact: .continuity(
                fromStateCID: protocolCID("same-state"),
                toStateCID: protocolCID("same-state")
            )
        ).encoded())
        // A general reachability question is not a shape this protocol
        // defines: every child block anchors at the parent chain's genesis,
        // so any other `from` is malformed. This is what keeps a served
        // continuity query O(1) instead of an ancestry walk run for a peer.
        XCTAssertThrowsError(try ParentChainFactMessage(
            requestID: 5,
            fact: .continuity(
                fromStateCID: protocolCID("from-state"),
                toStateCID: protocolCID("to-state")
            )
        ).encoded())
    }



    func testPortableAttachmentVocabularyIsCanonicalAndCursorBound() throws {
        let attachments = [
            PortableAttachmentSummary(
                edgeCID: protocolCID("portable-edge-a"),
                rootCID: protocolCID("portable-root-a"),
                attachmentCID: protocolCID("portable-attachment-a")
            ),
            PortableAttachmentSummary(
                edgeCID: protocolCID("portable-edge-b"),
                rootCID: protocolCID("portable-root-b"),
                attachmentCID: protocolCID("portable-attachment-b")
            ),
            PortableAttachmentSummary(
                edgeCID: protocolCID("portable-edge-c"),
                rootCID: protocolCID("portable-root-c"),
                attachmentCID: protocolCID("portable-attachment-c")
            ),
        ].sorted {
            ($0.edgeCID, $0.rootCID) < ($1.edgeCID, $1.rootCID)
        }
        let cursor = attachments[0]
        let page = [attachments[1]]

        let indexRequest = PortableAttachmentIndexRequestMessage(
            requestID: 1,
            after: cursor
        )
        XCTAssertEqual(
            try PortableAttachmentIndexRequestMessage.decoded(
                indexRequest.encoded()
            ),
            indexRequest
        )

        let indexResponse = PortableAttachmentIndexResponseMessage(
            requestID: 1,
            after: cursor,
            entries: page,
            hasMore: true
        )
        XCTAssertEqual(
            try PortableAttachmentIndexResponseMessage.decoded(
                indexResponse.encoded()
            ),
            indexResponse
        )

        let available = PortableAttachmentAvailableMessage(
            edgeCID: page[0].edgeCID,
            rootCID: page[0].rootCID,
            attachmentCID: page[0].attachmentCID
        )
        XCTAssertEqual(
            try PortableAttachmentAvailableMessage.decoded(available.encoded()),
            available
        )

        // Over the page cap throws — built cap-relative so it survives page-size
        // changes (canonical CIDs distinct per index so the entries stay sorted
        // and unique, the other bounds validate() enforces).
        let overCap = (0...PortableAttachmentIndexResponseMessage.maximumEntries)
            .map { i in
                PortableAttachmentSummary(
                    edgeCID: protocolCID("overcap-edge-\(i)"),
                    rootCID: protocolCID("overcap-root-\(i)"),
                    attachmentCID: protocolCID("overcap-attachment-\(i)")
                )
            }
            .sorted { ($0.edgeCID, $0.rootCID) < ($1.edgeCID, $1.rootCID) }
        XCTAssertThrowsError(try PortableAttachmentIndexResponseMessage(
            requestID: 1,
            after: cursor,
            entries: overCap,
            hasMore: false
        ).encoded())
        XCTAssertThrowsError(try PortableAttachmentIndexResponseMessage(
            requestID: 1,
            after: cursor,
            entries: [],
            hasMore: true
        ).encoded())
        XCTAssertThrowsError(try PortableAttachmentAvailableMessage(
            edgeCID: "not-a-canonical-cid",
            rootCID: page[0].rootCID,
            attachmentCID: page[0].attachmentCID
        ).encoded())

        var nonCanonical = try available.encoded()
        nonCanonical.append(0x20)
        XCTAssertThrowsError(
            try PortableAttachmentAvailableMessage.decoded(nonCanonical)
        ) { error in
            XCTAssertEqual(error as? NodeNetworkWireError, .nonCanonical)
        }
    }

    func testPortableAttachmentLocateRequestIsCanonicalAndCIDBound() throws {
        let request = PortableAttachmentLocateRequestMessage(
            requestID: 9,
            childCID: protocolCID("locate-child")
        )
        XCTAssertEqual(
            try PortableAttachmentLocateRequestMessage.decoded(request.encoded()),
            request
        )
        XCTAssertEqual(
            NodeNetworkTopic.plane(
                for: NodeNetworkTopic.portableAttachmentLocateRequest
            ),
            .overlay
        )
        XCTAssertThrowsError(try PortableAttachmentLocateRequestMessage(
            requestID: 0,
            childCID: protocolCID("locate-child")
        ).encoded())
        XCTAssertThrowsError(try PortableAttachmentLocateRequestMessage(
            requestID: 9,
            childCID: "not-a-canonical-cid"
        ).encoded())

        var nonCanonical = try request.encoded()
        nonCanonical.append(0x20)
        XCTAssertThrowsError(
            try PortableAttachmentLocateRequestMessage.decoded(nonCanonical)
        ) { error in
            XCTAssertEqual(error as? NodeNetworkWireError, .nonCanonical)
        }
    }

    func testEvidenceProofCapMatchesTransportCapacityNotOneFrame() {
        let frame = Int(IvyConfig.defaultProtocolMaxFrameSize)
        // The old cap was a single frame — the original wedge. A legitimate
        // deep multi-hop proof exceeds one frame; the volume-archive transport
        // chunks the evidence across frames, so the hard proof cap must exceed
        // one frame...
        XCTAssertGreaterThan(
            ChildValidationPackageEnvelope.maximumEncodedSize, frame
        )
        // ...and so must the operator acceptance budget, or the receiver's
        // decode (the min of the two) still wedges at one frame.
        XCTAssertGreaterThan(
            NodeResourcePolicy.default.maximumParentWitnessBytes, frame
        )
        // The wrapped evidence Volume must stay under the transport's archive
        // ceiling (16 frames) so the archive never rejects it.
        XCTAssertLessThanOrEqual(
            ChildEvidenceVolume.maximumArchiveBytes, frame * 16
        )
    }

    private func evidenceFixture() async throws
        -> (envelope: Data, childCID: String) {
        let source = MemoryBroker()
        try await LatticeState.emptyHeader.storeRecursively(
            storer: source
        )
        let block = try await NexusGenesis.create(
            fetcher: source
        ).block
        let childCID = try BlockHeader(node: block).rawCID
        return (
            Data("envelope".utf8),
            childCID
        )
    }
}
