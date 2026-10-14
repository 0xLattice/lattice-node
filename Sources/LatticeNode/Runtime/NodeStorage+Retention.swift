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
        try await retainHeld(roots.filter { !named.contains($0) })
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
}
