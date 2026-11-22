import Foundation
import Lattice
import VolumeBroker
import cashew
import LatticeNodeAPI
import LatticeNodeStore

/// Verified content in memory, for reads that would otherwise ask peers
/// again: the Volumes a body fetch derived for its block, whole, serve
/// the block's connect; what the operator's own reads asked of peers, the
/// entries as they asked for them, serves the next read (a template's
/// reads the block mined on it). Only the operator's own reads consult
/// it: a body's fetch reads only what it fetches itself.
///
/// Only the whole Volumes are Volumes this node derived itself, walking a
/// body it fetched to its end, as storing the block would derive them. A
/// peer chooses what it sends with a Volume, so nothing a peer sent is
/// kept as a Volume. Each entry was checked against its CID, and its
/// reader checks it again. It is not the Volume store: nothing here is
/// stored until a block's execution finds it valid.
///
/// Bounded in bytes, each entry charged as a session charges it. When room
/// is needed, what goes first: bodies of blocks in no chain's body window
/// (connected, or off the best chain), then the entries reads asked for,
/// then bodies furthest ahead of their chain's next block to connect
/// (`order(bodies:leaving:)`), the least recently read first among equals.
/// What would go before everything it would have to evict is not kept. What
/// is evicted is fetched again when it is read: this decides only what is
/// asked of peers twice. What is put again replaces what is held.
actor ReadCache: ContentSource {
    private enum Key: Hashable {
        /// A whole Volume a body's fetch derived for its block, by its root.
        case body(block: String, root: String)
        /// One entry a read asked for, by its CID.
        case entry(String)

        var root: String? {
            if case .body(_, let root) = self { root } else { nil }
        }
    }

    private struct Held {
        let entries: [String: Data]
        let bytes: Int
        /// When an entry was last read; a body's is its block's (`Body`).
        var read: UInt64 = 0
        var older: Key? = nil
        var newer: Key? = nil
    }

    /// A block's body: the roots of its Volumes held, and when it was last read.
    private struct Body {
        let roots: [String]
        var read: UInt64
    }

    /// Which goes first when room is needed: the greater.
    private typealias Rank = (Int, Int, UInt64)

    private var held: [Key: Held] = [:]
    /// The entries reads asked for, in recency order, a list linked
    /// through `older` and `newer`.
    private var oldest: Key?
    private var newest: Key?
    private var bodies: [String: Body] = [:]
    /// The held body Volumes each CID is in.
    private var containing: [String: Set<Key>] = [:]
    /// Each window block's distance from its chain's next block to connect.
    private var distances: [String: Int] = [:]
    /// How many held bodies are of blocks in no window: the bodies that go
    /// before a read's entries.
    private var outsideWindow = 0
    private var clock: UInt64 = 0
    private var bytes = 0
    private let maximumBytes: Int

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    var isEmpty: Bool { held.isEmpty }

    /// The bytes held now.
    var heldBytes: Int { bytes }

    /// The CIDs held now, read or not.
    var heldCIDs: Set<String> { Set(held.values.flatMap(\.entries.keys)) }

    /// How many times room was made by looking through the held bodies.
    private(set) var bodyScans = 0

    /// The window blocks whose distance from their chain's next block to
    /// connect (0 for that block) changed, each by its distance, and the
    /// blocks that left every window: the order their bodies are needed in.
    func order(bodies distances: [String: Int], leaving left: Set<String>) {
        for (block, distance) in distances where self.distances.updateValue(distance, forKey: block) == nil {
            if bodies[block] != nil { outsideWindow -= 1 }
        }
        for block in left where self.distances.removeValue(forKey: block) != nil {
            if bodies[block] != nil { outsideWindow += 1 }
        }
    }

    /// The whole Volume under `root`, when this node derived it and it is held.
    func volume(_ root: String) -> SerializedVolume? {
        guard let key = containing[root]?.first(where: { $0.root == root }),
              let entries = held[key]?.entries else { return nil }
        touch(key)
        return SerializedVolume(root: root, entries: entries)
    }

    /// The whole Volumes a fetch of `block`'s body derived, when held: the
    /// Volumes storing the block derives.
    func body(_ block: String) -> [SerializedVolume]? {
        bodies[block]?.roots.compactMap { root in
            held[.body(block: block, root: root)].map { SerializedVolume(root: root, entries: $0.entries) }
        }
    }

    func fetch(_ cids: Set<String>) async -> [String: Data] {
        var found: [String: Data] = [:]
        for cid in cids {
            guard let key = held[.entry(cid)] != nil ? .entry(cid) : containing[cid]?.first,
                  let data = held[key]?.entries[cid] else { continue }
            found[cid] = data
            touch(key)
        }
        return found
    }

    /// Keeps the Volumes a fetch of `block`'s body derived, all or none.
    func put(_ volumes: [SerializedVolume], block: String) {
        evict(body: block)
        var unique: [String: [String: Data]] = [:]
        for volume in volumes { unique[volume.root] = volume.entries }
        let charges = unique.mapValues(Self.charge)
        var victims: [(rank: Rank, block: String)]?
        guard makeRoom(charges.values.reduce(0, +), for: rank(body: block, read: clock + 1), victims: &victims) else { return }
        clock += 1
        for (root, entries) in unique {
            let key = Key.body(block: block, root: root)
            held[key] = Held(entries: entries, bytes: charges[root] ?? 0)
            for cid in entries.keys { containing[cid, default: []].insert(key) }
            bytes += charges[root] ?? 0
        }
        bodies[block] = Body(roots: Array(unique.keys), read: clock)
        if distances[block] == nil { outsideWindow += 1 }
    }

    /// Keeps entries a read asked for, each on its own.
    func put(entries: [String: Data]) {
        // An entry goes before every body in a window and after every other
        // body, so the bodies it may evict are the same for the whole batch.
        var victims: [(rank: Rank, block: String)]?
        for (cid, data) in entries {
            let key = Key.entry(cid)
            evict(entry: key)
            let charge = Self.charge([cid: data])
            guard makeRoom(charge, for: (1, 0, UInt64.max - (clock + 1)), victims: &victims) else { continue }
            clock += 1
            held[key] = Held(entries: [cid: data], bytes: charge, read: clock)
            link(key)
            bytes += charge
        }
    }

    /// `source`, with the entries a read asks of it kept here.
    nonisolated func remembering(_ source: any ContentSource) -> any ContentSource {
        Remembering(source: source, cache: self)
    }

    private struct Remembering: ContentSource {
        let source: any ContentSource
        let cache: ReadCache

        func fetch(_ cids: Set<String>) async -> [String: Data] {
            let answer = await source.fetch(cids)
            await cache.put(entries: answer.filter { cids.contains($0.key) })
            return answer
        }
    }

    private static func charge(_ entries: [String: Data]) -> Int {
        entries.reduce(0) {
            $0 + $1.key.utf8.count + $1.value.count + IvyRootContentSource.retainedEntryOverhead
        }
    }

    /// A body's rank: a block in no window first, then by distance.
    private func rank(body block: String, read: UInt64) -> Rank {
        guard let distance = distances[block] else { return (2, 0, UInt64.max - read) }
        return (0, distance, UInt64.max - read)
    }

    /// Evicts what goes before `rank` until `charge` fits. False, having
    /// evicted only what goes before it, when it does not.
    ///
    /// `victims` are the bodies that go before `rank`, last first, found
    /// once and kept for the rest of a put. Only a body in a window can go
    /// after a read's entries, so while every held body is in a window an entry
    /// looks at no body: refusing it costs nothing while the cache is full
    /// of bodies the windows need.
    private func makeRoom(_ charge: Int, for rank: Rank, victims: inout [(rank: Rank, block: String)]?) -> Bool {
        guard charge <= maximumBytes else { return false }
        while bytes + charge > maximumBytes {
            if victims == nil, rank.0 == 0 || outsideWindow > 0 {
                bodyScans += 1
                victims = bodies.compactMap { block, body in
                    let candidate = self.rank(body: block, read: body.read)
                    return candidate > rank ? (candidate, block) : nil
                }.sorted { $0.rank < $1.rank }
            }
            var first: (rank: Rank, body: String?)? = victims?.last.map { ($0.rank, $0.block) }
            if let oldest, let entry = held[oldest] {
                let candidate: Rank = (1, 0, UInt64.max - entry.read)
                if first.map({ candidate > $0.rank }) ?? true { first = (candidate, nil) }
            }
            guard let first, first.rank > rank else { return false }
            if let block = first.body {
                victims?.removeLast()
                evict(body: block)
            } else if let oldest {
                evict(entry: oldest)
            }
        }
        return true
    }

    /// Makes `key` the most recently read.
    private func touch(_ key: Key) {
        clock += 1
        switch key {
        case .body(let block, _):
            bodies[block]?.read = clock
        case .entry:
            held[key]?.read = clock
            guard newest != key else { return }
            unlink(key)
            link(key)
        }
    }

    /// Puts held `key` at the newest end.
    private func link(_ key: Key) {
        held[key]?.older = newest
        held[key]?.newer = nil
        if let newest { held[newest]?.newer = key } else { oldest = key }
        newest = key
    }

    private func unlink(_ key: Key) {
        guard let entry = held[key] else { return }
        if let older = entry.older { held[older]?.newer = entry.newer } else { oldest = entry.newer }
        if let newer = entry.newer { held[newer]?.older = entry.older } else { newest = entry.older }
    }

    private func evict(entry key: Key) {
        guard held[key] != nil else { return }
        unlink(key)
        guard let entry = held.removeValue(forKey: key) else { return }
        bytes -= entry.bytes
    }

    private func evict(body block: String) {
        guard let body = bodies.removeValue(forKey: block) else { return }
        if distances[block] == nil { outsideWindow -= 1 }
        for root in body.roots {
            let key = Key.body(block: block, root: root)
            guard let entry = held.removeValue(forKey: key) else { continue }
            for cid in entry.entries.keys {
                containing[cid]?.remove(key)
                if containing[cid]?.isEmpty == true { containing[cid] = nil }
            }
            bytes -= entry.bytes
        }
    }
}
