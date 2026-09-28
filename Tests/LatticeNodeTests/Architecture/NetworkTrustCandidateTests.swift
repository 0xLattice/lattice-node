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

private actor MinimumWorkRecorder {
    private var values: [[MiningMinimumWork]] = []

    func record(_ value: [MiningMinimumWork]) {
        values.append(value)
    }

    func last() -> [MiningMinimumWork]? { values.last }
    func count() -> Int { values.count }
}

private actor HierarchyVolumeProbe: IvyDelegate, IvyContentSource {
    private let hello: Data
    private var helloCount = 0
    private var volumeRequests = 0

    init(hello: Data) {
        self.hello = hello
    }

    func ivy(
        _ ivy: Ivy,
        didReceiveMessage message: PeerMessage,
        from peer: AuthenticatedPeer
    ) async {
        switch message.topic {
        case NodeNetworkTopic.hierarchyHello:
            helloCount += 1
            _ = await ivy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.hierarchyHello,
                payload: hello
            )
        case NodeNetworkTopic.childEvidenceIndexRequest:
            guard let request = try? ChildEvidenceIndexRequestMessage.decoded(
                message.payload
            ), let response = try? ChildEvidenceIndexResponseMessage(
                requestID: request.requestID,
                childPath: request.childPath,
                sourceID: testEvidenceSourceID,
                cursor: 0,
                through: 0,
                entries: [],
                next: 0
            ).encoded() else { return }
            _ = await ivy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.childEvidenceIndexResponse,
                payload: response
            )
        default:
            break
        }
    }

    func content(
        rootCID: String,
        cids: [String],
        maxDataBytes: Int
    ) -> [ContentEntry] {
        []
    }

    func volume(rootCID: String, maxDataBytes: Int) -> [ContentEntry] {
        volumeRequests += 1
        return []
    }

    func didReceiveHello() -> Bool { helloCount > 0 }
    func resetVolumeRequests() { volumeRequests = 0 }
    func volumeRequestCount() -> Int { volumeRequests }
}

/// Answers nothing until released (at teardown), long after any request
/// deadline.
private struct StallingContentSource: IvyContentSource {
    let release: Latch

    func content(rootCID: String, cids: [String], maxDataBytes: Int) async -> [ContentEntry] {
        await release.wait()
        return []
    }

    func volume(rootCID: String, maxDataBytes: Int) async -> [ContentEntry] {
        await release.wait()
        return []
    }
}

/// A gate a test closes and opens: while closed, every request waits.
private actor ContentGate {
    private var closed = false
    private var refusing = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func close() { closed = true }

    /// Answer every request with nothing (content unavailable).
    func refuse() { refusing = true }

    func open() {
        closed = false
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    /// Whether the request may be served (after waiting while closed).
    func pass() async -> Bool {
        guard !refusing else { return false }
        guard closed else { return true }
        await withCheckedContinuation { waiters.append($0) }
        return !refusing
    }
}

/// Serves `inner` once `gate` lets each request through.
private struct GatedContentSource: IvyContentSource {
    let inner: any IvyContentSource
    let gate: ContentGate

    func content(rootCID: String, cids: [String], maxDataBytes: Int) async -> [ContentEntry] {
        guard await gate.pass() else { return [] }
        return await inner.content(rootCID: rootCID, cids: cids, maxDataBytes: maxDataBytes)
    }

    func volume(rootCID: String, maxDataBytes: Int) async -> [ContentEntry] {
        guard await gate.pass() else { return [] }
        return await inner.volume(rootCID: rootCID, maxDataBytes: maxDataBytes)
    }
}

/// Serves one Volume (a portable attachment) and records that it did.
private actor AttachmentSource: IvyContentSource {
    private let root: String
    private let entries: [String: Data]
    private var served = false

    init(root: String, entries: [String: Data]) {
        self.root = root
        self.entries = entries
    }

    func wasServed() -> Bool { served }

    func content(rootCID: String, cids: [String], maxDataBytes: Int) async -> [ContentEntry] {
        []
    }

    func volume(rootCID: String, maxDataBytes: Int) async -> [ContentEntry] {
        guard rootCID == root else { return [] }
        served = true
        return entries.sorted { $0.key < $1.key }.map {
            ContentEntry(cid: $0.key, data: $0.value)
        }
    }
}

/// Forwards everything to `inner` and records the parent tip contexts it
/// receives: each one's tip and the carried block it names.
private final class ParentTipRecordingDelegate: IvyDelegate, @unchecked Sendable {
    struct Received: Equatable {
        let tipCID: String
        let carried: String?
    }

    private let inner: NodeNetworkRuntime
    private let lock = NSLock()
    private var received: [Received] = []

    init(forwardingTo inner: NodeNetworkRuntime) {
        self.inner = inner
    }

    var contexts: [Received] { lock.withLock { received } }

    func contexts(forTip tipCID: String) -> [Received] {
        contexts.filter { $0.tipCID == tipCID }
    }

    func reset() { lock.withLock { received.removeAll() } }

    func ivy(_ ivy: Ivy, didConnect peer: AuthenticatedPeer) async {
        await inner.ivy(ivy, didConnect: peer)
    }

    func ivy(_ ivy: Ivy, didDisconnect peer: PeerID) {
        inner.ivy(ivy, didDisconnect: peer)
    }

    func ivy(_ ivy: Ivy, didDiscoverPublicAddress address: ObservedAddress) {
        inner.ivy(ivy, didDiscoverPublicAddress: address)
    }

    func ivy(
        _ ivy: Ivy,
        didReceiveMessage message: PeerMessage,
        from peer: AuthenticatedPeer
    ) async {
        if message.topic == NodeNetworkTopic.parentTipAvailable,
           let context = try? ParentTipContextMessage.decoded(message.payload) {
            lock.withLock {
                received.append(Received(
                    tipCID: context.tipCID, carried: context.carriedChildCID
                ))
            }
        }
        await inner.ivy(ivy, didReceiveMessage: message, from: peer)
    }
}

/// Names the child block whose evidence attachment the parent will not
/// serve.
private actor EvidenceAttachmentGate {
    private(set) var refusedChild: String?

    func refuse(_ childCID: String) { refusedChild = childCID }
}

/// Serves the parent's content, except the attachment Volume of the
/// evidence it issued for the gate's child block: that request is answered
/// with nothing (content unavailable), so the child's recovery of that
/// evidence ends `.unavailable` and the session is kept.
private struct EvidenceRefusingContentSource: IvyContentSource {
    let parent: ChainProcess
    let gate: EvidenceAttachmentGate

    private var inner: ChainProcessIvyContentSource {
        ChainProcessIvyContentSource(process: parent)
    }

    func content(rootCID: String, cids: [String], maxDataBytes: Int) async -> [ContentEntry] {
        await inner.content(rootCID: rootCID, cids: cids, maxDataBytes: maxDataBytes)
    }

    func volume(rootCID: String, maxDataBytes: Int) async -> [ContentEntry] {
        if let child = await gate.refusedChild,
           let issued = try? await parent.store.issuedChildEvidenceSummary(
               childCID: child, directory: "Payments"
           ),
           issued.summary.attachmentCID == rootCID {
            return []
        }
        return await inner.volume(rootCID: rootCID, maxDataBytes: maxDataBytes)
    }
}

/// Counts the parent's serves of the attachment Volume of the evidence it
/// issued for `childCID`, and stalls the serve of `stalledRoot` until
/// `release` opens (then answers nothing: content unavailable).
private actor EvidenceServeProbe {
    private(set) var carriedChild: String?
    private(set) var serves = 0
    private(set) var stalledRoot: String?
    let release = Latch()

    func watch(_ childCID: String) { carriedChild = childCID }
    func stall(_ rootCID: String) { stalledRoot = rootCID }
    func served() { serves += 1 }
}

private struct ProbedContentSource: IvyContentSource {
    let parent: ChainProcess
    let probe: EvidenceServeProbe

    private var inner: ChainProcessIvyContentSource {
        ChainProcessIvyContentSource(process: parent)
    }

    func content(rootCID: String, cids: [String], maxDataBytes: Int) async -> [ContentEntry] {
        await inner.content(rootCID: rootCID, cids: cids, maxDataBytes: maxDataBytes)
    }

    func volume(rootCID: String, maxDataBytes: Int) async -> [ContentEntry] {
        if await probe.stalledRoot == rootCID {
            await probe.release.wait()
            return []
        }
        if let child = await probe.carriedChild,
           let issued = try? await parent.store.issuedChildEvidenceSummary(
               childCID: child, directory: "Payments"
           ),
           issued.summary.attachmentCID == rootCID {
            await probe.served()
        }
        return await inner.volume(rootCID: rootCID, maxDataBytes: maxDataBytes)
    }
}

/// On until switched off; a recovery-iteration hook reads it.
private actor RearmSwitch {
    private(set) var isOn = true
    func turnOff() { isOn = false }
}

/// A one-way switch a test flips and an admission closure reads.
private actor DecisionSwitch {
    private(set) var isOn = false
    func turnOn() { isOn = true }
}

private struct ProvisionalRootFixture {
    let childConfiguration: NodeConfiguration
    let parentRuntime: NodeNetworkRuntime
    let childRuntime: NodeNetworkRuntime
    let parentProcess: ChainProcess
    let childProcess: ChainProcess
    let context: ChildCandidateRequestContext
    let candidate: DirectChildCandidate
}

final class NetworkTrustCandidateTests: NetworkTrustTestCase {
    func testContextualCandidateWireBindsCarrierRewardAndCommittedContent() async throws {
        let parent = try await canonicalNetworkBlock()
        let parentCID = try BlockHeader(node: parent).rawCID
        let parentData = try XCTUnwrap(parent.toData())
        let childReward = MiningReward(
            chainPath: ["Nexus", "Payments"],
            transaction: try unsignedTransaction(path: ["Nexus", "Payments"])
        )
        let descendantReward = MiningReward(
            chainPath: ["Nexus", "Payments", "Receipts"],
            transaction: try unsignedTransaction(
                path: ["Nexus", "Payments", "Receipts"]
            )
        )
        let request = ParentTipContextMessage(
            sequence: 11,
            childPath: ["Nexus", "Payments"],
            tipCID: parentCID,
            tipData: parentData,
            rewards: [childReward, descendantReward]
        )
        let decodedRequest = try ParentTipContextMessage.decoded(
            request.encoded()
        )
        XCTAssertEqual(decodedRequest.sequence, 11)
        XCTAssertEqual(decodedRequest.rewards.map(\.chainPath), [
            ["Nexus", "Payments"],
            ["Nexus", "Payments", "Receipts"],
        ])
        XCTAssertNotNil(decodedRequest.rewards[0].transaction.body.node)

        let response = ChildCandidateAvailableMessage(
            sequence: 11,
            childPath: ["Nexus", "Payments"],
            childCID: parentCID,
            blockData: parentData,
            searchWitness: nil
        )
        let decodedResponse = try ChildCandidateAvailableMessage.decoded(
            response.encoded()
        )
        XCTAssertEqual(decodedResponse.childCID, parentCID)
        XCTAssertNil(decodedResponse.searchWitness)

        var forgedTarget = try response.encoded()
        let targetOffset = 8 + 2
            + (2 + "Nexus".utf8.count)
            + (2 + "Payments".utf8.count)
            + 2 + parentCID.utf8.count
        forgedTarget.insert(
            contentsOf: Data(repeating: 0x66, count: 64),
            at: targetOffset
        )
        XCTAssertThrowsError(
            try ChildCandidateAvailableMessage.decoded(forgedTarget)
        )

        XCTAssertThrowsError(try ParentTipContextMessage(
            sequence: 12,
            childPath: ["Nexus", "Payments"],
            tipCID: parentCID,
            tipData: parentData,
            rewards: [MiningReward(
                chainPath: ["Nexus", "Other"],
                transaction: try unsignedTransaction(path: ["Nexus", "Other"])
            )]
        ).encoded())
    }

    func testCandidateWireRejectsMismatchedAndOversizedContent() async throws {
        let block = try await canonicalNetworkBlock()
        let childCID = try BlockHeader(node: block).rawCID
        let blockData = try XCTUnwrap(block.toData())
        func candidate(_ data: Data) -> ChildCandidateAvailableMessage {
            ChildCandidateAvailableMessage(
                sequence: 19,
                childPath: ["Nexus", "Payments"],
                childCID: childCID,
                blockData: data,
                searchWitness: nil
            )
        }

        XCTAssertThrowsError(try candidate(blockData + Data([0])).encoded())
        XCTAssertThrowsError(try candidate(
            Data(repeating: 0, count: Int(IvyConfig.defaultProtocolMaxFrameSize))
        ).encoded())

        XCTAssertThrowsError(try ChildEvidenceAvailableMessage(
            childPath: ["Nexus", "Payments"],
            sourceID: testEvidenceSourceID,
            ordinal: 1,
            childCID: childCID,
            rootCID: childCID,
            attachmentCID: "not-a-cid"
        ).encoded()) { error in
            XCTAssertEqual(error as? NodeNetworkWireError, .malformed)
        }
    }

    /// A miner's minimum work rides the candidate request only when it has
    /// entries, so a request without one keeps the exact bytes it always had.
    func testCandidateRequestCarriesMinimumWorkOnlyWhenPresent() async throws {
        let parent = try await canonicalNetworkBlock()
        let parentCID = try BlockHeader(node: parent).rawCID
        let parentData = try XCTUnwrap(parent.toData())
        func request(
            _ minimumWork: [MiningMinimumWork]
        ) -> ParentTipContextMessage {
            ParentTipContextMessage(
                sequence: 21,
                childPath: ["Nexus", "Payments"],
                tipCID: parentCID,
                tipData: parentData,
                rewards: [],
                minimumWork: minimumWork
            )
        }

        let legacy = try request([]).encoded()
        XCTAssertEqual(legacy.suffix(parentData.count), parentData)
        XCTAssertTrue(
            try ParentTipContextMessage.decoded(legacy).minimumWork.isEmpty
        )

        let entries = [
            MiningMinimumWork(
                chainPath: ["Nexus", "Payments"],
                work: UInt256(1) << 32
            ),
            MiningMinimumWork(
                chainPath: ["Nexus", "Payments", "Receipts"],
                work: UInt256(9)
            ),
        ]
        let encoded = try request(entries).encoded()
        XCTAssertGreaterThan(encoded.count, legacy.count)
        XCTAssertEqual(
            try ParentTipContextMessage.decoded(encoded).minimumWork,
            entries
        )

        // Another subtree, zero work, a truncated trailer, and an empty one
        // (which a present-only-when-used field can never encode) are refused.
        XCTAssertThrowsError(try request([MiningMinimumWork(
            chainPath: ["Nexus", "Other"],
            work: UInt256(1)
        )]).encoded())
        XCTAssertThrowsError(try request([MiningMinimumWork(
            chainPath: ["Nexus", "Payments"],
            work: .zero
        )]).encoded())
        // More work than the hardest valid target (1) can represent.
        XCTAssertThrowsError(try request([MiningMinimumWork(
            chainPath: ["Nexus", "Payments"],
            work: workForTarget(UInt256(1)) + UInt256(1)
        )]).encoded())
        // Beyond the payload cap the rewards field also honours.
        XCTAssertThrowsError(try request((0..<20_000).map {
            MiningMinimumWork(
                chainPath: ["Nexus", "Payments", "d\($0)"],
                work: UInt256(1) << 16
            )
        }).encoded())
        XCTAssertThrowsError(
            try ParentTipContextMessage.decoded(encoded + Data([0]))
        )

        // The operator's opt-in to commit the minimum-work target is one
        // The wire carries a search plan and nothing more: there is no
        // trailing commit byte, so a filter cannot travel as a commitment.
        XCTAssertEqual(
            try ParentTipContextMessage.decoded(encoded).minimumWork,
            entries
        )
        XCTAssertThrowsError(
            try ParentTipContextMessage.decoded(encoded + Data([1])),
            "a trailing byte is not part of this message"
        )
        XCTAssertEqual(
            try ParentTipContextMessage(
                sequence: 21,
                childPath: ["Nexus", "Payments"],
                tipCID: parentCID,
                tipData: parentData,
                rewards: []
            ).encoded(),
            legacy
        )
        XCTAssertThrowsError(
            try ParentTipContextMessage.decoded(legacy + Data([1]))
        )
        // An empty minimum-work trailer (tag 1, length 4, "[]") and an empty
        // carried-child trailer (tag 2, length 0) are refused alike.
        var emptyTrailer = legacy
        emptyTrailer.append(contentsOf: [1, 2, 0, 0, 0])
        emptyTrailer.append(Data("[]".utf8))
        XCTAssertThrowsError(
            try ParentTipContextMessage.decoded(emptyTrailer)
        )
        XCTAssertThrowsError(
            try ParentTipContextMessage.decoded(legacy + Data([2, 0, 0]))
        )
    }

    /// The carried child rides the context as a tagged trailer after the
    /// minimum work, only when the tip's branch carried one, and always
    /// with the evidence the parent issued for it (the v2 topic): the
    /// legacy bytes are untouched, the trailer round-trips and re-encodes
    /// byte for byte, trailers are ordered and single, and the v1 shape (a
    /// bare name), an unknown tag, a truncated or a non-canonical summary
    /// are refused.
    func testCandidateRequestNamesTheCarriedChildWithItsEvidence() async throws {
        XCTAssertEqual(
            NodeNetworkTopic.parentTipAvailable,
            "lattice.hierarchy.parent-tip.available.v2"
        )
        let parent = try await canonicalNetworkBlock()
        let parentCID = try BlockHeader(node: parent).rawCID
        let parentData = try XCTUnwrap(parent.toData())
        let minimumWork = [MiningMinimumWork(
            chainPath: ["Nexus", "Payments"],
            work: UInt256(1) << 32
        )]
        let evidence = CarriedChildEvidence(
            sourceID: testEvidenceSourceID,
            summary: IssuedChildEvidenceSummary(
                ordinal: 7,
                childCID: testCID("carried-child"),
                rootCID: testCID("carried-root"),
                attachmentCID: testCID("carried-attachment")
            )
        )
        func request(
            _ carried: CarriedChildEvidence?,
            minimumWork: [MiningMinimumWork] = []
        ) -> ParentTipContextMessage {
            ParentTipContextMessage(
                sequence: 23,
                childPath: ["Nexus", "Payments"],
                tipCID: parentCID,
                tipData: parentData,
                rewards: [],
                minimumWork: minimumWork,
                carriedEvidence: carried
            )
        }

        let legacy = try request(nil).encoded()
        XCTAssertEqual(legacy.suffix(parentData.count), parentData)
        XCTAssertNil(try ParentTipContextMessage.decoded(legacy).carriedEvidence)

        let named = try request(evidence).encoded()
        let decoded = try ParentTipContextMessage.decoded(named)
        XCTAssertEqual(decoded.carriedEvidence, evidence)
        XCTAssertEqual(decoded.carriedChildCID, evidence.childCID)
        XCTAssertEqual(try decoded.encoded(), named, "canonical re-encode")
        let summary = evidence.summary
        XCTAssertEqual(
            named.count,
            legacy.count + 1
                + [summary.childCID, evidence.sourceID, summary.rootCID,
                   summary.attachmentCID].reduce(0) { $0 + 2 + $1.utf8.count }
                + 8,
            "one tag, four length-prefixed atoms, the ordinal"
        )
        let both = try request(evidence, minimumWork: minimumWork).encoded()
        let decodedBoth = try ParentTipContextMessage.decoded(both)
        XCTAssertEqual(decodedBoth.minimumWork, minimumWork)
        XCTAssertEqual(decodedBoth.carriedEvidence, evidence)
        XCTAssertEqual(try decodedBoth.encoded(), both)

        // The v1 shape: the carried trailer as a bare name.
        var v1 = legacy
        v1.append(2)
        let nameLength = UInt16(summary.childCID.utf8.count)
        v1.append(contentsOf: [UInt8(nameLength & 0xff), UInt8(nameLength >> 8)])
        v1.append(Data(summary.childCID.utf8))
        XCTAssertThrowsError(try ParentTipContextMessage.decoded(v1))
        // Trailers out of order: the carried child before the minimum work.
        let workOnly = try request(nil, minimumWork: minimumWork).encoded()
        var reordered = legacy
        reordered.append(named.suffix(from: legacy.count))
        reordered.append(workOnly.suffix(from: legacy.count))
        XCTAssertThrowsError(try ParentTipContextMessage.decoded(reordered))
        // The same trailer twice.
        var twice = named
        twice.append(named.suffix(from: legacy.count))
        XCTAssertThrowsError(try ParentTipContextMessage.decoded(twice))
        // An unknown tag, a truncated summary, trailing bytes.
        XCTAssertThrowsError(
            try ParentTipContextMessage.decoded(legacy + Data([3, 1, 0]))
        )
        XCTAssertThrowsError(
            try ParentTipContextMessage.decoded(named.dropLast())
        )
        XCTAssertThrowsError(
            try ParentTipContextMessage.decoded(named + Data([0]))
        )
        // Summaries the encoder refuses: a zero ordinal, a sourceID that is
        // no UUID, a non-canonical CID.
        func with(
            sourceID: String? = nil,
            ordinal: UInt64? = nil,
            rootCID: String? = nil
        ) -> CarriedChildEvidence {
            CarriedChildEvidence(
                sourceID: sourceID ?? evidence.sourceID,
                summary: IssuedChildEvidenceSummary(
                    ordinal: ordinal ?? summary.ordinal,
                    childCID: summary.childCID,
                    rootCID: rootCID ?? summary.rootCID,
                    attachmentCID: summary.attachmentCID
                )
            )
        }
        XCTAssertThrowsError(try request(with(ordinal: 0)).encoded())
        XCTAssertThrowsError(try request(with(sourceID: "not-a-uuid")).encoded())
        XCTAssertThrowsError(try request(with(rootCID: "Qm-not-canonical")).encoded())
        // The same refusals on the wire: a zero ordinal patched in.
        var zeroOrdinal = named
        let ordinalStart = legacy.count + 1
            + 2 + summary.childCID.utf8.count
            + 2 + evidence.sourceID.utf8.count
        zeroOrdinal.replaceSubrange(
            ordinalStart..<(ordinalStart + 8), with: Data(repeating: 0, count: 8)
        )
        XCTAssertThrowsError(try ParentTipContextMessage.decoded(zeroOrdinal))
    }

    func testCandidateRequestEnforcesHierarchyRewardAndFrameBounds() async throws {
        XCTAssertEqual(
            ParentTipContextMessage.maximumRewardBytes,
            ChainServiceLimits.maximumPayloadBytes
        )
        let parent = try await canonicalNetworkBlock()
        let parentCID = try BlockHeader(node: parent).rawCID
        let parentData = try XCTUnwrap(parent.toData())
        let maximumDepthPath = ["Nexus"] + Array(
            repeating: String(repeating: "x", count: 64),
            count: 256
        )
        let valid = try ParentTipContextMessage(
            sequence: 15,
            childPath: maximumDepthPath,
            tipCID: parentCID,
            tipData: parentData,
            rewards: []
        ).encoded()
        XCTAssertLessThan(
            valid.count,
            ParentTipContextMessage.maximumEncodedBytes
        )

        // The reward list has no invented count cap; it is bounded structurally by
        // the wire capacity (UInt16 count prefix) and the reward-byte cap. The
        // total message is still bounded by the frame size below.
        XCTAssertThrowsError(try ParentTipContextMessage.decoded(Data(
            repeating: 0,
            count: ParentTipContextMessage.maximumEncodedBytes + 1
        ))) { error in
            XCTAssertEqual(error as? NodeNetworkWireError, .oversized)
        }
    }

    func testCandidateSlotsGiveEveryPathOnePeerBeforeDuplicateClaims() {
        let slots = NodeNetworkRuntime.interleavedChildPeerIndices(
            peerCounts: [4] + Array(repeating: 1, count: 63),
            limit: 64
        )
        XCTAssertEqual(slots.count, 64)
        XCTAssertEqual(Set(slots.map(\.path)).count, 64)
        XCTAssertTrue(slots.allSatisfy { $0.peer == 0 })
    }

    func testCandidateFetcherIsBoundedFIFOAndDeduplicated() throws {
        var fetcher = BlockFetcher()
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "first",
            package: nil
        )).accepted)
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "second",
            package: nil
        )).accepted)
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "first",
            package: nil
        )).accepted)
        let first = try XCTUnwrap(fetcher.next())
        XCTAssertEqual(first.blockCID, "first")
        XCTAssertTrue(fetcher.complete(
            first.ticket,
            resolution: .terminal
        ))
        let second = try XCTUnwrap(fetcher.next())
        XCTAssertEqual(second.blockCID, "second")
        XCTAssertTrue(fetcher.complete(
            second.ticket,
            resolution: .terminal
        ))
        XCTAssertNil(fetcher.next())

        for index in 0..<BlockFetcher.readyCapacity {
            XCTAssertTrue(fetcher.observe(.init(
                blockCID: "cid-\(index)",
                package: nil
            )).accepted)
        }
        XCTAssertFalse(fetcher.observe(.init(
            blockCID: "overflow",
            package: nil
        )).accepted)
    }

    func testProofPreparationRotatesAcrossMoreThanSixtyFourChildPaths() {
        let first = NodeNetworkRuntime.rotatedPeerIndices(
            peerCount: 65,
            start: 0,
            limit: 64
        )
        let second = NodeNetworkRuntime.rotatedPeerIndices(
            peerCount: 65,
            start: first.next,
            limit: 64
        )
        XCTAssertEqual(first.indices.count, 64)
        XCTAssertFalse(first.indices.contains(64))
        XCTAssertTrue(second.indices.contains(64))
        XCTAssertFalse(second.indices.contains(0))
    }

    func testDisconnectedChildPathsCannotAccumulatePeerRotationState() {
        var rotations = Dictionary(uniqueKeysWithValues: (0..<1_000).map {
            ("Nexus/stale-\($0)", $0)
        })
        rotations["Nexus/active"] = 3
        NodeNetworkRuntime.pruneChildPeerRotations(
            &rotations,
            activeRoles: [.child(["Nexus", "active"])]
        )
        XCTAssertEqual(rotations, ["Nexus/active": 3])
    }

    /// A child never asks for a parent template. The parent pushes its
    /// context (its validated tip) when the child wires in; the child builds
    /// its candidate against the tip's post-state, reading the tip from the
    /// parent's own session and nothing from anyone else, and pushes the
    /// candidate up; the parent's next template finds it already held.
    func testChildPushesACandidateForThePushedParentTipAndTheParentHoldsIt()
        async throws
    {
        let descendantKey = signingKey(0x91)
        let fixture = try await provisionalRootFixture(keyByte: 0x8f)
        let parentTip = try await fixture.parentProcess.validatedTipBlock()
        let parentTipCID = try BlockHeader(node: parentTip).rawCID
        let builds = NetworkEventRecorder()
        let childHandlers = ClosureChainInterface(
            childCandidateBuilder: { context, parentSource in
                // The carrier the child builds against is the parent's tip's
                // post-state, and the tip itself is fetched from the parent.
                guard context.parentCarrier.prevState.rawCID
                    == parentTip.postState.rawCID else {
                    throw NetworkTestError.failedPhase("carrier on the parent tip")
                }
                let fetched = await parentSource.fetch([parentTipCID])
                guard fetched[parentTipCID] == parentTip.toData() else {
                    throw NetworkTestError.failedPhase(
                        "parent tip content from the parent session"
                    )
                }
                await builds.append(parentTipCID)
                return fixture.candidate
            },
            admission: { _ in throw CancellationError() }
        )
        let descendantHello = try ChainHello(
            nexusGenesisCID: fixture.childConfiguration.nexusGenesisCID,
            chainPath: fixture.childConfiguration.chainPath + ["Leaf"]
        ).encode()
        let probe = HierarchyVolumeProbe(hello: descendantHello)
        let descendant = Ivy(config: IvyConfig(
            signingKey: descendantKey,
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            privateContentExchangeEnabled: true,
            mode: .privateNetwork
        ))
        await descendant.installTestDelegate(probe)
        await descendant.setContentSource(probe)

        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess,
                chain: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                chain: childHandlers
            )
            try await descendant.start()
            try await descendant.connect(to: PeerEndpoint(
                publicKey: fixture.childConfiguration.processPublicKey,
                host: "127.0.0.1",
                port: fixture.childConfiguration.factListenPort
            ))
            for _ in 0..<250 {
                if await probe.didReceiveHello() { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard await probe.didReceiveHello() else {
                throw NetworkTestError.failedPhase("descendant hierarchy hello")
            }
            await probe.resetVolumeRequests()

            // No template was requested, and the parent asked for nothing:
            // the candidate is simply held once the child pushed it.
            try await waitForChildCandidate(fixture)
            let candidates = await fixture.parentRuntime.directChildCandidates(
                fixture.context
            )
            let descendantVolumeRequests = await probe.volumeRequestCount()
            XCTAssertEqual(candidates.count, 1)
            XCTAssertEqual(descendantVolumeRequests, 0)
            let buildsAfterFirst = await builds.snapshot().count
            XCTAssertEqual(buildsAfterFirst, 1, "built once per context")
            // Asking again costs no round trip and no rebuild.
            let again = await fixture.parentRuntime.directChildCandidates(
                fixture.context
            )
            XCTAssertEqual(again.count, 1)
            let buildsAfterSecond = await builds.snapshot().count
            XCTAssertEqual(buildsAfterSecond, 1)
            let digestInput = await fixture.parentRuntime.childCandidateDigestInput(
                parentStateCID: fixture.context.parentCarrier.prevState.rawCID
            )
            let candidateCID = try BlockHeader(node: fixture.candidate.block).rawCID
            XCTAssertEqual(digestInput, ["Payments:\(candidateCID)"])
        } catch {
            await descendant.stop()
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
            throw error
        }
        await descendant.stop()
        await fixture.childRuntime.stop()
        await fixture.parentRuntime.stop()
    }

    /// The parent pushes a miner's minimum work to the child that builds the
    /// block, and only the entries at or below that child; the same plan
    /// again pushes nothing, a changed plan pushes once more.
    func testParentPushesDescendantMinimumWorkAndTheChildBuildsWithIt() async throws {
        let fixture = try await provisionalRootFixture(keyByte: 0x96)
        let received = MinimumWorkRecorder()
        let childHandlers = ClosureChainInterface(
            childCandidateBuilder: { context, _ in
                await received.record(context.minimumWork)
                return fixture.candidate
            },
            admission: { _ in throw CancellationError() }
        )
        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess,
                chain: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                chain: childHandlers
            )
            try await waitForChildCandidate(fixture)
            let initialPlan = await received.last()
            XCTAssertEqual(initialPlan, [])

            let childEntry = MiningMinimumWork(
                chainPath: ["Nexus", "Payments"],
                work: UInt256(1) << 8
            )
            await fixture.parentRuntime.updateDescendantPlan(
                rewards: [],
                minimumWork: [
                    MiningMinimumWork(
                        chainPath: ["Nexus"],
                        work: UInt256(1) << 20
                    ),
                    childEntry,
                ]
            )
            for _ in 0..<250 {
                if await received.last() == [childEntry] { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            // The parent's own minimum is the parent's business, not the
            // child's: only the child's entry crosses.
            let forwarded = await received.last()
            XCTAssertEqual(forwarded, [childEntry])
            let builds = await received.count()

            // The same plan again is not a change: nothing is pushed.
            await fixture.parentRuntime.updateDescendantPlan(
                rewards: [],
                minimumWork: [
                    MiningMinimumWork(
                        chainPath: ["Nexus"],
                        work: UInt256(1) << 20
                    ),
                    childEntry,
                ]
            )
            try await alwaysDuring("a repeated plan builds nothing new", .milliseconds(300)) {
                await received.count() == builds
            }
            let buildsAfterRepeat = await received.count()
            XCTAssertEqual(buildsAfterRepeat, builds)
            let candidates = await fixture.parentRuntime.directChildCandidates(
                ChildCandidateRequestContext(
                    parentCarrier: fixture.context.parentCarrier,
                    rewards: [],
                    minimumWork: [childEntry]
                )
            )
            XCTAssertEqual(candidates.count, 1)
        } catch {
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
            throw error
        }
        await fixture.childRuntime.stop()
        await fixture.parentRuntime.stop()
    }

    /// When the parent's tip moves, the candidate the child pushed for the
    /// old tip is not carried (its parent state is stale); the parent pushes
    /// the new tip, the child rebuilds on it and pushes again, and only then
    /// is a candidate held for the new tip. A restarted parent session
    /// starts the child over the same way.
    func testParentTipChangeDropsTheStaleCandidateUntilTheChildRepushes()
        async throws
    {
        let fixture = try await provisionalRootFixture(keyByte: 0x9a)
        let childService = networkService(
            process: fixture.childProcess,
            runtime: fixture.childRuntime
        )
        let childHandlers = ClosureChainInterface(
            childCandidateBuilder: { [weak childService] context, parentSource in
                guard let childService else { return nil }
                return try await childService.miningCandidate(
                    for: context,
                    parentContentSource: parentSource
                )
            },
            admission: { _ in throw CancellationError() }
        )
        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess,
                chain: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                chain: childHandlers
            )
            for _ in 0..<250 {
                if await childService.status().phase == .active { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try await waitForChildCandidate(fixture)

            // The parent's tip moves to a block that CHANGES its state (an
            // empty block leaves the post-state, and so every candidate
            // built on it, exactly as valid as before): anchoring another
            // child genesis.
            let oldTip = try await fixture.parentProcess.validatedTipBlock()
            let otherGenesis = try await ChildGenesisBuilder.build(
                seed: ChildGenesisSeed(
                    spec: NexusGenesis.spec, premineTo: nil,
                    timestamp: oldTip.timestamp + 500
                ),
                chainPath: ["Nexus", "Other"],
                fetcher: fixture.parentProcess
            )
            let otherAnchor = try signedGenesisAnchorTransaction(
                directory: "Other",
                childGenesisCID: try BlockHeader(node: otherGenesis).rawCID,
                chainPath: ["Nexus"]
            )
            try await VolumeImpl<Transaction>(node: otherAnchor).storeRecursively(
                storer: fixture.parentProcess
            )
            let next = try await BlockBuilder.buildBlock(
                previous: oldTip,
                transactions: [otherAnchor],
                timestamp: oldTip.timestamp + 1_000,
                nonce: 3,
                fetcher: fixture.parentProcess
            )
            XCTAssertNotEqual(next.postState.rawCID, oldTip.postState.rawCID)
            let admitted = try await fixture.parentProcess.importBlock(
                try BlockHeader(node: next)
            )
            XCTAssertTrue(admitted.decision.isAccepted)
            await fixture.parentRuntime.chainStateChanged()
            let newProvisional = try await BlockBuilder.buildBlock(
                previous: next,
                timestamp: next.timestamp + 1_000,
                nonce: 4,
                fetcher: fixture.parentProcess
            )
            let newContext = ChildCandidateRequestContext(
                parentCarrier: newProvisional,
                rewards: []
            )
            // The child rebuilds on the new tip and pushes; until then the
            // stale candidate is not carried for the new tip.
            var heldForNewTip: [DirectChildCandidate] = []
            for _ in 0..<500 {
                heldForNewTip = await fixture.parentRuntime.directChildCandidates(
                    newContext
                )
                if !heldForNewTip.isEmpty { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(heldForNewTip.count, 1, "rebuilt for the new tip")
            XCTAssertEqual(
                heldForNewTip.first?.block.parentState.rawCID,
                next.postState.rawCID
            )
            // The old context no longer has a candidate: the child's latest
            // replaced it.
            let heldForOldTip = await fixture.parentRuntime.directChildCandidates(
                fixture.context
            )
            XCTAssertTrue(heldForOldTip.isEmpty)
        } catch {
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
            throw error
        }
        await fixture.childRuntime.stop()
        await fixture.parentRuntime.stop()
    }

    /// Once this chain has carried a child's block, neither that block nor
    /// a sibling of it (another candidate on the same child parent) is
    /// carried again: the child admits the carried block and builds on it,
    /// and every sibling carried meanwhile would only reorg the child's tip
    /// to the heavier carrier, so a child could never get ahead of its own
    /// forks. The next candidate, built on the carried block, is carried.
    /// The parent's context names the child block its branch carried; the
    /// child holds its offer until it admits that block, and the parent
    /// does not carry the named block again. Once the child admits it, the
    /// candidate it builds on it is carried.
    func testACarriedChildBlockIsNamedToTheChildAndNotCarriedAgain() async throws {
        let fixture = try await provisionalRootFixture(keyByte: 0x9e)
        let parentService = networkService(
            process: fixture.parentProcess,
            runtime: fixture.parentRuntime
        )
        let childService = networkService(
            process: fixture.childProcess,
            runtime: fixture.childRuntime
        )
        let childHandlers = ClosureChainInterface(
            childCandidateBuilder: { [weak childService] context, parentSource in
                guard let childService else { return nil }
                return try await childService.miningCandidate(
                    for: context,
                    parentContentSource: parentSource
                )
            },
            admission: { _ in throw CancellationError() }
        )
        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess,
                chain: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                chain: childHandlers
            )
            var held: [DirectChildCandidate] = []
            for _ in 0..<250 {
                held = await fixture.parentRuntime.directChildCandidates(fixture.context)
                if !held.isEmpty { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let first = try XCTUnwrap(held.first)
            XCTAssertEqual(first.block.height, 1)
            let firstHeader = try BlockHeader(node: first.block)

            // This chain carries it: a children-only carrier leaves the
            // post-state, so the fixture context still names this tip's
            // state. Admitted through the service, which publishes the
            // child proof, as a mined block's admission does.
            let parentTip = try await fixture.parentProcess.validatedTipBlock()
            let carrier = try await BlockBuilder.buildBlock(
                previous: parentTip,
                children: ["Payments": first.block],
                timestamp: parentTip.timestamp + 1_000,
                nonce: 7,
                fetcher: CoalescingFetcher(CompositeContentSource([
                    fixture.parentProcess, fixture.childProcess,
                ]))
            )
            let carrierHeader = try BlockHeader(node: carrier)
            try await carrierHeader.storeBlock(
                fetcher: CoalescingFetcher(CompositeContentSource([
                    fixture.parentProcess, fixture.childProcess,
                ])),
                storer: fixture.parentProcess
            )
            // As the mined-block path does: the child proof is prepared
            // before the carrier's admission, and the admission publishes it.
            _ = try await fixture.parentProcess.prepareChildProofs(
                for: carrier,
                children: [first],
                capacity: 16
            )
            let carried = try await parentService.importNetworkCandidate(
                carrierHeader,
                authenticatedChildPackage: nil,
                preparingChildDirectories: ["Payments"],
                contentSource: fixture.parentProcess
            )
            XCTAssertTrue(carried.decision.isAccepted, "\(carried.decision)")
            // Bounded poll, not a fixed wait: the parent re-mints its context
            // after the carrier validates, and a sanitizer build is slow.
            var afterCarry = await fixture.parentRuntime.directChildCandidates(
                fixture.context
            )
            for _ in 0..<500 where !afterCarry.isEmpty {
                try await Task.sleep(for: .milliseconds(20))
                afterCarry = await fixture.parentRuntime.directChildCandidates(
                    fixture.context
                )
            }
            XCTAssertTrue(afterCarry.isEmpty, "the carried block is not carried again")
            let digest = await fixture.parentRuntime.childCandidateDigestInput(
                parentStateCID: fixture.context.parentCarrier.prevState.rawCID
            )
            XCTAssertTrue(digest.isEmpty, "nor is it a template input")
            // The child was told which block was carried, at push latency,
            // and offers nothing on the tip before it.
            var named: String?
            for _ in 0..<250 {
                named = await fixture.childRuntime.debugSnapshot().receivedCarriedChildCID
                if named != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(named, firstHeader.rawCID, "the context names the carried block")
            // The hold is the child's own: its offer task deferred behind the
            // named block, which this child has not admitted. (Here the
            // admission handler throws, so the attempt the parent's evidence
            // seeded leaves without the block and the hold is released
            // again: what is pinned is that the hold happened.)
            var holds = 0
            for _ in 0..<250 {
                holds = await fixture.childRuntime.debugSnapshot().carriedHoldCount
                if holds > 0 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertGreaterThan(holds, 0, "the child held its offer behind the carried block")

            // The child admits and validates its carried block, then builds
            // on it; that candidate is carried.
            let childGenesis = try await fixture.childProcess.validatedTipBlock()
            let proof = try await ChildBlockProof.generate(
                rootHeader: carrierHeader,
                childDirectory: "Payments",
                fetcher: fixture.parentProcess
            )
            let package = AuthenticatedChildPackage(
                package: ChildValidationPackage(
                    proof: proof,
                    parentStateContinuityLink: ParentStateContinuityLink(
                        parentPath: ["Nexus"],
                        fromStateCID: childGenesis.parentState.rawCID,
                        toStateCID: first.block.parentState.rawCID
                    )
                )
            )
            let weighed = try await fixture.childProcess.importBlock(
                firstHeader,
                authenticatedChildPackage: package,
                remoteSource: fixture.parentProcess,
                mode: .header
            )
            XCTAssertTrue(weighed.decision.isAccepted, "\(weighed.decision)")
            let validated = try await fixture.childProcess.importBlock(
                firstHeader,
                authenticatedChildPackage: package,
                remoteSource: fixture.parentProcess,
                mode: .execution
            )
            XCTAssertTrue(validated.decision.isAccepted, "\(validated.decision)")
            await fixture.childRuntime.chainStateChanged()
            var next: [DirectChildCandidate] = []
            for _ in 0..<250 {
                next = await fixture.parentRuntime.directChildCandidates(fixture.context)
                if !next.isEmpty { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(next.first?.block.height, 2, "built on the carried block")
            XCTAssertEqual(next.first?.block.parent?.rawCID, firstHeader.rawCID)
            let stillHeld = await fixture.childRuntime.debugSnapshot().candidateOfferHeld
            XCTAssertFalse(stillHeld, "the hold lifts once the carried block is admitted")
        } catch {
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
            throw error
        }
        await fixture.childRuntime.stop()
        await fixture.parentRuntime.stop()
    }

    /// Control: the parent's named evidence comes to nothing and no overlay
    /// peer announced the block, so the hold is released and the child
    /// offers again.
    func testCarriedHoldReleasesWithoutAnOverlayAnnouncer() async throws {
        let released = try await carriedHoldScenario(keyByte: 0xa2, announce: false)
        XCTAssertTrue(released, "no announcer: the failed evidence releases the hold")
    }

    /// An unauthenticated overlay peer announces the carried CID (public in
    /// the parent chain) and never serves it. Only the parent's evidence can
    /// keep the hold: the parent's evidence failing releases it.
    func testAnOverlayAnnouncerThatNeverServesTheCarriedBlockCannotPinTheHold() async throws {
        let released = try await carriedHoldScenario(keyByte: 0xa6, announce: true)
        XCTAssertTrue(
            released,
            "an overlay announcement that is never served must not hold the child's offers"
        )
    }

    /// The announcer answers the Volume request only after the fetch times
    /// out, so its attempt is in flight when the parent's evidence fails:
    /// an overlay attempt in flight still does not keep the hold.
    func testASlowOverlayAnnouncerCannotPinTheHoldPastItsAttempt() async throws {
        let released = try await carriedHoldScenario(
            keyByte: 0xaa, announce: true, stallVolumeRequests: true,
            window: .seconds(40)
        )
        XCTAssertTrue(
            released,
            "a carried attempt that parks after the parent's evidence failed must still release the hold"
        )
    }

    /// The stalling announcer is joined by a new stalling provider every
    /// second, faster than the fetch timeout: every change of the block's
    /// providers re-readies the attempt, so it is ready or in flight at
    /// every review. Overlay attempts never keep the hold, whatever their
    /// state: the parent's evidence failing releases it.
    func testAnAnnouncerChurningProvidersCannotPinTheHold() async throws {
        let released = try await carriedHoldScenario(
            keyByte: 0xae, announce: true, stallVolumeRequests: true,
            churnProviders: true, window: .seconds(60)
        )
        XCTAssertTrue(
            released,
            "provider churn must not keep a never-served attempt pending"
        )
    }

    /// An overlay peer relays a fabricated portable attachment for the
    /// carried block: a made-up root that commits to it (a proof that
    /// verifies on its own terms, but no parent block). Its packaged attempt
    /// never lands the block. Only the parent's evidence can keep the hold:
    /// the parent's evidence failing releases it.
    func testAFabricatedOverlayAttachmentCannotPinTheHold() async throws {
        let released = try await carriedHoldScenario(
            keyByte: 0xbe, announce: false, fabricatedAttachment: true
        )
        XCTAssertTrue(
            released,
            "an overlay-relayed package must not hold the child's offers"
        )
    }

    /// Runs the carried-hold scenario; returns whether the child offered again
    /// (built a new candidate) after the parent named its carried block.
    private func carriedHoldScenario(
        keyByte: UInt8,
        announce: Bool,
        stallVolumeRequests: Bool = false,
        churnProviders: Bool = false,
        fabricatedAttachment: Bool = false,
        window: Duration = .seconds(10)
    ) async throws -> Bool {
        let fixture = try await provisionalRootFixture(keyByte: keyByte)
        let parentService = networkService(
            process: fixture.parentProcess,
            runtime: fixture.parentRuntime
        )
        let childService = networkService(
            process: fixture.childProcess,
            runtime: fixture.childRuntime
        )
        let builds = NetworkEventRecorder()
        // Admission never lands the carried block here (as in the carried
        // test above): only the hold's release paths can reopen the offer.
        let childHandlers = ClosureChainInterface(
            childCandidateBuilder: { [weak childService] context, parentSource in
                guard let childService else { return nil }
                await builds.append("build")
                return try await childService.miningCandidate(
                    for: context,
                    parentContentSource: parentSource
                )
            },
            admission: { _ in throw CancellationError() }
        )
        let attacker = carriedAnnouncer(keyByte: keyByte)
        let stalled = Latch()
        if stallVolumeRequests {
            await attacker.setContentSource(StallingContentSource(release: stalled))
        }
        var announcing: Task<Void, Never>?
        var churning: Task<Void, Never>?
        func stopAll() async {
            announcing?.cancel()
            await stalled.open()
            churning?.cancel()
            await churning?.value
            await attacker.stop()
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
        }
        let evidenceGate = EvidenceAttachmentGate()
        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess,
                chain: inertNetworkHandlers()
            )
            await fixture.parentRuntime.hierarchy.setContentSource(
                EvidenceRefusingContentSource(
                    parent: fixture.parentProcess, gate: evidenceGate
                )
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                chain: childHandlers
            )
            let first = try await firstHeldCandidate(fixture)
            let firstCID = try BlockHeader(node: first.block).rawCID
            if announce {
                announcing = try await announceRepeatedly(
                    firstCID, from: attacker, to: fixture
                )
                try await eventually("the announced carried CID is tracked") {
                    await fixture.childRuntime.blockFetcher.tracks(firstCID)
                }
                if churnProviders {
                    churning = try churnAnnouncers(
                        firstCID, stalled: stalled, to: fixture
                    )
                    // The churn is in effect before the parent names the block.
                    try await eventually("providers churned in") {
                        await fixture.childRuntime.blockFetcher
                            .debugSnapshot().providerKeys.count >= 4
                    }
                }
            }
            let buildsBeforeCarry = await builds.snapshot().count
            // The parent names the block with its evidence, but never
            // serves the evidence's attachment: the parent's word on the
            // block comes to nothing here.
            await evidenceGate.refuse(firstCID)
            let carrier = try await storeCarrier(
                of: first, fixture: fixture, withEvidence: true
            )
            if fabricatedAttachment {
                try await relayFabricatedAttachment(
                    for: first, from: attacker, fixture: fixture
                )
            }
            try await admitCarrier(
                carrier, service: parentService, fixture: fixture, withEvidence: true
            )
            try await eventually("the context names the carried block") {
                await fixture.childRuntime.debugSnapshot().receivedCarriedChildCID
                    == firstCID
            }
            try await eventually("the child held its offer") {
                await fixture.childRuntime.debugSnapshot().carriedHoldCount > 0
            }
            var released = false
            let deadline = ContinuousClock.now + window * testTimeScale
            while ContinuousClock.now < deadline {
                if await fixture.childRuntime.debugCarriedHold().released == firstCID {
                    if fabricatedAttachment {
                        // Released by the parent's evidence failing, not by
                        // the relayed package's attempt leaving the fetcher.
                        let tracked = await fixture.childRuntime.blockFetcher
                            .tracks(firstCID)
                        XCTAssertTrue(
                            tracked,
                            "released while the relayed package's attempt is held"
                        )
                    }
                    if await builds.snapshot().count > buildsBeforeCarry {
                        released = true
                        break
                    }
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            await stopAll()
            return released
        } catch {
            await stopAll()
            throw error
        }
    }

    /// The parent's tip moves away from the carried block and back. While
    /// its context names nothing, the attempt the parent's evidence seeded
    /// for the block leaves the fetcher (no review: nothing is carried).
    /// Named again, nothing the parent seeded is pending: the context's
    /// evidence is recovered once more, its attempt is decided against, and
    /// the hold is released.
    func testACarriedBlockNamedAgainAfterItsAttemptLeftIsReviewed() async throws {
        let fixture = try await provisionalRootFixture(keyByte: 0xc6)
        let parentService = networkService(
            process: fixture.parentProcess,
            runtime: fixture.parentRuntime
        )
        let childService = networkService(
            process: fixture.childProcess,
            runtime: fixture.childRuntime
        )
        // Admission of the parent's package parks on evidence until the
        // test says otherwise; then it decides against the block.
        let decideAgainst = DecisionSwitch()
        let childHandlers = ClosureChainInterface(
            childCandidateBuilder: { [weak childService] context, parentSource in
                guard let childService else { return nil }
                return try await childService.miningCandidate(
                    for: context,
                    parentContentSource: parentSource
                )
            },
            admission: { admission in
                guard admission.authenticatedChildPackage != nil else {
                    throw CancellationError()
                }
                let against = await decideAgainst.isOn
                return NodeImportOutcome(
                    decision: against ? .invalid : .unavailable(nil),
                    parentCarrierLink: nil,
                    sameChainPredecessor: nil
                )
            }
        )
        func stopAll() async {
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
        }
        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess,
                chain: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                chain: childHandlers
            )
            let first = try await firstHeldCandidate(fixture)
            let firstCID = try BlockHeader(node: first.block).rawCID
            let carrier = try await storeCarrier(
                of: first, fixture: fixture, withEvidence: true
            )
            try await admitCarrier(
                carrier, service: parentService, fixture: fixture, withEvidence: true
            )
            try await eventually("the parent's evidence seeded an attempt") {
                await fixture.childRuntime.blockFetcher.hasParentAttempt(firstCID)
            }
            try await eventually("the context names the carried block") {
                await fixture.childRuntime.debugSnapshot().receivedCarriedChildCID
                    == firstCID
            }
            try await alwaysDuring("held behind the parent's attempt", .milliseconds(500)) {
                await fixture.childRuntime.debugCarriedHold().released != firstCID
            }
            let heldAtFirst = await fixture.childRuntime.debugCarriedHold().released
            XCTAssertNotEqual(heldAtFirst, firstCID, "held behind the parent's attempt")

            // The parent's tip moves to a context naming nothing.
            let tip = try await fixture.parentProcess.validatedTipBlock()
            let tipCID = try BlockHeader(node: tip).rawCID
            let tipData = try XCTUnwrap(tip.toData())
            let childPeer = PeerID(publicKey: fixture.childConfiguration.processPublicKey)
            let issued = try await fixture.parentProcess.store
                .issuedChildEvidenceSummary(childCID: firstCID, directory: "Payments")
            let evidence = try XCTUnwrap(issued.map {
                CarriedChildEvidence(sourceID: $0.sourceID, summary: $0.summary)
            })
            func pushContext(
                _ sequence: UInt64, carried: CarriedChildEvidence?
            ) async throws {
                let payload = try ParentTipContextMessage(
                    sequence: sequence,
                    childPath: fixture.childConfiguration.chainPath,
                    tipCID: tipCID,
                    tipData: tipData,
                    rewards: [],
                    carriedEvidence: carried
                ).encoded()
                _ = await fixture.parentRuntime.hierarchy.sendMessage(
                    to: childPeer,
                    topic: NodeNetworkTopic.parentTipAvailable,
                    payload: payload
                )
            }
            try await pushContext(1_000_000, carried: nil)
            try await eventually("the context names nothing") {
                await fixture.childRuntime.debugSnapshot().receivedCarriedChildCID == nil
            }
            // Meanwhile the parent's attempt is decided and leaves.
            await decideAgainst.turnOn()
            try await eventually("the parent's attempt left the fetcher") {
                await !fixture.childRuntime.blockFetcher.hasParentAttempt(firstCID)
            }
            let releasedMeanwhile = await fixture.childRuntime.debugCarriedHold().released
            XCTAssertNotEqual(releasedMeanwhile, firstCID, "nothing named: no release")

            // The tip moves back: the block is named again.
            try await pushContext(1_000_001, carried: evidence)
            try await eventually("the block named again is reviewed and released") {
                await fixture.childRuntime.debugCarriedHold().released == firstCID
            }
            await stopAll()
        } catch {
            await stopAll()
            throw error
        }
    }

    /// Honest: an overlay peer gossips the carried block (here: announces
    /// it; its rootless attempt parks on content) while the parent's
    /// evidence for it is still being recovered: the parent named the block
    /// with its evidence, but the attachment Volume is held at the parent.
    /// The rooted package is still coming: no release. Once the evidence
    /// lands, the rooted package admits the block. No push is held back:
    /// the context names the block only once its evidence is issued.
    func testARootlessParkWhileTheNamedEvidenceIsRecoveredDoesNotReleaseTheHold() async throws {
        let fixture = try await provisionalRootFixture(keyByte: 0xb2)
        let parentService = networkService(
            process: fixture.parentProcess,
            runtime: fixture.parentRuntime
        )
        let childService = networkService(
            process: fixture.childProcess,
            runtime: fixture.childRuntime
        )
        let admissions = NetworkEventRecorder()
        let childHandlers = ClosureChainInterface(
            childCandidateBuilder: { [weak childService] context, parentSource in
                guard let childService else { return nil }
                return try await childService.miningCandidate(
                    for: context,
                    parentContentSource: parentSource
                )
            },
            admission: { [weak childService] admission in
                guard admission.authenticatedChildPackage != nil,
                      let childService else {
                    await admissions.append("rootless")
                    throw CancellationError()
                }
                await admissions.append("rooted")
                return try await childService.importNetworkCandidate(
                    admission.header,
                    authenticatedChildPackage: admission.authenticatedChildPackage,
                    preparingChildDirectories: admission.preparingChildDirectories,
                    contentSource: admission.contentSource,
                    weighed: admission.weighed
                )
            }
        )
        let attacker = carriedAnnouncer(keyByte: 0xb2)
        let gate = ContentGate()
        var announcing: Task<Void, Never>?
        func stopAll() async {
            announcing?.cancel()
            await gate.open()
            await attacker.stop()
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
        }
        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess,
                chain: inertNetworkHandlers()
            )
            await fixture.parentRuntime.hierarchy.setContentSource(
                GatedContentSource(
                    inner: ChainProcessIvyContentSource(process: fixture.parentProcess),
                    gate: gate
                )
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                chain: childHandlers
            )
            let first = try await firstHeldCandidate(fixture)
            let firstCID = try BlockHeader(node: first.block).rawCID

            await gate.close()
            let carrier = try await storeCarrier(
                of: first, fixture: fixture, withEvidence: true
            )
            try await admitCarrier(
                carrier, service: parentService, fixture: fixture, withEvidence: true
            )
            try await eventually("the carried block's evidence is being recovered") {
                await fixture.childRuntime.debugCarriedHold().evidenceInFlight[firstCID] != nil
            }
            try await eventually("the context names the carried block") {
                await fixture.childRuntime.debugSnapshot().receivedCarriedChildCID
                    == firstCID
            }
            announcing = try await announceRepeatedly(
                firstCID, from: attacker, to: fixture
            )
            try await eventually("the gossiped attempt parked on content") {
                let fetcher = await fixture.childRuntime.blockFetcher
                return fetcher.tracks(firstCID) && !fetcher.isAwaitingAdmission(firstCID)
            }
            let rootless = await admissions.snapshot().contains("rootless")
            XCTAssertTrue(rootless, "the gossiped attempt reached admission and parked")
            try await alwaysDuring("no release while the evidence is recovered", .seconds(1)) {
                await fixture.childRuntime.debugCarriedHold().released != firstCID
            }
            let recovering = await fixture.childRuntime.debugCarriedHold().evidenceInFlight[firstCID]
            XCTAssertNotNil(recovering, "the evidence was still held")

            await gate.open()
            try await eventually("the rooted package admits the carried block") {
                await fixture.childProcess.hasAcceptedBlock(firstCID)
            }
            let rooted = await admissions.snapshot().contains("rooted")
            XCTAssertTrue(rooted, "admitted through the parent's package")
            let released = await fixture.childRuntime.debugCarriedHold().released
            XCTAssertNotEqual(released, firstCID, "the hold was never released")
            await stopAll()
        } catch {
            await stopAll()
            throw error
        }
    }

    /// The parent names the carried block with its evidence but never
    /// serves the evidence's attachment, so its recovery ends
    /// `.unavailable` (the session is kept). The parent's word came to
    /// nothing: the hold is released after that one attempt, not left
    /// waiting on evidence that never lands.
    func testNamedEvidenceThatIsUnavailableReleasesTheHold() async throws {
        let fixture = try await provisionalRootFixture(keyByte: 0xba)
        let parentService = networkService(
            process: fixture.parentProcess,
            runtime: fixture.parentRuntime
        )
        let childService = networkService(
            process: fixture.childProcess,
            runtime: fixture.childRuntime
        )
        let childHandlers = ClosureChainInterface(
            childCandidateBuilder: { [weak childService] context, parentSource in
                guard let childService else { return nil }
                return try await childService.miningCandidate(
                    for: context,
                    parentContentSource: parentSource
                )
            },
            admission: { _ in throw CancellationError() }
        )
        let gate = ContentGate()
        func stopAll() async {
            await gate.open()
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
        }
        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess,
                chain: inertNetworkHandlers()
            )
            await fixture.parentRuntime.hierarchy.setContentSource(
                GatedContentSource(
                    inner: ChainProcessIvyContentSource(process: fixture.parentProcess),
                    gate: gate
                )
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                chain: childHandlers
            )
            let first = try await firstHeldCandidate(fixture)
            let firstCID = try BlockHeader(node: first.block).rawCID

            await gate.refuse()
            let carrier = try await storeCarrier(
                of: first, fixture: fixture, withEvidence: true
            )
            try await admitCarrier(
                carrier, service: parentService, fixture: fixture, withEvidence: true
            )
            // The parent has issued the block's evidence, so its context
            // names the block with it.
            try await eventually("the parent issued the carried block's evidence") {
                let head = try? await fixture.parentProcess.store
                    .issuedChildEvidenceScanHead(directory: "Payments")
                return (head?.throughOrdinal ?? 0) > 0
            }
            try await eventually("the context names the carried block") {
                await fixture.childRuntime.debugSnapshot().receivedCarriedChildCID
                    == firstCID
            }
            try await eventually("the failed evidence releases the hold") {
                await fixture.childRuntime.debugCarriedHold().released == firstCID
            }
            let parentSession = await fixture.childRuntime.debugCarriedHold().named != nil
            XCTAssertTrue(parentSession, "the parent session was kept")
            await stopAll()
        } catch {
            await stopAll()
            throw error
        }
    }

    /// Honest: the attempt the parent's evidence seeded for the carried
    /// block walks a missing predecessor (`.predecessor` park). That is the
    /// parent's word that a decision is coming: the hold is not released.
    func testAParentBackedPredecessorParkDoesNotReleaseTheHold() async throws {
        let fixture = try await provisionalRootFixture(keyByte: 0xb6)
        let parentService = networkService(
            process: fixture.parentProcess,
            runtime: fixture.parentRuntime
        )
        let childService = networkService(
            process: fixture.childProcess,
            runtime: fixture.childRuntime
        )
        let missingPredecessor = "bafyreib" + String(repeating: "q", count: 51)
        let admissions = NetworkEventRecorder()
        let childHandlers = ClosureChainInterface(
            childCandidateBuilder: { [weak childService] context, parentSource in
                guard let childService else { return nil }
                return try await childService.miningCandidate(
                    for: context,
                    parentContentSource: parentSource
                )
            },
            admission: { admission in
                let cid = admission.header.rawCID
                guard admission.authenticatedChildPackage != nil else {
                    throw CancellationError()
                }
                await admissions.append("walk")
                return NodeImportOutcome(
                    decision: .unavailable(nil),
                    parentCarrierLink: nil,
                    sameChainPredecessor: SameChainPredecessorRequirement(
                        descendantCID: cid,
                        predecessorCID: missingPredecessor
                    )
                )
            }
        )
        func stopAll() async {
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
        }
        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess,
                chain: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                chain: childHandlers
            )
            let first = try await firstHeldCandidate(fixture)
            let firstCID = try BlockHeader(node: first.block).rawCID
            let carrier = try await storeCarrier(
                of: first, fixture: fixture, withEvidence: true
            )
            try await admitCarrier(
                carrier, service: parentService, fixture: fixture, withEvidence: true
            )
            // The parent's pushed evidence seeds the attempt; it walks.
            try await eventually("the parent-backed attempt walks its predecessor") {
                let fetcher = await fixture.childRuntime.blockFetcher
                return fetcher.hasParentAttempt(firstCID)
                    && !fetcher.isAwaitingAdmission(firstCID)
            }
            let walked = await admissions.snapshot().contains("walk")
            XCTAssertTrue(walked, "the parent's package parked on its predecessor")
            try await eventually("the context names the carried block") {
                await fixture.childRuntime.debugSnapshot().receivedCarriedChildCID
                    == firstCID
            }
            try await alwaysDuring("no release while the walk is pending", .seconds(1)) {
                await fixture.childRuntime.debugCarriedHold().released != firstCID
            }
            let stillHeld = await fixture.childRuntime.debugSnapshot().candidateOfferHeld
            XCTAssertTrue(stillHeld, "the offer is still held behind the carried block")
            await stopAll()
        } catch {
            await stopAll()
            throw error
        }
    }

    // MARK: - #200: a context names a carried block only with its evidence

    /// A child built from `fixture` whose builds are recorded (the height
    /// of each candidate built), admitting through its own service or not
    /// at all.
    private func recordingChildHandlers(
        _ fixture: ProvisionalRootFixture,
        builds: NetworkEventRecorder,
        admits: Bool
    ) -> ClosureChainInterface {
        let childService = networkService(
            process: fixture.childProcess,
            runtime: fixture.childRuntime
        )
        return ClosureChainInterface(
            childCandidateBuilder: { context, parentSource in
                let built = try await childService.miningCandidate(
                    for: context,
                    parentContentSource: parentSource
                )
                await builds.append("\(built.block.height)")
                return built
            },
            admission: { admission in
                guard admits else { throw CancellationError() }
                return try await childService.importNetworkCandidate(
                    admission.header,
                    authenticatedChildPackage: admission.authenticatedChildPackage,
                    preparingChildDirectories: admission.preparingChildDirectories,
                    contentSource: admission.contentSource,
                    weighed: admission.weighed
                )
            }
        )
    }

    /// Admits the stored carrier through the parent's service, preparing
    /// the child's directory, as a mined or relayed carrier is admitted.
    private func admitCarrierThroughService(
        _ carrier: Block,
        service: ChainService,
        fixture: ProvisionalRootFixture
    ) async throws {
        let admitted = try await service.importNetworkCandidate(
            try BlockHeader(node: carrier),
            authenticatedChildPackage: nil,
            preparingChildDirectories: ["Payments"],
            contentSource: fixture.parentProcess
        )
        XCTAssertTrue(admitted.decision.isAccepted, "\(admitted.decision)")
    }

    private func scheduleChildProofRecovery(
        _ fixture: ProvisionalRootFixture
    ) async {
        let generation = await fixture.parentRuntime.runtimeGeneration
        await fixture.parentRuntime.scheduleChildProofRecovery(
            generation: generation, process: fixture.parentProcess
        )
    }

    /// The parent admits a carrier while the child block's content is
    /// withheld (the proof cannot be built): its push to the child waits
    /// for a recovery iteration, then goes out on the carrier's tip without
    /// naming the block. Once the content is there (the proof prepared)
    /// and a pass issues the evidence, the next context names the block.
    /// Before #200 the context named the block at once.
    func testTheContextNamesACarriedBlockOnlyOnceItsEvidenceIsIndexed() async throws {
        let fixture = try await provisionalRootFixture(keyByte: 0xca)
        let parentService = networkService(
            process: fixture.parentProcess,
            runtime: fixture.parentRuntime
        )
        let builds = NetworkEventRecorder()
        let recorder = ParentTipRecordingDelegate(forwardingTo: fixture.childRuntime)
        func stopAll() async {
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
        }
        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess,
                chain: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                chain: recordingChildHandlers(fixture, builds: builds, admits: false)
            )
            await fixture.childRuntime.hierarchy.installTestDelegate(recorder)
            let first = try await firstHeldCandidate(fixture)
            let firstCID = try BlockHeader(node: first.block).rawCID
            let heldBefore = await fixture.parentRuntime.debugParentTipNaming().heldBackCount

            let carrier = try await storeCarrierBlock(
                of: first, fixture: fixture, withEvidence: false
            )
            let carrierCID = try BlockHeader(node: carrier).rawCID
            try await admitCarrierThroughService(
                carrier, service: parentService, fixture: fixture
            )
            try await eventually("the carrier's context reaches the child") {
                !recorder.contexts(forTip: carrierCID).isEmpty
            }
            XCTAssertEqual(
                recorder.contexts(forTip: carrierCID).map(\.carried), [nil],
                "no evidence issued: the carried block is not named"
            )
            let naming = await fixture.parentRuntime.debugParentTipNaming()
            XCTAssertGreaterThan(
                naming.heldBackCount, heldBefore,
                "the push waited for a recovery iteration first"
            )
            XCTAssertEqual(naming.named, [:])
            XCTAssertEqual(naming.heldBack, [], "the pass ended: nothing waits")

            // The content arrives: the proof is prepared, a pass issues it.
            _ = try await fixture.parentProcess.prepareChildProofs(
                for: carrier, children: [first], capacity: 16
            )
            await scheduleChildProofRecovery(fixture)
            try await eventually("the next context names the carried block") {
                recorder.contexts(forTip: carrierCID).last?.carried == firstCID
            }
            let issued = try await fixture.parentProcess.store
                .issuedChildEvidenceSummary(childCID: firstCID, directory: "Payments")
            XCTAssertNotNil(issued, "named only with its evidence indexed")
            await stopAll()
        } catch {
            await stopAll()
            throw error
        }
    }

    /// #200: the parent names the carried block, the child admits it, and
    /// in between the child builds nothing on the tip before it (a sibling
    /// of the carried block). Before, the context named the block before
    /// its evidence was issued, the child's scan came back empty and
    /// released the hold, and one sibling was built. No push is held back
    /// here: the context and the evidence race as they do in production.
    func testNoSiblingIsBuiltBetweenTheCarryAndItsAdmission() async throws {
        let fixture = try await provisionalRootFixture(keyByte: 0xce)
        let parentService = networkService(
            process: fixture.parentProcess,
            runtime: fixture.parentRuntime
        )
        let builds = NetworkEventRecorder()
        func stopAll() async {
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
        }
        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess,
                chain: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                chain: recordingChildHandlers(fixture, builds: builds, admits: true)
            )
            let first = try await firstHeldCandidate(fixture)
            let firstCID = try BlockHeader(node: first.block).rawCID
            let buildsBeforeCarry = await builds.snapshot().count

            let carrier = try await storeCarrier(
                of: first, fixture: fixture, withEvidence: true
            )
            try await admitCarrier(
                carrier, service: parentService, fixture: fixture, withEvidence: true
            )
            try await eventually("the carried block is admitted") {
                await fixture.childProcess.hasAcceptedBlock(firstCID)
            }
            try await eventually("the child builds on the carried block") {
                await builds.snapshot().dropFirst(buildsBeforeCarry).contains("2")
            }
            let afterCarry = Array(await builds.snapshot().dropFirst(buildsBeforeCarry))
            XCTAssertFalse(
                afterCarry.contains("1"),
                "a sibling of the carried block was built: \(afterCarry)"
            )
            await stopAll()
        } catch {
            await stopAll()
            throw error
        }
    }

    /// A parent that cannot issue the carried block's evidence (its child
    /// content never arrives; for a parent below the root, the root that
    /// would secure the proof never arrives) does not wedge the child: once
    /// a recovery iteration has done what it can, its context goes out without
    /// naming the block, and the child offers on it.
    func testAParentThatCannotIssueTheEvidenceDoesNotWedgeTheChild() async throws {
        let fixture = try await provisionalRootFixture(keyByte: 0xd2)
        let parentService = networkService(
            process: fixture.parentProcess,
            runtime: fixture.parentRuntime
        )
        let builds = NetworkEventRecorder()
        let recorder = ParentTipRecordingDelegate(forwardingTo: fixture.childRuntime)
        func stopAll() async {
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
        }
        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess,
                chain: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                chain: recordingChildHandlers(fixture, builds: builds, admits: false)
            )
            await fixture.childRuntime.hierarchy.installTestDelegate(recorder)
            let first = try await firstHeldCandidate(fixture)
            let buildsBeforeCarry = await builds.snapshot().count
            let carrier = try await storeCarrierBlock(
                of: first, fixture: fixture, withEvidence: false
            )
            let carrierCID = try BlockHeader(node: carrier).rawCID
            try await admitCarrierThroughService(
                carrier, service: parentService, fixture: fixture
            )
            try await eventually("the child offers on the carrier's tip") {
                await builds.snapshot().count > buildsBeforeCarry
            }
            XCTAssertEqual(
                recorder.contexts(forTip: carrierCID).map(\.carried), [nil],
                "the context never named the block"
            )
            let hold = await fixture.childRuntime.debugSnapshot().carriedHoldCount
            XCTAssertEqual(hold, 0, "nothing named: the child never held")
            await stopAll()
        } catch {
            await stopAll()
            throw error
        }
    }

    /// A context names a block the parent never carried, with a forged
    /// evidence summary (an attachment the parent cannot serve). The
    /// summary is only a pointer: its recovery fails, and after that one
    /// attempt the hold is gone (released, or dropped with the session the
    /// failure recycles) and the child offers again. No attempt for the
    /// block is left behind for the forged pointer.
    func testAForgedEvidenceSummaryReleasesTheHoldAfterOneFailedAttempt() async throws {
        let fixture = try await provisionalRootFixture(keyByte: 0xde)
        let builds = NetworkEventRecorder()
        func stopAll() async {
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
        }
        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess,
                chain: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                chain: recordingChildHandlers(fixture, builds: builds, admits: false)
            )
            let first = try await firstHeldCandidate(fixture)
            let firstCID = try BlockHeader(node: first.block).rawCID
            let buildsBefore = await builds.snapshot().count
            let tip = try await fixture.parentProcess.validatedTipBlock()
            let payload = try ParentTipContextMessage(
                sequence: 1_000_000,
                childPath: fixture.childConfiguration.chainPath,
                tipCID: try BlockHeader(node: tip).rawCID,
                tipData: try XCTUnwrap(tip.toData()),
                rewards: [],
                carriedEvidence: CarriedChildEvidence(
                    sourceID: testEvidenceSourceID,
                    summary: IssuedChildEvidenceSummary(
                        ordinal: 1,
                        childCID: firstCID,
                        rootCID: testCID("forged-root"),
                        attachmentCID: testCID("forged-attachment")
                    )
                )
            ).encoded()
            _ = await fixture.parentRuntime.hierarchy.sendMessage(
                to: PeerID(publicKey: fixture.childConfiguration.processPublicKey),
                topic: NodeNetworkTopic.parentTipAvailable,
                payload: payload
            )
            try await eventually("the forged context named the block") {
                let hold = await fixture.childRuntime.debugCarriedHold()
                return hold.named == firstCID || hold.released == firstCID
            }
            try await eventually("the hold ends after the failed recovery") {
                let hold = await fixture.childRuntime.debugCarriedHold()
                return hold.released == firstCID || hold.named != firstCID
            }
            try await eventually("the child offers again") {
                await builds.snapshot().count > buildsBefore
            }
            let inFlight = await fixture.childRuntime.debugCarriedHold()
                .evidenceInFlight[firstCID]
            XCTAssertNil(inFlight, "the forged pointer's recovery settled")
            let tracked = await fixture.childRuntime.blockFetcher.hasParentAttempt(firstCID)
            XCTAssertFalse(tracked, "no parent-backed attempt from a forged pointer")
            await stopAll()
        } catch {
            await stopAll()
            throw error
        }
    }

    /// The child's parent-evidence lane is full (every evidence slot held
    /// by overlay work) when the parent names its carried block: the
    /// pushed hint is dropped as local backpressure, but the named evidence
    /// takes the lane's reserved slot and waits for a Volume slot, so the
    /// hold holds and no sibling is built. Once the lane frees, the block
    /// is admitted and the next candidate is built on it. Before, the
    /// backpressured append seeded nothing and the hold was released.
    func testABackpressuredEvidenceLaneDoesNotReleaseTheHold() async throws {
        let fixture = try await provisionalRootFixture(keyByte: 0xe2)
        let parentService = networkService(
            process: fixture.parentProcess,
            runtime: fixture.parentRuntime
        )
        let builds = NetworkEventRecorder()
        func stopAll() async {
            await fixture.childRuntime.freeEvidenceLaneForTesting()
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
        }
        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess,
                chain: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                chain: recordingChildHandlers(fixture, builds: builds, admits: true)
            )
            let first = try await firstHeldCandidate(fixture)
            let firstCID = try BlockHeader(node: first.block).rawCID
            let buildsBeforeCarry = await builds.snapshot().count
            await fixture.childRuntime.fillEvidenceLaneForTesting()

            let carrier = try await storeCarrier(
                of: first, fixture: fixture, withEvidence: true
            )
            try await admitCarrier(
                carrier, service: parentService, fixture: fixture, withEvidence: true
            )
            try await eventually("the context names the carried block") {
                await fixture.childRuntime.debugSnapshot().receivedCarriedChildCID
                    == firstCID
            }
            try await eventually("the named evidence is seeded despite the full lane") {
                await fixture.childRuntime.debugCarriedHold()
                    .evidenceInFlight[firstCID] != nil
            }
            try await alwaysDuring("the hold holds while the lane is full", .seconds(1)) {
                await fixture.childRuntime.debugCarriedHold().released != firstCID
            }
            let accepted = await fixture.childProcess.hasAcceptedBlock(firstCID)
            XCTAssertFalse(accepted, "the lane was full: nothing recovered yet")

            await fixture.childRuntime.freeEvidenceLaneForTesting()
            try await eventually("the carried block is admitted once the lane frees") {
                await fixture.childProcess.hasAcceptedBlock(firstCID)
            }
            try await eventually("the child builds on the carried block") {
                await builds.snapshot().dropFirst(buildsBeforeCarry).contains("2")
            }
            let afterCarry = Array(await builds.snapshot().dropFirst(buildsBeforeCarry))
            XCTAssertFalse(
                afterCarry.contains("1"),
                "a sibling of the carried block was built: \(afterCarry)"
            )
            let released = await fixture.childRuntime.debugCarriedHold().released
            XCTAssertNotEqual(released, firstCID, "the hold was never released")
            await stopAll()
        } catch {
            await stopAll()
            throw error
        }
    }

    /// The child's parent-evidence inbox is full (one parked entry fills a
    /// one-entry inbox) when the parent names its carried block. The named
    /// evidence waits for room without fetching: the parent serves its
    /// attachment at most once (the hint's own fetch) while the inbox stays
    /// full, the hold holds, and once an import frees the inbox the block is
    /// admitted. Before, every inbox refusal re-seeded the evidence at once:
    /// a fetch loop against the parent for as long as the inbox stayed full.
    func testAFullInboxHoldsTheNamedEvidenceWithoutAFetchLoop() async throws {
        let fixture = try await provisionalRootFixture(
            keyByte: 0xe6, childInboxCapacity: 1
        )
        let parentService = networkService(
            process: fixture.parentProcess,
            runtime: fixture.parentRuntime
        )
        let probe = EvidenceServeProbe()
        let builds = NetworkEventRecorder()
        // The filler: a parent-evidence entry for another block, parked in
        // the inbox (its admission waits), which fills it.
        let filler = try await fabricatedEvidence(for: fixture.candidate, fixture: fixture)
        try await fixture.childProcess.store.storeParentEvidenceInbox(
            sourceID: testEvidenceSourceID,
            ordinal: 1_000,
            attachment: filler.attachment,
            package: filler.package,
            advanceScan: false
        )
        let childService = networkService(
            process: fixture.childProcess,
            runtime: fixture.childRuntime
        )
        let childHandlers = ClosureChainInterface(
            childCandidateBuilder: { context, parentSource in
                let built = try await childService.miningCandidate(
                    for: context,
                    parentContentSource: parentSource
                )
                await builds.append("\(built.block.height)")
                return built
            },
            admission: { admission in
                if admission.header.rawCID == filler.childCID {
                    return NodeImportOutcome(
                        decision: .unavailable(nil),
                        parentCarrierLink: nil,
                        sameChainPredecessor: nil
                    )
                }
                return try await childService.importNetworkCandidate(
                    admission.header,
                    authenticatedChildPackage: admission.authenticatedChildPackage,
                    preparingChildDirectories: admission.preparingChildDirectories,
                    contentSource: admission.contentSource,
                    weighed: admission.weighed
                )
            }
        )
        func stopAll() async {
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
        }
        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess,
                chain: inertNetworkHandlers()
            )
            await fixture.parentRuntime.hierarchy.setContentSource(
                ProbedContentSource(parent: fixture.parentProcess, probe: probe)
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                chain: childHandlers
            )
            let first = try await firstHeldCandidate(fixture)
            let firstCID = try BlockHeader(node: first.block).rawCID
            let buildsBeforeCarry = await builds.snapshot().count
            let full = try await fixture.childProcess.store.parentEvidenceInboxHasCapacity()
            XCTAssertFalse(full, "the filler fills the inbox")
            await probe.watch(firstCID)

            let carrier = try await storeCarrier(
                of: first, fixture: fixture, withEvidence: true
            )
            try await admitCarrier(
                carrier, service: parentService, fixture: fixture, withEvidence: true
            )
            try await eventually("the named evidence waits for inbox room") {
                await fixture.childRuntime.debugCarriedHold().namedEvidenceWaiting
                    == firstCID
            }
            try await alwaysDuring("the hold holds while the inbox is full", .seconds(2)) {
                await fixture.childRuntime.debugCarriedHold().released != firstCID
            }
            let servedWhileFull = await probe.serves
            XCTAssertLessThanOrEqual(
                servedWhileFull, 1,
                "the full inbox cost the parent \(servedWhileFull) fetches"
            )

            // An import consumes the filler: room, and a state change.
            try await fixture.childProcess.store.consumeParentEvidence(
                childCID: filler.childCID, rootCID: filler.package.package.proof.rootCID
            )
            await fixture.childRuntime.chainStateChanged()
            try await eventually("the carried block is admitted once the inbox has room") {
                await fixture.childProcess.hasAcceptedBlock(firstCID)
            }
            try await eventually("the child builds on the carried block") {
                await builds.snapshot().dropFirst(buildsBeforeCarry).contains("2")
            }
            let afterCarry = Array(await builds.snapshot().dropFirst(buildsBeforeCarry))
            XCTAssertFalse(afterCarry.contains("1"), "a sibling was built: \(afterCarry)")
            await stopAll()
        } catch {
            await stopAll()
            throw error
        }
    }

    /// A parent-evidence entry for `candidate` under a made-up root: a
    /// Nexus genesis that commits to it (a proof that verifies on its own
    /// terms, no parent block).
    private func fabricatedEvidence(
        for candidate: DirectChildCandidate,
        fixture: ProvisionalRootFixture
    ) async throws -> (
        childCID: String,
        attachment: ChildEvidenceVolume,
        package: AuthenticatedChildPackage
    ) {
        let content = InMemoryContentStore()
        let fetcher = CoalescingFetcher(CompositeContentSource([
            content, fixture.parentProcess, fixture.childProcess,
        ]))
        let root = try await BlockBuilder.buildGenesis(
            spec: NexusGenesis.spec,
            children: ["Payments": candidate.block],
            timestamp: 5,
            target: UInt256.max,
            fetcher: fetcher
        )
        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: root),
            childDirectory: "Payments",
            fetcher: fetcher
        )
        let childCID = try BlockHeader(node: candidate.block).rawCID
        let package = ChildValidationPackage(proof: proof)
        let attachment = try ChildEvidenceVolume(
            envelopeBytes: try ChildValidationPackageEnvelope(package).encode(),
            childCID: childCID
        )
        return (childCID, attachment, AuthenticatedChildPackage(package: package))
    }

    /// The parent's recovery pass never ends (every iteration re-arms it,
    /// as a stream of imports or overlay hellos does) while the carried
    /// block's evidence cannot be issued (its content withheld): the push
    /// waits for one iteration, then the carrier's context goes out without
    /// naming the block. Before, the wait ended only when a pass ended, so
    /// the directory got no context at all for as long as passes were
    /// re-armed.
    func testAReArmedRecoveryPassEndsTheWaitAfterOneIteration() async throws {
        let fixture = try await provisionalRootFixture(keyByte: 0xea)
        let parentService = networkService(
            process: fixture.parentProcess,
            runtime: fixture.parentRuntime
        )
        let builds = NetworkEventRecorder()
        let recorder = ParentTipRecordingDelegate(forwardingTo: fixture.childRuntime)
        let rearm = RearmSwitch()
        func stopAll() async {
            await rearm.turnOff()
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
        }
        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess,
                chain: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                chain: recordingChildHandlers(fixture, builds: builds, admits: false)
            )
            await fixture.childRuntime.hierarchy.installTestDelegate(recorder)
            let first = try await firstHeldCandidate(fixture)
            let parentRuntime = fixture.parentRuntime
            await parentRuntime.setChildProofRecoveryIterationForTesting { [weak parentRuntime] in
                guard await rearm.isOn else { return }
                await parentRuntime?.rearmChildProofRecoveryForTesting()
                try? await Task.sleep(for: .milliseconds(20))
            }
            await parentRuntime.rearmChildProofRecoveryForTesting()
            let carrier = try await storeCarrierBlock(
                of: first, fixture: fixture, withEvidence: false
            )
            let carrierCID = try BlockHeader(node: carrier).rawCID
            let heldBefore = await parentRuntime.debugParentTipNaming().heldBackCount
            try await admitCarrierThroughService(
                carrier, service: parentService, fixture: fixture
            )
            try await eventually("the carrier's context reaches the child", within: .seconds(10)) {
                !recorder.contexts(forTip: carrierCID).isEmpty
            }
            XCTAssertEqual(recorder.contexts(forTip: carrierCID).map(\.carried), [nil])
            let heldAfter = await parentRuntime.debugParentTipNaming().heldBackCount
            XCTAssertGreaterThan(heldAfter, heldBefore, "the push waited first")
            let stillRearming = await rearm.isOn
            XCTAssertTrue(stillRearming, "sent while the pass kept iterating")
            await stopAll()
        } catch {
            await stopAll()
            throw error
        }
    }

    /// The carried block's proof is prepared but its route is not owed
    /// (the state of a parent below the root whose carrier has no root yet:
    /// the proof is ready, the evidence cannot be issued, and no work here
    /// would change that). The context goes out on the carrier's tip at
    /// once, without naming the block and without holding the push back.
    func testACarriedBlockWhoseRouteIsNotOwedIsSentUnnamedAtOnce() async throws {
        let fixture = try await provisionalRootFixture(keyByte: 0xee)
        let builds = NetworkEventRecorder()
        let recorder = ParentTipRecordingDelegate(forwardingTo: fixture.childRuntime)
        func stopAll() async {
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
        }
        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess,
                chain: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                chain: recordingChildHandlers(fixture, builds: builds, admits: false)
            )
            await fixture.childRuntime.hierarchy.installTestDelegate(recorder)
            let first = try await firstHeldCandidate(fixture)
            let carrier = try await storeCarrierBlock(
                of: first, fixture: fixture, withEvidence: false
            )
            let carrierCID = try BlockHeader(node: carrier).rawCID
            // Admitted with no directory to prepare: no route recorded.
            await fixture.parentProcess.serveRuns(for: "Payments")
            let admitted = try await fixture.parentProcess.importBlock(
                try BlockHeader(node: carrier)
            )
            XCTAssertTrue(admitted.decision.isAccepted, "\(admitted.decision)")
            // The proof is prepared afterwards: ready, not promoted, not owed.
            _ = try await fixture.parentProcess.prepareChildProofs(
                for: carrier, children: [first], capacity: 16
            )
            let owed = try await fixture.parentProcess.pendingChildProofCarrierCIDs()
            XCTAssertFalse(owed.contains(carrierCID), "no route owed")
            let heldBefore = await fixture.parentRuntime.debugParentTipNaming().heldBackCount
            await fixture.parentRuntime.chainStateChanged()
            try await eventually("the carrier's context reaches the child") {
                !recorder.contexts(forTip: carrierCID).isEmpty
            }
            XCTAssertEqual(recorder.contexts(forTip: carrierCID).map(\.carried), [nil])
            let heldAfter = await fixture.parentRuntime.debugParentTipNaming().heldBackCount
            XCTAssertEqual(heldAfter, heldBefore, "nothing owed: no push held back")
            await stopAll()
        } catch {
            await stopAll()
            throw error
        }
    }

    /// The parent's hint for the carried block is queued behind an earlier
    /// hint whose attachment turns out unavailable, so the hint's append
    /// ends without trying the block. The context naming the block arrived
    /// while that append was in flight: its evidence is seeded on its own
    /// (the reserved slot inherits no earlier append's failure), so the
    /// hold holds until the block is tried, and it is admitted. Before, the
    /// context skipped the seed for evidence already in flight, and the
    /// hold was released when that append settled.
    func testANamedBlockBehindAnUnavailableHintIsStillTried() async throws {
        let fixture = try await provisionalRootFixture(keyByte: 0xf2)
        let parentService = networkService(
            process: fixture.parentProcess,
            runtime: fixture.parentRuntime
        )
        let probe = EvidenceServeProbe()
        let builds = NetworkEventRecorder()
        func stopAll() async {
            await probe.release.open()
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
        }
        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess,
                chain: inertNetworkHandlers()
            )
            await fixture.parentRuntime.hierarchy.setContentSource(
                ProbedContentSource(parent: fixture.parentProcess, probe: probe)
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                chain: recordingChildHandlers(fixture, builds: builds, admits: true)
            )
            let first = try await firstHeldCandidate(fixture)
            let firstCID = try BlockHeader(node: first.block).rawCID
            let buildsBeforeCarry = await builds.snapshot().count

            // An earlier hint whose attachment stalls, then is unavailable.
            let stalledChild = testCID("stalled-hint-child")
            let stalledAttachment = testCID("stalled-hint-attachment")
            await probe.stall(stalledAttachment)
            let hint = try ChildEvidenceAvailableMessage(
                childPath: fixture.childConfiguration.chainPath,
                sourceID: testEvidenceSourceID,
                ordinal: 9_999,
                childCID: stalledChild,
                rootCID: testCID("stalled-hint-root"),
                attachmentCID: stalledAttachment
            ).encoded()
            _ = await fixture.parentRuntime.hierarchy.sendMessage(
                to: PeerID(publicKey: fixture.childConfiguration.processPublicKey),
                topic: NodeNetworkTopic.childEvidenceAvailable,
                payload: hint
            )
            try await eventually("the earlier hint's recovery stalls") {
                await fixture.childRuntime.debugCarriedHold()
                    .evidenceInFlight[stalledChild] != nil
            }

            let carrier = try await storeCarrier(
                of: first, fixture: fixture, withEvidence: true
            )
            try await admitCarrier(
                carrier, service: parentService, fixture: fixture, withEvidence: true
            )
            try await eventually("the context names the carried block") {
                await fixture.childRuntime.debugSnapshot().receivedCarriedChildCID
                    == firstCID
            }
            await probe.release.open()
            try await eventually("the carried block is admitted") {
                await fixture.childProcess.hasAcceptedBlock(firstCID)
            }
            let released = await fixture.childRuntime.debugCarriedHold().released
            XCTAssertNotEqual(released, firstCID, "the hold was never released")
            try await eventually("the child builds on the carried block") {
                await builds.snapshot().dropFirst(buildsBeforeCarry).contains("2")
            }
            let afterCarry = Array(await builds.snapshot().dropFirst(buildsBeforeCarry))
            XCTAssertFalse(afterCarry.contains("1"), "a sibling was built: \(afterCarry)")
            await stopAll()
        } catch {
            await stopAll()
            throw error
        }
    }

    /// The parent restarts with a carried block's route still owed: after
    /// the child reconnects, the push waits for a recovery iteration, and the
    /// first context the child gets on that tip names the block, with its
    /// evidence issued. Without the wait it would go out unnamed.
    func testAfterARestartThePushWaitsForTheRecoveryPass() async throws {
        let fixture = try await provisionalRootFixture(keyByte: 0xd6)
        let parentService = networkService(
            process: fixture.parentProcess,
            runtime: fixture.parentRuntime
        )
        let builds = NetworkEventRecorder()
        let recorder = ParentTipRecordingDelegate(forwardingTo: fixture.childRuntime)
        let passes = Latch()
        func stopAll() async {
            await passes.open()
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
        }
        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess,
                chain: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                chain: recordingChildHandlers(fixture, builds: builds, admits: false)
            )
            await fixture.childRuntime.hierarchy.installTestDelegate(recorder)
            let first = try await firstHeldCandidate(fixture)
            let firstCID = try BlockHeader(node: first.block).rawCID
            let carrier = try await storeCarrierBlock(
                of: first, fixture: fixture, withEvidence: false
            )
            let carrierCID = try BlockHeader(node: carrier).rawCID
            try await admitCarrierThroughService(
                carrier, service: parentService, fixture: fixture
            )
            try await eventually("the carrier's context went out unnamed") {
                recorder.contexts(forTip: carrierCID).map(\.carried) == [nil]
            }

            // Down, the proof becomes buildable; the route is still owed.
            await fixture.parentRuntime.stop()
            _ = try await fixture.parentProcess.prepareChildProofs(
                for: carrier, children: [first], capacity: 16
            )
            let owed = try await fixture.parentProcess.pendingChildProofCarrierCIDs()
            XCTAssertTrue(owed.contains(carrierCID), "\(owed)")
            recorder.reset()
            // Every pass waits until the test lets it through.
            await fixture.parentRuntime.setChildProofRecoveryIterationForTesting {
                await passes.wait()
            }
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess,
                chain: inertNetworkHandlers()
            )
            try await eventually("the reconnected child's push is held back") {
                await fixture.parentRuntime.debugParentTipNaming().heldBack == ["Payments"]
            }
            let early = recorder.contexts(forTip: carrierCID)
            XCTAssertEqual(early, [], "nothing on the carrier's tip before the pass")
            await passes.open()
            try await eventually("the context names the carried block") {
                !recorder.contexts(forTip: carrierCID).isEmpty
            }
            XCTAssertEqual(
                recorder.contexts(forTip: carrierCID).first?.carried, firstCID,
                "the first context on the tip after the restart names the block"
            )
            await stopAll()
        } catch {
            await stopAll()
            throw error
        }
    }

    /// The parent reorgs off the carrier while the child's push is held
    /// back behind the carried block's evidence (the recovery iteration kept
    /// running): the new tip carries nothing into the child, so its
    /// context goes out at once, without waiting for the iteration.
    func testAReorgWhileThePushIsHeldBackSendsTheNewTip() async throws {
        let fixture = try await provisionalRootFixture(keyByte: 0xda)
        let parentService = networkService(
            process: fixture.parentProcess,
            runtime: fixture.parentRuntime
        )
        let builds = NetworkEventRecorder()
        let recorder = ParentTipRecordingDelegate(forwardingTo: fixture.childRuntime)
        let passes = Latch()
        func stopAll() async {
            await passes.open()
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
        }
        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess,
                chain: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                chain: recordingChildHandlers(fixture, builds: builds, admits: false)
            )
            await fixture.childRuntime.hierarchy.installTestDelegate(recorder)
            let first = try await firstHeldCandidate(fixture)
            let base = try await fixture.parentProcess.validatedTipBlock()
            await fixture.parentRuntime.setChildProofRecoveryIterationForTesting {
                await passes.wait()
            }
            let carrier = try await storeCarrierBlock(
                of: first, fixture: fixture, withEvidence: false
            )
            let carrierCID = try BlockHeader(node: carrier).rawCID
            try await admitCarrierThroughService(
                carrier, service: parentService, fixture: fixture
            )
            try await eventually("the push is held back behind the evidence") {
                await fixture.parentRuntime.debugParentTipNaming().heldBack == ["Payments"]
            }
            let passesBefore = await fixture.parentRuntime.debugParentTipNaming().recoveryIterations

            // A heavier branch on the carrier's parent, carrying nothing.
            var tip = base
            for step in 1...2 {
                let unmined = try await BlockBuilder.buildBlock(
                    previous: tip,
                    timestamp: base.timestamp + 2_000 * Int64(step),
                    nonce: 0,
                    fetcher: fixture.parentProcess
                )
                let mined = try XCTUnwrap(BlockBuilder.mine(
                    block: unmined, target: tip.nextTarget
                ))
                let admitted = try await fixture.parentProcess.importBlock(
                    try BlockHeader(node: mined)
                )
                XCTAssertTrue(admitted.decision.isAccepted, "\(admitted.decision)")
                tip = mined
            }
            let reorgCID = try BlockHeader(node: tip).rawCID
            await fixture.parentRuntime.chainStateChanged()
            try await eventually("the new tip's context reaches the child") {
                !recorder.contexts(forTip: reorgCID).isEmpty
            }
            XCTAssertEqual(recorder.contexts(forTip: reorgCID).map(\.carried), [nil])
            XCTAssertEqual(
                recorder.contexts(forTip: carrierCID), [],
                "the held-back context never went out"
            )
            let passesAfter = await fixture.parentRuntime.debugParentTipNaming().recoveryIterations
            XCTAssertEqual(passesAfter, passesBefore, "sent before a recovery iteration completed")
            await stopAll()
        } catch {
            await stopAll()
            throw error
        }
    }

    private func carriedAnnouncer(keyByte: UInt8) -> Ivy {
        Ivy(config: IvyConfig(
            signingKey: signingKey(keyByte &+ 0x40),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
    }

    private func firstHeldCandidate(
        _ fixture: ProvisionalRootFixture
    ) async throws -> DirectChildCandidate {
        var held: [DirectChildCandidate] = []
        try await eventually("the child's first candidate is held") {
            held = await fixture.parentRuntime.directChildCandidates(fixture.context)
            return !held.isEmpty
        }
        return try XCTUnwrap(held.first)
    }

    /// Connects `attacker` to the child's overlay and announces `cid` every
    /// 100 ms: a no-op while the attempt exists, a re-creation once it is
    /// ever reclaimed.
    private func announceRepeatedly(
        _ cid: String,
        from attacker: Ivy,
        to fixture: ProvisionalRootFixture
    ) async throws -> Task<Void, Never> {
        let childPeer = PeerID(publicKey: fixture.childConfiguration.processPublicKey)
        try await connectAndHello(
            attacker,
            peerID: childPeer,
            endpoint: PeerEndpoint(
                publicKey: fixture.childConfiguration.processPublicKey,
                host: "127.0.0.1",
                port: fixture.childConfiguration.listenPort
            ),
            hello: try ChainHello(
                nexusGenesisCID: fixture.childConfiguration.nexusGenesisCID,
                chainPath: fixture.childConfiguration.chainPath
            ).encode()
        )
        let payload = try BlockAnnouncementMessage(blockCID: cid).encoded()
        return Task {
            while !Task.isCancelled {
                _ = await attacker.sendMessage(
                    to: childPeer,
                    topic: NodeNetworkTopic.blockAnnouncement,
                    payload: payload
                )
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Adds a new overlay provider for `cid` every second (a fresh key,
    /// kept connected, stalling every Volume request), up to 20: each one
    /// changes the block's provider entry while an attempt is in flight.
    private func churnAnnouncers(
        _ cid: String,
        stalled: Latch,
        to fixture: ProvisionalRootFixture
    ) throws -> Task<Void, Never> {
        let childPeer = PeerID(publicKey: fixture.childConfiguration.processPublicKey)
        let endpoint = PeerEndpoint(
            publicKey: fixture.childConfiguration.processPublicKey,
            host: "127.0.0.1",
            port: fixture.childConfiguration.listenPort
        )
        let hello = try ChainHello(
            nexusGenesisCID: fixture.childConfiguration.nexusGenesisCID,
            chainPath: fixture.childConfiguration.chainPath
        ).encode()
        let payload = try BlockAnnouncementMessage(blockCID: cid).encoded()
        return Task {
            var churners: [Ivy] = []
            while !Task.isCancelled, churners.count < 20 {
                let churner = Ivy(config: IvyConfig(
                    signingKey: Curve25519.Signing.PrivateKey(),
                    listenPort: 0,
                    stunServers: [],
                    healthConfig: PeerHealthConfig(enabled: false),
                    mode: .overlay
                ))
                await churner.setContentSource(StallingContentSource(release: stalled))
                churners.append(churner)
                do {
                    try await churner.start()
                    try await churner.connect(to: endpoint)
                    for _ in 0..<50 where !(await churner.connectedPeers).contains(childPeer) {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    _ = await churner.sendMessage(
                        to: childPeer,
                        topic: NodeNetworkTopic.overlayHello,
                        payload: hello
                    )
                    try await Task.sleep(for: .milliseconds(50))
                    _ = await churner.sendMessage(
                        to: childPeer,
                        topic: NodeNetworkTopic.blockAnnouncement,
                        payload: payload
                    )
                } catch {}
                try? await Task.sleep(for: .seconds(1))
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            for churner in churners { await churner.stop() }
        }
    }

    /// Relays, from `relay`, a portable attachment for `candidate` under a
    /// made-up root (a Nexus genesis that commits to it, no parent block),
    /// until the child fetched it and tracks a packaged attempt.
    private func relayFabricatedAttachment(
        for candidate: DirectChildCandidate,
        from relay: Ivy,
        fixture: ProvisionalRootFixture
    ) async throws {
        let content = InMemoryContentStore()
        let fetcher = CoalescingFetcher(CompositeContentSource([
            content, fixture.parentProcess, fixture.childProcess,
        ]))
        let root = try await BlockBuilder.buildGenesis(
            spec: NexusGenesis.spec,
            children: ["Payments": candidate.block],
            timestamp: 3,
            target: UInt256.max,
            fetcher: fetcher
        )
        let rootHeader = try BlockHeader(node: root)
        try await rootHeader.storeBlock(fetcher: fetcher, storer: content)
        let proof = try await ChildBlockProof.generate(
            rootHeader: rootHeader,
            childDirectory: "Payments",
            fetcher: fetcher
        )
        let derivedEdge = await DirectChildEdge.derive(from: proof)
        let edge = try XCTUnwrap(derivedEdge)
        let childCID = try BlockHeader(node: candidate.block).rawCID
        let attachment = try ChildEvidenceVolume(
            envelopeBytes: try ChildValidationPackageEnvelope(
                ChildValidationPackage(proof: proof)
            ).encode(),
            childCID: childCID
        )
        let source = AttachmentSource(
            root: attachment.rawCID,
            entries: attachment.serialized.entries
        )
        await relay.setContentSource(source)
        let childPeer = PeerID(publicKey: fixture.childConfiguration.processPublicKey)
        try await connectAndHello(
            relay,
            peerID: childPeer,
            endpoint: PeerEndpoint(
                publicKey: fixture.childConfiguration.processPublicKey,
                host: "127.0.0.1",
                port: fixture.childConfiguration.listenPort
            ),
            hello: try ChainHello(
                nexusGenesisCID: fixture.childConfiguration.nexusGenesisCID,
                chainPath: fixture.childConfiguration.chainPath
            ).encode()
        )
        let payload = try PortableAttachmentAvailableMessage(
            edgeCID: try XCTUnwrap(edge.edgeCID),
            rootCID: proof.rootCID,
            attachmentCID: attachment.rawCID
        ).encoded()
        // Hints are dropped until the relay's hello is processed: re-send.
        try await eventually("the fabricated attachment was fetched") {
            if await source.wasServed() { return true }
            _ = await relay.sendMessage(
                to: childPeer,
                topic: NodeNetworkTopic.portableAttachmentAvailable,
                payload: payload
            )
            try await Task.sleep(for: .milliseconds(100))
            return false
        }
        try await eventually("the relayed package is an attempt") {
            await fixture.childRuntime.blockFetcher.tracks(childCID)
        }
    }

    /// Builds and stores the parent block that carries `candidate`. With
    /// `withEvidence`, its child proof is prepared, as the mined-block path
    /// does, so its admission issues (and pushes) the child's evidence.
    private func storeCarrier(
        of candidate: DirectChildCandidate,
        fixture: ProvisionalRootFixture,
        withEvidence: Bool
    ) async throws -> BlockHeader {
        try BlockHeader(node: try await storeCarrierBlock(
            of: candidate, fixture: fixture, withEvidence: withEvidence
        ))
    }

    /// `storeCarrier`, returning the block. Stored without its evidence,
    /// the parent holds the carrier but not the child block it commits
    /// (a block's content excludes its child blocks), so it cannot build
    /// the child's proof until one is prepared from the block.
    private func storeCarrierBlock(
        of candidate: DirectChildCandidate,
        fixture: ProvisionalRootFixture,
        withEvidence: Bool
    ) async throws -> Block {
        let parentTip = try await fixture.parentProcess.validatedTipBlock()
        let carrier = try await BlockBuilder.buildBlock(
            previous: parentTip,
            children: ["Payments": candidate.block],
            timestamp: parentTip.timestamp + 1_000,
            nonce: 7,
            fetcher: CoalescingFetcher(CompositeContentSource([
                fixture.parentProcess, fixture.childProcess,
            ]))
        )
        let carrierHeader = try BlockHeader(node: carrier)
        try await carrierHeader.storeBlock(
            fetcher: CoalescingFetcher(CompositeContentSource([
                fixture.parentProcess, fixture.childProcess,
            ])),
            storer: fixture.parentProcess
        )
        if withEvidence {
            _ = try await fixture.parentProcess.prepareChildProofs(
                for: carrier,
                children: [candidate],
                capacity: 16
            )
        }
        return carrier
    }

    /// Admits the carrier on the parent. With `withEvidence`, through the
    /// service (which publishes the prepared child proof); without, straight
    /// at the process: the parent's context names the carried block, but it
    /// has no evidence to serve for it.
    private func admitCarrier(
        _ carrierHeader: BlockHeader,
        service: ChainService,
        fixture: ProvisionalRootFixture,
        withEvidence: Bool
    ) async throws {
        guard withEvidence else {
            await fixture.parentProcess.serveRuns(for: "Payments")
            let carried = try await fixture.parentProcess.importBlock(carrierHeader)
            XCTAssertTrue(carried.decision.isAccepted, "\(carried.decision)")
            await fixture.parentRuntime.chainStateChanged()
            return
        }
        let carried = try await service.importNetworkCandidate(
            carrierHeader,
            authenticatedChildPackage: nil,
            preparingChildDirectories: ["Payments"],
            contentSource: fixture.parentProcess
        )
        XCTAssertTrue(carried.decision.isAccepted, "\(carried.decision)")
    }

    /// A weighed block ahead of the validated tip with no walk stepping —
    /// parked on a fact it cannot get, or never armed — does not withhold
    /// the child's candidate: the child builds on its validated tip, since
    /// that is how a chain outweighs a branch it cannot validate.
    func testAParkedExecutionWalkDoesNotWithholdTheChildsCandidate() async throws {
        let fixture = try await provisionalRootFixture(keyByte: 0x9c)
        // No evidence source: the walk the deferral arms parks on the
        // continuity fact it cannot get, and the retry is out of the way.
        let childRuntime = fixture.childRuntime
        let childService = ChainService(
            process: fixture.childProcess,
            network: ClosureNetworkInterface(
                childCandidateProvider: { _ in [] },
                chainStateChangePublisher: { [weak childRuntime] in
                    await childRuntime?.chainStateChanged()
                },
                childProofPublisher: { _ in },
                acceptedBlockPublisher: { _ in }
            ),
            executionWalkRetryInterval: .seconds(60)
        )
        let childHandlers = ClosureChainInterface(
            childCandidateBuilder: { [weak childService] context, parentSource in
                guard let childService else { return nil }
                return try await childService.miningCandidate(
                    for: context,
                    parentContentSource: parentSource
                )
            },
            admission: { _ in throw CancellationError() }
        )
        let weighedOnly = try await weighedOnlyChildBlock(fixture)
        let tips = await fixture.childProcess.metricsTipHeights()
        XCTAssertEqual(tips.weighed, 1)
        XCTAssertEqual(tips.validated, 0)

        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess,
                chain: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                chain: childHandlers
            )
            var held: [DirectChildCandidate] = []
            for _ in 0..<250 {
                held = await fixture.parentRuntime.directChildCandidates(fixture.context)
                if !held.isEmpty { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(held.count, 1, "offered with the walk parked")
            XCTAssertEqual(held.first?.block.height, 1, "built on the validated tip")
            XCTAssertNotEqual(
                held.first.map { try? BlockHeader(node: $0.block).rawCID },
                weighedOnly.header.rawCID
            )
        } catch {
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
            throw error
        }
        await fixture.childRuntime.stop()
        await fixture.parentRuntime.stop()
    }

    /// A child whose last candidate landed and awaits validation builds no
    /// other (a second at the same height would only fork it): the request
    /// arms the walk if nothing did, and while the walk steps nothing is
    /// built either. When the walk stops, the service reports a state
    /// change so the deferred candidate is offered, built on the tip the
    /// walk reached.
    func testChildCandidateWaitsWhileTheExecutionWalkSteps() async throws {
        let fixture = try await provisionalRootFixture(keyByte: 0x9d)
        let weighedOnly = try await weighedOnlyChildBlock(fixture)
        let gate = Latch()
        let changes = NetworkEventRecorder()
        let parentProcess = fixture.parentProcess
        let package = weighedOnly.package
        let childService = ChainService(
            process: fixture.childProcess,
            network: ClosureNetworkInterface(
                childCandidateProvider: { _ in [] },
                chainStateChangePublisher: { await changes.append("change") },
                childProofPublisher: { _ in },
                acceptedBlockPublisher: { _ in },
                executionBodySource: { _, admit in
                    await gate.wait()
                    return try await admit(parentProcess)
                },
                validateEvidenceSource: { _, _ in package }
            )
        )
        // Behind and not parked: the request itself is refused and arms the
        // walk, whose first step then holds at the gate.
        var behind: Error?
        do {
            _ = try await childService.miningCandidate(
                for: fixture.context,
                parentContentSource: parentProcess
            )
        } catch {
            behind = error
        }
        guard case .validateWalkInProgress? = behind as? ChainServiceError else {
            return XCTFail("expected the candidate deferred while behind, got \(String(describing: behind))")
        }
        for _ in 0..<250 {
            if await gate.isHeld { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let stepping = await gate.isHeld
        XCTAssertTrue(stepping, "the walk is mid-step")

        var deferred: Error?
        do {
            _ = try await childService.miningCandidate(
                for: fixture.context,
                parentContentSource: parentProcess
            )
        } catch {
            deferred = error
        }
        guard case .validateWalkInProgress? = deferred as? ChainServiceError else {
            return XCTFail("expected the candidate deferred, got \(String(describing: deferred))")
        }
        let changesBeforeRelease = await changes.snapshot().count

        await gate.open()
        var built: DirectChildCandidate?
        for _ in 0..<250 {
            built = try? await childService.miningCandidate(
                for: fixture.context,
                parentContentSource: parentProcess
            )
            if built != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(built?.block.height, 2, "built on the tip the walk reached")
        let validated = await fixture.childProcess.metricsTipHeights().validated
        XCTAssertEqual(validated, 1)
        // One report for the step, one more for the walk stopping: the
        // second is what turns the deferral into an offer.
        var changesAfter = 0
        for _ in 0..<100 {
            changesAfter = await changes.snapshot().count
            if changesAfter - changesBeforeRelease >= 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThanOrEqual(changesAfter - changesBeforeRelease, 2)
    }

    /// A child block the fixture child has weighed but not executed: its
    /// weighed tip is ahead of its validated tip. The fixture's child genesis
    /// is self-contained (empty parent state), so the block's package carries
    /// the continuity fact the runtime would otherwise fetch.
    private func weighedOnlyChildBlock(
        _ fixture: ProvisionalRootFixture
    ) async throws -> (header: BlockHeader, package: AuthenticatedChildPackage) {
        let childGenesis = try await fixture.childProcess.validatedTipBlock()
        let weighedOnly = try await BlockBuilder.buildBlock(
            previous: childGenesis,
            parentChainBlock: fixture.context.parentCarrier,
            timestamp: childGenesis.timestamp + 1_000,
            target: .max,
            fetcher: CoalescingFetcher(CompositeContentSource([
                fixture.childProcess, fixture.parentProcess,
            ]))
        )
        let weighedHeader = try BlockHeader(node: weighedOnly)
        try await weighedHeader.storeBlock(
            fetcher: fixture.parentProcess, storer: fixture.childProcess
        )
        // The parent carries it (a carrier with no transactions leaves the
        // parent's post-state, so the fixture context still fits).
        let parentTip = try await fixture.parentProcess.validatedTipBlock()
        let carrier = try await BlockBuilder.buildBlock(
            previous: parentTip,
            children: ["Payments": weighedOnly],
            timestamp: parentTip.timestamp + 1_000,
            nonce: 5,
            fetcher: fixture.parentProcess
        )
        let carrierHeader = try BlockHeader(node: carrier)
        let carried = try await fixture.parentProcess.importBlock(carrierHeader)
        XCTAssertTrue(carried.decision.isAccepted, "\(carried.decision)")
        let proof = try await ChildBlockProof.generate(
            rootHeader: carrierHeader,
            childDirectory: "Payments",
            fetcher: fixture.parentProcess
        )
        let package = AuthenticatedChildPackage(
            package: ChildValidationPackage(
                proof: proof,
                parentStateContinuityLink: ParentStateContinuityLink(
                    parentPath: ["Nexus"],
                    fromStateCID: childGenesis.parentState.rawCID,
                    toStateCID: weighedOnly.parentState.rawCID
                )
            )
        )
        let weighed = try await fixture.childProcess.importBlock(
            weighedHeader,
            authenticatedChildPackage: package,
            remoteSource: fixture.parentProcess,
            mode: .header
        )
        XCTAssertTrue(weighed.decision.isAccepted, "\(weighed.decision)")
        return (weighedHeader, package)
    }

    private func provisionalRootFixture(
        keyByte: UInt8,
        childInboxCapacity: Int = 64
    ) async throws -> ProvisionalRootFixture {
        let parentStorage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-provisional-parent-\(UUID().uuidString)",
            isDirectory: true
        )
        let childStorage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-provisional-child-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: parentStorage)
            try? FileManager.default.removeItem(at: childStorage)
        }
        let parentConfiguration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: parentStorage,
            privateKeyHex: String(
                repeating: String(format: "%02x", keyByte),
                count: 32
            ),
            listenPort: NetworkTransportTestPorts.allocate(),
            factListenPort: NetworkTransportTestPorts.allocate(),
            rpcPort: NetworkTransportTestPorts.allocate()
        )
        let childConfiguration = try NodeConfiguration(
            chainPath: ["Nexus", "Payments"],
            storagePath: childStorage,
            privateKeyHex: String(
                repeating: String(format: "%02x", keyByte &+ 1),
                count: 32
            ),
            listenPort: NetworkTransportTestPorts.allocate(),
            factListenPort: NetworkTransportTestPorts.allocate(),
            rpcPort: NetworkTransportTestPorts.allocate(),
            parentEndpoint: ParentEndpoint(
                publicKey: parentConfiguration.processPublicKey,
                host: "127.0.0.1",
                port: parentConfiguration.factListenPort
            ),
            resourcePolicy: NodeResourcePolicy(
                maximumPendingParentEvidence: childInboxCapacity
            )
        )
        let parentRuntime = try NodeNetworkRuntime(configuration: parentConfiguration)
        let childRuntime = try NodeNetworkRuntime(
            configuration: childConfiguration
        )
        let parentProcess = try await ChainProcess.open(
            configuration: parentConfiguration
        )
        let childProcess = try await ChainProcess.open(
            configuration: childConfiguration
        )
        let parentGenesis = try await parentProcess.canonicalTipBlock()
        let timestamp = parentGenesis.timestamp + 3_600_000
        // A self-contained child genesis (empty parentState): the parent only
        // RECORDS its CID via a plain GenesisAction; the child rebuilds it from
        // the same seed and self-admits it. It is never carried on the carrier.
        let seed = ChildGenesisSeed(
            spec: NexusGenesis.spec, premineTo: nil, timestamp: timestamp
        )
        let childGenesis = try await ChildGenesisBuilder.build(
            seed: seed,
            chainPath: childConfiguration.chainPath,
            fetcher: parentProcess
        )
        let childHeader = try BlockHeader(node: childGenesis)
        let authorization = try signedGenesisAnchorTransaction(
            directory: "Payments",
            childGenesisCID: childHeader.rawCID,
            chainPath: parentConfiguration.chainPath
        )
        try await VolumeImpl<Transaction>(node: authorization).storeRecursively(
            storer: parentProcess
        )
        let carrier = try await BlockBuilder.buildBlock(
            previous: parentGenesis,
            transactions: [authorization],
            timestamp: timestamp,
            nonce: 1,
            fetcher: parentProcess
        )
        let carrierHeader = try BlockHeader(node: carrier)
        let carrierAdmission = try await parentProcess.importBlock(carrierHeader)
        XCTAssertTrue(carrierAdmission.decision.isAccepted)
        let activated = try await childProcess.activateSeededChildGenesis(
            seed: seed,
            confirmParentRecordedGenesis: { _ in true }
        )
        XCTAssertTrue(activated)

        let provisional = try await BlockBuilder.buildBlock(
            previous: carrier,
            timestamp: timestamp + 3_600_000,
            nonce: 2,
            fetcher: parentProcess
        )
        // The fixture candidate is a co-mined height-1 child block bound to the
        // provisional parent carrier (a genesis is never a candidate).
        let candidateBlock = try await BlockBuilder.buildBlock(
            previous: childGenesis,
            parentChainBlock: provisional,
            timestamp: provisional.timestamp,
            target: .max,
            fetcher: CoalescingFetcher(CompositeContentSource([
                childProcess, parentProcess,
            ]))
        )
        return ProvisionalRootFixture(
            childConfiguration: childConfiguration,
            parentRuntime: parentRuntime,
            childRuntime: childRuntime,
            parentProcess: parentProcess,
            childProcess: childProcess,
            context: ChildCandidateRequestContext(
                parentCarrier: provisional,
                rewards: []
            ),
            candidate: DirectChildCandidate(
                directory: "Payments",
                block: candidateBlock
            )
        )
    }

    private func waitForChildCandidate(
        _ fixture: ProvisionalRootFixture
    ) async throws {
        try await eventually("direct child candidate session") {
            await fixture.parentRuntime.directChildCandidates(fixture.context).count == 1
        }
    }
}

extension NodeNetworkRuntime {
    /// Holds every evidence Volume slot with overlay work, as a burst of
    /// portable attachments would.
    fileprivate func fillEvidenceLaneForTesting() {
        for index in 0..<Self.maximumEvidenceCandidates {
            sessionLeases.activeEvidenceVolumes.insert(EvidenceVolumeLease(
                plane: .overlay,
                sessionID: Data([0xee]),
                attachmentCID: "lane-filler-\(index)"
            ))
        }
    }

    fileprivate func freeEvidenceLaneForTesting() {
        sessionLeases.activeEvidenceVolumes = sessionLeases.activeEvidenceVolumes
            .filter { !$0.attachmentCID.hasPrefix("lane-filler-") }
    }

    /// Arms another child-proof recovery pass, as an import or an overlay
    /// hello does.
    fileprivate func rearmChildProofRecoveryForTesting() {
        guard let process else { return }
        scheduleChildProofRecovery(generation: runtimeGeneration, process: process)
    }
}
