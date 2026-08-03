import Foundation

/// Runs one child to completion, returning its stdout. This is THE spawn
/// path the mining loop uses per block, so its fd discipline is exercised
/// here and pinned by ProcessSpawnTests across many sequential spawns.
///
/// - stderr goes to a FRESH /dev/null each call, never the shared
///   `FileHandle.nullDevice` singleton: corelibs-Foundation closes a child's
///   standard-handle fd on exit, so reusing the singleton makes a later
///   spawn throw EBADF (which once killed the miner an hour in).
/// - reaping is off `terminationHandler`, not a thread parked in
///   `waitUntilExit`, which can hang on a missed SIGCHLD on Linux.
/// - after the child exits, the parent's pipe write-end is closed so
///   `readDataToEndOfFile` sees EOF, then both ends are closed so a
///   spawn-per-block loop does not leak two fds each iteration (EMFILE).
///   No async readabilityHandler is used: draining concurrently with the
///   final read raced and dropped output under load. Callers spawn
///   small-output children (a JSON result line), so a single post-exit read
///   cannot fill the pipe buffer.
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
    try? stdout.fileHandleForWriting.close()
    defer { try? stdout.fileHandleForReading.close() }
    return stdout.fileHandleForReading.readDataToEndOfFile()
}
