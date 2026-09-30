import Lattice
import LatticeNodeCore

/// One simulation's shape. `random(seed:)` draws a seed's own shape.
public struct SimConfig: Sendable {
    public var seed: UInt64
    public var cores = 4
    public var honestSources = 2
    public var spammer = true
    public var liar = true
    public var honestBlocks = 40
    public var forkProbability = 0.2
    public var spamBlocks = 4
    public var drop = 0.1
    public var duplicate = 0.05
    /// Probability that a served page omits a child index (over budget).
    public var omitChildren = 0.1
    public var minDelay: Int64 = 5
    public var maxDelay: Int64 = 250
    public var pageSize = 8
    public var headersTimeout: Int64 = 2_000
    public var reannounceInterval: Int64 = 5_000
    public var reconnectDelay: Int64 = 3_000
    /// Simulated time after the last release before the run stops.
    public var settle: Int64 = 60_000
    /// Replay the store and compare trees every this many persists per node.
    public var replayInterval = 32

    public init(seed: UInt64) {
        self.seed = seed
    }

    public static func random(seed: UInt64) -> SimConfig {
        var rng = SplitMix64(state: seed ^ 0xC0FF_EE00)
        var config = SimConfig(seed: seed)
        config.cores = Int.random(in: 2...5, using: &rng)
        config.honestSources = Int.random(in: 1...2, using: &rng)
        config.spammer = Bool.random(using: &rng)
        config.liar = Bool.random(using: &rng)
        config.honestBlocks = Int.random(in: 20...50, using: &rng)
        config.forkProbability = Double.random(in: 0...0.3, using: &rng)
        config.spamBlocks = Int.random(in: 1...5, using: &rng)
        config.drop = Double.random(in: 0...0.2, using: &rng)
        config.duplicate = Double.random(in: 0...0.1, using: &rng)
        config.maxDelay = Int64.random(in: 20...500, using: &rng)
        config.pageSize = Int.random(in: 3...16, using: &rng)
        return config
    }
}

/// What a run observed.
public struct SimReport: Sendable {
    public var steps = 0
    public var coreTips: [String: String] = [:]
    /// Every block on each honest source's final best chain.
    public var sourceChains: [String: [String]] = [:]
    public var coreHeld: [String: Set<String>] = [:]
    /// (by, peer name, reason) for every disconnect an honest node issued.
    public var disconnects: [(by: String, peer: String, reason: DisconnectReason)] = []
    /// A fingerprint of the run's event order: equal seeds, equal traces.
    public var trace: UInt64 = 0xCBF2_9CE4_8422_2325
}

/// A deterministic network of honest cores and scripted peers in one thread.
/// Every step runs `Core.step`, executes its effects, then checks the
/// invariants.
public struct Simulator {
    struct CoreNode {
        var core: Core
        var store: SimStore
        var digest: TreeDigest
        var persists = 0
    }

    /// DST 7: the store alone rebuilds an equal tree.
    func checkReplay(_ name: String, _ node: CoreNode, _ digest: TreeDigest) throws {
        let restored = try Core.restore(
            replaying: node.store.facts,
            context: world.context,
            spec: world.spec,
            config: node.core.config
        )
        guard TreeDigest(restored.tree) == digest else {
            throw Invariants.fail(name, "replaying the store gives a different tree")
        }
    }

    enum Delivery {
        case core(Event)
        case scriptMessage(PeerID, SyncMessage)
        case scriptFetch(from: String, session: UInt64, cid: String)
        case scriptTick
        case connect(String, String)
    }

    struct Scheduled {
        let time: Int64
        let sequence: UInt64
        let node: String
        let delivery: Delivery
    }

    public let config: SimConfig
    public let world: World
    var rng: SplitMix64
    public private(set) var now: Int64 = World.genesisTime
    var cores: [String: CoreNode] = [:]
    var scripts: [String: any SimScript] = [:]
    var sessions: [Pair: UInt64] = [:]
    var nextSession: UInt64 = 1
    var queue = EventQueue()
    public private(set) var report = SimReport()

    struct Pair: Hashable {
        let low: String
        let high: String
        init(_ a: String, _ b: String) {
            (low, high) = a < b ? (a, b) : (b, a)
        }
    }

    public static func make(_ config: SimConfig) async throws -> Simulator {
        var rng = SplitMix64(state: config.seed)
        let world = try await World.generate(
            rng: &rng,
            honestBlocks: config.honestBlocks,
            forkProbability: config.forkProbability,
            spamBlocks: config.spamBlocks
        )
        return Simulator(config: config, world: world, rng: rng)
    }

    init(config: SimConfig, world: World, rng: SplitMix64) {
        self.config = config
        self.world = world
        self.rng = rng
        let coreConfig = CoreConfig(
            maxHeadersPerPage: config.pageSize,
            headersTimeout: config.headersTimeout
        )
        for index in 0..<config.cores {
            let core = Core(tree: world.bootstrap.tree, spec: world.spec, config: coreConfig)
            cores["core\(index)"] = CoreNode(
                core: core,
                store: SimStore(genesis: world.genesis, facts: world.bootstrap.facts),
                digest: TreeDigest(core.tree)
            )
        }
        for index in 0..<config.honestSources {
            let source = HonestSource(
                name: "source\(index)",
                pageSize: config.pageSize,
                reannounceInterval: config.reannounceInterval,
                world: world
            )
            scripts[source.name] = source
        }
        if config.spammer { scripts["spammer"] = HeaderSpammer(name: "spammer") }
        if config.liar { scripts["liar"] = Liar(name: "liar", pageSize: config.pageSize) }

        let coreNames = cores.keys.sorted()
        for (position, name) in coreNames.enumerated() {
            for other in coreNames[(position + 1)...] {
                schedule(at: now, to: name, .connect(name, other))
            }
            for script in scripts.keys.sorted() {
                schedule(at: now, to: name, .connect(name, script))
            }
        }
        for script in scripts.keys.sorted() {
            schedule(at: now, to: script, .scriptTick)
        }
    }

    public var end: Int64 {
        (world.honest.compactMap { world.blocks[$0]?.releaseAt }.max() ?? now) + config.settle
    }

    /// Run to `end`, checking invariants after every step.
    public mutating func run() throws -> SimReport {
        while let next = queue.pop(), next.time <= end {
            now = max(now, next.time)
            report.steps += 1
            report.trace = (report.trace ^ next.sequence ^ UInt64(bitPattern: next.time)) &* 0x100_0000_01B3
            try deliver(next)
        }
        for (name, node) in cores.sorted(by: { $0.key < $1.key }) {
            try checkReplay(name, node, node.digest)
            report.coreTips[name] = node.core.tree.canonicalTip
            report.coreHeld[name] = Set(node.digest.blocks.keys)
        }
        for (name, script) in scripts where script.isHonest {
            report.sourceChains[name] = bestChain(
                of: world.released(world.honest, at: now), genesis: world.genesis
            ).map(\.cid)
        }
        return report
    }

    // MARK: - Delivery

    mutating func schedule(at time: Int64, to node: String, _ delivery: Delivery) {
        queue.push(Scheduled(time: time, sequence: queue.nextSequence, node: node, delivery: delivery))
    }

    func session(_ a: String, _ b: String) -> UInt64? {
        sessions[Pair(a, b)]
    }

    mutating func deliver(_ scheduled: Scheduled) throws {
        let node = scheduled.node
        switch scheduled.delivery {
        case .connect(let a, let b):
            guard session(a, b) == nil else { return }
            let id = nextSession
            nextSession += 1
            sessions[Pair(a, b)] = id
            try arrive(at: a, from: b, session: id)
            try arrive(at: b, from: a, session: id)
        case .core(let event):
            try step(node, event)
        case .scriptMessage(let peer, let message):
            guard session(node, peer.key) == peer.session, var script = scripts[node] else { return }
            let actions = script.received(message, from: peer, now: now, world: world, rng: &rng)
            scripts[node] = script
            perform(actions, by: node)
        case .scriptFetch(let from, let sessionID, let cid):
            guard session(node, from) == sessionID, let script = scripts[node] else { return }
            let index = script.fetch(cid, now: now, world: world)
            send(.core(.childIndexFetched(PeerID(key: node, session: sessionID), cid: cid, index)),
                 from: node, to: from)
        case .scriptTick:
            guard var script = scripts[node] else { return }
            let peers = sessions.compactMap { pair, id -> PeerID? in
                pair.low == node ? PeerID(key: pair.high, session: id)
                    : pair.high == node ? PeerID(key: pair.low, session: id) : nil
            }.sorted()
            let actions = script.tick(peers: peers, now: now, world: world)
            scripts[node] = script
            perform(actions, by: node)
        }
    }

    /// `node` learns of a new session with `peer`.
    mutating func arrive(at node: String, from peer: String, session id: UInt64) throws {
        let peerID = PeerID(key: peer, session: id)
        if cores[node] != nil {
            try step(node, .peerReady(peerID))
        } else if var script = scripts[node] {
            let actions = script.connected(peerID, now: now, world: world)
            scripts[node] = script
            perform(actions, by: node)
        }
    }

    /// A message leg: dropped, delayed or duplicated by the seed.
    mutating func send(_ delivery: Delivery, from: String, to: String) {
        guard Double.random(in: 0..<1, using: &rng) >= config.drop else { return }
        let copies = Double.random(in: 0..<1, using: &rng) < config.duplicate ? 2 : 1
        for _ in 0..<copies {
            schedule(at: now + Int64.random(in: config.minDelay...config.maxDelay, using: &rng), to: to, delivery)
        }
    }

    mutating func perform(_ actions: [ScriptAction], by script: String) {
        for action in actions {
            switch action {
            case .send(let peer, let message):
                guard session(script, peer.key) == peer.session else { continue }
                let from = PeerID(key: script, session: peer.session)
                send(.core(.received(from, message)), from: script, to: peer.key)
            case .wakeAt(let time):
                schedule(at: max(time, now), to: script, .scriptTick)
            }
        }
    }

    /// One `Core.step`, its effects in order, then the invariants.
    mutating func step(_ name: String, _ event: Event) throws {
        guard var node = cores[name] else { return }
        let revision = node.core.tree.currentRevision()
        let effects = node.core.step(event, now: now)
        var persisted = false
        for effect in effects {
            switch effect {
            case .persist(let batch):
                node.store.append(batch)
                persisted = true
            case .publish(let snapshot):
                // DST 3: durability precedes visibility.
                for tip in [snapshot.bestHeaderTip, snapshot.actOnTip]
                where !node.store.blockFacts.contains(tip) {
                    throw Invariants.fail(name, "published tip \(tip) is not durable")
                }
            case .send(let peer, let message):
                if case .announce(let cid, _) = message, cid != node.core.snapshot.actOnTip
                    || !node.store.blockFacts.contains(cid) {
                    throw Invariants.fail(name, "announced \(cid), not its durable act-on tip")
                }
                try route(message, from: name, to: peer)
            case .serveHeaders(let peer, let requestID, let blockCIDs, let hasMore):
                var entries: [HeaderEntry] = []
                for cid in blockCIDs {
                    guard let stored = node.store.headers[cid] else {
                        throw Invariants.fail(name, "served \(cid) before it was durable")
                    }
                    let omit = Double.random(in: 0..<1, using: &rng) < config.omitChildren
                    entries.append(HeaderEntry(block: stored.block, children: omit ? nil : stored.children))
                }
                try route(.headers(HeadersResponse(
                    requestID: requestID, entries: entries, hasMore: hasMore
                )), from: name, to: peer)
            case .fetchByCID(let peer, let cid):
                guard session(name, peer.key) == peer.session else { continue }
                if let other = cores[peer.key] {
                    let index = other.store.childIndexes[cid]
                    send(.core(.childIndexFetched(PeerID(key: peer.key, session: peer.session), cid: cid, index)),
                         from: peer.key, to: name)
                } else {
                    send(.scriptFetch(from: name, session: peer.session, cid: cid), from: name, to: peer.key)
                }
            case .disconnect(let peer, let reason):
                report.disconnects.append((by: name, peer: peer.key, reason: reason))
                if cores[peer.key] != nil || scripts[peer.key]?.isHonest == true {
                    throw Invariants.fail(name, "disconnected honest peer \(peer) as \(reason)")
                }
                guard session(name, peer.key) == peer.session else { continue }
                sessions[Pair(name, peer.key)] = nil
                schedule(at: now + config.reconnectDelay, to: name, .connect(name, peer.key))
            case .wakeAt(let time):
                if time > now, !queue.hasTick(for: name, at: time) {
                    schedule(at: time, to: name, .core(.tick))
                }
            }
        }
        // Every consensus mutation advances the revision: an unchanged one is
        // an unchanged tree, whose tree invariants already hold.
        let treeChanged = node.core.tree.currentRevision() != revision
        let digest = treeChanged ? TreeDigest(node.core.tree) : node.digest
        try Invariants.check(
            node: name,
            core: node.core,
            digest: digest,
            previous: treeChanged ? node.digest : nil,
            store: node.store,
            treeChanged: treeChanged || persisted
        )
        if persisted {
            node.persists += 1
            // Replay costs the whole log, so it runs every `replayInterval`
            // persists and once more at the end of the run.
            if node.persists % config.replayInterval == 0 {
                try checkReplay(name, node, digest)
            }
        }
        node.digest = digest
        cores[name] = node
    }

    mutating func route(_ message: SyncMessage, from name: String, to peer: PeerID) throws {
        let from = PeerID(key: name, session: peer.session)
        if cores[peer.key] != nil {
            send(.core(.received(from, message)), from: name, to: peer.key)
        } else if session(name, peer.key) == peer.session {
            send(.scriptMessage(from, message), from: name, to: peer.key)
        }
    }
}

/// A binary min-heap on (time, sequence): equal times run in schedule order.
struct EventQueue {
    private var heap: [Simulator.Scheduled] = []
    private var ticks: Set<TickKey> = []
    private(set) var nextSequence: UInt64 = 0

    struct TickKey: Hashable {
        let node: String
        let time: Int64
    }

    func hasTick(for node: String, at time: Int64) -> Bool {
        ticks.contains(TickKey(node: node, time: time))
    }

    mutating func push(_ item: Simulator.Scheduled) {
        nextSequence += 1
        if case .core(.tick) = item.delivery {
            ticks.insert(TickKey(node: item.node, time: item.time))
        }
        heap.append(item)
        var child = heap.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard precedes(heap[child], heap[parent]) else { break }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> Simulator.Scheduled? {
        guard !heap.isEmpty else { return nil }
        heap.swapAt(0, heap.count - 1)
        let top = heap.removeLast()
        var parent = 0
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var first = parent
            if left < heap.count, precedes(heap[left], heap[first]) { first = left }
            if right < heap.count, precedes(heap[right], heap[first]) { first = right }
            guard first != parent else { break }
            heap.swapAt(parent, first)
            parent = first
        }
        if case .core(.tick) = top.delivery {
            ticks.remove(TickKey(node: top.node, time: top.time))
        }
        return top
    }

    private func precedes(_ a: Simulator.Scheduled, _ b: Simulator.Scheduled) -> Bool {
        a.time != b.time ? a.time < b.time : a.sequence < b.sequence
    }
}
