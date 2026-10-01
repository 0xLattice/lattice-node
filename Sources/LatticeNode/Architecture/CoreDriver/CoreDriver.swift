import Foundation
import Ivy
import Lattice
import LatticeNodeCore
import cashew

public enum CoreDriverError: Error, Equatable, Sendable {
    /// The durable facts are rooted at another genesis than the configured
    /// Nexus genesis CID.
    case wrongGenesis(String?)
    /// The driver hosts the Nexus level only.
    case notNexus
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
///
/// Network and fetch effects spawn tasks that only post events back, so no
/// suspension ever interleaves two steps.
// PENDING (child levels): `hosted` is empty, so no `bootstrap` effect and no
// child level arise yet. Hosting children needs per-level stores (P4) and
// the evidence index behind `lookupProofs` / `indexProof`.
public final class CoreDriver: Sendable {
    public let published: PublishedValue<Snapshot>
    private let inputs: AsyncStream<Input>.Continuation
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
        /// A worker finished: its slot frees, then its result steps.
        case jobDone(HostEvent)
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
        let core = try await boot(process: process, configuration: configuration, coreConfig: coreConfig)
        let headers = try CoreHeaderStore(directory: configuration.storagePath)
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
    static func boot(
        process: ChainProcess,
        configuration: NodeConfiguration,
        coreConfig: CoreConfig
    ) async throws -> HostCore {
        guard configuration.address.isNexus else { throw CoreDriverError.notNexus }
        let root = try Core.restore(
            replaying: try await process.coreFacts(),
            context: try configuration.runtimeContext,
            spec: NexusGenesis.spec,
            config: coreConfig
        )
        guard root.genesis == configuration.nexusGenesisCID else {
            throw CoreDriverError.wrongGenesis(root.genesis)
        }
        return HostCore(root: root.tree, hosted: [], config: coreConfig)
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
        self.published = published
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
            inputs: inputs,
            gate: gate,
            helloTimeout: helloTimeout,
            remote: IvyRootContentSource(ivy: ivy, policy: configuration.resourcePolicy),
            workers: max(1, workers),
            failStop: failStop
        )
        loop = Task {
            var state = initial
            for await input in stream {
                guard await state.handle(input) else { break }
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
        let inputs: AsyncStream<Input>.Continuation
        let gate: CoreDriverInputGate
        let helloTimeout: Duration
        let remote: IvyRootContentSource
        let workers: Int
        let failStop: @Sendable (any Error) -> Void

        /// One overlay session per peer key; the core sees `(key, id)`.
        var sessions: [String: Session] = [:]
        var nextSession: UInt64 = 1
        var runningJobs = 0
        var queuedJobs: [@Sendable () async -> HostEvent] = []
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
            inputs: AsyncStream<Input>.Continuation,
            gate: CoreDriverInputGate,
            helloTimeout: Duration,
            remote: IvyRootContentSource,
            workers: Int,
            failStop: @escaping @Sendable (any Error) -> Void
        ) {
            self.gate = gate
            self.helloTimeout = helloTimeout
            self.core = core
            self.process = process
            self.headers = headers
            self.ivy = ivy
            self.hello = hello
            self.configuration = configuration
            self.published = published
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
            case .jobDone(let event):
                runningJobs -= 1
                startJobs()
                return await step(event)
            case .network(let network):
                let result = await receive(network)
                switch network {
                case .hello, .sync: await gate.release()
                case .connected, .disconnected: break
                }
                return result
            }
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
            }
            return true
        }

        // MARK: - Step and effects

        private mutating func step(_ event: HostEvent) async -> Bool {
            let effects = core.step(event, now: CoreDriver.now())
            SyncTrace.log(chain: core.rootPath, "core-driver step \(String(describing: event).prefix(160)) -> \(effects.map { String(describing: $0).prefix(80) })")
            // Persist, then publish, then everything else, each in order.
            func rank(_ effect: HostEffect) -> Int {
                switch effect {
                case .persist: 0
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
            return true
        }

        private mutating func execute(_ effect: HostEffect) async -> Bool {
            switch effect {
            case .persist(let batch):
                // PENDING (child levels, P4): one transaction across levels,
                // with `added` / `removed` level records and `issued` links.
                // The Nexus-only host writes its root level's batch.
                for (path, levelBatch) in batch.levels where path == core.rootPath {
                    // A validated block's body roots are journaled with its
                    // validation, so they stay retained across restarts.
                    let validated = levelBatch.facts.flatMap(\.facts).compactMap { fact -> BodyKey? in
                        guard case .validation(let validation) = fact else { return nil }
                        return BodyKey(path: path, cid: validation.blockHash)
                    }
                    do {
                        try await process.persistCoreBatch(
                            levelBatch,
                            headers: headers,
                            bodyRoots: validated.flatMap { bodyRoots[$0] ?? [] }
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
                let fetcher = process.localFetcher
                queuedJobs.append {
                    .level(path, .connected(await ChainTree.connect(
                        job,
                        fetcher: fetcher,
                        parentFacts: parentFacts,
                        validationContext: ValidationContext(nowMilliseconds: CoreDriver.now())
                    )))
                }
                startJobs()
            case .bootstrap:
                // PENDING (child levels): never emitted while `hosted` is empty.
                break
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
                if path == core.rootPath { published.publish(snapshot) }
            case .send(let peer, let message):
                guard let session = session(peer), let frame = try? CoreWire.encode(message, at: path) else { break }
                _ = await ivy.sendMessage(to: session.peer, topic: frame.topic, payload: frame.payload)
            case .serveHeaders(let peer, let token, let requestID, let blockCIDs, let hasMore):
                guard let session = session(peer) else { break }
                let (process, headers, ivy, inputs, config) = (process, headers, ivy, inputs, core.config)
                // PENDING (child levels): a child header's proofs are served
                // from the evidence index.
                spawn {
                    var entries: [HeaderEntry] = []
                    for cid in blockCIDs {
                        guard let stored = await process.coreHeader(cid, headers: headers) else { continue }
                        entries.append(config.entry(stored.block, children: stored.children))
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
                    guard let bytes, let index = ChildIndex(data: bytes) else { return }
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
                guard let block = job.block ?? headers.header(job.childCID)?.block else { break }
                queuedJobs.append { .level(path, .proofVerified(job, await job.run(block))) }
                startJobs()
            case .lookupProofs, .indexProof:
                // PENDING (child levels): the child-evidence index (#253).
                // A root level never emits these.
                break
            }
            return true
        }

        /// The live, ready session the core's peer names.
        private func session(_ peer: LatticeNodeCore.PeerID) -> Session? {
            guard let session = sessions[peer.key], session.id == peer.session, session.ready else { return nil }
            return session
        }

        /// The worker pool: at most `workers` jobs run; each result posts
        /// back as an event that frees its slot.
        private mutating func startJobs() {
            while runningJobs < workers, !queuedJobs.isEmpty {
                let job = queuedJobs.removeFirst()
                runningJobs += 1
                let inputs = inputs
                spawn { inputs.yield(.jobDone(await job())) }
            }
        }

        /// Effect work off the loop: it only posts events back, and a post
        /// after the loop ended is dropped.
        private func spawn(_ work: @escaping @Sendable () async -> Void) {
            Task { await work() }
        }

        mutating func cancelAll() {
            wake?.task.cancel()
            for task in bodies.values { task.cancel() }
            bodies.removeAll()
        }
    }
}
