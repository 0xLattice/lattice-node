import Synchronization

/// The child directories a chain's executed blocks commit, each with its
/// newest commitment by height. Execution is irrevocable, so the list only
/// grows: a directory stays once any executed block committed it, on the
/// best chain or not. It lists children; finding one is its hosts' rendezvous.
///
/// Shared by the level core and the read views that publish it; the core
/// writes, readers take the lock.
public final class ExecutedChildren: Sendable {
    public struct Commitment: Sendable, Equatable {
        public let directory: String
        public let cid: String
        public let height: UInt64
    }

    /// The most a reader asks `mostRecent` for.
    public static let recentLimit = 100

    private struct State {
        var newest: [String: Commitment] = [:]
        /// The most recently committed, built when first read after a change.
        var recent: [Commitment]?
    }

    private let state = Mutex(State())

    public init() {}

    /// An executed block at `height` committed `commitments` (directory →
    /// child block). A directory keeps its highest commitment; at one height,
    /// the smaller CID.
    public func record(_ commitments: [String: String], height: UInt64) {
        guard !commitments.isEmpty else { return }
        state.withLock { state in
            for (directory, cid) in commitments {
                if let held = state.newest[directory],
                   held.height > height || (held.height == height && held.cid <= cid) { continue }
                state.newest[directory] = Commitment(directory: directory, cid: cid, height: height)
                state.recent = nil
            }
        }
    }

    /// The newest commitment under `directory`, if any.
    public subscript(directory: String) -> Commitment? {
        state.withLock { $0.newest[directory] }
    }

    public var count: Int { state.withLock { $0.newest.count } }

    /// At most `limit` (up to `recentLimit`) directories, the most recently
    /// committed first, ties by directory. Sorted once per change.
    public func mostRecent(_ limit: Int) -> [Commitment] {
        let recent = state.withLock { state in
            if let recent = state.recent { return recent }
            let built = Array(state.newest.values.sorted {
                $0.height != $1.height ? $0.height > $1.height : $0.directory < $1.directory
            }.prefix(Self.recentLimit))
            state.recent = built
            return built
        }
        return Array(recent.prefix(max(0, limit)))
    }
}
