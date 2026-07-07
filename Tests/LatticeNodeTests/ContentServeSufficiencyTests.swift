import XCTest
@testable import LatticeNode
@testable import Lattice
import Ivy
import cashew
import VolumeBroker
import UInt256
import Foundation
#if canImport(os)
import os
#endif

/// Reproduction harness for the toy cold-sync stall: a follower fetches a block's
/// content by fetching WHOLE VOLUME GROUPINGS by root (the real `volumeData` serve
/// gate — a CID is served iff it has its own `volume_entries` grouping AND is
/// pin-reachable; an internal in-package node is refused by-root and delivered ONLY
/// inside its owning grouping). The flat `TestVolumeFetcher` in Lattice serves any
/// CID and therefore CANNOT catch a "needed node lives in no served grouping" gap;
/// this fetcher faithfully models by-root serving so such a gap surfaces as notFound.
/// Faithful model of the real follower's `IvyFetcher.fetchWave` over by-root serving
/// (`volumeData`): a wave of CIDs is served from the local cache first; each miss is
/// treated as a Volume BOUNDARY ROOT and fetched as a whole grouping by root (only if
/// pin-reachable AND it has its own grouping). An internal in-package node with no own
/// grouping that is NOT already cached is unrecoverable — exactly the real behavior.
final class ByRootContentSource: ContentSource, @unchecked Sendable {
    private let source: DiskBroker
    private let state = OSAllocatedUnfairLock(initialState: [String: Data]())
    private let auditLock = OSAllocatedUnfairLock(initialState: [String]())

    init(source: DiskBroker) { self.source = source }

    /// Pre-load a whole grouping by root (models the prefetch / an already-fetched bundle).
    func preload(root: String) async {
        if let vol = await source.fetchVolumeLocal(root: root) {
            state.withLock { s in for (k, v) in vol.entries { s[k] = v } }
        }
    }

    func fetch(_ cids: Set<String>) async -> [String: Data] {
        var out: [String: Data] = [:]
        var missing: Set<String> = []
        for cid in cids where !cid.isEmpty {
            if let d = state.withLock({ $0[cid] }) { out[cid] = d } else { missing.insert(cid) }
        }
        for root in missing {
            auditLock.withLock { $0.append(root) }
            if await source.isPinReachable(cid: root),
               let vol = await source.fetchVolumeLocal(root: root), !vol.entries.isEmpty {
                state.withLock { s in for (k, v) in vol.entries { s[k] = v } }
            }
        }
        for root in missing {
            if let d = state.withLock({ $0[root] }) { out[root] = d }
        }
        return out
    }

    var attemptedByRoot: [String] { auditLock.withLock { $0 } }
}

/// Grain-independent local source: reads any node from cas_data by CID (what the
/// recovery's `recoverySource` does over the node's own store).
struct GrainIndependentSource: ContentSource {
    let disk: DiskBroker
    func fetch(_ cids: Set<String>) async -> [String: Data] {
        var out: [String: Data] = [:]
        for cid in cids where !cid.isEmpty {
            if let d = await disk.fetchData(cid: cid) { out[cid] = d }
        }
        return out
    }
}

final class ContentServeSufficiencyTests: XCTestCase {

    private func tempDisk() throws -> DiskBroker {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return try DiskBroker(path: dir.appendingPathComponent("volumes.sqlite").path)
    }

    private func makeNetwork(disk: DiskBroker) async throws -> ChainNetwork {
        let kp = CryptoUtils.generateKeyPair()
        return try await ChainNetwork(
            chainPath: ["Nexus"],
            config: IvyConfig(
                publicKey: kp.publicKey, listenPort: 0, bootstrapPeers: [],
                enableLocalDiscovery: false, stunServers: []
            ),
            sharedDiskBroker: disk
        )
    }

    private func buildGenesisWithTxs(_ n: Int, fetcher: Fetcher) async throws -> Block {
        var txs: [Transaction] = []
        for i in 0..<n {
            let owner = "owner-\(i)"
            let body = TransactionBody(
                accountActions: [AccountAction(owner: owner, delta: Int64(1000 + i))],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [owner], fee: 0, nonce: 0
            )
            txs.append(Transaction(signatures: [owner: "genesis"], body: try HeaderImpl(node: body)))
        }
        return try await BlockBuilder.buildGenesis(
            spec: testSpec(), transactions: txs,
            timestamp: now() - 10_000, target: UInt256.max, fetcher: fetcher
        )
    }

    /// ROOT-CAUSE VALIDATION: the July-5 recovery `reconstructBlockVolumes` uses a
    /// SHALLOW resolve (`stub.resolve(source:)` = block node only), then `storeBlockData`.
    /// storeRecursively skips the unhydrated transactions boundary, so the recovered
    /// block gets a bare root volume with NO tx-value grouping → the tx BODIES are
    /// stranded. `resolveBlockContent` (deep — spec/transactions/children) is the fix.
    func testShallowRecoveryDropsTransactionBodies() async throws {
        let disk = try tempDisk()
        let network = try await makeNetwork(disk: disk)
        let fetcher = cas()
        let block = try await buildGenesisWithTxs(1, fetcher: fetcher)
        let blockHash = try VolumeImpl<Block>(node: block).rawCID
        // Full, correct store (as the miner/creator does) — complete closure present.
        let storer0 = BrokerStorer(broker: disk)
        try VolumeImpl<Block>(node: block).storeRecursively(storer: storer0)
        try await network.storeVolumesDurably(storer0.collectVolumes(root: blockHash))
        let txValueRoot = try XCTUnwrap(block.transactions.node?.allKeysAndValues().values.first?.rawCID)
        let preTxGrouping = await disk.fetchVolumeLocal(root: txValueRoot)
        XCTAssertNotNil(preTxGrouping, "precondition: full store has the tx-value grouping")

        // The recovery reads its OWN local store grain-independently (cas_data has every
        // node), so use a grain-independent source to isolate RESOLVE DEPTH, not serving.
        let source = GrainIndependentSource(disk: disk)
        let stub = VolumeImpl<Block>(rawCID: blockHash, node: nil, encryptionInfo: nil)

        // (1) SHALLOW recovery — exactly what reconstructBlockVolumes does today.
        let shallowResolved = try await stub.resolve(source: source).node
        let shallow = try XCTUnwrap(shallowResolved)
        XCTAssertNil(shallow.transactions.node, "shallow resolve leaves transactions UNHYDRATED")
        let recDisk = try tempDisk()
        let recNet = try await makeNetwork(disk: recDisk)
        let s1 = BrokerStorer(broker: recDisk)
        try VolumeImpl<Block>(node: shallow).storeRecursively(storer: s1)
        try await recNet.storeVolumesDurably(s1.collectVolumes(root: blockHash))
        let shallowHasTxGrouping = (await recDisk.fetchVolumeLocal(root: txValueRoot)) != nil
        print("[RECOVERY] SHALLOW resolve → tx-value grouping present on recovered node: \(shallowHasTxGrouping)")
        XCTAssertFalse(shallowHasTxGrouping,
            "BUG CONFIRMED: shallow-resolve recovery dropped the tx-value grouping — the tx body is stranded")

        // (2) FIX — resolveBlockContent (deep) hydrates transactions, so the closure is rebuilt.
        let contentResolved = try await stub.resolveBlockContent(source: source).node
        let content = try XCTUnwrap(contentResolved)
        XCTAssertNotNil(content.transactions.node, "resolveBlockContent hydrates transactions")
        let fixDisk = try tempDisk()
        let fixNet = try await makeNetwork(disk: fixDisk)
        let s2 = BrokerStorer(broker: fixDisk)
        try VolumeImpl<Block>(node: content).storeRecursively(storer: s2)
        try await fixNet.storeVolumesDurably(s2.collectVolumes(root: blockHash))
        let fixHasTxGrouping = (await fixDisk.fetchVolumeLocal(root: txValueRoot)) != nil
        print("[RECOVERY] resolveBlockContent → tx-value grouping present on recovered node: \(fixHasTxGrouping)")
        XCTAssertTrue(fixHasTxGrouping,
            "FIX CONFIRMED: resolveBlockContent recovery preserves the tx-value grouping (body servable)")
    }

    /// REVIEWER P1: the recovery skip must gate on PIN-REACHABILITY (the actual P2P serve
    /// predicate in `volumeData`), not durable existence. A run that stored the volumes but
    /// crashed / had `pinBatchDurably` fail before pinning leaves them durable-but-unpinned:
    /// `hasDurableVolume` == true yet `isPinReachable` == false, so the serve gate refuses
    /// them. This locks in that the two predicates diverge exactly in that window, and that
    /// pinning every served root closes it.
    func testDurableButUnpinnedIsNotServable() async throws {
        let disk = try tempDisk()
        let network = try await makeNetwork(disk: disk)
        let block = try await buildGenesisWithTxs(1, fetcher: cas())
        let blockHash = try VolumeImpl<Block>(node: block).rawCID

        // Store durably but DO NOT pin — models a crash/failure between store and pin.
        let storer = BrokerStorer(broker: disk)
        try VolumeImpl<Block>(node: block).storeRecursively(storer: storer)
        let volumes = storer.collectVolumes(root: blockHash)   // also populates storer.storedRoots
        try await network.storeVolumesDurably(volumes)

        let durable = await network.hasDurableVolume(rootCID: blockHash)
        let reachableBefore = await disk.isPinReachable(cid: blockHash)
        XCTAssertTrue(durable, "volume is durably stored")
        XCTAssertFalse(reachableBefore,
            "durable but NOT pin-reachable — the serve gate refuses it, so a hasDurableVolume skip is wrong")

        // Pinning every served root makes the whole closure servable.
        try await network.pinBatchDurably(roots: storer.storedRoots, owner: "Nexus:0")
        for r in storer.storedRoots {
            let ok = await disk.isPinReachable(cid: r)
            XCTAssertTrue(ok, "served root not pin-reachable after pin: \(r)")
        }
    }

    /// REVIEWER P1 (round 2): pin-reachability ALONE is not the serve predicate. A tx-value
    /// root can be pin-reachable purely because it is an entry inside a pinned block bundle,
    /// while its OWN grouping is missing — the serve gate then still refuses it
    /// (`fetchVolumeLocal(root:)` is empty). So the recovery skip must use the full predicate
    /// (`servableRootPayload`): pin-reachable AND non-empty own grouping.
    func testPinReachableEntryWithoutOwnGroupingIsNotServable() async throws {
        let disk = try tempDisk()
        let network = try await makeNetwork(disk: disk)
        let block = try await buildGenesisWithTxs(1, fetcher: cas())
        let blockHash = try VolumeImpl<Block>(node: block).rawCID
        let txValueRoot = try XCTUnwrap(block.transactions.node?.allKeysAndValues().values.first?.rawCID)

        // Store ONLY the block-root grouping (which carries the tx-value bare root as an
        // entry/edge), NOT the tx-value's own grouping — the exact shallow-recovery residue.
        let storer = BrokerStorer(broker: disk)
        try VolumeImpl<Block>(node: block).storeRecursively(storer: storer)
        let blockBundleOnly = storer.collectVolumes(root: blockHash).filter { $0.root == blockHash }
        try await network.storeVolumesDurably(blockBundleOnly)
        try await network.pinBatchDurably(roots: [blockHash], owner: "Nexus:0")

        // The tx-value root IS pin-reachable (entry of the pinned block bundle)...
        let txReachable = await disk.isPinReachable(cid: txValueRoot)
        XCTAssertTrue(txReachable, "tx-value root is pin-reachable via the block-bundle edge")
        // ...but it has NO own grouping, so the serve gate refuses it and the skip must too.
        let payload = await network.servableRootPayload(for: txValueRoot)
        XCTAssertNil(payload,
            "pin-reachable but no own grouping → NOT servable; an isPinReachable-only skip would wrongly skip it")
        // And the block root itself IS servable (own grouping present + pinned).
        let blockPayload = await network.servableRootPayload(for: blockHash)
        XCTAssertNotNil(blockPayload, "block root is servable (own grouping + pinned)")
    }

    /// INVARIANT: a block stored via the real node closure path and pinned at its
    /// root must be fully CONTENT-resolvable by a follower that can only fetch whole
    /// groupings by root. If this fails, the served block bundle is missing a node
    /// that content resolution needs — the exact cold-sync stall.
    func testFullyStoredBlockServedByRootResolvesContent() async throws {
        let txCount = 1
        let disk = try tempDisk()
        let network = try await makeNetwork(disk: disk)
        let fetcher = cas()
        let block = try await buildGenesisWithTxs(txCount, fetcher: fetcher)
        let blockHash = try VolumeImpl<Block>(node: block).rawCID

        // Real node store path (collectBlockVolumes) → durable → pin the block root.
        let storer = BrokerStorer(broker: disk)
        try VolumeImpl<Block>(node: block).storeRecursively(storer: storer)
        let volumes = storer.collectVolumes(root: blockHash)
        try await network.storeVolumesDurably(volumes)
        try await network.pinBatchDurably(roots: [blockHash], owner: "Nexus:0")

        print("[SERVE] blockHash=\(blockHash)")
        print("[SERVE] storer.storedRoots (\(storer.storedRoots.count)): \(storer.storedRoots)")
        if let g = await disk.fetchVolumeLocal(root: blockHash) {
            print("[SERVE] block grouping entries (\(g.entries.count)): \(Array(g.entries.keys))")
        }
        // What does resolveBlockContent commit-reference? spec/transactions/children CIDs:
        print("[SERVE] block.spec.rawCID=\(block.spec.rawCID)")
        print("[SERVE] block.transactions.rawCID=\(block.transactions.rawCID)")
        print("[SERVE] block.children.rawCID=\(block.children.rawCID)")
        // From the HYDRATED block object, print the tx-value + tx-body CIDs so we can
        // identify what the faulting CID actually is.
        if let txDict = block.transactions.node {
            let kv = try txDict.allKeysAndValues()
            for (k, txHeader) in kv {
                print("[SERVE] hydrated tx[\(k)] value.rawCID=\(txHeader.rawCID) body.rawCID=\(txHeader.node?.body.rawCID ?? "nil")")
            }
        }

        // The block bundle serves the tx-value BARE ROOT inline (BrokerStorer.exitVolume
        // copies the child root up for the reachability edge), but the tx BODY lives ONLY
        // in the tx-value's own grouping. So a follower that fetches only the block bundle
        // resolves the tx-value root locally, never fetches its grouping, and faults on the
        // body. This is exactly what makes the shallow-recovery damage invisible — the block
        // bundle "looks" complete. prefetchBlockContentClosure avoids the stall by fetching
        // each tx-value grouping; this locks in both the fragility and its fix.
        let txValueRoot = try XCTUnwrap(block.transactions.node?.allKeysAndValues().values.first?.rawCID)

        // (1) Bundle-only → faults (bare-root shadow of the tx-value).
        let bundleOnly = ByRootContentSource(source: disk)
        await bundleOnly.preload(root: blockHash)
        let h1 = VolumeImpl<Block>(rawCID: blockHash, node: nil, encryptionInfo: nil)
        var faulted = false
        do { _ = try await h1.resolveBlockContent(source: bundleOnly) } catch { faulted = true }
        XCTAssertTrue(faulted, "block bundle alone must be insufficient: the tx body is only in the tx-value grouping")

        // (2) Fetch the tx-value grouping (what prefetch does) → resolves, body present.
        let withGrouping = ByRootContentSource(source: disk)
        await withGrouping.preload(root: blockHash)
        await withGrouping.preload(root: txValueRoot)
        let h2 = VolumeImpl<Block>(rawCID: blockHash, node: nil, encryptionInfo: nil)
        let resolved = try await h2.resolveBlockContent(source: withGrouping)
        let body = try resolved.node?.transactions.node?.allKeysAndValues().values.first?.node?.body.node
        XCTAssertNotNil(body, "fetching the tx-value grouping resolves the tx body")
    }
}
