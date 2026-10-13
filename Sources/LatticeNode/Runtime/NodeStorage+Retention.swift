import Foundation
import Lattice
import LatticeNodeCore
import VolumeBroker
import cashew

/// The names content is pinned under. A Volume stays while any scope names
/// it, and each scope says why.
///
/// - The chain scope holds what every level's executions read and created
///   (state, specs, policy modules) and each genesis block.
/// - A block's body, its own Volume and its transactions', is pinned under
///   that block's name: two blocks that carry one transaction each keep
///   it, and letting go of one block lets go of nothing the other names.
/// - A block this node built is pinned under a name of its own until a
///   fact records the block, so a start finds the ones a crash orphaned
///   without looking at every body it holds.
struct RetentionScopes: Sendable {
    let chain: String

    var bodyPrefix: String { chain + ":body:" }
    var builtPrefix: String { chain + ":built:" }

    func body(_ blockCID: String) -> String { bodyPrefix + blockCID }
    func built(_ blockCID: String) -> String { builtPrefix + blockCID }
}

/// The retention rules: the only code that decides what this store keeps.
/// Nothing here is needed for the node to be right: content a rule let go
/// of is fetched again by whatever reads it next.
extension NodeStorage {
    nonisolated var scopes: RetentionScopes { RetentionScopes(chain: retentionScope) }

    /// Pins what storing a block wrote: its body under the block's name
    /// (`built`: under the name of a block not recorded yet), and the rest,
    /// the state its execution reads, its spec and its policy modules, with
    /// the chain.
    nonisolated func retainStored(_ roots: [String], ofBlock blockCID: String, built: Bool = false) async throws {
        let body = Set([blockCID] + (await NodeRuntime.transactionIDs(ofBlock: blockCID, fetcher: localFetcher)))
        try await broker.mergeRetainedRoots(
            scope: built ? scopes.built(blockCID) : scopes.body(blockCID), roots: roots.filter(body.contains)
        )
        try await retainHeld(roots.filter { !body.contains($0) })
        if !built { await release(scope: scopes.built(blockCID)) }
    }

    /// Lets go of a block's body. What another block's body or the chain
    /// also names stays.
    nonisolated func releaseBody(_ blockCID: String) async {
        await release(scope: scopes.body(blockCID))
        await release(scope: scopes.built(blockCID))
    }

    private nonisolated func release(scope: String) async {
        do {
            let roots = try await broker.retainedRoots(scope: scope)
            guard !roots.isEmpty else { return }
            try await broker.releaseRetainedRoots(scope: scope, roots: roots)
        } catch {
            syncTrace("\(scope) not released: \(error)")
        }
    }
}
