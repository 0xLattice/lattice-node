import Foundation
import Ivy
import Lattice
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

    private static func boundedExplorerLimit(_ limit: Int) -> Int {
        min(max(limit, 0), maximumExplorerPageLimit)
    }

    let storage: NodeStorage
    /// The tip readers see: the deepest executed block on the best chain.
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
            templateDigest: nil
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
        let boundedLimit = Self.boundedExplorerLimit(limit)
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
        return ExplorerTransaction(
            txCID: cid,
            blockHeight: nil,
            blockHash: nil,
            timestamp: nil,
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

    public func explorerAccount(owner: String) async -> ExplorerAccount? {
        guard let tip = await tip().tipCID else { return nil }
        guard let account = await account(owner: owner, blockCID: tip) else { return nil }
        return ExplorerAccount(
            owner: owner,
            balance: account.balance,
            nonce: account.nonce
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
            chain: chainPath
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
