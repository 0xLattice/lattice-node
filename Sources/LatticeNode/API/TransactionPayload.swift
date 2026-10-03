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
}
