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

    /// Three levels: every core runs every level, each child genesis a root
    /// weighed by its proof, and holds the identical weighed graph at each after the quiet point. Each
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
    /// (a liveness wait, never blame) and weighs the branch once they are
    /// public.
    func testAProofWithholderIsWaitedForAndNeverBlamed() async throws {
        let (simulator, report) = try await simulate(config(0x1D_1E) {
            $0.withholder = true
            $0.zeroWork = false
            $0.scheduleLiar = false
        })
        let withheld = simulator.world.grinds.filter(\.withheld).flatMap(\.mined.carried)
        XCTAssertEqual(withheld.count, 2)
        XCTAssertTrue(report.disconnects.isEmpty, "\(report.disconnects)")
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
    func testEveryHonestProofIsCreditedUnderATightBudgetAndAFlood() async throws {
        let (_, report) = try await simulate(config(0xF100D) {
            $0.flooders = 1
            $0.doubleProbability = 0.5
            $0.pageSize = 12
            $0.proofs = ChildProofConfig(maxQueuedBytes: Self.tightProofBudget, maxAwaiting: 64)
            $0.withholder = false
            $0.zeroWork = false
            $0.scheduleLiar = false
        })
        XCTAssertFalse(report.disconnects.isEmpty, "the flooder's failing proofs were never blamed")
        XCTAssertTrue(report.disconnects.allSatisfy { $0.peer == "flooder0" && $0.reason == .proofOfWorkInvalid },
                      "\(report.disconnects)")
    }

    /// The operator's byte budget for proofs in a check, a few proofs' worth.
    private static let tightProofBudget = 16 * 1_024

    /// Sybils: several flooders, each relaying every child block with free
    /// junk proofs and coming back on every reconnection, against a tight
    /// operator budget for proofs in a check. A flooder is disconnected at
    /// its first failed check, so with only plain caps every honest proof is
    /// credited everywhere within a bounded latency, no honest peer is
    /// blamed, and state stays within the caps (checked every step). A page
    /// of junk costs its check, never a verdict: nothing bounds a flood but
    /// the network. A flooder whose every push names a header already held
    /// or asked of another is never asked, so its junk is never checked and
    /// it stays: harmless, and which flooder that is depends on timing.
    func testSybilFloodersAreDisconnectedAndCannotStarveHonestProofs() async throws {
        let proofs = ChildProofConfig(maxQueuedBytes: Self.tightProofBudget, maxAwaiting: 64)
        let flooders = 5
        let (_, report) = try await simulate(config(0x5B11) {
            $0.flooders = flooders
            $0.doubleProbability = 0.5
            $0.pageSize = 12
            $0.proofs = proofs
            $0.withholder = false
            $0.zeroWork = false
            $0.scheduleLiar = false
        })
        // Every flooder whose proofs a core took is disconnected, and no one else.
        let served = report.servedProofs.filter { $0.hasPrefix("flooder") }
        XCTAssertFalse(served.isEmpty)
        XCTAssertEqual(Set(report.disconnects.map(\.peer)), served)
        XCTAssertLessThanOrEqual(served.count, flooders)
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

    // MARK: - The proof download

    /// One honest peer serves a long child chain, at the default bounds, to
    /// a node that never ticks (so nothing is asked twice): every block
    /// weighs and no header is asked for twice. The root level asks for one
    /// page.
    func testALongChildChainWeighsWithoutAskingTwice() async throws {
        var rng = SplitMix64(state: 0x51075)
        let world = try await LevelWorld.generate(
            rng: &rng, levels: 2, grinds: 200, forkProbability: 0, shareProbability: 0,
            doubleProbability: 0, withholdDelay: 1_000
        )
        let now = World.genesisTime + 1_000_000
        let config = ChainCoreConfig()
        let alpha = LevelWorld.alpha
        var host = NodeCore(root: world.rootBootstrap.tree.detached(), hosted: world.hosted, config: config)
        var source = LevelSource(name: "source", config: config)
        let peer = PeerID(key: "source", session: 1)
        // Alpha's genesis comes with the grind that carries it; everything
        // after it comes from the peer.
        var queue: [NodeEvent] = world.grinds.prefix(3).map { .mined($0.mined) } + [.peerReady(peer)]
        var asked: [ChainPath: [Int]] = [:]
        var askedCIDs: [String: Int] = [:]
        while !queue.isEmpty {
            for effect in host.step(queue.removeFirst(), now: now) {
                switch effect {
                case .level(let path, .send(_, let message)):
                    if case .getData(_, let cids) = message {
                        asked[path, default: []].append(cids.count)
                        if path == alpha {
                            for cid in cids { askedCIDs[cid, default: 0] += 1 }
                        }
                    }
                    for case .send(_, let path, let reply) in source.received(
                        message, at: path, from: PeerID(key: "node", session: 1), now: now, world: world
                    ) {
                        queue.append(.received(peer, path, reply))
                    }
                case .level(let path, .verifyProofs(let batch)):
                    queue.append(.level(path, .proofsVerified(batch.run { world.blocks[path]?[$0]?.block })))
                case .level(let path, .deriveProofs(let jobs)):
                    for job in jobs {
                        let held = job.block ?? world.blocks[path]?[job.childCID]?.block
                        queue.append(.level(path, .derived(await job.run(held: held, upstream: [], fetcher: world.cas))))
                    }
                case .level(let path, .fetchByCID(_, let cid)):
                    queue.append(.level(path, .childIndexFetched(
                        peer, cid: cid, source.fetch(cid, at: path, now: now, world: world)
                    )))
                // Nexus executes what it weighed; Alpha's gate opened when Nexus had weighed its peer's log.
                case .level(let path, .fetchBody(let cid)):
                    queue.append(.level(path, .bodyFetched(cid: cid)))
                case .connect(let path, let jobs):
                    queue.append(.level(path, await ConnectRun.connected(
                        jobs, fetcher: world.cas, parentFacts: host.parentFacts(for: path), now: now
                    )))
                case .disconnect(let gone, let reason):
                    XCTFail("disconnected \(gone) as \(reason)")
                default:
                    break
                }
            }
        }
        let served = world.released(alpha, at: now, withheld: false).filter { $0.height > 0 }.map(\.cid)
        let level = try XCTUnwrap(host.levels[alpha])
        let weighed = TreeDigest(level.tree).blocks
        XCTAssertEqual(served.filter { weighed[$0] == nil }.count, 0, "child blocks never weighed")
        XCTAssertTrue(level.sync.proofs.awaiting.isEmpty)
        XCTAssertEqual(askedCIDs.values.filter { $0 > 1 }.count, 0, "a header asked of the peer twice")
        XCTAssertEqual(asked[LevelWorld.nexus]?.count, 1, "the root level asks for a whole page at once")
    }

    /// The evidence index holds only the proofs this level credited: every
    /// proof a step indexes credits its root at a weighed block once the
    /// step is done, in the batch of the facts that credit it. So the index
    /// has nothing to give back, and the node never asks it.
    func testEveryIndexedChildProofIsAlreadyCredited() async throws {
        var rng = SplitMix64(state: 0x5E1F)
        let world = try await LevelWorld.generate(
            rng: &rng, levels: 2, grinds: 60, forkProbability: 0, shareProbability: 0,
            doubleProbability: 0, withholdDelay: 1_000
        )
        let now = World.genesisTime + 1_000_000
        let config = ChainCoreConfig()
        let alpha = LevelWorld.alpha
        var host = NodeCore(root: world.rootBootstrap.tree.detached(), hosted: world.hosted, config: config)
        var source = LevelSource(name: "source", config: config)
        let peer = PeerID(key: "source", session: 1)
        var queue: [NodeEvent] = world.grinds.prefix(3).map { .mined($0.mined) } + [.peerReady(peer)]
        var indexed = 0
        while !queue.isEmpty {
            for effect in host.step(queue.removeFirst(), now: now) {
                switch effect {
                case .persist(let batch):
                    let tree = try XCTUnwrap(host.levels[alpha]).tree
                    for (path, level) in batch.levels where path == alpha {
                        for stored in level.proofs {
                            indexed += 1
                            XCTAssertTrue(tree.contains(blockHash: stored.childCID), "an indexed proof's block is weighed")
                            XCTAssertNotNil(
                                tree.workContribution(id: stored.proof.rootCID, at: stored.childCID),
                                "an indexed proof credits its root"
                            )
                        }
                    }
                case .level(let path, .send(_, let message)):
                    for case .send(_, let path, let reply) in source.received(
                        message, at: path, from: PeerID(key: "node", session: 1), now: now, world: world
                    ) {
                        queue.append(.received(peer, path, reply))
                    }
                case .level(let path, .verifyProofs(let batch)):
                    queue.append(.level(path, .proofsVerified(batch.run { world.blocks[path]?[$0]?.block })))
                case .level(let path, .deriveProofs(let jobs)):
                    for job in jobs {
                        let held = job.block ?? world.blocks[path]?[job.childCID]?.block
                        queue.append(.level(path, .derived(await job.run(held: held, upstream: [], fetcher: world.cas))))
                    }
                case .level(let path, .fetchByCID(_, let cid)):
                    queue.append(.level(path, .childIndexFetched(
                        peer, cid: cid, source.fetch(cid, at: path, now: now, world: world)
                    )))
                // Nexus executes what it weighed; Alpha's gate opened when Nexus had weighed its peer's log.
                case .level(let path, .fetchBody(let cid)):
                    queue.append(.level(path, .bodyFetched(cid: cid)))
                case .connect(let path, let jobs):
                    queue.append(.level(path, await ConnectRun.connected(
                        jobs, fetcher: world.cas, parentFacts: host.parentFacts(for: path), now: now
                    )))
                default:
                    break
                }
            }
        }
        let weighed = TreeDigest(try XCTUnwrap(host.levels[alpha]).tree).blocks
        XCTAssertGreaterThan(weighed.count, 50, "the child chain was not weighed")
        XCTAssertGreaterThan(indexed, 50, "no credited proof was indexed")
    }

    /// A peer answers each child-level `getData` with every header it has,
    /// proofs and all: only the asked ones wait for a proof, and no check is
    /// spent on another.
    func testAChildDataAnswerIsTakenOnlyForWhatWasAsked() async throws {
        var rng = SplitMix64(state: 0x51075)
        let world = try await LevelWorld.generate(
            rng: &rng, levels: 2, grinds: 200, forkProbability: 0, shareProbability: 0,
            doubleProbability: 0, withholdDelay: 1_000
        )
        let now = World.genesisTime + 1_000_000
        // Small pages, so the chain takes several requests.
        var config = ChainCoreConfig()
        config.maxHeadersPerPage = 16
        let alpha = LevelWorld.alpha
        var host = NodeCore(root: world.rootBootstrap.tree.detached(), hosted: world.hosted, config: config)
        var source = LevelSource(name: "source", config: config)
        let peer = PeerID(key: "source", session: 1)
        let node = PeerID(key: "node", session: 1)
        let served = world.released(alpha, at: now, withheld: false).filter { $0.height > 0 }.map(\.cid)
        var everything: [HeaderEntry] = []
        for case .send(_, _, .headers(let all)) in source.received(
            .getData(requestID: 0, cids: served), at: alpha, from: node, now: now, world: world
        ) {
            everything = all.entries
        }
        XCTAssertEqual(everything.count, served.count)
        var queue: [NodeEvent] = world.grinds.prefix(3).map { .mined($0.mined) } + [.peerReady(peer)]
        var asked = Set<String>()
        var answers = 0
        while !queue.isEmpty {
            for effect in host.step(queue.removeFirst(), now: now) {
                switch effect {
                case .level(let path, .send(_, let message)):
                    if path == alpha, case .getData(_, let cids) = message { asked.formUnion(cids) }
                    for case .send(_, let path, var reply) in source.received(message, at: path, from: node, now: now, world: world) {
                        if path == alpha, case .headers(let page) = reply {
                            reply = .headers(HeadersResponse(
                                requestID: page.requestID, entries: page.entries + everything, hasMore: page.hasMore
                            ))
                            answers += 1
                        }
                        queue.append(.received(peer, path, reply))
                    }
                case .level(let path, .verifyProofs(let batch)):
                    for job in batch.jobs {
                        XCTAssertTrue(asked.contains(job.childCID), "a check spent on a header not asked for")
                    }
                    queue.append(.level(path, .proofsVerified(batch.run { world.blocks[path]?[$0]?.block })))
                case .level(let path, .deriveProofs(let jobs)):
                    for job in jobs {
                        let held = job.block ?? world.blocks[path]?[job.childCID]?.block
                        queue.append(.level(path, .derived(await job.run(held: held, upstream: [], fetcher: world.cas))))
                    }
                case .level(let path, .fetchByCID(_, let cid)):
                    queue.append(.level(path, .childIndexFetched(
                        peer, cid: cid, source.fetch(cid, at: path, now: now, world: world)
                    )))
                // Nexus executes what it weighed; Alpha's gate opened when Nexus had weighed its peer's log.
                case .level(let path, .fetchBody(let cid)):
                    queue.append(.level(path, .bodyFetched(cid: cid)))
                case .connect(let path, let jobs):
                    queue.append(.level(path, await ConnectRun.connected(
                        jobs, fetcher: world.cas, parentFacts: host.parentFacts(for: path), now: now
                    )))
                case .disconnect(let gone, let reason):
                    XCTFail("disconnected \(gone) as \(reason)")
                default:
                    break
                }
            }
            let level = try XCTUnwrap(host.levels[alpha])
            XCTAssertTrue(asked.isSuperset(of: level.sync.proofs.awaiting.keys), "a header not asked for awaits a proof")
            XCTAssertTrue(asked.isSuperset(of: level.sync.proofs.verifying.values.map(\.cid)))
        }
        XCTAssertGreaterThan(answers, 1)
        let weighed = TreeDigest(try XCTUnwrap(host.levels[alpha]).tree).blocks
        XCTAssertEqual(served.filter { weighed[$0] == nil }.count, 0, "child blocks never weighed")
    }

    /// Child blocks carried by seventeen roots each, served with every
    /// proof: all seventeen are credited, a few per answer, the rest as the
    /// header is asked again on a tick.
    func testAChildBlockCarriedBySeventeenRootsIsCreditedWithAll() async throws {
        var rng = SplitMix64(state: 0x17)
        let world = try await LevelWorld.generate(
            rng: &rng, levels: 2, grinds: 12, forkProbability: 0, shareProbability: 0,
            doubleProbability: 1, doubles: 16, withholdDelay: 1_000
        )
        var now = World.genesisTime + 1_000_000
        let config = ChainCoreConfig()
        let alpha = LevelWorld.alpha
        var host = NodeCore(root: world.rootBootstrap.tree.detached(), hosted: world.hosted, config: config)
        var source = LevelSource(name: "source", config: config)
        let peer = PeerID(key: "source", session: 1)
        let served = world.released(alpha, at: now, withheld: false).filter { $0.height > 0 }.map(\.cid)
        let roots = Dictionary(uniqueKeysWithValues: served.map { cid in
            (cid, Set(world.publicProofs(alpha, cid, at: now).map(\.rootCID)))
        })
        XCTAssertGreaterThan(roots.values.filter { $0.count == 17 }.count, 3)
        func missing() throws -> Int {
            let weighed = TreeDigest(try XCTUnwrap(host.levels[alpha]).tree).blocks
            return roots.map { cid, roots in roots.subtracting(weighed[cid]?.grinds.keys.map { $0 } ?? []).count }.reduce(0, +)
        }
        // Alpha's genesis comes with the grind that carries it.
        let first = try XCTUnwrap(world.grinds.firstIndex { !$0.mined.carried.isEmpty })
        var queue: [NodeEvent] = world.grinds.prefix(through: first).map { .mined($0.mined) } + [.peerReady(peer)]
        var asks: [String: Int] = [:]
        var ticks = 0
        while true {
            while !queue.isEmpty {
                for effect in host.step(queue.removeFirst(), now: now) {
                    switch effect {
                    case .level(let path, .send(_, let message)):
                        if path == alpha, case .getData(_, let cids) = message {
                            for cid in cids { asks[cid, default: 0] += 1 }
                        }
                        for case .send(_, let path, let reply) in source.received(
                            message, at: path, from: PeerID(key: "node", session: 1), now: now, world: world
                        ) {
                            queue.append(.received(peer, path, reply))
                        }
                    case .level(let path, .verifyProofs(let batch)):
                        queue.append(.level(path, .proofsVerified(batch.run { world.blocks[path]?[$0]?.block })))
                    case .level(let path, .deriveProofs(let jobs)):
                        for job in jobs {
                            let held = job.block ?? world.blocks[path]?[job.childCID]?.block
                            queue.append(.level(path, .derived(await job.run(held: held, upstream: [], fetcher: world.cas))))
                        }
                    case .level(let path, .fetchByCID(_, let cid)):
                        queue.append(.level(path, .childIndexFetched(
                            peer, cid: cid, source.fetch(cid, at: path, now: now, world: world)
                        )))
                    // Nexus executes what it weighed; Alpha's gate opened when Nexus had weighed its peer's log.
                    case .level(let path, .fetchBody(let cid)):
                        queue.append(.level(path, .bodyFetched(cid: cid)))
                    case .connect(let path, let jobs):
                        queue.append(.level(path, await ConnectRun.connected(
                            jobs, fetcher: world.cas, parentFacts: host.parentFacts(for: path), now: now
                        )))
                    case .disconnect(let gone, let reason):
                        XCTFail("disconnected \(gone) as \(reason)")
                    default:
                        break
                    }
                }
            }
            let left = try missing()
            print("seventeen roots: \(left) proofs uncredited after \(ticks) ticks, most asks of one header \(asks.values.max() ?? 0)")
            guard left > 0, ticks < 20 else { break }
            ticks += 1
            now += config.headersTimeout
            queue.append(.tick)
        }
        XCTAssertEqual(try missing(), 0, "proofs never credited")
    }

    /// Node-local finality at a child level: every header is
    /// weighed, each attaching at the tip of its time, but a proof arriving
    /// for a block that has since fallen beyond the window is declined. Blocks
    /// inside the window collect every grind; nobody is blamed.
    func testFinalityDeclinesLateProofsForOldChildBlocks() async throws {
        var rng = SplitMix64(state: 0x17)
        let world = try await LevelWorld.generate(
            rng: &rng, levels: 2, grinds: 12, forkProbability: 0, shareProbability: 0,
            doubleProbability: 1, doubles: 16, withholdDelay: 1_000
        )
        var now = World.genesisTime + 1_000_000
        var config = ChainCoreConfig()
        let window: UInt64 = 2
        let alpha = LevelWorld.alpha
        // A window on the child chain alone.
        config.finality = FinalityWindows(byChain: [alpha: window])
        var host = NodeCore(root: world.rootBootstrap.tree.detached(), hosted: world.hosted, config: config)
        var source = LevelSource(name: "source", config: config)
        let peer = PeerID(key: "source", session: 1)
        let served = world.released(alpha, at: now, withheld: false).filter { $0.height > 0 }.map(\.cid)
        let first = try XCTUnwrap(world.grinds.firstIndex { !$0.mined.carried.isEmpty })
        var queue: [NodeEvent] = world.grinds.prefix(through: first).map { .mined($0.mined) } + [.peerReady(peer)]
        for _ in 0..<20 {
            while !queue.isEmpty {
                for effect in host.step(queue.removeFirst(), now: now) {
                    switch effect {
                    case .level(let path, .send(_, let message)):
                        for case .send(_, let path, let reply) in source.received(
                            message, at: path, from: PeerID(key: "node", session: 1), now: now, world: world
                        ) {
                            queue.append(.received(peer, path, reply))
                        }
                    case .level(let path, .verifyProofs(let batch)):
                        queue.append(.level(path, .proofsVerified(batch.run { world.blocks[path]?[$0]?.block })))
                    case .level(let path, .deriveProofs(let jobs)):
                        for job in jobs {
                            let held = job.block ?? world.blocks[path]?[job.childCID]?.block
                            queue.append(.level(path, .derived(await job.run(held: held, upstream: [], fetcher: world.cas))))
                        }
                    case .level(let path, .fetchByCID(_, let cid)):
                        queue.append(.level(path, .childIndexFetched(
                            peer, cid: cid, source.fetch(cid, at: path, now: now, world: world)
                        )))
                    // Nexus executes what it weighed; Alpha's gate opened when Nexus had weighed its peer's log.
                    case .level(let path, .fetchBody(let cid)):
                        queue.append(.level(path, .bodyFetched(cid: cid)))
                    case .connect(let path, let jobs):
                        queue.append(.level(path, await ConnectRun.connected(
                            jobs, fetcher: world.cas, parentFacts: host.parentFacts(for: path), now: now
                        )))
                    case .disconnect(let gone, let reason):
                        XCTFail("disconnected \(gone) as \(reason)")
                    default:
                        break
                    }
                }
            }
            now += config.headersTimeout
            queue.append(.tick)
        }
        let tree = try XCTUnwrap(host.levels[alpha]).tree
        let weighed = TreeDigest(tree).blocks
        let heights = Dictionary(uniqueKeysWithValues: world.released(alpha, at: now, withheld: false).map { ($0.cid, $0.height) })
        let tip = tree.getHighestBlockHeight()
        var declined = 0
        for cid in served {
            let roots = Set(world.publicProofs(alpha, cid, at: now).map(\.rootCID))
            let credited = Set(weighed[cid]?.grinds.keys.map { $0 } ?? [])
            XCTAssertNotNil(weighed[cid], "every header arrives at the tip of its time")
            let height = try XCTUnwrap(heights[cid])
            if tip > height, tip - height > window {
                declined += roots.subtracting(credited).count
            } else {
                XCTAssertEqual(credited.intersection(roots), roots, "a block inside the window collects every grind")
            }
        }
        XCTAssertGreaterThan(declined, 0, "late proofs for old blocks are declined")
        XCTAssertEqual(try XCTUnwrap(host.levels[host.rootPath]).sync.declined.count, 0, "the root has no window")
    }

    // MARK: - Waiting on the parent level

    /// Drives one host by hand over a two-level world: weighs root blocks
    /// and runs every connect job, or holds the root's.
    struct NodeCoreHarness {
        let world: LevelWorld
        let now = World.genesisTime + 10_000
        var host: NodeCore
        /// When true, root connect jobs are held here, not run.
        var holdRoot = false
        var heldRoot: [[ConnectJob]] = []
        /// Connect jobs emitted, per block.
        var connects: [String: Int] = [:]

        init() async throws {
            var rng = SplitMix64(state: 0x914)
            world = try await LevelWorld.generate(
                rng: &rng, levels: 2, grinds: 12, forkProbability: 0, shareProbability: 0,
                doubleProbability: 0, withholdDelay: 1_000
            )
            host = NodeCore(root: world.rootBootstrap.tree.detached(), hosted: world.hosted)
        }

        mutating func step(_ event: NodeEvent) async throws {
            var queue = [event]
            while !queue.isEmpty {
                for effect in host.step(queue.removeFirst(), now: now) {
                    switch effect {
                    case .level(let path, .fetchBody(let cid)):
                        queue.append(.level(path, .bodyFetched(cid: cid)))
                    case .connect(let path, let jobs) where holdRoot && path == LevelWorld.nexus:
                        for job in jobs { connects[job.blockHash, default: 0] += 1 }
                        heldRoot.append(jobs)
                    case .connect(let path, let jobs):
                        for job in jobs { connects[job.blockHash, default: 0] += 1 }
                        queue.append(.level(path, await ConnectRun.connected(
                            jobs, fetcher: world.cas, parentFacts: host.parentFacts(for: path), now: now
                        )))
                    default:
                        break
                    }
                }
            }
        }
    }

    /// Decision 21: a child block whose parent state its parent level has
    /// not executed waits, unvalidated and never excluded, with no timer;
    /// the parent level's execution wakes it, and the child level goes on
    /// executing its chain.
    func testAChildConnectLackingAParentFactWaitsForItsParentLevel() async throws {
        var harness = try await NodeCoreHarness()
        let grinds = harness.world.grinds
        try await harness.step(.mined(grinds[0].mined))
        harness.holdRoot = true
        for grind in grinds.dropFirst() { try await harness.step(.mined(grind.mined)) }
        // Alpha's genesis names the post-state of a held root block.
        let first = try XCTUnwrap(grinds[2].mined.carried.first).block
        let firstCID = try BlockHeader(node: first).rawCID
        var alpha = try XCTUnwrap(harness.host.levels[LevelWorld.alpha]?.held)
        XCTAssertNotNil(alpha.bodies.awaitingParent[firstCID])
        for cid in alpha.bodies.awaitingParent.keys {
            XCTAssertNil(harness.connects[cid], "no connect is issued for a block whose parent state is not executed")
        }
        try LevelInvariants.checkExecutionStop("harness", path: LevelWorld.alpha, host: harness.host, digest: TreeDigest(alpha.tree))
        XCTAssertEqual(alpha.snapshot.actOnHeight, 0)
        XCTAssertTrue(TreeDigest(alpha.tree).excluded.isEmpty, "a missing parent fact is never invalidity")

        harness.holdRoot = false
        while !harness.heldRoot.isEmpty {
            let jobs = harness.heldRoot.removeFirst()
            try await harness.step(.level(LevelWorld.nexus, await ConnectRun.connected(
                jobs, fetcher: harness.world.cas, now: harness.now
            )))
        }
        let nexus = try XCTUnwrap(harness.host.levels[LevelWorld.nexus]).snapshot
        XCTAssertEqual(nexus.actOnTip, nexus.bestHeaderTip)
        alpha = try XCTUnwrap(harness.host.levels[LevelWorld.alpha]?.held)
        try LevelInvariants.checkExecutionStop("harness", path: LevelWorld.alpha, host: harness.host, digest: TreeDigest(alpha.tree))
        XCTAssertTrue(alpha.bodies.awaitingParent.isEmpty)
        XCTAssertEqual(harness.connects[firstCID], 1, "never connected while it lacked its fact: connected once it arrived")
        XCTAssertEqual(alpha.snapshot.actOnTip, alpha.snapshot.bestHeaderTip, "the woken child level executed its whole chain")
        XCTAssertGreaterThan(alpha.snapshot.actOnHeight, 1)
    }

}
