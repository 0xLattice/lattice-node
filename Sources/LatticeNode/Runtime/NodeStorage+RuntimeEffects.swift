import Foundation
import Lattice
import LatticeNodeCore
import LatticeNodeAPI
import VolumeBroker
import cashew

/// The store side of the node runtime: the existing NodeStore (state.db) and
/// Volume broker of an opened `NodeStorage`, used as the effect executor's
/// persistence and content layer. Nothing here decides anything.
extension NodeStorage {
    /// One level's stored facts, in the order it took them.
    nonisolated func nodeFacts(at path: ChainPath) async throws -> StoredFacts {
        try await store.storedFacts(at: path)
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
    /// in one volumes.db transaction, retained in the same one — then the
    /// complete node step's headers, proofs, facts and cursors in one
    /// state.db transaction.
    nonisolated func persistNodeBatch(_ batch: NodeBatch, logID: String) async throws {
        var durable: [NodeFactBatch] = []
        // What this step's executions created. An executed block's body was
        // pinned under its block's name by the job that executed it.
        var stored: [String] = []
        // With recent state kept, or none: the state each level's
        // executions stored, each under the height of the block that
        // produced it (a batch's blocks keep their own windows).
        var states: [ChainPath: [(height: UInt64?, roots: [String])]] = [:]
        let storage = NodeImportStorage(storage: broker)
        for (path, level) in batch.levels.sorted(by: {
            $0.path.count != $1.path.count
                ? $0.path.count < $1.path.count
                : $0.path.joined(separator: "/") < $1.path.joined(separator: "/")
        }) {
            // The blocks whose states these are: the ones this step
            // executed (a header only weighed names a state it did not
            // produce), in order. Two blocks can produce the same state,
            // each in its own window.
            let facts = level.facts.flatMap(\.facts)
            let validated = Set(facts.compactMap { fact -> String? in
                guard case .validation(let validation) = fact else { return nil }
                return validation.blockHash
            })
            var heights = facts.compactMap { fact -> (cid: String, height: UInt64)? in
                guard case .block(let block) = fact, validated.contains(block.blockHash) else { return nil }
                return (block.postStateCID, block.blockHeight)
            }
            var executed: [String] = []
            var produced: [(height: UInt64?, roots: [String])] = []
            for state in level.states {
                try await Self.storeExecutedState(state, in: storage)
                let roots = await storage.takeStoredVolumeRoots()
                executed += roots
                let cid = try? LatticeStateHeader(node: state).rawCID
                let height = heights.firstIndex { $0.cid == cid }.map { heights.remove(at: $0).height }
                produced.append((height, roots))
            }
            // A child genesis's spec: what restore holds as its root's.
            for spec in level.headers.compactMap(\.spec) {
                try await VolumeImpl<ChainSpec>(node: spec).store(storer: storage)
            }
            let specs = await storage.takeStoredVolumeRoots()
            let created = executed + specs
            switch configuration.state {
            case .all:
                stored.append(contentsOf: created)
            case .recent, .none:
                // A state no block fact of the step names (none does today)
                // joins the chain's newest window below.
                states[path] = produced
                stored.append(contentsOf: specs)
            }
            durable.append(NodeFactBatch(
                path: path,
                facts: level.facts,
                headers: level.headers,
                proofs: level.proofs,
                cursors: level.cursors,
                keepsStateDiffs: configuration.state == .recent
            ))
        }
        // Every root retained is one this batch stores.
        var retaining: [String: [String]] = [:]
        if !stored.isEmpty { retaining[retentionScope] = stored }
        for (path, produced) in states {
            for state in produced where !state.roots.isEmpty {
                // A state of no known height goes with the newest the chain
                // keeps: kept as long as that, never let go of before it.
                let scope = if let height = state.height {
                    scopes.window(at: path, height: height)
                } else {
                    try await broker.retainedScopes(prefix: scopes.windowPrefix(at: path)).max()
                        ?? scopes.window(at: path, height: 0)
                }
                retaining[scope, default: []] += state.roots
            }
        }
        try await broker.storeVolumesLocal(await storage.takeVolumes(), retaining: retaining)
        try await store.stageNodeFacts(durable, logID: logID)
    }

    /// Retains the roots this store holds, and returns the ones it lacks.
    /// One it lacks (a body fetched for this step and gone since) is no
    /// fault here: the facts still name it, and whatever reads it next
    /// fetches it. A merge refused for a root it lacks is made again with
    /// only the roots held.
    @discardableResult
    nonisolated func retainHeld(_ roots: [String], scope: String? = nil) async throws -> [String] {
        var roots = Set(roots)
        var lacked: [String] = []
        while !roots.isEmpty {
            do {
                try await broker.mergeRetainedRoots(scope: scope ?? retentionScope, roots: roots.sorted())
                break
            } catch BrokerError.missingRetainedRoot(let missing) {
                for root in roots {
                    let held = root == missing ? false : await broker.hasVolume(root: root)
                    guard !held else { continue }
                    roots.remove(root)
                    lacked.append(root)
                }
            }
        }
        return lacked
    }

    /// How the operator's own work reads: this store, a block's header
    /// record, what is in memory (`readCache`), then peers, whose answers
    /// are kept there for the next read. Every read of materialized state
    /// the node's work makes (a block's pre-state when it executes, a
    /// template's, a mined block's) goes through here, so a peer is asked
    /// only for what neither this store nor memory holds: a state this node
    /// let go of, as a reorganization past its kept windows needs. A
    /// block's body is fetched without its state (`fetchChainBody`).
    nonisolated func ownReads(through peers: any ContentSource) -> CoalescingFetcher {
        CoalescingFetcher(CompositeContentSource([workSource, readCache, readCache.remembering(peers)]))
    }

    /// How a reader's state read reads: this store, a block's header
    /// record, what is in memory, then peers, whose answers are not kept
    /// for later reads.
    nonisolated func readersReads(through peers: any ContentSource) -> CoalescingFetcher {
        CoalescingFetcher(CompositeContentSource([workSource, readCache, peers]))
    }

    /// Stores a block and pins what was stored: its body is what `fetcher`,
    /// the content it was stored from, says it carries.
    nonisolated func storingAndRetaining(
        _ header: BlockHeader, at path: ChainPath, from fetcher: any Fetcher,
        _ store: (NodeImportStorage) async throws -> Void
    ) async throws -> [String] {
        let blockCID = header.rawCID
        let storage = NodeImportStorage(storage: broker)
        try await store(storage)
        try await storage.commit()
        // Read once the block's content is stored: the witness is read
        // through the block's transactions.
        let witness = await receiptWitness(of: header, fetcher: fetcher)
        for volume in witness { try await storage.store(volume: volume) }
        try await storage.commit()
        let roots = await storage.takeStoredVolumeRoots()
        let body = [blockCID] + (try await NodeRuntime.carriedTransactionIDs(ofBlock: blockCID, fetcher: fetcher))
            + witness.map(\.root)
        try await retainStored(roots, body: body, ofBlock: blockCID, at: path)
        return roots
    }

    /// A block's parent-receipt witness (`storeParentReceiptWitness`): the
    /// Volumes under its parent state on the path to each of its
    /// withdrawals' receipts, which its execution reads. They are its body's
    /// as much as its transactions are: fetched, stored, pinned under its
    /// name, and served with it, so the block executes where its parent's
    /// state is gone. None for a block without withdrawals, or when
    /// `fetcher` cannot read them (the execution then reads them itself).
    nonisolated func receiptWitness(of block: BlockHeader, fetcher: any Fetcher) async -> [SerializedVolume] {
        let walked = NodeImportStorage(storage: nil, keepsVolumes: true)
        do {
            try await block.storeParentReceiptWitness(fetcher: fetcher, storer: walked)
        } catch {
            syncTrace("receipt witness of \(block.rawCID) not read: \(error)")
            return []
        }
        return await walked.takeVolumes().map(\.volume)
    }

    /// Stores a block execution found valid, and pins it
    /// (`storeValidBlocks` of the one block). Returns the CIDs of the
    /// transactions the block carries; throws when it was not stored.
    @discardableResult
    nonisolated func storeValidBlock(
        _ cid: String, decoded: Block? = nil, at path: ChainPath, from fetcher: any Fetcher
    ) async throws -> [String] {
        guard let transactions = try await storeValidBlocks([(cid, decoded)], at: path, from: fetcher)[cid] else {
            throw NodeAPIError.unresolvedTransactionContent
        }
        return transactions
    }

    /// Stores the blocks of one connect job execution found valid, and pins
    /// them, in one volumes.db transaction. A body fetched from peers is
    /// held in memory until then. Each block's Volumes are the ones its
    /// body's fetch derived and kept, or else derived again as `fetcher`
    /// reads them: its content (`storeBlockContent`) and its receipt witness
    /// (`receiptWitness`), never the rest of the state it read. What is
    /// stored is its body (its own Volume, its transactions' and its
    /// witness's), pinned under its name, and, with the chain, its spec and
    /// policy modules. The state it read is its parent's, which
    /// this node stored executing the parent, and the counts and windows
    /// keep or peers serve. Returns, by block stored, the CIDs of the
    /// transactions it carries, read once from its transaction index. A
    /// block whose body or witness cannot be read ends the run: it and the
    /// blocks after it are not stored, and not in the result, so the job
    /// does not connect them (geth's `insertChain` stops at the first block
    /// it cannot import). Throws only when the store's write fails.
    /// `decoded` is the
    /// block's node as its connect decoded it (`ConnectVerdict.connectedBlock`),
    /// or nil to resolve it through `fetcher`.
    nonisolated func storeValidBlocks(
        _ blocks: [(cid: String, decoded: Block?)], at path: ChainPath, from fetcher: any Fetcher
    ) async throws -> [String: [String]] {
        var stored: [String: SerializedVolume] = [:]
        var retaining: [String: [String]] = [:]
        var carried: [String: [String]] = [:]
        var bundled: [(root: String, roots: [String])] = []
        let rulesScope = configuration.state == .all ? retentionScope : scopes.rules(at: path)
        for (cid, decoded) in blocks {
            do {
                let volumes: [SerializedVolume]
                if let fetched = await readCache.body(cid) {
                    volumes = fetched
                } else {
                    let walked = NodeImportStorage(storage: nil, keepsVolumes: true)
                    try await BlockHeader(rawCID: cid).storeBlockContent(fetcher: fetcher, storer: walked)
                    // A fetch's Volumes carry its witness; this walk reads it
                    // too, or the block is not stored, as for its content.
                    try await BlockHeader(rawCID: cid).storeParentReceiptWitness(fetcher: fetcher, storer: walked)
                    volumes = await walked.takeVolumes().map(\.volume)
                }
                let resolved: Block?
                if let decoded {
                    resolved = decoded
                } else {
                    resolved = try await BlockHeader(rawCID: cid).resolve(fetcher: fetcher).node
                }
                guard let block = resolved else { throw NodeAPIError.unresolvedTransactionContent }
                let transactions = try await NodeRuntime.carriedTransactionIDs(of: block, fetcher: fetcher)
                // What is neither the block's, its transactions' nor its
                // rules (spec and policy modules) is its receipt witness (for
                // a genesis, the empty state it starts from): body too.
                let roots = Set(volumes.map(\.root))
                let rules = await rules(of: block, fetcher: fetcher)
                let body = roots.subtracting(rules).union([cid] + transactions)
                var rest = roots.subtracting(body)
                if configuration.state != .all { rest.formIntersection(rules) }
                for volume in volumes where body.contains(volume.root) || rest.contains(volume.root) {
                    stored[volume.root] = volume
                }
                retaining[scopes.body(cid, at: path), default: []] += body.sorted()
                retaining[rulesScope, default: []] += rest.sorted()
                carried[cid] = transactions
                bundled.append((cid, roots.sorted()))
            } catch {
                syncTrace("body of \(cid) not stored: \(error)")
                break
            }
        }
        let volumes = try stored.keys.sorted().compactMap { try stored[$0].map(ValidatedVolume.init(trusting:)) }
        try await broker.storeVolumesLocal(volumes, retaining: retaining.filter { !$0.value.isEmpty })
        for (root, roots) in bundled { bundles.record(root: root, roots: roots) }
        return carried
    }

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
                let fetcher = CoalescingFetcher(CompositeContentSource([broker, session]))
                let walked = NodeImportStorage(storage: nil, keepsVolumes: true)
                do {
                    try await BlockHeader(rawCID: cid).storeBlockContent(fetcher: fetcher, storer: walked)
                    // With its receipt witness, which the bundle carries: a
                    // witness not obtained fails the fetch as content not
                    // obtained does (its execution could not read it either),
                    // and one past the reservation is retried under the
                    // whole allowance.
                    try await BlockHeader(rawCID: cid).storeParentReceiptWitness(fetcher: fetcher, storer: walked)
                    // The walk reached the end: the Volumes it derived are the
                    // ones storing the block would, and serve its connect.
                    await readCache.put(walked.takeVolumes().map(\.volume), block: cid)
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
            throw NodeStorageError.bodyExceedsLocalBudget(bytes: bytes)
        }
    }

    /// The Volume roots served together for `rootCID`, its own first: the
    /// content `storeBlockContent` defines for that block. Recorded when the
    /// block was stored; for a block stored before bundles were recorded, the same
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
            try await BlockHeader(rawCID: rootCID).storeBlockContent(fetcher: localFetcher, storer: walked)
        } catch {
            syncTrace("volume bundle of \(rootCID) not walked: \(error)")
            return [rootCID]
        }
        let witness = await receiptWitness(of: BlockHeader(rawCID: rootCID), fetcher: localFetcher).map(\.root)
        let roots = Set(await walked.takeStoredVolumeRoots() + witness).sorted()
        bundles.record(root: rootCID, roots: roots)
        return [rootCID] + roots.filter { $0 != rootCID }
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
        guard let remote else { return try await storeMinedBlock(header, block, at: path, fetcher: localFetcher) }
        return try await remote.withRootTracing(header.rawCID, bundle: false) { session in
            let children = try await storeMinedBlock(
                header, block, at: path, fetcher: ownReads(through: session)
            )
            return children
        }.value
    }

    private nonisolated func storeMinedBlock(
        _ header: BlockHeader, _ block: Block, at path: ChainPath, fetcher: any Fetcher
    ) async throws -> FlatDictionary<BlockHeader> {
        let roots = try await storingAndRetaining(header, at: path, from: fetcher) { storage in
            try await header.storeBlockContent(fetcher: fetcher, storer: storage)
        }
        bundles.record(root: header.rawCID, roots: roots)
        guard let children = try await block.children.resolve(fetcher: fetcher).node else {
            throw NodeStorageError.missingMaterializedVolume(block.children.rawCID)
        }
        return children
    }

    /// The child blocks a mined root carries at hosted levels, outermost
    /// first, each stored and with its proof from this root: only those the
    /// grind's work meets (a verified contribution), at any depth below
    /// carriers it misses.
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
                guard let proof = try await ChildBlockProof.extending(
                    proofToCarrier.map { [$0] }, by: BlockHeader(node: carrier), into: directory, fetcher: localFetcher
                ).first else { continue }
                guard case .success(let evidence) = proof.verifySecuringWork(child: block, chainPath: childPath)
                else { continue }
                // A block the grind's work misses is still walked: a carrier
                // need not meet its own target, so a descendant with an easier
                // one can be met through it. Only a met block (a verified
                // contribution) is stored and carried.
                frontier.append((block, childPath, proof))
                guard evidence.contribution != nil else { continue }
                let roots = try await storingAndRetaining(child, at: childPath, from: localFetcher) { storage in
                    try await child.storeBlockContent(fetcher: localFetcher, storer: storage)
                }
                bundles.record(root: child.rawCID, roots: roots)
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
