import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#endif
import XCTest
@testable import LatticeMiningCoordinator
import LatticeMinerCore
import UInt256

private actor StubNodeClient: MiningCoordinatorNodeClient {
    private var workResponses: [MiningCoordinatorWork?]
    private let submission: MiningSolutionSubmission
    private let submitError: Error?
    private(set) var submissions: [(workId: String, nonce: UInt64)] = []

    init(
        workResponses: [MiningCoordinatorWork?],
        submission: MiningSolutionSubmission = .init(
            accepted: true,
            disposition: "canonicalized",
            tipCID: "b"
        ),
        submitError: Error? = nil
    ) {
        self.workResponses = workResponses
        self.submission = submission
        self.submitError = submitError
    }

    func fetchWork() async throws -> MiningCoordinatorWork? {
        if workResponses.isEmpty { return nil }
        return workResponses.removeFirst()
    }

    func submit(workId: String, nonce: UInt64) async throws -> MiningSolutionSubmission {
        submissions.append((workId, nonce))
        if let submitError { throw submitError }
        return submission
    }

    func submissionCount() -> Int {
        submissions.count
    }
}

private enum TestTimeout: Error {
    case timedOut
}

/// Stub that fails the first `transientFailures` submit attempts with a
/// transient error, then accepts. `fetchWork` replays a queue so the
/// supersession re-check (isStale) sees a fresh tip per call.
private actor RetryingSubmitStub: MiningCoordinatorNodeClient {
    private var workResponses: [MiningCoordinatorWork?]
    private var remainingFailures: Int
    private let failure: Error
    private(set) var submissions: [(workId: String, nonce: UInt64)] = []

    init(
        workResponses: [MiningCoordinatorWork?],
        transientFailures: Int,
        failure: Error = MiningCoordinatorNodeClientError.invalidSubmissionResponse(statusCode: 503)
    ) {
        self.workResponses = workResponses
        self.remainingFailures = transientFailures
        self.failure = failure
    }

    func fetchWork() async throws -> MiningCoordinatorWork? {
        if workResponses.isEmpty { return nil }
        return workResponses.removeFirst()
    }

    func submit(workId: String, nonce: UInt64) async throws -> MiningSolutionSubmission {
        submissions.append((workId, nonce))
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw failure
        }
        return MiningSolutionSubmission(
            accepted: true,
            disposition: "canonicalized",
            tipCID: "b"
        )
    }

    func recordedSubmissions() -> [(workId: String, nonce: UInt64)] {
        submissions
    }
}

/// Merged work over a fixed preimage prefix: an easy child target that about
/// half of all hashes clear, and a HARD parent target that exactly one nonce in
/// the span clears. A maximum parent target would let the first hit clear the
/// parent too, which is exactly the case that cannot show the parent starving.
private struct MergedWork: Sendable {
    static let span: UInt64 = 1 << 14

    let prefix: ContiguousArray<UInt8>
    let childTarget: UInt256
    let parentTarget: UInt256
    let parentNonce: UInt64
    let work: MiningCoordinatorWork

    init() {
        prefix = ContiguousArray("merged-mining-duty-cycle".utf8)
        let midstate = ProofOfWork.midstate(prefixBytes: prefix)
        var parentNonce: UInt64 = 0
        var parentTarget = UInt256.max
        for nonce in 0..<Self.span {
            let hash = ProofOfWork.hash(midstate: midstate, nonce: nonce)
            if hash < parentTarget {
                parentTarget = hash
                parentNonce = nonce
            }
        }
        childTarget = UInt256.max >> 1
        self.parentTarget = parentTarget
        self.parentNonce = parentNonce
        work = MiningCoordinatorWork(
            workId: "merged",
            blockHex: "00",
            prefixHex: prefix.map { String(format: "%02x", $0) }.joined(),
            targetHex: childTarget.toHexString(),
            targets: [childTarget, parentTarget],
            expiresInMilliseconds: nil,
            staleToken: "tip"
        )
    }

    func hash(_ nonce: UInt64) -> UInt256 {
        ProofOfWork.hash(midstate: ProofOfWork.midstate(prefixBytes: prefix), nonce: nonce)
    }

    var firstChildNonce: UInt64 {
        (0..<Self.span).first { hash($0) <= childTarget }!
    }

    /// A real CPU search of the assigned prefix, target, and range that records
    /// the effort it actually spent.
    func worker(id: String, ledger: SearchLedger) -> MiningCoordinatorWorker {
        MiningCoordinatorWorker(id: id) { assignment, range in
            let target = MinerLoopLogic.parseTarget(assignment.targetHex)!
            let nonce = ProofOfWork.searchBatch(
                midstate: ProofOfWork.midstate(prefixBytes: prefix),
                target: target,
                startNonce: range.startNonce,
                count: range.count
            )
            await ledger.record(SearchLedger.Search(
                target: target,
                startNonce: range.startNonce,
                hashed: nonce.map { $0 - range.startNonce + 1 } ?? range.count,
                cancelled: Task.isCancelled
            ))
            return nonce.map {
                MiningWorkerResult(workerId: id, workId: assignment.workId, nonce: $0)
            }
        }
    }
}

private actor SearchLedger {
    struct Search: Equatable {
        let target: UInt256
        let startNonce: UInt64
        let hashed: UInt64
        let cancelled: Bool
    }

    private(set) var searches: [Search] = []

    func record(_ search: Search) {
        searches.append(search)
    }
}

/// Decides each submission the way the node does: by hashing it. A hash that
/// clears the parent target produces the parent block; one that clears only the
/// child target is a carrier, which leaves the work open.
private actor MergedMiningNode: MiningCoordinatorNodeClient {
    private let merged: MergedWork
    private(set) var submissions: [UInt64] = []

    init(_ merged: MergedWork) {
        self.merged = merged
    }

    func fetchWork() async throws -> MiningCoordinatorWork? {
        merged.work
    }

    func submit(workId: String, nonce: UInt64) async throws -> MiningSolutionSubmission {
        submissions.append(nonce)
        let hash = merged.hash(nonce)
        if hash <= merged.parentTarget {
            return MiningSolutionSubmission(accepted: true, disposition: "canonicalized", tipCID: "parent")
        }
        if hash <= merged.childTarget {
            return MiningSolutionSubmission(accepted: false, disposition: "carrier")
        }
        return MiningSolutionSubmission(accepted: false, disposition: "invalid")
    }
}

/// Serves fixed work whose tip moves to a new block after `movesAfter`.
private actor MovingTipNode: MiningCoordinatorNodeClient {
    private let work: MiningCoordinatorWork
    private let movesAt: ContinuousClock.Instant
    private(set) var probes = 0

    init(work: MiningCoordinatorWork, movesAfter: Duration) {
        self.work = work
        movesAt = ContinuousClock.now + movesAfter
    }

    func fetchWork() async throws -> MiningCoordinatorWork? {
        work
    }

    func fetchStaleToken() async throws -> String? {
        probes += 1
        return ContinuousClock.now < movesAt ? work.staleToken : "moved-tip"
    }

    func submit(workId: String, nonce: UInt64) async throws -> MiningSolutionSubmission {
        MiningSolutionSubmission(accepted: true, disposition: "canonicalized")
    }
}

/// Submits through the real HTTP client against a stubbed daemon, and counts
/// every POST the coordinator makes.
private actor HTTPSubmittingNode: MiningCoordinatorNodeClient {
    private let work: MiningCoordinatorWork
    private let client: HTTPMiningCoordinatorNodeClient
    private(set) var submitAttempts = 0

    init(work: MiningCoordinatorWork, client: HTTPMiningCoordinatorNodeClient) {
        self.work = work
        self.client = client
    }

    func fetchWork() async throws -> MiningCoordinatorWork? {
        work
    }

    func fetchStaleToken() async throws -> String? {
        work.staleToken
    }

    func submit(workId: String, nonce: UInt64) async throws -> MiningSolutionSubmission {
        submitAttempts += 1
        return try await client.submit(workId: workId, nonce: nonce)
    }
}

private actor CancellationFlag {
    private(set) var cancelled = false

    func record(_ cancelled: Bool) {
        self.cancelled = cancelled
    }
}

private actor RangeRecorder {
    private(set) var ranges: [String: NonceSearchRange] = [:]
    private(set) var history: [NonceSearchRange] = []

    func record(workerId: String, range: NonceSearchRange) {
        ranges[workerId] = range
        history.append(range)
    }

    func snapshot() -> [String: NonceSearchRange] {
        ranges
    }

    func recordedRanges() -> [NonceSearchRange] {
        history
    }
}

final class MiningTemplateRequestBodyTests: XCTestCase {
    private let rewards = Data(#"{"rewards":[]}"#.utf8)

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    /// The filter reaches the request as a SEARCH plan and nothing else.
    /// There is no way to ask for it to be committed into blocks -- difficulty
    /// is what the chain reads from arrival rate, not what a miner declares.
    func testMinimumWorkReachesTheRequestAsASearchPlanOnly() throws {
        let body = try object(MiningTemplateRequestBody.make(
            rewardsRequest: rewards,
            deployment: false,
            minimumWork: ["Nexus=2^8"]
        ))
        XCTAssertEqual((body["minimumWork"] as? [Any])?.count, 1)
        XCTAssertNil(
            body["commitMinimumWorkTarget"],
            "a miner's filter must never travel as a commitment"
        )
    }
}
