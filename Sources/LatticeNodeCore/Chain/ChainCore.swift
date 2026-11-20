import Lattice
import UInt256
import cashew

/// A level's durable facts as restore takes them: in the order the store
/// first took each (its staged batch, then its place in that batch), and
/// the number of staged batches that added them. The weigh log is that
/// order, each object once, so a restart keeps every log position.
public struct StoredFacts: Sendable {
    public let facts: [ChainFact]
    public let batches: UInt64

    public init(facts: [ChainFact], batches: UInt64) {
        self.facts = facts
        self.batches = batches
    }

    /// A store that kept the staged batches themselves: their facts in
    /// order, copies included (restore and the log take each once).
    public init(_ batches: [BlockImportBatch]) {
        self.init(facts: batches.flatMap(\.facts), batches: UInt64(batches.count))
    }

    public static let empty = StoredFacts(facts: [], batches: 0)
}

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
    /// The content layer could not obtain the body of this block: an
    /// availability wait, never a verdict. It is asked for again after the
    /// level's backoff (`ChainCoreConfig.bodyRetryBase`).
    case bodyUnavailable(cid: String)
    /// A peer hosting this level connected (a reconnect included): what
    /// no peer held may be held now, so every waiting body is asked for
    /// again.
    case providerJoined
    /// A connect job's verdicts, in its blocks' order, up to the first
    /// block without a valid one (`ChainEffect.connect`).
    case connected([ConnectResult])
    /// The answer to `readTransactions`: each block's transaction CIDs (a
    /// body no longer held reads as none).
    case transactionsRead([String: [String]])
    /// A child level: its parent level now holds the facts these blocks'
    /// connects lacked.
    case parentFactsPresent([String])
    case tick
    /// A child level: its parent level has weighed a peer's whole log
    /// (`headersSynced`), so this level's gate opens for good and every
    /// peer's stream is read.
    case parentWeighed
    /// A child level: a `verifyProofs` job finished, every check answered
    /// (nil for one whose block was not held: no verdict, no blame).
    case proofsVerified([ChildProofAnswer])
    /// A child level: a derivation of `deriveProofs` finished, every time it ran.
    case derived(ChildDerivation)
    /// A child level: a header submitted on this node (its author's push),
    /// taken as the same header gossiped from no peer.
    case submitted(HeaderEntry)
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

/// The durable form of one step: content first — the post-states its
/// executions produced, stored, pinned and fsynced — then the facts that
/// reference it, committed with their headers and credited proofs. The shell writes it before executing any
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
    /// A child level: the proofs this step credited, written with the work
    /// facts they produced, so this node serves them.
    public let proofs: [StoredProof]
    /// The stream cursors this step moved, per peer key: written with the
    /// facts that applied the entries they pass, never separately.
    public let cursors: [String: StreamCursor]

    public init(
        headers: [StoredHeader],
        states: [LatticeState] = [],
        facts: [BlockImportBatch],
        proofs: [StoredProof] = [],
        cursors: [String: StreamCursor] = [:]
    ) {
        self.headers = headers
        self.states = states
        self.facts = facts
        self.proofs = proofs
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
    /// report `bodyFetched` once it has been read, or `bodyUnavailable`
    /// when it could not be.
    case fetchBody(cid: String)
    /// The window no longer wants this body: stop fetching it.
    case cancelBody(cid: String)
    /// Run `ChainTree.connect` on these jobs off the core, in order (each
    /// block the previous one's child, reading the state the previous one
    /// produced), stop after the first without a valid verdict, and report
    /// the verdicts as one `connected`: one step, one commit for them all.
    case connect([ConnectJob])
    case disconnect(PeerID, DisconnectReason)
    case persist(ChainBatch)
    case publish(ChainSnapshot)
    case wakeAt(Int64)
    /// A child level: run every check of the batch (`verifySecuringWork`,
    /// pure) in one job off the step, reading from the store a block the
    /// batch does not carry, and answer `proofsVerified` once.
    case verifyProofs(ChildProofBatch)
    /// A child level: derive held blocks' proofs from the parent-level
    /// blocks that commit them, from this node's own content only, and
    /// answer `derived` for each (`ChildDeriveJob`). One per level and
    /// step, as `verifyProofs`: the shell runs it in at most one job per
    /// worker.
    case deriveProofs([ChildDeriveJob])
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

/// The node's state machine for one root level: the chain tree and header
/// sync as values behind one synchronous `step`. No IO, no awaits: every
/// mutation of a step is atomic, and the effects say what the shell must do.
///
/// HeaderSync (`ChainCore+HeaderSync.swift`) replicates the level's weighed
/// subgraph as a stream of weigh logs.
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
    /// Whether this level has caught up since it started: set the first time
    /// a peer's log has been read to its end and applied here, and the act-on
    /// tip is the heaviest tip whose bodies may be had (`latchSynced`). Never
    /// unset while the process runs, never
    /// persisted (geth's `handler.synced`, set when its downloader completes
    /// a sync cycle). Until then a peer's transaction is ignored.
    public internal(set) var synced = false
    /// Whether this level has weighed a peer's whole log since it started:
    /// the first half of `synced`, set whatever of the log is executed.
    /// One-way, never persisted. What a child level waits for before it
    /// reads its own peers: the work it weighs is committed in this level's
    /// weighed graph, never in what this level has executed (weight never
    /// waits on execution, its own chain's or its parent's). What a child
    /// block's execution needs of this level, the state its parent block
    /// produced, it waits for block by block (`awaitingParent`). Also when
    /// the relay starts: what this level appends from then on is new.
    public internal(set) var headersSynced = false
    public let config: ChainCoreConfig
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
    /// weighed where the body window will not execute it.
    var minedReplies: [String: UInt64] = [:]
    /// The blocks this step's admissions weighed (`ChainTreeUpdate.weighed`),
    /// for the host to forward to run attribution. Reset by every step.
    public internal(set) var weighed: [String] = []
    /// The blocks this step took in to wait for a proof: their committers'
    /// grinds are derived (`deriveGrinds`). Reset by every step.
    public internal(set) var arrived: [String] = []
    /// A child level, within one step only: its parent level's tree, whose
    /// committers make a header with no proofs worth taking (`awaitProof`).
    /// Never held past the step.
    var parentTree: ChainTree?
    /// A child level, within one step only: its parent level has not weighed
    /// a peer's whole log (`headersSynced`). Top-down by weight: a gated
    /// level reads none of its peers' streams, so it weighs, fetches and
    /// executes nothing from them; its cursors stay where they were. The
    /// parent's latch opens it for good (`parentWeighed`), while the parent
    /// may still be executing. Never held past the step.
    var gated = false
    /// A child level stepped while gated: its peers were held back, and are
    /// read once the parent has latched (`parentWeighed`).
    public internal(set) var heldBack = false
    /// The child directories this level's executed blocks commit: built from
    /// the held tree, then grown by every block that executes valid.
    public let executedChildren = ExecutedChildren()

    /// A core over a bootstrapped, restored or empty tree, with its weigh
    /// log and the per-peer stream cursors the shell persisted. `roots` are
    /// the tree's genesis roots (default: all it holds). A node whose
    /// store resets passes a new log id.
    public init(
        tree: ChainTree,
        roots: [String]? = nil,
        config: ChainCoreConfig = ChainCoreConfig(),
        log: WeighLog = WeighLog(),
        cursors: [String: StreamCursor] = [:]
    ) {
        precondition(tree.context != nil, "the core runs one chain's level")
        var stack = roots ?? tree.genesisRoots
        while let hash = stack.popLast() {
            guard let meta = tree.getConsensusBlock(hash: hash) else { continue }
            if tree.isExecuted(blockHash: hash) {
                executedChildren.record(meta.childCommitments.keys)
            }
            stack += meta.childHashes
        }
        mining = MiningState(
            tipCID: Self.miningTip(of: tree), spec: Self.actOnSpec(of: tree), config: config.mining
        )
        self.tree = tree
        self.config = config
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
    static func logEntries(of facts: [ChainFact], isRoot: Bool) -> [LogEntry] {
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
    ///
    /// The revision floor is the number of staged batches that added a
    /// fact. On a root level each batch that took a revision added at least
    /// one new fact, so no revision exposed before the restart exceeds it.
    /// Replay alone can count fewer: its sort can apply a batch that
    /// re-states a grind's final quantity before the work batches that
    /// raised it, which then replay as duplicates (§12.5.11). A child level
    /// also takes a revision for each raised attributed run
    /// (`applyParentRun`), which no durable row records and restore
    /// re-derives once, so there the floor can still fall short. The node
    /// exposes no revision to clients.
    public static func restore(
        _ stored: StoredFacts,
        context: ChainRuntimeContext,
        specs: [ChainSpec],
        parent: ChainTree? = nil,
        config: ChainCoreConfig = ChainCoreConfig(),
        logID: String = "",
        cursors: [String: StreamCursor] = [:]
    ) throws -> ChainCore {
        let tree = stored.facts.isEmpty
            ? ChainTree.empty(context: context)
            : try ChainTree.restore(
                facts: stored.facts,
                revisionFloor: stored.batches,
                context: context,
                specs: specs,
                parent: parent
            )
        let roots = stored.facts.compactMap { fact -> String? in
            guard case .block(let block) = fact, block.parentBlockHash == nil else { return nil }
            return block.blockHash
        }
        return ChainCore(
            tree: tree,
            roots: roots,
            config: config,
            log: WeighLog(id: logID, entries: logEntries(of: stored.facts, isRoot: context.isRoot), in: tree),
            cursors: cursors
        )
    }

    /// One event. A child level is handed its parent level's tree, and
    /// whether that level has weighed a peer's whole log (`headersSynced`),
    /// for the step alone (`parentTree`, `gated`).
    public mutating func step(
        _ event: ChainEvent, now: Int64, parent: ChainTree? = nil, parentWeighed: Bool = true,
        parentCaughtUp: Bool = true
    ) -> [ChainEffect] {
        // A peer's transaction is ignored until the level has caught up
        // (`synced`), as Bitcoin Core ignores `tx` during initial block
        // download: its verdict would be read on a tip about to move. Never
        // blamed.
        if case .mining(.transactionReceived(_, origin: .peer)) = event, !synced { return [] }
        parentTree = parent
        gated = !parentWeighed
        if gated { heldBack = true }
        defer {
            parentTree = nil
            gated = false
        }
        var turn = Turn(now: now, parentCaughtUp: parentCaughtUp)
        weighed = []
        arrived = []
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
        case .bodyUnavailable(let cid):
            bodyUnavailable(cid, &turn)
        case .providerJoined:
            providerJoined()
        case .connected(let results):
            connected(results, &turn)
        case .transactionsRead(let blocks):
            readingTransactions.subtract(blocks.keys)
            for (cid, transactions) in blocks where tree.contains(blockHash: cid) {
                executedTransactions[cid] = transactions
            }
        case .parentFactsPresent(let blocks):
            parentFactsPresent(blocks)
        case .tick:
            tick(&turn)
        case .parentWeighed:
            heldBack = false
            for peer in sync.peers.keys.sorted() { requestStream(from: peer, &turn) }
        case .proofsVerified(let answers):
            proofsVerified(answers, &turn)
        case .derived(let derivation):
            // Applied even when it outlived its count (an unhost between):
            // the job is pure and credit idempotent.
            guard !isRoot else { break }
            sync.proofs.finishDeriving(derivation.job.childCID)
            derived(derivation, &turn)
            released(derivation.job.childCID, &turn)
        case .submitted(let entry):
            guard !isRoot else { break }
            _ = accept(entry, from: nil, &turn)
        case .mining(let event):
            turn.mining += mining.step(event, now: turn.now)
        }
        drain(&turn)
        // Evict once the step's headers are processed, so a header weighed
        // this step (a promoted one whose parent is weighed) has already left
        // the queue: only what still waits is evicted, largest hash first.
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
        /// A child level's step: whether its parent level has caught up now
        /// (`caughtUp`, and latched `synced`), so that a parent fact it
        /// lacks is not on its way from the parent's own progress
        /// (`unobtainable`). Nil for work that runs this level's `finish`
        /// without the host (an own block weighed, a parent's run applied),
        /// which assumes a child's parent is still syncing; a root has none.
        var parentCaughtUp: Bool?

        init(now: Int64, parentCaughtUp: Bool? = nil) {
            self.now = now
            self.parentCaughtUp = parentCaughtUp
        }
        var headers: [StoredHeader] = []
        var states: [LatticeState] = []
        var facts: [BlockImportBatch] = []
        var effects: [ChainEffect] = []
        /// Child proofs this step credited, to index.
        var indexed: [StoredProof] = []
        /// Peers' proofs this step took, checked as one job (`finish`).
        var checks: [ChildProofJob] = []
        /// Stream cursors this step moved.
        var cursors: [String: StreamCursor] = [:]
        var mining: [MiningEffect] = []
        /// The step weighed a block this node produced: mined or submitted
        /// here (`weighOwn`), or a header no peer announced.
        var own = false
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
        let actOn = followActOnChain(&turn)
        var effects: [ChainEffect] = []
        // The weigh log follows the fact log: a header precedes its proofs,
        // a parent its children.
        let start = sync.log.count
        for entry in Self.logEntries(of: turn.facts.flatMap(\.facts), isRoot: isRoot) { sync.log.append(entry, in: tree) }
        // At most a page is pushed; `hasMore` has the peer pull the rest.
        let appended = sync.log.page(after: start, limit: config.maxHeadersPerPage, bytes: config.maxPageBytes)
        if !turn.facts.isEmpty || !turn.indexed.isEmpty || !turn.cursors.isEmpty {
            effects.append(.persist(ChainBatch(
                headers: turn.headers, states: turn.states, facts: turn.facts,
                proofs: turn.indexed, cursors: turn.cursors
            )))
        }
        let wasWeighed = headersSynced
        latchSynced(parentCaughtUp: turn.parentCaughtUp ?? isRoot)
        // The step that latches pushes at least the log's last entry: a
        // subscriber from before the latch pulls the gap from its position.
        let tail = appended.entries.isEmpty && !wasWeighed && headersSynced && sync.log.count > 0
            ? sync.log.page(after: sync.log.count - 1, limit: 1) : appended
        let current = snapshot(actOn: actOn)
        // A best tip that moved down moved the finality window with it: what
        // was declined just past the old window may be inside the new one.
        if let published, current.bestHeaderHeight < published.bestHeaderHeight {
            sync.declined = DeclinedSet(capacity: sync.declined.capacity)
        }
        if current != published {
            published = current
            effects.append(.publish(current))
        }
        // Push what was appended to every peer that read our log to its end:
        // the stream's tail is the relay. Relaying a header is not acting on
        // its weight: only tip announces and templates act, and they come
        // from the executed tip. So the relay waits on weight, never on
        // execution, and pushes what is new: a block this node produced,
        // which no peer has yet, or anything appended once this level has
        // weighed a peer's whole log (`headersSynced`). Before that, what it
        // appends is history a subscriber has, as Bitcoin Core announces
        // nothing during initial download. A peer still pulls our log, and
        // a push past its position has it pull the gap.
        if headersSynced || turn.own, !tail.entries.isEmpty {
            for peer in sync.peers.keys.sorted() where sync.peers[peer]?.subscribed == true {
                effects.append(.send(peer, .stream(StreamPage(
                    requestID: 0, logID: sync.log.id, entries: tail.entries, hasMore: tail.hasMore
                ))))
                // A cut push has the peer pull the rest: it is subscribed
                // again once a pull reaches the end.
                if tail.hasMore { sync.peers[peer]?.subscribed = false }
            }
        }
        effects += turn.effects
        if !turn.checks.isEmpty { effects.append(.verifyProofs(ChildProofBatch(jobs: turn.checks))) }
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

    mutating func nextRequestID() -> UInt64 {
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
                .filter { !isRootGenesis($0) && tree.contains(blockHash: $0) && seen.insert($0).inserted }
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
        isRoot && tree.contains(blockHash: cid) && tree.parent(of: cid) == nil
    }

    /// The weighed header `cid` and up to `max` of its ancestors (capped by
    /// the page), child to parent, stopping above a root chain's genesis: one
    /// parent step each.
    func ancestors(of cid: String, max: Int) -> [String] {
        guard !isRootGenesis(cid), tree.contains(blockHash: cid) else { return [] }
        var cids = [cid]
        var current = cid
        let limit = Swift.min(Swift.max(max, 0), config.maxHeadersPerPage)
        while cids.count <= limit, let parent = tree.parent(of: current), !isRootGenesis(parent) {
            cids.append(parent)
            current = parent
        }
        return cids
    }

    // MARK: - Finality

    /// Decline a header beyond the window, and every pending header below it,
    /// which could only attach through it. Never a verdict, never blame.
    mutating func decline(_ cid: String) {
        var stack = [cid]
        while let next = stack.popLast() {
            stack += sync.pending.childrenOf[next] ?? []
            sync.removePending(next)
            sync.proofs.awaiting[next] = nil
            sync.declined.insert(next)
        }
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
        for (peer, state) in sync.peers.sorted(by: { $0.key < $1.key }) {
            let (due, overflow) = state.askedAt.addingReportingOverflow(config.headersTimeout)
            pump(peer, &turn, again: overflow || now >= due)
        }
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

    /// Everything the entry puts on the wire: a child level's header carries
    /// its proofs, a genesis its spec.
    static func size(of entry: HeaderEntry) -> Int {
        size(of: entry.block) + (entry.children.map(size) ?? 0)
            + entry.proofs.reduce(0) { $0 + ((try? $1.serialize().count) ?? 0) }
            + (entry.spec?.toData()?.count ?? 0)
    }
}
