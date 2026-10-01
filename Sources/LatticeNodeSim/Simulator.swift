import Lattice
import LatticeNodeCore

/// One simulation's shape. `random(seed:)` draws a seed's own shape.
public struct SimConfig: Sendable {
    public var seed: UInt64
    public var cores = 4
    public var honestSources = 2
    public var spammer = true
    public var liar = true
    /// A script that shows the world's uncle to core0 alone.
    public var uncle = false
    /// Headers of garbage the spammer floods per connection.
    public var garbage = 16
    /// The honest chain stops after this block for this long, then resumes.
    public var stall: (afterBlock: Int, milliseconds: Int64)?
    public var honestBlocks = 40
    public var forkProbability = 0.2
    public var spamBlocks = 4
    /// Probability that a message breaks its link (a session ends, as a TCP
    /// connection does). Within a session every message arrives, in order,
    /// after the link's latency and its bandwidth's transfer time.
    public var drop = 0.02
    public var duplicate = 0.05
    /// Each session's one-way latency is drawn from this range.
    public var minDelay: Int64 = 5
    public var maxDelay: Int64 = 250
    /// Bytes per millisecond on every link, unless `slowLinks` names it.
    public var bandwidth = 1_000.0
    public var slowLinks: [String: Double] = [:]
    /// Probability that a reconnect attempt fails (retried later, backing
    /// off): links do not always come back.
    public var reconnectFailure = 0.0
    /// Core-to-core links: every pair, or a ring (multi-hop).
    public var ring = false
    /// How many cores each honest source connects to (nil: all).
    public var sourceFanout: Int?
    /// Side leaves added beside the honest chain.
    public var sideLeaves = 0
    /// A partition: the first half of the cores follows source0 mining the
    /// lighter side, the rest source1 mining the heavier side, with no link
    /// between the halves until the last release.
    public var split: (lighter: Int, heavier: Int)?
    public var pageSize = 8
    public var headersTimeout: Int64 = 2_000
    /// Honest child indexes of one entry travel inline; those of 48 do not.
    public var inlineChildIndexBytes = 1_024
    public var pendingBudget = 256 * 1_024
    public var reconnectDelay: Int64 = 3_000
    /// Each core asks each peer for a repair catch-up this often.
    public var catchUpInterval: Int64 = 20_000
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
        config.cores = rng.draw(2...5)
        config.honestSources = rng.draw(1...2)
        config.spammer = rng.chance(0.5)
        config.liar = rng.chance(0.5)
        config.honestBlocks = rng.draw(20...50)
        config.forkProbability = 0.3 * rng.unit()
        config.spamBlocks = rng.draw(1...5)
        config.drop = 0.03 * rng.unit()
        config.duplicate = 0.1 * rng.unit()
        config.maxDelay = rng.draw(Int64(20)...500)
        config.reconnectFailure = 0.3 * rng.unit()
        config.ring = rng.chance(0.3)
        config.sourceFanout = rng.chance(0.3) ? 1 : nil
        config.pageSize = rng.draw(3...16)
        return config
    }
}

/// Bugs a test plants to show an invariant catches them.
public struct SimFaults: Sendable {
    /// Execute a step's `publish` before its `persist`.
    public var publishBeforePersist = false
    /// Lose one fact batch on its way into the store.
    public var dropFact = false
    /// Break the reference's equal-work ties toward the larger CID.
    public var flipReferenceTieBreak = false

    public init() {}
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
    /// Every leaf count a core reached.
    public var peakLeaves = 0
    /// Child indexes fetched by CID (too big to travel inline).
    public var fetches = 0
    /// The most bytes any core's pending queue held after a step.
    public var pendingPeak = 0
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

    /// After the quiet point every honest core selects the same head, and
    /// above the head's height less `sideBranchWindow` holds every released
    /// honest block and the identical weighed graph (the same blocks,
    /// grinds, subtree work and exclusions). A side block forking deeper that
    /// a core missed while a link was down is never re-sent: the catch-up
    /// window's documented boundary.
    func checkQuietPoint() throws {
        let nodes = cores.sorted { $0.key < $1.key }
        guard let (first, reference) = nodes.first else { return }
        let headHeight = reference.digest.blocks[reference.digest.canonicalTip]?.height ?? 0
        let window = coreConfig.sideBranchWindow
        let cutoff = headHeight > window ? headHeight - window : 0
        let above = { (digest: TreeDigest) in digest.blocks.filter { $0.value.height > cutoff } }
        let honest = Set(world.released(world.honest, at: now)
            .filter { $0.height > cutoff }.map(\.cid))
        for (name, node) in nodes {
            if let missing = honest.subtracting(node.digest.blocks.keys).first {
                throw Invariants.fail(name, "misses released honest block \(missing) after the quiet point")
            }
            if above(node.digest) != above(reference.digest)
                || node.digest.excluded.filter({ (node.digest.blocks[$0]?.height ?? 0) > cutoff })
                    != reference.digest.excluded.filter({ (reference.digest.blocks[$0]?.height ?? 0) > cutoff }) {
                throw Invariants.fail(name, "weighs a different graph than \(first) after the quiet point")
            }
            if node.digest.canonicalTip != reference.digest.canonicalTip {
                throw Invariants.fail(name, "head differs from \(first)'s after the quiet point")
            }
        }
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
        /// The session ends: both ends learn it, and reconnect later.
        case linkDown(String, String, UInt64)
    }

    struct Scheduled {
        let time: Int64
        let sequence: UInt64
        let node: String
        let delivery: Delivery
    }

    public let config: SimConfig
    public let coreConfig: CoreConfig
    public let world: World
    var rng: SplitMix64
    public private(set) var now: Int64 = World.genesisTime
    var cores: [String: CoreNode] = [:]
    var scripts: [String: any SimScript] = [:]
    var sessions: [Pair: UInt64] = [:]
    var latency: [Pair: Int64] = [:]
    var connected: Set<Pair> = []
    var busyUntil: [String: Int64] = [:]
    var nextSession: UInt64 = 1
    var queue = EventQueue()
    public private(set) var report = SimReport()
    /// Planted bugs, for proving the invariants can fail.
    public var faults = SimFaults()
    var droppedFact = false

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
            spamBlocks: config.spamBlocks,
            garbage: config.garbage,
            stall: config.stall,
            sideLeaves: config.sideLeaves,
            split: config.split
        )
        return Simulator(config: config, world: world, rng: rng)
    }

    init(config: SimConfig, world: World, rng: SplitMix64) {
        self.config = config
        self.world = world
        self.rng = rng
        let coreConfig = CoreConfig(
            maxHeadersPerPage: config.pageSize,
            headersTimeout: config.headersTimeout,
            maxInlineChildIndexBytes: config.inlineChildIndexBytes,
            pendingBudget: config.pendingBudget,
            catchUpInterval: config.catchUpInterval
        )
        self.coreConfig = coreConfig
        for index in 0..<config.cores {
            let core = Core(tree: world.bootstrap.tree, config: coreConfig)
            cores["core\(index)"] = CoreNode(
                core: core,
                store: SimStore(genesis: world.genesis, facts: world.bootstrap.facts),
                digest: TreeDigest(core.tree)
            )
        }
        let sources = config.split == nil ? config.honestSources : 2
        for index in 0..<sources {
            let chain = config.split == nil ? nil : world.sides[index]
            let source = HonestSource(name: "source\(index)", config: coreConfig, chain: chain)
            scripts[source.name] = source
        }
        if config.spammer { scripts["spammer"] = HeaderSpammer(name: "spammer", config: coreConfig) }
        if config.liar { scripts["liar"] = Liar(name: "liar", config: coreConfig) }
        if config.uncle {
            scripts["uncle"] = UncleShower(name: "uncle", showingTo: "core0", config: coreConfig)
        }

        let coreNames = (0..<config.cores).map { "core\($0)" }
        for (position, name) in coreNames.enumerated() {
            let others = config.ring
                ? (coreNames.count > 1 ? [coreNames[(position + 1) % coreNames.count]] : [])
                : Array(coreNames[(position + 1)...])
            for other in others where other != name {
                schedule(at: linkTime(name, other), to: name, .connect(name, other))
            }
        }
        for script in scripts.keys.sorted() {
            var targets = coreNames
            if config.split != nil, script.hasPrefix("source") {
                let half = (coreNames.count + 1) / 2
                targets = script == "source0" ? Array(coreNames[..<half]) : Array(coreNames[half...])
            } else if script.hasPrefix("source"), let fanout = config.sourceFanout {
                let first = Int(script.dropFirst("source".count)) ?? 0
                targets = (0..<min(fanout, coreNames.count)).map { coreNames[(first + $0) % coreNames.count] }
            }
            for core in targets {
                schedule(at: now, to: core, .connect(core, script))
            }
        }
        for script in scripts.keys.sorted() {
            schedule(at: now, to: script, .scriptTick)
        }
    }

    /// When a link may first come up: a link across the split waits for
    /// the last release.
    func linkTime(_ a: String, _ b: String) -> Int64 {
        guard config.split != nil, let x = Int(a.dropFirst(4)), let y = Int(b.dropFirst(4)),
              a.hasPrefix("core"), b.hasPrefix("core") else { return now }
        let half = (config.cores + 1) / 2
        return (x < half) == (y < half) ? now : lastRelease
    }

    var lastRelease: Int64 {
        world.honest.compactMap { world.blocks[$0]?.releaseAt }.max() ?? now
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
        try checkQuietPoint()
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
            guard now >= linkTime(a, b) else {
                return schedule(at: linkTime(a, b), to: a, .connect(a, b))
            }
            if connected.contains(Pair(a, b)), rng.chance(config.reconnectFailure) {
                return schedule(at: now + 2 * config.reconnectDelay, to: a, .connect(a, b))
            }
            connected.insert(Pair(a, b))
            let id = nextSession
            nextSession += 1
            sessions[Pair(a, b)] = id
            latency[Pair(a, b)] = rng.draw(config.minDelay...config.maxDelay)
            try arrive(at: a, from: b, session: id)
            try arrive(at: b, from: a, session: id)
        case .linkDown(let a, let b, let id):
            guard session(a, b) == id else { return }
            sessions[Pair(a, b)] = nil
            for (end, other) in [(a, b), (b, a)] where cores[end] != nil {
                try step(end, .peerGone(PeerID(key: other, session: id)))
            }
            schedule(at: now + config.reconnectDelay, to: a, .connect(a, b))
        case .core(let event):
            try step(node, event)
        case .scriptMessage(let peer, let message):
            guard session(node, peer.key) == peer.session, var script = scripts[node] else { return }
            let actions = script.received(message, from: peer, now: now, world: world)
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

    /// A message leg: queued behind the link's earlier messages for its
    /// transfer time, then its latency; duplicated by the seed, or lost with
    /// its link.
    mutating func send(_ delivery: Delivery, from: String, to: String) {
        guard let id = session(from, to) else { return }
        if rng.chance(config.drop) {
            schedule(at: now, to: from, .linkDown(from, to, id))
            return
        }
        let pair = Pair(from, to)
        let rate = config.slowLinks[pair.low + "-" + pair.high] ?? config.bandwidth
        let direction = from + ">" + to
        let transfer = Int64((Double(Self.bytes(of: delivery)) / rate).rounded(.up))
        let sent = max(now, busyUntil[direction] ?? now) + transfer
        busyUntil[direction] = sent
        let copies = rng.chance(config.duplicate) ? 2 : 1
        for _ in 0..<copies {
            schedule(at: sent + (latency[pair] ?? config.minDelay), to: to, delivery)
        }
    }

    static func bytes(of delivery: Delivery) -> Int {
        switch delivery {
        case .core(.received(_, let message)), .scriptMessage(_, let message):
            guard case .headers(let response) = message else { return 64 }
            return 64 + response.entries.reduce(0) {
                $0 + ($1.block.toData()?.count ?? 0) + ($1.children?.toData()?.count ?? 0)
            }
        case .core(.childIndexFetched(_, _, let index)):
            return 64 + (index?.toData()?.count ?? 0)
        default:
            return 64
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
        var effects = node.core.step(event, now: now)
        if faults.publishBeforePersist {
            effects = effects.filter { if case .publish = $0 { true } else { false } }
                + effects.filter { if case .publish = $0 { false } else { true } }
        }
        var persisted = false
        for effect in effects {
            switch effect {
            case .persist(var batch):
                if faults.dropFact, !droppedFact, let dropped = batch.facts.last {
                    droppedFact = true
                    batch = PersistBatch(headers: batch.headers, facts: batch.facts.filter { $0 != dropped })
                }
                node.store.append(batch)
                persisted = true
            case .publish(let snapshot):
                // DST 3: durability precedes visibility.
                for tip in [snapshot.bestHeaderTip, snapshot.actOnTip]
                where !node.store.blockFacts.contains(tip) {
                    throw Invariants.fail(name, "published tip \(tip) is not durable")
                }
            case .send(let peer, let message):
                // Relaying a weighed header is not acting on it, but it is
                // sent only once durable.
                if case .headers(let relayed) = message {
                    for entry in relayed.entries {
                        let cid = (try? BlockHeader(node: entry.block).rawCID) ?? ""
                        guard node.store.headers[cid] != nil else {
                            throw Invariants.fail(name, "relayed \(cid) before it was durable")
                        }
                    }
                }
                try route(message, from: name, to: peer)
            case .serveHeaders(let peer, let token, let requestID, let blockCIDs, let hasMore):
                var entries: [HeaderEntry] = []
                for cid in blockCIDs {
                    guard let stored = node.store.headers[cid] else {
                        throw Invariants.fail(name, "served \(cid) before it was durable")
                    }
                    entries.append(coreConfig.entry(stored.block, children: stored.children))
                }
                let page = coreConfig.page(entries, hasMore: hasMore)
                try route(.headers(HeadersResponse(
                    requestID: requestID, entries: page.entries, hasMore: page.hasMore
                )), from: name, to: peer)
                // The shell reports the answer sent; it is local, never lost.
                schedule(at: now, to: name, .core(.headersServed(peer, token: token)))
            case .fetchByCID(let peer, let cid):
                report.fetches += 1
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
                schedule(at: now, to: name, .linkDown(name, peer.key, peer.session))
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
            world: world,
            flipTieBreak: faults.flipReferenceTieBreak,
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
        report.pendingPeak = max(report.pendingPeak, node.core.sync.pending.bytes)
        report.peakLeaves = max(report.peakLeaves, node.core.index.leaves.count)
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
