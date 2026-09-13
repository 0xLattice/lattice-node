import ArgumentParser
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Lattice
import NIOCore
import XCTest
@testable import LatticeNode
@testable import LatticeNodeDaemon

/// The public read listener is the one surface an unauthenticated caller can
/// drive as fast as it likes, and a directly exposed node has no proxy in front
/// of it to bound that. These assert the two things that are easy to get wrong:
/// that a limit exists at all on the expensive routes while `/health` stays
/// exempt, and that the cheap-budget escape hatch — a path the ROUTER resolves
/// to an expensive handler but a raw-string classifier does not — is closed.
final class PublicReadRateLimitTests: XCTestCase {
    private func makeService(
        _ name: String
    ) async throws -> (ChainService, NodeConfiguration) {
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-\(name)-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storage,
            privateKeyHex: String(repeating: "01", count: 32)
        )
        let process = try await ChainProcess.open(configuration: configuration)
        return (
            ChainService(
                process: process,
                childCandidateProvider: { _ in [] },
                childProofPublisher: { _ in },
                acceptedBlockPublisher: { _ in },
            ),
            configuration
        )
    }

    /// At the shipped defaults the expensive per-client budget is 1 r/s with a
    /// 10-second bank: 10 tokens, which 14 back-to-back requests cannot be
    /// covered by (refill over the milliseconds they take is negligible). On a
    /// listener with no limiter installed every one of them is served, so the
    /// 429 assertion is what fails — and `/health` must answer 200 either way,
    /// because a platform health check that public load can throttle turns load
    /// into a depooled machine.
    func testExpensiveRouteIsRefusedAtDefaultsWhileHealthStaysExempt() async throws {
        let (service, configuration) = try await makeService("public-read-rate")
        let app = makePublicReadApplication(
            service: service, host: "127.0.0.1", port: 8081
        )
        let cid = configuration.nexusGenesisCID

        try await app.test(.router) { client in
            var statuses: [Int] = []
            for _ in 0..<14 {
                try await client.execute(
                    uri: "/api/block/\(cid)/children", method: .get
                ) { response in
                    statuses.append(response.status.code)
                }
            }
            XCTAssertTrue(
                statuses.contains(429),
                "14 requests against a 10-token expensive bank must be refused at least once, got \(statuses)"
            )

            try await client.execute(uri: "/health", method: .get) { response in
                XCTAssertEqual(
                    response.status, .ok,
                    "/health is exempt from every limit"
                )
            }
        }
    }

    /// The router resolves a path with `splitSequence`, which omits empty
    /// components, so `//api/block//<cid>/children/` reaches the SAME expensive
    /// handler as the canonical spelling. A classifier that compared the raw
    /// path string would bill those requests to the general budget (50 tokens,
    /// never exhausted here), leave the expensive bank full, and answer the
    /// canonical path with whatever the handler returns instead of a 429.
    func testEscapedSpellingSpendsTheBudgetOfTheRouteItReaches() async throws {
        let (service, configuration) = try await makeService("public-read-escape")
        let app = makePublicReadApplication(
            service: service, host: "127.0.0.1", port: 8081
        )
        let cid = configuration.nexusGenesisCID
        let escaped = "//api/block//\(cid)/children/"

        // The classification itself, stated as an invariant rather than
        // inferred from the HTTP result below.
        XCTAssertEqual(
            PublicReadRouteClass(method: .get, path: escaped), .expensive
        )
        XCTAssertEqual(
            PublicReadRouteClass(method: .get, path: "/api/block/\(cid)/children"),
            .expensive
        )

        try await app.test(.router) { client in
            // Spend the expensive bank ONLY through the escaped spelling.
            for _ in 0..<12 {
                try await client.execute(uri: escaped, method: .get) { _ in }
            }
            try await client.execute(
                uri: "/api/block/\(cid)/children", method: .get
            ) { response in
                XCTAssertEqual(
                    response.status, .tooManyRequests,
                    "the escaped spelling routes to the expensive handler, so it must spend the expensive budget"
                )
            }
        }
    }

    /// Every route's budget, one-for-one with the nginx `zone=expensive`
    /// locations. `/v1/blocks/<cid>` is block DETAIL and stays general.
    func testRouteClassificationMatchesTheExpensiveAllowlist() {
        // Paths only: `URI.path` never carries the query string, so a
        // query-bearing spelling is not an input this ever sees.
        for path in [
            "/v1/blocks",
            "/api/chain/endpoints",
            "/api/block/bafy/transactions",
            "/api/block/bafy/children",
        ] {
            XCTAssertEqual(
                PublicReadRouteClass(method: .get, path: path), .expensive, path
            )
        }
        for path in [
            "/v1/blocks/bafy",
            "/v1/transactions/bafy",
            "/v1/accounts/bafy",
            "/api/block/latest",
            "/api/block/bafy",
            "/api/peers",
            "/api/mempool",
            "/unknown",
        ] {
            XCTAssertEqual(
                PublicReadRouteClass(method: .get, path: path), .general, path
            )
        }
        XCTAssertEqual(PublicReadRouteClass(method: .get, path: "/health"), .exempt)
        XCTAssertEqual(PublicReadRouteClass(method: .head, path: "/health"), .exempt)
        // Matching the router, which omits empty components.
        XCTAssertEqual(PublicReadRouteClass(method: .get, path: "//health//"), .exempt)

        // The exemption exists so a health check cannot be refused, and health
        // checks are GET/HEAD. Any other method must be charged rather than
        // handed a free, unmetered path to a 404.
        for method in [HTTPRequest.Method.post, .put, .delete, .options] {
            XCTAssertEqual(
                PublicReadRouteClass(method: method, path: "/health"),
                .general,
                "\(method) /health must not be exempt"
            )
        }
    }

    /// `URI.path` excludes the query string, so a caller-chosen query cannot
    /// steer an expensive route onto the cheaper budget. Driven over HTTP,
    /// because that is where the classified path actually comes from.
    func testQueryStringDoesNotMoveARequestOffTheExpensiveBudget() async throws {
        let (service, _) = try await makeService("public-read-query")
        let app = makePublicReadApplication(
            service: service, host: "127.0.0.1", port: 8081
        )

        try await app.test(.router) { client in
            var statuses: [Int] = []
            for _ in 0..<12 {
                try await client.execute(
                    uri: "/api/chain/endpoints?chainPath=Nexus/toy", method: .get
                ) { response in
                    statuses.append(response.status.code)
                }
            }
            XCTAssertTrue(
                statuses.contains(429),
                "a query must not move /api/chain/endpoints onto the general budget, got \(statuses)"
            )
        }
    }

    func testBucketsAreIndependentPerClientAndPerBudgetAndRefillOnTheClock() async throws {
        let clock = TestClock()
        let limits = try PublicReadRateLimits.validated(
            generalRate: 25, expensiveRate: 1, listenerRate: 200
        )
        let limiter = try XCTUnwrap(
            PublicReadRateLimiter(limits: limits, clock: { clock.now })
        )

        // Expensive bank: 1 r/s x 10 s = 10 tokens.
        for token in 0..<10 {
            let admitted = await limiter.admit(client: "a", route: .expensive)
            XCTAssertTrue(admitted, "token \(token) must be inside the bank")
        }
        var admitted = await limiter.admit(client: "a", route: .expensive)
        XCTAssertFalse(admitted, "the 11th request exceeds the bank")

        // A different client key carries its own bank.
        admitted = await limiter.admit(client: "b", route: .expensive)
        XCTAssertTrue(admitted)
        // ...and the same client's general budget is a separate bank.
        admitted = await limiter.admit(client: "a", route: .general)
        XCTAssertTrue(admitted)

        // Refill is on the injected clock, never wall time.
        clock.advance(0.5)
        admitted = await limiter.admit(client: "a", route: .expensive)
        XCTAssertFalse(admitted, "half a token is not a token")
        clock.advance(1)
        admitted = await limiter.admit(client: "a", route: .expensive)
        XCTAssertTrue(admitted, "a second of refill at 1 r/s buys one request")

        // The exemption is unconditional, not a large budget.
        for _ in 0..<1_000 {
            let health = await limiter.admit(client: "a", route: .exempt)
            XCTAssertTrue(health)
        }
    }

    /// The tracked-client map is a ceiling, never a growth path: an attacker
    /// cycling source addresses must not be able to make the node allocate.
    func testTrackedClientMapIsCappedAndEvictsRefilledEntriesFirst() async throws {
        let clock = TestClock()
        // Ceiling = max(rate) x longest bank = max(1, 1, 0) x 10 = 10 entries.
        // The listener ceiling is off so this isolates the map.
        let limits = try PublicReadRateLimits.validated(
            generalRate: 1, expensiveRate: 1, listenerRate: 0
        )
        let limiter = try XCTUnwrap(
            PublicReadRateLimiter(limits: limits, clock: { clock.now })
        )

        for index in 0..<10 {
            _ = await limiter.admit(client: "client-\(index)", route: .expensive)
        }
        var tracked = await limiter.trackedClientCount
        XCTAssertEqual(tracked, 10)

        // An 11th address while every tracked bank is still draining: nothing
        // is evictable, so it goes untracked rather than growing the map.
        _ = await limiter.admit(client: "client-overflow", route: .expensive)
        tracked = await limiter.trackedClientCount
        XCTAssertEqual(tracked, 10, "the map must not grow past its ceiling")

        // Once those banks have fully refilled they carry no state worth
        // keeping, so they are the first thing evicted to make room.
        clock.advance(20)
        _ = await limiter.admit(client: "client-late", route: .expensive)
        tracked = await limiter.trackedClientCount
        XCTAssertEqual(
            tracked, 1, "fully refilled entries must be evicted before the map blocks"
        )
    }

    func testAllZeroRatesDisableTheLimiterEntirely() throws {
        let off = try PublicReadRateLimits.validated(
            generalRate: 0, expensiveRate: 0, listenerRate: 0
        )
        XCTAssertTrue(off.isFullyDisabled)
        XCTAssertNil(PublicReadRateLimiter(limits: off))
    }

    /// A bad value in a unit file must name the flag that carried it, not trap
    /// the whole node on a `precondition`.
    func testBadRatesAreRefusedByFlagName() {
        let cases: [(Double, Double, Double, String)] = [
            (-1, 1, 1, "--public-read-rate"),
            (1, -0.5, 1, "--public-read-expensive-rate"),
            (1, 1, .nan, "--public-read-max-rate"),
            (1, 1, .infinity, "--public-read-max-rate"),
        ]
        for (general, expensive, listener, flag) in cases {
            XCTAssertThrowsError(
                try PublicReadRateLimits.validated(
                    generalRate: general,
                    expensiveRate: expensive,
                    listenerRate: listener
                ),
                flag
            ) { error in
                XCTAssertTrue(
                    error is ValidationError,
                    "must be a refusal, not a trap: \(error)"
                )
                XCTAssertTrue(
                    "\(error)".contains(flag),
                    "the refusal must name \(flag), got: \(error)"
                )
            }
        }
    }

    /// The port is dropped: a client opening a fresh connection per request
    /// gets a fresh source port, and keying on it would hand every request a
    /// full bank.
    func testClientKeyDropsThePort() throws {
        let first = try SocketAddress(ipAddress: "203.0.113.7", port: 40_001)
        let second = try SocketAddress(ipAddress: "203.0.113.7", port: 51_999)
        let other = try SocketAddress(ipAddress: "203.0.113.8", port: 40_001)
        typealias Key = PublicReadRateLimitMiddleware<PublicReadRequestContext>
        XCTAssertEqual(Key.clientKey(first), Key.clientKey(second))
        XCTAssertNotEqual(Key.clientKey(first), Key.clientKey(other))
        XCTAssertEqual(Key.clientKey(first), "203.0.113.7")
    }

    /// The defaults are `deploy/read-replica/nginx.conf`'s numbers, and the
    /// banks are its bursts carried as `burst / rate` so an operator changing a
    /// rate keeps the tuned burstiness.
    func testDefaultsReproduceTheReadReplicaLimits() {
        let limits = PublicReadRateLimits.default
        XCTAssertEqual(limits.generalRate, 25)
        XCTAssertEqual(limits.expensiveRate, 1)
        XCTAssertEqual(limits.listenerRate, 200)
        // nginx burst= values: 50, 10, 200.
        XCTAssertEqual(
            limits.generalRate * PublicReadRateLimits.generalBankSeconds, 50
        )
        XCTAssertEqual(
            limits.expensiveRate * PublicReadRateLimits.expensiveBankSeconds, 10
        )
        XCTAssertEqual(
            limits.listenerRate * PublicReadRateLimits.listenerBankSeconds, 200
        )
    }
    /// The deliberate decision behind the `/health` exemption: it is exempt
    /// from the LISTENER bucket too, not just the per-client ones. Charging it
    /// there would mean a sustained flood empties the bucket, the health check
    /// 429s, and the platform depools a machine that carries every chain in the
    /// path — load amplified into an outage. The cost is bounded by collapsing
    /// the work instead (see the snapshot-cache tests below).
    func testExemptRouteIsNotChargedToTheListenerBucketEither() async throws {
        let clock = TestClock()
        // Listener bank = max(1, 1 x 1) = exactly one token.
        let limits = try PublicReadRateLimits.validated(
            generalRate: 0, expensiveRate: 0, listenerRate: 1
        )
        let limiter = try XCTUnwrap(
            PublicReadRateLimiter(limits: limits, clock: { clock.now })
        )

        var admitted = await limiter.admit(client: "a", route: .general)
        XCTAssertTrue(admitted)
        admitted = await limiter.admit(client: "a", route: .general)
        XCTAssertFalse(admitted, "the listener bank is spent")
        // Same instant, same empty listener bucket: the health check still wins.
        for _ in 0..<100 {
            let health = await limiter.admit(client: "a", route: .exempt)
            XCTAssertTrue(
                health,
                "a health check must never be refused by public load"
            )
        }
    }

    /// What bounds `/health` instead of a rate limit: the work collapses.
    func testHealthSnapshotCollapsesAFloodToOneLoadPerInterval() async throws {
        let clock = TestClock()
        let counter = LoadCounter()
        let cache = ShortTTLSnapshotCache<Int>(
            ttl: statusCacheMaxAgeSeconds, clock: { clock.now }
        ) {
            await counter.record()
        }

        for _ in 0..<500 { _ = await cache.value() }
        var loads = await counter.count
        XCTAssertEqual(
            loads, 1, "500 requests inside the TTL must cost one snapshot"
        )

        clock.advance(statusCacheMaxAgeSeconds)
        _ = await cache.value()
        loads = await counter.count
        XCTAssertEqual(loads, 2, "past the TTL it refreshes, once")
    }

    /// A cold cache under a simultaneous burst must not stampede the loader —
    /// otherwise the cache bounds nothing in exactly the case it exists for.
    ///
    /// Structural rather than probabilistic: the loader parks until EVERY
    /// caller has registered, so no load can complete while a caller is still
    /// outside the cache, and a warm-cache read cannot be what satisfies this.
    /// Delete the `if let inFlight` branch and all 200 callers start their own
    /// load, unpark together, and the count lands on 200 — a deterministic
    /// failure, not a race the test usually wins.
    func testConcurrentBurstOnAColdCacheIsCoalescedIntoOneLoad() async throws {
        let clock = TestClock()
        let counter = LoadCounter()
        let callers = 200
        let gate = CallerGate(expected: callers)
        let cache = ShortTTLSnapshotCache<Int>(
            ttl: statusCacheMaxAgeSeconds, clock: { clock.now }
        ) {
            await gate.waitForAll()
            return await counter.record()
        }

        var observed: Set<Int> = []
        await withTaskGroup(of: Int.self) { group in
            for _ in 0..<callers {
                group.addTask {
                    // Registered BEFORE entering the cache, so the loader
                    // cannot finish until every caller is already inside.
                    await gate.register()
                    return await cache.value()
                }
            }
            for await value in group { observed.insert(value) }
        }

        XCTAssertEqual(
            observed, [1], "every caller must observe the one shared load"
        )
        let loads = await counter.count
        XCTAssertEqual(loads, 1, "a concurrent burst must share one load")
    }

    /// `HEAD /health` is exempt from every bucket, so it also has to REACH a
    /// handler. `.autoGenerateHeadEndpoints` is off and only GET was
    /// registered, so without an explicit HEAD route it fell through to the
    /// not-found responder and answered 404 — unmetered, and enough to depool a
    /// live machine, since the read-replica allowlist forwards HEAD
    /// (`limit_except GET HEAD`).
    func testHeadHealthIsRoutedOnBothApplications() async throws {
        let (service, _) = try await makeService("public-read-head-health")
        let publicApp = makePublicReadApplication(
            service: service, host: "127.0.0.1", port: 8081
        )
        let loopback = makeApplication(
            service: service, host: "127.0.0.1", port: 8080
        )

        try await publicApp.test(.router) { client in
            try await client.execute(uri: "/health", method: .head) { response in
                XCTAssertEqual(
                    response.status, .ok, "HEAD /health must reach the handler"
                )
                XCTAssertEqual(
                    response.body.readableBytes, 0,
                    "a HEAD response carries no body"
                )
                XCTAssertEqual(response.headers[.cacheControl], statusCacheControl)
            }
        }
        try await loopback.test(.router) { client in
            try await client.execute(uri: "/health", method: .head) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(response.body.readableBytes, 0)
            }
        }
    }

    /// The live-vs-cached split is the stated reason `lattice status` and the
    /// E2E height polls still work, so it needs an executable invariant on each
    /// side — the cache's own unit tests would stay green if the cached closure
    /// were wired into the loopback application by mistake.
    func testPublicHealthIsCachedWhileLoopbackStaysLive() async throws {
        let (service, _) = try await makeService("public-read-health-wiring")
        // A frozen clock: the public cache cannot expire mid-test, so this
        // asserts the WIRING rather than racing a 3-second wall clock.
        let frozen = TestClock()
        let publicApp = makePublicReadApplication(
            service: service, host: "127.0.0.1", port: 8081,
            healthClock: { frozen.now }
        )
        let loopback = makeApplication(
            service: service, host: "127.0.0.1", port: 8080
        )

        try await loopback.test(.router) { loopbackClient in
            try await publicApp.test(.router) { publicClient in
                let before = try await healthHeight(loopbackClient)
                let publicBefore = try await healthHeight(publicClient)
                XCTAssertEqual(publicBefore, before)

                _ = try await mineOneBlock(client: loopbackClient)

                let loopbackAfter = try await healthHeight(loopbackClient)
                XCTAssertEqual(
                    loopbackAfter, before + 1,
                    "loopback /health must read the live snapshot"
                )
                let publicAfter = try await healthHeight(publicClient)
                XCTAssertEqual(
                    publicAfter, publicBefore,
                    "public /health must serve the cached snapshot"
                )
            }
        }
    }
}

/// Reads `/health` and returns the reported height.
private func healthHeight(_ client: some TestClientProtocol) async throws -> UInt64 {
    var height: UInt64?
    try await client.execute(uri: "/health", method: .get) { response in
        XCTAssertEqual(response.status, .ok)
        height = try JSONDecoder().decode(
            ChainServiceStatusResponse.self,
            from: Data(response.body.readableBytesView)
        ).height
    }
    return try XCTUnwrap(height)
}

/// Mines exactly one block atop the current tip through the loopback
/// template/work routes; genesis is at max target, so nonce 0 always solves it.
private func mineOneBlock(client: some TestClientProtocol) async throws -> String {
    var template: MiningTemplateResponse?
    try await client.execute(
        uri: "/v1/mining/templates",
        method: .post,
        headers: [.contentType: "application/json"],
        body: ByteBuffer(bytes: try JSONEncoder().encode(MiningTemplateRequest()))
    ) { response in
        template = try JSONDecoder().decode(
            MiningTemplateResponse.self,
            from: Data(response.body.readableBytesView)
        )
    }
    let issued = try XCTUnwrap(template)
    var tipCID: String?
    try await client.execute(
        uri: "/v1/mining/work",
        method: .post,
        headers: [.contentType: "application/json"],
        body: ByteBuffer(bytes: try JSONEncoder().encode(
            SubmitWorkRequest(workID: issued.workID, nonce: 0)
        ))
    ) { response in
        let submitted = try JSONDecoder().decode(
            SubmitWorkResponse.self,
            from: Data(response.body.readableBytesView)
        )
        XCTAssertTrue(submitted.accepted)
        tipCID = submitted.tipCID
    }
    return try XCTUnwrap(tipCID)
}

/// Parks the loader until every caller has registered, so a load cannot
/// complete while any caller is still outside the cache.
private actor CallerGate {
    private let expected: Int
    private var registered = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(expected: Int) { self.expected = expected }

    func register() {
        registered += 1
        guard registered >= expected else { return }
        let pending = waiters
        waiters = []
        for continuation in pending { continuation.resume() }
    }

    func waitForAll() async {
        if registered >= expected { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Counts loads; `CallerGate` supplies the ordering the coalescing test needs.
private actor LoadCounter {
    private(set) var count = 0

    func record() -> Int {
        count += 1
        return count
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds = 0.0

    var now: Double {
        lock.lock()
        defer { lock.unlock() }
        return seconds
    }

    func advance(_ delta: Double) {
        lock.lock()
        seconds += delta
        lock.unlock()
    }
}
