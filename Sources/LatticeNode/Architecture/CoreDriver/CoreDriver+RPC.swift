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
            rewardRecipient: try ChainService.validatedRecipientPlan(
                request.recipients, chainPath: chainPath
            ).current,
            minimumWork: try ChainService.validatedMinimumWorkPlan(
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
            templateDigest: readView.value?.templateDigest ?? ""
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
        case .weighed(canonical: true): .canonicalized
        case .weighed(canonical: false): .acceptedSide
        case .duplicate: .duplicate
        case .childOnly: .childOnly
        case .refused: .invalid
        }
        return SubmitWorkResponse(
            accepted: { if case .weighed = outcome { true } else { false } }(),
            disposition: disposition,
            tipCID: published.value?.actOnTip,
            parentGenesisLinks: [],
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
            mempool: {
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
            parentReportsApplied: 0,
            parentReportRefusals: [:],
            executionWalkParked: 0,
            candidateSessionReads: 0
        ))
    }

    // MARK: - Jobs

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
              let timestamp = try? ChainService.nextTimestamp(after: previous.timestamp, parentCarrier: nil)
        else { return nil }
        let pooled = await ChainService.policyAcceptedTransactions(
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
            targets: template.targets
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
    /// act-on tip and the transactions a template selects from.
    static func templateDigest(tip: String, mempool: Mempool) -> String {
        let selectable = mempool.items.filter { $0.disposition != .unavailable }.map(\.cid).sorted()
        let lines = ["tip:\(tip)", "mempool:" + selectable.joined(separator: ",")]
        return SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}
