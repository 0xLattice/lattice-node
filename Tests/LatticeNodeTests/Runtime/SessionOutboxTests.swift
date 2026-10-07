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
        // A large page fills the session's send buffer; replies queued right
        // behind it may meet backpressure (whether they do depends on how fast
        // the page drains - the scripted-transport tests cover that path
        // deterministically). Either way, every reply must arrive, in order.
        let page = Data(repeating: 7, count: 1_000_000)
        _ = await pair.server.sendMessage(to: pair.clientPeer, topic: "page", payload: page)
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

    func testTheOperatorsQueuedByteBudgetBoundsASession() async throws {
        let transport = ScriptedTransport()
        let outbox = SessionOutbox(
            send: { _, topic, _ in await transport.send(topic) },
            waitUntilWritable: { _ in await transport.waitUntilWritable() },
            maximumQueuedBytesPerSession: 2_048
        )
        let page = Data(count: 1_024)
        _ = await outbox.send(to: peer, topic: "page-0", payload: page)
        _ = await outbox.send(to: peer, topic: "page-1", payload: page)
        let overflow = await outbox.send(to: peer, topic: "overflow", payload: page)
        let refused = await finishes(overflow, within: .seconds(2))
        XCTAssertEqual(refused, false, "past the operator's byte budget a send is refused at once")
        await transport.end()
    }

    /// The byte budget bounds backlog: a session with nothing queued takes
    /// one message of any size, so the smallest budget still delivers.
    func testAMessageIntoAnEmptySessionIsTakenWhateverTheByteBudget() async throws {
        let transport = ScriptedTransport()
        let outbox = SessionOutbox(
            send: { _, topic, _ in await transport.send(topic) },
            waitUntilWritable: { _ in await transport.waitUntilWritable() },
            maximumQueuedBytesPerSession: 1
        )
        let page = Data(count: 1_024 * 1_024)
        let first = await outbox.send(to: peer, topic: "first", payload: page)
        let behind = await outbox.send(to: peer, topic: "behind", payload: page)
        let refused = await finishes(behind, within: .seconds(2))
        XCTAssertEqual(refused, false, "the budget bounds what queues behind the first message")
        await transport.drain()
        let firstDelivered = await first.value
        XCTAssertTrue(firstDelivered)
        // The lane empties in the delivery's follow-up; allow it a moment.
        var delivered = false
        for _ in 0..<100 where !delivered {
            delivered = await outbox.send(to: peer, topic: "after-drain", payload: page).value
            if !delivered { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertTrue(delivered)
        let sent = await transport.sent
        XCTAssertEqual(sent, ["first", "after-drain"])
    }

    func testASessionsQueuedBytesAreBounded() async throws {
        let transport = ScriptedTransport()
        let outbox = outbox(transport)
        let page = Data(count: 1_024 * 1_024)
        let fitting = outbox.maximumQueuedBytesPerSession / page.count
        var queued: [Task<Bool, Never>] = []
        for index in 0..<fitting {
            queued.append(await outbox.send(to: peer, topic: "page-\(index)", payload: page))
        }
        let overflow = await outbox.send(to: peer, topic: "overflow", payload: page)
        let refused = await finishes(overflow, within: .seconds(2))
        XCTAssertEqual(refused, false, "past the byte bound a send is refused at once, not queued")
        // Draining frees the bound once the queued pages are delivered.
        await transport.drain()
        for task in queued { _ = await task.value }
        // Freed bytes are returned by each delivery's follow-up; allow it a moment.
        var delivered = false
        for _ in 0..<100 where !delivered {
            delivered = await outbox.send(to: peer, topic: "after-drain", payload: page).value
            if !delivered { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertTrue(delivered)
    }

    func testASessionsQueueIsBounded() async throws {
        let transport = ScriptedTransport()
        let outbox = outbox(transport)
        for index in 0..<SessionOutbox.maximumQueuedPerSession {
            await outbox.send(to: peer, topic: "m\(index)", payload: Data())
        }
        let overflow = await outbox.send(to: peer, topic: "overflow", payload: Data())
        let refused = await finishes(overflow, within: .seconds(2))
        XCTAssertEqual(refused, false, "past the bound a send is refused at once, not queued")
        await transport.end()
    }
}

/// The task's result if it finishes within `timeout`; nil if it is still
/// waiting (a send that was queued instead of refused). Returns at the
/// timeout without waiting for the task.
private func finishes(_ task: Task<Bool, Never>, within timeout: Duration) async -> Bool? {
    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool?, Never>?
        init(_ continuation: CheckedContinuation<Bool?, Never>) { self.continuation = continuation }
        func resume(_ value: Bool?) {
            lock.withLock { () -> CheckedContinuation<Bool?, Never>? in
                defer { continuation = nil }
                return continuation
            }?.resume(returning: value)
        }
    }
    return await withCheckedContinuation { continuation in
        let once = Once(continuation)
        Task { once.resume(await task.value) }
        Task { try? await Task.sleep(for: timeout); once.resume(nil) }
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
