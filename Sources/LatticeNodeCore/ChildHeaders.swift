import Lattice
import UInt256

/// A child level's proof bounds.
public struct ProofConfig: Sendable {
    /// Proof checks in flight at once. `indexReserve` of them only the
    /// evidence index (this node's own lookups) may take; peers share the
    /// rest, each at most `maxChecksPerSource` and at most an equal share
    /// among the peers with checks queued or in flight.
    public var maxChecks: Int
    public var maxChecksPerSource: Int
    public var indexReserve: Int
    /// Proofs taken from, or held for, one header, and the largest proof
    /// taken at all (a larger one is dropped, never blamed).
    public var maxPerHeader: Int
    public var maxProofBytes: Int
    /// Headers awaiting their first proof that weighs: at once, per peer,
    /// and in bytes (the headers and their queued proofs).
    public var maxAwaiting: Int
    public var maxAwaitingPerPeer: Int
    public var awaitingBudget: Int
    /// Blocks the evidence index named that this node does not hold: a
    /// header without proofs is taken only for one of these (or a parent a
    /// waiting header names).
    public var maxWanted: Int

    public init(
        maxChecks: Int = 256,
        maxChecksPerSource: Int = 64,
        indexReserve: Int = 32,
        maxPerHeader: Int = 8,
        maxProofBytes: Int = 64 * 1_024,
        maxAwaiting: Int = 1_024,
        maxAwaitingPerPeer: Int = 256,
        awaitingBudget: Int = 8 * 1_024 * 1_024,
        maxWanted: Int = 4_096
    ) {
        self.maxChecks = maxChecks
        self.maxChecksPerSource = maxChecksPerSource
        self.indexReserve = indexReserve
        self.maxPerHeader = maxPerHeader
        self.maxProofBytes = maxProofBytes
        self.maxAwaiting = maxAwaiting
        self.maxAwaitingPerPeer = maxAwaitingPerPeer
        self.awaitingBudget = awaitingBudget
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

/// A proof not yet checked, where it came from (nil: the evidence index),
/// and its serialized size, charged to whatever holds it.
public struct QueuedProof: Sendable {
    public let proof: ChildBlockProof
    public let id: String
    public let source: PeerID?
    public let bytes: Int
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
/// by count, per peer and in bytes; an entry with a check in flight is never
/// evicted.
public struct AwaitingProof: Sendable {
    public let blockCID: String
    public let block: Block
    public internal(set) var children: ChildIndex?
    public internal(set) var announcers: [PeerID]
    public internal(set) var unverified: [QueuedProof] = []
    public internal(set) var inFlight: Set<String> = []
    /// Whether its proofs were looked up since the evidence index changed.
    public internal(set) var lookedUp = false
    /// The header's bytes and its queued proofs'.
    public internal(set) var bytes: Int
    let sequence: UInt64

    var source: PeerID? { announcers.first }
}

/// A queued proof by its header and content.
struct ProofRef: Sendable, Hashable {
    let cid: String
    let id: String
}

/// A child level's proof work.
public struct ProofSync: Sendable {
    public internal(set) var awaiting: [String: AwaitingProof] = [:]
    public internal(set) var awaitingBytes = 0
    /// Checks in flight, and the source each is charged to.
    public internal(set) var verifying: [ProofKey: PeerID?] = [:]
    var perSource: [PeerID?: Int] = [:]
    /// Queued proofs, FIFO per source, served round-robin across sources
    /// from a rotating start.
    var fifo: [PeerID?: [ProofRef]] = [:]
    var rotation: [PeerID?] = []
    var cursor = 0
    /// Weighed blocks to look up in the evidence index again.
    var relookup: Set<String> = []
    var wanted: Set<String> = []
    var wantedOrder: [String] = []
    var sequence: UInt64 = 0

    public init() {}

    /// Whether `source` may start a check now: a free slot, outside the
    /// index's reserve for a peer, and within the peer's share.
    func hasSlot(for source: PeerID?, _ config: ProofConfig) -> Bool {
        guard verifying.count < config.maxChecks else { return false }
        guard let source else { return true }
        // The reserve always leaves peers at least one slot.
        let peerCapacity = max(1, config.maxChecks - config.indexReserve)
        let peerChecks = verifying.count - (perSource[nil] ?? 0)
        guard peerChecks < peerCapacity else { return false }
        var active = Set(perSource.keys.compactMap { $0 })
        for (queued, refs) in fifo where !refs.isEmpty { if let queued { active.insert(queued) } }
        active.remove(source)
        let share = max(1, min(config.maxChecksPerSource, peerCapacity / (active.count + 1)))
        return (perSource[source] ?? 0) < share
    }

    mutating func enqueue(_ ref: ProofRef, from source: PeerID?) {
        if fifo[source]?.isEmpty ?? true, !rotation.contains(source) { rotation.append(source) }
        fifo[source, default: []].append(ref)
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
            if held.children == nil, let children = entry.children {
                let size = Self.size(of: children)
                held.children = children
                held.bytes += size
                sync.proofs.awaitingBytes += size
            }
            sync.proofs.awaiting[cid] = held
            offer(entry.proofs, for: entry.block, cid: cid, from: peer, &turn)
            trimAwaiting()
            return
        }
        let wanted = sync.proofs.wanted.contains(cid) || sync.pending.childrenOf[cid] != nil
            || sync.proofs.awaiting.values.contains { $0.block.parent?.rawCID == cid }
        guard !entry.proofs.isEmpty || wanted else { return }
        let fromPeer = sync.proofs.awaiting.values.filter { $0.source == peer }.count
        let bytes = Self.size(of: entry.block) + (entry.children.map(Self.size) ?? 0)
        guard fromPeer < proofConfig.maxAwaitingPerPeer, makeRoomToAwait(bytes) else { return }
        sync.proofs.sequence += 1
        sync.proofs.awaiting[cid] = AwaitingProof(
            blockCID: cid, block: entry.block, children: entry.children,
            announcers: [peer], bytes: bytes, sequence: sync.proofs.sequence
        )
        sync.proofs.awaitingBytes += bytes
        sync.proofs.wanted.remove(cid)
        offer(entry.proofs, for: entry.block, cid: cid, from: peer, &turn)
        trimAwaiting()
    }

    /// Room for one more waiting header of `bytes`: evict from the source
    /// holding the most entries (bytes, when over the byte budget), its
    /// oldest with no check in flight; or refuse.
    mutating func makeRoomToAwait(_ bytes: Int) -> Bool {
        while sync.proofs.awaiting.count >= proofConfig.maxAwaiting
                || sync.proofs.awaitingBytes + bytes > proofConfig.awaitingBudget {
            let byCount = sync.proofs.awaiting.count >= proofConfig.maxAwaiting
            guard evictAwaiting(byBytes: !byCount) else { return false }
        }
        return true
    }

    /// Back within the byte budget after queued proofs grew an entry.
    mutating func trimAwaiting() {
        while sync.proofs.awaitingBytes > proofConfig.awaitingBudget, evictAwaiting(byBytes: true) {}
    }

    mutating func evictAwaiting(byBytes: Bool) -> Bool {
        var load: [PeerID?: Int] = [:]
        for entry in sync.proofs.awaiting.values where entry.inFlight.isEmpty {
            load[entry.source, default: 0] += byBytes ? entry.bytes : 1
        }
        guard let heaviest = load.max(by: { $0.value != $1.value ? $0.value < $1.value : "\(String(describing: $0.key))" > "\(String(describing: $1.key))" })?.key,
              let victim = sync.proofs.awaiting.values
                .filter({ $0.inFlight.isEmpty && $0.source == heaviest })
                .min(by: { $0.sequence < $1.sequence }) else { return false }
        sync.proofs.awaiting[victim.blockCID] = nil
        sync.proofs.awaitingBytes -= victim.bytes
        return true
    }

    /// Check each new proof (by content) of a waiting, pending or weighed
    /// header now if its source has a free slot and nothing queued ahead of
    /// it, else queue it with the header (up to `maxPerHeader`, its bytes
    /// charged there). A proof larger than `maxProofBytes` is dropped
    /// without blame. A proof that cannot be kept clears the header's
    /// lookup, or queues a weighed block for another, so it is found again.
    mutating func offer(_ proofs: [ChildBlockProof], for block: Block?, cid: String, from source: PeerID?, _ turn: inout Turn) {
        for proof in proofs.prefix(proofConfig.maxPerHeader) {
            guard let bytes = try? proof.serialize(), bytes.count <= proofConfig.maxProofBytes else { continue }
            let id = "\(UInt256.hash(bytes))"
            let key = ProofKey(childCID: cid, proofID: id)
            guard sync.proofs.verifying[key] == nil, !isQueued(id, at: cid), !credits(proof.rootCID, at: cid) else { continue }
            let queued = QueuedProof(proof: proof, id: id, source: source, bytes: bytes.count)
            if sync.proofs.fifo[source]?.isEmpty ?? true, sync.proofs.hasSlot(for: source, proofConfig) {
                dispatch(queued, cid: cid, block: block, &turn)
            } else if !queue(queued, at: cid) {
                skipped(cid)
            }
        }
    }

    func isQueued(_ id: String, at cid: String) -> Bool {
        (sync.proofs.awaiting[cid]?.unverified ?? sync.pending.entries[cid]?.unverified ?? [])
            .contains { $0.id == id }
    }

    /// Queue a proof with its waiting or pending header, charging its bytes
    /// there (the pending queue's budget then evicts as it does).
    mutating func queue(_ proof: QueuedProof, at cid: String) -> Bool {
        if var held = sync.proofs.awaiting[cid], held.unverified.count < proofConfig.maxPerHeader {
            held.unverified.append(proof)
            held.bytes += proof.bytes
            sync.proofs.awaiting[cid] = held
            sync.proofs.awaitingBytes += proof.bytes
        } else if let held = sync.pending.entries[cid], held.unverified.count < proofConfig.maxPerHeader {
            sync.pending.entries[cid]?.unverified.append(proof)
            sync.pending.entries[cid]?.bytes += proof.bytes
            sync.pending.bytes += proof.bytes
        } else {
            return false
        }
        sync.proofs.enqueue(ProofRef(cid: cid, id: proof.id), from: proof.source)
        if sync.pending.entries[cid] != nil { sync.evict(to: config.pendingBudget) }
        return true
    }

    /// Take a queued proof back from its header, uncharging its bytes; nil
    /// when the header or the proof is gone.
    mutating func takeQueued(_ ref: ProofRef) -> QueuedProof? {
        if var held = sync.proofs.awaiting[ref.cid] {
            guard let at = held.unverified.firstIndex(where: { $0.id == ref.id }) else { return nil }
            let proof = held.unverified.remove(at: at)
            held.bytes -= proof.bytes
            sync.proofs.awaiting[ref.cid] = held
            sync.proofs.awaitingBytes -= proof.bytes
            return proof
        }
        guard let at = sync.pending.entries[ref.cid]?.unverified.firstIndex(where: { $0.id == ref.id }),
              let proof = sync.pending.entries[ref.cid]?.unverified.remove(at: at) else { return nil }
        sync.pending.entries[ref.cid]?.bytes -= proof.bytes
        sync.pending.bytes -= proof.bytes
        return proof
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
        trimAwaiting()
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
            let size = (try? job.proof.serialize().count) ?? 0
            sync.pending.entries[cid]?.evidence[evidence.grindID] = evidence
            sync.pending.entries[cid]?.proofs[evidence.grindID] = job.proof
            sync.pending.entries[cid]?.bytes += size
            sync.pending.bytes += size
            sync.evict(to: config.pendingBudget)
        } else if let waiting = sync.proofs.awaiting.removeValue(forKey: cid) {
            sync.proofs.awaitingBytes -= waiting.bytes
            promote(waiting, evidence: evidence, proof: job.proof, &turn)
        }
    }

    /// A waiting header has verified work: it enters the pending queue, at
    /// its root's achieved hash, as `accept` enters a root header, and is
    /// weighed at once when its parent is. Its bytes (and its queued
    /// proofs') move with it.
    mutating func promote(_ waiting: AwaitingProof, evidence: VerifiedChildEvidence, proof: ChildBlockProof, _ turn: inout Turn) {
        let cid = waiting.blockCID
        guard waiting.block.parent != nil else { return }
        var header = PendingHeader(
            blockCID: cid,
            block: waiting.block,
            children: waiting.children,
            hash: evidence.rootHash,
            bytes: waiting.bytes + ((try? proof.serialize().count) ?? 0),
            announcers: waiting.announcers
        )
        header.evidence[evidence.grindID] = evidence
        header.proofs[evidence.grindID] = proof
        header.unverified = waiting.unverified
        sync.pending.insert(header)
        for peer in waiting.announcers { sync.announced[peer, default: []].insert(cid) }
        dirty(cid, &turn)
        sync.evict(to: config.pendingBudget)
    }

    // MARK: - Each step

    /// Check queued proofs while slots are free — round-robin across
    /// sources from a rotating start, FIFO within each, so no source wins
    /// every freed slot — then ask the evidence index in one batch: for
    /// every child header weighed this step (another host's grinds), every
    /// waiting header with no proof in hand, and every weighed block queued
    /// for another lookup.
    mutating func proofWork(_ turn: inout Turn) {
        var progress = true
        while progress, sync.proofs.verifying.count < proofConfig.maxChecks, !sync.proofs.rotation.isEmpty {
            progress = false
            let sources = sync.proofs.rotation
            let start = sync.proofs.cursor % sources.count
            for offset in 0..<sources.count {
                let source = sources[(start + offset) % sources.count]
                guard sync.proofs.hasSlot(for: source, proofConfig) else { continue }
                while var refs = sync.proofs.fifo[source], !refs.isEmpty {
                    let ref = refs.removeFirst()
                    sync.proofs.fifo[source] = refs
                    guard let queued = takeQueued(ref) else { continue }
                    if credits(queued.proof.rootCID, at: ref.cid) { continue }
                    dispatch(queued, cid: ref.cid, block: nil, &turn)
                    progress = true
                    break
                }
            }
            sync.proofs.cursor = start + 1
            sync.proofs.rotation.removeAll { sync.proofs.fifo[$0]?.isEmpty ?? true }
            for (source, refs) in sync.proofs.fifo where refs.isEmpty { sync.proofs.fifo[source] = nil }
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
            if let waiting = sync.proofs.awaiting.removeValue(forKey: cid) {
                sync.proofs.awaitingBytes -= waiting.bytes
            }
            turn.headers.append(StoredHeader(blockCID: cid, block: block, children: children))
            index.add(cid, parent: block.parent?.rawCID, height: block.height)
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
