import Foundation
import Lattice
import VolumeBroker
import cashew

public enum NodeStorageError: Error, Equatable, Sendable {
    case invalidStoragePath
    case storageInUse
    case storageUnavailable
    case invalidNexusGenesis
    case missingMaterializedVolume(String)
    /// Entries given for a Volume that do not match their CIDs or lack its root.
    case invalidVolume(String)
    /// A body's content is past this node's byte budget for one fetch.
    case bodyExceedsLocalBudget(bytes: Int)
}

public enum ChainPhase: String, Sendable {
    case awaitingGenesis
    case active
}

public struct ChainStatus: Sendable, Equatable {
    public let phase: ChainPhase
    public let chainPath: [String]
    public let nexusGenesisCID: String
    public let tipCID: String?
    public let height: UInt64?
    public let revision: UInt64?
    /// The best header chain's height (nil before any header).
    public var bestHeaderHeight: UInt64? = nil
    /// The next block this chain cannot execute yet, and why (nil when none).
    public var waiting: String? = nil
}


struct DurableLocalTransaction: Sendable {
    let transactionCID: String
    let addedAt: Int64
    let transaction: Transaction
}

/// The node runtime's storage gateway: one hosted-tree fact journal, the
/// Volume store and local mempool journal, opened and reconciled
/// at boot. It decides nothing; the core does.
public actor NodeStorage: ContentSource, Fetcher, VolumeStorer {
    public nonisolated let configuration: NodeConfiguration

    let store: NodeStore
    nonisolated let bundles: VolumeBundleCache
    let broker: DiskBroker
    let localFetcher: CoalescingFetcher
    /// Local content, and behind it the header records: a block's own node
    /// is read from them when its body is not held. Execution and mining
    /// build on blocks through this.
    nonisolated let workFetcher: CoalescingFetcher
    nonisolated let workSource: CompositeContentSource
    /// Verified content finished sessions took from peers, in memory.
    nonisolated let readCache: ReadCache
    let retentionScope: String
    let durableMempoolOwner: String
    let liveMempoolOwner: String
    private let directoryLock: StorageDirectoryLock
    private var livePinnedMempoolRoots = Set<String>()

    // Actors are reentrant. This queue keeps each retained-root update in
    // one order across its suspension points.
    private struct OperationWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var operationInFlight = false
    private var operationWaiters: [OperationWaiter] = []

    private init(
        configuration: NodeConfiguration,
        store: NodeStore,
        bundles: VolumeBundleCache,
        broker: DiskBroker,
        localFetcher: CoalescingFetcher,
        retentionScope: String,
        durableMempoolOwner: String,
        liveMempoolOwner: String,
        directoryLock: StorageDirectoryLock
    ) {
        self.configuration = configuration
        self.store = store
        self.bundles = bundles
        self.broker = broker
        self.localFetcher = localFetcher
        self.workSource = CompositeContentSource([broker, HeaderRecords(store: store)])
        self.workFetcher = CoalescingFetcher(workSource)
        self.readCache = ReadCache(maximumBytes: configuration.resourcePolicy.maximumCachedContentBytes)
        self.retentionScope = retentionScope
        self.durableMempoolOwner = durableMempoolOwner
        self.liveMempoolOwner = liveMempoolOwner
        self.directoryLock = directoryLock
    }

    /// Completes store validation and settles what the store pins before
    /// returning a storage the runtime may expose.
    public static func open(
        configuration: NodeConfiguration
    ) async throws -> NodeStorage {
        let recovered = try await BootRecovery.run(configuration: configuration)
        return NodeStorage(
            configuration: configuration,
            store: recovered.store,
            bundles: VolumeBundleCache(directory: configuration.storagePath),
            broker: recovered.broker,
            localFetcher: recovered.localFetcher,
            retentionScope: recovered.retentionScope,
            durableMempoolOwner: recovered.durableMempoolOwner,
            liveMempoolOwner: recovered.liveMempoolOwner,
            directoryLock: recovered.directoryLock
        )
    }

    /// Hosted-tree content serving reads only this storage's durable local tiers.
    public func content(_ cids: Set<String>) async -> [String: Data] {
        await fetch(cids)
    }

    /// Ungated: whether `cid` is a durably accepted block. Public read RPC uses
    /// this as the canonical-data gate before serving decoded block content.
    public func hasAcceptedBlock(
        _ cid: String,
        at chainPath: [String] = ["Nexus"]
    ) async -> Bool {
        (try? await store.hasAcceptedBlock(cid, at: chainPath)) ?? false
    }

    func hasExecutedBlock(_ cid: String, at chainPath: [String]) async -> Bool {
        (try? await store.hasExecutedBlock(cid, at: chainPath)) ?? false
    }

    public func fetch(_ cids: Set<String>) async -> [String: Data] {
        await broker.fetchDataLocal(cids: cids)
    }

    /// A block's own node: from its Volume, or from its header record when
    /// its body is not held. Enough to reach the state it commits to.
    nonisolated func blockNodeBytes(_ cid: String) async -> Data? {
        if let held = await broker.fetchDataLocal(cid: cid) { return held }
        return store.headerBlockBytes(cid)
    }

    /// Peer content exchange serves complete local Volumes. Membership is a
    /// storage fact and cannot be reconstructed from an arbitrary CID list.
    func volume(_ rootCID: String) async -> SerializedVolume? {
        await broker.fetchVolumeLocal(root: rootCID)
    }

    /// The public storage fetch port is deliberately local-only. Network
    /// acquisition is explicit and root-scoped at admission/retry boundaries.
    public func fetch(rawCid: String) async throws -> Data {
        try await localFetcher.fetch(rawCid: rawCid)
    }

    public func store(volume: SerializedVolume) async throws {
        try await broker.store(volume: volume)
    }

    @discardableResult
    func persistLocalTransaction(
        _ transaction: Transaction,
        addedAt: Int64 = Int64(Date().timeIntervalSince1970)
    ) async throws -> String {
        try await acquireMutationOperation()
        defer { releaseOperation() }
        guard addedAt >= 0 else {
            throw NodeStoreError.invalidConfiguration(
                "local transaction timestamp is malformed"
            )
        }
        let volume = try VolumeImpl<Transaction>(node: transaction)
        if try await store.localMempoolTransactions().contains(where: {
            $0.transactionCID == volume.rawCID
        }) {
            return volume.rawCID
        }
        try await volume.store(storer: broker)
        try Task.checkCancellation()
        try await broker.retain([volume.rawCID], owner: durableMempoolOwner)
        do {
            try await store.persistLocalMempoolTransaction(
                transactionCID: volume.rawCID,
                addedAt: addedAt
            )
        } catch {
            try await broker.release([volume.rawCID], owner: durableMempoolOwner
            )
            throw error
        }
        return volume.rawCID
    }

    /// Keeps an admitted peer transaction serveable for this storage lifetime.
    /// The scope is cleared on restart, so peer gossip never becomes recovery
    /// authority merely because its bytes use the durable broker.
    func persistPeerTransaction(_ transaction: Transaction) async throws -> String {
        try await acquireMutationOperation()
        defer { releaseOperation() }
        let volume = try VolumeImpl<Transaction>(node: transaction)
        try await volume.store(storer: broker)
        // Eviction uses the same storage mutation gate, so publishing the
        // complete Volume and its live owner pin is atomic at the node boundary.
        if !livePinnedMempoolRoots.contains(volume.rawCID) {
            try await broker.retain([volume.rawCID], owner: liveMempoolOwner)
            livePinnedMempoolRoots.insert(volume.rawCID)
        }
        return volume.rawCID
    }

    /// Owner/count deltas keep live-pool retention O(changes), while startup's
    /// owner reset makes these pins storage-local authority.
    func updateLiveMempoolRoots(
        adding: Set<String>,
        removing: Set<String>
    ) async throws {
        try await acquireMutationOperation()
        defer { releaseOperation() }
        let added = adding.subtracting(livePinnedMempoolRoots)
        let removed = removing.intersection(livePinnedMempoolRoots)
        if !added.isEmpty {
            try await broker.retain(added.sorted(),
                owner: liveMempoolOwner
            )
            livePinnedMempoolRoots.formUnion(added)
        }
        if !removed.isEmpty {
            try await broker.release(Set(removed.sorted()), owner: liveMempoolOwner)
            livePinnedMempoolRoots.subtract(removed)
        }
    }

    func removeLocalTransaction(_ transactionCID: String) async throws {
        try await acquireMutationOperation()
        defer { releaseOperation() }
        try await store.removeLocalMempoolTransaction(
            transactionCID: transactionCID
        )
        try await broker.release([transactionCID], owner: durableMempoolOwner
        )
    }

    func localTransactions() async throws -> [DurableLocalTransaction] {
        await acquireOperation()
        defer { releaseOperation() }
        var transactions: [DurableLocalTransaction] = []
        for record in try await store.localMempoolTransactions() {
            let volume = try await VolumeImpl<Transaction>(
                rawCID: record.transactionCID
            ).resolveRecursive(source: broker)
            guard let transaction = volume.node else {
                throw NodeStorageError.missingMaterializedVolume(
                    record.transactionCID
                )
            }
            transactions.append(DurableLocalTransaction(
                transactionCID: record.transactionCID,
                addedAt: record.addedAt,
                transaction: transaction
            ))
        }
        return transactions
    }

    func localTransactionTimestamps() async throws -> [String: Int64] {
        await acquireOperation()
        defer { releaseOperation() }
        return Dictionary(uniqueKeysWithValues:
            try await store.localMempoolTransactions().map {
                ($0.transactionCID, $0.addedAt)
            }
        )
    }

    private func acquireOperation() async {
        _ = await acquireOperation(cancellable: false)
    }

    private func acquireMutationOperation() async throws {
        guard await acquireOperation(cancellable: true) else {
            throw CancellationError()
        }
        guard !Task.isCancelled else {
            releaseOperation()
            throw CancellationError()
        }
    }

    private func acquireOperation(cancellable: Bool) async -> Bool {
        guard !cancellable || !Task.isCancelled else { return false }
        if !operationInFlight {
            operationInFlight = true
            if cancellable && Task.isCancelled {
                releaseOperation()
                return false
            }
            return true
        }

        let id = UUID()
        if !cancellable {
            return await withCheckedContinuation { continuation in
                operationWaiters.append(OperationWaiter(
                    id: id,
                    continuation: continuation
                ))
            }
        }

        let acquired = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                operationWaiters.append(OperationWaiter(
                    id: id,
                    continuation: continuation
                ))
                if Task.isCancelled {
                    cancelOperationWaiter(id)
                }
            }
        }, onCancel: {
            Task { [weak self] in
                await self?.cancelOperationWaiter(id)
            }
        })
        guard acquired, !Task.isCancelled else {
            if acquired {
                releaseOperation()
            }
            return false
        }
        return true
    }

    private func cancelOperationWaiter(_ id: UUID) {
        guard let index = operationWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        operationWaiters.remove(at: index).continuation.resume(returning: false)
    }

    private func releaseOperation() {
        guard !operationWaiters.isEmpty else {
            operationInFlight = false
            return
        }
        operationWaiters.removeFirst().continuation.resume(returning: true)
    }
}

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
/// Bounded in bytes, each entry charged as a session charges it; what was
/// read least recently goes first, and what is evicted is fetched again
/// when it is read. What is put again replaces what is held.
actor ReadCache: ContentSource {
    private enum Key: Hashable {
        /// A whole Volume this node derived, by its root.
        case volume(String)
        /// One entry a read asked for, by its CID.
        case entry(String)
    }

    private struct Held {
        let entries: [String: Data]
        let bytes: Int
        var older: Key? = nil
        var newer: Key? = nil
    }

    /// Held in recency order, a list linked through `older` and `newer`.
    private var held: [Key: Held] = [:]
    private var oldest: Key?
    private var newest: Key?
    /// The roots of the held whole Volumes each CID is in.
    private var roots: [String: Set<String>] = [:]
    private var bytes = 0
    private let maximumBytes: Int

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    var isEmpty: Bool { held.isEmpty }

    /// The bytes held now.
    var heldBytes: Int { bytes }

    /// The whole Volume under `root`, when this node derived it and it is held.
    func volume(_ root: String) -> SerializedVolume? {
        guard let entries = held[.volume(root)]?.entries else { return nil }
        touch(.volume(root))
        return SerializedVolume(root: root, entries: entries)
    }

    func fetch(_ cids: Set<String>) async -> [String: Data] {
        var found: [String: Data] = [:]
        for cid in cids {
            let key: Key
            if held[.entry(cid)] != nil {
                key = .entry(cid)
            } else if let root = roots[cid]?.first {
                key = .volume(root)
            } else {
                continue
            }
            found[cid] = held[key]?.entries[cid]
            touch(key)
        }
        return found
    }

    /// Keeps the Volumes a body's fetch derived for its block, each whole
    /// or not at all.
    func put(_ volumes: [SerializedVolume]) {
        for volume in volumes { put(volume.entries, as: .volume(volume.root)) }
    }

    /// Keeps entries a read asked for, each on its own.
    func put(entries: [String: Data]) {
        for (cid, data) in entries { put([cid: data], as: .entry(cid)) }
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

    private func put(_ entries: [String: Data], as key: Key) {
        evict(key)
        let charge = entries.reduce(0) {
            $0 + $1.key.utf8.count + $1.value.count + IvyRootContentSource.retainedEntryOverhead
        }
        guard charge <= maximumBytes else { return }
        while bytes + charge > maximumBytes, let oldest { evict(oldest) }
        held[key] = Held(entries: entries, bytes: charge)
        link(key)
        if case .volume(let root) = key {
            for cid in entries.keys { roots[cid, default: []].insert(root) }
        }
        bytes += charge
    }

    /// Makes `key` the most recently read.
    private func touch(_ key: Key) {
        guard newest != key else { return }
        unlink(key)
        link(key)
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

    private func evict(_ key: Key) {
        guard held[key] != nil else { return }
        unlink(key)
        guard let entry = held.removeValue(forKey: key) else { return }
        if case .volume(let root) = key {
            for cid in entry.entries.keys {
                roots[cid]?.remove(root)
                if roots[cid]?.isEmpty == true { roots[cid] = nil }
            }
        }
        bytes -= entry.bytes
    }
}
