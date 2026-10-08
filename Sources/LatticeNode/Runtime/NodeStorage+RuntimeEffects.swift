import Foundation
import Lattice
import LatticeNodeCore
import VolumeBroker
import cashew

/// The store side of the node runtime: the existing NodeStore (state.db) and
/// Volume broker of an opened `NodeStorage`, used as the effect executor's
/// persistence and content layer. Nothing here decides anything.
extension NodeStorage {
    /// Boot replay: every durable fact batch, grouped by hosted level.
    nonisolated func nodeFacts() async throws -> [ChainPath: [BlockImportBatch]] {
        Dictionary(grouping: try await store.stagedImports(), by: \.chainPath)
            .mapValues { $0.map(\.batch) }
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
        let storage = NodeImportStorage(storage: broker)
        for (path, level) in batch.levels.sorted(by: {
            $0.path.count != $1.path.count
                ? $0.path.count < $1.path.count
                : $0.path.joined(separator: "/") < $1.path.joined(separator: "/")
        }) {
            for state in level.states {
                try await Self.storeExecutedState(state, in: storage)
            }
            // A child genesis's spec: what restore holds as its root's.
            for spec in level.headers.compactMap(\.spec) {
                try await VolumeImpl<ChainSpec>(node: spec).store(storer: storage)
            }
            let roots = await storage.takeStoredVolumeRoots() + (bodyRoots[path] ?? [])
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
        let roots = durable.flatMap(\.volumeRoots)
        if !roots.isEmpty {
            try await broker.mergeRetainedRoots(scope: retentionScope, roots: roots)
        }
        try await store.stageNodeFacts(durable, logID: logID)
    }

    /// `ChainEffect.fetchBody`: the block's Volume and the nested Volumes its
    /// execution reads, through the content layer (local store first, then
    /// any overlay provider of the root), stored and retained locally.
    /// What it stored is recorded as the block's bundle, so a peer fetching the
    /// block from this node is sent it all with one request.
    /// Returns the roots it stored in, for the validation that references
    /// them.
    ///
    /// `bundle` is false on a retry: a bundle is an optimisation, so a block
    /// whose first attempt failed is fetched one Volume at a time, as it
    /// would be from peers that speak no bundles. `hosts` is the rendezvous
    /// of the block's chain: the bundle is asked first of the peers it names.
    nonisolated func fetchChainBody(
        _ cid: String, remote: IvyRootContentSource, bundle: Bool = true, hosts: String? = nil
    ) async throws -> [String] {
        let capture = IvyRootContentSource.AttributionCapture()
        do {
            return try await remote.withRootTracing(cid, bundle: bundle, hosts: hosts, capture: capture) { session in
                let fetcher = CoalescingFetcher(CompositeContentSource([broker, session]))
                let storage = NodeImportStorage(storage: broker)
                try await BlockHeader(rawCID: cid).storeBlock(fetcher: fetcher, storer: storage)
                try await storage.commit()
                let roots = await storage.takeStoredVolumeRoots()
                try await broker.mergeRetainedRoots(scope: retentionScope, roots: roots)
                bundles.record(root: cid, roots: roots)
                return roots
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
    /// index, which the root header is inserted with.
    nonisolated func storeMinedBlock(_ block: Block) async throws -> FlatDictionary<BlockHeader> {
        let storage = NodeImportStorage(storage: broker)
        let header = try BlockHeader(node: block)
        try await header.storeBlock(fetcher: localFetcher, storer: storage)
        try await storage.commit()
        let roots = await storage.takeStoredVolumeRoots()
        try await broker.mergeRetainedRoots(scope: retentionScope, roots: roots)
        bundles.record(root: header.rawCID, roots: roots)
        guard let children = try await block.children.resolve(fetcher: localFetcher).node else {
            throw NodeStorageError.missingMaterializedVolume(block.children.rawCID)
        }
        return children
    }

    /// The child blocks a mined root carries at hosted levels, outermost
    /// first, each stored and with its proof from this root: only those the
    /// grind's work meets (a verified contribution).
    nonisolated func carriedGrinds(of root: Block, hosted: Set<ChainPath>) async throws -> [MinedGrind.Carried] {
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
                let storage = NodeImportStorage(storage: broker)
                try await child.storeBlock(fetcher: localFetcher, storer: storage)
                try await storage.commit()
                let roots = await storage.takeStoredVolumeRoots()
                try await broker.mergeRetainedRoots(scope: retentionScope, roots: roots)
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
    nonisolated func chainGenesisSpec(_ cid: String) async throws -> ChainSpec? {
        guard let block = await chainHeader(cid)?.block else { return nil }
        return try await block.spec.resolve(fetcher: localFetcher).node
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
        guard let node: any cashew.Node = loadedNode(of: header) else { return }
        if let volume = header as? any Volume {
            try await volume.store(storer: storer)
        }
        var children: [any Header] = node.properties().sorted().compactMap { node.get(property: $0) }
        if let radix = node as? any RadixNode, let value = radix.value as? any Header {
            children.append(value)
        }
        for child in children {
            try await storeLoaded(child, in: storer)
        }
    }

    private static func loadedNode<H: Header>(of header: H) -> (any cashew.Node)? {
        header.node
    }
}
