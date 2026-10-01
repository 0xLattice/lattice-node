import Lattice
import LatticeNodeCore
import LatticeNodeSim
import XCTest

/// The simulator with bodies: every core downloads bodies by CID through the
/// content layer and executes the best chain, with the invariants (the
/// "Lattice architecture preserved" gate, the body window, and liveness at
/// the quiet point) checked after every step.
final class BodySimulationTests: XCTestCase {
    private func config(seed: UInt64) -> SimConfig {
        var config = SimConfig(seed: seed)
        config.cores = 3
        config.honestSources = 1
        config.spammer = false
        config.liar = false
        config.honestBlocks = 24
        config.forkProbability = 0
        config.drop = 0
        config.duplicate = 0
        config.maxDelay = 50
        config.bodyWindow = 4
        return config
    }

    /// The final best chain of the released honest blocks.
    private func honestBestChain(_ world: World) -> [String] {
        var reference = GhostReference(genesis: world.genesis.cid)
        for block in world.released(world.honest, at: .max) {
            reference.add(block.cid, parent: block.parent, work: workForTarget(block.block.target))
        }
        return reference.descent().path
    }

    func testEveryCoreExecutesTheBestChainToItsTip() async throws {
        var simulator = try await Simulator.make(config(seed: 0xB0D1))
        let report = try await simulator.run()
        let tip = try XCTUnwrap(honestBestChain(simulator.world).last)
        for (core, actOn) in report.actOnTips {
            XCTAssertEqual(actOn, tip, core)
            XCTAssertEqual(report.coreTips[core], tip, core)
        }
        XCTAssertGreaterThanOrEqual(report.connects, 3 * 24)
    }

    func testAnInvalidBodyIsExcludedStillWeighsAndItsRelayerIsNeverBlamed() async throws {
        var config = config(seed: 0xB0D2)
        config.invalidBody = true
        var simulator = try await Simulator.make(config)
        let report = try await simulator.run()
        let world = simulator.world
        // The invalid branch outweighs honest block 3 when it arrives, so
        // every core executes it and excludes it; its work still weighs.
        for (core, excluded) in report.coreExcluded {
            XCTAssertTrue(excluded.contains(world.invalidBody), "\(core) never excluded the invalid body")
            XCTAssertTrue(report.coreHeld[core]?.contains(world.invalidBodyChild) == true)
            XCTAssertEqual(report.actOnTips[core], report.coreTips[core])
        }
        XCTAssertFalse(report.disconnects.contains { $0.peer == "invalid-body" })
    }

    func testAWithheldBodyIsALivenessWaitNeverBlame() async throws {
        var config = config(seed: 0xB0D3)
        let world = try await Simulator.make(config).world
        let chain = honestBestChain(world)
        let held = chain[6]
        let release = (world.blocks[held]?.releaseAt ?? 0) + 20_000
        config.withheldBodies = [held: release]
        var simulator = try await Simulator.make(config)
        let report = try await simulator.run()
        XCTAssertTrue(report.disconnects.isEmpty)
        for actOn in report.actOnTips.values {
            XCTAssertEqual(actOn, chain.last)
        }
    }

    func testABodyThatNeverArrivesHoldsTheActOnTipBelowItAndBlamesNoOne() async throws {
        var config = config(seed: 0xB0D4)
        let world = try await Simulator.make(config).world
        let chain = honestBestChain(world)
        config.withheldBodies = [chain[6]: .max]
        var simulator = try await Simulator.make(config)
        let report = try await simulator.run()
        XCTAssertTrue(report.disconnects.isEmpty)
        for (core, actOn) in report.actOnTips {
            XCTAssertEqual(actOn, chain[5], "\(core) acts on the block below the missing body")
            XCTAssertEqual(report.coreTips[core], chain.last, "\(core) still syncs headers past it")
        }
    }

    func testCrashesThatTearWritesRestartFromTheStoreAndCatchUp() async throws {
        var config = config(seed: 0xB0D5)
        config.invalidBody = true
        let start = World.genesisTime
        config.crashes = [
            (at: start + 4_000, core: "core0", mode: .loseBatch),
            (at: start + 8_000, core: "core1", mode: .keepContentLoseFacts),
            (at: start + 12_000, core: "core2", mode: .keepFactsLoseUnexecutedBodies),
            (at: start + 16_000, core: "core0", mode: .keepContentLoseFacts),
        ]
        var simulator = try await Simulator.make(config)
        let report = try await simulator.run()
        XCTAssertEqual(report.crashes, 4)
        let tip = try XCTUnwrap(honestBestChain(simulator.world).last)
        for (core, actOn) in report.actOnTips {
            XCTAssertEqual(actOn, tip, core)
        }
    }

    func testTheWindowNeverExceedsTheOperatorCount() async throws {
        var config = config(seed: 0xB0D6)
        config.bodyWindow = 1
        var simulator = try await Simulator.make(config)
        let report = try await simulator.run()
        XCTAssertEqual(Set(report.actOnTips.values).count, 1)
    }
}
