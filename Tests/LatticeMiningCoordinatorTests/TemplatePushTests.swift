import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import Lattice
import cashew
@testable import LatticeMiningCoordinator
import LatticeMinerCore
import UInt256

/// A node that pushes templates when told to and counts any poll.
private actor PushingNode: MiningCoordinatorNodeClient {
    private let stream: AsyncThrowingStream<MiningCoordinatorPush, any Error>
    private let feed: AsyncThrowingStream<MiningCoordinatorPush, any Error>.Continuation
    private let fetched: MiningCoordinatorWork?
    private(set) var polls = 0

    init(fetched: MiningCoordinatorWork? = nil) {
        (stream, feed) = AsyncThrowingStream.makeStream()
        self.fetched = fetched
    }

    nonisolated func templates() -> AsyncThrowingStream<MiningCoordinatorPush, any Error>? { stream }

    nonisolated func push(_ work: MiningCoordinatorWork, clean: Bool) {
        feed.yield(MiningCoordinatorPush(work: work, clean: clean))
    }

    func fetchWork() async throws -> MiningCoordinatorWork? {
        polls += 1
        return fetched
    }

    func fetchStaleToken() async throws -> String? {
        polls += 1
        return nil
    }

    func submit(workId: String, nonce: UInt64) async throws -> MiningSolutionSubmission {
        MiningSolutionSubmission(accepted: true, disposition: "canonicalized")
    }
}

private actor Searches {
    private(set) var workIDs: [String] = []
    private(set) var cancelled = 0
    func record(_ workID: String) { workIDs.append(workID) }
    func recordCancel() { cancelled += 1 }
}

final class TemplatePushTests: XCTestCase {
    private func work(_ id: String) -> MiningCoordinatorWork {
        MiningCoordinatorWork(workId: id, blockHex: "00", targetHex: "ff")
    }

    /// A clean push (the tip moved) ends the search at once; nothing polls.
    func testACleanPushCancelsTheSearch() async {
        let node = PushingNode()
        let searches = Searches()
        let worker = MiningCoordinatorWorker(id: "grinder") { work, _ in
            await searches.record(work.workId)
            try? await Task.sleep(for: .seconds(10))
            if Task.isCancelled { await searches.recordCancel() }
            return nil
        }
        let coordinator = MiningCoordinator(nodeClient: node, workers: [worker], totalBatchSize: 1)
        node.push(work("w1"), clean: true)
        await coordinator.awaitPush()
        let batch = Task { await coordinator.runBatch() }
        while await searches.workIDs.isEmpty { await Task.yield() }
        node.push(work("w2"), clean: true)

        let started = ContinuousClock.now
        let result = await batch.value
        XCTAssertEqual(result, .stale(workId: "w1"))
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
        let cancelled = await searches.cancelled
        XCTAssertEqual(cancelled, 1)
        let polls = await node.polls
        XCTAssertEqual(polls, 0)
    }

    /// A push that is not clean (only the pool or a descendant moved) leaves
    /// the search running; the next batch takes the new work.
    func testAPushThatIsNotCleanWaitsForTheNextBatch() async {
        let node = PushingNode()
        let searches = Searches()
        let worker = MiningCoordinatorWorker(id: "grinder") { work, _ in
            await searches.record(work.workId)
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { await searches.recordCancel() }
            return nil
        }
        let coordinator = MiningCoordinator(nodeClient: node, workers: [worker], totalBatchSize: 1)
        node.push(work("w1"), clean: true)
        await coordinator.awaitPush()
        let batch = Task { await coordinator.runBatch() }
        while await searches.workIDs.isEmpty { await Task.yield() }
        node.push(work("w2"), clean: false)

        let first = await batch.value
        XCTAssertEqual(first, .noSolution(workId: "w1"))
        let cancelled = await searches.cancelled
        XCTAssertEqual(cancelled, 0)
        let second = await coordinator.runBatch()
        XCTAssertEqual(second, .noSolution(workId: "w2"))
        let polls = await node.polls
        XCTAssertEqual(polls, 0)
    }

    func testServerSentEventFraming() {
        var parser = ServerSentEventParser()
        XCTAssertEqual(parser.feed(Data(": keepalive\n\nevent: templ".utf8)), [])
        let events = parser.feed(Data("ate\r\ndata: {\"a\":\ndata: 1}\n\nevent: end\ndata: busy\n\n".utf8))
        XCTAssertEqual(events.map(\.name), ["template", "end"])
        XCTAssertEqual(events.first?.data, Data("{\"a\":\n1}".utf8))
        XCTAssertEqual(events.last?.data, Data("busy".utf8))
    }

    /// The HTTP client reads the event stream, marks a reconnect's first
    /// push clean, and reconnects when the connection ends.
    func testHTTPClientStreamsTemplatesAndReconnects() async throws {
        let block = try await BlockBuilder.buildGenesis(
            spec: ChainSpec(
                maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000, premine: 0,
                targetBlockTime: 1_000, initialReward: 1_024, halvingInterval: 10_000, halfLife: 10
            ),
            timestamp: 1, target: UInt256.max, fetcher: InMemoryContentSource([:])
        )
        struct Wire: Encodable {
            let workID: String
            let block: Block
            let searchTarget: UInt256
            let targets: [UInt256]
            let chainPath: [String]
            let templateDigest: String
            let clean: Bool?
        }
        func event(_ id: String, clean: Bool?) throws -> String {
            let json = try JSONEncoder().encode(Wire(
                workID: id, block: block, searchTarget: .max, targets: [.max], chainPath: ["Nexus"],
                templateDigest: "d-\(id)", clean: clean
            ))
            return "event: template\ndata: \(String(decoding: json, as: UTF8.self))\n\n"
        }
        let connections = [
            try event("a", clean: true) + ": keepalive\n\n" + (try event("b", clean: false)),
            try event("c", clean: nil),
            // A refused subscription: the client stops and the coordinator fetches.
            "event: end\ndata: busy\n\n",
        ]
        let served = Counter()
        StubTemplateURLProtocol.responder = { request in
            XCTAssertEqual(request.url?.path, "/api/mining/templates/subscribe")
            let index = served.next()
            XCTAssertLessThan(index, connections.count, "no reconnect after a refusal")
            return index < connections.count ? (200, Data(connections[index].utf8)) : (404, Data())
        }
        defer { StubTemplateURLProtocol.responder = nil }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubTemplateURLProtocol.self]
        let client = HTTPMiningCoordinatorNodeClient(
            apiBaseURL: URL(string: "http://127.0.0.1:1/api")!,
            session: URLSession(configuration: config)
        )

        var pushes: [MiningCoordinatorPush] = []
        do {
            for try await push in client.templates()! { pushes.append(push) }
            XCTFail("the stream ends when the subscription is refused")
        } catch let error as MiningCoordinatorNodeClientError {
            XCTAssertEqual(error, .subscriptionUnavailable)
        }
        XCTAssertEqual(pushes.map(\.work.workId), ["a", "b", "c"])
        XCTAssertEqual(pushes.map(\.clean), [true, false, true])
        XCTAssertEqual(pushes.map(\.work.staleToken), ["d-a", "d-b", "d-c"])
    }

    /// Before the first push a batch fetches; the subscriber's first push is
    /// clean, but on the same tip it leaves the fetched work running.
    func testAFirstPushOnTheSameTipKeepsFetchedWork() async {
        let node = PushingNode(fetched: work("w1"))
        let searches = Searches()
        let worker = MiningCoordinatorWorker(id: "grinder") { work, _ in
            await searches.record(work.workId)
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { await searches.recordCancel() }
            return nil
        }
        let coordinator = MiningCoordinator(nodeClient: node, workers: [worker], totalBatchSize: 1)
        let batch = Task { await coordinator.runBatch() }
        while await searches.workIDs.isEmpty { await Task.yield() }
        node.push(work("w1"), clean: true)

        let result = await batch.value
        XCTAssertEqual(result, .noSolution(workId: "w1"))
        let cancelled = await searches.cancelled
        XCTAssertEqual(cancelled, 0)
    }

    /// Against a node without the route, the coordinator fetches and probes.
    func testANodeWithoutTheRouteFallsBackToFetching() async {
        let node = FallbackNode(work: work("polled"))
        let coordinator = MiningCoordinator(
            nodeClient: node, workers: [MiningCoordinatorWorker(id: "w") { _, _ in nil }], totalBatchSize: 1
        )
        let result = await coordinator.runBatch()
        XCTAssertEqual(result, .noSolution(workId: "polled"))
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value - 1
    }
}

private actor FallbackNode: MiningCoordinatorNodeClient {
    let work: MiningCoordinatorWork
    init(work: MiningCoordinatorWork) { self.work = work }

    nonisolated func templates() -> AsyncThrowingStream<MiningCoordinatorPush, any Error>? {
        AsyncThrowingStream { $0.finish(throwing: MiningCoordinatorNodeClientError.subscriptionUnavailable) }
    }

    func fetchWork() async throws -> MiningCoordinatorWork? { work }

    func submit(workId: String, nonce: UInt64) async throws -> MiningSolutionSubmission {
        MiningSolutionSubmission(accepted: false, disposition: "invalid")
    }
}
