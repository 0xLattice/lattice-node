import Crypto
import Foundation
import LatticeNodeCore
import Synchronization
import VolumeBroker
import cashew

/// One Volume store per hosted chain path, each a file of its own under
/// `volumes/` beside `state.db`: a chain's content, its retention scopes and
/// its counts live in its store and nowhere else, so a chain's tables hold
/// only its rows and its writes do not grow with the chains hosted beside it
/// (node design §4.9b). The root chain's store also holds what belongs to
/// the node rather than a chain: the protocol constants, the Nexus genesis,
/// the operator's policy modules and pins, and the mempool's journal pins.
///
/// Writes name their chain (`store(at:)`); reads compose. A chain's work
/// reads its own store, then its ancestors' (a child's receipt proofs travel
/// with its blocks, so a child's execution needs nothing of a sibling's),
/// and what none of them holds is asked of peers; only a read by CID from
/// the API or a peer, or one that names no chain, asks every store, root
/// first. A chain's reads that asked every store probed each in turn and
/// missed in all but one, which cost 17% more CPU with eight children.
///
/// The set changes only when the operator hosts or drops a chain; the
/// lock guards that set, not any store, and is held only to read or
/// change it.
final class VolumeStores: ContentSource, Sendable {
    let directory: URL
    let rootPath: ChainPath
    /// The root chain's store, open for the stores' life.
    let root: DiskBroker
    private let opened: Mutex<Open>

    /// The open stores, and the same in reading order: the root's first,
    /// then by depth and path.
    private struct Open {
        var stores: [ChainPath: DiskBroker]
        var ordered: [(path: ChainPath, store: DiskBroker)]
        /// Each open chain's reading order (`reading(at:below:)`), worked
        /// out once per change of the set, not per read.
        var lineage: [ChainPath: [DiskBroker]] = [:]
        var subtree: [ChainPath: [DiskBroker]] = [:]

        init(_ stores: [ChainPath: DiskBroker], root: ChainPath) {
            self.stores = stores
            ordered = stores.map { (path: $0.key, store: $0.value) }
                .sorted { ($0.path.count, $0.path.joined(separator: "/")) < ($1.path.count, $1.path.joined(separator: "/")) }
            for path in stores.keys {
                let line = Open.lineage(of: path, root: root, in: stores)
                lineage[path] = line
                subtree[path] = line + ordered.filter { $0.path.count > path.count && $0.path.starts(with: path) }.map(\.store)
            }
        }

        static func lineage(of path: ChainPath, root: ChainPath, in stores: [ChainPath: DiskBroker]) -> [DiskBroker] {
            (root.count...max(root.count, path.count)).reversed().compactMap { stores[Array(path.prefix($0))] }
        }
    }

    /// Opens the root's store and each of `hosted`'s, and removes every
    /// other file under `volumes/`: the store of a chain no longer hosted,
    /// with its log and shared memory, so a stale log never pairs with a
    /// new file.
    init(directory storage: URL, root rootPath: ChainPath, hosted: [ChainPath]) throws {
        directory = storage.appendingPathComponent("volumes", isDirectory: true)
        self.rootPath = rootPath
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let wanted = Set(([rootPath] + hosted).flatMap { path in ["", "-wal", "-shm"].map { Self.fileName(path) + $0 } })
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where !wanted.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        root = try Self.open(directory, rootPath)
        var stores = [rootPath: root]
        for path in hosted where path != rootPath { stores[path] = try Self.open(directory, path) }
        opened = Mutex(Open(stores, root: rootPath))
    }

    /// The store of the chain at `path`: every write names the chain it is
    /// for. A chain this node does not host, and has not hosted since the
    /// start, has none (`NotHosted`): a late job of a level gone writes
    /// nowhere rather than making a file.
    func store(at path: ChainPath) throws -> DiskBroker {
        guard let held = opened.withLock({ $0.stores[path] }) else { throw NotHosted(path: path) }
        return held
    }

    /// The chain at `path` is not hosted here.
    struct NotHosted: Error, Equatable {
        let path: ChainPath
    }

    /// A chain this node starts to host: its store is opened (made, the
    /// first time). It stays open until the node stops, hosted or not.
    func open(at path: ChainPath) throws {
        if opened.withLock({ $0.stores[path] }) != nil { return }
        let made = try Self.open(directory, path)
        return opened.withLock { open in
            guard open.stores[path] == nil else { return }
            var stores = open.stores
            stores[path] = made
            open = Open(stores, root: rootPath)
        }
    }

    /// The store of the chain at `path` if it is open.
    func opened(at path: ChainPath) -> DiskBroker? {
        opened.withLock { $0.stores[path] }
    }

    /// Every open store, the root's first, then by depth and path.
    var all: [DiskBroker] {
        opened.withLock { $0.ordered.map(\.store) }
    }

    /// Every open store with its chain, the root's first.
    var byChain: [(path: ChainPath, store: DiskBroker)] {
        opened.withLock { $0.ordered }
    }

    /// The stores the work of the chain at `path` reads, in order: its own,
    /// then its ancestors' nearest first; with `below`, then its
    /// descendants' (a template built at a chain carries the levels below).
    func reading(at path: ChainPath, below: Bool = false) -> [DiskBroker] {
        opened.withLock { open in
            (below ? open.subtree[path] : open.lineage[path])
                ?? Open.lineage(of: path, root: rootPath, in: open.stores)
                + (below ? open.ordered.filter { $0.path.count > path.count && $0.path.starts(with: path) }.map(\.store) : [])
        }
    }

    /// A content source over `reading(at:below:)`.
    func source(at path: ChainPath, below: Bool = false) -> any ContentSource {
        Reading(stores: self, path: path, below: below)
    }

    /// The chain at `path` is let go of: its store closes and its file
    /// goes, with its log and shared memory, and everything in it. Its jobs
    /// have ended (`Retention.release`); a read in flight finishes on the
    /// file it opened, and a write that comes late is refused (`NotHosted`).
    func remove(at path: ChainPath) {
        guard path != rootPath else { return }
        opened.withLock { open in
            var stores = open.stores
            stores[path] = nil
            open = Open(stores, root: rootPath)
        }
        let file = directory.appendingPathComponent(Self.fileName(path))
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: file.path + suffix)
        }
    }

    // MARK: - Reads by CID, every store

    func fetch(_ cids: Set<String>) async -> [String: Data] {
        var found: [String: Data] = [:]
        var missing = cids
        for store in all {
            guard !missing.isEmpty else { break }
            let held = await store.fetchDataLocal(cids: missing)
            found.merge(held) { first, _ in first }
            missing.subtract(held.keys)
        }
        return found
    }

    func fetchDataLocal(cid: String) async -> Data? {
        for store in all { if let held = await store.fetchDataLocal(cid: cid) { return held } }
        return nil
    }

    func fetchVolumeLocal(root cid: String) async -> SerializedVolume? {
        for store in all { if let held = await store.fetchVolumeLocal(root: cid) { return held } }
        return nil
    }

    func hasVolume(root cid: String) async -> Bool {
        for store in all where await store.hasVolume(root: cid) { return true }
        return false
    }

    /// Whether the stores the chain at `path` reads hold `cid`'s Volume.
    func hasVolume(root cid: String, at path: ChainPath, below: Bool = false) async -> Bool {
        for store in reading(at: path, below: below) where await store.hasVolume(root: cid) { return true }
        return false
    }

    /// What no scope names goes, store by store.
    func sweep() async throws {
        for store in all { _ = try await store.sweep() }
    }

    /// Each store's scopes beginning with `prefix`, with its chain.
    func retainedScopes(prefix: String) async throws -> [(store: DiskBroker, scope: String)] {
        var listed: [(store: DiskBroker, scope: String)] = []
        for store in all { listed += try await store.retainedScopes(prefix: prefix).map { (store, $0) } }
        return listed
    }

    /// Each store's counted scopes beginning with `prefix`.
    func countedScopes(prefix: String) async throws -> [(store: DiskBroker, scope: String)] {
        var listed: [(store: DiskBroker, scope: String)] = []
        for store in all { listed += try await store.countedScopes(prefix: prefix).map { (store, $0) } }
        return listed
    }

    private struct Reading: ContentSource {
        let stores: VolumeStores
        let path: ChainPath
        let below: Bool

        func fetch(_ cids: Set<String>) async -> [String: Data] {
            var found: [String: Data] = [:]
            var missing = cids
            for store in stores.reading(at: path, below: below) {
                guard !missing.isEmpty else { break }
                let held = await store.fetchDataLocal(cids: missing)
                found.merge(held) { first, _ in first }
                missing.subtract(held.keys)
            }
            return found
        }
    }

    // MARK: - Files

    private static func open(_ directory: URL, _ path: ChainPath) throws -> DiskBroker {
        let file = directory.appendingPathComponent(fileName(path)).path
        do {
            return try DiskBroker(path: file)
        } catch BrokerError.migrationRequired(let found, let required) {
            // A Volume store another version wrote is not converted.
            throw NodeStoreError.wipeRequired("\(fileName(path)) has schema \(found), this version reads \(required)")
        }
    }

    /// A chain's file: the hex SHA-256 of its path's directory names joined
    /// by "/" (`printf %s Nexus/Alpha | shasum -a 256`), so any directory
    /// name makes a file name of one length that a case-insensitive file
    /// system cannot confuse with another's.
    static func fileName(_ path: ChainPath) -> String {
        SHA256.hash(data: Data(path.joined(separator: "/").utf8)).map { String(format: "%02x", $0) }.joined() + ".db"
    }
}
