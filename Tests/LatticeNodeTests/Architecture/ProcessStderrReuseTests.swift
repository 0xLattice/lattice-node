import Foundation
import XCTest
@testable import LatticeCtlCore

/// The `lattice mine` loop calls `spawnCollectingOutput` once per block,
/// forever. This exercises that exact spawn-and-reap path across many
/// sequential spawns — the condition the fleet migration hit an hour in,
/// where a reused `FileHandle.nullDevice` singleton's closed fd made a
/// later spawn throw EBADF and (before the fix) killed the miner. A revert
/// to the singleton fails here on Linux.
private final class PidCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

final class ProcessSpawnTests: XCTestCase {
    private func stubEmitter() throws -> URL {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("spawn-stub-\(UUID().uuidString).sh")
        try #"""
        #!/bin/sh
        echo '{"result":"noSolution","workId":"stub"}'
        echo "chatter on stderr" >&2
        """#.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path
        )
        return script
    }

    func testManySequentialSpawnsSurviveAndCollectOutput() async throws {
        let stub = try stubEmitter()
        defer { try? FileManager.default.removeItem(at: stub) }
        let pidCounter = PidCounter()
        for iteration in 0..<60 {
            let output: Data
            do {
                output = try await spawnCollectingOutput(
                    executable: stub,
                    arguments: [],
                    onSpawn: { _ in pidCounter.bump() }
                )
            } catch {
                XCTFail("spawn \(iteration) threw: \(error)")
                return
            }
            let text = String(decoding: output, as: UTF8.self)
            XCTAssertTrue(
                text.contains("noSolution"),
                "spawn \(iteration) lost stdout: \(text)"
            )
        }
        XCTAssertEqual(pidCounter.value, 60)
    }
}
