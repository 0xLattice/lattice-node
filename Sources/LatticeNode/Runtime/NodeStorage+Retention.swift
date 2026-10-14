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
/// - A block's body, its own Volume and its transactions', is pinned under
///   the name of that block on its chain: two blocks that carry one
///   transaction each keep it, and letting go of one block lets go of
///   nothing the other names.
struct RetentionScopes: Sendable {
    let chain: String

    var bodyPrefix: String { chain + ":body:" }

    /// The state of the tip of the chain at `path`, when the operator
    /// keeps no other.
    func state(at path: ChainPath) -> String { chain + ":state:" + path.joined(separator: "/") }

    /// What the last step's executions stored, until the kept state has
    /// counted what of it the tip's state holds.
    func executed(at path: ChainPath) -> String { chain + ":executed:" + path.joined(separator: "/") }

    var readsPrefix: String { chain + ":reads:" }

    /// What a block reads, until it executes, when the operator does not
    /// keep all state.
    func reads(_ blockCID: String, at path: ChainPath) -> String {
        readsPrefix + path.joined(separator: "/") + ":" + blockCID
    }

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
            let scope = scopes.reads(blockCID, at: path)
            let roots = try await broker.retainedRoots(scope: scope)
            guard !roots.isEmpty else { return }
            try await broker.releaseRetainedRoots(scope: scope, roots: roots)
        } catch {
            syncTrace("reads of \(blockCID) not released: \(error)")
        }
    }

    /// Lets go of a block's body. What another block's body or the chain
    /// also names stays.
    nonisolated func releaseBody(_ blockCID: String, at path: ChainPath = ["Nexus"]) async {
        do {
            let scope = scopes.body(blockCID, at: path)
            let roots = try await broker.retainedRoots(scope: scope)
            guard !roots.isEmpty else { return }
            try await broker.releaseRetainedRoots(scope: scope, roots: roots)
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

    // MARK: - State: tip

    /// With `state: tip`: the state kept for the chain at `path` becomes
    /// that of `tip`. A node of the state is named by its content, so one
    /// can be named from several places: each is counted once for every
    /// node of the tip's state that names it. The new state is walked
    /// from its root down to the nodes already counted, and the last one
    /// from its root down to the nodes still named; a node nothing names
    /// any more is let go of. The walk reads this store alone and runs in
    /// the step that stored the tip, so nothing else writes this scope
    /// meanwhile. A node of the new state this store lacks (a move to
    /// another branch brings back what was let go of) is not counted: it
    /// is fetched when a block reads it, and counted when the state that
    /// names it is walked again.
    nonisolated func forgetStateCounts() async {
        do { try await store.forgetStateCounts() } catch { syncTrace("state counts not forgotten: \(error)") }
    }

    nonisolated func keepState(of tip: String, at path: ChainPath) async {
        guard configuration.state == .tip else { return }
        do {
            let last = try await store.stateTip(at: path)
            guard last != tip, let root = try await store.blockFact(tip, at: path)?.postStateCID else { return }
            var lastRoot: String?
            if let last { lastRoot = try await store.blockFact(last, at: path)?.postStateCID }
            let walk = TipStateWalk(storage: self, path: path)
            try await walk.hold(LatticeStateHeader(rawCID: root))
            if let lastRoot { await walk.letGo(LatticeStateHeader(rawCID: lastRoot)) }
            let changes = await walk.changes
            let (entered, left) = try await store.moveStateCounts(at: path, to: tip, changes: changes)
            try await retainHeld(entered, scope: scopes.state(at: path))
            var gone = left
            if last == nil {
                // Counted afresh: what an earlier run left pinned and this
                // state does not hold goes.
                let counted = Set(changes.filter { $0.value > 0 }.keys)
                gone += try await broker.retainedRoots(scope: scopes.state(at: path)).filter { !counted.contains($0) }
            }
            try await broker.releaseRetainedRoots(scope: scopes.state(at: path), roots: gone)
            // What executions stored and the tip's state does not hold goes.
            let executed = try await broker.retainedRoots(scope: scopes.executed(at: path))
            try await broker.releaseRetainedRoots(scope: scopes.executed(at: path), roots: executed)
        } catch {
            syncTrace("state of \(tip) not kept: \(error)")
        }
    }
}

/// One move of the kept state: the counts it read and how it changes them.
private actor TipStateWalk {
    private let storage: NodeStorage
    private let path: ChainPath
    private var counted: [String: Int] = [:]
    private(set) var changes: [String: Int] = [:]

    init(storage: NodeStorage, path: ChainPath) {
        self.storage = storage
        self.path = path
    }

    private func count(_ cid: String) async throws -> Int {
        if counted[cid] == nil { counted[cid] = try await storage.store.stateCount(cid, at: path) }
        return (counted[cid] ?? 0) + (changes[cid] ?? 0)
    }

    /// One more node names `header`. A node not counted before is new to
    /// the state, and names its own; one this store lacks is left out.
    func hold(_ header: any Header) async throws {
        let named = try await count(header.rawCID)
        if named == 0 {
            guard let resolved = try? await Self.resolved(header, fetcher: storage.localFetcher) else { return }
            changes[header.rawCID, default: 0] += 1
            for child in NodeStorage.children(of: resolved) { try await hold(child) }
        } else {
            changes[header.rawCID, default: 0] += 1
        }
    }

    /// One node fewer names `header`. A node nothing names any more has
    /// left the state, and no longer names its own.
    func letGo(_ header: any Header) async {
        guard let named = try? await count(header.rawCID), named > 0 else { return }
        changes[header.rawCID, default: 0] -= 1
        guard named == 1, let resolved = try? await Self.resolved(header, fetcher: storage.localFetcher) else { return }
        for child in NodeStorage.children(of: resolved) { await letGo(child) }
    }

    private static func resolved<H: Header>(_ header: H, fetcher: any Fetcher) async throws -> any Header {
        try await header.resolve(fetcher: fetcher)
    }
}
