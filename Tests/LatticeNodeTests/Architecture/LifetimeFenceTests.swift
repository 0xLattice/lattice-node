import Crypto
import Foundation
import Ivy
import Lattice
import XCTest
@testable import LatticeNode

/// The lifetime fences: `LifetimeToken`, `TaskSlot`, the parent-state query
/// guard's holds, and the runtime sites that stored work outliving its
/// generation used to clobber (#202). Each runtime case recreates the
/// interleaving directly: the stale party runs after teardown emptied the
/// slot and the next generation filled it again.
final class LifetimeFenceTests: NetworkTrustTestCase {

    // MARK: - LifetimeToken

    func testTokensAreNeverZeroAndNeverRepeat() {
        var seen = Set<UInt64>()
        for _ in 0..<1_000 {
            let token = LifetimeToken.next()
            XCTAssertNotEqual(token.rawValue, 0)
            XCTAssertTrue(seen.insert(token.rawValue).inserted)
        }
    }

    /// #202 item 5: request IDs are lifetime tokens, so no two runtimes (and
    /// no two generations of one) ever issue the same ID; a table keyed by
    /// request ID alone cannot be answered by another generation's request.
    func testRequestIDsAreUniqueAcrossRuntimesAndRestarts() async throws {
        let first = try await overlayRuntime(keyByte: 0xe1, requestTimeout: .seconds(5))
        let second = try await overlayRuntime(keyByte: 0xe2, requestTimeout: .seconds(5))
        var seen = Set<UInt64>()
        for runtime in [first.runtime, second.runtime, first.runtime] {
            for _ in 0..<50 {
                let id = await runtime.makeRequestID()
                XCTAssertNotEqual(id, 0)
                XCTAssertTrue(seen.insert(id).inserted, "request ID \(id) issued twice")
            }
        }
        try await first.runtime.start(process: first.process, chain: inertNetworkHandlers())
        await first.runtime.stop()
        let afterRestart = await first.runtime.makeRequestID()
        XCTAssertFalse(seen.contains(afterRestart))
    }

    // MARK: - TaskSlot

    func testSlotStartsOnlyWhenEmptyAndClearsOnlyForItsOwnToken() {
        var slot = TaskSlot()
        XCTAssertTrue(slot.isEmpty)
        let first = slot.start { _ in Task {} }
        XCTAssertNotNil(first)
        XCTAssertNil(slot.start { _ in Task {} }, "an occupied slot is left alone")
        XCTAssertTrue(slot.holds(first!))

        slot.cancel()  // teardown
        XCTAssertTrue(slot.isEmpty)
        XCTAssertFalse(slot.holds(first!), "teardown fences the old task out")

        let second = slot.start { _ in Task {} }
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(slot.clear(first!), "a stale task cannot empty the newer handle")
        XCTAssertTrue(slot.holds(second!))
        XCTAssertTrue(slot.clear(second!))
        XCTAssertTrue(slot.isEmpty)
        XCTAssertFalse(slot.clear(second!), "a second clear finds nothing")
    }

    func testSlotHandsItsTokenToTheTaskItStarts() async {
        var slot = TaskSlot()
        var handed: LifetimeToken?
        let token = slot.start { token in
            handed = token
            return Task {}
        }
        XCTAssertEqual(handed, token)
        let task = slot.take()
        XCTAssertNotNil(task)
        XCTAssertTrue(slot.isEmpty)
        await task?.value
    }

    func testSlotCancelCancelsTheHeldTask() async {
        var slot = TaskSlot()
        let started = Latch()
        slot.start { _ in
            Task {
                await started.open()
                _ = await Timers.sleep(nanoseconds: 60_000_000_000)
            }
        }
        await started.wait()
        let task = slot.take()
        task?.cancel()
        await task?.value
        XCTAssertTrue(task?.isCancelled ?? false)
    }

    // MARK: - #202 item 3: the parent-state query guard

    func testAStaleReleaseCannotFreeTheNextGenerationsSlot() throws {
        let peer = try PeerKey(rawRepresentation: Data(repeating: 7, count: PeerKey.byteCount))
        var guardState = ParentStateQueryGuard(capacity: 1)
        let stale = try XCTUnwrap(guardState.acquire(peer))
        guardState.removeAll()  // stop
        let current = try XCTUnwrap(guardState.acquire(peer))  // restart, same peer
        guardState.release(stale)  // the old handler's defer, late
        XCTAssertEqual(Set(guardState.peers.keys), [peer], "the new holder keeps its slot")
        XCTAssertNil(guardState.acquire(peer), "and a duplicate is still refused")
        guardState.release(current)
        XCTAssertTrue(guardState.peers.isEmpty)
    }

    // MARK: - #202 item 1: the range-sync re-entry probe

    func testAStaleReentryProbeLeavesTheNewerProbeArmed() async throws {
        let target = try await overlayRuntime(keyByte: 0xe3, requestTimeout: .seconds(5))
        let newerStillArmed = await target.runtime.fireStaleReentryProbeAfterRestart()
        XCTAssertTrue(newerStillArmed)
    }

    // MARK: - #202 item 2: the child-evidence sync worker

    func testAStaleEvidenceSyncWorkerLeavesTheNewerWorkerAndItsWork() async throws {
        let target = try await overlayRuntime(keyByte: 0xe4, requestTimeout: .seconds(5))
        let outcome = await target.runtime.runStaleEvidenceSyncAfterRestart(
            process: target.process
        )
        XCTAssertTrue(outcome.newerStillHeld, "the stale worker emptied the newer handle")
        XCTAssertEqual(outcome.queued, 1, "the stale worker took the new generation's work")
    }
}

extension NodeNetworkRuntime {
    /// A probe armed before a stop fires after the restart armed its own.
    fileprivate func fireStaleReentryProbeAfterRestart() async -> Bool {
        guard let stale = overlayState.rangeSync.reentryTask.start({ _ in Task {} })
        else { return false }
        overlayState.rangeSync.reentryTask.cancel()  // the stop
        guard let newer = overlayState.rangeSync.reentryTask.start({ _ in Task {} })
        else { return false }
        await maybeRestartRangeSync(generation: runtimeGeneration, token: stale)
        defer { overlayState.rangeSync.reentryTask.cancel() }
        return overlayState.rangeSync.reentryTask.holds(newer)
    }

    /// A sync worker started before a stop runs after the restart started
    /// its own and marked a peer for it.
    fileprivate func runStaleEvidenceSyncAfterRestart(
        process: ChainProcess
    ) async -> (newerStillHeld: Bool, queued: Int) {
        guard let stale = overlayState.childEvidenceSync.start({ _ in Task {} })
        else { return (false, -1) }
        overlayState.childEvidenceSync.cancel()  // the stop
        guard let newer = overlayState.childEvidenceSync.start({ _ in Task {} })
        else { return (false, -1) }
        let key = try! PeerKey(String(repeating: "ab", count: 32))
        overlayState.overlayRecords.update(key) { $0.evidenceWalkDirty = true }
        await runChildEvidenceSync(
            token: stale,
            generation: runtimeGeneration,
            process: process
        )
        let outcome = (
            overlayState.childEvidenceSync.holds(newer),
            overlayState.overlayRecords.records.values
                .filter(\.evidenceWalkDirty).count
        )
        overlayState.overlayRecords.remove(key)
        overlayState.childEvidenceSync.cancel()
        return outcome
    }
}
