import Lattice
import LatticeNodeCore
import LatticeNodeSim
import UInt256
import XCTest

/// Consensus edge cases across levels and restarts: one grind relayed down
/// several paths is credited once per level, and an excluded subtree that
/// keeps gaining work weighs but is never selected, before and after a
/// restart from the fact log.
final class ConsensusEdgeSimulationTests: XCTestCase {
    private static let now = World.genesisTime + 1_000_000
    private let peer = PeerID(key: "peer", session: 1)

    // MARK: - One grind, many paths, three levels

    private func config(_ seed: UInt64, _ change: (inout LevelSimConfig) -> Void = { _ in }) -> LevelSimConfig {
        var config = LevelSimConfig(seed: seed)
        config.grinds = 14
        config.cores = 2
        config.settle = 30_000
        config.levels = 3
        config.withholder = false
        config.zeroWork = false
        config.scheduleLiar = false
        change(&config)
        return config
    }

    /// Each level's grinds per block, from a digest.
    private func credits(_ digests: [ChainPath: TreeDigest]) -> [ChainPath: [String: [String: UInt256]]] {
        digests.mapValues { $0.blocks.mapValues(\.grinds) }
    }

    /// Every grind carrying blocks at Nexus, Alpha and Beta, relayed to each
    /// core by two other cores with every message doubled, is credited
    /// exactly as with single delivery over one link: the same grinds with
    /// the same work at every level (equal, not a superset). A restart from
    /// the durable facts credits the same.
    func testAGrindRelayedDownTwoPathsIsCreditedOncePerLevel() async throws {
        let single = config(0xD0_ED6E) {
            $0.drop = 0
            $0.duplicate = 0
            $0.doubleProbability = 0.5
        }
        var base = try await LevelSimulator.make(single)
        var many = single
        many.cores = 3
        many.duplicate = 1
        var relayed = LevelSimulator(config: many, world: base.world, rng: base.rngAfterWorld)
        let once = try await base.run()
        let twice = try await relayed.run()
        let world = base.world
        XCTAssertEqual(world.paths.count, 3)

        // The world must hold a grind carrying blocks at all three levels.
        let threeLevel = world.grinds.filter { grind in
            grind.rootIsBlock && Set(grind.mined.carried.map(\.path)) == [LevelWorld.alpha, LevelWorld.beta]
        }
        XCTAssertFalse(threeLevel.isEmpty, "no grind carries a block at every level")

        // Non-vacuity: every core reported every level. With three cores each
        // core hears every header from two distinct peers, and `duplicate = 1`
        // doubles every message leg.
        XCTAssertEqual(once.digests.count, 2)
        XCTAssertEqual(twice.digests.count, 3)
        for digests in Array(once.digests.values) + Array(twice.digests.values) {
            XCTAssertEqual(Set(digests.keys), Set(world.paths))
            for path in world.paths { XCTAssertGreaterThan(digests[path]?.blocks.count ?? 0, 1, "\(path) weighed nothing") }
        }

        let reference = try XCTUnwrap(once.digests.values.first)
        for path in world.paths {
            for (core, digests) in once.digests {
                XCTAssertEqual(digests[path], reference[path], "\(core) differs at \(path) on one link")
            }
        }
        for (core, digests) in twice.digests {
            for path in world.paths {
                XCTAssertEqual(credits(digests)[path], credits(reference)[path], "\(core) credits \(path) differently when relayed twice")
                XCTAssertEqual(digests[path]?.blocks.mapValues(\.subtreeWork), reference[path]?.blocks.mapValues(\.subtreeWork),
                               "\(core) weighs \(path) differently when relayed twice")
                XCTAssertEqual(digests[path]?.canonicalTip, reference[path]?.canonicalTip, "\(core) selects differently at \(path)")
                XCTAssertEqual(digests[path], reference[path], "\(core) holds a different graph at \(path)")
            }
            for grind in threeLevel {
                XCTAssertEqual(digests[LevelWorld.nexus]?.blocks[grind.root.cid]?.grinds.count, 1, core)
                for carried in grind.mined.carried {
                    let cid = try BlockHeader(node: carried.block).rawCID
                    let truth = world.proofs[carried.path]?[cid] ?? [:]
                    let grinds = try XCTUnwrap(digests[carried.path]?.blocks[cid]?.grinds, "\(core) never weighed \(cid)")
                    // Hierarchical GHOST also credits the parent level's
                    // attributed runs, keyed by carrier: derived, not grinds.
                    // Every other key must be the run of a parent-level block
                    // that carries this one (a Nexus block root for Alpha, an
                    // Alpha block for Beta), and only a carrier the parent weighed.
                    let directory = carried.path[carried.path.count - 1]
                    let carriers = Set(world.grinds.flatMap { other -> [String] in
                        guard other.mined.carried.contains(where: { $0.path == carried.path && (try? BlockHeader(node: $0.block).rawCID) == cid })
                        else { return [] }
                        if carried.path.count == 2 { return other.rootIsBlock ? [other.root.cid] : [] }
                        return other.mined.carried.filter { $0.path == Array(carried.path.dropLast()) }
                            .compactMap { try? BlockHeader(node: $0.block).rawCID }
                    })
                    let parent = Array(carried.path.dropLast())
                    let runs = Set(carriers.filter { digests[parent]?.blocks[$0] != nil }.compactMap {
                        AttributedRunIdentity(carrierBlockHash: $0, directory: directory).contributionID
                    })
                    let extra = Set(grinds.keys).subtracting(truth.keys)
                    XCTAssertTrue(extra.isSubset(of: runs), "\(core) credits \(cid) at \(carried.path) with \(extra.subtracting(runs)), neither a grind nor a carrier's run")
                    let direct = grinds.filter { !runs.contains($0.key) }
                    XCTAssertEqual(direct, truth.compactMapValues { $0.evidence.contribution?.work },
                                   "\(core) credits \(cid) at \(carried.path) other than once per grind")
                }
            }
        }

        // Restart every relayed core from its store alone.
        for (core, digests) in twice.digests {
            let store = try XCTUnwrap(relayed.durable(core))
            let restored = try NodeCore.restore(
                root: try XCTUnwrap(store.records[LevelWorld.nexus]),
                facts: store.levels.mapValues(\.facts),
                specs: store.levels.mapValues { $0.headers.values.compactMap(\.spec) },
                hosted: world.hosted,
                config: relayed.coreConfig,
                logID: core,
                cursors: store.levels.mapValues(\.cursors)
            )
            for path in world.paths {
                let level = try XCTUnwrap(restored.levels[path], "\(core) lost \(path)")
                let after = TreeDigest(level.tree)
                XCTAssertEqual(after.blocks.mapValues(\.grinds), credits(digests)[path], "\(core) re-credits \(path) after restart")
                XCTAssertEqual(after.blocks.mapValues(\.grinds), credits(reference)[path], "\(core) after restart at \(path)")
                XCTAssertEqual(after.blocks.mapValues(\.subtreeWork), digests[path]?.blocks.mapValues(\.subtreeWork), "\(core) reweighs \(path) after restart")
                XCTAssertEqual(after.canonicalTip, digests[path]?.canonicalTip, "\(core) reselects at \(path) after restart")
            }
        }
    }

    // MARK: - An excluded subtree that keeps gaining work

    private var shown: [String: HeaderEntry] = [:]

    private func show(_ core: inout ChainCore, _ blocks: [SimBlock]) -> [ChainEffect] {
        guard let state = core.sync.peers[peer] else { return [] }
        let first = core.sync.cursors[peer.key] == nil ? 1 : state.taken + 1
        let ids = blocks.enumerated().map { offset, block -> StreamEntry in
            shown[block.cid] = HeaderEntry(block: block.block, children: block.children)
            return StreamEntry(position: first + UInt64(offset), entry: .header(block.cid))
        }
        var effects = core.step(.received(peer, .stream(StreamPage(
            requestID: state.stream?.requestID ?? 0, logID: "peer", entries: ids, hasMore: false
        ))), now: Self.now)
        var all = effects
        while let ask = effects.compactMap({ effect -> (UInt64, [String])? in
            if case .send(_, .getData(let id, let cids)) = effect { return (id, cids) }
            return nil
        }).first {
            effects = core.step(.received(peer, .headers(HeadersResponse(
                requestID: ask.0, entries: ask.1.compactMap { shown[$0] }, hasMore: false
            ))), now: Self.now)
            all += effects
        }
        return all
    }

    private func persisted(_ effects: [ChainEffect]) -> [BlockImportBatch] {
        effects.flatMap { effect -> [BlockImportBatch] in
            if case .persist(let batch) = effect { return batch.facts }
            return []
        }
    }

    private func jobs(_ effects: [ChainEffect]) -> [ConnectJob] {
        effects.compactMap {
            if case .connect(let job) = $0 { return job }
            return nil
        }
    }

    /// Deliver `cid`'s body, run every connect it starts, persisting as the
    /// shell does; returns every effect.
    private func deliver(_ cid: String, _ world: World, _ content: SimCAS, to core: inout ChainCore) async throws -> [ChainEffect] {
        content.put(world.blocks[cid]!.body)
        var effects = core.step(.bodyFetched(cid: cid), now: Self.now)
        var all = effects
        while let job = jobs(effects).first {
            let verdict = await ChainTree.connect(
                job, fetcher: content, validationContext: ValidationContext(nowMilliseconds: Self.now)
            )
            effects = core.step(.connected(verdict), now: Self.now)
            for case .persist(let batch) in effects {
                for state in batch.states { try await storeMaterialized(state, in: content) }
            }
            all += effects
        }
        return all
    }

    /// Work weighs, validity selects: an excluded block whose subtree keeps
    /// growing past the honest chain's weight weighs every new block, is
    /// never selected, blames no one, and a restart from the fact log holds
    /// the same weights, exclusion and selection.
    func testAnExcludedSubtreeThatKeepsGainingWorkWeighsAndIsNeverSelectedAcrossARestart() async throws {
        var rng = SplitMix64(state: 0x5_1C)
        let world = try await World.generate(rng: &rng, honestBlocks: 12, forkProbability: 0, spamBlocks: 2)
        let chain = world.honest.compactMap { world.blocks[$0] }
        let content = SimCAS(world.genesisContent)
        let invalid = try XCTUnwrap(world.blocks[world.invalidBody])
        let child = try XCTUnwrap(world.blocks[world.invalidBodyChild])

        var core = ChainCore(tree: world.bootstrap.tree, config: ChainCoreConfig(bodyWindow: 4))
        _ = core.step(.peerReady(peer), now: Self.now)
        var all = show(&core, Array(chain.prefix(3)) + [invalid, child])
        for block in chain.prefix(2) { all += try await deliver(block.cid, world, content, to: &core) }
        all += try await deliver(invalid.cid, world, content, to: &core)
        XCTAssertTrue(core.tree.isExcludedRoot(invalid.cid))

        // The excluded subtree keeps gaining work, well past the honest chain.
        let extendedBranch = try await world.branch(from: child, count: 8)
        var previous = TreeDigest(core.tree).blocks[invalid.cid]?.subtreeWork
        for block in extendedBranch {
            all += show(&core, [block])
            XCTAssertTrue(core.tree.contains(blockHash: block.cid), "a block on the excluded subtree is weighed")
            let weight = TreeDigest(core.tree).blocks[invalid.cid]?.subtreeWork
            XCTAssertNotNil(weight)
            if let weight, let before = previous { XCTAssertGreaterThan(weight, before, "its work weighs") }
            previous = weight
            XCTAssertFalse(TreeDigest(core.tree).canonicalPath.contains(invalid.cid), "validity selects")
        }
        let honestWeight = try XCTUnwrap(TreeDigest(core.tree).blocks[chain[2].cid]?.subtreeWork)
        XCTAssertGreaterThan(try XCTUnwrap(previous), honestWeight, "the excluded subtree outweighs the honest branch")
        let before = TreeDigest(core.tree)
        XCTAssertEqual(before.canonicalTip, chain[2].cid)
        XCTAssertTrue(before.excluded.contains(invalid.cid))
        XCTAssertFalse(all.contains { if case .disconnect = $0 { true } else { false } }, "no proof-of-work failed: no blame")

        let log = [world.bootstrap.facts] + persisted(all)
        let restored = try ChainCore.restore(
            replaying: log, context: world.context, specs: [world.spec], config: ChainCoreConfig(bodyWindow: 4)
        )
        let after = TreeDigest(restored.tree)
        XCTAssertEqual(after, before, "the restart rebuilds the same weighed graph")
        XCTAssertTrue(after.excluded.contains(invalid.cid))
        XCTAssertFalse(after.canonicalPath.contains(invalid.cid))
        for block in extendedBranch { XCTAssertNotNil(after.blocks[block.cid]) }
    }
}
