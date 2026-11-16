import Foundation
import Lattice
import LatticeNodeCore
@testable import LatticeNodeSim
import XCTest
import cashew

/// The mempool and miner work inside `ChainCore.step`: a move of the act-on tip
/// reaches the level's `MiningState` in the same step, and a mined grind is
/// weighed in one host step and answered once it executes.
final class ChainCoreMiningTests: XCTestCase {
    private static let now = World.genesisTime + 1_000_000
    private let peer = PeerID(key: "peer", session: 1)
    private let key = CryptoUtils.generateKeyPair()
    private var world: World!
    private var chain: [SimBlock] = []
    private var content: SimCAS!

    override func setUp() async throws {
        var rng = SplitMix64(state: 0x317)
        world = try await World.generate(
            rng: &rng, honestBlocks: 4, forkProbability: 0, spamBlocks: 0
        )
        chain = world.honest.compactMap { world.blocks[$0] }
        content = SimCAS(world.genesisContent)
    }

    /// A core that weighed `blocks` from `peer`'s log: a page of their IDs,
    /// then the objects it asks for.
    private func weighed(_ blocks: [SimBlock], bodyWindow: Int = 4) -> ChainCore {
        var core = ChainCore(tree: world.bootstrap.tree.detached(), config: ChainCoreConfig(bodyWindow: bodyWindow))
        let asked = core.step(.peerReady(peer), now: Self.now).compactMap { effect -> UInt64? in
            if case .send(_, .getStream(let id, _, _, _)) = effect { return id }
            return nil
        }
        let ids = blocks.enumerated().map { StreamEntry(position: UInt64($0.offset + 1), entry: .header($0.element.cid)) }
        let page = core.step(.received(peer, .stream(StreamPage(
            requestID: asked.first ?? 0, logID: "peer", entries: ids, hasMore: false
        ))), now: Self.now)
        for case .send(_, .getData(let id, _)) in page {
            _ = core.step(.received(peer, .headers(HeadersResponse(
                requestID: id,
                entries: blocks.map { HeaderEntry(block: $0.block, children: $0.children) },
                hasMore: false
            ))), now: Self.now)
        }
        return core
    }

    /// Deliver the first block's body and run its connect.
    private func executeFirst(_ core: inout ChainCore, transactions: [String] = []) async throws -> [ChainEffect] {
        content.put(world.blocks[chain[0].cid]!.body)
        let arrived = core.step(.bodyFetched(cid: chain[0].cid), now: Self.now)
        let job = try XCTUnwrap(arrived.compactMap { effect -> ConnectJob? in
            if case .connect(let job) = effect { return job }
            return nil
        }.first)
        let verdict = await ChainTree.connect(
            job, fetcher: content, validationContext: ValidationContext(nowMilliseconds: Self.now)
        )
        return core.step(.connected(verdict, transactions: transactions), now: Self.now)
    }

    private func mining(_ effects: [ChainEffect]) -> [MiningEffect] {
        effects.compactMap {
            if case .mining(let effect) = $0 { return effect }
            return nil
        }
    }

    func testAnExecutionThatConfirmsAWaitingSubmitAnswersItAsAdmitted() async throws {
        var core = weighed(Array(chain.prefix(2)))
        XCTAssertEqual(core.mining.tipCID, world.genesis.cid)
        let transaction = try signed(key, [AccountAction(owner: address(key), delta: -2)], nonce: 0)
        let cid = try Mempool.cid(of: transaction)
        let submitted = mining(core.step(
            .mining(.transactionReceived(transaction, origin: .local(replyID: 7))), now: Self.now
        ))
        guard case .preflight(let preflight)? = submitted.first else { return XCTFail("\(submitted)") }
        XCTAssertEqual(preflight.tipCID, world.genesis.cid)

        let applied = try await executeFirst(&core, transactions: [cid])
        XCTAssertEqual(core.snapshot.actOnTip, chain[0].cid)
        XCTAssertEqual(core.mining.tipCID, chain[0].cid)
        // The connect result named its transactions: the move confirms the
        // waiting submit in the same step, before any verdict on the new tip.
        XCTAssertTrue(mining(applied).contains {
            if case .transactionAdmitted(7, cid, _, _) = $0 { true } else { false }
        }, "\(mining(applied))")
        XCTAssertFalse(mining(applied).contains {
            if case .preflight(let job) = $0 { job.cid == cid } else { false }
        })
        XCTAssertEqual(core.mining.pendingAdmissions, 0)
        // Persist and publish precede every mining effect of the step.
        let firstMining = try XCTUnwrap(applied.firstIndex { if case .mining = $0 { true } else { false } })
        for (index, effect) in applied.enumerated() {
            switch effect {
            case .persist, .publish: XCTAssertLessThan(index, firstMining)
            default: break
            }
        }
        // The verdict on the old tip changes nothing.
        XCTAssertTrue(mining(core.step(.mining(.preflighted(preflight, .ready, balances: funded(preflight))), now: Self.now)).isEmpty)
        XCTAssertEqual(core.mining.mempool.count, 0)
    }

    /// Show `blocks` as `peer`'s log, positions from `from`: the page
    /// answers the stream request in flight (or is pushed), and the headers
    /// it asks for are sent.
    @discardableResult
    private func show(_ blocks: [SimBlock], from: UInt64, to core: inout ChainCore) -> [ChainEffect] {
        let ids = blocks.enumerated().map { StreamEntry(position: from + UInt64($0.offset), entry: .header($0.element.cid)) }
        let page = core.step(.received(peer, .stream(StreamPage(
            requestID: core.sync.peers[peer]?.stream?.requestID ?? 0, logID: "peer", entries: ids, hasMore: false
        ))), now: Self.now)
        var effects = page
        for case .send(_, .getData(let id, _)) in page {
            effects += core.step(.received(peer, .headers(HeadersResponse(
                requestID: id, entries: blocks.map { HeaderEntry(block: $0.block, children: $0.children) }, hasMore: false
            ))), now: Self.now)
        }
        return effects
    }

    /// Execute `blocks` in order, each body delivered and its connect run.
    private func execute(_ blocks: [SimBlock], world: World, content: SimCAS, on core: inout ChainCore) async throws {
        for block in blocks {
            content.put(world.blocks[block.cid]!.body)
            var effects = core.step(.bodyFetched(cid: block.cid), now: Self.now)
            while let job = effects.lazy.compactMap({ effect -> ConnectJob? in
                if case .connect(let job) = effect { return job }
                return nil
            }).first {
                let verdict = await ChainTree.connect(
                    job, fetcher: content, validationContext: ValidationContext(nowMilliseconds: Self.now)
                )
                effects = core.step(.connected(verdict), now: Self.now)
                for case .persist(let batch) in effects {
                    for state in batch.states { try await storeMaterialized(state, in: content) }
                }
            }
        }
    }

    private func peerArrival(_ core: inout ChainCore, nonce: UInt64) throws -> [MiningEffect] {
        let tx = try signed(key, [AccountAction(owner: address(key), delta: -2)], nonce: nonce)
        return mining(core.step(.mining(.transactionReceived(tx, origin: .peer(peer))), now: Self.now))
    }

    /// The sync latch: a peer's transaction is dropped (no effect, nothing
    /// pending, no blame) until a peer's log has been read to its end and
    /// the act-on tip has reached the best header; every other origin and a
    /// template request is served meanwhile. Once set it stays set when the
    /// gap reopens. A core started again, or one whose tip is current but
    /// that has read no peer's log, is unsynced.
    func testAPeerTransactionWaitsForTheSyncLatch() async throws {
        var rng = SplitMix64(state: 0x5E7C)
        let world = try await World.generate(rng: &rng, honestBlocks: 6, forkProbability: 0, spamBlocks: 0)
        let chain = world.honest.compactMap { world.blocks[$0] }
        let content = SimCAS(world.genesisContent)

        // A current tip, no peer's log read: unsynced.
        var alone = ChainCore(tree: world.bootstrap.tree.detached(), config: ChainCoreConfig(bodyWindow: 8))
        _ = alone.step(.peerReady(peer), now: Self.now)
        XCTAssertEqual(alone.snapshot.actOnTip, alone.snapshot.bestHeaderTip)
        XCTAssertFalse(alone.synced)
        XCTAssertTrue(try peerArrival(&alone, nonce: 0).isEmpty)

        var core = ChainCore(tree: world.bootstrap.tree.detached(), config: ChainCoreConfig(bodyWindow: 8))
        _ = core.step(.peerReady(peer), now: Self.now)
        show(Array(chain.prefix(4)), from: 1, to: &core)
        XCTAssertEqual(core.snapshot.bestHeaderHeight, 4)
        XCTAssertFalse(core.synced, "the peer's log is read, the tip not yet executed")
        XCTAssertTrue(try peerArrival(&core, nonce: 0).isEmpty)
        XCTAssertEqual(core.mining.pendingAdmissions, 0)
        XCTAssertEqual(core.mining.pendingPeerAdmissions, 0)
        for (nonce, origin) in [
            TransactionOrigin.local(replyID: 1), .submitted(replyID: 2), .returned, .restored(addedAt: 0),
        ].enumerated() {
            let tx = try signed(key, [AccountAction(owner: address(key), delta: -2)], nonce: UInt64(nonce) + 1)
            let effects = mining(core.step(.mining(.transactionReceived(tx, origin: origin)), now: Self.now))
            XCTAssertTrue(effects.contains { if case .preflight = $0 { true } else { false } }, "\(origin): \(effects)")
        }
        let template = mining(core.step(
            .mining(.templateRequested(replyID: 9, TemplateRequest(rewardRecipient: nil))), now: Self.now
        ))
        XCTAssertTrue(template.contains { if case .buildTemplate = $0 { true } else { false } }, "\(template)")

        try await execute(Array(chain.prefix(3)), world: world, content: content, on: &core)
        XCTAssertFalse(core.synced, "one block short")
        try await execute([chain[3]], world: world, content: content, on: &core)
        XCTAssertTrue(core.synced)
        XCTAssertTrue(try peerArrival(&core, nonce: 9).contains { if case .preflight = $0 { true } else { false } })

        // The gap reopens: the latch stays.
        show(Array(chain[4...]), from: 5, to: &core)
        XCTAssertEqual(core.snapshot.bestHeaderHeight, 6)
        XCTAssertEqual(core.snapshot.actOnHeight, 4)
        XCTAssertTrue(core.synced)
        XCTAssertTrue(try peerArrival(&core, nonce: 10).contains { if case .preflight = $0 { true } else { false } })

        // Started again over the same tree: unsynced until it reads a peer.
        var restarted = ChainCore(tree: core.tree.detached(), config: ChainCoreConfig(bodyWindow: 8))
        XCTAssertFalse(restarted.synced)
        XCTAssertTrue(try peerArrival(&restarted, nonce: 11).isEmpty)
    }

    /// The stream's tail is pushed only once the level is synced, as Bitcoin
    /// Core announces no block during initial download. A peer that read our
    /// log to its end before the latch misses what was weighed meanwhile; the
    /// first push after the latch lies past its position, so it pulls the gap.
    func testTheStreamIsPushedOnlyOnceSynced() async throws {
        var rng = SplitMix64(state: 0x5E7C)
        let world = try await World.generate(rng: &rng, honestBlocks: 6, forkProbability: 0, spamBlocks: 0)
        let chain = world.honest.compactMap { world.blocks[$0] }
        let content = SimCAS(world.genesisContent)
        let subscriber = PeerID(key: "subscriber", session: 1)
        func pushes(_ effects: [ChainEffect]) -> [StreamPage] {
            effects.compactMap { if case .send(subscriber, .stream(let page)) = $0, page.requestID == 0 { page } else { nil } }
        }

        var core = ChainCore(tree: world.bootstrap.tree.detached(), config: ChainCoreConfig(bodyWindow: 8))
        _ = core.step(.peerReady(peer), now: Self.now)
        _ = core.step(.peerReady(subscriber), now: Self.now)
        let subscribedAt = core.sync.log.count
        _ = core.step(.received(subscriber, .getStream(requestID: 1, logID: core.sync.log.id, after: subscribedAt, own: "")), now: Self.now)
        XCTAssertEqual(core.sync.peers[subscriber]?.subscribed, true)

        XCTAssertTrue(pushes(show(Array(chain.prefix(4)), from: 1, to: &core)).isEmpty, "unsynced: nothing is pushed")
        XCTAssertFalse(core.synced)
        try await execute(Array(chain.prefix(4)), world: world, content: content, on: &core)
        XCTAssertTrue(core.synced)
        let missed = core.sync.log.count
        XCTAssertGreaterThan(missed, subscribedAt)
        let push = try XCTUnwrap(pushes(show(Array(chain[4...]), from: 5, to: &core)).first, "synced: the tail is pushed")
        XCTAssertEqual(push.entries.first?.position, missed + 1)

        // The subscriber, at `subscribedAt` in our log, pulls the gap.
        let server = PeerID(key: "server", session: 1)
        var client = ChainCore(tree: world.bootstrap.tree.detached(), config: ChainCoreConfig(bodyWindow: 8))
        let first = client.step(.peerReady(server), now: Self.now)
        let id = try XCTUnwrap(first.lazy.compactMap { effect -> UInt64? in
            if case .send(server, .getStream(let id, _, _, _)) = effect { return id }
            return nil
        }.first)
        _ = client.step(.received(server, .stream(StreamPage(
            requestID: id, logID: core.sync.log.id, entries: [], hasMore: false
        ))), now: Self.now)
        let resumed = client.step(.received(server, .stream(push)), now: Self.now)
        let pulls = resumed.compactMap { effect -> UInt64? in
            if case .send(server, .getStream(_, let logID, let after, _)) = effect, logID == core.sync.log.id { return after }
            return nil
        }
        XCTAssertEqual(pulls, [subscribedAt], "the gap is pulled from where the subscriber stood")
    }

    /// The same latch at a child level, through the level simulator's
    /// network: every core ends synced at every depth (and the simulator
    /// fails a latch that is ever unset); a core restored from its store, or
    /// one that mined every grind itself with no peer, is unsynced, and drops
    /// a peer's child transaction while serving a local one.
    func testTheSyncLatchAtAChildLevel() async throws {
        var config = LevelSimConfig(seed: 0x5E7C)
        config.levels = 2
        config.cores = 2
        config.withholder = false
        config.zeroWork = false
        config.scheduleLiar = false
        config.forkProbability = 0
        config.doubleProbability = 0
        config.drop = 0
        var sim = try await LevelSimulator.make(config)
        _ = try await sim.run()
        let alpha = LevelWorld.alpha
        let tx = try SimTransactions.signed(
            keys: [key], accountActions: [AccountAction(owner: address(key), delta: -2)], nonce: 0, chainPath: alpha
        )
        func peerArrival(_ host: inout NodeCore) -> [NodeEffect] {
            host.step(.level(alpha, .mining(.transactionReceived(tx, origin: .peer(peer)))), now: Self.now)
        }
        func preflights(_ effects: [NodeEffect]) -> Bool {
            effects.contains { if case .level(alpha, .mining(.preflight)) = $0 { true } else { false } }
        }
        for name in ["core0", "core1"] {
            var host = try XCTUnwrap(sim.cores[name]).core
            for path in sim.world.paths {
                XCTAssertEqual(host.levels[path]?.synced, true, "\(name) \(path)")
            }
            XCTAssertTrue(preflights(peerArrival(&host)), name)
        }

        let store = try XCTUnwrap(sim.durable("core0"))
        var restored = try NodeCore.restore(
            root: store.records[LevelWorld.nexus]!,
            facts: store.levels.mapValues { StoredFacts($0.facts) },
            specs: store.levels.mapValues { $0.headers.values.compactMap(\.spec) },
            hosted: sim.world.hosted,
            config: sim.coreConfig,
            logID: "core0",
            cursors: store.levels.mapValues(\.cursors)
        )
        XCTAssertEqual(restored.levels[alpha]?.synced, false)
        XCTAssertTrue(peerArrival(&restored).isEmpty)

        // Every grind mined here, every body held: a current tip, no peer.
        var alone = NodeCore(root: sim.world.rootBootstrap.tree.detached(), hosted: sim.world.hosted)
        for grind in sim.world.grinds {
            var queue: [NodeEvent] = [.mined(grind.mined)]
            while !queue.isEmpty {
                for effect in alone.step(queue.removeFirst(), now: Self.now) {
                    switch effect {
                    case .level(let path, .fetchBody(let cid)):
                        queue.append(.level(path, .bodyFetched(cid: cid)))
                    case .connect(let path, let job):
                        let verdict = await ChainTree.connect(
                            job, fetcher: sim.world.cas, parentFacts: alone.parentFacts(for: path),
                            validationContext: ValidationContext(nowMilliseconds: Self.now)
                        )
                        queue.append(.level(path, .connected(verdict)))
                    default:
                        break
                    }
                }
            }
        }
        let level = try XCTUnwrap(alone.levels[alpha])
        XCTAssertEqual(level.snapshot.actOnTip, level.snapshot.bestHeaderTip)
        XCTAssertFalse(level.synced)
        XCTAssertTrue(peerArrival(&alone).isEmpty)
        let local = alone.step(.level(alpha, .mining(.transactionReceived(tx, origin: .local(replyID: 1)))), now: Self.now)
        XCTAssertTrue(local.contains {
            switch $0 {
            case .level(alpha, .mining(.preflight)), .level(alpha, .mining(.transactionRefused(1, _))): true
            default: false
            }
        }, "\(local)")
    }

    /// A build on the old tip is neither thrown away nor issued again when
    /// the tip moves: its result answers the request.
    func testATemplateBuildWaitingOnTheOldTipAnswersWhenItLands() async throws {
        var core = weighed(Array(chain.prefix(2)))
        let requested = mining(core.step(
            .mining(.templateRequested(replyID: 1, TemplateRequest(rewardRecipient: nil))), now: Self.now
        ))
        guard case .buildTemplate(let first)? = requested.first else { return XCTFail("\(requested)") }
        XCTAssertEqual(first.tipCID, world.genesis.cid)

        let applied = mining(try await executeFirst(&core))
        XCTAssertEqual(core.mining.tipCID, chain[0].cid)
        XCTAssertFalse(applied.contains { if case .buildTemplate = $0 { true } else { false } }, "\(applied)")
        XCTAssertFalse(applied.contains { if case .templateRefused = $0 { true } else { false } }, "\(applied)")
        let answered = mining(core.step(.mining(.templateBuilt(first, nil)), now: Self.now))
        XCTAssertEqual(answered.count, 1, "\(answered)")
        guard case .templateRefused(1, .buildFailed)? = answered.first else { return XCTFail("\(answered)") }
    }

    /// A block this node produced is pushed whether or not the level is
    /// synced: it may be canonical, and it adds weight (Bitcoin Core
    /// announces a block it found even during initial download).
    func testAMinedBlockIsPushedBeforeTheSyncLatch() throws {
        let path = world.bootstrap.tree.context!.path
        let subscriber = PeerID(key: "subscriber", session: 1)
        var host = NodeCore(root: world.bootstrap.tree.detached(), hosted: [])
        _ = host.step(.peerReady(subscriber), now: Self.now)
        let (logID, count) = try XCTUnwrap(host.levels[path].map { ($0.sync.log.id, $0.sync.log.count) })
        _ = host.step(.received(subscriber, path, .getStream(
            requestID: 1, logID: logID, after: count, own: ""
        )), now: Self.now)
        XCTAssertEqual(host.levels[path]?.sync.peers[subscriber]?.subscribed, true)
        XCTAssertEqual(host.levels[path]?.synced, false, "the subscriber's log is not read")

        let grind = MinedGrind(root: chain[0].block, rootChildren: chain[0].children, carried: [])
        let effects = host.step(.mined(grind, replyID: nil), now: Self.now)
        let pushed = effects.compactMap { effect -> [String]? in
            if case .level(_, .send(subscriber, .stream(let page))) = effect, page.requestID == 0 {
                return page.entries.map(\.entry.cid)
            }
            return nil
        }
        XCTAssertEqual(pushed, [[chain[0].cid]], "\(effects)")
        XCTAssertEqual(host.levels[path]?.synced, false)
    }

    func testAMinedRootIsAnsweredOnceItExecutes() async throws {
        let path = world.bootstrap.tree.context!.path
        var host = NodeCore(root: world.bootstrap.tree.detached(), hosted: [])
        let grind = MinedGrind(root: chain[0].block, rootChildren: chain[0].children, carried: [])
        let weighed = host.step(.mined(grind, replyID: 3), now: Self.now)
        XCTAssertTrue(weighed.contains { if case .persist = $0 { true } else { false } }, "\(weighed)")
        XCTAssertFalse(weighed.contains { if case .level(_, .workSubmitted) = $0 { true } else { false } },
                       "a weighed root is answered once it executes")
        // Its body is asked for in the same step.
        XCTAssertTrue(weighed.contains {
            if case .level(_, .fetchBody(let cid)) = $0 { cid == chain[0].cid } else { false }
        }, "\(weighed)")

        content.put(world.blocks[chain[0].cid]!.body)
        let arrived = host.step(.level(path, .bodyFetched(cid: chain[0].cid)), now: Self.now)
        let job = try XCTUnwrap(arrived.compactMap { effect -> ConnectJob? in
            if case .connect(_, let job) = effect { return job }
            return nil
        }.first)
        let verdict = await ChainTree.connect(
            job, fetcher: content, validationContext: ValidationContext(nowMilliseconds: Self.now)
        )
        let executed = host.step(.level(path, .connected(verdict)), now: Self.now)
        let persisted = executed.firstIndex { if case .persist = $0 { true } else { false } }
        let answered = executed.firstIndex {
            if case .level(_, .workSubmitted(3, .executed(chain[0].cid))) = $0 { true } else { false }
        }
        XCTAssertNotNil(answered, "\(executed)")
        XCTAssertLessThan(persisted ?? .max, answered ?? .min, "the answer follows the write")

        XCTAssertTrue(host.step(.mined(grind, replyID: 4), now: Self.now).contains {
            if case .level(_, .workSubmitted(4, .duplicate)) = $0 { true } else { false }
        })
    }
}
