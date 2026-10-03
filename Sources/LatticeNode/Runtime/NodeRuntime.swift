import Foundation
import Ivy
import Lattice
import LatticeNodeCore
import cashew

public enum NodeRuntimeError: Error, Equatable, Sendable {
    /// The configured root is not Nexus.
    case notNexus
    /// The runtime stopped before answering.
    case stopped
    /// A request names a chain this node does not host.
    case unknownChain
}

/// The production shell around the sans-IO `LatticeNodeCore.NodeCore`.
/// One serial task owns the node core, drains network messages, content
/// arrivals, job results and timers, calls `step(event, now)`, and executes
/// effects in order — persist, then publish, then everything else. Every
/// decision remains in the core.
///
/// - `persist` (one `NodeBatch`) → the opened `NodeStorage`'s Volume store and state.db
///   (content fsynced first, then the facts in one transaction). A failure
///   stops the storage: restart replays the journal.
/// - `publish` → `published`, read by RPC without touching the loop.
/// - `send` / `serveHeaders` / `disconnect` → the Ivy overlay.
/// - `fetchBody` / `cancelBody` / `fetchByCID` → the content layer
///   (VolumeBroker, then overlay providers by CID).
/// - `connect` / `verifyProof` → a bounded worker pool; the result comes
///   back as an event.
/// - `wakeAt` → one timer that posts `tick`.
/// - `mining` → the pool delta persisted like `persist` (fail-stop), RPC
///   replies answered by reply ID, announces to every ready peer, and the
///   preflight and template jobs on the worker pool (a job whose tip epoch
///   moved before it starts runs nothing).
///
/// RPC writes (`submitTransaction`, `miningTemplate`, `submitWork`) are
/// mining events with reply IDs, one per RPC in flight; RPC reads
/// (`reads`) come from the published snapshot and view, never the loop.
///
/// Network and fetch effects spawn tasks that only post events back, so no
/// suspension ever interleaves two steps.
// Child levels: the operator's `hostedChildren`, each journaling its facts in
// its own state.db under `levels/` (until the P4 fact store); their verified
// proofs are kept in memory for `lookupProofs` and serving.
public final class NodeRuntime: Sendable {
    public let published: PublishedValue<ChainSnapshot>
    let readView: PublishedValue<NodeReadView>
    /// The RPC read surface, over `published` and the view.
    public let reads: ChainReads
    /// Each hosted child level's read surface, over its own published
    /// snapshot and view.
    public let levelReads: [ChainPath: ChainReads]
    /// Each level's published snapshot and view, the root's included.
    let outputs: [ChainPath: LevelOutput]

    struct LevelOutput: Sendable {
        let published: PublishedValue<ChainSnapshot>
        let view: PublishedValue<NodeReadView>
    }
    let configuration: NodeConfiguration
    let inputs: AsyncStream<Input>.Continuation
    private let loop: Task<Void, Never>
    private let ivy: Ivy
    private let delegate: NodeRuntimeIvyDelegate
    private let gate: NodeRuntimeInputGate

    /// How many overlay messages may wait for the loop before a delivering
    /// connection is held back.
    static let networkCapacity = 256

    /// Overlay inputs are bounded by `gate`; every other input is bounded by
    /// the work the core itself issued.
    enum Input: Sendable {
        case network(NodeRuntimeNetworkInput)
        case event(NodeEvent)
        /// A body is held locally, in these Volume roots.
        case bodyStored(ChainPath, cid: String, roots: [String])
        /// A session's hello deadline passed.
        case helloDeadline(peerKey: String, session: UInt64)
        /// A worker finished: its slot frees, then its results step.
        case jobDone([NodeEvent])
        /// An RPC: its mining event under a fresh reply ID.
        case request(ChainPath, @Sendable (UInt64) -> MiningEvent, CheckedContinuation<NodeRuntimeReply, any Error>)
        /// An RPC answered outside a step (the shell could not run its part).
        case answer(UInt64, Result<NodeRuntimeReply, any Error>)
        /// An announced transaction's fetch ended: the transaction, or nil.
        case transactionFetched(cid: String, NodeEvent?)
        case stop
    }

    /// Boot replay, then start the loop and the overlay.
    public static func start(
        storage: NodeStorage,
        configuration: NodeConfiguration,
        overlay: IvyConfig? = nil,
        coreConfig: ChainCoreConfig = ChainCoreConfig(),
        workers: Int = max(1, ProcessInfo.processInfo.activeProcessorCount - 1),
        failStop: @escaping @Sendable (any Error) -> Void = { fatalError("node runtime: persist failed: \($0)") }
    ) async throws -> NodeRuntime {
        let headers = try HeaderContentStore(directory: configuration.storagePath)
        let core = try await boot(storage: storage, configuration: configuration, coreConfig: coreConfig, headers: headers)
        let overlay = try overlay ?? OverlayConfiguration(configuration).overlay
        let runtime = NodeRuntime(
            core: core,
            storage: storage,
            headers: headers,
            configuration: configuration,
            ivy: Ivy(config: overlay),
            helloTimeout: overlay.requestTimeout,
            workers: workers,
            // A store that cannot read its proofs fails the boot: it would
            // serve child headers without them.
            proofs: try headers.proofs(),
            failStop: failStop
        )
        await runtime.ivy.installNodeRuntime(
            delegate: runtime.delegate,
            contentSource: NodeStorageIvyContentSource(storage: storage) { root in
                // A child index travels by CID as its own one-node Volume.
                headers.childIndexBytes(root).map { SerializedVolume(root: root, entries: [root: $0]) }
            }
        )
        // Boot replay of the local journal, each row with its arrival time,
        // into the pool of the chain it names.
        for item in try await storage.localTransactions() {
            let path = item.transaction.body.node?.chainPath ?? core.rootPath
            guard core.levels[path] != nil else { continue }
            runtime.inputs.yield(.event(.level(path, .mining(.transactionReceived(
                item.transaction, origin: .restored(addedAt: item.addedAt * 1_000)
            )))))
        }
        do {
            try await runtime.ivy.start()
        } catch {
            await runtime.stop()
            throw error
        }
        return runtime
    }

    /// Rebuild the core from the durable facts, rooted at the configured
    /// Nexus genesis and nothing else.
    // PENDING #72 (decision 18d): the configured root genesis CID moves into
    // `ChainRuntimeContext`, and Lattice refuses any other root itself.
    ///
    /// The weigh log is derived from the fact log; its id is the one state.db
    /// recorded with its first fact (a fresh store: a new one, recorded with
    /// the first fact it journals).
    // PENDING P4 (one store): `ChainBatch.cursors` are not journaled yet,
    // so a restart reads each peer's log from 0 again (IDs only).
    static func boot(
        storage: NodeStorage,
        configuration: NodeConfiguration,
        coreConfig: ChainCoreConfig,
        headers: HeaderContentStore
    ) async throws -> NodeCore {
        guard configuration.address.isNexus else { throw NodeRuntimeError.notNexus }
        let logID = try await storage.chainLogID() ?? UUID().uuidString.lowercased()
        // The context pins the Nexus genesis: a store holding another root
        // fails the restore.
        let root = try ChainCore.restore(
            replaying: try await storage.chainFacts(),
            context: try configuration.runtimeContext,
            specs: [NexusGenesis.spec],
            config: coreConfig
        )
        let stores = try levelStores(configuration)
        var facts: [ChainPath: [BlockImportBatch]] = [:]
        var specs: [ChainPath: [ChainSpec]] = [:]
        for (path, store) in stores {
            let batches = try await store.stagedImports().map(\.batch)
            facts[path] = batches
            for case .block(let block) in batches.flatMap(\.facts) where block.parentBlockHash == nil {
                guard let spec = try await storage.chainGenesisSpec(block.blockHash, headers: headers) else {
                    throw NodeStorageError.missingMaterializedVolume(block.blockHash)
                }
                specs[path, default: []].append(spec)
            }
        }
        return try NodeCore.restore(
            root: root,
            facts: facts, specs: specs, hosted: Set(stores.keys), config: coreConfig, logID: logID
        )
    }

    /// Each hosted child level's own journal, under `levels/`.
    static func levelStores(_ configuration: NodeConfiguration) throws -> [ChainPath: NodeStore] {
        var stores: [ChainPath: NodeStore] = [:]
        for path in configuration.hostedChildren {
            let directory = configuration.storagePath.appendingPathComponent("levels")
                .appendingPathComponent(path.joined(separator: "."))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            stores[path] = try NodeStore(
                databasePath: directory.appendingPathComponent("state.db"),
                nexusGenesisCID: configuration.nexusGenesisCID,
                chainPath: path
            )
        }
        return stores
    }

    private init(
        core: NodeCore,
        storage: NodeStorage,
        headers: HeaderContentStore,
        configuration: NodeConfiguration,
        ivy: Ivy,
        helloTimeout: Duration,
        workers: Int,
        proofs: [ChainPath: [String: [String: ChildBlockProof]]],
        failStop: @escaping @Sendable (any Error) -> Void
    ) {
        let (stream, inputs) = AsyncStream<Input>.makeStream()
        let published = PublishedValue(core.levels[core.rootPath]?.snapshot)
        let readView = PublishedValue<NodeReadView>()
        self.published = published
        self.readView = readView
        self.configuration = configuration
        reads = Self.reads(storage: storage, configuration: configuration, published: published, view: readView)
        let levelStores = (try? Self.levelStores(configuration)) ?? [:]
        var outputs: [ChainPath: LevelOutput] = [core.rootPath: LevelOutput(published: published, view: readView)]
        var levelReads: [ChainPath: ChainReads] = [:]
        for (path, store) in levelStores {
            let output = LevelOutput(published: PublishedValue(core.levels[path]?.snapshot), view: PublishedValue())
            outputs[path] = output
            levelReads[path] = Self.reads(
                storage: storage, configuration: configuration, published: output.published, view: output.view,
                chainPath: path, accepted: { (try? await store.hasAcceptedBlock($0)) ?? false }
            )
        }
        self.outputs = outputs
        self.levelReads = levelReads
        self.inputs = inputs
        self.ivy = ivy
        let gate = NodeRuntimeInputGate(capacity: Self.networkCapacity)
        self.gate = gate
        delegate = NodeRuntimeIvyDelegate(gate: gate) { inputs.yield(.network($0)) }
        let initial = Loop(
            core: core,
            storage: storage,
            headers: headers,
            ivy: ivy,
            hello: try? ChainHandshake(
                nexusGenesisCID: configuration.nexusGenesisCID,
                chainPath: configuration.chainPath
            ).encode(),
            configuration: configuration,
            outputs: outputs,
            inputs: inputs,
            gate: gate,
            helloTimeout: helloTimeout,
            remote: IvyRootContentSource(ivy: ivy, policy: configuration.resourcePolicy),
            levelStores: levelStores,
            proofs: proofs,
            workers: max(1, workers),
            failStop: failStop
        )
        loop = Task {
            var state = initial
            state.refreshView()
            // After the loop ends, inputs are only drained until the stream
            // finishes, so no RPC waits forever.
            var running = true
            for await input in stream {
                if running {
                    running = await state.handle(input)
                } else if case .request(_, _, let reply) = input {
                    reply.resume(throwing: NodeRuntimeError.stopped)
                }
            }
            state.cancelAll()
        }
    }

    /// Stop the overlay, then the loop; joins both.
    public func stop() async {
        // Free the delegates waiting for room first: stopping Ivy waits for
        // its deliveries.
        await gate.close()
        await ivy.stop()
        await ivy.setContentSource(nil)
        inputs.yield(.stop)
        inputs.finish()
        await loop.value
    }

    static func now() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }
}

extension NodeRuntime {
    /// Everything the loop task owns. Only the loop touches it.
    struct Loop: Sendable {
        var core: NodeCore
        let storage: NodeStorage
        let headers: HeaderContentStore
        let ivy: Ivy
        let hello: Data?
        let configuration: NodeConfiguration
        let outputs: [ChainPath: LevelOutput]
        let inputs: AsyncStream<Input>.Continuation
        let gate: NodeRuntimeInputGate
        let helloTimeout: Duration
        let remote: IvyRootContentSource
        let workers: Int
        let failStop: @Sendable (any Error) -> Void
        /// Each hosted child level's journal.
        let levelStores: [ChainPath: NodeStore]
        /// Each child level's verified proofs, by block and root: what
        /// `lookupProofs` answers and a served child header carries.
        var proofs: [ChainPath: [String: [String: ChildBlockProof]]] = [:]

        /// One overlay session per peer key; the core sees `(key, id)`.
        var sessions: [String: Session] = [:]
        var nextSession: UInt64 = 1
        var runningJobs = 0
        /// Two FIFOs: execution (connect, proof verification) runs before
        /// mining jobs.
        var executionJobs: [RuntimeJob] = []
        var miningJobs: [RuntimeJob] = []
        /// RPCs waiting on their answer, by reply ID.
        var replies: [UInt64: CheckedContinuation<NodeRuntimeReply, any Error>] = [:]
        var nextReply: UInt64 = 1
        /// Announced transactions being fetched, by CID.
        var transactionFetches: Set<String> = []
        /// Transactions recently fetched, not refetched until the act-on tip
        /// moves (Bitcoin's recent rejects): a refused one is not fetched
        /// again in a loop. Bounded, oldest out.
        var recentlyFetched = RecentSet(capacity: 4_096)
        var recentlyFetchedTip: String?
        /// Per level, the chain a tip epoch's jobs read, made once per epoch
        /// that has a job.
        var preflightLevels: [ChainPath: (epoch: UInt64, level: ChainLevel)] = [:]
        var views: [ChainPath: NodeReadView] = [:]


        /// A bounded set, oldest out.
        struct RecentSet {
            let capacity: Int
            private(set) var members: Set<String> = []
            private var order: [String] = []

            init(capacity: Int) { self.capacity = capacity }

            mutating func insert(_ cid: String) {
                guard members.insert(cid).inserted else { return }
                order.append(cid)
                if order.count > capacity { members.remove(order.removeFirst()) }
            }

            mutating func removeAll() {
                members.removeAll()
                order.removeAll()
            }
        }
        var wake: (time: Int64, task: Task<Void, Never>)?
        var bodies: [BodyKey: Task<Void, Never>] = [:]
        /// The Volume roots each fetched body was stored in, until the
        /// validation fact that references them is persisted with them.
        var bodyRoots: [BodyKey: [String]] = [:]

        struct BodyKey: Hashable {
            let path: ChainPath
            let cid: String
        }

        struct Session {
            let peer: AuthenticatedPeer
            let id: UInt64
            var ready = false
            var coreID: LatticeNodeCore.PeerID { .init(key: peer.key.hex, session: id) }
        }

        init(
            core: NodeCore,
            storage: NodeStorage,
            headers: HeaderContentStore,
            ivy: Ivy,
            hello: Data?,
            configuration: NodeConfiguration,
            outputs: [ChainPath: LevelOutput],
            inputs: AsyncStream<Input>.Continuation,
            gate: NodeRuntimeInputGate,
            helloTimeout: Duration,
            remote: IvyRootContentSource,
            levelStores: [ChainPath: NodeStore],
            proofs: [ChainPath: [String: [String: ChildBlockProof]]],
            workers: Int,
            failStop: @escaping @Sendable (any Error) -> Void
        ) {
            self.levelStores = levelStores
            self.proofs = proofs
            self.gate = gate
            self.helloTimeout = helloTimeout
            self.core = core
            self.storage = storage
            self.headers = headers
            self.ivy = ivy
            self.hello = hello
            self.configuration = configuration
            self.outputs = outputs
            self.inputs = inputs
            self.remote = remote
            self.workers = workers
            self.failStop = failStop
        }

        /// Returns false once the loop must end.
        mutating func handle(_ input: Input) async -> Bool {
            switch input {
            case .stop:
                return false
            case .event(let event):
                if case .tick = event { wake = nil }
                return await step(event)
            case .bodyStored(let path, let cid, let roots):
                let key = BodyKey(path: path, cid: cid)
                bodies[key] = nil
                bodyRoots[key] = roots
                return await step(.level(path, .bodyFetched(cid: cid)))
            case .helloDeadline(let key, let id):
                guard let session = sessions[key], session.id == id, !session.ready else { return true }
                sessions[key] = nil
                _ = await ivy.disconnectSession(ifCurrent: session.peer)
                return true
            case .jobDone(let events):
                runningJobs -= 1
                startJobs()
                for event in events {
                    guard await step(event) else { return false }
                }
                return true
            case .network(let network):
                defer { refreshView() }
                let result = await receive(network)
                switch network {
                case .hello, .sync, .transactionAvailable: await gate.release()
                case .connected, .disconnected: break
                }
                return result
            case .request(let path, let event, let reply):
                guard core.levels[path] != nil else {
                    reply.resume(throwing: NodeRuntimeError.unknownChain)
                    return true
                }
                let id = nextReply
                nextReply += 1
                replies[id] = reply
                return await step(.level(path, .mining(event(id))))
            case .answer(let id, let result):
                answer(id, result)
                return true
            case .transactionFetched(let cid, let event):
                transactionFetches.remove(cid)
                recentlyFetched.insert(cid)
                guard let event else { return true }
                return await step(event)
            }
        }

        private mutating func answer(_ id: UInt64, _ result: Result<NodeRuntimeReply, any Error>) {
            replies.removeValue(forKey: id)?.resume(with: result)
        }

        /// Republish the read view when the act-on chain, the pool or the
        /// peers changed: the act-on chain by height (walked down from its
        /// top only as far as it changed), the pool listing and the digest.
        mutating func refreshView() {
            for path in core.levels.keys { refreshView(path) }
        }

        /// One level's read view: its act-on chain by height, pool listing
        /// and template digest.
        mutating func refreshView(_ path: ChainPath) {
            guard let level = core.levels[path], let output = outputs[path] else { return }
            var view = views[path] ?? NodeReadView()
            let snapshot = level.snapshot
            let tip = (hash: snapshot.actOnTip, height: snapshot.actOnHeight)
            let peers = sessions.values.filter(\.ready).count
            let pool = level.mining.mempool
            let digest = path == core.rootPath
                ? NodeRuntime.templateDigest(tip: tip.hash, mempool: pool, levels: core.ordered.dropFirst().compactMap {
                    core.levels[$0].map { ($0.snapshot.actOnTip, $0.snapshot.bestHeaderTip, $0.mining.mempool) }
                })
                : NodeRuntime.templateDigest(tip: tip.hash, mempool: pool)
            guard view.actOnTip != tip.hash || view.poolVersion != pool.version
                    || view.templateDigest != digest || view.peers != peers else { return }
            if view.actOnTip != tip.hash {
                view.actOnTip = tip.hash
                let tree = level.tree
                var keep = min(view.heights.count, tip.hash.isEmpty ? 0 : Int(tip.height) + 1)
                while keep > 0, view.heights[keep - 1] != tree.canonicalBlockHash(atHeight: UInt64(keep - 1)) {
                    keep -= 1
                }
                view.heights.truncate(to: keep)
                var height = UInt64(keep)
                while !tip.hash.isEmpty, height <= tip.height, let cid = tree.canonicalBlockHash(atHeight: height) {
                    view.heights.append(cid)
                    height += 1
                }
            }
            view.poolVersion = pool.version
            view.mempool = ChainReads.MempoolListing(
                count: pool.count, bytes: pool.byteCount, cids: pool.items.prefix(200).map(\.cid)
            )
            // The root's digest covers every hosted level: a child's tip or
            // pool moving changes the template a miner should fetch.
            view.templateDigest = digest
            view.peers = peers
            views[path] = view
            output.view.publish(view)
        }

        // MARK: - Network → events

        private mutating func receive(_ input: NodeRuntimeNetworkInput) async -> Bool {
            switch input {
            case .connected(let peer):
                guard peer.role == .endpoint else {
                    _ = await ivy.disconnectSession(ifCurrent: peer)
                    return true
                }
                let replaced = sessions[peer.key.hex]
                let id = nextSession
                sessions[peer.key.hex] = Session(peer: peer, id: id)
                nextSession += 1
                let (inputs, key) = (inputs, peer.key.hex)
                Timers.deadline(after: helloTimeout, generation: id) { id in
                    inputs.yield(.helloDeadline(peerKey: key, session: id))
                }
                if let hello {
                    _ = await ivy.sendMessage(to: peer, topic: OverlayTopic.overlayHello, payload: hello)
                }
                if let replaced, replaced.ready {
                    return await step(.peerGone(replaced.coreID))
                }
            case .disconnected(let key):
                guard let session = sessions[key],
                      !(await ivy.connectedPeers).contains(session.peer.id) else { return true }
                sessions[key] = nil
                if session.ready { return await step(.peerGone(session.coreID)) }
            case .hello(let peer, let payload):
                guard var session = sessions[peer.key.hex], session.peer.sessionID == peer.sessionID,
                      !session.ready else {
                    return true
                }
                    guard let remote = try? ChainHandshake.decode(payload),
                          (try? remote.validateCompatibility(
                              expectedNexusGenesisCID: configuration.nexusGenesisCID,
                              expectedChainPath: configuration.chainPath
                          )) != nil else {
                        sessions[peer.key.hex] = nil
                        _ = await ivy.disconnectSession(ifCurrent: peer)
                        return true
                    }
                session.ready = true
                sessions[peer.key.hex] = session
                return await step(.peerReady(session.coreID))
            case .sync(let peer, let chainPath, let message):
                guard let session = sessions[peer.key.hex], session.peer.sessionID == peer.sessionID,
                      session.ready else {
                    return true
                }
                return await step(.received(session.coreID, chainPath, message))
            case .transactionAvailable(let peer, let cid):
                guard let session = sessions[peer.key.hex], session.peer.sessionID == peer.sessionID,
                      session.ready else {
                    return true
                }
                fetchAnnounced(cid, from: session)
            }
            return true
        }

        /// A peer announced a transaction: fetch it from that peer, and hand
        /// it to the pool as the peer's. Only one not pooled, not awaiting
        /// its verdict, not being fetched and not recently fetched, within
        /// the cap on concurrent fetches; anything else is dropped, never
        /// blamed.
        private mutating func fetchAnnounced(_ cid: String, from session: Session) {
            guard let mining = core.levels[core.rootPath]?.mining else { return }
            if recentlyFetchedTip != mining.tipCID {
                recentlyFetchedTip = mining.tipCID
                recentlyFetched.removeAll()
            }
            guard !mining.mempool.contains(cid), !mining.isPending(cid),
                  !transactionFetches.contains(cid), !recentlyFetched.members.contains(cid),
                  transactionFetches.count < 64
            else { return }
            transactionFetches.insert(cid)
            let (ivy, inputs, path, peer) = (ivy, inputs, core.rootPath, session.coreID)
            spawn {
                let response = await ivy.fetchVolume(rootCID: cid, from: session.peer)
                let transaction = try? await VolumeImpl<Transaction>(rawCID: cid, node: nil, encryptionInfo: nil)
                    .resolveRecursive(source: InMemoryContentSource(response.entries)).node
                inputs.yield(.transactionFetched(cid: cid, transaction.map {
                    .level(path, .mining(.transactionReceived($0, origin: .peer(peer))))
                }))
            }
        }

        // MARK: - Step and effects

        private mutating func step(_ event: NodeEvent) async -> Bool {
            let effects = core.step(event, now: NodeRuntime.now())
            SyncTrace.log(chain: core.rootPath, "node-runtime step \(String(describing: event).prefix(160)) -> \(effects.map { String(describing: $0).prefix(80) })")
            // Persist, then publish, then everything else, each in order.
            func rank(_ effect: NodeEffect) -> Int {
                switch effect {
                case .persist, .level(_, .mining(.poolChanged)): 0
                case .level(_, .publish): 1
                default: 2
                }
            }
            let ordered = effects.enumerated()
                .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
                .map(\.element)
            for effect in ordered {
                guard await execute(effect) else { return false }
            }
            // A tree copy is kept only for the current epoch's jobs.
            preflightLevels = preflightLevels.filter { core.levels[$0.key]?.mining.tipEpoch == $0.value.epoch }
            refreshView()
            return true
        }

        private mutating func execute(_ effect: NodeEffect) async -> Bool {
            switch effect {
            case .persist(let batch):
                // Parent level before child, each into its own journal
                // (PENDING P4: one transaction across levels). A crash
                // between two writes leaves a child missing facts its parent
                // has, never the reverse: restore takes it as a child that
                // has not heard of them yet, and sync brings them again.
                for (path, levelBatch) in batch.levels.sorted(by: { $0.path.count < $1.path.count }) {
                    // A validated block's body roots are journaled with its
                    // validation, so they stay retained across restarts.
                    let validated = levelBatch.facts.flatMap(\.facts).compactMap { fact -> BodyKey? in
                        guard case .validation(let validation) = fact else { return nil }
                        return BodyKey(path: path, cid: validation.blockHash)
                    }
                    do {
                        try await storage.persistChainBatch(
                            levelBatch,
                            logID: core.logID,
                            headers: headers,
                            bodyRoots: validated.flatMap { bodyRoots[$0] ?? [] },
                            into: path == core.rootPath ? nil : levelStores[path]
                        )
                        for key in validated { bodyRoots[key] = nil }
                    } catch {
                        // Fail-stop: no later effect of this step may run.
                        failStop(error)
                        return false
                    }
                }
            case .level(let path, let effect):
                return await execute(effect, at: path)
            case .disconnect(let peer, _):
                guard let session = session(peer) else { break }
                sessions[peer.key] = nil
                _ = await ivy.disconnectSession(ifCurrent: session.peer)
            case .connect(let path, let job, let parentFacts):
                executionJobs.append(NodeRuntime.connectJob(job, at: path, parentFacts: parentFacts, storage: storage))
                startJobs()
            case .wakeAt(let time):
                if let wake, wake.time <= time { break }
                wake?.task.cancel()
                let inputs = inputs
                wake = (time, Task {
                    let delay = UInt64(max(0, time - NodeRuntime.now()))
                    guard await Timers.sleep(nanoseconds: delay * 1_000_000) else { return }
                    inputs.yield(.event(.tick))
                })
            }
            return true
        }

        private mutating func execute(_ effect: LatticeNodeCore.ChainEffect, at path: ChainPath) async -> Bool {
            switch effect {
            case .persist, .disconnect, .wakeAt, .connect:
                // The host merges these into its own effects.
                break
            case .publish(let snapshot):
                refreshView()
                outputs[path]?.published.publish(snapshot)
            case .send(let peer, let message):
                guard let session = session(peer), let frame = try? ChainSyncWire.encode(message, at: path) else { break }
                _ = await ivy.sendMessage(to: session.peer, topic: frame.topic, payload: frame.payload)
            case .serveHeaders(let peer, let token, let requestID, let blockCIDs, let hasMore):
                guard let session = session(peer) else { break }
                let (storage, headers, ivy, inputs, config) = (storage, headers, ivy, inputs, core.config)
                let proofs = proofs[path] ?? [:]
                spawn {
                    var entries: [HeaderEntry] = []
                    for cid in blockCIDs {
                        guard let stored = await storage.chainHeader(cid, headers: headers) else { continue }
                        let spec = stored.block.parent == nil
                            ? try? await storage.chainGenesisSpec(cid, headers: headers) : nil
                        entries.append(config.entry(
                            stored.block, children: stored.children,
                            proofs: (proofs[cid] ?? [:]).sorted { $0.key < $1.key }.map(\.value), spec: spec ?? nil
                        ))
                    }
                    let page = config.page(entries, hasMore: hasMore)
                    if let frame = try? ChainSyncWire.encode(.headers(HeadersResponse(
                        requestID: requestID, entries: page.entries, hasMore: page.hasMore
                    )), at: path) {
                        _ = await ivy.sendMessage(to: session.peer, topic: frame.topic, payload: frame.payload)
                    }
                    inputs.yield(.event(.level(path, .headersServed(peer, token: token))))
                }
            case .fetchByCID(let peer, let cid):
                guard let session = session(peer) else { break }
                let (headers, ivy, inputs) = (headers, ivy, inputs)
                spawn {
                    let bytes: Data?
                    if let local = headers.childIndexBytes(cid) {
                        bytes = local
                    } else {
                        bytes = await ivy.fetchVolume(rootCID: cid, from: session.peer).entries[cid]
                    }
                    // No answer is no event: the request's deadline decides.
                    guard let bytes, let index = FlatDictionary<BlockHeader>(data: bytes) else { return }
                    inputs.yield(.event(.level(path, .childIndexFetched(peer, cid: cid, index))))
                }
            case .fetchBody(let cid):
                let key = BodyKey(path: path, cid: cid)
                guard bodies[key] == nil else { break }
                let (storage, remote, inputs) = (storage, remote, inputs)
                bodies[key] = Task {
                    // The content layer retries until the body is held or the
                    // core no longer wants it.
                    var backoff: UInt64 = 250
                    while !Task.isCancelled {
                        if let roots = try? await storage.fetchChainBody(cid, remote: remote) {
                            inputs.yield(.bodyStored(path, cid: cid, roots: roots))
                            return
                        }
                        _ = await Timers.sleep(nanoseconds: backoff * 1_000_000)
                        backoff = min(backoff * 2, 30_000)
                    }
                }
            case .cancelBody(let cid):
                bodies.removeValue(forKey: BodyKey(path: path, cid: cid))?.cancel()
                bodyRoots[BodyKey(path: path, cid: cid)] = nil
            case .verifyProof(let job):
                // A job without its block reads it from the header store.
                guard let block = job.block ?? headers.header(job.childCID)?.block else {
                    // Its block is gone: the check frees its slot, blaming no one.
                    inputs.yield(.event(.level(path, .proofDropped(job))))
                    break
                }
                executionJobs.append(RuntimeJob(path: path, epoch: nil) {
                    [.level(path, .proofVerified(job, await job.run(block)))]
                })
                startJobs()
            case .readTransactions(let blocks):
                executionJobs.append(NodeRuntime.readJob(blocks, at: path, storage: storage))
                startJobs()
            case .lookupProofs(let cids):
                let found = cids.compactMap { cid in
                    (proofs[path]?[cid]).map { ($0, cid) }
                }
                for (roots, cid) in found {
                    inputs.yield(.event(.level(path, .proofsFound(
                        childCID: cid, roots.sorted { $0.key < $1.key }.map(\.value)
                    ))))
                }
            case .indexProof(let cid, let proof):
                proofs[path, default: [:]][cid, default: [:]][proof.rootCID] = proof
                do {
                    try headers.storeProof(proof, for: cid, at: path)
                } catch {
                    failStop(error)
                    return false
                }
            case .mining(let effect):
                return await execute(effect, at: path)
            case .workSubmitted(let replyID, let outcome):
                answer(replyID, .success(.work(outcome)))
            }
            return true
        }

        private mutating func execute(_ effect: MiningEffect, at path: ChainPath) async -> Bool {
            switch effect {
            case .poolChanged(let delta):
                do {
                    try await storage.persistPoolDelta(delta)
                } catch {
                    failStop(error)
                    return false
                }
            case .transactionAdmitted(let replyID, let cid, let count, let bytes):
                answer(replyID, .success(.admitted(cid: cid, count: count, bytes: bytes)))
            case .transactionRefused(let replyID, let error):
                answer(replyID, .failure(error))
            case .templateIssued(let replyID, let template):
                answer(replyID, .success(.template(template)))
            case .templateRefused(let replyID, let error), .workRefused(let replyID, let error):
                answer(replyID, .failure(error))
            case .announceTransaction(let cid):
                guard let payload = try? TransactionAvailableMessage(volumeRootCID: cid).encoded() else { break }
                for session in sessions.values.sorted(by: { $0.id < $1.id }) where session.ready {
                    _ = await ivy.sendMessage(
                        to: session.peer, topic: OverlayTopic.transactionAvailable, payload: payload
                    )
                }
            case .mined(let replyID, let block):
                // Content first: the block is stored before the grind's one
                // step weighs it.
                // The carried blocks of hosted levels, each with its proof
                // verified, join the grind: one step weighs every level the
                // grind meets.
                let (storage, inputs) = (storage, inputs)
                let hosted = Set(core.levels.keys)
                spawn {
                    do {
                        let children = try await storage.storeMinedBlock(block)
                        let carried = try await storage.carriedGrinds(of: block, hosted: hosted)
                        inputs.yield(.event(.mined(
                            MinedGrind(root: block, rootChildren: children, carried: carried), replyID: replyID
                        )))
                    } catch {
                        inputs.yield(.answer(replyID, .failure(error)))
                    }
                }
            case .preflight(let job):
                guard let level = await epochLevel(at: path, epoch: job.tipEpoch) else { break }
                miningJobs.append(NodeRuntime.miningJob(effect, at: path, level: level, storage: storage))
                startJobs()
            case .buildTemplate(let job):
                guard let level = await epochLevel(at: path, epoch: job.tipEpoch) else { break }
                miningJobs.append(NodeRuntime.miningJob(
                    effect, at: path, level: level, storage: storage, children: childTemplateInputs(below: path)
                ))
                startJobs()
            case .returnTransactions:
                miningJobs.append(NodeRuntime.miningJob(effect, at: path, level: nil, storage: storage))
                startJobs()
            }
            return true
        }

        /// The chain a tip epoch's jobs read: Lattice's `preflightTransaction`
        /// and the template's difficulty anchor, over a copy of the level's
        /// tree made once per epoch.
        private mutating func epochLevel(at path: ChainPath, epoch: UInt64) async -> ChainLevel? {
            if let cached = preflightLevels[path], cached.epoch == epoch { return cached.level }
            guard let tree = core.levels[path]?.tree, let level = NodeRuntime.jobLevel(tree) else { return nil }
            preflightLevels[path] = (epoch, level)
            return level
        }

        private func anchor(_ tree: ChainTree, _ tip: String) -> DifficultyAnchor? {
            var tree = tree
            return tree.difficultyAnchor(forBlockHash: tip)
        }

        /// Every hosted level below `path`, as a template job reads it.
        func childTemplateInputs(below path: ChainPath) -> [ChildTemplateInput] {
            core.ordered.filter { $0.count > path.count && $0.starts(with: path) }.compactMap { child -> ChildTemplateInput? in
                guard let level = core.levels[child] else { return nil }
                let snapshot = level.snapshot
                let executed = !snapshot.actOnTip.isEmpty
                return ChildTemplateInput(
                    path: child,
                    tipCID: executed ? snapshot.actOnTip : nil,
                    bestHeaderTip: snapshot.bestHeaderTip,
                    transactions: level.mining.mempool.transactions(limit: .max),
                    anchor: executed ? anchor(level.tree, snapshot.actOnTip) : nil,
                    // A weighed root that has not executed carries nothing
                    // until it executes, rather than a rival genesis.
                    genesisSpec: snapshot.bestHeaderTip.isEmpty ? configuration.childSpecs[child] : nil,
                    genesisTarget: .max
                )
            }
        }

        /// The live, ready session the core's peer names.
        private func session(_ peer: LatticeNodeCore.PeerID) -> Session? {
            guard let session = sessions[peer.key], session.id == peer.session, session.ready else { return nil }
            return session
        }

        /// The worker pool: at most `workers` jobs run; each result posts
        /// back as an event that frees its slot.
        private mutating func startJobs() {
            while runningJobs < workers, !executionJobs.isEmpty || !miningJobs.isEmpty {
                let job = executionJobs.isEmpty ? miningJobs.removeFirst() : executionJobs.removeFirst()
                guard job.isCurrent(in: core) else { continue }
                runningJobs += 1
                let inputs = inputs
                spawn { inputs.yield(.jobDone(await job.run())) }
            }
        }

        /// ChainEffect work off the loop: it only posts events back, and a post
        /// after the loop ended is dropped.
        private func spawn(_ work: @escaping @Sendable () async -> Void) {
            Task { await work() }
        }

        mutating func cancelAll() {
            for reply in replies.values { reply.resume(throwing: NodeRuntimeError.stopped) }
            replies.removeAll()
            wake?.task.cancel()
            for task in bodies.values { task.cancel() }
            bodies.removeAll()
        }
    }
}
