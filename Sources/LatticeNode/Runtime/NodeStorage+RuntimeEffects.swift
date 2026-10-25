import Foundation
import Lattice
import LatticeNodeCore
import VolumeBroker
import cashew

/// The store side of the node runtime: the existing NodeStore (state.db) and
/// Volume broker of an opened `NodeStorage`, used as the effect executor's
/// persistence and content layer. Nothing here decides anything.
extension NodeStorage {
    /// One level's journaled facts, in order.
    nonisolated func nodeFacts(at path: ChainPath) async throws -> [BlockImportBatch] {
        try await store.importBatches(at: path)
    }

    /// Policy modules an operator supplies while the node runs, stored as
    /// at start, so a genesis that names one can be stored.
    nonisolated func storePolicyModules(_ modules: [Data]) async throws {
        guard !modules.isEmpty else { return }
        let storage = NodeImportStorage(storage: broker)
        for bytes in modules {
            try await WasmPolicyModuleHeader(node: WasmPolicyModule(bytes: bytes)).store(storer: storage)
        }
        try await storage.commit()
        try await retainHeld(await storage.takeStoredVolumeRoots())
    }

    /// The weigh log id state.db recorded with its first chain fact.
    nonisolated func chainLogID() async throws -> String? {
        try await store.chainLogID()
    }

    nonisolated func chainCursors(at path: ChainPath) async throws -> [String: StreamCursor] {
        try await store.chainCursors(at: path)
    }

    /// `NodeEffect.persist`: content first — every affected level's Volumes
    /// in one volumes.db transaction, then retained — then the complete node
    /// step's headers, proofs, facts and cursors in one state.db transaction.
    nonisolated func persistNodeBatch(
        _ batch: NodeBatch,
        logID: String,
        bodyRoots: [ChainPath: [String]] = [:]
    ) async throws {
        var durable: [NodeFactBatch] = []
        // What this step's executions created. An executed block's body was
        // pinned under its block's name by the job that executed it, and the
        // journal still names it.
        var stored: [String] = []
        // With only the tip's state kept, or none: the state each level's
        // executions created, under the level's state scope.
        var states: [ChainPath: [String]] = [:]
        let storage = NodeImportStorage(storage: broker)
        for (path, level) in batch.levels.sorted(by: {
            $0.path.count != $1.path.count
                ? $0.path.count < $1.path.count
                : $0.path.joined(separator: "/") < $1.path.joined(separator: "/")
        }) {
            for state in level.states {
                try await Self.storeExecutedState(state, in: storage)
            }
            let executed = await storage.takeStoredVolumeRoots()
            // A child genesis's spec: what restore holds as its root's.
            for spec in level.headers.compactMap(\.spec) {
                try await VolumeImpl<ChainSpec>(node: spec).store(storer: storage)
            }
            let specs = await storage.takeStoredVolumeRoots()
            let created = executed + specs
            switch configuration.state {
            case .all:
                stored.append(contentsOf: created)
            case .tip, .none:
                states[path] = executed
                stored.append(contentsOf: specs)
            }
            let roots = created + (bodyRoots[path] ?? [])
            durable.append(NodeFactBatch(
                path: path,
                facts: level.facts,
                headers: level.headers,
                proofs: level.proofs,
                volumeRoots: roots,
                cursors: level.cursors
            ))
        }
        try await storage.commit()
        try await retainHeld(stored)
        for (path, roots) in states where !roots.isEmpty {
            if configuration.state == .tip {
                // Until the kept state has counted what of it the tip holds.
                try await retainHeld(roots, scope: scopes.executed(at: path))
                continue
            }
            let scope = scopes.state(at: path)
            // With no state kept, only what the last execution touched
            // stays: the next block most likely reads it.
            let earlier = configuration.state == .none ? try await broker.retainedRoots(scope: scope) : []
            try await retainHeld(roots, scope: scope)
            let gone = Set(earlier).subtracting(roots)
            if !gone.isEmpty { try await broker.releaseRetainedRoots(scope: scope, roots: gone.sorted()) }
        }
        try await store.stageNodeFacts(durable, logID: logID)
    }

    /// Retains the roots this store holds. One it lacks (a body fetched for
    /// this step and gone since) is no fault: the facts still name it, and
    /// whatever reads it next fetches it.
    nonisolated func retainHeld(_ roots: [String], scope: String? = nil) async throws {
        var roots = Set(roots)
        while !roots.isEmpty {
            do {
                return try await broker.mergeRetainedRoots(scope: scope ?? retentionScope, roots: roots.sorted())
            } catch BrokerError.missingRetainedRoot(let root) {
                roots.remove(root)
            }
        }
    }

    /// How the operator's own work reads: this store, a block's header
    /// record, what its earlier reads asked of peers, then peers, whose
    /// answers are remembered for the next read.
    nonisolated func ownReads(through peers: any ContentSource) -> CoalescingFetcher {
        CoalescingFetcher(CompositeContentSource([workSource, readCache, readCache.remembering(peers)]))
    }

    /// Stores a block and pins what was stored: its body is what `fetcher`,
    /// the content it was stored from, says it carries.
    nonisolated func storingAndRetaining(
        _ blockCID: String, at path: ChainPath, from fetcher: any Fetcher,
        _ store: (NodeImportStorage) async throws -> Void
    ) async throws -> [String] {
        let storage = NodeImportStorage(storage: broker)
        try await store(storage)
        try await storage.commit()
        let roots = await storage.takeStoredVolumeRoots()
        let body = [blockCID] + (try await NodeRuntime.carriedTransactionIDs(ofBlock: blockCID, fetcher: fetcher))
        try await retainStored(roots, body: body, ofBlock: blockCID, at: path)
        return roots
    }

    /// Stores a block execution found valid, as `fetcher` reads it, and pins
    /// it. None of it is in the store before: a body fetched from peers is
    /// held in memory until then.
    nonisolated func storeValidBlock(_ cid: String, at path: ChainPath, from fetcher: any Fetcher) async throws {
        let roots = try await storingAndRetaining(cid, at: path, from: fetcher) { storage in
            try await BlockHeader(rawCID: cid).storeBlock(fetcher: fetcher, storer: storage)
        }
        bundles.record(root: cid, roots: roots)
    }

    /// `ChainEffect.fetchBody`: the block's Volume and the nested Volumes its
    /// execution reads, through the content layer (local store first, then
    /// any overlay provider of the root), read into memory and not stored:
    /// the block is stored once its execution finds it valid. Returns the
    /// roots it read.
    ///
    /// `bundle` is false on a retry: a bundle is an optimisation, so a block
    /// whose first attempt failed is fetched one Volume at a time, as it
    /// would be from peers that speak no bundles. `hosts` names the
    /// block's child chain: the bundle is asked first of its current peers.
    nonisolated func fetchChainBody(
        _ cid: String, remote: IvyRootContentSource, bundle: Bool = true, hosts: ChainHosts? = nil
    ) async throws -> [String] {
        let capture = IvyRootContentSource.AttributionCapture()
        do {
            return try await remote.withRootTracing(cid, bundle: bundle, hosts: hosts, capture: capture) { session in
                // Read into memory, never into the store: what a peer sent is
                // stored once the block's execution has found it valid. The
                // session reads whole Volumes, so it is asked before what an
                // earlier, failed attempt left in memory.
                let fetcher = CoalescingFetcher(CompositeContentSource([broker, readCache.remembering(session)]))
                let walked = NodeImportStorage(storage: nil)
                do {
                    try await BlockHeader(rawCID: cid).storeBlock(fetcher: fetcher, storer: walked)
                } catch BlockContentSizeError.exceedsLimit {
                    // Past the chain's own maxBlockSize the block is invalid,
                    // and its execution proves it from what was read: run it
                    // rather than retry a fetch that can never succeed.
                }
                return await walked.takeStoredVolumeRoots()
            }.value
        } catch {
            // Content this node's own budget declined is named as that, not
            // as content nobody served.
            guard capture.snapshot()?.byteBudgetExceeded == true else { throw error }
            throw NodeStorageError.bodyExceedsLocalBudget(bytes: remote.maximumStorageBytes)
        }
    }

    /// The Volume roots served together for `rootCID`, its own first: the
    /// content `storeBlock` defines for that block. Recorded when the block
    /// was stored; for a block stored before bundles were recorded, the same
    /// walk over local content only, recorded once it completes. A root that
    /// is no block this node holds whole bundles only itself.
    nonisolated func volumeBundle(_ rootCID: String) async -> [String] {
        if let recorded = bundles.bundle(root: rootCID) { return recorded }
        // Not a block this node holds: nothing to walk, and nothing to say.
        guard let bytes = await broker.fetchDataLocal(cid: rootCID), Block(data: bytes) != nil else {
            return [rootCID]
        }
        let walked = NodeImportStorage(storage: nil)
        do {
            try await BlockHeader(rawCID: rootCID).storeBlock(fetcher: localFetcher, storer: walked)
        } catch {
            syncTrace("volume bundle of \(rootCID) not walked: \(error)")
            return [rootCID]
        }
        let roots = await walked.takeStoredVolumeRoots()
        bundles.record(root: rootCID, roots: roots)
        return [rootCID] + roots.filter { $0 != rootCID }
    }

    /// `MiningEffect.mined`: the mined block's content, stored and retained
    /// before its header is weighed (content first). Returns its child
    /// index, which the root header is inserted with. What the block names
    /// and this store lacks is read from peers, as the template that built
    /// it read it.
    nonisolated func storeMinedBlock(
        _ block: Block, remote: IvyRootContentSource? = nil
    ) async throws -> FlatDictionary<BlockHeader> {
        let header = try BlockHeader(node: block)
        guard let remote else { return try await storeMinedBlock(header, block, fetcher: localFetcher) }
        return try await remote.withRootTracing(header.rawCID, bundle: false) { session in
            let children = try await storeMinedBlock(
                header, block, fetcher: ownReads(through: session)
            )
            return children
        }.value
    }

    private nonisolated func storeMinedBlock(
        _ header: BlockHeader, _ block: Block, fetcher: any Fetcher
    ) async throws -> FlatDictionary<BlockHeader> {
        let roots = try await storingAndRetaining(header.rawCID, at: configuration.chainPath, from: fetcher) { storage in
            try await header.storeBlock(fetcher: fetcher, storer: storage)
        }
        bundles.record(root: header.rawCID, roots: roots)
        guard let children = try await block.children.resolve(fetcher: fetcher).node else {
            throw NodeStorageError.missingMaterializedVolume(block.children.rawCID)
        }
        return children
    }

    /// The child blocks a mined root carries at hosted levels, outermost
    /// first, each stored and with its proof from this root: only those the
    /// grind's work meets (a verified contribution).
    nonisolated func carriedGrinds(
        of root: Block, hosted: Set<ChainPath>, remote: IvyRootContentSource? = nil
    ) async throws -> [MinedGrind.Carried] {
        guard let remote else { return try await carriedGrinds(of: root, hosted: hosted, fetcher: localFetcher) }
        let rootCID = try BlockHeader(node: root).rawCID
        return try await remote.withRootTracing(rootCID, bundle: false) { session in
            let carried = try await carriedGrinds(
                of: root, hosted: hosted, fetcher: ownReads(through: session)
            )
            return carried
        }.value
    }

    private nonisolated func carriedGrinds(
        of root: Block, hosted: Set<ChainPath>, fetcher localFetcher: any Fetcher
    ) async throws -> [MinedGrind.Carried] {
        var carried: [MinedGrind.Carried] = []
        // (carrier block, its path, the proof from the root to it)
        var frontier: [(block: Block, path: ChainPath, proof: ChildBlockProof?)] = [(root, configuration.chainPath, nil)]
        while let (carrier, path, proofToCarrier) = frontier.popLast() {
            guard let children = carrier.children.node else { continue }
            for (directory, child) in children.entries.sorted(by: { $0.key < $1.key }) {
                let childPath = path + [directory]
                guard hosted.contains(childPath), let block = child.node else { continue }
                let hop = try await ChildBlockProof.generate(
                    rootHeader: BlockHeader(node: carrier), childDirectory: directory, fetcher: localFetcher
                )
                let proof = proofToCarrier.map { $0.composing(hop: hop) } ?? hop
                // Only a block the grind's work meets is stored and walked.
                guard case .success(let evidence) = await proof.verifySecuringWork(child: block, chainPath: childPath),
                      evidence.contribution != nil else { continue }
                let roots = try await storingAndRetaining(child.rawCID, at: childPath, from: localFetcher) { storage in
                    try await child.storeBlock(fetcher: localFetcher, storer: storage)
                }
                bundles.record(root: child.rawCID, roots: roots)
                frontier.append((block, childPath, proof))
                guard let grandchildren = try await block.children.resolve(fetcher: localFetcher).node else { continue }
                carried.append(MinedGrind.Carried(
                    path: childPath, block: block, children: grandchildren, proof: proof, evidence: evidence
                ))
            }
        }
        return carried.sorted { $0.path.count < $1.path.count }
    }

    /// `MiningEffect.poolChanged`, before any later effect of its step: each
    /// added transaction's Volume stored and pinned for this storage, each
    /// journaled one written to the local journal, and every removed one
    /// unpinned and dropped from the journal. The journal keeps seconds.
    nonisolated func persistPoolDelta(_ delta: PoolDelta) async throws {
        for item in delta.added {
            _ = try await persistPeerTransaction(item.transaction)
        }
        for item in delta.journaled {
            _ = try await persistLocalTransaction(item.transaction, addedAt: item.addedAt / 1_000)
        }
        guard !delta.removed.isEmpty else { return }
        try await updateLiveMempoolRoots(adding: [], removing: Set(delta.removed))
        let journal = try await localTransactionTimestamps()
        for cid in delta.removed where journal[cid] != nil {
            try await removeLocalTransaction(cid)
        }
    }

    /// A header's content for serving: the runtime's header store, or a full
    /// block boundary already held by the Volume store.
    /// The spec a stored genesis header names, from local content.
    /// A child genesis header lives in the header store (its body may not be
    /// fetched yet); its spec Volume was stored with it.
    /// `operatorSpecs` are the operator's specs now, when they changed since
    /// start.
    nonisolated func chainGenesisSpec(
        _ cid: String, operatorSpecs: [ChainPath: ChainSpec]? = nil
    ) async throws -> ChainSpec? {
        guard let block = await chainHeader(cid)?.block else { return nil }
        if let held = try? await block.spec.resolve(fetcher: localFetcher).node { return held }
        // Not in the store: the operator's own spec for a chain it created
        // is the same content if it has the same CID, and is stored again.
        for spec in (operatorSpecs ?? configuration.childSpecs).values {
            let volume = try VolumeImpl<ChainSpec>(node: spec)
            guard volume.rawCID == block.spec.rawCID else { continue }
            let storage = NodeImportStorage(storage: broker)
            try await volume.store(storer: storage)
            try await storage.commit()
            try await retainHeld(await storage.takeStoredVolumeRoots())
            return spec
        }
        return nil
    }

    nonisolated func chainHeader(_ cid: String) async -> (block: Block, children: FlatDictionary<BlockHeader>)? {
        if let stored = store.header(cid) { return stored }
        guard let blockBytes = try? await localFetcher.fetch(rawCid: cid),
              let block = Block(data: blockBytes),
              let childBytes = try? await localFetcher.fetch(rawCid: block.children.rawCID),
              let children = FlatDictionary<BlockHeader>(data: childBytes) else { return nil }
        return (block, children)
    }

    /// Store an execution's materialized post-state: every Volume the
    /// execution loaded, each as its own boundary.
    static func storeExecutedState(_ state: LatticeState, in storer: any VolumeStorer) async throws {
        try await storeLoaded(LatticeStateHeader(node: state), in: storer)
    }

    private static func storeLoaded(_ header: any Header, in storer: any VolumeStorer) async throws {
        guard loadedNode(of: header) != nil else { return }
        if let volume = header as? any Volume {
            try await volume.store(storer: storer)
        }
        for child in children(of: header) {
            try await storeLoaded(child, in: storer)
        }
    }

    /// The headers a loaded node names; none when it is not loaded.
    static func children(of header: any Header) -> [any Header] {
        guard let node: any cashew.Node = loadedNode(of: header) else { return [] }
        var children: [any Header] = node.properties().sorted().compactMap { node.get(property: $0) }
        if let radix = node as? any RadixNode, let value = radix.value as? any Header {
            children.append(value)
        }
        return children
    }

    private static func loadedNode<H: Header>(of header: H) -> (any cashew.Node)? {
        header.node
    }
}
