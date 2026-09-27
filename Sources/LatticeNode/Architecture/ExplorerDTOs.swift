import Foundation
import UInt256

// MARK: - Explorer read API DTOs
//
// Rich, public, ungated read responses for the static browser explorer's
// `/api/...` surface. Defined here (module LatticeNode) so both ChainService
// and the daemon's HTTP handlers (module LatticeNodeDaemon) can see them —
// the handlers only `json()` these. Field names are the explorer's wire
// contract and must not change. Every producing method mirrors the existing
// by-CID read path (content-verified, size-bounded) and never takes the
// operation gate.

public struct ExplorerLatestBlock: Codable, Sendable, Equatable {
    public let height: UInt64
    public let hash: String
    public let transactionCount: Int
    public let timestamp: Int64
    public let previousBlock: String?
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
}

public struct ExplorerTransactionSummary: Codable, Sendable, Equatable {
    public let txCID: String
    public let signers: [String]
    public let fee: UInt64
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
    public let height: UInt64
    public let transactionCount: Int
}

public struct ExplorerBlockChildren: Codable, Sendable, Equatable {
    public let children: [ExplorerChildBlock]
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
    public let fee: UInt64
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

public struct ExplorerChainChild: Codable, Sendable, Equatable {
    public let chainPath: [String]
    public let genesisHash: String?
}

public struct ExplorerChainChildren: Codable, Sendable, Equatable {
    public let children: [ExplorerChainChild]
}

public struct ExplorerEndpoint: Codable, Sendable, Equatable {
    /// A reachable HTTP(S) read URL for a node serving the child chain. By
    /// convention (A) this is `https://<provider-host>` — the child node serves
    /// its public read API over HTTPS on the same host it announced as a DHT
    /// provider of the child's genesis. The explorer connects here and
    /// genesis-verifies it against the parent's anchored genesisCID.
    public let rpcUrl: String

    public init(rpcUrl: String) {
        self.rpcUrl = rpcUrl
    }
}

public struct ExplorerEndpoints: Codable, Sendable, Equatable {
    public let endpoints: [ExplorerEndpoint]

    public init(endpoints: [ExplorerEndpoint]) {
        self.endpoints = endpoints
    }
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
