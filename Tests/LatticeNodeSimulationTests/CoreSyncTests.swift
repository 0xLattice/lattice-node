import Lattice
import LatticeNodeCore
import LatticeNodeSim
import UInt256
import XCTest

/// `Core.step` weighed-subgraph replication, one event at a time.
final class CoreSyncTests: XCTestCase {
    private static let now = World.genesisTime + 1_000_000
    private let peer = PeerID(key: "peer", session: 1)
    private let other = PeerID(key: "other", session: 1)
    private var world: World!
    private var chain: [SimBlock] = []

    override func setUp() async throws {
        var rng = SplitMix64(state: 0x5_1C)
        world = try await World.generate(rng: &rng, honestBlocks: 30, forkProbability: 0, spamBlocks: 6)
        chain = world.honest.compactMap { world.blocks[$0] }
    }

    private func core(pageSize: Int = 4, pendingBudget: Int = 1 << 20) -> Core {
        Core(
            tree: world.bootstrap.tree,
            config: CoreConfig(
                maxHeadersPerPage: pageSize,
                headersTimeout: 1_000,
                maxInlineChildIndexBytes: 1_024,
                pendingBudget: pendingBudget
            )
        )
    }

    // MARK: - Effect readers

    private func requests(_ effects: [Effect]) -> [(requestID: UInt64, logID: String?, after: UInt64)] {
        effects.compactMap {
            if case .send(_, .getStream(let id, let logID, let after)) = $0 { return (id, logID, after) }
            return nil
        }
    }

    private func dataRequests(_ effects: [Effect]) -> [(requestID: UInt64, cids: [String])] {
        effects.compactMap {
            if case .send(_, .getData(let id, let cids)) = $0 { return (id, cids) }
            return nil
        }
    }

    private func parentRequests(_ effects: [Effect]) -> [(PeerID, UInt64, String)] {
        effects.compactMap {
            if case .send(let to, .getAncestors(let id, let cid, _)) = $0 { return (to, id, cid) }
            return nil
        }
    }

    /// Pushes of our log's tail, per peer: the logged CIDs.
    private func relays(_ effects: [Effect]) -> [(PeerID, [String])] {
        effects.compactMap {
            if case .send(let to, .stream(let page)) = $0, page.requestID == 0 {
                return (to, page.entries.map(\.entry.cid))
            }
            return nil
        }
    }

    private func disconnects(_ effects: [Effect]) -> [DisconnectReason] {
        effects.compactMap {
            if case .disconnect(_, let reason) = $0 { return reason }
            return nil
        }
    }

    private func fetches(_ effects: [Effect]) -> [String] {
        effects.compactMap {
            if case .fetchByCID(_, let cid) = $0 { return cid }
            return nil
        }
    }

    private func served(_ effects: [Effect]) -> [(UInt64, [String], Bool, token: UInt64)] {
        effects.compactMap {
            if case .serveHeaders(_, let token, let id, let cids, let hasMore) = $0 { return (id, cids, hasMore, token) }
            return nil
        }
    }

    // MARK: - Drivers

    private func entry(_ block: SimBlock, inline: Bool = true) -> HeaderEntry {
        HeaderEntry(block: block.block, children: inline ? block.children : nil)
    }

    /// `peer` becomes ready and reads our log to its end, so it receives
    /// what we append. Returns the `peerReady` step's effects.
    @discardableResult
    private func ready(_ core: inout Core, _ peer: PeerID, at now: Int64 = CoreSyncTests.now) -> [Effect] {
        let effects = core.step(.peerReady(peer), now: now)
        _ = core.step(.received(peer, .getStream(requestID: 1, logID: core.sync.log.id, after: core.sync.log.count)), now: now)
        return effects
    }

    @discardableResult
    private func relay(
        _ core: inout Core,
        _ entries: [HeaderEntry],
        from peer: PeerID,
        requestID: UInt64 = 0,
        hasMore: Bool = false,
        at now: Int64 = CoreSyncTests.now
    ) -> [Effect] {
        core.step(.received(peer, .headers(HeadersResponse(
            requestID: requestID, entries: entries, hasMore: hasMore
        ))), now: now)
    }

    /// A core that weighed `blocks`, relayed by `peer`.
    private func weighed(_ blocks: [SimBlock], pageSize: Int = 4) -> Core {
        var core = core(pageSize: pageSize)
        ready(&core, peer)
        relay(&core, blocks.map { entry($0) }, from: peer)
        for block in blocks { XCTAssertTrue(core.tree.contains(blockHash: block.cid)) }
        return core
    }

    // MARK: - Streams

    func testPeerReadyAsksForThePeersLogFromItsCursorAndArmsADeadline() throws {
        var core = core()
        let effects = ready(&core, peer)
        let request = try XCTUnwrap(requests(effects).first)
        XCTAssertNil(request.logID, "a fresh peer")
        XCTAssertEqual(request.after, 0)
        XCTAssertEqual(core.sync.peers[peer]?.stream?.deadline, Self.now + 1_000)
        guard case .wakeAt(let wake) = effects.last else { return XCTFail("\(effects)") }
        XCTAssertEqual(wake, Self.now + 1_000)
        var resumed = Core(tree: world.bootstrap.tree, cursors: [peer.key: StreamCursor(logID: "L", position: 7)])
        let again = try XCTUnwrap(requests(resumed.step(.peerReady(peer), now: Self.now)).first)
        XCTAssertEqual(again.logID, "L")
        XCTAssertEqual(again.after, 7, "resumed from the shell's cursor")
    }

    /// A page of IDs: only what the node lacks is asked for; once it is
    /// applied, the cursor advances, the next page is asked, and what was
    /// weighed is persisted (with its log entries), published and pushed.
    func testAStreamPageAsksOnlyForWhatItLacksAndAdvancesTheCursor() throws {
        var core = weighed(Array(chain[0..<2]))
        ready(&core, other)
        let request = try XCTUnwrap(requests(ready(&core, PeerID(key: "server", session: 1))).first)
        let server = PeerID(key: "server", session: 1)
        let ids = chain[0..<4].enumerated().map { StreamEntry(position: UInt64($0.offset + 1), entry: .header($0.element.cid)) }
        var effects = core.step(.received(server, .stream(StreamPage(
            requestID: request.requestID, logID: "S", entries: ids, hasMore: true
        ))), now: Self.now)
        let asked = try XCTUnwrap(dataRequests(effects).first)
        XCTAssertEqual(asked.cids, chain[2..<4].map(\.cid), "held objects cost only their ID")
        effects = relay(&core, chain[2..<4].map { entry($0) }, from: server, requestID: asked.requestID)

        guard case .persist(let batch) = effects.first else { return XCTFail("\(effects)") }
        XCTAssertEqual(batch.headers.map(\.blockCID), chain[2..<4].map(\.cid))
        XCTAssertEqual(batch.log, chain[2..<4].map { .header($0.cid) })
        for fact in batch.facts.flatMap(\.facts) {
            switch fact {
            case .block, .work: continue
            case .validation, .exclusion: XCTFail("a weighed-only header issued \(fact)")
            }
        }
        guard case .publish(let snapshot) = effects.dropFirst().first else { return XCTFail("\(effects)") }
        XCTAssertEqual(snapshot.bestHeaderTip, chain[3].cid)
        XCTAssertEqual(snapshot.actOnTip, world.genesis.cid, "no header is executed")
        XCTAssertEqual(Set(relays(effects).map(\.0)), [peer, other, server], "pushed to every subscribed peer")
        XCTAssertEqual(relays(effects).first?.1, chain[2..<4].map(\.cid))
        XCTAssertEqual(core.sync.cursors[server.key], StreamCursor(logID: "S", position: 4))
        let next = try XCTUnwrap(requests(effects).first)
        XCTAssertEqual(next.logID, "S")
        XCTAssertEqual(next.after, 4)
    }

    func testServingStreamsTheLogInWeighOrderPagedAndSubscribesAtTheEnd() async throws {
        let side = try await world.branch(from: chain[1], count: 2)
        let graph = Array(chain[0..<6]) + side
        var core = weighed(graph)
        let log = core.sync.log.entries
        XCTAssertEqual(Set(log), Set(graph.map { .header($0.cid) }))
        for block in graph where block.parent != world.genesis.cid {
            XCTAssertLessThan(log.firstIndex(of: .header(block.parent!))!, log.firstIndex(of: .header(block.cid))!,
                              "weigh order is topological")
        }
        let id = core.sync.log.id
        var effects = core.step(.received(other, .getStream(requestID: 7, logID: nil, after: 0)), now: Self.now)
        XCTAssertFalse(effects.contains { if case .send = $0 { true } else { false } }, "a peer that is not ready is not served")
        _ = core.step(.peerReady(other), now: Self.now)
        effects = core.step(.received(other, .getStream(requestID: 7, logID: nil, after: 5)), now: Self.now)
        guard case .send(other, .stream(let first)) = effects.first else { return XCTFail("\(effects)") }
        XCTAssertEqual(first.requestID, 7)
        XCTAssertEqual(first.entries.map(\.position), [1, 2, 3, 4], "another log id: from 0")
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(core.sync.peers[other]?.subscribed, false)
        effects = core.step(.received(other, .getStream(requestID: 8, logID: id, after: 4)), now: Self.now)
        guard case .send(other, .stream(let rest)) = effects.first else { return XCTFail("\(effects)") }
        XCTAssertEqual(rest.entries.map(\.entry), Array(log[4...]))
        XCTAssertFalse(rest.hasMore)
        XCTAssertEqual(core.sync.peers[other]?.subscribed, true, "at the end: what we append is pushed")
    }

    func testOnlyOneServedPagePerPeerIsOutstandingAndTheNextWaitsForIt() throws {
        var core = weighed(Array(chain[0..<3]))
        ready(&core, other)
        let first = core.step(.received(other, .getData(requestID: 1, cids: [chain[0].cid])), now: Self.now)
        XCTAssertEqual(served(first).count, 1)
        let second = core.step(.received(other, .getData(requestID: 2, cids: [chain[1].cid])), now: Self.now)
        XCTAssertTrue(served(second).isEmpty)
        let sent = core.step(.headersServed(other, token: served(first)[0].token), now: Self.now)
        XCTAssertEqual(served(sent).first?.0, 2)
        // A `getAncestors` takes the same slot.
        let third = core.step(.received(other, .getAncestors(requestID: 3, cid: chain[0].cid, max: 4)), now: Self.now)
        XCTAssertTrue(served(third).isEmpty)
        let after = core.step(.headersServed(other, token: served(sent)[0].token), now: Self.now)
        XCTAssertEqual(served(after).first?.1, [chain[0].cid])
    }

    func testStreamingFromAnotherCoreReplicatesItsWholeGraph() async throws {
        let side = try await world.branch(from: chain[4], count: 3)
        var server = weighed(chain + side, pageSize: 5)
        var client = core(pageSize: 5)
        try link(&server, &client, extra: side, session: 9)
        XCTAssertEqual(TreeDigest(client.tree), TreeDigest(server.tree))
        XCTAssertEqual(Set(client.sync.log.entries), Set(server.sync.log.entries))
    }

    // MARK: - Blame: proof-of-work only

    func testAHeaderFailingProofOfWorkIsBlamed() throws {
        var core = core()
        ready(&core, peer)
        let forged = world.blocks[world.lies[.failedProofOfWork]!]!
        XCTAssertNil(ChainTree.rootWork(of: forged.block))
        let effects = relay(&core, [entry(forged)], from: peer)
        XCTAssertEqual(disconnects(effects), [.proofOfWorkInvalid])
        XCTAssertTrue(core.sync.pending.entries.isEmpty)
        XCTAssertNil(core.sync.peers[peer])
    }

    func testOffScheduleHeadersAreBlamedOnceTheirParentIsWeighed() throws {
        for lie in [Lie.offScheduleTarget, .offScheduleTimestamp] {
            let block = world.blocks[world.lies[lie]!]!
            XCTAssertNotNil(ChainTree.rootWork(of: block.block), "\(lie) meets its own target")
            var core = weighed(Array(chain[0..<2]))
            ready(&core, other)
            let effects = relay(&core, [entry(block)], from: other)
            XCTAssertEqual(disconnects(effects), [.proofOfWorkInvalid], "\(lie)")
            XCTAssertFalse(core.tree.contains(blockHash: block.cid))
            XCTAssertTrue(relays(effects).isEmpty)
        }
    }

    func testWrongSpecOrPrevStateIsWeighedExcludedAndRelayedNeverBlamed() throws {
        var core = weighed(Array(chain[0..<3]))
        ready(&core, other)
        let tip = core.tree.canonicalTip
        let invalid = [world.lies[.wrongSpec]!, world.lies[.wrongPrevState]!, world.excludedChild]
            .map { world.blocks[$0]! }
        let effects = relay(&core, invalid.map { entry($0) }, from: other)
        XCTAssertTrue(disconnects(effects).isEmpty)
        for block in invalid { XCTAssertTrue(core.tree.contains(blockHash: block.cid)) }
        XCTAssertEqual(Set(invalid.prefix(2).map(\.cid)).filter(core.tree.isExcludedRoot), Set(invalid.prefix(2).map(\.cid)))
        XCTAssertFalse(core.tree.isExcludedRoot(world.excludedChild), "a descendant weighs under its excluded root")
        XCTAssertEqual(core.tree.canonicalTip, tip, "never selected")
        XCTAssertEqual(Set(relays(effects).map(\.0)), [peer, other])
        XCTAssertEqual(Set(relays(effects).first?.1 ?? []), Set(invalid.map(\.cid)), "excluded headers are logged and pushed too")
    }

    func testStructuralProblemsAreDroppedWithoutBlame() throws {
        var core = core()
        ready(&core, peer)
        let fake = ChildIndex(entries: ["Liar": try BlockHeader(node: world.genesis.block)])
        let effects = relay(&core, [
            HeaderEntry(block: chain[0].block, children: fake),
            HeaderEntry(block: world.genesis.block, children: world.genesis.children),
        ], from: peer)
        XCTAssertTrue(disconnects(effects).isEmpty)
        XCTAssertTrue(core.sync.pending.entries.isEmpty)
        XCTAssertFalse(core.tree.contains(blockHash: chain[0].cid))
    }

    // MARK: - Unknown parents, child indexes, future headers

    func testAnUnknownParentIsFetchedWithItsAncestorsFromTheSender() throws {
        var core = core()
        ready(&core, peer)
        ready(&core, other)
        let orphan = world.blocks[world.orphan]!
        let withheld = world.blocks[world.withheld]!
        var effects = relay(&core, [entry(orphan)], from: other)
        XCTAssertTrue(disconnects(effects).isEmpty)
        let ask = try XCTUnwrap(parentRequests(effects).first)
        XCTAssertEqual(ask.0, other)
        XCTAssertEqual(ask.2, withheld.cid)
        XCTAssertNotNil(core.sync.pending.entries[orphan.cid])

        effects = relay(&core, [entry(withheld)], from: other, requestID: ask.1)
        XCTAssertTrue(core.tree.contains(blockHash: withheld.cid))
        XCTAssertTrue(core.tree.contains(blockHash: orphan.cid))
        XCTAssertEqual(relays(effects).first?.1, [withheld.cid, orphan.cid], "parent before child")
    }

    /// One `getAncestors` round trip connects a branch whose fork lies
    /// deep below: the answer lists child to parent and is taken parent
    /// first, and nothing more is asked.
    func testOneAncestorsAnswerConnectsADeepBranch() async throws {
        let branch = try await world.branch(from: chain[5], count: 8)
        var core = weighed(Array(chain[0..<12]), pageSize: 16)
        ready(&core, other)
        let effects = relay(&core, [entry(branch.last!)], from: other)
        let ask = try XCTUnwrap(parentRequests(effects).first)
        XCTAssertEqual(ask.2, branch[6].cid)
        // The server's answer: the header, then its ancestors down past the
        // fork (held ones are dropped as duplicates).
        let answer = (Array(chain[0...5]) + branch.dropLast()).reversed().map { entry($0) }
        let done = relay(&core, answer, from: other, requestID: ask.1)
        for block in branch { XCTAssertTrue(core.tree.contains(blockHash: block.cid)) }
        XCTAssertTrue(parentRequests(done).isEmpty)
        XCTAssertTrue(disconnects(done).isEmpty)
        XCTAssertTrue(core.sync.pending.entries.isEmpty)
    }

    func testTheServerAnswersAncestorsChildToParentCappedAboveGenesis() throws {
        var core = weighed(Array(chain[0..<10]), pageSize: 4)
        ready(&core, other)
        let effects = core.step(.received(other, .getAncestors(requestID: 5, cid: chain[9].cid, max: .max)), now: Self.now)
        let page = try XCTUnwrap(served(effects).first)
        XCTAssertEqual(page.1, chain[4...9].reversed().prefix(5).map(\.cid), "the header and at most a page of ancestors")
        _ = core.step(.headersServed(other, token: page.token), now: Self.now)
        let low = core.step(.received(other, .getAncestors(requestID: 6, cid: chain[1].cid, max: 9)), now: Self.now)
        XCTAssertEqual(served(low).first?.1, [chain[1].cid, chain[0].cid], "never genesis")
        _ = core.step(.headersServed(other, token: served(low)[0].token), now: Self.now)
        let unknown = core.step(.received(other, .getAncestors(requestID: 7, cid: "bafyunknown", max: -3)), now: Self.now)
        XCTAssertEqual(served(unknown).first?.1, [])
    }

    func testAnUnansweredParentIsNotBlameAndNotAskedAgain() throws {
        var core = core()
        ready(&core, peer)
        let orphan = world.blocks[world.orphan]!
        let ask = try XCTUnwrap(parentRequests(relay(&core, [entry(orphan)], from: peer)).first)
        let effects = relay(&core, [], from: peer, requestID: ask.1)
        XCTAssertTrue(disconnects(effects).isEmpty)
        XCTAssertTrue(parentRequests(effects).isEmpty)
        XCTAssertNotNil(core.sync.pending.entries[orphan.cid], "held until its parent arrives or it is evicted")
    }

    func testAnOmittedChildIndexIsFetchedByCIDFromTheSenderAndVerified() async throws {
        let carrier = try await world.carriers(count: 1, entries: 48)[0]
        let cid = carrier.block.children.rawCID
        for answer in ["honest", "mismatched", "missing"] {
            var core = core()
            ready(&core, peer)
            ready(&core, other)
            let effects = relay(&core, [entry(carrier, inline: false)], from: other)
            XCTAssertEqual(fetches(effects), [cid])
            XCTAssertEqual(core.sync.peers[other]?.childIndex?.cid, cid)
            let bytes: ChildIndex? = switch answer {
            case "honest": carrier.children
            case "mismatched": ChildIndex(entries: ["Liar": try BlockHeader(node: world.genesis.block)])
            default: nil
            }
            let fetched = core.step(.childIndexFetched(other, cid: cid, bytes), now: Self.now)
            switch answer {
            case "honest":
                XCTAssertTrue(core.tree.contains(blockHash: carrier.cid))
                guard case .persist = fetched.first else { return XCTFail("\(fetched)") }
                XCTAssertEqual(relays(fetched).first?.1, [carrier.cid], "pushed as an ID")
            case "mismatched":
                XCTAssertEqual(disconnects(fetched), [.proofOfWorkInvalid])
                XCTAssertFalse(core.tree.contains(blockHash: carrier.cid))
            default:
                XCTAssertTrue(disconnects(fetched).isEmpty, "availability, never blame")
                XCTAssertTrue(core.sync.pending.entries.isEmpty)
            }
        }
    }

    func testOnePeerHoldsAtMostOneChildIndexWait() async throws {
        let carriers = try await world.carriers(count: 2, entries: 48)
        var core = core()
        ready(&core, peer)
        let effects = relay(&core, carriers.map { entry($0, inline: false) }, from: peer)
        XCTAssertEqual(fetches(effects).count, 1)
        let first = try XCTUnwrap(fetches(effects).first)
        let done = carriers.first { $0.block.children.rawCID == first }!
        let next = core.step(.childIndexFetched(peer, cid: first, done.children), now: Self.now)
        XCTAssertEqual(fetches(next), carriers.filter { $0.cid != done.cid }.map(\.block.children.rawCID))
    }

    func testAHeaderFromTheFutureWaitsForItsTime() throws {
        var core = core()
        let early = chain[0].block.timestamp - 500
        ready(&core, peer, at: early)
        let effects = relay(&core, [entry(chain[0])], from: peer, at: early)
        XCTAssertFalse(core.tree.contains(blockHash: chain[0].cid))
        XCTAssertTrue(disconnects(effects).isEmpty)
        XCTAssertEqual(core.sync.pending.entries[chain[0].cid]?.notBefore, chain[0].block.timestamp)
        guard case .wakeAt(let wake) = effects.last else { return XCTFail("\(effects)") }
        XCTAssertEqual(wake, chain[0].block.timestamp)
        _ = core.step(.tick, now: chain[0].block.timestamp)
        XCTAssertTrue(core.tree.contains(blockHash: chain[0].cid))
    }

    // MARK: - Stalls and stale events

    func testAStalledRequestDisconnectsThePeerWithoutBanningIt() throws {
        var core = core()
        ready(&core, peer)
        XCTAssertTrue(disconnects(core.step(.tick, now: Self.now + 999)).isEmpty)
        let effects = core.step(.tick, now: Self.now + 1_000)
        XCTAssertEqual(disconnects(effects), [.stalled])
        XCTAssertNil(core.sync.peers[peer])
        // Not a ban: the peer's next session is asked like any other.
        let again = PeerID(key: peer.key, session: peer.session + 1)
        XCTAssertEqual(requests(ready(&core, again)).count, 1)
    }

    func testStaleAnswersAndDeadSessionsAreIgnored() throws {
        var core = core()
        let request = try XCTUnwrap(requests(ready(&core, peer)).first)
        let stale = relay(&core, [entry(chain[0])], from: peer, requestID: request.requestID + 100)
        XCTAssertFalse(core.tree.contains(blockHash: chain[0].cid))
        XCTAssertTrue(disconnects(stale).isEmpty)
        let dead = PeerID(key: peer.key, session: 99)
        _ = relay(&core, [entry(chain[0])], from: dead)
        XCTAssertFalse(core.tree.contains(blockHash: chain[0].cid))
        _ = core.step(.peerGone(peer), now: Self.now)
        XCTAssertTrue(core.step(.tick, now: Self.now + 5_000).isEmpty, "a gone peer's deadline is gone too")
    }

    // MARK: - The pending queue

    func testAQueuedChildLiftsItsParentsPriority() async throws {
        let branch = try await world.branch(from: chain[5], count: 2)
        var core = core()
        ready(&core, peer)
        relay(&core, branch.map { entry($0) }, from: peer)
        let hashes = branch.map { $0.block.proofOfWorkHash() }
        let priorities = core.sync.pending.priorities()
        XCTAssertEqual(priorities[branch[0].cid], min(hashes[0], hashes[1]))
        XCTAssertEqual(priorities[branch[1].cid], hashes[1])
    }

    func testThePendingBudgetEvictsTheLargestHashLeafAndNeverAWeighedHeader() async throws {
        let garbage = world.garbage.compactMap { world.blocks[$0] }.filter { $0.children.entries.isEmpty }
        let sizes = garbage.map { $0.block.toData()!.count }
        let budget = sizes.prefix(4).reduce(0, +)
        var core = core(pendingBudget: budget)
        ready(&core, peer)
        relay(&core, chain[0..<3].map { entry($0) }, from: peer)
        relay(&core, garbage.map { entry($0) }, from: peer)
        XCTAssertLessThanOrEqual(core.sync.pending.bytes, budget)
        for block in chain[0..<3] { XCTAssertTrue(core.tree.contains(blockHash: block.cid)) }
        let kept = Set(core.sync.pending.entries.keys)
        XCTAssertFalse(kept.isEmpty)
        XCTAssertLessThan(kept.count, garbage.count)
        let smallest = garbage.min { $0.block.proofOfWorkHash() < $1.block.proofOfWorkHash() }!
        XCTAssertTrue(kept.contains(smallest.cid), "the smallest hash is never the one evicted")

        // A pending parent is never evicted from under its pending child.
        let branch = try await world.branch(from: chain[5], count: 2)
        var tight = self.core(pendingBudget: branch.map { $0.block.toData()!.count }.reduce(0, +) - 1)
        ready(&tight, peer)
        relay(&tight, branch.map { entry($0) }, from: peer)
        XCTAssertEqual(Set(tight.sync.pending.entries.keys), [branch[0].cid])
    }

    // MARK: - Connected headers weigh at once

    /// Decision 16: a cheap fork from an old block is weighed (a storage
    /// cost) and never selected; so is a near-tip fork.
    func testACheapForkFromAnOldBlockIsWeighedAndNeverSelected() async throws {
        var core = weighed(chain)
        let tip = core.tree.canonicalTip
        let spam = world.spam.compactMap { world.blocks[$0] }
        let nearTip = try await world.branch(from: chain[27], count: 1)
        relay(&core, (spam + nearTip).map { entry($0) }, from: peer)
        for block in spam + nearTip { XCTAssertTrue(core.tree.contains(blockHash: block.cid)) }
        XCTAssertEqual(core.tree.canonicalTip, tip)
        XCTAssertTrue(core.sync.pending.entries.isEmpty, "the pending queue holds only unconnected headers")
    }

    // MARK: - Resume, late blocks, duplicates, resets

    /// A block weighed long after its date (an old side block), whose push
    /// a peer missed (it was offline): the peer's next session resumes from
    /// its cursor and gets it, whatever its timestamp.
    func testALateBlockWithALostPushStillArrives() async throws {
        var server = weighed(Array(chain[0..<10]))
        var client = core()
        try link(&server, &client, session: 1)
        XCTAssertEqual(client.sync.cursors["server"]?.position, 10)
        let late = try await world.branch(from: chain[2], count: 1)
        relay(&server, late.map { entry($0) }, from: peer)
        XCTAssertTrue(late[0].block.timestamp < chain[9].block.timestamp, "dated long before the tip")
        let trips = try link(&server, &client, extra: late, session: 2)
        XCTAssertTrue(client.tree.contains(blockHash: late[0].cid))
        XCTAssertLessThanOrEqual(trips, 3, "one page, one fetch")
    }

    /// The same graph from a second peer costs only its IDs: nothing is
    /// fetched again.
    func testDuplicatesAcrossPeersCostIDsNotObjects() throws {
        var first = weighed(Array(chain[0..<12]))
        var second = Core(tree: world.bootstrap.tree, config: first.config, log: WeighLog(id: "second"))
        ready(&second, peer)
        relay(&second, chain[0..<12].reversed().map { entry($0) }, from: peer)
        var client = core()
        try link(&first, &client, session: 1)
        var fetched = 0
        try link(&second, &client, session: 2, key: "second") { message in
            if case .getData(_, let cids) = message { fetched += cids.count }
        }
        XCTAssertEqual(fetched, 0)
        XCTAssertEqual(client.sync.cursors["second"]?.position, 12, "its whole log applied")
    }

    /// A peer whose log reset (a new log id) is read from 0 again.
    func testAPeerLogResetFallsBackToZero() throws {
        var server = Core(tree: world.bootstrap.tree, config: core().config, log: WeighLog(id: "S1"))
        ready(&server, peer)
        relay(&server, chain[0..<10].map { entry($0) }, from: peer)
        var client = core()
        try link(&server, &client, session: 1)
        XCTAssertEqual(client.sync.cursors["server"], StreamCursor(logID: "S1", position: 10))
        var reset = Core(tree: world.bootstrap.tree, config: core().config, log: WeighLog(id: "S2"))
        ready(&reset, peer)
        relay(&reset, chain[0..<3].map { entry($0) }, from: peer)
        try link(&reset, &client, session: 2)
        // Read from 0: all three, then what the reset peer weighed from us.
        XCTAssertEqual(client.sync.cursors["server"], StreamCursor(logID: "S2", position: reset.sync.log.count))
        XCTAssertEqual(reset.sync.log.count, 10)
    }

    func testPagesAreCappedByBytes() throws {
        let config = CoreConfig(maxPageBytes: 1)
        let entries = chain.prefix(3).map { entry($0) }
        let page = config.page(entries, hasMore: false)
        XCTAssertEqual(page.entries.count, 1, "always at least one header")
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(CoreConfig().page(entries, hasMore: false).entries.count, 3)
    }

    // MARK: - Schedule before fetch, re-sourcing, repair

    func testAnOffScheduleHeaderIsBlamedBeforeItsChildIndexIsFetched() throws {
        var core = weighed(Array(chain[0..<2]))
        ready(&core, other)
        let block = world.blocks[world.lies[.offScheduleTarget]!]!
        let effects = relay(&core, [entry(block, inline: false)], from: other)
        XCTAssertEqual(disconnects(effects), [.proofOfWorkInvalid])
        XCTAssertTrue(fetches(effects).isEmpty)
    }

    func testChildrenAddedAfterAdmissionStayWithinTheBudget() async throws {
        let carrier = try await world.carriers(count: 1, entries: 48)[0]
        let orphanBytes = world.blocks[world.orphan]!.block.toData()!.count
        var core = core(pendingBudget: carrier.block.toData()!.count + orphanBytes + 200)
        ready(&core, peer)
        relay(&core, [entry(world.blocks[world.orphan]!)], from: peer)
        // Held without its child index (the peer never answers the fetch),
        // then the same header again with it inline.
        relay(&core, [entry(carrier, inline: false)], from: peer)
        relay(&core, [entry(carrier)], from: peer)
        XCTAssertLessThanOrEqual(core.sync.pending.bytes, core.config.pendingBudget)
    }

    func testALostAnnouncerHandsTheHeaderToAnotherOne() throws {
        var core = core()
        ready(&core, peer)
        ready(&core, other)
        let orphan = world.blocks[world.orphan]!
        let ask = try XCTUnwrap(parentRequests(relay(&core, [entry(orphan)], from: peer)).first)
        XCTAssertEqual(ask.0, peer)
        relay(&core, [entry(orphan)], from: other)
        let effects = core.step(.peerGone(peer), now: Self.now)
        XCTAssertEqual(parentRequests(effects).first?.0, other, "asked of the next live announcer")
    }

    // MARK: - Round 2: hostile cursors, bounded bookkeeping, heals

    func testACursorPastTheLogServesNothingAndNeverTraps() throws {
        var core = weighed(Array(chain[0..<3]))
        _ = core.step(.peerReady(other), now: Self.now)
        for after: UInt64 in [.max, .max - 1, 1 << 62, 4] {
            let effects = core.step(.received(other, .getStream(requestID: 2, logID: core.sync.log.id, after: after)), now: Self.now)
            guard case .send(_, .stream(let page)) = effects.first else { return XCTFail("\(effects)") }
            XCTAssertEqual(page.entries, [])
        }
        let effects = core.step(.received(other, .getData(requestID: 3, cids: ["bafyunknown", world.genesis.cid])), now: Self.now)
        XCTAssertEqual(served(effects).first?.1, [])
    }

    func testWeighingLeavesTheBookkeepingProportionalToThePendingQueue() throws {
        let core = weighed(chain)
        XCTAssertTrue(core.sync.pending.entries.isEmpty)
        XCTAssertLessThanOrEqual(core.sync.bookkeeping, 16)
    }

    func testFutureDatedHeadersBeyondTheDriftAreDroppedNotHeld() throws {
        var core = core()
        let early = chain[0].block.timestamp - core.config.maxFutureDrift - 1
        ready(&core, peer, at: early)
        let effects = relay(&core, chain[0..<5].map { entry($0) }, from: peer, at: early)
        XCTAssertTrue(disconnects(effects).isEmpty)
        XCTAssertTrue(core.sync.pending.entries.isEmpty)
        XCTAssertEqual(core.sync.bookkeeping, 0)
    }

    /// Zero-work orphan junk dated now floods the budget; eviction takes
    /// the largest hashes, so an honest real-work orphan survives.
    func testZeroWorkJunkCannotDisplaceAnHonestOrphan() async throws {
        let orphan = world.blocks[world.orphan]!
        let withheld = world.blocks[world.withheld]!
        let junk = try await world.junk(on: withheld, timestamp: withheld.block.timestamp + 1, count: 24)
        let size = { (block: SimBlock) in block.block.toData()!.count + block.children.toData()!.count }
        var core = core(pendingBudget: size(orphan) + 3 * size(junk[0]))
        ready(&core, peer)
        ready(&core, other)
        relay(&core, [entry(orphan)], from: peer)
        for block in junk { relay(&core, [entry(block)], from: other) }
        XCTAssertNotNil(core.sync.pending.entries[orphan.cid], "the honest orphan stays")
        XCTAssertLessThan(core.sync.pending.entries.count, junk.count, "junk was evicted")
        XCTAssertLessThanOrEqual(core.sync.pending.bytes, core.config.pendingBudget)
    }

    /// A partition heal: the requester's best chain is a side branch the
    /// server holds but does not select, forked long before the requester's
    /// request time. The pages dated after that time and one ancestors
    /// fetch per missing stretch connect the server's branch,
    /// with no depth cap and no empty page with `hasMore`.
    func testAPartitionHealConvergesThroughAncestorsWithNoDepthCap() async throws {
        var (server, client, side) = try await partitioned()
        let roundTrips = try exchange(&server, &client, side: side, session: 9)
        for block in chain { XCTAssertTrue(client.tree.contains(blockHash: block.cid)) }
        XCTAssertEqual(client.tree.canonicalTip, chain.last?.cid)
        XCTAssertTrue(client.sync.pending.entries.isEmpty)
        XCTAssertLessThanOrEqual(roundTrips, 20, "pages of IDs, batched fetches and bulk ancestors, not one CID per trip")
        print("heal of a 12-block side branch: \(roundTrips) round trips")
    }

    /// The review's repro: a session ends right after one ancestors answer,
    /// leaving the deepest pending header without a live announcer, before
    /// the client's cursor in the server's log. The next sessions' pages
    /// re-announce its descendants, whose announcers join it, so the heal
    /// still completes.
    func testAHealSurvivesSessionsLostAfterOneAncestorsAnswer() async throws {
        var (server, client, side) = try await partitioned()
        try exchange(&server, &client, side: side, session: 9, dropAfterAncestors: true)
        XCTAssertFalse(client.sync.pending.entries.isEmpty, "the first session left a gap")
        try exchange(&server, &client, side: side, session: 10, dropAfterAncestors: true)
        try exchange(&server, &client, side: side, session: 11)
        XCTAssertEqual(client.tree.canonicalTip, chain.last?.cid)
        XCTAssertTrue(client.sync.pending.entries.isEmpty)
    }

    /// A peer that answers an ancestors request without the asked header
    /// does not hold it: the header moves on to its next announcer, and the
    /// peer is never blamed.
    func testAnEmptyAncestorsAnswerCannotPinAHeal() throws {
        var core = core()
        ready(&core, peer)
        ready(&core, other)
        let orphan = world.blocks[world.orphan]!
        let withheld = world.blocks[world.withheld]!
        let ask = try XCTUnwrap(parentRequests(relay(&core, [entry(orphan)], from: peer)).first)
        XCTAssertEqual(ask.0, peer)
        relay(&core, [entry(orphan)], from: other)
        let effects = relay(&core, [], from: peer, requestID: ask.1)
        XCTAssertTrue(disconnects(effects).isEmpty)
        let next = try XCTUnwrap(parentRequests(effects).first)
        XCTAssertEqual(next.0, other, "asked of the next announcer")
        XCTAssertEqual(next.2, withheld.cid)
        relay(&core, [entry(withheld)], from: other, requestID: next.1)
        XCTAssertTrue(core.tree.contains(blockHash: orphan.cid))
    }

    /// A server on the main chain and a client on a 12-block side branch,
    /// whose cursor in the server's log is past the fork: the stream starts
    /// at chain[20], whose ancestors back to the fork the client must fetch.
    private func partitioned() async throws -> (server: Core, client: Core, side: [SimBlock]) {
        let side = try await world.branch(from: chain[9], count: 12)
        let config = CoreConfig(maxHeadersPerPage: 4)
        var server = Core(tree: world.bootstrap.tree, config: config, log: WeighLog(id: "S"))
        ready(&server, peer)
        relay(&server, (chain + side).map { entry($0) }, from: peer)
        XCTAssertEqual(server.tree.canonicalTip, chain.last?.cid)
        // Weigh order is a topological order: past chain[20]'s position the
        // log holds nothing of chain[...19].
        let position = try XCTUnwrap(server.sync.log.entries.firstIndex(of: .header(chain[20].cid)))
        var client = Core(tree: world.bootstrap.tree, config: config, cursors: ["server": StreamCursor(logID: "S", position: UInt64(position))])
        ready(&client, peer)
        relay(&client, (Array(chain[0...9]) + side).map { entry($0) }, from: peer)
        XCTAssertEqual(client.tree.canonicalTip, side.last?.cid)
        _ = client.step(.peerGone(peer), now: Self.now)
        return (server, client, side)
    }

    @discardableResult
    private func exchange(
        _ server: inout Core, _ client: inout Core, side: [SimBlock], session: UInt64, dropAfterAncestors: Bool = false
    ) throws -> Int {
        try link(&server, &client, extra: side, session: session, dropAfterAncestors: dropAfterAncestors)
    }

    /// One session between `client` and `server` (seen by the client as
    /// `key`), every message delivered in order until none is left, or (when
    /// `dropAfterAncestors`) until the first ancestors answer reaches the
    /// client. `observe` sees each client request. Returns the client's
    /// requests.
    @discardableResult
    private func link(
        _ server: inout Core,
        _ client: inout Core,
        extra: [SimBlock] = [],
        session: UInt64,
        key: String = "server",
        dropAfterAncestors: Bool = false,
        observe: (SyncMessage) -> Void = { _ in }
    ) throws -> Int {
        let atServer = PeerID(key: "client", session: session)
        let atClient = PeerID(key: key, session: session)
        var queue: [(toServer: Bool, message: SyncMessage)] = []
        func out(_ effects: [Effect], fromServer: Bool, _ core: inout Core) {
            let to = fromServer ? atServer : atClient
            for effect in effects {
                switch effect {
                case .send(to, let message):
                    queue.append((!fromServer, message))
                case .serveHeaders(to, let token, let id, let cids, let more):
                    let entries = cids.map { cid in entry(world.blocks[cid] ?? extra.first { $0.cid == cid }!) }
                    let page = core.config.page(entries, hasMore: more)
                    queue.append((!fromServer, .headers(HeadersResponse(requestID: id, entries: page.entries, hasMore: page.hasMore))))
                    out(core.step(.headersServed(to, token: token), now: Self.now), fromServer: fromServer, &core)
                default:
                    continue
                }
            }
        }
        out(server.step(.peerReady(atServer), now: Self.now), fromServer: true, &server)
        out(client.step(.peerReady(atClient), now: Self.now), fromServer: false, &client)
        var requests = 0
        var dropping = false
        var delivered = 0
        while !queue.isEmpty, delivered < 1_000 {
            let (toServer, message) = queue.removeFirst()
            delivered += 1
            if toServer {
                switch message {
                case .getStream, .getData: requests += 1
                case .getAncestors:
                    requests += 1
                    dropping = dropAfterAncestors
                case .stream, .headers: break
                }
                observe(message)
                out(server.step(.received(atServer, message), now: Self.now), fromServer: true, &server)
            } else {
                out(client.step(.received(atClient, message), now: Self.now), fromServer: false, &client)
                if dropping, case .headers = message { break }
            }
        }
        _ = client.step(.peerGone(atClient), now: Self.now)
        _ = server.step(.peerGone(atServer), now: Self.now)
        return requests
    }

    /// Crafted requests cost at most a page each: a stream page from 0, over
    /// and over, is answered from memory; content requests, however long
    /// their CID lists, hold the peer to its serving slot (one served, two
    /// queued, the rest dropped) and are cut to a page.
    func testACraftedRequestCostsAPageAndStaysInTheServingSlot() async throws {
        let side = try await world.branch(from: chain[0], count: 25)
        let pageSize = 4
        var server = Core(tree: world.bootstrap.tree, config: CoreConfig(maxHeadersPerPage: pageSize))
        ready(&server, peer)
        relay(&server, (chain + side).map { entry($0) }, from: peer)
        _ = server.step(.peerReady(other), now: Self.now)
        for id in 1...6 {
            _ = server.step(.received(other, .getStream(requestID: UInt64(id), logID: nil, after: 0)), now: Self.now)
            XCTAssertLessThanOrEqual(server.sync.lastServeScanned, pageSize)
        }
        let everything = (chain + side).map(\.cid)
        var tokens: [UInt64] = []
        for id in 1...6 {
            let effects = server.step(.received(other, .getData(requestID: UInt64(id), cids: everything)), now: Self.now)
            for page in served(effects) { XCTAssertEqual(page.1.count, pageSize) }
            tokens += served(effects).map(\.token)
        }
        XCTAssertEqual(tokens.count, 1, "one served request per peer at a time")
        XCTAssertEqual(server.sync.peers[other]?.queued.count, 2)
        var served = 1
        while let token = tokens.popLast() {
            let effects = server.step(.headersServed(other, token: token), now: Self.now)
            tokens += self.served(effects).map(\.token)
            served += self.served(effects).count
        }
        XCTAssertEqual(served, 3, "the rest were dropped")
    }

    /// Sync never reads canonicity: the sync sources (the step, serving,
    /// catch-up, the pending queue, the messages) name no best-chain API.
    /// Only what acts on the best chain may: `ActOn.swift` (the snapshot and
    /// act-on tip), execution and templates.
    func testSyncNeverReadsCanonicity() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LatticeNodeCore")
        for file in ["Core.swift", "Sync.swift", "Messages.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for api in ["isCanonical", "canonicalTip", "canonicalBlockHash", "canonicalChain", "actOnTip", "bestChain"] {
                XCTAssertFalse(text.contains(api), "\(file) reads \(api)")
            }
        }
    }

    /// Zero-work junk dated in the future is off schedule (its target is
    /// not `parent.nextTarget`, checked before the time hold): blamed and
    /// disconnected, never held.
    func testFutureDatedZeroWorkJunkIsBlamedNotHeld() async throws {
        let junk = try await world.junk(on: chain[29], timestamp: Self.now + 3_600_000, count: 1)
        var core = weighed(chain)
        ready(&core, other)
        let effects = relay(&core, [entry(junk[0])], from: other)
        XCTAssertEqual(disconnects(effects), [.proofOfWorkInvalid])
        XCTAssertTrue(core.sync.pending.entries.isEmpty)
    }
}
