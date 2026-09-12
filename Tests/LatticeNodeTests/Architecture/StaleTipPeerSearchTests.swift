import Foundation
import Ivy
import XCTest
@testable import LatticeNode

private actor TestClock {
    private var current: Date

    init(_ start: Date) { current = start }

    func advance(_ seconds: TimeInterval) {
        current = current.addingTimeInterval(seconds)
    }

    func read() -> Date { current }
}

private actor DialRecorder {
    private var dialled: [PeerEndpoint] = []

    func record(_ endpoint: PeerEndpoint) { dialled.append(endpoint) }

    func snapshot() -> [PeerEndpoint] { dialled }

    func count() -> Int { dialled.count }
}

private actor TipHeight {
    private var height: UInt64

    init(_ height: UInt64) { self.height = height }

    func advance() { height &+= 1 }

    func set(_ value: UInt64) { height = value }

    func read() -> UInt64? { height }
}

private func testEndpoint(_ name: String) -> PeerEndpoint {
    PeerEndpoint(publicKey: name, host: "127.0.0.1", port: 4001)
}

/// The search is discovery only: every assertion below is about which
/// endpoints were DIALLED, never about the search's internal bookkeeping.
final class StaleTipPeerSearchTests: XCTestCase {
    private static let interval: TimeInterval = 600
    private static let maximumDiscoveredDials = 4
    private static let configuredPeer = testEndpoint("configured")
    private static let discoveredPeers = (0..<10).map { testEndpoint("discovered-\($0)") }
    /// One configured re-dial plus the capped share of the provider lookup.
    private static let dialsPerSearch = 1 + maximumDiscoveredDials

    private func makeSearch(
        clock: TestClock,
        tip: TipHeight,
        recorder: DialRecorder,
        interval: TimeInterval = StaleTipPeerSearchTests.interval,
        configuredPeers: [PeerEndpoint] = [StaleTipPeerSearchTests.configuredPeer],
        discoveredPeers: [PeerEndpoint] = StaleTipPeerSearchTests.discoveredPeers
    ) -> StaleTipPeerSearch {
        let configured = configuredPeers
        let discovered = discoveredPeers
        return StaleTipPeerSearch(
            interval: interval,
            maximumDiscoveredDials: Self.maximumDiscoveredDials,
            clock: { await clock.read() },
            acquiredHeight: { await tip.read() },
            configuredPeersWithoutSession: { configured },
            discoveredPeersWithoutSession: { discovered },
            dial: { await recorder.record($0) }
        )
    }

    /// A tip that stops advancing for the configured period makes the node dial
    /// again: the configured peer it holds no session with, then a bounded
    /// share of one provider lookup.
    func testIdleTipWidensThePeerSearch() async {
        let clock = TestClock(Date(timeIntervalSince1970: 0))
        let tip = TipHeight(41)
        let recorder = DialRecorder()
        let search = makeSearch(clock: clock, tip: tip, recorder: recorder)

        await search.tick()
        let afterFirstObservation = await recorder.snapshot()
        XCTAssertEqual(
            afterFirstObservation, [],
            "a node that has just started is not idle yet"
        )

        await clock.advance(Self.interval)
        await search.tick()

        let dialled = await recorder.snapshot()
        XCTAssertEqual(
            dialled,
            [Self.configuredPeer] + Self.discoveredPeers.prefix(Self.maximumDiscoveredDials),
            "an idle tip re-dials the configured peer and a capped share of discovery"
        )
    }

    /// A node whose tip keeps advancing never widens, however long it runs.
    func testAdvancingTipNeverWidensTheSearch() async {
        let clock = TestClock(Date(timeIntervalSince1970: 0))
        let tip = TipHeight(1)
        let recorder = DialRecorder()
        let search = makeSearch(clock: clock, tip: tip, recorder: recorder)

        await search.tick()
        for _ in 0..<10 {
            await clock.advance(Self.interval * 2)
            await tip.advance()
            await search.tick()
        }

        let count = await recorder.count()
        XCTAssertEqual(count, 0, "progress is the whole reason not to go looking")
    }

    /// Once the tip moves again the widening stops; the node does not keep
    /// dialling because it was stalled a moment ago.
    func testSearchStopsOnceProgressResumes() async {
        let clock = TestClock(Date(timeIntervalSince1970: 0))
        let tip = TipHeight(7)
        let recorder = DialRecorder()
        let search = makeSearch(clock: clock, tip: tip, recorder: recorder)

        await search.tick()
        await clock.advance(Self.interval)
        await search.tick()
        let whileStalled = await recorder.count()
        XCTAssertEqual(whileStalled, Self.dialsPerSearch)

        // The tip advances: the next observation, a full interval later, must
        // dial nothing at all.
        await tip.advance()
        await clock.advance(Self.interval)
        await search.tick()

        let afterRecovery = await recorder.count()
        XCTAssertEqual(
            afterRecovery, whileStalled,
            "a node making progress again has nothing to look for"
        )
    }

    /// The extra dialling is rate-limited: ticking ten times per interval for
    /// six intervals still yields exactly one widening per interval.
    func testSearchRateIsBoundedUnderALongStall() async {
        let clock = TestClock(Date(timeIntervalSince1970: 0))
        let tip = TipHeight(99)
        let recorder = DialRecorder()
        let search = makeSearch(clock: clock, tip: tip, recorder: recorder)

        await search.tick()
        let intervalsStalled = 6
        let ticksPerInterval = 10
        let step = Self.interval / TimeInterval(ticksPerInterval)
        for _ in 0..<(intervalsStalled * ticksPerInterval) {
            await clock.advance(step)
            await search.tick()
        }

        let count = await recorder.count()
        XCTAssertEqual(
            count, intervalsStalled * Self.dialsPerSearch,
            "one widening per interval, however often the tip is observed"
        )
    }

    /// The operator can turn it off entirely.
    func testZeroIntervalDisablesTheSearch() async {
        let clock = TestClock(Date(timeIntervalSince1970: 0))
        let tip = TipHeight(3)
        let recorder = DialRecorder()
        let search = makeSearch(
            clock: clock,
            tip: tip,
            recorder: recorder,
            interval: 0
        )

        await search.tick()
        for _ in 0..<5 {
            await clock.advance(Self.interval * 10)
            await search.tick()
        }

        let count = await recorder.count()
        XCTAssertEqual(count, 0, "0 disables the search")
    }

    /// A tip that moves BACKWARDS — a mid-walk reorg, an exclusion
    /// re-projection — is not progress. Treating any change as progress would
    /// let a tip flipping between two heights reset the stall timer on every
    /// observation, suppressing the search exactly when it is needed.
    func testOscillatingTipBelowItsHighWaterMarkIsStillAStall() async {
        let clock = TestClock(Date(timeIntervalSince1970: 0))
        let tip = TipHeight(100)
        let recorder = DialRecorder()
        let search = makeSearch(clock: clock, tip: tip, recorder: recorder)

        await search.tick()
        for step in 0..<6 {
            await tip.set(step.isMultiple(of: 2) ? 99 : 100)
            await clock.advance(Self.interval)
            await search.tick()
        }

        let count = await recorder.count()
        XCTAssertGreaterThan(
            count, 0,
            "a tip oscillating below its high-water mark is a stall, not progress"
        )
    }

    /// A node with no configured peers at all — the default on main today —
    /// must still run the discovery limb rather than widening into nothing.
    func testWideningWithNoConfiguredPeersStillRunsDiscovery() async {
        let clock = TestClock(Date(timeIntervalSince1970: 0))
        let tip = TipHeight(5)
        let recorder = DialRecorder()
        let search = makeSearch(
            clock: clock,
            tip: tip,
            recorder: recorder,
            configuredPeers: []
        )

        await search.tick()
        await clock.advance(Self.interval)
        await search.tick()

        let dialled = await recorder.snapshot()
        XCTAssertEqual(
            dialled,
            Array(Self.discoveredPeers.prefix(Self.maximumDiscoveredDials)),
            "an empty configured set still dials the capped discovery share"
        )
    }
}

/// The runtime-side halves of the search that are reachable without standing a
/// whole node up: the sleep cadence and the discovery host filter.
final class PeerSearchRuntimePolicyTests: XCTestCase {
    /// Converting an operator-supplied Double straight to UInt64 traps. NaN is
    /// not clamped by min/max either — both propagate it — so a non-finite
    /// value must be replaced outright.
    func testPollCadenceIsRepresentableForAnyOperatorValue() {
        XCTAssertEqual(NodeNetworkRuntime.peerSearchPollSeconds(600), 600)
        XCTAssertEqual(NodeNetworkRuntime.peerSearchPollSeconds(0.5), 1)
        XCTAssertEqual(NodeNetworkRuntime.peerSearchPollSeconds(-5), 1)
        XCTAssertEqual(NodeNetworkRuntime.peerSearchPollSeconds(1e30), 86_400)
        XCTAssertEqual(NodeNetworkRuntime.peerSearchPollSeconds(.infinity), 600)
        XCTAssertEqual(NodeNetworkRuntime.peerSearchPollSeconds(.nan), 600)
    }

    /// Discovery answers are attacker-supplied, and this is the node's first
    /// automatic repeating dial of them, so unroutable targets are dropped
    /// before any connection is attempted. Private ranges stay diallable: a LAN
    /// peer is a legitimate deployment.
    func testDiscoveredHostFilterRejectsUnroutableTargets() {
        for host in [
            "127.0.0.1", "0.0.0.0", "::1", "::", "localhost", "169.254.1.2",
            "224.0.0.1", "255.255.255.255", "fe80::1", "ff02::1", ""
        ] {
            XCTAssertFalse(
                NodeNetworkRuntime.isDiallableDiscoveredHost(host),
                "\(host) must not be dialled from a discovery answer"
            )
        }
        for host in [
            "93.184.216.34", "10.0.0.5", "2606:4700::1111", "peer.example.com"
        ] {
            XCTAssertTrue(
                NodeNetworkRuntime.isDiallableDiscoveredHost(host),
                "\(host) is a legitimate dial target"
            )
        }
    }
}
