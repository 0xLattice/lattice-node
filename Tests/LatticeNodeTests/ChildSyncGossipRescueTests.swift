import XCTest
@testable import Lattice
@testable import LatticeNode
import Ivy
import UInt256
import cashew
import VolumeBroker

/// Prerequisite for unconditional child fast-forward SYNC admission: sync
/// deliberately never decides a child REORG (own-target sums are meaningless
/// for child ordering — a carrier's real weight is the securing work in its
/// ChildBlockProof), so the machinery that DOES own that decision — gossip
/// fork choice over trueCumWork = same-chain subtree weight + inherited
/// securing work — must be able to rescue a follower that is parked on a
/// cheaper branch (e.g. one it fast-forwarded onto via sync).
///
/// This test proves that rescue end-to-end at the node layer: a follower
/// whose canonical branch is TALLER but secured by child-only carriers
/// (zero inherited work) must reorg onto a SHORTER sibling branch whose
/// carrier clears the parent target (strictly greater trueCumWork), delivered
/// through the same proven-child ingestion gossip relay uses.
final class ChildSyncGossipRescueTests: XCTestCase {

    /// Parent (Nexus) target hard enough that a random carrier usually does
    /// NOT clear it, yet easy enough that a short nonce search finds a clearing
    /// one: p(clear) = 1/4 per nonce. workForTarget(max >> 2) == 4, so one
    /// clearing carrier out-weighs several trivial-target child blocks.
    private static let nexusTarget = UInt256.max >> 2

    private func makeChildNode() async throws -> (node: LatticeNode, fixture: TestBrokerFetcher, nexusGenesis: Block, midGenesis: Block) {
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
        let ts = midGenesis.timestamp
        try await storeBlockFixtureTree(midGenesis, to: fixture)
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: testSpec("Nexus"), timestamp: ts, target: Self.nexusTarget, fetcher: fixture
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

    /// Mine a Mid child block on `previousMid`, embedded in a Nexus carrier whose
    /// PoW hash clears the (hard) Nexus target iff `carrierClears`. A clearing
    /// carrier contributes workForTarget(nexusTarget) of inherited securing work;
    /// a non-clearing (child-only) carrier contributes zero.
    private func minedChild(
        node: LatticeNode,
        fixture: TestBrokerFetcher,
        previousMid: Block,
        nexusGenesis: Block,
        carrierClears: Bool,
        nonceSeed: UInt64,
        ts: Int64
    ) async throws -> (midCID: String, block: Block, proof: ChildBlockProof) {
        let parentAnchor = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, timestamp: ts, nonce: nonceSeed, fetcher: fixture
        )
        let child = try await BlockBuilder.buildBlock(
            previous: previousMid, parentChainBlock: parentAnchor,
            timestamp: ts, nonce: 0, fetcher: fixture
        )
        try await storeBlockFixtureTree(child, to: fixture)

        // Nonce-search the carrier for the required clear/non-clear outcome so
        // the branch weights are deterministic, not left to hash luck.
        var carrier: Block? = nil
        for nonce in nonceSeed..<(nonceSeed + 10_000) {
            let candidate = try await BlockBuilder.buildBlock(
                previous: nexusGenesis, children: ["Mid": child],
                timestamp: ts, nonce: nonce, fetcher: fixture
            )
            let clears = candidate.validateProofOfWork(nexusHash: candidate.proofOfWorkHash())
            if clears == carrierClears {
                carrier = candidate
                break
            }
        }
        let minedCarrier = try XCTUnwrap(carrier, "no nonce in the search window produced carrierClears=\(carrierClears)")
        try await storeBlockFixtureTree(minedCarrier, to: fixture)

        let proof = try await ChildBlockProof.generate(
            rootHeader: try VolumeImpl<Block>(node: minedCarrier),
            childDirectory: "Mid",
            fetcher: fixture
        )
        let expectedWork = await proof.securingWork()
        if carrierClears {
            XCTAssertGreaterThan(expectedWork, .zero, "clearing carrier must contribute inherited securing work")
        } else {
            XCTAssertEqual(expectedWork, .zero, "child-only carrier must contribute zero inherited securing work")
        }

        if let network = await node.network(for: "Mid") {
            try await storeBlockFixtureVolumes(child, in: network)
            try await storeBlockFixtureVolumes(nexusGenesis, in: network)
        }
        return (try VolumeImpl<Block>(node: child).rawCID, child, proof)
    }

    /// Rescue boundary, case 1 (WORKS?): the competing heavier-secured branch
    /// forks at the tip's parent — its block arrives at the SAME height as the
    /// local tip, so the gossip pipeline's height-monotonicity guard
    /// (processBlockAndRecoverReorgUnlocked: `block.height < localHeight` →
    /// rejected) does not fire, and inherited-weight fork choice can decide.
    func testGossipReorgsEqualHeightSiblingWithHeavierSecuringWork() async throws {
        let (node, fixture, nexusGenesis, midGenesis) = try await makeChildNode()
        let chainMaybe = await node.chain(for: "Mid")
        let chain = try XCTUnwrap(chainMaybe)
        let ts = midGenesis.timestamp

        // Incumbent: one child block secured by a child-only carrier (zero
        // inherited work).
        let a1 = try await minedChild(
            node: node, fixture: fixture, previousMid: midGenesis,
            nexusGenesis: nexusGenesis, carrierClears: false, nonceSeed: 1_000, ts: ts + 1_000
        )
        let a1Result = await node.submitProvenChildBlock(chainPath: ["Nexus", "Mid"], block: a1.block, proof: a1.proof)
        XCTAssertEqual(a1Result.status, .accepted)
        let tipOnA = await chain.getMainChainTip()
        XCTAssertEqual(tipOnA, a1.midCID)

        // Challenger: an EQUAL-HEIGHT sibling whose carrier clears the hard
        // Nexus target — strictly greater trueCumWork (1 + workForTarget(target)
        // vs 1 + 0), so this is NOT an equal-work tie and must be adopted.
        let b1 = try await minedChild(
            node: node, fixture: fixture, previousMid: midGenesis,
            nexusGenesis: nexusGenesis, carrierClears: true, nonceSeed: 3_000, ts: ts + 2_000
        )
        let b1Result = await node.submitProvenChildBlock(chainPath: ["Nexus", "Mid"], block: b1.block, proof: b1.proof)
        XCTAssertEqual(b1Result.status, .accepted, "an equal-height heavier-secured sibling must be accepted")

        var tip = await chain.getMainChainTip()
        for _ in 0..<50 where tip != b1.midCID {
            try await Task.sleep(for: .milliseconds(100))
            tip = await chain.getMainChainTip()
        }
        XCTAssertEqual(
            tip, b1.midCID,
            "fork choice must adopt the equal-height sibling with strictly greater inherited securing work"
        )
    }

    /// Rescue boundary, case 2 — the held-heavier connector rescue (formerly a
    /// characterization of a permanent stall; flipped now that the rescue
    /// transport is wired).
    ///
    /// The heavier-secured branch is offered newest-first while the follower's
    /// cheap branch is TALLER — the realistic shape of the canonical branch
    /// reaching a follower parked on a cheaper fork:
    ///  - B2 (equal height) is accepted DETACHED: the chain records its missing
    ///    parent B1 in `missingBlockHashes` (a held, not-yet-connectable branch);
    ///  - B1's push is still hard-rejected by the gossip height-monotonicity
    ///    guard (cheap-DoS protection, unchanged) — but its fully verified
    ///    evidence (bytes + committing anchor + work proofs) is cached;
    ///  - the connector rescue replays the cached B1 precisely because the
    ///    chain declared it missing (pull-shaped admission), the branch becomes
    ///    contiguously body-present, and fork choice — the sole switch
    ///    authority — reorgs onto the heavier-secured tip B2.
    func testHeldHeavierRescueConvergesCheaperTallerBranchWithForkBelowTipHeight() async throws {
        let (node, fixture, nexusGenesis, midGenesis) = try await makeChildNode()
        let chainMaybe = await node.chain(for: "Mid")
        let chain = try XCTUnwrap(chainMaybe)
        let ts = midGenesis.timestamp

        // Branch A (the follower's branch): two child blocks secured only by
        // child-only carriers — zero inherited work, subtree weight = 2 trivial
        // own-target units.
        let a1 = try await minedChild(
            node: node, fixture: fixture, previousMid: midGenesis,
            nexusGenesis: nexusGenesis, carrierClears: false, nonceSeed: 1_000, ts: ts + 1_000
        )
        let a2 = try await minedChild(
            node: node, fixture: fixture, previousMid: a1.block,
            nexusGenesis: nexusGenesis, carrierClears: false, nonceSeed: 2_000, ts: ts + 2_000
        )
        let a1Result = await node.submitProvenChildBlock(chainPath: ["Nexus", "Mid"], block: a1.block, proof: a1.proof)
        XCTAssertEqual(a1Result.status, .accepted)
        let a2Result = await node.submitProvenChildBlock(chainPath: ["Nexus", "Mid"], block: a2.block, proof: a2.proof)
        XCTAssertEqual(a2Result.status, .accepted)
        let tipOnA = await chain.getMainChainTip()
        XCTAssertEqual(tipOnA, a2.midCID, "the follower starts parked on the taller cheap branch")

        // Branch B: B1 (height 1) → B2 (height 2), BOTH with clearing carriers.
        // trueCumWork(B) strictly exceeds trueCumWork(A) = 2.
        let b1 = try await minedChild(
            node: node, fixture: fixture, previousMid: midGenesis,
            nexusGenesis: nexusGenesis, carrierClears: true, nonceSeed: 3_000, ts: ts + 3_000
        )
        let b2 = try await minedChild(
            node: node, fixture: fixture, previousMid: b1.block,
            nexusGenesis: nexusGenesis, carrierClears: true, nonceSeed: 4_000, ts: ts + 4_000
        )

        // Deliver newest-first, the realistic gossip shape for a follower that
        // just came back online. B1 (height 1 < local tip height 2) is still
        // hard-rejected by the push height-monotonicity guard — the rescue is
        // PULL-shaped: its verified evidence is cached and replayed only
        // because the chain declared B1 a missing ancestor of held B2.
        let b2Result = await node.submitProvenChildBlock(chainPath: ["Nexus", "Mid"], block: b2.block, proof: b2.proof)
        let b1Result = await node.submitProvenChildBlock(chainPath: ["Nexus", "Mid"], block: b1.block, proof: b1.proof)
        XCTAssertEqual(
            b1Result.status, .rejected,
            "the push height guard must still drop the below-tip connector at arrival (the rescue is pull, not a guard relaxation)"
        )

        // The connector rescue drains asynchronously: B1 replays, the branch
        // connects, and fork choice must converge on the heavier-secured B2.
        var tip = await chain.getMainChainTip()
        for _ in 0..<100 where tip != b2.midCID {
            try await Task.sleep(for: .milliseconds(100))
            tip = await chain.getMainChainTip()
        }
        XCTAssertEqual(
            tip, b2.midCID,
            "held-heavier rescue must converge the follower onto the heavier-secured branch (b2Result=\(b2Result.status), b1Result=\(b1Result.status))"
        )
    }

    /// Memory-pin hardening: the detached-evidence cache must DECLINE to hold a
    /// body larger than `maxDetachedEvidenceBytes` so an attacker cannot pin
    /// 64 × maxBlockSize per followed chain by gossiping large below-tip proven
    /// connectors. An at-cap body is still cached (adoption/backfill unaffected);
    /// an over-cap body is dropped from the speculative FIFO.
    func testDetachedEvidenceCacheRejectsOversizedBodies() async throws {
        let (node, _, _, _) = try await makeChildNode()
        let key = await node.chainKey(forDirectory: "Mid")
        let anchor = ParentAnchor(blockHash: "anchor", parentHash: nil, height: 0)

        // At the cap: cached.
        let atCap = Data(repeating: 0xAB, count: LatticeNode.maxDetachedEvidenceBytes)
        await node.cacheDetachedChildEvidence(
            directory: "Mid", chainPath: nil, cid: "cid-at-cap",
            blockData: atCap, selectedAnchor: anchor,
            processingRootHash: .zero, verified: []
        )
        var cached = await node.detachedChildEvidence[key] ?? [:]
        XCTAssertNotNil(cached["cid-at-cap"], "an at-cap body must be cached")

        // Over the cap: declined.
        let overCap = Data(repeating: 0xAB, count: LatticeNode.maxDetachedEvidenceBytes + 1)
        await node.cacheDetachedChildEvidence(
            directory: "Mid", chainPath: nil, cid: "cid-over-cap",
            blockData: overCap, selectedAnchor: anchor,
            processingRootHash: .zero, verified: []
        )
        cached = await node.detachedChildEvidence[key] ?? [:]
        XCTAssertNil(cached["cid-over-cap"], "an over-cap body must NOT be cached (memory-pin hardening)")
        let order = await node.detachedChildEvidenceOrder[key] ?? []
        XCTAssertFalse(order.contains("cid-over-cap"), "an over-cap body must not enter the FIFO order")
    }
}
