import Foundation
import Lattice
import cashew

public enum ChainServiceLimits {
    /// Fits beneath the HTTP upload ceiling and leaves hierarchy-frame room for
    /// the provisional parent carrier and framing.
    public static let maximumPayloadBytes = 1 << 20

    /// A child intent may carry one consensus-sized genesis block and every
    /// immutable policy module named by its spec. The daemon applies this cap
    /// while collecting the request body, before JSON decoding.
    public static let maximumChildIntentPayloadBytes = 64 << 20
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
}
