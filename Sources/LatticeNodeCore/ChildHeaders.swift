import Lattice
import UInt256

/// A child level's proof bounds.
public struct ProofConfig: Sendable {
    /// Proof checks in flight at once, and per source (a peer, or the
    /// evidence index), so no source can hold every slot.
    public var maxChecks: Int
    public var maxChecksPerSource: Int
    /// Proofs taken from, or held for, one header.
    public var maxPerHeader: Int
    /// Headers awaiting their first proof that weighs, at once and per peer.
    public var maxAwaiting: Int
    public var maxAwaitingPerPeer: Int
    /// Blocks the evidence index named that this node does not hold: a
    /// header without proofs is taken only for one of these (or a parent a
    /// waiting header names).
    public var maxWanted: Int

    public init(
        maxChecks: Int = 256,
        maxChecksPerSource: Int = 64,
        maxPerHeader: Int = 8,
        maxAwaiting: Int = 1_024,
        maxAwaitingPerPeer: Int = 256,
        maxWanted: Int = 4_096
    ) {
        self.maxChecks = maxChecks
        self.maxChecksPerSource = maxChecksPerSource
        self.maxPerHeader = maxPerHeader
        self.maxAwaiting = maxAwaiting
        self.maxAwaitingPerPeer = maxAwaitingPerPeer
        self.maxWanted = maxWanted
    }
}

/// One proof check, keyed by the block and the proof's CONTENT: two proofs
/// naming one root (a forged twin beside the real one) are two checks.
public struct ProofKey: Hashable, Comparable, Sendable {
    public let childCID: String
    public let proofID: String

    public init(childCID: String, proofID: String) {
        self.childCID = childCID
        self.proofID = proofID
    }

    public static func < (lhs: ProofKey, rhs: ProofKey) -> Bool {
        lhs.childCID != rhs.childCID ? lhs.childCID < rhs.childCID : lhs.proofID < rhs.proofID
    }
}

/// A proof not yet checked, and where it came from (nil: the evidence index).
public struct QueuedProof: Sendable {
    public let proof: ChildBlockProof
    public let id: String
    public let source: PeerID?
}

/// One proof check the shell runs off the step: `verifySecuringWork` of
/// `proof` for the block on the level's chain. Pure over its inputs, so its
/// answer is never stale. `block` is nil for a weighed block: the shell
/// reads it from its store, as it does to serve it.
public struct ProofJob: Sendable {
    public let childCID: String
    public let block: Block?
    public let proof: ChildBlockProof
    public let proofID: String
    public let chainPath: [String]

    public var key: ProofKey { ProofKey(childCID: childCID, proofID: proofID) }

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
public struct AwaitingProof: Sendable {
    public let blockCID: String
    public let block: Block
    public internal(set) var children: ChildIndex?
    public internal(set) var announcers: [PeerID]
    public internal(set) var unverified: [QueuedProof] = []
    public internal(set) var inFlight: Set<String> = []
    /// Whether its proofs were looked up since the evidence index changed.
    public internal(set) var lookedUp = false
    let sequence: UInt64
}

/// A child level's proof work.
public struct ProofSync: Sendable {
    public internal(set) var awaiting: [String: AwaitingProof] = [:]
    /// Checks in flight, and the source each is charged to.
    public internal(set) var verifying: [ProofKey: PeerID?] = [:]
    var perSource: [PeerID?: Int] = [:]
    /// Blocks with queued, unchecked proofs.
    var queued: Set<String> = []
    /// Weighed blocks to look up in the evidence index again.
    var relookup: Set<String> = []
    var wanted: Set<String> = []
    var wantedOrder: [String] = []
    var sequence: UInt64 = 0

    public init() {}

    func hasSlot(for source: PeerID?, _ config: ProofConfig) -> Bool {
        verifying.count < config.maxChecks && (perSource[source] ?? 0) < config.maxChecksPerSource
    }

    mutating func want(_ cid: String, _ config: ProofConfig) {
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
/// `addWork`. A proof that does not weigh blames no one; a missing proof is
/// a liveness wait, looked up in the evidence index again when it changes.
extension Core {
    var isRoot: Bool { tree.context?.isRoot ?? true }

    var chainPath: [String] { tree.context?.path ?? [] }

    var proofConfig: ProofConfig { config.proofs }

    // MARK: - Taking proofs

    /// A child header nobody weighed yet: it waits for a proof. A header with
    /// no proofs is taken only when wanted (the evidence index named it, or
    /// a waiting header names it as parent); otherwise it is dropped, so
    /// strangers cannot spend this node's lookups.
    mutating func awaitProof(_ entry: HeaderEntry, cid: String, from peer: PeerID, _ turn: inout Turn) {
        if var held = sync.proofs.awaiting[cid] {
            if !held.announcers.contains(peer) { held.announcers.append(peer) }
            if held.children == nil, let children = entry.children { held.children = children }
            sync.proofs.awaiting[cid] = held
            offer(entry.proofs, for: entry.block, cid: cid, from: peer, &turn)
            return
        }
        let wanted = sync.proofs.wanted.contains(cid) || sync.pending.childrenOf[cid] != nil
            || sync.proofs.awaiting.values.contains { $0.block.parent?.rawCID == cid }
        guard !entry.proofs.isEmpty || wanted else { return }
        let fromPeer = sync.proofs.awaiting.values.filter { $0.announcers.first == peer }.count
        guard fromPeer < proofConfig.maxAwaitingPerPeer, makeRoomToAwait() else { return }
        sync.proofs.sequence += 1
        sync.proofs.awaiting[cid] = AwaitingProof(
            blockCID: cid, block: entry.block, children: entry.children,
            announcers: [peer], sequence: sync.proofs.sequence
        )
        sync.proofs.wanted.remove(cid)
        offer(entry.proofs, for: entry.block, cid: cid, from: peer, &turn)
    }

    /// Room for one more waiting header: evict the oldest with no check in
    /// flight, or refuse.
    mutating func makeRoomToAwait() -> Bool {
        guard sync.proofs.awaiting.count >= proofConfig.maxAwaiting else { return true }
        guard let victim = sync.proofs.awaiting.values
            .filter({ $0.inFlight.isEmpty })
            .min(by: { $0.sequence < $1.sequence }) else { return false }
        sync.proofs.awaiting[victim.blockCID] = nil
        sync.proofs.queued.remove(victim.blockCID)
        return true
    }

    /// Check each new proof (by content) of a waiting, pending or weighed
    /// header now if a slot is free for its source, else queue it with the
    /// header (up to `maxPerHeader`). A proof that cannot be kept clears the
    /// header's lookup, or queues a weighed block for another, so it is
    /// found again later.
    mutating func offer(_ proofs: [ChildBlockProof], for block: Block?, cid: String, from source: PeerID?, _ turn: inout Turn) {
        for proof in proofs.prefix(proofConfig.maxPerHeader) {
            guard let id = ProofJob.id(of: proof) else { continue }
            let key = ProofKey(childCID: cid, proofID: id)
            guard sync.proofs.verifying[key] == nil, !isQueued(id, at: cid), !credits(proof.rootCID, at: cid) else { continue }
            if sync.proofs.hasSlot(for: source, proofConfig) {
                dispatch(QueuedProof(proof: proof, id: id, source: source), cid: cid, block: block, &turn)
            } else if !queue(QueuedProof(proof: proof, id: id, source: source), at: cid) {
                skipped(cid)
            }
        }
    }

    func isQueued(_ id: String, at cid: String) -> Bool {
        (sync.proofs.awaiting[cid]?.unverified ?? sync.pending.entries[cid]?.unverified ?? [])
            .contains { $0.id == id }
    }

    mutating func queue(_ proof: QueuedProof, at cid: String) -> Bool {
        if var held = sync.proofs.awaiting[cid], held.unverified.count < proofConfig.maxPerHeader {
            held.unverified.append(proof)
            sync.proofs.awaiting[cid] = held
        } else if let held = sync.pending.entries[cid], held.unverified.count < proofConfig.maxPerHeader {
            sync.pending.entries[cid]?.unverified.append(proof)
        } else {
            return false
        }
        sync.proofs.queued.insert(cid)
        return true
    }

    /// A proof this node could not keep: look the block up again later.
    mutating func skipped(_ cid: String) {
        if sync.proofs.awaiting[cid] != nil {
            sync.proofs.awaiting[cid]?.lookedUp = false
        } else if sync.pending.entries[cid] != nil || index.contains(cid) {
            sync.proofs.relookup.insert(cid)
        }
    }

    mutating func dispatch(_ queued: QueuedProof, cid: String, block: Block?, _ turn: inout Turn) {
        let job = ProofJob(
            childCID: cid,
            block: block ?? sync.proofs.awaiting[cid]?.block ?? sync.pending.entries[cid]?.block,
            proof: queued.proof, proofID: queued.id, chainPath: chainPath
        )
        sync.proofs.verifying[job.key] = .some(queued.source)
        sync.proofs.perSource[queued.source, default: 0] += 1
        sync.proofs.awaiting[cid]?.inFlight.insert(queued.id)
        turn.effects.append(.verifyProof(job))
    }

    mutating func credits(_ grind: String, at cid: String) -> Bool {
        sync.pending.entries[cid]?.evidence[grind] != nil
            || (index.contains(cid) && tree.getConsensusBlock(hash: cid)?.workContributions[grind] != nil)
    }

    /// The evidence index's proofs for a block.
    mutating func proofsFound(_ proofs: [ChildBlockProof], for cid: String, _ turn: inout Turn) {
        guard sync.proofs.awaiting[cid] != nil || sync.pending.entries[cid] != nil || index.contains(cid) else { return }
        offer(proofs, for: nil, cid: cid, from: nil, &turn)
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

    mutating func dropProofSource(_ peer: PeerID) {
        for cid in sync.proofs.awaiting.keys.sorted() {
            sync.proofs.awaiting[cid]?.announcers.removeAll { $0 == peer }
        }
    }

    // MARK: - Results

    /// A proof that weighs credits its grind: at a weighed block at once
    /// (persisted, indexed, relayed), on a pending header when it is weighed,
    /// and a waiting header enters the pending queue with it.
    mutating func proofVerified(
        _ job: ProofJob,
        _ result: Result<VerifiedChildEvidence, ChildProofVerificationFailure>,
        _ turn: inout Turn
    ) {
        guard let source = sync.proofs.verifying.removeValue(forKey: job.key) else { return }
        sync.proofs.perSource[source, default: 1] -= 1
        if sync.proofs.perSource[source] == 0 { sync.proofs.perSource[source] = nil }
        let cid = job.childCID
        sync.proofs.awaiting[cid]?.inFlight.remove(job.proofID)
        guard case .success(let evidence) = result, evidence.childCID == cid,
              let work = evidence.contribution, work.work > .zero else {
            if let held = sync.proofs.awaiting[cid], held.inFlight.isEmpty, held.unverified.isEmpty {
                sync.proofs.awaiting[cid]?.lookedUp = false
            }
            return
        }
        if index.contains(cid) {
            guard case .applied(let update) = tree.addWork(work, to: cid) else { return }
            turn.facts += update.batches
            turn.indexed.append((cid, job.proof))
            if let block = job.block {
                turn.relays.append((HeaderEntry(block: block, children: nil, proofs: [job.proof]), from: nil))
            }
        } else if let held = sync.pending.entries[cid] {
            guard held.evidence[evidence.grindID] == nil else { return }
            sync.pending.entries[cid]?.evidence[evidence.grindID] = evidence
            sync.pending.entries[cid]?.proofs[evidence.grindID] = job.proof
        } else if let waiting = sync.proofs.awaiting.removeValue(forKey: cid) {
            promote(waiting, evidence: evidence, proof: job.proof, &turn)
        }
    }

    /// A waiting header has verified work: it enters the pending queue, at
    /// its root's achieved hash, as `accept` enters a root header.
    mutating func promote(_ waiting: AwaitingProof, evidence: VerifiedChildEvidence, proof: ChildBlockProof, _ turn: inout Turn) {
        let cid = waiting.blockCID
        sync.proofs.queued.remove(cid)
        guard let parent = waiting.block.parent?.rawCID else { return }
        let work = workForTarget(waiting.block.target)
        let base = index.chainWork[parent] ?? sync.pending.entries[parent]?.chainWork
        let proofBytes = ((try? proof.serialize().count) ?? 0)
            + waiting.unverified.reduce(0) { $0 + ((try? $1.proof.serialize().count) ?? 0) }
        var header = PendingHeader(
            blockCID: cid,
            block: waiting.block,
            children: waiting.children,
            hash: evidence.rootHash,
            bytes: Self.size(of: waiting.block) + (waiting.children.map(Self.size) ?? 0) + proofBytes,
            announcers: waiting.announcers,
            chainWork: base.map { $0 + work }
        )
        header.evidence[evidence.grindID] = evidence
        header.proofs[evidence.grindID] = proof
        header.unverified = waiting.unverified
        sync.pending.insert(header)
        if !header.unverified.isEmpty { sync.proofs.queued.insert(cid) }
        for peer in waiting.announcers { sync.announced[peer, default: []].insert(cid) }
        if base != nil { linkDescendants(of: cid, &turn) }
        dirty(cid, &turn)
        sync.evict(to: config.pendingBudget)
    }

    // MARK: - Each step

    /// Check queued proofs while slots are free, then ask the evidence index
    /// in one batch: for every child header weighed this step (another
    /// host's grinds), every waiting header with no proof in hand, and every
    /// weighed block queued for another lookup.
    mutating func proofWork(_ turn: inout Turn) {
        for cid in sync.proofs.queued.sorted() where sync.proofs.verifying.count < proofConfig.maxChecks {
            var waiting = sync.proofs.awaiting[cid]?.unverified ?? sync.pending.entries[cid]?.unverified ?? []
            var kept: [QueuedProof] = []
            for queued in waiting {
                if sync.proofs.hasSlot(for: queued.source, proofConfig), !credits(queued.proof.rootCID, at: cid) {
                    dispatch(queued, cid: cid, block: nil, &turn)
                } else if !credits(queued.proof.rootCID, at: cid) {
                    kept.append(queued)
                }
            }
            waiting = kept
            if sync.proofs.awaiting[cid] != nil {
                sync.proofs.awaiting[cid]?.unverified = waiting
            } else if sync.pending.entries[cid] != nil {
                sync.pending.entries[cid]?.unverified = waiting
            }
            if waiting.isEmpty { sync.proofs.queued.remove(cid) }
        }
        var wanted = Set(turn.headers.map(\.blockCID))
        for (cid, held) in sync.proofs.awaiting
        where !held.lookedUp && held.inFlight.isEmpty && held.unverified.isEmpty {
            sync.proofs.awaiting[cid]?.lookedUp = true
            wanted.insert(cid)
        }
        if sync.proofs.hasSlot(for: nil, proofConfig) {
            wanted.formUnion(sync.proofs.relookup)
            sync.proofs.relookup = []
        }
        if !wanted.isEmpty { turn.effects.append(.lookupProofs(wanted.sorted())) }
    }

    // MARK: - Weighing

    /// Weigh a pending child header with its smallest-hash grind.
    mutating func insertChildHeader(
        _ header: PendingHeader,
        children: ChildIndex,
        _ context: ValidationContext
    ) -> ChainTreeAdmission {
        guard let first = header.evidence.values.min(by: {
            $0.rootHash != $1.rootHash ? $0.rootHash < $1.rootHash : $0.grindID < $1.grindID
        }) else { return .rejected(.unavailableEvidence) }
        return tree.insertChildHeader(
            header.block, childIndex: children, evidence: first, validationContext: context
        )
    }

    /// Credit a newly weighed child header's other grinds, one per root, and
    /// return every proof it now weighs by, to index and relay. Its queued
    /// proofs are checked later against the weighed block.
    mutating func creditRemainingProofs(of header: PendingHeader, _ turn: inout Turn) -> [ChildBlockProof] {
        guard !isRoot else { return [] }
        var credited: [ChildBlockProof] = []
        for (root, evidence) in header.evidence.sorted(by: { $0.key < $1.key }) {
            guard let work = evidence.contribution, let proof = header.proofs[root] else { continue }
            if tree.getConsensusBlock(hash: header.blockCID)?.workContributions[root] == nil {
                guard case .applied(let update) = tree.addWork(work, to: header.blockCID) else { continue }
                turn.facts += update.batches
            }
            credited.append(proof)
            turn.indexed.append((header.blockCID, proof))
        }
        if !header.unverified.isEmpty { sync.proofs.relookup.insert(header.blockCID) }
        sync.proofs.queued.remove(header.blockCID)
        return credited
    }

    // MARK: - Local and cross-level inputs

    /// Weigh this node's own grind at this level, blaming no one: a root
    /// block by its own work, a child block by the grind's verified proof.
    /// Part of one mined handoff, whose levels persist as one batch.
    mutating func weighOwn(
        _ block: Block,
        children: ChildIndex,
        proof: (proof: ChildBlockProof, evidence: VerifiedChildEvidence)?,
        now: Int64
    ) -> [Effect] {
        var turn = Turn(now: now)
        guard let cid = try? BlockHeader(node: block).rawCID else { return [] }
        let context = ValidationContext(nowMilliseconds: now)
        let held = index.contains(cid)
        let admission: ChainTreeAdmission
        if isRoot {
            admission = tree.insertRootHeader(block, childIndex: children, validationContext: context)
        } else {
            guard let proof, proof.evidence.childCID == cid,
                  let work = proof.evidence.contribution, work.work > .zero else { return [] }
            admission = held
                ? tree.addWork(work, to: cid)
                : tree.insertChildHeader(block, childIndex: children, evidence: proof.evidence, validationContext: context)
        }
        guard case .applied(let update) = admission else { return [] }
        if !held {
            let waiting = sync.pending.childrenOf[cid] ?? []
            sync.removePending(cid)
            sync.proofs.awaiting[cid] = nil
            sync.proofs.queued.remove(cid)
            turn.headers.append(StoredHeader(blockCID: cid, block: block, children: children))
            index.add(cid, parent: block.parent?.rawCID, height: block.height, work: workForTarget(block.target))
            for child in waiting { dirty(child, &turn) }
        }
        turn.facts += update.batches
        if let proof { turn.indexed.append((cid, proof.proof)) }
        turn.relays.append((
            config.entry(block, children: children, proofs: proof.map { [$0.proof] } ?? []),
            from: nil
        ))
        drain(&turn)
        if !isRoot { proofWork(&turn) }
        return finish(turn)
    }

    /// Apply an execution verdict: a validation joins the executed set, a
    /// proven-invalid block is excluded with its work still weighing.
    mutating func applyConnect(_ verdict: ConnectVerdict, now: Int64) -> (effects: [Effect], update: ChainTreeUpdate?) {
        var turn = Turn(now: now)
        let update = tree.applyConnect(verdict).update
        if let update { turn.facts += update.batches }
        return (finish(turn), update)
    }

    /// Credit a parent's attributed run at one of this level's blocks
    /// (hierarchical GHOST), derived and applied in one step.
    mutating func strengthen(
        _ child: String,
        directory: String,
        report: ParentRunReport,
        now: Int64
    ) -> [Effect]? {
        guard case .strengthened(let batch) = tree.strengthenFromParentReport(
            child: child, directory: directory, report: report
        ) else { return nil }
        do {
            _ = try tree.replay(batch)
        } catch {
            return nil
        }
        var turn = Turn(now: now)
        turn.facts.append(batch)
        return finish(turn)
    }
}
