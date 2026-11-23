import Foundation
import Lattice
import LatticeNodeCore
import VolumeBroker
import cashew
import LatticeNodeSupport

/// The storage's reads from peers: a block's body, what a mined block names
/// and this store lacks, and a state sync's or a heal's nodes, each read
/// through an `IvyRootContentSource` session. The store does not speak the
/// peer protocol; the runtime hands these the session.
extension NodeStorage {
    /// `ChainEffect.fetchBody`: the block's content (`storeBlockContent`: its
    /// Volume, its transactions', its spec and policy modules) through the
    /// content layer (local store first, then any overlay provider of the
    /// root), read into memory and not stored: the block is stored once its
    /// execution finds it valid. Returns the roots it read. Never the state
    /// its execution reads: this node derives a block's pre-state by
    /// executing its parent, as Bitcoin's initial block download and geth's
    /// full sync do, and a peer keeping recent state only holds no old one.
    /// The execution reads that state through `ownReads`, which asks a
    /// peer only for what this node does not hold.
    ///
    /// `bundle` is false once a fetch of the block failed: a bundle is an
    /// optimisation, so such a block is fetched one Volume at a time, as it
    /// would be from peers that speak no bundles. `hosts` names the
    /// block's child chain: its body is asked of that chain's current peers,
    /// the peers that store it, then of the connected peers known to
    /// provide the block or a Volume of it, and with none of them connected
    /// no peer is asked.
    ///
    /// The session reserves from the node's budget when it first asks a
    /// peer, an estimate of its worst case (`bodyReservation`): the chain's
    /// `maxBlockSize` (when its spec is held) bounds a body's bytes, not
    /// what holding them costs this node. A body past the estimate is
    /// fetched once more under the whole allowance, after the first
    /// reservation is released. The Volumes the
    /// walk derives, once it reaches the end of the body, are kept in memory
    /// for the block's connect.
    nonisolated func fetchChainBody(
        _ cid: String, remote: IvyRootContentSource, bundle: Bool = true, hosts: ChainHosts? = nil,
        maxBlockSize: Int? = nil
    ) async throws -> [String] {
        let allowance = remote.maximumStorageBytes
        let first = Self.bodyReservation(maxBlockSize: maxBlockSize, allowance: allowance)
        do {
            return try await fetchChainBody(cid, remote: remote, bundle: bundle, hosts: hosts, reserving: first)
        } catch NodeStorageError.bodyExceedsLocalBudget where first < allowance {
            return try await fetchChainBody(cid, remote: remote, bundle: bundle, hosts: hosts, reserving: allowance)
        }
    }

    /// What a body session reserves: four times `maxBlockSize`, at most
    /// `allowance` (the whole allowance when the spec is not held).
    /// `maxBlockSize` counts the data of the block's own Volume and its
    /// transactions, which is all the walk reads from peers. Holding an
    /// entry costs its CID and `retainedEntryOverhead` beside its data: a
    /// body of 0.97 MB of minimal transactions costs 3.5 MB to hold, hence
    /// four. A body past that (one of unusually small entries, or one whose
    /// spec or policy modules are not held yet) is fetched once more under
    /// the whole allowance. The spec and modules cost the session nothing
    /// once held (stored with the chain's genesis, then with each block):
    /// the walk reads the store first.
    static func bodyReservation(maxBlockSize: Int?, allowance: Int) -> Int {
        guard let maxBlockSize, maxBlockSize < allowance / 4 else { return allowance }
        return 4 * max(maxBlockSize, 0)
    }

    private nonisolated func fetchChainBody(
        _ cid: String, remote: IvyRootContentSource, bundle: Bool, hosts: ChainHosts?, reserving bytes: Int
    ) async throws -> [String] {
        let capture = IvyRootContentSource.AttributionCapture()
        do {
            return try await remote.withRootTracing(
                cid, bundle: bundle, hosts: hosts, onlyHosts: true, capture: capture, reserving: bytes, priority: .body(
                    cid, depth: hosts.map { $0.path.count - 1 } ?? 0
                )
            ) { session in
                // Read into memory, never into the store: what a peer sent is
                // stored once the block's execution has found it valid.
                let fetcher = CoalescingFetcher(CompositeContentSource([
                    ReadTally.wrap("store", stores.reads(.chain(hosts?.path ?? stores.rootPath))), ReadTally.wrap("peers", session),
                ]))
                let walked = NodeImportStorage(storage: nil, keepsVolumes: true)
                do {
                    // With its receipt witness, which the bundle carries,
                    // read from the content this walk resolved: a witness
                    // not obtained fails the fetch as content not obtained
                    // does (its execution could not read it either), and one
                    // past the reservation is retried under the whole
                    // allowance.
                    try await BlockHeader(rawCID: cid)
                        .storeBlockContent(fetcher: fetcher, storer: walked, parentReceiptWitness: true)
                    // The walk reached the end: the Volumes it derived are the
                    // ones storing the block would, and serve its connect.
                    await readCache.put(walked.takeVolumes().map(\.volume), block: cid)
                } catch BlockContentSizeError.exceedsLimit {
                    // Past the chain's own maxBlockSize the block is invalid,
                    // and its execution proves it from what was read: run it
                    // rather than retry a fetch that can never succeed.
                } catch {
                    throw await incompleteBody(cid, read: walked.takeVolumes().map(\.volume), error: error)
                }
                return await walked.takeStoredVolumeRoots()
            }.value
        } catch {
            // Content this node's own budget declined is named as that, not
            // as content nobody served.
            guard capture.snapshot()?.byteBudgetExceeded == true else { throw error }
            throw NodeStorageError.bodyExceedsLocalBudget(bytes: bytes)
        }
    }

    /// `MiningEffect.mined`: the mined block's content, stored and retained
    /// before its header is weighed (content first). Returns its child
    /// index, which the root header is inserted with. What the block names
    /// and this store lacks is read from peers, as the template that built
    /// it read it. A child block built for its author to commit (`at` its
    /// chain) is stored the same way, before any parent commits it.
    nonisolated func storeMinedBlock(
        _ block: Block, at path: ChainPath? = nil, remote: IvyRootContentSource? = nil
    ) async throws -> FlatDictionary<BlockHeader> {
        let header = try BlockHeader(node: block)
        let path = path ?? configuration.chainPath
        // A mined block carries the levels below it.
        guard let remote else {
            return try await storeMinedBlock(header, block, at: path, fetcher: localFetcher(.subtree(path)))
        }
        return try await remote.withRootTracing(header.rawCID, bundle: false) { session in
            let children = try await storeMinedBlock(
                header, block, at: path, fetcher: ownReads(through: session, .subtree(path))
            )
            return children
        }.value
    }

    /// The child blocks a mined root carries at hosted levels, outermost
    /// first, each stored and with its proof from this root: only those the
    /// grind's work meets (a verified contribution), at any depth below
    /// carriers it misses.
    nonisolated func carriedGrinds(
        of root: Block, hosted: Set<ChainPath>, remote: IvyRootContentSource? = nil
    ) async throws -> [MinedGrind.Carried] {
        guard let remote else {
            return try await carriedGrinds(of: root, hosted: hosted, fetcher: localFetcher(.subtree(stores.rootPath)))
        }
        let rootCID = try BlockHeader(node: root).rawCID
        return try await remote.withRootTracing(rootCID, bundle: false) { session in
            let carried = try await carriedGrinds(
                of: root, hosted: hosted, fetcher: ownReads(through: session, .subtree(stores.rootPath))
            )
            return carried
        }.value
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
            let fetcher = readersReads(through: session, .chain(path))
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
}

extension StateBackend {
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
}
