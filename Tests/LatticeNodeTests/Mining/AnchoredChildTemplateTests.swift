import Lattice
@testable import LatticeNodeCore
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
            node = NodeCore(root: world.rootBootstrap.tree.detached(), hosted: world.hosted)
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
                    case .connect(let path, let job):
                        let verdict = await ChainTree.connect(
                            job, fetcher: cas, parentFacts: node.parentFacts(for: path),
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

        /// A copy to hold while this host steps on: its own trees.
        var held: Host {
            var copy = self
            copy.node.levels = node.levels.mapValues { level in
                var level = level
                level.tree = level.tree.detached()
                return level
            }
            return copy
        }
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

    private func input(_ host: Host, transactions: [Transaction] = []) -> ChildTemplateInput {
        let tree = host.alpha.tree
        let tip = host.alpha.snapshot.actOnTip
        return ChildTemplateInput(
            path: Self.alpha, tipCID: tip, bestHeaderTip: host.alpha.snapshot.bestHeaderTip,
            transactions: transactions, anchor: tree.difficultyAnchor(forBlockHash: tip),
            genesisSpec: nil, genesisPremineRecipient: nil, genesisTransactions: [], genesisTarget: .max
        )
    }

    /// The host's levels as a job reads them live; with Nexus left out
    /// when the parent is not hosted.
    private func levels(_ host: Host, parentHosted: Bool = true) -> LiveLevels {
        let levels = parentHosted ? host.node.levels : host.node.levels.filter { $0.key != Self.nexus }
        return LiveLevels { $0(levels) }
    }

    /// The Alpha candidate the template builds under a carrier entering
    /// `entering`, dated `timestamp`.
    private func candidate(
        _ input: ChildTemplateInput, levels: LiveLevels, entering: SimBlock, timestamp: Int64, cas: SimCAS
    ) async throws -> Block {
        var refused: [PolicyRefusal] = []
        return try await candidate(input, levels: levels, entering: entering, timestamp: timestamp, cas: cas, refused: &refused)
    }

    private func candidate(
        _ input: ChildTemplateInput, levels: LiveLevels, entering: SimBlock, timestamp: Int64, cas: SimCAS,
        refused: inout [PolicyRefusal]
    ) async throws -> Block {
        let candidates = await NodeRuntime.childCandidates(
            of: Self.nexus, among: [input], entering: entering.block.postState,
            timestamp: timestamp, request: TemplateRequest(rewardRecipient: nil), levels: levels, fetcher: cas,
            refused: &refused
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
        let host = fixture.host.held
        let cas = host.cas
        let interval = LevelWorld.interval
        let entering = fixture.b3.block.postState.rawCID

        let tip = await NodeRuntime.anchoredTip(
            from: fixture.a2.cid, entering: entering, at: Self.alpha, levels: levels(host), fetcher: cas
        )
        XCTAssertEqual(tip?.tip, fixture.a1.cid, "the heaviest tip whose anchor advances to B3's state")

        let pooled = try Self.nonceSpend(1, on: Self.alpha)
        let good = try await candidate(
            input(host, transactions: [pooled]), levels: levels(host),
            entering: fixture.b3, timestamp: fixture.nextTime, cas: cas
        )
        XCTAssertEqual(good.parent?.rawCID, fixture.a1.cid)
        XCTAssertEqual(good.parentState.rawCID, entering)
        let goodCount = try await transactionCount(good, cas)
        XCTAssertEqual(goodCount, 0, "a block below the act-on tip carries no pool transactions")

        let naive = try await candidate(
            input(host), levels: levels(host, parentHosted: false), entering: fixture.b3, timestamp: fixture.nextTime + 1, cas: cas
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
            let carrier: SimBlock
            let block: Block
            do {
                // The template reads the host's state; no copy outlives it
                // into the carrying step.
                let host = fixture.host
                let nexusTip = try XCTUnwrap(host.node.levels[Self.nexus]?.snapshot.actOnTip)
                carrier = try XCTUnwrap(fixture.builder.blocks[Self.nexus]?[nexusTip])
                block = try await candidate(
                    input(host), levels: levels(host), entering: carrier,
                    timestamp: fixture.nextTime + Int64(round) * LevelWorld.interval, cas: host.cas
                )
            }
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

    /// Before live reads a job held a copy of the level and of its parent's
    /// tree, and chose its tip this way: the oracle the live reads match.
    private static func copiedAnchoredTip(
        from tipCID: String, entering: String, level: ChainCore, parentTree: ChainTree?, fetcher: any Fetcher
    ) async -> String? {
        guard let parentTree else { return tipCID }
        // The anchors of the tip's ancestry (this fixture's Alpha has no
        // forks), read first: the walk runs at once.
        var anchors: [String: String] = [:]
        var cid: String? = tipCID
        while let current = cid {
            if let read = try? await BlockHeader(rawCID: current).resolve(fetcher: fetcher).node {
                anchors[current] = read.parentState.rawCID
            }
            cid = level.parent(of: current)
        }
        return level.actOnTip(from: tipCID) { tip in
            anchors[tip].map { parentTree.executedSetAdvanced(from: $0, to: entering) }
        }
    }

    /// Holds the levels as the runtime's loop does: a read hops onto it.
    private actor Loop {
        let levels: [ChainPath: ChainCore]
        init(_ levels: [ChainPath: ChainCore]) { self.levels = levels }
        func run(_ read: @Sendable ([ChainPath: ChainCore]?) -> Void) { read(levels) }
    }

    /// Holds the levels as the runtime's loop does, and moves them to
    /// `next` between steps, after its `swapAfter`th read.
    private actor MovingLoop {
        var levels: [ChainPath: ChainCore]
        let next: [ChainPath: ChainCore]
        let swapAfter: Int
        private(set) var reads = 0
        init(_ levels: [ChainPath: ChainCore], next: [ChainPath: ChainCore], swapAfter: Int) {
            (self.levels, self.next, self.swapAfter) = (levels, next, swapAfter)
        }
        func run(_ read: @Sendable ([ChainPath: ChainCore]?) -> Void) {
            read(levels)
            reads += 1
            if reads == swapAfter { levels = next }
        }
    }

    /// Alpha moves between the loop's steps while a child template job
    /// reads the levels: before, the job's tip a2 is refused and a1 is built
    /// on; after, a block on a1 has executed and is Alpha's act-on tip, so
    /// it is built on. Each read is one step's state, so the job builds what
    /// the state of its last read gives, one of the two, never a mix.
    func testAMoveBetweenStepsGivesOneStatesTemplate() async throws {
        var fixture = try await fixture()
        // Held while the host steps on: its own trees.
        let spawned = fixture.host.held
        let before = spawned.node.levels
        func built(_ levels: LiveLevels) async throws -> String? {
            var refused: [PolicyRefusal] = []
            let candidates = await NodeRuntime.childCandidates(
                of: Self.nexus, among: [input(spawned)], entering: fixture.b3.block.postState,
                timestamp: fixture.nextTime, request: TemplateRequest(rewardRecipient: nil), levels: levels,
                fetcher: spawned.cas, refused: &refused
            )
            return try candidates.first.map { try BlockHeader(node: $0.block).rawCID }
        }
        let fromBefore = try await built(LiveLevels { $0(before) })

        let onA1 = try await candidate(
            input(spawned), levels: LiveLevels { $0(before) }, entering: fixture.b3, timestamp: fixture.nextTime,
            cas: spawned.cas
        )
        let (onA1CID, b4) = try await carry(onA1, on: fixture.b3, as: .block, &fixture)
        let b5 = try await fixture.builder.grind(on: b4, carrying: [], at: fixture.nextTime + LevelWorld.interval, outcome: .block)
        await fixture.host.drive(.mined(b5.grind))
        XCTAssertEqual(fixture.host.alpha.snapshot.actOnTip, onA1CID, "fixture: Alpha moved onto the block on a1")
        let after = fixture.host.node.levels
        let fromAfter = try await built(LiveLevels { $0(after) })
        XCTAssertNotNil(fromBefore)
        XCTAssertNotNil(fromAfter)
        XCTAssertNotEqual(fromBefore, fromAfter, "fixture: the two states build different blocks")

        var crossed = 0
        for swapAfter in 1...6 {
            let loop = MovingLoop(before, next: after, swapAfter: swapAfter)
            let result = try await built(LiveLevels { read in Task { await loop.run(read) } })
            let reads = await loop.reads
            if reads > swapAfter {
                crossed += 1
                XCTAssertEqual(result, fromAfter, "moved after read \(swapAfter) of \(reads)")
            } else {
                XCTAssertEqual(result, fromBefore, "all \(reads) reads before the move")
            }
        }
        XCTAssertGreaterThan(crossed, 0, "fixture: some job read across the move")
    }

    /// A child template's reads made live, hopping onto the levels' owner,
    /// build what a job holding copies of the levels built: the same tip
    /// (the old copy-based choice), and byte for byte the same block, below
    /// the act-on tip after the reorganization and on it with the pool.
    func testLiveReadsBuildWhatCopiesOfTheLevelsBuilt() async throws {
        let fixture = try await fixture()
        let host = fixture.host
        let loop = Loop(host.node.levels)
        let live = LiveLevels { read in Task { await loop.run(read) } }
        let held = host.node.levels
        let copied = LiveLevels { $0(held) }
        let pooled = try Self.nonceSpend(1, on: Self.alpha)
        for (carrier, expected) in [(fixture.b3, fixture.a1.cid), (fixture.rootA2, fixture.a2.cid)] {
            let entering = carrier.block.postState.rawCID
            let copiedTip = await Self.copiedAnchoredTip(
                from: fixture.a2.cid, entering: entering, level: host.alpha, parentTree: host.nexusTree, fetcher: host.cas
            )
            let liveTip = await NodeRuntime.anchoredTip(
                from: fixture.a2.cid, entering: entering, at: Self.alpha, levels: live, fetcher: host.cas
            )
            XCTAssertEqual(copiedTip, expected)
            XCTAssertEqual(liveTip?.tip, copiedTip)
            let liveBlock = try await candidate(
                input(host, transactions: [pooled]), levels: live, entering: carrier, timestamp: fixture.nextTime, cas: host.cas
            )
            let copiedBlock = try await candidate(
                input(host, transactions: [pooled]), levels: copied, entering: carrier, timestamp: fixture.nextTime, cas: host.cas
            )
            XCTAssertEqual(liveBlock.parent?.rawCID, expected)
            XCTAssertEqual(try BlockHeader(node: liveBlock).rawCID, try BlockHeader(node: copiedBlock).rawCID)
        }
    }

    /// With no hosted parent the act-on tip is built on unchanged.
    func testWithNoParentTreeTheActOnTipIsBuiltOn() async throws {
        let fixture = try await fixture()
        let tip = await NodeRuntime.anchoredTip(
            from: fixture.a2.cid, entering: fixture.b3.block.postState.rawCID,
            at: Self.alpha, levels: levels(fixture.host, parentHosted: false), fetcher: fixture.host.cas
        )
        XCTAssertEqual(tip?.tip, fixture.a2.cid)
    }

    /// The pool's verdicts were taken at another height, so a child template
    /// judges what it carries by the child's policies, at its own height,
    /// as the root template does: a transaction they refuse is left out, not
    /// mined into a block every validator rejects, and named for Alpha's
    /// pool to drop.
    func testAChildTemplateCarriesOnlyWhatItsPoliciesAccept() async throws {
        for (verdict, carried) in [(UInt8(0), 0), (1, 2)] {
            var builder = try await LevelWorld.Builder(levels: 2)
            let module = WasmPolicyModule(bytes: Self.policyModule(verdict: verdict))
            let header = try WasmPolicyModuleHeader(node: module)
            try await header.storeRecursively(storer: builder.cas as any VolumeStorer)
            let base = LevelWorld.specFor(Self.alpha)
            builder.specs[Self.alpha] = ChainSpec(
                maxNumberOfTransactionsPerBlock: 2,
                maxStateGrowth: base.maxStateGrowth, premine: base.premine,
                targetBlockTime: base.targetBlockTime, initialReward: base.initialReward,
                halvingInterval: base.halvingInterval, halfLife: base.halfLife,
                wasmPolicies: [WasmPolicyRef(moduleCID: header.rawCID, scope: .transaction)]
            )
            let t = World.genesisTime
            let interval = LevelWorld.interval
            let genesis = try XCTUnwrap(builder.geneses[Self.nexus])
            let n0 = try await builder.grind(on: genesis, carrying: [], at: t + interval / 2, outcome: .block).root
            let g = try await builder.childGenesis(Self.alpha, parentState: n0.block.postState.rawCID, at: t + interval)
            let n1 = try await builder.grind(on: n0, carrying: [(Self.alpha, g)], at: t + interval, outcome: .block).root
            var host = Host(builder.world())
            await host.feed(builder.grinds)
            XCTAssertEqual(host.alpha.snapshot.actOnTip, g.cid, "fixture: Alpha executed its genesis")

            let spends = try (1...3).map { try Self.nonceSpend($0, on: Self.alpha) }
            var refused: [PolicyRefusal] = []
            let block = try await candidate(
                input(host, transactions: spends), levels: levels(host),
                entering: n1, timestamp: t + 2 * interval, cas: host.cas, refused: &refused
            )
            let count = try await transactionCount(block, host.cas)
            XCTAssertEqual(count, carried, "policy verdict \(verdict)")
            XCTAssertEqual(
                refused, carried == 0 ? [PolicyRefusal(path: Self.alpha, tipCID: g.cid, cids: try spends.map(Mempool.cid(of:)))] : []
            )
        }
    }

    /// A WASM policy module that gives `verdict` for every transaction.
    private static func policyModule(verdict: UInt8) -> Data {
        func section(_ id: UInt8, _ body: [UInt8]) -> [UInt8] { [id, UInt8(body.count)] + body }
        func export(_ name: String, kind: UInt8, index: UInt8) -> [UInt8] {
            [UInt8(name.utf8.count)] + Array(name.utf8) + [kind, index]
        }
        var exports: [UInt8] = [0x03]
        exports += export("memory", kind: 2, index: 0)
        exports += export("lattice_alloc", kind: 0, index: 0)
        exports += export("lattice_validate_transaction", kind: 0, index: 1)
        var module: [UInt8] = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]
        module += section(1, [0x02, 0x60, 0x01, 0x7f, 0x01, 0x7f, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f])
        module += section(3, [0x02, 0x00, 0x01])
        module += section(5, [0x01, 0x00, 0x01])
        module += section(7, exports)
        module += section(10, [0x02, 0x05, 0x00, 0x41, 0x80, 0x08, 0x0b, 0x04, 0x00, 0x41, verdict, 0x0b])
        return Data(module)
    }

    /// A carrier on A2 (the branch a2 is anchored on): the act-on tip is
    /// accepted, and the template carries the pool.
    func testAnActOnTipWhoseAnchorAdvancesIsBuiltOnWithThePool() async throws {
        let fixture = try await fixture()
        let host = fixture.host
        let entering = fixture.rootA2.block.postState.rawCID
        let tip = await NodeRuntime.anchoredTip(
            from: fixture.a2.cid, entering: entering, at: Self.alpha, levels: levels(host), fetcher: host.cas
        )
        XCTAssertEqual(tip?.tip, fixture.a2.cid)
        let pooled = try Self.nonceSpend(1, on: Self.alpha)
        let block = try await candidate(
            input(host, transactions: [pooled]), levels: levels(host),
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
