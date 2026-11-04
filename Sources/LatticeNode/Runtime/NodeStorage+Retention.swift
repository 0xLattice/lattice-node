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

/// The retention rules: the only code that decides what this store keeps.
/// Nothing here is needed for the node to be right: content a rule let go
/// of is fetched again by whatever reads it next.
extension NodeStorage {
    nonisolated var scopes: RetentionScopes { RetentionScopes(chain: retentionScope) }

    /// Pins what storing a block wrote: its `body`, the block's own Volume
    /// and its transactions', under the block's name, and the rest, the
    /// state its execution reads, its spec and its policy modules, with
    /// the chain, or with the block until it executes when the operator
    /// does not keep all state. A body root this store lacks refuses the
    /// pin whole.
    nonisolated func retainStored(
        _ roots: [String], body: [String], ofBlock blockCID: String, at path: ChainPath = ["Nexus"]
    ) async throws {
        let named = Set(body)
        try await broker.mergeRetainedRoots(scope: scopes.body(blockCID, at: path), roots: named.sorted())
        let scope = configuration.state == .all ? retentionScope : scopes.reads(blockCID, at: path)
        try await retainHeld(roots.filter { !named.contains($0) }, scope: scope)
    }

    /// At a start: what a block read goes when the block has executed (a
    /// stop came between), or when the operator keeps all state.
    nonisolated func letGoOfReads() async {
        do {
            for scope in try await broker.retainedScopes(prefix: scopes.readsPrefix) {
                guard let (path, cid) = scopes.block(named: scope, after: scopes.readsPrefix) else { continue }
                if configuration.state == .all, let roots = try? await broker.retainedRoots(scope: scope) {
                    try await broker.releaseRetainedRoots(scope: scope, roots: roots)
                } else if try await store.hasExecutedBlock(cid, at: path) {
                    await releaseReads(cid, at: path)
                }
            }
        } catch {
            syncTrace("reads not let go of at start: \(error)")
        }
    }

    /// When the operator does not keep all state: what a block read goes
    /// once it has executed, or was found invalid.
    nonisolated func releaseReads(_ blockCID: String, at path: ChainPath) async {
        guard configuration.state != .all else { return }
        do {
            try await release(scope: scopes.reads(blockCID, at: path))
        } catch {
            syncTrace("reads of \(blockCID) not released: \(error)")
        }
    }

    /// Lets go of a block's body. What another block's body or the chain
    /// also names stays.
    nonisolated func releaseBody(_ blockCID: String, at path: ChainPath = ["Nexus"]) async {
        do {
            try await release(scope: scopes.body(blockCID, at: path))
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
            for scope in try await broker.retainedScopes(prefix: scopes.bodyPrefix) {
                guard let (path, cid) = scopes.block(named: scope), tips[path] != cid,
                      try await store.hasExecutedBlock(cid, at: path) else { continue }
                await letGo(ofBodies: [cid], at: path)
            }
        } catch {
            syncTrace("bodies not let go of at start: \(error)")
        }
    }

    // MARK: - Operator pins

    /// The Volumes the operator pinned.
    nonisolated func operatorPins() async -> [String] {
        (try? await broker.retainedRoots(scope: scopes.operatorPins)) ?? []
    }

    /// Pins the Volume `root` names, already stored or as the operator
    /// provides it in `entries`, each checked against its CID. The node does
    /// not look inside it or follow what it names.
    nonisolated func pin(_ root: String, entries: [String: Data]?) async throws {
        if await !broker.hasVolume(root: root) {
            guard let entries else { throw NodeStorageError.missingMaterializedVolume(root) }
            let volume = SerializedVolume(root: root, entries: entries)
            guard (try? volume.validate()) != nil else { throw NodeStorageError.invalidVolume(root) }
            try await broker.store(volume: volume)
        }
        try await broker.mergeRetainedRoots(scope: scopes.operatorPins, roots: [root])
    }

    /// Unpinning what the operator did not pin changes nothing.
    nonisolated func unpin(_ root: String) async throws {
        guard await operatorPins().contains(root) else { return }
        try await broker.releaseRetainedRoots(scope: scopes.operatorPins, roots: [root])
    }

    /// Lets go of everything `scope` names.
    nonisolated func release(scope: String) async throws {
        let roots = try await broker.retainedRoots(scope: scope)
        if !roots.isEmpty { try await broker.releaseRetainedRoots(scope: scope, roots: roots) }
    }

    // MARK: - State: recent

    /// With a state window: what executions stored at heights more than a
    /// window below `height`, the tip's, goes. On `recent` what the counts
    /// name stays; on `none` what a newer block still names is read from
    /// peers when something reads it.
    nonisolated func letGoOfState(at path: ChainPath, below height: UInt64) async {
        guard let window = configuration.stateWindow(for: path) else { return }
        guard height >= window else { return }
        let kept = scopes.window(at: path, height: height - window + 1)
        do {
            for scope in try await broker.retainedScopes(prefix: scopes.windowPrefix(at: path)) where scope < kept {
                try await release(scope: scope)
            }
        } catch {
            syncTrace("state below \(height) not let go of: \(error)")
        }
    }

    /// When the chain at `path` is no longer hosted: every state window it
    /// kept goes.
    nonisolated func letGoOfWindows(at path: ChainPath) async {
        guard let listed = try? await broker.retainedScopes(prefix: scopes.windowPrefix(at: path)) else { return }
        for scope in listed { await letGoOfWindow(scope) }
    }

    private nonisolated func letGoOfWindow(_ scope: String) async {
        do { try await release(scope: scope) } catch { syncTrace("\(scope) not released: \(error)") }
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
        var (marker, known) = (marker, known)
        for retry in [false, true] {
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
                    (marker, known) = (stored, nil)
                } catch {
                    return .failed("\(error)")
                }
            } catch {
                return Self.outcome(of: error)
            }
        }
        return .resync("the marker changed again")
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
        do {
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

    /// At a start, the check of a chain's counts against the store: the
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
            var expected: [String: Int] = [:]
            try await walkState(tip.postStateCID, into: &expected) { batch in
                let resolved = try await withThrowingTaskGroup(of: (any Header).self) { group in
                    for header in batch { group.addTask { try await header.resolve(fetcher: self.localFetcher) } }
                    return try await group.reduce(into: [any Header]()) { $0.append($1) }
                }
                return Dictionary(resolved.map { ($0.rawCID, Self.children(of: $0)) }) { first, _ in first }
            }
            for cid in chain.dropFirst() {
                guard let fact = try await store.blockFact(cid, at: path) else { return nil }
                for (cid, count) in NodeStore.net(fact.stateDiff).replaced { expected[cid, default: 0] += count }
            }
            let stored = try await broker.countedState(scope: scopes.counted(at: path))
            return stored.marker == marker && stored.counts == expected ? chain : nil
        } catch {
            syncTrace("counts of \(path) not checked: \(error)")
            return nil
        }
    }

    /// The block a state sync of the chain at `path` reads the state of: a
    /// few below `tip` on its chain, so a short reorganization leaves it on
    /// the act-on chain, and within the window, whose scopes still hold
    /// what the blocks above it created.
    nonisolated func countedSyncBlock(at path: ChainPath, below tip: String, window: UInt64) async throws -> CountedMarker.Block {
        guard let block = try await store.ancestor(of: tip, depth: min(6, window / 2), at: path) else {
            throw NodeStorageError.missingBlockFact(tip)
        }
        return block
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
            if let staged = try? await broker.retainedRoots(scope: scope) {
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
        let lacked = Set(try await retainHeld(batch.map(\.rawCID), scope: scope))
        return try await remote.withRootTracing(root, bundle: false, hosts: hosts) { session in
            let fetcher = readersReads(through: session)
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
            if let missed = try await retainHeld(Array(lacked), scope: scope).first {
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
        for root in try await retainHeld(roots, scope: scope) {
            try Task.checkCancellation()
            let read = await remote.withRootTracing(root, bundle: false, hosts: hosts) { session in
                await session.volume(rootCID: root)
            }
            guard let volume = read.value else { throw NodeStorageError.missingMaterializedVolume(root) }
            try await broker.store(volume: volume)
            if let missed = try await retainHeld([root], scope: scope).first {
                throw NodeStorageError.missingMaterializedVolume(missed)
            }
        }
    }

    /// Lets go of what a state sync or a heal of the chain at `path` read:
    /// once the counts name it, or the chain is no longer counted.
    nonisolated func releaseStaging(at path: ChainPath) async {
        do {
            try await release(scope: scopes.staging(at: path))
        } catch {
            syncTrace("staging of \(path) not released: \(error)")
        }
    }

    /// When the chain at `path` is no longer hosted: its counts go, and
    /// what its staging held.
    nonisolated func dropCounted(at path: ChainPath) async {
        do {
            try await broker.dropCountedScope(scope: scopes.counted(at: path))
        } catch {
            syncTrace("counts of \(path) not dropped: \(error)")
        }
        await releaseStaging(at: path)
    }

    /// At a start, with `hosted` the chains this node hosts: the markers of
    /// the hosted chains' counts when the operator keeps recent state, and
    /// the staging of each chain with one let go of (a chain without keeps
    /// it for its state sync). Counts kept for a chain no longer hosted go,
    /// as do every chain's when the operator keeps recent state no more:
    /// on `all` what they counted is kept with the chain first.
    nonisolated func settleCountedScopes(hosted: Set<ChainPath>) async -> [ChainPath: String] {
        func path(_ scope: String, after prefix: String) -> ChainPath {
            scope.dropFirst(prefix.count).split(separator: "/").map(String.init)
        }
        let recent = configuration.state == .recent
        var markers: [ChainPath: String] = [:]
        do {
            for scope in try await broker.countedScopes(prefix: scopes.countedPrefix) {
                let chain = path(scope, after: scopes.countedPrefix)
                guard !recent || !hosted.contains(chain) else { continue }
                if configuration.state == .all, hosted.contains(chain) {
                    try await retainHeld(Array(try await broker.countedState(scope: scope).counts.keys))
                }
                try await broker.dropCountedScope(scope: scope)
            }
            if recent {
                for chain in hosted {
                    let marker = try await broker.countedState(scope: scopes.counted(at: chain)).marker
                    if let marker, CountedMarker(marker) != nil { markers[chain] = marker }
                }
            }
            for scope in try await broker.retainedScopes(prefix: scopes.stagingPrefix) {
                let chain = path(scope, after: scopes.stagingPrefix)
                if markers[chain] != nil || !recent || !hosted.contains(chain) { try await release(scope: scope) }
            }
        } catch {
            syncTrace("counts not settled at start: \(error)")
        }
        return markers
    }

    /// At a start, with `tips` the hosted chains' tip heights: what an
    /// earlier version kept a hosted chain's tip state under moves to the
    /// chain's window at its tip's height, or to the chain on `all`, and
    /// goes from there as any state does, a window later on `recent`; the
    /// counts it kept are forgotten. The state windows of a run that kept
    /// recent state stay: they go by height as the tips move, or are kept
    /// with everything else on `all`. What either kept for a chain no
    /// longer hosted goes.
    nonisolated func moveLegacyState(tips: [ChainPath: UInt64]) async {
        func path(_ scope: String, after prefix: String) -> ChainPath {
            scope.dropFirst(prefix.count).split(separator: "/").map(String.init)
        }
        // Each scope on its own: one that fails stays for the next start,
        // and the rest move.
        func each(_ prefix: String, _ move: (String) async throws -> Void) async {
            guard let listed = try? await broker.retainedScopes(prefix: prefix) else { return }
            for scope in listed {
                do { try await move(scope) } catch { syncTrace("\(scope) not moved at start: \(error)") }
            }
        }
        await each(scopes.windowsPrefix) { scope in
            guard let colon = scope.lastIndex(of: ":") else { return }
            if tips[path(String(scope[..<colon]), after: scopes.windowsPrefix)] == nil {
                await letGoOfWindow(scope)
            }
        }
        for prefix in scopes.legacyStatePrefixes {
            await each(prefix) { scope in
                let path = path(scope, after: prefix)
                if let tip = tips[path] {
                    // What this store no longer holds is not kept: it is
                    // read again, as any state let go of is.
                    var held: [String] = []
                    for root in try await broker.retainedRoots(scope: scope) where await broker.hasVolume(root: root) {
                        held.append(root)
                    }
                    let kept = configuration.stateWindow(for: path) == nil
                        ? retentionScope : scopes.window(at: path, height: tip)
                    if !held.isEmpty { try await broker.mergeRetainedRoots(scope: kept, roots: held) }
                }
                try await release(scope: scope)
            }
        }
        do { try await store.forgetStateCounts() } catch { syncTrace("earlier counts not forgotten: \(error)") }
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
