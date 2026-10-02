import Crypto
import Foundation
import Ivy
import Lattice
import Synchronization
import UInt256
import VolumeBroker
import cashew

/// Wraps a network candidate's session so admission's reads of it are
/// counted: the CIDs network block admission requests from the session after
/// local storage misses. The session answers some from its per-attempt cache
/// and fetches the rest from the candidate's supplier, so this is an upper
/// bound on supplier requests from the admission path, not a count of them;
/// other acquisition paths (the validate walk, evidence) are not counted.
private struct CountedContentSource: ContentSource {
    let base: any ContentSource
    let count: @Sendable (Int) async -> Void

    func fetch(_ cids: Set<String>) async -> [String: Data] {
        await count(cids.count)
        return await base.fetch(cids)
    }
}

/// Transport-independent operations for one path. A future HTTP layer only
/// decodes a bounded DTO, calls this actor, and encodes the response.
public actor ChainService {
    struct ValidatedRecipientPlan {
        let current: String?
        let descendants: [MiningRecipient]
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
    // the mining-plan BYTE cap already bounds how many entries fit, so no invented
    // recipient/signature COUNT cap is imposed on top of it.
    private static let maximumWorkIDBytes = _wireAtomCapacity
    private static let maximumDirectoryBytes = _wireAtomCapacity
    private static let maximumSignatureFieldBytes = _wireAtomCapacity
    private static let maximumMiningPlanBytes =
        ChainServiceLimits.maximumPayloadBytes
    private static let templateLifetimeSeconds: Int64 = 30
    private static let templateLifetimeMilliseconds: UInt64 = 30_000
    private static let templateCapacity = 16
    private let process: ChainProcess
    private let pool: TransactionPool
    /// The read surface: tip and canonical heights from the process, the
    /// listing from the pool.
    public nonisolated let reads: ChainReads
    private let templates: MiningTemplateBook
    private let network: any NetworkInterface
    /// The co-hosted parent level's facts; nil on Nexus.
    private let parentLevel: (any ParentLevel)?
    /// Hosted children, by directory: told when this level's tip moves, a
    /// run into their directory changes or the miner's plan for them changes
    /// (an enqueue, never a wait); their pre-built candidates are read by
    /// this level's template path without waiting on them.
    private var childLevels: [String: any ChildLevel] = [:]
    /// The miner's plan this level's hosted children build against: on
    /// Nexus, the last template request's plan for its descendants; on a
    /// child, its subtree's part from its parent. Each hosted child is sent
    /// its own subtree's part when that part changes.
    private var descendantPlan = DescendantPlan()
    private var sentDescendantPlans: [String: DescendantPlan] = [:]
    /// This child level's pre-built candidate for its co-hosted parent's
    /// templates, which read it without waiting on this level
    /// (`ChildLevel.readyCandidate`). Rebuilt by one coalesced task
    /// (`scheduleCandidateRebuild`) when the parent's tip, this level's
    /// state, a hosted child's candidate, or the plan changes.
    private nonisolated let readySnapshot = Published<ReadyCandidate>()
    /// The plan for this child level's subtree its parent last sent
    /// (`ParentChange.plan`), newest only; adopted at each rebuild.
    private nonisolated let parentPlan = Published<DescendantPlan>()
    private var candidateRebuild = TaskSlot()
    private var candidateRebuildDirty = false
    /// The provisional carrier the snapshot was built against, reused while
    /// the parent's tip post-state (the one carrier field a candidate binds)
    /// and this level's validated tip stand, so a rebuild whose inputs did
    /// not change builds the same block: the carrier's timestamp is the
    /// block's. A children-only parent block leaves the post-state, so the
    /// block it carried is rebuilt as is and the parent's carried-CID skip
    /// leaves it out; either tip moving stamps a fresh one. So does the
    /// carrier outliving a template's lifetime, but only while the parent's
    /// tip is the one it was stamped on (`parentTipCID`): a children-only
    /// parent block on top must still rebuild the carried block as is.
    private var readyCarrier: (key: String, parentTipCID: String, block: Block)?
    /// Set with the parent mailbox: how the parent level hears that this
    /// level's snapshot changed.
    private var candidateChanged: (@Sendable () async -> Void)?
    /// This child level's mailbox from its co-hosted parent level, and the one
    /// task that drains it in order (`openParentMailbox`). Nil on Nexus and
    /// until the host opens it.
    private var parentMailbox: AsyncStream<Void>.Continuation?
    private var parentMailboxDrain: Task<Void, Never>?
    /// The parent's tip changes, coalesced to one pending signal and drained
    /// by their own task: never queued behind a gate-bound run credit or the
    /// parent's serve walk.
    private var parentTipSignal: AsyncStream<Void>.Continuation?
    private var parentTipDrain: Task<Void, Never>?
    /// Each plan the parent sends (`parentPlan`) signals a rebuild, drained
    /// by its own task.
    private var parentPlanSignal: AsyncStream<Void>.Continuation?
    private var parentPlanDrain: Task<Void, Never>?
    private let maximumChildCandidates: Int
    private var liveMempoolRoots = Set<String>()
    private var mempoolUnavailable = false
    private var canonicalCommitQueue: [QueuedCanonicalCommit] = []
    private var canonicalCommitWorker: Task<Void, Never>?
    private var canonicalCommitWorkerReserved = false
    // Validate-on-candidacy walk: a single coalesced worker (mirrors the
    // canonical-commit worker's reserved-Task + dirty-bit pattern) that executes
    // the canonical branch FORWARD from the deepest validated ancestor so the
    // node becomes/stays operable after a weighed (deferred-execution) sync. It
    // deliberately does NOT hold this actor's operation gate: it re-acquires the
    // process gate per block, so holding the service gate would head-of-line-block
    // every other operation for the length of a deep catch-up.
    private var executionWalkWorker: Task<Void, Never>?
    private var executionWalkDirty = false
    /// The last walk pass stopped short of the canonical tip on something it
    /// cannot step past by itself (a missing body or fact, an invalidity, a
    /// block it will not re-execute). While a walk is merely behind and able
    /// to step, no candidate is built; a parked one withholds none.
    private var executionWalkParked = false
    // Network body acquisition for the validate walk (see
    // NetworkInterface.withExecutionBodySource). When the network has a body
    // source the walk pulls a weighed block's deferred body over it; when the
    // body is temporarily unavailable the walk parks and a single delayed
    // retry re-arms it — there is no push signal on body arrival, and once
    // weighed sync completes the fetcher may hold no timed wait to re-drive
    // it, so the walk owns its own liveness retry rather than borrowing the
    // fetcher's. Cross-chain evidence for the walk comes from `parentLevel`:
    // a weighed CHILD block's `.execution` needs the parent fact (state
    // continuity / genesis link) the co-hosted parent level holds; nil parks
    // the walk on the retry timer as an availability gap.
    private let executionWalkRetryInterval: Duration
    private var executionWalkRetryTask: Task<Void, Never>?
    private var executionWalkParkedCount: UInt64 = 0
    /// CIDs network block admission requested from candidates' sessions
    /// (see `CountedContentSource`).
    private var candidateSessionReadCount: UInt64 = 0
    #if DEBUG
    // Test seam: invoked with each height about to be `.execution`-admitted, in
    // walk order. Lets tests assert strictly-forward progress (never tip-first).
    var onExecutionWalkStep: (@Sendable (UInt64) -> Void)?
    #endif
    private var transactionPublications = Set<String>()
    private var transactionPublicationWorker: Task<Void, Never>?
    // Set once by `shutdown()`: no background work is started afterwards.
    private var stopped = false
    // Network ingress calls in flight (`enterIngress`). `shutdown()` waits
    // for them, because a finishing import enqueues a canonical commit.
    private var ingressInFlight = 0
    private var ingressDrainWaiters: [CheckedContinuation<Void, Never>] = []
    // Set once by `closeMiningIngress()`: template and work requests are
    // refused from then on.
    private var miningClosed = false
    // Template and work requests in flight (`enterMining`).
    private var miningInFlight = 0
    private var miningDrainWaiters: [CheckedContinuation<Void, Never>] = []

    // This actor calls other actors and is therefore reentrant. Keep its pool,
    // template cache, and pending intents in one externally observable order.
    private var operationInFlight = false
    private var operationWaiters: [OperationWaiter] = []

    public init(
        process: ChainProcess,
        network: any NetworkInterface,
        parentLevel: (any ParentLevel)? = nil,
        executionWalkRetryInterval: Duration = .seconds(4),
        mempoolMaxCount: Int = 10_000,
        mempoolMaxNonReadyPerSigner: Int = 64,
        maximumChildCandidates: Int = 64
    ) {
        precondition(
            mempoolMaxCount > 0 && mempoolMaxNonReadyPerSigner > 0
                && maximumChildCandidates > 0
        )
        self.executionWalkRetryInterval = executionWalkRetryInterval
        self.process = process
        self.network = network
        self.parentLevel = parentLevel
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
        let pool = self.pool
        reads = ChainReads(
            process: process,
            tip: { await process.readSnapshot() },
            canonicalCID: { await process.canonicalBlockCID(atHeight: $0) },
            mempool: { listing in
                ChainReads.MempoolListing(
                    count: await pool.count,
                    bytes: await pool.byteCount,
                    cids: listing ? await pool.snapshot().map(\.cid) : []
                )
            }
        )
    }

    /// Stop this service's background work and join what is in flight:
    /// the canonical-commit worker (including one reserved behind the
    /// operation gate but not yet started), the validate walk, transaction
    /// publication, and carrier child-proof deliveries. Each captures this
    /// actor, and through it the `ChainProcess` and its exclusive
    /// storage-directory lock, so a caller that closes or reopens the store
    /// must wait for them rather than merely drop its reference.
    ///
    /// It is a one-way door: afterwards the walk, its retry timer,
    /// transaction publication and child-proof delivery are never started
    /// again, and a walk already running stops after its current block.
    /// Canonical commits still drain, because each is already durable in the
    /// process and only its reconciliation is outstanding; they arrive only
    /// through ingress, which the caller stops first (`Node.shutdown()`).
    /// Network ingress (every `ChainInterface` entry) is refused from entry
    /// on, and calls already inside are waited for: the network runtime's
    /// stop cancels its tasks without joining them.
    /// Idempotent: a later call waits for the same join and returns.
    public func shutdown() async {
        stopped = true
        executionWalkRetryTask?.cancel()
        executionWalkRetryTask = nil
        // The parent may still send; what is not drained is dropped (every
        // apply is refused from here on, and a restart re-reads the runs).
        parentMailbox?.finish()
        parentMailbox = nil
        parentTipSignal?.finish()
        parentTipSignal = nil
        parentPlanSignal?.finish()
        parentPlanSignal = nil
        if let drain = parentMailboxDrain {
            await drain.value
            parentMailboxDrain = nil
        }
        if let drain = parentTipDrain {
            await drain.value
            parentTipDrain = nil
        }
        if let drain = parentPlanDrain {
            await drain.value
            parentPlanDrain = nil
        }
        // A rebuild re-checks `stopped` between builds; join the one running.
        await candidateRebuild.take()?.value
        readySnapshot.swap(nil)
        while true {
            if let worker = canonicalCommitWorker ?? executionWalkWorker
                ?? transactionPublicationWorker {
                await worker.value
            } else if canonicalCommitWorkerReserved {
                // Reserved behind a holder of the operation gate: queue
                // behind it so the deferred worker starts and finishes first.
                await acquireOperation()
                releaseOperation()
            } else if ingressInFlight > 0 {
                await withCheckedContinuation { ingressDrainWaiters.append($0) }
            } else {
                return
            }
        }
    }

    /// Refuses template and work requests, and mined handoffs from a parent,
    /// from now on and waits for those already inside, a mined handoff to
    /// hosted children included. A host
    /// stopping calls it on every level before it stops any level, so no
    /// grind is mined into, or handed down to, a level being stopped.
    /// Idempotent.
    public func closeMiningIngress() async {
        miningClosed = true
        while miningInFlight > 0 {
            await withCheckedContinuation { miningDrainWaiters.append($0) }
        }
    }

    /// Admits one template or work request; refused once mining ingress is
    /// closed. Pair with `defer { exitMining() }`.
    private func enterMining() throws {
        guard !miningClosed else { throw ChainServiceError.shuttingDown }
        miningInFlight += 1
    }

    private func exitMining() {
        miningInFlight -= 1
        guard miningInFlight == 0 else { return }
        let waiters = miningDrainWaiters
        miningDrainWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Admits one network ingress call; refused once `shutdown()` has begun.
    /// Pair with `defer { exitIngress() }`.
    private func enterIngress() throws {
        guard !stopped else { throw CancellationError() }
        ingressInFlight += 1
    }

    private func exitIngress() {
        ingressInFlight -= 1
        guard ingressInFlight == 0 else { return }
        let waiters = ingressDrainWaiters
        ingressDrainWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    #if DEBUG
    /// Test seam: no worker is running or reserved and no ingress is inside.
    func isQuiescent() -> Bool {
        canonicalCommitWorker == nil && !canonicalCommitWorkerReserved
            && executionWalkWorker == nil && executionWalkRetryTask == nil
            && transactionPublicationWorker == nil
            && parentMailboxDrain == nil && parentTipDrain == nil
            && parentPlanDrain == nil && candidateRebuild.isEmpty
            && ingressInFlight == 0
    }
    #endif

    public func status() async -> ChainServiceStatusResponse {
        await acquireOperation()
        defer { releaseOperation() }
        let mempoolAvailable = (try? await prepareMempoolLocked()) != nil
        let status = await process.status()
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
            templateDigest: status.tipCID == nil
                ? nil
                : await templateDigestLocked()
        )
    }

    /// The operator `/metrics` exposition: an ungated read costing what
    /// `/health` does (one validated-tip walk plus the live pool count).
    public func metricsExposition(peers: Int, processStartTime: Date) async -> String {
        let tips = await process.metricsTipHeights()
        return renderNodeMetrics(NodeMetricsSample(
            chainPath: process.configuration.chainPath,
            validatedTipHeight: tips.validated,
            weighedTipHeight: tips.weighed,
            overlayPeers: peers,
            mempoolTransactions: await pool.count,
            processStartTime: processStartTime,
            executionWalkParked: executionWalkParkedCount,
            candidateSessionReads: candidateSessionReadCount
        ))
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
    public func importNetworkCandidate(
        _ header: BlockHeader,
        authenticatedChildPackage: AuthenticatedChildPackage?,
        contentSource: any ContentSource,
        weighed: Bool = false
    ) async throws -> NodeImportOutcome {
        try enterIngress()
        defer { exitIngress() }
        let outcome = try await process.importBlock(
            header,
            authenticatedChildPackage: authenticatedChildPackage,
            remoteSource: CountedContentSource(base: contentSource) {
                [weak self] count in
                await self?.countCandidateSessionReads(count)
            },
            mode: weighed ? .header : .full,
            canonicalCommitPublisher: { [self] commit in
                await enqueueCanonicalCommit(commit)
            }
        )
        guard let block = await locallyStoredBlock(header) else {
            // A refused block is intentionally not local chain state.
            return outcome
        }
        await handleImport(
            block: block,
            header: header,
            outcome: outcome
        )
        return outcome
    }

    private func countCandidateSessionReads(_ count: Int) {
        candidateSessionReadCount &+= UInt64(count)
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
        if admission.inserted { publishChainStateChange(tipChanged: false) }
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
        try enterIngress()
        defer { exitIngress() }
        await acquireOperation()
        defer { releaseOperation() }
        let inserted = try await admitTransactionLocked(
            transaction,
            persistLocal: false
        ).inserted
        if inserted { publishChainStateChange(tipChanged: false) }
        return inserted
    }

    public func transactionInventoryRoots() async -> [String] {
        guard (try? enterIngress()) != nil else { return [] }
        defer { exitIngress() }
        await acquireOperation()
        defer { releaseOperation() }
        guard (try? await prepareMempoolLocked()) != nil else { return [] }
        return await pool.snapshot().map(\.cid).sorted()
    }

    /// Service start, before networking: rebuilds only user-submitted durable
    /// entries (peer-originated transactions intentionally remain volatile)
    /// and arms the validate walk if the restart left the validated tier
    /// below the canonical tip — the common state under deferred execution,
    /// and otherwise driven only by a canonical commit, so on a quiet network
    /// templates would build on the stale validated tip indefinitely.
    public func restoreLocalTransactions() async throws {
        await acquireOperation()
        defer { releaseOperation() }
        await reserveExecutionWalkIfBehind()
        try await restoreLocalTransactionsLocked()
        publishChainStateChange()
    }

    private func restoreLocalTransactionsLocked() async throws {
        _ = await pool.clear()
        let durable = try await process.localTransactions()
        guard !durable.isEmpty else {
            try await syncLiveMempoolRootsLocked([])
            return
        }
        let tip = try await process.validatedTipBlock()
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
        let previous = try await process.validatedTipBlock()
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

    /// A Nexus template for `request`, carrying the hosted children's
    /// snapshots. The node serves one miner's plan at a time: a request whose
    /// plan (recipients and minimum work for descendant chains) differs from the
    /// last adopts it, and each child whose part changed rebuilds on it. A
    /// snapshot built on another plan is never carried — that child is left
    /// out of the template, never paid to the wrong miner — so the template
    /// that changes the plan carries no mismatched child, and the rebuilt
    /// snapshots move the digest.
    public func miningTemplate(
        _ request: MiningTemplateRequest
    ) async throws -> MiningTemplateResponse {
        try enterMining()
        defer { exitMining() }
        await acquireOperation()
        defer { releaseOperation() }
        try await prepareMempoolLocked()
        guard process.configuration.address.isNexus else {
            throw ChainServiceError.parentCarrierRequired
        }
        // Children build their next candidates against this miner's plan for
        // them. Read before the build, so a refused plan refuses the request
        // and never reaches a child.
        let recipientPlan = try Self.validatedRecipientPlan(
            request.recipients, chainPath: process.configuration.chainPath
        )
        let minimumWorkPlan = try Self.validatedMinimumWorkPlan(
            request.minimumWork, chainPath: process.configuration.chainPath
        )
        // Adopted before the digest and the build, which carry only the
        // snapshots built on it.
        sendDescendantPlan(DescendantPlan(
            recipients: recipientPlan.descendants,
            minimumWork: minimumWorkPlan.descendants
        ))
        // Read before the build: a child's snapshot may move while it runs,
        // and a digest read after could name a snapshot the template does
        // not carry. Read before, such a move only makes the digest stale,
        // so the miner refreshes.
        let digest = await templateDigestLocked()
        let assembled = try await buildMiningTemplate(
            recipients: request.recipients,
            minimumWork: request.minimumWork,
            parentCarrier: nil
        )
        let issuance = await templates.issueTrackingInsertion(assembled)
        let template = issuance.template
        guard template.remainingLifetimeMilliseconds > 0 else {
            await templates.discard(workID: template.workID)
            throw MiningTemplateError.expired
        }
        return MiningTemplateResponse(
            template: template,
            maximumLifetimeMilliseconds: Self.templateLifetimeMilliseconds,
            templateDigest: digest
        )
    }

    /// One string that changes whenever a template built now would differ
    /// from one built a moment ago: the validated tip, the transactions a
    /// template selects from (an unavailable entry is never selected), and
    /// the child candidates built on the tip's post-state. The template
    /// carries it and status serves it, so a miner comparing the two learns
    /// its work is stale at any level of the hierarchy, not only when this
    /// chain's tip moves.
    private func templateDigestLocked() async -> String {
        var lines: [String] = []
        let tip = try? await process.validatedTipBlock()
        let tipCID = tip.flatMap { try? BlockHeader(node: $0).rawCID }
        lines.append("tip:\(tipCID ?? "")")
        lines.append("mempool:" + (await pool.snapshot()
            .filter { $0.disposition != .unavailable }
            .map(\.cid).sorted().joined(separator: ",")))
        if let tip, let tipCID {
            lines += await childCandidateDigestInput(
                parentStateCID: tip.postState.rawCID, tipCID: tipCID
            )
        }
        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The candidates a template built on `tipCID` (post-state
    /// `parentStateCID`) can carry, one `directory:candidateCID` line per
    /// hosted child, sorted: a template-digest input. A snapshot for another
    /// parent state, or the block the tip's branch already carries, is not
    /// carried, so it is not an input.
    private func childCandidateDigestInput(
        parentStateCID: String,
        tipCID: String
    ) async -> [String] {
        await readyChildCandidates(parentStateCID: parentStateCID, tipCID: tipCID)
            .map { "\($0.candidate.directory):\($0.cid)" }
            .sorted()
    }

    /// Each hosted child's snapshot a template on `tipCID` can carry: one
    /// in the child's own directory, built on the child's part of this
    /// level's plan, binding `parentStateCID` (the tip's
    /// post-state, every carrier's `prevState`), and not the block the tip's
    /// branch already carries for the directory — a children-only carrier
    /// leaves the post-state, so a carried snapshot still binds, and
    /// carrying it again would only credit the same block once more.
    /// Reads the snapshots without waiting on any child (§2.4).
    private func readyChildCandidates(
        parentStateCID: String,
        tipCID: String
    ) async -> [ReadyCandidate] {
        let snapshots = childLevels.compactMap { directory, level -> ReadyCandidate? in
            guard let ready = level.readyCandidate,
                  ready.candidate.directory == directory,
                  ready.parentStateCID == parentStateCID,
                  ready.plan.same(as: descendantPlan.narrowed(
                      to: process.configuration.chainPath + [directory]
                  )) else { return nil }
            return ready
        }
        guard !snapshots.isEmpty else { return [] }
        let carried = await process.carriedChildBlocks(
            on: tipCID, directories: snapshots.map(\.candidate.directory).sorted()
        )
        return snapshots.filter { carried[$0.candidate.directory] != $0.cid }
    }

    /// This child level's snapshot, read without waiting on this actor.
    nonisolated func readyCandidate() -> ReadyCandidate? {
        readySnapshot.value
    }

    #if DEBUG
    /// Test seam: no snapshot rebuild is running or owed.
    func candidateRebuildIdle() -> Bool {
        candidateRebuild.isEmpty
    }

    /// Test seam: how far ahead of the wall clock a rebuild reads the time.
    private var carrierClockOffsetForTesting: Int64 = 0

    func advanceCarrierClockForTesting(milliseconds: Int64) {
        carrierClockOffsetForTesting += milliseconds
    }

    /// Test seam: runs `body` while holding this service's operation lease.
    func withOperationForTesting(_ body: @Sendable () async -> Void) async {
        await acquireOperation()
        defer { releaseOperation() }
        await body()
    }
    #endif

    /// A child candidate for one parent request, built from every field of the
    /// request context, so no caller can drop part of the miner's plan.
    func miningCandidate(
        for context: ChildCandidateRequestContext,
        parentContentSource: any ContentSource
    ) async throws -> DirectChildCandidate {
        try enterIngress()
        defer { exitIngress() }
        // A candidate builds on the validated tip. While the validate walk is
        // stepping, that tip is about to move and the build is the very work
        // that starves the walk, so none is built: this level publishes no
        // snapshot, and the walk's stop reports the state change that
        // rebuilds it. A parked
        // walk never withholds one, since building on the validated tip is
        // how a chain outweighs a branch it cannot validate.
        guard executionWalkWorker == nil else {
            syncTrace("child candidate deferred: validate walk stepping")
            throw ChainServiceError.validateWalkInProgress
        }
        // Behind but not parked: this chain's last candidate landed and
        // awaits validation. Another at the same height would only fork it
        // — one sibling per parent block, and the validated tip crawls under
        // the reorgs — so the walk is armed here if nothing armed it, and
        // its stop reports the state change that rebuilds the snapshot.
        if !executionWalkParked {
            let validated = await process.deepestValidatedCanonicalTip()?.height
            if let target = await process.canonicalTipHeight(),
               (validated.map { Int64($0) } ?? -1) < Int64(target) {
                syncTrace("child candidate deferred: validated \(validated.map(String.init) ?? "none") behind weighed \(target)")
                reserveExecutionWalkWorker()
                throw ChainServiceError.validateWalkInProgress
            }
        }
        do {
            let candidate = try await miningCandidate(
                parentCarrier: context.parentCarrier,
                parentContentSource: parentContentSource,
                recipients: context.recipients,
                minimumWork: context.minimumWork
            )
            syncTrace("child candidate built h=\(candidate.block.height)")
            return candidate
        } catch {
            syncTrace("child candidate build failed: \(error)")
            throw error
        }
    }

    /// Hierarchy-only child candidate construction. The parent level supplies
    /// the provisional carrier whose `prevState` this block must bind.
    /// Private and without defaults: `miningCandidate(for:)` is the only way
    /// in, so no caller can build a candidate from part of the miner's plan.
    private func miningCandidate(
        parentCarrier: Block,
        parentContentSource: any ContentSource,
        recipients: [MiningRecipient],
        minimumWork: [MiningMinimumWork]
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
            recipients: recipients,
            minimumWork: minimumWork,
            parentCarrier: parentCarrier,
            fetcher: fetcher
        )
        let candidateHeader = try BlockHeader(node: template.block)
        // Keep what this candidate needs — its body, transactions, post-state
        // — for as long as the parent may still mine it: retention is this
        // chain's own budget, never a parent's reservation. The carried
        // block's admission owns these roots later; a candidate never
        // carried is evicted by the offer budget.
        try await process.storeContextualCandidate(
            candidateHeader,
            fetcher: fetcher,
            capacity: process.configuration.resourcePolicy
                .maximumRetainedCandidateOffers
        )
        return DirectChildCandidate(
            directory: process.configuration.address.directory,
            block: template.block,
            searchWitness: template.searchWitness
        )
    }

    private func buildMiningTemplate(
        recipients: [MiningRecipient],
        minimumWork: [MiningMinimumWork],
        parentCarrier: Block?,
        fetcher: (any Fetcher)? = nil
    ) async throws -> MiningTemplate {
        let fetcher: any Fetcher = fetcher ?? process
        let previous = try await process.validatedTipBlock()
        // Read the anchor from consensus state once, here, and hand it down.
        // The builder can rediscover it by walking to height 1, but that walk
        // is O(chain depth) and runs per candidate assembly -- many times per
        // template. Nil is still correct (the builder falls back); it is just
        // slow, so this is a performance path, not a validity one.
        let difficultyAnchor = await process.difficultyAnchor(
            forBlockHash: try BlockHeader(node: previous).rawCID
        )
        let spec = try await chainSpec(for: previous)
        // The recipient is a header field, not a transaction: it takes no
        // pool slot, and the builder credits it the reward plus fees.
        let recipient = try Self.validatedRecipientPlan(
            recipients, chainPath: process.configuration.chainPath
        ).current
        let minimumWorkPlan = try Self.validatedMinimumWorkPlan(
            minimumWork, chainPath: process.configuration.chainPath
        )
        let timestamp = try Self.nextTimestamp(
            after: previous.timestamp,
            parentCarrier: parentCarrier
        )
        let candidates: [Transaction]
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
            candidates = contextual
        } else {
            candidates = await pool.transactions(limit: .max)
        }
        let pooled = await Self.policyAcceptedTransactions(
            candidates,
            chainPath: process.configuration.chainPath,
            previous: previous,
            timestamp: timestamp,
            spec: spec,
            fetcher: fetcher
        )
        try await syncLiveMempoolRootsLocked(
            Set(await pool.snapshot().map(\.cid))
        )
        // Merged-mining: attach ongoing (height >= 1) direct-child candidates
        // the hosted child levels pre-built against this level's validated
        // tip. Child geneses are self-contained and self-mined — they are
        // never carried here; they enter parent state as ordinary
        // GenesisAction transactions and come up separately. Read once per
        // template: every carrier the fit search below previews has the
        // tip's post-state as `prevState`, the one field a child binds.
        let provided = await validatedProvidedChildren(
            parentStateCID: previous.postState.rawCID,
            tipCID: try BlockHeader(node: previous).rawCID
        )

        return try await MiningTemplateAssembly.fit(
            chainPath: process.configuration.chainPath,
            lifetime: .seconds(Self.templateLifetimeSeconds),
            previous: previous,
            pooled: pooled,
            provided: provided,
            parentCarrier: parentCarrier,
            timestamp: timestamp,
            rewardRecipient: recipient,
            minimumWork: minimumWorkPlan.works,
            difficultyAnchor: difficultyAnchor,
            spec: spec,
            fetcher: fetcher
        )
    }

    public func submitWork(
        _ request: SubmitWorkRequest
    ) async throws -> SubmitWorkResponse {
        try enterMining()
        defer { exitMining() }
        guard process.configuration.address.isNexus else {
            throw ChainServiceError.parentCarrierRequired
        }
        guard !request.workID.isEmpty,
              request.workID.utf8.count <= Self.maximumWorkIDBytes else {
            throw ChainServiceError.invalidWorkID
        }
        // Verifies the grind clears the template's search target.
        let submission = try await templates.submission(
            workID: request.workID,
            nonce: request.nonce
        )
        let candidate = submission.block
        let header = try BlockHeader(node: candidate)
        // One grind, one subtree insert, content first: the hosted children
        // admit their carried blocks before this level takes its lease and
        // commits its own. No lease is held across the downward await.
        // Nexus is its own root: each hop is the whole proof.
        let admittedChildren = await handOffMined(carrier: candidate, upstream: nil)
        // The template checked the grind against its search target, the
        // easiest of the chains it carries. One that misses Nexus's own
        // target is no Nexus block: it cleared only child targets, and those
        // levels admitted it above. The same work stays open so the miner
        // can keep searching it toward the harder targets it has not cleared
        // yet, instead of abandoning the search at every child hit.
        guard candidate.validateProofOfWork(
            nexusHash: candidate.proofOfWorkHash()
        ) else {
            return SubmitWorkResponse(
                accepted: false,
                disposition: .childOnly,
                tipCID: await process.status().tipCID,
                durableChildProofs: admittedChildren
            )
        }

        await acquireOperation()
        var ownsOperation = true
        defer {
            if ownsOperation { releaseOperation() }
        }
        let outcome = try await process.importBlock(
            header,
            canonicalCommitPublisher: { [self] commit in
                await enqueueCanonicalCommit(commit)
            }
        )
        await applyImportEffects(
            block: candidate,
            header: header,
            outcome: outcome
        )
        await templates.discard(workID: request.workID)

        // The process enqueued this commit while preserving its own mutation
        // order. Release our gate before waiting because reconciliation must
        // acquire the same gate to update the pool and templates.
        releaseOperation()
        ownsOperation = false
        if let receipt = outcome.canonicalCommitReceipt {
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
            durableChildProofs: admittedChildren
        )
    }

    /// Hands a grind this host mined to the hosted child levels `carrier`
    /// commits, in memory (D2), one after another: each gets its carried
    /// block and `upstream` (the proof that reached `carrier`; nil at Nexus,
    /// its own root) composed with the hop from `carrier`, and folds the same
    /// way into its own hosted children before answering. Returns the
    /// children that admitted. Called only with this level's lease released.
    ///
    /// Ordering: `submitWork` hands down before the root imports and commits
    /// its own block, and each level folds into its children before it
    /// answers, so a grind's subtree is inserted content first, children
    /// before their carrier. A crash after the children and before the root
    /// loses only the root block, the miner's own loss, as if it had never
    /// broadcast it. A child level that is not running is skipped; a host
    /// closes mining ingress on every level before it stops any, so no
    /// handoff races a stopping level. Nothing retries a handoff.
    private func handOffMined(
        carrier: Block,
        upstream: ChildBlockProof?
    ) async -> [DirectChildProofSummary] {
        guard let committed = carrier.children.node?.entries,
              let rootHeader = try? BlockHeader(node: carrier) else { return [] }
        var admitted: [DirectChildProofSummary] = []
        for (directory, header) in committed.sorted(by: { $0.key < $1.key }) {
            guard let level = childLevels[directory], let block = header.node,
                  let hop = try? await ChildBlockProof.generate(
                    rootHeader: rootHeader,
                    childDirectory: directory,
                    fetcher: process
                  ) else { continue }
            if await level.admitMined(
                block: block, proof: upstream?.composing(hop: hop) ?? hop
            ) {
                admitted.append(DirectChildProofSummary(
                    directory: directory, childCID: header.rawCID
                ))
            }
        }
        return admitted
    }

    /// The co-hosted parent mined a grind carrying this level's `block`
    /// under `proof` (`ChildLevel.admitMined`): admit it weighed as a network
    /// candidate (the weighed tier reads no parent fact), announce its
    /// proof on this chain's overlay once admitted, then fold the grind into
    /// this level's hosted children whatever this level decided: a block
    /// whose grind missed this level's target still carries them. True iff
    /// this level admitted the block. Counted as mining ingress: once this
    /// level's mining ingress is closed a handoff is refused, and closing
    /// waits for one in flight.
    func admitMinedCarriage(block: Block, proof: ChildBlockProof) async -> Bool {
        guard (try? enterMining()) != nil else { return false }
        defer { exitMining() }
        guard let parentLevel, let header = try? BlockHeader(node: block) else {
            return false
        }
        let package = AuthenticatedChildPackage(
            package: ChildValidationPackage(proof: proof)
        )
        let outcome = try? await importNetworkCandidate(
            header,
            authenticatedChildPackage: package,
            contentSource: parentLevel.contentSource,
            weighed: true
        )
        syncTrace("mined handoff \(header.rawCID.prefix(12)) decision=\(outcome.map { "\($0.decision)" } ?? "failed")")
        if outcome?.decision.isAccepted == true {
            await network.announceCarriedEvidence(package)
        }
        _ = await handOffMined(carrier: block, upstream: proof)
        return outcome?.decision.isAccepted ?? false
    }

    /// Reconciles service-owned state after a candidate was admitted through
    /// gossip, sync, or a co-hosted parent's handoff.
    /// Consensus admission itself remains exclusively in `ChainProcess`.
    private func handleImport(
        block: Block,
        header: BlockHeader,
        outcome: NodeImportOutcome
    ) async {
        await acquireOperation()
        defer { releaseOperation() }
        await applyImportEffects(
            block: block,
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

    /// Deferred execution: if the canonical (weighed-inclusive) tip has run
    /// ahead of the validated tier, execute the gap forward so the node stays
    /// operable. Reserve — never run inline: callers hold the service gate,
    /// and the walk re-acquires the process gate per block. `nil` validated
    /// height means nothing on the main chain is validated yet (below
    /// genesis), so treat it as strictly behind any canonical tip.
    private func reserveExecutionWalkIfBehind() async {
        let validatedHeight = await process.deepestValidatedCanonicalTip()?.height
        if let target = await process.canonicalTipHeight(),
           (validatedHeight.map { Int64($0) } ?? -1) < Int64(target) {
            reserveExecutionWalkWorker()
        }
    }

    /// Coalescing reserve for the validate-on-candidacy walk. Mirrors
    /// `reserveCanonicalCommitWorker`'s single-instance-Task + dirty-bit shape: a
    /// commit that lands mid-walk sets the dirty bit (so the running worker takes
    /// another pass) rather than spawning a second walk. Unlike the canonical
    /// worker this does NOT reserve the operation gate — the walk must interleave
    /// with other operations because it re-takes the process gate per block.
    private func reserveExecutionWalkWorker() {
        guard !stopped else { return }
        executionWalkDirty = true
        guard executionWalkWorker == nil else { return }
        executionWalkWorker = Task { [weak self] in
            await self?.drainExecutionWalk()
        }
    }

    private func drainExecutionWalk() async {
        var caughtUp = false
        while executionWalkDirty {
            executionWalkDirty = false
            caughtUp = await runExecutionWalkPass()
        }
        executionWalkParked = !caughtUp
        executionWalkWorker = nil
        // The walk stopped, caught up or parked: a candidate deferred while
        // it stepped builds now.
        publishChainStateChange()
    }

    /// Arm one delayed re-drive of the validate walk after it parks on a network
    /// availability gap or a store error. A withheld body has no arrival signal
    /// and — once weighed sync has completed — may leave no canonical commit to
    /// re-arm the walk, so a single coalesced timer polls until the body is
    /// servable. A broker-only walk never parks on a fetch, but a store error
    /// can park it in any configuration, so the timer is not gated on a body
    /// source.
    private func scheduleExecutionWalkRetry() {
        guard !stopped, executionWalkRetryTask == nil else { return }
        executionWalkRetryTask = Timers.deadline(
            after: executionWalkRetryInterval,
            generation: 0
        ) { [weak self] _ in
            await self?.fireExecutionWalkRetry()
        }
    }

    private func fireExecutionWalkRetry() {
        executionWalkRetryTask = nil
        reserveExecutionWalkWorker()
    }

    #if DEBUG
    func setExecutionWalkObserver(_ observer: (@Sendable (UInt64) -> Void)?) {
        onExecutionWalkStep = observer
    }
    #endif

    /// One catch-up pass: execute canonical blocks forward from the deepest
    /// validated ancestor until the validated tier meets the canonical tier.
    /// FORWARD (+1), never tip-first — a `.execution` on a block whose parent is
    /// not validated cannot form a valid pre-state. Tip and target are re-read
    /// every iteration so a mid-walk reorg or exclusion re-projection re-targets.
    /// Returns whether the pass reached the canonical tip; `false` is a park.
    @discardableResult
    func runExecutionWalkPass() async -> Bool {
        // Height of the last admit that returned a non-parking decision. If the
        // durable validated height does not advance past it on the next read,
        // park (return) instead of hot-spinning — defence against any future
        // no-progress case (an exclusion that re-projects re-arms a fresh pass).
        var lastAdmittedHeight: UInt64?
        while !stopped {
            let validated = await process.deepestValidatedCanonicalTip()
            guard let target = await process.canonicalTipHeight() else { return true }
            let validatedHeight = validated.map { Int64($0.height) } ?? -1
            if let lastAdmittedHeight, validatedHeight < Int64(lastAdmittedHeight) {
                return false
            }
            if validatedHeight >= Int64(target) { return true }
            let nextHeight = UInt64(validatedHeight + 1)
            // FORWARD-apply on the CURRENT main chain. A weighed admit stored only
            // this block's boundary, so its body (tier-3) is NOT local: pull it over
            // the network via the injected body source. `admit` composes [broker,
            // session], so the local boundary is served free and only the missing
            // body is fetched. With no source wired (empty-block unit contexts whose
            // boundary already is the whole block), admit broker-only as before.
            guard let next = await process.canonicalBlockCID(atHeight: nextHeight)
            else { return false }
            #if DEBUG
            onExecutionWalkStep?(nextHeight)
            #endif
            let header = BlockHeader(rawCID: next, node: nil, encryptionInfo: nil)
            let admitValidate: @Sendable (
                (any ContentSource)?, AuthenticatedChildPackage?
            ) async throws -> NodeImportOutcome = { [self] remoteSource, package in
                try await process.importBlock(
                    header,
                    authenticatedChildPackage: package,
                    remoteSource: remoteSource,
                    mode: .execution,
                    canonicalCommitPublisher: { [self] commit in
                        await enqueueCanonicalCommit(commit)
                    }
                )
            }
            let attempt: @Sendable (
                AuthenticatedChildPackage?
            ) async throws -> NodeImportOutcome = { [network] package in
                try await network.withExecutionBodySource(
                    blockCID: next
                ) { remoteSource in
                    try await admitValidate(remoteSource, package)
                }
            }
            var outcome: NodeImportOutcome
            do {
                outcome = try await attempt(nil)
                // A CHILD block on the validate tier recovers its own proof but
                // may still need a cross-chain fact from the parent. Read it
                // from the parent level exactly as the live path does and
                // re-admit with the merged package; if the parent does not
                // hold it yet, fall through to the availability park below.
                if case .unavailable(let requirement?) = outcome.decision,
                   let parentLevel,
                   let recovered = try? await process
                       .recoveredAuthenticatedChildPackage(for: next),
                   let package = await parentLevel.evidence(
                       for: requirement,
                       child: process.configuration.address,
                       package: recovered
                   ) {
                    outcome = try await attempt(package)
                }
            } catch {
                // A store/durability error is not a verdict: keep acting on the
                // last validated tip. With the hierarchy artifacts persisted
                // BEFORE the marker flips, a deterministic store conflict
                // (conflicting issued parent fact / child proof, genesis
                // authority without a connected parent) throws here every
                // time and no commit would re-arm the walk on a quiet
                // network — a silent permanent stall at this height. Log it
                // and re-attempt on the availability-park timer so it stays
                // observable and never wedges silently.
                syncTrace(
                    "validate walk h=\(nextHeight) store error: \(error)"
                )
                scheduleExecutionWalkRetry()
                return false
            }
            syncTrace(
                "validate walk h=\(nextHeight) decision=\(outcome.decision)"
            )
            switch outcome.decision {
            case .canonicalized, .acceptedSide, .duplicate:
                // SUCCESS promoted weighed->validated (validated height advances),
                // or a deterministic invalidity staged `.exclusion` and fork choice
                // re-projected (the excluded block is off the main chain now). Either
                // way re-read tip/target and continue — never mark an excluded block
                // validated, and never self-loop.
                lastAdmittedHeight = nextHeight
                // The validated tip moved: templates and child candidates
                // build on it.
                publishChainStateChange()
                continue
            case .unavailable:
                // Availability gap: the body is not yet fetchable. Park at the last
                // validated tip (still fully operable) and arm a single delayed
                // retry — the body arrives over the network with no local signal, so
                // the walk polls until it is present. A later canonical commit also
                // re-arms the walk.
                scheduleExecutionWalkRetry()
                return false
            case .temporarilyInvalid:
                // A parked verdict: a not-yet-admissible timestamp, or a root
                // exclusion with no other executed root to stand on (§9.9).
                // The decision does not say which, and a height-0 park can be
                // either (a root's future timestamp parks the same way), so
                // poll for both like an availability gap: the timestamp case
                // resolves by itself, and the root case is a chain with an
                // invalid own genesis — dead until a new root lands — where
                // one genesis-sized prepare per interval is the cost of not
                // guessing. Counted where the operator can see it.
                executionWalkParkedCount += 1
                scheduleExecutionWalkRetry()
                return false
            case .invalid, .proofOfWorkInvalid, .localFailure:
                // Ordering / non-availability park: keep acting on the last
                // validated tip. A later commit re-arms the walk; no self-retry
                // (retrying an invalidity with no new fact would hot-loop).
                return false
            }
        }
        // Stopped by `shutdown()` between blocks.
        return false
    }

    // MARK: - Parent-attributed run work (§9.10)

    /// Serve run reports for a hosted child directory. The host calls it when
    /// the child level starts and when its genesis activates (idempotent,
    /// re-called after every restart); preparing proofs for a directory
    /// serves it too. It walks this chain's whole graph once per directory,
    /// so it is never called from inside a child level's lease (§2.4): the
    /// host hands it to the child's mailbox drain, which holds no lease and
    /// calls it when the child starts and when its genesis activates.
    public func serveRuns(for directory: String) async {
        guard (try? enterIngress()) != nil else { return }
        defer { exitIngress() }
        await process.serveRuns(for: directory)
    }

    /// Derive this level's attributed runs from its co-hosted parent level
    /// (§9.10): derived, never persisted. When a run rose, this level's own
    /// children derive theirs again.
    private func deriveParentRuns() async {
        guard let parentLevel, let parent = await parentLevel.runTree(),
              (try? enterIngress()) != nil else { return }
        defer { exitIngress() }
        let raised = (try? await process.applyParentRuns(
            from: parent,
            canonicalCommitPublisher: { [self] commit in
                await enqueueCanonicalCommit(commit)
            }
        )) ?? false
        if raised { notifyChildrenOfRuns() }
    }

    /// This level's weight moved: each hosted child derives its runs again.
    private func notifyChildrenOfRuns() {
        for level in childLevels.values { level.parentChanged(.runs) }
    }

    private func reconcileCanonicalCommitOrResetLocked(
        _ commit: ChainCommit
    ) async {
        defer { publishChainStateChange() }
        do {
            try await reconcileCanonicalCommitLocked(commit)
        } catch {
            _ = await pool.clear()
            do {
                try await syncLiveMempoolRootsLocked([])
            } catch {}
            mempoolUnavailable = true
            await invalidateTemplatesLocked()
        }
    }

    private func applyImportEffects(
        block: Block,
        header: BlockHeader,
        outcome: NodeImportOutcome
    ) async {
        // Visibility of accepted work is independent from optional child
        // materialization. A missing child payload must not suppress the
        // canonical announcement.
        switch outcome.decision {
        case .canonicalized(let commit):
            if outcome.canonicalCommitReceipt == nil {
                await reconcileCanonicalCommitOrResetLocked(commit)
            }
            try? await network.publishAcceptedBlock(header.rawCID)
        case .acceptedSide:
            try? await network.publishAcceptedBlock(header.rawCID)
        default:
            break
        }

        // §9.10: this level's weight moved, so its children's runs and its
        // own (as a child) are derived again.
        if outcome.decision.isAccepted {
            notifyChildrenOfRuns()
            parentMailbox?.yield()
        }
        if outcome.decision.isAccepted {
            publishChainStateChange()
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
        // Reserved BEFORE the mempool bookkeeping below: operability must not
        // hinge on it, and a body-less weighed tip is exactly the case where
        // that bookkeeping has the least to work with.
        await reserveExecutionWalkIfBehind()
        try await prepareMempoolLocked()

        let addedTransactions = try await transactions(
            inBlocks: commit.canonicalBlocksAdded.keys.sorted()
        )
        let removedTransactions = try await transactions(
            inBlocks: commit.canonicalBlocksRemoved.sorted()
        )
        let tip = try await process.validatedTipBlock()
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
        for cid in removedByCID.keys.sorted() where pooledRoots.contains(cid) {
            scheduleTransactionPublication(cid)
        }
    }

    private func scheduleTransactionPublication(_ cid: String) {
        guard !stopped else { return }
        transactionPublications.insert(cid)
        guard transactionPublicationWorker == nil else { return }
        transactionPublicationWorker = Task {
            await drainTransactionPublications()
        }
    }

    private func drainTransactionPublications() async {
        while let cid = transactionPublications.popFirst() {
            try? await network.publishTransaction(cid)
        }
        transactionPublicationWorker = nil
    }

    private func invalidateTemplatesLocked() async {
        await templates.invalidateAll()
    }

    /// Fire-and-forget: never hold the service lease across the network.
    /// Untracked: touches only the network, never the store. A change that
    /// can move the tip also tells the hosted children, which never blocks.
    private func publishChainStateChange(tipChanged: Bool = true) {
        // A mempool change alone (`tipChanged: false`) rebuilds no snapshot:
        // the next rebuild picks its transactions up, so peer gossip never
        // churns the snapshot, the retained candidates or the digest.
        if tipChanged {
            for level in childLevels.values { level.parentChanged(.tipChanged) }
            scheduleCandidateRebuild()
        }
    }

    /// The host attaches a hosted child level: told each time this level's
    /// tip moves, a run into its directory changes or its plan changes
    /// (never blocking), and its snapshot read by this level's templates.
    /// Replaces the directory's previous child, as a restarted child level
    /// does, and sends it the plan as it stands.
    func attachChildLevel(_ level: any ChildLevel) {
        childLevels[level.directory] = level
        sentDescendantPlans[level.directory] = nil
        sendDescendantPlan(descendantPlan)
    }

    /// Adopts `plan` for this level's hosted children and sends each child
    /// its subtree's part when that part changed: a coalesced enqueue.
    private func sendDescendantPlan(_ plan: DescendantPlan) {
        descendantPlan = plan
        for (directory, level) in childLevels {
            let part = plan.narrowed(
                to: process.configuration.chainPath + [directory]
            )
            // A child starts on the empty plan: only a change is sent.
            if (sentDescendantPlans[directory] ?? DescendantPlan()).same(as: part) {
                continue
            }
            sentDescendantPlans[directory] = part
            level.parentChanged(.plan(part))
        }
    }

    /// A hosted child published a new snapshot. On a child level, this
    /// level's own candidate carries it, so it is rebuilt; on Nexus, the
    /// template digest reads it, so nothing else moves.
    func childCandidateChanged() {
        scheduleCandidateRebuild()
    }

    /// Rebuilds this child level's snapshot: one build at a time, and a
    /// change during a build runs one more, with the inputs that stand then.
    private func scheduleCandidateRebuild() {
        guard parentLevel != nil, candidateChanged != nil, !stopped else { return }
        candidateRebuildDirty = true
        candidateRebuild.start { token in
            Task { [weak self] in
                await self?.runCandidateRebuilds(token: token)
            }
        }
    }

    private func runCandidateRebuilds(token: LifetimeToken) async {
        defer { candidateRebuild.clear(token) }
        while candidateRebuildDirty, !stopped, candidateRebuild.holds(token) {
            candidateRebuildDirty = false
            let built = await buildReadyCandidate()
            guard !stopped, candidateRebuild.holds(token) else { return }
            if readySnapshot.swap(built)?.cid != built?.cid {
                syncTrace("ready candidate \(built.map { "h=\($0.candidate.block.height) \($0.cid.prefix(12))" } ?? "withdrawn")")
                // Outside this level's lease: the parent level only marks
                // its own rebuild (§2.4).
                await candidateChanged?()
            }
        }
    }

    /// This level's candidate against a provisional carrier on the parent's
    /// validated tip, read gate-free, under this level's own lease only. Nil
    /// while the validate walk steps or is behind, or before the parent or
    /// this level can build.
    private func buildReadyCandidate() async -> ReadyCandidate? {
        guard let parentLevel else { return nil }
        // The plan this level and its hosted children build against.
        if let plan = parentPlan.value, !plan.same(as: descendantPlan) {
            sendDescendantPlan(plan)
        }
        guard await process.status().phase == .active else { return nil }
        guard let tip = await parentLevel.validatedTip() else { return nil }
        let carrierKey = tip.block.postState.rawCID + "|"
            + (await process.deepestValidatedCanonicalTip()?.cid ?? "")
        var now = Int64(Date().timeIntervalSince1970 * 1_000)
        #if DEBUG
        now += carrierClockOffsetForTesting
        #endif
        let carrier: Block
        if let ready = readyCarrier, ready.key == carrierKey,
           ready.parentTipCID != tip.cid
            || now - ready.block.timestamp < Int64(Self.templateLifetimeMilliseconds) {
            carrier = ready.block
        } else {
            guard let fresh = Self.provisionalCarrier(
                on: tip.block,
                tipCID: tip.cid,
                timestamp: max(now, tip.block.timestamp + 1)
            ) else { return nil }
            readyCarrier = (carrierKey, tip.cid, fresh)
            carrier = fresh
        }
        let plan = descendantPlan
        let candidate = try? await miningCandidate(
            for: ChildCandidateRequestContext(
                parentCarrier: carrier,
                recipients: plan.recipients,
                minimumWork: plan.minimumWork
            ),
            parentContentSource: parentLevel.contentSource
        )
        return candidate.flatMap { ReadyCandidate($0, plan: plan) }
    }

    /// A hosted child's inbox from its parent level. `send` enqueues and
    /// returns: the parent never waits on the child. Runs are queued in
    /// order; tip changes are coalesced into one pending signal.
    struct ParentMailbox: Sendable {
        fileprivate let continuation: AsyncStream<Void>.Continuation
        fileprivate let tipSignal: AsyncStream<Void>.Continuation
        fileprivate let plan: Published<DescendantPlan>
        fileprivate let planSignal: AsyncStream<Void>.Continuation

        func send(_ change: ParentChange) {
            switch change {
            case .tipChanged: tipSignal.yield()
            case .runs: continuation.yield()
            case .plan(let plan):
                self.plan.swap(plan)
                planSignal.yield()
            }
        }
    }

    /// Opens this child level's parent mailbox; the host calls it once, when
    /// the level starts. One task drains the run signals, coalesced: each runs
    /// `serveParentRuns` (the parent serves this directory's runs;
    /// idempotent) and then derives this level's attributed runs from the
    /// parent's tree, never persisted, so a restart re-derives them. The
    /// drain holds no lease of this level, so `serveParentRuns` may take the
    /// parent's gate (§2.4). Tip changes run `tipChanged` on a second task,
    /// coalesced, and then rebuild this level's snapshot; a plan change,
    /// kept newest only, rebuilds it from a third. `candidateChanged` tells
    /// the parent level this level's snapshot changed. `shutdown` finishes
    /// all three and joins them.
    func openParentMailbox(
        tipChanged: @escaping @Sendable () async -> Void,
        serveParentRuns: @escaping @Sendable () async -> Void,
        candidateChanged: @escaping @Sendable () async -> Void
    ) -> ParentMailbox {
        precondition(parentMailbox == nil, "one parent mailbox per level")
        let (stream, continuation) = AsyncStream.makeStream(
            of: Void.self, bufferingPolicy: .bufferingNewest(1)
        )
        let (tips, tipSignal) = AsyncStream.makeStream(
            of: Void.self, bufferingPolicy: .bufferingNewest(1)
        )
        let (plans, planSignal) = AsyncStream.makeStream(
            of: Void.self, bufferingPolicy: .bufferingNewest(1)
        )
        if stopped {
            continuation.finish()
            tipSignal.finish()
            planSignal.finish()
        } else {
            self.candidateChanged = candidateChanged
            parentMailbox = continuation
            parentTipSignal = tipSignal
            parentPlanSignal = planSignal
            parentMailboxDrain = Task { [weak self] in
                for await _ in stream {
                    guard let self else { return }
                    // Idempotent, and O(1) once served: the parent may have
                    // started after this level opened.
                    await serveParentRuns()
                    await self.deriveParentRuns()
                }
            }
            parentTipDrain = Task { [weak self] in
                for await _ in tips {
                    await tipChanged()
                    await self?.scheduleCandidateRebuild()
                }
            }
            parentPlanDrain = Task { [weak self] in
                for await _ in plans { await self?.scheduleCandidateRebuild() }
            }
            continuation.yield()
            scheduleCandidateRebuild()
        }
        return ParentMailbox(
            continuation: continuation,
            tipSignal: tipSignal,
            plan: parentPlan,
            planSignal: planSignal
        )
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
            // An accepted-but-weighed (deferred-execution) block holds no body
            // locally yet: there is nothing of it to reconcile until the walk
            // validates it, and pool revalidation against the validated tip
            // covers the rest. An unknown block still fails below.
            if await process.hasAcceptedBlock(cid),
               await process.blockValidated(cid) == false {
                continue
            }
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

    /// A miner's recipients by chain path: this chain's, which its template
    /// commits, and the descendants', which travel with the child candidate
    /// requests. Each is a canonical address on a chain at or below this one,
    /// at most one per chain.
    static func validatedRecipientPlan(
        _ recipients: [MiningRecipient],
        chainPath currentPath: [String]
    ) throws -> ValidatedRecipientPlan {
        guard let encoded = try? JSONEncoder().encode(
                  MiningTemplateRequest(recipients: recipients)
              ),
              encoded.count <= Self.maximumMiningPlanBytes else {
            throw ChainServiceError.invalidRecipientPlan
        }
        var seen: Set<String> = []
        var current: String?
        var descendants: [MiningRecipient] = []
        for recipient in recipients {
            guard let address = ChainAddress(recipient.chainPath),
                  address.components.count >= currentPath.count,
                  Array(address.components.prefix(currentPath.count))
                    == currentPath,
                  seen.insert(address.key).inserted,
                  CryptoUtils.isValidAddress(recipient.address) else {
                throw ChainServiceError.invalidRecipientPlan
            }
            if address.components == currentPath {
                current = recipient.address
            } else {
                descendants.append(MiningRecipient(
                    chainPath: address.components,
                    address: recipient.address
                ))
            }
        }
        return ValidatedRecipientPlan(
            current: current,
            descendants: descendants.sorted {
                $0.chainPath.lexicographicallyPrecedes($1.chainPath)
            }
        )
    }

    /// A miner's minimum-work entries by chain path — this chain's and its
    /// descendants', which bound the template's search — and the descendants'
    /// alone, which travel with the child candidate requests.
    static func validatedMinimumWorkPlan(
        _ entries: [MiningMinimumWork],
        chainPath currentPath: [String]
    ) throws -> (works: [[String]: UInt256], descendants: [MiningMinimumWork]) {
        // The same payload cap the recipient plan honours. Bounding it here means
        // an oversized plan is a named refusal to the miner that sent it,
        // rather than a descendant request that silently fails to encode and
        // leaves that child with no candidate for the round.
        guard let encoded = try? JSONEncoder().encode(
                  MiningTemplateRequest(minimumWork: entries)
              ),
              encoded.count <= Self.maximumMiningPlanBytes else {
            throw ChainServiceError.minimumWorkPlanTooLarge
        }
        var seen: Set<String> = []
        var works: [[String]: UInt256] = [:]
        var descendants: [MiningMinimumWork] = []
        for entry in entries {
            guard let address = ChainAddress(entry.chainPath),
                  address.components.count >= currentPath.count,
                  Array(address.components.prefix(currentPath.count))
                    == currentPath,
                  seen.insert(address.key).inserted,
                  entry.work > .zero,
                  entry.work <= maximumRepresentableWork else {
                throw ChainServiceError.invalidMinimumWork
            }
            works[address.components] = entry.work
            if address.components != currentPath {
                descendants.append(entry)
            }
        }
        return (
            works,
            descendants.sorted {
                $0.chainPath.lexicographicallyPrecedes($1.chainPath)
            }
        )
    }

    /// Bounded, deduplicated set of ongoing (height >= 1) direct child
    /// candidates the hosted child levels pre-built, each binding
    /// `parentStateCID` (every carrier's `prevState`) and offering a valid
    /// scheduling target.
    private func validatedProvidedChildren(
        parentStateCID: String,
        tipCID: String
    ) async -> [DirectChildCandidate] {
        let candidates = await readyChildCandidates(
            parentStateCID: parentStateCID, tipCID: tipCID
        ).map(\.candidate)
        var directories: Set<String> = []
        var accepted: [DirectChildCandidate] = []
        for candidate in candidates.sorted(by: candidateOrder) {
            guard (try? BlockHeader(node: candidate.block)) != nil,
                  accepted.count < maximumChildCandidates,
                  candidate.directory.utf8.count <= Self.maximumDirectoryBytes,
                  !directories.contains(candidate.directory),
                  ChainAddress(
                      process.configuration.chainPath + [candidate.directory]
                  ) != nil,
                  candidate.block.parentState.rawCID == parentStateCID,
                  // Paid to the miner's recipient for that chain (nil when
                  // the plan names none), never one the child chose.
                  candidate.block.rewardRecipient == descendantPlan.recipients.first(where: {
                      $0.chainPath == process.configuration.chainPath + [candidate.directory]
                  })?.address else {
                continue
            }
            guard await schedulingTargets(for: candidate) != nil,
                  directories.insert(candidate.directory).inserted else {
                continue
            }
            accepted.append(candidate)
        }
        syncTrace("child candidates: \(accepted.count) of \(childLevels.count) hosted children")
        return accepted
    }

    /// The carrier a child builds against: a block on its parent's tip whose
    /// `prevState` is the tip's post-state — the one field the builder takes
    /// from a carrier — stamped with `timestamp`. Every real carrier the
    /// parent mines on that tip has the same `prevState`, so the candidate
    /// fits any of them.
    static func provisionalCarrier(
        on tip: Block,
        tipCID: String,
        timestamp: Int64
    ) -> Block? {
        guard let emptyTransactions = try? HeaderImpl<
                  MerkleDictionaryImpl<VolumeImpl<Transaction>>
              >(node: MerkleDictionaryImpl<VolumeImpl<Transaction>>()),
              let emptyChildren = try? HeaderImpl<FlatDictionary<BlockHeader>>(node: FlatDictionary<BlockHeader>()),
              tip.height < UInt64.max else { return nil }
        return Block(
            version: tip.version,
            parent: VolumeImpl<Block>(rawCID: tipCID),
            transactions: emptyTransactions,
            target: tip.nextTarget,
            nextTarget: tip.nextTarget,
            spec: tip.spec,
            parentState: tip.parentState,
            prevState: tip.postState.removingNode(),
            postState: tip.postState.removingNode(),
            children: emptyChildren,
            height: tip.height + 1,
            timestamp: timestamp,
            rewardRecipient: nil,
            nonce: 0
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

    private func blockTransactions(in block: Block) async throws -> [Transaction] {
        try await MiningTemplateAssembly.blockTransactions(in: block, fetcher: process)
    }

    /// Policies may read the carrying block's height and timestamp, which a
    /// pool verdict (taken against the tip, at its own time) did not see. Offer
    /// only transactions the policies accept for THIS template; a skipped one
    /// stays pooled until it passes or a tip change evicts it.
    static func policyAcceptedTransactions(
        _ transactions: [Transaction],
        chainPath: [String],
        previous: Block,
        timestamp: Int64,
        spec: ChainSpec,
        fetcher: any Fetcher
    ) async -> [Transaction] {
        guard !spec.wasmPolicies.isEmpty else { return transactions }
        let (height, overflow) = previous.height.addingReportingOverflow(1)
        guard !overflow else { return [] }
        var accepted: [Transaction] = []
        for transaction in transactions {
            guard let body = try? await transaction.body.resolve(fetcher: fetcher).node,
                  (try? await TransactionBody.batchVerifyPolicies(
                      bodies: [body],
                      spec: spec,
                      chainPath: chainPath,
                      height: height,
                      timestamp: timestamp,
                      fetcher: fetcher
                  )) == true else { continue }
            accepted.append(transaction)
        }
        return accepted
    }

    static func nextTimestamp(
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

extension WorkDisposition {
    init(_ decision: NodeImportDecision) {
        switch decision {
        case .canonicalized: self = .canonicalized
        case .acceptedSide: self = .acceptedSide
        case .duplicate: self = .duplicate
        case .unavailable: self = .unavailable
        case .temporarilyInvalid: self = .temporarilyInvalid
        case .proofOfWorkInvalid: self = .proofOfWorkInvalid
        case .invalid: self = .invalid
        case .localFailure: self = .localFailure
        }
    }
}

/// A value one side publishes and another reads without waiting on the
/// publisher's actor: a child level's snapshot (read by its parent's
/// template path) and the plan a parent sends a child.
final class Published<Value: Sendable>: Sendable {
    private let current = Mutex<Value?>(nil)

    var value: Value? { current.withLock { $0 } }

    /// Publishes `value`; the value it replaced.
    @discardableResult
    func swap(_ value: Value?) -> Value? {
        current.withLock { current in
            defer { current = value }
            return current
        }
    }
}

extension ChainService {
    nonisolated func syncTrace(_ message: @autoclosure () -> String) {
        SyncTrace.log(chain: process.configuration.chainPath, message())
    }
}
