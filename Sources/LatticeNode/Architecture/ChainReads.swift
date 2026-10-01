import Foundation
import Ivy
import Lattice
import cashew

/// The node's read surface — chain status, blocks, transactions, state reads
/// and the explorer API — over content-verified, by-CID reads of this
/// chain's store and a tip source. Nothing here takes a gate or mutates:
/// content is immutable by CID, so only the tip, the canonical height index
/// and the mempool listing are read live. The actor path reads them from
/// `ChainProcess` and the transaction pool; the core driver from its
/// published snapshot.
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
    public static let maximumRecentBlocksLimit = 50
    private static let maximumExplorerPageLimit = 100
    private static let maximumExplorerMempoolListing = 200

    private static func boundedExplorerLimit(_ limit: Int) -> Int {
        min(max(limit, 0), maximumExplorerPageLimit)
    }

    let process: ChainProcess
    /// The tip readers see: the deepest executed block on the best chain.
    let tip: @Sendable () async -> ChainProcessStatus
    /// The block at a height of the chain to that tip.
    let canonicalCID: @Sendable (UInt64) async -> String?
    let mempool: @Sendable () async -> MempoolListing

    init(
        process: ChainProcess,
        tip: @escaping @Sendable () async -> ChainProcessStatus,
        canonicalCID: @escaping @Sendable (UInt64) async -> String?,
        mempool: @escaping @Sendable () async -> MempoolListing
    ) {
        self.process = process
        self.tip = tip
        self.canonicalCID = canonicalCID
        self.mempool = mempool
    }

    /// Ungated mirror of `status()` for public read RPC: no `acquireOperation()`,
    /// no `prepareMempoolLocked()` (which may restore durable local transactions) —
    /// every read is non-mutating.
    public func readSnapshot() async -> ChainServiceStatusResponse {
        let status = await tip()
        let pool = await mempool()
        let phase: ChainServicePhase = status.phase == .active
            ? .active
            : .awaitingGenesis
        return ChainServiceStatusResponse(
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

    /// Bounded public read: a decoded, content-verified block, gated to only
    /// what this node has durably accepted. Never takes the operation gate —
    /// reads only ChainProcess's ungated CAS path.
    public func block(cid: String) async -> Block? {
        guard await process.hasAcceptedBlock(cid) else { return nil }
        guard let data = await process.content([cid])[cid],
              data.count <= Self.maximumReadResponseBytes else {
            return nil
        }
        return _contentBoundBlock(cid: cid, data: data)
    }

    /// Bounded public read: a decoded, content-verified transaction. Resolving
    /// and content-binding as a `Transaction` is itself the gate that keeps
    /// internal (non-transaction) objects from being served by CID.
    public func transaction(cid: String) async -> Transaction? {
        guard let data = await process.content([cid])[cid],
              data.count <= Self.maximumReadResponseBytes else {
            return nil
        }
        guard let transaction = Transaction(data: data),
              (try? VolumeImpl<Transaction>(node: transaction).rawCID) == cid
        else { return nil }
        return transaction
    }

    /// Bounded public read: an account's balance and next-expected nonce as of
    /// one accepted block's post-state. Never takes the operation gate — reads
    /// only ChainProcess's ungated CAS path plus targeted trie resolution.
    public func account(
        owner: String,
        blockCID: String
    ) async -> (balance: UInt64, nonce: UInt64)? {
        guard await process.hasAcceptedBlock(blockCID) else { return nil }
        guard let data = await process.content([blockCID])[blockCID],
              data.count <= Self.maximumReadResponseBytes,
              let block = _contentBoundBlock(cid: blockCID, data: data) else {
            return nil
        }
        guard let state = try? await block.postState.resolve(fetcher: process).node else {
            return nil
        }
        guard let nonce = try? await state.accountState.nextExpectedNonce(
                for: owner,
                fetcher: process
              ),
              let resolved = try? await state.accountState.resolve(
                paths: [[owner]: .targeted],
                fetcher: process
              ),
              let accountNode = resolved.node else {
            return nil
        }
        let balance: UInt64 = (try? accountNode.get(key: owner)) ?? 0
        return (balance: balance, nonce: nonce)
    }

    /// Bounded public read: recent block headers walking parent links from
    /// `startCID` (or the current tip when `nil`) for up to `limit` steps
    /// (hard-capped at `maximumRecentBlocksLimit`). Each step is one bounded
    /// content fetch for the block plus one bounded content fetch for its
    /// transactions-dictionary header (to read its count) — full transaction
    /// bodies are never fetched. Never takes the operation gate. Returns nil
    /// when `startCID` is given but is not an accepted block.
    public func recentBlocks(before startCID: String?, limit: Int) async -> [BlockSummary]? {
        let boundedLimit = min(max(limit, 0), Self.maximumRecentBlocksLimit)
        guard boundedLimit > 0 else { return [] }

        var cid: String
        if let startCID {
            guard await process.hasAcceptedBlock(startCID) else { return nil }
            cid = startCID
        } else {
            guard let tip = await tip().tipCID else { return [] }
            cid = tip
        }

        var summaries: [BlockSummary] = []
        summaries.reserveCapacity(boundedLimit)
        for _ in 0..<boundedLimit {
            guard let data = await process.content([cid])[cid],
                  data.count <= Self.maximumReadResponseBytes,
                  let block = _contentBoundBlock(cid: cid, data: data) else {
                break
            }
            let transactionCount = (try? await block.transactions.resolve(
                fetcher: process
            ))?.node?.count ?? 0
            summaries.append(BlockSummary(
                cid: cid,
                height: block.height,
                parentCID: block.parent?.rawCID,
                timestamp: block.timestamp,
                transactionCount: transactionCount
            ))
            guard let parent = block.parent else { break }
            cid = parent.rawCID
        }
        return summaries
    }

    // MARK: - Explorer read API
    //
    // Ungated public reads for the browser explorer. Each mirrors the bounded,
    // content-verified by-CID path above and never takes the operation gate.

    /// This node's own absolute chain path — the single chain it serves. Used
    /// by the daemon to answer the explorer's optional `?chainPath=` filter.
    public func explorerChainPath() -> [String] {
        process.configuration.chainPath
    }

    /// Main-chain block CID at `height` (ungated height-index lookup), so the
    /// daemon can resolve a numeric `:id` to a CID before reading.
    public func explorerCanonicalBlockCID(atHeight height: UInt64) async -> String? {
        await canonicalCID(height)
    }

    public func explorerLatestBlock() async -> ExplorerLatestBlock? {
        guard let summary = (await recentBlocks(before: nil, limit: 1))?.first else {
            return nil
        }
        return ExplorerLatestBlock(
            height: summary.height,
            hash: summary.cid,
            transactionCount: summary.transactionCount,
            timestamp: summary.timestamp,
            previousBlock: summary.parentCID
        )
    }

    public func explorerBlock(cid: String) async -> ExplorerBlock? {
        guard let block = await block(cid: cid) else { return nil }
        let transactionCount = (try? await block.transactions.resolve(
            fetcher: process
        ))?.node?.count ?? 0
        let childBlockCount = (try? await block.children.resolve(
            fetcher: process
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
            chain: process.configuration.chainPath,
            rewardRecipient: block.rewardRecipient,
            rewardAmount: await rewardAmount(of: block)
        )
    }

    /// What `block` credited its recipient: the block reward plus fees, by
    /// the rule consensus applies. Nil when nothing was credited (no
    /// recipient, so it burned) or the block's content is not held here.
    private func rewardAmount(of block: Block) async -> UInt64? {
        guard block.rewardRecipient != nil,
              let spec = try? await block.spec.resolve(fetcher: process).node,
              let transactions = try? await MiningTemplateAssembly.blockTransactions(in: block, fetcher: process)
        else { return nil }
        var bodies: [TransactionBody] = []
        for transaction in transactions {
            guard let body = try? await transaction.body.resolve(
                fetcher: process
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
            fetcher: process
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
                        fetcher: process
                      ))?.node,
                      let volume = (try? node.get(key: key)) ?? nil else {
                    continue
                }
                guard let transaction = try? await volume.resolve(
                        fetcher: process
                      ).node,
                      let body = try? await transaction.body.resolve(
                        fetcher: process
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
            fetcher: process
        ))?.node else { return nil }
        let boundedLimit = Self.boundedExplorerLimit(limit)
        guard boundedLimit > 0 else { return ExplorerBlockChildren(children: []) }
        // The index is one node: the first `limit` directories in order.
        let entries = index.entries.keys.sorted().prefix(boundedLimit).map {
            ($0, index.entries[$0]!)
        }
        var children: [ExplorerChildBlock] = []
        for (directory, volume) in entries {
            guard let child = try? await volume.resolve(fetcher: process).node else {
                continue
            }
            let transactionCount = (try? await child.transactions.resolve(
                fetcher: process
            ))?.node?.count ?? 0
            children.append(ExplorerChildBlock(
                directory: directory,
                blockHash: volume.rawCID,
                height: child.height,
                transactionCount: transactionCount
            ))
        }
        return ExplorerBlockChildren(children: children)
    }

    public func explorerTransaction(cid: String) async -> ExplorerTransaction? {
        guard let transaction = await transaction(cid: cid) else { return nil }
        guard let body = try? await transaction.body.resolve(fetcher: process).node else {
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

    /// Ungated mempool snapshot: the pool's live CIDs (never the gated,
    /// mempool-reconciling `transactionInventoryRoots()`), hard-capped at 200.
    public func explorerMempool() async -> ExplorerMempool {
        let pool = await mempool()
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
            chain: process.configuration.chainPath
        )
    }

    public func explorerChainSpec() async -> ExplorerChainSpec? {
        guard let tip = await tip().tipCID,
              let block = await block(cid: tip),
              let spec = try? await block.spec.resolve(fetcher: process).node else {
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

    /// Best-effort child directory listing from the tip block's committed
    /// `genesisState` subtrie, capped at 100. Each entry maps a child directory
    /// to its anchored genesisCID.
    public func explorerChainChildren(limit: Int) async -> ExplorerChainChildren {
        let boundedLimit = Self.boundedExplorerLimit(limit)
        guard boundedLimit > 0 else { return ExplorerChainChildren(children: []) }
        let base = process.configuration.chainPath
        var seen = Set<String>()
        var children: [ExplorerChainChild] = []
        // Canonical source: the committed `genesisState` subtrie of the tip's
        // post-state maps every anchored child's directory -> its genesisCID.
        // Anchoring a child (a GenesisAction in a parent block) writes this
        // entry, so this trie IS the permissionless child index — no registry.
        // The genesisCID is what a client uses to (a) genesis-verify any node it
        // later discovers as a DHT provider of that CID and (b) resolve the
        // child's spec; walk it in one bounded enumeration.
        if let tip = await tip().tipCID,
           let block = await block(cid: tip),
           let state = try? await block.postState.resolve(
               fetcher: process
           ).node,
           let genesis = (try? await state.genesisState.resolve(
               fetcher: process
           ))?.node,
           let entries = try? await genesis.boundedKeysAndValues(
               limit: boundedLimit,
               fetcher: process
           ) {
            for (directory, genesisCID) in entries {
                guard children.count < boundedLimit else { break }
                guard seen.insert(directory).inserted else { continue }
                children.append(ExplorerChainChild(
                    chainPath: base + [directory],
                    genesisHash: genesisCID
                ))
            }
        }
        return ExplorerChainChildren(children: Array(children.prefix(boundedLimit)))
    }

    /// The anchored genesisCID of a direct child `directory` of this chain, read
    /// from the committed `genesisState` subtrie (targeted, single-key). nil if
    /// no such child is anchored. The daemon uses this to turn a `?chainPath=`
    /// into the CID it then runs a DHT provider discovery on for /api/chain/endpoints.
    public func explorerChildGenesisCID(directory: String) async -> String? {
        guard let tip = await tip().tipCID,
              let block = await block(cid: tip),
              let state = try? await block.postState.resolve(
                  fetcher: process
              ).node,
              let resolved = try? await state.genesisState.resolve(
                  paths: [[directory]: .targeted],
                  fetcher: process
              ),
              let node = resolved.node else {
            return nil
        }
        return (try? node.get(key: directory)) ?? nil
    }
}
