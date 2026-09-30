import Lattice
import UInt256

/// A child proof by the block it weighs and its root: one grind at one block.
public struct ProofKey: Hashable, Comparable, Sendable {
    public let childCID: String
    public let rootCID: String

    public init(childCID: String, rootCID: String) {
        self.childCID = childCID
        self.rootCID = rootCID
    }

    public static func < (lhs: ProofKey, rhs: ProofKey) -> Bool {
        lhs.childCID != rhs.childCID ? lhs.childCID < rhs.childCID : lhs.rootCID < rhs.rootCID
    }
}

/// One proof check the shell runs off the step: `verifySecuringWork` of
/// `proof` for `block` on the level's chain. Pure over its inputs, so its
/// answer is never stale.
public struct ProofJob: Sendable {
    public let childCID: String
    public let block: Block
    public let proof: ChildBlockProof
    public let chainPath: [String]

    public var key: ProofKey { ProofKey(childCID: childCID, rootCID: proof.rootCID) }

    public func run() async -> Result<VerifiedChildEvidence, ChildProofVerificationFailure> {
        await proof.verifySecuringWork(child: block, chainPath: chainPath)
    }
}

/// A child level's header is its block and a `ChildBlockProof` per root that
/// carries it. It waits in the pending queue until one proof verifies and
/// weighs; the rest credit their grinds with `addWork`, one per root. A proof
/// that does not weigh (malformed, or a root hash that misses the block's
/// target) blames no one; a missing proof is a liveness wait, looked up in
/// the evidence index again whenever the index changes.
extension Core {
    var isRoot: Bool { tree.context?.isRoot ?? true }

    var chainPath: [String] { tree.context?.path ?? [] }

    /// Verify the proofs a header came with: one job per root that is neither
    /// credited nor in flight, within the per-header and in-flight bounds.
    mutating func offerProofs(_ proofs: [ChildBlockProof], for block: Block, cid: String, _ turn: inout Turn) {
        var roots = Set<String>()
        for proof in proofs.prefix(config.maxProofsPerHeader) where roots.insert(proof.rootCID).inserted {
            let job = ProofJob(childCID: cid, block: block, proof: proof, chainPath: chainPath)
            guard sync.verifying.count < config.maxProofChecks,
                  !sync.verifying.contains(job.key),
                  sync.pending.entries[cid]?.evidence[proof.rootCID] == nil,
                  !credits(proof.rootCID, at: cid) else { continue }
            sync.verifying.insert(job.key)
            turn.effects.append(.verifyProof(job))
        }
    }

    mutating func credits(_ grind: String, at cid: String) -> Bool {
        tree.getConsensusBlock(hash: cid)?.workContributions[grind] != nil
    }

    /// The evidence index's proofs for a header still waiting.
    mutating func proofsFound(_ proofs: [ChildBlockProof], for cid: String, _ turn: inout Turn) {
        guard let header = sync.pending.entries[cid] else { return }
        offerProofs(proofs, for: header.block, cid: cid, &turn)
    }

    /// A proof that weighs credits its grind: on a weighed block at once (its
    /// work fact persisted, the proof indexed and relayed), on a waiting
    /// header once it is weighed.
    mutating func proofVerified(
        _ job: ProofJob,
        _ result: Result<VerifiedChildEvidence, ChildProofVerificationFailure>,
        _ turn: inout Turn
    ) {
        guard sync.verifying.remove(job.key) != nil else { return }
        guard case .success(let evidence) = result,
              evidence.childCID == job.childCID,
              let work = evidence.contribution, work.work > .zero else { return }
        if tree.contains(blockHash: job.childCID) {
            guard case .applied(let update) = tree.addWork(work, to: job.childCID) else { return }
            turn.facts += update.batches
            turn.indexed.append((job.childCID, job.proof))
            turn.relays.append((HeaderEntry(block: job.block, children: nil, proofs: [job.proof]), from: nil))
        } else if let header = sync.pending.entries[job.childCID], header.evidence[evidence.grindID] == nil {
            let size = (try? job.proof.serialize().count) ?? 0
            sync.pending.entries[job.childCID]?.evidence[evidence.grindID] = evidence
            sync.pending.entries[job.childCID]?.proofs[evidence.grindID] = job.proof
            sync.pending.entries[job.childCID]?.hash = min(header.hash, evidence.rootHash)
            sync.pending.entries[job.childCID]?.bytes += size
            sync.pending.bytes += size
            sync.pending.evict(to: config.pendingBudget)
        }
    }

    mutating func evidenceChanged() {
        for cid in sync.pending.entries.keys {
            sync.pending.entries[cid]?.lookedUp = false
        }
    }

    /// Ask the evidence index, once per index change, for every waiting
    /// header with no proof in hand or in flight: one batch per step.
    mutating func requestProofs(_ turn: inout Turn) {
        let inFlight = Set(sync.verifying.map(\.childCID))
        let wanted = sync.pending.entries.values
            .filter { $0.evidence.isEmpty && !$0.lookedUp && !inFlight.contains($0.blockCID) }
            .map(\.blockCID)
            .sorted()
        guard !wanted.isEmpty else { return }
        for cid in wanted { sync.pending.entries[cid]?.lookedUp = true }
        turn.effects.append(.lookupProofs(wanted))
    }

    /// Weigh a waiting child header with its strongest-hash grind.
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
    /// return every proof it now weighs by, to index and relay.
    mutating func creditRemainingProofs(of header: PendingHeader, _ turn: inout Turn) -> [ChildBlockProof] {
        guard !isRoot else { return [] }
        var credited: [ChildBlockProof] = []
        for (root, evidence) in header.evidence.sorted(by: { $0.key < $1.key }) {
            guard let work = evidence.contribution, let proof = header.proofs[root] else { continue }
            if !credits(root, at: header.blockCID) {
                guard case .applied(let update) = tree.addWork(work, to: header.blockCID) else { continue }
                turn.facts += update.batches
            }
            credited.append(proof)
            turn.indexed.append((header.blockCID, proof))
        }
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
        let held = tree.contains(blockHash: cid)
        let admission: ChainTreeAdmission
        if isRoot {
            admission = tree.insertRootHeader(block, childIndex: children, validationContext: context)
        } else {
            guard let proof, evidence(proof.evidence, weighs: cid),
                  let work = proof.evidence.contribution else { return [] }
            admission = held
                ? tree.addWork(work, to: cid)
                : tree.insertChildHeader(block, childIndex: children, evidence: proof.evidence, validationContext: context)
        }
        guard case .applied(let update) = admission else { return [] }
        if !held {
            sync.pending.remove(cid)
            turn.headers.append(StoredHeader(blockCID: cid, block: block, children: children))
            if let parent = block.parent?.rawCID { leaves.remove(parent) }
            leaves.insert(cid)
        }
        turn.facts += update.batches
        if let proof { turn.indexed.append((cid, proof.proof)) }
        turn.relays.append((
            config.entry(block, children: children, proofs: proof.map { [$0.proof] } ?? []),
            from: nil
        ))
        advance(&turn)
        return finish(turn)
    }

    func evidence(_ evidence: VerifiedChildEvidence, weighs cid: String) -> Bool {
        evidence.childCID == cid && (evidence.contribution?.work ?? .zero) > .zero
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
