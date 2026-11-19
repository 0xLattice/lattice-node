import Foundation
import Synchronization
import VolumeBroker
import cashew

/// Executed state not yet in the content store: what executions created,
/// held in memory, read from here first, and written to the store in one
/// transaction when it is flushed (`NodeStorage.flushState`). Bitcoin Core
/// keeps its coins this way (`-dbcache`), and geth its trie nodes.
///
/// A Volume here is in no store transaction yet, so a crash loses it. The
/// blocks whose state is only here are named in state.db
/// (`NodeStore.unflushedBlocks`), and a start executes them again.
///
/// Reads and adds may come from any task. A flush takes a `batch`, stores
/// it, then removes exactly that batch: what was added meanwhile stays.
final class StateBuffer: ContentSource, Sendable {
    /// What one flush writes: the Volumes, and the scopes that retain them.
    struct Batch: Sendable {
        let volumes: [ValidatedVolume]
        let retaining: [String: [String]]

        var isEmpty: Bool { volumes.isEmpty && retaining.isEmpty }
    }

    private struct Held {
        var volumes: [String: ValidatedVolume] = [:]
        /// Every entry of every held Volume, and how many of them carry it.
        var entries: [String: (data: Data, holders: Int)] = [:]
        var retaining: [String: Set<String>] = [:]
        var bytes = 0
    }

    private let held = Mutex(Held())

    /// The bytes of the entries held, each counted once.
    var bytes: Int { held.withLock(\.bytes) }

    var isEmpty: Bool { held.withLock { $0.volumes.isEmpty && $0.retaining.isEmpty } }

    /// Holds `volumes`, each retained under the scopes of `retaining` that
    /// name its root. A root may be retained that an earlier flush stored.
    func add(_ volumes: [ValidatedVolume], retaining: [String: [String]]) {
        held.withLock { held in
            for volume in volumes where held.volumes[volume.volume.root] == nil {
                held.volumes[volume.volume.root] = volume
                for (cid, data) in volume.volume.entries {
                    if held.entries[cid] == nil {
                        held.entries[cid] = (data, 1)
                        held.bytes += data.count
                    } else {
                        held.entries[cid]?.holders += 1
                    }
                }
            }
            for (scope, roots) in retaining where !roots.isEmpty {
                held.retaining[scope, default: []].formUnion(roots)
            }
        }
    }

    public func fetch(_ cids: Set<String>) async -> [String: Data] {
        held.withLock { held in
            guard !held.entries.isEmpty else { return [:] }
            var found: [String: Data] = [:]
            for cid in cids {
                if let entry = held.entries[cid] { found[cid] = entry.data }
            }
            return found
        }
    }

    /// The held Volume `root` names, whole.
    func volume(_ root: String) -> SerializedVolume? {
        held.withLock { $0.volumes[root]?.volume }
    }

    /// Everything held now, for one flush.
    func batch() -> Batch {
        held.withLock { held in
            Batch(
                volumes: held.volumes.keys.sorted().compactMap { held.volumes[$0] },
                retaining: held.retaining.mapValues { $0.sorted() }
            )
        }
    }

    /// Lets go of `batch`, which the store now holds. A Volume or a
    /// retention added since the batch was taken stays.
    func remove(_ batch: Batch) {
        held.withLock { held in
            for volume in batch.volumes {
                guard held.volumes.removeValue(forKey: volume.volume.root) != nil else { continue }
                for cid in volume.volume.entries.keys {
                    guard let entry = held.entries[cid] else { continue }
                    if entry.holders > 1 {
                        held.entries[cid]?.holders -= 1
                    } else {
                        held.entries[cid] = nil
                        held.bytes -= entry.data.count
                    }
                }
            }
            for (scope, roots) in batch.retaining {
                held.retaining[scope]?.subtract(roots)
                if held.retaining[scope]?.isEmpty == true { held.retaining[scope] = nil }
            }
        }
    }
}
