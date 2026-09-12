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
        interval: TimeInterval = StaleTipPeerSearchTests.interval
    ) -> StaleTipPeerSearch {
        let configured = [Self.configuredPeer]
        let discovered = Self.discoveredPeers
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
}
