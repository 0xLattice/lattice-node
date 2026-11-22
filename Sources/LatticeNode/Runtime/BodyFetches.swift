import Lattice
import LatticeNodeCore
import LatticeNodeSupport

extension NodeRuntime {
    struct BodyKey: Hashable {
        let path: ChainPath
        let cid: String
    }

    /// The bodies the core asks for: each fetch in flight, why each body
    /// the window asks for has not arrived or not connected, and the body
    /// windows the read cache and the content budget are ordered by. Only
    /// the loop touches it.
    struct BodyFetches: Sendable {
        let storage: NodeStorage
        let remote: IvyRootContentSource
        let inputs: Inputs
        var bodies: [BodyKey: Task<Void, Never>] = [:]
        /// Why each body the window asks for has not arrived: its last
        /// fetch's failure, until it arrives or the window leaves it. A body
        /// with one is fetched again without a bundle.
        var fetchWaits: [BodyKey: BodyWait] = [:]
        /// Why each held block's connect ended without a verdict, until the
        /// block leaves the body window.
        var connectWaits: [BodyKey: BodyWait] = [:]
        /// The window blocks' distances from their chains' next blocks to
        /// connect, each its nearest in any window: the read cache's order.
        var cachedBodyOrder: [String: Int] = [:]
        /// Each level's next blocks to connect and window distances, as of
        /// the last step that ran it (`NodeCore.touched`): a level no step
        /// ran has the same tree, so the same window.
        var windows: [ChainPath: (next: [String], distances: [String: Int])] = [:]

        init(storage: NodeStorage, remote: IvyRootContentSource, inputs: Inputs) {
            self.storage = storage
            self.remote = remote
            self.inputs = inputs
        }

        /// The windows after a step: each level the step ran, or that has
        /// none yet, is read again, and a level gone leaves. Returns the
        /// blocks whose body order changed.
        mutating func moveWindows(_ core: NodeCore) -> Set<String> {
            var moved: [(old: [String: Int], new: [String: Int])] = []
            for path in windows.keys where core.levels[path] == nil {
                moved.append((windows.removeValue(forKey: path)?.distances ?? [:], [:]))
            }
            for (path, level) in core.levels where core.touched.contains(path) || windows[path] == nil {
                let window = level.connectOrder
                moved.append((windows.updateValue(window, forKey: path)?.distances ?? [:], window.distances))
            }
            // A block the window left (executed, excluded, or no longer
            // asked for) waits no more.
            if !fetchWaits.isEmpty || !connectWaits.isEmpty {
                connectWaits = connectWaits.filter { windows[$0.key.path]?.distances[$0.key.cid] != nil }
                fetchWaits = fetchWaits.filter { windows[$0.key.path]?.distances[$0.key.cid] != nil }
            }
            return moved.isEmpty
                ? []
                : Self.reorder(&cachedBodyOrder, moved: moved, windows: windows.values.map(\.distances))
        }

        /// After a step's effects: the content budget and the read cache
        /// follow the windows.
        func order(_ reordered: Set<String>) async {
            // The blocks each chain can connect next wait for the content
            // budget ahead of bodies fetched ahead of them. Refreshed only
            // while someone waits: a waiter that arrives between steps is
            // ordered by the last set, and moves up at the next step.
            if remote.budget.waiting > 0 {
                remote.budget.prioritize(Set(windows.values.flatMap(\.next)))
            }
            // Fetched bodies stay in memory in the order their connects
            // need them: the furthest ahead go first when room is needed.
            if !reordered.isEmpty {
                await storage.readCache.order(
                    bodies: reordered.reduce(into: [:]) { $0[$1] = cachedBodyOrder[$1] },
                    leaving: reordered.filter { cachedBodyOrder[$0] == nil }
                )
            }
        }

        /// Fetch the body of `cid` at `path`, unless a fetch of it runs.
        mutating func fetch(_ cid: String, at path: ChainPath, nexusGenesisCID: String, maxBlockSize: Int?) {
            let key = BodyKey(path: path, cid: cid)
            guard bodies[key] == nil else { return }
            let (storage, remote, inputs) = (storage, remote, inputs)
            // Every peer hosts Nexus; a child's body is asked of its
            // hosts (its current peers), then of the root's known
            // providers.
            let rendezvous = ChainHosts.of(path, nexusGenesisCID: nexusGenesisCID)
            // A bundle is an optimisation: a block whose fetch failed is
            // fetched one Volume at a time, as from peers that speak no
            // bundles, so a bad bundle cannot withhold it.
            let bundle = fetchWaits[key] == nil
            let asked = SyncTrace.now()
            // One attempt: the core asks again after its backoff, or
            // at once when the body may now be had.
            bodies[key] = Task {
                do {
                    _ = try await storage.fetchChainBody(
                        cid, remote: remote, bundle: bundle, hosts: rendezvous, maxBlockSize: maxBlockSize
                    )
                    inputs.yield(.bodyStored(path, cid: cid, asked: asked, held: SyncTrace.now()))
                } catch {
                    guard !Task.isCancelled else { return }
                    inputs.yield(.bodyWaiting(path, cid: cid, BodyWait(fetchFailure: error), detail: "\(error)"))
                }
            }
        }

        mutating func cancel(_ cid: String, at path: ChainPath) {
            bodies.removeValue(forKey: BodyKey(path: path, cid: cid))?.cancel()
            fetchWaits[BodyKey(path: path, cid: cid)] = nil
        }

        /// A body is held locally.
        mutating func stored(_ key: BodyKey) {
            bodies[key] = nil
            fetchWaits[key] = nil
        }

        /// A body's fetch failed: false when no fetch of it was running.
        mutating func failed(_ key: BodyKey, _ reason: BodyWait, detail: String) -> Bool {
            guard bodies.removeValue(forKey: key) != nil else { return false }
            wait(key, reason, detail: detail, in: \.fetchWaits)
            return true
        }

        /// A held block's connect ended without a verdict.
        mutating func connectFailed(_ key: BodyKey, _ failure: BlockImportError) {
            wait(key, .notConnected(failure), detail: "\(failure)", in: \.connectWaits)
        }

        /// Record why a block waits. A reason is logged when it changes,
        /// never per retry, with the error behind it: `detail` goes to the
        /// log and nowhere else.
        private mutating func wait(
            _ key: BodyKey, _ reason: BodyWait, detail: String,
            in waits: WritableKeyPath<BodyFetches, [BodyKey: BodyWait]>
        ) {
            guard self[keyPath: waits][key] != reason else { return }
            self[keyPath: waits][key] = reason
            let line = "waiting: body of \(key.cid): \(reason) (\(detail))"
            SyncTrace.log(chain: key.path, line)
            logLine("lattice-node [\(key.path.joined(separator: "/"))] \(line)")
        }

        /// Only the levels in `hosted` keep their fetches and waits.
        mutating func keep(only hosted: Set<ChainPath>) {
            for key in bodies.keys where !hosted.contains(key.path) {
                bodies.removeValue(forKey: key)?.cancel()
            }
            fetchWaits = fetchWaits.filter { hosted.contains($0.key.path) }
            connectWaits = connectWaits.filter { hosted.contains($0.key.path) }
        }

        /// The wait of the block after `tip`, the act-on tip of `level` at
        /// `path`: its heaviest child the window asks for.
        func waiting(at path: ChainPath, level: ChainCore, tip: String) -> NodeReadView.Waiting? {
            guard !fetchWaits.isEmpty || !connectWaits.isEmpty else { return nil }
            // The level's window as its last step left it: one whose parent
            // is the act-on tip is among those to connect next.
            let window = windows[path] ?? level.connectOrder
            return window.next.first { (level.parent(of: $0) ?? "") == tip }.flatMap { cid in
                let key = BodyKey(path: path, cid: cid)
                return (fetchWaits[key] ?? connectWaits[key]).map { NodeReadView.Waiting(cid: cid, reason: $0) }
            }
        }

        /// The bodies at `path` whose last fetch failed.
        func unavailable(at path: ChainPath) -> Int {
            fetchWaits.keys.count(where: { $0.path == path })
        }

        mutating func cancelAll() {
            for task in bodies.values { task.cancel() }
            bodies.removeAll()
        }

        /// Moves the body order (each window block's nearest distance in any
        /// window) with the windows that moved, each from `old` to `new`, and
        /// returns the blocks whose order changed. `windows` are every window
        /// after the moves. A block is looked up across windows only where its
        /// nearest distance may have grown or left; elsewhere the work is the
        /// moved windows' entries.
        static func reorder(
            _ order: inout [String: Int], moved: [(old: [String: Int], new: [String: Int])], windows: [[String: Int]]
        ) -> Set<String> {
            var reordered: Set<String> = []
            var lookUp: Set<String> = []
            for (old, new) in moved {
                for (cid, distance) in new where old[cid] != distance {
                    if order[cid].map({ distance < $0 }) ?? true {
                        order[cid] = distance
                        reordered.insert(cid)
                    } else if order[cid] == old[cid] {
                        lookUp.insert(cid)
                    }
                }
                for (cid, distance) in old where new[cid] == nil && order[cid] == distance {
                    lookUp.insert(cid)
                }
            }
            for cid in lookUp {
                let nearest = windows.compactMap { $0[cid] }.min()
                guard order[cid] != nearest else { continue }
                order[cid] = nearest
                reordered.insert(cid)
            }
            return reordered
        }
    }
}
