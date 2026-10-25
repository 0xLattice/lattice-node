import Foundation
import Ivy
import Lattice
import Tally
import XCTest
import cashew
@testable import LatticeNode

/// One byte budget for every content session of every chain: each
/// session reserves its worst case once, at its start, and releases it at
/// its end. Never exceeded, waited on in line rather than refused, and
/// never deadlocked.
final class AcquisitionBudgetTests: XCTestCase {
    /// A real content-addressed node: its CID and canonical bytes, about
    /// `padding` bytes larger than the smallest.
    private func content(_ nonce: UInt64, padding: Int = 1) throws -> (cid: String, data: Data) {
        let node = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [String(repeating: "s", count: max(1, padding))], nonce: nonce, chainPath: ["Nexus"]
        )
        return (try HeaderImpl(node: node).rawCID, try XCTUnwrap(node.toData()))
    }

    private actor Requests {
        private(set) var volumes = 0
        private(set) var bundles = 0
        func volume() { volumes += 1 }
        func bundle() { bundles += 1 }
    }

    private func eventually(_ what: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<2_500 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail(what)
    }

    /// A waiter for `bytes` at `priority`, in line before this returns.
    private func enqueue(
        _ budget: AcquisitionBudget, _ bytes: Int, _ priority: AcquisitionBudget.Priority,
        then record: @escaping @Sendable (Int?) async -> Void = { _ in }
    ) async throws -> Task<Int?, Never> {
        let before = budget.waiting
        let task = Task {
            let reserved = await budget.reserve(bytes, priority: priority)
            await record(reserved)
            return reserved
        }
        try await eventually("the waiter is in line") { budget.waiting == before + 1 }
        return task
    }

    private actor Order {
        private(set) var granted: [String] = []
        func append(_ name: String) { granted.append(name) }
    }

    /// Many sessions at once, as for several chains, half of them taking a
    /// padded bundle: every one completes, no session holds more than it
    /// reserved, the reservations never pass the budget, and all of them
    /// come back.
    func testTheBudgetIsNeverExceededAcrossManyConcurrentSessionsAndBundles() async throws {
        let items = try (0..<40).map { try content($0, padding: 20_000) }
        let padding = try (100..<104).map { try content($0, padding: 20_000) }
        let served = Dictionary(uniqueKeysWithValues: items.map { ($0.cid, $0.data) })
        let sessionBytes = 64 * 1_024
        let budget = AcquisitionBudget(capacity: 3 * sessionBytes)
        let source = IvyRootContentSource(
            maximumStorageBytes: sessionBytes,
            budget: budget,
            fetch: { root in
                try? await Task.sleep(nanoseconds: 1_000_000)
                guard let data = served[root] else { return .empty }
                return AttributedVolumeResponse(rootCID: root, entries: [root: data], servedBy: nil)
            },
            fetchBundle: { root in
                try? await Task.sleep(nanoseconds: 1_000_000)
                guard let data = served[root] else { return [] }
                // A peer pads its bundle past what the session may hold.
                return [AttributedVolumeResponse(rootCID: root, entries: [root: data], servedBy: nil)]
                    + padding.map { AttributedVolumeResponse(rootCID: $0.cid, entries: [$0.cid: $0.data], servedBy: nil) }
            }
        )
        let all = await withTaskGroup(of: Bool.self) { group in
            for (index, item) in items.enumerated() {
                group.addTask {
                    let priority: AcquisitionBudget.Priority = index % 3 == 0 ? .ownWork : .body(item.cid)
                    let reserving = index % 2 == 0 ? sessionBytes : sessionBytes / 2
                    return await source.withRootTracing(
                        item.cid, bundle: index % 2 == 0, reserving: reserving, priority: priority
                    ) { session in
                        let fetched = await session.fetch([item.cid])
                        return fetched == [item.cid: item.data] && session.accountedBytes <= reserving
                    }.value
                }
            }
            var all = true
            for await one in group { all = all && one }
            return all
        }
        XCTAssertTrue(all, "every session completes within its reservation")
        XCTAssertLessThanOrEqual(budget.peakReserved, budget.capacity)
        XCTAssertGreaterThan(budget.peakReserved, sessionBytes, "sessions ran side by side")
        XCTAssertEqual(budget.reserved, 0)
        XCTAssertEqual(budget.waiting, 0)
    }

    /// Every waiter is a chain's next block and the budget is full: each
    /// reservation comes back when its session ends, so every one runs.
    func testNoDeadlockWhenEveryWaiterIsNextToConnectAndTheBudgetIsFull() async throws {
        let items = try (0..<12).map { try content($0) }
        let served = Dictionary(uniqueKeysWithValues: items.map { ($0.cid, $0.data) })
        let sessionBytes = 16 * 1_024
        let budget = AcquisitionBudget(capacity: 2 * sessionBytes)
        budget.prioritize(Set(items.map(\.cid)))
        let source = IvyRootContentSource(
            maximumStorageBytes: sessionBytes,
            budget: budget,
            fetch: { root in
                try? await Task.sleep(nanoseconds: 5_000_000)
                guard let data = served[root] else { return .empty }
                return AttributedVolumeResponse(rootCID: root, entries: [root: data], servedBy: nil)
            }
        )
        let completed = await withTaskGroup(of: Bool.self) { group in
            for item in items {
                group.addTask {
                    await source.withRootTracing(item.cid, bundle: false, priority: .body(item.cid)) { session in
                        await session.fetch([item.cid]) == [item.cid: item.data]
                    }.value
                }
            }
            var count = 0
            for await one in group where one { count += 1 }
            return count
        }
        XCTAssertEqual(completed, items.count)
        XCTAssertEqual(budget.peakReserved, budget.capacity)
        XCTAssertEqual(budget.reserved, 0)
    }

    /// Waiters are served in arrival order, the node's own work and each
    /// chain's next block ahead of look-ahead; a look-ahead fetch whose
    /// block becomes next moves up.
    func testWaitersAreServedFirstInFirstOutWithNextToConnectAhead() async throws {
        let budget = AcquisitionBudget(capacity: 10)
        let held = await budget.reserve(10, priority: .ownWork)
        XCTAssertEqual(held, 10)
        let order = Order()
        func waiter(_ name: String, _ priority: AcquisitionBudget.Priority) async throws -> Task<Int?, Never> {
            try await enqueue(budget, 10, priority) { reserved in
                await order.append(name)
                if let reserved { budget.release(reserved) }
            }
        }
        let tasks = [
            try await waiter("ahead-1", .body("a")),
            try await waiter("ahead-2", .body("b")),
            try await waiter("next", .body("c")),
            try await waiter("own", .ownWork),
            try await waiter("ahead-3", .body("d")),
        ]
        budget.prioritize(["c"])
        budget.release(10)
        for task in tasks { _ = await task.value }
        let granted = await order.granted
        XCTAssertEqual(granted, ["next", "own", "ahead-1", "ahead-2", "ahead-3"])
        XCTAssertEqual(budget.reserved, 0)
    }

    /// A waiter cancelled in line leaves it, holding nothing; one cancelled
    /// before it was in line is never in it. A session cancelled while it
    /// waits asks no peer.
    func testCancellationLeavesNothingReserved() async throws {
        let budget = AcquisitionBudget(capacity: 10)
        let held = await budget.reserve(10, priority: .ownWork)
        XCTAssertEqual(held, 10)

        let waiting = try await enqueue(budget, 4, .body("a"))
        waiting.cancel()
        let cancelled = await waiting.value
        XCTAssertNil(cancelled)
        XCTAssertEqual(budget.waiting, 0)

        // Cancelled before it asks: nothing is reserved even with room.
        budget.release(10)
        let early = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await budget.reserve(4, priority: .ownWork)
        }
        let earlyReserved = await early.value
        XCTAssertNil(earlyReserved)
        XCTAssertEqual(budget.reserved, 0)
        XCTAssertEqual(budget.waiting, 0)

        // A session cancelled waiting runs, offline, and then holds nothing.
        let item = try content(1)
        let requests = Requests()
        let sessionBytes = 16 * 1_024
        let sessions = AcquisitionBudget(capacity: sessionBytes)
        let source = IvyRootContentSource(
            maximumStorageBytes: sessionBytes,
            budget: sessions,
            fetch: { root in
                await requests.volume()
                return AttributedVolumeResponse(rootCID: root, entries: [item.cid: item.data], servedBy: nil)
            },
            fetchBundle: { _ in
                await requests.bundle()
                return []
            }
        )
        let blocking = await sessions.reserve(sessionBytes, priority: .ownWork)
        XCTAssertEqual(blocking, sessionBytes)
        let session = Task {
            await source.withRootTracing(item.cid, priority: .body(item.cid)) { session in
                await session.fetch([item.cid])
            }
        }
        try await eventually("the session waits") { sessions.waiting == 1 }
        session.cancel()
        let answer = await session.value
        XCTAssertEqual(answer.value, [:])
        XCTAssertFalse(answer.attribution.byteBudgetExceeded, "waiting is not the budget declining content")
        XCTAssertTrue(answer.attribution.servedByPublicKeys.isEmpty)
        sessions.release(sessionBytes)
        XCTAssertEqual(sessions.reserved, 0)
        XCTAssertEqual(sessions.waiting, 0)
        let asked = await (requests.volumes, requests.bundles)
        XCTAssertEqual(asked.0, 0)
        XCTAssertEqual(asked.1, 0)
    }

    /// Every real reader reads through a `CoalescingFetcher`, whose flush
    /// asks the session from a task of its own. A body fetch cancelled
    /// while it waits on a full budget (a reorg, a window that moved, a
    /// stop) still leaves the line at once: it reserves nothing, is never
    /// granted later, and asks no peer.
    func testACancelledBodyReadingThroughACoalescingFetcherLeavesTheLineAtOnce() async throws {
        let item = try content(3)
        let requests = Requests()
        let sessionBytes = 16 * 1_024
        let budget = AcquisitionBudget(capacity: sessionBytes)
        let source = IvyRootContentSource(
            maximumStorageBytes: sessionBytes,
            budget: budget,
            fetch: { root in
                await requests.volume()
                return AttributedVolumeResponse(rootCID: root, entries: [item.cid: item.data], servedBy: nil)
            },
            fetchBundle: { _ in
                await requests.bundle()
                return []
            }
        )
        let reserved = await budget.reserve(sessionBytes, priority: .ownWork)
        let blocking = try XCTUnwrap(reserved)
        let body = Task {
            await source.withRootTracing(item.cid, priority: .body(item.cid)) { session in
                try? await CoalescingFetcher(session).fetch(rawCid: item.cid)
            }
        }
        try await eventually("the body waits") { budget.waiting == 1 }
        body.cancel()
        try await eventually("the cancelled body leaves the line while the budget is full") { budget.waiting == 0 }
        let answer = await body.value
        XCTAssertNil(answer.value)
        XCTAssertEqual(budget.reserved, blocking, "the cancelled body reserved nothing")
        budget.release(blocking)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(budget.reserved, 0, "nothing is granted to it later")
        XCTAssertEqual(budget.waiting, 0)
        let asked = await (requests.volumes, requests.bundles)
        XCTAssertEqual(asked.0, 0)
        XCTAssertEqual(asked.1, 0)
    }

    /// Waiting on the budget is no peer's failure: the attribution a
    /// session reports, which status and backoff read, is the same as for
    /// one that never waited, and the peer is credited the same.
    func testWaitingOnTheBudgetDoesNotChangeBlameCreditOrStatus() async throws {
        let item = try content(2)
        let server = PeerID(publicKey: String(repeating: "cd", count: 32))
        actor Ledger {
            private(set) var credited: [Int] = []
            private(set) var reported = 0
            func credit(_ bytes: Int) { credited.append(bytes) }
            func report() { reported += 1 }
        }
        let sessionBytes = 16 * 1_024
        func run(waiting: Bool) async throws -> (IvyRootContentSource.Attribution, [Int], Int) {
            let ledger = Ledger()
            let budget = AcquisitionBudget(capacity: sessionBytes)
            let source = IvyRootContentSource(
                maximumStorageBytes: sessionBytes,
                budget: budget,
                fetch: { root in
                    AttributedVolumeResponse(rootCID: root, entries: [item.cid: item.data], servedBy: server)
                },
                credit: { _, bytes in await ledger.credit(bytes) },
                report: { _, _ in await ledger.report() }
            )
            let blocking = waiting ? await budget.reserve(sessionBytes, priority: .ownWork) : nil
            let session = Task {
                await source.withRootTracing(item.cid, bundle: false, priority: .body(item.cid)) { session in
                    await session.fetch([item.cid])
                }
            }
            if let blocking {
                try await eventually("the session waits") { budget.waiting == 1 }
                try await Task.sleep(nanoseconds: 20_000_000)
                budget.release(blocking)
            }
            let answer = await session.value
            XCTAssertEqual(answer.value, [item.cid: item.data])
            return (answer.attribution, await ledger.credited, await ledger.reported)
        }
        let direct = try await run(waiting: false)
        let waited = try await run(waiting: true)
        XCTAssertEqual(waited.0, direct.0)
        XCTAssertEqual(waited.1, direct.1)
        XCTAssertEqual(waited.2, 0)
        XCTAssertFalse(waited.0.byteBudgetExceeded)
        XCTAssertFalse(waited.0.localCapacityUnavailable)
        XCTAssertFalse(waited.0.contentUnavailable)
    }
}
