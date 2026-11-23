import Foundation
import Lattice
import LatticeNodeCore
import LatticeNodeAPI
import VolumeBroker
import cashew
import LatticeNodeSupport

/// The store side of the node runtime: the existing NodeStore (state.db) and
/// Volume broker of an opened `NodeStorage`, used as the effect executor's
/// persistence and content layer. Nothing here decides anything.
extension NodeStorage {
    /// One level's stored facts, in the order it took them.
    package nonisolated func nodeFacts(at path: ChainPath) async throws -> StoredFacts {
        try await store.storedFacts(at: path)
    }

    /// Policy modules an operator supplies while the node runs, stored as
    /// at start, with the root chain's constants, so a genesis that names
    /// one can be stored.
    package nonisolated func storePolicyModules(_ modules: [Data]) async throws {
        guard !modules.isEmpty else { return }
        let storage = NodeImportStorage(storage: stores.root)
        for bytes in modules {
            try await WasmPolicyModuleHeader(node: WasmPolicyModule(bytes: bytes)).store(storer: storage)
        }
        try await storage.commit()
        try await retainHeld(await storage.takeStoredVolumeRoots(), in: stores.root)
    }

    /// The weigh log id state.db recorded with its first chain fact.
    package nonisolated func chainLogID() async throws -> String? {
        try await store.chainLogID()
    }

    package nonisolated func chainCursors(at path: ChainPath) async throws -> [String: StreamCursor] {
        try await store.chainCursors(at: path)
    }

    /// `NodeEffect.persist`: content first — each affected level's Volumes
    /// in one transaction of its own chain's store, retained in the same
    /// one, store by store, shallowest level first — then the complete node step's
    /// headers, proofs, facts and cursors in one state.db transaction. A
    /// crash between stores leaves content no fact names, retained under its
    /// window's scope like any execution's: it goes when the tip is a window
    /// past it, or with its chain.
    package nonisolated func persistNodeBatch(_ batch: NodeBatch, logID: String) async throws {
        var durable: [NodeFactBatch] = []
        // Each level's content, for its own store, and where what its
        // executions created is kept there, by scope
        // (`StateBackend.keepExecuted`). An executed block's body was pinned
        // under its block's name by the job that executed it. Every root
        // retained is one the level's batch stores.
        var content: [(store: DiskBroker, volumes: [ValidatedVolume], retaining: [String: [String]])] = []
        let backend = stateBackend
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
            let chainStore = try stores.store(at: path)
            let storage = NodeImportStorage(storage: chainStore)
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
            let retaining = try await backend.keepExecuted(produced, specs: [], at: path)
            content.append((chainStore, await storage.takeVolumes(), retaining.filter { !$0.value.isEmpty }))
            // A child genesis's spec, what restore holds as its root's, is
            // the node's, in the root chain's store: a chain hosted again
            // after its own store went still starts from it.
            let specs = NodeImportStorage(storage: stores.root)
            for spec in level.headers.compactMap(\.spec) {
                try await VolumeImpl<ChainSpec>(node: spec).store(storer: specs)
            }
            let specRoots = await specs.takeStoredVolumeRoots()
            if !specRoots.isEmpty {
                content.append((stores.root, await specs.takeVolumes(), [retentionScope: specRoots]))
            }
            durable.append(NodeFactBatch(
                path: path,
                facts: level.facts,
                stateDiffs: level.stateDiffs,
                headers: level.headers,
                proofs: level.proofs,
                cursors: level.cursors,
                keepsStateDiffs: backend.keepsStateDiffs
            ))
        }
        for (chainStore, volumes, kept) in content where !volumes.isEmpty || !kept.isEmpty {
            syncTrace("stored state \(Self.storedLine(volumes, kept))")
            try await chainStore.storeVolumesLocal(volumes, retaining: kept)
        }
        try await store.stageNodeFacts(durable, logID: logID)
    }

    /// A trace line's account of one store: its Volumes, their entries, the
    /// entries' bytes and their CIDs' text, and the roots it retains.
    package static func storedLine(_ volumes: [ValidatedVolume], _ retaining: [String: [String]]) -> String {
        let entries = volumes.flatMap(\.volume.entries)
        return "volumes \(volumes.count) entries \(entries.count) bytes \(entries.reduce(0) { $0 + $1.value.count })"
            + " cidBytes \(entries.reduce(0) { $0 + $1.key.utf8.count }) retained \(retaining.values.reduce(0) { $0 + $1.count })"
    }

    /// Retains the roots this store holds, and returns the ones it lacks.
    /// One it lacks (a body fetched for this step and gone since) is no
    /// fault here: the facts still name it, and whatever reads it next
    /// fetches it. A merge refused for a root it lacks is made again with
    /// only the roots held.
    /// `broker` is the store of the chain the roots are kept for.
    @discardableResult
    package nonisolated func retainHeld(_ roots: [String], scope: String? = nil, in broker: DiskBroker) async throws -> [String] {
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

    /// How the operator's own work reads: the stores `scope` names, a
    /// block's header record, what is in memory (`readCache`), then peers,
    /// whose answers are kept there for the next read. Every read of
    /// materialized state the node's work makes (a block's pre-state when it
    /// executes, a template's, a mined block's) goes through here, so a peer
    /// is asked only for what neither these stores nor memory holds: a state
    /// this node let go of, as a reorganization past its kept windows needs.
    /// A block's body is fetched without its state (`fetchChainBody`).
    package nonisolated func ownReads(through peers: any ContentSource, _ scope: ReadScope) -> CoalescingFetcher {
        CoalescingFetcher(CompositeContentSource([
            stores.readers(scope).workSource, ReadTally.wrap("memory", readCache),
            ReadTally.wrap("peers", readCache.remembering(peers)),
        ]))
    }

    /// The stores `scope` names, and behind them the header records: a
    /// block's own node is read from them when its body is not held.
    /// Execution and mining build on blocks through this. One per scope,
    /// shared by its reads in flight.
    package nonisolated func workFetcher(_ scope: ReadScope) -> CoalescingFetcher {
        stores.readers(scope).work
    }

    /// The stores `scope` names alone.
    package nonisolated func localFetcher(_ scope: ReadScope) -> CoalescingFetcher {
        stores.readers(scope).local
    }

    /// How a reader's state read reads: the stores `scope` names, a block's
    /// header record, what is in memory, then peers, whose answers are not
    /// kept for later reads.
    package nonisolated func readersReads(through peers: any ContentSource, _ scope: ReadScope) -> CoalescingFetcher {
        CoalescingFetcher(CompositeContentSource([
            stores.readers(scope).workSource, ReadTally.wrap("memory", readCache), ReadTally.wrap("peers", peers),
        ]))
    }

    /// Stores a block and pins what was stored: its body is what `fetcher`,
    /// the content it was stored from, says it carries.
    package nonisolated func storingAndRetaining(
        _ header: BlockHeader, at path: ChainPath, from fetcher: any Fetcher,
        _ store: (NodeImportStorage) async throws -> Void
    ) async throws -> [String] {
        let blockCID = header.rawCID
        let storage = NodeImportStorage(storage: try stores.store(at: path))
        try await store(storage)
        try await storage.commit()
        // Read once the block's content is stored: the witness is read
        // through the block's transactions.
        let witness = await receiptWitness(of: header, fetcher: fetcher)
        for volume in witness { try await storage.store(volume: volume) }
        try await storage.commit()
        let roots = await storage.takeStoredVolumeRoots()
        let body = [blockCID] + (try await Self.carriedTransactionIDs(ofBlock: blockCID, fetcher: fetcher))
            + witness.map(\.root)
        try await retainStored(roots, body: body, ofBlock: blockCID, at: path)
        return roots
    }

    /// The transactions a block carries, by CID, as storing the block
    /// finds them: every entry of its transaction index, whatever its key.
    package static func carriedTransactionIDs(ofBlock cid: String, fetcher: any Fetcher) async throws -> [String] {
        guard let block = try await BlockHeader(rawCID: cid).resolve(fetcher: fetcher).node else {
            throw NodeAPIError.unresolvedTransactionContent
        }
        return try await carriedTransactionIDs(of: block, fetcher: fetcher)
    }

    /// `carriedTransactionIDs(ofBlock:)` of a block already decoded.
    package static func carriedTransactionIDs(of block: Block, fetcher: any Fetcher) async throws -> [String] {
        guard let index = try await block.transactions.resolve(fetcher: fetcher).node else {
            throw NodeAPIError.unresolvedTransactionContent
        }
        return try await index.boundedKeysAndValues(limit: index.count, fetcher: fetcher).map(\.1.rawCID)
    }

    /// A block's parent-receipt witness (`storeParentReceiptWitness`): the
    /// Volumes under its parent state on the path to each of its
    /// withdrawals' receipts, which its execution reads. They are its body's
    /// as much as its transactions are: fetched, stored, pinned under its
    /// name, and served with it, so the block executes where its parent's
    /// state is gone. None for a block without withdrawals, or when
    /// `fetcher` cannot read them (the execution then reads them itself).
    package nonisolated func receiptWitness(of block: BlockHeader, fetcher: any Fetcher) async -> [SerializedVolume] {
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
    package nonisolated func storeValidBlock(
        _ cid: String, decoded: Block? = nil, at path: ChainPath, from fetcher: any Fetcher
    ) async throws -> [String] {
        guard let transactions = try await storeValidBlocks([(cid, decoded)], at: path, from: fetcher)[cid] else {
            throw NodeAPIError.unresolvedTransactionContent
        }
        return transactions
    }

    /// Stores the blocks of one connect job execution found valid, and pins
    /// them, in one transaction of the chain's Volume store. A body fetched from peers is
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
    package nonisolated func storeValidBlocks(
        _ blocks: [(cid: String, decoded: Block?)], at path: ChainPath, from fetcher: any Fetcher
    ) async throws -> [String: [String]] {
        var stored: [String: SerializedVolume] = [:]
        var retaining: [String: [String]] = [:]
        var carried: [String: [String]] = [:]
        var bundled: [(root: String, roots: [String])] = []
        // A chain's blocks all name its genesis's spec (spec continuity):
        // its rules are read once for the job, not once a block.
        var rulesBySpec: [String: Set<String>] = [:]
        let backend = stateBackend
        for (cid, decoded) in blocks {
            do {
                let volumes: [SerializedVolume]
                if let fetched = await readCache.body(cid) {
                    volumes = fetched
                } else {
                    let walked = NodeImportStorage(storage: nil, keepsVolumes: true)
                    // A fetch's Volumes carry its witness; this walk reads it
                    // too, or the block is not stored, as for its content.
                    try await BlockHeader(rawCID: cid)
                        .storeBlockContent(fetcher: fetcher, storer: walked, parentReceiptWitness: true)
                    volumes = await walked.takeVolumes().map(\.volume)
                }
                let resolved: Block?
                if let decoded {
                    resolved = decoded
                } else {
                    resolved = try await BlockHeader(rawCID: cid).resolve(fetcher: fetcher).node
                }
                guard let block = resolved else { throw NodeAPIError.unresolvedTransactionContent }
                let transactions = try await Self.carriedTransactionIDs(of: block, fetcher: fetcher)
                // What is neither the block's, its transactions' nor its
                // rules (spec and policy modules) is its receipt witness (for
                // a genesis, the empty state it starts from): body too.
                let roots = Set(volumes.map(\.root))
                let rules: Set<String>
                if let held = rulesBySpec[block.spec.rawCID] {
                    rules = held
                } else {
                    rules = await self.rules(of: block, fetcher: fetcher)
                    if !rules.isEmpty { rulesBySpec[block.spec.rawCID] = rules }
                }
                let body = roots.subtracting(rules).union([cid] + transactions)
                let (rulesScope, rest) = backend.keepWithValidBlock(roots.subtracting(body), rules: rules, at: path)
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
        syncTrace("stored body \(Self.storedLine(volumes, retaining))")
        try await stores.store(at: path).storeVolumesLocal(volumes, retaining: retaining.filter { !$0.value.isEmpty })
        bundles.record(bundled)
        return carried
    }

    /// Why a body's walk failed: when what it read, with this store, holds
    /// the block's whole content, what no peer served is the receipt proofs
    /// that travel with it (`receiptProofsUnavailable`); otherwise `error`.
    package nonisolated func incompleteBody(_ cid: String, read: [SerializedVolume], error: any Error) async -> any Error {
        var entries: [String: Data] = [:]
        for volume in read { entries.merge(volume.entries) { first, _ in first } }
        let local = CompositeContentSource([InMemoryContentSource(entries), stores.anyChain])
        let content = NodeImportStorage(storage: nil, keepsVolumes: true)
        guard (try? await BlockHeader(rawCID: cid).storeBlockContent(
            fetcher: CoalescingFetcher(local), storer: content
        )) != nil else { return error }
        return NodeStorageError.receiptProofsUnavailable(cid)
    }

    /// The Volume roots served together for `rootCID`, its own first: the
    /// content `storeBlockContent` defines for that block. Recorded when the
    /// block was stored; for a block stored before bundles were recorded, the same
    /// walk over local content only, recorded once it completes. A root that
    /// is no block this node holds whole bundles only itself.
    package nonisolated func volumeBundle(_ rootCID: String) async -> [String] {
        // A recording outlives a store a start removed: one whose block is
        // no longer held is not advertised. A served bundle names no chain,
        // so this asks every store: a known cost per bundle served.
        if let recorded = bundles.bundle(root: rootCID) {
            return await stores.anyChain.hasVolume(root: rootCID) ? recorded : [rootCID]
        }
        // Not a block this node holds: nothing to walk, and nothing to say.
        guard let bytes = await stores.anyChain.fetchDataLocal(cid: rootCID), Block(data: bytes) != nil else {
            return [rootCID]
        }
        let walked = NodeImportStorage(storage: nil)
        do {
            try await BlockHeader(rawCID: rootCID).storeBlockContent(fetcher: localFetcher(.anyChain), storer: walked)
        } catch {
            syncTrace("volume bundle of \(rootCID) not walked: \(error)")
            return [rootCID]
        }
        let witness = await receiptWitness(of: BlockHeader(rawCID: rootCID), fetcher: localFetcher(.anyChain)).map(\.root)
        let roots = Set(await walked.takeStoredVolumeRoots() + witness).sorted()
        bundles.record(root: rootCID, roots: roots)
        return [rootCID] + roots.filter { $0 != rootCID }
    }

    package nonisolated func storeMinedBlock(
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

    package nonisolated func carriedGrinds(
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
    package nonisolated func persistPoolDelta(_ delta: PoolDelta) async throws {
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

    /// The spec a stored genesis header names, from local content.
    /// A child genesis header lives in the header store (its body may not be
    /// fetched yet); its spec Volume was stored with it.
    /// `operatorSpecs` are the operator's specs now, when they changed since
    /// start.
    package nonisolated func chainGenesisSpec(
        _ cid: String, operatorSpecs: [ChainPath: ChainSpec]? = nil
    ) async throws -> ChainSpec? {
        guard let block = await chainHeader(cid)?.block else { return nil }
        if let held = try? await block.spec.resolve(fetcher: localFetcher(.anyChain)).node { return held }
        // Not in the store: the operator's own spec for a chain it created
        // is the same content if it has the same CID, and is stored again.
        for spec in (operatorSpecs ?? configuration.childSpecs).values {
            let volume = try VolumeImpl<ChainSpec>(node: spec)
            guard volume.rawCID == block.spec.rawCID else { continue }
            // With the root chain's constants, as the operator's modules are.
            let storage = NodeImportStorage(storage: stores.root)
            try await volume.store(storer: storage)
            try await storage.commit()
            try await retainHeld(await storage.takeStoredVolumeRoots(), in: stores.root)
            return spec
        }
        return nil
    }

    package nonisolated func chainHeader(_ cid: String) async -> (block: Block, children: FlatDictionary<BlockHeader>)? {
        if let stored = store.header(cid) { return stored }
        guard let blockBytes = try? await localFetcher(.anyChain).fetch(rawCid: cid),
              let block = Block(data: blockBytes),
              let childBytes = try? await localFetcher(.anyChain).fetch(rawCid: block.children.rawCID),
              let children = FlatDictionary<BlockHeader>(data: childBytes) else { return nil }
        return (block, children)
    }

    /// Store an execution's materialized post-state: every Volume the
    /// execution loaded, each as its own boundary.
    package static func storeExecutedState(_ state: LatticeState, in storer: any VolumeStorer) async throws {
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
    package static func children(of header: any Header) -> [any Header] {
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
