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
    /// The same answer with the host's public-submit declaration. A host that
    /// accepts submits sends it BEFORE the v1 answer, so a reader that knows
    /// it records the flag and one that does not (an unknown topic is dropped)
    /// still gets the URL from v1. A v1 answer alone means no submit.
    static let responseV2 = "lattice.overlay.read-endpoint.response.v2"
}

/// One declared endpoint: its URL and whether its host says it accepts
/// `POST /transactions` there. Both unverified.
struct DeclaredReadEndpoint: Equatable, Sendable {
    let url: String
    let acceptsSubmit: Bool
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
    /// Connect when needed, then send the request; true when it dialed a
    /// session for this request.
    let ask: @Sendable (PeerEndpoint, ReadEndpointRequestMessage) async -> Bool
    /// Close a session `ask` dialed, once its lookup is over.
    let release: @Sendable (PeerEndpoint) async -> Void

    /// The node's overlay: providers from the DHT, a dial when no session.
    static func overlay(_ ivy: Ivy, keep: Set<String> = []) -> ReadEndpointTransport {
        ReadEndpointTransport(
            providers: { await ivy.discoverProviders(rootCID: $0) },
            ask: { provider, request in
                guard let key = try? PeerKey(provider.publicKey),
                      let payload = try? request.encoded() else { return false }
                let peer = PeerID(publicKey: key.hex)
                var dialed = false
                if !(await ivy.connectedPeers).contains(peer) {
                    guard !Task.isCancelled, (try? await ivy.connect(to: provider)) != nil else { return false }
                    dialed = true
                }
                _ = await ivy.sendMessage(to: peer, topic: ReadEndpointTopic.request, payload: payload)
                return dialed
            },
            release: { provider in
                guard let key = try? PeerKey(provider.publicKey), !keep.contains(key.hex) else { return }
                await ivy.disconnect(PeerID(publicKey: key.hex))
            }
        )
    }
}

/// The v2 answer: the v1 fields and the host's submit declaration.
struct ReadEndpointResponseV2Message: CanonicalJSONMessage, Equatable, Sendable {
    let chainPath: [String]
    let requestID: UInt64
    let url: String
    let acceptsSubmit: Bool

    func validate() throws {
        guard _isAbsoluteChainPath(chainPath), NodeConfiguration.isValidPublicReadURL(url) else {
            throw OverlayWireError.malformed
        }
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

    private var cache: [[String]: (at: Double, urls: [DeclaredReadEndpoint])] = [:]
    private var inFlight: [[String]: Task<[DeclaredReadEndpoint], Never>] = [:]
    private var lookups: [UInt64: Lookup] = [:]
    /// Each request in flight: its lookup and the peer it was sent to.
    private var requests: [UInt64: (lookup: UInt64, peerKey: String)] = [:]
    private var nextID: UInt64 = 1
    /// Lookups holding each session they dialed: closed only when none does.
    private var dialHolds: [PeerEndpoint: Int] = [:]

    private struct Lookup {
        let chainPath: [String]
        /// Nil until the providers are found and asked.
        var unanswered: Set<UInt64>?
        var urls: [DeclaredReadEndpoint] = []
        var perResponder: [String: Int] = [:]
        var asks: [Task<Void, Never>] = []
        /// Sessions dialed only for this lookup: closed when it ends.
        var dialed: [PeerEndpoint] = []
        var waiter: CheckedContinuation<[DeclaredReadEndpoint], Never>?
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
    func lookup(_ chainPath: [String]) async -> [DeclaredReadEndpoint] {
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

    private func fresh(_ entry: (at: Double, urls: [DeclaredReadEndpoint])) -> Bool {
        clock() - entry.at < (entry.urls.isEmpty ? min(cacheSeconds, Self.emptyCacheSeconds) : cacheSeconds)
    }

    /// A response from an authenticated peer: counted only as the answer to
    /// a request this directory sent that peer, for the path it asked.
    func receive(_ response: ReadEndpointResponseMessage, from peerKey: String) {
        receive(response.chainPath, response.requestID, response.url, acceptsSubmit: false, from: peerKey)
    }

    func receive(_ response: ReadEndpointResponseV2Message, from peerKey: String) {
        receive(response.chainPath, response.requestID, response.url,
                acceptsSubmit: response.acceptsSubmit, from: peerKey)
    }

    /// A URL already recorded is merged, not counted again: a host that
    /// accepts submits answers twice (v2, then v1) with the same URL. Its
    /// submit flag, once declared, stays.
    private func receive(
        _ chainPath: [String], _ requestID: UInt64, _ url: String, acceptsSubmit: Bool, from peerKey: String
    ) {
        guard let request = requests[requestID], request.peerKey == peerKey,
              var lookup = lookups[request.lookup], lookup.chainPath == chainPath else { return }
        if let index = lookup.urls.firstIndex(where: { $0.url == url }) {
            if acceptsSubmit, !lookup.urls[index].acceptsSubmit {
                lookup.urls[index] = DeclaredReadEndpoint(url: url, acceptsSubmit: true)
            }
        } else {
            guard lookup.perResponder[peerKey, default: 0] < Self.perResponderCap else { return }
            lookup.perResponder[peerKey, default: 0] += 1
            lookup.urls.append(DeclaredReadEndpoint(url: url, acceptsSubmit: acceptsSubmit))
        }
        lookup.unanswered?.remove(requestID)
        lookups[request.lookup] = lookup
        if lookup.unanswered?.isEmpty == true { finish(request.lookup) }
    }

    /// One lookup under one deadline, provider discovery included.
    private func run(_ chainPath: [String]) async -> [DeclaredReadEndpoint] {
        let lookupID = nextID
        nextID += 1
        lookups[lookupID] = Lookup(chainPath: chainPath)
        let key = ReadEndpointKey.key(nexusGenesisCID: nexusGenesisCID, chainPath: chainPath)
        let transport = transport
        let discovery = Task {
            let providers = await transport.providers(key)
            self.ask(lookupID, providers)
        }
        let (seconds, attoseconds) = deadline.components
        let nanoseconds = UInt64(max(0, seconds)) * 1_000_000_000 + UInt64(max(0, attoseconds) / 1_000_000_000)
        let timer = Task {
            _ = await Timers.sleep(nanoseconds: nanoseconds)
            self.finish(lookupID)
        }
        let urls = await withCheckedContinuation { continuation in
            lookups[lookupID]?.waiter = continuation
            if lookups[lookupID]?.unanswered?.isEmpty == true { finish(lookupID) }
        }
        timer.cancel()
        discovery.cancel()
        return urls
    }

    /// Ask up to `maximumAsked` of the providers found, unless the lookup
    /// already ended.
    private func ask(_ lookupID: UInt64, _ providers: [PeerEndpoint]) {
        guard var lookup = lookups[lookupID] else { return }
        var seen: Set<String> = [ownKey]
        let asked = providers.shuffled()
            .compactMap { provider in (try? PeerKey(provider.publicKey)).map { (provider, $0.hex) } }
            .filter { seen.insert($0.1).inserted }
            .prefix(Self.maximumAsked)
        var unanswered: Set<UInt64> = []
        let transport = transport
        for (provider, peerKey) in asked {
            let requestID = nextID
            nextID += 1
            requests[requestID] = (lookupID, peerKey)
            unanswered.insert(requestID)
            let message = ReadEndpointRequestMessage(chainPath: lookup.chainPath, requestID: requestID)
            lookup.asks.append(Task {
                if await transport.ask(provider, message) { await self.dialed(lookupID, provider) }
            })
        }
        lookup.unanswered = unanswered
        lookups[lookupID] = lookup
        if unanswered.isEmpty { finish(lookupID) }
    }

    private func dialed(_ lookupID: UInt64, _ provider: PeerEndpoint) async {
        dialHolds[provider, default: 0] += 1
        if lookups[lookupID] != nil {
            lookups[lookupID]?.dialed.append(provider)
        } else {
            await drop(provider)
        }
    }

    /// One lookup's hold on a dialed session ends; the last one closes it.
    private func drop(_ provider: PeerEndpoint) async {
        let holds = (dialHolds[provider] ?? 1) - 1
        dialHolds[provider] = holds > 0 ? holds : nil
        if holds <= 0 { await transport.release(provider) }
    }

    /// Answer a peer's request: a URL only for a level this node hosts.
    static func answer(
        _ request: ReadEndpointRequestMessage, hosted: Set<[String]>, url: String?
    ) -> ReadEndpointResponseMessage? {
        guard let url, hosted.contains(request.chainPath) else { return nil }
        return ReadEndpointResponseMessage(chainPath: request.chainPath, requestID: request.requestID, url: url)
    }

    /// The v2 answer sent before `answer`'s, only when this host accepts
    /// public submits: a host without it answers exactly as before.
    static func answerV2(
        _ request: ReadEndpointRequestMessage, hosted: Set<[String]>, url: String?, acceptsSubmit: Bool
    ) -> ReadEndpointResponseV2Message? {
        guard acceptsSubmit, let v1 = answer(request, hosted: hosted, url: url) else { return nil }
        return ReadEndpointResponseV2Message(
            chainPath: v1.chainPath, requestID: v1.requestID, url: v1.url, acceptsSubmit: true
        )
    }

    /// End a lookup: answer its waiter, stop its asks, and close the
    /// sessions it dialed.
    private func finish(_ lookupID: UInt64) {
        guard let lookup = lookups[lookupID], let waiter = lookup.waiter else { return }
        lookups[lookupID] = nil
        requests = requests.filter { $0.value.lookup != lookupID }
        for ask in lookup.asks { ask.cancel() }
        let dialed = lookup.dialed
        if !dialed.isEmpty {
            Task { for provider in dialed { await self.drop(provider) } }
        }
        waiter.resume(returning: lookup.urls)
    }
}
