import Lattice
@testable import LatticeNodeCore
@testable import LatticeNodeSim
import XCTest
@testable import LatticeNode

/// A level is mined unless it, or a level above it, holds a backlog of its
/// best chain to execute (`NodeRuntime.mined`): the same rule at the root,
/// which then has no template, and at a child, which is left out of the
/// root's.
final class MinedLevelsTests: XCTestCase {
    private static let now = World.genesisTime + 1_000_000
    private static let nexus = LevelWorld.nexus
    private static let alpha = LevelWorld.alpha

    /// A host running Nexus and Alpha, fed grinds the way the shell feeds
    /// them, its connects run at once or held.
    private struct Host {
        var node: NodeCore
        let cas: SimCAS
        var holding = false
        var held: [(path: ChainPath, job: ConnectJob)] = []

        mutating func drive(_ event: NodeEvent) async {
            var queue = [event]
            while !queue.isEmpty {
                for effect in node.step(queue.removeFirst(), now: MinedLevelsTests.now) {
                    switch effect {
                    case .level(let path, .fetchBody(let cid)):
                        queue.append(.level(path, .bodyFetched(cid: cid)))
                    case .connect(let path, let job) where holding:
                        held.append((path, job))
                    case .connect(let path, let job):
                        queue.append(.level(path, .connected(await connect(path, job))))
                    default:
                        break
                    }
                }
            }
        }

        func connect(_ path: ChainPath, _ job: ConnectJob) async -> ConnectVerdict {
            await ChainTree.connect(
                job, fetcher: cas, parentFacts: node.parentFacts(for: path),
                validationContext: ValidationContext(nowMilliseconds: MinedLevelsTests.now)
            )
        }

        /// Run the first held connect, holding whatever it starts.
        mutating func runHeld() async {
            let (path, job) = held.removeFirst()
            await drive(.level(path, .connected(await connect(path, job))))
        }

        func mined(_ path: ChainPath) -> Bool {
            NodeRuntime.mined(path, root: MinedLevelsTests.nexus, levels: node.levels)
        }
    }

    func testALevelHoldingABacklogAndEveryLevelBelowItAreNotMined() async throws {
        var builder = try await LevelWorld.Builder(levels: 2)
        let t = World.genesisTime
        let interval = LevelWorld.interval
        let genesis = try XCTUnwrap(builder.geneses[Self.nexus])
        let n0 = try await builder.grind(on: genesis, carrying: [], at: t + interval / 2, outcome: .block).root
        let g = try await builder.childGenesis(Self.alpha, parentState: n0.block.postState.rawCID, at: t + interval)
        let n1 = try await builder.grind(on: n0, carrying: [(Self.alpha, g)], at: t + interval, outcome: .block).root
        let a1 = try await builder.build(on: g, carrierPrevState: n1.block.postState.rawCID, timestamp: t + 2 * interval, nonce: 1)
        let n2 = try await builder.grind(on: n1, carrying: [(Self.alpha, a1)], at: t + 2 * interval, outcome: .block).root
        let a2 = try await builder.build(on: a1, carrierPrevState: n2.block.postState.rawCID, timestamp: t + 3 * interval, nonce: 1)
        let n3 = try await builder.grind(on: n2, carrying: [(Self.alpha, a2)], at: t + 3 * interval, outcome: .block).root
        let world = builder.world()
        var host = Host(node: NodeCore(root: world.rootBootstrap.tree.detached(), hosted: world.hosted), cas: world.cas)
        let grinds = builder.grinds
        for grind in grinds.dropLast(2) { await host.drive(.mined(grind.mined)) }
        XCTAssertEqual(host.node.levels[Self.nexus]?.snapshot.actOnTip, n1.cid)
        XCTAssertEqual(host.node.levels[Self.alpha]?.snapshot.actOnTip, g.cid)

        // One block arriving at each level, as at the tip: both are mined
        // while it executes.
        host.holding = true
        await host.drive(.mined(grinds[grinds.count - 2].mined))
        XCTAssertEqual(host.held.map(\.path), [Self.nexus, Self.alpha], "N2 carried a1")
        XCTAssertTrue(host.mined(Self.nexus))
        XCTAssertTrue(host.mined(Self.alpha))

        // A second block behind it: Nexus holds a backlog (N2, N3), so
        // nothing is mined, and the root answers 503 executing.
        await host.drive(.mined(grinds[grinds.count - 1].mined))
        XCTAssertFalse(host.mined(Self.nexus))
        XCTAssertFalse(host.mined(Self.alpha), "a child is carried only under its parent's block")

        // N2 executes: Nexus holds only N3 and is mined; Alpha, holding a1
        // and a2, is left out of it.
        await host.runHeld()
        XCTAssertEqual(host.node.levels[Self.nexus]?.snapshot.actOnTip, n2.cid)
        XCTAssertTrue(host.mined(Self.nexus))
        XCTAssertFalse(host.mined(Self.alpha))

        // a1 executes: Alpha holds only a2, and both are mined.
        await host.runHeld()
        XCTAssertEqual(host.node.levels[Self.alpha]?.snapshot.actOnTip, a1.cid)
        XCTAssertTrue(host.mined(Self.nexus))
        XCTAssertTrue(host.mined(Self.alpha))
        while !host.held.isEmpty { await host.runHeld() }
        XCTAssertEqual(host.node.levels[Self.nexus]?.snapshot.actOnTip, n3.cid)
        XCTAssertEqual(host.node.levels[Self.alpha]?.snapshot.actOnTip, a2.cid)
    }
}
