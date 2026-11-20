import LatticeNodeCore

extension NodeRuntime {
    /// The loop's side of retention: what it lets go of as each level's tip
    /// moves (bodies beyond the working set, executed blocks' reads, state
    /// below the window), through the state scheme (`StateBackend`) for
    /// state. The counts the state waits on are `Counts`, which the loop
    /// passes in. The store holds what is kept; this holds only where the
    /// loop last left each chain. Only the loop touches it.
    struct Retention: Sendable {
        let storage: NodeStorage
        let state: StateBackend
        /// Blocks whose execution this step journaled, and each level's
        /// tip as of the last step: what the working set compares to let
        /// go of a body when the operator keeps none beyond it.
        var executedThisStep: [BodyKey] = []
        /// Blocks this step found invalid, whose bodies go after its effects.
        var excludedThisStep: [BodyKey] = []
        var bodyTips: [ChainPath: String] = [:]
        /// Each level's tip the kept state was last moved to, or held back
        /// at (none: move it at the next settle), and the blocks executed or
        /// found invalid this step, whose reads go after it.
        var stateTips: [ChainPath: String] = [:]
        var readsDone: [BodyKey] = []

        /// The chains the operator's configuration hosts, a level that did
        /// not start among them: none of their data is let go of.
        private(set) var configured: Set<ChainPath>
        /// Chains left the configuration: their data is let go of once no
        /// running job is of a chain not configured.
        var releasing = false

        init(storage: NodeStorage, state: StateBackend, configured: Set<ChainPath>) {
            self.storage = storage
            self.state = state
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
            guard releasing, !jobsRunning, !state.stops(at: .letGoOfChain) else { return }
            releasing = false
            await storage.letGoOfChains(except: configured)
        }

        /// A start, before any step: what a run before left is let go of,
        /// the counts found are checked, and the state settled.
        mutating func start(_ levels: [ChainPath: ChainCore], counts: inout Counts) async {
            // What a chain the configuration does not host left goes first.
            await storage.letGoOfChains(except: configured)
            // With no bodies kept beyond the working set, a start lets go
            // of the ones a run that kept them left, before any step.
            for (path, level) in levels { bodyTips[path] = level.snapshot.actOnTip }
            if !state.stops(at: .startBodies) { await storage.letGoOfBodies(except: bodyTips) }
            counts.start(await state.start(tips: levels.mapValues(\.snapshot.actOnHeight)))
            await settleState(levels, counts: &counts)
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
            // A block found invalid is no block: its body goes after the
            // step's effects (`settleBodies`).
            for (path, levelBatch) in batch.levels {
                for case .exclusion(let excluded) in levelBatch.facts.flatMap(\.facts) {
                    excludedThisStep.append(BodyKey(path: path, cid: excluded.blockHash))
                    readsDone.append(BodyKey(path: path, cid: excluded.blockHash))
                }
            }
        }

        /// What an executed block read goes once the kept state holds
        /// what of it the tip's state holds: its execution's window
        /// until the counts reach it.
        mutating func releaseReads() async {
            for key in readsDone { await state.releaseReads(key.cid, at: key.path) }
            readsDone.removeAll()
        }

        /// The chain at `path` settles at the next settle, whatever its tip.
        mutating func resettle(_ path: ChainPath) {
            stateTips[path] = nil
        }

        /// A level the operator no longer hosts. What it kept goes with its
        /// chain's data, once no job of it runs (`release`); the repair of
        /// its counts stops with `Counts.unhost`.
        mutating func unhost(_ path: ChainPath) {
            stateTips[path] = nil
        }

        /// A maintenance pass: on `recent`, counts behind their tip are
        /// settled again, then those that moved are checked.
        mutating func maintain(_ levels: [ChainPath: ChainCore], counts: inout Counts) async {
            guard state.counts else { return }
            for path in counts.behind(levels) { stateTips[path] = nil }
            await settleState(levels, counts: &counts)
            counts.auditMoved()
        }

        /// The bodies of the blocks this step found invalid go. Then the
        /// working set, when the operator keeps no bodies beyond it: a body
        /// stays while it is its chain's tip. One that executed this step
        /// and is not, and the tip another block replaced, are let go.
        mutating func settleBodies(_ levels: [ChainPath: ChainCore], configuration: NodeConfiguration) async {
            for key in excludedThisStep where !state.stops(at: .releaseExcludedBody) {
                await storage.releaseBody(key.cid, at: key.path)
            }
            excludedThisStep.removeAll()
            guard configuration.blockBodies == .none else { return }
            let executed = Dictionary(grouping: executedThisStep, by: \.path)
            executedThisStep.removeAll()
            for (path, level) in levels {
                let tip = level.snapshot.actOnTip
                var past = (executed[path] ?? []).map(\.cid)
                if let last = bodyTips[path], last != tip { past.append(last) }
                bodyTips[path] = tip
                past.removeAll { $0 == tip }
                if !past.isEmpty, !state.stops(at: .letGoOfBodies) { await storage.letGo(ofBodies: past, at: path) }
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
        mutating func settleState(_ levels: [ChainPath: ChainCore], counts: inout Counts) async {
            guard !state.keepsAll else { return }
            for (path, level) in levels where stateTips[path] != level.snapshot.actOnTip {
                let asked = stateTips[path] == nil
                stateTips[path] = level.snapshot.actOnTip
                if !asked, counts.climbedLessThanAWindow(level, at: path) { continue }
                guard !level.snapshot.actOnTip.isEmpty,
                      await counts.settle(at: path, tip: level.snapshot.actOnTip)
                else { continue }
                await state.letGo(at: path, below: level.snapshot.actOnHeight)
            }
        }
    }
}
