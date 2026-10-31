import Foundation
import Lattice
@testable import LatticeNodeCore
@testable import LatticeNodeSim
import UInt256
import XCTest
import cashew

/// A parent block that commits a child block by CID alone (a `child/X =
/// C@P` commitment, whose miner hosts no X and makes no proof) has its grind
/// derived at C, push only: by the host that holds C's bytes (normally C's
/// author), when the carrier is weighed, and by any host of X when C
/// arrives with or without proofs (each of its committers). No host fetches
/// C: one nobody published is not credited yet. Nothing of a derivation is
/// stored: a node online throughout, one hosting X late and one restarted
/// from its stores end alike.
final class DerivedChildGrindTests: XCTestCase {
    private static let now = World.genesisTime + 1_000_000
    private static let nexus = LevelWorld.nexus
    private static let alpha = LevelWorld.alpha
    private static let beta = LevelWorld.beta
    private static let interval = LevelWorld.interval
    private static let t = World.genesisTime

    private struct Derived: Hashable {
        let path: ChainPath
        let cid: String
        let carrier: String
    }

    /// One proof check, a peer's or a derived one, by block and root.
    private struct Check: Hashable {
        let path: ChainPath
        let cid: String
        let root: String
    }

    /// One host and the peers it hears: what it sends is kept to answer.
    /// Its own content is what it weighed and what it authored.
    private struct Host {
        let world: LevelWorld
        var core: NodeCore
        var store: HostStore
        /// Blocks this host holds the bytes of without having weighed them.
        let authored = SimCAS()
        var sent: [(path: ChainPath, message: SyncMessage)] = []
        var derived: [Derived] = []
        var checks: [Check] = []
        var disconnects: [PeerID] = []
        var position: [ChainPath: UInt64] = [:]
        /// Blocks whose bodies the content layer never serves.
        var withheldBodies: Set<String> = []
        /// Carriers whose derivations are lost (a crash before they ran).
        var lostDerivations: Set<String> = []
        /// When set, peer proof checks answer only when `deferred` is run.
        var deferChecks = false
        var deferred: [NodeEvent] = []
        /// When set, derivations run only when `runHeldDerivations` is.
        var holdDerivations = false
        var heldDerivations: [(path: ChainPath, job: ChildDeriveJob)] = []

        init(_ world: LevelWorld, hosted: Set<ChainPath>? = nil) {
            self.world = world
            core = NodeCore(root: world.rootBootstrap.tree.detached(), hosted: hosted ?? world.hosted)
            store = HostStore(world: world)
        }

        /// What this host holds of its own: its headers and child indexes,
        /// and what it authored.
        func own() -> SimCAS {
            let held = SimCAS(authored.all)
            for level in store.levels.values {
                for (cid, stored) in level.headers {
                    if let block = stored.block.toData() { held.put([cid: block]) }
                    if let children = stored.children.toData() { held.put([stored.block.children.rawCID: children]) }
                }
            }
            return held
        }

        /// This host authored `block`: it holds its bytes, child index and
        /// a genesis's spec, and has published none of them.
        func author(_ block: SimBlock) {
            let keys = [block.cid, block.block.children.rawCID, block.block.spec.rawCID]
            authored.put(world.cas.all.filter { keys.contains($0.key) })
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
                        checks.append(Check(path: path, cid: job.childCID, root: job.proof.rootCID))
                        let answer = NodeEvent.level(path, .proofVerified(job, await job.run(block)))
                        if deferChecks { deferred.append(answer) } else { queue.append(answer) }
                    case .level(let path, .lookupProofs(let cids)):
                        for cid in cids where !store.proofs(path, cid).isEmpty {
                            queue.append(.level(path, .proofsFound(childCID: cid, store.proofs(path, cid))))
                        }
                    case .level(let path, .deriveProof(let job)):
                        // From this host's own content only.
                        derived.append(Derived(path: path, cid: job.childCID, carrier: job.carrier))
                        guard !lostDerivations.contains(job.carrier) else { break }
                        if holdDerivations { heldDerivations.append((path, job)) } else { queue.append(await derive(job, at: path)) }
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

        /// `job` run from this host's own content, as it stands now.
        mutating func derive(_ job: ChildDeriveJob, at path: ChainPath) async -> NodeEvent {
            let held = job.block ?? store.levels[path]?.headers[job.childCID]?.block
            let upstream = store.proofs(Array(path.dropLast()), job.carrier)
            let derivation = await job.run(held: held, upstream: upstream, fetcher: own())
            checks += derivation.checks.map { Check(path: path, cid: $0.0.childCID, root: $0.0.proof.rootCID) }
            return .level(path, .derived(derivation))
        }

        /// The held derivations, run late in the order issued.
        mutating func runHeldDerivations() async {
            holdDerivations = false
            let held = heldDerivations
            heldDerivations = []
            for (path, job) in held { await step(await derive(job, at: path)) }
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

        /// Checks run per block and root at `path`.
        func checkCounts(at path: ChainPath) -> [Check: Int] {
            checks.filter { $0.path == path }.reduce(into: [:]) { $0[$1, default: 0] += 1 }
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

    private func host(_ fixture: Committed) async -> Host {
        var host = Host(fixture.world)
        for grind in fixture.setup { await host.step(.mined(grind)) }
        await host.meet(Self.miner)
        return host
    }

    /// C's author holds C in its store alone. It hears B from a miner
    /// hosting no Alpha, derives B's grind at C, credits it and serves C
    /// with the proof; B2 extends B and C is credited with B's run. A second
    /// host of Alpha weighs B, holds no C and credits nothing (nothing is
    /// fetched or remembered), then credits the same work once C reaches it
    /// over gossip with the author's proof: the peer's check and C's own
    /// derivation, which credit once.
    func testTheAuthorDerivesAndServesAndAPeerCreditsTheSameWork() async throws {
        let fixture = try await committedWorld()
        var author = await host(fixture)
        author.author(fixture.c)

        await author.relay(fixture.b, at: Self.nexus, from: Self.miner)
        XCTAssertEqual(try author.digest(Self.nexus).canonicalTip, fixture.b.cid)
        XCTAssertEqual(author.derived, [Derived(path: Self.alpha, cid: fixture.c.cid, carrier: fixture.b.cid)])
        var alpha = try author.digest(Self.alpha)
        XCTAssertGreaterThan(try XCTUnwrap(alpha.blocks[fixture.c.cid]?.grinds[fixture.b.cid], "C weighs by B's grind"), .zero)
        XCTAssertEqual(alpha.canonicalTip, fixture.c.cid)
        let served = author.store.proofs(Self.alpha, fixture.c.cid)
        XCTAssertEqual(served.map(\.rootCID), [fixture.b.cid], "the proof is saved, to serve with C")
        await author.relay(fixture.b2, at: Self.nexus, from: Self.miner)
        alpha = try author.digest(Self.alpha)
        XCTAssertEqual(alpha.blocks[fixture.c.cid]?.grinds[try Self.runID(fixture.b.cid)], workForTarget(fixture.b2.block.target),
                       "B2's work reaches C through B's run")
        XCTAssertEqual(author.derived.count, 1, "a carrier already credited is not derived again")

        var peer = await host(fixture)
        await peer.relay(fixture.b, at: Self.nexus, from: Self.miner)
        XCTAssertNil(try peer.digest(Self.alpha).blocks[fixture.c.cid], "C is unavailable here: not credited")
        let proofs = try XCTUnwrap(peer.core.levels[Self.alpha]?.sync.proofs)
        XCTAssertTrue(proofs.awaiting.isEmpty && proofs.deriving.isEmpty,
                      "nothing is remembered of a block not held")
        XCTAssertTrue(peer.checks.isEmpty)
        await peer.meet(Self.alphaHost)
        await peer.relay(fixture.c, at: Self.alpha, from: Self.alphaHost, proofs: served)
        await peer.relay(fixture.b2, at: Self.nexus, from: Self.miner)
        XCTAssertEqual(try peer.digest(Self.alpha).blocks, alpha.blocks, "the same work, from the author's proof")
        let checks = peer.checkCounts(at: Self.alpha)
        XCTAssertEqual(Set(checks.keys), [Check(path: Self.alpha, cid: fixture.c.cid, root: fixture.b.cid)])
        XCTAssertLessThanOrEqual(checks.values.reduce(0, +), 2, "the peer's check and the derived one")
        XCTAssertEqual(peer.derived.filter { $0.cid == fixture.c.cid }.count, 2, "the read on B, which held nothing, and C's arrival")
        XCTAssertTrue(author.disconnects.isEmpty && peer.disconnects.isEmpty)
    }

    /// B is weighed and its derivation, which reads nothing, runs late: C
    /// arrives without proofs meanwhile and is derived again, not held back
    /// by the stale one. C is credited, as when C arrives after the read.
    func testADerivationInFlightDoesNotHoldBackOneOnArrival() async throws {
        let fixture = try await committedWorld()
        var late = await host(fixture)
        late.holdDerivations = true
        await late.relay(fixture.b, at: Self.nexus, from: Self.miner)
        await late.meet(Self.alphaHost)
        await late.relay(fixture.c, at: Self.alpha, from: Self.alphaHost)
        XCTAssertNil(try late.digest(Self.alpha).blocks[fixture.c.cid], "nothing has run yet")
        XCTAssertEqual(late.heldDerivations.map(\.job.carrier), [fixture.b.cid, fixture.b.cid],
                       "the read on B, and C's arrival beside it")
        await late.runHeldDerivations()
        XCTAssertNotNil(try late.digest(Self.alpha).blocks[fixture.c.cid]?.grinds[fixture.b.cid], "C is credited")
        XCTAssertEqual(late.core.levels[Self.alpha]?.sync.proofs.deriving.isEmpty, true)

        var after = await host(fixture)
        await after.relay(fixture.b, at: Self.nexus, from: Self.miner)
        await after.meet(Self.alphaHost)
        await after.relay(fixture.c, at: Self.alpha, from: Self.alphaHost)
        XCTAssertEqual(try late.digest(Self.alpha), try after.digest(Self.alpha), "arrival order does not matter")
        XCTAssertTrue(late.disconnects.isEmpty && after.disconnects.isEmpty)
    }

    /// B and its sibling S both commit C: each one's grind is credited at C,
    /// the second while C is held.
    func testSiblingCarriersOfOneBlockBothCreditIt() async throws {
        let fixture = try await committedWorld()
        var host = await host(fixture)
        host.author(fixture.c)
        await host.relay(fixture.b, at: Self.nexus, from: Self.miner)
        await host.relay(fixture.sibling, at: Self.nexus, from: Self.miner)
        XCTAssertEqual(host.derived.map(\.carrier), [fixture.b.cid, fixture.sibling.cid])
        let grinds = try XCTUnwrap(try host.digest(Self.alpha).blocks[fixture.c.cid]?.grinds)
        XCTAssertNotNil(grinds[fixture.b.cid], "B's grind")
        XCTAssertNotNil(grinds[fixture.sibling.cid], "S's grind, at a held C")
        XCTAssertEqual(Set(host.store.proofs(Self.alpha, fixture.c.cid).map(\.rootCID)), [fixture.b.cid, fixture.sibling.cid])
    }

    /// A header with no proofs that a weighed parent block commits is taken
    /// and derived for every committer; with no committer it is dropped,
    /// as before.
    func testAProoflessGossipIsTakenOnlyWhenCommitted() async throws {
        let fixture = try await committedWorld()
        var host = await host(fixture)
        await host.relay(fixture.b, at: Self.nexus, from: Self.miner)
        await host.relay(fixture.sibling, at: Self.nexus, from: Self.miner)
        XCTAssertNil(try host.digest(Self.alpha).blocks[fixture.c.cid])
        await host.meet(Self.alphaHost)
        await host.relay(fixture.c, at: Self.alpha, from: Self.alphaHost)
        let grinds = try XCTUnwrap(try host.digest(Self.alpha).blocks[fixture.c.cid]?.grinds)
        XCTAssertEqual(Set(grinds.keys), [fixture.b.cid, fixture.sibling.cid], "each committer's grind is derived and credited")
        XCTAssertTrue(host.disconnects.isEmpty)

        var stranger = await self.host(fixture)
        await stranger.meet(Self.alphaHost)
        await stranger.relay(fixture.c, at: Self.alpha, from: Self.alphaHost)
        XCTAssertEqual(stranger.core.levels[Self.alpha]?.sync.proofs.awaiting.isEmpty, true, "no committer: dropped")
        XCTAssertTrue(stranger.derived.isEmpty)
    }

    /// A peer's bogus proof for (C, B) arrives first: it fails, the peer is
    /// blamed, and C is still credited with B's grind by derivation.
    func testABogusProofSentFirstCannotLeaveTheBlockUncredited() async throws {
        let fixture = try await committedWorld()
        var host = await host(fixture)
        await host.relay(fixture.b, at: Self.nexus, from: Self.miner)
        await host.meet(Self.alphaHost)
        let bogus = ChildBlockProof(rootCID: fixture.b.cid, directoryPath: [Self.alpha[1]], entries: [])
        await host.relay(fixture.c, at: Self.alpha, from: Self.alphaHost, proofs: [bogus])
        XCTAssertEqual(host.disconnects, [Self.alphaHost], "the peer is blamed")
        XCTAssertNotNil(try host.digest(Self.alpha).blocks[fixture.c.cid]?.grinds[fixture.b.cid], "C is credited by derivation")
        XCTAssertEqual(host.checkCounts(at: Self.alpha)[Check(path: Self.alpha, cid: fixture.c.cid, root: fixture.b.cid)], 2,
                       "the bogus check, then the derived one")
    }

    /// A peer gossips C with a copy of the real proof for (C, B), then is
    /// gone before that proof's check answers: its proof is forgotten and
    /// its late answer lands on nothing, yet C is credited with B's grind
    /// without a restart, by derivation.
    func testAPeerGoneBeforeItsProofIsCheckedCannotLeaveTheBlockUncredited() async throws {
        let fixture = try await committedWorld()
        var host = await host(fixture)
        await host.relay(fixture.b, at: Self.nexus, from: Self.miner)
        await host.meet(Self.alphaHost)
        let proof = try await ChildBlockProof.generate(
            rootHeader: BlockHeader(node: fixture.b.block), childDirectory: Self.alpha[1], fetcher: fixture.world.cas
        )
        host.deferChecks = true
        await host.relay(fixture.c, at: Self.alpha, from: Self.alphaHost, proofs: [proof])
        XCTAssertFalse(host.deferred.isEmpty, "the peer's check has not answered")
        await host.step(.peerGone(Self.alphaHost))
        XCTAssertEqual(host.core.levels[Self.alpha]?.sync.proofs.verifying.isEmpty, true, "the peer's proof is forgotten")
        for answer in host.deferred { await host.step(answer) }
        XCTAssertNotNil(try host.digest(Self.alpha).blocks[fixture.c.cid]?.grinds[fixture.b.cid], "C is credited by derivation")
        XCTAssertTrue(host.disconnects.isEmpty)
    }

    /// At the waiting cap, a header whose derivation is in flight is kept:
    /// the oldest idle header is evicted in its place.
    func testAWaitingHeaderWithADerivationInFlightSurvivesEviction() async throws {
        let fixture = try await committedWorld()
        var host = await host(fixture)
        await host.relay(fixture.b, at: Self.nexus, from: Self.miner)
        await host.meet(Self.alphaHost)
        host.lostDerivations = [fixture.b.cid]
        await host.relay(fixture.c, at: Self.alpha, from: Self.alphaHost)
        var core = try XCTUnwrap(host.core.levels[Self.alpha])
        let waiting = try XCTUnwrap(core.sync.proofs.awaiting[fixture.c.cid])
        XCTAssertNotNil(core.sync.proofs.deriving[fixture.c.cid], "its derivation is in flight")
        let room = core.proofConfig.maxAwaiting - core.sync.proofs.awaiting.count
        for index in 0..<room {
            core.sync.proofs.awaiting["idle-\(index)"] = AwaitingChildProof(
                blockCID: "idle-\(index)", block: fixture.c.block, children: nil, spec: nil, announcers: [],
                sequence: waiting.sequence + 1 + UInt64(index)
            )
        }
        XCTAssertEqual(core.sync.proofs.awaiting.count, core.proofConfig.maxAwaiting)
        XCTAssertTrue(core.makeRoomToAwait())
        XCTAssertNotNil(core.sync.proofs.awaiting[fixture.c.cid], "in flight: never evicted")
        XCTAssertNil(core.sync.proofs.awaiting["idle-0"], "the oldest idle header goes")
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

        var host = Host(world)
        host.author(g)
        await host.step(.mined(n0.grind))
        await host.meet(Self.miner)
        let read = await HeaderEntry.committed(g.cid, at: Self.alpha, fetcher: host.own())
        let entry = try XCTUnwrap(read)
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

        var host = Host(world)
        host.author(c)
        await host.step(.mined(n0.grind))
        await host.meet(Self.miner)
        await host.relay(b, at: Self.nexus, from: Self.miner)
        XCTAssertEqual(try host.digest(Self.nexus).canonicalTip, b.cid)
        XCTAssertEqual(Set(host.derived.map(\.carrier)), [b.cid])
        XCTAssertLessThanOrEqual(host.derived.count, 2, "one per trigger: B weighed, then C taken in from its read")
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

        var host = Host(world)
        host.author(c)
        for grind in [n0.grind, n1.grind] { await host.step(.mined(grind)) }
        await host.meet(Self.miner)
        await host.relay(b.root, at: Self.nexus, from: Self.miner)
        XCTAssertNotNil(try host.digest(Self.nexus).blocks[b.root.cid])
        XCTAssertEqual(Set(host.derived.map(\.carrier)), [b.root.cid])
        XCTAssertLessThanOrEqual(host.derived.count, 2, "one per trigger: B weighed, then C taken in from its read")
        XCTAssertNil(try host.digest(Self.alpha).blocks[c.cid], "no work on the wrong prevState")
        XCTAssertTrue(host.store.proofs(Self.alpha, c.cid).isEmpty)
        XCTAssertTrue(host.disconnects.isEmpty, "no one is blamed")
    }

    // MARK: - Two levels

    /// Three levels: N1 carries Alpha's genesis G and R1 carries A1 on G;
    /// Alpha block A on A1 commits Beta's genesis D by CID (an Alpha
    /// transaction); Nexus block B on R1 commits A by CID; B2 extends B.
    /// With `hardLeaf`, D claims a target B's hash misses, though A's is met.
    private struct Deep {
        let world: LevelWorld
        let setup: [MinedGrind]
        let a: SimBlock
        let d: SimBlock
        let b: SimBlock
        let b2: SimBlock
    }

    private func deepWorld(hardLeaf: Bool = false) async throws -> Deep {
        var builder = try await LevelWorld.Builder(levels: 3)
        let n0 = try await builder.grind(on: try XCTUnwrap(builder.geneses[Self.nexus]), carrying: [], at: Self.t + Self.interval / 2, outcome: .block)
        let g = try await builder.childGenesis(Self.alpha, parentState: n0.root.block.postState.rawCID, at: Self.t + Self.interval)
        let n1 = try await builder.grind(on: n0.root, carrying: [(Self.alpha, g)], at: Self.t + Self.interval, outcome: .block)
        let a1 = try await builder.build(on: g, carrierPrevState: n1.root.block.postState.rawCID, timestamp: Self.t + 2 * Self.interval, nonce: 5)
        let r1 = try await builder.grind(on: n1.root, carrying: [(Self.alpha, a1)], at: Self.t + 2 * Self.interval, outcome: .block)
        let entering = r1.root.block.postState.rawCID
        // D commits A's entering state: A's previous state, A1's post-state.
        let underA = a1.block.postState.rawCID
        let hard = UInt256.max >> 24
        let d: SimBlock
        if hardLeaf {
            let genesis = try await BlockBuilder.buildChildGenesis(
                spec: try XCTUnwrap(builder.specs[Self.beta]), parentState: a1.block.postState,
                timestamp: Self.t + 3 * Self.interval, target: hard, fetcher: builder.cas
            )
            d = try await builder.store(genesis, releaseAt: Self.t + 3 * Self.interval, anchor: nil)
        } else {
            d = try await builder.childGenesis(Self.beta, parentState: underA, at: Self.t + 3 * Self.interval)
        }
        let a = try await builder.build(
            on: a1, carrierPrevState: entering,
            transactions: [try Self.commit(d, parentState: underA, under: Self.beta[2], on: Self.alpha, key: 1)],
            timestamp: Self.t + 3 * Self.interval, nonce: 1
        )
        let unmined = try await builder.build(
            on: r1.root, carrierPrevState: nil,
            transactions: [try Self.commit(a, parentState: entering, under: Self.alpha[1], on: Self.nexus, key: 0)],
            timestamp: Self.t + 3 * Self.interval, nonce: 0
        )
        let (rootTarget, aTarget, dTarget) = (unmined.block.target, a.block.target, d.block.target)
        let mined = builder.mine(unmined.block) { hash in
            rootTarget >= hash && aTarget >= hash && (hardLeaf ? hash > hard : dTarget >= hash)
        }
        let b = try await builder.store(mined, releaseAt: Self.t + 3 * Self.interval, anchor: unmined.anchor)
        let b2 = try await builder.grind(on: b, carrying: [], at: Self.t + 4 * Self.interval, outcome: .block)
        return Deep(world: builder.world(), setup: [n0.grind, n1.grind, r1.grind], a: a, d: d, b: b, b2: b2.root)
    }

    private func host(_ fixture: Deep) async -> Host {
        var host = Host(fixture.world)
        for grind in fixture.setup { await host.step(.mined(grind)) }
        await host.meet(Self.miner)
        host.author(fixture.a)
        host.author(fixture.d)
        return host
    }

    /// A carrier at depth 2 whose own credit is a derived proof: A weighs by
    /// B's derived grind, and D, which A commits a level down, by A's saved
    /// proof extended by A's hop (rooted at B). A's body is withheld: the
    /// header tree does not wait on it.
    func testADerivedCarrierCreditsTheBlockItCommitsByTheComposedPath() async throws {
        let fixture = try await deepWorld()
        var host = await host(fixture)
        host.withheldBodies = [fixture.a.cid]

        await host.relay(fixture.b, at: Self.nexus, from: Self.miner)
        let alpha = try host.digest(Self.alpha)
        XCTAssertNotNil(alpha.blocks[fixture.a.cid]?.grinds[fixture.b.cid], "A weighs by B's derived grind")
        XCTAssertFalse(alpha.executed.contains(fixture.a.cid), "its body never came")
        XCTAssertEqual(host.derived.filter { $0.path == Self.beta }.map(\.carrier), [fixture.a.cid])
        let beta = try host.digest(Self.beta)
        XCTAssertEqual(beta.roots, [fixture.d.cid], "D weighs as Beta's genesis")
        XCTAssertNotNil(beta.blocks[fixture.d.cid]?.grinds[fixture.b.cid])
        XCTAssertEqual(try XCTUnwrap(host.store.proofs(Self.beta, fixture.d.cid).first).directoryPath,
                       [Self.alpha[1], Self.beta[2]], "the path from the root through A")
        XCTAssertTrue(host.disconnects.isEmpty)
    }

    /// A carrier whose grind meets A's target but misses D's: nothing is
    /// credited, and D is derived at most once per trigger (B and B2
    /// weighed, D and A gossiped again), never more.
    func testADerivationThatMissesCreditsNothingAndIsBoundedByItsTriggers() async throws {
        let fixture = try await deepWorld(hardLeaf: true)
        var host = await host(fixture)
        await host.relay(fixture.b, at: Self.nexus, from: Self.miner)
        XCTAssertNotNil(try host.digest(Self.alpha).blocks[fixture.a.cid]?.grinds[fixture.b.cid], "A's target is met")
        XCTAssertNotNil(host.core.levels[Self.beta]?.sync.proofs.awaiting[fixture.d.cid], "D waits")

        await host.relay(fixture.b2, at: Self.nexus, from: Self.miner)
        await host.meet(Self.alphaHost)
        await host.relay(fixture.d, at: Self.beta, from: Self.alphaHost)
        await host.relay(fixture.a, at: Self.alpha, from: Self.alphaHost)
        let derived = host.derived.filter { $0.path == Self.beta }
        XCTAssertEqual(Set(derived), [Derived(path: Self.beta, cid: fixture.d.cid, carrier: fixture.a.cid)])
        XCTAssertLessThanOrEqual(derived.count, 4, "at most one per trigger fired")
        let checks = host.checkCounts(at: Self.beta)
        XCTAssertEqual(Set(checks.keys), [Check(path: Self.beta, cid: fixture.d.cid, root: fixture.b.cid)])
        XCTAssertLessThanOrEqual(checks.values.reduce(0, +), derived.count, "one check per derivation")
        XCTAssertTrue(try host.digest(Self.beta).blocks.isEmpty, "B's hash misses D's target")
        XCTAssertTrue(host.disconnects.isEmpty)
    }

    // MARK: - Merged mining

    /// Plain merged-mining sync: N1 carries Alpha's genesis G and N2 carries
    /// C, and their proofs come with them over gossip. In either arrival
    /// order each grind is credited, checked at most twice (its proof and
    /// its derivation).
    func testMergedMiningSyncCreditsEachGrindWithFewChecks() async throws {
        var builder = try await LevelWorld.Builder(levels: 2)
        let n0 = try await builder.grind(on: try XCTUnwrap(builder.geneses[Self.nexus]), carrying: [], at: Self.t + Self.interval / 2, outcome: .block)
        let g = try await builder.childGenesis(Self.alpha, parentState: n0.root.block.postState.rawCID, at: Self.t + Self.interval)
        let n1 = try await builder.grind(on: n0.root, carrying: [(Self.alpha, g)], at: Self.t + Self.interval, outcome: .block)
        let c = try await builder.build(on: g, carrierPrevState: n1.root.block.postState.rawCID, timestamp: Self.t + 2 * Self.interval, nonce: 1)
        let n2 = try await builder.grind(on: n1.root, carrying: [(Self.alpha, c)], at: Self.t + 2 * Self.interval, outcome: .block)
        let world = builder.world()
        let (gProof, cProof) = (try XCTUnwrap(n1.grind.carried.first).proof, try XCTUnwrap(n2.grind.carried.first).proof)

        for parentFirst in [true, false] {
            var host = Host(world)
            await host.step(.mined(n0.grind))
            await host.meet(Self.miner)
            await host.meet(Self.alphaHost)
            if parentFirst {
                await host.relay(n1.root, at: Self.nexus, from: Self.miner)
                await host.relay(n2.root, at: Self.nexus, from: Self.miner)
            }
            await host.relay(g, at: Self.alpha, from: Self.alphaHost, proofs: [gProof], spec: world.specs[Self.alpha])
            await host.relay(c, at: Self.alpha, from: Self.alphaHost, proofs: [cProof])
            if !parentFirst {
                await host.relay(n1.root, at: Self.nexus, from: Self.miner)
                await host.relay(n2.root, at: Self.nexus, from: Self.miner)
            }
            let alpha = try host.digest(Self.alpha)
            XCTAssertNotNil(alpha.blocks[c.cid]?.grinds[n2.root.cid], "parent first: \(parentFirst)")
            XCTAssertNotNil(alpha.blocks[g.cid]?.grinds[n1.root.cid], "parent first: \(parentFirst)")
            let checks = host.checkCounts(at: Self.alpha)
            XCTAssertEqual(Set(checks.keys), [
                Check(path: Self.alpha, cid: g.cid, root: n1.root.cid),
                Check(path: Self.alpha, cid: c.cid, root: n2.root.cid),
            ], "parent first: \(parentFirst)")
            XCTAssertTrue(checks.values.allSatisfy { $0 <= 2 }, "parent first: \(parentFirst)")
            XCTAssertTrue(host.disconnects.isEmpty)
        }
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
        var host = Host(fixture.world)
        host.author(fixture.c)
        for grind in fixture.mined { await host.step(.mined(grind)) }
        XCTAssertTrue(fixture.carrierCIDs.isSubset(of: try grinds(at: fixture.c.cid, host)))
        XCTAssertEqual(host.derived.filter { $0.cid == fixture.c.cid }.count, fixture.carriers.count, "each carrier once")
        XCTAssertTrue(host.disconnects.isEmpty)
    }

    /// A burst of derived proofs past the per-source cap: a level hosted late
    /// takes C from a peer with one proof, and every other committer of C is
    /// derived at once; each credits, in no source's load.
    func testABurstOfDerivedProofsPastTheSourceCapAllCredit() async throws {
        let fixture = try await carriersWorld(ChildProofConfig().maxPerSource + 6)
        var host = Host(fixture.world, hosted: [])
        for grind in fixture.mined { await host.step(.mined(grind)) }
        try await catchUp(&host, fixture)
        XCTAssertTrue(fixture.carrierCIDs.isSubset(of: try grinds(at: fixture.c.cid, host)))
        XCTAssertEqual(host.derived.filter { $0.cid == fixture.c.cid }.count, fixture.carriers.count,
                       "every committer, the peer's proof's included")
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

    /// Arrival order and restart change nothing once C is published,
    /// carriers deep below the tip included: a node online throughout (C
    /// unavailable until it arrives over gossip with no proof), one hosting
    /// Alpha after every block weighed, and C's author restarted from its
    /// stores after all but one derivation was lost, end with equal Alpha
    /// trees.
    func testOnlineLateAndRestartedHostsAgree() async throws {
        let fixture = try await carriersWorld(ChildProofConfig().maxPerHeader + 4, depth: 70)

        var online = Host(fixture.world)
        for grind in fixture.mined { await online.step(.mined(grind)) }
        XCTAssertNil(try online.digest(Self.alpha).blocks[fixture.c.cid], "unpublished: not credited")
        await online.meet(Self.alphaHost)
        await online.relay(fixture.c, at: Self.alpha, from: Self.alphaHost)
        let reference = try online.digest(Self.alpha)
        XCTAssertTrue(fixture.carrierCIDs.isSubset(of: Set(try XCTUnwrap(reference.blocks[fixture.c.cid]).grinds.keys)))
        let deepest = try XCTUnwrap(try online.digest(Self.nexus).blocks[try BlockHeader(node: fixture.carriers[0].root).rawCID])
        XCTAssertGreaterThan(try online.digest(Self.nexus).blocks.values.map(\.height).max() ?? 0, deepest.height + 64,
                             "the carriers are past the body window")

        var late = Host(fixture.world, hosted: [])
        for grind in fixture.mined { await late.step(.mined(grind)) }
        try await catchUp(&late, fixture)
        XCTAssertEqual(try late.digest(Self.alpha).blocks, reference.blocks)

        var restarted = Host(fixture.world)
        restarted.author(fixture.c)
        restarted.lostDerivations = fixture.carrierCIDs.subtracting([try BlockHeader(node: fixture.carriers[0].root).rawCID])
        for grind in fixture.mined { await restarted.step(.mined(grind)) }
        XCTAssertNotNil(try restarted.digest(Self.alpha).blocks[fixture.c.cid], "C weighs by the one derivation not lost")
        XCTAssertNotEqual(try restarted.digest(Self.alpha).blocks, reference.blocks, "derivations were lost")
        restarted.lostDerivations = []
        try restarted.restart()
        await restarted.step(.tick)
        XCTAssertEqual(try restarted.digest(Self.alpha).blocks, reference.blocks)
        XCTAssertTrue(online.disconnects.isEmpty && late.disconnects.isEmpty && restarted.disconnects.isEmpty)
    }

    /// Restarts over a history with a grind that never credits: W, a
    /// sibling of N1, commits C on N0's post-state while C anchors at N1's.
    /// Each boot derives only the pair not fully credited (B's is), the
    /// second boot exactly the work of the first, and both rebuild the tree.
    func testEachBootDerivesOnlyWhatIsOwedAndTheSameWork() async throws {
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
        let stale = n0.root.block.postState.rawCID
        let w = try await builder.grind(
            on: n0.root, carrying: [],
            transactions: [try Self.commit(c, parentState: stale, under: Self.alpha[1], on: Self.nexus, key: 1)],
            at: Self.t + 2 * Self.interval, outcome: .block
        )
        let world = builder.world()

        var host = Host(world)
        host.author(c)
        for grind in [n0.grind, n1.grind, b.grind, w.grind] { await host.step(.mined(grind)) }
        let reference = try host.digest(Self.alpha)
        XCTAssertNotNil(reference.blocks[c.cid]?.grinds[b.root.cid], "B's grind credits C")
        XCTAssertNil(reference.blocks[c.cid]?.grinds[w.root.cid], "W's never does")

        var boots: [[Derived]] = []
        for _ in 0..<2 {
            host.derived = []
            try host.restart()
            await host.step(.tick)
            XCTAssertEqual(try host.digest(Self.alpha).blocks, reference.blocks)
            boots.append(host.derived)
        }
        XCTAssertEqual(boots[0], [Derived(path: Self.alpha, cid: c.cid, carrier: w.root.cid)], "only the pair not fully credited")
        XCTAssertEqual(boots[1], boots[0], "the second boot does the first's work, no more")
        XCTAssertTrue(host.disconnects.isEmpty)
    }
}
