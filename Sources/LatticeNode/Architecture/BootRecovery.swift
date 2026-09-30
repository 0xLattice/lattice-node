import Foundation
import Lattice
import VolumeBroker
import cashew

/// Boot recovery for one chain process: everything `ChainProcess.open` does
/// before a process exists that networking may expose. The stages run in
/// this order, and the order is load-bearing: the legacy-execution
/// migration reads executed blocks before the validated-tier demotion
/// rewrites that column, and stages its facts before the demotion loop
/// commits (see `migrateLegacyExecutionsAndDemote`).
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
        let runtimePhase: ChainProcess.RuntimePhase
        let bootHoleCeiling: UInt64?
    }

    /// The two stores, and the retention scopes and pin owners derived from
    /// the chain's identity.
    private struct Stores {
        let broker: DiskBroker
        let localFetcher: CoalescingFetcher
        let retentionScope: String
        let issuedHierarchyRetentionScope: String
        let preparedHierarchyRetentionScope: String
        let parentEvidenceInboxRetentionScope: String
        let durableMempoolOwner: String
        let liveMempoolOwner: String
        let contextualCandidateOwner: String
        let store: NodeStore
    }

    static func run(configuration: NodeConfiguration) async throws -> Result {
        let directoryLock = try lockStorageDirectory(configuration: configuration)
        let stores = try openStores(configuration: configuration)
        let constantRoots = try await materializeConstantRoots(stores)
        let staged = try await reconcileRetainedRoots(
            stores,
            constantRoots: constantRoots
        )
        let (migrated, bootDemoted) = try await migrateLegacyExecutionsAndDemote(
            stores,
            staged: staged
        )
        try await pinMempool(stores)
        let runtimePhase = try await restoreRuntimePhase(
            stores,
            configuration: configuration,
            staged: staged,
            migrated: migrated
        )
        // Stage 8: prepared child proofs recovered.
        try await ChainProcess.recoverPreparedChildProofs(
            store: stores.store,
            configuration: configuration
        )
        let bootHoleCeiling = await holeCeiling(
            runtimePhase: runtimePhase,
            bootDemoted: bootDemoted
        )
        return Result(
            store: stores.store,
            broker: stores.broker,
            localFetcher: stores.localFetcher,
            retentionScope: stores.retentionScope,
            durableMempoolOwner: stores.durableMempoolOwner,
            liveMempoolOwner: stores.liveMempoolOwner,
            directoryLock: directoryLock,
            runtimePhase: runtimePhase,
            bootHoleCeiling: bootHoleCeiling
        )
    }

    /// Stage 1: the storage directory and its exclusive lock.
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
        let issuedHierarchyRetentionScope = retentionScope + ":issued-hierarchy"
        let preparedHierarchyRetentionScope = retentionScope + ":prepared-hierarchy"
        let parentEvidenceInboxRetentionScope =
            retentionScope + ":parent-evidence-inbox"
        let durableMempoolOwner = retentionScope + ":durable-mempool"
        let liveMempoolOwner = retentionScope + ":live-mempool"
        let contextualCandidateOwner = retentionScope + ":contextual-candidates"
        let store = try NodeStore(
            databasePath: configuration.storagePath.appendingPathComponent("state.db"),
            nexusGenesisCID: configuration.nexusGenesisCID,
            chainPath: configuration.chainPath,
            recoveryVolumeBroker: broker,
            blockRetentionScope: retentionScope,
            issuedRecoveryRetentionScope: issuedHierarchyRetentionScope,
            preparedRecoveryRetentionScope: preparedHierarchyRetentionScope,
            parentEvidenceInboxRetentionScope:
                parentEvidenceInboxRetentionScope,
            parentEvidenceInboxCapacity:
                configuration.resourcePolicy.maximumPendingParentEvidence,
            contextualCandidateOwner: contextualCandidateOwner,
            handoffCandidateCapacity:
                configuration.resourcePolicy.maximumRetainedHandoffCandidates
        )
        return Stores(
            broker: broker,
            localFetcher: localFetcher,
            retentionScope: retentionScope,
            issuedHierarchyRetentionScope: issuedHierarchyRetentionScope,
            preparedHierarchyRetentionScope: preparedHierarchyRetentionScope,
            parentEvidenceInboxRetentionScope: parentEvidenceInboxRetentionScope,
            durableMempoolOwner: durableMempoolOwner,
            liveMempoolOwner: liveMempoolOwner,
            contextualCandidateOwner: contextualCandidateOwner,
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

    /// Stage 4: the staged admission log, audited, and every retained root
    /// reconciled against it.
    private static func reconcileRetainedRoots(
        _ stores: Stores,
        constantRoots: [String]
    ) async throws -> [StagedImport] {
        let broker = stores.broker
        let store = stores.store
        let retentionScope = stores.retentionScope
        let issuedHierarchyRetentionScope = stores.issuedHierarchyRetentionScope
        let preparedHierarchyRetentionScope = stores.preparedHierarchyRetentionScope
        let parentEvidenceInboxRetentionScope = stores.parentEvidenceInboxRetentionScope
        let contextualCandidateOwner = stores.contextualCandidateOwner
        let staged = try await store.stagedImports()
        try await store.auditNormalizedIndexes()
        try await store.pruneAdmittedContextualCandidates()
        try await store.enforceHandoffCandidateBudget()
        let retainedRoots = durableProtectedRoots(
            staged: staged,
            additionalRoots: constantRoots
        )
        let issuedRecoveryRoots = try await store.issuedRecoveryVolumeRoots()
        let preparedRecoveryRoots = try await store.preparedRecoveryVolumeRoots()
        let parentEvidenceInboxRoots = try await store
            .parentEvidenceInboxRoots()
        let contextualCandidateRoots = try await store
            .contextualCandidateVolumeRoots()
        for root in Set(
            retainedRoots + issuedRecoveryRoots + preparedRecoveryRoots
                + parentEvidenceInboxRoots + contextualCandidateRoots
        ) {
            guard await broker.fetchVolumeLocal(root: root) != nil else {
                throw ChainProcessError.missingMaterializedVolume(root)
            }
        }
        try await broker.advanceRetainedRoots(
            scope: issuedHierarchyRetentionScope,
            roots: issuedRecoveryRoots
        )
        // Startup is quiescent under the storage-directory lock, so stale
        // counts can be replaced before any local garbage-collection pass.
        try await broker.unpinAll(owner: contextualCandidateOwner)
        try await broker.pinBatch(
            roots: contextualCandidateRoots,
            owner: contextualCandidateOwner
        )
        // Pins stand in for the reachability GC planned in P4, which
        // replaces them. Only an index update a crash interrupted leaves
        // them out of step: re-pin what the committed root reaches.
        if try await store.childEvidencePinsDirty() {
            let childEvidenceOwner = await store.childEvidenceOwner
            try await broker.unpinAll(owner: childEvidenceOwner)
            var missing: [String] = []
            if let childEvidenceRoot = try await store.childEvidenceRoot() {
                let volumes = await ChildEvidenceIndex.volumes(
                    root: childEvidenceRoot,
                    fetcher: broker
                )
                try await broker.pinBatch(
                    roots: volumes.reachable,
                    owner: childEvidenceOwner
                )
                missing = volumes.missing
            }
            if missing.isEmpty {
                try await store.setChildEvidencePinsDirty(false)
            } else {
                // The marker stays set: the next boot tries again.
                store.syncTrace(
                    "error: child-evidence reconcile: \(missing.count) index "
                        + "Volumes missing, pinned what is reachable"
                )
            }
        }
        try await broker.advanceRetainedRoots(
            scope: preparedHierarchyRetentionScope,
            roots: preparedRecoveryRoots
        )
        try await broker.advanceRetainedRoots(
            scope: parentEvidenceInboxRetentionScope,
            roots: parentEvidenceInboxRoots
        )
        try await broker.advanceRetainedRoots(
            scope: retentionScope,
            roots: retainedRoots
        )
        return staged
    }

    /// Stage 5: the legacy-execution migration, then the validated-tier
    /// demotion. Returns the migrated validation batches (replayed with the
    /// log) and the blocks this boot demoted.
    private static func migrateLegacyExecutionsAndDemote(
        _ stores: Stores,
        staged: [StagedImport]
    ) async throws -> (migrated: [BlockImportBatch], bootDemoted: [String]) {
        let broker = stores.broker
        let store = stores.store
        let retentionScope = stores.retentionScope
        // Walk-validated tier invariant: a block is marked `2` iff its body +
        // post-state are pinned under its owner. Owner pins persist in
        // volumes.db (unlike the batch-rebuilt scope above). A marker whose
        // pin is gone is demoted to weighed so the walk re-validates it; a pin
        // whose marker never flipped (crash between pin and flip) is released.
        // Read BEFORE the demotion below rewrites this column. Demotion is
        // retention bookkeeping — it says a cached post-state may be evicted,
        // not that the transition never ran — so an execution demoted on this
        // boot must still be carried across.
        let executedBeforeDemotion = try await store.executedBlockCIDs()
        // Admission batches are the only recovery authority. The projection is
        // a derived cache and must not be able to add facts or prevent a valid
        // history from reopening.
        //
        // The one exception is history written before durable validation facts
        // existed: those rows record executions this store really performed,
        // and replaying without them would come back having forgotten every one
        // — leaving the chain unable to attest any state it produced, so no
        // child could anchor and no child could advance.
        //
        // They are STAGED, not merely replayed. Replaying alone would leave the
        // mutable tier column as the only record of those executions forever,
        // and demotion sets it to zero — so a demote would erase an execution
        // that actually happened, permanently. Staging makes this a one-time
        // migration after which the immutable fact is the authority, matching
        // every execution recorded from here on.
        //
        // Staged BEFORE the demotion loop below, not merely read before it.
        // Demotion commits per block while this writes its own transactions, so
        // a crash in between would leave a legacy row demoted to `.weighed`
        // with no durable fact — `executedBlockCIDs()` would never return it
        // again and no later boot could carry it. Ordering the writes closes
        // that window; the migration needs nothing the demotion produces.
        let carriedFacts = Set(staged.flatMap { admission in
            admission.batch.facts.compactMap { fact -> String? in
                guard case .validation(let value) = fact else { return nil }
                return value.blockHash
            }
        })
        // Only blocks this log actually admitted: a validation naming a block
        // absent from the replayed facts would defer forever and turn a boot
        // into `corruptConsensusGraph`.
        let admittedBlocks = Set(staged.flatMap { admission in
            admission.batch.facts.compactMap { fact -> String? in
                guard case .block(let value) = fact else { return nil }
                return value.blockHash
            }
        })
        let migrated = executedBeforeDemotion
            .intersection(admittedBlocks)
            .subtracting(carriedFacts)
            .sorted()
            .map { BlockImportBatch.validation(blockHash: $0) }
        for batch in migrated {
            try await store.stage(batch, volumeRoots: [])
        }
        let walkValidated = try await store.executedAndPinnedBlockCIDs()
        let validatedOwnerPrefix = ChainProcess.validatedOwnerPrefix(retentionScope)
        let pinnedOwners = Set(
            await broker.pinnedOwners(prefix: validatedOwnerPrefix)
        )
        var bootDemoted: [String] = []
        for blockCID in walkValidated.sorted()
        where !pinnedOwners.contains(
            ChainProcess.validatedOwner(retentionScope, blockCID)
        ) {
            try await store.demoteValidated(blockCID: blockCID)
            bootDemoted.append(blockCID)
        }
        for owner in pinnedOwners.sorted()
        where !walkValidated.contains(
            String(owner.dropFirst(validatedOwnerPrefix.count))
        ) {
            try await broker.unpinAll(owner: owner)
        }
        return (migrated, bootDemoted)
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
        try await broker.unpinAll(owner: durableMempoolOwner)
        try await broker.pinBatch(
            roots: localMempoolRoots,
            owner: durableMempoolOwner
        )
        // The live pool is operational cache, not restart authority. Owner
        // pins support O(changes) updates and are cleared for each process.
        try await broker.unpinAll(owner: liveMempoolOwner)
    }

    /// Stage 7: the runtime phase — Nexus genesis bootstrapped on an empty
    /// log, otherwise the chain restored by replaying the log and the
    /// migration.
    private static func restoreRuntimePhase(
        _ stores: Stores,
        configuration: NodeConfiguration,
        staged: [StagedImport],
        migrated: [BlockImportBatch]
    ) async throws -> ChainProcess.RuntimePhase {
        let broker = stores.broker
        let localFetcher = stores.localFetcher
        let store = stores.store
        let retentionScope = stores.retentionScope
        let context = try configuration.runtimeContext
        let runtimePhase: ChainProcess.RuntimePhase
        if staged.isEmpty {
            if configuration.address.isNexus {
                let genesis = try await NexusGenesis.create(fetcher: localFetcher)
                guard try NexusGenesis.verifyGenesis(genesis) else {
                    throw ChainProcessError.invalidNexusGenesis
                }
                let importStorage = NodeImportStorage(
                    storage: broker
                )
                let bootstrapped = try await ChainLevel.bootstrap(
                    context: context,
                    genesisHeader: try BlockHeader(node: genesis.block),
                    fetcher: localFetcher,
                    validationContentStorer: importStorage,
                    materializedVolumeStorer: importStorage,
                    stage: { context in
                        let hierarchyArtifacts = context.issuedCarrierLink.map {
                            ImportHierarchyArtifacts(
                                carrierLink: $0,
                                carrierEvidence: nil,
                                parentGenesisLinks: context.parentGenesisLinks
                            )
                        }
                        try await ChainProcess.persist(
                            context.batch,
                            importStorage: importStorage,
                            store: store,
                            broker: broker,
                            retentionScope: retentionScope,
                            persistence: ImportPersistence(
                                pendingChildProofCapacity: ChainProcess.preparedChildProofCapacity,
                                hierarchyArtifacts: hierarchyArtifacts
                            )
                        )
                    }
                )
                runtimePhase = .active(bootstrapped.level)
            } else {
                runtimePhase = .awaitingGenesis
            }
        } else {
            if configuration.address.isNexus {
                let genesisRoots = Set(staged.flatMap { admission in
                    admission.batch.facts.compactMap { fact -> String? in
                        guard case .block(let block) = fact,
                              block.parentBlockHash == nil,
                              block.blockHeight == 0 else { return nil }
                        return block.blockHash
                    }
                })
                guard genesisRoots == [NexusGenesis.expectedBlockHash] else {
                    throw ChainProcessError.invalidNexusGenesis
                }
            }
            // The legacy-execution migration was staged before the boot
            // demotion above; replay it alongside the durable log.
            let batches = staged.map(\.batch) + migrated
            let chain = try await ChainState.restore(
                replaying: batches,
                revisionFloor: try await store.consensusRevisionFloor()
            )
            let level = ChainLevel(chain: chain, context: context)
            runtimePhase = .active(level)
        }
        return runtimePhase
    }

    /// Stage 9: the hole ceiling seeded from the blocks this boot demoted.
    private static func holeCeiling(
        runtimePhase: ChainProcess.RuntimePhase,
        bootDemoted: [String]
    ) async -> UInt64? {
        // A block boot reconciliation demoted can later reorg onto the main
        // chain beneath still-validated blocks: seed the probe's hole
        // ceiling with the highest such height (see `demotedHoleCeiling`).
        var bootHoleCeiling: UInt64?
        if case .active(let level) = runtimePhase {
            for blockCID in bootDemoted {
                guard let height = await level.chain
                    .getConsensusBlock(hash: blockCID)?.blockHeight
                else { continue }
                bootHoleCeiling = max(bootHoleCeiling ?? height, height)
            }
        }
        return bootHoleCeiling
    }

    private nonisolated static func durableProtectedRoots(
        staged: [StagedImport],
        additionalRoots: [String] = []
    ) -> [String] {
        var roots = Set(staged.flatMap(\.volumeRoots))
        roots.formUnion(additionalRoots)
        return roots.sorted()
    }
}
