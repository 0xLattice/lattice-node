import Lattice
import cashew
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
    /// An answer for one level: a children map fetched, a page served,
    /// proofs found or verified, an evidence index change.
    case level(ChainPath, Event)
    case tick
    /// This host's own grind: a level's `MiningEffect.mined`, its content
    /// stored and its carried blocks' proofs verified by the shell. With a
    /// reply ID, the step answers `workSubmitted`.
    case mined(MinedGrind, replyID: UInt64? = nil)
}

/// What a submitted grind did at the root level.
public enum MinedOutcome: Sendable, Equatable {
    /// The root met its own target, was weighed on the best chain and
    /// executed; `tipCID` is the act-on tip after its execution.
    case executed(tipCID: String)
    /// The root was weighed off the best chain: it is not executed.
    case side
    /// The root was weighed and its execution proved it invalid.
    case invalid
    /// The root was already weighed.
    case duplicate
    /// The grind missed the root's own target: only the blocks it carries
    /// weigh, and the work stays open.
    case childOnly
    /// The root header was refused.
    case refused
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
        public let children: FlatDictionary<BlockHeader>
        public let proof: ChildBlockProof
        public let evidence: VerifiedChildEvidence

        public init(path: ChainPath, block: Block, children: FlatDictionary<BlockHeader>, proof: ChildBlockProof, evidence: VerifiedChildEvidence) {
            self.path = path
            self.block = block
            self.children = children
            self.proof = proof
            self.evidence = evidence
        }
    }

    public let root: Block
    public let rootChildren: FlatDictionary<BlockHeader>
    public let carried: [Carried]

    public init(root: Block, rootChildren: FlatDictionary<BlockHeader>, carried: [Carried]) {
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
    case wakeAt(Int64)
}

/// The root level a host runs: its chain, its configured genesis and spec,
/// and the id of its weigh log.
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

    public var isEmpty: Bool { levels.isEmpty }

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
            cursors: held.cursors.merging(batch.cursors) { $1 }
        )
    }
}

/// The node's state machine across levels: one `Core` per chain it hosts —
/// the root and the child chains the operator chose — as values behind one
/// synchronous `step`. Everything between levels is a plain read: a child's
/// parent facts are its parent level's tree; run attribution reads the
/// parent's runs, forwarding what each level weighed; one mined grind weighs
/// every level it carries in one step and one batch.
///
/// A hosted child level runs from the start: every genesis under its
/// directory is a root of its tree, weighed by its proofs and executed like
/// any block, and fork choice picks among them (an operator pin admits one).
public struct HostCore: Sendable {
    public let rootPath: ChainPath
    /// The child chains this host runs (operator choice).
    public let hosted: Set<ChainPath>
    public let config: CoreConfig
    /// Names this host's weigh logs: level `path` logs as `logID/path`. A
    /// host whose store resets takes a new one.
    public let logID: String
    public internal(set) var levels: [ChainPath: Core] = [:]
    public internal(set) var peers: Set<PeerID> = []
    /// Operator overrides: the one genesis a child chain admits.
    public let pins: [ChainPath: String]

    /// A host over its root tree, running every hosted child level whose
    /// parent level it runs, each empty.
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
        for path in hosted.sorted(by: Self.order) {
            guard let context = try? ChainRuntimeContext(path: path, genesisCID: pins[path]), serve(path) else { continue }
            levels[path] = Core(
                tree: ChainTree.empty(context: context), config: config,
                log: WeighLog(id: Self.logID(logID, path))
            )
        }
    }

    /// The root level's log: one per host store.
    static func logID(_ host: String, _ path: ChainPath) -> String {
        host + "/" + path.joined(separator: "/")
    }

    /// Rebuild a host from its durable facts: the root level over its
    /// record, then each hosted child level, parent before child, over the
    /// specs its genesis roots name. A child level's attributed runs are
    /// derived from its restored parent, never read.
    public static func restore(
        root record: LevelRecord,
        facts: [ChainPath: [BlockImportBatch]],
        specs: [ChainPath: [ChainSpec]] = [:],
        hosted: Set<ChainPath>,
        pins: [ChainPath: String] = [:],
        config: CoreConfig = CoreConfig(),
        logID: String = "",
        cursors: [ChainPath: [String: StreamCursor]] = [:]
    ) throws -> HostCore {
        let restoredRoot = try Core.restore(
            replaying: facts[record.path] ?? [],
            context: try ChainRuntimeContext(path: record.path, genesisCID: record.genesis.blockCID),
            specs: [record.spec]
        )
        var host = HostCore(
            root: restoredRoot.tree,
            hosted: hosted,
            pins: pins,
            config: config,
            logID: logID,
            rootLog: restoredRoot.sync.log.entries,
            rootCursors: cursors[record.path] ?? [:]
        )
        // Parent before child: each restores over its restored parent.
        for path in host.ordered where path != host.rootPath {
            guard let parent = host.levels[Array(path.dropLast())] else { continue }
            host.levels[path] = try Core.restore(
                replaying: facts[path] ?? [],
                context: try ChainRuntimeContext(path: path, genesisCID: pins[path]),
                specs: specs[path] ?? [],
                parent: parent.tree,
                config: config,
                logID: HostCore.logID(logID, path),
                cursors: cursors[path] ?? [:]
            )
        }
        return host
    }

    static func order(_ a: ChainPath, _ b: ChainPath) -> Bool {
        a.count != b.count ? a.count < b.count : a.joined(separator: "/") < b.joined(separator: "/")
    }

    /// Levels parent before child.
    public var ordered: [ChainPath] { levels.keys.sorted(by: Self.order) }

    /// What a child level's execution reads of its parent: the parent's
    /// executed set on any branch. A parent level executes only along its
    /// own best chain (decision 21): a child block naming a state it never
    /// executed waits, unvalidated, until it does.
    public func parentFacts(for path: ChainPath) -> ParentLevelFacts? {
        let parent = Array(path.dropLast())
        guard path.count > 1, let core = levels[parent] else { return nil }
        return ParentLevelFacts(tree: core.tree)
    }

    // MARK: - Step

    struct Turn {
        let now: Int64
        var batch = HostBatch()
        var effects: [HostEffect] = []
        var disconnects: [PeerID: DisconnectReason] = [:]
        var wake: Int64?
        /// What each level's admissions weighed this step
        /// (`ChainTreeUpdate.weighed`), forwarded to run attribution.
        var weighed: [ChainPath: Set<String>] = [:]
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
        case .mined(let grind, let replyID):
            mined(grind, replyID: replyID, &turn)
        }
        dropDisconnected(&turn)
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
        turn.weighed[path, default: []].formUnion(core.weighed)
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

    // MARK: - Mined handoff

    /// Weigh one of this host's grinds at every level it reaches, in one
    /// step: the root block when its hash meets its own target (a share that
    /// misses it weighs only the child blocks it carries), then each carried
    /// block, parent level before child.
    /// With a reply ID, the root's answer: at once for a share, a duplicate
    /// or a refusal; for a weighed root, once it executes (or is weighed
    /// off the best chain), as the root level's `workSubmitted`.
    mutating func mined(_ grind: MinedGrind, replyID: UInt64?, _ turn: inout Turn) {
        var outcome: MinedOutcome? = .childOnly
        if ChainTree.rootWork(of: grind.root) != nil, var core = levels[rootPath],
           let cid = try? BlockHeader(node: grind.root).rawCID {
            let held = core.index.contains(cid)
            if !held, let replyID { core.minedReplies[cid] = replyID }
            let effects = core.weighOwn(grind.root, children: grind.rootChildren, proof: nil, now: turn.now)
            turn.weighed[rootPath, default: []].formUnion(core.weighed)
            if held {
                outcome = .duplicate
            } else if core.index.contains(cid) {
                outcome = nil
            } else {
                core.minedReplies[cid] = nil
                outcome = .refused
            }
            levels[rootPath] = core
            absorb(effects, at: rootPath, &turn)
        }
        for carried in grind.carried.sorted(by: { Self.order($0.path, $1.path) }) {
            guard var core = levels[carried.path] else { continue }
            let effects = core.weighOwn(
                carried.block, children: carried.children,
                proof: (carried.proof, carried.evidence), now: turn.now
            )
            turn.weighed[carried.path, default: []].formUnion(core.weighed)
            levels[carried.path] = core
            absorb(effects, at: carried.path, &turn)
        }
        if let replyID, let outcome {
            turn.effects.append(.level(rootPath, .workSubmitted(replyID: replyID, outcome)))
        }
    }

    // MARK: - Run attribution (hierarchical GHOST)

    /// Start a child level's runs: its parent serves runs for its directory.
    /// False when this host does not run the parent level.
    @discardableResult
    mutating func serve(_ path: ChainPath) -> Bool {
        let parent = Array(path.dropLast())
        guard path.count > 1, var core = levels[parent] else { return false }
        core.tree.serveRuns(for: path[path.count - 1])
        levels[parent] = core
        return true
    }

    /// Credit each child level with the parent runs this step can have
    /// moved, parent levels first: the parent level's weighed blocks and the
    /// blocks its own derivation raised, and this level's weighed blocks,
    /// forwarded unchanged. What a level raises flows on down.
    mutating func attributeRuns(_ turn: inout Turn) {
        var raised: [ChainPath: Set<String>] = [:]
        for path in ordered where path.count > 1 {
            let parent = Array(path.dropLast())
            let parentBlocks = (turn.weighed[parent] ?? []).union(raised[parent] ?? [])
            let held = turn.weighed[path] ?? []
            guard !parentBlocks.isEmpty || !held.isEmpty,
                  let parentCore = levels[parent], var core = levels[path] else { continue }
            let result = core.applyParentRun(
                from: parentCore.tree, parentBlocks: parentBlocks, held: held, now: turn.now
            )
            levels[path] = core
            raised[path] = Set(result.raised)
            absorb(result.effects, at: path, &turn)
        }
    }
}

extension ParentLevelFacts {
    /// Whether these facts hold what a child connect lacked.
    public func holds(_ fact: CrossChainEvidenceRequirement) -> Bool {
        switch fact {
        case .parentStateContinuity(let parentPath, let from, let to):
            hasContinuity(ParentStateContinuityLink(parentPath: parentPath, fromStateCID: from, toStateCID: to))
        case .childProof:
            false
        }
    }
}
