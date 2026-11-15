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
import LatticeNodeAPI

/// The public read listener is the one surface an unauthenticated caller can
/// drive as fast as it likes, and a directly exposed node has no proxy in front
/// of it to bound that. These assert that the listener-wide ceilings refuse
/// load while `/health` stays exempt.
final class PublicReadRateLimitTests: XCTestCase {
    private func makeService(
        _ name: String
    ) async throws -> (NodeRuntime, NodeConfiguration) {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-\(name)-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: storageDirectory) }
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storageDirectory,
            privateKeyHex: String(repeating: "01", count: 32)
        )
        let storage = try await NodeStorage.open(configuration: configuration)
        return (
            try await startRuntime(storage),
            configuration
        )
    }

    /// A one-token listener bank: the second read is refused, and `/health`
    /// must still answer 200, because a platform health check that public load
    /// can throttle turns load into a depooled machine.
    func testReadIsRefusedOverTheListenerCeilingWhileHealthStaysExempt() async throws {
        let (service, configuration) = try await makeService("public-read-rate")
        let app = makePublicReadApplication(
            service: service, host: "127.0.0.1", port: 8081,
            limits: try PublicReadRateLimits.validated(listenerRate: 0.001)
        )
        let cid = configuration.nexusGenesisCID

        try await app.test(.router) { client in
            var statuses: [Int] = []
            for _ in 0..<3 {
                try await client.execute(
                    uri: "/api/block/\(cid)/children", method: .get, headers: [.authorization: testOperatorAuthorization]
                ) { response in
                    statuses.append(response.status.code)
                }
            }
            XCTAssertTrue(
                statuses.contains(429),
                "3 requests against a 1-token listener bank must be refused at least once, got \(statuses)"
            )

            try await client.execute(uri: "/health", method: .get, headers: [.authorization: testOperatorAuthorization]) { response in
                XCTAssertEqual(
                    response.status, .ok,
                    "/health is exempt from every limit"
                )
            }
        }
    }

    /// A web page reads this listener cross-origin. When the limiter refuses
    /// a request the answer must still carry CORS headers, or the browser
    /// reports a CORS failure and the page cannot tell "slow down" from
    /// "this node does not serve you". Preflights are answered without
    /// spending the budget.
    func testARefusalStillCarriesCORSSoAPageCanSeeIt() async throws {
        let (service, configuration) = try await makeService("public-read-cors-refusal")
        let app = makePublicReadApplication(
            service: service, host: "127.0.0.1", port: 8081,
            limits: try PublicReadRateLimits.validated(listenerRate: 0.001)
        )
        let path = "/api/block/\(configuration.nexusGenesisCID)/children"
        let origin: HTTPFields = [.origin: "https://stoa.example"]
        try await app.test(.router) { client in
            var refused: HTTPResponse.Status?
            var allowOrigin: String?
            for _ in 0..<3 {
                try await client.execute(uri: path, method: .get, headers: origin) { response in
                    if response.status == .tooManyRequests {
                        refused = response.status
                        allowOrigin = response.headers[.accessControlAllowOrigin]
                    }
                }
            }
            XCTAssertEqual(refused, .tooManyRequests, "the listener bank runs out")
            XCTAssertEqual(allowOrigin, "*", "a refusal carries CORS, so a page sees the 429")
            let preflight: HTTPFields = [.origin: "https://stoa.example", .accessControlRequestMethod: "GET"]
            try await client.execute(uri: path, method: .options, headers: preflight) { response in
                XCTAssertNotEqual(response.status, .tooManyRequests, "a preflight is answered, not billed")
                XCTAssertNotNil(response.headers[.accessControlAllowOrigin])
            }
        }
    }

    func testRouteClassification() {
        for path in ["/api/block/bafy/children", "/volumes", "/transactions/bafy", "/unknown"] {
            XCTAssertEqual(PublicReadRouteClass(method: .get, path: path), .read, path)
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
                .read,
                "\(method) /health must not be exempt"
            )
        }
    }

    func testListenerBucketRefillsOnTheClock() async throws {
        let clock = TestClock()
        let limits = try PublicReadRateLimits.validated(listenerRate: 2)
        let limiter = try XCTUnwrap(
            PublicReadRateLimiter(limits: limits, clock: { clock.now })
        )

        // Listener bank: 2 r/s x 1 s = 2 tokens.
        for token in 0..<2 {
            let admitted = await limiter.admit(route: .read)
            XCTAssertTrue(admitted, "token \(token) must be inside the bank")
        }
        var admitted = await limiter.admit(route: .read)
        XCTAssertFalse(admitted, "the 3rd request exceeds the bank")

        // Refill is on the injected clock, never wall time.
        clock.advance(0.25)
        admitted = await limiter.admit(route: .read)
        XCTAssertFalse(admitted, "half a token is not a token")
        clock.advance(0.5)
        admitted = await limiter.admit(route: .read)
        XCTAssertTrue(admitted, "half a second of refill at 2 r/s buys one request")
    }

    func testAllZeroRatesDisableTheLimiterEntirely() throws {
        let off = try PublicReadRateLimits.validated(listenerRate: 0, submitRate: 0)
        XCTAssertTrue(off.isFullyDisabled)
        XCTAssertNil(PublicReadRateLimiter(limits: off))
    }

    /// A bad value in a unit file must name the flag that carried it, not trap
    /// the whole node on a `precondition`.
    func testBadRatesAreRefusedByFlagName() {
        let cases: [(Double, Double, String)] = [
            (-1, 1, "--public-read-max-rate"),
            (.nan, 1, "--public-read-max-rate"),
            (.infinity, 1, "--public-read-max-rate"),
            (1, -1, "--public-submit-rate"),
        ]
        for (listener, submit, flag) in cases {
            XCTAssertThrowsError(
                try PublicReadRateLimits.validated(listenerRate: listener, submitRate: submit),
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

    /// The removed per-client flags still parse, so an existing unit file or
    /// deploy entrypoint keeps starting; the node ignores them.
    func testRemovedPerClientFlagsStillParse() throws {
        let command = try LatticeNodeCommand.parse([
            "--public-read-rate", "0", "--public-read-expensive-rate", "0",
        ])
        XCTAssertEqual(command.publicReadRate, 0)
        XCTAssertEqual(command.publicReadExpensiveRate, 0)
    }

    /// The default is the lattice-ops read replica's nginx number, and the
    /// bank is its burst carried as `burst / rate` so an operator changing the
    /// rate keeps the tuned burstiness.
    func testDefaultsReproduceTheReadReplicaLimits() {
        let limits = PublicReadRateLimits.default
        XCTAssertEqual(limits.listenerRate, 200)
        // nginx burst=200.
        XCTAssertEqual(
            limits.listenerRate * PublicReadRateLimits.listenerBankSeconds, 200
        )
    }

    /// The deliberate decision behind the `/health` exemption: it is exempt
    /// from the listener bucket. Charging it there would mean a sustained flood
    /// empties the bucket, the health check 429s, and the platform depools a
    /// machine that carries every chain in the path — load amplified into an
    /// outage. The cost is bounded by collapsing the work instead (see the
    /// snapshot-cache tests below).
    func testExemptRouteIsNotChargedToTheListenerBucket() async throws {
        let clock = TestClock()
        // Listener bank = max(1, 1 x 1) = exactly one token.
        let limits = try PublicReadRateLimits.validated(listenerRate: 1)
        let limiter = try XCTUnwrap(
            PublicReadRateLimiter(limits: limits, clock: { clock.now })
        )

        var admitted = await limiter.admit(route: .read)
        XCTAssertTrue(admitted)
        admitted = await limiter.admit(route: .read)
        XCTAssertFalse(admitted, "the listener bank is spent")
        // Same instant, same empty listener bucket: the health check still wins.
        for _ in 0..<100 {
            let health = await limiter.admit(route: .exempt)
            XCTAssertTrue(
                health,
                "a health check must never be refused by public load"
            )
        }
    }

    /// Public submit has its own listener budget: a submit flood never spends
    /// the read listener's, nor reads the submit one's.
    func testSubmitIsClassifiedAndBilledToItsOwnListenerBudget() async throws {
        XCTAssertEqual(PublicReadRouteClass(method: .post, path: "/transactions"), .submit)
        XCTAssertEqual(PublicReadRouteClass(method: .post, path: "//transactions/"), .submit)
        XCTAssertEqual(PublicReadRouteClass(method: .get, path: "/transactions"), .read)
        let clock = TestClock()
        let limits = try PublicReadRateLimits.validated(listenerRate: 1, submitRate: 1)
        let limiter = try XCTUnwrap(PublicReadRateLimiter(limits: limits, clock: { clock.now }))
        var admitted = await limiter.admit(route: .submit)
        XCTAssertTrue(admitted)
        admitted = await limiter.admit(route: .submit)
        XCTAssertTrue(admitted, "a two-second bank")
        admitted = await limiter.admit(route: .submit)
        XCTAssertFalse(admitted, "the submit listener bank is spent")
        admitted = await limiter.admit(route: .read)
        XCTAssertTrue(admitted, "reads keep their own listener budget")
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
            try await client.execute(uri: "/health", method: .head, headers: [.authorization: testOperatorAuthorization]) { response in
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
            try await client.execute(uri: "/health", method: .head, headers: [.authorization: testOperatorAuthorization]) { response in
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
    try await client.execute(uri: "/health", method: .get, headers: [.authorization: testOperatorAuthorization]) { response in
        XCTAssertEqual(response.status, .ok)
        height = try JSONDecoder().decode(
            NodeStatusResponse.self,
            from: Data(response.body.readableBytesView)
        ).height
    }
    return try XCTUnwrap(height)
}

/// Mines exactly one block atop the current tip through the loopback
/// template/work routes, solving the issued template.
private func mineOneBlock(client: some TestClientProtocol) async throws -> String {
    var template: MiningTemplateResponse?
    try await client.execute(
        uri: "/mining/templates",
        method: .post,
        headers: [.authorization: testOperatorAuthorization, .contentType: "application/json"],
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
        uri: "/mining/work",
        method: .post,
        headers: [.authorization: testOperatorAuthorization, .contentType: "application/json"],
        body: ByteBuffer(bytes: try JSONEncoder().encode(
            SubmitWorkRequest(workID: issued.workID, nonce: solvedNonce(for: issued))
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
