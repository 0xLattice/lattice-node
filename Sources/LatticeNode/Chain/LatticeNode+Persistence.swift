import Lattice
import Foundation
import cashew
import Ivy
import VolumeBroker
import UInt256

private final class DiskBrokerFetcher: Fetcher, @unchecked Sendable {
    private let diskBroker: DiskBroker

    init(diskBroker: DiskBroker) {
        self.diskBroker = diskBroker
    }

    func fetch(rawCid: String) async throws -> Data {
        // Content-by-CID: resolve any stored node — boundary roots AND in-package
        // internal trie/dictionary nodes — directly from cas_data. A root-keyed
        // fetchVolumeLocal(root: rawCid) misses internal nodes (which are NON-root
        // entries of their boundary volume), so startup tip-frontier resolution
        // would falsely judge a healthy persisted chain unusable and resync from
        // genesis on every restart.
        guard let data = await diskBroker.fetchData(cid: rawCid) else {
            throw DiskBrokerFetchError.notFound
        }
        return data
    }
}

private enum DiskBrokerFetchError: Error {
    case notFound
}

private final class StaticEntryStorer: Storer, @unchecked Sendable {
    private var entries: [String: Data] = [:]

    func store(rawCid: String, data: Data) throws {
        entries[rawCid] = data
    }

    func snapshot() -> [String: Data] {
        entries
    }
}

extension LatticeNode {

    // MARK: - DiskBroker-based chain state rebuild

    /// Rebuild PersistedChainState by walking backwards through DiskBroker from
    /// a known tip CID. Used when chain_state.json is stale or absent but the
    /// DiskBroker meta tip is set — both live in the same SQLite file so they
    /// are always mutually consistent.
    static func rebuildChainState(
        tipCID: String,
        diskBroker: DiskBroker,
        retentionDepth: UInt64
    ) async -> PersistedChainState? {
        let source = FetcherContentSource(DiskBrokerFetcher(diskBroker: diskBroker))
        return await rebuildChainState(tipCID: tipCID, source: source, retentionDepth: retentionDepth)
    }

    static func rebuildChainState(
        tipCID: String,
        source: any ContentSource,
        retentionDepth: UInt64
    ) async -> PersistedChainState? {
        var loaded: [(cid: String, block: Block)] = []
        var tipBlock: Block? = nil
        var currentCID = tipCID

        for _ in 0...retentionDepth {
            let stub = VolumeImpl<Block>(rawCID: currentCID, node: nil, encryptionInfo: nil)
            guard let block = try? await stub.resolve(source: source).node else { break }

            if tipBlock == nil { tipBlock = block }
            loaded.append((cid: currentCID, block: block))

            guard let parentCID = block.parent?.rawCID, !parentCID.isEmpty else { break }
            currentCID = parentCID
        }

        guard let tip = tipBlock else { return nil }
        loaded.reverse()
        var childHashesByParent: [String: [String]] = [:]
        for entry in loaded {
            if let parentCID = entry.block.parent?.rawCID, !parentCID.isEmpty {
                childHashesByParent[parentCID, default: []].append(entry.cid)
            }
        }
        let blocks = loaded.map { entry in
            PersistedBlockMeta(
                blockHash: entry.cid,
                parentBlockHash: entry.block.parent?.rawCID,
                blockHeight: entry.block.height,
                parentChainBlocks: [:],
                childHashes: childHashesByParent[entry.cid] ?? [],
                target: entry.block.target.toHexString(),
                timestamp: entry.block.timestamp
            )
        }
        let mainChainHashes = loaded.map(\.cid)

        return PersistedChainState(
            chainTip: tipCID,
            tipPostStateCID: tip.postState.rawCID.isEmpty ? nil : tip.postState.rawCID,
            tipPrevStateCID: tip.prevState.rawCID.isEmpty ? nil : tip.prevState.rawCID,
            tipSpecCID: tip.spec.rawCID.isEmpty ? nil : tip.spec.rawCID,
            tipTarget: tip.target.toHexString(),
            tipNextTarget: tip.nextTarget.toHexString(),
            tipHeight: tip.height,
            tipTimestamp: tip.timestamp,
            mainChainHashes: mainChainHashes,
            blocks: blocks,
            parentChainMap: [:],
            missingBlockHashes: []
        )
    }

    /// CFC-A3 : a persisted block whose `target` string is *present
    /// but undecodable* is corruption — `ChainState.restore`/`resetFrom` would map
    /// it to `UInt256.zero` work, silently understating this chain's accumulated
    /// work and inviting a spurious fork. The startup guard fails closed
    /// (markChainUnhealthy / reindex) on this rather than restoring a zeroed tip.
    ///
    /// A `nil` target is NOT corruption: pre-prefix-sum / sync-produced blocks
    /// legitimately omit it (recomputed window-relative on restore).
    ///
    static func persistedHasUndecodableTarget(_ persisted: PersistedChainState) -> Bool {
        for block in persisted.blocks {
            if let hex = block.target, UInt256(hex, radix: 16) == nil {
                return true
            }
        }
        return false
    }

    /// A persisted chain snapshot is only usable for startup if the local CAS can
    /// resolve the tip block and the frontier roots that validators/miners need
    /// immediately after boot. Otherwise the node can restore an apparently high
    /// tip and then reject every newly-mined block with missing prevState/postState
    /// CIDs.
    static func isPersistedChainStateUsable(
        _ persisted: PersistedChainState,
        diskBroker: DiskBroker
    ) async -> Bool {
        let fetcher = DiskBrokerFetcher(diskBroker: diskBroker)
        guard !persisted.chainTip.isEmpty,
              let tipBlock = try? await VolumeImpl<Block>(rawCID: persisted.chainTip)
                  .resolve(fetcher: fetcher).node else {
            return false
        }

        if let postStateCID = persisted.tipPostStateCID,
           postStateCID != tipBlock.postState.rawCID {
            return false
        }
        if let prevStateCID = persisted.tipPrevStateCID,
           prevStateCID != tipBlock.prevState.rawCID {
            return false
        }
        if let specCID = persisted.tipSpecCID,
           specCID != tipBlock.spec.rawCID {
            return false
        }

        return await isTipFrontierResolvable(tipBlock, fetcher: fetcher)
    }

    static func isTipFrontierResolvable(_ tipBlock: Block, fetcher: Fetcher) async -> Bool {
        guard (try? await tipBlock.postState.resolve(fetcher: fetcher)) != nil,
              (try? await tipBlock.spec.resolve(fetcher: fetcher)) != nil,
              (try? await tipBlock.transactions.resolve(fetcher: fetcher)) != nil,
              (try? await tipBlock.children.resolve(fetcher: fetcher)) != nil else {
            return false
        }
        return true
    }

    static func isTipFrontierResolvable(_ tipBlock: Block, source: any ContentSource) async -> Bool {
        guard (try? await tipBlock.postState.resolve(source: source)) != nil,
              (try? await tipBlock.spec.resolve(source: source)) != nil,
              (try? await tipBlock.transactions.resolve(source: source)) != nil,
              (try? await tipBlock.children.resolve(source: source)) != nil else {
            return false
        }
        return true
    }

    /// Warm nextTargetByBlockCID from DiskBroker at startup so the first
    /// gossip blocks are validated against the correct expected target
    /// rather than passing through unchecked.
    func warmNextTargetCache(directory: String) async {
        let key = chainKey(forDirectory: directory)
        let tipCID = await sharedDiskBroker.getChainMeta(key: "chain_tip:\(key)")
        guard let tipCID,
              !tipCID.isEmpty else { return }
        // Only need recent blocks — targets change slowly and any
        // incoming block's parent is almost certainly within this window.
        let warmDepth: UInt64 = min(config.retentionDepth, 200)
        var currentCID = tipCID
        for _ in 0..<warmDepth {
            guard let payload = await sharedDiskBroker.fetchVolumeLocal(root: currentCID),
                  let data = payload.entries[currentCID],
                  let block = Block(data: data) else { break }
            cacheNextTarget(blockCID: currentCID, value: block.nextTarget)
            guard let parentCID = block.parent?.rawCID, !parentCID.isEmpty else { break }
            currentCID = parentCID
        }
    }

    func persistChainState(directory: String) async {
        guard let address = chainAddress(forDirectory: directory) else { return }
        await persistChainState(chainPath: address.components)
    }

    func persistChainState(chainPath: [String]) async {
        let key = chainKey(forPath: chainPath)
        guard let directory = chainPath.last,
              let persister = persisters[key],
              let chainState = await chain(forPath: chainPath) else { return }
        let persisted = await chainState.persist()

        // Write the bootstrap tip into the same SQLite database as the block
        // volumes BEFORE writing chain_state.json. This keeps the DiskBroker meta a
        // consistent BOOTSTRAP CACHE (not the canonical authority): the meta tip
        // always points to a block that exists in cas_data, so startup can seed
        // ChainState from it before recovery rolls forward to the StateStore tip.
        let tipCID = persisted.chainTip
        var metaWriteFailed = false
        if !tipCID.isEmpty {
            do {
                try await writeChainMeta(key: "chain_tip:\(key)", value: tipCID)
            } catch {
                // Boot seeds ChainState from the DiskBroker meta tip, so a lost meta
                // write leaves the bootstrap cache pointing at the prior tip even
                // though chain_state.json advanced. Fail closed: log it, mark storage
                // degraded, and do NOT reset blocksSinceLastPersist below so
                // chain_state.json and the meta tip can't diverge silently.
                // TODO(Module 2 follow-up): under StateStore-authority (option-b)
                // recoverFromCAS rolls ChainState forward to the StateStore tip
                // regardless of the meta, so this degraded-marking may be vestigial.
                // Re-evaluate behind full smoke + l1 review before changing it.
                NodeLogger("persistence").error("Failed to write chain_tip meta for \(directory): \(error) — not treating chain state as persisted")
                await markChainStorageDegraded(chainPath: chainPath, reason: "failed to write chain_tip meta")
                metaWriteFailed = true
            }
        }

        // Prune nextTargetByBlockCID to the current retention window.
        let validCIDs = Set(persisted.blocks.map { $0.blockHash })
        pruneNextTargetCache(keepingCIDs: validCIDs)

        // reset the cadence counter ONLY on a successful save. The
        // meta tip (above) has already advanced; if `save` throws, chain_state.json
        // is stale. Resetting unconditionally would make `maybePersist` wait
        // another full `persistInterval` before retrying, widening the window
        // where the on-disk JSON disagrees with the durable tip. Leaving the
        // counter untouched on failure means the next `maybePersist` (count
        // already >= persistInterval) re-persists immediately.
        do {
            try await persister.save(persisted)
            // Only mark this persist as complete when the save succeeded AND the
            // authoritative meta tip was actually committed; otherwise leave the
            // counter so the next block retries.
            if !metaWriteFailed {
                blocksSinceLastPersist[key] = 0
            }
        } catch {
            let log = NodeLogger("persistence")
            log.error("Failed to persist chain state for \(directory): \(error)")
        }
    }

    func maybePersist(directory: String) async {
        let key = chainKey(forDirectory: directory)
        let count = (blocksSinceLastPersist[key] ?? 0) + 1
        blocksSinceLastPersist[key] = count
        if count >= config.persistInterval {
            await persistChainState(directory: directory)
        }
    }

    // MARK: - Mempool Persistence

    func persistMempool(directory: String, network: ChainNetwork) async {
        await persistMempool(network: network)
    }

    func persistMempool(network: ChainNetwork) async {
        let persistence = MempoolPersistence(dataDir: config.storagePath.appendingPathComponent(storageNamespace(forPath: network.chainPath)))
        let directory = network.directory
        let txs = await network.allMempoolTransactions()
        do {
            try persistence.save(transactions: txs)
        } catch {
            let log = NodeLogger("persistence")
            log.error("Failed to persist mempool for \(directory): \(error)")
        }
    }

    func restoreMempool(directory: String, network: ChainNetwork, fetcher: Fetcher) async {
        let persistence = MempoolPersistence(dataDir: config.storagePath.appendingPathComponent(storageNamespace(forPath: network.chainPath)))
        let serialized = persistence.load()
        guard !serialized.isEmpty else { return }
        var restored = 0
        for stx in serialized {
            let bodyHeader = HeaderImpl<TransactionBody>(rawCID: stx.bodyCID)
            guard let resolvedBody = try? await bodyHeader.resolve(fetcher: fetcher),
                  resolvedBody.node != nil else { continue }
            let tx = Transaction(signatures: stx.signatures, body: resolvedBody)
            // P-1304: admitToMempool (via P-902) already resolves the on-chain nonce
            // and calls updateConfirmedNonce internally — explicit getNonce +
            // seedConfirmedNonceIfUnset here was a redundant double-resolve.
            switch await admitToMempool(transaction: tx, chainPath: network.chainPath) {
            case .added, .replacedExisting:
                restored += 1
            case .rejected:
                break
            }
        }
        if restored > 0 {
            let log = NodeLogger("persistence")
            log.info("\(directory): restored \(restored) mempool transaction(s)")
        }
        persistence.delete()
    }

    // MARK: - CAS-Based Chain Recovery

    func recoverRecoverableUnhealthyChains() async {
        guard chainHealth.values.contains(where: \.isRecoverable) else { return }

        for chainPath in topologicallyOrderedChainPaths() {
            let key = chainKey(forPath: chainPath)
            guard case .degraded(_, _, .committedTipFrontier)? = chainHealth[key],
                  let directory = chainPath.last,
                  let network = network(forPath: chainPath) else {
                continue
            }
            await recoverRecoverableUnhealthyChain(directory: directory, network: network)
        }
    }

    private func recoverRecoverableUnhealthyChain(directory: String, network: ChainNetwork) async {
        let log = NodeLogger("recovery")
        guard await committedTipBlockIfFrontierResolves(directory: directory, network: network) != nil else {
            log.warn("\(directory): storage-degraded recovery waiting; committed tip frontier is not resolvable")
            return
        }
        guard await recoverFromCAS(directory: directory) else {
            log.warn("\(directory): storage-degraded recovery waiting; StateStore projection from CAS failed")
            return
        }
        guard let recoveredTipBlock = await committedTipBlockIfFrontierResolves(directory: directory, network: network) else {
            log.warn("\(directory): storage-degraded recovery waiting; committed tip frontier no longer resolves after projection")
            return
        }

        do {
            try await network.start()
            markChainHealthy(chainPath: network.chainPath)
            updateSyncActiveMetric()

            if let chainState = await chain(for: directory) {
                let tipCID = await chainState.getMainChainTip()
                let tipHeight = await chainState.getHighestBlockHeight()
                let specCID = recoveredTipBlock.spec.rawCID
                await network.broadcastChainAnnounce(tipCID: tipCID, tipHeight: tipHeight, specCID: specCID)
            }
            log.info("\(directory): recovered from transient durable storage failure")
        } catch {
            log.warn("\(directory): durable storage is readable again but chain network restart failed: \(error)")
        }
    }

    private func committedTipFrontierResolves(directory: String, network: ChainNetwork) async -> Bool {
        await committedTipBlockIfFrontierResolves(directory: directory, network: network) != nil
    }

    private func committedTipBlockIfFrontierResolves(directory: String, network: ChainNetwork) async -> Block? {
        let key = chainKey(forPath: network.chainPath)
        guard let store = stateStores[key],
              let tipCID = store.getChainTip(),
              !tipCID.isEmpty else {
            return nil
        }
        let source = recoverySource(directory: directory, network: network)
        let tipStub = VolumeImpl<Block>(rawCID: tipCID, node: nil, encryptionInfo: nil)
        guard let tipBlock = try? await tipStub.resolve(source: source).node else {
            return nil
        }
        return await Self.isTipFrontierResolvable(tipBlock, source: source) ? tipBlock : nil
    }

    /// Recover chain state from CAS after an ungraceful shutdown.
    /// The StateStore (SQLite) is crash-safe and tracks the real tip.
    /// If it's ahead of the chain state (which is persisted periodically),
    /// walk backwards through CAS from the SQLite tip to the chain state tip,
    /// then replay those blocks forward to catch up.
    func recoverFromCAS(directory: String) async -> Bool {
        let log = NodeLogger("recovery")
        guard let store = stateStores[chainKey(forDirectory: directory)],
              let network = network(for: directory),
              let chainState = await chain(for: directory) else { return false }

        let chainTipCID = await chainState.getMainChainTip()
        let chainHeight = await chainState.getHighestBlockHeight()

        guard let sqliteTipCID = store.getChainTip(),
              let sqliteHeight = store.getHeight() else { return true }

        guard await recoverReceiptIndexesIfNeeded(
            directory: directory,
            store: store,
            network: network,
            committedHeight: sqliteHeight
        ) else {
            return false
        }

        // StateStore is the authoritative durable head (it's where commitCanonicalSegment
        // atomically published the canonical tip); ChainState is its in-memory projection,
        // which a crash before persistChainState can leave behind. Recover whenever the
        // committed tip differs — including a REORG where the committed tip is not a
        // descendant of the in-memory tip (height alone can't detect that; an equal-height
        // reorg has sqliteHeight == chainHeight).
        guard sqliteTipCID != chainTipCID else { return true }

        log.info("\(directory): in-memory tip \(String(chainTipCID.prefix(16)))@\(chainHeight) != committed tip \(String(sqliteTipCID.prefix(16)))@\(sqliteHeight) — projecting ChainState from the authoritative StateStore head")

        let source = recoverySource(directory: directory, network: network)
        guard let projected = await Self.rebuildChainState(
            tipCID: sqliteTipCID,
            source: source,
            retentionDepth: config.retentionDepth
        ) else {
            log.error("Recovery: could not fetch committed branch \(String(sqliteTipCID.prefix(16))) from CAS")
            return false
        }
        let tipStub = VolumeImpl<Block>(rawCID: sqliteTipCID, node: nil, encryptionInfo: nil)
        guard let tipBlock = try? await tipStub.resolve(source: source).node else {
            log.error("Recovery: could not fetch committed tip \(String(sqliteTipCID.prefix(16))) from CAS")
            return false
        }
        do {
            try await chainState.resetFrom(projected, retentionDepth: config.retentionDepth)
        } catch {
            log.error("\(directory): failed to reset ChainState from committed StateStore head: \(error)")
            return false
        }
        await chainState.updateTipSnapshot(block: tipBlock)

        // Anchor the tip cache to the actual main-chain tip after recovery.
        let postRecoveryTip = await chainState.getMainChainTip()
        guard postRecoveryTip == sqliteTipCID else {
            log.error("\(directory): recovery projection selected \(postRecoveryTip) but committed durable tip is \(sqliteTipCID)")
            return false
        }
        tipCaches[chainKey(forDirectory: directory)]?.update(postRecoveryTip)

        log.info("\(directory): projected ChainState to committed tip \(String(sqliteTipCID.prefix(16)))@\(sqliteHeight) from CAS")
        await persistChainState(directory: directory)
        return true
    }

    func recoverySource(directory: String, network: ChainNetwork) -> any ContentSource {
        guard directory == genesisConfig.directory else {
            return IvyContentSource(network.ivyFetcher)
        }
        let storer = StaticEntryStorer()
        do {
            let block = genesisResult.block
            try VolumeImpl<Block>(node: block).storeRecursively(storer: storer)
            try block.transactions.storeRecursively(storer: storer)
            try block.children.storeRecursively(storer: storer)
            try block.spec.storeRecursively(storer: storer)
            try block.postState.storeRecursively(storer: storer)
            // prevState/parentState are References to the genesis empty state
            // (not owned children). Stage the empty state itself so they resolve
            // from the overlay during recovery.
            try LatticeState.emptyHeader.storeRecursively(storer: storer)
        } catch {
            NodeLogger("recovery").warn("\(directory): failed to stage genesis recovery overlay: \(error)")
            return IvyContentSource(network.ivyFetcher)
        }
        // Byte-identical mirror of the prior per-CID composite (ivy primary,
        // staged-genesis-overlay fallback): ivy tier first, then the staged genesis
        // overlay — same precedence.
        return CompositeContentSource([IvyContentSource(network.ivyFetcher), InMemoryContentSource(storer.snapshot())])
    }

    private func recoverReceiptIndexesIfNeeded(
        directory: String,
        store: StateStore,
        network: ChainNetwork,
        committedHeight: UInt64
    ) async -> Bool {
        let appliedThrough = store.getReceiptsAppliedThroughHeight() ?? 0
        guard appliedThrough < committedHeight else { return true }

        let log = NodeLogger("recovery")
        let fetcher = network.canonicalContentFetcher()
        let replayStart = max(appliedThrough + 1, store.getLowestBlockIndexHeight() ?? appliedThrough + 1)
        guard replayStart <= committedHeight else { return true }
        var recovered = 0
        if replayStart > appliedThrough + 1 {
            log.info("\(directory): receipts marker \(appliedThrough) is below retained block_index floor; replaying from height \(replayStart)")
        }
        for height in replayStart...committedHeight {
            guard let blockHash = store.getBlockHash(atHeight: height) else {
                log.error("\(directory): receipts marker lags at \(appliedThrough), but block_index[\(height)] is missing")
                return false
            }
            let stub = VolumeImpl<Block>(rawCID: blockHash, node: nil, encryptionInfo: nil)
            let block: Block
            do {
                guard let resolved = try await stub.resolve(fetcher: fetcher).node else {
                    log.error("\(directory): receipts marker lags at \(appliedThrough), but committed block \(String(blockHash.prefix(16)))…@\(height) header resolved without a node")
                    return false
                }
                block = resolved
            } catch {
                log.error("\(directory): receipts marker lags at \(appliedThrough), but committed block \(String(blockHash.prefix(16)))…@\(height) header is missing from canonical CAS: \(error)")
                return false
            }
            guard let txEntries = await resolveReceiptTransactions(
                block: block,
                blockHash: blockHash,
                fetcher: fetcher,
                directory: directory,
                height: height
            ) else {
                return false
            }
            let (generalEntries, txHistoryEntries) = await buildReceiptsParallel(
                txEntries: txEntries,
                blockHash: blockHash,
                blockHeight: height,
                blockTimestamp: block.timestamp
            )
            do {
                try await store.batchIndexReceipts(
                    generalEntries: generalEntries,
                    txHistory: txHistoryEntries,
                    appliedThroughHeight: height
                )
            } catch {
                log.error("\(directory): receipts recovery failed to commit indexes at height \(height): \(error)")
                return false
            }
            recovered += 1
        }
        if recovered > 0 {
            log.info("\(directory): reindexed receipts for \(recovered) committed block(s) through height \(committedHeight)")
        }
        return true
    }

    private func resolveReceiptTransactions(
        block: Block,
        blockHash: String,
        fetcher: Fetcher,
        directory: String,
        height: UInt64
    ) async -> [String: VolumeImpl<Transaction>]? {
        let log = NodeLogger("recovery")
        guard let txDict = try? await block.transactions.resolveRecursive(fetcher: fetcher).node,
              let entries = try? txDict.allKeysAndValues() else {
            log.error("\(directory): receipts marker lags, but committed block \(String(blockHash.prefix(16)))…@\(height) transaction dictionary is missing from CAS")
            return nil
        }

        var resolved: [String: VolumeImpl<Transaction>] = [:]
        resolved.reserveCapacity(entries.count)
        for (key, txHeader) in entries {
            guard let tx = try? await txHeader.resolveRecursive(fetcher: fetcher) else {
                log.error("\(directory): receipts marker lags, but transaction \(String(txHeader.rawCID.prefix(16)))… in committed block \(String(blockHash.prefix(16)))…@\(height) is missing from CAS")
                return nil
            }
            resolved[key] = tx
        }
        return resolved
    }

    // MARK: - Block Index Backfill

    /// Backfill the SQLite block_index table from the in-memory chain state.
    /// This ensures blocks persisted before the block_index table existed
    /// become queryable by height after restart.
    func backfillBlockIndex(directory: String) async {
        guard let store = stateStores[chainKey(forDirectory: directory)],
              let chainState = await chain(for: directory) else { return }
        let log = NodeLogger("persistence")
        let height = await chainState.getHighestBlockHeight()
        // Skip the full chain walk when block_index is already CONTIGUOUS up to
        // `height`. Each `applyBlock` writes its own height into block_index
        // atomically, so on any steady-state restart the table already has a
        // gap-free 0...height and the scan is pure overhead. At ~300 blocks/hour
        // a year-old chain is ~2.6M rows to walk; the skip drops restart from
        // seconds-to-minutes to O(1).
        //
        // the gate is a contiguity predicate, NOT a bare COUNT(*). A
        // stale over-tip row (no `DELETE WHERE height > tip` on a shorter-chain
        // promotion) inflates COUNT past height+1 and would mask a missing
        // interior height, skipping the repair and leaving an unqueryable gap.
        if store.isBlockIndexContiguous(throughHeight: height) { return }
        let tip = await chainState.getMainChainTip()
        var entries: [(height: UInt64, blockHash: String)] = []
        var missing: [UInt64] = []
        for i in 0...height {
            if let hash = await chainState.getMainChainBlockHash(atIndex: i) {
                entries.append((height: i, blockHash: hash))
            } else {
                missing.append(i)
            }
        }
        if !missing.isEmpty {
            log.warn("\(directory): chain height=\(height) tip=\(String(tip.prefix(16)))… but \(missing.count) index(es) missing from in-memory state: \(missing.prefix(10))")
        }
        guard !entries.isEmpty else { return }
        await store.backfillBlockIndex(entries)
        log.info("\(directory): backfilled \(entries.count)/\(height + 1) block index entries")
    }

    /// Re-materialize the ROOT-keyed Volume grouping (`volume_entries(blockHash, *)`) for any
    /// retained main-chain block that lacks one. A block's bytes can be present in `cas_data`
    /// (so RPC `/api/block/N` serves it, and it's transitively pinned) yet have NO root-keyed
    /// volume of its own — which happens when the block arrived embedded inside a parent block's
    /// volume (root=parentHash — e.g. a child block carried inside a Nexus block on the shared
    /// DiskBroker) or was rebuilt by CID-only crash recovery (`rebuildChainState` resolves blocks
    /// by CID and never re-creates root volumes). Without its own root volume,
    /// `fetchVolumeLocal(root: blockHash)` returns nil, so `getHeaders/getHeaders2` cannot serve
    /// the block over P2P: a follower downloads 0 headers and can never sync, even though the data
    /// is fully intact locally. `storeBlockData` re-derives the volume from the block's
    /// content-addressed closure (already in `cas_data`), so we reconstruct the missing groupings
    /// here on startup. Idempotent (skips blocks whose durable root volume already exists) and
    /// bounded to the retained window.
    func reconstructBlockVolumes(directory: String) async {
        guard let network = network(for: directory),
              let chainState = await chain(for: directory) else { return }
        let log = NodeLogger("persistence")
        let height = await chainState.getHighestBlockHeight()
        let lowest = height > config.retentionDepth ? height - config.retentionDepth : 0
        let source = recoverySource(directory: directory, network: network)
        var reconstructed = 0
        for i in lowest...height {
            guard let blockHash = await chainState.getMainChainBlockHash(atIndex: i) else { continue }
            let stub = VolumeImpl<Block>(rawCID: blockHash, node: nil, encryptionInfo: nil)
            // A durable block ROOT volume is NOT sufficient. A block's transactions resolve
            // into per-tx sub-volumes, each carrying a tx BODY as its own servable grouping.
            // The prior recovery here shallow-resolved (`resolve(...).node` leaves
            // transactions UNHYDRATED), so `storeRecursively` SKIPPED them and rebuilt only a
            // bare root volume — every tx-value grouping stayed missing. A peer's root-keyed
            // volume responder then notFounds on the tx body, so a synced follower downloads
            // all headers but can never materialize block content. Content-resolve
            // (`resolveBlockContent` = spec/transactions/children, hydrated from local CAS) so
            // `storeRecursively` rebuilds every tx-value grouping and its body. postState is
            // materialized separately and is intentionally NOT resolved here.
            guard let block = try? await stub.resolveBlockContent(source: source).node else {
                log.warn("\(directory): reconstructBlockVolumes: could not content-resolve block \(String(blockHash.prefix(16)))… at height \(i)")
                continue
            }
            // Skip only when every served boundary is genuinely servable over P2P, using
            // the SAME predicate the serve gate applies (`servableRootPayload`): a root must
            // be BOTH pin-reachable AND have its own non-empty grouping. Durable existence,
            // or pin-reachability alone, is insufficient — a tx-value root can be
            // pin-reachable purely because it is an entry inside a pinned block bundle while
            // its OWN grouping is missing (the exact shallow-recovery failure), and a prior
            // run may have stored volumes but crashed before `pinBatchDurably`. Compute the
            // AUTHORITATIVE served-boundary set (block root, spec, every per-tx volume, and
            // any other owned sub-volume) the same way `storeBlockData` does — against a
            // throwaway in-memory broker, so no disk write. When any root is not servable,
            // fall through: `storeBlockData` + `pinBatchDurably` are idempotent and rebuild /
            // re-pin whatever a prior interrupted or shallow run left missing.
            let servedRoots = await storeBlockData(block, broker: MemoryBroker()) ?? []
            var servable = !servedRoots.isEmpty
            for r in servedRoots where (await network.servableRootPayload(for: r)) == nil {
                servable = false
                break
            }
            if servable { continue }
            guard let roots = await storeBlockData(block, network: network), !roots.isEmpty else { continue }
            try? await network.pinBatchDurably(roots: roots, owner: "\(network.ownerNamespace):\(i)")
            reconstructed += 1
        }
        if reconstructed > 0 {
            log.info("\(directory): reconstructed \(reconstructed) block closure(s) (full sub-volume reindex) in [\(lowest)...\(height)] for P2P serving + content materialization")
        }
    }

    // MARK: - Account Pin Rebuild

    /// Rebuild account pins from tx_history so the node retains and serves
    /// its own RECENT tx history across restarts.
    ///
    /// B1-class leak fix: this must mirror the live path (`pinAccountData`):
    ///   • pins go under the height-scoped owners `account:<ns>:txwindow:<h>`
    ///     so the M6 release window can reclaim them — the old bare
    ///     `account:<ns>` owner was never released and grew every restart;
    ///   • pins are bounded to the most recent `ownTxPinWindow` heights;
    ///   • block headers are deliberately NOT pinned — only the tx CIDs needed
    ///     to serve our own tx history;
    ///   • pins are written through the durable pin surface (`pinBatchDurably`).
    func rebuildAccountPins(directory: String) async {
        guard let store = stateStores[chainKey(forDirectory: directory)],
              let network = network(for: directory) else { return }

        let log = NodeLogger("persistence")
        let history = store.getAllTransactionCIDs(address: nodeAddress)

        // Anchor the retention window at the newest known height: normally the
        // chain tip, but never below the newest tx_history row (rows can lead
        // the in-memory tip during recovery replay).
        let tipHeight = await chain(for: directory)?.getHighestBlockHeight() ?? 0
        let historyMax = history.map(\.height).max() ?? 0
        let anchor = max(tipHeight, historyMax)
        let windowFloor = anchor >= ownTxPinWindow ? anchor - ownTxPinWindow + 1 : 0

        // Reclaim sweep: the live M6 release fires only when an own-tx block
        // lands at exactly h + ownTxPinWindow, so sparse own-tx traffic strands
        // txwindow owners; and pre-fix code pinned under the bare
        // `account:<ns>` owner, which nothing releases. Startup is the one
        // choke point every node passes through — release both here.
        let windowPrefix = "account:\(network.ownerNamespace):txwindow:"
        for owner in await network.pinnedOwners(prefix: windowPrefix) {
            guard let height = UInt64(owner.dropFirst(windowPrefix.count)), height < windowFloor else { continue }
            do {
                try await network.unpinAllDurably(owner: owner)
            } catch {
                log.error("\(directory): stale txwindow release failed for \(owner): \(error)")
            }
        }
        do {
            try await network.unpinAllDurably(owner: "account:\(network.ownerNamespace)")
        } catch {
            log.error("\(directory): legacy bare account-owner release failed: \(error)")
        }

        var txCIDsByHeight: [UInt64: [String]] = [:]
        for entry in history where entry.height >= windowFloor {
            txCIDsByHeight[entry.height, default: []].append(entry.txCID)
        }
        guard !txCIDsByHeight.isEmpty else { return }

        // Object-grain content store: transactions are in-package entries of
        // the BLOCK volume, so a pinned txCID's reachability closure protects
        // only the tx header blob. Mirror `pinAccountData` and pin each tx's
        // body CID alongside; a header that no longer resolves can't be
        // conjured at rebuild time — log and keep the header pin.
        let fetcher = network.canonicalContentFetcher()
        var pinned = 0
        for (height, cids) in txCIDsByHeight.sorted(by: { $0.key < $1.key }) {
            var roots: [String] = []
            roots.reserveCapacity(cids.count * 2)
            for txCID in cids {
                roots.append(txCID)
                do {
                    let tx = try await VolumeImpl<Transaction>(rawCID: txCID, node: nil, encryptionInfo: nil)
                        .resolve(fetcher: fetcher)
                    if let bodyCID = tx.node?.body.rawCID, !bodyCID.isEmpty {
                        roots.append(bodyCID)
                    }
                } catch {
                    log.warn("\(directory): could not resolve tx \(String(txCID.prefix(16)))… to pin its body: \(error)")
                }
            }
            let owner = Self.ownTxPinOwner(ownerNamespace: network.ownerNamespace, height: height)
            do {
                try await network.pinBatchDurably(roots: roots, owner: owner)
                pinned += roots.count
            } catch {
                log.error("\(directory): account pin rebuild failed at height \(height): \(error)")
            }
        }
        log.info("\(directory): rebuilt \(pinned) account pin(s) across \(txCIDsByHeight.count) height(s) from tx_history")
    }

    // MARK: - Deployed Child Chain Persistence

    private var deployedChildChainsURL: URL {
        config.storagePath.appendingPathComponent("deployed_child_chains.json")
    }

    private struct PersistedRPCEndpoints: Codable {
        let endpoints: [String: String]
    }

    private struct PersistedRPCAuthTokens: Codable {
        let authTokens: [String: String]
    }

    private var registeredRPCRegistrationsURL: URL {
        config.storagePath.appendingPathComponent("registered_rpc_endpoints.json")
    }

    private var registeredRPCAuthTokensURL: URL {
        config.storagePath.appendingPathComponent("registered_rpc_auth_tokens.json")
    }

    // Versioned on-disk envelope for deployed-child metadata. Treating the file as a
    // protocol format (not a bare struct dump) means schema changes are explicit and
    // migratable: load tries the current envelope, then falls back to the legacy bare
    // map, and a present-but-corrupt file is logged loudly rather than silently dropped
    // (silent [:] on upgrade would erase a parent's whole deployed-child set).
    struct DeployedChildChainsFile: Codable {
        static let currentVersion = 2
        var schemaVersion: Int
        var chains: [String: DeployedChainMetadata]

        init(chains: [String: DeployedChainMetadata], schemaVersion: Int = currentVersion) {
            self.schemaVersion = schemaVersion
            self.chains = chains
        }
        enum CodingKeys: String, CodingKey { case schemaVersion, chains }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentVersion
            chains = try c.decode([String: DeployedChainMetadata].self, forKey: .chains)
        }
    }

    func persistDeployedChildChains() async {
        do {
            let file = DeployedChildChainsFile(chains: deployedChildChains)
            let data = try JSONEncoder().encode(file)
            try data.write(to: deployedChildChainsURL, options: .atomic)
        } catch {
            NodeLogger("persistence").error("Failed to persist deployed child chain metadata: \(error)")
        }
    }

    func loadDeployedChildChains() -> [String: DeployedChainMetadata] {
        guard FileManager.default.fileExists(atPath: deployedChildChainsURL.path) else {
            return [:]  // fresh node — no file yet
        }
        guard let data = try? Data(contentsOf: deployedChildChainsURL) else {
            NodeLogger("persistence").error("deployed_child_chains.json unreadable; keeping file, starting with empty deployed-child set")
            return [:]
        }
        return Self.decodeDeployedChildChains(data)
    }

    /// Pure decode with legacy migration — extracted so migration tests can exercise it
    /// against fixture bytes without standing up a node. v2 = versioned envelope; v1 =
    /// legacy bare `[chainKey: DeployedChainMetadata]` map.
    static func decodeDeployedChildChains(_ data: Data) -> [String: DeployedChainMetadata] {
        let decoder = JSONDecoder()
        if let file = try? decoder.decode(DeployedChildChainsFile.self, from: data) {
            return file.chains
        }
        do {
            let legacy = try decoder.decode([String: DeployedChainMetadata].self, from: data)
            NodeLogger("persistence").info("migrated deployed_child_chains.json from legacy (v1) to versioned (v\(DeployedChildChainsFile.currentVersion)) schema")
            return legacy
        } catch {
            NodeLogger("persistence").error("deployed_child_chains.json present but undecodable (\(error)); keeping file for recovery, starting with empty deployed-child set")
            return [:]
        }
    }

    func persistRegisteredRPCRegistrations() {
        do {
            let data = try JSONEncoder().encode(PersistedRPCEndpoints(endpoints: registeredRPCEndpoints))
            try data.write(to: registeredRPCRegistrationsURL, options: .atomic)
            if registeredRPCAuthTokens.isEmpty {
                try? FileManager.default.removeItem(at: registeredRPCAuthTokensURL)
            } else {
                let tokenData = try JSONEncoder().encode(PersistedRPCAuthTokens(authTokens: registeredRPCAuthTokens))
                try writeSensitiveSidecar(tokenData, to: registeredRPCAuthTokensURL)
            }
        } catch {
            NodeLogger("persistence").error("Failed to persist registered RPC endpoints: \(error)")
        }
    }

    private func loadRegisteredRPCEndpoints() -> [String: String] {
        guard FileManager.default.fileExists(atPath: registeredRPCRegistrationsURL.path) else { return [:] }
        guard let data = try? Data(contentsOf: registeredRPCRegistrationsURL) else {
            NodeLogger("persistence").error("registered_rpc_endpoints.json unreadable; starting with no registrations")
            return [:]
        }
        do {
            return try JSONDecoder().decode(PersistedRPCEndpoints.self, from: data).endpoints
        } catch {
            NodeLogger("persistence").error("registered_rpc_endpoints.json present but undecodable (\(error)); keeping file for recovery, starting with no registrations")
            return [:]
        }
    }

    private func loadRegisteredRPCAuthTokens() -> [String: String] {
        let fm = FileManager.default
        let decoder = JSONDecoder()
        if fm.fileExists(atPath: registeredRPCAuthTokensURL.path) {
            guard sensitiveSidecarPermissionsAreStrict(registeredRPCAuthTokensURL) else {
                NodeLogger("persistence").error("Ignoring registered RPC auth token sidecar with non-0600 permissions: \(registeredRPCAuthTokensURL.path)")
                return [:]
            }
            guard let data = try? Data(contentsOf: registeredRPCAuthTokensURL) else {
                NodeLogger("persistence").error("registered_rpc_auth_tokens.json unreadable; starting with no auth tokens")
                return [:]
            }
            do {
                return try decoder.decode(PersistedRPCAuthTokens.self, from: data).authTokens
            } catch {
                NodeLogger("persistence").error("registered_rpc_auth_tokens.json present but undecodable (\(error)); keeping file for recovery, starting with no auth tokens")
                return [:]
            }
        }
        return [:]
    }

    private func sensitiveSidecarPermissionsAreStrict(_ url: URL) -> Bool {
        #if os(Windows)
        return true
        #else
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value else {
            return false
        }
        return (perms & 0o777) == 0o600
        #endif
    }

    private func writeSensitiveSidecar(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        if fm.fileExists(atPath: tmp.path) {
            try fm.removeItem(at: tmp)
        }
        guard fm.createFile(
            atPath: tmp.path,
            contents: data,
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        #if !os(Windows)
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: tmp.path)
        #endif
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        try fm.moveItem(at: tmp, to: url)
        #if !os(Windows)
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
        #endif
    }

    func recordDeployedChildChain(_ metadata: DeployedChainMetadata) async {
        deployedChildChains[chainKey(forPath: metadata.chainPath)] = metadata
        await persistDeployedChildChains()
    }

    public func restoreDeployedChildChains() async {
        deployedChildChains = loadDeployedChildChains()
        registeredRPCEndpoints = loadRegisteredRPCEndpoints()
        registeredRPCAuthTokens = loadRegisteredRPCAuthTokens()
        // Persisted loopback registrations are KEPT: reconcileSupervisedChildren()
        // probes each child and adopts a live one (using the persisted token) or
        // recovers a dead one. Clearing here would discard the token needed to adopt
        // a child that survived a parent crash (Contract 4).
    }
}
