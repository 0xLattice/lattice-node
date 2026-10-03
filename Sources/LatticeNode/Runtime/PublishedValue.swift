import Synchronization

/// The latest value the run loop published. Only the loop writes; readers
/// (RPC) take the current immutable value without touching the loop.
public final class PublishedValue<Value: Sendable>: Sendable {
    private let current: Mutex<Value?>

    public init(_ value: Value? = nil) {
        current = Mutex(value)
    }

    public var value: Value? {
        current.withLock { $0 }
    }

    func publish(_ value: Value) {
        current.withLock { $0 = value }
    }
}
