import Lattice
import LatticeNodeWire
import Foundation
import Ivy
import VolumeBroker
import Tally
import cashew
import UInt256

// Block storage for LatticeNode.
// Behavior-preserving extraction : store/commit/finalize, pin/unpin,
// prune, validator-pin release + reconciliation, state-root extraction, announce,
// and deep copy. Pure relocation; no logic change.

extension LatticeNode {

    /// Volume boundary CIDs that must stay resolvable to answer queries at `block`.
    /// Pinned in the per-chain protection policy to survive LRU eviction.
    static func stateRoots(of block: Block) -> [String] {
        // Only the block's OWNED postState frontier. prevState/parentState are
        // References (docs/design/block-content-storage.md): "Do not pin or require
        // references … under the block's owner — they are independently retained by
        // their producers" and are resolved by CID on demand ONLY as deeply as
        // validation touches. Requiring the WHOLE parentState durable demands the
        // parent chain's full state trie a child never owns — a followed child holds
        // only sparse parent state — which fails the durability gate on every
        // gossip-accept past the initial sync and wrongly announces it as servable.
        //
        // RECOVERY INVARIANT (why dropping prevState is safe, not just spec-aligned):
        // the only paths that must RECONSTRUCT a block by re-executing from its
        // prevState — materializeSyncedCanonicalContent (the sync segment) and
        // gossip-accept — only ever target IN-WINDOW blocks. A block's prevState is the
        // immediately-prior block's OWNED postState, which is itself in-window and
        // required-durable here, and retention's structural sharing keeps the shared
        // trie nodes reachable from any in-window height. So a prevState a node may need
        // to recompute is always still durably reachable; recompute never targets a
        // block whose prevState was pruned out-of-window. (If a future fast-path ever
        // accepts a block WITHOUT the full prevState→postState recompute check, this
        // invariant must be revisited — that path would lose prevState reconstructability.)
        [
            block.postState.rawCID,
        ].filter { !$0.isEmpty }
    }
    static func blockContentRoots(of block: Block, blockHash: String) -> [String] {
        // Object-grain boundary roots only. transactions/children are in-package
        // HeaderImpls stored inside the block volume (not their own volume roots),
        // so hasVolume(blockHash) already covers them; spec is its own boundary
        // volume. Their internal CIDs are not separately required/announced.
        [
            blockHash,
            block.spec.rawCID,
        ].filter { !$0.isEmpty }
    }

    // MARK: - Recursive Block Storage
    /// Store a block + sub-volumes as canonical chain storage: persist the data
    /// locally, pin + announce it for retention/serving, persist its stored
    /// roots, and prune superseded data. Use this for blocks that are already
    /// accepted (genesis, extracted child blocks). Self-mined candidates instead
    /// go through `storeBlockData` (for validation) and only `commitBlockStorage`
    /// once accepted, so a rejected candidate is never pinned or announced.
    @discardableResult
    func storeBlockRecursively(_ block: Block, network: ChainNetwork, directory: String? = nil, stateDiff: StateDiff = .empty) async -> Bool {
        // If candidate storage fails there is nothing durable to commit — skip
        // pin/announce/persist rather than committing an empty root set.
        guard let storedRoots = await storeBlockData(block, network: network) else { return false }
        guard await commitBlockStorage(block, storedRoots: storedRoots, network: network, directory: directory, stateDiff: stateDiff) else {
            return false
        }
        // Pre-warm LAST — after all storage writes — so new DiskBroker entries
        // don't evict the pre-warmed nodes before validation runs.
        await preWarmValidationCache(block, network: network)
        return true
    }
    /// Persist a block's data + sub-volumes into `broker` so it can be resolved
    /// during validation. Does NOT pin or announce — a rejected candidate must
    /// not be retained or advertised as chain storage. Returns the stored roots so
    /// the caller can `commitBlockStorage` them if the block is accepted, or `nil`
    /// if storage failed (so the caller can abort rather than advance a block
    /// whose data was never durably stored).
    func storeBlockData(_ block: Block, broker: any VolumeBroker) async -> [String]? {
        // known-valid local node; CID cannot fail
        let header = try! VolumeImpl<Block>(node: block)
        do {
            let (volumes, roots) = try collectBlockVolumes(block, blockHash: header.rawCID, broker: broker)
            if !volumes.isEmpty {
                try await broker.storeVolumesLocal(volumes)
            }
            return roots
        } catch {
            NodeLogger("blocks").error("Failed to store block data: \(error)")
            return nil
        }
    }
    func storeBlockData(_ block: Block, network: ChainNetwork) async -> [String]? {
        let header = try! VolumeImpl<Block>(node: block)
        do {
            let (volumes, roots) = try collectBlockVolumes(block, blockHash: header.rawCID, broker: MemoryBroker())
            if !volumes.isEmpty {
                try await network.storeVolumesDurably(volumes)
            }
            return roots
        } catch {
            NodeLogger("blocks").error("Failed to store block data: \(error)")
            return nil
        }
    }

    func storeAcceptedStateDiffRoots(
        block: Block,
        stateDiff: StateDiff,
        materializedPostState: LatticeState? = nil,
        network: ChainNetwork,
        source: any ContentSource,
        directory: String
    ) async -> [String]? {
        // `CoalescingFetcher(source)` resolves byte-identically to the prior
        // `fetcher` (transparent per-wave batching). Lattice's resolve/
        // proveAndUpdateState take a `Fetcher`, so derive one from the source.
        let fetcher = CoalescingFetcher(source)
        do {
            let updatedHeader: LatticeStateHeader
            let createdRoots: Set<String>
            if let materializedPostState {
                updatedHeader = try LatticeStateHeader(node: materializedPostState)
                createdRoots = Set(stateDiff.created.keys)
            } else {
                guard !stateDiff.created.isEmpty else { return [] }
                guard let txDict = try await block.transactions.resolveRecursive(fetcher: fetcher).node,
                      let txEntries = try? txDict.allKeysAndValues() else {
                    NodeLogger("blocks").error("\(directory): failed to resolve transactions while materializing accepted state roots")
                    return nil
                }
                let transactionBodies = txEntries.values.compactMap { $0.node?.body.node }
                guard transactionBodies.count == txEntries.count else {
                    NodeLogger("blocks").error("\(directory): failed to resolve transaction bodies while materializing accepted state roots")
                    return nil
                }
                let prevState = try await block.prevState.resolve(fetcher: fetcher)

                let (updatedState, recomputedDiff) = try await prevState.proveAndUpdateState(
                    allAccountActions: transactionBodies.flatMap { $0.accountActions },
                    allActions: transactionBodies.flatMap { $0.actions },
                    allDepositActions: transactionBodies.flatMap { $0.depositActions },
                    allGenesisActions: transactionBodies.flatMap { $0.genesisActions },
                    allReceiptActions: transactionBodies.flatMap { $0.receiptActions },
                    allWithdrawalActions: transactionBodies.flatMap { $0.withdrawalActions },
                    transactionBodies: transactionBodies,
                    fetcher: fetcher
                )
                updatedHeader = try LatticeStateHeader(node: updatedState)
                createdRoots = Set(recomputedDiff.created.keys)

                let unverifiedCreated = Set(stateDiff.created.keys).subtracting(createdRoots)
                guard unverifiedCreated.isEmpty else {
                    let shortRoots = unverifiedCreated.map { String($0.prefix(16)) }.joined(separator: ",")
                    NodeLogger("blocks").error("\(directory): accepted state diff contains root(s) not produced by recomputation: \(shortRoots)")
                    return nil
                }
            }
            guard updatedHeader.rawCID == block.postState.rawCID else {
                NodeLogger("blocks").error("\(directory): accepted postState \(String(updatedHeader.rawCID.prefix(16)))… does not match block \(String(block.postState.rawCID.prefix(16)))…")
                return nil
            }
            // SHADOW perf: `updatedHeader` is the fully-materialized accepted post-state
            // frontier (from `materializedPostState` or the local `proveAndUpdateState`
            // recompute) — the SAME frontier `recordStateRefcountOnAccept` would
            // otherwise re-resolve. Capture its membership-faithful node-set + edges
            // here (one in-memory walk, no fetch) so the accept hook consumes it
            // directly. Gated on the shadow OR flip flag (the flip drives retention off
            // this index, so it must capture the post frontier too) → zero overhead when
            // both are OFF.
            if stateDeathIndexShadowEnabled || stateRetentionViaRefcount {
                var graph = StateGraph(nodes: [], edges: [:])
                updatedHeader.collectStateRefEdges(into: &graph)
                stateRefcountPendingPost[chainKey(forDirectory: directory)] =
                    (cid: updatedHeader.rawCID, graph: graph)
            }
            guard !createdRoots.isEmpty else { return [] }

            // Serialize the verified updated frontier through the same
            // volume-aware path used by candidate/template storage. The diff
            // names the changed roots, but trie state needs its containing
            // Volume boundaries written durably so those roots are serveable
            // after sync/restart.
            let (volumes, roots) = try collectStateVolumes(updatedHeader, broker: MemoryBroker())
            var volumesToStore = volumes
            var materializedRoots = Set(roots)
            let requiredVolumeRoots = acceptedStateBoundaryRoots(updatedHeader)
                .filter { !$0.isEmpty && !materializedRoots.contains($0) }
                .sorted()
            for root in requiredVolumeRoots {
                if await network.hasDurableVolume(rootCID: root) {
                    materializedRoots.insert(root)
                    continue
                }
                guard let payload = await verifiedPayloadForAcceptedStateRoot(
                    root,
                    network: network,
                    fetcher: fetcher
                ) else {
                    NodeLogger("blocks").error("\(directory): accepted state boundary root \(String(root.prefix(16)))… was not materialized or fetchable")
                    return nil
                }
                volumesToStore.append(payload)
                materializedRoots.insert(payload.root)
            }
            let missingCreatedRoots = createdRoots
                .filter { !$0.isEmpty && !materializedRoots.contains($0) }
                .sorted()
            for root in missingCreatedRoots {
                if await network.hasDurableVolume(rootCID: root) {
                    materializedRoots.insert(root)
                    continue
                }
                guard let payload = await verifiedPayloadForAcceptedStateRoot(
                    root,
                    network: network,
                    fetcher: fetcher
                ) else {
                    NodeLogger("blocks").error("\(directory): recomputed accepted state root \(String(root.prefix(16)))… was not materialized or fetchable")
                    return nil
                }
                volumesToStore.append(payload)
                materializedRoots.insert(payload.root)
            }
            if !volumesToStore.isEmpty {
                try await network.storeVolumesDurably(volumesToStore)
            }
            return Array(materializedRoots)
        } catch {
            NodeLogger("blocks").error("\(directory): failed to materialize accepted state roots: \(error)")
            return nil
        }
    }

    private func acceptedStateBoundaryRoots(_ state: LatticeStateHeader) -> [String] {
        var seen = Set<String>()
        var roots: [String] = []
        func append(_ root: String) {
            guard !root.isEmpty, seen.insert(root).inserted else { return }
            roots.append(root)
        }
        append(state.rawCID)
        guard let node = state.node else { return roots }
        append(node.accountState.rawCID)
        append(node.generalState.rawCID)
        append(node.depositState.rawCID)
        append(node.genesisState.rawCID)
        append(node.receiptState.rawCID)
        return roots
    }

    private func verifiedPayloadForAcceptedStateRoot(
        _ root: String,
        network: ChainNetwork,
        fetcher: Fetcher
    ) async -> SerializedVolume? {
        if let local = await network.verifiedLocalVolume(root: root) {
            return local
        }

        let entries = await network.ivy.fetchVolumeFromAllPeers(rootCID: root)
        if !entries.isEmpty,
           entries[root] != nil,
           entries.allSatisfy({ ContentAddressVerifier.data($0.value, matches: $0.key) }) {
            return SerializedVolume(root: root, entries: entries)
        }

        guard let data = try? await fetcher.fetch(rawCid: root),
              ContentAddressVerifier.data(data, matches: root) else {
            return nil
        }
        return SerializedVolume(root: root, entries: [root: data])
    }

    /// Store a block as a single OBJECT CLOSURE. One `storeRecursively` pass over
    /// the block walks its entire owned closure — transactions (+ bodies), spec,
    /// the postState trie, children and descendant blocks — producing per-boundary
    /// volumes joined by VolumeBroker owned-child edges and rooted at `blockHash`.
    /// References (prevState/parentState/parent) are not children, so they are
    /// never walked (no backward over-retention). No singleton promotion: content
    /// keeps its closure grain, so a single `retain(blockRoot)` can transitively
    /// protect the whole closure. Partial hydration is handled by cashew
    /// (`storeRecursively` skips an unhydrated boundary), exactly as the prior
    /// per-subtree `.node` guards did.
    private func collectBlockVolumes(
        _ block: Block,
        blockHash: String,
        broker: any VolumeBroker
    ) throws -> (volumes: [SerializedVolume], roots: [String]) {
        let storer = BrokerStorer(broker: broker)
        try VolumeImpl<Block>(node: block).storeRecursively(storer: storer)
        let volumes = storer.collectVolumes(root: blockHash)
        return (volumes, storer.storedRoots)
    }

    /// Store a state frontier as a single closure: one pass walks the LatticeState
    /// header and its five sub-state tries into per-boundary volumes + owned-child
    /// edges, rooted at the state CID.
    private func collectStateVolumes(
        _ state: LatticeStateHeader,
        broker: any VolumeBroker
    ) throws -> (volumes: [SerializedVolume], roots: [String]) {
        let storer = BrokerStorer(broker: broker)
        try state.storeRecursively(storer: storer)
        let volumes = storer.collectVolumes(root: state.rawCID)
        return (volumes, storer.storedRoots)
    }
    /// Pin + announce + persist + prune an already-stored block as canonical
    /// chain storage. Call only after the block is accepted, so rejected
    /// candidates stored via `storeBlockData` are never pinned or announced.
    @discardableResult
    func commitBlockStorage(_ block: Block, storedRoots: [String], network: ChainNetwork, directory: String? = nil, stateDiff: StateDiff = .empty) async -> Bool {
        let dir = directory ?? network.directory
        do {
            let blockHash = try VolumeImpl<Block>(node: block).rawCID
            let owner = "\(network.ownerNamespace):\(block.height)"
            try await network.pinBatchDurably(roots: blockStorageProtectionRoots(block: block), owner: owner)
            await announceStoredRoots(storedRoots, network: network)
            if let store = stateStores[chainKey(forDirectory: dir)] {
                try await store.persistStoredRoots(height: block.height, roots: storedRoots)
            }
            // Advance state retained roots before prune, but only if this accepted
            // block is now the canonical tip. Valid side forks must not replace
            // the canonical retained-root set.
            try await advanceStateRetainedRootsIfCanonicalTip(
                block: block,
                blockHash: blockHash,
                network: network,
                directory: dir
            )
            await releaseCanonicalStateProtectionIfRetainedRoots(
                block: block,
                blockHash: blockHash,
                network: network,
                directory: dir
            )
            // B1(c): release stale candidate pins now that the tip advanced.
            // Candidates at or below the confirmed tip are dead; the next-height
            // candidate remains live.
            try await releaseStaleCandidatePins(block: block, network: network)
            try await pruneBlocks(block: block, directory: dir, network: network)
            // SHADOW: maintain the reference-counting state refcount index alongside
            // the live object-grain pins. Best-effort and AFTER the canonical commit/
            // prune succeeded, so it can never affect accept/prune behavior.
            await recordStateRefcountOnAccept(block: block, height: block.height, network: network, directory: dir)
            return true
        } catch {
            NodeLogger("blocks").error("Failed to commit block storage: \(error)")
            return false
        }
    }
    /// B1(c): release candidate volume pins that are no longer useful:
    ///   - the exact promoted candidate for the accepted block, and
    ///   - any candidate below the confirmed tip.
    ///
    /// Same-height alternatives are deliberately left pinned. During concurrent
    /// mining an equal-height side candidate can still be extended into the heavier
    /// fork, so pruning every `candidate:<ns>:<height>` owner when one sibling is
    /// accepted can make delayed side-fork validation lose its block bundle.
    func releaseStaleCandidatePins(block: Block, network: ChainNetwork) async throws {
        let prefix = Self.candidateStorageOwnerPrefix(ownerNamespace: network.ownerNamespace)
        let promotedOwner = candidateStorageOwner(block: block, network: network)
        let owners = await network.pinnedOwners(prefix: prefix)
        for owner in owners {
            guard let height = Self.candidateStorageOwnerHeight(owner: owner, prefix: prefix),
                  height < block.height || owner == promotedOwner else { continue }
            try await network.unpinAllDurably(owner: owner)
        }
    }
    /// crash-mid-prune sweep. `pruneBlocks` unpins exactly one height per
    /// committed block (`block.height - retentionDepth`). A crash between
    /// `commitBlockStorage`'s `pinBatchDurably` and `pruneBlocks` skips that height's
    /// prune FOREVER — the next block prunes a LATER height and never walks back, so
    /// the canonical block-height owner `<ownerNamespace>:<skippedHeight>` leaks
    /// (unbounded retention growth, one stranded owner per crash). Candidate pins have
    /// `releaseStaleCandidatePins` and account pins got a startup sweep (#253); this is
    /// the equivalent below-retention-floor sweep for canonical block-height owners.
    ///
    /// Enumerate `pinnedOwners(prefix: "<ownerNamespace>:")`, parse the trailing
    /// height, and `unpinAllDurably` every owner strictly below the live retention
    /// floor (mirroring `pruneBlocks`/`reconcileValidatorPins` exactly):
    ///   - `.tip`:       floor = chainTip; release height < chainTip.
    ///   - `.retention`: floor = chainTip - retentionDepth; release height <= floor.
    /// `.historical` keeps every main-chain block forever and only releases off-main
    /// forks (hash-scoped, indistinguishable from the bare owner scheme), so it is a
    /// deliberate no-op here — exactly as reconcileValidatorPins is.
    ///
    /// The candidate / account / validates owners share the broker but have DISTINCT
    /// prefixes (`candidate:`, `account:`, `validates:`), none of which begin with
    /// `<ownerNamespace>:`, and only the bare `<ns>:<height>` owner parses to a
    /// UInt64 — so the prefix+parse filter selects canonical block-height owners only.
    func sweepStaleBlockStoragePins(directory: String, network: ChainNetwork) async throws {
        guard let chain = await chain(for: directory) else { return }
        let chainTip = await chain.getHighestBlockHeight()
        let releaseBelowOrAt: UInt64
        switch config.blockRetention {
        case .tip:
            guard chainTip > 0 else { return }
            releaseBelowOrAt = chainTip - 1
        case .retention:
            guard chainTip > config.retentionDepth else { return }
            releaseBelowOrAt = chainTip - config.retentionDepth
        case .historical:
            return
        }
        let prefix = "\(network.ownerNamespace):"
        for owner in await network.pinnedOwners(prefix: prefix) {
            guard let height = UInt64(owner.dropFirst(prefix.count)),
                  height <= releaseBelowOrAt else { continue }
            try await network.unpinAllDurably(owner: owner)
        }
    }
    /// Run the canonical block-height pin sweep across every subscribed
    /// chain. Wired into the periodic storage-maintenance cycle alongside
    /// `reconcileValidatorPins` so a crash-skipped prune self-heals on a later pass.
    /// Returns nothing; failures are logged per-chain and do not halt other chains.
    func sweepStaleBlockStoragePins() async {
        for directory in allDirectories() {
            guard let network = network(for: directory) else { continue }
            do {
                try await sweepStaleBlockStoragePins(directory: directory, network: network)
            } catch {
                NodeLogger("gc").error("\(directory): stale block-storage pin sweep failed: \(error)")
            }
        }
    }
    /// F5-4 (Hierarchical GHOST): persist an accepted block's verified sparse work
    /// proof — the content-addressed path from the absolute PoW root to the block —
    /// as block metadata, keyed by block hash and stamped at the block's height so
    /// it prunes/unpins on the same schedule as the block (see `pruneBlocks`).
    /// No-op when there's no proof (e.g. the PoW-root block is its own anchor) or no
    /// state store for the chain. Historical nodes thereby retain every block's
    /// proof; pruning nodes drop them with the block.
    func persistAcceptedBlockProof(directory: String, height: UInt64, blockHash: String, proof: ChildBlockProof?) async {
        guard let proof, let store = stateStores[chainKey(forDirectory: directory)] else { return }
        do {
            try await store.persistBlockProof(
                height: height,
                blockHash: blockHash,
                proofID: proof.proofPathID,
                proof: proof.serialize()
            )
        } catch {
            NodeLogger("blocks").error("\(directory): persistBlockProof failed for \(String(blockHash.prefix(16)))… at \(height): \(error)")
        }
    }
    /// ChainNetworkDelegate: serve a stored ChildBlockProof by block CID so a peer
    /// can bundle it with child-chain headers during sync (F5-4 proof-carrying sync).
    /// Reads the `block_proofs` metadata persisted at ingestion; nil for the root
    /// chain or any block without a stored proof.
    public func chainNetwork(_ network: ChainNetwork, blockProofData cid: String) async -> Data? {
        let directory = network.directory
        guard let proofData = stateStores[chainKey(forDirectory: directory)]?.getBlockProofs(blockHash: cid),
              !proofData.isEmpty else { return nil }
        let proofs = proofData.compactMap { ChildBlockProof.deserialize($0) }
        guard !proofs.isEmpty else { return nil }
        return ChildBlockProofEnvelope.serialize(proofs)
    }
    /// True when a ChildBlockProof is already persisted for `blockHash` in `directory`.
    /// Used by the proof self-heal backfill to skip blocks that already have a proof.
    public func blockProofExists(directory: String, blockHash: String) -> Bool {
        !(stateStores[chainKey(forDirectory: directory)]?.getBlockProofs(blockHash: blockHash).isEmpty ?? true)
    }
    /// The child's last-known parent tip hash (highest persisted parent header) — the
    /// proof self-heal backfill's walk start when no fresh chainAnnounce has arrived.
    public func highestParentHeaderHash(directory: String) -> String? {
        stateStores[chainKey(forDirectory: directory)]?.getHighestParentHeader()?.hash
    }
    func persistAcceptedChildParentAnchor(
        directory: String,
        blockHash: String,
        height: UInt64,
        parentAnchor: ParentAnchor?,
        replaceExisting: Bool = false
    ) async throws {
        guard let parentAnchor,
              let store = stateStores[chainKey(forDirectory: directory)] else { return }
        if replaceExisting {
            try await store.replaceChildParentAnchor(
                childHash: blockHash,
                parentHash: parentAnchor.blockHash,
                height: height
            )
        } else {
            try await store.persistChildParentAnchor(
                childHash: blockHash,
                parentHash: parentAnchor.blockHash,
                height: height
            )
        }
        let liveIndex = await ensureLiveInheritedWeightIndex(directory: directory)
        _ = liveIndex.recordParentAnchor(childHash: blockHash, parentHash: parentAnchor.blockHash)
    }
    func canonicalStorageOwner(block: Block, network: ChainNetwork) -> String {
        "\(network.ownerNamespace):\(block.height)"
    }
    /// Consensus pins retain non-state object content. Canonical state frontier
    /// retention is owned by the storage layer's retained-root scope when the
    /// production gate is on, or by the legacy refcount path when that test gate
    /// is enabled. References (`prevState`/`parentState`) remain deliberately
    /// unpinned by this block.
    func consensusPinRoots(block: Block) -> [String] {
        let blockHash = try! VolumeImpl<Block>(node: block).rawCID
        if stateRetentionViaRetainedRoots || stateRetentionViaRefcount {
            return [blockHash].filter { !$0.isEmpty }
        }
        return [blockHash, block.postState.rawCID].filter { !$0.isEmpty }
    }
    /// Roots pinned while an accepted block is still being finalized. Canonical
    /// blocks shed the extra post-state root after the retained-root scope has
    /// advanced; valid side forks keep it under the height owner so peers can
    /// still fetch and evaluate the side branch until normal height pruning.
    func blockStorageProtectionRoots(block: Block) -> [String] {
        var seen = Set<String>()
        var roots: [String] = []
        for root in consensusPinRoots(block: block) + [block.postState.rawCID] where !root.isEmpty {
            guard seen.insert(root).inserted else { continue }
            roots.append(root)
        }
        return roots
    }
    func releaseCanonicalStateProtectionIfRetainedRoots(
        block: Block,
        blockHash: String,
        network: ChainNetwork,
        directory: String
    ) async {
        guard stateRetentionViaRetainedRoots else { return }
        guard await chain(for: directory)?.getMainChainTip() == blockHash else { return }
        let postStateRoot = block.postState.rawCID
        guard !postStateRoot.isEmpty else { return }
        do {
            try await network.unpinDurably(root: postStateRoot, owner: canonicalStorageOwner(block: block, network: network))
        } catch {
            NodeLogger("blocks").warn("\(directory): failed to release redundant canonical postState pin \(String(postStateRoot.prefix(16)))…: \(error)")
        }
    }
    static func candidateStorageOwnerPrefix(ownerNamespace: String) -> String {
        "candidate:\(ownerNamespace):"
    }
    static func candidateStorageOwner(ownerNamespace: String, height: UInt64, blockHash: String? = nil) -> String {
        let base = "\(candidateStorageOwnerPrefix(ownerNamespace: ownerNamespace))\(height)"
        guard let blockHash, !blockHash.isEmpty else { return base }
        return "\(base):\(blockHash)"
    }
    static func candidateStorageOwnerHeight(owner: String, prefix: String) -> UInt64? {
        guard owner.hasPrefix(prefix) else { return nil }
        let suffix = owner.dropFirst(prefix.count)
        let heightString = suffix.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        guard !heightString.isEmpty else { return nil }
        return UInt64(heightString)
    }
    func candidateStorageOwner(block: Block, network: ChainNetwork) -> String {
        let blockHash = try! VolumeImpl<Block>(node: block).rawCID
        return Self.candidateStorageOwner(ownerNamespace: network.ownerNamespace, height: block.height, blockHash: blockHash)
    }
    func pinBlockStorageForConsensus(_ block: Block, network: ChainNetwork) async -> Bool {
        let owner = canonicalStorageOwner(block: block, network: network)
        // Pin the accepted-block protection roots. The failure-path unpin must
        // release the SAME pinned set under this owner.
        let pinRoots = blockStorageProtectionRoots(block: block)
        do {
            try await network.pinBatchDurably(roots: pinRoots, owner: owner)
            return true
        } catch {
            NodeLogger("blocks").error("Failed to pin block storage before consensus: \(error)")
            await unpinBlockStorageRoots(pinRoots, owner: owner, network: network)
            return false
        }
    }
    func unpinBlockStorageRoots(_ roots: [String], owner: String, network: ChainNetwork) async {
        for root in roots {
            do {
                try await network.unpinDurably(root: root, owner: owner)
            } catch {
                NodeLogger("blocks").warn("Failed to unpin rejected candidate root \(String(root.prefix(16)))…: \(error)")
            }
        }
    }
    func unpinBlockStorageForRejectedCandidate(_ block: Block, storedRoots: [String], network: ChainNetwork) async {
        await unpinBlockStorageRoots(storedRoots, owner: candidateStorageOwner(block: block, network: network), network: network)
    }
    @discardableResult
    func finalizeDurableBlockStorage(_ block: Block, blockHash: String, storedRoots: [String], network: ChainNetwork, directory: String, stateDiff: StateDiff) async -> Bool {
        await announceStoredRoots(storedRoots, network: network)
        if let store = stateStores[chainKey(forDirectory: directory)] {
            do {
                try await store.persistStoredRoots(height: block.height, roots: storedRoots)
            } catch {
                NodeLogger("blocks").error("\(directory): persist stored roots failed at height \(block.height): \(error)")
            }
        }
        do {
            try await advanceStateRetainedRootsIfCanonicalTip(
                block: block,
                blockHash: blockHash,
                network: network,
                directory: directory
            )
            await releaseCanonicalStateProtectionIfRetainedRoots(
                block: block,
                blockHash: blockHash,
                network: network,
                directory: directory
            )
        } catch {
            NodeLogger("blocks").error("\(directory): failed to advance state retained roots for \(String(blockHash.prefix(16)))…: \(error)")
            await markChainStorageDegraded(directory: directory, reason: "failed to advance state retained roots")
            return false
        }
        do {
            try await pruneBlocks(block: block, directory: directory, network: network)
        } catch {
            NodeLogger("blocks").error("\(directory): accepted block \(String(blockHash.prefix(16)))… stored durably but prune cleanup failed (validator-pin rows survive as the durable retry ledger; reconciliation/retry reclaims): \(error)")
        }
        // SHADOW: maintain the reference-counting state refcount index (best-effort,
        // no behavior change to the live object-grain pins).
        await recordStateRefcountOnAccept(block: block, height: block.height, network: network, directory: directory)
        return true
    }
    /// Announce stored CIDs to the DHT so peers can fetch them.
    func announceStoredRoots(_ cids: [String], network: ChainNetwork) async {
        guard !cids.isEmpty else { return }
        // P-202: read config once (not inside the per-CID loop) and parallelize
        // the independent DHT announcements via a task group.
        let fee = await network.ivy.config.relayFee * 2
        let expiry = UInt64(Date().timeIntervalSince1970) + config.pinAnnounceExpiry
        await withTaskGroup(of: Void.self) { group in
            for root in cids {
                group.addTask { await network.announce(cid: root, expiry: expiry, fee: fee) }
            }
        }
    }
    func storeBlockContentForDurableValidation(
        header: BlockHeader,
        block: Block,
        directory: String,
        network: ChainNetwork,
        preStoredCIDs: [String]?,
        storageBrokerOverride: (any VolumeBroker)?
    ) async -> [String]? {
        let storedRoots: [String]
        if let preStoredCIDs {
            // Pre-stored mined candidates can be sparse relative to the fully
            // resolved block content used by validation. Restage the resolved
            // block before promotion so canonical pins include every volume a
            // syncing peer later needs to resolveBlockContent.
            let refreshedRoots: [String]?
            if let broker = storageBrokerOverride {
                refreshedRoots = await storeBlockData(block, broker: broker)
            } else {
                refreshedRoots = await storeBlockData(block, network: network)
            }
            guard let refreshedRoots else {
                NodeLogger("blocks").error("\(directory): failed to durably restage resolved block \(String(header.rawCID.prefix(16)))… before consensus mutation")
                return nil
            }
            var seen = Set<String>()
            storedRoots = (preStoredCIDs + refreshedRoots).filter { root in
                guard !root.isEmpty, seen.insert(root).inserted else { return false }
                return true
            }
        } else if let broker = storageBrokerOverride {
            guard let cids = await storeBlockData(block, broker: broker) else {
                NodeLogger("blocks").error("\(directory): failed to durably store block \(String(header.rawCID.prefix(16)))… before consensus mutation")
                return nil
            }
            storedRoots = cids
        } else {
            guard let cids = await storeBlockData(block, network: network) else {
                NodeLogger("blocks").error("\(directory): failed to durably store block \(String(header.rawCID.prefix(16)))… before consensus mutation")
                return nil
            }
            storedRoots = cids
        }

        let stillMissing = await missingLocalRoots(block: block, blockHash: header.rawCID, network: network)
        guard stillMissing.isEmpty else {
            let shortRoots = stillMissing.map { String($0.prefix(16)) }.joined(separator: ",")
            NodeLogger("blocks").error("\(directory): block \(String(header.rawCID.prefix(16)))… content store completed but durable content root(s) are still missing before validation: \(shortRoots)")
            return nil
        }
        return storedRoots
    }
    func canonicalBlockStorageRoots(
        block: Block,
        blockHash: String,
        collectedRoots: [String],
        stateDiff: StateDiff,
        network: ChainNetwork,
        directory: String,
        source: any ContentSource
    ) async -> [String]? {
        // `CoalescingFetcher(source)` resolves byte-identically to the prior
        // `fetcher`; the materialize path bottoms out in `fetcher.fetch(rawCid:)`.
        let fetcher = CoalescingFetcher(source)
        let requiredRoots = requiredCanonicalRoots(block: block, blockHash: blockHash, stateDiff: stateDiff)
        let availableRoots = Set(collectedRoots)
        let uncollectedRoots = requiredRoots.filter { !availableRoots.contains($0) }
        if !uncollectedRoots.isEmpty {
            let shortRoots = uncollectedRoots.map { String($0.prefix(16)) }.joined(separator: ",")
            NodeLogger("blocks").debug("\(directory): accepted block \(String(blockHash.prefix(16)))… canonical delta root(s) were already durable outside the block-content collection: \(shortRoots)")
        }

        var collectedRoots = collectedRoots
        let initiallyMissing = await missingDurableRoots(block: block, blockHash: blockHash, network: network, stateDiff: stateDiff)
        if !initiallyMissing.isEmpty {
            guard let imported = await materializeAcceptedCanonicalRoots(
                initiallyMissing,
                network: network,
                fetcher: fetcher,
                directory: directory
            ) else {
                let shortRoots = initiallyMissing.map { String($0.prefix(16)) }.joined(separator: ",")
                NodeLogger("blocks").error("\(directory): block \(String(blockHash.prefix(16)))… store completed but canonical delta root(s) are still missing before consensus mutation: \(shortRoots)")
                return nil
            }
            collectedRoots.append(contentsOf: imported)
        }

        let stillMissing = await missingDurableRoots(block: block, blockHash: blockHash, network: network, stateDiff: stateDiff)
        guard stillMissing.isEmpty else {
            let shortRoots = stillMissing.map { String($0.prefix(16)) }.joined(separator: ",")
            NodeLogger("blocks").error("\(directory): block \(String(blockHash.prefix(16)))… store completed but canonical delta root(s) are still missing before consensus mutation: \(shortRoots)")
            return nil
        }
        var seen = Set<String>()
        var canonicalRoots: [String] = []
        for root in collectedRoots + requiredRoots where !root.isEmpty {
            guard seen.insert(root).inserted else { continue }
            canonicalRoots.append(root)
        }
        return canonicalRoots
    }

    private func materializeAcceptedCanonicalRoots(
        _ roots: [String],
        network: ChainNetwork,
        fetcher: Fetcher,
        directory: String
    ) async -> [String]? {
        var imported: [String] = []
        var seen = Set<String>()
        for root in roots where !root.isEmpty && seen.insert(root).inserted {
            if await network.hasDurableVolume(rootCID: root) {
                imported.append(root)
                continue
            }

            // Parent extraction can observe a committed parent block before the
            // child peer has published the same child block locally. Import the
            // exact accepted root from whatever verified source validation used
            // (child peer or parent-carried candidate volumes), then re-run the
            // durable guard below. Consensus still decides acceptance; this only
            // turns already content-addressed data into local availability.
            var materialized = false
            for attempt in 0..<3 {
                if await prefetchAcceptedVolumeRoot(root, network: network, fetcher: fetcher) {
                    materialized = true
                    break
                }
                if let payload = await verifiedPayloadForAcceptedStateRoot(
                    root,
                    network: network,
                    fetcher: fetcher
                ) {
                    do {
                        try await network.storeVolumeDurably(payload)
                        if await network.hasDurableVolume(rootCID: root) {
                            materialized = true
                            break
                        }
                    } catch {
                        NodeLogger("blocks").error("\(directory): failed to durably store canonical root \(String(root.prefix(16)))…: \(error)")
                        return nil
                    }
                }
                if attempt < 2 {
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            guard materialized, await network.hasDurableVolume(rootCID: root) else {
                NodeLogger("blocks").error("\(directory): accepted canonical root \(String(root.prefix(16)))… was not materialized or fetchable")
                return nil
            }
            imported.append(root)
        }
        return imported
    }

    /// Fetch a block's entire CONTENT closure from peers as whole volumes — the
    /// block volume, the chain-spec volume, and every transaction-body volume —
    /// each in ONE round-trip keyed by its ROOT CID. Object-grain storage groups
    /// a volume's internal trie nodes as NON-root entries, so they arrive bundled
    /// with their volume root and are NEVER requested individually over the wire
    /// (a root-keyed peer cannot serve a non-root entry; doing so is an
    /// antipattern that re-introduces per-node fetch churn and stalls sync). The
    /// transaction trie lives inside the block bundle, so listing its leaves to
    /// discover the per-tx volumes needs no extra network round-trip. After this
    /// returns, `resolveBlockContent` resolves entirely from the local CAS.
    /// Returns the bundle roots it fetched, so a failed resolution can
    /// attribute the deficient bundle(s) to their servers
    /// (`IvyFetcher.reportDeficientVolumes`) and retry with `force`. Routing
    /// around punished servers is handled inside Ivy (deficiency suppression).
    @discardableResult
    func prefetchBlockContentClosure(
        blockHash: String,
        network: ChainNetwork,
        force: Bool = false
    ) async -> [String] {
        await prefetchBlockContentClosure(
            blockHash: blockHash,
            ivyFetcher: network.ivyFetcher,
            // Resolve the just-fetched block bundle to enumerate sub-volume roots
            // over the SAME tier `ivyFetcher.fetchVolumeBundle` persists into — the
            // fetch-cache (memory) tier. `canonicalContentFetcher()` reads the
            // DURABLE tier only, so it cannot see the freshly network-fetched
            // bundle (the fetch cache is memory-only by design), making `.list`
            // enumerate zero tx-leaf roots and stranding sync once non-root
            // in-package serving is removed. `fetchCacheFetcher()` is the semantic
            // helper for exactly this enumeration tier.
            localFetcher: network.fetchCacheFetcher(),
            force: force
        )
    }

    /// Closure prefetch over an explicit `ivyFetcher` (for the parent-chain
    /// extractor, whose parent content is reached through its own IvyFetcher
    /// rather than a registered ChainNetwork). `localFetcher` resolves the
    /// just-bundled block/trie nodes from the local CAS to enumerate boundaries.
    @discardableResult
    func prefetchBlockContentClosure(
        blockHash: String,
        ivyFetcher: IvyFetcher,
        localFetcher: Fetcher,
        force: Bool = false
    ) async -> [String] {
        guard !blockHash.isEmpty else { return [] }
        var bundleRoots = [blockHash]
        // Prefer a multi-entry block bundle first: a fast headers-only peer with
        // only the bare root can otherwise shadow a complete holder. If no such
        // complete holder appears, fall back to accept-first because compact or
        // sparse block roots can legitimately be single-entry while their content
        // boundaries are fetched separately. The caller's JIT resolution remains
        // the authoritative completeness check and will punish/refetch a true
        // bare-root stub.
        let fetchedPreferred = await ivyFetcher.fetchVolumeBundle(
            rootCID: blockHash,
            preferComplete: true,
            force: force
        )
        if !fetchedPreferred {
            await ivyFetcher.fetchVolumeBundle(rootCID: blockHash, force: true)
        }
        guard let block = try? await VolumeImpl<Block>(rawCID: blockHash, node: nil, encryptionInfo: nil)
            .resolve(fetcher: localFetcher).node else { return bundleRoots }
        if !block.spec.rawCID.isEmpty {
            bundleRoots.append(block.spec.rawCID)
            await ivyFetcher.fetchVolumeBundle(rootCID: block.spec.rawCID, force: force)
        }
        // The transaction trie is in the block bundle (local); resolve its
        // STRUCTURE only (.list) to enumerate the per-transaction volume roots,
        // then fetch each as a whole volume. No internal node is fetched alone.
        // This prefetch is a warm-up for the batched ContentSource resolution
        // that follows, not the source of truth for the closure's boundary set —
        // resolution waves fetch any boundary this enumeration misses.
        if let txDict = try? await block.transactions.resolve(
               paths: [[""]: ResolutionStrategy.list], fetcher: localFetcher).node,
           let entries = try? txDict.sortedKeysAndValues() {
            for (_, txLeaf) in entries where !txLeaf.rawCID.isEmpty {
                bundleRoots.append(txLeaf.rawCID)
                await ivyFetcher.fetchVolumeBundle(rootCID: txLeaf.rawCID, force: force)
            }
        }
        return bundleRoots
    }

    private func prefetchAcceptedVolumeRoot(
        _ root: String,
        network: ChainNetwork,
        fetcher: Fetcher
    ) async -> Bool {
        // cashew 3.x has no enterVolume pre-fetch: fetch the root directly.
        // IvyFetcher.fetch writes fetched content through to the durable broker,
        // warming the durable cache as enterVolume did.
        _ = try? await fetcher.fetch(rawCid: root)
        return await network.hasDurableVolume(rootCID: root)
    }
    func pruneBlocks(block: Block, directory: String, network: ChainNetwork) async throws {
        switch config.blockRetention {
        case .tip:
            if block.height > 0 {
                let pruneHeight = block.height - 1
                let prevOwner = "\(network.ownerNamespace):\(pruneHeight)"
                try await network.unpinAllDurably(owner: prevOwner)
                if let store = stateStores[chainKey(forDirectory: directory)] {
                    try await store.deleteStoredRoots(height: pruneHeight)
                }
                // F5-4: drop the pruned height's sparse work proof alongside the block.
                try await stateStores[chainKey(forDirectory: directory)]?.deleteBlockProofs(height: pruneHeight)
                try await releaseValidatorPinsThrough(directory: directory, throughHeight: pruneHeight, network: network)
                // SHADOW: log (do NOT act on) the refcount-index reclaim verdict at the
                // advanced floor. floor = pruneHeight + 1 (every block <= pruneHeight
                // is now pruned, i.e. their root pins are released).
                await logStateRefcountReclaimVerdict(floor: pruneHeight + 1, directory: directory)
                // FLIP (gated, default OFF): drive STATE reclamation off the refcount
                // index — unpin the refcount-0 reclaim set (== reachability). Runs
                // AFTER the object-grain prune (so the floor's roots are released) and
                // BEFORE verify (so verify observes the post-reclaim broker state — in
                // flip mode the per-node pins ARE the retention, so verify must run
                // after they're released or it would see still-pinned reclaimables).
                // Fail-safe guarded: never unpins a node forward-reachable from a
                // retained root. A no-op when the gate is OFF.
                await reclaimRefcountStateNodes(floor: pruneHeight + 1, directory: directory, network: network)
                // PRODUCTION VERIFY (gated, drives no unpin): assert the index verdict
                // == broker reachability. In SHADOW mode the object-grain prune already
                // released the pins; in FLIP mode the reclaim above did. floor matches
                // the now-pruned boundary.
                await verifyStateRefcountAgainstReachability(floor: pruneHeight + 1, directory: directory, network: network)
            }

        case .retention:
            if block.height > config.retentionDepth {
                let pruneHeight = block.height - config.retentionDepth
                let pruneOwner = "\(network.ownerNamespace):\(pruneHeight)"
                try await network.unpinAllDurably(owner: pruneOwner)
                if let store = stateStores[chainKey(forDirectory: directory)] {
                    try await store.deleteStoredRoots(height: pruneHeight)
                    try await store.deleteBlockProofs(height: pruneHeight)
                }
                try await releaseValidatorPinsThrough(directory: directory, throughHeight: pruneHeight, network: network)
                // SHADOW: log (do NOT act on) the refcount-index reclaim verdict.
                await logStateRefcountReclaimVerdict(floor: pruneHeight + 1, directory: directory)
                // FLIP (gated, default OFF): refcount-driven STATE reclamation (==
                // reachability). Runs before verify (see the .tip case rationale).
                await reclaimRefcountStateNodes(floor: pruneHeight + 1, directory: directory, network: network)
                // PRODUCTION VERIFY (gated, drives no unpin).
                await verifyStateRefcountAgainstReachability(floor: pruneHeight + 1, directory: directory, network: network)
            }

        case .historical:
            if block.height > config.retentionDepth {
                let pruneHeight = block.height - config.retentionDepth
                guard let chain = await chain(for: directory) else { return }
                guard let blockHash = stateStores[chainKey(forDirectory: directory)]?.getBlockHash(atHeight: pruneHeight) else { return }
                let onMainChain = await chain.isOnMainChain(hash: blockHash)
                if !onMainChain {
                    let pruneOwner = "\(network.ownerNamespace):\(pruneHeight)"
                    try await network.unpinAllDurably(owner: pruneOwner)
                    // F5-4: drop ONLY this orphaned fork's proof (hash-scoped) — a
                    // canonical block's proof at the same height must survive, since a
                    // historical node keeps every main-chain block's proof forever.
                    try await stateStores[chainKey(forDirectory: directory)]?.deleteBlockProof(height: pruneHeight, blockHash: blockHash)
                    try await releaseValidatorPins(directory: directory, height: pruneHeight, network: network)
                }
            }
        }
    }
    static func acceptedBlockAnnouncementRoots(of block: Block, blockHash: String) -> [String] {
        var seen = Set<String>()
        var roots: [String] = []
        for root in blockContentRoots(of: block, blockHash: blockHash) + stateRoots(of: block) {
            guard !root.isEmpty, seen.insert(root).inserted else { continue }
            roots.append(root)
        }
        return roots
    }
    /// Announce accepted block volume roots to the Ivy DHT so peers can
    /// discover and fetch root-addressable serialized volumes. Internal CIDs
    /// inside those volumes are deliberately not announced as provider roots.
    func announceAcceptedBlockState(_ block: Block, blockHash: String, network: ChainNetwork) async {
        let fee = await network.ivy.config.relayFee * 2
        let expiry = UInt64(Date().timeIntervalSince1970) + config.pinAnnounceExpiry
        for cid in Self.acceptedBlockAnnouncementRoots(of: block, blockHash: blockHash) {
            Task { await network.announce(cid: cid, expiry: expiry, fee: fee) }
        }
    }

    // MARK: - Block Processing with Reorg Recovery
    /// Release validator pins at a height: removes both the broker pin
    /// (`validates:<childCID>` owner on the nexus root) and the StateStore
    /// row. Invoked from `pruneBlocks` at the retention boundary so the
    /// nexus block can age out once no descendant references remain.
    func releaseValidatorPins(directory: String, height: UInt64, network: ChainNetwork) async throws {
        guard let store = stateStores[chainKey(forDirectory: directory)] else { return }
        if let broker = validatorPinReleaserOverride {
            try await LatticeNode.releaseValidatorPins(store: store, broker: broker, height: height)
        } else {
            try await LatticeNode.releaseValidatorPins(store: store, broker: network.validatorPinReleaser(), height: height)
        }
    }
    /// The single broker capability the validator-pin release/reconcile core needs:
    /// drop all pins for the given owners in one transaction. `DiskBroker` already
    /// provides this; abstracting it as a seam lets a test inject an `unpinAllBatch`
    /// failure that is non-destructive to the underlying pins, so the retry/recovery
    /// invariant (rows survive a broker-unpin failure, then a restored broker reclaims
    /// them) is exercisable in CI.
    protocol ValidatorPinReleaser: Sendable {
        func unpinAllBatch(owners: [String]) async throws
    }
    /// Pure store+broker release used by both the prune cycle and reconcile.
    /// Removes the broker `validates:<childCID>` pins and the StateStore rows at
    /// `height`. Extracted so the reconciliation invariant is testable against a
    /// deterministic StateStore + DiskBroker without a live node.
    ///
    /// The `broker` is taken as the `ValidatorPinReleaser` seam (which `DiskBroker`
    /// satisfies) rather than the concrete `DiskBroker` so the load-bearing
    /// retry/recovery invariant — broker unpin fails ⇒ rows survive as the retry
    /// ledger — is testable through a fault-injecting broker that throws on
    /// `unpinAllBatch` WITHOUT destroying the underlying pins.
    static func releaseValidatorPins(store: StateStore, broker: any ValidatorPinReleaser, height: UInt64) async throws {
        let entries = store.getValidatorPins(height: height)
        if entries.isEmpty { return }
        // P-501: batch all unpinAll calls into one transaction instead of N auto-commits
        let owners = entries.map { "validates:\($0.childCID)" }
        // The validator-pin store rows are the durable retry ledger: keep them until
        // the broker unpin actually succeeds. Propagate broker failure (NOT try?) so
        // the store delete is the COMMIT POINT only after the leaked broker pin is
        // released — otherwise a swallowed broker failure would delete the rows and
        // orphan the broker pin beyond recovery (reconciliation below re-derives
        // orphans FROM these rows). On failure the error propagates; the caller logs
        // and does NOT mark the release complete, so reconcile/retry reclaims the pin
        // on a later pass (no-halt).
        try await broker.unpinAllBatch(owners: owners)
        try await store.deleteValidatorPins(height: height)
    }
    /// re-derive the authoritative live validator-pin set from canonical
    /// chain state and release any persisted/broker pin that should already be gone.
    /// This is the safety net for the no-halt decision: when a
    /// `deleteValidatorPins`/`releaseValidatorPins` failure surfaces and is logged
    /// (but not halted on), the broker pin + StateStore row leak. Reconcile re-runs
    /// the SAME release the prune cycle would have, so the leak self-heals on the
    /// next maintenance pass. Returns the number of orphaned pin-heights reclaimed
    /// for `directory`.
    ///
    /// Authoritative live-set rule — mirrors `pruneBlocks` exactly:
    ///   - `.tip`:       a pin is live iff `height >= chainTip`. Anything below is gone.
    ///   - `.retention`: a pin is live iff `height > chainTip - retentionDepth`.
    /// `.historical` keeps every main-chain block's pin forever and only releases
    /// off-main forks below the boundary (consensus-adjacent membership), so it has
    /// no purely height-based live boundary and reconcile is a deliberate no-op
    /// there — it never reclaims a pin that might still be live.
    @discardableResult
    func reconcileValidatorPins(directory: String) async -> Int {
        guard let store = stateStores[chainKey(forDirectory: directory)],
              let network = network(for: directory),
              let chain = await chain(for: directory) else { return 0 }

        let chainTip = await chain.getHighestBlockHeight()
        return await LatticeNode.reconcileValidatorPins(
            store: store,
            broker: network.validatorPinReleaser(),
            chainTip: chainTip,
            retention: config.blockRetention,
            retentionDepth: config.retentionDepth,
            label: directory
        )
    }
    /// Pure reconciliation core, parameterized over a StateStore + DiskBroker
    /// + chain tip + retention config. Extracted from the LatticeNode-bound method so
    /// the reclamation invariant runs in CI against a deterministic harness instead of a
    /// live node. The boundary derivation MUST mirror `pruneBlocks` exactly.
    @discardableResult
    static func reconcileValidatorPins(
        store: StateStore,
        broker: any ValidatorPinReleaser,
        chainTip: UInt64,
        retention: BlockRetention,
        retentionDepth: UInt64,
        label: String
    ) async -> Int {
        let orphanBoundary: UInt64
        switch retention {
        case .tip:
            guard chainTip > 0 else { return 0 }
            orphanBoundary = chainTip - 1            // release everything strictly below the tip
        case .retention:
            guard chainTip > retentionDepth else { return 0 }
            orphanBoundary = chainTip - retentionDepth
        case .historical:
            return 0                                  // no height-based live boundary; skip
        }

        // Group orphaned pins (height <= boundary) by height so we release with
        // the same height-keyed primitives the prune cycle uses.
        let orphanHeights = Set(
            store.getAllValidatorPins()
                .filter { $0.height <= orphanBoundary }
                .map(\.height)
        )
        guard !orphanHeights.isEmpty else { return 0 }

        var reclaimed = 0
        for height in orphanHeights.sorted() {
            do {
                try await releaseValidatorPins(store: store, broker: broker, height: height)
                reclaimed += 1
            } catch {
                NodeLogger("blocks").error("\(label): validator-pin reconcile failed to release height \(height): \(error)")
            }
        }
        if reclaimed > 0 {
            NodeLogger("gc").info("Reconciled \(reclaimed) orphaned validator-pin height(s) on \(label) at/below \(orphanBoundary)")
        }
        return reclaimed
    }
    /// Run validator-pin reconciliation across every subscribed chain. Wired into
    /// the periodic storage-maintenance cycle. Returns the total number
    /// of orphaned pin-heights reclaimed across all chains.
    @discardableResult
    public func reconcileValidatorPins() async -> Int {
        var total = 0
        for directory in allDirectories() {
            total += await reconcileValidatorPins(directory: directory)
        }
        return total
    }
    func releaseValidatorPinsThrough(directory: String, throughHeight: UInt64, network: ChainNetwork) async throws {
        guard let store = stateStores[chainKey(forDirectory: directory)] else { return }
        for height in store.getValidatorPinHeights(throughHeight: throughHeight) {
            try await releaseValidatorPins(directory: directory, height: height, network: network)
        }
    }
    func installValidatorPinReleaserForTesting(_ releaser: (any ValidatorPinReleaser)?) {
        validatorPinReleaserOverride = releaser
    }
}
