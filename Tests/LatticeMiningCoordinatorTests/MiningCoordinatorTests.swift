import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import LatticeMiningCoordinator
import LatticeMinerCore

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

final class MiningCoordinatorTests: XCTestCase {
    private let work = MiningCoordinatorWork(
        workId: "work-1",
        blockHex: "00",
        targetHex: "ff",
        staleToken: "work-1"
    )

    private func waitUntil(
        timeout: Duration = .milliseconds(500),
        _ predicate: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await predicate()
    }

    private func assertCompletes(
        timeout: Duration = .milliseconds(300),
        operation: @escaping @Sendable () async -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    await operation()
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw TestTimeout.timedOut
                }
                _ = try await group.next()
                group.cancelAll()
            }
        } catch {
            XCTFail("operation did not complete before timeout: \(error)", file: file, line: line)
        }
    }

    func testAllocatesNonOverlappingRangesAcrossWorkers() async {
        let recorder = RangeRecorder()
        let workers = (0..<3).map { i in
            MiningCoordinatorWorker(id: "w\(i)") { _, range in
                await recorder.record(workerId: "w\(i)", range: range)
                return nil
            }
        }
        let node = StubNodeClient(workResponses: [work, work])
        let coordinator = MiningCoordinator(
            nodeClient: node,
            workers: workers,
            totalBatchSize: 10,
            nonceOffset: 5
        )

        let result = await coordinator.runBatch()
        guard case .noSolution = result else {
            return XCTFail("expected no solution, got \(result)")
        }

        let ranges = await recorder.snapshot()
        XCTAssertEqual(Set(ranges.keys), ["w0", "w1", "w2"])
        XCTAssertEqual(ranges["w0"], NonceSearchRange(startNonce: 5, count: 4))
        XCTAssertEqual(ranges["w1"], NonceSearchRange(startNonce: 9, count: 3))
        XCTAssertEqual(ranges["w2"], NonceSearchRange(startNonce: 12, count: 3))

        let metrics = await coordinator.metrics()
        XCTAssertEqual(metrics.currentWorkId, "work-1")
        XCTAssertEqual(metrics.activeWorkerCount, 3)
        XCTAssertEqual(metrics.assignedRangeCount, 3)
    }

    func testStaleWorkCancelsBatchWithoutSubmitting() async {
        let stale = MiningCoordinatorWork(
            workId: "work-2",
            blockHex: "00",
            targetHex: "ff",
            staleToken: "work-2"
        )
        let worker = MiningCoordinatorWorker(id: "slow") { work, _ in
            try? await Task.sleep(for: .milliseconds(150))
            return MiningWorkerResult(workerId: "slow", workId: work.workId, nonce: 1)
        }
        let node = StubNodeClient(workResponses: [work, stale])
        let coordinator = MiningCoordinator(nodeClient: node, workers: [worker], totalBatchSize: 1)

        let result = await coordinator.runBatch()

        XCTAssertEqual(result, .stale(workId: "work-1"))
        let submissionCount = await node.submissionCount()
        XCTAssertEqual(submissionCount, 0)
        let metrics = await coordinator.metrics()
        XCTAssertEqual(metrics.staleAbortCount, 1)
        XCTAssertEqual(metrics.acceptedSolutionCount, 0)
        XCTAssertEqual(metrics.rejectedSolutionCount, 0)
    }

    func testStaleWorkIsRecheckedBeforeSubmittingFastWorkerResult() async {
        let stale = MiningCoordinatorWork(
            workId: "work-2",
            blockHex: "00",
            targetHex: "ff",
            staleToken: "work-2"
        )
        let worker = MiningCoordinatorWorker(id: "fast") { work, _ in
            MiningWorkerResult(workerId: "fast", workId: work.workId, nonce: 1)
        }
        let node = StubNodeClient(workResponses: [work, stale, stale])
        let coordinator = MiningCoordinator(nodeClient: node, workers: [worker], totalBatchSize: 1)

        let result = await coordinator.runBatch()

        XCTAssertEqual(result, .stale(workId: "work-1"))
        let submissionCount = await node.submissionCount()
        XCTAssertEqual(submissionCount, 0)
        let metrics = await coordinator.metrics()
        XCTAssertEqual(metrics.staleAbortCount, 1)
        XCTAssertEqual(metrics.acceptedSolutionCount, 0)
        XCTAssertEqual(metrics.rejectedSolutionCount, 0)
    }

    func testTransientProbeFailureDoesNotCancelValidWork() async {
        let worker = MiningCoordinatorWorker(id: "solver") { work, _ in
            try? await Task.sleep(for: .milliseconds(50))
            return MiningWorkerResult(workerId: "solver", workId: work.workId, nonce: 42)
        }
        let node = StubNodeClient(workResponses: [work, nil])
        let coordinator = MiningCoordinator(nodeClient: node, workers: [worker], totalBatchSize: 1)

        let result = await coordinator.runBatch()

        guard case .submitted(let workId, let nonce, let submission) = result else {
            return XCTFail("expected valid work to continue through transient probe failure, got \(result)")
        }
        XCTAssertEqual(workId, "work-1")
        XCTAssertEqual(nonce, 42)
        XCTAssertTrue(submission.accepted)
        let metrics = await coordinator.metrics()
        XCTAssertEqual(metrics.staleAbortCount, 0)
        XCTAssertEqual(metrics.acceptedSolutionCount, 1)
    }

    func testWorkAdoptsTemplateParentAsStableToken() {
        let withToken = MiningCoordinatorWork(template: TemplateResponse(
            workID: "candidate-cid",
            blockHex: "00",
            searchTarget: "ff",
            staleToken: "tip-hash"
        ))
        XCTAssertEqual(withToken?.workId, "candidate-cid")
        XCTAssertEqual(withToken?.staleToken, "tip-hash")
    }

    func testStableStaleTokenSubmitsDespiteWorkIdChurn() async {
        // Regression for the smoke-suite block-landing failure: the node restamps
        // the template timestamp every fetch, so the workId (candidate CID) churns
        // even while the tip is unchanged. With the probe keyed on the stable
        // staleToken (tip hash), a found solution must be SUBMITTED, not aborted
        // as stale. Before the fix (staleToken == workId), this churn made every
        // solution look stale and nothing was ever submitted.
        let initial = MiningCoordinatorWork(workId: "work-A", blockHex: "00", targetHex: "ff", staleToken: "tip-1")
        let churned = MiningCoordinatorWork(workId: "work-B", blockHex: "00", targetHex: "ff", staleToken: "tip-1")
        let worker = MiningCoordinatorWorker(id: "fast") { work, _ in
            MiningWorkerResult(workerId: "fast", workId: work.workId, nonce: 7)
        }
        let node = StubNodeClient(workResponses: [initial, churned, churned])
        let coordinator = MiningCoordinator(nodeClient: node, workers: [worker], totalBatchSize: 1)

        let result = await coordinator.runBatch()

        guard case .submitted(let workId, let nonce, let submission) = result else {
            return XCTFail("stable tip must submit despite workId churn, got \(result)")
        }
        XCTAssertEqual(workId, "work-A")
        XCTAssertEqual(nonce, 7)
        XCTAssertTrue(submission.accepted)
        let metrics = await coordinator.metrics()
        XCTAssertEqual(metrics.staleAbortCount, 0)
        XCTAssertEqual(metrics.acceptedSolutionCount, 1)
    }

    func testWorkerFailureFailsClosedWithoutReportingNoSolution() async {
        let worker = MiningCoordinatorWorker(id: "broken-worker") { _, _ in
            throw MiningWorkerProcessError.missingExecutable("/definitely/missing")
        }
        let node = StubNodeClient(workResponses: [work])
        let coordinator = MiningCoordinator(
            nodeClient: node,
            workers: [worker],
            totalBatchSize: 1,
            staleProbeEnabled: false
        )

        let result = await coordinator.runBatch()

        guard case .workerFailed(let workId, let workerId, let error) = result else {
            return XCTFail("expected worker failure to fail closed, got \(result)")
        }
        XCTAssertEqual(workId, "work-1")
        XCTAssertEqual(workerId, "broken-worker")
        XCTAssertTrue(error.contains("missingExecutable"))
        let submissionCount = await node.submissionCount()
        XCTAssertEqual(submissionCount, 0)
        let metrics = await coordinator.metrics()
        XCTAssertEqual(metrics.workerFailureCount, 1)
    }

    func testProcessWorkerNonzeroExitThrowsInsteadOfNoSolution() async throws {
        let client = MiningWorkerProcessClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo failed >&2; exit 1"]
        )

        do {
            _ = try await client.search(
                workerId: "exiting-worker",
                work: work,
                range: NonceSearchRange(startNonce: 0, count: 1)
            )
            XCTFail("expected nonzero worker process to throw")
        } catch let error as MiningWorkerProcessError {
            guard case .nonzeroExit(let status, let stderr) = error else {
                return XCTFail("expected nonzeroExit, got \(error)")
            }
            XCTAssertEqual(status, 1)
            XCTAssertTrue(stderr.contains("failed"))
        }
    }

    func testProcessWorkerTerminatesSubprocessOnCancellation() async throws {
        let client = MiningWorkerProcessClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            // `exec` so the shell is replaced by `sleep` and the tracked PID is a
            // direct child — matching how the coordinator spawns `LatticeMiner`.
            // Without it, dash forks `sleep` as a grandchild that survives the kill
            // and keeps the stdout pipe's write end open, blocking the read until
            // the natural 5s exit (the Linux-only failure this guards against).
            arguments: ["-c", "exec sleep 5"]
        )
        let work = self.work
        let task = Task {
            _ = try await client.search(
                workerId: "sleeping-worker",
                work: work,
                range: NonceSearchRange(startNonce: 0, count: 1)
            )
        }

        try await Task.sleep(for: .milliseconds(100))
        await assertCompletes(timeout: .milliseconds(700)) {
            task.cancel()
            _ = try? await task.value
        }
    }

    func testAssignedRangeCountTracksCurrentBatchFanout() async {
        let workers = (0..<2).map { i in
            MiningCoordinatorWorker(id: "w\(i)") { _, _ in nil }
        }
        let node = StubNodeClient(workResponses: [work, work, work, work])
        let coordinator = MiningCoordinator(nodeClient: node, workers: workers, totalBatchSize: 4)

        let first = await coordinator.runBatch()
        guard case .noSolution = first else {
            return XCTFail("expected first no-solution batch, got \(first)")
        }
        var metrics = await coordinator.metrics()
        XCTAssertEqual(metrics.assignedRangeCount, 2)

        let second = await coordinator.runBatch()
        guard case .noSolution = second else {
            return XCTFail("expected second no-solution batch, got \(second)")
        }
        metrics = await coordinator.metrics()
        XCTAssertEqual(metrics.assignedRangeCount, 2)
    }

    func testNonceOffsetResetsWhenWorkIdChanges() async {
        let recorder = RangeRecorder()
        let worker = MiningCoordinatorWorker(id: "w0") { _, range in
            await recorder.record(workerId: "w0", range: range)
            return nil
        }
        let nextWork = MiningCoordinatorWork(
            workId: "work-2",
            blockHex: "00",
            targetHex: "ff",
            staleToken: "work-2"
        )
        let node = StubNodeClient(workResponses: [work, work, nextWork])
        let coordinator = MiningCoordinator(
            nodeClient: node,
            workers: [worker],
            totalBatchSize: 4,
            nonceOffset: 5,
            staleProbeEnabled: false
        )

        _ = await coordinator.runBatch()
        _ = await coordinator.runBatch()
        _ = await coordinator.runBatch()

        let ranges = await recorder.recordedRanges()
        XCTAssertEqual(ranges, [
            NonceSearchRange(startNonce: 5, count: 4),
            NonceSearchRange(startNonce: 9, count: 4),
            NonceSearchRange(startNonce: 0, count: 4)
        ])
    }

    func testHTTPSubmitDecodesProtocolRejectionDespiteHTTPConflict() throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "http://127.0.0.1/v1/mining/work")!,
            statusCode: 409,
            httpVersion: nil,
            headerFields: nil
        ))
        let body = Data(
            #"{"accepted":false,"disposition":"duplicate","tipCID":null}"#.utf8
        )

        let submission = try HTTPMiningCoordinatorNodeClient.decodeSubmission(data: body, response: response)

        XCTAssertFalse(submission.accepted)
        XCTAssertEqual(submission.disposition, "duplicate")
    }

    func testHTTPSubmitRejectsNonJSONTransportFailure() throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "http://127.0.0.1/v1/mining/work")!,
            statusCode: 502,
            httpVersion: nil,
            headerFields: nil
        ))

        XCTAssertThrowsError(
            try HTTPMiningCoordinatorNodeClient.decodeSubmission(data: Data("<html>bad gateway</html>".utf8), response: response)
        ) { error in
            XCTAssertEqual(
                error as? MiningCoordinatorNodeClientError,
                .invalidSubmissionResponse(statusCode: 502)
            )
        }
    }

    func testHTTPSubmitTreatsJSONServerFailureAsRetryableTransportFailure() throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "http://127.0.0.1/v1/mining/work")!,
            statusCode: 503,
            httpVersion: nil,
            headerFields: nil
        ))

        XCTAssertThrowsError(
            try HTTPMiningCoordinatorNodeClient.decodeSubmission(
                data: Data(#"{"accepted":false,"disposition":"busy","tipCID":null}"#.utf8),
                response: response
            )
        ) { error in
            XCTAssertEqual(
                error as? MiningCoordinatorNodeClientError,
                .invalidSubmissionResponse(statusCode: 503)
            )
        }
    }

    func testHTTPSubmitUsesCurrentWorkRouteAndPayload() async throws {
        StubTemplateURLProtocol.responder = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/mining/work")
            XCTAssertEqual(request.httpMethod, "POST")
            let payload = requestBodyData(request).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            XCTAssertEqual(payload?["workID"] as? String, "candidate")
            XCTAssertEqual(payload?["nonce"] as? UInt64, 7)
            XCTAssertNil(payload?["workId"])
            XCTAssertNil(payload?["hash"])
            return (200, Data(
                #"{"accepted":true,"disposition":"canonicalized","tipCID":"tip"}"#.utf8
            ))
        }
        defer { StubTemplateURLProtocol.responder = nil }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubTemplateURLProtocol.self]
        let client = HTTPMiningCoordinatorNodeClient(
            apiBaseURL: URL(string: "http://127.0.0.1:1/api")!,
            session: URLSession(configuration: config)
        )

        let submission = try await client.submit(
            workId: "candidate",
            nonce: 7
        )

        XCTAssertTrue(submission.accepted)
        XCTAssertEqual(submission.disposition, "canonicalized")
        XCTAssertEqual(submission.tipCID, "tip")
    }

    func testHTTPSubmitClassifiesUnauthorizedAsFatalAuthError() throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "http://127.0.0.1/v1/mining/work")!,
            statusCode: 401,
            httpVersion: nil,
            headerFields: nil
        ))

        XCTAssertThrowsError(
            try HTTPMiningCoordinatorNodeClient.decodeSubmission(data: Data(#"{"error":"Unauthorized"}"#.utf8), response: response)
        ) { error in
            XCTAssertEqual(
                error as? MiningCoordinatorNodeClientError,
                .unauthorized(statusCode: 401)
            )
        }
    }

    func testFirstValidWorkerResultWinsAndSubmitsOnce() async {
        let slow = MiningCoordinatorWorker(id: "slow") { work, _ in
            try? await Task.sleep(for: .milliseconds(100))
            return MiningWorkerResult(workerId: "slow", workId: work.workId, nonce: 20)
        }
        let fast = MiningCoordinatorWorker(id: "fast") { work, _ in
            MiningWorkerResult(workerId: "fast", workId: work.workId, nonce: 7)
        }
        let node = StubNodeClient(workResponses: [work, work])
        let coordinator = MiningCoordinator(nodeClient: node, workers: [slow, fast], totalBatchSize: 2)

        let result = await coordinator.runBatch()

        guard case .submitted(let workId, let nonce, let submission) = result else {
            return XCTFail("expected submitted, got \(result)")
        }
        XCTAssertEqual(workId, "work-1")
        XCTAssertEqual(nonce, 7)
        XCTAssertTrue(submission.accepted)
        let submissionCount = await node.submissionCount()
        XCTAssertEqual(submissionCount, 1)
        let submissions = await node.submissions
        XCTAssertEqual(submissions.first?.workId, "work-1")
        XCTAssertEqual(submissions.first?.nonce, 7)

        let metrics = await coordinator.metrics()
        XCTAssertEqual(metrics.acceptedSolutionCount, 1)
        XCTAssertEqual(metrics.rejectedSolutionCount, 0)
    }

    func testRejectedSubmissionDoesNotLoopDuplicateSubmitsAcrossBatches() async {
        let workers = [
            MiningCoordinatorWorker(id: "a") { work, range in
                MiningWorkerResult(workerId: "a", workId: work.workId, nonce: range.startNonce)
            },
            MiningCoordinatorWorker(id: "b") { work, range in
                MiningWorkerResult(workerId: "b", workId: work.workId, nonce: range.startNonce)
            }
        ]
        let node = StubNodeClient(
            workResponses: [work, work],
            submission: .init(accepted: false, disposition: "invalid")
        )
        let coordinator = MiningCoordinator(
            nodeClient: node,
            workers: workers,
            totalBatchSize: 2,
            staleProbeEnabled: false
        )

        let first = await coordinator.runBatch()
        let second = await coordinator.runBatch()

        guard case .submitted(_, _, let firstSubmission) = first else {
            return XCTFail("expected first rejected submission, got \(first)")
        }
        guard case .submitted(_, _, let secondSubmission) = second else {
            return XCTFail("expected second rejected submission, got \(second)")
        }
        XCTAssertFalse(firstSubmission.accepted)
        XCTAssertFalse(secondSubmission.accepted)
        XCTAssertEqual(firstSubmission.disposition, "invalid")
        XCTAssertEqual(secondSubmission.disposition, "invalid")
        let submissions = await node.submissions
        XCTAssertEqual(submissions.count, 2)
        XCTAssertEqual(submissions.map(\.workId), ["work-1", "work-1"])
        XCTAssertLessThan(submissions[0].nonce, 2)
        XCTAssertGreaterThanOrEqual(submissions[1].nonce, 2)
        XCTAssertLessThan(submissions[1].nonce, 4)
        let metrics = await coordinator.metrics()
        XCTAssertEqual(metrics.acceptedSolutionCount, 0)
        XCTAssertEqual(metrics.rejectedSolutionCount, 2)
    }

    /// (a): a transient 5xx/network error during SUBMIT must not forfeit
    /// the solved block. The coordinator retries the SAME solution and lands it
    /// on a later attempt.
    func testTransientSubmitFailureResubmitsSameSolution() async {
        let worker = MiningCoordinatorWorker(id: "fast") { work, _ in
            MiningWorkerResult(workerId: "fast", workId: work.workId, nonce: 99)
        }
        // 2 transient submit failures, then accept. fetchWork queue must cover the
        // initial fetch + the stale-recheck between each retry (same tip => fresh).
        let fresh = { MiningCoordinatorWork(workId: "work-1", blockHex: "00", targetHex: "ff", staleToken: "work-1") }
        let node = RetryingSubmitStub(
            workResponses: [fresh(), fresh(), fresh(), fresh(), fresh()],
            transientFailures: 2
        )
        let coordinator = MiningCoordinator(
            nodeClient: node,
            workers: [worker],
            totalBatchSize: 1,
            staleProbeEnabled: false,
            retryBackoffDelay: .milliseconds(1),
            maxSubmitRetries: 3
        )

        let result = await coordinator.runBatch()

        guard case .submitted(let workId, let nonce, let submission) = result else {
            return XCTFail("expected eventual successful resubmit, got \(result)")
        }
        XCTAssertEqual(workId, "work-1")
        XCTAssertEqual(nonce, 99)
        XCTAssertTrue(submission.accepted, "solution must be accepted on the retry")

        let submissions = await node.recordedSubmissions()
        XCTAssertEqual(submissions.count, 3, "the same solution is POSTed 3 times (2 failures + 1 accept)")
        XCTAssertTrue(submissions.allSatisfy { $0.workId == "work-1" && $0.nonce == 99 },
                      "every retry must re-POST the same work ID and nonce")
        let metrics = await coordinator.metrics()
        XCTAssertEqual(metrics.acceptedSolutionCount, 1)
        XCTAssertEqual(metrics.rejectedSolutionCount, 0)
    }

    /// (b): if the tip is superseded mid-retry, the coordinator abandons
    /// the stale solution cleanly (a single .stale result, no infinite loop).
    func testSupersededTipMidRetryAbandonsWithoutInfiniteLoop() async {
        let worker = MiningCoordinatorWorker(id: "fast") { work, _ in
            MiningWorkerResult(workerId: "fast", workId: work.workId, nonce: 7)
        }
        // Initial work (tip-1); submit fails transiently; the stale-recheck then
        // observes a NEW tip (tip-2) => abandon.
        let initial = MiningCoordinatorWork(workId: "work-1", blockHex: "00", targetHex: "ff", staleToken: "tip-1")
        let moved = MiningCoordinatorWork(workId: "work-2", blockHex: "00", targetHex: "ff", staleToken: "tip-2")
        let node = RetryingSubmitStub(
            workResponses: [initial, moved, moved, moved],
            transientFailures: 5 // would loop forever if supersession didn't bound it
        )
        let coordinator = MiningCoordinator(
            nodeClient: node,
            workers: [worker],
            totalBatchSize: 1,
            staleProbeEnabled: false,
            retryBackoffDelay: .milliseconds(1),
            maxSubmitRetries: 10
        )

        let result = await coordinator.runBatch()

        XCTAssertEqual(result, .stale(workId: "work-1"), "superseded tip must abandon as stale")
        let submissions = await node.recordedSubmissions()
        XCTAssertEqual(submissions.count, 1, "exactly one POST before supersession abandons the retry")
        let metrics = await coordinator.metrics()
        XCTAssertEqual(metrics.staleAbortCount, 1)
        XCTAssertEqual(metrics.acceptedSolutionCount, 0)
    }

    /// (c1): a 401/403 during submit stays FATAL — surfaced as nodeFailed,
    /// not retried.
    func testUnauthorizedSubmitIsFatalAndNotRetried() async {
        let worker = MiningCoordinatorWorker(id: "fast") { work, _ in
            MiningWorkerResult(workerId: "fast", workId: work.workId, nonce: 7)
        }
        let node = StubNodeClient(
            workResponses: [work, work, work],
            submitError: MiningCoordinatorNodeClientError.unauthorized(statusCode: 403)
        )
        let coordinator = MiningCoordinator(
            nodeClient: node,
            workers: [worker],
            totalBatchSize: 1,
            staleProbeEnabled: false,
            retryBackoffDelay: .milliseconds(1)
        )

        let result = await coordinator.runBatch()

        guard case .nodeFailed = result else {
            return XCTFail("401/403 during submit must be fatal, got \(result)")
        }
        let submissionCount = await node.submissionCount()
        XCTAssertEqual(submissionCount, 1, "fatal auth error must not be retried")
    }

    /// (c2): a clean accepted:false is a DEFINITIVE answer, not a
    /// transient — it must be POSTed exactly once, never retried.
    func testCleanRejectionIsNotRetried() async {
        let worker = MiningCoordinatorWorker(id: "fast") { work, _ in
            MiningWorkerResult(workerId: "fast", workId: work.workId, nonce: 7)
        }
        let node = StubNodeClient(
            workResponses: [work, work, work],
            submission: .init(accepted: false, disposition: "invalid")
        )
        let coordinator = MiningCoordinator(
            nodeClient: node,
            workers: [worker],
            totalBatchSize: 1,
            staleProbeEnabled: false,
            retryBackoffDelay: .milliseconds(1)
        )

        let result = await coordinator.runBatch()

        guard case .submitted(_, _, let submission) = result else {
            return XCTFail("expected submitted with clean rejection, got \(result)")
        }
        XCTAssertFalse(submission.accepted)
        XCTAssertEqual(submission.disposition, "invalid")
        let submissionCount = await node.submissionCount()
        XCTAssertEqual(submissionCount, 1, "a clean accepted:false must not be retried")
        let metrics = await coordinator.metrics()
        XCTAssertEqual(metrics.rejectedSolutionCount, 1)
    }

    func testBackoffWhenNodeHasNoWork() async {
        let node = StubNodeClient(workResponses: [nil])
        let coordinator = MiningCoordinator(nodeClient: node, workers: [], totalBatchSize: 1)

        let result = await coordinator.runBatch()

        XCTAssertEqual(result, .backoff)
        let submissionCount = await node.submissionCount()
        XCTAssertEqual(submissionCount, 0)
        let metrics = await coordinator.metrics()
        XCTAssertEqual(metrics.retryBackoffCount, 1)
    }

    func testStartStopLifecycleAppliesBackoffAndStopsLoop() async {
        let node = StubNodeClient(workResponses: [nil])
        let coordinator = MiningCoordinator(
            nodeClient: node,
            workers: [],
            totalBatchSize: 1,
            retryBackoffDelay: .milliseconds(200)
        )

        let started = await coordinator.start()
        XCTAssertTrue(started)
        let observedBackoff = await waitUntil {
            await coordinator.metrics().retryBackoffCount >= 1
        }
        XCTAssertTrue(observedBackoff)
        let metrics = await coordinator.metrics()
        XCTAssertGreaterThanOrEqual(metrics.retryBackoffCount, 1)

        await coordinator.stop()
        let afterStop = await coordinator.metrics().retryBackoffCount
        try? await Task.sleep(for: .milliseconds(240))
        let afterSleep = await coordinator.metrics().retryBackoffCount
        XCTAssertEqual(afterSleep, afterStop)
    }

    func testStartIsIdempotentAndShutdownCancelsBackoffSleep() async {
        let node = StubNodeClient(workResponses: [nil])
        let coordinator = MiningCoordinator(
            nodeClient: node,
            workers: [],
            totalBatchSize: 1,
            retryBackoffDelay: .seconds(5)
        )

        let started = await coordinator.start()
        XCTAssertTrue(started)
        let startedAgain = await coordinator.start()
        XCTAssertFalse(startedAgain)
        let observedBackoff = await waitUntil {
            await coordinator.metrics().retryBackoffCount == 1
        }
        XCTAssertTrue(observedBackoff)

        await assertCompletes {
            await coordinator.shutdown()
        }
        let restarted = await coordinator.start()
        XCTAssertTrue(restarted)
        await coordinator.stop()
    }

    /// a 503 from the template route (e.g. "No parent-state-continuous
    /// child candidate" while the node waits to learn a parent-state transition)
    /// must be TRANSIENT for the coordinator — `fetchWork()` maps it to nil, which
    /// `runBatch()` turns into `.backoff` (sleep + retry), never a fatal error
    /// that stops the mining loop. Driven through the real HTTP client.
    func testHTTPFetchWorkTreats503AsTransientBackoffNotFatal() async throws {
        StubTemplateURLProtocol.responder = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/mining/templates")
            XCTAssertEqual(request.httpMethod, "POST")
            let payload = requestBodyData(request).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            XCTAssertEqual((payload?["rewards"] as? [Any])?.count, 0)
            return (
                503,
                Data(#"{"error":"No parent-state-continuous child candidate"}"#.utf8)
            )
        }
        defer { StubTemplateURLProtocol.responder = nil }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubTemplateURLProtocol.self]
        let client = HTTPMiningCoordinatorNodeClient(
            apiBaseURL: URL(string: "http://127.0.0.1:1/api")!,
            session: URLSession(configuration: config)
        )

        // No throw, no work: the 503 is "no work right now", not a failure.
        let work = try await client.fetchWork()
        XCTAssertNil(work, "a 503 template response must map to nil work (transient), not throw")

        // And the coordinator loop turns that into a retryable backoff cycle.
        let coordinator = MiningCoordinator(nodeClient: client, workers: [], totalBatchSize: 1)
        let result = await coordinator.runBatch()
        XCTAssertEqual(result, .backoff, "a 503 cycle must back off and retry, not stop the loop")
    }

    /// Contrast: 401/403 ARE fatal (`unauthorized`) — only auth failures may
    /// abort the fetch with an error.
    func testHTTPFetchWorkClassifiesUnauthorizedAsFatal() async throws {
        StubTemplateURLProtocol.responder = { _ in (401, Data(#"{"error":"Unauthorized"}"#.utf8)) }
        defer { StubTemplateURLProtocol.responder = nil }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubTemplateURLProtocol.self]
        let client = HTTPMiningCoordinatorNodeClient(
            apiBaseURL: URL(string: "http://127.0.0.1:1/api")!,
            session: URLSession(configuration: config)
        )

        do {
            _ = try await client.fetchWork()
            XCTFail("a 401 must throw unauthorized")
        } catch {
            XCTAssertEqual(error as? MiningCoordinatorNodeClientError, .unauthorized(statusCode: 401))
        }
    }

    func testHTTPFetchStaleTokenUsesChainInfoTipWithoutTemplateFetch() async throws {
        StubTemplateURLProtocol.responder = { request in
            guard request.url?.path == "/api/v1/status" else {
                return (500, Data(#"{"error":"template should not be fetched for stale token"}"#.utf8))
            }
            return (200, Data(#"{"tipCID":"child-tip"}"#.utf8))
        }
        defer { StubTemplateURLProtocol.responder = nil }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubTemplateURLProtocol.self]
        let client = HTTPMiningCoordinatorNodeClient(
            apiBaseURL: URL(string: "http://127.0.0.1:1/api")!,
            session: URLSession(configuration: config)
        )

        let token = try await client.fetchStaleToken()

        XCTAssertEqual(token, "child-tip")
    }
}

/// Minimal URLProtocol stub: answers every request with the configured
/// status/body so `HTTPMiningCoordinatorNodeClient.fetchWork()`'s status-code
/// classification is testable without a node process.
final class StubTemplateURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let (status, body) = Self.responder?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func requestBodyData(_ request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }

    var body = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count >= 0 else { return nil }
        guard count > 0 else { return body }
        body.append(contentsOf: buffer.prefix(count))
    }
}
