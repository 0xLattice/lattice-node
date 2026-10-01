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
        // Small scenarios: CI runs the whole target on two cores.
        var config = LevelSimConfig(seed: seed)
        config.grinds = 14
        config.cores = 2
        config.settle = 30_000
        change(&config)
        return config
    }

    func testSeeds() async throws {
        let count = try TestBudget.resolve("LEVEL_SIM_SEEDS", default: 1)
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
    /// holds the identical weighed graph at each after the quiet point. Each
    /// level executes only through its body window, its whole best chain.
    func testThreeLevelsConvergeAtEveryLevel() async throws {
        let (simulator, report) = try await simulate(config(0x3_1E7E) { $0.levels = 3 })
        let world = simulator.world
        XCTAssertEqual(world.paths.count, 3)
        for (core, digests) in report.digests {
            XCTAssertEqual(Set(digests.keys), Set(world.paths), core)
            for path in world.paths {
                let digest = try XCTUnwrap(digests[path])
                XCTAssertEqual(digest.actOnTip, digest.canonicalTip, "\(core) stopped executing \(path) short of its head")
            }
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
    /// work: it is never weighed, and its sender sent a proof that fails
    /// proof-of-work, so it alone is blamed.
    func testAZeroWorkProofIsNeverWeighedAndItsSenderIsBlamed() async throws {
        let (simulator, report) = try await simulate(config(0x2E_20) {
            $0.withholder = false
            $0.zeroWork = true
            $0.scheduleLiar = false
        })
        let header = try XCTUnwrap(simulator.world.zeroWork)
        XCTAssertTrue(report.disconnects.contains { $0.peer == "zerowork" && $0.reason == .proofOfWorkInvalid })
        XCTAssertTrue(report.disconnects.allSatisfy { $0.peer == "zerowork" }, "\(report.disconnects)")
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

    // MARK: - Proofs under a flood

    /// Proof checks are scarce (4 at once, 1 for the index) against pages of
    /// up to 12 proof-bearing headers, doubled roots, and a flooder relaying
    /// every child block ahead of honest relays with forged twins of its
    /// honest proofs and other blocks' proofs. Its first failed check fails
    /// proof-of-work: it alone is blamed, and every honest proof is still
    /// credited everywhere (checked at the quiet point) with identical
    /// weights.
    func testEveryHonestProofIsCreditedThroughScarceSlotsAndAFlood() async throws {
        let (_, report) = try await simulate(config(0xF100D) {
            $0.flooders = 1
            $0.doubleProbability = 0.5
            $0.pageSize = 12
            $0.proofs = ProofConfig(maxChecks: 4, indexChecks: 1, maxPerSource: 16, maxAwaiting: 64, maxAwaitingPerPeer: 32)
            $0.withholder = false
            $0.zeroWork = false
            $0.scheduleLiar = false
        })
        XCTAssertFalse(report.disconnects.isEmpty, "the flooder's failing proofs were never blamed")
        XCTAssertTrue(report.disconnects.allSatisfy { $0.peer == "flooder0" && $0.reason == .proofOfWorkInvalid },
                      "\(report.disconnects)")
    }

    /// Sybils: more flooders than there are check slots, each relaying every
    /// child block with free junk proofs and coming back on every
    /// reconnection. A flooder is disconnected at its first failed check
    /// (its other proofs forgotten), so with only plain caps every honest
    /// proof is credited everywhere within a bounded latency, no honest peer
    /// is blamed, and state stays within the caps (checked every step).
    func testSybilFloodersAreDisconnectedAndCannotStarveHonestProofs() async throws {
        let proofs = ProofConfig(maxChecks: 4, indexChecks: 1, maxPerSource: 16, maxAwaiting: 64, maxAwaitingPerPeer: 16)
        let flooders = proofs.maxChecks + 1
        let (_, report) = try await simulate(config(0x5B11) {
            $0.flooders = flooders
            $0.doubleProbability = 0.5
            $0.pageSize = 12
            $0.proofs = proofs
            $0.withholder = false
            $0.zeroWork = false
            $0.scheduleLiar = false
        })
        XCTAssertEqual(Set(report.disconnects.map(\.peer)), Set((0..<flooders).map { "flooder\($0)" }))
        XCTAssertTrue(report.disconnects.allSatisfy { $0.reason == .proofOfWorkInvalid })
        XCTAssertLessThan(report.creditLatency, 20_000, "an honest proof waited too long")
    }

    /// Blame only when proof-of-work fails: honest peers relay only proofs
    /// they verified, so no honest peer is ever disconnected, with many
    /// doubled roots relayed and served between cores.
    func testHonestPeersRelayingVerifiedProofsAreNeverBlamed() async throws {
        let (_, report) = try await simulate(config(0x40E57) {
            $0.doubleProbability = 0.7
            $0.withholder = false
            $0.zeroWork = false
            $0.scheduleLiar = false
        })
        XCTAssertTrue(report.disconnects.isEmpty, "\(report.disconnects)")
    }

    // MARK: - Choosing a child genesis

    /// Alpha's real genesis link is in Nexus block 1; a competing genesis
    /// whose CID is ground below it is anchored by an uncle off the best
    /// chain, which every node weighs and executes. The uncle's genesis is
    /// never hosted, and all honest nodes on the same tip host the same
    /// child (the invariants check each node's hosted genesis against its
    /// act-on path after every step).
    func testTheChildGenesisResolvesFromTheBestExecutedChain() async throws {
        let (simulator, report) = try await simulate(config(0x6E2E5) {
            $0.withholder = false
            $0.zeroWork = false
            $0.scheduleLiar = false
        })
        let world = simulator.world
        let alpha = world.anchors.filter { $0.child == LevelWorld.alpha }
        XCTAssertEqual(alpha.count, 3, "real, ground and failing")
        let real = try XCTUnwrap(world.links[LevelWorld.alpha]).childGenesisCID
        XCTAssertTrue(alpha.contains { $0.link.childGenesisCID < real }, "the competing CID is ground below the real one")
        for (core, digests) in report.digests {
            XCTAssertEqual(digests[LevelWorld.alpha]?.genesis, real, core)
            let uncle = alpha[1].issuer
            XCTAssertNotNil(digests[LevelWorld.nexus]?.blocks[uncle], "\(core) never weighed the uncle")
        }
    }

    /// Drives one host by hand over a two-level world: weighs and executes
    /// root blocks, and answers bootstraps from the world's content.
    struct HostDriver {
        let world: LevelWorld
        let now = World.genesisTime + 10_000
        var host: HostCore
        var batches: [HostBatch] = []
        var asked: [String] = []
        /// When false, bootstraps are collected here, not answered.
        var answer = true
        var unanswered: [(ChainPath, String, ParentLevelFacts)] = []
        /// When true, root connect jobs are held here, not run.
        var holdRoot = false
        var heldRoot: [ConnectJob] = []
        /// Connect jobs emitted, per block.
        var connects: [String: Int] = [:]

        init(pins: [ChainPath: String] = [:]) async throws {
            var rng = SplitMix64(state: 0x914)
            world = try await LevelWorld.generate(
                rng: &rng, levels: 2, grinds: 12, forkProbability: 0, shareProbability: 0,
                doubleProbability: 0, withholdDelay: 1_000
            )
            host = HostCore(root: world.rootBootstrap.tree, hosted: world.hosted, pins: pins)
        }

        var anchors: [GenesisAnchor] { world.anchors.filter { $0.child == LevelWorld.alpha } }
        var real: String { anchors[0].link.childGenesisCID }
        var ground: String { anchors[1].link.childGenesisCID }
        var failing: String { anchors[2].link.childGenesisCID }
        var hosted: String? { host.levels[LevelWorld.alpha]?.genesis }

        func block(issuing index: Int) -> SimBlock { world.blocks[LevelWorld.nexus]![anchors[index].issuer]! }

        mutating func step(_ event: HostEvent) async throws {
            var queue = [event]
            while !queue.isEmpty {
                for effect in host.step(queue.removeFirst(), now: now) {
                    switch effect {
                    case .persist(let batch):
                        batches.append(batch)
                    case .bootstrap(let path, let cid, let facts):
                        asked.append(cid)
                        guard answer else {
                            unanswered.append((path, cid, facts))
                            continue
                        }
                        let world = world
                        let result = await ChainTree.bootstrap(
                            genesis: BlockHeader(rawCID: cid), fetcher: world.cas,
                            context: try ChainRuntimeContext(path: path), parentFacts: facts,
                            validationContext: ValidationContext(nowMilliseconds: now)
                        ).map { boot -> BootstrappedLevel in
                            let genesis = cid == world.groundGenesis?.cid ? world.groundGenesis! : world.geneses[path]!
                            return BootstrappedLevel(
                                genesis: StoredHeader(blockCID: genesis.cid, block: genesis.block, children: genesis.children),
                                spec: world.specs[path]!, bootstrap: boot
                            )
                        }
                        queue.append(.bootstrapped(path, genesisCID: cid, result))
                    case .level(let path, .fetchBody(let cid)):
                        queue.append(.level(path, .bodyFetched(cid: cid)))
                    case .connect(let path, let job, _) where holdRoot && path == LevelWorld.nexus:
                        connects[job.blockHash, default: 0] += 1
                        heldRoot.append(job)
                    case .connect(let path, let job, let facts):
                        connects[job.blockHash, default: 0] += 1
                        let verdict = await ChainTree.connect(
                            job, fetcher: world.cas, parentFacts: facts,
                            validationContext: ValidationContext(nowMilliseconds: now)
                        )
                        queue.append(.level(path, .connected(verdict)))
                    default:
                        break
                    }
                }
            }
        }

        /// Weigh each block; the body window executes the best chain.
        mutating func weighAndExecute(_ blocks: [SimBlock]) async throws {
            for block in blocks {
                try await step(.mined(MinedGrind(root: block.block, rootChildren: block.children, carried: [])))
            }
        }

        func restored(hosted: Set<ChainPath>? = nil) throws -> HostCore {
            var records: [ChainPath: LevelRecord] = [:]
            var facts: [ChainPath: [BlockImportBatch]] = [LevelWorld.nexus: [world.rootBootstrap.facts]]
            let genesis = world.geneses[LevelWorld.nexus]!
            records[LevelWorld.nexus] = LevelRecord(
                path: LevelWorld.nexus, spec: world.specs[LevelWorld.nexus]!,
                genesis: StoredHeader(blockCID: genesis.cid, block: genesis.block, children: genesis.children)
            )
            for batch in batches {
                for path in batch.removed { records[path] = nil; facts[path] = nil }
                for record in batch.added { records[record.path] = record; facts[record.path] = [] }
                for (path, level) in batch.levels { facts[path, default: []] += level.facts }
            }
            return try HostCore.restore(
                records: Array(records.values), facts: facts,
                issued: batches.flatMap(\.issued), hosted: hosted ?? world.hosted, pins: host.pins
            )
        }
    }

    /// Decision 15c: the hosted child follows the link on the path to the
    /// parent's act-on tip. A reorg onto the uncle's branch (another link)
    /// switches it, and a restore keeps the switch.
    func testAReorgOntoABranchWithAnotherLinkSwitchesTheHostedChild() async throws {
        var driver = try await HostDriver()
        try await driver.weighAndExecute([driver.block(issuing: 0), driver.world.grinds[1].root])
        XCTAssertEqual(driver.hosted, driver.real)
        try await driver.weighAndExecute([driver.block(issuing: 1)])
        XCTAssertEqual(driver.hosted, driver.real, "an uncle's genesis is never hosted")
        try await driver.weighAndExecute(driver.world.reorg)
        XCTAssertEqual(driver.host.levels[LevelWorld.nexus]?.tree.canonicalTip, driver.world.reorg.last?.cid)
        XCTAssertEqual(driver.hosted, driver.ground, "the reorg switched the hosted child")
        XCTAssertEqual(driver.asked, [driver.real, driver.ground])
        var restored = try driver.restored()
        XCTAssertEqual(restored.levels[LevelWorld.alpha]?.genesis, driver.ground, "a restore keeps the switch")
        XCTAssertTrue(restored.pendingBootstraps(now: driver.now).isEmpty)
        let unhosted = try driver.restored(hosted: [])
        XCTAssertEqual(Array(unhosted.levels.keys), [LevelWorld.nexus], "a level no longer hosted is not restored")
    }

    /// Decision 21: a child block whose parent state its parent level has
    /// not executed waits, unvalidated and never excluded, with no timer;
    /// the parent level's execution wakes it, and the child level goes on
    /// executing its chain.
    func testAChildConnectLackingAParentFactWaitsForItsParentLevel() async throws {
        var driver = try await HostDriver()
        let grinds = driver.world.grinds
        try await driver.step(.mined(grinds[0].mined))
        XCTAssertNotNil(driver.hosted)
        driver.holdRoot = true
        for grind in grinds.dropFirst() { try await driver.step(.mined(grind.mined)) }
        // Alpha's first block names the post-state of the held root block.
        let first = try XCTUnwrap(grinds[2].mined.carried.first).block
        let firstCID = try BlockHeader(node: first).rawCID
        var alpha = try XCTUnwrap(driver.host.levels[LevelWorld.alpha])
        XCTAssertEqual(Array(alpha.bodies.awaitingParent.keys), [firstCID])
        try LevelInvariants.checkExecutionStop("driver", path: LevelWorld.alpha, host: driver.host, digest: TreeDigest(alpha.tree))
        XCTAssertEqual(alpha.snapshot.actOnHeight, 0)
        XCTAssertTrue(TreeDigest(alpha.tree).excluded.isEmpty, "a missing parent fact is never invalidity")

        driver.holdRoot = false
        while !driver.heldRoot.isEmpty {
            let job = driver.heldRoot.removeFirst()
            let verdict = await ChainTree.connect(
                job, fetcher: driver.world.cas, validationContext: ValidationContext(nowMilliseconds: driver.now)
            )
            try await driver.step(.level(LevelWorld.nexus, .connected(verdict)))
        }
        let nexus = try XCTUnwrap(driver.host.levels[LevelWorld.nexus]).snapshot
        XCTAssertEqual(nexus.actOnTip, nexus.bestHeaderTip)
        alpha = try XCTUnwrap(driver.host.levels[LevelWorld.alpha])
        try LevelInvariants.checkExecutionStop("driver", path: LevelWorld.alpha, host: driver.host, digest: TreeDigest(alpha.tree))
        XCTAssertTrue(alpha.bodies.awaitingParent.isEmpty)
        XCTAssertEqual(driver.connects[firstCID], 2, "parked once, connected again once when its fact arrived")
        XCTAssertEqual(alpha.snapshot.actOnTip, alpha.snapshot.bestHeaderTip, "the woken child level executed its whole chain")
        XCTAssertGreaterThan(alpha.snapshot.actOnHeight, 1)
    }

    /// A parked child block is connected again only when its parent level
    /// holds the fact it lacked: parent executions in between that do not
    /// produce it leave it parked, unstepped.
    func testAParkedChildIsConnectedAgainOnlyWhenItsFactArrives() async throws {
        // Pinned, so the uncle's branch executing keeps Alpha hosted.
        let probe = try await HostDriver()
        var driver = try await HostDriver(pins: [LevelWorld.alpha: probe.real])
        let grinds = driver.world.grinds
        try await driver.step(.mined(grinds[0].mined))
        XCTAssertNotNil(driver.hosted)
        // The uncle's heavier branch becomes best, its executions held...
        driver.holdRoot = true
        try await driver.weighAndExecute([driver.block(issuing: 1)] + driver.world.reorg)
        // ...while Alpha's first block parks on block 1's state, which only
        // the lighter branch produces.
        try await driver.step(.mined(grinds[1].mined))
        try await driver.step(.mined(grinds[2].mined))
        let first = try BlockHeader(node: try XCTUnwrap(grinds[2].mined.carried.first).block).rawCID
        XCTAssertEqual(driver.host.levels[LevelWorld.alpha]?.bodies.awaitingParent.keys.sorted(), [first])
        var inBetween = 0
        while !driver.heldRoot.isEmpty {
            let job = driver.heldRoot.removeFirst()
            let verdict = await ChainTree.connect(
                job, fetcher: driver.world.cas, validationContext: ValidationContext(nowMilliseconds: driver.now)
            )
            try await driver.step(.level(LevelWorld.nexus, .connected(verdict)))
            inBetween += 1
            XCTAssertNotNil(driver.host.levels[LevelWorld.alpha]?.bodies.awaitingParent[first])
        }
        let nexus = try XCTUnwrap(driver.host.levels[LevelWorld.nexus]).snapshot
        XCTAssertEqual(nexus.actOnTip, driver.world.reorg.last?.cid)
        XCTAssertGreaterThan(inBetween, 1)
        XCTAssertEqual(driver.connects[first], 1, "parent executions that lack its fact never reconnect it")

        // The lighter branch overtakes and executes: the fact arrives.
        driver.holdRoot = false
        for grind in grinds[3...6] { try await driver.step(.mined(grind.mined)) }
        let alpha = try XCTUnwrap(driver.host.levels[LevelWorld.alpha])
        XCTAssertNil(alpha.bodies.awaitingParent[first])
        XCTAssertGreaterThan(alpha.snapshot.actOnHeight, 1)
        XCTAssertEqual(driver.connects[first], 2, "connected again exactly once, when its fact arrived")
    }

    /// A bootstrap answer for a genesis no longer asked (a stale failure)
    /// changes nothing: the current genesis is not marked failed and its
    /// own answer still lands.
    func testAStaleBootstrapAnswerIsIgnored() async throws {
        var driver = try await HostDriver()
        driver.answer = false
        try await driver.weighAndExecute([driver.block(issuing: 0)])
        XCTAssertEqual(driver.unanswered.map(\.1), [driver.real])
        try await driver.step(.bootstrapped(LevelWorld.alpha, genesisCID: driver.ground, .failure(.unavailableEvidence)))
        try await driver.step(.tick)
        XCTAssertEqual(driver.asked, [driver.real], "the stale failure neither failed nor re-asked the current genesis")
        driver.answer = true
        let (path, cid, facts) = driver.unanswered[0]
        let world = driver.world
        let result = await ChainTree.bootstrap(
            genesis: BlockHeader(rawCID: cid), fetcher: world.cas,
            context: try ChainRuntimeContext(path: path), parentFacts: facts,
            validationContext: ValidationContext(nowMilliseconds: driver.now)
        ).map { boot -> BootstrappedLevel in
            let genesis = world.geneses[path]!
            return BootstrappedLevel(
                genesis: StoredHeader(blockCID: genesis.cid, block: genesis.block, children: genesis.children),
                spec: world.specs[path]!, bootstrap: boot
            )
        }
        try await driver.step(.bootstrapped(path, genesisCID: cid, result))
        XCTAssertEqual(driver.hosted, driver.real)
    }

    /// A host restored after its parent reorged past its child's link (the
    /// child's record still the old genesis): `pendingBootstraps` drops the
    /// level, persisting the removal, and asks for the new genesis.
    func testPendingBootstrapsPersistsARemovalAfterRestore() async throws {
        var driver = try await HostDriver()
        try await driver.weighAndExecute([driver.block(issuing: 0), driver.world.grinds[1].root])
        XCTAssertEqual(driver.hosted, driver.real)
        let hostedUntil = driver.batches.count
        try await driver.weighAndExecute([driver.block(issuing: 1)] + driver.world.reorg)
        XCTAssertEqual(driver.hosted, driver.ground)

        let world = driver.world
        let rootGenesis = world.geneses[LevelWorld.nexus]!
        var rootFacts = [world.rootBootstrap.facts]
        var alphaFacts: [BlockImportBatch] = []
        for (position, batch) in driver.batches.enumerated() {
            for (path, level) in batch.levels {
                if path == LevelWorld.nexus { rootFacts += level.facts }
                if path == LevelWorld.alpha, position < hostedUntil { alphaFacts += level.facts }
            }
        }
        var restored = try HostCore.restore(
            records: [LevelRecord(
                path: LevelWorld.nexus, spec: world.specs[LevelWorld.nexus]!,
                genesis: StoredHeader(blockCID: rootGenesis.cid, block: rootGenesis.block, children: rootGenesis.children)
            )] + driver.batches[..<hostedUntil].flatMap(\.added),
            facts: [LevelWorld.nexus: rootFacts, LevelWorld.alpha: alphaFacts],
            issued: driver.batches.flatMap(\.issued),
            hosted: world.hosted
        )
        XCTAssertEqual(restored.levels[LevelWorld.alpha]?.genesis, driver.real)
        let effects = restored.pendingBootstraps(now: driver.now)
        guard case .persist(let batch) = effects.first else { return XCTFail("no batch persisted: \(effects)") }
        XCTAssertEqual(batch.removed, [LevelWorld.alpha])
        XCTAssertNil(restored.levels[LevelWorld.alpha])
        XCTAssertTrue(effects.contains { if case .bootstrap(_, let cid, _) = $0 { return cid == driver.ground } else { return false } })
    }

    /// A genesis that fails to bootstrap is retried on a tick (its content
    /// may arrive later), never swapped for an uncle's.
    func testAFailedGenesisIsRetriedNotSwapped() async throws {
        var driver = try await HostDriver()
        try await driver.weighAndExecute(driver.world.failingBranch)
        XCTAssertEqual(driver.asked, [driver.failing])
        try await driver.weighAndExecute([driver.block(issuing: 1)])
        XCTAssertEqual(driver.asked, [driver.failing], "no retry before a tick, and no side-branch fallback")
        try await driver.step(.tick)
        XCTAssertEqual(driver.asked, [driver.failing, driver.failing], "retried on a tick")
        XCTAssertNil(driver.hosted)
    }

    /// An operator pin overrides the act-on path once an executed parent
    /// block authorizes the pinned genesis. A level executes only its best
    /// chain (decision 21), so the pin is the link of a block executed while
    /// it was best, and a reorg onto the uncle's branch keeps it.
    func testAnOperatorPinOverridesTheActOnPath() async throws {
        var probe = try await HostDriver()
        let real = probe.real
        probe = try await HostDriver(pins: [LevelWorld.alpha: real])
        try await probe.weighAndExecute([probe.block(issuing: 0), probe.world.grinds[1].root])
        XCTAssertEqual(probe.hosted, real)
        try await probe.weighAndExecute([probe.block(issuing: 1)] + probe.world.reorg)
        XCTAssertEqual(probe.host.levels[LevelWorld.nexus]?.tree.canonicalTip, probe.world.reorg.last?.cid)
        XCTAssertEqual(probe.hosted, real, "the pin holds across a reorg onto another link")
        XCTAssertEqual(probe.asked, [real])
    }
}
