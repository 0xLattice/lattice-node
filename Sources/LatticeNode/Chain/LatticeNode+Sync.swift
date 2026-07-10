import Lattice
import LatticeNodeWire
import Foundation
import Ivy
import Tally
import cashew
import VolumeBroker
import UInt256

func sleepUnlessCancelled(_ duration: Duration) async -> Bool {
    do {
        try await Task.sleep(for: duration)
        return !Task.isCancelled
    } catch {
        return false
    }
}

extension LatticeNode {

    public var isSyncing: Bool {
        !syncTasks.isEmpty || !unhealthyChains.isEmpty
    }

    func isChainSyncing(chainPath: [String]) -> Bool {
        syncTasks[chainKey(forPath: chainPath)] != nil
    }

    func isChainSyncing(directory: String) -> Bool {
        isChainSyncing(chainPath: chainPath(forDirectory: directory))
    }

    func isChainUnhealthy(chainPath: [String]) -> Bool {
        unhealthyChains.contains(chainKey(forPath: chainPath))
    }

    func isChainUnhealthy(directory: String) -> Bool {
        isChainUnhealthy(chainPath: chainPath(forDirectory: directory))
    }

    func isChainUnavailable(chainPath: [String]) -> Bool {
        if isChainUnhealthy(chainPath: chainPath) { return true }
        // Fail closed only for deep/initial syncs (gap unknown = .max). Shallow
        // catch-ups within the finality window keep only that chain readable
        // and mining (the documented shallowSyncThreshold intent);
        // announce-driven gap=1 syncs would otherwise blank reads and stall
        // mining for the whole sync tail. A forged small-gap announcement at
        // worst keeps the node serving its own canonical state.
        let key = chainKey(forPath: chainPath)
        return syncTasks[key] != nil
            && (activeSyncGaps[key] ?? UInt64.max) > shallowSyncThreshold
    }

    func isChainUnavailable(directory: String) -> Bool {
        isChainUnavailable(chainPath: chainPath(forDirectory: directory))
    }

    func updateSyncActiveMetric() {
        metrics.set("lattice_sync_active", value: syncTasks.isEmpty ? 0 : 1)
    }

    // Ethereum go-ethereum uses 32 blocks before handing off to the downloader.
    // Gaps ≤ this are handled by direct gossip block acceptance; gaps > this
    // trigger headersFirst sync. Raising from 2→32 matches SOTA and avoids
    // triggering expensive syncs for small natural variance between peers.
    var catchUpSyncThreshold: UInt64 { config.tuning.sync.catchUpThreshold }

    // Syncs within this gap are considered shallow: mining stays running since
    // the reorg will be tiny and the finality window (1000 blocks) is not at risk.
    var shallowSyncThreshold: UInt64 { config.tuning.sync.shallowThreshold }

    /// A node that owns the ROOT chain receives child blocks only through the
    /// per-process candidate/submit pipeline (chain/submit-child-block forwarding
    /// to the owning child process) — it must never headers-first-sync a child
    /// path from a peer: the child PoW lives on a cross-chain anchor path, and
    /// the proof-carrying sync path would loop on a peer's bare child headers.
    /// Per-process child nodes don't own the root and sync their chain normally.
    /// (Named for the historical in-process mode; the guard's effect — root
    /// owners never child-sync — is unchanged under per-process.)
    func producesChildInProcess(network: ChainNetwork) -> Bool {
        guard network.chainPath.count >= 2, let root = network.chainPath.first else { return false }
        return self.network(forPath: [root]) != nil
    }

    /// Lightweight sync check used when block data isn't available yet —
    /// only checks height gap (no work comparison, no PoW check).
    func checkSyncNeeded(
        peerBlock: Block?,
        peerTipCID: String,
        peerHeight: UInt64,
        network: ChainNetwork,
        sourcePeer: PeerID? = nil,
        announceOnly: Bool = false
    ) async -> Bool {
        guard !producesChildInProcess(network: network) else { return false }
        // No block data here — the announced (cid, height) is entirely
        // unvalidated, so it must NOT be recorded into knownPeerTips: a forged
        // announcement would poison best-peer/best-tip sync selection. Tips are
        // recorded on the full-block path after PoW validation; the sync started
        // below still targets sourcePeer directly for the immediate attempt.
        let syncKey = chainKey(forPath: network.chainPath)
        guard syncTasks[syncKey] == nil else { return true }
        guard let chainState = await chain(forPath: network.chainPath) else { return false }
        let localHeight = await chainState.getHighestBlockHeight()
        let gap = peerHeight > localHeight ? peerHeight - localHeight : 0
        let localTip = await chainState.getMainChainTip()
        // Exact ties hold the incumbent — only a higher peer tip (gap > 0) is
        // worth an announce-driven sync; equal-height siblings are not adopted.
        let shouldSync = SyncPolicy.heightGapTrigger(gap: gap, announceOnly: announceOnly, catchUpThreshold: catchUpSyncThreshold)
        guard shouldSync else { return false }
        guard !isRefusedSyncTip(peerTipCID, localTip: localTip) else { return false }
        guard syncTasks[syncKey] == nil else { return true }
        startSync(peerTipCID: peerTipCID, network: network, gap: gap, sourcePeer: sourcePeer, peerTipHeight: peerHeight)
        return true
    }

    func checkSyncNeeded(
        peerBlock: Block,
        peerTipCID: String,
        network: ChainNetwork,
        sourcePeer: PeerID? = nil
    ) async -> Bool {
        guard !producesChildInProcess(network: network) else { return false }
        if let sourcePeer {
            recordPeerTip(chainPath: network.chainPath, peerKey: sourcePeer.publicKey, tipCID: peerTipCID, height: peerBlock.height)
        }
        let syncKey = chainKey(forPath: network.chainPath)
        guard syncTasks[syncKey] == nil else { return true }
        guard let chainState = await chain(forPath: network.chainPath) else { return false }
        let localHeight = await chainState.getHighestBlockHeight()
        let gap = peerBlock.height > localHeight ? peerBlock.height - localHeight : 0

        // Nakamoto consensus: the canonical chain is the one with the most
        // cumulative proof-of-work, not necessarily the longest by block count.
        // Trigger a sync if EITHER:
        //   1. The peer is significantly ahead by height (normal catch-up), OR
        //   2. The peer appears to have more cumulative work even at equal/lower
        //      height — this handles forks where one branch mined harder blocks.
        guard peerBlock.target > UInt256.zero else { return false }
        let localWork = await localCumulativeWork(chainPath: network.chainPath)
        let peerWorkPerBlock = workForTarget(peerBlock.target)
        let peerChainDepth = UInt256(peerBlock.height + 1)
        let estimatedPeerWork = peerWorkPerBlock * peerChainDepth

        // Exact ties hold the incumbent (docs/protocol.md §fork-choice): only a
        // STRICTLY heavier fork is worth syncing. Equal-work siblings are never
        // adopted on receipt — the next extending block breaks the tie and the
        // network converges, so there is no permanent-fork hazard while mining.
        let localTip = await chainState.getMainChainTip()

        // Ahead-by-height OR heavier-even-at-lower-height, with a root-only own-work
        // veto (a child's real weight is inherited securing work, decided at
        // admission after its proofs are verified). See SyncPolicy.workAwareTrigger.
        guard SyncPolicy.workAwareTrigger(
            gap: gap,
            catchUpThreshold: catchUpSyncThreshold,
            localWork: localWork,
            estimatedPeerWork: estimatedPeerWork,
            peerWorkPerBlock: peerWorkPerBlock,
            isRootChain: network.chainPath.count == 1
        ) else { return false }

        // A tip we already fully synced and refused stays refused while our own
        // tip is unchanged — re-syncing it every announce round is pure churn.
        guard !isRefusedSyncTip(peerTipCID, localTip: localTip) else { return false }

        // Re-check: another task may have started a sync during our awaits above.
        guard syncTasks[syncKey] == nil else { return true }
        startSync(peerTipCID: peerTipCID, network: network, gap: gap, sourcePeer: sourcePeer, peerTipHeight: peerBlock.height)
        return true
    }

    var syncTimeout: Duration { config.tuning.sync.timeout }

    func startSync(peerTipCID: String, network: ChainNetwork, gap: UInt64 = UInt64.max, sourcePeer: PeerID? = nil, peerTipHeight: UInt64? = nil, retryCount: Int = 0) {
        let syncKey = chainKey(forPath: network.chainPath)
        guard syncTasks[syncKey] == nil else { return }
        let syncTimeout = self.syncTimeout
        activeSyncGaps[syncKey] = gap
        let task = Task { [weak self] in
            guard let self = self else { return }
            // Race the sync against the timeout; the winner's ChainOutcome (nil = the
            // timeout fired first) drives the retry decision below.
            let outcome: ChainOutcome? = await withTaskGroup(of: ChainOutcome?.self) { group in
                group.addTask {
                    await self.performHeadersFirstSync(
                        peerTipCID: peerTipCID,
                        network: network,
                        sourcePeer: sourcePeer,
                        peerTipHeight: peerTipHeight
                    )
                }
                group.addTask {
                    _ = await sleepUnlessCancelled(syncTimeout)
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            if Task.isCancelled {
                let log = NodeLogger("sync")
                log.warn("Sync timed out — will retry on next peer block")
            }

            // Transient-failure retry, driven by the sync OUTCOME (not height). A sync
            // that downloaded a strictly-heavier peer chain but could not materialize
            // its content — e.g. the source peer JUST restarted (a partition heal) and
            // was not serving its volumes yet — returns `.pendingUnavailable`. The
            // trigger to retry is normally "next peer block / new announcement", but an
            // announce-driven target is not recorded in `knownPeerTips` (unvalidated),
            // and a stopped/idle source never re-announces — so the node would wait
            // forever on a gap one fetch from closing. Crucially, the peer can be
            // strictly heavier at the SAME or LOWER height (work-aware fork choice), so
            // a height-gated retry would miss it entirely. Re-attempt the SAME target
            // with bounded backoff while the outcome is retriable-transient (a content
            // miss or a timeout, `outcome == nil`); a genuinely-unreachable peer simply
            // exhausts the budget. TERMINAL outcomes stop: `.adopted` (done),
            // `.ignoredLighter` (work-refused — retrying is churn), `.invalid` (bad
            // data), `.degraded` (local failure — not fixable by waiting).
            // The `!isChainUnhealthy` guard closes the timeout-race edge (M1): if the
            // sync and the timeout complete near-simultaneously, `group.next()` can
            // surface the timeout's `nil` and mask a real `.degraded` outcome — whose
            // markChain* already called `network.stop()`. Without this guard the retry
            // would re-run against a deliberately-stopped/unhealthy chain.
            if (outcome?.isRetriableTransient ?? true), retryCount < Self.maxSyncRetries, !Task.isCancelled,
               !(await self.isChainUnhealthy(chainPath: network.chainPath)) {
                await self.clearSyncTaskForRetry(network: network)
                let backoffSeconds = UInt64(min(30, 1 << min(retryCount, 5)))   // 1,2,4,8,16,30…
                guard await sleepUnlessCancelled(.seconds(backoffSeconds)) else { return }
                await self.startSync(peerTipCID: peerTipCID, network: network, gap: gap, sourcePeer: sourcePeer, peerTipHeight: peerTipHeight, retryCount: retryCount + 1)
                return
            }
            await self.clearSyncTask(completedNetwork: network)
        }
        syncTasks[syncKey] = task
        updateSyncActiveMetric()
    }

    /// Clear just enough sync-task state to re-arm a transient-failure retry
    /// (see `startSync`) without running `clearSyncTask`'s post-sync re-broadcast
    /// + known-peer re-check, which would race the pending backoff retry.
    func clearSyncTaskForRetry(network: ChainNetwork) {
        let syncKey = chainKey(forPath: network.chainPath)
        syncTasks[syncKey] = nil
        activeSyncGaps.removeValue(forKey: syncKey)
        updateSyncActiveMetric()
    }

    /// Bounded transient-sync-failure retries (see `startSync`): enough backoff
    /// budget (1+2+4+8+16+30×… ≈ a couple minutes) to outlast a source peer
    /// coming back up after a restart, without retrying a truly-dead peer forever.
    static let maxSyncRetries = 8

    func clearSyncTask(completedNetwork: ChainNetwork? = nil) async {
        if let completedNetwork {
            let syncKey = chainKey(forPath: completedNetwork.chainPath)
            syncTasks[syncKey] = nil
            activeSyncGaps.removeValue(forKey: syncKey)
        } else {
            syncTasks.removeAll()
            activeSyncGaps.removeAll()
        }
        syncOutcomes.clearFailed()
        updateSyncActiveMetric()

        // Replay gossip blocks that arrived while sync was running. These were
        // cached per-chain (keyed by ChainNetwork identity) rather than discarded
        // so that a node that syncs to height N while the peer mines to N+17 can
        // apply the buffered gossip immediately without a redundant sync.
        let buffered: [ObjectIdentifier: [PendingGossipBlock]]
        if let completedNetwork {
            let completedID = ObjectIdentifier(completedNetwork)
            buffered = pendingGossipBlocks.removeValue(forKey: completedID).map { [completedID: $0] } ?? [:]
        } else {
            buffered = pendingGossipBlocks
            pendingGossipBlocks.removeAll()
        }

        // Replay buffered gossip blocks first — they extend the chains already
        // synced, and the peer-tip check below handles chains that were
        // announced but not yet synced (e.g. child chains). This is deliberately
        // structured in the clearing task so stop/cancel observes the replay.
        for (_, blocks) in buffered {
            for entry in blocks {
                // Internal re-delivery, not a fresh network arrival: drop the
                // gossip-dedup timestamp first, or a sync that completes inside
                // blockDeduplicationWindow dedup-drops its own buffered blocks.
                clearBlockTime(key: entry.cid)
                await chainNetwork(entry.network, didReceiveBlock: entry.cid, data: entry.data, from: entry.peer)
            }
        }
        // Active reconciliation: after syncing to the best tip we knew about,
        // announce that resulting tip. Any peer still ahead already responds
        // with its higher tip, closing the race where final announcements arrive
        // during the just-finished sync or are missed by the data channel.
        if let completedDirectory = completedNetwork?.directory {
            await broadcastChainTip(directory: completedDirectory)
            guard await sleepUnlessCancelled(.milliseconds(500)) else { return }
            await broadcastChainTip(directory: completedDirectory)
            guard await sleepUnlessCancelled(.milliseconds(500)) else { return }
        }
        // Re-check all known peer tips. Chain announcements that arrived during
        // sync or in response to the post-sync heartbeat are recorded in
        // knownPeerTips; snapshot after the heartbeat retry window so the final
        // mined tip cannot be stranded behind the pre-broadcast snapshot.
        let peerTips = knownPeerTips
        // Check all recorded peer tips for any chain still behind.
        for (pathKey, tips) in peerTips {
            guard syncTasks[pathKey] == nil else { continue }
            let chainPath = pathKey.split(separator: "/").map(String.init)
            guard let network = network(forPath: chainPath) else { continue }
            for (_, entry) in tips {
                guard syncTasks[pathKey] == nil else { break }
                _ = await checkSyncNeeded(
                    peerBlock: nil,
                    peerTipCID: entry.tipCID,
                    peerHeight: entry.height,
                    network: network,
                    announceOnly: true
                )
            }
        }
    }

    /// Returns the terminal `ChainOutcome` of the attempt so `startSync` can decide
    /// whether to retry: `.pendingUnavailable` (content miss / timeout / threw) is
    /// retriable regardless of height; every other outcome is terminal.
    func performHeadersFirstSync(peerTipCID: String, network: ChainNetwork, sourcePeer: PeerID? = nil, peerTipHeight: UInt64? = nil) async -> ChainOutcome {
        let log = NodeLogger("sync")
        log.info("Starting headers-first sync from \(String(peerTipCID.prefix(16)))...")

        let fetcher = network.ivyFetcher
        let headerChain = HeaderChain()
        var attemptedTip = peerTipCID
        var statePrefetchTask: Task<Void, Never>? = nil

        do {
            let localWork = await localCumulativeWork(chainPath: network.chainPath)
            let (activeTip, activeSourcePeer) = await bestConnectedPeerTipWithPeer(
                defaultTipCID: peerTipCID,
                defaultTipHeight: peerTipHeight,
                network: network,
                preferredPeer: sourcePeer
            )
            attemptedTip = activeTip

            // Stateful nodes: warm the tip BLOCK content (header + spec + tx bodies)
            // in parallel with headers, so the recompute that materializes state
            // during sync finds it locally. The state trie itself is NEVER fetched —
            // it is re-executed from these transactions (see
            // materializeSyncedCanonicalContent), so the tip state is available for
            // gossip validation after sync without depending on the source serving
            // the whole historical trie.
            if config.storageMode == .stateful {
                let prefetchSource = IvyContentSource(network.ivyFetcher)
                let tipCIDForPrefetch = activeTip
                statePrefetchTask = Task {
                    _ = try? await VolumeImpl<Block>(rawCID: tipCIDForPrefetch)
                        .resolve(source: prefetchSource).node
                }
            }

            // Child chain (chainPath deeper than the root): headers must arrive with
            // their anchoring proofs and be PoW-verified against the cross-chain root,
            // never self-hashed. expectedChildPath is the proof's root-exclusive path.
            let chainPath = network.chainPath
            let expectedChildPath: [String]? = chainPath.count >= 2 ? Array(chainPath.dropFirst()) : nil
            // Reputation-gated, SHUFFLED, bounded candidate set for the source-agnostic
            // child walk:
            //  - Tally-allowed only — a misbehaving peer is still skipped (audit H1).
            //  - shuffled so the bounded window ROTATES across sync retries: an empty
            //    response/timeout draws no Tally penalty, so without rotation an attacker
            //    holding a fixed front-N of empty-serving peers could stall sync forever
            //    (audit M3). A fresh shuffle each attempt means the honest tail is reached.
            //  - admission-gate only a bounded slice (not every connected peer), so
            //    building the set doesn't spend a Tally request token network-wide and
            //    can't spuriously shrink under load (audit Low). downloadHeaders applies
            //    the final per-batch cap.
            let syncTally = await network.ivy.tally
            // Tally-filter BEFORE slicing so the candidate window is filled with allowed
            // peers, not silently shrunk when disallowed peers land in the shuffled prefix
            // (audit Low). `shouldAllow` is a local in-memory check, so filtering the full
            // set first costs nothing. downloadHeaders applies the final per-batch cap.
            let allowedCandidates = Array((await network.ivy.connectedPeers).shuffled()
                .filter { syncTally.shouldAllow(peer: $0) }
                .prefix(HeaderChain.maxSyncCandidatePeers * 2))
            // Segment-anchored catch-up: hand the walk this node's RETAINED
            // main-chain CIDs as stop points, so it terminates at the fork point
            // instead of walking clear back to genesis. Without this, every sync
            // must download a full genesis-anchored header path — impossible once
            // the chain outgrows any single peer's served window (retention
            // pruning), which froze every follower with genesisMismatch retry
            // loops. Restricting the stop set to the retained window (never the
            // pruned prefix) is what makes the aboveHeight work comparison below
            // sound: the local side of the compare can always be fully summed.
            var knownCIDs: Set<String> = []
            if let localChain = await chain(forPath: network.chainPath) {
                let tipHeight = await localChain.getHighestBlockHeight()
                let contextDepthFloor = ChainSyncer.requiredAnchorContextDepth(
                    retargetWindow: genesisResult.block.spec.node?.retargetWindow ?? 0)
                let floor = Self.anchorableStopFloor(
                    tipHeight: tipHeight,
                    retentionDepth: config.retentionDepth,
                    contextDepth: contextDepthFloor)
                knownCIDs = await localChain.mainChainHashesFrom(index: floor)
            }
            let headers = try await headerChain.downloadHeaders(
                peerTipCID: activeTip,
                fetcher: fetcher,
                genesisBlockHash: genesisResult.blockHash,
                localWork: localWork,
                knownBlockCIDs: knownCIDs,
                network: network,
                sourcePeer: activeSourcePeer,
                candidatePeers: allowedCandidates,
                expectedChildPath: expectedChildPath,
                progress: { current, total in
                    if current % 100 == 0 {
                        log.info("Headers: \(current)/\(total)")
                    }
                }
            )

            // Wait for state prefetch before finalizing so gossip validation
            // has state available immediately after sync completes.
            if let prefetch = statePrefetchTask {
                await prefetch.value
            }

            log.info("Downloaded \(headers.count) headers, applying to chain...")

            // Build SyncResult directly from the downloaded headers rather than
            // re-walking via IvyFetcher. syncSnapshot's second pass re-fetches
            // every block through IvyFetcher → DiskBroker, which fails if any
            // DiskBroker write was lost under load (SQLite I/O error), causing
            // invalidBlock(N). downloadHeaders already verified PoW and state
            // chain continuity — the second pass is pure redundant I/O.
            let syncer = ChainSyncer(
                fetcher: fetcher,
                store: { _, _ in },
                genesisBlockHash: genesisResult.blockHash,
                chainPath: config.fullChainPath ?? [genesisConfig.directory],
                retentionDepth: config.retentionDepth,
                validateBlockConsensus: true
            )
            // If the walk stopped at one of OUR retained main-chain blocks (the
            // fork point), validate the segment against a trusted-local anchor
            // CONTEXT (attach block + enough local ancestors for the retarget/
            // MTP windows) and compare work fork-point-relative: segment work
            // vs local work strictly above the attach point. Comparing a
            // partial segment against the WHOLE local chain would refuse every
            // catch-up (the segment can never outweigh a chain that includes
            // its own shared prefix).
            var knownAnchors: [SyncBlockHeader] = []
            var localWorkForAdmission = Self.syncerWorkFloor(chainPath: network.chainPath, localWork: localWork)
            // downloadHeaders returns OLDEST-FIRST; the attach point is the
            // oldest header's parent.
            if let oldest = headers.first, let anchorCID = oldest.previousBlockCID,
               anchorCID != genesisResult.blockHash, knownCIDs.contains(anchorCID),
               let localChain = await chain(forPath: network.chainPath),
               // CHILD chains anchor only as a pure FAST-FORWARD (attach == the
               // current local tip): a child sync must never decide a REORG on
               // own-target work sums — child-fork weight is trueCumWork
               // (subtree + inherited securing work), owned by gossip fork
               // choice. Appending fully-validated, proof-carrying blocks to
               // our own tip evicts nothing and is exactly the frozen-follower
               // catch-up this path exists for. Root chains keep the fork-point
               // compare (headers are self-PoW-verified there).
               await isAnchorEligible(anchorCID: anchorCID, chainPath: network.chainPath, localChain: localChain) {
                var cursor: String? = anchorCID
                var context: [SyncBlockHeader] = []
                var contextDepth = ChainSyncer.requiredAnchorContextDepth(
                    retargetWindow: genesisResult.block.spec.node?.retargetWindow ?? 0)
                while let cid = cursor, context.count < Int(contextDepth),
                      let block = try? await VolumeImpl<Block>(rawCID: cid).resolve(fetcher: fetcher).node {
                    if context.isEmpty, let attachWindow = block.spec.node?.retargetWindow {
                        // Depth per the ATTACH block's spec (a spec update may
                        // have raised the window since genesis).
                        contextDepth = max(contextDepth, ChainSyncer.requiredAnchorContextDepth(retargetWindow: attachWindow))
                    }
                    context.append(SyncBlockHeader(
                        cid: cid,
                        height: block.height,
                        previousBlockCID: block.parent?.rawCID,
                        target: block.target,
                        nextTarget: block.nextTarget,
                        timestamp: block.timestamp,
                        specCID: block.spec.rawCID,
                        spec: block.spec.node
                    ))
                    cursor = block.parent?.rawCID
                }
                // Only anchor when the context is deep enough for consensus
                // validation of the first segment headers (or reaches genesis):
                // an under-deep context would fail validation anyway, so fall
                // back to the legacy genesis-anchored path in that case. This
                // means fork points within contextDepth of the retention floor
                // cannot anchor — log it distinctly rather than loop silently.
                let reachedGenesis = context.last?.height == 0
                if let attach = context.first,
                   context.count >= Int(contextDepth) || reachedGenesis {
                    knownAnchors = context.reversed()   // oldest-first, ending at attach
                    localWorkForAdmission = await localChain.getCumulativeWork(aboveHeight: attach.height)
                } else {
                    // Defense-in-depth: the stop set (anchorableStopFloor)
                    // should make this unreachable. If hit, the truncated
                    // segment cannot validate (it neither anchors nor reaches
                    // genesis) — log loudly; the sync attempt will fail and
                    // retry against a fresh download.
                    log.warn("\(network.directory): segment fork point \(String(anchorCID.prefix(16)))… lacks anchor context (\(context.count)/\(contextDepth)) despite the anchorable stop floor — sync attempt will fail validation")
                }
            }
            let headersForSync = HeaderChain.headersByInheritingMissingSpecCIDs(
                headers,
                initialSpecCID: knownAnchors.last?.specCID ?? genesisResult.block.spec.rawCID
            )
            let result = try await syncer.syncFromHeaders(
                headersForSync,
                cumulativeWork: headerChain.totalWork,
                localCumulativeWork: localWorkForAdmission,
                knownAnchors: knownAnchors
            )

            log.info("Sync complete: height \(result.tipBlockHeight), applying to chain...")

            var syncedParentAnchors: [String: ParentAnchor] = [:]
            if expectedChildPath != nil {
                let directory = network.directory
                let syncedProofs = await headerChain.acceptedProofs
                syncedParentAnchors = try await validateSyncedParentAnchorConsistency(
                    directory: directory,
                    headers: headers,
                    proofs: syncedProofs,
                    fetcher: fetcher
                )
            }

            let outcome = await finalizeSyncResult(result, localWork: localWork, network: network, fetcher: fetcher, sourcePeer: activeSourcePeer)
            let finalized = outcome.wasAdopted
            // Act on the outcome — make each fate an observable signal so a transient
            // content miss (the seed-496 class) is VISIBLE, not a silent stall.
            // `.pendingUnavailable` is deliberately NOT recorded as refused/failed, so
            // it stays retriable when data/peers arrive; only `.ignoredLighter` is the
            // settled work-refusal (already memoized inside finalizeSyncResult).
            metrics.increment("lattice_sync_outcome_\(outcome.metricSuffix)")
            switch outcome {
            case .adopted:
                break  // logged below as "Headers-first sync complete"
            case .ignoredLighter:
                log.info("\(network.directory): sync settled — incumbent held (peer chain not heavier)")
            case .pendingUnavailable:
                log.warn("\(network.directory): sync pending — canonical content unavailable; will retry when data/peers arrive (not refused, stays retriable)")
            case .invalid(let reason):
                log.warn("\(network.directory): sync rejected invalid chain: \(reason)")
            case .degraded(let reason):
                log.error("\(network.directory): sync could not publish — local storage/config failure: \(reason) (not retriable by waiting)")
            }

            // F5-4: child blocks just synced carry verified anchoring proofs. Persist
            // each (so this node can serve it onward) and fold its securing work into
            // fork choice — the same accumulate→reevaluate the live ingestion runs, so
            // sync is not a special path for inherited weight.
            // Gated on finalize: a refused or failed finalize never committed
            // the segment, so persisting "accepted" proofs or applying inherited
            // weight for it would leave durable state for blocks we never adopted.
            if finalized, expectedChildPath != nil {
                let directory = network.directory
                let syncedProofs = await headerChain.acceptedProofs
                await recordSyncedChildProofs(
                    directory: directory,
                    headers: headers,
                    proofs: syncedProofs,
                    parentAnchors: syncedParentAnchors,
                    source: IvyContentSource(fetcher)
                )
            }

            log.info("Headers-first sync complete")
            return outcome

        } catch {
            let peerCount2 = await network.ivy.peerConnectionCount
            // Don't blacklist the (honest) tip CID when the failure was lying peers —
            // they were already Tally-penalized; a reshuffled retry should re-reach the
            // tip via other peers. Blacklisting the content would lock honest peers out
            // of serving it too (audit M1).
            var lyingPeers = false
            if let hce = error as? HeaderChain.HeaderChainError, case .allCandidatesServedInvalid = hce {
                lyingPeers = true
            }
            if peerCount2 > 0, !lyingPeers {
                recordFailedSyncTip(attemptedTip)
            }
            if let prefetch = statePrefetchTask {
                prefetch.cancel()
                await prefetch.value
            }
            log.error("Headers-first sync failed: \(error)")
            // A throw = the attempt did not complete = transient. A reshuffled retry
            // (bounded) can re-reach the tip via other peers; a genuinely-dead source
            // just exhausts the budget. Terminal validity is decided at finalize, not here.
            return .pendingUnavailable
        }
    }

    /// Is `rootCID` (at `rootHeight`) canonical on `directory`'s chain?
    /// Used by callers that explicitly need root-chain canonicity:
    ///   1. In-memory main chain — authoritative and reorg-correct for blocks we still hold.
    ///   2. Present but off the main chain → a real side fork, not the canonical anchor.
    ///   3. Absent in memory → the root's body was pruned (it's below retention, hence
    ///      finalized). An anchor above our own tip can't be canonical for us; otherwise
    ///      fall back to the durable height→hash commitment (`block_index`), which is kept
    ///      beyond body pruning precisely so deep anchors stay verifiable without the body.
    /// Any chain can be a root here — the check is identical regardless of depth.
    func isCanonicalRoot(directory: String, rootCID: String, rootHeight: UInt64) async -> Bool {
        if let rootChain = await chain(for: directory) {
            if await rootChain.isOnMainChain(hash: rootCID) { return true }
            if await rootChain.getConsensusBlock(hash: rootCID) != nil { return false }
            if rootHeight > (await rootChain.getHighestBlockHeight()) { return false }
        }
        if let rootStore = stateStore(for: directory) {
            return rootStore.getBlockHash(atHeight: rootHeight) == rootCID
        }
        // Per-process child node: it does not own the root chain, so it can't
        // consult a root-chain state store. Instead it tracks verified parent
        // (root) headers via the parent-chain subscription, persisted under its own
        // chain's store. A root CID present as a verified parent-header edge is one
        // this node has independently PoW-verified from parent gossip — sufficient to
        // anchor an inbound child block's committing parent.
        for store in stateStores.values where store.getParentHeader(parentHash: rootCID) != nil {
            return true
        }
        return false
    }

    /// Persist each synced child block's anchoring proof and fold its inherited
    /// (securing) work into fork choice. The proofs were already anchored-verified by
    /// HeaderChain during download, so this mirrors the live ingestion's
    /// persist→accumulate→reevaluate exactly — sync is not special. Keyed by block hash,
    /// so a re-delivered block (gossip overlap) stays exactly-once in the accumulator.
    private func recordSyncedChildProofs(
        directory: String,
        headers: [SyncBlockHeader],
        proofs: [String: Data],
        parentAnchors: [String: ParentAnchor],
        source: any ContentSource
    ) async {
        for header in headers {
            guard let proofData = proofs[header.cid],
                  let decodedProofs = ChildBlockProofEnvelope.deserialize(proofData) else { continue }
            for proof in decodedProofs {
                await persistAcceptedBlockProof(directory: directory, height: header.height, blockHash: header.cid, proof: proof)
            }
            if let anchor = parentAnchors[header.cid] {
                do {
                    try await persistAcceptedChildParentAnchor(
                        directory: directory,
                        blockHash: header.cid,
                        height: header.height,
                        parentAnchor: anchor,
                        replaceExisting: true
                    )
                } catch {
                    NodeLogger("sync").error("\(directory): persistChildParentAnchor failed at height \(header.height): \(error)")
                }
            }
            for proof in decodedProofs {
                guard await applyInheritedWeight(directory: directory, blockHash: header.cid, proof: proof, source: source) else {
                    return
                }
            }
        }
    }

    /// Serves the CID-addressed entries carried inside the synced blocks'
    /// ChildBlockProofs before falling back to the network fetcher. Child-only
    /// CARRIER blocks exist only as proof material — no CAS anywhere serves
    /// their bytes — so the parent-continuity walk must read them from the
    /// proofs the sync already downloaded and verified (this is exactly how
    /// live proof-relay ingestion records the same edges). Safe against junk
    /// entries: every consumer re-derives the CID from the bytes before use.
    private struct ProofEntriesFirstFetcher: Fetcher {
        let entries: [String: Data]
        let base: Fetcher
        func fetch(rawCid: String) async throws -> Data {
            if let data = entries[rawCid] { return data }
            return try await base.fetch(rawCid: rawCid)
        }
    }

    func validateSyncedParentAnchorConsistency(
        directory: String,
        headers: [SyncBlockHeader],
        proofs: [String: Data],
        fetcher: Fetcher
    ) async throws -> [String: ParentAnchor] {
        guard let store = stateStores[chainKey(forDirectory: directory)] else { return [:] }
        // Collect every proof's CAS entries up front so the continuity walk
        // below can resolve carrier blocks that only exist as proof material.
        var proofEntryBytes: [String: Data] = [:]
        for proofData in proofs.values {
            guard let decoded = ChildBlockProofEnvelope.deserialize(proofData) else { continue }
            for proof in decoded {
                for entry in proof.entries where proofEntryBytes[entry.cid] == nil {
                    proofEntryBytes[entry.cid] = entry.data
                }
            }
        }
        let continuityFetcher: Fetcher = proofEntryBytes.isEmpty
            ? fetcher
            : ProofEntriesFirstFetcher(entries: proofEntryBytes, base: fetcher)
        var anchorsByChild: [String: [ParentAnchor]] = [:]
        for header in headers where header.height > 0 {
            guard let proofData = proofs[header.cid],
                  let decodedProofs = ChildBlockProofEnvelope.deserialize(proofData),
                  !decodedProofs.isEmpty else {
                NodeLogger("sync").warn("\(directory): synced child header \(String(header.cid.prefix(16)))… has no usable parent proof envelope")
                throw HeaderChain.HeaderChainError.invalidPoW(header.cid)
            }
            var anchors: [ParentAnchor] = []
            for proof in decodedProofs {
                guard let anchor = await persistCommittingParentEdgeFromVerifiedProof(directory: directory, proof: proof) else {
                    NodeLogger("sync").warn("\(directory): synced child header \(String(header.cid.prefix(16)))… has an unusable parent proof")
                    throw HeaderChain.HeaderChainError.invalidPoW(header.cid)
                }
                anchors.append(anchor)
            }
            anchorsByChild[header.cid] = anchors.canonicalAnchorSorted()
        }

        var pendingChildAnchors: [String: String] = [:]
        var selectedAnchors: [String: ParentAnchor] = [:]
        for header in headers where header.height > 0 {
            guard let orderedAnchors = anchorsByChild[header.cid], !orderedAnchors.isEmpty else {
                throw HeaderChain.HeaderChainError.invalidPoW(header.cid)
            }
            let canonicalAtHeight = store.getBlockHash(atHeight: header.height) == header.cid
            var selected: ParentAnchor?
            if let existing = store.getChildParentAnchor(childHash: header.cid) {
                if let matching = orderedAnchors.first(where: { $0.blockHash == existing }) {
                    selected = matching
                } else {
                    if !canonicalAtHeight {
                        NodeLogger("sync").debug("\(directory): ignoring stale noncanonical parent anchor for synced child header \(String(header.cid.prefix(16)))…")
                    } else {
                        NodeLogger("sync").warn("\(directory): synced canonical child header \(String(header.cid.prefix(16)))… conflicts with existing parent anchor")
                        throw HeaderChain.HeaderChainError.invalidPoW(header.cid)
                    }
                }
            }

            if selected == nil, header.height > 1 {
                selected = orderedAnchors.first
            } else if selected == nil {
                guard let first = orderedAnchors.first else {
                    throw HeaderChain.HeaderChainError.invalidPoW(header.cid)
                }
                selected = first
            }

            guard let selected else {
                throw HeaderChain.HeaderChainError.invalidPoW(header.cid)
            }
            if let previousChild = header.previousBlockCID, header.height > 1 {
                guard let currentRoot = selected.prevStateCID,
                      let previousChildData = try? await continuityFetcher.fetch(rawCid: previousChild),
                      let previousChildBlock = Block(data: previousChildData),
                      try VolumeImpl<Block>(node: previousChildBlock).rawCID == previousChild else {
                    NodeLogger("sync").warn("\(directory): synced child header \(String(header.cid.prefix(16)))… cannot resolve previous child block for parent state root continuity")
                    throw HeaderChain.HeaderChainError.invalidPoW(header.cid)
                }
                let previousRoot = previousChildBlock.parentState.rawCID
                let alreadyContinuous = await parentStateRootIsContinuous(
                    previousRoot: previousRoot,
                    currentRoot: currentRoot,
                    directory: directory
                )
                let backfilled: Bool
                if alreadyContinuous {
                    backfilled = true
                } else {
                    backfilled = await backfillSyncedParentStatePath(
                        directory: directory,
                        previousRoot: previousRoot,
                        currentRoot: currentRoot,
                        committingParentHash: selected.blockHash,
                        fetcher: continuityFetcher
                    )
                }
                guard backfilled,
                      await parentStateRootIsContinuous(
                        previousRoot: previousChildBlock.parentState.rawCID,
                        currentRoot: currentRoot,
                        directory: directory
                      ) else {
                    NodeLogger("sync").warn("\(directory): synced child header \(String(header.cid.prefix(16)))… breaks parent state root continuity")
                    throw HeaderChain.HeaderChainError.invalidPoW(header.cid)
                }
            }
            pendingChildAnchors[header.cid] = selected.blockHash
            selectedAnchors[header.cid] = selected
        }
        return selectedAnchors
    }

    /// Historical child sync receives a proof for each child block's committing
    /// parent carrier, but not necessarily every parent block between two child
    /// commitments. The child does not import parent blocks into its own view; it
    /// only records verified parent state transitions needed for continuity.
    func backfillSyncedParentStatePath(
        directory: String,
        previousRoot: String,
        currentRoot: String,
        committingParentHash: String,
        fetcher: Fetcher,
        maxDepth: Int = 2048,
        requireProofOfWork: Bool = false
    ) async -> Bool {
        guard previousRoot != currentRoot,
              let store = stateStores[chainKey(forDirectory: directory)] else {
            return previousRoot == currentRoot
        }

        let parentFetcher: Fetcher
        if let parentStateFetcher = parentStateFetchers[directory] {
            // Byte-identical mirror of the prior per-CID composite (primary
            // `fetcher`, fallback `parentStateFetcher`): same precedence. These
            // are local-broker/parent-subscription tiers (not the dominant network
            // ivy path), so bridging each via FetcherContentSource is
            // semantics-exact (no wave-batching to forfeit here).
            parentFetcher = CoalescingFetcher(CompositeContentSource([
                FetcherContentSource(fetcher),
                FetcherContentSource(parentStateFetcher),
            ]))
        } else {
            parentFetcher = fetcher
        }

        var cursor: String? = committingParentHash
        var seen = Set<String>()
        var depth = 0
        while let hash = cursor, !hash.isEmpty, depth < maxDepth {
            guard seen.insert(hash).inserted else { return false }
            guard let data = try? await parentFetcher.fetch(rawCid: hash),
                  let block = Block(data: data),
                  // known-valid local node; CID cannot fail
                  try! VolumeImpl<Block>(node: block).rawCID == hash else {
                NodeLogger("sync").warn("\(directory): parent-state backfill could not fetch verified parent block \(String(hash.prefix(16)))…")
                return false
            }
            // Callers that walk a less-trusted ancestry (a miner-supplied candidate
            // carrier, vs. a sync proof's verified committing parent) require each
            // walked parent block to carry valid PoW before its state transition is
            // recorded as a continuity fact — a state edge attests "this transition
            // happened", which only PoW-backed work may assert.
            if requireProofOfWork {
                // A merge-mined parent (itself a child) carries nonce=0 and fails standalone
                // PoW; trust one already verified when first relayed (header edge recorded
                // only after securing-work verification), else require standalone PoW (valid
                // for a root carrier). Standalone PoW on a nonce-0 child parent is a coin-flip
                // that falsely rejects legitimate deep merged-mined parents (the depth-3 stall).
                guard hasVerifiedParentHeaderEdge(directory: directory, blockHash: hash)
                      || block.validateProofOfWork(nexusHash: block.proofOfWorkHash()) else {
                    NodeLogger("sync").warn("\(directory): parent-state backfill rejected parent block \(String(hash.prefix(16)))… with unverified work")
                    return false
                }
            }

            await persistVerifiedParentStateEdge(directory: directory, parentBlock: block)
            if store.hasParentStatePath(from: previousRoot, to: currentRoot) {
                return true
            }
            cursor = block.parent?.rawCID
            depth += 1
        }

        return store.hasParentStatePath(from: previousRoot, to: currentRoot)
    }

    private func reprocessSyncedBlocksForChildChains(
        persisted: PersistedChainState,
        fetcher: Fetcher,
        network: ChainNetwork
    ) async -> Bool {
        // Child blocks at all depths live in child-chain CAS stores, not the nexus CAS.
        // Build a composite fetcher that falls back through all registered child networks
        // so grandchild (and deeper) block data can be resolved during replay.
        _ = fetcher
        let durableFetcher = network.canonicalContentFetcher()
        let allChildFetchers = networks.values.compactMap { $0 === network ? nil : $0.canonicalContentFetcher() as Fetcher }
        // Byte-identical mirror of the prior per-CID composite (durable broker
        // primary, child-broker fallbacks): durable broker first, then each child
        // broker in order. LOCAL-BROKER tiers (canonicalContentFetcher, not network
        // ivy), so bridging each via FetcherContentSource is semantics-exact —
        // no network wave-batching to gain.
        let compositeSource: any ContentSource = allChildFetchers.isEmpty
            ? FetcherContentSource(durableFetcher)
            : CompositeContentSource([FetcherContentSource(durableFetcher)] + allChildFetchers.map { FetcherContentSource($0) })

        let sortedBlocks = persisted.blocks.sorted { $0.blockHeight < $1.blockHeight }

        for blockMeta in sortedBlocks {
            let stub = VolumeImpl<Block>(rawCID: blockMeta.blockHash, node: nil, encryptionInfo: nil)
            do {
                // Migrate this durable-presence check onto the source API
                // (resolve(paths:source:)) to complete the fetcher→ContentSource
                // cutover. This is a LOCAL-BROKER site (canonicalContentFetcher,
                // not network ivy), so there is no network wave-batching to gain:
                // bridging the EXACT composite fetcher via FetcherContentSource
                // is byte-identical to the prior resolution (sequential per-CID over
                // the local broker; no network round-trips to batch). This is an
                // API-consistency bridge, not a perf win — that win lives only on
                // the network tier (#287).
                guard (try await stub.resolve(paths: Block.contentResolutionPaths, source: compositeSource).node) != nil else {
                    await markChainStorageDegraded(directory: network.directory, reason: "synced child canonical content not durable")
                    return false
                }
            } catch {
                NodeLogger("sync").error("\(network.directory): synced canonical block \(String(blockMeta.blockHash.prefix(16)))… missing from durable CAS during child reprocess: \(error)")
                await markChainStorageDegraded(directory: network.directory, reason: "synced child canonical content not durable")
                return false
            }
        }
        return true
    }


    /// After sync replaces the nexus chain, ensure each existing child
    /// chain's tipSnapshot reflects the new nexus state. If the synced
    /// nexus blocks don't embed a particular child chain (e.g. syncing to
    /// a fork that predates the child's deployment), the child's tip must
    /// be updated to match whatever state the Lattice reorg left it in.
    private func reconcileChildChainStatesAfterSync(
        persisted: PersistedChainState,
        fetcher: Fetcher,
        currentMutationKey: String
    ) async {
        let log = NodeLogger("sync")

        // P-502: two-phase reconciliation — collect all (dir, tip, fetcher) tuples
        // on the LatticeNode actor, then resolve tip blocks for all child chains
        // concurrently (CAS fetches are independent), then apply results sequentially.
        struct WorkItem: Sendable {
            let dir: String
            let newTip: String
            let chain: ChainState
            let blockFetcher: Fetcher
        }
        var work: [WorkItem] = []
        for (childDir, _) in networks where childDir != genesisConfig.directory {
            guard let childChain = await chain(for: childDir) else { continue }
            let newTip = await childChain.getMainChainTip()
            guard !newTip.isEmpty else { continue }
            let blockFetcher: Fetcher
            if let childNet = network(for: childDir) {
                // Byte-identical mirror of the prior per-CID composite (primary
                // `fetcher`, fallback `childNet.ivyFetcher`): passed-in sync fetcher
                // first, then the child network ivy. Bridge `fetcher` (a sync/local
                // tier, not necessarily network ivy) exactly; use the native
                // IvyContentSource for the child ivy fallback.
                blockFetcher = CoalescingFetcher(CompositeContentSource([
                    FetcherContentSource(fetcher),
                    IvyContentSource(childNet.ivyFetcher),
                ]))
            } else {
                blockFetcher = fetcher
            }
            work.append(WorkItem(dir: childDir, newTip: newTip, chain: childChain, blockFetcher: blockFetcher))
        }

        // Resolve all tip blocks concurrently — each is an independent CAS fetch
        var resolved: [(WorkItem, Block)] = []
        await withTaskGroup(of: (WorkItem, Block?).self) { group in
            for item in work {
                group.addTask {
                    let stub = VolumeImpl<Block>(rawCID: item.newTip, node: nil, encryptionInfo: nil)
                    return (item, try? await stub.resolve(fetcher: item.blockFetcher).node)
                }
            }
            for await (item, tipBlock) in group {
                if let b = tipBlock { resolved.append((item, b)) }
            }
        }

        // Apply results — back on LatticeNode actor
        for (item, tipBlock) in resolved {
            let itemKey = chainKey(forDirectory: item.dir)
            let applyResolvedChildTip: () async -> Void = { [self] in
                await item.chain.updateTipSnapshot(block: tipBlock)
                // Publish the child's canonical chain atomically (block_index + tip marker)
                // instead of moving the tip marker alone, so the child commitment can't diverge.
                do {
                    try await reconcileBlockIndex(directory: item.dir, tipStateRoot: tipBlock.postState.rawCID)
                } catch {
                    log.error("\(item.dir): failed to publish post-sync child commitment: \(error)")
                    return
                }
                log.info("\(item.dir): post-sync tip at height \(tipBlock.height)")
                tipCaches[chainKey(forDirectory: item.dir)]?.update(item.newTip)
                postStateCaches[chainKey(forDirectory: item.dir)]?.invalidate()
            }
            if itemKey == currentMutationKey {
                await applyResolvedChildTip()
            } else {
                await withChainMutation(itemKey) {
                    await applyResolvedChildTip()
                }
            }
        }
        // Tip cache update for dirs that didn't resolve
        for item in work where !resolved.contains(where: { $0.0.dir == item.dir }) {
            let itemKey = chainKey(forDirectory: item.dir)
            let applyUnresolvedChildTip: () async -> Void = { [self] in
                tipCaches[chainKey(forDirectory: item.dir)]?.update(item.newTip)
                postStateCaches[chainKey(forDirectory: item.dir)]?.invalidate()
            }
            if itemKey == currentMutationKey {
                await applyUnresolvedChildTip()
            } else {
                await withChainMutation(itemKey) {
                    await applyUnresolvedChildTip()
                }
            }
        }
    }

    // DESIGN CONSTRAINT: Every chain behaves identically. A chain that is a
    // child of Nexus behaves exactly as Nexus does for its own children.
    // finalizeSyncResult is chain-agnostic — `network` identifies which chain
    // was just synced. After applying the result, child chains are synced
    // recursively via the same performHeadersFirstSync path.
    // Behavior-preserving delegation to the pure `SyncPolicy` module (plan 3a);
    // full docs live there. Kept as thin wrappers so existing call sites + tests
    // are the characterization net during the extraction.
    static func shouldAdmitSyncedChain(peerWork: UInt256, localWork: UInt256) -> Bool {
        SyncPolicy.shouldAdmit(peerWork: peerWork, localWork: localWork)
    }

    static func syncerWorkFloor(chainPath: [String], localWork: UInt256) -> UInt256 {
        SyncPolicy.workFloor(chainPath: chainPath, localWork: localWork)
    }

    func recordRefusedSyncTip(_ peerTip: String, localTip: String) {
        syncOutcomes.recordRefused(peerTip: peerTip, localTip: localTip)
    }

    /// Was `peerTip` already fully synced and refused while our tip was `localTip`?
    /// Re-syncing it is pure churn until either tip changes.
    func isRefusedSyncTip(_ peerTip: String, localTip: String) -> Bool {
        syncOutcomes.isRefused(peerTip: peerTip, localTip: localTip)
    }

    enum SyncAdmissionDecision {
        case admit
        /// Deterministic refusal (less work, or equal-work tiebreak keeps the
        /// local tip) — safe to memoize until either tip changes.
        case refuse
    }

    /// Admission decision for a fully-validated synced chain, evaluated against
    /// the chain's CURRENT state (never a pre-download snapshot).
    ///
    /// Only a STRICTLY heavier `trueCumWork` tip admits; an exact tie holds the
    /// incumbent (docs/protocol.md §fork-choice, docs/whitepaper.md). Equal-work
    /// forks are not switched on receipt — the next block to extend either fork
    /// makes it strictly heavier and the network converges on that. Admission
    /// stays verify-not-trust: the synced chain passed full PoW + consensus
    /// validation in the header path before reaching here.
    /// Lowest height offered to the header walk as a stop point. Every stop
    /// point must be ANCHORABLE: the anchor context needs `contextDepth` local
    /// ancestors below it (or to reach genesis), so stop points within
    /// `contextDepth` of the retention floor are excluded — the walk continues
    /// past them to a deeper (anchorable) block or to genesis. Without this, a
    /// walk stopped at a near-floor block strands the sync: the segment is
    /// already truncated at that stop, no anchor context can be built, and the
    /// genesis-anchored validation can only ever fail on it (review P2).
    /// Near genesis (tip within retention + context) everything is anchorable
    /// or genesis-reachable, so the floor is 0.
    static func anchorableStopFloor(tipHeight: UInt64, retentionDepth: UInt64, contextDepth: UInt64) -> UInt64 {
        SyncPolicy.anchorableStopFloor(tipHeight: tipHeight, retentionDepth: retentionDepth, contextDepth: contextDepth)
    }

    /// Anchor eligibility for a downloaded segment: root chains may anchor at
    /// any retained main-chain fork point; child chains only at the CURRENT
    /// tip (pure fast-forward — see the call site and admission for why).
    func isAnchorEligible(anchorCID: String, chainPath: [String], localChain: ChainState) async -> Bool {
        if chainPath.count == 1 { return true }
        return anchorCID == (await localChain.getMainChainTip())
    }

    func admitSyncedChainAgainstCurrentChain(
        _ result: SyncResult,
        chainState: ChainState,
        chainPath: [String]
    ) async -> SyncAdmissionDecision {
        // Segment-anchored result: when the synced segment attaches to a block
        // that is on OUR CURRENT main chain, it competes only against the local
        // blocks strictly above that fork point — the shared prefix cancels on
        // both sides. Comparing the segment against the whole local chain would
        // refuse every catch-up shorter than the local chain itself. The
        // isOnMainChain check is re-evaluated HERE (post-materialization), so a
        // reorg that removed the anchor mid-sync falls through to the legacy
        // whole-chain compare and fails closed. Exact ties still hold the
        // incumbent (strictly-greater compare, unchanged).
        let sortedBlocks = result.persisted.blocks.sorted { $0.blockHeight < $1.blockHeight }
        // CHILD chains admit ONLY pure fast-forwards of the current tip via
        // sync — enforced HERE at the single admission choke point so no
        // branch below can decide a child reorg on own-target work sums (a
        // below-retention fork otherwise reaches the legacy whole-window
        // compare, where a long cheap-target fork with no inherited securing
        // work could outweigh the properly-secured chain — audit P2-1). Child
        // fork resolution belongs exclusively to gossip fork choice
        // (trueCumWork = subtree + inherited securing work).
        if chainPath.count > 1 {
            let currentTip = await chainState.getMainChainTip()
            guard let lowest = sortedBlocks.first, lowest.blockHeight > 0,
                  lowest.parentBlockHash == currentTip else {
                return .refuse
            }
            // Strict fast-forward of the current tip: admit WITHOUT a work
            // comparison. Child own-target work sums are meaningless for child
            // ordering (a carrier's real weight is the securing work in its
            // ChildBlockProofs, which admission cannot see), so gating a pure
            // append on them refuses valid carrier catch-ups (the frozen-
            // follower "insufficientWork" loop). The segment was fully
            // validated and proof-anchored upstream, it evicts nothing, and it
            // decides no reorg — fork choice over trueCumWork remains the sole
            // switch authority for competing branches.
            return .admit
        }
        if let lowest = sortedBlocks.first, lowest.blockHeight > 0,
           let anchorCID = lowest.parentBlockHash,
           await chainState.isOnMainChain(hash: anchorCID) {
            // ROOT chains compare at the fork point: their headers are
            // self-PoW-verified, so segment work vs local-work-above-fork is
            // the correct Nakamoto comparison. (Children never reach here —
            // handled fast-forward-only above.) NOTE: a root gap larger than
            // retentionDepth truncates the result below the retained window
            // (lowest.parent off the main chain) and intentionally falls to
            // the legacy whole-window compare below.
            let localBeyondFork = await chainState.getCumulativeWork(aboveHeight: lowest.blockHeight - 1)
            if Self.shouldAdmitSyncedChain(peerWork: result.cumulativeWork, localWork: localBeyondFork) { return .admit }
            return .refuse
        }
        let localWork = await localCumulativeWork(chainPath: chainPath)
        if Self.shouldAdmitSyncedChain(peerWork: result.cumulativeWork, localWork: localWork) { return .admit }
        return .refuse
    }

    /// Returns true only when the synced segment was durably published AND
    /// projected into ChainState. Callers running accepted-only side effects
    /// (e.g. persisting child proofs / folding inherited weight) MUST gate on
    /// this — a refused or failed finalize means the segment was
    /// never committed.
    @discardableResult
    func finalizeSyncResult(_ result: SyncResult, localWork: UInt256, network: ChainNetwork, fetcher: Fetcher, sourcePeer: PeerID? = nil) async -> ChainOutcome {
        let key = chainKey(forPath: network.chainPath)
        return await withChainMutation(key) {
            await finalizeSyncResultUnlocked(
                result,
                localWork: localWork,
                network: network,
                fetcher: fetcher,
                sourcePeer: sourcePeer
            )
        }
    }

    @discardableResult
    private func finalizeSyncResultUnlocked(_ result: SyncResult, localWork: UInt256, network: ChainNetwork, fetcher: Fetcher, sourcePeer: PeerID? = nil) async -> ChainOutcome {
        let log = NodeLogger("sync")
        let directory = network.directory
        guard let chainState = await chain(for: directory) else { return .pendingUnavailable }

        // Gate against the CURRENT chain, not the caller's pre-download
        // `localWork` snapshot: a block mined or accepted during the sync must
        // never be rolled back by an equal/lower-work synced chain.
        switch await admitSyncedChainAgainstCurrentChain(result, chainState: chainState, chainPath: network.chainPath) {
        case .admit:
            break
        case .refuse:
            log.warn("\(directory): sync refused: peer work \(result.cumulativeWork) does not beat the current local chain")
            recordRefusedSyncTip(result.tipBlockHash, localTip: await chainState.getMainChainTip())
            return .ignoredLighter
        }

        let sortedBlocks = result.persisted.blocks.sorted { $0.blockHeight < $1.blockHeight }
        guard let store = stateStores[chainKey(forDirectory: directory)],
              let lowest = sortedBlocks.first,
              let tipMeta = sortedBlocks.last else {
            log.error("\(directory): cannot publish sync without StateStore and a non-empty canonical segment")
            return .degraded(reason: "missing StateStore or empty canonical segment")
        }

        guard let materialized = await materializeSyncedCanonicalContent(
            blocks: sortedBlocks,
            tipHash: tipMeta.blockHash,
            network: network,
            fetcher: fetcher,
            sourcePeer: sourcePeer
        ) else {
            log.warn("\(directory): could not materialize synced canonical content; retrying before durable publish")
            return .pendingUnavailable
        }
        let tipBlock = materialized.tipBlock
        let oldTip = await chainState.getMainChainTip()

        // Materialization fetches remote content and can take seconds — re-run
        // the admission gate against the chain as it stands NOW, so a chain
        // that advanced mid-sync is never durably replaced by a stale result.
        guard case .admit = await admitSyncedChainAgainstCurrentChain(result, chainState: chainState, chainPath: network.chainPath) else {
            log.info("\(directory): sync abandoned after materialization: local chain advanced past the synced chain")
            return .ignoredLighter
        }

        // Publish the synced canonical chain as ONE atomic segment commit before
        // mutating ChainState. StateStore is authoritative; ChainState is only the
        // in-memory projection of this durable commit.
        let connectsBelow = lowest.blockHeight == 0
            || store.getBlockHash(atHeight: lowest.blockHeight - 1) == lowest.parentBlockHash
        let syncedTransition = await syncedCanonicalTransition(
            oldTip: oldTip,
            newTip: tipMeta.blockHash,
            syncedBlocks: sortedBlocks,
            connectsBelow: connectsBelow,
            chain: chainState
        )
        let segment = CanonicalSegment(
            blocks: sortedBlocks.map {
                CanonicalSegmentBlock(
                    height: $0.blockHeight, hash: $0.blockHash,
                    stateRoot: $0.blockHash == tipMeta.blockHash ? tipBlock.postState.rawCID : nil)
            },
            connectsBelow: connectsBelow)

        guard let preparedEffects = await prepareSyncedCanonicalEffects(
            blocks: sortedBlocks,
            materializedBlocks: materialized.blocksByHeight,
            directory: directory,
            fetcher: fetcher
        ) else {
            // prepareSyncedCanonicalEffects marks the chain unhealthy on ALL its nil
            // paths, so this is a degraded (terminal) failure, not a wait-and-retry
            // availability miss. Return .degraded so the classification is self-
            // consistent (any markChain*-degrade → .degraded) rather than relying on
            // the retry loop's !isChainUnhealthy guard to suppress a wrong retry.
            return .degraded(reason: "failed to prepare synced canonical effects (chain marked unhealthy)")
        }

        do {
            try await advanceStateRetainedRoots(
                directory: directory,
                network: network,
                tipHeight: tipMeta.blockHeight,
                tipHash: tipMeta.blockHash,
                materializedBlocks: materialized.blocksByHeight,
                preserveExistingRoots: true
            )
        } catch {
            log.error("\(directory): failed to pre-protect synced state retained roots before sync publish: \(error)")
            await markChainStorageDegraded(directory: directory, reason: "failed to advance synced state retained roots")
            return .degraded(reason: "failed to advance synced state retained roots")
        }

        for meta in sortedBlocks {
            let owner = "\(network.ownerNamespace):\(meta.blockHeight)"
            do {
                let pinRoots = materialized.blocksByHeight[meta.blockHeight].map {
                    consensusPinRoots(block: $0)
                } ?? [meta.blockHash]
                try await network.pinBatchDurably(roots: pinRoots, owner: owner)
            } catch {
                log.error("\(directory): failed to pre-pin synced block \(String(meta.blockHash.prefix(16)))… at height \(meta.blockHeight): \(error)")
                await markChainStorageDegraded(directory: directory, reason: "failed to pin synced canonical content before durable commit")
                return .degraded(reason: "failed to pin synced canonical content")
            }
        }

        do {
            try await store.commitCanonicalSegment(
                segment,
                blockEffects: preparedEffects.map(\.storeEffects)
            )
        } catch {
            log.error("\(directory): failed to publish synced canonical segment: \(error)")
            return .pendingUnavailable
        }

        for meta in sortedBlocks {
            let storedRoots = materialized.rootsByHeight[meta.blockHeight] ?? [meta.blockHash]
            do {
                try await store.persistStoredRoots(height: meta.blockHeight, roots: storedRoots)
            } catch {
                log.error("\(directory): failed to persist synced stored roots for \(String(meta.blockHash.prefix(16)))… at height \(meta.blockHeight): \(error)")
                await markChainStorageDegraded(directory: directory, reason: "failed to persist synced canonical content roots after durable commit")
                return .degraded(reason: "failed to persist synced canonical content roots")
            }
        }

        do {
            try await advanceStateRetainedRoots(
                directory: directory,
                network: network,
                tipHeight: tipMeta.blockHeight,
                tipHash: tipMeta.blockHash,
                materializedBlocks: materialized.blocksByHeight
            )
        } catch {
            log.warn("\(directory): failed to shrink synced state retained roots after publish; retaining previous roots until the next successful advance: \(error)")
        }

        do {
            // Anchored (mid-chain) segments: `result.persisted` contains ONLY
            // the segment, so resetFrom(it) would shrink the in-memory window
            // to the segment and under-count windowed cumulative work until a
            // restart re-projects it — temporarily weakening the whole-window
            // admission compare (review High). The durable commit above just
            // made prefix+segment contiguous in the authoritative store, so
            // reproject the FULL retained window from it instead — the same
            // walk boot recovery uses. Genesis-rooted results already ARE the
            // full window and keep the direct path.
            var projection = result.persisted
            if lowest.blockHeight > 0 {
                let source = recoverySource(directory: directory, network: network)
                if let rebuilt = await Self.rebuildChainState(
                    tipCID: result.tipBlockHash, source: source, retentionDepth: config.retentionDepth) {
                    projection = rebuilt
                    log.info("\(directory): reprojected full retained window from durable store after anchored sync")
                } else {
                    log.warn("\(directory): could not reproject retained window after anchored sync; using segment-only projection (window heals on restart)")
                }
            }
            try await chainState.resetFrom(projection, retentionDepth: config.retentionDepth)
        } catch {
            log.error("\(directory): failed to project synced state into ChainState: \(error)")
            await markChainUnhealthy(directory: directory, reason: "failed to project synced state after durable commit")
            return .degraded(reason: "failed to project synced state after durable commit")
        }
        await chainState.updateTipSnapshot(block: tipBlock)

        tipCaches[chainKey(forDirectory: directory)]?.update(result.tipBlockHash)
        postStateCaches[chainKey(forDirectory: directory)]?.invalidate()

        await persistChainState(directory: directory)

        guard await publishPreparedSyncedCanonicalSideEffects(
            preparedEffects,
            directory: directory,
            fetcher: fetcher,
            chain: chainState,
            oldTip: oldTip,
            newTip: result.tipBlockHash,
            transition: syncedTransition
        ) else {
            // POST-COMMIT (segment committed + ChainState reset): a sync retry would
            // re-attempt an already-committed segment, so this is TERMINAL, not
            // wait-and-retry availability.
            return .degraded(reason: "failed to publish synced canonical side effects after commit")
        }

        // Parent sync must not rewrite descendant fork choice. Child chains are
        // independent proof-validated chains; parent canonicity only changes the
        // local parent data available to prove future child work.
        guard await reprocessSyncedBlocksForChildChains(persisted: result.persisted, fetcher: fetcher, network: network) else {
            // POST-COMMIT: the canonical segment is already committed and ChainState
            // reset; this helper marks storage degraded on missing durable content. A
            // sync retry is wrong here (it would re-attempt an already-committed segment
            // on a stopped/unhealthy chain), so this is TERMINAL, not wait-and-retry.
            return .degraded(reason: "failed to reprocess synced blocks for child chains after commit")
        }
        await reconcileChildChainStatesAfterSync(
            persisted: result.persisted,
            fetcher: fetcher,
            currentMutationKey: chainKey(forDirectory: directory)
        )
        await verifySyncWithPeers(tipCID: result.tipBlockHash, tipHeight: result.tipBlockHeight, network: network)

        await syncSubscribedChildren(of: directory)
        return .adopted(tipCID: result.tipBlockHash)
    }

    private func syncedCanonicalTransition(
        oldTip: String,
        newTip: String,
        syncedBlocks: [PersistedBlockMeta],
        connectsBelow: Bool,
        chain: ChainState
    ) async -> BoundedReorgWalkResult? {
        guard !oldTip.isEmpty, oldTip != newTip else { return nil }
        var newChainHashes = Set(syncedBlocks.map(\.blockHash))
        if connectsBelow, let lowerParent = syncedBlocks.first?.parentBlockHash, !lowerParent.isEmpty {
            newChainHashes.insert(lowerParent)
        }
        let walked = await Self.walkOrphansToCommonAncestor(
            oldTip: oldTip,
            newChainHashes: newChainHashes,
            retentionDepth: config.retentionDepth
        ) { hash in
            await chain.getConsensusBlock(hash: hash)?.parentBlockHash
        }
        return BoundedReorgWalkResult(
            orphaned: walked.orphans,
            promoted: syncedBlocks.reversed().map { (hash: $0.blockHash, height: $0.blockHeight) },
            newChainHashes: newChainHashes,
            foundCommonAncestor: walked.foundCommonAncestor
        )
    }

    /// Prepare the same deterministic block effects used by live acceptance
    /// before the synced segment is published. This keeps consensus data
    /// (transaction actions and declared state roots) ahead of local projections
    /// (receipts, tx_history, nonce floors) and lets StateStore commit the
    /// canonical segment plus query indexes atomically.
    private func prepareSyncedCanonicalEffects(
        blocks: [PersistedBlockMeta],
        materializedBlocks: [UInt64: Block],
        directory: String,
        fetcher: Fetcher
    ) async -> [PreparedAcceptedBlockEffects]? {
        // Grain-independent, LOCAL-FIRST resolution for the synced replay: the
        // recompute reads state-trie grains that exist in the local CAS but are
        // NOT servable volume roots, so the wave-batched IvyContentSource (a
        // remote volume-root optimization the baseFetcher overload would pick
        // here) reports notFound for bytes this node already holds — killing
        // the publish of an otherwise-valid deep catch-up. FetcherContentSource
        // over IvyFetcher is the documented semantics-exact bridge: per-CID,
        // local broker first, remote poll second.
        let txSource = await buildMempoolAwareSource(
            directory: directory, baseSource: FetcherContentSource(fetcher))
        var prepared: [PreparedAcceptedBlockEffects] = []
        prepared.reserveCapacity(blocks.count)
        for meta in blocks {
            guard let block = materializedBlocks[meta.blockHeight] else {
                NodeLogger("sync").error("\(directory): synced canonical block \(String(meta.blockHash.prefix(16)))…@\(meta.blockHeight) was not materialized for effect preparation")
                await markChainUnhealthy(directory: directory, reason: "failed to materialize synced canonical effects")
                return nil
            }
            guard let transactions = await resolveCompleteSyncedBlockTransactions(
                block: block,
                blockHash: meta.blockHash,
                blockHeight: meta.blockHeight,
                directory: directory,
                source: txSource
            ) else {
                await markChainUnhealthy(directory: directory, reason: "failed to resolve synced canonical transactions")
                return nil
            }
            guard await verifySyncedStateTransition(
                block: block,
                blockHash: meta.blockHash,
                blockHeight: meta.blockHeight,
                directory: directory,
                transactions: transactions,
                source: txSource
            ) else {
                await markChainUnhealthy(directory: directory, reason: "failed to verify synced canonical state transition")
                return nil
            }
            guard let effects = await prepareAcceptedBlockEffects(
                block: block,
                blockHash: meta.blockHash,
                txEntries: transactions.entriesByKey,
                directory: directory,
                allowLowerHeightReplay: true
            ) else {
                NodeLogger("sync").error("\(directory): synced canonical block \(String(meta.blockHash.prefix(16)))…@\(meta.blockHeight) could not prepare canonical effects")
                await markChainUnhealthy(directory: directory, reason: "failed to prepare synced canonical effects")
                return nil
            }
            prepared.append(effects)
        }
        return prepared
    }

    private struct SyncedBlockTransactions {
        let entriesByKey: [String: VolumeImpl<Transaction>]
        let orderedBodies: [TransactionBody]
    }

    private func resolveCompleteSyncedBlockTransactions(
        block: Block,
        blockHash: String,
        blockHeight: UInt64,
        directory: String,
        source: any ContentSource
    ) async -> SyncedBlockTransactions? {
        guard let txDict = try? await block.transactions.resolveRecursive(source: source).node,
              let orderedEntries = try? txDict.sortedKeysAndValues() else {
            NodeLogger("sync").error("\(directory): synced canonical block \(String(blockHash.prefix(16)))…@\(blockHeight) has unresolved transaction dictionary")
            return nil
        }
        var orderedBodies: [TransactionBody] = []
        orderedBodies.reserveCapacity(orderedEntries.count)
        for (key, txHeader) in orderedEntries {
            guard let tx = txHeader.node, let body = tx.body.node else {
                NodeLogger("sync").error("\(directory): synced canonical block \(String(blockHash.prefix(16)))…@\(blockHeight) has unresolved transaction \(key)")
                return nil
            }
            orderedBodies.append(body)
        }
        return SyncedBlockTransactions(
            entriesByKey: Dictionary(uniqueKeysWithValues: orderedEntries),
            orderedBodies: orderedBodies
        )
    }

    /// Startup state self-heal — the state-layer sibling of `reconstructBlockVolumes`
    /// (#16, block volumes) and the proof self-heal (#18). A node that SYNCED its tip
    /// before state-on-sync persisted the full closure holds only each block's diff, so
    /// full-state reads (candidate build for mining, deep serving) fault to the network.
    /// We RECOMPUTE the retained heights' state from the blocks the node ALREADY holds
    /// (recompute-don't-fetch — no whole-trie fetch over the wire) and durably store ONLY
    /// the boundary volumes not already present: `storeAcceptedStateDiffRoots` skips
    /// already-durable roots, and a per-block closure-durable check skips whole blocks.
    ///
    /// Completeness by mode: `historical` retains ALL heights, so the union of per-height
    /// diffs materializes the FULL tip trie — a `historical` node fully recovers. `stateful`
    /// (retention window) recovers the window-TOUCHED state; an account last changed BELOW
    /// the floor stays a Reference and the floor block's prevState may fault once, so a node
    /// that must serve / candidate-build the full tip set should run `historical`. Data
    /// present ⇒ node recovers its state on restart, no re-sync, no wipe.
    ///
    /// Efficiency: a persisted watermark short-circuits the whole pass once converged; it
    /// is advanced ONLY after a fully-successful pass, so a crash/failure re-scans, and a
    /// new tip is bounded to the un-materialized suffix (already-durable heights skip cheap).
    func materializeRetainedState(directory: String) async {
        guard config.storageMode != .stateless,
              let network = network(for: directory),
              let chainState = await chain(for: directory) else { return }
        let log = NodeLogger("sync")
        let height = await chainState.getHighestBlockHeight()
        let retained = retainedStateRootHeights(tipHeight: height)
        guard let lowest = retained.min() else { return }
        let retainedSet = Set(retained)
        let store = stateStore(for: directory)
        // Watermark = "<coveredLowest>:<coveredThrough>:<tipHash>": a prior pass materialized
        // every retained height in [coveredLowest…coveredThrough] as of `tipHash`. `coveredThrough`
        // may be < height — partial progress is persisted so a flaky pass never strands the tail
        // or re-walks a confirmed prefix (tipHash may itself contain ':', so split at most twice).
        let tipHash = await chainState.getMainChainTip()
        var wmLowest: UInt64? = nil
        var wmThrough: UInt64? = nil
        var wmTip: String? = nil
        if let wm = store?.getGeneral(key: stateHealWatermarkKey).flatMap({ String(decoding: $0, as: UTF8.self) }) {
            let parts = wm.split(separator: ":", maxSplits: 2)
            if parts.count == 3 {
                wmLowest = UInt64(parts[0]); wmThrough = UInt64(parts[1]); wmTip = String(parts[2])
            }
        }
        // Converged short-circuit: skip ONLY when a prior pass covered [≤lowest … ≥height] on the
        // SAME canonical tip (by hash — a reorg to a numerically-lower tip must re-check). The
        // watermark is written ONLY after a real recompute+store pass below, so it is a trustworthy
        // completeness signal on its own. We deliberately do NOT gate on a local-resolve check:
        // `resolveRecursive` over the state header does NOT cross the account-trie Volume boundaries
        // (every internal trie edge is a separate Volume), so it resolves only the shallow closure —
        // the header + 5 sub-state roots, present as bare-root stubs — and false-passes even when the
        // DEEP account trie is absent. That shallow gate is exactly why prior passes "converged"
        // while every full-state read still faulted to the network.
        if !tipHash.isEmpty, wmTip == tipHash, (wmLowest ?? UInt64.max) <= lowest, (wmThrough ?? 0) >= height {
            return
        }
        // No resume-prefix skip: once the short-circuit above did NOT fire, always scan from
        // `lowest`. A blind prefix-skip based on the watermark alone would re-introduce durability
        // inferred from a weaker signal — an intermediate height's state can be evicted after being
        // materialized, and skipping it would persist a "complete" watermark that faults to network
        // for the tip's lifetime. The per-block `postStateLocallyResolvable` skip already makes an
        // already-materialized height cheap (resolves locally, skipped without recompute), so
        // scanning from `lowest` is correct and adds no recompute for converged heights.
        // Connected backbone peers hold the retained blocks' content; bind them per height below
        // so resolves hop straight to a peer instead of a 15s untargeted DHT walk per miss.
        let peers = await network.ivy.connectedPeers
        let source = recoverySource(directory: directory, network: network)
        let fetcher = CoalescingFetcher(source)
        var materialized = 0
        // Highest height h with every retained height in [lowest…h] materialized this pass. A gap
        // freezes the marker so the tail retries next pass.
        var contiguousThrough: UInt64? = nil
        var contiguousBroken = false
        // Ascending: each recompute's prevState resolves from LOCAL CAS once the prior
        // height's closure is stored below.
        for i in lowest...height {
            guard retainedSet.contains(i) else {
                if !contiguousBroken { contiguousThrough = i }
                continue
            }
            // A retained height with no indexed block is an anomaly — freeze the contiguous marker
            // so we don't advance the watermark past un-materialized state next restart.
            guard let blockHash = await chainState.getMainChainBlockHash(atIndex: i) else {
                contiguousBroken = true; continue
            }
            let stub = VolumeImpl<Block>(rawCID: blockHash, node: nil, encryptionInfo: nil)
            guard let block = try? await stub.resolve(source: source).node else { contiguousBroken = true; continue }
            // No per-block "already materialized?" resolve check: any resolve-based probe is either
            // shallow (a bare-root-stub / boundary-stopping walk that false-passes) or an unbounded
            // full-trie walk. Instead recompute unconditionally — proveAndUpdateState touches only the
            // paths this block's txs hit, and storeAcceptedStateDiffRoots is idempotent (already-durable
            // roots are skipped), so a genuinely-materialized height is already cheap. The watermark
            // short-circuit above (written only after a full pass) covers the converged fast path.
            // Route this height's content resolves straight to connected backbone peers
            // (bindBlockRoots) — the sync path's pattern — instead of the untargeted DHT-walk timeout.
            for peer in peers {
                await network.ivyFetcher.bindPinner(rootCID: blockHash, peer: peer)
                await network.ivyFetcher.bindBlockRoots(block, peer: peer)
            }
            // Bounded retry so one transient content miss doesn't strand an otherwise-healable height.
            var succeeded = false
            for attempt in 0..<3 {
                guard let txs = await resolveCompleteSyncedBlockTransactions(
                          block: block, blockHash: blockHash, blockHeight: i,
                          directory: directory, source: source) else { continue }
                do {
                    let prevState = try await block.prevState.resolve(fetcher: fetcher)
                    let bodies = txs.orderedBodies
                    let (postState, diff) = try await prevState.proveAndUpdateState(
                        allAccountActions: bodies.flatMap(\.accountActions),
                        allActions: bodies.flatMap(\.actions),
                        allDepositActions: bodies.flatMap(\.depositActions),
                        allGenesisActions: bodies.flatMap(\.genesisActions),
                        allReceiptActions: bodies.flatMap(\.receiptActions),
                        allWithdrawalActions: bodies.flatMap(\.withdrawalActions),
                        transactionBodies: bodies,
                        fetcher: fetcher
                    )
                    // Fail closed: never persist a recompute that does not reproduce the declared
                    // postState root. A mismatch is deterministic — do not retry it.
                    guard let postHeader = try? LatticeStateHeader(node: postState),
                          postHeader.rawCID == block.postState.rawCID else {
                        log.error("\(directory): materializeRetainedState: recomputed state does not match declared postState at height \(i)")
                        break
                    }
                    // Durably materializes ONLY the boundary roots not already stored — from
                    // the in-memory recompute, no network trie fetch.
                    if await storeAcceptedStateDiffRoots(
                        block: block, stateDiff: diff, materializedPostState: postState,
                        network: network, source: source, directory: directory) != nil {
                        materialized += 1
                        succeeded = true
                        break
                    }
                    // Store failed — retry.
                } catch {
                    if attempt == 2 {
                        log.warn("\(directory): materializeRetainedState: recompute failed at height \(i): \(error)")
                    }
                }
            }
            if succeeded {
                if !contiguousBroken { contiguousThrough = i }
            } else {
                contiguousBroken = true
            }
        }
        // Persist the highest CONTIGUOUS materialized height (partial progress included) so a later
        // pass resumes above it and eventually short-circuits once through == height.
        if let through = contiguousThrough, !tipHash.isEmpty {
            try? await store?.setGeneral(key: stateHealWatermarkKey,
                value: Data("\(lowest):\(through):\(tipHash)".utf8), atHeight: height)
        }
        if materialized > 0 {
            log.info("\(directory): self-healed state for \(materialized) retained block(s) in [\(lowest)...\(height)]")
        }
    }

    // v2: the v1 watermark was written by a pass whose shallow resolveRecursive gate false-passed,
    // so v1 markers claim completeness over un-materialized deep state. A new key forces every node
    // to re-run the (now unconditional-recompute) pass once, healing the deep closure, then converge.
    private var stateHealWatermarkKey: String { "state-materialized-height-v2" }

    private func verifySyncedStateTransition(
        block: Block,
        blockHash: String,
        blockHeight: UInt64,
        directory: String,
        transactions: SyncedBlockTransactions,
        source: any ContentSource
    ) async -> Bool {
        let fetcher = CoalescingFetcher(source)
        do {
            let prevState = try await block.prevState.resolve(fetcher: fetcher)
            let bodies = transactions.orderedBodies
            let (updatedState, _) = try await prevState.proveAndUpdateState(
                allAccountActions: bodies.flatMap(\.accountActions),
                allActions: bodies.flatMap(\.actions),
                allDepositActions: bodies.flatMap(\.depositActions),
                allGenesisActions: bodies.flatMap(\.genesisActions),
                allReceiptActions: bodies.flatMap(\.receiptActions),
                allWithdrawalActions: bodies.flatMap(\.withdrawalActions),
                transactionBodies: bodies,
                fetcher: fetcher
            )
            let updatedHeader = try LatticeStateHeader(node: updatedState)
            guard updatedHeader.rawCID == block.postState.rawCID else {
                NodeLogger("sync").error("\(directory): synced canonical block \(String(blockHash.prefix(16)))…@\(blockHeight) computed postState \(String(updatedHeader.rawCID.prefix(16)))… but declares \(String(block.postState.rawCID.prefix(16)))…")
                return false
            }
            return true
        } catch {
            NodeLogger("sync").error("\(directory): synced canonical block \(String(blockHash.prefix(16)))…@\(blockHeight) failed Cashew state replay: \(error)")
            return false
        }
    }

    /// Publish the non-SQLite side effects for an already-committed synced
    /// canonical segment. The canonical segment, receipts, tx_history, and
    /// applied-through marker have already moved together in StateStore.
    @discardableResult
    private func publishPreparedSyncedCanonicalSideEffects(
        _ preparedEffects: [PreparedAcceptedBlockEffects],
        directory: String,
        fetcher: Fetcher,
        chain: ChainState,
        oldTip: String,
        newTip: String,
        transition: BoundedReorgWalkResult?
    ) async -> Bool {
        let source = FetcherContentSource(fetcher)
        if let transition, oldTip != newTip {
            await recoverOrphanedTransactions(
                transition: transition,
                oldTip: oldTip,
                newTip: newTip,
                directory: directory,
                source: source
            )
        }

        for effects in preparedEffects {
            await applyPreparedAcceptedBlockEffects(effects, recoverReplacedCanonicalBlock: false)
        }
        if let tipBlock = preparedEffects.last?.block {
            await chain.updateTipSnapshot(block: tipBlock)
        }
        tipCaches[chainKey(forDirectory: directory)]?.update(newTip)
        postStateCaches[chainKey(forDirectory: directory)]?.invalidate()
        return true
    }

    private func materializeSyncedCanonicalContent(
        blocks: [PersistedBlockMeta],
        tipHash: String,
        network: ChainNetwork,
        fetcher: Fetcher,
        sourcePeer: PeerID? = nil
    ) async -> (tipBlock: Block, rootsByHeight: [UInt64: [String]], blocksByHeight: [UInt64: Block])? {
        let log = NodeLogger("sync")
        var syncedTip: Block?
        var rootsByHeight: [UInt64: [String]] = [:]
        var blocksByHeight: [UInt64: Block] = [:]

        // State-completeness on sync: for the heights this mode RETAINS (just the tip
        // for stateful/retention, all for historical) materialize the FULL state-boundary
        // closure (state root + sub-roots), not only each block's created diff. A synced
        // node that stores only diffs faults every full-state read to the network (slow
        // candidate build / serving); completing the closure here — the same primitive the
        // live accept path uses — keeps cold state reads LOCAL. Not stateful/historical
        // specific: any non-stateless mode gets its retained heights completed.
        let syncTipHeight = blocks.first(where: { $0.blockHash == tipHash })?.blockHeight
            ?? (blocks.map(\.blockHeight).max() ?? 0)
        let retainedStateHeights = Set(retainedStateRootHeights(tipHeight: syncTipHeight))

        for meta in blocks {
            let blockHeader = VolumeImpl<Block>(rawCID: meta.blockHash, node: nil, encryptionInfo: nil)
            // The sync source peer is a guaranteed holder of every synced block
            // and its sub-volumes. Bind it the same way the gossip path does
            // (bindBlockRoots) so content resolution hops straight to the peer
            // instead of burning the 15s untargeted DHT-walk timeout per missing
            // provider record — which overruns the sync window and aborts an
            // otherwise valid sync.
            if let sourcePeer {
                await network.ivyFetcher.bindPinner(rootCID: meta.blockHash, peer: sourcePeer)
                if let stub = try? await blockHeader.resolve(fetcher: fetcher).node {
                    await network.ivyFetcher.bindBlockRoots(stub, peer: sourcePeer)
                }
            }
            // Headers-first sync delivered only the block ROOT node. Fetch the
            // block's whole CONTENT closure — the block volume, the spec volume,
            // and each transaction-body volume — one shot per volume by root CID,
            // so resolution finds every internal trie node in the local CAS.
            // Object-grain storage keeps internal nodes as non-root entries that
            // are never fetched individually over the wire.
            //
            // A received volume is a locality bundle, not a completeness claim:
            // resolution below IS the JIT verification. If it fails, the bundle
            // some peer served was deficient — report its server (Tally demotion,
            // provider-record removal), then refetch the bundles from OTHER peers
            // and retry. Without this, a first-responder stub (e.g. a headers-only
            // tracker answering a volume want with a bare root) wedges sync
            // permanently against the same peer mix. Trust is local.
            var bundleRoots = await prefetchBlockContentClosure(blockHash: meta.blockHash, network: network)
            var resolved: VolumeImpl<Block>?
            for attempt in 0..<3 {
                do {
                    // Stage 2c: resolve over the batched Ivy ContentSource. Each
                    // resolution wave is served from local CAS; misses are Volume
                    // boundary roots fetched as whole attributed bundles — so any
                    // boundary the warm-up prefetch above didn't know about (it
                    // enumerates types by hand) is still fetched at the right
                    // grain, on demand, by resolution itself.
                    await network.ivyFetcher.beginVolumeTrace()
                    resolved = try await blockHeader.resolve(
                        paths: Block.contentResolutionPaths,
                        source: IvyContentSource(network.ivyFetcher)
                    )
                    _ = await network.ivyFetcher.takeVolumeTrace()
                    break
                } catch {
                    // A bundle did not resolve into a complete block. This is an
                    // AVAILABILITY miss, NOT fraud — the peer doesn't (yet) have the
                    // data. A connected peer can transiently answer notHave for content
                    // it is about to hold (a freshly-accepted block whose sub-volumes
                    // are still writing through on the source; see IvyFetcher.fetch).
                    // So do NOT punish or suppress the server: suppressing our only
                    // same-chain peer would strand the sync permanently (it has nobody
                    // else to fetch from). Just force-refetch the full accumulated
                    // closure — the hand-enumerated set plus every trace-discovered deep
                    // boundary — and retry. Resolution IS the verification, so a
                    // genuinely-bad bundle still fails closed (it is never accepted); it
                    // only ever costs a refetch, never a peer penalty.
                    let traced = await network.ivyFetcher.takeVolumeTrace()
                    var seen = Set(bundleRoots)
                    for root in traced where seen.insert(root).inserted { bundleRoots.append(root) }
                    if attempt == 2 {
                        log.warn("\(network.directory): synced block content \(String(meta.blockHash.prefix(16)))…@\(meta.blockHeight) still unresolved after retries; error=\(error); roots=\(bundleRoots.count); retrying on next sync")
                        return nil
                    }
                    log.warn("\(network.directory): synced block content \(String(meta.blockHash.prefix(16)))…@\(meta.blockHeight) not yet resolvable (attempt \(attempt)); error=\(error); refetching (availability miss, no peer penalty)")
                    let refetched = await prefetchBlockContentClosure(
                        blockHash: meta.blockHash, network: network, force: true)
                    var refetchedSet = Set(refetched)
                    for root in bundleRoots where refetchedSet.insert(root).inserted {
                        await network.ivyFetcher.fetchVolumeBundle(rootCID: root, force: true)
                    }
                }
            }
            guard let resolvedHeader = resolved else {
                log.error("\(network.directory): failed to resolve synced block content \(String(meta.blockHash.prefix(16)))… after deficiency retries")
                return nil
            }
            guard let block = resolvedHeader.node else {
                log.error("\(network.directory): synced block content \(String(meta.blockHash.prefix(16)))… resolved without a block node")
                return nil
            }

            var blockToStore = block
            var syncedPostState: LatticeState? = nil
            var syncedDiff: StateDiff? = nil
            if config.storageMode != .stateless {
                // Forward state recompute — NEVER resolveRecursive-fetch the state
                // trie. A block's content bundle carries only the trie nodes it
                // CREATED (its diff); the unchanged majority lives in ancestor
                // blocks' bundles, so fetching the whole postState needs the source
                // to serve the entire historical trie — which it cannot at depth
                // (object-grain availability), the root cause of cold-sync stalls.
                // Instead re-execute this block's transactions against its prev
                // post-state. Blocks are applied height-ascending and each is stored
                // below before the next, so prevState resolves from LOCAL CAS — the
                // same transition `verifySyncedStateTransition` checks, but here we
                // KEEP the materialized frontier to store. Fails closed: a recompute
                // that does not reproduce the declared postState root is rejected.
                let source = FetcherContentSource(fetcher)
                guard let transactions = await resolveCompleteSyncedBlockTransactions(
                    block: block, blockHash: meta.blockHash, blockHeight: meta.blockHeight,
                    directory: network.directory, source: source
                ) else { return nil }
                do {
                    let prevState = try await block.prevState.resolve(fetcher: fetcher)
                    let bodies = transactions.orderedBodies
                    let (postState, diff) = try await prevState.proveAndUpdateState(
                        allAccountActions: bodies.flatMap(\.accountActions),
                        allActions: bodies.flatMap(\.actions),
                        allDepositActions: bodies.flatMap(\.depositActions),
                        allGenesisActions: bodies.flatMap(\.genesisActions),
                        allReceiptActions: bodies.flatMap(\.receiptActions),
                        allWithdrawalActions: bodies.flatMap(\.withdrawalActions),
                        transactionBodies: bodies,
                        fetcher: fetcher
                    )
                    let postStateHeader = try LatticeStateHeader(node: postState)
                    guard postStateHeader.rawCID == block.postState.rawCID else {
                        log.error("\(network.directory): synced block \(String(meta.blockHash.prefix(16)))… recomputed postState \(String(postStateHeader.rawCID.prefix(16)))… does not match declared \(String(block.postState.rawCID.prefix(16)))…")
                        return nil
                    }
                    blockToStore = Block(
                        version: block.version,
                        parent: block.parent,
                        transactions: block.transactions,
                        target: block.target,
                        nextTarget: block.nextTarget,
                        spec: block.spec,
                        parentState: block.parentState,
                        prevState: block.prevState,
                        postState: postStateHeader,
                        children: block.children,
                        height: block.height,
                        timestamp: block.timestamp,
                        nonce: block.nonce
                    )
                    syncedPostState = postState
                    syncedDiff = diff
                } catch {
                    log.error("\(network.directory): failed to recompute synced state \(String(meta.blockHash.prefix(16)))…: \(error)")
                    return nil
                }
            }

            if config.storageMode != .stateless {
                guard let storedRoots = await storeBlockData(blockToStore, network: network) else {
                    log.error("\(network.directory): failed to store synced block content \(String(meta.blockHash.prefix(16)))…")
                    return nil
                }
                var allRoots = storedRoots
                // Complete the full state-boundary closure (state root + sub-roots) for the
                // heights this mode retains — the SAME completion the live accept path runs
                // (storeAndPinAcceptedBlock → storeAcceptedStateDiffRoots). storeBlockData
                // alone persists only this block's created diff; unchanged sub-state
                // boundaries stay unhydrated, so full-state reads (candidate build, deep
                // serving) fault to the network. Reusing the recomputed diff + post-state
                // (no re-fetch), this materializes+pins the boundary roots locally.
                if retainedStateHeights.contains(meta.blockHeight),
                   let diff = syncedDiff, let post = syncedPostState {
                    if let stateRoots = await storeAcceptedStateDiffRoots(
                           block: blockToStore, stateDiff: diff, materializedPostState: post,
                           network: network, source: FetcherContentSource(fetcher),
                           directory: network.directory) {
                        allRoots.append(contentsOf: stateRoots)
                    } else if meta.blockHash == tipHash {
                        // The TIP's full closure is load-bearing (candidate build / deep
                        // serving). Fail CLOSED like the live accept path so a later sync
                        // retries the boundary source-agnostically, rather than reporting
                        // success with an incomplete tip state (the exact gap this fixes).
                        log.error("\(network.directory): synced tip \(String(meta.blockHash.prefix(16)))… state-boundary completion failed — failing sync to retry")
                        return nil
                    } else {
                        // A deep retained (historical) height: don't stall a large sync on
                        // one momentarily-unfetchable boundary — it completes when a live
                        // block re-folds it (storeAndPinAcceptedBlock). Surface the gap.
                        log.warn("\(network.directory): synced height \(meta.blockHeight) state closure incomplete (diff-only) — completes on next live block")
                    }
                }
                rootsByHeight[meta.blockHeight] = allRoots
            }

            if meta.blockHash == tipHash {
                syncedTip = blockToStore
            }
            blocksByHeight[meta.blockHeight] = blockToStore
        }

        guard let syncedTip else { return nil }
        return (syncedTip, rootsByHeight, blocksByHeight)
    }

    /// Recursive multi-chain sync wave. A chain syncs and finalizes itself first;
    /// only then do its direct subscribed children start syncing, in parallel. Each
    /// child runs this same method after finalizing, so arbitrary-depth trees sync
    /// parent-before-child without serializing independent siblings.
    func syncSubscribedChildren(of parentDirectory: String) async {
        struct ChildSyncCandidate: Sendable {
            let network: ChainNetwork
            let tipCID: String
        }

        var candidates: [ChildSyncCandidate] = []
        let childNetworks = networks.values.filter { $0.parentDirectory == parentDirectory }
        for childNetwork in childNetworks {
            guard !producesChildInProcess(network: childNetwork) else { continue }
            guard let childChain = await chain(for: childNetwork.directory) else { continue }
            let localHeight = await childChain.getHighestBlockHeight()
            guard let tips = knownPeerTips[chainKey(forPath: childNetwork.chainPath)] else { continue }
            guard let best = tips.values
                .filter({ $0.height > localHeight })
                .max(by: { $0.height < $1.height }) else { continue }
            candidates.append(ChildSyncCandidate(network: childNetwork, tipCID: best.tipCID))
        }

        guard !candidates.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for candidate in candidates {
                group.addTask { [weak self] in
                    // Recursive child wave: children reorg via gossip / held-heavier
                    // rescue, not this transient-retry loop, so the outcome is discarded.
                    _ = await self?.performHeadersFirstSync(
                        peerTipCID: candidate.tipCID,
                        network: candidate.network
                    )
                }
            }
        }
    }

    /// Returns the best connected, tally-allowed tip CID plus the PeerID for bulk header requests.
    /// `defaultTipHeight` is the announced height of `defaultTipCID` when the caller
    /// got the tip from an (unvalidated, deliberately unrecorded) announcement.
    func bestConnectedPeerTipWithPeer(
        defaultTipCID: String,
        defaultTipHeight: UInt64? = nil,
        network: ChainNetwork,
        preferredPeer: PeerID? = nil
    ) async -> (String, PeerID?) {
        let connectedPeers = await network.ivy.connectedPeers
        let tally = await network.ivy.tally
        let connectedPreferred = preferredPeer.flatMap { p in
            connectedPeers.first(where: { $0.publicKey == p.publicKey })
        }
        // Source-agnostic but still reputation-gated: a peer is only a fetch hint
        // (authority is PoW + ChildBlockProof), yet a peer that has misbehaved below
        // Tally's allow-threshold must still be skipped — exactly as the recorded-tip
        // loop skips it. Source agnosticism must not become a Tally bypass (audit H1).
        // The preferred (announcing) peer is Tally-gated too: the original preferred
        // path checked it, so the fallback must not silently re-admit a disallowed one.
        let allowedPreferred = connectedPreferred.flatMap { tally.shouldAllow(peer: $0) ? $0 : nil }
        let anyAllowedPeer = allowedPreferred ?? connectedPeers.first(where: { tally.shouldAllow(peer: $0) })
        guard let tips = knownPeerTips[chainKey(forPath: network.chainPath)], !tips.isEmpty else {
            // Source-agnostic: a peer is only a fetch hint — authority is PoW +
            // ChildBlockProof, never peer identity (consensus-fork-choice.md: "the
            // source does not make the data authoritative"; SOTA: Bitcoin IBD
            // PR#2964 removed single-source dependence). With no preferred peer and
            // no recorded tip, fall back to ANY connected same-chain peer rather
            // than returning nil — which fails child sync closed while peers exist.
            return (defaultTipCID, anyAllowedPeer)
        }
        var best: (key: String, height: UInt64, tipCID: String, peer: PeerID)? = nil
        for peer in connectedPeers {
            guard let entry = tips[peer.publicKey] else { continue }
            guard tally.shouldAllow(peer: peer) else { continue }
            guard !syncOutcomes.isFailed(tip: entry.tipCID) else { continue }
            if best == nil || entry.height > best!.height {
                best = (key: peer.publicKey, height: entry.height, tipCID: entry.tipCID, peer: peer)
            }
        }
        // Announce-driven syncs pass the just-announced tip as the default. It is
        // deliberately NOT recorded into knownPeerTips (it's unvalidated — recording
        // would poison best-tip selection), so when it claims a height above every
        // recorded connected-peer tip the sync must target it directly. Otherwise
        // every announce-driven catch-up re-syncs a stale recorded tip, gets refused
        // for insufficient work, and the node never reaches the announced height.
        // Targeting it is safe: the headers-first path fully validates (PoW +
        // cumulative work) before any adoption.
        if let defaultTipHeight,
           !syncOutcomes.isFailed(tip: defaultTipCID),
           best == nil || defaultTipHeight > best!.height {
            return (defaultTipCID, anyAllowedPeer)
        }
        if let preferredPeer,
           let connectedPreferred = connectedPeers.first(where: { $0.publicKey == preferredPeer.publicKey }),
           let preferredEntry = tips[preferredPeer.publicKey],
           tally.shouldAllow(peer: connectedPreferred),
           !syncOutcomes.isFailed(tip: preferredEntry.tipCID),
           best == nil || preferredEntry.height >= best!.height {
            // Preferred peer is a source hint for this announced tip, not fork
            // choice. Header validation and cumulative work still decide adoption.
            return (preferredEntry.tipCID, connectedPreferred)
        }
        return (best?.tipCID ?? defaultTipCID, best?.peer ?? anyAllowedPeer)
    }

    func verifySyncWithPeers(tipCID: String, tipHeight: UInt64, network: ChainNetwork) async {
        let log = NodeLogger("sync")
        let peerCount = await network.ivy.peerConnectionCount
        if peerCount < 2 {
            log.warn("Sync completed with only \(peerCount) peer(s) — insufficient for cross-verification")
            return
        }

        let verifyStub = VolumeImpl<Block>(rawCID: tipCID, node: nil, encryptionInfo: nil)
        if let block = try? await verifyStub.resolve(fetcher: network.ivyFetcher).node {
            let valid = block.height == tipHeight
            if valid {
                log.info("Sync verified: tip at height \(tipHeight) with \(peerCount) connected peers")
            } else {
                log.warn("Sync tip height mismatch: expected \(tipHeight), got \(block.height)")
            }
        } else {
            log.warn("Sync verification: could not resolve tip block from CAS")
        }
    }

    func isChildChainSyncing(directory: String) -> Bool {
        isChainSyncing(directory: directory) || isChainUnhealthy(directory: directory)
    }

    func isChildChainSyncing(chainPath: [String]) -> Bool {
        isChainSyncing(chainPath: chainPath) || isChainUnhealthy(chainPath: chainPath)
    }


    /// Sum the proof-of-work for all blocks in the local retention window.
    /// Underestimates when blocks have been pruned beyond `retentionDepth`,
    /// but any positive floor is strictly safer than passing UInt256.zero
    /// to the syncer (which disables the work comparison entirely).
    func localCumulativeWork(for directory: String) async -> UInt256 {
        await localCumulativeWork(chainPath: chainPath(forDirectory: directory))
    }

    func localCumulativeWork(chainPath: [String]) async -> UInt256 {
        // P-801: one actor hop instead of O(retentionDepth) sequential hops.
        // getCumulativeWork walks hashToBlock entirely inside the ChainState actor.
        guard let chainState = await chain(forPath: chainPath) else { return UInt256.zero }
        return await chainState.getCumulativeWork(limit: config.retentionDepth)
    }
}
