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

/// Verified content finished sessions took from peers, in memory, whole
/// Volumes by their roots: a body fetched for a block then serves its
/// connect, and a template's reads the block mined on it and the next
/// template, without asking peers again. Only the operator's own reads
/// consult it, as they read everything: a body's fetch reads only what
/// it fetches itself.
///
/// Each Volume was requested by its root and checked against its CIDs by
/// the session that fetched it, and its reader checks what it reads again.
/// It is not the Volume store: nothing here is stored until a block's
/// execution finds it valid.
///
/// Bounded in bytes, each entry charged as a session charges it; the
/// Volumes read least recently go first, and one evicted is fetched again
/// when it is read.
actor ReadCache: ContentSource {
    private struct Held {
        let volume: SerializedVolume
        let bytes: Int
        var lastRead: UInt64
    }

    private var volumes: [String: Held] = [:]
    /// The roots of the held Volumes each CID is in.
    private var roots: [String: Set<String>] = [:]
    private var bytes = 0
    private var clock: UInt64 = 0
    private let maximumBytes: Int

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    var isEmpty: Bool { volumes.isEmpty }

    /// The bytes held now.
    var heldBytes: Int { bytes }

    /// The whole Volume under `root`, when held.
    func volume(_ root: String) -> SerializedVolume? {
        clock += 1
        volumes[root]?.lastRead = clock
        return volumes[root]?.volume
    }

    func fetch(_ cids: Set<String>) async -> [String: Data] {
        clock += 1
        var found: [String: Data] = [:]
        for cid in cids {
            guard let root = roots[cid]?.first, let data = volumes[root]?.volume.entries[cid] else { continue }
            found[cid] = data
            volumes[root]?.lastRead = clock
        }
        return found
    }

    /// Keeps these Volumes, each whole or not at all, as the most recently read.
    func put(_ incoming: [SerializedVolume]) {
        for volume in incoming {
            clock += 1
            if volumes[volume.root] != nil {
                volumes[volume.root]?.lastRead = clock
                continue
            }
            let charge = volume.entries.reduce(0) {
                $0 + $1.key.utf8.count + $1.value.count + IvyRootContentSource.retainedEntryOverhead
            }
            guard charge <= maximumBytes else { continue }
            while bytes + charge > maximumBytes,
                  let oldest = volumes.min(by: { $0.value.lastRead < $1.value.lastRead })?.key {
                evict(oldest)
            }
            volumes[volume.root] = Held(volume: volume, bytes: charge, lastRead: clock)
            for cid in volume.entries.keys { roots[cid, default: []].insert(volume.root) }
            bytes += charge
        }
    }

    /// Keeps what a finished session verified.
    func put(_ session: IvyRootContentSource.Session) async {
        put(await session.verifiedVolumes())
    }

    private func evict(_ root: String) {
        guard let held = volumes.removeValue(forKey: root) else { return }
        for cid in held.volume.entries.keys {
            roots[cid]?.remove(root)
            if roots[cid]?.isEmpty == true { roots[cid] = nil }
        }
        bytes -= held.bytes
    }
}
