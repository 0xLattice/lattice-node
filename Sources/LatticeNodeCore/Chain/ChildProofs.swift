import Lattice
import cashew
import UInt256

/// A child level's proof bounds: plain caps. A peer whose proof fails
/// proof-of-work is disconnected, so no fairness machinery is needed.
public struct ChildProofConfig: Sendable {
    /// Proofs taken from one header, and the largest proof taken at all.
    public var maxPerHeader: Int
    public var maxProofBytes: Int
    /// The operator's memory budget for proofs in a check, all sources
    /// together; over it, a proof is dropped without blame.
    public var maxQueuedBytes: Int
    /// Headers awaiting their first proof that weighs, at once.
    public var maxAwaiting: Int

    public init(
        maxPerHeader: Int = 8,
        maxProofBytes: Int = 64 * 1_024,
        maxQueuedBytes: Int = 16 * 1_024 * 1_024,
        maxAwaiting: Int = 1_024
    ) {
        self.maxPerHeader = maxPerHeader
        self.maxProofBytes = maxProofBytes
        self.maxQueuedBytes = maxQueuedBytes
        self.maxAwaiting = maxAwaiting
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

/// A peer's proof in a check: for a block, from the peer that sent it, with
/// its serialized size.
public struct QueuedChildProof: Sendable {
    public let cid: String
    public let proof: ChildBlockProof
    public let id: String
    public let source: PeerID
    public let bytes: Int

    public var key: ChildProofKey { ChildProofKey(childCID: cid, proofID: id) }
}

/// One proof check: `verifySecuringWork` of `proof` for the block on the
/// level's chain. Pure over its inputs, so its answer is never stale.
/// `block` is nil for a weighed block: the shell reads it from its store,
/// as it does to serve it. A `derived` proof was built by this node
/// (`ChildDeriveJob`), blaming no one.
public struct ChildProofJob: Sendable {
    public let childCID: String
    public let block: Block?
    public let proof: ChildBlockProof
    public let proofID: String
    public let chainPath: [String]
    public internal(set) var derived = false

    public var key: ChildProofKey { ChildProofKey(childCID: childCID, proofID: proofID) }

    /// The check: a root whose hash misses the block's target comes back
    /// with no contribution, which `proofVerified` judges a failure.
    public func run(_ block: Block) -> Result<VerifiedChildEvidence, ChildProofVerificationFailure> {
        proof.verifySecuringWork(child: block, chainPath: chainPath)
    }

    /// A proof's content identity: the hash of its canonical bytes.
    public static func id(of proof: ChildBlockProof) -> String? {
        guard let bytes = try? proof.serialize() else { return nil }
        return "\(UInt256.hash(bytes))"
    }
}

/// The proofs one step took from peers, checked together in one job off
/// the step (geth's `VerifyHeaders` checks a batch of headers off its import
/// loop), whose answers apply in one step: one persist for the page.
public struct ChildProofBatch: Sendable {
    public let jobs: [ChildProofJob]

    /// Each check, its block read through `stored` when the job carries
    /// none; nil when that block is not held (no verdict, no blame).
    public func run(stored: (String) -> Block?) -> [ChildProofAnswer] {
        jobs.map { job in
            ChildProofAnswer(job: job, result: (job.block ?? stored(job.childCID)).map(job.run))
        }
    }
}

/// One check's answer: its result, or nil when its block was not held.
public struct ChildProofAnswer: Sendable {
    public let job: ChildProofJob
    public let result: Result<VerifiedChildEvidence, ChildProofVerificationFailure>?

    public init(job: ChildProofJob, result: Result<VerifiedChildEvidence, ChildProofVerificationFailure>?) {
        self.job = job
        self.result = result
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
            checks.append((check, check.run(block)))
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
    let sequence: UInt64

    var source: PeerID? { announcers.first }
}

/// A child level's proof work: the headers awaiting a proof, the peers'
/// proofs in a check, and the derivations in flight.
public struct ChildProofSync: Sendable {
    public internal(set) var awaiting: [String: AwaitingChildProof] = [:]
    /// Peers' proofs in a verify job: a check in flight still answers when
    /// its peer is gone (a check is the proof's verdict, not its sender's).
    public private(set) var verifying: [ChildProofKey: QueuedChildProof] = [:]
    /// What `verifying` holds, kept with it: its bytes, its checks per
    /// block, and its (block, root) pairs.
    public private(set) var verifyingBytes = 0
    private var checksOf: [String: Int] = [:]
    private var checkedRoots: [[String]: Int] = [:]
    var sequence: UInt64 = 0
    /// Derivations in flight, counted by the block derived (a waiting
    /// header with one is never evicted). Soft: in memory only, gone on
    /// restart.
    var deriving: [String: Int] = [:]

    public init() {}

    func holds(_ cid: String) -> Bool {
        checksOf[cid] != nil || deriving[cid] != nil
    }

    /// Whether a peer's proof of `root` at `cid` is in a check.
    func checking(_ cid: String, root: String) -> Bool {
        checkedRoots[[cid, root]] != nil
    }

    mutating func startCheck(_ proof: QueuedChildProof) {
        verifying[proof.key] = proof
        verifyingBytes += proof.bytes
        checksOf[proof.cid, default: 0] += 1
        checkedRoots[[proof.cid, proof.proof.rootCID], default: 0] += 1
    }

    mutating func endCheck(_ key: ChildProofKey) -> QueuedChildProof? {
        guard let proof = verifying.removeValue(forKey: key) else { return nil }
        verifyingBytes -= proof.bytes
        let count = checksOf[proof.cid] ?? 1
        checksOf[proof.cid] = count == 1 ? nil : count - 1
        let pair = [proof.cid, proof.proof.rootCID], roots = checkedRoots[pair] ?? 1
        checkedRoots[pair] = roots == 1 ? nil : roots - 1
        return proof
    }

    mutating func startDeriving(_ child: String) {
        deriving[child, default: 0] += 1
    }

    mutating func finishDeriving(_ child: String) {
        guard let count = deriving[child] else { return }
        deriving[child] = count == 1 ? nil : count - 1
    }
}

/// A child level's header is its block and a `ChildBlockProof` per root that
/// carries it. It waits in `awaitingProof` until one proof verifies and
/// weighs, then enters the pending queue (prioritised by that root's hash)
/// and is weighed by `insertChildHeader`; every other root is credited with
/// `addWork`. Blame only when proof-of-work fails: a proof a peer sent that
/// fails `verifySecuringWork` (malformed, or no work for that block)
/// disconnects the peer, which honest peers never risk, since they relay
/// only proofs they verified; a derived proof blames no one. A missing
/// proof is a liveness wait until a peer sends it.
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
    /// no proofs is taken only when wanted (a pending or waiting header
    /// names it as parent, or a parent-level block commits it, whose grinds
    /// are then derived); otherwise it is dropped, so strangers cannot fill
    /// the waiting pool for free. One from no peer (a local submit) has no
    /// announcer and no proofs.
    mutating func awaitProof(_ entry: HeaderEntry, cid: String, from peer: PeerID?, _ turn: inout Turn) {
        if var held = sync.proofs.awaiting[cid] {
            if let peer, !held.announcers.contains(peer) { held.announcers.append(peer) }
            if held.children == nil, let children = entry.children { held.children = children }
            if held.spec == nil { held.spec = Self.bound(entry.spec, by: entry.block) }
            sync.proofs.awaiting[cid] = held
            if let peer { offer(entry.proofs, cid: cid, from: peer, &turn) }
            return
        }
        let wanted = sync.pending.childrenOf[cid] != nil
            || sync.proofs.awaiting.values.contains { $0.block.parent?.rawCID == cid }
            || parentTree.map { !$0.committers(of: cid, directory: chainPath[chainPath.count - 1]).isEmpty } == true
        guard !entry.proofs.isEmpty || wanted else { return }
        guard makeRoomToAwait() else { return }
        sync.proofs.sequence += 1
        sync.proofs.awaiting[cid] = AwaitingChildProof(
            blockCID: cid, block: entry.block, children: entry.children, spec: Self.bound(entry.spec, by: entry.block),
            announcers: peer.map { [$0] } ?? [], sequence: sync.proofs.sequence
        )
        arrived.append(cid)
        if let peer { offer(entry.proofs, cid: cid, from: peer, &turn) }
    }

    /// Room for one more waiting header: evict the oldest with no proof in a
    /// check and no derivation in flight, or refuse.
    mutating func makeRoomToAwait() -> Bool {
        guard sync.proofs.awaiting.count >= proofConfig.maxAwaiting else { return true }
        guard let victim = sync.proofs.awaiting.values
            .filter({ !sync.proofs.holds($0.blockCID) })
            .min(by: { $0.sequence < $1.sequence }) else { return false }
        sync.proofs.awaiting[victim.blockCID] = nil
        return true
    }

    /// Check each new proof (by content) of a waiting, pending or weighed
    /// header, up to `maxPerHeader` from one header, within the operator's
    /// byte budget for proofs in a check; over it, a proof is dropped without
    /// blame, taken again only if a peer sends it again. A proof whose grind
    /// a derivation credits instead (`derives`) is not checked. The step's
    /// checks run as one job (`finish`).
    mutating func offer(_ proofs: [ChildBlockProof], cid: String, from source: PeerID, _ turn: inout Turn) {
        // Work crediting a block beyond the finality window is declined.
        if pastFinality(cid) { return }
        // Grinds not yet credited first, so a header served again with the
        // same proofs offers the ones a cap left out.
        var fresh: [ChildBlockProof] = []
        for proof in proofs where !credits(proof.rootCID, at: cid) && !derives(proof.rootCID, at: cid) {
            fresh.append(proof)
        }
        var held = sync.proofs.verifyingBytes
        for proof in fresh.prefix(proofConfig.maxPerHeader) {
            guard let bytes = try? proof.serialize(), bytes.count <= proofConfig.maxProofBytes else { continue }
            let id = "\(UInt256.hash(bytes))"
            let queued = QueuedChildProof(cid: cid, proof: proof, id: id, source: source, bytes: bytes.count)
            guard sync.proofs.verifying[queued.key] == nil else { continue }
            guard held + queued.bytes <= proofConfig.maxQueuedBytes else { continue }
            held += queued.bytes
            sync.proofs.startCheck(queued)
            turn.checks.append(ChildProofJob(
                childCID: cid,
                block: sync.proofs.awaiting[cid]?.block ?? sync.pending.entries[cid]?.block,
                proof: proof, proofID: id, chainPath: chainPath
            ))
        }
    }

    /// Whether a derivation credits `grind` at `cid` (the work facts of
    /// docs/design/sync-architecture.md: work comes from the parent once it
    /// has weighed the carrier):
    /// a parent-level block committing `cid` holds that grind, and `cid`'s
    /// derivation is in flight or is issued at the end of this step (it
    /// arrived in it). A derived proof and a peer's proof of one grind at
    /// one block are the same path from the same root, so they verify
    /// alike; a peer's is checked only when no derivation will answer (one
    /// that ran and credited nothing, for content it could not read, leaves
    /// the peer's to be checked when it is sent again).
    func derives(_ grind: String, at cid: String) -> Bool {
        guard let parentTree, sync.proofs.deriving[cid] != nil || arrived.contains(cid) else { return false }
        return parentTree.committers(of: cid, directory: chainPath[chainPath.count - 1]).contains { carrier in
            guard let meta = parentTree.getConsensusBlock(hash: carrier) else { return false }
            return meta.workContributions[grind] != nil && !meta.attributedRuns.contains(grind)
        }
    }

    mutating func credits(_ grind: String, at cid: String) -> Bool {
        sync.pending.entries[cid]?.evidence[grind] != nil
            || (tree.contains(blockHash: cid) && tree.workContribution(id: grind, at: cid) != nil)
    }

    /// Whether `cid` is a header held here waiting for its work, with a
    /// check or a derivation of it in flight: its answer weighs it or frees
    /// it (`released`), so a pending child of it does not ask a peer for it
    /// and its ancestors meanwhile. Asked, a peer serves the header again
    /// with a page of ancestors this node mostly holds.
    func awaitsItsWork(_ cid: String) -> Bool {
        sync.proofs.awaiting[cid] != nil && sync.proofs.holds(cid)
    }

    /// A check or a derivation of `cid` answered. If it still waits, with
    /// nothing more in flight, the pending headers whose parent it is look
    /// again: one may now ask a peer for it.
    mutating func released(_ cid: String, _ turn: inout Turn) {
        guard sync.proofs.awaiting[cid] != nil, !sync.proofs.holds(cid) else { return }
        for child in (sync.pending.childrenOf[cid] ?? []).sorted() { dirty(child, &turn) }
    }

    /// A peer is gone (for any reason): its announcements end. Its proofs in
    /// a check still answer.
    mutating func dropProofSource(_ peer: PeerID) {
        for cid in sync.proofs.awaiting.keys.sorted() {
            sync.proofs.awaiting[cid]?.announcers.removeAll { $0 == peer }
        }
    }

    // MARK: - Results

    /// A verify job's answers, applied in one step: each as `proofVerified`,
    /// one whose block was not held freeing its place, blaming no one. A
    /// failing proof disconnects its sender; the page's other proofs that
    /// verify still credit, since each verdict is its proof's own.
    mutating func proofsVerified(_ answers: [ChildProofAnswer], _ turn: inout Turn) {
        for answer in answers {
            if let result = answer.result {
                proofVerified(answer.job, result, &turn)
            } else {
                _ = sync.proofs.endCheck(answer.job.key)
            }
            released(answer.job.childCID, &turn)
        }
    }

    /// A proof that weighs credits its grind: at a weighed block at once
    /// (persisted, indexed, relayed), on a pending header when it is weighed,
    /// and a waiting header enters the pending queue with it. A proof that
    /// fails — malformed, or no work for this block — is a proof-of-work
    /// failure: the peer that sent it is disconnected; a derived proof
    /// blames no one.
    mutating func proofVerified(
        _ job: ChildProofJob,
        _ result: Result<VerifiedChildEvidence, ChildProofVerificationFailure>,
        _ turn: inout Turn
    ) {
        var source: PeerID?
        if !job.derived {
            guard let checked = sync.proofs.endCheck(job.key) else { return }
            source = checked.source
        }
        let cid = job.childCID
        guard case .success(let evidence) = result, evidence.childCID == cid,
              let work = evidence.contribution, work.work > .zero else {
            if let peer = source { disconnect(peer, .proofOfWorkInvalid, &turn) }
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
    /// weighed at once when its parent is. As there, a peer that sent a
    /// header holds its ancestors: it inherits the announcers of its pending
    /// children (which wait on it rather than ask for it while its work is
    /// checked), and its own announcers announce its pending parent.
    mutating func promote(_ waiting: AwaitingChildProof, evidence: VerifiedChildEvidence, proof: ChildBlockProof, _ turn: inout Turn) {
        let cid = waiting.blockCID
        var announcers = waiting.announcers
        for child in (sync.pending.childrenOf[cid] ?? []).sorted() {
            for other in sync.pending.entries[child]?.announcers ?? [] where !announcers.contains(other) {
                announcers.append(other)
            }
        }
        var header = PendingHeader(
            blockCID: cid,
            block: waiting.block,
            children: waiting.children,
            spec: waiting.spec,
            hash: evidence.rootHash,
            bytes: Self.size(of: waiting.block) + (waiting.children.map(Self.size) ?? 0)
                + ((try? proof.serialize().count) ?? 0),
            announcers: announcers
        )
        header.evidence[evidence.grindID] = evidence
        header.proofs[evidence.grindID] = proof
        sync.pending.insert(header)
        for peer in announcers { sync.announced[peer, default: []].insert(cid) }
        dirty(cid, &turn)
        if let parent = waiting.block.parent?.rawCID {
            for peer in announcers { announce(parent, by: peer, &turn) }
        }
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
    /// return every proof it now weighs by, to index and log. Its proofs in a
    /// check answer against the weighed block.
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
        turn.own = true
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
        var jobs: [ChildDeriveJob] = []
        for pair in pairs.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            let (carrier, child) = (pair[0], pair[1])
            guard tree.contains(blockHash: child) || sync.proofs.awaiting[child] != nil || sync.pending.entries[child] != nil,
                  !sync.declined.contains(child), let meta = parent.getConsensusBlock(hash: carrier) else { continue }
            let grinds = meta.workContributions.keys.filter { !meta.attributedRuns.contains($0) }
            let owed = Set(grinds.filter { !credits($0, at: child) })
            guard !owed.isEmpty else { continue }
            sync.proofs.startDeriving(child)
            jobs.append(ChildDeriveJob(
                childCID: child,
                block: sync.proofs.awaiting[child]?.block ?? sync.pending.entries[child]?.block,
                carrier: carrier, grinds: owed, chainPath: chainPath
            ))
        }
        // One effect for the step's derivations, as for its proof checks.
        return jobs.isEmpty ? [] : [.deriveProofs(jobs)]
    }

    /// A derivation's checks: each judged as a derived proof.
    mutating func derived(_ derivation: ChildDerivation, _ turn: inout Turn) {
        for (check, result) in derivation.checks { proofVerified(check, result, &turn) }
    }
}
