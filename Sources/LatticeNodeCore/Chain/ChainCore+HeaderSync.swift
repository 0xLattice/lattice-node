import Lattice
import UInt256
import cashew

extension ChainCore {
    // MARK: - Streams

    /// Ask `peer` for its log after what we took of it (on a new session,
    /// after our cursor in it; a fresh peer: 0). Never while gated: the
    /// parent's latch asks every peer (`parentWeighed`).
    mutating func requestStream(from peer: PeerID, _ turn: inout Turn) {
        guard !gated, let state = sync.peers[peer], state.stream == nil else { return }
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
    /// Nothing is taken while gated: no page was asked, and a push is read
    /// again from the cursor once the gate opens.
    mutating func receive(_ page: StreamPage, from peer: PeerID, _ turn: inout Turn) {
        guard !gated, let state = sync.peers[peer] else { return }
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
            // A new log is not one read to its end: only a page asked of
            // it that says nothing more follows makes it so.
            sync.peers[peer]?.readToEnd = false
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
        if page.requestID != 0, !page.hasMore, sync.peers[peer]?.more == false {
            sync.peers[peer]?.readToEnd = true
        }
        advanceCursor(of: peer, &turn)
        pump(peer, &turn)
    }

    /// Whether a logged object is applied here: a header weighed, a grind
    /// credited.
    mutating func applied(_ entry: LogEntry) -> Bool {
        // Declined is done: a stream must not stall on what finality refused.
        if sync.declined.contains(entry.block) { return true }
        guard tree.contains(blockHash: entry.block) else { return false }
        if entry.kind == .proof, pastFinality(entry.block) { return true }
        return entry.kind == .header || tree.workContribution(id: entry.cid, at: entry.block) != nil
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
            // A pending header with no child index and no announcer waits
            // on nobody: its hole is asked again, so a stall frees the slot.
            let waiting = sync.pending.entries[entry.block].map { $0.children == nil && $0.announcers.isEmpty }
            return !tree.contains(blockHash: entry.block) && waiting != false
                && sync.proofs.awaiting[entry.block] == nil && !sync.declined.contains(entry.block)
        case .proof:
            return !applied(entry) && sync.pending.entries[entry.block]?.evidence[entry.cid] == nil
                && !sync.proofs.checking(entry.block, root: entry.cid)
        }
    }

    /// One `getData` at a time, for the holes this node lacks and has not
    /// asked for (an object asked of another peer counts as held, until that
    /// request stalls). A header it holds but has not weighed gains the peer
    /// as an announcer (the peer holds its ancestors). Otherwise the next
    /// page is pulled, once the holes leave room for half a page: a page is
    /// served whole, and a pull with room for a few entries would take those
    /// few and drop the rest (TCP's silly-window avoidance). Holes still
    /// lacking are asked again on a tick. Nothing while gated.
    mutating func pump(_ peer: PeerID, _ turn: inout Turn, again: Bool = false) {
        guard !gated, let state = sync.peers[peer], state.data == nil, sync.cursors[peer.key] != nil else { return }
        let inFlight = Set(sync.peers.values.flatMap { $0.data?.cids ?? [] })
        let requested = state.holes.last.map { Swift.max(state.requested, $0.position) } ?? state.requested
        var seen = Set<String>()
        var cids: [String] = []
        for hole in state.holes where (again || hole.position > state.requested) && lacks(hole.entry, inFlight: inFlight) {
            if seen.insert(hole.entry.block).inserted { cids.append(hole.entry.block) }
        }
        for hole in state.holes where hole.position > state.requested && hole.position <= requested
            && hole.entry.kind == .header && sync.pending.entries[hole.entry.block] != nil {
            announce(hole.entry.block, by: peer, &turn)
        }
        sync.peers[peer]?.requested = requested
        if !cids.isEmpty {
            requestData(cids, from: peer, &turn)
        } else if state.more, state.stream == nil, state.holes.count <= config.maxHeadersPerPage / 2 {
            requestStream(from: peer, &turn)
        }
    }

    private mutating func requestData(_ cids: [String], from peer: PeerID, _ turn: inout Turn) {
        let requestID = nextRequestID()
        sync.peers[peer]?.data = InFlightData(
            requestID: requestID, cids: cids, deadline: turn.now + config.headersTimeout
        )
        sync.peers[peer]?.askedAt = turn.now
        turn.effects.append(.send(peer, .getData(requestID: requestID, cids: cids)))
    }

    /// Headers from `peer`: the objects asked of it, or the ancestors asked
    /// of it (child to parent, taken parent first); anything unasked is
    /// ignored (the stream's tail is the relay). A peer that advertised an
    /// object and serves none of it is failing to serve: a stall, never
    /// blame. An answer cut short by bytes is asked again for the rest.
    mutating func receive(_ response: HeadersResponse, from peer: PeerID, _ turn: inout Turn) {
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
        // Only what was asked is taken: each asked object once, or the asked
        // header and the parents linked to it, as many as were asked.
        var entries: [HeaderEntry] = []
        if let data {
            var wanted = Set(data.cids)
            entries = response.entries.filter {
                guard let cid = $0.cid else { return false }
                return wanted.remove(cid) != nil
            }
        } else {
            var next = asked
            for entry in response.entries.prefix(config.maxHeadersPerPage + 1) {
                guard let cid = entry.cid, cid == next else { break }
                entries.append(entry)
                next = entry.block.parent?.rawCID
            }
            entries.reverse()
        }
        var received = Set<String>()
        for entry in entries {
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
    /// disconnected. A child header from no peer (a local submit) is judged
    /// the same way and blames no one.
    mutating func accept(_ entry: HeaderEntry, from peer: PeerID?, _ turn: inout Turn) -> String? {
        // An inline children map over the operator's limit is as if not sent:
        // asked for by CID, where the same limit makes it unavailable.
        var entry = entry
        if let children = entry.children, Self.size(of: children) > config.maxChildIndexBytes {
            entry = HeaderEntry(block: entry.block, children: nil, proofs: entry.proofs, spec: entry.spec, cid: entry.cid)
        }
        guard let cid = entry.cid else {
            if let peer { disconnect(peer, .proofOfWorkInvalid, &turn) }
            return nil
        }
        if tree.contains(blockHash: cid) {
            if !isRoot { offer(entry.proofs, cid: cid, from: peer, &turn) }
            return cid
        }
        if sync.declined.contains(cid) { return cid }
        // A root header proves its own work first: one that fails is blamed
        // whatever else is wrong with it (a date too far ahead included).
        if isRoot, ChainTree.rootWork(of: entry.block) == nil {
            if let peer { disconnect(peer, .proofOfWorkInvalid, &turn) }
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
        // A header carries its height: judged at once, an orphan too. Its
        // height is verified when it connects.
        if pastFinality(height: entry.block.height)
            || entry.block.parent.map({ sync.declined.contains($0.rawCID) }) == true {
            decline(cid)
            return cid
        }
        if let held = sync.pending.entries[cid] {
            if let peer { announce(cid, by: peer, &turn) }
            if let children = entry.children, held.children == nil {
                sync.pending.setChildren(children, of: cid, bytes: Self.size(of: children))
            }
            if held.spec == nil, let spec = Self.bound(entry.spec, by: entry.block) {
                sync.pending.entries[cid]?.spec = spec
            }
            if !isRoot { offer(entry.proofs, cid: cid, from: peer, &turn) }
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
        guard let peer else { return cid }
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
    mutating func announce(_ cid: String, by peer: PeerID, _ turn: inout Turn) {
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
        if tree.contains(blockHash: parent) {
            // The tip may have moved on since the header arrived.
            if pastFinality(height: header.block.height) {
                decline(cid)
                return
            }
            if header.children == nil {
                if scheduleCheck(header, turn.now, &turn) {
                    want(header, parent: false, &turn)
                }
            } else {
                insert(header, &turn)
            }
        } else if sync.pending.entries[parent] == nil, !awaitsItsWork(parent), !header.askedParent {
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
            // No announcer: submitted here (`ChainEvent.submitted`), or a
            // peer header whose announcers all left before it was weighed.
            // The latter costs one early push of a page, nothing more.
            if header.announcers.isEmpty { turn.own = true }
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

    mutating func childIndexFetched(
        _ index: FlatDictionary<BlockHeader>?,
        cid: String,
        from peer: PeerID,
        _ turn: inout Turn
    ) {
        guard let waiting = sync.peers[peer]?.childIndex, waiting.cid == cid else { return }
        sync.peers[peer]?.childIndex = nil
        let committing = sync.pending.committing(cid)
        // Over the operator's limit is unavailable here, exactly as absent.
        let index = index.flatMap { Self.size(of: $0) <= config.maxChildIndexBytes ? $0 : nil }
        guard let index else {
            // This peer does not hold what its header commits. The header
            // moves on to its next announcer, or waits for one; never blame.
            for var header in committing where header.source == peer {
                header.announcers.removeFirst()
                sync.pending.entries[header.blockCID] = header
                sync.announced[peer]?.remove(header.blockCID)
                dirty(header.blockCID, &turn)
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

}
