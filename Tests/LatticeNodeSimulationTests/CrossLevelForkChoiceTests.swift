import Lattice
import LatticeNodeCore
@testable import LatticeNodeSim
import UInt256
import XCTest

/// Child fork choice across a parent fork: hierarchical GHOST over the
/// child's own work plus the parent work attributed to each child run
/// (spec §9.10). The parent is never authoritative over which child fork is
/// canonical, its fork choice never reads the child, and a restart from the
/// fact log re-derives the same attribution.
final class CrossLevelForkChoiceTests: XCTestCase {
    private static let now = World.genesisTime + 1_000_000
    private static let alpha = LevelWorld.alpha
    private static let nexus = LevelWorld.nexus

    /// Two hosts fed the same grinds in order: one runs Nexus and Alpha,
    /// one Nexus alone. Persists go to the first's store.
    private struct Hosts {
        let world: LevelWorld
        var both: NodeCore
        var nexusOnly: NodeCore
        var store: HostStore

        init(_ world: LevelWorld) {
            self.world = world
            both = NodeCore(root: world.rootBootstrap.tree, hosted: world.hosted)
            nexusOnly = NodeCore(root: world.rootBootstrap.tree, hosted: [])
            store = HostStore(world: world)
        }

        mutating func feed(_ grinds: [MinedGrind]) async throws {
            for grind in grinds {
                try await Self.step(&both, .mined(grind), world: world) { store.append($0) }
                try await Self.step(&nexusOnly, .mined(grind), world: world) { _ in }
            }
        }

        static func step(
            _ host: inout NodeCore, _ event: NodeEvent, world: LevelWorld, persist: (NodeBatch) -> Void
        ) async throws {
            var queue = [event]
            while !queue.isEmpty {
                for effect in host.step(queue.removeFirst(), now: CrossLevelForkChoiceTests.now) {
                    switch effect {
                    case .persist(let batch):
                        persist(batch)
                    case .level(let path, .fetchBody(let cid)):
                        queue.append(.level(path, .bodyFetched(cid: cid)))
                    case .connect(let path, let job, let facts):
                        let verdict = await ChainTree.connect(
                            job, fetcher: world.cas, parentFacts: facts,
                            validationContext: ValidationContext(nowMilliseconds: CrossLevelForkChoiceTests.now)
                        )
                        queue.append(.level(path, .connected(verdict)))
                    default:
                        break
                    }
                }
            }
        }

        func digest(_ path: ChainPath) throws -> TreeDigest {
            TreeDigest(try XCTUnwrap(both.levels[path]).tree)
        }

        func restored() throws -> NodeCore {
            try NodeCore.restore(
                root: try XCTUnwrap(store.records[LevelWorld.nexus]),
                facts: store.levels.mapValues(\.facts),
                specs: store.levels.mapValues { $0.headers.values.compactMap(\.spec) },
                hosted: world.hosted,
                cursors: store.levels.mapValues(\.cursors)
            )
        }
    }

    /// The rule, computed independently from the world's ground truth: each
    /// Alpha block's own grinds (from its verified proofs), plus, for every
    /// Nexus block P committing Alpha block C, `runWork(P) − grindWork(P)`
    /// credited at C under `AttributedRunIdentity(P, Alpha)`, where a Nexus
    /// block is in the run of its nearest carrier by parent pointer.
    /// Scoped to these two-level worlds: a Nexus block's credited work is its
    /// own block work (shares never enter Nexus, and no grandparent attributes
    /// runs), so `runWork` and `grindWork` reduce to `workForTarget`.
    private func predicted(_ world: LevelWorld) throws -> GhostReference {
        let directory = Self.alpha[Self.alpha.count - 1]
        var commits: [String: String] = [:]
        for grind in world.grinds where grind.rootIsBlock {
            if let carried = grind.mined.carried.first(where: { $0.path == Self.alpha }) {
                commits[grind.root.cid] = try BlockHeader(node: carried.block).rawCID
            }
        }
        let nexus = try XCTUnwrap(world.blocks[Self.nexus])
        func nearestCarrier(_ cid: String) -> String? {
            var current: String? = cid
            while let hash = current {
                if commits[hash] != nil { return hash }
                current = nexus[hash]?.parent
            }
            return nil
        }
        var runWork: [String: UInt256] = [:]
        for cid in nexus.keys {
            guard let block = nexus[cid], block.parent != nil, let carrier = nearestCarrier(cid) else { continue }
            runWork[carrier, default: .zero] += workForTarget(block.block.target)
        }

        let alphaBlocks = try XCTUnwrap(world.blocks[Self.alpha])
        var reference = GhostReference(genesis: try XCTUnwrap(world.geneses[Self.alpha]).cid)
        for block in alphaBlocks.values.sorted(by: { $0.height < $1.height }) {
            var grinds = (world.proofs[Self.alpha]?[block.cid] ?? [:]).compactMapValues { $0.evidence.contribution?.work }
            for (carrier, child) in commits where child == block.cid {
                let own = workForTarget(try XCTUnwrap(nexus[carrier]).block.target)
                let run = runWork[carrier] ?? .zero
                if run > own, let id = AttributedRunIdentity(carrierBlockHash: carrier, directory: directory).contributionID {
                    grinds[id] = run - own
                }
            }
            reference.add(block.cid, parent: block.parent, grinds: grinds)
        }
        return reference
    }

    private func assertMatches(_ digest: TreeDigest, _ reference: GhostReference, _ context: String) {
        let work = reference.subtreeWork()
        XCTAssertEqual(digest.canonicalTip, reference.head, "\(context): child tip")
        XCTAssertEqual(digest.blocks.mapValues(\.grinds), reference.grinds, "\(context): child credits")
        XCTAssertEqual(digest.blocks.compactMapValues(\.subtreeWork), work, "\(context): child weights")
    }

    @discardableResult
    private func assertRestartHolds(_ hosts: Hosts, _ context: String) throws -> NodeCore {
        let restored = try hosts.restored()
        for path in hosts.world.paths {
            let after = TreeDigest(try XCTUnwrap(restored.levels[path]).tree)
            XCTAssertEqual(after, try hosts.digest(path), "\(context): restart rebuilds \(path) differently")
        }
        return restored
    }

    // MARK: - Test 1: carried child forks under a parent fork

    /// Nexus N1 (on N0) carries Alpha's genesis G. Nexus forks: A1 on N1 carries
    /// Alpha block a1, B1 on N1 carries Alpha block b1, and B2 on B1 commits
    /// nothing into Alpha, so Nexus selects B. `shares` child-only shares
    /// rooted on A1 extend a1 with Alpha's own work.
    private func forkedWorld(shares: Int) async throws -> (world: LevelWorld, a1: String, b1: String, b2: String, aTip: String) {
        var builder = try await LevelWorld.Builder(levels: 2)
        let t = World.genesisTime
        let interval = LevelWorld.interval
        // Alpha's genesis anchors a real (non-empty) Nexus state: N0's.
        let n0 = try await builder.grind(on: try XCTUnwrap(builder.geneses[Self.nexus]), carrying: [], at: t + interval / 2, outcome: .block).root
        let g = try await builder.childGenesis(Self.alpha, parentState: n0.block.postState.rawCID, at: t + interval)
        let n1 = try await builder.grind(on: n0, carrying: [(Self.alpha, g)], at: t + interval, outcome: .block).root

        let a1 = try await builder.build(on: g, carrierPrevState: n1.block.postState.rawCID, timestamp: t + 2 * interval, nonce: 1)
        let rootA1 = try await builder.grind(on: n1, carrying: [(Self.alpha, a1)], at: t + 2 * interval, outcome: .block).root
        let b1 = try await builder.build(on: g, carrierPrevState: n1.block.postState.rawCID, timestamp: t + 2 * interval, nonce: 2)
        let rootB1 = try await builder.grind(on: n1, carrying: [(Self.alpha, b1)], at: t + 2 * interval + 1, outcome: .block).root
        let rootB2 = try await builder.grind(on: rootB1, carrying: [], at: t + 3 * interval, outcome: .block).root

        var tip = a1
        for index in 0..<shares {
            let at = t + Int64(3 + index) * interval
            let next = try await builder.build(on: tip, carrierPrevState: rootA1.block.postState.rawCID, timestamp: at, nonce: UInt64(10 + index))
            _ = try await builder.grind(on: rootA1, carrying: [(Self.alpha, next)], at: at, outcome: .share)
            tip = next
        }
        return (builder.world(), a1.cid, b1.cid, rootB2.cid, tip.cid)
    }

    private func runForkCase(shares: Int, expectA: Bool) async throws {
        let (world, a1, b1, b2, aTip) = try await forkedWorld(shares: shares)
        var hosts = Hosts(world)
        try await hosts.feed(world.grinds.map(\.mined))

        // Parent fork choice is B, and is the same with or without the child.
        let nexus = try hosts.digest(Self.nexus)
        XCTAssertEqual(nexus.canonicalTip, b2, "Nexus selects its heavier fork")
        XCTAssertEqual(nexus, TreeDigest(try XCTUnwrap(hosts.nexusOnly.levels[Self.nexus]).tree),
                       "the child level changes nothing on Nexus")

        let alpha = try hosts.digest(Self.alpha)
        let reference = try predicted(world)
        assertMatches(alpha, reference, "live")

        // Non-vacuity: b1 carries an attributed run (B2's work), and the
        // outcome differs from what own work alone would select.
        let directory = Self.alpha[Self.alpha.count - 1]
        let carrierB1 = try XCTUnwrap(world.grinds.first { $0.mined.carried.contains { (try? BlockHeader(node: $0.block).rawCID) == b1 } }).root.cid
        let runID = try XCTUnwrap(AttributedRunIdentity(carrierBlockHash: carrierB1, directory: directory).contributionID)
        XCTAssertNotNil(alpha.blocks[b1]?.grinds[runID], "b1 carries B's attributed run")
        let aWork = try XCTUnwrap(alpha.blocks[a1]?.subtreeWork)
        let bWork = try XCTUnwrap(alpha.blocks[b1]?.subtreeWork)
        let bOwn = try XCTUnwrap(alpha.blocks[b1]?.grinds.filter { $0.key != runID }.values.reduce(UInt256.zero, +))
        XCTAssertGreaterThan(aWork, bOwn, "on own child work alone, A's fork would win")
        if expectA {
            XCTAssertGreaterThan(aWork, bWork, "A's own child work outweighs B's attribution")
            XCTAssertEqual(alpha.canonicalTip, aTip, "the child keeps A's fork although Nexus selected B")
        } else {
            XCTAssertGreaterThan(bWork, aWork, "B's attribution outweighs A's own child work")
            XCTAssertEqual(alpha.canonicalTip, b1, "attribution selects B's child fork")
        }

        let restored = try assertRestartHolds(hosts, "restart")
        assertMatches(TreeDigest(try XCTUnwrap(restored.levels[Self.alpha]).tree), reference, "restart")
    }

    /// One share on a1: A's own child work exceeds b1's, but B2's work,
    /// attributed through B1's run, makes B's child fork heavier.
    func testParentAttributionSelectsTheChildForkUnderTheHeavierParentFork() async throws {
        try await runForkCase(shares: 1, expectA: false)
    }

    /// Six shares on a1: A's own child work outweighs b1 with B's attributed
    /// run, so the child keeps A's fork while Nexus selects B.
    func testOwnChildWorkOutweighsAttributionUnderTheHeavierParentFork() async throws {
        try await runForkCase(shares: 6, expectA: true)
    }

    // MARK: - Test 2: the heavier parent fork omits the child

    /// N1 (on N0) carries G. Alpha forks under G: c1 carried by Nexus block A1 on
    /// N1, c2 carried by a child-only share rooted on N1. Then Nexus B1 on N1
    /// and B2 on B1 commit nothing into Alpha, so Nexus selects B, off the
    /// carrier of c1. B's omission revokes no child work and credits neither
    /// child fork: its work lands in N1's run, attributed at G, the common
    /// ancestor. Child fork choice is unchanged, also after a restart.
    func testAHeavierParentForkThatOmitsTheChildChangesNoChildForkChoice() async throws {
        var builder = try await LevelWorld.Builder(levels: 2)
        let t = World.genesisTime
        let interval = LevelWorld.interval
        // Alpha's genesis anchors a real (non-empty) Nexus state: N0's.
        let n0 = try await builder.grind(on: try XCTUnwrap(builder.geneses[Self.nexus]), carrying: [], at: t + interval / 2, outcome: .block).root
        let g = try await builder.childGenesis(Self.alpha, parentState: n0.block.postState.rawCID, at: t + interval)
        let n1 = try await builder.grind(on: n0, carrying: [(Self.alpha, g)], at: t + interval, outcome: .block).root
        let c1 = try await builder.build(on: g, carrierPrevState: n1.block.postState.rawCID, timestamp: t + 2 * interval, nonce: 1)
        let rootA1 = try await builder.grind(on: n1, carrying: [(Self.alpha, c1)], at: t + 2 * interval, outcome: .block).root
        let c2 = try await builder.build(on: g, carrierPrevState: n1.block.postState.rawCID, timestamp: t + 2 * interval, nonce: 2)
        _ = try await builder.grind(on: n1, carrying: [(Self.alpha, c2)], at: t + 2 * interval + 1, outcome: .share)
        let before = builder.grinds.count
        let rootB1 = try await builder.grind(on: n1, carrying: [], at: t + 2 * interval + 2, outcome: .block).root
        let rootB2 = try await builder.grind(on: rootB1, carrying: [], at: t + 3 * interval, outcome: .block).root
        let world = builder.world()

        var hosts = Hosts(world)
        try await hosts.feed(world.grinds.prefix(before).map(\.mined))
        let nexusBefore = try hosts.digest(Self.nexus)
        XCTAssertEqual(nexusBefore.canonicalTip, rootA1.cid)
        let alphaBefore = try hosts.digest(Self.alpha)
        XCTAssertEqual(alphaBefore.canonicalTip, c1.cid)

        try await hosts.feed(world.grinds.dropFirst(before).map(\.mined))
        let nexus = try hosts.digest(Self.nexus)
        XCTAssertEqual(nexus.canonicalTip, rootB2.cid, "Nexus selects the heavier fork, which omits Alpha")
        XCTAssertFalse(nexus.canonicalPath.contains(rootA1.cid), "c1's carrier is off Nexus's best chain")
        XCTAssertEqual(nexus, TreeDigest(try XCTUnwrap(hosts.nexusOnly.levels[Self.nexus]).tree),
                       "the child level changes nothing on Nexus")

        let alpha = try hosts.digest(Self.alpha)
        assertMatches(alpha, try predicted(world), "live")
        XCTAssertEqual(alpha.canonicalTip, c1.cid, "child fork choice is unchanged by B")
        for fork in [c1.cid, c2.cid] {
            XCTAssertEqual(alpha.blocks[fork]?.grinds, alphaBefore.blocks[fork]?.grinds, "B neither revokes nor adds credit at \(fork)")
            XCTAssertEqual(alpha.blocks[fork]?.subtreeWork, alphaBefore.blocks[fork]?.subtreeWork, "\(fork) weighs the same")
        }
        // B's work reaches Alpha only through N1's run, at the common ancestor G.
        let directory = Self.alpha[Self.alpha.count - 1]
        let runID = try XCTUnwrap(AttributedRunIdentity(carrierBlockHash: n1.cid, directory: directory).contributionID)
        XCTAssertEqual(alpha.blocks[g.cid]?.grinds[runID],
                       workForTarget(rootB1.block.target) + workForTarget(rootB2.block.target))

        let restored = try assertRestartHolds(hosts, "restart")
        XCTAssertEqual(TreeDigest(try XCTUnwrap(restored.levels[Self.alpha]).tree).canonicalTip, c1.cid)
    }
}
