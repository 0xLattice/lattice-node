// Arrival-rate limits for the public read listener.
//
// A node exposing `--public-read-port` directly has no proxy in front of it,
// so nothing else bounds how fast the public internet can ask it for the
// expensive reads. The read-replica gets these limits from nginx
// (deploy/read-replica/nginx.conf); a directly exposed node has to enforce
// them itself, and the numbers here are that file's, not taste.
//
// Client identity is the peer socket address and nothing else. A directly
// exposed node has no trusted header, so a forwarded-for header is never read.
// The corollary is the reason the per-client zones ship disabled on the
// testnet follower: behind fly-proxy every client arrives from ONE observed
// address, and a per-client limit keyed on it throttles the whole internet as
// a single user. The listener-wide ceiling is address-agnostic and stays on.

import ArgumentParser
import Dispatch
import HTTPTypes
import Hummingbird
import NIOCore

/// The three operator-settable ceilings, in requests per second. `0` disables
/// that ceiling; all three `0` is fully off.
struct PublicReadRateLimits: Sendable {
    /// nginx `limit_req_zone zone=reads rate=25r/s`.
    static let defaultGeneralRate = 25.0
    /// nginx `limit_req_zone zone=expensive rate=1r/s`.
    static let defaultExpensiveRate = 1.0
    /// nginx `limit_req_zone zone=global rate=200r/s`.
    static let defaultListenerRate = 200.0

    // nginx states burstiness as an absolute token count (`burst=`). Carried
    // here as `burst ÷ rate` — the SECONDS of traffic one full bank holds — so
    // an operator who changes a rate keeps the tuned burstiness instead of
    // silently keeping a bank sized for the old one. At the defaults these
    // reproduce nginx exactly: 50/25 = 2, 10/1 = 10, 200/200 = 1.
    static let generalBankSeconds = 2.0
    static let expensiveBankSeconds = 10.0
    static let listenerBankSeconds = 1.0

    var generalRate: Double
    var expensiveRate: Double
    var listenerRate: Double

    static let `default` = PublicReadRateLimits(
        generalRate: defaultGeneralRate,
        expensiveRate: defaultExpensiveRate,
        listenerRate: defaultListenerRate
    )

    private init(generalRate: Double, expensiveRate: Double, listenerRate: Double) {
        self.generalRate = generalRate
        self.expensiveRate = expensiveRate
        self.listenerRate = listenerRate
    }

    /// Refuse bad input by the flag name that carried it. A `precondition`
    /// here would trap the whole node on a typo in a unit file.
    static func validated(
        generalRate: Double,
        expensiveRate: Double,
        listenerRate: Double
    ) throws -> PublicReadRateLimits {
        PublicReadRateLimits(
            generalRate: try checked(generalRate, flag: "--public-read-rate"),
            expensiveRate: try checked(
                expensiveRate, flag: "--public-read-expensive-rate"
            ),
            listenerRate: try checked(
                listenerRate, flag: "--public-read-max-rate"
            )
        )
    }

    private static func checked(_ value: Double, flag: String) throws -> Double {
        guard value.isFinite, value >= 0 else {
            throw ValidationError(
                "\(flag) must be a finite requests-per-second value of 0 or more (0 disables that ceiling)"
            )
        }
        return value
    }

    var isFullyDisabled: Bool {
        generalRate <= 0 && expensiveRate <= 0 && listenerRate <= 0
    }

    /// What the startup banner prints, so an operator reads the LIVE values
    /// rather than the documented defaults.
    var bannerDescription: String {
        func describe(_ rate: Double) -> String {
            rate <= 0 ? "off" : "\(rate)/s"
        }
        return "general \(describe(generalRate)), "
            + "expensive \(describe(expensiveRate)), "
            + "listener \(describe(listenerRate))"
    }
}

/// Which budget a request is billed to. One-for-one with the nginx
/// `zone=expensive` locations, plus the health-check exemption.
enum PublicReadRouteClass: Sendable, Equatable {
    /// Exempt from every bucket, per-client AND listener-wide. A platform
    /// health check that public load can throttle turns load into a DEPOOLED
    /// MACHINE — on the testnet follower that machine carries Nexus, the child
    /// and the grandchild, so a cheap flood would become a total outage. The
    /// cost of that exemption is bounded by collapsing the work instead: the
    /// public listener serves /health from a short-TTL cached snapshot
    /// (`ShortTTLSnapshotCache`), so a flood costs one read per TTL however
    /// fast it arrives — a strictly tighter bound than a rate limit, which
    /// would still admit `--public-read-max-rate` walks per second.
    case exempt
    case general
    /// A recent-block walk, a peer fan-out, or hundreds of content fetches.
    case expensive

    /// Classified by splitting the path EXACTLY as the router resolves it.
    /// Hummingbird's `splitSequence` omits empty components, so
    /// `//api/block//<cid>/children/` reaches the expensive handler; a
    /// classifier comparing the raw path string would bill it to the cheap
    /// budget and hand an attacker the expensive routes at the general rate.
    /// `String.split(separator:)` omits empty subsequences by default, which is
    /// the same rule.
    init(method: HTTPRequest.Method, path: String) {
        let components = path.split(separator: "/")
        switch components.count {
        case 1 where components[0] == "health":
            // The exemption exists for ONE reason: a platform health check must
            // never be refused. Those are GET (fly's `http_checks`) or HEAD, so
            // nothing legitimate needs it under another method, and leaving it
            // method-insensitive would hand a caller a free, unmetered path to
            // the router — a `POST /health` 404 that no bucket ever sees.
            self = (method == .get || method == .head) ? .exempt : .general
        case 2 where components[0] == "v1" && components[1] == "blocks":
            // The recent-block list. `/v1/blocks/<cid>` is block DETAIL and
            // stays general, exactly as in nginx.
            self = .expensive
        case 3 where components[0] == "api"
            && components[1] == "chain" && components[2] == "endpoints":
            self = .expensive
        case 4 where components[0] == "api" && components[1] == "block"
            && (components[3] == "transactions" || components[3] == "children"):
            self = .expensive
        default:
            self = .general
        }
    }
}

/// One value, recomputed at most once per `ttl` however often it is asked for,
/// with concurrent askers coalesced onto a single in-flight load.
///
/// This is what bounds `/health`, which is exempt from every rate limit. Its
/// handler is not free — `readSnapshot()` is actor-isolated on `ChainProcess`,
/// the same actor serving sync and block admission, and `Cache-Control` only
/// asks the CLIENT to cache, so without this every request pays. The TTL is the
/// max-age the node already advertises for that snapshot, so serving one that
/// old from memory changes no contract it does not already publish.
actor ShortTTLSnapshotCache<Value: Sendable> {
    private let ttl: Double
    private let clock: @Sendable () -> Double
    private let load: @Sendable () async -> Value
    private var cached: (value: Value, at: Double)?
    private var inFlight: Task<Value, Never>?

    init(
        ttl: Double,
        clock: @escaping @Sendable () -> Double = PublicReadRateLimiter.monotonicSeconds,
        load: @escaping @Sendable () async -> Value
    ) {
        self.ttl = ttl
        self.clock = clock
        self.load = load
    }

    func value() async -> Value {
        if let cached, clock() - cached.at < ttl { return cached.value }
        // Coalesce: without this a burst arriving on a cold cache would each
        // start their own walk, which is the stampede the cache exists to stop.
        if let inFlight { return await inFlight.value }
        let task = Task { [load] in await load() }
        inFlight = task
        let value = await task.value
        inFlight = nil
        // Timestamped at load COMPLETION, not at its start. The content is as
        // of the start, so true staleness is `ttl + loadDuration` and can
        // exceed the advertised max-age under a slow tip walk. That is
        // deliberate: timestamping at the start would make any load slower than
        // the TTL land already-expired, so every request would reload and the
        // cache would stop bounding anything in exactly the case it exists for
        // — a slow node under load. Bounded extra staleness is the better trade
        // than losing the work bound.
        cached = (value, clock())
        return value
    }
}

/// Token buckets: one pair per tracked client plus one for the whole listener.
///
/// Known gap, stated rather than solved: nginx's per-client `limit_conn` (a cap
/// on one client's IN-FLIGHT requests) has no analogue here. A router
/// middleware sees requests, not connection lifetime, so a token bucket bounds
/// requests STARTED, never requests RESIDENT. Concurrency is therefore bounded
/// only indirectly, through arrival rate — and that bound loosens exactly when
/// handler latency rises, which is when it matters most.
actor PublicReadRateLimiter {
    private struct Bucket {
        let capacity: Double
        let refillPerSecond: Double
        var tokens: Double
        var updatedAt: Double

        init(rate: Double, bankSeconds: Double, now: Double) {
            // At least one token, so a deliberately tiny rate still admits a
            // request eventually instead of refusing everything forever.
            self.capacity = max(1, rate * bankSeconds)
            self.refillPerSecond = rate
            self.tokens = self.capacity
            self.updatedAt = now
        }

        private func refilled(at now: Double) -> Double {
            min(capacity, tokens + max(0, now - updatedAt) * refillPerSecond)
        }

        mutating func take(at now: Double) -> Bool {
            tokens = refilled(at: now)
            updatedAt = now
            guard tokens >= 1 else { return false }
            tokens -= 1
            return true
        }

        /// The time this bank is full again — i.e. the time it stops being
        /// worth any memory.
        func refillCompletion() -> Double {
            guard refillPerSecond > 0 else { return .infinity }
            let deficit = capacity - tokens
            return deficit > 0 ? updatedAt + deficit / refillPerSecond : updatedAt
        }
    }

    /// One client's two budgets, mirroring nginx's two per-client zones.
    private struct ClientBuckets {
        var general: Bucket?
        var expensive: Bucket?

        func refillCompletion() -> Double {
            max(
                general?.refillCompletion() ?? -.infinity,
                expensive?.refillCompletion() ?? -.infinity
            )
        }
    }

    private let limits: PublicReadRateLimits
    private let clock: @Sendable () -> Double
    /// The tracked-client map is a CEILING, never a growth path. Derived, not
    /// picked: an entry is only worth holding while it is still draining, so
    /// the bound is the fastest traffic can arrive (the highest configured
    /// rate) times the longest a bank takes to refill.
    private let clientCeiling: Int
    private var clients: [String: ClientBuckets] = [:]
    /// The earliest time any tracked entry could be fully refilled, and so the
    /// earliest a sweep could free anything. A sweep is O(map), and it runs on
    /// the per-client path which precedes the listener check — so without this
    /// gate an attacker cycling source addresses would pay one full scan per
    /// request at ARRIVAL rate, turning a cheap request into a large one. Kept
    /// as a lower bound: inserts lower it, a sweep recomputes it exactly, so it
    /// can never miss an eviction. It does NOT promise only one futile scan —
    /// refreshing the currently-minimal entry just before its completion and
    /// then presenting a new source address re-arms the gate — but each such
    /// scan is O(ceiling), it takes an event to trigger, and the listener
    /// bucket caps the rate of those events. Strictly better than the ungated
    /// form, which scanned on every insert once the map sat at ceiling.
    private var earliestPossibleEviction = Double.infinity
    private var listener: Bucket?

    /// `nil` when every ceiling is `0`: fully off costs nothing at all.
    init?(
        limits: PublicReadRateLimits,
        clock: @escaping @Sendable () -> Double = PublicReadRateLimiter.monotonicSeconds
    ) {
        guard !limits.isFullyDisabled else { return nil }
        self.limits = limits
        self.clock = clock
        let peakRate = max(
            limits.generalRate, limits.expensiveRate, limits.listenerRate
        )
        let longestBank = max(
            PublicReadRateLimits.generalBankSeconds,
            PublicReadRateLimits.expensiveBankSeconds
        )
        self.clientCeiling = max(1, Int((peakRate * longestBank).rounded(.up)))
        if limits.listenerRate > 0 {
            self.listener = Bucket(
                rate: limits.listenerRate,
                bankSeconds: PublicReadRateLimits.listenerBankSeconds,
                now: clock()
            )
        }
    }

    static func monotonicSeconds() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    /// Per-client budget first, then the listener-wide one — a request already
    /// refused by its own budget never reaches the node, so charging the
    /// listener for it would spend other clients' headroom on an attacker.
    func admit(client: String, route: PublicReadRouteClass) -> Bool {
        guard route != .exempt else { return true }
        let now = clock()
        guard takePerClient(client: client, route: route, now: now) else {
            return false
        }
        return takeListener(now: now)
    }

    /// Test-only view of the map ceiling.
    var trackedClientCount: Int { clients.count }

    private func takePerClient(
        client: String, route: PublicReadRouteClass, now: Double
    ) -> Bool {
        let expensive = route == .expensive
        let rate = expensive ? limits.expensiveRate : limits.generalRate
        guard rate > 0 else { return true }
        let bank = expensive
            ? PublicReadRateLimits.expensiveBankSeconds
            : PublicReadRateLimits.generalBankSeconds

        var buckets: ClientBuckets
        if let existing = clients[client] {
            buckets = existing
        } else {
            if clients.count >= clientCeiling, now >= earliestPossibleEviction {
                // Fully refilled entries hold no state worth keeping, so they
                // are what makes room.
                clients = clients.filter { $0.value.refillCompletion() > now }
                earliestPossibleEviction = clients.values
                    .map { $0.refillCompletion() }.min() ?? .infinity
            }
            guard clients.count < clientCeiling else {
                // Untracked rather than tracked-badly: the listener ceiling
                // alone bounds this request. This state is attacker-SUSTAINABLE
                // — enough distinct addresses hold the map full and new clients
                // then get no per-client budget — and that is the deliberate
                // fallback, not an oversight: in exactly that scenario the
                // listener bucket is the binding constraint anyway. It is the
                // reason the listener ceiling must not also be disabled on a
                // directly exposed node.
                return true
            }
            buckets = ClientBuckets()
        }

        var bucket = (expensive ? buckets.expensive : buckets.general)
            ?? Bucket(rate: rate, bankSeconds: bank, now: now)
        let admitted = bucket.take(at: now)
        if expensive { buckets.expensive = bucket } else { buckets.general = bucket }
        clients[client] = buckets
        earliestPossibleEviction = min(
            earliestPossibleEviction, buckets.refillCompletion()
        )
        return admitted
    }

    private func takeListener(now: Double) -> Bool {
        guard var bucket = listener else { return true }
        let admitted = bucket.take(at: now)
        listener = bucket
        return admitted
    }
}

/// The public listener's request context. `BasicRequestContext` carries no peer
/// address, and the peer socket is the only client identity a directly exposed
/// node has.
struct PublicReadRequestContext: RemoteAddressRequestContext {
    var coreContext: CoreRequestContextStorage
    let remoteAddress: SocketAddress?

    init(source: ApplicationRequestContextSource) {
        self.coreContext = .init(source: source)
        self.remoteAddress = source.channel.remoteAddress
    }
}

struct PublicReadRateLimitMiddleware<Context: RemoteAddressRequestContext>: RouterMiddleware {
    let limiter: PublicReadRateLimiter

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard await limiter.admit(
            client: Self.clientKey(context.remoteAddress),
            route: PublicReadRouteClass(
                method: request.method, path: request.uri.path
            )
        ) else {
            throw HTTPError(.tooManyRequests)
        }
        return try await next(request, context)
    }

    /// Keyed on the address with the PORT DROPPED: a client opening a fresh
    /// connection per request gets a fresh source port, and keying on it would
    /// make every request a new client with a full bank. No forwarded-for
    /// header is consulted — there is no trusted proxy in front of this
    /// listener, so any such header is attacker-chosen.
    ///
    /// Two properties a future change must not break:
    /// - A peer that is neither IP nor unix-domain keys to `""`, collapsing
    ///   every such peer into one bucket. Not reachable on a TCP listener.
    /// - The whole IPv6 address is the key, which is only safe because this
    ///   listener binds `0.0.0.0` and therefore only ever sees IPv4 peers. A
    ///   single IPv6 client is routinely handed a /64, so if this ever becomes
    ///   dual-stack the key MUST become the /64 prefix — otherwise one client
    ///   owns 2^64 independent banks and the per-client ceiling means nothing.
    static func clientKey(_ address: SocketAddress?) -> String {
        guard let address else { return "" }
        return address.ipAddress ?? address.pathname ?? ""
    }
}
