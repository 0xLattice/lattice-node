import Lattice
import LatticeNodeCore
import LatticeNodeSim
import XCTest

/// Body download and execution: `Core.step` asks the content layer for the
/// window's bodies by CID and connects them in parent order.
final class CoreBodyTests: XCTestCase {
    private static let now = World.genesisTime + 1_000_000
    private let peer = PeerID(key: "peer", session: 1)
    private var world: World!
    private var chain: [SimBlock] = []

    override func setUp() async throws {
        var rng = SplitMix64(state: 0x5_1C)
        world = try await World.generate(rng: &rng, honestBlocks: 12, forkProbability: 0, spamBlocks: 2)
        chain = world.honest.compactMap { world.blocks[$0] }
    }

    /// A core that weighed `blocks` as `peer`'s catch-up page (so nothing
    /// is left in flight), and the fact log it persisted from genesis.
    private func weighed(_ blocks: [SimBlock], window: Int = 4) -> (Core, [BlockImportBatch]) {
        var core = Core(tree: world.bootstrap.tree, config: CoreConfig(bodyWindow: window))
        let asked = core.step(.peerReady(peer), now: Self.now).compactMap { effect -> UInt64? in
            if case .send(_, .getHeaders(let request)) = effect { return request.requestID }
            return nil
        }
        let effects = core.step(.received(peer, .headers(HeadersResponse(
            requestID: asked.first ?? 0,
            entries: blocks.map { HeaderEntry(block: $0.block, children: $0.children) },
            hasMore: false
        ))), now: Self.now)
        for block in blocks { XCTAssertTrue(core.tree.contains(blockHash: block.cid)) }
        return (core, [world.bootstrap.facts] + persisted(effects))
    }

    private func persisted(_ effects: [Effect]) -> [BlockImportBatch] {
        effects.flatMap { effect -> [BlockImportBatch] in
            if case .persist(let batch) = effect { return batch.facts }
            return []
        }
    }

    private func bodyFetches(_ effects: [Effect]) -> [String] {
        effects.compactMap {
            if case .fetchBody(let cid) = $0 { return cid }
            return nil
        }
    }

    private func jobs(_ effects: [Effect]) -> [ConnectJob] {
        effects.compactMap {
            if case .connect(let job) = $0 { return job }
            return nil
        }
    }

    private func facts(_ effects: [Effect]) -> [ChainFact] {
        effects.flatMap { effect -> [ChainFact] in
            if case .persist(let batch) = effect { return batch.facts.flatMap(\.facts) }
            return []
        }
    }

    private func hasDisconnect(_ effects: [Effect]) -> Bool {
        effects.contains { if case .disconnect = $0 { true } else { false } }
    }

    /// Run a job the way the shell does, over the whole world's content.
    private func run(_ job: ConnectJob) async -> ConnectVerdict {
        await ChainTree.connect(
            job, fetcher: world.content, validationContext: ValidationContext(nowMilliseconds: Self.now)
        )
    }

    /// Deliver `cid`'s body, run any connect it starts, and apply its
    /// verdict; returns the effects of the verdict's step.
    private func deliver(_ cid: String, to core: inout Core) async -> [Effect] {
        var effects = core.step(.bodyFetched(cid: cid), now: Self.now)
        var last: [Effect] = []
        while let job = jobs(effects).first {
            let verdict = await run(job)
            effects = core.step(.connected(verdict), now: Self.now)
            last = effects
        }
        return last
    }

    func testTheNextWindowOfTheBestChainIsAskedForInParentOrder() {
        var core = Core(tree: world.bootstrap.tree, config: CoreConfig(bodyWindow: 3))
        _ = core.step(.peerReady(peer), now: Self.now)
        let effects = core.step(.received(peer, .headers(HeadersResponse(
            requestID: 0,
            entries: chain.prefix(6).map { HeaderEntry(block: $0.block, children: $0.children) },
            hasMore: false
        ))), now: Self.now)
        XCTAssertEqual(bodyFetches(effects), chain.prefix(3).map(\.cid))
        XCTAssertEqual(core.bodyWindow, chain.prefix(3).map(\.cid))
        XCTAssertEqual(core.bodies.requested, Set(chain.prefix(3).map(\.cid)))
        // Nothing is asked twice while it is in flight.
        XCTAssertTrue(bodyFetches(core.step(.tick, now: Self.now + 60_000)).isEmpty)
    }

    func testBodiesConnectInParentOrderWhateverOrderTheyArriveIn() async throws {
        var (core, _) = weighed(Array(chain.prefix(4)))
        // The second body alone starts nothing: its parent is not executed.
        XCTAssertTrue(jobs(core.step(.bodyFetched(cid: chain[1].cid), now: Self.now)).isEmpty)
        XCTAssertEqual(core.snapshot.actOnTip, world.genesis.cid)

        let first = core.step(.bodyFetched(cid: chain[0].cid), now: Self.now)
        let job = try XCTUnwrap(jobs(first).first)
        XCTAssertEqual(job.blockHash, chain[0].cid)
        XCTAssertEqual(core.bodies.connecting, chain[0].cid)

        // Its verdict persists a validation, advances the act-on tip, and
        // starts the next connect, whose body is already here.
        let applied = core.step(.connected(await run(job)), now: Self.now)
        XCTAssertTrue(facts(applied).contains { if case .validation(let v) = $0 { v.blockHash == chain[0].cid } else { false } })
        XCTAssertEqual(core.snapshot.actOnTip, chain[0].cid)
        XCTAssertEqual(jobs(applied).map(\.blockHash), [chain[1].cid])
        // The window slid: the block after the old window is asked for.
        XCTAssertEqual(bodyFetches(applied), [chain[4].cid].filter { core.tree.contains(blockHash: $0) })

        _ = core.step(.connected(await run(jobs(applied)[0])), now: Self.now)
        XCTAssertEqual(core.snapshot.actOnTip, chain[1].cid)
    }

    func testAMissingBodyIsAnAvailabilityWaitAndNeverBlame() {
        var (core, _) = weighed(Array(chain.prefix(3)))
        for later in stride(from: Self.now, through: Self.now + 3_600_000, by: 600_000) {
            let effects = core.step(.tick, now: later)
            XCTAssertFalse(hasDisconnect(effects))
            XCTAssertTrue(bodyFetches(effects).isEmpty, "the content layer retries, not the core")
        }
        XCTAssertEqual(core.snapshot.actOnTip, world.genesis.cid)
        XCTAssertEqual(core.bodies.requested.count, 3)
        XCTAssertNotNil(core.sync.peers[peer])
    }

    func testAnInvalidBodyIsExcludedItsWorkStillWeighsAndNoOneIsBlamed() async throws {
        let invalid = try XCTUnwrap(world.blocks[world.invalidBody])
        let child = try XCTUnwrap(world.blocks[world.invalidBodyChild])
        // Two blocks on honest block 2 outweigh nothing else: the invalid
        // branch is the best chain.
        var (core, _) = weighed(Array(chain.prefix(2)) + [invalid, child])
        XCTAssertEqual(core.tree.canonicalTip, child.cid)
        var before = core.tree
        let weightBefore = before.subtreeWeight(forHash: chain[1].cid)?.uint256Value

        _ = await deliver(chain[0].cid, to: &core)
        _ = await deliver(chain[1].cid, to: &core)
        XCTAssertEqual(core.snapshot.actOnTip, chain[1].cid)
        let effects = await deliver(invalid.cid, to: &core)

        XCTAssertTrue(facts(effects).contains { if case .exclusion(let e) = $0 { e.blockHash == invalid.cid } else { false } })
        XCTAssertTrue(core.tree.isExcludedRoot(invalid.cid))
        XCTAssertFalse(core.tree.hasExecutedAncestry(blockHash: invalid.cid))
        XCTAssertTrue(core.tree.contains(blockHash: child.cid), "the excluded subtree stays weighed")
        var after = core.tree
        XCTAssertEqual(after.subtreeWeight(forHash: chain[1].cid)?.uint256Value, weightBefore, "its work still weighs")
        XCTAssertEqual(core.tree.canonicalTip, chain[1].cid, "validity selects")
        XCTAssertEqual(core.snapshot.actOnTip, chain[1].cid)
        XCTAssertTrue(core.bodyWindow.isEmpty)
        XCTAssertFalse(hasDisconnect(effects))
        XCTAssertNotNil(core.sync.peers[peer], "the peer that relayed it is not blamed")
    }

    func testAVerdictWithoutDecisionAsksForTheBodyAgain() async throws {
        var (core, _) = weighed(Array(chain.prefix(2)))
        let job = try XCTUnwrap(jobs(core.step(.bodyFetched(cid: chain[0].cid), now: Self.now)).first)
        // The body is gone from the content store by the time the job runs.
        let empty = SimCAS()
        let verdict = await ChainTree.connect(job, fetcher: empty, validationContext: ValidationContext(nowMilliseconds: Self.now))
        XCTAssertNotNil(verdict.retryFailure)
        let effects = core.step(.connected(verdict), now: Self.now)
        XCTAssertEqual(bodyFetches(effects), [chain[0].cid])
        XCTAssertTrue(facts(effects).isEmpty)
        XCTAssertFalse(hasDisconnect(effects))
        XCTAssertNil(core.bodies.connecting)
    }

    func testARestartReplaysTheExecutedSetAndAsksOnlyForWhatIsLeft() async throws {
        var (core, log) = weighed(Array(chain.prefix(4)))
        log += persisted(await deliver(chain[0].cid, to: &core))
        log += persisted(await deliver(chain[1].cid, to: &core))
        XCTAssertEqual(core.snapshot.actOnTip, chain[1].cid)

        var restored = try Core.restore(
            replaying: log, context: world.context, spec: world.spec, config: CoreConfig(bodyWindow: 4)
        )
        XCTAssertEqual(restored.snapshot.actOnTip, chain[1].cid)
        let effects = restored.step(.tick, now: Self.now)
        XCTAssertEqual(bodyFetches(effects), [chain[2].cid, chain[3].cid])
    }
}
