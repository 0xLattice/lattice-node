import Foundation
import Lattice
import LatticeNodeCore
import VolumeBroker
import cashew

/// The names content is pinned under. A Volume stays while any scope names
/// it, and each scope says why.
///
/// - The chain scope holds what every level's executions read and created
///   (state, specs, policy modules) and the Nexus genesis block.
/// - When the operator does not keep all state, a chain's rules scope holds
///   its spec and the policy modules the spec names, which every block of
///   the chain reads, until it is no longer hosted.
/// - When the operator keeps recent state, a chain's window scopes hold
///   what its last executions stored, and its counted scope (counted
///   roots, not retained ones) every node of its current state and what
///   its last blocks replaced. Its staging scope holds what a state sync
///   or a heal read, until the counts name it.
/// - A block's body, its own Volume and its transactions', is pinned under
///   the name of that block on its chain: two blocks that carry one
///   transaction each keep it, and letting go of one block lets go of
///   nothing the other names.
struct RetentionScopes: Sendable {
    let chain: String

    var bodyPrefix: String { chain + ":body:" }

    /// What the executions of the chain at `path` stored at `height`, when
    /// the operator keeps recent state. Zero-padded, so the scopes of a
    /// chain list in height order.
    func window(at path: ChainPath, height: UInt64) -> String {
        let digits = String(height)
        return windowPrefix(at: path) + String(repeating: "0", count: max(0, 20 - digits.count)) + digits
    }

    func windowPrefix(at path: ChainPath) -> String { windowsPrefix + path.joined(separator: "/") + ":" }

    var windowsPrefix: String { chain + ":window:" }

    /// The counts of the chain at `path`, a counted scope: the places each
    /// node holds in its act-on tip's state, plus those the blocks above
    /// its cursor replaced. Its marker is a `CountedMarker`.
    func counted(at path: ChainPath) -> String { countedPrefix + path.joined(separator: "/") }

    var countedPrefix: String { chain + ":counted:" }

    /// What a state sync or a heal of the chain at `path` read, held until
    /// the counts name it.
    func staging(at path: ChainPath) -> String { stagingPrefix + path.joined(separator: "/") }

    var stagingPrefix: String { chain + ":staging:" }

    /// Scopes earlier versions kept state under: a chain's tip state, and
    /// what its last executions stored.
    var legacyStatePrefixes: [String] { [chain + ":state:", chain + ":executed:"] }

    var readsPrefix: String { chain + ":reads:" }

    /// The spec and policy modules of the chain at `path`, when the
    /// operator does not keep all state.
    func rules(at path: ChainPath) -> String { rulesPrefix + path.joined(separator: "/") }

    var rulesPrefix: String { chain + ":rules:" }

    /// What a block reads, until it executes, when the operator does not
    /// keep all state.
    func reads(_ blockCID: String, at path: ChainPath) -> String {
        readsPrefix + path.joined(separator: "/") + ":" + blockCID
    }

    /// The Volumes the operator named on the private port.
    var operatorPins: String { chain + ":operator" }

    func body(_ blockCID: String, at path: ChainPath = ["Nexus"]) -> String {
        bodyPrefix + path.joined(separator: "/") + ":" + blockCID
    }

    /// The block a body scope names. A CID holds no colon, so the last one
    /// ends the chain's path.
    func block(named scope: String, after prefix: String? = nil) -> (path: ChainPath, cid: String)? {
        let name = scope.dropFirst((prefix ?? bodyPrefix).count)
        guard let colon = name.lastIndex(of: ":") else { return nil }
        return (name[..<colon].split(separator: "/").map(String.init), String(name[name.index(after: colon)...]))
    }
}

/// The retention mechanism: pinning and releasing under the scopes above,
/// and the counts' moves, checks, heals and state syncs. What state is kept
/// under which scope, and when it goes, the state scheme decides
/// (`StateBackend`); bodies and operator pins are decided here. Nothing
/// here is needed for the node to be right: content let go of is fetched
/// again by whatever reads it next.
extension NodeStorage {
    nonisolated var scopes: RetentionScopes { RetentionScopes(chain: retentionScope) }

    /// Pins what storing a block wrote: its `body`, the block's own Volume
    /// and its transactions', under the block's name, and the rest, its
    /// spec and its policy modules (and for a genesis the empty state it
    /// starts from), where the state scheme keeps them
    /// (`StateBackend.keepStored`). A body root this store lacks refuses
    /// the pin whole.
    nonisolated func retainStored(
        _ roots: [String], body: [String], ofBlock blockCID: String, at path: ChainPath = ["Nexus"]
    ) async throws {
        let named = Set(body)
        try await stores.store(at: path).mergeRetainedRoots(scope: scopes.body(blockCID, at: path), roots: named.sorted())
        try await stateBackend.keepStored(roots.filter { !named.contains($0) }, ofBlock: blockCID, at: path)
    }

    /// The spec a block names and the policy modules that spec names, as
    /// `fetcher` reads them.
    nonisolated func rules(ofBlock blockCID: String, fetcher: any Fetcher) async -> Set<String> {
        guard let block = try? await BlockHeader(rawCID: blockCID).resolve(fetcher: fetcher).node else { return [] }
        return await rules(of: block, fetcher: fetcher)
    }

    /// `rules(ofBlock:)` of a block already decoded.
    nonisolated func rules(of block: Block, fetcher: any Fetcher) async -> Set<String> {
        guard let spec = try? await block.spec.resolve(fetcher: fetcher).node else { return [] }
        return Set([block.spec.rawCID] + spec.wasmPolicies.map(\.moduleCID))
    }

    /// What a block read goes (`StateBackend.releaseReads`).
    nonisolated func releaseReads(_ blockCID: String, at path: ChainPath) async {
        do {
            try await release(scope: scopes.reads(blockCID, at: path), at: path)
        } catch {
            syncTrace("reads of \(blockCID) not released: \(error)")
        }
    }

    /// Lets go of a block's body. What another block's body or the chain
    /// also names stays.
    nonisolated func releaseBody(_ blockCID: String, at path: ChainPath = ["Nexus"]) async {
        do {
            try await release(scope: scopes.body(blockCID, at: path), at: path)
        } catch {
            syncTrace("body of \(blockCID) not released: \(error)")
        }
    }

    // MARK: - Block bodies: none

    /// The working set lets go of these bodies: none is its chain's tip or
    /// waits to execute any more, and the operator keeps no others. Every
    /// node holds each chain's genesis block.
    nonisolated func letGo(ofBodies blockCIDs: [String], at path: ChainPath) async {
        guard configuration.blockBodies == .none else { return }
        for cid in blockCIDs {
            guard (try? await store.isGenesis(cid, at: path)) == false else { continue }
            await releaseBody(cid, at: path)
        }
    }

    /// At a start with `none`: lets go of every executed body pinned under
    /// its block's name but each chain's tip.
    nonisolated func letGoOfBodies(except tips: [ChainPath: String]) async {
        guard configuration.blockBodies == .none else { return }
        do {
            for (_, scope) in try await stores.retainedScopes(prefix: scopes.bodyPrefix) {
                guard let (path, cid) = scopes.block(named: scope), tips[path] != cid,
                      try await store.hasExecutedBlock(cid, at: path) else { continue }
                await letGo(ofBodies: [cid], at: path)
            }
        } catch {
            syncTrace("bodies not let go of at start: \(error)")
        }
    }

    // MARK: - Operator pins

    /// The Volumes the operator pinned, kept in the root chain's store
    /// whichever chain's they are.
    nonisolated func operatorPins() async -> [String] {
        (try? await stores.root.retainedRoots(scope: scopes.operatorPins)) ?? []
    }

    /// Pins the Volume `root` names, already stored or as the operator
    /// provides it in `entries`, each checked against its CID. The node does
    /// not look inside it or follow what it names.
    /// One a chain's store holds is copied into the root's, which keeps
    /// every pin.
    nonisolated func pin(_ root: String, entries: [String: Data]?) async throws {
        let broker = stores.root
        if await !broker.hasVolume(root: root) {
            guard let volume = await stores.fetchVolumeLocal(root: root)
                    ?? entries.map({ SerializedVolume(root: root, entries: $0) }) else {
                throw NodeStorageError.missingMaterializedVolume(root)
            }
            guard let validated = try? ValidatedVolume(validating: volume) else { throw NodeStorageError.invalidVolume(root) }
            try await broker.storeVolumesLocal([validated])
        }
        try await broker.mergeRetainedRoots(scope: scopes.operatorPins, roots: [root])
    }

    /// Unpinning what the operator did not pin changes nothing.
    nonisolated func unpin(_ root: String) async throws {
        guard await operatorPins().contains(root) else { return }
        try await stores.root.releaseRetainedRoots(scope: scopes.operatorPins, roots: [root])
    }

    // MARK: - Chains the configuration does not host

    /// With `hosted` what the configuration hosts (a chain that failed to
    /// start among them): every other chain this node holds anything of
    /// has its data let go of; hosting it again syncs it from peers like
    /// any new chain. The configuration is the record: a release a stop or
    /// a failure cuts short leaves the chain's facts, and the next call,
    /// at the latest the next start, finishes it. Returns the chains not
    /// let go of (logged).
    @discardableResult
    nonisolated func letGoOfChains(except hosted: Set<ChainPath>) async -> [ChainPath] {
        let held: Set<ChainPath>
        do {
            held = try await store.chainPaths().union(stores.byChain.map(\.path))
        } catch {
            logLine("lattice-node: chains not hosted not let go of, tried again at the next start: \(error)")
            return []
        }
        var failed: [ChainPath] = []
        // Deepest first: a chain's facts outlive those of the chains under it.
        for path in held.subtracting(hosted).sorted(by: { $0.count > $1.count }) where await !letGo(ofChain: path) {
            failed.append(path)
        }
        // A store no fact names (a chain that never journaled, or one whose
        // facts went after its store did): removed too.
        stores.removeFiles(except: hosted.union(failed))
        return failed
    }

    /// Everything kept only for the chain at `path` goes, content first:
    /// its Volume store, with every body, read, window, rule, count and
    /// staged node it held; its local and pooled transactions (pinned in
    /// the root's store) and its blocks' cached bundles; then its facts, in
    /// one transaction. What another chain needs is in that chain's own
    /// store, and the operator's pins in the root's. A fact naming content
    /// that is gone is no fault: it is read again from peers
    /// (NODE-STORAGE-002.f), so a release cut short leaves a store the
    /// node runs on, and its facts name the chain for the next try. False,
    /// logged, when it failed.
    private nonisolated func letGo(ofChain path: ChainPath) async -> Bool {
        let chain = path.joined(separator: "/")
        do {
            stores.remove(at: path)
            for item in try await localTransactions() where item.transaction.body.node?.chainPath == path {
                try await removeLocalTransaction(item.transactionCID)
            }
            try await releaseLivePool(of: path)
            try bundles.forget(try await store.ownBlocks(path))
            let blocks = try await store.forget(path)
            logLine("lattice-node: \(chain) is not hosted: let go of its data (\(blocks) blocks)")
            return true
        } catch {
            logLine("lattice-node: \(chain) is not hosted, and its data was not let go of; tried again at the next start: \(error)")
            return false
        }
    }

    /// Lets go of everything `scope` names in `broker`.
    nonisolated func release(scope: String, in broker: DiskBroker) async throws {
        let roots = try await broker.retainedRoots(scope: scope)
        if !roots.isEmpty { try await broker.releaseRetainedRoots(scope: scope, roots: roots) }
    }

    /// Lets go of everything `scope` names in the store of the chain at
    /// `path`; nothing when that store is not open (the chain is not
    /// hosted).
    nonisolated func release(scope: String, at path: ChainPath) async throws {
        guard let broker = stores.opened(at: path) else { return }
        try await release(scope: scope, in: broker)
    }

    // MARK: - State: recent

    /// With a state window of `window` blocks: what executions stored at
    /// heights more than a window below `height`, the tip's, goes, in one
    /// commit however many heights that is, and their state diffs. On
    /// `recent` what the counts name stays; on `none` what a newer block
    /// still names is read from peers when something reads it.
    nonisolated func letGoOfState(at path: ChainPath, below height: UInt64, window: UInt64) async {
        guard height >= window else { return }
        let kept = scopes.window(at: path, height: height - window + 1)
        do {
            let broker = try stores.store(at: path)
            try await broker.releaseRetainedScopes(
                try await broker.retainedScopes(prefix: scopes.windowPrefix(at: path)).filter { $0 < kept }
            )
            try await store.dropStateDiffs(at: path, below: height - window + 1)
        } catch {
            syncTrace("state below \(height) not let go of: \(error)")
        }
    }

    nonisolated func letGoOfWindow(_ scope: String, in broker: DiskBroker) async {
        do { try await release(scope: scope, in: broker) } catch { syncTrace("\(scope) not released: \(error)") }
    }

    // MARK: - State: the whole current state, on recent

    /// Moves the counts of the chain at `path` from `marker` to `tip`, its
    /// act-on block, in one adjustment under the marker: every node of the
    /// tip's state is counted for each place it holds, and every node the
    /// blocks above the cursor replaced for each place it lost, the cursor
    /// a window below the tip, or where it was if that is higher. `known`
    /// is the chain the last move returned. A marker that is not the
    /// store's is read again from the store and the move tried once more
    /// from it.
    nonisolated func settleCounted(
        at path: ChainPath, tip: String, window: UInt64, marker: String, known: [String]?
    ) async -> CountedOutcome {
        let broker: DiskBroker
        do { broker = try stores.store(at: path) } catch { return .failed("\(error)") }
        var (marker, known, retry) = (marker, known, false)
        while true {
            guard let counted = CountedMarker(marker) else { return .resync("marker \(marker) unreadable") }
            let change: CountedChange
            do {
                guard let found = try await store.countedChange(at: path, from: counted, to: tip, window: window, known: known) else {
                    return .resync("\(counted.cursor.cid) at \(counted.cursor.height) is not below \(tip) on its chain")
                }
                change = found
            } catch {
                return .failed("\(error)")
            }
            guard change.marker != counted else { return .settled(marker, known: change.known) }
            do {
                try await broker.adjustCountedRoots(
                    scope: scopes.counted(at: path), deltas: change.deltas, marker: change.marker.text, expectedMarker: marker
                )
                return .settled(change.marker.text, known: change.known)
            } catch BrokerError.countedMarkerMismatch where !retry {
                do {
                    guard let stored = try await broker.countedState(scope: scopes.counted(at: path)).marker else {
                        return .resync("no marker")
                    }
                    (marker, known, retry) = (stored, nil, true)
                } catch {
                    return .failed("\(error)")
                }
            } catch {
                return Self.outcome(of: error)
            }
        }
    }

    /// Makes the counts of the chain at `path` those of the state of
    /// `block` a state sync read, `places`, moved on to `tip`: in one
    /// adjustment, the difference from the counts there are, under the
    /// marker read with them.
    nonisolated func commitCounted(
        at path: ChainPath, block: CountedMarker.Block, places: [String: Int], tip: String, window: UInt64
    ) async -> CountedOutcome {
        let current: (marker: String?, counts: [String: Int])
        let change: CountedChange
        let broker: DiskBroker
        do {
            broker = try stores.store(at: path)
            current = try await broker.countedState(scope: scopes.counted(at: path))
            guard let found = try await store.countedChange(
                at: path, from: CountedMarker(cursor: block, tip: block), to: tip, window: window, known: [block.cid]
            ) else {
                return .resync("\(block.cid) at \(block.height) is not below \(tip) on its chain")
            }
            change = found
        } catch {
            return .failed("\(error)")
        }
        var deltas = places
        for (root, count) in current.counts { deltas[root, default: 0] -= count }
        for (root, count) in change.deltas { deltas[root, default: 0] += count }
        do {
            try await broker.adjustCountedRoots(
                scope: scopes.counted(at: path), deltas: deltas.filter { $0.value != 0 },
                marker: change.marker.text, expectedMarker: current.marker
            )
            return .settled(change.marker.text, known: change.known)
        } catch {
            return Self.outcome(of: error)
        }
    }

    private static func outcome(of error: any Error) -> CountedOutcome {
        switch error as? BrokerError {
        case .countedRootsMissing(let roots): .missing(roots)
        case .countedMarkerMismatch, .negativeCount, .countedRootOverflow: .resync("\(error)")
        default: .failed("\(error)")
        }
    }

    /// The check of a chain's counts against the store: the
    /// places of the state of the marker's tip, walked from this store
    /// alone, plus what the blocks above the cursor replaced. Returns the
    /// counts' chain when they match; nil when they do not, a node of the
    /// state is not held, or the check could not be made: then a state sync
    /// replaces them.
    nonisolated func auditCounted(at path: ChainPath, marker: String) async -> [String]? {
        do {
            guard let counted = CountedMarker(marker),
                  let tip = try await store.blockFact(counted.tip.cid, at: path),
                  let chain = try await store.chain(from: counted.tip, down: counted.cursor, at: path) else { return nil }
            // The counts are their chain's store's: the walk reads that
            // store alone, not even its ancestors'.
            let own = CoalescingFetcher(try stores.store(at: path))
            var expected: [String: Int] = [:]
            try await walkState(tip.postStateCID, into: &expected) { batch in
                let resolved = try await withThrowingTaskGroup(of: (any Header).self) { group in
                    for header in batch { group.addTask { try await header.resolve(fetcher: own) } }
                    return try await group.reduce(into: [any Header]()) { $0.append($1) }
                }
                return Dictionary(resolved.map { ($0.rawCID, Self.children(of: $0)) }) { first, _ in first }
            }
            for cid in chain.dropFirst() {
                guard let diff = try await store.stateDiff(cid, at: path) else { return nil }
                for (cid, count) in NodeStore.net(diff).replaced { expected[cid, default: 0] += count }
            }
            let stored = try await stores.store(at: path).countedState(scope: scopes.counted(at: path))
            return stored.marker == marker && stored.counts == expected ? chain : nil
        } catch {
            syncTrace("counts of \(path) not checked: \(error)")
            return nil
        }
    }

    /// The block a state sync of the chain at `path` reads the state of: a
    /// few below `tip` on its chain, so a short reorganization leaves it on
    /// the act-on chain, and within the window, whose scopes still hold
    /// what the blocks above it created. The counts move on from it to the
    /// tip with the diffs of the blocks above it; when one is not kept (a
    /// block executed before the node kept diffs, or one whose window went),
    /// it is the tip itself, whose state needs no diff to reach it: snap
    /// sync's pivot at the head.
    nonisolated func countedSyncBlock(at path: ChainPath, below tip: String, window: UInt64) async throws -> CountedMarker.Block {
        guard let top = try await store.ancestor(of: tip, depth: 0, at: path),
              let block = try await store.ancestor(of: tip, depth: min(6, window / 2), at: path) else {
            throw NodeStorageError.missingBlockFact(tip)
        }
        let follows = try await store.countedChange(
            at: path, from: CountedMarker(cursor: block, tip: block), to: tip, window: window, known: [block.cid]
        ) != nil
        return follows ? block : top
    }

    /// The state sync of the chain at `path`: every node of the state of
    /// `block`, with each place it holds there. Each is pinned under the
    /// chain's staging scope as it is visited, what this store lacks read
    /// from peers and stored as its own Volume, checked against its CID, as
    /// an execution stores what it loaded. Nothing is kept in memory but
    /// the counts and one depth of the tree at a time. A sync that fails
    /// lets go of what staging holds beyond what it reached, so staging
    /// never grows past one attempt.
    nonisolated func syncCountedState(
        at path: ChainPath, block: CountedMarker.Block, remote: IvyRootContentSource
    ) async throws -> [String: Int] {
        guard let fact = try await store.blockFact(block.cid, at: path) else {
            throw NodeStorageError.missingBlockFact(block.cid)
        }
        let root = fact.postStateCID
        let hosts = ChainHosts.of(path, nexusGenesisCID: configuration.nexusGenesisCID)
        var places: [String: Int] = [:]
        do {
            try await walkState(root, into: &places) { batch in
                try await stage(batch, of: root, at: path, hosts: hosts, remote: remote)
            }
        } catch {
            let scope = scopes.staging(at: path)
            if let broker = stores.opened(at: path), let staged = try? await broker.retainedRoots(scope: scope) {
                let unreached = staged.filter { places[$0] == nil }
                if !unreached.isEmpty { _ = try? await broker.releaseRetainedRoots(scope: scope, roots: unreached) }
            }
            throw error
        }
        return places
    }

    /// Walks the state whose root is `root` one depth at a time, adding to
    /// `places` the places each node holds; `read` gives the nodes each node
    /// of a batch names. A node in places at two depths is read at each.
    private nonisolated func walkState(
        _ root: String, into places: inout [String: Int],
        read: ([any Header]) async throws -> [String: [any Header]]
    ) async throws {
        var depth: [String: (header: any Header, places: Int)] = [root: (LatticeStateHeader(rawCID: root), 1)]
        while !depth.isEmpty {
            let nodes = Array(depth.values)
            depth = [:]
            for start in stride(from: 0, to: nodes.count, by: 256) {
                try Task.checkCancellation()
                let batch = nodes[start..<min(start + 256, nodes.count)]
                let named = try await read(batch.map(\.header))
                for (header, count) in batch {
                    places[header.rawCID, default: 0] += count
                    for child in named[header.rawCID] ?? [] { depth[child.rawCID, default: (child, 0)].places += count }
                }
            }
        }
    }

    /// One batch of a state sync, in one session: what this store holds is
    /// pinned under the staging scope first, so nothing lets go of it
    /// meanwhile; the rest is read, stored and pinned. Returns the nodes
    /// each one names; throws when one could not be read or pinned.
    private nonisolated func stage(
        _ batch: [any Header], of root: String, at path: ChainPath, hosts: ChainHosts?, remote: IvyRootContentSource
    ) async throws -> [String: [any Header]] {
        let scope = scopes.staging(at: path)
        let broker = try stores.store(at: path)
        let lacked = Set(try await retainHeld(batch.map(\.rawCID), scope: scope, in: broker))
        return try await remote.withRootTracing(root, bundle: false, hosts: hosts) { session in
            let fetcher = readersReads(through: session, at: path)
            let resolved = try await withThrowingTaskGroup(of: (any Header).self) { group in
                for header in batch { group.addTask { try await header.resolve(fetcher: fetcher) } }
                return try await group.reduce(into: [any Header]()) { $0.append($1) }
            }
            let storage = NodeImportStorage(storage: broker)
            for header in resolved where lacked.contains(header.rawCID) {
                guard let volume = header as? any Volume else { continue }
                try await volume.store(storer: storage)
            }
            try await storage.commit()
            if let missed = try await retainHeld(Array(lacked), scope: scope, in: broker).first {
                throw NodeStorageError.missingMaterializedVolume(missed)
            }
            return Dictionary(resolved.map { ($0.rawCID, Self.children(of: $0)) }) { first, _ in first }
        }.value
    }

    /// The heal: the roots an adjustment found this store lacks, read from
    /// peers, each checked against its CID, stored, and pinned under the
    /// chain's staging scope until the counts name them.
    nonisolated func healCounted(_ roots: [String], at path: ChainPath, remote: IvyRootContentSource) async throws {
        let scope = scopes.staging(at: path)
        let hosts = ChainHosts.of(path, nexusGenesisCID: configuration.nexusGenesisCID)
        let broker = try stores.store(at: path)
        for root in try await retainHeld(roots, scope: scope, in: broker) {
            try Task.checkCancellation()
            let read = await remote.withRootTracing(root, bundle: false, hosts: hosts) { session in
                await session.volume(rootCID: root)
            }
            guard let volume = read.value else { throw NodeStorageError.missingMaterializedVolume(root) }
            // The session holds only what it checked on receipt.
            try await broker.storeVolumesLocal([try ValidatedVolume(trusting: volume)])
            if let missed = try await retainHeld([root], scope: scope, in: broker).first {
                throw NodeStorageError.missingMaterializedVolume(missed)
            }
        }
    }

    /// Lets go of what a state sync or a heal of the chain at `path` read:
    /// once the counts name it, or the chain is no longer counted.
    nonisolated func releaseStaging(at path: ChainPath) async {
        do {
            try await release(scope: scopes.staging(at: path), at: path)
        } catch {
            syncTrace("staging of \(path) not released: \(error)")
        }
    }

}

/// Where a settle of a chain's counts left them.
enum CountedOutcome: Sendable {
    /// Moved, or already where they belong: their marker now, and the
    /// blocks from the cursor up to the tip.
    case settled(String, known: [String])
    /// Refused whole: these roots would be counted and this store lacks
    /// them. A heal reads them, then the settle runs again.
    case missing([String])
    /// The counts cannot follow the tip, or the store refused them as they
    /// are: a state sync replaces them.
    case resync(String)
    /// The store failed: nothing changed, and the next settle tries again.
    case failed(String)
}
