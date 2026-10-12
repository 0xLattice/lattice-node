import Foundation
import Ivy
import Tally

/// What the hello of each session now open said the peer speaks beyond the
/// base protocol, for readers off the runtime loop. A message added to the
/// protocol is sent only to a session listed here with its capability: a peer
/// that never advertised it may end the session of whoever sends it. A
/// capability belongs to the session whose hello named it, never to the peer
/// key: a peer that reconnects is judged by its new hello.
///
/// A session keeps a capability only while it honours it: `revoke` takes one
/// from the session that broke it, for as long as that session lasts.
final class PeerCapabilities: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [(peer: AuthenticatedPeer, capabilities: Set<String>)] = []
    /// By session ID: what an open session advertised and no longer has.
    private var revoked: [Data: Set<String>] = [:]

    /// Replaces the whole view with the sessions now open.
    func set(_ sessions: [(peer: AuthenticatedPeer, capabilities: Set<String>)]) {
        lock.withLock {
            self.sessions = sessions
            let open = Set(sessions.map(\.peer.sessionID))
            revoked = revoked.filter { open.contains($0.key) }
        }
    }

    func revoke(_ capability: String, from session: AuthenticatedPeer) {
        let taken = lock.withLock {
            guard sessions.contains(where: { $0.peer.sessionID == session.sessionID }) else { return false }
            return revoked[session.sessionID, default: []].insert(capability).inserted
        }
        // Said once per session: a fleet falling back to the base protocol
        // must be visible.
        guard taken else { return }
        FileHandle.standardError.write(Data(
            "lattice-node: \(capability) no longer asked of \(session.key.hex.prefix(12)) this session\n".utf8
        ))
    }

    /// A chain's current peers: the open sessions that serve it. Nexus
    /// (`child` nil) is served by every session, since every node hosts it;
    /// a child by the sessions whose hello named it, and by those its
    /// rendezvous names, so a peer whose build predates the hello's claim
    /// still counts. A hint for whom to ask, never for what to accept.
    func sessions(hosting child: ChainHosts?, ivy: Ivy) async -> [AuthenticatedPeer] {
        guard let child else { return lock.withLock { sessions.map(\.peer) } }
        let named = Set(await ivy.providers(for: child.key))
        let capability = ChainHandshake.hosting(child.path)
        return lock.withLock {
            sessions.filter { $0.capabilities.contains(capability) || named.contains($0.peer.id) }.map(\.peer)
        }
    }

    func sessions(speaking capability: String) -> [AuthenticatedPeer] {
        lock.withLock {
            sessions.filter {
                $0.capabilities.contains(capability)
                    && revoked[$0.peer.sessionID]?.contains(capability) != true
            }.map(\.peer)
        }
    }
}
