import Lattice
import UInt256

/// Where a transaction came from, which decides what admitting it owes.
public enum TransactionOrigin: Sendable, Equatable {
    /// An RPC submit: journaled, announced, and answered under `replyID`.
    case local(replyID: UInt64)
    /// Peer gossip: volatile, never answered, never blamed.
    case peer(PeerID)
    /// It left the executed chain when the tip moved: re-admitted and
    /// announced.
    case returned
    /// Boot replay of the local journal, with its original arrival time.
    case restored(addedAt: Int64)
}

/// The executed tip moved: the transactions the new chain carries that the
/// old one did not, and those the old chain carried that the new one does not.
public struct TipMove: Sendable {
    public let tipCID: String
    public let confirmed: Set<String>
    public let returned: [Transaction]

    public init(tipCID: String, confirmed: Set<String>, returned: [Transaction]) {
        self.tipCID = tipCID
        self.confirmed = confirmed
        self.returned = returned
    }
}

/// Classify one transaction against the executed tip `tipCID` (Lattice's
/// `preflightTransaction`). Built from `poolVersion`.
public struct PreflightJob: Sendable {
    public let cid: String
    public let transaction: Transaction
    public let tipCID: String
    public let poolVersion: UInt64
}

/// A miner's plan for a template: who the block credits, and the minimum
/// work per chain path the miner searches for.
public struct TemplateRequest: Sendable, Equatable {
    public let rewardRecipient: String?
    public let minimumWork: [[String]: UInt256]

    public init(rewardRecipient: String?, minimumWork: [[String]: UInt256] = [:]) {
        self.rewardRecipient = rewardRecipient
        self.minimumWork = minimumWork
    }
}

/// Assemble a candidate on the executed tip `tipCID` from `transactions`, in
/// this order, read from the pool at `poolVersion`.
public struct TemplateJob: Sendable {
    public let id: UInt64
    public let tipCID: String
    public let poolVersion: UInt64
    public let transactions: [Transaction]
    public let request: TemplateRequest
}

/// What a template job assembled.
public struct TemplateBuild: Sendable {
    public let workID: String
    public let block: Block
    public let searchTarget: UInt256
    public let targets: [UInt256]

    public init(workID: String, block: Block, searchTarget: UInt256, targets: [UInt256]) {
        self.workID = workID
        self.block = block
        self.searchTarget = searchTarget
        self.targets = targets
    }
}

public enum MiningEvent: Sendable {
    /// A transaction whose content the shell has resolved.
    case transactionReceived(Transaction, origin: TransactionOrigin)
    case preflighted(PreflightJob, MempoolDisposition)
    case tipMoved(TipMove)
    case templateRequested(replyID: UInt64, TemplateRequest)
    /// nil: the job could not build a block on its tip.
    case templateBuilt(TemplateJob, TemplateBuild?)
    case submitWork(replyID: UInt64, workID: String, nonce: UInt64)
}

/// The pool's durable side of one step. The shell applies it before any later
/// effect of the same step: pins for `added`, journal rows for `journaled`,
/// and both dropped for `removed`.
public struct PoolDelta: Sendable {
    public var added: [MempoolItem] = []
    public var journaled: [MempoolItem] = []
    public var removed: [String] = []

    var isEmpty: Bool { added.isEmpty && journaled.isEmpty && removed.isEmpty }
}

public enum MiningEffect: Sendable {
    case poolChanged(PoolDelta)
    case transactionAdmitted(replyID: UInt64, cid: String, count: Int, bytes: Int)
    case transactionRefused(replyID: UInt64, MempoolError)
    case announceTransaction(String)
    case templateIssued(replyID: UInt64, WorkTemplate)
    case templateRefused(replyID: UInt64, TemplateError)
    /// A grind cleared the search target: insert the block (and the carried
    /// blocks it secures) as one subtree, then answer `replyID`.
    case mined(replyID: UInt64, Block)
    case workRefused(replyID: UInt64, TemplateError)
    case preflight(PreflightJob)
    case buildTemplate(TemplateJob)
}

public struct MiningConfig: Sendable {
    /// Transactions waiting on a preflight verdict before admission.
    public var maxPendingAdmissions: Int
    /// Template requests waiting on a build.
    public var maxWaitingTemplateRequests: Int
    public var mempool: MempoolLimits
    public var templateLifetime: Int64
    public var templateCapacity: Int

    public init(
        maxPendingAdmissions: Int = 1_024,
        maxWaitingTemplateRequests: Int = 64,
        mempool: MempoolLimits = MempoolLimits(),
        templateLifetime: Int64 = 30_000,
        templateCapacity: Int = 16
    ) {
        self.maxPendingAdmissions = maxPendingAdmissions
        self.maxWaitingTemplateRequests = maxWaitingTemplateRequests
        self.mempool = mempool
        self.templateLifetime = templateLifetime
        self.templateCapacity = templateCapacity
    }
}

/// One level's mempool and template book, and the jobs that feed them, behind
/// one synchronous `step`. No IO, no awaits.
///
/// Jobs replace the leases and fences: a preflight or template job names the
/// executed tip it ran on, and a result for a tip that has since moved is
/// dropped. The tip move itself reissues every preflight the pool still
/// needs, and a stale template build is rebuilt from the current pool.
public struct Mining: Sendable {
    public private(set) var mempool: Mempool
    public private(set) var templates: TemplateBook
    /// The executed tip transactions and templates build on.
    public private(set) var tipCID: String
    public let spec: ChainSpec
    public let config: MiningConfig

    private struct Admission {
        let transaction: Transaction
        var origins: [TransactionOrigin]
    }

    /// Transactions awaiting a verdict before admission.
    private var admissions: [String: Admission] = [:]
    /// The tip each outstanding preflight was issued for.
    private var preflighting: [String: String] = [:]
    /// Pooled transactions in the local journal.
    public private(set) var journaled: Set<String> = []
    private var builds: [UInt64: (job: TemplateJob, replies: [UInt64])] = [:]
    private var nextJobID: UInt64 = 1

    public init(tipCID: String, spec: ChainSpec, config: MiningConfig = MiningConfig()) {
        self.tipCID = tipCID
        self.spec = spec
        self.config = config
        self.mempool = Mempool(limits: config.mempool)
        self.templates = TemplateBook(lifetime: config.templateLifetime, capacity: config.templateCapacity)
    }

    public var pendingAdmissions: Int { admissions.count }
    public var waitingTemplateRequests: Int { builds.values.reduce(0) { $0 + $1.replies.count } }
    public var outstandingPreflights: Int { preflighting.count }

    public mutating func step(_ event: MiningEvent, now: Int64) -> [MiningEffect] {
        var turn = Turn()
        switch event {
        case .transactionReceived(let transaction, let origin):
            receive(transaction, origin: origin, now: now, &turn)
        case .preflighted(let job, let disposition):
            preflighted(job, disposition, now: now, &turn)
        case .tipMoved(let move):
            tipMoved(move, &turn)
        case .templateRequested(let replyID, let request):
            requestTemplate(request, replyIDs: [replyID], &turn)
        case .templateBuilt(let job, let build):
            built(job, build, now: now, &turn)
        case .submitWork(let replyID, let workID, let nonce):
            do {
                let block = try templates.submission(workID: workID, nonce: nonce, now: now)
                // A grind that clears only child targets leaves the work open,
                // so the miner keeps searching it toward the root's target.
                if block.proofOfWorkHash() <= block.target {
                    templates.discard(workID: workID)
                }
                turn.replies.append(.mined(replyID: replyID, block))
            } catch {
                turn.replies.append(.workRefused(replyID: replyID, error as? TemplateError ?? .unknownWork))
            }
        }
        return turn.effects
    }

    /// One step's output: the durable delta first, then replies and
    /// announces, then jobs.
    private struct Turn {
        var delta = PoolDelta()
        var replies: [MiningEffect] = []
        var jobs: [MiningEffect] = []

        var effects: [MiningEffect] {
            (delta.isEmpty ? [] : [.poolChanged(delta)]) + replies + jobs
        }
    }

    // MARK: - Transactions

    private mutating func receive(
        _ transaction: Transaction,
        origin: TransactionOrigin,
        now: Int64,
        _ turn: inout Turn
    ) {
        let cid: String
        do {
            cid = try mempool.check(transaction, spec: spec)
        } catch {
            refuse([origin], cid: nil, error as? MempoolError ?? .unresolved, &turn)
            return
        }
        if let pooled = mempool.item(cid) {
            // Already admitted on this tip; each tip move preflights it again.
            admitted(pooled, origins: [origin], &turn)
            return
        }
        if admissions[cid] != nil {
            admissions[cid]?.origins.append(origin)
            return
        }
        guard admissions.count < config.maxPendingAdmissions else {
            refuse([origin], cid: cid, .full, &turn)
            return
        }
        admissions[cid] = Admission(transaction: transaction, origins: [origin])
        preflight(cid, transaction, &turn)
    }

    private mutating func preflight(_ cid: String, _ transaction: Transaction, _ turn: inout Turn) {
        guard preflighting[cid] != tipCID else { return }
        preflighting[cid] = tipCID
        turn.jobs.append(.preflight(PreflightJob(
            cid: cid, transaction: transaction, tipCID: tipCID, poolVersion: mempool.version
        )))
    }

    private mutating func preflighted(
        _ job: PreflightJob,
        _ disposition: MempoolDisposition,
        now: Int64,
        _ turn: inout Turn
    ) {
        // A verdict on a tip that has moved is dropped: the move reissued the
        // job on the new tip.
        guard job.tipCID == tipCID else { return }
        if preflighting[job.cid] == job.tipCID { preflighting[job.cid] = nil }
        if let admission = admissions.removeValue(forKey: job.cid) {
            admit(admission, cid: job.cid, disposition, now: now, &turn)
        } else {
            let mutation = mempool.reclassify(job.cid, as: disposition)
            departed(mutation, &turn)
        }
    }

    private mutating func admit(
        _ admission: Admission,
        cid: String,
        _ disposition: MempoolDisposition,
        now: Int64,
        _ turn: inout Turn
    ) {
        let restoredAt = admission.origins.lazy.compactMap { origin -> Int64? in
            if case .restored(let addedAt) = origin { return addedAt }
            return nil
        }.first
        do {
            let mutation = try mempool.submit(
                admission.transaction,
                spec: spec,
                disposition: disposition,
                addedAt: restoredAt ?? now
            )
            departed(mutation, &turn)
            if let inserted = mutation.inserted { turn.delta.added.append(inserted) }
            guard let item = mempool.item(cid) else { return }
            admitted(item, origins: admission.origins, &turn)
        } catch {
            refuse(admission.origins, cid: cid, error as? MempoolError ?? .invalidState, &turn)
        }
    }

    /// `item` is pooled: journal and answer each local origin, and announce
    /// it for a local or returned one.
    private mutating func admitted(_ item: MempoolItem, origins: [TransactionOrigin], _ turn: inout Turn) {
        var announce = false
        for origin in origins {
            switch origin {
            case .local(let replyID):
                journal(item, &turn)
                announce = true
                turn.replies.append(.transactionAdmitted(
                    replyID: replyID, cid: item.cid, count: mempool.count, bytes: mempool.byteCount
                ))
            case .restored:
                // Its journal row is already durable.
                journaled.insert(item.cid)
            case .returned:
                announce = true
            case .peer:
                break
            }
        }
        if announce { turn.replies.append(.announceTransaction(item.cid)) }
    }

    private mutating func journal(_ item: MempoolItem, _ turn: inout Turn) {
        guard journaled.insert(item.cid).inserted else { return }
        turn.delta.journaled.append(item)
    }

    private mutating func refuse(
        _ origins: [TransactionOrigin],
        cid: String?,
        _ error: MempoolError,
        _ turn: inout Turn
    ) {
        for origin in origins {
            switch origin {
            case .local(let replyID):
                turn.replies.append(.transactionRefused(replyID: replyID, error))
            case .restored:
                // The journal row goes with the refusal.
                if let cid { turn.delta.removed.append(cid) }
            case .peer, .returned:
                break
            }
        }
    }

    private mutating func departed(_ mutation: MempoolMutation, _ turn: inout Turn) {
        for item in mutation.departed {
            journaled.remove(item.cid)
            turn.delta.added.removeAll { $0.cid == item.cid }
            turn.delta.journaled.removeAll { $0.cid == item.cid }
            turn.delta.removed.append(item.cid)
        }
    }

    private mutating func tipMoved(_ move: TipMove, _ turn: inout Turn) {
        tipCID = move.tipCID
        departed(mempool.remove(move.confirmed.sorted()), &turn)
        for transaction in move.returned {
            guard let cid = try? Mempool.cid(of: transaction),
                  !move.confirmed.contains(cid),
                  !mempool.contains(cid), admissions[cid] == nil else { continue }
            admissions[cid] = Admission(transaction: transaction, origins: [.returned])
        }
        // Every verdict the pool holds or awaits was for the old tip.
        for item in mempool.items {
            preflight(item.cid, item.transaction, &turn)
        }
        for (cid, admission) in admissions.sorted(by: { $0.key < $1.key }) {
            preflight(cid, admission.transaction, &turn)
        }
    }

    // MARK: - Templates

    private mutating func requestTemplate(_ request: TemplateRequest, replyIDs: [UInt64], _ turn: inout Turn) {
        // A build of this plan on this tip from this pool is already running.
        if let (id, _) = builds.first(where: {
            $0.value.job.tipCID == tipCID && $0.value.job.poolVersion == mempool.version
                && $0.value.job.request == request
        }) {
            builds[id]?.replies += replyIDs
            return
        }
        guard waitingTemplateRequests + replyIDs.count <= config.maxWaitingTemplateRequests else {
            for replyID in replyIDs { turn.replies.append(.templateRefused(replyID: replyID, .busy)) }
            return
        }
        let job = TemplateJob(
            id: nextJobID,
            tipCID: tipCID,
            poolVersion: mempool.version,
            transactions: mempool.transactions(limit: .max),
            request: request
        )
        nextJobID += 1
        builds[job.id] = (job, replyIDs)
        turn.jobs.append(.buildTemplate(job))
    }

    private mutating func built(_ job: TemplateJob, _ build: TemplateBuild?, now: Int64, _ turn: inout Turn) {
        guard let waiting = builds.removeValue(forKey: job.id) else { return }
        // Built on a tip that has moved: rebuild from the current pool.
        guard job.tipCID == tipCID else {
            requestTemplate(job.request, replyIDs: waiting.replies, &turn)
            return
        }
        guard let build else {
            for replyID in waiting.replies { turn.replies.append(.templateRefused(replyID: replyID, .buildFailed)) }
            return
        }
        let issued = templates.issue(WorkTemplate(
            workID: build.workID,
            block: build.block,
            searchTarget: build.searchTarget,
            targets: build.targets,
            tipCID: job.tipCID,
            poolVersion: job.poolVersion,
            expiresAt: now + templates.lifetime
        ), now: now)
        for replyID in waiting.replies {
            turn.replies.append(.templateIssued(replyID: replyID, issued))
        }
    }
}
