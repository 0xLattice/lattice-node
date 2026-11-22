import Lattice
import UInt256

/// Where a transaction came from, which decides what admitting it owes.
public enum TransactionOrigin: Sendable, Equatable {
    /// An RPC submit: journaled, announced, and answered under `replyID`.
    case local(replyID: UInt64)
    /// A submit on the opt-in public listener: answered under `replyID` and
    /// announced like a local one, but volatile (never journaled) and, while
    /// it waits for its verdict, held to its own pending bound. Once pooled it
    /// is an ordinary entry: the pool's capacity rules know no origin.
    case submitted(replyID: UInt64)
    /// Peer gossip: volatile, never answered, never blamed.
    case peer(PeerID)
    /// It left the executed chain when the tip moved: re-admitted and
    /// announced.
    case returned
    /// Boot replay of the local journal, with its original arrival time.
    case restored(addedAt: Int64)
}

/// The executed tip moved: the transactions the blocks the act-on chain
/// entered carry (`confirmed`, from their executions, as Bitcoin Core's
/// `removeForBlock`), and the blocks it left, parent first, whose
/// transactions the shell reads from content and returns
/// (`MiningEffect.returnTransactions`). A caller that holds the returned
/// transactions passes them as `returned` instead.
public struct TipMove: Sendable {
    public let tipCID: String
    public let confirmed: Set<String>
    public let returned: [Transaction]
    public let left: [String]

    public init(
        tipCID: String,
        confirmed: Set<String> = [],
        returned: [Transaction] = [],
        left: [String] = []
    ) {
        self.tipCID = tipCID
        self.confirmed = confirmed
        self.returned = returned
        self.left = left
    }
}

/// Classify one transaction against the executed tip `tipCID` (Lattice's
/// `preflightTransaction`). Built from `poolVersion`.
///
/// Job contract, two kinds by `checksPolicies`:
///
/// - An admission (`checksPolicies`): an executor always runs it, on the
///   basis it was issued with, and the core never drops its verdict for a
///   tip move. A verdict on a tip that has since moved is applied as though
///   it had arrived before the move (geth's legacypool: `Add` validates
///   against `pool.currentState`, and the reorg that follows demotes what no
///   longer executes): ready, the transaction is pooled and its submitter
///   answered, with no account shed for balances read on the old tip, and
///   one ordinary recheck is issued on the current tip; otherwise it is
///   refused, once. A verdict counts only for the job its admission waits
///   on (`id`): one for an admission the move confirmed or closed does
///   nothing. A tip move never reissues an admission's job.
/// - A pooled transaction's recheck: the executor MUST skip the job iff
///   `tipCID` is not `MiningState.tipCID` read when it dequeues the job, and
///   the core drops a verdict iff the same holds when it arrives, as geth
///   coalesces resets to the latest head. A verdict on a tip is a fact about
///   that tip, so a tip that moves away and back (A, B, A) takes the job's
///   verdict. Each move issues the recheck again on its tip.
///
/// `awaited` marks an admission an RPC is waiting on (a local or public
/// submit among its origins): the executor runs those ahead of other work.
///
/// `checksPolicies` is false for a pooled transaction: the chain's policies
/// accepted it on admission, and every template, root or child, judges it
/// by them again at the height that would carry it, removing one they
/// refuse (`MiningEvent.policyRefused`). Nor are its signatures checked
/// again: they read nothing but the transaction's own content, which its
/// CID fixes, and its admission checked them. So a tip move costs the pool
/// its state checks, never a policy evaluation or a signature verification
/// per pooled transaction.
public struct PreflightJob: Sendable {
    /// Which job this is: a verdict counts only for the job its admission
    /// waits on.
    public let id: UInt64
    public let cid: String
    public let transaction: Transaction
    public let tipCID: String
    public let poolVersion: UInt64
    public let checksPolicies: Bool
    public let awaited: Bool
}

/// The parent level's provisional carrier a child candidate builds under:
/// its `prevState` is the parent state a child withdrawal is checked
/// against. Two contexts are the same carrier when their CIDs are.
public struct ParentCarrier: Sendable, Equatable {
    public let cid: String
    public let block: Block

    public init(cid: String, block: Block) {
        self.cid = cid
        self.block = block
    }

    public static func == (lhs: ParentCarrier, rhs: ParentCarrier) -> Bool {
        lhs.cid == rhs.cid
    }
}

/// A miner's plan for a template: who the block credits, the minimum work
/// per chain path the miner searches for, and, for a child level's
/// candidate, the parent carrier it builds under.
public struct TemplateRequest: Sendable, Equatable {
    public let rewardRecipient: String?
    public let minimumWork: [[String]: UInt256]
    public let parentCarrier: ParentCarrier?
    /// Each hosted child chain's reward recipient, by path.
    public let childRecipients: [[String]: String]
    /// Hosted descendant chains this template carries no block for.
    public let exclude: Set<[String]>

    public init(
        rewardRecipient: String?,
        minimumWork: [[String]: UInt256] = [:],
        parentCarrier: ParentCarrier? = nil,
        childRecipients: [[String]: String] = [:],
        exclude: Set<[String]> = []
    ) {
        self.childRecipients = childRecipients
        self.exclude = exclude
        self.rewardRecipient = rewardRecipient
        self.minimumWork = minimumWork
        self.parentCarrier = parentCarrier
    }
}

/// Assemble a candidate on the executed tip `tipCID` from `transactions`, in
/// this order, read from the pool at `poolVersion`. With a parent carrier the
/// job preflights each against the carrier's `prevState`, as the shell's
/// assembler does today.
///
/// Job contract: an executor always runs it, and its build is answered and
/// issued whatever the tip is when it lands. A template on a tip that has
/// since moved is still valid work on that tip (a solution is a side block),
/// and the template digest pushed on the move tells the miner to ask again
/// (Bitcoin Core's `getblocktemplate` likewise never refuses because the tip
/// moved).
public struct TemplateJob: Sendable {
    public let id: UInt64
    public let tipCID: String
    public let poolVersion: UInt64
    public let transactions: [Transaction]
    public let request: TemplateRequest
}

/// One block a template commits: its chain, its committed target, its
/// height and who it pays.
public struct TemplateChain: Sendable, Equatable {
    public let chainPath: [String]
    public let target: UInt256
    public let height: UInt64
    public let rewardRecipient: String?

    public init(chainPath: [String], target: UInt256, height: UInt64, rewardRecipient: String?) {
        self.chainPath = chainPath
        self.target = target
        self.height = height
        self.rewardRecipient = rewardRecipient
    }
}

/// What a template job assembled.
public struct TemplateBuild: Sendable {
    public let workID: String
    public let block: Block
    public let searchTarget: UInt256
    public let targets: [UInt256]
    /// What the template was built from (its tip and pool), for a miner to
    /// compare with the node's current digest.
    public let digest: String
    /// Every block a nonce for it commits, the root first.
    public let chains: [TemplateChain]

    public init(
        workID: String, block: Block, searchTarget: UInt256, targets: [UInt256], digest: String = "",
        chains: [TemplateChain] = []
    ) {
        self.workID = workID
        self.block = block
        self.searchTarget = searchTarget
        self.targets = targets
        self.digest = digest
        self.chains = chains
    }
}

public enum MiningEvent: Sendable {
    /// A transaction whose content the shell has resolved.
    case transactionReceived(Transaction, origin: TransactionOrigin)
    /// `balances`: for a ready verdict, each account the transaction debits
    /// and its balance on the job's tip (`Mempool.debits(of:)`).
    case preflighted(PreflightJob, MempoolDisposition, balances: [String: UInt64])
    case tipMoved(TipMove)
    case templateRequested(replyID: UInt64, TemplateRequest)
    /// nil: the job could not build a block on its tip.
    case templateBuilt(TemplateJob, TemplateBuild?)
    /// A template judged these pooled transactions by the chain's policies
    /// at the height that would carry them on `tipCID`, and they refused
    /// them. Applied only while `tipCID` is still the tip.
    case policyRefused(tipCID: String, cids: [String])
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
    /// Read the transactions of the `left` blocks from content and hand each
    /// one the new act-on chain does not carry (`carried`) back as
    /// `.transactionReceived(_, origin: .returned)`. A body no longer held
    /// returns nothing.
    case returnTransactions(left: [String], carried: Set<String>)
}

/// Bounds on transactions waiting for a preflight verdict. Local and
/// restored arrivals are never refused for pending capacity (the shell bounds
/// them: one per RPC in flight, one per journal row), so a peer flood cannot
/// crowd them out; peers and returned transactions have their own bounds.
public struct MiningConfig: Sendable {
    /// Peer arrivals waiting on a verdict, from all peers together.
    public var maxPendingPeerAdmissions: Int
    /// Peer arrivals waiting on a verdict, from any one peer.
    public var maxPendingPerPeer: Int
    /// Transactions a tip move returned, waiting on a verdict. The excess of
    /// a deep reorg is spilled. The default is the pool's own capacity, so an
    /// ordinary reorg returns every transaction, as the actor did.
    public var maxPendingReturned: Int
    /// Public-listener submits waiting on a verdict. Over it a submit is
    /// answered `.full` rather than dropped silently.
    public var maxPendingSubmitted: Int
    /// Template requests waiting on a build.
    public var maxWaitingTemplateRequests: Int
    public var mempool: MempoolLimits
    public var templateCapacity: Int

    public init(
        maxPendingPeerAdmissions: Int = 1_024,
        maxPendingPerPeer: Int = 64,
        maxPendingReturned: Int = MempoolLimits().maxCount,
        maxPendingSubmitted: Int = 256,
        maxWaitingTemplateRequests: Int = 64,
        mempool: MempoolLimits = MempoolLimits(),
        templateCapacity: Int = 512
    ) {
        self.maxPendingPeerAdmissions = maxPendingPeerAdmissions
        self.maxPendingPerPeer = maxPendingPerPeer
        self.maxPendingReturned = maxPendingReturned
        self.maxPendingSubmitted = maxPendingSubmitted
        self.maxWaitingTemplateRequests = maxWaitingTemplateRequests
        self.mempool = mempool
        self.templateCapacity = templateCapacity
    }
}

/// One level's mempool and template book, and the jobs that feed them, behind
/// one synchronous `step`. No IO, no awaits.
///
/// Jobs replace the leases and fences: a preflight or template job names the
/// executed tip it ran on. A recheck's result for a tip that is not the
/// current one is dropped, and the tip move itself reissues every recheck
/// the pool needs on the new tip. An admission's verdict is applied
/// whatever tip it was read on, then rechecked on the current one
/// (`PreflightJob`). A build is answered whatever tip it was read on
/// (`TemplateJob`).
public struct MiningState: Sendable {
    public private(set) var mempool: Mempool
    public private(set) var templates: WorkTemplateBook
    /// The executed tip transactions and templates build on, and what makes
    /// a recheck stale (`PreflightJob`).
    public private(set) var tipCID: String
    /// The spec of the tip's genesis root; nil while the level executed no
    /// root, when the pool admits nothing.
    public internal(set) var spec: ChainSpec?
    public let config: MiningConfig

    /// Which bound a pending admission counts against. A local or restored
    /// origin joining a peer's or a returned admission takes it out of that
    /// bound.
    private enum Slot: Equatable {
        case local
        case submitted
        case peer(PeerID)
        case returned
    }

    private struct Admission {
        let transaction: Transaction
        var origins: [TransactionOrigin]
        var slot: Slot

        /// An RPC waits on its verdict: a local or public submit is among
        /// its origins (a restored row is not waited on).
        var isAwaited: Bool { origins.contains(where: Self.isAnswered) }

        static func isAnswered(_ origin: TransactionOrigin) -> Bool {
            switch origin {
            case .local, .submitted: true
            case .peer, .returned, .restored: false
            }
        }
    }

    /// Transactions awaiting a verdict before admission.
    private var admissions: [String: Admission] = [:]
    /// Each pending admission's outstanding preflight, by job ID: at most
    /// one, outstanding across tip moves until its verdict lands.
    private var admitting: [String: UInt64] = [:]
    /// Pooled transactions with a recheck outstanding on the current tip.
    private var rechecking: Set<String> = []
    /// What the next block can carry: what a template is handed, and what
    /// the status digest names.
    public var nextBlock: [Transaction] { spec.map(mempool.nextBlock) ?? [] }

    /// Pooled transactions in the local journal.
    public private(set) var journaled: Set<String> = []
    /// Each running build's job and the template requests waiting on it.
    private var builds: [UInt64: (job: TemplateJob, replies: [UInt64])] = [:]
    private var nextJobID: UInt64 = 1

    public init(tipCID: String, spec: ChainSpec?, config: MiningConfig = MiningConfig()) {
        self.tipCID = tipCID
        self.spec = spec
        self.config = config
        self.mempool = Mempool(limits: config.mempool)
        self.templates = WorkTemplateBook(capacity: config.templateCapacity)
    }

    public var pendingAdmissions: Int { admissions.count }
    /// Every origin recorded on a pending admission.
    public var pendingOrigins: Int { admissions.values.reduce(0) { $0 + $1.origins.count } }
    public private(set) var pendingPeerAdmissions = 0
    public private(set) var pendingReturned = 0
    public private(set) var pendingSubmitted = 0
    private var pendingByPeer: [PeerID: Int] = [:]

    public func pendingAdmissions(from peer: PeerID) -> Int { pendingByPeer[peer] ?? 0 }
    /// Whether `cid` awaits its preflight verdict.
    public func isPending(_ cid: String) -> Bool { admissions[cid] != nil }
    public var waitingTemplateRequests: Int { builds.values.reduce(0) { $0 + $1.replies.count } }
    public var outstandingPreflights: Int { admitting.count + rechecking.count }

    public mutating func step(_ event: MiningEvent, now: Int64) -> [MiningEffect] {
        var turn = Turn()
        switch event {
        case .transactionReceived(let transaction, let origin):
            receive(transaction, origin: origin, now: now, &turn)
        case .preflighted(let job, let disposition, let balances):
            preflighted(job, disposition, balances: balances, now: now, &turn)
        case .tipMoved(let move):
            tipMoved(move, &turn)
        case .templateRequested(let replyID, let request):
            requestTemplate(request, replyID: replyID, &turn)
        case .templateBuilt(let job, let build):
            built(job, build, &turn)
        case .policyRefused(let refusedOn, let cids):
            if refusedOn == tipCID { departed(mempool.remove(cids), &turn) }
        case .submitWork(let replyID, let workID, let nonce):
            do {
                let block = try templates.submission(workID: workID, nonce: nonce)
                // A grind that clears only child targets leaves the work open,
                // so the miner keeps searching it toward the root's target.
                if ChainTree.rootWork(of: block) != nil {
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
        // A level that has not executed cannot judge yet: a restored row
        // waits for its first tip, which preflights every admission.
        if spec == nil, case .restored = origin, let cid = try? Mempool.cid(of: transaction) {
            if admissions[cid] == nil {
                open(cid, Admission(transaction: transaction, origins: [origin], slot: .local))
            }
            return
        }
        let cid: String
        do {
            guard let spec else { throw MempoolError.unavailable }
            cid = try mempool.check(transaction, spec: spec)
        } catch {
            refuse([origin], cid: try? Mempool.cid(of: transaction), error as? MempoolError ?? .unresolved, &turn)
            return
        }
        if let pooled = mempool.item(cid) {
            // Already admitted on this tip; each tip move preflights it again.
            admitted(pooled, origins: [origin], &turn)
            return
        }
        let slot = Self.slot(of: origin)
        if var admission = admissions[cid] {
            // A peer's origin is never read: recording a resend would only
            // grow the admission.
            if case .peer = origin { return }
            // A local origin takes the admission into its own bound, a public
            // submit a peer's or a returned one into its. One that now has an
            // RPC waiting is judged by a job run ahead of other work: the
            // job out is let go, and its verdict no longer counts.
            let upgrades = Admission.isAnswered(origin) && !admission.isAwaited
            let reslots = slot != admission.slot
                && (slot == .local || (slot == .submitted && admission.slot != .local))
            if reslots {
                guard hasRoom(for: slot) else {
                    if case .submitted(let replyID) = origin {
                        turn.replies.append(.transactionRefused(replyID: replyID, .full))
                    }
                    return
                }
                count(admission.slot, -1)
                admission.slot = slot
                count(slot, 1)
            }
            admission.origins.append(origin)
            admissions[cid] = admission
            if upgrades {
                admitting[cid] = nil
                preflight(cid, admission.transaction, &turn)
            }
            return
        }
        // Over its bound, a peer's or a returned arrival is dropped: never
        // answered, never blamed. A public submit is answered.
        guard hasRoom(for: slot) else {
            if case .submitted(let replyID) = origin {
                turn.replies.append(.transactionRefused(replyID: replyID, .full))
            }
            return
        }
        open(cid, Admission(transaction: transaction, origins: [origin], slot: slot))
        preflight(cid, transaction, &turn)
    }

    private static func slot(of origin: TransactionOrigin) -> Slot {
        switch origin {
        case .local, .restored: .local
        case .submitted: .submitted
        case .peer(let peer): .peer(peer)
        case .returned: .returned
        }
    }

    private func hasRoom(for slot: Slot) -> Bool {
        switch slot {
        case .local:
            true
        case .submitted:
            pendingSubmitted < config.maxPendingSubmitted
        case .peer(let peer):
            pendingPeerAdmissions < config.maxPendingPeerAdmissions
                && pendingAdmissions(from: peer) < config.maxPendingPerPeer
        case .returned:
            pendingReturned < config.maxPendingReturned
        }
    }

    private mutating func count(_ slot: Slot, _ delta: Int) {
        switch slot {
        case .local:
            break
        case .submitted:
            pendingSubmitted += delta
        case .peer(let peer):
            pendingPeerAdmissions += delta
            let remaining = pendingAdmissions(from: peer) + delta
            pendingByPeer[peer] = remaining == 0 ? nil : remaining
        case .returned:
            pendingReturned += delta
        }
    }

    private mutating func open(_ cid: String, _ admission: Admission) {
        admissions[cid] = admission
        count(admission.slot, 1)
    }

    /// Its outstanding job goes with it: one received again later (a
    /// reorg's return) gets a job of its own.
    private mutating func close(_ cid: String) -> Admission? {
        admitting[cid] = nil
        guard let admission = admissions.removeValue(forKey: cid) else { return nil }
        count(admission.slot, -1)
        return admission
    }

    /// Issue `cid`'s admission preflight, unless one is outstanding.
    private mutating func preflight(_ cid: String, _ transaction: Transaction, _ turn: inout Turn) {
        guard admitting[cid] == nil else { return }
        let awaited = admissions[cid]?.isAwaited ?? false
        admitting[cid] = issue(cid, transaction, checksPolicies: true, awaited: awaited, &turn)
    }

    /// Issue a pooled transaction's recheck on this tip: its state checks
    /// alone, without its policies or signatures (`PreflightJob`).
    private mutating func recheck(_ item: MempoolItem, _ turn: inout Turn) {
        guard rechecking.insert(item.cid).inserted else { return }
        issue(item.cid, item.transaction, checksPolicies: false, awaited: false, &turn)
    }

    @discardableResult
    private mutating func issue(
        _ cid: String, _ transaction: Transaction, checksPolicies: Bool, awaited: Bool, _ turn: inout Turn
    ) -> UInt64 {
        let id = nextJobID
        nextJobID += 1
        turn.jobs.append(.preflight(PreflightJob(
            id: id, cid: cid, transaction: transaction, tipCID: tipCID,
            poolVersion: mempool.version, checksPolicies: checksPolicies, awaited: awaited
        )))
        return id
    }

    private mutating func preflighted(
        _ job: PreflightJob,
        _ disposition: MempoolDisposition,
        balances: [String: UInt64],
        now: Int64,
        _ turn: inout Turn
    ) {
        if job.checksPolicies {
            // Only the job its admission waits on counts: one for an
            // admission closed since (confirmed, say) touches nothing.
            guard admitting[job.cid] == job.id, let admission = close(job.cid) else { return }
            // A verdict read on a tip that has since moved is applied as if
            // it arrived before the move, and the pooled transaction is
            // checked again on this tip, as every move checks the pool. Its
            // balances are the old tip's: they shed nothing.
            let stale = job.tipCID != tipCID
            admit(admission, cid: job.cid, disposition, balances: stale ? nil : balances, now: now, &turn)
            if stale, let item = mempool.item(job.cid) { recheck(item, &turn) }
            return
        }
        // A recheck on a tip that is not the current one is dropped: the move
        // reissued it on the new tip.
        guard job.tipCID == tipCID, rechecking.remove(job.cid) != nil else { return }
        // It left the pool and arrived again: its admission's own job, which
        // checks the policies, judges it.
        guard admissions[job.cid] == nil else { return }
        // The pool holds only what executes on the tip: a pooled transaction
        // that no longer does, or that this node can no longer judge (a
        // receipt or deposit a reorg took), leaves, freeing what it claims.
        // One ahead or unjudged is its sender's to send again. One still
        // ready brings its accounts' balances on the new tip: an account
        // that can no longer pay all it backs sheds the lowest fee rate first.
        if disposition == .ready {
            departed(mempool.rebalance(balances), &turn)
        } else {
            departed(mempool.remove([job.cid]), &turn)
        }
    }

    /// `balances` nil: none read on this tip, so no account is shed.
    private mutating func admit(
        _ admission: Admission,
        cid: String,
        _ disposition: MempoolDisposition,
        balances: [String: UInt64]?,
        now: Int64,
        _ turn: inout Turn
    ) {
        let restoredAt = admission.origins.lazy.compactMap { origin -> Int64? in
            if case .restored(let addedAt) = origin { return addedAt }
            return nil
        }.first
        // Only what executes on the tip now is pooled. A nonce ahead, or
        // evidence this node lacks, is a retry for the sender, not a verdict.
        let refusal: MempoolError? = switch disposition {
        case .ready: nil
        case .future: .nonceAhead
        case .unavailable: .unavailable
        case .invalid: .invalidState
        }
        if let refusal {
            refuse(admission.origins, cid: cid, refusal, &turn)
            return
        }
        do {
            guard let spec else { throw MempoolError.unavailable }
            let mutation = try mempool.submit(
                admission.transaction,
                spec: spec,
                addedAt: restoredAt ?? now,
                balances: balances
            )
            departed(mutation, &turn)
            if let inserted = mutation.inserted { turn.delta.added.append(inserted) }
            guard let item = mempool.item(cid) else { return }
            admitted(item, origins: admission.origins, inserted: mutation.inserted != nil, &turn)
        } catch {
            refuse(admission.origins, cid: cid, error as? MempoolError ?? .invalidState, &turn)
        }
    }

    /// `item` is pooled: journal and answer each local origin, and announce
    /// it for a local or returned one, or for a peer's when this admission
    /// newly pooled it (relayed once: a resend of a
    /// pooled transaction is never announced again).
    private mutating func admitted(
        _ item: MempoolItem,
        origins: [TransactionOrigin],
        inserted: Bool = false,
        _ turn: inout Turn
    ) {
        var announce = false
        for origin in origins {
            switch origin {
            case .local(let replyID):
                journal(item, &turn)
                announce = true
                turn.replies.append(.transactionAdmitted(
                    replyID: replyID, cid: item.cid, count: mempool.count, bytes: mempool.byteCount
                ))
            case .submitted(let replyID):
                // Volatile: a public submit is never journaled.
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
                announce = announce || inserted
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
            case .local(let replyID), .submitted(let replyID):
                turn.replies.append(.transactionRefused(replyID: replyID, error))
            case .restored:
                // A journal row lives as long as its pool entry: one not
                // pooled again is its sender's to resend.
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

    /// Transactions the act-on chain now carries leave the pool. One still
    /// awaiting its verdict is done: a local submit is answered as admitted,
    /// a restored row goes.
    private mutating func confirm(_ confirmed: Set<String>, _ turn: inout Turn) {
        departed(mempool.remove(confirmed.sorted()), &turn)
        for cid in confirmed.sorted() {
            guard let admission = close(cid) else { continue }
            for origin in admission.origins {
                switch origin {
                case .local(let replyID), .submitted(let replyID):
                    turn.replies.append(.transactionAdmitted(
                        replyID: replyID, cid: cid, count: mempool.count, bytes: mempool.byteCount
                    ))
                case .restored:
                    turn.delta.removed.append(cid)
                case .peer, .returned:
                    break
                }
            }
        }
    }

    private mutating func tipMoved(_ move: TipMove, _ turn: inout Turn) {
        tipCID = move.tipCID
        // Issued work stays known: a solution on the old tip is a side block
        // (Bitcoin's `submitblock` checks no tip). A waiting build is
        // answered when it lands.
        confirm(move.confirmed, &turn)
        // Returned transactions within their bound; a deep reorg spills the
        // rest.
        for transaction in move.returned where hasRoom(for: .returned) {
            guard let cid = try? Mempool.cid(of: transaction),
                  !move.confirmed.contains(cid),
                  !mempool.contains(cid), admissions[cid] == nil else { continue }
            open(cid, Admission(transaction: transaction, origins: [.returned], slot: .returned))
        }
        // Every verdict the pool holds was for the old tip: rechecks still
        // out on another tip will be dropped, and each is issued again here. The move
        // confirmed first, so no verdict refuses what it carries. An
        // admission's outstanding job is left alone: its verdict is applied
        // whenever it lands (`PreflightJob`). One with no job (returned, or
        // restored before the first tip) is issued one.
        rechecking.removeAll()
        for item in mempool.items {
            recheck(item, &turn)
        }
        for (cid, admission) in admissions.sorted(by: { $0.key < $1.key }) {
            preflight(cid, admission.transaction, &turn)
        }
        if !move.left.isEmpty {
            turn.jobs.append(.returnTransactions(left: move.left, carried: move.confirmed))
        }
    }

    // MARK: - Templates

    private mutating func requestTemplate(_ request: TemplateRequest, replyID: UInt64, _ turn: inout Turn) {
        // A build of this plan on this tip from this pool is already running.
        if let (id, _) = builds.first(where: {
            $0.value.job.tipCID == tipCID && $0.value.job.poolVersion == mempool.version
                && $0.value.job.request == request
        }) {
            builds[id]?.replies.append(replyID)
            return
        }
        guard waitingTemplateRequests < config.maxWaitingTemplateRequests else {
            turn.replies.append(.templateRefused(replyID: replyID, .busy))
            return
        }
        let job = TemplateJob(
            id: nextJobID,
            tipCID: tipCID,
            poolVersion: mempool.version,
            transactions: nextBlock,
            request: request
        )
        nextJobID += 1
        builds[job.id] = (job, [replyID])
        turn.jobs.append(.buildTemplate(job))
    }

    private mutating func built(_ job: TemplateJob, _ build: TemplateBuild?, _ turn: inout Turn) {
        // Answered whatever the tip is now: work on the tip it read is valid
        // work on that tip (`TemplateJob`).
        guard let waiting = builds.removeValue(forKey: job.id) else { return }
        guard let build else {
            for replyID in waiting.replies {
                turn.replies.append(.templateRefused(replyID: replyID, .buildFailed))
            }
            return
        }
        let issued = templates.issue(WorkTemplate(
            workID: build.workID,
            block: build.block,
            searchTarget: build.searchTarget,
            targets: build.targets,
            tipCID: job.tipCID,
            poolVersion: job.poolVersion,
            digest: build.digest,
            chains: build.chains
        ))
        for replyID in waiting.replies {
            turn.replies.append(.templateIssued(replyID: replyID, issued))
        }
    }
}
