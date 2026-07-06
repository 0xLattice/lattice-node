import XCTest
@testable import Lattice
@testable import LatticeNode
import Lattice
@testable import Ivy
import UInt256
import cashew
import Synchronization

/// (storage-recovery): a restored child must NOT go live before its
/// recovery loop runs, and a failed `chain_tip` meta write must NOT be swallowed.
///
/// Residual 1 — restored child deployment metadata must not materialize a parent-side
/// child ChainState. Children run as separate node processes.
///
/// Residual 2 — `persistChainState` used `try?` for the `chain_tip:<key>` meta
/// write, so a failed write was swallowed yet `chain_state.json` still saved and
/// `blocksSinceLastPersist` reset to 0. Boot prefers the meta tip as authoritative,
/// so a lost meta write silently rolled back on the next boot.
final class RecoveryLifecycleTests: XCTestCase {

    // MARK: - inherited (parent-securing) weight is restored identically across restart

    /// F5-4 fork choice is `effectiveWeight = subtreeWeight + inheritedWeight`, so a
    /// child chain that restarts with its inherited (parent-securing) weight zeroed
    /// could flip to a fork the pre-restart node correctly rejected (a self-reorg).
    /// `restoreInheritedWeight` (driven by `start()`) must replay the persisted
    /// `block_proofs` into the InheritedWeightStore so the per-child inherited weight
    /// — and therefore fork choice — is provably identical across a restart.
    ///
    /// We seed a REAL, deserializable `ChildBlockProof` (the same artifact the live
    /// ingestion path persists via `persistBlockProof`) into a deployed child's
    /// StateStore, record the per-child inherited weight BEFORE restart through the
    /// existing `InheritedWeightStore` read API, restart on the same storage, and
    /// assert the restored per-child weight equals the pre-restart value.
    func testInheritedWeightRestoredIdenticallyAcrossRestart() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let genesis = testGenesis(spec: testSpec(), directory: "Mid")
        let storagePath = tmpDir.appendingPathComponent("node1")
        let ts = now() - 100_000

        // --- First run: boot the Mid chain itself and persist a real securing
        // proof for a child block, exactly as live ingestion
        // (persistAcceptedBlockProof) would. The parent node never owns a Mid
        // ChainState; inherited-weight recovery is child-local.
        let p1 = nextTestPort()
        let config1 = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: p1, storagePath: storagePath,
            enableLocalDiscovery: false, persistInterval: 10_000, minPeerKeyBits: 0
        )
        let node1 = try await LatticeNode(config: config1, genesisConfig: genesis)
        try await node1.start()

        let f = cas()
        let midGenesis = await node1.genesisResult.block

        // A real mined Mid block embedded in a real Nexus block yields an intrinsic,
        // non-zero securing-work proof (the caller supplies no weight).
        let midBlock = try await BlockBuilder.buildBlock(
            previous: midGenesis, timestamp: ts + 1000, target: UInt256.max, nonce: 0, fetcher: f)
        let midCID = try VolumeImpl<Block>(node: midBlock).rawCID
        await f.store(rawCid: midCID, data: midBlock.toData()!)

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: testSpec("Nexus"), timestamp: ts, target: UInt256.max, fetcher: f)
        let nexusBlock = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, children: ["Mid": midBlock],
            timestamp: ts + 1000, target: UInt256.max, nonce: 1, fetcher: f)
        let nexusHeader = try VolumeImpl<Block>(node: nexusBlock)
        await f.store(rawCid: nexusHeader.rawCID, data: nexusBlock.toData()!)
        let storer = CollectingProofStorer()
        try nexusHeader.storeRecursively(storer: storer)
        for (cid, data) in storer.entries { await f.store(rawCid: cid, data: data) }

        let proof = try await ChildBlockProof.generate(
            rootHeader: nexusHeader, childDirectory: "Mid", fetcher: f)
        let securingWork = await proof.securingWork()
        XCTAssertGreaterThan(securingWork, .zero, "a valid proof must credit positive securing work")

        // Persist the proof keyed by the child block CID — the same row
        // persistAcceptedBlockProof writes; restoreInheritedWeight replays it as a
        // verified parent-work delta committing that child.
        let midStore = await node1.stateStore(for: "Mid")!
        try await midStore.persistBlockProof(
            height: midBlock.height, blockHash: midCID, proofID: proof.proofPathID, proof: proof.serialize())

        // Record the per-child inherited weight BEFORE restart via the existing read
        // API (restoreInheritedWeight is the exact call start() makes on each chain).
        await node1.restoreInheritedWeight(directory: "Mid")
        let preRestartWeight = await node1.ensureInheritedWeightStore(directory: "Mid")
            .inheritedWeight(forChild: midCID)
        XCTAssertEqual(preRestartWeight, securingWork,
                       "pre-restart inherited weight must equal the proof's securing work")
        await node1.stop()

        // --- Restart on the same storage. start() runs restoreInheritedWeight for
        // every restored chain before projecting fork choice.
        let p2 = nextTestPort()
        let config2 = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: p2, storagePath: storagePath,
            enableLocalDiscovery: false, persistInterval: 10_000, minPeerKeyBits: 0
        )
        let node2 = try await LatticeNode(config: config2, genesisConfig: genesis)
        await node2.restoreDeployedChildChains()
        try await node2.start()

        let postRestartWeight = await node2.ensureInheritedWeightStore(directory: "Mid")
            .inheritedWeight(forChild: midCID)
        XCTAssertEqual(postRestartWeight, preRestartWeight,
                       "restored per-child inherited weight must match pre-restart (fork choice identical across restart)")
        XCTAssertGreaterThan(postRestartWeight, .zero,
                             "inherited weight must NOT reset to zero on restart")

        // The store carrying the value is necessary but NOT sufficient: fork choice
        // reads the inherited term through ChainState's provider, which is the
        // LiveInheritedWeightIndex (chain.setInheritedWeightProvider(index.makeProvider())).
        // After restart there is no live parent projection, so unless `restore`
        // installs the durable floor into the index the provider returns .zero and
        // fork choice silently drops the restored child's inherited work — a
        // self-reorg the store-only assertion above would NOT catch. Assert the
        // provider path, not just the store, reports the restored weight.
        let postRestartProviderWeight = await node2.ensureLiveInheritedWeightIndex(directory: "Mid")
            .inheritedWeight(forChild: midCID)
        XCTAssertEqual(postRestartProviderWeight, preRestartWeight,
                       "fork-choice provider (live index + durable floor) must report restored inherited weight after restart, with no live parent projection")
        await node2.stop()
    }

    /// H1 guard (per-grind consensus fix): an in-place upgrade must NOT replay stale
    /// PER-LEVEL inherited-work rows that predate the per-grind crediting rule.
    /// `restoreInheritedWeight` rebuilds from the PROOF (source of truth, per-grind MAX)
    /// for any child that has one, and uses the persisted contribution rows only as a
    /// fallback for a proof-less child. Persist an inflated stale-row set AND a real proof
    /// for the SAME child, restore, and assert the proof value wins — not the stale sum.
    func testRestorePrefersProofOverStalePerLevelContributions() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let genesis = testGenesis(spec: testSpec(), directory: "Mid")
        let storagePath = tmpDir.appendingPathComponent("node1")
        let ts = now() - 100_000

        let p1 = nextTestPort()
        let config1 = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: p1, storagePath: storagePath,
            enableLocalDiscovery: false, persistInterval: 10_000, minPeerKeyBits: 0)
        let node1 = try await LatticeNode(config: config1, genesisConfig: genesis)
        try await node1.start()

        let f = cas()
        let midGenesis = await node1.genesisResult.block
        let midBlock = try await BlockBuilder.buildBlock(
            previous: midGenesis, timestamp: ts + 1000, target: UInt256.max, nonce: 0, fetcher: f)
        let midCID = try VolumeImpl<Block>(node: midBlock).rawCID
        await f.store(rawCid: midCID, data: midBlock.toData()!)

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: testSpec("Nexus"), timestamp: ts, target: UInt256.max, fetcher: f)
        let nexusBlock = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, children: ["Mid": midBlock],
            timestamp: ts + 1000, target: UInt256.max, nonce: 1, fetcher: f)
        let nexusHeader = try VolumeImpl<Block>(node: nexusBlock)
        await f.store(rawCid: nexusHeader.rawCID, data: nexusBlock.toData()!)
        let storer = CollectingProofStorer()
        try nexusHeader.storeRecursively(storer: storer)
        for (cid, data) in storer.entries { await f.store(rawCid: cid, data: data) }

        let proof = try await ChildBlockProof.generate(
            rootHeader: nexusHeader, childDirectory: "Mid", fetcher: f)
        let proofWork = await proof.securingWork()
        XCTAssertGreaterThan(proofWork, .zero)

        let midStore = await node1.stateStore(for: "Mid")!
        try await midStore.persistBlockProof(
            height: midBlock.height, blockHash: midCID, proofID: proof.proofPathID, proof: proof.serialize())

        // Simulate a PRE-FIX in-place upgrade: stale per-level rows for the SAME child with
        // distinct contributor ids (old per-level crediting), disjoint from the proof's
        // per-grind (rootCID) contribution and summing to an inflated 3x.
        try await midStore.persistInheritedWorkContributions(
            height: midBlock.height, blockHash: midCID,
            contributions: [(id: "stale-level-A", work: proofWork),
                            (id: "stale-level-B", work: proofWork),
                            (id: "stale-level-C", work: proofWork)])
        let staleRows = midStore.getAllInheritedWorkContributions().filter { $0.blockHash == midCID }
        XCTAssertEqual(staleRows.count, 3, "stale per-level rows must persist, else the test is vacuous")

        await node1.restoreInheritedWeight(directory: "Mid")
        let restored = await node1.ensureInheritedWeightStore(directory: "Mid").inheritedWeight(forChild: midCID)
        XCTAssertEqual(restored, proofWork,
                       "restore must credit the PROOF's per-grind work, NOT replay the stale inflated per-level rows")
        await node1.stop()
    }

    // MARK: - Residual 1

    /// Restored deploy metadata must stay metadata-only. The parent advertises
    /// deployed child availability, but the child ChainState lives in its own node
    /// process and is not reconstructed inside the parent on restart.
    func testRestoredChildDeployMetadataDoesNotCreateParentSideChildState() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let genesis = testGenesis(spec: testSpec(), directory: "Nexus")
        let storagePath = tmpDir.appendingPathComponent("node1")

        // --- First run: deploy a Child so its genesis is written to CAS and its
        // deployment metadata is persisted. The parent advertises availability,
        // but must not create a local child ChainState/StateStore/fork-choice view.
        let p1 = nextTestPort()
        let config1 = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: p1, storagePath: storagePath,
            enableLocalDiscovery: false, persistInterval: 10_000, minPeerKeyBits: 0
        )
        let node1 = try await LatticeNode(config: config1, genesisConfig: genesis)
        try await node1.start()

        let nexusNet = await node1.network(for: "Nexus")!
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: testSpec("Child"),
            transactions: [],
            timestamp: now() - 10_000,
            target: UInt256.max,
            fetcher: nexusNet.ivyFetcher
        )
        try await node1.deployChildChain(
            directory: "Child",
            parentDirectory: "Nexus",
            genesisBlock: childGenesis,
            bootstrapEntries: []
        )
        let childGenesisCID = try VolumeImpl<Block>(node: childGenesis).rawCID
        let deployedNetwork = await node1.network(for: "Child")
        let deployedChain = await node1.chain(for: "Child")
        let deployedStore = await node1.stateStore(for: "Child")
        let deployed = await node1.deployedChildChains["Nexus/Child"]
        XCTAssertNil(deployedNetwork, "parent deploy must not create a local child network")
        XCTAssertNil(deployedChain, "parent deploy must not create a local child ChainState")
        XCTAssertNil(deployedStore, "parent deploy must not create a local child StateStore")
        XCTAssertEqual(deployed?.genesisHash, childGenesisCID)
        await node1.stop()

        // --- Second run: restore on the same storage. restoreDeployedChildChains() restores
        // deploy metadata only; the parent still must not instantiate a child view
        // before or after start().
        let p2 = nextTestPort()
        let config2 = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: p2, storagePath: storagePath,
            enableLocalDiscovery: false, persistInterval: 10_000, minPeerKeyBits: 0
        )
        let node2 = try await LatticeNode(config: config2, genesisConfig: genesis)
        await node2.restoreDeployedChildChains()

        let restoredNetwork = await node2.network(for: "Child")
        let restoredMetadata = await node2.deployedChildChains["Nexus/Child"]
        XCTAssertNil(restoredNetwork, "restoring child deploy metadata must not create a local child network")
        XCTAssertEqual(restoredMetadata?.genesisHash, childGenesisCID)

        // --- Recovery: start() recovers the parent only. A separate child process
        // owns the child ChainState and validates any mined child blocks it receives.
        try await node2.start()

        let startedNetwork = await node2.network(for: "Child")
        let startedChain = await node2.chain(for: "Child")
        let startedStore = await node2.stateStore(for: "Child")
        XCTAssertNil(startedNetwork, "parent start must not create a local child network")
        XCTAssertNil(startedChain, "parent start must not create a local child ChainState")
        XCTAssertNil(startedStore, "parent start must not create a local child StateStore")

        await node2.stop()
    }

    // MARK: - Residual 2

    /// A failed `chain_tip:<key>` meta write must surface — not be swallowed by a
    /// `try?` — and must NOT let `blocksSinceLastPersist` reset to 0, so the durable
    /// meta tip and chain_state.json cannot diverge silently.
    func testPersistChainStateSurfacesFailedMetaWrite() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let genesis = testGenesis(spec: testSpec(), directory: "Nexus")
        let storagePath = tmpDir.appendingPathComponent("node1")

        let p1 = nextTestPort()
        let config1 = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: p1, storagePath: storagePath,
            enableLocalDiscovery: false, persistInterval: 10_000, minPeerKeyBits: 0
        )
        let node1 = try await LatticeNode(config: config1, genesisConfig: genesis)
        try await node1.start()

        // Establish a durable baseline tip via a clean persist (meta write OK).
        try await mineBlocks(1, on: node1)
        await node1.persistChainState(directory: "Nexus")
        let baselineMetaTip = await node1.sharedDiskBroker.getChainMeta(key: "chain_tip:Nexus")
        XCTAssertNotNil(baselineMetaTip)

        // Advance the tip, then force the meta write to fail via the test seam.
        try await mineBlocks(2, on: node1)
        let advancedTip = await node1.chain(for: "Nexus")!.getMainChainTip()
        XCTAssertNotEqual(advancedTip, baselineMetaTip, "tip must have advanced past the baseline")

        struct MetaWriteFailure: Error {}
        await node1.installSetChainMetaHookForTests { _, _ in throw MetaWriteFailure() }
        // Reset the persist counter so we can prove the failed write leaves it unreset.
        await node1.setBlocksSinceLastPersistForTests(key: "Nexus", value: 7)

        await node1.persistChainState(directory: "Nexus")

        // Failure is observable: the chain is marked unhealthy AND the persist
        // counter was NOT reset to 0 (so the next block retries the meta write).
        let unavailable = await node1.isChainUnavailable(directory: "Nexus")
        XCTAssertTrue(unavailable, "a failed chain_tip meta write must fail closed (chain unhealthy)")
        let health = await node1.chainHealth["Nexus"]
        guard case .degraded(let reason, _, .committedTipFrontier)? = health else {
            XCTFail("failed chain_tip meta write must be recoverable degraded health, got \(String(describing: health))")
            await node1.stop()
            return
        }
        XCTAssertEqual(reason, "failed to write chain_tip meta")
        let counterAfter = await node1.blocksSinceLastPersistForTests(key: "Nexus")
        XCTAssertNotEqual(counterAfter, 0, "blocksSinceLastPersist must NOT reset when the meta write failed")

        // The durable meta tip must still be the pre-update value (the failed write
        // did not advance it).
        let metaAfterFailure = await node1.sharedDiskBroker.getChainMeta(key: "chain_tip:Nexus")
        XCTAssertEqual(metaAfterFailure, baselineMetaTip,
                       "a failed meta write must not advance the durable meta tip")

        await node1.stop()
    }

    /// Restart invariant the reviewer asked for: after a periodic `chain_tip` meta
    /// write FAILS — leaving the DiskBroker meta tip / chain_state.json LAGGING the
    /// canonical tip the node already committed — a restart must NEVER retain or
    /// advertise a tip below what was durably committed. The canonical commit point
    /// is the StateStore (`state.db`) `meta:chain-tip`, written atomically with
    /// `block_index` inside `applyBlock`/`commitCanonicalSegment` BEFORE any gossip
    /// tip announce. `recoverFromCAS` re-derives ChainState forward from that
    /// authoritative committed tip on boot, so the lagging meta cache is corrected
    /// and no un-backed (or rolled-back) tip survives the restart as trusted.
    func testRestartReDerivesPastFailedMetaWriteToCommittedTip() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let genesis = testGenesis(spec: testSpec(), directory: "Nexus")
        let storagePath = tmpDir.appendingPathComponent("node1")

        // --- First run: establish a durable baseline, then advance the committed
        // tip while forcing the periodic chain_tip meta write to fail.
        let p1 = nextTestPort()
        let config1 = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: p1, storagePath: storagePath,
            enableLocalDiscovery: false, persistInterval: 10_000, minPeerKeyBits: 0
        )
        let node1 = try await LatticeNode(config: config1, genesisConfig: genesis)
        try await node1.start()

        // Baseline: a clean persist (meta write OK) writes the lagging cache tip.
        try await mineBlocks(1, on: node1)
        await node1.persistChainState(directory: "Nexus")
        let laggingMetaTip = await node1.sharedDiskBroker.getChainMeta(key: "chain_tip:Nexus")
        XCTAssertNotNil(laggingMetaTip)

        // Advance the canonical tip further. Each mined block commits the new tip to
        // state.db atomically (applyBlock) and only then announces it — so these
        // blocks are durably committed regardless of the chain_tip cache.
        try await mineBlocks(2, on: node1)
        let committedTip = await node1.stateStore(for: "Nexus")!.getChainTip()
        XCTAssertNotEqual(committedTip, laggingMetaTip,
                          "committed state.db tip must have advanced past the baseline cache tip")

        // Force the periodic chain_tip meta write to fail, then persist. The
        // DiskBroker meta tip / chain_state.json stay at the lagging baseline; the
        // committed state.db tip is unaffected (separate SQLite file).
        struct MetaWriteFailure: Error {}
        await node1.installSetChainMetaHookForTests { _, _ in throw MetaWriteFailure() }
        await node1.persistChainState(directory: "Nexus")
        let metaAfterFailedPersist = await node1.sharedDiskBroker.getChainMeta(key: "chain_tip:Nexus")
        XCTAssertEqual(metaAfterFailedPersist, laggingMetaTip,
                       "failed meta write must leave the cache tip lagging the committed tip")
        await node1.stop()

        // --- Restart on the same storage. Boot loads ChainState from the lagging
        // chain_tip cache, then recoverFromCAS projects it forward from the
        // authoritative committed state.db tip.
        let p2 = nextTestPort()
        let config2 = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: p2, storagePath: storagePath,
            enableLocalDiscovery: false, persistInterval: 10_000, minPeerKeyBits: 0
        )
        let node2 = try await LatticeNode(config: config2, genesisConfig: genesis)
        try await node2.start()

        let recoveredTip = await node2.chain(for: "Nexus")!.getMainChainTip()
        let recoveredCommittedTip = await node2.stateStore(for: "Nexus")!.getChainTip()
        // The committed tip is preserved across restart (state.db is crash-safe and
        // independent of the failed chain_tip cache write).
        XCTAssertEqual(recoveredCommittedTip, committedTip,
                       "committed state.db tip must survive the restart unchanged")
        // The live in-memory tip the node retains/advertises after recovery must be
        // the committed tip — NOT the stale lagging cache tip. This is the invariant:
        // the node never retains a tip below (or rolled back from) what it committed.
        XCTAssertEqual(recoveredTip, committedTip,
                       "recovered in-memory tip must re-derive forward to the committed tip, not the stale meta cache")
        XCTAssertNotEqual(recoveredTip, laggingMetaTip,
                          "recovered tip must NOT roll back to the lagging meta cache tip")

        await node2.stop()
    }
}

/// Collects a block header's inline sub-node tree so a real ChildBlockProof can be
/// generated from locally-staged entries.
/// Collects entries on whatever thread `storeRecursively` runs on (synchronously,
/// from the single test task), then exposes them as an immutable snapshot once the
/// recursive walk returns. A `Mutex` makes the type genuinely `Sendable` — no
/// `@unchecked` escape — so it satisfies the strict-concurrency gate while the
/// `Storer` requirement (a non-`Sendable`, non-isolated `throws` method) is met.
private final class CollectingProofStorer: Storer, Sendable {
    private let collected = Mutex<[(String, Data)]>([])

    var entries: [(String, Data)] { collected.withLock { $0 } }

    func store(rawCid: String, data: Data) throws {
        collected.withLock { $0.append((rawCid, data)) }
    }
}
