import Lattice
import UInt256

/// A chain by its path from the root: `["Nexus"]`, `["Nexus", "Alpha"]`, ...
public typealias ChainPath = [String]

/// What the shell hands the host core.
public enum HostEvent: Sendable {
    /// A session with a peer: it serves every level both ends host.
    case peerReady(PeerID)
    case peerGone(PeerID)
    /// A sync message for one level.
    case received(PeerID, ChainPath, SyncMessage)
    /// An answer for one level: a child index fetched, a page served, proofs
    /// found or verified, an evidence index change.
    case level(ChainPath, Event)
    case tick
    /// The answer to a `bootstrap` effect.
    /// Answers for a genesis no longer being asked are ignored.
    case bootstrapped(ChainPath, genesisCID: String, Result<BootstrappedLevel, BlockImportError>)
    /// This host's own grind.
    case mined(MinedGrind)
}

/// A hosted child chain's genesis, bootstrapped by the shell.
public struct BootstrappedLevel: Sendable {
    public let genesis: StoredHeader
    public let spec: ChainSpec
    public let bootstrap: GenesisBootstrap

    public init(genesis: StoredHeader, spec: ChainSpec, bootstrap: GenesisBootstrap) {
        self.genesis = genesis
        self.spec = spec
        self.bootstrap = bootstrap
    }
}

/// One grind this host mined: the root block (a root-chain block when its
/// hash meets its own target, otherwise a share that never enters the root
/// chain) and every child block it carries, each with its proof and that
/// proof's verified evidence. One grind is one atomic subtree insert: every
/// level it weighs persists in one batch.
public struct MinedGrind: Sendable {
    public struct Carried: Sendable {
        public let path: ChainPath
        public let block: Block
        public let children: ChildIndex
        public let proof: ChildBlockProof
        public let evidence: VerifiedChildEvidence

        public init(path: ChainPath, block: Block, children: ChildIndex, proof: ChildBlockProof, evidence: VerifiedChildEvidence) {
            self.path = path
            self.block = block
            self.children = children
            self.proof = proof
            self.evidence = evidence
        }
    }

    public let root: Block
    public let rootChildren: ChildIndex
    public let carried: [Carried]

    public init(root: Block, rootChildren: ChildIndex, carried: [Carried]) {
        self.root = root
        self.rootChildren = rootChildren
        self.carried = carried
    }
}

public enum HostEffect: Sendable {
    /// Every level's writes of one step, in one transaction, before any
    /// later effect of the step.
    case persist(HostBatch)
    /// Every level effect but `connect`.
    case level(ChainPath, Effect)
    /// Run `ChainTree.connect` on a level's job, reading `parentFacts` for a
    /// child level, and report the verdict as `.level(path, .connected)`.
    case connect(ChainPath, ConnectJob, parentFacts: ParentLevelFacts?)
    case disconnect(PeerID, DisconnectReason)
    /// Bootstrap a hosted child chain from the genesis a parent's executed
    /// block authorized, reading `parentFacts`; answer `bootstrapped`.
    case bootstrap(ChainPath, genesisCID: String, parentFacts: ParentLevelFacts)
    case wakeAt(Int64)
}

/// A level the host runs: its chain, spec, genesis header and the id of
/// its weigh log (one per instance: a level bootstrapped again, even on the
/// same genesis, starts a new log). A record for a path that already has
/// one replaces it: that path's earlier facts are left unreferenced.
public struct LevelRecord: Sendable {
    public let path: ChainPath
    public let spec: ChainSpec
    public let genesis: StoredHeader
    public let logID: String

    public init(path: ChainPath, spec: ChainSpec, genesis: StoredHeader, logID: String = "") {
        self.path = path
        self.spec = spec
        self.genesis = genesis
        self.logID = logID
    }
}

/// The durable form of one host step, across levels.
public struct HostBatch: Sendable {
    public internal(set) var levels: [(path: ChainPath, batch: PersistBatch)] = []
    public internal(set) var added: [LevelRecord] = []
    /// Child levels this host stopped running (their genesis left the
    /// parent's act-on path): a restore drops them.
    ///
    /// For the shell: a removed level is unpublished and no longer served.
    /// The core drops the removed level's own effects of the same step, so
    /// nothing it emitted that step reaches the network.
    public internal(set) var removed: [ChainPath] = []
    public internal(set) var issued: [IssuedGenesisLink] = []

    public var isEmpty: Bool { levels.isEmpty && added.isEmpty && issued.isEmpty && removed.isEmpty }

    mutating func append(_ batch: PersistBatch, at path: ChainPath) {
        guard let index = levels.firstIndex(where: { $0.path == path }) else {
            levels.append((path, batch))
            return
        }
        let held = levels[index].batch
        levels[index].batch = PersistBatch(
            headers: held.headers + batch.headers,
            states: held.states + batch.states,
            facts: held.facts + batch.facts,
            genesisLinks: held.genesisLinks + batch.genesisLinks,
            cursors: held.cursors.merging(batch.cursors) { $1 }
        )
    }
}

/// The node's state machine across levels: one `Core` per chain it hosts —
/// the root and the child chains the operator chose — as values behind one
/// synchronous `step`. Everything between levels is a plain read: a child's
/// parent facts are its parent level's tree and the genesis links that
/// level's executions issued; run attribution reads the parent's runs; one
/// mined grind weighs every level it carries in one step and one batch.
public struct HostCore: Sendable {
    public let rootPath: ChainPath
    /// The child chains this host runs (operator choice).
    public let hosted: Set<ChainPath>
    public let config: CoreConfig
    /// Names this host's weigh logs: level `path` logs as `logID/path`. A
    /// host whose store resets takes a new one.
    public let logID: String
    public internal(set) var levels: [ChainPath: Core] = [:]
    /// Per parent level: each genesis link its executions issued, by issuer.
    /// Read through `ParentLevelFacts`, which honours a link only while an
    /// issuer is executed. Deleted in Lattice 41 (decision 18d).
    public internal(set) var issuers: [ChainPath: [ParentGenesisLink: Set<String>]] = [:]
    public internal(set) var peers: Set<PeerID> = []
    /// Operator overrides: the genesis to host for a child chain.
    public let pins: [ChainPath: String]
    /// The genesis being bootstrapped per child chain, and the geneses whose
    /// bootstrap failed (tried again on a tick: their content may arrive).
    var bootstrapping: [ChainPath: String] = [:]
    var failed: [ChainPath: Set<String>] = [:]
    /// Per child level: the parent blocks that commit each child block.
    var committers: [ChainPath: [String: Set<String>]] = [:]

    public init(
        root: ChainTree,
        hosted: Set<ChainPath>,
        pins: [ChainPath: String] = [:],
        config: CoreConfig = CoreConfig(),
        logID: String = "",
        rootLog: [LogEntry] = [],
        rootCursors: [String: StreamCursor] = [:]
    ) {
        var core = Core(tree: root, config: config)
        rootPath = core.chainPath
        core = Core(
            tree: core.tree, config: config,
            log: WeighLog(id: Self.logID(logID, rootPath), entries: rootLog), cursors: rootCursors
        )
        self.hosted = hosted
        self.pins = pins
        self.config = config
        self.logID = logID
        levels[rootPath] = core
    }

    /// The root level's log: one per host store.
    static func logID(_ host: String, _ path: ChainPath) -> String {
        host + "/" + path.joined(separator: "/")
    }

    /// A child level instance's log: its genesis and when it was
    /// bootstrapped (a nonce per instance).
    static func logID(_ host: String, genesis: String, at now: Int64) -> String {
        "\(host)/\(genesis)/\(now)"
    }

    /// Rebuild a host from its durable batches: each level's facts over its
    /// record, and the genesis links its parents issued.
    public static func restore(
        records: [LevelRecord],
        facts: [ChainPath: [BlockImportBatch]],
        issued: [IssuedGenesisLink],
        hosted: Set<ChainPath>,
        pins: [ChainPath: String] = [:],
        config: CoreConfig = CoreConfig(),
        logID: String = "",
        cursors: [ChainPath: [String: StreamCursor]] = [:]
    ) throws -> HostCore {
        let ordered = records.sorted { order($0.path, $1.path) }
        guard let root = ordered.first else { throw HostRestoreError.noRoot }
        let restoredRoot = try Core.restore(
            replaying: facts[root.path] ?? [],
            context: try ChainRuntimeContext(path: root.path),
            spec: root.spec
        )
        var host = HostCore(
            root: restoredRoot.tree,
            hosted: hosted,
            pins: pins,
            config: config,
            logID: logID,
            rootLog: restoredRoot.sync.log.entries,
            rootCursors: cursors[root.path] ?? [:]
        )
        for record in ordered.dropFirst() {
            // A level the operator no longer hosts, or whose parent is gone,
            // is not restored.
            guard hosted.contains(record.path), host.levels[Array(record.path.dropLast())] != nil else { continue }
            host.levels[record.path] = try Core.restore(
                replaying: facts[record.path] ?? [],
                context: try ChainRuntimeContext(path: record.path),
                spec: record.spec,
                config: config,
                logID: record.logID.isEmpty ? HostCore.logID(logID, record.path) : record.logID,
                cursors: cursors[record.path] ?? [:]
            )
            host.serve(record.path)
        }
        for issue in issued {
            host.issuers[issue.link.parentPath, default: [:]][issue.link, default: []].insert(issue.issuer)
        }
        return host
    }

    /// The bootstraps a restored host owes: each hosted child chain it does
    /// not run yet whose genesis is now resolvable. The shell steps `.tick`
    /// after `restore`, which asks for them.
    public mutating func pendingBootstraps(now: Int64) -> [HostEffect] {
        var turn = Turn(now: now)
        reconcileChildren(retryFailed: true, &turn)
        return emit(turn)
    }

    public enum HostRestoreError: Error {
        case noRoot
    }

    static func order(_ a: ChainPath, _ b: ChainPath) -> Bool {
        a.count != b.count ? a.count < b.count : a.joined(separator: "/") < b.joined(separator: "/")
    }

    /// Levels parent before child.
    public var ordered: [ChainPath] { levels.keys.sorted(by: Self.order) }

    /// What a child level's execution and bootstrap read of its parent: the
    /// parent's executed set on any branch, and the genesis links its
    /// executed blocks issued. A parent level executes only along its own
    /// best chain (decision 21): a child block naming a state it never
    /// executed waits, unvalidated, until it does.
    public func parentFacts(for path: ChainPath) -> ParentLevelFacts? {
        let parent = Array(path.dropLast())
        guard path.count > 1, let core = levels[parent] else { return nil }
        return ParentLevelFacts(tree: core.tree, genesisIssuers: issuers[parent] ?? [:])
    }

    // MARK: - Step

    struct Turn {
        let now: Int64
        var batch = HostBatch()
        var effects: [HostEffect] = []
        var disconnects: [PeerID: DisconnectReason] = [:]
        var wake: Int64?
        /// Blocks whose weight changed this step, per level.
        var touched: [ChainPath: Set<String>] = [:]
        /// Parent blocks whose runs to report this step, per child level.
        var reports: [ChainPath: Set<String>] = [:]
    }

    public mutating func step(_ event: HostEvent, now: Int64) -> [HostEffect] {
        var turn = Turn(now: now)
        switch event {
        case .peerReady(let peer):
            guard peers.insert(peer).inserted else { break }
            for path in ordered { run(path, .peerReady(peer), &turn) }
        case .peerGone(let peer):
            guard peers.remove(peer) != nil else { break }
            for path in ordered { run(path, .peerGone(peer), &turn) }
        case .received(let peer, let path, let message):
            guard peers.contains(peer) else { break }
            if levels[path] != nil {
                run(path, .received(peer, message), &turn)
            } else {
                answerUnhosted(message, at: path, from: peer, &turn)
            }
        case .level(let path, let event):
            if levels[path] != nil { run(path, event, &turn) }
        case .tick:
            for path in ordered { run(path, .tick, &turn) }
        case .bootstrapped(let path, let genesisCID, let result):
            bootstrapped(result, genesisCID: genesisCID, at: path, &turn)
        case .mined(let grind):
            mined(grind, &turn)
        }
        dropDisconnected(&turn)
        if case .tick = event {
            reconcileChildren(retryFailed: true, &turn)
        } else {
            reconcileChildren(&turn)
        }
        attributeRuns(&turn)
        return emit(turn)
    }

    /// One step's effects: its one batch first, then the rest in order.
    func emit(_ turn: Turn) -> [HostEffect] {
        var effects: [HostEffect] = turn.batch.isEmpty ? [] : [.persist(turn.batch)]
        effects += turn.effects
        effects += turn.disconnects.sorted { $0.key < $1.key }.map { .disconnect($0.key, $0.value) }
        if let wake = turn.wake { effects.append(.wakeAt(wake)) }
        return effects
    }

    /// Step one level. A level that executed a block wakes each child
    /// block awaiting a fact it now holds; a level's own verdict is checked
    /// the same way, since its parent may have executed while it ran.
    mutating func run(_ path: ChainPath, _ event: Event, _ turn: inout Turn) {
        guard var core = levels[path] else { return }
        let effects = core.step(event, now: turn.now)
        levels[path] = core
        absorb(effects, at: path, &turn)
        let executed = effects.contains {
            guard case .persist(let batch) = $0 else { return false }
            return batch.facts.flatMap(\.facts).contains {
                if case .validation = $0 { return true }
                return false
            }
        }
        if executed {
            for child in ordered where child.dropLast().elementsEqual(path) {
                wakeAnswered(child, &turn)
            }
        }
        if case .connected = event { wakeAnswered(path, &turn) }
    }

    /// Connect again the blocks of a child level whose awaited parent fact
    /// is now present; a level with none is not stepped.
    mutating func wakeAnswered(_ path: ChainPath, _ turn: inout Turn) {
        guard let core = levels[path], !core.bodies.awaitingParent.isEmpty,
              let facts = parentFacts(for: path) else { return }
        let present = core.bodies.awaitingParent.filter { facts.holds($0.value) }.keys.sorted()
        guard !present.isEmpty else { return }
        run(path, .parentFactsPresent(present), &turn)
    }

    /// A level's effects join the host's: persists merge into the step's one
    /// batch, a disconnect ends the session at every level, wakes merge.
    mutating func absorb(_ effects: [Effect], at path: ChainPath, _ turn: inout Turn) {
        for effect in effects {
            switch effect {
            case .persist(let batch):
                turn.batch.append(batch, at: path)
                // Genesis links: deleted in Lattice 41 (decision 18d), and
                // this recording with them.
                for issued in batch.genesisLinks
                where issuers[path, default: [:]][issued.link, default: []].insert(issued.issuer).inserted {
                    turn.batch.issued.append(issued)
                }
                for fact in batch.facts.flatMap(\.facts) {
                    switch fact {
                    case .block(let block): turn.touched[path, default: []].insert(block.blockHash)
                    case .work(let work): turn.touched[path, default: []].insert(work.blockHash)
                    case .validation, .exclusion: break
                    }
                }
                for header in batch.headers {
                    for (directory, child) in header.children.entries {
                        let childPath = path + [directory]
                        guard hosted.contains(childPath) else { continue }
                        committers[childPath, default: [:]][child.rawCID, default: []].insert(header.blockCID)
                    }
                }
            case .disconnect(let peer, let reason):
                turn.disconnects[peer] = turn.disconnects[peer] ?? reason
            case .wakeAt(let time):
                turn.wake = min(turn.wake ?? time, time)
            case .connect(let job):
                turn.effects.append(.connect(path, job, parentFacts: parentFacts(for: path)))
            default:
                turn.effects.append(.level(path, effect))
            }
        }
    }

    mutating func dropDisconnected(_ turn: inout Turn) {
        for peer in turn.disconnects.keys.sorted() where peers.remove(peer) != nil {
            for path in ordered { run(path, .peerGone(peer), &turn) }
        }
    }

    /// A level this host does not run answers at once, so a peer's request
    /// never waits out its deadline here: its log at this level is the empty
    /// one (id ""), so the asker's cursor for it starts over (only that
    /// level's), and what it asked of the old log is forgotten, never a
    /// stall.
    func answerUnhosted(_ message: SyncMessage, at path: ChainPath, from peer: PeerID, _ turn: inout Turn) {
        switch message {
        case .getStream(let id, _, _, _):
            turn.effects.append(.level(path, .send(peer, .stream(StreamPage(
                requestID: id, logID: "", entries: [], hasMore: false
            )))))
        case .getData, .getAncestors:
            turn.effects.append(.level(path, .send(peer, .stream(StreamPage(
                requestID: 0, logID: "", entries: [], hasMore: false
            )))))
            // An ancestors request is answered "not held".
            if case .getAncestors(let id, _, _) = message {
                turn.effects.append(.level(path, .send(peer, .headers(HeadersResponse(
                    requestID: id, entries: [], hasMore: false
                )))))
            }
        case .stream, .headers:
            return
        }
    }

    // MARK: - Genesis links

    /// The genesis a hosted child chain must run on (decision 15c): the
    /// operator's pinned genesis, once an executed parent block authorizes
    /// it; otherwise the link issued by the executed parent block on the
    /// path to the parent's act-on tip (a path holds at most one link per
    /// directory). Nil: host nothing.
    func wantedGenesis(of child: ChainPath) -> ParentGenesisLink? {
        let parent = Array(child.dropLast())
        guard let core = levels[parent], let facts = parentFacts(for: child) else { return nil }
        let directory = child[child.count - 1]
        let links = (issuers[parent] ?? [:]).filter { $0.key.directory == directory }
        if let pin = pins[child] {
            return links.keys.filter { $0.childGenesisCID == pin && facts.recordsGenesis($0) }
                .min { $0.parentStateCID < $1.parentStateCID }
        }
        let actOn = core.snapshot.actOnHeight
        return links.compactMap { link, issuers -> (UInt64, ParentGenesisLink)? in
            let onPath = issuers.compactMap { issuer -> UInt64? in
                guard core.tree.isCanonical(hash: issuer), core.tree.hasExecutedAncestry(blockHash: issuer),
                      let height = core.tree.headerSnapshot(of: issuer)?.tipHeight, height <= actOn else { return nil }
                return height
            }
            return onPath.min().map { ($0, link) }
        }.min { $0.0 < $1.0 }?.1
    }

    /// Make every hosted child chain run on its wanted genesis, parent before
    /// child: a level on another genesis (or with none wanted) stops, with
    /// its descendants, and the wanted one is bootstrapped. A failed genesis
    /// is tried again only on a tick.
    mutating func reconcileChildren(retryFailed: Bool = false, _ turn: inout Turn) {
        for path in levels.keys.sorted(by: Self.order) where path != rootPath && !hosted.contains(path) {
            remove(path, &turn)
        }
        for child in hosted.sorted(by: Self.order) {
            let wanted = wantedGenesis(of: child)
            if let level = levels[child], level.genesis != wanted?.childGenesisCID {
                remove(child, &turn)
            }
            guard let link = wanted, levels[child] == nil, let facts = parentFacts(for: child),
                  bootstrapping[child] != link.childGenesisCID else { continue }
            if failed[child]?.contains(link.childGenesisCID) == true {
                guard retryFailed else { continue }
                failed[child]?.remove(link.childGenesisCID)
            }
            bootstrapping[child] = link.childGenesisCID
            turn.effects.append(.bootstrap(child, genesisCID: link.childGenesisCID, parentFacts: facts))
        }
    }

    /// Stop a child level and its descendants: recorded as removed, its
    /// writes and effects of this step dropped.
    mutating func remove(_ child: ChainPath, _ turn: inout Turn) {
        for path in levels.keys.sorted(by: Self.order) where path.starts(with: child) {
            levels[path] = nil
            committers[path] = nil
            bootstrapping[path] = nil
            turn.batch.levels.removeAll { $0.path == path }
            turn.batch.removed.append(path)
            turn.effects.removeAll {
                switch $0 {
                case .level(let at, _), .connect(let at, _, _): return at == path
                default: return false
                }
            }
        }
    }

    /// A bootstrapped child chain becomes a level if it is still the wanted
    /// genesis. Its genesis persists with the step (replacing any earlier
    /// record for the path), its parent starts serving runs for it, and it
    /// syncs from every peer. A failed bootstrap is retried on a tick.
    mutating func bootstrapped(
        _ result: Result<BootstrappedLevel, BlockImportError>,
        genesisCID: String,
        at path: ChainPath,
        _ turn: inout Turn
    ) {
        // A stale answer (a genesis no longer asked) changes nothing: it can
        // never mark the current genesis failed.
        guard bootstrapping[path] == genesisCID else { return }
        guard let asked = bootstrapping.removeValue(forKey: path), levels[path] == nil, hosted.contains(path) else { return }
        guard case .success(let level) = result, level.genesis.blockCID == asked,
              wantedGenesis(of: path)?.childGenesisCID == asked else {
            if case .failure = result { failed[path, default: []].insert(asked) }
            return
        }
        let instance = Self.logID(logID, genesis: level.genesis.blockCID, at: turn.now)
        levels[path] = Core(tree: level.bootstrap.tree, config: config, log: WeighLog(id: instance))
        turn.batch.removed.removeAll { $0 == path }
        turn.batch.levels.removeAll { $0.path == path }
        turn.batch.append(PersistBatch(headers: [level.genesis], facts: [level.bootstrap.facts]), at: path)
        turn.batch.added.append(LevelRecord(path: path, spec: level.spec, genesis: level.genesis, logID: instance))
        serve(path)
        turn.reports[path, default: []].formUnion(committers[path]?.values.flatMap { $0 } ?? [])
        for peer in peers.sorted() { run(path, .peerReady(peer), &turn) }
    }

    // MARK: - Mined handoff

    /// Weigh one of this host's grinds at every level it reaches, in one
    /// step: the root block when its hash meets its own target (a share that
    /// misses it weighs only the child blocks it carries), then each carried
    /// block, parent level before child.
    mutating func mined(_ grind: MinedGrind, _ turn: inout Turn) {
        if ChainTree.rootWork(of: grind.root) != nil, var core = levels[rootPath] {
            let effects = core.weighOwn(grind.root, children: grind.rootChildren, proof: nil, now: turn.now)
            levels[rootPath] = core
            absorb(effects, at: rootPath, &turn)
        }
        for carried in grind.carried.sorted(by: { Self.order($0.path, $1.path) }) {
            guard var core = levels[carried.path] else { continue }
            let effects = core.weighOwn(
                carried.block, children: carried.children,
                proof: (carried.proof, carried.evidence), now: turn.now
            )
            levels[carried.path] = core
            absorb(effects, at: carried.path, &turn)
        }
    }

    // MARK: - Run attribution (hierarchical GHOST)

    /// Start a child level's run reports: its parent serves runs for its
    /// directory, and the parent's recorded commitments into it are indexed.
    mutating func serve(_ path: ChainPath) {
        let parent = Array(path.dropLast())
        let directory = path[path.count - 1]
        guard var core = levels[parent] else { return }
        core.tree.serveRuns(for: directory)
        var index: [String: Set<String>] = [:]
        var stack = [core.tree.canonicalBlockHash(atHeight: 0) ?? core.tree.canonicalTip]
        while let hash = stack.popLast() {
            guard let meta = core.tree.getConsensusBlock(hash: hash) else { continue }
            stack += meta.childHashes
            if let child = core.tree.recordedChildCommitments(of: hash)?[directory] {
                index[child, default: []].insert(hash)
            }
        }
        levels[parent] = core
        committers[path, default: [:]].merge(index) { $0.union($1) }
    }

    /// Credit each child level with its parent's attributed runs that this
    /// step may have raised: the run of every parent block whose weight
    /// changed, and the committers of every child block that did. Parent
    /// before child, so a strengthened child block's own run flows on down.
    mutating func attributeRuns(_ turn: inout Turn) {
        for path in ordered where path.count > 1 {
            let parent = Array(path.dropLast())
            let directory = path[path.count - 1]
            guard let parentCore = levels[parent], levels[path] != nil else { continue }
            var candidates = turn.reports[path] ?? []
            for hash in turn.touched[parent] ?? [] {
                if let committer = parentCore.tree.nearestCarrier(of: hash, directory: directory) {
                    candidates.insert(committer)
                }
            }
            for hash in turn.touched[path] ?? [] {
                candidates.formUnion(committers[path]?[hash] ?? [])
            }
            for committer in candidates.sorted() {
                guard let report = parentCore.tree.parentRunReport(at: committer, directory: directory),
                      var core = levels[path], core.tree.contains(blockHash: report.childBlock),
                      let effects = core.strengthen(report.childBlock, directory: directory, report: report, now: turn.now)
                else { continue }
                levels[path] = core
                absorb(effects, at: path, &turn)
            }
        }
    }
}

extension ParentLevelFacts {
    /// Whether these facts hold what a child connect lacked.
    public func holds(_ fact: CrossChainEvidenceRequirement) -> Bool {
        switch fact {
        case .parentStateContinuity(let parentPath, let from, let to):
            hasContinuity(ParentStateContinuityLink(parentPath: parentPath, fromStateCID: from, toStateCID: to))
        case .parentGenesis(let parentPath, let directory, let genesis, let parentState):
            // Deleted with genesis links in Lattice 41 (decision 18d).
            recordsGenesis(ParentGenesisLink(
                parentPath: parentPath, directory: directory,
                childGenesisCID: genesis, parentStateCID: parentState
            ))
        case .childProof:
            false
        }
    }
}
