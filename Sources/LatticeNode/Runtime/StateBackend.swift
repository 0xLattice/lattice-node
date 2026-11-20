import Foundation
import LatticeNodeCore
import VolumeBroker

/// What the node does with executed state, behind one interface: keep what
/// a block's storing and execution stored, let go of what a block read once
/// it executed, move with each chain's act-on tip, bring the current state
/// into reach after a start, and let go of a chain no longer hosted. The
/// operator's `state` setting (all, recent, none) is its `scheme`, read from
/// the configuration, which does not change while the store is open
/// (`NodeStorage.stateBackend` builds one on each access). The write paths'
/// and the store's choices by scheme are made here; the loop's `Retention`
/// and `Counts` ask it whether to settle, count or hold back (`keepsAll`,
/// `counts`, `window(for:)`). The mechanism under it is the counted
/// scopes'; a different one (geth's path scheme, say) would change this
/// type, `Counts`, `Retention.settleState` and the scope-to-roots map the
/// write path takes from `keepExecuted`. Reads stay on the store's fetchers.
///
/// The schemes, over the scopes `RetentionScopes` names:
///
/// - `all`: everything executions stored, and the specs and policy modules
///   blocks read, stay with the chain.
/// - `recent`: what executions stored stays in a window scope per height
///   until the tip is a window above; the counts name every node of each
///   chain's current state and move with the tip; a block's reads are kept
///   until it executes; a chain's rules while it is hosted.
/// - `none`: as `recent` with a window of one block and no counts.
///
/// Block bodies and operator pins are beside it, not in it: they are
/// content the node serves or promised to keep, whatever it keeps of state.
struct StateBackend: Sendable {
    let storage: NodeStorage
    let scheme: StateRetention

    init(storage: NodeStorage) {
        self.storage = storage
        scheme = storage.configuration.state
    }

    /// The blocks of the chain at `path` whose executions' state is kept,
    /// counting its tip: nil when every state is.
    func window(for path: ChainPath) -> UInt64? {
        storage.configuration.stateWindow(for: path)
    }

    /// Whether each chain's current state is counted (`recent`).
    var counts: Bool { scheme == .recent }

    /// Whether every state executions stored is kept, so nothing moves with
    /// the tip.
    var keepsAll: Bool { scheme == .all }

    // MARK: - Apply: what a block's storing and execution stored

    /// Whether the facts keep each executed block's state diff, which the
    /// counts move by.
    var keepsStateDiffs: Bool { scheme == .recent }

    /// Where what one level's executions stored is kept, by scope, in the
    /// persist's own transaction: `produced`, each with the height of the
    /// block that produced it, and `specs`, a child genesis's spec, which
    /// stays with the chain.
    func keepExecuted(
        _ produced: [(height: UInt64?, roots: [String])], specs: [String], at path: ChainPath
    ) async throws -> [String: [String]] {
        switch scheme {
        case .all:
            return [storage.retentionScope: produced.flatMap(\.roots) + specs]
        case .recent, .none:
            // With recent state kept, or none: the state each level's
            // executions stored, each under the height of the block that
            // produced it (a batch's blocks keep their own windows). A state
            // no block fact of the step names (none does today) joins the
            // chain's newest window below.
            var retaining: [String: [String]] = [storage.retentionScope: specs]
            for state in produced where !state.roots.isEmpty {
                // A state of no known height goes with the newest the chain
                // keeps: kept as long as that, never let go of before it.
                let scope = if let height = state.height {
                    storage.scopes.window(at: path, height: height)
                } else {
                    try await storage.stores.store(at: path).retainedScopes(prefix: storage.scopes.windowPrefix(at: path)).max()
                        ?? storage.scopes.window(at: path, height: 0)
                }
                retaining[scope, default: []] += state.roots
            }
            return retaining
        }
    }

    /// Pins what storing a block wrote beside its body: its spec and policy
    /// modules (and for a genesis the empty state it starts from), as
    /// `rest`. With all state kept, with the chain; otherwise the spec and
    /// policy modules with the chain at `path` while it is hosted, and any
    /// state with the block until it executes.
    func keepStored(_ rest: [String], ofBlock blockCID: String, at path: ChainPath) async throws {
        let store = try storage.stores.store(at: path)
        guard scheme != .all else {
            try await storage.retainHeld(rest, in: store)
            return
        }
        let rules = rest.isEmpty ? [] : await storage.rules(ofBlock: blockCID, fetcher: storage.localFetcher(.chain(path)))
        try await storage.retainHeld(rest.filter(rules.contains), scope: storage.scopes.rules(at: path), in: store)
        try await storage.retainHeld(rest.filter { !rules.contains($0) }, scope: storage.scopes.reads(blockCID, at: path), in: store)
    }

    /// Where a block a connect found valid keeps what is neither its body
    /// nor its parent's state, `rest`, of which `rules` are its spec and
    /// policy modules: with the chain when all state is kept, else only its
    /// rules, with the chain at `path` while it is hosted.
    func keepWithValidBlock(
        _ rest: Set<String>, rules: Set<String>, at path: ChainPath
    ) -> (scope: String, roots: Set<String>) {
        scheme == .all ? (storage.retentionScope, rest) : (storage.scopes.rules(at: path), rest.intersection(rules))
    }

    // MARK: - Reads

    /// What a block read goes once it has executed, or was found invalid,
    /// when the operator does not keep all state.
    func releaseReads(_ blockCID: String, at path: ChainPath) async {
        guard scheme != .all else { return }
        await storage.releaseReads(blockCID, at: path)
    }

    // MARK: - Moving with the tip

    /// What executions of the chain at `path` stored more than a window
    /// below `height`, the tip's, goes, with their state diffs.
    func letGo(at path: ChainPath, below height: UInt64) async {
        guard let window = window(for: path) else { return }
        await storage.letGoOfState(at: path, below: height, window: window)
    }

    /// Moves the counts of the chain at `path` from `marker` to `tip`
    /// (`NodeStorage.settleCounted`).
    func moveCounts(at path: ChainPath, tip: String, window: UInt64, marker: String, known: [String]?) async -> CountedOutcome {
        await storage.settleCounted(at: path, tip: tip, window: window, marker: marker, known: known)
    }

    /// Commits a state sync's counts moved on to `tip`
    /// (`NodeStorage.commitCounted`).
    func commitCounts(
        at path: ChainPath, block: CountedMarker.Block, places: [String: Int], tip: String, window: UInt64
    ) async -> CountedOutcome {
        await storage.commitCounted(at: path, block: block, places: places, tip: tip, window: window)
    }

    /// What a state sync or heal read is counted now.
    func releaseStaging(at path: ChainPath) async {
        await storage.releaseStaging(at: path)
    }

    // MARK: - Bringing the current state into reach

    /// A state sync of the chain at `path` below `tip`: the block it reads,
    /// then every node of that block's state with its places.
    func syncCounts(
        at path: ChainPath, below tip: String, window: UInt64, remote: IvyRootContentSource
    ) async throws -> (CountedMarker.Block, [String: Int]) {
        let block = try await storage.countedSyncBlock(at: path, below: tip, window: window)
        return (block, try await storage.syncCountedState(at: path, block: block, remote: remote))
    }

    /// The roots a move found missing, read from peers.
    func healCounts(_ roots: [String], at path: ChainPath, remote: IvyRootContentSource) async throws {
        try await storage.healCounted(roots, at: path, remote: remote)
    }

    /// The counts checked against the store: their chain when they match.
    func auditCounts(at path: ChainPath, marker: String) async -> [String]? {
        await storage.auditCounted(at: path, marker: marker)
    }

    /// At a start, before any step, with `tips` the hosted chains' act-on
    /// tip heights: what a block read goes once it executed (all of it,
    /// when all state is kept), and the counts of the hosted chains are
    /// found. Returns their markers.
    func start(tips: [ChainPath: UInt64]) async -> [ChainPath: String] {
        await letGoOfReads()
        return await settleCountedScopes(hosted: Set(tips.keys))
    }

    /// At a start: what a block read goes when the block has executed (a
    /// stop came between), or when the operator keeps all state.
    func letGoOfReads() async {
        do {
            for (broker, scope) in try await storage.stores.retainedScopes(prefix: storage.scopes.readsPrefix) {
                guard let (path, cid) = storage.scopes.block(named: scope, after: storage.scopes.readsPrefix) else { continue }
                if scheme == .all, let roots = try? await broker.retainedRoots(scope: scope) {
                    try await broker.releaseRetainedRoots(scope: scope, roots: roots)
                } else if try await storage.store.hasExecutedBlock(cid, at: path) {
                    await releaseReads(cid, at: path)
                }
            }
        } catch {
            storage.syncTrace("reads not let go of at start: \(error)")
        }
    }


    /// At a start, with `hosted` the chains this node hosts (every store
    /// open is one of theirs: a chain not hosted was let go of with its
    /// store): the markers of their counts when the operator keeps recent
    /// state, and the staging of each chain with one let go of (a chain
    /// without keeps it for its state sync). When the operator keeps recent
    /// state no more, every chain's counts go: on `all` what they counted
    /// is kept with the chain first.
    func settleCountedScopes(hosted: Set<ChainPath>) async -> [ChainPath: String] {
        func path(_ scope: String, after prefix: String) -> ChainPath {
            scope.dropFirst(prefix.count).split(separator: "/").map(String.init)
        }
        let recent = scheme == .recent
        var markers: [ChainPath: String] = [:]
        do {
            for (broker, scope) in try await storage.stores.countedScopes(prefix: storage.scopes.countedPrefix) {
                guard !recent else { continue }
                if scheme == .all {
                    try await storage.retainHeld(Array(try await broker.countedState(scope: scope).counts.keys), in: broker)
                }
                try await broker.dropCountedScope(scope: scope)
            }
            if recent {
                for chain in hosted {
                    guard let broker = storage.stores.opened(at: chain) else { continue }
                    let marker = try await broker.countedState(scope: storage.scopes.counted(at: chain)).marker
                    if let marker, CountedMarker(marker) != nil { markers[chain] = marker }
                }
            }
            for (broker, scope) in try await storage.stores.retainedScopes(prefix: storage.scopes.stagingPrefix) {
                let chain = path(scope, after: storage.scopes.stagingPrefix)
                if markers[chain] != nil || !recent { try await storage.release(scope: scope, in: broker) }
            }
        } catch {
            storage.syncTrace("counts not settled at start: \(error)")
        }
        return markers
    }


}

extension NodeStorage {
    /// The state scheme the operator chose (`StateBackend`).
    nonisolated var stateBackend: StateBackend { StateBackend(storage: self) }
}
