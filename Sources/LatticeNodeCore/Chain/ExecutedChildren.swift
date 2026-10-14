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
        /// The `recentLimit` most recently committed, kept as `newest` grows:
        /// a directory's rank only rises (a higher height, or the same height
        /// with a smaller CID), so one that falls out returns only through
        /// its own record.
        var recent: [Commitment] = []
    }

    private let state = Mutex(State())

    public init() {}

    /// Whether `a` is listed before `b`: the higher height, then the directory.
    private static func before(_ a: Commitment, _ b: Commitment) -> Bool {
        a.height != b.height ? a.height > b.height : a.directory < b.directory
    }

    /// An executed block at `height` committed `commitments` (directory →
    /// child block). A directory keeps its highest commitment; at one height,
    /// the smaller CID. Costs O(`recentLimit`) per directory changed.
    public func record(_ commitments: [String: String], height: UInt64) {
        guard !commitments.isEmpty else { return }
        state.withLock { state in
            for (directory, cid) in commitments {
                if let held = state.newest[directory],
                   held.height > height || (held.height == height && held.cid <= cid) { continue }
                let entry = Commitment(directory: directory, cid: cid, height: height)
                state.newest[directory] = entry
                state.recent.removeAll { $0.directory == directory }
                if state.recent.count < Self.recentLimit || Self.before(entry, state.recent[state.recent.count - 1]) {
                    var low = 0, high = state.recent.count
                    while low < high {
                        let middle = (low + high) / 2
                        if Self.before(state.recent[middle], entry) { low = middle + 1 } else { high = middle }
                    }
                    state.recent.insert(entry, at: low)
                    if state.recent.count > Self.recentLimit { state.recent.removeLast() }
                }
            }
        }
    }

    /// The newest commitment under `directory`, if any.
    public subscript(directory: String) -> Commitment? {
        state.withLock { $0.newest[directory] }
    }

    public var count: Int { state.withLock { $0.newest.count } }

    /// At most `limit` (up to `recentLimit`) directories, the most recently
    /// committed first, ties by directory. A copy: nothing is sorted here.
    public func mostRecent(_ limit: Int) -> [Commitment] {
        state.withLock { Array($0.recent.prefix(max(0, limit))) }
    }
}
