import Foundation
#if canImport(Glibc)
import Glibc
#endif
import XCTest
@testable import LatticeCtlCore

private final class PidCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// The `lattice mine` loop calls `spawnCollectingOutput` once per block,
/// forever. Two Linux-only corelibs hazards it must survive, both hit in
/// production and neither caught before:
///   - reusing the FileHandle.nullDevice singleton → EBADF on a later spawn;
///   - not closing a Pipe's fds → a two-per-spawn leak → EMFILE.
/// This spawns under a DELIBERATELY LOW fd limit so a per-spawn fd leak
/// exhausts it and fails fast, rather than needing thousands of spawns.
/// (Verified on Linux to fail without the pipe-close fix; a macOS run passes
/// either way because real Foundation reclaims Pipe fds on dealloc.)
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

    func testManySpawnsSurviveUnderALowFdLimit() async throws {
        let stub = try stubEmitter()
        defer { try? FileManager.default.removeItem(at: stub) }

        // RLIMIT_NOFILE is a plain Int32 on Darwin but a __rlimit_resource
        // enum on Glibc, which getrlimit/setrlimit take as Int32.
        #if canImport(Glibc)
        let nofile = __rlimit_resource_t(RLIMIT_NOFILE.rawValue)
        #else
        let nofile = RLIMIT_NOFILE
        #endif
        var original = rlimit()
        XCTAssertEqual(getrlimit(nofile, &original), 0)
        var capped = original
        capped.rlim_cur = min(original.rlim_max, 128)
        XCTAssertEqual(setrlimit(nofile, &capped), 0)
        defer { setrlimit(nofile, &original) }

        let pidCounter = PidCounter()
        for iteration in 0..<300 {
            let output: Data
            do {
                output = try await spawnCollectingOutput(
                    executable: stub, arguments: [],
                    onSpawn: { _ in pidCounter.bump() }
                )
            } catch {
                XCTFail("spawn \(iteration) threw (fd leak?): \(error)")
                return
            }
            XCTAssertTrue(
                String(decoding: output, as: UTF8.self).contains("noSolution"),
                "spawn \(iteration) lost stdout"
            )
        }
        XCTAssertEqual(pidCounter.value, 300)
    }
}
