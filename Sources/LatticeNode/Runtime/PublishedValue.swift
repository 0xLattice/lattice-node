import Synchronization

/// The latest value the run loop published. Only the loop writes; readers
/// (RPC) take the current immutable value without touching the loop, or
/// watch it change through `updates()`.
public final class PublishedValue<Value: Sendable>: Sendable {
    private struct State {
        var value: Value?
        var watchers: [UInt64: AsyncStream<Value>.Continuation] = [:]
        var nextWatcher: UInt64 = 0
        var finished = false
    }

    private let current: Mutex<State>

    public init(_ value: Value? = nil) {
        current = Mutex(State(value: value))
    }

    public var value: Value? {
        current.withLock { $0.value }
    }

    func publish(_ value: Value) {
        let watchers = current.withLock { state in
            state.value = value
            return state.watchers
        }
        // Outside the lock: a watcher ending runs its termination handler,
        // which takes the lock again.
        for (id, watcher) in watchers {
            if case .terminated = watcher.yield(value) {
                current.withLock { _ = $0.watchers.removeValue(forKey: id) }
            }
        }
    }

    /// The current value, if any, then each one published. Newest only: a
    /// reader that falls behind skips to the latest, so a stalled one holds
    /// one value. Ends when the publisher `finish`es.
    public func updates() -> AsyncStream<Value> {
        let (stream, continuation) = AsyncStream<Value>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let registered = current.withLock { state -> (id: UInt64, value: Value?)? in
            guard !state.finished else { return nil }
            let id = state.nextWatcher
            state.nextWatcher += 1
            state.watchers[id] = continuation
            return (id, state.value)
        }
        guard let registered else {
            continuation.finish()
            return stream
        }
        continuation.onTermination = { [weak self] _ in
            self?.current.withLock { _ = $0.watchers.removeValue(forKey: registered.id) }
        }
        if let value = registered.value { continuation.yield(value) }
        return stream
    }

    /// End every watcher's stream, and any later one's at once.
    func finish() {
        let watchers = current.withLock { state in
            state.finished = true
            defer { state.watchers = [:] }
            return state.watchers
        }
        for watcher in watchers.values { watcher.finish() }
    }
}
