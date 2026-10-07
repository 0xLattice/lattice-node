import Crypto
import Foundation
import Ivy
import Tally
import XCTest
@testable import LatticeNode

/// After a large message fills a session's send buffer, the transport refuses
/// further sends as backpressured. The outbox must deliver them anyway, in
/// order, once the session drains - a reply refused and dropped left the
/// requester waiting until its deadline disconnected a peer that had answered.
final class SessionOutboxTests: XCTestCase {
    private final class Recorder: IvyDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var _connected: [AuthenticatedPeer] = []
        private var _topics: [String] = []

        var connected: [AuthenticatedPeer] { lock.withLock { _connected } }
        var topics: [String] { lock.withLock { _topics } }

        func ivy(_ ivy: Ivy, didConnect peer: AuthenticatedPeer) async {
            lock.withLock { _connected.append(peer) }
        }

        func ivy(_ ivy: Ivy, didReceiveMessage message: PeerMessage, from peer: AuthenticatedPeer) async {
            lock.withLock { _topics.append(message.topic) }
        }
    }

    private struct Pair {
        let server: Ivy
        let client: Ivy
        let serverRecorder: Recorder
        let clientRecorder: Recorder
        /// The client, as the server's session sees it.
        let clientPeer: AuthenticatedPeer
    }

    private func connectedPair() async throws -> Pair {
        func config(_ key: Curve25519.Signing.PrivateKey, _ port: UInt16) -> IvyConfig {
            IvyConfig(
                signingKey: key,
                listenPort: port,
                requestTimeout: .seconds(5),
                stunServers: [],
                healthConfig: PeerHealthConfig(enabled: false),
                externalAddress: ("127.0.0.1", port),
                mode: .overlay
            )
        }
        let (serverKey, clientKey) = (Curve25519.Signing.PrivateKey(), Curve25519.Signing.PrivateKey())
        let (serverPort, clientPort) = (NetworkTransportTestPorts.allocate(), NetworkTransportTestPorts.allocate())
        let server = Ivy(config: config(serverKey, serverPort))
        let client = Ivy(config: config(clientKey, clientPort))
        let (serverRecorder, clientRecorder) = (Recorder(), Recorder())
        await server.setTestDelegateForOutbox(serverRecorder)
        await client.setTestDelegateForOutbox(clientRecorder)
        try await server.start()
        try await client.start()
        addTeardownBlock {
            await client.stop()
            await server.stop()
        }
        try await client.connect(to: PeerEndpoint(
            publicKey: serverKey.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined(), host: "127.0.0.1", port: serverPort
        ))
        try await waitUntil { !serverRecorder.connected.isEmpty && !clientRecorder.connected.isEmpty }
        return Pair(
            server: server, client: client,
            serverRecorder: serverRecorder, clientRecorder: clientRecorder,
            clientPeer: try XCTUnwrap(serverRecorder.connected.first)
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(10),
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("condition not met within \(timeout)")
    }

    func testRepliesAfterALargePageAreDeliveredInOrder() async throws {
        let pair = try await connectedPair()
        // Without the outbox, these replies are refused as backpressured.
        let page = Data(repeating: 7, count: 1_000_000)
        let probe = await pair.server.sendMessage(to: pair.clientPeer, topic: "probe", payload: Data([0]))
        XCTAssertTrue(probe.isEnqueued)
        _ = await pair.server.sendMessage(to: pair.clientPeer, topic: "page", payload: page)
        let refused = await pair.server.sendMessage(to: pair.clientPeer, topic: "dropped", payload: Data([1]))
        XCTAssertEqual(refused, .backpressured, "the transport refuses sends while a large page drains")

        // Refill the buffer: wait for it to drain, then a second page is
        // accepted and the replies queued after it meet backpressure.
        let drained = await pair.server.waitUntilWritable(to: pair.clientPeer)
        XCTAssertTrue(drained)
        let secondPage = await pair.server.sendMessage(to: pair.clientPeer, topic: "page-2", payload: page)
        XCTAssertTrue(secondPage.isEnqueued)
        let outbox = SessionOutbox(ivy: pair.server)
        var deliveries: [Task<Bool, Never>] = []
        for index in 0..<3 {
            deliveries.append(await outbox.send(to: pair.clientPeer, topic: "reply-\(index)", payload: Data([UInt8(index)])))
        }
        for delivery in deliveries {
            let delivered = await delivery.value
            XCTAssertTrue(delivered)
        }
        try await waitUntil { pair.clientRecorder.topics.contains("reply-2") }
        let replies = pair.clientRecorder.topics.filter { $0.hasPrefix("reply-") }
        XCTAssertEqual(replies, ["reply-0", "reply-1", "reply-2"])
    }

    func testQueuedMessagesFinishWhenTheSessionEnds() async throws {
        let pair = try await connectedPair()
        let outbox = SessionOutbox(ivy: pair.server)
        let page = Data(repeating: 7, count: 1_000_000)
        _ = await pair.server.sendMessage(to: pair.clientPeer, topic: "page", payload: page)
        let queued = await outbox.send(to: pair.clientPeer, topic: "after", payload: Data([1]))
        await pair.client.stop()
        // Delivered before the close or abandoned after it - never left hanging.
        let finished = Task { await queued.value }
        let outcome = await withTaskGroup(of: Bool?.self) { group in
            group.addTask { await finished.value }
            group.addTask { try? await Task.sleep(for: .seconds(10)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        XCTAssertNotNil(outcome, "a queued send must finish once its session ends")
    }
}

/// A transport that refuses sends as backpressured until `drain()`, then
/// accepts them; or, once `end()` is called, reports the session gone.
private actor ScriptedTransport {
    enum Mode { case backpressured, accepting, ended }
    private var mode: Mode = .backpressured
    private(set) var sent: [String] = []
    private(set) var waits = 0
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func send(_ topic: String) -> SendMessageResult {
        switch mode {
        case .backpressured: return .backpressured
        case .ended: return .notConnected
        case .accepting:
            sent.append(topic)
            return .enqueued(endpoint: PeerID(publicKey: "peer"), route: .direct)
        }
    }

    func waitUntilWritable() async -> Bool {
        waits += 1
        switch mode {
        case .accepting: return true
        case .ended: return false
        case .backpressured: return await withCheckedContinuation { waiters.append($0) }
        }
    }

    func drain() { release(.accepting, true) }
    func end() { release(.ended, false) }

    private func release(_ next: Mode, _ writable: Bool) {
        mode = next
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume(returning: writable) }
    }
}

final class SessionOutboxDeliveryTests: XCTestCase {
    private func outbox(_ transport: ScriptedTransport) -> SessionOutbox {
        SessionOutbox(
            send: { _, topic, _ in await transport.send(topic) },
            waitUntilWritable: { _ in await transport.waitUntilWritable() }
        )
    }

    private let peer = AuthenticatedPeer(
        key: try! PeerKey(String(repeating: "ab", count: 32)),
        role: .endpoint,
        route: .direct,
        metadata: PeerMetadata(listenAddresses: []),
        sessionID: Data(repeating: 1, count: 32)
    )

    func testBackpressuredSendsWaitForTheSessionToDrainThenDeliverInOrder() async throws {
        let transport = ScriptedTransport()
        let outbox = outbox(transport)
        let deliveries = await (0..<3).asyncMap { await outbox.send(to: self.peer, topic: "reply-\($0)", payload: Data()) }
        try await Task.sleep(for: .milliseconds(100))
        let sentWhileFull = await transport.sent
        XCTAssertTrue(sentWhileFull.isEmpty, "nothing is sent while the session is full")
        let waits = await transport.waits
        XCTAssertGreaterThanOrEqual(waits, 1)

        await transport.drain()
        for delivery in deliveries {
            let delivered = await delivery.value
            XCTAssertTrue(delivered)
        }
        let sent = await transport.sent
        XCTAssertEqual(sent, ["reply-0", "reply-1", "reply-2"])
    }

    func testQueuedSendsFinishUndeliveredWhenTheSessionEnds() async throws {
        let transport = ScriptedTransport()
        let outbox = outbox(transport)
        let deliveries = await (0..<3).asyncMap { await outbox.send(to: self.peer, topic: "m\($0)", payload: Data()) }
        try await Task.sleep(for: .milliseconds(50))
        await transport.end()
        for delivery in deliveries {
            let delivered = await delivery.value
            XCTAssertFalse(delivered)
        }
        let sent = await transport.sent
        XCTAssertTrue(sent.isEmpty)
    }

    func testASessionsQueueIsBounded() async throws {
        let transport = ScriptedTransport()
        let outbox = outbox(transport)
        for index in 0..<SessionOutbox.maximumQueuedPerSession {
            await outbox.send(to: peer, topic: "m\(index)", payload: Data())
        }
        let overflow = await outbox.send(to: peer, topic: "overflow", payload: Data())
        let accepted = await overflow.value
        XCTAssertFalse(accepted, "past the bound a send is refused at once")
        await transport.end()
    }
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var results: [T] = []
        for element in self { results.append(await transform(element)) }
        return results
    }
}

private extension SendMessageResult {
    var isEnqueued: Bool {
        if case .enqueued = self { return true }
        return false
    }
}

private extension Ivy {
    func setTestDelegateForOutbox(_ delegate: IvyDelegate) {
        self.delegate = delegate
    }
}
