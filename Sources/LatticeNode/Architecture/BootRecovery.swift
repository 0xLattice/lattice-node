import Foundation
import Lattice
import VolumeBroker
import cashew

/// Boot recovery for one chain's storage: everything `ChainProcess.open`
/// does before the driver starts. Content is retained before the facts that
/// reference it, so boot only re-asserts the retained roots the journal
/// names; an empty journal is seeded with the configured Nexus genesis.
enum BootRecovery {
    /// What `ChainProcess.open` builds the process from.
    struct Result {
        let store: NodeStore
        let broker: DiskBroker
        let localFetcher: CoalescingFetcher
        let retentionScope: String
        let durableMempoolOwner: String
        let liveMempoolOwner: String
        let directoryLock: StorageDirectoryLock
    }

    /// The two stores, and the retention scopes derived from the chain's
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
        let constantRoots = try await materializeConstantRoots(stores)
        try await reconcileRetainedRoots(
            stores, constantRoots: constantRoots, levels: Array(CoreDriver.levelStores(configuration).values)
        )
        try await pinMempool(stores)
        try await seedNexusGenesis(stores, configuration: configuration)
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
            throw ChainProcessError.invalidStoragePath
        }
        try FileManager.default.createDirectory(
            at: configuration.storagePath,
            withIntermediateDirectories: true
        )
        let directoryLock: StorageDirectoryLock
        do {
            directoryLock = try StorageDirectoryLock(directory: configuration.storagePath)
        } catch StorageDirectoryLockError.alreadyLocked {
            throw ChainProcessError.storageInUse
        } catch {
            throw ChainProcessError.storageUnavailable
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
            nexusGenesisCID: configuration.nexusGenesisCID,
            chainPath: configuration.chainPath
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

    /// Stage 3: the protocol-constant roots.
    private static func materializeConstantRoots(
        _ stores: Stores
    ) async throws -> [String] {
        let broker = stores.broker
        // Protocol constants are ordinary Volumes and therefore ordinary GC
        // roots. Materialize them before the one exact startup reconciliation.
        let constantStorage = NodeImportStorage(storage: broker)
        try await LatticeState.emptyHeader.storeRecursively(
            storer: constantStorage as any VolumeStorer
        )
        let constantRoots = await constantStorage.takeStoredVolumeRoots()
        return constantRoots
    }

    /// Stage 4: the journal audited, and the chain's retained roots set to
    /// exactly what its facts name.
    private static func reconcileRetainedRoots(
        _ stores: Stores,
        constantRoots: [String],
        levels: [NodeStore]
    ) async throws {
        var staged = try await stores.store.stagedImports()
        try await stores.store.auditNormalizedIndexes()
        // Hosted child levels share the scope: their journals' roots too.
        for level in levels {
            staged += try await level.stagedImports()
            try await level.auditNormalizedIndexes()
        }
        let roots = Set(staged.flatMap(\.volumeRoots)).union(constantRoots).sorted()
        for root in roots {
            guard await stores.broker.fetchVolumeLocal(root: root) != nil else {
                throw ChainProcessError.missingMaterializedVolume(root)
            }
        }
        try await stores.broker.advanceRetainedRoots(scope: stores.retentionScope, roots: roots)
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
                throw ChainProcessError.missingMaterializedVolume(root)
            }
        }
        try await broker.advanceRetainedRoots(
            scope: durableMempoolOwner, roots: localMempoolRoots
        )
        // The live pool is operational cache, not restart authority. Owner
        // pins support O(changes) updates and are cleared for each process.
        try await broker.advanceRetainedRoots(scope: liveMempoolOwner, roots: [])
    }

    /// Stage 7: an empty journal starts from the configured Nexus genesis:
    /// its content stored and retained, then its executed batch journaled.
    private static func seedNexusGenesis(
        _ stores: Stores,
        configuration: NodeConfiguration
    ) async throws {
        guard try await stores.store.stagedImports().isEmpty else { return }
        let genesis = try await NexusGenesis.create(fetcher: stores.localFetcher)
        guard try NexusGenesis.verifyGenesis(genesis) else {
            throw ChainProcessError.invalidNexusGenesis
        }
        let header = try BlockHeader(node: genesis.block)
        // Content first: bootstrap resolves the genesis's spec, children and
        // body from the store.
        let storage = NodeImportStorage(storage: stores.broker)
        try await header.storeBlock(fetcher: stores.localFetcher, storer: storage)
        let booted = await ChainTree.bootstrap(
            genesis: header,
            fetcher: stores.localFetcher,
            context: try configuration.runtimeContext
        )
        guard case .success(let boot) = booted else {
            throw ChainProcessError.invalidNexusGenesis
        }
        if let state = boot.materializedPostState {
            try await ChainProcess.storeExecutedState(state, in: storage)
        }
        let roots = await storage.takeStoredVolumeRoots()
        try await stores.broker.mergeRetainedRoots(scope: stores.retentionScope, roots: roots)
        try await stores.store.stageCoreFacts(
            [boot.facts], volumeRoots: roots, logID: UUID().uuidString.lowercased()
        )
    }
}
