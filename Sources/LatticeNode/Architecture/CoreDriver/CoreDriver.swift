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

/// The production shell around the sans-IO `LatticeNodeCore.Core` (behind
/// `--core-driver`, Nexus only). It is plumbing: one serial task owns the
/// core, drains one event channel (network messages, content arrivals, job
/// results, timers), calls `step(event, now)` and executes the effects in
/// order — persist, then publish, then everything else. Every decision is
/// the core's.
///
/// - `persist` → the opened `ChainProcess`'s Volume store and state.db
///   (content fsynced first, then the facts in one transaction). A failure
///   stops the process: restart replays the journal.
/// - `publish` → `published`, read by RPC without touching the loop.
/// - `send` / `serveHeaders` / `disconnect` → the Ivy overlay.
/// - `fetchBody` / `cancelBody` / `fetchByCID` → the content layer
///   (VolumeBroker, then overlay providers by CID).
/// - `connect` → a bounded worker pool; the verdict comes back as an event.
/// - `wakeAt` → one timer that posts `tick`.
///
/// Network and fetch effects spawn tasks that only post events back, so no
/// suspension ever interleaves two steps.
// PENDING #259: `Core` becomes the multi-level `HostCore`; the loop is the
// same, events and effects gain a level.
public final class CoreDriver: Sendable {
    public let published: PublishedValue<Snapshot>
    private let inputs: AsyncStream<Input>.Continuation
    private let loop: Task<Void, Never>
    private let ivy: Ivy
    private let delegate: CoreDriverIvyDelegate

    enum Input: Sendable {
        case network(CoreDriverNetworkInput)
        case event(LatticeNodeCore.Event)
        /// A worker finished: its slot frees, then its result steps.
        case jobDone(LatticeNodeCore.Event)
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
        let driver = CoreDriver(
            core: core,
            process: process,
            headers: headers,
            configuration: configuration,
            ivy: Ivy(config: try overlay ?? NodeNetworkPlaneConfigurations(configuration).overlay),
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
    ) async throws -> Core {
        guard configuration.address.isNexus else { throw CoreDriverError.notNexus }
        let core = try Core.restore(
            replaying: try await process.coreFacts(),
            context: try configuration.runtimeContext,
            spec: NexusGenesis.spec,
            config: coreConfig
        )
        let genesis = core.tree.canonicalBlockHash(atHeight: 0)
        guard genesis == configuration.nexusGenesisCID else {
            throw CoreDriverError.wrongGenesis(genesis)
        }
        return core
    }

    private init(
        core: Core,
        process: ChainProcess,
        headers: CoreHeaderStore,
        configuration: NodeConfiguration,
        ivy: Ivy,
        workers: Int,
        failStop: @escaping @Sendable (any Error) -> Void
    ) {
        let (stream, inputs) = AsyncStream<Input>.makeStream()
        let published = PublishedValue(core.snapshot)
        self.published = published
        self.inputs = inputs
        self.ivy = ivy
        delegate = CoreDriverIvyDelegate { inputs.yield(.network($0)) }
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
        var core: Core
        let process: ChainProcess
        let headers: CoreHeaderStore
        let ivy: Ivy
        let hello: Data?
        let configuration: NodeConfiguration
        let published: PublishedValue<Snapshot>
        let inputs: AsyncStream<Input>.Continuation
        let remote: IvyRootContentSource
        let workers: Int
        let failStop: @Sendable (any Error) -> Void

        /// One overlay session per peer key; the core sees `(key, id)`.
        var sessions: [String: Session] = [:]
        var nextSession: UInt64 = 1
        var runningJobs = 0
        var queuedJobs: [@Sendable () async -> LatticeNodeCore.Event] = []
        var wake: (time: Int64, task: Task<Void, Never>)?
        var bodies: [String: Task<Void, Never>] = [:]

        struct Session {
            let peer: AuthenticatedPeer
            let id: UInt64
            var ready = false
            var coreID: LatticeNodeCore.PeerID { .init(key: peer.key.hex, session: id) }
        }

        init(
            core: Core,
            process: ChainProcess,
            headers: CoreHeaderStore,
            ivy: Ivy,
            hello: Data?,
            configuration: NodeConfiguration,
            published: PublishedValue<Snapshot>,
            inputs: AsyncStream<Input>.Continuation,
            remote: IvyRootContentSource,
            workers: Int,
            failStop: @escaping @Sendable (any Error) -> Void
        ) {
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
                if case .bodyFetched(let cid) = event { bodies[cid] = nil }
                if case .tick = event { wake = nil }
                return await step(event)
            case .jobDone(let event):
                runningJobs -= 1
                startJobs()
                return await step(event)
            case .network(let network):
                return await receive(network)
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
                sessions[peer.key.hex] = Session(peer: peer, id: nextSession)
                nextSession += 1
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
            case .message(let peer, let topic, let payload):
                guard var session = sessions[peer.key.hex], session.peer.sessionID == peer.sessionID else {
                    return true
                }
                if topic == NodeNetworkTopic.overlayHello {
                    guard !session.ready else { return true }
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
                }
                // A malformed frame is dropped: only the core blames, and
                // only for proof-of-work.
                guard session.ready, let message = try? CoreWire.decode(topic: topic, payload: payload) else {
                    return true
                }
                return await step(.received(session.coreID, message))
            }
            return true
        }

        // MARK: - Step and effects

        private mutating func step(_ event: LatticeNodeCore.Event) async -> Bool {
            let effects = core.step(event, now: CoreDriver.now())
            // Persist, then publish, then everything else, each in order.
            func rank(_ effect: LatticeNodeCore.Effect) -> Int {
                switch effect {
                case .persist: 0
                case .publish: 1
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

        private mutating func execute(_ effect: LatticeNodeCore.Effect) async -> Bool {
            switch effect {
            case .persist(let batch):
                do {
                    try await process.persistCoreBatch(batch, headers: headers)
                } catch {
                    // Fail-stop: no later effect of this step may run.
                    failStop(error)
                    return false
                }
            case .publish(let snapshot):
                published.publish(snapshot)
            case .send(let peer, let message):
                guard let session = session(peer), let frame = try? CoreWire.encode(message) else { break }
                _ = await ivy.sendMessage(to: session.peer, topic: frame.topic, payload: frame.payload)
            case .serveHeaders(let peer, let token, let requestID, let blockCIDs, let hasMore):
                guard let session = session(peer) else { break }
                let (process, headers, ivy, inputs, config) = (process, headers, ivy, inputs, core.config)
                spawn {
                    var entries: [HeaderEntry] = []
                    for cid in blockCIDs {
                        guard let stored = await process.coreHeader(cid, headers: headers) else { continue }
                        entries.append(config.entry(stored.block, children: stored.children))
                    }
                    let page = config.page(entries, hasMore: hasMore)
                    if let frame = try? CoreWire.encode(.headers(HeadersResponse(
                        requestID: requestID, entries: page.entries, hasMore: page.hasMore
                    ))) {
                        _ = await ivy.sendMessage(to: session.peer, topic: frame.topic, payload: frame.payload)
                    }
                    inputs.yield(.event(.headersServed(peer, token: token)))
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
                    inputs.yield(.event(.childIndexFetched(peer, cid: cid, index)))
                }
            case .fetchBody(let cid):
                guard bodies[cid] == nil else { break }
                let (process, remote, inputs) = (process, remote, inputs)
                bodies[cid] = Task {
                    // The content layer retries until the body is held or the
                    // core no longer wants it.
                    var backoff: UInt64 = 250
                    while !Task.isCancelled {
                        if (try? await process.fetchCoreBody(cid, remote: remote)) != nil {
                            inputs.yield(.event(.bodyFetched(cid: cid)))
                            return
                        }
                        _ = await Timers.sleep(nanoseconds: backoff * 1_000_000)
                        backoff = min(backoff * 2, 30_000)
                    }
                }
            case .cancelBody(let cid):
                bodies.removeValue(forKey: cid)?.cancel()
            case .connect(let job):
                let fetcher = process.localFetcher
                queuedJobs.append {
                    .connected(await ChainTree.connect(
                        job,
                        fetcher: fetcher,
                        validationContext: ValidationContext(nowMilliseconds: CoreDriver.now())
                    ))
                }
                startJobs()
            case .disconnect(let peer, _):
                guard let session = session(peer) else { break }
                sessions[peer.key] = nil
                _ = await ivy.disconnectSession(ifCurrent: session.peer)
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
