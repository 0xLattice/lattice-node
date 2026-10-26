import Lattice
@testable import LatticeNodeCore
@testable import LatticeNodeSim
import XCTest

/// A child chain may hold several genesis roots. When the heaviest one's
/// body is never served, the act-on tip descends from the heaviest executed
/// root (spec §9.4, §9.9): its new blocks are fetched and executed, and the
/// mempool keeps a spec.
final class GenesisForkActOnTests: XCTestCase {
    private static let now = World.genesisTime + 1_000_000
    private static let alpha = LevelWorld.alpha
    private static let nexus = LevelWorld.nexus

    /// Nexus N0, then N1 carrying Alpha's genesis G1. Four Alpha blocks on
    /// G1, each carried by a share on N1. A second Alpha genesis G2, carried
    /// by `g2Shares` shares on N1 so it outweighs G1's subtree.
    private func world(g2Shares: Int = 16) async throws -> (
        world: LevelWorld, base: [MinedGrind], g1Chain: [SimBlock], g1Grinds: [MinedGrind], g2: SimBlock, g2Grinds: [MinedGrind]
    ) {
        var builder = try await LevelWorld.Builder(levels: 2)
        let t = World.genesisTime
        let interval = LevelWorld.interval
        let rootGenesis = try XCTUnwrap(builder.geneses[Self.nexus])
        let n0 = try await builder.grind(on: rootGenesis, carrying: [], at: t + interval / 2, outcome: .block)
        let g1 = try await builder.childGenesis(Self.alpha, parentState: n0.root.block.postState.rawCID, at: t + interval)
        let n1 = try await builder.grind(on: n0.root, carrying: [(Self.alpha, g1)], at: t + interval, outcome: .block)
        let entering = n1.root.block.postState.rawCID

        var chain: [SimBlock] = []
        var chainGrinds: [MinedGrind] = []
        var tip = g1
        for index in 0..<4 {
            let at = t + Int64(2 + index) * interval
            let next = try await builder.build(on: tip, carrierPrevState: entering, timestamp: at, nonce: UInt64(10 + index))
            chainGrinds.append(try await builder.grind(on: n1.root, carrying: [(Self.alpha, next)], at: at, outcome: .share).grind)
            chain.append(next)
            tip = next
        }

        // Built after G1's blocks: the builder's reference follows one genesis.
        let at = t + 10 * interval
        let g2 = try await builder.childGenesis(Self.alpha, parentState: entering, at: at)
        var g2Grinds: [MinedGrind] = []
        for index in 0..<g2Shares {
            g2Grinds.append(try await builder.grind(
                on: n1.root, carrying: [(Self.alpha, g2)], at: at + Int64(index), outcome: .share
            ).grind)
        }
        return (builder.world(), [n0.grind, n1.grind], chain, chainGrinds, g2, g2Grinds)
    }

    /// Step `grinds` into `host` to quiescence, serving every body but
    /// `withheld`'s. Returns the bodies asked for.
    @discardableResult
    private func feed(
        _ grinds: [MinedGrind], to host: inout NodeCore, world: LevelWorld, withheld: String
    ) async throws -> [String] {
        var asked: [String] = []
        for grind in grinds {
            var queue: [NodeEvent] = [.mined(grind)]
            while !queue.isEmpty {
                for effect in host.step(queue.removeFirst(), now: Self.now) {
                    switch effect {
                    case .level(let path, .fetchBody(let cid)):
                        asked.append(cid)
                        if cid != withheld { queue.append(.level(path, .bodyFetched(cid: cid))) }
                    case .connect(let path, let job):
                        let verdict = await ChainTree.connect(
                            job, fetcher: world.cas, parentFacts: host.parentFacts(for: path),
                            validationContext: ValidationContext(nowMilliseconds: Self.now)
                        )
                        queue.append(.level(path, .connected(verdict)))
                    default:
                        break
                    }
                }
            }
        }
        return asked
    }

    func testTheActOnTipDescendsFromTheExecutedGenesisUnderAHeavierUnservedOne() async throws {
        let (world, base, chain, chainGrinds, g2, g2Grinds) = try await world()
        var host = NodeCore(root: world.rootBootstrap.tree.detached(), hosted: world.hosted)

        try await feed(base + chainGrinds.prefix(2), to: &host, world: world, withheld: g2.cid)
        XCTAssertEqual(try XCTUnwrap(host.levels[Self.alpha]).snapshot.actOnTip, chain[1].cid, "fixture: G1's blocks execute")

        let askedForG2 = try await feed(g2Grinds, to: &host, world: world, withheld: g2.cid)
        var alpha = try XCTUnwrap(host.levels[Self.alpha]).held
        XCTAssertEqual(Set(alpha.tree.genesisRoots).count, 2, "Alpha holds two genesis roots")
        XCTAssertEqual(alpha.snapshot.bestHeaderTip, g2.cid, "fixture: G2 outweighs G1's subtree")
        XCTAssertTrue(askedForG2.contains(g2.cid), "the best root's body is asked for")
        XCTAssertFalse(alpha.tree.isExecuted(blockHash: g2.cid))
        XCTAssertEqual(alpha.snapshot.actOnTip, chain[1].cid, "the act-on tip stays under the executed root")
        XCTAssertNotNil(alpha.mining.spec, "the mempool keeps the act-on tip's spec")
        XCTAssertNotNil(ChainCore(tree: alpha.tree.detached()).mining.spec, "a restarted core has the act-on tip's spec")

        let asked = try await feed(Array(chainGrinds.suffix(2)), to: &host, world: world, withheld: g2.cid)
        alpha = try XCTUnwrap(host.levels[Self.alpha]).held
        XCTAssertEqual(alpha.snapshot.bestHeaderTip, g2.cid, "G2 stays the best header tip")
        XCTAssertTrue(asked.contains(chain[2].cid) && asked.contains(chain[3].cid), "bodies under G1 are asked for")
        XCTAssertTrue(alpha.tree.isExecuted(blockHash: chain[3].cid), "G1's new blocks execute")
        XCTAssertEqual(alpha.snapshot.actOnTip, chain[3].cid, "the act-on tip advances along G1")
        XCTAssertEqual(alpha.mining.tipCID, chain[3].cid, "templates build on it")
        let digest = TreeDigest(alpha.tree)
        XCTAssertEqual(digest.actOnTip, chain[3].cid, "the simulator's act-on tip agrees")
        var reference = GhostReference(roots: digest.roots)
        reference.excluded = digest.excluded
        for (hash, entry) in digest.blocks { reference.add(hash, parent: entry.parent, grinds: entry.grinds) }
        XCTAssertEqual(reference.head, g2.cid, "the GHOST reference descends from the genesis fork")
        let work = reference.subtreeWork()
        for (hash, entry) in digest.blocks {
            XCTAssertEqual(entry.subtreeWork, work[hash], "the reference weighs \(hash) under its own root")
        }
        XCTAssertEqual(alpha.connectDistances[g2.cid], 0, "the withheld root is next to connect on its own branch")
    }
}
