import Lattice
import Foundation
import Ivy
import VolumeBroker
import cashew
import UInt256

// Held-heavier convergence rescue for LatticeNode.
//
// Fork choice (Hierarchical GHOST over trueCumWork) can only adopt a heavier
// branch whose bodies are contiguously present. Two shapes leave a strictly
// heavier subtree HELD with missing interior bodies:
//
//  1. Index-known hold (CFC-A1): the weight index retains the branch's
//     linkage/weight but interior bodies were pruned / never fetched. Lattice
//     ships the complete detector + transport for this shape
//     (`ChainState.heldHeavierBackfillTarget()` →
//     `ChainLevel.backfillHeldHeavierSubtree`) and `Lattice.processBlockHeader`
//     drives it at the non-extending submission choke point — but only when the
//     node installs a `backfillSyncerProvider`. `installHeldHeavierBackfill`
//     below is that wiring.
//
//  2. Detached hold (gossip shape): a proof-verified child block arrives whose
//     parent linkage the chain does not know (the chain records the parent in
//     `missingBlockHashes`), while the connector itself was pushed below the
//     local tip height and dropped by the gossip height-monotonicity guard.
//     Lattice's detector cannot see this branch (no linkage from genesis), so
//     the node keeps the verified evidence (bytes + committing parent anchor +
//     work proofs — all fully verified at arrival) in a bounded cache and
//     replays a connector ONLY once the chain itself declares its CID a missing
//     ancestor. This is pull-shaped admission (the chain asked for exactly this
//     CID), not a relaxation of the push guard: arbitrary below-tip blocks are
//     still dropped, and adoption stays exclusively with fork choice.
extension LatticeNode {

    // MARK: - Detached connector evidence

    /// One verified work proof for a cached connector, with the committing
    /// parent anchor and the anchored PoW root hash it was verified against.
    struct VerifiedChildProofEvidence: Sendable {
        let proof: ChildBlockProof
        let anchor: ParentAnchor
        let rootHash: UInt256
    }

    /// Everything needed to replay a proof-verified child block through the
    /// SAME proven-child ingestion gossip uses, once the chain wants it.
    struct DetachedChildEvidence: Sendable {
        let blockData: Data
        let selectedAnchor: ParentAnchor
        let processingRootHash: UInt256
        let verified: [VerifiedChildProofEvidence]
    }

    static let maxDetachedEvidencePerChain = 64
    static let maxRescuePassesPerDrain = 16

    /// Per-connector body-size cap for the speculative detached-evidence cache.
    /// A valid block may be as large as the chain's `maxBlockSize` (up to the
    /// Ivy frame cap, ~megabytes), so 64 valid-but-below-tip proven connectors
    /// could otherwise pin 64 × maxBlockSize of memory per followed chain. We
    /// only DECLINE TO CACHE bodies above this cap: an oversized detached
    /// connector can still be re-gossiped, or — once its linkage is known —
    /// rescued through the index-known held-heavier backfill transport, which
    /// fetches bodies on demand rather than holding them. 256 KiB comfortably
    /// covers realistic child connectors while bounding the cache to
    /// 64 × 256 KiB = 16 MiB per chain.
    static let maxDetachedEvidenceBytes = 256 * 1024

    /// Cache a proof-verified child block that could not enter the chain (below
    /// the tip height, or otherwise not promoted) so the connector rescue can
    /// replay it when the chain declares its CID missing. Bounded FIFO per chain.
    func cacheDetachedChildEvidence(
        directory: String,
        chainPath: [String]?,
        cid: String,
        blockData: Data,
        selectedAnchor: ParentAnchor,
        processingRootHash: UInt256,
        verified: [VerifiedChildProofEvidence]
    ) {
        // Decline to speculatively cache oversized bodies (memory-pin hardening):
        // they can still be re-gossiped or backfilled on demand once linkage is
        // known. Fork choice and the push guard are unaffected — this only bounds
        // what the detached-evidence FIFO is willing to hold.
        guard blockData.count <= Self.maxDetachedEvidenceBytes else { return }
        let key = chainPath.map { chainKey(forPath: $0) } ?? chainKey(forDirectory: directory)
        if detachedChildEvidence[key]?[cid] == nil {
            detachedChildEvidenceOrder[key, default: []].append(cid)
        }
        detachedChildEvidence[key, default: [:]][cid] = DetachedChildEvidence(
            blockData: blockData,
            selectedAnchor: selectedAnchor,
            processingRootHash: processingRootHash,
            verified: verified
        )
        while (detachedChildEvidenceOrder[key]?.count ?? 0) > Self.maxDetachedEvidencePerChain {
            let evicted = detachedChildEvidenceOrder[key]!.removeFirst()
            detachedChildEvidence[key]?.removeValue(forKey: evicted)
        }
    }

    private func removeDetachedChildEvidence(key: String, cid: String) {
        detachedChildEvidence[key]?.removeValue(forKey: cid)
        detachedChildEvidenceOrder[key]?.removeAll { $0 == cid }
    }

    // MARK: - Connector rescue (single-flight per chain, memoized failures)

    /// Schedule a rescue drain for `directory`'s chain. Single-flight per chain
    /// (same pattern as `syncTasks`); a no-op when the chain reports no missing
    /// ancestors or no cached evidence matches them.
    func scheduleChildConnectorRescue(directory: String, chainPath: [String]?) {
        let key = chainPath.map { chainKey(forPath: $0) } ?? chainKey(forDirectory: directory)
        guard childRescueTasks[key] == nil else { return }
        childRescueTasks[key] = Task { [weak self] in
            await self?.runChildConnectorRescue(directory: directory, chainPath: chainPath)
            await self?.clearChildRescueTask(key: key)
        }
    }

    private func clearChildRescueTask(key: String) {
        childRescueTasks[key] = nil
    }

    private func runChildConnectorRescue(directory: String, chainPath: [String]?) async {
        let key = chainPath.map { chainKey(forPath: $0) } ?? chainKey(forDirectory: directory)
        let chainMaybe: ChainState?
        if let chainPath {
            chainMaybe = await chain(forPath: chainPath)
        } else {
            chainMaybe = await chain(for: directory)
        }
        guard let chain = chainMaybe,
              let network = chainPath.flatMap({ network(forPath: $0) }) ?? network(for: directory) else { return }

        // Drain: replay cached connectors the chain has declared missing. Each
        // successful replay can surface the NEXT missing ancestor (a deeper
        // fork connects one hop per pass), so loop until a pass makes no
        // progress. Bounded: every pass either consumes a cached entry or
        // memoizes a failed one, and the pass count is capped outright.
        var passes = 0
        while passes < Self.maxRescuePassesPerDrain {
            passes += 1
            let missing = await chain.getMissingBlockHashes()
            guard !missing.isEmpty else { return }
            let localTip = await chain.getMainChainTip()
            var progressed = false
            for cid in missing.sorted() {
                guard !refusedRescueConnectors.contains("\(cid)|\(localTip)") else { continue }
                guard let evidence = detachedChildEvidence[key]?[cid] else { continue }
                guard let block = Block(data: evidence.blockData),
                      ChainNetwork.blockCIDMatches(cid, block: block) else {
                    removeDetachedChildEvidence(key: key, cid: cid)
                    continue
                }
                let outcome = await submitRescuedChildConnector(
                    block: block,
                    cid: cid,
                    evidence: evidence,
                    network: network,
                    directory: directory,
                    chainPath: chainPath
                )
                switch outcome {
                case .accepted, .duplicate:
                    // In the chain now (promoted, side, or detached-awaiting its
                    // own parent — the next pass sees the deeper missing hash).
                    removeDetachedChildEvidence(key: key, cid: cid)
                    progressed = true
                case .rejected, .storageFailed:
                    // Memoize against the CURRENT tip so an unserved/invalid
                    // heavier claim can't spin the node; a tip change re-arms.
                    memoizeRefusedRescueConnector(cid, localTip: localTip)
                }
            }
            if !progressed { return }
        }
    }

    func memoizeRefusedRescueConnector(_ cid: String, localTip: String) {
        if refusedRescueConnectors.count > 512 { refusedRescueConnectors.removeAll() }
        refusedRescueConnectors.insert("\(cid)|\(localTip)")
    }

    /// Replay one cached connector through the SAME proven-child ingestion path
    /// gossip uses (full anchor/proof/PoW/state validation + durable-store-then-
    /// commit), bypassing ONLY the push height-monotonicity guard — the chain
    /// itself declared this CID a missing ancestor. Fork choice remains the sole
    /// switch authority: this supplies a body, nothing else.
    private func submitRescuedChildConnector(
        block: Block,
        cid: String,
        evidence: DetachedChildEvidence,
        network: ChainNetwork,
        directory: String,
        chainPath: [String]?
    ) async -> BlockProcessOutcome {
        for item in evidence.verified {
            await preloadInheritedWeight(directory: directory, blockHash: cid, proof: item.proof)
        }
        var proofEntries: [String: Data] = [:]
        for item in evidence.verified {
            for entry in item.proof.entries where proofEntries[entry.cid] == nil {
                proofEntries[entry.cid] = entry.data
            }
        }
        let validationBaseSource = OverlayContentSource(
            entries: proofEntries,
            fallback: IvyContentSource(network.ivyFetcher)
        )
        let outcome = await processBlockAndRecoverReorg(
            header: VolumeImpl<Block>(rawCID: cid),
            directory: directory,
            chainPath: chainPath,
            fetcher: CoalescingFetcher(validationBaseSource),
            resolvedBlock: block,
            rootHash: evidence.processingRootHash,
            parentAnchor: evidence.selectedAnchor,
            requireDurableResolvedBlock: true,
            baseValidationSourceOverride: validationBaseSource,
            allowBelowTipHeight: true
        )
        if outcome == .accepted || outcome == .duplicate {
            for item in evidence.verified {
                await persistAcceptedBlockProof(directory: directory, height: block.height, blockHash: cid, proof: item.proof)
            }
            for item in evidence.verified {
                guard await applyInheritedWeight(directory: directory, blockHash: cid, proof: item.proof, source: validationBaseSource) else {
                    break
                }
            }
        }
        return outcome
    }

    // MARK: - Lattice held-heavier backfill transport (index-known holds)

    /// Install the body-backfill transport on a Lattice facade so
    /// `processBlockHeader` can drive `ChainLevel.backfillHeldHeavierSubtree`
    /// at its non-extending submission choke point (the CFC-A1 hold drain).
    /// Idempotent for the node's own facade; per-view facades (latticeView)
    /// are freshly constructed and always need the install.
    func installHeldHeavierBackfill(on facade: Lattice, chainPath: [String]) async {
        if facade === lattice {
            if mainLatticeBackfillInstalled { return }
            mainLatticeBackfillInstalled = true
        }
        let path = chainPath
        let key = chainKey(forPath: chainPath)
        await facade.setBackfillSyncerProvider { [weak self] level in
            guard let self else { return nil }
            return await self.heldHeavierBackfillTransport(level: level, chainPath: path)
        }
        await facade.setBackfillFailureObserver { [weak self] error in
            NodeLogger("sync").warn("\(path.joined(separator: "/")): held-heavier body backfill failed: \(error)")
            // Fail closed but not silent (the facade already kept the incumbent);
            // memoize the failed target so an unserved heavier claim can't spin
            // the node on every subsequent non-extending submission.
            Task { [weak self] in await self?.memoizeFailedHeldHeavierBackfill(chainKey: key) }
        }
    }

    /// Provide the real sync transport for a held-heavier body backfill on
    /// `level`, or nil when there is no target, no network, or the target
    /// already failed against the current tip (memoized).
    private func heldHeavierBackfillTransport(
        level: ChainLevel,
        chainPath: [String]
    ) async -> (syncer: ChainSyncer, maxBodies: UInt64)? {
        guard let network = network(forPath: chainPath) ?? chainPath.last.flatMap({ network(for: $0) }) else {
            return nil
        }
        let chain = await level.chain
        guard let target = await chain.heldHeavierBackfillTarget() else { return nil }
        let tip = await chain.getMainChainTip()
        let key = chainKey(forPath: chainPath)
        let memoKey = "\(target.tipHash)|\(tip)"
        guard !heldHeavierBackfillMemo.contains(memoKey) else { return nil }
        heldHeavierLastIssuedTarget[key] = memoKey
        let genesisHash = await chain.getMainChainBlockHash(atIndex: 0) ?? genesisResult.blockHash
        let syncer = ChainSyncer(
            fetcher: network.ivyFetcher,
            // Persist each validated body durably so the chain can resolve it
            // after `submitBlock` adopts the branch (the backfill submits
            // through Lattice's own fork-choice path; the node's canonical
            // transition publish reconciles durable side effects afterwards).
            store: { [weak network] cid, data in
                guard let network else { return }
                do {
                    try await network.storeVolumeDurably(SerializedVolume(root: cid, entries: [cid: data]))
                } catch {
                    NodeLogger("sync").error("held-heavier backfill: failed to durably store body \(String(cid.prefix(16)))…: \(error)")
                }
            },
            genesisBlockHash: genesisHash,
            chainPath: chainPath,
            retentionDepth: config.retentionDepth,
            validateBlockConsensus: true
        )
        return (syncer: syncer, maxBodies: config.retentionDepth)
    }

    private func memoizeFailedHeldHeavierBackfill(chainKey key: String) {
        guard let memoKey = heldHeavierLastIssuedTarget.removeValue(forKey: key) else { return }
        if heldHeavierBackfillMemo.count > 512 { heldHeavierBackfillMemo.removeAll() }
        heldHeavierBackfillMemo.insert(memoKey)
    }
}
