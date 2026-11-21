import Ivy
import LatticeNodeCore

/// Where browsers reach this node, as it advertises to its peers
/// (`Ivy.setWebAddresses`): the URL its operator declared, or else one
/// connected peer that listens for browsers itself, to be dialled at that
/// peer's URL and relayed through it.
enum WebAddresses {
    /// A connected peer that relays and advertised a URL of its own: one
    /// this node can be reached through. `preferred` when it hosts the parent of the
    /// deepest chain this node hosts.
    struct Candidate {
        let key: PeerKey
        let url: String
        let preferred: Bool
    }

    /// The addresses to advertise. Without a declared URL, the relay
    /// advertised now is kept while it is still a candidate, so the address
    /// does not change under the browsers that found it; otherwise the
    /// candidate with the smallest key, preferred ones first. No candidate,
    /// none.
    static func choose(declared: String?, current: [WebAddress], candidates: [Candidate]) -> [WebAddress] {
        if let declared { return [WebAddress(url: declared)] }
        let chosen = candidates.first { $0.key == current.first?.via }
            ?? candidates.min { ($0.preferred ? 0 : 1, $0.key.hex) < ($1.preferred ? 0 : 1, $1.key.hex) }
        return chosen.map { [WebAddress(url: $0.url, via: $0.key)] } ?? []
    }
}

extension NodeRuntime.Loop {
    /// Advertises where browsers reach this node, when that changed: at
    /// each maintenance pass, and when a session becomes ready or is lost.
    /// A peer's own URL is known before its hello (Ivy sends it first on
    /// every session); one it changes later is picked up by the next pass.
    mutating func refreshWebAddresses() async {
        var candidates: [WebAddresses.Candidate] = []
        if configuration.webSocketURL == nil {
            let deepest = core.ordered.max { $0.count < $1.count } ?? core.rootPath
            let parent = Array(deepest.dropLast())
            // A relay reaches this node only over a session of its own to
            // it, and only a peer whose hello says it relays will.
            for session in sessions.values where session.ready && session.peer.route == .direct
                && session.capabilities.contains(ChainHandshake.relay) {
                guard let url = await ivy.webAddresses(of: session.peer.id)?.first(where: { $0.via == nil })?.url
                else { continue }
                candidates.append(.init(
                    key: session.peer.key, url: url,
                    preferred: parent.count <= core.rootPath.count
                        || session.capabilities.contains(ChainHandshake.hosting(parent))))
            }
        }
        let next = WebAddresses.choose(
            declared: configuration.webSocketURL, current: webAddresses, candidates: candidates)
        guard next != webAddresses else { return }
        webAddresses = next
        await ivy.setWebAddresses(next)
    }
}
