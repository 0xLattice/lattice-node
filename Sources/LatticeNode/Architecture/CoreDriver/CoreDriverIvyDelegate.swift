import Foundation
import Ivy
import Tally

/// What the overlay tells the run loop, as plain values. The delegate only
/// forwards: sessions, hello and every decision are the loop's.
enum CoreDriverNetworkInput: Sendable {
    case connected(AuthenticatedPeer)
    case disconnected(peerKey: String)
    case message(AuthenticatedPeer, topic: String, payload: Data)
}

final class CoreDriverIvyDelegate: IvyDelegate {
    private let forward: @Sendable (CoreDriverNetworkInput) -> Void

    init(_ forward: @escaping @Sendable (CoreDriverNetworkInput) -> Void) {
        self.forward = forward
    }

    func ivy(_ ivy: Ivy, didConnect peer: AuthenticatedPeer) async {
        forward(.connected(peer))
    }

    func ivy(_ ivy: Ivy, didDisconnect peer: PeerID) {
        guard let key = try? PeerKey(peer.publicKey) else { return }
        forward(.disconnected(peerKey: key.hex))
    }

    func ivy(_ ivy: Ivy, didReceiveMessage message: PeerMessage, from peer: AuthenticatedPeer) async {
        forward(.message(peer, topic: message.topic, payload: message.payload))
    }
}

extension Ivy {
    func installCoreDriver(delegate: IvyDelegate, contentSource: any IvyContentSource) {
        self.delegate = delegate
        setContentSource(contentSource)
    }
}
