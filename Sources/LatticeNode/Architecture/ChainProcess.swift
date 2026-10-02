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
    /// The validated tier produced a batch that does not record execution.
    /// Recording one anyway would attest a state this node never produced.
    case validatedTierRecordedNoExecution
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

public struct NodeImportOutcome: Sendable {
    public let decision: NodeImportDecision
    public let sameChainPredecessor: SameChainPredecessorRequirement?
    let canonicalCommitReceipt: CanonicalCommitReceipt?
    /// For a block refused as not yet valid, the block's timestamp in
    /// milliseconds: the time a retry could decide it.
    let notBefore: Int64?
    /// For a `.proofOfWorkInvalid` block, whether the failure is the block's
    /// own: always on Nexus, and on a child chain only when the package's
    /// proof carries work to it. When the proof carries none, the failure is
    /// the proof's, which did not come from the block's supplier.
    let blockSupplierAtFault: Bool

    init(
        decision: NodeImportDecision,
        sameChainPredecessor: SameChainPredecessorRequirement?,
        canonicalCommitReceipt: CanonicalCommitReceipt? = nil,
        notBefore: Int64? = nil,
        blockSupplierAtFault: Bool = false
    ) {
        self.decision = decision
        self.sameChainPredecessor = sameChainPredecessor
        self.canonicalCommitReceipt = canonicalCommitReceipt
        self.notBefore = notBefore
        self.blockSupplierAtFault = blockSupplierAtFault
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

struct DurableLocalTransaction: Sendable {
    let transactionCID: String
    let addedAt: Int64
    let transaction: Transaction
}

/// One process owns one absolute chain path. Child processes have an explicit
/// pre-genesis phase that holds no local chain state.
public actor ChainProcess: ContentSource, Fetcher, VolumeStorer {
    enum RuntimePhase: Sendable {
        case awaitingGenesis
        case active(ChainLevel)
    }

    /// Page size for walking a child's incoming carrier-proof roots.
    private static let incomingCarrierProofRootPageSize = 257

    /// Owner pins holding a walk-validated block's body + post-state, one
    /// owner per block: `<retentionScope>:validated:<blockCID>`.
    nonisolated static func validatedOwnerPrefix(
        _ retentionScope: String
    ) -> String {
        retentionScope + ":validated:"
    }

    nonisolated static func validatedOwner(
        _ retentionScope: String,
        _ blockCID: String
    ) -> String {
        validatedOwnerPrefix(retentionScope) + blockCID
    }

    public nonisolated let configuration: NodeConfiguration

    let store: NodeStore
    let broker: DiskBroker
    let localFetcher: CoalescingFetcher
    let retentionScope: String
    private let durableMempoolOwner: String
    private let liveMempoolOwner: String
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

    private init(
        configuration: NodeConfiguration,
        store: NodeStore,
        broker: DiskBroker,
        localFetcher: CoalescingFetcher,
        retentionScope: String,
        durableMempoolOwner: String,
        liveMempoolOwner: String,
        directoryLock: StorageDirectoryLock,
        runtimePhase: RuntimePhase,
        bootHoleCeiling: UInt64?
    ) {
        self.configuration = configuration
        self.store = store
        self.broker = broker
        self.localFetcher = localFetcher
        self.retentionScope = retentionScope
        self.durableMempoolOwner = durableMempoolOwner
        self.liveMempoolOwner = liveMempoolOwner
        self.directoryLock = directoryLock
        self.runtimePhase = runtimePhase
        self.demotedHoleCeiling = bootHoleCeiling
    }

    /// Completes store validation, retained-root reconciliation, and recovery
    /// before returning a process that networking may expose.
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
            directoryLock: recovered.directoryLock,
            runtimePhase: recovered.runtimePhase,
            bootHoleCeiling: recovered.bootHoleCeiling
        )
    }

    func importBlock(
        _ blockHeader: BlockHeader,
        authenticatedChildPackage suppliedAuthenticatedChildPackage:
            AuthenticatedChildPackage? = nil,
        remoteSource: (any ContentSource)? = nil,
        mode: ImportMode = .full,
        canonicalCommitPublisher: CanonicalCommitPublisher? = nil
    ) async throws -> NodeImportOutcome {
        let authenticatedChildPackage: AuthenticatedChildPackage?
        if let supplied = suppliedAuthenticatedChildPackage {
            authenticatedChildPackage = supplied
        } else {
            authenticatedChildPackage = try await recoveredAuthenticatedChildPackage(
                for: blockHeader.rawCID
            )
        }

        let package = authenticatedChildPackage?.package
        let attemptFetcher = try Self.attemptFetcher(
            package: package,
            fallback: remoteSource.map {
                CompositeContentSource([broker, $0])
            } ?? broker
        )
        if case .active(let level) = runtimePhase {
            return try await importActive(
                blockHeader,
                level: level,
                authenticatedPackage: authenticatedChildPackage,
                attemptFetcher: attemptFetcher,
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
            return try await importActive(
                blockHeader,
                level: level,
                authenticatedPackage: authenticatedChildPackage,
                attemptFetcher: attemptFetcher,
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
            return NodeImportOutcome(
                decision: .unavailable(.childProof(
                    chainPath: configuration.chainPath,
                    childCID: blockHeader.rawCID
                )),
                sameChainPredecessor: nil
            )
        }
        // A child process can receive a valid successor attachment before its
        // genesis attachment. That is an ordering dependency, not malformed
        // genesis. Keep the authenticated candidate parked behind its direct
        // predecessor so ordinary same-chain wake-up admits it after bootstrap.
        // Nothing is persisted for it.
        let bootstrapCandidate = try await Self.resolvedCandidate(
            blockHeader,
            fetcher: attemptFetcher
        )
        if let predecessorCID = bootstrapCandidate.parent?.rawCID {
            return NodeImportOutcome(
                decision: .unavailable(nil),
                sameChainPredecessor: SameChainPredecessorRequirement(
                    descendantCID: blockHeader.rawCID,
                    predecessorCID: predecessorCID
                )
            )
        }
        let importStorage = NodeImportStorage(storage: broker)
        let carrierEvidence = try await Self.canonicalCarrierEvidence(
            blockHeader,
            authenticatedPackage: authenticatedChildPackage,
            chainPath: configuration.chainPath,
            fetcher: attemptFetcher
        )
        let stage: @Sendable (BlockImportStagingContext) async throws -> Void = {
            context in
            try Task.checkCancellation()
            try await Self.persist(
                context.batch,
                importStorage: importStorage,
                store: self.store,
                broker: self.broker,
                retentionScope: self.retentionScope,
                persistence: ImportPersistence(incomingCarrierEvidence: carrierEvidence)
            )
        }
        // A child genesis weighs by its proof and executes like any child
        // block, its continuity included; no parent record authorizes it.
        let result = try await ChainLevel.bootstrap(
            context: configuration.runtimeContext,
            genesisHeader: blockHeader,
            fetcher: attemptFetcher,
            childPackage: package,
            validationContentStorer: importStorage,
            materializedVolumeStorer: importStorage,
            stage: stage
        )
        let failure: BlockImportError
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
            return NodeImportOutcome(
                decision: .canonicalized(commit),
                sameChainPredecessor: nil,
                canonicalCommitReceipt: receipt
            )
        // A genesis this chain did not accept records nothing.
        case .rejected(let rejection):
            failure = rejection
        }
        releaseOperation()
        operationHeld = false
        return NodeImportOutcome(
            decision: Self.bootstrapDecision(failure),
            sameChainPredecessor: nil
        )
    }

    /// A bootstrap refusal blames no peer. A genesis that misses its own
    /// target is the content's fault, not its server's, so its
    /// `.proofOfWorkInvalid` is reported as a plain, blameless `.invalid`.
    nonisolated static func bootstrapDecision(
        _ failure: BlockImportError
    ) -> NodeImportDecision {
        let decision = NodeImportDecision(failure)
        return decision == .proofOfWorkInvalid ? .invalid : decision
    }

    /// Whether an admission decided the block: accepted (made durable by
    /// `stage`), a duplicate of one, or refused for a reason no retry would
    /// change — the grind that carried it missed this chain's target (which
    /// merged mining produces every round it clears only a deeper target),
    /// the block or its evidence is invalid, or this node could not verify
    /// it. Decided is exactly the set the candidate fetcher never retries, by
    /// the same predicate: what it would retry (evidence not yet held, a rule
    /// not yet met) is a deferral. A deferral persists nothing.
    static func isDecided(_ result: BlockImportResult) -> Bool {
        let decision = NodeImportDecision(result)
        return !(decision.shouldRetryWhenEvidenceChanges || decision.shouldRetryLater)
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
                limit: Self.incomingCarrierProofRootPageSize
            )
            result.append(contentsOf: roots)
            guard roots.count == Self.incomingCarrierProofRootPageSize,
                  let last = roots.last else { return result }
            afterRootCID = last
        }
    }

    private func importActive(
        _ blockHeader: BlockHeader,
        level: ChainLevel,
        authenticatedPackage: AuthenticatedChildPackage?,
        attemptFetcher: any Fetcher,
        mode: ImportMode = .full,
        canonicalCommitPublisher: CanonicalCommitPublisher?
    ) async throws -> NodeImportOutcome {
        let package = authenticatedPackage?.package
        let importStorage = NodeImportStorage(storage: broker)
        let preflight = try await level.preflightBlockImport(
            blockHeader,
            fetcher: attemptFetcher,
            childPackage: package,
            validationContentStorer: importStorage,
            mode: mode
        )
        // Keep all remote acquisition before the one serial durability lane.
        // A refused block records no evidence.
        let mayRecordEvidence: Bool
        switch preflight {
        case .ready, .duplicate:
            mayRecordEvidence = true
        case .terminal(let result):
            mayRecordEvidence = result.failure == nil
        }
        let carrierEvidence: ImportCarrierEvidence?
        if mayRecordEvidence, authenticatedPackage != nil {
            carrierEvidence = try await Self.canonicalCarrierEvidence(
                blockHeader,
                authenticatedPackage: authenticatedPackage,
                chainPath: configuration.chainPath,
                fetcher: attemptFetcher
            )
        } else {
            carrierEvidence = nil
        }
        let stage: @Sendable (BlockImportStagingContext) async throws -> Void = {
            context in
            try Task.checkCancellation()
            // Validated tier (deferred execution): the block was already weighed,
            // and its weighed block fact (empty stateDiff) is immutable and keyed
            // by blockHash only, so the validated fact's real stateDiff cannot
            // rewrite it. What a validate SUCCESS does stage is the standalone
            // `.validation` fact, which is keyed separately and so never collides:
            // it retains the freshly materialized post-state, appends that fact,
            // and flips the durable marker. The fact is not decoration —
            // `admission_batches` is the only recovery authority, so without it
            // execution would be forgotten on every restart and the chain would
            // attest nothing. A validate EXCLUSION is a brand-new fact and stages
            // normally.
            if case .execution = mode {
                let isExclusion = context.batch.facts.contains {
                    if case .exclusion = $0 { return true }
                    return false
                }
                if isExclusion {
                    try await Self.persist(
                        context.batch,
                        importStorage: importStorage,
                        store: self.store,
                        broker: self.broker,
                        retentionScope: self.retentionScope,
                        persistence: ImportPersistence(
                            consensusRevisionFloor: try Self.nextConsensusRevision(
                                await level.chain.currentRevision()
                            )
                        )
                    )
                } else {
                    // Take Lattice's own judgment rather than re-deriving it
                    // from the mode: Lattice appends the validation fact when it
                    // executed the transition, and inferring "this mode means
                    // executed" would silently become a forged-attestation
                    // primitive the day any non-executing outcome is added under
                    // `.execution`.
                    //
                    // Checked FIRST, before the pin and before any hierarchy
                    // artifact is written. Those artifacts are exactly what this
                    // node serves children as the binding it stands behind, and
                    // `persistIssuedHierarchyArtifacts` does not roll back — so
                    // a guard placed after them would let a non-executing
                    // outcome publish a child-visible binding and only then
                    // refuse. A refusal that lands after the evidence is durable
                    // is not a refusal.
                    let executed = context.batch.facts.contains { fact in
                        guard case .validation(let value) = fact else {
                            return false
                        }
                        return value.blockHash == blockHeader.rawCID
                    }
                    guard executed else {
                        throw ChainProcessError.validatedTierRecordedNoExecution
                    }
                    // Pin BEFORE flipping the marker: a crash between leaves an
                    // orphan pin that boot reclaims, never a marker without its
                    // state. The owner pin (not the batch-rebuilt retention
                    // scope) is what survives a restart.
                    let roots = await importStorage.takeStoredVolumeRoots()
                    try await self.broker.retain(roots,
                        owner: Self.validatedOwner(
                            self.retentionScope, blockHeader.rawCID
                        )
                    )
                    // Appended BEFORE the marker flips, for the same reason the
                    // pin goes first: a crash between leaves a block the walk
                    // simply re-validates (the fact is idempotent by id), never
                    // a marker whose fact was lost. The batch carries no volume
                    // roots — execution owns no new content, only the judgment.
                    //
                    // No revision floor: a validation carries no block and no
                    // work, so Lattice returns no commit for it and the chain's
                    // revision does not move. Advancing the durable floor here
                    // would push it past a revision the replayed chain never
                    // reaches.
                    try await self.store.stage(
                        BlockImportBatch.validation(
                            blockHash: blockHeader.rawCID
                        ),
                        volumeRoots: []
                    )
                    try await self.store.promoteValidated(
                        blockCID: blockHeader.rawCID
                    )
                }
                return
            }
            try await Self.persist(
                context.batch,
                importStorage: importStorage,
                store: self.store,
                broker: self.broker,
                retentionScope: self.retentionScope,
                persistence: ImportPersistence(
                    // A weighed admission enters fork choice on verified work
                    // but is not executed: record it below the validated tier
                    // so the validate-on-candidacy walk (and every act-on
                    // read) knows to execute it before building on it.
                    status: {
                        if case .header = mode { return .header }
                        return .executed
                    }(),
                    incomingCarrierEvidence: carrierEvidence,
                    consensusRevisionFloor: try Self.nextConsensusRevision(
                        await level.chain.currentRevision()
                    )
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
        let result: BlockImportResult
        switch preflight {
        case .terminal(let terminal):
            result = terminal
        case .duplicate(let token):
            result = try await level.resolveDuplicatePreflight(token)
        case .ready(let token):
            result = try await level.commitPreflight(
                token,
                materializedVolumeStorer: importStorage,
                stage: stage
            )
        }

        let decision = NodeImportDecision(result)
        let admissionStaged = result.commit != nil
        // Only an ACCEPTED block records its carrier evidence: a block this
        // chain refused has no reader here, so it writes no edge, proof, fact
        // or pin. A staged acceptance already wrote its evidence in `stage`.
        if !admissionStaged, decision.isAccepted, carrierEvidence != nil {
            try await store.persistIssuedHierarchyArtifacts(
                ImportHierarchyArtifacts(
                    blockCID: blockHeader.rawCID,
                    carrierEvidence: carrierEvidence
                )
            )
        }
        // Only a canonical change is published: a side block's commit leaves
        // the tip where it was and has nothing to reconcile.
        var receipt: CanonicalCommitReceipt?
        if let canonicalCommitPublisher,
           decision.shouldPublishCanonicalTip,
           let commit = result.commit {
            receipt = await canonicalCommitPublisher(commit)
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

        var notBefore: Int64?
        if decision == .temporarilyInvalid {
            notBefore = try? await Self.resolvedCandidate(
                blockHeader, fetcher: attemptFetcher
            ).timestamp
        }
        var blockSupplierAtFault = false
        if decision == .proofOfWorkInvalid {
            if configuration.address.isNexus {
                blockSupplierAtFault = true
            } else if let package,
                      let child = try? await Self.resolvedCandidate(
                        blockHeader, fetcher: attemptFetcher
                      ) {
                blockSupplierAtFault = await Self.proofWeighs(
                    package.proof,
                    child: child,
                    chainPath: configuration.chainPath
                )
            }
        }
        return NodeImportOutcome(
            decision: decision,
            sameChainPredecessor: result.sameChainPredecessor,
            canonicalCommitReceipt: receipt,
            notBefore: notBefore,
            blockSupplierAtFault: blockSupplierAtFault
        )
    }

    /// One page of this node's MAIN chain going forward from `afterCID` (a block
    /// the caller already holds): `[child(afterCID), …]`, genesis-ward first,
    /// with `hasMore` when the canonical chain extends past the page. Serves
    /// forward-apply sync so a receiver can apply a bounded page and page again,
    /// never buffering the whole gap. Empty when `afterCID` is not on our main
    /// chain or we have nothing after it.
    func forwardCanonicalRange(
        afterCID: String,
        limit: Int
    ) async -> (blockCIDs: [String], hasMore: Bool) {
        guard limit > 0, case .active(let level) = runtimePhase else {
            return ([], false)
        }
        guard let meta = await level.chain.getConsensusBlock(hash: afterCID),
              await level.chain.canonicalBlockHash(atHeight: meta.blockHeight) == afterCID
        else {
            return ([], false)
        }
        let highest = await level.chain.getHighestBlockHeight()
        var blockCIDs: [String] = []
        var height = meta.blockHeight + 1
        while blockCIDs.count < limit, height <= highest {
            guard let cid = await level.chain.canonicalBlockHash(atHeight: height) else {
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
    /// verified history. Same main-chain test as `forwardCanonicalRange`.
    func commonAncestorRange(
        locator: [String],
        limit: Int
    ) async -> (commonAncestor: String?, blockCIDs: [String], hasMore: Bool) {
        guard limit > 0, case .active(let level) = runtimePhase else {
            return (nil, [], false)
        }
        for cid in locator {
            guard let meta = await level.chain.getConsensusBlock(hash: cid),
                  await level.chain.canonicalBlockHash(atHeight: meta.blockHeight) == cid
            else { continue }
            let page = await forwardCanonicalRange(afterCID: cid, limit: limit)
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
    /// height index (same source as `forwardCanonicalRange`), so a by-height
    /// lookup never walks parents or touches the operation gate.
    func canonicalBlockCID(atHeight height: UInt64) async -> String? {
        guard case .active(let level) = runtimePhase else { return nil }
        return await level.chain.canonicalBlockHash(atHeight: height)
    }

    /// Height of the CURRENT canonical (weighed-inclusive) main-chain tip, or nil
    /// when not active. The validate-on-candidacy walk targets this: it executes
    /// forward from the deepest validated ancestor until the validated tier meets
    /// the canonical tier. Re-read every walk iteration so a mid-walk reorg or
    /// exclusion re-projection re-targets rather than chasing a stale frontier.
    func canonicalTipHeight() async -> UInt64? {
        await canonicalTip()?.height
    }

    /// The difficulty anchor carried for `hash`, inherited at admission and
    /// read in O(1). The block builder needs it to schedule `nextTarget`, and
    /// without it the builder falls back to walking the ancestry to height 1 --
    /// which is O(chain depth) per template, redone every mining round. Nil
    /// when not active or when the block is not in consensus state; the
    /// fallback still covers that.
    func difficultyAnchor(forBlockHash hash: String) async -> DifficultyAnchor? {
        guard case .active(let level) = runtimePhase else { return nil }
        return await level.chain.difficultyAnchor(forBlockHash: hash)
    }

    /// The CURRENT canonical (weighed-inclusive) main-chain tip as one
    /// (cid, height) pair, or nil when not active. The height is that CID's
    /// own — immutable — so the pair is consistent even if a reorg lands
    /// between the two consensus reads; a `canonicalTipHeight()` paired with
    /// a separate by-height CID lookup is not. Acquisition (the hello-reply
    /// advertisement, range-sync anchors) uses this; act-on reads use
    /// `status()` / the validated tip.
    func canonicalTip() async -> (cid: String, height: UInt64)? {
        guard case .active(let level) = runtimePhase else { return nil }
        let tip = await level.chain.canonicalTip
        guard let height = await level.chain.getConsensusBlock(hash: tip)?
            .blockHeight else { return nil }
        return (tip, height)
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
        #if DEBUG
        await localTransactionVolumeStoredForTesting?(volume.rawCID)
        #endif
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

    func storeContextualCandidate(
        _ header: BlockHeader,
        fetcher: any Fetcher,
        capacity: Int
    ) async throws {
        guard capacity > 0 else {
            throw ChainProcessError.malformedAuthenticatedChildProof
        }
        try await acquireMutationOperation()
        defer { releaseOperation() }

        if try await store.touchContextualCandidate(
            candidateCID: header.rawCID
        ) {
            return
        }

        let storage = NodeImportStorage(storage: broker)
        try await header.storeBlock(fetcher: fetcher, storer: storage)
        let roots = Array(Set(await storage.takeStoredVolumeRoots())).sorted()
        guard roots.contains(header.rawCID) else {
            throw ChainProcessError.malformedAuthenticatedChildProof
        }
        try await store.persistContextualCandidateRoots(
            candidateCID: header.rawCID,
            roots: roots,
            capacity: capacity
        )
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

    public func canonicalTipBlock() async throws -> Block {
        await acquireOperation()
        defer { releaseOperation() }
        guard case .active(let level) = runtimePhase else {
            throw ChainProcessError.chainNotBootstrapped
        }
        let tip = await level.chain.canonicalTip
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
    func deepestValidatedCanonicalTip() async -> (cid: String, height: UInt64)? {
        guard case .active(let level) = runtimePhase else { return nil }
        return await deepestValidatedCanonicalTip(level: level)
    }

    /// The last answer of `deepestValidatedCanonicalTip`. Validated main-chain
    /// blocks form a PREFIX (the walk validates forward from validated+1,
    /// self-mined blocks attach on the validated tip, a reorg leaves a
    /// validated prefix below the fork point), so the last answer is a floor:
    /// while that block is still the main-chain block at its height, only the
    /// delta above it needs reading — O(delta) per call instead of O(gap),
    /// which made draining a backlog O(gap²) and every gated `status()`
    /// O(gap). Any demotion on a live process (eviction) clears it, and a
    /// cached block that left the main chain, or whose marker is no longer
    /// validated when re-read, falls back to the full walk.
    private var validatedTipCache: (cid: String, height: UInt64)?
    private var servedRunDirectories: Set<String> = []
    /// The prefix assumption has one hole: a demoted block (eviction of an
    /// off-main-chain block; boot reconciliation of a marker whose owner pin
    /// is gone) can sit on the main chain BENEATH still-validated blocks —
    /// eviction keeps the retained blocks nearest the head, above the ones it
    /// demotes, and two forks demote at different heights. This is the
    /// HIGHEST height ever demoted on this process (eviction here; `open`
    /// seeds it from boot reconciliation). The fast path is taken only while
    /// the cached floor sits at or above it: with no demotion above the
    /// floor, validated-on-main is contiguous above it and the up-walk is
    /// exact; a floor below any hole takes the full downward walk instead
    /// (an up-walk would stop at the hole and under-report the true top).
    /// The mark is never cleared; the ceiling tracks the head, where
    /// eviction happens, so the floor is normally above it and O(delta)
    /// holds.
    private var demotedHoleCeiling: UInt64?
    #if DEBUG
    // Test seam: store reads made by the validated-tip probe.
    private var validatedTipStoreReads = 0
    func validatedTipStoreReadsForTesting() -> Int { validatedTipStoreReads }
    func resetValidatedTipStoreReadsForTesting() { validatedTipStoreReads = 0 }
    /// Test seam: demote a block's marker WITHOUT touching the probe's cache,
    /// the stale-floor race an ungated probe could otherwise resurrect.
    func demoteValidatedForTesting(_ cid: String) async throws {
        try await store.demoteValidated(blockCID: cid)
    }
    /// Test seam: drop a walk-validated block's owner pin, the state boot
    /// reconciliation demotes at the next open.
    func unpinValidatedOwnerForTesting(_ cid: String) async throws {
        try await broker.advanceRetainedRoots(scope: Self.validatedOwner(retentionScope, cid), roots: [])
    }
    /// Test seam: awaited in `persistLocalTransaction` once the transaction
    /// Volume is stored, before its pin and its SQLite reference.
    private var localTransactionVolumeStoredForTesting:
        (@Sendable (String) async -> Void)?
    func setLocalTransactionVolumeStoredForTesting(
        _ hook: (@Sendable (String) async -> Void)?
    ) {
        localTransactionVolumeStoredForTesting = hook
    }
    #endif

    private func storeBlockValidated(_ cid: String) async -> Bool {
        #if DEBUG
        validatedTipStoreReads += 1
        #endif
        return (try? await store.blockValidated(cid)) == true
    }

    private func deepestValidatedCanonicalTip(
        level: ChainLevel
    ) async -> (cid: String, height: UInt64)? {
        await validatedTipWalk(level: level)?.validated
    }

    /// `deepestValidatedCanonicalTip` together with the canonical tip height
    /// the walk started from, which the validated height never exceeds.
    private func validatedTipWalk(
        level: ChainLevel
    ) async -> (tipHeight: UInt64, validated: (cid: String, height: UInt64)?)? {
        let tip = await level.chain.canonicalTip
        guard let tipHeight = await level.chain
            .getConsensusBlock(hash: tip)?.blockHeight
        else { return nil }
        // Fast path: the floor is at or above every demotion hole, still the
        // main-chain block at its height, and — re-read, since an ungated
        // probe may race an eviction that cleared the cache under the gate —
        // still validated.
        if let cached = validatedTipCache, cached.height <= tipHeight,
           demotedHoleCeiling.map({ cached.height >= $0 }) ?? true,
           await level.chain.canonicalBlockHash(atHeight: cached.height)
            == cached.cid,
           await storeBlockValidated(cached.cid) {
            // Walk UP from the cached floor while the next main-chain block
            // is validated.
            var best = cached
            while best.height < tipHeight {
                let next = best.height + 1
                guard let cid = await level.chain.canonicalBlockHash(
                    atHeight: next
                ), await storeBlockValidated(cid) else { break }
                best = (cid, next)
            }
            validatedTipCache = best
            return (tipHeight, best)
        }
        // Full downward walk: the first validated block from the top.
        var height = tipHeight
        while true {
            if let cid = await level.chain.canonicalBlockHash(atHeight: height),
               await storeBlockValidated(cid) {
                validatedTipCache = (cid, height)
                return (tipHeight, (cid, height))
            }
            if height == 0 {
                // The chain's own genesis is executed by construction — the
                // restore seeds it as trusted, so Lattice's executed frontier
                // holds it even when the store's marker was demoted. Without
                // this the walk would target height 0 forever, and on the
                // root chain that verdict is parked (§9.9), never staged.
                if let cid = await level.chain.canonicalBlockHash(atHeight: 0),
                   await level.chain.hasExecutedAncestry(blockHash: cid) {
                    validatedTipCache = (cid, 0)
                    return (tipHeight, (cid, 0))
                }
                validatedTipCache = nil
                return (tipHeight, nil)
            }
            height -= 1
        }
    }

    /// `validatedTipBlock` without the operation gate, for a co-hosted
    /// child's candidate rebuild (`ParentLevel.validatedTip`, §2.4): the
    /// same ungated walk `readSnapshot` makes, resolved from local content.
    func ungatedValidatedTip() async -> (cid: String, block: Block)? {
        guard let validated = await deepestValidatedCanonicalTip(),
              let block = try? await BlockHeader(
                  rawCID: validated.cid, node: nil, encryptionInfo: nil
              ).resolve(fetcher: localFetcher).node else { return nil }
        return (validated.cid, block)
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
              let validated = await deepestValidatedCanonicalTip(level: level)
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
        // Against the validated tip — the block admission and templates
        // build on, and the tip `status()` reports — never the weighed
        // canonical tip, whose post-state this node has not executed
        // (Lattice classifies an unexecuted tip as unavailable).
        return await level.preflightTransaction(
            transaction,
            at: await deepestValidatedCanonicalTip(level: level)?.cid,
            parentState: parentState,
            fetcher: fetcher ?? localFetcher
        )
    }

    /// Did this chain PRODUCE this state? — the one continuity question the
    /// protocol asks, and the only one this node answers for a peer.
    ///
    /// Every child block anchors its `parentState` at the parent chain's
    /// genesis, so Lattice builds exactly one shape of continuity requirement:
    /// `from` is always `emptyHeader` (`validateParentFacts`, the single
    /// construction site). That shape is answered outright by the
    /// executed-from-genesis frontier, without walking the chain and
    /// independently of HEIGHT — which is what mattered, since the removed
    /// visit budget existed precisely because cost grew with height. Not
    /// literally O(1): the frontier check scans the blocks DECLARING that
    /// post-state, and the weighed tier records a declared post-state without
    /// executing it, so that bucket can be grown — at one proof-of-work solve
    /// per entry, against a query already capped at one in flight per peer.
    ///
    /// Asking it as a general `from`→`to` reachability query is what made it
    /// expensive, and the expense was never something an honest peer imposed:
    /// no child can need a non-genesis `from`, so the only way to reach the
    /// ancestry walk was to craft a request for it. A budget would have
    /// truncated the ANSWER (making the same question answerable here and
    /// unanswerable on an identically-stocked peer), and a rate limit would
    /// have rationed a cost no correct caller creates — bounding arrivals while
    /// leaving each one unbounded. Neither is needed once the node simply does
    /// not serve a question the protocol never asks: the bound is structural,
    /// not a policy, so every honest node answers identically.
    func hasProducedParentState(_ stateCID: String) async -> Bool {
        guard case .active(let level) = runtimePhase else { return false }
        return await level.chain.hasStateContinuity(
            from: LatticeState.emptyHeader.rawCID,
            to: stateCID
        )
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
        let validated = await deepestValidatedCanonicalTip(level: level)
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
        let validated = await deepestValidatedCanonicalTip(level: level)
        return ChainProcessStatus(
            phase: .active,
            chainPath: configuration.chainPath,
            nexusGenesisCID: configuration.nexusGenesisCID,
            tipCID: validated?.cid,
            height: validated?.height,
            revision: await level.chain.currentRevision()
        )
    }

    // MARK: - Parent-attributed run work (§9.10)

    /// Start keeping runs for `directory`: this process hosts a child chain
    /// there (Lattice §9.10: which directories a node serves is its own
    /// choice). Idempotent; the served set is NOT persisted (Lattice's lives
    /// in memory), so the host re-serves after every restart. One whole-graph
    /// walk per directory, on the consensus actor. Takes no operation gate,
    /// but callers treat it as one that may: never call it from inside a
    /// child level's lease (`ChainHost`).
    func serveRuns(for directory: String) async {
        guard case .active(let level) = runtimePhase,
              !servedRunDirectories.contains(directory)
        else { return }
        await level.chain.serveRuns(for: directory)
        servedRunDirectories.insert(directory)
    }

    func servedRunDirectoryList() -> [String] {
        servedRunDirectories.sorted()
    }

    /// This chain's tree, for a co-hosted child level to derive its parent
    /// runs from (`ParentLevel.runTree`). Gate-free. Nil until active.
    func runTree() async -> ChainTree? {
        guard case .active(let level) = runtimePhase else { return nil }
        return await level.chain.tree
    }

    /// Per directory, the child block the branch through `tipCID` last
    /// committed into it: the nearest committer's commitment, read from
    /// the durable block facts, so it follows the branch under a reorg.
    /// Only directories this chain serves runs for are answered; the rest
    /// are absent, never "none".
    func carriedChildBlocks(
        on tipCID: String,
        directories: [String]
    ) async -> [String: String] {
        guard case .active(let level) = runtimePhase, !directories.isEmpty,
              await level.chain.getConsensusBlock(hash: tipCID) != nil
        else { return [:] }
        var carried: [String: String] = [:]
        var carriers: [String: BlockMeta?] = [:]
        for directory in directories {
            guard let carrier = await level.chain.nearestCarrier(
                of: tipCID, directory: directory
            ) else { continue }
            if carriers[carrier] == nil {
                carriers[carrier] = await level.chain.getConsensusBlock(hash: carrier)
            }
            if let child = carriers[carrier]??.childCommitments[directory] {
                carried[directory] = child
            }
        }
        return carried
    }

    /// Credit this chain with its co-hosted parent's attributed runs (§9.10),
    /// derived from the parent's tree (which serves this directory) and never
    /// persisted: every run is derived again, so neither arrival order nor a
    /// restart loses a credit. Returns whether any block's weight rose; a
    /// canonical change is published like any admission's.
    func applyParentRuns(
        from parent: ChainTree,
        canonicalCommitPublisher: CanonicalCommitPublisher? = nil
    ) async throws -> Bool {
        guard case .active(let level) = runtimePhase,
              let directory = configuration.chainPath.last,
              !configuration.address.isNexus else { return false }
        try await acquireMutationOperation()
        defer { releaseOperation() }
        let applied = await level.chain.applyParentRun(from: parent, directory: directory)
        if let commit = applied.commit, commit.canonicalChanged, let canonicalCommitPublisher {
            _ = await canonicalCommitPublisher(commit)
        }
        return !applied.raised.isEmpty
    }

    /// Ungated tip heights for `/metrics`, from ONE validated-tip walk: the
    /// validated height and the canonical (weighed-inclusive) tip height the
    /// walk started from, so a scrape never shows validated above weighed.
    func metricsTipHeights() async -> (validated: UInt64?, weighed: UInt64?) {
        guard case .active(let level) = runtimePhase else { return (nil, nil) }
        let walk = await validatedTipWalk(level: level)
        return (walk?.validated?.height, walk?.tipHeight)
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

    public func pruneUnpinnedVolumes() async throws -> Int {
        try await acquireMutationOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        try await evictDemotableValidatedBlocks()
        return try await broker.sweep()
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
              let validatedTip = await deepestValidatedCanonicalTip(level: level)
        else { return }
        let policy = configuration.resourcePolicy
        let depth = UInt64(policy.offChainValidatedRetentionDepth)
        guard validatedTip.height > depth else { return }
        let candidateCeiling = validatedTip.height - depth
        var candidates: [(cid: String, height: UInt64)] = []
        for blockCID in try await store.executedAndPinnedBlockCIDs() {
            guard let height = await level.chain
                .getConsensusBlock(hash: blockCID)?.blockHeight,
                  height < candidateCeiling,
                  await level.chain.canonicalBlockHash(atHeight: height)
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
            validatedTipCache = nil
            demotedHoleCeiling = max(
                demotedHoleCeiling ?? candidate.height, candidate.height
            )
            try await broker.advanceRetainedRoots(
                scope: Self.validatedOwner(retentionScope, candidate.cid), roots: []
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

    /// Proof bytes authenticate the parent path. Child validation content is
    /// resolved from this child process's local or exact peer source.
    /// `weighs`: the proof contributes work to the child, the objective
    /// predicate for entering the child-evidence index.
    private nonisolated static func canonicalCarrierEvidence(
        _ header: BlockHeader,
        authenticatedPackage: AuthenticatedChildPackage?,
        chainPath: [String],
        fetcher: any Fetcher
    ) async throws -> ImportCarrierEvidence {
        guard let authenticatedPackage else {
            throw ChainProcessError.malformedAuthenticatedChildProof
        }
        let package = authenticatedPackage.package
        let child = try await resolvedCandidate(header, fetcher: fetcher)
        return ImportCarrierEvidence(
            proof: package.proof,
            childCID: try BlockHeader(node: child).rawCID,
            weighs: await Self.proofWeighs(
                package.proof, child: child, chainPath: chainPath
            )
        )
    }

    private nonisolated static func proofWeighs(
        _ proof: ChildBlockProof,
        child: Block,
        chainPath: [String]
    ) async -> Bool {
        guard case .success(let verified) = await proof.verifySecuringWork(
            child: child,
            chainPath: chainPath
        ) else { return false }
        return verified.contribution != nil
    }

    /// The child-evidence index's root; nil while it is empty.
    func childEvidenceRoot() async throws -> String? {
        try await store.childEvidenceRoot()
    }

    /// Reads this process's own Volumes: the child-evidence index a peer's
    /// root is compared against.
    nonisolated var childEvidenceFetcher: any Fetcher { localFetcher }

    /// Whether `proof` contributes work to the child block `childCID`, or
    /// nil when that block is not held locally and it cannot be judged.
    func childEvidenceWeighs(
        _ proof: ChildBlockProof,
        childCID: String
    ) async -> Bool? {
        guard let child = try? await BlockHeader(
            rawCID: childCID, node: nil, encryptionInfo: nil
        ).resolve(fetcher: localFetcher).node else { return nil }
        return await Self.proofWeighs(
            proof, child: child, chainPath: configuration.chainPath
        )
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
        _ batch: BlockImportBatch,
        importStorage: NodeImportStorage,
        store: NodeStore,
        broker: DiskBroker,
        retentionScope: String,
        persistence: ImportPersistence,
        afterRetainingRoots: (@Sendable () async -> Void)? = nil
    ) async throws {
        let roots = await importStorage.takeStoredVolumeRoots()
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
            persistence: persistence
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
}
