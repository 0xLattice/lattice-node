import XCTest
@testable import LatticeNode

/// Regression for the relay-masked same-chain discovery bug.
///
/// `chainGossipPeerCount` used to return Ivy's raw `directPeerCount`, which counts a
/// `--use-relay` circuit-relay peer even though the relay never serves the child chain.
/// Once a NAT'd follower was past genesis, that made `needsSameChainPeer` return false and
/// the getChildPeers rendezvous discovery never ran again — the node could never (re)find a
/// same-chain source. The fix excludes known-relay keys from the count; these tests pin the
/// exclusion logic (including the `ed01`-prefix normalization that the first fix missed).
final class RelayPeerCountTests: XCTestCase {
    // Ivy stores connected peer keys WITHOUT the `ed01` multicodec prefix; config /
    // `--use-relay` keys keep it. Model both forms.
    private let relayFull = "ed01" + String(repeating: "a", count: 64)   // as parsed from --use-relay
    private var relayStripped: String { String(repeating: "a", count: 64) } // as seen in Ivy connections
    private let sourceKey = String(repeating: "b", count: 64)

    /// The masking scenario: the ONLY connection is the relay. Raw `directPeerCount` would be
    /// 1 (→ needsSameChainPeer false → discovery masked); the fix must report 0.
    func testRelayOnlyCountsAsNoSameChainPeer() {
        let count = LatticeNode.nonRelayPeerCount(
            connectedPeerKeys: [relayStripped],
            knownRelayKeys: [relayFull])
        XCTAssertEqual(count, 0, "a relay-only follower must report zero same-chain peers")
    }

    /// A genuine same-chain peer alongside the relay counts as exactly one.
    func testRealPeerCountedRelayExcluded() {
        let count = LatticeNode.nonRelayPeerCount(
            connectedPeerKeys: [relayStripped, sourceKey],
            knownRelayKeys: [relayFull])
        XCTAssertEqual(count, 1, "the source counts; the relay does not")
    }

    /// The `ed01` prefix must be normalized on BOTH sides — the first version of the fix
    /// compared a prefixed config key against a stripped Ivy key and silently matched nothing.
    func testEd01PrefixNormalizedBothDirections() {
        XCTAssertEqual(LatticeNode.normalizedPeerKey(relayFull), relayStripped)
        XCTAssertEqual(LatticeNode.normalizedPeerKey(relayStripped), relayStripped)
        // stripped connection key vs prefixed relay key → excluded
        XCTAssertEqual(LatticeNode.nonRelayPeerCount(connectedPeerKeys: [relayStripped],
                                                     knownRelayKeys: [relayFull]), 0)
        // prefixed connection key vs stripped relay key → also excluded
        XCTAssertEqual(LatticeNode.nonRelayPeerCount(connectedPeerKeys: [relayFull],
                                                     knownRelayKeys: [relayStripped]), 0)
    }

    /// Hex case must be folded (Ivy/Tally canonicalize connection keys with `.lowercased()`),
    /// so a relay key entered in a different case than the connection key is still excluded.
    func testRelayKeyCaseFolded() {
        let relayUpper = "ED01" + String(repeating: "A", count: 64)   // --use-relay, upper-cased
        // stripped, lower-case connection key vs upper-case prefixed relay key → excluded
        XCTAssertEqual(LatticeNode.nonRelayPeerCount(connectedPeerKeys: [relayStripped],
                                                     knownRelayKeys: [relayUpper]), 0)
        XCTAssertEqual(LatticeNode.normalizedPeerKey(relayUpper), relayStripped)
    }

    /// With no relays configured every connection counts (the non-NAT default path).
    func testNoRelaysCountsEverything() {
        let count = LatticeNode.nonRelayPeerCount(
            connectedPeerKeys: [relayStripped, sourceKey],
            knownRelayKeys: [])
        XCTAssertEqual(count, 2)
    }
}
