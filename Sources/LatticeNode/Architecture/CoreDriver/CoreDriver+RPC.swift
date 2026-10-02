import Crypto
import Foundation
import Lattice
import LatticeNodeCore
import cashew

/// What RPC reads besides the core's snapshot, published by the loop with
/// it: the act-on chain by height, the pool listing and the template digest.
struct CoreReadView: Sendable {
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

/// An RPC's answer, from the effect that names its reply ID.
enum CoreReply: Sendable {
    case admitted(cid: String, count: Int, bytes: Int)
    case template(WorkTemplate)
    case work(MinedOutcome)
}

// MARK: - Operator writes: events with reply IDs, answered from effects

extension CoreDriver {
    public func submitTransaction(
        _ request: SubmitTransactionRequest
    ) async throws -> SubmitTransactionResponse {
        guard let payload = try? JSONEncoder().encode(request),
              payload.count <= ChainServiceLimits.maximumPayloadBytes else {
            throw ChainServiceError.requestTooLarge
        }
        let transaction = request.transaction
        guard case .admitted(let cid, let count, let bytes) = try await ask({
            .transactionReceived(transaction, origin: .local(replyID: $0))
        }) else { throw CoreDriverError.stopped }
        return SubmitTransactionResponse(transactionCID: cid, mempoolCount: count, mempoolBytes: bytes)
    }

    public func miningTemplate(
        _ request: MiningTemplateRequest
    ) async throws -> MiningTemplateResponse {
        let chainPath = configuration.chainPath
        // The driver hosts no child level, so only this chain's part of the
        // plan is used.
        let plan = TemplateRequest(
            rewardRecipient: try MiningPlan.validatedRecipientPlan(
                request.recipients, chainPath: chainPath
            ).current,
            minimumWork: try MiningPlan.validatedMinimumWorkPlan(
                request.minimumWork, chainPath: chainPath
            ).works
        )
        guard case .template(let template) = try await ask({
            .templateRequested(replyID: $0, plan)
        }) else { throw CoreDriverError.stopped }
        let remaining = template.expiresAt - CoreDriver.now()
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
            throw ChainServiceError.invalidWorkID
        }
        guard case .work(let outcome) = try await ask({
            .submitWork(replyID: $0, workID: request.workID, nonce: request.nonce)
        }) else { throw CoreDriverError.stopped }
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
    private func ask(_ event: @escaping @Sendable (UInt64) -> MiningEvent) async throws -> CoreReply {
        try await withCheckedThrowingContinuation { continuation in
            if case .terminated = inputs.yield(.request(event, continuation)) {
                continuation.resume(throwing: CoreDriverError.stopped)
            }
        }
    }

    // MARK: - Reads: the published snapshot and view

    static func reads(
        process: ChainProcess,
        configuration: NodeConfiguration,
        published: PublishedValue<Snapshot>,
        view: PublishedValue<CoreReadView>
    ) -> ChainReads {
        ChainReads(
            process: process,
            tip: {
                let snapshot = published.value
                return ChainProcessStatus(
                    phase: snapshot == nil ? .awaitingGenesis : .active,
                    chainPath: configuration.chainPath,
                    nexusGenesisCID: configuration.nexusGenesisCID,
                    tipCID: snapshot?.actOnTip,
                    height: snapshot?.actOnHeight,
                    revision: nil
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

    /// `/v1/status`: the read snapshot with the template digest.
    public func status() async -> ChainServiceStatusResponse {
        let read = await reads.readSnapshot()
        return ChainServiceStatusResponse(
            phase: read.phase,
            chainPath: read.chainPath,
            nexusGenesisCID: read.nexusGenesisCID,
            tipCID: read.tipCID,
            height: read.height,
            revision: read.revision,
            mempoolCount: read.mempoolCount,
            mempoolBytes: read.mempoolBytes,
            templateDigest: read.tipCID == nil ? nil : readView.value?.templateDigest
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
            processStartTime: processStartTime,
            executionWalkParked: 0,
            candidateSessionReads: 0
        ))
    }

    // MARK: - Jobs

    /// A worker job. One with a tip epoch is skipped at dequeue when its
    /// level's mining tip epoch has moved: it runs nothing, posts nothing.
    struct CoreJob: Sendable {
        let path: ChainPath
        let epoch: UInt64?
        let run: @Sendable () async -> [HostEvent]

        func isCurrent(in core: HostCore) -> Bool {
            epoch.map { core.levels[path]?.mining.tipEpoch == $0 } ?? true
        }
    }

    /// The chain a tip epoch's jobs read, replayed from the durable facts:
    /// Lattice builds a level only from facts (`ChainLevel.restore`).
    static func jobLevel(context: ChainRuntimeContext, process: ChainProcess) async -> ChainLevel? {
        guard let facts = try? await process.coreFacts() else { return nil }
        return try? await ChainLevel.restore(replaying: facts, context: context)
    }

    /// The worker job for a mining effect that needs one: Lattice preflight
    /// and the template assembly over the job's epoch `level`, and the read
    /// of a tip move's blocks, which is tied to no epoch (a returned
    /// transaction is a candidate on any tip, and its preflight decides).
    static func miningJob(
        _ effect: MiningEffect,
        at path: ChainPath,
        level: ChainLevel?,
        process: ChainProcess
    ) -> CoreJob {
        let fetcher = process.localFetcher
        switch effect {
        case .preflight(let job):
            return CoreJob(path: path, epoch: job.tipEpoch) {
                guard let level else { return [] }
                let result = await level.preflightTransaction(job.transaction, at: job.tipCID, fetcher: fetcher)
                return [.level(path, .mining(.preflighted(job, disposition(result.disposition))))]
            }
        case .buildTemplate(let job):
            return CoreJob(path: path, epoch: job.tipEpoch) {
                let anchor = await level?.chain.difficultyAnchor(forBlockHash: job.tipCID)
                return [.level(path, .mining(.templateBuilt(job, await buildTemplate(
                    job, difficultyAnchor: anchor, process: process, chainPath: path
                ))))]
            }
        case .returnTransactions(let left, let carried):
            return CoreJob(path: path, epoch: nil) {
                var returned: [HostEvent] = []
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
        process: ChainProcess
    ) -> CoreJob {
        let fetcher = process.localFetcher
        return CoreJob(path: path, epoch: nil) {
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

    /// `Effect.readTransactions`: each block's transaction IDs.
    static func readJob(_ blocks: [String], at path: ChainPath, process: ChainProcess) -> CoreJob {
        let fetcher = process.localFetcher
        return CoreJob(path: path, epoch: nil) {
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
        process: ChainProcess,
        chainPath: [String]
    ) async -> TemplateBuild? {
        let fetcher = process.localFetcher
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
        guard let template = try? await MiningTemplateAssembly.fit(
            chainPath: chainPath,
            lifetime: .seconds(30),
            previous: previous,
            pooled: pooled,
            provided: [],
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
            digest: templateDigest(tip: job.tipCID, transactions: job.transactions.compactMap { try? Mempool.cid(of: $0) })
        )
    }

    static func disposition(_ preflight: TransactionPreflightDisposition) -> MempoolDisposition {
        switch preflight {
        case .ready: .ready
        case .future: .future
        case .unavailable: .unavailable
        case .invalid: .invalid
        }
    }

    /// The template digest without children (the driver hosts none): the
    /// tip and the transactions a template selects from (the pool's ready
    /// and future entries). A template carries the digest of the inputs its
    /// job read; status serves the current one.
    static func templateDigest(tip: String, mempool: Mempool) -> String {
        templateDigest(tip: tip, transactions: mempool.items.filter { $0.disposition != .unavailable }.map(\.cid))
    }

    static func templateDigest(tip: String, transactions: [String]) -> String {
        let lines = ["tip:\(tip)", "mempool:" + transactions.sorted().joined(separator: ",")]
        return SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}
