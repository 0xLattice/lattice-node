import Foundation
import Lattice
import cashew

public enum NodeAPILimits {
    /// Fits beneath the HTTP upload ceiling and leaves protocol framing room.
    public static let maximumPayloadBytes = 1 << 20
}

public enum ContentBoundTransactionError: Error, Equatable, Sendable {
    case unresolvedBody
    case bodyCIDMismatch
}

/// JSON-safe transaction payload. Cashew headers encode references only, so an
/// RPC request must carry the concrete body alongside its signatures.
public struct ContentBoundTransaction: Codable, Sendable {
    public let signatures: [String: String]
    public let body: TransactionBody

    public init(transaction: Transaction) throws {
        guard let body = transaction.body.node else {
            throw ContentBoundTransactionError.unresolvedBody
        }
        let header = try HeaderImpl(node: body)
        guard header.rawCID == transaction.body.rawCID else {
            throw ContentBoundTransactionError.bodyCIDMismatch
        }
        self.signatures = transaction.signatures
        self.body = body
    }

    public init(signatures: [String: String], body: TransactionBody) {
        self.signatures = signatures
        self.body = body
    }

    public func transaction() throws -> Transaction {
        Transaction(signatures: signatures, body: try HeaderImpl(node: body))
    }

    private enum CodingKeys: String, CodingKey {
        case signatures, body
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        signatures = try container.decode([String: String].self, forKey: .signatures)
        body = try container.decode(WireTransactionBody.self, forKey: .body).body
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(signatures, forKey: .signatures)
        try container.encode(WireTransactionBody(body), forKey: .body)
    }
}

/// `TransactionBody` on the JSON wire: every 64- and 128-bit integer a
/// canonical decimal string (see `DecimalString`). The body's content address
/// is its DAG-CBOR encoding, which this spelling does not touch.
struct WireTransactionBody: Codable {
    struct Account: Codable {
        let owner: String
        @DecimalString var delta: Int64
    }

    struct Deposit: Codable {
        @DecimalString var nonce: UInt128
        let demander: String
        @DecimalString var amountDemanded: UInt64
        @DecimalString var amountDeposited: UInt64
    }

    struct Receipt: Codable {
        let withdrawer: String
        @DecimalString var nonce: UInt128
        let demander: String
        @DecimalString var amountDemanded: UInt64
        let directory: String
    }

    struct Withdrawal: Codable {
        let withdrawer: String
        @DecimalString var nonce: UInt128
        let demander: String
        @DecimalString var amountDemanded: UInt64
        @DecimalString var amountWithdrawn: UInt64
    }

    let accountActions: [Account]
    let actions: [Action]
    let depositActions: [Deposit]
    let receiptActions: [Receipt]
    let withdrawalActions: [Withdrawal]
    let signers: [String]
    @DecimalString var nonce: UInt64
    let chainPath: [String]

    init(_ body: TransactionBody) {
        accountActions = body.accountActions.map { Account(owner: $0.owner, delta: $0.delta) }
        actions = body.actions
        depositActions = body.depositActions.map {
            Deposit(
                nonce: $0.nonce, demander: $0.demander,
                amountDemanded: $0.amountDemanded, amountDeposited: $0.amountDeposited
            )
        }
        receiptActions = body.receiptActions.map {
            Receipt(
                withdrawer: $0.withdrawer, nonce: $0.nonce, demander: $0.demander,
                amountDemanded: $0.amountDemanded, directory: $0.directory
            )
        }
        withdrawalActions = body.withdrawalActions.map {
            Withdrawal(
                withdrawer: $0.withdrawer, nonce: $0.nonce, demander: $0.demander,
                amountDemanded: $0.amountDemanded, amountWithdrawn: $0.amountWithdrawn
            )
        }
        signers = body.signers
        nonce = body.nonce
        chainPath = body.chainPath
    }

    var body: TransactionBody {
        TransactionBody(
            accountActions: accountActions.map { AccountAction(owner: $0.owner, delta: $0.delta) },
            actions: actions,
            depositActions: depositActions.map {
                DepositAction(
                    nonce: $0.nonce, demander: $0.demander,
                    amountDemanded: $0.amountDemanded, amountDeposited: $0.amountDeposited
                )
            },
            receiptActions: receiptActions.map {
                ReceiptAction(
                    withdrawer: $0.withdrawer, nonce: $0.nonce, demander: $0.demander,
                    amountDemanded: $0.amountDemanded, directory: $0.directory
                )
            },
            withdrawalActions: withdrawalActions.map {
                WithdrawalAction(
                    withdrawer: $0.withdrawer, nonce: $0.nonce, demander: $0.demander,
                    amountDemanded: $0.amountDemanded, amountWithdrawn: $0.amountWithdrawn
                )
            },
            signers: signers,
            nonce: nonce,
            chainPath: chainPath
        )
    }
}
