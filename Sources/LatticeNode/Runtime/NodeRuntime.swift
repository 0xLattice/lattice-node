import Foundation
import Ivy
import IvyWebSocket
import Lattice
import LatticeNodeAPI
import LatticeNodeCore
import Synchronization
import cashew

public enum NodeRuntimeError: Error, Equatable, Sendable {
    /// The configured root is not Nexus.
    case notNexus
    /// The runtime stopped before answering.
    case stopped
    /// A request names a chain this node does not host.
    case unknownChain
    /// This node's content budget is full for now; asking again may work.
    case busy
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
/// - `connect` / `verifyProofs` → a bounded worker pool; the result comes
///   back as an event.
/// - `wakeAt` → one timer that posts `tick`.
/// - `mining` → the pool delta persisted like `persist` (fail-stop), RPC
///   replies answered by reply ID, announces to every ready peer, and the
///   preflight and template jobs on the worker pool (a recheck whose tip is
///   no longer the mining tip when it starts runs nothing).
///
/// RPC writes (`submitTransaction`, `miningTemplate`, `submitWork`) are
/// mining events with reply IDs, one per RPC in flight; RPC reads
/// (`reads`) come from the published snapshot and view, never the loop.
///
/// Network and fetch effects spawn tasks that only post events back, so no
/// suspension ever interleaves two steps.
/// Child levels are journaled with Nexus in the one hosted-tree fact store,
/// their verified proofs with the work facts they produced, for lookup and
/// serving across restarts.
/// How the overlay closes a session the core disconnects. A stalled peer is
/// not to blame and may come back at once (`DisconnectReason.stalled`), so
/// its session is recycled: a configured peer is re-dialled on the overlay's
/// backoff. A peer that sent invalid proof of work is closed for good.
enum SessionClose: Equatable {
    case recycle
    case close

    init(_ reason: DisconnectReason) {
        switch reason {
        case .stalled: self = .recycle
        case .proofOfWorkInvalid: self = .close
        }
    }
}

public final class NodeRuntime: Sendable {
    public let published: PublishedValue<ChainSnapshot>
    let readView: PublishedValue<NodeReadView>
    /// The root's template digest, published as it changes: see
    /// `miningEvents()`.
    let templateDigest: PublishedValue<String>
    /// The RPC read surface, over `published` and the view.
    public let reads: ChainReads
    /// Each hosted child level's read surface, over its own published
    /// snapshot and view.
    public var levelReads: [ChainPath: ChainReads] { publishedLevelReads.value ?? [:] }
    let publishedLevelReads: PublishedValue<[ChainPath: ChainReads]>

    struct LevelOutput: Sendable {
        let published: PublishedValue<ChainSnapshot>
        let view: PublishedValue<NodeReadView>
    }
    let configuration: NodeConfiguration
    let storage: NodeStorage
    /// What the open sessions' hellos advertised, as the content layer reads it.
    let peerCapabilities: PeerCapabilities
    let inputs: Inputs
    private let loop: Task<Void, Never>
    let ivy: Ivy
    /// Moves a peer met through another peer onto a connection of its own.
    private let punch: PunchConnector
    /// Listens for browsers; see `WebSocketListener`.
    private let webSocket: WebSocketTransport
    private let delegate: NodeRuntimeIvyDelegate
    private let gate: NodeRuntimeInputGate
    /// Cancelled first when the runtime stops.
    let maintenanceTimer: Task<Void, Never>
    /// Read URLs other hosts declare, found through their provider records.
    let readEndpoints: ReadEndpointDirectory
    /// The peers remembered across restarts; nil for a node told to connect
    /// to no one, which neither remembers nor redials anyone.
    let peerMemory: PeerMemory?
    /// Each peer's serving standing, kept across restarts.
    public let servingLedger: ServingLedger

    /// How many overlay messages may wait for the loop before a delivering
    /// connection is held back.
    static let networkCapacity = 256

    /// Overlay inputs are bounded by `gate`; every other input is bounded by
    /// the work the core itself issued.
    enum Input: Sendable {
        case network(NodeRuntimeNetworkInput)
        case event(NodeEvent)
        /// A body is held locally; when it was asked for and held, while
        /// tracing.
        case bodyStored(ChainPath, cid: String, asked: Double, held: Double)
        /// A body's fetch failed: why, and the error for the log. The core
        /// asks for it again after its backoff.
        case bodyWaiting(ChainPath, cid: String, BodyWait, detail: String)
        /// A session's hello deadline passed.
        case helloDeadline(peerKey: String, session: UInt64)
        /// A worker finished: its slot frees, then its results step. When it
        /// was queued, started and done, while tracing.
        case jobDone(UInt64, [NodeEvent], TraceTimes?)
        /// An RPC: its mining event under a fresh reply ID.
        case request(ChainPath, @Sendable (UInt64) -> MiningEvent, CheckedContinuation<NodeRuntimeReply, any Error>)
        /// An RPC answered outside a step (the shell could not run its part).
        case answer(UInt64, Result<NodeRuntimeReply, any Error>)
        /// An announced transaction's fetch ended: the transaction, or nil.
        case transactionFetched(cid: String, NodeEvent?)
        /// Periodic provider announcement and stalled-peer search.
        case maintenance
        /// The network I/O started by a maintenance turn ended.
        case maintenanceFinished
        /// Each hosted chain's current peers, by key, as a maintenance pass
        /// counted them.
        case currentPeers([ChainPath: Set<String>])
        /// The operator changed the chains this node hosts: the hosted
        /// children of this configuration, and what goes with them.
        case host(NodeConfiguration, CheckedContinuation<Void, any Error>)
        /// A level's throttled fee projection is due.
        case reproject(ChainPath)
        /// A state sync or a heal of a chain's counts (`repair` names it)
        /// ended.
        case counted(ChainPath, repair: UInt64, CountedRepair)
        /// A job's read of the live levels (`LiveLevels`).
        case read(@Sendable ([ChainPath: ChainCore]?) -> Void)
        case stop
    }

    /// The loop's inputs. While tracing, they count how many wait for the
    /// loop, which each step's line reads.
    struct Inputs: Sendable {
        final class Waiting: Sendable {
            let count = Atomic<Int>(0)
        }

        let continuation: AsyncStream<Input>.Continuation
        let waiting = Waiting()

        @discardableResult
        func yield(_ input: Input) -> AsyncStream<Input>.Continuation.YieldResult {
            if SyncTrace.enabled { waiting.count.add(1, ordering: .relaxed) }
            return continuation.yield(input)
        }

        func finish() { continuation.finish() }

        /// The loop took an input.
        func taken() {
            if SyncTrace.enabled { waiting.count.subtract(1, ordering: .relaxed) }
        }

        var depth: Int { waiting.count.load(ordering: .relaxed) }
    }

    /// Boot replay, then start the loop and the overlay.
    public static func start(
        storage: NodeStorage,
        configuration: NodeConfiguration,
        overlay: IvyConfig? = nil,
        coreConfig: ChainCoreConfig = ChainCoreConfig(),
        workers: Int = max(1, ProcessInfo.processInfo.activeProcessorCount - 1),
        // Fail-stop is for local storage failure only: everything a step
        // persists is validated by the core, so peer input cannot reach it.
        failStop: @escaping @Sendable (any Error) -> Void = { fatalError("node runtime: persist failed: \($0)") }
    ) async throws -> NodeRuntime {
        try await start(
            storage: storage, configuration: configuration, overlay: overlay, coreConfig: coreConfig,
            workers: workers, failStop: failStop, observeJob: nil
        )
    }

    /// What a test sees of each job, awaited on its worker before it runs:
    /// its queue class, its level and, for a mining job, its effect.
    typealias JobObserver = @Sendable (RuntimeJob.Kind, ChainPath, MiningEffect?) async -> Void

    /// `start`, with `observeJob` awaited on each job's worker before the
    /// job runs (a test's view of the worker pool).
    static func start(
        storage: NodeStorage,
        configuration: NodeConfiguration,
        overlay: IvyConfig? = nil,
        coreConfig: ChainCoreConfig = ChainCoreConfig(),
        workers: Int = max(1, ProcessInfo.processInfo.activeProcessorCount - 1),
        failStop: @escaping @Sendable (any Error) -> Void = { fatalError("node runtime: persist failed: \($0)") },
        observeJob: JobObserver?
    ) async throws -> NodeRuntime {
        let started = ContinuousClock.now
        var coreConfig = coreConfig
        coreConfig.mining.mempool.minRelayFee = configuration.minRelayFee
        coreConfig.finality = configuration.finality
        let core = try await boot(
            storage: storage, configuration: configuration,
            coreConfig: coreConfig
        )
        let overlay = try overlay ?? OverlayConfiguration(configuration).overlay
        // What the journal replay below reads of the core, which the runtime
        // takes over.
        let (rootPath, levels) = (core.rootPath, Set(core.levels.keys))
        // Standings restored before the overlay serves anyone.
        let ivy = Ivy(config: overlay)
        let servingLedger = try ServingLedger(directory: configuration.storagePath, tally: await ivy.tally)
        let runtime = NodeRuntime(
            core: consume core,
            storage: storage,
            configuration: configuration,
            ivy: ivy,
            servingLedger: servingLedger,
            overlayPeers: overlay.bootstrapPeers,
            relays: overlay.relayEnabled,
            helloTimeout: overlay.requestTimeout,
            workers: workers,
            failStop: failStop,
            observeJob: observeJob
        )
        await runtime.ivy.installNodeRuntime(
            delegate: runtime.punch,
            contentSource: NodeStorageIvyContentSource(storage: storage) { root in
                // A child index travels by CID as its own one-node Volume.
                storage.store.childIndexBytes(root).map { SerializedVolume(root: root, entries: [root: $0]) }
            }
        )
        // Boot replay of the local journal, each row with its arrival time,
        // into the pool of the chain it names.
        for item in try await storage.localTransactions() {
            let path = item.transaction.body.node?.chainPath ?? rootPath
            guard levels.contains(path) else { continue }
            runtime.inputs.yield(.event(.level(path, .mining(.transactionReceived(
                item.transaction, origin: .restored(addedAt: item.addedAt * 1_000)
            )))))
        }
        do {
            try await runtime.ivy.start()
            switch configuration.webSocket {
            case .off:
                break
            case .required(let port):
                try await runtime.webSocket.listen(port: port)
            case .ifAvailable(let port):
                do {
                    try await runtime.webSocket.listen(port: port)
                } catch {
                    logLine("lattice-node: not listening for WebSocket and STUN on port \(port): \(error)")
                }
            }
        } catch {
            await runtime.stop()
            throw error
        }
        // The first maintenance pass, once the overlay is up: where a node
        // dials the peers it remembers, and its seeds if those are not enough
        // (the overlay itself dials only configured peers).
        runtime.inputs.yield(.maintenance)
        logLine("lattice-node: runtime started in \(seconds(started.duration(to: .now)))")
        return runtime
    }

    /// Rebuild the core from the durable facts, rooted at the configured
    /// Nexus genesis and nothing else.
    /// The weigh log is derived from the fact log; its id is the one state.db
    /// recorded with its first fact (a fresh store: a new one, recorded with
    /// the first fact it journals).
    static func boot(
        storage: NodeStorage,
        configuration: NodeConfiguration,
        coreConfig: ChainCoreConfig
    ) async throws -> NodeCore {
        guard configuration.address.isNexus else { throw NodeRuntimeError.notNexus }
        var coreConfig = coreConfig
        coreConfig.connectBatch = configuration.connectBatch
        let logID = try await storage.chainLogID() ?? UUID().uuidString.lowercased()
        var cursors: [ChainPath: [String: StreamCursor]] = [:]
        for path in [configuration.chainPath] + configuration.hostedChildren {
            cursors[path] = try await storage.chainCursors(at: path)
        }
        // One line per level once it is restored: its journal read, then
        // its restore, which ends when the next level's read starts.
        var level: (path: ChainPath, batches: Int, facts: Int, read: Duration, readEnd: ContinuousClock.Instant)
        func logRestored() {
            logLine(
                "lattice-node: boot: \(level.path.joined(separator: "/")): \(level.batches) batches, \(level.facts) facts:"
                    + " read \(seconds(level.read)), restore \(seconds(level.readEnd.duration(to: .now)))"
            )
        }
        var started = ContinuousClock.now
        let rootFacts = try await storage.nodeFacts(at: configuration.chainPath)
        level = (
            configuration.chainPath, Int(rootFacts.batches), rootFacts.facts.count,
            started.duration(to: .now), .now
        )
        // The context pins the Nexus genesis: a store holding another root
        // fails the restore.
        let root = try ChainCore.restore(
            consume rootFacts,
            context: try configuration.runtimeContext,
            specs: [NexusGenesis.spec],
            config: coreConfig,
            cursors: cursors[configuration.chainPath] ?? [:]
        )
        // One hosted level's journal read at a time, and only a hosted
        // level's: each is dropped once its level is restored.
        let core = try await NodeCore.restore(
            root: consume root, hosted: Set(configuration.hostedChildren), config: coreConfig,
            logID: logID, cursors: cursors
        ) { path in
            logRestored()
            started = .now
            let facts = try await storage.nodeFacts(at: path)
            var specs: [ChainSpec] = []
            for case .block(let block) in facts.facts where block.parentBlockHash == nil {
                guard let spec = try await storage.chainGenesisSpec(block.blockHash) else {
                    throw NodeStorageError.missingMaterializedVolume(block.blockHash)
                }
                specs.append(spec)
            }
            level = (path, Int(facts.batches), facts.facts.count, started.duration(to: .now), .now)
            return (facts, specs)
        }
        logRestored()
        return core
    }

    private init(
        core: consuming NodeCore,
        storage: NodeStorage,
        configuration: NodeConfiguration,
        ivy: Ivy,
        servingLedger: ServingLedger,
        overlayPeers: [PeerEndpoint],
        relays: Bool,
        helloTimeout: Duration,
        workers: Int,
        failStop: @escaping @Sendable (any Error) -> Void,
        observeJob: JobObserver?
    ) {
        let (stream, continuation) = AsyncStream<Input>.makeStream()
        let inputs = Inputs(continuation: continuation)
        let published = PublishedValue(core.levels[core.rootPath]?.snapshot)
        let readView = PublishedValue<NodeReadView>()
        self.published = published
        self.readView = readView
        let templateDigest = PublishedValue<String>()
        self.templateDigest = templateDigest
        self.configuration = configuration
        self.storage = storage
        let remote = IvyRootContentSource(ivy: ivy, policy: configuration.resourcePolicy)
        reads = Self.reads(
            storage: storage, remote: remote, configuration: configuration, published: published, view: readView
        )
        var outputs: [ChainPath: LevelOutput] = [core.rootPath: LevelOutput(published: published, view: readView)]
        var levelReads: [ChainPath: ChainReads] = [:]
        for path in core.ordered where path != core.rootPath {
            let output = LevelOutput(published: PublishedValue(core.levels[path]?.snapshot), view: PublishedValue())
            outputs[path] = output
            levelReads[path] = Self.reads(
                storage: storage, remote: remote, configuration: configuration, published: output.published, view: output.view,
                chainPath: path,
                accepted: { await storage.hasAcceptedBlock($0, at: path) }
            )
        }
        let publishedLevelReads = PublishedValue(levelReads)
        self.publishedLevelReads = publishedLevelReads
        self.inputs = inputs
        self.ivy = ivy
        self.servingLedger = servingLedger
        webSocket = WebSocketTransport(ivy: ivy)
        let gate = NodeRuntimeInputGate(capacity: Self.networkCapacity)
        self.gate = gate
        let readEndpoints = ReadEndpointDirectory(
            // A configured peer is never closed by a lookup.
            transport: .overlay(ivy, keep: Set(configuration.bootstrapPeers.compactMap {
                (try? PeerKey($0.publicKey))?.hex
            })),
            nexusGenesisCID: configuration.nexusGenesisCID,
            ownKey: configuration.processPublicKey
        )
        self.readEndpoints = readEndpoints
        // The overlay's own list is what is dialled from the start; the seeds
        // only on need. With neither, the operator chose an isolated node: it
        // keeps no memory of peers either. A seed is remembered like any
        // other peer, so a node that has met the network dials what it
        // remembers, the seeds among them, before it asks a seed afresh.
        let peerMemory: PeerMemory? = overlayPeers.isEmpty && configuration.seedPeers.isEmpty
            && configuration.childSeedPeers.values.allSatisfy(\.isEmpty) ? nil : PeerMemory(
            directory: configuration.storagePath,
            chains: [configuration.chainPath] + configuration.hostedChildren,
            excluding: Set([configuration.processPublicKey] + overlayPeers.map(\.publicKey)),
            now: Self.now()
        )
        self.peerMemory = peerMemory
        let hosted = PublishedValue(Set([configuration.chainPath] + configuration.hostedChildren))
        delegate = NodeRuntimeIvyDelegate(
            gate: gate,
            hosted: hosted,
            publicReadURL: configuration.publicReadURL,
            publicSubmit: configuration.publicSubmit,
            readEndpoints: readEndpoints
        ) { inputs.yield(.network($0)) }
        // Stands in front of the delegate, which it passes everything on to
        // but its own signalling. The loop asks it for each relayed session.
        var punchOptions = PunchConnector.Options()
        punchOptions.autoUpgrade = false
        // One line for each attempt, saying how it ended.
        punchOptions.log = { logLine("lattice-node: \($0)") }
        let punch = PunchConnector(
            ivy: ivy, localKey: configuration.processPublicKey,
            forwardingTo: delegate, options: punchOptions)
        self.punch = punch
        let cadence = configuration.maintenanceCadence
        maintenanceTimer = Task {
            while !Task.isCancelled {
                guard await Timers.sleep(nanoseconds: UInt64(cadence * 1_000_000_000)) else { return }
                await servingLedger.save()
                inputs.yield(.maintenance)
            }
        }
        peerCapabilities = remote.peerCapabilities
        // The loop task takes the only copy of the core: a copy its closure
        // kept would share every level's tree with the running loop.
        let initial = Handoff(Loop(
            core: consume core,
            storage: storage,
            ivy: ivy,
            punch: punch,
            relays: relays,
            configuration: configuration,
            outputs: outputs,
            levelReads: publishedLevelReads,
            hosted: hosted,
            templateDigest: templateDigest,
            inputs: inputs,
            gate: gate,
            helloTimeout: helloTimeout,
            remote: remote,
            workers: max(1, workers),
            failStop: failStop,
            observeJob: observeJob,
            peerMemory: peerMemory
        ))
        loop = Task {
            var state = initial.take()
            await state.retention.start(state.core.levels, counts: &state.counts)
            state.refreshView()
            // After the loop ends, inputs are only drained until the stream
            // finishes, so no RPC waits forever.
            var running = true
            for await input in stream {
                inputs.taken()
                if running {
                    running = await state.handle(input)
                } else if case .request(_, _, let reply) = input {
                    reply.resume(throwing: NodeRuntimeError.stopped)
                } else if case .host(_, let reply) = input {
                    reply.resume(throwing: NodeRuntimeError.stopped)
                } else if case .read(let read) = input {
                    read(nil)
                }
            }
            state.cancelAll()
            await state.jobs.stop()
            await state.counts.stop()
        }
    }

    /// Stop the overlay, then the loop; joins both.
    public func stop() async {
        maintenanceTimer.cancel()
        // Free the delegates waiting for room first: stopping Ivy waits for
        // its deliveries.
        await gate.close()
        punch.close()
        await webSocket.stopListening()
        await ivy.stop()
        await ivy.setContentSource(nil)
        // What serving changed, now that no more is served.
        await servingLedger.save()
        inputs.yield(.stop)
        inputs.finish()
        await loop.value
        templateDigest.finish()
    }

    /// How often, at most, a changing pool is projected for `/api/fees`
    /// (milliseconds): fee estimates a second old are as good, and a burst of
    /// submits does not walk the pool once each.
    static let projectionInterval: Int64 = 1_000

    static func now() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }

    /// Milliseconds on a clock that never steps back, for intervals.
    static func uptime() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    /// The most remembered peers one maintenance pass dials for a chain.
    static let rememberedPeerDials = 4

    /// ChainEffect work off the loop: it only posts events back, and a post
    /// after the loop ended is dropped.
    static func spawn(_ work: @escaping @Sendable () async -> Void) {
        Task { await work() }
    }
}

extension NodeRuntime {
    /// Everything the loop task owns. Only the loop touches it. It takes
    /// each input, steps the core, and hands each effect, in order, to the
    /// component that runs it (`JobPool`, `BodyFetches`, `Retention`,
    /// `ReadModel`, `Maintenance`, `TransactionFetches`); a job's or a
    /// task's result comes back as an input.
    struct Loop: Sendable {
        var core: NodeCore
        let storage: NodeStorage
        let ivy: Ivy
        let punch: PunchConnector
        /// Each session's outgoing sync messages, in order, surviving backpressure.
        let outbox: SessionOutbox
        /// Whether this node's overlay relays, as its hello says.
        let relays: Bool
        var configuration: NodeConfiguration
        var outputs: [ChainPath: LevelOutput]
        /// What RPC and the overlay read of the hosted levels, republished
        /// when the operator changes them.
        let levelReads: PublishedValue<[ChainPath: ChainReads]>
        let hosted: PublishedValue<Set<ChainPath>>
        let inputs: Inputs
        let gate: NodeRuntimeInputGate
        let helloTimeout: Duration
        let remote: IvyRootContentSource
        let failStop: @Sendable (any Error) -> Void
        let peerMemory: PeerMemory?
        /// Each hosted child level's last template block, reused while
        /// nothing it was built from changes (`ChildTemplateCache`).
        let childTemplates = ChildTemplateCache()

        /// One overlay session per peer key; the core sees `(key, id)`.
        /// Every change publishes what the open sessions' hellos advertised.
        /// A session that opened is told what this node hosts and asked what
        /// it hosts: each level's rendezvous is announced and looked at again.
        var sessions: [String: Session] = [:] {
            didSet {
                let ready = sessions.values.filter(\.ready)
                remote.peerCapabilities.set(ready.sorted { $0.id < $1.id }.map { ($0.peer, $0.capabilities) })
                if ready.isEmpty { maintenance.sessionsClosed() }
                if ready.count > oldValue.values.filter(\.ready).count {
                    startNetworkMaintenance()
                    for path in counts.retryWaiting() { retention.resettle(path) }
                }
            }
        }
        var nextSession: UInt64 = 1
        /// The keys of the peers connected now hosting each chain.
        var connectedHosts = ConnectedHosts()
        /// RPCs waiting on their answer, by reply ID.
        var replies: [UInt64: (path: ChainPath, reply: CheckedContinuation<NodeRuntimeReply, any Error>)] = [:]
        var nextReply: UInt64 = 1
        var wake: (time: Int64, task: Task<Void, Never>)?

        // The components each effect and result is dispatched to. Each owns
        // its own state; what one needs of another the loop passes in.

        /// The worker pool and its queues.
        var jobs: JobPool
        /// The body fetches, their waits and the body windows.
        var bodyFetches: BodyFetches
        /// The loop's side of retention: bodies, reads and state.
        var retention: Retention
        /// The counts of each chain's current state, and their repairs.
        var counts: Counts
        /// The read views and template digests published for RPC.
        var readModel: ReadModel
        /// Peer search, provider announcements and each chain's current
        /// peers.
        var maintenance: Maintenance
        /// Announced transactions being fetched and recently fetched.
        var transactionFetches: TransactionFetches

        struct Session {
            let peer: AuthenticatedPeer
            let id: UInt64
            var ready = false
            /// What this session's hello said the peer speaks beyond version 6.
            var capabilities: Set<String> = []
            /// The hello this node last sent on the session.
            var sentHello: Data?
            var coreID: LatticeNodeCore.PeerID { .init(key: peer.key.hex, session: id) }
        }

        init(
            core: NodeCore,
            storage: NodeStorage,
            ivy: Ivy,
            punch: PunchConnector,
            relays: Bool,
            configuration: NodeConfiguration,
            outputs: [ChainPath: LevelOutput],
            levelReads: PublishedValue<[ChainPath: ChainReads]>,
            hosted: PublishedValue<Set<ChainPath>>,
            templateDigest: PublishedValue<String>,
            inputs: Inputs,
            gate: NodeRuntimeInputGate,
            helloTimeout: Duration,
            remote: IvyRootContentSource,
            workers: Int,
            failStop: @escaping @Sendable (any Error) -> Void,
            observeJob: JobObserver?,
            peerMemory: PeerMemory?
        ) {
            self.peerMemory = peerMemory
            self.gate = gate
            self.helloTimeout = helloTimeout
            self.core = core
            self.storage = storage
            self.ivy = ivy
            self.punch = punch
            self.outbox = SessionOutbox(ivy: ivy)
            self.relays = relays
            self.configuration = configuration
            self.outputs = outputs
            self.levelReads = levelReads
            self.hosted = hosted
            self.inputs = inputs
            self.remote = remote
            self.bodyFetches = BodyFetches(storage: storage, remote: remote, inputs: inputs)
            let state = storage.stateBackend
            self.retention = Retention(
                storage: storage, state: state,
                configured: Set([configuration.chainPath] + configuration.hostedChildren)
            )
            self.counts = Counts(state: state, remote: remote, inputs: inputs)
            self.readModel = ReadModel(inputs: inputs, templateDigest: templateDigest)
            self.transactionFetches = TransactionFetches(ivy: ivy, inputs: inputs)
            self.maintenance = Maintenance(ivy: ivy, inputs: inputs, capabilities: remote.peerCapabilities, peerMemory: peerMemory)
            self.jobs = JobPool(workers: workers, inputs: inputs, observeJob: observeJob)
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
            case .bodyStored(let path, let cid, let asked, let held):
                SyncTrace.log(
                    chain: path,
                    "body \(cid) fetch \(SyncTrace.ms(asked, held)) loop \(SyncTrace.ms(held, SyncTrace.now())) ms"
                )
                bodyFetches.stored(BodyKey(path: path, cid: cid))
                return await step(.level(path, .bodyFetched(cid: cid)))
            case .bodyWaiting(let path, let cid, let reason, let detail):
                guard bodyFetches.failed(BodyKey(path: path, cid: cid), reason, detail: detail) else { return true }
                return await step(.level(path, .bodyUnavailable(cid: cid)))
            case .helloDeadline(let key, let id):
                guard let session = sessions[key], session.id == id, !session.ready else { return true }
                sessions[key] = nil
                _ = await ivy.disconnectSession(ifCurrent: session.peer)
                return true
            case .jobDone(let id, let events, let times):
                if let times {
                    let label = events.first?.traceLabel ?? "empty"
                    SyncTrace.log(chain: core.rootPath, "job \(label) \(times.line(taken: SyncTrace.now()))")
                }
                let abandoned = jobs.finished(id)
                jobs.start(in: core)
                // A stopped level's job: what it reports is for no level,
                // or for one hosted again since, which starts over.
                guard !abandoned else {
                    await releaseWhenIdle()
                    return true
                }
                for event in events {
                    // A connect without a verdict is a wait with its reason.
                    if case .level(let path, .connected(let results)) = event {
                        for verdict in results.map(\.verdict) {
                            guard let failure = verdict.retryFailure else { continue }
                            bodyFetches.connectFailed(BodyKey(path: path, cid: verdict.blockHash), failure)
                        }
                    }
                    guard await step(event) else { return false }
                }
                return true
            case .network(let network):
                let result = await receive(network)
                switch network {
                case .hello, .sync, .transactionAvailable: await gate.release()
                case .connected, .disconnected: break
                }
                // Peers are in every level's view; a message's step
                // refreshed the levels it ran.
                switch network {
                case .connected, .disconnected, .hello: refreshView()
                case .sync, .transactionAvailable: break
                }
                return result
            case .request(let path, let event, let reply):
                guard core.levels[path] != nil else {
                    reply.resume(throwing: NodeRuntimeError.unknownChain)
                    return true
                }
                let id = nextReply
                let mining = event(id)
                // A level with a backlog to execute (syncing) has no
                // template until it has executed it.
                if case .templateRequested = mining, !mined(path) {
                    reply.resume(throwing: TemplateError.executing)
                    return true
                }
                nextReply += 1
                replies[id] = (path, reply)
                return await step(.level(path, .mining(mining)))
            case .answer(let id, let result):
                answer(id, result)
                return true
            case .transactionFetched(let cid, let event):
                transactionFetches.fetched(cid)
                guard let event else { return true }
                return await step(event)
            case .maintenance:
                await maintenance.readPins(from: storage, configuration: configuration)
                startNetworkMaintenance()
                await retention.maintain(core.levels, counts: &counts)
                return true
            case .currentPeers(let current):
                maintenance.counted(current)
                let running = await meetHosts()
                refreshView()
                return running
            case .reproject(let path):
                readModel.reprojected(path)
                refreshView(path)
                return true
            case .counted(let path, let id, let repair):
                if counts.repaired(path, repair: id, repair) {
                    retention.resettle(path)
                    await retention.settleState(core.levels, counts: &counts)
                }
                return true
            case .read(let read):
                read(core.levels)
                return true
            case .host(let next, let reply):
                do {
                    try await host(next)
                    reply.resume()
                } catch {
                    reply.resume(throwing: error)
                    // A step that ended the loop.
                    if case NodeRuntimeError.stopped = error { return false }
                }
                return true
            case .maintenanceFinished:
                if maintenance.finished() { startNetworkMaintenance() }
                return true
            }
        }

        /// This node's hello: what it speaks and hosts now.
        private func helloPayload() -> Data? {
            try? ChainHandshake(
                nexusGenesisCID: configuration.nexusGenesisCID,
                chainPath: configuration.chainPath,
                capabilities: configuration.helloCapabilities(relays: relays)
            ).encode()
        }

        /// Host the children `next` lists, and only those: a level no longer
        /// listed stops with every level below it, and a newly listed one
        /// starts, parent first, as it would at boot. What a chain no longer
        /// configured stored is let go of once its level's running jobs end;
        /// listing it again syncs it from peers. A level that cannot start
        /// is left out, and the error says why; its data stays, as it is
        /// still configured.
        mutating func host(_ next: NodeConfiguration) async throws {
            try await storage.storePolicyModules(next.policyModules)
            let listed = Set(next.hostedChildren)
            retention.configure(listed.union([core.rootPath]))
            for path in core.ordered where path != core.rootPath && !listed.contains(path) {
                guard await step(.unhost(path)) else { throw NodeRuntimeError.stopped }
                // The count repair first: none writes after the chain's
                // data is let go of.
                await counts.unhost(path)
                retention.unhost(path)
            }
            var failure: (any Error)?
            for path in next.hostedChildren where core.levels[path] == nil {
                do {
                    try await start(path, specs: next.childSpecs)
                } catch NodeRuntimeError.stopped {
                    throw NodeRuntimeError.stopped
                } catch {
                    failure = failure ?? error
                }
            }
            for path in outputs.keys where core.levels[path] == nil {
                outputs[path] = nil
                readModel.drop(path)
                maintenance.drop(path)
                connectedHosts.keys[path] = nil
            }
            // A stopped level's body fetches would run on though nobody
            // wants them: no `cancelBody` comes from a level that is gone. Its RPCs would
            // wait for good: no answer comes from it either.
            bodyFetches.keep(only: Set(core.levels.keys))
            // A stopped level's jobs: a queued one never runs, and a running
            // one is cancelled, not awaited (it may wait on this loop), and
            // what it reports is dropped. Its chain is let go of once none
            // of them still runs: they store what they execute.
            jobs.abandon { core.levels[$0] == nil }
            await releaseWhenIdle()
            for (id, entry) in replies where core.levels[entry.path] == nil {
                replies[id] = nil
                entry.reply.resume(throwing: NodeRuntimeError.unknownChain)
            }
            try configuration.host(
                next.hostedChildren.filter { core.levels[$0] != nil },
                childSpecs: next.childSpecs,
                childPremineRecipients: next.childPremineRecipients,
                childGenesisTransactions: next.childGenesisTransactions,
                childSeedPeers: next.childSeedPeers.filter { core.levels[$0.key] != nil },
                policyModules: next.policyModules
            )
            var reads: [ChainPath: ChainReads] = [:]
            for path in core.ordered where path != core.rootPath {
                guard let output = outputs[path] else { continue }
                reads[path] = levelReads.value?[path] ?? NodeRuntime.reads(
                    storage: storage, remote: remote, configuration: configuration,
                    published: output.published, view: output.view,
                    chainPath: path,
                    accepted: { [storage] in await storage.hasAcceptedBlock($0, at: path) }
                )
            }
            levelReads.publish(reads)
            let hostedBefore = hosted.value
            hosted.publish(Set(core.levels.keys))
            refreshView()
            // Open sessions learn what is hosted now from a hello sent again,
            // where they said they take one.
            if hosted.value != hostedBefore, let hello = helloPayload() {
                for session in sessions.values.sorted(by: { $0.id < $1.id })
                where session.ready && session.capabilities.contains(ChainHandshake.helloUpdates) {
                    sessions[session.peer.key.hex]?.sentHello = hello
                    await outbox.send(to: session.peer, topic: OverlayTopic.overlayHello, payload: hello)
                }
            }
            startNetworkMaintenance()
            if let failure { throw failure }
        }

        /// Lets go of the chains the configuration no longer hosts, once
        /// no running job is one of theirs (`Retention.release`).
        mutating func releaseWhenIdle() async {
            let configured = retention.configured
            await retention.release(jobsRunning: jobs.runs { !configured.contains($0) })
        }

        /// One child level started over what it journaled, as boot does,
        /// with the operator's own pooled transactions for it.
        private mutating func start(_ path: ChainPath, specs operatorSpecs: [ChainPath: ChainSpec]) async throws {
            let facts = try await storage.nodeFacts(at: path)
            var specs: [ChainSpec] = []
            for case .block(let block) in facts.facts where block.parentBlockHash == nil {
                guard let spec = try await storage.chainGenesisSpec(block.blockHash, operatorSpecs: operatorSpecs) else {
                    throw NodeStorageError.missingMaterializedVolume(block.blockHash)
                }
                specs.append(spec)
            }
            let cursors = try await storage.chainCursors(at: path)
            guard await step(.host(path, facts: facts, specs: specs, cursors: cursors)) else {
                throw NodeRuntimeError.stopped
            }
            // No copy of the level outlives this check: the steps below
            // mutate it.
            guard core.levels[path] != nil else { throw NodeRuntimeError.unknownChain }
            outputs[path] = LevelOutput(published: PublishedValue(core.levels[path]?.snapshot), view: PublishedValue())
            await peerMemory?.track(path, now: NodeRuntime.now())
            for item in try await storage.localTransactions()
            where item.transaction.body.node?.chainPath == path {
                guard await step(.level(path, .mining(.transactionReceived(
                    item.transaction, origin: .restored(addedAt: item.addedAt * 1_000)
                )))) else { throw NodeRuntimeError.stopped }
            }
        }

        /// A maintenance pass (`Maintenance`), unless one runs: then the
        /// next.
        private mutating func startNetworkMaintenance() {
            maintenance.start(core, sessionReady: sessions.values.contains(where: \.ready), configuration: configuration)
        }

        private mutating func answer(_ id: UInt64, _ result: Result<NodeRuntimeReply, any Error>) {
            replies.removeValue(forKey: id)?.reply.resume(with: result)
        }

        /// Republish the read view when the act-on chain, the pool or the
        /// peers changed: the act-on chain by height (walked down from its
        /// top only as far as it changed), the pool listing and the digest.
        mutating func refreshView() {
            for path in core.levels.keys { refreshView(path) }
        }

        /// The chain's own current peers: every session for Nexus; for a
        /// child, those whose hello named it or its rendezvous names.
        func hosts(of path: ChainPath) -> [Session] {
            let hosting = ChainHandshake.hosting(path)
            return sessions.values.filter {
                $0.ready && (path == core.rootPath || $0.capabilities.contains(hosting)
                    || maintenance.currentPeers[path]?.contains($0.peer.id.publicKey) == true)
            }
        }

        /// A level with bodies waiting or in flight asks for them again when a host
        /// connects, a reconnect included: Bitswap sends its wants on every
        /// new connection. False when a step fail-stopped.
        mutating func meetHosts() async -> Bool {
            for path in core.ordered {
                let entered = connectedHosts.update(path, Set(hosts(of: path).map(\.peer.id.publicKey)))
                guard entered, let bodies = core.levels[path]?.bodies,
                      !bodies.parked.isEmpty || !bodies.requested.isEmpty else { continue }
                guard await step(.level(path, .providerJoined)) else { return false }
            }
            return true
        }

        /// The views of `paths` and of the root, whose template digest
        /// names every level's tip and pool.
        mutating func refreshView(_ paths: Set<ChainPath>) {
            guard !paths.isEmpty else { return }
            for path in paths.union([core.rootPath]) { refreshView(path) }
        }

        /// One level's read view, from the core and what the other
        /// components hold of it (`ReadModel`).
        mutating func refreshView(_ path: ChainPath) {
            guard let level = core.levels[path], let output = outputs[path] else { return }
            let snapshot = level.snapshot
            let peers = hosts(of: path).count
            // Status names the wait of the block after the act-on tip.
            let waiting = bodyFetches.waiting(at: path, level: level, tip: snapshot.actOnTip)
            let (window, unavailable) = (bodyFetches.windows[path], bodyFetches.unavailable(at: path))
            let jobsQueued = jobs.waiting(at: path)
            readModel.refresh(
                path, level: level, snapshot: snapshot, core: core, output: output, peers: peers, waiting: waiting,
                window: window, unavailable: unavailable, jobsQueued: jobsQueued
            )
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
                let hello = helloPayload()
                sessions[peer.key.hex] = Session(peer: peer, id: id, sentHello: hello)
                nextSession += 1
                let (inputs, key) = (inputs, peer.key.hex)
                Timers.deadline(after: helloTimeout, generation: id) { id in
                    inputs.yield(.helloDeadline(peerKey: key, session: id))
                }
                // Built at each connect, so it names what is hosted now.
                if let hello {
                    await outbox.send(to: peer, topic: OverlayTopic.overlayHello, payload: hello)
                }
                if peer.route != .direct {
                    // A peer met through another is worth a connection of
                    // its own. One that cannot be made leaves the relayed
                    // session as it is, as libp2p's DCUtR does: the relay
                    // bounds the routes it carries.
                    let punch = punch
                    Task { _ = await punch.upgrade(peer) }
                }
                if let replaced, replaced.ready {
                    guard await step(.peerGone(replaced.coreID)) else { return false }
                    // Forget the host it was, so the new session's hello wakes.
                    return await meetHosts()
                }
            case .disconnected(let key):
                guard let session = sessions[key],
                      !(await ivy.connectedPeers).contains(session.peer.id) else { return true }
                sessions[key] = nil
                maintenance.sessionLost(peers: sessions.count, configuration: configuration)
                if session.ready {
                    guard await step(.peerGone(session.coreID)) else { return false }
                    // Forget the host it was, so its reconnect wakes.
                    return await meetHosts()
                }
            case .hello(let peer, let payload):
                // A ready session's later hello replaces its claims, if its
                // first hello said it sends them; otherwise it is ignored.
                guard var session = sessions[peer.key.hex], session.peer.sessionID == peer.sessionID,
                      !session.ready || session.capabilities.contains(ChainHandshake.helloUpdates) else {
                    return true
                }
                    guard let remote = try? ChainHandshake.decode(payload),
                          (try? remote.validateCompatibility(
                              expectedNexusGenesisCID: configuration.nexusGenesisCID,
                              expectedChainPath: configuration.chainPath
                          )) != nil else {
                        // A later hello that does not hold is ignored: the
                        // session keeps the claims it has.
                        guard !session.ready else { return true }
                        sessions[peer.key.hex] = nil
                        _ = await ivy.disconnectSession(ifCurrent: peer)
                        return true
                    }
                let update = session.ready
                let before = session.capabilities
                session.ready = true
                session.capabilities = Set(remote.capabilities ?? [])
                // What is hosted may have changed since this node's hello
                // was sent, while the session was not yet ready to be told.
                var resend: Data?
                if !update, session.capabilities.contains(ChainHandshake.helloUpdates),
                   let current = helloPayload(), current != session.sentHello {
                    resend = current
                    session.sentHello = current
                }
                sessions[peer.key.hex] = session
                if let resend { await outbox.send(to: peer, topic: OverlayTopic.overlayHello, payload: resend) }
                // Asked for a route when a peer cannot be dialled. A session
                // that is itself relayed cannot carry another.
                let peerRelays = session.capabilities.contains(ChainHandshake.relay)
                if peer.route == .direct,
                   update ? peerRelays != before.contains(ChainHandshake.relay) : peerRelays {
                    await ivy.setRelaying(peer.id, peerRelays)
                }
                guard !update else {
                    // What it hosts changed: each chain's peers are counted again.
                    func hosting(_ claims: Set<String>) -> Set<String> {
                        claims.filter { $0.hasPrefix(ChainHandshake.hosting([])) }
                    }
                    if hosting(before) != hosting(session.capabilities) { startNetworkMaintenance() }
                    return await meetHosts()
                }
                guard await step(.peerReady(session.coreID)) else { return false }
                return await meetHosts()
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
                transactionFetches.fetch(cid, from: session.peer, as: session.coreID, levels: core.levels)
            }
            return true
        }

        // MARK: - Step and effects

        private mutating func step(_ event: NodeEvent) async -> Bool {
            let started = SyncTrace.now()
            let effects = core.step(event, now: NodeRuntime.now())
            let stepped = SyncTrace.now()
            // Only the step moves a level: its window is read once, here,
            // before any effect refreshes a view.
            let reordered = bodyFetches.moveWindows(core)
            // Time in the step's facts transaction, for the trace.
            var persisting = 0.0
            defer {
                if SyncTrace.enabled {
                    SyncTrace.log(
                        chain: core.rootPath,
                        "node-runtime step \(event.traceLabel) core \(SyncTrace.ms(started, stepped)) ms total \(SyncTrace.ms(started, SyncTrace.now())) ms persist \(SyncTrace.ms(0, persisting)) ms depth \(inputs.depth) -> \(effects.map(\.traceLabel))"
                    )
                }
            }
            // The facts transaction, then publish, then everything else, each
            // in order.
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
                guard SyncTrace.enabled, case .persist = effect else {
                    guard await execute(effect) else { return false }
                    continue
                }
                let before = SyncTrace.now()
                guard await execute(effect) else { return false }
                persisting += SyncTrace.now() - before
            }
            await retention.settleBodies(core.levels, configuration: configuration)
            await retention.settleState(core.levels, counts: &counts)
            await bodyFetches.order(reordered)
            await retention.releaseReads()
            refreshView(core.touched)
            return true
        }

        private mutating func execute(_ effect: NodeEffect) async -> Bool {
            switch effect {
            case .persist(let batch):
                do {
                    try await storage.persistNodeBatch(batch, logID: core.logID)
                } catch {
                    // Fail-stop: no later effect of this step may run.
                    failStop(error)
                    return false
                }
                await retention.persisted(batch, configuration: configuration)
            case .level(let path, let effect):
                return await execute(effect, at: path)
            case .disconnect(let peer, let reason):
                guard let session = session(peer) else { break }
                sessions[peer.key] = nil
                // No `.disconnected` follows for a session already gone: it
                // is no longer a connected host, so its reconnect wakes.
                for path in connectedHosts.keys.keys { connectedHosts.keys[path]?.remove(peer.key) }
                switch SessionClose(reason) {
                case .recycle:
                    _ = await ivy.recycleSession(ifCurrent: session.peer)
                case .close:
                    _ = await ivy.disconnectSession(ifCurrent: session.peer)
                }
            case .connect(let path, let jobs):
                self.jobs.enqueue(NodeRuntime.connectJob(
                    jobs, at: path, levels: LiveLevels(inputs: inputs), storage: storage, remote: remote,
                    failStop: failStop
                ))
                self.jobs.start(in: core)
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
                refreshView([path])
                outputs[path]?.published.publish(snapshot)
            case .send(let peer, let message):
                guard let session = session(peer), let frame = try? ChainSyncWire.encode(message, at: path) else { break }
                await outbox.send(to: session.peer, topic: frame.topic, payload: frame.payload)
            case .serveHeaders(let peer, let token, let requestID, let blockCIDs, let hasMore):
                guard let session = session(peer) else { break }
                let (storage, outbox, inputs, config, failStop) = (storage, outbox, inputs, core.config, failStop)
                NodeRuntime.spawn {
                    // Built up to a page, or for as long as the serving
                    // budget allows, and no further: the work is the
                    // page's, however many headers were asked, and the
                    // answer leaves before the requester's deadline.
                    let started = ContinuousClock.now
                    var entries: [HeaderEntry] = []
                    var (bytes, cut) = (0, false)
                    // A child header carries its saved proofs. Read off the
                    // loop, a proof whose staging transaction has not
                    // committed may show, as headers may: it was verified
                    // before persist, and the peer verifies it again.
                    var saved = SavedProofPage(store: storage.store, path: path, cids: blockCIDs)
                    for (offset, cid) in blockCIDs.enumerated() {
                        let proofs: [ChildBlockProof]
                        do {
                            proofs = try saved.proofs(at: offset)
                        } catch {
                            failStop(error)
                            return
                        }
                        guard let stored = await storage.chainHeader(cid) else { continue }
                        let spec = stored.block.parent == nil
                            ? try? await storage.chainGenesisSpec(cid) : nil
                        let entry = config.entry(
                            stored.block, children: stored.children,
                            proofs: proofs, spec: spec ?? nil
                        )
                        let elapsed = (ContinuousClock.now - started) / .milliseconds(1)
                        guard config.fits(
                            entry, first: entries.isEmpty, bytes: &bytes, elapsed: Int64(elapsed)
                        ) else {
                            cut = true
                            break
                        }
                        entries.append(entry)
                    }
                    do {
                        let frame = try ChainSyncWire.encode(.headers(HeadersResponse(
                            requestID: requestID, entries: entries, hasMore: hasMore || cut
                        )), at: path)
                        // Served once handed to the transport, not merely
                        // attempted: a page refused as backpressured is sent
                        // when the session drains.
                        _ = await outbox.send(to: session.peer, topic: frame.topic, payload: frame.payload).value
                    } catch {
                        // Unanswered, the requester's deadline decides; say why.
                        SyncTrace.log(chain: path, "headers answer \(requestID) not sent: \(error)")
                    }
                    inputs.yield(.event(.level(path, .headersServed(peer, token: token))))
                }
            case .fetchByCID(let peer, let cid):
                guard let session = session(peer) else { break }
                let (storage, ivy, inputs) = (storage, ivy, inputs)
                NodeRuntime.spawn {
                    let bytes: Data?
                    if let local = storage.store.childIndexBytes(cid) {
                        bytes = local
                    } else {
                        bytes = await ivy.fetchVolume(rootCID: cid, from: session.peer).entries[cid]
                    }
                    // No answer is no event: the request's deadline decides.
                    guard let bytes, let index = FlatDictionary<BlockHeader>(data: bytes) else { return }
                    inputs.yield(.event(.level(path, .childIndexFetched(peer, cid: cid, index))))
                }
            case .fetchBody(let cid):
                bodyFetches.fetch(
                    cid, at: path, nexusGenesisCID: configuration.nexusGenesisCID,
                    maxBlockSize: core.levels[path]?.maxBlockSize(of: cid)
                )
            case .cancelBody(let cid):
                bodyFetches.cancel(cid, at: path)
            case .deriveProof(let job):
                // From this node's own content only, never peers: the block
                // (read from this store when weighed), the carrier, its child
                // index and its saved proofs, written by the step that
                // weighed it, before this effect.
                let held = job.block ?? storage.store.header(job.childCID)?.block
                let parent = Array(path.dropLast())
                let (storage, failStop) = (storage, failStop)
                jobs.enqueue(RuntimeJob(path: path, tipCID: nil) {
                    var upstream: [ChildBlockProof] = []
                    if parent.count > 1 {
                        do {
                            upstream = try storage.store.savedProofs(at: parent, for: [job.carrier])[job.carrier] ?? []
                        } catch {
                            failStop(error)
                            return []
                        }
                    }
                    return [.level(path, .derived(await job.run(held: held, upstream: upstream, fetcher: storage.workFetcher)))]
                })
                jobs.start(in: core)
            case .verifyProofs(let batch):
                // Off the loop: a check without its block reads it from the
                // header store there; one whose block is gone answers nil,
                // blaming no one.
                jobs.enqueue(NodeRuntime.proofJob(batch, at: path, storage: storage))
                jobs.start(in: core)
            case .readTransactions(let blocks):
                jobs.enqueue(NodeRuntime.readJob(blocks, at: path, storage: storage))
                jobs.start(in: core)
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
                // To the chain's current peers: no other peer runs its pool,
                // and with many chains most sessions host others. Every
                // session hosts Nexus.
                let hosts = ChainHosts.of(path, nexusGenesisCID: configuration.nexusGenesisCID)
                let hosting = Set(await remote.peerCapabilities.sessions(hosting: hosts, ivy: ivy).map(\.sessionID))
                for session in sessions.values.sorted(by: { $0.id < $1.id })
                where session.ready && hosting.contains(session.peer.sessionID) {
                    await outbox.send(
                        to: session.peer, topic: OverlayTopic.transactionAvailable, payload: payload
                    )
                }
            case .mined(let replyID, let block):
                // Content first: the block is stored before the grind's one
                // step weighs it.
                // The carried blocks of hosted levels, each with its proof
                // verified, join the grind: one step weighs every level the
                // grind meets.
                let (storage, remote, inputs) = (storage, remote, inputs)
                let hosted = Set(core.levels.keys)
                NodeRuntime.spawn {
                    do {
                        let children = try await storage.storeMinedBlock(block, remote: remote)
                        let carried = try await storage.carriedGrinds(of: block, hosted: hosted, remote: remote)
                        inputs.yield(.event(.mined(
                            MinedGrind(root: block, rootChildren: children, carried: carried), replyID: replyID
                        )))
                    } catch {
                        inputs.yield(.answer(replyID, .failure(error)))
                    }
                }
            case .preflight:
                // An admission's job must run, else its submit is never
                // answered and its cid stays admitting.
                guard let basis = core.levels[path].flatMap({
                    NodeRuntime.miningBasis(effect, tree: $0.tree, parent: core.levels[Array(path.dropLast())])
                }) else { preconditionFailure("every hosted level's tree carries a context: a preflight has a basis") }
                jobs.enqueue(NodeRuntime.miningJob(effect, at: path, basis: basis, storage: storage, remote: remote), effect)
                jobs.start(in: core)
            case .buildTemplate:
                guard let basis = core.levels[path].flatMap({ NodeRuntime.miningBasis(effect, tree: $0.tree) }) else { break }
                jobs.enqueue(NodeRuntime.miningJob(
                    effect, at: path, basis: basis, storage: storage, remote: remote,
                    children: childTemplateInputs(below: path),
                    hosted: core.ordered.filter { $0.count > path.count && $0.starts(with: path) },
                    levels: LiveLevels(inputs: inputs),
                    cache: childTemplates
                ), effect)
                jobs.start(in: core)
            case .returnTransactions:
                jobs.enqueue(NodeRuntime.miningJob(effect, at: path, basis: nil, storage: storage, remote: remote), effect)
                jobs.start(in: core)
            }
            return true
        }

        func mined(_ path: ChainPath) -> Bool {
            NodeRuntime.mined(path, root: core.rootPath, levels: core.levels)
        }

        /// Every hosted level below `path` that is mined, as a template job
        /// reads it.
        func childTemplateInputs(below path: ChainPath) -> [ChildTemplateInput] {
            core.ordered.filter { $0.count > path.count && $0.starts(with: path) && mined($0) }.compactMap { child -> ChildTemplateInput? in
                guard let level = core.levels[child] else { return nil }
                let snapshot = level.snapshot
                let executed = !snapshot.actOnTip.isEmpty
                return ChildTemplateInput(
                    path: child,
                    tipCID: executed ? snapshot.actOnTip : nil,
                    weighed: !snapshot.bestHeaderTip.isEmpty,
                    // Each is checked again against the carrier's state.
                    transactions: level.mining.nextBlock,
                    anchor: executed ? NodeRuntime.anchor(level.tree, snapshot.actOnTip) : nil,
                    // A weighed root that has not executed carries nothing
                    // until it executes, rather than a rival genesis.
                    genesisSpec: snapshot.bestHeaderTip.isEmpty ? configuration.childSpecs[child] : nil,
                    genesisPremineRecipient: configuration.childPremineRecipients[child],
                    genesisTransactions: configuration.childGenesisTransactions[child] ?? [],
                    genesisTarget: .max
                )
            }
        }

        /// The live, ready session the core's peer names.
        private func session(_ peer: LatticeNodeCore.PeerID) -> Session? {
            guard let session = sessions[peer.key], session.id == peer.session, session.ready else { return nil }
            return session
        }

        mutating func cancelAll() {
            for entry in replies.values { entry.reply.resume(throwing: NodeRuntimeError.stopped) }
            replies.removeAll()
            wake?.task.cancel()
            bodyFetches.cancelAll()
        }
    }
}

/// A value handed to the one closure that takes it, which then holds no
/// copy of it. Taken once, by that closure alone.
private final class Handoff<Value>: @unchecked Sendable {
    private var value: Value?

    init(_ value: consuming Value) {
        self.value = value
    }

    func take() -> Value {
        value.take()!
    }
}
