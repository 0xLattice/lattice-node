import Foundation
import Ivy
import Tally

/// What the overlay tells the run loop, as plain values. The delegate only
/// forwards and decodes: sessions, hello and every decision are the loop's.
enum CoreDriverNetworkInput: Sendable {
    case connected(AuthenticatedPeer)
    case disconnected(peerKey: String)
    case hello(AuthenticatedPeer, payload: Data)
    case sync(AuthenticatedPeer, chainPath: [String], CoreSyncMessage)
}

/// Bounded room for overlay messages between the delegate and the loop. A
/// delivering connection waits for room, so a peer that sends faster than
/// the loop steps is held back by its own connection (Ivy's backpressure),
/// never buffered without bound. The loop frees room as it handles each
/// message; `close` frees every waiter for good.
actor CoreDriverInputGate {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var closed = false

    init(capacity: Int) {
        available = capacity
    }

    func acquire() async {
        guard !closed else { return }
        guard available == 0 else {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    func close() {
        closed = true
        let woken = waiters
        waiters.removeAll()
        for waiter in woken { waiter.resume() }
    }
}

final class CoreDriverIvyDelegate: IvyDelegate {
    private let forward: @Sendable (CoreDriverNetworkInput) -> Void
    private let gate: CoreDriverInputGate

    init(gate: CoreDriverInputGate, _ forward: @escaping @Sendable (CoreDriverNetworkInput) -> Void) {
        self.gate = gate
        self.forward = forward
    }

    func ivy(_ ivy: Ivy, didConnect peer: AuthenticatedPeer) async {
        forward(.connected(peer))
    }

    func ivy(_ ivy: Ivy, didDisconnect peer: PeerID) {
        guard let key = try? PeerKey(peer.publicKey) else { return }
        forward(.disconnected(peerKey: key.hex))
    }

    /// Decoded here, off the loop. A frame of another topic, or a malformed
    /// one, is dropped: only the core blames, and only for proof-of-work.
    func ivy(_ ivy: Ivy, didReceiveMessage message: PeerMessage, from peer: AuthenticatedPeer) async {
        let input: CoreDriverNetworkInput
        if message.topic == NodeNetworkTopic.overlayHello {
            input = .hello(peer, payload: message.payload)
        } else if let decoded = try? CoreWire.decode(topic: message.topic, payload: message.payload) {
            input = .sync(peer, chainPath: decoded.chainPath, decoded.message)
        } else {
            return
        }
        await gate.acquire()
        forward(input)
    }
}

extension Ivy {
    func installCoreDriver(delegate: IvyDelegate, contentSource: any IvyContentSource) {
        self.delegate = delegate
        setContentSource(contentSource)
    }
}
