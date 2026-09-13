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
    /// Teardown could only signal the pid, so descendants may have survived.
    ///
    /// Deliberately SEPARATE from `outcome`: teardown quality and wait
    /// outcome vary independently. A deadline can fire with a clean subtree
    /// teardown, and a child can exit normally having left descendants
    /// behind. Folding this into `.deadlineExceeded` would conflate two axes
    /// and leave no way to say "exited normally, teardown degraded".
    public let teardownDegraded: Bool

    public init(
        output: Data,
        outcome: ProcessWaitOutcome,
        outputComplete: Bool,
        teardownDegraded: Bool
    ) {
        self.output = output
        self.outcome = outcome
        self.outputComplete = outputComplete
        self.teardownDegraded = teardownDegraded
    }
}

/// How long to wait after SIGTERM before escalating to SIGKILL. Carried over
/// verbatim from `MiningWorkerSubprocess`, which this file subsumes: some
/// shells (dash `sh -c`) do not propagate SIGTERM to their children, and on
/// swift-corelibs-foundation a bare `terminate()` does not promptly reap such
/// a child. It is the step between two signals, not a bound on how long any
/// caller may run, which is why it is not an operator knob.
private let terminationGrace = Duration.milliseconds(200)

/// The teardown target for one child, CAPTURED AT SPAWN while the child is
/// still definitively alive.
///
/// Re-deriving this at kill time is what put #62 back: once the child is
/// reaped its process group is gone, `getpgid` returns -1, and the old guard
/// silently degraded a subtree teardown into a pid-only kill that left
/// orphaned grandchildren running -- while still reporting success.
public struct ProcessTeardownTarget: Sendable, Equatable {
    public let pid: Int32
    /// The group to signal, or nil when the child shares OUR process group,
    /// where signalling the group would kill the supervisor too.
    public let group: Int32?

    /// Only the pid can be signalled, so descendants outlive the child.
    /// Callers must SURFACE this: a pid-only kill that announces itself is
    /// acceptable; one that masquerades as a teardown is what hid this bug.
    public var isDegraded: Bool { group == nil }

    public init(pid: Int32, group: Int32?) {
        self.pid = pid
        self.group = group
    }

    /// Captures the target immediately after `run()`.
    public static func capture(pid: Int32) -> ProcessTeardownTarget {
        let ourGroup = getpgid(0)

        // API SAFETY -- not pid recycling. This is public and nothing
        // constrains a caller to a pid it spawned, so a caller passing our
        // own group leader's pid would otherwise fall through to
        // `group: pid` and `kill(-pid)` would signal the SUPERVISOR's group.
        //
        // Do not delete this by reconstructing the POSIX argument. That
        // argument is sound but narrower than this guard: for children WE
        // fork, `pid == ourGroup` is unreachable, because a process group id
        // is pinned for the group's lifetime and we are always a member of
        // our own group, so the leader's pid cannot be recycled even once it
        // exits and is reaped. It says nothing about an arbitrary pid handed
        // in by a caller.
        if pid == ourGroup {
            return ProcessTeardownTarget(pid: pid, group: nil)
        }

        let childGroup = getpgid(pid)
        if childGroup > 0 {
            // A child SHARING our group was never placed in one of its own;
            // signalling that group would take the supervisor with it.
            if childGroup == ourGroup {
                return ProcessTeardownTarget(pid: pid, group: nil)
            }
            // Use what was MEASURED. Returning `pid` here regardless would be
            // correct only under the assumption that the child leads its own
            // group: a child in a THIRD group would make `kill(-pid)` address
            // a group whose leader does not exist -- ESRCH, nothing signalled
            // at all, which is worse than the pid-only kill this replaced and
            // exactly as silent.
            return ProcessTeardownTarget(pid: pid, group: childGroup)
        }

        // Already gone, so its group cannot be read -- but descendants may
        // still hold that group open, and for a child we spawned the group id
        // is its pid by construction. An empty group makes this a harmless
        // no-op. Absence of the child is not a teardown failure, but it is
        // not a reason to skip the subtree either.
        return ProcessTeardownTarget(pid: pid, group: pid)
    }
}

/// SIGTERM the captured target, escalating to SIGKILL after the grace.
/// Returns immediately; the escalation runs detached.
///
/// `onSignalFailure` receives `errno` for any signal that FAILS. Discarding
/// kill(2)'s return value is how a teardown that never happened reads as
/// success -- the same silent-failure shape as an unreported degraded
/// teardown, and the reason a signalling question took a day to answer.
public func terminateProcessGroup(
    _ target: ProcessTeardownTarget,
    onSignalFailure: (@Sendable (Int32) -> Void)? = nil
) {
    let signalled = target.group.map { -$0 } ?? target.pid
    if kill(signalled, SIGTERM) != 0 { onSignalFailure?(errno) }
    Task.detached {
        try? await Task.sleep(for: terminationGrace)
        // Only escalate if something is still there -- the guard the
        // superseded MiningWorkerSubprocess had, and it costs nothing.
        guard kill(signalled, 0) == 0 else { return }
        if kill(signalled, SIGKILL) != 0 { onSignalFailure?(errno) }
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
    /// Captured at spawn, never re-derived. See ProcessTeardownTarget.
    private var teardown: ProcessTeardownTarget?
    /// errno from the last teardown signal that failed, if any.
    private var teardownSignalFailure: Int32?
    /// An unexpected error from the deadline task, if one ever occurs.
    private var timerFailure: String?
    private var waiters: [CheckedContinuation<ProcessWaitOutcome, Never>] = []
    private var outcome: ProcessWaitOutcome?
    private var timer: Task<Void, Never>?

    public var processIdentifier: Int32 { process.processIdentifier }

    /// The target captured AT SPAWN. Exposed so a regression that moved the
    /// capture back to kill time fails a test rather than silently degrading
    /// every teardown.
    public var capturedTeardown: ProcessTeardownTarget? {
        lock.lock()
        defer { lock.unlock() }
        return teardown
    }

    /// errno from the last teardown signal that FAILED, or nil when every
    /// signal succeeded. Surfaced for the same reason isTeardownDegraded is:
    /// a kill(2) whose return value is discarded lets a teardown that never
    /// happened read as a clean one.
    public var lastTeardownSignalFailure: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return teardownSignalFailure
    }

    private func recordTeardownSignalFailure(_ code: Int32) {
        lock.lock()
        teardownSignalFailure = code
        lock.unlock()
    }

    /// An unexpected error from the deadline task, or nil. `Task.sleep`
    /// throws only cancellation today, so a non-nil value means the bound
    /// ended for a reason this code did not anticipate -- which has to be
    /// visible rather than swallowed by an untyped catch.
    public var unexpectedTimerFailure: String? {
        lock.lock()
        defer { lock.unlock() }
        return timerFailure
    }

    private func recordTimerFailure(_ description: String) {
        lock.lock()
        timerFailure = description
        lock.unlock()
    }

    /// True when teardown can only signal the pid, so descendants survive it.
    /// Exposed so a caller can SAY SO rather than report a clean teardown.
    public var isTeardownDegraded: Bool {
        capturedTeardown?.isDegraded ?? false
    }

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
        let pid = process.processIdentifier
        // CAPTURE HERE, not at kill time: the child is alive at this instant,
        // so its group is knowable. After it is reaped the group is gone and
        // any later derivation silently degrades to a pid-only kill.
        let captured = ProcessTeardownTarget.capture(pid: pid)
        lock.lock()
        teardown = captured
        lock.unlock()
        guard let deadline else { return }
        timer = Task { [weak self] in
            do {
                try await Task.sleep(for: deadline)
            } catch is CancellationError {
                // NOT "the child exited first" -- this task never looks at
                // the child. Cancellation means the BOUND was removed.
                //
                // Returning is safe ONLY because of an invariant this file
                // maintains: the timer is unstructured, so `wait()` is the
                // only thing that cancels it, and only once an outcome
                // already exists. If the timer is ever made structured, a
                // cancelled bound could strand a caller waiting forever while
                // believing it is bounded, and this must then settle an
                // outcome that says so rather than return.
                return
            } catch {
                // Task.sleep throws nothing else today. An untyped catch that
                // returned in silence is precisely how a bound removes itself
                // without telling anyone, so record it rather than swallow it.
                self?.recordTimerFailure(String(describing: error))
                return
            }
            // SETTLE FIRST. Signalling before settling let our own SIGTERM
            // kill the child, whose terminationHandler then won the race and
            // reported `.exited(status: 15)` -- a deadline that fired, killed
            // the process, and then claimed a normal exit, which silently
            // downgrades the operator's ROUND DEADLINE EXCEEDED signal.
            // Settling first also means a child that exited on its own keeps
            // its real status and is never signalled.
            guard let self, self.settle(.deadlineExceeded) else { return }
            onDeadline?(pid)
            // Strong capture: a dropped record must never read as
            // "no failure occurred".
            terminateProcessGroup(captured) { code in
                self.recordTeardownSignalFailure(code)
            }
        }
    }

    /// Waits for exit or the deadline, whichever comes first. On task
    /// cancellation the group is signalled, preserving the prompt-reap
    /// behaviour the mining worker relies on.
    public func wait() async -> ProcessWaitOutcome {
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation {
                (cont: CheckedContinuation<ProcessWaitOutcome, Never>) in
                attach(cont)
            }
        } onCancel: {
            lock.lock()
            let captured = teardown
            lock.unlock()
            if let captured {
                terminateProcessGroup(captured) { code in
                    self.recordTeardownSignalFailure(code)
                }
            }
        }
        timer?.cancel()
        return result
    }

    /// The outcome is RETAINED, never consumed, and waiters are a list: this
    /// is a public API whose whole promise is that a wait cannot hang, so a
    /// second `wait()` must return the same answer at once rather than park
    /// on a continuation nobody will resume, and concurrent waits must all
    /// wake rather than stranding the earlier one.
    private func attach(
        _ cont: CheckedContinuation<ProcessWaitOutcome, Never>
    ) {
        lock.lock()
        if let decided = outcome {
            lock.unlock()
            cont.resume(returning: decided)
            return
        }
        waiters.append(cont)
        lock.unlock()
    }

    @discardableResult
    private func settle(_ result: ProcessWaitOutcome) -> Bool {
        lock.lock()
        if outcome != nil {
            lock.unlock()
            return false
        }
        outcome = result
        let pending = waiters
        waiters = []
        lock.unlock()
        // Never resume while holding the lock: a terminationHandler running
        // on a Foundation queue could otherwise re-enter and deadlock.
        for waiter in pending {
            waiter.resume(returning: result)
        }
        return true
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
        // Include the sub-second part. Truncating to whole seconds gave a
        // 1 ms budget for any remainder under a second, so a drain with less
        // than a second left effectively did not wait at all and discarded
        // output a child had already written.
        let components = remaining.components
        let scaled = components.seconds.multipliedReportingOverflow(by: 1_000)
        let waitMilliseconds: Int32
        if scaled.overflow {
            waitMilliseconds = Int32.max
        } else {
            let fraction = components.attoseconds / 1_000_000_000_000_000
            let total = scaled.partialValue
                .addingReportingOverflow(fraction + 1)
            waitMilliseconds = total.overflow
                ? Int32.max
                : Int32(clamping: total.partialValue)
        }
        var descriptor = pollfd(
            fd: fileDescriptor, events: Int16(POLLIN), revents: 0
        )
        let ready = poll(&descriptor, 1, waitMilliseconds)
        // Re-check the deadline rather than trusting one timeout return:
        // the guard at the top of the loop owns expiry.
        if ready == 0 { continue }
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
