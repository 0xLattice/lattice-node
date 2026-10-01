import Lattice
import LatticeNodeCore
import LatticeNodeSim
import UInt256
import XCTest

/// The deterministic simulator: honest cores header-sync from honest sources
/// over lossy links beside a header spammer and a liar, with every invariant
/// checked after every step. `SIM_SEEDS` sets how many seeds run (10 per PR,
/// many nightly); `LATTICE_TEST_SEED` sets the first.
final class SimulationTests: XCTestCase {
    func testSeeds() async throws {
        let count = try TestBudget.resolve("SIM_SEEDS", default: 10)
        let first = try TestSeed.resolve(default: 0x51_0000)
        for offset in 0..<UInt64(count) {
            let seed = first.value &+ offset
            let replay = TestSeed(value: seed)
            var simulator = try await Simulator.make(.random(seed: seed))
            let report: SimReport
            do {
                report = try simulator.run()
            } catch {
                return XCTFail("\(error) — replay with \(replay)")
            }
            assertSynced(report, replay)
        }
        print("simulated \(count) seeds from \(first)")
    }

    /// Every core holds every block of every honest source's final best chain.
    private func assertSynced(_ report: SimReport, _ replay: TestSeed, line: UInt = #line) {
        for (core, held) in report.coreHeld.sorted(by: { $0.key < $1.key }) {
            for (source, chain) in report.sourceChains {
                let missing = chain.filter { !held.contains($0) }
                XCTAssertTrue(missing.isEmpty, "\(core) misses \(missing.count) of \(source)'s best chain — replay with \(replay)", line: line)
            }
        }
    }

    func testTheSameSeedReplaysTheSameRun() async throws {
        var config = SimConfig.random(seed: 0xD37)
        config.drop = 0.15
        config.duplicate = 0.1
        var a = try await Simulator.make(config)
        var b = try await Simulator.make(config)
        let first = try a.run()
        let second = try b.run()
        XCTAssertEqual(first.trace, second.trace)
        XCTAssertEqual(first.steps, second.steps)
        XCTAssertEqual(first.coreTips, second.coreTips)
    }

    // MARK: - Planted bugs: each invariant can fail

    private func assertCaught(
        _ plant: (inout SimFaults) -> Void,
        _ expected: String,
        seeds: ClosedRange<UInt64> = 0x9A0...0x9A0,
        forkProbability: Double = 0.2,
        line: UInt = #line
    ) async throws {
        for seed in seeds {
            var config = SimConfig(seed: seed)
            config.cores = 2
            config.honestSources = 1
            config.honestBlocks = 20
            config.forkProbability = forkProbability
            var simulator = try await Simulator.make(config)
            plant(&simulator.faults)
            do {
                _ = try simulator.run()
            } catch let SimulationError.invariant(detail) {
                XCTAssertTrue(detail.contains(expected), detail, line: line)
                return
            }
        }
        XCTFail("the planted bug went unnoticed", line: line)
    }

    func testPublishingBeforePersistingIsCaught() async throws {
        try await assertCaught({ $0.publishBeforePersist = true }, "is not durable")
    }

    func testAFactDroppedFromTheStoreIsCaught() async throws {
        // Caught by whichever check reads the lost fact first: the published
        // tip's durability or the weighed block's durable fact.
        try await assertCaught({ $0.dropFact = true }, "durable")
    }

    func testAFlippedTieBreakIsCaught() async throws {
        try await assertCaught(
            { $0.flipReferenceTieBreak = true }, "GHOST reference",
            seeds: 0x7_1E00...0x7_1E0F, forkProbability: 0.6
        )
    }

    /// An honest side block shown to core0 alone reaches every core through
    /// core0's relay, and every core weighs it.
    func testAnUncleShownToOneNodeReachesEveryNode() async throws {
        var config = SimConfig(seed: 0xC1E)
        config.cores = 4
        config.honestSources = 1
        config.spammer = false
        config.liar = false
        config.uncle = true
        config.drop = 0
        config.duplicate = 0
        var simulator = try await Simulator.make(config)
        let report = try simulator.run()
        for (core, held) in report.coreHeld {
            XCTAssertTrue(held.contains(simulator.world.uncle), "\(core) never weighed the uncle")
        }
    }

    /// The honest chain stalls for five half-lives, so its next block is 32
    /// times easier than every node's tip; no peer is blamed or stalled out,
    /// and every core advances past the stall.
    func testEveryCoreAdvancesPastAStallLongerThanFourHalfLives() async throws {
        var config = SimConfig(seed: 0x57A11)
        config.cores = 3
        config.honestSources = 1
        config.spammer = false
        config.liar = false
        config.honestBlocks = 20
        config.forkProbability = 0
        config.stall = (afterBlock: 10, milliseconds: 50_000)
        var simulator = try await Simulator.make(config)
        let world = simulator.world
        let honest = world.honest.compactMap { world.blocks[$0] }
        // Block 11 is dated after the stall, so block 12's target (block
        // 11's next target) is the one ASERT eases.
        let tip = honest[10].block.target
        let resumed = honest[11].block.target
        XCTAssertGreaterThan(resumed, tip.multipliedReportingOverflow(by: 16).partialValue,
                             "the block after the stall is more than 16 times easier than its parent")
        let report = try simulator.run()
        XCTAssertTrue(report.disconnects.isEmpty, "\(report.disconnects)")
        for (core, tip) in report.coreTips {
            XCTAssertEqual(tip, honest.last?.cid, "\(core) did not advance past the stall")
        }
    }

    /// The liar is blamed only for headers that prove no work the chain
    /// accepts; its wrong-spec and wrong-prevState headers (and one on the
    /// latter) are weighed and excluded everywhere, and never selected.
    func testTheLiarIsBlamedOnlyForProofOfWorkAndItsInvalidHeadersWeighExcluded() async throws {
        var config = SimConfig(seed: 0x11A2)
        config.cores = 3
        config.honestSources = 1
        config.spammer = false
        config.liar = true
        config.honestBlocks = 25
        var simulator = try await Simulator.make(config)
        let report = try simulator.run()
        let world = simulator.world
        let liar = report.disconnects.filter { $0.peer == "liar" }
        XCTAssertFalse(liar.isEmpty)
        XCTAssertTrue(liar.allSatisfy { $0.reason == .proofOfWorkInvalid }, "\(liar)")
        XCTAssertTrue(report.disconnects.allSatisfy { $0.peer == "liar" })
        for (core, held) in report.coreHeld {
            XCTAssertTrue(world.excluded.isSubset(of: held), "\(core) did not weigh the invalid headers")
            XCTAssertTrue(held.contains(world.excludedChild), "\(core) did not weigh the excluded subtree")
            for lie in Liar.blameable {
                XCTAssertFalse(held.contains(world.lies[lie]!), "\(core) weighed \(lie)")
            }
            XCTAssertEqual(report.coreTips[core], report.sourceChains["source0"]?.last)
        }
        assertSynced(report, TestSeed(value: config.seed))
    }

    /// The spam fork (valid work at the easiest target the schedule allows)
    /// weighs and loses; garbage never weighs, its flood stays within the
    /// pending budget, and the spammer is disconnected only for its failed
    /// proof-of-work or its stalls.
    func testSpamWeighsAndLosesAndGarbageStaysWithinThePendingBudget() async throws {
        var config = SimConfig(seed: 0x5BA3)
        config.cores = 2
        config.honestSources = 1
        config.spammer = true
        config.liar = false
        config.spamBlocks = 40
        config.garbage = 64
        config.pendingBudget = 64 * 1_024
        config.drop = 0
        config.duplicate = 0
        var simulator = try await Simulator.make(config)
        let world = simulator.world
        let garbageBytes = world.garbage.compactMap { world.blocks[$0] }
            .map { ($0.block.toData()?.count ?? 0) + ($0.children.toData()?.count ?? 0) }.reduce(0, +)
        XCTAssertGreaterThan(garbageBytes, config.pendingBudget, "the flood must overrun the budget")
        let report = try simulator.run()
        XCTAssertLessThanOrEqual(report.pendingPeak, config.pendingBudget)
        let spammer = report.disconnects.filter { $0.peer == "spammer" }
        XCTAssertTrue(spammer.contains { $0.reason == .proofOfWorkInvalid })
        XCTAssertGreaterThan(report.pendingPeak, 0)
        XCTAssertTrue(report.disconnects.allSatisfy { $0.peer == "spammer" })
        for (core, held) in report.coreHeld {
            XCTAssertTrue(Set(world.spam).isSubset(of: held), "\(core) did not weigh the spam fork")
            XCTAssertTrue(Set(world.garbage).isDisjoint(with: held), "\(core) weighed garbage")
            XCTAssertEqual(report.coreTips[core], report.sourceChains["source0"]?.last)
        }
        assertSynced(report, TestSeed(value: config.seed))
    }

    /// Honest child indexes too big to travel inline are fetched by CID from
    /// the peer that sent the header, and every core still syncs.
    func testChildIndexesTooBigToInlineAreFetchedByCID() async throws {
        var config = SimConfig(seed: 0xF7C)
        config.cores = 3
        config.honestSources = 1
        config.spammer = false
        config.liar = false
        var simulator = try await Simulator.make(config)
        let world = simulator.world
        let indexes = world.honest.compactMap { world.blocks[$0]?.children }
        XCTAssertTrue(indexes.contains { ($0.toData()?.count ?? 0) > config.inlineChildIndexBytes })
        XCTAssertTrue(indexes.contains { !$0.entries.isEmpty && ($0.toData()?.count ?? .max) <= config.inlineChildIndexBytes })
        let report = try simulator.run()
        XCTAssertGreaterThan(report.fetches, 0)
        XCTAssertTrue(report.disconnects.isEmpty, "\(report.disconnects)")
        assertSynced(report, TestSeed(value: config.seed))
    }

    /// Two halves mine apart for hundreds of blocks — more than 144 past the
    /// fork — the heavier side faster, then the partition heals. Every core
    /// converges on the heavier side within the default pending budget,
    /// with a spammer flooding throughout.
    func testAPartitionHealsOntoTheHeavierSideWithinTheDefaultBudget() async throws {
        var config = SimConfig(seed: 0x5E1F)
        config.cores = 4
        config.honestBlocks = 10
        config.forkProbability = 0
        config.split = (lighter: 150, heavier: 170)
        config.spammer = true
        config.liar = false
        config.drop = 0
        config.duplicate = 0
        config.pendingBudget = CoreConfig().pendingBudget
        var simulator = try await Simulator.make(config)
        let world = simulator.world
        let heavier = try XCTUnwrap(world.sides[1].last)
        let report = try simulator.run()
        for (core, tip) in report.coreTips {
            XCTAssertEqual(tip, heavier, "\(core) did not converge on the heavier side")
        }
        XCTAssertLessThanOrEqual(report.pendingPeak, config.pendingBudget)
        print("partition heal: \(report.healPages) pages, \(report.healParentFetches) ancestor fetches")
    }

    /// A slow honest link: a page takes longer to transfer than the request
    /// deadline, so the honest source is disconnected as stalled, and the
    /// invariant catches it.
    func testASlowHonestLinkThatMissesTheDeadlineIsCaught() async throws {
        var config = SimConfig(seed: 0x510)
        config.cores = 2
        config.honestSources = 1
        config.spammer = false
        config.liar = false
        config.drop = 0
        config.slowLinks = ["core0-source0": 0.5]
        config.pageSize = 16
        var simulator = try await Simulator.make(config)
        do {
            _ = try simulator.run()
            XCTFail("a stalled honest link went unnoticed")
        } catch let SimulationError.invariant(detail) {
            XCTAssertTrue(detail.contains("disconnected honest peer"), detail)
        }
    }

    /// Many leaves, over a ring of cores that sources
    /// reach through one core each, with links that do not always come back.
    func testManyLeavesOverARingWithFlakyReconnects() async throws {
        var config = SimConfig(seed: 0x1EAF)
        config.cores = 4
        config.honestSources = 2
        config.honestBlocks = 90
        config.sideLeaves = 80
        config.forkProbability = 0
        config.ring = true
        config.sourceFanout = 1
        config.reconnectFailure = 0.5
        config.drop = 0.005
        var simulator = try await Simulator.make(config)
        let report = try simulator.run()
        XCTAssertGreaterThan(report.peakLeaves, 64)
        assertSynced(report, TestSeed(value: config.seed))
    }
}
