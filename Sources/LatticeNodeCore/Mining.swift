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
/// Job contract: an executor MUST skip the job iff `tipEpoch` differs from
/// `Mining.tipEpoch` read when it dequeues the job, and the core drops a
/// verdict iff the same holds when it arrives. The epoch moves on every tip
/// move, so a tip that moves away and back (A, B, A) still makes the job
/// stale. The move already issued the job again, so a backlog never runs
/// more than one tip's worth of preflights.
public struct PreflightJob: Sendable {
    public let cid: String
    public let transaction: Transaction
    public let tipCID: String
    public let tipEpoch: UInt64
    public let poolVersion: UInt64
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

    public init(
        rewardRecipient: String?,
        minimumWork: [[String]: UInt256] = [:],
        parentCarrier: ParentCarrier? = nil,
        childRecipients: [[String]: String] = [:]
    ) {
        self.childRecipients = childRecipients
        self.rewardRecipient = rewardRecipient
        self.minimumWork = minimumWork
        self.parentCarrier = parentCarrier
    }
}

/// Assemble a candidate on the executed tip `tipCID` from `transactions`, in
/// this order, read from the pool at `poolVersion`. With a parent carrier the
/// transactions are the pool's contextual set (unavailable entries included),
/// and the job preflights each against the carrier's `prevState`, as the
/// shell's assembler does today.
///
/// Job contract: as for `PreflightJob`, an executor MUST skip the job iff
/// `tipEpoch` differs from `Mining.tipEpoch` read at dequeue, and the core
/// drops its result iff the same holds; the tip move already issued the
/// build again for the same requests.
public struct TemplateJob: Sendable {
    public let id: UInt64
    public let tipCID: String
    public let tipEpoch: UInt64
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
    /// What the template was built from (its tip and pool), for a miner to
    /// compare with the node's current digest.
    public let digest: String

    public init(workID: String, block: Block, searchTarget: UInt256, targets: [UInt256], digest: String = "") {
        self.workID = workID
        self.block = block
        self.searchTarget = searchTarget
        self.targets = targets
        self.digest = digest
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
    /// Tip moves a local submit or a template request may wait through. One
    /// more and it is answered with a retriable `.contextChanged`, so replies
    /// stay bounded while the tip churns.
    public var maxReissues: Int
    /// Template requests waiting on a build.
    public var maxWaitingTemplateRequests: Int
    public var mempool: MempoolLimits
    public var templateLifetime: Int64
    public var templateCapacity: Int

    public init(
        maxPendingPeerAdmissions: Int = 1_024,
        maxPendingPerPeer: Int = 64,
        maxPendingReturned: Int = MempoolLimits().maxCount,
        maxReissues: Int = 3,
        maxWaitingTemplateRequests: Int = 64,
        mempool: MempoolLimits = MempoolLimits(),
        templateLifetime: Int64 = 30_000,
        templateCapacity: Int = 16
    ) {
        self.maxPendingPeerAdmissions = maxPendingPeerAdmissions
        self.maxPendingPerPeer = maxPendingPerPeer
        self.maxPendingReturned = maxPendingReturned
        self.maxReissues = maxReissues
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
/// needs, and every waiting template build, on the new tip.
public struct Mining: Sendable {
    public private(set) var mempool: Mempool
    public private(set) var templates: TemplateBook
    /// The executed tip transactions and templates build on.
    public private(set) var tipCID: String
    /// Moves on every tip move: what makes a job stale (see `PreflightJob`).
    public private(set) var tipEpoch: UInt64 = 0
    /// The spec of the tip's genesis root; nil while the level executed no
    /// root, when the pool admits nothing.
    public internal(set) var spec: ChainSpec?
    public let config: MiningConfig

    /// Which bound a pending admission counts against. A local or restored
    /// origin joining a peer's or a returned admission takes it out of that
    /// bound.
    private enum Slot: Equatable {
        case local
        case peer(PeerID)
        case returned
    }

    private struct Admission {
        let transaction: Transaction
        var origins: [TransactionOrigin]
        var slot: Slot
        /// Tip moves this admission has waited through.
        var reissues = 0
    }

    /// A template request waiting on a build, and the tip moves it has waited
    /// through.
    private struct Waiting {
        let replyID: UInt64
        var reissues = 0
    }

    /// Transactions awaiting a verdict before admission.
    private var admissions: [String: Admission] = [:]
    /// Transactions with a preflight outstanding on the current tip epoch.
    private var preflighting: Set<String> = []
    /// Pooled transactions in the local journal.
    public private(set) var journaled: Set<String> = []
    private var builds: [UInt64: (job: TemplateJob, replies: [Waiting])] = [:]
    private var nextJobID: UInt64 = 1

    public init(tipCID: String, spec: ChainSpec?, config: MiningConfig = MiningConfig()) {
        self.tipCID = tipCID
        self.spec = spec
        self.config = config
        self.mempool = Mempool(limits: config.mempool)
        self.templates = TemplateBook(lifetime: config.templateLifetime, capacity: config.templateCapacity)
    }

    public var pendingAdmissions: Int { admissions.count }
    /// Every origin recorded on a pending admission.
    public var pendingOrigins: Int { admissions.values.reduce(0) { $0 + $1.origins.count } }
    public private(set) var pendingPeerAdmissions = 0
    public private(set) var pendingReturned = 0
    private var pendingByPeer: [PeerID: Int] = [:]

    public func pendingAdmissions(from peer: PeerID) -> Int { pendingByPeer[peer] ?? 0 }
    /// Whether `cid` awaits its preflight verdict.
    public func isPending(_ cid: String) -> Bool { admissions[cid] != nil }
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
            requestTemplate(request, waiting: [Waiting(replyID: replyID)], &turn)
        case .templateBuilt(let job, let build):
            built(job, build, now: now, &turn)
        case .submitWork(let replyID, let workID, let nonce):
            do {
                let block = try templates.submission(workID: workID, nonce: nonce, now: now)
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
        let cid: String
        do {
            guard let spec else { throw MempoolError.unresolved }
            cid = try mempool.check(transaction, spec: spec)
        } catch {
            // Too large or value-creating: the pool can never hold it, on any
            // tip. Anything else (unresolved content, an encoding failure) is
            // not a verdict and keeps a journal row.
            let refusal = error as? MempoolError ?? .unresolved
            let verdict = error as? MempoolError == .tooLarge || error as? MempoolError == .invalidState
            refuse([origin], cid: try? Mempool.cid(of: transaction), refusal, verdict: verdict, &turn)
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
            admission.origins.append(origin)
            if slot == .local, admission.slot != .local {
                count(admission.slot, -1)
                admission.slot = .local
            }
            admissions[cid] = admission
            return
        }
        // Over its bound, a peer's or a returned arrival is dropped: never
        // answered, never blamed.
        guard hasRoom(for: slot) else { return }
        open(cid, Admission(transaction: transaction, origins: [origin], slot: slot))
        preflight(cid, transaction, &turn)
    }

    private static func slot(of origin: TransactionOrigin) -> Slot {
        switch origin {
        case .local, .restored: .local
        case .peer(let peer): .peer(peer)
        case .returned: .returned
        }
    }

    private func hasRoom(for slot: Slot) -> Bool {
        switch slot {
        case .local:
            true
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

    private mutating func close(_ cid: String) -> Admission? {
        guard let admission = admissions.removeValue(forKey: cid) else { return nil }
        count(admission.slot, -1)
        return admission
    }

    private mutating func preflight(_ cid: String, _ transaction: Transaction, _ turn: inout Turn) {
        guard preflighting.insert(cid).inserted else { return }
        turn.jobs.append(.preflight(PreflightJob(
            cid: cid, transaction: transaction, tipCID: tipCID, tipEpoch: tipEpoch,
            poolVersion: mempool.version
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
        guard job.tipEpoch == tipEpoch else { return }
        preflighting.remove(job.cid)
        if let admission = close(job.cid) {
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
            guard let spec else { throw MempoolError.unresolved }
            let mutation = try mempool.submit(
                admission.transaction,
                spec: spec,
                disposition: disposition,
                addedAt: restoredAt ?? now
            )
            departed(mutation, &turn)
            if let inserted = mutation.inserted { turn.delta.added.append(inserted) }
            guard let item = mempool.item(cid) else { return }
            admitted(item, origins: admission.origins, inserted: mutation.inserted != nil, &turn)
        } catch {
            // Only the verdict makes a refusal final for a journal row; a
            // capacity or conflict refusal leaves the row for the next boot.
            refuse(admission.origins, cid: cid, error as? MempoolError ?? .invalidState,
                   verdict: disposition == .invalid, &turn)
        }
    }

    /// `item` is pooled: journal and answer each local origin, and announce
    /// it for a local or returned one, or for a peer's when this admission
    /// newly pooled it (relayed once, as the actor path relays: a resend of a
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
        verdict: Bool,
        _ turn: inout Turn
    ) {
        for origin in origins {
            switch origin {
            case .local(let replyID):
                turn.replies.append(.transactionRefused(replyID: replyID, error))
            case .restored:
                // The journal row goes with a verdict, never with capacity.
                if verdict, let cid { turn.delta.removed.append(cid) }
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
                case .local(let replyID):
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
        tipEpoch &+= 1
        confirm(move.confirmed, &turn)
        // A local submit that has waited through too many moves is answered
        // with a retriable refusal; the admission goes on for any other origin.
        for cid in admissions.keys.sorted() {
            guard var admission = admissions[cid] else { continue }
            admission.reissues += 1
            admissions[cid] = admission
            guard admission.reissues > config.maxReissues,
                  admission.origins.contains(where: { if case .local = $0 { true } else { false } })
            else { continue }
            for case .local(let replyID) in admission.origins {
                turn.replies.append(.transactionRefused(replyID: replyID, .contextChanged))
            }
            reslot(cid, keeping: admission.origins.filter { if case .local = $0 { false } else { true } })
        }
        // Returned transactions within their bound; a deep reorg spills the
        // rest.
        for transaction in move.returned where hasRoom(for: .returned) {
            guard let cid = try? Mempool.cid(of: transaction),
                  !move.confirmed.contains(cid),
                  !mempool.contains(cid), admissions[cid] == nil else { continue }
            open(cid, Admission(transaction: transaction, origins: [.returned], slot: .returned))
        }
        // Every verdict the pool holds or awaits was for the old tip: those
        // still out will be dropped, and each is issued again here. The
        // move confirmed first, so no verdict refuses what it carries.
        preflighting.removeAll()
        for item in mempool.items {
            preflight(item.cid, item.transaction, &turn)
        }
        for (cid, admission) in admissions.sorted(by: { $0.key < $1.key }) {
            preflight(cid, admission.transaction, &turn)
        }
        if !move.left.isEmpty {
            turn.jobs.append(.returnTransactions(left: move.left, carried: move.confirmed))
        }
        // Every waiting build was for the old tip: issue it again on this
        // one, or refuse a request that has waited through too many moves.
        let stale = builds.sorted { $0.key < $1.key }
        builds.removeAll()
        for (_, entry) in stale {
            var again: [Waiting] = []
            for var waiting in entry.replies {
                waiting.reissues += 1
                if waiting.reissues > config.maxReissues {
                    turn.replies.append(.templateRefused(replyID: waiting.replyID, .contextChanged))
                } else {
                    again.append(waiting)
                }
            }
            if !again.isEmpty { requestTemplate(entry.job.request, waiting: again, &turn) }
        }
    }

    /// Keep `cid`'s admission for `origins` alone, under the bound they
    /// count against; with none left, or no room, it is closed.
    private mutating func reslot(_ cid: String, keeping origins: [TransactionOrigin]) {
        guard var admission = close(cid), let first = origins.first else { return }
        let slot = origins.contains(where: { if case .restored = $0 { true } else { false } })
            ? Slot.local : Self.slot(of: first)
        guard hasRoom(for: slot) else { return }
        admission.origins = origins
        admission.slot = slot
        open(cid, admission)
    }

    // MARK: - Templates

    private mutating func requestTemplate(_ request: TemplateRequest, waiting: [Waiting], _ turn: inout Turn) {
        // A build of this plan on this tip from this pool is already running.
        if let (id, _) = builds.first(where: {
            $0.value.job.tipEpoch == tipEpoch && $0.value.job.poolVersion == mempool.version
                && $0.value.job.request == request
        }) {
            builds[id]?.replies += waiting
            return
        }
        guard waitingTemplateRequests + waiting.count <= config.maxWaitingTemplateRequests else {
            for entry in waiting { turn.replies.append(.templateRefused(replyID: entry.replyID, .busy)) }
            return
        }
        let job = TemplateJob(
            id: nextJobID,
            tipCID: tipCID,
            tipEpoch: tipEpoch,
            poolVersion: mempool.version,
            transactions: request.parentCarrier == nil
                ? mempool.transactions(limit: .max)
                : mempool.contextualTransactions(limit: .max),
            request: request
        )
        nextJobID += 1
        builds[job.id] = (job, waiting)
        turn.jobs.append(.buildTemplate(job))
    }

    private mutating func built(_ job: TemplateJob, _ build: TemplateBuild?, now: Int64, _ turn: inout Turn) {
        // A build for an old tip epoch is dropped: the move issued it again.
        guard job.tipEpoch == tipEpoch, let waiting = builds.removeValue(forKey: job.id) else { return }
        guard let build else {
            for entry in waiting.replies {
                turn.replies.append(.templateRefused(replyID: entry.replyID, .buildFailed))
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
            expiresAt: now + templates.lifetime,
            digest: build.digest
        ), now: now)
        for entry in waiting.replies {
            turn.replies.append(.templateIssued(replyID: entry.replyID, issued))
        }
    }
}
