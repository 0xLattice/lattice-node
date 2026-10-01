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

    private func requests(_ effects: [Effect]) -> [HeadersRequest] {
        effects.compactMap {
            if case .send(_, .getHeaders(let request)) = $0 { return request }
            return nil
        }
    }

    private func parentRequests(_ effects: [Effect]) -> [(PeerID, UInt64, String)] {
        effects.compactMap {
            if case .send(let to, .getHeader(let id, let cid)) = $0 { return (to, id, cid) }
            return nil
        }
    }

    private func relays(_ effects: [Effect]) -> [(PeerID, [String])] {
        effects.compactMap {
            if case .send(let to, .headers(let response)) = $0, response.requestID == 0 {
                return (to, response.entries.map { try! BlockHeader(node: $0.block).rawCID })
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

    @discardableResult
    private func ready(_ core: inout Core, _ peer: PeerID, at now: Int64 = CoreSyncTests.now) -> [Effect] {
        core.step(.peerReady(peer), now: now)
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

    // MARK: - Catch-up

    func testPeerReadyAsksForHeadersAfterItsLeavesAndArmsADeadline() throws {
        var core = core()
        let effects = ready(&core, peer)
        let request = try XCTUnwrap(requests(effects).first)
        XCTAssertEqual(request.known, [world.genesis.cid])
        XCTAssertNil(request.after)
        XCTAssertEqual(core.sync.peers[peer]?.catchUp?.deadline, Self.now + 1_000)
        guard case .wakeAt(let wake) = effects.last else { return XCTFail("\(effects)") }
        XCTAssertEqual(wake, Self.now + 1_000)
    }

    func testAPagePersistsPublishesRelaysAndContinuesAfterItsLastHeader() throws {
        var core = core()
        let request = try XCTUnwrap(requests(ready(&core, peer)).first)
        ready(&core, other)
        let effects = relay(&core, chain[0..<4].map { entry($0) }, from: peer, requestID: request.requestID, hasMore: true)

        guard case .persist(let batch) = effects.first else { return XCTFail("\(effects)") }
        XCTAssertEqual(batch.headers.map(\.blockCID), chain[0..<4].map(\.cid))
        for fact in batch.facts.flatMap(\.facts) {
            switch fact {
            case .block, .work: continue
            case .validation, .exclusion: XCTFail("a weighed-only header issued \(fact)")
            }
        }
        guard case .publish(let snapshot) = effects.dropFirst().first else { return XCTFail("\(effects)") }
        XCTAssertEqual(snapshot.bestHeaderTip, chain[3].cid)
        XCTAssertEqual(snapshot.actOnTip, world.genesis.cid, "no header is executed")
        // Relayed to every ready peer but its source, right after publish.
        guard case .send(other, .headers(let relayed)) = effects.dropFirst(2).first else { return XCTFail("\(effects)") }
        XCTAssertEqual(relayed.requestID, 0)
        XCTAssertFalse(relays(effects).contains { $0.0 == peer })
        let next = try XCTUnwrap(requests(effects).first)
        XCTAssertEqual(next.known.first, chain[3].cid, "the locator starts at the tip")
        XCTAssertEqual(next.after, HeaderKey(height: 4, cid: chain[3].cid))
    }

    func testAPageThatDoesNotClimbEndsTheExchangeWithoutBlame() throws {
        var core = core()
        let request = try XCTUnwrap(requests(ready(&core, peer)).first)
        var effects = relay(&core, chain[0..<4].map { entry($0) }, from: peer, requestID: request.requestID, hasMore: true)
        let next = try XCTUnwrap(requests(effects).first)
        // The same page again: the cursor would not climb.
        effects = relay(&core, chain[0..<4].map { entry($0) }, from: peer, requestID: next.requestID, hasMore: true)
        XCTAssertTrue(requests(effects).isEmpty)
        XCTAssertTrue(disconnects(effects).isEmpty)
        XCTAssertNil(core.sync.peers[peer]?.catchUp)
    }

    func testServingListsTheWholeWeighedSubgraphAfterTheKnownCIDsPaged() async throws {
        let side = try await world.branch(from: chain[1], count: 2)
        var core = weighed(Array(chain[0..<6]) + side)
        let known = chain[3].cid
        var effects = core.step(.received(other, .getHeaders(HeadersRequest(
            requestID: 7, known: [known, "bafyunknown"], after: nil
        ))), now: Self.now)
        XCTAssertTrue(served(effects).isEmpty, "a peer that is not ready is not served")
        ready(&core, other)
        effects = core.step(.received(other, .getHeaders(HeadersRequest(
            requestID: 7, known: [known, "bafyunknown"], after: nil
        ))), now: Self.now)
        let expected = (side + chain[4..<6])
            .map { HeaderKey(height: $0.height, cid: $0.cid) }
            .sorted()
        let page = try XCTUnwrap(served(effects).first)
        XCTAssertEqual(page.0, 7)
        XCTAssertEqual(page.1, expected.map(\.cid), "side branches included, ancestors of known excluded")
        XCTAssertFalse(page.2)

        _ = core.step(.headersServed(other, token: page.token), now: Self.now)
        effects = core.step(.received(other, .getHeaders(HeadersRequest(
            requestID: 8, known: [known], after: expected[1]
        ))), now: Self.now)
        XCTAssertEqual(served(effects).first?.1, expected.dropFirst(2).map(\.cid))
    }

    func testOnlyOneServedPagePerPeerIsOutstandingAndTheNextWaitsForIt() throws {
        var core = weighed(Array(chain[0..<3]))
        ready(&core, other)
        let first = core.step(.received(other, .getHeaders(HeadersRequest(requestID: 1, known: [], after: nil))), now: Self.now)
        XCTAssertEqual(served(first).count, 1)
        let second = core.step(.received(other, .getHeaders(HeadersRequest(requestID: 2, known: [], after: nil))), now: Self.now)
        XCTAssertTrue(served(second).isEmpty)
        let sent = core.step(.headersServed(other, token: served(first)[0].token), now: Self.now)
        XCTAssertEqual(served(sent).first?.0, 2)
        // A `getHeader` takes the same slot.
        let third = core.step(.received(other, .getHeader(requestID: 3, cid: chain[0].cid)), now: Self.now)
        XCTAssertTrue(served(third).isEmpty)
        let after = core.step(.headersServed(other, token: served(sent)[0].token), now: Self.now)
        XCTAssertEqual(served(after).first?.1, [chain[0].cid])
    }

    func testCatchUpFromAnotherCoreReplicatesItsWholeGraph() async throws {
        let side = try await world.branch(from: chain[4], count: 3)
        var server = weighed(chain + side, pageSize: 5)
        var client = core(pageSize: 5)
        let serverSide = PeerID(key: "client", session: 9)
        let clientSide = PeerID(key: "server", session: 9)
        ready(&server, serverSide)
        var toServer = ready(&client, clientSide)
        for _ in 0..<50 {
            guard let request = requests(toServer).first else { break }
            let effects = server.step(.received(serverSide, .getHeaders(request)), now: Self.now)
            let page = try XCTUnwrap(served(effects).first)
            _ = server.step(.headersServed(serverSide, token: page.token), now: Self.now)
            let entries = page.1.map { cid in entry(world.blocks[cid] ?? side.first { $0.cid == cid }!) }
            toServer = relay(&client, entries, from: clientSide, requestID: page.0, hasMore: page.2)
        }
        XCTAssertEqual(TreeDigest(client.tree), TreeDigest(server.tree))
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
        XCTAssertEqual(relays(effects).first?.0, peer)
        XCTAssertEqual(Set(relays(effects).first?.1 ?? []), Set(invalid.map(\.cid)), "excluded headers are relayed too")
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

    func testAnUnknownParentIsAskedByCIDOfTheSender() throws {
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
                XCTAssertEqual(relays(fetched).first?.0, peer)
                let relayed = fetched.compactMap { effect -> HeaderEntry? in
                    if case .send(_, .headers(let response)) = effect { return response.entries.first }
                    return nil
                }.first
                XCTAssertNil(relayed?.children, "too big to travel inline")
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

    // MARK: - Locators and the indexed serve

    func testTheLocatorIsBitcoinStyleAndBounded() async throws {
        var core = weighed(chain)
        for index in 0..<70 {
            let side = try await world.branch(from: chain[index % 29], count: 1, interval: 500 + Int64(index))
            relay(&core, side.map { entry($0) }, from: peer)
        }
        XCTAssertGreaterThan(core.index.leaves.count, 64)
        let request = try XCTUnwrap(requests(core.step(.peerReady(other), now: Self.now)).first)
        XCTAssertEqual(request.known.count, HeadersRequest.maximumKnown)
        XCTAssertEqual(request.known.first, core.tree.canonicalTip, "the best chain from its tip")
        XCTAssertTrue(request.known.prefix(10).allSatisfy { core.tree.isCanonical(hash: $0) })
        XCTAssertTrue(request.known.contains(world.genesis.cid))
    }

    /// A server one block behind the requester answers with nothing, and
    /// examines O(window) index entries, not the graph.
    func testTheOneBlockRaceCostsNoHistory() throws {
        var requester = weighed(chain)
        var server = Core(tree: world.bootstrap.tree, config: CoreConfig(sideBranchWindow: 2))
        ready(&server, peer)
        relay(&server, chain.dropLast().map { entry($0) }, from: peer)
        let request = try XCTUnwrap(requests(requester.step(.peerReady(other), now: Self.now)).first)
        ready(&server, other)
        let effects = server.step(.received(other, .getHeaders(request)), now: Self.now)
        XCTAssertEqual(served(effects).first?.1, [])
        XCTAssertLessThanOrEqual(server.sync.lastServeScanned, 8)
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

    func testEachPeerIsAskedForACatchUpAgainAsARepairPath() throws {
        var core = core()
        let request = try XCTUnwrap(requests(ready(&core, peer)).first)
        relay(&core, [], from: peer, requestID: request.requestID)
        let later = Self.now + core.config.catchUpInterval
        XCTAssertTrue(requests(core.step(.tick, now: later - 1)).isEmpty)
        XCTAssertEqual(requests(core.step(.tick, now: later)).count, 1)
    }

    // MARK: - Round 2: hostile cursors, bounded bookkeeping, FindFork

    func testACursorPastAnyHeightServesNothingAndNeverTraps() throws {
        var core = weighed(Array(chain[0..<3]))
        ready(&core, other)
        let effects = core.step(.received(other, .getHeaders(HeadersRequest(
            requestID: 1, known: [], after: HeaderKey(height: .max, cid: "x")
        ))), now: Self.now)
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

    /// A requester on a branch the server holds but does not select: the
    /// server forks from the highest locator entry on ITS best chain, so the
    /// requester still gets the server's whole best chain past the fork.
    func testTheServerForksFromItsOwnBestChainAfterADeepReorg() async throws {
        let side = try await world.branch(from: chain[9], count: 5)
        // The side branch is weighed while it is the best chain, then the
        // main chain overtakes it.
        var server = Core(tree: world.bootstrap.tree, config: CoreConfig(sideBranchWindow: 2))
        ready(&server, peer)
        relay(&server, (chain + side).map { entry($0) }, from: peer)
        var requester = weighed(Array(chain[0...9]) + side)
        XCTAssertEqual(requester.tree.canonicalTip, side.last?.cid)
        XCTAssertFalse(server.tree.isCanonical(hash: side.last!.cid))
        let request = try XCTUnwrap(requests(requester.step(.peerReady(other), now: Self.now)).first)
        ready(&server, other)
        let page = try XCTUnwrap(served(server.step(.received(other, .getHeaders(request)), now: Self.now)).first)
        XCTAssertEqual(page.1.first, chain[10].cid, "from the fork, not from the requester's tip")
    }

    /// Zero-work junk dated in the near future is held, and held headers
    /// are evicted before anything else: it cannot displace an honest orphan.
    func testFutureDatedJunkCannotDisplaceHonestOrphans() async throws {
        let orphan = world.blocks[world.orphan]!
        let junk = try await world.junk(on: chain[29], timestamp: Self.now + 3_600_000, count: 12)
        let size = { (block: SimBlock) in block.block.toData()!.count + block.children.toData()!.count }
        var core = core(pendingBudget: size(orphan) + 2 * size(junk[0]))
        ready(&core, peer)
        ready(&core, other)
        relay(&core, chain.map { entry($0) }, from: peer)
        relay(&core, [entry(orphan)], from: peer)
        for block in junk { relay(&core, [entry(block)], from: other) }
        XCTAssertNotNil(core.sync.pending.entries[orphan.cid], "the honest orphan stays")
        XCTAssertLessThanOrEqual(core.sync.pending.bytes, core.config.pendingBudget)
    }

    /// A crafted locator of deep side entries, or a cursor far below the
    /// fork, costs no more than the scan budget.
    func testCraftedLocatorsCostNoMoreThanTheScanBudget() async throws {
        let side = try await world.branch(from: chain[0], count: 25)
        var server = Core(tree: world.bootstrap.tree, config: CoreConfig(maxHeadersPerPage: 4, sideBranchWindow: 2))
        ready(&server, peer)
        relay(&server, (chain + side).map { entry($0) }, from: peer)
        ready(&server, other)
        let budget = server.config.serveScanBudget
        var token: UInt64?
        for (id, request) in [
            HeadersRequest(requestID: 1, known: side.suffix(64).map(\.cid) + [chain.last!.cid], after: nil),
            HeadersRequest(requestID: 2, known: [chain.last!.cid], after: HeaderKey(height: 0, cid: "")),
        ].enumerated() {
            if let token { _ = server.step(.headersServed(other, token: token), now: Self.now) }
            let page = try XCTUnwrap(served(server.step(.received(other, .getHeaders(request)), now: Self.now)).first)
            token = page.token
            XCTAssertLessThanOrEqual(server.sync.lastServeScanned, budget, "request \(id)")
        }
    }
}
