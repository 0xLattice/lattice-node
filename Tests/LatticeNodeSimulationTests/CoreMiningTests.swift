import Foundation
import Lattice
import LatticeNodeCore
import LatticeNodeSim
import XCTest
import cashew

/// The mempool and miner work inside `Core.step`: a move of the act-on tip
/// reaches the level's `Mining` in the same step, with what the connected
/// block confirmed, and a mined grind is weighed in one host step and
/// answered.
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

    /// A core that weighed `blocks` from `peer`'s catch-up page.
    private func weighed(_ blocks: [SimBlock]) -> Core {
        var core = Core(tree: world.bootstrap.tree, config: CoreConfig(bodyWindow: 4))
        let asked = core.step(.peerReady(peer), now: Self.now).compactMap { effect -> UInt64? in
            if case .send(_, .getHeaders(let request)) = effect { return request.requestID }
            return nil
        }
        _ = core.step(.received(peer, .headers(HeadersResponse(
            requestID: asked.first ?? 0,
            entries: blocks.map { HeaderEntry(block: $0.block, children: $0.children) },
            hasMore: false
        ))), now: Self.now)
        return core
    }

    /// Deliver the first block's body and run its connect; the verdict's
    /// step carries `transactions` as the executed block's.
    private func executeFirst(_ core: inout Core, transactions: [Transaction]) async throws -> [Effect] {
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

    func testAnExecutionThatMovesTheActOnTipConfirmsItsTransactionsInTheSameStep() async throws {
        var core = weighed(Array(chain.prefix(2)))
        XCTAssertEqual(core.mining.tipCID, world.genesis.cid)
        let transaction = try signed(key, [AccountAction(owner: address(key), delta: -2)], nonce: 0)
        let cid = try Mempool.cid(of: transaction)
        let submitted = mining(core.step(
            .mining(.transactionReceived(transaction, origin: .local(replyID: 7))), now: Self.now
        ))
        guard case .preflight(let preflight)? = submitted.first else { return XCTFail("\(submitted)") }
        XCTAssertEqual(preflight.tipCID, world.genesis.cid)

        let applied = try await executeFirst(&core, transactions: [transaction])
        XCTAssertEqual(core.snapshot.actOnTip, chain[0].cid)
        XCTAssertEqual(core.mining.tipCID, chain[0].cid)
        XCTAssertEqual(core.snapshot.miningEpoch, 1)
        // The block confirmed the submit that was waiting on its verdict.
        XCTAssertTrue(mining(applied).contains {
            if case .transactionAdmitted(7, cid, _, _) = $0 { true } else { false }
        }, "\(mining(applied))")
        // Persist and publish precede every mining effect of the step.
        let firstMining = try XCTUnwrap(applied.firstIndex { if case .mining = $0 { true } else { false } })
        for (index, effect) in applied.enumerated() {
            switch effect {
            case .persist, .publish: XCTAssertLessThan(index, firstMining)
            default: break
            }
        }
        // The verdict on the old tip is dropped.
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

        let applied = mining(try await executeFirst(&core, transactions: []))
        guard case .buildTemplate(let again)? = applied.first(where: {
            if case .buildTemplate = $0 { true } else { false }
        }) else { return XCTFail("\(applied)") }
        XCTAssertEqual(again.tipCID, chain[0].cid)
        XCTAssertEqual(again.tipEpoch, core.snapshot.miningEpoch)
        // The old build's result issues nothing.
        XCTAssertTrue(mining(core.step(.mining(.templateBuilt(first, nil)), now: Self.now)).isEmpty)
    }

    func testAMinedRootIsWeighedInOneStepAndAnswered() {
        var host = HostCore(root: world.bootstrap.tree, hosted: [])
        let grind = MinedGrind(root: chain[0].block, rootChildren: chain[0].children, carried: [])
        let effects = host.step(.mined(grind, replyID: 3), now: Self.now)
        let persisted = effects.firstIndex { if case .persist = $0 { true } else { false } }
        let answered = effects.firstIndex {
            if case .workSubmitted(3, .weighed(canonical: true)) = $0 { true } else { false }
        }
        XCTAssertNotNil(persisted, "\(effects)")
        XCTAssertNotNil(answered, "\(effects)")
        XCTAssertLessThan(persisted ?? .max, answered ?? .min, "the answer follows the write")
        XCTAssertTrue(host.levels[host.rootPath]?.tree.contains(blockHash: chain[0].cid) == true)

        XCTAssertTrue(host.step(.mined(grind, replyID: 4), now: Self.now).contains {
            if case .workSubmitted(4, .duplicate) = $0 { true } else { false }
        })
    }
}
