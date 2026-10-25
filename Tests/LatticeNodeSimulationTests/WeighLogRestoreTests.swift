import Lattice
import LatticeNodeCore
import LatticeNodeSim
import XCTest

/// The weigh log is derived from the fact log: each object is logged once,
/// when it is first weighed, however often its facts are re-stated (an
/// execution re-states its block and grind). So the log a restore rebuilds
/// from the facts is the log the node built live, entry for entry.
final class WeighLogRestoreTests: XCTestCase {
    private static let now = World.genesisTime + 1_000_000

    /// A host that mined and executed every grind of a two-level world with
    /// forks and doubly-credited child blocks, with each level's persisted
    /// facts and genesis specs.
    private func mined() async throws -> (
        world: LevelWorld, host: NodeCore, facts: [ChainPath: [BlockImportBatch]], specs: [ChainPath: [ChainSpec]]
    ) {
        var rng = SplitMix64(state: 0x1_0A61)
        let world = try await LevelWorld.generate(
            rng: &rng, levels: 2, grinds: 60, forkProbability: 0.3, shareProbability: 0.2,
            doubleProbability: 0.3, withholdDelay: 1_000
        )
        var host = NodeCore(root: world.rootBootstrap.tree, hosted: world.hosted)
        var facts: [ChainPath: [BlockImportBatch]] = [LevelWorld.nexus: [world.rootBootstrap.facts]]
        var specs: [ChainPath: [ChainSpec]] = [:]
        for grind in world.grinds {
            try await run(&host, .mined(grind.mined), world) { batch in
                for (path, level) in batch.levels {
                    facts[path, default: []] += level.facts
                    specs[path, default: []] += level.headers.compactMap(\.spec)
                }
            }
        }
        return (world, host, facts, specs)
    }

    /// Step `event` and everything it leads to: bodies are all held, and
    /// every connect runs.
    private func run(
        _ host: inout NodeCore, _ event: NodeEvent, _ world: LevelWorld, persisted: (NodeBatch) -> Void = { _ in }
    ) async throws {
        var queue = [event]
        while !queue.isEmpty {
            for effect in host.step(queue.removeFirst(), now: Self.now) {
                switch effect {
                case .persist(let batch):
                    persisted(batch)
                case .level(let path, .fetchBody(let cid)):
                    queue.append(.level(path, .bodyFetched(cid: cid)))
                case .connect(let path, let job, let parentFacts):
                    let verdict = await ChainTree.connect(
                        job, fetcher: world.cas, parentFacts: parentFacts,
                        validationContext: ValidationContext(nowMilliseconds: Self.now)
                    )
                    queue.append(.level(path, .connected(verdict)))
                default:
                    break
                }
            }
        }
    }

    func testTheLogARestoreRebuildsIsTheLiveLog() async throws {
        let (world, host, facts, specs) = try await mined()
        let restored = try NodeCore.restore(
            root: try ChainCore.restore(
                replaying: facts[LevelWorld.nexus] ?? [], context: try XCTUnwrap(world.rootBootstrap.tree.context),
                specs: [try XCTUnwrap(world.specs[LevelWorld.nexus])]
            ),
            facts: facts, specs: specs, hosted: world.hosted
        )
        XCTAssertEqual(Set(restored.levels.keys), Set(host.levels.keys))
        for (path, level) in host.levels {
            let live = level.sync.log.entries
            let rebuilt = try XCTUnwrap(restored.levels[path]).sync.log.entries
            XCTAssertEqual(rebuilt, live, "\(path): same entries, same order")
            XCTAssertEqual(Set(live).count, live.count, "\(path): no entry twice")
        }
        // Fixture guards: what makes the comparison bite.
        let child = try XCTUnwrap(host.levels[LevelWorld.alpha])
        XCTAssertTrue(child.sync.log.entries.contains { $0.kind == .proof }, "the child level logged proofs")
        let restated = (facts[LevelWorld.alpha] ?? []).filter { batch in
            batch.facts.contains { if case .validation = $0 { true } else { false } }
        }
        XCTAssertFalse(restated.isEmpty, "executions re-stated logged objects")
        let forked = host.levels.values.contains { level in
            level.sync.log.entries.contains { level.tree.children(of: $0.block).count > 1 }
        }
        XCTAssertTrue(forked, "the graph forks")
    }

    /// A header or proof delivered again weighs nothing new, so nothing is
    /// appended to any level's log.
    func testADuplicateDeliveryAppendsNothing() async throws {
        let world: LevelWorld
        var host: NodeCore
        (world, host, _, _) = try await mined()
        let before = host.levels.mapValues(\.sync.log.entries)
        for grind in world.grinds {
            try await run(&host, .mined(grind.mined), world)
        }
        XCTAssertEqual(host.levels.mapValues(\.sync.log.entries), before)
    }
}
