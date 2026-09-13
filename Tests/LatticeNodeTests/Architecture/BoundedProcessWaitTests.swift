import Foundation
#if canImport(Glibc)
import Glibc
#endif
import XCTest
import LatticeCtlCore
import LatticeProcessWait

/// #62: `lattice mine run` parked in a wait that could never return for 1.7
/// days while both chains froze. These pin the mechanism, not the symptom.
///
/// What each leg actually covers, because it is NOT obvious:
///   - the DRAIN bound, through `spawnCollectingOutput`:
///     testSpawnReturnsWhenAChildExitsButAGrandchildHoldsStdoutOpen
///   - the EXIT-WAIT bound, driven directly:
///     testDeadlineKillsTheWholeProcessGroup
///   - the EXIT-WAIT bound THROUGH `spawnCollectingOutput`, the path
///     `mine run` actually takes: testSpawnReturnsWhenTheChildNeverExits
///   - the literal #62 condition — a child that exits WITHOUT its
///     termination callback being delivered -- is NOT covered. The callback
///     is corelibs' to deliver, so no stub can withhold it. That leg rests
///     on the mechanism argument (the deadline path resumes the continuation
///     itself rather than awaiting a callback), not on a test.
///
/// Each test is itself bounded by an XCTWaiter, so the UNFIXED code fails
/// with a timeout rather than hanging the suite forever — the discipline
/// #141 asks of the E2E suite.
final class BoundedProcessWaitTests: XCTestCase {
    /// Runs `body` under a hard bound. A wait that never returns FAILS here.
    private func withinDeadline(
        _ seconds: TimeInterval,
        _ label: String,
        _ body: @escaping @Sendable () async -> Void
    ) {
        let finished = expectation(description: label)
        let work = Task {
            await body()
            finished.fulfill()
        }
        let outcome = XCTWaiter.wait(for: [finished], timeout: seconds)
        // Reap the in-flight work when the bound fires. Leaving it running
        // let a failing control burn ~16 minutes AFTER its 30s bound had
        // already fired: a harness that does not reap what it started is
        // the very thing #141 objects to.
        work.cancel()
        XCTAssertEqual(
            outcome, .completed,
            "\(label) did not return within \(seconds)s: the bound under test is not holding"
        )
    }

    private func script(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-\(UUID().uuidString).sh")
        try "#!/bin/sh\n\(body)\n".write(
            to: url, atomically: true, encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )
        return url
    }

    /// Covers the DRAIN bound, and ONLY that. The child exits immediately, so
    /// the exit wait returns either way; what hung was
    /// `readDataToEndOfFile()` waiting for an EOF the forked grandchild holds
    /// back by keeping the stdout write-end open. Established by control:
    /// with the exit wait left unbounded and only the drain bounded, this
    /// still passes, so it does not witness the exit-wait bound.
    func testSpawnReturnsWhenAChildExitsButAGrandchildHoldsStdoutOpen() throws {
        let stub = try script("sleep 60 &\necho ready\nexit 0")
        defer { try? FileManager.default.removeItem(at: stub) }

        withinDeadline(30, "bounded drain with an stdout-holding grandchild") {
            let result = try? await spawnCollectingOutput(
                executable: stub, arguments: [], deadline: .seconds(3)
            )
            XCTAssertNotNil(result, "spawn threw instead of returning")
            XCTAssertTrue(
                String(decoding: result?.output ?? Data(), as: UTF8.self)
                    .contains("ready"),
                "the child's line must survive the bounded read"
            )
        }
    }

    /// A deadline that kills only the pid leaves grandchildren running: #141
    /// orphaned two live lattice-node processes to init exactly that way. The
    /// whole group must go.
    func testDeadlineKillsTheWholeProcessGroup() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("grandchild-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: marker) }
        let stub = try script(
            "sh -c 'echo $$ > \(marker.path); sleep 60' &\nsleep 60"
        )
        defer { try? FileManager.default.removeItem(at: stub) }

        let process = Process()
        process.executableURL = stub
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let handle = try runBounded(process, deadline: .seconds(2))

        withinDeadline(30, "deadline kill") {
            let outcome = await handle.wait()
            XCTAssertEqual(outcome, .deadlineExceeded)
        }

        let grandchild = (try? String(contentsOf: marker, encoding: .utf8))
            .flatMap {
                Int32($0.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        guard let grandchild else {
            return XCTFail("the stub never recorded a grandchild pid")
        }
        // The SIGKILL escalation is asynchronous; poll within a bound.
        var alive = true
        for _ in 0..<50 where alive {
            usleep(100_000)
            alive = kill(grandchild, 0) == 0
        }
        XCTAssertFalse(
            alive,
            "grandchild \(grandchild) survived: only the pid was killed"
        )
    }

    /// A child that exits normally still reports its status, so the deadline
    /// path never swallows an ordinary result.
    func testNormalExitReportsItsStatusNotTheDeadline() throws {
        let stub = try script("echo hello\nexit 7")
        defer { try? FileManager.default.removeItem(at: stub) }

        withinDeadline(30, "normal exit") {
            let result = try? await spawnCollectingOutput(
                executable: stub, arguments: [], deadline: .seconds(30)
            )
            XCTAssertEqual(result?.outcome, .exited(status: 7))
            XCTAssertEqual(result?.outputComplete, true)
            XCTAssertTrue(
                String(decoding: result?.output ?? Data(), as: UTF8.self)
                    .contains("hello")
            )
        }
    }

    /// The deadline derives from the round's own parameters: what the node
    /// advertised as template expiry, plus the longest round that actually
    /// completed, times the operator's headroom.
    func testDeadlineDerivesFromObservedRoundParameters() {
        XCTAssertEqual(
            MiningRoundDeadline.deadline(
                templateExpiry: .seconds(30),
                longestCompletedRound: .zero,
                multiplier: 10
            ),
            .seconds(300)
        )
        // A host whose rounds legitimately run long widens its own bound.
        XCTAssertEqual(
            MiningRoundDeadline.deadline(
                templateExpiry: .seconds(30),
                longestCompletedRound: .seconds(20),
                multiplier: 10
            ),
            .seconds(500)
        )
        // Operator headroom is honoured.
        XCTAssertEqual(
            MiningRoundDeadline.deadline(
                templateExpiry: .seconds(30),
                longestCompletedRound: .zero,
                multiplier: 2
            ),
            .seconds(60)
        )
        // A zero multiplier would kill every healthy round; the floor holds.
        XCTAssertEqual(
            MiningRoundDeadline.deadline(
                templateExpiry: .seconds(30),
                longestCompletedRound: .zero,
                multiplier: 0
            ),
            .seconds(30)
        )
    }

    /// A completed round is bounded only by the PREVIOUS deadline, so feeding
    /// it back unclamped ratchets the bound by the multiplier every time --
    /// 300s, 3300s, 33300s -- and a few slow-but-completing rounds would
    /// recreate the multi-day freeze the bound exists to stop.
    func testMeasuredRoundCannotRatchetTheBound() {
        let first = MiningRoundDeadline.deadline(
            templateExpiry: .seconds(30),
            longestCompletedRound: .zero,
            multiplier: 10
        )
        XCTAssertEqual(first, .seconds(300))
        // A round that completed just inside that deadline must not widen it
        // beyond the clamp.
        let second = MiningRoundDeadline.deadline(
            templateExpiry: .seconds(30),
            longestCompletedRound: first,
            multiplier: 10
        )
        XCTAssertEqual(second, .seconds(600))
        // And that is a fixed point: no sequence of rounds climbs past it.
        XCTAssertEqual(
            MiningRoundDeadline.deadline(
                templateExpiry: .seconds(30),
                longestCompletedRound: second,
                multiplier: 10
            ),
            .seconds(600)
        )
    }

    /// A second wait on a settled handle must return the same answer at once.
    /// This is a public API whose whole promise is that a wait cannot hang.
    func testSecondWaitReturnsTheSameOutcomeInsteadOfHanging() throws {
        let stub = try script("exit 3")
        defer { try? FileManager.default.removeItem(at: stub) }
        let process = Process()
        process.executableURL = stub
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let handle = try runBounded(process, deadline: .seconds(30))

        withinDeadline(30, "repeated wait") {
            let first = await handle.wait()
            let second = await handle.wait()
            XCTAssertEqual(first, .exited(status: 3))
            XCTAssertEqual(second, first)
        }
    }

    /// Covers the EXIT-WAIT bound THROUGH `spawnCollectingOutput`, which is
    /// the path `mine run` actually takes -- it never calls `runBounded`
    /// directly. A child that never exits makes the deadline the only escape
    /// from the exit wait, so restoring an unbounded wait inside the spawn
    /// helper fails here. `testDeadlineKillsTheWholeProcessGroup` cannot
    /// catch that regression: it drives `runBounded` directly and bypasses
    /// this path entirely.
    func testSpawnReturnsWhenTheChildNeverExits() throws {
        let stub = try script("sleep 60")
        defer { try? FileManager.default.removeItem(at: stub) }

        withinDeadline(30, "bounded exit wait through spawnCollectingOutput") {
            let started = ContinuousClock.now
            let result = try? await spawnCollectingOutput(
                executable: stub, arguments: [], deadline: .seconds(3)
            )
            let elapsed = started.duration(to: ContinuousClock.now)
            XCTAssertEqual(
                result?.outcome, .deadlineExceeded,
                "the deadline, not the child, must end this round"
            )
            XCTAssertLessThan(
                elapsed, .seconds(20),
                "returned only after the child died on its own"
            )
        }
    }
}
