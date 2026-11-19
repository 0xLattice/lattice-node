import Synchronization

/// The store's lane: what the runtime writes to its stores, run one at a
/// time in the order it was asked for, off the loop. The loop decides and
/// goes on; a write that waits on the disk holds up the writes behind it,
/// and nothing else.
///
/// A reader of what a step wrote waits for the lane first (`settled`): the
/// writes asked for before it are in the store when it reads. A crash loses
/// the writes still in the lane, and only those: each is a transaction, they
/// run in order, so the store holds a prefix of what the loop decided.
///
/// A write that fails is the last: every one behind it fails with the same
/// error, and `onFailure` is told once.
final class StoreLane: Sendable {
    private struct State {
        var tail: Task<Void, any Error>?
        var depth = 0
        var failure: (any Error)?
        var onFailure: (@Sendable (any Error) -> Void)?
    }

    private let state = Mutex(State())

    /// The lane whose work this task is doing, if it is doing one's: work
    /// already in the lane does what it needs of the lane itself, where
    /// asking and waiting would wait for itself.
    @TaskLocal static var current: StoreLane?

    /// Whether the calling task is this lane's work.
    var isCurrent: Bool { Self.current === self }

    /// The writes asked for and not yet done.
    var depth: Int { state.withLock(\.depth) }

    /// Told the first failure, once: the runtime stops on it.
    func onFailure(_ handler: @escaping @Sendable (any Error) -> Void) {
        state.withLock { $0.onFailure = handler }
    }

    /// Runs `work` after everything asked for before it. Returns at once;
    /// the task ends when `work` has, or fails as the lane has.
    @discardableResult
    func run(_ work: @escaping @Sendable () async throws -> Void) -> Task<Void, any Error> {
        state.withLock { state in
            let previous = state.tail
            let task = Task { [self] in
                _ = await previous?.result
                defer { self.state.withLock { $0.depth -= 1 } }
                if let failure = self.state.withLock(\.failure) { throw failure }
                do {
                    try await Self.$current.withValue(self) { try await work() }
                } catch {
                    let handler = self.state.withLock { state -> (@Sendable (any Error) -> Void)? in
                        guard state.failure == nil else { return nil }
                        state.failure = error
                        return state.onFailure
                    }
                    handler?(error)
                    throw error
                }
            }
            state.tail = task
            state.depth += 1
            return task
        }
    }

    /// Everything asked for so far is done. Throws what the lane failed with.
    func settled() async throws {
        try await state.withLock(\.tail)?.value
    }
}
