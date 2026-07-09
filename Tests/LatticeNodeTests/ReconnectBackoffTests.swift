import XCTest
@testable import LatticeNode

final class ReconnectBackoffTests: XCTestCase {
    func testGeometricGrowthShape() {
        var backoff = ReconnectBackoff()

        let delays = (0..<8).map { _ in backoff.nextDelay().wholeSeconds }

        XCTAssertTrue(zip(delays, delays.dropFirst()).allSatisfy { $0 <= $1 })
        XCTAssertTrue(zip(delays, delays.dropFirst()).contains { $0 < $1 })
        XCTAssertEqual(delays.suffix(2), [300, 300])
    }

    func testResetReturnsToBase() {
        var backoff = ReconnectBackoff()
        for _ in 0..<8 { _ = backoff.nextDelay() }

        backoff.reset()

        XCTAssertEqual(backoff.nextDelay(), .seconds(30))
    }

    func testNoConstantSchedule() {
        var backoff = ReconnectBackoff()

        XCTAssertNotEqual(backoff.nextDelay(), backoff.nextDelay())
    }

    func testPinnedSchedule() {
        var backoff = ReconnectBackoff()

        let delays = (0..<7).map { _ in backoff.nextDelay().wholeSeconds }

        XCTAssertEqual(delays, [30, 60, 120, 240, 300, 300, 300])
    }

    func testCancelledLoopDoesNotReconnectOrConsumeBackoff() {
        var backoff = ReconnectBackoff()

        let action = ParentSubscriptionReconnectLoop.nextAction(
            isCancelled: true,
            peerConnectionCount: 0,
            backoff: &backoff
        )

        XCTAssertEqual(action, .exit)
        XCTAssertEqual(backoff.nextDelay(), .seconds(30))
    }

    func testConnectedPeerResetsBackoffAndWaitsAtBaseCadence() {
        var backoff = ReconnectBackoff()
        for _ in 0..<4 { _ = backoff.nextDelay() }

        let action = ParentSubscriptionReconnectLoop.nextAction(
            isCancelled: false,
            peerConnectionCount: 1,
            backoff: &backoff
        )

        XCTAssertEqual(action, .wait(.seconds(30)))
        XCTAssertEqual(backoff.nextDelay(), .seconds(30))
    }

    func testDisconnectedPeerReconnectsAfterNextBackoffDelay() {
        var backoff = ReconnectBackoff()

        let first = ParentSubscriptionReconnectLoop.nextAction(
            isCancelled: false,
            peerConnectionCount: 0,
            backoff: &backoff
        )
        let second = ParentSubscriptionReconnectLoop.nextAction(
            isCancelled: false,
            peerConnectionCount: 0,
            backoff: &backoff
        )

        XCTAssertEqual(first, .reconnectAfter(.seconds(30)))
        XCTAssertEqual(second, .reconnectAfter(.seconds(60)))
    }

    // a thrown connect error must reach onFailure (surfaced, not
    // swallowed) AND leave the backoff intact so the next delay keeps growing.
    // This drives the production performReconnect choke point the parent-reconnect
    // loop calls — a behavioral assertion, replacing the old source-grep test.
    func testPerformReconnectSurfacesConnectFailureWithBackoffIntact() async {
        struct ConnectFailed: Error, Equatable {}
        var backoff = ReconnectBackoff()
        // Advance the backoff so "intact" is a non-trivial value (60s, not base).
        XCTAssertEqual(backoff.nextDelay(), .seconds(30))
        let delayBeforeAttempt = backoff.nextDelay() // 60s; next would be 120s

        var surfaced: (any Error)?
        await ParentSubscriptionReconnectLoop.performReconnect(
            backoff: &backoff,
            connect: { throw ConnectFailed() },
            onFailure: { surfaced = $0 }
        )

        XCTAssertEqual(delayBeforeAttempt, .seconds(60))
        XCTAssertEqual(surfaced as? ConnectFailed, ConnectFailed(),
                       "a connect failure must be surfaced through onFailure, not swallowed")
        // Backoff was NOT reset by the failed attempt: it keeps growing.
        XCTAssertEqual(backoff.nextDelay(), .seconds(120),
                       "a failed reconnect must leave backoff intact so the delay keeps growing")
    }

    // The success path resets the backoff to base cadence.
    func testPerformReconnectResetsBackoffOnSuccess() async {
        var backoff = ReconnectBackoff()
        for _ in 0..<4 { _ = backoff.nextDelay() }

        var surfaced: (any Error)?
        await ParentSubscriptionReconnectLoop.performReconnect(
            backoff: &backoff,
            connect: {},
            onFailure: { surfaced = $0 }
        )

        XCTAssertNil(surfaced, "a successful reconnect must not surface any error")
        XCTAssertEqual(backoff.nextDelay(), .seconds(30),
                       "a successful reconnect must reset backoff to base cadence")
    }
}

private extension Duration {
    var wholeSeconds: Int64 {
        let (seconds, attoseconds) = components
        XCTAssertEqual(attoseconds, 0)
        return seconds
    }
}
