import XCTest
@testable import LatticeNode

/// The overlay's bounded handoff is a memory-safety boundary: a fast peer
/// must stop at capacity, and shutdown must not strand connection tasks that
/// are waiting for room.
final class NodeRuntimeInputGateTests: XCTestCase {
    func testAcquireWaitsAtCapacityUntilTheLoopReleasesRoom() async throws {
        let gate = NodeRuntimeInputGate(capacity: 1)
        await gate.acquire()
        let started = Latch()
        let passed = Latch()

        let waiter = Task {
            await started.open()
            await gate.acquire()
            await passed.open()
        }
        await started.wait()
        try await alwaysDuring("an input waits at capacity", .milliseconds(50)) {
            !(await passed.isOpen)
        }

        await gate.release()
        await passed.wait()
        await waiter.value
    }

    func testCloseWakesEveryBlockedDeliveryAndFutureAcquiresDoNotBlock() async throws {
        let gate = NodeRuntimeInputGate(capacity: 1)
        await gate.acquire()
        let firstStarted = Latch()
        let secondStarted = Latch()
        let firstPassed = Latch()
        let secondPassed = Latch()

        let first = Task {
            await firstStarted.open()
            await gate.acquire()
            await firstPassed.open()
        }
        await firstStarted.wait()
        try await alwaysDuring("the first delivery is parked", .milliseconds(25)) {
            !(await firstPassed.isOpen)
        }
        let second = Task {
            await secondStarted.open()
            await gate.acquire()
            await secondPassed.open()
        }
        await secondStarted.wait()
        try await alwaysDuring("both deliveries are parked", .milliseconds(25)) {
            let firstIsOpen = await firstPassed.isOpen
            let secondIsOpen = await secondPassed.isOpen
            return !firstIsOpen && !secondIsOpen
        }

        await gate.close()
        await firstPassed.wait()
        await secondPassed.wait()
        await first.value
        await second.value

        // A delivery racing with or arriving after shutdown must also return;
        // otherwise Ivy can keep a stopped runtime alive indefinitely.
        let afterClose = Latch()
        let late = Task {
            await gate.acquire()
            await afterClose.open()
        }
        try await eventually("an acquire after close returns") {
            await afterClose.isOpen
        }
        await late.value
    }
}
