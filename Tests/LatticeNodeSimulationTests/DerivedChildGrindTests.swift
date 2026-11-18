import Foundation
import Lattice
@testable import LatticeNodeCore
@testable import LatticeNodeSim
import UInt256
import XCTest
import cashew

/// A parent block that commits a child block by CID alone (a `child/X =
/// C@P` commitment, whose miner hosts no X and makes no proof) has its grind
/// derived at C, push only: when the carrier is weighed, for a C the host
/// holds, awaits or has pending, and when C arrives by gossip or a local
/// submit, with or without proofs (each of its committers). No host fetches
/// C and none records an authored block: its author submits it until it is
/// weighed. Nothing of a derivation is stored: a node online throughout,
/// one hosting X late and one restarted from its stores end alike.
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
    /// Its own content is what it weighed.
    private struct Host {
        let world: LevelWorld
        var core: NodeCore
        var store: HostStore
        var sent: [(path: ChainPath, message: SyncMessage)] = []
        var derived: [Derived] = []
        var checks: [Check] = []
        /// Peer proofs the host asked the shell to check, and the size of
        /// each verify job it asked for.
        var peerChecks = 0
        var peerChecksAt: [ChainPath: Int] = [:]
        var verifyJobs: [Int] = []
        /// The persists of each step that applied verify answers.
        var answerPersists: [Int] = []
        /// What each peer serves when asked (`getData`), answered as the
        /// request is sent, by level.
        var serving: [ChainPath: [PeerID: [String: HeaderEntry]]] = [:]
        /// Each peer's whole log, by level, which answers every stream
        /// request as it is sent.
        var logs: [ChainPath: [PeerID: [String]]] = [:]
        var disconnects: [PeerID] = []
        /// Child indexes asked for by CID, and of whom.
        var fetches: [(peer: PeerID, cid: String)] = []
        /// Each peer's log position, per level.
        var position: [ChainPath: [PeerID: UInt64]] = [:]
        /// Blocks whose bodies the content layer never serves.
        var withheldBodies: Set<String> = []
        /// Blocks whose bodies no provider has: the content layer answers
        /// every ask for them `bodyUnavailable`.
        var unavailableBodies: Set<String> = []
        /// Carriers whose derivations credit nothing (their content could
        /// not be read when they ran).
        var lostDerivations: Set<String> = []
        /// When set, peer proof checks answer only when `deferred` is run.
        var deferChecks = false
        var deferred: [NodeEvent] = []
        /// When set, derivations run only when `runHeldDerivations` is.
        var holdDerivations = false
        var heldDerivations: [(path: ChainPath, job: ChildDeriveJob)] = []
        let config: ChainCoreConfig
        /// Each level traced against lattice-formal's model (`GrindTracer`).
        var tracers: [GrindTracer] = []

        init(_ world: LevelWorld, hosted: Set<ChainPath>? = nil, config: ChainCoreConfig = ChainCoreConfig()) {
            self.world = world
            self.config = config
            core = NodeCore(root: world.rootBootstrap.tree.detached(), hosted: hosted ?? world.hosted, config: config)
            store = HostStore(world: world)
        }

        /// Trace `path` from here on, as `name`.
        mutating func trace(_ name: String, at path: ChainPath = DerivedChildGrindTests.alpha, _ fixture: GrindTraceFixture) {
            tracers.append(GrindTracer(name: name, path: path, fixture: fixture, cap: config.proofs.maxAwaiting, core: core))
        }

        /// The test changed the core's state from outside a step.
        func tamper(_ what: String) {
            for tracer in tracers { tracer.tamper(core, what) }
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

        /// The author submits `block` here, its bytes as the route takes
        /// them: whether the host holds it after (weighed, pending or
        /// waiting for a proof).
        @discardableResult
        mutating func submit(_ block: SimBlock, at path: ChainPath, spec: ChainSpec? = nil) async -> Bool {
            let bytes = Block(data: block.block.toData() ?? Data()) ?? block.block
            await step(.level(path, .submitted(HeaderEntry(block: bytes, children: block.children, spec: spec))))
            guard let level = core.levels[path] else { return false }
            return level.tree.contains(blockHash: block.cid) || level.sync.pending.entries[block.cid] != nil
                || level.sync.proofs.awaiting[block.cid] != nil
        }

        mutating func step(_ event: NodeEvent) async {
            var queue = [event]
            while !queue.isEmpty {
                let next = queue.removeFirst()
                let before = tracers.map { $0.snapshot(core) }
                let effects = core.step(next, now: DerivedChildGrindTests.now)
                for (tracer, snap) in zip(tracers, before) { tracer.record(next, before: snap, after: core, effects: effects) }
                if case .level(_, .proofsVerified) = next {
                    answerPersists.append(effects.filter { if case .persist = $0 { return true }; return false }.count)
                }
                for effect in effects {
                    switch effect {
                    case .persist(let batch):
                        store.append(batch)
                    case .level(let path, .fetchBody(let cid)):
                        if unavailableBodies.contains(cid) {
                            queue.append(.level(path, .bodyUnavailable(cid: cid)))
                        } else if !withheldBodies.contains(cid) {
                            queue.append(.level(path, .bodyFetched(cid: cid)))
                        }
                    case .level(let path, .send(let peer, let message)):
                        sent.append((path, message))
                        if case .getStream(let id, _, let after, _) = message, let log = logs[path]?[peer] {
                            let entries = log.enumerated().dropFirst(Int(after)).map {
                                StreamEntry(position: UInt64($0.offset + 1), entry: .header($0.element))
                            }
                            queue.append(.received(peer, path, .stream(StreamPage(requestID: id, logID: "peer", entries: entries, hasMore: false))))
                        }
                        if case .getData(let id, let cids) = message, let served = serving[path]?[peer] {
                            let entries = cids.compactMap { served[$0] }
                            if !entries.isEmpty {
                                queue.append(.received(peer, path, .headers(HeadersResponse(requestID: id, entries: entries, hasMore: false))))
                            }
                        }
                        if case .getAncestors(let id, let cid, let max) = message, let served = serving[path]?[peer] {
                            var entries: [HeaderEntry] = []
                            var next: String? = cid
                            while let at = next, let entry = served[at], entries.count < max {
                                entries.append(entry)
                                next = entry.block.parent?.rawCID
                            }
                            queue.append(.received(peer, path, .headers(HeadersResponse(requestID: id, entries: entries, hasMore: false))))
                        }
                    case .level(_, .fetchByCID(let peer, let cid)):
                        fetches.append((peer, cid))
                    case .level(let path, .verifyProofs(let batch)):
                        for job in batch.jobs { checks.append(Check(path: path, cid: job.childCID, root: job.proof.rootCID)) }
                        peerChecks += batch.jobs.count
                        peerChecksAt[path, default: 0] += batch.jobs.count
                        verifyJobs.append(batch.jobs.count)
                        let headers = store.levels[path]?.headers ?? [:]
                        let answer = NodeEvent.level(path, .proofsVerified(batch.run { headers[$0]?.block }))
                        if deferChecks { deferred.append(answer) } else { queue.append(answer) }
                    case .level(let path, .deriveProof(let job)):
                        // From this host's own content only.
                        derived.append(Derived(path: path, cid: job.childCID, carrier: job.carrier))
                        guard !lostDerivations.contains(job.carrier) else {
                            queue.append(.level(path, .derived(ChildDerivation(job: job, checks: []))))
                            break
                        }
                        if holdDerivations { heldDerivations.append((path, job)) } else { queue.append(await derive(job, at: path)) }
                    case .connect(let path, let jobs):
                        queue.append(.level(path, await ConnectRun.connected(
                            jobs, fetcher: world.cas, parentFacts: core.parentFacts(for: path), now: DerivedChildGrindTests.now
                        )))
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

        /// A peer whose logs this host reads from their start (a child
        /// level's once its parent level caught up).
        mutating func meet(_ peer: PeerID) async {
            await step(.peerReady(peer))
            var asked = take()
            while !asked.isEmpty {
                for (path, message) in asked {
                    guard case .getStream(let id, _, _, _) = message else { continue }
                    await step(.received(peer, path, .stream(StreamPage(requestID: id, logID: "peer", entries: [], hasMore: false))))
                }
                asked = take()
            }
        }

        /// `peer` logs a header and serves it (with `proofs`, and its child
        /// index unless not `inline`) when asked.
        mutating func relay(
            _ block: SimBlock, at path: ChainPath, from peer: PeerID, proofs: [ChildBlockProof] = [], spec: ChainSpec? = nil,
            inline: Bool = true
        ) async {
            await relay(block, logged: .header(block.cid), at: path, from: peer, proofs: proofs, spec: spec, inline: inline)
        }

        /// `peer` logs `proof` of `block`, a header this host already holds,
        /// and serves the header with that proof when asked: gossip that
        /// adds a proof to a held block.
        mutating func relayProof(_ block: SimBlock, _ proof: ChildBlockProof, at path: ChainPath, from peer: PeerID) async {
            await relay(block, logged: .proof(proof.rootCID, of: block.cid), at: path, from: peer, proofs: [proof])
        }

        /// `peer` logs `blocks` as one stream page and serves them as one
        /// headers page, each with its proofs, from then on whenever asked.
        mutating func relayPage(_ blocks: [(block: SimBlock, proofs: [ChildBlockProof])], at path: ChainPath, from peer: PeerID) async {
            var entries: [StreamEntry] = []
            for (block, _) in blocks {
                position[path, default: [:]][peer, default: 0] += 1
                entries.append(StreamEntry(position: position[path]![peer]!, entry: .header(block.cid)))
            }
            for (block, proofs) in blocks {
                serving[path, default: [:]][peer, default: [:]][block.cid] = HeaderEntry(
                    block: block.block, children: block.children, proofs: proofs
                )
            }
            await step(.received(peer, path, .stream(StreamPage(requestID: 0, logID: "peer", entries: entries, hasMore: false))))
        }

        private mutating func relay(
            _ block: SimBlock, logged: LogEntry, at path: ChainPath, from peer: PeerID, proofs: [ChildBlockProof],
            spec: ChainSpec? = nil, inline: Bool = true
        ) async {
            position[path, default: [:]][peer, default: 0] += 1
            await step(.received(peer, path, .stream(StreamPage(
                requestID: 0, logID: "peer",
                entries: [StreamEntry(position: position[path]![peer]!, entry: logged)], hasMore: false
            ))))
            for (sentAt, message) in take() where sentAt == path {
                guard case .getData(let id, let cids) = message, cids.contains(block.cid) else { continue }
                await step(.received(peer, path, .headers(HeadersResponse(
                    requestID: id,
                    entries: [HeaderEntry(
                        block: block.block, children: inline ? block.children : nil, proofs: proofs, spec: spec
                    )],
                    hasMore: false
                ))))
            }
        }

        mutating func take() -> [(path: ChainPath, message: SyncMessage)] {
            defer { sent = [] }
            return sent
        }

        /// The host as its stores alone rebuild it, hosting what it hosted:
        /// what the shell ran (held derivations, deferred checks) is lost
        /// with the process.
        mutating func restart() throws {
            core = try NodeCore.restore(
                root: try XCTUnwrap(store.records[DerivedChildGrindTests.nexus]),
                facts: store.levels.mapValues { StoredFacts($0.facts) },
                specs: store.levels.mapValues { $0.headers.values.compactMap(\.spec) },
                hosted: core.hosted,
                config: config
            )
            heldDerivations = []
            deferred = []
            for tracer in tracers { tracer.booting = true }
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

    /// `replacing` is the commitment the state already holds, if any.
    private static func commit(
        _ child: SimBlock, parentState: String, under directory: String, on chain: ChainPath, key index: Int,
        replacing: (child: SimBlock, parentState: String)? = nil
    ) throws -> Transaction {
        let key = SimTransactions.keys[index]
        let separator = String(UnicodeScalar(CHILD_COMMITMENT_PARENT_STATE_SEPARATOR))
        let body = try HeaderImpl(node: TransactionBody(
            accountActions: [],
            actions: [Action(
                key: CHILD_COMMITMENT_KEY_PREFIX + directory, oldValue: replacing.map { $0.child.cid + separator + $0.parentState },
                newValue: child.cid + separator + parentState
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

    /// Each host's traced levels are written (with `DERIVED_TRACE_DIR`) and
    /// must have needed no step outside the model.
    override func tearDown() async throws {
        for trace in try GrindTracer.flush() {
            XCTAssertEqual(trace.anomalies, [], trace.name)
        }
    }

    /// This test's name, to name its traces.
    private var testName: String {
        let tail = name.split(whereSeparator: { $0 == " " || $0 == "." }).last.map(String.init) ?? name
        return tail.hasSuffix("]") ? String(tail.dropLast()) : tail
    }

    // MARK: - One carrier

    /// N0 and N1 (carrying Alpha's genesis G) mined as usual; C on G; B and
    /// its sibling S on N1 each commit C by CID through a transaction (their
    /// miners host no Alpha and make no proof); B2 on B commits nothing.
    /// D1 and D2, C's siblings on G, are committed by nothing.
    private struct Committed {
        let world: LevelWorld
        let setup: [MinedGrind]
        let g: SimBlock
        let c: SimBlock
        let b: SimBlock
        let sibling: SimBlock
        let b2: SimBlock
        let d: [SimBlock]
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
        var d: [SimBlock] = []
        for nonce in [UInt64(2), 3] {
            d.append(try await builder.build(on: g, carrierPrevState: entering, timestamp: Self.t + 2 * Self.interval, nonce: nonce))
        }
        return Committed(
            world: builder.world(), setup: [n0.grind, n1.grind], g: g, c: c, b: b.root, sibling: sibling.root, b2: b2.root, d: d
        )
    }

    private func host(_ fixture: Committed, _ role: String = "host") async -> Host {
        var host = Host(fixture.world)
        for grind in fixture.setup { await host.step(.mined(grind)) }
        var labels = GrindTraceFixture()
        labels.child(fixture.c.cid, "C")
        labels.rootCarrier(fixture.b.cid, "B", commits: "C")
        labels.rootCarrier(fixture.sibling.cid, "S", commits: "C")
        host.trace("\(testName)-\(role)", labels)
        await host.meet(Self.miner)
        return host
    }

    /// C's author hears B from a miner hosting no Alpha, then submits C: B's
    /// grind is derived at C and credited, and C is served with the proof;
    /// B2 extends B and C is credited with B's run. A second host of Alpha
    /// weighs B, knows no C and derives nothing (nothing is fetched or
    /// remembered), then credits the same work once C reaches it over
    /// gossip with the author's proof: the peer's check and C's own
    /// derivation, which credit once.
    func testTheAuthorSubmitsAndServesAndAPeerCreditsTheSameWork() async throws {
        let fixture = try await committedWorld()
        var author = await host(fixture, "author")

        await author.relay(fixture.b, at: Self.nexus, from: Self.miner)
        XCTAssertEqual(try author.digest(Self.nexus).canonicalTip, fixture.b.cid)
        XCTAssertTrue(author.derived.isEmpty, "C is not known here yet")
        let held = await author.submit(fixture.c, at: Self.alpha)
        XCTAssertTrue(held)
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

        var peer = await host(fixture, "peer")
        await peer.relay(fixture.b, at: Self.nexus, from: Self.miner)
        XCTAssertNil(try peer.digest(Self.alpha).blocks[fixture.c.cid], "C is unavailable here: not credited")
        let proofs = try XCTUnwrap(peer.core.levels[Self.alpha]?.sync.proofs)
        XCTAssertTrue(proofs.awaiting.isEmpty && proofs.deriving.isEmpty,
                      "nothing is remembered of a block not held")
        XCTAssertTrue(peer.checks.isEmpty && peer.derived.isEmpty)
        await peer.meet(Self.alphaHost)
        await peer.relay(fixture.c, at: Self.alpha, from: Self.alphaHost, proofs: served)
        await peer.relay(fixture.b2, at: Self.nexus, from: Self.miner)
        XCTAssertEqual(try peer.digest(Self.alpha).blocks, alpha.blocks, "the same work, from the author's proof")
        let checks = peer.checkCounts(at: Self.alpha)
        XCTAssertEqual(Set(checks.keys), [Check(path: Self.alpha, cid: fixture.c.cid, root: fixture.b.cid)])
        XCTAssertLessThanOrEqual(checks.values.reduce(0, +), 2, "the peer's check and the derived one")
        XCTAssertEqual(peer.derived.filter { $0.cid == fixture.c.cid }.count, 1, "C's arrival")
        XCTAssertTrue(author.disconnects.isEmpty && peer.disconnects.isEmpty)
    }

    /// A child block its author submits here is pushed even before Alpha is
    /// synced: a block this node was handed to publish may be canonical and
    /// adds weight. It is weighed later (by B's derived grind), in a step
    /// that is not `weighOwn`: a weighed header no peer announced is own.
    func testASubmittedChildBlockIsPushedBeforeTheSyncLatch() async throws {
        let fixture = try await committedWorld()
        var author = Host(fixture.world)
        for grind in fixture.setup { await author.step(.mined(grind)) }
        await author.step(.peerReady(Self.miner))
        _ = author.take()
        await author.relay(fixture.b, at: Self.nexus, from: Self.miner)
        let subscriber = PeerID(key: "subscriber", session: 3)
        await author.step(.peerReady(subscriber))
        let (logID, count) = try XCTUnwrap(author.core.levels[Self.alpha].map { ($0.sync.log.id, $0.sync.log.count) })
        await author.step(.received(subscriber, Self.alpha, .getStream(requestID: 1, logID: logID, after: count, own: "")))
        XCTAssertEqual(author.core.levels[Self.alpha]?.sync.peers[subscriber]?.subscribed, true)
        XCTAssertEqual(author.core.levels[Self.alpha]?.synced, false, "no peer's Alpha log is read")
        _ = author.take()

        let held = await author.submit(fixture.c, at: Self.alpha)
        XCTAssertTrue(held)
        XCTAssertTrue(try author.digest(Self.alpha).blocks[fixture.c.cid] != nil, "C is weighed")
        let pushed = author.take().compactMap { sent -> [String]? in
            guard sent.path == Self.alpha, case .stream(let page) = sent.message, page.requestID == 0 else { return nil }
            return page.entries.map(\.entry.block)
        }.flatMap { $0 }
        XCTAssertTrue(pushed.contains(fixture.c.cid), "\(pushed)")
        XCTAssertEqual(author.core.levels[Self.alpha]?.synced, false)
    }

    /// C submitted before B is weighed has no committer: it is dropped as
    /// the same proofless gossip is, and nothing is derived when B is
    /// weighed. The author submits again and C is credited, as when it
    /// submits after B.
    func testASubmitBeforeTheCarrierIsDroppedAndAResubmitCredits() async throws {
        let fixture = try await committedWorld()
        var early = await host(fixture, "early")
        let dropped = await early.submit(fixture.c, at: Self.alpha)
        XCTAssertFalse(dropped, "no committer yet: dropped")
        XCTAssertEqual(early.core.levels[Self.alpha]?.sync.proofs.awaiting.isEmpty, true)
        await early.relay(fixture.b, at: Self.nexus, from: Self.miner)
        XCTAssertTrue(early.derived.isEmpty, "nothing recorded the submit")
        XCTAssertNil(try early.digest(Self.alpha).blocks[fixture.c.cid])
        let held = await early.submit(fixture.c, at: Self.alpha)
        XCTAssertTrue(held)
        XCTAssertNotNil(try early.digest(Self.alpha).blocks[fixture.c.cid]?.grinds[fixture.b.cid], "C is credited")

        var after = await host(fixture, "after")
        await after.relay(fixture.b, at: Self.nexus, from: Self.miner)
        await after.submit(fixture.c, at: Self.alpha)
        XCTAssertEqual(try early.digest(Self.alpha), try after.digest(Self.alpha), "submit order does not matter")
        XCTAssertTrue(early.disconnects.isEmpty && after.disconnects.isEmpty)
    }

    /// C waits for a proof when its derivation is lost, then the host
    /// restarts, unhosts and re-hosts Alpha, or evicts C: nothing of C is
    /// kept, and the author's next submit gets C credited.
    func testAResubmitAfterARestartAnUnhostOrAnEvictionCredits() async throws {
        let fixture = try await committedWorld()
        for disruption in ["restart", "unhost", "eviction"] {
            var host = await host(fixture, disruption)
            await host.relay(fixture.b, at: Self.nexus, from: Self.miner)
            host.lostDerivations = [fixture.b.cid]
            let waiting = await host.submit(fixture.c, at: Self.alpha)
            XCTAssertTrue(waiting, disruption)
            XCTAssertNil(try host.digest(Self.alpha).blocks[fixture.c.cid], disruption)
            switch disruption {
            case "restart":
                try host.restart()
                await host.step(.tick)
            case "unhost":
                await host.step(.unhost(Self.alpha))
                let stored = try XCTUnwrap(host.store.levels[Self.alpha])
                await host.step(.host(
                    Self.alpha, facts: StoredFacts(stored.facts), specs: stored.headers.values.compactMap(\.spec), cursors: [:]
                ))
            default:
                var core = try XCTUnwrap(host.core.levels[Self.alpha])
                core.sync.proofs.deriving = [:]
                let sequence = try XCTUnwrap(core.sync.proofs.awaiting[fixture.c.cid]).sequence
                for index in 0..<(core.proofConfig.maxAwaiting - core.sync.proofs.awaiting.count) {
                    core.sync.proofs.awaiting["idle-\(index)"] = AwaitingChildProof(
                        blockCID: "idle-\(index)", block: fixture.c.block, children: nil, spec: nil, announcers: [],
                        sequence: sequence + 1 + UInt64(index)
                    )
                }
                XCTAssertTrue(core.makeRoomToAwait())
                host.core.levels[Self.alpha] = core
                host.tamper("deriving cleared, awaiting filled, C evicted")
            }
            XCTAssertNil(host.core.levels[Self.alpha]?.sync.proofs.awaiting[fixture.c.cid], "\(disruption): C is gone")
            XCTAssertNil(try host.digest(Self.alpha).blocks[fixture.c.cid], disruption)
            host.lostDerivations = []
            let held = await host.submit(fixture.c, at: Self.alpha)
            XCTAssertTrue(held, disruption)
            XCTAssertNotNil(try host.digest(Self.alpha).blocks[fixture.c.cid]?.grinds[fixture.b.cid], "\(disruption): C is credited")
            XCTAssertTrue(host.disconnects.isEmpty, disruption)
        }
    }

    /// B is weighed, C arrives without proofs and its derivation runs late:
    /// C is credited, as when it runs at once.
    func testADerivationRunLateCreditsAsOneRunAtOnce() async throws {
        let fixture = try await committedWorld()
        var late = await host(fixture, "late")
        late.holdDerivations = true
        await late.relay(fixture.b, at: Self.nexus, from: Self.miner)
        await late.meet(Self.alphaHost)
        await late.relay(fixture.c, at: Self.alpha, from: Self.alphaHost)
        XCTAssertNil(try late.digest(Self.alpha).blocks[fixture.c.cid], "nothing has run yet")
        XCTAssertEqual(late.heldDerivations.map(\.job.carrier), [fixture.b.cid], "C's arrival")
        await late.runHeldDerivations()
        XCTAssertNotNil(try late.digest(Self.alpha).blocks[fixture.c.cid]?.grinds[fixture.b.cid], "C is credited")
        XCTAssertEqual(late.core.levels[Self.alpha]?.sync.proofs.deriving.isEmpty, true)

        var after = await host(fixture, "after")
        await after.relay(fixture.b, at: Self.nexus, from: Self.miner)
        await after.meet(Self.alphaHost)
        await after.relay(fixture.c, at: Self.alpha, from: Self.alphaHost)
        XCTAssertEqual(try late.digest(Self.alpha), try after.digest(Self.alpha), "late or at once alike")
        XCTAssertTrue(late.disconnects.isEmpty && after.disconnects.isEmpty)
    }

    /// A derivation that answers after its count is gone (an unhost and
    /// re-host between) is still applied: the job is pure, credit idempotent.
    func testADerivationOutlivingItsCountIsStillApplied() async throws {
        let fixture = try await committedWorld()
        var late = await host(fixture, "late")
        late.holdDerivations = true
        await late.relay(fixture.b, at: Self.nexus, from: Self.miner)
        await late.meet(Self.alphaHost)
        await late.relay(fixture.c, at: Self.alpha, from: Self.alphaHost)
        late.core.levels[Self.alpha]?.sync.proofs.deriving = [:]
        late.tamper("deriving cleared")
        await late.runHeldDerivations()
        XCTAssertNotNil(try late.digest(Self.alpha).blocks[fixture.c.cid]?.grinds[fixture.b.cid], "C is credited")
        XCTAssertEqual(late.core.levels[Self.alpha]?.sync.proofs.deriving.isEmpty, true)
    }

    /// B and its sibling S both commit C: each one's grind is credited at C,
    /// B's when C is submitted and S's when S is weighed while C is held.
    func testSiblingCarriersOfOneBlockBothCreditIt() async throws {
        let fixture = try await committedWorld()
        var host = await host(fixture)
        await host.relay(fixture.b, at: Self.nexus, from: Self.miner)
        await host.submit(fixture.c, at: Self.alpha)
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

        var stranger = await self.host(fixture, "stranger")
        await stranger.meet(Self.alphaHost)
        await stranger.relay(fixture.c, at: Self.alpha, from: Self.alphaHost)
        XCTAssertEqual(stranger.core.levels[Self.alpha]?.sync.proofs.awaiting.isEmpty, true, "no committer: dropped")
        XCTAssertTrue(stranger.derived.isEmpty)
    }

    /// A peer's bogus proof for (C, B) arrives with C, B weighed: B's grind
    /// is derived, so the bogus proof is never checked (no double work), and
    /// C is credited with B's grind by derivation.
    func testABogusProofForADerivedGrindIsNotCheckedAndTheBlockIsCredited() async throws {
        let fixture = try await committedWorld()
        var host = await host(fixture)
        await host.relay(fixture.b, at: Self.nexus, from: Self.miner)
        await host.meet(Self.alphaHost)
        let bogus = ChildBlockProof(rootCID: fixture.b.cid, directoryPath: [Self.alpha[1]], entries: [])
        for tracer in host.tracers { tracer.label(bogus, as: "bogus") }
        await host.relay(fixture.c, at: Self.alpha, from: Self.alphaHost, proofs: [bogus])
        XCTAssertTrue(host.disconnects.isEmpty, "never checked, so never blamed")
        XCTAssertNotNil(try host.digest(Self.alpha).blocks[fixture.c.cid]?.grinds[fixture.b.cid], "C is credited by derivation")
        XCTAssertEqual(host.peerChecks, 0, "the derived grind's peer proof is not checked")
        XCTAssertEqual(host.checkCounts(at: Self.alpha)[Check(path: Self.alpha, cid: fixture.c.cid, root: fixture.b.cid)], 1,
                       "the derived check alone")
    }

    /// The check of a proof a peer sent is the proof's verdict, not the
    /// peer's: one in flight when the peer is gone still credits the block
    /// (B not yet weighed, so no derivation would), and holds its place
    /// until it answers.
    func testAGonePeersCheckInFlightStillCreditsTheBlock() async throws {
        let fixture = try await committedWorld()
        var host = await host(fixture)
        await host.meet(Self.alphaHost)
        let proof = try await ChildBlockProof.generate(
            rootHeader: BlockHeader(node: fixture.b.block), childDirectory: Self.alpha[1], fetcher: fixture.world.cas
        )
        host.deferChecks = true
        await host.relay(fixture.c, at: Self.alpha, from: Self.alphaHost, proofs: [proof])
        XCTAssertEqual(host.deferred.count, 1, "the peer's check has not answered")
        await host.step(.peerGone(Self.alphaHost))
        XCTAssertEqual(host.core.levels[Self.alpha]?.sync.proofs.verifying.count, 1, "the check keeps its place")
        for answer in host.deferred { await host.step(answer) }
        XCTAssertNotNil(try host.digest(Self.alpha).blocks[fixture.c.cid]?.grinds[fixture.b.cid], "C is credited by the gone peer's proof")
        XCTAssertEqual(host.core.levels[Self.alpha]?.sync.proofs.verifying.isEmpty, true)
        XCTAssertTrue(host.disconnects.isEmpty)
    }

    /// A peer sends C with a bogus proof before B is weighed and is gone
    /// before its check answers: the check keeps its place and fails,
    /// nobody is blamed (the sender is not held), and once B is weighed C
    /// is credited with B's grind by derivation.
    func testAGonePeersFailingCheckBlamesNobodyAndDerivationCredits() async throws {
        let fixture = try await committedWorld()
        var host = await host(fixture)
        await host.meet(Self.alphaHost)
        let bogus = ChildBlockProof(rootCID: fixture.b.cid, directoryPath: [Self.alpha[1]], entries: [])
        for tracer in host.tracers { tracer.label(bogus, as: "bogus") }
        host.deferChecks = true
        await host.relay(fixture.c, at: Self.alpha, from: Self.alphaHost, proofs: [bogus])
        XCTAssertEqual(host.deferred.count, 1, "the peer's check has not answered")
        await host.step(.peerGone(Self.alphaHost))
        XCTAssertEqual(host.core.levels[Self.alpha]?.sync.proofs.verifying.count, 1, "the check keeps its place")
        for answer in host.deferred { await host.step(answer) }
        XCTAssertTrue(host.disconnects.isEmpty, "a gone sender is blamed for nothing")
        XCTAssertEqual(host.core.levels[Self.alpha]?.sync.proofs.verifying.isEmpty, true)
        host.deferChecks = false
        await host.relay(fixture.b, at: Self.nexus, from: Self.miner)
        XCTAssertNotNil(try host.digest(Self.alpha).blocks[fixture.c.cid]?.grinds[fixture.b.cid], "C is credited by derivation")
    }

    /// C waits for a proof (its derivation lost), and a peer then logs B's
    /// proof of C: the host asks for it, takes the header it already holds
    /// with that proof, and C is credited with B's grind.
    func testAProofGossipedForAHeldBlockCreditsIt() async throws {
        let fixture = try await committedWorld()
        var host = await host(fixture)
        await host.relay(fixture.b, at: Self.nexus, from: Self.miner)
        host.lostDerivations = [fixture.b.cid]
        await host.submit(fixture.c, at: Self.alpha)
        XCTAssertNotNil(host.core.levels[Self.alpha]?.sync.proofs.awaiting[fixture.c.cid], "C awaits a proof")
        await host.meet(Self.alphaHost)
        let proof = try await ChildBlockProof.generate(
            rootHeader: BlockHeader(node: fixture.b.block), childDirectory: Self.alpha[1], fetcher: fixture.world.cas
        )
        await host.relayProof(fixture.c, proof, at: Self.alpha, from: Self.alphaHost)
        XCTAssertNotNil(try host.digest(Self.alpha).blocks[fixture.c.cid]?.grinds[fixture.b.cid], "C is credited by the peer's proof")
        XCTAssertEqual(host.checkCounts(at: Self.alpha)[Check(path: Self.alpha, cid: fixture.c.cid, root: fixture.b.cid)], 1)
        XCTAssertTrue(host.disconnects.isEmpty)
    }

    /// At the waiting cap, a header whose derivation is in flight is kept:
    /// the oldest idle header is evicted in its place.
    func testAWaitingHeaderWithADerivationInFlightSurvivesEviction() async throws {
        let fixture = try await committedWorld()
        var host = await host(fixture)
        await host.relay(fixture.b, at: Self.nexus, from: Self.miner)
        await host.meet(Self.alphaHost)
        host.holdDerivations = true
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

    // MARK: - Liveness under the caps

    private static let otherHost = PeerID(key: "other-host", session: 3)

    /// A host of `fixture` that has not weighed B (so C's credit is a peer's
    /// proof, nothing derived) and reads both Alpha hosts. Untraced: these
    /// steps leave the model's assumptions.
    private func provedHost(_ fixture: Committed, config: ChainCoreConfig = ChainCoreConfig()) async throws
        -> (Host, ChildBlockProof)
    {
        var host = Host(fixture.world, config: config)
        for grind in fixture.setup { await host.step(.mined(grind)) }
        await host.meet(Self.miner)
        await host.meet(Self.alphaHost)
        await host.meet(Self.otherHost)
        let proof = try await ChildBlockProof.generate(
            rootHeader: BlockHeader(node: fixture.b.block), childDirectory: Self.alpha[1], fetcher: fixture.world.cas
        )
        return (host, proof)
    }

    /// The pending queue is full of low-hash orphans when C's proof verifies:
    /// C, its parent weighed, its children inline and its hash the largest,
    /// is weighed before the step evicts, and the queue ends within budget.
    func testAProvedHeaderWhoseParentIsWeighedIsWeighedBeforeEviction() async throws {
        let fixture = try await committedWorld()
        let orphanBytes = 10_000
        var config = ChainCoreConfig()
        config.pendingBudget = 4 * orphanBytes
        var (host, proof) = try await provedHost(fixture, config: config)
        for index in 0..<4 {
            host.core.levels[Self.alpha]?.sync.pending.insert(PendingHeader(
                blockCID: "orphan-\(index)", block: fixture.b2.block, children: nil, hash: UInt256(index + 1),
                bytes: orphanBytes, announcers: []
            ))
        }
        XCTAssertEqual(host.core.levels[Self.alpha]?.sync.pending.bytes, config.pendingBudget, "the queue is full")
        await host.relay(fixture.c, at: Self.alpha, from: Self.alphaHost, proofs: [proof])
        XCTAssertNotNil(try host.digest(Self.alpha).blocks[fixture.c.cid]?.grinds[fixture.b.cid], "C is weighed")
        let level = try XCTUnwrap(host.core.levels[Self.alpha])
        XCTAssertLessThanOrEqual(level.sync.pending.bytes, config.pendingBudget)
        XCTAssertTrue(host.disconnects.isEmpty)
    }

    /// C, its child index omitted, is announced by two peers and the first
    /// answers its index as missing: C stays pending with its credit, the
    /// index is asked of the second, and C is weighed on its answer.
    func testAMissingChildIndexMovesTheHeaderToItsNextAnnouncer() async throws {
        let fixture = try await committedWorld()
        var (host, proof) = try await provedHost(fixture)
        await host.relay(fixture.c, at: Self.alpha, from: Self.alphaHost, proofs: [proof], inline: false)
        await host.relay(fixture.c, at: Self.alpha, from: Self.otherHost, inline: false)
        let index = fixture.c.block.children.rawCID
        XCTAssertEqual(host.fetches.map(\.peer), [Self.alphaHost])
        await host.step(.level(Self.alpha, .childIndexFetched(Self.alphaHost, cid: index, nil)))
        let held = try XCTUnwrap(host.core.levels[Self.alpha]?.sync.pending.entries[fixture.c.cid], "C stays pending")
        XCTAssertNotNil(held.evidence[fixture.b.cid], "its credit is kept")
        XCTAssertEqual(host.fetches.map(\.peer), [Self.alphaHost, Self.otherHost], "asked of the next announcer")
        XCTAssertEqual(host.fetches.last?.cid, index)
        await host.step(.level(Self.alpha, .childIndexFetched(Self.otherHost, cid: index, fixture.c.children)))
        XCTAssertNotNil(try host.digest(Self.alpha).blocks[fixture.c.cid]?.grinds[fixture.b.cid], "C is weighed")
        XCTAssertTrue(host.disconnects.isEmpty, "availability, never blame")
    }

    /// C's sole announcer answers its child index as missing: C stays
    /// pending with its credit, waiting for another announcer, and nobody
    /// is blamed.
    func testAMissingChildIndexFromTheSoleAnnouncerLeavesTheHeaderWaiting() async throws {
        let fixture = try await committedWorld()
        var (host, proof) = try await provedHost(fixture)
        await host.relay(fixture.c, at: Self.alpha, from: Self.alphaHost, proofs: [proof], inline: false)
        await host.step(.level(Self.alpha, .childIndexFetched(Self.alphaHost, cid: fixture.c.block.children.rawCID, nil)))
        let held = try XCTUnwrap(host.core.levels[Self.alpha]?.sync.pending.entries[fixture.c.cid], "C stays pending")
        XCTAssertNotNil(held.evidence[fixture.b.cid], "its credit is kept")
        XCTAssertTrue(held.announcers.isEmpty, "it waits for an announcer")
        XCTAssertEqual(host.fetches.count, 1, "asked of nobody else")
        XCTAssertTrue(host.disconnects.isEmpty, "availability, never blame")
        let tick = host.core.step(.tick, now: Self.now + host.config.headersTimeout)
        let asked = tick.contains {
            guard case .level(Self.alpha, .send(Self.alphaHost, .getData(_, let cids))) = $0 else { return false }
            return cids.contains(fixture.c.cid)
        }
        XCTAssertTrue(asked, "its hole is asked again on a tick")
        XCTAssertNotNil(host.core.levels[Self.alpha]?.sync.pending.entries[fixture.c.cid]?.evidence[fixture.b.cid], "its credit is still kept")
    }

    /// One peer fills the whole waiting pool: there is no per-peer cap. An
    /// honest header from another peer still gets in, evicting the oldest
    /// entry not held. Every proof is over the operator's size cap, so no
    /// entry has a check and each waits idle.
    func testOnePeerFillingTheWaitingPoolCannotKeepAnotherOut() async throws {
        let fixture = try await committedWorld()
        var config = ChainCoreConfig()
        config.proofs.maxAwaiting = fixture.d.count
        let size = try await ChildBlockProof.generate(
            rootHeader: BlockHeader(node: fixture.b.block), childDirectory: Self.alpha[1], fetcher: fixture.world.cas
        ).serialize().count
        config.proofs.maxProofBytes = size - 1
        var (host, proof) = try await provedHost(fixture, config: config)
        for block in fixture.d {
            await host.relay(block, at: Self.alpha, from: Self.alphaHost, proofs: [proof])
        }
        XCTAssertEqual(Set(try XCTUnwrap(host.core.levels[Self.alpha]?.sync.proofs.awaiting).keys), Set(fixture.d.map(\.cid)),
                       "one peer fills the pool")
        await host.relay(fixture.c, at: Self.alpha, from: Self.otherHost, proofs: [proof])
        let awaiting = try XCTUnwrap(host.core.levels[Self.alpha]?.sync.proofs.awaiting)
        XCTAssertNotNil(awaiting[fixture.c.cid], "the honest header gets in")
        XCTAssertNil(awaiting[fixture.d[0].cid], "the oldest idle entry goes")
        XCTAssertNotNil(awaiting[fixture.d[1].cid])
        XCTAssertTrue(host.disconnects.isEmpty)
    }

    /// One peer sends C with more proof bytes than the queue's budget: what
    /// fits is queued, the rest dropped without blame, and C is credited
    /// with the dropped grind when a peer sends it again. The evidence index
    /// holds only proofs this level credited, so it never names the dropped
    /// one.
    func testProofsPastTheQueueBudgetAreDroppedAndTakenWhenSentAgain() async throws {
        let fixture = try await committedWorld()
        var proofs: [ChildBlockProof] = []
        for carrier in [fixture.b, fixture.sibling] {
            proofs.append(try await ChildBlockProof.generate(
                rootHeader: BlockHeader(node: carrier.block), childDirectory: Self.alpha[1], fetcher: fixture.world.cas
            ))
        }
        var config = ChainCoreConfig()
        config.proofs.maxQueuedBytes = try proofs.map { try $0.serialize().count }.max()!
        var host = Host(fixture.world, config: config)
        for grind in fixture.setup { await host.step(.mined(grind)) }
        await host.meet(Self.miner)
        await host.meet(Self.alphaHost)
        host.deferChecks = true
        await host.relay(fixture.c, at: Self.alpha, from: Self.alphaHost, proofs: proofs)
        do {
            let proofs = try XCTUnwrap(host.core.levels[Self.alpha]).sync.proofs
            let held = proofs.verifying.values.reduce(0) { $0 + $1.bytes }
            XCTAssertGreaterThan(held, 0)
            XCTAssertLessThanOrEqual(held, config.proofs.maxQueuedBytes, "within the budget")
        }
        host.deferChecks = false
        let answers = host.deferred
        host.deferred = []
        for answer in answers { await host.step(answer) }
        await host.step(.tick)
        let taken = try XCTUnwrap(try host.digest(Self.alpha).blocks[fixture.c.cid]?.grinds)
        XCTAssertEqual(taken.count, 1, "the dropped grind is not taken until it is sent again")
        for proof in proofs { await host.relayProof(fixture.c, proof, at: Self.alpha, from: Self.alphaHost) }
        let grinds = try XCTUnwrap(try host.digest(Self.alpha).blocks[fixture.c.cid]?.grinds)
        XCTAssertEqual(Set(grinds.keys), [fixture.b.cid, fixture.sibling.cid], "both grinds credit")
        XCTAssertTrue(host.disconnects.isEmpty, "a budget, never blame")
    }

    /// A committed child genesis submitted as bytes (its spec a CID, as on
    /// the wire) with its spec beside it weighs, and its spec is stored.
    func testASubmittedCommittedGenesisWeighs() async throws {
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
        await host.step(.mined(n0.grind))
        var labels = GrindTraceFixture()
        labels.child(g.cid, "G")
        labels.rootCarrier(b.root.cid, "B", commits: "G")
        host.trace(testName, labels)
        await host.meet(Self.miner)
        XCTAssertNil(Block(data: try XCTUnwrap(g.block.toData()))?.spec.node, "the block as bytes carries its spec's CID")
        await host.relay(b.root, at: Self.nexus, from: Self.miner)
        let held = await host.submit(g, at: Self.alpha, spec: world.specs[Self.alpha])
        XCTAssertTrue(held)
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
        await host.step(.mined(n0.grind))
        var labels = GrindTraceFixture()
        labels.child(c.cid, "C")
        labels.rootCarrier(b.cid, "B", commits: "C", meets: false)
        host.trace(testName, labels)
        await host.meet(Self.miner)
        await host.relay(b, at: Self.nexus, from: Self.miner)
        await host.submit(c, at: Self.alpha)
        XCTAssertEqual(try host.digest(Self.nexus).canonicalTip, b.cid)
        XCTAssertEqual(host.derived.map(\.carrier), [b.cid], "C's arrival")
        XCTAssertTrue(try host.digest(Self.alpha).blocks.isEmpty, "a hash that misses C's target weighs nothing")
        XCTAssertTrue(host.store.proofs(Self.alpha, c.cid).isEmpty)
        XCTAssertNotNil(host.core.levels[Self.alpha]?.sync.proofs.awaiting[c.cid], "C waits, bounded as any header")
        XCTAssertTrue(host.disconnects.isEmpty, "no one is blamed")
    }

    /// A peer's proof whose claimed root misses C's target: the walk passes
    /// it with no work, which weighs nothing, and its sender is blamed. An
    /// honest node never sends one: it serves only proofs that credited work.
    func testAProofWhoseRootMissesTheTargetBlamesItsSender() async throws {
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
        let proof = try await ChildBlockProof.generate(
            rootHeader: BlockHeader(node: b.block), childDirectory: Self.alpha[1], fetcher: world.cas
        )
        guard case .success(let walked) = proof.verifySecuringWork(child: c.block, chainPath: Self.alpha) else {
            return XCTFail("the path walk passes the proof")
        }
        XCTAssertNil(walked.contribution, "with no work")

        var host = Host(world)
        await host.step(.mined(n0.grind))
        await host.meet(Self.alphaHost)
        // B not weighed: nothing derives its grind, so the peer's proof is checked.
        await host.relay(c, at: Self.alpha, from: Self.alphaHost, proofs: [proof], spec: world.specs[Self.alpha])
        XCTAssertTrue(try host.digest(Self.alpha).blocks.isEmpty, "nothing weighs")
        XCTAssertEqual(host.disconnects, [Self.alphaHost], "its sender is blamed")
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
        for grind in [n0.grind, n1.grind] { await host.step(.mined(grind)) }
        var labels = GrindTraceFixture()
        labels.child(c.cid, "C")
        labels.rootCarrier(b.root.cid, "B", commits: "C", meets: false)
        host.trace(testName, labels)
        await host.meet(Self.miner)
        await host.relay(b.root, at: Self.nexus, from: Self.miner)
        await host.submit(c, at: Self.alpha)
        XCTAssertNotNil(try host.digest(Self.nexus).blocks[b.root.cid])
        XCTAssertEqual(host.derived.map(\.carrier), [b.root.cid], "C's arrival")
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
        let hardLeaf: Bool
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
        return Deep(world: builder.world(), setup: [n0.grind, n1.grind, r1.grind], a: a, d: d, b: b, b2: b2.root, hardLeaf: hardLeaf)
    }

    /// Both levels traced: Alpha's carriers are root blocks, Beta's are
    /// Alpha blocks, whose grinds are the root blocks committing them.
    private func host(_ fixture: Deep) async -> Host {
        var host = Host(fixture.world)
        for grind in fixture.setup { await host.step(.mined(grind)) }
        var alpha = GrindTraceFixture()
        alpha.child(fixture.a.cid, "A")
        alpha.rootCarrier(fixture.b.cid, "B", commits: "A")
        host.trace("\(testName)-alpha", alpha)
        var beta = GrindTraceFixture()
        beta.child(fixture.d.cid, "D")
        beta.carrier(fixture.a.cid, "A", commits: "D")
        beta.grind(fixture.b.cid, "b", of: "A", meets: !fixture.hardLeaf)
        host.trace("\(testName)-beta", at: Self.beta, beta)
        await host.meet(Self.miner)
        return host
    }

    /// A carrier at depth 2 whose own credit is a derived proof: A, then D,
    /// submitted by their author, A weighs by B's derived grind, and D,
    /// which A commits a level down, by A's saved proof extended by A's hop
    /// (rooted at B). A's body is withheld: the header tree does not wait on
    /// it.
    func testADerivedCarrierCreditsTheBlockItCommitsByTheComposedPath() async throws {
        let fixture = try await deepWorld()
        var host = await host(fixture)
        host.withheldBodies = [fixture.a.cid]

        await host.relay(fixture.b, at: Self.nexus, from: Self.miner)
        await host.submit(fixture.a, at: Self.alpha)
        await host.submit(fixture.d, at: Self.beta, spec: fixture.world.specs[Self.beta])
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
        await host.submit(fixture.a, at: Self.alpha)
        await host.submit(fixture.d, at: Self.beta, spec: fixture.world.specs[Self.beta])
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
            var labels = GrindTraceFixture()
            labels.child(g.cid, "G")
            labels.child(c.cid, "C", parent: "G")
            labels.rootCarrier(n1.root.cid, "N1", commits: "G")
            labels.rootCarrier(n2.root.cid, "N2", commits: "C")
            host.trace("\(testName)-\(parentFirst ? "parentFirst" : "childFirst")", labels)
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

        /// G and C on it; N1 commits G (it carries it), each carrier C.
        var labels: GrindTraceFixture {
            var labels = GrindTraceFixture()
            labels.child(g.cid, "G")
            labels.child(c.cid, "C", parent: "G")
            labels.rootCarrier((try? BlockHeader(node: setup[1].root).rawCID) ?? "", "N1", commits: "G")
            for (index, carrier) in carriers.enumerated() {
                labels.rootCarrier((try? BlockHeader(node: carrier.root).rawCID) ?? "", "K\(index + 1)", commits: "C")
            }
            return labels
        }
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
        for grind in fixture.setup { await host.step(.mined(grind)) }
        host.trace(testName, fixture.labels)
        for grind in fixture.carriers + fixture.tail { await host.step(.mined(grind)) }
        await host.submit(fixture.c, at: Self.alpha)
        XCTAssertTrue(fixture.carrierCIDs.isSubset(of: try grinds(at: fixture.c.cid, host)))
        XCTAssertEqual(host.derived.filter { $0.cid == fixture.c.cid }.count, fixture.carriers.count, "each carrier once")
        XCTAssertTrue(host.disconnects.isEmpty)
    }

    /// A burst of derived proofs: a level hosted late takes C from a peer
    /// with one proof, and every other committer of C is derived at once;
    /// each credits.
    func testABurstOfDerivedProofsAllCredit() async throws {
        let fixture = try await carriersWorld(70)
        var host = Host(fixture.world, hosted: [])
        host.trace(testName, fixture.labels)
        for grind in fixture.mined { await host.step(.mined(grind)) }
        try await catchUp(&host, fixture)
        XCTAssertTrue(fixture.carrierCIDs.isSubset(of: try grinds(at: fixture.c.cid, host)))
        XCTAssertEqual(host.derived.filter { $0.cid == fixture.c.cid }.count, fixture.carriers.count,
                       "every committer, the peer's proof's included")
        XCTAssertTrue(host.disconnects.isEmpty)
    }

    /// Host Alpha now and hear its blocks from a peer that has them: G with
    /// N1's proof, C with its first carrier's.
    private func catchUp(_ host: inout Host, _ fixture: Carriers) async throws {
        await host.step(.host(Self.alpha, facts: .empty, specs: [], cursors: [:]))
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
    /// Alpha after every block weighed, and C's author, which submitted C,
    /// restarted from its stores after all but one derivation was lost, end
    /// with equal Alpha trees.
    func testOnlineLateAndRestartedHostsAgree() async throws {
        let fixture = try await carriersWorld(ChildProofConfig().maxPerHeader + 4, depth: 70)

        var online = Host(fixture.world)
        for grind in fixture.setup { await online.step(.mined(grind)) }
        online.trace("\(testName)-online", fixture.labels)
        for grind in fixture.carriers + fixture.tail { await online.step(.mined(grind)) }
        XCTAssertNil(try online.digest(Self.alpha).blocks[fixture.c.cid], "unpublished: not credited")
        await online.meet(Self.alphaHost)
        await online.relay(fixture.c, at: Self.alpha, from: Self.alphaHost)
        let reference = try online.digest(Self.alpha)
        XCTAssertTrue(fixture.carrierCIDs.isSubset(of: Set(try XCTUnwrap(reference.blocks[fixture.c.cid]).grinds.keys)))
        let deepest = try XCTUnwrap(try online.digest(Self.nexus).blocks[try BlockHeader(node: fixture.carriers[0].root).rawCID])
        XCTAssertGreaterThan(try online.digest(Self.nexus).blocks.values.map(\.height).max() ?? 0, deepest.height + 64,
                             "the carriers are past the body window")

        var late = Host(fixture.world, hosted: [])
        late.trace("\(testName)-late", fixture.labels)
        for grind in fixture.mined { await late.step(.mined(grind)) }
        try await catchUp(&late, fixture)
        XCTAssertEqual(try late.digest(Self.alpha).blocks, reference.blocks)

        var restarted = Host(fixture.world)
        restarted.lostDerivations = fixture.carrierCIDs.subtracting([try BlockHeader(node: fixture.carriers[0].root).rawCID])
        for grind in fixture.setup { await restarted.step(.mined(grind)) }
        restarted.trace("\(testName)-restarted", fixture.labels)
        for grind in fixture.carriers + fixture.tail { await restarted.step(.mined(grind)) }
        await restarted.submit(fixture.c, at: Self.alpha)
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
        for grind in [n0.grind, n1.grind] { await host.step(.mined(grind)) }
        var labels = GrindTraceFixture()
        labels.child(c.cid, "C")
        labels.rootCarrier(b.root.cid, "B", commits: "C")
        labels.rootCarrier(w.root.cid, "W", commits: "C", meets: false)
        host.trace(testName, labels)
        for grind in [b.grind, w.grind] { await host.step(.mined(grind)) }
        await host.submit(c, at: Self.alpha)
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

    // MARK: - Random interleavings

    /// C1 on Alpha's genesis G (N1 carries G) and C2 on C1; B2 on N1 commits
    /// C1, B3 on B2 commits C2, and W on N0 commits C1 on N0's post-state,
    /// which C1 does not anchor at, so W's grind never credits. Each child's
    /// real proof (its carrier's), W's proof of C1 (fails), and a bogus proof
    /// rooted at N1 (fails), as a peer may send them.
    private struct Interleaved {
        let world: LevelWorld
        let setup: [MinedGrind]
        let n1: SimBlock
        let c1: SimBlock
        let c2: SimBlock
        let w: SimBlock
        let b2: SimBlock
        let b3: SimBlock
        let real: [String: ChildBlockProof]
        let failing: [String: [ChildBlockProof]]

        var children: [(label: String, block: SimBlock)] { [("C1", c1), ("C2", c2)] }

        var labels: GrindTraceFixture {
            var labels = GrindTraceFixture()
            labels.child(c1.cid, "C1")
            labels.child(c2.cid, "C2", parent: "C1")
            labels.rootCarrier(w.cid, "W", commits: "C1", meets: false)
            labels.rootCarrier(b2.cid, "B2", commits: "C1")
            labels.rootCarrier(b3.cid, "B3", commits: "C2")
            return labels
        }
    }

    private func interleavedWorld() async throws -> Interleaved {
        var builder = try await LevelWorld.Builder(levels: 2)
        let n0 = try await builder.grind(on: try XCTUnwrap(builder.geneses[Self.nexus]), carrying: [], at: Self.t + Self.interval / 2, outcome: .block)
        let g = try await builder.childGenesis(Self.alpha, parentState: n0.root.block.postState.rawCID, at: Self.t + Self.interval)
        let n1 = try await builder.grind(on: n0.root, carrying: [(Self.alpha, g)], at: Self.t + Self.interval, outcome: .block)
        let entering = n1.root.block.postState.rawCID
        let c1 = try await builder.build(on: g, carrierPrevState: entering, timestamp: Self.t + 2 * Self.interval, nonce: 1)
        let b2 = try await builder.grind(
            on: n1.root, carrying: [],
            transactions: [try Self.commit(c1, parentState: entering, under: Self.alpha[1], on: Self.nexus, key: 0)],
            at: Self.t + 2 * Self.interval, outcome: .block
        )
        let next = b2.root.block.postState.rawCID
        let c2 = try await builder.build(on: c1, carrierPrevState: next, timestamp: Self.t + 3 * Self.interval, nonce: 2)
        let b3 = try await builder.grind(
            on: b2.root, carrying: [],
            transactions: [try Self.commit(
                c2, parentState: next, under: Self.alpha[1], on: Self.nexus, key: 1, replacing: (c1, entering)
            )],
            at: Self.t + 3 * Self.interval, outcome: .block
        )
        let stale = n0.root.block.postState.rawCID
        let w = try await builder.grind(
            on: n0.root, carrying: [],
            transactions: [try Self.commit(c1, parentState: stale, under: Self.alpha[1], on: Self.nexus, key: 2)],
            at: Self.t + 2 * Self.interval, outcome: .block
        )
        let world = builder.world()
        func proof(_ carrier: SimBlock) async throws -> ChildBlockProof {
            try await ChildBlockProof.generate(rootHeader: BlockHeader(node: carrier.block), childDirectory: Self.alpha[1], fetcher: world.cas)
        }
        let bogus = ChildBlockProof(rootCID: n1.root.cid, directoryPath: [Self.alpha[1]], entries: [])
        return Interleaved(
            world: world, setup: [n0.grind, n1.grind], n1: n1.root, c1: c1, c2: c2, w: w.root, b2: b2.root, b3: b3.root,
            real: [c1.cid: try await proof(b2.root), c2.cid: try await proof(b3.root)],
            failing: [c1.cid: [try await proof(w.root), bogus], c2.cid: [bogus]]
        )
    }

    /// One seeded run: a host driven by a random interleaving of what its
    /// environment does (carriers weighed, the author's submits, a peer's
    /// gossip with real, failing or no proofs, derivations and checks held
    /// and answered out of order, restarts, unhost and re-host, a peer
    /// gone), checking at every step that every credit is a meeting grind
    /// of a carrier committing the block and sits only on a pending or
    /// weighed block, and in the end, with nothing held and the author
    /// pushing each block until weighed, that every grind owed is credited.
    private struct Run {
        let fixture: Interleaved
        var host: Host
        var rng: SplitMix64
        var peers: [String: PeerID] = [:]
        var epoch: UInt64 = 0
        var positions: [PeerID: UInt64] = [:]
        var relayed: Set<String> = []
        var sentBad: Set<PeerID> = []

        init(_ fixture: Interleaved, seed: UInt64, config: ChainCoreConfig) {
            self.fixture = fixture
            host = Host(fixture.world, config: config)
            rng = SplitMix64(state: seed)
        }

        /// The connected peer named `role`, or a fresh one met now.
        mutating func peer(_ role: String) async -> PeerID {
            if let peer = peers[role], host.core.peers.contains(peer) { return peer }
            epoch += 1
            let peer = PeerID(key: "\(role)-\(epoch)", session: epoch)
            peers[role] = peer
            await host.meet(peer)
            return peer
        }

        /// `peer` logs `block` (or, with `logged`, an object of it) and
        /// serves it (with `proofs`) when asked.
        mutating func relay(
            _ block: SimBlock, at path: ChainPath, from role: String, proofs: [ChildBlockProof] = [], logged: LogEntry? = nil
        ) async {
            let peer = await peer(role)
            positions[peer, default: 0] += 1
            await host.step(.received(peer, path, .stream(StreamPage(
                requestID: 0, logID: "peer",
                entries: [StreamEntry(position: positions[peer]!, entry: logged ?? .header(block.cid))], hasMore: false
            ))))
            for (sentAt, message) in host.take() where sentAt == path {
                guard case .getData(let id, let cids) = message, cids.contains(block.cid) else { continue }
                await host.step(.received(peer, path, .headers(HeadersResponse(
                    requestID: id, entries: [HeaderEntry(block: block.block, children: block.children, proofs: proofs)],
                    hasMore: false
                ))))
            }
        }

        mutating func restart() async throws {
            try host.restart()
            await host.step(.tick)
        }

        mutating func rehost() async throws {
            let stored = try XCTUnwrap(host.store.levels[DerivedChildGrindTests.alpha])
            await host.step(.host(
                DerivedChildGrindTests.alpha, facts: StoredFacts(stored.facts), specs: stored.headers.values.compactMap(\.spec), cursors: [:]
            ))
        }

        func status(_ cid: String) -> String {
            guard let level = host.core.levels[DerivedChildGrindTests.alpha] else { return "unhosted" }
            if level.tree.contains(blockHash: cid) { return "tree" }
            if level.sync.pending.entries[cid] != nil { return "pending" }
            return level.sync.proofs.awaiting[cid] != nil ? "awaiting" : "unknown"
        }

        func credited(_ cid: String) -> Set<String> {
            guard let level = host.core.levels[DerivedChildGrindTests.alpha] else { return [] }
            if let meta = level.tree.getConsensusBlock(hash: cid) {
                return Set(meta.workContributions.keys).subtracting(meta.attributedRuns)
            }
            return Set(level.sync.pending.entries[cid]?.evidence.keys.map { $0 } ?? [])
        }

        /// Held work in an order that does not depend on CIDs (signatures
        /// make them differ between runs), so a seed replays the same run.
        mutating func sortHeld() {
            let names = [fixture.c1.cid: "C1", fixture.c2.cid: "C2", fixture.w.cid: "W", fixture.b2.cid: "B2", fixture.b3.cid: "B3"]
            func name(_ cid: String) -> String { names[cid] ?? cid }
            func rank(_ event: NodeEvent) -> String {
                guard case .level(_, .proofsVerified(let answers)) = event else { return "" }
                return answers.map { name($0.job.childCID) + name($0.job.proof.rootCID) }.joined()
            }
            host.heldDerivations = host.heldDerivations.sorted {
                name($0.job.childCID) + name($0.job.carrier) < name($1.job.childCID) + name($1.job.carrier)
            }
            host.deferred = host.deferred.sorted { rank($0) < rank($1) }
        }

        /// What may credit each block: its carrier's grind, which meets.
        var owed: [String: String] { [fixture.c1.cid: fixture.b2.cid, fixture.c2.cid: fixture.b3.cid] }

        func checkInvariants(_ context: String) {
            guard let level = host.core.levels[DerivedChildGrindTests.alpha] else { return }
            XCTAssertLessThanOrEqual(level.sync.proofs.awaiting.count, host.config.proofs.maxAwaiting, context)
            for (label, block) in fixture.children {
                let credits = credited(block.cid)
                XCTAssertTrue(credits.isSubset(of: [owed[block.cid]!]), "\(context): \(label) credited only by its carrier")
                XCTAssertEqual(!credits.isEmpty, ["pending", "tree"].contains(status(block.cid)), "\(context): \(label) credit held")
            }
            if status(fixture.c2.cid) == "tree" { XCTAssertEqual(status(fixture.c1.cid), "tree", "\(context): C2 above C1") }
            for peer in host.disconnects { XCTAssertTrue(sentBad.contains(peer), "\(context): \(peer) blamed for nothing") }
        }

        /// One random action; returns its name.
        mutating func act() async throws -> String {
            let alpha = DerivedChildGrindTests.alpha
            let hosted = host.core.levels[alpha] != nil
            let child = rng.next() % 2 == 0 ? fixture.c1 : fixture.c2
            switch rng.next() % 34 {
            case 0, 1:
                let ready = [fixture.w, fixture.b2] + (relayed.contains(fixture.b2.cid) ? [fixture.b3] : [])
                guard let carrier = ready.filter({ !relayed.contains($0.cid) }).randomElement(using: &rng) else { return "none" }
                relayed.insert(carrier.cid)
                await relay(carrier, at: DerivedChildGrindTests.nexus, from: "miner")
                return "weigh \(carrier.cid.suffix(6))"
            case 2...5:
                await host.submit(child, at: alpha)
                return "submit"
            case 6...11:
                guard hosted else { return "none" }
                var proofs: [ChildBlockProof] = []
                switch rng.next() % 4 {
                case 0: proofs = [fixture.real[child.cid]!]
                case 1: proofs = [fixture.failing[child.cid]!.randomElement(using: &rng)!]
                default: break
                }
                if let proof = proofs.first, proof.rootCID != owed[child.cid] { sentBad.insert(await peer("alpha")) }
                await relay(child, at: alpha, from: "alpha", proofs: proofs)
                return "gossip \(proofs.count)"
            case 31, 32:
                // A peer re-sends a header held here, with a proof.
                guard hosted, ["awaiting", "pending", "tree"].contains(status(child.cid)) else { return "none" }
                let proof = rng.next() % 2 == 0
                    ? fixture.real[child.cid]! : fixture.failing[child.cid]!.randomElement(using: &rng)!
                if proof.rootCID != owed[child.cid] { sentBad.insert(await peer("alpha")) }
                await relay(child, at: alpha, from: "alpha", proofs: [proof], logged: .proof(proof.rootCID, of: child.cid))
                return "regossip"
            case 12:
                host.holdDerivations.toggle()
                return "hold \(host.holdDerivations)"
            case 13...17, 27, 28:
                guard !host.heldDerivations.isEmpty else { return "none" }
                sortHeld()
                let index = Int(rng.next() % UInt64(host.heldDerivations.count))
                let (path, job) = host.heldDerivations.remove(at: index)
                await host.step(await host.derive(job, at: path))
                return "derive"
            case 18:
                host.deferChecks.toggle()
                return "defer \(host.deferChecks)"
            case 19...22, 29, 30:
                guard !host.deferred.isEmpty else { return "none" }
                sortHeld()
                let answer = host.deferred.remove(at: Int(rng.next() % UInt64(host.deferred.count)))
                await host.step(answer)
                return "check"
            case 23:
                try await restart()
                return "restart"
            case 24:
                if hosted { await host.step(.unhost(alpha)) } else { try await rehost() }
                return hosted ? "unhost" : "rehost"
            case 25:
                guard let peer = peers["alpha"], host.core.peers.contains(peer) else { return "none" }
                await host.step(.peerGone(peer))
                return "peer gone"
            default:
                await host.step(.tick)
                return "tick"
            }
        }

        /// Nothing held, the level hosted, and the author pushing each
        /// block until it is weighed.
        mutating func settle() async throws {
            host.holdDerivations = false
            host.deferChecks = false
            sortHeld()
            while !host.heldDerivations.isEmpty || !host.deferred.isEmpty {
                if !host.heldDerivations.isEmpty {
                    let (path, job) = host.heldDerivations.removeFirst()
                    await host.step(await host.derive(job, at: path))
                }
                if !host.deferred.isEmpty { await host.step(host.deferred.removeFirst()) }
            }
            if host.core.levels[DerivedChildGrindTests.alpha] == nil { try await rehost() }
            for _ in 0..<3 {
                for (_, block) in fixture.children where status(block.cid) != "tree" {
                    await host.submit(block, at: DerivedChildGrindTests.alpha)
                }
            }
        }
    }

    /// About fifty seeded interleavings, each traced: the trace validation's
    /// main source. Odd seeds await one header at a time; every third keeps
    /// room for one pending header only.
    func testRandomInterleavingsCreditEveryOwedGrind() async throws {
        let fixture = try await interleavedWorld()
        let sizes = fixture.children.map {
            ChainCore.size(of: HeaderEntry(block: $0.block.block, children: $0.block.children, proofs: [fixture.real[$0.block.cid]!]))
        }
        let count = ProcessInfo.processInfo.environment["DERIVED_TRACE_COUNT"].flatMap(UInt64.init) ?? 50
        var actions: [String: Int] = [:]
        for seed in 1...count {
            var config = ChainCoreConfig()
            if seed % 2 == 1 { config.proofs.maxAwaiting = 1 }
            if seed % 3 == 0 { config.pendingBudget = sizes.max()! + sizes.min()! / 2 }
            var run = Run(fixture, seed: seed, config: config)
            run.host.holdDerivations = seed % 3 != 1
            run.host.deferChecks = seed % 4 < 2
            for grind in fixture.setup { await run.host.step(.mined(grind)) }
            run.host.trace("random-\(seed)", fixture.labels)
            for step in 0..<60 {
                let action = try await run.act()
                actions[action.split(separator: " ").first.map(String.init) ?? action, default: 0] += 1
                run.checkInvariants("seed \(seed) step \(step) (\(action))")
            }
            try await run.settle()
            run.checkInvariants("seed \(seed) settled")
            for (label, block) in fixture.children {
                let carrier = run.owed[block.cid]!
                if run.relayed.contains(carrier) {
                    XCTAssertEqual(run.status(block.cid), "tree", "seed \(seed): \(label) weighed")
                    XCTAssertEqual(run.credited(block.cid), [carrier], "seed \(seed): \(label) holds its carrier's grind")
                }
            }
        }
        print("derived grind interleavings: \(actions.sorted { $0.key < $1.key })")
        for action in ["weigh", "submit", "gossip", "regossip", "derive", "check", "restart", "unhost", "rehost", "peer"] {
            XCTAssertGreaterThan(actions[action] ?? 0, 0, "no run did \(action)")
        }
    }

    // MARK: - Top-down weighing and page-batched checks

    /// N0 and N1 (carrying Alpha's genesis G); Alpha blocks C1...Cn on G,
    /// each anchored at N1's post-state and carried by a share on it (a
    /// grind that is no Nexus block), with that share's proof.
    private struct Shares {
        let world: LevelWorld
        let setup: [MinedGrind]
        let blocks: [(block: SimBlock, proofs: [ChildBlockProof])]
    }

    private func sharesWorld(_ count: Int) async throws -> Shares {
        var builder = try await LevelWorld.Builder(levels: 2)
        let n0 = try await builder.grind(on: try XCTUnwrap(builder.geneses[Self.nexus]), carrying: [], at: Self.t + Self.interval / 2, outcome: .block)
        let g = try await builder.childGenesis(Self.alpha, parentState: n0.root.block.postState.rawCID, at: Self.t + Self.interval)
        let n1 = try await builder.grind(on: n0.root, carrying: [(Self.alpha, g)], at: Self.t + Self.interval, outcome: .block)
        let carrier = n1.root
        var blocks: [(block: SimBlock, proofs: [ChildBlockProof])] = []
        var previous = g
        for index in 0..<count {
            let time = Self.t + Int64(3 + index) * Self.interval
            let block = try await builder.build(
                on: previous, carrierPrevState: carrier.block.postState.rawCID, timestamp: time, nonce: UInt64(index + 1)
            )
            let share = try await builder.grind(on: carrier, carrying: [(Self.alpha, block)], at: time, outcome: .share)
            blocks.append((block, [try XCTUnwrap(share.grind.carried.first).proof]))
            previous = block
        }
        return Shares(world: builder.world(), setup: [n0.grind, n1.grind], blocks: blocks)
    }

    /// N0, N1 (carrying Alpha's genesis G, with its proof) and N2 on N1;
    /// Alpha blocks C1...C4 on G, each anchored at N1's post-state but C4
    /// at N2's, and carried by a share on its anchor, with that share's
    /// proof.
    private struct Gate {
        let world: LevelWorld
        let nexus: [SimBlock]
        let n2: SimBlock
        let alpha: [HeaderEntry]
        let c4: (block: SimBlock, proofs: [ChildBlockProof])
    }

    private func gateWorld() async throws -> Gate {
        var builder = try await LevelWorld.Builder(levels: 2)
        let n0 = try await builder.grind(on: try XCTUnwrap(builder.geneses[Self.nexus]), carrying: [], at: Self.t + Self.interval / 2, outcome: .block)
        let g = try await builder.childGenesis(Self.alpha, parentState: n0.root.block.postState.rawCID, at: Self.t + Self.interval)
        let n1 = try await builder.grind(on: n0.root, carrying: [(Self.alpha, g)], at: Self.t + Self.interval, outcome: .block)
        let n2 = try await builder.grind(on: n1.root, carrying: [], at: Self.t + 2 * Self.interval, outcome: .block)
        var alpha = [HeaderEntry(
            block: g.block, children: g.children, proofs: [try XCTUnwrap(n1.grind.carried.first).proof], spec: builder.world().specs[Self.alpha]
        )]
        var previous = g
        var c4: (block: SimBlock, proofs: [ChildBlockProof])?
        for index in 0..<4 {
            let carrier = index < 3 ? n1.root : n2.root
            let time = Self.t + Int64(3 + index) * Self.interval
            let block = try await builder.build(
                on: previous, carrierPrevState: carrier.block.postState.rawCID, timestamp: time, nonce: UInt64(index + 1)
            )
            let share = try await builder.grind(on: carrier, carrying: [(Self.alpha, block)], at: time, outcome: .share)
            let proofs = [try XCTUnwrap(share.grind.carried.first).proof]
            if index < 3 {
                alpha.append(HeaderEntry(block: block.block, children: block.children, proofs: proofs))
            } else {
                c4 = (block, proofs)
            }
            previous = block
        }
        return Gate(world: builder.world(), nexus: [n0.root, n1.root], n2: n2.root, alpha: alpha, c4: try XCTUnwrap(c4))
    }

    /// A host that hears Alpha's peer before Nexus has caught up.
    private func gatedHost(_ fixture: Gate) async throws -> Host {
        var host = Host(fixture.world)
        for block in fixture.nexus + [fixture.n2] {
            host.serving[Self.nexus, default: [:]][Self.miner, default: [:]][block.cid] = HeaderEntry(block: block.block, children: block.children)
        }
        for entry in fixture.alpha {
            host.serving[Self.alpha, default: [:]][Self.alphaHost, default: [:]][try XCTUnwrap(entry.cid)] = entry
        }
        host.logs[Self.alpha] = [Self.alphaHost: try fixture.alpha.map { try XCTUnwrap($0.cid) }]
        // Alpha's peer, hosting Nexus too, never answers for Nexus.
        await host.step(.peerReady(Self.alphaHost))
        XCTAssertFalse(host.take().contains { $0.path == Self.alpha }, "gated: Alpha asks its peer for nothing")
        await host.step(.peerReady(Self.miner))
        return host
    }

    /// Whole-chain top-down: while Nexus catches up, Alpha asks its peer
    /// for nothing (no stream page, no header) and weighs nothing; its
    /// cursor stays where it was. Once Nexus latches `synced`, Alpha reads
    /// its peer's log and weighs every block in it.
    func testAChildLevelAsksItsPeersNothingWhileItsParentCatchesUpThenSyncsFully() async throws {
        let fixture = try await gateWorld()
        var host = try await gatedHost(fixture)
        func asks(_ sent: [(path: ChainPath, message: SyncMessage)], at path: ChainPath) -> [SyncMessage] {
            sent.filter { $0.path == path }.map(\.message).filter {
                switch $0 {
                case .getStream, .getData, .getAncestors: true
                default: false
                }
            }
        }
        var sent = host.take()
        let nexusStream = try XCTUnwrap(sent.compactMap { sent -> UInt64? in
            guard sent.path == Self.nexus, case .getStream(let id, _, 0, _) = sent.message else { return nil }
            return id
        }.first)
        XCTAssertTrue(asks(sent, at: Self.alpha).isEmpty, "gated: Alpha asks for no stream")

        // Nexus catches up page by page: N0, then N1.
        let n0 = fixture.nexus[0].cid, n1 = fixture.nexus[1].cid
        await host.step(.received(Self.miner, Self.nexus, .stream(StreamPage(
            requestID: nexusStream, logID: "peer", entries: [StreamEntry(position: 1, entry: .header(n0))], hasMore: true
        ))))
        XCTAssertNotNil(try host.digest(Self.nexus).blocks[n0])
        XCTAssertEqual(host.core.levels[Self.nexus]?.synced, false)
        sent = host.take()
        XCTAssertTrue(asks(sent, at: Self.alpha).isEmpty, "still gated while Nexus catches up")
        XCTAssertEqual(host.core.levels[Self.alpha]?.sync.peers[Self.alphaHost]?.holes.isEmpty, true)
        XCTAssertNil(host.core.levels[Self.alpha]?.sync.cursors[Self.alphaHost.key], "Alpha's cursor stays")
        XCTAssertEqual(try host.digest(Self.alpha).blocks.count, 0, "Alpha weighs nothing")
        let next = try XCTUnwrap(sent.compactMap { sent -> UInt64? in
            guard sent.path == Self.nexus, case .getStream(let id, _, 1, _) = sent.message else { return nil }
            return id
        }.first)
        await host.step(.received(Self.miner, Self.nexus, .stream(StreamPage(
            requestID: next, logID: "peer", entries: [StreamEntry(position: 2, entry: .header(n1))], hasMore: false
        ))))

        XCTAssertEqual(host.core.levels[Self.nexus]?.synced, true, "Nexus caught up")
        XCTAssertFalse(asks(host.take(), at: Self.alpha).isEmpty, "the gate opened: Alpha reads its peer")
        let alpha = try host.digest(Self.alpha)
        for entry in fixture.alpha { XCTAssertNotNil(alpha.blocks[try XCTUnwrap(entry.cid)], "every Alpha block weighs") }
        XCTAssertEqual(alpha.canonicalTip, fixture.alpha.last?.cid)
        XCTAssertTrue(host.disconnects.isEmpty)
    }

    /// The latch is one-way: once Nexus has caught up, a new Nexus block,
    /// not yet executed (its body withheld, so its best header tip is past
    /// its act-on tip), does not pause Alpha. An Alpha block anchored at
    /// that new block's state weighs as soon as Alpha's peer relays it.
    func testAfterTheLatchANewParentBlockDoesNotPauseTheChild() async throws {
        let fixture = try await gateWorld()
        var host = try await gatedHost(fixture)
        for (path, message) in host.take() where path == Self.nexus {
            guard case .getStream(let id, _, _, _) = message else { continue }
            let entries = fixture.nexus.enumerated().map { StreamEntry(position: UInt64($0.offset + 1), entry: .header($0.element.cid)) }
            await host.step(.received(Self.miner, Self.nexus, .stream(StreamPage(requestID: id, logID: "peer", entries: entries, hasMore: false))))
        }
        XCTAssertEqual(host.core.levels[Self.nexus]?.synced, true)
        XCTAssertEqual(try host.digest(Self.alpha).canonicalTip, fixture.alpha.last?.cid)

        host.withheldBodies.insert(fixture.n2.cid)
        host.position[Self.nexus] = [Self.miner: UInt64(fixture.nexus.count)]
        await host.relay(fixture.n2, at: Self.nexus, from: Self.miner)
        let nexus = try XCTUnwrap(host.core.levels[Self.nexus]?.snapshot)
        XCTAssertEqual(nexus.bestHeaderTip, fixture.n2.cid)
        XCTAssertNotEqual(nexus.actOnTip, fixture.n2.cid, "N2 is weighed, not executed")
        let c4 = fixture.c4.block.cid
        host.position[Self.alpha] = [Self.alphaHost: UInt64(fixture.alpha.count)]
        await host.relayPage([fixture.c4], at: Self.alpha, from: Self.alphaHost)
        XCTAssertNotNil(try host.digest(Self.alpha).blocks[c4], "Alpha follows live")
        XCTAssertEqual(try host.digest(Self.alpha).canonicalTip, c4)
        XCTAssertTrue(host.disconnects.isEmpty)
    }

    /// A peer that does not run Nexus answers with an empty log of no id:
    /// it says nothing about the chain, so Nexus does not latch on it and
    /// Alpha stays gated.
    func testAnUnhostedPeersEmptyLogDoesNotLatchTheParent() async throws {
        let fixture = try await gateWorld()
        var host = Host(fixture.world)
        await host.step(.peerReady(Self.alphaHost))
        let asked = try XCTUnwrap(host.take().compactMap { sent -> UInt64? in
            guard sent.path == Self.nexus, case .getStream(let id, _, _, _) = sent.message else { return nil }
            return id
        }.first)
        await host.step(.received(Self.alphaHost, Self.nexus, .stream(StreamPage(requestID: asked, logID: "", entries: [], hasMore: false))))
        XCTAssertEqual(host.core.levels[Self.nexus]?.synced, false, "no hosted log was read")
        XCTAssertFalse(host.take().contains { $0.path == Self.alpha }, "Alpha stays gated")
    }

    /// The gate opens on the parent's state, not on seeing it change: a
    /// parent that latched by any path (here set outside a step) opens its
    /// held-back child on the next step, and a page pushed while gated is
    /// not taken.
    func testAChildHeldBackOpensOnTheNextStepAfterItsParentLatched() async throws {
        let fixture = try await gateWorld()
        var host = try await gatedHost(fixture)
        _ = host.take()
        await host.relayPage([fixture.c4], at: Self.alpha, from: Self.alphaHost)
        XCTAssertNil(host.core.levels[Self.alpha]?.sync.cursors[Self.alphaHost.key], "a push while gated is not taken")
        XCTAssertEqual(host.core.levels[Self.alpha]?.heldBack, true)
        host.core.levels[Self.nexus]?.synced = true
        host.tamper("Nexus latched synced")
        await host.step(.tick)
        XCTAssertEqual(host.core.levels[Self.alpha]?.heldBack, false)
        let alpha = try host.digest(Self.alpha)
        for entry in fixture.alpha { XCTAssertNotNil(alpha.blocks[try XCTUnwrap(entry.cid)], "Alpha read its peer") }
    }

    /// A level restored with a cursor in its peer's log keeps it while
    /// gated (a push is not taken) and, once the parent latches, reads the
    /// log after it, not from the start.
    func testARestoredCursorIsKeptWhileGatedAndReadFromOnceOpen() async throws {
        let fixture = try await gateWorld()
        var host = Host(fixture.world, hosted: [])
        let restored = StreamCursor(logID: "peer", position: 2)
        await host.step(.host(Self.alpha, facts: .empty, specs: [], cursors: [Self.alphaHost.key: restored]))
        await host.step(.peerReady(Self.alphaHost))
        XCTAssertFalse(host.take().contains { $0.path == Self.alpha }, "gated: Alpha asks its peer for nothing")
        host.position[Self.alpha] = [Self.alphaHost: 2]
        await host.relayPage([fixture.c4], at: Self.alpha, from: Self.alphaHost)
        XCTAssertEqual(host.core.levels[Self.alpha]?.sync.cursors[Self.alphaHost.key], restored, "kept while gated")
        XCTAssertEqual(host.core.levels[Self.alpha]?.sync.peers[Self.alphaHost]?.taken, 2, "the push was not taken")

        for block in fixture.nexus {
            host.serving[Self.nexus, default: [:]][Self.miner, default: [:]][block.cid] = HeaderEntry(block: block.block, children: block.children)
        }
        host.logs[Self.nexus] = [Self.miner: fixture.nexus.map(\.cid)]
        await host.step(.peerReady(Self.miner))
        XCTAssertEqual(host.core.levels[Self.nexus]?.synced, true)
        let asked = host.take().compactMap { sent -> (String?, UInt64)? in
            guard sent.path == Self.alpha, case .getStream(_, let logID, let after, _) = sent.message else { return nil }
            return (logID, after)
        }
        // Its peer's log is asked after the restored cursor (the miner's,
        // never read, from its start).
        XCTAssertTrue(asked.contains { $0.0 == "peer" && $0.1 == 2 }, "read after the restored cursor: \(asked)")
        XCTAssertFalse(asked.contains { $0.0 == "peer" && $0.1 != 2 })
    }

    /// A host whose Nexus peer logs N0 and N1, Nexus's heaviest header,
    /// read to its end, with N1's body `unavailable` (no provider has it)
    /// or only `slow` (asked, not answered yet).
    private func withheldParentHost(_ fixture: Gate, unavailable: Bool) async throws -> Host {
        var host = try await gatedHost(fixture)
        if unavailable { host.unavailableBodies = [fixture.nexus[1].cid] } else { host.withheldBodies = [fixture.nexus[1].cid] }
        for (path, message) in host.take() where path == Self.nexus {
            guard case .getStream(let id, _, _, _) = message else { continue }
            let entries = fixture.nexus.enumerated().map { StreamEntry(position: UInt64($0.offset + 1), entry: .header($0.element.cid)) }
            await host.step(.received(Self.miner, Self.nexus, .stream(StreamPage(requestID: id, logID: "peer", entries: entries, hasMore: false))))
        }
        let nexus = try XCTUnwrap(host.core.levels[Self.nexus])
        XCTAssertEqual(nexus.snapshot.bestHeaderTip, fixture.nexus[1].cid)
        XCTAssertEqual(nexus.snapshot.actOnTip, fixture.nexus[0].cid, "N1 is weighed, not executed")
        return host
    }

    /// Nexus's heaviest header's body is withheld by every provider: once
    /// it is found unavailable, Nexus has caught up with what it can have
    /// and latches `synced` (Bitcoin's `IsInitialBlockDownload` reads the
    /// active chain, never the best header), so Alpha opens and syncs.
    func testAParentWhoseHeaviestBodyIsUnavailableLatchesAndOpensItsChild() async throws {
        let fixture = try await gateWorld()
        let host = try await withheldParentHost(fixture, unavailable: true)
        XCTAssertEqual(host.core.levels[Self.nexus]?.synced, true)
        let alpha = try host.digest(Self.alpha)
        for entry in fixture.alpha { XCTAssertNotNil(alpha.blocks[try XCTUnwrap(entry.cid)], "Alpha opened and weighed") }
        XCTAssertEqual(alpha.canonicalTip, fixture.alpha.last?.cid)
        XCTAssertTrue(host.disconnects.isEmpty)
    }

    /// Same: with the heaviest body unavailable, Nexus takes peers'
    /// transactions (it is no longer in initial download).
    func testAParentWhoseHeaviestBodyIsUnavailableAdmitsPeerTransactions() async throws {
        let fixture = try await gateWorld()
        var host = try await withheldParentHost(fixture, unavailable: true)
        let key = CryptoUtils.generateKeyPair()
        let tx = try signed(key, [AccountAction(owner: address(key), delta: -2)], nonce: 0)
        let effects = host.core.step(.level(Self.nexus, .mining(.transactionReceived(tx, origin: .peer(Self.miner)))), now: Self.now)
        XCTAssertTrue(effects.contains {
            if case .level(Self.nexus, .mining(.preflight)) = $0 { return true }
            return false
        }, "a peer's transaction is checked, not ignored: \(effects)")
    }

    /// A body merely slow (asked, no answer yet) is not unavailable: Nexus
    /// does not latch on it, and Alpha stays gated.
    func testASlowParentBodyDoesNotLatch() async throws {
        let fixture = try await gateWorld()
        var host = try await withheldParentHost(fixture, unavailable: false)
        XCTAssertEqual(host.core.levels[Self.nexus]?.synced, false)
        XCTAssertFalse(host.take().contains { $0.path == Self.alpha }, "Alpha stays gated")
        XCTAssertTrue(try host.digest(Self.alpha).blocks.isEmpty)
    }

    /// A grandchild whose carrier the parent level weighed is credited by
    /// derivation alone: a peer's proofs of A (committed by the weighed
    /// Nexus block B) and of D (committed by A) are never checked.
    func testAGrandchildCommittedByAWeighedCarrierIsCreditedByDerivationWithNoPeerCheck() async throws {
        let fixture = try await deepWorld()
        var author = Host(fixture.world)
        for grind in fixture.setup { await author.step(.mined(grind)) }
        await author.meet(Self.miner)
        await author.relay(fixture.b, at: Self.nexus, from: Self.miner)
        await author.submit(fixture.a, at: Self.alpha)
        await author.submit(fixture.d, at: Self.beta, spec: fixture.world.specs[Self.beta])
        let (aProofs, dProofs) = (author.store.proofs(Self.alpha, fixture.a.cid), author.store.proofs(Self.beta, fixture.d.cid))
        XCTAssertFalse(aProofs.isEmpty || dProofs.isEmpty, "the author serves both proofs")

        var host = await host(fixture)
        await host.relay(fixture.b, at: Self.nexus, from: Self.miner)
        await host.meet(Self.alphaHost)
        await host.relay(fixture.a, at: Self.alpha, from: Self.alphaHost, proofs: aProofs)
        await host.relay(fixture.d, at: Self.beta, from: Self.alphaHost, proofs: dProofs, spec: fixture.world.specs[Self.beta])
        XCTAssertNotNil(try host.digest(Self.alpha).blocks[fixture.a.cid]?.grinds[fixture.b.cid])
        XCTAssertNotNil(try host.digest(Self.beta).blocks[fixture.d.cid]?.grinds[fixture.b.cid], "D weighs by A's derived proof")
        XCTAssertEqual(host.peerChecks, 0, "no peer proof is checked")
        XCTAssertEqual(Set(host.derived.map(\.carrier)), [fixture.b.cid, fixture.a.cid])
        XCTAssertTrue(host.disconnects.isEmpty)
    }

    /// One rule at every level with a parent, whatever its depth: a block a
    /// weighed parent-level block commits is credited by derivation, with
    /// no peer proof checked; one no weighed parent block commits is
    /// credited by its peer proof. Run at depth one (Alpha, under Nexus)
    /// and depth two (Beta, under Alpha), each with every block committed
    /// and with none.
    func testDeriveOrCheckIsDecidedPerBlockByAWeighedCommitterAtEveryDepth() async throws {
        for path in [Self.alpha, Self.beta] {
            for committed in [true, false] {
                let name = "\(path.last!) \(committed ? "committed" : "uncommitted")"
                let (host, blocks) = try await perBlockScenario(at: path, committed: committed, count: 3)
                let level = try host.digest(path)
                for block in blocks { XCTAssertNotNil(level.blocks[block.cid], "\(name): every block weighs") }
                XCTAssertEqual(host.peerChecksAt[path] ?? 0, committed ? 0 : blocks.count,
                               "\(name): peer proofs checked only for blocks no weighed parent block commits")
                let derived = Set(host.derived.filter { $0.path == path }.map(\.cid))
                XCTAssertEqual(derived, committed ? Set(blocks.map(\.cid)) : [], "\(name): derived exactly the committed blocks")
                XCTAssertTrue(host.disconnects.isEmpty, name)
            }
        }
    }

    /// The setup of `deepWorld` (Nexus B commits Alpha block A, which
    /// commits Beta's genesis D), weighed by the host. Then `count` blocks
    /// at `path`, each carried by a grind on the Nexus tip and relayed by a
    /// peer with that grind's proof. When `committed`, the parent-level
    /// block carrying each one is weighed first (a Nexus block, or an Alpha
    /// block meeting its target, relayed with its proof); otherwise no
    /// parent-level block carrying it is weighed (a Nexus share, or an
    /// Alpha block missing its target).
    private func perBlockScenario(at path: ChainPath, committed: Bool, count: Int) async throws -> (Host, [SimBlock]) {
        var builder = try await LevelWorld.Builder(levels: 3)
        let n0 = try await builder.grind(on: try XCTUnwrap(builder.geneses[Self.nexus]), carrying: [], at: Self.t + Self.interval / 2, outcome: .block)
        let g = try await builder.childGenesis(Self.alpha, parentState: n0.root.block.postState.rawCID, at: Self.t + Self.interval)
        let n1 = try await builder.grind(on: n0.root, carrying: [(Self.alpha, g)], at: Self.t + Self.interval, outcome: .block)
        let a1 = try await builder.build(on: g, carrierPrevState: n1.root.block.postState.rawCID, timestamp: Self.t + 2 * Self.interval, nonce: 5)
        let r1 = try await builder.grind(on: n1.root, carrying: [(Self.alpha, a1)], at: Self.t + 2 * Self.interval, outcome: .block)
        let entering = r1.root.block.postState.rawCID
        let underA = a1.block.postState.rawCID
        let d = try await builder.childGenesis(Self.beta, parentState: underA, at: Self.t + 3 * Self.interval)
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
        let b = try await builder.store(
            builder.mine(unmined.block) { rootTarget >= $0 && aTarget >= $0 && dTarget >= $0 },
            releaseAt: Self.t + 3 * Self.interval, anchor: unmined.anchor
        )
        var (nexusTip, alphaTip, betaTip) = (b, a, d)
        // Per block: the parent-level block to relay first (if any), the
        // block and its proof.
        var steps: [(carrier: (path: ChainPath, block: SimBlock, proof: ChildBlockProof?)?, block: SimBlock, proof: ChildBlockProof)] = []
        for index in 0..<count {
            let time = Self.t + Int64(4 + index) * Self.interval
            if path == Self.alpha {
                let c = try await builder.build(on: alphaTip, carrierPrevState: nexusTip.block.postState.rawCID, timestamp: time, nonce: UInt64(10 + index))
                let r = try await builder.grind(on: nexusTip, carrying: [(Self.alpha, c)], at: time, outcome: committed ? .block : .share)
                steps.append((committed ? (Self.nexus, r.root, nil) : nil, c, try XCTUnwrap(r.grind.carried.first).proof))
                if committed { nexusTip = r.root }
                alphaTip = c
            } else {
                let d = try await builder.build(on: betaTip, carrierPrevState: alphaTip.block.postState.rawCID, timestamp: time, nonce: UInt64(10 + index))
                let a = try await builder.build(
                    on: alphaTip, carrierPrevState: nexusTip.block.postState.rawCID, children: [Self.beta[2]: d.block],
                    timestamp: time, nonce: UInt64(20 + index)
                )
                // A Nexus share (no Nexus block); A meets its target only when committed.
                let unmined = try await builder.build(
                    on: nexusTip, carrierPrevState: nil, children: [Self.alpha[1]: a.block], timestamp: time, nonce: 0
                )
                let (rootTarget, aTarget, dTarget) = (unmined.block.target, a.block.target, d.block.target)
                let root = builder.mine(unmined.block) { hash in
                    hash > rootTarget && dTarget >= hash && (committed ? aTarget >= hash : hash > aTarget)
                }
                let hop = try await ChildBlockProof.generate(rootHeader: BlockHeader(node: root), childDirectory: Self.alpha[1], fetcher: builder.cas)
                let down = try await ChildBlockProof.generate(rootHeader: BlockHeader(node: a.block), childDirectory: Self.beta[2], fetcher: builder.cas)
                steps.append((committed ? (Self.alpha, a, hop) : nil, d, hop.composing(hop: down)))
                if committed { alphaTip = a }
                betaTip = d
            }
        }
        let world = builder.world()
        var host = Host(world)
        for grind in [n0.grind, n1.grind, r1.grind] { await host.step(.mined(grind)) }
        await host.meet(Self.miner)
        await host.relay(b, at: Self.nexus, from: Self.miner)
        await host.submit(a, at: Self.alpha)
        await host.submit(d, at: Self.beta, spec: world.specs[Self.beta])
        XCTAssertNotNil(try host.digest(Self.beta).blocks[d.cid], "the setup weighs")
        host.derived = []
        await host.meet(Self.alphaHost)
        for step in steps {
            if let carrier = step.carrier {
                if let proof = carrier.proof {
                    await host.relay(carrier.block, at: carrier.path, from: Self.alphaHost, proofs: [proof])
                } else {
                    await host.relay(carrier.block, at: carrier.path, from: Self.miner)
                }
            }
            await host.relay(step.block, at: path, from: Self.alphaHost, proofs: [step.proof])
        }
        return (host, steps.map(\.block))
    }

    /// A page of n headers, each with a proof, is checked by one verify
    /// job, and its answers apply in one step with one persist.
    func testAPageOfProofsIsOneVerifyJobAndOneCommit() async throws {
        let count = 8
        let fixture = try await sharesWorld(count)
        var host = Host(fixture.world)
        for grind in fixture.setup { await host.step(.mined(grind)) }
        await host.meet(Self.alphaHost)
        await host.relayPage(fixture.blocks, at: Self.alpha, from: Self.alphaHost)
        let alpha = try host.digest(Self.alpha)
        for (block, _) in fixture.blocks { XCTAssertNotNil(alpha.blocks[block.cid], "every header weighs") }
        XCTAssertEqual(host.verifyJobs, [count], "one job checks the page")
        XCTAssertEqual(host.answerPersists, [1], "its answers apply in one step, one persist")
        XCTAssertTrue(host.disconnects.isEmpty)
    }

    /// A page whose last header carries a proof of another block: the page
    /// is still one job and one step; the sender is disconnected, and every
    /// proof that verifies is credited (the verdict is the proof's).
    func testABadProofInAPageDisconnectsItsSenderAndTheValidOnesCredit() async throws {
        let count = 6
        let fixture = try await sharesWorld(count)
        var blocks = fixture.blocks
        blocks[count - 1].proofs = blocks[0].proofs
        var host = Host(fixture.world)
        for grind in fixture.setup { await host.step(.mined(grind)) }
        await host.meet(Self.alphaHost)
        await host.relayPage(blocks, at: Self.alpha, from: Self.alphaHost)
        XCTAssertEqual(host.disconnects, [Self.alphaHost])
        let alpha = try host.digest(Self.alpha)
        for (block, _) in blocks.dropLast() { XCTAssertNotNil(alpha.blocks[block.cid], "a valid proof credits") }
        XCTAssertNil(alpha.blocks[blocks[count - 1].block.cid])
        XCTAssertEqual(host.verifyJobs, [count], "one job checks the page")
        XCTAssertEqual(host.answerPersists, [1])
    }
}
