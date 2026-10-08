import Lattice
import cashew
import LatticeNodeCore
import UInt256

/// The "Lattice architecture preserved" checklist at every level of a host,
/// after every step:
///
/// - the weighed graph is the durable headers; invalid subtrees still weigh;
///   work is never revoked;
/// - each grind has one location and weighs what its proof verifies (root:
///   its own work; child: its root's `verifySecuringWork` contribution, one
///   per root) or the parent's attributed run, never more;
/// - hierarchical GHOST: the head is an independent reference's over those
///   grinds; validity selects (no excluded block on the best chain);
/// - the executed set is a subset of the weighed graph, closed under
///   ancestry, never shrinking, outside every excluded subtree, and holds no
///   invalid block. A level executes along its best chain and the
///   alternatives at forks on the chain it acts on, so a side branch it
///   never followed stays unexecuted, and an invalid block there stays
///   unexcluded;
/// - continuity: every executed child block's parent state was produced by
///   an executed parent block (any branch);
/// - weighed-only blocks issue no facts: validations only for executed
///   blocks;
/// - the root-exclusion rule;
/// - durability precedes visibility, and sync state stays bounded.
public enum LevelInvariants {
    public static func check(
        node: String,
        host: NodeCore,
        digests: [ChainPath: TreeDigest],
        previous: [ChainPath: TreeDigest],
        store: HostStore,
        world: LevelWorld
    ) throws {
        for path in host.ordered {
            guard let core = host.levels[path], let digest = digests[path],
                  let level = store.levels[path] else {
                throw Invariants.fail(node, "level \(path) has no digest or store")
            }
            let name = "\(node)\(path.dropFirst().map { "/" + $0 }.joined())"
            try checkLevel(name, path: path, host: host, core: core, digest: digest,
                           previous: previous[path], store: level, digests: digests, world: world)
        }
    }

    static func checkLevel(
        _ node: String,
        path: ChainPath,
        host: NodeCore,
        core: ChainCore,
        digest: TreeDigest,
        previous: TreeDigest?,
        store: SimStore,
        digests: [ChainPath: TreeDigest],
        world: LevelWorld
    ) throws {
        let fail = { (detail: String) in Invariants.fail(node, detail) }
        guard Set(digest.blocks.keys) == Set(store.headers.keys) else {
            throw fail("the weighed graph is not the set of durable headers")
        }
        if let missing = digest.blocks.keys.first(where: { !store.blockFacts.contains($0) }) {
            throw fail("weighed block \(missing) has no durable block fact")
        }
        let truth = world.blocks[path] ?? [:]
        if let stranger = digest.blocks.keys.first(where: { truth[$0] == nil }) {
            throw fail("weighed block \(stranger) was never mined")
        }
        // Availability never becomes invalidity: only a block whose
        // execution is invalid is excluded.
        if let wrong = digest.excluded.first(where: { !(world.invalid[path] ?? []).contains($0) }) {
            throw fail("excludes \(wrong), which is valid")
        }

        // Grinds: one location each, and each explained.
        let attributed = attributedRuns(at: path, host: host, digests: digests, world: world)
        var located: [String: String] = [:]
        for (hash, entry) in digest.blocks {
            for (grind, work) in entry.grinds {
                if let other = located.updateValue(hash, forKey: grind) {
                    throw fail("grind \(grind) is credited at \(other) and \(hash)")
                }
                if path.count == 1 {
                    guard grind == hash, work == workForTarget(truth[hash]!.block.target) else {
                        throw fail("block \(hash) weighs \(grind): \(work), not its own proof-of-work")
                    }
                } else if let proof = world.proofs[path]?[hash]?[grind] {
                    guard work == proof.evidence.contribution?.work else {
                        throw fail("grind \(grind) at \(hash) weighs \(work), its proof \(String(describing: proof.evidence.contribution?.work))")
                    }
                } else if let run = attributed[hash]?[grind] {
                    guard work <= run else {
                        throw fail("the attributed run \(grind) at \(hash) weighs \(work), over its parent's \(run)")
                    }
                } else {
                    throw fail("grind \(grind) at \(hash) is neither a proof's nor an attributed run")
                }
            }
        }

        // Hierarchical GHOST over those grinds; validity selects.
        var reference = GhostReference(genesis: digest.genesis)
        reference.excluded = digest.excluded
        for (hash, entry) in digest.blocks.sorted(by: { $0.key < $1.key }) {
            reference.add(hash, parent: entry.parent, grinds: entry.grinds)
        }
        let descent = reference.descent()
        // A level with no root weighed yet has no head.
        guard digest.blocks.isEmpty || (descent.head == digest.canonicalTip && descent.path == digest.canonicalPath) else {
            throw fail("head \(digest.canonicalTip) is not the GHOST reference's \(descent.head)")
        }
        let work = reference.subtreeWork()
        for (hash, entry) in digest.blocks where entry.subtreeWork != work[hash] {
            throw fail("subtree work of \(hash) is \(String(describing: entry.subtreeWork)), reference \(String(describing: work[hash]))")
        }
        if let excludedOnPath = digest.canonicalPath.first(where: digest.excluded.contains) {
            throw fail("the best chain enters excluded root \(excludedOnPath)")
        }

        // Work is never revoked; the executed set never shrinks.
        if let previous {
            for (hash, before) in previous.blocks {
                guard let now = digest.blocks[hash] else { throw fail("weighed block \(hash) left the graph") }
                for (grind, work) in before.grinds where (now.grinds[grind] ?? .zero) < work {
                    throw fail("grind \(grind) at \(hash) lost work")
                }
            }
            if !previous.executed.isSubset(of: digest.executed) { throw fail("the executed set shrank") }
        }

        // The executed set: in the weighed graph, closed under ancestry,
        // outside every excluded subtree.
        for hash in digest.executed {
            guard let entry = digest.blocks[hash] else { throw fail("executed block \(hash) is not weighed") }
            if let parent = entry.parent, !digest.executed.contains(parent) {
                throw fail("executed block \(hash) has an unexecuted parent")
            }
            if digest.excluded.contains(hash) { throw fail("executed block \(hash) is excluded") }
            if (world.invalid[path] ?? []).contains(hash) { throw fail("executed block \(hash) is invalid") }
        }

        // Continuity against any executed parent state.
        if path.count > 1, let facts = host.parentFacts(for: path) {
            let parentPath = Array(path.dropLast())
            for hash in digest.executed where digest.blocks[hash]?.height != 0 {
                // A block committing no parent state (`emptyHeader`) needs no
                // fact, as in Lattice's `validateParentFacts`.
                let parentState = truth[hash]!.block.parentState.rawCID
                guard parentState != LatticeState.emptyHeader.rawCID else { continue }
                let link = ParentStateContinuityLink(
                    parentPath: parentPath,
                    fromStateCID: LatticeState.emptyHeader.rawCID,
                    toStateCID: parentState
                )
                guard facts.hasContinuity(link) else {
                    throw fail("executed \(hash) has no executed parent block producing its parent state")
                }
            }
        }

        // Weighed-only blocks issue no facts.
        for hash in store.validations where !digest.executed.contains(hash) {
            throw fail("unexecuted block \(hash) has a durable validation")
        }
        for hash in store.exclusions where !digest.excluded.contains(hash) {
            throw fail("durable exclusion of \(hash) is not in the tree")
        }

        // The root-exclusion rule.
        for hash in digest.excluded where digest.blocks[hash]?.parent == nil {
            if !digest.executed.contains(where: { $0 != hash && digest.blocks[$0]?.parent == nil }) {
                throw fail("root \(hash) is excluded with no other executed root")
            }
        }

        // The act-on tip, publication, and bounded sync state.
        if core.snapshot.actOnTip != digest.actOnTip {
            throw fail("act-on tip \(core.snapshot.actOnTip) is not \(digest.actOnTip)")
        }
        if let published = core.published, published != core.snapshot {
            throw fail("published snapshot is stale after the step")
        }
        if core.sync.pending.bytes > core.config.pendingBudget {
            throw fail("the pending queue holds \(core.sync.pending.bytes) bytes, over its budget")
        }
        // The plain proof caps.
        let proofs = core.sync.proofs, bounds = core.config.proofs
        let held = proofs.queued + Array(proofs.verifying.values)
        if proofs.checks(index: false) > bounds.maxChecks || proofs.checks(index: true) > bounds.indexChecks {
            throw fail("proof checks in flight exceed their bounds")
        }
        if proofs.awaiting.count > bounds.maxAwaiting {
            throw fail("\(proofs.awaiting.count) headers await a proof, over the bound")
        }
        if held.contains(where: { $0.bytes > bounds.maxProofBytes }) {
            throw fail("a proof larger than the per-proof bound is held")
        }
        var load: [PeerID?: (count: Int, bytes: Int)] = [:]
        for proof in held {
            let current = load[proof.source] ?? (0, 0)
            load[proof.source] = (current.count + 1, current.bytes + proof.bytes)
        }
        for (source, used) in load {
            guard used.count <= bounds.maxPerSource, used.bytes <= bounds.maxSourceBytes else {
                throw fail("source \(String(describing: source)) holds \(used.count) proofs, \(used.bytes) bytes, over its caps")
            }
            if let peer = source, core.sync.peers[peer] == nil {
                throw fail("proofs of the gone peer \(peer) are still held")
            }
        }
        if core.sync.pending.entries.values.contains(where: { path.count > 1 && $0.evidence.isEmpty }) {
            throw fail("a child header with no verified work is in the pending queue")
        }
        if core.sync.pending.entries.keys.contains(where: digest.blocks.keys.contains) {
            throw fail("a weighed header is still pending")
        }
    }

    /// Per child block: each attributed-run identity its parent's committers
    /// credit it under, and the parent's run beyond the committer's own
    /// grinds, recomputed from the parent's digest: a parent block's run is
    /// that of its nearest ancestor (itself included) committing into the
    /// directory, and a run is its blocks' total credited work.
    static func attributedRuns(
        at path: ChainPath, host: NodeCore, digests: [ChainPath: TreeDigest], world: LevelWorld
    ) -> [String: [String: UInt256]] {
        let parentPath = Array(path.dropLast())
        guard path.count > 1, let parent = host.levels[parentPath],
              let parentDigest = digests[parentPath] else { return [:] }
        let directory = path[path.count - 1]
        var commits: [String: String] = [:]
        for hash in parentDigest.blocks.keys {
            if let child = parent.tree.recordedChildCommitments(of: hash)?[directory] {
                commits[hash] = CIDIdentity.canonicalString(child) ?? child
            }
        }
        var run: [String: UInt256] = [:]
        for (hash, entry) in parentDigest.blocks {
            var current: String? = hash
            while let block = current, commits[block] == nil { current = parentDigest.blocks[block]?.parent }
            guard let committer = current else { continue }
            run[committer, default: UInt256.zero] += entry.grinds.values.reduce(UInt256.zero, +)
        }
        var runs: [String: [String: UInt256]] = [:]
        for (committer, total) in run {
            let own = parentDigest.blocks[committer]?.grinds.filter {
                $0.key == committer || world.proofs[parentPath]?[committer]?[$0.key] != nil
            }.values.reduce(UInt256.zero, +) ?? UInt256.zero
            guard let child = commits[committer], total > own,
                  let id = AttributedRunIdentity(carrierBlockHash: committer, directory: directory).contributionID
            else { continue }
            runs[child, default: [:]][id] = total - own
        }
        return runs
    }

    /// Where a level stopped executing its best chain: at the head, or at
    /// a child block awaiting a parent fact its parent level still lacks.
    /// A fact the parent holds there is a lost wake.
    public static func checkExecutionStop(_ name: String, path: ChainPath, host: NodeCore, digest: TreeDigest) throws {
        let executedPrefix = digest.canonicalPath.prefix { digest.executed.contains($0) }.count
        if executedPrefix < digest.canonicalPath.count {
            let next = digest.canonicalPath[executedPrefix]
            guard let fact = host.levels[path]?.bodies.awaitingParent[next] else {
                throw Invariants.fail(name, "stopped executing the best chain at \(path) before \(next), which awaits no parent fact")
            }
            // A fact its parent level now holds is a lost wake.
            if host.parentFacts(for: path)?.holds(fact) != false {
                throw Invariants.fail(name, "lost wake: \(next) at \(path) still awaits \(fact), which its parent level holds")
            }
        }
    }

    /// After the quiet point: every honest core hosts every level, and at
    /// each holds the identical weighed graph (blocks, grinds, subtree work)
    /// and head, every block mined publicly, and each attributed run in full.
    /// Each has executed its best chain to the head, or up to a child block
    /// awaiting a parent fact its parent level still lacks (decision 21);
    /// a fact the parent holds means a lost wake.
    /// Executed sets and exclusions may differ: each core executed the best
    /// chains it followed.
    public static func checkQuietPoint(
        _ cores: [String: (host: NodeCore, digests: [ChainPath: TreeDigest])],
        world: LevelWorld,
        now: Int64,
        withheldShown: Bool
    ) throws {
        let names = cores.keys.sorted()
        guard let first = names.first else { return }
        for path in world.paths {
            guard let reference = cores[first]?.digests[path] else {
                throw Invariants.fail(first, "never ran level \(path)")
            }
            let public_ = world.released(path, at: now, withheld: withheldShown).filter {
                path.count == 1 || !world.publicProofs(path, $0.cid, at: now).isEmpty
            }
            for name in names {
                guard let (host, digests) = cores[name], let digest = digests[path] else {
                    throw Invariants.fail(name, "never ran level \(path) after the quiet point")
                }
                if let missing = public_.first(where: { digest.blocks[$0.cid] == nil }) {
                    let pending = host.levels[path]?.sync.pending.entries[missing.cid]
                    let detail = "height \(missing.height), parent held \(missing.parent.map { digest.blocks[$0] != nil } ?? true), "
                        + "pending \(pending != nil) with \(pending?.evidence.count ?? 0) grinds and children \(pending?.children != nil), "
                        + "withheld \(world.isWithheld(path, missing.cid)), level hosts \(host.levels[path] != nil)"
                    throw Invariants.fail(name, "misses \(missing.cid) at \(path) after the quiet point: \(detail)")
                }
                guard digest.blocks == reference.blocks else {
                    let differing = Set(digest.blocks.keys).union(reference.blocks.keys)
                        .filter { digest.blocks[$0] != reference.blocks[$0] }.sorted()
                    let root = differing.filter {
                        digest.blocks[$0]?.grinds != reference.blocks[$0]?.grinds || digest.blocks[$0] == nil || reference.blocks[$0] == nil
                    }
                    let detail = "\(differing.count) differ, \(root.count) in grinds or presence; " + (root.isEmpty ? differing : root).prefix(3).map { cid in
                        let mine = digest.blocks[cid], theirs = reference.blocks[cid]
                        let ids = Set(mine?.grinds.keys.map { $0 } ?? []).union(theirs?.grinds.keys.map { $0 } ?? [])
                        let odd = ids.filter { mine?.grinds[$0] != theirs?.grinds[$0] }
                        let kinds = odd.map {
                            (world.proofs[path]?[cid]?[$0] != nil ? "proof " : "run ")
                                + "\(String(describing: mine?.grinds[$0])) vs \(String(describing: theirs?.grinds[$0]))"
                        }.sorted()
                        return "\(cid) h\(mine?.height ?? 0): odd grinds \(kinds), grinds \(mine?.grinds.keys.sorted() ?? []) vs \(theirs?.grinds.keys.sorted() ?? []), "
                            + "subtree \(String(describing: mine?.subtreeWork)) vs \(String(describing: theirs?.subtreeWork))"
                    }.joined(separator: "; ")
                    throw Invariants.fail(name, "weighs a different graph at \(path) than \(first) after the quiet point: \(detail)")
                }
                guard digest.canonicalTip == reference.canonicalTip else {
                    throw Invariants.fail(name, "selects differently at \(path) than \(first)")
                }
                try checkExecutionStop(name, path: path, host: host, digest: digest)
                // Every public honest proof of a held block is credited.
                for (cid, roots) in world.proofs[path] ?? [:] where digest.blocks[cid] != nil {
                    for (root, truth) in roots where truth.releaseAt <= now && digest.blocks[cid]?.grinds[root] == nil {
                        throw Invariants.fail(name, "never credited the grind \(root) at \(cid) at \(path)")
                    }
                }
                let runs = attributedRuns(at: path, host: host, digests: digests, world: world)
                for (hash, entry) in digest.blocks {
                    for (id, run) in runs[hash] ?? [:] where run > .zero && entry.grinds[id] != run {
                        throw Invariants.fail(name, "credits \(String(describing: entry.grinds[id])) of the attributed run \(run) at \(hash)")
                    }
                }
            }
        }
    }
}
