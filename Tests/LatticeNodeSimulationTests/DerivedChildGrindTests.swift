import Foundation
import Lattice
@testable import LatticeNodeCore
@testable import LatticeNodeSim
import UInt256
import XCTest
import cashew

/// A parent block that commits a child block by CID alone (a `child/X =
/// C@P` commitment, whose miner hosts no X and makes no proof) has its grind
/// derived at C by the hosts that run X, beside run attribution and by its
/// index: when the carrier is weighed (C wanted by CID if not held) and when
/// C arrives by any route (each of its committers). Nothing of a derivation
/// is stored: a node online throughout, one hosting X late and one restarted
/// from its stores end alike.
final class DerivedChildGrindTests: XCTestCase {
    private static let now = World.genesisTime + 1_000_000
    private static let nexus = LevelWorld.nexus
    private static let alpha = LevelWorld.alpha
    private static let beta = LevelWorld.beta
    private static let interval = LevelWorld.interval
    private static let t = World.genesisTime

    /// The network's content, recording what was asked of it.
    private final class Network: Fetcher, @unchecked Sendable {
        let cas: SimCAS
        private let lock = NSLock()
        private var asked: Set<String> = []

        init(_ cas: SimCAS) { self.cas = cas }

        var fetched: Set<String> { lock.withLock { asked } }

        func forget() { lock.withLock { asked = [] } }

        func fetch(rawCid: String) async throws -> Data {
            _ = lock.withLock { asked.insert(rawCid) }
            return try await cas.fetch(rawCid: rawCid)
        }
    }

    /// The host's own headers first, then the network: as `ownReads` reads.
    private struct OwnFirst: Fetcher {
        let own: SimCAS
        let network: Network

        func fetch(rawCid: String) async throws -> Data {
            if let held = try? await own.fetch(rawCid: rawCid) { return held }
            return try await network.fetch(rawCid: rawCid)
        }
    }

    private struct Want: Equatable {
        let path: ChainPath
        let cid: String
    }

    private struct Derived: Equatable {
        let path: ChainPath
        let cid: String
        let carrier: String
    }

    /// One host and the peers it hears: what it sends is kept to answer. A
    /// header fetch that fails is kept to try again (the runtime's
    /// `retryingBody`) or to give up on, answering nothing.
    private struct Host {
        let world: LevelWorld
        var core: NodeCore
        var store: HostStore
        var network: Network
        var sent: [(path: ChainPath, message: SyncMessage)] = []
        var wants: [Want] = []
        var derived: [Derived] = []
        var unavailable: [Want] = []
        var disconnects: [PeerID] = []
        var position: [ChainPath: UInt64] = [:]
        /// Blocks whose bodies the content layer never serves.
        var withheldBodies: Set<String> = []
        /// Carriers whose derivations are lost (a crash before they ran).
        var lostDerivations: Set<String> = []

        init(_ world: LevelWorld, network: SimCAS, hosted: Set<ChainPath>? = nil) {
            self.world = world
            core = NodeCore(root: world.rootBootstrap.tree.detached(), hosted: hosted ?? world.hosted)
            store = HostStore(world: world)
            self.network = Network(network)
        }

        /// What this host holds of its own: its headers and child indexes.
        func own() -> SimCAS {
            let held = SimCAS()
            for level in store.levels.values {
                for (cid, stored) in level.headers {
                    if let block = stored.block.toData() { held.put([cid: block]) }
                    if let children = stored.children.toData() { held.put([stored.block.children.rawCID: children]) }
                }
            }
            return held
        }

        func assemble(_ cid: String, at path: ChainPath) async throws -> HeaderEntry {
            try await HeaderEntry.committed(cid, at: path, fetcher: OwnFirst(own: own(), network: network))
        }

        mutating func step(_ event: NodeEvent) async {
            var queue = [event]
            while !queue.isEmpty {
                for effect in core.step(queue.removeFirst(), now: DerivedChildGrindTests.now) {
                    switch effect {
                    case .persist(let batch):
                        store.append(batch)
                    case .level(let path, .fetchBody(let cid)):
                        if !withheldBodies.contains(cid) { queue.append(.level(path, .bodyFetched(cid: cid))) }
                    case .level(let path, .send(_, let message)):
                        sent.append((path, message))
                    case .level(let path, .verifyProof(let job)):
                        guard let block = job.block ?? store.levels[path]?.headers[job.childCID]?.block else { break }
                        queue.append(.level(path, .proofVerified(job, await job.run(block))))
                    case .level(let path, .lookupProofs(let cids)):
                        for cid in cids where !store.proofs(path, cid).isEmpty {
                            queue.append(.level(path, .proofsFound(childCID: cid, store.proofs(path, cid))))
                        }
                    case .level(let path, .fetchHeader(let cid)):
                        let want = Want(path: path, cid: cid)
                        wants.append(want)
                        unavailable.removeAll { $0 == want }
                        if let entry = try? await assemble(cid, at: path) {
                            queue.append(.level(path, .headerFetched(cid: cid, entry)))
                        } else {
                            unavailable.append(want)
                        }
                    case .level(let path, .deriveProof(let job)):
                        // From this host's own content only.
                        derived.append(Derived(path: path, cid: job.childCID, carrier: job.carrier))
                        guard !lostDerivations.contains(job.carrier),
                              let block = job.block ?? store.levels[path]?.headers[job.childCID]?.block else { break }
                        let upstream = store.proofs(Array(path.dropLast()), job.carrier)
                        for (check, result) in await job.run(block, upstream: upstream, fetcher: own()) {
                            queue.append(.level(path, .proofVerified(check, result)))
                        }
                    case .connect(let path, let job):
                        let verdict = await ChainTree.connect(
                            job, fetcher: world.cas, parentFacts: core.parentFacts(for: path),
                            validationContext: ValidationContext(nowMilliseconds: DerivedChildGrindTests.now)
                        )
                        queue.append(.level(path, .connected(verdict)))
                    case .disconnect(let peer, _):
                        disconnects.append(peer)
                    default:
                        break
                    }
                }
            }
        }

        /// The next attempt at every unavailable header.
        mutating func retry() async {
            let waiting = unavailable
            unavailable = []
            for want in waiting {
                if let entry = try? await assemble(want.cid, at: want.path) {
                    await step(.level(want.path, .headerFetched(cid: want.cid, entry)))
                } else {
                    unavailable.append(want)
                }
            }
        }

        /// Every unavailable header's attempts ran out: nothing answers.
        mutating func giveUp() {
            unavailable = []
        }

        /// A peer whose logs this host reads from their start.
        mutating func meet(_ peer: PeerID) async {
            await step(.peerReady(peer))
            for (path, message) in take() {
                guard case .getStream(let id, _, _, _) = message else { continue }
                await step(.received(peer, path, .stream(StreamPage(requestID: id, logID: "peer", entries: [], hasMore: false))))
            }
        }

        /// `peer` logs a header and serves it (with `proofs`) when asked.
        mutating func relay(
            _ block: SimBlock, at path: ChainPath, from peer: PeerID, proofs: [ChildBlockProof] = [], spec: ChainSpec? = nil
        ) async {
            position[path, default: 0] += 1
            await step(.received(peer, path, .stream(StreamPage(
                requestID: 0, logID: "peer",
                entries: [StreamEntry(position: position[path]!, entry: .header(block.cid))], hasMore: false
            ))))
            for (sentAt, message) in take() where sentAt == path {
                guard case .getData(let id, let cids) = message, cids.contains(block.cid) else { continue }
                await step(.received(peer, path, .headers(HeadersResponse(
                    requestID: id,
                    entries: [HeaderEntry(block: block.block, children: block.children, proofs: proofs, spec: spec)],
                    hasMore: false
                ))))
            }
        }

        mutating func take() -> [(path: ChainPath, message: SyncMessage)] {
            defer { sent = [] }
            return sent
        }

        /// The host as its stores alone rebuild it.
        mutating func restart() throws {
            core = try NodeCore.restore(
                root: try XCTUnwrap(store.records[DerivedChildGrindTests.nexus]),
                facts: store.levels.mapValues(\.facts),
                specs: store.levels.mapValues { $0.headers.values.compactMap(\.spec) },
                hosted: world.hosted
            )
        }

        func digest(_ path: ChainPath) throws -> TreeDigest {
            TreeDigest(try XCTUnwrap(core.levels[path]).tree)
        }
    }

    private static let miner = PeerID(key: "miner", session: 1)
    private static let alphaHost = PeerID(key: "alpha-host", session: 2)

    private static func commit(
        _ child: SimBlock, parentState: String, under directory: String, on chain: ChainPath, key index: Int
    ) throws -> Transaction {
        let key = SimTransactions.keys[index]
        let body = try HeaderImpl(node: TransactionBody(
            accountActions: [],
            actions: [Action(
                key: CHILD_COMMITMENT_KEY_PREFIX + directory, oldValue: nil,
                newValue: child.cid + String(UnicodeScalar(CHILD_COMMITMENT_PARENT_STATE_SEPARATOR)) + parentState
            )],
            depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: key.publicKey)], nonce: 0, chainPath: chain
        ))
        return Transaction(
            signatures: [key.publicKey: try XCTUnwrap(TransactionSigning.sign(bodyHeader: body, privateKeyHex: key.privateKey))],
            body: body
        )
    }

    private static func runID(_ carrier: String) throws -> String {
        try XCTUnwrap(AttributedRunIdentity(carrierBlockHash: carrier, directory: alpha[1]).contributionID)
    }

    // MARK: - One carrier

    /// N0 and N1 (carrying Alpha's genesis G) mined as usual; C on G; B and
    /// its sibling S on N1 each commit C by CID through a transaction (their
    /// miners host no Alpha and make no proof); B2 on B commits nothing.
    private struct Committed {
        let world: LevelWorld
        let setup: [MinedGrind]
        let g: SimBlock
        let c: SimBlock
        let b: SimBlock
        let sibling: SimBlock
        let b2: SimBlock
    }

    private func committedWorld() async throws -> Committed {
        var builder = try await LevelWorld.Builder(levels: 2)
        let n0 = try await builder.grind(on: try XCTUnwrap(builder.geneses[Self.nexus]), carrying: [], at: Self.t + Self.interval / 2, outcome: .block)
        let g = try await builder.childGenesis(Self.alpha, parentState: n0.root.block.postState.rawCID, at: Self.t + Self.interval)
        let n1 = try await builder.grind(on: n0.root, carrying: [(Self.alpha, g)], at: Self.t + Self.interval, outcome: .block)
        let entering = n1.root.block.postState.rawCID
        let c = try await builder.build(on: g, carrierPrevState: entering, timestamp: Self.t + 2 * Self.interval, nonce: 1)
        let b = try await builder.grind(
            on: n1.root, carrying: [],
            transactions: [try Self.commit(c, parentState: entering, under: Self.alpha[1], on: Self.nexus, key: 0)],
            at: Self.t + 2 * Self.interval, outcome: .block
        )
        let sibling = try await builder.grind(
            on: n1.root, carrying: [],
            transactions: [try Self.commit(c, parentState: entering, under: Self.alpha[1], on: Self.nexus, key: 1)],
            at: Self.t + 2 * Self.interval, outcome: .block
        )
        let children = try await b.root.block.children.resolve(fetcher: builder.cas).node
        XCTAssertEqual(children?[Self.alpha[1]]?.rawCID, c.cid, "B carries C by CID")
        XCTAssertNil(children?[Self.alpha[1]]?.node, "B carries C by CID alone")
        let b2 = try await builder.grind(on: b.root, carrying: [], at: Self.t + 3 * Self.interval, outcome: .block)
        return Committed(
            world: builder.world(), setup: [n0.grind, n1.grind], g: g, c: c, b: b.root, sibling: sibling.root, b2: b2.root
        )
    }

    private func host(_ fixture: Committed, network: SimCAS? = nil) async -> Host {
        var host = Host(fixture.world, network: network ?? fixture.world.cas)
        for grind in fixture.setup { await host.step(.mined(grind)) }
        await host.meet(Self.miner)
        host.network.forget()
        return host
    }

    /// A host of Alpha that does not hold C hears B from a miner hosting no
    /// Alpha: it wants C by CID, reads exactly C and C's child index from the
    /// network, credits B's grind at C, and credits C with B's run once B2
    /// extends it.
    func testACommittedChildIsFetchedCreditedAndAttributed() async throws {
        let fixture = try await committedWorld()
        var host = await host(fixture)

        await host.relay(fixture.b, at: Self.nexus, from: Self.miner)
        XCTAssertEqual(try host.digest(Self.nexus).canonicalTip, fixture.b.cid)
        XCTAssertEqual(host.wants, [Want(path: Self.alpha, cid: fixture.c.cid)])
        XCTAssertEqual(host.derived, [Derived(path: Self.alpha, cid: fixture.c.cid, carrier: fixture.b.cid)])
        XCTAssertTrue(host.network.fetched.isSubset(of: [fixture.c.cid, fixture.c.block.children.rawCID]),
                      "only C and its child index are read from the network")
        var alpha = try host.digest(Self.alpha)
        XCTAssertGreaterThan(try XCTUnwrap(alpha.blocks[fixture.c.cid]?.grinds[fixture.b.cid], "C weighs by B's grind"), .zero)
        XCTAssertEqual(alpha.canonicalTip, fixture.c.cid)
        XCTAssertEqual(host.store.proofs(Self.alpha, fixture.c.cid).map(\.rootCID), [fixture.b.cid], "the proof is indexed")
        XCTAssertTrue(host.disconnects.isEmpty)

        await host.relay(fixture.b2, at: Self.nexus, from: Self.miner)
        alpha = try host.digest(Self.alpha)
        XCTAssertEqual(alpha.blocks[fixture.c.cid]?.grinds[try Self.runID(fixture.b.cid)], workForTarget(fixture.b2.block.target),
                       "B2's work reaches C through B's run")
        XCTAssertEqual(host.wants.count, 1, "B2 commits nothing")
        XCTAssertEqual(host.derived.count, 1, "a carrier already credited is not derived again")
    }

    /// B and its sibling S both commit C: each one's grind is credited at C,
    /// the second while C is held, from this host's own headers, with no
    /// fetch.
    func testSiblingCarriersOfOneBlockBothCreditIt() async throws {
        let fixture = try await committedWorld()
        var host = await host(fixture)
        await host.relay(fixture.b, at: Self.nexus, from: Self.miner)
        host.network.forget()
        await host.relay(fixture.sibling, at: Self.nexus, from: Self.miner)
        XCTAssertEqual(host.wants.map(\.cid), [fixture.c.cid], "a held C is not fetched again")
        XCTAssertEqual(host.derived.map(\.carrier), [fixture.b.cid, fixture.sibling.cid])
        XCTAssertFalse(host.network.fetched.contains(fixture.c.cid), "a held C is read from this host")
        let grinds = try XCTUnwrap(try host.digest(Self.alpha).blocks[fixture.c.cid]?.grinds)
        XCTAssertNotNil(grinds[fixture.b.cid], "B's grind")
        XCTAssertNotNil(grinds[fixture.sibling.cid], "S's grind, at a held C")
        XCTAssertEqual(Set(host.store.proofs(Self.alpha, fixture.c.cid).map(\.rootCID)), [fixture.b.cid, fixture.sibling.cid])
    }

    /// A committed child genesis read from bytes (its spec a CID, as on the
    /// wire) weighs, with the spec read beside it.
    func testACommittedGenesisReadFromBytesWeighs() async throws {
        var builder = try await LevelWorld.Builder(levels: 2)
        let n0 = try await builder.grind(on: try XCTUnwrap(builder.geneses[Self.nexus]), carrying: [], at: Self.t + Self.interval / 2, outcome: .block)
        let entering = n0.root.block.postState.rawCID
        let g = try await builder.childGenesis(Self.alpha, parentState: entering, at: Self.t + Self.interval)
        let b = try await builder.grind(
            on: n0.root, carrying: [],
            transactions: [try Self.commit(g, parentState: entering, under: Self.alpha[1], on: Self.nexus, key: 0)],
            at: Self.t + Self.interval, outcome: .block
        )
        let world = builder.world()

        var host = Host(world, network: world.cas)
        await host.step(.mined(n0.grind))
        await host.meet(Self.miner)
        let entry = try await host.assemble(g.cid, at: Self.alpha)
        XCTAssertNil(entry.block.spec.node, "the block as read from bytes")
        XCTAssertNotNil(entry.spec, "its spec read beside it")

        await host.relay(b.root, at: Self.nexus, from: Self.miner)
        let alpha = try host.digest(Self.alpha)
        XCTAssertEqual(alpha.roots, [g.cid], "G weighs as Alpha's genesis")
        XCTAssertNotNil(alpha.blocks[g.cid]?.grinds[b.root.cid])
        XCTAssertNotNil(host.store.levels[Self.alpha]?.headers[g.cid]?.spec, "its spec is stored with it")
    }

    // MARK: - Nothing credited, nothing blamed

    /// A carrier whose hash misses the committed block's target credits
    /// nothing and blames no one: C is a child genesis claiming a target
    /// harder than B's hash.
    func testACarrierMissingTheChildTargetCreditsNothing() async throws {
        var builder = try await LevelWorld.Builder(levels: 2)
        let n0 = try await builder.grind(on: try XCTUnwrap(builder.geneses[Self.nexus]), carrying: [], at: Self.t + Self.interval / 2, outcome: .block)
        let entering = n0.root.block.postState
        let hard = UInt256.max >> 24
        let genesis = try await BlockBuilder.buildChildGenesis(
            spec: try XCTUnwrap(builder.specs[Self.alpha]), parentState: entering,
            timestamp: Self.t + Self.interval, target: hard, fetcher: builder.cas
        )
        let c = try await builder.store(genesis, releaseAt: Self.t + Self.interval, anchor: nil)
        let tx = try Self.commit(c, parentState: entering.rawCID, under: Self.alpha[1], on: Self.nexus, key: 0)
        let unmined = try await builder.build(
            on: n0.root, carrierPrevState: nil, transactions: [tx], timestamp: Self.t + Self.interval, nonce: 0
        )
        let rootTarget = unmined.block.target
        let mined = builder.mine(unmined.block) { rootTarget >= $0 && $0 > hard }
        let b = try await builder.store(mined, releaseAt: Self.t + Self.interval, anchor: unmined.anchor)
        let world = builder.world()

        var host = Host(world, network: world.cas)
        await host.step(.mined(n0.grind))
        await host.meet(Self.miner)
        await host.relay(b, at: Self.nexus, from: Self.miner)
        XCTAssertEqual(try host.digest(Self.nexus).canonicalTip, b.cid)
        XCTAssertEqual(host.wants.map(\.cid), [c.cid], "the commitment is wanted")
        XCTAssertEqual(host.derived.map(\.carrier), [b.cid], "and derived")
        XCTAssertTrue(try host.digest(Self.alpha).blocks.isEmpty, "a hash that misses C's target weighs nothing")
        XCTAssertTrue(host.store.proofs(Self.alpha, c.cid).isEmpty)
        XCTAssertNotNil(host.core.levels[Self.alpha]?.sync.proofs.awaiting[c.cid], "C waits, bounded as any header")
        XCTAssertTrue(host.disconnects.isEmpty, "no one is blamed")
    }

    /// A carrier that commits C on the wrong prevState (C anchors at N0's
    /// post-state, B enters N1's): the vertical binding fails, so nothing is
    /// credited and no one blamed.
    func testACarrierOnTheWrongPrevStateCreditsNothing() async throws {
        var builder = try await LevelWorld.Builder(levels: 2)
        let n0 = try await builder.grind(on: try XCTUnwrap(builder.geneses[Self.nexus]), carrying: [], at: Self.t + Self.interval / 2, outcome: .block)
        let g = try await builder.childGenesis(Self.alpha, parentState: n0.root.block.postState.rawCID, at: Self.t + Self.interval)
        let n1 = try await builder.grind(on: n0.root, carrying: [(Self.alpha, g)], at: Self.t + Self.interval, outcome: .block)
        let (stale, entering) = (n0.root.block.postState.rawCID, n1.root.block.postState.rawCID)
        XCTAssertNotEqual(stale, entering)
        let c = try await builder.build(on: g, carrierPrevState: stale, timestamp: Self.t + 2 * Self.interval, nonce: 1)
        // The commitment names B's entering state; C itself anchors elsewhere.
        let b = try await builder.grind(
            on: n1.root, carrying: [],
            transactions: [try Self.commit(c, parentState: entering, under: Self.alpha[1], on: Self.nexus, key: 0)],
            at: Self.t + 2 * Self.interval, outcome: .block
        )
        let world = builder.world()

        var host = Host(world, network: world.cas)
        for grind in [n0.grind, n1.grind] { await host.step(.mined(grind)) }
        await host.meet(Self.miner)
        await host.relay(b.root, at: Self.nexus, from: Self.miner)
        XCTAssertNotNil(try host.digest(Self.nexus).blocks[b.root.cid])
        XCTAssertEqual(host.derived.map(\.carrier), [b.root.cid])
        XCTAssertNil(try host.digest(Self.alpha).blocks[c.cid], "no work on the wrong prevState")
        XCTAssertTrue(host.store.proofs(Self.alpha, c.cid).isEmpty)
        XCTAssertTrue(host.disconnects.isEmpty, "no one is blamed")
    }

    // MARK: - Unavailable, then delivered

    /// C's header is unavailable when B is weighed: nothing weighs and no one
    /// is blamed. However C is held next — the fetch's next attempt, plain
    /// Alpha gossip with no proof while the fetch still runs or after it gave
    /// up, or a later carrier's want — B's grind is credited without B
    /// weighed again.
    func testAnUnavailableCommittedChildIsCreditedOnceDelivered() async throws {
        let fixture = try await committedWorld()
        let bytes = try XCTUnwrap(fixture.world.cas.all[fixture.c.cid])
        for route in ["retry", "gossip", "gave up, gossip", "gave up, later carrier"] {
            let network = SimCAS(fixture.world.cas.all.filter { $0.key != fixture.c.cid })
            var host = await host(fixture, network: network)
            await host.relay(fixture.b, at: Self.nexus, from: Self.miner)
            XCTAssertNil(try host.digest(Self.alpha).blocks[fixture.c.cid], "\(route): unavailable, not weighed")
            XCTAssertEqual(host.unavailable.map(\.cid), [fixture.c.cid])
            XCTAssertEqual(host.core.levels[Self.alpha]?.sync.proofs.awaiting.isEmpty, true)
            if route.hasPrefix("gave up") { host.giveUp() }

            network.put([fixture.c.cid: bytes])
            switch route {
            case "retry":
                await host.retry()
            case "gave up, later carrier":
                await host.relay(fixture.sibling, at: Self.nexus, from: Self.miner)
                XCTAssertEqual(host.wants.map(\.cid), [fixture.c.cid, fixture.c.cid], "wanted again by a later carrier")
            default:
                await host.meet(Self.alphaHost)
                await host.relay(fixture.c, at: Self.alpha, from: Self.alphaHost)
                XCTAssertEqual(host.wants.count, 1, "\(route): held from gossip, not fetched again")
            }
            XCTAssertNotNil(try host.digest(Self.alpha).blocks[fixture.c.cid]?.grinds[fixture.b.cid], "\(route): C weighs by B's grind")
            XCTAssertTrue(host.disconnects.isEmpty, "\(route): unavailable is never invalid")
        }
    }

    // MARK: - Two levels

    /// Three levels: N1 carries Alpha's genesis G and R1 carries A1 on G;
    /// Alpha block A on A1 commits Beta's genesis D by CID (an Alpha
    /// transaction); Nexus block B on R1 commits A by CID, and its sibling S
    /// commits another Alpha block A2; B2 extends B.
    private struct Deep {
        let world: LevelWorld
        let setup: [MinedGrind]
        let a: SimBlock
        let a2: SimBlock
        let d: SimBlock
        let b: SimBlock
        let sibling: SimBlock
        let b2: SimBlock
    }

    private func deepWorld() async throws -> Deep {
        var builder = try await LevelWorld.Builder(levels: 3)
        let n0 = try await builder.grind(on: try XCTUnwrap(builder.geneses[Self.nexus]), carrying: [], at: Self.t + Self.interval / 2, outcome: .block)
        let g = try await builder.childGenesis(Self.alpha, parentState: n0.root.block.postState.rawCID, at: Self.t + Self.interval)
        let n1 = try await builder.grind(on: n0.root, carrying: [(Self.alpha, g)], at: Self.t + Self.interval, outcome: .block)
        let a1 = try await builder.build(on: g, carrierPrevState: n1.root.block.postState.rawCID, timestamp: Self.t + 2 * Self.interval, nonce: 5)
        let r1 = try await builder.grind(on: n1.root, carrying: [(Self.alpha, a1)], at: Self.t + 2 * Self.interval, outcome: .block)
        let entering = r1.root.block.postState.rawCID
        // D commits A's entering state: A's previous state, A1's post-state.
        let underA = a1.block.postState.rawCID
        let d = try await builder.childGenesis(Self.beta, parentState: underA, at: Self.t + 3 * Self.interval)
        let a = try await builder.build(
            on: a1, carrierPrevState: entering,
            transactions: [try Self.commit(d, parentState: underA, under: Self.beta[2], on: Self.alpha, key: 1)],
            timestamp: Self.t + 3 * Self.interval, nonce: 1
        )
        let a2 = try await builder.build(on: a1, carrierPrevState: entering, timestamp: Self.t + 3 * Self.interval, nonce: 3)
        let b = try await builder.grind(
            on: r1.root, carrying: [],
            transactions: [try Self.commit(a, parentState: entering, under: Self.alpha[1], on: Self.nexus, key: 0)],
            at: Self.t + 3 * Self.interval, outcome: .block
        )
        let sibling = try await builder.grind(
            on: r1.root, carrying: [],
            transactions: [try Self.commit(a2, parentState: entering, under: Self.alpha[1], on: Self.nexus, key: 2)],
            at: Self.t + 3 * Self.interval, outcome: .block
        )
        let b2 = try await builder.grind(on: b.root, carrying: [], at: Self.t + 4 * Self.interval, outcome: .block)
        return Deep(
            world: builder.world(), setup: [n0.grind, n1.grind, r1.grind], a: a, a2: a2, d: d,
            b: b.root, sibling: sibling.root, b2: b2.root
        )
    }

    private func host(_ fixture: Deep, network: SimCAS? = nil) async -> Host {
        var host = Host(fixture.world, network: network ?? fixture.world.cas)
        for grind in fixture.setup { await host.step(.mined(grind)) }
        await host.meet(Self.miner)
        host.network.forget()
        return host
    }

    /// A carrier at depth 2 whose own credit is a derived proof: A weighs by
    /// B's derived grind, and D, which A commits a level down, by A's saved
    /// proof extended by A's hop (rooted at B). A's body is withheld: the
    /// header tree does not wait on it, and nothing read is a body.
    func testADerivedCarrierCreditsTheBlockItCommitsByTheComposedPath() async throws {
        let fixture = try await deepWorld()
        var host = await host(fixture)
        host.withheldBodies = [fixture.a.cid]

        await host.relay(fixture.b, at: Self.nexus, from: Self.miner)
        let alpha = try host.digest(Self.alpha)
        XCTAssertNotNil(alpha.blocks[fixture.a.cid]?.grinds[fixture.b.cid], "A weighs by B's derived grind")
        XCTAssertFalse(alpha.executed.contains(fixture.a.cid), "its body never came")
        XCTAssertEqual(host.wants.filter { $0.path == Self.beta }, [Want(path: Self.beta, cid: fixture.d.cid)])
        XCTAssertEqual(host.derived.filter { $0.path == Self.beta }.map(\.carrier), [fixture.a.cid])
        let beta = try host.digest(Self.beta)
        XCTAssertEqual(beta.roots, [fixture.d.cid], "D weighs as Beta's genesis")
        XCTAssertNotNil(beta.blocks[fixture.d.cid]?.grinds[fixture.b.cid])
        XCTAssertEqual(try XCTUnwrap(host.store.proofs(Self.beta, fixture.d.cid).first).directoryPath,
                       [Self.alpha[1], Self.beta[2]], "the path from the root through A")
        let headers: Set<String> = [
            fixture.a.cid, fixture.a.block.children.rawCID,
            fixture.d.cid, fixture.d.block.children.rawCID, fixture.d.block.spec.rawCID,
        ]
        XCTAssertTrue(host.network.fetched.isSubset(of: headers),
                      "only headers, child indexes and a spec are read: \(host.network.fetched.subtracting(headers))")
        XCTAssertTrue(host.disconnects.isEmpty)
    }

    /// A middle-level header is unavailable: the subtree below it is unknown,
    /// with no verdict and no blame, while both levels go on (B2 extends B;
    /// A2, committed by B's sibling, weighs). Once A's header is available
    /// the next attempt weighs it, and what A commits a level down is wanted
    /// and weighed in turn.
    func testAnUnavailableHeaderHoldsOnlyItsOwnSubtree() async throws {
        let fixture = try await deepWorld()
        let network = SimCAS(fixture.world.cas.all.filter { $0.key != fixture.a.cid })
        var host = await host(fixture, network: network)

        await host.relay(fixture.b, at: Self.nexus, from: Self.miner)
        await host.relay(fixture.sibling, at: Self.nexus, from: Self.miner)
        await host.relay(fixture.b2, at: Self.nexus, from: Self.miner)
        XCTAssertEqual(try host.digest(Self.nexus).canonicalTip, fixture.b2.cid, "the parent level goes on")
        var alpha = try host.digest(Self.alpha)
        XCTAssertNil(alpha.blocks[fixture.a.cid], "unavailable: not weighed")
        XCTAssertNotNil(alpha.blocks[fixture.a2.cid]?.grinds[fixture.sibling.cid], "the level goes on")
        XCTAssertEqual(host.unavailable.map(\.cid), [fixture.a.cid])
        XCTAssertTrue(try host.digest(Self.beta).blocks.isEmpty, "the subtree below A is unknown")
        XCTAssertTrue(host.disconnects.isEmpty, "unavailable is never invalid")

        network.put([fixture.a.cid: try XCTUnwrap(fixture.world.cas.all[fixture.a.cid])])
        await host.retry()
        alpha = try host.digest(Self.alpha)
        XCTAssertNotNil(alpha.blocks[fixture.a.cid]?.grinds[fixture.b.cid], "A weighs once available")
        XCTAssertEqual(try host.digest(Self.beta).roots, [fixture.d.cid], "and the subtree below it is wanted and weighed")
        XCTAssertTrue(host.unavailable.isEmpty)
    }

    // MARK: - Many carriers

    /// N0 and N1 (carrying Alpha's genesis G); C on G; `count` siblings on
    /// N1, each committing C by CID; then `depth` blocks on the first
    /// carrier, so the carriers end that far below the tip.
    private struct Carriers {
        let world: LevelWorld
        let setup: [MinedGrind]
        let g: SimBlock
        let c: SimBlock
        let carriers: [MinedGrind]
        let tail: [MinedGrind]

        var mined: [MinedGrind] { setup + carriers + tail }
        var carrierCIDs: Set<String> { Set(carriers.map { (try? BlockHeader(node: $0.root).rawCID) ?? "" }) }
    }

    private func carriersWorld(_ count: Int, depth: Int = 0) async throws -> Carriers {
        var builder = try await LevelWorld.Builder(levels: 2)
        let n0 = try await builder.grind(on: try XCTUnwrap(builder.geneses[Self.nexus]), carrying: [], at: Self.t + Self.interval / 2, outcome: .block)
        let g = try await builder.childGenesis(Self.alpha, parentState: n0.root.block.postState.rawCID, at: Self.t + Self.interval)
        let n1 = try await builder.grind(on: n0.root, carrying: [(Self.alpha, g)], at: Self.t + Self.interval, outcome: .block)
        let entering = n1.root.block.postState.rawCID
        let c = try await builder.build(on: g, carrierPrevState: entering, timestamp: Self.t + 2 * Self.interval, nonce: 1)
        let tx = try Self.commit(c, parentState: entering, under: Self.alpha[1], on: Self.nexus, key: 0)
        var carriers: [(root: SimBlock, grind: MinedGrind)] = []
        for _ in 0..<count {
            let mined = try await builder.grind(on: n1.root, carrying: [], transactions: [tx], at: Self.t + 2 * Self.interval, outcome: .block)
            carriers.append((mined.root, mined.grind))
        }
        var tail: [MinedGrind] = []
        var tip = try XCTUnwrap(carriers.first).root
        for height in 0..<depth {
            let mined = try await builder.grind(on: tip, carrying: [], at: Self.t + Int64(3 + height) * Self.interval, outcome: .block)
            tip = mined.root
            tail.append(mined.grind)
        }
        return Carriers(world: builder.world(), setup: [n0.grind, n1.grind], g: g, c: c, carriers: carriers.map(\.grind), tail: tail)
    }

    private func grinds(at cid: String, _ host: Host) throws -> Set<String> {
        Set(try XCTUnwrap(try host.digest(Self.alpha).blocks[cid]).grinds.keys)
    }

    /// More carriers of one block than a header's proof cap: each carrier is
    /// derived on its own, and every grind is credited.
    func testMoreCarriersThanTheHeaderCapAllCredit() async throws {
        let fixture = try await carriersWorld(ChildProofConfig().maxPerHeader + 4)
        var host = Host(fixture.world, network: fixture.world.cas)
        for grind in fixture.mined { await host.step(.mined(grind)) }
        XCTAssertTrue(fixture.carrierCIDs.isSubset(of: try grinds(at: fixture.c.cid, host)))
        XCTAssertEqual(host.wants.count, 1)
        XCTAssertTrue(host.disconnects.isEmpty)
    }

    /// A burst of derived proofs past the per-source cap: a level hosted late
    /// takes C from a peer with one proof, and every committer of C is
    /// derived at once by the index; each credits, in no source's load.
    func testABurstOfDerivedProofsPastTheSourceCapAllCredit() async throws {
        let fixture = try await carriersWorld(ChildProofConfig().maxPerSource + 6)
        var host = Host(fixture.world, network: fixture.world.cas, hosted: [])
        for grind in fixture.mined { await host.step(.mined(grind)) }
        try await catchUp(&host, fixture)
        XCTAssertTrue(fixture.carrierCIDs.isSubset(of: try grinds(at: fixture.c.cid, host)))
        XCTAssertGreaterThanOrEqual(host.derived.filter { $0.cid == fixture.c.cid }.count, fixture.carriers.count)
        XCTAssertEqual(host.core.levels[Self.alpha]?.sync.proofs.load.isEmpty, true, "derived proofs are no source's load")
        XCTAssertTrue(host.disconnects.isEmpty)
    }

    /// Host Alpha now and hear its blocks from a peer that has them: G with
    /// N1's proof, C with its first carrier's.
    private func catchUp(_ host: inout Host, _ fixture: Carriers) async throws {
        await host.step(.host(Self.alpha, facts: [], specs: [], cursors: [:]))
        await host.meet(Self.alphaHost)
        let genesisProof = try XCTUnwrap(fixture.setup[1].carried.first).proof
        await host.relay(fixture.g, at: Self.alpha, from: Self.alphaHost, proofs: [genesisProof], spec: fixture.world.specs[Self.alpha])
        let first = try XCTUnwrap(fixture.carriers.first).root
        let proof = try await ChildBlockProof.generate(
            rootHeader: BlockHeader(node: first), childDirectory: Self.alpha[1], fetcher: fixture.world.cas
        )
        await host.relay(fixture.c, at: Self.alpha, from: Self.alphaHost, proofs: [proof])
    }

    /// Arrival order and restart change nothing, carriers deep below the tip
    /// included: a node online throughout (C unavailable until after its
    /// fetch gave up, then plain gossip), one hosting Alpha after every block
    /// weighed, and one restarted from its stores after all but one
    /// derivation was lost, end with equal Alpha trees.
    func testOnlineLateAndRestartedHostsAgree() async throws {
        let fixture = try await carriersWorld(ChildProofConfig().maxPerHeader + 4, depth: 70)
        let bytes = try XCTUnwrap(fixture.world.cas.all[fixture.c.cid])

        let network = SimCAS(fixture.world.cas.all.filter { $0.key != fixture.c.cid })
        var online = Host(fixture.world, network: network)
        for grind in fixture.mined { await online.step(.mined(grind)) }
        online.giveUp()
        XCTAssertNil(try online.digest(Self.alpha).blocks[fixture.c.cid])
        network.put([fixture.c.cid: bytes])
        await online.meet(Self.alphaHost)
        await online.relay(fixture.c, at: Self.alpha, from: Self.alphaHost)
        let reference = try online.digest(Self.alpha)
        XCTAssertTrue(fixture.carrierCIDs.isSubset(of: Set(try XCTUnwrap(reference.blocks[fixture.c.cid]).grinds.keys)))
        let deepest = try XCTUnwrap(try online.digest(Self.nexus).blocks[try BlockHeader(node: fixture.carriers[0].root).rawCID])
        XCTAssertGreaterThan(try online.digest(Self.nexus).blocks.values.map(\.height).max() ?? 0, deepest.height + 64,
                             "the carriers are past the body window")

        var late = Host(fixture.world, network: fixture.world.cas, hosted: [])
        for grind in fixture.mined { await late.step(.mined(grind)) }
        try await catchUp(&late, fixture)
        XCTAssertEqual(try late.digest(Self.alpha).blocks, reference.blocks)

        var restarted = Host(fixture.world, network: fixture.world.cas)
        restarted.lostDerivations = fixture.carrierCIDs.subtracting([try BlockHeader(node: fixture.carriers[0].root).rawCID])
        for grind in fixture.mined { await restarted.step(.mined(grind)) }
        XCTAssertNotEqual(try restarted.digest(Self.alpha).blocks, reference.blocks, "derivations were lost")
        restarted.lostDerivations = []
        try restarted.restart()
        await restarted.step(.tick)
        XCTAssertEqual(try restarted.digest(Self.alpha).blocks, reference.blocks)
        XCTAssertTrue(online.disconnects.isEmpty && late.disconnects.isEmpty && restarted.disconnects.isEmpty)
    }
}
