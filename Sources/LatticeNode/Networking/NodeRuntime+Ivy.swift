import Foundation
import Ivy
import Tally

/// What the overlay tells the run loop, as plain values. The delegate only
/// forwards and decodes: sessions, hello and every decision are the loop's.
enum NodeRuntimeNetworkInput: Sendable {
    case connected(AuthenticatedPeer)
    case disconnected(peerKey: String)
    case hello(AuthenticatedPeer, payload: Data)
    case sync(AuthenticatedPeer, chainPath: [String], ChainSyncMessage)
    /// A peer announced a transaction by CID.
    case transactionAvailable(AuthenticatedPeer, cid: String)
}

/// Bounded room for overlay messages between the delegate and the loop. A
/// delivering connection waits for room, so a peer that sends faster than
/// the loop steps is held back by its own connection (Ivy's backpressure),
/// never buffered without bound. The loop frees room as it handles each
/// message; `close` frees every waiter for good.
actor NodeRuntimeInputGate {
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

final class NodeRuntimeIvyDelegate: IvyDelegate {
    private let forward: @Sendable (NodeRuntimeNetworkInput) -> Void
    private let gate: NodeRuntimeInputGate
    /// Read-endpoint requests are answered here and responses handed to the
    /// directory: neither touches the chain, so neither enters the loop.
    private let hosted: Set<[String]>
    private let publicReadURL: String?
    private let readEndpoints: ReadEndpointDirectory?

    init(
        gate: NodeRuntimeInputGate,
        hosted: Set<[String]> = [],
        publicReadURL: String? = nil,
        readEndpoints: ReadEndpointDirectory? = nil,
        _ forward: @escaping @Sendable (NodeRuntimeNetworkInput) -> Void
    ) {
        self.gate = gate
        self.hosted = hosted
        self.publicReadURL = publicReadURL
        self.readEndpoints = readEndpoints
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
        let input: NodeRuntimeNetworkInput
        if message.topic == ReadEndpointTopic.request {
            if let request = try? ReadEndpointRequestMessage.decoded(message.payload),
               let response = ReadEndpointDirectory.answer(request, hosted: hosted, url: publicReadURL),
               let payload = try? response.encoded() {
                _ = await ivy.sendMessage(to: peer, topic: ReadEndpointTopic.response, payload: payload)
            }
            return
        } else if message.topic == ReadEndpointTopic.response {
            if let response = try? ReadEndpointResponseMessage.decoded(message.payload) {
                await readEndpoints?.receive(response, from: peer.key.hex)
            }
            return
        } else if message.topic == OverlayTopic.overlayHello {
            input = .hello(peer, payload: message.payload)
        } else if message.topic == OverlayTopic.transactionAvailable,
                  let announced = try? TransactionAvailableMessage.decoded(message.payload) {
            input = .transactionAvailable(peer, cid: announced.volumeRootCID)
        } else if let decoded = try? ChainSyncWire.decode(topic: message.topic, payload: message.payload) {
            input = .sync(peer, chainPath: decoded.chainPath, decoded.message)
        } else {
            return
        }
        await gate.acquire()
        forward(input)
    }
}

extension Ivy {
    func installNodeRuntime(delegate: IvyDelegate, contentSource: any IvyContentSource) {
        self.delegate = delegate
        setContentSource(contentSource)
    }
}
