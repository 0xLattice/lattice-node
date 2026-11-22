import Foundation
import Ivy
import IvyWebSocket
import Lattice
import LatticeNodeAPI
import LatticeNodeCore
import Synchronization
import cashew
import LatticeNodeSupport

extension NodeRuntime {
    /// Everything the loop task owns. Only the loop touches it. It takes
    /// each input, steps the core, and hands each effect, in order, to the
    /// component that runs it (`JobPool`, `BodyFetches`, `Retention`,
    /// `Counts`, `ReadModel`, `Maintenance`, `TransactionFetches`); a job's
    /// or a task's result comes back as an input.
    ///
    /// Its contract (docs/design/sync-architecture.md, "The loop's
    /// contract"): the core performs no I/O; the loop never waits for the
    /// network or long computation (but for a dropped chain's count repair,
    /// which it cancels and waits out so it writes nothing after), nor on
    /// anything only the loop can finish; only the loop changes the core, by stepping it; a step's
    /// writes complete before what they make true is published (persist,
    /// then publish, then the rest); and every job and task has a rule for
    /// when it is superseded, listed there.
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
        /// Counts submissions on stale templates (`MiningMetrics`).
        let miningMetrics: MiningMetrics
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
        /// Submissions taken while their work's root tip was no longer the
        /// act-on tip, by reply ID, until the core judges their nonce: one
        /// it mines is counted stale (`MiningMetrics`), a refused one not.
        var staleWork: Set<UInt64> = []
        var wake: (time: Int64, task: Task<Void, Never>)?

        // The components each effect and result is dispatched to. Each owns
        // its own state; what one needs of another the loop reads and passes
        // in. One exception: Retention's settles (`start`, `maintain`,
        // `settleState`) take Counts in, inout, because a level's state goes
        // only once its counts have moved.

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
            miningMetrics: MiningMetrics,
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
            self.miningMetrics = miningMetrics
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
                // Work is stale, as a pool counts it, when the tip its
                // block builds on is no longer the act-on tip: its block can
                // only be a side block. A change to what a template would
                // carry (the pool, a child) leaves it current. Work this node
                // does not know cannot be told.
                if case .submitWork(_, let workID, _) = mining,
                   let level = core.levels[path], let template = level.mining.templates.template(workID),
                   template.tipCID != level.snapshot.actOnTip {
                    staleWork.insert(id)
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
        func helloPayload() -> Data? {
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
            try storage.stores.open(at: path)
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
        mutating func startNetworkMaintenance() {
            maintenance.start(core, sessionReady: sessions.values.contains(where: \.ready), configuration: configuration)
        }

        mutating func answer(_ id: UInt64, _ result: Result<NodeRuntimeReply, any Error>) {
            staleWork.remove(id)
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

        mutating func cancelAll() {
            for entry in replies.values { entry.reply.resume(throwing: NodeRuntimeError.stopped) }
            replies.removeAll()
            wake?.task.cancel()
            bodyFetches.cancelAll()
        }
    }
}
