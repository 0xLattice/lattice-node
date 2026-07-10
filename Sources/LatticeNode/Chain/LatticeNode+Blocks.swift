import Lattice
import Foundation
import Ivy
import VolumeBroker
import Tally
import cashew
import UInt256

// Block-acceptance orchestrator for LatticeNode.
// this file coordinates block processing and reorg recovery; the
// validation, storage, reorg, and side-effect responsibilities live in the
// sibling LatticeNode+Block*.swift extensions. Behavior-preserving split.

extension LatticeNode {

    static let maxTimestampDriftMs: Int64 = 7_200_000
    static let maxTimestampAgeMs: Int64 = 86_400_000
    enum BlockProcessOutcome {
        case accepted
        case duplicate
        case rejected
        case storageFailed
        /// processBlockHeader failed because a sub-CID fetch exhausted all sources.
    }

    private func failDurable(_ reason: String, directory: String, chainPath: [String]? = nil) async -> BlockProcessOutcome {
        if let chainPath {
            await markChainUnhealthy(chainPath: chainPath, reason: reason)
        } else {
            await markChainUnhealthy(directory: directory, reason: reason)
        }
        return .storageFailed
    }

    private func failStorageDegraded(_ reason: String, directory: String, chainPath: [String]? = nil) async -> BlockProcessOutcome {
        if let chainPath {
            await markChainStorageDegraded(chainPath: chainPath, reason: reason)
        } else {
            await markChainStorageDegraded(directory: directory, reason: reason)
        }
        return .storageFailed
    }

    func shouldDropNonAdvancingGossipBlock(_ block: Block, cid: String, network: ChainNetwork) async -> Bool {
        let chainState: ChainState?
        if let byPath = await chain(forPath: network.chainPath) {
            chainState = byPath
        } else {
            chainState = await chain(for: network.directory)
        }
        guard let chainState else { return false }
        let localHeight = await chainState.getHighestBlockHeight()
        if block.height < localHeight { return true }
        // Equal-height siblings do not win fork choice on receipt. Retain them
        // only when their full bundle is already local; otherwise treat gossip as
        // a soft availability hint and let a strictly higher extension trigger
        // headers-first sync if that side later becomes heavier.
        if block.height == localHeight {
            return !(await network.ivyFetcher.hasCompleteLocalBundle(rootCID: cid))
        }
        return false
    }

    /// Carries the durable-storage result out of the `beforeCommit` hook (which
    /// must be `@Sendable`) back to the caller after `processBlockHeader` returns.
    /// Access is serialised by the per-chain mutation lock and the hook completes
    /// before `processBlockHeader` returns, so the unchecked Sendable is safe.
    final class DurableCommitBox: @unchecked Sendable {
        var canonicalRoots: [String]?
        var stateDiff: StateDiff = .empty
        var failureReason: String?
    }

    /// Durable-store-then-commit (Theme 1): persist the validated block's content,
    /// state, and consensus pin BEFORE the in-memory tip advances. Run as the
    /// `processBlockHeader` `beforeCommit` hook. Once consensus validation has
    /// accepted the block, a required durable-store failure is a local safety
    /// failure: abort the commit and propagate a typed storage failure so the node
    /// fails closed instead of continuing to serve from an ambiguous boundary.
    func persistAcceptedBlockDurably(
        block: Block,
        blockHash: String,
        diff: StateDiff,
        materializedPostState: LatticeState?,
        preStoredContentRoots: [String]?,
        network: ChainNetwork,
        directory: String,
        source: any ContentSource,
        box: DurableCommitBox
    ) async -> Bool {
        func fail(_ reason: String) -> Bool {
            box.failureReason = reason
            return false
        }

        let contentRoots: [String]
        if let preStoredContentRoots {
            contentRoots = preStoredContentRoots
        } else if let r = await storeBlockData(block, network: network) {
            contentRoots = r
        } else {
            return fail("failed to durably store accepted block content before consensus commit")
        }
        guard let stateRoots = await storeAcceptedStateDiffRoots(
            block: block, stateDiff: diff, materializedPostState: materializedPostState,
            network: network, source: source, directory: directory
        ) else {
            return fail("failed to durably materialize accepted state roots before consensus commit")
        }
        guard let canonicalRoots = await canonicalBlockStorageRoots(
            block: block, blockHash: blockHash, collectedRoots: contentRoots + stateRoots,
            stateDiff: diff, network: network, directory: directory, source: source
        ) else {
            return fail("failed to verify accepted canonical roots are durable before consensus commit")
        }
        guard await pinBlockStorageForConsensus(block, network: network) else {
            return fail("failed to pin accepted canonical block content before consensus commit")
        }
        box.canonicalRoots = canonicalRoots
        box.stateDiff = diff
        return true
    }

    func processBlockAndRecoverReorg(
        header: BlockHeader,
        directory: String,
        chainPath: [String]? = nil,
        fetcher: Fetcher,
        resolvedBlock: Block? = nil,
        rootHash: UInt256? = nil,
        parentAnchor: ParentAnchor? = nil,
        requireDurableResolvedBlock: Bool = false,
        preStoredCIDs: [String]? = nil,
        storageBrokerOverride: (any VolumeBroker)? = nil,
        baseValidationSourceOverride: (any ContentSource)? = nil,
        allowBelowTipHeight: Bool = false
    ) async -> BlockProcessOutcome {
        let key = chainPath.map { chainKey(forPath: $0) } ?? chainKey(forDirectory: directory)
        return await withChainMutation(key) {
            await processBlockAndRecoverReorgUnlocked(
                header: header,
                directory: directory,
                chainPath: chainPath,
                fetcher: fetcher,
                resolvedBlock: resolvedBlock,
                rootHash: rootHash,
                parentAnchor: parentAnchor,
                requireDurableResolvedBlock: requireDurableResolvedBlock,
                preStoredCIDs: preStoredCIDs,
                storageBrokerOverride: storageBrokerOverride,
                baseValidationSourceOverride: baseValidationSourceOverride,
                allowBelowTipHeight: allowBelowTipHeight
            )
        }
    }

    private func processBlockAndRecoverReorgUnlocked(
        header: BlockHeader,
        directory: String,
        chainPath: [String]? = nil,
        fetcher: Fetcher,
        resolvedBlock: Block? = nil,
        rootHash: UInt256? = nil,
        parentAnchor: ParentAnchor? = nil,
        requireDurableResolvedBlock: Bool = false,
        preStoredCIDs: [String]? = nil,
        storageBrokerOverride: (any VolumeBroker)? = nil,
        baseValidationSourceOverride: (any ContentSource)? = nil,
        allowBelowTipHeight: Bool = false
    ) async -> BlockProcessOutcome {
        let key = chainPath.map { chainKey(forPath: $0) } ?? chainKey(forDirectory: directory)
        let keyedNetwork = chainPath.flatMap { network(forPath: $0) }
        guard !unhealthyChains.contains(key) else { return .storageFailed }
        let chain: ChainState?
        if let chainPath {
            chain = await self.chain(forPath: chainPath)
        } else {
            chain = await self.chain(for: directory)
        }
        guard let chain else { return .rejected }

        // Peers echo our own block announcements back via gossip. Detect the
        // duplicate here so the caller can record peer success without
        // warning or re-announcing.
        if await chain.contains(blockHash: header.rawCID) {
            if let block = resolvedBlock, let parentAnchor {
                await persistVerifiedParentHeaderEdge(directory: directory, anchor: parentAnchor)
                try? await persistAcceptedChildParentAnchor(
                    directory: directory,
                    blockHash: header.rawCID,
                    height: block.height,
                    parentAnchor: parentAnchor,
                    replaceExisting: true
                )
            }
            return .duplicate
        }

        // A gossip echo can arrive ~60ms after we submit/receive a block, while
        // the first call is still suspended inside `lattice.processBlockHeader`.
        // The chain hasn't recorded the block yet, so `chain.contains` above
        // misses it. Guard with an in-flight set so the echo short-circuits
        // instead of re-validating.
        if inFlightBlockCIDs.contains(header.rawCID) {
            if let block = resolvedBlock, let parentAnchor {
                await persistVerifiedParentHeaderEdge(directory: directory, anchor: parentAnchor)
                try? await persistAcceptedChildParentAnchor(
                    directory: directory,
                    blockHash: header.rawCID,
                    height: block.height,
                    parentAnchor: parentAnchor,
                    replaceExisting: true
                )
            }
            return .duplicate
        }
        inFlightBlockCIDs.insert(header.rawCID)
        defer { inFlightBlockCIDs.remove(header.rawCID) }

        let tipBefore = await chain.getMainChainTip()

        // When processing nexus blocks, child block validation needs access to
        // state data in child CAS stores (e.g., radix trie nodes for the
        // frontier state). Build a composite ContentSource that falls back to
        // child CAS stores when the nexus CAS doesn't have the requested data.
        // Include the mempool cache so TX bodies submitted to this chain's mempool
        // are resolvable during block validation (critical for per-process
        // external miners).
        //
        // CONSENSUS SAFETY: `validationSource` is the single content-resolution
        // input for this block — authoritative validation (`processBlockHeader(
        // source:)`), the durable-storage materialization, and the parent-anchor
        // continuity check all resolve over it. The composition (mempool overlay
        // precedence + fallback order) is the exact one the retired per-CID
        // fetcher zoo (mempool-aware → child/parent-state fallbacks) used.
        // The innermost base mirrors the PASSED-IN `fetcher`: the gossip +
        // mined-nexus paths pass `network.ivyFetcher` directly (→ native
        // `IvyContentSource`, the wave-batching win); the mined-child /
        // parent-extraction / side-effect paths supply a NATIVE base source via
        // `baseValidationSourceOverride` (the proof overlay), and any other wrapped
        // non-network-ivy fetcher is bridged with the exact `FetcherContentSource`
        // so resolution stays byte-identical.
        let sourceNetwork = keyedNetwork ?? network(for: directory)
        let baseSource: any ContentSource
        if let baseValidationSourceOverride {
            // Caller supplied a NATIVE base source that resolves byte-identically
            // to the passed-in `fetcher`. The wrapped-base callers (mined-child
            // Mining, side-effect BlockSideEffects) pass a proof overlay over
            // `network.ivyFetcher`; their override is
            // `OverlayContentSource(proofEntries, IvyContentSource(network.ivyFetcher))`,
            // so the proof-overlay bases get wave-batching too, without diverging
            // from the fetcher they replace.
            baseSource = baseValidationSourceOverride
        } else if let ivyFetcher = fetcher as? IvyFetcher, let net = sourceNetwork, ivyFetcher === net.ivyFetcher {
            baseSource = IvyContentSource(ivyFetcher)
        } else {
            // Bridge: passed-in fetcher is a wrapped/non-network-ivy fetcher
            // (mined-child proof overlay, parent-extraction composite, or the
            // side-effect proof overlay). Sequential per-CID, semantics-exact.
            baseSource = FetcherContentSource(fetcher)
        }
        let mempoolAwareSource = await buildMempoolAwareSource(directory: directory, baseSource: baseSource)
        let validationSource: any ContentSource
        if directory == genesisConfig.directory {
            let childSources = await lattice.nexus.childDirectories()
                .compactMap { network(for: $0)?.ivyFetcher }
                .map { IvyContentSource($0) as any ContentSource }
            if childSources.isEmpty {
                validationSource = mempoolAwareSource
            } else {
                validationSource = CompositeContentSource([mempoolAwareSource] + childSources)
            }
        } else if let parentStateFetcher = parentStateFetchers[directory] {
            // Parent-state fetcher is registered as an `IvyFetcher` in practice
            // (BackgroundLoops.startParentChainSubscription) though typed as
            // `Fetcher`. Use the native source when it is one; otherwise bridge.
            let parentSource: any ContentSource = (parentStateFetcher as? IvyFetcher).map { IvyContentSource($0) }
                ?? FetcherContentSource(parentStateFetcher)
            validationSource = CompositeContentSource([mempoolAwareSource, parentSource])
        } else {
            validationSource = mempoolAwareSource
        }

        // Monotonicity check using only data already in hand (no extra CAS fetch).
        // When the block is pre-resolved AND its parent is the current tip, the
        // tip snapshot has the parent's timestamp. This covers the common gossip
        // path (extending the tip). Skip for reorg candidates (parent != tip) —
        // the Lattice framework validates the target transition there.
        var blockForProcessing = resolvedBlock
        var durablyStoredCIDs = preStoredCIDs
        // Height-monotonicity DoS guard: a PUSHED block below the local tip
        // height costs a full validation for something that can never extend
        // the tip, so gossip drops it cheaply. `allowBelowTipHeight` is the
        // PULL exception — the held-heavier connector rescue re-submits a
        // proof-verified interior block precisely because the chain declared
        // it a missing ancestor of a held heavier subtree; the block still
        // runs the complete validation/durability pipeline below.
        if let block = blockForProcessing, !allowBelowTipHeight {
            let localHeight = await chain.getHighestBlockHeight()
            if block.height < localHeight {
                return .rejected
            }
        }
        if requireDurableResolvedBlock,
           let block = blockForProcessing,
           let network = keyedNetwork ?? network(for: directory) {
            // Whole-object-by-root: fetch the block's CONTENT closure as whole
            // volumes keyed by their roots (block bundle, spec, per-tx volumes)
            // BEFORE resolving. A gossiped block arrives as the bare block node;
            // its in-package trie internals (tx bodies, sub-volume entries) live in
            // sub-volume groupings that a root-only serve gate delivers only inside
            // the OWNING bundle — never as standalone by-CID responses. Without this
            // warm-up the on-demand resolution wave would miss an internal and
            // request it standalone (refused), stranding the gossip-accept path the
            // same way headers-first sync would. This is a no-op once the closure is
            // local (mined/already-fetched blocks), so it only costs the gossip
            // followers a one-shot whole-closure fetch.
            // Skip the whole-closure network warm-up when this block's content is ALREADY
            // durably stored locally (the mined path supplies `preStoredCIDs`). The carrier's
            // own content is local, and a MERGED carrier embeds a CHILD block whose content it
            // does NOT own — warming the closure over the network then blocks ~15s per call on
            // the child's unreachable content, serializing merged block production to ~31s/block.
            // Gossip followers (no preStoredCIDs) still warm their closure exactly as before.
            let contentAlreadyLocal = durablyStoredCIDs != nil
            if !contentAlreadyLocal {
                await prefetchBlockContentClosure(blockHash: header.rawCID, network: network)
            }
            let localHeightAfterPrefetch = await chain.getHighestBlockHeight()
            if block.height < localHeightAfterPrefetch, !allowBelowTipHeight {
                return .rejected
            }
            guard let durableBlock = await resolveBlockForDurableValidation(
                header: header,
                block: block,
                directory: directory,
                network: network,
                source: validationSource,
                skipNetworkPrefetch: contentAlreadyLocal
            ) else {
                return .rejected
            }
            blockForProcessing = durableBlock
            guard let storedRoots = await storeBlockContentForDurableValidation(
                header: header,
                block: durableBlock,
                directory: directory,
                network: network,
                preStoredCIDs: preStoredCIDs,
                storageBrokerOverride: storageBrokerOverride
            ) else {
                return .storageFailed
            }
            durablyStoredCIDs = storedRoots
            await preWarmValidationCache(durableBlock, network: network)
        }

        if let block = blockForProcessing,
           let parentCID = block.parent?.rawCID,
           parentCID == tipBefore,
           let tipSnapshot = await chain.tipSnapshot {
            if !isBlockTimestampValid(block, parentTimestamp: tipSnapshot.timestamp) {
                if let durablyStoredCIDs,
                   let network = keyedNetwork ?? network(for: directory) {
                    await unpinBlockStorageForRejectedCandidate(block, storedRoots: durablyStoredCIDs, network: network)
                }
                return .rejected
            }
        }

        if let block = blockForProcessing,
           !(await validateParentAnchorConsistencyBeforeSubmit(
                directory: directory,
                blockHash: header.rawCID,
                block: block,
                parentAnchor: parentAnchor,
                source: validationSource
           )) {
            NodeLogger("blocks").warn("\(directory): block \(String(header.rawCID.prefix(16)))… breaks parent state root continuity")
            if let durablyStoredCIDs,
               let network = keyedNetwork ?? network(for: directory) {
                await unpinBlockStorageForRejectedCandidate(block, storedRoots: durablyStoredCIDs, network: network)
            }
            return .rejected
        }

        let phLog = NodeLogger("blocks")
        let phShort = String(header.rawCID.prefix(16))
        // Reset fetch-failure flag so we can detect incomplete volumes.
        // Compute the full chain path for this directory in the global hierarchy.
        // For per-process nodes processing their own chain or child chains, this
        // must reflect the actual depth (e.g. ["Nexus","Mid","AlphaChain"] for a grandchild).
        let blockChainPath = chainPath ?? globalChainPath(for: directory)
        let processingLattice = await latticeView(for: blockChainPath)
        // Theme 1 (durable-store-then-commit): for the durable paths, persist the
        // validated block + state + consensus pin in `beforeCommit` — which runs
        // after validation but BEFORE the in-memory tip advances — so the chain
        // can never advance past durable storage. A storage failure (e.g. a
        // transient backend outage) aborts the commit (`.deferred`) rather than
        // halting the chain, and the block is retried once storage is back.
        let durableBox = DurableCommitBox()
        let durableNetwork = keyedNetwork ?? network(for: directory)
        let beforeCommitHook: (@Sendable (Block, StateDiff, LatticeState?) async -> Bool)?
        if requireDurableResolvedBlock, let net = durableNetwork {
            let preStored = durablyStoredCIDs
            let blockHash = header.rawCID
            let vsource = validationSource
            let dir = directory
            beforeCommitHook = { committedBlock, diff, postState in
                await self.persistAcceptedBlockDurably(
                    block: committedBlock, blockHash: blockHash, diff: diff,
                    materializedPostState: postState, preStoredContentRoots: preStored,
                    network: net, directory: dir, source: vsource, box: durableBox)
            }
        } else {
            beforeCommitHook = nil
        }
        // CONSENSUS-CRITICAL: authoritative validation over `validationSource`
        // (mempool overlay → base → fallbacks; proven #287). The Lattice `source:`
        // overload delegates to `fetcher: CoalescingFetcher(source)` (byte-identical,
        // Lattice 13.1.2), so the wave-batched source is content-neutral.
        let processingResult = await processingLattice.processBlockHeader(
            header,
            source: validationSource,
            rootHash: rootHash,
            chainPath: blockChainPath,
            beforeCommit: beforeCommitHook
        )
        guard processingResult.isAccepted else {
            if let failureReason = durableBox.failureReason {
                if let block = blockForProcessing,
                   let durablyStoredCIDs,
                   let network = keyedNetwork ?? network(for: directory) {
                    await unpinBlockStorageForRejectedCandidate(block, storedRoots: durablyStoredCIDs, network: network)
                }
                // Defer-don't-fault during sync (Bitcoin IBD / Geth fetcher–downloader
                // pattern): while this chain is actively backfilling, a gossip/extracted
                // block can fail durable commit ONLY because its ancestor state isn't
                // materialized yet — a transient "not caught up", not storage corruption.
                // The beforeCommit hook already aborted (the tip did not advance), so
                // treat it as a soft rejection (`.rejected` = "missing state, not fraud",
                // no peer penalty) and let sync re-deliver it once contiguous. Degrading
                // here would STOP the very sync that heals the gap. Steady state (not
                // syncing) still fails closed: a genuine durability fault degrades.
                let chainIsSyncing = blockChainPath.map { isChainSyncing(chainPath: $0) } ?? isSyncing
                if chainIsSyncing {
                    NodeLogger("blocks").info("\(directory): deferring premature block \(String(header.rawCID.prefix(16)))… while syncing (\(failureReason)); sync will re-deliver")
                    return .rejected
                }
                return await failStorageDegraded(failureReason, directory: directory, chainPath: blockChainPath)
            }
            if await chain.contains(blockHash: header.rawCID) {
                if let block = blockForProcessing, let parentAnchor {
                    await persistVerifiedParentHeaderEdge(directory: directory, anchor: parentAnchor)
                    try? await persistAcceptedChildParentAnchor(
                        directory: directory,
                        blockHash: header.rawCID,
                        height: block.height,
                        parentAnchor: parentAnchor
                    )
                }
                return .duplicate
            }
            let candidateParent = blockForProcessing?.parent?.rawCID ?? "nil"
            let candidateHeight = blockForProcessing?.height ?? 0
            phLog.warn("\(directory): block \(phShort)… rejected by processBlockHeader height=\(candidateHeight) parent=\(String(candidateParent.prefix(16)))… tipBefore=\(String(tipBefore.prefix(16)))… path=\((blockChainPath ?? []).joined(separator: "/"))")
            if let block = blockForProcessing,
               let durablyStoredCIDs,
               let network = keyedNetwork ?? network(for: directory) {
                await unpinBlockStorageForRejectedCandidate(block, storedRoots: durablyStoredCIDs, network: network)
            }
            return .rejected
        }
        let stateDiff = processingResult.stateDiff

        let block: Block?
        if let r = blockForProcessing {
            block = r
        } else {
            block = try? await header.resolve(fetcher: fetcher).node
        }
        guard let block else {
            return await failDurable("accepted block content unavailable after fork-choice update", directory: directory)
        }
        guard let network = keyedNetwork ?? network(for: directory) else {
            return await failDurable("accepted block has no chain network for durable storage", directory: directory)
        }
        let canonicalRoots: [String]
        if let preCommittedRoots = durableBox.canonicalRoots {
            // Theme 1 durable path: content + state + consensus pin were already
            // persisted in `beforeCommit`, BEFORE this in-memory commit. The tip
            // advanced only because that storage succeeded, so there is nothing
            // left to store here — just finalize bookkeeping and release the
            // now-superseded candidate pins.
            canonicalRoots = preCommittedRoots
            guard await finalizeDurableBlockStorage(block, blockHash: header.rawCID, storedRoots: canonicalRoots, network: network, directory: directory, stateDiff: stateDiff) else {
                return await failStorageDegraded("failed to finalize accepted canonical block storage", directory: directory)
            }
            do {
                try await releaseStaleCandidatePins(block: block, network: network)
            } catch {
                NodeLogger("blocks").warn("\(directory): failed to release promoted candidate pins at height \(block.height): \(error)")
            }
        } else {
            // Non-`beforeCommit` paths (no durable requirement): store after the
            // in-memory commit, as before.
            let storedRoots: [String]?
            if let durablyStoredCIDs {
                storedRoots = durablyStoredCIDs
            } else {
                storedRoots = await storeBlockData(block, network: network)
            }
            guard let storedRoots else {
                return await failDurable("failed to durably store accepted block content", directory: directory)
            }
            guard let stateRoots = await storeAcceptedStateDiffRoots(
                block: block,
                stateDiff: stateDiff,
                materializedPostState: processingResult.materializedPostState,
                network: network,
                source: validationSource,
                directory: directory
            ) else {
                return await failDurable("failed to durably materialize accepted state roots", directory: directory)
            }
            guard let computedCanonicalRoots = await canonicalBlockStorageRoots(
                block: block,
                blockHash: header.rawCID,
                collectedRoots: storedRoots + stateRoots,
                stateDiff: stateDiff,
                network: network,
                directory: directory,
                source: validationSource
            ) else {
                return await failDurable("failed to verify accepted canonical roots are durable", directory: directory)
            }
            canonicalRoots = computedCanonicalRoots
            if durablyStoredCIDs != nil {
                guard await pinBlockStorageForConsensus(block, network: network) else {
                    return await failStorageDegraded("failed to pin accepted canonical block content", directory: directory)
                }
                guard await finalizeDurableBlockStorage(block, blockHash: header.rawCID, storedRoots: canonicalRoots, network: network, directory: directory, stateDiff: stateDiff) else {
                    return await failStorageDegraded("failed to finalize accepted canonical block storage", directory: directory)
                }
                do {
                    try await releaseStaleCandidatePins(block: block, network: network)
                } catch {
                    NodeLogger("blocks").warn("\(directory): failed to release promoted candidate pins at height \(block.height): \(error)")
                }
            } else {
                guard await commitBlockStorage(block, storedRoots: canonicalRoots, network: network, directory: directory, stateDiff: stateDiff) else {
                    return await failStorageDegraded("failed to commit accepted canonical block storage", directory: directory)
                }
                await preWarmValidationCache(block, network: network)
            }
        }
            cacheNextTarget(blockCID: header.rawCID, value: block.nextTarget)
            let canonicalTipAfterValidation = await chain.getMainChainTip()
            if canonicalTipAfterValidation == header.rawCID {
                let txSource = await buildMempoolAwareSource(directory: directory, baseFetcher: fetcher)
                let txEntries = await resolveBlockTransactions(block: block, source: txSource)
                // This block IS the canonical main-chain tip (fork choice just promoted it).
                // The durable tip MUST advance to it even when its height is <= the previous
                // durable height — a heaviest-work reorg to a HEAVIER-BUT-SHORTER branch
                // legitimately lowers the tip height. Without `allowLowerHeightReplay`, the
                // `prepareAcceptedBlockEffects` height-skip guard (meant to drop a STALE
                // non-canonical lower block) silently skips the durable commit, leaving
                // meta:chain-tip behind the in-memory tip; on restart recovery then projects
                // the in-memory tip DOWN to that stale pointer, losing accepted blocks. The
                // guard still protects the side-fork branch below (which is NOT the tip and is
                // never committed), so only the genuine canonical tip is allowed to lower.
                guard await applyAcceptedBlock(
                    block: block, blockHash: header.rawCID,
                    txEntries: txEntries, directory: directory,
                    allowLowerHeightReplay: true
                ) else {
                    return await failDurable("failed to durably publish accepted block", directory: directory)
                }
            } else {
                // `processBlockHeader` may accept a valid side fork without
                // promoting it. Keep its content/proofs available for future
                // inherited-work promotion, but never publish a non-canonical
                // side block as meta:chain-tip.
                do {
                    try await network.pinBatchDurably(
                        roots: canonicalRoots,
                        owner: canonicalStorageOwner(block: block, network: network)
                    )
                } catch {
                    NodeLogger("blocks").error("\(directory): failed to pin accepted side-fork content for \(String(header.rawCID.prefix(16)))…: \(error)")
                    return await failDurable("failed to pin accepted side-fork content", directory: directory)
                }
                await persistParentStateEdgesForChildContinuity(
                    parentDirectory: directory,
                    block: block,
                    blockHash: header.rawCID
                )
            }
            do {
                try await persistAcceptedChildParentAnchor(
                    directory: directory,
                    blockHash: header.rawCID,
                    height: block.height,
                    parentAnchor: parentAnchor,
                    replaceExisting: true
                )
            } catch {
                NodeLogger("blocks").error("\(directory): persistChildParentAnchor failed at height \(block.height): \(error)")
            }

        let tipAfter = await chain.getMainChainTip()
        tipCaches[key]?.update(tipAfter)
        if tipBefore != tipAfter {
            let parentOfNewTip = await chain.getConsensusBlock(hash: tipAfter)?.parentBlockHash
            if parentOfNewTip != tipBefore {
                // A multi-block reorg can promote blocks that did not pass through
                // the immediate-tip apply path above. Publish their canonical side
                // effects (receipts, tx_history, nonces, parent-header edges) before
                // reconciling the durable height->hash commitment.
                guard await publishCanonicalTransition(
                    oldTip: tipBefore,
                    newTip: tipAfter,
                    directory: directory,
                    chain: chain,
                    source: baseSource,
                    reason: "block-processing"
                ) else {
                    return await failDurable("failed to publish accepted canonical transition", directory: directory)
                }
            }
        }

        return .accepted
    }
    nonisolated public func chainNetwork(
        _ network: ChainNetwork,
        didReceiveBlock cid: String,
        data: Data,
        from peer: PeerID
    ) async {
        if await isPeerBlockRateLimited(peer) { return }

        let tally = await network.ivy.tally
        if data.count > genesisConfig.spec.maxBlockSize {
            // Hard violation: an oversized block is unforgeable fraud — escalate
            // to a durable ban on repeat (M2).
            tally.recordFailure(peer: peer)
            await recordHardFault(peer: peer, network: network)
            return
        }

        let now = ContinuousClock.Instant.now
        let key = cid
        if let lastSeen = await recentBlockTime(for: key) {
            let elapsed = now - lastSeen
            if elapsed < (await blockDeduplicationWindow) {
                return
            }
        }

        tally.recordReceived(peer: peer, bytes: data.count)

        // Validate before storing — don't waste disk on invalid blocks
        guard let block = Block(data: data) else {
            tally.recordFailure(peer: peer)
            return
        }
        guard ChainNetwork.blockCIDMatches(cid, block: block) else {
            // Hard violation: announced CID doesn't match the block bytes —
            // unforgeable fraud — escalate to a durable ban on repeat (M2).
            tally.recordFailure(peer: peer)
            await recordHardFault(peer: peer, network: network)
            return
        }
        await recordBlockTime(key: key, time: now)

        if !isBlockTimestampValid(block) {
            tally.recordFailure(peer: peer)
            return
        }
        guard block.spec.rawCID == genesisResult.block.spec.rawCID else {
            return
        }

        // Reject insufficient-PoW before any CAS write. A block whose own hash
        // doesn't meet its claimed target costs zero PoW to forge; we must
        // not spend a disk write or a retention slot on it.
        // Gap-4: disconnect immediately on PoW violation (go-ethereum lesson).
        // tally.recordFailure alone is too slow — an attacker flooding invalid
        // blocks can saturate the actor queue before tally triggers disconnect.
        if !isBlockPoWValid(block) {
            // Hard violation: a block that doesn't meet its claimed target is
            // unforgeable fraud. Repeats escalate to a durable ban (M2); a single
            // offense keeps the immediate disconnect (Gap-4). recordHardFault
            // already disconnects via the ban path when it fires, so only
            // disconnect here if it did not.
            tally.recordFailure(peer: peer)
            if !(await recordHardFault(peer: peer, network: network)) {
                await network.ivy.disconnect(peer)
            }
            return
        }

        if block.height == 0 && block.parent != nil {
            tally.recordFailure(peer: peer)
            return
        }

        let directory = network.directory
        if await shouldDropNonAdvancingGossipBlock(block, cid: cid, network: network) {
            tally.recordSuccess(peer: peer)
            return
        }
        // Skip CAS store + processing for blocks we've already accepted.
        // hashToBlock contains only blocks we've fully processed, so presence
        // implies the block and its state are already resident in CAS.
        if let chainState = await chain(for: directory),
           await chainState.contains(blockHash: cid) {
            tally.recordSuccess(peer: peer)
            return
        }

        // Cap concurrent gossip validations to keep IvyFetcher actor responsive.
        // Dropped blocks will be re-announced and retried when the queue drains.
        if await inFlightBlockCIDs.count >= maxConcurrentGossipValidations { return }

        let blockFetcher = network.ivyFetcher
        await blockFetcher.bindPinner(rootCID: cid, peer: peer)
        await blockFetcher.bindBlockRoots(block, peer: peer)

        await recordPeerTip(chainPath: network.chainPath, peerKey: peer.publicKey, tipCID: cid, height: block.height)

        if await checkSyncNeeded(
            peerBlock: block,
            peerTipCID: cid,
            network: network,
            sourcePeer: peer
        ) {
            await bufferGossipBlock(cid: cid, data: data, network: network, peer: peer)
            tally.recordSuccess(peer: peer)
            return
        }

        let header = VolumeImpl<Block>(rawCID: cid)
        let outcome = await processBlockAndRecoverReorg(
            header: header, directory: directory, fetcher: blockFetcher,
            resolvedBlock: block,
            requireDurableResolvedBlock: true
        )
        switch outcome {
        case .accepted:
            tally.recordSuccess(peer: peer)
            // Compact relay: the Block struct (block.toData()) is already our compact
            // block equivalent — it contains only header fields and CID references to
            // the bulky sub-volumes (transaction trie, state trie). Recipients can
            // verify PoW from these bytes alone without fetching the full volume.
            // ~300-500 bytes per relay, analogous to Bitcoin's cmpctblock.
            await publishAcceptedBlock(block: block, cid: cid, data: data, network: network)
        case .duplicate:
            tally.recordSuccess(peer: peer)
        case .rejected:
            // Do not penalize for soft rejections. The block passed all pre-validation
            // checks (PoW, timestamp, size) so the peer is not misbehaving — the
            // rejection is due to fork divergence or missing state, not fraud.
            // Penalizing here causes legitimate bootstrap peers on minority forks
            // to be demoted from the anchor list, severing the connection that
            // would allow them to eventually sync and converge.
            break
        case .storageFailed:
            NodeLogger("blocks").error("\(directory): accepted block \(String(cid.prefix(16)))… was not durably stored; withholding tip publish")
        }
        if outcome != .storageFailed {
            await maybePersist(directory: directory)
        }
    }
    nonisolated public func chainNetwork(
        _ network: ChainNetwork,
        didReceiveBlockAnnouncement cid: String,
        height: UInt64,
        from peer: PeerID
    ) async {
        if await isPeerBlockRateLimited(peer) { return }

        let directory = network.directory
        let tally = await network.ivy.tally

        if let chainState = await chain(for: directory),
           let acceptedBlock = await chainState.getConsensusBlock(hash: cid) {
            await recordPeerTip(chainPath: network.chainPath, peerKey: peer.publicKey, tipCID: cid, height: acceptedBlock.blockHeight)
            let localHeight = await chainState.getHighestBlockHeight()
            if localHeight > height {
                let localTip = await chainState.getMainChainTip()
                let specCID = genesisResult.block.spec.rawCID
                await network.sendChainAnnounce(to: peer, tipCID: localTip, tipHeight: localHeight, specCID: specCID)
            }
            tally.recordSuccess(peer: peer)
            return
        }

        let now = ContinuousClock.Instant.now
        if let lastSeen = await recentBlockAnnounceTime(for: cid) {
            if now - lastSeen < (await blockDeduplicationWindow) {
                // Dedup repeated ANNOUNCEMENTS only. This uses a dedicated
                // announce map, NOT recentPeerBlocks: priming the validated-bytes
                // dedup map from a bare (unvalidated) announcement would let a
                // peer suppress the genuine full block arriving within the window.
                return
            }
        }
        await recordBlockAnnounceTime(key: cid, time: now)

        // Gossip is never blocked during sync — Ethereum's fetcher/downloader
        // run concurrently and new blocks are always processed. The sync will
        // apply the canonical chain once complete; gossip blocks in the meantime
        // are either on the same chain (accepted) or orphaned (discarded).

        if height > 0, let chainState = await chain(for: directory) {
            let localHeight = await chainState.getHighestBlockHeight()
            if height < localHeight {
                let localTip = await chainState.getMainChainTip()
                let specCID = genesisResult.block.spec.rawCID
                await network.sendChainAnnounce(to: peer, tipCID: localTip, tipHeight: localHeight, specCID: specCID)
                tally.recordSuccess(peer: peer)
                return
            }
            let gap = height > localHeight ? height - localHeight : 0
            // Exact ties hold the incumbent (docs/protocol.md §fork-choice): a
            // strictly higher peer tip triggers a sync; equal-height siblings do
            // not. The tie is broken by whichever fork is extended next.
            if gap > 0,
               await checkSyncNeeded(
                   peerBlock: nil,
                   peerTipCID: cid,
                   peerHeight: height,
                   network: network,
                   sourcePeer: peer,
                   announceOnly: true
               ) {
                tally.recordSuccess(peer: peer)
                return
            }
        }

        if await inFlightBlockCIDs.count >= maxConcurrentGossipValidations { return }

        let resolveFetcher = network.ivyFetcher

        // The peer who announced this block is a guaranteed source for its
        // entire tree. Skip DHT discovery — bind them directly so fetch()
        // can hop straight to them for any sub-CID we don't have locally.
        await resolveFetcher.bindPinner(rootCID: cid, peer: peer)

        let header = VolumeImpl<Block>(rawCID: cid)

        // Resolve the full block before processing — don't update chain tip
        // unless the block data is locally available for the miner to read.
        guard let block = try? await header.resolve(fetcher: resolveFetcher).node else {
            // Block data unavailable (data channel not ready yet). Use the
            // announced height and announcer directly to trigger headers-first
            // sync immediately rather than waiting for submitMinedBlock to
            // timeout. The announcer is a known source for the tip even when the
            // generic CAS fetch failed; passing it into sync lets HeaderChain
            // use the direct getHeaders path instead of provider lookup.
            if height > 0, network.chainPath.count == 1 {
                let chainState = await chain(for: directory)
                let localHeight = await chainState?.getHighestBlockHeight() ?? 0
                if height > localHeight {
                    _ = await checkSyncNeeded(
                        peerBlock: nil,
                        peerTipCID: cid,
                        peerHeight: height,
                        network: network,
                        sourcePeer: peer,
                        announceOnly: true
                    )
                }
            }
            return
        }
        guard block.spec.rawCID == genesisResult.block.spec.rawCID else {
            return
        }

        // Now that we have the block's boundary CIDs, bind the same peer as
        // a known source for each sub-Volume root. validateNexus and friends
        // will walk these trees via IvyFetcher; binding the peer up front
        // avoids the 15s DHT-walk timeout when the peer hasn't yet reached
        // the DHT as a discoverable pinner for every inner CID.
        await resolveFetcher.bindBlockRoots(block, peer: peer)

        if !isBlockTimestampValid(block) {
            tally.recordFailure(peer: peer)
            return
        }

        // PoW short-circuit *before* checkSyncNeeded / processBlockAndRecoverReorg.
        // `resolve` already paid a CAS hit, but this still avoids the full-subtree
        // resolve + state-apply cost that follows for forged announcements.
        // Gap-4: disconnect immediately on PoW violation.
        if !isBlockPoWValid(block) {
            // Hard violation: a block that doesn't meet its claimed target is
            // unforgeable fraud. Repeats escalate to a durable ban (M2); a single
            // offense keeps the immediate disconnect (Gap-4). recordHardFault
            // already disconnects via the ban path when it fires, so only
            // disconnect here if it did not.
            tally.recordFailure(peer: peer)
            if !(await recordHardFault(peer: peer, network: network)) {
                await network.ivy.disconnect(peer)
            }
            return
        }

        if await shouldDropNonAdvancingGossipBlock(block, cid: cid, network: network) {
            tally.recordSuccess(peer: peer)
            return
        }

        // Track best known tip per peer so sync retries can pick the best
        // currently-connected peer instead of one that has disconnected.
        await recordPeerTip(chainPath: network.chainPath, peerKey: peer.publicKey, tipCID: cid, height: block.height)

        if await checkSyncNeeded(
            peerBlock: block,
            peerTipCID: cid,
            network: network,
            sourcePeer: peer
        ) {
            tally.recordSuccess(peer: peer)
            return
        }

        let outcome = await processBlockAndRecoverReorg(
            header: header, directory: directory, fetcher: resolveFetcher,
            resolvedBlock: block,
            requireDurableResolvedBlock: true
        )
        switch outcome {
        case .accepted:
            tally.recordSuccess(peer: peer)
            // Relay full block data to peers that only heard the announcement
            // (not the inline data). Without this, those peers must DHT-fetch
            // the block rather than receiving it via direct relay.
            // W4 bug fix: this path previously never broadcastChainAnnounce'd a
            // promoted tip (the full-data gossip path always did) — peers that
            // hadn't seen the announcement waited for the periodic heartbeat.
            // publishAcceptedBlock now applies the same promoted-tip announce.
            let blockData = try? await resolveFetcher.fetch(rawCid: cid)
            await publishAcceptedBlock(block: block, cid: cid, data: blockData, network: network)
            await maybePersist(directory: directory)
        case .duplicate:
            tally.recordSuccess(peer: peer)
        case .rejected:
            break
        case .storageFailed:
            NodeLogger("blocks").error("\(directory): announced block \(String(cid.prefix(16)))… was accepted but not durably stored; withholding relay")
        }
    }
    nonisolated public func chainNetwork(_ network: ChainNetwork, didConnectPeer peer: PeerID) async {
        // Fail closed at the peer-admission boundary: a peer with a live ban
        // (durable across restarts) is dropped immediately and gets no service.
        if await banStore.isBanned(peer) {
            await network.ivy.disconnect(peer)
            return
        }
        let directory = network.directory
        guard let chainState = await chain(for: directory) else { return }
        let tipCID = await chainState.getMainChainTip()
        let tipHeight = await chainState.getHighestBlockHeight()
        let specCID = genesisResult.block.spec.rawCID
        await network.sendChainAnnounce(to: peer, tipCID: tipCID, tipHeight: tipHeight, specCID: specCID)
        // Clear stale sync failures when a new peer connects — tips that failed
        // with no peers may now be fetchable.
        Task { await self.clearStaleSyncFailures() }
    }
    /// Verify whatever spawn-cert chain `peer` has presented so far against our tree
    /// root, binding the leaf to its authenticated identity, and record/clear the
    /// proven scope. Idempotent and fail-closed; safe to call from both identify and
    /// the chain-arrival callback. Takes an `Ivy` so it classifies a peer on ANY
    /// authenticated link — a chain network OR the parent-subscription link (/// 2b/2c converges the parent link into the normal trust machinery).
    func classifySpawnTrust(ivy: Ivy, peer: PeerID) async {
        guard await spawnTrust.hasTrustedRoot else { return }
        let presented = await ivy.spawnCertChain(for: peer)
        await spawnTrust.classify(presentedChain: presented, peer: peer)
    }

    nonisolated public func chainNetwork(_ network: ChainNetwork, didReceiveSpawnCertChain peer: PeerID) async {
        await classifySpawnTrust(ivy: network.ivy, peer: peer)
    }

    nonisolated public func chainNetwork(_ network: ChainNetwork, handleConsensusRequest payload: Data, from peer: PeerID) async -> Data? {
        await consensusProvider?.handleRequest(payload, from: peer)
    }

    // MARK: - Parent-subscription link as a trusted consensus channel (2c)

    /// Register the parent-subscription Ivy so the node can send cw-requests to the
    /// parent and classify it as a trusted peer (it is not a ChainNetwork).
    func registerParentConsensusLink(directory: String, ivy: Ivy) {
        parentConsensusLinks[directory] = (ivy: ivy, peer: nil)
    }

    /// The parent identified on the subscription link: record its authenticated
    /// PeerID (so the consumer knows whom to query) and classify spawn-tree trust.
    func parentLinkDidIdentify(directory: String, ivy: Ivy, peer: PeerID) async {
        if parentConsensusLinks[directory] != nil { parentConsensusLinks[directory]!.peer = peer }
        await classifySpawnTrust(ivy: ivy, peer: peer)
    }

    /// The parent presented its spawn-cert chain on the subscription link (a frame
    /// after identify); re-classify now that the chain is present.
    func parentLinkDidReceiveSpawnCertChain(directory: String, ivy: Ivy, peer: PeerID) async {
        await classifySpawnTrust(ivy: ivy, peer: peer)
    }

    /// The parent disconnected: drop its recorded trust and the cached PeerID, so
    /// trust never outlives the authenticated link (a reconnect re-classifies on
    /// the next identify). Mirrors the chain-network `didDisconnectPeer` path.
    func parentLinkDidDisconnect(directory: String, peer: PeerID) async {
        if parentConsensusLinks[directory]?.peer == peer { parentConsensusLinks[directory]!.peer = nil }
        await spawnTrust.forget(peer)
    }

    /// Route a cw-response that arrived on the parent-subscription link into the
    /// consensus-provider client correlation (responder-bound).
    func deliverConsensusResponse(_ payload: Data, from peer: PeerID) async {
        await consensusProvider?.handleResponse(payload, from: peer)
    }

    /// query the trusted parent (on the subscription link for
    /// `directory`) for the faithful Hierarchical-GHOST inherited weight of the child
    /// committed by `committerHashes` on the parent chain — the parent computes the
    /// union (each grinding block once) over those committers. Returns nil if the
    /// parent hasn't identified, the provider is not up, or the query times out / is
    /// refused. A single-element set is the common case (`trueCumWork(committer)`).
    func queryParentWeight(directory: String, parentChainPath: [String], committerHashes: [String]) async -> UInt256? {
        guard let peer = parentConsensusLinks[directory]?.peer,
              let provider = consensusProvider else { return nil }
        return await provider.requestWeight(from: peer, chainPath: parentChainPath, committerHashes: committerHashes)
    }

    nonisolated public func chainNetwork(_ network: ChainNetwork, handleConsensusResponse payload: Data, from peer: PeerID) async {
        await consensusProvider?.handleResponse(payload, from: peer)
    }

    nonisolated public func chainNetwork(_ network: ChainNetwork, didIdentifyPeer peer: PeerID) async {
        // classify from any chain presented so far; the chain may
        // arrive in a later frame, which re-runs this via didReceiveSpawnCertChain.
        await classifySpawnTrust(ivy: network.ivy, peer: peer)
        // enforce the durable ban against a peer's REAL identity. Inbound
        // peers reach `didConnectPeer` only under a temporary `inbound-<uuid>` id,
        // so a banned peer reconnecting inbound was never disconnected there; this
        // fires after identify re-keys to the canonical id. Idempotent by
        // construction: re-check the ban and re-disconnect — Ivy may re-fire this
        // per identify frame, but a repeated check + disconnect accumulates nothing.
        guard await banStore.isBanned(peer) else { return }
        await network.ivy.disconnect(peer)
        // Mirror didDisconnectPeer: drop the node's per-peer maps for this identity.
        await didDisconnectPeer(publicKey: peer.publicKey)
    }
    nonisolated public func chainNetwork(_ network: ChainNetwork, banPeer peer: PeerID) async {
        // Persist the ban (survives restart) and drop the connection now.
        // Fail closed: if the durable write fails the ban would not survive a
        // restart, so we mark the chain unhealthy (which stops its network) rather
        // than continuing to serve with a non-durable ban. The in-memory ban is
        // still applied for the brief remaining session, and the peer is dropped.
        do {
            try await banStore.ban(peer)
            await network.ivy.disconnect(peer)
        } catch {
            await network.ivy.disconnect(peer)
            await markChainUnhealthy(
                directory: network.directory,
                reason: "durable peer-ban write failed (\(error)); ban would not survive restart"
            )
        }
    }
    /// Get-or-create this chain's inherited-weight accumulator. The init (create
    /// store + install its provider on the ChainState) runs inside a memoized
    /// `Task` so it completes exactly once before any caller observes the store —
    /// no reentrancy window where a second ingest could record + reevaluate against
    /// a providerless ChainState. The `Task` is registered synchronously (no `await`
    /// between the lookup and the insert), so the actor serializes the check-insert.
    func ensureInheritedWeightStore(directory: String) async -> InheritedWeightStore {
        let key = chainKey(forDirectory: directory)
        if let pending = inheritedWeightStoreInit[key] { return await pending.value }
        let task = Task { () -> InheritedWeightStore in
            let store = InheritedWeightStore()
            let index = await self.ensureLiveInheritedWeightIndex(directory: directory)
            // Wire the durable, only-grows floor into the live fork-choice index
            // here — the single path EVERY store creator funnels through (restore,
            // reorg, parent extraction) — so ChainState's provider reads restored
            // inherited work even when no live parent projection exists yet (e.g.
            // right after restart, before a parent block re-arrives). The store is
            // empty now, but makeProvider() is a live closure over it, so later
            // recordVerifiedWorkContributions are reflected. Idempotent.
            index.setDurableFloor(store.makeProvider())
            return store
        }
        inheritedWeightStoreInit[key] = task
        return await task.value
    }
    func ensureLiveInheritedWeightIndex(directory: String) async -> LiveInheritedWeightIndex {
        let key = chainKey(forDirectory: directory)
        if let pending = liveInheritedWeightIndexInit[key] { return await pending.value }
        let task = Task { () -> LiveInheritedWeightIndex in
            let index = LiveInheritedWeightIndex()
            if let chain = await self.chain(for: directory) {
                await chain.setInheritedWeightProvider(index.makeProvider())
            }
            return index
        }
        liveInheritedWeightIndexInit[key] = task
        return await task.value
    }
    func restoreInheritedWeight(directory: String) async {
        guard let stateStore = stateStores[chainKey(forDirectory: directory)] else { return }
        let proofs = stateStore.getAllBlockProofs()
        let anchors = stateStore.getAllChildParentAnchors()
        let storedContributions = stateStore.getAllInheritedWorkContributions()
        guard !proofs.isEmpty || !anchors.isEmpty || !storedContributions.isEmpty else { return }
        let liveIndex = await ensureLiveInheritedWeightIndex(directory: directory)
        for anchor in anchors {
            _ = liveIndex.recordParentAnchor(childHash: anchor.childHash, parentHash: anchor.parentHash)
        }
        let inheritedStore = await ensureInheritedWeightStore(directory: directory)
        var restored = 0
        // Proofs are the SOURCE OF TRUTH for inherited weight — re-derive from them first
        // (per-grind max crediting) and remember which children we covered.
        var rebuiltFromProof = Set<String>()
        for entry in proofs {
            guard let proof = ChildBlockProof.deserialize(entry.proof) else { continue }
            if let anchor = await proof.committingParentAnchor() {
                _ = liveIndex.recordParentAnchor(childHash: entry.blockHash, parentHash: anchor.blockHash)
            }
            let contributions = await proof.securingWorkContributions()
            guard !contributions.isEmpty else { continue }
            rebuiltFromProof.insert(entry.blockHash)
            if inheritedStore.recordVerifiedWorkContributions(contributions, committingChild: entry.blockHash) {
                restored += 1
            }
        }
        // Persisted per-level contribution rows are a DERIVED cache that predates the
        // per-grind crediting rule (Lattice `securingWorkContributions`). Replaying them for
        // a child we can rebuild from its proof would re-inflate depth>=2 inherited weight
        // and diverge from a freshly-synced node — so use them ONLY as a fallback for a
        // child that has no persisted proof.
        if !storedContributions.isEmpty {
            let grouped = Dictionary(grouping: storedContributions, by: \.blockHash)
            for (blockHash, rows) in grouped where !rebuiltFromProof.contains(blockHash) {
                let contributions = rows.map { (id: $0.contributorID, work: $0.work) }
                if inheritedStore.recordVerifiedWorkContributions(contributions, committingChild: blockHash) {
                    restored += 1
                }
            }
        }
        if restored > 0 {
            NodeLogger("recovery").info("\(directory): restored inherited weight from \(restored) source(s) (proofs preferred)")
        }
    }
    /// Build a ContentSource that pre-caches mempool transaction data for
    /// in-memory resolution: the admitted-tx overlay (mempool `fetcherCache()`)
    /// consulted first, then `baseSource`. Empty mempool returns `baseSource`
    /// unchanged.
    func buildMempoolAwareSource(directory: String, baseSource: any ContentSource) async -> any ContentSource {
        guard let network = network(for: directory) else { return baseSource }
        let txDataCache = await network.nodeMempool.fetcherCache()
        return txDataCache.isEmpty ? baseSource : OverlayContentSource(entries: txDataCache, fallback: baseSource)
    }

    /// Build the mempool-aware ContentSource from a bare base FETCHER, choosing the
    /// byte-identical native base: `IvyContentSource` when the base IS this chain's
    /// network ivy (the wave-batching win), otherwise the exact `FetcherContentSource`
    /// bridge (sequential per-CID, semantics-exact). Same precedence as the overlay
    /// builder above (mempool overlay → base).
    func buildMempoolAwareSource(directory: String, baseFetcher: Fetcher) async -> any ContentSource {
        let baseSource: any ContentSource
        if let ivy = baseFetcher as? IvyFetcher, let net = network(for: directory), ivy === net.ivyFetcher {
            baseSource = IvyContentSource(ivy)
        } else {
            baseSource = FetcherContentSource(baseFetcher)
        }
        return await buildMempoolAwareSource(directory: directory, baseSource: baseSource)
    }

    func materializeParentHomesteadForCandidate(directory: String, parentBlock: Block) async -> Block {
        // prevState is a Reference, resolved on demand — there is nothing to bake
        // into the block (and the only consumer, parentCompatibleCandidateBase,
        // reads prevState.rawCID, always available). Pre-warm the parent-state
        // fetcher's local store by resolving the homestead so later candidate
        // assembly can fetch it without a network round trip.
        guard let parentStateFetcher = parentStateFetchers[directory] else {
            NodeLogger("candidate").warn("\(directory): parent homestead \(String(parentBlock.prevState.rawCID.prefix(16)))… not pre-warmed: parent fetcher unavailable")
            return parentBlock
        }
        if (try? await parentBlock.prevState.resolve(fetcher: parentStateFetcher)) == nil {
            NodeLogger("candidate").warn("\(directory): parent homestead \(String(parentBlock.prevState.rawCID.prefix(16)))… not pre-warmed: fetch failed")
        }
        return parentBlock
    }

    /// Resolve a block's transaction dictionary into keyed entries.
    // nonisolated: only uses parameters, no actor state — allows concurrent calls from task groups.
    nonisolated func resolveBlockTransactions(block: Block, source: any ContentSource) async -> [String: VolumeImpl<Transaction>] {
        if let txDict = try? await block.transactions.resolveRecursive(source: source).node,
           let entries = try? txDict.allKeysAndValues() {
            return entries
        }
        return [:]
    }
    /// Apply a genesis block's state changes (balances, receipts, etc.) to the chain's StateStore.
    /// Must be called after the chain network exists and after the genesis block is stored in the CAS.
    public func applyGenesisBlock(directory: String, block: Block) async {
        guard let network = network(for: directory) else { return }
        let source = await buildMempoolAwareSource(directory: directory, baseFetcher: network.ivyFetcher)
        // known-valid local node; CID cannot fail
        let blockHash = try! VolumeImpl<Block>(node: block).rawCID
        let txEntries = await resolveBlockTransactions(block: block, source: source)
        _ = await applyAcceptedBlock(
            block: block, blockHash: blockHash,
            txEntries: txEntries, directory: directory
        )
    }
    /// Register and activate a new child chain with its genesis block.
    /// Orders the steps so the lattice subscription isn't created until the
    /// network is live (avoiding orphan entries on failure), seeds the tip
    /// cache with the genesis hash so the miner's lock-free tip check works,
    /// and persists chain state so the chain survives a restart before any
    /// blocks are mined.
    ///
    /// `parentDirectory` identifies the chain that will anchor the new chain
    /// via merged mining. When `nil`, defaults to the nexus so existing callers
    /// continue to work. For grandchildren (and deeper), pass the intermediate
    /// chain's directory.
    public func deployChildChain(
        directory: String,
        parentDirectory: String? = nil,
        parentChainPath: [String]? = nil,
        genesisBlock: Block,
        bootstrapEntries: [(String, Data)] = [],
        genesisHex: String = ""
    ) async throws {
        let nexusDir = genesisConfig.directory
        let parentDir = parentDirectory ?? nexusDir
        let resolvedParentPath: [String]
        if let parentChainPath {
            resolvedParentPath = parentChainPath
        } else if let parentHit = await lattice.nexus.findLevel(directory: parentDir, chainPath: [nexusDir]) {
            resolvedParentPath = parentHit.chainPath
        } else {
            let matches = deployedChildChains.values.filter { $0.directory == parentDir }
            guard matches.count == 1 else {
                throw NodeError.parentChainNotFound(parentDir)
            }
            resolvedParentPath = matches[0].chainPath
        }
        let childPath = resolvedParentPath + [directory]
        guard let spec = Self.subscriptionSpec(genesisBlock: genesisBlock, bootstrapEntries: bootstrapEntries) else {
            throw NodeError.chainSpecUnavailableForSubscription(directory)
        }
        try Self.validateSubscriptionFrameBudget(
            chainPath: childPath,
            spec: spec,
            maxFrameSize: config.maxFrameSize
        )
        let storageNetwork = nearestLocalNetwork(forPath: resolvedParentPath) ?? primaryNetwork
        guard let parentNetwork = storageNetwork else {
            throw NodeError.chainNetworkNotRegistered(parentDir)
        }
        if !bootstrapEntries.isEmpty {
            // Verify-before-pin: a pinned root is servable via the volumeData
            // directly-pinned fallback, so every entry must hash to its CID
            // before it becomes durable+pinned. This is the one durable-pin site
            // fed by externally-supplied (subscribe RPC) bytes rather than a
            // structural storeRecursively of a validated object — fail closed.
            for (cid, data) in bootstrapEntries where !ContentAddressVerifier.data(data, matches: cid) {
                throw NodeError.invalidGenesisBootstrapEntry(cid)
            }
            let payloads = bootstrapEntries.map { SerializedVolume(root: $0.0, entries: [$0.0: $0.1]) }
            try await parentNetwork.storeVolumesDurably(payloads)
            let bootstrapRoots = bootstrapEntries.map(\.0)
            try await parentNetwork.pinBatchDurably(
                roots: bootstrapRoots,
                owner: "\(parentNetwork.ownerNamespace):\(directory):genesis-bootstrap"
            )
        }
        guard let storedRoots = await storeBlockData(genesisBlock, network: parentNetwork) else {
            throw NodeError.chainNetworkNotRegistered(parentDir)
        }
        try await parentNetwork.pinBatchDurably(
            roots: storedRoots,
            owner: "\(parentNetwork.ownerNamespace):\(directory):genesis"
        )
        await announceStoredRoots(storedRoots, network: parentNetwork)
        await pinSpec(block: genesisBlock, chainPath: childPath, network: parentNetwork)

        // The parent advertises genesis availability, but it does not create a
        // local ChainState or fork-choice view for the child. Child nodes own
        // validation and sync for their chain.
        let genesisCID = try VolumeImpl<Block>(node: genesisBlock).rawCID
        let genesisOwner = "\(parentNetwork.ownerNamespace):\(directory):genesis-block"
        if let genesisData = genesisBlock.toData() {
            let payload = SerializedVolume(root: genesisCID, entries: [genesisCID: genesisData])
            try? await parentNetwork.storeVolumeDurably(payload)
            try? await parentNetwork.pinDurably(root: genesisCID, owner: genesisOwner)
        }
        await parentNetwork.ivy.announceBlock(cid: genesisCID)
        await recordDeployedChildChain(DeployedChainMetadata(
            chainPath: childPath,
            directory: directory,
            parentDirectory: parentDir,
            genesisHash: genesisCID,
            genesisHex: genesisHex,
            timestamp: genesisBlock.timestamp
        ))
    }

    func nearestLocalNetwork(forPath chainPath: [String]) -> ChainNetwork? {
        var path = chainPath
        while !path.isEmpty {
            if let network = network(forPath: path) {
                return network
            }
            path.removeLast()
        }
        return nil
    }
    static func subscriptionSpec(
        genesisBlock: Block,
        bootstrapEntries: [(String, Data)]
    ) -> ChainSpec? {
        if let spec = genesisBlock.spec.node {
            return spec
        }
        guard let entry = bootstrapEntries.first(where: { $0.0 == genesisBlock.spec.rawCID }) else {
            return nil
        }
        return ChainSpec(data: entry.1)
    }
    func pinSpec(block: Block, chainPath: [String], network: ChainNetwork) async {
        guard let specData = block.spec.node?.toData() else { return }
        let specCID = block.spec.rawCID
        let payload = SerializedVolume(root: specCID, entries: [specCID: specData])
        try? await network.storeVolumeDurably(payload)
        try? await network.pinDurably(root: specCID, owner: "\(network.ownerNamespace):spec")
        let fee = await network.ivy.config.relayFee * 2
        let expiry = UInt64(Date().timeIntervalSince1970) + config.pinAnnounceExpiry * 365
        await network.announce(cid: specCID, expiry: expiry, fee: fee)
    }
    func clearStaleSyncFailures() {
        syncOutcomes.clearFailed()
    }
    func bufferGossipBlock(cid: String, data: Data, network: ChainNetwork, peer: PeerID) {
        let key = ObjectIdentifier(network)
        let limit = config.pendingGossipBlockLimit
        if (pendingGossipBlocks[key]?.count ?? 0) < limit {
            pendingGossipBlocks[key, default: []].append(PendingGossipBlock(cid: cid, data: data, network: network, peer: peer))
        }
    }
    func handleChildChainDiscovery(directory: String) async {
        // SEC-501: validate the peer-supplied directory before any filesystem use.
        // Without this, a malicious peer embedding a child genesis block with
        // directory="../nexus" would traverse into the nexus state directory.
        // Apply the same allowlist as deployChain RPC (RPCServer.swift:551-554).
        let allowedChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        guard !directory.isEmpty,
              directory.count <= 64,
              !directory.hasPrefix("."),
              !directory.unicodeScalars.contains(where: { !allowedChars.contains($0) }) else {
            NodeLogger("discovery").warn("Rejected invalid chain directory from gossip: '\(directory)'")
            return
        }
        NodeLogger("discovery").debug("Ignoring discovered child chain '\(directory)' on parent node; child views are owned by child processes")
    }
}

extension IvyFetcher {
    /// Bind `peer` as a known source for every Volume-boundary CID referenced
    /// by `block`. A peer that just announced this block is by transitive
    /// pinning guaranteed to hold every subtree it points at — routing
    /// subsequent resolves directly to them avoids a DHT discovery round
    /// (and the 15s untargeted-walk timeout that follows when the pinner
    /// announcement hasn't yet reached us).
    /// P-1003: one Ivy actor hop instead of 7 sequential bindPinner calls.
    func bindBlockRoots(_ block: Block, peer: PeerID) async {
        var cids: [String] = [
            block.spec.rawCID,
            block.transactions.rawCID,
            block.postState.rawCID,
            block.prevState.rawCID,
            block.parentState.rawCID,
            block.children.rawCID,
        ]
        if let prev = block.parent?.rawCID { cids.append(prev) }
        await bindPinners(rootCIDs: cids, peer: peer)
    }
}
