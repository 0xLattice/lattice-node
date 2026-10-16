import Synchronization

/// The child directories a chain's executed blocks commit. Execution is
/// irrevocable, so the list only grows: a directory stays once any executed
/// block committed it. It lists children; finding one is its hosts'
/// rendezvous.
///
/// Shared by the level core and the read views that publish it; the core
/// writes, readers take the lock.
public final class ExecutedChildren: Sendable {
    /// Kept in order; a new name is inserted in place.
    private let sorted = Mutex<[String]>([])

    public init() {}

    /// An executed block committed children under `directories`.
    public func record<S: Sequence<String>>(_ directories: S) {
        sorted.withLock { names in
            for directory in directories {
                let low = Self.firstIndex(notBelow: directory, in: names)
                if low == names.count || names[low] != directory { names.insert(directory, at: low) }
            }
        }
    }

    /// Every directory, in order.
    public var names: [String] { sorted.withLock { $0 } }

    /// Up to `limit` directories after `after` (from the first when nil), in
    /// order, and whether more follow.
    public func page(after: String?, limit: Int) -> (names: [String], more: Bool) {
        sorted.withLock { names in
            var start = 0
            if let after {
                start = Self.firstIndex(notBelow: after, in: names)
                if start < names.count, names[start] == after { start += 1 }
            }
            let end = min(names.count, start + max(limit, 0))
            return (Array(names[start..<end]), end < names.count)
        }
    }

    private static func firstIndex(notBelow name: String, in names: [String]) -> Int {
        var low = 0, high = names.count
        while low < high {
            let middle = (low + high) / 2
            if names[middle] < name { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
