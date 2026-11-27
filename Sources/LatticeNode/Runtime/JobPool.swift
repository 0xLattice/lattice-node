import LatticeNodeCore
import LatticeNodeSupport

extension NodeRuntime {
    /// A worker job. One with a tip is skipped at dequeue when it is not its
    /// level's mining tip: it runs nothing, posts nothing. `kind` decides its
    /// queue (`JobQueues`).
    struct RuntimeJob: Sendable {
        /// Its queue (`JobQueues`).
        enum Kind: Sendable {
            /// What an RPC waits on: an awaited admission, a template build.
            case answered
            /// A level's next block to execute (`connectJob`).
            case connect
            case other
        }

        let path: ChainPath
        let tipCID: String?
        var kind = Kind.other
        /// When it was queued, while tracing.
        var queued = 0.0
        let run: @Sendable () async -> [NodeEvent]

        func isCurrent(in core: NodeCore) -> Bool {
            tipCID.map { core.levels[path]?.mining.tipCID == $0 } ?? true
        }
    }

    /// The worker's queues, each first in, first out, served in a fixed
    /// order: (A) what an RPC waits on, a submit's admission and a template
    /// build; then (B) each level's next block, so a level's connect never
    /// waits behind the derivations queued before it while a node syncs a
    /// tree of chains, and no level goes ahead of another; then (C)
    /// everything else in arrival order: derivations, reads, rechecks, and
    /// a peer's or a returned transaction's admission. A peer's proofs
    /// are not here: they are checked where their header is decoded,
    /// before the loop sees it (`NodeRuntimeIvyDelegate`). A recheck
    /// whose tip is not the current one is dropped at dequeue: it runs
    /// nothing, posts nothing.
    struct JobQueues {
        var answered: [RuntimeJob] = []
        var connects: [RuntimeJob] = []
        var rest: [RuntimeJob] = []

        var isEmpty: Bool { answered.isEmpty && connects.isEmpty && rest.isEmpty }

        /// The jobs waiting for a worker on `path`.
        func count(at path: ChainPath) -> Int {
            answered.count(where: { $0.path == path }) + connects.count(where: { $0.path == path })
                + rest.count(where: { $0.path == path })
        }

        mutating func append(_ job: RuntimeJob) {
            switch job.kind {
            case .answered: answered.append(job)
            case .connect: connects.append(job)
            case .other: rest.append(job)
            }
        }

        /// Drops the waiting jobs `dropped` names.
        mutating func drop(where dropped: (RuntimeJob) -> Bool) {
            answered.removeAll(where: dropped)
            connects.removeAll(where: dropped)
            rest.removeAll(where: dropped)
        }

        /// The next job a free worker runs.
        mutating func next(in core: NodeCore) -> RuntimeJob? {
            while !isEmpty {
                let job = !answered.isEmpty ? answered.removeFirst()
                    : !connects.isEmpty ? connects.removeFirst() : rest.removeFirst()
                if job.isCurrent(in: core) { return job }
            }
            return nil
        }
    }

    /// The worker pool: at most `workers` jobs run; each result posts
    /// back as an event that frees its slot. Only the loop touches it.
    struct JobPool: Sendable {
        let workers: Int
        let inputs: Inputs
        let observeJob: JobObserver?
        var runningJobs = 0
        /// The running jobs, by level, which the loop waits for before it
        /// lets the store go: a job reading from peers can outlast a step.
        var tasks: [UInt64: (path: ChainPath, task: Task<Void, Never>)] = [:]
        /// The running jobs of levels that stopped, cancelled: what they
        /// report is dropped.
        var abandoned: Set<UInt64> = []
        var nextJob: UInt64 = 0
        /// The jobs waiting for a worker (`JobQueues`).
        var queued = JobQueues()

        init(workers: Int, inputs: Inputs, observeJob: JobObserver?) {
            self.workers = workers
            self.inputs = inputs
            self.observeJob = observeJob
        }

        /// Start queued jobs while a worker is free; `core` decides which
        /// rechecks are still current.
        mutating func start(in core: NodeCore) {
            while runningJobs < workers, let job = queued.next(in: core) {
                runningJobs += 1
                nextJob += 1
                let (inputs, id, started) = (inputs, nextJob, SyncTrace.now())
                tasks[id] = (job.path, Task {
                    let events = await job.run()
                    let times = SyncTrace.enabled ? TraceTimes(queued: job.queued, started: started, done: SyncTrace.now()) : nil
                    inputs.yield(.jobDone(id, events, times))
                })
            }
        }

        /// Queue `job`, behind `observeJob` when a test watches the pool.
        mutating func enqueue(_ job: RuntimeJob, _ effect: MiningEffect? = nil) {
            guard let observeJob else {
                var job = job
                job.queued = SyncTrace.now()
                return queued.append(job)
            }
            queued.append(RuntimeJob(path: job.path, tipCID: job.tipCID, kind: job.kind, queued: SyncTrace.now()) {
                await observeJob(job.kind, job.path, effect)
                return await job.run()
            })
        }

        /// Job `id` ended: its slot frees. True when its level stopped
        /// while it ran (`abandon`): what it reports is dropped.
        mutating func finished(_ id: UInt64) -> Bool {
            runningJobs -= 1
            tasks[id] = nil
            return abandoned.remove(id) != nil
        }

        /// The levels `stopped` names stopped: a queued job of theirs never
        /// runs, and a running one is cancelled, not awaited (it may wait
        /// on the loop), and what it reports is dropped.
        mutating func abandon(where stopped: (ChainPath) -> Bool) {
            queued.drop { stopped($0.path) }
            for (id, job) in tasks where stopped(job.path) {
                job.task.cancel()
                abandoned.insert(id)
            }
        }

        /// Whether a running job is of a level `matches` names.
        func runs(where matches: (ChainPath) -> Bool) -> Bool {
            tasks.values.contains { matches($0.path) }
        }

        /// The jobs waiting for a worker on `path`.
        func waiting(at path: ChainPath) -> Int {
            queued.count(at: path)
        }

        /// Cancels each running job and waits for it.
        func stop() async {
            for job in tasks.values.map(\.task) {
                job.cancel()
                await job.value
            }
        }
    }
}
