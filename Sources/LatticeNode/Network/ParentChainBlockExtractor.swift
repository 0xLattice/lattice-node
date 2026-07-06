// ParentChainBlockExtractor: Phase 3 per-process child block extraction.
//
// A child chain node subscribes to its parent chain's P2P gossip. When a
// parent block arrives, a ChildBlockExtractor pulls the embedded child block
// out of it and applies it to the child chain.
//
// The extractor is intentionally generic: today the parent is a Lattice chain
// (Nexus contains SwapTest blocks in `block.children`), but the same mechanism
// supports any parent — including Bitcoin acting as Nexus's parent via AuxPoW
// or OP_RETURN commitments. The ChildBlockExtractor protocol is the seam.
//
// Parent graph handling: the extractor maintains a lightweight verified parent
// graph (block hashes + parent edges + work only, no state) for observed proof
// work. Changes in the parent's canonical branch never roll back child state.
// Child validity follows content-addressed proofs and same-chain ancestry.

import Foundation
import Lattice
import Ivy
import LatticeNodeWire
import Tally
import cashew
import VolumeBroker
import UInt256
import Synchronization

// MARK: - ChildBlockExtractor protocol

/// Extracts a child-chain block from parent-chain block bytes by providing
/// a content-addressed sparse proof that the child block is reachable from
/// a PoW root.
///
/// The merged mining security model is:
///   1. Root: some data whose hash passes PoW (Nexus block, Bitcoin block header)
///   2. Sparse proof: a content-addressed path (CID chain) from root to leaf
///   3. Leaf: the child chain block
///
/// The extraction IS the sparse proof — following CID references from the PoW
/// root down to the child block. In cashew terms, this is a `.targeted`
/// resolution: `root.children[dir]` traverses only the required path without
/// materializing the rest of the tree. A Bitcoin implementation would traverse
/// `bitcoinHeader → coinbase → OP_RETURN → NexusCID → NexusBlock`.
///
/// Returns (childBlock, rootHash) where:
/// - childBlock: the extracted child chain block (the leaf)
/// - rootHash: hash of the PoW root (what passed target)
///   Used as `nexusHash` in `Block.validateProofOfWork(nexusHash:)`.
///   This hash propagates from the absolute root of the hierarchy — today Nexus,
///   eventually Bitcoin — to ALL levels. Mid and Stable both validate against
///   the same Bitcoin hash, not their immediate parent's hash.
public protocol ChildBlockExtractor: Sendable {
    func extract(
        childDirectory: String,
        from parentBlockData: Data,
        fetcher: Fetcher
    ) async -> (block: Block, rootHash: UInt256)?
}

// MARK: - Lattice implementation

/// Extracts a child block from a Lattice parent block's `children` field.
///
/// Returns (childBlock, rootHash) where rootHash = parentBlock.proofOfWorkHash().
/// The root hash is the key piece: it's what gets passed as `nexusHash` in
/// `Block.validateProofOfWork(nexusHash:)`. For the current 2-level
/// hierarchy (Nexus → SwapTest), rootHash is the Nexus block's hash.
/// When Bitcoin becomes the root, rootHash would be the Bitcoin block's hash.
///
/// Each chain subscribes to its IMMEDIATE parent only. Recursion is natural:
/// Nexus gossips → Mid extracts → Mid gossips → Stable extracts
public struct LatticeChildBlockExtractor: ChildBlockExtractor {
    public init() {}

    public func extract(
        childDirectory: String,
        from parentBlockData: Data,
        fetcher: Fetcher
    ) async -> (block: Block, rootHash: UInt256)? {
        guard let parentBlock = Block(data: parentBlockData) else { return nil }
        // rootHash is the parent block's PoW hash — this IS the nexusHash
        // that validateProofOfWork will use for all child blocks.
        let rootHash = parentBlock.proofOfWorkHash()
        guard let childrenNode = try? await parentBlock.children.resolve(
            paths: [[childDirectory]: .targeted], fetcher: fetcher
        ).node,
        let childHeader: VolumeImpl<Block> = try? childrenNode.get(key: childDirectory),
        let childBlock = try? await childHeader.resolve(fetcher: fetcher).node else { return nil }
        return (block: childBlock, rootHash: rootHash)
    }
}

// MARK: - ParentChainBlockExtractor

/// Ivy delegate that receives parent-chain blocks and applies embedded child blocks.
/// Wired in via --subscribe-p2p: the child node's Ivy connects to the parent
/// chain's P2P port and this delegate handles incoming blocks.
// Actor ensures that concurrent Ivy delegate callbacks (didReceiveBlock,
// didReceiveMessage) serialize access to actor-isolated state (pending header
// request maps, the parent fetcher), preventing data races that manifested as
// NSException crashes in Dictionary mutation under concurrent load.
public actor ParentChainBlockExtractor: IvyDelegate {
    private let childDirectory: String
    private let parentDirectory: String?
    private let parentChainPath: [String]?
    private let extractor: any ChildBlockExtractor
    private weak var node: LatticeNode?

    private let parentFetcherBroker = MemoryBroker(capacity: 512)
    private var parentFetcher: (ivyID: ObjectIdentifier, fetcher: IvyFetcher)?
    /// One-shot per-session guard for the proof self-heal backfill (below); latched
    /// only on a COMPLETED walk. `backfillInProgress` (check-and-set with no intervening
    /// await) prevents two concurrent walks from a connect race.
    private var didBackfillChildProofs = false
    private var backfillInProgress = false
    /// Depth bound for the proof-backfill parent-chain walk.
    private let maxProofBackfillBlocks = 50_000
    private struct PendingHeaderRequest {
        let targetPeer: PeerID
        let resume: @Sendable ([(cid: String, data: Data)]) -> Void
    }
    private struct PendingHeaderProofRequest {
        let targetPeer: PeerID
        let resume: @Sendable ([(cid: String, data: Data, proof: Data?)]) -> Void
    }
    private var pendingHeaderRequests: [Data: PendingHeaderRequest] = [:]
    private var pendingHeaderProofRequests: [Data: PendingHeaderProofRequest] = [:]

    /// Per-peer rate gate on inbound parent blocks. Each inbound parent block
    /// triggers a verify (block decode + PoW + optional proof verify) and
    /// a targeted child-block extraction (CAS resolution). A flood of distinct
    /// parent CIDs from one peer is the amplification vector; cap it per peer.
    private var inboundBuckets: PeerRateBuckets
    /// Per-peer rate gate on the chainAnnounce backfill path. The chainAnnounce
    /// handler fans out to `fetchAnnouncedParentBranch` (up to
    /// `maxAnnounceBackfillBlocks` network fetches), so an announce flood would
    /// amplify outbound fetch traffic. Held in a `Mutex` (not actor-isolated) so
    /// it can be charged SYNCHRONOUSLY at the nonisolated ingress — before any
    /// task slot is consumed — mirroring `ChainNetwork.chainAnnounceBuckets`.
    private nonisolated let announceBuckets: Mutex<PeerRateBuckets>
    /// Operational tunables threaded from `config.tuning.parentExtractor` at
    /// construction. Stored as a `nonisolated let` so the nonisolated extraction
    /// spawner reads its cap synchronously.
    nonisolated let parentTuning: NodeTuning.ParentExtractor
    nonisolated var inboundCapacity: Double { parentTuning.inboundCapacity }
    nonisolated var inboundRefillPerSec: Double { parentTuning.inboundRefillPerSec }
    nonisolated var maxBucketEntries: Int { parentTuning.maxBucketEntries }

    /// Hard cap on concurrent extraction Tasks. Each inbound parent block /
    /// childBlock / chainAnnounce spawns one unstructured Task that hops onto the
    /// actor; without a cap a flood creates unbounded concurrent Tasks before any
    /// per-peer bucket inside `handle` is reached. Bounded the same way as
    /// ChainNetwork's gossip-task spawner.
    nonisolated let pendingExtractionTasks = Mutex(0)
    nonisolated var maxPendingExtractionTasks: Int { parentTuning.maxPendingExtractionTasks }

    /// Separate, smaller cap for chainAnnounce-handling Tasks, ISOLATED from the
    /// shared extraction pool above. Without this, an announce flood could occupy
    /// all `maxPendingExtractionTasks` slots (each consumed before the per-peer
    /// announce gate runs), starving real parent / `newBlock` / `childBlock`
    /// ingestion that draws from the same pool.
    nonisolated let pendingAnnounceTasks = Mutex(0)
    nonisolated var maxPendingAnnounceTasks: Int { parentTuning.maxPendingAnnounceTasks }

    /// Bound parent-announce backfill. The backfill only makes parent blocks
    /// available to the normal extractor; every block is still PoW/proof/state
    /// validated by `handle`.
    nonisolated var maxAnnounceBackfillBlocks: Int { parentTuning.maxAnnounceBackfillBlocks }
    /// Maximum ancestor walk used to anchor a newly observed parent branch before
    /// ranking it. Unknown branches beyond this bound stay deferred rather than
    /// receiving synthetic baseline work.
    nonisolated var maxParentAncestorBackfill: Int { parentTuning.maxParentAncestorBackfill }
    public init(
        childDirectory: String,
        parentDirectory: String? = nil,
        parentChainPath: [String]? = nil,
        extractor: any ChildBlockExtractor,
        node: LatticeNode,
        tuning: NodeTuning.ParentExtractor = .init()
    ) {
        self.childDirectory = childDirectory
        self.parentDirectory = parentDirectory
        self.parentChainPath = parentChainPath
        self.extractor = extractor
        self.node = node
        self.parentTuning = tuning
        self.inboundBuckets = PeerRateBuckets(
            capacity: tuning.inboundCapacity,
            refillPerSec: tuning.inboundRefillPerSec,
            maxEntries: tuning.maxBucketEntries
        )
        self.announceBuckets = Mutex(PeerRateBuckets(
            capacity: tuning.announceCapacity,
            refillPerSec: tuning.announceRefillPerSec,
            maxEntries: tuning.maxBucketEntries
        ))
    }

    /// Charge the per-peer chainAnnounce bucket. Nonisolated so it runs at the
    /// ingress BEFORE any task slot is consumed: a rate-limited announce neither
    /// amplifies fetches nor occupies an (isolated) announce-task slot.
    private nonisolated func admitAnnounce(from peer: PeerID) -> Bool {
        announceBuckets.withLock { $0.tryConsume(peer) }
    }

    /// Spawn a chainAnnounce-handling Task from the ISOLATED announce pool so an
    /// announce flood can never occupy the shared extraction slots used by real
    /// parent / newBlock / childBlock ingestion. Dropped announces are re-sent.
    private nonisolated func spawnAnnounceTask(_ work: @escaping @Sendable () async -> Void) {
        let accepted = pendingAnnounceTasks.withLock { count -> Bool in
            guard count < maxPendingAnnounceTasks else { return false }
            count += 1
            return true
        }
        guard accepted else { return }
        Task {
            defer { pendingAnnounceTasks.withLock { $0 -= 1 } }
            await work()
        }
    }

    static func acceptsParentChainAnnounce(_ announce: ChainAnnounceData, parentDirectory: String?) -> Bool {
        if let parentDirectory {
            return ChainNetwork.acceptsChainAnnounce(announce, for: parentDirectory)
        }
        return ChainNetwork.acceptsChainAnnounceMetadata(announce)
    }

    static func securingParentAnchors(
        primary: ParentAnchor,
        proofs: [ChildBlockProof]
    ) async -> [ParentAnchor] {
        var anchors: [ParentAnchor] = [primary]
        for proof in proofs {
            guard let anchor = await proof.committingParentAnchor() else { continue }
            anchors.append(anchor)
        }
        var seen = Set<String>()
        return anchors
            .canonicalAnchorSorted()
            .filter { seen.insert($0.blockHash).inserted }
    }

    private func backfillVerifiedParentAncestors(
        startingAt parentCID: String?,
        fetcher: Fetcher,
        node: LatticeNode,
        log: NodeLogger
    ) async {
        guard var cursor = parentCID else { return }
        var chain: [(cid: String, block: Block)] = []
        var seen = Set<String>()

        while !cursor.isEmpty {
            // Terminate on an ancestor whose header edge is already persisted: that
            // CID and everything below it were recorded by a prior backfill or live
            // extraction, so the prevState→postState/header edge chain is already
            // continuous from here down. This replaces the former in-memory
            // parentView "already known" marker now that the projection is gone; the
            // persisted edge is the durable equivalent and is written idempotently
            // (INSERT OR REPLACE) below, so re-walking a known ancestor is harmless.
            if await node.hasVerifiedParentHeaderEdge(directory: childDirectory, blockHash: cursor) { break }
            guard seen.insert(cursor).inserted else {
                log.warn("\(childDirectory): parent ancestry cycle at \(String(cursor.prefix(16)))…; deferring parent-edge backfill")
                return
            }
            guard chain.count < maxParentAncestorBackfill else {
                log.warn("\(childDirectory): parent ancestry for \(String(cursor.prefix(16)))… exceeds backfill cap; deferring parent-edge backfill")
                return
            }
            guard let data = try? await fetcher.fetch(rawCid: cursor),
                  let block = Block(data: data),
                  ChainNetwork.blockCIDMatches(cursor, block: block) else {
                log.warn("\(childDirectory): could not backfill parent ancestor \(String(cursor.prefix(16)))…; deferring parent-edge backfill")
                return
            }

            // A merge-mined ancestor (itself a child) carries nonce=0 and fails standalone
            // PoW; trust one already verified when first relayed (its header edge was
            // recorded only after securing-work verification), else require standalone PoW
            // (valid for a root carrier). A not-yet-verified merge-mined ancestor is
            // deferred rather than falsely rejected on standalone PoW (the depth-3 stall).
            guard await node.hasVerifiedParentHeaderEdge(directory: childDirectory, blockHash: cursor)
                  || block.validateProofOfWork(nexusHash: block.proofOfWorkHash()) else {
                log.warn("\(childDirectory): rejected backfilled parent ancestor \(String(cursor.prefix(16)))…: unverified work; deferring")
                return
            }

            chain.append((cursor, block))
            cursor = block.parent?.rawCID ?? ""
        }

        for (ancestorCID, ancestorBlock) in chain.reversed() {
            let parentCID = ancestorBlock.parent?.rawCID
            await node.persistVerifiedParentHeaderEdge(
                directory: childDirectory,
                anchor: ParentAnchor(
                    blockHash: ancestorCID,
                    parentHash: parentCID,
                    height: ancestorBlock.height
                )
            )
            // Record the prevState→postState edge too, exactly as the live
            // extraction paths do. Backfill is the path that runs when the parent
            // advanced faster than gossip delivered it in order (e.g. a child
            // catching up to a fast parent): persisting only the header edge here
            // while the live path persists BOTH leaves a gap in the parent-state
            // edge chain across the backfilled range, so `hasParentStatePath`
            // fails and the child can never assemble a parent-state-continuous
            // candidate. The backfilled block's PoW is verified above and its CID
            // matches, so its state transition is a verified fact like any other.
            await node.persistVerifiedParentStateEdge(
                directory: childDirectory,
                parentBlock: ancestorBlock
            )
        }
    }

    private func acceptsParentChainAnnounce(_ announce: ChainAnnounceData) -> Bool {
        Self.acceptsParentChainAnnounce(announce, parentDirectory: parentDirectory)
    }

    private func parentIvyFetcher(for ivy: Ivy) -> IvyFetcher {
        let ivyID = ObjectIdentifier(ivy)
        if let parentFetcher, parentFetcher.ivyID == ivyID {
            return parentFetcher.fetcher
        }
        let fetcher = IvyFetcher(ivy: ivy, broker: parentFetcherBroker)
        parentFetcher = (ivyID, fetcher)
        return fetcher
    }

    /// Spawn an extraction Task only if the pending count is below the cap.
    /// Dropped inbound blocks are re-delivered by gossip / the next chainAnnounce,
    /// so dropping under flood is safe and bounds concurrent Tasks.
    private nonisolated func spawnExtractionTask(_ work: @escaping @Sendable () async -> Void) {
        let accepted = pendingExtractionTasks.withLock { count -> Bool in
            guard count < maxPendingExtractionTasks else { return false }
            count += 1
            return true
        }
        guard accepted else { return }
        Task {
            defer { pendingExtractionTasks.withLock { $0 -= 1 } }
            await work()
        }
    }

    // MARK: - IvyDelegate (nonisolated: called from Ivy's context, dispatch to actor)

    public nonisolated func ivy(_ ivy: Ivy, didConnect peer: PeerID) {
        Task { [weak self] in
            guard let self else { return }
            NodeLogger("parent-extractor").info("\(self.childDirectory): connected to parent peer \(String(peer.publicKey.prefix(12)))…")
            await self.maybeBackfillProofsOnConnect(ivy: ivy, from: peer)
        }
    }

    /// On (re)connect to a parent peer, kick the proof self-heal — walking OUR OWN
    /// verified parent chain from the last-known tip (never a peer-announced tip), so
    /// an untrusted peer can neither steer the walk nor feed it unverified blocks.
    private func maybeBackfillProofsOnConnect(ivy: Ivy, from peer: PeerID) async {
        guard !didBackfillChildProofs, !backfillInProgress, node != nil else { return }
        // Let the just-established parent connection warm up (provider records +
        // block-serving handshake) before we pull the parent chain.
        try? await Task.sleep(for: .seconds(8))
        await backfillChildProofsOnce(ivy: ivy, from: peer)
    }

    public nonisolated func ivy(_ ivy: Ivy, didDisconnect peer: PeerID) {
        Task { [weak self] in
            NodeLogger("parent-extractor").info("\(self?.childDirectory ?? "?"): disconnected from parent peer \(String(peer.publicKey.prefix(12)))…")
            await self?.handleParentDisconnect(peer: peer)
        }
    }

    private func handleParentDisconnect(peer: PeerID) async {
        guard let node else { return }
        await node.parentLinkDidDisconnect(directory: childDirectory, peer: peer)
    }

    // the parent link is now a node-managed trusted consensus channel.
    // Forward the authenticated parent identity + its spawn-cert chain to the node
    // so the parent is classified trusted (just like any peer) and the node knows
    // whom to query for inherited weight.
    public nonisolated func ivy(_ ivy: Ivy, didIdentifyPeer realID: PeerID, previous: PeerID) {
        Task { [weak self] in await self?.handleParentIdentify(ivy: ivy, peer: realID) }
    }

    public nonisolated func ivy(_ ivy: Ivy, didReceiveSpawnCertChain peer: PeerID) {
        Task { [weak self] in await self?.handleParentSpawnCertChain(ivy: ivy, peer: peer) }
    }

    private func handleParentIdentify(ivy: Ivy, peer: PeerID) async {
        guard let node else { return }
        await node.parentLinkDidIdentify(directory: childDirectory, ivy: ivy, peer: peer)
    }

    private func handleParentSpawnCertChain(ivy: Ivy, peer: PeerID) async {
        guard let node else { return }
        await node.parentLinkDidReceiveSpawnCertChain(directory: childDirectory, ivy: ivy, peer: peer)
    }

    private func handleParentConsensusResponse(_ payload: Data, from peer: PeerID) async {
        guard let node else { return }
        await node.deliverConsensusResponse(payload, from: peer)
    }

    private func handleParentChildPeerResponse(_ payload: Data, from peer: PeerID) async {
        guard let node else { return }
        await node.deliverChildPeerResponse(payload, from: peer)
    }

    public nonisolated func ivy(_ ivy: Ivy, didReceiveBlock cid: String, data: Data, from peer: PeerID) {
        spawnExtractionTask { [weak self] in await self?.handle(cid: cid, data: data, ivy: ivy, from: peer) }
    }

    // When A sends a chainAnnounce (after B connects), fetch the announced parent
    // block and process it. This handles the case where A is frozen (not actively
    // mining new blocks) but B needs to sync existing blocks.
    public nonisolated func ivy(_ ivy: Ivy, didReceiveMessage message: Message, from peer: PeerID) {
        guard case .peerMessage(let topic, let payload) = message else { return }

        switch topic {
        case ConsensusProvider.responseTopic:
            // the parent answered one of our inherited-weight queries.
            Task { [weak self] in await self?.handleParentConsensusResponse(payload, from: peer) }
        case ChildPeerProvider.responseTopic:
            // the parent answered our same-chain-peer query over this link.
            Task { [weak self] in await self?.handleParentChildPeerResponse(payload, from: peer) }
        case "newBlock":
            guard let decoded = NetworkWireCodecs.parseNewBlockPayload(payload),
                  let blockData = decoded.blockData else { return }
            spawnExtractionTask { [weak self] in await self?.handle(cid: decoded.cid, data: blockData, ivy: ivy, from: peer) }

        case "childBlock":
            // Parent chain relayed this block as "childBlock" with its verified
            // proof envelope. The carrier root hashes are derived from those proofs.
            // F5-4: the inbound proof is root → … → the relayed (parent) block.
            // Keep the bytes opaque here; handle() parses and verifies them before
            // deriving carrier hashes for any child block extracted from this parent.
            guard let decoded = NetworkWireCodecs.parseChildBlockPayload(payload) else { return }
            let proofForTask = decoded.proofData
            spawnExtractionTask { [weak self] in await self?.handle(cid: decoded.cid, data: decoded.blockData, ivy: ivy, from: peer, inboundProofData: proofForTask) }

        case "chainAnnounce":
            guard let announce = ChainAnnounceData.deserialize(payload) else { return }
            // Per-peer rate gate at INGRESS, before any task slot is consumed, so
            // a flood neither amplifies fetches nor occupies slots. The isolated
            // announce pool (spawnAnnounceTask) then keeps announce work off the
            // shared extraction slots used by real parent/newBlock/childBlock work.
            guard admitAnnounce(from: peer) else { return }
            spawnAnnounceTask { [weak self] in
                guard let self else { return }
                guard await self.acceptsParentChainAnnounce(announce) else { return }
                let branch = await self.fetchAnnouncedParentBranch(tipCID: announce.tipCID, ivy: ivy, from: peer)
                for (cid, data, proof) in branch.reversed() {
                    await self.handle(cid: cid, data: data, ivy: ivy, from: peer, inboundProofData: proof)
                }
            }

        case "headerBatch":
            Task { [weak self] in
                await self?.handleHeaderBatchResponse(payload: payload, ivy: ivy, from: peer)
            }

        case "headerBatch2":
            Task { [weak self] in
                await self?.handleHeaderBatchWithProofsResponse(payload: payload, ivy: ivy, from: peer)
            }

        default: break
        }
    }

    // MARK: - Block handling

    /// Fetch the announced parent tip plus unknown ancestors from the announcing
    /// peer. A bare tip announcement can arrive after this child missed the parent
    /// block that actually embedded its child block; walking back to the known
    /// parent view lets the regular extraction path catch up without trusting the
    /// peer for fork choice or validation.
    private func fetchAnnouncedParentBranch(
        tipCID: String,
        ivy: Ivy,
        from peer: PeerID
    ) async -> [(cid: String, data: Data, proof: Data?)] {
        if await requiresInboundParentProof() {
            let batch = await requestParentHeaderBatchWithProofs(
                fromCID: tipCID,
                count: maxAnnounceBackfillBlocks,
                ivy: ivy,
                peer: peer
            )
            var result: [(cid: String, data: Data, proof: Data?)] = []
            for (cid, data, proof) in batch {
                if await node?.hasVerifiedParentHeaderEdge(directory: childDirectory, blockHash: cid) == true { break }
                guard let proof,
                      let block = Block(data: data),
                      ChainNetwork.blockCIDMatches(cid, block: block) else { break }
                result.append((cid, data, proof))
            }
            return result
        }

        let batch = await requestParentHeaderBatch(fromCID: tipCID, count: maxAnnounceBackfillBlocks, ivy: ivy, peer: peer)
        if !batch.isEmpty {
            var result: [(cid: String, data: Data, proof: Data?)] = []
            for (cid, data) in batch {
                if await node?.hasVerifiedParentHeaderEdge(directory: childDirectory, blockHash: cid) == true { break }
                guard let block = Block(data: data),
                      ChainNetwork.blockCIDMatches(cid, block: block) else { break }
                result.append((cid, data, nil))
            }
            if !result.isEmpty { return result }
        }

        var result: [(cid: String, data: Data, proof: Data?)] = []
        var currentCID: String? = tipCID

        for _ in 0..<maxAnnounceBackfillBlocks {
            guard let cid = currentCID, !cid.isEmpty else { break }
            if await node?.hasVerifiedParentHeaderEdge(directory: childDirectory, blockHash: cid) == true { break }

            await ivy.recordProvider(rootCID: cid, peer: peer)
            let data: Data?
            if let direct = await ivy.get(cid: cid, target: peer) {
                data = direct
            } else {
                data = await ivy.fetchVolume(rootCID: cid)[cid]
            }
            guard let data,
                  let block = Block(data: data),
                  ChainNetwork.blockCIDMatches(cid, block: block) else { break }

            result.append((cid: cid, data: data, proof: nil))
            currentCID = block.parent?.rawCID
        }

        return result
    }

    /// Run the proof self-heal at most once per session. Latches `didBackfillChildProofs`
    /// only on a COMPLETED walk, so a transient fetch miss doesn't permanently disable
    /// self-heal — a later connect retries. `backfillInProgress` (check-and-set with no
    /// intervening await) serializes concurrent connect triggers to a single walk.
    private func backfillChildProofsOnce(ivy: Ivy, from peer: PeerID) async {
        guard !didBackfillChildProofs, !backfillInProgress else { return }
        backfillInProgress = true
        let completed = await backfillMissingChildProofs(ivy: ivy, from: peer)
        backfillInProgress = false
        if completed { didBackfillChildProofs = true }
    }

    /// Self-heal (data present ⇒ recover derived state): re-derive and persist every
    /// missing direct-child ChildBlockProof by walking OUR OWN verified parent chain
    /// from the last-known tip. Returns true if the walk completed cleanly (reached the
    /// verified-chain boundary / genesis / a fully-healed run), false if it aborted on a
    /// transient fetch miss (so `backfillChildProofsOnce` won't latch and a later connect
    /// retries). Hardened per adversarial review:
    ///  - LOCAL tip only + `hasVerifiedParentHeaderEdge` gate + stop at the first
    ///    unverified parent: re-derive proofs ONLY for parents this node already
    ///    PoW-verified, never from peer-steerable/unverified data (no amplification vector).
    ///  - Depth-1 only: `generate` yields a single hop; a deeper child's live proof is
    ///    COMPOSED across levels, so re-deriving one hop would persist a wrong-anchored
    ///    proof. Skip non-direct children rather than write invalid proofs.
    ///  - Fold inherited (securing) work in-session (`applyInheritedWeight`) so this node's
    ///    fork choice matches a live-synced node immediately, not only after the next
    ///    restart's `restoreInheritedWeight`.
    ///  - Validate each re-derived proof (`MinedChildBlockSelection.accepts`) before
    ///    persisting, and promote the authoritative union inherited weight from the
    ///    trusted parent (`refreshTrustedInheritedWeight`) so a self-healed node's fork
    ///    choice matches a live-synced node (a child may be secured by multiple parents).
    private func backfillMissingChildProofs(ivy: Ivy, from peer: PeerID) async -> Bool {
        guard let node else { return false }
        // Depth-1 only: a direct child of the PoW root has parentChainPath == [root].
        guard (parentChainPath?.count ?? 0) == 1 else {
            NodeLogger("sync").info("\(childDirectory): proof self-heal skipped — non-direct child (parent depth \(parentChainPath?.count ?? 0)); composed-proof backfill unsupported")
            return true
        }
        guard let tip = await node.highestParentHeaderHash(directory: childDirectory) else { return true }
        let parentIvyFetcher = parentIvyFetcher(for: ivy)
        let childFetcher = await node.network(for: childDirectory)?.ivyFetcher
        let source: any ContentSource = childFetcher.map {
            CompositeContentSource([IvyContentSource($0), IvyContentSource(parentIvyFetcher)])
        } ?? IvyContentSource(parentIvyFetcher)
        let fetcher: Fetcher = CoalescingFetcher(source)

        NodeLogger("sync").info("\(childDirectory): proof self-heal starting from local parent tip \(String(tip.prefix(16)))…")
        var currentCID: String? = tip
        var backfilled = 0, walked = 0, committersRecorded = 0
        var healedChildren = Set<String>()
        for _ in 0..<maxProofBackfillBlocks {
            guard let cid = currentCID, !cid.isEmpty else { break }   // genesis: clean end
            // Only touch parents this node ALREADY PoW-verified; stop at the first
            // unverified parent — the boundary of our vetted chain. This is what kills
            // the attacker-tip vector and bounds the walk to real history.
            guard await node.hasVerifiedParentHeaderEdge(directory: childDirectory, blockHash: cid) else { break }
            guard let data = try? await fetcher.fetch(rawCid: cid),
                  let parentBlock = Block(data: data),
                  ChainNetwork.blockCIDMatches(cid, block: parentBlock),
                  let parentHeader = try? VolumeImpl<Block>(node: parentBlock) else {
                return false   // transient fetch miss: don't latch — retry on a later connect
            }
            walked += 1
            // For EVERY verified committing parent, re-derive the child's single-hop proof
            // and — after validating it exactly as the live path does — RECORD this
            // committer's securing work + anchor. Recording every committer (not just the
            // first the walk reaches) is what makes the union inherited weight promoted
            // below match a live-synced node's for a multiply-committed child. The PROOF is
            // persisted only once per child (one is all getHeaders2 serving needs). No
            // early-stop: a full walk each session is O(verified-chain) once, and stopping
            // early could skip an interior gap.
            if let childDict = try? await parentBlock.children.resolve(
                    paths: [[childDirectory]: .targeted], fetcher: fetcher).node,
               let childHeader: VolumeImpl<Block> = try? childDict.get(key: childDirectory),
               let childBlock = try? await childHeader.resolve(fetcher: fetcher).node,
               let childCID = (try? VolumeImpl<Block>(node: childBlock))?.rawCID,
               let proof = try? await ChildBlockProof.generate(
                   rootHeader: parentHeader, childDirectory: childDirectory, fetcher: fetcher),
               await MinedChildBlockSelection.accepts(
                   chainPath: (parentChainPath ?? []) + [childDirectory], block: childBlock,
                   childCID: childCID, rootHash: parentBlock.proofOfWorkHash(), proof: proof) {
                // Record THIS committer's securing work + anchor (idempotent per committer).
                _ = await node.applyInheritedWeight(
                    directory: childDirectory, blockHash: childCID, proof: proof, source: source)
                committersRecorded += 1
                healedChildren.insert(childCID)
                if !(await node.blockProofExists(directory: childDirectory, blockHash: childCID)) {
                    await node.persistAcceptedBlockProof(
                        directory: childDirectory, height: childBlock.height,
                        blockHash: childCID, proof: proof)
                    backfilled += 1
                }
            }
            currentCID = parentBlock.parent?.rawCID
        }
        // All verified committers are now recorded — promote the AUTHORITATIVE union
        // inherited weight from the trusted parent for each healed child, queried with the
        // FULL committer set, so this node's fork choice matches a live-synced node.
        for childCID in healedChildren {
            await refreshTrustedInheritedWeight(childHash: childCID, node: node)
        }
        NodeLogger("sync").info("\(childDirectory): proof self-heal done — backfilled \(backfilled) proof(s), recorded \(committersRecorded) committer(s) across \(healedChildren.count) child(ren), walked \(walked) parent block(s)")
        return true
    }

    private func requiresInboundParentProof() async -> Bool {
        guard let node,
              let expectedParentPath = await parentProofChainPath(node: node) else { return false }
        return expectedParentPath.count > 1
    }

    /// Draw a 16-byte request ID that collides with no in-flight header
    /// request (either kind). Same discipline as ChainNetwork's
    /// makeUniqueHeaderRequestID: a duplicate ID must never replace a
    /// pending continuation.
    private func makeUniqueHeaderRequestID(
        randomData: @Sendable (Int) -> Data? = { ChainNetwork.secureRandomData(count: $0) }
    ) -> Data? {
        for _ in 0..<16 {
            guard let requestID = randomData(16) else { return nil }
            if pendingHeaderRequests[requestID] == nil,
               pendingHeaderProofRequests[requestID] == nil {
                return requestID
            }
        }
        return nil
    }

    private func requestParentHeaderBatch(
        fromCID: String,
        count: Int,
        ivy: Ivy,
        peer: PeerID
    ) async -> [(cid: String, data: Data)] {
        guard let requestID = makeUniqueHeaderRequestID(),
              let payload = NetworkWireCodecs.encodeHeaderRequest(
                  requestID: requestID,
                  fromCID: fromCID,
                  count: UInt32(min(count, maxAnnounceBackfillBlocks))
              ) else { return [] }

        return await withCheckedContinuation { continuation in
            pendingHeaderRequests[requestID] = PendingHeaderRequest(
                targetPeer: peer,
                resume: { continuation.resume(returning: $0) }
            )
            Task {
                await ivy.sendMessage(to: peer, topic: "getHeaders", payload: payload)
                try? await Task.sleep(for: .seconds(10))
                if let pending = self.removePendingHeaderRequest(requestID) {
                    pending.resume([])
                }
            }
        }
    }

    private func requestParentHeaderBatchWithProofs(
        fromCID: String,
        count: Int,
        ivy: Ivy,
        peer: PeerID
    ) async -> [(cid: String, data: Data, proof: Data?)] {
        guard let requestID = makeUniqueHeaderRequestID(),
              let payload = NetworkWireCodecs.encodeHeaderRequest(
                  requestID: requestID,
                  fromCID: fromCID,
                  count: UInt32(min(count, maxAnnounceBackfillBlocks))
              ) else { return [] }

        return await withCheckedContinuation { continuation in
            pendingHeaderProofRequests[requestID] = PendingHeaderProofRequest(
                targetPeer: peer,
                resume: { continuation.resume(returning: $0) }
            )
            Task {
                await ivy.sendMessage(to: peer, topic: "getHeaders2", payload: payload)
                try? await Task.sleep(for: .seconds(10))
                if let pending = self.removePendingHeaderProofRequest(requestID) {
                    pending.resume([])
                }
            }
        }
    }

    private func removePendingHeaderRequest(_ requestID: Data) -> PendingHeaderRequest? {
        pendingHeaderRequests.removeValue(forKey: requestID)
    }

    private func removePendingHeaderProofRequest(_ requestID: Data) -> PendingHeaderProofRequest? {
        pendingHeaderProofRequests.removeValue(forKey: requestID)
    }

    private func handleHeaderBatchResponse(payload: Data, ivy: Ivy, from peer: PeerID) async {
        guard let requestID = NetworkWireCodecs.headerBatchResponseRequestID(payload) else { return }
        guard let pending = pendingHeaderRequests[requestID] else {
            let tally = await ivy.tally
            tally.recordFailure(peer: peer)
            return
        }
        guard pending.targetPeer == peer else {
            let tally = await ivy.tally
            tally.recordFailure(peer: peer)
            return
        }

        // Canonical fail-closed parse (same discipline as ChainNetwork): a
        // malformed/truncated response, or a declared numHeaders above the
        // bound, drops the WHOLE response (nil → []) — never a
        // silently-truncated prefix.
        let results = NetworkWireCodecs.parseHeaderBatch(payload, maxHeaders: maxAnnounceBackfillBlocks) ?? []
        _ = pendingHeaderRequests.removeValue(forKey: requestID)
        pending.resume(results)
    }

    private func handleHeaderBatchWithProofsResponse(payload: Data, ivy: Ivy, from peer: PeerID) async {
        guard let requestID = NetworkWireCodecs.headerBatchResponseRequestID(payload) else { return }
        guard let pending = pendingHeaderProofRequests[requestID] else {
            let tally = await ivy.tally
            tally.recordFailure(peer: peer)
            return
        }
        guard pending.targetPeer == peer else {
            let tally = await ivy.tally
            tally.recordFailure(peer: peer)
            return
        }

        // Canonical fail-closed parse: a truncated proof-carrying header set
        // must be rejected WHOLE so the syncing child fails closed rather
        // than accepting a short anchored-header prefix.
        let results = NetworkWireCodecs.parseHeaderBatch2(payload, maxHeaders: maxAnnounceBackfillBlocks) ?? []
        _ = pendingHeaderProofRequests.removeValue(forKey: requestID)
        pending.resume(results)
    }

    private func verifiedParentAnchor(
        cid: String,
        parentBlock: Block,
        node: LatticeNode,
        inboundProofs: [ChildBlockProof]
    ) async -> ParentAnchor? {
        guard await parentBlockWorkVerified(cid: cid, parentBlock: parentBlock, node: node, inboundProofs: inboundProofs) else { return nil }
        return ParentAnchor(
            blockHash: cid,
            parentHash: parentBlock.parent?.rawCID,
            height: parentBlock.height,
            prevStateCID: parentBlock.prevState.rawCID
        )
    }

    /// THE single choke point for "is this parent block's WORK verified?" — used before
    /// any fact (continuity edge, inherited work) is derived from a parent block.
    ///
    /// A MERGE-MINED parent (one that is itself a child, i.e. depth ≥ 3 relative to the
    /// PoW root) is built with nonce=0: it does NOT satisfy STANDALONE proof-of-work —
    /// its work is its CARRIER's, proven by a `ChildBlockProof`. So verify work the SAME
    /// way acceptance does: securing-work via the projected proof
    /// (`MinedChildBlockSelection.accepts` against the proof's anchor root), and
    /// standalone PoW ONLY when there is no securing proof (the parent IS the PoW root,
    /// which cleared its own target by construction). Validating a nonce-0 child parent
    /// with `validateProofOfWork(nexusHash: block.proofOfWorkHash())` is a coin-flip
    /// (`target ≥ hash(preimage, nonce=0)`) that falsely rejects legitimate deep
    /// merged-mined parent relays after the target retargets — wedging the grandchild
    /// at height 1 (the depth-3 "deep-child stall"). Identical to the predicate the miner
    /// submission and proof-based extraction already use to ACCEPT these very blocks, so
    /// this is the correct check, not a PoW weakening.
    func parentBlockWorkVerified(cid: String, parentBlock: Block, node: LatticeNode, inboundProofs: [ChildBlockProof]) async -> Bool {
        // STANDALONE first: true iff the parent cleared its OWN target — always the case
        // for the PoW ROOT (Nexus/Bitcoin), and the long-standing admission rule. This must
        // be tried first because a relayed parent block can arrive with CHILD proofs attached
        // (the carrier's children) that don't project to the parent's own path — branching on
        // "has proofs" alone then wrongly sends a ROOT block down the proof branch and rejects
        // it (the depth-2 regression).
        let expectedParentPath = await parentProofChainPath(node: node)
        // (1) CANONICAL ROOT carrier (path count 1) that cleared its OWN target by construction:
        // the common, cheap path for a real Nexus/Bitcoin block. Restricting standalone to the
        // root (defense-in-depth) keeps a forged-target DEEP parent off the continuity index.
        // NB: only ACCEPTS on success now — a root-shaped block that does NOT clear its own
        // target is not necessarily junk; it may be a child-only carrier (2a below).
        if (expectedParentPath?.count ?? 1) == 1,
           parentBlock.validateProofOfWork(nexusHash: parentBlock.proofOfWorkHash()) {
            return true
        }
        guard let expectedParentPath, !inboundProofs.isEmpty else { return false }

        // (2a) ROOT-LEVEL CHILD-ONLY CARRIER (path count 1, standalone failed above): a carrier
        // whose PoW hash did NOT clear the root target. It is a PROOF CARRIER for our child, not
        // a canonical root block ("parent blocks are proof carriers, not fork-choice
        // authorities"). Its work is legitimately zero at the root; validity is per-level:
        // accept iff an inbound proof shows OUR child (childDirectory) cleared THIS carrier's
        // PoW hash — the same predicate `verifiedCommittingParentAnchor` applies to a child that
        // arrives via child-gossip. Resolving the child ONLY from the proof's SEALED entries
        // (never the network) means this adds no availability/trust dependency, and a child-only
        // carrier contributes ZERO inherited parent weight, so accepting it cannot inflate
        // fork-choice work. Without this, a pure parent-stream follower rejects every toy block
        // whose carrier didn't co-clear Nexus (the wedge).
        if expectedParentPath.count == 1 {
            let childPath = expectedParentPath + [childDirectory]
            let carrierHash = parentBlock.proofOfWorkHash()
            for inboundProof in inboundProofs {
                guard let proofForChild = MinedChildBlockSelection.projectedProof(inboundProof, targeting: childPath) else { continue }
                // Sealed, network-free source over the proof's own attacker-supplied-but-
                // content-bound entries — mirrors ChildBlockProof.verify's proofSource().
                let sealed = InMemoryContentSource(Dictionary(
                    inboundProof.entries.map { ($0.cid, $0.data) }, uniquingKeysWith: { first, _ in first }))
                guard let childrenNode = try? await parentBlock.children.resolve(
                          paths: [[childDirectory]: .targeted], fetcher: sealed).node,
                      let childHeader: VolumeImpl<Block> = try? childrenNode.get(key: childDirectory),
                      let childBlock = try? await childHeader.resolve(fetcher: sealed).node else { continue }
                if await MinedChildBlockSelection.accepts(
                    chainPath: childPath, block: childBlock,
                    childCID: childHeader.rawCID, rootHash: carrierHash, proof: proofForChild
                ) {
                    return true
                }
            }
            return false
        }

        // (2b) DEEPER MERGE-MINED parent (path count >= 2, built nonce=0, no standalone work):
        // REQUIRE securing work via a carrier proof. One valid projected proof bound to THIS
        // block (childCID == cid) on THIS chain (expectedParentPath) suffices — identical to the
        // predicate that ACCEPTS these blocks. Without this, a nonce-0 child parent is falsely
        // rejected after the target retargets (the depth-3 deep-child stall).
        for inboundProof in inboundProofs {
            if let proofForParent = MinedChildBlockSelection.projectedProof(inboundProof, targeting: expectedParentPath),
               let root = await proofForParent.anchorRoot(),
               await MinedChildBlockSelection.accepts(
                 chainPath: expectedParentPath, block: parentBlock,
                 childCID: cid, rootHash: root.hash, proof: proofForParent
               ) {
                return true
            }
        }
        return false
    }

    private func verifiedInboundParentProofs(
        cid: String,
        parentBlock: Block,
        node: LatticeNode,
        inboundProofs: [ChildBlockProof]
    ) async -> [ChildBlockProof] {
        guard !inboundProofs.isEmpty,
              let expectedParentPath = await parentProofChainPath(node: node) else { return [] }

        var verified: [ChildBlockProof] = []
        for proof in inboundProofs {
            guard let proofForParent = MinedChildBlockSelection.projectedProof(
                proof,
                targeting: expectedParentPath
            ),
            let root = await proofForParent.anchorRoot(),
                  // Zero inherited work is legitimate (see verifiedParentAnchor); the
                  // union-weight zero-exclusion is handled downstream, not here.
                  await MinedChildBlockSelection.accepts(
                    chainPath: expectedParentPath,
                    block: parentBlock,
                    childCID: cid,
                    rootHash: root.hash,
                    proof: proofForParent
                  ) else { continue }
            verified.append(proof)
        }
        return ChildBlockProofEnvelope.deserialize(ChildBlockProofEnvelope.serialize(verified)) ?? verified
    }

    private func parentProofChainPath(node: LatticeNode) async -> [String]? {
        if let parentChainPath, !parentChainPath.isEmpty {
            return parentChainPath
        }
        guard let parentDirectory,
              let parentNetwork = await node.network(for: parentDirectory) else { return nil }
        return parentNetwork.chainPath
    }

    private func handle(cid: String, data: Data, ivy: Ivy, from peer: PeerID, inboundProofData: Data? = nil) async {
        guard let node = node else { return }
        let log = NodeLogger("parent-extractor")

        // Per-peer rate gate: over-rate inbound parent blocks from one peer are
        // dropped before any verify / extraction work. Re-delivered by gossip.
        guard inboundBuckets.tryConsume(peer) else { return }
        guard let parentBlock = Block(data: data),
              ChainNetwork.blockCIDMatches(cid, block: parentBlock) else { return }

        // Verify the parent block's proof-of-work FIRST — before any processing
        // (content prefetch, child extraction, continuity-edge recording). An
        // invalid-PoW header is not a real parent block: doing no work on it both
        // saves the fetch/extract cost on junk and makes it impossible for any
        // downstream fact (continuity edges, inherited work) to be derived from
        // unverified work. The hash computed here is reused by the proof/no-proof
        // branches below, so this adds no extra cost on the valid path.
        let preGateProofs: [ChildBlockProof] = inboundProofData.flatMap { ChildBlockProofEnvelope.deserialize($0) } ?? []
        guard await parentBlockWorkVerified(cid: cid, parentBlock: parentBlock, node: node, inboundProofs: preGateProofs) else {
            log.warn("\(childDirectory): rejected parent block \(String(cid.prefix(16)))… before processing: invalid work")
            return
        }

        // Record the prevState→postState (and header) continuity edge NOW, from
        // the just-verified header, before the network-bound content prefetch
        // below. Continuity is a header-level fact the parent's PoW attests to —
        // separate from content availability. Gating it behind the per-block
        // prefetch makes the child's continuity index lag a fast parent: the
        // parent mines its next block (and fans out a candidate anchored to that
        // block's state) before the child has recorded the edge for the prior one,
        // so child candidate assembly can never reach the parent's current carrier
        // prevState and the child stalls. Recording it here — at gossip-delivery
        // latency rather than content-fetch latency — lets the child keep pace.
        // This grants no fork-choice weight (inherited work is folded separately,
        // from verified securing proofs); it only lets continuity track the parent.
        await node.persistVerifiedParentStateEdge(directory: childDirectory, parentBlock: parentBlock)
        await node.persistVerifiedParentHeaderEdge(
            directory: childDirectory,
            anchor: ParentAnchor(
                blockHash: cid,
                parentHash: parentBlock.parent?.rawCID,
                height: parentBlock.height,
                prevStateCID: parentBlock.prevState.rawCID
            )
        )

        // Build a fetcher that uses the child's own IvyFetcher (with DiskBroker access)
        // as primary, falling back to the parent subscription Ivy for anything not local.
        // This is needed so TX bodies submitted to the child's mempool can be resolved
        // during block validation (they're in the child's DiskBroker, not the parent Ivy).
        let parentIvyFetcher = parentIvyFetcher(for: ivy)
        let childFetcher = await node.network(for: childDirectory)?.ivyFetcher
        // Byte-identical mirror of the prior per-CID composite (child ivy primary,
        // parent ivy fallback): child ivy (DiskBroker-local) first, then the parent
        // subscription. Both tiers are IvyFetchers, so the native IvyContentSource
        // composition resolves identically AND gains wave-batching.
        let extractionSource: any ContentSource = childFetcher.map {
            CompositeContentSource([IvyContentSource($0), IvyContentSource(parentIvyFetcher)])
        } ?? IvyContentSource(parentIvyFetcher)
        let fetcher: Fetcher = CoalescingFetcher(extractionSource)

        // Backfill any not-yet-recorded parent ancestors before the per-branch
        // persist/extract steps below. This was formerly the first step of the now
        // deleted recordVerifiedParentView; it runs once here so it covers BOTH the
        // no-proof and proof branches, exactly as before. It walks the parent's
        // ancestry and persists each ancestor's verified header + state edge so
        // `hasParentStatePath` succeeds during catch-up when the parent advanced
        // faster than gossip delivered it in order. Guarded on the immediate
        // parent's persisted header edge being absent (the durable equivalent of
        // the old in-memory "already known" marker).
        if let backfillParentCID = parentBlock.parent?.rawCID, !backfillParentCID.isEmpty,
           await node.hasVerifiedParentHeaderEdge(directory: childDirectory, blockHash: backfillParentCID) == false {
            await backfillVerifiedParentAncestors(
                startingAt: backfillParentCID,
                fetcher: fetcher,
                node: node,
                log: log
            )
        }

        let inboundProofs: [ChildBlockProof]
        let parentAnchor: ParentAnchor
        if inboundProofData == nil {
            if await requiresInboundParentProof() {
                log.warn("\(childDirectory): rejected parent relay \(String(cid.prefix(16)))…: missing inbound work proof")
                return
            }
            // PoW already verified at the top of handle(); `rootHash` is reused.
            guard let verifiedAnchor = await verifiedParentAnchor(
                cid: cid,
                parentBlock: parentBlock,
                node: node,
                inboundProofs: []
            ) else {
                log.warn("\(childDirectory): rejected unverified parent header \(String(cid.prefix(16)))…")
                return
            }
            await node.persistVerifiedParentHeaderEdge(directory: childDirectory, anchor: verifiedAnchor)
            await node.persistVerifiedParentStateEdge(directory: childDirectory, parentBlock: parentBlock)
            parentAnchor = verifiedAnchor
            inboundProofs = []
        } else {
            guard let inboundProofData,
                  let parsedProofs = ChildBlockProofEnvelope.deserialize(inboundProofData),
                  !parsedProofs.isEmpty else {
                log.warn("\(childDirectory): rejected parent relay \(String(cid.prefix(16)))…: missing or malformed inbound work proof")
                return
            }
            let verifiedProofs = await verifiedInboundParentProofs(
                cid: cid,
                parentBlock: parentBlock,
                node: node,
                inboundProofs: parsedProofs
            )
            guard !verifiedProofs.isEmpty else {
                // debug, not warn: a well-formed proof that doesn't verify against our
                // parent view is NORMAL operation, not an anomaly — e.g. merge-mining a
                // child on a parent chain this node follows but does not produce (no local
                // committing parent block), or a relay for a parent fork we don't track.
                // The relay is still fail-closed (rejected). Structural/DoS anomalies
                // (oversized / malformed / missing proof bytes) stay at warn above.
                log.debug("\(childDirectory): rejected parent relay \(String(cid.prefix(16)))…: no verified inbound work proof")
                return
            }
            guard let verifiedAnchor = await verifiedParentAnchor(
                cid: cid,
                parentBlock: parentBlock,
                node: node,
                inboundProofs: verifiedProofs
            ) else {
                log.warn("\(childDirectory): rejected unverified parent header \(String(cid.prefix(16)))…")
                return
            }
            var contributionByID: [String: UInt256] = [:]
            for proof in verifiedProofs {
                for contribution in await proof.securingWorkContributions() {
                    if let existing = contributionByID[contribution.id],
                       existing >= contribution.work {
                        continue
                    }
                    contributionByID[contribution.id] = contribution.work
                }
            }
            let contributions = contributionByID
                .map { (id: $0.key, work: $0.value) }
                .sorted { $0.id < $1.id }
            await node.persistVerifiedParentHeaderEdge(directory: childDirectory, anchor: verifiedAnchor)
            await node.persistVerifiedParentStateEdge(directory: childDirectory, parentBlock: parentBlock)
            if let parentDirectory {
                let parentStore = await node.ensureInheritedWeightStore(directory: parentDirectory)
                _ = parentStore.recordVerifiedWorkContributions(contributions, committingChild: cid)
            }
            parentAnchor = verifiedAnchor
            inboundProofs = verifiedProofs
        }

        // Prefetch-before-resolve (whole-object-by-root): the relay carried only
        // the parent block ROOT node, so its `children` trie and the child header
        // leaf are NON-root in-package entries. The serve gate is root-only — a
        // targeted resolve of those inline nodes would issue a standalone non-root
        // wantVolume that no peer answers, dropping real child-securing work. Fetch
        // the owning parent block's whole content closure by ROOT CID first (the
        // peer that relayed this block holds it), so `extract`'s targeted
        // resolution below reads the inline children node from the local CAS. This
        // runs AFTER the header-level continuity work above, which the parent's
        // verified PoW attests to and which needs no content — so continuity never
        // lags a fast parent; only extraction (which inherently needs content)
        // waits, exactly as the gossip-accept and sync paths already do.
        await node.prefetchBlockContentClosure(
            blockHash: cid, ivyFetcher: parentIvyFetcher, localFetcher: fetcher)

        // Extract the child block. The extractor does targeted resolution to find
        // childDirectory in the parent block's children field.
        guard let (childBlock, extractedRootHash) = await extractor.extract(
            childDirectory: childDirectory,
            from: data,
            fetcher: fetcher
        ) else { return }  // Parent block has no block for our chain — normal

        // Core security check: the child block must pass PoW using at least one
        // verified carrier root hash. The selected processing root is chosen from
        // the canonical proof order, never from peer-supplied envelope order.
        let selectedRootHash: UInt256
        if inboundProofs.isEmpty {
            selectedRootHash = extractedRootHash
        } else {
            var validRoots: [(proof: ChildBlockProof, rootHash: UInt256)] = []
            for proof in inboundProofs.sorted(by: { $0.canonicalProofID < $1.canonicalProofID }) {
                guard let root = await proof.anchorRoot(),
                      childBlock.validateProofOfWork(nexusHash: root.hash) else { continue }
                validRoots.append((proof: proof, rootHash: root.hash))
            }
            guard let first = validRoots.first else {
                log.warn("\(childDirectory): block height=\(childBlock.height) fails PoW (no carrier root hash meets child target)")
                return
            }
            selectedRootHash = first.rootHash
        }
        guard childBlock.validateProofOfWork(nexusHash: selectedRootHash) else {
            log.warn("\(childDirectory): block height=\(childBlock.height) fails PoW (no carrier root hash meets child target)")
            return
        }

        guard let network = await node.network(for: childDirectory),
              let childData = childBlock.toData() else { return }

        // known-valid local node; CID cannot fail
        let header = try! VolumeImpl<Block>(node: childBlock)

        // F5-4 (Hierarchical GHOST): build this block's full sparse work proof
        // root → … → our block by extending the inbound proof (root → the parent
        // block we extracted from) with one locally-generated hop (parent → our
        // block). When there's no inbound proof the parent block must itself be the
        // PoW root, so the hop is already root → our block. `verify` against the PoW
        // rootHash and the exact chain path gates both cases — a failure means we
        // relay without a proof (degraded, but the chain keeps moving) rather than
        // propagate a bogus one.
        var fullProofs: [ChildBlockProof] = []
        if let parentBlock = Block(data: data),
           let localHop = try? await ChildBlockProof.generate(
               rootHeader: try! VolumeImpl<Block>(node: parentBlock), childDirectory: childDirectory, fetcher: fetcher) {
            let candidates = inboundProofs.isEmpty
                ? [localHop]
                : inboundProofs + inboundProofs.map { $0.composing(hop: localHop) }
            for candidate in candidates {
                guard let root = await candidate.anchorRoot() else { continue }
                if await MinedChildBlockSelection.accepts(
                    chainPath: network.chainPath,
                    block: childBlock,
                    childCID: header.rawCID,
                    rootHash: root.hash,
                    proof: candidate
                ) {
                    fullProofs.append(candidate)
                }
            }
            if fullProofs.isEmpty {
                log.warn("\(childDirectory): could not compose a valid work proof for \(String(header.rawCID.prefix(16)))… (depth \(network.chainPath.count - 1)); relaying without one")
            }
        }

        let alreadyKnownChild = await node.chain(for: childDirectory)?.contains(blockHash: header.rawCID) ?? false
        if !alreadyKnownChild {
            await preloadExtractedChildSecuringWork(
                childHash: header.rawCID,
                parentAnchor: parentAnchor,
                primaryOwnWork: workForTarget(parentBlock.target),
                fullProofs: fullProofs,
                node: node
            )
        }

        // (lazy consumer): if this child block does NOT extend the
        // current child tip it is DIVERGENT — fork choice will compare it against the
        // main chain, so its inherited weight decides the outcome. Query the TRUSTED
        // parent for the securing anchor's authoritative trueCumWork and promote it
        // into the live index BEFORE the synchronous fork-choice decision below reads
        // it. A linear tip extension needs no query (it wins trivially on its own added
        // work). Best-effort + monotonic: a missing/lower answer never lowers a
        // previously-counted child's inherited weight (the durable floor holds).
        if !alreadyKnownChild, let blockParentCID = childBlock.parent?.rawCID {
            let childTip = await node.chain(for: childDirectory)?.getMainChainTip()
            if blockParentCID != childTip {
                await refreshTrustedInheritedWeight(childHash: header.rawCID, node: node)
            }
        }

        // Prefetch-before-resolve (whole-object-by-root): the parent relay commits
        // only to the child block's ROOT node; its spec + transaction-body volumes
        // are separate whole objects the relaying peer also holds. Fetch that
        // content closure by ROOT CID over the parent relay's IvyFetcher — the same
        // source the block was extracted from — BEFORE durable validation below, so
        // `requireDurableResolvedBlock` resolves the in-package nodes from the local
        // CAS rather than issuing standalone non-root wantVolumes the root-only
        // serve gate refuses. Skip it for a known child: a DUPLICATE short-circuits
        // in processBlockAndRecoverReorg before any content fetch, so prefetching
        // would only stall on content we never resolve. Child internal entries are
        // never fetched individually over the wire; the child root CID is the key.
        if !alreadyKnownChild {
            await node.prefetchBlockContentClosure(
                blockHash: header.rawCID, ivyFetcher: parentIvyFetcher, localFetcher: fetcher)
        }

        let outcome = await node.processBlockAndRecoverReorg(
            header: header,
            directory: childDirectory,
            fetcher: fetcher,
            resolvedBlock: childBlock,
            rootHash: selectedRootHash,
            parentAnchor: parentAnchor,
            requireDurableResolvedBlock: true
        )
        if outcome == .accepted {
            // Store our composed proof as block metadata (serve/push/sync), then
            // relay our block + that proof so the next level down composes one more
            // hop — the same inductive step, to any depth.
            guard await recordExtractedChildSecuringWork(
                childBlock: childBlock,
                childHash: header.rawCID,
                parentAnchor: parentAnchor,
                primaryOwnWork: workForTarget(parentBlock.target),
                fullProofs: fullProofs,
                node: node,
                source: extractionSource
            ) else { return }
            // Relay the composed proof envelope so any nodes subscribed to THIS
            // chain's P2P (e.g. Stable subscribing to Mid) can derive the carrier
            // root hash from the proof and validate recursively.
            await network.relayBlock(cid: header.rawCID, data: childData, rootHash: selectedRootHash, proofs: fullProofs)
            // Headers-first sync is announcement-driven. Parent-extracted child
            // blocks must announce their new tip immediately, otherwise child
            // followers can wait for the periodic reannounce heartbeat.
            await network.broadcastChainAnnounce(
                tipCID: header.rawCID,
                tipHeight: childBlock.height,
                specCID: childBlock.spec.rawCID
            )
            await node.maybePersist(directory: childDirectory)
        } else if outcome == .duplicate {
            // A child block may be secured by additional parent blocks after this
            // node already accepted the child. These are proof facts, not parent
            // canonicity facts: if we persist them for restart/sync, live fork
            // choice must fold the same idempotent contributions immediately so
            // restart cannot change effective work.
            guard await recordExtractedChildSecuringWork(
                childBlock: childBlock,
                childHash: header.rawCID,
                parentAnchor: parentAnchor,
                primaryOwnWork: workForTarget(parentBlock.target),
                fullProofs: fullProofs,
                node: node,
                source: extractionSource
            ) else { return }
        } else if outcome == .storageFailed {
            log.error("\(childDirectory): applied block height=\(childBlock.height) but storage failed; withholding tip publish")
        }
        log.info("\(childDirectory): applied block height=\(childBlock.height) outcome=\(outcome) anchor=\(String(cid.prefix(16)))…")
    }

    /// Back the live fork-choice index with the durable inherited-weight store as
    /// a monotonic floor. The live parent projection is pruned to a bounded
    /// window, so an anchored parent CID can fall out and the projection regress
    /// to zero; the durable store (keyed by child hash, only-grows) ensures the
    /// provider never under-reports a previously-counted child. Idempotent.
    private func ensureDurableInheritedWeightFloor(node: LatticeNode) async {
        let liveIndex = await node.ensureLiveInheritedWeightIndex(directory: childDirectory)
        let store = await node.ensureInheritedWeightStore(directory: childDirectory)
        liveIndex.setDurableFloor(store.makeProvider())
    }

    /// read the faithful Hierarchical-GHOST inherited weight for this
    /// child from the trusted parent — the UNION over ALL parent blocks that commit
    /// it (each grinding block once), which only the parent can compute since only it
    /// has full fork visibility of its committing blocks. The child supplies the
    /// complete committer set it has observed; the parent returns the union; the
    /// child trusts it (TCB) and promotes it into the live index, instead of
    /// re-deriving from its own incomplete relayed-proof view. Only-grows, so a
    /// lower/missing answer can never lower a previously-counted child's weight.
    private func refreshTrustedInheritedWeight(childHash: String, node: LatticeNode) async {
        guard let parentChainPath, !parentChainPath.isEmpty else { return }
        let liveIndex = await node.ensureLiveInheritedWeightIndex(directory: childDirectory)
        let committers = liveIndex.committers(forChild: childHash)
        guard !committers.isEmpty,
              let weight = await node.queryParentWeight(
                  directory: childDirectory, parentChainPath: parentChainPath, committerHashes: committers)
        else { return }
        _ = liveIndex.promoteChildUnionWeight(childHash: childHash, weight: weight)
    }

    private func preloadExtractedChildSecuringWork(
        childHash: String,
        parentAnchor: ParentAnchor,
        primaryOwnWork: UInt256,
        fullProofs: [ChildBlockProof],
        node: LatticeNode
    ) async {
        await ensureDurableInheritedWeightFloor(node: node)
        let anchors = await Self.securingParentAnchors(primary: parentAnchor, proofs: fullProofs)
        let liveIndex = await node.ensureLiveInheritedWeightIndex(directory: childDirectory)
        for anchor in anchors {
            _ = liveIndex.recordParentAnchor(childHash: childHash, parentHash: anchor.blockHash)
        }
        let contributions = await verifiedProofPathContributions(
            primary: parentAnchor,
            primaryOwnWork: primaryOwnWork,
            fullProofs: fullProofs
        )
        await node.preloadInheritedWorkContributions(
            directory: childDirectory,
            blockHash: childHash,
            contributions: contributions
        )
    }

    private func verifiedProofPathContributions(
        primary: ParentAnchor,
        primaryOwnWork: UInt256,
        fullProofs: [ChildBlockProof]
    ) async -> [(id: String, work: UInt256)] {
        var byID: [String: UInt256] = [:]
        for proof in fullProofs {
            for contribution in await proof.securingWorkContributions() {
                let existing = byID[contribution.id] ?? .zero
                if contribution.work > existing {
                    byID[contribution.id] = contribution.work
                }
            }
        }

        // No carried proof contributions (the no-inbound-proof path, where the
        // parent block IS the PoW root): the primary anchor's own work is the
        // parent block's own work, passed in by the caller.
        if byID.isEmpty {
            byID[primary.blockHash] = primaryOwnWork
        }
        return byID
            .map { (id: $0.key, work: $0.value) }
            .sorted { $0.id < $1.id }
    }

    private func persistExtractedChildProofs(
        height: UInt64,
        childHash: String,
        fullProofs: [ChildBlockProof],
        node: LatticeNode
    ) async {
        for fullProof in fullProofs {
            await node.persistAcceptedBlockProof(
                directory: childDirectory,
                height: height,
                blockHash: childHash,
                proof: fullProof
            )
        }
    }

    private func recordExtractedChildSecuringWork(
        childBlock: Block,
        childHash: String,
        parentAnchor: ParentAnchor,
        primaryOwnWork: UInt256,
        fullProofs: [ChildBlockProof],
        node: LatticeNode,
        source: any ContentSource
    ) async -> Bool {
        await persistExtractedChildProofs(
            height: childBlock.height,
            childHash: childHash,
            fullProofs: fullProofs,
            node: node
        )

        await ensureDurableInheritedWeightFloor(node: node)
        let anchors = await Self.securingParentAnchors(primary: parentAnchor, proofs: fullProofs)
        let liveIndex = await node.ensureLiveInheritedWeightIndex(directory: childDirectory)
        for anchor in anchors {
            _ = liveIndex.recordParentAnchor(childHash: childHash, parentHash: anchor.blockHash)
        }
        let contributions = await verifiedProofPathContributions(
            primary: parentAnchor,
            primaryOwnWork: primaryOwnWork,
            fullProofs: fullProofs
        )
        guard await node.applyInheritedWorkContributions(
            directory: childDirectory,
            blockHash: childHash,
            contributions: contributions,
            source: source
        ) else { return false }
        return true
    }

    #if DEBUG
    nonisolated func spawnExtractionTaskForTesting(_ work: @escaping @Sendable () async -> Void) {
        spawnExtractionTask(work)
    }
    nonisolated func pendingExtractionCountForTesting() -> Int {
        pendingExtractionTasks.withLock { $0 }
    }
    func ingestForTesting(cid: String, data: Data, ivy: Ivy, from peer: PeerID) async {
        await handle(cid: cid, data: data, ivy: ivy, from: peer)
    }
    func verifiedInboundParentProofsForTesting(
        cid: String,
        parentBlock: Block,
        node: LatticeNode,
        inboundProofs: [ChildBlockProof]
    ) async -> [ChildBlockProof] {
        await verifiedInboundParentProofs(
            cid: cid, parentBlock: parentBlock, node: node, inboundProofs: inboundProofs)
    }
    func verifiedParentAnchorForTesting(
        cid: String,
        parentBlock: Block,
        node: LatticeNode,
        inboundProofs: [ChildBlockProof]
    ) async -> ParentAnchor? {
        await verifiedParentAnchor(
            cid: cid, parentBlock: parentBlock, node: node, inboundProofs: inboundProofs)
    }
    func registerPendingHeaderRequestForTesting(
        requestID: Data,
        targetPeer: PeerID,
        resume: @escaping @Sendable ([(cid: String, data: Data)]) -> Void
    ) {
        pendingHeaderRequests[requestID] = PendingHeaderRequest(targetPeer: targetPeer, resume: resume)
    }
    func registerPendingHeaderProofRequestForTesting(
        requestID: Data,
        targetPeer: PeerID,
        resume: @escaping @Sendable ([(cid: String, data: Data, proof: Data?)]) -> Void
    ) {
        pendingHeaderProofRequests[requestID] = PendingHeaderProofRequest(targetPeer: targetPeer, resume: resume)
    }
    func handleHeaderBatchResponseForTesting(payload: Data, ivy: Ivy, from peer: PeerID) async {
        await handleHeaderBatchResponse(payload: payload, ivy: ivy, from: peer)
    }
    func handleHeaderBatchWithProofsResponseForTesting(payload: Data, ivy: Ivy, from peer: PeerID) async {
        await handleHeaderBatchWithProofsResponse(payload: payload, ivy: ivy, from: peer)
    }
    func makeUniqueHeaderRequestIDForTesting(
        randomData: @Sendable (Int) -> Data?
    ) -> Data? {
        makeUniqueHeaderRequestID(randomData: randomData)
    }
    #endif

}
