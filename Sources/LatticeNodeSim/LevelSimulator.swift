import Lattice
import LatticeNodeCore
import UInt256

/// One multi-level simulation's shape.
public struct LevelSimConfig: Sendable {
    public var seed: UInt64
    public var levels = 3
    public var cores = 3
    public var grinds = 24
    public var forkProbability = 0.15
    public var shareProbability = 0.3
    public var doubleProbability = 0.25
    /// Adversaries: a proof withholder (never blamed), a peer showing a
    /// zero-work proof (never blamed), and one showing a child header off
    /// the timestamp schedule with a proof that weighs (blamed).
    public var withholder = true
    public var withholdDelay: Int64 = 8_000
    public var zeroWork = true
    public var scheduleLiar = true
    /// A peer relaying every child block with garbage proofs and forged
    /// twins of the honest ones.
    public var flooders = 0
    /// The child levels' proof bounds (scaled down, pages overrun them).
    public var proofs = ProofConfig()
    public var drop = 0.01
    public var duplicate = 0.05
    public var minDelay: Int64 = 5
    public var maxDelay: Int64 = 200
    public var pageSize = 8
    public var headersTimeout: Int64 = 3_000
    public var pendingBudget = 512 * 1_024
    public var reconnectDelay: Int64 = 3_000
    /// Each peer's repair catch-up: how a proof-less header dropped before
    /// the evidence index named it (the withholder's) comes back.
    public var catchUpInterval: Int64 = 10_000
    public var settle: Int64 = 60_000
    public var replayInterval = 48

    public init(seed: UInt64) {
        self.seed = seed
    }

    public static func random(seed: UInt64) -> LevelSimConfig {
        var rng = SplitMix64(state: seed ^ 0x1E7E_15)
        var config = LevelSimConfig(seed: seed)
        config.levels = rng.chance(0.75) ? 3 : 2
        config.cores = rng.draw(2...3)
        config.grinds = rng.draw(12...18)
        config.settle = 30_000
        config.forkProbability = 0.3 * rng.unit()
        config.shareProbability = 0.5 * rng.unit()
        config.doubleProbability = 0.4 * rng.unit()
        config.drop = 0.02 * rng.unit()
        config.duplicate = 0.1 * rng.unit()
        config.maxDelay = rng.draw(Int64(20)...300)
        config.pageSize = rng.draw(3...12)
        return config
    }
}

/// What a multi-level run observed.
public struct LevelSimReport: Sendable {
    public var steps = 0
    public var trace: UInt64 = 0xCBF2_9CE4_8422_2325
    public var disconnects: [(by: String, peer: String, reason: DisconnectReason)] = []
    /// Each core's final digest per level.
    public var digests: [String: [ChainPath: TreeDigest]] = [:]
    /// Per mined handoff: the persists its step emitted and the levels the
    /// one batch covered.
    public var minedBatches: [(persists: Int, levels: Int)] = []
    public var lookups = 0
    public var verifications = 0
    public var executions = 0
    public var bootstraps = 0
    /// The longest any core took to credit a public honest proof of a
    /// child block it holds, from the proof's release.
    public var creditLatency: Int64 = 0
}

/// A node's durable store across levels.
public struct HostStore: Sendable {
    public private(set) var levels: [ChainPath: SimStore] = [:]
    public private(set) var records: [ChainPath: LevelRecord] = [:]
    public private(set) var issued: [IssuedGenesisLink] = []
    /// The local evidence index: verified proofs per level, block and root.
    public private(set) var proofs: [ChainPath: [String: [String: ChildBlockProof]]] = [:]

    init(world: LevelWorld) {
        let genesis = world.geneses[LevelWorld.nexus]!
        records[LevelWorld.nexus] = LevelRecord(
            path: LevelWorld.nexus,
            spec: world.specs[LevelWorld.nexus]!,
            genesis: StoredHeader(blockCID: genesis.cid, block: genesis.block, children: genesis.children)
        )
        levels[LevelWorld.nexus] = SimStore(genesis: genesis, facts: world.rootBootstrap.facts)
    }

    mutating func append(_ batch: HostBatch) {
        for path in batch.removed {
            records[path] = nil
            levels[path] = nil
        }
        for record in batch.added {
            records[record.path] = record
            levels[record.path] = SimStore()
        }
        for (path, level) in batch.levels {
            levels[path, default: SimStore()].append(level)
        }
        issued += batch.issued
    }

    mutating func index(_ proof: ChildBlockProof, for cid: String, at path: ChainPath) {
        proofs[path, default: [:]][cid, default: [:]][proof.rootCID] = proof
    }

    func proofs(_ path: ChainPath, _ cid: String) -> [ChildBlockProof] {
        (proofs[path]?[cid] ?? [:]).sorted { $0.key < $1.key }.map(\.value)
    }
}

/// A deterministic network of host cores, each running every level it
/// hosts, beside scripted peers; an evidence index the cores and the
/// withholder publish to; and an executor standing in for body execution,
/// which runs `ChainTree.connect` on every weighed block whose parent is
/// executed. Every step runs `HostCore.step`, executes its effects, then
/// checks the invariants at every level.
public struct LevelSimulator {
    struct HostNode {
        var core: HostCore
        var store: HostStore
        var digests: [ChainPath: TreeDigest]
        var persists = 0
        var executing: Set<ExecKey> = []
        /// A block whose execution lacked a parent fact, with the parent's
        /// executed count then: it is tried again once that grows.
        var retry: [ExecKey: Int] = [:]
    }

    struct ExecKey: Hashable {
        let path: ChainPath
        let cid: String
    }

    enum Delivery {
        case host(HostEvent)
        case script(PeerID, ChainPath, SyncMessage)
        case scriptFetch(from: String, session: UInt64, path: ChainPath, cid: String)
        case scriptTick
        case connect(String, String)
        case linkDown(String, String, UInt64)
        case execute(ChainPath, String)
        case mine(Int)
        case publishProofs(Int)
    }

    struct Scheduled {
        let time: Int64
        let sequence: UInt64
        let node: String
        let delivery: Delivery
    }

    public let config: LevelSimConfig
    public private(set) var coreConfig: CoreConfig
    public let world: LevelWorld
    /// The generator right after the world was drawn: with the world, it
    /// replays the run.
    public let rngAfterWorld: SplitMix64
    var rng: SplitMix64
    public private(set) var now: Int64 = World.genesisTime
    var cores: [String: HostNode] = [:]
    var scripts: [String: any LevelScript] = [:]
    var sessions: [Simulator.Pair: UInt64] = [:]
    var nextSession: UInt64 = 1
    var queue = Heap()
    var sequence: UInt64 = 0
    var ticks: Set<Tick> = []

    struct Tick: Hashable {
        let node: String
        let time: Int64
    }
    /// The network's evidence index: what `lookupProofs` finds.
    var index: [ChainPath: [String: [String: ChildBlockProof]]] = [:]
    public private(set) var report = LevelSimReport()

    public static func make(_ config: LevelSimConfig) async throws -> LevelSimulator {
        var rng = SplitMix64(state: config.seed)
        let world = try await LevelWorld.generate(
            rng: &rng,
            levels: config.levels,
            grinds: config.grinds,
            forkProbability: config.forkProbability,
            shareProbability: config.shareProbability,
            doubleProbability: config.doubleProbability,
            withholdDelay: config.withholdDelay
        )
        return LevelSimulator(config: config, world: world, rng: rng)
    }

    public init(config: LevelSimConfig, world: LevelWorld, rng: SplitMix64) {
        self.config = config
        self.world = world
        self.rng = rng
        rngAfterWorld = rng
        coreConfig = CoreConfig(
            maxHeadersPerPage: config.pageSize,
            headersTimeout: config.headersTimeout,
            pendingBudget: config.pendingBudget,
            catchUpInterval: config.catchUpInterval
        )
        coreConfig.proofs = config.proofs
        for index in 0..<config.cores {
            let core = HostCore(root: world.rootBootstrap.tree, hosted: world.hosted, config: coreConfig)
            cores["core\(index)"] = HostNode(
                core: core,
                store: HostStore(world: world),
                digests: [LevelWorld.nexus: TreeDigest(world.rootBootstrap.tree)]
            )
        }
        scripts["source"] = LevelSource(name: "source", config: coreConfig)
        if config.withholder { scripts["withholder"] = ProofWithholder(name: "withholder", config: coreConfig) }
        if config.zeroWork { scripts["zerowork"] = LoneHeader(name: "zerowork", header: world.zeroWork, blamed: true) }
        for index in 0..<config.flooders {
            scripts["flooder\(index)"] = ProofFlooder(name: "flooder\(index)", config: coreConfig)
        }
        if config.scheduleLiar { scripts["liar"] = LoneHeader(name: "liar", header: world.offSchedule, blamed: true) }

        let names = cores.keys.sorted()
        for (position, name) in names.enumerated() {
            for other in names[(position + 1)...] { schedule(at: now, to: name, .connect(name, other)) }
            for script in scripts.keys.sorted() { schedule(at: now, to: name, .connect(name, script)) }
        }
        for script in scripts.keys.sorted() { schedule(at: now, to: script, .scriptTick) }
        for (position, grind) in world.grinds.enumerated() {
            if grind.withheld {
                schedule(at: grind.proofsAt, to: "index", .publishProofs(position))
            } else {
                schedule(at: grind.releaseAt, to: names[Int(self.rng.next() % UInt64(names.count))], .mine(position))
            }
        }
    }

    public var end: Int64 {
        let last = world.grinds.map { max($0.releaseAt, $0.proofsAt) }.max() ?? now
        return last + config.settle
    }

    /// Run to `end`, checking the invariants after every step and at the
    /// quiet point.
    public mutating func run() async throws -> LevelSimReport {
        while let next = pop(), next.time <= end {
            now = max(now, next.time)
            report.steps += 1
            report.trace = (report.trace ^ next.sequence ^ UInt64(bitPattern: next.time)) &* 0x100_0000_01B3
            try await deliver(next)
        }
        for (name, node) in cores.sorted(by: { $0.key < $1.key }) {
            try checkReplay(name, node)
            report.digests[name] = node.digests
        }
        try LevelInvariants.checkQuietPoint(
            cores.mapValues { ($0.core, $0.digests) }, world: world, now: now,
            withheldShown: config.withholder
        )
        return report
    }

    // MARK: - Queue

    mutating func schedule(at time: Int64, to node: String, _ delivery: Delivery) {
        sequence += 1
        let item = Scheduled(time: time, sequence: sequence, node: node, delivery: delivery)
        if item.isTick { ticks.insert(Tick(node: node, time: time)) }
        queue.push(item)
    }

    mutating func pop() -> Scheduled? {
        guard let item = queue.pop() else { return nil }
        if item.isTick { ticks.remove(Tick(node: item.node, time: item.time)) }
        return item
    }

    func session(_ a: String, _ b: String) -> UInt64? {
        sessions[Simulator.Pair(a, b)]
    }

    mutating func delay() -> Int64 {
        now + rng.draw(config.minDelay...config.maxDelay)
    }

    /// A message leg: delayed or duplicated by the seed, or lost with its link.
    mutating func send(_ delivery: Delivery, from: String, to: String) {
        if rng.chance(config.drop), let id = session(from, to) {
            schedule(at: now, to: from, .linkDown(from, to, id))
            return
        }
        for _ in 0..<(rng.chance(config.duplicate) ? 2 : 1) {
            schedule(at: delay(), to: to, delivery)
        }
    }

    // MARK: - Delivery

    mutating func deliver(_ scheduled: Scheduled) async throws {
        let node = scheduled.node
        switch scheduled.delivery {
        case .connect(let a, let b):
            guard session(a, b) == nil else { return }
            let id = nextSession
            nextSession += 1
            sessions[Simulator.Pair(a, b)] = id
            try await arrive(at: a, from: b, session: id)
            try await arrive(at: b, from: a, session: id)
        case .linkDown(let a, let b, let id):
            guard session(a, b) == id else { return }
            sessions[Simulator.Pair(a, b)] = nil
            for (end, other) in [(a, b), (b, a)] where cores[end] != nil {
                try await step(end, .peerGone(PeerID(key: other, session: id)))
            }
            schedule(at: now + config.reconnectDelay, to: a, .connect(a, b))
        case .host(let event):
            try await step(node, event)
        case .script(let peer, let path, let message):
            guard session(node, peer.key) == peer.session, var script = scripts[node] else { return }
            let actions = script.received(message, at: path, from: peer, now: now, world: world)
            scripts[node] = script
            perform(actions, by: node)
        case .scriptFetch(let from, let id, let path, let cid):
            guard session(node, from) == id, let script = scripts[node] else { return }
            let index = script.fetch(cid, at: path, now: now, world: world)
            send(.host(.level(path, .childIndexFetched(PeerID(key: node, session: id), cid: cid, index))), from: node, to: from)
        case .scriptTick:
            guard var script = scripts[node] else { return }
            let peers = sessions.compactMap { pair, id -> PeerID? in
                pair.low == node ? PeerID(key: pair.high, session: id)
                    : pair.high == node ? PeerID(key: pair.low, session: id) : nil
            }.sorted()
            let actions = script.tick(peers: peers, now: now, world: world)
            scripts[node] = script
            perform(actions, by: node)
        case .execute(let path, let cid):
            try await execute(cid, at: path, on: node)
        case .mine(let position):
            // The miner hands its grind to its node and publishes its proofs
            // to the evidence index, whatever levels that node runs yet.
            let grind = world.grinds[position]
            try await step(node, .mined(grind.mined))
            for carried in grind.mined.carried {
                publish(carried.proof, for: WorldCID.of(carried.evidence), at: carried.path)
            }
        case .publishProofs(let position):
            for carried in world.grinds[position].mined.carried {
                publish(carried.proof, for: WorldCID.of(carried.evidence), at: carried.path)
            }
        }
    }

    mutating func arrive(at node: String, from peer: String, session id: UInt64) async throws {
        let peerID = PeerID(key: peer, session: id)
        if cores[node] != nil {
            try await step(node, .peerReady(peerID))
        } else if var script = scripts[node] {
            let actions = script.connected(peerID, now: now, world: world)
            scripts[node] = script
            perform(actions, by: node)
        }
    }

    mutating func perform(_ actions: [LevelAction], by script: String) {
        for action in actions {
            switch action {
            case .send(let peer, let path, let message):
                guard session(script, peer.key) == peer.session else { continue }
                send(.host(.received(PeerID(key: script, session: peer.session), path, message)), from: script, to: peer.key)
            case .wakeAt(let time):
                schedule(at: max(time, now), to: script, .scriptTick)
            }
        }
    }

    mutating func route(_ message: SyncMessage, at path: ChainPath, from name: String, to peer: PeerID) {
        let from = PeerID(key: name, session: peer.session)
        if cores[peer.key] != nil {
            send(.host(.received(from, path, message)), from: name, to: peer.key)
        } else if session(name, peer.key) == peer.session {
            send(.script(from, path, message), from: name, to: peer.key)
        }
    }

    /// A proof enters the network's evidence index; if it is new there,
    /// every core hears the index changed.
    mutating func publish(_ proof: ChildBlockProof, for cid: String, at path: ChainPath) {
        guard index[path, default: [:]][cid, default: [:]].updateValue(proof, forKey: proof.rootCID) == nil else { return }
        for name in cores.keys.sorted() {
            schedule(at: delay(), to: name, .host(.level(path, .evidenceChanged(childCIDs: [cid]))))
        }
    }

    // MARK: - Execution (the stand-in for body execution)

    mutating func execute(_ cid: String, at path: ChainPath, on name: String) async throws {
        guard var node = cores[name] else { return }
        let key = ExecKey(path: path, cid: cid)
        guard let job = node.core.connectJob(for: cid, at: path) else {
            node.executing.remove(key)
            cores[name] = node
            return
        }
        cores[name] = node
        report.executions += 1
        let verdict = await ChainTree.connect(
            job,
            fetcher: world.cas,
            parentFacts: node.core.parentFacts(for: path),
            validationContext: ValidationContext(nowMilliseconds: now)
        )
        schedule(at: delay(), to: name, .host(.connected(path, verdict)))
    }

    /// Execute every weighed block whose parent is executed, once per
    /// attempt; a block that lacked a parent fact waits for its parent level
    /// to execute more.
    mutating func scheduleExecutions(_ name: String) {
        guard var node = cores[name] else { return }
        for path in node.core.ordered {
            guard let digest = node.digests[path] else { continue }
            let parentExecuted = path.count > 1 ? node.digests[Array(path.dropLast())]?.executed.count ?? 0 : 0
            for (hash, entry) in digest.blocks.sorted(by: { $0.key < $1.key }) {
                let key = ExecKey(path: path, cid: hash)
                guard !digest.executed.contains(hash), !digest.excluded.contains(hash),
                      let parent = entry.parent, digest.executed.contains(parent),
                      !node.executing.contains(key), node.retry[key] != parentExecuted else { continue }
                node.executing.insert(key)
                schedule(at: delay(), to: name, .execute(path, hash))
            }
        }
        cores[name] = node
    }

    // MARK: - Steps

    /// One `HostCore.step`, its effects in order, then the invariants.
    mutating func step(_ name: String, _ event: HostEvent) async throws {
        guard var node = cores[name] else { return }
        let effects = node.core.step(event, now: now)
        var persisted = false
        var persists = 0
        var minedLevels = 0
        for effect in effects {
            switch effect {
            case .persist(let batch):
                node.store.append(batch)
                persisted = true
                persists += 1
                minedLevels = batch.levels.count
            case .level(let path, let effect):
                try await perform(effect, at: path, by: name, &node)
            case .disconnect(let peer, let reason):
                report.disconnects.append((by: name, peer: peer.key, reason: reason))
                if cores[peer.key] != nil || scripts[peer.key]?.isHonest == true {
                    throw Invariants.fail(name, "disconnected honest peer \(peer) as \(reason)")
                }
                schedule(at: now, to: name, .linkDown(name, peer.key, peer.session))
            case .bootstrap(let path, let genesisCID, let facts):
                report.bootstraps += 1
                let result = await ChainTree.bootstrap(
                    genesis: BlockHeader(rawCID: genesisCID),
                    fetcher: world.cas,
                    context: try ChainRuntimeContext(path: path),
                    parentFacts: facts,
                    validationContext: ValidationContext(nowMilliseconds: now)
                ).map { bootstrap -> BootstrappedLevel in
                    let genesis = world.geneses[path]!
                    return BootstrappedLevel(
                        genesis: StoredHeader(blockCID: genesis.cid, block: genesis.block, children: genesis.children),
                        spec: world.specs[path]!,
                        bootstrap: bootstrap
                    )
                }
                schedule(at: delay(), to: name, .host(.bootstrapped(path, genesisCID: genesisCID, result)))
            case .wakeAt(let time):
                if time > now, !ticks.contains(Tick(node: name, time: time)) {
                    schedule(at: time, to: name, .host(.tick))
                }
            case .workSubmitted:
                // This simulator's grinds carry no reply.
                break
            }
        }
        if case .mined = event { report.minedBatches.append((persists, minedLevels)) }
        var digests: [ChainPath: TreeDigest] = [:]
        for (path, level) in node.core.levels {
            digests[path] = TreeDigest(level.tree)
        }
        if case .connected(let path, let verdict) = event, let digest = digests[path] {
            let key = ExecKey(path: path, cid: verdict.blockHash)
            node.executing.remove(key)
            if !digest.executed.contains(verdict.blockHash), !digest.excluded.contains(verdict.blockHash) {
                node.retry[key] = path.count > 1 ? digests[Array(path.dropLast())]?.executed.count ?? 0 : 0
            }
        }
        try LevelInvariants.check(
            node: name, host: node.core, digests: digests, previous: node.digests,
            store: node.store, world: world
        )
        for (path, digest) in digests where path.count > 1 {
            let before = node.digests[path]
            for (cid, entry) in digest.blocks {
                for root in entry.grinds.keys where before?.blocks[cid]?.grinds[root] == nil {
                    if let truth = world.proofs[path]?[cid]?[root] {
                        report.creditLatency = max(report.creditLatency, now - truth.releaseAt)
                    }
                }
            }
        }
        node.digests = digests
        if persisted {
            node.persists += 1
            if node.persists % config.replayInterval == 0 { try checkReplay(name, node) }
        }
        cores[name] = node
        scheduleExecutions(name)
    }

    mutating func perform(_ effect: Effect, at path: ChainPath, by name: String, _ node: inout HostNode) async throws {
        switch effect {
        case .send(let peer, let message):
            if case .headers(let relayed) = message {
                for entry in relayed.entries {
                    let cid = (try? BlockHeader(node: entry.block).rawCID) ?? ""
                    guard node.store.levels[path]?.headers[cid] != nil else {
                        throw Invariants.fail(name, "relayed \(cid) at \(path) before it was durable")
                    }
                    for proof in entry.proofs where node.store.proofs[path]?[cid]?[proof.rootCID] == nil {
                        throw Invariants.fail(name, "relayed a proof of \(cid) before indexing it")
                    }
                }
            }
            route(message, at: path, from: name, to: peer)
        case .serveHeaders(let peer, let token, let requestID, let blockCIDs, let hasMore):
            var entries: [HeaderEntry] = []
            for cid in blockCIDs {
                guard let stored = node.store.levels[path]?.headers[cid] else {
                    throw Invariants.fail(name, "served \(cid) at \(path) before it was durable")
                }
                entries.append(coreConfig.entry(stored.block, children: stored.children, proofs: node.store.proofs(path, cid)))
            }
            let page = coreConfig.page(entries, hasMore: hasMore)
            route(.headers(HeadersResponse(requestID: requestID, entries: page.entries, hasMore: page.hasMore)), at: path, from: name, to: peer)
            schedule(at: now, to: name, .host(.level(path, .headersServed(peer, token: token))))
        case .fetchByCID(let peer, let cid):
            guard session(name, peer.key) == peer.session else { return }
            if let other = cores[peer.key] {
                let index = other.store.levels[path]?.childIndexes[cid]
                send(.host(.level(path, .childIndexFetched(peer, cid: cid, index))), from: peer.key, to: name)
            } else {
                send(.scriptFetch(from: name, session: peer.session, path: path, cid: cid), from: name, to: peer.key)
            }
        case .publish(let snapshot):
            for tip in [snapshot.bestHeaderTip, snapshot.actOnTip]
            where node.store.levels[path]?.blockFacts.contains(tip) != true {
                throw Invariants.fail(name, "published tip \(tip) at \(path) is not durable")
            }
        case .lookupProofs(let cids):
            report.lookups += 1
            for cid in cids {
                let found = (index[path]?[cid] ?? [:]).sorted { $0.key < $1.key }.map(\.value)
                if !found.isEmpty {
                    schedule(at: delay(), to: name, .host(.level(path, .proofsFound(childCID: cid, found))))
                }
            }
        case .verifyProof(let job):
            report.verifications += 1
            guard let block = job.block ?? node.store.levels[path]?.headers[job.childCID]?.block else {
                throw Invariants.fail(name, "asked to verify a proof of \(job.childCID), which it does not hold")
            }
            let result = await job.run(block)
            schedule(at: delay(), to: name, .host(.level(path, .proofVerified(job, result))))
        case .indexProof(let cid, let proof):
            node.store.index(proof, for: cid, at: path)
            publish(proof, for: cid, at: path)
        case .mining:
            // The transaction workload drives `Mining` on its own
            // (`TxWorkload`); the level simulator submits no transactions.
            break
        case .fetchBody, .cancelBody, .connect:
            // N2's body window: this simulator executes every weighed block
            // itself (`HostEvent.connected`, parent side branches included),
            // so the window's requests go unanswered here.
            break
        case .persist, .disconnect, .wakeAt:
            throw Invariants.fail(name, "a level effect escaped the host")
        }
    }

    /// DST 7 across levels: the store alone rebuilds equal trees and facts.
    func checkReplay(_ name: String, _ node: HostNode) throws {
        let restored = try HostCore.restore(
            records: Array(node.store.records.values),
            facts: node.store.levels.mapValues(\.facts),
            issued: node.store.issued,
            hosted: world.hosted,
            config: coreConfig
        )
        guard Set(restored.levels.keys) == Set(node.core.levels.keys) else {
            throw Invariants.fail(name, "replay restores levels \(restored.levels.keys.sorted { $0.count < $1.count })")
        }
        for (path, level) in restored.levels where TreeDigest(level.tree) != node.digests[path] {
            throw Invariants.fail(name, "replaying the store gives a different tree at \(path)")
        }
        guard restored.issuers == node.core.issuers else {
            throw Invariants.fail(name, "replaying the store gives different genesis links")
        }
        var resumed = restored
        for case .bootstrap(let path, _, _) in resumed.pendingBootstraps(now: now) where node.core.levels[path] != nil {
            throw Invariants.fail(name, "a restored host bootstraps \(path) again, though it pinned its genesis")
        }
    }
}

extension LevelSimulator.Scheduled {
    var isTick: Bool {
        if case .host(.tick) = delivery { return true }
        return false
    }
}

/// A binary min-heap on (time, sequence): equal times run in schedule order.
struct Heap {
    private var items: [LevelSimulator.Scheduled] = []

    mutating func push(_ item: LevelSimulator.Scheduled) {
        items.append(item)
        var child = items.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard precedes(items[child], items[parent]) else { break }
            items.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> LevelSimulator.Scheduled? {
        guard !items.isEmpty else { return nil }
        items.swapAt(0, items.count - 1)
        let top = items.removeLast()
        var parent = 0
        while true {
            let left = 2 * parent + 1
            var first = parent
            if left < items.count, precedes(items[left], items[first]) { first = left }
            if left + 1 < items.count, precedes(items[left + 1], items[first]) { first = left + 1 }
            guard first != parent else { break }
            items.swapAt(parent, first)
            parent = first
        }
        return top
    }

    private func precedes(_ a: LevelSimulator.Scheduled, _ b: LevelSimulator.Scheduled) -> Bool {
        a.time != b.time ? a.time < b.time : a.sequence < b.sequence
    }
}
