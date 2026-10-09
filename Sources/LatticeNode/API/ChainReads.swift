import Foundation
import Ivy
import Lattice
import LatticeLightClient
import cashew

/// The node's read surface — chain status, blocks, transactions, state reads
/// and the explorer API — over content-verified, by-CID reads of this
/// chain's store and a tip source. Nothing here takes a gate or mutates:
/// content is immutable by CID, so only the tip, the canonical height index
/// and the mempool listing are read live from `NodeRuntime`'s published view.
public struct ChainReads: Sendable {
    public struct MempoolListing: Sendable {
        public let count: Int
        public let bytes: Int
        /// The pooled transaction CIDs.
        public let cids: [String]

        public init(count: Int, bytes: Int, cids: [String]) {
            self.count = count
            self.bytes = bytes
            self.cids = cids
        }
    }

    private static let maximumReadResponseBytes = Int(IvyConfig.defaultProtocolMaxFrameSize)
    private static let maximumExplorerPageLimit = 100
    private static let maximumExplorerMempoolListing = 200
    /// Each listed height costs three local reads (index, block, transactions
    /// root), and the list is billed as a cheap read: a page stays small.
    public static let maximumExplorerBlocksPage = 25

    private static func boundedExplorerLimit(_ limit: Int) -> Int {
        min(max(limit, 0), maximumExplorerPageLimit)
    }

    let storage: NodeStorage
    /// The tip readers see: the tip this node acts on, its heaviest executed tip.
    let tip: @Sendable () async -> ChainStatus
    /// The block at a height of the chain to that tip.
    let canonicalCID: @Sendable (UInt64) async -> String?
    /// The pool's size, and its CIDs only when `listing` (status reads
    /// never build the listing).
    let mempool: @Sendable (_ listing: Bool) async -> MempoolListing
    /// The chain these reads serve: the root, or a hosted child level.
    public let chainPath: [String]
    /// Whether this chain durably accepted a block (its own journal).
    let accepted: @Sendable (String) async -> Bool

    init(
        storage: NodeStorage,
        chainPath: [String]? = nil,
        accepted: (@Sendable (String) async -> Bool)? = nil,
        tip: @escaping @Sendable () async -> ChainStatus,
        canonicalCID: @escaping @Sendable (UInt64) async -> String?,
        mempool: @escaping @Sendable (_ listing: Bool) async -> MempoolListing
    ) {
        self.storage = storage
        self.chainPath = chainPath ?? storage.configuration.chainPath
        if let accepted {
            self.accepted = accepted
        } else {
            self.accepted = { await storage.hasAcceptedBlock($0) }
        }
        self.tip = tip
        self.canonicalCID = canonicalCID
        self.mempool = mempool
    }

    /// Public status read over the immutable published view.
    public func readSnapshot() async -> NodeStatusResponse {
        let status = await tip()
        let pool = await mempool(false)
        let phase: NodeAPIPhase = status.phase == .active
            ? .active
            : .awaitingGenesis
        return NodeStatusResponse(
            phase: phase,
            chainPath: status.chainPath,
            nexusGenesisCID: status.nexusGenesisCID,
            tipCID: status.tipCID,
            height: status.height,
            revision: status.revision,
            mempoolCount: pool.count,
            mempoolBytes: pool.bytes,
            templateDigest: nil,
            bestHeaderHeight: status.bestHeaderHeight,
            waiting: status.waiting
        )
    }

    /// A decoded, content-verified block, gated to only what this node has
    /// durably accepted. It reads `NodeStorage` directly without entering the
    /// runtime loop.
    func block(cid: String) async -> Block? {
        guard await accepted(cid) else { return nil }
        guard let data = await storage.content([cid])[cid],
              data.count <= Self.maximumReadResponseBytes else {
            return nil
        }
        return _contentBoundBlock(cid: cid, data: data)
    }

    /// Bounded public read: a decoded, content-verified transaction. Resolving
    /// and content-binding as a `Transaction` is itself the gate that keeps
    /// internal (non-transaction) objects from being served by CID.
    public func transaction(cid: String) async -> Transaction? {
        guard let data = await storage.content([cid])[cid],
              data.count <= Self.maximumReadResponseBytes else {
            return nil
        }
        guard let transaction = Transaction(data: data),
              (try? VolumeImpl<Transaction>(node: transaction).rawCID) == cid
        else { return nil }
        return transaction
    }

    /// Bounded public read: an account's balance and next-expected nonce as of
    /// one accepted block's post-state. It uses direct storage reads plus
    /// targeted trie resolution without entering the runtime loop.
    public func account(
        owner: String,
        blockCID: String
    ) async -> (balance: UInt64, nonce: UInt64)? {
        guard await accepted(blockCID) else { return nil }
        guard let data = await storage.content([blockCID])[blockCID],
              data.count <= Self.maximumReadResponseBytes,
              let block = _contentBoundBlock(cid: blockCID, data: data) else {
            return nil
        }
        guard let state = try? await block.postState.resolve(fetcher: storage).node else {
            return nil
        }
        guard let nonce = try? await state.accountState.nextExpectedNonce(
                for: owner,
                fetcher: storage
              ),
              let resolved = try? await state.accountState.resolve(
                paths: [[owner]: .targeted],
                fetcher: storage
              ),
              let accountNode = resolved.node else {
            return nil
        }
        let balance: UInt64 = (try? accountNode.get(key: owner)) ?? 0
        return (balance: balance, nonce: nonce)
    }

    // MARK: - Explorer read API
    //
    // Public reads for the browser explorer. Each mirrors the bounded,
    // content-verified by-CID path above and never enters the runtime loop.

    /// The absolute chain path served by this read surface. Used by the daemon
    /// to answer the explorer's optional `?chainPath=` filter.
    public func explorerChainPath() -> [String] {
        chainPath
    }

    /// Main-chain block CID at `height` (ungated height-index lookup), so the
    /// daemon can resolve a numeric `:id` to a CID before reading.
    public func explorerCanonicalBlockCID(atHeight height: UInt64) async -> String? {
        await canonicalCID(height)
    }

    /// The tip block's summary: one bounded block fetch plus its
    /// transactions-dictionary header (for the count); no transaction body is
    /// fetched.
    public func explorerLatestBlock() async -> ExplorerLatestBlock? {
        guard let cid = await tip().tipCID,
              let data = await storage.content([cid])[cid],
              data.count <= Self.maximumReadResponseBytes,
              let block = _contentBoundBlock(cid: cid, data: data) else {
            return nil
        }
        let transactionCount = (try? await block.transactions.resolve(
            fetcher: storage
        ))?.node?.count ?? 0
        return ExplorerLatestBlock(
            height: block.height,
            hash: cid,
            transactionCount: transactionCount,
            timestamp: block.timestamp,
            previousBlock: block.parent?.rawCID,
            rewardRecipient: block.rewardRecipient,
            rewardCredited: await rewardCredited(by: block)
        )
    }

    /// A page of canonical block summaries below height `before` (default:
    /// past the tip), newest first. Reads each block and its transactions
    /// dictionary root (for the count) — never a transaction body.
    public func explorerBlocks(before: UInt64?, limit: Int) async -> ExplorerBlocksPage {
        let boundedLimit = min(max(limit, 0), Self.maximumExplorerBlocksPage)
        guard let tipHeight = await tip().height else {
            return ExplorerBlocksPage(blocks: [], nextBefore: nil)
        }
        // `before` is caller-controlled: clamp before any arithmetic.
        var height = min(before ?? tipHeight + 1, tipHeight + 1)
        var blocks: [ExplorerBlockSummary] = []
        // At most `limit` heights are visited: a height whose block is not
        // held here is skipped, not replaced by an older one.
        for _ in 0..<boundedLimit where height > 0 {
            height -= 1
            guard let cid = await canonicalCID(height),
                  let block = await block(cid: cid) else { continue }
            let transactionCount = (try? await block.transactions.resolve(
                fetcher: storage
            ))?.node?.count ?? 0
            blocks.append(ExplorerBlockSummary(
                height: block.height,
                hash: cid,
                previousBlock: block.parent?.rawCID,
                timestamp: block.timestamp,
                transactionCount: transactionCount,
                rewardRecipient: block.rewardRecipient
            ))
        }
        return ExplorerBlocksPage(blocks: blocks, nextBefore: height > 0 ? height : nil)
    }

    public func explorerBlock(cid: String) async -> ExplorerBlock? {
        guard let block = await block(cid: cid) else { return nil }
        let transactionCount = (try? await block.transactions.resolve(
            fetcher: storage
        ))?.node?.count ?? 0
        let childBlockCount = (try? await block.children.resolve(
            fetcher: storage
        ))?.node?.count ?? 0
        return ExplorerBlock(
            height: block.height,
            hash: cid,
            timestamp: block.timestamp,
            previousBlock: block.parent?.rawCID,
            transactionCount: transactionCount,
            childBlockCount: childBlockCount,
            nonce: block.nonce,
            version: block.version,
            target: block.target,
            nextTarget: block.nextTarget,
            transactionsCID: block.transactions.rawCID,
            postStateCID: block.postState.rawCID,
            chain: chainPath,
            rewardRecipient: block.rewardRecipient,
            rewardCredited: await rewardCredited(by: block)
        )
    }

    /// What `block` credited its recipient: the block reward plus fees, by
    /// the rule consensus applies (`Block.coinbaseAmount`). 0 when there is
    /// no recipient (burned); nil when the block's content is not held here.
    private func rewardCredited(by block: Block) async -> UInt64? {
        guard block.rewardRecipient != nil else { return 0 }
        guard let spec = try? await block.spec.resolve(fetcher: storage).node,
              let transactions = try? await MiningTemplateAssembly.blockTransactions(in: block, fetcher: storage)
        else { return nil }
        var bodies: [TransactionBody] = []
        for transaction in transactions {
            guard let body = try? await transaction.body.resolve(
                fetcher: storage
            ).node else { return nil }
            bodies.append(body)
        }
        guard case .success(let amount) = Block.coinbaseAmount(
            spec: spec,
            height: block.height,
            accountActions: bodies.flatMap(\.accountActions),
            depositActions: bodies.flatMap(\.depositActions),
            withdrawalActions: bodies.flatMap(\.withdrawalActions)
        ) else { return nil }
        return amount.uint64Value
    }

    /// Page over an accepted block's transaction dictionary by numeric index
    /// [offset, offset+limit). Each index is a *targeted* resolution of just
    /// that key — never a full `boundedKeysAndValues(limit: count)` fan-out —
    /// so an untrusted request cannot force materializing the whole dictionary.
    public func explorerBlockTransactions(
        cid: String,
        offset: Int,
        limit: Int
    ) async -> ExplorerBlockTransactions? {
        guard offset >= 0 else { return nil }
        guard let block = await block(cid: cid) else { return nil }
        guard let dictionary = (try? await block.transactions.resolve(
            fetcher: storage
        ))?.node else { return nil }
        let total = dictionary.count
        let boundedLimit = Self.boundedExplorerLimit(limit)
        // Short-circuit before the addition: a public caller controls `offset`,
        // and `offset + boundedLimit` would be a checked-arithmetic TRAP (an
        // uncatchable crash, not a throwable) for an offset near Int.max. With
        // offset < total (a small, consensus-bounded count) the add is safe.
        guard offset < total else {
            return ExplorerBlockTransactions(transactions: [], nextOffset: nil)
        }
        let end = min(offset + boundedLimit, total)
        var summaries: [ExplorerTransactionSummary] = []
        if offset < end {
            for index in offset..<end {
                let key = String(index)
                guard let node = (try? await block.transactions.resolve(
                        paths: [[key]: .targeted],
                        fetcher: storage
                      ))?.node,
                      let volume = (try? node.get(key: key)) ?? nil else {
                    continue
                }
                guard let transaction = try? await volume.resolve(
                        fetcher: storage
                      ).node,
                      let body = try? await transaction.body.resolve(
                        fetcher: storage
                      ).node else {
                    continue
                }
                summaries.append(ExplorerTransactionSummary(
                    txCID: volume.rawCID,
                    signers: body.signers,
                    accountActionCount: body.accountActions.count,
                    depositActionCount: body.depositActions.count,
                    receiptActionCount: body.receiptActions.count,
                    withdrawalActionCount: body.withdrawalActions.count
                ))
            }
        }
        return ExplorerBlockTransactions(
            transactions: summaries,
            nextOffset: end < total ? end : nil
        )
    }

    public func explorerBlockChildren(
        cid: String,
        limit: Int
    ) async -> ExplorerBlockChildren? {
        guard let block = await block(cid: cid) else { return nil }
        guard let index = (try? await block.children.resolve(
            fetcher: storage
        ))?.node else { return nil }
        let boundedLimit = Self.boundedExplorerLimit(limit)
        guard boundedLimit > 0 else { return ExplorerBlockChildren(children: []) }
        // The index is one node: the first `limit` directories in order.
        let entries = index.entries.keys.sorted().prefix(boundedLimit).map {
            ($0, index.entries[$0]!)
        }
        var children: [ExplorerChildBlock] = []
        for (directory, volume) in entries {
            // A child chain this node does not host has its commitment here
            // but not its block: listed by CID, without the block's details.
            let child = try? await volume.resolve(fetcher: storage).node
            var transactionCount: Int?
            if let child {
                transactionCount = (try? await child.transactions.resolve(fetcher: storage))?.node?.count ?? 0
            }
            children.append(ExplorerChildBlock(
                directory: directory,
                blockHash: volume.rawCID,
                height: child?.height,
                transactionCount: transactionCount
            ))
        }
        return ExplorerBlockChildren(children: children)
    }

    /// The newest child block this chain's canonical blocks commit under
    /// `directory`, looking back at most `depth` blocks from the tip: the
    /// commitment a reader checks a child's claimed read URL against.
    public func committedChild(directory: String, depth: UInt64 = 64) async -> String? {
        guard let top = await tip().height else { return nil }
        var height = top
        while top - height < depth {
            if let cid = await canonicalCID(height), let block = await block(cid: cid),
               let index = (try? await block.children.resolve(fetcher: storage))?.node,
               let child = index.entries[directory] {
                return child.rawCID
            }
            guard height > 0 else { return nil }
            height -= 1
        }
        return nil
    }

    public func explorerTransaction(cid: String) async -> ExplorerTransaction? {
        guard let transaction = await transaction(cid: cid) else { return nil }
        guard let body = try? await transaction.body.resolve(fetcher: storage).node else {
            return nil
        }
        let inclusion = await canonicalInclusion(cid: cid, body: body)
        return ExplorerTransaction(
            txCID: cid,
            blockHeight: inclusion?.height,
            blockHash: inclusion?.hash,
            timestamp: inclusion?.timestamp,
            nonce: body.nonce,
            signers: body.signers,
            chainPath: body.chainPath,
            chain: body.chainPath,
            accountActions: body.accountActions.map {
                ExplorerAccountAction(owner: $0.owner, delta: $0.delta)
            },
            depositActions: body.depositActions.map {
                ExplorerDepositAction(
                    nonce: String($0.nonce),
                    demander: $0.demander,
                    amountDemanded: $0.amountDemanded,
                    amountDeposited: $0.amountDeposited
                )
            },
            receiptActions: body.receiptActions.map {
                ExplorerReceiptAction(
                    withdrawer: $0.withdrawer,
                    nonce: String($0.nonce),
                    demander: $0.demander,
                    amountDemanded: $0.amountDemanded,
                    directory: $0.directory
                )
            },
            withdrawalActions: body.withdrawalActions.map {
                ExplorerWithdrawalAction(
                    withdrawer: $0.withdrawer,
                    nonce: String($0.nonce),
                    demander: $0.demander,
                    amountDemanded: $0.amountDemanded,
                    amountWithdrawn: $0.amountWithdrawn
                )
            }
        )
    }

    /// The canonical block that executed transaction `cid`, derived at read
    /// time, with no index: every signer's next-expected nonce only ever rises
    /// along the canonical chain, and executing this transaction is what moves
    /// its first signer's past `body.nonce`. So the block is the lowest height
    /// whose post-state nonce exceeds it (a binary search: at most ~64 account
    /// reads), and the transaction is included only if that block's
    /// transaction list holds its CID — a rival at the same nonce moves the
    /// nonce too. Nil when it is not in this chain's canonical executed
    /// chain, or the content needed to tell is not held here. Reorg-correct by
    /// construction: only the current canonical chain is read.
    func canonicalInclusion(
        cid: String,
        body: TransactionBody
    ) async -> (height: UInt64, hash: String, timestamp: Int64)? {
        guard body.chainPath == chainPath, let signer = body.signers.first,
              let tipCID = await tip().tipCID, let tipBlock = await block(cid: tipCID),
              let tipNonce = await nextNonce(of: signer, in: tipBlock),
              tipNonce > body.nonce else {
            return nil
        }
        // Invariant: nonce(high) > body.nonce; nonce(low - 1) <= body.nonce.
        var low: UInt64 = 0
        var high = tipBlock.height
        while low < high {
            let middle = low + (high - low) / 2
            guard let middleCID = await canonicalCID(middle),
                  let middleBlock = await block(cid: middleCID),
                  let nonce = await nextNonce(of: signer, in: middleBlock) else {
                return nil
            }
            if nonce > body.nonce { high = middle } else { low = middle + 1 }
        }
        guard let blockCID = await canonicalCID(high),
              let block = await block(cid: blockCID),
              await carries(block, transaction: cid),
              await canonicalCID(high) == blockCID else {
            return nil
        }
        return (height: high, hash: blockCID, timestamp: block.timestamp)
    }

    /// `signer`'s next-expected nonce in `block`'s post-state.
    private func nextNonce(of signer: String, in block: Block) async -> UInt64? {
        guard let state = try? await block.postState.resolve(fetcher: storage).node else {
            return nil
        }
        return try? await state.accountState.nextExpectedNonce(for: signer, fetcher: storage)
    }

    /// Whether `block`'s transaction list holds `cid`. Reads the list's
    /// entries (transaction CIDs), never a transaction body; the list is
    /// bounded by the chain's own per-block transaction limit.
    private func carries(_ block: Block, transaction cid: String) async -> Bool {
        guard let dictionary = (try? await block.transactions.resolve(fetcher: storage))?.node,
              let entries = try? await dictionary.boundedKeysAndValues(
                limit: dictionary.count, fetcher: storage
              ) else { return false }
        return entries.contains { $0.1.rawCID == cid }
    }

    public func explorerAccount(owner: String) async -> ExplorerAccount? {
        guard let tip = await tip().tipCID else { return nil }
        guard let account = await account(owner: owner, blockCID: tip) else { return nil }
        return ExplorerAccount(
            owner: owner,
            balance: account.balance,
            nonce: account.nonce
        )
    }

    /// Active deposits in the canonical tip state. The page is bounded before
    /// resolving trie values so this remains safe on the public read surface.
    public func explorerDeposits(limit: Int, after: String?) async throws -> ExplorerDepositsPage? {
        guard let tipCID = await tip().tipCID,
              let block = await block(cid: tipCID),
              let resolvedState = try? await block.postState.resolve(fetcher: storage),
              let state = resolvedState.node,
              let deposits = try? await state.depositState.resolve(fetcher: storage).node else {
            return nil
        }
        let boundedLimit = Self.boundedExplorerLimit(limit)
        guard let scanned = try? await deposits.boundedKeysAndValues(
            after: after,
            limit: boundedLimit + 1,
            fetcher: storage
        ) else { return nil }
        let entries = Array(scanned.prefix(boundedLimit))
        let next = scanned.count > boundedLimit ? entries.last?.key : nil
        let listed = entries.filter { $0.value > 0 && DepositKey($0.key) != nil }
        let created = await canonicalDepositInclusions(
            keys: listed.map(\.key), tipCID: tipCID, tipBlock: block, tipRoot: state.depositState.rawCID
        )
        var active: [ExplorerDeposit] = []
        for entry in listed {
            guard let key = DepositKey(entry.key) else { continue }
            active.append(ExplorerDeposit(
                key: entry.key,
                demander: key.demander,
                amountDemanded: key.amountDemanded,
                nonce: String(key.nonce),
                amountDeposited: entry.value,
                blockHeight: created[entry.key]?.height,
                blockHash: created[entry.key]?.hash
            ))
        }
        let proofPaths = Swift.Dictionary(uniqueKeysWithValues: entries.map { ([$0.key], SparseMerkleProof.existence) })
        let proven = entries.isEmpty
            ? try DepositStateHeader(node: deposits)
            : try await state.depositState.proof(paths: proofPaths, fetcher: storage)
        let proof = try await stateProof(
            blockCID: tipCID, block: block, state: resolvedState,
            dictionary: .deposits, dictionaryHeader: proven,
            claims: entries.map { .init(key: $0.key, value: String($0.value)) }
        )
        return ExplorerDepositsPage(
            deposits: active,
            chain: chainPath.joined(separator: "/"),
            next: next,
            proof: proof
        )
    }

    /// The canonical block that created each of `keys`, derived at read time
    /// with no index, as `canonicalInclusion` does for a transaction: a
    /// deposit key is absent until the block that inserts it and never
    /// removed afterwards (a withdrawal leaves a zero marker), so presence
    /// only ever turns on along the canonical chain. A key's creating block is
    /// the lowest height whose post-state holds it.
    ///
    /// One search serves the whole page. A probed height is loaded once and
    /// asked about every key still undecided in its range, which then splits
    /// into the keys already present (search below) and not yet (search
    /// above). The deposit dictionary is content-addressed, so a height whose
    /// dictionary root was already read answers with no trie read at all;
    /// most blocks carry no deposit or withdrawal and repeat their parent's.
    ///
    /// `tipBlock` must hold every key, under dictionary root `tipRoot`. A key
    /// is left out when a state needed to place it is not held here; nothing
    /// is returned if the canonical chain moved during the search.
    func canonicalDepositInclusions(
        keys: [String], tipCID: String, tipBlock: Block, tipRoot: String
    ) async -> [String: (height: UInt64, hash: String)] {
        guard !keys.isEmpty else { return [:] }
        // Keys present under a dictionary root, for every key ever asked of it.
        var known: [String: [String: Bool]] = [tipRoot: Dictionary(uniqueKeysWithValues: keys.map { ($0, true) })]
        var heights: [String: UInt64] = [:]
        // Invariant per range: every key present(high); absent(low - 1).
        var ranges: [(low: UInt64, high: UInt64, keys: [String])] = [(0, tipBlock.height, keys)]
        while let range = ranges.popLast() {
            if range.low == range.high {
                for key in range.keys { heights[key] = range.high }
                continue
            }
            let middle = range.low + (range.high - range.low) / 2
            guard let middleCID = await canonicalCID(middle),
                  let middleBlock = await block(cid: middleCID),
                  let state = try? await middleBlock.postState.resolve(fetcher: storage).node else {
                continue // not held here: these keys go unplaced
            }
            let root = state.depositState.rawCID
            let unread = range.keys.filter { known[root]?[$0] == nil }
            if !unread.isEmpty {
                let paths = Swift.Dictionary(uniqueKeysWithValues: unread.map { ([$0], ResolutionStrategy.targeted) })
                guard let deposits = try? await state.depositState.resolve(paths: paths, fetcher: storage).node else {
                    continue
                }
                for key in unread { known[root, default: [:]][key] = (try? deposits.get(key: key)) != nil }
            }
            let present = range.keys.filter { known[root]?[$0] == true }
            let absent = range.keys.filter { known[root]?[$0] != true }
            if !present.isEmpty { ranges.append((range.low, middle, present)) }
            if !absent.isEmpty { ranges.append((middle + 1, range.high, absent)) }
        }
        var hashes: [UInt64: String] = [:]
        for height in Set(heights.values) {
            if let cid = await canonicalCID(height) { hashes[height] = cid }
        }
        // The heights read name one chain only if the tip still names it.
        guard await canonicalCID(tipBlock.height) == tipCID else { return [:] }
        var created: [String: (height: UInt64, hash: String)] = [:]
        for (key, height) in heights {
            if let hash = hashes[height] { created[key] = (height: height, hash: hash) }
        }
        return created
    }

    /// The withdrawer recorded by a receipt on this (parent) chain.
    public func explorerReceiptState(
        demander: String,
        amountDemanded: UInt64,
        nonce: UInt128,
        destinationPath: [String]
    ) async throws -> ExplorerReceiptState? {
        guard let directory = destinationPath.last,
              let tipCID = await tip().tipCID,
              let block = await block(cid: tipCID),
              let resolvedState = try? await block.postState.resolve(fetcher: storage),
              let state = resolvedState.node else {
            return nil
        }
        let logicalKey = ReceiptKey(receiptAction: ReceiptAction(
            withdrawer: "",
            nonce: nonce,
            demander: demander,
            amountDemanded: amountDemanded,
            directory: directory
        ))
        let targeted = try? await state.receiptState.resolve(
            paths: [[logicalKey.storageKey]: .targeted],
            fetcher: storage
        ).node
        let withdrawer = targeted.flatMap { try? $0.get(key: logicalKey.storageKey) }
        let proofKind: SparseMerkleProof = withdrawer == nil ? .insertion : .existence
        let proven = try await state.receiptState.proof(
            paths: [[logicalKey.storageKey]: proofKind], fetcher: storage
        )
        let proof = try await stateProof(
            blockCID: tipCID, block: block, state: resolvedState,
            dictionary: .receipts, dictionaryHeader: proven,
            claims: [.init(key: logicalKey.storageKey, value: withdrawer)]
        )
        return ExplorerReceiptState(
            withdrawer: withdrawer,
            directory: directory,
            chainPath: destinationPath,
            key: logicalKey.description,
            proof: proof
        )
    }

    private func stateProof<NodeType>(
        blockCID: String, block: Block, state: LatticeStateHeader,
        dictionary: StateDictionaryProof.StateKind,
        dictionaryHeader: VolumeImpl<NodeType>,
        claims: [StateDictionaryProof.Claim]
    ) async throws -> StateDictionaryProof where NodeType: Node {
        let collector = ProofVolumeCollector()
        let storagePaths = Swift.Dictionary(uniqueKeysWithValues: claims.map { ([$0.key], StorageStrategy.targeted) })
        try await dictionaryHeader.store(paths: storagePaths, storer: collector)
        try await state.store(storer: collector)
        let blockData = try await storage.fetch(rawCid: blockCID)
        return StateDictionaryProof(
            blockHash: blockCID, blockHeight: block.height,
            block: .init(cid: blockCID, data: blockData), stateRoot: state.rawCID,
            dictionary: dictionary, dictionaryRoot: dictionaryHeader.rawCID,
            claims: claims, witness: await collector.witness()
        )
    }

    /// Ungated mempool snapshot: the pool's live CIDs, hard-capped at 200.
    public func explorerMempool() async -> ExplorerMempool {
        let pool = await mempool(true)
        let cids = pool.cids
        return ExplorerMempool(
            count: pool.count,
            transactions: Array(cids.prefix(Self.maximumExplorerMempoolListing))
        )
    }

    public func explorerChainInfo() async -> ExplorerChainInfo {
        let snapshot = await tip()
        return ExplorerChainInfo(
            genesisHash: await canonicalCID(0),
            height: snapshot.height,
            tipCID: snapshot.tipCID,
            chain: chainPath,
            minRelayFee: storage.configuration.minRelayFee
        )
    }

    public func explorerChainSpec() async -> ExplorerChainSpec? {
        guard let tip = await tip().tipCID,
              let block = await block(cid: tip),
              let spec = try? await block.spec.resolve(fetcher: storage).node else {
            return nil
        }
        return ExplorerChainSpec(
            targetBlockTime: spec.targetBlockTime,
            initialReward: spec.initialReward,
            halvingInterval: spec.halvingInterval,
            maxBlockSize: spec.maxBlockSize,
            maxNumberOfTransactionsPerBlock: spec.maxNumberOfTransactionsPerBlock,
            premine: spec.premine,
            halfLife: spec.halfLife
        )
    }

    public func explorerChainGenesis() async -> ExplorerChainGenesis {
        ExplorerChainGenesis(
            genesisHash: await tip().nexusGenesisCID
        )
    }
}

private actor ProofVolumeCollector: VolumeStorer {
    private var volumes: [String: SerializedVolume] = [:]

    func store(volume: SerializedVolume) async throws {
        volumes[volume.root] = volume
    }

    func witness() -> [LightClientProof.WitnessNode] {
        let unique = volumes.values.reduce(into: [String: Data]()) { result, volume in
            result.merge(volume.entries) { existing, _ in existing }
        }
        return unique.sorted { $0.key < $1.key }.map {
            LightClientProof.WitnessNode(cid: $0.key, data: $0.value)
        }
    }
}
