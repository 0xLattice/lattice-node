import Foundation
import LatticeProcessWait

/// Runs one child to completion under a deadline, returning its stdout. This
/// is THE spawn path the mining loop uses per block, so its fd discipline is
/// exercised here and pinned by ProcessSpawnTests across many sequential
/// spawns.
///
/// - the wait is bounded by `deadline` and routed through the shared
///   `LatticeProcessWait` helper: both the exit wait and the stdout read were
///   unbounded, and a coordinator that exited without delivering its
///   termination callback parked `lattice mine run` for 1.7 days (#62).
/// - stderr goes to a FRESH /dev/null each call, never the shared
///   `FileHandle.nullDevice` singleton: corelibs-Foundation closes a child's
///   standard-handle fd on exit, so reusing the singleton makes a later
///   spawn throw EBADF (which once killed the miner an hour in).
/// - after the wait returns, the parent's pipe write-end is closed so the
///   read can see EOF, then both ends are closed so a spawn-per-block loop
///   does not leak two fds each iteration (EMFILE). The read itself is
///   bounded: a grandchild that inherited the write-end would otherwise hold
///   EOF back forever.
public func spawnCollectingOutput(
    executable: URL,
    arguments: [String],
    deadline: Duration,
    onSpawn: (@Sendable (Int32) -> Void)? = nil,
    onDeadline: (@Sendable (Int32) -> Void)? = nil
) async throws -> BoundedSpawnResult {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let stdout = Pipe()
    process.standardOutput = stdout
    let devNull = FileHandle(forWritingAtPath: "/dev/null")
    defer { try? devNull?.close() }
    process.standardError = devNull ?? FileHandle.nullDevice
    let readDeadline = ContinuousClock.now + deadline
    let handle = try runBounded(
        process, deadline: deadline, onDeadline: onDeadline
    )
    onSpawn?(handle.processIdentifier)
    let outcome = await handle.wait()
    try? stdout.fileHandleForWriting.close()
    defer { try? stdout.fileHandleForReading.close() }
    let read = readToEndBounded(
        fileDescriptor: stdout.fileHandleForReading.fileDescriptor,
        deadline: readDeadline
    )
    return BoundedSpawnResult(
        output: read.data, outcome: outcome, outputComplete: read.complete
    )
}
