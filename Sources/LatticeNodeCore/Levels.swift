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
    /// The verdict of executing a block of a level (`ChainTree.connect` over
    /// `connectJob`, with `parentFacts` for a child level).
    case connected(ChainPath, ConnectVerdict)
    /// The answer to a `bootstrap` effect.
    case bootstrapped(ChainPath, Result<BootstrappedLevel, BlockImportError>)
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
    case level(ChainPath, Effect)
    case disconnect(PeerID, DisconnectReason)
    /// Bootstrap a hosted child chain from the genesis a parent's executed
    /// block authorized, reading `parentFacts`; answer `bootstrapped`.
    case bootstrap(ChainPath, genesisCID: String, parentFacts: ParentLevelFacts)
    case wakeAt(Int64)
}

/// A genesis link a parent level's execution issued, and the block that
/// issued it: durable so replay rebuilds the parent's facts.
public struct IssuedGenesisLink: Sendable, Hashable {
    public let link: ParentGenesisLink
    public let issuer: String

    public init(link: ParentGenesisLink, issuer: String) {
        self.link = link
        self.issuer = issuer
    }
}

/// A level the host runs: its chain, spec and genesis header.
public struct LevelRecord: Sendable {
    public let path: ChainPath
    public let spec: ChainSpec
    public let genesis: StoredHeader

    public init(path: ChainPath, spec: ChainSpec, genesis: StoredHeader) {
        self.path = path
        self.spec = spec
        self.genesis = genesis
    }
}

/// The durable form of one host step, across levels.
public struct HostBatch: Sendable {
    public internal(set) var levels: [(path: ChainPath, batch: PersistBatch)] = []
    public internal(set) var added: [LevelRecord] = []
    public internal(set) var issued: [IssuedGenesisLink] = []

    public var isEmpty: Bool { levels.isEmpty && added.isEmpty && issued.isEmpty }

    mutating func append(_ batch: PersistBatch, at path: ChainPath) {
        guard let index = levels.firstIndex(where: { $0.path == path }) else {
            levels.append((path, batch))
            return
        }
        let held = levels[index].batch
        levels[index].batch = PersistBatch(headers: held.headers + batch.headers, facts: held.facts + batch.facts)
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
    public internal(set) var levels: [ChainPath: Core] = [:]
    /// Per parent level: each genesis link its executions issued, by issuer.
    /// Read through `ParentLevelFacts`, which honours a link only while an
    /// issuer is executed.
    public internal(set) var issuers: [ChainPath: [ParentGenesisLink: Set<String>]] = [:]
    public internal(set) var peers: Set<PeerID> = []
    var bootstrapping: Set<ChainPath> = []
    /// Per child level: the parent blocks that commit each child block.
    var committers: [ChainPath: [String: Set<String>]] = [:]

    public init(root: ChainTree, hosted: Set<ChainPath>, config: CoreConfig = CoreConfig()) {
        let core = Core(tree: root, config: config)
        rootPath = core.chainPath
        self.hosted = hosted
        self.config = config
        levels[rootPath] = core
    }

    /// Rebuild a host from its durable batches: each level's facts over its
    /// record, and the genesis links its parents issued.
    public static func restore(
        records: [LevelRecord],
        facts: [ChainPath: [BlockImportBatch]],
        issued: [IssuedGenesisLink],
        hosted: Set<ChainPath>,
        config: CoreConfig = CoreConfig()
    ) throws -> HostCore {
        let ordered = records.sorted { order($0.path, $1.path) }
        guard let root = ordered.first else { throw HostRestoreError.noRoot }
        var host = HostCore(
            root: try Core.restore(
                replaying: facts[root.path] ?? [],
                context: try ChainRuntimeContext(path: root.path),
                spec: root.spec
            ).tree,
            hosted: hosted,
            config: config
        )
        for record in ordered.dropFirst() {
            host.levels[record.path] = try Core.restore(
                replaying: facts[record.path] ?? [],
                context: try ChainRuntimeContext(path: record.path),
                spec: record.spec,
                config: config
            )
            host.serve(record.path)
        }
        for issue in issued {
            host.issuers[issue.link.parentPath, default: [:]][issue.link, default: []].insert(issue.issuer)
        }
        return host
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
    /// executed blocks issued.
    public func parentFacts(for path: ChainPath) -> ParentLevelFacts? {
        let parent = Array(path.dropLast())
        guard path.count > 1, let core = levels[parent] else { return nil }
        return ParentLevelFacts(tree: core.tree, genesisIssuers: issuers[parent] ?? [:])
    }

    /// What executing a held block needs, captured from its level's tree.
    public mutating func connectJob(for blockHash: String, at path: ChainPath) -> ConnectJob? {
        levels[path]?.tree.connectJob(for: blockHash)
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
        case .connected(let path, let verdict):
            connected(verdict, at: path, &turn)
        case .bootstrapped(let path, let result):
            bootstrapped(result, at: path, &turn)
        case .mined(let grind):
            mined(grind, &turn)
        }
        dropDisconnected(&turn)
        attributeRuns(&turn)
        var effects: [HostEffect] = turn.batch.isEmpty ? [] : [.persist(turn.batch)]
        effects += turn.effects
        effects += turn.disconnects.sorted { $0.key < $1.key }.map { .disconnect($0.key, $0.value) }
        if let wake = turn.wake { effects.append(.wakeAt(wake)) }
        return effects
    }

    mutating func run(_ path: ChainPath, _ event: Event, _ turn: inout Turn) {
        guard var core = levels[path] else { return }
        let effects = core.step(event, now: turn.now)
        levels[path] = core
        absorb(effects, at: path, &turn)
    }

    /// A level's effects join the host's: persists merge into the step's one
    /// batch, a disconnect ends the session at every level, wakes merge.
    mutating func absorb(_ effects: [Effect], at path: ChainPath, _ turn: inout Turn) {
        for effect in effects {
            switch effect {
            case .persist(let batch):
                turn.batch.append(batch, at: path)
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

    /// A level this host does not run answers empty at once, so a peer's
    /// request never waits out its deadline here.
    func answerUnhosted(_ message: SyncMessage, at path: ChainPath, from peer: PeerID, _ turn: inout Turn) {
        let requestID: UInt64
        switch message {
        case .getHeaders(let request): requestID = request.requestID
        case .getHeader(let id, _): requestID = id
        case .headers: return
        }
        turn.effects.append(.level(path, .send(peer, .headers(HeadersResponse(
            requestID: requestID, entries: [], hasMore: false
        )))))
    }

    // MARK: - Execution and genesis links

    /// Apply a verdict. A valid block's genesis links are recorded for its
    /// issuer (only an executed block issues any), and each hosted child
    /// chain they now authorize is bootstrapped.
    mutating func connected(_ verdict: ConnectVerdict, at path: ChainPath, _ turn: inout Turn) {
        guard var core = levels[path] else { return }
        let (effects, update) = core.applyConnect(verdict, now: turn.now)
        levels[path] = core
        absorb(effects, at: path, &turn)
        for link in update?.parentGenesisLinks ?? [] {
            guard let issuer = update?.blockHash,
                  issuers[path, default: [:]][link, default: []].insert(issuer).inserted else { continue }
            turn.batch.issued.append(IssuedGenesisLink(link: link, issuer: issuer))
        }
        guard update != nil else { return }
        requestBootstraps(under: path, &turn)
    }

    /// Bootstrap each hosted child of `parent` whose genesis an executed
    /// parent block authorizes (the smallest genesis CID when several do).
    mutating func requestBootstraps(under parent: ChainPath, _ turn: inout Turn) {
        let links = (issuers[parent] ?? [:]).keys.sorted { $0.childGenesisCID < $1.childGenesisCID }
        for link in links {
            let child = parent + [link.directory]
            guard hosted.contains(child), levels[child] == nil, !bootstrapping.contains(child),
                  let facts = parentFacts(for: child), facts.recordsGenesis(link) else { continue }
            bootstrapping.insert(child)
            turn.effects.append(.bootstrap(child, genesisCID: link.childGenesisCID, parentFacts: facts))
        }
    }

    /// A bootstrapped child chain becomes a level, if its genesis is still
    /// authorized by an executed parent block. Its genesis persists with the
    /// step, its parent starts serving runs for it, and it syncs from every
    /// peer.
    mutating func bootstrapped(_ result: Result<BootstrappedLevel, BlockImportError>, at path: ChainPath, _ turn: inout Turn) {
        guard bootstrapping.remove(path) != nil, levels[path] == nil, hosted.contains(path),
              case .success(let level) = result,
              let facts = parentFacts(for: path),
              facts.recordsGenesis(ParentGenesisLink(
                  parentPath: Array(path.dropLast()),
                  directory: path[path.count - 1],
                  childGenesisCID: level.genesis.blockCID,
                  parentStateCID: level.genesis.block.parentState.rawCID
              )) else { return }
        levels[path] = Core(tree: level.bootstrap.tree, config: config)
        turn.batch.append(PersistBatch(headers: [level.genesis], facts: [level.bootstrap.facts]), at: path)
        turn.batch.added.append(LevelRecord(path: path, spec: level.spec, genesis: level.genesis))
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
