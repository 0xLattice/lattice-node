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

private actor AuthenticatedPeerRecorder: IvyDelegate {
    private var peer: AuthenticatedPeer?

    func ivy(_ ivy: Ivy, didConnect peer: AuthenticatedPeer) {
        self.peer = peer
    }

    func connectedPeer() -> AuthenticatedPeer? { peer }
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

/// A scripted overlay peer holding a main chain: announces its tip once per
/// session (on the runtime's hello-reply announcement), answers the
/// common-ancestor negotiation and forward pages from that chain, and records
/// the receiver's ACQUIRED height at the moment each frontier (accepted-
/// leaves) request arrives.
actor RangeServingPeer: IvyDelegate {
    private let genesisCID: String
    /// Ascending, genesis excluded.
    private let chain: [String]
    private let receiver: ChainProcess
    /// The height announced once per session (defaults to the chain's).
    private let claimedHeight: UInt64
    /// False: claims its tip, then answers no range request.
    private let servesRanges: Bool
    /// Where each range request received is recorded, if anywhere.
    private let events: NetworkEventRecorder?
    private var authorizedSessions: [Data] = []
    private var frontierRequestHeights: [UInt64] = []
    private var forwardAfterCIDs: [String] = []

    init(
        genesisCID: String,
        chain: [String],
        receiver: ChainProcess,
        claimedHeight: UInt64? = nil,
        servesRanges: Bool = true,
        events: NetworkEventRecorder? = nil
    ) {
        self.genesisCID = genesisCID
        self.chain = chain
        self.receiver = receiver
        self.claimedHeight = claimedHeight ?? UInt64(chain.count)
        self.servesRanges = servesRanges
        self.events = events
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
            await events?.append("range request")
            guard servesRanges, let request = try? AncestorRangeRequestMessage.decoded(
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
            guard servesRanges, let request = try? ForwardRangeRequestMessage.decoded(
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

/// Says nothing, but answers every transaction inventory request (empty),
/// as a live peer does; an unanswered one recycles the session.
private final class InventoryAnsweringPeer: IvyDelegate, Sendable {
    func ivy(
        _ ivy: Ivy,
        didReceiveMessage message: PeerMessage,
        from peer: AuthenticatedPeer
    ) async {
        guard message.topic == NodeNetworkTopic.transactionInventoryRequest else { return }
        await answerInventoryEmpty(ivy, message: message, peer: peer)
    }
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
func answerInventoryEmpty(
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

final class NetworkTrustFrontierSyncTests: NetworkTrustTestCase {
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
        await server.setContentSource(VolumeSource(one: volume))
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
        await observer.setContentSource(VolumeSource(
            one: validVolume
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
        await advertiser.setContentSource(VolumeSource(
            one: invalidVolume
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
                chain: handlers
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
            try await alwaysDuring("the advertised volume is neither pooled nor relayed", .milliseconds(300)) {
                let pooled = await service.status().mempoolCount
                let relayed = await observerTopics.contains(
                    NodeNetworkTopic.transactionAvailable
                )
                return pooled == 0 && !relayed
            }

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
            try await alwaysDuring("the advertised volume is neither pooled nor relayed", .milliseconds(300)) {
                let pooled = await service.status().mempoolCount
                let relayed = await observerTopics.contains(
                    NodeNetworkTopic.transactionAvailable
                )
                return pooled == 0 && !relayed
            }

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
            await observer.setContentSource(VolumeSource(
                one: bloated
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
                chain: firstHandlers
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
                chain: secondHandlers
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
                phase: "second transaction handler"
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
                chain: secondHandlers
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
                chain: lateHandlers
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
                chain: handlers
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
        let source = BlockingVolumeSource(value: volume)
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
                chain: handlers
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

    func testRealIvyApplicationMessageReachesAsyncRuntimeDelegate() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-network-delegate-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let overlayPort = NetworkTransportTestPorts.allocate()
        let rpcPort = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storage,
            privateKeyHex: String(repeating: "5d", count: 32),
            listenPort: overlayPort,
            rpcPort: rpcPort
        )
        let planes = try NodeNetworkPlaneConfigurations(
            overlay: IvyConfig(
                signingKey: configuration.signingKey,
                listenPort: overlayPort,
                stunServers: [],
                mode: .overlay
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
        let handlers = ClosureChainInterface(admission: { admission in
            await admissions.append(admission.header.rawCID)
            delivered.fulfill()
            return NodeImportOutcome(
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
        await client.setContentSource(VolumeSource(
            one: candidateVolume
        ))
        do {
            try await runtime.start(process: process, chain: handlers)
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
            // Short enough for the retry cadence, long enough that a stalled
            // sanitizer run still delivers the hello inside the deadline.
            requestTimeout: .milliseconds(250)
        )
        let service = networkService(
            process: fixture.process,
            runtime: fixture.runtime
        )
        let decisions = NetworkEventRecorder()
        let handlers = ClosureChainInterface(admission: { admission in
            let outcome = try await service.importNetworkCandidate(
                admission.header,
                authenticatedChildPackage: admission.authenticatedChildPackage,
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
                chain: handlers
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
            // (notYetValid), then admits once real time reaches its timestamp.
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
            let source = InMemoryContentStore()
            try await header.storeBlock(
                fetcher: fixture.process,
                storer: source
            )
            let storedVolume = await source.volume(root: header.rawCID)
            let volume = try XCTUnwrap(storedVolume)
            await advertiser.setContentSource(
                VolumeSource(one: volume)
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
                chain: inertNetworkHandlers()
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

        let badSource = RecordingVolumesSource([blockVolume])
        let bad = Ivy(config: IvyConfig(
            signingKey: signingKey(0x6c),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        await bad.setContentSource(badSource)

        let honestPort = NetworkTransportTestPorts.allocate()
        let honestSource = RecordingVolumesSource([
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
        let handlers = ClosureChainInterface(admission: { admission in
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
            return NodeImportOutcome(
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
                chain: handlers
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
        let handlers = ClosureChainInterface(admission: { admission in
            await admitted.append(admission.header.rawCID)
            if admission.header.rawCID == stalledCID {
                _ = await gate.enter()
                throw NetworkTestError.failedPhase("stalled acquisition")
            }
            return NodeImportOutcome(
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
        await first.setContentSource(VolumeSource(one: volumes[0]))
        let replacementDelegate = OverlayAnnouncingPeer(announcing: [replacementCID])
        let replacement = Ivy(config: IvyConfig(
            signingKey: attackerKey,
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        await replacement.installTestDelegate(replacementDelegate)
        await replacement.setContentSource(VolumeSource(one: volumes[1]))
        let honestDelegate = OverlayAnnouncingPeer(announcing: [honestCID])
        let honest = Ivy(config: IvyConfig(
            signingKey: signingKey(0x7a),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        await honest.installTestDelegate(honestDelegate)
        await honest.setContentSource(VolumeSource(one: volumes[2]))

        do {
            try await fixture.runtime.start(
                process: fixture.process,
                chain: handlers
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
                chain: transactionServiceHandlers(service)
            )
            try await connectAndHello(
                client,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            try await waitForTopic(NodeNetworkTopic.blockAnnouncement, in: topics)
            // Settle: the hello reply alone knows no peer height.
            try await alwaysDuring("hello alone pulls no frontier", .milliseconds(300)) {
                await topics.count(of: NodeNetworkTopic.acceptedLeavesRequest) == 0
            }
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
            try await alwaysDuring("same session at the edge: no second pull", .milliseconds(300)) {
                let pulls = await topics.count(of: NodeNetworkTopic.acceptedLeavesRequest)
                let announcements = await topics.count(of: NodeNetworkTopic.blockAnnouncement)
                return pulls == 1 && announcements == 1
            }
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
        await client.setContentSource(RecordingVolumesSource(volumes))
        let service = networkService(
            process: fixture.process,
            runtime: fixture.runtime
        )
        do {
            try await fixture.runtime.start(
                process: fixture.process,
                chain: transactionServiceHandlers(service)
            )
            try await connectAndHello(
                client,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            try await eventually("joiner acquires the peer's chain") {
                await fixture.process.canonicalTipHeight() == UInt64(depth)
            }
            try await eventually("frontier pulled at the edge") {
                !(await scripted.frontierRequests()).isEmpty
            }
            // Settle: nothing after the edge pulls again.
            try await alwaysDuring("nothing after the edge pulls again", .milliseconds(300)) {
                (await scripted.frontierRequests()).count == 1
            }
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

    /// A block that arrives before its parent waits for the parent at a
    /// constant request cost. Resolving its difficulty anchor by walking the
    /// missing ancestry over the network — one Volume request per ancestor,
    /// repeated at every level of the predecessor walk down from an announced
    /// deep tip — is quadratic, and drained the supplier's per-peer budget
    /// until requests went unanswered for a full request timeout each (#201).
    /// Admission now answers the anchor from what it holds or parks.
    func testOutOfOrderBlockParksOnItsParentWithoutWalkingItsAncestry()
        async throws
    {
        let fixture = try await overlayRuntime(
            keyByte: 0xe1,
            requestTimeout: .milliseconds(300)
        )
        // Deep enough that walking the ancestry per level (block h asked
        // depth + 1 - h times) breaks the per-block bound below.
        let depth = 8
        let producer = try await canonicalNetworkProcess()
        let clock = TestBlockClock()
        var parent = try await producer.canonicalTipBlock()
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
        let source = RecordingVolumesSource(volumes)
        let client = Ivy(config: IvyConfig(
            signingKey: signingKey(0xe2),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        // Answers no range request: the tip and the predecessor walk under
        // it are the only way the joiner acquires this chain. It answers the
        // transaction inventory request, as any peer does: left unanswered,
        // the runtime recycles the session at the request timeout, which on
        // a slow run lands mid-walk and strands it. The short request
        // timeout keeps that fixture race visible on a fast run.
        let delegate = InventoryAnsweringPeer()
        await client.installTestDelegate(delegate)
        await client.setContentSource(source)
        let service = networkService(
            process: fixture.process,
            runtime: fixture.runtime
        )
        do {
            try await fixture.runtime.start(
                process: fixture.process,
                chain: transactionServiceHandlers(service)
            )
            try await connectAndHello(
                client,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            guard case .enqueued = await client.sendMessage(
                to: fixture.peerID,
                topic: NodeNetworkTopic.blockAnnouncement,
                payload: try BlockAnnouncementMessage(
                    blockCID: try XCTUnwrap(chain.last),
                    height: UInt64(depth)
                ).encoded()
            ) else {
                throw NetworkTestError.failedSend
            }
            try await eventually("joiner acquires the announced chain") {
                await fixture.process.canonicalTipHeight() == UInt64(depth)
            }
            let requests = await source.requests()
            // A constant per block, whatever its depth: its own admission
            // (which parks it), its child's admission reading it as the
            // parent (for the grandparent's difficulty anchor), and its
            // re-admission when its parent connects. The ancestor walk asked
            // for the lowest blocks once per level above them.
            for (height, cid) in chain.enumerated() {
                let count = requests.filter { $0 == cid }.count
                XCTAssertLessThanOrEqual(
                    count, 3,
                    "block at height \(height + 1) requested \(count) times"
                )
            }
        } catch {
            await client.stop()
            await fixture.runtime.stop()
            throw error
        }
        await client.stop()
        await fixture.runtime.stop()
    }

    /// Waiting on a missing parent applies only to a block that clears its
    /// own target. A target miss is a carrier: decided and relayed from its
    /// own bytes, whatever its parent (§9.5), so it is never held behind a
    /// parent this node may never accept.
    func testTargetMissWithUnknownParentIsACarrierNotAPark() async throws {
        let producer = try await canonicalNetworkProcess()
        let joiner = try await canonicalNetworkProcess()
        let clock = TestBlockClock()
        let genesis = try await producer.canonicalTipBlock()
        let parent = try await acceptNexusBlock(
            on: genesis,
            process: producer,
            timestamp: clock.next()
        )
        let parentCID = try BlockHeader(node: parent).rawCID
        var nonce: UInt64 = 0
        var miss = try await BlockBuilder.buildBlock(
            previous: parent, timestamp: clock.next(), target: UInt256(1) << 8,
            nonce: nonce, fetcher: producer
        )
        while miss.validateProofOfWork(nexusHash: miss.proofOfWorkHash()) {
            nonce += 1
            miss = try await BlockBuilder.buildBlock(
                previous: parent, timestamp: clock.next(), target: UInt256(1) << 8,
                nonce: nonce, fetcher: producer
            )
        }
        let missHeader = try BlockHeader(node: miss)
        try await missHeader.storeBlock(fetcher: producer, storer: producer)
        let carrier = try await joiner.importBlock(
            missHeader, remoteSource: producer, mode: .header
        )
        guard case .carrier = carrier.decision else {
            return XCTFail("a target miss is a carrier, got \(carrier.decision)")
        }
        XCTAssertEqual(
            carrier.parentCarrierLink?.carrierCID, missHeader.rawCID,
            "the carrier is relayed"
        )
        XCTAssertNil(carrier.sameChainPredecessor, "not parked on its parent")

        // The same parent under a block that clears its target: it waits
        // for that parent.
        let child = try await acceptNexusBlock(
            on: parent,
            process: producer,
            timestamp: clock.next()
        )
        let waiting = try await joiner.importBlock(
            try BlockHeader(node: child), remoteSource: producer, mode: .header
        )
        XCTAssertEqual(waiting.sameChainPredecessor?.predecessorCID, parentCID)
    }

    /// One peer's in-flight range sync must not silence every OTHER peer's
    /// frontier pull. The edge test is PER PEER — our acquired tip against that
    /// peer's own claimed height — so a third party's claim has no bearing on
    /// whether we are at the edge with this one. A peer that claims a tall tip
    /// takes the single range-sync slot with a bare, unverified number and then
    /// stalls; while it holds the slot, a peer we are genuinely at the edge with
    /// must still have its frontier pulled, or one free identity withholds every
    /// honest peer's losing-fork leaves from fork choice for the whole redrive
    /// budget.
    func testStalledRangeSyncDoesNotSuppressAnotherPeersFrontierPull()
        async throws
    {
        let fixture = try await overlayRuntime(
            keyByte: 0xd7,
            requestTimeout: .seconds(5)
        )
        let genesisCID = try BlockHeader(
            node: await fixture.process.canonicalTipBlock()
        ).rawCID
        let stalling = SilentDeepPeer(claimedHeight: 5_000)
        let deepClient = Ivy(config: IvyConfig(
            signingKey: signingKey(0xd8),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        await deepClient.installTestDelegate(stalling)
        let topics = TopicRecorder()
        let edgeClient = Ivy(config: IvyConfig(
            signingKey: signingKey(0xd9),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        // Held in a local: the overlay retains its delegate weakly, so an
        // inline temporary would be released before the first message arrives.
        let edgeDelegate = TransactionTopicRecordingPeer(recorder: topics)
        await edgeClient.installTestDelegate(edgeDelegate)
        let service = networkService(
            process: fixture.process,
            runtime: fixture.runtime
        )
        do {
            try await fixture.runtime.start(
                process: fixture.process,
                chain: transactionServiceHandlers(service)
            )
            // The at-edge peer joins first, while the node is idle: its hello
            // reply is the node its own tip, and no frontier pull can follow yet,
            // because a hello carries no peer height.
            try await connectAndHello(
                edgeClient,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            try await waitForTopic(NodeNetworkTopic.blockAnnouncement, in: topics)
            // Now the tall claim commits the one range-sync slot: the node opens
            // the common-ancestor negotiation, which this peer never answers.
            try await connectAndHello(
                deepClient,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            try await eventually("range sync commits to the stalling peer") {
                await stalling.ancestorRequestCount() > 0
            }
            // This peer's tip is our own genesis: held, and at our edge.
            guard case .enqueued = await edgeClient.sendMessage(
                to: fixture.peerID,
                topic: NodeNetworkTopic.blockAnnouncement,
                payload: try BlockAnnouncementMessage(
                    blockCID: genesisCID,
                    height: 0
                ).encoded()
            ) else {
                throw NetworkTestError.failedSend
            }
            try await eventually("the at-edge peer frontier is pulled") {
                await topics.count(
                    of: NodeNetworkTopic.acceptedLeavesRequest
                ) > 0
            }
            let pulls = await topics.count(
                of: NodeNetworkTopic.acceptedLeavesRequest
            )
            XCTAssertEqual(
                pulls,
                1,
                "the at-edge peer's frontier is pulled once"
            )
            // The pull landed WHILE the slot was still held: that is the point.
            let anchor = await fixture.runtime.debugSnapshot().rangeSyncAnchor
            XCTAssertNotNil(
                anchor,
                "the stalling peer must still hold the range-sync slot, "
                    + "or the test proved nothing about suppression"
            )
        } catch {
            await deepClient.stop()
            await edgeClient.stop()
            await fixture.runtime.stop()
            throw error
        }
        await deepClient.stop()
        await edgeClient.stop()
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
        await client.setContentSource(RecordingVolumesSource(volumes))
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
                chain: transactionServiceHandlers(service)
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
            try await eventually("frontier request") {
                !(await scripted.frontierRequestIDs()).isEmpty
            }
            let captured = await scripted.frontierRequestIDs()
            let requestID = try XCTUnwrap(captured.first)

            // Mismatched requestID: seeds nothing.
            try await sendPage(requestID: requestID &+ 1, leaves: [siblingCID])
            try await alwaysDuring("an uncorrelated page seeds nothing", .milliseconds(300)) {
                !(await fixture.process.hasAcceptedBlock(siblingCID))
            }
            let unsolicited = await fixture.process.hasAcceptedBlock(siblingCID)
            XCTAssertFalse(unsolicited, "an uncorrelated page must seed nothing")

            // The one matching page seeds (leaf 2 walks down to leaf 1).
            try await sendPage(requestID: requestID, leaves: [block2CID])
            try await eventually("matching page seeds the leaf") {
                await fixture.process.hasAcceptedBlock(block2CID)
            }

            // A second matching page: the request is consumed.
            try await sendPage(requestID: requestID, leaves: [siblingCID])
            try await alwaysDuring("a repeated page seeds nothing", .milliseconds(300)) {
                !(await fixture.process.hasAcceptedBlock(siblingCID))
            }
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
                chain: inertNetworkHandlers()
            )
            try await connectAndHello(
                client,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            try await eventually("hello reply announcement") {
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
            try await eventually("tip announcement") {
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
    func testRangeSyncGapIsMeasuredAgainstTheFetchedTip() async throws {
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
                chain: inertNetworkHandlers()
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
            try await alwaysDuring("one past the tip is the edge, not a gap", .milliseconds(300)) {
                await topics.count(of: NodeNetworkTopic.ancestorRangeRequest) == 0
            }
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
                chain: transactionServiceHandlers(producerService)
            )
            try await joiner.runtime.start(
                process: joiner.process,
                chain: joinerHandlers
            )
            try await eventually("joiner validates the canonical tip") {
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
                chain: joinerHandlers
            )
            try await eventually("joiner weighs the losing sibling") {
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
                chain: transactionServiceHandlers(producerService)
            )
            try await joiner.runtime.start(
                process: joiner.process,
                chain: joinerHandlers
            )
            try await eventually("joiner validates X's tip") {
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
            let producerFrontier = try await producer.process.store.acceptedLeafPage(
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
                chain: joinerHandlers
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
            try await eventually("joiner assembles both subtrees") {
                let joinerX = await joiner.process.subtreeWeight(of: x3CID)
                let joinerY = await joiner.process.subtreeWeight(of: y3CID)
                return joinerX == producerX && joinerY == producerY
            }
            try await eventually("joiner settles on X") {
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
                chain: transactionServiceHandlers(
                    producerService,
                    inventoryRequests: producerInventory
                )
            )
            try await joiner.runtime.start(
                process: joiner.process,
                chain: transactionServiceHandlers(
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

            try await eventually("joiner validates the live block") {
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
                chain: transactionServiceHandlers(producerService)
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
                chain: transactionServiceHandlers(
                    joinerService,
                    admissions: joinerAdmissions
                )
            )
            try await eventually("joiner validates the announced block") {
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
    func testHelloReplyAdvertisesTheFetchedTip() async throws {
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
                chain: inertNetworkHandlers()
            )
            try await connectAndHello(
                client,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            try await eventually("hello reply announcement") {
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
        // The runtime probes range-sync re-entry one request timeout after
        // each clear (`scheduleRangeSyncReentry`).
        let reentryInterval: Duration = .milliseconds(300)
        let fixture = try await overlayRuntime(
            keyByte: 0xc5,
            requestTimeout: reentryInterval
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
            RecordingVolumesSource(volumes)
        )
        let service = networkService(
            process: fixture.process,
            runtime: fixture.runtime
        )
        do {
            try await fixture.runtime.start(
                process: fixture.process,
                chain: transactionServiceHandlers(service)
            )
            try await connectAndHello(
                liarClient,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            try await eventually("liar negotiated once") {
                await liar.ancestorRequestCount() >= 1
            }
            // Four re-entry windows: a retained claim would be re-picked.
            try await alwaysDuring("a demoted claim is not re-picked", reentryInterval * 4) {
                await liar.ancestorRequestCount() == 1
            }
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
            try await eventually("honest peer syncs the chain") {
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
    func testRangeSyncAnchorsAtTheFetchedTip() async throws {
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
                chain: inertNetworkHandlers()
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
            let anchorValue = await fixture.runtime.debugSnapshot().rangeSyncAnchor
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

    /// The frontier pull is gated on the PER-PEER edge — our acquired tip
    /// against THAT peer own claimed height — never on whether some other peer
    /// holds the single range-sync slot. A peer genuinely above our edge is
    /// therefore not pulled while a sync runs, and still not pulled once it
    /// clears: the answer follows the heights, not the slot.
    func testNoFrontierPullFromAPeerAboveOurEdge() async throws {
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
        let aboveEdge = FrontierRequestCapturingPeer()
        let aboveEdgeClient = Ivy(config: IvyConfig(
            signingKey: signingKey(0x73),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        await aboveEdgeClient.installTestDelegate(aboveEdge)
        do {
            try await fixture.runtime.start(
                process: fixture.process,
                chain: inertNetworkHandlers()
            )
            try await connectAndHello(
                deepClient,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            try await eventually("deep sync in flight") {
                await deep.ancestorRequestCount() >= 1
            }
            try await connectAndHello(
                aboveEdgeClient,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            try await eventually("aboveEdge hello landed") {
                await aboveEdge.count(of: NodeNetworkTopic.blockAnnouncement) >= 1
            }
            guard case .enqueued = await aboveEdgeClient.sendMessage(
                to: fixture.peerID,
                topic: NodeNetworkTopic.blockAnnouncement,
                payload: try BlockAnnouncementMessage(
                    blockCID: testCID("above-edge-tip"),
                    height: 50
                ).encoded()
            ) else {
                throw NetworkTestError.failedSend
            }
            try await alwaysDuring("a peer above our edge is not pulled", .milliseconds(400)) {
                await aboveEdge.count(of: NodeNetworkTopic.acceptedLeavesRequest) == 0
            }
            let duringSync = await aboveEdge.count(
                of: NodeNetworkTopic.acceptedLeavesRequest
            )
            XCTAssertEqual(duringSync, 0, "a peer above our edge is not pulled")

            // The deep peer leaves and the slot is released: still no pull,
            // because it was this peer own height — not the slot — that put it
            // out of reach of the edge test.
            await deepClient.stop()
            try await alwaysDuring("above the edge, slot or no slot", .milliseconds(400)) {
                await aboveEdge.count(of: NodeNetworkTopic.acceptedLeavesRequest) == 0
            }
            let afterClear = await aboveEdge.count(
                of: NodeNetworkTopic.acceptedLeavesRequest
            )
            XCTAssertEqual(afterClear, 0, "above the edge, slot or no slot")
        } catch {
            await deepClient.stop()
            await aboveEdgeClient.stop()
            await fixture.runtime.stop()
            throw error
        }
        await deepClient.stop()
        await aboveEdgeClient.stop()
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
                chain: inertNetworkHandlers()
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
            try await eventually("negotiated anchor committed") {
                (await fixture.runtime.debugSnapshot().rangeSyncAnchor)?.afterCID
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
}
