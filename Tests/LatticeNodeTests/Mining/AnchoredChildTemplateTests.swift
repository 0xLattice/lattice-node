import Lattice
import LatticeNodeCore
@testable import LatticeNodeSim
import UInt256
import XCTest
import cashew
@testable import LatticeNode

/// A child template after a parent reorganization, against the real parent
/// tree (Lattice spec §5.3 step 6: a child block's parent anchor only moves
/// forward along the parent's history).
///
/// Nexus forks at N1. Branch A (A1, A2) is fed first and carries Alpha's a1
/// (anchored at N1) and a2 (anchored at A1). A1 carries a transaction, so
/// A1's post-state is produced by no block of branch B. Branch B (B1, B2, B3)
/// carries nothing and is heavier: Nexus reorganizes onto it, and Alpha's
/// act-on tip stays a2, anchored on the abandoned branch.
final class AnchoredChildTemplateTests: XCTestCase {
    private static let now = World.genesisTime + 1_000_000
    private static let nexus = LevelWorld.nexus
    private static let alpha = LevelWorld.alpha

    /// A host running Nexus and Alpha, fed grinds and bodies the way the
    /// shell does, recording each connect's retry failure.
    private struct Host {
        var node: NodeCore
        let cas: SimCAS
        /// Bodies asked for and not delivered.
        var withheld: Set<String> = []
        var asked: Set<String> = []
        var retries: [String: BlockImportError] = [:]

        init(_ world: LevelWorld) {
            node = NodeCore(root: world.rootBootstrap.tree, hosted: world.hosted)
            cas = world.cas
        }

        mutating func drive(_ event: NodeEvent) async {
            var queue = [event]
            while !queue.isEmpty {
                for effect in node.step(queue.removeFirst(), now: AnchoredChildTemplateTests.now) {
                    switch effect {
                    case .level(let path, .fetchBody(let cid)):
                        if withheld.contains(cid) {
                            asked.insert(cid)
                        } else {
                            queue.append(.level(path, .bodyFetched(cid: cid)))
                        }
                    case .connect(let path, let job, let facts):
                        let verdict = await ChainTree.connect(
                            job, fetcher: cas, parentFacts: facts,
                            validationContext: ValidationContext(nowMilliseconds: AnchoredChildTemplateTests.now)
                        )
                        if let failure = verdict.retryFailure { retries[verdict.blockHash] = failure }
                        queue.append(.level(path, .connected(verdict)))
                    default:
                        break
                    }
                }
            }
        }

        mutating func feed(_ grinds: [LevelGrind]) async {
            for grind in grinds { await drive(.mined(grind.mined)) }
        }

        /// Deliver every withheld body that was asked for.
        mutating func release() async {
            withheld = []
            let pending = asked
            asked = []
            for cid in pending.sorted() {
                for path in [AnchoredChildTemplateTests.nexus, AnchoredChildTemplateTests.alpha] {
                    await drive(.level(path, .bodyFetched(cid: cid)))
                }
            }
        }

        var alpha: ChainCore { node.levels[AnchoredChildTemplateTests.alpha]! }
        var nexusTree: ChainTree { node.levels[AnchoredChildTemplateTests.nexus]!.tree }
    }

    private struct Fixture {
        var builder: LevelWorld.Builder
        var host: Host
        let n1: SimBlock
        let a1: SimBlock, a2: SimBlock
        let rootA1: SimBlock, rootA2: SimBlock
        let b3: SimBlock
        var nextTime: Int64
    }

    /// A transaction that only spends a fresh signer's first nonce: it
    /// changes the state of the chain it names.
    private static func nonceSpend(_ key: Int, on path: ChainPath) throws -> Transaction {
        try SimTransactions.signed(keys: [SimTransactions.keys[key]], accountActions: [], nonce: 0, chainPath: path)
    }

    private func fixture() async throws -> Fixture {
        var builder = try await LevelWorld.Builder(levels: 2)
        let t = World.genesisTime
        let interval = LevelWorld.interval
        let genesis = try XCTUnwrap(builder.geneses[Self.nexus])
        let n0 = try await builder.grind(on: genesis, carrying: [], at: t + interval / 2, outcome: .block).root
        let g = try await builder.childGenesis(Self.alpha, parentState: n0.block.postState.rawCID, at: t + interval)
        let n1 = try await builder.grind(on: n0, carrying: [(Self.alpha, g)], at: t + interval, outcome: .block).root

        // Branch A: A1 carries a transaction and a1; A2 carries a2.
        let a1 = try await builder.build(on: g, carrierPrevState: n1.block.postState.rawCID, timestamp: t + 2 * interval, nonce: 1)
        let rootA1 = try await builder.grind(
            on: n1, carrying: [(Self.alpha, a1)], transactions: [Self.nonceSpend(0, on: Self.nexus)],
            at: t + 2 * interval, outcome: .block
        ).root
        let a2 = try await builder.build(on: a1, carrierPrevState: rootA1.block.postState.rawCID, timestamp: t + 3 * interval, nonce: 2)
        let rootA2 = try await builder.grind(on: rootA1, carrying: [(Self.alpha, a2)], at: t + 3 * interval, outcome: .block).root
        let branchA = builder.grinds.count

        // Branch B: three empty Nexus blocks on N1.
        let b1 = try await builder.grind(on: n1, carrying: [], at: t + 2 * interval + 10, outcome: .block).root
        let b2 = try await builder.grind(on: b1, carrying: [], at: t + 3 * interval + 10, outcome: .block).root
        let b3 = try await builder.grind(on: b2, carrying: [], at: t + 4 * interval + 10, outcome: .block).root

        var host = Host(builder.world())
        await host.feed(Array(builder.grinds.prefix(branchA)))
        XCTAssertEqual(host.node.levels[Self.nexus]?.snapshot.actOnTip, rootA2.cid, "fixture: Nexus follows A first")
        XCTAssertEqual(host.alpha.snapshot.actOnTip, a2.cid, "fixture: Alpha executed a2")
        await host.feed(Array(builder.grinds.dropFirst(branchA)))
        XCTAssertEqual(host.node.levels[Self.nexus]?.snapshot.actOnTip, b3.cid, "fixture: Nexus reorganized onto B")
        XCTAssertEqual(host.alpha.snapshot.actOnTip, a2.cid, "fixture: Alpha still acts on a2")
        XCTAssertFalse(
            host.nexusTree.executedSetAdvanced(from: rootA1.block.postState.rawCID, to: b3.block.postState.rawCID),
            "fixture: A1's state is not on B's history"
        )
        return Fixture(
            builder: builder, host: host, n1: n1, a1: a1, a2: a2, rootA1: rootA1, rootA2: rootA2, b3: b3,
            nextTime: t + 6 * interval
        )
    }

    private func input(
        _ host: Host, transactions: [Transaction] = [], parentTree: ChainTree?
    ) -> ChildTemplateInput {
        var tree = host.alpha.tree
        let tip = host.alpha.snapshot.actOnTip
        return ChildTemplateInput(
            path: Self.alpha, tipCID: tip, bestHeaderTip: host.alpha.snapshot.bestHeaderTip,
            transactions: transactions, anchor: tree.difficultyAnchor(forBlockHash: tip),
            level: host.alpha, parentTree: parentTree,
            genesisSpec: nil, genesisPremineRecipient: nil, genesisTarget: .max
        )
    }

    /// The Alpha candidate the template builds under a carrier entering
    /// `entering`, dated `timestamp`.
    private func candidate(
        _ input: ChildTemplateInput, entering: SimBlock, timestamp: Int64, cas: SimCAS
    ) async throws -> Block {
        let candidates = await NodeRuntime.childCandidates(
            of: Self.nexus, among: [input], entering: entering.block.postState,
            timestamp: timestamp, request: TemplateRequest(rewardRecipient: nil), fetcher: cas
        )
        XCTAssertEqual(candidates.count, 1)
        return try XCTUnwrap(candidates.first?.block)
    }

    private func transactionCount(_ block: Block, _ cas: SimCAS) async throws -> Int {
        try await block.transactions.resolve(fetcher: cas).node?.count ?? 0
    }

    /// Carry `block` in a grind rooted on `carrier` (a share, or a Nexus
    /// block), and feed it. Returns the block's CID and the grind's root.
    @discardableResult
    private func carry(
        _ block: Block, on carrier: SimBlock, as outcome: LevelWorld.Builder.Outcome = .share, _ fixture: inout Fixture
    ) async throws -> (cid: String, root: SimBlock) {
        // The template commits its spec by CID; the sim's record stores it.
        let cas = fixture.host.cas
        let spec = try await block.spec.resolve(fetcher: cas)
        let children = block.children.node == nil ? try await block.children.resolve(fetcher: cas) : block.children
        let whole = Block(
            version: block.version, parent: block.parent, transactions: block.transactions,
            target: block.target, nextTarget: block.nextTarget, spec: spec,
            parentState: block.parentState, prevState: block.prevState, postState: block.postState,
            children: children, height: block.height, timestamp: block.timestamp,
            rewardRecipient: block.rewardRecipient, nonce: block.nonce
        )
        XCTAssertEqual(try BlockHeader(node: whole).rawCID, try BlockHeader(node: block).rawCID)
        let sim = try await fixture.builder.store(whole, releaseAt: block.timestamp, anchor: fixture.a1.anchor)
        let mined = try await fixture.builder.grind(
            on: carrier, carrying: [(Self.alpha, sim)], at: block.timestamp, outcome: outcome
        )
        await fixture.host.drive(.mined(mined.grind))
        return (sim.cid, mined.root)
    }

    /// After the reorganization the template builds on a1, whose anchor (N1)
    /// is on B's history, without the pool; the block it builds is executed.
    /// The block the act-on tip alone would give (the template with no
    /// parent tree) is refused for parent continuity, with the link from its
    /// predecessor's anchor, and never executes.
    func testTheTemplateBuildsBelowAnActOnTipAnchoredOnTheAbandonedBranch() async throws {
        var fixture = try await fixture()
        let host = fixture.host
        let cas = host.cas
        let interval = LevelWorld.interval
        let entering = fixture.b3.block.postState.rawCID

        let tip = await NodeRuntime.anchoredTip(
            from: fixture.a2.cid, entering: entering, level: host.alpha, parentTree: host.nexusTree, fetcher: cas
        )
        XCTAssertEqual(tip, fixture.a1.cid, "the heaviest tip whose anchor advances to B3's state")

        let pooled = try Self.nonceSpend(1, on: Self.alpha)
        let good = try await candidate(
            input(host, transactions: [pooled], parentTree: host.nexusTree),
            entering: fixture.b3, timestamp: fixture.nextTime, cas: cas
        )
        XCTAssertEqual(good.parent?.rawCID, fixture.a1.cid)
        XCTAssertEqual(good.parentState.rawCID, entering)
        let goodCount = try await transactionCount(good, cas)
        XCTAssertEqual(goodCount, 0, "a block below the act-on tip carries no pool transactions")

        let naive = try await candidate(
            input(host, parentTree: nil), entering: fixture.b3, timestamp: fixture.nextTime + 1, cas: cas
        )
        XCTAssertEqual(naive.parent?.rawCID, fixture.a2.cid, "with no parent tree the act-on tip is built on")

        // The naive block rides a share; the anchored one a Nexus block B4
        // on B3, and the canonical Nexus goes on (B5), its work attributed
        // to B4's run: the anchored block is the heavier child.
        let naiveCID = try await carry(naive, on: fixture.b3, as: .share, &fixture).cid
        let link = CrossChainEvidenceRequirement.parentStateContinuity(
            parentPath: Self.nexus, fromStateCID: fixture.rootA1.block.postState.rawCID, toStateCID: entering
        )
        XCTAssertEqual(fixture.host.alpha.bodies.awaitingParent[naiveCID], link, "the naive block waits for a fact that never comes")
        let (goodCID, b4) = try await carry(good, on: fixture.b3, as: .block, &fixture)
        let b5 = try await fixture.builder.grind(on: b4, carrying: [], at: fixture.nextTime + interval, outcome: .block)
        await fixture.host.drive(.mined(b5.grind))
        XCTAssertEqual(fixture.host.node.levels[Self.nexus]?.snapshot.actOnTip, b5.root.cid)
        let alpha = fixture.host.alpha
        XCTAssertTrue(alpha.tree.contains(blockHash: goodCID) && alpha.tree.contains(blockHash: naiveCID), "both weigh")
        XCTAssertTrue(alpha.tree.isExecuted(blockHash: goodCID), "Lattice admits the anchored block")
        XCTAssertNil(fixture.host.retries[goodCID])
        XCTAssertNil(alpha.bodies.awaitingParent[goodCID])
        XCTAssertEqual(alpha.snapshot.actOnTip, goodCID, "Alpha moves with its parent")

        XCTAssertFalse(alpha.tree.isExecuted(blockHash: naiveCID), "Lattice refuses the naive block")
        XCTAssertFalse(alpha.tree.isExcludedRoot(naiveCID), "a missing parent fact never excludes")
        guard case .crossChainEvidenceRequired(let fact)? = fixture.host.retries[naiveCID] else {
            return XCTFail("the naive block's connect: \(String(describing: fixture.host.retries[naiveCID]))")
        }
        XCTAssertEqual(fact, link, "the link runs from the predecessor's anchor")
        XCTAssertEqual(fixture.host.node.parentFacts(for: Self.alpha)?.holds(link), false)
    }

    /// Honest mining after the reorganization, every template from the real
    /// code on the host's own state and carried by a Nexus block on Nexus's
    /// act-on tip: the first candidate leaves a2's branch, each later one
    /// extends the one before, and Alpha's act-on chain ends anchored only on
    /// states of Nexus's canonical history.
    func testHonestMiningMovesTheChildOntoTheCanonicalParent() async throws {
        var fixture = try await fixture()
        var built: [(cid: String, parent: String?)] = []
        for round in 0..<4 {
            let host = fixture.host
            let nexusTip = try XCTUnwrap(host.node.levels[Self.nexus]?.snapshot.actOnTip)
            let carrier = try XCTUnwrap(fixture.builder.blocks[Self.nexus]?[nexusTip])
            let block = try await candidate(
                input(host, parentTree: host.nexusTree), entering: carrier,
                timestamp: fixture.nextTime + Int64(round) * LevelWorld.interval, cas: host.cas
            )
            let cid = try await carry(block, on: carrier, as: .block, &fixture).cid
            built.append((cid, block.parent?.rawCID))
            XCTAssertTrue(fixture.host.alpha.tree.isExecuted(blockHash: cid), "round \(round): the honest block executes")
            XCTAssertNil(fixture.host.retries[cid], "round \(round): never refused")
            XCTAssertEqual(fixture.host.alpha.snapshot.actOnTip, cid, "round \(round): Alpha acts on it")
        }
        XCTAssertEqual(built.first?.parent, fixture.a1.cid, "the first leaves the abandoned branch")
        for (previous, next) in zip(built, built.dropFirst()) {
            XCTAssertEqual(next.parent, previous.cid, "each extends the one before")
        }
        try await assertAnchoredOnCanonicalParent(fixture.host)
    }

    /// Alpha's act-on chain anchors only on states Nexus's canonical chain
    /// produced, moving forward along it.
    private func assertAnchoredOnCanonicalParent(_ host: Host) async throws {
        let nexus = try XCTUnwrap(host.node.levels[Self.nexus])
        var canonical: [String: Int] = [:]
        var cursor: String? = nexus.snapshot.actOnTip
        var depth = 0
        while let cid = cursor {
            let block = try await BlockHeader(rawCID: cid).resolve(fetcher: host.cas).node
            if let state = block?.postState.rawCID, canonical[state] == nil { canonical[state] = depth }
            depth += 1
            cursor = nexus.parent(of: cid)
        }
        var cid: String? = host.alpha.snapshot.actOnTip
        var newer = -1
        while let current = cid, let parent = host.alpha.parent(of: current) {
            let resolved = try await BlockHeader(rawCID: current).resolve(fetcher: host.cas).node
            let state = try XCTUnwrap(resolved).parentState.rawCID
            let at = try XCTUnwrap(canonical[state], "Alpha block \(current) anchors off Nexus's canonical chain")
            XCTAssertGreaterThanOrEqual(at, newer, "anchors only move forward")
            newer = at
            cid = parent
        }
    }

    /// With no hosted parent the act-on tip is built on unchanged.
    func testWithNoParentTreeTheActOnTipIsBuiltOn() async throws {
        let fixture = try await fixture()
        let tip = await NodeRuntime.anchoredTip(
            from: fixture.a2.cid, entering: fixture.b3.block.postState.rawCID,
            level: fixture.host.alpha, parentTree: nil, fetcher: fixture.host.cas
        )
        XCTAssertEqual(tip, fixture.a2.cid)
    }

    /// A carrier on A2 (the branch a2 is anchored on): the act-on tip is
    /// accepted, and the template carries the pool.
    func testAnActOnTipWhoseAnchorAdvancesIsBuiltOnWithThePool() async throws {
        let fixture = try await fixture()
        let host = fixture.host
        let entering = fixture.rootA2.block.postState.rawCID
        let tip = await NodeRuntime.anchoredTip(
            from: fixture.a2.cid, entering: entering, level: host.alpha, parentTree: host.nexusTree, fetcher: host.cas
        )
        XCTAssertEqual(tip, fixture.a2.cid)
        let pooled = try Self.nonceSpend(1, on: Self.alpha)
        let block = try await candidate(
            input(host, transactions: [pooled], parentTree: host.nexusTree),
            entering: fixture.rootA2, timestamp: fixture.nextTime, cas: host.cas
        )
        XCTAssertEqual(block.parent?.rawCID, fixture.a2.cid)
        XCTAssertEqual(block.parentState.rawCID, entering)
        let count = try await transactionCount(block, host.cas)
        XCTAssertEqual(count, 1, "the pool rides on the act-on tip")
    }

    /// Retry: a block on a2 anchored at A3's state, carried by a share on
    /// A3, while A3's body is withheld. Branch A (A1..A4) is now heavier but
    /// Nexus cannot execute past A2, so the connect lacks the link from a2's
    /// anchor (A1's state) to A3's and waits. B2 carries the same
    /// transaction A1 does, so B3 produced A3's state: the block's anchor is
    /// in the executed set, on a branch that does not descend from A1, and
    /// only the forward link is missing. Once A3's body arrives Nexus
    /// executes it, the fact holds, and the node's own retry connects the
    /// block.
    func testABlockAwaitingItsForwardLinkConnectsOnceTheParentExecutesTheBranch() async throws {
        var builder = try await LevelWorld.Builder(levels: 2)
        let t = World.genesisTime
        let interval = LevelWorld.interval
        let spend = try Self.nonceSpend(0, on: Self.nexus)
        let genesis = try XCTUnwrap(builder.geneses[Self.nexus])
        let n0 = try await builder.grind(on: genesis, carrying: [], at: t + interval / 2, outcome: .block).root
        let g = try await builder.childGenesis(Self.alpha, parentState: n0.block.postState.rawCID, at: t + interval)
        let n1 = try await builder.grind(on: n0, carrying: [(Self.alpha, g)], at: t + interval, outcome: .block).root
        let a1 = try await builder.build(on: g, carrierPrevState: n1.block.postState.rawCID, timestamp: t + 2 * interval, nonce: 1)
        let rootA1 = try await builder.grind(
            on: n1, carrying: [(Self.alpha, a1)], transactions: [spend], at: t + 2 * interval, outcome: .block
        ).root
        let a2 = try await builder.build(on: a1, carrierPrevState: rootA1.block.postState.rawCID, timestamp: t + 3 * interval, nonce: 2)
        let rootA2 = try await builder.grind(on: rootA1, carrying: [(Self.alpha, a2)], at: t + 3 * interval, outcome: .block).root
        let branchA = builder.grinds.count
        let b1 = try await builder.grind(on: n1, carrying: [], at: t + 2 * interval + 10, outcome: .block).root
        let b2 = try await builder.grind(on: b1, carrying: [], transactions: [spend], at: t + 3 * interval + 10, outcome: .block).root
        let b3 = try await builder.grind(on: b2, carrying: [], at: t + 4 * interval + 10, outcome: .block).root
        let branchB = builder.grinds.count
        let a3 = try await builder.grind(on: rootA2, carrying: [], at: t + 5 * interval, outcome: .block).root
        let a4 = try await builder.grind(on: a3, carrying: [], at: t + 6 * interval, outcome: .block).root
        XCTAssertEqual(a3.block.postState.rawCID, b3.block.postState.rawCID, "fixture: B3 produced A3's state")
        // Carried by a share rooted on A3: anchored at A3's state.
        let anchored = try await builder.build(on: a2, carrierPrevState: a3.block.postState.rawCID, timestamp: t + 7 * interval, nonce: 3)
        _ = try await builder.grind(on: a3, carrying: [(Self.alpha, anchored)], at: t + 7 * interval, outcome: .share)
        let world = builder.world()

        var host = Host(world)
        await host.feed(Array(world.grinds.prefix(branchA)))
        await host.feed(Array(world.grinds[branchA..<branchB]))
        XCTAssertEqual(host.node.levels[Self.nexus]?.snapshot.actOnTip, b3.cid)
        let link = CrossChainEvidenceRequirement.parentStateContinuity(
            parentPath: Self.nexus, fromStateCID: rootA1.block.postState.rawCID, toStateCID: a3.block.postState.rawCID
        )
        XCTAssertTrue(host.nexusTree.executedSetProduced(stateCID: a3.block.postState.rawCID),
                      "fixture: the anchor itself is produced (by B3)")
        XCTAssertFalse(host.node.parentFacts(for: Self.alpha)?.holds(link) ?? true)

        host.withheld = [a3.cid]
        await host.feed(Array(world.grinds.dropFirst(branchB)))
        XCTAssertEqual(host.node.levels[Self.nexus]?.snapshot.bestHeaderTip, a4.cid, "A is heavier")
        XCTAssertFalse(host.nexusTree.isExecuted(blockHash: a3.cid), "A3's body is withheld")
        XCTAssertTrue(host.alpha.tree.contains(blockHash: anchored.cid))
        guard case .crossChainEvidenceRequired(let fact)? = host.retries[anchored.cid] else {
            return XCTFail("the block's connect: \(String(describing: host.retries[anchored.cid]))")
        }
        XCTAssertEqual(fact, link)
        XCTAssertEqual(host.alpha.bodies.awaitingParent[anchored.cid], link)
        XCTAssertFalse(host.alpha.tree.isExecuted(blockHash: anchored.cid))

        await host.release()
        XCTAssertTrue(host.nexusTree.isExecuted(blockHash: a3.cid))
        XCTAssertEqual(host.node.levels[Self.nexus]?.snapshot.actOnTip, a4.cid)
        XCTAssertTrue(host.node.parentFacts(for: Self.alpha)?.holds(link) ?? false)
        XCTAssertTrue(host.alpha.tree.isExecuted(blockHash: anchored.cid), "the retry connects the block")
        XCTAssertNil(host.alpha.bodies.awaitingParent[anchored.cid])
        XCTAssertEqual(host.alpha.snapshot.actOnTip, anchored.cid)
    }
}
