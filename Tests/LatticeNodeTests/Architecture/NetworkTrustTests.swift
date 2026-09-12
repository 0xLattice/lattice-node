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

private let testEvidenceSourceID = "00000000-0000-4000-8000-000000000001"

private enum NetworkTestError: Error {
    case failedStart
    case failedSend
    case failedPhase(String)
}

private func inertNetworkHandlers() -> NodeNetworkHandlers {
    NodeNetworkHandlers(admission: { _ in throw CancellationError() })
}

private func duplicateNetworkHandlers() -> NodeNetworkHandlers {
    NodeNetworkHandlers(admission: { _ in
        NodeAdmissionOutcome(
            decision: .duplicate,
            parentCarrierLink: nil,
            sameChainPredecessor: nil
        )
    })
}

private func testCID(_ seed: String) -> String {
    try! HeaderImpl<PublicKey>(node: PublicKey(key: seed)).rawCID
}

private enum NetworkRuntimeStartOutcome: Equatable, Sendable {
    case started
    case failed(NodeNetworkRuntimeError)
    case unexpected(String)
}

private actor NetworkEventRecorder {
    private var values: [String] = []
    func append(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
}

private actor ContentRequestRecorder {
    private var values: [String] = []
    func append(root: String) { values.append(root) }
    func snapshot() -> [String] { values }
}

/// Drops the first common-ancestor negotiation it receives, answers every
/// later one "caught up at your genesis", and counts forward-range pages.
private actor RangeNegotiationDroppingPeer: IvyDelegate {
    private var ancestorRequests = 0
    private var forwardRequests = 0

    func ivy(
        _ ivy: Ivy,
        didReceiveMessage message: PeerMessage,
        from peer: AuthenticatedPeer
    ) async {
        switch message.topic {
        case NodeNetworkTopic.ancestorRangeRequest:
            ancestorRequests += 1
            guard ancestorRequests > 1,
                  let request = try? AncestorRangeRequestMessage.decoded(
                    message.payload
                  ), let payload = try? AncestorRangeResponseMessage(
                    requestID: request.requestID,
                    commonAncestor: request.locator.last,
                    blockCIDs: [],
                    hasMore: false
                  ).encoded() else { return }
            _ = await ivy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.ancestorRangeResponse,
                payload: payload
            )
        case NodeNetworkTopic.forwardRangeRequest:
            forwardRequests += 1
        default:
            break
        }
    }

    func counts() -> (ancestor: Int, forward: Int) {
        (ancestorRequests, forwardRequests)
    }
}

private actor TopicRecorder {
    private var topics: [String] = []
    func append(_ topic: String) { topics.append(topic) }
    func contains(_ topic: String) -> Bool { topics.contains(topic) }
    func count(of topic: String) -> Int { topics.filter { $0 == topic }.count }
}

private actor AuthenticatedPeerRecorder: IvyDelegate {
    private var peer: AuthenticatedPeer?

    func ivy(_ ivy: Ivy, didConnect peer: AuthenticatedPeer) {
        self.peer = peer
    }

    func connectedPeer() -> AuthenticatedPeer? { peer }
}

private actor PayloadRecorder {
    private var events: [(topic: String, payload: Data)] = []

    func append(topic: String, payload: Data) {
        events.append((topic, payload))
    }
    func payloads(topic: String) -> [Data] {
        events.filter { $0.topic == topic }.map(\.payload)
    }
    func topics() -> [String] { events.map(\.topic) }
}

private final class PayloadRecordingPeer: IvyDelegate, Sendable {
    private let recorder: PayloadRecorder

    init(recorder: PayloadRecorder) {
        self.recorder = recorder
    }

    func ivy(
        _ ivy: Ivy,
        didReceiveMessage message: PeerMessage,
        from peer: AuthenticatedPeer
    ) async {
        await recorder.append(topic: message.topic, payload: message.payload)
    }
}

private final class TopicRecordingPeer: IvyDelegate, Sendable {
    private let recorder: TopicRecorder

    init(recorder: TopicRecorder) {
        self.recorder = recorder
    }

    func ivy(
        _ ivy: Ivy,
        didReceiveMessage message: PeerMessage,
        from peer: AuthenticatedPeer
    ) async {
        await recorder.append(message.topic)
    }
}

private final class TransactionTopicRecordingPeer: IvyDelegate, Sendable {
    private let recorder: TopicRecorder

    init(recorder: TopicRecorder) {
        self.recorder = recorder
    }

    func ivy(
        _ ivy: Ivy,
        didReceiveMessage message: PeerMessage,
        from peer: AuthenticatedPeer
    ) async {
        await recorder.append(message.topic)
        guard message.topic == NodeNetworkTopic.transactionInventoryRequest,
              let request = try? TransactionInventoryRequestMessage.decoded(
                message.payload
              ), let response = try? TransactionInventoryResponseMessage(
                requestID: request.requestID,
                afterRootCID: request.afterRootCID,
                volumeRootCIDs: [],
                hasMore: false
              ).encoded() else { return }
        _ = await ivy.sendMessage(
            to: peer,
            topic: NodeNetworkTopic.transactionInventoryResponse,
            payload: response
        )
    }
}

private actor EchoInventoryPeer: IvyDelegate {
    private let roots: [String]
    private var requests: [TransactionInventoryRequestMessage] = []

    init(roots: [String]) {
        self.roots = roots.sorted()
    }

    func ivy(
        _ ivy: Ivy,
        didReceiveMessage message: PeerMessage,
        from peer: AuthenticatedPeer
    ) async {
        guard message.topic == NodeNetworkTopic.transactionInventoryRequest,
              let request = try? TransactionInventoryRequestMessage.decoded(
                message.payload
              ) else { return }
        requests.append(request)
        let page = request.afterRootCID == nil ? roots : []
        guard let payload = try? TransactionInventoryResponseMessage(
            requestID: request.requestID,
            afterRootCID: request.afterRootCID,
            volumeRootCIDs: page,
            hasMore: !page.isEmpty
        ).encoded() else { return }
        _ = await ivy.sendMessage(
            to: peer,
            topic: NodeNetworkTopic.transactionInventoryResponse,
            payload: payload
        )
    }

    func continuationCount() -> Int {
        requests.filter { $0.afterRootCID != nil }.count
    }
}

/// A scripted overlay peer that announces its blocks once the runtime has
/// authorized the session. The runtime answers a hello with its own tip
/// announcement — the one wire-visible sign that the hello landed — and
/// each session is served exactly once.
private actor OverlayAnnouncingPeer: IvyDelegate {
    private let blocks: [String]
    private var authorizedSessions: [Data] = []

    init(announcing blocks: [String]) {
        self.blocks = blocks
    }

    func ivy(
        _ ivy: Ivy,
        didReceiveMessage message: PeerMessage,
        from peer: AuthenticatedPeer
    ) async {
        guard message.topic == NodeNetworkTopic.blockAnnouncement,
              !authorizedSessions.contains(peer.sessionID) else { return }
        authorizedSessions.append(peer.sessionID)
        for blockCID in blocks {
            guard let payload = try? BlockAnnouncementMessage(
                blockCID: blockCID
            ).encoded() else { continue }
            _ = await ivy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.blockAnnouncement,
                payload: payload
            )
        }
    }

    func authorizedSessionCount() -> Int { authorizedSessions.count }
}

/// A scripted overlay peer holding a main chain: announces its tip once per
/// session (on the runtime's hello-reply announcement), answers the
/// common-ancestor negotiation and forward pages from that chain, and records
/// the receiver's ACQUIRED height at the moment each frontier (accepted-
/// leaves) request arrives.
private actor RangeServingPeer: IvyDelegate {
    private let genesisCID: String
    /// Ascending, genesis excluded.
    private let chain: [String]
    private let receiver: ChainProcess
    /// The height announced once per session (defaults to the chain's).
    private let claimedHeight: UInt64
    private var authorizedSessions: [Data] = []
    private var frontierRequestHeights: [UInt64] = []
    private var forwardAfterCIDs: [String] = []

    init(
        genesisCID: String,
        chain: [String],
        receiver: ChainProcess,
        claimedHeight: UInt64? = nil
    ) {
        self.genesisCID = genesisCID
        self.chain = chain
        self.receiver = receiver
        self.claimedHeight = claimedHeight ?? UInt64(chain.count)
    }

    func ivy(
        _ ivy: Ivy,
        didReceiveMessage message: PeerMessage,
        from peer: AuthenticatedPeer
    ) async {
        switch message.topic {
        case NodeNetworkTopic.blockAnnouncement:
            guard !authorizedSessions.contains(peer.sessionID),
                  let tip = chain.last else { return }
            authorizedSessions.append(peer.sessionID)
            guard let payload = try? BlockAnnouncementMessage(
                blockCID: tip,
                height: claimedHeight
            ).encoded() else { return }
            _ = await ivy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.blockAnnouncement,
                payload: payload
            )
        case NodeNetworkTopic.ancestorRangeRequest:
            guard let request = try? AncestorRangeRequestMessage.decoded(
                message.payload
            ) else { return }
            // Locator is newest-first: the first hit is the highest shared.
            let ancestor = request.locator.first {
                $0 == genesisCID || chain.contains($0)
            }
            let page = ancestor.map { pageAfter($0) }
                ?? (blockCIDs: [], hasMore: false)
            guard let payload = try? AncestorRangeResponseMessage(
                requestID: request.requestID,
                commonAncestor: ancestor,
                blockCIDs: page.blockCIDs,
                hasMore: page.hasMore
            ).encoded() else { return }
            _ = await ivy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.ancestorRangeResponse,
                payload: payload
            )
        case NodeNetworkTopic.forwardRangeRequest:
            guard let request = try? ForwardRangeRequestMessage.decoded(
                message.payload
            ) else { return }
            forwardAfterCIDs.append(request.afterCID)
            let page = pageAfter(request.afterCID)
            guard let payload = try? ForwardRangeResponseMessage(
                requestID: request.requestID,
                afterCID: request.afterCID,
                blockCIDs: page.blockCIDs,
                hasMore: page.hasMore
            ).encoded() else { return }
            _ = await ivy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.forwardRangeResponse,
                payload: payload
            )
        case NodeNetworkTopic.acceptedLeavesRequest:
            frontierRequestHeights.append(
                await receiver.canonicalTipHeight() ?? 0
            )
        case NodeNetworkTopic.transactionInventoryRequest:
            // An unanswered inventory request recycles the session at the
            // request timeout, which would erase the runtime's recorded tip.
            await answerInventoryEmpty(ivy, message: message, peer: peer)
        default:
            break
        }
    }

    private func pageAfter(_ cid: String) -> (blockCIDs: [String], hasMore: Bool) {
        let start = cid == genesisCID
            ? 0
            : (chain.firstIndex(of: cid).map { $0 + 1 } ?? chain.count)
        let page = Array(
            chain[start...].prefix(ForwardRangeResponseMessage.maximumBlocks)
        )
        return (page, start + page.count < chain.count)
    }

    func frontierRequests() -> [UInt64] { frontierRequestHeights }
    func forwardRequests() -> [String] { forwardAfterCIDs }
}

/// Records every topic it receives and the requestID of each frontier
/// (accepted-leaves) request, so a test can answer — or fail to answer — it.
private actor FrontierRequestCapturingPeer: IvyDelegate {
    private var topics: [String] = []
    private var requestIDs: [UInt64] = []

    func ivy(
        _ ivy: Ivy,
        didReceiveMessage message: PeerMessage,
        from peer: AuthenticatedPeer
    ) async {
        topics.append(message.topic)
        if message.topic == NodeNetworkTopic.acceptedLeavesRequest,
           let request = try? AcceptedLeavesRequestMessage.decoded(
            message.payload
           ) {
            requestIDs.append(request.requestID)
        }
        if message.topic == NodeNetworkTopic.transactionInventoryRequest {
            await answerInventoryEmpty(ivy, message: message, peer: peer)
        }
    }

    func count(of topic: String) -> Int { topics.filter { $0 == topic }.count }
    func frontierRequestIDs() -> [UInt64] { requestIDs }
}

/// A peer that announces a tip the receiver lacks, negotiates GENESIS as the
/// common ancestor, and serves one full first page (with more claimed
/// beyond it); forward requests are recorded and answered empty.
private actor FullPagePeer: IvyDelegate {
    private let genesisCID: String
    private let page: [String]
    private let claimedHeight: UInt64
    private var authorizedSessions: [Data] = []
    private var forwardAfterCIDs: [String] = []

    private let hasMore: Bool

    init(
        genesisCID: String,
        page: [String],
        claimedHeight: UInt64,
        hasMore: Bool
    ) {
        self.genesisCID = genesisCID
        self.page = page
        self.claimedHeight = claimedHeight
        self.hasMore = hasMore
    }

    func ivy(
        _ ivy: Ivy,
        didReceiveMessage message: PeerMessage,
        from peer: AuthenticatedPeer
    ) async {
        switch message.topic {
        case NodeNetworkTopic.blockAnnouncement:
            guard !authorizedSessions.contains(peer.sessionID) else { return }
            authorizedSessions.append(peer.sessionID)
            guard let payload = try? BlockAnnouncementMessage(
                blockCID: testCID("full-page-tip"),
                height: claimedHeight
            ).encoded() else { return }
            _ = await ivy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.blockAnnouncement,
                payload: payload
            )
        case NodeNetworkTopic.ancestorRangeRequest:
            guard let request = try? AncestorRangeRequestMessage.decoded(
                message.payload
            ), request.locator.contains(genesisCID),
            let payload = try? AncestorRangeResponseMessage(
                requestID: request.requestID,
                commonAncestor: genesisCID,
                blockCIDs: page,
                hasMore: hasMore
            ).encoded() else { return }
            _ = await ivy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.ancestorRangeResponse,
                payload: payload
            )
        case NodeNetworkTopic.forwardRangeRequest:
            guard let request = try? ForwardRangeRequestMessage.decoded(
                message.payload
            ) else { return }
            forwardAfterCIDs.append(request.afterCID)
            guard let payload = try? ForwardRangeResponseMessage(
                requestID: request.requestID,
                afterCID: request.afterCID,
                blockCIDs: [],
                hasMore: false
            ).encoded() else { return }
            _ = await ivy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.forwardRangeResponse,
                payload: payload
            )
        case NodeNetworkTopic.transactionInventoryRequest:
            await answerInventoryEmpty(ivy, message: message, peer: peer)
        default:
            break
        }
    }

    func forwardRequests() -> [String] { forwardAfterCIDs }
}

/// A lying peer: claims a tall tip once per session, then answers every
/// locator negotiation with a valid common ancestor and an EMPTY page.
private actor EmptyAncestorPeer: IvyDelegate {
    private let claimedHeight: UInt64
    private var authorizedSessions: [Data] = []
    private var ancestorRequests = 0

    init(claimedHeight: UInt64) {
        self.claimedHeight = claimedHeight
    }

    func ivy(
        _ ivy: Ivy,
        didReceiveMessage message: PeerMessage,
        from peer: AuthenticatedPeer
    ) async {
        switch message.topic {
        case NodeNetworkTopic.blockAnnouncement:
            guard !authorizedSessions.contains(peer.sessionID) else { return }
            authorizedSessions.append(peer.sessionID)
            guard let payload = try? BlockAnnouncementMessage(
                blockCID: testCID("liar-tip"),
                height: claimedHeight
            ).encoded() else { return }
            _ = await ivy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.blockAnnouncement,
                payload: payload
            )
        case NodeNetworkTopic.ancestorRangeRequest:
            ancestorRequests += 1
            guard let request = try? AncestorRangeRequestMessage.decoded(
                message.payload
            ), let payload = try? AncestorRangeResponseMessage(
                requestID: request.requestID,
                commonAncestor: request.locator.last,
                blockCIDs: [],
                hasMore: false
            ).encoded() else { return }
            _ = await ivy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.ancestorRangeResponse,
                payload: payload
            )
        case NodeNetworkTopic.transactionInventoryRequest:
            await answerInventoryEmpty(ivy, message: message, peer: peer)
        default:
            break
        }
    }

    func ancestorRequestCount() -> Int { ancestorRequests }
}

/// A peer that claims a tall tip once per session and then never answers
/// the negotiation, so the receiver's range sync stays in flight.
private actor SilentDeepPeer: IvyDelegate {
    private let claimedHeight: UInt64
    private var authorizedSessions: [Data] = []
    private var ancestorRequests = 0

    init(claimedHeight: UInt64) {
        self.claimedHeight = claimedHeight
    }

    func ivy(
        _ ivy: Ivy,
        didReceiveMessage message: PeerMessage,
        from peer: AuthenticatedPeer
    ) async {
        switch message.topic {
        case NodeNetworkTopic.blockAnnouncement:
            guard !authorizedSessions.contains(peer.sessionID) else { return }
            authorizedSessions.append(peer.sessionID)
            guard let payload = try? BlockAnnouncementMessage(
                blockCID: testCID("deep-tip"),
                height: claimedHeight
            ).encoded() else { return }
            _ = await ivy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.blockAnnouncement,
                payload: payload
            )
        case NodeNetworkTopic.ancestorRangeRequest:
            ancestorRequests += 1
        case NodeNetworkTopic.transactionInventoryRequest:
            await answerInventoryEmpty(ivy, message: message, peer: peer)
        default:
            break
        }
    }

    func ancestorRequestCount() -> Int { ancestorRequests }
}

/// Answer a runtime's hello-reply inventory request with an empty page so the
/// scripted session survives past the request timeout.
private func answerInventoryEmpty(
    _ ivy: Ivy,
    message: PeerMessage,
    peer: AuthenticatedPeer
) async {
    guard let request = try? TransactionInventoryRequestMessage.decoded(
        message.payload
    ), let response = try? TransactionInventoryResponseMessage(
        requestID: request.requestID,
        afterRootCID: request.afterRootCID,
        volumeRootCIDs: [],
        hasMore: false
    ).encoded() else { return }
    _ = await ivy.sendMessage(
        to: peer,
        topic: NodeNetworkTopic.transactionInventoryResponse,
        payload: response
    )
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

private actor HierarchyRetryRecorder {
    private let withholdFirstHello: Bool
    private var evidenceIndexRequests = 0
    private var helloSessions: [Data] = []
    private var indexSessions: [Data] = []
    private var parentFactRequests = 0

    init(withholdFirstHello: Bool = false) {
        self.withholdFirstHello = withholdFirstHello
    }

    func record(_ topic: String, sessionID: Data) -> Bool {
        switch topic {
        case NodeNetworkTopic.hierarchyHello:
            if !helloSessions.contains(sessionID) {
                helloSessions.append(sessionID)
            }
            return withholdFirstHello && helloSessions.count == 1
        case NodeNetworkTopic.childEvidenceIndexRequest:
            evidenceIndexRequests += 1
            indexSessions.append(sessionID)
        case NodeNetworkTopic.parentChainFactRequest:
            parentFactRequests += 1
        default:
            break
        }
        return false
    }

    func sessionTrace() -> (hellos: [Data], indexes: [Data]) {
        (helloSessions, indexSessions)
    }

    func parentFactRequestCount() -> Int { parentFactRequests }
}

private final class HierarchyRetryPeer: IvyDelegate, Sendable {
    private let recorder: HierarchyRetryRecorder
    private let parentHello: Data
    private let summary: IssuedChildEvidenceSummary?

    init(
        recorder: HierarchyRetryRecorder,
        parentHello: Data,
        summary: IssuedChildEvidenceSummary?
    ) {
        self.recorder = recorder
        self.parentHello = parentHello
        self.summary = summary
    }

    func ivy(
        _ ivy: Ivy,
        didReceiveMessage message: PeerMessage,
        from peer: AuthenticatedPeer
    ) async {
        let withholdHello = await recorder.record(
            message.topic,
            sessionID: peer.sessionID
        )
        switch message.topic {
        case NodeNetworkTopic.hierarchyHello:
            guard !withholdHello else { return }
            _ = await ivy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.hierarchyHello,
                payload: parentHello
            )
        case NodeNetworkTopic.childEvidenceIndexRequest:
            guard let request = try? ChildEvidenceIndexRequestMessage.decoded(
                message.payload
            ), let payload = try? ChildEvidenceIndexResponseMessage(
                requestID: request.requestID,
                childPath: request.childPath,
                sourceID: testEvidenceSourceID,
                cursor: 0,
                through: summary?.ordinal ?? 0,
                entries: summary.map { [$0] } ?? [],
                next: summary?.ordinal ?? 0
            ).encoded() else { return }
            _ = await ivy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.childEvidenceIndexResponse,
                payload: payload
            )
        default:
            break
        }
    }
}

private struct HierarchyRetryFixture {
    let storage: URL
    let configuration: NodeConfiguration
    let runtime: NodeNetworkRuntime
    let process: ChainProcess
    let parent: Ivy
    let recorder: HierarchyRetryRecorder
    let delegate: HierarchyRetryPeer
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

    init(
        recorder: ChildEvidenceRecorder,
        hello: Data,
        childPath: [String]
    ) {
        self.recorder = recorder
        self.hello = hello
        self.childPath = childPath
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

private struct PendingSideCarrierFixture {
    let storage: URL
    let configuration: NodeConfiguration
    let runtime: NodeNetworkRuntime
    let process: ChainProcess
    let child: Ivy
    let childDelegate: ChildEvidencePeer
    let recorder: ChildEvidenceRecorder
    let remoteContent: NetworkTestContentStore
    let canonicalTipCID: String
    let carrierCID: String
    let childCID: String
    let childPath: [String]
}

private extension Ivy {
    func installTestDelegate(_ delegate: IvyDelegate) {
        self.delegate = delegate
    }
}

private actor NetworkTestContentStore: Fetcher, Storer, VolumeStorer, IvyContentSource {
    private var values: [String: Data] = [:]
    private var volumes: [String: SerializedVolume] = [:]

    func fetch(rawCid: String) throws -> Data {
        guard let data = values[rawCid] else {
            throw FetcherError.notFound(rawCid)
        }
        return data
    }

    func store(entries: [String: Data]) {
        values.merge(entries) { existing, _ in existing }
    }

    func store(volume: SerializedVolume) {
        values.merge(volume.entries) { existing, _ in existing }
        volumes[volume.root] = volume
    }

    func allEntries() -> [String: Data] { values }

    func serializedVolume(rootCID: String) -> SerializedVolume? {
        volumes[rootCID]
    }

    func content(
        rootCID: String,
        cids: [String],
        maxDataBytes: Int
    ) -> [ContentEntry] {
        var total = 0
        var entries: [ContentEntry] = []
        for cid in cids {
            guard let data = values[cid] else { return [] }
            total += data.count
            guard total <= maxDataBytes else { return [] }
            entries.append(ContentEntry(cid: cid, data: data))
        }
        return entries
    }

    func volume(rootCID: String, maxDataBytes: Int) -> [ContentEntry] {
        guard let volume = volumes[rootCID],
              volume.entries.values.reduce(0, { $0 + $1.count }) <= maxDataBytes
        else { return [] }
        return volume.entries.sorted { $0.key < $1.key }.map {
            ContentEntry(cid: $0.key, data: $0.value)
        }
    }
}

private struct NetworkTestVolumeSource: IvyContentSource, Sendable {
    let value: SerializedVolume

    func content(
        rootCID: String,
        cids: [String],
        maxDataBytes: Int
    ) -> [ContentEntry] {
        guard rootCID == value.root,
              cids.allSatisfy({ value.entries[$0] != nil }),
              cids.reduce(0, { $0 + value.entries[$1]!.count }) <= maxDataBytes
        else { return [] }
        return cids.map { cid in
            ContentEntry(cid: cid, data: value.entries[cid]!)
        }
    }

    func volume(rootCID: String, maxDataBytes: Int) -> [ContentEntry] {
        guard rootCID == value.root,
              value.entries.values.reduce(0, { $0 + $1.count }) <= maxDataBytes
        else { return [] }
        return value.entries.sorted { $0.key < $1.key }.map {
            ContentEntry(cid: $0.key, data: $0.value)
        }
    }
}

private struct NetworkTestVolumesSource: IvyContentSource, Sendable {
    let values: [String: SerializedVolume]

    init(_ values: [SerializedVolume]) {
        self.values = Dictionary(uniqueKeysWithValues: values.map { ($0.root, $0) })
    }

    func content(rootCID: String, cids: [String], maxDataBytes: Int) -> [ContentEntry] {
        []
    }

    func volume(rootCID: String, maxDataBytes: Int) -> [ContentEntry] {
        guard let value = values[rootCID],
              value.entries.values.reduce(0, { $0 + $1.count }) <= maxDataBytes
        else { return [] }
        return value.entries.sorted { $0.key < $1.key }.map {
            ContentEntry(cid: $0.key, data: $0.value)
        }
    }
}

private actor RecordingNetworkTestVolumesSource: IvyContentSource {
    private let values: [String: SerializedVolume]
    private var requestedRoots: [String] = []

    init(_ values: [SerializedVolume]) {
        self.values = Dictionary(
            uniqueKeysWithValues: values.map { ($0.root, $0) }
        )
    }

    func content(
        rootCID: String,
        cids: [String],
        maxDataBytes: Int
    ) -> [ContentEntry] {
        []
    }

    func volume(
        rootCID: String,
        maxDataBytes: Int
    ) -> [ContentEntry] {
        requestedRoots.append(rootCID)
        guard let value = values[rootCID],
              value.entries.values.reduce(0, { $0 + $1.count })
                <= maxDataBytes else { return [] }
        return value.entries.sorted { $0.key < $1.key }.map {
            ContentEntry(cid: $0.key, data: $0.value)
        }
    }

    func requests() -> [String] { requestedRoots }
}

private actor BlockingNetworkTestVolumeSource: IvyContentSource {
    let value: SerializedVolume
    private var started = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: SerializedVolume) {
        self.value = value
    }

    func content(rootCID: String, cids: [String], maxDataBytes: Int) -> [ContentEntry] {
        []
    }

    func volume(rootCID: String, maxDataBytes: Int) async -> [ContentEntry] {
        guard rootCID == value.root else { return [] }
        started = true
        if !released {
            await withCheckedContinuation { waiters.append($0) }
        }
        guard value.entries.values.reduce(0, { $0 + $1.count }) <= maxDataBytes else {
            return []
        }
        return value.entries.sorted { $0.key < $1.key }.map {
            ContentEntry(cid: $0.key, data: $0.value)
        }
    }

    func didStart() -> Bool { started }

    func release() {
        released = true
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume() }
    }
}

private actor CandidateBuildGate {
    private var next = 0
    private var released: Set<Int> = []
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]

    func enter() async -> Int {
        next += 1
        let index = next
        guard !released.contains(index) else { return index }
        await withCheckedContinuation { waiters[index] = $0 }
        return index
    }

    func enteredCount() -> Int { next }

    func release(_ index: Int) {
        released.insert(index)
        waiters.removeValue(forKey: index)?.resume()
    }

    func releaseAll() {
        for index in Array(waiters.keys) { release(index) }
    }
}

private final class BlockingProvisionalBroker: VolumeBroker {
    let near: (any VolumeBroker)? = nil
    let far: (any VolumeBroker)? = nil
    private let backing = MemoryBroker(evictUnpinnedGrace: .zero)
    private let gate = CandidateBuildGate()

    func waitUntilStoreStarts() async {
        while await gate.enteredCount() == 0 { await Task.yield() }
    }

    func releaseStore() async { await gate.release(1) }

    func hasVolume(root: String) async -> Bool {
        await backing.hasVolume(root: root)
    }

    func fetchVolumeLocal(root: String) async -> SerializedVolume? {
        await backing.fetchVolumeLocal(root: root)
    }

    func fetchDataLocal(cid: String) async -> Data? {
        await backing.fetchDataLocal(cid: cid)
    }

    func fetchDataLocal(cids: Set<String>) async -> [String: Data] {
        await backing.fetchDataLocal(cids: cids)
    }

    func storeVolumesLocal(_ volumes: [SerializedVolume]) async throws {
        _ = await gate.enter()
        try await backing.storeVolumesLocal(volumes)
    }

    func pin(
        root: String,
        owner: String,
        count: Int,
        ttl: Duration?
    ) async throws {
        try await backing.pin(root: root, owner: owner, count: count, ttl: ttl)
    }

    func unpin(root: String, owner: String, count: Int) async throws {
        try await backing.unpin(root: root, owner: owner, count: count)
    }

    func unpinAll(owner: String) async throws {
        try await backing.unpinAll(owner: owner)
    }

    func owners(root: String) async -> Set<String> {
        await backing.owners(root: root)
    }

    func evictUnpinned() async throws -> Int {
        try await backing.evictUnpinned()
    }
}

private actor CandidateReservationAckGate {
    private let apply: @Sendable (NetworkCandidateReservationUpdate) async -> Bool
    private var snapshots: [[String]] = []
    private var handoffSnapshots: [[String]] = []
    private var rejections: [[String]] = []
    private var holdAnyNonempty = true
    private var heldCandidateCIDs: Set<String>?
    private var blocking = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(
        apply: @escaping @Sendable (
            NetworkCandidateReservationUpdate
        ) async -> Bool
    ) {
        self.apply = apply
    }

    func handle(_ update: NetworkCandidateReservationUpdate) async -> Bool {
        let candidateCIDs = update.candidateCIDs
        snapshots.append(candidateCIDs)
        handoffSnapshots.append(update.handoffCIDs)
        let shouldBlock = !blocking && (
            holdAnyNonempty && !candidateCIDs.isEmpty
                || heldCandidateCIDs == Set(candidateCIDs)
        )
        if shouldBlock {
            blocking = true
            await withCheckedContinuation { waiters.append($0) }
        }
        let result = await apply(update)
        if !result {
            rejections.append(candidateCIDs)
        }
        return result
    }

    func snapshot() -> [[String]] { snapshots }
    func handoffSnapshot() -> [[String]] { handoffSnapshots }
    func rejectionSnapshot() -> [[String]] { rejections }

    func holdNext(_ candidateCIDs: Set<String>) {
        precondition(waiters.isEmpty)
        holdAnyNonempty = false
        heldCandidateCIDs = candidateCIDs
        blocking = false
    }

    func holdNextNonempty() {
        precondition(waiters.isEmpty)
        holdAnyNonempty = true
        heldCandidateCIDs = nil
        blocking = false
    }

    func release() {
        holdAnyNonempty = false
        heldCandidateCIDs = nil
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume() }
    }
}

private actor IssuedCandidateSet {
    private var candidateCIDs: Set<String> = []

    func replace(with candidateCIDs: [String]) -> Bool {
        self.candidateCIDs = Set(candidateCIDs)
        return true
    }

    func snapshot() -> Set<String> { candidateCIDs }
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

private struct NetworkHierarchyBranch {
    let rootHeader: BlockHeader
    let middle: Block
    let middleHeader: BlockHeader
    let leaf: Block
    let leafHeader: BlockHeader
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

private enum NetworkTransportTestPorts {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var allocated = Set<UInt16>()

    static func allocate() -> UInt16 {
        lock.withLock {
            while true {
                #if canImport(Darwin)
                let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
                #else
                let descriptor = Glibc.socket(
                    AF_INET,
                    Int32(SOCK_STREAM.rawValue),
                    0
                )
                #endif
                precondition(descriptor >= 0)
                defer { _ = close(descriptor) }

                var address = sockaddr_in()
                #if canImport(Darwin)
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                #endif
                address.sin_family = sa_family_t(AF_INET)
                address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
                let bound = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        bind(
                            descriptor,
                            $0,
                            socklen_t(MemoryLayout<sockaddr_in>.size)
                        )
                    }
                }
                precondition(bound == 0)

                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let named = withUnsafeMutablePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        getsockname(descriptor, $0, &length)
                    }
                }
                precondition(named == 0)
                let port = UInt16(bigEndian: address.sin_port)
                if allocated.insert(port).inserted { return port }
            }
        }
    }
}

final class NetworkTrustTests: XCTestCase {
    func testDuplicateParentQueryCannotReleaseActivePeerSlot() throws {
        let first = try PeerKey(
            rawRepresentation: Data(repeating: 1, count: PeerKey.byteCount)
        )
        let second = try PeerKey(
            rawRepresentation: Data(repeating: 2, count: PeerKey.byteCount)
        )
        var guardState = ParentStateQueryGuard(capacity: 1)

        XCTAssertTrue(guardState.acquire(first))
        XCTAssertFalse(guardState.acquire(first))
        XCTAssertFalse(guardState.acquire(second))
        XCTAssertEqual(guardState.peers, [first])

        guardState.release(first)
        XCTAssertTrue(guardState.acquire(second))
    }

    private let nexusCID = "bafyreiaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let minimumRootWork = String(repeating: "0", count: 63) + "1"
    private func overlayRuntime(
        keyByte: UInt8,
        requestTimeout: Duration,
        bootstrapPeers: [PeerEndpoint] = [],
        publicReadURL: String? = nil
    ) async throws -> (
        runtime: NodeNetworkRuntime,
        process: ChainProcess,
        peerID: PeerID,
        endpoint: PeerEndpoint,
        hello: Data
    ) {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-overlay-runtime-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
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
            rpcPort: NetworkTransportTestPorts.allocate(),
            publicReadURL: publicReadURL
        )
        let runtime = try NodeNetworkRuntime(
            configuration: configuration,
            planeConfigurations: try NodeNetworkPlaneConfigurations(
                overlay: IvyConfig(
                    signingKey: configuration.signingKey,
                    listenPort: overlayPort,
                    bootstrapPeers: bootstrapPeers,
                    requestTimeout: requestTimeout,
                    stunServers: [],
                    healthConfig: PeerHealthConfig(enabled: false),
                    mode: .overlay
                ),
                hierarchy: IvyConfig(
                    signingKey: configuration.signingKey,
                    listenPort: hierarchyPort,
                    stunServers: [],
                    maxConnections: IvyConfig.defaultMaxConnections,
                    maxConnectionsPerNetgroup: IvyConfig.defaultMaxConnections,
                    relayEnabled: false,
                    carriers: [],
                    mode: .privateNetwork
                )
            )
        )
        let process = try await ChainProcess.open(
            configuration: configuration
        )
        let peerID = PeerID(publicKey: configuration.processPublicKey)
        return (
            runtime,
            process,
            peerID,
            PeerEndpoint(
                publicKey: configuration.processPublicKey,
                host: "127.0.0.1",
                port: overlayPort
            ),
            try ChainHello(
                nexusGenesisCID: configuration.nexusGenesisCID,
                chainPath: configuration.chainPath
            ).encode()
        )
    }

    private func connectAndHello(
        _ peer: Ivy,
        peerID: PeerID,
        endpoint: PeerEndpoint,
        hello: Data
    ) async throws {
        try await peer.start()
        try await peer.connect(to: endpoint)
        for _ in 0..<100 {
            if (await peer.connectedPeers).contains(peerID) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard (await peer.connectedPeers).contains(peerID),
              case .enqueued = await peer.sendMessage(
                to: peerID,
                topic: NodeNetworkTopic.overlayHello,
                payload: hello
              ) else {
            throw NetworkTestError.failedStart
        }
    }

    func testChainHelloPinsProtocolIdentityButNotLocalWorkFloor() throws {
        let hello = ChainHello(
            nexusGenesisCID: nexusCID,
            chainPath: ["Nexus"]
        )
        let encoded = try hello.encode()
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self)
            .contains("minimumRootWork"))
        let decoded = try ChainHello.decode(encoded)
        XCTAssertNoThrow(try decoded.validateCompatibility(
            expectedNexusGenesisCID: nexusCID,
            expectedChainPath: ["Nexus"]
        ))

        XCTAssertThrowsError(try decoded.validateCompatibility(
            expectedNexusGenesisCID: "different-nexus",
            expectedChainPath: ["Nexus"]
        )) { error in
            XCTAssertEqual(error as? ChainHelloError, .wrongNexusGenesis)
        }

        let legacy = try JSONDecoder().decode(
            ChainHello.self,
            from: try JSONSerialization.data(withJSONObject: [
                "version": ChainHello.protocolVersion - 1,
                "nexusGenesisCID": nexusCID,
                "chainPath": ["Nexus"],
                "minimumRootWorkHex": minimumRootWork,
            ])
        )
        XCTAssertThrowsError(try legacy.validateCompatibility(
            expectedNexusGenesisCID: nexusCID,
            expectedChainPath: ["Nexus"]
        )) { error in
            XCTAssertEqual(error as? ChainHelloError, .incompatibleProtocol)
        }

    }

    func testChainHelloCarriesDeclaredReadURLTolerantly() throws {
        // Declared: survives the round-trip.
        let declared = ChainHello(
            nexusGenesisCID: nexusCID,
            chainPath: ["Nexus"],
            publicReadURL: "https://nexus.example"
        )
        let decoded = try ChainHello.decode(try declared.encode())
        XCTAssertEqual(decoded.publicReadURL, "https://nexus.example")
        XCTAssertNoThrow(try decoded.validateCompatibility(
            expectedNexusGenesisCID: nexusCID,
            expectedChainPath: ["Nexus"]
        ))

        // Undeclared: byte-identical to the legacy wire (a nil optional emits
        // no key), so legacy peers see exactly the hello they always did.
        let undeclared = ChainHello(
            nexusGenesisCID: nexusCID,
            chainPath: ["Nexus"]
        )
        XCTAssertFalse(String(
            decoding: try undeclared.encode(),
            as: UTF8.self
        ).contains("publicReadURL"))

        // Legacy payload without the field decodes to nil.
        let legacy = try ChainHello.decode(try JSONSerialization.data(
            withJSONObject: [
                "version": ChainHello.protocolVersion,
                "nexusGenesisCID": nexusCID,
                "chainPath": ["Nexus"],
            ]
        ))
        XCTAssertNil(legacy.publicReadURL)

        // A non-browsable declared value never costs the session: the hello
        // still decodes and authorizes; ingest just drops the URL.
        let hostile = try ChainHello.decode(try JSONSerialization.data(
            withJSONObject: [
                "version": ChainHello.protocolVersion,
                "nexusGenesisCID": nexusCID,
                "chainPath": ["Nexus"],
                "publicReadURL": "javascript:alert(1)",
            ]
        ))
        XCTAssertNoThrow(try hostile.validateCompatibility(
            expectedNexusGenesisCID: nexusCID,
            expectedChainPath: ["Nexus"]
        ))
        XCTAssertNil(normalizedPublicReadURL(hostile.publicReadURL))
    }

    func testDeclaredReadURLNormalizationAdmitsOnlyBrowsableBases() {
        XCTAssertEqual(
            normalizedPublicReadURL(" https://toy.example/ "),
            "https://toy.example"
        )
        XCTAssertEqual(
            normalizedPublicReadURL("http://198.51.100.7:8081"),
            "http://198.51.100.7:8081"
        )
        XCTAssertEqual(
            normalizedPublicReadURL("https://toy.example/read/"),
            "https://toy.example/read"
        )
        XCTAssertNil(normalizedPublicReadURL(nil))
        XCTAssertNil(normalizedPublicReadURL(""))
        XCTAssertNil(normalizedPublicReadURL("toy.example"))
        XCTAssertNil(normalizedPublicReadURL("ftp://toy.example"))
        XCTAssertNil(normalizedPublicReadURL("https://user:pw@toy.example"))
        XCTAssertNil(normalizedPublicReadURL("https://toy.example?x=1"))
        XCTAssertNil(normalizedPublicReadURL("https://toy.example#frag"))
        XCTAssertNil(normalizedPublicReadURL("https://"))
        XCTAssertNil(normalizedPublicReadURL(
            "https://toy.example/" + String(
                repeating: "a",
                count: maximumPublicReadURLBytes
            )
        ))
        // Case variants fold to one base so dedup is real; markup
        // metacharacters never survive into explorer-facing JSON.
        XCTAssertEqual(
            normalizedPublicReadURL("HTTPS://Toy.Example/Read"),
            "https://toy.example/Read"
        )
        XCTAssertNil(normalizedPublicReadURL("https://toy.example/\"><script>"))
        XCTAssertNil(normalizedPublicReadURL("https://toy.example/'x"))
        // Every accepted output is a fixed point, so an honestly-normalized
        // URL can never fail the response wire's round-trip validation.
        for candidate in [
            "https://toy.example", " https://toy.example/ ",
            "HTTPS://Toy.Example/Read", "http://198.51.100.7:8081",
            "https://[::1]:8081", "https://%74oy.example",
        ] {
            guard let normalized = normalizedPublicReadURL(candidate) else {
                continue
            }
            XCTAssertEqual(normalizedPublicReadURL(normalized), normalized)
        }
    }

    func testReadEndpointMessagesAreCanonicalAndBounded() throws {
        let genesis = testCID("read-endpoint")
        let request = ReadEndpointRequestMessage(
            requestID: 7,
            genesisCID: genesis
        )
        let decodedRequest = try ReadEndpointRequestMessage.decoded(
            try request.encoded()
        )
        XCTAssertEqual(decodedRequest, request)
        XCTAssertThrowsError(try ReadEndpointRequestMessage(
            requestID: 0,
            genesisCID: genesis
        ).encoded())
        XCTAssertThrowsError(try ReadEndpointRequestMessage(
            requestID: 7,
            genesisCID: "not-a-cid"
        ).encoded())

        let response = ReadEndpointResponseMessage(
            requestID: 7,
            genesisCID: genesis,
            readURLs: ["https://toy.example"]
        )
        let decodedResponse = try ReadEndpointResponseMessage.decoded(
            try response.encoded()
        )
        XCTAssertEqual(decodedResponse, response)
        // Empty answers are valid wire: a fast negative beats a timeout.
        XCTAssertNoThrow(try ReadEndpointResponseMessage(
            requestID: 7,
            genesisCID: genesis,
            readURLs: []
        ).encoded())
        // Only normalized browsable bases; count bounded.
        XCTAssertThrowsError(try ReadEndpointResponseMessage(
            requestID: 7,
            genesisCID: genesis,
            readURLs: ["https://toy.example/"]
        ).encoded())
        XCTAssertThrowsError(try ReadEndpointResponseMessage(
            requestID: 7,
            genesisCID: genesis,
            readURLs: (0...ReadEndpointResponseMessage.maximumURLs).map {
                "https://node\($0).example"
            }
        ).encoded())
        // Non-canonical bytes are rejected wholesale.
        XCTAssertThrowsError(try ReadEndpointResponseMessage.decoded(
            try response.encoded() + Data(" ".utf8)
        ))
    }

    func testReadEndpointRequestAnsweredFromSelfDescriptionOnly() async throws {
        let target = try await overlayRuntime(
            keyByte: 0xc1,
            requestTimeout: .seconds(2),
            publicReadURL: "https://nexus.example"
        )
        let service = networkService(
            process: target.process,
            runtime: target.runtime
        )
        let handlers = transactionServiceHandlers(service)
        let recorder = PayloadRecorder()
        let observer = Ivy(config: IvyConfig(
            signingKey: signingKey(0xc2),
            listenPort: 0,
            stunServers: [],
            mode: .overlay
        ))
        let observerDelegate = PayloadRecordingPeer(recorder: recorder)
        await observer.installTestDelegate(observerDelegate)
        do {
            try await target.runtime.start(
                process: target.process,
                handlers: handlers
            )
            try await connectAndHello(
                observer,
                peerID: target.peerID,
                endpoint: target.endpoint,
                hello: target.hello
            )
            // Every overlay topic is gated on a completed hello; the runtime
            // announces its tip back in the same handling branch, so seeing it
            // proves the observer's hello landed.
            for _ in 0..<200 {
                if await !recorder.payloads(
                    topic: NodeNetworkTopic.blockAnnouncement
                ).isEmpty { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let maybeOwnGenesis = await target.process.mainChainBlockCID(
                atHeight: 0
            )
            let ownGenesis = try XCTUnwrap(maybeOwnGenesis)
            // The node's own genesis: answered with its configured URL.
            let askOwn = try ReadEndpointRequestMessage(
                requestID: 7,
                genesisCID: ownGenesis
            ).encoded()
            _ = await observer.sendMessage(
                to: target.peerID,
                topic: NodeNetworkTopic.readEndpointRequest,
                payload: askOwn
            )
            let own = try await waitForReadEndpointResponse(
                requestID: 7,
                in: recorder
            )
            XCTAssertEqual(own.genesisCID, ownGenesis)
            XCTAssertEqual(own.readURLs, ["https://nexus.example"])

            // A genesis this node knows nothing about: a fast empty negative,
            // never an invented URL.
            let askUnknown = try ReadEndpointRequestMessage(
                requestID: 8,
                genesisCID: testCID("unknown-chain")
            ).encoded()
            _ = await observer.sendMessage(
                to: target.peerID,
                topic: NodeNetworkTopic.readEndpointRequest,
                payload: askUnknown
            )
            let unknown = try await waitForReadEndpointResponse(
                requestID: 8,
                in: recorder
            )
            XCTAssertEqual(unknown.readURLs, [])
            await observer.stop()
            await target.runtime.stop()
        } catch {
            await observer.stop()
            await target.runtime.stop()
            throw error
        }
    }

    func testReadURLDiscoveryListsOwnDeclarationWithoutOwnProviderRecord()
        async throws {
        // The node declares a read URL for its own genesis but advertises no
        // P2P address (no external address, no STUN), so Ivy never stores a
        // provider record under its own key. Its own declaration must still
        // lead the answer: the node best placed to answer must not omit the
        // one endpoint it knows first-hand, leaving only other providers.
        let target = try await overlayRuntime(
            keyByte: 0xc3,
            requestTimeout: .seconds(2),
            publicReadURL: "https://nexus.example"
        )
        let maybeOwnGenesis = await target.process.mainChainBlockCID(
            atHeight: 0
        )
        let ownGenesis = try XCTUnwrap(maybeOwnGenesis)
        let discovery = try await discoverReadURLs(
            runtime: target.runtime,
            process: target.process,
            peerID: target.peerID,
            endpoint: target.endpoint,
            hello: target.hello,
            genesisCID: ownGenesis,
            providers: [ReadURLProvider(
                keyByte: 0xc4,
                answers: [["https://remote.example"]]
            )]
        )
        // The remote provider was discovered and asked, and its declaration
        // flows through; the node's own declaration comes first.
        XCTAssertEqual(discovery.asks, [1])
        XCTAssertEqual(
            discovery.urls,
            ["https://nexus.example", "https://remote.example"]
        )
    }

    func testReadURLDiscoveryInventsNoURLForUndeclaredProvider() async throws {
        // A provider that answers the ask declaring no read surface has no
        // browsable endpoint; its P2P host is an IP literal, not a read URL.
        // Neither it nor this undeclared node may appear as https://<host>.
        let target = try await overlayRuntime(
            keyByte: 0xc5,
            requestTimeout: .seconds(2)
        )
        let discovery = try await discoverReadURLs(
            runtime: target.runtime,
            process: target.process,
            peerID: target.peerID,
            endpoint: target.endpoint,
            hello: target.hello,
            genesisCID: testCID("undeclared-child"),
            providers: [ReadURLProvider(keyByte: 0xc6, answers: [[]])]
        )
        // Not vacuous: the provider was found and asked, and still no URL.
        XCTAssertEqual(discovery.asks, [1])
        XCTAssertEqual(discovery.urls, [])
    }

    func testReadURLDiscoveryAsksEveryProviderSharingAHost() async throws {
        // Two provider identities behind one IP (one host running several
        // nodes, or one NAT). The first recorded declares nothing; the
        // second declares a URL. Sharing a host must not hide the declarer.
        let target = try await overlayRuntime(
            keyByte: 0xc7,
            requestTimeout: .seconds(2)
        )
        let discovery = try await discoverReadURLs(
            runtime: target.runtime,
            process: target.process,
            peerID: target.peerID,
            endpoint: target.endpoint,
            hello: target.hello,
            genesisCID: testCID("shared-host-child"),
            providers: [
                ReadURLProvider(keyByte: 0xc8, answers: [[]]),
                ReadURLProvider(
                    keyByte: 0xc9,
                    answers: [["https://declared.example"]]
                ),
            ]
        )
        XCTAssertEqual(discovery.asks, [1, 1])
        XCTAssertEqual(discovery.urls, ["https://declared.example"])
    }

    func testReadURLDiscoveryAsksEachProviderIdentityOnce() async throws {
        // One identity announced under two hosts holds two provider routes.
        // It is one responder: one ask slot, one per-responder URL cap —
        // never a second ask it can answer with a fresh pair of URLs.
        let target = try await overlayRuntime(
            keyByte: 0xca,
            requestTimeout: .seconds(2)
        )
        let discovery = try await discoverReadURLs(
            runtime: target.runtime,
            process: target.process,
            peerID: target.peerID,
            endpoint: target.endpoint,
            hello: target.hello,
            genesisCID: testCID("multi-route-child"),
            providers: [ReadURLProvider(
                keyByte: 0xcb,
                routes: ["11.0.0.1", "11.0.0.2"],
                answers: [
                    ["https://first.example", "https://second.example"],
                    ["https://third.example", "https://fourth.example"],
                ]
            )]
        )
        XCTAssertEqual(discovery.asks, [1])
        XCTAssertEqual(
            discovery.urls,
            ["https://first.example", "https://second.example"]
        )
    }

    /// One provider identity for `discoverReadURLs`. It opens one session per
    /// entry in `routes`, in order, each advertising that host (nil: its
    /// loopback listen address) and announcing the genesis; only the last
    /// session stays up. Its n-th ask is answered with `answers[n]`, the last
    /// answer repeating.
    private struct ReadURLProvider {
        let keyByte: UInt8
        var routes: [String?] = [nil]
        let answers: [[String]]
    }

    /// Starts `runtime`, lets each provider (in order) announce itself as a
    /// provider of `genesisCID`, then runs the runtime's read-URL discovery
    /// while the providers answer its asks. Returns the URLs and how many
    /// asks for `genesisCID` each provider received, so an empty result can
    /// never pass for a missed discovery. Stops everything before returning.
    private func discoverReadURLs(
        runtime: NodeNetworkRuntime,
        process: ChainProcess,
        peerID: PeerID,
        endpoint: PeerEndpoint,
        hello: Data,
        genesisCID: String,
        providers: [ReadURLProvider]
    ) async throws -> (urls: [String], asks: [Int]) {
        let service = networkService(process: process, runtime: runtime)
        var instances: [Ivy] = []
        var delegates: [PayloadRecordingPeer] = []
        var liveProviders: [Ivy] = []
        var liveRecorders: [PayloadRecorder] = []
        do {
            try await runtime.start(
                process: process,
                handlers: transactionServiceHandlers(service)
            )
            for provider in providers {
                var session: (Ivy, PayloadRecorder)?
                for route in provider.routes {
                    await session?.0.stop()
                    let port = NetworkTransportTestPorts.allocate()
                    let ivy = Ivy(config: IvyConfig(
                        signingKey: signingKey(provider.keyByte),
                        listenPort: port,
                        stunServers: [],
                        externalAddress: route.map { (host: $0, port: port) },
                        mode: .overlay
                    ))
                    let recorder = PayloadRecorder()
                    let delegate = PayloadRecordingPeer(recorder: recorder)
                    await ivy.installTestDelegate(delegate)
                    instances.append(ivy)
                    delegates.append(delegate)
                    try await connectAndHello(
                        ivy,
                        peerID: peerID,
                        endpoint: endpoint,
                        hello: hello
                    )
                    await ivy.announceProvider(
                        rootCID: genesisCID,
                        expiresAt: UInt64(Date().timeIntervalSince1970) + 600
                    )
                    // Frames on one session are handled in order, so an
                    // answered probe sent after the announce proves the
                    // hello landed and the record was stored.
                    _ = await ivy.sendMessage(
                        to: peerID,
                        topic: NodeNetworkTopic.readEndpointRequest,
                        payload: try ReadEndpointRequestMessage(
                            requestID: 1,
                            genesisCID: testCID("probe")
                        ).encoded()
                    )
                    _ = try await waitForReadEndpointResponse(
                        requestID: 1,
                        in: recorder
                    )
                    session = (ivy, recorder)
                }
                if let (ivy, recorder) = session {
                    liveProviders.append(ivy)
                    liveRecorders.append(recorder)
                }
            }

            let urls = await Self.discoverAnsweringAsks(
                runtime: runtime,
                genesisCID: genesisCID,
                providers: liveProviders,
                recorders: liveRecorders,
                answers: providers.map(\.answers),
                to: peerID
            )
            var asks: [Int] = []
            for recorder in liveRecorders {
                asks.append(await Self.readEndpointAsks(
                    for: genesisCID,
                    in: recorder
                ).count)
            }
            for ivy in instances { await ivy.stop() }
            await runtime.stop()
            withExtendedLifetime((service, delegates)) {}
            return (urls, asks)
        } catch {
            for ivy in instances { await ivy.stop() }
            await runtime.stop()
            throw error
        }
    }

    /// `runtime`'s read-URL discovery for `genesisCID`, run while the
    /// providers answer its asks; the responder stops once discovery returns.
    private static func discoverAnsweringAsks(
        runtime: NodeNetworkRuntime,
        genesisCID: String,
        providers: [Ivy],
        recorders: [PayloadRecorder],
        answers: [[[String]]],
        to peerID: PeerID
    ) async -> [String] {
        await withTaskGroup(of: [String]?.self) { group in
            group.addTask {
                await answerReadEndpointAsks(
                    for: genesisCID,
                    providers: providers,
                    recorders: recorders,
                    answers: answers,
                    to: peerID
                )
                return nil
            }
            group.addTask {
                await runtime.discoverProviderReadURLs(genesisCID: genesisCID)
            }
            var urls: [String] = []
            for await result in group {
                guard let result else { continue }
                urls = result
                group.cancelAll()
            }
            return urls
        }
    }

    /// Until cancelled, answers every ask for `genesisCID` each provider
    /// receives: the n-th with `answers[provider][n]`, the last repeating.
    private static func answerReadEndpointAsks(
        for genesisCID: String,
        providers: [Ivy],
        recorders: [PayloadRecorder],
        answers: [[[String]]],
        to peerID: PeerID
    ) async {
        var answered = [Set<UInt64>](repeating: [], count: providers.count)
        while !Task.isCancelled {
            for index in providers.indices {
                let asks = await readEndpointAsks(
                    for: genesisCID,
                    in: recorders[index]
                )
                for ask in asks {
                    guard answered[index].insert(ask.requestID).inserted
                    else { continue }
                    let slot = min(answered[index].count, answers[index].count)
                    guard let payload = try? ReadEndpointResponseMessage(
                        requestID: ask.requestID,
                        genesisCID: genesisCID,
                        readURLs: answers[index][slot - 1]
                    ).encoded() else { continue }
                    _ = await providers[index].sendMessage(
                        to: peerID,
                        topic: NodeNetworkTopic.readEndpointResponse,
                        payload: payload
                    )
                }
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func readEndpointAsks(
        for genesisCID: String,
        in recorder: PayloadRecorder
    ) async -> [ReadEndpointRequestMessage] {
        await recorder.payloads(topic: NodeNetworkTopic.readEndpointRequest)
            .compactMap { try? ReadEndpointRequestMessage.decoded($0) }
            .filter { $0.genesisCID == genesisCID }
    }

    private func waitForReadEndpointResponse(
        requestID: UInt64,
        in recorder: PayloadRecorder
    ) async throws -> ReadEndpointResponseMessage {
        for _ in 0..<200 {
            for payload in await recorder.payloads(
                topic: NodeNetworkTopic.readEndpointResponse
            ) {
                if let response = try? ReadEndpointResponseMessage.decoded(
                    payload
                ), response.requestID == requestID {
                    return response
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let seen = await recorder.topics()
        throw NetworkTestError.failedPhase("read endpoint response; saw \(seen)")
    }

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

    func testTwoPlanesHaveDisjointTopologyAndSharedIdentity() throws {
        let parent = signingKey(41)
        let bootstrap = signingKey(46)
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus", "Payments"],
            storagePath: URL(fileURLWithPath: "/tmp/lattice-network-plane-test"),
            privateKeyHex: String(repeating: "2a", count: 32),
            listenPort: 4101,
            factListenPort: 4102,
            rpcPort: 8100,
            bootstrapPeers: [PeerEndpoint(
                publicKey: peerKey(bootstrap).hex,
                host: "overlay.example",
                port: 4101
            )],
            parentEndpoint: ParentEndpoint(
                publicKey: peerKey(parent).hex,
                host: "127.0.0.1",
                port: 4102
            ),
            minPeerKeyBits: 17
        )
        let planes = try NodeNetworkPlaneConfigurations(configuration)

        XCTAssertEqual(planes.overlay.mode, .overlay)
        XCTAssertEqual(planes.overlay.listenPort, 4101)
        XCTAssertEqual(planes.overlay.minPeerKeyBits, 17)
        XCTAssertEqual(planes.overlay.bootstrapPeers.count, 1)
        XCTAssertTrue(planes.overlay.inboundAdmissionBypassPeerKeys.isEmpty)

        XCTAssertEqual(planes.hierarchy.mode, .privateNetwork)
        XCTAssertEqual(planes.hierarchy.listenPort, 4102)
        XCTAssertEqual(planes.hierarchy.minPeerKeyBits, 0)
        XCTAssertEqual(planes.hierarchy.bootstrapPeers, [configuration.parentEndpoint!.ivy])
        XCTAssertEqual(
            planes.hierarchy.inboundAdmissionBypassPeerKeys,
            [peerKey(parent)]
        )
        XCTAssertTrue(planes.hierarchy.stunServers.isEmpty)
        XCTAssertTrue(planes.hierarchy.carriers.isEmpty)
        XCTAssertFalse(planes.hierarchy.relayEnabled)
        XCTAssertTrue(planes.hierarchy.privateContentExchangeEnabled)
        XCTAssertEqual(planes.hierarchy.reservedOutboundConnectionSlots, 1)
        XCTAssertEqual(
            planes.hierarchy.maxConnectionsPerNetgroup,
            IvyConfig.defaultMaxConnections
        )
        XCTAssertEqual(planes.overlay.publicKey, planes.hierarchy.publicKey)
        XCTAssertEqual(
            NodeNetworkTopic.plane(for: NodeNetworkTopic.blockAnnouncement),
            .overlay
        )
        XCTAssertNil(NodeNetworkTopic.plane(for: "lattice.hierarchy.coverage.v1"))
        XCTAssertNil(NodeNetworkTopic.plane(for: "lattice.hierarchy.inherited-work.v1"))
        XCTAssertNil(NodeNetworkTopic.plane(for: "unknown"))
    }

    func testRuntimeRejectsAdditionalHierarchyBootstrapPeer() throws {
        let parent = signingKey(47)
        let extra = signingKey(48)
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus", "Payments"],
            storagePath: URL(fileURLWithPath: "/tmp/lattice-network-bootstrap-parent"),
            privateKeyHex: String(repeating: "2b", count: 32),
            parentEndpoint: ParentEndpoint(
                publicKey: peerKey(parent).hex,
                host: "127.0.0.1",
                port: 4102
            )
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
                bootstrapPeers: [
                    configuration.parentEndpoint!.ivy,
                    PeerEndpoint(
                        publicKey: peerKey(extra).hex,
                        host: "127.0.0.2",
                        port: 4102
                    ),
                ],
                inboundAdmissionBypassPeerKeys: [peerKey(parent)],
                stunServers: [],
                maxConnections: IvyConfig.defaultMaxConnections,
                maxConnectionsPerNetgroup: IvyConfig.defaultMaxConnections,
                relayEnabled: false,
                carriers: [],
                mode: .privateNetwork
            )
        )

        XCTAssertThrowsError(try NodeNetworkRuntime(
            configuration: configuration,
            planeConfigurations: planes
        )) { error in
            XCTAssertEqual(
                error as? IvyModeError,
                .invalidConfiguration(
                    "hierarchy bootstrap peers must contain exactly the configured parent"
                )
            )
        }
    }

    func testNexusRuntimeRejectsHierarchyBootstrapPeer() throws {
        let extra = signingKey(49)
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: URL(fileURLWithPath: "/tmp/lattice-network-bootstrap-nexus"),
            privateKeyHex: String(repeating: "2c", count: 32)
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
                bootstrapPeers: [PeerEndpoint(
                    publicKey: peerKey(extra).hex,
                    host: "127.0.0.2",
                    port: 4102
                )],
                stunServers: [],
                maxConnections: IvyConfig.defaultMaxConnections,
                maxConnectionsPerNetgroup: IvyConfig.defaultMaxConnections,
                relayEnabled: false,
                carriers: [],
                mode: .privateNetwork
            )
        )

        XCTAssertThrowsError(try NodeNetworkRuntime(
            configuration: configuration,
            planeConfigurations: planes
        )) { error in
            XCTAssertEqual(
                error as? IvyModeError,
                .invalidConfiguration(
                    "hierarchy bootstrap peers must contain exactly the configured parent"
                )
            )
        }
    }

    func testHierarchyHelloGrantsOnlyExactParentOrImmediateChildRole() throws {
        let parent = signingKey(43)
        let other = signingKey(44)
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus", "Payments"],
            storagePath: URL(fileURLWithPath: "/tmp/lattice-hierarchy-hello-test"),
            privateKeyHex: String(repeating: "2d", count: 32),
            parentEndpoint: ParentEndpoint(
                publicKey: peerKey(parent).hex,
                host: "127.0.0.1",
                port: 4002
            )
        )
        let parentHello = ChainHello(
            nexusGenesisCID: configuration.nexusGenesisCID,
            chainPath: ["Nexus"]
        )
        XCTAssertEqual(
            NodeNetworkRuntime.hierarchyRole(
                for: parentHello,
                peerKey: peerKey(parent).hex,
                configuration: configuration
            ),
            .parent
        )
        XCTAssertNil(NodeNetworkRuntime.hierarchyRole(
            for: parentHello,
            peerKey: peerKey(other).hex,
            configuration: configuration
        ))

        let childPath = ["Nexus", "Payments", "Receipts"]
        let childHello = ChainHello(
            nexusGenesisCID: configuration.nexusGenesisCID,
            chainPath: childPath
        )
        XCTAssertEqual(
            NodeNetworkRuntime.hierarchyRole(
                for: childHello,
                peerKey: peerKey(other).hex,
                configuration: configuration
            ),
            .child(childPath)
        )
        XCTAssertNil(NodeNetworkRuntime.hierarchyRole(
            for: ChainHello(
                nexusGenesisCID: configuration.nexusGenesisCID,
                chainPath: ["Nexus", "Other", "Receipts"]
            ),
            peerKey: peerKey(other).hex,
            configuration: configuration
        ))
    }

    func testHierarchyHelloIsExactSessionAndOneShot() {
        let first = Data([1])
        let replacement = Data([2])

        XCTAssertFalse(NodeNetworkRuntime.hierarchyHelloMatches(
            sessionID: first,
            deadlineSessionID: replacement
        ))
        XCTAssertTrue(NodeNetworkRuntime.hierarchyHelloMatches(
            sessionID: replacement,
            deadlineSessionID: replacement
        ))
        XCTAssertFalse(NodeNetworkRuntime.hierarchyHelloMatches(
            sessionID: replacement,
            deadlineSessionID: nil
        ))
    }

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

    func testAcceptedLeafPagesAreCanonicalAndCursorBound() throws {
        let request = AcceptedLeavesRequestMessage(
            requestID: 12,
            afterCID: "block-a",
            snapshotSequence: 9
        )
        XCTAssertEqual(
            try AcceptedLeavesRequestMessage.decoded(request.encoded()),
            request
        )
        let fullPage = (0..<AcceptedLeavesResponseMessage.maximumLeaves).map {
            String(format: "block-b%03d", $0)
        }
        let response = AcceptedLeavesResponseMessage(
            requestID: 12,
            afterCID: "block-a",
            snapshotSequence: 9,
            blockCIDs: fullPage,
            hasMore: true
        )
        XCTAssertEqual(
            try AcceptedLeavesResponseMessage.decoded(response.encoded()),
            response
        )
        XCTAssertThrowsError(try AcceptedLeavesResponseMessage(
            requestID: 12,
            afterCID: "block-a",
            snapshotSequence: 9,
            blockCIDs: fullPage.reversed(),
            hasMore: false
        ).encoded())
        XCTAssertThrowsError(try AcceptedLeavesResponseMessage(
            requestID: 12,
            afterCID: "block-a",
            snapshotSequence: 9,
            blockCIDs: [],
            hasMore: true
        ).encoded())
    }

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
        let request = ChildCandidateRequestMessage(
            requestID: 11,
            budgetMilliseconds: 750,
            childPath: ["Nexus", "Payments"],
            parentCID: parentCID,
            parentData: parentData,
            rewards: [childReward, descendantReward]
        )
        let decodedRequest = try ChildCandidateRequestMessage.decoded(
            request.encoded()
        )
        XCTAssertEqual(decodedRequest.budgetMilliseconds, 750)
        XCTAssertEqual(decodedRequest.rewards.map(\.chainPath), [
            ["Nexus", "Payments"],
            ["Nexus", "Payments", "Receipts"],
        ])
        XCTAssertNotNil(decodedRequest.rewards[0].transaction.body.node)

        let response = ChildCandidateResponseMessage(
            requestID: 11,
            childPath: ["Nexus", "Payments"],
            parentCID: parentCID,
            childCID: parentCID,
            blockData: parentData,
            searchWitness: nil
        )
        let decodedResponse = try ChildCandidateResponseMessage.decoded(
            response.encoded()
        )
        XCTAssertEqual(decodedResponse.parentCID, parentCID)
        XCTAssertNil(decodedResponse.searchWitness)

        var forgedTarget = try response.encoded()
        let targetOffset = 8 + 2
            + (2 + "Nexus".utf8.count)
            + (2 + "Payments".utf8.count)
            + 2 + parentCID.utf8.count
            + 2 + parentCID.utf8.count
        forgedTarget.insert(
            contentsOf: Data(repeating: 0x66, count: 64),
            at: targetOffset
        )
        XCTAssertThrowsError(
            try ChildCandidateResponseMessage.decoded(forgedTarget)
        )

        XCTAssertThrowsError(try ChildCandidateRequestMessage(
            requestID: 12,
            budgetMilliseconds: 750,
            childPath: ["Nexus", "Payments"],
            parentCID: parentCID,
            parentData: parentData,
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
        func candidate(_ data: Data) -> ChildCandidateResponseMessage {
            ChildCandidateResponseMessage(
                requestID: 19,
                childPath: ["Nexus", "Payments"],
                parentCID: childCID,
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

    func testCandidateRequestEnforcesHierarchyRewardAndFrameBounds() async throws {
        XCTAssertEqual(
            ChildCandidateRequestMessage.maximumRewardBytes,
            ChainServiceLimits.maximumPayloadBytes
        )
        let parent = try await canonicalNetworkBlock()
        let parentCID = try BlockHeader(node: parent).rawCID
        let parentData = try XCTUnwrap(parent.toData())
        let maximumDepthPath = ["Nexus"] + Array(
            repeating: String(repeating: "x", count: 64),
            count: 256
        )
        let valid = try ChildCandidateRequestMessage(
            requestID: 15,
            budgetMilliseconds: 750,
            childPath: maximumDepthPath,
            parentCID: parentCID,
            parentData: parentData,
            rewards: []
        ).encoded()
        XCTAssertLessThan(
            valid.count,
            ChildCandidateRequestMessage.maximumEncodedBytes
        )

        // The reward list has no invented count cap; it is bounded structurally by
        // the wire capacity (UInt16 count prefix) and the reward-byte cap. The
        // total message is still bounded by the frame size below.
        XCTAssertThrowsError(try ChildCandidateRequestMessage.decoded(Data(
            repeating: 0,
            count: ChildCandidateRequestMessage.maximumEncodedBytes + 1
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

    func testCandidateAcquirerIsBoundedFIFOAndDeduplicated() throws {
        var acquirer = CandidateAcquirer()
        XCTAssertTrue(acquirer.observe(.init(
            blockCID: "first",
            package: nil
        )).accepted)
        XCTAssertTrue(acquirer.observe(.init(
            blockCID: "second",
            package: nil
        )).accepted)
        XCTAssertTrue(acquirer.observe(.init(
            blockCID: "first",
            package: nil
        )).accepted)
        let first = try XCTUnwrap(acquirer.next())
        XCTAssertEqual(first.blockCID, "first")
        XCTAssertTrue(acquirer.complete(
            first.ticket,
            resolution: .terminal
        ))
        let second = try XCTUnwrap(acquirer.next())
        XCTAssertEqual(second.blockCID, "second")
        XCTAssertTrue(acquirer.complete(
            second.ticket,
            resolution: .terminal
        ))
        XCTAssertNil(acquirer.next())

        for index in 0..<CandidateAcquirer.readyCapacity {
            XCTAssertTrue(acquirer.observe(.init(
                blockCID: "cid-\(index)",
                package: nil
            )).accepted)
        }
        XCTAssertFalse(acquirer.observe(.init(
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

    func testCandidateBudgetsShrinkAndPeerPriorityRotates() {
        let childBudget = NodeNetworkRuntime.remoteChildCandidateBudget(
            parentWaitMilliseconds: 1_000
        )
        let grandchildBudget = childBudget.flatMap {
            NodeNetworkRuntime.remoteChildCandidateBudget(
                parentWaitMilliseconds: UInt64($0)
            )
        }
        XCTAssertEqual(childBudget, 750)
        XCTAssertEqual(grandchildBudget, 563)

        let first = NodeNetworkRuntime.rotatedPeerIndices(
            peerCount: 3,
            start: 0,
            limit: 2
        )
        let second = NodeNetworkRuntime.rotatedPeerIndices(
            peerCount: 3,
            start: first.next,
            limit: 2
        )
        XCTAssertEqual(first.indices, [0, 1])
        XCTAssertEqual(second.indices, [1, 2])
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

        let content = NetworkTestContentStore()
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
        let storedLeafVolume = await content.serializedVolume(
            rootCID: leafHeader.rawCID
        )
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
        let firstAdmissionGate = CandidateBuildGate()
        let handlers = NodeNetworkHandlers(
            admission: { admission in
                guard let rootCID = admission.authenticatedChildPackage?
                    .package.proof.rootCID else {
                    await unavailable.append(admission.header.rawCID)
                    return NodeAdmissionOutcome(
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
                return NodeAdmissionOutcome(
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
            NetworkTestVolumeSource(value: leafSerializedVolume)
        )
        await replacement.setContentSource(
            NetworkTestVolumeSource(value: leafSerializedVolume)
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
            try await runtime.start(process: process, handlers: handlers)
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
                phase: "replacement advertiser retry",
                attempts: 2_000
            )
            let admittedRoots = await roots.snapshot()
            let servedRoots = await delegate.servedRoots()
            XCTAssertEqual(
                servedRoots,
                Set(attachments.map(\.summary.attachmentCID))
            )
            XCTAssertEqual(admittedRoots.count, 2)
            XCTAssertEqual(Set(admittedRoots), Set(proofs.map(\.rootCID)))
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

    func testCanonicalNetworkMessagesRejectAlternateEncodings() throws {
        let message = BlockAnnouncementMessage(blockCID: "candidate")
        let encoded = try message.encoded()
        XCTAssertEqual(try BlockAnnouncementMessage.decoded(encoded), message)

        var padded = encoded
        padded.append(0x20)
        XCTAssertThrowsError(try BlockAnnouncementMessage.decoded(padded)) { error in
            XCTAssertEqual(error as? NodeNetworkWireError, .nonCanonical)
        }
    }

    func testTransactionInventoryWireIsCanonicalAndCursorBound() throws {
        let available = TransactionAvailableMessage(volumeRootCID: "volume")
        XCTAssertEqual(
            try TransactionAvailableMessage.decoded(available.encoded()),
            available
        )

        let request = TransactionInventoryRequestMessage(
            requestID: 1,
            afterRootCID: "b"
        )
        XCTAssertEqual(
            try TransactionInventoryRequestMessage.decoded(request.encoded()),
            request
        )
        XCTAssertThrowsError(try TransactionInventoryRequestMessage(
            requestID: 0,
            afterRootCID: nil
        ).encoded())

        let valid = TransactionInventoryResponseMessage(
            requestID: 1,
            afterRootCID: "b",
            volumeRootCIDs: ["c", "d"],
            hasMore: false
        )
        XCTAssertEqual(
            try TransactionInventoryResponseMessage.decoded(valid.encoded()),
            valid
        )
        let fullPage = (0..<TransactionInventoryResponseMessage.maximumRoots)
            .map { String(format: "r%02d", $0) }
        XCTAssertNoThrow(try TransactionInventoryResponseMessage(
            requestID: 1,
            afterRootCID: nil,
            volumeRootCIDs: fullPage,
            hasMore: true
        ).encoded())
        for invalid in [
            TransactionInventoryResponseMessage(
                requestID: 1,
                afterRootCID: "b",
                volumeRootCIDs: ["d", "c"],
                hasMore: false
            ),
            TransactionInventoryResponseMessage(
                requestID: 1,
                afterRootCID: "b",
                volumeRootCIDs: ["b"],
                hasMore: false
            ),
            TransactionInventoryResponseMessage(
                requestID: 1,
                afterRootCID: nil,
                volumeRootCIDs: ["c"],
                hasMore: true
            ),
            TransactionInventoryResponseMessage(
                requestID: 1,
                afterRootCID: nil,
                volumeRootCIDs: fullPage + ["z"],
                hasMore: false
            ),
        ] {
            XCTAssertThrowsError(try invalid.encoded())
        }

        var padded = try valid.encoded()
        padded.append(0x20)
        XCTAssertThrowsError(
            try TransactionInventoryResponseMessage.decoded(padded)
        ) { error in
            XCTAssertEqual(error as? NodeNetworkWireError, .nonCanonical)
        }
    }

    func testRealIvyFetchesCompleteVolumeFromExactAuthenticatedSession()
        async throws
    {
        let transaction = try signedNetworkTransaction(chainPath: ["Nexus"])
        let volume = try await transactionVolume(transaction)
        let serverKey = signingKey(0x9e)
        let serverPort = NetworkTransportTestPorts.allocate()
        let server = Ivy(config: IvyConfig(
            signingKey: serverKey,
            listenPort: serverPort,
            stunServers: [],
            mode: .overlay
        ))
        await server.setContentSource(NetworkTestVolumeSource(value: volume))
        let client = Ivy(config: IvyConfig(
            signingKey: signingKey(0x9f),
            listenPort: 0,
            requestTimeout: .seconds(1),
            stunServers: [],
            mode: .overlay
        ))
        let recorder = AuthenticatedPeerRecorder()
        await client.installTestDelegate(recorder)

        do {
            try await server.start()
            try await client.start()
            try await client.connect(to: PeerEndpoint(
                publicKey: peerKey(serverKey).hex,
                host: "127.0.0.1",
                port: serverPort
            ))
            let peer: AuthenticatedPeer
            for _ in 0..<200 {
                if let connected = await recorder.connectedPeer() {
                    peer = connected
                    let response = await client.fetchVolume(
                        rootCID: volume.root,
                        from: peer
                    )
                    XCTAssertEqual(response.rootCID, volume.root)
                    XCTAssertEqual(response.entries, volume.entries)
                    XCTAssertEqual(response.servedBy, peer.id)
                    await client.stop()
                    await server.stop()
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw NetworkTestError.failedStart
        } catch {
            await client.stop()
            await server.stop()
            throw error
        }
    }

    func testTransactionAnnouncementUsesExactAdvertiserAndRejectsInvalidVolume()
        async throws
    {
        let target = try await overlayRuntime(
            keyByte: 0xa1,
            requestTimeout: .milliseconds(150)
        )
        let service = networkService(
            process: target.process,
            runtime: target.runtime
        )
        let transactionAttempts = NetworkEventRecorder()
        let handlers = transactionServiceHandlers(
            service,
            transactions: transactionAttempts
        )

        let valid = try signedNetworkTransaction(chainPath: ["Nexus"])
        let validVolume = try await transactionVolume(valid)
        let invalid = try signedNetworkTransaction(
            chainPath: ["Nexus", "Other"]
        )
        let invalidVolume = try await transactionVolume(invalid)
        let observerTopics = TopicRecorder()
        let observer = Ivy(config: IvyConfig(
            signingKey: signingKey(0xa2),
            listenPort: 0,
            stunServers: [],
            mode: .overlay
        ))
        let observerDelegate = TransactionTopicRecordingPeer(
            recorder: observerTopics
        )
        await observer.installTestDelegate(observerDelegate)
        await observer.setContentSource(NetworkTestVolumeSource(
            value: validVolume
        ))

        let advertiserTopics = TopicRecorder()
        let advertiser = Ivy(config: IvyConfig(
            signingKey: signingKey(0xa3),
            listenPort: 0,
            stunServers: [],
            mode: .overlay
        ))
        let advertiserDelegate = TransactionTopicRecordingPeer(
            recorder: advertiserTopics
        )
        await advertiser.installTestDelegate(advertiserDelegate)
        await advertiser.setContentSource(NetworkTestVolumeSource(
            value: invalidVolume
        ))
        let unavailableTopics = TopicRecorder()
        let unavailable = Ivy(config: IvyConfig(
            signingKey: signingKey(0xaa),
            listenPort: 0,
            stunServers: [],
            mode: .overlay
        ))
        let unavailableDelegate = TransactionTopicRecordingPeer(
            recorder: unavailableTopics
        )
        await unavailable.installTestDelegate(unavailableDelegate)

        do {
            try await target.runtime.start(
                process: target.process,
                handlers: handlers
            )
            try await connectAndHello(
                observer,
                peerID: target.peerID,
                endpoint: target.endpoint,
                hello: target.hello
            )
            try await waitForTopic(
                NodeNetworkTopic.transactionInventoryRequest,
                in: observerTopics
            )
            try await connectAndHello(
                advertiser,
                peerID: target.peerID,
                endpoint: target.endpoint,
                hello: target.hello
            )
            try await waitForTopic(
                NodeNetworkTopic.transactionInventoryRequest,
                in: advertiserTopics
            )
            guard case .enqueued = await advertiser.sendMessage(
                to: target.peerID,
                topic: NodeNetworkTopic.transactionAvailable,
                payload: try TransactionAvailableMessage(
                    volumeRootCID: invalidVolume.root
                ).encoded()
            ) else { throw NetworkTestError.failedSend }
            try await Task.sleep(for: .milliseconds(300))

            let invalidStatus = await service.status()
            let relayedInvalid = await observerTopics.contains(
                NodeNetworkTopic.transactionAvailable
            )
            XCTAssertEqual(invalidStatus.mempoolCount, 0)
            XCTAssertFalse(relayedInvalid)

            await advertiser.stop()
            try await connectAndHello(
                unavailable,
                peerID: target.peerID,
                endpoint: target.endpoint,
                hello: target.hello
            )
            try await waitForTopic(
                NodeNetworkTopic.transactionInventoryRequest,
                in: unavailableTopics
            )

            guard case .enqueued = await unavailable.sendMessage(
                to: target.peerID,
                topic: NodeNetworkTopic.transactionAvailable,
                payload: try TransactionAvailableMessage(
                    volumeRootCID: validVolume.root
                ).encoded()
            ) else { throw NetworkTestError.failedSend }
            try await Task.sleep(for: .milliseconds(300))

            let unavailableStatus = await service.status()
            let relayedUnavailable = await observerTopics.contains(
                NodeNetworkTopic.transactionAvailable
            )
            XCTAssertEqual(unavailableStatus.mempoolCount, 0)
            XCTAssertFalse(relayedUnavailable)

            let extra = try HeaderImpl<PublicKey>(
                node: PublicKey(key: "unrelated-volume-member")
            )
            var bloatedEntries = validVolume.entries
            bloatedEntries[extra.rawCID] = try extra.mapToData()
            let bloated = SerializedVolume(
                root: validVolume.root,
                entries: bloatedEntries
            )
            try bloated.validate()
            await observer.setContentSource(NetworkTestVolumeSource(
                value: bloated
            ))
            let attemptsBefore = await transactionAttempts.snapshot().count
            guard case .enqueued = await observer.sendMessage(
                to: target.peerID,
                topic: NodeNetworkTopic.transactionAvailable,
                payload: try TransactionAvailableMessage(
                    volumeRootCID: validVolume.root
                ).encoded()
            ) else { throw NetworkTestError.failedSend }
            try await waitForEventCount(
                attemptsBefore + 1,
                in: transactionAttempts
            )
            try await waitForMempoolCount(1, service: service)

            let normalized = await target.process.volume(validVolume.root)
            XCTAssertNotNil(normalized)
            XCTAssertNil(normalized?.entries[extra.rawCID])
        } catch {
            await unavailable.stop()
            await advertiser.stop()
            await observer.stop()
            await target.runtime.stop()
            throw error
        }
        await unavailable.stop()
        await advertiser.stop()
        await observer.stop()
        await target.runtime.stop()
    }

    func testSameChainTransactionRelaysAndLateJoinerRecoversFromPeerInventory()
        async throws
    {
        let first = try await overlayRuntime(
            keyByte: 0xa4,
            requestTimeout: .seconds(15)
        )
        let second = try await overlayRuntime(
            keyByte: 0xa5,
            requestTimeout: .seconds(15),
            bootstrapPeers: [first.endpoint]
        )
        let firstService = networkService(
            process: first.process,
            runtime: first.runtime
        )
        let secondService = networkService(
            process: second.process,
            runtime: second.runtime
        )
        let firstInventoryRequests = NetworkEventRecorder()
        let secondInventoryRequests = NetworkEventRecorder()
        let secondTransactions = NetworkEventRecorder()
        let firstHandlers = transactionServiceHandlers(
            firstService,
            inventoryRequests: firstInventoryRequests
        )
        let secondHandlers = transactionServiceHandlers(
            secondService,
            inventoryRequests: secondInventoryRequests,
            transactions: secondTransactions
        )
        let publicationTopics = TopicRecorder()
        let publicationDelegate = TopicRecordingPeer(recorder: publicationTopics)
        let publicationObserver = Ivy(config: IvyConfig(
            signingKey: signingKey(0xa7),
            listenPort: 0,
            stunServers: [],
            mode: .overlay
        ))
        await publicationObserver.installTestDelegate(publicationDelegate)

        var late: (
            runtime: NodeNetworkRuntime,
            process: ChainProcess,
            peerID: PeerID,
            endpoint: PeerEndpoint,
            hello: Data
        )?
        do {
            try await first.runtime.start(
                process: first.process,
                handlers: firstHandlers
            )
            try await connectAndHello(
                publicationObserver,
                peerID: first.peerID,
                endpoint: first.endpoint,
                hello: first.hello
            )
            try await waitForTopic(
                NodeNetworkTopic.transactionInventoryRequest,
                in: publicationTopics
            )

            let transaction = try signedNetworkTransaction(
                chainPath: ["Nexus"]
            )
            let submitted = try await firstService.submitTransaction(
                SubmitTransactionRequest(transaction: transaction)
            )
            try await waitForTopic(
                NodeNetworkTopic.transactionAvailable,
                in: publicationTopics
            )
            try await second.runtime.start(
                process: second.process,
                handlers: secondHandlers
            )
            try await waitForEvent(
                in: secondInventoryRequests,
                phase: "second inventory handshake"
            )
            try await waitForEvent(
                in: firstInventoryRequests,
                phase: "first inventory response"
            )
            try await waitForEvent(
                in: secondTransactions,
                phase: "second transaction handler",
                attempts: 2_000
            )
            try await waitForMempoolCount(
                1,
                service: secondService,
                phase: "second peer direct relay"
            )
            let secondInventory = await secondService.transactionInventoryRoots()
            XCTAssertEqual(
                secondInventory,
                [submitted.transactionCID]
            )

            // The original submitter disappears, and the receiving runtime
            // restarts. A late joiner must recover the complete Volume from
            // that peer's ordinary inventory, not from the original source.
            await first.runtime.stop()
            await second.runtime.stop()
            try await second.runtime.start(
                process: second.process,
                handlers: secondHandlers
            )

            let joined = try await overlayRuntime(
                keyByte: 0xa6,
                requestTimeout: .seconds(15),
                bootstrapPeers: [second.endpoint]
            )
            late = joined
            let lateService = networkService(
                process: joined.process,
                runtime: joined.runtime
            )
            let lateHandlers = transactionServiceHandlers(lateService)
            try await joined.runtime.start(
                process: joined.process,
                handlers: lateHandlers
            )
            try await waitForMempoolCount(
                1,
                service: lateService,
                phase: "late join inventory"
            )

            let lateInventory = await lateService.transactionInventoryRoots()
            let retainedVolume = await joined.process.volume(
                submitted.transactionCID
            )
            XCTAssertEqual(lateInventory, [submitted.transactionCID])
            XCTAssertNotNil(retainedVolume)
        } catch {
            if let late { await late.runtime.stop() }
            await publicationObserver.stop()
            await second.runtime.stop()
            await first.runtime.stop()
            throw error
        }
        if let late { await late.runtime.stop() }
        await publicationObserver.stop()
        await second.runtime.stop()
        await first.runtime.stop()
    }

    func testAllKnownInventoryPageStillContinuesTheScan() async throws {
        let node = try await overlayRuntime(
            keyByte: 0xa8,
            requestTimeout: .seconds(15)
        )
        let service = networkService(
            process: node.process,
            runtime: node.runtime
        )
        let handlers = transactionServiceHandlers(service)
        let peer = Ivy(config: IvyConfig(
            signingKey: signingKey(0xa9),
            listenPort: 0,
            stunServers: [],
            mode: .overlay
        ))
        do {
            try await node.runtime.start(
                process: node.process,
                handlers: handlers
            )
            // Fill the mempool with one full wire page of known roots, so a
            // peer can serve a valid 64-root page containing nothing new.
            var known: [String] = []
            while known.count < TransactionInventoryResponseMessage
                .maximumRoots {
                let transaction = try signedNetworkTransaction(
                    chainPath: ["Nexus"]
                )
                let submitted = try await service.submitTransaction(
                    SubmitTransactionRequest(transaction: transaction)
                )
                known.append(submitted.transactionCID)
            }
            let echo = EchoInventoryPeer(roots: known)
            await peer.installTestDelegate(echo)
            try await connectAndHello(
                peer,
                peerID: node.peerID,
                endpoint: node.endpoint,
                hello: node.hello
            )
            // Honest mempools overlap: a full page of already-known roots
            // must consume budget yet continue the scan, because later pages
            // may hold roots we lack. Truncating here is the regression.
            for _ in 0..<400 {
                if await echo.continuationCount() >= 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let continuations = await echo.continuationCount()
            XCTAssertGreaterThanOrEqual(continuations, 1)
        } catch {
            await peer.stop()
            await node.runtime.stop()
            throw error
        }
        await peer.stop()
        await node.runtime.stop()
    }

    func testTransactionFetchDoesNotBlockSameSessionIngress() async throws {
        let target = try await overlayRuntime(
            keyByte: 0xa8,
            requestTimeout: .seconds(2)
        )
        let service = networkService(process: target.process, runtime: target.runtime)
        let transactions = NetworkEventRecorder()
        let inventoryRequests = NetworkEventRecorder()
        let handlers = transactionServiceHandlers(
            service,
            inventoryRequests: inventoryRequests,
            transactions: transactions
        )
        let transaction = try signedNetworkTransaction(chainPath: ["Nexus"])
        let volume = try await transactionVolume(transaction)
        let source = BlockingNetworkTestVolumeSource(value: volume)
        let topics = TopicRecorder()
        let advertiser = Ivy(config: IvyConfig(
            signingKey: signingKey(0xa9),
            listenPort: 0,
            stunServers: [],
            mode: .overlay
        ))
        let advertiserDelegate = TransactionTopicRecordingPeer(recorder: topics)
        await advertiser.installTestDelegate(advertiserDelegate)
        await advertiser.setContentSource(source)

        do {
            try await target.runtime.start(
                process: target.process,
                handlers: handlers
            )
            try await connectAndHello(
                advertiser,
                peerID: target.peerID,
                endpoint: target.endpoint,
                hello: target.hello
            )
            guard case .enqueued = await advertiser.sendMessage(
                to: target.peerID,
                topic: NodeNetworkTopic.transactionAvailable,
                payload: try TransactionAvailableMessage(
                    volumeRootCID: volume.root
                ).encoded()
            ) else { throw NetworkTestError.failedSend }
            for _ in 0..<200 {
                if await source.didStart() { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let didStart = await source.didStart()
            XCTAssertTrue(didStart)

            guard case .enqueued = await advertiser.sendMessage(
                to: target.peerID,
                topic: NodeNetworkTopic.transactionInventoryRequest,
                payload: try TransactionInventoryRequestMessage(
                    requestID: 99,
                    afterRootCID: nil
                ).encoded()
            ) else { throw NetworkTestError.failedSend }
            try await waitForEventCount(
                1,
                in: inventoryRequests,
                phase: "concurrent transaction inventory request"
            )
            try await waitForTopic(
                NodeNetworkTopic.transactionInventoryResponse,
                in: topics
            )
            let attempts = await transactions.snapshot()
            XCTAssertTrue(attempts.isEmpty)

            await source.release()
            try await waitForMempoolCount(1, service: service)
        } catch {
            await source.release()
            await advertiser.stop()
            await target.runtime.stop()
            throw error
        }
        await advertiser.stop()
        await target.runtime.stop()
    }

    func testPlaneLifecycleStartsPrivateFirstAndStopsInReverse() async throws {
        let success = NetworkEventRecorder()
        try await NodeNetworkRuntime.startPlanes(
            startHierarchy: { await success.append("start-hierarchy") },
            startOverlay: { await success.append("start-overlay") },
            stopOverlay: { await success.append("stop-overlay") },
            stopHierarchy: { await success.append("stop-hierarchy") }
        )
        await NodeNetworkRuntime.stopPlanes(
            stopOverlay: { await success.append("stop-overlay") },
            stopHierarchy: { await success.append("stop-hierarchy") }
        )
        let successEvents = await success.snapshot()
        XCTAssertEqual(successEvents, [
            "start-hierarchy", "start-overlay", "stop-overlay", "stop-hierarchy",
        ])

        let failure = NetworkEventRecorder()
        do {
            try await NodeNetworkRuntime.startPlanes(
                startHierarchy: { await failure.append("start-hierarchy") },
                startOverlay: {
                    await failure.append("start-overlay")
                    throw NetworkTestError.failedStart
                },
                stopOverlay: { await failure.append("stop-overlay") },
                stopHierarchy: { await failure.append("stop-hierarchy") }
            )
            XCTFail("expected overlay start failure")
        } catch NetworkTestError.failedStart {}
        let failureEvents = await failure.snapshot()
        XCTAssertEqual(failureEvents, [
            "start-hierarchy", "start-overlay", "stop-overlay", "stop-hierarchy",
        ])
    }

    func testRealIvyApplicationMessageReachesAsyncRuntimeDelegate() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-network-delegate-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let overlayPort = NetworkTransportTestPorts.allocate()
        let hierarchyPort = NetworkTransportTestPorts.allocate()
        let rpcPort = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storage,
            privateKeyHex: String(repeating: "5d", count: 32),
            listenPort: overlayPort,
            factListenPort: hierarchyPort,
            rpcPort: rpcPort
        )
        let planes = try NodeNetworkPlaneConfigurations(
            overlay: IvyConfig(
                signingKey: configuration.signingKey,
                listenPort: overlayPort,
                stunServers: [],
                mode: .overlay
            ),
            hierarchy: IvyConfig(
                signingKey: configuration.signingKey,
                listenPort: hierarchyPort,
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
        let candidateVolume = try await canonicalNetworkBlockVolumes(count: 1)[0]
        let candidateCID = candidateVolume.root
        let admissions = NetworkEventRecorder()
        let delivered = expectation(
            description: "real Ivy application message reaches runtime delegate"
        )
        let handlers = NodeNetworkHandlers(admission: { admission in
            await admissions.append(admission.header.rawCID)
            delivered.fulfill()
            return NodeAdmissionOutcome(
                decision: .duplicate,
                parentCarrierLink: nil,
                sameChainPredecessor: nil
            )
        })
        let client = Ivy(config: IvyConfig(
            signingKey: signingKey(94),
            listenPort: 0,
            stunServers: [],
            mode: .overlay
        ))
        await client.setContentSource(NetworkTestVolumeSource(
            value: candidateVolume
        ))
        do {
            try await runtime.start(process: process, handlers: handlers)
            try await client.start()
            let runtimePeer = PeerID(publicKey: configuration.processPublicKey)
            try await client.connect(to: PeerEndpoint(
                publicKey: configuration.processPublicKey,
                host: "127.0.0.1",
                port: overlayPort
            ))
            let hello = try ChainHello(
                nexusGenesisCID: configuration.nexusGenesisCID,
                chainPath: configuration.chainPath
            ).encode()
            guard case .enqueued = await client.sendMessage(
                to: runtimePeer,
                topic: NodeNetworkTopic.overlayHello,
                payload: hello
            ) else {
                throw NetworkTestError.failedSend
            }
            guard case .enqueued = await client.sendMessage(
                to: runtimePeer,
                topic: NodeNetworkTopic.blockAnnouncement,
                payload: try BlockAnnouncementMessage(blockCID: candidateCID).encoded()
            ) else {
                throw NetworkTestError.failedSend
            }

            await fulfillment(of: [delivered], timeout: 2)
            let recordedAdmissions = await admissions.snapshot()
            XCTAssertEqual(recordedAdmissions, [candidateCID])
        } catch {
            await client.stop()
            await runtime.stop()
            throw error
        }
        await client.stop()
        await runtime.stop()
    }

    func testOnceAnnouncedFutureBlockRetriesUntilAdmissible() async throws {
        let fixture = try await overlayRuntime(
            keyByte: 0xb1,
            requestTimeout: .milliseconds(25)
        )
        let service = networkService(
            process: fixture.process,
            runtime: fixture.runtime
        )
        let decisions = NetworkEventRecorder()
        let handlers = NodeNetworkHandlers(admission: { admission in
            let outcome = try await service.admitNetworkCandidate(
                admission.header,
                authenticatedChildPackage: admission.authenticatedChildPackage,
                preparingChildDirectories: admission.preparingChildDirectories,
                contentSource: admission.contentSource
            )
            let decision = switch outcome.decision {
            case .canonicalized: "canonicalized"
            case .acceptedSide: "acceptedSide"
            case .carrier: "carrier"
            case .duplicate: "duplicate"
            case .unavailable: "unavailable"
            case .temporarilyInvalid: "temporarilyInvalid"
            case .invalid: "invalid"
            case .localFailure: "localFailure"
            }
            await decisions.append(decision)
            return outcome
        })
        let advertiser = Ivy(config: IvyConfig(
            signingKey: signingKey(0xb2),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))

        do {
            try await fixture.runtime.start(
                process: fixture.process,
                handlers: handlers
            )
            try await connectAndHello(
                advertiser,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )

            let parent = try await fixture.process.canonicalTipBlock()
            // Admission is strict (`timestamp <= now`) — Lattice 27.0.0 removed the
            // central future-drift tolerance. A block 5s ahead is briefly deferred
            // (notYetAdmissible), then admits once real time reaches its timestamp.
            let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
                + 5_000
            var nonce: UInt64 = 0
            var future = try await BlockBuilder.buildBlock(
                previous: parent,
                timestamp: timestamp,
                nonce: nonce,
                fetcher: fixture.process
            )
            while future.proofOfWorkHash() > future.target {
                nonce += 1
                future = try await BlockBuilder.buildBlock(
                    previous: parent,
                    timestamp: timestamp,
                    nonce: nonce,
                    fetcher: fixture.process
                )
            }
            let header = try BlockHeader(node: future)
            let source = NetworkTestContentStore()
            try await header.storeBlock(
                fetcher: fixture.process,
                storer: source
            )
            let storedVolume = await source.serializedVolume(
                rootCID: header.rawCID
            )
            let volume = try XCTUnwrap(storedVolume)
            await advertiser.setContentSource(
                NetworkTestVolumeSource(value: volume)
            )

            guard case .enqueued = await advertiser.sendMessage(
                to: fixture.peerID,
                topic: NodeNetworkTopic.blockAnnouncement,
                payload: try BlockAnnouncementMessage(
                    blockCID: header.rawCID
                ).encoded()
            ) else {
                throw NetworkTestError.failedSend
            }
            for _ in 0..<200 {
                if (await decisions.snapshot()).contains("temporarilyInvalid") {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            let futureDecisions = await decisions.snapshot()
            XCTAssertTrue(futureDecisions.contains("temporarilyInvalid"))
            for _ in 0..<800 {
                if await fixture.process.status().tipCID == header.rawCID,
                   (await decisions.snapshot()).contains("canonicalized") {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            let admittedStatus = await fixture.process.status()
            let admittedDecisions = await decisions.snapshot()
            XCTAssertEqual(admittedStatus.tipCID, header.rawCID)
            XCTAssertTrue(
                admittedDecisions.contains("canonicalized"),
                "decisions: \(admittedDecisions)"
            )
        } catch {
            await advertiser.stop()
            await fixture.runtime.stop()
            throw error
        }
        await advertiser.stop()
        await fixture.runtime.stop()
    }

    func testAncestorNegotiationTimeoutRenegotiatesInsteadOfPagingFromFrontier()
        async throws
    {
        // A range sync whose common ancestor was never negotiated must not
        // fall through to a forward page anchored at the receiver's own
        // frontier: on a losing sibling that frontier is off the peer's main
        // chain, the empty page reads as "caught up", and one dropped packet
        // maroons the follower. The timeout re-sends the locator instead.
        let fixture = try await overlayRuntime(
            keyByte: 0x75,
            requestTimeout: .milliseconds(150)
        )
        let scripted = RangeNegotiationDroppingPeer()
        let peer = Ivy(config: IvyConfig(
            signingKey: signingKey(0x76),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        await peer.installTestDelegate(scripted)

        do {
            try await fixture.runtime.start(
                process: fixture.process,
                handlers: inertNetworkHandlers()
            )
            try await connectAndHello(
                peer,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            // A claim far past the range-sync threshold opens a range sync,
            // which begins with the locator negotiation the peer drops.
            guard case .enqueued = await peer.sendMessage(
                to: fixture.peerID,
                topic: NodeNetworkTopic.blockAnnouncement,
                payload: try BlockAnnouncementMessage(
                    blockCID: testCID("deep-tip"),
                    height: 100
                ).encoded()
            ) else {
                throw NetworkTestError.failedSend
            }
            for _ in 0..<300 {
                if (await scripted.counts()).ancestor >= 2 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let counts = await scripted.counts()
            XCTAssertGreaterThanOrEqual(counts.ancestor, 2)
            XCTAssertEqual(
                counts.forward, 0,
                "a timed-out negotiation paged forward from the frontier"
            )
        } catch {
            await peer.stop()
            await fixture.runtime.stop()
            throw error
        }
        await peer.stop()
        await fixture.runtime.stop()
    }

    func testBlockValidationFindsMissingVolumeFromAdvertisedProvider()
        async throws
    {
        let fixture = try await overlayRuntime(
            keyByte: 0x6b,
            requestTimeout: .milliseconds(150)
        )
        let process = try await canonicalNetworkProcess()
        let transaction = try unsignedTransaction(path: ["Nexus"])
        let transactionVolume = try await transactionVolume(transaction)
        try await VolumeImpl<Transaction>(node: transaction)
            .storeRecursively(storer: process)
        let previous = try await process.canonicalTipBlock()
        let block = try await BlockBuilder.buildBlock(
            previous: previous,
            transactions: [transaction],
            timestamp: 1,
            nonce: 1,
            fetcher: process
        )
        let header = try BlockHeader(node: block)
        try await header.storeBlock(fetcher: process, storer: process)
        let storedBlockVolume = await process.volume(header.rawCID)
        let blockVolume = try XCTUnwrap(storedBlockVolume)

        let badSource = RecordingNetworkTestVolumesSource([blockVolume])
        let bad = Ivy(config: IvyConfig(
            signingKey: signingKey(0x6c),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        await bad.setContentSource(badSource)

        let honestPort = NetworkTransportTestPorts.allocate()
        let honestSource = RecordingNetworkTestVolumesSource([
            transactionVolume
        ])
        let honest = Ivy(config: IvyConfig(
            signingKey: signingKey(0x6d),
            listenPort: honestPort,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        await honest.setContentSource(honestSource)
        let admitted = NetworkEventRecorder()
        let handlers = NodeNetworkHandlers(admission: { admission in
            let root = await admission.contentSource.fetch([
                admission.header.rawCID
            ])
            let nested = await admission.contentSource.fetch([
                transactionVolume.root
            ])
            guard root[admission.header.rawCID] != nil,
                  nested[transactionVolume.root] != nil else {
                throw NetworkTestError.failedPhase(
                    "split Volume acquisition"
                )
            }
            await admitted.append(admission.header.rawCID)
            return NodeAdmissionOutcome(
                decision: .acceptedSide(ChainCommit(
                    tipHash: admission.header.rawCID
                )),
                parentCarrierLink: nil,
                sameChainPredecessor: nil
            )
        })

        do {
            try await fixture.runtime.start(
                process: fixture.process,
                handlers: handlers
            )
            try await connectAndHello(
                honest,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            await honest.announceProvider(
                rootCID: transactionVolume.root,
                expiresAt: UInt64(Date().timeIntervalSince1970) + 60
            )
            try await connectAndHello(
                bad,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            guard case .enqueued = await bad.sendMessage(
                to: fixture.peerID,
                topic: NodeNetworkTopic.blockAnnouncement,
                payload: try BlockAnnouncementMessage(
                    blockCID: blockVolume.root
                ).encoded()
            ) else {
                throw NetworkTestError.failedSend
            }

            for _ in 0..<400 {
                if (await admitted.snapshot()).contains(blockVolume.root) {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }

            let admittedCIDs = await admitted.snapshot()
            let badRequests = await badSource.requests()
            let honestRequests = await honestSource.requests()
            XCTAssertEqual(admittedCIDs, [blockVolume.root])
            XCTAssertTrue(badRequests.contains(transactionVolume.root))
            XCTAssertTrue(honestRequests.contains(transactionVolume.root))
        } catch {
            await bad.stop()
            await honest.stop()
            await fixture.runtime.stop()
            throw error
        }
        await bad.stop()
        await honest.stop()
        await fixture.runtime.stop()
    }

    func testLocalAdmissionFailureDoesNotPunishReplacementSession()
        async throws {
        let fixture = try await overlayRuntime(
            keyByte: 0x78,
            requestTimeout: .milliseconds(300)
        )
        let volumes = try await canonicalNetworkBlockVolumes(count: 3)
        let stalledCID = volumes[0].root
        let replacementCID = volumes[1].root
        let honestCID = volumes[2].root
        let gate = CandidateBuildGate()
        let admitted = NetworkEventRecorder()
        let handlers = NodeNetworkHandlers(admission: { admission in
            await admitted.append(admission.header.rawCID)
            if admission.header.rawCID == stalledCID {
                _ = await gate.enter()
                throw NetworkTestError.failedPhase("stalled acquisition")
            }
            return NodeAdmissionOutcome(
                decision: .acceptedSide(ChainCommit(
                    tipHash: admission.header.rawCID
                )),
                parentCarrierLink: nil,
                sameChainPredecessor: nil
            )
        })

        let attackerKey = signingKey(0x79)
        let firstDelegate = OverlayAnnouncingPeer(announcing: [])
        let first = Ivy(config: IvyConfig(
            signingKey: attackerKey,
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        await first.installTestDelegate(firstDelegate)
        await first.setContentSource(NetworkTestVolumeSource(value: volumes[0]))
        let replacementDelegate = OverlayAnnouncingPeer(announcing: [replacementCID])
        let replacement = Ivy(config: IvyConfig(
            signingKey: attackerKey,
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        await replacement.installTestDelegate(replacementDelegate)
        await replacement.setContentSource(NetworkTestVolumeSource(value: volumes[1]))
        let honestDelegate = OverlayAnnouncingPeer(announcing: [honestCID])
        let honest = Ivy(config: IvyConfig(
            signingKey: signingKey(0x7a),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        await honest.installTestDelegate(honestDelegate)
        await honest.setContentSource(NetworkTestVolumeSource(value: volumes[2]))

        do {
            try await fixture.runtime.start(
                process: fixture.process,
                handlers: handlers
            )
            try await connectAndHello(
                first,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            for _ in 0..<100 {
                if await firstDelegate.authorizedSessionCount() == 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let firstRequests = await firstDelegate.authorizedSessionCount()
            XCTAssertEqual(firstRequests, 1)
            guard case .enqueued = await first.sendMessage(
                to: fixture.peerID,
                topic: NodeNetworkTopic.blockAnnouncement,
                payload: try BlockAnnouncementMessage(
                    blockCID: stalledCID
                ).encoded()
            ) else {
                throw NetworkTestError.failedSend
            }
            for _ in 0..<100 {
                if await gate.enteredCount() == 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let stalledAdmissions = await gate.enteredCount()
            XCTAssertEqual(stalledAdmissions, 1)

            await first.stop()
            try await connectAndHello(
                replacement,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            for _ in 0..<100 {
                if await replacementDelegate.authorizedSessionCount() == 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let replacementRequests = await replacementDelegate.authorizedSessionCount()
            XCTAssertEqual(replacementRequests, 1)
            try await connectAndHello(
                honest,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            for _ in 0..<100 {
                if await honestDelegate.authorizedSessionCount() == 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let honestRequests = await honestDelegate.authorizedSessionCount()
            XCTAssertEqual(honestRequests, 1)

            await gate.release(1)
            for _ in 0..<200 {
                let admittedCIDs = await admitted.snapshot()
                if admittedCIDs.contains(replacementCID),
                   admittedCIDs.contains(honestCID) {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            let replacementConnected = await replacement.connectedPeers
                .contains(fixture.peerID)
            let admittedCIDs = await admitted.snapshot()
            XCTAssertTrue(replacementConnected)
            XCTAssertEqual(admittedCIDs.first, stalledCID)
            XCTAssertTrue(admittedCIDs.contains(honestCID))
            XCTAssertTrue(admittedCIDs.contains(replacementCID))
        } catch {
            await gate.releaseAll()
            await honest.stop()
            await replacement.stop()
            await first.stop()
            await fixture.runtime.stop()
            throw error
        }
        await gate.releaseAll()
        await honest.stop()
        await replacement.stop()
        await first.stop()
        await fixture.runtime.stop()
    }

    func testOverlayHelloDeadlineAndOneShotAuthorization() async throws {
        let fixture = try await overlayRuntime(
            keyByte: 0x7b,
            requestTimeout: .milliseconds(150)
        )
        let silent = Ivy(config: IvyConfig(
            signingKey: signingKey(0x7c),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        let authorizedDelegate = OverlayAnnouncingPeer(announcing: [])
        let authorized = Ivy(config: IvyConfig(
            signingKey: signingKey(0x7d),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        await authorized.installTestDelegate(authorizedDelegate)

        do {
            try await fixture.runtime.start(
                process: fixture.process,
                handlers: inertNetworkHandlers()
            )
            try await silent.start()
            try await silent.connect(to: fixture.endpoint)
            for _ in 0..<100 {
                if (await silent.connectedPeers).contains(fixture.peerID) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let silentConnected = await silent.connectedPeers
                .contains(fixture.peerID)
            XCTAssertTrue(silentConnected)
            for _ in 0..<100 {
                if !(await silent.connectedPeers).contains(fixture.peerID) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let silentStillConnected = await silent.connectedPeers
                .contains(fixture.peerID)
            XCTAssertFalse(silentStillConnected)
            await silent.stop()

            try await connectAndHello(
                authorized,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            for _ in 0..<100 {
                if await authorizedDelegate.authorizedSessionCount() == 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let initialRequests = await authorizedDelegate.authorizedSessionCount()
            XCTAssertEqual(initialRequests, 1)

            guard case .enqueued = await authorized.sendMessage(
                to: fixture.peerID,
                topic: NodeNetworkTopic.overlayHello,
                payload: fixture.hello
            ) else {
                throw NetworkTestError.failedSend
            }
            try await Task.sleep(for: .milliseconds(300))
            let finalRequests = await authorizedDelegate.authorizedSessionCount()
            let authorizedConnected = await authorized.connectedPeers
                .contains(fixture.peerID)
            XCTAssertEqual(finalRequests, 1)
            XCTAssertTrue(authorizedConnected)
        } catch {
            await authorized.stop()
            await silent.stop()
            await fixture.runtime.stop()
            throw error
        }
        await authorized.stop()
        await silent.stop()
        await fixture.runtime.stop()
    }

    func testHierarchyContentRequiresHelloOnEveryRealConnection() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-hierarchy-content-auth-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let parentKey = signingKey(0x71)
        let parentPeer = peerKey(parentKey)
        let parentPort = NetworkTransportTestPorts.allocate()
        let overlayPort = NetworkTransportTestPorts.allocate()
        let hierarchyPort = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus", "Payments"],
            storagePath: storage,
            privateKeyHex: String(repeating: "72", count: 32),
            listenPort: overlayPort,
            factListenPort: hierarchyPort,
            rpcPort: NetworkTransportTestPorts.allocate(),
            parentEndpoint: ParentEndpoint(
                publicKey: parentPeer.hex,
                host: "127.0.0.1",
                port: parentPort
            )
        )
        let runtime = try NodeNetworkRuntime(configuration: configuration)
        let process = try await ChainProcess.open(
            configuration: configuration
        )
        let boundary = try VolumeImpl<PublicKey>(
            node: PublicKey(key: "hierarchy-content")
        )
        try await boundary.store(storer: process)
        let rootCID = boundary.rawCID
        let storedVolume = await process.volume(rootCID)
        let expectedVolume = try XCTUnwrap(storedVolume)
        let runtimePeer = PeerID(publicKey: configuration.processPublicKey)
        let parentHello = try ChainHello(
            nexusGenesisCID: configuration.nexusGenesisCID,
            chainPath: ["Nexus"]
        ).encode()

        func makeParent(
            _ recorder: TopicRecorder
        ) async -> (Ivy, TopicRecordingPeer) {
            let parent = Ivy(config: IvyConfig(
                signingKey: parentKey,
                listenPort: parentPort,
                requestTimeout: .milliseconds(500),
                stunServers: [],
                healthConfig: PeerHealthConfig(enabled: false),
                privateContentExchangeEnabled: true,
                mode: .privateNetwork
            ))
            let delegate = TopicRecordingPeer(recorder: recorder)
            await parent.installTestDelegate(delegate)
            return (parent, delegate)
        }

        func waitForRuntimeHello(_ recorder: TopicRecorder) async throws {
            for _ in 0..<150 {
                if await recorder.contains(NodeNetworkTopic.hierarchyHello) { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw NetworkTestError.failedPhase("runtime hierarchy hello")
        }

        func authorize(_ parent: Ivy) async throws {
            guard case .enqueued = await parent.sendMessage(
                to: runtimePeer,
                topic: NodeNetworkTopic.hierarchyHello,
                payload: parentHello
            ) else {
                throw NetworkTestError.failedSend
            }
            for _ in 0..<100 {
                let response = await parent.fetchVolume(rootCID: rootCID)
                if response.rootCID == rootCID,
                   response.entries == expectedVolume.entries { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw NetworkTestError.failedPhase("authorized hierarchy content")
        }

        let firstRecorder = TopicRecorder()
        var parentPair: (Ivy, TopicRecordingPeer)? = await makeParent(firstRecorder)
        do {
            try await parentPair!.0.start()
            try await runtime.start(
                process: process,
                handlers: inertNetworkHandlers()
            )
            try await waitForRuntimeHello(firstRecorder)
            let beforeFirstHello = await parentPair!.0.fetchVolume(rootCID: rootCID)
            XCTAssertEqual(beforeFirstHello, .empty)
            try await authorize(parentPair!.0)

            await parentPair!.0.stop()
            let replacementRecorder = TopicRecorder()
            parentPair = await makeParent(replacementRecorder)
            try await parentPair!.0.start()
            try await waitForRuntimeHello(replacementRecorder)
            let beforeReplacementHello = await parentPair!.0.fetchVolume(rootCID: rootCID)
            XCTAssertEqual(beforeReplacementHello, .empty)
            try await authorize(parentPair!.0)
        } catch {
            await parentPair?.0.stop()
            await runtime.stop()
            throw error
        }
        await parentPair?.0.stop()
        await runtime.stop()
    }

    func testRestartRecoversAcceptedOrphanSuffixOnlyAfterLocalAttachment()
        async throws
    {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-recovery-suffix-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let overlayPort = NetworkTransportTestPorts.allocate()
        let hierarchyPort = NetworkTransportTestPorts.allocate()
        let rpcPort = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storage,
            privateKeyHex: String(repeating: "6d", count: 32),
            listenPort: overlayPort,
            factListenPort: hierarchyPort,
            rpcPort: rpcPort
        )

        // Persist P (not admitted) -> O (accepted orphan) -> D (accepted
        // orphan), then reopen. Replaying the remote accepted leaf D must walk
        // the missing predecessor suffix and wake it in connection order.
        var stagingProcess: ChainProcess? = try await ChainProcess.open(
            configuration: configuration
        )
        let genesis = try await stagingProcess!.canonicalTipBlock()
        let predecessorCandidate = try await BlockBuilder.buildBlock(
            previous: genesis,
            timestamp: 3_600_000,
            nonce: 1,
            fetcher: stagingProcess!
        )
        let predecessor = try XCTUnwrap(BlockBuilder.mine(
            block: predecessorCandidate,
            target: predecessorCandidate.target,
            maxAttempts: 4_096
        ))
        let predecessorHeader = try BlockHeader(node: predecessor)
        try await predecessorHeader.storeBlock(
            fetcher: stagingProcess!,
            storer: stagingProcess!
        )
        let orphanCandidate = try await BlockBuilder.buildBlock(
            previous: predecessor,
            timestamp: 7_200_000,
            nonce: 2,
            fetcher: stagingProcess!
        )
        let orphan = try XCTUnwrap(BlockBuilder.mine(
            block: orphanCandidate,
            target: orphanCandidate.target,
            maxAttempts: 4_096
        ))
        let orphanHeader = try BlockHeader(node: orphan)
        try await orphanHeader.storeBlock(
            fetcher: stagingProcess!,
            storer: stagingProcess!
        )
        let descendantCandidate = try await BlockBuilder.buildBlock(
            previous: orphan,
            timestamp: 10_800_000,
            nonce: 3,
            fetcher: stagingProcess!
        )
        let descendant = try XCTUnwrap(BlockBuilder.mine(
            block: descendantCandidate,
            target: descendantCandidate.target,
            maxAttempts: 4_096
        ))
        let descendantHeader = try BlockHeader(node: descendant)
        try await descendantHeader.storeBlock(
            fetcher: stagingProcess!,
            storer: stagingProcess!
        )
        let remoteContent = NetworkTestContentStore()
        for header in [predecessorHeader, orphanHeader, descendantHeader] {
            try await header.storeBlock(
                fetcher: stagingProcess!,
                storer: remoteContent
            )
        }
        let orphanAdmission = try await stagingProcess!.admit(orphanHeader)
        let descendantAdmission = try await stagingProcess!.admit(descendantHeader)
        guard case .acceptedSide = orphanAdmission.decision,
              case .acceptedSide = descendantAdmission.decision
        else {
            return XCTFail("expected accepted orphan suffix")
        }
        XCTAssertEqual(
            orphanAdmission.sameChainPredecessor,
            SameChainPredecessorRequirement(
                descendantCID: orphanHeader.rawCID,
                predecessorCID: predecessorHeader.rawCID
            )
        )
        XCTAssertEqual(
            descendantAdmission.sameChainPredecessor,
            SameChainPredecessorRequirement(
                descendantCID: descendantHeader.rawCID,
                predecessorCID: orphanHeader.rawCID
            )
        )
        stagingProcess = nil

        let planes = try NodeNetworkPlaneConfigurations(
            overlay: IvyConfig(
                signingKey: configuration.signingKey,
                listenPort: overlayPort,
                stunServers: [],
                mode: .overlay
            ),
            hierarchy: IvyConfig(
                signingKey: configuration.signingKey,
                listenPort: hierarchyPort,
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
        let recoveredProcess = try await ChainProcess.open(
            configuration: configuration
        )
        let recoveredRequirements = await recoveredProcess
            .unresolvedSameChainPredecessors()
        XCTAssertEqual(
            recoveredRequirements,
            [
                SameChainPredecessorRequirement(
                    descendantCID: descendantHeader.rawCID,
                    predecessorCID: orphanHeader.rawCID
                ),
                SameChainPredecessorRequirement(
                    descendantCID: orphanHeader.rawCID,
                    predecessorCID: predecessorHeader.rawCID
                ),
            ].sorted {
                $0.descendantCID < $1.descendantCID
            }
        )

        let handlers = NodeNetworkHandlers(admission: { admission in
            try await recoveredProcess.admit(
                admission.header,
                authenticatedChildPackage:
                    admission.authenticatedChildPackage,
                preparingChildDirectories:
                    admission.preparingChildDirectories,
                remoteSource: admission.contentSource
            )
        })
        let clientDelegate = OverlayAnnouncingPeer(
            announcing: [descendantHeader.rawCID]
        )
        let client = Ivy(config: IvyConfig(
            signingKey: signingKey(96),
            listenPort: 0,
            stunServers: [],
            mode: .overlay
        ))
        await client.installTestDelegate(clientDelegate)
        await client.setContentSource(remoteContent)

        do {
            try await runtime.start(
                process: recoveredProcess,
                handlers: handlers
            )
            try await client.start()
            let runtimePeer = PeerID(publicKey: configuration.processPublicKey)
            try await client.connect(to: PeerEndpoint(
                publicKey: configuration.processPublicKey,
                host: "127.0.0.1",
                port: overlayPort
            ))
            for _ in 0..<100 {
                if (await client.connectedPeers).contains(runtimePeer) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard (await client.connectedPeers).contains(runtimePeer) else {
                throw NetworkTestError.failedStart
            }
            guard case .enqueued = await client.sendMessage(
                to: runtimePeer,
                topic: NodeNetworkTopic.overlayHello,
                payload: try ChainHello(
                    nexusGenesisCID: configuration.nexusGenesisCID,
                    chainPath: configuration.chainPath
                ).encode()
            ) else {
                throw NetworkTestError.failedSend
            }
            for _ in 0..<200 {
                if await recoveredProcess.status().tipCID
                    == descendantHeader.rawCID {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            let recoveredStatus = await recoveredProcess.status()
            XCTAssertEqual(recoveredStatus.tipCID, descendantHeader.rawCID)
            XCTAssertEqual(recoveredStatus.height, descendant.height)
        } catch {
            await client.stop()
            await runtime.stop()
            throw error
        }
        await client.stop()
        await runtime.stop()
    }

    func testRestartedRuntimeRetriesDurableChildOrphanWhenOnlyPredecessorArrives()
        async throws
    {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-child-orphan-retry-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let parentPeer = peerKey(signingKey(0x97))
        let overlayPort = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus", "Payments"],
            storagePath: storage,
            privateKeyHex: String(repeating: "98", count: 32),
            listenPort: overlayPort,
            factListenPort: NetworkTransportTestPorts.allocate(),
            rpcPort: NetworkTransportTestPorts.allocate(),
            parentEndpoint: ParentEndpoint(
                publicKey: parentPeer.hex,
                host: "127.0.0.1",
                port: NetworkTransportTestPorts.allocate()
            )
        )
        let source = NetworkTestContentStore()
        try await LatticeState.emptyHeader.storeRecursively(storer: source)
        // Self-contained child genesis: the child rebuilds it from the seed and
        // self-admits it (never bootstrapped from a carried-genesis proof).
        let seed = ChildGenesisSeed(
            spec: NexusGenesis.spec, premineTo: nil, timestamp: 1
        )
        let childGenesis = try await ChildGenesisBuilder.build(
            seed: seed,
            chainPath: configuration.chainPath,
            fetcher: source
        )
        try await BlockHeader(node: childGenesis).storeBlock(
            fetcher: source,
            storer: source
        )
        var process: ChainProcess? = try await ChainProcess.open(
            configuration: configuration
        )
        let activated = try await process!.activateSeededChildGenesis(
            seed: seed,
            confirmParentRecordedGenesis: { _ in true }
        )
        XCTAssertTrue(activated)
        let genesis = try await process!.canonicalTipBlock()
        let predecessor = try await BlockBuilder.buildBlock(
            previous: genesis,
            timestamp: 3_600_001,
            nonce: 1,
            fetcher: process!
        )
        let predecessorHeader = try BlockHeader(node: predecessor)
        try await predecessorHeader.storeBlock(fetcher: process!, storer: process!)
        try await predecessorHeader.storeBlock(fetcher: process!, storer: source)
        let orphan = try await BlockBuilder.buildBlock(
            previous: predecessor,
            timestamp: 7_200_001,
            nonce: 2,
            fetcher: process!
        )
        let orphanHeader = try BlockHeader(node: orphan)
        try await orphanHeader.storeBlock(fetcher: process!, storer: process!)
        try await orphanHeader.storeBlock(fetcher: process!, storer: source)

        func package(
            for block: Block,
            header: BlockHeader,
            timestamp: Int64
        ) async throws -> (AuthenticatedChildPackage, String) {
            let carrierCandidate = try await BlockBuilder.buildGenesis(
                spec: NexusGenesis.spec,
                children: ["Payments": block],
                timestamp: timestamp,
                target: UInt256.max,
                fetcher: source
            )
            let carrier = try XCTUnwrap(BlockBuilder.mine(
                block: carrierCandidate,
                target: block.target,
                maxAttempts: 1_024
            ))
            let carrierHeader = try BlockHeader(node: carrier)
            await source.store(entries: [
                carrierHeader.rawCID: try XCTUnwrap(carrier.toData()),
            ])
            let proof = try await ChildBlockProof.generate(
                rootHeader: carrierHeader,
                childDirectory: "Payments",
                fetcher: source
            )
            return (
                AuthenticatedChildPackage(
                    package: ChildValidationPackage(
                        proof: proof,
                        parentGenesisLink: nil
                    )
                ),
                carrierHeader.rawCID
            )
        }

        let (predecessorPackage, _) = try await package(
            for: predecessor,
            header: predecessorHeader,
            timestamp: 10
        )
        let (orphanPackageA, orphanCarrierA) = try await package(
            for: orphan,
            header: orphanHeader,
            timestamp: 11
        )
        let (orphanPackageB, orphanCarrierB) = try await package(
            for: orphan,
            header: orphanHeader,
            timestamp: 12
        )
        XCTAssertNotEqual(orphanCarrierA, orphanCarrierB)
        let detached = try await process!.admit(
            orphanHeader,
            authenticatedChildPackage: orphanPackageA
        )
        guard case .acceptedSide = detached.decision else {
            return XCTFail("expected accepted child orphan, got \(detached.decision)")
        }
        XCTAssertEqual(detached.sameChainPredecessor, SameChainPredecessorRequirement(
            descendantCID: orphanHeader.rawCID,
            predecessorCID: predecessorHeader.rawCID
        ))
        XCTAssertEqual(
            detached.parentCarrierLink?.rootCID,
            orphanCarrierA
        )
        let secondRoot = try await process!.admit(
            orphanHeader,
            authenticatedChildPackage: orphanPackageB
        )
        XCTAssertEqual(secondRoot.sameChainPredecessor, detached.sameChainPredecessor)
        XCTAssertEqual(
            secondRoot.parentCarrierLink?.rootCID,
            orphanCarrierB
        )

        let remoteContent = NetworkTestContentStore()
        try await predecessorHeader.storeBlock(
            fetcher: process!,
            storer: remoteContent
        )
        process = nil

        let runtime = try NodeNetworkRuntime(configuration: configuration)
        let recovered = try await ChainProcess.open(
            configuration: configuration
        )
        let admissions = NetworkEventRecorder()
        let handlers = NodeNetworkHandlers(admission: { [weak recovered] admission in
            guard let recovered else { throw CancellationError() }
            let outcome = try await recovered.admit(
                admission.header,
                authenticatedChildPackage: admission.header.rawCID == predecessorHeader.rawCID
                    ? predecessorPackage
                    : admission.authenticatedChildPackage,
                remoteSource: admission.contentSource
            )
            await admissions.append(admission.header.rawCID)
            return outcome
        })
        let client = Ivy(config: IvyConfig(
            signingKey: signingKey(0x99),
            listenPort: 0,
            stunServers: [],
            mode: .overlay
        ))
        await client.setContentSource(remoteContent)
        let runtimePeer = PeerID(publicKey: configuration.processPublicKey)
        do {
            try await runtime.start(process: recovered, handlers: handlers)
            try await connectAndHello(
                client,
                peerID: runtimePeer,
                endpoint: PeerEndpoint(
                    publicKey: configuration.processPublicKey,
                    host: "127.0.0.1",
                    port: overlayPort
                ),
                hello: try ChainHello(
                    nexusGenesisCID: configuration.nexusGenesisCID,
                    chainPath: configuration.chainPath
                ).encode()
            )
            guard case .enqueued = await client.sendMessage(
                to: runtimePeer,
                topic: NodeNetworkTopic.blockAnnouncement,
                payload: try BlockAnnouncementMessage(
                    blockCID: predecessorHeader.rawCID
                ).encoded()
            ) else {
                throw NetworkTestError.failedSend
            }
            try await waitForEventCount(
                3,
                in: admissions,
                phase: "durable child orphan retry",
                attempts: 2_000
            )

            let admittedCIDs = await admissions.snapshot()
            XCTAssertEqual(admittedCIDs, [
                predecessorHeader.rawCID,
                orphanHeader.rawCID,
                orphanHeader.rawCID,
            ])
            let status = await recovered.status()
            XCTAssertEqual(status.tipCID, orphanHeader.rawCID)
            let promotedA = try await recovered.issuedParentCarrierLink(
                carrierCID: orphanHeader.rawCID,
                rootCID: orphanCarrierA
            )
            let promotedB = try await recovered.issuedParentCarrierLink(
                carrierCID: orphanHeader.rawCID,
                rootCID: orphanCarrierB
            )
            XCTAssertNotNil(promotedA)
            XCTAssertNotNil(promotedB)
            let unresolved = await recovered.unresolvedSameChainPredecessors()
            XCTAssertTrue(unresolved.isEmpty)
        } catch {
            await client.stop()
            await runtime.stop()
            throw error
        }
        await client.stop()
        await runtime.stop()
    }

    func testConfiguredParentReconnectsWhenFirstHierarchyHelloIsWithheld()
        async throws {
        let fixture = try await hierarchyRetryFixture(
            keyByte: 0x61,
            summary: nil,
            withholdFirstHello: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fixture.storage)
        }

        do {
            try await fixture.parent.start()
            try await fixture.runtime.start(
                process: fixture.process,
                handlers: duplicateNetworkHandlers()
            )
            for _ in 0..<400 {
                let trace = await fixture.recorder.sessionTrace()
                if trace.hellos.count >= 2, !trace.indexes.isEmpty { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let trace = await fixture.recorder.sessionTrace()
            XCTAssertGreaterThanOrEqual(trace.hellos.count, 2)
            let firstHello = try XCTUnwrap(trace.hellos.first)
            let secondHello = try XCTUnwrap(trace.hellos.dropFirst().first)
            let firstIndex = try XCTUnwrap(trace.indexes.first)
            XCTAssertNotEqual(firstHello, secondHello)
            XCTAssertFalse(trace.indexes.contains(firstHello))
            XCTAssertTrue(Set(trace.hellos.dropFirst()).contains(firstIndex))
        } catch {
            await fixture.parent.stop()
            await fixture.runtime.stop()
            throw error
        }
        await fixture.parent.stop()
        await fixture.runtime.stop()
    }

    /// The validate walk's evidence request suspends on the parent's answer.
    /// When the parent session drops while it is in flight, the request must
    /// resolve nil (the walk parks and retries) — never stay suspended: an
    /// unresumed continuation would leave the walk worker alive and every
    /// later reserve a no-op for the process lifetime.
    func testValidateEvidenceRequestResolvesNilWhenTheParentSessionDrops()
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
                handlers: duplicateNetworkHandlers()
            )
            try await waitUntil("parent role granted") {
                !(await fixture.recorder.sessionTrace()).hellos.isEmpty
            }
            // In flight: the parent never answers.
            let resolved = Task { [runtime = fixture.runtime] in
                await runtime.resolveValidateEvidenceForTesting(
                    for: testCID("child-block"),
                    requirement: .parentStateContinuity(
                        parentPath: ["Nexus"],
                        fromStateCID: testCID("from-state"),
                        toStateCID: testCID("to-state")
                    ),
                    package: package
                )
            }
            try await waitUntil("request sent to the parent") {
                await fixture.recorder.parentFactRequestCount() >= 1
            }
            await fixture.parent.stop()

            // Bounded: a leaked continuation never returns.
            let outcome = await withTaskGroup(
                of: Bool.self, returning: Bool.self
            ) { group in
                group.addTask { await resolved.value == nil }
                group.addTask {
                    try? await Task.sleep(for: .seconds(10))
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
                handlers: duplicateNetworkHandlers()
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

    func testRejectedEvidenceHintRecyclesSessionAndReconnectIndexRepairs()
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
                handlers: duplicateNetworkHandlers()
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
            for _ in 0..<300 {
                if !(await fixture.child.connectedPeers).contains(parentID) {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            let connectedAfterRejection = await fixture.child.connectedPeers
            XCTAssertFalse(connectedAfterRejection.contains(parentID))
            let rejected = await fixture.recorder.snapshot()
            XCTAssertEqual(rejected.helloSessions.count, 1)
            XCTAssertEqual(rejected.indexEntries, [[]])
            XCTAssertTrue(rejected.available.isEmpty)

            hierarchyTally.resetPeer(childID)
            try await waitForEvidenceIndexes(fixture, count: 2)

            let repaired = await fixture.recorder.snapshot()
            XCTAssertEqual(repaired.helloSessions.count, 2)
            XCTAssertNotEqual(
                repaired.helloSessions[0],
                repaired.helloSessions[1]
            )
            XCTAssertEqual(repaired.indexEntries.count, 2)
            XCTAssertTrue(repaired.indexEntries.first?.isEmpty == true)
            XCTAssertEqual(repaired.indexEntries.last?.count, 1)
            XCTAssertEqual(repaired.indexEntries.last?.first?.childCID, fixture.childCID)
            XCTAssertEqual(repaired.indexEntries.last?.first?.rootCID, fixture.carrierCID)
            XCTAssertTrue(repaired.indexEntries.last?.first.map {
                CIDIdentity.isCanonical($0.attachmentCID)
            } ?? false)
            XCTAssertTrue(repaired.available.isEmpty)
            let pending = try await fixture.process.pendingChildProofCarrierCIDs()
            let status = await fixture.process.status()
            XCTAssertTrue(pending.isEmpty)
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

    func testProvisionalVolumeRegistryRetainsUntilLastLease() async throws {
        let volume = try await transactionVolume(
            unsignedTransaction(path: [])
        )
        let registry = ProvisionalVolumeRegistry()

        let firstLease = await registry.retain(volume, generation: 7)
        let secondLease = await registry.retain(volume, generation: 7)
        XCTAssertTrue(firstLease)
        XCTAssertTrue(secondLease)
        await registry.release(volume.root, generation: 7)
        let retained = await registry.volume(volume.root, generation: 7)
        XCTAssertNotNil(retained)

        await registry.release(volume.root, generation: 7)
        let released = await registry.volume(volume.root, generation: 7)
        XCTAssertNil(released)

        let nextGeneration = await registry.retain(volume, generation: 8)
        XCTAssertTrue(nextGeneration)
        let stale = await registry.volume(volume.root, generation: 7)
        let current = await registry.volume(volume.root, generation: 8)
        XCTAssertNil(stale)
        XCTAssertNotNil(current)
    }

    func testProvisionalVolumeRegistryRejectsRetainRacingReset() async throws {
        let volume = try await transactionVolume(unsignedTransaction(path: []))
        let broker = BlockingProvisionalBroker()
        let registry = ProvisionalVolumeRegistry(broker: broker)
        let retain = Task { await registry.retain(volume, generation: 7) }

        await broker.waitUntilStoreStarts()
        await registry.removeAll()
        await broker.releaseStore()

        let retained = await retain.value
        let registered = await registry.volume(volume.root, generation: 7)
        let stored = await broker.hasVolume(root: volume.root)
        XCTAssertFalse(retained)
        XCTAssertNil(registered)
        XCTAssertFalse(stored)
    }

    func testContextualCandidateReadsOnlyExactRequestingParentSession()
        async throws
    {
        let descendantKey = signingKey(0x91)
        let fixture = try await provisionalRootFixture(keyByte: 0x8f)
        let childHandlers = NodeNetworkHandlers(
            childCandidateBuilder: { context, parentSource in
                let parentCID = try BlockHeader(
                    node: context.parentCarrier
                ).rawCID
                let fetched = await parentSource.fetch([parentCID])
                guard fetched[parentCID] == context.parentCarrier.toData() else {
                    throw NetworkTestError.failedPhase(
                        "exact parent carrier content"
                    )
                }
                return fixture.candidate
            },
            candidateReservations: { _ in true },
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
                handlers: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                handlers: childHandlers
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

            try await waitForChildCandidate(fixture)
            let candidates = await fixture.parentRuntime.directChildCandidates(
                fixture.context
            )
            let descendantVolumeRequests = await probe.volumeRequestCount()
            XCTAssertEqual(candidates.count, 1)
            XCTAssertEqual(descendantVolumeRequests, 0)
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

    func testInvalidParentEvidenceCannotPinCandidateOrOvertakeReservation()
        async throws
    {
        let fixture = try await provisionalRootFixture(keyByte: 0x93)
        let childTip = try await fixture.childProcess.canonicalTipBlock()
        let candidateBlock = try await BlockBuilder.buildBlock(
            previous: childTip,
            timestamp: childTip.timestamp + 1,
            nonce: 77,
            fetcher: fixture.childProcess
        )
        let candidateHeader = try BlockHeader(node: candidateBlock)
        let reservations = NetworkEventRecorder()
        let childHandlers = NodeNetworkHandlers(
            candidateReservations: { update in
                await reservations.append("called")
                return (try? await fixture.childProcess
                    .replaceIssuedContextualCandidates(
                        Set(update.candidateCIDs),
                        handoffs: Set(update.handoffCIDs),
                        capacity: 16
                    )) == true
            },
            admission: { _ in throw CancellationError() }
        )

        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess,
                handlers: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                handlers: childHandlers
            )

            for _ in 0..<250 {
                if !(await reservations.snapshot()).isEmpty { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let reservationBaseline = await reservations.snapshot().count
            guard reservationBaseline > 0 else {
                throw NetworkTestError.failedPhase(
                    "initial reservation reconciliation"
                )
            }
            try await fixture.childProcess.storeContextualCandidate(
                candidateHeader,
                fetcher: fixture.childProcess,
                capacity: 16
            )
            let candidateCID = candidateHeader.rawCID
            let retainedBeforeEvidence = try await fixture.childProcess
                .contextualCandidateChildren(candidateCIDs: [candidateCID])
            XCTAssertNotNil(retainedBeforeEvidence)

            let childPeer = PeerID(
                publicKey: fixture.childConfiguration.processPublicKey
            )
            let invalidEvidence = try ChildEvidenceAvailableMessage(
                childPath: fixture.childConfiguration.chainPath,
                sourceID: testEvidenceSourceID,
                ordinal: 1,
                childCID: candidateCID,
                rootCID: testCID("invalid-parent-evidence-root"),
                attachmentCID: testCID(
                    "invalid-parent-evidence-attachment"
                )
            ).encoded()
            guard case .enqueued =
                    await fixture.parentRuntime.hierarchy.sendMessage(
                        to: childPeer,
                        topic: NodeNetworkTopic.childEvidenceAvailable,
                        payload: invalidEvidence
                    ) else {
                throw NetworkTestError.failedPhase(
                    "invalid evidence advertisement"
                )
            }
            try await Task.sleep(for: .milliseconds(250))
            let reservationCount = await reservations.snapshot().count
            XCTAssertEqual(reservationCount, reservationBaseline)
            let replaced = try await fixture.childProcess
                .replaceIssuedContextualCandidates([], capacity: 16)
            XCTAssertTrue(replaced)
            let retainedAfterInvalidEvidence = try await fixture.childProcess
                .contextualCandidateChildren(candidateCIDs: [candidateCID])
            XCTAssertNil(retainedAfterInvalidEvidence)
        } catch {
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
            throw error
        }
        await fixture.childRuntime.stop()
        await fixture.parentRuntime.stop()
    }

    func testExactParentSessionRunsOnlyOneReservationHandler() async throws {
        let fixture = try await provisionalRootFixture(keyByte: 0x95)
        let reservationGate = CandidateReservationAckGate { _ in true }
        let childHandlers = NodeNetworkHandlers(
            candidateReservations: { update in
                await reservationGate.handle(update)
            },
            admission: { _ in throw CancellationError() }
        )

        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess,
                handlers: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                handlers: childHandlers
            )
            for _ in 0..<250 {
                if !(await reservationGate.snapshot()).isEmpty { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let baseline = await reservationGate.snapshot().count
            guard baseline > 0 else {
                throw NetworkTestError.failedPhase(
                    "initial reservation reconciliation"
                )
            }
            let childPeer = PeerID(
                publicKey: fixture.childConfiguration.processPublicKey
            )
            let candidateCID = testCID("single-flight-reservation")
            for requestID in [UInt64(91), UInt64(92)] {
                let payload = try ChildCandidateReservationRequestMessage(
                    requestID: requestID,
                    childPath: fixture.childConfiguration.chainPath,
                    candidateCIDs: [candidateCID]
                ).encoded()
                guard case .enqueued =
                        await fixture.parentRuntime.hierarchy.sendMessage(
                            to: childPeer,
                            topic: NodeNetworkTopic
                                .childCandidateReservationRequest,
                            payload: payload
                        ) else {
                    throw NetworkTestError.failedPhase(
                        "reservation request \(requestID)"
                    )
                }
                if requestID == 91 {
                    for _ in 0..<250 {
                        if await reservationGate.snapshot().count > baseline {
                            break
                        }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                }
            }

            let snapshots = await reservationGate.snapshot()
            XCTAssertEqual(
                snapshots.filter { $0 == [candidateCID] }.count,
                1
            )
        } catch {
            await reservationGate.release()
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
            throw error
        }
        await reservationGate.release()
        await fixture.childRuntime.stop()
        await fixture.parentRuntime.stop()
    }

    func testParentTemplateWaitsForDurableChildCandidateReservationAck()
        async throws
    {
        let fixture = try await provisionalRootFixture(keyByte: 0x92)
        let childService = networkService(
            process: fixture.childProcess,
            runtime: fixture.childRuntime
        )
        let reservationGate = CandidateReservationAckGate {
            [weak childService] update in
            guard let childService else { return false }
            return await childService.replaceIssuedCandidateReservations(
                update
            )
        }
        await reservationGate.holdNext([])
        let completion = NetworkEventRecorder()
        let parentService = ChainService(
            process: fixture.parentProcess,
            childCandidateProvider: { [weak runtime = fixture.parentRuntime] context in
                guard let runtime else { return [] }
                return await runtime.directChildCandidates(context)
            },
            childCandidateReservationReconciler: {
                [weak runtime = fixture.parentRuntime] update in
                guard let runtime else {
                    return update.reservations.isEmpty
                        && update.handoffs.isEmpty
                }
                return await runtime.reconcileChildCandidateReservations(
                    update
                )
            },
            childProofPublisher: {
                [weak runtime = fixture.parentRuntime] publication in
                guard let runtime else { return }
                _ = try await runtime.publishChildProof(
                    publication.proof,
                    childDirectory: publication.directory,
                    childCID: publication.childCID
                )
            },
            acceptedBlockPublisher: { _ in }
        )
        let childHandlers = NodeNetworkHandlers(
            childCandidateBuilder: { [weak childService] context, parentSource in
                guard let childService else { return nil }
                return try await childService.miningCandidate(
                    parentCarrier: context.parentCarrier,
                    parentContentSource: parentSource,
                    rewards: context.rewards
                )
            },
            candidateReservations: { [weak reservationGate] update in
                guard let reservationGate else { return false }
                return await reservationGate.handle(update)
            },
            admission: { _ in throw CancellationError() }
        )

        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess,
                handlers: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                handlers: childHandlers
            )
            for _ in 0..<250 {
                if await childService.status().phase == .active { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let childPhase = await childService.status().phase
            XCTAssertEqual(childPhase, .active)

            for _ in 0..<250 {
                if await reservationGate.snapshot().contains([]) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let initialSnapshots = await reservationGate.snapshot()
            XCTAssertTrue(initialSnapshots.contains([]))

            let unavailable = await fixture.parentRuntime
                .directChildCandidates(fixture.context)
            XCTAssertTrue(unavailable.isEmpty)
            let snapshotsWhileInitialAckBlocked =
                await reservationGate.snapshot()
            XCTAssertFalse(snapshotsWhileInitialAckBlocked.contains {
                !$0.isEmpty
            })

            await reservationGate.release()
            try await waitForChildCandidate(fixture)
            await reservationGate.holdNextNonempty()

            let mining = Task {
                let response = try await parentService.miningTemplate(
                    MiningTemplateRequest()
                )
                await completion.append("returned")
                return response
            }
            for _ in 0..<250 {
                if await reservationGate.snapshot().contains(where: {
                    !$0.isEmpty
                }) {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            let nonempty = await reservationGate.snapshot().filter {
                !$0.isEmpty
            }
            XCTAssertEqual(nonempty.count, 1)
            let reservation = try XCTUnwrap(nonempty.first)
            XCTAssertEqual(reservation.count, 1)
            await Task.yield()
            let completionBeforeAck = await completion.snapshot()
            XCTAssertTrue(completionBeforeAck.isEmpty)

            await reservationGate.release()
            let response = try await mining.value
            let reservationRejections =
                await reservationGate.rejectionSnapshot()
            XCTAssertEqual(reservationRejections, [])
            let completionAfterAck = await completion.snapshot()
            XCTAssertEqual(completionAfterAck, ["returned"])
            let children = try XCTUnwrap(response.block.children.node)
            let childValues = try children.allKeysAndValues()
            XCTAssertEqual(children.count, 1)
            XCTAssertEqual(childValues.keys.sorted(), ["Payments"])
            let reservationAfterAck = await reservationGate.snapshot().last
            XCTAssertEqual(reservationAfterAck, reservation)
            let childCID = try XCTUnwrap(childValues["Payments"]?.rawCID)
            XCTAssertEqual(reservation, [childCID])

            let retentionScope = [
                fixture.childConfiguration.nexusGenesisCID,
                fixture.childConfiguration.address.key,
            ].joined(separator: ":")
            let store = try testNodeStore(
                databasePath: fixture.childConfiguration.storagePath
                    .appendingPathComponent("state.db"),
                nexusGenesisCID: fixture.childConfiguration.nexusGenesisCID,
                chainPath: fixture.childConfiguration.chainPath,
                contextualCandidateOwner:
                    retentionScope + ":contextual-candidates"
            )
            let issuedCandidateCIDs =
                try await store.issuedContextualCandidateCIDs()
            XCTAssertEqual(
                issuedCandidateCIDs,
                [childCID]
            )

            let snapshotsBeforeSubmission =
                await reservationGate.snapshot().count
            await reservationGate.holdNext([])
            let submissionCompletion = NetworkEventRecorder()
            let submissionTask = Task {
                let result = try await parentService.submitWork(
                    SubmitWorkRequest(workID: response.workID, nonce: 0)
                )
                await submissionCompletion.append("returned")
                return result
            }
            for _ in 0..<250 {
                let snapshots = await reservationGate.snapshot()
                if snapshots.count > snapshotsBeforeSubmission,
                   snapshots.last?.isEmpty == true {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            for _ in 0..<250 {
                if await submissionCompletion.snapshot() == ["returned"] {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            let completionWhileReleaseBlocked =
                await submissionCompletion.snapshot()
            XCTAssertEqual(
                completionWhileReleaseBlocked,
                ["returned"],
                "a child withholding a release ACK must not stall its parent"
            )
            // Mining acknowledges durable parent-side proof construction, not
            // live delivery. The release update itself must transfer the CID
            // into durable handoff ownership before discarding the speculative
            // reservation.
            for _ in 0..<250 {
                if try await !store.parentEvidenceInbox().isEmpty {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            let deliveredEvidence = try await store.parentEvidenceInbox()
            XCTAssertFalse(deliveredEvidence.isEmpty)
            await reservationGate.release()
            let submission = try await submissionTask.value
            XCTAssertTrue(submission.accepted)
            let snapshotsAfterSubmission =
                await reservationGate.snapshot()
            let handoffsAfterSubmission =
                await reservationGate.handoffSnapshot()
            XCTAssertGreaterThan(
                snapshotsAfterSubmission.count,
                snapshotsBeforeSubmission
            )
            XCTAssertEqual(snapshotsAfterSubmission.last, [])
            XCTAssertTrue(
                handoffsAfterSubmission.contains([childCID]),
                "missing committed-candidate handoff: \(handoffsAfterSubmission)"
            )
            for _ in 0..<250 {
                if try await store.issuedContextualCandidateCIDs().isEmpty {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            let releasedCandidateCIDs = try await store
                .issuedContextualCandidateCIDs()
            XCTAssertTrue(releasedCandidateCIDs.isEmpty)

            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
            let eviction = try DiskBroker(
                path: fixture.childConfiguration.storagePath
                    .appendingPathComponent("volumes.db").path,
                evictUnpinnedGraceSeconds: 0
            )
            _ = try await eviction.evictUnpinned()
            let retainedAfterReleaseAndGC = await eviction.fetchVolumeLocal(
                root: childCID
            )
            XCTAssertNotNil(retainedAfterReleaseAndGC)
        } catch {
            await reservationGate.release()
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
            throw error
        }
        await reservationGate.release()
        await fixture.childRuntime.stop()
        await fixture.parentRuntime.stop()
    }

    func testReconnectReservationCannotOverwriteNewerExactSet()
        async throws
    {
        let fixture = try await provisionalRootFixture(keyByte: 0x94)
        let issued = IssuedCandidateSet()
        let reservationGate = CandidateReservationAckGate {
            [weak issued] update in
            guard let issued else { return false }
            return await issued.replace(with: update.candidateCIDs)
        }
        await reservationGate.release()
        let childHandlers = NodeNetworkHandlers(
            candidateReservations: { [weak reservationGate] update in
                guard let reservationGate else { return false }
                return await reservationGate.handle(update)
            },
            admission: { _ in throw CancellationError() }
        )
        let firstCID = testCID("reservation-race-first")
        let secondCID = testCID("reservation-race-second")
        let childPeerKey = try PeerKey(
            fixture.childConfiguration.processPublicKey
        )
        let first = ChildCandidateReservationReference(
            peerKey: childPeerKey,
            candidateCID: firstCID
        )
        let newer = [
            first,
            ChildCandidateReservationReference(
                peerKey: childPeerKey,
                candidateCID: secondCID
            ),
        ]

        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess,
                handlers: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                handlers: childHandlers
            )
            var initiallyApplied = false
            for _ in 0..<250 {
                if await fixture.parentRuntime
                    .reconcileChildCandidateReservations(
                        ChildCandidateReservationUpdate(reservations: [first])
                    ) {
                    initiallyApplied = true
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(initiallyApplied)
            let initiallyIssued = await issued.snapshot()
            XCTAssertEqual(initiallyIssued, [firstCID])

            await fixture.childRuntime.stop()
            await reservationGate.holdNext([firstCID])
            let reconnectStart = await reservationGate.snapshot().count
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                handlers: childHandlers
            )
            for _ in 0..<250 {
                let snapshots = await reservationGate.snapshot()
                if snapshots.count > reconnectStart,
                   Set(snapshots.last ?? []) == [firstCID] {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            let heldReconnect = await reservationGate.snapshot()
            XCTAssertGreaterThan(heldReconnect.count, reconnectStart)
            XCTAssertEqual(Set(heldReconnect.last ?? []), [firstCID])

            let completion = NetworkEventRecorder()
            let reconciliation = Task {
                let accepted = await fixture.parentRuntime
                    .reconcileChildCandidateReservations(
                        ChildCandidateReservationUpdate(reservations: newer)
                    )
                await completion.append(accepted ? "accepted" : "rejected")
                return accepted
            }
            try await Task.sleep(for: .milliseconds(500))
            let completionWhileHelloHeld = await completion.snapshot()
            XCTAssertTrue(completionWhileHelloHeld.isEmpty)
            let snapshotsWhileHelloHeld =
                await reservationGate.snapshot()
            XCTAssertEqual(
                snapshotsWhileHelloHeld.count,
                heldReconnect.count
            )

            await reservationGate.release()
            let accepted = await reconciliation.value
            XCTAssertTrue(accepted)
            let completed = await completion.snapshot()
            XCTAssertEqual(completed, ["accepted"])
            let finallyIssued = await issued.snapshot()
            XCTAssertEqual(
                finallyIssued,
                [firstCID, secondCID]
            )
            let finalReservationSnapshot =
                await reservationGate.snapshot().last
            XCTAssertEqual(
                Set(finalReservationSnapshot ?? []),
                [firstCID, secondCID]
            )
        } catch {
            await reservationGate.release()
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
            throw error
        }
        await reservationGate.release()
        await fixture.childRuntime.stop()
        await fixture.parentRuntime.stop()
    }

    func testConcurrentExactReservationReconciliationIsLinearizable()
        async throws
    {
        let fixture = try await provisionalRootFixture(keyByte: 0x9a)
        let applied = IssuedCandidateSet()
        let reservationGate = CandidateReservationAckGate {
            [weak applied] update in
            guard let applied else { return false }
            return await applied.replace(with: update.candidateCIDs)
        }
        await reservationGate.release()
        let childHandlers = NodeNetworkHandlers(
            candidateReservations: { [weak reservationGate] update in
                guard let reservationGate else { return false }
                return await reservationGate.handle(update)
            },
            admission: { _ in throw CancellationError() }
        )
        let childPeerKey = try PeerKey(
            fixture.childConfiguration.processPublicKey
        )
        let first = ChildCandidateReservationReference(
            peerKey: childPeerKey,
            candidateCID: testCID("reservation-linear-first")
        )
        let expanded = [
            first,
            ChildCandidateReservationReference(
                peerKey: childPeerKey,
                candidateCID: testCID(
                    "reservation-linear-second"
                )
            ),
        ]

        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess,
                handlers: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                handlers: childHandlers
            )
            var initiallyApplied = false
            for _ in 0..<250 {
                if await fixture.parentRuntime
                    .reconcileChildCandidateReservations(
                        ChildCandidateReservationUpdate(reservations: [first])
                    ) {
                    initiallyApplied = true
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(initiallyApplied)

            await reservationGate.holdNext(
                Set(expanded.map(\.candidateCID))
            )
            let expandedTask = Task {
                await fixture.parentRuntime
                    .reconcileChildCandidateReservations(
                        ChildCandidateReservationUpdate(reservations: expanded)
                    )
            }
            for _ in 0..<250 {
                if Set(await reservationGate.snapshot().last ?? [])
                    == Set(expanded.map(\.candidateCID)) {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            let heldExpanded = await reservationGate.snapshot().last
            XCTAssertEqual(
                Set(heldExpanded ?? []),
                Set(expanded.map(\.candidateCID))
            )

            let restored = NetworkEventRecorder()
            let restoreTask = Task {
                let accepted = await fixture.parentRuntime
                    .reconcileChildCandidateReservations(
                        ChildCandidateReservationUpdate(reservations: [first])
                    )
                await restored.append(accepted ? "accepted" : "rejected")
                return accepted
            }
            try await Task.sleep(for: .milliseconds(200))
            let restoredWhileHeld = await restored.snapshot()
            XCTAssertTrue(restoredWhileHeld.isEmpty)

            await reservationGate.release()
            let expandedAccepted = await expandedTask.value
            let restoreAccepted = await restoreTask.value
            XCTAssertTrue(expandedAccepted)
            XCTAssertTrue(restoreAccepted)
            for _ in 0..<250 {
                if Set(await reservationGate.snapshot().last ?? [])
                    == [first.candidateCID],
                   await applied.snapshot() == [first.candidateCID] {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            let finalReservations = await reservationGate.snapshot().last
            let finalApplied = await applied.snapshot()
            let restoreCompletions = await restored.snapshot()
            XCTAssertEqual(
                Set(finalReservations ?? []),
                [first.candidateCID]
            )
            XCTAssertEqual(finalApplied, [first.candidateCID])
            XCTAssertEqual(restoreCompletions, ["accepted"])
        } catch {
            await reservationGate.release()
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
            throw error
        }
        await reservationGate.release()
        await fixture.childRuntime.stop()
        await fixture.parentRuntime.stop()
    }

    func testOldSessionReservationAckCannotSatisfyReplacementSession()
        async throws
    {
        let fixture = try await provisionalRootFixture(keyByte: 0x96)
        let applied = IssuedCandidateSet()
        let reservationGate = CandidateReservationAckGate {
            [weak applied] update in
            guard let applied else { return false }
            return await applied.replace(with: update.candidateCIDs)
        }
        await reservationGate.release()
        let childHandlers = NodeNetworkHandlers(
            candidateReservations: { [weak reservationGate] update in
                guard let reservationGate else { return false }
                return await reservationGate.handle(update)
            },
            admission: { _ in throw CancellationError() }
        )
        let childPeerKey = try PeerKey(
            fixture.childConfiguration.processPublicKey
        )
        let first = ChildCandidateReservationReference(
            peerKey: childPeerKey,
            candidateCID: testCID("reservation-session-first")
        )
        let stale = [
            first,
            ChildCandidateReservationReference(
                peerKey: childPeerKey,
                candidateCID: testCID("reservation-session-stale")
            ),
        ]
        let replacement = [
            first,
            ChildCandidateReservationReference(
                peerKey: childPeerKey,
                candidateCID: testCID("reservation-session-replacement")
            ),
        ]

        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess,
                handlers: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                handlers: childHandlers
            )
            var initiallyApplied = false
            for _ in 0..<250 {
                if await fixture.parentRuntime
                    .reconcileChildCandidateReservations(
                        ChildCandidateReservationUpdate(reservations: [first])
                    ) {
                    initiallyApplied = true
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(initiallyApplied)

            await reservationGate.holdNext(
                Set(stale.map(\.candidateCID))
            )
            let staleReconciliation = Task {
                await fixture.parentRuntime
                    .reconcileChildCandidateReservations(
                        ChildCandidateReservationUpdate(reservations: stale)
                    )
            }
            for _ in 0..<250 {
                if Set(await reservationGate.snapshot().last ?? [])
                    == Set(stale.map(\.candidateCID)) {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            let heldStaleSnapshot = await reservationGate.snapshot().last
            XCTAssertEqual(
                Set(heldStaleSnapshot ?? []),
                Set(stale.map(\.candidateCID))
            )

            // Replacing the authenticated child session must fail the suspended
            // request locally. Releasing its handler later may attempt an old
            // response, but that response cannot satisfy any replacement-session
            // reservation.
            await fixture.childRuntime.stop()
            let staleAccepted = await staleReconciliation.value
            XCTAssertFalse(staleAccepted)
            let replacementStart = await reservationGate.snapshot().count
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                handlers: childHandlers
            )
            for _ in 0..<250 {
                let snapshots = await reservationGate.snapshot()
                if snapshots.count > replacementStart,
                   Set(snapshots.last ?? []) == [first.candidateCID] {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            let reconnectedSnapshot = await reservationGate.snapshot().last
            XCTAssertEqual(Set(reconnectedSnapshot ?? []), [first.candidateCID])

            let replacementAccepted = await fixture.parentRuntime
                .reconcileChildCandidateReservations(
                    ChildCandidateReservationUpdate(reservations: replacement)
                )
            XCTAssertTrue(replacementAccepted)
            let replacementSnapshot = await reservationGate.snapshot().last
            XCTAssertEqual(
                Set(replacementSnapshot ?? []),
                Set(replacement.map(\.candidateCID))
            )

            await reservationGate.release()
            for _ in 0..<250 {
                if await reservationGate.snapshot().count >= replacementStart + 3 {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }

            let final = replacement + [
                ChildCandidateReservationReference(
                    peerKey: childPeerKey,
                    candidateCID: testCID("reservation-session-final")
                ),
            ]
            let finalAccepted = await fixture.parentRuntime
                .reconcileChildCandidateReservations(
                    ChildCandidateReservationUpdate(reservations: final)
                )
            XCTAssertTrue(finalAccepted)
            let finalSnapshot = await reservationGate.snapshot().last
            XCTAssertEqual(
                Set(finalSnapshot ?? []),
                Set(final.map(\.candidateCID))
            )
        } catch {
            await reservationGate.release()
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
            throw error
        }
        await reservationGate.release()
        await fixture.childRuntime.stop()
        await fixture.parentRuntime.stop()
    }

    func testRealNetworkRuntimeRestartsBothPlanesWithAtomicHandlers() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-network-runtime-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storage,
            privateKeyHex: String(repeating: "5b", count: 32)
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
        let handlers = inertNetworkHandlers()

        do {
            // `start` requires the complete generation value; there is no
            // running state in which admission can be installed or replaced.
            do {
                try await runtime.canonicalTipDidChange()
                XCTFail("a stopped runtime must reject canonical-tip changes")
            } catch {
                XCTAssertEqual(error as? NodeNetworkRuntimeError, .notRunning)
            }

            var startOutcomes: [NetworkRuntimeStartOutcome] = []
            await withTaskGroup(of: NetworkRuntimeStartOutcome.self) { group in
                for _ in 0..<2 {
                    group.addTask {
                        do {
                            try await runtime.start(
                                process: process,
                                handlers: handlers
                            )
                            return .started
                        } catch let error as NodeNetworkRuntimeError {
                            return .failed(error)
                        } catch {
                            return .unexpected(String(describing: error))
                        }
                    }
                }
                for await outcome in group { startOutcomes.append(outcome) }
            }
            XCTAssertEqual(startOutcomes.filter { $0 == .started }.count, 1)
            XCTAssertEqual(
                startOutcomes.filter { $0 == .failed(.alreadyRunning) }.count,
                1
            )
            try await runtime.canonicalTipDidChange()

            await runtime.stop()
            do {
                try await runtime.canonicalTipDidChange()
                XCTFail("a stopped runtime must reject canonical-tip changes")
            } catch {
                XCTAssertEqual(error as? NodeNetworkRuntimeError, .notRunning)
            }
            await runtime.stop()

            try await runtime.start(process: process, handlers: handlers)
            try await runtime.canonicalTipDidChange()
            await runtime.stop()

            let starting = await runtime.enqueueStart(
                process: process,
                handlers: handlers
            )
            await runtime.stop()
            try await starting.value
            do {
                try await runtime.canonicalTipDidChange()
                XCTFail("stop queued during start must leave the runtime stopped")
            } catch {
                XCTAssertEqual(error as? NodeNetworkRuntimeError, .notRunning)
            }
        } catch {
            await runtime.stop()
            throw error
        }
    }

    private func provisionalRootFixture(
        keyByte: UInt8
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
        let carrierAdmission = try await parentProcess.admit(carrierHeader)
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
        for _ in 0..<250 {
            if await fixture.parentRuntime.directChildCandidates(fixture.context).count == 1 {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NetworkTestError.failedPhase("direct child candidate session")
    }

    private func waitForBuilds(
        _ gate: CandidateBuildGate,
        count: Int
    ) async throws {
        for _ in 0..<250 {
            if await gate.enteredCount() >= count { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        let entered = await gate.enteredCount()
        throw NetworkTestError.failedPhase(
            "provisional child candidate build \(count), entered \(entered)"
        )
    }


    private func envelope(parentPath: [String]) throws -> ChildValidationPackageEnvelope {
        try ChildValidationPackageEnvelope(ChildValidationPackage(
            proof: proof()
        ))
    }

    private func proof() -> ChildBlockProof {
        ChildBlockProof(
            rootCID: "proof-root",
            directoryPath: ["Payments"],
            entries: []
        )
    }

    // MARK: frontier pull — the header graph is its leaves plus parent links

    /// The frontier (accepted-leaves) request is sent once per session, at
    /// the live edge: triggered by the peer's tip announcement — never by the
    /// hello alone, which carries no peer height — and evaluated even when we
    /// already HOLD the announced block (holding the peer's tip is being at
    /// its edge). A later at-edge announcement in the same session pulls
    /// nothing more.
    func testFrontierIsPulledOnceAtTheEdgeEvenForAHeldTip() async throws {
        let fixture = try await overlayRuntime(
            keyByte: 0xc1,
            requestTimeout: .seconds(5)
        )
        let topics = TopicRecorder()
        let client = Ivy(config: IvyConfig(
            signingKey: signingKey(0xc2),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        let delegate = TopicRecordingPeer(recorder: topics)
        await client.installTestDelegate(delegate)
        let service = networkService(
            process: fixture.process,
            runtime: fixture.runtime
        )
        let genesisCID = try BlockHeader(
            node: await fixture.process.canonicalTipBlock()
        ).rawCID
        do {
            try await fixture.runtime.start(
                process: fixture.process,
                handlers: transactionServiceHandlers(service)
            )
            try await connectAndHello(
                client,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            try await waitForTopic(NodeNetworkTopic.blockAnnouncement, in: topics)
            // Settle: the hello reply alone knows no peer height.
            try await Task.sleep(for: .milliseconds(300))
            let atHello = await topics.count(
                of: NodeNetworkTopic.acceptedLeavesRequest
            )
            XCTAssertEqual(atHello, 0, "hello must not pull the frontier blindly")

            // The peer's tip is our own genesis: held, and at the edge.
            guard case .enqueued = await client.sendMessage(
                to: fixture.peerID,
                topic: NodeNetworkTopic.blockAnnouncement,
                payload: try BlockAnnouncementMessage(
                    blockCID: genesisCID,
                    height: 0
                ).encoded()
            ) else {
                throw NetworkTestError.failedSend
            }
            try await waitForTopic(
                NodeNetworkTopic.acceptedLeavesRequest,
                in: topics
            )
            // Still at the edge, same session: no second pull.
            guard case .enqueued = await client.sendMessage(
                to: fixture.peerID,
                topic: NodeNetworkTopic.blockAnnouncement,
                payload: try BlockAnnouncementMessage(
                    blockCID: testCID("next"),
                    height: 1
                ).encoded()
            ) else {
                throw NetworkTestError.failedSend
            }
            try await Task.sleep(for: .milliseconds(300))
            let frontierRequests = await topics.count(
                of: NodeNetworkTopic.acceptedLeavesRequest
            )
            let announcements = await topics.count(
                of: NodeNetworkTopic.blockAnnouncement
            )
            XCTAssertEqual(frontierRequests, 1)
            XCTAssertEqual(announcements, 1)
        } catch {
            await client.stop()
            await fixture.runtime.stop()
            throw error
        }
        await client.stop()
        await fixture.runtime.stop()
    }

    /// A joiner far below a peer's tip must NOT pull the frontier at hello:
    /// every leaf would be far above its edge and each leaf's predecessor walk
    /// would descend the whole main chain in competition with range sync. The
    /// gap takes range sync first; the one pull lands once the ACQUIRED tip is
    /// at the edge, and only once.
    func testDeepJoinerPullsTheFrontierOnlyAfterRangeSyncReachesTheEdge()
        async throws
    {
        let fixture = try await overlayRuntime(
            keyByte: 0xcb,
            requestTimeout: .milliseconds(300)
        )
        let depth = 8
        let producer = try await canonicalNetworkProcess()
        let clock = TestBlockClock()
        var parent = try await producer.canonicalTipBlock()
        let genesisCID = try BlockHeader(node: parent).rawCID
        var chain: [String] = []
        var volumes: [SerializedVolume] = []
        for _ in 0..<depth {
            parent = try await acceptNexusBlock(
                on: parent,
                process: producer,
                timestamp: clock.next()
            )
            let cid = try BlockHeader(node: parent).rawCID
            chain.append(cid)
            let volume = await producer.volume(cid)
            volumes.append(try XCTUnwrap(volume))
        }
        let scripted = RangeServingPeer(
            genesisCID: genesisCID,
            chain: chain,
            receiver: fixture.process
        )
        let client = Ivy(config: IvyConfig(
            signingKey: signingKey(0xcc),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        await client.installTestDelegate(scripted)
        await client.setContentSource(RecordingNetworkTestVolumesSource(volumes))
        let service = networkService(
            process: fixture.process,
            runtime: fixture.runtime
        )
        do {
            try await fixture.runtime.start(
                process: fixture.process,
                handlers: transactionServiceHandlers(service)
            )
            try await connectAndHello(
                client,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            try await waitUntil("joiner acquires the peer's chain") {
                await fixture.process.canonicalTipHeight() == UInt64(depth)
            }
            try await waitUntil("frontier pulled at the edge", attempts: 1_000) {
                !(await scripted.frontierRequests()).isEmpty
            }
            // Settle: nothing after the edge pulls again.
            try await Task.sleep(for: .milliseconds(300))
            let pulls = await scripted.frontierRequests()
            XCTAssertEqual(pulls.count, 1, "one pull per session: \(pulls)")
            XCTAssertEqual(
                pulls.first, UInt64(depth),
                "the frontier is pulled at the edge, never at hello while deep"
            )
        } catch {
            await client.stop()
            await fixture.runtime.stop()
            throw error
        }
        await client.stop()
        await fixture.runtime.stop()
    }

    /// A frontier page seeds candidates only as the one answer to the one
    /// request we sent: an unsolicited or mismatched-requestID page seeds
    /// nothing, the matching page seeds, and a second matching page seeds
    /// nothing (the request is consumed).
    func testFrontierPageSeedsOnlyTheOneCorrelatedResponse() async throws {
        let fixture = try await overlayRuntime(
            keyByte: 0xcd,
            requestTimeout: .seconds(5)
        )
        let producer = try await canonicalNetworkProcess()
        let clock = TestBlockClock()
        let genesis = try await producer.canonicalTipBlock()
        let genesisCID = try BlockHeader(node: genesis).rawCID
        let block1 = try await acceptNexusBlock(
            on: genesis, process: producer, timestamp: clock.next()
        )
        let block2 = try await acceptNexusBlock(
            on: block1, process: producer, timestamp: clock.next()
        )
        let sibling = try await acceptNexusBlock(
            on: genesis, process: producer, timestamp: clock.next()
        )
        let block2CID = try BlockHeader(node: block2).rawCID
        let siblingCID = try BlockHeader(node: sibling).rawCID
        var volumes: [SerializedVolume] = []
        for block in [block1, block2, sibling] {
            let cid = try BlockHeader(node: block).rawCID
            let volume = await producer.volume(cid)
            volumes.append(try XCTUnwrap(volume))
        }
        let scripted = FrontierRequestCapturingPeer()
        let client = Ivy(config: IvyConfig(
            signingKey: signingKey(0xce),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        await client.installTestDelegate(scripted)
        await client.setContentSource(RecordingNetworkTestVolumesSource(volumes))
        let service = networkService(
            process: fixture.process,
            runtime: fixture.runtime
        )
        func sendPage(requestID: UInt64, leaves: [String]) async throws {
            guard case .enqueued = await client.sendMessage(
                to: fixture.peerID,
                topic: NodeNetworkTopic.acceptedLeavesResponse,
                payload: try AcceptedLeavesResponseMessage(
                    requestID: requestID,
                    afterCID: nil,
                    snapshotSequence: 1,
                    blockCIDs: leaves,
                    hasMore: false
                ).encoded()
            ) else {
                throw NetworkTestError.failedSend
            }
        }
        do {
            try await fixture.runtime.start(
                process: fixture.process,
                handlers: transactionServiceHandlers(service)
            )
            try await connectAndHello(
                client,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            // At-edge announcement of a held block triggers the one pull.
            guard case .enqueued = await client.sendMessage(
                to: fixture.peerID,
                topic: NodeNetworkTopic.blockAnnouncement,
                payload: try BlockAnnouncementMessage(
                    blockCID: genesisCID,
                    height: 0
                ).encoded()
            ) else {
                throw NetworkTestError.failedSend
            }
            try await waitUntil("frontier request") {
                !(await scripted.frontierRequestIDs()).isEmpty
            }
            let captured = await scripted.frontierRequestIDs()
            let requestID = try XCTUnwrap(captured.first)

            // Mismatched requestID: seeds nothing.
            try await sendPage(requestID: requestID &+ 1, leaves: [siblingCID])
            try await Task.sleep(for: .milliseconds(300))
            let unsolicited = await fixture.process.hasAcceptedBlock(siblingCID)
            XCTAssertFalse(unsolicited, "an uncorrelated page must seed nothing")

            // The one matching page seeds (leaf 2 walks down to leaf 1).
            try await sendPage(requestID: requestID, leaves: [block2CID])
            try await waitUntil("matching page seeds the leaf") {
                await fixture.process.hasAcceptedBlock(block2CID)
            }

            // A second matching page: the request is consumed.
            try await sendPage(requestID: requestID, leaves: [siblingCID])
            try await Task.sleep(for: .milliseconds(300))
            let repeated = await fixture.process.hasAcceptedBlock(siblingCID)
            XCTAssertFalse(repeated, "a repeated page must seed nothing")
        } catch {
            await client.stop()
            await fixture.runtime.stop()
            throw error
        }
        await client.stop()
        await fixture.runtime.stop()
    }

    /// An announcement carries the announced block's OWN height, not the
    /// validated tip's: every accepted block is announced, and a receiver
    /// reads (blockCID, height) as one claim for its gap test.
    func testAnnouncementCarriesTheAnnouncedBlocksOwnHeight() async throws {
        let fixture = try await overlayRuntime(
            keyByte: 0xcf,
            requestTimeout: .seconds(5)
        )
        let depth = 5
        let payloads = PayloadRecorder()
        let client = Ivy(config: IvyConfig(
            signingKey: signingKey(0xd0),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        // Ivy holds its delegate weakly: keep it alive for the test.
        let delegate = PayloadRecordingPeer(recorder: payloads)
        await client.installTestDelegate(delegate)
        do {
            try await fixture.runtime.start(
                process: fixture.process,
                handlers: inertNetworkHandlers()
            )
            try await connectAndHello(
                client,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            try await waitUntil("hello reply announcement") {
                !(await payloads.payloads(
                    topic: NodeNetworkTopic.blockAnnouncement
                )).isEmpty
            }
            // Acquire weighed history AFTER the session is up (see
            // weighedChain): the node now holds the chain to `depth` while
            // its validated tip is still genesis.
            let blocks = try await weighedChain(on: fixture.process, depth: depth)
            let tipCID = try BlockHeader(node: try XCTUnwrap(blocks.last)).rawCID
            let validatedHeight = await fixture.process.status().height
            XCTAssertEqual(validatedHeight, 0, "validated tip lags the acquired tip")
            try await fixture.runtime.announceBlock(tipCID)
            try await waitUntil("tip announcement") {
                (await payloads.payloads(
                    topic: NodeNetworkTopic.blockAnnouncement
                )).count >= 2
            }
            let announced = try (await payloads.payloads(
                topic: NodeNetworkTopic.blockAnnouncement
            )).map { try BlockAnnouncementMessage.decoded($0) }
            let tip = try XCTUnwrap(announced.first { $0.blockCID == tipCID })
            XCTAssertEqual(tip.height, UInt64(depth))
        } catch {
            await client.stop()
            await fixture.runtime.stop()
            throw error
        }
        await client.stop()
        await fixture.runtime.stop()
    }

    /// The range-sync gap test measures against the ACQUIRED (weighed-
    /// inclusive) tip — what we hold — not the validated tip: a node holding
    /// weighed blocks to H treats H+1 as the live edge (direct predecessor
    /// path) and H+3 as a gap (range sync).
    func testRangeSyncGapIsMeasuredAgainstTheAcquiredTip() async throws {
        let fixture = try await overlayRuntime(
            keyByte: 0xc1,
            requestTimeout: .seconds(5)
        )
        let depth = 5
        let topics = TopicRecorder()
        let client = Ivy(config: IvyConfig(
            signingKey: signingKey(0xc2),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        // Ivy holds its delegate weakly: keep it alive for the test.
        let delegate = TopicRecordingPeer(recorder: topics)
        await client.installTestDelegate(delegate)
        do {
            try await fixture.runtime.start(
                process: fixture.process,
                handlers: inertNetworkHandlers()
            )
            try await connectAndHello(
                client,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            try await waitForTopic(NodeNetworkTopic.blockAnnouncement, in: topics)
            // Acquire weighed history AFTER the session is up (see
            // weighedChain): held to `depth`, validated tip still genesis.
            _ = try await weighedChain(on: fixture.process, depth: depth)
            guard case .enqueued = await client.sendMessage(
                to: fixture.peerID,
                topic: NodeNetworkTopic.blockAnnouncement,
                payload: try BlockAnnouncementMessage(
                    blockCID: testCID("edge"),
                    height: UInt64(depth + 1)
                ).encoded()
            ) else {
                throw NetworkTestError.failedSend
            }
            try await Task.sleep(for: .milliseconds(300))
            let atEdge = await topics.count(
                of: NodeNetworkTopic.ancestorRangeRequest
            )
            XCTAssertEqual(
                atEdge, 0,
                "one past the acquired tip is the live edge, not a gap"
            )
            guard case .enqueued = await client.sendMessage(
                to: fixture.peerID,
                topic: NodeNetworkTopic.blockAnnouncement,
                payload: try BlockAnnouncementMessage(
                    blockCID: testCID("deep"),
                    height: UInt64(depth + 3)
                ).encoded()
            ) else {
                throw NetworkTestError.failedSend
            }
            try await waitForTopic(
                NodeNetworkTopic.ancestorRangeRequest,
                in: topics
            )
        } catch {
            await client.stop()
            await fixture.runtime.stop()
            throw error
        }
        await client.stop()
        await fixture.runtime.stop()
    }

    /// A joiner discovers a producer's LOSING fork from the frontier pull alone
    /// (range sync pages only the main chain; announcements carry only the
    /// tip). The fresh joiner first cold-syncs the canonical chain — every
    /// network block admitted weighed, then validated by the walk — and, after
    /// the producer silently accepts a losing sibling, a rejoin's one-shot
    /// frontier pull weighs that sibling into fork choice without ever
    /// executing it, while the joiner keeps building on the canonical tip.
    func testJoinerWeighsLosingForkFromFrontierWithoutExecutingIt() async throws {
        let producer = try await overlayRuntime(
            keyByte: 0xc3,
            requestTimeout: .seconds(5)
        )
        let joiner = try await overlayRuntime(
            keyByte: 0xc4,
            requestTimeout: .seconds(5),
            bootstrapPeers: [producer.endpoint]
        )
        let producerService = networkService(
            process: producer.process,
            runtime: producer.runtime
        )
        let joinerService = networkService(
            process: joiner.process,
            runtime: joiner.runtime
        )
        let joinerAdmissions = NetworkEventRecorder()
        let joinerHandlers = transactionServiceHandlers(
            joinerService,
            admissions: joinerAdmissions
        )

        // Producer history: genesis-1-2-3-4-5 canonical.
        let clock = TestBlockClock()
        var parent = try await producer.process.canonicalTipBlock()
        var canonical: [String] = []
        var block2 = parent
        for height in 1...5 {
            parent = try await acceptNexusBlock(
                on: parent,
                process: producer.process,
                timestamp: clock.next()
            )
            canonical.append(try BlockHeader(node: parent).rawCID)
            if height == 2 { block2 = parent }
        }
        let tipCID = try XCTUnwrap(canonical.last)

        do {
            try await producer.runtime.start(
                process: producer.process,
                handlers: transactionServiceHandlers(producerService)
            )
            try await joiner.runtime.start(
                process: joiner.process,
                handlers: joinerHandlers
            )
            try await waitUntil("joiner validates the canonical tip") {
                await joiner.process.status().tipCID == tipCID
            }

            // A losing sibling of 3 (on 2), accepted by the producer's process
            // only: no announcement ever carries it, and it is off the main
            // chain, so only the frontier can reveal it.
            let losing = try await acceptNexusBlock(
                on: block2,
                process: producer.process,
                timestamp: clock.next()
            )
            let losingCID = try BlockHeader(node: losing).rawCID
            let producerTip = await producer.process.status().tipCID
            XCTAssertEqual(producerTip, tipCID, "the sibling must lose")

            // Rejoin: the new session's hello pulls the frontier once.
            await joiner.runtime.stop()
            try await joiner.runtime.start(
                process: joiner.process,
                handlers: joinerHandlers
            )
            try await waitUntil("joiner weighs the losing sibling") {
                await joiner.process.hasAcceptedBlock(losingCID)
            }

            let losingValidated = await joiner.process.blockValidated(losingCID)
            XCTAssertFalse(losingValidated, "a losing fork is weighed, never executed")
            for cid in canonical {
                let validated = await joiner.process.blockValidated(cid)
                XCTAssertTrue(validated, "canonical block must be walk-validated")
            }
            let admissions = await joinerAdmissions.snapshot()
            XCTAssertTrue(
                admissions.contains("\(losingCID)|weighed"),
                "admissions: \(admissions)"
            )
            XCTAssertTrue(
                admissions.allSatisfy { $0.hasSuffix("|weighed") },
                "every network-sourced block seeds weighed: \(admissions)"
            )
            let joinerTip = await joiner.process.status().tipCID
            XCTAssertEqual(joinerTip, tipCID)
            let template = try await joinerService.miningTemplate(
                MiningTemplateRequest()
            )
            XCTAssertEqual(template.block.parent?.rawCID, tipCID)
        } catch {
            await joiner.runtime.stop()
            await producer.runtime.stop()
            throw error
        }
        await joiner.runtime.stop()
        await producer.runtime.stop()
    }

    /// Subtree weights are complete. At the fork on 2, branch X wins only
    /// because of a LOSING sub-subtree S under it: X = X3 + {X4a,X5a,X6a}
    /// canonical + S {X4b,X5b} = 6, versus Y = Y3..Y7 = 5. A joiner that
    /// learned Y's leaf but not S would reorg to Y; the frontier pull delivers
    /// both leaves, so the joiner's fork choice matches the producer's, with S
    /// weighed (strictly lighter than its sibling, so never canonical, never
    /// executed).
    func testJoinerForkChoiceMatchesProducerOnlyWithItsLosingSubtree()
        async throws
    {
        let producer = try await overlayRuntime(
            keyByte: 0xc5,
            requestTimeout: .seconds(5)
        )
        let joiner = try await overlayRuntime(
            keyByte: 0xc6,
            requestTimeout: .seconds(5),
            bootstrapPeers: [producer.endpoint]
        )
        let producerService = networkService(
            process: producer.process,
            runtime: producer.runtime
        )
        let joinerService = networkService(
            process: joiner.process,
            runtime: joiner.runtime
        )
        let joinerHandlers = transactionServiceHandlers(joinerService)

        let clock = TestBlockClock()
        func extend(
            _ parent: Block, by count: Int
        ) async throws -> [Block] {
            var blocks: [Block] = []
            var current = parent
            for _ in 0..<count {
                current = try await acceptNexusBlock(
                    on: current,
                    process: producer.process,
                    timestamp: clock.next()
                )
                blocks.append(current)
            }
            return blocks
        }
        func cid(_ block: Block) throws -> String {
            try BlockHeader(node: block).rawCID
        }
        let genesis = try await producer.process.canonicalTipBlock()
        let trunk = try await extend(genesis, by: 2)
        let block2 = try XCTUnwrap(trunk.last)
        let x3 = try await acceptNexusBlock(
            on: block2,
            process: producer.process,
            timestamp: clock.next()
        )
        let xCanonical = try await extend(x3, by: 3)
        let xTipCID = try cid(try XCTUnwrap(xCanonical.last))

        do {
            try await producer.runtime.start(
                process: producer.process,
                handlers: transactionServiceHandlers(producerService)
            )
            try await joiner.runtime.start(
                process: joiner.process,
                handlers: joinerHandlers
            )
            try await waitUntil("joiner validates X's tip") {
                await joiner.process.status().tipCID == xTipCID
            }

            // Silently (process-only) add S under X3 and the competitor Y.
            let s = try await extend(x3, by: 2)
            let y = try await extend(block2, by: 5)
            let sLeafCID = try cid(try XCTUnwrap(s.last))
            let yLeafCID = try cid(try XCTUnwrap(y.last))
            let producerTip = await producer.process.status().tipCID
            XCTAssertEqual(producerTip, xTipCID, "X must still win on the producer")
            // The producer's frontier page carries both new leaves (most
            // recently admitted first), which is all the joiner needs.
            let producerFrontier = try await producer.process.acceptedLeafPage(
                afterCID: nil,
                snapshotSequence: nil,
                limit: AcceptedLeavesResponseMessage.maximumLeaves
            ).blockCIDs
            XCTAssertEqual(
                Array(producerFrontier.prefix(2)), [yLeafCID, sLeafCID],
                "frontier: \(producerFrontier)"
            )

            await joiner.runtime.stop()
            try await joiner.runtime.start(
                process: joiner.process,
                handlers: joinerHandlers
            )
            // A leaf is accepted the moment it is fetched, while its segment
            // is still disconnected; the header graph is complete only once
            // the subtree weights at the fork match the producer's.
            let x3CID = try cid(x3)
            let y3CID = try cid(try XCTUnwrap(y.first))
            let producerXWeight = await producer.process.subtreeWeight(of: x3CID)
            let producerYWeight = await producer.process.subtreeWeight(of: y3CID)
            let producerX = try XCTUnwrap(producerXWeight)
            let producerY = try XCTUnwrap(producerYWeight)
            XCTAssertGreaterThan(producerX, producerY, "X outweighs Y only with S")
            try await waitUntil("joiner assembles both subtrees") {
                let joinerX = await joiner.process.subtreeWeight(of: x3CID)
                let joinerY = await joiner.process.subtreeWeight(of: y3CID)
                return joinerX == producerX && joinerY == producerY
            }
            try await waitUntil("joiner settles on X") {
                await joiner.process.status().tipCID == xTipCID
            }
            let hasS = await joiner.process.hasAcceptedBlock(sLeafCID)
            let hasY = await joiner.process.hasAcceptedBlock(yLeafCID)
            XCTAssertTrue(hasS && hasY)
            for block in s {
                let validated = await joiner.process.blockValidated(try cid(block))
                XCTAssertFalse(validated, "S is weighed, never executed")
            }
            let template = try await joinerService.miningTemplate(
                MiningTemplateRequest()
            )
            XCTAssertEqual(template.block.parent?.rawCID, xTipCID)
        } catch {
            await joiner.runtime.stop()
            await producer.runtime.stop()
            throw error
        }
        await joiner.runtime.stop()
        await producer.runtime.stop()
    }

    /// A live-gossiped block is admitted WEIGHED (rank on verified work), then
    /// executed by the validate-on-candidacy walk once canonical, so the
    /// validated tip and the mining template still reflect it.
    func testLiveAnnouncementIsWeighedThenValidatedOnCandidacy() async throws {
        let producer = try await overlayRuntime(
            keyByte: 0xc7,
            requestTimeout: .seconds(5)
        )
        let joiner = try await overlayRuntime(
            keyByte: 0xc8,
            requestTimeout: .seconds(5),
            bootstrapPeers: [producer.endpoint]
        )
        let producerService = networkService(
            process: producer.process,
            runtime: producer.runtime
        )
        let joinerService = networkService(
            process: joiner.process,
            runtime: joiner.runtime
        )
        let producerInventory = NetworkEventRecorder()
        let joinerInventory = NetworkEventRecorder()
        let joinerAdmissions = NetworkEventRecorder()
        do {
            try await producer.runtime.start(
                process: producer.process,
                handlers: transactionServiceHandlers(
                    producerService,
                    inventoryRequests: producerInventory
                )
            )
            try await joiner.runtime.start(
                process: joiner.process,
                handlers: transactionServiceHandlers(
                    joinerService,
                    inventoryRequests: joinerInventory,
                    admissions: joinerAdmissions
                )
            )
            // Both hellos have landed once each side answered the other's
            // inventory request; anything mined now travels as live gossip.
            try await waitForEvent(in: producerInventory, phase: "producer hello")
            try await waitForEvent(in: joinerInventory, phase: "joiner hello")

            // A real body: the weighed admit stores only the boundary, so the
            // walk must fetch this transaction over the network to validate.
            _ = try await producerService.submitTransaction(
                SubmitTransactionRequest(
                    transaction: try signedNetworkTransaction(chainPath: ["Nexus"])
                )
            )
            let template = try await producerService.miningTemplate(
                MiningTemplateRequest()
            )
            let mined = try await producerService.submitWork(SubmitWorkRequest(
                workID: template.workID,
                nonce: 0
            ))
            XCTAssertTrue(mined.accepted)
            let drained = await producerService.status().mempoolCount
            XCTAssertEqual(drained, 0, "the block must carry the transaction")
            let minedCID = try BlockHeader(node: template.block).rawCID

            try await waitUntil("joiner validates the live block") {
                await joiner.process.status().tipCID == minedCID
            }
            // The hello reply's tip announcement also admits (as a duplicate)
            // the peer's genesis; only the live block is under test.
            let admissions = (await joinerAdmissions.snapshot())
                .filter { $0.hasPrefix(minedCID) }
            XCTAssertEqual(admissions, ["\(minedCID)|weighed"])
            let validated = await joiner.process.blockValidated(minedCID)
            XCTAssertTrue(validated)
            let joinerTemplate = try await joinerService.miningTemplate(
                MiningTemplateRequest()
            )
            XCTAssertEqual(joinerTemplate.block.parent?.rawCID, minedCID)
        } catch {
            await joiner.runtime.stop()
            await producer.runtime.stop()
            throw error
        }
        await joiner.runtime.stop()
        await producer.runtime.stop()
    }

    /// A joiner one block behind (direct predecessor path, no range sync)
    /// weighs the announced block and must then FETCH its deferred body from
    /// the peer to validate it: the joiner never saw the block's transaction
    /// gossiped, so nothing but the network fetch can complete the walk.
    func testShallowJoinerFetchesDeferredBodyOfLiveEdgeBlock() async throws {
        let producer = try await overlayRuntime(
            keyByte: 0xc9,
            requestTimeout: .seconds(5)
        )
        let joiner = try await overlayRuntime(
            keyByte: 0xca,
            requestTimeout: .seconds(5),
            bootstrapPeers: [producer.endpoint]
        )
        let producerService = networkService(
            process: producer.process,
            runtime: producer.runtime
        )
        let joinerService = networkService(
            process: joiner.process,
            runtime: joiner.runtime
        )
        let joinerAdmissions = NetworkEventRecorder()
        do {
            try await producer.runtime.start(
                process: producer.process,
                handlers: transactionServiceHandlers(producerService)
            )
            // Mined BEFORE the joiner exists: the transaction is never relayed
            // to it, so the block's body is only available over the network.
            _ = try await producerService.submitTransaction(
                SubmitTransactionRequest(
                    transaction: try signedNetworkTransaction(chainPath: ["Nexus"])
                )
            )
            let template = try await producerService.miningTemplate(
                MiningTemplateRequest()
            )
            let mined = try await producerService.submitWork(SubmitWorkRequest(
                workID: template.workID,
                nonce: 0
            ))
            XCTAssertTrue(mined.accepted)
            let drained = await producerService.status().mempoolCount
            XCTAssertEqual(drained, 0, "the block must carry the transaction")
            let minedCID = try BlockHeader(node: template.block).rawCID

            try await joiner.runtime.start(
                process: joiner.process,
                handlers: transactionServiceHandlers(
                    joinerService,
                    admissions: joinerAdmissions
                )
            )
            try await waitUntil("joiner validates the announced block") {
                await joiner.process.status().tipCID == minedCID
            }
            let admissions = (await joinerAdmissions.snapshot())
                .filter { $0.hasPrefix(minedCID) }
            XCTAssertEqual(admissions, ["\(minedCID)|weighed"])
            let joinerTemplate = try await joinerService.miningTemplate(
                MiningTemplateRequest()
            )
            XCTAssertEqual(joinerTemplate.block.parent?.rawCID, minedCID)
        } catch {
            await joiner.runtime.stop()
            await producer.runtime.stop()
            throw error
        }
        await joiner.runtime.stop()
        await producer.runtime.stop()
    }

    /// The hello reply advertises the ACQUIRED tip: every receiver measures
    /// its gap, range-sync target and edge against acquired heights, so a node
    /// whose validated tip lags (deferred execution) must not advertise the
    /// validated one — a joiner would range-sync to the validated height,
    /// clear as "caught up", and never re-enter on a quiet network.
    func testHelloReplyAdvertisesTheAcquiredTip() async throws {
        let fixture = try await overlayRuntime(
            keyByte: 0xc3,
            requestTimeout: .seconds(5)
        )
        let depth = 5
        let blocks = try await weighedChain(on: fixture.process, depth: depth)
        let tipCID = try BlockHeader(node: try XCTUnwrap(blocks.last)).rawCID
        let validatedHeight = await fixture.process.status().height
        XCTAssertEqual(validatedHeight, 0, "validated tip lags the acquired tip")
        let payloads = PayloadRecorder()
        let client = Ivy(config: IvyConfig(
            signingKey: signingKey(0x79),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        // Ivy holds its delegate weakly: keep it alive for the test.
        let delegate = PayloadRecordingPeer(recorder: payloads)
        await client.installTestDelegate(delegate)
        do {
            try await fixture.runtime.start(
                process: fixture.process,
                handlers: inertNetworkHandlers()
            )
            try await connectAndHello(
                client,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            try await waitUntil("hello reply announcement") {
                !(await payloads.payloads(
                    topic: NodeNetworkTopic.blockAnnouncement
                )).isEmpty
            }
            let announced = try (await payloads.payloads(
                topic: NodeNetworkTopic.blockAnnouncement
            )).map { try BlockAnnouncementMessage.decoded($0) }
            let hello = try XCTUnwrap(announced.first)
            XCTAssertEqual(hello.blockCID, tipCID)
            XCTAssertEqual(hello.height, UInt64(depth))
        } catch {
            await client.stop()
            await fixture.runtime.stop()
            throw error
        }
        await client.stop()
        await fixture.runtime.stop()
    }

    /// A peer whose claim negotiates to a valid common ancestor and then an
    /// EMPTY page loses its recorded claim exactly like an empty forward page:
    /// otherwise the re-entry probe re-picks the tallest claim forever and a
    /// liar owns the single sync slot. The honest peer syncs us afterwards.
    func testEmptyAncestorPageDemotesThePeersClaim() async throws {
        let fixture = try await overlayRuntime(
            keyByte: 0xc5,
            requestTimeout: .milliseconds(300)
        )
        let liar = EmptyAncestorPeer(claimedHeight: 1 << 62)
        let liarClient = Ivy(config: IvyConfig(
            signingKey: signingKey(0x7a),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        await liarClient.installTestDelegate(liar)
        let depth = 5
        let producer = try await canonicalNetworkProcess()
        let clock = TestBlockClock()
        var parent = try await producer.canonicalTipBlock()
        let genesisCID = try BlockHeader(node: parent).rawCID
        var chain: [String] = []
        var volumes: [SerializedVolume] = []
        for _ in 0..<depth {
            parent = try await acceptNexusBlock(
                on: parent, process: producer, timestamp: clock.next()
            )
            let cid = try BlockHeader(node: parent).rawCID
            chain.append(cid)
            let volume = await producer.volume(cid)
            volumes.append(try XCTUnwrap(volume))
        }
        let honest = RangeServingPeer(
            genesisCID: genesisCID,
            chain: chain,
            receiver: fixture.process
        )
        let honestClient = Ivy(config: IvyConfig(
            signingKey: signingKey(0x7c),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        await honestClient.installTestDelegate(honest)
        await honestClient.setContentSource(
            RecordingNetworkTestVolumesSource(volumes)
        )
        let service = networkService(
            process: fixture.process,
            runtime: fixture.runtime
        )
        do {
            try await fixture.runtime.start(
                process: fixture.process,
                handlers: transactionServiceHandlers(service)
            )
            try await connectAndHello(
                liarClient,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            try await waitUntil("liar negotiated once") {
                await liar.ancestorRequestCount() >= 1
            }
            // Four re-entry windows: a retained claim would be re-picked.
            try await Task.sleep(for: .milliseconds(1_200))
            let negotiations = await liar.ancestorRequestCount()
            XCTAssertEqual(
                negotiations, 1,
                "an empty-page claim must be demoted, not re-picked"
            )

            try await connectAndHello(
                honestClient,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            try await waitUntil("honest peer syncs the chain") {
                await fixture.process.canonicalTipHeight() == UInt64(depth)
            }
            let afterwards = await liar.ancestorRequestCount()
            XCTAssertEqual(afterwards, 1)
        } catch {
            await liarClient.stop()
            await honestClient.stop()
            await fixture.runtime.stop()
            throw error
        }
        await liarClient.stop()
        await honestClient.stop()
        await fixture.runtime.stop()
    }

    /// The range-sync anchor is one (cid, height) pair describing the SAME
    /// block — the acquired tip — never the validated tip's CID under the
    /// acquired height (which would re-page every held block above it).
    func testRangeSyncAnchorsAtTheAcquiredTip() async throws {
        let fixture = try await overlayRuntime(
            keyByte: 0xc7,
            requestTimeout: .seconds(5)
        )
        let depth = 5
        let blocks = try await weighedChain(on: fixture.process, depth: depth)
        let tipCID = try BlockHeader(node: try XCTUnwrap(blocks.last)).rawCID
        let topics = TopicRecorder()
        let client = Ivy(config: IvyConfig(
            signingKey: signingKey(0x7d),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        // Ivy holds its delegate weakly: keep it alive for the test.
        let delegate = TopicRecordingPeer(recorder: topics)
        await client.installTestDelegate(delegate)
        do {
            try await fixture.runtime.start(
                process: fixture.process,
                handlers: inertNetworkHandlers()
            )
            try await connectAndHello(
                client,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            try await waitForTopic(NodeNetworkTopic.blockAnnouncement, in: topics)
            guard case .enqueued = await client.sendMessage(
                to: fixture.peerID,
                topic: NodeNetworkTopic.blockAnnouncement,
                payload: try BlockAnnouncementMessage(
                    blockCID: testCID("deep-tip"),
                    height: 100
                ).encoded()
            ) else {
                throw NetworkTestError.failedSend
            }
            try await waitForTopic(
                NodeNetworkTopic.ancestorRangeRequest,
                in: topics
            )
            let anchorValue = await fixture.runtime.rangeSyncAnchorForTesting()
            let anchor = try XCTUnwrap(anchorValue)
            XCTAssertEqual(anchor.requestedHeight, UInt64(depth))
            XCTAssertEqual(anchor.afterCID, tipCID, "anchor CID is the acquired tip")
        } catch {
            await client.stop()
            await fixture.runtime.stop()
            throw error
        }
        await client.stop()
        await fixture.runtime.stop()
    }

    /// While a range sync is in flight we are by definition not at the edge:
    /// another peer attesting height 1 must not trigger a frontier pull until
    /// the sync clears.
    func testNoFrontierPullWhileARangeSyncIsInFlight() async throws {
        let fixture = try await overlayRuntime(
            keyByte: 0xc9,
            requestTimeout: .milliseconds(300)
        )
        let deep = SilentDeepPeer(claimedHeight: 100)
        let deepClient = Ivy(config: IvyConfig(
            signingKey: signingKey(0x71),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        await deepClient.installTestDelegate(deep)
        let shallow = FrontierRequestCapturingPeer()
        let shallowClient = Ivy(config: IvyConfig(
            signingKey: signingKey(0x73),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        await shallowClient.installTestDelegate(shallow)
        do {
            try await fixture.runtime.start(
                process: fixture.process,
                handlers: inertNetworkHandlers()
            )
            try await connectAndHello(
                deepClient,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            try await waitUntil("deep sync in flight") {
                await deep.ancestorRequestCount() >= 1
            }
            try await connectAndHello(
                shallowClient,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            try await waitUntil("shallow hello landed") {
                await shallow.count(of: NodeNetworkTopic.blockAnnouncement) >= 1
            }
            guard case .enqueued = await shallowClient.sendMessage(
                to: fixture.peerID,
                topic: NodeNetworkTopic.blockAnnouncement,
                payload: try BlockAnnouncementMessage(
                    blockCID: testCID("shallow-tip"),
                    height: 1
                ).encoded()
            ) else {
                throw NetworkTestError.failedSend
            }
            try await Task.sleep(for: .milliseconds(400))
            let duringSync = await shallow.count(
                of: NodeNetworkTopic.acceptedLeavesRequest
            )
            XCTAssertEqual(duringSync, 0, "no pull while a range sync is in flight")

            // The deep peer leaves: the sync clears, and the re-entry probe
            // finds the shallow peer at the edge.
            await deepClient.stop()
            try await waitUntil("pull after the sync clears") {
                await shallow.count(of: NodeNetworkTopic.acceptedLeavesRequest) == 1
            }
        } catch {
            await deepClient.stop()
            await shallowClient.stop()
            await fixture.runtime.stop()
            throw error
        }
        await deepClient.stop()
        await shallowClient.stop()
        await fixture.runtime.stop()
    }

    /// The negotiated anchor survives the ancestor page's enqueue loop: the
    /// loop suspends per CID while the worker it starts drains into the pump,
    /// and a pump that fired there would page forward from the PRE-negotiation
    /// anchor (our own tip) and bump the requestID so the negotiated anchor is
    /// discarded. Every CID of the page is held, so each candidate completes
    /// (and drains) immediately; the anchor must still be the page's last CID.
    func testNegotiatedAnchorSurvivesDrainsDuringTheAncestorPage() async throws {
        let fixture = try await overlayRuntime(
            keyByte: 0xcb,
            requestTimeout: .seconds(5)
        )
        // Kept small: the fixture weighed-admits every block and the page's
        // candidates all complete locally; sixteen drains is plenty.
        let pageSize = 16
        let held = try await weighedChain(on: fixture.process, depth: pageSize + 1)
        let chain = try held.map { try BlockHeader(node: $0).rawCID }
        let genesisCID = try BlockHeader(
            node: await fixture.process.canonicalTipBlock()
        ).rawCID
        let ourTipCID = try XCTUnwrap(chain.last)
        let pageLastCID = chain[pageSize - 1]
        // The peer announces a tip we lack (so a range sync opens), negotiates
        // genesis as the common ancestor, and serves one page of blocks we
        // already hold — every candidate completes at once and drains into
        // the pump while the page loop is still running.
        let scripted = FullPagePeer(
            genesisCID: genesisCID,
            page: Array(chain.prefix(pageSize)),
            claimedHeight: UInt64(pageSize) * 16,
            hasMore: false
        )
        let client = Ivy(config: IvyConfig(
            signingKey: signingKey(0xcc),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        await client.installTestDelegate(scripted)
        do {
            try await fixture.runtime.start(
                process: fixture.process,
                handlers: inertNetworkHandlers()
            )
            try await connectAndHello(
                client,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            // The committed anchor is the negotiated page's end. (A wrong-anchor
            // pump would instead have paged forward from our tip, bumped the
            // requestID, and left the negotiated anchor discarded.)
            try await waitUntil("negotiated anchor committed") {
                (await fixture.runtime.rangeSyncAnchorForTesting())?.afterCID
                    == pageLastCID
            }
            let forward = await scripted.forwardRequests()
            XCTAssertFalse(
                forward.contains(ourTipCID),
                "no forward page anchored at our pre-negotiation tip: \(forward)"
            )
        } catch {
            await client.stop()
            await fixture.runtime.stop()
            throw error
        }
        await client.stop()
        await fixture.runtime.stop()
    }

    /// Mine `depth` empty blocks on a fresh producer and weighed-admit them on
    /// `process` straight at the process (no commit publisher, so no walk
    /// fires): `process` then HOLDS the chain to `depth` while its validated
    /// tip stays at genesis — the deferred-execution catch-up state.
    private func weighedChain(
        on process: ChainProcess,
        depth: Int
    ) async throws -> [Block] {
        let producer = try await canonicalNetworkProcess()
        let clock = TestBlockClock()
        var parent = try await producer.canonicalTipBlock()
        var blocks: [Block] = []
        for _ in 0..<depth {
            parent = try await acceptNexusBlock(
                on: parent,
                process: producer,
                timestamp: clock.next()
            )
            blocks.append(parent)
            let outcome = try await process.admit(
                BlockHeader(node: parent),
                remoteSource: FetcherContentSource(producer),
                mode: .weighed
            )
            guard outcome.decision.isAccepted else {
                throw NetworkTestError.failedPhase(
                    "weighed admit rejected: \(outcome.decision)"
                )
            }
        }
        return blocks
    }

    /// Strictly increasing, slightly-past block timestamps (admission is
    /// `timestamp <= now`).
    private final class TestBlockClock {
        private var current = Int64(Date().timeIntervalSince1970 * 1_000) - 5_000
        func next() -> Int64 {
            current += 100
            return current
        }
    }

    /// Build an empty block on `parent`, grind its (max-target) nonce, and
    /// accept it eagerly on `process` — a producer's own history.
    private func acceptNexusBlock(
        on parent: Block,
        process: ChainProcess,
        timestamp: Int64
    ) async throws -> Block {
        var nonce: UInt64 = 0
        var block = try await BlockBuilder.buildBlock(
            previous: parent,
            timestamp: timestamp,
            nonce: nonce,
            fetcher: process
        )
        while block.proofOfWorkHash() > block.target {
            nonce += 1
            block = try await BlockBuilder.buildBlock(
                previous: parent,
                timestamp: timestamp,
                nonce: nonce,
                fetcher: process
            )
        }
        let outcome = try await process.admit(BlockHeader(node: block))
        guard outcome.decision.isAccepted else {
            throw NetworkTestError.failedPhase(
                "producer block rejected: \(outcome.decision)"
            )
        }
        return block
    }

    private func waitUntil(
        _ phase: String,
        attempts: Int = 3_000,
        _ condition: () async throws -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NetworkTestError.failedPhase(phase)
    }

    private func canonicalNetworkBlock() async throws -> Block {
        let process = try await canonicalNetworkProcess()
        return try await process.canonicalTipBlock()
    }

    private func canonicalNetworkBlockVolumes(
        count: Int
    ) async throws -> [SerializedVolume] {
        let process = try await canonicalNetworkProcess()
        var previous = try await process.canonicalTipBlock()
        var volumes: [SerializedVolume] = []
        for step in 1...count {
            let block = try await BlockBuilder.buildBlock(
                previous: previous,
                timestamp: Int64(step),
                nonce: UInt64(step),
                fetcher: process
            )
            let header = try BlockHeader(node: block)
            try await header.storeBlock(fetcher: process, storer: process)
            let volume = await process.volume(header.rawCID)
            volumes.append(try XCTUnwrap(volume))
            previous = block
        }
        return volumes
    }

    private func canonicalNetworkProcess() async throws -> ChainProcess {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-network-block-\(UUID().uuidString)",
            isDirectory: true
        )
        return try await ChainProcess.open(configuration: try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storage,
            privateKeyHex: String(repeating: "5a", count: 32)
        ))
    }

    private func unsignedTransaction(
        path: [String],
        genesisActions: [GenesisAction] = []
    ) throws -> Transaction {
        let body = TransactionBody(
            accountActions: [],
            actions: [],
            depositActions: [],
            genesisActions: genesisActions,
            receiptActions: [],
            withdrawalActions: [],
            signers: [],
            fee: 0,
            nonce: 0,
            chainPath: path
        )
        return Transaction(
            signatures: [:],
            body: try HeaderImpl<TransactionBody>(node: body)
        )
    }

    private func networkService(
        process: ChainProcess,
        runtime: NodeNetworkRuntime,
        acceptedBlockRecorder: NetworkEventRecorder? = nil
    ) -> ChainService {
        ChainService(
            process: process,
            childCandidateProvider: { [weak runtime] context in
                guard let runtime else { return [] }
                return await runtime.directChildCandidates(context)
            },
            childProofPublisher: { [weak runtime] publication in
                guard let runtime else { throw CancellationError() }
                _ = try await runtime.publishChildProof(
                    publication.proof,
                    childDirectory: publication.directory,
                    childCID: publication.childCID
                )
            },
            acceptedBlockPublisher: { [weak runtime] blockCID in
                await acceptedBlockRecorder?.append(blockCID)
                guard let runtime else { throw CancellationError() }
                try await runtime.publishAcceptedBlock(blockCID)
            },
            acceptedTransactionPublisher: { [weak runtime] rootCID in
                guard let runtime else { throw CancellationError() }
                try await runtime.publishTransaction(rootCID)
            },
            // Mirror the daemon: a weighed admit stored only the boundary, so the
            // validate walk pulls the deferred body over the network.
            validateBodySource: { [weak runtime] blockCID, admit in
                guard let runtime else { throw CancellationError() }
                return try await runtime.remoteContentSource
                    .withRoot(blockCID) { session in
                        try await admit(session)
                    }
            },
            validateEvidenceSource: { [weak runtime] blockCID, requirement in
                await runtime?.resolveValidateEvidence(
                    for: blockCID,
                    requirement: requirement
                )
            }
        )
    }

    /// Handlers that pass the runtime's admission tier through (as the daemon
    /// does); `admissions` records each attempt as `<cid>|weighed` or
    /// `<cid>|eager`.
    private func transactionServiceHandlers(
        _ service: ChainService,
        inventoryRequests: NetworkEventRecorder? = nil,
        transactions: NetworkEventRecorder? = nil,
        admissions: NetworkEventRecorder? = nil
    ) -> NodeNetworkHandlers {
        NodeNetworkHandlers(
            admission: { [weak service] admission in
                guard let service else { throw CancellationError() }
                await admissions?.append(
                    "\(admission.header.rawCID)|"
                        + (admission.weighed ? "weighed" : "eager")
                )
                return try await service.admitNetworkCandidate(
                    admission.header,
                    authenticatedChildPackage: admission.authenticatedChildPackage,
                    preparingChildDirectories: admission.preparingChildDirectories,
                    contentSource: admission.contentSource,
                    weighed: admission.weighed
                )
            },
            transaction: { [weak service] transaction in
                guard let service else { throw CancellationError() }
                await transactions?.append("attempt")
                let inserted = try await service.submitNetworkTransaction(transaction)
                await transactions?.append("accepted")
                return inserted
            },
            transactionInventory: { [weak service] in
                guard let service else { return [] }
                await inventoryRequests?.append("request")
                return await service.transactionInventoryRoots()
            }
        )
    }

    private func waitForTopic(
        _ topic: String,
        in recorder: TopicRecorder
    ) async throws {
        for _ in 0..<200 {
            if await recorder.contains(topic) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NetworkTestError.failedPhase("topic \(topic)")
    }

    private func waitForEvent(
        in recorder: NetworkEventRecorder,
        phase: String = "transaction inventory request",
        attempts: Int = 200
    ) async throws {
        try await waitForEventCount(
            1,
            in: recorder,
            phase: phase,
            attempts: attempts
        )
    }

    private func waitForEventCount(
        _ count: Int,
        in recorder: NetworkEventRecorder,
        phase: String = "transaction inventory request",
        attempts: Int = 200
    ) async throws {
        for _ in 0..<attempts {
            if (await recorder.snapshot()).count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NetworkTestError.failedPhase(phase)
    }

    private func waitForMempoolCount(
        _ count: Int,
        service: ChainService,
        phase: String = "transaction mempool"
    ) async throws {
        for _ in 0..<2_000 {
            if await service.status().mempoolCount == count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NetworkTestError.failedPhase(phase)
    }

    private func signedNetworkTransaction(chainPath: [String]) throws -> Transaction {
        let key = CryptoUtils.generateKeyPair()
        let body = TransactionBody(
            accountActions: [],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: key.publicKey)],
            fee: 0,
            nonce: 0,
            chainPath: chainPath
        )
        let header = try HeaderImpl<TransactionBody>(node: body)
        guard let signature = TransactionSigning.sign(
            bodyHeader: header,
            privateKeyHex: key.privateKey
        ) else { throw NetworkTestError.failedStart }
        return Transaction(
            signatures: [key.publicKey: signature],
            body: header
        )
    }

    private func transactionVolume(
        _ transaction: Transaction
    ) async throws -> SerializedVolume {
        let store = NetworkTestContentStore()
        let volume = try VolumeImpl<Transaction>(node: transaction)
        try await volume.storeRecursively(storer: store)
        let serialized = SerializedVolume(
            root: volume.rawCID,
            entries: await store.allEntries()
        )
        try serialized.validate()
        return serialized
    }

    private func signedGenesisAnchorTransaction(
        directory: String,
        childGenesisCID: String,
        chainPath: [String]
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
        guard let signature = TransactionSigning.sign(
            bodyHeader: bodyHeader,
            privateKeyHex: key.privateKey
        ) else {
            throw NetworkTestError.failedStart
        }
        return Transaction(
            signatures: [key.publicKey: signature],
            body: bodyHeader
        )
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

        let outcome = try await process.admit(
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
            let outcome = try await process.admit(BlockHeader(node: canonical))
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
        let sidePredecessorOutcome = try await process.admit(sidePredecessorHeader)
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
        let remoteContent = NetworkTestContentStore()
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
        let carrierOutcome = try await process.admit(
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
              try await process.issuedChildEvidenceSummaries(
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
        for _ in 0..<500 {
            if (await fixture.recorder.snapshot()).indexEntries.count >= count {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NetworkTestError.failedPhase("child evidence index")
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

    private func hierarchyRetryFixture(
        keyByte: UInt8,
        summary: IssuedChildEvidenceSummary?,
        withholdFirstHello: Bool = false
    ) async throws -> HierarchyRetryFixture {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-hierarchy-retry-\(UUID().uuidString)",
            isDirectory: true
        )
        let parentKey = signingKey(keyByte)
        let parentPeerKey = peerKey(parentKey)
        let parentPort = NetworkTransportTestPorts.allocate()
        let overlayPort = NetworkTransportTestPorts.allocate()
        let hierarchyPort = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus", "Retry"],
            storagePath: storage,
            privateKeyHex: String(
                repeating: String(format: "%02x", keyByte &+ 1),
                count: 32
            ),
            listenPort: overlayPort,
            factListenPort: hierarchyPort,
            rpcPort: NetworkTransportTestPorts.allocate(),
            parentEndpoint: ParentEndpoint(
                publicKey: parentPeerKey.hex,
                host: "127.0.0.1",
                port: parentPort
            )
        )
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
                    bootstrapPeers: [configuration.parentEndpoint!.ivy],
                    inboundAdmissionBypassPeerKeys: [parentPeerKey],
                    requestTimeout: .milliseconds(100),
                    stunServers: [],
                    maxConnections: IvyConfig.defaultMaxConnections,
                    maxConnectionsPerNetgroup: IvyConfig.defaultMaxConnections,
                    relayEnabled: false,
                    carriers: [],
                    mode: .privateNetwork
                )
            )
        )
        let process = try await ChainProcess.open(
            configuration: configuration
        )
        let recorder = HierarchyRetryRecorder(
            withholdFirstHello: withholdFirstHello
        )
        let parent = Ivy(config: IvyConfig(
            signingKey: parentKey,
            listenPort: parentPort,
            stunServers: [],
            mode: .privateNetwork
        ))
        let delegate = HierarchyRetryPeer(
            recorder: recorder,
            parentHello: try ChainHello(
                nexusGenesisCID: configuration.nexusGenesisCID,
                chainPath: ["Nexus"]
            ).encode(),
            summary: summary
        )
        await parent.installTestDelegate(delegate)
        return HierarchyRetryFixture(
            storage: storage,
            configuration: configuration,
            runtime: runtime,
            process: process,
            parent: parent,
            recorder: recorder,
            delegate: delegate
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
        let admission = try await target.process.admit(
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
                handlers: duplicateNetworkHandlers()
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

    private func signingKey(_ byte: UInt8) -> Curve25519.Signing.PrivateKey {
        try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: byte, count: 32))
    }

    private func peerKey(_ key: Curve25519.Signing.PrivateKey) -> PeerKey {
        try! PeerKey(rawRepresentation: key.publicKey.rawRepresentation)
    }

    private func authenticatedPeer(
        _ key: Curve25519.Signing.PrivateKey,
        role: AuthenticatedPeerRole
    ) -> AuthenticatedPeer {
        AuthenticatedPeer(
            key: peerKey(key),
            role: role,
            route: .direct,
            metadata: PeerMetadata()
        )
    }

    private func carrierLink(
        parentPath: [String],
        carrierCID: String,
        rootCID: String
    ) throws -> ParentCarrierLink {
        struct Wire: Encodable {
            let parentPath: [String]
            let carrierCID: String
            let rootCID: String
        }
        return try JSONDecoder().decode(
            ParentCarrierLink.self,
            from: JSONEncoder().encode(Wire(
                parentPath: parentPath,
                carrierCID: carrierCID,
                rootCID: rootCID
            ))
        )
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

    private func contribution(
        id: String,
        work: UInt64
    ) -> VerifiedWorkContribution {
        try! JSONDecoder().decode(
            VerifiedWorkContribution.self,
            from: Data(
                "{\"id\":\"\(id)\",\"work\":\"0x\(String(work, radix: 16))\"}".utf8
            )
        )
    }
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
