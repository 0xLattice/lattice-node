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
    /// The shell finished sending the page a `serveHeaders` effect named.
    case headersServed(PeerID)
    case tick
}

public enum DisconnectReason: Sendable, Equatable {
    /// The peer sent something provably wrong: bytes that do not match
    /// their CID, a header that fails proof-of-work or linkage, a page that
    /// does not chain, or too many pages that do not connect.
    case malformed
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
    /// Answer `getHeaders` with these blocks of the best header chain, in
    /// order. The shell reads their content and byte-budgets the page,
    /// omitting a child index that does not fit and setting `hasMore` when
    /// it truncates.
    case serveHeaders(PeerID, requestID: UInt64, blockCIDs: [String], hasMore: Bool)
    case fetchByCID(PeerID, cid: String)
    case disconnect(PeerID, DisconnectReason)
    case persist(PersistBatch)
    case publish(Snapshot)
    case wakeAt(Int64)
}

public struct CoreConfig: Sendable {
    public var maxHeadersPerPage: Int
    public var headersTimeout: Int64
    public var maxUnconnectingHeaders: Int
    public var maxAwaitingChildIndex: Int
    /// The spam floor N: drop (never blame) a header whose target is easier
    /// than 1/N of the best header tip's. 16 is four ASERT half-lives: an
    /// honest block's target moves by 2^(drift / half-life), so an honest
    /// side branch near the tip sits within a small factor of the tip's
    /// target, while a fork dated far behind schedule to saturate its target
    /// is cut off after a few headers. 0 or 1 disables it.
    public var targetFloorDivisor: UInt64

    public init(
        maxHeadersPerPage: Int = 2_000,
        headersTimeout: Int64 = 30_000,
        maxUnconnectingHeaders: Int = 10,
        maxAwaitingChildIndex: Int = 64,
        targetFloorDivisor: UInt64 = 16
    ) {
        self.maxHeadersPerPage = maxHeadersPerPage
        self.headersTimeout = headersTimeout
        self.maxUnconnectingHeaders = maxUnconnectingHeaders
        self.maxAwaitingChildIndex = maxAwaitingChildIndex
        self.targetFloorDivisor = targetFloorDivisor
    }
}

/// The node's state machine for one root level: the chain tree and header
/// sync as values behind one synchronous `step`. No IO, no awaits: every
/// mutation of a step is atomic, and the effects say what the shell must do.
public struct Core: Sendable {
    public private(set) var tree: ChainTree
    public private(set) var sync = Sync()
    public private(set) var published: Snapshot?
    public let spec: ChainSpec
    public let config: CoreConfig

    /// A core over a bootstrapped or restored root tree. `spec` is the
    /// chain's own (every header must commit the same one).
    public init(tree: ChainTree, spec: ChainSpec, config: CoreConfig = CoreConfig()) {
        precondition(tree.context?.isRoot == true, "the core runs one root level")
        self.tree = tree
        self.spec = spec
        self.config = config
    }

    /// Rebuild a core from its durable facts.
    public static func restore(
        replaying facts: [BlockImportBatch],
        context: ChainRuntimeContext,
        spec: ChainSpec,
        config: CoreConfig = CoreConfig()
    ) throws -> Core {
        Core(
            tree: try ChainTree.restore(replaying: facts, context: context),
            spec: spec,
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
            requestHeaders(from: peer, continuingFrom: nil, &turn)
        case .peerGone(let peer):
            sync.drop(peer)
        case .received(let peer, let message):
            guard sync.peers[peer] != nil else { break }
            receive(message, from: peer, &turn)
        case .childIndexFetched(let peer, let cid, let index):
            childIndexFetched(index, cid: cid, from: peer, &turn)
        case .headersServed(let peer):
            sync.peers[peer]?.serving = false
        case .tick:
            expireDeadlines(&turn)
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
        var relays: [(entry: HeaderEntry, from: PeerID)] = []
    }

    /// Persist first, then publish, then everything else: nothing a step
    /// makes visible precedes the write that makes it durable.
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
        // Relay every newly weighed header to every other peer (BIP130
        // sendheaders): relaying a header is not acting on its weight. Only
        // tip announces and templates act, and they come from the executed tip.
        let peers = sync.peers.keys.sorted()
        for relay in turn.relays {
            for peer in peers where peer != relay.from {
                effects.append(.send(peer, .headers(HeadersResponse(
                    requestID: 0, entries: [relay.entry], hasMore: false
                ))))
            }
        }
        effects += turn.effects
        if let deadline = sync.nextDeadline {
            effects.append(.wakeAt(deadline))
        }
        return effects
    }

    private mutating func disconnect(_ peer: PeerID, _ reason: DisconnectReason, _ turn: inout Turn) {
        sync.drop(peer)
        turn.effects.append(.disconnect(peer, reason))
    }

    // MARK: - Messages

    private mutating func receive(_ message: SyncMessage, from peer: PeerID, _ turn: inout Turn) {
        switch message {
        case .announce(let blockCID, _):
            sync.peers[peer]?.announcedTip = blockCID
            if !tree.contains(blockHash: blockCID) {
                requestHeaders(from: peer, continuingFrom: nil, &turn)
            }
        case .getHeaders(let request):
            serve(request, to: peer, &turn)
        case .headers(let response):
            if let inFlight = sync.peers[peer]?.inFlight, inFlight.requestID == response.requestID {
                sync.peers[peer]?.inFlight = nil
                receive(response, from: peer, solicited: true, &turn)
            } else if response.entries.count == 1 {
                receive(response, from: peer, solicited: false, &turn)
            }
        }
    }

    /// Ask `peer` for headers after our best header chain, unless a request is
    /// already in flight. `continuingFrom` is the last header of a full page:
    /// it leads the locator so a heavier chain still lighter than ours at this
    /// point keeps downloading.
    ///
    /// An exchange is one request and the continuations that follow it;
    /// `continuationHeight` is the height of `last`, the exchange's new
    /// continuation point. A fresh request starts a new exchange with no
    /// point, except the retry that follows an exchange ended for making no
    /// progress (`resuming`): it keeps that exchange's point, so a peer that
    /// repeats a page costs one page per timeout.
    private mutating func requestHeaders(
        from peer: PeerID,
        continuingFrom last: String?,
        continuationHeight: UInt64? = nil,
        resuming: Bool = false,
        _ turn: inout Turn
    ) {
        guard let state = sync.peers[peer], state.inFlight == nil,
              !sync.awaitingChildIndex.values.contains(where: { $0.peer == peer })
        else { return }
        sync.peers[peer]?.continuationHeight = last == nil
            ? (resuming ? state.stalledHeight : nil)
            : continuationHeight
        sync.peers[peer]?.stalledHeight = nil
        var locator = tree.headerLocator()
        if let last, !locator.contains(last) {
            locator = Array(([last] + locator).prefix(HeadersRequest.maximumLocatorEntries - 1))
            if let genesis = tree.canonicalBlockHash(atHeight: 0), locator.last != genesis {
                locator.append(genesis)
            }
        }
        let requestID = sync.nextRequestID
        sync.nextRequestID += 1
        sync.peers[peer]?.retryAt = nil
        sync.peers[peer]?.inFlight = InFlightHeaders(
            requestID: requestID,
            deadline: turn.now + config.headersTimeout
        )
        turn.effects.append(.send(peer, .getHeaders(HeadersRequest(
            requestID: requestID, locator: locator
        ))))
    }

    /// Serve the best header chain after the first locator entry on it. One
    /// page per peer is outstanding at a time; a request beyond it is
    /// dropped, never blamed (the peer re-asks at its own deadline).
    private mutating func serve(_ request: HeadersRequest, to peer: PeerID, _ turn: inout Turn) {
        guard request.locator.count <= HeadersRequest.maximumLocatorEntries else {
            disconnect(peer, .malformed, &turn)
            return
        }
        guard sync.peers[peer]?.serving == false else { return }
        sync.peers[peer]?.serving = true
        let tipHeight = tree.headerSnapshot(of: tree.canonicalTip)?.tipHeight ?? 0
        let tree = self.tree
        let forkHeight = request.locator.lazy
            .filter { tree.isCanonical(hash: $0) }
            .compactMap { tree.headerSnapshot(of: $0)?.tipHeight }
            .first ?? 0
        var blockCIDs: [String] = []
        var height = forkHeight + 1
        while height <= tipHeight, blockCIDs.count < config.maxHeadersPerPage,
              let hash = tree.canonicalBlockHash(atHeight: height) {
            blockCIDs.append(hash)
            height += 1
        }
        turn.effects.append(.serveHeaders(
            peer,
            requestID: request.requestID,
            blockCIDs: blockCIDs,
            hasMore: height <= tipHeight
        ))
    }

    // MARK: - Header insertion

    private enum Insertion {
        case inserted
        case held
        /// The first header's parent is unknown.
        case unconnected
        /// Not blame: the header is from our future; ask again at its time.
        case notYetValid(Int64)
        /// Not blame: the failure is ours.
        case deferred
        case malformed
    }

    /// Weigh one root header: its own proof-of-work, target, linkage and
    /// timestamp, checked by the tree.
    private mutating func insert(
        _ block: Block,
        blockCID: String,
        children: ChildIndex,
        from peer: PeerID,
        _ turn: inout Turn
    ) -> Insertion {
        if tree.contains(blockHash: blockCID) { return .held }
        let admission = tree.insertRootHeader(
            block,
            spec: spec,
            childIndex: children,
            validationContext: ValidationContext(nowMilliseconds: turn.now)
        )
        switch admission {
        case .applied(let update):
            turn.headers.append(StoredHeader(blockCID: blockCID, block: block, children: children))
            turn.facts.append(update.facts)
            // A relay carries only the empty child index inline; any other
            // is fetched by CID (one wait per peer), keeping relays small.
            turn.relays.append((
                HeaderEntry(block: block, children: children.entries.isEmpty ? children : nil),
                from: peer
            ))
            return .inserted
        case .duplicate:
            return .held
        case .rejected(let failure):
            switch failure {
            case .unavailableEvidence:
                return .unconnected
            case .notYetValid:
                return .notYetValid(block.timestamp)
            case .localVerificationFailure, .revisionExhausted:
                return .deferred
            case .providerMalformedEvidence, .protocolInvalid, .notAcceptedAtCurrentChain,
                 .crossChainEvidenceRequired:
                return .malformed
            }
        }
    }

    /// Read a headers page: the answer to our request (`solicited`), or one
    /// unsolicited header a peer relayed. Both take the same insert path.
    private mutating func receive(
        _ response: HeadersResponse,
        from peer: PeerID,
        solicited: Bool,
        _ turn: inout Turn
    ) {
        var previous: String?
        var inserted = 0
        for (position, entry) in response.entries.enumerated() {
            guard let blockCID = try? BlockHeader(node: entry.block).rawCID,
                  previous == nil || entry.block.parent?.rawCID == previous else {
                disconnect(peer, .malformed, &turn)
                return
            }
            previous = blockCID
            if tree.contains(blockHash: blockCID) { continue }
            if belowTargetFloor(entry.block) {
                // Dropped, never blamed: not stored, not relayed. The rest of
                // the page descends from it, so the exchange ends here; the
                // peer is asked again, from our best chain, after a timeout.
                if solicited { retry(peer, at: turn.now + config.headersTimeout) }
                return
            }
            guard let children = entry.children ?? heldChildIndex(for: entry.block) else {
                // Only a header that would be inserted may cost a fetch.
                switch linkageBeforeFetch(entry.block, now: turn.now) {
                case .linked:
                    awaitChildIndex(of: entry.block, blockCID: blockCID, from: peer, &turn)
                case .unconnected:
                    if position == 0 { unconnected(peer, solicited: solicited, &turn) }
                case .notYetValid(let timestamp):
                    retry(peer, at: timestamp)
                case .deferred:
                    retry(peer, at: turn.now + config.headersTimeout)
                case .malformed:
                    disconnect(peer, .malformed, &turn)
                }
                return
            }
            switch insert(entry.block, blockCID: blockCID, children: children, from: peer, &turn) {
            case .inserted:
                inserted += 1
            case .held:
                continue
            case .notYetValid(let timestamp):
                retry(peer, at: timestamp)
                return
            case .deferred:
                retry(peer, at: turn.now + config.headersTimeout)
                return
            case .malformed:
                disconnect(peer, .malformed, &turn)
                return
            case .unconnected:
                // Only the first header can miss its parent: every later one
                // names the header before it, which is now held.
                guard position == 0 else { return }
                unconnected(peer, solicited: solicited, &turn)
                return
            }
        }
        guard solicited, let last = previous else { return }
        if response.hasMore, inserted == 0, let lastHeight = response.entries.last?.block.height {
            // Every header is already held. An honest peer walking its best
            // chain through blocks we hold but do not select moves forward:
            // continue while the walk climbs past this exchange's previous
            // continuation point. Anything else ends the exchange until a
            // timeout. Never blame: holding a peer's chain is not its fault.
            let previous = sync.peers[peer]?.continuationHeight
            if previous.map({ lastHeight > $0 }) ?? true {
                requestHeaders(from: peer, continuingFrom: last, continuationHeight: lastHeight, &turn)
            } else {
                sync.peers[peer]?.stalledHeight = previous
                retry(peer, at: turn.now + config.headersTimeout)
            }
            return
        }
        sync.peers[peer]?.unconnecting = 0
        if response.hasMore {
            requestHeaders(
                from: peer,
                continuingFrom: last,
                continuationHeight: response.entries.last?.block.height,
                &turn
            )
        } else if inserted > 0, let announced = sync.peers[peer]?.announcedTip,
                  !tree.contains(blockHash: announced) {
            // Progress, but not yet the block it announced: ask again. A page
            // that added nothing ends the exchange, so a peer announcing a
            // block off its own best chain cannot loop us.
            requestHeaders(from: peer, continuingFrom: nil, &turn)
        }
    }

    /// The spam floor: a header whose target is easier than 1/N of our best
    /// header tip's target is dropped. It gates what this node stores and
    /// relays, never what is valid, and blames no one. A header extending the
    /// best header tip always passes: after a stall longer than four
    /// half-lives the next honest block is that much easier than the tip, and
    /// flooring it would halt the chain.
    private func belowTargetFloor(_ block: Block) -> Bool {
        guard config.targetFloorDivisor > 1,
              block.parent?.rawCID != tree.canonicalTip,
              let tipTarget = tree.headerSnapshot(of: tree.canonicalTip)?.target else { return false }
        let (floor, overflow) = tipTarget.multipliedReportingOverflow(by: UInt256(config.targetFloorDivisor))
        return !overflow && block.target > floor
    }

    /// A page we asked for whose first header does not connect counts against
    /// the peer; below the limit, ask again from our best header chain. A
    /// relayed header that does not connect is a chain we lack (its own
    /// proof-of-work was checked first on both paths: the tree checks it
    /// before the parent, and a header without its child index is checked
    /// before it may cost a fetch): ask, never count it, since an honest peer
    /// relays a burst of headers to a peer that is behind. The ask is bounded
    /// by the one request in flight per peer.
    private mutating func unconnected(_ peer: PeerID, solicited: Bool, _ turn: inout Turn) {
        guard solicited else {
            requestHeaders(from: peer, continuingFrom: nil, &turn)
            return
        }
        let count = (sync.peers[peer]?.unconnecting ?? 0) + 1
        guard count < config.maxUnconnectingHeaders else {
            disconnect(peer, .malformed, &turn)
            return
        }
        sync.peers[peer]?.unconnecting = count
        requestHeaders(from: peer, continuingFrom: nil, &turn)
    }

    /// A child index this tree already commits to: the empty one, or the
    /// one its parent recorded. Its CID must be the block's own.
    private func heldChildIndex(for block: Block) -> ChildIndex? {
        var candidates = [ChildIndex()]
        if let parent = block.parent?.rawCID,
           let commitments = tree.recordedChildCommitments(of: parent), !commitments.isEmpty {
            candidates.append(ChildIndex(entries: commitments.mapValues { BlockHeader(rawCID: $0) }))
        }
        let cid = block.children.rawCID
        return candidates.first { (try? HeaderImpl<ChildIndex>(node: $0).rawCID) == cid }
    }

    /// What a header without its child index may cost, checked with
    /// everything but the child index: its own proof-of-work first, then a
    /// held parent, then the tree's header linkage — spec, state, height,
    /// timestamp, and a target that is exactly the consensus target (so a
    /// tip extension cannot declare an easy target and take a wait free).
    private enum PreFetch {
        case linked
        case unconnected
        case notYetValid(Int64)
        case deferred
        case malformed
    }

    private mutating func linkageBeforeFetch(_ block: Block, now: Int64) -> PreFetch {
        guard ChainTree.rootWork(of: block) != nil else { return .malformed }
        guard let parentHash = block.parent?.rawCID,
              let parent = tree.headerSnapshot(of: parentHash) else { return .unconnected }
        let anchor = tree.difficultyAnchor(forBlockHash: parentHash)
        do {
            let linked = try block.validateHeaderLinkage(
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
                reportTemporalFailure: true,
                validationContext: ValidationContext(nowMilliseconds: now)
            )
            return linked ? .linked : .malformed
        } catch BlockValidationError.notYetValid {
            return .notYetValid(block.timestamp)
        } catch {
            return .deferred
        }
    }

    /// Ask `peer` again at `time` (another wait's deadline, a header's
    /// timestamp, or a timeout after an exchange ended without progress):
    /// never a drop, never blame.
    private mutating func retry(_ peer: PeerID, at time: Int64) {
        guard let existing = sync.peers[peer] else { return }
        sync.peers[peer]?.retryAt = min(existing.retryAt ?? .max, time)
    }

    private mutating func awaitChildIndex(
        of block: Block,
        blockCID: String,
        from peer: PeerID,
        _ turn: inout Turn
    ) {
        let cid = block.children.rawCID
        guard sync.awaitingChildIndex[cid] == nil,
              sync.awaitingChildIndex.count < config.maxAwaitingChildIndex,
              !sync.awaitingChildIndex.values.contains(where: { $0.peer == peer }) else {
            // One wait per peer, and a taken slot is not ours: ask this peer
            // again once the earliest wait resolves or expires.
            let next = sync.awaitingChildIndex.values.map(\.deadline).min()
            retry(peer, at: next ?? turn.now + config.headersTimeout)
            return
        }
        sync.awaitingChildIndex[cid] = AwaitingChildIndex(
            blockCID: blockCID,
            block: block,
            peer: peer,
            deadline: turn.now + config.headersTimeout
        )
        turn.effects.append(.fetchByCID(peer, cid: cid))
    }

    private mutating func childIndexFetched(
        _ index: ChildIndex?,
        cid: String,
        from peer: PeerID,
        _ turn: inout Turn
    ) {
        guard let waiting = sync.awaitingChildIndex[cid], waiting.peer == peer else { return }
        sync.awaitingChildIndex[cid] = nil
        // Not having the bytes is availability, never blame: ask again later.
        guard let index else {
            retry(peer, at: turn.now + config.headersTimeout)
            return
        }
        guard (try? HeaderImpl<ChildIndex>(node: index).rawCID) == cid else {
            disconnect(peer, .malformed, &turn)
            return
        }
        switch insert(waiting.block, blockCID: waiting.blockCID, children: index, from: peer, &turn) {
        case .inserted, .held:
            requestHeaders(
                from: peer,
                continuingFrom: waiting.blockCID,
                continuationHeight: waiting.block.height,
                &turn
            )
        case .notYetValid(let timestamp):
            retry(peer, at: timestamp)
        case .deferred, .unconnected:
            retry(peer, at: turn.now + config.headersTimeout)
        case .malformed:
            disconnect(peer, .malformed, &turn)
        }
    }

    // MARK: - Deadlines

    /// A request past its deadline is dropped and asked again: silence is
    /// availability, never blame.
    private mutating func expireDeadlines(_ turn: inout Turn) {
        let expiredFetches = sync.awaitingChildIndex.filter { $0.value.deadline <= turn.now }
        for (cid, _) in expiredFetches {
            sync.awaitingChildIndex[cid] = nil
        }
        let expiredRequests = sync.peers.filter { ($0.value.inFlight?.deadline ?? .max) <= turn.now }
        for peer in expiredRequests.keys {
            sync.peers[peer]?.inFlight = nil
        }
        let dueRetries = sync.peers.filter { ($0.value.retryAt ?? .max) <= turn.now }
        for peer in dueRetries.keys {
            sync.peers[peer]?.retryAt = nil
        }
        let retry = Set(expiredFetches.values.map(\.peer))
            .union(expiredRequests.keys)
            .union(dueRetries.keys)
        for peer in retry.sorted() {
            requestHeaders(
                from: peer, continuingFrom: nil, resuming: dueRetries.keys.contains(peer), &turn
            )
        }
    }
}
