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

    /// What the executions of the chain at `path` stored at `height`, when
    /// the operator keeps recent state. Zero-padded, so the scopes of a
    /// chain list in height order.
    func window(at path: ChainPath, height: UInt64) -> String {
        let digits = String(height)
        return windowPrefix(at: path) + String(repeating: "0", count: max(0, 20 - digits.count)) + digits
    }

    func windowPrefix(at path: ChainPath) -> String { chain + ":window:" + path.joined(separator: "/") + ":" }

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

    // MARK: - State: recent

    /// With a state window: what executions stored at heights more than a
    /// window below `height`, the tip's, goes. What a newer block still
    /// names is read from peers when something reads it.
    nonisolated func letGoOfState(at path: ChainPath, below height: UInt64) async {
        guard let window = configuration.stateWindow(for: path) else { return }
        guard height >= window else { return }
        let kept = scopes.window(at: path, height: height - window + 1)
        do {
            for scope in try await broker.retainedScopes(prefix: scopes.windowPrefix(at: path)) where scope < kept {
                let roots = try await broker.retainedRoots(scope: scope)
                if !roots.isEmpty { try await broker.releaseRetainedRoots(scope: scope, roots: roots) }
            }
        } catch {
            syncTrace("state below \(height) not let go of: \(error)")
        }
    }

    /// At a start: what earlier versions kept state under goes (exact
    /// counts of the tip's state, and their scopes). The state windows of a
    /// run that kept recent state stay: they go by height as the tips move,
    /// or are kept with everything else on `all`.
    nonisolated func letGoOfLegacyState() async {
        do {
            try await store.forgetStateCounts()
            for prefix in scopes.legacyStatePrefixes {
                for scope in try await broker.retainedScopes(prefix: prefix) {
                    let roots = try await broker.retainedRoots(scope: scope)
                    if !roots.isEmpty { try await broker.releaseRetainedRoots(scope: scope, roots: roots) }
                }
            }
        } catch {
            syncTrace("earlier state not let go of at start: \(error)")
        }
    }
}
