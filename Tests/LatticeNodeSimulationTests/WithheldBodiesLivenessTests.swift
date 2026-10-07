import Foundation
import Lattice
import LatticeNodeCore
import LatticeNodeSim
import UInt256
import XCTest
import cashew

/// The act-on tip is the heaviest executed tip. A branch of proof-of-work
/// valid headers whose bodies are never served weighs and is never judged;
/// honest miners keep extending the heaviest executed tip, their work pools
/// on one chain, and a released branch wins or loses on weight alone.
final class WithheldBodiesLivenessTests: XCTestCase {
    private static let executedHeight = 3

    /// Honest nodes over one world, each a root-level `NodeCore` with its own
    /// content store. One relay peer shows every node the headers the others
    /// mine. A body is served when asked for unless it is withheld: a
    /// withheld body never arrives.
    private final class Net {
        let world: World
        let path: ChainPath
        let peer = PeerID(key: "relay", session: 1)
        var hosts: [NodeCore] = []
        var contents: [SimCAS] = []
        var positions: [UInt64] = []
        var known: [String: SimBlock]
        var withheld = Set<String>()
        /// While set, no body asked for is served yet.
        var inFlight = false
        /// While set, a withheld body's Volume arrives without the content
        /// its connect needs.
        var unresolvable = false
        var now = World.genesisTime + 1_000_000
        /// Per node: the bodies asked for and the blocks connected, in order,
        /// and every act-on tip it published, in order.
        var fetched: [[String]] = []
        var connected: [[String]] = []
        var tips: [[String]] = []

        init(world: World, nodes: Int, window: Int = 8) {
            self.world = world
            path = world.bootstrap.tree.context!.path
            known = world.blocks
            for _ in 0..<nodes {
                var host = NodeCore(root: world.bootstrap.tree, hosted: [], config: ChainCoreConfig(bodyWindow: window))
                _ = host.step(.peerReady(peer), now: now)
                hosts.append(host)
                contents.append(SimCAS(world.genesisContent))
                positions.append(0)
                fetched.append([])
                connected.append([])
                tips.append([world.genesis.cid])
            }
        }

        func level(_ node: Int) -> ChainCore { hosts[node].levels[path]! }
        func snapshot(_ node: Int) -> ChainSnapshot { level(node).snapshot }

        func step(_ node: Int, _ event: NodeEvent) -> [NodeEffect] {
            let effects = hosts[node].step(event, now: now)
            let tip = snapshot(node).actOnTip
            if tip != tips[node].last { tips[node].append(tip) }
            return effects
        }

        /// Run a step's effects to quiescence, as the shell does.
        @discardableResult
        func settle(_ node: Int, _ first: [NodeEffect]) async throws -> [NodeEffect] {
            var all = first
            var queue = first
            while !queue.isEmpty {
                var next: [NodeEffect] = []
                switch queue.removeFirst() {
                case .persist(let batch):
                    for (_, level) in batch.levels {
                        for state in level.states { try await storeMaterialized(state, in: contents[node]) }
                    }
                case .level(_, .fetchBody(let cid)):
                    fetched[node].append(cid)
                    if inFlight || (withheld.contains(cid) && !unresolvable) {
                        break
                    } else if withheld.contains(cid) {
                        next = step(node, .level(path, .bodyFetched(cid: cid)))
                    } else {
                        contents[node].put(known[cid]!.body)
                        next = step(node, .level(path, .bodyFetched(cid: cid)))
                    }
                case .connect(_, let job, _):
                    connected[node].append(job.blockHash)
                    let verdict = await ChainTree.connect(
                        job, fetcher: contents[node], validationContext: ValidationContext(nowMilliseconds: now)
                    )
                    next = step(node, .level(path, .connected(verdict)))
                default:
                    break
                }
                all += next
                queue += next
            }
            return all
        }

        /// The relay shows `blocks` to `node`, as a peer does.
        func show(_ blocks: [SimBlock], to node: Int) async throws {
            for block in blocks { known[block.cid] = block }
            let entries = blocks.map { block -> StreamEntry in
                positions[node] += 1
                return StreamEntry(position: positions[node], entry: .header(block.cid))
            }
            var effects = try await settle(node, step(node, .received(peer, path, .stream(StreamPage(
                requestID: level(node).sync.peers[peer]?.stream?.requestID ?? 0,
                logID: "relay", entries: entries, hasMore: false
            )))))
            while let ask = effects.compactMap({ effect -> (UInt64, [String])? in
                if case .level(_, .send(_, .getData(let id, let cids))) = effect { return (id, cids) }
                return nil
            }).first {
                effects = try await settle(node, step(node, .received(peer, path, .headers(HeadersResponse(
                    requestID: ask.0,
                    entries: ask.1.compactMap { known[$0] }.map { HeaderEntry(block: $0.block, children: $0.children) },
                    hasMore: false
                )))))
            }
        }

        /// `node` mines one block on the tip its templates are built on and
        /// every other node is shown its header. Returns the block and the
        /// answer to the miner.
        func mine(by node: Int, _ block: SimBlock? = nil) async throws -> (block: SimBlock, outcome: MinedOutcome?) {
            now += World.blockInterval
            let tip = level(node).mining.tipCID
            XCTAssertEqual(tip, snapshot(node).actOnTip, "templates are built on the act-on tip")
            // A millisecond off the interval: never the withheld branch's own block.
            var mined = block
            if mined == nil {
                mined = try await world.branch(from: known[tip]!, count: 1, interval: World.blockInterval + 1)[0]
            }
            guard let mined else { throw SimulationError.malformedWorld("no block") }
            known[mined.cid] = mined
            let grind = MinedGrind(root: mined.block, rootChildren: mined.children, carried: [])
            let effects = try await settle(node, step(node, .mined(grind, replyID: 1)))
            for other in hosts.indices where other != node { try await show([mined], to: other) }
            let outcome = effects.compactMap { effect -> MinedOutcome? in
                if case .level(_, .workSubmitted(1, let outcome)) = effect { return outcome }
                return nil
            }.first
            return (mined, outcome)
        }

        /// The withholder serves its bodies: every node still asking gets them.
        func release() async throws {
            let released = withheld
            withheld = []
            for node in hosts.indices {
                for cid in level(node).bodies.requested.intersection(released).sorted() {
                    contents[node].put(known[cid]!.body)
                    try await settle(node, step(node, .level(path, .bodyFetched(cid: cid))))
                }
            }
        }

        /// A withheld block weighs what it weighed and has no verdict.
        func assertUnjudged(_ blocks: [SimBlock], weight: UInt256?) {
            for node in hosts.indices {
                var tree = level(node).tree
                XCTAssertEqual(tree.subtreeWeight(forHash: blocks[0].cid)?.uint256Value, weight)
                for block in blocks {
                    XCTAssertFalse(tree.isExcludedRoot(block.cid), "a body not held is never an exclusion")
                    XCTAssertFalse(tree.isExecuted(blockHash: block.cid))
                }
            }
        }
    }

    /// `nodes` honest nodes at an executed tip of height 3, shown `count`
    /// headers on it whose bodies are withheld.
    private func held(
        withheld count: Int, nodes: Int, window: Int = 8, unresolvable: Bool = false
    ) async throws -> (net: Net, base: SimBlock, branch: [SimBlock], weight: UInt256?) {
        var rng = SplitMix64(state: 0x317)
        let world = try await World.generate(rng: &rng, honestBlocks: 4, forkProbability: 0, spamBlocks: 0)
        let chain = world.honest.compactMap { world.blocks[$0] }
        let net = Net(world: world, nodes: nodes, window: window)
        net.unresolvable = unresolvable
        for block in chain.prefix(Self.executedHeight) { _ = try await net.mine(by: 0, block) }
        let base = chain[Self.executedHeight - 1]
        let branch = try await world.branch(from: base, count: count)
        net.withheld = Set(branch.map(\.cid))
        for node in 0..<nodes {
            XCTAssertEqual(net.snapshot(node).actOnTip, base.cid)
            try await net.show(branch, to: node)
            XCTAssertEqual(net.snapshot(node).bestHeaderTip, branch.last?.cid)
            XCTAssertEqual(net.snapshot(node).actOnTip, base.cid)
        }
        var tree = net.level(0).tree
        return (net, base, branch, tree.subtreeWeight(forHash: branch[0].cid)?.uint256Value)
    }

    /// One honest miner: every block it mines is executed and the next is
    /// built on it, so the tip advances every round and the honest chain
    /// outweighs the withheld branch within `count + 1` blocks. Released
    /// after that, the withheld branch stays a losing fork.
    private func assertTheMinerIsNeverHeld(withheld count: Int) async throws {
        let (net, base, branch, weight) = try await held(withheld: count, nodes: 1)
        var parent = base.cid
        var heaviest: Int?
        for round in 1...8 {
            let (block, outcome) = try await net.mine(by: 0)
            XCTAssertEqual(block.parent, parent, "round \(round) builds on the last honest block")
            XCTAssertEqual(outcome, .executed(tipCID: block.cid))
            XCTAssertEqual(net.snapshot(0).actOnHeight, UInt64(Self.executedHeight + round))
            if heaviest == nil, net.snapshot(0).bestHeaderTip == block.cid { heaviest = round }
            parent = block.cid
        }
        XCTAssertLessThanOrEqual(heaviest ?? .max, count + 1)
        net.assertUnjudged(branch, weight: weight)
        try await net.release()
        XCTAssertEqual(net.snapshot(0).actOnTip, parent, "released late, the withheld branch is a losing fork")
        XCTAssertEqual(net.snapshot(0).bestHeaderTip, parent)
        net.assertUnjudged(branch, weight: weight)
    }

    func testOneWithheldHeaderNeverHoldsTheMiner() async throws {
        try await assertTheMinerIsNeverHeld(withheld: 1)
    }

    func testTwoWithheldHeadersNeverHoldTheMiner() async throws {
        try await assertTheMinerIsNeverHeld(withheld: 2)
    }

    func testThreeWithheldHeadersNeverHoldTheMiner() async throws {
        try await assertTheMinerIsNeverHeld(withheld: 3)
    }

    /// Released while it is still the heaviest header chain, the withheld
    /// branch is executed and wins: an ordinary reorg off the honest block.
    func testAWithheldBranchReleasedWhileHeaviestIsExecutedAndWins() async throws {
        let (net, _, branch, _) = try await held(withheld: 3, nodes: 1)
        let (honest, _) = try await net.mine(by: 0)
        XCTAssertEqual(net.snapshot(0).actOnTip, honest.cid)
        XCTAssertEqual(net.snapshot(0).bestHeaderTip, branch.last?.cid)
        try await net.release()
        XCTAssertEqual(net.snapshot(0).actOnTip, branch.last?.cid)
        XCTAssertEqual(net.snapshot(0).actOnHeight, UInt64(Self.executedHeight + 3))
        let next = try await net.mine(by: 0)
        XCTAssertEqual(next.block.parent, branch.last?.cid)
    }

    /// Three honest miners: each node asks for every child of its tip, so
    /// another miner's block arrives while the withheld one does not, and
    /// their work pools on one chain. No honest block is wasted and the
    /// hold ends within `count + 1` rounds.
    func testHonestWorkPoolsOnOneChainAgainstTwoWithheldHeaders() async throws {
        let (net, base, branch, weight) = try await held(withheld: 2, nodes: 3)
        var parent = base.cid
        var ended: Int?
        for round in 1...9 {
            let (block, _) = try await net.mine(by: round % 3)
            XCTAssertEqual(block.parent, parent, "round \(round) builds on the last honest block, whoever mined it")
            for node in 0..<3 { XCTAssertEqual(net.snapshot(node).actOnTip, block.cid, "node \(node), round \(round)") }
            if ended == nil, (0..<3).allSatisfy({ net.snapshot($0).bestHeaderTip == block.cid }) { ended = round }
            parent = block.cid
        }
        XCTAssertLessThanOrEqual(ended ?? .max, 3)
        net.assertUnjudged(branch, weight: weight)
        try await net.release()
        for node in 0..<3 {
            XCTAssertEqual(net.snapshot(node).actOnTip, parent)
            XCTAssertEqual(net.snapshot(node).bestHeaderTip, parent)
        }
    }

    /// The heavier child's body arrived but its connect found content
    /// unresolvable (it is parked for a retry): the next-heaviest sibling,
    /// another node's block, is executed meanwhile.
    func testAParkedHeavierSiblingDoesNotHoldTheNextHeaviest() async throws {
        let (net, _, branch, weight) = try await held(withheld: 2, nodes: 2, unresolvable: true)
        XCTAssertNotNil(net.level(1).bodies.parked[branch[0].cid])
        let (block, _) = try await net.mine(by: 0)
        XCTAssertEqual(net.snapshot(1).actOnTip, block.cid)
        XCTAssertEqual(net.snapshot(1).bestHeaderTip, branch.last?.cid)
        XCTAssertTrue(net.level(1).bodyWindow.contains(branch[0].cid), "the parked block stays wanted")
        net.assertUnjudged(branch, weight: weight)
    }

    /// Two honest miners against a heavier withheld branch build one chain
    /// between them; released while still the heaviest, the withheld branch
    /// is executed and every node follows it.
    func testTwoMinersPoolAndConvergeOnTheReleasedHeavierBranch() async throws {
        let (net, base, branch, weight) = try await held(withheld: 4, nodes: 2)
        var parent = base.cid
        for round in 1...2 {
            let (block, outcome) = try await net.mine(by: round % 2)
            XCTAssertEqual(block.parent, parent, "round \(round) builds on the other miner's block")
            XCTAssertEqual(outcome, .executed(tipCID: block.cid))
            for node in 0..<2 {
                XCTAssertEqual(net.snapshot(node).actOnTip, block.cid)
                XCTAssertEqual(net.snapshot(node).bestHeaderTip, branch.last?.cid)
            }
            parent = block.cid
        }
        net.assertUnjudged(branch, weight: weight)
        try await net.release()
        for node in 0..<2 {
            XCTAssertEqual(net.snapshot(node).actOnTip, branch.last?.cid)
            XCTAssertEqual(net.level(node).mining.tipCID, branch.last?.cid)
        }
    }

    /// More children of the tip than window slots take turns: with a window
    /// of one the withheld heavier child does not keep the slot from the
    /// honest block, and is asked for again once that block is the tip.
    func testAWithheldHeavierChildDoesNotKeepTheOnlySlot() async throws {
        let (net, _, branch, _) = try await held(withheld: 2, nodes: 2, window: 1)
        let (block, _) = try await net.mine(by: 0)
        for _ in 0..<2 {
            net.now += net.level(1).config.bodyRetryCap
            for node in 0..<2 { try await net.settle(node, net.step(node, .tick)) }
        }
        for node in 0..<2 { XCTAssertEqual(net.snapshot(node).actOnTip, block.cid) }
        XCTAssertEqual(net.level(1).bodies.requested, [branch[0].cid])
        try await net.release()
        XCTAssertEqual(net.snapshot(1).actOnTip, branch.last?.cid, "released while heaviest, it is executed and wins")
    }

    /// Every body obtainable but late: each is still in flight when its
    /// header and a stale sibling's are weighed. The sync asks for the main
    /// chain and, as each block becomes the tip, its children: at most one
    /// stale sibling a fork. The main chain is executed and the tip never
    /// leaves it.
    func testASyncPastStaleSiblingsExecutesOnlyTheMainChain() async throws {
        var rng = SplitMix64(state: 0x51B)
        let world = try await World.generate(rng: &rng, honestBlocks: 12, forkProbability: 0, spamBlocks: 0)
        let chain = world.honest.compactMap { world.blocks[$0] }
        let net = Net(world: world, nodes: 1)
        net.inFlight = true
        // A sibling of every main block but the last, each shown once the
        // main chain is a block past it.
        try await net.show([chain[0]], to: 0)
        for (index, block) in chain.enumerated().dropFirst() {
            let sibling = try await world.branch(
                from: index > 1 ? chain[index - 2] : world.genesis, count: 1, interval: World.blockInterval / 2
            )
            try await net.show([block] + sibling, to: 0)
        }
        XCTAssertEqual(net.level(0).index.leaves.count, chain.count)
        XCTAssertEqual(net.snapshot(0).actOnTip, world.genesis.cid)
        var served = 0
        while served < net.fetched[0].count {
            let cid = net.fetched[0][served]
            served += 1
            net.contents[0].put(net.known[cid]!.body)
            try await net.settle(0, net.step(0, .level(net.path, .bodyFetched(cid: cid))))
        }
        XCTAssertEqual(net.snapshot(0).actOnTip, chain.last?.cid)
        XCTAssertEqual(net.snapshot(0).bestHeaderTip, chain.last?.cid)
        let main = Set(chain.map(\.cid))
        let stale = net.fetched[0].filter { !main.contains($0) }.compactMap { net.known[$0]?.parent }
        XCTAssertEqual(net.fetched[0].filter(main.contains), chain.map(\.cid))
        XCTAssertEqual(stale.count, Set(stale).count, "at most one stale sibling a fork is asked for")
        XCTAssertTrue(stale.allSatisfy { main.contains($0) || $0 == world.genesis.cid }, "never a stale sibling's descendant")
        XCTAssertEqual(net.connected[0], chain.map(\.cid), "exactly the main chain is executed")
        XCTAssertEqual(net.tips[0], [world.genesis.cid] + chain.map(\.cid), "the tip only ever extends")
    }
}
