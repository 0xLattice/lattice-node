import Lattice
import LatticeNodeCore
import LatticeNodeSim
import XCTest

/// The deterministic simulator: honest cores header-sync from honest sources
/// over lossy links beside a header spammer and a liar, with every invariant
/// checked after every step. `SIM_SEEDS` sets how many seeds run (10 per PR,
/// many nightly); `LATTICE_TEST_SEED` sets the first.
final class SimulationTests: XCTestCase {
    func testSeeds() async throws {
        let count = try TestBudget.resolve("SIM_SEEDS", default: 10)
        let first = try TestSeed.resolve(default: 0x51_0000)
        var headDisagreements = 0
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
            // Headers-first serves best chains, so a block that was never on
            // a server's best chain does not travel; GHOST heads can differ
            // from a source's where such side blocks carry weight.
            if Set(report.coreTips.values).count > 1
                || Set(report.coreTips.values) != Set(report.sourceChains.values.compactMap(\.last)) {
                headDisagreements += 1
            }
        }
        print("simulated \(count) seeds from \(first); seeds whose heads differ from a source's: \(headDisagreements)")
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

    func testTheLiarIsDisconnectedAndHonestSyncCompletes() async throws {
        var config = SimConfig(seed: 0x11A2)
        config.cores = 2
        config.honestSources = 1
        config.spammer = false
        config.liar = true
        config.honestBlocks = 25
        var simulator = try await Simulator.make(config)
        let report = try simulator.run()
        XCTAssertTrue(report.disconnects.contains { $0.peer == "liar" && $0.reason == .malformed })
        XCTAssertTrue(report.disconnects.allSatisfy { $0.peer == "liar" })
        assertSynced(report, TestSeed(value: config.seed))
    }

    func testTheSpammersForkWeighsAndLosesAndItsUnconnectedHeadersDisconnectIt() async throws {
        var config = SimConfig(seed: 0x5BA3)
        config.cores = 2
        config.honestSources = 1
        config.spammer = true
        config.liar = false
        config.spamBlocks = 3
        config.drop = 0
        config.duplicate = 0
        var simulator = try await Simulator.make(config)
        let report = try simulator.run()
        XCTAssertTrue(report.disconnects.contains { $0.peer == "spammer" && $0.reason == .malformed })
        let spam = simulator.world.spam.filter { simulator.world.blocks[$0]!.releaseAt <= simulator.end }
        for (core, held) in report.coreHeld {
            XCTAssertTrue(Set(spam).isSubset(of: held), "\(core) weighs the spam fork")
            XCTAssertFalse(held.contains(simulator.world.orphan), "\(core) holds an unconnected header")
            XCTAssertEqual(report.coreTips[core], report.sourceChains["source0"]?.last)
        }
        assertSynced(report, TestSeed(value: config.seed))
    }
}
