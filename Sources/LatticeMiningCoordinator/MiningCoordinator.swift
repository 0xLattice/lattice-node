import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Lattice
import LatticeMinerCore
import UInt256

public struct MiningCoordinatorWork: Sendable, Equatable {
    public let workId: String
    public let blockHex: String
    /// Consensus PoW preimage prefix (hex). Workers receive it alongside the
    /// block bytes so non-Swift workers never re-derive the preimage layout.
    /// Empty only for hand-built work whose blockHex is not a decodable Block.
    public let prefixHex: String
    public let targetHex: String
    public let staleToken: String

    public init(workId: String, blockHex: String, targetHex: String, staleToken: String? = nil) {
        self.workId = workId
        self.blockHex = blockHex
        self.prefixHex = TemplateResponse.derivePrefixHex(blockHex: blockHex)
        self.targetHex = targetHex
        self.staleToken = staleToken ?? workId
    }

    public init?(template: TemplateResponse) {
        guard !template.workID.isEmpty,
              Data(hex: template.blockHex) != nil,
              MinerLoopLogic.parseTarget(template.searchTarget) != nil else {
            return nil
        }
        self.init(
            workId: template.workID,
            blockHex: template.blockHex,
            targetHex: template.searchTarget,
            staleToken: template.staleToken
        )
    }
}

public struct MiningWorkerResult: Sendable, Equatable {
    public let workerId: String
    public let workId: String
    public let nonce: UInt64

    public init(workerId: String, workId: String, nonce: UInt64) {
        self.workerId = workerId
        self.workId = workId
        self.nonce = nonce
    }
}

public struct MiningSolutionSubmission: Sendable, Equatable {
    public let accepted: Bool
    public let disposition: String
    public let tipCID: String?

    public init(
        accepted: Bool,
        disposition: String,
        tipCID: String? = nil
    ) {
        self.accepted = accepted
        self.disposition = disposition
        self.tipCID = tipCID
    }
}

public enum MiningCoordinatorNodeClientError: Error, Sendable, Equatable {
    case nonHTTPResponse
    case unauthorized(statusCode: Int)
    case invalidSubmissionResponse(statusCode: Int)
}

public protocol MiningCoordinatorNodeClient: Sendable {
    func fetchWork() async throws -> MiningCoordinatorWork?
    func fetchStaleToken() async throws -> String?
    func submit(workId: String, nonce: UInt64) async throws -> MiningSolutionSubmission
}

public extension MiningCoordinatorNodeClient {
    func fetchStaleToken() async throws -> String? {
        try await fetchWork()?.staleToken
    }
}

public struct MiningCoordinatorWorker: Sendable, Equatable {
    public let id: String
    private let searchImpl: @Sendable (MiningCoordinatorWork, NonceSearchRange) async throws -> MiningWorkerResult?

    public init(
        id: String,
        search: @escaping @Sendable (MiningCoordinatorWork, NonceSearchRange) async throws -> MiningWorkerResult?
    ) {
        self.id = id
        self.searchImpl = search
    }

    public static func == (lhs: MiningCoordinatorWorker, rhs: MiningCoordinatorWorker) -> Bool {
        lhs.id == rhs.id
    }

    public func search(work: MiningCoordinatorWork, range: NonceSearchRange) async throws -> MiningWorkerResult? {
        try await searchImpl(work, range)
    }

    public static func local(id: String = "local") -> MiningCoordinatorWorker {
        MiningCoordinatorWorker(id: id) { work, range in
            guard let data = Data(hex: work.blockHex),
                  let block = Block(data: data),
                  let target = MinerLoopLogic.parseTarget(work.targetHex) else {
                return nil
            }
            let midstate = ProofOfWork.midstate(for: block)
            guard let nonce = ProofOfWork.searchBatch(
                midstate: midstate,
                target: target,
                startNonce: range.startNonce,
                count: range.count
            ) else {
                return nil
            }
            return MiningWorkerResult(
                workerId: id,
                workId: work.workId,
                nonce: nonce
            )
        }
    }
}

public struct MiningCoordinatorMetrics: Sendable, Equatable {
    public var currentWorkId: String?
    public var activeWorkerCount: Int = 0
    public var assignedRangeCount: UInt64 = 0
    public var staleAbortCount: UInt64 = 0
    public var workerFailureCount: UInt64 = 0
    public var acceptedSolutionCount: UInt64 = 0
    public var rejectedSolutionCount: UInt64 = 0
    public var retryBackoffCount: UInt64 = 0

    public init() {}
}

public enum MiningCoordinatorCycleResult: Sendable, Equatable {
    case backoff
    case nodeFailed(error: String)
    case noSolution(workId: String)
    case stale(workId: String)
    case workerFailed(workId: String, workerId: String, error: String)
    case submitted(workId: String, nonce: UInt64, submission: MiningSolutionSubmission)
}

public actor MiningCoordinator {
    private let nodeClient: any MiningCoordinatorNodeClient
    private let workers: [MiningCoordinatorWorker]
    private let totalBatchSize: UInt64
    private let staleProbeEnabled: Bool
    private let retryBackoffNanoseconds: UInt64
    private let maxSubmitRetries: Int
    private var nextNonceOffset: UInt64
    private var nonceWorkId: String?
    private var loopTask: Task<Void, Never>?
    private var metricsState = MiningCoordinatorMetrics()

    public init(
        nodeClient: any MiningCoordinatorNodeClient,
        workers: [MiningCoordinatorWorker],
        totalBatchSize: UInt64,
        nonceOffset: UInt64 = 0,
        staleProbeEnabled: Bool = true,
        retryBackoffDelay: Duration = .milliseconds(250),
        maxSubmitRetries: Int = 3
    ) {
        self.nodeClient = nodeClient
        self.workers = workers.isEmpty ? [.local()] : workers
        self.totalBatchSize = max(totalBatchSize, 1)
        self.nextNonceOffset = nonceOffset
        self.staleProbeEnabled = staleProbeEnabled
        self.retryBackoffNanoseconds = Self.nanoseconds(retryBackoffDelay)
        self.maxSubmitRetries = max(maxSubmitRetries, 0)
    }

    public func metrics() -> MiningCoordinatorMetrics {
        metricsState
    }

    @discardableResult
    public func start() -> Bool {
        guard loopTask == nil else { return false }
        loopTask = Task { [weak self] in
            guard let self else { return }
            await self.runLoop()
        }
        return true
    }

    public func stop() async {
        guard let task = loopTask else { return }
        task.cancel()
        await task.value
        loopTask = nil
    }

    public func shutdown() async {
        await stop()
    }

    private func runLoop() async {
        while !Task.isCancelled {
            let result = await runBatch()
            guard !Task.isCancelled else { break }
            switch result {
            case .backoff, .nodeFailed:
                do {
                    try await Task.sleep(nanoseconds: retryBackoffNanoseconds)
                } catch {
                    break
                }
            default:
                break
            }
        }
    }

    public func runBatch() async -> MiningCoordinatorCycleResult {
        let work: MiningCoordinatorWork
        do {
            guard let fetched = try await nodeClient.fetchWork() else {
                metricsState.retryBackoffCount += 1
                return .backoff
            }
            work = fetched
        } catch {
            metricsState.retryBackoffCount += 1
            if Self.isFatalNodeClientError(error) {
                return .nodeFailed(error: String(describing: error))
            }
            return .backoff
        }

        metricsState.currentWorkId = work.workId
        if let nonceWorkId, nonceWorkId != work.workId {
            nextNonceOffset = 0
        }
        nonceWorkId = work.workId
        metricsState.activeWorkerCount = workers.count
        let ranges = assignRanges(workerCount: workers.count)
        metricsState.assignedRangeCount = UInt64(ranges.count)

        enum Event: Sendable {
            case unchanged
            case stale
            case workerFailed(workerId: String, error: String)
            case solution(MiningWorkerResult)
        }

        return await withTaskGroup(of: Event.self) { group in
            for (worker, range) in zip(workers, ranges) {
                group.addTask {
                    do {
                        guard let result = try await worker.search(work: work, range: range),
                              result.workId == work.workId else {
                            return .unchanged
                        }
                        return .solution(result)
                    } catch {
                        return .workerFailed(workerId: worker.id, error: String(describing: error))
                    }
                }
            }

            if staleProbeEnabled {
                group.addTask { [nodeClient] in
                    // Best-effort freshness probe only; work submission remains the
                    // authoritative stale/tip check. This must stay cheap:
                    // recursive merged-mining templates rebuild descendant
                    // candidates, so probing by fetchWork() doubles the hottest
                    // path and can starve easy-target smoke/dev mining.
                    let latest = try? await nodeClient.fetchStaleToken()
                    guard let latest else { return .unchanged }
                    return latest == work.staleToken ? .unchanged : .stale
                }
            }

            for await event in group {
                switch event {
                case .unchanged:
                    continue
                case .stale:
                    group.cancelAll()
                    metricsState.staleAbortCount += 1
                    return .stale(workId: work.workId)
                case .workerFailed(let workerId, let error):
                    group.cancelAll()
                    metricsState.workerFailureCount += 1
                    return .workerFailed(workId: work.workId, workerId: workerId, error: error)
                case .solution(let result):
                    group.cancelAll()
                    if staleProbeEnabled, await isStale(work) {
                        metricsState.staleAbortCount += 1
                        return .stale(workId: work.workId)
                    }
                    return await submitWithRetry(work: work, result: result)
                }
            }

            return .noSolution(workId: work.workId)
        }
    }

    /// Submit a solved block, retrying on transient submit failures (5xx /
    /// network / non-decodable response) before discarding. Retries are
    /// STALENESS-BOUNDED: between attempts the coordinator re-checks whether the
    /// template/tip the solution extends is still current; once it is superseded
    /// the solution is abandoned (a clean discard, no infinite loop). A clean
    /// `accepted:false` is a definitive answer (not transient) and is never
    /// retried; a fatal auth failure (401/403) abandons immediately.
    private func submitWithRetry(
        work: MiningCoordinatorWork,
        result: MiningWorkerResult
    ) async -> MiningCoordinatorCycleResult {
        var attempt = 0
        while true {
            do {
                let submission = try await nodeClient.submit(
                    workId: result.workId,
                    nonce: result.nonce
                )
                if submission.accepted {
                    metricsState.acceptedSolutionCount += 1
                } else {
                    metricsState.rejectedSolutionCount += 1
                }
                return .submitted(workId: work.workId, nonce: result.nonce, submission: submission)
            } catch {
                // 401/403 are fatal — do not retry, surface to stop the loop.
                if Self.isFatalNodeClientError(error) {
                    metricsState.workerFailureCount += 1
                    return .nodeFailed(error: String(describing: error))
                }
                // Transient (5xx / network / non-decodable): retry, bounded by a
                // small attempt count AND by supersession of the work being mined.
                attempt += 1
                if attempt > maxSubmitRetries {
                    metricsState.rejectedSolutionCount += 1
                    return .submitted(
                        workId: work.workId,
                        nonce: result.nonce,
                        submission: MiningSolutionSubmission(
                            accepted: false,
                            disposition: "submitFailed"
                        )
                    )
                }
                metricsState.retryBackoffCount += 1
                do {
                    try await Task.sleep(nanoseconds: retryBackoffNanoseconds)
                } catch {
                    // Cancellation: abandon without a duplicate POST.
                    return .submitted(
                        workId: work.workId,
                        nonce: result.nonce,
                        submission: MiningSolutionSubmission(
                            accepted: false,
                            disposition: "submitFailed"
                        )
                    )
                }
                // Abandon the moment the solution is superseded (tip moved on).
                if await isStale(work) {
                    metricsState.staleAbortCount += 1
                    return .stale(workId: work.workId)
                }
            }
        }
    }

    private func isStale(_ work: MiningCoordinatorWork) async -> Bool {
        guard let latest = try? await nodeClient.fetchStaleToken() else { return false }
        return latest != work.staleToken
    }

    private static func isFatalNodeClientError(_ error: Error) -> Bool {
        guard let error = error as? MiningCoordinatorNodeClientError else { return false }
        switch error {
        case .unauthorized:
            return true
        case .nonHTTPResponse, .invalidSubmissionResponse:
            return false
        }
    }

    private static func nanoseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        guard components.seconds >= 0, components.attoseconds >= 0 else { return 0 }
        let seconds = UInt64(components.seconds)
        let nanoseconds = UInt64(components.attoseconds / 1_000_000_000)
        let (scaled, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        if overflow { return UInt64.max }
        let (total, additionOverflow) = scaled.addingReportingOverflow(nanoseconds)
        return additionOverflow ? UInt64.max : total
    }

    private func assignRanges(workerCount: Int) -> [NonceSearchRange] {
        let ranges = Self.allocateRanges(
            totalBatchSize: totalBatchSize,
            workerCount: workerCount,
            nonceOffset: nextNonceOffset
        )
        let assigned = ranges.reduce(UInt64(0)) { $0 &+ $1.count }
        nextNonceOffset = nextNonceOffset &+ assigned
        return ranges
    }

    public nonisolated static func allocateRanges(
        totalBatchSize: UInt64,
        workerCount: Int,
        nonceOffset: UInt64
    ) -> [NonceSearchRange] {
        ProofOfWork.nonceSearchRanges(
            totalBatchSize: totalBatchSize,
            workerCount: workerCount,
            nonceOffset: nonceOffset
        )
    }
}

public final class HTTPMiningCoordinatorNodeClient: MiningCoordinatorNodeClient {
    private let apiBaseURL: URL
    private let templateRequestBody: Data
    private let session: URLSession

    public init(
        apiBaseURL: URL,
        templateRequestBody: Data = Data(#"{"rewards":[]}"#.utf8),
        session: URLSession = .shared
    ) {
        self.apiBaseURL = apiBaseURL
        self.templateRequestBody = templateRequestBody
        self.session = session
    }

    public func fetchWork() async throws -> MiningCoordinatorWork? {
        var request = URLRequest(
            url: apiBaseURL.appendingPathComponent("v1/mining/templates")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = templateRequestBody
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MiningCoordinatorNodeClientError.nonHTTPResponse
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw MiningCoordinatorNodeClientError.unauthorized(statusCode: http.statusCode)
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 409 || http.statusCode == 503 { return nil }
            throw MiningCoordinatorNodeClientError.invalidSubmissionResponse(
                statusCode: http.statusCode
            )
        }
        return MiningCoordinatorWork(
            template: try JSONDecoder().decode(TemplateResponse.self, from: data)
        )
    }

    public func fetchStaleToken() async throws -> String? {
        var request = URLRequest(url: apiBaseURL.appendingPathComponent("v1/status"))
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MiningCoordinatorNodeClientError.nonHTTPResponse
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw MiningCoordinatorNodeClientError.unauthorized(statusCode: http.statusCode)
        }
        guard http.statusCode == 200 else { return nil }

        struct StatusResponse: Decodable {
            let tipCID: String?
        }
        guard let decoded = try? JSONDecoder().decode(StatusResponse.self, from: data) else {
            throw MiningCoordinatorNodeClientError.invalidSubmissionResponse(statusCode: http.statusCode)
        }
        guard let tip = decoded.tipCID, !tip.isEmpty else { return nil }
        return tip
    }

    public func submit(
        workId: String,
        nonce: UInt64
    ) async throws -> MiningSolutionSubmission {
        var request = URLRequest(
            url: apiBaseURL.appendingPathComponent("v1/mining/work")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct WorkRequest: Encodable {
            let workID: String
            let nonce: UInt64
        }
        request.httpBody = try JSONEncoder().encode(
            WorkRequest(workID: workId, nonce: nonce)
        )

        let (data, response) = try await session.data(for: request)
        return try Self.decodeSubmission(data: data, response: response)
    }

    static func decodeSubmission(data: Data, response: URLResponse) throws -> MiningSolutionSubmission {
        guard let http = response as? HTTPURLResponse else {
            throw MiningCoordinatorNodeClientError.nonHTTPResponse
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw MiningCoordinatorNodeClientError.unauthorized(statusCode: http.statusCode)
        }
        guard http.statusCode < 500 else {
            throw MiningCoordinatorNodeClientError.invalidSubmissionResponse(
                statusCode: http.statusCode
            )
        }
        struct Response: Decodable {
            let accepted: Bool
            let disposition: String
            let tipCID: String?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw MiningCoordinatorNodeClientError.invalidSubmissionResponse(statusCode: http.statusCode)
        }
        return MiningSolutionSubmission(
            accepted: response.accepted,
            disposition: response.disposition,
            tipCID: response.tipCID
        )
    }
}
