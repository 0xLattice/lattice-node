import Foundation
import Lattice
import VolumeBroker
import cashew

public enum ChainProcessError: Error, Equatable, Sendable {
    case invalidStoragePath
    case storageInUse
    case storageUnavailable
    case invalidNexusGenesis
    case missingMaterializedVolume(String)
}

public enum ChainProcessPhase: String, Sendable {
    case awaitingGenesis
    case active
}

public struct ChainProcessStatus: Sendable, Equatable {
    public let phase: ChainProcessPhase
    public let chainPath: [String]
    public let nexusGenesisCID: String
    public let tipCID: String?
    public let height: UInt64?
    public let revision: UInt64?
}


struct DurableLocalTransaction: Sendable {
    let transactionCID: String
    let addedAt: Int64
    let transaction: Transaction
}

/// The core driver's local storage for one chain: the fact journal
/// (state.db), the Volume store and the local mempool journal, opened and
/// reconciled at boot. It decides nothing; the core does.
public actor ChainProcess: ContentSource, Fetcher, VolumeStorer {
    public nonisolated let configuration: NodeConfiguration

    let store: NodeStore
    let broker: DiskBroker
    let localFetcher: CoalescingFetcher
    let retentionScope: String
    private let durableMempoolOwner: String
    private let liveMempoolOwner: String
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
        broker: DiskBroker,
        localFetcher: CoalescingFetcher,
        retentionScope: String,
        durableMempoolOwner: String,
        liveMempoolOwner: String,
        directoryLock: StorageDirectoryLock
    ) {
        self.configuration = configuration
        self.store = store
        self.broker = broker
        self.localFetcher = localFetcher
        self.retentionScope = retentionScope
        self.durableMempoolOwner = durableMempoolOwner
        self.liveMempoolOwner = liveMempoolOwner
        self.directoryLock = directoryLock
    }

    /// Completes store validation and retained-root reconciliation before
    /// returning a process the driver may expose.
    public static func open(
        configuration: NodeConfiguration
    ) async throws -> ChainProcess {
        let recovered = try await BootRecovery.run(configuration: configuration)
        return ChainProcess(
            configuration: configuration,
            store: recovered.store,
            broker: recovered.broker,
            localFetcher: recovered.localFetcher,
            retentionScope: recovered.retentionScope,
            durableMempoolOwner: recovered.durableMempoolOwner,
            liveMempoolOwner: recovered.liveMempoolOwner,
            directoryLock: recovered.directoryLock
        )
    }

    /// Same-chain content serving reads only this process's durable local tiers.
    public func content(_ cids: Set<String>) async -> [String: Data] {
        await fetch(cids)
    }

    /// Ungated: whether `cid` is a durably accepted block. Public read RPC uses
    /// this as the canonical-data gate before serving decoded block content.
    public func hasAcceptedBlock(_ cid: String) async -> Bool {
        (try? await store.hasAcceptedBlock(cid)) ?? false
    }

    public func fetch(_ cids: Set<String>) async -> [String: Data] {
        await broker.fetchDataLocal(cids: cids)
    }

    /// Peer content exchange serves complete local Volumes. Membership is a
    /// storage fact and cannot be reconstructed from an arbitrary CID list.
    func volume(_ rootCID: String) async -> SerializedVolume? {
        await broker.fetchVolumeLocal(root: rootCID)
    }

    /// The public process fetch port is deliberately local-only. Network
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

    /// Keeps an admitted peer transaction serveable for this process lifetime.
    /// The scope is cleared on restart, so peer gossip never becomes recovery
    /// authority merely because its bytes use the durable broker.
    func persistPeerTransaction(_ transaction: Transaction) async throws -> String {
        try await acquireMutationOperation()
        defer { releaseOperation() }
        let volume = try VolumeImpl<Transaction>(node: transaction)
        try await volume.store(storer: broker)
        // Eviction uses the same process mutation gate, so publishing the
        // complete Volume and its live owner pin is atomic at the node boundary.
        if !livePinnedMempoolRoots.contains(volume.rawCID) {
            try await broker.retain([volume.rawCID], owner: liveMempoolOwner)
            livePinnedMempoolRoots.insert(volume.rawCID)
        }
        return volume.rawCID
    }

    /// Owner/count deltas keep live-pool retention O(changes), while startup's
    /// owner reset makes these pins process-local authority.
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
                throw ChainProcessError.missingMaterializedVolume(
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
