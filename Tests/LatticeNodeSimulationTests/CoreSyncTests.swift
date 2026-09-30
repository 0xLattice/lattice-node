import Lattice
import LatticeNodeCore
import LatticeNodeSim
import UInt256
import XCTest

/// `Core.step` header sync, one event at a time.
final class CoreSyncTests: XCTestCase {
    private static let now = World.genesisTime + 1_000_000
    private let peer = PeerID(key: "peer", session: 1)
    private var world: World!
    private var chain: [SimBlock] = []

    override func setUp() async throws {
        var rng = SplitMix64(state: 0x5_1C)
        world = try await World.generate(rng: &rng, honestBlocks: 30, forkProbability: 0, spamBlocks: 6)
        chain = world.honest.compactMap { world.blocks[$0] }
    }

    private func core(pageSize: Int = 4) -> Core {
        Core(
            tree: world.bootstrap.tree,
            spec: world.spec,
            config: CoreConfig(maxHeadersPerPage: pageSize, headersTimeout: 1_000)
        )
    }

    private func entries(_ blocks: ArraySlice<SimBlock>) -> [HeaderEntry] {
        blocks.map { HeaderEntry(block: $0.block, children: $0.children) }
    }

    private func requests(_ effects: [Effect]) -> [HeadersRequest] {
        effects.compactMap {
            if case .send(_, .getHeaders(let request)) = $0 { return request }
            return nil
        }
    }

    private func disconnects(_ effects: [Effect]) -> [DisconnectReason] {
        effects.compactMap {
            if case .disconnect(_, let reason) = $0 { return reason }
            return nil
        }
    }

    /// A core that has asked `peer` for headers; returns the request.
    private func ready(_ core: inout Core) throws -> HeadersRequest {
        try XCTUnwrap(requests(core.step(.peerReady(peer), now: Self.now)).first)
    }

    private func answer(
        _ core: inout Core,
        _ request: HeadersRequest,
        _ entries: [HeaderEntry],
        hasMore: Bool = false
    ) -> [Effect] {
        core.step(.received(peer, .headers(HeadersResponse(
            requestID: request.requestID, entries: entries, hasMore: hasMore
        ))), now: Self.now)
    }

    func testPeerReadyAsksFromGenesisAndArmsATimeout() throws {
        var core = core()
        let effects = core.step(.peerReady(peer), now: Self.now)
        let request = try XCTUnwrap(requests(effects).first)
        XCTAssertEqual(request.locator, [world.genesis.cid])
        XCTAssertEqual(core.sync.peers[peer]?.inFlight?.deadline, Self.now + 1_000)
        guard case .wakeAt(let wake) = effects.last else { return XCTFail("\(effects)") }
        XCTAssertEqual(wake, Self.now + 1_000)
        // A second trigger while one request is in flight asks nothing.
        let announce = core.step(.received(peer, .announce(blockCID: chain[9].cid, height: 10)), now: Self.now)
        XCTAssertTrue(requests(announce).isEmpty)
    }

    func testAFullPagePersistsBeforePublishingAndContinuesFromItsLastHeader() throws {
        var core = core()
        let request = try ready(&core)
        let effects = answer(&core, request, entries(chain[0..<4]), hasMore: true)

        guard case .persist(let batch) = effects.first else { return XCTFail("\(effects)") }
        XCTAssertEqual(batch.headers.map(\.blockCID), chain[0..<4].map(\.cid))
        XCTAssertEqual(batch.facts.count, 4)
        for facts in batch.facts {
            for fact in facts.facts {
                switch fact {
                case .block, .work: continue
                case .validation, .exclusion: XCTFail("a weighed-only header issued \(fact)")
                }
            }
        }
        guard case .publish(let snapshot) = effects.dropFirst().first else { return XCTFail("\(effects)") }
        XCTAssertEqual(snapshot.bestHeaderTip, chain[3].cid)
        XCTAssertEqual(snapshot.bestHeaderHeight, 4)
        XCTAssertEqual(snapshot.actOnTip, world.genesis.cid, "no header is executed")
        XCTAssertEqual(requests(effects).first?.locator.first, chain[3].cid)
    }

    func testTheLocatorIsLogSpacedBoundedAndEndsAtGenesis() throws {
        var core = core(pageSize: 100)
        let request = try ready(&core)
        let effects = answer(&core, request, entries(chain[...]))
        XCTAssertEqual(core.tree.canonicalTip, chain.last?.cid)
        _ = effects
        let next = core.step(.received(peer, .announce(blockCID: "unknown", height: 99)), now: Self.now)
        let locator = try XCTUnwrap(requests(next).first).locator
        XCTAssertLessThanOrEqual(locator.count, HeadersRequest.maximumLocatorEntries)
        XCTAssertEqual(Array(locator.prefix(10)), chain.suffix(10).reversed().map(\.cid))
        XCTAssertEqual(locator.last, world.genesis.cid)
    }

    func testPagesThatDoNotConnectDisconnectAtTheLimit() throws {
        var core = core()
        var request = try ready(&core)
        let orphan = try XCTUnwrap(world.blocks[world.orphan])
        for _ in 1..<core.config.maxUnconnectingHeaders {
            let effects = answer(&core, request, entries([orphan][...]))
            XCTAssertTrue(disconnects(effects).isEmpty)
            request = try XCTUnwrap(requests(effects).first, "ask again from the best chain")
        }
        let effects = answer(&core, request, entries([orphan][...]))
        XCTAssertEqual(disconnects(effects), [.malformed])
        XCTAssertNil(core.sync.peers[peer])
    }

    func testProvablyWrongHeadersDisconnect() throws {
        let fake = ChildIndex(entries: ["Liar": try BlockHeader(node: world.genesis.block)])
        var forgedNonce = chain[0].block.nonce &+ 1
        while ChainTree.rootWork(of: replacing(chain[0].block, nonce: forgedNonce)) != nil { forgedNonce &+= 1 }
        let lies: [String: [HeaderEntry]] = [
            "failed proof-of-work": [HeaderEntry(block: replacing(chain[0].block, nonce: forgedNonce), children: chain[0].children)],
            "mismatched children": [HeaderEntry(block: chain[0].block, children: fake)],
            "broken chain": [chain[0], chain[2]].map { HeaderEntry(block: $0.block, children: $0.children) },
        ]
        for (lie, page) in lies.sorted(by: { $0.key < $1.key }) {
            var core = core()
            let request = try ready(&core)
            let effects = answer(&core, request, page)
            XCTAssertEqual(disconnects(effects), [.malformed], lie)
            XCTAssertTrue(core.sync.peers.isEmpty, lie)
        }
    }

    func testStaleAnswersAndDeadSessionsAreIgnored() throws {
        var core = core()
        let request = try ready(&core)
        let stale = HeadersResponse(requestID: request.requestID + 7, entries: entries(chain[0..<2]), hasMore: false)
        XCTAssertFalse(core.step(.received(peer, .headers(stale)), now: Self.now).contains {
            if case .persist = $0 { return true }
            return false
        })
        let oldSession = PeerID(key: peer.key, session: 0)
        let fresh = HeadersResponse(requestID: request.requestID, entries: entries(chain[0..<2]), hasMore: false)
        _ = core.step(.received(oldSession, .headers(fresh)), now: Self.now)
        XCTAssertFalse(core.tree.contains(blockHash: chain[0].cid), "a dead session's page is not read")

        _ = core.step(.peerGone(peer), now: Self.now)
        XCTAssertTrue(core.sync.peers.isEmpty)
        XCTAssertTrue(core.sync.awaitingChildIndex.isEmpty)
        _ = core.step(.received(peer, .headers(fresh)), now: Self.now)
        XCTAssertFalse(core.tree.contains(blockHash: chain[0].cid))
    }

    func testASilentPeerIsAskedAgainAtItsDeadlineNeverBlamed() throws {
        var core = core()
        let request = try ready(&core)
        XCTAssertTrue(requests(core.step(.tick, now: Self.now + 999)).isEmpty)
        let effects = core.step(.tick, now: Self.now + 1_000)
        let again = try XCTUnwrap(requests(effects).first)
        XCTAssertNotEqual(again.requestID, request.requestID)
        XCTAssertTrue(disconnects(effects).isEmpty)
    }

    func testServesTheBestHeaderChainAfterTheLocatorForkPoint() throws {
        var core = core()
        var request = try ready(&core)
        for start in stride(from: 0, to: 12, by: 4) {
            let effects = answer(&core, request, entries(chain[start..<start + 4]), hasMore: true)
            request = try XCTUnwrap(requests(effects).first)
        }
        func serve(_ locator: [String]) -> [Effect] {
            defer { _ = core.step(.headersServed(peer), now: Self.now) }
            return core.step(.received(peer, .getHeaders(HeadersRequest(requestID: 42, locator: locator))), now: Self.now)
        }
        guard case .serveHeaders(_, 42, let cids, let hasMore) = serve([chain[2].cid, world.genesis.cid]).first else {
            return XCTFail("no page")
        }
        XCTAssertEqual(cids, chain[3..<7].map(\.cid))
        XCTAssertTrue(hasMore)
        guard case .serveHeaders(_, _, let fromStart, _) = serve(["unknown"]).first else { return XCTFail("no page") }
        XCTAssertEqual(fromStart, chain[0..<4].map(\.cid))
        guard case .serveHeaders(_, _, let atTip, let more) = serve([chain[11].cid]).first else { return XCTFail("no page") }
        XCTAssertTrue(atTip.isEmpty)
        XCTAssertFalse(more)
        let tooLong = Array(repeating: world.genesis.cid, count: HeadersRequest.maximumLocatorEntries + 1)
        XCTAssertEqual(disconnects(serve(tooLong)), [.malformed])
    }

    private func ready(_ core: inout Core, _ peer: PeerID, at now: Int64 = CoreSyncTests.now) throws -> HeadersRequest {
        try XCTUnwrap(requests(core.step(.peerReady(peer), now: now)).first)
    }

    private func answer(
        _ core: inout Core,
        _ peer: PeerID,
        _ request: HeadersRequest,
        _ entries: [HeaderEntry],
        hasMore: Bool = false,
        at now: Int64 = CoreSyncTests.now
    ) -> [Effect] {
        core.step(.received(peer, .headers(HeadersResponse(
            requestID: request.requestID, entries: entries, hasMore: hasMore
        ))), now: now)
    }

    private func fetches(_ effects: [Effect]) -> [String] {
        effects.compactMap {
            if case .fetchByCID(_, let cid) = $0 { return cid }
            return nil
        }
    }

    func testAChildIndexTheTreeAlreadyCommitsIsReusedWithoutAFetch() throws {
        var core = core()
        let request = try ready(&core)
        let effects = answer(&core, request, [HeaderEntry(block: chain[0].block, children: nil)])
        XCTAssertTrue(fetches(effects).isEmpty)
        XCTAssertTrue(core.tree.contains(blockHash: chain[0].cid))
    }

    func testAnOmittedChildIndexIsFetchedByCIDAndVerified() async throws {
        let carriers = try await world.carriers(count: 1)
        let carrier = try XCTUnwrap(carriers.first)
        for honest in [false, true] {
            var core = core()
            let request = try ready(&core)
            let effects = answer(&core, request, [HeaderEntry(block: carrier.block, children: nil)])
            let cid = carrier.block.children.rawCID
            XCTAssertEqual(fetches(effects), [cid])
            let bytes = honest ? carrier.children : ChildIndex(entries: ["Liar": try BlockHeader(node: world.genesis.block)])
            let fetched = core.step(.childIndexFetched(peer, cid: cid, bytes), now: Self.now)
            if honest {
                XCTAssertTrue(core.tree.contains(blockHash: carrier.cid))
                guard case .persist = fetched.first else { return XCTFail("\(fetched)") }
                XCTAssertEqual(requests(fetched).first?.locator.first, carrier.cid)
            } else {
                XCTAssertEqual(disconnects(fetched), [.malformed])
                XCTAssertFalse(core.tree.contains(blockHash: carrier.cid))
            }
        }
    }

    func testAMissingChildIndexIsAvailabilityNotBlame() async throws {
        let carriers = try await world.carriers(count: 1)
        let carrier = try XCTUnwrap(carriers.first)
        var core = core()
        let request = try ready(&core)
        _ = answer(&core, request, [HeaderEntry(block: carrier.block, children: nil)])
        let effects = core.step(.childIndexFetched(peer, cid: carrier.block.children.rawCID, nil), now: Self.now)
        XCTAssertTrue(disconnects(effects).isEmpty)
        XCTAssertEqual(core.sync.peers[peer]?.retryAt, Self.now + core.config.headersTimeout, "not left idle")
        XCTAssertNotNil(requests(core.step(.tick, now: Self.now + core.config.headersTimeout)).first)
    }

    func testNonConnectingHeadersWithoutChildrenStillCountAgainstThePeer() throws {
        var core = core()
        var request = try ready(&core)
        let orphan = try XCTUnwrap(world.blocks[world.orphan])
        let page = [HeaderEntry(block: orphan.block, children: nil)]
        for _ in 1..<core.config.maxUnconnectingHeaders {
            let effects = answer(&core, request, page)
            XCTAssertTrue(fetches(effects).isEmpty, "no fetch for a header that does not connect")
            request = try XCTUnwrap(requests(effects).first)
        }
        XCTAssertEqual(disconnects(answer(&core, request, page)), [.malformed])
        XCTAssertTrue(core.sync.awaitingChildIndex.isEmpty)
    }

    func testAHeaderFailingProofOfWorkCostsNoFetch() async throws {
        let carriers = try await world.carriers(count: 1)
        let carrier = try XCTUnwrap(carriers.first)
        var nonce = carrier.block.nonce &+ 1
        while ChainTree.rootWork(of: replacing(carrier.block, nonce: nonce)) != nil { nonce &+= 1 }
        var core = core()
        let request = try ready(&core)
        let effects = answer(&core, request, [HeaderEntry(block: replacing(carrier.block, nonce: nonce), children: nil)])
        XCTAssertTrue(fetches(effects).isEmpty)
        XCTAssertEqual(disconnects(effects), [.malformed])
    }

    /// 64 sybils fill every child-index wait with fetches they never answer;
    /// an honest peer's page is re-asked once those waits expire, not dropped.
    func testSixtyFourSybilsCannotStallHonestSync() async throws {
        let carriers = try await world.carriers(count: 65)
        var core = core()
        XCTAssertEqual(core.config.maxAwaitingChildIndex, 64)
        for index in 0..<64 {
            let sybil = PeerID(key: "sybil\(index)", session: 1)
            let request = try ready(&core, sybil)
            let effects = answer(&core, sybil, request, [HeaderEntry(block: carriers[index].block, children: nil)])
            XCTAssertEqual(fetches(effects).count, 1)
        }
        XCTAssertEqual(core.sync.awaitingChildIndex.count, 64)

        let honest = carriers[64]
        let request = try ready(&core, peer)
        var effects = answer(&core, peer, request, [HeaderEntry(block: honest.block, children: nil)])
        XCTAssertTrue(fetches(effects).isEmpty, "every wait is taken")
        let retry = try XCTUnwrap(core.sync.peers[peer]?.retryAt)
        XCTAssertEqual(retry, Self.now + core.config.headersTimeout)

        effects = core.step(.tick, now: retry)
        XCTAssertTrue(effects.contains {
            if case .send(peer, .getHeaders) = $0 { return true }
            return false
        }, "the honest peer is asked again")
        XCTAssertTrue(core.sync.awaitingChildIndex.isEmpty, "the sybils' waits expired")
        let honestRequest = try XCTUnwrap(core.sync.peers[peer]?.inFlight?.requestID)
        effects = core.step(.received(peer, .headers(HeadersResponse(
            requestID: honestRequest, entries: [HeaderEntry(block: honest.block, children: nil)], hasMore: false
        ))), now: retry)
        XCTAssertEqual(fetches(effects), [honest.block.children.rawCID])
        _ = core.step(.childIndexFetched(peer, cid: honest.block.children.rawCID, honest.children), now: retry)
        XCTAssertTrue(core.tree.contains(blockHash: honest.cid))
    }

    func testAHeaderFromTheFutureIsAskedAgainAtItsTimestamp() throws {
        var core = core()
        let early = chain[0].block.timestamp - 500
        let request = try ready(&core, peer, at: early)
        let effects = answer(&core, peer, request, entries(chain[0..<1]), at: early)
        XCTAssertFalse(core.tree.contains(blockHash: chain[0].cid))
        XCTAssertTrue(disconnects(effects).isEmpty)
        guard case .wakeAt(let wake) = effects.last else { return XCTFail("\(effects)") }
        XCTAssertEqual(wake, chain[0].block.timestamp)
        let again = try XCTUnwrap(requests(core.step(.tick, now: wake)).first)
        _ = answer(&core, peer, again, entries(chain[0..<1]), at: wake)
        XCTAssertTrue(core.tree.contains(blockHash: chain[0].cid))
    }

    func testOnlyOneServedPagePerPeerIsOutstanding() throws {
        var core = core()
        _ = try ready(&core)
        func ask(_ id: UInt64) -> [Effect] {
            core.step(.received(peer, .getHeaders(HeadersRequest(requestID: id, locator: [world.genesis.cid]))), now: Self.now)
        }
        func served(_ effects: [Effect]) -> Bool {
            effects.contains { if case .serveHeaders = $0 { true } else { false } }
        }
        XCTAssertTrue(served(ask(1)))
        let extra = ask(2)
        XCTAssertFalse(served(extra), "a second request while one is outstanding is dropped")
        XCTAssertTrue(disconnects(extra).isEmpty, "and never blamed")
        _ = core.step(.headersServed(peer), now: Self.now)
        XCTAssertTrue(served(ask(3)))
    }

    private func relayed(_ effects: [Effect]) -> [(PeerID, String)] {
        effects.compactMap {
            guard case .send(let to, .headers(let page)) = $0, page.requestID == 0,
                  let first = page.entries.first,
                  let cid = try? BlockHeader(node: first.block).rawCID else { return nil }
            return (to, cid)
        }
    }

    /// BIP130-style relay: an unsolicited single header whose parent is held
    /// is weighed through the same path and relayed to every other peer.
    func testARelayedHeaderIsWeighedAndRelayedToEveryOtherPeer() throws {
        var core = core()
        let other = PeerID(key: "other", session: 1)
        _ = try ready(&core)
        _ = try ready(&core, other)
        func push(_ entries: [HeaderEntry], from sender: PeerID) -> [Effect] {
            core.step(.received(sender, .headers(HeadersResponse(requestID: 0, entries: entries, hasMore: false))), now: Self.now)
        }
        let effects = push(entries(chain[0..<1]), from: peer)
        guard case .persist = effects.first else { return XCTFail("\(effects)") }
        let sent = relayed(effects)
        XCTAssertEqual(sent.map(\.0), [other], "relayed to every peer but its source")
        XCTAssertEqual(sent.map(\.1), [chain[0].cid])
        XCTAssertTrue(relayed(push(entries(chain[0..<1]), from: other)).isEmpty, "a held header is not relayed again")

        XCTAssertFalse(push(entries(chain[1..<3]), from: peer).contains {
            if case .persist = $0 { return true }
            return false
        }, "only a single header is read unsolicited")
        XCTAssertFalse(core.tree.contains(blockHash: chain[1].cid))

        // A relayed header we cannot connect is a chain we lack: never a
        // strike, and the getHeaders it asks with is bounded by the one
        // request in flight per peer.
        let inFlight = try XCTUnwrap(core.sync.peers[peer]?.inFlight)
        _ = core.step(.received(peer, .headers(HeadersResponse(
            requestID: inFlight.requestID, entries: [], hasMore: false
        ))), now: Self.now)
        XCTAssertNil(core.sync.peers[peer]?.inFlight)
        var asked = 0
        for _ in 0..<5 {
            let gap = push(entries(chain[5..<6]), from: peer)
            XCTAssertTrue(disconnects(gap).isEmpty)
            asked += requests(gap).count
        }
        XCTAssertEqual(asked, 1, "one getHeaders in flight, however many relays")
        XCTAssertEqual(core.sync.peers[peer]?.unconnecting, 0)
    }

    /// The ASERT-saturation fork: its on-schedule headers weigh, every header
    /// whose target is easier than 1/16 of the tip's is dropped — not stored,
    /// not relayed, not blamed — and the peer's sync goes on.
    func testSpamUnderTheTargetFloorIsDroppedWithoutBlame() throws {
        var core = core(pageSize: 100)
        let request = try ready(&core)
        _ = answer(&core, request, entries(chain[0..<10]))
        let spammer = PeerID(key: "spammer", session: 1)
        let spamRequest = try ready(&core, spammer)
        let spam = world.spam.compactMap { world.blocks[$0] }
        XCTAssertGreaterThan(spam.count, 2, "saturated headers follow the on-schedule two")
        let effects = core.step(.received(spammer, .headers(HeadersResponse(
            requestID: spamRequest.requestID,
            entries: spam.map { HeaderEntry(block: $0.block, children: $0.children) },
            hasMore: true
        ))), now: Self.now)
        XCTAssertTrue(core.tree.contains(blockHash: spam[0].cid))
        XCTAssertTrue(core.tree.contains(blockHash: spam[1].cid))
        XCTAssertFalse(spam.dropFirst(2).contains { core.tree.contains(blockHash: $0.cid) })
        XCTAssertTrue(disconnects(effects).isEmpty, "the floor never blames")
        XCTAssertTrue(requests(effects).isEmpty, "the exchange ends: nothing continues from a dropped header")
        XCTAssertEqual(core.sync.peers[spammer]?.retryAt, Self.now + core.config.headersTimeout,
                       "the peer is asked again, from our best chain, after a timeout")
        XCTAssertFalse(relayed(effects).contains { !Set(spam.prefix(2).map(\.cid)).contains($0.1) })
    }

    /// Catch-up from genesis on a chain whose difficulty rose 16x and more:
    /// each header is compared with the node's best tip as it advances, so
    /// the early, easier headers are never under the floor.
    func testCatchUpFromGenesisWorksAcrossAHardeningChain() async throws {
        var rng = SplitMix64(state: 0xFA57)
        let fast = try await World.generate(
            rng: &rng, honestBlocks: 50, forkProbability: 0, spamBlocks: 2, honestInterval: 1
        )
        let blocks = fast.honest.compactMap { fast.blocks[$0] }
        let first = try XCTUnwrap(blocks.first?.block.target)
        let last = try XCTUnwrap(blocks.last?.block.target)
        XCTAssertLessThanOrEqual(last.multipliedReportingOverflow(by: 16).partialValue, first, "the chain hardened at least 16x")
        var core = Core(tree: fast.bootstrap.tree, spec: fast.spec, config: CoreConfig(maxHeadersPerPage: 100))
        let request = try ready(&core)
        _ = answer(&core, request, blocks.map { HeaderEntry(block: $0.block, children: $0.children) })
        XCTAssertEqual(core.tree.canonicalTip, blocks.last?.cid)
    }

    /// The page after the first locator entry on `chain`: what an honest
    /// peer whose best chain is `chain` serves.
    private func servedPage(of chain: [SimBlock], after locator: [String], limit: Int) -> (entries: [HeaderEntry], hasMore: Bool) {
        let fork = locator.lazy.compactMap { hash in chain.firstIndex { $0.cid == hash } }.first ?? 0
        let rest = chain.dropFirst(fork + 1)
        return (entries(rest.prefix(limit)), rest.count > limit)
    }

    /// An honest peer whose best chain runs through headers we hold but do
    /// not select walks us to its new blocks, with no strike.
    func testAWalkThroughHeldButUnselectedHeadersReachesThePeersNewBlocks() async throws {
        var core = core(pageSize: 4)
        var request = try ready(&core)
        for start in stride(from: 0, to: 20, by: 4) {
            request = try XCTUnwrap(requests(answer(&core, request, entries(chain[start..<start + 4]), hasMore: true)).first)
        }
        // A lighter side branch from height 5: its first 8 blocks held (from
        // a relay), its last 4 new. Ours stays the heavier chain.
        let side = try await world.branch(from: chain[4], count: 12)
        for block in side.prefix(8) {
            _ = core.step(.received(peer, .headers(HeadersResponse(
                requestID: 0, entries: entries([block][...]), hasMore: false
            ))), now: Self.now + 100_000)
        }
        XCTAssertTrue(side.prefix(8).allSatisfy { core.tree.contains(blockHash: $0.cid) })
        XCTAssertEqual(core.tree.canonicalTip, chain[19].cid)

        let walker = PeerID(key: "walker", session: 1)
        let best = [world.genesis] + Array(chain[0..<5]) + side
        var ask = try ready(&core, walker, at: Self.now + 100_000)
        for _ in 0..<6 {
            let page = servedPage(of: best, after: ask.locator, limit: 4)
            let effects = answer(&core, walker, ask, page.entries, hasMore: page.hasMore, at: Self.now + 100_000)
            XCTAssertTrue(disconnects(effects).isEmpty)
            guard let next = requests(effects).first else { break }
            ask = next
        }
        XCTAssertTrue(core.tree.contains(blockHash: side[11].cid), "the walk reached the peer's new blocks")
        XCTAssertEqual(core.sync.peers[walker]?.unconnecting, 0, "no strike")
    }

    /// A peer that repeats the same full page is never blamed and is asked
    /// again only at each timeout: one page per timeout.
    func testAPeerRepeatingAFullPageCostsOnePagePerTimeout() throws {
        var core = core(pageSize: 4)
        var request = try ready(&core)
        request = try XCTUnwrap(requests(answer(&core, request, entries(chain[0..<4]), hasMore: true)).first)
        _ = answer(&core, request, entries(chain[4..<8]))
        let repeater = PeerID(key: "repeater", session: 1)
        let page = entries(chain[0..<4])
        var now = Self.now
        var ask = try ready(&core, repeater)
        // The exchange's first all-held page may be a walk: it continues once.
        ask = try XCTUnwrap(requests(answer(&core, repeater, ask, page, hasMore: true)).first)
        for _ in 0..<5 {
            let effects = answer(&core, repeater, ask, page, hasMore: true, at: now)
            XCTAssertTrue(disconnects(effects).isEmpty, "never blamed")
            XCTAssertTrue(requests(effects).isEmpty, "the exchange ends")
            XCTAssertEqual(core.sync.peers[repeater]?.unconnecting, 0)
            let retry = try XCTUnwrap(core.sync.peers[repeater]?.retryAt)
            XCTAssertEqual(retry, now + core.config.headersTimeout)
            XCTAssertTrue(requests(core.step(.tick, now: retry - 1)).isEmpty, "nothing before the timeout")
            now = retry
            ask = try XCTUnwrap(requests(core.step(.tick, now: now)).first, "asked again at the timeout")
        }
    }

    /// 9a with M1: one peer streaming tip extensions that declare the
    /// maximum target and omit their child index takes no wait (the target is
    /// not the consensus one: malformed), and streaming valid ones takes one
    /// wait at most. Honest sync completes beside it.
    func testOnePeerHoldsAtMostOneChildIndexWait() async throws {
        let carriers = try await world.carriers(count: 6)
        var core = core()
        let attacker = PeerID(key: "attacker", session: 1)
        _ = try ready(&core, attacker)
        func push(_ block: Block) -> [Effect] {
            core.step(.received(attacker, .headers(HeadersResponse(
                requestID: 0, entries: [HeaderEntry(block: block, children: nil)], hasMore: false
            ))), now: Self.now)
        }
        for carrier in carriers.prefix(5) {
            _ = push(carrier.block)
        }
        XCTAssertEqual(core.sync.awaitingChildIndex.count, 1, "one wait per peer")
        XCTAssertNotNil(core.sync.peers[attacker]?.retryAt)

        let easy = Block(
            version: carriers[5].block.version, parent: carriers[5].block.parent,
            transactions: carriers[5].block.transactions, target: .max,
            nextTarget: carriers[5].block.nextTarget, spec: carriers[5].block.spec,
            parentState: carriers[5].block.parentState, prevState: carriers[5].block.prevState,
            postState: carriers[5].block.postState, children: carriers[5].block.children,
            height: carriers[5].block.height, timestamp: carriers[5].block.timestamp,
            rewardRecipient: nil, nonce: 7
        )
        XCTAssertNotNil(ChainTree.rootWork(of: easy), "the maximum target passes its own proof-of-work")
        let effects = push(easy)
        XCTAssertEqual(disconnects(effects), [.malformed], "a declared target that is not the consensus target")
        XCTAssertTrue(core.sync.awaitingChildIndex.isEmpty)

        let honest = PeerID(key: "honest", session: 1)
        let request = try ready(&core, honest)
        _ = answer(&core, honest, request, entries(chain[0..<10]))
        XCTAssertEqual(core.tree.canonicalTip, chain[9].cid)
    }

    private func replacing(_ block: Block, nonce: UInt64) -> Block {
        Block(
            version: block.version, parent: block.parent, transactions: block.transactions,
            target: block.target, nextTarget: block.nextTarget, spec: block.spec,
            parentState: block.parentState, prevState: block.prevState, postState: block.postState,
            children: block.children, height: block.height, timestamp: block.timestamp,
            rewardRecipient: block.rewardRecipient, nonce: nonce
        )
    }
}
