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
    /// Proofs taken from one header, and the largest proof taken at all.
    public var maxPerHeader: Int
    public var maxProofBytes: Int
    /// The operator's memory budget for proofs queued or in flight, all
    /// sources together; over it, a proof is dropped without blame.
    public var maxQueuedBytes: Int
    /// Headers awaiting their first proof that weighs, at once.
    public var maxAwaiting: Int
    /// Blocks the evidence index named that this node does not hold: a
    /// header without proofs is taken only for one of these (or a parent a
    /// waiting header names).
    public var maxWanted: Int

    public init(
        maxChecks: Int = 256,
        indexChecks: Int = 32,
        maxPerHeader: Int = 8,
        maxProofBytes: Int = 64 * 1_024,
        maxQueuedBytes: Int = 16 * 1_024 * 1_024,
        maxAwaiting: Int = 1_024,
        maxWanted: Int = 4_096
    ) {
        self.maxChecks = maxChecks
        self.indexChecks = indexChecks
        self.maxPerHeader = maxPerHeader
        self.maxProofBytes = maxProofBytes
        self.maxQueuedBytes = maxQueuedBytes
        self.maxAwaiting = maxAwaiting
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
/// reads it from its store, as it does to serve it. A `derived` proof was
/// built by this node (`ChildDeriveJob`): in no slot, blaming no one.
public struct ChildProofJob: Sendable {
    public let childCID: String
    public let block: Block?
    public let proof: ChildBlockProof
    public let proofID: String
    public let chainPath: [String]
    public internal(set) var derived = false

    public var key: ChildProofKey { ChildProofKey(childCID: childCID, proofID: proofID) }

    /// The cheap test first: the claimed root's hash meets the block's
    /// target. Only a proof whose sender did that work reaches the path walk.
    public func run(_ block: Block) async -> Result<VerifiedChildEvidence, ChildProofVerificationFailure> {
        guard let root = proof.entries.first(where: { $0.cid == proof.rootCID }).flatMap({ Block(data: $0.data) }),
              block.validateProofOfWork(nexusHash: root.proofOfWorkHash()) else { return .failure(.malformedEvidence) }
        return await proof.verifySecuringWork(child: block, chainPath: chainPath)
    }

    /// A proof's content identity: the hash of its canonical bytes.
    public static func id(of proof: ChildBlockProof) -> String? {
        guard let bytes = try? proof.serialize() else { return nil }
        return "\(UInt256.hash(bytes))"
    }
}

/// One derivation the shell runs off the step, from this node's own
/// content: the proofs of a block at `chainPath` from `carrier`, a block of
/// the parent level that commits it, each of the carrier's saved proofs
/// (none for a root block) extended by the carrier's hop, then each checked
/// as a derived `ChildProofJob`. Only the proofs of `grinds` are built.
/// `block` is nil for a weighed block: the shell reads it from its store.
public struct ChildDeriveJob: Sendable {
    public let childCID: String
    public let block: Block?
    public let carrier: String
    /// The carrier's grinds owed here: not credited.
    public let grinds: Set<String>
    public let chainPath: [String]

    /// The job over `held` (the block, as the shell holds it): each proof
    /// built from `upstream` (the carrier's saved proofs) with its check. No
    /// checks when the block is not held or the hop cannot be read from
    /// `fetcher`.
    public func run(held: Block?, upstream: [ChildBlockProof], fetcher: any Fetcher) async -> ChildDerivation {
        guard let block = held, let bytes = block.toData() else {
            return ChildDerivation(job: self, checks: [])
        }
        let local = CoalescingFetcher(OverlayContentSource(entries: [childCID: bytes], fallback: FetcherContentSource(fetcher)))
        let proofs = (try? await ChildBlockProof.extending(
            chainPath.count == 2 ? nil : upstream, by: BlockHeader(rawCID: carrier),
            into: chainPath[chainPath.count - 1], fetcher: local
        )) ?? []
        var checks: [(ChildProofJob, Result<VerifiedChildEvidence, ChildProofVerificationFailure>)] = []
        for proof in proofs where grinds.contains(proof.rootCID) {
            guard let id = ChildProofJob.id(of: proof) else { continue }
            var check = ChildProofJob(childCID: childCID, block: self.block, proof: proof, proofID: id, chainPath: chainPath)
            check.derived = true
            checks.append((check, await check.run(block)))
        }
        return ChildDerivation(job: self, checks: checks)
    }
}

/// A derivation's answer: each proof it built with its check.
public struct ChildDerivation: Sendable {
    public let job: ChildDeriveJob
    public let checks: [(ChildProofJob, Result<VerifiedChildEvidence, ChildProofVerificationFailure>)]
}

extension ChildBlockProof {
    /// The proofs of the block `carrier` commits at `directory`: each of
    /// `upstream` (proofs of `carrier` from a root) extended by `carrier`'s
    /// hop, or the hop alone when `upstream` is nil (`carrier` is the root).
    public static func extending(
        _ upstream: [ChildBlockProof]?, by carrier: BlockHeader, into directory: String, fetcher: any Fetcher
    ) async throws -> [ChildBlockProof] {
        let hop = try await generate(rootHeader: carrier, childDirectory: directory, fetcher: fetcher)
        return upstream.map { $0.map { $0.composing(hop: hop) } } ?? [hop]
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

/// A child level's proof work: one FIFO of unchecked proofs and the checks
/// in flight.
public struct ChildProofSync: Sendable {
    public internal(set) var awaiting: [String: AwaitingChildProof] = [:]
    public internal(set) var queued: [QueuedChildProof] = []
    public internal(set) var verifying: [ChildProofKey: QueuedChildProof] = [:]
    /// Weighed blocks to look up in the evidence index again.
    var relookup: Set<String> = []
    var wanted: Set<String> = []
    var wantedOrder: [String] = []
    var sequence: UInt64 = 0
    /// Derivations in flight, counted by the block derived (a waiting
    /// header with one is never evicted). Soft: in memory only, gone on
    /// restart.
    var deriving: [String: Int] = [:]

    public init() {}

    public func checks(index: Bool) -> Int {
        verifying.values.filter { ($0.source == nil) == index }.count
    }

    func holds(_ cid: String) -> Bool {
        queued.contains { $0.cid == cid } || verifying.keys.contains { $0.childCID == cid }
            || deriving[cid] != nil
    }

    mutating func startDeriving(_ child: String) {
        deriving[child, default: 0] += 1
    }

    mutating func finishDeriving(_ child: String) {
        guard let count = deriving[child] else { return }
        deriving[child] = count == 1 ? nil : count - 1
    }

    /// Forget everything `peer` sent, queued or in flight. A check still
    /// running in the shell answers into nothing.
    mutating func purge(_ peer: PeerID) {
        queued.removeAll { $0.source == peer }
        for (key, proof) in verifying where proof.source == peer { verifying[key] = nil }
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
    /// no proofs is taken only when wanted (the evidence index named it, a
    /// waiting header names it as parent, or a parent-level block commits
    /// it, whose grinds are then derived); otherwise it is dropped, so
    /// strangers cannot spend this node's lookups. One from no peer (a
    /// local submit) has no announcer.
    mutating func awaitProof(_ entry: HeaderEntry, cid: String, from peer: PeerID?, _ turn: inout Turn) {
        if var held = sync.proofs.awaiting[cid] {
            if let peer, !held.announcers.contains(peer) { held.announcers.append(peer) }
            if held.children == nil, let children = entry.children { held.children = children }
            if held.spec == nil { held.spec = Self.bound(entry.spec, by: entry.block) }
            sync.proofs.awaiting[cid] = held
            offer(entry.proofs, cid: cid, from: peer)
            return
        }
        let wanted = sync.proofs.wanted.contains(cid) || sync.pending.childrenOf[cid] != nil
            || sync.proofs.awaiting.values.contains { $0.block.parent?.rawCID == cid }
            || parentTree.map { !$0.committers(of: cid, directory: chainPath[chainPath.count - 1]).isEmpty } == true
        guard !entry.proofs.isEmpty || wanted else { return }
        guard makeRoomToAwait() else { return }
        sync.proofs.sequence += 1
        sync.proofs.awaiting[cid] = AwaitingChildProof(
            blockCID: cid, block: entry.block, children: entry.children, spec: Self.bound(entry.spec, by: entry.block),
            announcers: peer.map { [$0] } ?? [], sequence: sync.proofs.sequence
        )
        sync.proofs.wanted.remove(cid)
        arrived.append(cid)
        offer(entry.proofs, cid: cid, from: peer)
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
    /// header, up to `maxPerHeader` from one header, within the queue's byte
    /// budget; over it, a proof is dropped without blame and the block is
    /// looked up again later. Checks start in `proofWork`.
    mutating func offer(_ proofs: [ChildBlockProof], cid: String, from source: PeerID?) {
        // Work crediting a block beyond the finality window is declined.
        if pastFinality(cid) { return }
        // Grinds not yet credited first, so a header served again with the
        // same proofs offers the ones a cap left out.
        var fresh: [ChildBlockProof] = []
        for proof in proofs where !credits(proof.rootCID, at: cid) { fresh.append(proof) }
        var held = sync.proofs.queued.reduce(0) { $0 + $1.bytes }
            + sync.proofs.verifying.values.reduce(0) { $0 + $1.bytes }
        for proof in fresh.prefix(proofConfig.maxPerHeader) {
            guard let bytes = try? proof.serialize(), bytes.count <= proofConfig.maxProofBytes else { continue }
            let id = "\(UInt256.hash(bytes))"
            let queued = QueuedChildProof(cid: cid, proof: proof, id: id, source: source, bytes: bytes.count)
            guard sync.proofs.verifying[queued.key] == nil,
                  !sync.proofs.queued.contains(where: { $0.key == queued.key }),
                  !credits(proof.rootCID, at: cid) else { continue }
            guard held + queued.bytes <= proofConfig.maxQueuedBytes else {
                skipped(cid)
                continue
            }
            held += queued.bytes
            sync.proofs.queued.append(queued)
        }
    }

    /// A proof this node could not keep: look the block up again later.
    mutating func skipped(_ cid: String) {
        if sync.proofs.awaiting[cid] != nil {
            sync.proofs.awaiting[cid]?.lookedUp = false
        } else if sync.pending.entries[cid] != nil || tree.contains(blockHash: cid) {
            sync.proofs.relookup.insert(cid)
        }
    }

    mutating func credits(_ grind: String, at cid: String) -> Bool {
        sync.pending.entries[cid]?.evidence[grind] != nil
            || (tree.contains(blockHash: cid) && tree.workContribution(id: grind, at: cid) != nil)
    }

    /// The evidence index's proofs for a block.
    mutating func proofsFound(_ proofs: [ChildBlockProof], for cid: String, _ turn: inout Turn) {
        guard sync.proofs.awaiting[cid] != nil || sync.pending.entries[cid] != nil || tree.contains(blockHash: cid) else { return }
        offer(proofs, cid: cid, from: nil)
    }

    mutating func evidenceChanged(_ cids: [String]) {
        for cid in Set(cids).sorted() {
            if sync.proofs.awaiting[cid] != nil {
                sync.proofs.awaiting[cid]?.lookedUp = false
            } else if sync.pending.entries[cid] != nil || tree.contains(blockHash: cid) {
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
    /// failure: the peer that sent it is disconnected; the index's and a
    /// derived proof's blame no one.
    mutating func proofVerified(
        _ job: ChildProofJob,
        _ result: Result<VerifiedChildEvidence, ChildProofVerificationFailure>,
        _ turn: inout Turn
    ) {
        var source: PeerID?
        if !job.derived {
            guard let checked = sync.proofs.verifying.removeValue(forKey: job.key) else { return }
            source = checked.source
        }
        let cid = job.childCID
        guard case .success(let evidence) = result, evidence.childCID == cid,
              let work = evidence.contribution, work.work > .zero else {
            if let peer = source { disconnect(peer, .proofOfWorkInvalid, &turn) }
            if sync.proofs.awaiting[cid] != nil, !sync.proofs.holds(cid) {
                sync.proofs.awaiting[cid]?.lookedUp = false
            }
            return
        }
        if tree.contains(blockHash: cid) {
            // The window may have moved past the block while it was checked.
            guard !pastFinality(cid),
                  case .applied(let update) = tree.addWork(work, to: cid) else { return }
            turn.facts += update.batches
            weighed += update.weighed
            turn.indexed.append(StoredProof(childCID: cid, proof: job.proof))
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
                || tree.contains(blockHash: proof.cid)
            guard known, !credits(proof.proof.rootCID, at: proof.cid) else { continue }
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
            turn.indexed.append(StoredProof(childCID: header.blockCID, proof: proof))
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
        arrived = []
        guard let cid = try? BlockHeader(node: block).rawCID else { return [] }
        let context = ValidationContext(nowMilliseconds: now)
        let held = tree.contains(blockHash: cid)
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
            for child in waiting { dirty(child, &turn) }
        }
        turn.facts += update.batches
        if let proof { turn.indexed.append(StoredProof(childCID: cid, proof: proof.proof)) }
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

    /// Derive the grinds of parent-level carriers at the blocks they commit
    /// here, beside run attribution and by its index: each block `carriers`
    /// (weighed at the parent this step) commits into this directory, and
    /// each committer of a block in `arrived`. A carrier is derived for its
    /// grinds this level owes the block: those not credited, whatever peer
    /// proofs are queued or in a check (a peer may vanish with its proofs;
    /// a second check of one grind credits once). A pair fully credited
    /// issues nothing, so a restored level's pass is cheap; a grind that
    /// misses the block's target is derived again at each trigger (a weigh
    /// or an arrival), even with one in flight (credit is idempotent). Only
    /// a block this level holds, awaits or has pending is derived: one it
    /// does not know is credited when it arrives, by gossip or a local
    /// submit (its author pushes it until it is weighed).
    mutating func deriveGrinds(from parent: ChainTree, carriers: Set<String>, arrived: Set<String>) -> [ChainEffect] {
        let directory = chainPath[chainPath.count - 1]
        var pairs: Set<[String]> = []
        for carrier in carriers {
            guard let named = parent.recordedChildCommitments(of: carrier)?[directory] else { continue }
            pairs.insert([carrier, CIDIdentity.canonicalString(named) ?? named])
        }
        for child in arrived {
            for carrier in parent.committers(of: child, directory: directory) { pairs.insert([carrier, child]) }
        }
        var effects: [ChainEffect] = []
        for pair in pairs.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            let (carrier, child) = (pair[0], pair[1])
            guard tree.contains(blockHash: child) || sync.proofs.awaiting[child] != nil || sync.pending.entries[child] != nil,
                  !sync.declined.contains(child), let meta = parent.getConsensusBlock(hash: carrier) else { continue }
            let grinds = meta.workContributions.keys.filter { !meta.attributedRuns.contains($0) }
            let owed = Set(grinds.filter { !credits($0, at: child) })
            guard !owed.isEmpty else { continue }
            sync.proofs.startDeriving(child)
            effects.append(.deriveProof(ChildDeriveJob(
                childCID: child,
                block: sync.proofs.awaiting[child]?.block ?? sync.pending.entries[child]?.block,
                carrier: carrier, grinds: owed, chainPath: chainPath
            )))
        }
        return effects
    }

    /// A derivation's checks: each judged as a derived proof.
    mutating func derived(_ derivation: ChildDerivation, _ turn: inout Turn) {
        for (check, result) in derivation.checks { proofVerified(check, result, &turn) }
    }
}
