import XCTest
@testable import LatticeNode

final class TimersTests: XCTestCase {

    private actor Recorder {
        var fired: [UInt64] = []
        var count = 0
        func record(_ generation: UInt64) { fired.append(generation) }
        func bump() -> Int {
            count += 1
            return count
        }
    }

    func testDeadlineFiresWithItsGeneration() async {
        let recorder = Recorder()
        let task = Timers.deadline(after: .milliseconds(10), generation: 42) {
            await recorder.record($0)
        }
        await task.value
        let fired = await recorder.fired
        XCTAssertEqual(fired, [42])
    }

    func testCancelledDeadlineDoesNotFire() async throws {
        let recorder = Recorder()
        let task = Timers.deadline(after: .milliseconds(50), generation: 7) {
            await recorder.record($0)
        }
        task.cancel()
        await task.value
        try await Task.sleep(nanoseconds: 100_000_000)
        let fired = await recorder.fired
        XCTAssertEqual(fired, [])
    }

    func testSleepReportsCancellation() async {
        let completed = await Timers.sleep(nanoseconds: 1_000_000)
        XCTAssertTrue(completed)
        let task = Task { await Timers.sleep(nanoseconds: 10_000_000_000) }
        task.cancel()
        let cancelled = await task.value
        XCTAssertFalse(cancelled)
    }

    func testNanosecondsClampsAndSaturates() {
        XCTAssertEqual(Timers.nanoseconds(.milliseconds(1500)), 1_500_000_000)
        XCTAssertEqual(Timers.nanoseconds(.seconds(-1)), 0)
        XCTAssertEqual(Timers.nanoseconds(.seconds(Int64.max)), UInt64.max)
    }

    func testRetryReturnsTheFirstValueWithCapacity() async {
        let recorder = Recorder()
        let result = await Timers.retryWhileCapacityUnavailable(
            every: .milliseconds(1),
            attempt: { await recorder.bump() },
            capacityUnavailable: { $0 < 3 },
            stillCurrent: { true }
        )
        guard case .value(let value) = result else {
            return XCTFail("expected a value, got \(result)")
        }
        XCTAssertEqual(value, 3)
    }

    func testRetryReportsStaleAfterTheSleep() async {
        let recorder = Recorder()
        let result = await Timers.retryWhileCapacityUnavailable(
            every: .milliseconds(1),
            attempt: { await recorder.bump() },
            capacityUnavailable: { _ in true },
            stillCurrent: { false }
        )
        guard case .stale = result else {
            return XCTFail("expected stale, got \(result)")
        }
        let attempts = await recorder.count
        XCTAssertEqual(attempts, 1)
    }

    func testRetryReportsCancellation() async {
        let task = Task { () -> String in
            let result = await Timers.retryWhileCapacityUnavailable(
                every: .seconds(10),
                attempt: { 0 },
                capacityUnavailable: { _ in true },
                stillCurrent: { true }
            )
            return "\(result)"
        }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, "cancelled")
    }

    func testPollReturnsDoneValue() async {
        let recorder = Recorder()
        let result = await Timers.poll(every: .milliseconds(1), onCancel: -1) {
            let count = await recorder.bump()
            return count < 3 ? .again : .done(count)
        }
        XCTAssertEqual(result, 3)
    }

    func testPollReturnsOnCancelWhenItsSleepIsCancelled() async {
        let task = Task {
            await Timers.poll(every: .seconds(10), onCancel: -1) {
                Timers.Step<Int>.again
            }
        }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, -1)
    }

    func testRepeatingActsFirstThenSleepsWhileTheConditionHolds() async {
        let recorder = Recorder()
        var remaining = 3
        await Timers.repeating(every: .milliseconds(1), while: { remaining > 0 }) {
            remaining -= 1
            _ = await recorder.bump()
        }
        let count = await recorder.count
        XCTAssertEqual(count, 3)
    }
}
