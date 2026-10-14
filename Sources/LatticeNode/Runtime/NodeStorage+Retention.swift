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

    /// What a block reads, until it executes, when the operator keeps no
    /// state.
    func reads(_ blockCID: String, at path: ChainPath) -> String {
        chain + ":reads:" + path.joined(separator: "/") + ":" + blockCID
    }

    func body(_ blockCID: String, at path: ChainPath = ["Nexus"]) -> String {
        bodyPrefix + path.joined(separator: "/") + ":" + blockCID
    }

    /// The block a body scope names. A CID holds no colon, so the last one
    /// ends the chain's path.
    func block(named scope: String) -> (path: ChainPath, cid: String)? {
        let name = scope.dropFirst(bodyPrefix.count)
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
    /// the chain. A body root this store lacks refuses the pin whole.
    nonisolated func retainStored(
        _ roots: [String], body: [String], ofBlock blockCID: String, at path: ChainPath = ["Nexus"]
    ) async throws {
        let named = Set(body)
        try await broker.mergeRetainedRoots(scope: scopes.body(blockCID, at: path), roots: named.sorted())
        let scope = switch configuration.state {
        case .all: retentionScope
        case .tip: scopes.state(at: path)
        case .none: scopes.reads(blockCID, at: path)
        }
        try await retainHeld(roots.filter { !named.contains($0) }, scope: scope)
    }

    /// With `state: none`: what a block read goes once it has executed, or
    /// was found invalid.
    nonisolated func releaseReads(_ blockCID: String, at path: ChainPath) async {
        guard configuration.state == .none else { return }
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
    /// any more is let go of. A node of the new state this store lacks (a
    /// move to another branch brings back what was let go of) is read
    /// from peers. If one cannot be read nothing changes, and the next
    /// move starts from the same place.
    nonisolated func keepState(of tip: String, at path: ChainPath, remote: IvyRootContentSource?) async {
        guard configuration.state == .tip else { return }
        do {
            let last = try await store.stateTip(at: path)
            guard last != tip, let root = try await store.blockFact(tip, at: path)?.postStateCID else { return }
            var lastRoot: String?
            if let last { lastRoot = try await store.blockFact(last, at: path)?.postStateCID }
            let walk = TipStateWalk(storage: self, path: path)
            let state = LatticeStateHeader(rawCID: root)
            if let remote {
                try await remote.withRootTracing(root, bundle: false) { session in
                    try await walk.hold(state, fetcher: CoalescingFetcher(CompositeContentSource([broker, session])))
                }.value
            } else {
                try await walk.hold(state, fetcher: localFetcher)
            }
            if let lastRoot { await walk.letGo(LatticeStateHeader(rawCID: lastRoot)) }
            let (entered, left) = try await store.moveStateCounts(at: path, to: tip, changes: try await walk.finish())
            try await retainHeld(entered, scope: scopes.state(at: path))
            try await broker.releaseRetainedRoots(scope: scopes.state(at: path), roots: left)
        } catch {
            syncTrace("state of \(tip) not kept: \(error)")
        }
    }
}

/// One move of the kept state: the counts it read and how it changes them.
private actor TipStateWalk {
    private let storage: NodeStorage
    private let path: ChainPath
    private let storer: NodeImportStorage
    private var counted: [String: Int] = [:]
    private var changes: [String: Int] = [:]

    init(storage: NodeStorage, path: ChainPath) {
        self.storage = storage
        self.path = path
        storer = NodeImportStorage(storage: storage.broker)
    }

    private func count(_ cid: String) async throws -> Int {
        if counted[cid] == nil { counted[cid] = try await storage.store.stateCount(cid, at: path) }
        return (counted[cid] ?? 0) + (changes[cid] ?? 0)
    }

    /// One more node names `header`. A node not counted before is new to
    /// the state: it is stored if this store lacks it, and names its own.
    func hold(_ header: any Header, fetcher: any Fetcher) async throws {
        let named = try await count(header.rawCID)
        changes[header.rawCID, default: 0] += 1
        guard named == 0 else { return }
        let resolved = try await Self.resolved(header, fetcher: fetcher)
        if let volume = resolved as? any Volume, await !storage.broker.hasVolume(root: header.rawCID) {
            try await volume.store(storer: storer)
        }
        for child in NodeStorage.children(of: resolved) { try await hold(child, fetcher: fetcher) }
    }

    /// One node fewer names `header`. A node nothing names any more has
    /// left the state, and no longer names its own.
    func letGo(_ header: any Header) async {
        guard let named = try? await count(header.rawCID), named > 0 else { return }
        changes[header.rawCID, default: 0] -= 1
        guard named == 1, let resolved = try? await Self.resolved(header, fetcher: storage.localFetcher) else { return }
        for child in NodeStorage.children(of: resolved) { await letGo(child) }
    }

    /// What the walk read from peers is stored; the changes to the counts.
    func finish() async throws -> [String: Int] {
        try await storer.commit()
        return changes
    }

    private static func resolved<H: Header>(_ header: H, fetcher: any Fetcher) async throws -> any Header {
        try await header.resolve(fetcher: fetcher)
    }
}
