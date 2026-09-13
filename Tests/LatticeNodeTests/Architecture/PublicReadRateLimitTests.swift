import ArgumentParser
import Foundation
import Hummingbird
import HummingbirdTesting
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
        XCTAssertEqual(PublicReadRouteClass(path: escaped), .expensive)
        XCTAssertEqual(
            PublicReadRouteClass(path: "/api/block/\(cid)/children"), .expensive
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
            XCTAssertEqual(PublicReadRouteClass(path: path), .expensive, path)
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
            XCTAssertEqual(PublicReadRouteClass(path: path), .general, path)
        }
        XCTAssertEqual(PublicReadRouteClass(path: "/health"), .exempt)
        XCTAssertEqual(PublicReadRouteClass(path: "//health//"), .exempt)
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
