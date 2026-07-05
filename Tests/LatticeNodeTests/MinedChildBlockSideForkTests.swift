import XCTest
@testable import Lattice
@testable import LatticeNode
import Lattice
import Ivy
import Tally
import UInt256
import cashew
import VolumeBroker

/// Fix: `submitMinedChildBlock` must announce the mined child's CID as the chain
/// tip ONLY when that block actually wins fork choice (the promoted-to-tip
/// contract centralized in `publishAcceptedBlock`/`broadcastCanonicalTipAnnounce`).
/// A mined child that lands as a SIDE FORK (lost the tie / lower work) must not
/// be announced as the tip — it may at most re-announce the incumbent canonical
/// tip (child-chain ingestion keeps peers' headers-first sync primed).
///
/// RED before the fix: `submitMinedChildBlock` called
/// `broadcastChainAnnounce(tipCID: header.rawCID, …)` UNCONDITIONALLY on accept,
/// so the side-fork child's CID was announced as the tip.
final class MinedChildBlockSideForkTests: XCTestCase {

    /// Boot a per-process child node rooted at Nexus ⊃ Mid (the leaf chain this
    /// node serves), and a separate Nexus fixture CAS to build proof carriers.
    private func makeChildNode(nexusTarget: UInt256 = .max) async throws -> (node: LatticeNode, fixture: TestBrokerFetcher, nexusGenesis: Block, midGenesis: Block) {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let node = try await LatticeNode(
            config: LatticeNodeConfig(
                publicKey: kp.publicKey,
                privateKey: kp.privateKey,
                listenPort: nextTestPort(),
                storagePath: tmp,
                enableLocalDiscovery: false,
                fullChainPath: ["Nexus", "Mid"],
                minPeerKeyBits: 0
            ),
            genesisConfig: testGenesis(spec: testSpec(), directory: "Mid")
        )
        addTeardownBlock { [node] in
            await node.stop()
            try? FileManager.default.removeItem(at: tmp)
        }

        let fixture = cas()
        let midGenesis = await node.genesisResult.block
        // Base all block timestamps on the node's actual Mid genesis timestamp so
        // child blocks are strictly later than their parent (Lattice's monotonic
        // timestamp validation).
        let ts = midGenesis.timestamp
        try await storeBlockFixtureTree(midGenesis, to: fixture)
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: testSpec("Nexus"), timestamp: ts, target: nexusTarget, fetcher: fixture
        )
        return (node, fixture, nexusGenesis, midGenesis)
    }

    private func storeBlockFixtureTree(_ block: Block, to f: TestBrokerFetcher) async throws {
        let header = try VolumeImpl<Block>(node: block)
        await f.store(rawCid: header.rawCID, data: block.toData()!)
        let storer = BufferedStorer()
        try header.storeRecursively(storer: storer)
        for (cid, data) in storer.entryList {
            await f.store(rawCid: cid, data: data)
        }
    }

    /// Mine a Mid child block on `previousMid` whose `parentState` is the Nexus
    /// carrier's prev-state (the committing-parent anchor invariant), embed it in
    /// a Nexus carrier block, generate the single-hop work proof, and store the
    /// whole tree both in the fixture CAS and the node's Mid network so the child
    /// block resolves locally for processing.
    private func minedChild(
        node: LatticeNode,
        fixture: TestBrokerFetcher,
        previousMid: Block,
        nexusGenesis: Block,
        nexusNonce: UInt64,
        ts: Int64
    ) async throws -> (midCID: String, block: Block, proof: ChildBlockProof, carrier: Block, carrierCID: String) {
        // Build the child with the derived (retargeted) target/nextTarget so it
        // passes Lattice's `validateNextTarget` (target == parent.nextTarget and
        // nextTarget == windowed retarget). An explicit target would break that.
        // The carrier's prev-state is the Nexus genesis post-state (height-1 Nexus
        // block). The child's parentState must equal the committing parent's
        // prevState for `verifiedCommittingParentAnchor` to accept it.
        let parentAnchor = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, timestamp: ts, nonce: nexusNonce, fetcher: fixture
        )
        let child = try await BlockBuilder.buildBlock(
            previous: previousMid, parentChainBlock: parentAnchor,
            timestamp: ts, nonce: 0, fetcher: fixture
        )
        try await storeBlockFixtureTree(child, to: fixture)

        let nexusCarrier = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, children: ["Mid": child],
            timestamp: ts, nonce: nexusNonce, fetcher: fixture
        )
        try await storeBlockFixtureTree(nexusCarrier, to: fixture)

        let proof = try await ChildBlockProof.generate(
            rootHeader: try VolumeImpl<Block>(node: nexusCarrier),
            childDirectory: "Mid",
            fetcher: fixture
        )

        // Mirror the proof carrier tree into the node's Mid network so the child
        // body + state resolve during processing. The child's parentState is the
        // Nexus carrier's prev-state (genesis post-state); store that subtree too
        // so the parent-chain state root resolves locally (a real child node holds
        // it via its parent subscription).
        if let network = await node.network(for: "Mid") {
            try await storeBlockFixtureVolumes(child, in: network)
            try await storeBlockFixtureVolumes(nexusGenesis, in: network)
        }

        let midCID = try VolumeImpl<Block>(node: child).rawCID
        let carrierCID = try VolumeImpl<Block>(node: nexusCarrier).rawCID
        return (midCID, child, proof, nexusCarrier, carrierCID)
    }

    func testMinedChildAnnouncedAsTipOnlyWhenItWinsForkChoice() async throws {
        let (node, fixture, nexusGenesis, midGenesis) = try await makeChildNode()
        let networkMaybe = await node.network(for: "Mid")
        let network = try XCTUnwrap(networkMaybe)
        let chainMaybe = await node.chain(for: "Mid")
        let chain = try XCTUnwrap(chainMaybe)
        let ts = midGenesis.timestamp

        await network.resetTipPublishCountsForTesting()

        // 1) A winning mined child at height 1 — it extends the tip and IS the new
        //    canonical tip, so it must be announced as the tip.
        let winner = try await minedChild(
            node: node, fixture: fixture, previousMid: midGenesis,
            nexusGenesis: nexusGenesis, nexusNonce: 1, ts: ts + 1_000
        )
        let winResult = await node.submitProvenChildBlock(
            chainPath: ["Nexus", "Mid"], block: winner.block, proof: winner.proof
        )
        XCTAssertEqual(winResult.status, .accepted, "the winning mined child must be accepted")
        let tipAfterWinner = await chain.getMainChainTip()
        XCTAssertEqual(tipAfterWinner, winner.midCID, "the winning child must become the canonical tip")
        let winnerAnnounceCount = await network.broadcastChainAnnounceCountForTesting()
        XCTAssertEqual(
            winnerAnnounceCount, 1,
            "a winning mined child must announce its tip exactly once"
        )
        let winnerAnnouncedTip = await network.lastBroadcastChainAnnounceTipCIDForTesting()
        XCTAssertEqual(
            winnerAnnouncedTip, winner.midCID,
            "the announced tip CID must be the winning child"
        )

        // 2) A mined child that lands as a SIDE FORK (accepted, but not the new
        //    canonical tip). Build a competing branch B1 → B2 (height 2, strictly
        //    heavier than the single-block A branch). Deliver B2 first while its
        //    parent B1 is absent (a retained, non-canonical side block), then mine
        //    + submit B1. Submitting B1 connects the heavier B branch and promotes
        //    its TIP (B2) via reorg — so B1 is accepted but `getMainChainTip()` is
        //    B2, not B1. B1 must therefore NOT be announced as the tip.
        let b1 = try await minedChild(
            node: node, fixture: fixture, previousMid: midGenesis,
            nexusGenesis: nexusGenesis, nexusNonce: 2, ts: ts + 2_000
        )
        let b2 = try await minedChild(
            node: node, fixture: fixture, previousMid: b1.block,
            nexusGenesis: nexusGenesis, nexusNonce: 3, ts: ts + 3_000
        )
        XCTAssertNotEqual(b1.midCID, winner.midCID, "B1 must be a distinct sibling of the winner")

        // Deliver B2 out of order (parent B1 absent) — retained as a side block.
        _ = await node.submitProvenChildBlock(
            chainPath: ["Nexus", "Mid"], block: b2.block, proof: b2.proof
        )

        await network.resetTipPublishCountsForTesting()

        // Now submit B1. It connects B2 to the chain; the height-2 B branch beats
        // the height-1 winner, so fork choice reorganizes onto B and the tip
        // becomes B2 (B1's descendant), NOT B1 itself.
        let b1Result = await node.submitProvenChildBlock(
            chainPath: ["Nexus", "Mid"], block: b1.block, proof: b1.proof
        )
        XCTAssertEqual(b1Result.status, .accepted, "B1 connects the heavier branch and is accepted")
        let tipAfterB1 = await chain.getMainChainTip()
        XCTAssertEqual(tipAfterB1, b2.midCID, "the heavier branch's TIP (B2) must be canonical, not B1")
        XCTAssertNotEqual(tipAfterB1, b1.midCID, "B1 itself must not be the canonical tip")

        // The core contract: the accepted-but-not-promoted B1 must NEVER be
        // announced as the chain tip. (Before the fix `submitMinedChildBlock`
        // announced `header.rawCID` unconditionally on accept — RED.)
        let b1AnnouncedTip = await network.lastBroadcastChainAnnounceTipCIDForTesting()
        XCTAssertNotEqual(
            b1AnnouncedTip, b1.midCID,
            "a mined child that lost fork choice (B1) must NOT be announced as the chain tip"
        )
    }

    /// Fix: child-block VALIDITY is per-chain PoW (`MinedChildBlockSelection.accepts`),
    /// NOT inherited parent work. In merged mining the Nexus carrier is mined to
    /// clear only the embedded child's EASY target, not the parent's HARD target.
    /// `ChildBlockProof.securingWork()` credits a level's inherited work only when
    /// the blocktree hash clears THAT level's own target — so a carrier that does
    /// not clear the parent's hard target yields `securingWork() == .zero`. The
    /// child is still valid (its own PoW clears the CHILD target, proven by
    /// `accepts`), so a `securingWork() > .zero` validity gate wrongly rejected
    /// children mined at their own difficulty.
    ///
    /// This is reachable ONLY with a hard (non-`UInt256.max`) parent target —
    /// every other test uses a max-target Nexus genesis, which masks it by always
    /// crediting nonzero inherited work.
    ///
    /// RED before the fix: `verifiedCommittingParentAnchor` required
    /// `await proof.securingWork() > .zero`, so this zero-inherited-work child was
    /// `.rejected` and never became the canonical tip.
    func testChildMinedAtOwnDifficultyUnderHardTargetParentIsAccepted() async throws {
        // A hard Nexus target the carrier's PoW hash will NOT clear, so the
        // proof's inherited work is genuinely zero — the exact bug condition.
        let (node, fixture, nexusGenesis, midGenesis) = try await makeChildNode(nexusTarget: UInt256(1_000))
        let chainMaybe = await node.chain(for: "Mid")
        let chain = try XCTUnwrap(chainMaybe)
        let ts = midGenesis.timestamp

        let mined = try await minedChild(
            node: node, fixture: fixture, previousMid: midGenesis,
            nexusGenesis: nexusGenesis, nexusNonce: 1, ts: ts + 1_000
        )

        // The carrier does not clear the hard Nexus target → zero inherited work.
        // (If this is ever non-zero the chosen parent target is too easy.)
        let w = await mined.proof.securingWork()
        XCTAssertEqual(
            w, .zero,
            "carrier must not clear the hard Nexus target — inherited work must be zero (the bug condition)"
        )

        // Validity is per-chain PoW: the carrier clears the CHILD (Mid) target, so
        // `accepts` passes and the zero-inherited-work child must be accepted.
        let r = await node.submitProvenChildBlock(
            chainPath: ["Nexus", "Mid"], block: mined.block, proof: mined.proof
        )
        XCTAssertEqual(
            r.status, .accepted,
            "a child mined at its own difficulty under a hard-target parent must be accepted"
        )
        let tip = await chain.getMainChainTip()
        XCTAssertEqual(
            tip, mined.midCID,
            "the accepted child must become the canonical tip"
        )
    }

    /// Fix (gossip/inbound-parent-proof path, depth ≥3): the SAME
    /// zero-inherited-work-is-not-invalid principle as
    /// `testChildMinedAtOwnDifficultyUnderHardTargetParentIsAccepted`, but for the
    /// OTHER admission path — the inbound-parent-proof relay in
    /// `ParentChainBlockExtractor.handle(...)`, reached at chain depth ≥3 where
    /// `requiresInboundParentProof()` is true (`expectedParentPath.count > 1`).
    ///
    /// Scenario: a node serving "Stable" (path `["Nexus","Mid","Stable"]`,
    /// `expectedParentPath == ["Nexus","Mid"]`) receives a "Mid" parent block whose
    /// inbound proof roots at the Nexus carrier. When that Nexus carrier is mined to
    /// clear only Mid's EASY target (not Nexus's HARD target), the proof's
    /// `securingWork()` is legitimately `.zero` — yet the Mid block is valid (its own
    /// PoW clears the carrier root, proven by `MinedChildBlockSelection.accepts`).
    ///
    /// RED before the fix: `verifiedInboundParentProofs` and `verifiedParentAnchor`
    /// each required `await proofForParent.securingWork() > .zero`, so this
    /// zero-inherited-work proof was filtered out → `verifiedProofs.isEmpty` →
    /// `handle(...)` `return`ed, dropping the WHOLE relay (anchor + continuity edge +
    /// downstream "Stable" child extraction) and stalling the deep child.
    ///
    /// GREEN after the fix: both gate only on `accepts(...)`; the proof is admitted
    /// and the parent anchor is produced. (Union-weight zero-exclusion is handled
    /// downstream in `recordVerifiedWorkContributions`, not on this admission gate.)
    func testInboundParentProofAtDepth3WithZeroSecuringWorkIsAdmitted() async throws {
        // Hard Nexus target the carrier's PoW hash will NOT clear → zero inherited work.
        let (node, fixture, nexusGenesis, midGenesis) = try await makeChildNode(nexusTarget: UInt256(1_000))
        let ts = midGenesis.timestamp

        // A Mid child embedded in a Nexus carrier, with the single-hop `["Mid"]`
        // proof rooted at that carrier — exactly the inbound parent block + proof a
        // node one level deeper (serving "Stable") receives over the relay.
        let mined = try await minedChild(
            node: node, fixture: fixture, previousMid: midGenesis,
            nexusGenesis: nexusGenesis, nexusNonce: 1, ts: ts + 1_000
        )

        // The carrier does not clear the hard Nexus target → zero inherited work.
        // (If this is ever non-zero the chosen parent target is too easy and the test
        // would no longer exercise the bug condition.)
        let w = await mined.proof.securingWork()
        XCTAssertEqual(
            w, .zero,
            "carrier must not clear the hard Nexus target — inherited work must be zero (the bug condition)"
        )

        // An extractor for a deeper chain: serving "Stable" under parent path
        // ["Nexus","Mid"], so `requiresInboundParentProof()` is true (count 2 > 1)
        // and the inbound-parent-proof admission path runs.
        let extractor = ParentChainBlockExtractor(
            childDirectory: "Stable",
            parentDirectory: "Mid",
            parentChainPath: ["Nexus", "Mid"],
            extractor: LatticeChildBlockExtractor(),
            node: node
        )

        // Drive the two gates that the fix removed the `securingWork() > .zero`
        // conjunct from. The parent block is the Mid child; its CID is the relayed
        // parent CID. With the gates present (RED) both filter this zero-work proof
        // out; with the gates removed (GREEN) `accepts(...)` admits it.
        let verified = await extractor.verifiedInboundParentProofsForTesting(
            cid: mined.midCID, parentBlock: mined.block, node: node, inboundProofs: [mined.proof]
        )
        XCTAssertFalse(
            verified.isEmpty,
            "a depth-3 inbound parent proof with zero inherited work must NOT be filtered out (its child PoW is valid)"
        )

        let anchor = await extractor.verifiedParentAnchorForTesting(
            cid: mined.midCID, parentBlock: mined.block, node: node, inboundProofs: verified
        )
        let producedAnchor = try XCTUnwrap(
            anchor,
            "the parent anchor must be produced from the zero-inherited-work inbound proof (relay must NOT be dropped)"
        )
        XCTAssertEqual(
            producedAnchor.blockHash, mined.midCID,
            "the produced anchor must bind to the relayed parent block CID"
        )
    }

    /// Fix (the wedge): the DIRECT-CHILD parent-extractor path (`expectedParentPath.count == 1`).
    /// A pure parent-stream follower of a direct child of Nexus (leaf path `["Nexus","Mid"]`,
    /// parent path `["Nexus"]`) receives, on its Nexus subscription, the CHILD-ONLY CARRIER that
    /// secures a Mid block — a Nexus-shaped block whose PoW hash did NOT clear Nexus's hard target
    /// (so it was never a canonical Nexus block; it exists only as the proof carrier). Validity is
    /// per-level: the Mid child cleared THIS carrier's hash (`childTarget >= carrierHash`).
    ///
    /// RED before the fix: `parentBlockWorkVerified`'s `count == 1` branch validated the carrier
    /// with standalone `validateProofOfWork` (target >= hash), which a child-only carrier can never
    /// pass → "invalid work" → no anchor → the follower is wedged and can never adopt the Mid
    /// block. GREEN after: the count==1 branch falls back to the child-proof predicate (`accepts`
    /// on `["Nexus","Mid"]`, resolving the child from the proof's SEALED entries) and admits it.
    func testChildOnlyRootCarrierAdmittedViaChildProof() async throws {
        // Hard Nexus target → the carrier's hash will NOT clear it → child-only carrier.
        let (node, fixture, nexusGenesis, midGenesis) = try await makeChildNode(nexusTarget: UInt256(1_000))
        let ts = midGenesis.timestamp
        let mined = try await minedChild(
            node: node, fixture: fixture, previousMid: midGenesis,
            nexusGenesis: nexusGenesis, nexusNonce: 1, ts: ts + 1_000
        )
        // Confirm the bug condition: the carrier is child-only (zero inherited work at the root).
        let w = await mined.proof.securingWork()
        XCTAssertEqual(w, .zero, "carrier must be child-only (must NOT clear the hard Nexus target)")

        // A DIRECT-child extractor: "Mid" under parent path ["Nexus"] (count 1) — the wedged path.
        let extractor = ParentChainBlockExtractor(
            childDirectory: "Mid",
            parentDirectory: "Nexus",
            parentChainPath: ["Nexus"],
            extractor: LatticeChildBlockExtractor(),
            node: node
        )

        // The parent block delivered on the Nexus subscription IS the child-only carrier, with the
        // single-hop ["Mid"] proof rooted at it. Must be admitted (child cleared the carrier's
        // target), not rejected as "invalid work".
        let anchor = await extractor.verifiedParentAnchorForTesting(
            cid: mined.carrierCID, parentBlock: mined.carrier, node: node, inboundProofs: [mined.proof]
        )
        let produced = try XCTUnwrap(
            anchor,
            "a child-only root carrier must be admitted via its child-proof, not rejected as 'invalid work'"
        )
        XCTAssertEqual(produced.blockHash, mined.carrierCID, "the anchor must bind the carrier CID")

        // Negative: with NO proof, a root-level carrier that does not clear its own target has no
        // demonstrated securing work and MUST be rejected — no free admission of a non-clearing root.
        let rejected = await extractor.verifiedParentAnchorForTesting(
            cid: mined.carrierCID, parentBlock: mined.carrier, node: node, inboundProofs: []
        )
        XCTAssertNil(rejected, "a non-clearing root carrier with NO securing proof must be rejected")
    }
}
