import Foundation
import Ivy
import Lattice
import UInt256
import VolumeBroker
import cashew

public struct SubmitTransactionRequest: Codable, Sendable {
    public let transaction: Transaction

    public init(transaction: Transaction) {
        self.transaction = transaction
    }

    private enum CodingKeys: String, CodingKey {
        case transaction
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transaction = try container.decode(
            ContentBoundTransaction.self,
            forKey: .transaction
        ).transaction()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            ContentBoundTransaction(transaction: transaction),
            forKey: .transaction
        )
    }
}

public struct SubmitTransactionResponse: Codable, Sendable, Equatable {
    public let transactionCID: String
    public let mempoolCount: Int
    public let mempoolBytes: Int
}

/// One externally signed reward transaction for one absolute chain path.
/// Process identity is never accepted as, or converted into, wallet identity.
public struct MiningReward: Codable, Sendable {
    public let chainPath: [String]
    public let transaction: Transaction

    public init(chainPath: [String], transaction: Transaction) {
        self.chainPath = chainPath
        self.transaction = transaction
    }

    private enum CodingKeys: String, CodingKey {
        case chainPath
        case transaction
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chainPath = try container.decode([String].self, forKey: .chainPath)
        transaction = try container.decode(
            ContentBoundTransaction.self,
            forKey: .transaction
        ).transaction()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(chainPath, forKey: .chainPath)
        try container.encode(
            ContentBoundTransaction(transaction: transaction),
            forKey: .transaction
        )
    }
}

public enum MiningMode: String, Codable, Sendable, Equatable {
    case normal
    case deployment
}

public struct MiningTemplateRequest: Codable, Sendable {
    public let rewards: [MiningReward]
    public let mode: MiningMode

    public init(
        rewards: [MiningReward] = [],
        mode: MiningMode = .normal
    ) {
        self.rewards = rewards
        self.mode = mode
    }

    private enum CodingKeys: String, CodingKey {
        case rewards
        case mode
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rewards = try container.decodeIfPresent(
            [MiningReward].self,
            forKey: .rewards
        ) ?? []
        mode = try container.decodeIfPresent(
            MiningMode.self,
            forKey: .mode
        ) ?? .normal
    }
}

public struct MiningTemplateResponse: Codable, Sendable {
    public let workID: String
    public let block: Block
    public let searchTarget: UInt256
    public let chainPath: [String]
    public let expiresInMilliseconds: UInt64

    init(
        template: MiningTemplate,
        maximumLifetimeMilliseconds: UInt64
    ) {
        workID = template.workID
        block = template.block
        searchTarget = template.searchTarget
        chainPath = template.chainPath
        expiresInMilliseconds = min(
            maximumLifetimeMilliseconds,
            template.remainingLifetimeMilliseconds
        )
    }
}

public struct SubmitWorkRequest: Codable, Sendable, Equatable {
    public let workID: String
    public let nonce: UInt64

    public init(workID: String, nonce: UInt64) {
        self.workID = workID
        self.nonce = nonce
    }
}

public enum WorkDisposition: String, Codable, Sendable {
    case canonicalized
    case acceptedSide
    case carrier
    case duplicate
    case unavailable
    case temporarilyInvalid
    case invalid
    case localFailure
}

public struct SubmitWorkResponse: Codable, Sendable {
    public let accepted: Bool
    public let disposition: WorkDisposition
    public let tipCID: String?
    public let parentCarrierLink: ParentCarrierLink?
    public let parentGenesisLinks: [ParentGenesisLink]
    public let durableChildProofs: [DirectChildProofSummary]
}

/// Bounded miner-facing acknowledgement. Proof bytes stay on the authenticated
/// hierarchy plane.
public struct DirectChildProofSummary: Codable, Sendable, Equatable {
    public let directory: String
    public let childCID: String

    public init(directory: String, childCID: String) {
        self.directory = directory
        self.childCID = childCID
    }
}

/// Internal publication passed directly to the hierarchy runtime. Deliberately
/// not Codable so it cannot accidentally become an HTTP DTO.
public struct DirectChildProofPublication: Sendable {
    public let directory: String
    public let childCID: String
    public let proof: ChildBlockProof
}

/// The runtime requests authenticated direct-child candidates against this
/// exact provisional carrier. It owns the bounded deadline and returns partial
/// success when only some children respond.
public struct ChildCandidateRequestContext: Sendable {
    public let parentCarrier: Block
    public let rewards: [MiningReward]
    public let mode: MiningMode
    public let excludedDirectories: Set<String>

    public init(
        parentCarrier: Block,
        rewards: [MiningReward],
        mode: MiningMode = .normal,
        excludedDirectories: Set<String> = []
    ) {
        self.parentCarrier = parentCarrier
        self.rewards = rewards
        self.mode = mode
        self.excludedDirectories = excludedDirectories
    }
}

public typealias ChildCandidateProvider = @Sendable (
    ChildCandidateRequestContext
) async throws
    -> [DirectChildCandidate]
public typealias ChildCandidateReservationReconciler = @Sendable (
    ChildCandidateReservationUpdate
) async -> Bool
public typealias ChildProofPublisher = @Sendable (
    DirectChildProofPublication
) async throws -> Void
public typealias AcceptedBlockPublisher = @Sendable (_ blockCID: String) async throws -> Void
public typealias AcceptedTransactionPublisher = @Sendable (
    _ volumeRootCID: String
) async throws -> Void

private struct AdmissionEffects: Sendable {
    let parentGenesisLinks: [ParentGenesisLink]
}

/// Creates an ordinary direct-child genesis bound to the current parent state.
/// Its signed parent anchor is submitted later through `submitTransaction`.
public struct ChildDeployIntentRequest: Codable, Sendable {
    public let directory: String
    public let spec: ChainSpec
    public let genesisTransactions: [Transaction]
    public let policyModules: [ContentBoundWasmPolicyModule]
    public let target: UInt256
    public let timestamp: Int64

    public init(
        directory: String,
        spec: ChainSpec,
        genesisTransactions: [Transaction],
        policyModules: [ContentBoundWasmPolicyModule] = [],
        target: UInt256,
        timestamp: Int64
    ) {
        self.directory = directory
        self.spec = spec
        self.genesisTransactions = genesisTransactions
        self.policyModules = policyModules
        self.target = target
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case directory
        case spec
        case genesisTransactions
        case policyModules
        case target
        case timestamp
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        directory = try container.decode(String.self, forKey: .directory)
        spec = try container.decode(ChainSpec.self, forKey: .spec)
        genesisTransactions = try container.decode(
            [ContentBoundTransaction].self,
            forKey: .genesisTransactions
        ).map { try $0.transaction() }
        policyModules = try container.decodeIfPresent(
            [ContentBoundWasmPolicyModule].self,
            forKey: .policyModules
        ) ?? []
        target = try container.decode(UInt256.self, forKey: .target)
        timestamp = try container.decode(Int64.self, forKey: .timestamp)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(directory, forKey: .directory)
        try container.encode(spec, forKey: .spec)
        try container.encode(
            genesisTransactions.map {
                try ContentBoundTransaction(transaction: $0)
            },
            forKey: .genesisTransactions
        )
        try container.encode(policyModules, forKey: .policyModules)
        try container.encode(target, forKey: .target)
        try container.encode(timestamp, forKey: .timestamp)
    }
}

public struct ChildDeployIntentResponse: Codable, Sendable {
    public let directory: String
    public let chainPath: [String]
    public let genesisCID: String
    public let genesisBlock: Block
    public let parentStateCID: String
}

public enum ChainServicePhase: String, Codable, Sendable {
    case awaitingGenesis
    case active
}

public struct ChainServiceStatusResponse: Codable, Sendable, Equatable {
    public let phase: ChainServicePhase
    public let chainPath: [String]
    public let nexusGenesisCID: String
    public let tipCID: String?
    public let height: UInt64?
    public let revision: UInt64?
    public let mempoolCount: Int
    public let mempoolBytes: Int
    public let pendingChildIntents: Int
}

public enum ChainServiceError: Error, Equatable, Sendable {
    case unresolvedChainSpec
    case invalidRewardTransaction
    case invalidRewardPlan
    case rewardPlanTooLarge
    case requestTooLarge
    case invalidChildDirectory
    case invalidChildGenesis
    case invalidChildPolicyModules
    case childIntentTooLarge
    case childIntentLimitReached
    case childCandidateLimitReached
    case invalidParentCarrier
    case parentCarrierRequired
    case unresolvedTransactionContent
    case templateContextChanged
    case invalidWorkID
    case timestampOverflow
    case templateTooLarge
    case noDeploymentAvailable
    case mempoolUnavailable
    case parentUnavailable
    case childCandidateReservationFailed
}

/// Transport-independent operations for one path. A future HTTP layer only
/// decodes a bounded DTO, calls this actor, and encodes the response.
public actor ChainService {
    private struct ChildIntent: Sendable {
        let directory: String
        let chainPath: [String]
        let genesisCID: String
        let genesis: Block
        let parentStateCID: String
        let volumeRoots: Set<String>
    }

    private struct Anchor: Hashable {
        let directory: String
        let genesisCID: String
    }

    private struct ValidatedRewardPlan {
        let current: Transaction?
        let descendants: [MiningReward]
    }

    private struct FittingMiningTemplate {
        let template: MiningTemplate
        let deploymentTransactionAdvance: Int
        let advancesDeploymentChild: Bool
    }

    private struct QueuedCanonicalCommit: Sendable {
        let commit: ChainCommit
        let receipt: CanonicalCommitReceipt
    }

    private enum OperationWaiter {
        case caller(CheckedContinuation<Void, Never>)
        case canonicalCommit
    }

    // Wire-field caps bound parse work by the structural wire capacity, not an
    // invented sub-capacity constant. The authoritative check decides validity —
    // a directory atom's consensus grammar (Lattice accepts up to the same wire
    // capacity, so a 64-byte cap here would reject candidates consensus considers
    // valid), a signature's crypto verification, a workID's template lookup — and
    // the reward-plan BYTE cap already bounds how many entries fit, so no invented
    // reward/signature COUNT cap is imposed on top of it.
    private static let maximumWorkIDBytes = _wireAtomCapacity
    private static let maximumDirectoryBytes = _wireAtomCapacity
    private static let maximumSignatureFieldBytes = _wireAtomCapacity
    private static let maximumRewardPlanBytes =
        ChainServiceLimits.maximumPayloadBytes
    private static let maximumChildIntents = 64
    private static let maximumChildIntentBytes =
        ChainServiceLimits.maximumChildIntentPayloadBytes
    private static let templateLifetimeSeconds: Int64 = 30
    private static let templateLifetimeMilliseconds: UInt64 = 30_000
    private static let templateCapacity = 16
    private static let maximumReadResponseBytes = Int(IvyConfig.defaultProtocolMaxFrameSize)

    private let process: ChainProcess
    private let pool: TransactionPool
    private let templates: MiningTemplateBook
    private let childCandidateProvider: ChildCandidateProvider
    private let childCandidateReservationReconciler:
        ChildCandidateReservationReconciler
    private let childProofPublisher: ChildProofPublisher
    private let acceptedBlockPublisher: AcceptedBlockPublisher
    private let acceptedTransactionPublisher: AcceptedTransactionPublisher
    private let maximumChildCandidates: Int
    private var childIntents: [String: ChildIntent] = [:]
    private var deploymentTransactionCursor = 0
    private var deploymentChildCursor = 0
    private var deploymentSourceCursor = 0
    private var liveMempoolRoots = Set<String>()
    private var mempoolUnavailable = false
    private var canonicalCommitQueue: [QueuedCanonicalCommit] = []
    private var canonicalCommitWorker: Task<Void, Never>?
    private var canonicalCommitWorkerReserved = false
    private var transactionPublications = Set<String>()
    private var transactionPublicationWorker: Task<Void, Never>?

    // This actor calls other actors and is therefore reentrant. Keep its pool,
    // template cache, and pending intents in one externally observable order.
    private var operationInFlight = false
    private var operationWaiters: [OperationWaiter] = []

    public init(
        process: ChainProcess,
        childCandidateProvider: @escaping ChildCandidateProvider,
        childCandidateReservationReconciler:
            @escaping ChildCandidateReservationReconciler = {
                $0.reservations.isEmpty && $0.handoffs.isEmpty
            },
        childProofPublisher: @escaping ChildProofPublisher,
        acceptedBlockPublisher: @escaping AcceptedBlockPublisher,
        acceptedTransactionPublisher: @escaping AcceptedTransactionPublisher = { _ in },
        mempoolMaxCount: Int = 10_000,
        mempoolMaxNonReadyPerSigner: Int = 64,
        maximumChildCandidates: Int = 64
    ) {
        precondition(
            mempoolMaxCount > 0 && mempoolMaxNonReadyPerSigner > 0
                && maximumChildCandidates > 0
        )
        self.process = process
        self.childCandidateProvider = childCandidateProvider
        self.childCandidateReservationReconciler =
            childCandidateReservationReconciler
        self.childProofPublisher = childProofPublisher
        self.acceptedBlockPublisher = acceptedBlockPublisher
        self.acceptedTransactionPublisher = acceptedTransactionPublisher
        self.pool = TransactionPool(
            maxCount: mempoolMaxCount,
            maxBytes: 64 * 1024 * 1024,
            maxNonReadyPerSigner: mempoolMaxNonReadyPerSigner
        )
        self.templates = MiningTemplateBook(
            chainPath: process.configuration.chainPath,
            lifetime: .seconds(Self.templateLifetimeSeconds),
            capacity: Self.templateCapacity
        )
        self.maximumChildCandidates = maximumChildCandidates
    }

    public func status() async -> ChainServiceStatusResponse {
        await acquireOperation()
        defer { releaseOperation() }
        let mempoolAvailable = (try? await prepareMempoolLocked()) != nil
        let status = await process.status()
        if status.phase == .active,
           let tip = try? await process.canonicalTipBlock() {
            try? await removeStaleChildIntents(
                parentStateCID: tip.postState.rawCID
            )
        }
        let phase: ChainServicePhase = status.phase == .active
            ? .active
            : .awaitingGenesis
        return ChainServiceStatusResponse(
            phase: phase,
            chainPath: status.chainPath,
            nexusGenesisCID: status.nexusGenesisCID,
            tipCID: status.tipCID,
            height: status.height,
            revision: status.revision,
            mempoolCount: mempoolAvailable ? await pool.count : 0,
            mempoolBytes: mempoolAvailable ? await pool.byteCount : 0,
            pendingChildIntents: childIntents.count
        )
    }

    /// Ungated mirror of `status()` for public read RPC: no `acquireOperation()`,
    /// no `prepareMempoolLocked()` (which mutates the pool via `pool.expire()`),
    /// no `removeStaleChildIntents()` — every read is non-mutating.
    public func readSnapshot() async -> ChainServiceStatusResponse {
        let status = await process.readSnapshot()
        let phase: ChainServicePhase = status.phase == .active
            ? .active
            : .awaitingGenesis
        return ChainServiceStatusResponse(
            phase: phase,
            chainPath: status.chainPath,
            nexusGenesisCID: status.nexusGenesisCID,
            tipCID: status.tipCID,
            height: status.height,
            revision: status.revision,
            mempoolCount: await pool.count,
            mempoolBytes: await pool.byteCount,
            pendingChildIntents: childIntents.count
        )
    }

    /// Bounded public read: a decoded, content-verified block, gated to only
    /// what this node has durably accepted. Never takes the operation gate —
    /// reads only ChainProcess's ungated CAS path.
    public func block(cid: String) async -> Block? {
        guard await process.hasAcceptedBlock(cid) else { return nil }
        guard let data = await process.content([cid])[cid],
              data.count <= Self.maximumReadResponseBytes else {
            return nil
        }
        return _contentBoundBlock(cid: cid, data: data)
    }

    /// Bounded public read: a decoded, content-verified transaction. Resolving
    /// and content-binding as a `Transaction` is itself the gate that keeps
    /// internal (non-transaction) objects from being served by CID.
    public func transaction(cid: String) async -> Transaction? {
        guard let data = await process.content([cid])[cid],
              data.count <= Self.maximumReadResponseBytes else {
            return nil
        }
        guard let transaction = Transaction(data: data),
              (try? VolumeImpl<Transaction>(node: transaction).rawCID) == cid
        else { return nil }
        return transaction
    }

    /// Appends a canonical commit while ChainProcess still owns mutation order.
    /// Reconciliation is deferred to this service's worker so callers can
    /// release their operation gate before waiting.
    func enqueueCanonicalCommit(
        _ commit: ChainCommit
    ) -> CanonicalCommitReceipt {
        let receipt = CanonicalCommitReceipt()
        canonicalCommitQueue.append(QueuedCanonicalCommit(
            commit: commit,
            receipt: receipt
        ))
        reserveCanonicalCommitWorker()
        return receipt
    }

    /// The only production ingress for a candidate acquired by the network.
    /// The process reserves canonical reconciliation before it releases its
    /// mutation order; this method then waits behind that reservation before
    /// projecting service-owned state.
    public func admitNetworkCandidate(
        _ header: BlockHeader,
        authenticatedChildPackage: AuthenticatedChildPackage?,
        preparingChildDirectories: [String],
        contentSource: any ContentSource
    ) async throws -> NodeAdmissionOutcome {
        let outcome = try await process.admit(
            header,
            authenticatedChildPackage: authenticatedChildPackage,
            preparingChildDirectories: preparingChildDirectories,
            remoteSource: contentSource,
            canonicalCommitPublisher: { [self] commit in
                await enqueueCanonicalCommit(commit)
            }
        )
        guard let block = await locallyStoredBlock(header) else {
            // A target-miss carrier is intentionally not local chain state,
            // but its authenticated path can still carry an accepted direct
            // child. Relay any proof the process durably composed for it.
            if outcome.parentCarrierLink != nil {
                await handleCarrierAdmission(
                    header: header,
                    outcome: outcome
                )
            }
            return outcome
        }
        _ = await handleAdmission(
            block: block,
            header: header,
            outcome: outcome
        )
        return outcome
    }

    public func submitTransaction(
        _ request: SubmitTransactionRequest
    ) async throws -> SubmitTransactionResponse {
        await acquireOperation()
        defer { releaseOperation() }
        guard let payload = try? JSONEncoder().encode(request),
              payload.count <= ChainServiceLimits.maximumPayloadBytes else {
            throw ChainServiceError.requestTooLarge
        }
        let admission = try await admitTransactionLocked(
            request.transaction,
            persistLocal: true
        )
        scheduleTransactionPublication(admission.cid)
        return SubmitTransactionResponse(
            transactionCID: admission.cid,
            mempoolCount: await pool.count,
            mempoolBytes: await pool.byteCount
        )
    }

    /// Same-chain peer ingress. The exact advertiser has already supplied and
    /// content-address verified the complete Volume; only Lattice may classify
    /// its state validity.
    public func submitNetworkTransaction(
        _ transaction: Transaction
    ) async throws -> Bool {
        await acquireOperation()
        defer { releaseOperation() }
        return try await admitTransactionLocked(
            transaction,
            persistLocal: false
        ).inserted
    }

    public func transactionInventoryRoots() async -> [String] {
        await acquireOperation()
        defer { releaseOperation() }
        guard (try? await prepareMempoolLocked()) != nil else { return [] }
        return await pool.snapshot().map(\.cid).sorted()
    }

    /// Rebuilds only user-submitted durable entries before networking starts.
    /// Peer-originated transactions intentionally remain volatile.
    public func restoreLocalTransactions() async throws {
        await acquireOperation()
        defer { releaseOperation() }
        try await restoreLocalTransactionsLocked()
    }

    private func restoreLocalTransactionsLocked() async throws {
        _ = await pool.clear()
        let durable = try await process.localTransactions()
        guard !durable.isEmpty else {
            try await syncLiveMempoolRootsLocked([])
            return
        }
        let tip = try await process.canonicalTipBlock()
        let spec = try await chainSpec(for: tip)
        for item in durable {
            let disposition = Self.poolDisposition(
                (try await process.preflightTransaction(item.transaction)).disposition
            )
            guard disposition != .invalid else {
                try await process.removeLocalTransaction(item.transactionCID)
                continue
            }
            _ = try? await pool.submit(
                item.transaction,
                spec: spec,
                fetcher: process,
                disposition: disposition,
                addedAt: Date(timeIntervalSince1970: TimeInterval(item.addedAt))
            )
        }
        try await prepareMempoolLocked()
        let roots = Set(await pool.snapshot().map(\.cid))
        try await pruneDurableLocalTransactionsLocked(keeping: roots)
        try await syncLiveMempoolRootsLocked(roots)
    }

    private func admitTransactionLocked(
        _ transaction: Transaction,
        persistLocal: Bool
    ) async throws -> (cid: String, inserted: Bool) {
        try await prepareMempoolLocked()
        let previous = try await process.canonicalTipBlock()
        try await removeStaleChildIntents(
            parentStateCID: previous.postState.rawCID
        )
        let spec = try await chainSpec(for: previous)
        guard let envelope = transaction.toData(),
              envelope.count <= spec.maxBlockSize,
              transaction.body.node?.toData().map({
                  $0.count <= spec.maxBlockSize
              }) ?? true else {
            throw TransactionPoolError.tooLarge
        }
        let preflight = try await process.preflightTransaction(
            transaction
        )
        guard await process.status().tipCID == preflight.tipCID else {
            throw ChainServiceError.templateContextChanged
        }
        let disposition = Self.poolDisposition(preflight.disposition)
        guard disposition != .invalid else {
            throw TransactionPoolError.invalidState
        }
        let expectedCID = try VolumeImpl<Transaction>(node: transaction).rawCID
        let durableBefore = try await process.localTransactionTimestamps()
        let mutation = try await pool.submit(
            transaction,
            spec: spec,
            fetcher: process,
            disposition: disposition
        )
        guard let cid = mutation.transactionCID, cid == expectedCID else {
            await pool.rollback(mutation)
            throw TransactionPoolError.unresolved
        }
        let wasKnown = mutation.inserted == nil
        do {
            let snapshot = await pool.snapshot()
            if persistLocal,
               durableBefore[cid] == nil,
               let admitted = snapshot.first(where: { $0.cid == cid }) {
                let storedCID = try await process.persistLocalTransaction(
                    admitted.transaction,
                    addedAt: Int64(admitted.addedAt.timeIntervalSince1970)
                )
                guard storedCID == cid else {
                    throw TransactionPoolError.unresolved
                }
            } else if !wasKnown {
                let storedCID = try await process.persistPeerTransaction(
                    transaction
                )
                // `persistPeerTransaction` installed this owner pin while the
                // process mutation gate was held; account for it before the
                // ordinary delta sync so it is neither doubled nor leaked.
                liveMempoolRoots.insert(storedCID)
                guard storedCID == cid else {
                    throw TransactionPoolError.unresolved
                }
            }
            try await pruneDurableLocalTransactionsLocked(
                keeping: Set(snapshot.map(\.cid))
            )
            try await syncLiveMempoolRootsLocked(Set(snapshot.map(\.cid)))
            guard await process.status().tipCID == preflight.tipCID else {
                throw ChainServiceError.templateContextChanged
            }
            return (cid, !wasKnown)
        } catch {
            await pool.rollback(mutation)
            try await restoreLocalDurabilityLocked(
                durableBefore,
                mutation: mutation
            )
            try await syncLiveMempoolRootsLocked(
                Set(await pool.snapshot().map(\.cid))
            )
            throw error
        }
    }

    private func restoreLocalDurabilityLocked(
        _ durableBefore: [String: Int64],
        mutation: TransactionPoolMutation
    ) async throws {
        let changed = [mutation.inserted].compactMap { $0 }
            + mutation.replaced + mutation.evicted
            + mutation.expired + mutation.removed
        var changedByCID = Dictionary(uniqueKeysWithValues: changed.map {
            ($0.cid, $0.transaction)
        })
        if let transactionCID = mutation.transactionCID {
            let current = await pool.snapshot().first {
                $0.cid == transactionCID
            }
            changedByCID[transactionCID] = mutation.inserted?.transaction
                ?? current?.transaction
        }
        let changedRoots = Set(changedByCID.keys)
        let currentRoots = Set(
            try await process.localTransactionTimestamps().keys
        )
        for cid in changedRoots where durableBefore[cid] == nil
            && currentRoots.contains(cid) {
            try await process.removeLocalTransaction(cid)
        }
        for cid in changedRoots where durableBefore[cid] != nil
            && !currentRoots.contains(cid) {
            guard let addedAt = durableBefore[cid],
                  let transaction = changedByCID[cid] else { continue }
            _ = try await process.persistLocalTransaction(
                transaction,
                addedAt: addedAt
            )
        }
    }

    private func pruneDurableLocalTransactionsLocked(
        keeping roots: Set<String>
    ) async throws {
        for transactionCID in try await process.localTransactionTimestamps().keys
        where !roots.contains(transactionCID) {
            try await process.removeLocalTransaction(transactionCID)
        }
    }

    private func prepareMempoolLocked() async throws {
        if mempoolUnavailable {
            mempoolUnavailable = false
            do {
                try await restoreLocalTransactionsLocked()
            } catch {
                mempoolUnavailable = true
                throw ChainServiceError.mempoolUnavailable
            }
        }
        let expiration = await pool.expire()
        guard !expiration.expired.isEmpty else { return }
        let durableBefore: [String: Int64]
        do {
            durableBefore = try await process.localTransactionTimestamps()
        } catch {
            await pool.rollback(expiration)
            throw error
        }
        do {
            let roots = Set(await pool.snapshot().map(\.cid))
            try await pruneDurableLocalTransactionsLocked(keeping: roots)
            try await syncLiveMempoolRootsLocked(roots)
        } catch {
            await pool.rollback(expiration)
            try await restoreLocalDurabilityLocked(
                durableBefore,
                mutation: expiration
            )
            try await syncLiveMempoolRootsLocked(
                Set(await pool.snapshot().map(\.cid))
            )
            throw error
        }
    }

    private func syncLiveMempoolRootsLocked(_ roots: Set<String>) async throws {
        let added = roots.subtracting(liveMempoolRoots)
        let removed = liveMempoolRoots.subtracting(roots)
        guard !added.isEmpty || !removed.isEmpty else { return }
        try await process.updateLiveMempoolRoots(
            adding: added,
            removing: removed
        )
        liveMempoolRoots = roots
    }

    public func createChildDeployIntent(
        _ request: ChildDeployIntentRequest
    ) async throws -> ChildDeployIntentResponse {
        await acquireOperation()
        defer { releaseOperation() }
        guard _isBoundedDirectoryAtom(request.directory),
              let childAddress = ChainAddress(
                  process.configuration.chainPath + [request.directory]
              ) else {
            throw ChainServiceError.invalidChildDirectory
        }
        guard let encoded = try? JSONEncoder().encode(request),
              encoded.count <= Self.maximumChildIntentBytes else {
            throw ChainServiceError.childIntentTooLarge
        }
        let childSpec = request.spec
        let parent = try await process.canonicalTipBlock()
        try await removeStaleChildIntents(
            parentStateCID: parent.postState.rawCID
        )
        guard childIntents[request.directory] != nil
            || childIntents.count < Self.maximumChildIntents else {
            throw ChainServiceError.childIntentLimitReached
        }
        guard request.policyModules.count
                <= process.configuration.resourcePolicy.maximumWasmPolicies else {
            throw ChainServiceError.invalidChildPolicyModules
        }
        let requiredModuleCIDs = Set(childSpec.wasmPolicies.map(\.moduleCID))
        let suppliedModuleCIDs = Set(request.policyModules.map(\.rootCID))
        guard suppliedModuleCIDs.count == request.policyModules.count,
              suppliedModuleCIDs == requiredModuleCIDs else {
            throw ChainServiceError.invalidChildPolicyModules
        }
        let requestContent = MemoryBroker()
        do {
            for module in request.policyModules {
                guard module.bytes.count <= WasmPolicyResourceLimits.default.maxModuleBytes
                else {
                    throw ChainServiceError.invalidChildPolicyModules
                }
                try await module.header().store(storer: requestContent)
            }
        } catch {
            throw ChainServiceError.invalidChildPolicyModules
        }
        let childContentSource = CompositeContentSource([
            requestContent,
            process,
        ])
        let childContentFetcher = CoalescingFetcher(childContentSource)
        guard request.genesisTransactions.allSatisfy({ transaction in
            guard let body = transaction.body.node else { return false }
            return transaction.signatures.isEmpty
                && body.signers.isEmpty
                && body.stateAtomsAreValid()
        }) else {
            throw ChainServiceError.invalidChildGenesis
        }
        let genesis = try await BlockBuilder.buildChildGenesis(
            spec: childSpec,
            parentState: parent.postState,
            transactions: request.genesisTransactions,
            timestamp: request.timestamp,
            target: request.target,
            fetcher: childContentFetcher
        )
        let valid = try await genesis.validateGenesis(
            fetcher: childContentFetcher,
            chainPath: childAddress.components
        ).0
        guard valid else { throw ChainServiceError.invalidChildGenesis }

        let header = try BlockHeader(node: genesis)
        let retainedOtherRoots = childIntents.reduce(into: Set<String>()) {
            guard $1.key != request.directory else { return }
            $0.formUnion($1.value.volumeRoots)
        }
        let volumeRoots = try await process.storeChildIntent(
            header,
            fetcher: childContentFetcher,
            retaining: retainedOtherRoots
        )
        let intent = ChildIntent(
            directory: request.directory,
            chainPath: childAddress.components,
            genesisCID: header.rawCID,
            genesis: genesis,
            parentStateCID: parent.postState.rawCID,
            volumeRoots: volumeRoots
        )
        childIntents[request.directory] = intent

        return ChildDeployIntentResponse(
            directory: intent.directory,
            chainPath: intent.chainPath,
            genesisCID: intent.genesisCID,
            genesisBlock: intent.genesis,
            parentStateCID: intent.parentStateCID
        )
    }

    public func miningTemplate(
        _ request: MiningTemplateRequest
    ) async throws -> MiningTemplateResponse {
        await acquireOperation()
        defer { releaseOperation() }
        try await prepareMempoolLocked()
        guard process.configuration.address.isNexus else {
            throw ChainServiceError.parentCarrierRequired
        }
        // A child candidate is optional until its exact process durably acks
        // the reservation. One rebuild lets the runtime omit every peer that
        // failed the bounded ack round while preserving healthy siblings.
        for attempt in 0...1 {
            let assembled: MiningTemplate
            do {
                assembled = try await buildMiningTemplate(
                    rewards: request.rewards,
                    mode: request.mode,
                    parentCarrier: nil
                )
            } catch {
                _ = await reconcileCurrentCandidateReservations()
                throw error
            }
            let issuance = await templates.issueTrackingInsertion(assembled)
            if await reconcileCurrentCandidateReservations() {
                let template = issuance.template
                guard template.remainingLifetimeMilliseconds > 0 else {
                    await templates.discard(workID: template.workID)
                    _ = await reconcileCurrentCandidateReservations()
                    throw MiningTemplateError.expired
                }
                return MiningTemplateResponse(
                    template: template,
                    maximumLifetimeMilliseconds: Self.templateLifetimeMilliseconds
                )
            }
            if issuance.inserted {
                await templates.discard(workID: issuance.template.workID)
            }
            _ = await reconcileCurrentCandidateReservations()
            if attempt == 1 {
                throw ChainServiceError.childCandidateReservationFailed
            }
        }
        throw ChainServiceError.childCandidateReservationFailed
    }

    /// Applies one exact parent-issued snapshot only after recursively making
    /// every committed direct-child candidate durable at its exact process.
    public func replaceIssuedCandidateReservations(
        _ update: NetworkCandidateReservationUpdate
    ) async -> Bool {
        await acquireOperation()
        defer { releaseOperation() }
        let desired = Set(update.candidateCIDs)
        let handoffs = Set(update.handoffCIDs)
        guard desired.count == update.candidateCIDs.count,
              handoffs.count == update.handoffCIDs.count,
              desired.count + handoffs.count <= Self.templateCapacity,
              desired.isDisjoint(with: handoffs),
              let reservedChildren = try? await process
                .contextualCandidateChildren(
                candidateCIDs: desired
              ),
              let handoffChildren = try? await process
                .contextualCandidateChildren(candidateCIDs: handoffs),
              await childCandidateReservationReconciler(
                ChildCandidateReservationUpdate(
                    reservations: reservedChildren,
                    handoffs: handoffChildren
                )
              ) else {
            return false
        }
        return (try? await process.replaceIssuedContextualCandidates(
            desired,
            handoffs: handoffs,
            capacity: Self.templateCapacity
        )) == true
    }

    private func reconcileCurrentCandidateReservations(
        handoffs: [ChildCandidateReservationReference] = []
    ) async -> Bool {
        let candidates = await templates.activeChildCandidates()
        let ownership: ChildCandidateOwnership
        do {
            ownership = try ChildCandidateOwnership(
                candidates: candidates,
                handoffs: handoffs
            )
        } catch {
            return false
        }
        return await childCandidateReservationReconciler(ownership.update)
    }

    private func reconcileRetainedCandidateDescendants() async {
        guard let references = try? await process
            .currentContextualCandidateChildren() else { return }
        _ = await childCandidateReservationReconciler(
            ChildCandidateReservationUpdate(
                reservations: sortedReservationReferences(references)
            )
        )
    }

    private func sortedReservationReferences(
        _ references: [ChildCandidateReservationReference]
    ) -> [ChildCandidateReservationReference] {
        Array(Set(references)).sorted {
            ($0.peerKey.description, $0.candidateCID)
                < ($1.peerKey.description, $1.candidateCID)
        }
    }

    /// Hierarchy-only child candidate construction. The authenticated parent
    /// supplies the provisional carrier whose `prevState` this block must bind.
    public func miningCandidate(
        parentCarrier: Block,
        parentContentSource: any ContentSource,
        rewards: [MiningReward] = [],
        mode: MiningMode = .normal
    ) async throws -> DirectChildCandidate {
        await acquireOperation()
        defer { releaseOperation() }
        try await prepareMempoolLocked()
        guard !process.configuration.address.isNexus,
              (try? BlockHeader(node: parentCarrier)) != nil else {
            throw ChainServiceError.invalidParentCarrier
        }
        let fetcher = CoalescingFetcher(CompositeContentSource([
            process,
            parentContentSource,
        ]))
        let template = try await buildMiningTemplate(
            rewards: rewards,
            mode: mode,
            parentCarrier: parentCarrier,
            fetcher: fetcher
        )
        let candidateHeader = try BlockHeader(node: template.block)
        let childReservations = try template.childCandidates.compactMap {
            candidate -> ChildCandidateReservationReference? in
            guard let peerKey = candidate.advertiserPeerKey else { return nil }
            return ChildCandidateReservationReference(
                peerKey: peerKey,
                candidateCID: try BlockHeader(node: candidate.block).rawCID
            )
        }
        try await process.storeContextualCandidate(
            candidateHeader,
            fetcher: fetcher,
            children: Array(Set(childReservations)),
            capacity: Self.templateCapacity
        )
        _ = try await process.prepareChildProofs(
            for: template.block,
            children: template.childCandidates,
            capacity: Self.templateCapacity
        )
        return DirectChildCandidate(
            directory: process.configuration.address.directory,
            block: template.block,
            searchWitness: template.searchWitness,
            deploymentWitness: template.deploymentWitness
        )
    }

    private func buildMiningTemplate(
        rewards: [MiningReward],
        mode: MiningMode,
        parentCarrier: Block?,
        fetcher: (any Fetcher)? = nil
    ) async throws -> MiningTemplate {
        let fetcher: any Fetcher = fetcher ?? process
        let previous = try await process.canonicalTipBlock()
        try await removeStaleChildIntents(
            parentStateCID: previous.postState.rawCID
        )
        let spec = try await chainSpec(for: previous)
        let rewardPlan = try await validatedRewardPlan(rewards)
        let reward = try await validatedRewardTransaction(
            rewardPlan.current,
            previous: previous,
            spec: spec
        )
        let maximumTransactions = Int(clamping: spec.maxNumberOfTransactionsPerBlock)
        var poolLimit = max(0, maximumTransactions - (reward == nil ? 0 : 1))
        var largestFittingPoolLimit = -1
        var largestFittingTemplate: FittingMiningTemplate?
        var maximumPoolLimit = poolLimit
        let timestamp = try nextTimestamp(
            after: previous.timestamp,
            parentCarrier: parentCarrier
        )
        let pooled: [Transaction]
        if let parentCarrier {
            var contextual: [Transaction] = []
            for transaction in await pool.contextualTransactions(limit: .max) {
                let preflight = try await process.preflightTransaction(
                    transaction,
                    parentState: parentCarrier.prevState,
                    fetcher: fetcher
                )
                if preflight.disposition == .ready
                    || preflight.disposition == .future {
                    contextual.append(transaction)
                }
            }
            pooled = contextual
        } else {
            pooled = await pool.transactions(limit: .max)
        }
        try await syncLiveMempoolRootsLocked(
            Set(await pool.snapshot().map(\.cid))
        )
        let deploymentIndices = pooled.indices.filter {
            !anchors(in: [pooled[$0]]).isEmpty
        }
        let pendingDeploymentIndices = deploymentIndices.filter {
            isPendingDeployment(
                pooled[$0],
                parentStateCID: previous.postState.rawCID
            )
        }
        let deploymentIndexSet = Set(deploymentIndices)
        var preferredDeploymentIndex: Int?
        var deploymentCursorAdvance = 0
        if mode == .deployment, poolLimit > 0 {
            for offset in pendingDeploymentIndices.indices {
                let position = (deploymentTransactionCursor &+ offset)
                    % pendingDeploymentIndices.count
                let index = pendingDeploymentIndices[position]
                let candidateAnchors = anchors(in: [pooled[index]])
                let probe = try await templates.preview(
                    previous: previous,
                    transactions: (reward.map { [$0] } ?? []) + [pooled[index]],
                    children: [],
                    parentCarrier: parentCarrier,
                    timestamp: timestamp,
                    transactionLimit: (reward == nil ? 0 : 1) + 1,
                    fetcher: fetcher
                )
                let included = anchors(
                    in: try await blockTransactions(in: probe.block)
                )
                guard candidateAnchors.isSubset(of: included) else { continue }
                preferredDeploymentIndex = index
                deploymentCursorAdvance = offset + 1
                break
            }
        }
        let childDeploymentCursor = deploymentChildCursor
        var selectLocalDeployment = preferredDeploymentIndex != nil
            && deploymentSourceCursor.isMultiple(of: 2)

        while true {
            let selectedDeploymentIndex = selectLocalDeployment && poolLimit > 0
                ? preferredDeploymentIndex
                : nil
            let ordinary = pooled.indices.compactMap {
                deploymentIndexSet.contains($0) ? nil : pooled[$0]
            }
            let transactions = (reward.map { [$0] } ?? [])
                + (selectedDeploymentIndex.map { [pooled[$0]] } ?? [])
                + ordinary
            let provisional = try await templates.preview(
                previous: previous,
                transactions: transactions,
                children: [],
                parentCarrier: parentCarrier,
                timestamp: timestamp,
                transactionLimit: poolLimit + (reward == nil ? 0 : 1),
                fetcher: fetcher
            )
            try requireReward(rewardPlan.current, in: provisional.block)
            if try await !blockFits(
                provisional.block,
                spec: spec,
                fetcher: fetcher
            ) {
                maximumPoolLimit = poolLimit - 1
                if maximumPoolLimit <= largestFittingPoolLimit {
                    guard let largestFittingTemplate else {
                        throw ChainServiceError.templateTooLarge
                    }
                    return finishMiningTemplate(
                        largestFittingTemplate,
                        mode: mode
                    )
                }
                poolLimit = largestFittingPoolLimit
                    + (maximumPoolLimit - largestFittingPoolLimit + 1) / 2
                continue
            }

            let selectedTransactions = try await blockTransactions(
                in: provisional.block
            )
            let selectedAnchors = anchors(in: selectedTransactions)
            let localChildren = eligibleChildren(
                parentStateCID: previous.postState.rawCID,
                anchors: selectedAnchors
            )
            let localDeploymentIncluded = selectedDeploymentIndex.map {
                anchors(in: [pooled[$0]]).isSubset(of: selectedAnchors)
            } ?? false
            let provided = try await validatedProvidedChildren(
                context: ChildCandidateRequestContext(
                    parentCarrier: provisional.block,
                    rewards: rewardPlan.descendants,
                    mode: mode == .deployment && !localDeploymentIncluded
                        ? .deployment
                        : .normal,
                    excludedDirectories: Set(localChildren.map(\.directory))
                ),
                deploymentCursor: childDeploymentCursor
            )
            let providedChildren = provided.candidates
            let providedDeployment = provided.hasDeployment
            if mode == .deployment,
               !pendingDeploymentIndices.isEmpty,
               !localDeploymentIncluded,
               !providedDeployment,
               poolLimit == 0 {
                throw ChainServiceError.templateTooLarge
            }
            if mode == .deployment,
               preferredDeploymentIndex != nil,
               !selectLocalDeployment,
               !providedDeployment {
                selectLocalDeployment = true
                continue
            }
            if mode == .deployment,
               !localDeploymentIncluded,
               !providedDeployment {
                throw ChainServiceError.noDeploymentAvailable
            }
            let children = try combineChildren(
                providedChildren,
                localChildren
            )
            let requiredDirectories: Set<String> = if localDeploymentIncluded {
                Set(localChildren.map(\.directory))
            } else {
                Set(provided.deploymentDirectory.map { [$0] } ?? [])
            }
            let requiredChildren = children.filter {
                requiredDirectories.contains($0.directory)
            }
            var optionalChildren = children.filter {
                !requiredDirectories.contains($0.directory)
            }
            if !optionalChildren.isEmpty {
                let offset = Int(
                    previous.height % UInt64(optionalChildren.count)
                )
                optionalChildren = Array(optionalChildren[offset...])
                    + optionalChildren[..<offset]
            }

            var selectedChildCount = optionalChildren.count
            var template = try await templates.preview(
                previous: previous,
                transactions: selectedTransactions,
                children: (requiredChildren
                    + optionalChildren.prefix(selectedChildCount))
                    .sorted { $0.directory < $1.directory },
                parentCarrier: parentCarrier,
                timestamp: timestamp,
                fetcher: fetcher
            )
            try requireReward(rewardPlan.current, in: template.block)
            try requireSameTemplateContext(
                provisional.block,
                final: template.block
            )
            if try await !blockFits(
                template.block,
                spec: spec,
                fetcher: fetcher
            ), !optionalChildren.isEmpty {
                let minimumChildCount = poolLimit == 0 ? 0 : 1
                let minimumTemplate = try await templates.preview(
                    previous: previous,
                    transactions: selectedTransactions,
                    children: (requiredChildren
                        + optionalChildren.prefix(minimumChildCount))
                        .sorted { $0.directory < $1.directory },
                    parentCarrier: parentCarrier,
                    timestamp: timestamp,
                    fetcher: fetcher
                )
                if try await blockFits(
                    minimumTemplate.block,
                    spec: spec,
                    fetcher: fetcher
                ) {
                    var fittingLimit = minimumChildCount
                    var failingLimit = optionalChildren.count
                    template = minimumTemplate
                    while fittingLimit + 1 < failingLimit {
                        let probeLimit = fittingLimit
                            + (failingLimit - fittingLimit) / 2
                        let probe = try await templates.preview(
                            previous: previous,
                            transactions: selectedTransactions,
                            children: (requiredChildren
                                + optionalChildren.prefix(probeLimit))
                                .sorted { $0.directory < $1.directory },
                            parentCarrier: parentCarrier,
                            timestamp: timestamp,
                            fetcher: fetcher
                        )
                        if try await blockFits(
                            probe.block,
                            spec: spec,
                            fetcher: fetcher
                        ) {
                            fittingLimit = probeLimit
                            template = probe
                        } else {
                            failingLimit = probeLimit
                        }
                    }
                    selectedChildCount = fittingLimit
                }
            }

            if try await blockFits(
                template.block,
                spec: spec,
                fetcher: fetcher
            ) {
                largestFittingPoolLimit = poolLimit
                let fittingTemplate = FittingMiningTemplate(
                    template: template,
                    deploymentTransactionAdvance: localDeploymentIncluded
                        ? deploymentCursorAdvance
                        : 0,
                    advancesDeploymentChild: providedDeployment
                )
                largestFittingTemplate = fittingTemplate
                if poolLimit < maximumPoolLimit {
                    poolLimit += (maximumPoolLimit - poolLimit + 1) / 2
                    continue
                }
                return finishMiningTemplate(fittingTemplate, mode: mode)
            }
            maximumPoolLimit = poolLimit - 1
            if maximumPoolLimit <= largestFittingPoolLimit {
                guard let largestFittingTemplate else {
                    throw ChainServiceError.templateTooLarge
                }
                return finishMiningTemplate(
                    largestFittingTemplate,
                    mode: mode
                )
            }
            poolLimit = largestFittingPoolLimit
                + (maximumPoolLimit - largestFittingPoolLimit + 1) / 2
        }
    }

    private func finishMiningTemplate(
        _ fitting: FittingMiningTemplate,
        mode: MiningMode
    ) -> MiningTemplate {
        deploymentTransactionCursor &+= fitting.deploymentTransactionAdvance
        if fitting.advancesDeploymentChild {
            deploymentChildCursor &+= 1
        }
        if mode == .deployment {
            deploymentSourceCursor &+= 1
        }
        return fitting.template
    }

    public func submitWork(
        _ request: SubmitWorkRequest
    ) async throws -> SubmitWorkResponse {
        await acquireOperation()
        var ownsOperation = true
        defer {
            if ownsOperation { releaseOperation() }
        }
        guard process.configuration.address.isNexus else {
            throw ChainServiceError.parentCarrierRequired
        }
        guard !request.workID.isEmpty,
              request.workID.utf8.count <= Self.maximumWorkIDBytes else {
            throw ChainServiceError.invalidWorkID
        }
        let submission = try await templates.submission(
            workID: request.workID,
            nonce: request.nonce
        )
        let candidate = submission.block
        let header = try BlockHeader(node: candidate)
        let preparedChildProofs = try await process.prepareChildProofs(
            for: candidate,
            children: submission.children,
            capacity: Self.templateCapacity
        )
        let outcome = try await process.admit(
            header,
            canonicalCommitPublisher: { [self] commit in
                await enqueueCanonicalCommit(commit)
            }
        )
        let candidateHandoffs: [ChildCandidateReservationReference]
        if outcome.decision.isAccepted {
            let committedCIDs = Set(preparedChildProofs.map(\.childCID))
            candidateHandoffs = try submission.children.compactMap { child in
                guard let peerKey = child.advertiserPeerKey else { return nil }
                let childCID = try BlockHeader(node: child.block).rawCID
                guard committedCIDs.contains(childCID) else { return nil }
                return ChildCandidateReservationReference(
                    peerKey: peerKey,
                    candidateCID: childCID
                )
            }
        } else {
            candidateHandoffs = []
        }
        let effects = await applyAdmissionEffects(
            block: candidate,
            header: header,
            outcome: outcome,
            candidateHandoffs: candidateHandoffs
        )
        await templates.discard(workID: request.workID)

        // The process enqueued this commit while preserving its own mutation
        // order. Release our gate before waiting because reconciliation must
        // acquire the same gate to update the pool and templates.
        if let receipt = outcome.canonicalCommitReceipt {
            releaseOperation()
            ownsOperation = false
            await receipt.wait()
        }

        let status = await process.status()
        let accepted: Bool
        switch outcome.decision {
        case .canonicalized, .acceptedSide:
            accepted = true
        default:
            accepted = false
        }
        return SubmitWorkResponse(
            accepted: accepted,
            disposition: WorkDisposition(outcome.decision),
            tipCID: status.tipCID,
            parentCarrierLink: outcome.parentCarrierLink,
            parentGenesisLinks: effects.parentGenesisLinks,
            durableChildProofs: outcome.decision.isAccepted
                ? preparedChildProofs.map {
                    DirectChildProofSummary(
                        directory: $0.directory,
                        childCID: $0.childCID
                    )
                }
                : []
        )
    }

    /// Reconciles service-owned state and publishes hierarchy effects after a
    /// candidate was admitted through gossip, sync, or the hierarchy plane.
    /// Consensus admission itself remains exclusively in `ChainProcess`.
    @discardableResult
    private func handleAdmission(
        block: Block,
        header: BlockHeader,
        outcome: NodeAdmissionOutcome
    ) async -> AdmissionEffects {
        await acquireOperation()
        defer { releaseOperation() }
        return await applyAdmissionEffects(
            block: block,
            header: header,
            outcome: outcome
        )
    }

    private func handleCarrierAdmission(
        header: BlockHeader,
        outcome: NodeAdmissionOutcome
    ) async {
        await acquireOperation()
        defer { releaseOperation() }
        _ = await publishCarrierChildProofs(
            header: header,
            outcome: outcome
        )
    }

    private func startCanonicalCommitWorker() {
        guard canonicalCommitWorker == nil else { return }
        canonicalCommitWorker = Task {
            await drainCanonicalCommits()
        }
    }

    private func reserveCanonicalCommitWorker() {
        guard !canonicalCommitWorkerReserved else { return }
        // Reserve the gate before the task starts so later callers cannot see
        // advanced chain state before reconciliation.
        canonicalCommitWorkerReserved = true
        if operationInFlight {
            operationWaiters.insert(.canonicalCommit, at: 0)
        } else {
            operationInFlight = true
            startCanonicalCommitWorker()
        }
    }

    private func drainCanonicalCommits() async {
        precondition(canonicalCommitWorkerReserved)
        while !canonicalCommitQueue.isEmpty {
            let event = canonicalCommitQueue.removeFirst()
            await reconcileCanonicalCommitOrResetLocked(event.commit)
            await event.receipt.finish()
        }
        canonicalCommitWorker = nil
        canonicalCommitWorkerReserved = false
        releaseOperation()
    }

    private func reconcileCanonicalCommitOrResetLocked(
        _ commit: ChainCommit
    ) async {
        do {
            try await reconcileCanonicalCommitLocked(commit)
        } catch {
            _ = await pool.clear()
            do {
                try await syncLiveMempoolRootsLocked([])
            } catch {}
            mempoolUnavailable = true
            await invalidateTemplatesLocked()
            if (try? await process.retainChildIntentRoots([])) != nil {
                childIntents.removeAll()
            }
        }
    }

    private func applyAdmissionEffects(
        block: Block,
        header: BlockHeader,
        outcome: NodeAdmissionOutcome,
        candidateHandoffs: [ChildCandidateReservationReference]? = nil
    ) async -> AdmissionEffects {
        // Visibility of accepted work is independent from optional child
        // materialization. A missing child payload must not suppress the
        // canonical announcement.
        switch outcome.decision {
        case .canonicalized(let commit):
            if outcome.canonicalCommitReceipt == nil {
                await reconcileCanonicalCommitOrResetLocked(commit)
            }
            try? await acceptedBlockPublisher(header.rawCID)
        case .acceptedSide:
            try? await acceptedBlockPublisher(header.rawCID)
        default:
            break
        }

        var genesisLinks: [ParentGenesisLink] = []

        switch outcome.decision {
        case .canonicalized, .acceptedSide, .duplicate:
            let transactions = (try? await blockTransactions(in: block)) ?? []
            let blockAnchors = anchors(in: transactions).sorted {
                ($0.directory, $0.genesisCID) < ($1.directory, $1.genesisCID)
            }
            for anchor in blockAnchors {
                if let link = try? await process.issuedParentGenesisLink(
                    directory: anchor.directory,
                    childGenesisCID: anchor.genesisCID,
                    parentStateCID: block.prevState.rawCID
                ) {
                    genesisLinks.append(link)
                    if childIntents[anchor.directory]?.genesisCID == anchor.genesisCID {
                        var remaining = childIntents
                        remaining.removeValue(forKey: anchor.directory)
                        if (try? await replaceChildIntents(remaining)) != nil {
                            childIntents = remaining
                        }
                    }
                }
            }
        default:
            break
        }

        await publishCarrierChildProofs(
            header: header,
            outcome: outcome,
            candidateHandoffs: candidateHandoffs
        )
        if outcome.decision.isAccepted, candidateHandoffs == nil {
            Task { [weak self] in
                await self?.reconcileRetainedCandidateDescendants()
            }
        }
        return AdmissionEffects(
            parentGenesisLinks: genesisLinks.sorted {
                $0.directory < $1.directory
            }
        )
    }

    private func publishCarrierChildProofs(
        header: BlockHeader,
        outcome: NodeAdmissionOutcome,
        candidateHandoffs: [ChildCandidateReservationReference]? = nil
    ) async {
        guard let link = outcome.parentCarrierLink else {
            if let candidateHandoffs {
                Task { [weak self] in
                    _ = await self?.reconcileCurrentCandidateReservations(
                        handoffs: candidateHandoffs
                    )
                }
            }
            return
        }
        // Admission and the miner response depend only on the durable proof,
        // never on child availability. Delivery is an asynchronous hint; the
        // retained route remains pullable and retryable after failure/restart.
        // The following reservation update carries the committed candidate as
        // a handoff, so the child retains it atomically before releasing its
        // speculative reservation. Proof acquisition remains independent.
        Task { [weak self] in
            guard let self else { return }
            if let candidateHandoffs {
                _ = await self.reconcileCurrentCandidateReservations(
                    handoffs: candidateHandoffs
                )
            }
            await self.deliverCarrierChildProofs(
                carrierCID: header.rawCID,
                rootCID: link.rootCID
            )
        }
    }

    private func deliverCarrierChildProofs(
        carrierCID: String,
        rootCID: String
    ) async {
        _ = try? await process.retryPendingChildProofs(carrierCID: carrierCID)
        let durableProofs = (try? await process.durableDirectChildProofs(
            carrierCID: carrierCID,
            rootCID: rootCID
        )) ?? []
        for durable in durableProofs {
            let publication = DirectChildProofPublication(
                directory: durable.directory,
                childCID: durable.childCID,
                proof: durable.proof
            )
            do { try await childProofPublisher(publication) } catch {
                // Proofs and links are durable; hierarchy pull/reconnect can
                // retry a failed eager publication.
            }
        }
    }

    private func locallyStoredBlock(_ header: BlockHeader) async -> Block? {
        guard let data = await process.content([header.rawCID])[header.rawCID]
        else {
            return nil
        }
        return _contentBoundBlock(cid: header.rawCID, data: data)
    }

    private func reconcileCanonicalCommitLocked(
        _ commit: ChainCommit
    ) async throws {
        guard commit.canonicalChanged else { return }
        try await prepareMempoolLocked()

        let addedTransactions = try await transactions(
            inBlocks: commit.mainChainBlocksAdded.keys.sorted()
        )
        let removedTransactions = try await transactions(
            inBlocks: commit.mainChainBlocksRemoved.sorted()
        )
        let tip = try await process.canonicalTipBlock()
        let spec = try await chainSpec(for: tip)

        let addedCIDs = Set(addedTransactions.compactMap {
            try? VolumeImpl<Transaction>(node: $0).rawCID
        })
        var removedByCID: [String: Transaction] = [:]
        for transaction in removedTransactions {
            guard let cid = try? VolumeImpl<Transaction>(node: transaction).rawCID,
                  !addedCIDs.contains(cid) else {
                continue
            }
            removedByCID[cid] = transaction
        }

        await pool.remove(addedCIDs)
        for cid in removedByCID.keys.sorted() {
            guard let transaction = removedByCID[cid] else { continue }
            let disposition = Self.poolDisposition(
                (try await process.preflightTransaction(transaction)).disposition
            )
            _ = try? await pool.submit(
                transaction,
                spec: spec,
                fetcher: process,
                disposition: disposition
            )
        }
        let process = self.process
        _ = try await pool.revalidate { transaction in
            let result = try await process.preflightTransaction(transaction)
            return Self.poolDisposition(result.disposition)
        }
        let pooledRoots = Set(await pool.snapshot().map(\.cid))
        try await pruneDurableLocalTransactionsLocked(
            keeping: pooledRoots
        )
        try await syncLiveMempoolRootsLocked(pooledRoots)
        try await removeStaleChildIntents(
            parentStateCID: tip.postState.rawCID
        )
        for cid in removedByCID.keys.sorted() where pooledRoots.contains(cid) {
            scheduleTransactionPublication(cid)
        }
    }

    private func scheduleTransactionPublication(_ cid: String) {
        transactionPublications.insert(cid)
        guard transactionPublicationWorker == nil else { return }
        transactionPublicationWorker = Task {
            await drainTransactionPublications()
        }
    }

    private func drainTransactionPublications() async {
        while let cid = transactionPublications.popFirst() {
            try? await acceptedTransactionPublisher(cid)
        }
        transactionPublicationWorker = nil
    }

    private func invalidateTemplatesLocked() async {
        await templates.invalidateAll()
        _ = await reconcileCurrentCandidateReservations()
    }

    private nonisolated static func poolDisposition(
        _ disposition: TransactionPreflightDisposition
    ) -> TransactionPoolDisposition {
        switch disposition {
        case .ready: .ready
        case .future: .future
        case .unavailable: .unavailable
        case .invalid: .invalid
        }
    }

    private func transactions(inBlocks blockCIDs: [String]) async throws
        -> [Transaction] {
        var result: [Transaction] = []
        for cid in blockCIDs {
            let header = BlockHeader(
                rawCID: cid,
                node: nil,
                encryptionInfo: nil
            )
            guard let block = try await header.resolve(fetcher: process).node else {
                throw ChainServiceError.unresolvedTransactionContent
            }
            result += try await blockTransactions(in: block)
        }
        return result
    }

    private func chainSpec(for block: Block) async throws -> ChainSpec {
        guard let spec = try await block.spec.resolve(fetcher: process).node else {
            throw ChainServiceError.unresolvedChainSpec
        }
        return spec
    }

    private func validatedRewardTransaction(
        _ transaction: Transaction?,
        previous: Block,
        spec: ChainSpec
    ) async throws -> Transaction? {
        guard let transaction else { return nil }
        guard let bodyHeader = try? await transaction.body.resolve(fetcher: process),
              let body = bodyHeader.node else {
            throw ChainServiceError.invalidRewardTransaction
        }
        let resolved = Transaction(
            signatures: transaction.signatures,
            body: bodyHeader
        )
        let (height, overflow) = previous.height.addingReportingOverflow(1)
        guard !overflow,
              transaction.signatures.allSatisfy({ key, signature in
                  key.utf8.count <= Self.maximumSignatureFieldBytes
                      && signature.utf8.count <= Self.maximumSignatureFieldBytes
              }),
              body.chainPath == process.configuration.chainPath,
              body.fee == 0,
              !body.accountActions.isEmpty,
              body.accountActions.allSatisfy(\.isCredit),
              body.actions.isEmpty,
              body.depositActions.isEmpty,
              body.genesisActions.isEmpty,
              body.receiptActions.isEmpty,
              body.withdrawalActions.isEmpty,
              body.stateAtomsAreValid(),
              body.accountActionsAreValid(),
              resolved.signaturesAreValid(),
              resolved.signaturesMatchSigners(),
              let envelope = resolved.toData(),
              let bodyData = body.toData(),
              envelope.count <= spec.maxBlockSize,
              bodyData.count <= spec.maxBlockSize else {
            throw ChainServiceError.invalidRewardTransaction
        }
        var claimed: UInt64 = 0
        for action in body.accountActions {
            let addition = claimed.addingReportingOverflow(action.absoluteAmount)
            guard !addition.overflow else {
                throw ChainServiceError.invalidRewardTransaction
            }
            claimed = addition.partialValue
        }
        guard claimed <= spec.rewardAtBlock(height),
              try await TransactionBody.batchVerifyPolicies(
                  bodies: [body],
                  spec: spec,
                  chainPath: process.configuration.chainPath,
                  fetcher: process
              ) else {
            throw ChainServiceError.invalidRewardTransaction
        }
        try await VolumeImpl<Transaction>(node: resolved).store(storer: process)
        return resolved
    }

    private func validatedRewardPlan(
        _ rewards: [MiningReward]
    ) async throws -> ValidatedRewardPlan {
        guard let encoded = try? JSONEncoder().encode(
                  MiningTemplateRequest(rewards: rewards)
              ),
              encoded.count <= Self.maximumRewardPlanBytes else {
            throw ChainServiceError.rewardPlanTooLarge
        }
        let currentPath = process.configuration.chainPath
        var seen: Set<String> = []
        var current: Transaction?
        var descendants: [MiningReward] = []
        var resolvedBytes = 0
        for reward in rewards {
            guard let address = ChainAddress(reward.chainPath),
                  address.components.count >= currentPath.count,
                  Array(address.components.prefix(currentPath.count))
                    == currentPath,
                  seen.insert(address.key).inserted,
                  reward.transaction.signatures.allSatisfy({ key, signature in
                      key.utf8.count <= Self.maximumSignatureFieldBytes
                          && signature.utf8.count
                            <= Self.maximumSignatureFieldBytes
                  }),
                  let bodyHeader = try? await reward.transaction.body.resolve(
                      fetcher: process
                  ),
                  let body = bodyHeader.node,
                  body.chainPath == address.components,
                  let bodyData = body.toData(),
                  let transactionData = reward.transaction.toData(),
                  bodyData.count <= Self.maximumRewardPlanBytes - resolvedBytes,
                  transactionData.count <= Self.maximumRewardPlanBytes
                    - resolvedBytes - bodyData.count else {
                throw ChainServiceError.invalidRewardPlan
            }
            resolvedBytes += bodyData.count + transactionData.count
            let resolvedReward = MiningReward(
                chainPath: address.components,
                transaction: Transaction(
                    signatures: reward.transaction.signatures,
                    body: bodyHeader
                )
            )
            if address.components == currentPath {
                current = resolvedReward.transaction
            } else {
                descendants.append(resolvedReward)
            }
        }
        return ValidatedRewardPlan(
            current: current,
            descendants: descendants.sorted {
                $0.chainPath.lexicographicallyPrecedes($1.chainPath)
            }
        )
    }

    private func eligibleChildren(
        parentStateCID: String,
        anchors: Set<Anchor>
    ) -> [DirectChildCandidate] {
        childIntents.values.compactMap { intent in
            guard intent.parentStateCID == parentStateCID,
                  anchors.contains(Anchor(
                      directory: intent.directory,
                      genesisCID: intent.genesisCID
                  )) else { return nil }
            return DirectChildCandidate(
                directory: intent.directory,
                block: intent.genesis,
                parentCreatedGenesis: true
            )
        }.sorted { $0.directory < $1.directory }
    }

    private func validatedProvidedChildren(
        context: ChildCandidateRequestContext,
        deploymentCursor: Int
    ) async throws
        -> (
            candidates: [DirectChildCandidate],
            hasDeployment: Bool,
            deploymentDirectory: String?
        ) {
        let candidates = try await childCandidateProvider(context)
        var directories: Set<String> = []
        var accepted: [(
            candidate: DirectChildCandidate,
            targets: (search: UInt256, deployment: UInt256?)
        )] = []
        for candidate in candidates.sorted(by: candidateOrder) {
            guard (try? BlockHeader(node: candidate.block)) != nil,
                  accepted.count < maximumChildCandidates,
                  candidate.directory.utf8.count <= Self.maximumDirectoryBytes,
                  !directories.contains(candidate.directory),
                  ChainAddress(
                      process.configuration.chainPath + [candidate.directory]
                  ) != nil,
                  candidate.block.parentState.rawCID
                      == context.parentCarrier.prevState.rawCID else {
                continue
            }
            guard let targets = await schedulingTargets(for: candidate),
                  context.mode == .deployment
                    || targets.deployment == nil,
                  directories.insert(candidate.directory).inserted else {
                continue
            }
            accepted.append((candidate, targets))
        }
        guard context.mode == .deployment else {
            return (
                candidates: accepted.map(\.candidate),
                hasDeployment: false,
                deploymentDirectory: nil
            )
        }
        let deployments = accepted.filter { $0.targets.deployment != nil }
        guard !deployments.isEmpty else {
            return (
                candidates: accepted.map(\.candidate),
                hasDeployment: false,
                deploymentDirectory: nil
            )
        }
        let selected = deployments[deploymentCursor % deployments.count]
        return (
            candidates: accepted.filter { $0.targets.deployment == nil }
                .map(\.candidate)
                + [selected.candidate],
            hasDeployment: true,
            deploymentDirectory: selected.candidate.directory
        )
    }

    private func candidateOrder(
        _ left: DirectChildCandidate,
        _ right: DirectChildCandidate
    ) -> Bool {
        if left.directory != right.directory {
            return left.directory < right.directory
        }
        let leftCID = try? BlockHeader(node: left.block).rawCID
        let rightCID = try? BlockHeader(node: right.block).rawCID
        return (leftCID ?? "") < (rightCID ?? "")
    }

    private func blockFits(
        _ block: Block,
        spec: ChainSpec,
        fetcher: any Fetcher
    ) async throws -> Bool {
        try await block.logicalContentByteSize(fetcher: fetcher)
            <= spec.maxBlockSize
    }

    private func requireSameTemplateContext(
        _ provisional: Block,
        final: Block
    ) throws {
        guard provisional.version == final.version,
              provisional.parent?.rawCID == final.parent?.rawCID,
              provisional.transactions.rawCID == final.transactions.rawCID,
              provisional.target == final.target,
              provisional.nextTarget == final.nextTarget,
              provisional.spec.rawCID == final.spec.rawCID,
              provisional.parentState.rawCID == final.parentState.rawCID,
              provisional.prevState.rawCID == final.prevState.rawCID,
              provisional.postState.rawCID == final.postState.rawCID,
              provisional.height == final.height,
              provisional.timestamp == final.timestamp,
              provisional.nonce == final.nonce else {
            throw ChainServiceError.templateContextChanged
        }
    }

    private func combineChildren(
        _ provided: [DirectChildCandidate],
        _ deployments: [DirectChildCandidate]
    ) throws -> [DirectChildCandidate] {
        guard deployments.count <= maximumChildCandidates else {
            throw ChainServiceError.childCandidateLimitReached
        }
        let deploymentDirectories = Set(deployments.map(\.directory))
        var byDirectory = Dictionary(
            uniqueKeysWithValues: provided.filter {
                !deploymentDirectories.contains($0.directory)
            }.prefix(
                maximumChildCandidates - deployments.count
            ).map { ($0.directory, $0) }
        )
        for deployment in deployments {
            byDirectory[deployment.directory] = deployment
        }
        return byDirectory.values.sorted { $0.directory < $1.directory }
    }

    private func removeStaleChildIntents(
        parentStateCID: String
    ) async throws {
        let remaining = childIntents.filter {
            $0.value.parentStateCID == parentStateCID
        }
        guard remaining.count != childIntents.count else { return }
        try await replaceChildIntents(remaining)
        childIntents = remaining
    }

    private func replaceChildIntents(
        _ intents: [String: ChildIntent]
    ) async throws {
        try await process.retainChildIntentRoots(
            intents.values.reduce(into: Set<String>()) {
                $0.formUnion($1.volumeRoots)
            }
        )
    }

    private func requireReward(
        _ reward: Transaction?,
        in block: Block
    ) throws {
        guard let reward else { return }
        let rewardCID = try VolumeImpl<Transaction>(node: reward).rawCID
        guard let transactions = block.transactions.node,
              try transactions.allKeysAndValues().values.contains(where: {
                  $0.rawCID == rewardCID
              }) else {
            throw ChainServiceError.invalidRewardTransaction
        }
    }

    private func anchors(in transactions: [Transaction]) -> Set<Anchor> {
        Set(transactions.flatMap { transaction in
            transaction.body.node?.genesisActions.map {
                Anchor(
                    directory: $0.directory,
                    genesisCID: $0.blockCID
                )
            } ?? []
        })
    }

    private func isPendingDeployment(
        _ transaction: Transaction,
        parentStateCID: String
    ) -> Bool {
        let transactionAnchors = anchors(in: [transaction])
        return !transactionAnchors.isEmpty && transactionAnchors.allSatisfy { anchor in
            guard let intent = childIntents[anchor.directory] else {
                return false
            }
            return intent.parentStateCID == parentStateCID
                && intent.genesisCID == anchor.genesisCID
        }
    }

    private func blockTransactions(in block: Block) async throws -> [Transaction] {
        let transactionsHeader = try await block.transactions.resolve(
            fetcher: process
        )
        guard let dictionary = transactionsHeader.node else {
            throw ChainServiceError.unresolvedTransactionContent
        }
        let entries = try await dictionary.boundedKeysAndValues(
            limit: dictionary.count,
            fetcher: process
        )
        guard entries.count == dictionary.count else {
            throw ChainServiceError.unresolvedTransactionContent
        }
        let headers = Dictionary(uniqueKeysWithValues: entries)
        var transactions: [Transaction] = []
        for index in 0..<headers.count {
            guard let transactionHeader = headers[String(index)] else {
                throw ChainServiceError.unresolvedTransactionContent
            }
            let resolved = try await transactionHeader.resolve(fetcher: process)
            guard let transaction = resolved.node else {
                throw ChainServiceError.unresolvedTransactionContent
            }
            transactions.append(transaction)
        }
        return transactions
    }

    private func nextTimestamp(
        after previous: Int64,
        parentCarrier: Block?
    ) throws -> Int64 {
        let (minimum, overflow) = previous.addingReportingOverflow(1)
        guard !overflow else { throw ChainServiceError.timestampOverflow }
        if let parentCarrier { return max(minimum, parentCarrier.timestamp) }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        return max(minimum, now)
    }

    private func acquireOperation() async {
        if !operationInFlight {
            operationInFlight = true
            return
        }
        await withCheckedContinuation {
            operationWaiters.append(.caller($0))
        }
    }

    private func releaseOperation() {
        guard !operationWaiters.isEmpty else {
            operationInFlight = false
            return
        }
        switch operationWaiters.removeFirst() {
        case .caller(let waiter):
            waiter.resume()
        case .canonicalCommit:
            startCanonicalCommitWorker()
        }
    }
}

private extension WorkDisposition {
    init(_ decision: NodeAdmissionDecision) {
        switch decision {
        case .canonicalized: self = .canonicalized
        case .acceptedSide: self = .acceptedSide
        case .carrier: self = .carrier
        case .duplicate: self = .duplicate
        case .unavailable: self = .unavailable
        case .temporarilyInvalid: self = .temporarilyInvalid
        case .invalid: self = .invalid
        case .localFailure: self = .localFailure
        }
    }
}
