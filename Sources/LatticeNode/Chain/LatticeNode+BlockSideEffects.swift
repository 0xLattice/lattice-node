import Lattice
import LatticeNodeWire
import Foundation
import Ivy
import VolumeBroker
import Tally
import cashew
import UInt256

// Block side effects for LatticeNode.
// Behavior-preserving extraction : accepted-block application, receipts,
// state changeset, account-data pinning, peer rate-limit/dedup tracking, and the
// child-block gossip delegate. Pure relocation; no logic change.

extension LatticeNode {

    static let receiptEncoder = JSONEncoder()
    var blockDeduplicationWindow: Duration { config.tuning.gossip.blockDedupWindow }

    /// the maximum serialized size of an inline childBlock work proof,
    /// derived from the spec's `maxBlockSize` size policy (NOT an independent
    /// constant). A proof carries the sparse CAS entries along the receiving
    /// chain's root-exclusive path; its dominant cost is at most one full
    /// block-equivalent per level on that path, so the bound scales with path
    /// depth (`max(1, pathDepth)`). For a direct child of the PoW root
    /// (`pathDepth == 2`, e.g. `[Nexus, Mid]`) this is two block-equivalents.
    /// Legitimate composed proofs fit; an attacker-sized inline proof is rejected.
    static func maxProofSize(pathDepth: Int, spec: ChainSpec) -> Int {
        max(1, pathDepth) * spec.maxBlockSize
    }

    /// size-policy admission for an inline childBlock gossip payload,
    /// evaluated on the RAW wire byte lengths in the `ChainNetwork` IvyDelegate
    /// handler BEFORE `Block(data:)` / `ChildBlockProof.deserialize`. The inline
    /// block must fit the spec block cap and the inline proof must fit
    /// `maxProofSize` for the receiving chain's path depth. Checking the raw
    /// `proofBytes` (rather than only a successfully-deserialized proof) is what
    /// closes the oversized-but-malformed-proof gap: such a proof decodes to nil
    /// and would otherwise skip the post-decode cap. Fail closed.
    nonisolated public func chainNetwork(
        _ network: ChainNetwork,
        allowsChildBlockSize blockBytes: Int,
        proofBytes: Int?
    ) -> Bool {
        if blockBytes > genesisConfig.spec.maxBlockSize { return false }
        if let proofBytes,
           proofBytes > Self.maxProofSize(pathDepth: network.chainPath.count, spec: genesisConfig.spec) {
            return false
        }
        return true
    }
    var peerBlockCountCleanupThreshold: Int { config.tuning.gossip.peerBlockCountCleanupThreshold }
    var peerBlockCountWindow: Duration { config.tuning.gossip.peerBlockCountWindow }
    func isPeerBlockRateLimited(_ peer: PeerID) -> Bool {
        let now = ContinuousClock.Instant.now

        // Evict oldest entries when over hard cap (LRU: oldest are at front)
        while peerBlockCounts.count > peerBlockCountCleanupThreshold {
            peerBlockCounts.removeFirst()
        }

        if let entry = peerBlockCounts[peer] {
            if now - entry.windowStart < peerRateWindow {
                if entry.count >= Self.maxBlocksPerPeerPerWindow {
                    return true
                }
                // Move to end (most recently used)
                peerBlockCounts.removeValue(forKey: peer)
                peerBlockCounts[peer] = (count: entry.count + 1, windowStart: entry.windowStart)
            } else {
                peerBlockCounts.removeValue(forKey: peer)
                peerBlockCounts[peer] = (count: 1, windowStart: now)
            }
        } else {
            peerBlockCounts[peer] = (count: 1, windowStart: now)
        }
        return false
    }
    func recentBlockTime(for key: String) -> ContinuousClock.Instant? {
        recentPeerBlocks[key]
    }
    var maxRecentPeerBlocks: Int { config.tuning.gossip.maxRecentPeerBlocks }
    /// How long a `recentPeerBlocks` entry remains useful. The dedup check
    /// only cares about hits inside `blockDeduplicationWindow` (100ms), so
    /// anything older than ~60s is dead weight that the LRU hard-cap would
    /// eventually evict — a periodic sweep drops it earlier and keeps memory
    /// bounded under steady-state churn.
    var recentPeerBlockRetention: Duration { config.tuning.gossip.recentPeerBlockRetention }
    /// Forget a CID's gossip-dedup timestamp. Used when re-delivering a block
    /// internally (post-sync buffered-gossip replay): the original network
    /// arrival recorded the CID moments before it was buffered, so a sync that
    /// finishes within `blockDeduplicationWindow` would otherwise dedup-drop
    /// the replay and silently lose the block.
    func clearBlockTime(key: String) {
        recentPeerBlocks.removeValue(forKey: key)
    }
    func recordBlockTime(key: String, time: ContinuousClock.Instant) {
        // Move to end on update (LRU touch)
        recentPeerBlocks.removeValue(forKey: key)
        recentPeerBlocks[key] = time
        // Hard cap: evict oldest entries from front
        while recentPeerBlocks.count > maxRecentPeerBlocks {
            recentPeerBlocks.removeFirst()
        }
    }
    /// Dedup timestamp for bare block ANNOUNCEMENTS. Separate from
    /// `recentBlockTime` so an unvalidated announce can never suppress the
    /// validated full-block path (see `recentBlockAnnounces`).
    func recentBlockAnnounceTime(for key: String) -> ContinuousClock.Instant? {
        recentBlockAnnounces[key]
    }
    func recordBlockAnnounceTime(key: String, time: ContinuousClock.Instant) {
        recentBlockAnnounces.removeValue(forKey: key)
        recentBlockAnnounces[key] = time
        while recentBlockAnnounces.count > maxRecentPeerBlocks {
            recentBlockAnnounces.removeFirst()
        }
    }
    /// Drop peer-tracking entries whose time window has elapsed. Hard caps
    /// already keep the dicts from unbounded growth, but a peer that bursts
    /// once and disappears would otherwise sit in `peerBlockCounts` until
    /// 5000 other peers showed up to evict it. Called from the mempool loop.
    func sweepPeerTracking() {
        let now = ContinuousClock.Instant.now
        // removeAll(where:) removes in place without allocating a new dictionary,
        // unlike .filter which builds a fresh OrderedDictionary every sweep.
        let rateWindow = peerRateWindow
        peerBlockCounts.removeAll(where: { _, entry in
            now - entry.windowStart >= rateWindow
        })
        let recentCutoff = recentPeerBlockRetention
        recentPeerBlocks.removeAll(where: { _, t in
            now - t >= recentCutoff
        })
        recentBlockAnnounces.removeAll(where: { _, t in
            now - t >= recentCutoff
        })
    }

    // MARK: - Shared Helpers
    struct PreparedAcceptedBlockEffects {
        let block: Block
        let blockHash: String
        let txEntries: [String: VolumeImpl<Transaction>]
        let directory: String
        let blockHeight: UInt64
        let blockTimestamp: Int64
        let storeEffects: CanonicalBlockEffects
        let mempoolNonceUpdates: [(sender: String, nonce: UInt64)]
        let txFees: [UInt64]
        let txBodyCIDs: Set<String>
        let txCIDs: Set<String>
        let replacedCanonicalBlock: String?
    }

    /// Deterministically derive all block effects from the transaction actions.
    /// Consensus data is the ordered action set in the block; receipts,
    /// tx-history rows, nonce floors, and fee samples are local projections.
    func prepareAcceptedBlockEffects(
        block: Block,
        blockHash: String,
        txEntries: [String: VolumeImpl<Transaction>],
        directory: String,
        allowLowerHeightReplay: Bool = false
    ) async -> PreparedAcceptedBlockEffects? {
        let store = stateStores[chainKey(forDirectory: directory)]
        let blockHeight = block.height
        let blockTimestamp = block.timestamp
        if let durableHeight = store?.getHeight(), blockHeight < durableHeight, !allowLowerHeightReplay {
            NodeLogger("blocks").info("\(directory): skipping stale canonical side effects for block \(String(blockHash.prefix(16)))… at height \(blockHeight); durable tip is already height \(durableHeight)")
            return nil
        }
        let replacedCanonicalBlock = store?.getBlockHash(atHeight: blockHeight)
            .flatMap { $0 == blockHash ? nil : $0 }

        async let receiptTask = buildReceiptsParallel(
            txEntries: txEntries, blockHash: blockHash,
            blockHeight: blockHeight, blockTimestamp: blockTimestamp
        )

        let (changeset, mempoolNonceUpdates) = extractStateChangeset(
            block: block, blockHash: blockHash,
            txEntries: txEntries
        )

        var txFees: [UInt64] = []
        for (_, txHeader) in txEntries {
            if let fee = txHeader.node?.body.node?.fee, fee > 0 {
                txFees.append(fee)
            }
        }

        let (generalEntries, txHistoryEntries) = await receiptTask

        let txBodyCIDs = Set(txEntries.values.compactMap { $0.node?.body.rawCID })
        let txCIDs = Set(txEntries.values.map(\.rawCID))
        return PreparedAcceptedBlockEffects(
            block: block,
            blockHash: blockHash,
            txEntries: txEntries,
            directory: directory,
            blockHeight: blockHeight,
            blockTimestamp: blockTimestamp,
            storeEffects: CanonicalBlockEffects(
                changes: changeset,
                receiptGeneralEntries: generalEntries,
                txHistory: txHistoryEntries
            ),
            mempoolNonceUpdates: mempoolNonceUpdates,
            txFees: txFees,
            txBodyCIDs: txBodyCIDs,
            txCIDs: txCIDs,
            replacedCanonicalBlock: replacedCanonicalBlock
        )
    }

    /// Apply an accepted block's state changes, receipts, fees, events, and metrics.
    func applyAcceptedBlock(
        block: Block,
        blockHash: String,
        txEntries: [String: VolumeImpl<Transaction>],
        directory: String,
        allowLowerHeightReplay: Bool = false
    ) async -> Bool {
        guard let prepared = await prepareAcceptedBlockEffects(
            block: block,
            blockHash: blockHash,
            txEntries: txEntries,
            directory: directory,
            allowLowerHeightReplay: allowLowerHeightReplay
        ) else {
            return true
        }
        let store = stateStores[chainKey(forDirectory: directory)]

        // commit the canonical tip, block_index rows, receipts, tx_history,
        // and receipts-applied-through marker in one StateStore transaction.
        if let store {
            guard await store.applyBlock(
                prepared.storeEffects.changes,
                receiptGeneralEntries: prepared.storeEffects.receiptGeneralEntries,
                txHistory: prepared.storeEffects.txHistory
            ) else {
                return false
            }
        }

        await applyPreparedAcceptedBlockEffects(prepared, recoverReplacedCanonicalBlock: true)
        return true
    }

    /// Apply side effects that are intentionally outside the canonical
    /// StateStore transaction. Callers that already committed
    /// `prepared.storeEffects` can reuse this without rewriting SQLite rows.
    func applyPreparedAcceptedBlockEffects(
        _ prepared: PreparedAcceptedBlockEffects,
        recoverReplacedCanonicalBlock: Bool
    ) async {
        let directory = prepared.directory
        let network = network(for: directory)
        if let network {
            await network.nodeMempool.removeAll(txCIDs: prepared.txBodyCIDs)
            await network.nodeMempool.batchUpdateConfirmedNonces(updates: prepared.mempoolNonceUpdates)
        }
        if recoverReplacedCanonicalBlock, let replacedCanonicalBlock = prepared.replacedCanonicalBlock {
            await recoverTransactionsFromReplacedCanonicalBlock(
                oldBlockHash: replacedCanonicalBlock,
                newTxCIDs: prepared.txCIDs,
                directory: directory
            )
        }
        await persistParentStateEdgesForChildContinuity(
            parentDirectory: directory,
            block: prepared.block,
            blockHash: prepared.blockHash
        )

        // Pin CIDs for transactions involving our account
        await pinAccountData(
            blockHash: prepared.blockHash,
            blockHeight: prepared.blockHeight,
            txEntries: prepared.txEntries,
            txHistoryEntries: prepared.storeEffects.txHistory,
            directory: directory
        )

        if !prepared.txFees.isEmpty {
            await feeEstimator(for: directory).recordBlock(height: prepared.blockHeight, transactionFees: prepared.txFees)
        }

        await subscriptions.emit(.newBlock(
            hash: prepared.blockHash,
            height: prepared.blockHeight,
            directory: directory,
            timestamp: prepared.blockTimestamp
        ))

        metrics.increment("lattice_blocks_accepted_total")
        metrics.set("lattice_chain_height{chain=\"\(directory)\"}", value: Double(prepared.blockHeight))
    }

    /// Durable-side reorg guard for the ordinary apply path. A short fork can
    /// overwrite `block_index[height]` without going through the explicit
    /// multi-block transition publisher; transactions from the replaced block
    /// must be re-admitted if the new canonical state did not confirm them.
    private func recoverTransactionsFromReplacedCanonicalBlock(
        oldBlockHash: String,
        newTxCIDs: Set<String>,
        directory: String
    ) async {
        guard let store = stateStores[chainKey(forDirectory: directory)],
              let network = network(for: directory) else { return }
        let log = NodeLogger("reorg")
        let source = await buildMempoolAwareSource(directory: directory, baseFetcher: network.ivyFetcher)
        let oldStub = VolumeImpl<Block>(rawCID: oldBlockHash, node: nil, encryptionInfo: nil)
        guard let oldBlock = try? await oldStub.resolve(source: source).node else {
            log.error("\(directory): replaced canonical block \(String(oldBlockHash.prefix(16)))… missing during mempool recovery")
            return
        }
        let oldTxEntries = await resolveBlockTransactions(block: oldBlock, source: source)
        let orphaned = oldTxEntries.values.filter { !newTxCIDs.contains($0.rawCID) }
        guard !orphaned.isEmpty else { return }

        do {
            try await store.deleteReceiptsForOrphanedTxCIDs(Set(orphaned.map(\.rawCID)))
        } catch {
            log.error("\(directory): failed to delete stale receipts for replaced block \(String(oldBlockHash.prefix(16)))…: \(error)")
        }

        var senders = Set<String>()
        var txs: [Transaction] = []
        txs.reserveCapacity(orphaned.count)
        for txHeader in orphaned {
            guard let tx = txHeader.node,
                  let body = tx.body.node else { continue }
            if body.fee == 0 && body.nonce == oldBlock.height { continue }
            // Reset the confirmed-nonce floor for EVERY signer (parity with the
            // transition path's recoverOrphanedTransactions, BlockReorg.swift ~397),
            // not just signers.first: a multi-signer orphaned tx otherwise leaves a
            // co-signer's floor too high, stranding the re-admitted tx (it can never
            // be reselected). resetConfirmedNoncesAfterReorg is monotonic:false, so
            // adding more signers to the reset set is strictly safe.
            for sender in body.signers where !sender.isEmpty {
                senders.insert(sender)
            }
            txs.append(tx)
        }

        if !senders.isEmpty {
            var nonceResets: [(sender: String, nonce: UInt64)] = []
            for sender in senders.sorted() {
                if let nonce = try? await getNonce(address: sender, directory: directory) {
                    nonceResets.append((sender: sender, nonce: nonce))
                }
            }
            await network.nodeMempool.resetConfirmedNoncesAfterReorg(updates: nonceResets)
        }

        var recovered = 0
        for tx in txs {
            // Reorg recovery: a withdrawal whose matching deposit lived in the
            // replaced block re-confirms shortly. Tolerate that ONE typed failure
            // via the admission seam (allowWithdrawalWithoutDeposit) so the tx still
            // gets confirmed-balance + sender-debit threaded into the cumulative
            // double-spend bound — never the raw addTransaction bypass.
            switch await admitToMempool(transaction: tx, directory: directory, allowWithdrawalWithoutDeposit: true) {
            case .added, .replacedExisting:
                recovered += 1
            case .rejected(let reason):
                log.info("\(directory): replaced-block tx \(String(tx.body.rawCID.prefix(16)))… not recovered: \(reason)")
            }
        }
        if recovered > 0 {
            log.info("\(directory): recovered \(recovered) tx(s) from replaced canonical block \(String(oldBlockHash.prefix(16)))…")
        }
    }

    /// Parent state root continuity for child chains is checked against verified
    /// parent `prevState -> postState` edges. A parent block does not need to
    /// contain a child block to contribute one of those edges, so every accepted
    /// parent block records its transition for each direct child. This persists
    /// only state-root edges, not parent block bodies or parent fork choice.
    func persistParentStateEdgesForChildContinuity(
        parentDirectory: String,
        block: Block,
        blockHash: String
    ) async {
        let anchor = ParentAnchor(
            blockHash: blockHash,
            parentHash: block.parent?.rawCID,
            height: block.height,
            prevStateCID: block.prevState.rawCID
        )
        let childDirectories = networks.values
            .filter { $0.parentDirectory == parentDirectory }
            .map(\.directory)
        for childDirectory in childDirectories {
            await persistVerifiedParentHeaderEdge(directory: childDirectory, anchor: anchor)
            await persistVerifiedParentStateEdge(directory: childDirectory, parentBlock: block)
        }
    }
    /// M6: how many recent heights of own-tx pins to retain. Own-tx pins
    /// (`account:<ns>:txwindow:<height>`) survive ordinary FIFO eviction so the
    /// node can always serve its own RECENT tx history, but for a high-volume
    /// address (coinbase/faucet/exchange) keeping every height forever grows
    /// roughly with chain length. Bounding the retained set to the most recent
    /// `ownTxPinWindow` heights keeps growth bounded while still serving recent
    /// history; older own-tx pins fall out of the window and are released.
    var ownTxPinWindow: UInt64 { config.tuning.storage.ownTxPinWindow }

    /// Per-height owner for own-tx pins, so a whole height can be released as a
    /// unit once it falls out of `ownTxPinWindow`.
    static func ownTxPinOwner(ownerNamespace: String, height: UInt64) -> String {
        "account:\(ownerNamespace):txwindow:\(height)"
    }

    /// Pin transaction and body CIDs for transactions that involve our account.
    /// These pins are not subject to FIFO eviction so the node can serve data
    /// related to its own address, but they are bounded to the most recent
    /// `ownTxPinWindow` heights (M6) rather than retained forever. The full block
    /// header is intentionally NOT pinned per own-tx block — only the tx and body
    /// CIDs needed to serve our own tx history — to avoid header retention scaling
    /// with own-tx-bearing block count.
    func pinAccountData(
        blockHash: String,
        blockHeight: UInt64,
        txEntries: [String: VolumeImpl<Transaction>],
        txHistoryEntries: [(address: String, txCID: String, blockHash: String, height: UInt64)],
        directory: String
    ) async {
        // Collect txCIDs that involve our address
        let myTxCIDs = Set(txHistoryEntries.filter { $0.address == nodeAddress }.map(\.txCID))
        guard !myTxCIDs.isEmpty, let network = network(for: directory) else { return }

        var cidsToPin: [String] = []
        for (_, txHeader) in txEntries {
            let txCID = txHeader.rawCID
            guard myTxCIDs.contains(txCID) else { continue }
            cidsToPin.append(txCID)
            if let bodyCID = txHeader.node?.body.rawCID, !bodyCID.isEmpty {
                cidsToPin.append(bodyCID)
            }
        }
        guard !cidsToPin.isEmpty else { return }

        // Pin under a per-height owner so the window's tail can be released as a
        // unit (P-304: use pinBatch). The data survives ordinary eviction.
        let pinOwner = Self.ownTxPinOwner(ownerNamespace: network.ownerNamespace, height: blockHeight)
        try? await network.pinBatchDurably(roots: cidsToPin, owner: pinOwner)

        // M6: release own-tx pins for the height that just fell out of the window.
        // `unpinAllDurably` is idempotent — a height with no own-tx pins (or one
        // already released by a prior apply at this height) is a no-op.
        if blockHeight >= ownTxPinWindow {
            let evictHeight = blockHeight - ownTxPinWindow
            let evictOwner = Self.ownTxPinOwner(ownerNamespace: network.ownerNamespace, height: evictHeight)
            try? await network.unpinAllDurably(owner: evictOwner)
        }

        // Announce so peers can discover us as a provider of our own tx data.
        let fee = await network.ivy.config.relayFee * 2
        let expiry = UInt64(Date().timeIntervalSince1970) + config.pinAnnounceExpiry
        await withTaskGroup(of: Void.self) { group in
            for cid in cidsToPin {
                group.addTask {
                    await network.announce(cid: cid, expiry: expiry, fee: fee)
                }
            }
        }
    }
    func extractStateChangeset(
        block: Block,
        blockHash: String,
        txEntries: [String: VolumeImpl<Transaction>]
    ) -> (changeset: StateChangeset, mempoolNonceUpdates: [(sender: String, nonce: UInt64)]) {
        // Produce (sender, nextNonce) pairs for mempool confirmedNonce sync.
        // AccountState tree stores `last-used` nonce; mempool stores `next-to-use`.
        // consensus advances EVERY signer's nonce-tracking key when a
        // multi-signer tx applies (Lattice AccountState.proveAndUpdateState), so
        // the mempool floor must advance for every signer, not only signers.first.
        var maxSignedNonce: [String: UInt64] = [:]
        var signerOrder: [String] = []
        for (_, txHeader) in txEntries {
            guard let body = txHeader.node?.body.node else { continue }
            let signers = body.signers.isEmpty ? [""] : body.signers
            for sender in Set(signers) {
                if maxSignedNonce[sender] == nil {
                    signerOrder.append(sender)
                    maxSignedNonce[sender] = body.nonce
                } else if body.nonce > maxSignedNonce[sender]! {
                    maxSignedNonce[sender] = body.nonce
                }
            }
        }

        let mempoolNonceUpdates: [(sender: String, nonce: UInt64)] = signerOrder.compactMap {
            let maxNonce = maxSignedNonce[$0]!
            let (next, overflow) = maxNonce.addingReportingOverflow(1)
            guard !overflow else { return nil }
            return (sender: $0, nonce: next)
        }

        let changeset = StateChangeset(
            height: block.height,
            blockHash: blockHash,
            stateRoot: block.postState.rawCID
        )
        return (changeset, mempoolNonceUpdates)
    }
    /// Build receipt index entries and tx history concurrently.
    /// Each transaction's receipt is independent — JSON encoding runs in parallel via TaskGroup.
    nonisolated func buildReceiptsParallel(
        txEntries: [String: VolumeImpl<Transaction>],
        blockHash: String,
        blockHeight: UInt64,
        blockTimestamp: Int64
    ) async -> (
        generalEntries: [(key: String, value: Data, height: UInt64)],
        txHistory: [(address: String, txCID: String, blockHash: String, height: UInt64)]
    ) {
        struct TxReceiptData: Sendable {
            let generalEntries: [(key: String, value: Data, height: UInt64)]
            let txHistory: [(address: String, txCID: String, blockHash: String, height: UInt64)]
        }

        let txList = Array(txEntries)

        // Process transactions in parallel — each receipt is independent.
        // Sequential fast-path for small blocks: TaskGroup setup overhead (~20μs)
        // exceeds the parallelism benefit when there are only a few transactions.
        guard txList.count > 4 else {
            var allGeneral: [(key: String, value: Data, height: UInt64)] = []
            var allTxHistory: [(address: String, txCID: String, blockHash: String, height: UInt64)] = []
            allGeneral.reserveCapacity(txList.count * 2)
            allTxHistory.reserveCapacity(txList.count)
            for (_, txHeader) in txList {
                let txCID = txHeader.rawCID
                struct ReceiptIdx: Codable { let blockHash: String; let blockHeight: UInt64 }
                if let idxData = try? Self.receiptEncoder.encode(ReceiptIdx(blockHash: blockHash, blockHeight: blockHeight)) {
                    allGeneral.append((key: "receipt-idx:\(txCID)", value: idxData, height: blockHeight))
                }
                if let tx = txHeader.node, let body = tx.body.node {
                    var actions: [TransactionReceipt.ReceiptAction] = []
                    actions.reserveCapacity(body.accountActions.count)
                    for action in body.accountActions {
                        allTxHistory.append((address: action.owner, txCID: txCID, blockHash: blockHash, height: blockHeight))
                        actions.append(TransactionReceipt.ReceiptAction(owner: action.owner, delta: action.delta))
                    }
                    let receipt = TransactionReceipt(txCID: txCID, blockHash: blockHash, blockHeight: blockHeight,
                        timestamp: blockTimestamp, fee: body.fee, sender: body.signers.first ?? "",
                        status: "confirmed", accountActions: actions)
                    if let data = try? Self.receiptEncoder.encode(receipt) {
                        allGeneral.append((key: "receipt:\(txCID)", value: data, height: blockHeight))
                    }
                }
            }
            return (generalEntries: allGeneral, txHistory: allTxHistory)
        }

        // Note: dict keys are sequential indices ("0","1",...) — use rawCID for receipt indexing.
        let results: [TxReceiptData] = await withTaskGroup(of: TxReceiptData.self) { group in
            for (_, txHeader) in txList {
                let txCID = txHeader.rawCID
                group.addTask {
                    var generalEntries: [(key: String, value: Data, height: UInt64)] = []
                    var txHistory: [(address: String, txCID: String, blockHash: String, height: UInt64)] = []

                    struct ReceiptIdx: Codable { let blockHash: String; let blockHeight: UInt64 }
                    if let idxData = try? Self.receiptEncoder.encode(ReceiptIdx(blockHash: blockHash, blockHeight: blockHeight)) {
                        generalEntries.append((key: "receipt-idx:\(txCID)", value: idxData, height: blockHeight))
                    }

                    if let tx = txHeader.node, let body = tx.body.node {
                        // Single iteration: build both txHistory and receipt actions
                        var actions: [TransactionReceipt.ReceiptAction] = []
                        actions.reserveCapacity(body.accountActions.count)
                        for action in body.accountActions {
                            txHistory.append((address: action.owner, txCID: txCID, blockHash: blockHash, height: blockHeight))
                            actions.append(TransactionReceipt.ReceiptAction(owner: action.owner, delta: action.delta))
                        }
                        let receipt = TransactionReceipt(
                            txCID: txCID, blockHash: blockHash, blockHeight: blockHeight,
                            timestamp: blockTimestamp, fee: body.fee,
                            sender: body.signers.first ?? "", status: "confirmed",
                            accountActions: actions
                        )
                        if let data = try? Self.receiptEncoder.encode(receipt) {
                            generalEntries.append((key: "receipt:\(txCID)", value: data, height: blockHeight))
                        }
                    }

                    return TxReceiptData(generalEntries: generalEntries, txHistory: txHistory)
                }
            }

            var collected: [TxReceiptData] = []
            collected.reserveCapacity(txList.count)
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        // Merge results — pre-allocate since each tx produces ~2 general + ~1 history entries
        var allGeneral: [(key: String, value: Data, height: UInt64)] = []
        allGeneral.reserveCapacity(txList.count * 2)
        var allTxHistory: [(address: String, txCID: String, blockHash: String, height: UInt64)] = []
        allTxHistory.reserveCapacity(txList.count)
        for result in results {
            allGeneral.append(contentsOf: result.generalEntries)
            allTxHistory.append(contentsOf: result.txHistory)
        }
        return (generalEntries: allGeneral, txHistory: allTxHistory)
    }
    // MARK: - Child Block Gossip (Phase 3 per-process)

    /// Outcome of the childBlock gossip relay gate. `.admit` means the block
    /// proceeds to verification/relay; the others short-circuit before any disk
    /// write, pin, DHT announce, or re-broadcast.
    enum ChildBlockRelayGate: Equatable {
        case admit
        case rateLimited
        case duplicate
    }

    /// (H8): apply the same front-of-path guards the `newBlock` gossip
    /// path uses (`didReceiveBlock` :287-303) before a childBlock is relayed.
    /// Without this, `didReceiveChildBlock` would disk-write + pin + DHT-announce
    /// + broadcast-to-all (including the sender) on every hop, so a single block
    /// ping-pongs A→B→A indefinitely. Reuses the existing per-peer rate primitive
    /// (`isPeerBlockRateLimited`, backed by Tally-style counting) and the existing
    /// 100ms recent-CID dedup window — no new state is introduced.
    ///
    /// This is a pure CHECK and must NOT prime the dedup window. Priming a CID as
    /// "seen" happens only AFTER the payload parses and `blockCIDMatches` confirms
    /// the bytes genuinely are that CID's block (see `recordChildBlockSeen`).
    /// Otherwise a peer could send malformed data — or a mismatched block — under a
    /// real childBlock's CID, prime `recentBlockTime` for that CID, and have the
    /// subsequent VALID packet from another peer classified `.duplicate` and
    /// dropped, suppressing the real block (DoS).
    func childBlockRelayGate(cid: String, peer: PeerID, now: ContinuousClock.Instant) -> ChildBlockRelayGate {
        if isPeerBlockRateLimited(peer) { return .rateLimited }
        if let lastSeen = recentBlockTime(for: cid), now - lastSeen < blockDeduplicationWindow {
            return .duplicate
        }
        return .admit
    }

    /// Prime the dedup window for `cid`. Call this ONLY after the payload has
    /// parsed and `blockCIDMatches` has confirmed the bytes are genuinely that
    /// block, so unvalidated/forged bytes can never suppress the real block.
    func recordChildBlockSeen(cid: String, now: ContinuousClock.Instant) {
        recordBlockTime(key: cid, time: now)
    }

    // Receives a child chain block gossiped with sparse proof paths. Each carrier
    // root hash is derived from its proof root, so the wire does not trust a
    // separately advertised rootHash.
    nonisolated public func chainNetwork(
        _ network: ChainNetwork,
        didReceiveChildBlock cid: String,
        data: Data,
        proofs: [ChildBlockProof],
        from peer: PeerID
    ) async {
        let directory = network.directory
        let tally = await network.ivy.tally
        // bound the gossiped payload at the earliest node-controlled point —
        // before the relay gate, any CAS write, or re-broadcast — mirroring the
        // `newBlock` block-size cap (LatticeNode+Blocks.swift :283). Reuses the spec's
        // size policy (`maxBlockSize`): the inline block must fit the block cap, and
        // the inline work proof is bounded by `maxProofSize` (one block-equivalent per
        // hop on the RECEIVING chain's path — see `maxProofSize`). An attacker-sized
        // inline proof is rejected + the peer penalized before it is stored or relayed.
        // Fail closed.
        if data.count > genesisConfig.spec.maxBlockSize {
            tally.recordFailure(peer: peer)
            return
        }
        let proofEnvelopeSize = proofs.isEmpty ? 0 : ChildBlockProofEnvelope.serialize(proofs).count
        if proofEnvelopeSize > Self.maxProofSize(pathDepth: network.chainPath.count, spec: genesisConfig.spec) {
            tally.recordFailure(peer: peer)
            return
        }
        // dedup + per-peer rate-limit CHECK BEFORE any relay-triggering work.
        let now = ContinuousClock.Instant.now
        guard await childBlockRelayGate(cid: cid, peer: peer, now: now) == .admit else { return }
        guard let block = Block(data: data) else { return }
        guard ChainNetwork.blockCIDMatches(cid, block: block) else {
            NodeLogger("blocks").warn("\(directory): childBlock CID mismatch for advertised \(String(cid.prefix(16)))…")
            return
        }
        // Verify proof: ensures the block is legitimately embedded under
        // its derived carrier root via the full path root → … → this chain's block. Bind the proof
        // to the RECEIVING network's own chainPath (which encodes the complete
        // ancestry, so same-leaf-name COUSINS at different levels — ["MidB","Stable"]
        // vs ["MidA","Stable"] — are distinct). The proof's root-exclusive path must
        // match exactly, so a sibling/cousin chain's proof can't be replayed here.
        guard !proofs.isEmpty else {
            NodeLogger("blocks").warn("\(directory): childBlock missing proof for \(String(cid.prefix(16)))…")
            return
        }
        // Only now that the bytes are confirmed to genuinely be this CID's block,
        // and a proof envelope is present do we prime the dedup window. Invalid
        // PoW/malformed packets cannot suppress a later valid relay; duplicate
        // valid-work packets avoid repeated proof walks.
        await recordChildBlockSeen(cid: cid, now: now)
        var verified: [(proof: ChildBlockProof, anchor: ParentAnchor, rootHash: UInt256)] = []
        for proof in proofs {
            guard let root = await proof.anchorRoot(),
                  let anchor = await verifiedCommittingParentAnchor(
                    directory: directory,
                    chainPath: network.chainPath,
                    childBlock: block,
                    childCID: cid,
                    proof: proof
                  ) else { continue }
            verified.append((proof: proof, anchor: anchor, rootHash: root.hash))
        }
        verified.sort {
            if $0.anchor != $1.anchor {
                return ParentAnchor.canonicalSelectionLess($0.anchor, $1.anchor)
            }
            return $0.proof.canonicalProofID < $1.proof.canonicalProofID
        }
        guard !verified.isEmpty else {
            // debug, not warn: no proof yielded a verified committing parent anchor. This
            // is NORMAL when this node isn't the parent producer that commits the child
            // (e.g. a single miner merge-mining a child on live mainnet Nexus it follows
            // but doesn't win blocks on) — the child still advances on its own PoW; only
            // parent-anchoring is deferred. The block is still fail-closed (rejected).
            // A genuinely malformed/absent proof is caught earlier and stays at warn.
            NodeLogger("blocks").debug("\(directory): childBlock proof verification failed for \(String(cid.prefix(16)))…")
            return
        }
        let parentAnchor = await selectChildParentAnchor(
            directory: directory,
            blockHash: cid,
            block: block,
            candidates: verified.map(\.anchor)
        )
        guard let parentAnchor,
              let processingRootHash = verified.first(where: { $0.anchor.blockHash == parentAnchor.blockHash })?.rootHash else {
            NodeLogger("blocks").warn("\(directory): childBlock has no continuity-compatible parent anchor for \(String(cid.prefix(16)))…")
            return
        }

        do {
            try await network.storeVolumeDurably(SerializedVolume(root: cid, entries: [cid: data]))
        } catch {
            NodeLogger("blocks").error("\(directory): failed to stage verified childBlock \(String(cid.prefix(16)))… before durable validation: \(error)")
            return
        }

        let header = VolumeImpl<Block>(rawCID: cid)
        let baseFetcher = network.ivyFetcher
        let proofEntries = verified.reduce(into: [String: Data]()) { map, item in
            for entry in item.proof.entries {
                map[entry.cid] = entry.data
            }
        }
        // Native wave-batched validation base source (#287): proof-entry overlay
        // over `network.ivyFetcher` (== baseFetcher). The block-processing entry
        // takes a `Fetcher`, so wrap the source in a `CoalescingFetcher` —
        // byte-identical to the retired per-CID proof-entry overlay over
        // `baseFetcher`.
        let validationBaseSource = OverlayContentSource(
            entries: proofEntries,
            fallback: IvyContentSource(baseFetcher)
        )
        let fetcher: Fetcher = CoalescingFetcher(validationBaseSource)
        await baseFetcher.bindPinner(rootCID: cid, peer: peer)
        await baseFetcher.bindBlockRoots(block, peer: peer)
        await recordPeerTip(chainPath: network.chainPath, peerKey: peer.publicKey, tipCID: cid, height: block.height)
        for item in verified {
            await preloadInheritedWeight(directory: directory, blockHash: cid, proof: item.proof)
        }
        let outcome = await processBlockAndRecoverReorg(
            header: header, directory: directory, fetcher: fetcher,
            resolvedBlock: block, rootHash: processingRootHash, parentAnchor: parentAnchor,
            requireDurableResolvedBlock: true,
            baseValidationSourceOverride: validationBaseSource
        )
        if outcome == .accepted || outcome == .duplicate {
            // F5-4: store the (already-verified) sparse work proof as block metadata
            // so this node can serve/push it to children and answer sync. For a
            // direct child of the PoW root this single-hop proof IS the full path to
            // the root; grandchildren get their composed full path via the parent-
            // chain relay.
            for item in verified {
                await persistAcceptedBlockProof(directory: directory, height: block.height, blockHash: cid, proof: item.proof)
            }
            // F5-4: fold this block's verified inherited (parent-chain) work into the
            // accumulator and re-run fork choice so its securing weight counts.
            for item in verified {
                guard await applyInheritedWeight(directory: directory, blockHash: cid, proof: item.proof, source: validationBaseSource) else {
                    return
                }
            }
            if outcome == .accepted {
                await publishAcceptedBlock(
                    block: block,
                    cid: cid,
                    data: data,
                    network: network,
                    childRelayRootHash: processingRootHash,
                    childRelayProofs: verified.map(\.proof),
                    announceCurrentTipWhenNotPromoted: true
                )
            } else {
                // Duplicate delivery may still have folded NEW inherited weight
                // above — keep the tip announce so peers see a promotion that the
                // re-delivered proof caused.
                await broadcastCanonicalTipAnnounce(
                    block: block,
                    cid: cid,
                    network: network,
                    announceCurrentTipWhenNotPromoted: true
                )
            }
            await maybePersist(directory: directory)
        } else if outcome == .rejected {
            // A rejection often means we're missing ancestors — trigger sync if
            // the received block is far ahead of our local tip.
            _ = await checkSyncNeeded(peerBlock: block, peerTipCID: cid, network: network)
        } else if outcome == .storageFailed {
            NodeLogger("blocks").error("\(directory): child block \(String(cid.prefix(16)))… was accepted but not durably stored; withholding tip publish")
        }
    }

    // MARK: - Peer Connection (Chain Tip Exchange)
}
