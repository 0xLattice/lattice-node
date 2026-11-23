import Crypto
import Foundation
import Ivy
import Lattice
import LatticeNodeCore
import cashew
import UInt256
import VolumeBroker
import LatticeNodeAPI

extension NodeRuntime {
    /// The basis of a preflight or template job on `tree`, the live level's,
    /// taken when the job is spawned; nil for any other effect, or a tree
    /// made without a context.
    static func miningBasis(_ effect: MiningEffect, tree: ChainTree, parent: ChainCore? = nil) -> MiningBasis? {
        let (tip, anchored): (String, Bool)
        switch effect {
        case .preflight(let job): (tip, anchored) = (job.tipCID, false)
        case .buildTemplate(let job): (tip, anchored) = (job.tipCID, true)
        default: return nil
        }
        guard tree.context != nil else { return nil }
        let parentState = anchored ? nil : parent.flatMap { parent in
            parent.tree.transactionPreflightTip(at: parent.snapshot.actOnTip).snapshot
                .map { LatticeStateHeader(rawCID: $0.postStateCID) }
        }
        return MiningBasis(
            snapshot: tree.transactionPreflightTip(at: tip).snapshot, anchor: anchored ? anchor(tree, tip) : nil,
            parentState: parentState
        )
    }

    /// `tip`'s difficulty anchor, read from `tree`.
    static func anchor(_ tree: ChainTree, _ tip: String) -> DifficultyAnchor? {
        tree.difficultyAnchor(forBlockHash: tip)
    }

    /// The worker job for a mining effect that needs one: Lattice preflight
    /// and the template assembly on the job's `basis`, child templates
    /// reading the live `levels`, and the read of a tip move's blocks, which
    /// is tied to no tip (a returned transaction is a candidate on any tip,
    /// and its preflight decides).
    static func miningJob(
        _ effect: MiningEffect,
        at path: ChainPath,
        basis: MiningBasis?,
        storage: NodeStorage,
        remote: IvyRootContentSource? = nil,
        children: [ChildTemplateInput] = [],
        hosted: [ChainPath]? = nil,
        levels: LiveLevels = .none,
        cache: ChildTemplateCache? = nil
    ) -> RuntimeJob {
        // A template carries the levels below: its work reads their stores.
        let fetcher = storage.workFetcher(.subtree(path))
        switch effect {
        case .preflight(let job):
            // An admission always runs: its verdict counts on any tip
            // (`PreflightJob`).
            return RuntimeJob(
                path: path, tipCID: job.checksPolicies ? nil : job.tipCID, kind: job.awaited ? .answered : .other
            ) {
                guard let basis else { preconditionFailure("every hosted level's tree carries a context: a preflight has a basis") }
                // A child withdrawal is proven against the parent's executed
                // state, so it is ready, invalid or a retry, never held
                // unchecked.
                let judge: @Sendable (any Fetcher) async -> (MempoolDisposition, [String: UInt64]) = { fetcher in
                    let result = await TransactionPreflight.classify(
                        job.transaction, tipCID: job.tipCID, snapshot: basis.snapshot, chainPath: path,
                        parentState: basis.parentState, fetcher: fetcher, validationContext: .current,
                        checksPolicies: job.checksPolicies,
                        checksSignatures: job.checksPolicies
                    )
                    // A ready transaction brings the balances it was funded
                    // from, read from the same tip state, for the pool's budget.
                    var verdict = disposition(result.disposition)
                    if verdict == .ready, let body = job.transaction.body.node, let snapshot = basis.snapshot,
                       !carriesChildCommitments(body, entering: snapshot.postStateCID) {
                        verdict = .invalid
                    }
                    var balances: [String: UInt64] = [:]
                    if verdict == .ready {
                        if let body = job.transaction.body.node,
                           let snapshot = basis.snapshot,
                           let state = try? await LatticeStateHeader(rawCID: snapshot.postStateCID).resolve(fetcher: fetcher).node,
                           let read = await Mempool.balances(debitedBy: body, on: state, fetcher: fetcher) {
                            balances = read
                        } else {
                            verdict = .unavailable
                        }
                    }
                    return (verdict, balances)
                }
                // From this store first: what it refuses (a bad signature,
                // the wrong chain, a stale nonce) costs no request to peers.
                // State is a cache, so a node of the tip's state this store
                // lacks is read as any work reads it, through peers, and the
                // transaction is judged again.
                var (verdict, balances) = await judge(fetcher)
                if verdict == .unavailable, remote != nil, basis.snapshot != nil {
                    (verdict, balances) = await reading(job.tipCID, at: path, storage: storage, remote: remote, judge)
                }
                return [.level(path, .mining(.preflighted(job, verdict, balances: balances)))]
            }
        case .buildTemplate(let job):
            // A build always runs: it is answered on any tip (`TemplateJob`).
            return RuntimeJob(path: path, tipCID: nil, kind: .answered) {
                let (built, refused) = await reading(job.tipCID, at: path, below: true, storage: storage, remote: remote) { fetcher in
                    var refused: [PolicyRefusal] = []
                    let built = await buildTemplate(
                        job, difficultyAnchor: basis?.anchor, fetcher: fetcher, chainPath: path,
                        children: children, hosted: hosted, levels: levels, cache: cache, refused: &refused
                    )
                    return (built, refused)
                }
                return refused.map { .level($0.path, .mining(.policyRefused(tipCID: $0.tipCID, cids: $0.cids))) }
                    + [.level(path, .mining(.templateBuilt(job, built)))]
            }
        case .returnTransactions(let left, let carried):
            return RuntimeJob(path: path, tipCID: nil) {
                var returned: [NodeEvent] = []
                for cid in left {
                    for transaction in await transactions(ofLeftBlock: cid, at: path, storage: storage, remote: remote)
                    where (try? Mempool.cid(of: transaction)).map({ !carried.contains($0) }) ?? false {
                        returned.append(.level(path, .mining(.transactionReceived(transaction, origin: .returned))))
                    }
                }
                return returned
            }
        default:
            preconditionFailure("\(effect) is not a job")
        }
    }

    /// `MiningEffect.buildTemplate`: today's assembly (the bisecting fit, the
    /// policy filter, the minimum-work search target) on the job's tip.
    /// Nil when no block can be built there. What the policy filter refused,
    /// root and children, is added to `refused`.
    static func buildTemplate(
        _ job: TemplateJob,
        difficultyAnchor: DifficultyAnchor?,
        fetcher: any Fetcher,
        chainPath: [String],
        children: [ChildTemplateInput] = [],
        hosted: [ChainPath]? = nil,
        levels: LiveLevels = .none,
        cache: ChildTemplateCache? = nil,
        refused: inout [PolicyRefusal]
    ) async -> TemplateBuild? {
        // Every hosted level, mined or not: a hosted directory is this
        // node's to mine, and carries no other's commitment.
        let hosted = hosted ?? children.map(\.path)
        guard job.request.parentCarrier == nil,
              let previous = try? await BlockHeader(rawCID: job.tipCID).resolve(fetcher: fetcher).node,
              let spec = try? await previous.spec.resolve(fetcher: fetcher).node,
              let timestamp = try? MiningPlan.nextTimestamp(after: previous.timestamp, parentCarrier: nil, now: Self.now())
        else { return nil }
        let (pooled, refusedHere) = await MiningPlan.policyAcceptedTransactions(
            job.transactions,
            chainPath: chainPath,
            previous: previous,
            timestamp: timestamp,
            spec: spec,
            fetcher: fetcher
        )
        if !refusedHere.isEmpty { refused.append(PolicyRefusal(path: chainPath, tipCID: job.tipCID, cids: refusedHere)) }
        let provided = await childCandidates(
            of: chainPath, among: children, entering: previous.postState, timestamp: timestamp,
            request: job.request, hosted: hosted, levels: levels, fetcher: fetcher, cache: cache, refused: &refused
        )
        guard let template = try? await MiningTemplateAssembly.fit(
            chainPath: chainPath,
            previous: previous,
            pooled: pooled,
            provided: provided,
            hosted: directories(below: chainPath, among: hosted),
            parentCarrier: nil,
            timestamp: timestamp,
            rewardRecipient: job.request.rewardRecipient,
            minimumWork: job.request.minimumWork,
            difficultyAnchor: difficultyAnchor,
            spec: spec,
            fetcher: fetcher
        ) else { return nil }
        return TemplateBuild(
            workID: template.workID,
            block: template.block,
            searchTarget: template.searchTarget,
            targets: template.targets,
            digest: templateDigest(
                tip: job.tipCID, carrying: job.transactions,
                levels: children.map { ($0.path, $0.tipCID ?? "", $0.weighed, $0.transactions) }
            ),
            chains: MiningTemplateAssembly.committedChains(root: template.block, chainPath: chainPath)
        )
    }

    /// A child's genesis paying its premine and carrying its creator's
    /// `transactions`, offered only if it is valid: a genesis mined and then
    /// refused would leave the chain weighing a root that never executes.
    static func childGenesis(
        spec: ChainSpec, premineTo recipient: String?, transactions: [Transaction] = [], path: ChainPath,
        parentState: LatticeStateHeader, timestamp: Int64, target: UInt256, fetcher: any Fetcher
    ) async throws -> Block? {
        let block = try await BlockBuilder.buildChildGenesis(
            spec: spec, parentState: parentState,
            transactions: try ChildGenesis.premine(spec: spec, to: recipient, on: path) + transactions,
            timestamp: timestamp, target: target, fetcher: fetcher
        )
        let (valid, _) = try await block.validateGenesis(fetcher: fetcher, chainPath: path)
        return valid ? block : nil
    }

    /// Whether a block on a tip entering `entering` can carry every child
    /// commitment (`child/X` = `C@P`) `body` makes: X a directory, C a
    /// standard CID, and P exactly `entering`. Read from the transaction
    /// alone: C is carried by CID, so a commitment never spends a request on
    /// its child. One into a directory this node hosts is relayed all the
    /// same; only this node's own templates leave it out.
    static func carriesChildCommitments(_ body: TransactionBody, entering: String) -> Bool {
        Block.childCommitments(in: [body]).allSatisfy { commitment in
            guard _isBoundedDirectoryAtom(commitment.directory),
                  let value = Block.childCommitmentValue(commitment.value),
                  CIDIdentity.isStandard(String(decoding: value.child, as: UTF8.self)) else { return false }
            return value.parentState.elementsEqual(entering.utf8)
        }
    }

    /// Whether `path` is mined: neither it nor a level above it, up to
    /// `root`, holds a backlog to execute (`ChainCore.holdsBacklog`). A
    /// child is carried only under its parent's block.
    static func mined(_ path: ChainPath, root: ChainPath, levels: [ChainPath: ChainCore]) -> Bool {
        (root.count...max(root.count, path.count)).allSatisfy {
            levels[Array(path.prefix($0))]?.holdsBacklog != true
        }
    }

    /// The directories directly below `parent` among the hosted `paths`.
    static func directories(below parent: ChainPath, among paths: [ChainPath]) -> Set<String> {
        Set(paths.filter { $0.dropLast().elementsEqual(parent) }.compactMap(\.last))
    }

    /// Merged mining: a candidate block for each hosted direct child of
    /// `parent`, each carrying its own children's, every one committing its
    /// carrier's entering state. A child with an executed tip builds on it;
    /// one with no root yet and a configured spec gets a genesis; one whose
    /// root is weighed but not executed waits.
    static func childCandidates(
        of parent: ChainPath,
        among inputs: [ChildTemplateInput],
        entering: LatticeStateHeader,
        timestamp: Int64,
        request: TemplateRequest,
        hosted: [ChainPath]? = nil,
        levels: LiveLevels,
        fetcher: any Fetcher,
        cache: ChildTemplateCache? = nil,
        refused: inout [PolicyRefusal]
    ) async -> [DirectChildCandidate] {
        let paths = hosted ?? inputs.map(\.path)
        var candidates: [DirectChildCandidate] = []
        // An excluded chain gets no candidate: its subtree, all excluded too
        // (`MiningPlan.validatedExclusions`), is never built.
        for input in inputs where input.path.dropLast().elementsEqual(parent) && !request.exclude.contains(input.path) {
            let carrier = Block(
                version: Block.currentVersion, parent: nil,
                transactions: HeaderImpl(rawCID: entering.rawCID), target: .max, nextTarget: .max,
                spec: VolumeImpl(rawCID: entering.rawCID), parentState: entering, prevState: entering,
                postState: entering, children: HeaderImpl(rawCID: entering.rawCID), height: 0,
                timestamp: timestamp, rewardRecipient: nil, nonce: 0
            )
            let block: Block?
            // A child's own template schedules its subtree: the block its
            // search target names below it, and every threshold there. Kept,
            // a grandchild's easier target reaches the root's search.
            var searchWitness: ChildSchedulingWitness?
            var subtreeThresholds: [UInt256]?
            if let tipCID = input.tipCID {
                // Building below the act-on tip: the block carries neither
                // the pool, which is kept on the act-on tip, nor children.
                guard let (tip, anchorBelow) = await anchoredTip(
                    from: tipCID, entering: entering.rawCID, at: input.path, levels: levels, fetcher: fetcher
                ),
                      let previous = try? await BlockHeader(rawCID: tip).resolve(fetcher: fetcher).node,
                      let spec = try? await previous.spec.resolve(fetcher: fetcher).node,
                      let time = try? MiningPlan.nextTimestamp(after: previous.timestamp, parentCarrier: carrier, now: Self.now())
                else { continue }
                let below = tip != tipCID
                let grandchildren = below ? [] : await childCandidates(
                    of: input.path, among: inputs, entering: previous.postState, timestamp: time,
                    request: request, hosted: paths, levels: levels, fetcher: fetcher, cache: cache, refused: &refused
                )
                let hosted = directories(below: input.path, among: paths)
                // Built from exactly this before: the block is reused, and
                // nothing here is judged or assembled again.
                let key = ChildTemplateCache.Key(
                    tipCID: tip, actOnTipCID: tipCID, enteringCID: entering.rawCID,
                    transactions: below ? [] : input.transactions.compactMap { try? Mempool.cid(of: $0) },
                    anchor: below ? anchorBelow : input.anchor, request: request, hosted: hosted.sorted(),
                    children: grandchildren.map { "\($0.directory)=\((try? BlockHeader(node: $0.block).rawCID) ?? "")" }
                )
                if let cached = cache?.block(at: input.path, for: key) {
                    block = cached.block
                    searchWitness = cached.searchWitness
                    subtreeThresholds = cached.subtreeThresholds
                } else {
                    let (pooled, refusedHere) = below ? ([], []) : await MiningPlan.policyAcceptedTransactions(
                        input.transactions, chainPath: input.path, previous: previous, timestamp: time,
                        spec: spec, fetcher: fetcher
                    )
                    if !refusedHere.isEmpty { refused.append(PolicyRefusal(path: input.path, tipCID: tipCID, cids: refusedHere)) }
                    let template = try? await MiningTemplateAssembly.fit(
                        chainPath: input.path, previous: previous,
                        pooled: pooled, provided: grandchildren,
                        hosted: hosted, parentCarrier: carrier,
                        timestamp: time, rewardRecipient: request.childRecipients[input.path],
                        minimumWork: request.minimumWork,
                        difficultyAnchor: below ? anchorBelow : input.anchor,
                        spec: spec, fetcher: fetcher
                    )
                    block = template?.block
                    searchWitness = template?.searchWitness
                    subtreeThresholds = template?.subtreeThresholds
                    // Refused transactions leave the pool, which changes the
                    // key, so a block built while refusing is never reused.
                    if let template, refusedHere.isEmpty {
                        cache?.keep(ChildTemplateCache.Entry(
                            key: key, builtAt: .now, block: template.block,
                            searchWitness: template.searchWitness, subtreeThresholds: template.subtreeThresholds
                        ), at: input.path)
                    }
                }
            } else if let spec = input.genesisSpec {
                // A genesis carries no children: a nested genesis commits its
                // carrier's entering state, and a genesis enters the empty
                // one, which no child genesis may name. Its children wait
                // until it executes.
                block = (try? await childGenesis(
                    spec: spec, premineTo: input.genesisPremineRecipient,
                    transactions: input.genesisTransactions, path: input.path,
                    parentState: entering, timestamp: timestamp, target: input.genesisTarget, fetcher: fetcher
                )) ?? nil
            } else {
                block = nil
            }
            if let block {
                candidates.append(DirectChildCandidate(
                    directory: input.path[input.path.count - 1], block: block,
                    searchWitness: searchWitness, subtreeThresholds: subtreeThresholds
                ))
            }
        }
        return candidates
    }

    /// The child tip to build on: `tipCID`, the act-on tip, when its anchor
    /// advances to `entering` in the parent's executed set (Lattice spec §5.3
    /// step 6: a child anchor only moves forward along the parent's history).
    /// After a parent reorganization the act-on tip may be anchored on the
    /// abandoned branch, and a block on it anchored at the canonical parent
    /// would be invalid; building on the heaviest tip it can extend instead
    /// is what moves the child with its parent. With the tip, its difficulty
    /// anchor when it is below `tipCID`.
    ///
    /// The levels are read live, all in one read (`childTip`): the tip is
    /// what one step's state gives, as a copy of the levels taken at that
    /// step would. What the walk needs of a block's content, the anchor it
    /// names, is read off the loop and the read made again: content never
    /// changes, so only the last read's state decides.
    ///
    /// `tipCID` when the parent is not hosted here; nil when no executed
    /// block's anchor advances to `entering`, a block cannot be read, or the
    /// levels no longer can.
    static func anchoredTip(
        from tipCID: String, entering: String, at path: ChainPath, levels: LiveLevels, fetcher: any Fetcher
    ) async -> (tip: String, anchor: DifficultyAnchor?)? {
        var anchors: [String: String] = [:]
        while true {
            let known = anchors
            switch await levels.read({
                childTip(from: tipCID, entering: entering, at: path, levels: $0, anchors: known)
            }) {
            case .tip(let tip, let anchor)?:
                return (tip, anchor)
            case .needs(let cid)?:
                guard let block = try? await BlockHeader(rawCID: cid).resolve(fetcher: fetcher).node else { return nil }
                anchors[cid] = block.parentState.rawCID
            case .noTip?, nil:
                return nil
            }
        }
    }

    /// `anchoredTip` over one step's `levels`, with the parent states the
    /// blocks it has read name (`anchors`); `.needs` a block it has not read.
    static func childTip(
        from tipCID: String, entering: String, at path: ChainPath,
        levels: [ChainPath: ChainCore], anchors: [String: String]
    ) -> ChildTip {
        guard let level = levels[path] else { return .noTip }
        guard let parent = levels[Array(path.dropLast())] else { return .tip(tipCID, anchor: nil) }
        var needs: String?
        let tip = level.actOnTip(from: tipCID) { tip in
            guard let from = anchors[tip] else {
                needs = tip
                return nil
            }
            return parent.tree.executedSetAdvanced(from: from, to: entering)
        }
        if let needs { return .needs(needs) }
        guard let tip else { return .noTip }
        return .tip(tip, anchor: tip == tipCID ? nil : anchor(level.tree, tip))
    }

    /// What one read of the levels gives `anchoredTip`.
    enum ChildTip: Sendable {
        case tip(String, anchor: DifficultyAnchor?)
        case noTip
        /// The parent state a block names, which the walk must know.
        case needs(String)
    }

    static func disposition(_ preflight: TransactionPreflightDisposition) -> MempoolDisposition {
        switch preflight {
        case .ready: .ready
        case .future: .future
        case .unavailable: .unavailable
        case .invalid: .invalid
        }
    }

    /// The digest of the template a build on `tip` carrying these (each
    /// level's `nextBlock`) would give: status and `GET /mining/events` name
    /// it, so a miner sees its template go stale. Each hosted level is named
    /// by path, so the hosted set changing changes it too, with what its
    /// candidate is built from: its act-on tip, its next block, and whether
    /// any block of it is weighed (until one is, its creator mines its
    /// genesis). Its best header is not named: no template reads it.
    static func templateDigest(
        tip: String, carrying: [Transaction],
        levels: [(path: ChainPath, actOn: String, weighed: Bool, carrying: [Transaction])] = []
    ) -> String {
        templateDigest(
            tip: tip,
            transactions: carrying.compactMap { try? Mempool.cid(of: $0) },
            levels: levels.map { ($0.path, $0.actOn, $0.weighed, $0.carrying.compactMap { try? Mempool.cid(of: $0) }) }
        )
    }

    static func templateDigest(
        tip: String,
        transactions: [String],
        levels: [(path: ChainPath, actOn: String, weighed: Bool, transactions: [String])]
    ) -> String {
        let own = templateDigest(tip: tip, transactions: transactions)
        guard !levels.isEmpty else { return own }
        let lines = [own] + levels.map {
            "\($0.path.joined(separator: "/")):\($0.actOn)/\($0.weighed ? "weighed" : "")/"
                + templateDigest(tip: $0.actOn, transactions: $0.transactions)
        }
        return SHA256.hash(data: Data(lines.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func templateDigest(tip: String, transactions: [String]) -> String {
        let lines = ["tip:\(tip)", "mempool:" + transactions.sorted().joined(separator: ",")]
        return SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}
