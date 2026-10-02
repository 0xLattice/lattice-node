import Foundation
import Ivy
import Lattice
import LatticeNodeCore
import cashew

public enum CoreDriverError: Error, Equatable, Sendable {
    /// The driver hosts the Nexus level only.
    case notNexus
    /// The driver stopped before answering.
    case stopped
}

/// The production shell around the sans-IO `LatticeNodeCore.HostCore`
/// (behind `--core-driver`; it hosts the Nexus level only for now). It is
/// plumbing: one serial task owns the host core, drains one event channel (network messages, content arrivals, job
/// results, timers), calls `step(event, now)` and executes the effects in
/// order — persist, then publish, then everything else. Every decision is
/// the core's.
///
/// - `persist` (one `HostBatch`) → the opened `ChainProcess`'s Volume store and state.db
///   (content fsynced first, then the facts in one transaction). A failure
///   stops the process: restart replays the journal.
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
public final class CoreDriver: Sendable {
    public let published: PublishedValue<Snapshot>
    let readView: PublishedValue<CoreReadView>
    /// The RPC read surface, over `published` and the view.
    public let reads: ChainReads
    let configuration: NodeConfiguration
    let inputs: AsyncStream<Input>.Continuation
    private let loop: Task<Void, Never>
    private let ivy: Ivy
    private let delegate: CoreDriverIvyDelegate
    private let gate: CoreDriverInputGate

    /// How many overlay messages may wait for the loop before a delivering
    /// connection is held back.
    static let networkCapacity = 256

    /// Overlay inputs are bounded by `gate`; every other input is bounded by
    /// the work the core itself issued.
    enum Input: Sendable {
        case network(CoreDriverNetworkInput)
        case event(HostEvent)
        /// A body is held locally, in these Volume roots.
        case bodyStored(ChainPath, cid: String, roots: [String])
        /// A session's hello deadline passed.
        case helloDeadline(peerKey: String, session: UInt64)
        /// A worker finished: its slot frees, then its results step.
        case jobDone([HostEvent])
        /// An RPC: its mining event under a fresh reply ID.
        case request(@Sendable (UInt64) -> MiningEvent, CheckedContinuation<CoreReply, any Error>)
        /// An RPC answered outside a step (the shell could not run its part).
        case answer(UInt64, Result<CoreReply, any Error>)
        /// An announced transaction's fetch ended: the transaction, or nil.
        case transactionFetched(cid: String, HostEvent?)
        case stop
    }

    /// Boot replay, then start the loop and the overlay.
    public static func start(
        process: ChainProcess,
        configuration: NodeConfiguration,
        overlay: IvyConfig? = nil,
        coreConfig: CoreConfig = CoreConfig(),
        workers: Int = max(1, ProcessInfo.processInfo.activeProcessorCount - 1),
        failStop: @escaping @Sendable (any Error) -> Void = { fatalError("core driver: persist failed: \($0)") }
    ) async throws -> CoreDriver {
        let headers = try CoreHeaderStore(directory: configuration.storagePath)
        let core = try await boot(process: process, configuration: configuration, coreConfig: coreConfig, headers: headers)
        let overlay = try overlay ?? NodeNetworkPlaneConfigurations(configuration).overlay
        let driver = CoreDriver(
            core: core,
            process: process,
            headers: headers,
            configuration: configuration,
            ivy: Ivy(config: overlay),
            helloTimeout: overlay.requestTimeout,
            workers: workers,
            failStop: failStop
        )
        await driver.ivy.installCoreDriver(
            delegate: driver.delegate,
            contentSource: ChainProcessIvyContentSource(process: process) { root in
                // A child index travels by CID as its own one-node Volume.
                headers.childIndexBytes(root).map { SerializedVolume(root: root, entries: [root: $0]) }
            }
        )
        // Boot replay of the local journal, each row with its arrival time.
        for item in try await process.localTransactions() {
            driver.inputs.yield(.event(.level(core.rootPath, .mining(.transactionReceived(
                item.transaction, origin: .restored(addedAt: item.addedAt * 1_000)
            )))))
        }
        do {
            try await driver.ivy.start()
        } catch {
            await driver.stop()
            throw error
        }
        return driver
    }

    /// Rebuild the core from the durable facts, rooted at the configured
    /// Nexus genesis and nothing else.
    // PENDING #72 (decision 18d): the configured root genesis CID moves into
    // `ChainRuntimeContext`, and Lattice refuses any other root itself.
    ///
    /// The weigh log is derived from the fact log; its id is the one state.db
    /// recorded with its first fact (a fresh store: a new one, recorded with
    /// the first fact it journals).
    // PENDING P4 (one store): `PersistBatch.cursors` are not journaled yet,
    // so a restart reads each peer's log from 0 again (IDs only).
    static func boot(
        process: ChainProcess,
        configuration: NodeConfiguration,
        coreConfig: CoreConfig,
        headers: CoreHeaderStore
    ) async throws -> HostCore {
        guard configuration.address.isNexus else { throw CoreDriverError.notNexus }
        let logID = try await process.coreLogID() ?? UUID().uuidString.lowercased()
        // The context pins the Nexus genesis: a store holding another root
        // fails the restore.
        let root = try Core.restore(
            replaying: try await process.coreFacts(),
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
                guard let spec = try await process.coreGenesisSpec(block.blockHash, headers: headers) else {
                    throw ChainProcessError.missingMaterializedVolume(block.blockHash)
                }
                specs[path, default: []].append(spec)
            }
        }
        return try HostCore.restore(
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
        core: HostCore,
        process: ChainProcess,
        headers: CoreHeaderStore,
        configuration: NodeConfiguration,
        ivy: Ivy,
        helloTimeout: Duration,
        workers: Int,
        failStop: @escaping @Sendable (any Error) -> Void
    ) {
        let (stream, inputs) = AsyncStream<Input>.makeStream()
        let published = PublishedValue(core.levels[core.rootPath]?.snapshot)
        let readView = PublishedValue<CoreReadView>()
        self.published = published
        self.readView = readView
        self.configuration = configuration
        reads = Self.reads(process: process, configuration: configuration, published: published, view: readView)
        self.inputs = inputs
        self.ivy = ivy
        let gate = CoreDriverInputGate(capacity: Self.networkCapacity)
        self.gate = gate
        delegate = CoreDriverIvyDelegate(gate: gate) { inputs.yield(.network($0)) }
        let initial = Loop(
            core: core,
            process: process,
            headers: headers,
            ivy: ivy,
            hello: try? ChainHello(
                nexusGenesisCID: configuration.nexusGenesisCID,
                chainPath: configuration.chainPath
            ).encode(),
            configuration: configuration,
            published: published,
            readView: readView,
            inputs: inputs,
            gate: gate,
            helloTimeout: helloTimeout,
            remote: IvyRootContentSource(ivy: ivy, policy: configuration.resourcePolicy),
            levelStores: (try? Self.levelStores(configuration)) ?? [:],
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
                } else if case .request(_, let reply) = input {
                    reply.resume(throwing: CoreDriverError.stopped)
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

extension CoreDriver {
    /// Everything the loop task owns. Only the loop touches it.
    struct Loop: Sendable {
        var core: HostCore
        let process: ChainProcess
        let headers: CoreHeaderStore
        let ivy: Ivy
        let hello: Data?
        let configuration: NodeConfiguration
        let published: PublishedValue<Snapshot>
        let readView: PublishedValue<CoreReadView>
        let inputs: AsyncStream<Input>.Continuation
        let gate: CoreDriverInputGate
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
        var executionJobs: [CoreJob] = []
        var miningJobs: [CoreJob] = []
        /// RPCs waiting on their answer, by reply ID.
        var replies: [UInt64: CheckedContinuation<CoreReply, any Error>] = [:]
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
        var view = CoreReadView()


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
            core: HostCore,
            process: ChainProcess,
            headers: CoreHeaderStore,
            ivy: Ivy,
            hello: Data?,
            configuration: NodeConfiguration,
            published: PublishedValue<Snapshot>,
            readView: PublishedValue<CoreReadView>,
            inputs: AsyncStream<Input>.Continuation,
            gate: CoreDriverInputGate,
            helloTimeout: Duration,
            remote: IvyRootContentSource,
            levelStores: [ChainPath: NodeStore],
            workers: Int,
            failStop: @escaping @Sendable (any Error) -> Void
        ) {
            self.levelStores = levelStores
            self.gate = gate
            self.helloTimeout = helloTimeout
            self.core = core
            self.process = process
            self.headers = headers
            self.ivy = ivy
            self.hello = hello
            self.configuration = configuration
            self.published = published
            self.readView = readView
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
            case .request(let event, let reply):
                let id = nextReply
                nextReply += 1
                replies[id] = reply
                return await step(.level(core.rootPath, .mining(event(id))))
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

        private mutating func answer(_ id: UInt64, _ result: Result<CoreReply, any Error>) {
            replies.removeValue(forKey: id)?.resume(with: result)
        }

        /// Republish the read view when the act-on chain, the pool or the
        /// peers changed: the act-on chain by height (walked down from its
        /// top only as far as it changed), the pool listing and the digest.
        mutating func refreshView() {
            guard let level = core.levels[core.rootPath] else { return }
            let snapshot = level.snapshot
            let tip = (hash: snapshot.actOnTip, height: snapshot.actOnHeight)
            let peers = sessions.values.filter(\.ready).count
            let pool = level.mining.mempool
            guard view.actOnTip != tip.hash || view.poolVersion != pool.version || view.peers != peers else { return }
            if view.actOnTip != tip.hash {
                view.actOnTip = tip.hash
                let tree = level.tree
                var keep = min(view.heights.count, Int(tip.height) + 1)
                while keep > 0, view.heights[keep - 1] != tree.canonicalBlockHash(atHeight: UInt64(keep - 1)) {
                    keep -= 1
                }
                view.heights.truncate(to: keep)
                var height = UInt64(keep)
                while height <= tip.height, let cid = tree.canonicalBlockHash(atHeight: height) {
                    view.heights.append(cid)
                    height += 1
                }
            }
            view.poolVersion = pool.version
            view.mempool = ChainReads.MempoolListing(
                count: pool.count, bytes: pool.byteCount, cids: pool.items.prefix(200).map(\.cid)
            )
            view.templateDigest = CoreDriver.templateDigest(tip: tip.hash, mempool: pool)
            view.peers = peers
            readView.publish(view)
        }

        // MARK: - Network → events

        private mutating func receive(_ input: CoreDriverNetworkInput) async -> Bool {
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
                    _ = await ivy.sendMessage(to: peer, topic: NodeNetworkTopic.overlayHello, payload: hello)
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
                    guard let remote = try? ChainHello.decode(payload),
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

        private mutating func step(_ event: HostEvent) async -> Bool {
            let effects = core.step(event, now: CoreDriver.now())
            SyncTrace.log(chain: core.rootPath, "core-driver step \(String(describing: event).prefix(160)) -> \(effects.map { String(describing: $0).prefix(80) })")
            // Persist, then publish, then everything else, each in order.
            func rank(_ effect: HostEffect) -> Int {
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

        private mutating func execute(_ effect: HostEffect) async -> Bool {
            switch effect {
            case .persist(let batch):
                // Root level first, then each child level into its own
                // journal (PENDING P4: one transaction across levels).
                for (path, levelBatch) in batch.levels {
                    // A validated block's body roots are journaled with its
                    // validation, so they stay retained across restarts.
                    let validated = levelBatch.facts.flatMap(\.facts).compactMap { fact -> BodyKey? in
                        guard case .validation(let validation) = fact else { return nil }
                        return BodyKey(path: path, cid: validation.blockHash)
                    }
                    do {
                        try await process.persistCoreBatch(
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
                executionJobs.append(CoreDriver.connectJob(job, at: path, parentFacts: parentFacts, process: process))
                startJobs()
            case .wakeAt(let time):
                if let wake, wake.time <= time { break }
                wake?.task.cancel()
                let inputs = inputs
                wake = (time, Task {
                    let delay = UInt64(max(0, time - CoreDriver.now()))
                    guard await Timers.sleep(nanoseconds: delay * 1_000_000) else { return }
                    inputs.yield(.event(.tick))
                })
            }
            return true
        }

        private mutating func execute(_ effect: LatticeNodeCore.Effect, at path: ChainPath) async -> Bool {
            switch effect {
            case .persist, .disconnect, .wakeAt, .connect:
                // The host merges these into its own effects.
                break
            case .publish(let snapshot):
                if path == core.rootPath {
                    refreshView()
                    published.publish(snapshot)
                }
            case .send(let peer, let message):
                guard let session = session(peer), let frame = try? CoreWire.encode(message, at: path) else { break }
                _ = await ivy.sendMessage(to: session.peer, topic: frame.topic, payload: frame.payload)
            case .serveHeaders(let peer, let token, let requestID, let blockCIDs, let hasMore):
                guard let session = session(peer) else { break }
                let (process, headers, ivy, inputs, config) = (process, headers, ivy, inputs, core.config)
                let proofs = proofs[path] ?? [:]
                spawn {
                    var entries: [HeaderEntry] = []
                    for cid in blockCIDs {
                        guard let stored = await process.coreHeader(cid, headers: headers) else { continue }
                        let spec = stored.block.parent == nil
                            ? try? await process.coreGenesisSpec(cid, headers: headers) : nil
                        entries.append(config.entry(
                            stored.block, children: stored.children,
                            proofs: (proofs[cid] ?? [:]).sorted { $0.key < $1.key }.map(\.value), spec: spec ?? nil
                        ))
                    }
                    let page = config.page(entries, hasMore: hasMore)
                    if let frame = try? CoreWire.encode(.headers(HeadersResponse(
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
                let (process, remote, inputs) = (process, remote, inputs)
                bodies[key] = Task {
                    // The content layer retries until the body is held or the
                    // core no longer wants it.
                    var backoff: UInt64 = 250
                    while !Task.isCancelled {
                        if let roots = try? await process.fetchCoreBody(cid, remote: remote) {
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
                executionJobs.append(CoreJob(path: path, epoch: nil) {
                    [.level(path, .proofVerified(job, await job.run(block)))]
                })
                startJobs()
            case .readTransactions(let blocks):
                executionJobs.append(CoreDriver.readJob(blocks, at: path, process: process))
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
                    try await process.persistPoolDelta(delta)
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
                        to: session.peer, topic: NodeNetworkTopic.transactionAvailable, payload: payload
                    )
                }
            case .mined(let replyID, let block):
                // Content first: the block is stored before the grind's one
                // step weighs it.
                // PENDING (child levels): the carried blocks of hosted
                // levels, each with its proof verified, join the grind.
                let (process, inputs) = (process, inputs)
                spawn {
                    do {
                        let children = try await process.storeMinedBlock(block)
                        inputs.yield(.event(.mined(
                            MinedGrind(root: block, rootChildren: children, carried: []), replyID: replyID
                        )))
                    } catch {
                        inputs.yield(.answer(replyID, .failure(error)))
                    }
                }
            case .preflight(let job):
                guard let level = await epochLevel(at: path, epoch: job.tipEpoch) else { break }
                miningJobs.append(CoreDriver.miningJob(effect, at: path, level: level, process: process))
                startJobs()
            case .buildTemplate(let job):
                guard let level = await epochLevel(at: path, epoch: job.tipEpoch) else { break }
                miningJobs.append(CoreDriver.miningJob(effect, at: path, level: level, process: process))
                startJobs()
            case .returnTransactions:
                miningJobs.append(CoreDriver.miningJob(effect, at: path, level: nil, process: process))
                startJobs()
            }
            return true
        }

        /// The chain a tip epoch's jobs read: Lattice's `preflightTransaction`
        /// and the template's difficulty anchor, over a copy of the level's
        /// tree made once per epoch.
        private mutating func epochLevel(at path: ChainPath, epoch: UInt64) async -> ChainLevel? {
            if let cached = preflightLevels[path], cached.epoch == epoch { return cached.level }
            guard let tree = core.levels[path]?.tree, let level = CoreDriver.jobLevel(tree) else { return nil }
            preflightLevels[path] = (epoch, level)
            return level
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

        /// Effect work off the loop: it only posts events back, and a post
        /// after the loop ended is dropped.
        private func spawn(_ work: @escaping @Sendable () async -> Void) {
            Task { await work() }
        }

        mutating func cancelAll() {
            for reply in replies.values { reply.resume(throwing: CoreDriverError.stopped) }
            replies.removeAll()
            wake?.task.cancel()
            for task in bodies.values { task.cancel() }
            bodies.removeAll()
        }
    }
}
