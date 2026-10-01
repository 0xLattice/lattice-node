import Lattice
import UInt256
import cashew

/// What the shell hands the core. Time is not an event: every `step` takes
/// the shell's `now` (milliseconds since the epoch).
public enum Event: Sendable {
    case peerReady(PeerID)
    case peerGone(PeerID)
    case received(PeerID, SyncMessage)
    /// The answer to `Effect.fetchByCID` for a child index: nil ONLY when the
    /// peer definitively does not hold it. A transport failure is no event
    /// (the request's deadline decides).
    case childIndexFetched(PeerID, cid: String, ChildIndex?)
    /// The shell finished sending the answer a `serveHeaders` effect named.
    case headersServed(PeerID, token: UInt64)
    /// The content layer holds the body Volume of this block locally.
    case bodyFetched(cid: String)
    /// A connect job's verdict.
    case connected(ConnectVerdict)
    case tick
    /// A child level: the evidence index's proofs for a block
    /// (`Effect.lookupProofs`).
    case proofsFound(childCID: String, [ChildBlockProof])
    /// A child level: a `verifyProof` job finished.
    case proofVerified(ProofJob, Result<VerifiedChildEvidence, ChildProofVerificationFailure>)
    /// A child level: the evidence index's proofs changed for these blocks.
    case evidenceChanged(childCIDs: [String])
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
/// the facts that reference it, with the child-genesis links those
/// executions issued, committed. The shell writes it before executing any
/// later effect of the same step. Facts durable without their content is an
/// ordering violation the shell must prevent: a crash may lose the facts of
/// durable content, never the reverse.
public struct PersistBatch: Sendable {
    public let headers: [StoredHeader]
    /// Each executed block's materialized post-state: the state content a
    /// later execution resolves, written before the validation that
    /// references it.
    public let states: [LatticeState]
    public let facts: [BlockImportBatch]
    /// The child-genesis links this step's executions issued, each with the
    /// block that issued it.
    public let genesisLinks: [IssuedGenesisLink]
    /// The entries this step appended to the weigh log, in order: durable
    /// with the facts that weigh them.
    public let log: [LogEntry]

    public init(
        headers: [StoredHeader],
        states: [LatticeState] = [],
        facts: [BlockImportBatch],
        genesisLinks: [IssuedGenesisLink] = [],
        log: [LogEntry] = []
    ) {
        self.headers = headers
        self.states = states
        self.facts = facts
        self.genesisLinks = genesisLinks
        self.log = log
    }
}

/// A child-genesis link and the executed block whose `GenesisAction`
/// authorized it: the link authorizes only while that block is executed.
public struct IssuedGenesisLink: Sendable, Equatable {
    public let link: ParentGenesisLink
    public let issuer: String

    public init(link: ParentGenesisLink, issuer: String) {
        self.link = link
        self.issuer = issuer
    }
}

public enum Effect: Sendable {
    case send(PeerID, SyncMessage)
    /// Answer request `requestID` with these weighed headers, in order, then
    /// report `headersServed(peer, token:)`. The shell reads their content
    /// and caps the answer by bytes (`CoreConfig.page`).
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
    case persist(PersistBatch)
    case publish(Snapshot)
    case wakeAt(Int64)
    /// A child level: ask the evidence index for these blocks' proofs.
    case lookupProofs([String])
    /// A child level: run `ChildBlockProof.verifySecuringWork`, a pure job,
    /// and answer `proofVerified`.
    case verifyProof(ProofJob)
    /// A child level: write a credited proof to the local evidence index, so
    /// this node serves it. Emitted after the step's `persist`.
    case indexProof(childCID: String, ChildBlockProof)
}

public struct CoreConfig: Sendable {
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
    public var proofs = ProofConfig()
    /// How many weighed-but-unexecuted blocks of the best chain, after the
    /// act-on tip, have their bodies asked for at once.
    public var bodyWindow: Int
    /// A connect with no verdict (its content was not resolvable) waits this
    /// long before its body is asked for again, doubling per attempt up to
    /// `bodyRetryCap`, and starting over whenever the act-on tip or the
    /// window changes.
    public var bodyRetryBase: Int64
    public var bodyRetryCap: Int64

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

    /// A header as it travels: its child index inline when it fits.
    public func entry(_ block: Block, children: ChildIndex, proofs: [ChildBlockProof] = []) -> HeaderEntry {
        let fits = (children.toData()?.count ?? .max) <= maxInlineChildIndexBytes
        return HeaderEntry(block: block, children: fits ? children : nil, proofs: proofs)
    }

    /// The answer the shell sends: `entries` cut at `maxPageBytes` (at least
    /// one), with `hasMore` set when cut. The requester continues after the
    /// last header it receives.
    public func page(_ entries: [HeaderEntry], hasMore: Bool) -> (entries: [HeaderEntry], hasMore: Bool) {
        var total = 0
        for (index, entry) in entries.enumerated() {
            total += Core.size(of: entry)
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
/// Sync replicates the level's weighed subgraph as a stream of weigh logs.
/// Every weighed object (a header, or a credited proof) — excluded ones too —
/// is appended to this node's log in weigh order. Each peer reads our log
/// from where it left off, as pages of IDs, and then receives what we append
/// as we append it: one mechanism for catch-up and relay. A node fetches only
/// the objects it lacks (`getData`) and verifies each on arrival; an unknown
/// parent is fetched with its ancestors from a peer that sent the header.
/// Sync never reads canonicity. Only a proof-of-work failure blames a peer.
///
/// Bodies (`Bodies.swift`) are fetched by CID through the content layer and
/// connected in parent order along the best chain; a missing body is an
/// availability wait, never blame.
public struct Core: Sendable {
    public internal(set) var tree: ChainTree
    public internal(set) var sync = Sync()
    public internal(set) var bodies = Bodies()
    public private(set) var published: Snapshot?
    public let config: CoreConfig
    public let genesis: String
    public internal(set) var index = WeighedIndex()

    /// A core over a bootstrapped or restored tree, with the weigh log and
    /// the per-peer stream cursors the shell persisted. A node whose store
    /// resets passes a new log id.
    public init(
        tree: ChainTree,
        config: CoreConfig = CoreConfig(),
        log: WeighLog = WeighLog(),
        cursors: [String: StreamCursor] = [:]
    ) {
        var tree = tree
        precondition(tree.context != nil, "the core runs one chain's level")
        let genesis = Self.genesis(of: tree)
        var index = WeighedIndex()
        var stack = [genesis]
        while let hash = stack.popLast() {
            guard let meta = tree.getConsensusBlock(hash: hash) else { continue }
            index.add(hash, parent: meta.parentBlockHash)
            stack += meta.childHashes
        }
        self.tree = tree
        self.config = config
        self.genesis = genesis
        self.index = index
        self.sync.log = log
        self.sync.cursors = cursors
    }

    /// Rebuild a core from its durable facts and the chain's genesis spec
    /// (the tree binds it to the genesis and holds it from then on).
    public static func restore(
        replaying facts: [BlockImportBatch],
        context: ChainRuntimeContext,
        spec: ChainSpec,
        config: CoreConfig = CoreConfig(),
        log: WeighLog = WeighLog(),
        cursors: [String: StreamCursor] = [:]
    ) throws -> Core {
        Core(
            tree: try ChainTree.restore(replaying: facts, context: context, spec: spec),
            config: config,
            log: log,
            cursors: cursors
        )
    }

    public mutating func step(_ event: Event, now: Int64) -> [Effect] {
        var turn = Turn(now: now)
        switch event {
        case .peerReady(let peer):
            guard sync.peers[peer] == nil else { break }
            sync.peers[peer] = PeerSync()
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
        case .connected(let verdict):
            connected(verdict, &turn)
        case .tick:
            tick(&turn)
        case .proofsFound(let cid, let proofs):
            proofsFound(proofs, for: cid, &turn)
        case .proofVerified(let job, let result):
            proofVerified(job, result, &turn)
        case .evidenceChanged(let cids):
            evidenceChanged(cids)
        }
        drain(&turn)
        if !isRoot { proofWork(&turn) }
        // Evict once the step's headers are processed, so a header held for
        // its future timestamp is already in the first eviction tier.
        sync.evict(to: config.pendingBudget)
        for peer in sync.peers.keys.sorted() where sync.peers[peer]?.holes.isEmpty == false {
            advanceCursor(of: peer)
        }
        scheduleBodies(&turn)
        return finish(turn)
    }

    // MARK: - Step bookkeeping

    /// What one step produced, in order.
    struct Turn {
        let now: Int64
        var headers: [StoredHeader] = []
        var states: [LatticeState] = []
        var facts: [BlockImportBatch] = []
        var genesisLinks: [IssuedGenesisLink] = []
        var effects: [Effect] = []
        /// Child proofs this step credited, to index.
        var indexed: [(childCID: String, proof: ChildBlockProof)] = []
        /// Pending headers to look at again, smallest priority first.
        var dirty = Heap<(priority: UInt256, cid: String)> {
            $0.priority != $1.priority ? $0.priority < $1.priority : $0.cid < $1.cid
        }

        init(now: Int64) { self.now = now }
    }

    /// Persist first, then publish, then push, then everything else:
    /// nothing a step makes visible precedes the write that makes it durable.
    mutating func finish(_ turn: Turn) -> [Effect] {
        var effects: [Effect] = []
        // Each header this step weighed, then each proof it credited: a
        // header precedes its proofs, a parent its children.
        let start = sync.log.count
        for header in turn.headers { sync.log.append(.header(header.blockCID)) }
        for (cid, proof) in turn.indexed {
            if let id = ProofJob.id(of: proof) { sync.log.append(.proof(id, of: cid)) }
        }
        let appended = sync.log.page(after: start, limit: .max).entries
        if !turn.facts.isEmpty || !appended.isEmpty {
            effects.append(.persist(PersistBatch(
                headers: turn.headers, states: turn.states, facts: turn.facts, genesisLinks: turn.genesisLinks,
                log: appended.map(\.entry)
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
        if !appended.isEmpty {
            for peer in sync.peers.keys.sorted() where sync.peers[peer]?.subscribed == true {
                effects.append(.send(peer, .stream(StreamPage(
                    requestID: 0, logID: sync.log.id, entries: appended, hasMore: false
                ))))
            }
        }
        effects += turn.effects
        sync.compact()
        let deadlines = [sync.nextDeadline(after: turn.now), bodies.nextRetry(after: turn.now)]
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

    private mutating func receive(_ message: SyncMessage, from peer: PeerID, _ turn: inout Turn) {
        switch message {
        case .getStream(let id, let logID, let after):
            serveStream(id, logID: logID, after: after, to: peer, &turn)
        case .getData, .getAncestors:
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

    /// A page of our log after `after` (from 0 if the peer's log id is not
    /// ours), IDs only, answered from memory: at most a page. A page that
    /// reaches the end subscribes the peer to what we append.
    mutating func serveStream(_ requestID: UInt64, logID: String?, after: UInt64, to peer: PeerID, _ turn: inout Turn) {
        let from = logID == sync.log.id ? after : 0
        let page = sync.log.page(after: from, limit: config.maxHeadersPerPage)
        sync.lastServeScanned = page.entries.count
        sync.peers[peer]?.subscribed = !page.hasMore
        turn.effects.append(.send(peer, .stream(StreamPage(
            requestID: requestID, logID: sync.log.id, entries: page.entries, hasMore: page.hasMore
        ))))
    }

    /// Answer one content request through the peer's serving slot: the
    /// shell reads the headers (with their proofs) and caps them by bytes.
    private mutating func serve(_ message: SyncMessage, to peer: PeerID, _ turn: inout Turn) {
        let requestID: UInt64
        let cids: [String]
        switch message {
        case .getAncestors(let id, let cid, let max):
            requestID = id
            cids = ancestors(of: cid, max: max)
        case .getData(let id, let asked):
            requestID = id
            var seen = Set<String>()
            cids = asked.prefix(config.maxHeadersPerPage)
                .filter { $0 != genesis && index.contains($0) && seen.insert($0).inserted }
        case .getStream, .stream, .headers:
            return
        }
        let token = sync.nextToken
        sync.nextToken += 1
        sync.peers[peer]?.serving = token
        turn.effects.append(.serveHeaders(
            peer, token: token, requestID: requestID, blockCIDs: cids, hasMore: false
        ))
    }

    /// The weighed header `cid` and up to `max` of its ancestors (capped by
    /// the page), child to parent, stopping above genesis: one parent step
    /// each.
    func ancestors(of cid: String, max: Int) -> [String] {
        guard cid != genesis, index.contains(cid) else { return [] }
        var cids = [cid]
        var current = cid
        let limit = Swift.min(Swift.max(max, 0), config.maxHeadersPerPage)
        while cids.count <= limit, let parent = index.parent[current], parent != genesis {
            cids.append(parent)
            current = parent
        }
        return cids
    }

    // MARK: - Streams

    /// Ask `peer` for its log after our cursor in it (a fresh peer: 0).
    private mutating func requestStream(from peer: PeerID, _ turn: inout Turn) {
        guard let state = sync.peers[peer], state.stream == nil else { return }
        let cursor = sync.cursors[peer.key]
        // Within a session, after what was taken; a new session resumes at
        // the cursor (before anything not yet applied).
        let after = state.inventory.last?.position ?? Swift.max(state.through, cursor?.position ?? 0)
        let requestID = nextRequestID()
        sync.peers[peer]?.stream = InFlightStream(requestID: requestID, deadline: turn.now + config.headersTimeout)
        sync.peers[peer]?.more = false
        turn.effects.append(.send(peer, .getStream(requestID: requestID, logID: cursor?.logID, after: after)))
    }

    /// A page of `peer`'s log, asked or pushed. A log id that is not the
    /// cursor's means the peer's log reset: start over from 0. Entries are
    /// taken in order from the next position; a gap ends the page (the next
    /// request fills it).
    private mutating func receive(_ page: StreamPage, from peer: PeerID, _ turn: inout Turn) {
        guard let state = sync.peers[peer] else { return }
        if page.requestID != 0 {
            guard state.stream?.requestID == page.requestID else { return }
            sync.peers[peer]?.stream = nil
            sync.peers[peer]?.more = page.hasMore
        } else if sync.cursors[peer.key]?.logID != page.logID || state.stream != nil {
            return
        }
        if sync.cursors[peer.key]?.logID != page.logID {
            sync.cursors[peer.key] = StreamCursor(logID: page.logID, position: 0)
            sync.peers[peer]?.inventory = []
            sync.peers[peer]?.holes = []
            sync.peers[peer]?.through = 0
        }
        var next = (sync.peers[peer]?.inventory.last?.position
            ?? Swift.max(sync.peers[peer]?.through ?? 0, sync.cursors[peer.key]?.position ?? 0)) + 1
        for entry in page.entries where entry.position >= next {
            guard entry.position == next else {
                sync.peers[peer]?.more = true
                break
            }
            sync.peers[peer]?.inventory.append(entry)
            next += 1
        }
        pump(peer, &turn)
    }

    /// Whether a logged object is applied here: a header weighed, a proof
    /// credited (logged).
    func applied(_ entry: LogEntry) -> Bool {
        entry.kind == .header ? index.contains(entry.block) : sync.log.contains(entry)
    }

    /// The cursor in `peer`'s log: before its first entry not yet applied,
    /// else through the last taken.
    mutating func advanceCursor(of peer: PeerID) {
        guard let state = sync.peers[peer], let logID = sync.cursors[peer.key]?.logID else { return }
        let holes = state.holes.filter { !applied($0.entry) }
        sync.peers[peer]?.holes = holes
        sync.cursors[peer.key] = StreamCursor(logID: logID, position: holes.first.map { $0.position - 1 } ?? state.through)
    }

    /// Whether this node lacks a logged object.
    func lacks(_ entry: LogEntry) -> Bool {
        switch entry.kind {
        case .header:
            return !index.contains(entry.block) && sync.pending.entries[entry.block] == nil
                && sync.proofs.awaiting[entry.block] == nil
        case .proof:
            let key = ProofKey(childCID: entry.block, proofID: entry.cid)
            return !sync.log.contains(entry) && sync.proofs.verifying[key] == nil
                && !sync.proofs.queued.contains { $0.key == key }
        }
    }

    /// Take `peer`'s inventory in order, a batch at a time: what this node
    /// lacks is asked for (one `getData` at a time); a header it holds but
    /// has not weighed gains the peer as an announcer (the peer holds its
    /// ancestors). A drained inventory asks for the next page.
    private mutating func pump(_ peer: PeerID, _ turn: inout Turn) {
        while let state = sync.peers[peer], state.data == nil {
            guard !state.inventory.isEmpty, sync.cursors[peer.key] != nil else {
                if state.more { requestStream(from: peer, &turn) }
                return
            }
            let batch = state.inventory.prefix(config.maxHeadersPerPage)
            sync.peers[peer]?.inventory.removeFirst(batch.count)
            sync.peers[peer]?.through = batch.last?.position ?? state.through
            var seen = Set<String>()
            var cids: [String] = []
            for item in batch where !applied(item.entry) {
                sync.peers[peer]?.holes.append(item)
                if lacks(item.entry) {
                    if seen.insert(item.entry.block).inserted { cids.append(item.entry.block) }
                } else if item.entry.kind == .header, sync.pending.entries[item.entry.block] != nil {
                    announce(item.entry.block, by: peer, &turn)
                }
            }
            advanceCursor(of: peer)
            guard !cids.isEmpty else { continue }
            requestData(cids, from: peer, &turn)
        }
    }

    private mutating func requestData(_ cids: [String], from peer: PeerID, _ turn: inout Turn) {
        let requestID = nextRequestID()
        sync.peers[peer]?.data = InFlightData(
            requestID: requestID, cids: cids, deadline: turn.now + config.headersTimeout
        )
        turn.effects.append(.send(peer, .getData(requestID: requestID, cids: cids)))
    }

    /// Headers from `peer`: the objects asked of it, the ancestors asked of
    /// it (child to parent, taken parent first), or unsolicited. All take
    /// the same path. An answer cut short is asked again for the rest.
    private mutating func receive(_ response: HeadersResponse, from peer: PeerID, _ turn: inout Turn) {
        var data: InFlightData?
        var answeredParent = false
        var asked: String?
        if response.requestID != 0 {
            if let inFlight = sync.peers[peer]?.data, inFlight.requestID == response.requestID {
                sync.peers[peer]?.data = nil
                data = inFlight
            } else if let request = sync.peers[peer]?.parentRequest, request.requestID == response.requestID {
                sync.peers[peer]?.parentRequest = nil
                answeredParent = true
                asked = request.cid
            } else {
                return
            }
        }
        var received = Set<String>()
        for entry in answeredParent ? response.entries.reversed() : response.entries {
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
        if answeredParent { nextWant(of: peer, parent: true, &turn) }
        if let data {
            let rest = data.cids.filter { !received.contains($0) }
            if !rest.isEmpty, !received.isEmpty {
                requestData(rest, from: peer, &turn)
            } else {
                advanceCursor(of: peer)
                pump(peer, &turn)
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
        // Structural, never blame: an inline child index that is not the one
        // the block commits, or a genesis (only bootstrap admits one).
        if let children = entry.children, Self.cid(of: children) != entry.block.children.rawCID {
            return cid
        }
        guard entry.block.parent != nil else { return cid }
        let (horizon, overflow) = turn.now.addingReportingOverflow(config.maxFutureDrift)
        if !overflow, entry.block.timestamp > horizon { return cid }
        if let held = sync.pending.entries[cid] {
            announce(cid, by: peer, &turn)
            if let children = entry.children, held.children == nil {
                sync.pending.setChildren(children, of: cid, bytes: Self.size(of: children))
            }
            if !isRoot { offer(entry.proofs, cid: cid, from: peer) }
            dirty(cid, &turn)
            return cid
        }
        // A child header's work is its proofs': it waits apart until one
        // verifies (see `ChildHeaders.swift`).
        if !isRoot {
            awaitProof(entry, cid: cid, from: peer, &turn)
            return cid
        }
        guard ChainTree.rootWork(of: entry.block) != nil else {
            disconnect(peer, .proofOfWorkInvalid, &turn)
            return nil
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
        guard let header = sync.pending.entries[cid], let parent = header.parent else { return }
        if let time = header.notBefore, time > turn.now { return }
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
        guard let parentHash = header.parent, let parent = tree.headerSnapshot(of: parentHash),
              let spec = tree.spec else { return false }
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
            turn.headers.append(StoredHeader(blockCID: cid, block: header.block, children: children))
            turn.facts += update.batches
            index.add(cid, parent: header.parent)
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
        func free(_ core: Core) -> Bool {
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
        _ index: ChildIndex?,
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
        while let first = sync.held.first, first.time <= now {
            _ = sync.held.pop()
            if sync.pending.entries[first.cid]?.notBefore == first.time {
                sync.pending.entries[first.cid]?.notBefore = nil
                dirty(first.cid, &turn)
            }
        }
    }

    // MARK: - Content

    static func cid(of index: ChildIndex) -> String? {
        try? HeaderImpl<ChildIndex>(node: index).rawCID
    }

    static func size(of block: Block) -> Int {
        block.toData()?.count ?? 0
    }

    static func size(of index: ChildIndex) -> Int {
        index.toData()?.count ?? 0
    }

    static func size(of entry: HeaderEntry) -> Int {
        size(of: entry.block) + (entry.children.map(size) ?? 0)
    }
}
