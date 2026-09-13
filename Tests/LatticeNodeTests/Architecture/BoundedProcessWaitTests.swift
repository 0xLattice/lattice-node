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
        Task {
            await body()
            finished.fulfill()
        }
        let outcome = XCTWaiter.wait(for: [finished], timeout: seconds)
        XCTAssertEqual(
            outcome, .completed,
            "\(label) did not return within \(seconds)s: the wait is unbounded"
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

    /// THE #62 SHAPE. The child exits immediately, but a grandchild it forked
    /// inherited the stdout pipe write-end and holds it open. The old path
    /// waits on a `terminationHandler` and then blocks in
    /// `readDataToEndOfFile()` for an EOF that never comes, so the loop parks
    /// forever with the coordinator already dead. The bounded path returns.
    func testSpawnReturnsWhenAChildExitsButAGrandchildHoldsStdoutOpen() throws {
        let stub = try script("sleep 600 &\necho ready\nexit 0")
        defer { try? FileManager.default.removeItem(at: stub) }

        withinDeadline(30, "spawn with an stdout-holding grandchild") {
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
            "sh -c 'echo $$ > \(marker.path); sleep 600' &\nsleep 600"
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
}
