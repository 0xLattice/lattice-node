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

private final class AcceptedLeavesPeer: IvyDelegate, Sendable {
    private let acceptedLeafCID: String

    init(acceptedLeafCID: String) {
        self.acceptedLeafCID = acceptedLeafCID
    }

    func ivy(
        _ ivy: Ivy,
        didReceiveMessage message: PeerMessage,
        from peer: AuthenticatedPeer
    ) async {
        switch message.topic {
        case NodeNetworkTopic.acceptedLeavesRequest:
            guard let request = try? AcceptedLeavesRequestMessage.decoded(
                message.payload
            ), let response = try? AcceptedLeavesResponseMessage(
                requestID: request.requestID,
                afterCID: request.afterCID,
                snapshotSequence: request.snapshotSequence ?? 1,
                blockCIDs: [acceptedLeafCID],
                hasMore: false
            ).encoded() else { return }
            _ = await ivy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.acceptedLeavesResponse,
                payload: response
            )
        default:
            break
        }
    }
}

private actor TopicRecorder {
    private var topics: [String] = []
    func append(_ topic: String) { topics.append(topic) }
    func contains(_ topic: String) -> Bool { topics.contains(topic) }
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

private actor OverlayInventoryPeer: IvyDelegate {
    private let leaves: [String]?
    private var requestSessions: [Data] = []

    init(leaves: [String]?) {
        self.leaves = leaves
    }

    func ivy(
        _ ivy: Ivy,
        didReceiveMessage message: PeerMessage,
        from peer: AuthenticatedPeer
    ) async {
        if message.topic == NodeNetworkTopic.acceptedLeavesRequest {
            guard let request = try? AcceptedLeavesRequestMessage.decoded(
                message.payload
            ) else { return }
            requestSessions.append(peer.sessionID)
            guard let leaves,
                  let payload = try? AcceptedLeavesResponseMessage(
                requestID: request.requestID,
                afterCID: request.afterCID,
                snapshotSequence: request.snapshotSequence ?? 1,
                blockCIDs: leaves,
                hasMore: false
            ).encoded() else { return }
            _ = await ivy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.acceptedLeavesResponse,
                payload: payload
            )
        } else if message.topic
            == NodeNetworkTopic.portableAttachmentIndexRequest {
            guard let request = try? PortableAttachmentIndexRequestMessage
                .decoded(message.payload),
                  let payload = try? PortableAttachmentIndexResponseMessage(
                    requestID: request.requestID,
                    after: request.after,
                    entries: [],
                    hasMore: false
                  ).encoded() else { return }
            _ = await ivy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.portableAttachmentIndexResponse,
                payload: payload
            )
        }
    }

    func requestCount() -> Int { requestSessions.count }
}

private struct PortableAttachmentTestPayload: Sendable {
    let summary: PortableAttachmentSummary
    let content: [String: Data]
}

private actor PortableAttachmentQueuePeer: IvyDelegate, IvyContentSource {
    private let attachments: [PortableAttachmentTestPayload]
    private let firstAdmissionGate: CandidateBuildGate
    private var servedAttachments = Set<String>()
    private var portableIndexRequests = 0

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

    func ivy(
        _ ivy: Ivy,
        didReceiveMessage message: PeerMessage,
        from peer: AuthenticatedPeer
    ) async {
        switch message.topic {
        case NodeNetworkTopic.acceptedLeavesRequest:
            guard let request = try? AcceptedLeavesRequestMessage.decoded(
                message.payload
            ), let payload = try? AcceptedLeavesResponseMessage(
                requestID: request.requestID,
                afterCID: request.afterCID,
                snapshotSequence: request.snapshotSequence ?? 1,
                blockCIDs: [],
                hasMore: false
            ).encoded() else { return }
            _ = await ivy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.acceptedLeavesResponse,
                payload: payload
            )
        case NodeNetworkTopic.portableAttachmentIndexRequest:
            guard let request = try? PortableAttachmentIndexRequestMessage
                .decoded(message.payload) else { return }
            portableIndexRequests += 1
            await sendEmptyPortablePage(request, ivy: ivy, peer: peer)
        default:
            break
        }
    }

    private func sendEmptyPortablePage(
        _ request: PortableAttachmentIndexRequestMessage,
        ivy: Ivy,
        peer: AuthenticatedPeer
    ) async {
        guard let payload = try? PortableAttachmentIndexResponseMessage(
            requestID: request.requestID,
            after: request.after,
            entries: [],
            hasMore: false
        ).encoded() else { return }
        _ = await ivy.sendMessage(
            to: peer,
            topic: NodeNetworkTopic.portableAttachmentIndexResponse,
            payload: payload
        )
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
    func indexRequestCount() -> Int { portableIndexRequests }
}

private actor HierarchyRetryRecorder {
    private let withholdFirstHello: Bool
    private var evidenceIndexRequests = 0
    private var helloSessions: [Data] = []
    private var indexSessions: [Data] = []

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
        default:
            break
        }
        return false
    }

    func sessionTrace() -> (hellos: [Data], indexes: [Data]) {
        (helloSessions, indexSessions)
    }
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

    func testCandidateAcquirerReservesOneAcceptedLeafPage() {
        var acquirer = CandidateAcquirer()
        let pageSize = AcceptedLeavesResponseMessage.maximumLeaves
        for index in 0..<(CandidateAcquirer.readyCapacity - pageSize) {
            XCTAssertTrue(acquirer.observe(.init(
                blockCID: "cid-\(index)",
                package: nil
            )).accepted)
        }
        XCTAssertTrue(acquirer.reserveAcceptedLeafPage(pageSize))
        XCTAssertFalse(acquirer.reserveAcceptedLeafPage(pageSize))
        XCTAssertFalse(acquirer.observe(.init(
            blockCID: "gossip-overflow",
            package: nil
        )).accepted)
        acquirer.releaseAcceptedLeafPage(pageSize)
        XCTAssertTrue(acquirer.observe(.init(
            blockCID: "next",
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
        let blockDelegate = OverlayInventoryPeer(leaves: [])
        let replacementDelegate = OverlayInventoryPeer(leaves: [])
        await blockAdvertiser.installTestDelegate(blockDelegate)
        await replacement.installTestDelegate(replacementDelegate)
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
            for _ in 0..<300 {
                if await delegate.indexRequestCount() > 0 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard await delegate.indexRequestCount() > 0 else {
                throw NetworkTestError.failedPhase(
                    "initial portable attachment inventory"
                )
            }
            for attachment in attachments {
                guard case .enqueued = await evidencePeer.sendMessage(
                    to: PeerID(publicKey: targetConfiguration.processPublicKey),
                    topic: NodeNetworkTopic.portableAttachmentAvailable,
                    payload: try PortableAttachmentAvailableMessage(
                        edgeCID: attachment.summary.edgeCID,
                        rootCID: attachment.summary.rootCID,
                        attachmentCID: attachment.summary.attachmentCID
                    ).encoded()
                ) else {
                    throw NetworkTestError.failedSend
                }
            }
            for _ in 0..<2_000 {
                if (await delegate.servedRoots()).count == 2 { break }
                try await Task.sleep(for: .milliseconds(10))
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
            for _ in 0..<300 {
                if await replacementDelegate.requestCount() > 0 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard await replacementDelegate.requestCount() > 0 else {
                throw NetworkTestError.failedPhase(
                    "replacement overlay authorization"
                )
            }
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

    func testAcceptedLeafSyncRotatesPastSilentOverlayPeer() async throws {
        let fixture = try await overlayRuntime(
            keyByte: 0x75,
            requestTimeout: .milliseconds(150)
        )
        let admitted = NetworkEventRecorder()
        let handlers = NodeNetworkHandlers(admission: { admission in
            await admitted.append(admission.header.rawCID)
            return NodeAdmissionOutcome(
                decision: .acceptedSide(ChainCommit(
                    tipHash: admission.header.rawCID
                )),
                parentCarrierLink: nil,
                sameChainPredecessor: nil
            )
        })

        let silentDelegate = OverlayInventoryPeer(leaves: nil)
        let silent = Ivy(config: IvyConfig(
            signingKey: signingKey(0x76),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        await silent.installTestDelegate(silentDelegate)
        let honestVolume = try await canonicalNetworkBlockVolumes(count: 1)[0]
        let honestCID = honestVolume.root
        let honestDelegate = OverlayInventoryPeer(leaves: [honestCID])
        let honest = Ivy(config: IvyConfig(
            signingKey: signingKey(0x77),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        await honest.installTestDelegate(honestDelegate)
        await honest.setContentSource(NetworkTestVolumeSource(
            value: honestVolume
        ))

        do {
            try await fixture.runtime.start(
                process: fixture.process,
                handlers: handlers
            )
            try await connectAndHello(
                silent,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            for _ in 0..<100 {
                if await silentDelegate.requestCount() >= 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let silentRequests = await silentDelegate.requestCount()
            XCTAssertGreaterThanOrEqual(silentRequests, 1)

            try await connectAndHello(
                honest,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            for _ in 0..<200 {
                if (await admitted.snapshot()).contains(honestCID) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let honestRequests = await honestDelegate.requestCount()
            let admittedCIDs = await admitted.snapshot()
            XCTAssertGreaterThanOrEqual(honestRequests, 1)
            XCTAssertEqual(admittedCIDs, [honestCID])
        } catch {
            await honest.stop()
            await silent.stop()
            await fixture.runtime.stop()
            throw error
        }
        await honest.stop()
        await silent.stop()
        await fixture.runtime.stop()
    }

    func testAcceptedLeafRetriesTransientEmptyAdvertiserWithoutReconnect()
        async throws {
        let fixture = try await overlayRuntime(
            keyByte: 0x7b,
            requestTimeout: .milliseconds(100)
        )
        let volume = try await canonicalNetworkBlockVolumes(count: 1)[0]
        let source = BlockingNetworkTestVolumeSource(value: volume)
        let inventory = OverlayInventoryPeer(leaves: [volume.root])
        let advertiser = Ivy(config: IvyConfig(
            signingKey: signingKey(0x7c),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        await advertiser.installTestDelegate(inventory)
        await advertiser.setContentSource(source)
        let admitted = NetworkEventRecorder()
        let handlers = NodeNetworkHandlers(admission: { admission in
            await admitted.append(admission.header.rawCID)
            return NodeAdmissionOutcome(
                decision: .duplicate,
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
                advertiser,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            for _ in 0..<200 {
                if await source.didStart() { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let firstRequestStarted = await source.didStart()
            XCTAssertTrue(firstRequestStarted)

            // Ivy's first exact request expires as an unattributed `.empty`.
            // The same session then serves the same advertised Volume.
            try await Task.sleep(for: .milliseconds(200))
            await source.release()
            for _ in 0..<300 {
                if (await admitted.snapshot()).contains(volume.root) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let admittedCIDs = await admitted.snapshot()
            let inventoryRequests = await inventory.requestCount()
            XCTAssertEqual(admittedCIDs, [volume.root])
            XCTAssertEqual(inventoryRequests, 1)
        } catch {
            await advertiser.stop()
            await fixture.runtime.stop()
            throw error
        }
        await advertiser.stop()
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
        let firstDelegate = OverlayInventoryPeer(leaves: [])
        let first = Ivy(config: IvyConfig(
            signingKey: attackerKey,
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        await first.installTestDelegate(firstDelegate)
        await first.setContentSource(NetworkTestVolumeSource(value: volumes[0]))
        let replacementDelegate = OverlayInventoryPeer(leaves: [replacementCID])
        let replacement = Ivy(config: IvyConfig(
            signingKey: attackerKey,
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        await replacement.installTestDelegate(replacementDelegate)
        await replacement.setContentSource(NetworkTestVolumeSource(value: volumes[1]))
        let honestDelegate = OverlayInventoryPeer(leaves: [honestCID])
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
                if await firstDelegate.requestCount() == 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let firstRequests = await firstDelegate.requestCount()
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
                if await replacementDelegate.requestCount() == 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let replacementRequests = await replacementDelegate.requestCount()
            XCTAssertEqual(replacementRequests, 1)
            try await connectAndHello(
                honest,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            for _ in 0..<100 {
                if await honestDelegate.requestCount() == 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let honestRequests = await honestDelegate.requestCount()
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
        let authorizedDelegate = OverlayInventoryPeer(leaves: [])
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
                if await authorizedDelegate.requestCount() == 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let initialRequests = await authorizedDelegate.requestCount()
            XCTAssertEqual(initialRequests, 1)

            guard case .enqueued = await authorized.sendMessage(
                to: fixture.peerID,
                topic: NodeNetworkTopic.overlayHello,
                payload: fixture.hello
            ) else {
                throw NetworkTestError.failedSend
            }
            try await Task.sleep(for: .milliseconds(300))
            let finalRequests = await authorizedDelegate.requestCount()
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
        let clientDelegate = AcceptedLeavesPeer(
            acceptedLeafCID: descendantHeader.rawCID
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
            }
        )
    }

    private func transactionServiceHandlers(
        _ service: ChainService,
        inventoryRequests: NetworkEventRecorder? = nil,
        transactions: NetworkEventRecorder? = nil
    ) -> NodeNetworkHandlers {
        NodeNetworkHandlers(
            admission: { [weak service] admission in
                guard let service else { throw CancellationError() }
                return try await service.admitNetworkCandidate(
                    admission.header,
                    authenticatedChildPackage: admission.authenticatedChildPackage,
                    preparingChildDirectories: admission.preparingChildDirectories,
                    contentSource: admission.contentSource
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
