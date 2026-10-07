import Foundation
import Ivy

/// What the hello of each session now open said the peer speaks beyond the
/// base protocol, for readers off the runtime loop. A message added to the
/// protocol is sent only to a session listed here with its capability: a peer
/// that never advertised it may end the session of whoever sends it. A
/// capability belongs to the session whose hello named it, never to the peer
/// key: a peer that reconnects is judged by its new hello.
final class PeerCapabilities: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [(peer: AuthenticatedPeer, capabilities: Set<String>)] = []

    /// Replaces the whole view with the sessions now open.
    func set(_ sessions: [(peer: AuthenticatedPeer, capabilities: Set<String>)]) {
        lock.withLock { self.sessions = sessions }
    }

    func sessions(speaking capability: String) -> [AuthenticatedPeer] {
        lock.withLock { sessions.filter { $0.capabilities.contains(capability) }.map(\.peer) }
    }
}
