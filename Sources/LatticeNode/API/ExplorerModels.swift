import Foundation
import UInt256

// MARK: - Explorer read API DTOs
//
// Rich, public, ungated read responses for the static browser explorer's
// `/api/...` surface. Defined here (module LatticeNode) so `ChainReads` and
// the daemon's HTTP handlers (module LatticeNodeDaemon) share one contract.
// The handlers only `json()` these. Field names are the explorer's wire
// contract and must not change. Every producing method mirrors the existing
// by-CID read path (content-verified and size-bounded).

public struct ExplorerLatestBlock: Codable, Sendable, Equatable {
    public let height: UInt64
    public let hash: String
    public let transactionCount: Int
    public let timestamp: Int64
    public let previousBlock: String?
    /// The address this block credited its reward and fees; nil burned them.
    public let rewardRecipient: String?
    /// See `ExplorerBlock.rewardCredited`.
    public let rewardCredited: UInt64?
}

public struct ExplorerBlock: Codable, Sendable, Equatable {
    public let height: UInt64
    public let hash: String
    public let timestamp: Int64
    public let previousBlock: String?
    public let transactionCount: Int
    public let childBlockCount: Int
    public let nonce: UInt64
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
    public let rewardCredited: UInt64?
}

/// One row of `GET /api/blocks`: header fields and the transaction count
/// only. No transaction body is read, so there is no `rewardCredited`.
public struct ExplorerBlockSummary: Codable, Sendable, Equatable {
    public let height: UInt64
    public let hash: String
    public let previousBlock: String?
    public let timestamp: Int64
    public let transactionCount: Int
    public let rewardRecipient: String?
}

/// `GET /api/blocks`: canonical blocks newest first. `nextBefore` is the
/// `before` for the next (older) page; nil once height 0 is listed.
public struct ExplorerBlocksPage: Codable, Sendable, Equatable {
    public let blocks: [ExplorerBlockSummary]
    public let nextBefore: UInt64?
}

public struct ExplorerTransactionSummary: Codable, Sendable, Equatable {
    public let txCID: String
    public let signers: [String]
    public let accountActionCount: Int
    public let depositActionCount: Int
    public let receiptActionCount: Int
    public let withdrawalActionCount: Int
}

public struct ExplorerBlockTransactions: Codable, Sendable, Equatable {
    public let transactions: [ExplorerTransactionSummary]
    public let nextOffset: Int?
}

public struct ExplorerChildBlock: Codable, Sendable, Equatable {
    public let directory: String
    public let blockHash: String
    /// Nil when this node does not hold the child block (it does not host
    /// that child chain).
    public let height: UInt64?
    public let transactionCount: Int?
}

public struct ExplorerBlockChildren: Codable, Sendable, Equatable {
    public let children: [ExplorerChildBlock]
}

/// `GET /api/chain/endpoints`: the read URLs declared for a child chain,
/// UNVERIFIED, beside the child block its parent commits under its
/// directory. A reader accepts a URL only if it serves that block.
public struct ExplorerChainEndpoints: Codable, Sendable, Equatable {
    public let chainPath: [String]
    public let committedBlock: String?
    public let endpoints: [String]
    /// The subset of `endpoints` whose hosts also declare that they accept
    /// `POST /transactions` there (operator choice, equally unverified). A
    /// host answering in the v1 form is counted as not accepting.
    public let submitEndpoints: [String]

    public init(chainPath: [String], committedBlock: String?, endpoints: [String], submitEndpoints: [String] = []) {
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
    public let delta: Int64
}

public struct ExplorerDepositAction: Codable, Sendable, Equatable {
    public let nonce: String
    public let demander: String
    public let amountDemanded: UInt64
    public let amountDeposited: UInt64
}

public struct ExplorerReceiptAction: Codable, Sendable, Equatable {
    public let withdrawer: String
    public let nonce: String
    public let demander: String
    public let amountDemanded: UInt64
    public let directory: String
}

public struct ExplorerWithdrawalAction: Codable, Sendable, Equatable {
    public let withdrawer: String
    public let nonce: String
    public let demander: String
    public let amountDemanded: UInt64
    public let amountWithdrawn: UInt64
}

public struct ExplorerTransaction: Codable, Sendable, Equatable {
    public let txCID: String
    public let blockHeight: UInt64?
    public let blockHash: String?
    public let timestamp: Int64?
    public let nonce: UInt64
    public let signers: [String]
    public let chainPath: [String]
    public let chain: [String]
    public let accountActions: [ExplorerAccountAction]
    public let depositActions: [ExplorerDepositAction]
    public let receiptActions: [ExplorerReceiptAction]
    public let withdrawalActions: [ExplorerWithdrawalAction]
}

public struct ExplorerAccount: Codable, Sendable, Equatable {
    public let owner: String
    public let balance: UInt64
    public let nonce: UInt64
}

public struct ExplorerMempool: Codable, Sendable, Equatable {
    public let count: Int
    public let transactions: [String]
}

public struct ExplorerChainInfo: Codable, Sendable, Equatable {
    public let genesisHash: String?
    public let height: UInt64?
    public let tipCID: String?
    public let chain: [String]
    /// Whether the listener that answered accepts `POST /transactions`: true
    /// on the loopback operator API, and on the public read listener only
    /// when its operator turned public submit on. Absent from older nodes.
    public var acceptsSubmit: Bool?
}

public struct ExplorerChainSpec: Codable, Sendable, Equatable {
    public let targetBlockTime: UInt64
    public let initialReward: UInt64
    public let halvingInterval: UInt64
    public let maxBlockSize: Int
    public let maxNumberOfTransactionsPerBlock: UInt64
    public let premine: UInt64
    public let halfLife: UInt64
}

public struct ExplorerChainGenesis: Codable, Sendable, Equatable {
    public let genesisHash: String
}

/// Public explorer peer DTOs. Defined here (module LatticeNode) so both the
/// runtime and the daemon's HTTP handlers (module LatticeNodeDaemon) can see
/// them; the handlers only `json()` these.
public struct ExplorerPeerSummary: Codable, Sendable, Equatable {
    public let key: String
    public let role: String
}

public struct ExplorerPeersResponse: Codable, Sendable, Equatable {
    public let count: Int
    public let peers: [ExplorerPeerSummary]

    public init(count: Int, peers: [ExplorerPeerSummary]) {
        self.count = count
        self.peers = peers
    }
}
