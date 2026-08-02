import Foundation

/// Accumulates a child's piped output under a lock, since the readability
/// handler fires on an arbitrary queue.
final class SpawnOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock(); data.append(chunk); lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock(); defer { lock.unlock() }; return data
    }
}

/// Runs one child to completion, returning its stdout. This is THE spawn
/// path the mining loop uses per block, so its fd discipline is exercised
/// here and pinned by ProcessSpawnTests across many sequential spawns:
///
/// - stderr goes to a FRESH /dev/null each call, never the shared
///   `FileHandle.nullDevice` singleton — corelibs-Foundation closes a
///   child's standard-handle fd on exit, so reusing the singleton makes a
///   later spawn throw EBADF (which once killed the miner an hour in).
/// - reaping is off `terminationHandler`, not a thread parked in
///   `waitUntilExit`, which can hang on a missed SIGCHLD on Linux.
public func spawnCollectingOutput(
    executable: URL,
    arguments: [String],
    onSpawn: (@Sendable (Int32) -> Void)? = nil
) async throws -> Data {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let stdout = Pipe()
    process.standardOutput = stdout
    let devNull = FileHandle(forWritingAtPath: "/dev/null")
    defer { try? devNull?.close() }
    process.standardError = devNull ?? FileHandle.nullDevice
    let collector = SpawnOutput()
    stdout.fileHandleForReading.readabilityHandler = { handle in
        collector.append(handle.availableData)
    }
    try await withCheckedThrowingContinuation { (
        continuation: CheckedContinuation<Void, Error>
    ) in
        process.terminationHandler = { _ in continuation.resume() }
        do {
            try process.run()
            onSpawn?(process.processIdentifier)
        } catch {
            process.terminationHandler = nil
            continuation.resume(throwing: error)
        }
    }
    stdout.fileHandleForReading.readabilityHandler = nil
    collector.append(stdout.fileHandleForReading.readDataToEndOfFile())
    return collector.snapshot()
}
