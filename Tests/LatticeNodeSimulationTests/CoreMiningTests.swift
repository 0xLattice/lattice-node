import Foundation
import Lattice
import LatticeNodeCore
import LatticeNodeSim
import XCTest
import cashew

/// The mempool and miner work inside `Core.step`: a move of the act-on tip
/// reaches the level's `Mining` in the same step, and a mined grind is
/// weighed in one host step and answered once it executes.
final class CoreMiningTests: XCTestCase {
    private static let now = World.genesisTime + 1_000_000
    private let peer = PeerID(key: "peer", session: 1)
    private let key = CryptoUtils.generateKeyPair()
    private var world: World!
    private var chain: [SimBlock] = []
    private var content: SimCAS!

    override func setUp() async throws {
        var rng = SplitMix64(state: 0x317)
        world = try await World.generate(
            rng: &rng, honestBlocks: 4, forkProbability: 0, spamBlocks: 0, genesisActions: false
        )
        chain = world.honest.compactMap { world.blocks[$0] }
        content = SimCAS(world.genesisContent)
    }

    /// A core that weighed `blocks` from `peer`'s log: a page of their IDs,
    /// then the objects it asks for.
    private func weighed(_ blocks: [SimBlock]) -> Core {
        var core = Core(tree: world.bootstrap.tree, config: CoreConfig(bodyWindow: 4))
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
    private func executeFirst(_ core: inout Core, transactions: [String] = []) async throws -> [Effect] {
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

    private func mining(_ effects: [Effect]) -> [MiningEffect] {
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
        XCTAssertEqual(core.snapshot.miningEpoch, 1)
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
        XCTAssertTrue(mining(core.step(.mining(.preflighted(preflight, .ready)), now: Self.now)).isEmpty)
        XCTAssertEqual(core.mining.mempool.count, 0)
    }

    func testATemplateBuildWaitingOnTheOldTipIsIssuedAgainOnTheNewOne() async throws {
        var core = weighed(Array(chain.prefix(2)))
        let requested = mining(core.step(
            .mining(.templateRequested(replyID: 1, TemplateRequest(rewardRecipient: nil))), now: Self.now
        ))
        guard case .buildTemplate(let first)? = requested.first else { return XCTFail("\(requested)") }
        XCTAssertEqual(first.tipCID, world.genesis.cid)
        XCTAssertEqual(first.tipEpoch, 0)

        let applied = mining(try await executeFirst(&core))
        guard case .buildTemplate(let again)? = applied.first(where: {
            if case .buildTemplate = $0 { true } else { false }
        }) else { return XCTFail("\(applied)") }
        XCTAssertEqual(again.tipCID, chain[0].cid)
        XCTAssertEqual(again.tipEpoch, core.snapshot.miningEpoch)
        // The old build's result issues nothing.
        XCTAssertTrue(mining(core.step(.mining(.templateBuilt(first, nil)), now: Self.now)).isEmpty)
    }

    func testAMinedRootIsAnsweredOnceItExecutes() async throws {
        let path = world.bootstrap.tree.context!.path
        var host = HostCore(root: world.bootstrap.tree, hosted: [])
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
            if case .connect(_, let job, _) = effect { return job }
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
