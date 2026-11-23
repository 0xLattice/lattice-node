import Foundation
import Lattice
import VolumeBroker
import cashew
import LatticeNodeAPI
import LatticeNodeConfig
import LatticeNodeSupport

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
    /// No executed block's fact names this block.
    case missingBlockFact(String)
    /// A child block's own content was obtained, and the receipt proofs its
    /// withdrawals need, which travel with it, were not: no peer served them.
    case receiptProofsUnavailable(String)
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
    /// The best header chain's height (nil before any header).
    public var bestHeaderHeight: UInt64? = nil
    /// The next block this chain cannot execute yet, and why (nil when none).
    public var waiting: String? = nil
    /// What the chain's sync holds (operator status only).
    public var sync: NodeSyncStatus? = nil

    package init(
        phase: ChainPhase, chainPath: [String], nexusGenesisCID: String, tipCID: String?, height: UInt64?,
        bestHeaderHeight: UInt64? = nil, waiting: String? = nil, sync: NodeSyncStatus? = nil
    ) {
        self.phase = phase
        self.chainPath = chainPath
        self.nexusGenesisCID = nexusGenesisCID
        self.tipCID = tipCID
        self.height = height
        self.bestHeaderHeight = bestHeaderHeight
        self.waiting = waiting
        self.sync = sync
    }
}


package struct DurableLocalTransaction: Sendable {
    package let transactionCID: String
    package let addedAt: Int64
    package let transaction: Transaction
}

/// The node runtime's storage gateway: one hosted-tree fact journal, a
/// Volume store per hosted chain and the local mempool journal, opened and reconciled
/// at boot. It decides nothing; the core does.
public actor NodeStorage: ContentSource, Fetcher, VolumeStorer {
    public nonisolated let configuration: StoreConfiguration

    package nonisolated let store: NodeStore
    package nonisolated let bundles: VolumeBundleCache
    /// One Volume store per hosted chain (`VolumeStores`). The root's also
    /// holds the mempool's pins.
    package nonisolated let stores: VolumeStores
    /// Verified content finished sessions took from peers, in memory.
    package nonisolated let readCache: ReadCache
    package nonisolated let retentionScope: String
    package nonisolated let durableMempoolOwner: String
    package nonisolated let liveMempoolOwner: String
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
        configuration: StoreConfiguration,
        store: NodeStore,
        bundles: VolumeBundleCache,
        stores: VolumeStores,
        retentionScope: String,
        durableMempoolOwner: String,
        liveMempoolOwner: String,
        directoryLock: StorageDirectoryLock
    ) {
        self.configuration = configuration
        self.store = store
        self.bundles = bundles
        self.stores = stores
        self.readCache = ReadCache(maximumBytes: configuration.resourcePolicy.maximumCachedContentBytes)
        self.retentionScope = retentionScope
        self.durableMempoolOwner = durableMempoolOwner
        self.liveMempoolOwner = liveMempoolOwner
        self.directoryLock = directoryLock
    }

    /// Completes store validation and settles what the store pins before
    /// returning a storage the runtime may expose.
    public static func open(
        _ configuration: StoreConfiguration
    ) async throws -> NodeStorage {
        let recovered = try await BootRecovery.run(configuration: configuration)
        return NodeStorage(
            configuration: configuration,
            store: recovered.store,
            bundles: VolumeBundleCache(directory: configuration.storagePath),
            stores: recovered.stores,
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

    package func hasExecutedBlock(_ cid: String, at chainPath: [String]) async -> Bool {
        (try? await store.hasExecutedBlock(cid, at: chainPath)) ?? false
    }

    public func fetch(_ cids: Set<String>) async -> [String: Data] {
        await stores.anyChain.fetch(cids)
    }

    /// A block's own node: from its Volume, or from its header record when
    /// its body is not held. Enough to reach the state it commits to.
    package nonisolated func blockNodeBytes(_ cid: String) async -> Data? {
        if let held = await stores.anyChain.fetchDataLocal(cid: cid) { return held }
        return store.headerBlockBytes(cid)
    }

    /// Peer content exchange serves complete local Volumes. Membership is a
    /// storage fact and cannot be reconstructed from an arbitrary CID list.
    ///
    /// What this node sends to others, a peer or a reader, is checked
    /// against its CIDs first: bytes damaged in the store read as absent,
    /// never handed on. This node's own reads (`fetch`) take them unhashed.
    package func volume(_ rootCID: String) async -> SerializedVolume? {
        guard let volume = await stores.anyChain.fetchVolumeLocal(root: rootCID),
              (try? volume.validate()) != nil else { return nil }
        return volume
    }

    /// The public storage fetch port is deliberately local-only. Network
    /// acquisition is explicit and root-scoped at admission/retry boundaries.
    public func fetch(rawCid: String) async throws -> Data {
        try await localFetcher(.anyChain).fetch(rawCid: rawCid)
    }

    public func store(volume: SerializedVolume) async throws {
        try await stores.root.store(volume: volume)
    }

    /// Stores a Volume Cashew serializes from `volume`'s node, which hashes
    /// each entry as it does: the broker does not hash it again.
    private func storeHashed(_ volume: some Volume) async throws {
        let storage = NodeImportStorage(storage: stores.root)
        try await volume.store(storer: storage)
        try await storage.commit()
    }

    @discardableResult
    package func persistLocalTransaction(
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
        try await storeHashed(volume)
        try Task.checkCancellation()
        try await stores.root.retain([volume.rawCID], owner: durableMempoolOwner)
        do {
            try await store.persistLocalMempoolTransaction(
                transactionCID: volume.rawCID,
                addedAt: addedAt
            )
        } catch {
            try await stores.root.release([volume.rawCID], owner: durableMempoolOwner
            )
            throw error
        }
        return volume.rawCID
    }

    /// Keeps an admitted peer transaction serveable for this storage lifetime.
    /// The scope is cleared on restart, so peer gossip never becomes recovery
    /// authority merely because its bytes use the durable broker.
    package func persistPeerTransaction(_ transaction: Transaction) async throws -> String {
        try await acquireMutationOperation()
        defer { releaseOperation() }
        let volume = try VolumeImpl<Transaction>(node: transaction)
        try await storeHashed(volume)
        // Eviction uses the same storage mutation gate, so publishing the
        // complete Volume and its live owner pin is atomic at the node boundary.
        if !livePinnedMempoolRoots.contains(volume.rawCID) {
            try await stores.root.retain([volume.rawCID], owner: liveMempoolOwner)
            livePinnedMempoolRoots.insert(volume.rawCID)
        }
        return volume.rawCID
    }

    /// Owner/count deltas keep live-pool retention O(changes), while startup's
    /// owner reset makes these pins storage-local authority.
    package func updateLiveMempoolRoots(
        adding: Set<String>,
        removing: Set<String>
    ) async throws {
        try await acquireMutationOperation()
        defer { releaseOperation() }
        let added = adding.subtracting(livePinnedMempoolRoots)
        let removed = removing.intersection(livePinnedMempoolRoots)
        if !added.isEmpty {
            try await stores.root.retain(added.sorted(),
                owner: liveMempoolOwner
            )
            livePinnedMempoolRoots.formUnion(added)
        }
        if !removed.isEmpty {
            try await stores.root.release(Set(removed.sorted()), owner: liveMempoolOwner)
            livePinnedMempoolRoots.subtract(removed)
        }
    }

    /// The live pool's pins of the transactions of the chain at `path` go:
    /// its pool went with its level.
    package func releaseLivePool(of path: [String]) async throws {
        var gone: Set<String> = []
        for root in livePinnedMempoolRoots {
            let read = try? await VolumeImpl<Transaction>(rawCID: root).resolveRecursive(source: stores.root)
            if read?.node?.body.node?.chainPath == path { gone.insert(root) }
        }
        try await updateLiveMempoolRoots(adding: [], removing: gone)
    }

    package func removeLocalTransaction(_ transactionCID: String) async throws {
        try await acquireMutationOperation()
        defer { releaseOperation() }
        try await store.removeLocalMempoolTransaction(
            transactionCID: transactionCID
        )
        try await stores.root.release([transactionCID], owner: durableMempoolOwner
        )
    }

    package func localTransactions() async throws -> [DurableLocalTransaction] {
        await acquireOperation()
        defer { releaseOperation() }
        var transactions: [DurableLocalTransaction] = []
        for record in try await store.localMempoolTransactions() {
            let volume = try await VolumeImpl<Transaction>(
                rawCID: record.transactionCID
            ).resolveRecursive(source: stores.root)
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

    package func localTransactionTimestamps() async throws -> [String: Int64] {
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

extension NodeStorage {
    package nonisolated func syncTrace(_ message: @autoclosure () -> String) {
        SyncTrace.log(chain: configuration.chainPath, message())
    }
}
