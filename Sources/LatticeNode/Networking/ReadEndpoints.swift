import Foundation
import Ivy
import Tally

/// Operator-declared public read URLs, discovered over the overlay. One rule
/// at every level: a node answers "your read URL for chain P" only for a
/// level it hosts, and a node hosting P's parent finds the hosts of P through
/// the provider records they announce under P's read-endpoint key. Answers
/// are UNVERIFIED claims: a reader accepts one only after the URL serves the
/// block P's parent commits under P's directory.
enum ReadEndpointTopic {
    static let request = "lattice.overlay.read-endpoint.request.v1"
    static let response = "lattice.overlay.read-endpoint.response.v1"
}

/// "Your declared read URL for `chainPath`?"
struct ReadEndpointRequestMessage: CanonicalJSONMessage, Equatable, Sendable {
    let chainPath: [String]
    let requestID: UInt64

    func validate() throws {
        guard _isAbsoluteChainPath(chainPath) else { throw OverlayWireError.malformed }
    }
}

/// The answer: sent only by a host of `chainPath` that declared a URL; no
/// answer means no.
struct ReadEndpointResponseMessage: CanonicalJSONMessage, Equatable, Sendable {
    static let maximumURLBytes = 512

    let chainPath: [String]
    let requestID: UInt64
    let url: String

    func validate() throws {
        guard _isAbsoluteChainPath(chainPath), NodeConfiguration.isValidPublicReadURL(url) else {
            throw OverlayWireError.malformed
        }
    }
}

enum ReadEndpointKey {
    /// The provider-record key a host of `chainPath` with a declared read URL
    /// announces: scoped to the Nexus it runs under, so two networks sharing
    /// a DHT never mix.
    static func key(nexusGenesisCID: String, chainPath: [String]) -> String {
        "lattice.read-endpoint.v1:\(nexusGenesisCID):\(chainPath.joined(separator: "/"))"
    }
}

/// What the directory needs from the overlay.
struct ReadEndpointTransport: Sendable {
    /// Provider endpoints announced under a key.
    let providers: @Sendable (String) async -> [PeerEndpoint]
    /// Connect when needed, then send the request. Fire and forget.
    let ask: @Sendable (PeerEndpoint, ReadEndpointRequestMessage) async -> Void

    /// The node's overlay: providers from the DHT, a dial when no session.
    static func overlay(_ ivy: Ivy) -> ReadEndpointTransport {
        ReadEndpointTransport(
            providers: { await ivy.discoverProviders(rootCID: $0) },
            ask: { provider, request in
                guard let key = try? PeerKey(provider.publicKey),
                      let payload = try? request.encoded() else { return }
                let peer = PeerID(publicKey: key.hex)
                if !(await ivy.connectedPeers).contains(peer) {
                    try? await ivy.connect(to: provider)
                }
                _ = await ivy.sendMessage(to: peer, topic: ReadEndpointTopic.request, payload: payload)
            }
        )
    }
}

/// Bounded lookups of the read URLs other hosts declare for a chain: at most
/// `maximumAsked` providers (shuffled, so a crowd of announcers cannot pick
/// who is asked), at most `perResponderCap` URLs from any one responder, one
/// shared deadline, identical concurrent lookups coalesced, results cached
/// for `cacheSeconds` (an empty one for `emptyCacheSeconds`, so a host that
/// just announced is found soon).
actor ReadEndpointDirectory {
    static let maximumAsked = 8
    static let perResponderCap = 2
    static let emptyCacheSeconds = 5.0

    private let transport: ReadEndpointTransport
    private let nexusGenesisCID: String
    private let ownKey: String
    private let deadline: Duration
    private let cacheSeconds: Double
    private let clock: @Sendable () -> Double

    private var cache: [[String]: (at: Double, urls: [String])] = [:]
    private var inFlight: [[String]: Task<[String], Never>] = [:]
    private var lookups: [UInt64: Lookup] = [:]
    /// Each request in flight: its lookup and the peer it was sent to.
    private var requests: [UInt64: (lookup: UInt64, peerKey: String)] = [:]
    private var nextID: UInt64 = 1

    private struct Lookup {
        let chainPath: [String]
        var unanswered: Set<UInt64>
        var urls: [String] = []
        var perResponder: [String: Int] = [:]
        var waiter: CheckedContinuation<[String], Never>?
    }

    init(
        transport: ReadEndpointTransport,
        nexusGenesisCID: String,
        ownKey: String,
        deadline: Duration = .seconds(2),
        cacheSeconds: Double = 30,
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) {
        self.transport = transport
        self.nexusGenesisCID = nexusGenesisCID
        self.ownKey = ownKey
        self.deadline = deadline
        self.cacheSeconds = cacheSeconds
        self.clock = clock
    }

    /// The URLs other hosts declared for `chainPath`, unverified.
    func lookup(_ chainPath: [String]) async -> [String] {
        if let cached = cache[chainPath], fresh(cached) { return cached.urls }
        if let running = inFlight[chainPath] { return await running.value }
        let task = Task { await self.run(chainPath) }
        inFlight[chainPath] = task
        let urls = await task.value
        inFlight[chainPath] = nil
        cache[chainPath] = (clock(), urls)
        // Expired entries go when the next lookup lands, so the cache holds
        // at most the paths asked for within one window.
        cache = cache.filter { fresh($0.value) }
        return urls
    }

    private func fresh(_ entry: (at: Double, urls: [String])) -> Bool {
        clock() - entry.at < (entry.urls.isEmpty ? min(cacheSeconds, Self.emptyCacheSeconds) : cacheSeconds)
    }

    /// A response from an authenticated peer: counted only as the answer to
    /// a request this directory sent that peer, for the path it asked.
    func receive(_ response: ReadEndpointResponseMessage, from peerKey: String) {
        guard let request = requests[response.requestID], request.peerKey == peerKey,
              var lookup = lookups[request.lookup], lookup.chainPath == response.chainPath,
              lookup.perResponder[peerKey, default: 0] < Self.perResponderCap else { return }
        lookup.perResponder[peerKey, default: 0] += 1
        if !lookup.urls.contains(response.url) { lookup.urls.append(response.url) }
        lookup.unanswered.remove(response.requestID)
        lookups[request.lookup] = lookup
        if lookup.unanswered.isEmpty { finish(request.lookup) }
    }

    private func run(_ chainPath: [String]) async -> [String] {
        let key = ReadEndpointKey.key(nexusGenesisCID: nexusGenesisCID, chainPath: chainPath)
        var seen: Set<String> = [ownKey]
        let asked = (await transport.providers(key)).shuffled()
            .compactMap { provider in (try? PeerKey(provider.publicKey)).map { (provider, $0.hex) } }
            .filter { seen.insert($0.1).inserted }
            .prefix(Self.maximumAsked)
        guard !asked.isEmpty else { return [] }
        let lookupID = nextID
        nextID += 1
        var sends: [(PeerEndpoint, ReadEndpointRequestMessage)] = []
        for (provider, peerKey) in asked {
            let requestID = nextID
            nextID += 1
            requests[requestID] = (lookupID, peerKey)
            sends.append((provider, ReadEndpointRequestMessage(chainPath: chainPath, requestID: requestID)))
        }
        lookups[lookupID] = Lookup(chainPath: chainPath, unanswered: Set(sends.map(\.1.requestID)))
        let transport = transport
        for (provider, message) in sends {
            Task { await transport.ask(provider, message) }
        }
        let (seconds, attoseconds) = deadline.components
        let nanoseconds = UInt64(max(0, seconds)) * 1_000_000_000 + UInt64(max(0, attoseconds) / 1_000_000_000)
        let timer = Task {
            _ = await Timers.sleep(nanoseconds: nanoseconds)
            self.finish(lookupID)
        }
        let urls = await withCheckedContinuation { continuation in
            lookups[lookupID]?.waiter = continuation
            if lookups[lookupID]?.unanswered.isEmpty ?? true { finish(lookupID) }
        }
        timer.cancel()
        return urls
    }

    /// Answer a peer's request: a URL only for a level this node hosts.
    static func answer(
        _ request: ReadEndpointRequestMessage, hosted: Set<[String]>, url: String?
    ) -> ReadEndpointResponseMessage? {
        guard let url, hosted.contains(request.chainPath) else { return nil }
        return ReadEndpointResponseMessage(chainPath: request.chainPath, requestID: request.requestID, url: url)
    }

    private func finish(_ lookupID: UInt64) {
        guard let lookup = lookups[lookupID], let waiter = lookup.waiter else { return }
        lookups[lookupID] = nil
        requests = requests.filter { $0.value.lookup != lookupID }
        waiter.resume(returning: lookup.urls)
    }
}
