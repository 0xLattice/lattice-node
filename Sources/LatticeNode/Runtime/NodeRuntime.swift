import Foundation
import Ivy
import IvyWebSocket
import Lattice
import LatticeNodeAPI
import LatticeNodeCore
import Synchronization
import cashew
import LatticeNodeSupport

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
/// - `persist` (one `NodeBatch`) → the opened `NodeStorage`'s Volume stores and state.db
///   (content fsynced first, then the facts in one transaction). A failure
///   stops the storage: restart replays the journal.
/// - `publish` → `published`, read by RPC without touching the loop.
/// - `send` / `serveHeaders` / `disconnect` → the Ivy overlay.
/// - `fetchBody` / `cancelBody` / `fetchByCID` → the content layer
///   (VolumeBroker, then overlay providers by CID).
/// - `connect` → a bounded worker pool; the result comes back as an event.
/// - `verifyProofs` → a task of its own, beside the pool; its answers come
///   back as one event.
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
    /// Template and submission answer times, and submissions on stale
    /// templates, for `/metrics`.
    let miningMetrics = MiningMetrics()
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
        // Where browsers reach this node, told every session from the
        // first: the declared URL, or else relays among its peers.
        if let url = configuration.webSocketURL {
            await runtime.ivy.setWebAddresses([WebAddress(url: url)])
        } else {
            await runtime.ivy.setAutoRelay(true)
        }
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
            miningMetrics: miningMetrics,
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
