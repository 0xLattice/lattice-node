import LatticeNodeCore

extension NodeRuntime {
    /// On `recent`: each chain's counts as this loop last wrote or read
    /// them, and the check, heal or state sync that repairs them, run off
    /// the loop one at a time per chain, each ending as a `counted` input.
    /// A state sync's result is held here, and only here, until its commit:
    /// that much is authoritative. Everything else is the store's, read
    /// through the state scheme (`StateBackend`). Only the loop touches it.
    struct Counts: Sendable {
        let state: StateBackend
        let remote: IvyRootContentSource
        let inputs: Inputs
        var counted: [ChainPath: CountedChain] = [:]
        var nextRepair: UInt64 = 0

        init(state: StateBackend, remote: IvyRootContentSource, inputs: Inputs) {
            self.state = state
            self.remote = remote
            self.inputs = inputs
        }

        /// At a start: the counts found, by their markers, each checked.
        mutating func start(_ markers: [ChainPath: String]) {
            for (path, marker) in markers {
                counted[path] = CountedChain(marker: marker)
                audit(path)
            }
        }

        /// A session became ready: the chains whose last repair failed, for
        /// want of a peer most likely, to settle again at the next step.
        mutating func retryWaiting() -> [ChainPath] {
            var retried: [ChainPath] = []
            for (path, chain) in counted where chain.waiting {
                counted[path]?.waiting = false
                retried.append(path)
            }
            return retried
        }

        /// A maintenance pass: the chains whose counts are behind their tip
        /// (a tip less than a window above them, a store failure on a chain
        /// with no block since, or a repair that failed), to settle again.
        mutating func behind(_ levels: [ChainPath: ChainCore]) -> [ChainPath] {
            var behind: [ChainPath] = []
            for (path, level) in levels {
                let chain = counted[path]
                guard chain?.waiting == true
                    || chain?.marker.flatMap(CountedMarker.init)?.tip.cid != level.snapshot.actOnTip else { continue }
                counted[path]?.waiting = false
                behind.append(path)
            }
            return behind
        }

        /// A maintenance pass, after the settle: counts that moved since
        /// they were last checked are checked against the store again.
        mutating func auditMoved() {
            for (path, chain) in counted
            where chain.marker != nil && chain.marker != chain.audited && chain.repair == nil && !chain.waiting {
                audit(path)
            }
        }

        /// A state sync or a heal of a chain's counts (`id` names it) ended:
        /// true when it was the one running, and the chain is to settle
        /// again.
        mutating func repaired(_ path: ChainPath, repair id: UInt64, _ repair: CountedRepair) -> Bool {
            guard var chain = counted[path], chain.repair?.id == id else { return false }
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
            return true
        }

        /// A chain no longer hosted: any repair of its counts is cancelled
        /// and waited for. The counts go with the chain's data
        /// (`Retention.release`).
        mutating func unhost(_ path: ChainPath) async {
            if let repair = counted.removeValue(forKey: path)?.repair {
                repair.task.cancel()
                await repair.task.value
            }
        }

        /// Waits for each repair running, cancelled.
        func stop() async {
            for repair in counted.values.compactMap(\.repair) {
                repair.task.cancel()
                await repair.task.value
            }
        }

        /// Whether the act-on tip of the chain at `path` descends from its
        /// counts' tip, by less than a window: a tip on another branch, or
        /// counts not kept, never holds a settle back.
        func climbedLessThanAWindow(_ level: ChainCore, at path: ChainPath) -> Bool {
            guard let window = state.window(for: path),
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
        mutating func settle(at path: ChainPath, tip: String) async -> Bool {
            guard state.counts, let window = state.window(for: path) else { return true }
            var chain = counted[path] ?? CountedChain()
            defer { counted[path] = chain }
            guard chain.repair == nil, !chain.waiting else { return false }
            let outcome: CountedOutcome
            if let synced = chain.synced {
                outcome = await state.commitCounts(
                    at: path, block: synced.block, places: synced.places, tip: tip, window: window
                )
            } else if let marker = chain.marker {
                outcome = await state.moveCounts(at: path, tip: tip, window: window, marker: marker, known: chain.known)
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
                if moved { await state.releaseStaging(at: path) }
                return true
            case .missing(let roots):
                SyncTrace.log(chain: path, "counts heal \(roots.count) roots this store lacks")
                repair(path, &chain) { state, remote in
                    try await state.healCounts(roots, at: path, remote: remote)
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
            repair(path, &chain) { state, remote in
                let (block, places) = try await state.syncCounts(at: path, below: tip, window: window, remote: remote)
                return .synced(block, places)
            }
        }

        /// The counts of the chain at `path` are checked against the store
        /// off the loop, as they are now: at a start, before they move, and
        /// at a maintenance pass when they moved since the last check.
        mutating func audit(_ path: ChainPath) {
            guard var chain = counted[path], let marker = chain.marker else { return }
            repair(path, &chain) { state, _ in .audited(marker, await state.auditCounts(at: path, marker: marker)) }
            counted[path] = chain
        }

        /// Runs a check, heal or state sync of the chain's counts off the
        /// loop; it posts how it ended.
        private mutating func repair(
            _ path: ChainPath, _ chain: inout CountedChain,
            _ work: @escaping @Sendable (StateBackend, IvyRootContentSource) async throws -> CountedRepair
        ) {
            nextRepair += 1
            let (id, state, remote, inputs) = (nextRepair, state, remote, inputs)
            chain.repair = (id, Task {
                let ended: CountedRepair
                do {
                    ended = try await work(state, remote)
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
