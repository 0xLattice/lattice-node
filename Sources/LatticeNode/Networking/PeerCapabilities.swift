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
    /// By session ID: the chain rendezvous the session's peer was named under.
    private var hosting: [Data: Set<String>] = [:]

    /// Replaces the whole view with the sessions now open.
    func set(_ sessions: [(peer: AuthenticatedPeer, capabilities: Set<String>)]) {
        lock.withLock {
            self.sessions = sessions
            let open = Set(sessions.map(\.peer.sessionID))
            revoked = revoked.filter { open.contains($0.key) }
            hosting = hosting.filter { open.contains($0.key) }
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

    /// The open sessions that host the chain whose rendezvous is `key`: the
    /// peers the overlay names there now (`providers`), and those it named
    /// earlier in their session. A process hosts the same chains for as long
    /// as it runs, while the overlay's record of it may be displaced. As the
    /// record is, this is a hint for whom to ask, never for what to accept.
    func hosts(of key: String, providers: [PeerID]) -> [AuthenticatedPeer] {
        let providers = Set(providers)
        return lock.withLock {
            for session in sessions where providers.contains(session.peer.id) {
                hosting[session.peer.sessionID, default: []].insert(key)
            }
            return sessions.map(\.peer).filter { hosting[$0.sessionID]?.contains(key) == true }
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
