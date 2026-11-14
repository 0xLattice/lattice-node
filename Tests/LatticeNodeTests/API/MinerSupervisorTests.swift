import Foundation
import LatticeCtlCore
import XCTest
@testable import LatticeNodeDaemon

/// The node's mining loop, run by a stand-in: a loop that ignores SIGTERM
/// (as `mine run` finishes its round first) while its round's coordinator
/// runs, and leaves once the coordinator is gone.
final class MinerSupervisorTests: XCTestCase {
    private func layout() throws -> (HostLayout, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("miner-supervisor-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let coordinator = bin.appendingPathComponent("lattice-mining-coordinator")
        try "#!/bin/sh\nsleep 600\n".write(to: coordinator, atomically: true, encoding: .utf8)
        // Arguments: mine run --root <root> --parent-pid <pid>.
        let loop = bin.appendingPathComponent("lattice")
        try """
        #!/bin/sh
        trap '' TERM
        "\(coordinator.path)" &
        mkdir -p "$4/run"
        echo "$! lattice-mining-coordinator" > "$4/run/mine-coordinator.pid"
        echo "loop started"
        wait
        echo "round ended"
        """.write(to: loop, atomically: true, encoding: .utf8)
        for file in [coordinator, loop] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return (HostLayout(root: root.path), loop)
    }

    private func waitFor(_ label: String, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("timed out waiting for \(label)")
    }

    /// A stop does not wait out the round: the coordinator is ended and the
    /// loop leaves well inside the node's own shutdown grace.
    func testAStopCutsTheRoundInFlight() async throws {
        let (layout, loop) = try layout()
        let supervisor = MinerSupervisor(layout: layout, executable: loop)
        await supervisor.apply(TopologyMine(enabled: true))
        try await waitFor("the coordinator") { FileManager.default.fileExists(atPath: layout.pidFile(for: "mine-coordinator").path) }
        let coordinator = try XCTUnwrap(
            Int32(try String(contentsOf: layout.pidFile(for: "mine-coordinator"), encoding: .utf8).split(separator: " ")[0])
        )
        let started = ContinuousClock.now
        await supervisor.stop()
        XCTAssertLessThan(started.duration(to: .now), .seconds(8))
        XCTAssertNotEqual(kill(coordinator, 0), 0, "the coordinator is gone")
        let status = await supervisor.status()
        XCTAssertFalse(status.running)
    }

    /// The log is appended to across starts: a crashed loop's output stays.
    func testTheLogIsKeptAcrossStarts() async throws {
        let (layout, loop) = try layout()
        let log = layout.logFile(for: "mine")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "earlier output\n".write(to: log, atomically: true, encoding: .utf8)
        let supervisor = MinerSupervisor(layout: layout, executable: loop)
        await supervisor.apply(TopologyMine(enabled: true))
        try await waitFor("the first loop") { (try? String(contentsOf: log, encoding: .utf8))?.contains("loop started") == true }
        try await waitFor("its coordinator") { FileManager.default.fileExists(atPath: layout.pidFile(for: "mine-coordinator").path) }
        // A changed section restarts the loop.
        await supervisor.apply(TopologyMine(enabled: true, workers: 2))
        try await waitFor("the second loop") {
            (try? String(contentsOf: log, encoding: .utf8))?.components(separatedBy: "loop started").count == 3
        }
        let started = ContinuousClock.now
        await supervisor.stop()
        XCTAssertLessThan(started.duration(to: .now), .seconds(8))
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("earlier output\n"), text)
        XCTAssertEqual(text.components(separatedBy: "loop started").count, 3, text)
    }
}
