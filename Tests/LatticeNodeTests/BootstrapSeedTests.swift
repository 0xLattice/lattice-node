import XCTest
@testable import LatticeNode

/// Regression for the child-chain backbone-pollution bug.
///
/// A child chain booted from `--genesis-hex` inherited the hardcoded Nexus mainnet backbone
/// (137.66.x) and the mainnet DNS seeds for its CHAIN-GOSSIP network. Those are parent-chain
/// (Nexus) nodes that never serve the child: wiring them into the child's chain-gossip Ivy
/// polluted its same-chain peer set and masked `needsSameChainPeer`, so getChildPeers discovery
/// stopped running. `--no-dns-seeds` did not suppress the hardcoded list. The fix seeds the
/// backbone / DNS peers ONLY on a ROOT chain-gossip network; these tests pin the root-vs-child
/// discriminator.
final class BootstrapSeedTests: XCTestCase {
    /// The plain root node: no parent signals ⇒ seeds the backbone.
    func testRootUsesBackbone() {
        XCTAssertTrue(NodeCommand.isRootChainGossip(
            subscribeP2P: nil, chainPath: nil, chainDirectory: nil))
    }

    /// A root re-served from --genesis-hex (chain-directory omitted ⇒ defaults to Nexus, no
    /// parent subscription) still counts as root and keeps the backbone.
    func testRootFromGenesisHexKeepsBackbone() {
        XCTAssertTrue(NodeCommand.isRootChainGossip(
            subscribeP2P: nil, chainPath: "Nexus", chainDirectory: "Nexus"))
        XCTAssertTrue(NodeCommand.isRootChainGossip(
            subscribeP2P: nil, chainPath: nil, chainDirectory: nil))
    }

    /// A child that subscribes to a parent's gossip must NOT seed the backbone.
    func testChildViaSubscribeP2PExcludesBackbone() {
        XCTAssertFalse(NodeCommand.isRootChainGossip(
            subscribeP2P: "ed01aa@127.0.0.1:4001", chainPath: nil, chainDirectory: nil))
    }

    /// A child identified by a full path below the root must NOT seed the backbone.
    func testChildViaFullChainPathExcludesBackbone() {
        XCTAssertFalse(NodeCommand.isRootChainGossip(
            subscribeP2P: nil, chainPath: "Nexus/Toy", chainDirectory: nil))
        XCTAssertFalse(NodeCommand.isRootChainGossip(
            subscribeP2P: nil, chainPath: "Nexus/Mid/Stable", chainDirectory: nil))
    }

    /// A child identified only by a non-root directory must NOT seed the backbone.
    func testChildViaNonRootDirectoryExcludesBackbone() {
        XCTAssertFalse(NodeCommand.isRootChainGossip(
            subscribeP2P: nil, chainPath: nil, chainDirectory: "Toy"))
    }
}
