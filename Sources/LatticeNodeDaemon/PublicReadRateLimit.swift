// Arrival-rate limits for the public read listener.
//
// A node exposing `--public-read-port` directly has no proxy in front of it,
// so nothing else bounds how fast the public internet can ask it for reads.
// The limits are listener-wide ceilings, never per client: a client is not an
// identity the node can know (behind a proxy every client arrives from one
// address), and a busy node sheds load by the listener's total, whoever sent
// it.

import ArgumentParser
import Dispatch
import HTTPTypes
import Hummingbird

/// The operator-settable ceilings, in requests per second. `0` disables
/// that ceiling; both `0` is fully off.
struct PublicReadRateLimits: Sendable {
    /// nginx `limit_req_zone zone=global rate=200r/s`.
    static let defaultListenerRate = 200.0
    /// Listener-wide ceiling for `POST /transactions` when public submit is
    /// on: its own budget, so submits never spend the read budget or the
    /// reverse. No nginx analogue (the read replica serves no submit).
    static let defaultSubmitRate = 10.0

    // nginx states burstiness as an absolute token count (`burst=`). Carried
    // here as `burst ÷ rate` — the SECONDS of traffic one full bank holds — so
    // an operator who changes a rate keeps the tuned burstiness instead of
    // silently keeping a bank sized for the old one. At the default this
    // reproduces nginx exactly: 200/200 = 1.
    static let listenerBankSeconds = 1.0
    static let submitBankSeconds = 2.0

    var listenerRate: Double
    var submitRate: Double

    static let `default` = PublicReadRateLimits(
        listenerRate: defaultListenerRate,
        submitRate: defaultSubmitRate
    )

    private init(listenerRate: Double, submitRate: Double) {
        self.listenerRate = listenerRate
        self.submitRate = submitRate
    }

    /// Refuse bad input by the flag name that carried it. A `precondition`
    /// here would trap the whole node on a typo in a unit file.
    static func validated(
        listenerRate: Double,
        submitRate: Double = defaultSubmitRate
    ) throws -> PublicReadRateLimits {
        PublicReadRateLimits(
            listenerRate: try checked(
                listenerRate, flag: "--public-read-max-rate"
            ),
            submitRate: try checked(submitRate, flag: "--public-submit-rate")
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
        listenerRate <= 0 && submitRate <= 0
    }
}

/// Which budget a request is billed to.
enum PublicReadRouteClass: Sendable, Equatable {
    /// Exempt from every bucket. A platform health check that public load can
    /// throttle turns load into a DEPOOLED MACHINE — on the testnet follower
    /// that machine carries Nexus, the child and the grandchild, so a cheap
    /// flood would become a total outage. The cost of that exemption is
    /// bounded by collapsing the work instead: the public listener serves
    /// /health from a short-TTL cached snapshot (`ShortTTLSnapshotCache`), so a
    /// flood costs one read per TTL however fast it arrives — a strictly
    /// tighter bound than a rate limit, which would still admit
    /// `--public-read-max-rate` walks per second.
    case exempt
    case read
    /// `POST /transactions` (public submit): the listener's separate submit
    /// budget, never the read budget.
    case submit

    /// Classified by splitting the path EXACTLY as the router resolves it.
    /// Hummingbird's `splitSequence` omits empty components, so `//health//`
    /// reaches the health handler; `String.split(separator:)` omits empty
    /// subsequences by default, which is the same rule.
    init(method: HTTPRequest.Method, path: String) {
        let components = path.split(separator: "/")
        switch components.count {
        case 1 where components[0] == "transactions" && method == .post:
            self = .submit
        case 1 where components[0] == "health":
            // The exemption exists for ONE reason: a platform health check must
            // never be refused. Those are GET (fly's `http_checks`) or HEAD, so
            // nothing legitimate needs it under another method, and leaving it
            // method-insensitive would hand a caller a free, unmetered path to
            // the router — a `POST /health` 404 that no bucket ever sees.
            self = (method == .get || method == .head) ? .exempt : .read
        default:
            self = .read
        }
    }
}

/// One value, recomputed at most once per `ttl` however often it is asked for,
/// with concurrent askers coalesced onto a single in-flight load.
///
/// This is what bounds `/health`, which is exempt from every rate limit. Its
/// handler is not free — `readSnapshot()` is actor-isolated on `NodeStorage`,
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

/// Token buckets: one for the read listener, one for public submit.
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

        mutating func take(at now: Double) -> Bool {
            tokens = min(capacity, tokens + max(0, now - updatedAt) * refillPerSecond)
            updatedAt = now
            guard tokens >= 1 else { return false }
            tokens -= 1
            return true
        }
    }

    private let clock: @Sendable () -> Double
    private var listener: Bucket?
    private var submitListener: Bucket?

    /// `nil` when every ceiling is `0`: fully off costs nothing at all.
    init?(
        limits: PublicReadRateLimits,
        clock: @escaping @Sendable () -> Double = PublicReadRateLimiter.monotonicSeconds
    ) {
        guard !limits.isFullyDisabled else { return nil }
        self.clock = clock
        if limits.listenerRate > 0 {
            self.listener = Bucket(
                rate: limits.listenerRate,
                bankSeconds: PublicReadRateLimits.listenerBankSeconds,
                now: clock()
            )
        }
        if limits.submitRate > 0 {
            self.submitListener = Bucket(
                rate: limits.submitRate,
                bankSeconds: PublicReadRateLimits.submitBankSeconds,
                now: clock()
            )
        }
    }

    static func monotonicSeconds() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    func admit(route: PublicReadRouteClass) -> Bool {
        switch route {
        case .exempt:
            return true
        case .read:
            return Self.take(&listener, at: clock())
        case .submit:
            return Self.take(&submitListener, at: clock())
        }
    }

    private static func take(_ bucket: inout Bucket?, at now: Double) -> Bool {
        bucket?.take(at: now) ?? true
    }
}

struct PublicReadRateLimitMiddleware<Context: RequestContext>: RouterMiddleware {
    let limiter: PublicReadRateLimiter

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard await limiter.admit(
            route: PublicReadRouteClass(
                method: request.method, path: request.uri.path
            )
        ) else {
            throw HTTPError(.tooManyRequests)
        }
        return try await next(request, context)
    }
}
