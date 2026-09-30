import Lattice
import UInt256
import cashew

/// What the shell hands the core. Time is not an event: every `step` takes
/// the shell's `now` (milliseconds since the epoch).
public enum Event: Sendable {
    case peerReady(PeerID)
    case peerGone(PeerID)
    case received(PeerID, SyncMessage)
    /// The answer to `Effect.fetchByCID` for a child index: nil when the peer
    /// did not have it.
    case childIndexFetched(PeerID, cid: String, ChildIndex?)
    /// The shell finished sending the headers a `serveHeaders` effect named.
    case headersServed(PeerID, requestID: UInt64)
    case tick
    /// A child level: the evidence index's proofs for a block
    /// (`Effect.lookupProofs`).
    case proofsFound(childCID: String, [ChildBlockProof])
    /// A child level: a `verifyProof` job finished.
    case proofVerified(ProofJob, Result<VerifiedChildEvidence, ChildProofVerificationFailure>)
    /// A child level: the evidence index changed, so what still waits for a
    /// proof is looked up again.
    case evidenceChanged
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

/// The durable form of one step: header content first, then the facts that
/// reference it. The shell writes it before executing any later effect of
/// the same step.
public struct PersistBatch: Sendable {
    public let headers: [StoredHeader]
    public let facts: [BlockImportBatch]

    public init(headers: [StoredHeader], facts: [BlockImportBatch]) {
        self.headers = headers
        self.facts = facts
    }
}

/// What readers see: the best header tip and the tip a node acts on — the
/// deepest executed block on the best chain.
public struct Snapshot: Sendable, Equatable {
    public let bestHeaderTip: String
    public let bestHeaderHeight: UInt64
    public let actOnTip: String
    public let actOnHeight: UInt64
}

public enum Effect: Sendable {
    case send(PeerID, SyncMessage)
    /// Answer a request with these weighed headers, in order. The shell reads
    /// their content (`CoreConfig.entry` decides what travels inline).
    case serveHeaders(PeerID, requestID: UInt64, blockCIDs: [String], hasMore: Bool)
    case fetchByCID(PeerID, cid: String)
    case disconnect(PeerID, DisconnectReason)
    case persist(PersistBatch)
    case publish(Snapshot)
    case wakeAt(Int64)
    /// A child level: ask the evidence index for these blocks' proofs.
    case lookupProofs([String])
    /// A child level: run `ChildBlockProof.verifySecuringWork`, a pure job,
    /// and answer `proofVerified`.
    case verifyProof(ProofJob)
    /// A child level: write a verified proof to the local evidence index, so
    /// this node serves it. Emitted after the step's `persist`.
    case indexProof(childCID: String, ChildBlockProof)
}

public struct CoreConfig: Sendable {
    public var maxHeadersPerPage: Int
    /// How long any request may stay in flight before its peer is
    /// disconnected as stalled.
    public var headersTimeout: Int64
    public var maxAwaitingChildIndex: Int
    /// A child index larger than this travels by CID instead of inline.
    public var maxInlineChildIndexBytes: Int
    /// The operator's byte budget for headers not yet weighed.
    public var pendingBudget: Int
    /// Child proofs verified at once, and taken from one header.
    public var maxProofChecks: Int
    public var maxProofsPerHeader: Int

    public init(
        maxHeadersPerPage: Int = 2_000,
        headersTimeout: Int64 = 30_000,
        maxAwaitingChildIndex: Int = 64,
        maxInlineChildIndexBytes: Int = 16 * 1_024,
        pendingBudget: Int = 16 * 1_024 * 1_024,
        maxProofChecks: Int = 256,
        maxProofsPerHeader: Int = 8
    ) {
        self.maxHeadersPerPage = maxHeadersPerPage
        self.headersTimeout = headersTimeout
        self.maxAwaitingChildIndex = maxAwaitingChildIndex
        self.maxInlineChildIndexBytes = maxInlineChildIndexBytes
        self.pendingBudget = pendingBudget
        self.maxProofChecks = maxProofChecks
        self.maxProofsPerHeader = maxProofsPerHeader
    }

    /// A header as it travels: its child index inline when it fits.
    public func entry(_ block: Block, children: ChildIndex, proofs: [ChildBlockProof] = []) -> HeaderEntry {
        let fits = (children.toData()?.count ?? .max) <= maxInlineChildIndexBytes
        return HeaderEntry(block: block, children: fits ? children : nil, proofs: proofs)
    }
}

/// The node's state machine for one root level: the chain tree and header
/// sync as values behind one synchronous `step`. No IO, no awaits: every
/// mutation of a step is atomic, and the effects say what the shell must do.
///
/// Sync replicates the level's weighed subgraph. A header is weighed by
/// `insertRootHeader`; every newly weighed header — excluded ones too — is
/// relayed to every other ready peer; an unknown parent is asked by CID of
/// the peer that sent the header; catch-up asks a peer for its weighed
/// headers after ours. Only a proof-of-work failure blames a peer.
public struct Core: Sendable {
    public internal(set) var tree: ChainTree
    public internal(set) var sync = Sync()
    public private(set) var published: Snapshot?
    public let config: CoreConfig
    let genesis: String
    /// The weighed graph's leaves: what a catch-up request names as known.
    var leaves: Set<String>

    /// A core over a bootstrapped or restored root tree.
    public init(tree: ChainTree, config: CoreConfig = CoreConfig()) {
        var tree = tree
        precondition(tree.context != nil, "the core runs one chain's level")
        let genesis = tree.canonicalBlockHash(atHeight: 0) ?? tree.canonicalTip
        var leaves = Set<String>()
        var stack = [genesis]
        while let hash = stack.popLast() {
            guard let meta = tree.getConsensusBlock(hash: hash) else { continue }
            if meta.childHashes.isEmpty { leaves.insert(hash) }
            stack += meta.childHashes
        }
        self.tree = tree
        self.config = config
        self.genesis = genesis
        self.leaves = leaves
    }

    /// Rebuild a core from its durable facts and the chain's genesis spec
    /// (the tree binds it to the genesis and holds it from then on).
    public static func restore(
        replaying facts: [BlockImportBatch],
        context: ChainRuntimeContext,
        spec: ChainSpec,
        config: CoreConfig = CoreConfig()
    ) throws -> Core {
        Core(
            tree: try ChainTree.restore(replaying: facts, context: context, spec: spec),
            config: config
        )
    }

    public var snapshot: Snapshot {
        let actOn = tree.actOnTip()
        return Snapshot(
            bestHeaderTip: tree.canonicalTip,
            bestHeaderHeight: tree.headerSnapshot(of: tree.canonicalTip)?.tipHeight ?? 0,
            actOnTip: actOn.hash,
            actOnHeight: actOn.height
        )
    }

    public mutating func step(_ event: Event, now: Int64) -> [Effect] {
        var turn = Turn(now: now)
        switch event {
        case .peerReady(let peer):
            guard sync.peers[peer] == nil else { break }
            sync.peers[peer] = PeerSync()
            requestCatchUp(from: peer, after: nil, &turn)
        case .peerGone(let peer):
            sync.drop(peer)
        case .received(let peer, let message):
            guard sync.peers[peer] != nil else { break }
            receive(message, from: peer, &turn)
        case .childIndexFetched(let peer, let cid, let index):
            childIndexFetched(index, cid: cid, from: peer, &turn)
        case .headersServed(let peer, let requestID):
            guard sync.peers[peer]?.serving == requestID else { break }
            sync.peers[peer]?.serving = nil
            if let queued = sync.peers[peer]?.queued {
                sync.peers[peer]?.queued = nil
                serve(queued, to: peer, &turn)
            }
        case .tick:
            expireDeadlines(&turn)
        case .proofsFound(let cid, let proofs):
            proofsFound(proofs, for: cid, &turn)
        case .proofVerified(let job, let result):
            proofVerified(job, result, &turn)
        case .evidenceChanged:
            evidenceChanged()
        }
        advance(&turn)
        if !isRoot { requestProofs(&turn) }
        // A full page continues once its headers are weighed, so the next
        // request names them as known.
        for (peer, after) in turn.continuations {
            requestCatchUp(from: peer, after: after, &turn)
        }
        return finish(turn)
    }

    // MARK: - Step bookkeeping

    /// What one step produced, in order.
    struct Turn {
        let now: Int64
        var headers: [StoredHeader] = []
        var facts: [BlockImportBatch] = []
        var effects: [Effect] = []
        /// Headers this step weighed, and the peer each came from (nil for
        /// this node's own grinds and the evidence index's proofs).
        var relays: [(entry: HeaderEntry, from: PeerID?)] = []
        /// Child proofs this step verified and credited, to index.
        var indexed: [(childCID: String, proof: ChildBlockProof)] = []
        /// Catch-up pages to continue, after the given header.
        var continuations: [(PeerID, HeaderKey)] = []
    }

    /// Persist first, then publish, then relay, then everything else:
    /// nothing a step makes visible precedes the write that makes it durable.
    mutating func finish(_ turn: Turn) -> [Effect] {
        var effects: [Effect] = []
        if !turn.facts.isEmpty {
            effects.append(.persist(PersistBatch(headers: turn.headers, facts: turn.facts)))
        }
        effects += turn.indexed.map { .indexProof(childCID: $0.childCID, $0.proof) }
        let current = snapshot
        if current != published {
            published = current
            effects.append(.publish(current))
        }
        // Relay every newly weighed header to every ready peer but its
        // source. Relaying a header is not acting on its weight: only tip
        // announces and templates act, and they come from the executed tip.
        for peer in sync.peers.keys.sorted() {
            let entries = turn.relays.filter { $0.from != peer }.map(\.entry)
            if !entries.isEmpty {
                effects.append(.send(peer, .headers(HeadersResponse(
                    requestID: 0, entries: entries, hasMore: false
                ))))
            }
        }
        effects += turn.effects
        if let deadline = sync.nextDeadline(after: turn.now) {
            effects.append(.wakeAt(deadline))
        }
        return effects
    }

    mutating func disconnect(_ peer: PeerID, _ reason: DisconnectReason, _ turn: inout Turn) {
        sync.drop(peer)
        turn.effects.append(.disconnect(peer, reason))
    }

    private mutating func nextRequestID() -> UInt64 {
        defer { sync.nextRequestID += 1 }
        return sync.nextRequestID
    }

    // MARK: - Serving

    private mutating func receive(_ message: SyncMessage, from peer: PeerID, _ turn: inout Turn) {
        switch message {
        case .getHeaders(let request):
            serve(request, to: peer, &turn)
        case .getHeader(let requestID, let cid):
            let held = cid != genesis && tree.contains(blockHash: cid)
            turn.effects.append(.serveHeaders(
                peer, requestID: requestID, blockCIDs: held ? [cid] : [], hasMore: false
            ))
        case .headers(let response):
            receive(response, from: peer, &turn)
        }
    }

    /// Serve every weighed header that is neither known to the requester nor
    /// an ancestor of a known one, in `HeaderKey` order after the request's
    /// cursor, one page at a time per peer (a request that arrives while a
    /// page is still being sent waits for it).
    private mutating func serve(_ request: HeadersRequest, to peer: PeerID, _ turn: inout Turn) {
        guard request.known.count <= HeadersRequest.maximumKnown else { return }
        guard sync.peers[peer]?.serving == nil else {
            sync.peers[peer]?.queued = request
            return
        }
        var skip: Set<String> = [genesis]
        for known in request.known where tree.contains(blockHash: known) {
            var cursor: String? = known
            while let hash = cursor, skip.insert(hash).inserted {
                cursor = tree.getConsensusBlock(hash: hash)?.parentBlockHash
            }
        }
        var keys: [HeaderKey] = []
        var stack = [genesis]
        while let hash = stack.popLast() {
            guard let meta = tree.getConsensusBlock(hash: hash) else { continue }
            stack += meta.childHashes
            let key = HeaderKey(height: meta.blockHeight, cid: hash)
            if !skip.contains(hash), request.after.map({ key > $0 }) ?? true {
                keys.append(key)
            }
        }
        keys.sort()
        let page = keys.prefix(config.maxHeadersPerPage)
        sync.peers[peer]?.serving = request.requestID
        turn.effects.append(.serveHeaders(
            peer,
            requestID: request.requestID,
            blockCIDs: page.map(\.cid),
            hasMore: keys.count > page.count
        ))
    }

    // MARK: - Catch-up

    /// Ask `peer` for its weighed headers after our leaves (the highest
    /// first, up to the request's bound), continuing after `after`.
    private mutating func requestCatchUp(from peer: PeerID, after: HeaderKey?, _ turn: inout Turn) {
        guard let state = sync.peers[peer], state.catchUp == nil else { return }
        let tree = self.tree
        let known = leaves
            .map { HeaderKey(height: tree.headerSnapshot(of: $0)?.tipHeight ?? 0, cid: $0) }
            .sorted { $0 > $1 }
            .prefix(HeadersRequest.maximumKnown)
            .map(\.cid)
        let requestID = nextRequestID()
        sync.peers[peer]?.catchUp = InFlightPage(
            requestID: requestID, after: after, deadline: turn.now + config.headersTimeout
        )
        turn.effects.append(.send(peer, .getHeaders(HeadersRequest(
            requestID: requestID, known: known, after: after
        ))))
    }

    /// Headers from `peer`: a relay, a catch-up page, or the parent asked of
    /// it. All take the same path; only a page continues.
    private mutating func receive(_ response: HeadersResponse, from peer: PeerID, _ turn: inout Turn) {
        var page: InFlightPage?
        if response.requestID != 0 {
            if let inFlight = sync.peers[peer]?.catchUp, inFlight.requestID == response.requestID {
                sync.peers[peer]?.catchUp = nil
                page = inFlight
            } else if sync.peers[peer]?.parentRequest?.requestID == response.requestID {
                sync.peers[peer]?.parentRequest = nil
            } else {
                return
            }
        }
        var last: HeaderKey?
        for entry in response.entries {
            guard let cid = accept(entry, from: peer, &turn) else { return }
            last = HeaderKey(height: entry.block.height, cid: cid)
        }
        // The cursor only climbs, so a page that repeats itself ends here.
        if let page, response.hasMore, let last, page.after.map({ last > $0 }) ?? true {
            turn.continuations.append((peer, last))
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
        if tree.contains(blockHash: cid) {
            if !isRoot { offerProofs(entry.proofs, for: entry.block, cid: cid, &turn) }
            return cid
        }
        // Structural, never blame: an inline child index that is not the one
        // the block commits, or a genesis (only bootstrap admits one).
        if let children = entry.children, Self.cid(of: children) != entry.block.children.rawCID {
            return cid
        }
        guard entry.block.parent != nil else { return cid }
        if !isRoot, sync.pending.entries[cid] != nil {
            offerProofs(entry.proofs, for: entry.block, cid: cid, &turn)
        }
        if let held = sync.pending.entries[cid] {
            if let children = entry.children {
                sync.pending.setChildren(children, of: cid, bytes: Self.size(of: children))
            }
            if sync.peers[held.source] == nil {
                sync.pending.entries[cid]?.source = peer
                sync.pending.entries[cid]?.askedParent = false
            }
            return cid
        }
        // A root header proves its own work now; a child header's work is
        // its proofs', verified off the step.
        guard !isRoot || ChainTree.rootWork(of: entry.block) != nil else {
            disconnect(peer, .proofOfWorkInvalid, &turn)
            return nil
        }
        let header = PendingHeader(
            blockCID: cid,
            block: entry.block,
            children: entry.children,
            hash: isRoot ? entry.block.proofOfWorkHash() : .max,
            bytes: Self.size(of: entry.block) + (entry.children.map(Self.size) ?? 0),
            source: peer
        )
        // A header that can be weighed now is, so a page that links never
        // waits in (or is evicted from) the pending queue.
        sync.pending.insert(header)
        if !isRoot { offerProofs(entry.proofs, for: entry.block, cid: cid, &turn) }
        if isReady(header, turn.now) {
            _ = insert(header, &turn)
        } else {
            sync.pending.evict(to: config.pendingBudget)
        }
        return sync.peers[peer] == nil ? nil : cid
    }

    /// Weigh every pending header whose parent is weighed, smallest priority
    /// first (each weighed header readies its pending children), then ask
    /// for what the rest lack: a child index of the peer that sent the
    /// header, or its unknown parent.
    mutating func advance(_ turn: inout Turn) {
        guard !sync.pending.entries.isEmpty else { return }
        let priority = sync.pending.priorities()
        let before: (String, String) -> Bool = { a, b in
            let (pa, pb) = (priority[a] ?? .max, priority[b] ?? .max)
            return pa != pb ? pa < pb : a < b
        }
        var childrenOf: [String: [String]] = [:]
        for header in sync.pending.entries.values {
            if let parent = header.parent { childrenOf[parent, default: []].append(header.blockCID) }
        }
        var ready = sync.pending.entries.values.filter { isReady($0, turn.now) }.map(\.blockCID)
        while !ready.isEmpty {
            ready.sort { before($1, $0) }
            let cid = ready.removeLast()
            guard let header = sync.pending.entries[cid], isReady(header, turn.now) else { continue }
            if insert(header, &turn) {
                ready += (childrenOf[cid] ?? []).filter {
                    sync.pending.entries[$0].map { isReady($0, turn.now) } ?? false
                }
            }
        }
        for cid in sync.pending.entries.keys.sorted(by: before) {
            guard let header = sync.pending.entries[cid], sync.peers[header.source] != nil,
                  let parent = header.parent else { continue }
            if tree.contains(blockHash: parent) {
                if header.children == nil { awaitChildIndex(of: header, &turn) }
            } else if sync.pending.entries[parent] == nil, !header.askedParent,
                      sync.peers[header.source]?.parentRequest == nil {
                let requestID = nextRequestID()
                sync.peers[header.source]?.parentRequest = InFlightHeader(
                    requestID: requestID, cid: parent, deadline: turn.now + config.headersTimeout
                )
                sync.pending.entries[cid]?.askedParent = true
                turn.effects.append(.send(header.source, .getHeader(requestID: requestID, cid: parent)))
            }
        }
    }

    private func isReady(_ header: PendingHeader, _ now: Int64) -> Bool {
        header.children != nil && (header.notBefore ?? .min) <= now
            && header.parent.map { tree.contains(blockHash: $0) } == true
            && (isRoot || !header.evidence.isEmpty)
    }

    /// Weigh one header. Only `.proofOfWorkInvalid` blames its source (for a
    /// child header, only with a proof that weighs, so the failure is the
    /// header's own); a header from this node's future waits for its time;
    /// anything else is dropped. Returns whether the header is now weighed.
    mutating func insert(_ header: PendingHeader, _ turn: inout Turn) -> Bool {
        guard let children = header.children else { return false }
        let context = ValidationContext(nowMilliseconds: turn.now)
        let admission = isRoot
            ? tree.insertRootHeader(header.block, childIndex: children, validationContext: context)
            : insertChildHeader(header, children: children, context)
        switch admission {
        case .applied(let update):
            sync.pending.remove(header.blockCID)
            turn.headers.append(StoredHeader(blockCID: header.blockCID, block: header.block, children: children))
            turn.facts += update.batches
            if let parent = header.parent { leaves.remove(parent) }
            leaves.insert(header.blockCID)
            let proofs = creditRemainingProofs(of: header, &turn)
            turn.relays.append((config.entry(header.block, children: children, proofs: proofs), from: header.source))
            return true
        case .duplicate:
            sync.pending.remove(header.blockCID)
            return true
        case .rejected(.proofOfWorkInvalid):
            sync.pending.remove(header.blockCID)
            if sync.peers[header.source] != nil {
                disconnect(header.source, .proofOfWorkInvalid, &turn)
            }
        case .rejected(.notYetValid) where header.block.timestamp > turn.now:
            sync.pending.entries[header.blockCID]?.notBefore = header.block.timestamp
        case .rejected:
            sync.pending.remove(header.blockCID)
        }
        return false
    }

    // MARK: - Child indexes

    /// Fetch a header's child index from the peer that sent the header: one
    /// wait per peer and per CID, up to `maxAwaitingChildIndex`. A taken slot
    /// is tried again on a later step.
    private mutating func awaitChildIndex(of header: PendingHeader, _ turn: inout Turn) {
        let cid = header.block.children.rawCID
        guard sync.awaitingChildIndex[cid] == nil,
              sync.awaitingChildIndex.count < config.maxAwaitingChildIndex,
              !sync.awaitingChildIndex.values.contains(where: { $0.peer == header.source }) else { return }
        sync.awaitingChildIndex[cid] = AwaitingChildIndex(
            peer: header.source, deadline: turn.now + config.headersTimeout
        )
        turn.effects.append(.fetchByCID(header.source, cid: cid))
    }

    private mutating func childIndexFetched(
        _ index: ChildIndex?,
        cid: String,
        from peer: PeerID,
        _ turn: inout Turn
    ) {
        guard let waiting = sync.awaitingChildIndex[cid], waiting.peer == peer else { return }
        sync.awaitingChildIndex[cid] = nil
        let committing = sync.pending.entries.values.filter { $0.block.children.rawCID == cid }
        guard let index else {
            // The peer lacks what its own header commits: drop that header,
            // never blame.
            for header in committing where header.source == peer {
                sync.pending.remove(header.blockCID)
            }
            return
        }
        guard Self.cid(of: index) == cid else {
            disconnect(peer, .proofOfWorkInvalid, &turn)
            return
        }
        for header in committing {
            sync.pending.setChildren(index, of: header.blockCID, bytes: Self.size(of: index))
        }
        sync.pending.evict(to: config.pendingBudget)
    }

    // MARK: - Deadlines

    /// A peer whose request passed its deadline is stalling: disconnect it
    /// to free the slot. Never a ban.
    private mutating func expireDeadlines(_ turn: inout Turn) {
        let now = turn.now
        var stalled = Set(sync.awaitingChildIndex.values.filter { $0.deadline <= now }.map(\.peer))
        for (peer, state) in sync.peers {
            let deadlines = [state.catchUp?.deadline, state.parentRequest?.deadline].compactMap { $0 }
            if deadlines.contains(where: { $0 <= now }) { stalled.insert(peer) }
        }
        for peer in stalled.sorted() where sync.peers[peer] != nil {
            disconnect(peer, .stalled, &turn)
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
}
