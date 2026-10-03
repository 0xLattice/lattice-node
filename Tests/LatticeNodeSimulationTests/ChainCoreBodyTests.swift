import Foundation
import Lattice
import LatticeNodeCore
import LatticeNodeSim
import XCTest
import cashew

/// Body download and execution: `ChainCore.step` asks the content layer for the
/// window's bodies by CID and connects them in parent order.
final class ChainCoreBodyTests: XCTestCase {
    private static let now = World.genesisTime + 1_000_000
    private let peer = PeerID(key: "peer", session: 1)
    private var world: World!
    private var chain: [SimBlock] = []
    /// The shell's content store: genesis content, the bodies delivered,
    /// and the post-states persisted.
    private var content: SimCAS!

    override func setUp() async throws {
        var rng = SplitMix64(state: 0x5_1C)
        world = try await World.generate(
            rng: &rng, honestBlocks: 12, forkProbability: 0, spamBlocks: 2
        )
        chain = world.honest.compactMap { world.blocks[$0] }
        content = SimCAS(world.genesisContent)
    }

    /// A core that weighed `blocks` from `peer`, its stream read to the end
    /// (so nothing is left in flight), and the fact log it persisted from genesis.
    private func weighed(_ blocks: [SimBlock], window: Int = 4) -> (ChainCore, [BlockImportBatch]) {
        var core = ChainCore(tree: world.bootstrap.tree, config: ChainCoreConfig(bodyWindow: window))
        let asked = core.step(.peerReady(peer), now: Self.now).compactMap { effect -> UInt64? in
            if case .send(_, .getStream(let id, _, _, _)) = effect { return id }
            return nil
        }
        _ = asked
        let effects = show(&core, blocks.map { HeaderEntry(block: $0.block, children: $0.children) }, at: Self.now)
        for block in blocks { XCTAssertTrue(core.tree.contains(blockHash: block.cid)) }
        return (core, [world.bootstrap.facts] + persisted(effects))
    }

    private var shown: [String: HeaderEntry] = [:]

    /// `entries` shown by `peer` the way a peer shows headers: appended to
    /// its log (answering the stream request in flight, or pushed), then
    /// served as the core asks. Returns every effect of the exchange.
    private func show(_ core: inout ChainCore, _ entries: [HeaderEntry], at now: Int64) -> [ChainEffect] {
        guard let state = core.sync.peers[peer] else { return [] }
        let first = core.sync.cursors[peer.key] == nil ? 1 : state.taken + 1
        let ids = entries.enumerated().map { offset, entry -> StreamEntry in
            let cid = (try? BlockHeader(node: entry.block).rawCID) ?? ""
            shown[cid] = entry
            return StreamEntry(position: first + UInt64(offset), entry: .header(cid))
        }
        var effects = core.step(.received(peer, .stream(StreamPage(
            requestID: state.stream?.requestID ?? 0, logID: "peer", entries: ids, hasMore: false
        ))), now: now)
        var all = effects
        while let ask = effects.compactMap({ effect -> (UInt64, [String])? in
            if case .send(_, .getData(let id, let cids)) = effect { return (id, cids) }
            return nil
        }).first {
            effects = core.step(.received(peer, .headers(HeadersResponse(
                requestID: ask.0, entries: ask.1.compactMap { shown[$0] }, hasMore: false
            ))), now: now)
            all += effects
        }
        return all
    }

    private func persisted(_ effects: [ChainEffect]) -> [BlockImportBatch] {
        effects.flatMap { effect -> [BlockImportBatch] in
            if case .persist(let batch) = effect { return batch.facts }
            return []
        }
    }

    private func bodyFetches(_ effects: [ChainEffect]) -> [String] {
        effects.compactMap {
            if case .fetchBody(let cid) = $0 { return cid }
            return nil
        }
    }

    private func jobs(_ effects: [ChainEffect]) -> [ConnectJob] {
        effects.compactMap {
            if case .connect(let job) = $0 { return job }
            return nil
        }
    }

    private func facts(_ effects: [ChainEffect]) -> [ChainFact] {
        effects.flatMap { effect -> [ChainFact] in
            if case .persist(let batch) = effect { return batch.facts.flatMap(\.facts) }
            return []
        }
    }

    private func wakes(_ effects: [ChainEffect]) -> [Int64] {
        effects.compactMap {
            if case .wakeAt(let time) = $0 { return time }
            return nil
        }
    }

    private func cancels(_ effects: [ChainEffect]) -> [String] {
        effects.compactMap {
            if case .cancelBody(let cid) = $0 { return cid }
            return nil
        }
    }

    private func batches(_ effects: [ChainEffect]) -> [ChainBatch] {
        effects.compactMap {
            if case .persist(let batch) = $0 { return batch }
            return nil
        }
    }

    private func hasDisconnect(_ effects: [ChainEffect]) -> Bool {
        effects.contains { if case .disconnect = $0 { true } else { false } }
    }

    /// Run a job the way the shell does, over its content store.
    private func run(_ job: ConnectJob) async -> ConnectVerdict {
        await ChainTree.connect(
            job, fetcher: content, validationContext: ValidationContext(nowMilliseconds: Self.now)
        )
    }

    /// The content layer delivered `cid`'s body into the store.
    private func arrive(_ cid: String, _ core: inout ChainCore) -> [ChainEffect] {
        content.put(world.blocks[cid]!.body)
        return core.step(.bodyFetched(cid: cid), now: Self.now)
    }

    /// Execute a step's persists as the shell does: content first.
    private func persist(_ effects: [ChainEffect], storingStates: Bool = true) async throws {
        for case .persist(let batch) in effects where storingStates {
            for state in batch.states {
                try await storeMaterialized(state, in: content)
            }
        }
    }

    /// Deliver `cid`'s body, run any connect it starts, and apply its
    /// verdict; returns the effects of the verdict's step.
    private func deliver(_ cid: String, to core: inout ChainCore, storingStates: Bool = true) async throws -> [ChainEffect] {
        var effects = arrive(cid, &core)
        var last: [ChainEffect] = []
        while let job = jobs(effects).first {
            let verdict = await run(job)
            effects = core.step(.connected(verdict), now: Self.now)
            try await persist(effects, storingStates: storingStates)
            last = effects
        }
        return last
    }

    func testTheNextWindowOfTheBestChainIsAskedForInParentOrder() {
        var core = ChainCore(tree: world.bootstrap.tree, config: ChainCoreConfig(bodyWindow: 3))
        _ = core.step(.peerReady(peer), now: Self.now)
        let effects = show(&core, chain.prefix(6).map { HeaderEntry(block: $0.block, children: $0.children) }, at: Self.now)
        XCTAssertEqual(bodyFetches(effects), chain.prefix(3).map(\.cid))
        XCTAssertEqual(core.bodyWindow, chain.prefix(3).map(\.cid))
        XCTAssertEqual(core.bodies.requested, Set(chain.prefix(3).map(\.cid)))
        // Nothing is asked twice while it is in flight.
        XCTAssertTrue(bodyFetches(core.step(.tick, now: Self.now + 60_000)).isEmpty)
    }

    func testBodiesConnectInParentOrderWhateverOrderTheyArriveIn() async throws {
        var (core, _) = weighed(Array(chain.prefix(4)))
        // The second body alone starts nothing: its parent is not executed.
        XCTAssertTrue(jobs(arrive(chain[1].cid, &core)).isEmpty)
        XCTAssertEqual(core.snapshot.actOnTip, world.genesis.cid)

        let first = arrive(chain[0].cid, &core)
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

        try await persist(applied)
        _ = core.step(.connected(await run(jobs(applied)[0])), now: Self.now)
        XCTAssertEqual(core.snapshot.actOnTip, chain[1].cid)
    }

    func testAMissingBodyIsAnAvailabilityWaitAndNeverBlame() {
        var (core, _) = weighed(Array(chain.prefix(3)))
        // Header sync's own catch-up deadlines are not this test's subject:
        // the peer that relayed the headers is gone, and no body is ever
        // tied to it.
        _ = core.step(.peerGone(peer), now: Self.now)
        for later in stride(from: Self.now, through: Self.now + 3_600_000, by: 600_000) {
            let effects = core.step(.tick, now: later)
            XCTAssertFalse(hasDisconnect(effects))
            XCTAssertTrue(bodyFetches(effects).isEmpty, "the content layer retries, not the core")
            XCTAssertTrue(cancels(effects).isEmpty)
        }
        XCTAssertEqual(core.snapshot.actOnTip, world.genesis.cid)
        XCTAssertEqual(core.bodies.requested.count, 3)
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

        _ = try await deliver(chain[0].cid, to: &core)
        _ = try await deliver(chain[1].cid, to: &core)
        XCTAssertEqual(core.snapshot.actOnTip, chain[1].cid)
        let effects = try await deliver(invalid.cid, to: &core)

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

    func testAVerdictWithoutDecisionParksTheBodyWithAPacedBackoff() async throws {
        var (core, _) = weighed(Array(chain.prefix(2)))
        var job = try XCTUnwrap(jobs(arrive(chain[0].cid, &core)).first)
        let base = core.config.bodyRetryBase
        var now = Self.now
        // The body is gone from the content store by the time each job runs:
        // every retry waits twice as long as the last, and a wake is asked
        // for exactly when it is due.
        for attempt in 0..<4 {
            let verdict = await ChainTree.connect(job, fetcher: SimCAS(), validationContext: ValidationContext(nowMilliseconds: now))
            XCTAssertNotNil(verdict.retryFailure)
            let effects = core.step(.connected(verdict), now: now)
            XCTAssertTrue(bodyFetches(effects).isEmpty, "a retry waits")
            XCTAssertTrue(facts(effects).isEmpty)
            XCTAssertFalse(hasDisconnect(effects))
            XCTAssertNil(core.bodies.connecting)
            let due = now + (base << Int64(attempt))
            XCTAssertEqual(wakes(effects).min(), due)
            XCTAssertTrue(bodyFetches(core.step(.tick, now: due - 1)).isEmpty)
            now = due
            XCTAssertEqual(bodyFetches(core.step(.tick, now: now)), [chain[0].cid])
            job = try XCTUnwrap(jobs(core.step(.bodyFetched(cid: chain[0].cid), now: now)).first)
        }
        XCTAssertEqual(core.bodies.parked[chain[0].cid]?.attempts, 4)
    }

    func testARestartReplaysTheExecutedSetAndAsksOnlyForWhatIsLeft() async throws {
        var (core, log) = weighed(Array(chain.prefix(4)))
        log += persisted(try await deliver(chain[0].cid, to: &core))
        log += persisted(try await deliver(chain[1].cid, to: &core))
        XCTAssertEqual(core.snapshot.actOnTip, chain[1].cid)

        var restored = try ChainCore.restore(
            replaying: log, context: world.context, specs: [world.spec], config: ChainCoreConfig(bodyWindow: 4)
        )
        XCTAssertEqual(restored.snapshot.actOnTip, chain[1].cid)
        let effects = restored.step(.tick, now: Self.now)
        XCTAssertEqual(bodyFetches(effects), [chain[2].cid, chain[3].cid])
    }

    func testAWindowChangeStartsTheBackoffOver() async throws {
        var (core, _) = weighed(Array(chain.prefix(3)))
        let job = try XCTUnwrap(jobs(arrive(chain[0].cid, &core)).first)
        let verdict = await ChainTree.connect(job, fetcher: SimCAS(), validationContext: ValidationContext(nowMilliseconds: Self.now))
        _ = core.step(.connected(verdict), now: Self.now)
        let parked = try XCTUnwrap(core.bodies.parked[chain[0].cid])
        // A header weighed off the best chain moves neither the act-on tip
        // nor the window: the wait stands.
        let side = try XCTUnwrap(world.blocks[world.spam[0]])
        let off = show(&core, [HeaderEntry(block: side.block, children: side.children)], at: Self.now + 1)
        XCTAssertTrue(core.tree.contains(blockHash: side.cid))
        XCTAssertFalse(bodyFetches(off).contains(chain[0].cid))
        XCTAssertEqual(core.bodies.parked[chain[0].cid], parked)
        // A new header extends the best chain: the window changed, so the
        // wait is over.
        let effects = show(&core, [HeaderEntry(block: chain[3].block, children: chain[3].children)], at: Self.now + 1)
        XCTAssertTrue(bodyFetches(effects).contains(chain[0].cid))
        XCTAssertTrue(core.bodies.parked.isEmpty)
    }

    func testABodyThatLeavesTheWindowUnarrivedIsCancelled() async throws {
        let invalid = try XCTUnwrap(world.blocks[world.invalidBody])
        let child = try XCTUnwrap(world.blocks[world.invalidBodyChild])
        var (core, _) = weighed(Array(chain.prefix(2)) + [invalid, child])
        XCTAssertEqual(core.bodyWindow, [chain[0].cid, chain[1].cid, invalid.cid, child.cid])
        _ = try await deliver(chain[0].cid, to: &core)
        _ = try await deliver(chain[1].cid, to: &core)
        // Executing the invalid body moves the best chain off its branch:
        // the child's body, never arrived, is cancelled.
        let effects = try await deliver(invalid.cid, to: &core)
        XCTAssertEqual(cancels(effects), [child.cid])
        XCTAssertFalse(core.bodies.requested.contains(child.cid))
    }

    func testAnExecutionPersistsItsPostStateBeforeItsFacts() async throws {
        var (core, _) = weighed(Array(chain.prefix(3)))
        _ = try await deliver(chain[0].cid, to: &core)
        // Honest block 2 pays its reward: its execution changes the state.
        let effects = try await deliver(chain[1].cid, to: &core)
        let batch = try XCTUnwrap(batches(effects).first)
        let state = try XCTUnwrap(batch.states.first)
        XCTAssertEqual(try LatticeStateHeader(node: state).rawCID, chain[1].block.postState.rawCID)
        XCTAssertNotEqual(chain[1].block.postState.rawCID, chain[1].block.prevState.rawCID)
        XCTAssertTrue(content.contains(chain[1].block.postState.rawCID))
    }

    func testAPostStateNeverStoredLeavesTheNextBlockWithoutAVerdict() async throws {
        var (core, _) = weighed(Array(chain.prefix(3)))
        _ = try await deliver(chain[0].cid, to: &core)
        _ = try await deliver(chain[1].cid, to: &core, storingStates: false)
        XCTAssertEqual(core.snapshot.actOnTip, chain[1].cid)
        let effects = try await deliver(chain[2].cid, to: &core)
        XCTAssertTrue(facts(effects).isEmpty, "block 3 executes on block 2's state, which was never stored")
        XCTAssertNotNil(core.bodies.parked[chain[2].cid])
        XCTAssertEqual(core.snapshot.actOnTip, chain[1].cid)
    }

    /// A node-local failure (here, content that fails to serialize while the
    /// block executes) is no verdict on the block: retriable, never an
    /// exclusion. The block parks and is retried after the backoff.
    func testALocalFailureIsNeverAnExclusion() async throws {
        var (core, _) = weighed(Array(chain.prefix(2)))
        _ = try await deliver(chain[0].cid, to: &core)
        let job = try XCTUnwrap(jobs(arrive(chain[1].cid, &core)).first)
        let verdict = await ChainTree.connect(
            job,
            fetcher: FailingAfterBlock(content: content, block: chain[1].cid, parent: chain[0].cid),
            validationContext: ValidationContext(nowMilliseconds: Self.now)
        )
        let effects = core.step(.connected(verdict), now: Self.now)
        XCTAssertFalse(verdict.provesInvalid)
        XCTAssertFalse(facts(effects).contains { if case .exclusion = $0 { true } else { false } })
        XCTAssertFalse(core.tree.isExcludedRoot(chain[1].cid))
        XCTAssertNotNil(core.bodies.parked[chain[1].cid])
    }
}

/// Serves a block and its parent, and fails every other read as content
/// this node cannot serialize: a local fault, not a property of the block.
private struct FailingAfterBlock: Fetcher {
    let content: SimCAS
    let block: String
    let parent: String

    func fetch(rawCid: String) async throws -> Data {
        guard rawCid == block || rawCid == parent else {
            throw DataErrors.serializationFailed
        }
        return try await content.fetch(rawCid: rawCid)
    }
}
