import Lattice
import UInt256
import cashew

/// What the shell hands the core. Time is not an event: every `step` takes
/// the shell's `now` (milliseconds since the epoch).
public enum ChainEvent: Sendable {
    case peerReady(PeerID)
    case peerGone(PeerID)
    case received(PeerID, SyncMessage)
    /// The answer to `ChainEffect.fetchByCID` for a child index: nil ONLY when the
    /// peer definitively does not hold it. A transport failure is no event
    /// (the request's deadline decides).
    case childIndexFetched(PeerID, cid: String, FlatDictionary<BlockHeader>?)
    /// The shell finished sending the answer a `serveHeaders` effect named.
    case headersServed(PeerID, token: UInt64)
    /// The content layer holds the body Volume of this block locally.
    case bodyFetched(cid: String)
    /// A connect job's verdict, with the CIDs of the transactions the block
    /// carries (the job read them from the body it executed): what the act-on
    /// chain confirms when it enters the block.
    case connected(ConnectVerdict, transactions: [String] = [])
    /// The answer to `readTransactions`: each block's transaction CIDs (a
    /// body no longer held reads as none).
    case transactionsRead([String: [String]])
    /// A child level: its parent level now holds the facts these blocks'
    /// connects lacked.
    case parentFactsPresent([String])
    case tick
    /// A child level: the evidence index's proofs for a block
    /// (`ChainEffect.lookupProofs`).
    case proofsFound(childCID: String, [ChildBlockProof])
    /// A child level: a `verifyProof` job the shell could not run (its block
    /// is not held): its slot frees, blaming no one.
    case proofDropped(ChildProofJob)
    /// A child level: a `verifyProof` job finished.
    case proofVerified(ChildProofJob, Result<VerifiedChildEvidence, ChildProofVerificationFailure>)
    /// A child level: the evidence index's proofs changed for these blocks.
    case evidenceChanged(childCIDs: [String])
    /// The level's mempool and miner work: transactions, preflight and
    /// template results, template requests and submitted work.
    case mining(MiningEvent)
}

public enum DisconnectReason: Sendable, Equatable {
    /// Blame: the peer sent a header that proves no work the chain accepts
    /// (`.proofOfWorkInvalid`: its hash misses its target, it is off the
    /// schedule, or its bytes do not match their CID).
    case proofOfWorkInvalid
    /// Not blame: a request to the peer passed its deadline, so its slot is
    /// freed. The peer may reconnect at once.
    case stalled
}

/// The durable form of one step: content first — header content and the
/// post-states its executions produced, stored, pinned and fsynced — then
/// the facts that reference it, committed. The shell writes it before executing any
/// later effect of the same step. Facts durable without their content is an
/// ordering violation the shell must prevent: a crash may lose the facts of
/// durable content, never the reverse.
public struct ChainBatch: Sendable {
    public let headers: [StoredHeader]
    /// Each executed block's materialized post-state: the state content a
    /// later execution resolves, written before the validation that
    /// references it.
    public let states: [LatticeState]
    public let facts: [BlockImportBatch]
    /// The stream cursors this step moved, per peer key: written with the
    /// facts that applied the entries they pass, never separately.
    public let cursors: [String: StreamCursor]

    public init(
        headers: [StoredHeader],
        states: [LatticeState] = [],
        facts: [BlockImportBatch],
        cursors: [String: StreamCursor] = [:]
    ) {
        self.headers = headers
        self.states = states
        self.facts = facts
        self.cursors = cursors
    }
}

public enum ChainEffect: Sendable {
    case send(PeerID, SyncMessage)
    /// Answer request `requestID` with these weighed headers, in order, then
    /// report `headersServed(peer, token:)`. The shell reads their content
    /// and caps the answer by bytes (`ChainCoreConfig.page`).
    case serveHeaders(PeerID, token: UInt64, requestID: UInt64, blockCIDs: [String], hasMore: Bool)
    case fetchByCID(PeerID, cid: String)
    /// Fetch a block's body Volume by CID through the content layer, and
    /// report `bodyFetched` once it is held locally.
    case fetchBody(cid: String)
    /// The window no longer wants this body: stop fetching it.
    case cancelBody(cid: String)
    /// Run `ChainTree.connect` on this job off the core and report its
    /// verdict as `connected`.
    case connect(ConnectJob)
    case disconnect(PeerID, DisconnectReason)
    case persist(ChainBatch)
    case publish(ChainSnapshot)
    case wakeAt(Int64)
    /// A child level: ask the evidence index for these blocks' proofs.
    case lookupProofs([String])
    /// A child level: run `ChildBlockProof.verifySecuringWork`, a pure job,
    /// and answer `proofVerified`.
    case verifyProof(ChildProofJob)
    /// A child level: write a credited proof to the local evidence index, so
    /// this node serves it. Emitted after the step's `persist`.
    case indexProof(childCID: String, ChildBlockProof)
    /// The answer to a mined grind (`NodeEvent.mined` with a reply ID): at
    /// once unless its root waits to execute, then from its verdict.
    case workSubmitted(replyID: UInt64, MinedOutcome)
    /// Read these executed blocks' transaction CIDs from content and answer
    /// `transactionsRead`: the act-on chain entered them, and their IDs were
    /// not held (executed before a restart, or below the body window).
    case readTransactions([String])
    /// The level's mempool and miner work (see `MiningEffect`), after the
    /// step's `persist` and `publish`. A `poolChanged` is durable state: the
    /// shell executes it, in order, before any later effect.
    case mining(MiningEffect)
}

public struct ChainCoreConfig: Sendable {
    public var maxHeadersPerPage: Int
    /// A served page stops before this many bytes (always at least one
    /// header).
    public var maxPageBytes: Int
    /// How long any request may wait for its answer before its peer is
    /// disconnected as stalled. Each page is its own request, so a stream
    /// that keeps delivering never times out.
    public var headersTimeout: Int64
    /// A child index larger than this travels by CID instead of inline.
    public var maxInlineChildIndexBytes: Int
    /// The operator's byte budget for headers not yet connected.
    public var pendingBudget: Int
    /// A header dated more than this beyond now is dropped (never blamed)
    /// instead of held: Bitcoin's two hours.
    public var maxFutureDrift: Int64
    /// A child level's proof bounds.
    public var proofs = ChildProofConfig()
    /// How many weighed-but-unexecuted blocks of the best chain, after the
    /// act-on tip, have their bodies asked for at once.
    public var bodyWindow: Int
    /// A connect with no verdict (its content was not resolvable) waits this
    /// long before its body is asked for again, doubling per attempt up to
    /// `bodyRetryCap`, and starting over whenever the act-on tip or the
    /// window changes.
    public var bodyRetryBase: Int64
    public var bodyRetryCap: Int64
    /// The level's mempool and template bounds.
    public var mining = MiningConfig()

    public init(
        maxHeadersPerPage: Int = 2_000,
        maxPageBytes: Int = 1 << 20,
        headersTimeout: Int64 = 30_000,
        maxInlineChildIndexBytes: Int = 16 * 1_024,
        pendingBudget: Int = 16 * 1_024 * 1_024,
        maxFutureDrift: Int64 = 2 * 60 * 60 * 1_000,
        bodyWindow: Int = 64,
        bodyRetryBase: Int64 = 1_000,
        bodyRetryCap: Int64 = 60_000
    ) {
        self.maxFutureDrift = maxFutureDrift
        self.maxHeadersPerPage = maxHeadersPerPage
        self.maxPageBytes = maxPageBytes
        self.headersTimeout = headersTimeout
        self.maxInlineChildIndexBytes = maxInlineChildIndexBytes
        self.pendingBudget = pendingBudget
        self.bodyWindow = bodyWindow
        self.bodyRetryBase = bodyRetryBase
        self.bodyRetryCap = bodyRetryCap
    }

    /// A header as it travels: its children map inline when it fits, and a
    /// genesis's spec.
    public func entry(
        _ block: Block, children: FlatDictionary<BlockHeader>, proofs: [ChildBlockProof] = [], spec: ChainSpec? = nil
    ) -> HeaderEntry {
        let fits = (children.toData()?.count ?? .max) <= maxInlineChildIndexBytes
        return HeaderEntry(block: block, children: fits ? children : nil, proofs: proofs, spec: spec)
    }

    /// The answer the shell sends: `entries` cut at `maxPageBytes` (at least
    /// one), with `hasMore` set when cut. The requester continues after the
    /// last header it receives.
    public func page(_ entries: [HeaderEntry], hasMore: Bool) -> (entries: [HeaderEntry], hasMore: Bool) {
        var total = 0
        for (index, entry) in entries.enumerated() {
            total += ChainCore.size(of: entry)
            if index > 0, total > maxPageBytes {
                return (Array(entries[..<index]), true)
            }
        }
        return (entries, hasMore)
    }
}

/// The node's state machine for one root level: the chain tree and header
/// sync as values behind one synchronous `step`. No IO, no awaits: every
/// mutation of a step is atomic, and the effects say what the shell must do.
///
/// HeaderSync replicates the level's weighed subgraph as a stream of weigh logs.
/// Every weighed object (a header, or a credited proof) — excluded ones too —
/// is appended to this node's log in weigh order. Each peer reads our log
/// from where it left off, as pages of IDs, and then receives what we append
/// as we append it: one mechanism for catch-up and relay. A node fetches only
/// the objects it lacks (`getData`) and verifies each on arrival; an unknown
/// parent is fetched with its ancestors from a peer that sent the header.
/// HeaderSync never reads canonicity. Only a proof-of-work failure blames a peer.
///
/// Block bodies (`BodyPipeline.swift`) are fetched by CID through the content layer and
/// connected in parent order along the best chain; a missing body is an
/// availability wait, never blame.
public struct ChainCore: Sendable {
    public internal(set) var tree: ChainTree
    public internal(set) var sync = HeaderSync()
    public internal(set) var bodies = BodyPipeline()
    public private(set) var published: ChainSnapshot?
    public let config: ChainCoreConfig
    public internal(set) var index = WeighedIndex()
    /// The level's mempool and template book, on the act-on tip.
    public internal(set) var mining: MiningState
    /// The transaction CIDs of executed blocks within `bodyWindow` heights of
    /// the act-on tip, from their connects: what the act-on chain confirms
    /// when it enters them, without a read. Bounded like the bodies kept.
    var executedTransactions: [String: [String]] = [:]
    /// Blocks whose transaction CIDs are being read.
    var readingTransactions: Set<String> = []
    /// This host's mined blocks awaiting their answer, by block: answered
    /// once executed (or proven invalid), or at once when the block is
    /// weighed off the best chain, which the body window never executes.
    var minedReplies: [String: UInt64] = [:]
    /// The blocks this step's admissions weighed (`ChainTreeUpdate.weighed`),
    /// for the host to forward to run attribution. Reset by every step.
    public internal(set) var weighed: [String] = []

    /// A core over a bootstrapped, restored or empty tree, with its weigh
    /// log and the per-peer stream cursors the shell persisted. `roots` are
    /// the tree's genesis roots (default: its best chain's). A node whose
    /// store resets passes a new log id.
    public init(
        tree: ChainTree,
        roots: [String]? = nil,
        config: ChainCoreConfig = ChainCoreConfig(),
        log: WeighLog = WeighLog(),
        cursors: [String: StreamCursor] = [:]
    ) {
        var tree = tree
        precondition(tree.context != nil, "the core runs one chain's level")
        mining = MiningState(tipCID: Self.miningTip(of: tree), spec: Self.actOnSpec(of: tree), config: config.mining)
        var index = WeighedIndex()
        var stack = roots ?? Self.bestRoot(of: tree)
        while let hash = stack.popLast() {
            guard let meta = tree.getConsensusBlock(hash: hash) else { continue }
            index.add(hash, parent: meta.parentBlockHash, height: meta.blockHeight)
            stack += meta.childHashes
        }
        self.tree = tree
        self.config = config
        self.index = index
        self.sync.log = log
        self.sync.cursors = cursors
        self.sync.knownCursors = Set(cursors.keys)
    }

    /// The weigh log the fact log implies, in fact order: each block fact a
    /// header, and at a child level each grind's work fact a proof (keyed by
    /// its root). A root chain's genesis is configured, never streamed; a
    /// child genesis weighs by its proofs like any child header. The fact
    /// log is the one source of truth; attributed runs are derived and never
    /// facts.
    static func logEntries(of batches: [BlockImportBatch], isRoot: Bool) -> [LogEntry] {
        let facts = batches.flatMap(\.facts)
        let rootGenesis: Set<String> = isRoot ? Set(facts.compactMap {
            guard case .block(let block) = $0, block.parentBlockHash == nil else { return nil }
            return block.blockHash
        }) : []
        return facts.compactMap { fact in
            switch fact {
            case .block(let block) where !rootGenesis.contains(block.blockHash):
                return .header(block.blockHash)
            case .work(let work) where !isRoot:
                return .proof(work.contribution.id, of: work.blockHash)
            default:
                return nil
            }
        }
    }

    /// Rebuild a core from its durable facts and the specs its genesis roots
    /// name (the tree binds each to its root). A level with no facts yet is
    /// an empty tree. A child level passes its restored `parent`, serving
    /// its directory, so its attributed runs are derived.
    public static func restore(
        replaying facts: [BlockImportBatch],
        context: ChainRuntimeContext,
        specs: [ChainSpec],
        parent: ChainTree? = nil,
        config: ChainCoreConfig = ChainCoreConfig(),
        logID: String = "",
        cursors: [String: StreamCursor] = [:]
    ) throws -> ChainCore {
        let tree = facts.isEmpty
            ? ChainTree.empty(context: context)
            : try ChainTree.restore(replaying: facts, context: context, specs: specs, parent: parent)
        let roots = facts.flatMap(\.facts).compactMap { fact -> String? in
            guard case .block(let block) = fact, block.parentBlockHash == nil else { return nil }
            return block.blockHash
        }
        return ChainCore(
            tree: tree,
            roots: roots,
            config: config,
            log: WeighLog(id: logID, entries: logEntries(of: facts, isRoot: context.isRoot)),
            cursors: cursors
        )
    }

    public mutating func step(_ event: ChainEvent, now: Int64) -> [ChainEffect] {
        var turn = Turn(now: now)
        weighed = []
        switch event {
        case .peerReady(let peer):
            guard sync.peers[peer] == nil else { break }
            var state = PeerSync()
            state.taken = sync.cursors[peer.key]?.position ?? 0
            sync.peers[peer] = state
            requestStream(from: peer, &turn)
        case .peerGone(let peer):
            drop(peer, &turn)
        case .received(let peer, let message):
            guard sync.peers[peer] != nil else { break }
            receive(message, from: peer, &turn)
        case .childIndexFetched(let peer, let cid, let index):
            childIndexFetched(index, cid: cid, from: peer, &turn)
        case .headersServed(let peer, let token):
            guard sync.peers[peer]?.serving == token else { break }
            sync.peers[peer]?.serving = nil
            if let next = sync.peers[peer]?.queued.first {
                sync.peers[peer]?.queued.removeFirst()
                serve(next, to: peer, &turn)
            }
        case .bodyFetched(let cid):
            bodyFetched(cid)
        case .connected(let verdict, let transactions):
            connected(verdict, transactions: transactions, &turn)
        case .transactionsRead(let blocks):
            readingTransactions.subtract(blocks.keys)
            for (cid, transactions) in blocks where index.contains(cid) {
                executedTransactions[cid] = transactions
            }
        case .parentFactsPresent(let blocks):
            parentFactsPresent(blocks)
        case .tick:
            tick(&turn)
        case .proofsFound(let cid, let proofs):
            proofsFound(proofs, for: cid, &turn)
        case .proofDropped(let job):
            if let checked = sync.proofs.verifying.removeValue(forKey: job.key) {
                sync.proofs.charge(checked, -1)
                skipped(job.childCID)
            }
        case .proofVerified(let job, let result):
            proofVerified(job, result, &turn)
        case .evidenceChanged(let cids):
            evidenceChanged(cids)
        case .mining(let event):
            turn.mining += mining.step(event, now: turn.now)
        }
        drain(&turn)
        if !isRoot { proofWork(&turn) }
        // Evict once the step's headers are processed, so a header held for
        // its future timestamp is already in the first eviction tier.
        sync.evict(to: config.pendingBudget)
        for peer in sync.peers.keys.sorted() {
            advanceCursor(of: peer, &turn)
            pump(peer, &turn)
        }
        return finish(turn)
    }

    // MARK: - Step bookkeeping

    /// What one step produced, in order.
    struct Turn {
        let now: Int64
        var headers: [StoredHeader] = []
        var states: [LatticeState] = []
        var facts: [BlockImportBatch] = []
        var effects: [ChainEffect] = []
        /// Child proofs this step credited, to index.
        var indexed: [(childCID: String, proof: ChildBlockProof)] = []
        /// Stream cursors this step moved.
        var cursors: [String: StreamCursor] = [:]
        var mining: [MiningEffect] = []
        /// Pending headers to look at again, smallest priority first.
        var dirty = Heap<(priority: UInt256, cid: String)> {
            $0.priority != $1.priority ? $0.priority < $1.priority : $0.cid < $1.cid
        }

        init(now: Int64) { self.now = now }
    }

    /// Persist first, then publish, then push, then everything else, the
    /// mining effects last: nothing a step makes visible precedes the write
    /// that makes it durable. Every step ends by scheduling the body window,
    /// whatever moved it, and a move of the act-on tip reaches the mempool
    /// in the same step.
    mutating func finish(_ turn: Turn) -> [ChainEffect] {
        var turn = turn
        scheduleBodies(&turn)
        moveMiningTip(&turn)
        answerSideMined(&turn)
        var effects: [ChainEffect] = []
        // The weigh log follows the fact log: a header precedes its proofs,
        // a parent its children.
        let start = sync.log.count
        for entry in Self.logEntries(of: turn.facts, isRoot: isRoot) { sync.log.append(entry) }
        // At most a page is pushed; `hasMore` has the peer pull the rest.
        let appended = sync.log.page(after: start, limit: config.maxHeadersPerPage, bytes: config.maxPageBytes)
        if !turn.facts.isEmpty || !turn.cursors.isEmpty {
            effects.append(.persist(ChainBatch(
                headers: turn.headers, states: turn.states, facts: turn.facts, cursors: turn.cursors
            )))
        }
        effects += turn.indexed.map { .indexProof(childCID: $0.childCID, $0.proof) }
        let current = snapshot
        if current != published {
            published = current
            effects.append(.publish(current))
        }
        // Push what was appended to every peer that read our log to its end:
        // the stream's tail is the relay. Relaying a header is not acting on
        // its weight: only tip announces and templates act, and they come
        // from the executed tip.
        if !appended.entries.isEmpty {
            for peer in sync.peers.keys.sorted() where sync.peers[peer]?.subscribed == true {
                effects.append(.send(peer, .stream(StreamPage(
                    requestID: 0, logID: sync.log.id, entries: appended.entries, hasMore: appended.hasMore
                ))))
            }
        }
        effects += turn.effects
        effects += turn.mining.map { .mining($0) }
        sync.compact()
        // Holes left unasked are asked again on a tick.
        let holes = sync.peers.values.contains { !$0.holes.isEmpty && $0.data == nil }
        let deadlines = [sync.nextDeadline(after: turn.now), bodies.nextRetry(after: turn.now),
                         holes ? turn.now + config.headersTimeout : nil]
        if let deadline = deadlines.compactMap({ $0 }).min() {
            effects.append(.wakeAt(deadline))
        }
        return effects
    }

    mutating func disconnect(_ peer: PeerID, _ reason: DisconnectReason, _ turn: inout Turn) {
        guard sync.peers[peer] != nil else { return }
        drop(peer, &turn)
        turn.effects.append(.disconnect(peer, reason))
    }

    /// Forget `peer`. Each pending header it announced moves to its next
    /// live announcer.
    private mutating func drop(_ peer: PeerID, _ turn: inout Turn) {
        guard sync.peers.removeValue(forKey: peer) != nil else { return }
        // Until the store keeps cursors (P4), only those it handed back
        // outlive their session.
        if !sync.knownCursors.contains(peer.key), !sync.peers.keys.contains(where: { $0.key == peer.key }) {
            sync.cursors[peer.key] = nil
        }
        if !isRoot { dropProofSource(peer) }
        for parent in [true, false] {
            sync.wants[WantSlot(peer: peer, parent: parent)] = nil
            sync.wanting[WantSlot(peer: peer, parent: parent)] = nil
        }
        for cid in sync.announced.removeValue(forKey: peer) ?? [] {
            guard var header = sync.pending.entries[cid],
                  let position = header.announcers.firstIndex(of: peer) else { continue }
            header.announcers.remove(at: position)
            if position == 0 { header.askedParent = false }
            sync.pending.entries[cid] = header
            if position == 0 { dirty(cid, &turn) }
        }
    }

    private mutating func nextRequestID() -> UInt64 {
        defer { sync.nextRequestID += 1 }
        return sync.nextRequestID
    }

    func dirty(_ cid: String, _ turn: inout Turn) {
        turn.dirty.push((sync.pending.priority[cid] ?? .max, cid))
    }

    // MARK: - Serving

    /// Every request takes the peer's one serving slot, queued (two at most)
    /// while it is busy. A stream page is answered from memory and frees
    /// the slot at once; content waits for the shell's `headersServed`.
    private mutating func receive(_ message: SyncMessage, from peer: PeerID, _ turn: inout Turn) {
        switch message {
        case .getStream, .getData, .getAncestors:
            // A peer reading our log names its own log at this level: one we
            // have not read (a new instance, or one we never had) is read now.
            if case .getStream(_, _, _, let own) = message, own != sync.cursors[peer.key]?.logID {
                requestStream(from: peer, &turn)
            }
            if sync.peers[peer]?.serving == nil {
                serve(message, to: peer, &turn)
            } else if (sync.peers[peer]?.queued.count ?? 0) < 2 {
                sync.peers[peer]?.queued.append(message)
            }
        case .stream(let page):
            receive(page, from: peer, &turn)
        case .headers(let response):
            receive(response, from: peer, &turn)
        }
    }

    /// Answer one request through the peer's serving slot.
    mutating func serve(_ message: SyncMessage, to peer: PeerID, _ turn: inout Turn) {
        let requestID: UInt64
        let cids: [String]
        switch message {
        case .getStream(let id, let logID, let after, _):
            // Our log after `after`, IDs only, at most a page (by count and
            // bytes); from 0 if the peer's log id is not ours or its position
            // is past our log (a reset). A page that reaches the end
            // subscribes the peer.
            let from = logID == sync.log.id && after <= sync.log.count ? after : 0
            let page = sync.log.page(after: from, limit: config.maxHeadersPerPage, bytes: config.maxPageBytes)
            sync.peers[peer]?.subscribed = !page.hasMore
            turn.effects.append(.send(peer, .stream(StreamPage(
                requestID: id, logID: sync.log.id, entries: page.entries, hasMore: page.hasMore
            ))))
            if let next = sync.peers[peer]?.queued.first {
                sync.peers[peer]?.queued.removeFirst()
                serve(next, to: peer, &turn)
            }
            return
        case .getAncestors(let id, let cid, let max):
            requestID = id
            cids = ancestors(of: cid, max: max)
        case .getData(let id, let asked):
            requestID = id
            var seen = Set<String>()
            cids = asked.prefix(config.maxHeadersPerPage)
                .filter { !isRootGenesis($0) && index.contains($0) && seen.insert($0).inserted }
        case .stream, .headers:
            return
        }
        let token = sync.nextToken
        sync.nextToken += 1
        sync.peers[peer]?.serving = token
        turn.effects.append(.serveHeaders(
            peer, token: token, requestID: requestID, blockCIDs: cids, hasMore: false
        ))
    }

    /// Whether `cid` is a root chain's genesis: configured on every node,
    /// so never served.
    func isRootGenesis(_ cid: String) -> Bool {
        isRoot && index.contains(cid) && index.parent[cid] == nil
    }

    /// The weighed header `cid` and up to `max` of its ancestors (capped by
    /// the page), child to parent, stopping above a root chain's genesis: one
    /// parent step each.
    func ancestors(of cid: String, max: Int) -> [String] {
        guard !isRootGenesis(cid), index.contains(cid) else { return [] }
        var cids = [cid]
        var current = cid
        let limit = Swift.min(Swift.max(max, 0), config.maxHeadersPerPage)
        while cids.count <= limit, let parent = index.parent[current], !isRootGenesis(parent) {
            cids.append(parent)
            current = parent
        }
        return cids
    }

    // MARK: - Streams

    /// Ask `peer` for its log after what we took of it (on a new session,
    /// after our cursor in it; a fresh peer: 0).
    private mutating func requestStream(from peer: PeerID, _ turn: inout Turn) {
        guard let state = sync.peers[peer], state.stream == nil else { return }
        let requestID = nextRequestID()
        sync.peers[peer]?.stream = InFlightStream(requestID: requestID, deadline: turn.now + config.headersTimeout)
        sync.peers[peer]?.more = false
        turn.effects.append(.send(peer, .getStream(
            requestID: requestID, logID: sync.cursors[peer.key]?.logID, after: state.taken, own: sync.log.id
        )))
    }

    /// A page of `peer`'s log, asked or pushed. A log id that is not the
    /// cursor's means the peer's log is another instance (reset, or a level
    /// it stopped or started running): only that cursor starts over, from 0,
    /// and what was in flight for the old log is forgotten. Entries are
    /// taken in order from the next position while the peer's holes (taken,
    /// not yet applied) fit in a page; a gap, a full page or `hasMore` has
    /// the next pull continue it.
    private mutating func receive(_ page: StreamPage, from peer: PeerID, _ turn: inout Turn) {
        guard let state = sync.peers[peer] else { return }
        let reset = sync.cursors[peer.key]?.logID != page.logID
        if page.requestID != 0 {
            guard state.stream?.requestID == page.requestID else { return }
            sync.peers[peer]?.stream = nil
            sync.peers[peer]?.more = page.hasMore
        } else if !reset && state.stream != nil {
            // The answer in flight carries these too.
            return
        } else if page.hasMore {
            sync.peers[peer]?.more = true
        }
        if reset {
            sync.cursors[peer.key] = StreamCursor(logID: page.logID, position: 0)
            turn.cursors[peer.key] = sync.cursors[peer.key]
            sync.peers[peer]?.taken = 0
            sync.peers[peer]?.holes = []
            sync.peers[peer]?.requested = 0
            sync.peers[peer]?.data = nil
        }
        for item in page.entries {
            guard let state = sync.peers[peer], item.position > state.taken else { continue }
            guard item.position == state.taken + 1, state.holes.count < config.maxHeadersPerPage else {
                sync.peers[peer]?.more = true
                break
            }
            sync.peers[peer]?.taken = item.position
            if !applied(item.entry) { sync.peers[peer]?.holes.append(item) }
        }
        advanceCursor(of: peer, &turn)
        pump(peer, &turn)
    }

    /// Whether a logged object is applied here: a header weighed, a grind
    /// credited.
    mutating func applied(_ entry: LogEntry) -> Bool {
        guard index.contains(entry.block) else { return false }
        return entry.kind == .header || tree.getConsensusBlock(hash: entry.block)?.workContributions[entry.cid] != nil
    }

    /// The cursor in `peer`'s log: before its first hole not yet applied
    /// (only that one is looked at), else through what was taken.
    mutating func advanceCursor(of peer: PeerID, _ turn: inout Turn) {
        guard var state = sync.peers[peer], let cursor = sync.cursors[peer.key] else { return }
        while let hole = state.holes.first, applied(hole.entry) { state.holes.removeFirst() }
        sync.peers[peer] = state
        let position = state.holes.first.map { $0.position - 1 } ?? state.taken
        guard position != cursor.position else { return }
        sync.cursors[peer.key] = StreamCursor(logID: cursor.logID, position: position)
        turn.cursors[peer.key] = sync.cursors[peer.key]
    }

    /// Whether this node lacks a logged object: nothing of it held, weighed
    /// or in hand.
    mutating func lacks(_ entry: LogEntry, inFlight: Set<String> = []) -> Bool {
        if inFlight.contains(entry.block) { return false }
        switch entry.kind {
        case .header:
            return !index.contains(entry.block) && sync.pending.entries[entry.block] == nil
                && sync.proofs.awaiting[entry.block] == nil
        case .proof:
            return !applied(entry) && sync.pending.entries[entry.block]?.evidence[entry.cid] == nil
                && !sync.proofs.verifying.values.contains { $0.cid == entry.block && $0.proof.rootCID == entry.cid }
                && !sync.proofs.queued.contains { $0.cid == entry.block && $0.proof.rootCID == entry.cid }
        }
    }

    /// One `getData` at a time, for the holes this node lacks and has not
    /// asked for (an object asked of another peer counts as held, until that
    /// request stalls). A header it holds but has not weighed gains the peer
    /// as an announcer (the peer holds its ancestors). Otherwise the next
    /// page is pulled. Holes still lacking are asked again on a tick.
    mutating func pump(_ peer: PeerID, _ turn: inout Turn, again: Bool = false) {
        guard let state = sync.peers[peer], state.data == nil, sync.cursors[peer.key] != nil else { return }
        let inFlight = Set(sync.peers.values.flatMap { $0.data?.cids ?? [] })
        var ask: [StreamEntry] = []
        for hole in state.holes where (again || hole.position > state.requested) && lacks(hole.entry, inFlight: inFlight) {
            ask.append(hole)
        }
        for hole in state.holes where hole.position > state.requested && hole.entry.kind == .header
            && sync.pending.entries[hole.entry.block] != nil {
            announce(hole.entry.block, by: peer, &turn)
        }
        if let last = state.holes.last { sync.peers[peer]?.requested = Swift.max(state.requested, last.position) }
        var seen = Set<String>()
        let cids = ask.map(\.entry.block).filter { seen.insert($0).inserted }
        if !cids.isEmpty {
            requestData(cids, from: peer, &turn)
        } else if state.more, state.stream == nil, state.holes.count < config.maxHeadersPerPage {
            requestStream(from: peer, &turn)
        }
    }

    private mutating func requestData(_ cids: [String], from peer: PeerID, _ turn: inout Turn) {
        let requestID = nextRequestID()
        sync.peers[peer]?.data = InFlightData(
            requestID: requestID, cids: cids, deadline: turn.now + config.headersTimeout
        )
        turn.effects.append(.send(peer, .getData(requestID: requestID, cids: cids)))
    }

    /// Headers from `peer`: the objects asked of it, or the ancestors asked
    /// of it (child to parent, taken parent first); anything unasked is
    /// ignored (the stream's tail is the relay). A peer that advertised an
    /// object and serves none of it is failing to serve: a stall, never
    /// blame. An answer cut short by bytes is asked again for the rest.
    private mutating func receive(_ response: HeadersResponse, from peer: PeerID, _ turn: inout Turn) {
        var data: InFlightData?
        var asked: String?
        if let inFlight = sync.peers[peer]?.data, inFlight.requestID == response.requestID {
            sync.peers[peer]?.data = nil
            data = inFlight
        } else if let request = sync.peers[peer]?.parentRequest, request.requestID == response.requestID {
            sync.peers[peer]?.parentRequest = nil
            asked = request.cid
        } else {
            return
        }
        var received = Set<String>()
        for entry in asked != nil ? response.entries.reversed() : response.entries {
            guard let cid = accept(entry, from: peer, &turn) else { return }
            received.insert(cid)
        }
        // An answer without the asked header: this peer does not hold it.
        // Its children move on to their next announcer; never blame.
        if let asked, !received.contains(asked) {
            for child in (sync.pending.childrenOf[asked] ?? []).sorted() {
                guard var header = sync.pending.entries[child], header.source == peer else { continue }
                header.announcers.removeFirst()
                header.askedParent = false
                sync.pending.entries[child] = header
                sync.announced[peer]?.remove(child)
                dirty(child, &turn)
            }
        }
        if asked != nil { nextWant(of: peer, parent: true, &turn) }
        if let data {
            let rest = data.cids.filter { !received.contains($0) }
            if rest.isEmpty {
                pump(peer, &turn)
            } else if received.isEmpty {
                disconnect(peer, .stalled, &turn)
            } else {
                requestData(rest, from: peer, &turn)
            }
        }
    }

    // MARK: - Accepting headers

    /// Take one header: only its proof-of-work is checked before it waits in
    /// the pending queue. Returns its CID, or nil when the peer was
    /// disconnected.
    private mutating func accept(_ entry: HeaderEntry, from peer: PeerID, _ turn: inout Turn) -> String? {
        guard let cid = try? BlockHeader(node: entry.block).rawCID else {
            disconnect(peer, .proofOfWorkInvalid, &turn)
            return nil
        }
        if index.contains(cid) {
            if !isRoot { offer(entry.proofs, cid: cid, from: peer) }
            return cid
        }
        // A root header proves its own work first: one that fails is blamed
        // whatever else is wrong with it (a date too far ahead included).
        if isRoot, ChainTree.rootWork(of: entry.block) == nil {
            disconnect(peer, .proofOfWorkInvalid, &turn)
            return nil
        }
        // Structural, never blame: an inline children map that is not the
        // one the block commits, or a root chain's genesis (configured, never
        // synced).
        if let children = entry.children, Self.cid(of: children) != entry.block.children.rawCID {
            return cid
        }
        guard entry.block.parent != nil || !isRoot else { return cid }
        let (horizon, overflow) = turn.now.addingReportingOverflow(config.maxFutureDrift)
        if !overflow, entry.block.timestamp > horizon { return cid }
        if let held = sync.pending.entries[cid] {
            announce(cid, by: peer, &turn)
            if let children = entry.children, held.children == nil {
                sync.pending.setChildren(children, of: cid, bytes: Self.size(of: children))
            }
            if held.spec == nil, let spec = Self.bound(entry.spec, by: entry.block) {
                sync.pending.entries[cid]?.spec = spec
            }
            if !isRoot { offer(entry.proofs, cid: cid, from: peer) }
            dirty(cid, &turn)
            return cid
        }
        // A child header's work is its proofs': it waits apart until one
        // verifies (see `ChildProofs.swift`).
        if !isRoot {
            awaitProof(entry, cid: cid, from: peer, &turn)
            return cid
        }
        // A peer that sent a header holds all its ancestors: this header
        // inherits every announcer of its pending children.
        var announcers = [peer]
        for child in (sync.pending.childrenOf[cid] ?? []).sorted() {
            for other in sync.pending.entries[child]?.announcers ?? [] where !announcers.contains(other) {
                announcers.append(other)
            }
        }
        sync.pending.insert(PendingHeader(
            blockCID: cid,
            block: entry.block,
            children: entry.children,
            hash: entry.block.proofOfWorkHash(),
            bytes: Self.size(of: entry.block) + (entry.children.map(Self.size) ?? 0),
            announcers: announcers
        ))
        for other in announcers { sync.announced[other, default: []].insert(cid) }
        dirty(cid, &turn)
        if let parent = entry.block.parent?.rawCID { announce(parent, by: peer, &turn) }
        return cid
    }

    /// `peer` sent `cid` or a descendant, so it holds `cid` and every
    /// ancestor: it joins the announcers of each pending one up to the root
    /// of the pending chain (the header whose parent is asked for). The walk
    /// stops at the first that already has it, whose ancestors have it too.
    /// A header whose announcers had all gone may be asked again.
    private mutating func announce(_ cid: String, by peer: PeerID, _ turn: inout Turn) {
        var current = cid
        while var header = sync.pending.entries[current], !header.announcers.contains(peer) {
            if header.announcers.isEmpty { header.askedParent = false }
            header.announcers.append(peer)
            sync.pending.entries[current] = header
            sync.announced[peer, default: []].insert(current)
            guard let parent = header.parent, sync.pending.entries[parent] != nil else {
                dirty(current, &turn)
                return
            }
            current = parent
        }
    }

    // MARK: - Processing pending headers

    /// Look at every dirty pending header, smallest priority first; each one
    /// weighed dirties its pending children.
    mutating func drain(_ turn: inout Turn) {
        while let next = turn.dirty.pop() {
            evaluate(next.cid, &turn)
        }
    }

    private mutating func evaluate(_ cid: String, _ turn: inout Turn) {
        guard let header = sync.pending.entries[cid] else { return }
        if let time = header.notBefore, time > turn.now { return }
        guard let parent = header.parent else {
            // A child genesis: no parent, no schedule.
            if header.children == nil { want(header, parent: false, &turn) } else { insert(header, &turn) }
            return
        }
        if index.contains(parent) {
            if header.children == nil {
                if scheduleCheck(header, turn.now, &turn) {
                    want(header, parent: false, &turn)
                }
            } else {
                insert(header, &turn)
            }
        } else if sync.pending.entries[parent] == nil, !header.askedParent {
            want(header, parent: true, &turn)
        }
    }

    /// The schedule half of the proof-of-work check, before a child-index
    /// fetch may be spent on the header: target, `nextTarget` and timestamp
    /// against its weighed parent. Returns whether to go on.
    private mutating func scheduleCheck(_ header: PendingHeader, _ now: Int64, _ turn: inout Turn) -> Bool {
        guard let parentHash = header.parent, let parent = tree.headerSnapshot(of: parentHash) else { return false }
        // The schedule is the root's spec's; a parent under a spec mismatch
        // (whose root spec is not its own) is left to admission.
        guard let spec = tree.specs[parent.specCID] else { return true }
        let anchor = tree.difficultyAnchor(forBlockHash: parentHash)
        do {
            let admission = try header.block.headerAdmission(
                parent: HeaderLinkageParent(
                    height: parent.tipHeight,
                    timestamp: parent.timestamp,
                    target: parent.target,
                    nextTarget: parent.nextTarget,
                    postStateCID: parent.postStateCID,
                    specCID: parent.specCID
                ),
                spec: spec,
                inheritedAnchor: { anchor },
                validationContext: ValidationContext(nowMilliseconds: now)
            )
            switch admission {
            case .linked, .excluded:
                return true
            case .offSchedule:
                sync.removePending(header.blockCID)
                if let source = header.source { disconnect(source, .proofOfWorkInvalid, &turn) }
            case .malformed:
                sync.removePending(header.blockCID)
            }
        } catch BlockValidationError.notYetValid {
            hold(header, until: header.block.timestamp)
        } catch {
            sync.removePending(header.blockCID)
        }
        return false
    }

    private mutating func hold(_ header: PendingHeader, until time: Int64) {
        sync.pending.entries[header.blockCID]?.notBefore = time
        sync.held.push((time, header.blockCID))
    }

    /// Weigh one header. Only `.proofOfWorkInvalid` blames its source; a
    /// header from this node's future waits for its time; anything else is
    /// dropped.
    private mutating func insert(_ header: PendingHeader, _ turn: inout Turn) {
        guard let children = header.children else { return }
        let cid = header.blockCID
        let context = ValidationContext(nowMilliseconds: turn.now)
        let admission = isRoot
            ? tree.insertRootHeader(header.block, childIndex: children, validationContext: context)
            : insertChildHeader(header, children: children, context)
        switch admission {
        case .applied(let update):
            let waiting = sync.pending.childrenOf[cid] ?? []
            sync.removePending(cid)
            turn.headers.append(StoredHeader(
                blockCID: cid, block: header.block, children: children,
                spec: header.parent == nil ? header.spec : nil
            ))
            turn.facts += update.batches
            weighed += update.weighed
            index.add(cid, parent: header.parent, height: header.block.height)
            creditRemainingProofs(of: header, &turn)
            for child in waiting { dirty(child, &turn) }
        case .duplicate:
            let waiting = sync.pending.childrenOf[cid] ?? []
            sync.removePending(cid)
            for child in waiting { dirty(child, &turn) }
        case .rejected(.proofOfWorkInvalid):
            sync.removePending(cid)
            if let source = header.source { disconnect(source, .proofOfWorkInvalid, &turn) }
        case .rejected(.notYetValid) where header.block.timestamp > turn.now:
            hold(header, until: header.block.timestamp)
        case .rejected:
            sync.removePending(cid)
        }
    }

    // MARK: - Requests for what a pending header lacks

    /// Ask the header's first announcer for its parent (with its ancestors)
    /// or its child index,
    /// or queue the ask until that request slot frees. A header no live
    /// peer announced waits for one: any peer that sends it or a descendant
    /// holds it all.
    private mutating func want(_ header: PendingHeader, parent: Bool, _ turn: inout Turn) {
        guard let source = header.source, let state = sync.peers[source] else { return }
        let cid = header.blockCID
        if parent {
            guard let parentHash = header.parent else { return }
            guard state.parentRequest == nil else { return queueWant(cid, of: source, parent: true) }
            let requestID = nextRequestID()
            sync.peers[source]?.parentRequest = InFlightHeader(
                requestID: requestID, cid: parentHash, deadline: turn.now + config.headersTimeout
            )
            sync.pending.entries[cid]?.askedParent = true
            turn.effects.append(.send(source, .getAncestors(
                requestID: requestID, cid: parentHash, max: config.maxHeadersPerPage
            )))
        } else {
            guard state.childIndex == nil else { return queueWant(cid, of: source, parent: false) }
            let children = header.block.children.rawCID
            sync.peers[source]?.childIndex = InFlightFetch(
                cid: children, deadline: turn.now + config.headersTimeout
            )
            turn.effects.append(.fetchByCID(source, cid: children))
        }
    }

    private mutating func queueWant(_ cid: String, of peer: PeerID, parent: Bool) {
        let key = WantSlot(peer: peer, parent: parent)
        guard sync.wanting[key, default: []].insert(cid).inserted else { return }
        sync.wants[key, default: Heap { $0.priority != $1.priority ? $0.priority < $1.priority : $0.cid < $1.cid }]
            .push((sync.pending.priority[cid] ?? .max, cid))
    }

    /// A request slot of `peer` freed: look again at its queued headers,
    /// smallest priority first, while the slot stays free.
    private mutating func nextWant(of peer: PeerID, parent: Bool, _ turn: inout Turn) {
        let key = WantSlot(peer: peer, parent: parent)
        func free(_ core: ChainCore) -> Bool {
            guard let state = core.sync.peers[peer] else { return false }
            return parent ? state.parentRequest == nil : state.childIndex == nil
        }
        while free(self), let next = sync.wants[key]?.pop() {
            sync.wanting[key]?.remove(next.cid)
            guard let header = sync.pending.entries[next.cid], header.source == peer else { continue }
            evaluate(next.cid, &turn)
        }
    }

    // MARK: - Child indexes

    private mutating func childIndexFetched(
        _ index: FlatDictionary<BlockHeader>?,
        cid: String,
        from peer: PeerID,
        _ turn: inout Turn
    ) {
        guard let waiting = sync.peers[peer]?.childIndex, waiting.cid == cid else { return }
        sync.peers[peer]?.childIndex = nil
        let committing = sync.pending.committing(cid)
        guard let index else {
            // The peer definitively lacks what its own header commits: drop
            // that header, never blame.
            for header in committing where header.source == peer {
                sync.removePending(header.blockCID)
            }
            nextWant(of: peer, parent: false, &turn)
            return
        }
        guard Self.cid(of: index) == cid else {
            disconnect(peer, .proofOfWorkInvalid, &turn)
            return
        }
        for header in committing {
            sync.pending.setChildren(index, of: header.blockCID, bytes: Self.size(of: index))
            dirty(header.blockCID, &turn)
        }
        nextWant(of: peer, parent: false, &turn)
    }

    // MARK: - Time

    /// A peer whose request passed its deadline is stalling: disconnect it
    /// to free the slot, never a ban. Held headers whose time came are looked
    /// at again.
    private mutating func tick(_ turn: inout Turn) {
        let now = turn.now
        for (peer, state) in sync.peers.sorted(by: { $0.key < $1.key })
        where state.deadlines.contains(where: { $0 <= now }) {
            disconnect(peer, .stalled, &turn)
        }
        for peer in sync.peers.keys.sorted() { pump(peer, &turn, again: true) }
        while let first = sync.held.first, first.time <= now {
            _ = sync.held.pop()
            if sync.pending.entries[first.cid]?.notBefore == first.time {
                sync.pending.entries[first.cid]?.notBefore = nil
                dirty(first.cid, &turn)
            }
        }
    }

    // MARK: - Content

    static func cid(of index: FlatDictionary<BlockHeader>) -> String? {
        try? HeaderImpl<FlatDictionary<BlockHeader>>(node: index).rawCID
    }

    static func size(of block: Block) -> Int {
        block.toData()?.count ?? 0
    }

    static func size(of index: FlatDictionary<BlockHeader>) -> Int {
        index.toData()?.count ?? 0
    }

    static func size(of entry: HeaderEntry) -> Int {
        size(of: entry.block) + (entry.children.map(size) ?? 0)
    }
}
