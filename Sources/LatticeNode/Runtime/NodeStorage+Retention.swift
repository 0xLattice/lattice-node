import Foundation
import Ivy
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
///   what its last executions stored, and its current scope the whole
///   state of the block a window below its tip.
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

    /// Every node of the state of the block a window below the tip of the
    /// chain at `path`, when the operator keeps recent state: with the
    /// chain's windows, its whole current state.
    func current(at path: ChainPath) -> String { currentPrefix + path.joined(separator: "/") }

    var currentPrefix: String { chain + ":current:" }

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

    /// With a state window: what executions stored at `height` or below
    /// goes, the caller saying how far: a window below the tip, and on
    /// `recent` no further than the chain's counts have reached, so what of
    /// it is still in the state is in the current scope by then. On `none`
    /// it is read from peers when something reads it.
    nonisolated func letGoOfState(at path: ChainPath, through height: UInt64) async {
        let kept = scopes.window(at: path, height: height + 1)
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

    /// The block whose state the chain's current scope holds; nil before
    /// a walk of it completed.
    nonisolated func currentStateCursor(at path: ChainPath) async -> (height: UInt64, block: String)? {
        do {
            return try await store.currentStateCursor(at: path)
        } catch {
            syncTrace("current state cursor of \(path) not read: \(error)")
            return nil
        }
    }

    /// Moves the chain's current state from the block `cursor` names up
    /// `blocks`, the act-on chain's blocks at the heights after it, in
    /// order, as each leaves the window: each block's state diff moves the
    /// count of each node's places, a node whose count was 0 joins the
    /// current scope (its window still holds it), and one whose count
    /// reaches 0 goes from it. The pins first, then the counts and the
    /// cursor: a stop between them is repaired by doing it again. False,
    /// writing no counts, when the counts are in doubt: a fact is missing,
    /// a count would go below 0, a node joining is not held, or the store
    /// failed. The caller walks the state then.
    nonisolated func moveCurrentState(
        at path: ChainPath, up blocks: [String], from cursor: (height: UInt64, block: String)
    ) async -> Bool {
        guard let last = blocks.last else { return true }
        do {
            var change: [String: Int] = [:]
            for block in blocks {
                guard let fact = try await store.blockFact(block, at: path) else {
                    syncTrace("current state of \(path) not moved: no fact of \(block)")
                    return false
                }
                for (cid, count) in fact.stateDiff.created { change[cid, default: 0] += count }
                for (cid, count) in fact.stateDiff.replaced { change[cid, default: 0] -= count }
            }
            let held = try await store.currentStateCounts(change.keys.filter { change[$0] != 0 }, at: path)
            var (counts, entered, left): ([String: Int], [String], [String]) = ([:], [], [])
            for (cid, was) in held {
                let now = was + change[cid, default: 0]
                guard now >= 0 else {
                    syncTrace("current state of \(path) not moved: \(cid) would hold \(now) places")
                    return false
                }
                counts[cid] = now
                if was == 0, now > 0 { entered.append(cid) }
                if was > 0, now == 0 { left.append(cid) }
            }
            let scope = scopes.current(at: path)
            let missed = try await retainHeld(entered, scope: scope)
            guard missed.isEmpty else {
                syncTrace("current state of \(path) not moved: \(missed.count) joining nodes not held")
                return false
            }
            if !left.isEmpty { try await broker.releaseRetainedRoots(scope: scope, roots: left) }
            try await store.writeCurrentState(
                at: path, counts: counts, cursor: (cursor.height + UInt64(blocks.count), last)
            )
            return true
        } catch {
            syncTrace("current state of \(path) not moved past \(cursor.height): \(error)")
            return false
        }
    }

    /// Makes the state of `block`, the act-on chain's at `height`, the
    /// chain's current state: every node reachable from its post-state,
    /// each place it holds counted. The counts are forgotten first, so
    /// none are trusted until the walk completes. What this store lacks is
    /// read through peers, not kept in memory, and stored as its own
    /// Volume, as an execution stores what it loaded. Each node is pinned
    /// under the chain's current scope as it is reached, and what the
    /// scope named that this walk did not reach goes. True when every node
    /// was reached and the counts and the block are written; false when a
    /// node could not be read, its subtree left for the next walk.
    nonisolated func walkCurrentState(
        at path: ChainPath, block: String, height: UInt64, remote: IvyRootContentSource
    ) async -> Bool {
        let scope = scopes.current(at: path)
        do {
            try await store.forgetCurrentState(at: path)
            guard let bytes = await blockNodeBytes(block), let root = Block(data: bytes)?.postState.rawCID else {
                syncTrace("current state of \(path) not walked: \(block) is not held")
                return false
            }
            let hosts = ChainHosts.of(path, nexusGenesisCID: configuration.nexusGenesisCID)
            var counts: [String: Int] = [:]
            var whole = true
            // One depth at a time: each node at it, with the places it holds
            // there.
            var depth: [String: (header: any Header, places: Int)] = [root: (LatticeStateHeader(rawCID: root), 1)]
            while !depth.isEmpty {
                let nodes = Array(depth.values)
                depth = [:]
                for start in stride(from: 0, to: nodes.count, by: 256) {
                    try Task.checkCancellation()
                    let batch = nodes[start..<min(start + 256, nodes.count)]
                    let (named, read) = try await walk(batch.map(\.header), of: root, hosts: hosts, remote: remote, scope: scope)
                    whole = whole && read
                    for (header, places) in batch {
                        guard let children = named[header.rawCID] else { continue }
                        counts[header.rawCID, default: 0] += places
                        for child in children { depth[child.rawCID, default: (child, 0)].places += places }
                    }
                }
            }
            let stale = try await broker.retainedRoots(scope: scope).filter { counts[$0] == nil }
            if !stale.isEmpty { try await broker.releaseRetainedRoots(scope: scope, roots: stale) }
            guard whole else {
                syncTrace("current state of \(path) at \(height) not walked whole")
                return false
            }
            try await store.writeCurrentState(at: path, counts: counts, cursor: (height, block), replacing: true)
            return true
        } catch {
            syncTrace("current state of \(path) at \(height) not walked: \(error)")
            return false
        }
    }

    /// One batch of a walk, in one session: what this store holds is
    /// pinned under `scope` first, so nothing lets go of it meanwhile; the
    /// rest is read and stored, and then every node read is pinned.
    /// Returns the nodes each pinned node names, and whether every node of
    /// the batch was read and pinned.
    private nonisolated func walk(
        _ batch: [any Header], of root: String, hosts: ChainHosts?, remote: IvyRootContentSource, scope: String
    ) async throws -> (named: [String: [any Header]], whole: Bool) {
        try await retainHeld(batch.map(\.rawCID), scope: scope)
        return try await remote.withRootTracing(root, bundle: false, hosts: hosts) { session in
            let fetcher = readersReads(through: session)
            let resolved = await withTaskGroup(of: (any Header)?.self) { group in
                for header in batch { group.addTask { try? await header.resolve(fetcher: fetcher) } }
                return await group.reduce(into: [any Header]()) { if let header = $1 { $0.append(header) } }
            }
            let storage = NodeImportStorage(storage: broker)
            for header in resolved {
                guard await !broker.hasVolume(root: header.rawCID), let volume = header as? any Volume else { continue }
                try await volume.store(storer: storage)
            }
            try await storage.commit()
            let missed = Set(try await retainHeld(resolved.map(\.rawCID), scope: scope))
            var named: [String: [any Header]] = [:]
            for header in resolved where !missed.contains(header.rawCID) {
                named[header.rawCID] = Self.children(of: header)
            }
            return (named, resolved.count == batch.count && missed.isEmpty)
        }.value
    }

    /// When the chain at `path` is no longer hosted: its current state
    /// goes, and its counts are forgotten.
    nonisolated func letGoOfCurrentState(at path: ChainPath) async {
        do {
            try await store.forgetCurrentState(at: path)
            try await release(scope: scopes.current(at: path))
        } catch {
            syncTrace("current state of \(path) not let go of: \(error)")
        }
    }

    /// At a start: the current state a chain was kept under goes when the
    /// chain is no longer hosted or the operator no longer keeps recent
    /// state, kept with the chain on `all`; its counts are forgotten.
    nonisolated func settleCurrentState(hosted: Set<ChainPath>) async {
        do {
            if configuration.state != .recent { try await store.forgetCurrentState(at: nil) }
            for scope in try await broker.retainedScopes(prefix: scopes.currentPrefix) {
                let path = scope.dropFirst(scopes.currentPrefix.count).split(separator: "/").map(String.init)
                if configuration.state == .recent, hosted.contains(path) { continue }
                if configuration.state == .all, hosted.contains(path) {
                    try await retainHeld(try await broker.retainedRoots(scope: scope))
                }
                await letGoOfCurrentState(at: path)
            }
        } catch {
            syncTrace("current state not settled at start: \(error)")
        }
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
