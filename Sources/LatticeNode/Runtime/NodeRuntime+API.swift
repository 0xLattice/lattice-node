import Crypto
import Foundation
import Lattice
import LatticeNodeCore
import cashew
import UInt256

/// What RPC reads besides the core's snapshot, published by the loop with
/// it: the act-on chain by height, the pool listing and the template digest.
struct NodeReadView: Sendable {
    var actOnTip: String?
    var heights = HeightIndex()
    var poolVersion: UInt64?
    var mempool = ChainReads.MempoolListing(count: 0, bytes: 0, cids: [])
    var templateDigest: String?
    var peers = 0
}

/// The act-on chain's block CIDs by height, in fixed-size chunks: a copy
/// published to readers shares every chunk, so the loop's next append copies
/// one chunk and the chunk list, never the whole chain.
struct HeightIndex: Sendable {
    private static let chunkSize = 4_096
    private var chunks: [[String]] = []
    private(set) var count = 0

    subscript(height: Int) -> String? {
        guard height >= 0, height < count else { return nil }
        return chunks[height / Self.chunkSize][height % Self.chunkSize]
    }

    mutating func append(_ cid: String) {
        if count % Self.chunkSize == 0 { chunks.append([]) }
        chunks[chunks.count - 1].append(cid)
        count += 1
    }

    mutating func truncate(to newCount: Int) {
        while count > max(0, newCount) {
            chunks[chunks.count - 1].removeLast()
            if chunks[chunks.count - 1].isEmpty { chunks.removeLast() }
            count -= 1
        }
    }
}

/// One hosted child level as a template job reads it: its executed tip (nil
/// when it executed no root), its pool, its difficulty anchor, and the spec a
/// genesis is built from when it has no root yet. One that is not caught up
/// (`ChainCore.isCaughtUp`) is read for the digest, which status serves for
/// every hosted level, and gets no candidate.
struct ChildTemplateInput: Sendable {
    let path: ChainPath
    let tipCID: String?
    let bestHeaderTip: String
    let transactions: [Transaction]
    let anchor: DifficultyAnchor?
    let genesisSpec: ChainSpec?
    let genesisTarget: UInt256
    let caughtUp: Bool
}

/// An RPC's answer, from the effect that names its reply ID.
enum NodeRuntimeReply: Sendable {
    case admitted(cid: String, count: Int, bytes: Int)
    case template(WorkTemplate)
    case work(MinedOutcome)
}

// MARK: - Operator writes: events with reply IDs, answered from effects

extension NodeRuntime {
    public func submitTransaction(
        _ request: SubmitTransactionRequest
    ) async throws -> SubmitTransactionResponse {
        try await submit(request) { .local(replyID: $0) }
    }

    /// A submit on the opt-in public listener: the same answer, but the
    /// transaction is volatile (never journaled) and its wait for a verdict is
    /// bounded; once pooled it is held to the pool's ordinary capacity rules.
    public func submitPublicTransaction(
        _ request: SubmitTransactionRequest
    ) async throws -> SubmitTransactionResponse {
        try await submit(request) { .submitted(replyID: $0) }
    }

    private func submit(
        _ request: SubmitTransactionRequest,
        origin: @escaping @Sendable (UInt64) -> TransactionOrigin
    ) async throws -> SubmitTransactionResponse {
        guard let payload = try? JSONEncoder().encode(request),
              payload.count <= NodeAPILimits.maximumPayloadBytes else {
            throw NodeAPIError.requestTooLarge
        }
        let transaction = request.transaction
        // A transaction names its chain: it goes to that level's pool.
        let path = transaction.body.node?.chainPath ?? configuration.chainPath
        guard case .admitted(let cid, let count, let bytes) = try await ask(at: path, {
            .transactionReceived(transaction, origin: origin($0))
        }) else { throw NodeRuntimeError.stopped }
        return SubmitTransactionResponse(transactionCID: cid, mempoolCount: count, mempoolBytes: bytes)
    }

    public func miningTemplate(
        _ request: MiningTemplateRequest
    ) async throws -> MiningTemplateResponse {
        let chainPath = configuration.chainPath
        // One plan for every level the template carries: each hosted
        // child's recipient and minimum work by path.
        let recipients = try MiningPlan.validatedRecipientPlan(request.recipients, chainPath: chainPath)
        let plan = TemplateRequest(
            rewardRecipient: recipients.current,
            minimumWork: try MiningPlan.validatedMinimumWorkPlan(
                request.minimumWork, chainPath: chainPath
            ).works,
            childRecipients: Dictionary(
                recipients.descendants.map { ($0.chainPath, $0.address) }, uniquingKeysWith: { first, _ in first }
            )
        )
        guard case .template(let template) = try await ask({
            .templateRequested(replyID: $0, plan)
        }) else { throw NodeRuntimeError.stopped }
        let remaining = template.expiresAt - NodeRuntime.now()
        guard remaining > 0 else { throw MiningTemplateError.expired }
        return MiningTemplateResponse(
            workID: template.workID,
            block: template.block,
            searchTarget: template.searchTarget,
            targets: template.targets,
            chainPath: chainPath,
            expiresInMilliseconds: UInt64(remaining),
            templateDigest: template.digest
        )
    }

    public func submitWork(_ request: SubmitWorkRequest) async throws -> SubmitWorkResponse {
        guard !request.workID.isEmpty, request.workID.utf8.count <= _wireAtomCapacity else {
            throw NodeAPIError.invalidWorkID
        }
        guard case .work(let outcome) = try await ask({
            .submitWork(replyID: $0, workID: request.workID, nonce: request.nonce)
        }) else { throw NodeRuntimeError.stopped }
        let disposition: WorkDisposition = switch outcome {
        case .executed: .canonicalized
        case .side: .acceptedSide
        case .duplicate: .duplicate
        case .childOnly: .childOnly
        case .invalid, .refused: .invalid
        }
        let tipCID: String? = if case .executed(let tip) = outcome { tip } else { published.value?.actOnTip }
        return SubmitWorkResponse(
            accepted: disposition == .canonicalized || disposition == .acceptedSide,
            disposition: disposition,
            tipCID: tipCID,
            durableChildProofs: []
        )
    }

    /// Post a mining event under a fresh reply ID and wait for its answer.
    private func ask(
        at path: ChainPath? = nil, _ event: @escaping @Sendable (UInt64) -> MiningEvent
    ) async throws -> NodeRuntimeReply {
        let path = path ?? configuration.chainPath
        return try await withCheckedThrowingContinuation { continuation in
            if case .terminated = inputs.yield(.request(path, event, continuation)) {
                continuation.resume(throwing: NodeRuntimeError.stopped)
            }
        }
    }

    // MARK: - Reads: the published snapshot and view

    static func reads(
        storage: NodeStorage,
        configuration: NodeConfiguration,
        published: PublishedValue<ChainSnapshot>,
        view: PublishedValue<NodeReadView>,
        chainPath: ChainPath? = nil,
        accepted: (@Sendable (String) async -> Bool)? = nil
    ) -> ChainReads {
        ChainReads(
            storage: storage,
            chainPath: chainPath,
            accepted: accepted,
            tip: {
                let snapshot = published.value
                return ChainStatus(
                    phase: snapshot == nil || snapshot?.actOnTip.isEmpty == true ? .awaitingGenesis : .active,
                    chainPath: chainPath ?? configuration.chainPath,
                    nexusGenesisCID: configuration.nexusGenesisCID,
                    tipCID: snapshot?.actOnTip.isEmpty == false ? snapshot?.actOnTip : nil,
                    height: snapshot?.actOnTip.isEmpty == false ? snapshot?.actOnHeight : nil,
                    revision: nil,
                    bestHeaderHeight: snapshot?.bestHeaderTip.isEmpty == false ? snapshot?.bestHeaderHeight : nil
                )
            },
            canonicalCID: { height in
                view.value?.heights[Int(clamping: height)]
            },
            mempool: { _ in
                view.value?.mempool ?? ChainReads.MempoolListing(count: 0, bytes: 0, cids: [])
            }
        )
    }

    /// The read URLs declared for `chainPath`, a child of a level this node
    /// hosts that the parent recently committed (or this node hosts): this
    /// node's own when it hosts the child, then what the child's other hosts
    /// answer. Nil when the parent is not hosted or commits no such child.
    public func chainEndpoints(_ chainPath: [String]) async -> ExplorerChainEndpoints? {
        guard chainPath.count > 1, ChainAddress(chainPath) != nil else { return nil }
        let parent = Array(chainPath.dropLast())
        guard let parentReads = parent == reads.chainPath ? reads : levelReads[parent] else { return nil }
        let hostsChild = levelReads[chainPath] != nil
        let committed = await parentReads.committedChild(directory: chainPath[chainPath.count - 1])
        guard committed != nil || hostsChild else { return nil }
        var declared = hostsChild
            ? configuration.publicReadURL.map {
                [DeclaredReadEndpoint(url: $0, acceptsSubmit: configuration.publicSubmit)]
            } ?? []
            : []
        for endpoint in await readEndpoints.lookup(chainPath) where !declared.contains(where: { $0.url == endpoint.url }) {
            declared.append(endpoint)
        }
        return ExplorerChainEndpoints(
            chainPath: chainPath,
            committedBlock: committed,
            endpoints: declared.map(\.url),
            submitEndpoints: declared.filter(\.acceptsSubmit).map(\.url)
        )
    }

    /// `/status`: the read snapshot with the template digest.
    public func status() async -> NodeStatusResponse {
        let read = await reads.readSnapshot()
        return NodeStatusResponse(
            phase: read.phase,
            chainPath: read.chainPath,
            nexusGenesisCID: read.nexusGenesisCID,
            tipCID: read.tipCID,
            height: read.height,
            revision: read.revision,
            mempoolCount: read.mempoolCount,
            mempoolBytes: read.mempoolBytes,
            templateDigest: read.tipCID == nil ? nil : readView.value?.templateDigest,
            bestHeaderHeight: read.bestHeaderHeight
        )
    }

    /// Ready overlay sessions.
    public var peerCount: Int { readView.value?.peers ?? 0 }

    public func metricsExposition(peers: Int, processStartTime: Date) -> String {
        let snapshot = published.value
        return renderNodeMetrics(NodeMetricsSample(
            chainPath: configuration.chainPath,
            validatedTipHeight: snapshot?.actOnHeight,
            weighedTipHeight: snapshot?.bestHeaderHeight,
            overlayPeers: peers,
            mempoolTransactions: snapshot?.mempoolCount ?? 0,
            processStartTime: processStartTime
        ))
    }

    // MARK: - Jobs

    /// A worker job. One with a tip epoch is skipped at dequeue when its
    /// level's mining tip epoch has moved: it runs nothing, posts nothing.
    struct RuntimeJob: Sendable {
        let path: ChainPath
        let epoch: UInt64?
        let run: @Sendable () async -> [NodeEvent]

        func isCurrent(in core: NodeCore) -> Bool {
            epoch.map { core.levels[path]?.mining.tipEpoch == $0 } ?? true
        }
    }

    /// The chain a tip epoch's jobs read: a copy of the level's tree.
    static func jobLevel(_ tree: ChainTree) -> ChainLevel? { ChainLevel(tree: tree) }

    /// The worker job for a mining effect that needs one: Lattice preflight
    /// and the template assembly over the job's epoch `level`, and the read
    /// of a tip move's blocks, which is tied to no epoch (a returned
    /// transaction is a candidate on any tip, and its preflight decides).
    static func miningJob(
        _ effect: MiningEffect,
        at path: ChainPath,
        level: ChainLevel?,
        storage: NodeStorage,
        children: [ChildTemplateInput] = []
    ) -> RuntimeJob {
        let fetcher = storage.localFetcher
        switch effect {
        case .preflight(let job):
            return RuntimeJob(path: path, epoch: job.tipEpoch) {
                guard let level else { return [] }
                let result = await level.preflightTransaction(job.transaction, at: job.tipCID, fetcher: fetcher)
                return [.level(path, .mining(.preflighted(job, disposition(result.disposition))))]
            }
        case .buildTemplate(let job):
            return RuntimeJob(path: path, epoch: job.tipEpoch) {
                let anchor = await level?.chain.difficultyAnchor(forBlockHash: job.tipCID)
                return [.level(path, .mining(.templateBuilt(job, await buildTemplate(
                    job, difficultyAnchor: anchor, storage: storage, chainPath: path, children: children
                ))))]
            }
        case .returnTransactions(let left, let carried):
            return RuntimeJob(path: path, epoch: nil) {
                var returned: [NodeEvent] = []
                for cid in left {
                    for transaction in await transactions(ofBlock: cid, fetcher: fetcher)
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

    /// A block's transactions with their bodies resolved (the pool takes
    /// resolved content only); none when its body is not held.
    static func transactions(ofBlock cid: String, fetcher: any Fetcher) async -> [Transaction] {
        guard let block = try? await BlockHeader(rawCID: cid).resolve(fetcher: fetcher).node,
              let carried = try? await MiningTemplateAssembly.blockTransactions(in: block, fetcher: fetcher)
        else { return [] }
        var resolved: [Transaction] = []
        for transaction in carried {
            guard let body = try? await transaction.body.resolve(fetcher: fetcher), body.node != nil else { continue }
            resolved.append(Transaction(signatures: transaction.signatures, body: body))
        }
        return resolved
    }

    static func transactionIDs(ofBlock cid: String, fetcher: any Fetcher) async -> [String] {
        await transactions(ofBlock: cid, fetcher: fetcher).compactMap { try? Mempool.cid(of: $0) }
    }

    /// A level's connect job: `ChainTree.connect`, and for a valid block the
    /// IDs of the transactions it carries, read from the body it executed.
    static func connectJob(
        _ job: ConnectJob,
        at path: ChainPath,
        parentFacts: ParentLevelFacts?,
        storage: NodeStorage
    ) -> RuntimeJob {
        let fetcher = storage.localFetcher
        return RuntimeJob(path: path, epoch: nil) {
            let verdict = await ChainTree.connect(
                job,
                fetcher: fetcher,
                parentFacts: parentFacts,
                validationContext: ValidationContext(nowMilliseconds: now())
            )
            let valid = verdict.retryFailure == nil && !verdict.provesInvalid
            let transactions = valid ? await transactionIDs(ofBlock: job.blockHash, fetcher: fetcher) : []
            return [.level(path, .connected(verdict, transactions: transactions))]
        }
    }

    /// `ChainEffect.readTransactions`: each block's transaction IDs.
    static func readJob(_ blocks: [String], at path: ChainPath, storage: NodeStorage) -> RuntimeJob {
        let fetcher = storage.localFetcher
        return RuntimeJob(path: path, epoch: nil) {
            var read: [String: [String]] = [:]
            for cid in blocks { read[cid] = await transactionIDs(ofBlock: cid, fetcher: fetcher) }
            return [.level(path, .transactionsRead(read))]
        }
    }

    /// `MiningEffect.buildTemplate`: today's assembly (the bisecting fit, the
    /// policy filter, the minimum-work search target) on the job's tip.
    /// Nil when no block can be built there.
    static func buildTemplate(
        _ job: TemplateJob,
        difficultyAnchor: DifficultyAnchor?,
        storage: NodeStorage,
        chainPath: [String],
        children: [ChildTemplateInput] = []
    ) async -> TemplateBuild? {
        let fetcher = storage.localFetcher
        guard job.request.parentCarrier == nil,
              let previous = try? await BlockHeader(rawCID: job.tipCID).resolve(fetcher: fetcher).node,
              let spec = try? await previous.spec.resolve(fetcher: fetcher).node,
              let timestamp = try? MiningPlan.nextTimestamp(after: previous.timestamp, parentCarrier: nil)
        else { return nil }
        let pooled = await MiningPlan.policyAcceptedTransactions(
            job.transactions,
            chainPath: chainPath,
            previous: previous,
            timestamp: timestamp,
            spec: spec,
            fetcher: fetcher
        )
        let provided = await childCandidates(
            of: chainPath, among: children, entering: previous.postState, timestamp: timestamp,
            request: job.request, fetcher: fetcher
        )
        guard let template = try? await MiningTemplateAssembly.fit(
            chainPath: chainPath,
            lifetime: .seconds(30),
            previous: previous,
            pooled: pooled,
            provided: provided,
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
                tip: job.tipCID,
                transactions: job.transactions.compactMap { try? Mempool.cid(of: $0) },
                levels: children.map {
                    (
                        $0.tipCID ?? "",
                        $0.bestHeaderTip,
                        $0.transactions.compactMap { try? Mempool.cid(of: $0) }
                    )
                }
            )
        )
    }

    /// Merged mining: a candidate block for each hosted direct child of
    /// `parent`, each carrying its own children's, every one committing its
    /// carrier's entering state. A child with an executed tip builds on it;
    /// one with no root yet and a configured spec gets a genesis; one whose
    /// root is weighed but not executed, or that is not caught up, waits.
    static func childCandidates(
        of parent: ChainPath,
        among inputs: [ChildTemplateInput],
        entering: LatticeStateHeader,
        timestamp: Int64,
        request: TemplateRequest,
        fetcher: any Fetcher
    ) async -> [DirectChildCandidate] {
        var candidates: [DirectChildCandidate] = []
        for input in inputs where input.caughtUp && input.path.dropLast().elementsEqual(parent) {
            let carrier = Block(
                version: Block.currentVersion, parent: nil,
                transactions: HeaderImpl(rawCID: entering.rawCID), target: .max, nextTarget: .max,
                spec: VolumeImpl(rawCID: entering.rawCID), parentState: entering, prevState: entering,
                postState: entering, children: HeaderImpl(rawCID: entering.rawCID), height: 0,
                timestamp: timestamp, rewardRecipient: nil, nonce: 0
            )
            let block: Block?
            if let tipCID = input.tipCID {
                guard let previous = try? await BlockHeader(rawCID: tipCID).resolve(fetcher: fetcher).node,
                      let spec = try? await previous.spec.resolve(fetcher: fetcher).node,
                      let time = try? MiningPlan.nextTimestamp(after: previous.timestamp, parentCarrier: carrier)
                else { continue }
                let grandchildren = await childCandidates(
                    of: input.path, among: inputs, entering: previous.postState, timestamp: time,
                    request: request, fetcher: fetcher
                )
                block = try? await MiningTemplateAssembly.fit(
                    chainPath: input.path, lifetime: .seconds(30), previous: previous,
                    pooled: input.transactions, provided: grandchildren, parentCarrier: carrier,
                    timestamp: time, rewardRecipient: request.childRecipients[input.path],
                    minimumWork: request.minimumWork, difficultyAnchor: input.anchor, spec: spec, fetcher: fetcher
                ).block
            } else if let spec = input.genesisSpec {
                // A genesis carries no children: a nested genesis commits its
                // carrier's entering state, and a genesis enters the empty
                // one, which no child genesis may name. Its children wait
                // until it executes.
                block = try? await BlockBuilder.buildChildGenesis(
                    spec: spec, parentState: entering,
                    timestamp: timestamp, target: input.genesisTarget, fetcher: fetcher
                )
            } else {
                block = nil
            }
            if let block { candidates.append(DirectChildCandidate(directory: input.path[input.path.count - 1], block: block)) }
        }
        return candidates
    }

    static func disposition(_ preflight: TransactionPreflightDisposition) -> MempoolDisposition {
        switch preflight {
        case .ready: .ready
        case .future: .future
        case .unavailable: .unavailable
        case .invalid: .invalid
        }
    }

    /// The template digest over the root and every hosted child: each tip,
    /// best header, and transaction set a template job reads. Status serves
    /// the current value, so it reads the same selections a build does: the
    /// root's ready set, and each carried child's contextual set.
    static func templateDigest(
        tip: String, mempool: Mempool, levels: [(actOn: String, best: String, pool: Mempool)] = []
    ) -> String {
        templateDigest(
            tip: tip,
            transactions: mempool.transactions(limit: .max).compactMap { try? Mempool.cid(of: $0) },
            levels: levels.map {
                ($0.actOn, $0.best, $0.pool.contextualTransactions(limit: .max).compactMap { try? Mempool.cid(of: $0) })
            }
        )
    }

    static func templateDigest(
        tip: String,
        transactions: [String],
        levels: [(actOn: String, best: String, transactions: [String])]
    ) -> String {
        let own = templateDigest(tip: tip, transactions: transactions)
        guard !levels.isEmpty else { return own }
        let lines = [own] + levels.map {
            "\($0.actOn)/\($0.best)/" + templateDigest(tip: $0.actOn, transactions: $0.transactions)
        }
        return SHA256.hash(data: Data(lines.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func templateDigest(tip: String, transactions: [String]) -> String {
        let lines = ["tip:\(tip)", "mempool:" + transactions.sorted().joined(separator: ",")]
        return SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}
