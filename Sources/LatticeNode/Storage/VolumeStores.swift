import Crypto
import Foundation
import Lattice
import LatticeNodeCore
import VolumeBroker
import cashew

/// Which stores a read asks, in order.
enum ReadScope: Hashable, Sendable {
    /// The chain's own store, then its ancestors' nearest first: a child's
    /// receipt proofs travel with its blocks, so a chain's work needs
    /// nothing of a sibling's.
    case chain(ChainPath)
    /// As `chain`, then its descendants': a template carries the levels
    /// below it, as does a mined block.
    case subtree(ChainPath)
    /// Every store, root first: only reads that name no chain, a read by
    /// CID from the API or a peer, a bundle served, a header page served
    /// when the header record lacks it, a child genesis's spec at a start,
    /// and boot.
    case anyChain
}

/// One Volume store per hosted chain path, each a file of its own under
/// `volumes/` beside `state.db`: a chain's content, its retention scopes and
/// its counts live in its store and nowhere else, so a chain's tables hold
/// only its rows and its writes do not grow with the chains hosted beside it
/// (node design §4.9b). The root chain's store also holds what belongs to
/// the node rather than a chain: the protocol constants, the Nexus genesis,
/// the operator's policy modules and pins, and the mempool's journal pins.
///
/// Writes name their chain (`store(at:)`); reads name their scope
/// (`reads(_:)`, `ReadScope`). A chain's reads that asked every store probed
/// each in turn and missed in all but one, which cost 17% more CPU with
/// eight children.
///
/// The set of stores changes only on the loop, when the operator's
/// configuration hosts or drops a chain, and at a start; each change
/// publishes an immutable `Snapshot` (the stores, each scope's reading
/// order, and its readers), which every read takes as it is
/// (`PublishedValue`).
final class VolumeStores: Sendable {
    let directory: URL
    let rootPath: ChainPath
    /// The root chain's store, open for the stores' life.
    let root: DiskBroker
    private let headers: any ContentSource
    private let current: PublishedValue<Snapshot>

    /// The open stores, each scope's reading order, and its readers, as the
    /// last change of the set left them.
    struct Snapshot: Sendable {
        let stores: [ChainPath: DiskBroker]
        /// The root's first, then by depth and path.
        let ordered: [(path: ChainPath, store: DiskBroker)]
        let readers: [ReadScope: Readers]

        init(_ stores: [ChainPath: DiskBroker], root: ChainPath, headers: any ContentSource) {
            self.stores = stores
            ordered = stores.map { (path: $0.key, store: $0.value) }
                .sorted { ($0.path.count, $0.path.joined(separator: "/")) < ($1.path.count, $1.path.joined(separator: "/")) }
            var readers: [ReadScope: Readers] = [.anyChain: Readers(ordered.map(\.store), headers: headers)]
            for path in stores.keys {
                for scope in [ReadScope.chain(path), .subtree(path)] {
                    readers[scope] = Readers(Self.order(scope, root: root, stores: stores, ordered: ordered), headers: headers)
                }
            }
            self.readers = readers
        }

        static func order(
            _ scope: ReadScope, root: ChainPath, stores: [ChainPath: DiskBroker],
            ordered: [(path: ChainPath, store: DiskBroker)]
        ) -> [DiskBroker] {
            switch scope {
            case .anyChain:
                return ordered.map(\.store)
            case .chain(let path), .subtree(let path):
                let lineage = (root.count...max(root.count, path.count)).reversed().compactMap { stores[Array(path.prefix($0))] }
                guard case .subtree = scope else { return lineage }
                return lineage + ordered.filter { $0.path.count > path.count && $0.path.starts(with: path) }.map(\.store)
            }
        }
    }

    /// A scope's readers: its stores alone, and behind them the header
    /// records, each as a fetcher its reads in flight share.
    struct Readers: Sendable {
        let stores: StoreReads
        let local: CoalescingFetcher
        let workSource: CompositeContentSource
        let work: CoalescingFetcher

        init(_ stores: [DiskBroker], headers: any ContentSource) {
            self.stores = StoreReads(stores: stores)
            local = CoalescingFetcher(ReadTally.wrap("store", self.stores))
            workSource = CompositeContentSource([ReadTally.wrap("store", self.stores), ReadTally.wrap("headers", headers)])
            work = CoalescingFetcher(workSource)
        }
    }

    /// Opens the root's store and each of `hosted`'s. Nothing is removed
    /// here: a chain not hosted is let go of at the start, after state.db
    /// is validated, content first (`NodeStorage.letGoOfChains`, then
    /// `removeFiles(except:)`).
    init(directory storage: URL, root rootPath: ChainPath, hosted: [ChainPath], headers: any ContentSource) throws {
        directory = storage.appendingPathComponent("volumes", isDirectory: true)
        self.rootPath = rootPath
        self.headers = headers
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        root = try Self.open(directory, rootPath)
        var stores = [rootPath: root]
        for path in hosted where path != rootPath { stores[path] = try Self.open(directory, path) }
        current = PublishedValue(Snapshot(stores, root: rootPath, headers: headers))
    }

    private var snapshot: Snapshot {
        guard let held = current.value else { preconditionFailure("the stores are published at init") }
        return held
    }

    /// The store of the chain at `path`: every write names the chain it is
    /// for. A chain not hosted has none (`NotHosted`), so no write makes a
    /// file: a late job of a chain let go of writes nowhere.
    func store(at path: ChainPath) throws -> DiskBroker {
        guard let held = snapshot.stores[path] else { throw NotHosted(path: path) }
        return held
    }

    /// The chain at `path` is not hosted here.
    struct NotHosted: Error, Equatable {
        let path: ChainPath
    }

    /// A chain this node starts to host: its store is opened (made, the
    /// first time). On the loop only.
    func open(at path: ChainPath) throws {
        var stores = snapshot.stores
        guard stores[path] == nil else { return }
        stores[path] = try Self.open(directory, path)
        current.publish(Snapshot(stores, root: rootPath, headers: headers))
    }

    /// The store of the chain at `path` if it is open.
    func opened(at path: ChainPath) -> DiskBroker? {
        snapshot.stores[path]
    }

    /// Every open store with its chain, the root's first.
    var byChain: [(path: ChainPath, store: DiskBroker)] {
        snapshot.ordered
    }

    /// The readers of `scope`: one worked out when the set changed for a
    /// hosted chain, else for this read.
    func readers(_ scope: ReadScope) -> Readers {
        let held = snapshot
        return held.readers[scope]
            ?? Readers(Snapshot.order(scope, root: rootPath, stores: held.stores, ordered: held.ordered), headers: headers)
    }

    /// The stores `scope` reads, by CID.
    func reads(_ scope: ReadScope) -> StoreReads {
        readers(scope).stores
    }

    /// Every store, root first: reads that name no chain.
    var anyChain: StoreReads {
        reads(.anyChain)
    }

    /// The chain at `path` is let go of: its store closes and its file
    /// goes, with its log and shared memory, and everything in it. Its jobs
    /// have ended (`Retention.release`); a read in flight finishes on the
    /// file it opened, and a write that comes late is refused (`NotHosted`).
    /// On the loop, or at the start.
    func remove(at path: ChainPath) {
        guard path != rootPath else { return }
        var stores = snapshot.stores
        stores[path] = nil
        current.publish(Snapshot(stores, root: rootPath, headers: headers))
        let file = directory.appendingPathComponent(Self.fileName(path))
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: file.path + suffix)
        }
    }

    /// Removes every file under `volumes/` that is not the store of a chain
    /// in `chains`, logs and shared memory included: what a chain no longer
    /// hosted left with no facts to name it. A stale log never pairs with a
    /// new file.
    func removeFiles(except chains: Set<ChainPath>) {
        let wanted = Set(chains.flatMap { path in ["", "-wal", "-shm"].map { Self.fileName(path) + $0 } })
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where !wanted.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: - Maintenance across every store

    /// What no scope names goes, store by store.
    func sweep() async throws {
        for (_, store) in byChain { _ = try await store.sweep() }
    }

    /// Each store's scopes beginning with `prefix`, with its store.
    func retainedScopes(prefix: String) async throws -> [(store: DiskBroker, scope: String)] {
        var listed: [(store: DiskBroker, scope: String)] = []
        for (_, store) in byChain { listed += try await store.retainedScopes(prefix: prefix).map { (store, $0) } }
        return listed
    }

    /// Each store's counted scopes beginning with `prefix`.
    func countedScopes(prefix: String) async throws -> [(store: DiskBroker, scope: String)] {
        var listed: [(store: DiskBroker, scope: String)] = []
        for (_, store) in byChain { listed += try await store.countedScopes(prefix: prefix).map { (store, $0) } }
        return listed
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

/// Reads by CID over a fixed list of stores, in order (`ReadScope`).
struct StoreReads: ContentSource {
    let stores: [DiskBroker]

    /// Content whose CID fixes its bytes and that nearly every block names,
    /// answered without asking a store: the empty child index (a block with
    /// no child blocks) and the empty Merkle dictionary (a block with no
    /// transactions, an empty state trie). Node design §2, "What the
    /// repeated reads are".
    static let empty: [String: Data] = {
        let childIndex = FlatDictionary<BlockHeader>()
        let dictionary = MerkleDictionaryImpl<VolumeImpl<Transaction>>(children: [:], count: 0)
        let entries: [(String, Data)?] = [
            (try? HeaderImpl(node: childIndex).rawCID).flatMap { cid in childIndex.toData().map { (cid, $0) } },
            (try? HeaderImpl(node: dictionary).rawCID).flatMap { cid in dictionary.toData().map { (cid, $0) } },
        ]
        return Dictionary(entries.compactMap { $0 }) { first, _ in first }
    }()

    func fetch(_ cids: Set<String>) async -> [String: Data] {
        var found = Self.empty.filter { cids.contains($0.key) }
        var missing = cids.subtracting(found.keys)
        for store in stores {
            guard !missing.isEmpty else { break }
            let held = await store.fetchDataLocal(cids: missing)
            found.merge(held) { first, _ in first }
            missing.subtract(held.keys)
        }
        return found
    }

    func fetchDataLocal(cid: String) async -> Data? {
        if let held = Self.empty[cid] { return held }
        for store in stores { if let held = await store.fetchDataLocal(cid: cid) { return held } }
        return nil
    }

    func fetchVolumeLocal(root cid: String) async -> SerializedVolume? {
        for store in stores { if let held = await store.fetchVolumeLocal(root: cid) { return held } }
        return nil
    }

    func hasVolume(root cid: String) async -> Bool {
        for store in stores where await store.hasVolume(root: cid) { return true }
        return false
    }
}
