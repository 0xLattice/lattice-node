// One bounded wait for every child process this repo spawns.
//
// The defect class is a wait that can never return, and it has wedged this
// codebase three times in three different disguises:
//   - `Process.waitUntilExit()` parks a thread in sigsuspend until corelibs
//     delivers the child-exit signal. When that delivery is lost the wait
//     never returns even though the child is long gone (#62: `lattice mine
//     run` parked 1.7 days on a coordinator that had already exited — both
//     chains frozen, GPU idle, no log output).
//   - A `withCheckedContinuation` resumed only from `terminationHandler` is
//     the same wait wearing a different hat: no callback, no resume.
//   - A post-exit `readDataToEndOfFile()` blocks until EOF, and a grandchild
//     that inherited the pipe write-end means EOF never arrives.
//
// So every wait here takes a deadline the CALLER derives from its own
// parameters — this file defines no policy duration of its own — and on
// expiry signals the process GROUP rather than the pid, because killing the
// pid alone leaves orphaned grandchildren running (#141 orphaned two live
// nodes to init). The outcome is distinguishable so a supervisor can say out
// loud that the deadline fired and keep going, instead of freezing silently.

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum ProcessWaitOutcome: Sendable, Equatable {
    /// The child exited on its own before the deadline.
    case exited(status: Int32)
    /// The deadline fired first; the child's process group was signalled.
    case deadlineExceeded
}

/// Output collected from a bounded spawn.
public struct BoundedSpawnResult: Sendable {
    public let output: Data
    public let outcome: ProcessWaitOutcome
    /// stdout reached EOF. `false` means the read itself hit the deadline,
    /// so `output` is a prefix.
    public let outputComplete: Bool

    public init(
        output: Data, outcome: ProcessWaitOutcome, outputComplete: Bool
    ) {
        self.output = output
        self.outcome = outcome
        self.outputComplete = outputComplete
    }
}

/// How long to wait after SIGTERM before escalating to SIGKILL. Carried over
/// verbatim from `MiningWorkerSubprocess`, which this file subsumes: some
/// shells (dash `sh -c`) do not propagate SIGTERM to their children, and on
/// swift-corelibs-foundation a bare `terminate()` does not promptly reap such
/// a child. It is the step between two signals, not a bound on how long any
/// caller may run, which is why it is not an operator knob.
private let terminationGrace = Duration.milliseconds(200)

/// What `kill(2)` must be given to take down `pid` AND whatever it spawned.
/// A child leading its own process group is addressed as the negative group
/// id so orphaned grandchildren die with it; otherwise only the pid is
/// signalled. Never returns our OWN group: signalling that kills the
/// supervisor along with the child.
public func processSignalTarget(pid: Int32) -> Int32 {
    let childGroup = getpgid(pid)
    guard childGroup > 0, childGroup == pid, childGroup != getpgid(0) else {
        return pid
    }
    return -childGroup
}

/// SIGTERM the child's process group, escalating to SIGKILL after the grace.
/// Returns immediately; the escalation runs detached.
public func terminateProcessGroup(pid: Int32) {
    let target = processSignalTarget(pid: pid)
    kill(target, SIGTERM)
    Task.detached {
        try? await Task.sleep(for: terminationGrace)
        kill(target, SIGKILL)
    }
}

/// Starts `process` under a hard deadline, returning a handle whose `wait()`
/// cannot hang. Separate from the wait so a caller can record the pid between
/// spawn and wait.
public func runBounded(
    _ process: Process,
    deadline: Duration?,
    onDeadline: (@Sendable (Int32) -> Void)? = nil
) throws -> BoundedProcessWait {
    let waiter = BoundedProcessWait(process: process)
    try waiter.start(deadline: deadline, onDeadline: onDeadline)
    return waiter
}

/// The live handle for one bounded child.
///
/// Resumes off `terminationHandler` when the child exits normally, but — and
/// this is the whole point — the deadline path resumes the SAME continuation
/// itself. It never waits for a callback to tell it the deadline fired,
/// because a missing callback is precisely the failure being defended against.
public final class BoundedProcessWait: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProcessWaitOutcome, Never>?
    private var pending: ProcessWaitOutcome?
    private var settled = false
    private var timer: Task<Void, Never>?

    public var processIdentifier: Int32 { process.processIdentifier }

    init(process: Process) {
        self.process = process
    }

    func start(
        deadline: Duration?,
        onDeadline: (@Sendable (Int32) -> Void)?
    ) throws {
        process.terminationHandler = { [weak self] proc in
            self?.settle(.exited(status: proc.terminationStatus))
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            throw error
        }
        guard let deadline else { return }
        let pid = process.processIdentifier
        timer = Task { [weak self] in
            do {
                try await Task.sleep(for: deadline)
            } catch {
                return  // cancelled: the child exited first
            }
            onDeadline?(pid)
            terminateProcessGroup(pid: pid)
            self?.settle(.deadlineExceeded)
        }
    }

    /// Waits for exit or the deadline, whichever comes first. On task
    /// cancellation the group is signalled, preserving the prompt-reap
    /// behaviour the mining worker relies on.
    public func wait() async -> ProcessWaitOutcome {
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation {
                (cont: CheckedContinuation<ProcessWaitOutcome, Never>) in
                attach(cont)
            }
        } onCancel: {
            let pid = process.processIdentifier
            if pid > 0 {
                terminateProcessGroup(pid: pid)
            }
        }
        timer?.cancel()
        return outcome
    }

    private func attach(
        _ cont: CheckedContinuation<ProcessWaitOutcome, Never>
    ) {
        lock.lock()
        if let ready = pending {
            pending = nil
            lock.unlock()
            cont.resume(returning: ready)
            return
        }
        continuation = cont
        lock.unlock()
    }

    private func settle(_ outcome: ProcessWaitOutcome) {
        lock.lock()
        if settled {
            lock.unlock()
            return
        }
        settled = true
        if let waiting = continuation {
            continuation = nil
            lock.unlock()
            waiting.resume(returning: outcome)
            return
        }
        pending = outcome
        lock.unlock()
    }
}

/// Reads a descriptor to EOF under a deadline.
///
/// `readDataToEndOfFile()` parks a thread until EOF, and a grandchild holding
/// the write end keeps that EOF from ever arriving. Non-blocking reads driven
/// by `poll(2)` bound the wait without stranding a thread nothing can wake.
///
/// Returns the bytes read and whether EOF was actually reached.
public func readToEndBounded(
    fileDescriptor: Int32,
    deadline: ContinuousClock.Instant
) -> (data: Data, complete: Bool) {
    let existingFlags = fcntl(fileDescriptor, F_GETFL, 0)
    if existingFlags >= 0 {
        _ = fcntl(fileDescriptor, F_SETFL, existingFlags | O_NONBLOCK)
    }
    var data = Data()
    // A read chunk, not a bound: the loop reads until EOF or the deadline
    // regardless of this size.
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { return (data, false) }
        let scaled = remaining.components.seconds
            .multipliedReportingOverflow(by: 1_000)
        let waitMilliseconds: Int32 = scaled.overflow
            ? Int32.max
            : Int32(clamping: scaled.partialValue + 1)
        var descriptor = pollfd(
            fd: fileDescriptor, events: Int16(POLLIN), revents: 0
        )
        let ready = poll(&descriptor, 1, waitMilliseconds)
        if ready == 0 { return (data, false) }
        if ready < 0 {
            if errno == EINTR { continue }
            return (data, false)
        }
        let count = buffer.withUnsafeMutableBytes {
            read(fileDescriptor, $0.baseAddress, $0.count)
        }
        if count == 0 { return (data, true) }
        if count < 0 {
            if errno == EINTR || errno == EAGAIN { continue }
            return (data, false)
        }
        data.append(contentsOf: buffer[0..<count])
    }
}
