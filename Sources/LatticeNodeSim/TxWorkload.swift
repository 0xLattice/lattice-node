import Lattice
import LatticeNodeCore
import Synchronization
import UInt256
import cashew

/// One transaction workload run's shape. `random(seed:)` draws a seed's own.
public struct TxWorkloadConfig: Sendable {
    public var seed: UInt64
    public var users = 4
    /// Blocks mined to the bank before the workload starts.
    public var fundingBlocks = 3
    public var transactions = 60
    /// Mean gap between workload submissions.
    public var submitInterval: Int64 = 300
    public var templateInterval: Int64 = 1_000
    public var replaceProbability = 0.15
    public var overspendProbability = 0.1
    /// Submit a signer's next two nonces in reverse order.
    public var reorderProbability = 0.1
    /// Deliver a transaction a second time, from a peer.
    public var duplicateProbability = 0.1
    /// Replace up to `maxReorgDepth` blocks of the executed chain with one
    /// empty sibling, returning their transactions to the pool.
    public var reorgProbability = 0.1
    public var maxReorgDepth = 1
    /// A burst of junk from many peers: unfunded transfers and far-future
    /// nonces, never answered.
    public var floodProbability = 0.0
    public var floodPeers = 4
    public var floodSize = 8
    public var minJobDelay: Int64 = 1
    public var maxJobDelay: Int64 = 400
    public var mempool = MempoolLimits(maxCount: 24, maxNonReadyPerSigner: 4)
    public var pending = MiningConfig(maxPendingPeerAdmissions: 16, maxPendingPerPeer: 4, maxPendingReturned: 8)
    /// Simulated time after the last submission before the run stops.
    public var settle: Int64 = 30_000

    public init(seed: UInt64) {
        self.seed = seed
    }

    public static func random(seed: UInt64) -> TxWorkloadConfig {
        var rng = SplitMix64(state: seed ^ 0x7A_0000)
        var config = TxWorkloadConfig(seed: seed)
        config.users = rng.draw(2...6)
        config.transactions = rng.draw(20...50)
        config.submitInterval = rng.draw(Int64(50)...600)
        config.templateInterval = rng.draw(Int64(400)...2_000)
        config.replaceProbability = 0.3 * rng.unit()
        config.overspendProbability = 0.2 * rng.unit()
        config.reorderProbability = 0.2 * rng.unit()
        config.duplicateProbability = 0.2 * rng.unit()
        config.reorgProbability = 0.2 * rng.unit()
        config.maxReorgDepth = rng.draw(1...4)
        config.floodProbability = 0.04 * rng.unit()
        config.floodPeers = rng.draw(1...4)
        config.floodSize = rng.draw(1...6)
        config.pending = MiningConfig(
            maxPendingPeerAdmissions: rng.draw(2...24),
            maxPendingPerPeer: rng.draw(1...6),
            maxPendingReturned: rng.draw(1...12)
        )
        config.maxJobDelay = rng.draw(Int64(20)...1_500)
        config.mempool = MempoolLimits(
            maxCount: rng.draw(8...64),
            maxNonReadyPerSigner: rng.draw(1...8)
        )
        return config
    }
}

/// What a workload run observed.
public struct TxWorkloadReport: Sendable {
    public var steps = 0
    public var tipHeight: UInt64 = 0
    /// Workload transactions on the final executed chain.
    public var confirmed = 0
    public var admitted = 0
    public var refused = 0
    public var templates = 0
    public var mined = 0
    public var reorgs = 0
    /// Jobs an executor skipped at dequeue because the tip had moved.
    public var skippedJobs = 0
    public var floods = 0
    /// A fingerprint of the run's event order: equal seeds, equal traces.
    public var trace: UInt64 = 0xCBF2_9CE4_8422_2325
}

/// The mempool and template book under a seeded transaction workload.
///
/// One `Mining` value runs against a simulated executed chain. Its jobs run
/// the real Lattice work (the state reads of a preflight, `BlockBuilder` for a
/// template) one at a time, and post their results after a seeded delay, so
/// the tip often moves under a job and its result goes stale. A miner grinds
/// every issued template; a grind on the current tip extends the chain, and
/// a seeded reorg replaces the tip with an empty sibling. Every step's
/// effects are executed, then the invariants are checked.
public struct TxWorkload {
    enum Item {
        case event(MiningEvent)
        case submit
        case resubmit(Transaction)
        case requestTemplate
        case reorg
        case flood
        /// A job the executor dequeues.
        case runPreflight(PreflightJob)
        case runTemplate(TemplateJob)
    }

    struct Scheduled {
        let time: Int64
        let sequence: UInt64
        let item: Item
    }

    struct ChainBlock {
        let sim: SimBlock
        let transactions: [String: Transaction]
    }

    public let config: TxWorkloadConfig
    public private(set) var mining: Mining
    public private(set) var report = TxWorkloadReport()
    var rng: SplitMix64
    var now: Int64
    let cas: SimCAS
    let spec: ChainSpec
    let bank: (privateKey: String, publicKey: String)
    let users: [(privateKey: String, publicKey: String)]
    let genesis: String
    var blocks: [String: ChainBlock]
    /// The transactions each template job selected, by the block's
    /// transactions root (a grind changes only the nonce).
    var selected: [String: [Transaction]] = [:]
    var tip: String
    /// Every transaction on the executed chain.
    var onChain: Set<String> = []
    var queue: [Scheduled] = []
    var sequence: UInt64 = 0
    var nextReplyID: UInt64 = 1
    /// Replies owed: local submits, template requests and work submissions.
    var owed: Set<UInt64> = []
    /// The journal the pool deltas built.
    var journal: Set<String> = []
    var submitted = 0
    /// Transactions a later submission may replace or redeliver.
    var recent: [Transaction] = []
    /// A reordered nonce held back for the next submission.
    var heldBack: Transaction?
    var lastSubmission: Int64 = 0
    /// (tip, transaction) of every preflight run whose verdict is not yet
    /// delivered: at most one per transaction, and only on the current tip.
    var runningPreflights: Set<String> = []
    /// Preflights run on the current tip, and the bound on them: every
    /// pooled or pending transaction once, plus each new arrival.
    var preflightsOnTip = 0
    var arrivalsOnTip = 0
    var epochAtMove: UInt64 = .max
    var poolAtMove = 0
    var floodCount: Int64 = 0
    /// Local submits awaiting a reply, and refused ones awaiting a retry.
    var submissions: [UInt64: Transaction] = [:]
    var retrying: [String: Transaction] = [:]

    public static func make(_ config: TxWorkloadConfig) async throws -> TxWorkload {
        let cas = SimCAS()
        try await LatticeState.emptyHeader.storeRecursively(storer: cas as any VolumeStorer)
        let genesisBlock = World.mined(try await BlockBuilder.buildGenesis(
            spec: World.spec,
            timestamp: World.genesisTime,
            target: World.genesisTarget,
            fetcher: cas
        ))
        let genesis = try await World.record(
            genesisBlock, releaseAt: World.genesisTime, anchor: nil, in: cas
        )
        return TxWorkload(config: config, cas: cas, genesis: genesis)
    }

    init(config: TxWorkloadConfig, cas: SimCAS, genesis: SimBlock) {
        self.config = config
        self.cas = cas
        self.spec = World.spec
        self.rng = SplitMix64(state: config.seed)
        self.now = World.genesisTime + World.blockInterval
        // The last key is the flooder's, never funded.
        precondition(config.users >= 2 && config.users < SimTransactions.keys.count - 1)
        self.bank = SimTransactions.keys[0]
        self.users = Array(SimTransactions.keys[1...config.users])
        self.genesis = genesis.cid
        self.blocks = [genesis.cid: ChainBlock(sim: genesis, transactions: [:])]
        self.tip = genesis.cid
        self.mining = Mining(
            tipCID: genesis.cid,
            spec: World.spec,
            config: MiningConfig(
                maxPendingPeerAdmissions: config.pending.maxPendingPeerAdmissions,
                maxPendingPerPeer: config.pending.maxPendingPerPeer,
                maxPendingReturned: config.pending.maxPendingReturned,
                mempool: config.mempool
            )
        )
        // The bank's funding blocks, then the workload.
        for index in 0..<config.fundingBlocks {
            schedule(at: now + Int64(index) * config.templateInterval, .requestTemplate)
        }
        lastSubmission = now + Int64(config.fundingBlocks + 1) * config.templateInterval
        schedule(at: lastSubmission, .submit)
    }

    var end: Int64 { lastSubmission + config.settle }

    mutating func schedule(at time: Int64, _ item: Item) {
        sequence += 1
        let scheduled = Scheduled(time: time, sequence: sequence, item: item)
        let index = queue.firstIndex {
            ($0.time, $0.sequence) > (scheduled.time, scheduled.sequence)
        } ?? queue.endIndex
        queue.insert(scheduled, at: index)
    }

    /// Run to the end, checking the invariants after every step and the
    /// settled state after the last.
    public mutating func run() async throws -> TxWorkloadReport {
        while !queue.isEmpty, queue[0].time <= end {
            let next = queue.removeFirst()
            now = max(now, next.time)
            switch next.item {
            case .event(let event):
                try await step(event)
            case .resubmit(let transaction):
                let replyID = reply()
                submissions[replyID] = transaction
                if let cid = try? Mempool.cid(of: transaction) { retrying[cid] = nil }
                try await step(.transactionReceived(transaction, origin: .local(replyID: replyID)))
            case .submit:
                try await submit()
            case .requestTemplate:
                let replyID = reply()
                try await step(.templateRequested(replyID: replyID, TemplateRequest(
                    rewardRecipient: recipient()
                )))
                if now < end - config.templateInterval {
                    schedule(at: now + config.templateInterval, .requestTemplate)
                }
            case .reorg:
                try await reorg()
            case .flood:
                try await flood()
            case .runPreflight(let job):
                try await run(job)
            case .runTemplate(let job):
                try await run(job)
            }
        }
        try await settle()
        report.tipHeight = blocks[tip]?.sim.height ?? 0
        report.confirmed = onChain.count
        return report
    }

    // MARK: - Workload

    mutating func reply() -> UInt64 {
        defer { nextReplyID += 1 }
        owed.insert(nextReplyID)
        return nextReplyID
    }

    /// Mining rewards rotate: the bank funds the workload, then every user
    /// earns its own coinbase.
    mutating func recipient() -> String {
        let keys = [bank] + users
        let key = report.mined < config.fundingBlocks ? bank : keys[rng.draw(0...keys.count - 1)]
        return CryptoUtils.createAddress(from: key.publicKey)
    }

    mutating func submit() async throws {
        let transaction: Transaction
        if let held = heldBack {
            transaction = held
            heldBack = nil
        } else if !recent.isEmpty, rng.chance(config.replaceProbability) {
            // Same signer and nonce, a new bid: higher or lower.
            let original = recent[rng.draw(0...recent.count - 1)]
            transaction = try rebid(original)
        } else {
            transaction = try await fresh()
        }
        recent = Array((recent + [transaction]).suffix(16))
        let replyID = reply()
        submissions[replyID] = transaction
        try await step(.transactionReceived(transaction, origin: .local(replyID: replyID)))
        if rng.chance(config.duplicateProbability) {
            let again = recent[rng.draw(0...recent.count - 1)]
            try await step(.transactionReceived(again, origin: .peer(PeerID(key: "peer", session: 1))))
        }
        if rng.chance(config.reorgProbability) {
            schedule(at: now + rng.draw(Int64(1)...config.templateInterval), .reorg)
        }
        if rng.chance(config.floodProbability) {
            schedule(at: now + rng.draw(Int64(1)...config.submitInterval), .flood)
        }
        submitted += 1
        if submitted < config.transactions || heldBack != nil {
            lastSubmission = now + rng.draw(Int64(1)...2 * config.submitInterval)
            schedule(at: lastSubmission, .submit)
        }
    }

    /// A transfer from the bank or a user to another user, at the sender's
    /// next nonce past its pooled transactions.
    mutating func fresh() async throws -> Transaction {
        let senders = [bank] + users
        let sender = senders[rng.draw(0...senders.count - 1)]
        let others = users.filter { $0.publicKey != sender.publicKey }
        let receiver = others[rng.draw(0...others.count - 1)]
        let senderAddress = CryptoUtils.createAddress(from: sender.publicKey)
        var nonce = try await nextNonce(senderAddress)
        // Past every nonce the client already has out: pooled, awaiting a
        // reply, or awaiting a retry.
        let outstanding = mining.mempool.items.map(\.transaction)
            + Array(submissions.values) + Array(retrying.values)
        nonce += UInt64(Set(outstanding.filter {
            $0.body.node?.signers.contains(senderAddress) == true
        }.compactMap { try? Mempool.cid(of: $0) }).count)
        let overspend = rng.chance(config.overspendProbability)
        let amount = overspend ? Int64(1_000_000) : (sender.publicKey == bank.publicKey ? 20 : Int64(rng.draw(1...3)))
        let fee = Int64(rng.draw(0...3))
        let make = { (nonce: UInt64) throws -> Transaction in
            try SimTransactions.transfer(
                from: sender, to: CryptoUtils.createAddress(from: receiver.publicKey),
                amount: amount, fee: fee, nonce: nonce
            )
        }
        if !overspend, rng.chance(config.reorderProbability) {
            heldBack = try make(nonce)
            return try make(nonce + 1)
        }
        return try make(nonce)
    }

    mutating func rebid(_ original: Transaction) throws -> Transaction {
        guard let body = original.body.node,
              let sender = ([bank] + users).first(where: {
                  body.signers == [CryptoUtils.createAddress(from: $0.publicKey)]
              }),
              let credit = body.accountActions.first(where: { $0.delta > 0 }) else {
            return original
        }
        let debit = body.accountActions.first { $0.delta < 0 }?.delta ?? 0
        let fee = -debit - credit.delta + Int64(rng.draw(-1...3))
        return try SimTransactions.transfer(
            from: sender, to: credit.owner, amount: credit.delta, fee: max(0, fee), nonce: body.nonce
        )
    }

    func nextNonce(_ address: String) async throws -> UInt64 {
        guard let state = try await blocks[tip]?.sim.block.postState.resolve(fetcher: cas).node else {
            throw SimulationError.malformedWorld("tip state unavailable")
        }
        return try await state.accountState.nextExpectedNonce(for: address, fetcher: cas)
    }

    // MARK: - Chain

    /// Replace up to a seeded depth of the executed chain (never genesis's
    /// child) with one empty sibling of the deepest block replaced.
    mutating func reorg() async throws {
        let depth = rng.draw(1...config.maxReorgDepth)
        var disconnected: [ChainBlock] = []
        var forkPoint = tip
        while disconnected.count < depth, let block = blocks[forkPoint],
              let parent = block.sim.parent, parent != genesis {
            disconnected.append(block)
            forkPoint = parent
        }
        guard !disconnected.isEmpty, let parent = blocks[forkPoint] else { return }
        let built = try await BlockBuilder.buildBlock(
            previous: parent.sim.block,
            timestamp: max(parent.sim.block.timestamp + 1, now),
            difficultyAnchor: parent.sim.anchor,
            fetcher: cas
        )
        let sibling = World.mined(built.replacing(parent: built.parent?.removingNode(), nonce: built.nonce))
        let recorded = try await World.record(sibling, releaseAt: now, anchor: anchor(below: parent.sim, sibling), in: cas)
        blocks[recorded.cid] = ChainBlock(sim: recorded, transactions: [:])
        tip = recorded.cid
        var returned: [Transaction] = []
        for block in disconnected.reversed() {
            onChain.subtract(block.transactions.keys)
            returned += block.transactions.keys.sorted().compactMap { block.transactions[$0] }
        }
        report.reorgs += 1
        try await step(.tipMoved(TipMove(tipCID: recorded.cid, confirmed: [], returned: returned)))
    }

    /// Junk from several peers at once: unsigned, unfunded transfers from the
    /// flooder's key, at its first nonce (invalid) or a far one (future).
    mutating func flood() async throws {
        report.floods += 1
        let flooder = SimTransactions.keys[SimTransactions.keys.count - 1]
        let sender = CryptoUtils.createAddress(from: flooder.publicKey)
        for peer in 0..<config.floodPeers {
            for _ in 0..<config.floodSize {
                floodCount += 1
                let body = TransactionBody(
                    accountActions: [AccountAction(owner: sender, delta: -floodCount)],
                    actions: [], depositActions: [], receiptActions: [],
                    withdrawalActions: [],
                    signers: [sender],
                    nonce: rng.chance(0.5) ? 0 : UInt64(rng.draw(1...8)),
                    chainPath: [DEFAULT_ROOT_DIRECTORY]
                )
                let junk = Transaction(signatures: [flooder.publicKey: "00"], body: try HeaderImpl(node: body))
                try await step(.transactionReceived(junk, origin: .peer(PeerID(key: "flood\(peer)", session: 1))))
            }
        }
    }

    func anchor(below parent: SimBlock, _ block: Block) -> DifficultyAnchor {
        parent.anchor ?? DifficultyAnchor(blockHeight: 1, timestamp: block.timestamp, target: block.target)
    }

    /// A grind on the current tip extends the executed chain; one on an old
    /// tip is a side block this chain does not execute.
    mutating func mined(_ block: Block) async throws {
        report.mined += 1
        guard block.parent?.rawCID == tip, let parent = blocks[tip] else { return }
        let recorded = try await World.record(block, releaseAt: now, anchor: anchor(below: parent.sim, block), in: cas)
        var transactions: [String: Transaction] = [:]
        for transaction in selected[block.transactions.rawCID] ?? [] {
            transactions[try Mempool.cid(of: transaction)] = transaction
        }
        blocks[recorded.cid] = ChainBlock(sim: recorded, transactions: transactions)
        tip = recorded.cid
        onChain.formUnion(transactions.keys)
        try await step(.tipMoved(TipMove(tipCID: recorded.cid, confirmed: Set(transactions.keys), returned: [])))
    }

    // MARK: - Step and effects

    mutating func step(_ event: MiningEvent) async throws {
        report.steps += 1
        mix(Self.describe(event))
        switch event {
        case .preflighted(let job, _):
            runningPreflights.remove("\(job.tipEpoch)/" + job.cid)
        case .transactionReceived:
            arrivalsOnTip += 1
        default:
            break
        }
        let effects = mining.step(event, now: now)
        try checkOrder(effects)
        for effect in effects {
            try await execute(effect)
        }
        try checkInvariants()
    }

    mutating func execute(_ effect: MiningEffect) async throws {
        switch effect {
        case .poolChanged(let delta):
            journal.subtract(delta.removed)
            journal.formUnion(delta.journaled.map(\.cid))
        case .transactionAdmitted(let replyID, _, _, _):
            try answer(replyID)
            submissions[replyID] = nil
            report.admitted += 1
        case .transactionRefused(let replyID, let error):
            try answer(replyID)
            // A client retries a refusal the tip's churn caused.
            if error == .contextChanged, let transaction = submissions[replyID],
               let cid = try? Mempool.cid(of: transaction) {
                retrying[cid] = transaction
                schedule(at: now + delay(), .resubmit(transaction))
            }
            submissions[replyID] = nil
            report.refused += 1
        case .announceTransaction:
            break
        case .templateIssued(let replyID, let template):
            try answer(replyID)
            report.templates += 1
            // DST 5: work comes only from the executed tip.
            guard template.tipCID == mining.tipCID, template.block.parent?.rawCID == mining.tipCID else {
                throw fail("template issued off the executed tip")
            }
            let nonce = Self.grind(template.block, below: template.searchTarget)
            schedule(at: now + delay(), .event(.submitWork(
                replyID: reply(), workID: template.workID, nonce: nonce
            )))
        case .templateRefused(let replyID, _), .workRefused(let replyID, _):
            try answer(replyID)
        case .mined(let replyID, let block):
            try answer(replyID)
            try await mined(block)
        case .preflight(let job):
            schedule(at: now + delay(), .runPreflight(job))
        case .returnTransactions:
            // The workload passes its tip moves' transactions directly.
            break
        case .buildTemplate(let job):
            schedule(at: now + delay(), .runTemplate(job))
        }
    }

    /// The executor's side of the job contract: a job is skipped iff its tip
    /// epoch is not `Mining.tipEpoch` when it is dequeued.
    mutating func run(_ job: PreflightJob) async throws {
        guard job.tipEpoch == mining.tipEpoch else {
            report.skippedJobs += 1
            return
        }
        guard runningPreflights.insert("\(job.tipEpoch)/" + job.cid).inserted else {
            throw fail("preflight of \(job.cid) ran twice at once in tip epoch \(job.tipEpoch)")
        }
        if epochAtMove != job.tipEpoch {
            epochAtMove = job.tipEpoch
            preflightsOnTip = 0
            arrivalsOnTip = 0
            poolAtMove = mining.mempool.count + mining.pendingAdmissions
        }
        preflightsOnTip += 1
        guard preflightsOnTip <= poolAtMove + arrivalsOnTip else {
            throw fail("\(preflightsOnTip) preflights in tip epoch \(job.tipEpoch): more than one tip's worth")
        }
        let verdict = try await classify(job)
        schedule(at: now + delay(), .event(.preflighted(job, verdict)))
    }

    mutating func run(_ job: TemplateJob) async throws {
        guard job.tipEpoch == mining.tipEpoch else {
            report.skippedJobs += 1
            return
        }
        let build = try await assemble(job)
        schedule(at: now + delay(), .event(.templateBuilt(job, build)))
    }

    mutating func delay() -> Int64 {
        rng.draw(config.minJobDelay...config.maxJobDelay)
    }

    mutating func answer(_ replyID: UInt64) throws {
        guard owed.remove(replyID) != nil else { throw fail("reply \(replyID) answered twice or never asked") }
    }

    static func grind(_ block: Block, below target: UInt256) -> UInt64 {
        var nonce: UInt64 = 0
        while block.replacing(parent: block.parent, nonce: nonce).proofOfWorkHash() > target { nonce += 1 }
        return nonce
    }

    // MARK: - Jobs (the real Lattice work)

    /// The preflight job: the state reads Lattice's `preflightTransaction`
    /// makes against the tip's post-state. Signature and policy checks are
    /// package-internal to Lattice and are not run: every workload
    /// transaction is correctly signed.
    func classify(_ job: PreflightJob) async throws -> MempoolDisposition {
        guard let body = job.transaction.body.node, body.minerSurplus() != nil,
              body.chainPath == [DEFAULT_ROOT_DIRECTORY] else { return .invalid }
        guard let tipBlock = blocks[job.tipCID]?.sim.block,
              let state = try await tipBlock.postState.resolve(fetcher: cas).node else { return .unavailable }
        var future = false
        for signer in Set(body.signers).sorted() {
            let expected = try await state.accountState.nextExpectedNonce(for: signer, fetcher: cas)
            if body.nonce < expected { return .invalid }
            if body.nonce > expected { future = true }
        }
        if future { return .future }
        do {
            _ = try await state.proveAndUpdateState(
                allAccountActions: body.accountActions,
                allActions: body.actions,
                allDepositActions: body.depositActions,
                allReceiptActions: body.receiptActions,
                allWithdrawalActions: body.withdrawalActions,
                transactionBodies: [body],
                fetcher: cas
            )
            return .ready
        } catch {
            return .invalid
        }
    }

    /// The template job: build on the job's tip, keeping every chunk of the
    /// pool's order the state transform accepts and bisecting the rest (the
    /// shell assembler's fit, without child candidates or minimum work).
    mutating func assemble(_ job: TemplateJob) async throws -> TemplateBuild? {
        guard let tipBlock = blocks[job.tipCID] else { return nil }
        let previous = tipBlock.sim.block
        let timestamp = max(previous.timestamp + 1, now)
        func build(_ transactions: [Transaction]) async throws -> Block {
            let built = try await BlockBuilder.buildBlock(
                previous: previous,
                transactions: transactions,
                timestamp: timestamp,
                difficultyAnchor: tipBlock.sim.anchor,
                rewardRecipient: job.request.rewardRecipient,
                fetcher: cas
            )
            return built.replacing(parent: built.parent?.removingNode(), nonce: 0)
        }
        let limit = Int(spec.maxNumberOfTransactionsPerBlock)
        var selected: [Transaction] = []
        guard var candidate = try? await build([]) else { return nil }
        var chunks = job.transactions.isEmpty ? [] : [job.transactions[...]]
        while selected.count < limit, let chunk = chunks.popLast() {
            let remaining = limit - selected.count
            if chunk.count > remaining {
                let split = chunk.index(chunk.startIndex, offsetBy: remaining)
                chunks.append(chunk[split...])
                chunks.append(chunk[..<split])
                continue
            }
            if let block = try? await build(selected + chunk) {
                candidate = block
                selected.append(contentsOf: chunk)
            } else if chunk.count > 1 {
                let midpoint = chunk.index(chunk.startIndex, offsetBy: chunk.count / 2)
                chunks.append(chunk[midpoint...])
                chunks.append(chunk[..<midpoint])
            }
        }
        self.selected[candidate.transactions.rawCID] = selected
        return TemplateBuild(
            workID: try BlockHeader(node: candidate).rawCID,
            block: candidate,
            searchTarget: candidate.target,
            targets: [candidate.target]
        )
    }

    // MARK: - Invariants

    func fail(_ detail: String) -> SimulationError {
        .invariant("tx workload seed \(config.seed) at \(now): \(detail)")
    }

    /// Durability precedes visibility: a step's pool delta comes first.
    func checkOrder(_ effects: [MiningEffect]) throws {
        for (index, effect) in effects.enumerated() {
            if case .poolChanged = effect, index != 0 { throw fail("pool delta after another effect") }
        }
    }

    func checkInvariants() throws {
        let pooled = Set(mining.mempool.items.map(\.cid))
        let limits = mining.mempool.limits
        guard mining.mempool.count <= limits.maxCount, mining.mempool.byteCount <= limits.maxBytes else {
            throw fail("pool over its limits")
        }
        let bounds = mining.config
        guard mining.pendingPeerAdmissions <= bounds.maxPendingPeerAdmissions,
              mining.pendingReturned <= bounds.maxPendingReturned,
              (0..<config.floodPeers).allSatisfy({
                  mining.pendingAdmissions(from: PeerID(key: "flood\($0)", session: 1)) <= bounds.maxPendingPerPeer
              }),
              mining.waitingTemplateRequests <= bounds.maxWaitingTemplateRequests else {
            throw fail("waiting work over its bounds")
        }
        if let stale = pooled.intersection(onChain).first {
            throw fail("pool holds \(stale), already on the executed chain")
        }
        guard mining.tipCID == tip else { throw fail("mining builds on a tip that is not the executed tip") }
        guard journal == mining.journaled, journal.isSubset(of: pooled) else {
            throw fail("journal \(journal.count) diverged from the pool's local set \(mining.journaled.count)")
        }
        var slots: Set<String> = []
        for item in mining.mempool.items {
            guard let body = item.transaction.body.node else { throw fail("pooled content unresolved") }
            for signer in body.signers where !slots.insert("\(signer)/\(body.nonce)").inserted {
                throw fail("two pooled transactions hold \(signer)'s nonce \(body.nonce)")
            }
        }
    }

    /// The quiet point: the workload stops, every outstanding job and grind
    /// is delivered, and templates keep coming while the pool holds a ready
    /// transaction. Then every reply was given and no ready transaction is
    /// left unmined.
    mutating func settle() async throws {
        queue.removeAll {
            switch $0.item {
            case .event, .runPreflight, .runTemplate, .resubmit: false
            case .submit, .requestTemplate, .reorg, .flood: true
            }
        }
        for _ in 0..<Self.settleRounds {
            while !queue.isEmpty {
                let next = queue.removeFirst()
                now = max(now, next.time)
                switch next.item {
                case .event(let event): try await step(event)
                case .runPreflight(let job): try await run(job)
                case .runTemplate(let job): try await run(job)
                case .resubmit(let transaction):
                    let replyID = reply()
                    submissions[replyID] = transaction
                    if let cid = try? Mempool.cid(of: transaction) { retrying[cid] = nil }
                    try await step(.transactionReceived(transaction, origin: .local(replyID: replyID)))
                case .submit, .requestTemplate, .reorg, .flood: break
                }
            }
            guard mining.mempool.items.contains(where: { $0.disposition == .ready }) else { break }
            try await step(.templateRequested(replyID: reply(), TemplateRequest(rewardRecipient: recipient())))
        }
        guard owed.isEmpty else { throw fail("\(owed.count) replies never given") }
        if let ready = mining.mempool.items.first(where: { $0.disposition == .ready }) {
            throw fail("ready transaction \(ready.cid) never mined")
        }
    }

    static let settleRounds = 16

    // MARK: - Trace

    mutating func mix(_ text: String) {
        for byte in text.utf8 {
            report.trace = (report.trace ^ UInt64(byte)) &* 0x100_0000_01B3
        }
    }

    static func describe(_ event: MiningEvent) -> String {
        switch event {
        case .transactionReceived(let transaction, let origin):
            "tx \((try? Mempool.cid(of: transaction)) ?? "?") \(origin)"
        case .preflighted(let job, let verdict):
            "verdict \(job.cid) \(job.tipCID) \(verdict)"
        case .tipMoved(let move):
            "tip \(move.tipCID)"
        case .templateRequested(let replyID, _):
            "template? \(replyID)"
        case .templateBuilt(let job, let build):
            "built \(job.id) \(build?.workID ?? "-")"
        case .submitWork(let replyID, let workID, let nonce):
            "work \(replyID) \(workID) \(nonce)"
        }
    }
}

/// Signed workload transactions.
public enum SimTransactions {
    /// Ed25519 signing may be hedged (randomized, as CryptoKit's is), and a
    /// transaction's CID covers its signatures: one signature per body and
    /// key per process keeps a seed's CIDs, and so its run, reproducible.
    private static let signatures = Mutex<[String: String]>([:])

    static func signature(
        _ header: HeaderImpl<TransactionBody>,
        _ key: (privateKey: String, publicKey: String)
    ) throws -> String {
        let slot = header.rawCID + "/" + key.publicKey
        if let cached = signatures.withLock({ $0[slot] }) { return cached }
        guard let signature = TransactionSigning.sign(bodyHeader: header, privateKeyHex: key.privateKey) else {
            throw SimulationError.malformedWorld("signing failed")
        }
        return signatures.withLock { cache in
            if let cached = cache[slot] { return cached }
            cache[slot] = signature
            return signature
        }
    }

    /// Fixed Ed25519 keys (private seed, Multikey public key), so a seed
    /// replays the same transaction CIDs in every process.
    public static let keys: [(privateKey: String, publicKey: String)] = [
        ("5371bd9615661b6cbb47f176d3fac329826c48cc70dcfa0ef4a4ab36e917fb23", "ed0144a396a93762a6ee31a295d45a872e8859267b7e6df533e33e432ed21ab09e93"),
        ("d3d3975a241f38233cb72a47ebf87de4d984df7c7e86ce08da66db3a3e5272b9", "ed013a826cf7f1a11dc469009194375b25251e1782cf6cf86be30d074e0b90593bae"),
        ("63f4e8c9ba57595b824b081881a772b6187e517cd7cdf554273f66b90ce92705", "ed015a52cdc9c8633aba8fd3df4610e0a9aed08bc17fbb24f127fc550842d9f9e456"),
        ("e390175be9a4fc6114391cc9b1b6b56b2d2f1538bfb463f6c3e22cbbe1aeb4d1", "ed01c3bf371e348605455acc12163ebd1b2a0386d6b729204509102346264659bbb9"),
        ("f413fac852db60d6b1c954158e3c4c0744434ef09dcc8116699264130b33d1e9", "ed017ef60c5e2ba64f76ea9645f08e7d1918fe588adb4e98909763309a80d1b47508"),
        ("bcaecbc6b0a63ece1de724c0e5dd48177787d3c2c52b7a1ee97adb280d07afaf", "ed018f93bf5dbe1239a2d2ef03f2c2984f0c7573634bb8e6cb838acb1710571ff3ec"),
        ("b2c679aa4905fda336c7d2d31f4fd772f8a30787249bbc21b7dd6dc44affa390", "ed01733ab9b4eeeab43945446e9f739e19390a893e2695546a9843ad8080c942bb55"),
        ("49b7deb6d93adb4836710685f3706ecb91bc861657e01d693ecfc0b30252d363", "ed01a757919748b80418ab95db2557ec4a1f540feabe73dabe19bb3edb6b541ef477"),
    ]

    /// `from` pays `amount` to `to` and `fee` to the block's reward
    /// recipient: the fee is the debit's excess over the credit.
    public static func transfer(
        from key: (privateKey: String, publicKey: String),
        to recipient: String,
        amount: Int64,
        fee: Int64,
        nonce: UInt64
    ) throws -> Transaction {
        let sender = CryptoUtils.createAddress(from: key.publicKey)
        return try signed(keys: [key], accountActions: [
            AccountAction(owner: sender, delta: -(amount + fee)),
            AccountAction(owner: recipient, delta: amount),
        ], nonce: nonce)
    }

    /// A root-chain transaction signed by every key in `keys`, all of them
    /// its signers.
    public static func signed(
        keys: [(privateKey: String, publicKey: String)],
        accountActions: [AccountAction],
        nonce: UInt64,
        chainPath: [String] = [DEFAULT_ROOT_DIRECTORY]
    ) throws -> Transaction {
        let body = TransactionBody(
            accountActions: accountActions,
            actions: [],
            depositActions: [],
                        receiptActions: [],
            withdrawalActions: [],
            signers: keys.map { CryptoUtils.createAddress(from: $0.publicKey) },
            nonce: nonce,
            chainPath: chainPath
        )
        let header = try HeaderImpl(node: body)
        var signatures: [String: String] = [:]
        for key in keys {
            signatures[key.publicKey] = try signature(header, key)
        }
        return Transaction(signatures: signatures, body: header)
    }
}
