import LatticeNodeCore

extension NodeRuntime {
    /// The loop's side of retention: what it lets go of as each level's tip
    /// moves (bodies beyond the working set, executed blocks' reads, state
    /// below the window), and on `recent` the counts that follow the tip and
    /// the check, heal or state sync that repairs them. The store holds what
    /// is kept; this holds only where the loop last left each chain. Only
    /// the loop touches it.
    struct Retention: Sendable {
        let storage: NodeStorage
        let remote: IvyRootContentSource
        let inputs: Inputs
        /// Blocks whose execution this step journaled, and each level's
        /// tip as of the last step: what the working set compares to let
        /// go of a body when the operator keeps none beyond it.
        var executedThisStep: [BodyKey] = []
        var bodyTips: [ChainPath: String] = [:]
        /// Each level's tip the kept state was last moved to, or held back
        /// at (none: move it at the next settle), and the blocks executed or
        /// found invalid this step, whose reads go after it.
        var stateTips: [ChainPath: String] = [:]
        var readsDone: [BodyKey] = []
        /// On `recent`: each chain's counts as this loop last wrote or read
        /// them, and the repair running for them.
        var counted: [ChainPath: CountedChain] = [:]
        var nextRepair: UInt64 = 0

        /// The chains the operator's configuration hosts, a level that did
        /// not start among them: none of their data is let go of.
        private(set) var configured: Set<ChainPath>
        /// Chains left the configuration: their data is let go of once no
        /// running job is of a chain not configured.
        var releasing = false

        init(storage: NodeStorage, remote: IvyRootContentSource, inputs: Inputs, configured: Set<ChainPath>) {
            self.storage = storage
            self.remote = remote
            self.inputs = inputs
            self.configured = configured
        }

        /// The operator's configuration hosts `next` now: a chain it no
        /// longer hosts is let go of once none of its jobs runs (`release`).
        mutating func configure(_ next: Set<ChainPath>) {
            releasing = releasing || !configured.isSubset(of: next)
            configured = next
        }

        /// Lets go of the chains the configuration no longer hosts, unless
        /// a job of theirs still runs: they store what they execute.
        mutating func release(jobsRunning: Bool) async {
            guard releasing, !jobsRunning else { return }
            releasing = false
            await storage.letGoOfChains(except: configured)
        }

        /// A start, before any step: what a run before left is let go of,
        /// the counts found are checked, and the state settled.
        mutating func start(_ levels: [ChainPath: ChainCore], configuration: NodeConfiguration) async {
            // What a chain the configuration does not host left goes first.
            await storage.letGoOfChains(except: configured, blocks: true)
            // With no bodies kept beyond the working set, a start lets go
            // of the ones a run that kept them left, before any step.
            for (path, level) in levels { bodyTips[path] = level.snapshot.actOnTip }
            await storage.letGoOfBodies(except: bodyTips)
            await storage.letGoOfReads()
            await storage.moveLegacyState(tips: levels.mapValues(\.snapshot.actOnHeight))
            for (path, marker) in await storage.settleCountedScopes(hosted: Set(levels.keys)) {
                counted[path] = CountedChain(marker: marker)
                audit(path)
            }
            await settleState(levels, configuration: configuration)
        }

        /// A step's batch is durable: its executed and excluded blocks.
        mutating func persisted(_ batch: NodeBatch, configuration: NodeConfiguration) async {
            var persistedBodyKeys: [BodyKey] = []
            for (path, levelBatch) in batch.levels.sorted(by: { $0.path.count < $1.path.count }) {
                persistedBodyKeys += levelBatch.facts.flatMap(\.facts).compactMap { fact -> BodyKey? in
                    guard case .validation(let validation) = fact else { return nil }
                    return BodyKey(path: path, cid: validation.blockHash)
                }
            }
            if configuration.blockBodies == .none { executedThisStep.append(contentsOf: persistedBodyKeys) }
            readsDone.append(contentsOf: persistedBodyKeys)
            // A block found invalid is no block: its body goes.
            for (path, levelBatch) in batch.levels {
                for case .exclusion(let excluded) in levelBatch.facts.flatMap(\.facts) {
                    await storage.releaseBody(excluded.blockHash, at: path)
                    readsDone.append(BodyKey(path: path, cid: excluded.blockHash))
                }
            }
        }

        /// What an executed block read goes once the kept state holds
        /// what of it the tip's state holds: its execution's window
        /// until the counts reach it.
        mutating func releaseReads() async {
            for key in readsDone { await storage.releaseReads(key.cid, at: key.path) }
            readsDone.removeAll()
        }

        /// A level the operator no longer hosts: the repair running for its
        /// counts is cancelled and waited out. What it kept goes with its
        /// chain's data, once no job of it runs (`release`).
        mutating func unhost(_ path: ChainPath) async {
            stateTips[path] = nil
            if let repair = counted.removeValue(forKey: path)?.repair {
                repair.task.cancel()
                await repair.task.value
            }
        }

        /// A session became ready.
        mutating func sessionReady() {
            // A state sync or heal that failed, for want of a peer
            // most likely, runs again at the next step.
            for (path, chain) in counted where chain.waiting {
                counted[path]?.waiting = false
                stateTips[path] = nil
            }
        }

        /// A maintenance pass, on `recent`.
        mutating func maintain(_ levels: [ChainPath: ChainCore], configuration: NodeConfiguration) async {
            // Counts behind their tip (a tip less than a window above
            // them, a store failure on a chain with no block since, or a
            // repair that failed) are settled again.
            for (path, level) in levels {
                let chain = counted[path]
                guard chain?.waiting == true
                    || chain?.marker.flatMap(CountedMarker.init)?.tip.cid != level.snapshot.actOnTip else { continue }
                counted[path]?.waiting = false
                stateTips[path] = nil
            }
            await settleState(levels, configuration: configuration)
            // Counts that moved since they were last checked are
            // checked against the store again.
            for (path, chain) in counted
            where chain.marker != nil && chain.marker != chain.audited && chain.repair == nil && !chain.waiting {
                audit(path)
            }
        }

        /// A state sync or a heal of a chain's counts (`id` names it) ended.
        mutating func repaired(
            _ path: ChainPath, repair id: UInt64, _ repair: CountedRepair,
            _ levels: [ChainPath: ChainCore], configuration: NodeConfiguration
        ) async {
            guard var chain = counted[path], chain.repair?.id == id else { return }
            chain.repair = nil
            switch repair {
            case .synced(let block, let places): chain.synced = (block, places)
            case .healed: break
            case .audited(let marker, let known?): (chain.audited, chain.known) = (marker, known)
            case .audited(_, nil):
                SyncTrace.log(chain: path, "counts do not match the store: resync")
                (chain.marker, chain.known, chain.audited) = (nil, nil, nil)
            case .failed: chain.waiting = true
            }
            counted[path] = chain
            stateTips[path] = nil
            await settleState(levels, configuration: configuration)
        }

        /// Waits for each repair running, cancelled.
        func stop() async {
            for repair in counted.values.compactMap(\.repair) {
                repair.task.cancel()
                await repair.task.value
            }
        }

        /// The working set, when the operator keeps no bodies beyond it:
        /// a body stays while it is its chain's tip. One that executed this
        /// step and is not, and the tip another block replaced, are let go.
        mutating func settleBodies(_ levels: [ChainPath: ChainCore], configuration: NodeConfiguration) async {
            guard configuration.blockBodies == .none else { return }
            let executed = Dictionary(grouping: executedThisStep, by: \.path)
            executedThisStep.removeAll()
            for (path, level) in levels {
                let tip = level.snapshot.actOnTip
                var past = (executed[path] ?? []).map(\.cid)
                if let last = bodyTips[path], last != tip { past.append(last) }
                bodyTips[path] = tip
                past.removeAll { $0 == tip }
                if !past.isEmpty { await storage.letGo(ofBodies: past, at: path) }
            }
        }

        /// With a state window: as each level's tip moves, its counts move
        /// with it on `recent`, then what executions stored more than a
        /// window below it goes; on `recent` only once the counts reached
        /// the tip, so the windows hold what the blocks the counts have not
        /// reached created. A tip that climbed from the counts' own by less
        /// than a window holds them back, unless a settle was asked for
        /// (`stateTips` lost the chain: a start, a repair that ended, a
        /// maintenance pass): a commit of each per window of blocks, not per
        /// block, with at most two windows of executions held while the
        /// counts follow the tip.
        mutating func settleState(_ levels: [ChainPath: ChainCore], configuration: NodeConfiguration) async {
            guard configuration.state != .all else { return }
            for (path, level) in levels where stateTips[path] != level.snapshot.actOnTip {
                let asked = stateTips[path] == nil
                stateTips[path] = level.snapshot.actOnTip
                if !asked, climbedLessThanAWindow(level, at: path, configuration: configuration) { continue }
                guard !level.snapshot.actOnTip.isEmpty,
                      await settleCounted(at: path, tip: level.snapshot.actOnTip, configuration: configuration)
                else { continue }
                await storage.letGoOfState(at: path, below: level.snapshot.actOnHeight)
            }
        }

        /// Whether the act-on tip of the chain at `path` descends from its
        /// counts' tip, by less than a window: a tip on another branch, or
        /// counts not kept, never holds a settle back.
        private func climbedLessThanAWindow(
            _ level: ChainCore, at path: ChainPath, configuration: NodeConfiguration
        ) -> Bool {
            guard let window = configuration.stateWindow(for: path),
                  let counts = counted[path]?.marker.flatMap(CountedMarker.init)?.tip else { return false }
            let height = level.snapshot.actOnHeight
            guard height > counts.height, height - counts.height < window else { return false }
            var cid = level.snapshot.actOnTip
            for _ in 0..<(height - counts.height) {
                guard let parent = level.parent(of: cid) else { return false }
                cid = parent
            }
            return cid == counts.cid
        }

        /// On `recent`: the chain's counts move to its act-on tip, or a
        /// state sync's counts are committed moved to it. Roots the store
        /// lacks are healed first; counts that cannot follow, or that the
        /// store refuses, are replaced by a state sync, the old ones serving
        /// until it commits; a store failure is tried again at the next
        /// settle or maintenance pass. A check, heal or state sync runs off
        /// the loop, one at a time, and settles again when it ends; one that
        /// failed waits for a new peer or the next maintenance pass. True
        /// when the counts reached the tip, or the operator keeps no counts.
        private mutating func settleCounted(
            at path: ChainPath, tip: String, configuration: NodeConfiguration
        ) async -> Bool {
            guard configuration.state == .recent, let window = configuration.stateWindow(for: path) else { return true }
            var chain = counted[path] ?? CountedChain()
            defer { counted[path] = chain }
            guard chain.repair == nil, !chain.waiting else { return false }
            let outcome: CountedOutcome
            if let synced = chain.synced {
                outcome = await storage.commitCounted(
                    at: path, block: synced.block, places: synced.places, tip: tip, window: window
                )
            } else if let marker = chain.marker {
                outcome = await storage.settleCounted(at: path, tip: tip, window: window, marker: marker, known: chain.known)
            } else {
                stateSync(path, &chain, tip: tip, window: window)
                return false
            }
            switch outcome {
            case .settled(let marker, let known):
                let moved = marker != chain.marker
                // A state sync's counts are checked anew.
                if chain.synced != nil { chain.audited = nil }
                (chain.marker, chain.known, chain.synced) = (marker, known, nil)
                // What a state sync or heal read is counted now.
                if moved { await storage.releaseStaging(at: path) }
                return true
            case .missing(let roots):
                SyncTrace.log(chain: path, "counts heal \(roots.count) roots this store lacks")
                repair(path, &chain) { storage, remote in
                    try await storage.healCounted(roots, at: path, remote: remote)
                    return .healed
                }
            case .resync(let reason):
                SyncTrace.log(chain: path, "counts resync: \(reason)")
                // A state sync's commit refused: the next waits for a new
                // peer or the next maintenance pass, not run back to back.
                chain.waiting = chain.synced != nil
                (chain.marker, chain.known, chain.synced) = (nil, nil, nil)
                if !chain.waiting { stateSync(path, &chain, tip: tip, window: window) }
            case .failed(let reason):
                SyncTrace.log(chain: path, "counts not moved: \(reason)")
            }
            return false
        }

        private mutating func stateSync(_ path: ChainPath, _ chain: inout CountedChain, tip: String, window: UInt64) {
            repair(path, &chain) { storage, remote in
                let block = try await storage.countedSyncBlock(at: path, below: tip, window: window)
                return .synced(block, try await storage.syncCountedState(at: path, block: block, remote: remote))
            }
        }

        /// The counts of the chain at `path` are checked against the store
        /// off the loop, as they are now: at a start, before they move, and
        /// at a maintenance pass when they moved since the last check.
        mutating func audit(_ path: ChainPath) {
            guard var chain = counted[path], let marker = chain.marker else { return }
            repair(path, &chain) { storage, _ in .audited(marker, await storage.auditCounted(at: path, marker: marker)) }
            counted[path] = chain
        }

        /// Runs a check, heal or state sync of the chain's counts off the
        /// loop; it posts how it ended.
        private mutating func repair(
            _ path: ChainPath, _ chain: inout CountedChain,
            _ work: @escaping @Sendable (NodeStorage, IvyRootContentSource) async throws -> CountedRepair
        ) {
            nextRepair += 1
            let (id, storage, remote, inputs) = (nextRepair, storage, remote, inputs)
            chain.repair = (id, Task {
                let ended: CountedRepair
                do {
                    ended = try await work(storage, remote)
                } catch {
                    SyncTrace.log(chain: path, "counts repair failed: \(error)")
                    ended = .failed
                }
                inputs.yield(.counted(path, repair: id, ended))
            })
        }
    }
}

/// The loop's view of one chain's counts on `recent`.
struct CountedChain {
    /// The counts' marker; nil before a state sync committed, or once they
    /// are in doubt and a state sync is to replace them.
    var marker: String?
    /// The blocks from the cursor up to the counts' tip, as the last move
    /// left them: the next move reads only the facts it needs.
    var known: [String]?
    /// The marker of the counts the last check found matching the store.
    var audited: String?
    /// The check, heal or state sync running off the loop.
    var repair: (id: UInt64, task: Task<Void, Never>)?
    /// A state sync's counts, until committed.
    var synced: (block: CountedMarker.Block, places: [String: Int])?
    /// The last repair failed: a new peer or the next maintenance pass
    /// runs it again.
    var waiting = false
}

/// How a check, heal or state sync of a chain's counts ended.
enum CountedRepair: Sendable {
    /// The state of `block`, every node with the places it holds there.
    case synced(CountedMarker.Block, [String: Int])
    case healed
    /// A check of the counts with this marker: their chain when they match
    /// the store.
    case audited(String, [String]?)
    case failed
}
