import Lattice
import cashew

/// What the node fetches and stores for a block, apart from the pre-state it
/// derives by executing the block's parent. The protocol defines the paths
/// (`Block.carriedContentPaths`, `Block.parentReceiptWitnessPaths`) and the
/// byte bound (`resolveBoundedContent`); which of them the node acquires,
/// and when, is the node's.
extension VolumeImpl where NodeType == Block {
    /// The complete block Volume and exactly the nested Volumes needed to
    /// validate it (`Block.validationPaths`), with its policy modules. Parent
    /// blocks and post-state are independent roots with their own retention.
    ///
    /// The transactions are fetched under the chain's own `maxBlockSize`
    /// (`resolveBoundedContent`): once their verified unique bytes exceed it
    /// the block is invalid, so this throws
    /// `BlockContentSizeError.exceedsLimit`, requests nothing further, and
    /// stores nothing. That error is a reason to execute the block, not a
    /// verdict on it: execution applies the rule itself.
    func storeBlock(fetcher: any Fetcher, storer: any VolumeStorer) async throws {
        let (content, spec) = try await resolveBoundedContent(fetcher: fetcher)
        guard let block = content.node, block.transactions.node != nil else {
            throw DataErrors.nodeNotAvailable
        }
        try await Self.store(
            content,
            paths: Block.validationPaths(
                transactionBodies: try Self.transactionBodies(of: content),
                rewardRecipient: block.rewardRecipient
            ),
            spec: spec, fetcher: fetcher, storer: storer
        )
    }

    /// The block's content: its complete Volume (with its child index), its
    /// spec, its transactions and its policy modules, the transactions read
    /// under the chain's `maxBlockSize` (`resolveBoundedContent`). Nothing
    /// under the block's prev, parent or post state is fetched or stored,
    /// except the constant empty state stored for a genesis (height-0)
    /// block.
    ///
    /// With `parentReceiptWitness`, it then stores the block's
    /// parent-receipt witness (`storeParentReceiptWitness`) from the content
    /// it resolved, without resolving it again: a block with no withdrawal
    /// reads and stores nothing more.
    func storeBlockContent(
        fetcher: any Fetcher, storer: any VolumeStorer, parentReceiptWitness: Bool = false
    ) async throws {
        let (content, spec) = try await resolveBoundedContent(fetcher: fetcher)
        guard content.node?.transactions.node != nil else { throw DataErrors.nodeNotAvailable }
        try await Self.store(content, paths: Block.carriedContentPaths, spec: spec, fetcher: fetcher, storer: storer)
        if parentReceiptWitness {
            try await Self.storeParentReceiptWitness(of: content, fetcher: fetcher, storer: storer)
        }
    }

    /// The parent-receipt witness of this block's withdrawals
    /// (`Block.parentReceiptWitnessPaths`): the nodes of its
    /// `parentState.receiptState` on the path to each withdrawal's receipt,
    /// from the parent state's root down. The block's own Volume is not
    /// among them (`storeBlockContent` stores it). A block with no
    /// withdrawal stores nothing and reads nothing under its parent state.
    ///
    /// `storeBlockContent` and this together hold everything executing the
    /// block reads but its pre-state: a node that let go of the parent
    /// chain's state can still execute a withdrawal it fetched with its
    /// witness.
    func storeParentReceiptWitness(fetcher: any Fetcher, storer: any VolumeStorer) async throws {
        let (content, _) = try await resolveBoundedContent(fetcher: fetcher)
        try await Self.storeParentReceiptWitness(of: content, fetcher: fetcher, storer: storer)
    }

    /// `paths` under resolved `content`, then the spec's policy modules, and
    /// for a genesis (height 0) the constant empty state it executes on.
    private static func store(
        _ content: Self,
        paths: [[String]: ResolutionStrategy],
        spec: ChainSpec,
        fetcher: any Fetcher,
        storer: any VolumeStorer
    ) async throws {
        let resolved = try await content.resolve(paths: paths, fetcher: fetcher)
        let storagePaths: [[String]: StorageStrategy] = paths.compactMapValues {
            switch $0 {
            case .targeted: .targeted
            case .recursive: .recursive
            case .list, .range: nil
            }
        }
        try await resolved.store(paths: storagePaths, storer: storer)
        for moduleCID in Set(spec.wasmPolicies.map(\.moduleCID)).sorted() {
            try await WasmPolicyModuleHeader(rawCID: moduleCID)
                .resolve(fetcher: fetcher)
                .store(storer: storer)
        }
        if content.node?.height == 0 {
            try await LatticeState.emptyHeader.storeRecursively(storer: storer)
        }
    }

    /// `storeParentReceiptWitness` of `content`, the block's resolved
    /// content (`resolveBoundedContent`).
    private static func storeParentReceiptWitness(
        of content: Self, fetcher: any Fetcher, storer: any VolumeStorer
    ) async throws {
        let paths = Block.parentReceiptWitnessPaths(transactionBodies: try transactionBodies(of: content))
        guard !paths.isEmpty else { return }
        let resolved = try await content.resolve(paths: paths, fetcher: fetcher)
        guard let parentState = resolved.node?.parentState else { throw DataErrors.nodeNotAvailable }
        let statePaths = Dictionary(uniqueKeysWithValues: paths.keys.map { (Array($0.dropFirst()), StorageStrategy.targeted) })
        try await parentState.store(paths: statePaths, storer: storer)
    }
}
