import Foundation
import LatticeNodeAPI
import LatticeNodeCore
import LatticeNodeSupport

extension NodeRuntime {
    /// The read model: each level's read view (its act-on chain by height,
    /// pool listing, template digest and sync status) and the root's
    /// template digest, built from the core's levels and what the loop
    /// passes in, and published for RPC. It owns no authoritative state:
    /// everything here is rebuilt from the core. Only the loop touches it.
    struct ReadModel: Sendable {
        let inputs: Inputs
        let templateDigest: PublishedValue<String>
        var views: [ChainPath: NodeReadView] = [:]
        /// Each view's template digest and the tips and pool versions it was
        /// computed from: selection runs only when one of them moves.
        var digests: [ChainPath: (key: String, digest: String)] = [:]
        /// Levels with a `reproject` timer pending.
        var reprojections: Set<ChainPath> = []

        init(inputs: Inputs, templateDigest: PublishedValue<String>) {
            self.inputs = inputs
            self.templateDigest = templateDigest
        }

        /// One level's read view: its act-on chain by height, pool listing
        /// and template digest, published to `output`. `peers` are the
        /// level's current peers, `waiting` the wait of the block after its
        /// act-on tip, `window` its body window, `unavailable` the bodies
        /// whose fetch failed, `jobsQueued` its jobs waiting for a worker.
        mutating func refresh(
            _ path: ChainPath, level: ChainCore, snapshot: ChainSnapshot, core: NodeCore, output: LevelOutput,
            peers: Int, waiting: NodeReadView.Waiting?, window: (next: [String], distances: [String: Int])?,
            unavailable: Int, jobsQueued: Int
        ) {
            var view = views[path] ?? NodeReadView()
            view.children = level.executedChildren
            let tip = (hash: snapshot.actOnTip, height: snapshot.actOnHeight)
            let pool = level.mining.mempool
            // The digest names what a template would carry: a level with a
            // backlog to execute names nothing, and it and every level below
            // it are left out of the root's (`mined`).
            let mined = !level.holdsBacklog
            // A child is mined while neither it nor a level above it holds a
            // backlog or, below the root, its next block (`NodeRuntime
            // .mined`): parents come first, so each level is read once.
            var unmined: Set<ChainPath> = []
            let children = path == core.rootPath && mined
                ? core.ordered.dropFirst().filter { child in
                    guard !unmined.contains(Array(child.dropLast())),
                          core.levels[child].map({ $0.holdsBacklog || $0.holdsNextBlock }) != true else {
                        unmined.insert(child)
                        return false
                    }
                    return true
                }.compactMap { child in
                    core.levels[child].map { (path: child, level: $0, snapshot: $0.snapshot) }
                }
                : []
            let key = ([("", tip.hash, "\(mined)", pool.version)] + children.map {
                ($0.path.joined(separator: "/"), $0.snapshot.actOnTip, "\(!$0.snapshot.bestHeaderTip.isEmpty)",
                 $0.level.mining.mempool.version)
            }).map { "\($0.0):\($0.1)/\($0.2)/\($0.3)" }.joined(separator: "\n")
            let digest: String
            if let cached = digests[path], cached.key == key {
                digest = cached.digest
            } else {
                digest = NodeRuntime.templateDigest(
                    tip: mined ? tip.hash : "", carrying: mined ? level.mining.nextBlock : [],
                    levels: children.map {
                        ($0.path, $0.snapshot.actOnTip, !$0.snapshot.bestHeaderTip.isEmpty, $0.level.mining.nextBlock)
                    }
                )
                digests[path] = (key, digest)
            }
            var sync = NodeSyncStatus()
            // A move of the act-on tip, as this step left it: the first
            // tip a start publishes counts as one.
            sync.tipAdvancedAt = view.actOnTip == tip.hash ? view.sync.tipAdvancedAt
                : tip.hash.isEmpty ? nil : Date().timeIntervalSince1970
            sync.pendingHeaders = level.sync.pending.entries.count
            sync.headersAwaitingProof = level.sync.proofs.awaiting.count
            sync.bodyWindow = window?.distances.count ?? 0
            sync.bodiesRequested = level.bodies.requested.count
            sync.bodiesUnavailable = unavailable
            sync.bodiesParked = level.bodies.parked.count
            sync.awaitingParentFacts = level.bodies.awaitingParent.count
            let parentWeighed = path.count > 1 ? core.levels[Array(path.dropLast())]?.headersSynced ?? true : true
            sync.blockedOn = level.progress(parentWeighed: parentWeighed, next: window?.next).rawValue
            sync.headersSynced = level.headersSynced
            sync.synced = level.synced
            sync.jobsQueued = jobsQueued
            // The fee projection walks the pool, so a busy pool is projected
            // at most once a `projectionInterval`, and at once on a new tip.
            // A change inside the interval is projected when it ends, input
            // or not.
            let now = NodeRuntime.uptime()
            let reproject = view.projectedVersion != pool.version
                && (view.actOnTip != tip.hash || now - view.projectedAt >= NodeRuntime.projectionInterval)
            if view.projectedVersion != pool.version, !reproject, !reprojections.contains(path) {
                reprojections.insert(path)
                let inputs = inputs
                Timers.deadline(
                    after: .milliseconds(NodeRuntime.projectionInterval - (now - view.projectedAt)), generation: 0
                ) { _ in
                    inputs.yield(.reproject(path))
                }
            }
            guard view.actOnTip != tip.hash || view.poolVersion != pool.version
                    || view.templateDigest != digest || view.peers != peers
                    || view.waiting != waiting || view.sync != sync || reproject else { return }
            if view.actOnTip != tip.hash {
                view.actOnTip = tip.hash
                // The act-on chain is the tip's ancestry, on the best header
                // chain or not: walk down to where the view already agrees.
                var entered: [String] = []
                var keep = tip.hash.isEmpty ? 0 : Int(tip.height) + 1
                var cursor: String? = tip.hash
                while keep > 0, let cid = cursor, !(keep <= view.heights.count && view.heights[keep - 1] == cid) {
                    entered.append(cid)
                    cursor = level.parent(of: cid)
                    keep -= 1
                }
                view.heights.truncate(to: keep)
                for cid in entered.reversed() { view.heights.append(cid) }
            }
            if view.poolVersion != pool.version || reproject {
                // A pool holds nothing before its level has a spec, so a
                // projection waits only on the pool.
                let projected = !reproject ? view.mempool.projected : level.mining.spec.map {
                    pool.projectedBlocks(count: ChainReads.projectedFeeBlocks, spec: $0)
                } ?? []
                if reproject {
                    view.projectedVersion = pool.version
                    view.projectedAt = now
                }
                view.mempool = ChainReads.MempoolListing(
                    count: pool.count, bytes: pool.byteCount, cids: pool.items.prefix(200).map(\.cid),
                    projected: projected, weight: level.mining.spec.map(FeeWeight.init)
                )
            }
            view.poolVersion = pool.version
            // The root's digest covers every hosted level: a child's tip or
            // pool moving changes the template a miner should fetch.
            let digestChanged = path == core.rootPath && view.templateDigest != digest
            view.templateDigest = digest
            view.peers = peers
            view.waiting = waiting
            view.sync = sync
            views[path] = view
            output.view.publish(view)
            // After the view: a client told of a digest finds it in status.
            if digestChanged { templateDigest.publish(digest) }
        }

        /// A `reproject` timer fired for `path`.
        mutating func reprojected(_ path: ChainPath) {
            reprojections.remove(path)
        }

        /// A level no longer hosted.
        mutating func drop(_ path: ChainPath) {
            views[path] = nil
            digests[path] = nil
        }
    }
}
