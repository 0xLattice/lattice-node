import Lattice
import LatticeNodeCore
import LatticeNodeSim
import UInt256
import XCTest

/// The multi-level simulator: host cores run Nexus and the child chains
/// merge-mined under it (two or three levels), weighing child headers by
/// their proofs, beside a proof withholder, a peer showing a zero-work proof
/// and one showing an off-schedule child header, with the "Lattice
/// architecture preserved" invariants checked at every level after every
/// step. `LEVEL_SIM_SEEDS` sets how many random seeds run.
final class LevelSimulationTests: XCTestCase {
    private func simulate(_ config: LevelSimConfig) async throws -> (LevelSimulator, LevelSimReport) {
        var simulator = try await LevelSimulator.make(config)
        let report = try await simulator.run()
        return (simulator, report)
    }

    private func config(_ seed: UInt64, _ change: (inout LevelSimConfig) -> Void = { _ in }) -> LevelSimConfig {
        var config = LevelSimConfig(seed: seed)
        config.grinds = 20
        change(&config)
        return config
    }

    func testSeeds() async throws {
        let count = try TestBudget.resolve("LEVEL_SIM_SEEDS", default: 3)
        let first = try TestSeed.resolve(default: 0x1E_0000)
        for offset in 0..<UInt64(count) {
            let seed = first.value &+ offset
            do {
                _ = try await simulate(.random(seed: seed))
            } catch {
                return XCTFail("\(error) — replay with \(TestSeed(value: seed))")
            }
        }
    }

    /// Three levels: every core runs every level, its child levels
    /// bootstrapped from genesis links issued by executed parent blocks, and
    /// holds the identical weighed graph at each after the quiet point.
    func testThreeLevelsConvergeAtEveryLevel() async throws {
        let (simulator, report) = try await simulate(config(0x3_1E7E) { $0.levels = 3 })
        let world = simulator.world
        XCTAssertEqual(world.paths.count, 3)
        for (core, digests) in report.digests {
            XCTAssertEqual(Set(digests.keys), Set(world.paths), core)
            XCTAssertFalse(digests[LevelWorld.beta]?.executed.isEmpty ?? true, "\(core) executed nothing on Beta")
        }
        XCTAssertGreaterThan(report.bootstraps, 0)
        XCTAssertGreaterThan(report.executions, 0)
    }

    func testTwoLevelsConverge() async throws {
        let (simulator, report) = try await simulate(config(0x2_1E7E) { $0.levels = 2 })
        XCTAssertEqual(simulator.world.paths.count, 2)
        for (core, digests) in report.digests {
            XCTAssertEqual(Set(digests.keys), Set(simulator.world.paths), core)
        }
    }

    /// Child-only history: a share that misses Nexus but clears Alpha weighs
    /// its Alpha block everywhere, and never enters the Nexus graph.
    func testSharesWeighTheirChildBlocksAndNeverEnterTheRootChain() async throws {
        let (simulator, report) = try await simulate(config(0x5_4A2E) {
            $0.shareProbability = 0.6
            $0.withholder = false
            $0.zeroWork = false
            $0.scheduleLiar = false
        })
        let shares = simulator.world.grinds.filter { !$0.rootIsBlock && !$0.withheld }
        XCTAssertFalse(shares.isEmpty)
        for (core, digests) in report.digests {
            for share in shares {
                XCTAssertNil(digests[LevelWorld.nexus]?.blocks[share.root.cid], "\(core) weighed a share on Nexus")
                for carried in share.mined.carried {
                    let cid = try BlockHeader(node: carried.block).rawCID
                    XCTAssertNotNil(digests[carried.path]?.blocks[cid], "\(core) misses a share's block at \(carried.path)")
                    XCTAssertNotNil(digests[carried.path]?.blocks[cid]?.grinds[share.root.cid], "\(core) misses the share's grind")
                }
            }
        }
        XCTAssertTrue(report.disconnects.isEmpty, "\(report.disconnects)")
    }

    /// A child block carried by two roots weighs both grinds, one per root.
    func testAChildBlockCarriedByTwoRootsWeighsBothGrinds() async throws {
        let (simulator, report) = try await simulate(config(0xD0B1E) {
            $0.doubleProbability = 0.8
            $0.withholder = false
            $0.zeroWork = false
            $0.scheduleLiar = false
        })
        let world = simulator.world
        let doubled = (world.proofs[LevelWorld.alpha] ?? [:]).filter { $0.value.count > 1 }
        XCTAssertFalse(doubled.isEmpty)
        for (core, digests) in report.digests {
            for (cid, roots) in doubled {
                let grinds = Set(digests[LevelWorld.alpha]?.blocks[cid]?.grinds.keys.map { $0 } ?? [])
                XCTAssertTrue(Set(roots.keys).isSubset(of: grinds), "\(core) misses a grind of \(cid)")
            }
        }
    }

    /// The proof withholder shows headers with no proofs: every node waits
    /// (a liveness wait, never blame), looks the proofs up when the evidence
    /// index changes, and weighs the branch once they are public.
    func testAProofWithholderIsWaitedForAndNeverBlamed() async throws {
        let (simulator, report) = try await simulate(config(0x1D_1E) {
            $0.withholder = true
            $0.zeroWork = false
            $0.scheduleLiar = false
        })
        let withheld = simulator.world.grinds.filter(\.withheld).flatMap(\.mined.carried)
        XCTAssertEqual(withheld.count, 2)
        XCTAssertTrue(report.disconnects.isEmpty, "\(report.disconnects)")
        XCTAssertGreaterThan(report.lookups, 0)
        for (core, digests) in report.digests {
            for carried in withheld {
                let cid = try BlockHeader(node: carried.block).rawCID
                XCTAssertNotNil(digests[LevelWorld.alpha]?.blocks[cid], "\(core) never weighed the withheld block")
            }
        }
    }

    /// A header with a proof whose root misses the block's target carries no
    /// work: it is never weighed, and nobody is blamed.
    func testAZeroWorkProofIsNeverWeighedAndBlamesNoOne() async throws {
        let (simulator, report) = try await simulate(config(0x2E_20) {
            $0.withholder = false
            $0.zeroWork = true
            $0.scheduleLiar = false
        })
        let header = try XCTUnwrap(simulator.world.zeroWork)
        XCTAssertTrue(report.disconnects.isEmpty, "\(report.disconnects)")
        XCTAssertGreaterThan(report.verifications, 0)
        for (core, digests) in report.digests {
            XCTAssertNil(digests[LevelWorld.alpha]?.blocks[header.block.cid], "\(core) weighed a zero-work header")
        }
    }

    /// A child header off the timestamp schedule, with a proof that weighs,
    /// fails proof-of-work on its own: its sender is blamed, only for that.
    func testAnOffScheduleChildHeaderWithAWeighingProofIsBlamed() async throws {
        let (simulator, report) = try await simulate(config(0x0FF5) {
            $0.withholder = false
            $0.zeroWork = false
            $0.scheduleLiar = true
        })
        let header = try XCTUnwrap(simulator.world.offSchedule)
        let blamed = report.disconnects.filter { $0.peer == "liar" }
        XCTAssertFalse(blamed.isEmpty)
        XCTAssertTrue(report.disconnects.allSatisfy { $0.peer == "liar" && $0.reason == .proofOfWorkInvalid }, "\(report.disconnects)")
        for (core, digests) in report.digests {
            XCTAssertNil(digests[LevelWorld.alpha]?.blocks[header.block.cid], "\(core) weighed an off-schedule header")
        }
    }

    /// An invalid Alpha block (forged post-state) and the block on it weigh
    /// everywhere; execution excludes the first; neither is ever selected.
    func testAnInvalidChildSubtreeWeighsAndIsNeverSelected() async throws {
        let (simulator, report) = try await simulate(config(0xBAD_1E) {
            $0.withholder = false
            $0.zeroWork = false
            $0.scheduleLiar = false
        })
        let invalid = try XCTUnwrap(simulator.world.invalid[LevelWorld.alpha]?.first)
        for (core, digests) in report.digests {
            let alpha = try XCTUnwrap(digests[LevelWorld.alpha])
            XCTAssertTrue(alpha.excluded.contains(invalid), core)
            XCTAssertTrue(alpha.blocks.values.contains { $0.parent == invalid }, "\(core) does not weigh the invalid subtree")
            XCTAssertFalse(alpha.canonicalPath.contains(invalid), core)
        }
    }

    /// One mined grind is one atomic subtree insert: its step emits one
    /// persist, and a Nexus block carrying Alpha and Beta blocks writes all
    /// three levels in it.
    func testAMinedGrindPersistsEveryLevelInOneBatch() async throws {
        let (_, report) = try await simulate(config(0x3_A70) {
            $0.levels = 3
            $0.shareProbability = 0.2
        })
        XCTAssertFalse(report.minedBatches.isEmpty)
        XCTAssertTrue(report.minedBatches.allSatisfy { $0.persists <= 1 })
        XCTAssertEqual(report.minedBatches.map(\.levels).max(), 3)
    }

    func testTheSameWorldAndSeedReplayTheSameRun() async throws {
        let config = config(0xDE7) { $0.drop = 0.05 }
        var a = try await LevelSimulator.make(config)
        var b = LevelSimulator(config: config, world: a.world, rng: a.rngAfterWorld)
        let first = try await a.run()
        let second = try await b.run()
        XCTAssertEqual(first.trace, second.trace)
        XCTAssertEqual(first.steps, second.steps)
    }
}
