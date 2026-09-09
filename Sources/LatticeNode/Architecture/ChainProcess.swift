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
    case chainNotBootstrapped
    case unresolvedCanonicalTip(String)
    case malformedAuthenticatedChildProof
    case consensusRevisionExhausted
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

/// The result must be routed immediately when `parentCarrierLink` is present;
/// the link is authenticated evidence, not local consensus state.
public struct NodeAdmissionOutcome: Sendable {
    public let decision: NodeAdmissionDecision
    public let parentCarrierLink: ParentCarrierLink?
    public let sameChainPredecessor: SameChainPredecessorRequirement?
    let canonicalCommitReceipt: CanonicalCommitReceipt?

    init(
        decision: NodeAdmissionDecision,
        parentCarrierLink: ParentCarrierLink?,
        sameChainPredecessor: SameChainPredecessorRequirement?,
        canonicalCommitReceipt: CanonicalCommitReceipt? = nil
    ) {
        self.decision = decision
        self.parentCarrierLink = parentCarrierLink
        self.sameChainPredecessor = sameChainPredecessor
        self.canonicalCommitReceipt = canonicalCommitReceipt
    }
}

/// A one-shot completion token for source-ordered canonical reconciliation.
/// It is intentionally independent of actor lifetime so callers can release
/// their own operation gate before waiting for the queued reconciliation.
actor CanonicalCommitReceipt {
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init() {}

    func wait() async {
        await withCheckedContinuation { continuation in
            if finished {
                continuation.resume()
                return
            }
            waiters.append(continuation)
        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

/// Receives each mutation commit while `ChainProcess` still owns its operation
/// order. Implementations must enqueue and return; reconciliation belongs to a
/// separate worker so it cannot re-enter the process operation.
typealias CanonicalCommitPublisher = @Sendable (ChainCommit) async
    -> CanonicalCommitReceipt

struct DurableDirectChildProof: Sendable {
    let directory: String
    let childCID: String
    let proof: ChildBlockProof
}

struct DurableLocalTransaction: Sendable {
    let transactionCID: String
    let addedAt: Int64
    let transaction: Transaction
}

/// One process owns one absolute chain path. Child processes have an explicit
/// pre-genesis phase so target-miss carriers can relay deeper accepted work
/// without inventing local chain state.
public actor ChainProcess: ContentSource, Fetcher, VolumeStorer {
    private enum RuntimePhase: Sendable {
        case awaitingGenesis
        case active(ChainLevel)
    }

    private enum TargetedChildProofResolution: Sendable {
        case absent
        case prepared(PreparedChildProof)
        case unavailable
    }

    private static let maximumDirectChildRoutes = 64
    private static let preparedChildProofCapacity = 16

    /// Owner pins holding a walk-validated block's body + post-state, one
    /// owner per block: `<retentionScope>:validated:<blockCID>`.
    private nonisolated static func validatedOwnerPrefix(
        _ retentionScope: String
    ) -> String {
        retentionScope + ":validated:"
    }

    private nonisolated static func validatedOwner(
        _ retentionScope: String,
        _ blockCID: String
    ) -> String {
        validatedOwnerPrefix(retentionScope) + blockCID
    }

    public nonisolated let configuration: NodeConfiguration

    private let store: NodeStore
    private let broker: DiskBroker
    private let localFetcher: CoalescingFetcher
    private let retentionScope: String
    private let durableMempoolOwner: String
    private let liveMempoolOwner: String
    private let childIntentRetentionScope: String
    private let directoryLock: StorageDirectoryLock
    private var runtimePhase: RuntimePhase
    private var livePinnedMempoolRoots = Set<String>()

    // Actors are reentrant. This queue keeps admission and eviction in one
    // durability order across their suspension points.
    private struct OperationWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var operationInFlight = false
    private var operationWaiters: [OperationWaiter] = []
#if DEBUG
    private var operationWaiterChangeWaiters: [CheckedContinuation<Void, Never>] = []
#endif

    private init(
        configuration: NodeConfiguration,
        store: NodeStore,
        broker: DiskBroker,
        localFetcher: CoalescingFetcher,
        retentionScope: String,
        durableMempoolOwner: String,
        liveMempoolOwner: String,
        childIntentRetentionScope: String,
        directoryLock: StorageDirectoryLock,
        runtimePhase: RuntimePhase
    ) {
        self.configuration = configuration
        self.store = store
        self.broker = broker
        self.localFetcher = localFetcher
        self.retentionScope = retentionScope
        self.durableMempoolOwner = durableMempoolOwner
        self.liveMempoolOwner = liveMempoolOwner
        self.childIntentRetentionScope = childIntentRetentionScope
        self.directoryLock = directoryLock
        self.runtimePhase = runtimePhase
    }

    /// Completes store validation, retained-root reconciliation, and recovery
    /// before returning a process that networking may expose.
    public static func open(
        configuration: NodeConfiguration
    ) async throws -> ChainProcess {
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
        let childIntentRetentionScope = retentionScope + ":child-intents"
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

        // Protocol constants are ordinary Volumes and therefore ordinary GC
        // roots. Materialize them before the one exact startup reconciliation.
        let constantStorage = NodeAdmissionStorage(storage: broker)
        try await LatticeState.emptyHeader.storeRecursively(
            storer: constantStorage as any VolumeStorer
        )
        let constantRoots = await constantStorage.takeStoredVolumeRoots()

        let staged = try await store.stagedAdmissions()
        try await store.auditNormalizedIndexes()
        try await store.pruneAdmittedContextualCandidates()
        try await store.enforceHandoffCandidateBudget()
        let retainedRoots = durableRetainedRoots(
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
        // Walk-validated tier invariant: a block is marked `2` iff its body +
        // post-state are pinned under its owner. Owner pins persist in
        // volumes.db (unlike the batch-rebuilt scope above). A marker whose
        // pin is gone is demoted to weighed so the walk re-validates it; a pin
        // whose marker never flipped (crash between pin and flip) is released.
        let walkValidated = try await store.walkValidatedBlockCIDs()
        let validatedOwnerPrefix = Self.validatedOwnerPrefix(retentionScope)
        let pinnedOwners = Set(
            await broker.pinnedOwners(prefix: validatedOwnerPrefix)
        )
        for blockCID in walkValidated.sorted()
        where !pinnedOwners.contains(
            Self.validatedOwner(retentionScope, blockCID)
        ) {
            try await store.demoteValidated(blockCID: blockCID)
        }
        for owner in pinnedOwners.sorted()
        where !walkValidated.contains(
            String(owner.dropFirst(validatedOwnerPrefix.count))
        ) {
            try await broker.unpinAll(owner: owner)
        }
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
        try await broker.advanceRetainedRoots(
            scope: childIntentRetentionScope,
            roots: []
        )

        let context = try configuration.runtimeContext
        let runtimePhase: RuntimePhase
        if staged.isEmpty {
            if configuration.address.isNexus {
                let genesis = try await NexusGenesis.create(fetcher: localFetcher)
                guard try NexusGenesis.verifyGenesis(genesis) else {
                    throw ChainProcessError.invalidNexusGenesis
                }
                let admissionStorage = NodeAdmissionStorage(
                    storage: broker
                )
                let bootstrapped = try await ChainLevel.bootstrap(
                    context: context,
                    genesisHeader: try BlockHeader(node: genesis.block),
                    fetcher: localFetcher,
                    validationContentStorer: admissionStorage,
                    materializedVolumeStorer: admissionStorage,
                    stage: { context in
                        let hierarchyArtifacts = context.issuedCarrierLink.map {
                            AdmissionHierarchyArtifacts(
                                carrierLink: $0,
                                carrierEvidence: nil,
                                parentGenesisLinks: context.parentGenesisLinks
                            )
                        }
                        try await persist(
                            context.batch,
                            admissionStorage: admissionStorage,
                            store: store,
                            broker: broker,
                            retentionScope: retentionScope,
                            pendingChildProofRoutes: [],
                            pendingChildProofCapacity: Self.preparedChildProofCapacity,
                            hierarchyArtifacts: hierarchyArtifacts
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
            let batches = staged.map(\.batch)
            // Admission batches are the only recovery authority. The
            // projection is a derived cache and must not be able to add facts
            // or prevent a valid history from reopening.
            let chain = try await ChainState.restore(
                replaying: batches,
                revisionFloor: try await store.consensusRevisionFloor()
            )
            let level = ChainLevel(chain: chain, context: context)
            runtimePhase = .active(level)
        }

        try await recoverPreparedChildProofs(
            store: store,
            configuration: configuration
        )

        return ChainProcess(
            configuration: configuration,
            store: store,
            broker: broker,
            localFetcher: localFetcher,
            retentionScope: retentionScope,
            durableMempoolOwner: durableMempoolOwner,
            liveMempoolOwner: liveMempoolOwner,
            childIntentRetentionScope: childIntentRetentionScope,
            directoryLock: directoryLock,
            runtimePhase: runtimePhase
        )
    }

    /// Self-admit a deployer-seeded, self-contained child genesis. The deployer
    /// holds the genesis bytes (the parent only RECORDED the CID via a
    /// GenesisAction); the child node rebuilds the identical genesis from the
    /// seed and bootstraps it locally, exactly as the Nexus root bootstraps
    /// `NexusGenesis`. Before activating, `confirmParentRecordedGenesis` must
    /// confirm the parent actually recorded THIS rebuilt CID (the parent holds
    /// the committed `genesisState`, not this child node, so the confirmation is
    /// verify-not-trust over the authenticated parent fact plane). Fail-closed: a
    /// genesis the parent never recorded — or a CID that differs from the record —
    /// yields `false` and the chain stays `awaitingGenesis` for the caller to
    /// retry, so no honest node self-admits an unrecorded fork. Returns whether the
    /// genesis became active. Idempotent: returns false (no-op) once the chain is
    /// past `awaitingGenesis`.
    public func activateSeededChildGenesis(
        seed: ChildGenesisSeed,
        confirmParentRecordedGenesis: (_ childGenesisCID: String) async -> Bool
    ) async throws -> Bool {
        try await acquireMutationOperation()
        defer { releaseOperation() }
        guard case .awaitingGenesis = runtimePhase,
              !configuration.address.isNexus else {
            return false
        }
        let context = try configuration.runtimeContext
        guard let directory = context.path.last else { return false }
        let genesis = try await ChildGenesisBuilder.build(
            seed: seed,
            chainPath: context.path,
            fetcher: localFetcher
        )
        let header = try BlockHeader(node: genesis)
        return try await bootstrapSelfContainedGenesis(
            header: header,
            context: context,
            directory: directory,
            fetcher: localFetcher,
            confirmParentRecordedGenesis: confirmParentRecordedGenesis
        )
    }

    /// Self-admit an ADOPTED self-contained child genesis: this node did not
    /// deploy the child and holds no seed, so it FETCHES the genesis block by the
    /// parent-recorded `genesisCID` (content-addressed and self-verifying)
    /// through `remoteSource` — a child-overlay provider serves the bytes — and
    /// bootstraps it under the same fail-closed parent-record gate as the seeded
    /// path. This is the no-seed follower counterpart the candidate machinery
    /// cannot carry (a self-contained genesis has no `ChildBlockProof` to
    /// package). Returns whether the genesis became active; a fetch miss, a CID
    /// that fails to hash back, or a genesis the parent never recorded yields
    /// `false` for the caller to retry. Idempotent past `awaitingGenesis`.
    public func activateAdoptedChildGenesis(
        genesisCID: String,
        remoteSource: any ContentSource,
        confirmParentRecordedGenesis: (_ childGenesisCID: String) async -> Bool
    ) async throws -> Bool {
        try await acquireMutationOperation()
        defer { releaseOperation() }
        guard case .awaitingGenesis = runtimePhase,
              !configuration.address.isNexus else {
            return false
        }
        let context = try configuration.runtimeContext
        guard let directory = context.path.last else { return false }
        let fetcher = try Self.attemptFetcher(
            package: nil,
            fallback: CompositeContentSource([broker, remoteSource])
        )
        guard let node = try? await BlockHeader(
            rawCID: genesisCID, node: nil, encryptionInfo: nil
        ).resolve(fetcher: fetcher).node else {
            return false
        }
        let header = try BlockHeader(node: node)
        // Content addressing is self-verifying: a fetched volume that does not
        // hash back to the requested CID is not this genesis.
        guard header.rawCID == genesisCID else { return false }
        return try await bootstrapSelfContainedGenesis(
            header: header,
            context: context,
            directory: directory,
            fetcher: fetcher,
            confirmParentRecordedGenesis: confirmParentRecordedGenesis
        )
    }

    /// Bootstrap a resolved self-contained child genesis (seed-built or
    /// adopted-by-fetch). Fail-closed gate: only admits a genesis the parent
    /// actually recorded for this directory — this node holds no local copy of
    /// the parent's committed genesisState, so it asks the parent (over the
    /// authenticated fact plane) whether it recorded exactly this CID, bound to
    /// the empty parent state a self-contained genesis commits to. A negative or
    /// absent answer leaves the chain awaiting for the retry path. The caller
    /// holds the mutation operation and has confirmed `.awaitingGenesis`.
    private func bootstrapSelfContainedGenesis(
        header: BlockHeader,
        context: ChainRuntimeContext,
        directory: String,
        fetcher: any Fetcher,
        confirmParentRecordedGenesis: (_ childGenesisCID: String) async -> Bool
    ) async throws -> Bool {
        guard await confirmParentRecordedGenesis(header.rawCID) else {
            return false
        }
        let parentGenesisLink = ParentGenesisLink(
            parentPath: Array(context.path.dropLast()),
            directory: directory,
            childGenesisCID: header.rawCID,
            parentStateCID: LatticeState.emptyHeader.rawCID
        )
        let admissionStorage = NodeAdmissionStorage(storage: broker)
        let result = try await ChainLevel.bootstrap(
            context: context,
            genesisHeader: header,
            fetcher: fetcher,
            parentGenesisLink: parentGenesisLink,
            validationContentStorer: admissionStorage,
            materializedVolumeStorer: admissionStorage,
            stage: { context in
                let hierarchyArtifacts = context.issuedCarrierLink.map {
                    AdmissionHierarchyArtifacts(
                        carrierLink: $0,
                        carrierEvidence: nil,
                        parentGenesisLinks: context.parentGenesisLinks
                    )
                }
                try await Self.persist(
                    context.batch,
                    admissionStorage: admissionStorage,
                    store: self.store,
                    broker: self.broker,
                    retentionScope: self.retentionScope,
                    pendingChildProofRoutes: [],
                    pendingChildProofCapacity: Self.preparedChildProofCapacity,
                    hierarchyArtifacts: hierarchyArtifacts
                )
            }
        )
        guard case .accepted(let acceptance) = result else { return false }
        runtimePhase = .active(acceptance.level)
        return true
    }

    func admit(
        _ blockHeader: BlockHeader,
        authenticatedChildPackage suppliedAuthenticatedChildPackage:
            AuthenticatedChildPackage? = nil,
        preparingChildDirectories: [String] = [],
        remoteSource: (any ContentSource)? = nil,
        mode: AdmissionMode = .eager,
        canonicalCommitPublisher: CanonicalCommitPublisher? = nil
    ) async throws -> NodeAdmissionOutcome {
        let authenticatedChildPackage: AuthenticatedChildPackage?
        if let supplied = suppliedAuthenticatedChildPackage {
            authenticatedChildPackage = supplied
        } else {
            authenticatedChildPackage = try await recoveredAuthenticatedChildPackage(
                for: blockHeader.rawCID
            )
        }
        let directChildDirectories = try validatedDirectChildDirectories(
            preparingChildDirectories
        )
        let pendingChildProofRoutes = Self.pendingChildProofRoutes(
            carrierCID: blockHeader.rawCID,
            directories: directChildDirectories
        )

        let package = authenticatedChildPackage?.package
        let attemptFetcher = try Self.attemptFetcher(
            package: package,
            fallback: remoteSource.map {
                CompositeContentSource([broker, $0])
            } ?? broker
        )
        if case .active(let level) = runtimePhase {
            return try await admitActive(
                blockHeader,
                level: level,
                authenticatedPackage: authenticatedChildPackage,
                attemptFetcher: attemptFetcher,
                directChildDirectories: directChildDirectories,
                pendingChildProofRoutes: pendingChildProofRoutes,
                mode: mode,
                canonicalCommitPublisher: canonicalCommitPublisher
            )
        }

        // Bootstrap changes the phase, so it remains one sequential operation.
        // Once active, the Lattice preflight path above releases this lease
        // during remote acquisition and takes it only for durability/commit.
        try await acquireMutationOperation()
        var operationHeld = true
        if case .active(let level) = runtimePhase {
            releaseOperation()
            operationHeld = false
            return try await admitActive(
                blockHeader,
                level: level,
                authenticatedPackage: authenticatedChildPackage,
                attemptFetcher: attemptFetcher,
                directChildDirectories: directChildDirectories,
                pendingChildProofRoutes: pendingChildProofRoutes,
                mode: mode,
                canonicalCommitPublisher: canonicalCommitPublisher
            )
        }
        defer {
            if operationHeld {
                releaseOperation()
            }
        }

        guard case .awaitingGenesis = runtimePhase else {
            throw ChainProcessError.chainNotBootstrapped
        }
        guard let package else {
            return NodeAdmissionOutcome(
                decision: .unavailable(.childProof(
                    chainPath: configuration.chainPath,
                    childCID: blockHeader.rawCID
                )),
                parentCarrierLink: nil,
                sameChainPredecessor: nil
            )
        }
        // A child process can receive a valid successor attachment before its
        // genesis attachment. That is an ordering dependency, not malformed
        // genesis. Keep the authenticated candidate parked behind its direct
        // predecessor so ordinary same-chain wake-up admits it after bootstrap.
        let bootstrapCandidate = try await Self.resolvedCandidate(
            blockHeader,
            fetcher: attemptFetcher
        )
        if let predecessorCID = bootstrapCandidate.parent?.rawCID {
            let relayLink: ParentCarrierLink
            switch await package.verifiedCarrierLink(
                child: bootstrapCandidate,
                chainPath: configuration.chainPath
            ) {
            case .success(let link):
                relayLink = link
            case .failure(.crossChainEvidenceRequired(let requirement)):
                return NodeAdmissionOutcome(
                    decision: .unavailable(requirement),
                    parentCarrierLink: nil,
                    sameChainPredecessor: nil
                )
            case .failure(.malformedEvidence),
                 .failure(.protocolInvalid):
                return NodeAdmissionOutcome(
                    decision: .invalid,
                    parentCarrierLink: nil,
                    sameChainPredecessor: nil
                )
            }
            let evidence = try await Self.canonicalCarrierEvidence(
                blockHeader,
                authenticatedPackage: authenticatedChildPackage,
                fetcher: attemptFetcher
            )
            try await persistHierarchyArtifacts(
                relayLink,
                carrierEvidence: evidence,
                pendingChildProofRoutes: pendingChildProofRoutes
            )
            return NodeAdmissionOutcome(
                decision: .unavailable(nil),
                parentCarrierLink: relayLink,
                sameChainPredecessor: SameChainPredecessorRequirement(
                    descendantCID: blockHeader.rawCID,
                    predecessorCID: predecessorCID
                )
            )
        }
        let admissionStorage = NodeAdmissionStorage(storage: broker)
        let carrierEvidence = try await Self.canonicalCarrierEvidence(
            blockHeader,
            authenticatedPackage: authenticatedChildPackage,
            fetcher: attemptFetcher
        )
        let stage: @Sendable (ChainAdmissionStagingContext) async throws -> Void = {
            context in
            let hierarchyArtifacts: AdmissionHierarchyArtifacts?
            if let link = context.issuedCarrierLink {
                hierarchyArtifacts = AdmissionHierarchyArtifacts(
                    carrierLink: link,
                    carrierEvidence: carrierEvidence,
                    parentGenesisLinks: context.parentGenesisLinks
                )
            } else {
                hierarchyArtifacts = nil
            }
            try Task.checkCancellation()
            try await Self.persist(
                context.batch,
                admissionStorage: admissionStorage,
                store: self.store,
                broker: self.broker,
                retentionScope: self.retentionScope,
                pendingChildProofRoutes: hierarchyArtifacts == nil
                    ? []
                    : Self.pendingChildProofRoutes(
                        carrierCID: blockHeader.rawCID,
                        directories: directChildDirectories,
                        parentGenesisLinks: context.parentGenesisLinks
                    ),
                pendingChildProofCapacity: Self.preparedChildProofCapacity,
                hierarchyArtifacts: hierarchyArtifacts,
                incomingCarrierEvidence: hierarchyArtifacts == nil
                    ? carrierEvidence
                    : nil
            )
        }
        // A self-contained child genesis is authorized solely by the parent
        // RECORDING its CID (a GenesisAction -> genesisState). The authenticated
        // package carries the parent-issued ParentGenesisLink; without it the
        // parent has not yet recorded this genesis, so defer (retriable).
        guard let parentGenesisLink = package.parentGenesisLink else {
            return NodeAdmissionOutcome(
                decision: .unavailable(.parentGenesis(
                    parentPath: Array(configuration.chainPath.dropLast()),
                    directory: configuration.chainPath.last ?? "",
                    childGenesisCID: blockHeader.rawCID,
                    parentStateCID: LatticeState.emptyHeader.rawCID
                )),
                parentCarrierLink: nil,
                sameChainPredecessor: nil
            )
        }
        let result = try await ChainLevel.bootstrap(
            context: configuration.runtimeContext,
            genesisHeader: blockHeader,
            fetcher: attemptFetcher,
            parentGenesisLink: parentGenesisLink,
            validationContentStorer: admissionStorage,
            materializedVolumeStorer: admissionStorage,
            stage: stage
        )
        let decision: NodeAdmissionDecision
        let link: ParentCarrierLink
        switch result {
        case .accepted(let acceptance):
            runtimePhase = .active(acceptance.level)
            // The admission batch now owns every materialized root. Candidate
            // retention may release its overlapping reference without a GC gap.
            _ = try? await store.removeContextualCandidateIfAdmitted(
                candidateCID: blockHeader.rawCID
            )
            let commit = acceptance.commit
            let receipt: CanonicalCommitReceipt?
            if let canonicalCommitPublisher {
                receipt = await canonicalCommitPublisher(commit)
            } else {
                receipt = nil
            }
            releaseOperation()
            operationHeld = false
            return NodeAdmissionOutcome(
                decision: .canonicalized(commit),
                parentCarrierLink: acceptance.parentCarrierLink,
                sameChainPredecessor: nil,
                canonicalCommitReceipt: receipt
            )
        case .carrier(let resultLink):
            decision = .carrier
            link = resultLink
        case .rejected(let failure, let resultLink):
            decision = NodeAdmissionDecision(failure)
            link = resultLink
        }
        let evidence = try await Self.canonicalCarrierEvidence(
            blockHeader,
            authenticatedPackage: authenticatedChildPackage,
            fetcher: attemptFetcher
        )
        try await persistHierarchyArtifacts(
            link,
            carrierEvidence: evidence,
            pendingChildProofRoutes: pendingChildProofRoutes
        )
        releaseOperation()
        operationHeld = false
        return NodeAdmissionOutcome(
            decision: decision,
            parentCarrierLink: link,
            sameChainPredecessor: nil
        )
    }

    func recoveredAuthenticatedChildPackage(
        for childCID: String,
        rootCID: String? = nil
    ) async throws -> AuthenticatedChildPackage? {
        guard !configuration.address.isNexus,
              let evidence = try await store.incomingCarrierEvidence(
                childCID: childCID,
                directory: configuration.address.directory,
                rootCID: rootCID
              ) else {
            return nil
        }
        return AuthenticatedChildPackage(
            package: ChildValidationPackage(proof: evidence.proof)
        )
    }

    func recoveredIncomingCarrierRootCIDs(
        for childCID: String
    ) async throws -> [String] {
        guard !configuration.address.isNexus else { return [] }
        var result: [String] = []
        var afterRootCID: String?
        while true {
            let roots = try await store.incomingCarrierProofRoots(
                childCID: childCID,
                directory: configuration.address.directory,
                afterRootCID: afterRootCID,
                limit: 257
            )
            result.append(contentsOf: roots)
            guard roots.count == 257, let last = roots.last else { return result }
            afterRootCID = last
        }
    }

    private func admitActive(
        _ blockHeader: BlockHeader,
        level: ChainLevel,
        authenticatedPackage: AuthenticatedChildPackage?,
        attemptFetcher: any Fetcher,
        directChildDirectories: [String],
        pendingChildProofRoutes: [PendingChildProofRoute],
        mode: AdmissionMode = .eager,
        canonicalCommitPublisher: CanonicalCommitPublisher?
    ) async throws -> NodeAdmissionOutcome {
        let package = authenticatedPackage?.package
        let admissionStorage = NodeAdmissionStorage(storage: broker)
        let preflight = try await level.preflightBlockHeaderChainLocal(
            blockHeader,
            fetcher: attemptFetcher,
            childPackage: package,
            validationContentStorer: admissionStorage,
            mode: mode
        )
        // Keep all remote acquisition before the one serial durability lane.
        // A ready token may gain a carrier link when its predecessor commits.
        let mayIssueCarrierLink: Bool
        switch preflight {
        case .ready:
            mayIssueCarrierLink = true
        case .duplicate:
            mayIssueCarrierLink = true
        case .terminal(let result, _):
            mayIssueCarrierLink = result.parentCarrierLink != nil
        }
        let carrierEvidence: AdmissionCarrierEvidence?
        if mayIssueCarrierLink, authenticatedPackage != nil {
            carrierEvidence = try await Self.canonicalCarrierEvidence(
                blockHeader,
                authenticatedPackage: authenticatedPackage,
                fetcher: attemptFetcher
            )
        } else {
            carrierEvidence = nil
        }
        var directParentGenesisLinks: [ParentGenesisLink] = []
        if case .terminal(_, let parentGenesisLinks) = preflight {
            directParentGenesisLinks = parentGenesisLinks
        }
        let stage: @Sendable (ChainAdmissionStagingContext) async throws -> Void = {
            context in
            try Task.checkCancellation()
            // Validated tier (deferred execution): the block was already weighed,
            // and its weighed block fact (empty stateDiff) is immutable and keyed
            // by blockHash only. Re-staging the validated fact's real stateDiff
            // would collide, so a validate SUCCESS never rewrites `admission_facts`
            // — it retains the freshly materialized post-state and flips the durable
            // marker. A validate EXCLUSION is a brand-new fact and stages normally.
            if case .validate = mode {
                let isExclusion = context.batch.facts.contains {
                    if case .exclusion = $0 { return true }
                    return false
                }
                if isExclusion {
                    try await Self.persist(
                        context.batch,
                        admissionStorage: admissionStorage,
                        store: self.store,
                        broker: self.broker,
                        retentionScope: self.retentionScope,
                        pendingChildProofRoutes: [],
                        pendingChildProofCapacity: Self.preparedChildProofCapacity,
                        consensusRevisionFloor: try Self.nextConsensusRevision(
                            await level.chain.currentRevision()
                        )
                    )
                } else {
                    // Pin BEFORE flipping the marker: a crash between leaves an
                    // orphan pin that boot reclaims, never a marker without its
                    // state. The owner pin (not the batch-rebuilt retention
                    // scope) is what survives a restart.
                    let roots = await admissionStorage.takeStoredVolumeRoots()
                    try await self.broker.pinBatch(
                        roots: roots,
                        owner: Self.validatedOwner(
                            self.retentionScope, blockHeader.rawCID
                        )
                    )
                    try await self.store.promoteValidated(
                        blockCID: blockHeader.rawCID
                    )
                    // The weighed tier suppressed hierarchy issuance; validation
                    // re-derives it, and Lattice hands the carrier link back in the
                    // staging context. Persist it exactly as the eager path does so
                    // a cold-synced parent can serve child-proof routes and relay
                    // securing proofs for children anchored in below-tip blocks.
                    if let hierarchyArtifacts = context.issuedCarrierLink.map({
                        AdmissionHierarchyArtifacts(
                            carrierLink: $0,
                            carrierEvidence: carrierEvidence,
                            parentGenesisLinks: context.parentGenesisLinks
                        )
                    }) {
                        try await self.store.persistIssuedHierarchyArtifacts(
                            hierarchyArtifacts,
                            pendingChildProofRoutes: Self.pendingChildProofRoutes(
                                carrierCID: blockHeader.rawCID,
                                directories: directChildDirectories,
                                parentGenesisLinks: context.parentGenesisLinks
                            ),
                            pendingChildProofCapacity: Self.preparedChildProofCapacity
                        )
                    }
                }
                return
            }
            let hierarchyArtifacts = context.issuedCarrierLink.map {
                AdmissionHierarchyArtifacts(
                    carrierLink: $0,
                    carrierEvidence: carrierEvidence,
                    parentGenesisLinks: context.parentGenesisLinks
                )
            }
            try await Self.persist(
                context.batch,
                admissionStorage: admissionStorage,
                store: self.store,
                broker: self.broker,
                retentionScope: self.retentionScope,
                pendingChildProofRoutes: hierarchyArtifacts == nil
                    ? []
                    : Self.pendingChildProofRoutes(
                        carrierCID: blockHeader.rawCID,
                        directories: directChildDirectories,
                        parentGenesisLinks: context.parentGenesisLinks
                ),
                pendingChildProofCapacity: Self.preparedChildProofCapacity,
                // A weighed admission enters fork choice on verified work but
                // is not executed: record it below the validated tier so the
                // validate-on-candidacy walk (and every act-on read) knows to
                // execute it before building on it.
                validated: {
                    if case .weighed = mode { return false }
                    return true
                }(),
                hierarchyArtifacts: hierarchyArtifacts,
                incomingCarrierEvidence: hierarchyArtifacts == nil
                    ? carrierEvidence
                    : nil,
                consensusRevisionFloor: try Self.nextConsensusRevision(
                    await level.chain.currentRevision()
                )
            )
        }

        try await acquireMutationOperation()
        var operationHeld = true
        defer {
            if operationHeld {
                releaseOperation()
            }
        }
        let result: ChainLocalBlockResult
        switch preflight {
        case .terminal(let terminal, _):
            result = terminal
        case .duplicate(let token):
            let resolved = try await level.resolveDuplicatePreflight(token)
            result = resolved.result
            directParentGenesisLinks = resolved.parentGenesisLinks
        case .ready(let token):
            result = try await level.commitPreflight(
                token,
                materializedVolumeStorer: admissionStorage,
                stage: stage
            )
        }

        let decision = NodeAdmissionDecision(result)
        let admissionStaged = result.commit != nil
        // A disconnected accepted block is not yet a parent-fact issuer, but
        // its content-verified carrier remains valid relay data for deeper
        // chains. Persist that relay with no genesis facts; a later duplicate
        // retry promotes the exact genesis facts after the predecessor connects.
        if (!admissionStaged || result.sameChainPredecessor != nil),
           let link = result.parentCarrierLink {
            try await store.persistIssuedHierarchyArtifacts(
                AdmissionHierarchyArtifacts(
                    carrierLink: link,
                    carrierEvidence: carrierEvidence,
                    parentGenesisLinks: decision.isAccepted
                        && result.sameChainPredecessor == nil
                        ? directParentGenesisLinks
                        : []
                ),
                pendingChildProofRoutes: Self.pendingChildProofRoutes(
                    carrierCID: blockHeader.rawCID,
                    directories: directChildDirectories,
                    parentGenesisLinks: directParentGenesisLinks
                ),
                pendingChildProofCapacity: Self.preparedChildProofCapacity
            )
        }
        var receipt: CanonicalCommitReceipt?
        if let canonicalCommitPublisher {
            if let commit = result.commit {
                receipt = await canonicalCommitPublisher(commit)
            }
        }
        if decision.isAccepted {
            // Staging (or the earlier duplicate admission) is already durable.
            _ = try? await store.removeContextualCandidateIfAdmitted(
                candidateCID: blockHeader.rawCID
            )
        }

        // The canonical decision is now durable and ordered for publication.
        // Everything below is replayable availability work.
        releaseOperation()
        operationHeld = false

        return NodeAdmissionOutcome(
            decision: decision,
            parentCarrierLink: result.parentCarrierLink,
            sameChainPredecessor: result.sameChainPredecessor,
            canonicalCommitReceipt: receipt
        )
    }

    func acceptedLeafPage(
        afterCID: String?,
        snapshotSequence: Int64?,
        limit: Int
    ) async throws -> AcceptedLeafPage {
        return try await store.acceptedLeafPage(
            afterCID: afterCID,
            snapshotSequence: snapshotSequence,
            limit: limit
        )
    }

    /// One page of this node's MAIN chain going forward from `afterCID` (a block
    /// the caller already holds): `[child(afterCID), …]`, genesis-ward first,
    /// with `hasMore` when the canonical chain extends past the page. Serves
    /// forward-apply sync so a receiver can apply a bounded page and page again,
    /// never buffering the whole gap. Empty when `afterCID` is not on our main
    /// chain or we have nothing after it.
    func forwardMainChainRange(
        afterCID: String,
        limit: Int
    ) async -> (blockCIDs: [String], hasMore: Bool) {
        guard limit > 0, case .active(let level) = runtimePhase else {
            return ([], false)
        }
        guard let meta = await level.chain.getConsensusBlock(hash: afterCID),
              await level.chain.getMainChainBlockHash(atIndex: meta.blockHeight) == afterCID
        else {
            return ([], false)
        }
        let highest = await level.chain.getHighestBlockHeight()
        var blockCIDs: [String] = []
        var height = meta.blockHeight + 1
        while blockCIDs.count < limit, height <= highest {
            guard let cid = await level.chain.getMainChainBlockHash(atIndex: height) else {
                break
            }
            blockCIDs.append(cid)
            height += 1
        }
        let hasMore = meta.blockHeight + UInt64(blockCIDs.count) < highest
        return (blockCIDs, hasMore)
    }

    /// Resolve the negotiated stream start from a receiver's block locator: the
    /// highest locator entry that lies on this node's main chain, then the page
    /// of main-chain blocks forward from it. The locator is newest-first, so the
    /// first entry on our chain is the highest common block. A `nil` common
    /// ancestor means no locator entry is on the main chain (disjoint
    /// retention) — distinct from a present ancestor with an empty page, which
    /// is "the receiver is caught up to us." The start is one of the receiver's
    /// own accepted CIDs by construction, so this never rewinds it past its own
    /// verified history. Same main-chain test as `forwardMainChainRange`.
    func commonAncestorRange(
        locator: [String],
        limit: Int
    ) async -> (commonAncestor: String?, blockCIDs: [String], hasMore: Bool) {
        guard limit > 0, case .active(let level) = runtimePhase else {
            return (nil, [], false)
        }
        for cid in locator {
            guard let meta = await level.chain.getConsensusBlock(hash: cid),
                  await level.chain.getMainChainBlockHash(atIndex: meta.blockHeight) == cid
            else { continue }
            let page = await forwardMainChainRange(afterCID: cid, limit: limit)
            return (cid, page.blockCIDs, page.hasMore)
        }
        return (nil, [], false)
    }

    /// Height of an accepted block by CID, or nil when the process is not active
    /// or the block is unknown. Used to anchor a range sync's request-height
    /// window at a negotiated common ancestor rather than the receiver's own
    /// (possibly off-chain) frontier height.
    func acceptedBlockHeight(_ cid: String) async -> UInt64? {
        guard case .active(let level) = runtimePhase else { return nil }
        return await level.chain.getConsensusBlock(hash: cid)?.blockHeight
    }

    /// Main-chain block CID at `height`, or nil when the process is not active
    /// or the height is past the tip. Ungated explorer read over the in-memory
    /// height index (same source as `forwardMainChainRange`), so a by-height
    /// lookup never walks parents or touches the operation gate.
    func mainChainBlockCID(atHeight height: UInt64) async -> String? {
        guard case .active(let level) = runtimePhase else { return nil }
        return await level.chain.getMainChainBlockHash(atIndex: height)
    }

    /// The current main-chain tip height, or nil when not active.
    func highestBlockHeight() async -> UInt64? {
        guard case .active(let level) = runtimePhase else { return nil }
        return await level.chain.getHighestBlockHeight()
    }

    /// Height of the CURRENT canonical (weighed-inclusive) main-chain tip, or nil
    /// when not active. The validate-on-candidacy walk targets this: it executes
    /// forward from the deepest validated ancestor until the validated tier meets
    /// the canonical tier. Re-read every walk iteration so a mid-walk reorg or
    /// exclusion re-projection re-targets rather than chasing a stale frontier.
    func canonicalTipHeight() async -> UInt64? {
        guard case .active(let level) = runtimePhase else { return nil }
        let tip = await level.chain.getMainChainTip()
        return await level.chain.getConsensusBlock(hash: tip)?.blockHeight
    }

    /// Anchored `directory -> genesisCID` map from the committed `genesisState`
    /// subtrie of the tip's post-state (one bounded, ungated resolve). Lets the
    /// runtime announce every wired+anchored child's genesis on this (parent)
    /// overlay for the permissionless child-bootstrap rendezvous in a single
    /// pass — no per-child re-resolve, and unanchored fake `.child` peers just
    /// miss the map.
    func anchoredChildGenesisCIDs(limit: Int) async -> [String: String] {
        guard case .active(let level) = runtimePhase, limit > 0,
              let tip = await deepestValidatedMainChainTip(level: level)?.cid
        else { return [:] }
        let header = BlockHeader(rawCID: tip, node: nil, encryptionInfo: nil)
        guard let block = try? await header.resolve(fetcher: localFetcher).node,
              let state = try? await block.postState.resolve(
                  fetcher: localFetcher
              ).node,
              let genesis = (try? await state.genesisState.resolve(
                  fetcher: localFetcher
              ))?.node,
              let entries = try? await genesis.boundedKeysAndValues(
                  limit: limit,
                  fetcher: localFetcher
              ) else {
            return [:]
        }
        return Dictionary(entries.map { ($0.key, $0.value) }) { first, _ in first }
    }

    func portableEvidenceVolumeCID(
        scope: IssuedChildProofScope,
        edgeCID: String,
        rootCID: String
    ) async throws -> String? {
        try await store.portableEvidenceVolumeCID(
            scope: scope,
            edgeCID: edgeCID,
            rootCID: rootCID
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

    /// Ungated: whether `cid` is accepted on the validated (executed) tier, as
    /// opposed to merely weighed.
    public func blockValidated(_ cid: String) async -> Bool {
        (try? await store.blockValidated(cid)) ?? false
    }

    /// Fork choice's same-chain subtree weight of `cid`, or nil when the block
    /// is unknown or the process is not active.
    func subtreeWeight(of cid: String) async -> WorkSum? {
        guard case .active(let level) = runtimePhase else { return nil }
        return await level.chain.subtreeWeight(forHash: cid)
    }

    /// Walks durable parent edges from `cid` toward genesis and returns the
    /// first ancestor that is NOT accepted locally — the block an
    /// accepted-but-disconnected segment is actually missing — or nil when
    /// every ancestor within the bound is already accepted (connection is
    /// then a re-admission/fork-choice concern, not an acquisition one).
    /// Point lookups only, never block materialization.
    public func deepestMissingAncestor(
        of cid: String,
        limit: Int = 4096
    ) async -> String? {
        var cursor = cid
        for _ in 0..<max(0, limit) {
            guard let parent =
                ((try? await store.acceptedBlockParent(cursor)) ?? nil)
            else { return nil }
            guard (try? await store.hasAcceptedBlock(parent)) == true else {
                return parent
            }
            cursor = parent
        }
        return nil
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
        try await broker.pin(root: volume.rawCID, owner: durableMempoolOwner)
        do {
            try await store.persistLocalMempoolTransaction(
                transactionCID: volume.rawCID,
                addedAt: addedAt
            )
        } catch {
            try await broker.unpin(
                root: volume.rawCID,
                owner: durableMempoolOwner
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
            try await broker.pin(root: volume.rawCID, owner: liveMempoolOwner)
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
            try await broker.pinBatch(
                roots: added.sorted(),
                owner: liveMempoolOwner
            )
            livePinnedMempoolRoots.formUnion(added)
        }
        if !removed.isEmpty {
            try await broker.unpinBatch(items: removed.sorted().map {
                (root: $0, owner: liveMempoolOwner, count: 1)
            })
            livePinnedMempoolRoots.subtract(removed)
        }
    }

    func storeContextualCandidate(
        _ header: BlockHeader,
        fetcher: any Fetcher,
        children: [ChildCandidateReservationReference] = [],
        capacity: Int
    ) async throws {
        guard capacity > 0 else {
            throw ChainProcessError.malformedAuthenticatedChildProof
        }
        try await acquireMutationOperation()
        defer { releaseOperation() }

        if try await store.touchContextualCandidate(
            candidateCID: header.rawCID,
            children: children
        ) {
            return
        }

        let storage = NodeAdmissionStorage(storage: broker)
        try await header.storeBlock(fetcher: fetcher, storer: storage)
        let roots = Array(Set(await storage.takeStoredVolumeRoots())).sorted()
        guard roots.contains(header.rawCID) else {
            throw ChainProcessError.malformedAuthenticatedChildProof
        }
        try await store.persistContextualCandidateRoots(
            candidateCID: header.rawCID,
            roots: roots,
            children: children,
            capacity: capacity
        )
    }

    func contextualCandidateChildren(
        candidateCIDs: Set<String>
    ) async throws -> [ChildCandidateReservationReference]? {
        try await store.contextualCandidateChildren(
            candidateCIDs: candidateCIDs
        )
    }

    func currentContextualCandidateChildren()
        async throws -> [ChildCandidateReservationReference]
    {
        try await store.currentContextualCandidateChildren()
    }

    func replaceIssuedContextualCandidates(
        _ candidateCIDs: Set<String>,
        handoffs: Set<String> = [],
        capacity: Int
    ) async throws -> Bool {
        try await acquireMutationOperation()
        defer { releaseOperation() }
        return try await store.replaceIssuedContextualCandidates(
            candidateCIDs,
            handoffs: handoffs,
            capacity: capacity
        )
    }

    /// Stores one validated child-intent closure and atomically replaces the
    /// exact live retention set while process eviction is excluded.
    func storeChildIntent(
        _ header: BlockHeader,
        fetcher: any Fetcher,
        retaining existingRoots: Set<String>
    ) async throws -> Set<String> {
        try await acquireMutationOperation()
        defer { releaseOperation() }
        let storage = NodeAdmissionStorage(storage: broker)
        try await header.storeBlock(fetcher: fetcher, storer: storage)
        let storedRoots = Set(await storage.takeStoredVolumeRoots())
        try await broker.advanceRetainedRoots(
            scope: childIntentRetentionScope,
            roots: Array(existingRoots.union(storedRoots)).sorted()
        )
        return storedRoots
    }

    func retainChildIntentRoots(_ roots: Set<String>) async throws {
        try await acquireMutationOperation()
        defer { releaseOperation() }
        try await broker.advanceRetainedRoots(
            scope: childIntentRetentionScope,
            roots: roots.sorted()
        )
    }

    func removeLocalTransaction(_ transactionCID: String) async throws {
        try await acquireMutationOperation()
        defer { releaseOperation() }
        try await store.removeLocalMempoolTransaction(
            transactionCID: transactionCID
        )
        try await broker.unpin(
            root: transactionCID,
            owner: durableMempoolOwner
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

    public func canonicalTipBlock() async throws -> Block {
        await acquireOperation()
        defer { releaseOperation() }
        guard case .active(let level) = runtimePhase else {
            throw ChainProcessError.chainNotBootstrapped
        }
        let tip = await level.chain.getMainChainTip()
        let header = BlockHeader(rawCID: tip, node: nil, encryptionInfo: nil)
        guard let block = try await header.resolve(fetcher: localFetcher).node else {
            throw ChainProcessError.unresolvedCanonicalTip(tip)
        }
        return block
    }

    /// The deepest block on the CURRENT main chain that carries the durable
    /// *validated* tier marker (spec §9.9): starting at the canonical tip, walk
    /// DOWN the main chain and return the first block recorded validated, with
    /// its height. A node MUST NOT act on a merely *weighed* tip, so every
    /// act-on read (head/height, mining parent, announcement) uses this instead
    /// of the raw canonical tip. Re-evaluated against the live main chain on
    /// every call — never a stored highwater — so after a reorg it returns the
    /// deepest validated ancestor of the NEW main chain, and it degrades one
    /// block at a time rather than all-or-nothing when the tip is weighed.
    /// Under all-eager admission every accepted block is validated, so this is
    /// the canonical tip. Nil only when the process is inactive or (impossible
    /// while genesis is eager) no main-chain block is validated.
    func deepestValidatedMainChainTip() async -> (cid: String, height: UInt64)? {
        guard case .active(let level) = runtimePhase else { return nil }
        return await deepestValidatedMainChainTip(level: level)
    }

    private func deepestValidatedMainChainTip(
        level: ChainLevel
    ) async -> (cid: String, height: UInt64)? {
        let tip = await level.chain.getMainChainTip()
        guard var height = await level.chain
            .getConsensusBlock(hash: tip)?.blockHeight
        else { return nil }
        while true {
            if let cid = await level.chain.getMainChainBlockHash(atIndex: height),
               (try? await store.blockValidated(cid)) == true {
                return (cid, height)
            }
            if height == 0 { return nil }
            height -= 1
        }
    }

    /// The block at the deepest validated main-chain tip. Mirrors
    /// `canonicalTipBlock()` but honours the deferred-execution gate so callers
    /// that BUILD ON the tip (mining templates, mempool reconciliation) never
    /// act on a merely weighed tip. Identical to `canonicalTipBlock()` under
    /// all-eager admission.
    public func validatedTipBlock() async throws -> Block {
        await acquireOperation()
        defer { releaseOperation() }
        guard case .active(let level) = runtimePhase,
              let validated = await deepestValidatedMainChainTip(level: level)
        else {
            throw ChainProcessError.chainNotBootstrapped
        }
        let header = BlockHeader(
            rawCID: validated.cid, node: nil, encryptionInfo: nil
        )
        guard let block = try await header.resolve(fetcher: localFetcher).node
        else {
            throw ChainProcessError.unresolvedCanonicalTip(validated.cid)
        }
        return block
    }

    /// Classifies against one coherent Lattice tip while process mutations are
    /// fenced. The returned tip CID lets the service reject a result overtaken
    /// immediately after this operation releases its fence.
    public func preflightTransaction(
        _ transaction: Transaction,
        parentState: LatticeStateHeader? = nil,
        fetcher: (any Fetcher)? = nil
    ) async throws -> TransactionPreflightResult {
        await acquireOperation()
        defer { releaseOperation() }
        guard case .active(let level) = runtimePhase else {
            throw ChainProcessError.chainNotBootstrapped
        }
        return await level.preflightTransaction(
            transaction,
            parentState: parentState,
            fetcher: fetcher ?? localFetcher
        )
    }

    public func issuedParentCarrierLink(
        carrierCID: String,
        rootCID: String
    ) async throws -> ParentCarrierLink? {
        try await store.issuedParentCarrierLink(
            carrierCID: carrierCID,
            rootCID: rootCID
        )
    }

    /// Query this process's recovered graph of connected, validated blocks.
    /// The walk holds the consensus actor, so each query carries the local
    /// resource-policy visit budget. Exhaustion answers with silence — the
    /// same retryable unavailability as any other non-answer — and the
    /// budget is operator-raisable; it never marks chain data invalid.
    func hasParentStateContinuity(
        from fromStateCID: String,
        to toStateCID: String
    ) async -> Bool {
        guard case .active(let level) = runtimePhase else { return false }
        return await level.chain.hasStateContinuity(
            from: fromStateCID,
            to: toStateCID,
            maximumBlockVisits:
                configuration.resourcePolicy.maximumContinuityBlockVisits
        )
    }

    /// Pages authenticated root contexts for one local carrier. Nexus is its
    /// own root; every child reuses its durable incoming-proof index.
    func parentCarrierRootPage(
        carrierCID: String,
        afterRootCID: String?,
        limit: Int
    ) async throws -> [String] {
        guard limit > 0 else { return [] }
        if configuration.address.isNexus {
            guard afterRootCID == nil,
                  try await store.issuedParentCarrierLink(
                    carrierCID: carrierCID,
                    rootCID: carrierCID
                  ) != nil else {
                return []
            }
            return [carrierCID]
        }
        return try await store.incomingCarrierProofRoots(
            childCID: carrierCID,
            directory: configuration.address.directory,
            afterRootCID: afterRootCID,
            limit: limit
        )
    }

    public func issuedParentGenesisLink(
        directory: String,
        childGenesisCID: String,
        parentStateCID: String
    ) async throws -> ParentGenesisLink? {
        try await store.issuedParentGenesisLink(
            directory: directory,
            childGenesisCID: childGenesisCID,
            parentStateCID: parentStateCID
        )
    }

    func prepareChildProofs(
        for candidate: Block,
        children selectedChildren: [DirectChildCandidate] = [],
        capacity: Int
    ) async throws -> [PreparedChildProof] {
        try await acquireMutationOperation()
        defer { releaseOperation() }
        guard let children = candidate.children.node else {
            throw ChainProcessError.malformedAuthenticatedChildProof
        }
        let rootHeader = try BlockHeader(node: candidate)
        let selected = Dictionary(
            selectedChildren.map { ($0.directory, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var prepared: [PreparedChildProof] = []
        for (directory, childHeader) in try children.allKeysAndValues().sorted(by: {
            $0.key < $1.key
        }) {
            guard let child = childHeader.node else {
                throw ChainProcessError.malformedAuthenticatedChildProof
            }
            let childCID = try BlockHeader(node: child).rawCID
            if let supplied = selected[directory] {
                guard try BlockHeader(node: supplied.block).rawCID == childCID else {
                    throw ChainProcessError.malformedAuthenticatedChildProof
                }
            }
            let isChildGenesis = child.parent == nil
            // Child geneses are self-contained and self-mined; a parent never
            // carries a child genesis, so no bootstrap volume roots are staged.
            let bootstrapRoots: [String] = []
            prepared.append(try PreparedChildProof(
                directory: directory,
                childCID: childCID,
                isChildGenesis: isChildGenesis,
                bootstrapRoots: bootstrapRoots,
                proof: try await ChildBlockProof.generate(
                    rootHeader: rootHeader,
                    childDirectory: directory,
                    fetcher: localFetcher
                )
            ))
        }
        guard selected.keys.allSatisfy({ directory in
            prepared.contains { $0.directory == directory }
        }) else {
            throw ChainProcessError.malformedAuthenticatedChildProof
        }
        try Task.checkCancellation()
        try await store.persistPreparedChildProofs(
            carrierCID: rootHeader.rawCID,
            proofs: prepared,
            capacity: capacity
        )
        return prepared
    }

    /// Targeted retry for authenticated direct-child routes. This never walks
    /// or enumerates the complete children trie.
    func prepareChildProofs(
        for carrier: BlockHeader,
        directories: [String],
        remoteSource: (any ContentSource)? = nil
    ) async throws {
        var directories = try validatedDirectChildDirectories(directories)
        try await acquireMutationOperation()
        do {
            defer { releaseOperation() }
            try Task.checkCancellation()
            let available = Set(try await store.preparedChildProofs(
                carrierCID: carrier.rawCID
            ).map(\.directory)).union(try await store.retainedDirectChildProofs(
                carrierCID: carrier.rawCID
            ).map(\.directory))
            directories.removeAll { available.contains($0) }
            guard !directories.isEmpty else { return }
            try await store.persistPendingChildProofRoutes(
                carrierCID: carrier.rawCID,
                directories: directories,
                capacity: Self.preparedChildProofCapacity
            )
        }
        _ = try await acquirePendingChildProofs(
            carrier: carrier,
            directories: directories,
            fetcher: CoalescingFetcher(remoteSource.map {
                CompositeContentSource([broker, $0])
            } ?? broker)
        )
    }

    /// Backfill securing-evidence issuance for one child directory across the
    /// recent accepted-carrier window (the operator-configured
    /// `NodeResourcePolicy.childEvidenceBackfillCarrierWindow`). Called when a
    /// `.child` connects or a tracked child is recovered. Issuance is a
    /// consequence of having admitted/validated the carrier — independent of
    /// mining and of the child being a connected peer at admission. Reuses
    /// `prepareChildProofs`: a carrier that does not commit the directory
    /// resolves `.absent` and drops its route (self-cleaning), unavailable
    /// content is retried by the ordinary pipeline. Never touches validation,
    /// weight, or fork choice — the proof is still verified from content.
    func backfillChildProofRoutes(
        directory: String,
        carrierLimit: Int? = nil,
        remoteSource: (any ContentSource)? = nil
    ) async {
        let carrierLimit = carrierLimit
            ?? configuration.resourcePolicy.childEvidenceBackfillCarrierWindow
        let carriers: [String]
        do {
            carriers = try await store.recentAcceptedBlockCIDs(limit: carrierLimit)
        } catch {
            return
        }
        for carrierCID in carriers {
            try? await prepareChildProofs(
                for: BlockHeader(
                    rawCID: carrierCID,
                    node: nil,
                    encryptionInfo: nil
                ),
                directories: [directory],
                remoteSource: remoteSource
            )
        }
    }

    func pendingChildProofCarrierCIDs() async throws -> [String] {
        await acquireOperation()
        defer { releaseOperation() }
        return Array(Set(
            try await store.pendingChildProofRoutes().map(\.carrierCID)
        )).sorted()
    }

    /// Retries one bounded carrier batch retained across a crash after remote
    /// content is available again. Individual acquisition misses remain pending.
    func retryPendingChildProofs(
        carrierCID: String,
        remoteSource: (any ContentSource)? = nil
    ) async throws -> [String] {
        try await acquireMutationOperation()
        let directories: [String]
        do {
            defer { releaseOperation() }
            directories = try await store.pendingChildProofRoutes()
                .filter { $0.carrierCID == carrierCID }
                .map(\.directory)
                .sorted()
        }
        guard !directories.isEmpty else { return [] }
        return try await acquirePendingChildProofs(
            carrier: BlockHeader(
                rawCID: carrierCID,
                node: nil,
                encryptionInfo: nil
            ),
            directories: directories,
            fetcher: CoalescingFetcher(remoteSource.map {
                CompositeContentSource([broker, $0])
            } ?? broker)
        )
    }

    func durableDirectChildProofs(
        carrierCID: String,
        rootCID: String,
        directories: Set<String>? = nil
    ) async throws -> [DurableDirectChildProof] {
        var durable: [DurableDirectChildProof] = []
        let retained = try await store.retainedDirectChildProofs(
            carrierCID: carrierCID
        )
        for edge in retained
        where directories?.contains(edge.directory) ?? true {
            guard let evidence = try await store.issuedChildEvidence(
                childCID: edge.childCID,
                directory: edge.directory,
                rootCID: rootCID
            ) else {
                throw ChainProcessError.malformedAuthenticatedChildProof
            }
            durable.append(DurableDirectChildProof(
                directory: edge.directory,
                childCID: edge.childCID,
                proof: evidence.proof
            ))
        }
        return durable
    }

    func issuedChildEvidence(
        childCID: String,
        directory: String,
        rootCID: String? = nil
    ) async throws -> IssuedChildEvidence? {
        try await store.issuedChildEvidence(
            childCID: childCID,
            directory: directory,
            rootCID: rootCID
        )
    }

    func childRootAttachment(
        scope: IssuedChildProofScope,
        edgeCID: String,
        rootCID: String
    ) async throws -> IssuedChildEvidence? {
        try await store.issuedChildEvidence(
            scope: scope,
            edgeCID: edgeCID,
            rootCID: rootCID
        )
    }

    func childRootAttachmentSummaries(
        scope: IssuedChildProofScope,
        directory: String,
        after: ChildRootAttachmentSummary?,
        limit: Int
    ) async throws -> [ChildRootAttachmentSummary] {
        try await store.childRootAttachmentSummaries(
            scope: scope,
            directory: directory,
            after: after,
            limit: limit
        )
    }

    func issuedChildProofRoots(
        childCID: String,
        directory: String,
        afterRootCID: String?,
        limit: Int
    ) async throws -> [String] {
        try await store.issuedChildProofRoots(
            childCID: childCID,
            directory: directory,
            afterRootCID: afterRootCID,
            limit: limit
        )
    }

    func issuedChildEvidenceSummaries(
        directory: String,
        afterOrdinal: UInt64,
        throughOrdinal: UInt64,
        limit: Int
    ) async throws -> [IssuedChildEvidenceSummary] {
        try await store.issuedChildEvidenceSummaries(
            directory: directory,
            afterOrdinal: afterOrdinal,
            throughOrdinal: throughOrdinal,
            limit: limit
        )
    }

    func issuedChildEvidenceScanHead(directory: String) async throws
        -> (sourceID: String, throughOrdinal: UInt64)
    {
        try await store.issuedChildEvidenceScanHead(directory: directory)
    }

    func issuedChildEvidenceSummary(
        childCID: String,
        directory: String,
        rootCID: String
    ) async throws -> (sourceID: String, summary: IssuedChildEvidenceSummary)? {
        try await store.issuedChildEvidenceSummary(
            childCID: childCID,
            directory: directory,
            rootCID: rootCID
        )
    }

    func parentEvidenceScanCursor() async throws -> ParentEvidenceScanCursor {
        try await store.parentEvidenceScanCursor()
    }

    func parentEvidenceInbox() async throws -> [ParentEvidenceInboxItem] {
        try await store.parentEvidenceInbox()
    }

    func parentEvidenceInboxHasCapacity() async throws -> Bool {
        try await store.parentEvidenceInboxHasCapacity()
    }

    func retainParentEvidence(
        sourceID: String,
        ordinal: UInt64,
        attachment: ChildEvidenceVolume,
        package: AuthenticatedChildPackage,
        advanceScan: Bool
    ) async throws {
        try await acquireMutationOperation()
        defer { releaseOperation() }
        try await store.storeParentEvidenceInbox(
            sourceID: sourceID,
            ordinal: ordinal,
            attachment: attachment,
            package: package,
            advanceScan: advanceScan
        )
        // The handoff budget is deliberately NOT enforced here: evidence
        // retention is the critical path for child admission, and evidence
        // only arrives while the parent is mining — the same cadence on
        // which reservation snapshots already enforce the budget.
    }

    public func status() async -> ChainProcessStatus {
        await acquireOperation()
        defer { releaseOperation() }
        guard case .active(let level) = runtimePhase else {
            return ChainProcessStatus(
                phase: .awaitingGenesis,
                chainPath: configuration.chainPath,
                nexusGenesisCID: configuration.nexusGenesisCID,
                tipCID: nil,
                height: nil,
                revision: nil
            )
        }
        let validated = await deepestValidatedMainChainTip(level: level)
        return ChainProcessStatus(
            phase: .active,
            chainPath: configuration.chainPath,
            nexusGenesisCID: configuration.nexusGenesisCID,
            tipCID: validated?.cid,
            height: validated?.height,
            revision: await level.chain.currentRevision()
        )
    }

    /// Ungated mirror of `status()` for public read RPC: identical projection,
    /// but never takes the consensus operation gate, so a read can never be
    /// blocked behind (or block) an in-flight mutating operation.
    public func readSnapshot() async -> ChainProcessStatus {
        guard case .active(let level) = runtimePhase else {
            return ChainProcessStatus(
                phase: .awaitingGenesis,
                chainPath: configuration.chainPath,
                nexusGenesisCID: configuration.nexusGenesisCID,
                tipCID: nil,
                height: nil,
                revision: nil
            )
        }
        let validated = await deepestValidatedMainChainTip(level: level)
        return ChainProcessStatus(
            phase: .active,
            chainPath: configuration.chainPath,
            nexusGenesisCID: configuration.nexusGenesisCID,
            tipCID: validated?.cid,
            height: validated?.height,
            revision: await level.chain.currentRevision()
        )
    }

    /// Recovery derives every still-unconnected same-chain edge from the
    /// durable accepted graph. The runtime uses these CID-only obligations to
    /// resume predecessor acquisition after a restart.
    func unresolvedSameChainPredecessors() async -> [SameChainPredecessorRequirement] {
        await acquireOperation()
        defer { releaseOperation() }
        guard case .active(let level) = runtimePhase else { return [] }
        return await level.chain.unresolvedSameChainPredecessors()
    }

    public func evictUnretainedVolumes() async throws -> Int {
        try await acquireMutationOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        try await evictDemotableValidatedBlocks()
        return try await broker.evictUnpinned()
    }

    /// Budgeted eviction-by-demotion of walk-validated state (fork loss = cache
    /// eviction): a walk-validated block OFF the current main chain and more
    /// than `offChainValidatedRetentionDepth` below the validated head is a
    /// candidate; the `maximumRetainedOffChainValidatedBlocks` nearest the head
    /// are kept and the rest demoted. Demotion flips the marker to weighed
    /// FIRST and then releases the owner pin (a crash between leaves an orphan
    /// pin that boot reclaims, never a marker pointing at evicted state), so the
    /// following unpinned pass reclaims exactly that block's body + post-state.
    /// Consensus facts, the accepted-block row and the batch-scoped boundary
    /// are untouched: the block stays accepted and served by CID, and if its
    /// fork returns the walk simply re-validates it. Canonical blocks are never
    /// demoted here.
    private func evictDemotableValidatedBlocks() async throws {
        guard case .active(let level) = runtimePhase,
              let validatedTip = await deepestValidatedMainChainTip(level: level)
        else { return }
        let policy = configuration.resourcePolicy
        let depth = UInt64(policy.offChainValidatedRetentionDepth)
        guard validatedTip.height > depth else { return }
        let candidateCeiling = validatedTip.height - depth
        var candidates: [(cid: String, height: UInt64)] = []
        for blockCID in try await store.walkValidatedBlockCIDs() {
            guard let height = await level.chain
                .getConsensusBlock(hash: blockCID)?.blockHeight,
                  height < candidateCeiling,
                  await level.chain.getMainChainBlockHash(atIndex: height)
                    != blockCID
            else { continue }
            candidates.append((blockCID, height))
        }
        // Nearest the head first; CID order only makes ties deterministic.
        candidates.sort { ($0.height, $0.cid) > ($1.height, $1.cid) }
        for candidate in candidates.dropFirst(
            policy.maximumRetainedOffChainValidatedBlocks
        ) {
            try await store.demoteValidated(blockCID: candidate.cid)
            try await broker.unpinAll(
                owner: Self.validatedOwner(retentionScope, candidate.cid)
            )
        }
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
#if DEBUG
                operationWaitersChanged()
#endif
            }
        }

        let acquired = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                operationWaiters.append(OperationWaiter(
                    id: id,
                    continuation: continuation
                ))
#if DEBUG
                operationWaitersChanged()
#endif
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
#if DEBUG
        operationWaitersChanged()
#endif
    }

    private func releaseOperation() {
        guard !operationWaiters.isEmpty else {
            operationInFlight = false
            return
        }
        operationWaiters.removeFirst().continuation.resume(returning: true)
#if DEBUG
        operationWaitersChanged()
#endif
    }

#if DEBUG
    /// Internal deterministic test seam for cancellation of queued mutations.
    func waitForOperationWaiterCount(_ expectedCount: Int) async {
        while operationWaiters.count != expectedCount {
            await withCheckedContinuation { continuation in
                operationWaiterChangeWaiters.append(continuation)
            }
        }
    }

    private func operationWaitersChanged() {
        let waiters = operationWaiterChangeWaiters
        operationWaiterChangeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
#endif

    private func validatedDirectChildDirectories(
        _ directories: [String]
    ) throws -> [String] {
        let canonical = Array(Set(directories)).sorted()
        guard canonical.count <= Self.maximumDirectChildRoutes,
              canonical.allSatisfy({ directory in
                  !directory.isEmpty
                      && !directory.contains("/")
                      && directory.utf8.count <= Int(UInt16.max)
                      && ChainAddress(
                          configuration.chainPath + [directory]
                      ) != nil
              }) else {
            throw ChainProcessError.malformedAuthenticatedChildProof
        }
        return canonical
    }

    private nonisolated static func pendingChildProofRoutes(
        carrierCID: String,
        directories: [String],
        parentGenesisLinks: [ParentGenesisLink] = []
    ) -> [PendingChildProofRoute] {
        Set(directories + parentGenesisLinks.map(\.directory))
            .sorted()
            .map {
                PendingChildProofRoute(
                    carrierCID: carrierCID,
                    directory: $0
                )
            }
    }

    /// Proof bytes authenticate the parent path. Child validation content is
    /// resolved from this child process's local or exact peer source.
    private nonisolated static func canonicalCarrierEvidence(
        _ header: BlockHeader,
        authenticatedPackage: AuthenticatedChildPackage?,
        fetcher: any Fetcher
    ) async throws -> AdmissionCarrierEvidence {
        guard let authenticatedPackage else {
            throw ChainProcessError.malformedAuthenticatedChildProof
        }
        let package = authenticatedPackage.package
        let child = try await resolvedCandidate(header, fetcher: fetcher)
        return AdmissionCarrierEvidence(
            proof: package.proof,
            childCID: try BlockHeader(node: child).rawCID
        )
    }

    private func acquirePendingChildProofs(
        carrier: BlockHeader,
        directories: [String],
        fetcher: any Fetcher
    ) async throws -> [String] {
        guard !directories.isEmpty else { return [] }
        let preparedDirectories = Set(
            try await store.preparedChildProofs(carrierCID: carrier.rawCID)
                .map(\.directory)
        )
        let retainedDirectories = Set(
            try await store.retainedDirectChildProofs(carrierCID: carrier.rawCID)
                .map(\.directory)
        )
        let availableDirectories = preparedDirectories.union(retainedDirectories)
        var prepared: [PreparedChildProof] = []
        var absent: [String] = []
        for directory in directories where !availableDirectories.contains(directory) {
            switch await Self.resolveDirectChildProof(
                carrier: carrier,
                directory: directory,
                fetcher: fetcher
            ) {
            case .absent:
                absent.append(directory)
            case .prepared(let proof):
                prepared.append(proof)
            case .unavailable:
                break
            }
        }
        try Task.checkCancellation()
        try await acquireMutationOperation()
        defer { releaseOperation() }
        let active = Set(try await store.pendingChildProofRoutes().lazy
            .filter { $0.carrierCID == carrier.rawCID }
            .map(\.directory))
            .intersection(directories)
        guard !active.isEmpty else { return [] }
        prepared = prepared.filter { active.contains($0.directory) }
        absent = Array(active.intersection(absent)).sorted()
        try Task.checkCancellation()
        try await store.persistPreparedChildProofs(
            carrierCID: carrier.rawCID,
            proofs: prepared,
            capacity: Self.preparedChildProofCapacity
        )
        try Task.checkCancellation()
        try await Self.promotePreparedChildProofsFromDurableEvidence(
            store: store,
            configuration: configuration,
            carrierCID: carrier.rawCID
        )
        try Task.checkCancellation()
        let retained = Set(try await store.retainedDirectChildProofs(
            carrierCID: carrier.rawCID
        ).map(\.directory))
        let completed = Array(active.intersection(
            Set(absent).union(retained)
        )).sorted()
        try await store.removePendingChildProofRoutes(
            carrierCID: carrier.rawCID,
            directories: completed
        )
        return completed
    }

    private nonisolated static func resolveDirectChildProof(
        carrier: BlockHeader,
        directory: String,
        fetcher: any Fetcher
    ) async -> TargetedChildProofResolution {
        do {
            let path: [[String]: ResolutionStrategy] = [
                ["children", directory]: .targeted,
            ]
            let resolvedCarrier = try await carrier.resolve(
                paths: path,
                fetcher: fetcher
            )
            guard let block = resolvedCarrier.node,
                  let children = block.children.node else {
                return .unavailable
            }
            guard let childHeader = try children.get(key: directory) else {
                return .absent
            }
            guard let child = childHeader.node else {
                return .unavailable
            }
            let proof = try await ChildBlockProof.generate(
                rootHeader: resolvedCarrier,
                childDirectory: directory,
                fetcher: fetcher
            )
            let isChildGenesis = child.parent == nil
            return .prepared(try PreparedChildProof(
                directory: directory,
                childCID: childHeader.rawCID,
                isChildGenesis: isChildGenesis,
                bootstrapRoots: [],
                proof: proof
            ))
        } catch {
            return .unavailable
        }
    }

    private func persistHierarchyArtifacts(
        _ link: ParentCarrierLink,
        carrierEvidence: AdmissionCarrierEvidence?,
        parentGenesisLinks: [ParentGenesisLink] = [],
        pendingChildProofRoutes: [PendingChildProofRoute]
    ) async throws {
        try Task.checkCancellation()
        try await store.persistIssuedHierarchyArtifacts(
            AdmissionHierarchyArtifacts(
                carrierLink: link,
                carrierEvidence: carrierEvidence,
                parentGenesisLinks: parentGenesisLinks
            ),
            pendingChildProofRoutes: pendingChildProofRoutes,
            pendingChildProofCapacity: Self.preparedChildProofCapacity
        )
    }

    private func promotePreparedChildProofs(
        carrierCID: String,
        upstreamProof: ChildBlockProof?
    ) async throws {
        try await Self.promotePreparedChildProofs(
            store: store,
            configuration: configuration,
            carrierCID: carrierCID,
            upstreamProof: upstreamProof
        )
    }

    private nonisolated static func promotePreparedChildProofs(
        store: NodeStore,
        configuration: NodeConfiguration,
        carrierCID: String,
        upstreamProof: ChildBlockProof?,
        additional: [PreparedChildProof] = []
    ) async throws {
        let retained = try await store.retainedDirectChildProofs(
            carrierCID: carrierCID
        )
        let newlyPrepared = try await store.preparedChildProofs(
            carrierCID: carrierCID
        )
        var byDirectory = Dictionary(
            uniqueKeysWithValues: retained.map { ($0.directory, $0) }
        )
        for prepared in newlyPrepared {
            if let existing = byDirectory[prepared.directory] {
                guard existing.childCID == prepared.childCID else {
                    throw ChainProcessError.malformedAuthenticatedChildProof
                }
            } else {
                byDirectory[prepared.directory] = prepared
            }
        }
        for prepared in additional {
            if let existing = byDirectory[prepared.directory] {
                guard existing.childCID == prepared.childCID else {
                    throw ChainProcessError.malformedAuthenticatedChildProof
                }
            } else {
                byDirectory[prepared.directory] = prepared
            }
        }
        for prepared in byDirectory.values.sorted(by: {
            $0.directory < $1.directory
        }) {
            if prepared.isChildGenesis,
               let parentStateCID = await prepared.proof.directHop()?
                    .parentStateCID,
               try await store.issuedParentGenesisLink(
                    directory: prepared.directory,
                    childGenesisCID: prepared.childCID,
                    parentStateCID: parentStateCID
               ) == nil {
                continue
            }
            let proof: ChildBlockProof
            if configuration.address.isNexus {
                guard upstreamProof == nil else {
                    throw ChainProcessError.malformedAuthenticatedChildProof
                }
                proof = prepared.proof
            } else {
                guard let upstreamProof else {
                    throw ChainProcessError.malformedAuthenticatedChildProof
                }
                proof = upstreamProof.composing(hop: prepared.proof)
            }
            guard try await store.issuedParentCarrierLink(
                carrierCID: carrierCID,
                rootCID: proof.rootCID
            ) != nil else {
                throw ChainProcessError.malformedAuthenticatedChildProof
            }
            if try await store.issuedChildEvidence(
                childCID: prepared.childCID,
                directory: prepared.directory,
                rootCID: proof.rootCID
            ) != nil {
                try await store.removePreparedChildProof(
                    carrierCID: carrierCID,
                    directory: prepared.directory
                )
                continue
            }
            let rootEnvelope = try ChildValidationPackageEnvelope(proof: proof)
            try Task.checkCancellation()
            try await store.persistIssuedChildProof(
                proof,
                childCID: prepared.childCID,
                isChildGenesis: prepared.isChildGenesis,
                bootstrapRoots: prepared.bootstrapRoots,
                parentCarrierCID: carrierCID,
                rootEnvelope: rootEnvelope
            )
            // The permanent direct edge now contains everything needed to
            // compose future roots. The preparation row was only a crash bridge.
            try await store.removePreparedChildProof(
                carrierCID: carrierCID,
                directory: prepared.directory
            )
        }
    }

    private nonisolated static func recoverPreparedChildProofs(
        store: NodeStore,
        configuration: NodeConfiguration
    ) async throws {
        var carrierCIDs = Set(try await store.preparedChildProofCarrierCIDs())
        if !configuration.address.isNexus {
            carrierCIDs.formUnion(
                try await store.uncomposedDirectChildProofCarrierCIDs(
                    parentDirectory: configuration.address.directory
                )
            )
        }
        for carrierCID in carrierCIDs.sorted() {
            try await promotePreparedChildProofsFromDurableEvidence(
                store: store,
                configuration: configuration,
                carrierCID: carrierCID
            )
        }
    }

    private nonisolated static func promotePreparedChildProofsFromDurableEvidence(
        store: NodeStore,
        configuration: NodeConfiguration,
        carrierCID: String,
        additional: [PreparedChildProof] = []
    ) async throws {
        if configuration.address.isNexus {
            guard try await store.issuedParentCarrierLink(
                carrierCID: carrierCID,
                rootCID: carrierCID
            ) != nil else { return }
            try await promotePreparedChildProofs(
                store: store,
                configuration: configuration,
                carrierCID: carrierCID,
                upstreamProof: nil,
                additional: additional
            )
            return
        }

        var afterRootCID: String?
        while true {
            let roots = try await store.incomingCarrierProofRoots(
                childCID: carrierCID,
                directory: configuration.address.directory,
                afterRootCID: afterRootCID,
                limit: 257
            )
            for rootCID in roots {
                let evidence = try await store.incomingCarrierEvidence(
                    childCID: carrierCID,
                    directory: configuration.address.directory,
                    rootCID: rootCID
                )
                guard let upstream = evidence?.proof else {
                    throw ChainProcessError.malformedAuthenticatedChildProof
                }
                try await promotePreparedChildProofs(
                    store: store,
                    configuration: configuration,
                    carrierCID: carrierCID,
                    upstreamProof: upstream,
                    additional: additional
                )
            }
            guard roots.count == 257, let last = roots.last else { break }
            afterRootCID = last
        }
    }

    /// Parent proof bytes are an attempt-local acquisition overlay. Cashew and
    /// Lattice content-bind every resolved CID; only verified admission paths
    /// copy useful sparse content into the durable NodeStore.
    nonisolated static func attemptContentSource(
        package: ChildValidationPackage?,
        fallback: any ContentSource
    ) throws -> any ContentSource {
        guard let package else { return fallback }
        var entries: [String: Data] = [:]
        for entry in package.proof.entries {
            if let existing = entries[entry.cid] {
                guard existing == entry.data else {
                    throw ChainProcessError.malformedAuthenticatedChildProof
                }
            } else {
                entries[entry.cid] = entry.data
            }
        }
        return OverlayContentSource(
            entries: entries,
            fallback: fallback
        )
    }

    nonisolated static func attemptFetcher(
        package: ChildValidationPackage?,
        fallback: any ContentSource
    ) throws -> CoalescingFetcher {
        CoalescingFetcher(try attemptContentSource(
            package: package,
            fallback: fallback
        ))
    }

    private nonisolated static func resolvedCandidate(
        _ header: BlockHeader,
        fetcher: any Fetcher
    ) async throws -> Block {
        guard let block = try await header.resolve(fetcher: fetcher).node else {
            throw ChainProcessError.malformedAuthenticatedChildProof
        }
        return block
    }

    nonisolated static func persist(
        _ batch: ChainAdmissionBatch,
        admissionStorage: NodeAdmissionStorage,
        store: NodeStore,
        broker: DiskBroker,
        retentionScope: String,
        pendingChildProofRoutes: [PendingChildProofRoute],
        pendingChildProofCapacity: Int,
        validated: Bool = true,
        hierarchyArtifacts: AdmissionHierarchyArtifacts? = nil,
        incomingCarrierEvidence: AdmissionCarrierEvidence? = nil,
        consensusRevisionFloor: UInt64? = nil,
        afterRetainingRoots: (@Sendable () async -> Void)? = nil
    ) async throws {
        let roots = await admissionStorage.takeStoredVolumeRoots()
        // Retaining an orphan is harmless; staging a batch without durable
        // retention is not. Once retention succeeds, the batch must finish:
        // cancellation between these writes would pin its roots until restart.
        try Task.checkCancellation()
        try await broker.mergeRetainedRoots(scope: retentionScope, roots: roots)
        if let afterRetainingRoots {
            await afterRetainingRoots()
        }
        // A failed stage may leave a retained orphan. That is deliberately
        // safer than a live exact rollback, which could unretain another
        // writer between its retention and reference commits. Startup removes
        // any such orphan while the process is quiescent.
        try await store.stage(
            batch,
            volumeRoots: roots,
            validated: validated,
            pendingChildProofRoutes: pendingChildProofRoutes,
            pendingChildProofCapacity: pendingChildProofCapacity,
            hierarchyArtifacts: hierarchyArtifacts,
            incomingCarrierEvidence: incomingCarrierEvidence,
            consensusRevisionFloor: consensusRevisionFloor
        )
    }

    private nonisolated static func nextConsensusRevision(
        _ revision: UInt64
    ) throws -> UInt64 {
        guard revision < .max else {
            throw ChainProcessError.consensusRevisionExhausted
        }
        return revision + 1
    }

    private nonisolated static func durableRetainedRoots(
        staged: [StagedAdmission],
        additionalRoots: [String] = []
    ) -> [String] {
        var roots = Set(staged.flatMap(\.volumeRoots))
        roots.formUnion(additionalRoots)
        return roots.sorted()
    }
}
