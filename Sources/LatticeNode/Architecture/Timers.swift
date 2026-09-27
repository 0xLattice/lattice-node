import Foundation

/// The node's one suspension primitive and the timer shapes built on it.
///
/// Every sleep goes through `sleep(nanoseconds:)`, which uses
/// `Task.sleep(nanoseconds:)` ONLY. Never `Task.sleep(for:)` and never
/// `Clock.sleep(for:)`: both bodies are emitted into the client and miscompile
/// under Swift 6.3 -O (swift_task_dealloc aborts with "freed pointer was not
/// the last allocation" on resume). `Duration` is converted to nanoseconds
/// before any task is created or any suspension happens, so it never sits in
/// an optimized async task frame.
///
/// Timers does no generation gating. `deadline` passes `generation` through
/// to its fire closure and every fire target does its own check.
enum Timers {
    /// Sleeps `nanoseconds`. Returns `false` iff the task was cancelled.
    static func sleep(nanoseconds: UInt64) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
        } catch {
            return false
        }
        return !Task.isCancelled
    }

    /// `duration` in nanoseconds, zero for a negative duration, saturating at
    /// `UInt64.max`.
    static func nanoseconds(_ duration: Duration) -> UInt64 {
        // Keep Duration out of optimized async task frames: the generic Clock
        // sleep overload can trip Swift's task allocator during teardown.
        let components = duration.components
        guard components.seconds >= 0, components.attoseconds >= 0 else { return 0 }
        let seconds = UInt64(components.seconds)
        let nanoseconds = UInt64(components.attoseconds / 1_000_000_000)
        let (scaled, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        if overflow { return UInt64.max }
        let (total, additionOverflow) = scaled.addingReportingOverflow(nanoseconds)
        return additionOverflow ? UInt64.max : total
    }

    /// One-shot: `fire(generation)` runs iff the sleep completes uncancelled.
    /// `Task {}`, not `Task.detached`: task-locals (the child-candidate budget)
    /// must still inherit. Callers capture `[weak self]` in `fire` so a
    /// sleeping timer does not retain its owner.
    @discardableResult
    static func deadline(
        after delay: Duration,
        generation: UInt64,
        _ fire: @escaping @Sendable (UInt64) async -> Void
    ) -> Task<Void, Never> {
        let delayNanoseconds = Timers.nanoseconds(delay)
        return Task {
            guard await Timers.sleep(nanoseconds: delayNanoseconds) else { return }
            await fire(generation)
        }
    }

    enum Retry<T> {
        case value(T)
        case cancelled
        case stale
    }

    /// `attempt`; while its result is `capacityUnavailable`, sleep `every`,
    /// then re-check `stillCurrent` and attempt again. The closures run on
    /// the caller's actor.
    static func retryWhileCapacityUnavailable<T>(
        every interval: Duration,
        isolation: isolated (any Actor)? = #isolation,
        attempt: () async -> T,
        capacityUnavailable: (T) -> Bool,
        stillCurrent: () -> Bool
    ) async -> Retry<T> {
        let intervalNanoseconds = Timers.nanoseconds(interval)
        while true {
            let result = await attempt()
            guard capacityUnavailable(result) else { return .value(result) }
            guard await Timers.sleep(nanoseconds: intervalNanoseconds) else {
                return .cancelled
            }
            guard stillCurrent() else { return .stale }
        }
    }

    enum Step<T> {
        case again
        case done(T)
    }

    /// `step`; while it answers `.again`, sleep `every` and step again.
    /// Returns `onCancel` when a sleep is cancelled. The step runs on the
    /// caller's actor.
    static func poll<T>(
        every interval: Duration,
        onCancel: T,
        isolation: isolated (any Actor)? = #isolation,
        _ step: () async -> Step<T>
    ) async -> T {
        let intervalNanoseconds = Timers.nanoseconds(interval)
        while true {
            if case .done(let value) = await step() { return value }
            guard await Timers.sleep(nanoseconds: intervalNanoseconds) else {
                return onCancel
            }
        }
    }

    /// While `while` holds: `body`, then sleep `every`. Acts first, then
    /// sleeps; returns when a sleep is cancelled. Runs on the caller's actor.
    static func repeating(
        every interval: Duration,
        isolation: isolated (any Actor)? = #isolation,
        while condition: () -> Bool,
        _ body: () async -> Void
    ) async {
        let intervalNanoseconds = Timers.nanoseconds(interval)
        while condition() {
            await body()
            guard await Timers.sleep(nanoseconds: intervalNanoseconds) else {
                return
            }
        }
    }
}
