import Foundation
import LatticeLightClient
import UInt256

// MARK: - Explorer read API DTOs
//
// Rich, public, ungated read responses for the static browser explorer's
// `/api/...` surface. Defined here (module LatticeNodeAPI) so `ChainReads` and
// the daemon's HTTP handlers (module LatticeNodeDaemon) share one contract.
// The handlers only `json()` these. Field names are the explorer's wire
// contract and must not change. Every producing method mirrors the existing
// by-CID read path (content-verified and size-bounded).

public struct ExplorerLatestBlock: Codable, Sendable, Equatable {
    @DecimalString public var height: UInt64
    public let hash: String
    public let transactionCount: Int
    @DecimalString public var timestamp: Int64
    public let previousBlock: String?
    /// The address this block credited its reward and fees; nil burned them.
    public let rewardRecipient: String?
    /// See `ExplorerBlock.rewardCredited`.
    @OptionalDecimalString public var rewardCredited: UInt64?

    public init(
        height: UInt64,
        hash: String,
        transactionCount: Int,
        timestamp: Int64,
        previousBlock: String?,
        rewardRecipient: String?,
        rewardCredited: UInt64? = nil
    ) {
        self.height = height
        self.hash = hash
        self.transactionCount = transactionCount
        self.timestamp = timestamp
        self.previousBlock = previousBlock
        self.rewardRecipient = rewardRecipient
        self.rewardCredited = rewardCredited
    }
}

public struct ExplorerBlock: Codable, Sendable, Equatable {
    @DecimalString public var height: UInt64
    public let hash: String
    @DecimalString public var timestamp: Int64
    public let previousBlock: String?
    public let transactionCount: Int
    public let childBlockCount: Int
    @DecimalString public var nonce: UInt64
    public let version: UInt16
    public let target: UInt256
    public let nextTarget: UInt256
    public let transactionsCID: String
    public let postStateCID: String
    public let chain: [String]
    /// The address this block credited its reward and fees; nil burned them.
    public let rewardRecipient: String?
    /// What consensus credited `rewardRecipient`: the block reward at this
    /// height plus the block's fees; 0 when the recipient is nil (burned).
    /// Nil only when this node does not hold the block's spec or bodies.
    @OptionalDecimalString public var rewardCredited: UInt64?

    public init(
        height: UInt64,
        hash: String,
        timestamp: Int64,
        previousBlock: String?,
        transactionCount: Int,
        childBlockCount: Int,
        nonce: UInt64,
        version: UInt16,
        target: UInt256,
        nextTarget: UInt256,
        transactionsCID: String,
        postStateCID: String,
        chain: [String],
        rewardRecipient: String?,
        rewardCredited: UInt64? = nil
    ) {
        self.height = height
        self.hash = hash
        self.timestamp = timestamp
        self.previousBlock = previousBlock
        self.transactionCount = transactionCount
        self.childBlockCount = childBlockCount
        self.nonce = nonce
        self.version = version
        self.target = target
        self.nextTarget = nextTarget
        self.transactionsCID = transactionsCID
        self.postStateCID = postStateCID
        self.chain = chain
        self.rewardRecipient = rewardRecipient
        self.rewardCredited = rewardCredited
    }
}

/// One row of `GET /api/blocks`: header fields and the transaction count
/// only. No transaction body is read, so there is no `rewardCredited`.
public struct ExplorerBlockSummary: Codable, Sendable, Equatable {
    @DecimalString public var height: UInt64
    public let hash: String
    public let previousBlock: String?
    @DecimalString public var timestamp: Int64
    public let transactionCount: Int
    public let rewardRecipient: String?

    public init(
        height: UInt64,
        hash: String,
        previousBlock: String?,
        timestamp: Int64,
        transactionCount: Int,
        rewardRecipient: String?
    ) {
        self.height = height
        self.hash = hash
        self.previousBlock = previousBlock
        self.timestamp = timestamp
        self.transactionCount = transactionCount
        self.rewardRecipient = rewardRecipient
    }
}

/// `GET /api/blocks`: canonical blocks newest first. `nextBefore` is the
/// `before` for the next (older) page; nil once height 0 is listed.
public struct ExplorerBlocksPage: Codable, Sendable, Equatable {
    public let blocks: [ExplorerBlockSummary]
    @OptionalDecimalString public var nextBefore: UInt64?

    public init(blocks: [ExplorerBlockSummary], nextBefore: UInt64? = nil) {
        self.blocks = blocks
        self.nextBefore = nextBefore
    }
}

public struct ExplorerTransactionSummary: Codable, Sendable, Equatable {
    public let txCID: String
    public let signers: [String]
    public let accountActionCount: Int
    public let depositActionCount: Int
    public let receiptActionCount: Int
    public let withdrawalActionCount: Int

    public init(
        txCID: String,
        signers: [String],
        accountActionCount: Int,
        depositActionCount: Int,
        receiptActionCount: Int,
        withdrawalActionCount: Int
    ) {
        self.txCID = txCID
        self.signers = signers
        self.accountActionCount = accountActionCount
        self.depositActionCount = depositActionCount
        self.receiptActionCount = receiptActionCount
        self.withdrawalActionCount = withdrawalActionCount
    }
}

public struct ExplorerBlockTransactions: Codable, Sendable, Equatable {
    public let transactions: [ExplorerTransactionSummary]
    public let nextOffset: Int?

    public init(transactions: [ExplorerTransactionSummary], nextOffset: Int?) {
        self.transactions = transactions
        self.nextOffset = nextOffset
    }
}

public struct ExplorerChildBlock: Codable, Sendable, Equatable {
    public let directory: String
    public let blockHash: String
    /// Nil when this node does not hold the child block (it does not host
    /// that child chain).
    @OptionalDecimalString public var height: UInt64?
    public let transactionCount: Int?

    public init(
        directory: String,
        blockHash: String,
        height: UInt64? = nil,
        transactionCount: Int?
    ) {
        self.directory = directory
        self.blockHash = blockHash
        self.height = height
        self.transactionCount = transactionCount
    }
}

public struct ExplorerBlockChildren: Codable, Sendable, Equatable {
    public let children: [ExplorerChildBlock]

    public init(children: [ExplorerChildBlock]) {
        self.children = children
    }
}

/// `GET /api/chain/children`: a page of the child directories the chain's
/// executed blocks have committed, in order. `next` is the `after` for the
/// following page, absent on the last.
public struct ExplorerChainChildren: Codable, Sendable, Equatable {
    public let chainPath: [String]
    public let directories: [String]
    public let next: String?

    public init(chainPath: [String], directories: [String], next: String?) {
        self.chainPath = chainPath
        self.directories = directories
        self.next = next
    }
}

/// `GET /api/chain/endpoints`: the read URLs declared for a child chain,
/// UNVERIFIED, beside the child block its parent most recently commits
/// under its directory (information only: it can be a block the child
/// chain did not keep, or one nobody serves).
public struct ExplorerChainEndpoints: Codable, Sendable, Equatable {
    public let chainPath: [String]
    public let committedBlock: String?
    public let endpoints: [String]
    /// The subset of `endpoints` whose hosts also declare that they accept
    /// `POST /transactions` there (operator choice, equally unverified). A
    /// host answering in the v1 form is counted as not accepting.
    public let submitEndpoints: [String]

    public init(
        chainPath: [String],
        committedBlock: String?,
        endpoints: [String],
        submitEndpoints: [String] = []
    ) {
        self.chainPath = chainPath
        self.committedBlock = committedBlock
        self.endpoints = endpoints
        self.submitEndpoints = submitEndpoints
    }

    private enum CodingKeys: String, CodingKey {
        case chainPath, committedBlock, endpoints, submitEndpoints
    }

    /// An answer from a node predating `submitEndpoints` declares none.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chainPath = try container.decode([String].self, forKey: .chainPath)
        committedBlock = try container.decodeIfPresent(String.self, forKey: .committedBlock)
        endpoints = try container.decode([String].self, forKey: .endpoints)
        submitEndpoints = try container.decodeIfPresent([String].self, forKey: .submitEndpoints) ?? []
    }
}

public struct ExplorerAccountAction: Codable, Sendable, Equatable {
    public let owner: String
    @DecimalString public var delta: Int64

    public init(owner: String, delta: Int64) {
        self.owner = owner
        self.delta = delta
    }
}

public struct ExplorerDepositAction: Codable, Sendable, Equatable {
    public let nonce: String
    public let demander: String
    @DecimalString public var amountDemanded: UInt64
    @DecimalString public var amountDeposited: UInt64

    public init(nonce: String, demander: String, amountDemanded: UInt64, amountDeposited: UInt64) {
        self.nonce = nonce
        self.demander = demander
        self.amountDemanded = amountDemanded
        self.amountDeposited = amountDeposited
    }
}

public struct ExplorerDeposit: Codable, Sendable, Equatable {
    public let key: String
    public let demander: String
    @DecimalString public var amountDemanded: UInt64
    public let nonce: String
    @DecimalString public var amountDeposited: UInt64
    /// The canonical block that created this deposit, as this node reports it.
    /// Absent when the node no longer holds the states needed to locate it.
    /// The page's proof covers the deposit's value at the tip, not these.
    @OptionalDecimalString public var blockHeight: UInt64?
    public let blockHash: String?

    public init(
        key: String,
        demander: String,
        amountDemanded: UInt64,
        nonce: String,
        amountDeposited: UInt64,
        blockHeight: UInt64? = nil,
        blockHash: String? = nil
    ) {
        self.key = key
        self.demander = demander
        self.amountDemanded = amountDemanded
        self.nonce = nonce
        self.amountDeposited = amountDeposited
        self.blockHeight = blockHeight
        self.blockHash = blockHash
    }
}

public struct ExplorerDepositsPage: Codable, Sendable, Equatable {
    public let deposits: [ExplorerDeposit]
    public let count: Int
    public let chain: String
    public let next: String?
    public let proof: StateDictionaryProof

    public init(
        deposits: [ExplorerDeposit],
        chain: String,
        next: String?,
        proof: StateDictionaryProof
    ) {
        self.deposits = deposits
        self.count = deposits.count
        self.chain = chain
        self.next = next
        self.proof = proof
    }
}

/// One deposit key's value at the tip: the amount still locked, `0` once
/// withdrawn, or absent (`value` left out) if it was never deposited.
public struct ExplorerDepositState: Codable, Sendable, Equatable {
    public let exists: Bool
    public let key: String
    public let value: String?
    public let chain: String
    public let proof: StateDictionaryProof

    public init(key: String, value: String?, chain: String, proof: StateDictionaryProof) {
        self.exists = value != nil
        self.key = key
        self.value = value
        self.chain = chain
        self.proof = proof
    }
}

public struct ExplorerReceiptState: Codable, Sendable, Equatable {
    public let exists: Bool
    public let withdrawer: String?
    public let directory: String
    public let chainPath: [String]
    public let key: String
    public let proof: StateDictionaryProof

    public init(
        withdrawer: String?,
        directory: String,
        chainPath: [String],
        key: String,
        proof: StateDictionaryProof
    ) {
        self.exists = withdrawer != nil
        self.withdrawer = withdrawer
        self.directory = directory
        self.chainPath = chainPath
        self.key = key
        self.proof = proof
    }
}

public struct ExplorerReceiptAction: Codable, Sendable, Equatable {
    public let withdrawer: String
    public let nonce: String
    public let demander: String
    @DecimalString public var amountDemanded: UInt64
    public let directory: String

    public init(
        withdrawer: String,
        nonce: String,
        demander: String,
        amountDemanded: UInt64,
        directory: String
    ) {
        self.withdrawer = withdrawer
        self.nonce = nonce
        self.demander = demander
        self.amountDemanded = amountDemanded
        self.directory = directory
    }
}

public struct ExplorerWithdrawalAction: Codable, Sendable, Equatable {
    public let withdrawer: String
    public let nonce: String
    public let demander: String
    @DecimalString public var amountDemanded: UInt64
    @DecimalString public var amountWithdrawn: UInt64

    public init(
        withdrawer: String,
        nonce: String,
        demander: String,
        amountDemanded: UInt64,
        amountWithdrawn: UInt64
    ) {
        self.withdrawer = withdrawer
        self.nonce = nonce
        self.demander = demander
        self.amountDemanded = amountDemanded
        self.amountWithdrawn = amountWithdrawn
    }
}

public struct ExplorerTransaction: Codable, Sendable, Equatable {
    public let txCID: String
    @OptionalDecimalString public var blockHeight: UInt64?
    public let blockHash: String?
    @OptionalDecimalString public var timestamp: Int64?
    @DecimalString public var nonce: UInt64
    public let signers: [String]
    public let chainPath: [String]
    public let chain: [String]
    public let accountActions: [ExplorerAccountAction]
    public let depositActions: [ExplorerDepositAction]
    public let receiptActions: [ExplorerReceiptAction]
    public let withdrawalActions: [ExplorerWithdrawalAction]

    public init(
        txCID: String,
        blockHeight: UInt64? = nil,
        blockHash: String?,
        timestamp: Int64? = nil,
        nonce: UInt64,
        signers: [String],
        chainPath: [String],
        chain: [String],
        accountActions: [ExplorerAccountAction],
        depositActions: [ExplorerDepositAction],
        receiptActions: [ExplorerReceiptAction],
        withdrawalActions: [ExplorerWithdrawalAction]
    ) {
        self.txCID = txCID
        self.blockHeight = blockHeight
        self.blockHash = blockHash
        self.timestamp = timestamp
        self.nonce = nonce
        self.signers = signers
        self.chainPath = chainPath
        self.chain = chain
        self.accountActions = accountActions
        self.depositActions = depositActions
        self.receiptActions = receiptActions
        self.withdrawalActions = withdrawalActions
    }
}

public struct ExplorerAccount: Codable, Sendable, Equatable {
    public let owner: String
    @DecimalString public var balance: UInt64
    @DecimalString public var nonce: UInt64

    public init(owner: String, balance: UInt64, nonce: UInt64) {
        self.owner = owner
        self.balance = balance
        self.nonce = nonce
    }
}

public struct ExplorerMempool: Codable, Sendable, Equatable {
    public let count: Int
    public let transactions: [String]

    public init(count: Int, transactions: [String]) {
        self.count = count
        self.transactions = transactions
    }
}

/// `GET /api/fees`: the blocks this node's pool would fill next, in order.
/// A chain with room has one block, not `full`, or none: any fee at the
/// floor makes the next block. Behind full blocks, a fee buys a place.
public struct ExplorerFees: Codable, Sendable, Equatable {
    /// This node's relay floor (policy, never consensus), as in chain info.
    @DecimalString public var minRelayFee: UInt64
    public let blocks: [ExplorerProjectedBlock]
    /// What a transaction's weight is measured against. Absent from older
    /// nodes, whose rates are per byte.
    public var weight: ExplorerWeight?

    public init(
        minRelayFee: UInt64,
        blocks: [ExplorerProjectedBlock],
        weight: ExplorerWeight? = nil
    ) {
        self.minRelayFee = minRelayFee
        self.blocks = blocks
        self.weight = weight
    }
}

/// A transaction's weight (`FeeWeight`) is the largest of its bytes plus
/// `transactionAllowance`, its state growth (Lattice's ceiling) times
/// `blockRoom / growthRoom` rounded up, and `blockRoom / maxTransactions`.
public struct ExplorerWeight: Codable, Sendable, Equatable {
    public let blockRoom: Int
    public let growthRoom: Int
    public let maxTransactions: Int
    public let transactionAllowance: Int

    public init(blockRoom: Int, growthRoom: Int, maxTransactions: Int, transactionAllowance: Int) {
        self.blockRoom = blockRoom
        self.growthRoom = growthRoom
        self.maxTransactions = maxTransactions
        self.transactionAllowance = transactionAllowance
    }
}

public struct ExplorerProjectedBlock: Codable, Sendable, Equatable {
    public let transactionCount: Int
    public let bytes: Int
    /// The block's lowest rate: `lowestFee` over `lowestFeeWeight`. A
    /// transaction of weight `w` paying more than
    /// `lowestFee * w / lowestFeeWeight` would be taken before it.
    @DecimalString public var lowestFee: UInt64
    public let lowestFeeBytes: Int
    /// Absent from older nodes, whose weight is `lowestFeeBytes`.
    public var lowestFeeWeight: Int?
    /// Whether ready transactions were left for a later block.
    public let full: Bool

    public init(
        transactionCount: Int,
        bytes: Int,
        lowestFee: UInt64,
        lowestFeeBytes: Int,
        lowestFeeWeight: Int? = nil,
        full: Bool
    ) {
        self.transactionCount = transactionCount
        self.bytes = bytes
        self.lowestFee = lowestFee
        self.lowestFeeBytes = lowestFeeBytes
        self.lowestFeeWeight = lowestFeeWeight
        self.full = full
    }
}

public struct ExplorerChainInfo: Codable, Sendable, Equatable {
    public let genesisHash: String?
    @OptionalDecimalString public var height: UInt64?
    public let tipCID: String?
    public let chain: [String]
    /// Whether the listener that answered accepts `POST /transactions`: true
    /// on the loopback operator API, and on the public read listener only
    /// when its operator turned public submit on. Absent from older nodes.
    public var acceptsSubmit: Bool?
    /// The operator's minimum fee for admitting a transaction to this node's
    /// pool (node policy, never consensus; 0 admits any fee). Other nodes may
    /// set their own.
    @OptionalDecimalString public var minRelayFee: UInt64?
    /// The operator's node-local finality window for this chain, in blocks
    /// (`--finality-window`; node policy, never consensus). Absent when off,
    /// the default.
    @OptionalDecimalString public var finalityWindow: UInt64? = nil

    public init(
        genesisHash: String?,
        height: UInt64? = nil,
        tipCID: String?,
        chain: [String],
        acceptsSubmit: Bool? = nil,
        minRelayFee: UInt64? = nil,
        finalityWindow: UInt64? = nil
    ) {
        self.genesisHash = genesisHash
        self.height = height
        self.tipCID = tipCID
        self.chain = chain
        self.acceptsSubmit = acceptsSubmit
        self.minRelayFee = minRelayFee
        self.finalityWindow = finalityWindow
    }
}

public struct ExplorerChainSpec: Codable, Sendable, Equatable {
    @DecimalString public var targetBlockTime: UInt64
    @DecimalString public var initialReward: UInt64
    @DecimalString public var halvingInterval: UInt64
    public let maxBlockSize: Int
    @DecimalString public var maxNumberOfTransactionsPerBlock: UInt64
    @DecimalString public var premine: UInt64
    @DecimalString public var halfLife: UInt64

    public init(
        targetBlockTime: UInt64,
        initialReward: UInt64,
        halvingInterval: UInt64,
        maxBlockSize: Int,
        maxNumberOfTransactionsPerBlock: UInt64,
        premine: UInt64,
        halfLife: UInt64
    ) {
        self.targetBlockTime = targetBlockTime
        self.initialReward = initialReward
        self.halvingInterval = halvingInterval
        self.maxBlockSize = maxBlockSize
        self.maxNumberOfTransactionsPerBlock = maxNumberOfTransactionsPerBlock
        self.premine = premine
        self.halfLife = halfLife
    }
}

public struct ExplorerChainGenesis: Codable, Sendable, Equatable {
    public let genesisHash: String

    public init(genesisHash: String) {
        self.genesisHash = genesisHash
    }
}

/// Public explorer peer DTOs. Defined here (module LatticeNode) so both the
/// runtime and the daemon's HTTP handlers (module LatticeNodeDaemon) can see
/// them; the handlers only `json()` these.
public struct ExplorerPeerSummary: Codable, Sendable, Equatable {
    public let key: String
    public let role: String

    public init(key: String, role: String) {
        self.key = key
        self.role = role
    }
}

public struct ExplorerPeersResponse: Codable, Sendable, Equatable {
    public let count: Int
    public let peers: [ExplorerPeerSummary]

    public init(count: Int, peers: [ExplorerPeerSummary]) {
        self.count = count
        self.peers = peers
    }
}
