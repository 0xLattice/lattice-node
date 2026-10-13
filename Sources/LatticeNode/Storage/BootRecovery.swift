import Foundation
import Lattice
import VolumeBroker
import cashew

/// Boot recovery for one hosted tree's storage: everything `NodeStorage.open`
/// does before the runtime starts. Content is retained before the facts that
/// reference it, so boot only re-asserts the retained roots the journal
/// names; an empty journal is seeded with the configured Nexus genesis.
enum BootRecovery {
    /// What `NodeStorage.open` builds the storage from.
    struct Result {
        let store: NodeStore
        let broker: DiskBroker
        let localFetcher: CoalescingFetcher
        let retentionScope: String
        let durableMempoolOwner: String
        let liveMempoolOwner: String
        let directoryLock: StorageDirectoryLock
    }

    /// The two stores, and the retention scopes derived from the tree's
    /// identity.
    private struct Stores {
        let broker: DiskBroker
        let localFetcher: CoalescingFetcher
        let retentionScope: String
        let durableMempoolOwner: String
        let liveMempoolOwner: String
        let store: NodeStore
    }

    static func run(configuration: NodeConfiguration) async throws -> Result {
        let directoryLock = try lockStorageDirectory(configuration: configuration)
        let stores = try openStores(configuration: configuration)
        let constantRoots = try await materializeConstantRoots(stores, configuration: configuration)
        try await settleRetention(stores, constantRoots: constantRoots)
        try await pinMempool(stores)
        try await seedNexusGenesis(stores, configuration: configuration)
        // Content stays only because a scope names it. What none does (a
        // write a crash cut short, a pool entry of the last run) goes now,
        // while nothing is being stored.
        try await stores.broker.sweep()
        return Result(
            store: stores.store,
            broker: stores.broker,
            localFetcher: stores.localFetcher,
            retentionScope: stores.retentionScope,
            durableMempoolOwner: stores.durableMempoolOwner,
            liveMempoolOwner: stores.liveMempoolOwner,
            directoryLock: directoryLock
        )
    }

    private static func lockStorageDirectory(
        configuration: NodeConfiguration
    ) throws -> StorageDirectoryLock {
        guard configuration.storagePath.isFileURL else {
            throw NodeStorageError.invalidStoragePath
        }
        try FileManager.default.createDirectory(
            at: configuration.storagePath,
            withIntermediateDirectories: true
        )
        let directoryLock: StorageDirectoryLock
        do {
            directoryLock = try StorageDirectoryLock(directory: configuration.storagePath)
        } catch StorageDirectoryLockError.alreadyLocked {
            throw NodeStorageError.storageInUse
        } catch {
            throw NodeStorageError.storageUnavailable
        }
        return directoryLock
    }

    /// Stage 2: volumes.db, state.db, and the scopes and owners they use.
    private static func openStores(
        configuration: NodeConfiguration
    ) throws -> Stores {
        let broker = try DiskBroker(
            path: configuration.storagePath.appendingPathComponent("volumes.db").path
        )
        let localFetcher = CoalescingFetcher(broker)
        let retentionScope = [
            configuration.nexusGenesisCID,
            configuration.address.key,
        ].joined(separator: ":")
        let durableMempoolOwner = retentionScope + ":durable-mempool"
        let liveMempoolOwner = retentionScope + ":live-mempool"
        let store = try NodeStore(
            databasePath: configuration.storagePath.appendingPathComponent("state.db"),
            nexusGenesisCID: configuration.nexusGenesisCID
        )
        return Stores(
            broker: broker,
            localFetcher: localFetcher,
            retentionScope: retentionScope,
            durableMempoolOwner: durableMempoolOwner,
            liveMempoolOwner: liveMempoolOwner,
            store: store
        )
    }

    /// Stage 3: the protocol-constant roots, and the operator's policy
    /// modules beside them.
    private static func materializeConstantRoots(
        _ stores: Stores,
        configuration: NodeConfiguration
    ) async throws -> [String] {
        let broker = stores.broker
        // Protocol constants are ordinary Volumes and therefore ordinary GC
        // roots. Materialize them before the one exact startup reconciliation.
        let constantStorage = NodeImportStorage(storage: broker)
        try await LatticeState.emptyHeader.storeRecursively(
            storer: constantStorage as any VolumeStorer
        )
        // A hosted child's genesis names its policy modules by CID, and
        // storing that genesis resolves each from this store.
        for bytes in configuration.policyModules {
            try await WasmPolicyModuleHeader(node: WasmPolicyModule(bytes: bytes))
                .store(storer: constantStorage)
        }
        try await constantStorage.commit()
        let constantRoots = await constantStorage.takeStoredVolumeRoots()
        return constantRoots
    }

    /// Stage 4: the journal audited and the pins settled. Pins are in the
    /// store and stay as a start finds them: nothing is rebuilt from the
    /// journal, and content a fact names and the store lacks is no fault.
    /// The constants are pinned, and a block this node built is given its
    /// body's name if a fact records it and let go of if none does.
    private static func settleRetention(
        _ stores: Stores,
        constantRoots: [String]
    ) async throws {
        try await stores.store.auditNormalizedIndexes()
        let broker = stores.broker
        let scopes = RetentionScopes(chain: stores.retentionScope)
        try await broker.mergeRetainedRoots(scope: scopes.chain, roots: constantRoots)
        for scope in try await broker.retainedScopes(prefix: scopes.builtPrefix) {
            let blockCID = String(scope.dropFirst(scopes.builtPrefix.count))
            let roots = try await broker.retainedRoots(scope: scope)
            if try await stores.store.recordsBlock(blockCID) {
                try await broker.mergeRetainedRoots(scope: scopes.body(blockCID), roots: roots)
            }
            try await broker.releaseRetainedRoots(scope: scope, roots: roots)
        }
    }

    /// Stage 6: the durable mempool's pins rebuilt, the live pool's cleared.
    private static func pinMempool(_ stores: Stores) async throws {
        let broker = stores.broker
        let store = stores.store
        let durableMempoolOwner = stores.durableMempoolOwner
        let liveMempoolOwner = stores.liveMempoolOwner
        let localMempoolRoots = try await store.localMempoolTransactions()
            .map(\.transactionCID)
        for root in localMempoolRoots {
            guard await broker.fetchVolumeLocal(root: root) != nil,
                  let resolved = try? await VolumeImpl<Transaction>(
                    rawCID: root
                  ).resolveRecursive(source: broker),
                  resolved.node != nil else {
                throw NodeStorageError.missingMaterializedVolume(root)
            }
        }
        try await broker.advanceRetainedRoots(
            scope: durableMempoolOwner, roots: localMempoolRoots
        )
        // The live pool is operational cache, not restart authority. Owner
        // pins support O(changes) updates and are cleared for each storage.
        try await broker.advanceRetainedRoots(scope: liveMempoolOwner, roots: [])
    }

    /// Stage 7: the configured Nexus genesis, whole: its content stored and
    /// retained whenever the store lacks its block, and for an empty journal
    /// its executed batch journaled. Every node holds it; nothing later can
    /// supply its block's own node, which has no header record.
    private static func seedNexusGenesis(
        _ stores: Stores,
        configuration: NodeConfiguration
    ) async throws {
        let seeded = try await !stores.store.stagedImports().isEmpty
        if seeded, await stores.broker.hasVolume(root: configuration.nexusGenesisCID) { return }
        let genesis = try await NexusGenesis.create(fetcher: stores.localFetcher)
        guard try NexusGenesis.verifyGenesis(genesis) else {
            throw NodeStorageError.invalidNexusGenesis
        }
        let header = try BlockHeader(node: genesis.block)
        // Content first: bootstrap resolves the genesis's spec, children and
        // body from the store.
        let storage = NodeImportStorage(storage: stores.broker)
        try await header.storeBlock(fetcher: stores.localFetcher, storer: storage)
        try await storage.commit()
        let booted = await ChainTree.bootstrap(
            genesis: header,
            fetcher: stores.localFetcher,
            context: try configuration.runtimeContext
        )
        guard case .success(let boot) = booted else {
            throw NodeStorageError.invalidNexusGenesis
        }
        if let state = boot.materializedPostState {
            try await NodeStorage.storeExecutedState(state, in: storage)
        }
        try await storage.commit()
        let roots = await storage.takeStoredVolumeRoots()
        try await stores.broker.mergeRetainedRoots(scope: stores.retentionScope, roots: roots)
        guard !seeded else { return }
        try await stores.store.stageChainFacts(
            [boot.facts], volumeRoots: roots, logID: UUID().uuidString.lowercased()
        )
    }
}
