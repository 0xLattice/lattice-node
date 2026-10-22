import Lattice
import LatticeNodeCore
@testable import LatticeNodeSim
import XCTest

/// Multi-level runs under frequent parent forks, against Lattice's forward
/// anchor rule (spec §5.3 step 6: a child block's parent anchor only moves
/// forward along its parent's history). The world's honest miners build as
/// the node's template does (`forwardAnchors`), each block pays its own
/// reward account so parent branches produce distinct states
/// (`divergentStates`), and the last grinds are mined with no forks
/// (`calmTail`). After the quiet point `LevelInvariants.checkForwardAnchors`
/// holds at every child level: (a) no honest child block is refused for
/// parent continuity, (b) the child keeps producing executed blocks after
/// parent reorganizations, (c) its act-on chain anchors only on its parent's
/// act-on chain.
final class ForwardAnchorSimulationTests: XCTestCase {
    private static let seeds: [UInt64] = [0xF0_0001, 0xF0_0002, 0xF0_0003, 0xF0_0004]

    private func config(_ seed: UInt64, forward: Bool = true) -> LevelSimConfig {
        var config = LevelSimConfig(seed: seed)
        config.levels = 3
        config.cores = 2
        config.grinds = 20
        config.settle = 30_000
        config.forkProbability = 0.6
        config.forwardAnchors = forward
        config.divergentStates = true
        config.calmTail = 4
        return config
    }

    /// Parent blocks off the final best chain: the reorganizations a world
    /// made.
    private func abandoned(_ world: LevelWorld, _ path: ChainPath, _ digest: TreeDigest) -> Int {
        (world.blocks[path] ?? [:]).keys.filter { !digest.canonicalPath.contains($0) }.count
    }

    /// Four seeds at a 0.6 parent fork probability, three levels, two
    /// cores: the run's invariants, then `checkForwardAnchors` (a)-(c), hold
    /// (the simulator throws otherwise). Non-vacuity: the parent forked, and
    /// every child level advanced.
    func testChildLevelsFollowTheirParentsThroughForks() async throws {
        var reorganized = 0
        for seed in Self.seeds {
            var simulator = try await LevelSimulator.make(config(seed))
            let report: LevelSimReport
            do {
                report = try await simulator.run()
            } catch {
                XCTFail("seed \(String(seed, radix: 16)): \(error)")
                continue
            }
            let world = simulator.world
            XCTAssertTrue(world.backwardAnchors().isEmpty)
            for (core, digests) in report.digests {
                reorganized += abandoned(world, LevelWorld.nexus, try XCTUnwrap(digests[LevelWorld.nexus]))
                for path in world.paths where path.count > 1 {
                    let digest = try XCTUnwrap(digests[path])
                    XCTAssertGreaterThan(digest.blocks[digest.actOnTip]?.height ?? 0, 3, "\(core) \(path) advanced")
                }
            }
        }
        XCTAssertGreaterThan(reorganized, 0, "the worlds fork their parent")
    }

    /// The finding behind `forwardAnchors`: the world builder's legacy
    /// miner picks a child block's predecessor and its carrier's parent
    /// independently, so under parent forks it builds child blocks whose
    /// anchor moves backward or sideways, which Lattice refuses, with the
    /// one-state-per-height parent states of the default worlds too.
    func testTheLegacyBuilderAnchorsBackwardUnderParentForks() async throws {
        for seed in Self.seeds {
            for divergent in [false, true] {
                var rng = SplitMix64(state: seed)
                let config = config(seed, forward: false)
                let world = try await LevelWorld.generate(
                    rng: &rng, levels: 3, grinds: config.grinds, forkProbability: config.forkProbability,
                    shareProbability: config.shareProbability, doubleProbability: config.doubleProbability,
                    withholdDelay: config.withholdDelay, forwardAnchors: false, divergentStates: divergent,
                    calmTail: config.calmTail
                )
                XCTAssertFalse(world.backwardAnchors().isEmpty, "seed \(String(seed, radix: 16)), divergent \(divergent)")
            }
        }
    }

    /// Blocks anchored backward or sideways, run through the nodes: never
    /// executed, never excluded (a missing parent fact is not invalidity),
    /// and the quiet-point oracle expects exactly that. With a calm tail the
    /// liveness invariant (b) catches the child that the legacy miner left
    /// stuck behind them.
    func testBackwardAnchorsAreNeverExecutedNorExcluded() async throws {
        var stuck = 0
        for seed in Self.seeds.prefix(2) {
            var legacy = config(seed, forward: false)
            legacy.calmTail = 0
            var simulator = try await LevelSimulator.make(legacy)
            let report = try await simulator.run()
            let backward = simulator.world.backwardAnchors()
            XCTAssertFalse(backward.isEmpty)
            for (core, digests) in report.digests {
                for (path, cid) in backward {
                    let digest = try XCTUnwrap(digests[path])
                    XCTAssertFalse(digest.executed.contains(cid), "\(core) executed \(cid) at \(path)")
                    XCTAssertFalse(digest.excluded.contains(cid), "\(core) excluded \(cid) at \(path)")
                }
            }
            var calm = try await LevelSimulator.make(config(seed, forward: false))
            do {
                _ = try await calm.run()
            } catch {
                XCTAssertTrue("\(error)".contains("calm tail"), "\(error)")
                stuck += 1
            }
        }
        XCTAssertGreaterThan(stuck, 0, "the legacy miner loses child liveness under parent forks")
    }

    /// A legacy child block carried by a root on Nexus's genesis commits the
    /// genesis pre-state (emptyHeader) after a real anchor: Lattice proves
    /// it invalid (`protocolInvalid`), and the oracle lists it in
    /// `world.invalid`, so its exclusion is expected (the world of
    /// `LevelSimulationTests.testTwoLevelsConverge` before the builder
    /// anchored forward).
    func testADropBackToTheGenesisPreStateIsExcluded() async throws {
        var config = LevelSimConfig(seed: 0x2_1E7E)
        config.levels = 2
        config.grinds = 14
        config.cores = 2
        config.settle = 30_000
        config.forwardAnchors = false
        var simulator = try await LevelSimulator.make(config)
        let report = try await simulator.run()
        let world = simulator.world
        let empty = LatticeState.emptyHeader.rawCID
        let alpha = try XCTUnwrap(world.blocks[LevelWorld.alpha])
        let dropped = alpha.values.filter { block in
            block.block.parentState.rawCID == empty
                && block.parent.flatMap { alpha[$0] }.map { $0.block.parentState.rawCID != empty } == true
        }.map(\.cid)
        XCTAssertFalse(dropped.isEmpty, "the world drops an anchor back")
        XCTAssertTrue(Set(dropped).isSubset(of: world.invalid[LevelWorld.alpha] ?? []))
        let excluded = report.digests.values.contains { digests in
            dropped.contains { digests[LevelWorld.alpha]?.excluded.contains($0) == true }
        }
        XCTAssertTrue(excluded, "a node excluded the drop-back")
    }
}
