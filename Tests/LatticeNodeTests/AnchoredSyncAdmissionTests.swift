import Foundation
import XCTest
@testable import Lattice
@testable import LatticeNode
import cashew
import UInt256

/// Segment-anchored sync admission (fork-point-relative work comparison).
///
/// A synced segment that attaches to a block on OUR current main chain
/// competes only against the local blocks strictly above that fork point —
/// the shared prefix cancels on both sides. These tests pin:
///  - pure fast-forward is admitted (the frozen-follower catch-up case),
///  - an equal-work competing fork is refused (exact ties hold the incumbent),
///  - a strictly heavier fork is admitted (root chains),
///  - child chains anchor ONLY at their current tip (fast-forward): child
///    fork REORGS are never decided by own-target work sums — that decision
///    belongs to gossip fork choice (trueCumWork).
final class AnchoredSyncAdmissionTests: XCTestCase {

    // MARK: - isAnchorEligible (child fast-forward-only rule)

    func testRootChainMayAnchorAtAnyMainChainBlock() async throws {
        try await withSyncNode { node in
            let chain = await node.lattice.nexus.chain
            let eligible = await node.isAnchorEligible(
                anchorCID: "bafy-not-the-tip", chainPath: ["Nexus"], localChain: chain)
            XCTAssertTrue(eligible, "root chains anchor at any retained fork point")
        }
    }

    func testChildChainAnchorsOnlyAtCurrentTip() async throws {
        try await withSyncNode { node in
            let chain = await node.lattice.nexus.chain
            let tip = await chain.getMainChainTip()
            let atTip = await node.isAnchorEligible(
                anchorCID: tip, chainPath: ["Nexus", "toy"], localChain: chain)
            XCTAssertTrue(atTip, "child fast-forward (anchor == tip) is eligible")
            let belowTip = await node.isAnchorEligible(
                anchorCID: "bafy-not-the-tip", chainPath: ["Nexus", "toy"], localChain: chain)
            XCTAssertFalse(belowTip, "child fork-point anchoring is NOT eligible: child reorgs belong to gossip fork choice")
        }
    }

    // MARK: - Fork-point-relative admission

    /// Pure fast-forward: a valid segment extending our tip is admitted even
    /// though its segment work is (necessarily) less than whole-chain work.
    /// This is exactly the frozen-follower catch-up the fix exists for.
    func testFastForwardSegmentAdmitted() async throws {
        try await withSyncNode { node in
            let chainState = await node.lattice.nexus.chain
            let fixture = try await Self.makeExtensionFixture(on: node, blocks: 1)
            let decision = await node.admitSyncedChainAgainstCurrentChain(
                fixture.result, chainState: chainState, chainPath: ["Nexus"])
            guard case .admit = decision else {
                return XCTFail("fast-forward segment (1 valid block above our tip, 0 local work above fork) must be admitted")
            }
        }
    }

    /// Exact ties hold the incumbent at the fork point: a sibling block with
    /// work equal to our own block above the shared parent is refused.
    func testEqualWorkCompetingForkRefused() async throws {
        try await withSyncNode { node in
            let chainState = await node.lattice.nexus.chain
            // Commit one LOCAL block above genesis (local work above fork = 1).
            let maybeNetwork = await node.network(forPath: ["Nexus"])
            let network = try XCTUnwrap(maybeNetwork)
            let fetcher = await network.ivyFetcher
            let genesis = await node.genesisResult
            let localBlock = try await BlockBuilder.buildBlock(
                previous: genesis.block,
                timestamp: genesis.block.timestamp + 1_000,
                target: genesis.block.nextTarget,
                fetcher: fetcher)
            let localHeader = try VolumeImpl<Block>(node: localBlock)
            _ = await chainState.submitBlock(
                parentBlockHeaderAndIndex: nil, blockHeader: localHeader, block: localBlock)
            await chainState.updateTipSnapshot(block: localBlock)

            // Peer sibling at the same height, equal work (same target).
            let sibling = try await BlockBuilder.buildBlock(
                previous: genesis.block,
                timestamp: genesis.block.timestamp + 2_000,
                target: genesis.block.nextTarget,
                nonce: 7,
                fetcher: fetcher)
            let result = try await Self.resultFor(blocks: [sibling], genesis: genesis.block, fetcher: fetcher, cumulativeWork: UInt256(1))
            let decision = await node.admitSyncedChainAgainstCurrentChain(
                result, chainState: chainState, chainPath: ["Nexus"])
            guard case .refuse = decision else {
                return XCTFail("equal-work sibling above the fork must be refused (ties hold the incumbent)")
            }
        }
    }

    /// A strictly heavier fork above the fork point is admitted on the root.
    func testHeavierForkAdmittedOnRoot() async throws {
        try await withSyncNode { node in
            let chainState = await node.lattice.nexus.chain
            let maybeNetwork = await node.network(forPath: ["Nexus"])
            let network = try XCTUnwrap(maybeNetwork)
            let fetcher = await network.ivyFetcher
            let genesis = await node.genesisResult
            // Local: one block above genesis.
            let localBlock = try await BlockBuilder.buildBlock(
                previous: genesis.block,
                timestamp: genesis.block.timestamp + 1_000,
                target: genesis.block.nextTarget,
                fetcher: fetcher)
            _ = await chainState.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: try VolumeImpl<Block>(node: localBlock), block: localBlock)
            await chainState.updateTipSnapshot(block: localBlock)

            // Peer: two blocks above genesis (work 2 > local 1).
            let f1 = try await BlockBuilder.buildBlock(
                previous: genesis.block,
                timestamp: genesis.block.timestamp + 2_000,
                target: genesis.block.nextTarget, nonce: 9, fetcher: fetcher)
            let f2 = try await BlockBuilder.buildBlock(
                previous: f1,
                timestamp: genesis.block.timestamp + 3_000,
                target: f1.nextTarget, fetcher: fetcher)
            let result = try await Self.resultFor(blocks: [f1, f2], genesis: genesis.block, fetcher: fetcher, cumulativeWork: UInt256(2))
            let decision = await node.admitSyncedChainAgainstCurrentChain(
                result, chainState: chainState, chainPath: ["Nexus"])
            guard case .admit = decision else {
                return XCTFail("strictly heavier fork above the fork point must be admitted on the root chain")
            }
        }
    }

    /// Child chains: a strict fast-forward of the current tip is admitted
    /// WITHOUT any work comparison — even a zero own-target segment work sum.
    /// Child own-target sums are meaningless for ordering (a carrier's real
    /// weight is the securing work in its ChildBlockProofs, invisible here);
    /// gating a pure append on them is exactly the frozen-follower
    /// "insufficientWork" refusal loop. The append evicts nothing and decides
    /// no reorg, so fork choice (trueCumWork) stays the sole switch authority.
    func testChildFastForwardAdmittedWithoutWorkComparison() async throws {
        try await withSyncNode { node in
            let chainState = await node.lattice.nexus.chain
            let maybeNetwork = await node.network(forPath: ["Nexus"])
            let network = try XCTUnwrap(maybeNetwork)
            let fetcher = await network.ivyFetcher
            let genesis = await node.genesisResult
            let ext = try await BlockBuilder.buildBlock(
                previous: genesis.block,
                timestamp: genesis.block.timestamp + 1_000,
                target: genesis.block.nextTarget,
                fetcher: fetcher)
            // Segment work declared ZERO: strictly less than any local work,
            // so the old `peerWork > localWork` gate refused this append.
            let result = try await Self.resultFor(
                blocks: [ext], genesis: genesis.block, fetcher: fetcher, cumulativeWork: .zero)
            let decision = await node.admitSyncedChainAgainstCurrentChain(
                result, chainState: chainState, chainPath: ["Nexus", "toy"])
            guard case .admit = decision else {
                return XCTFail("a strict child fast-forward must admit without a work comparison (own-target sums do not order child chains)")
            }
        }
    }

    /// Deterministic refusals are memoized per (peerTip, localTip) pair so a
    /// refused tip is not re-synced every announce round; either tip changing
    /// re-arms the sync.
    func testRefusedSyncTipMemoizationIsPairScoped() async throws {
        try await withSyncNode { node in
            await node.recordRefusedSyncTip("bafy-peer-tip", localTip: "bafy-local-tip")
            let memoized = await node.isRefusedSyncTip("bafy-peer-tip", localTip: "bafy-local-tip")
            XCTAssertTrue(memoized, "a refused (peerTip, localTip) pair must stay refused while both tips are unchanged")
            let localMoved = await node.isRefusedSyncTip("bafy-peer-tip", localTip: "bafy-local-tip-2")
            XCTAssertFalse(localMoved, "a local tip change must re-arm the refused peer tip")
            let otherPeer = await node.isRefusedSyncTip("bafy-peer-tip-2", localTip: "bafy-local-tip")
            XCTAssertFalse(otherPeer, "an unseen peer tip must not be pre-refused")
        }
    }

    /// The syncer's `insufficientWork` pre-gate floor: root chains pass their
    /// whole-chain work; CHILD chains pass ZERO so the gate can never
    /// pre-refuse a fast-forward before the single admission choke point
    /// (`admitSyncedChainAgainstCurrentChain`) decides it.
    func testChildSyncerWorkFloorIsZero() {
        XCTAssertEqual(LatticeNode.syncerWorkFloor(chainPath: ["Nexus"], localWork: UInt256(7)), UInt256(7))
        XCTAssertEqual(LatticeNode.syncerWorkFloor(chainPath: ["Nexus", "toy"], localWork: UInt256(7)), UInt256.zero)
        XCTAssertEqual(LatticeNode.syncerWorkFloor(chainPath: ["Nexus", "toy", "tt"], localWork: UInt256(7)), UInt256.zero)
    }

    /// Child chains: an anchored result whose anchor is NOT the current tip
    /// falls back to the legacy whole-chain compare (and refuses when the
    /// segment does not outweigh the whole local chain) — a child sync-reorg
    /// must not land on own-target work.
    func testChildForkFallsBackToWholeChainCompareAndRefuses() async throws {
        try await withSyncNode { node in
            let chainState = await node.lattice.nexus.chain
            let maybeNetwork = await node.network(forPath: ["Nexus"])
            let network = try XCTUnwrap(maybeNetwork)
            let fetcher = await network.ivyFetcher
            let genesis = await node.genesisResult
            let localBlock = try await BlockBuilder.buildBlock(
                previous: genesis.block,
                timestamp: genesis.block.timestamp + 1_000,
                target: genesis.block.nextTarget,
                fetcher: fetcher)
            _ = await chainState.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: try VolumeImpl<Block>(node: localBlock), block: localBlock)
            await chainState.updateTipSnapshot(block: localBlock)

            // Sibling fork of equal segment work, anchored at genesis ≠ tip.
            let sibling = try await BlockBuilder.buildBlock(
                previous: genesis.block,
                timestamp: genesis.block.timestamp + 2_000,
                target: genesis.block.nextTarget, nonce: 7, fetcher: fetcher)
            let result = try await Self.resultFor(blocks: [sibling], genesis: genesis.block, fetcher: fetcher, cumulativeWork: UInt256(1))
            let decision = await node.admitSyncedChainAgainstCurrentChain(
                result, chainState: chainState, chainPath: ["Nexus", "toy"])
            guard case .refuse = decision else {
                return XCTFail("child anchored-below-tip result must fall back to whole-chain compare and refuse")
            }
        }
    }

    /// P2-1 (round-2 audit): a child result that is NOT a pure fast-forward of
    /// the current tip must be refused on EVERY branch — including the
    /// genesis-rooted / below-retention shape that previously fell through to
    /// the legacy whole-window own-target compare (where a long cheap-target
    /// fork could out-sum a properly-secured chain).
    func testChildGenesisRootedForkRefusedOutright() async throws {
        try await withSyncNode { node in
            let chainState = await node.lattice.nexus.chain
            let maybeNetwork = await node.network(forPath: ["Nexus"])
            let network = try XCTUnwrap(maybeNetwork)
            let fetcher = await network.ivyFetcher
            let genesis = await node.genesisResult
            // Local: one block above genesis (tip != genesis).
            let localBlock = try await BlockBuilder.buildBlock(
                previous: genesis.block,
                timestamp: genesis.block.timestamp + 1_000,
                target: genesis.block.nextTarget,
                fetcher: fetcher)
            _ = await chainState.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: try VolumeImpl<Block>(node: localBlock), block: localBlock)
            await chainState.updateTipSnapshot(block: localBlock)

            // Peer: a genesis-ROOTED full-chain result (includes genesis, so
            // lowest.blockHeight == 0) with MORE own-target work than local.
            let f1 = try await BlockBuilder.buildBlock(
                previous: genesis.block,
                timestamp: genesis.block.timestamp + 2_000,
                target: genesis.block.nextTarget, nonce: 9, fetcher: fetcher)
            let f2 = try await BlockBuilder.buildBlock(
                previous: f1,
                timestamp: genesis.block.timestamp + 3_000,
                target: f1.nextTarget, fetcher: fetcher)
            let genesisCID = try VolumeImpl<Block>(node: genesis.block).rawCID
            let genesisHeader = SyncBlockHeader(
                cid: genesisCID, height: 0, previousBlockCID: nil,
                target: genesis.block.target, nextTarget: genesis.block.nextTarget,
                timestamp: genesis.block.timestamp,
                specCID: genesis.block.spec.rawCID, spec: genesis.block.spec.node)
            let forkHeaders = try [f1, f2].map { block -> SyncBlockHeader in
                SyncBlockHeader(
                    cid: try VolumeImpl<Block>(node: block).rawCID, height: block.height,
                    previousBlockCID: block.parent?.rawCID,
                    target: block.target, nextTarget: block.nextTarget,
                    timestamp: block.timestamp, specCID: block.spec.rawCID, spec: block.spec.node)
            }
            let syncer = ChainSyncer(
                fetcher: fetcher, store: { _, _ in }, genesisBlockHash: genesisCID)
            let result = try await syncer.syncFromHeaders(
                [genesisHeader] + forkHeaders, cumulativeWork: UInt256(3))

            let decision = await node.admitSyncedChainAgainstCurrentChain(
                result, chainState: chainState, chainPath: ["Nexus", "toy"])
            guard case .refuse = decision else {
                return XCTFail("child genesis-rooted fork (not a tip fast-forward) must be refused outright — child reorgs belong to gossip fork choice")
            }
        }
    }

    /// Review P2: every stop point offered to the header walk must be
    /// anchorable — stop points within contextDepth of the retention floor are
    /// excluded so a stopped walk never strands the sync with a segment that
    /// can neither anchor (context too shallow) nor reach genesis (already
    /// truncated at the stop).
    func testAnchorableStopFloorExcludesNearFloorStops() {
        // Deep chain: floor sits contextDepth above the retention floor.
        XCTAssertEqual(LatticeNode.anchorableStopFloor(tipHeight: 2000, retentionDepth: 1000, contextDepth: 12),
                       1012)
        // Tip just past retention+context: still elevated.
        XCTAssertEqual(LatticeNode.anchorableStopFloor(tipHeight: 1013, retentionDepth: 1000, contextDepth: 12),
                       25)
        // Short chains: everything anchorable or genesis-reachable — floor 0.
        XCTAssertEqual(LatticeNode.anchorableStopFloor(tipHeight: 1012, retentionDepth: 1000, contextDepth: 12), 0)
        XCTAssertEqual(LatticeNode.anchorableStopFloor(tipHeight: 500, retentionDepth: 1000, contextDepth: 12), 0)
        XCTAssertEqual(LatticeNode.anchorableStopFloor(tipHeight: 0, retentionDepth: 1000, contextDepth: 12), 0)
    }

    // MARK: - Helpers

    private enum FixtureError: Error { case unavailable }

    /// Build a segment-shaped SyncResult through the REAL production path:
    /// ChainSyncer.syncFromHeaders with a genesis anchor context. The persisted
    /// chain then contains ONLY the segment blocks (lowest.height > 0), exactly
    /// like a segment-anchored catch-up sync result — full-sync results (which
    /// include genesis) intentionally route to the legacy whole-chain compare.
    private static func resultFor(blocks: [Block], genesis: Block, fetcher: Fetcher, cumulativeWork: UInt256) async throws -> SyncResult {
        let genesisCID = try VolumeImpl<Block>(node: genesis).rawCID
        let anchor = SyncBlockHeader(
            cid: genesisCID, height: genesis.height, previousBlockCID: nil,
            target: genesis.target, nextTarget: genesis.nextTarget,
            timestamp: genesis.timestamp, specCID: genesis.spec.rawCID, spec: genesis.spec.node)
        let headers = try blocks.map { block -> SyncBlockHeader in
            SyncBlockHeader(
                cid: try VolumeImpl<Block>(node: block).rawCID, height: block.height,
                previousBlockCID: block.parent?.rawCID,
                target: block.target, nextTarget: block.nextTarget,
                timestamp: block.timestamp, specCID: block.spec.rawCID, spec: block.spec.node)
        }
        let syncer = ChainSyncer(
            fetcher: fetcher, store: { _, _ in }, genesisBlockHash: genesisCID)
        return try await syncer.syncFromHeaders(
            headers, cumulativeWork: cumulativeWork, knownAnchors: [anchor])
    }

    /// One-block extension of the node's own current tip (fast-forward shape).
    private static func makeExtensionFixture(on node: LatticeNode, blocks _: Int) async throws -> (result: SyncResult, network: ChainNetwork) {
        guard let network = await node.network(forPath: ["Nexus"]) else { throw FixtureError.unavailable }
        let fetcher = await network.ivyFetcher
        let genesis = await node.genesisResult
        let ext = try await BlockBuilder.buildBlock(
            previous: genesis.block,
            timestamp: genesis.block.timestamp + 1_000,
            target: genesis.block.nextTarget,
            fetcher: fetcher)
        let result = try await Self.resultFor(blocks: [ext], genesis: genesis.block, fetcher: fetcher, cumulativeWork: UInt256(1))
        return (result, network)
    }

    private func withSyncNode(_ body: (LatticeNode) async throws -> Void) async throws {
        let keyPair = CryptoUtils.generateKeyPair()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let config = LatticeNodeConfig(
            publicKey: keyPair.publicKey,
            privateKey: keyPair.privateKey,
            listenPort: nextTestPort(),
            storagePath: tmpDir,
            enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        do {
            try await body(node)
        } catch {
            await node.stop()
            throw error
        }
        await node.stop()
    }
}
