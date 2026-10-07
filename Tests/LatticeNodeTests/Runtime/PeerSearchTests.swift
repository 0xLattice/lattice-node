import XCTest
@testable import LatticeNode

/// Each hosted level searches its own rendezvous when it has not progressed,
/// whatever the other levels do: a live Nexus must not keep a stalled child
/// level from finding the peers that host it.
final class PeerSearchTests: XCTestCase {
    private let nexus = ["Nexus"], testnet = ["Nexus", "testnet"]
    private let interval: Int64 = 600_000

    func testEveryLevelSearchesAtOnceBeforeItProgresses() {
        var search = PeerSearch()
        XCTAssertEqual(
            search.due(heights: [(nexus, 0), (testnet, 0)], now: 0, interval: interval, connected: true),
            [nexus, testnet], "a joiner looks for each level's peers right away"
        )
        XCTAssertEqual(search.due(heights: [(nexus, 0), (testnet, 0)], now: 1_000, interval: interval, connected: true), [])
    }

    func testAStalledChildLevelSearchesWhileNexusProgresses() {
        var search = PeerSearch()
        _ = search.due(heights: [(nexus, 10), (testnet, 50)], now: 0, interval: interval, connected: true)
        XCTAssertEqual(search.due(heights: [(nexus, 11), (testnet, 50)], now: 1, interval: interval, connected: true), [])
        XCTAssertEqual(search.due(heights: [(nexus, 12), (testnet, 50)], now: 300_000, interval: interval, connected: true), [])
        XCTAssertEqual(
            search.due(heights: [(nexus, 13), (testnet, 50)], now: 600_000, interval: interval, connected: true),
            [testnet], "testnet stalled while Nexus advanced: it searches, Nexus does not"
        )
    }

    func testASearchRepeatsAtMostOncePerInterval() {
        var search = PeerSearch()
        XCTAssertEqual(search.due(heights: [(testnet, 5)], now: 0, interval: interval, connected: true), [testnet])
        XCTAssertEqual(search.due(heights: [(testnet, 5)], now: 300_000, interval: interval, connected: true), [])
        XCTAssertEqual(search.due(heights: [(testnet, 5)], now: 600_000, interval: interval, connected: true), [testnet])
    }

    func testProgressDefersTheNextSearch() {
        var search = PeerSearch()
        _ = search.due(heights: [(nexus, 1)], now: 0, interval: interval, connected: true)
        XCTAssertEqual(search.due(heights: [(nexus, 2)], now: 500_000, interval: interval, connected: true), [])
        XCTAssertEqual(search.due(heights: [(nexus, 2)], now: 1_000_000, interval: interval, connected: true), [])
        XCTAssertEqual(search.due(heights: [(nexus, 2)], now: 1_100_000, interval: interval, connected: true), [nexus])
    }

    func testWithoutAPeerNothingIsSearchedAndNoSearchIsSpent() {
        var search = PeerSearch()
        XCTAssertEqual(search.due(heights: [(testnet, 0)], now: 0, interval: interval, connected: false), [])
        XCTAssertEqual(
            search.due(heights: [(testnet, 0)], now: 1_000, interval: interval, connected: true), [testnet],
            "the first peer brings the boot search, not one an interval later"
        )
    }

    func testAZeroIntervalNeverSearches() {
        var search = PeerSearch()
        XCTAssertEqual(search.due(heights: [(nexus, 1)], now: 0, interval: 0, connected: true), [])
    }

    func testTheRendezvousIsScopedToItsNexusAndPath() {
        let key = ChainPeersKey.key(nexusGenesisCID: "bafyNexus", chainPath: testnet)
        XCTAssertEqual(key, "lattice.chain-peers.v1:bafyNexus:Nexus/testnet")
        XCTAssertNotEqual(key, ChainPeersKey.key(nexusGenesisCID: "bafyOther", chainPath: testnet))
        XCTAssertNotEqual(key, ReadEndpointKey.key(nexusGenesisCID: "bafyNexus", chainPath: testnet))
    }
}
