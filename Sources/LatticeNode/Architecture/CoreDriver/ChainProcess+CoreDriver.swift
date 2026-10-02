import Foundation
import Lattice
import LatticeNodeCore
import VolumeBroker
import cashew

/// The store side of the core driver: the existing NodeStore (state.db) and
/// Volume broker of an opened `ChainProcess`, used as the effect executor's
/// persistence and content layer. Nothing here decides anything.
extension ChainProcess {
    /// Boot replay: every durable fact batch, to rebuild `Core` from.
    // PENDING P4: `BootRecovery` still restores the actor `ChainLevel` too.
    nonisolated func coreFacts() async throws -> [BlockImportBatch] {
        try await store.stagedImports().map(\.batch)
    }

    /// The weigh log id state.db recorded with its first core fact.
    nonisolated func coreLogID() async throws -> String? {
        try await store.coreLogID()
    }

    /// `Effect.persist`: content first — post-states into the Volume store,
    /// header bytes into the header store, both durable and the Volume roots
    /// retained — then the batch's facts in one state.db transaction, with
    /// every root they reference: the post-states' and `bodyRoots`, the
    /// stored bodies of the blocks it validates. Boot keeps exactly the
    /// journaled roots retained.
    nonisolated func persistCoreBatch(
        _ batch: PersistBatch,
        logID: String,
        headers: CoreHeaderStore,
        bodyRoots: [String] = [],
        into levelStore: NodeStore? = nil
    ) async throws {
        let storage = NodeImportStorage(storage: broker)
        for state in batch.states {
            try await Self.storeExecutedState(state, in: storage)
        }
        // A child genesis's spec: what a restore holds as its root's.
        for spec in batch.headers.compactMap(\.spec) {
            try await VolumeImpl<ChainSpec>(node: spec).store(storer: storage)
        }
        try headers.store(batch.headers)
        let roots = await storage.takeStoredVolumeRoots() + bodyRoots
        try await broker.mergeRetainedRoots(scope: retentionScope, roots: roots)
        // PENDING #72 / decision 18d: genesis links are deleted; a Nexus-only
        // driver issues none it would need to keep.
        try await (levelStore ?? store).stageCoreFacts(batch.facts, volumeRoots: roots, logID: logID)
    }

    /// `Effect.fetchBody`: the block's Volume and the nested Volumes its
    /// execution reads, through the content layer (local store first, then
    /// any overlay provider of the root), stored and retained locally.
    /// Returns the roots it stored in, for the validation that references
    /// them.
    nonisolated func fetchCoreBody(_ cid: String, remote: IvyRootContentSource) async throws -> [String] {
        try await remote.withRoot(cid) { session in
            let fetcher = CoalescingFetcher(CompositeContentSource([broker, session]))
            let storage = NodeImportStorage(storage: broker)
            try await BlockHeader(rawCID: cid).storeBlock(fetcher: fetcher, storer: storage)
            let roots = await storage.takeStoredVolumeRoots()
            try await broker.mergeRetainedRoots(scope: retentionScope, roots: roots)
            return roots
        }
    }

    /// `MiningEffect.mined`: the mined block's content, stored and retained
    /// before its header is weighed (content first). Returns its child
    /// index, which the root header is inserted with.
    nonisolated func storeMinedBlock(_ block: Block) async throws -> FlatDictionary<BlockHeader> {
        let storage = NodeImportStorage(storage: broker)
        try await BlockHeader(node: block).storeBlock(fetcher: localFetcher, storer: storage)
        try await broker.mergeRetainedRoots(
            scope: retentionScope, roots: await storage.takeStoredVolumeRoots()
        )
        guard let children = try await block.children.resolve(fetcher: localFetcher).node else {
            throw ChainProcessError.missingMaterializedVolume(block.children.rawCID)
        }
        return children
    }

    /// `MiningEffect.poolChanged`, before any later effect of its step: each
    /// added transaction's Volume stored and pinned for this process, each
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

    /// A header's content for serving: the driver's header store, or the
    /// block boundary the actor path stored before the driver ran.
    /// The spec a stored genesis header names, from local content.
    nonisolated func coreGenesisSpec(_ cid: String) async throws -> ChainSpec? {
        guard let bytes = try? await localFetcher.fetch(rawCid: cid), let block = Block(data: bytes) else { return nil }
        return try await block.spec.resolve(fetcher: localFetcher).node
    }

    nonisolated func coreHeader(_ cid: String, headers: CoreHeaderStore) async -> (block: Block, children: FlatDictionary<BlockHeader>)? {
        if let stored = headers.header(cid) { return stored }
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
