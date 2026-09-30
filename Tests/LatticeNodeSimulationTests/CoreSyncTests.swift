import Lattice
import LatticeNodeCore
import LatticeNodeSim
import XCTest

/// `Core.step` header sync, one event at a time.
final class CoreSyncTests: XCTestCase {
    private static let now = World.genesisTime + 1_000_000
    private let peer = PeerID(key: "peer", session: 1)
    private var world: World!
    private var chain: [SimBlock] = []

    override func setUp() async throws {
        var rng = SplitMix64(state: 0x5_1C)
        world = try await World.generate(rng: &rng, honestBlocks: 30, forkProbability: 0, spamBlocks: 1)
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
            core.step(.received(peer, .getHeaders(HeadersRequest(requestID: 42, locator: locator))), now: Self.now)
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

    func testAnOmittedChildIndexIsFetchedByCIDAndVerified() throws {
        for honest in [false, true] {
            var core = core()
            let request = try ready(&core)
            let page = [HeaderEntry(block: chain[0].block, children: nil)]
            let effects = answer(&core, request, page)
            let cid = chain[0].block.children.rawCID
            XCTAssertTrue(effects.contains {
                if case .fetchByCID(peer, cid) = $0 { return true }
                return false
            })
            let bytes = honest ? chain[0].children : ChildIndex(entries: ["Liar": try BlockHeader(node: world.genesis.block)])
            let fetched = core.step(.childIndexFetched(peer, cid: cid, bytes), now: Self.now)
            if honest {
                XCTAssertTrue(core.tree.contains(blockHash: chain[0].cid))
                guard case .persist = fetched.first else { return XCTFail("\(fetched)") }
                XCTAssertEqual(requests(fetched).first?.locator.first, chain[0].cid)
            } else {
                XCTAssertEqual(disconnects(fetched), [.malformed])
                XCTAssertFalse(core.tree.contains(blockHash: chain[0].cid))
            }
        }
    }

    func testAMissingChildIndexIsAvailabilityNotBlame() throws {
        var core = core()
        let request = try ready(&core)
        _ = answer(&core, request, [HeaderEntry(block: chain[0].block, children: nil)])
        let effects = core.step(.childIndexFetched(peer, cid: chain[0].block.children.rawCID, nil), now: Self.now)
        XCTAssertTrue(disconnects(effects).isEmpty)
        XCTAssertNotNil(core.sync.peers[peer])
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
