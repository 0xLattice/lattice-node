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
    case tick
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
    /// Answer request `requestID` with these weighed headers, in order, then
    /// report `headersServed(peer, token:)`. The shell reads their content
    /// and caps the answer by bytes (`CoreConfig.page`).
    case serveHeaders(PeerID, token: UInt64, requestID: UInt64, blockCIDs: [String], hasMore: Bool)
    case fetchByCID(PeerID, cid: String)
    case disconnect(PeerID, DisconnectReason)
    case persist(PersistBatch)
    case publish(Snapshot)
    case wakeAt(Int64)
}

public struct CoreConfig: Sendable {
    public var maxHeadersPerPage: Int
    /// A served page stops before this many bytes (always at least one
    /// header).
    public var maxPageBytes: Int
    /// How long any request may wait for its answer before its peer is
    /// disconnected as stalled. Each page is its own request, so a catch-up
    /// that keeps delivering never times out.
    public var headersTimeout: Int64
    /// A child index larger than this travels by CID instead of inline.
    public var maxInlineChildIndexBytes: Int
    /// The operator's byte budget for headers not yet connected.
    public var pendingBudget: Int
    /// How far below the fork point a catch-up also serves side branches:
    /// a side block the requester missed while a link was down forks just
    /// below its tip, where FindFork alone would never reach it.
    public var sideBranchWindow: UInt64
    /// A header dated more than this beyond now is dropped (never blamed)
    /// instead of held: Bitcoin's two hours.
    public var maxFutureDrift: Int64
    /// How often each peer is asked for a catch-up again: the repair path
    /// for anything a relay missed.
    public var catchUpInterval: Int64

    public init(
        maxHeadersPerPage: Int = 2_000,
        maxPageBytes: Int = 1 << 20,
        headersTimeout: Int64 = 30_000,
        maxInlineChildIndexBytes: Int = 16 * 1_024,
        pendingBudget: Int = 16 * 1_024 * 1_024,
        sideBranchWindow: UInt64 = 144,
        catchUpInterval: Int64 = 600_000,
        maxFutureDrift: Int64 = 2 * 60 * 60 * 1_000
    ) {
        self.maxFutureDrift = maxFutureDrift
        self.sideBranchWindow = sideBranchWindow
        self.maxHeadersPerPage = maxHeadersPerPage
        self.maxPageBytes = maxPageBytes
        self.headersTimeout = headersTimeout
        self.maxInlineChildIndexBytes = maxInlineChildIndexBytes
        self.pendingBudget = pendingBudget
        self.catchUpInterval = catchUpInterval
    }

    /// A header as it travels: its child index inline when it fits.
    public func entry(_ block: Block, children: ChildIndex) -> HeaderEntry {
        let fits = (children.toData()?.count ?? .max) <= maxInlineChildIndexBytes
        return HeaderEntry(block: block, children: fits ? children : nil)
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
/// Sync replicates the level's weighed subgraph. A connected header with
/// valid proof-of-work is weighed at once by `insertRootHeader`;
/// every newly weighed header — excluded ones too — is relayed to every other
/// ready peer; an unknown parent is asked by CID of a peer that sent the
/// header; catch-up asks a peer for its weighed headers after a locator of
/// ours. Only a proof-of-work failure blames a peer.
public struct Core: Sendable {
    public private(set) var tree: ChainTree
    public private(set) var sync = Sync()
    public private(set) var published: Snapshot?
    public let config: CoreConfig
    let genesis: String
    public private(set) var index = WeighedIndex()

    /// A core over a bootstrapped or restored root tree.
    public init(tree: ChainTree, config: CoreConfig = CoreConfig()) {
        var tree = tree
        precondition(tree.context?.isRoot == true, "the core runs one root level")
        let genesis = tree.canonicalBlockHash(atHeight: 0) ?? tree.canonicalTip
        var index = WeighedIndex()
        var stack = [genesis]
        while let hash = stack.popLast() {
            guard let meta = tree.getConsensusBlock(hash: hash) else { continue }
            index.add(hash, parent: meta.parentBlockHash, height: meta.blockHeight)
            stack += meta.childHashes
        }
        self.tree = tree
        self.config = config
        self.genesis = genesis
        self.index = index
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
        case .tick:
            tick(&turn)
        }
        drain(&turn)
        // A full page continues once its headers are processed, so the next
        // locator names them.
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
        /// Headers this step weighed, and the peer each came from.
        var relays: [(entry: HeaderEntry, from: PeerID?)] = []
        /// Catch-up pages to continue, after the given header.
        var continuations: [(PeerID, HeaderKey)] = []
        /// Pending headers to look at again, smallest priority first.
        var dirty = Heap<(priority: UInt256, cid: String)> {
            $0.priority != $1.priority ? $0.priority < $1.priority : $0.cid < $1.cid
        }

        init(now: Int64) { self.now = now }
    }

    /// Persist first, then publish, then relay, then everything else:
    /// nothing a step makes visible precedes the write that makes it durable.
    private mutating func finish(_ turn: Turn) -> [Effect] {
        var effects: [Effect] = []
        if !turn.facts.isEmpty {
            effects.append(.persist(PersistBatch(headers: turn.headers, facts: turn.facts)))
        }
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
        sync.compact()
        if let deadline = sync.nextDeadline(after: turn.now) {
            effects.append(.wakeAt(deadline))
        }
        return effects
    }

    private mutating func disconnect(_ peer: PeerID, _ reason: DisconnectReason, _ turn: inout Turn) {
        guard sync.peers[peer] != nil else { return }
        drop(peer, &turn)
        turn.effects.append(.disconnect(peer, reason))
    }

    /// Forget `peer`. Each pending header it announced moves to its next
    /// live announcer.
    private mutating func drop(_ peer: PeerID, _ turn: inout Turn) {
        guard sync.peers.removeValue(forKey: peer) != nil else { return }
        sync.wants[WantSlot(peer: peer, parent: true)] = nil
        sync.wants[WantSlot(peer: peer, parent: false)] = nil
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

    private func dirty(_ cid: String, _ turn: inout Turn) {
        turn.dirty.push((sync.pending.priority[cid] ?? .max, cid))
    }

    // MARK: - Serving

    private mutating func receive(_ message: SyncMessage, from peer: PeerID, _ turn: inout Turn) {
        switch message {
        case .getHeaders, .getHeader:
            if sync.peers[peer]?.serving == nil {
                serve(message, to: peer, &turn)
            } else if (sync.peers[peer]?.queued.count ?? 0) < 2 {
                sync.peers[peer]?.queued.append(message)
            }
        case .headers(let response):
            receive(response, from: peer, &turn)
        }
    }

    /// Answer one request through the peer's serving slot.
    private mutating func serve(_ message: SyncMessage, to peer: PeerID, _ turn: inout Turn) {
        let requestID: UInt64
        let page: (cids: [String], hasMore: Bool)
        switch message {
        case .getHeader(let id, let cid):
            requestID = id
            page = (cid != genesis && index.contains(cid) ? [cid] : [], false)
        case .getHeaders(let request):
            guard request.known.count <= HeadersRequest.maximumKnown else { return }
            requestID = request.requestID
            page = catchUpPage(request)
        case .headers:
            return
        }
        let token = sync.nextToken
        sync.nextToken += 1
        sync.peers[peer]?.serving = token
        turn.effects.append(.serveHeaders(
            peer, token: token, requestID: requestID, blockCIDs: page.cids, hasMore: page.hasMore
        ))
    }

    /// The weighed headers after the requester's locator: from Bitcoin's
    /// FindFork (the highest locator entry on our best chain) less
    /// `sideBranchWindow` heights, in `HeaderKey` order after the cursor,
    /// skipping every ancestor of a held locator entry. The work is
    /// O(page + locator × window), never O(graph).
    mutating func catchUpPage(_ request: HeadersRequest) -> (cids: [String], hasMore: Bool) {
        let held = request.known.filter(index.contains)
        let fork = held.filter { tree.isCanonical(hash: $0) }.compactMap(index.key).max()
        let top = (fork?.height ?? 0) + 1
        let startHeight = request.after?.height
            ?? (top > config.sideBranchWindow ? max(1, top - config.sideBranchWindow) : 1)
        var skip: Set<String> = [genesis]
        for known in held {
            var current: String? = known
            while let hash = current, let height = index.height[hash], height >= startHeight,
                  skip.insert(hash).inserted {
                current = index.parent[hash]
            }
        }
        let start = request.after ?? HeaderKey(height: startHeight, cid: "")
        var cids: [String] = []
        sync.lastServeScanned = skip.count
        for key in index.keys(from: start, strictlyAfter: request.after != nil) {
            sync.lastServeScanned += 1
            guard !skip.contains(key.cid) else { continue }
            if cids.count == config.maxHeadersPerPage { return (cids, true) }
            cids.append(key.cid)
        }
        return (cids, false)
    }

    // MARK: - Catch-up

    /// A Bitcoin-style locator: the best chain from its tip (ten, then
    /// doubling steps back to genesis), then our leaves, highest first, each
    /// with doubling steps back until the best chain; at most
    /// `HeadersRequest.maximumKnown` entries.
    func locator() -> [String] {
        let limit = HeadersRequest.maximumKnown
        var entries: [String] = []
        var seen = Set<String>()
        func add(_ cid: String?) {
            guard let cid, entries.count < limit, seen.insert(cid).inserted else { return }
            entries.append(cid)
        }
        let tipHeight = index.height[tree.canonicalTip] ?? 0
        var height = tipHeight
        var step: UInt64 = 1
        while true {
            add(tree.canonicalBlockHash(atHeight: height))
            if height == 0 { break }
            if entries.count >= 10 { step *= 2 }
            height = height > step ? height - step : 0
        }
        for leaf in index.topLeaves where entries.count < limit && !tree.isCanonical(hash: leaf.cid) {
            add(leaf.cid)
            var step: UInt64 = 1
            var height = leaf.height
            while height > step, entries.count < limit {
                height -= step
                step *= 2
                guard let ancestor = index.ancestor(of: leaf.cid, atHeight: height) else { break }
                if tree.isCanonical(hash: ancestor) { break }
                add(ancestor)
            }
        }
        return entries
    }

    /// Ask `peer` for its weighed headers after our locator, continuing
    /// after `after`.
    private mutating func requestCatchUp(from peer: PeerID, after: HeaderKey?, _ turn: inout Turn) {
        guard let state = sync.peers[peer], state.catchUp == nil else { return }
        let requestID = nextRequestID()
        sync.peers[peer]?.catchUp = InFlightPage(
            requestID: requestID, after: after, deadline: turn.now + config.headersTimeout
        )
        sync.peers[peer]?.nextCatchUp = turn.now + config.catchUpInterval
        turn.effects.append(.send(peer, .getHeaders(HeadersRequest(
            requestID: requestID, known: locator(), after: after
        ))))
    }

    /// Headers from `peer`: a relay, a catch-up page, or the parent asked of
    /// it. All take the same path; only a page continues.
    private mutating func receive(_ response: HeadersResponse, from peer: PeerID, _ turn: inout Turn) {
        var page: InFlightPage?
        var answeredParent = false
        if response.requestID != 0 {
            if let inFlight = sync.peers[peer]?.catchUp, inFlight.requestID == response.requestID {
                sync.peers[peer]?.catchUp = nil
                page = inFlight
            } else if sync.peers[peer]?.parentRequest?.requestID == response.requestID {
                sync.peers[peer]?.parentRequest = nil
                answeredParent = true
            } else {
                return
            }
        }
        var last: HeaderKey?
        for entry in response.entries {
            guard let cid = accept(entry, from: peer, &turn) else { return }
            last = HeaderKey(height: entry.block.height, cid: cid)
        }
        if answeredParent { nextWant(of: peer, parent: true, &turn) }
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
        if index.contains(cid) { return cid }
        // Structural, never blame: an inline child index that is not the one
        // the block commits, or a genesis (only bootstrap admits one).
        if let children = entry.children, Self.cid(of: children) != entry.block.children.rawCID {
            return cid
        }
        guard let parent = entry.block.parent?.rawCID else { return cid }
        let (horizon, overflow) = turn.now.addingReportingOverflow(config.maxFutureDrift)
        if !overflow, entry.block.timestamp > horizon { return cid }
        if var held = sync.pending.entries[cid] {
            if !held.announcers.contains(peer) {
                if held.announcers.isEmpty { held.askedParent = false }
                held.announcers.append(peer)
                sync.pending.entries[cid] = held
                sync.announced[peer, default: []].insert(cid)
            }
            if let children = entry.children, held.children == nil {
                sync.pending.setChildren(children, of: cid, bytes: Self.size(of: children))
                sync.evict(to: config.pendingBudget)
            }
            dirty(cid, &turn)
            return cid
        }
        guard ChainTree.rootWork(of: entry.block) != nil else {
            disconnect(peer, .proofOfWorkInvalid, &turn)
            return nil
        }
        sync.pending.insert(PendingHeader(
            blockCID: cid,
            block: entry.block,
            children: entry.children,
            hash: entry.block.proofOfWorkHash(),
            bytes: Self.size(of: entry.block) + (entry.children.map(Self.size) ?? 0),
            announcers: [peer],
            linked: index.contains(parent)
        ))
        sync.announced[peer, default: []].insert(cid)
        dirty(cid, &turn)
        sync.evict(to: config.pendingBudget)
        return cid
    }

    // MARK: - Processing pending headers

    /// Look at every dirty pending header, smallest priority first; each one
    /// weighed dirties its pending children.
    private mutating func drain(_ turn: inout Turn) {
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
        let admission = tree.insertRootHeader(
            header.block,
            childIndex: children,
            validationContext: ValidationContext(nowMilliseconds: turn.now)
        )
        switch admission {
        case .applied(let update):
            let waiting = sync.pending.childrenOf[cid] ?? []
            sync.removePending(cid)
            turn.headers.append(StoredHeader(blockCID: cid, block: header.block, children: children))
            turn.facts += update.batches
            index.add(cid, parent: header.parent, height: header.block.height)
            turn.relays.append((config.entry(header.block, children: children), from: header.source))
            for child in waiting {
                sync.pending.entries[child]?.linked = true
                dirty(child, &turn)
            }
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

    /// Ask the header's first announcer for its parent or its child index,
    /// or queue the ask until that request slot frees. A header no live
    /// peer announced starts a catch-up from another peer instead.
    private mutating func want(_ header: PendingHeader, parent: Bool, _ turn: inout Turn) {
        guard let source = header.source, let state = sync.peers[source] else {
            if let other = sync.peers.keys.sorted().first(where: { sync.peers[$0]?.catchUp == nil }) {
                requestCatchUp(from: other, after: nil, &turn)
            }
            return
        }
        let cid = header.blockCID
        if parent {
            guard let parentHash = header.parent else { return }
            guard state.parentRequest == nil else { return queueWant(cid, of: source, parent: true) }
            let requestID = nextRequestID()
            sync.peers[source]?.parentRequest = InFlightHeader(
                requestID: requestID, cid: parentHash, deadline: turn.now + config.headersTimeout
            )
            sync.pending.entries[cid]?.askedParent = true
            turn.effects.append(.send(source, .getHeader(requestID: requestID, cid: parentHash)))
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
        sync.wants[key, default: Heap { $0.priority != $1.priority ? $0.priority < $1.priority : $0.cid < $1.cid }]
            .push((sync.pending.priority[cid] ?? .max, cid))
    }

    /// A request slot of `peer` freed: look again at the queued header of
    /// smallest priority that still waits on it.
    private mutating func nextWant(of peer: PeerID, parent: Bool, _ turn: inout Turn) {
        let key = WantSlot(peer: peer, parent: parent)
        while let next = sync.wants[key]?.pop() {
            guard let header = sync.pending.entries[next.cid], header.source == peer else { continue }
            evaluate(next.cid, &turn)
            return
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
        sync.evict(to: config.pendingBudget)
        nextWant(of: peer, parent: false, &turn)
    }

    // MARK: - Time

    /// A peer whose request passed its deadline is stalling: disconnect it
    /// to free the slot, never a ban. Held headers whose time came are looked
    /// at again, and each peer due a repair catch-up is asked.
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
        for peer in sync.peers.keys.sorted() where (sync.peers[peer]?.nextCatchUp ?? .max) <= now {
            requestCatchUp(from: peer, after: nil, &turn)
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
