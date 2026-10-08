import Lattice
import cashew
import UInt256

/// A child level's proof bounds: plain caps. A peer whose proof fails
/// proof-of-work is disconnected, so no fairness machinery is needed.
public struct ChildProofConfig: Sendable {
    /// Peers' proof checks in flight at once, and the evidence index's own
    /// allowance beside them (so this node's lookups always progress).
    public var maxChecks: Int
    public var indexChecks: Int
    /// Proofs per source (a peer, or the index) queued or in flight, by
    /// count and by bytes; over either, a proof is dropped without blame.
    public var maxPerSource: Int
    public var maxSourceBytes: Int
    /// Proofs taken from one header, and the largest proof taken at all.
    public var maxPerHeader: Int
    public var maxProofBytes: Int
    /// Headers awaiting their first proof that weighs, at once and per peer.
    public var maxAwaiting: Int
    public var maxAwaitingPerPeer: Int
    /// Blocks the evidence index named that this node does not hold: a
    /// header without proofs is taken only for one of these (or a parent a
    /// waiting header names).
    public var maxWanted: Int

    public init(
        maxChecks: Int = 256,
        indexChecks: Int = 32,
        maxPerSource: Int = 64,
        maxSourceBytes: Int = 1_024 * 1_024,
        maxPerHeader: Int = 8,
        maxProofBytes: Int = 64 * 1_024,
        maxAwaiting: Int = 1_024,
        maxAwaitingPerPeer: Int = 256,
        maxWanted: Int = 4_096
    ) {
        self.maxChecks = maxChecks
        self.indexChecks = indexChecks
        self.maxPerSource = maxPerSource
        self.maxSourceBytes = maxSourceBytes
        self.maxPerHeader = maxPerHeader
        self.maxProofBytes = maxProofBytes
        self.maxAwaiting = maxAwaiting
        self.maxAwaitingPerPeer = maxAwaitingPerPeer
        self.maxWanted = maxWanted
    }
}

/// One proof check, keyed by the block and the proof's CONTENT: two proofs
/// naming one root (a forged twin beside the real one) are two checks.
public struct ChildProofKey: Hashable, Comparable, Sendable {
    public let childCID: String
    public let proofID: String

    public init(childCID: String, proofID: String) {
        self.childCID = childCID
        self.proofID = proofID
    }

    public static func < (lhs: ChildProofKey, rhs: ChildProofKey) -> Bool {
        lhs.childCID != rhs.childCID ? lhs.childCID < rhs.childCID : lhs.proofID < rhs.proofID
    }
}

/// A proof not yet checked or in flight: for a block, from a source (nil:
/// the evidence index), with its serialized size.
public struct QueuedChildProof: Sendable {
    public let cid: String
    public let proof: ChildBlockProof
    public let id: String
    public let source: PeerID?
    public let bytes: Int

    public var key: ChildProofKey { ChildProofKey(childCID: cid, proofID: id) }
}

/// One proof check the shell runs off the step: `verifySecuringWork` of
/// `proof` for the block on the level's chain. Pure over its inputs, so its
/// answer is never stale. `block` is nil for a weighed block: the shell
/// reads it from its store, as it does to serve it.
public struct ChildProofJob: Sendable {
    public let childCID: String
    public let block: Block?
    public let proof: ChildBlockProof
    public let proofID: String
    public let chainPath: [String]

    public var key: ChildProofKey { ChildProofKey(childCID: childCID, proofID: proofID) }

    public func run(_ block: Block) async -> Result<VerifiedChildEvidence, ChildProofVerificationFailure> {
        await proof.verifySecuringWork(child: block, chainPath: chainPath)
    }

    /// A proof's content identity: the hash of its canonical bytes.
    public static func id(of proof: ChildBlockProof) -> String? {
        guard let bytes = try? proof.serialize() else { return nil }
        return "\(UInt256.hash(bytes))"
    }
}

/// A child header awaiting its first proof that weighs. It lives apart from
/// the pending queue (which holds only headers with verified work), bounded
/// by count and per peer; an entry with a check in flight is never evicted.
public struct AwaitingChildProof: Sendable {
    public let blockCID: String
    public let block: Block
    public internal(set) var children: FlatDictionary<BlockHeader>?
    /// A genesis's spec, as its first announcer sent it.
    public internal(set) var spec: ChainSpec?
    public internal(set) var announcers: [PeerID]
    /// Whether its proofs were looked up since the evidence index changed.
    public internal(set) var lookedUp = false
    let sequence: UInt64

    var source: PeerID? { announcers.first }
}

/// A child level's proof work: one FIFO of unchecked proofs, the checks in
/// flight, and each source's load (queued plus in flight).
public struct ChildProofSync: Sendable {
    public internal(set) var awaiting: [String: AwaitingChildProof] = [:]
    public internal(set) var queued: [QueuedChildProof] = []
    public internal(set) var verifying: [ChildProofKey: QueuedChildProof] = [:]
    public internal(set) var load: [PeerID?: (count: Int, bytes: Int)] = [:]
    /// Weighed blocks to look up in the evidence index again.
    var relookup: Set<String> = []
    var wanted: Set<String> = []
    var wantedOrder: [String] = []
    var sequence: UInt64 = 0

    public init() {}

    public func checks(index: Bool) -> Int {
        verifying.values.filter { ($0.source == nil) == index }.count
    }

    func holds(_ cid: String) -> Bool {
        queued.contains { $0.cid == cid } || verifying.keys.contains { $0.childCID == cid }
    }

    mutating func charge(_ proof: QueuedChildProof, _ sign: Int) {
        let held = load[proof.source] ?? (0, 0)
        let next = (count: held.count + sign, bytes: held.bytes + sign * proof.bytes)
        load[proof.source] = next.count == 0 ? nil : next
    }

    /// Forget everything `peer` sent, queued or in flight. A check still
    /// running in the shell answers into nothing.
    mutating func purge(_ peer: PeerID) {
        queued.removeAll { $0.source == peer }
        for (key, proof) in verifying where proof.source == peer { verifying[key] = nil }
        load[peer] = nil
    }

    mutating func want(_ cid: String, _ config: ChildProofConfig) {
        guard wanted.insert(cid).inserted else { return }
        wantedOrder.append(cid)
        while wantedOrder.count > config.maxWanted {
            wanted.remove(wantedOrder.removeFirst())
        }
    }
}

/// A child level's header is its block and a `ChildBlockProof` per root that
/// carries it. It waits in `awaitingProof` until one proof verifies and
/// weighs, then enters the pending queue (prioritised by that root's hash)
/// and is weighed by `insertChildHeader`; every other root is credited with
/// `addWork`. Blame only when proof-of-work fails: a proof a peer sent that
/// fails `verifySecuringWork` (malformed, or no work for that block)
/// disconnects the peer, which honest peers never risk, since they relay
/// only proofs they verified; the evidence index's proofs are not
/// attributable and blame no one. A missing proof is a liveness wait,
/// looked up in the evidence index again when it changes.
extension ChainCore {
    var isRoot: Bool { tree.context?.isRoot ?? true }

    var chainPath: [String] { tree.context?.path ?? [] }

    var proofConfig: ChildProofConfig { config.proofs }

    /// A genesis's spec only when it is the one the block names: a wrong
    /// one from a peer is dropped, so the next announcer's can be held.
    static func bound(_ spec: ChainSpec?, by block: Block) -> ChainSpec? {
        guard let spec, block.parent == nil, (try? VolumeImpl<ChainSpec>(node: spec).rawCID) == block.spec.rawCID else { return nil }
        return spec
    }

    // MARK: - Taking proofs

    /// A child header nobody weighed yet: it waits for a proof. A header with
    /// no proofs is taken only when wanted (the evidence index named it, or
    /// a waiting header names it as parent); otherwise it is dropped, so
    /// strangers cannot spend this node's lookups.
    mutating func awaitProof(_ entry: HeaderEntry, cid: String, from peer: PeerID, _ turn: inout Turn) {
        if var held = sync.proofs.awaiting[cid] {
            if !held.announcers.contains(peer) { held.announcers.append(peer) }
            if held.children == nil, let children = entry.children { held.children = children }
            if held.spec == nil { held.spec = Self.bound(entry.spec, by: entry.block) }
            sync.proofs.awaiting[cid] = held
            offer(entry.proofs, cid: cid, from: peer)
            return
        }
        let wanted = sync.proofs.wanted.contains(cid) || sync.pending.childrenOf[cid] != nil
            || sync.proofs.awaiting.values.contains { $0.block.parent?.rawCID == cid }
        guard !entry.proofs.isEmpty || wanted else { return }
        let fromPeer = sync.proofs.awaiting.values.filter { $0.source == peer }.count
        guard fromPeer < proofConfig.maxAwaitingPerPeer, makeRoomToAwait() else { return }
        sync.proofs.sequence += 1
        sync.proofs.awaiting[cid] = AwaitingChildProof(
            blockCID: cid, block: entry.block, children: entry.children, spec: Self.bound(entry.spec, by: entry.block),
            announcers: [peer], sequence: sync.proofs.sequence
        )
        sync.proofs.wanted.remove(cid)
        offer(entry.proofs, cid: cid, from: peer)
    }

    /// The proof-bearing headers `peer` can be asked for now: its free proof
    /// slots, by the cap `offer` holds it to. A peer with no check queued or
    /// in flight always has room, so asking never stops for good. A root
    /// header carries no proofs: no bound.
    func proofRoom(for peer: PeerID) -> Int {
        guard !isRoot else { return .max }
        return Swift.max(0, proofConfig.maxPerSource - (sync.proofs.load[peer]?.count ?? 0))
    }

    /// Room for one more waiting header: evict the oldest with no proof
    /// queued or in flight, or refuse.
    mutating func makeRoomToAwait() -> Bool {
        guard sync.proofs.awaiting.count >= proofConfig.maxAwaiting else { return true }
        guard let victim = sync.proofs.awaiting.values
            .filter({ !sync.proofs.holds($0.blockCID) })
            .min(by: { $0.sequence < $1.sequence }) else { return false }
        sync.proofs.awaiting[victim.blockCID] = nil
        return true
    }

    /// Queue each new proof (by content) of a waiting, pending or weighed
    /// header, up to `maxPerHeader` from one header, if it fits its source's
    /// caps; otherwise it is dropped without blame and the block is looked
    /// up again later. Checks start in `proofWork`.
    mutating func offer(_ proofs: [ChildBlockProof], cid: String, from source: PeerID?) {
        // Grinds not yet credited first, so a header served again with the
        // same proofs offers the ones a cap left out.
        var fresh: [ChildBlockProof] = []
        for proof in proofs where !credits(proof.rootCID, at: cid) { fresh.append(proof) }
        for proof in fresh.prefix(proofConfig.maxPerHeader) {
            guard let bytes = try? proof.serialize(), bytes.count <= proofConfig.maxProofBytes else { continue }
            let id = "\(UInt256.hash(bytes))"
            let queued = QueuedChildProof(cid: cid, proof: proof, id: id, source: source, bytes: bytes.count)
            guard sync.proofs.verifying[queued.key] == nil,
                  !sync.proofs.queued.contains(where: { $0.key == queued.key }),
                  !credits(proof.rootCID, at: cid) else { continue }
            let load = sync.proofs.load[source] ?? (0, 0)
            guard load.count < proofConfig.maxPerSource,
                  load.bytes + queued.bytes <= proofConfig.maxSourceBytes else {
                skipped(cid)
                continue
            }
            sync.proofs.queued.append(queued)
            sync.proofs.charge(queued, 1)
        }
    }

    /// A proof this node could not keep: look the block up again later.
    mutating func skipped(_ cid: String) {
        if sync.proofs.awaiting[cid] != nil {
            sync.proofs.awaiting[cid]?.lookedUp = false
        } else if sync.pending.entries[cid] != nil || index.contains(cid) {
            sync.proofs.relookup.insert(cid)
        }
    }

    mutating func credits(_ grind: String, at cid: String) -> Bool {
        sync.pending.entries[cid]?.evidence[grind] != nil
            || (index.contains(cid) && tree.workContribution(id: grind, at: cid) != nil)
    }

    /// The evidence index's proofs for a block.
    mutating func proofsFound(_ proofs: [ChildBlockProof], for cid: String, _ turn: inout Turn) {
        guard sync.proofs.awaiting[cid] != nil || sync.pending.entries[cid] != nil || index.contains(cid) else { return }
        offer(proofs, cid: cid, from: nil)
    }

    mutating func evidenceChanged(_ cids: [String]) {
        for cid in Set(cids).sorted() {
            if sync.proofs.awaiting[cid] != nil {
                sync.proofs.awaiting[cid]?.lookedUp = false
            } else if sync.pending.entries[cid] != nil || index.contains(cid) {
                sync.proofs.relookup.insert(cid)
            } else {
                sync.proofs.want(cid, proofConfig)
            }
        }
    }

    /// A peer is gone (for any reason): its announcements end, and its
    /// proofs, queued or in flight, are forgotten.
    mutating func dropProofSource(_ peer: PeerID) {
        for cid in sync.proofs.awaiting.keys.sorted() {
            sync.proofs.awaiting[cid]?.announcers.removeAll { $0 == peer }
        }
        sync.proofs.purge(peer)
    }

    // MARK: - Results

    /// A proof that weighs credits its grind: at a weighed block at once
    /// (persisted, indexed, relayed), on a pending header when it is weighed,
    /// and a waiting header enters the pending queue with it. A proof that
    /// fails — malformed, or no work for this block — is a proof-of-work
    /// failure: the peer that sent it is disconnected; the index's blame no
    /// one.
    mutating func proofVerified(
        _ job: ChildProofJob,
        _ result: Result<VerifiedChildEvidence, ChildProofVerificationFailure>,
        _ turn: inout Turn
    ) {
        guard let checked = sync.proofs.verifying.removeValue(forKey: job.key) else { return }
        sync.proofs.charge(checked, -1)
        let cid = job.childCID
        guard case .success(let evidence) = result, evidence.childCID == cid,
              let work = evidence.contribution, work.work > .zero else {
            if let peer = checked.source { disconnect(peer, .proofOfWorkInvalid, &turn) }
            if sync.proofs.awaiting[cid] != nil, !sync.proofs.holds(cid) {
                sync.proofs.awaiting[cid]?.lookedUp = false
            }
            return
        }
        if index.contains(cid) {
            guard case .applied(let update) = tree.addWork(work, to: cid) else { return }
            turn.facts += update.batches
            weighed += update.weighed
            turn.indexed.append((cid, job.proof))
        } else if let held = sync.pending.entries[cid] {
            guard held.evidence[evidence.grindID] == nil else { return }
            sync.pending.entries[cid]?.evidence[evidence.grindID] = evidence
            sync.pending.entries[cid]?.proofs[evidence.grindID] = job.proof
        } else if let waiting = sync.proofs.awaiting.removeValue(forKey: cid) {
            promote(waiting, evidence: evidence, proof: job.proof, &turn)
        }
    }

    /// A waiting header has verified work: it enters the pending queue, at
    /// its root's achieved hash, as `accept` enters a root header, and is
    /// weighed at once when its parent is.
    mutating func promote(_ waiting: AwaitingChildProof, evidence: VerifiedChildEvidence, proof: ChildBlockProof, _ turn: inout Turn) {
        let cid = waiting.blockCID
        var header = PendingHeader(
            blockCID: cid,
            block: waiting.block,
            children: waiting.children,
            spec: waiting.spec,
            hash: evidence.rootHash,
            bytes: Self.size(of: waiting.block) + (waiting.children.map(Self.size) ?? 0)
                + ((try? proof.serialize().count) ?? 0),
            announcers: waiting.announcers
        )
        header.evidence[evidence.grindID] = evidence
        header.proofs[evidence.grindID] = proof
        sync.pending.insert(header)
        for peer in waiting.announcers { sync.announced[peer, default: []].insert(cid) }
        dirty(cid, &turn)
        sync.evict(to: config.pendingBudget)
    }

    // MARK: - Each step

    /// Start queued checks in arrival order while slots are free (peers'
    /// and the index's apart), dropping proofs whose block is gone or
    /// already credited by that root; then ask the evidence index in one
    /// batch: for every child header weighed this step (another host's
    /// grinds), every waiting header with no proof queued or in flight, and
    /// every weighed block queued for another lookup.
    mutating func proofWork(_ turn: inout Turn) {
        var peerChecks = sync.proofs.checks(index: false)
        var indexChecks = sync.proofs.checks(index: true)
        var kept: [QueuedChildProof] = []
        for proof in sync.proofs.queued {
            let known = sync.proofs.awaiting[proof.cid] != nil || sync.pending.entries[proof.cid] != nil
                || index.contains(proof.cid)
            guard known, !credits(proof.proof.rootCID, at: proof.cid) else {
                sync.proofs.charge(proof, -1)
                continue
            }
            let free = proof.source == nil ? indexChecks < proofConfig.indexChecks : peerChecks < proofConfig.maxChecks
            guard free else {
                kept.append(proof)
                continue
            }
            if proof.source == nil { indexChecks += 1 } else { peerChecks += 1 }
            sync.proofs.verifying[proof.key] = proof
            turn.effects.append(.verifyProof(ChildProofJob(
                childCID: proof.cid,
                block: sync.proofs.awaiting[proof.cid]?.block ?? sync.pending.entries[proof.cid]?.block,
                proof: proof.proof, proofID: proof.id, chainPath: chainPath
            )))
        }
        sync.proofs.queued = kept
        var wanted = Set(turn.headers.map(\.blockCID))
        for (cid, held) in sync.proofs.awaiting where !held.lookedUp && !sync.proofs.holds(cid) {
            sync.proofs.awaiting[cid]?.lookedUp = true
            wanted.insert(cid)
        }
        wanted.formUnion(sync.proofs.relookup)
        sync.proofs.relookup = []
        if !wanted.isEmpty { turn.effects.append(.lookupProofs(wanted.sorted())) }
    }

    // MARK: - Weighing

    /// Weigh a pending child header with its smallest-hash grind: a genesis
    /// as a root, with the spec it came with.
    mutating func insertChildHeader(
        _ header: PendingHeader,
        children: FlatDictionary<BlockHeader>,
        _ context: ValidationContext
    ) -> ChainTreeAdmission {
        guard let first = header.evidence.values.min(by: {
            $0.rootHash != $1.rootHash ? $0.rootHash < $1.rootHash : $0.grindID < $1.grindID
        }) else { return .rejected(.unavailableEvidence) }
        guard header.parent != nil else {
            guard let spec = header.spec else { return .rejected(.unavailableEvidence) }
            return tree.insertGenesis(header.block, spec: spec, childIndex: children, evidence: first)
        }
        return tree.insertChildHeader(
            header.block, childIndex: children, evidence: first, validationContext: context
        )
    }

    /// Credit a newly weighed child header's other grinds, one per root, and
    /// return every proof it now weighs by, to index and log. Its queued
    /// proofs are checked later against the weighed block.
    @discardableResult
    mutating func creditRemainingProofs(of header: PendingHeader, _ turn: inout Turn) -> [ChildBlockProof] {
        guard !isRoot else { return [] }
        var credited: [ChildBlockProof] = []
        for (root, evidence) in header.evidence.sorted(by: { $0.key < $1.key }) {
            guard let work = evidence.contribution, let proof = header.proofs[root] else { continue }
            if tree.workContribution(id: root, at: header.blockCID) == nil {
                guard case .applied(let update) = tree.addWork(work, to: header.blockCID) else { continue }
                turn.facts += update.batches
                weighed += update.weighed
            }
            credited.append(proof)
            turn.indexed.append((header.blockCID, proof))
        }
        return credited
    }

    // MARK: - Local and cross-level inputs

    /// Weigh this node's own grind at this level, blaming no one: a root
    /// block by its own work, a child block by the grind's verified proof (a
    /// child genesis as a root, with the spec it was built with). Part of
    /// one mined handoff, whose levels persist as one batch.
    mutating func weighOwn(
        _ block: Block,
        children: FlatDictionary<BlockHeader>,
        proof: (proof: ChildBlockProof, evidence: VerifiedChildEvidence)?,
        now: Int64
    ) -> [ChainEffect] {
        var turn = Turn(now: now)
        weighed = []
        guard let cid = try? BlockHeader(node: block).rawCID else { return [] }
        let context = ValidationContext(nowMilliseconds: now)
        let held = index.contains(cid)
        let admission: ChainTreeAdmission
        if isRoot {
            admission = tree.insertRootHeader(block, childIndex: children, validationContext: context)
        } else {
            guard let proof, proof.evidence.childCID == cid,
                  let work = proof.evidence.contribution, work.work > .zero else { return [] }
            if held {
                admission = tree.addWork(work, to: cid)
            } else if block.parent == nil {
                guard let spec = block.spec.node else { return [] }
                admission = tree.insertGenesis(block, spec: spec, childIndex: children, evidence: proof.evidence)
            } else {
                admission = tree.insertChildHeader(
                    block, childIndex: children, evidence: proof.evidence, validationContext: context
                )
            }
        }
        guard case .applied(let update) = admission else { return [] }
        weighed += update.weighed
        if !held {
            let waiting = sync.pending.childrenOf[cid] ?? []
            sync.removePending(cid)
            sync.proofs.awaiting[cid] = nil
            turn.headers.append(StoredHeader(
                blockCID: cid, block: block, children: children, spec: block.parent == nil ? block.spec.node : nil
            ))
            index.add(cid, parent: block.parent?.rawCID, height: block.height)
            for child in waiting { dirty(child, &turn) }
        }
        turn.facts += update.batches
        if let proof { turn.indexed.append((cid, proof.proof)) }
        drain(&turn)
        if !isRoot { proofWork(&turn) }
        return finish(turn)
    }

    /// Credit this level with its parent's attributed runs (hierarchical
    /// GHOST) that the host's forwarded blocks can have moved: derived, never
    /// persisted. Returns the blocks it raised, to forward a level down, and
    /// the step's effects when any were.
    mutating func applyParentRun(
        from parent: ChainTree,
        parentBlocks: Set<String>,
        held: Set<String>,
        now: Int64
    ) -> (raised: [String], effects: [ChainEffect]) {
        let raised = tree.applyParentRun(
            from: parent, directory: chainPath[chainPath.count - 1], parentBlocks: parentBlocks, held: held
        ).raised
        guard !raised.isEmpty else { return ([], []) }
        return (raised, finish(Turn(now: now)))
    }
}
