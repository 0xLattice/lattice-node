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
        // Yielded under the lock, so a watcher registering meanwhile never
        // gets an older value after this one. A yield never runs a
        // termination handler, which takes the lock.
        let ended = current.withLock { state -> [UInt64] in
            state.value = value
            return state.watchers.compactMap { id, watcher in
                if case .terminated = watcher.yield(value) { id } else { nil }
            }
        }
        guard !ended.isEmpty else { return }
        current.withLock { state in
            for id in ended { state.watchers.removeValue(forKey: id) }
        }
    }

    /// The current value, if any, then each one published. Newest only: a
    /// reader that falls behind skips to the latest, so a stalled one holds
    /// one value. Ends when the publisher `finish`es.
    public func updates() -> AsyncStream<Value> {
        let (stream, continuation) = AsyncStream<Value>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = current.withLock { state -> UInt64? in
            guard !state.finished else { return nil }
            let id = state.nextWatcher
            state.nextWatcher += 1
            state.watchers[id] = continuation
            // Under the lock, so no publish lands between this and the
            // registration and is then overwritten by an older value.
            if let value = state.value { continuation.yield(value) }
            return id
        }
        guard let id else {
            continuation.finish()
            return stream
        }
        continuation.onTermination = { [weak self] _ in
            self?.current.withLock { _ = $0.watchers.removeValue(forKey: id) }
        }
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
